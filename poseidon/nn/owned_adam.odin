package nn

import "../core"
import "core:mem"

// Opt-in ownership for Adam's parameter-pointer list and two moment buffers.
// Start with a zero-valued handle and initialize it in its final location; do not
// copy or move it while live. The model, any rebound parameter data/gradients,
// allocator state, and the handle must outlive the optimizer and every compiled
// handle using it. The model must also remain in place. No concurrent mutation is
// permitted. The guard only compares addresses: it cannot detect a stale copy
// written back to its original address, validate the model's lifetime, revoke an
// already borrowed ^Adam, or protect direct field access. Treat the fields as
// implementation details; do not modify ownership metadata.
SequentialOwnedAdam :: struct {
	optimizer: Adam,
	parameterStorage: []^core.Node,
	firstMoment, secondMoment: []f32,
	allocator: mem.Allocator,
	self: rawptr,
	destroying: bool,
	pending: [3]rawptr,
}

// Allocates exactly the storage reported by SequentialAdamRequirements and binds
// it with SequentialAdamInit, using the same parameter order and defaults. A
// nonempty model with no trainable parameters needs no allocations. The allocator
// defaults to context.allocator and must return valid, aligned, disjoint storage
// and support individual frees; its state must remain alive until Destroy. A
// failed free must leave the allocation intact if destruction is to be retried.
// The handle, model, and rebound parameter data/gradients must be
// disjoint from each other and from the allocator's allocations and state.
//
// Ordinary failure leaves the handle and model unchanged and frees partial
// allocations. If a rollback free reports an error, its allocation is retained in
// a cleanup-only state and Destroy must be retried. A live, copied, or cleanup-
// pending handle cannot be reinitialized: destroy the original first. Success resets
// step and moments without changing parameters. After architecture changes or a
// model-only restore, destroy and reinitialize; discard/recompile all compiled
// handles that borrowed the previous optimizer.
SequentialOwnedAdamInit :: proc(
	model: ^Sequential($maxLayers, $maxWidth, $batchCapacity),
	owned: ^SequentialOwnedAdam,
	learningRate: f32 = 0.001, beta1: f32 = 0.9, beta2: f32 = 0.999, epsilon: f32 = 1e-8,
	allocator := context.allocator,
) -> bool {
	if model == nil || owned == nil { return false }
	modelRange, valid := SequentialAdamRange(rawptr(model), 1, size_of(model^))
	if !valid { return false }
	ownedRange, ownedValid := SequentialAdamRange(rawptr(owned), 1, size_of(owned^))
	if !ownedValid || SequentialAdamRangesOverlap(modelRange, ownedRange) || owned.self != nil ||
		owned.pending != ([3]rawptr{}) { return false }

	candidate := Adam{learningRate = learningRate, beta1 = beta1, beta2 = beta2, epsilon = epsilon}
	if !AdamConfigValid(&candidate) { return false }
	count, elements, requirementsOk := SequentialAdamRequirements(model)
	if !requirementsOk || count > max(int)/size_of(^core.Node) || elements > max(int)/size_of(f32) { return false }
	parameters: [2 * maxLayers]^core.Node
	list, listOk := SequentialParameters(model, parameters[:])
	if !listOk || len(list) != count { return false }
	for parameter in list {
		for tensor in ([2]core.Tensor{parameter.value, parameter.grad}) {
			dataRange, dataValid := SequentialAdamRange(rawptr(raw_data(tensor.data)), len(tensor.data), size_of(f32))
			if !dataValid || SequentialAdamRangesOverlap(ownedRange, dataRange) { return false }
		}
	}

	owned.allocator, owned.self, owned.destroying = allocator, rawptr(owned), true
	if count > 0 {
		err: mem.Allocator_Error
		owned.pending[0], err = mem.alloc(count*size_of(^core.Node), align_of(^core.Node), allocator)
		if err != nil || owned.pending[0] == nil { _ = sequentialOwnedAdamRollback(owned); return false }
	}
	if elements > 0 {
		err: mem.Allocator_Error
		owned.pending[1], err = mem.alloc(elements*size_of(f32), align_of(f32), allocator)
		if err != nil || owned.pending[1] == nil { _ = sequentialOwnedAdamRollback(owned); return false }
		owned.pending[2], err = mem.alloc(elements*size_of(f32), align_of(f32), allocator)
		if err != nil || owned.pending[2] == nil { _ = sequentialOwnedAdamRollback(owned); return false }
	}
	parameterMemory, firstMemory, secondMemory := owned.pending[0], owned.pending[1], owned.pending[2]

	parameterStorage: []^core.Node
	firstMoment, secondMoment: []f32
	if count > 0 { parameterStorage = mem.slice_ptr((^^core.Node)(parameterMemory), count) }
	if elements > 0 {
		firstMoment = mem.slice_ptr((^f32)(firstMemory), elements)
		secondMoment = mem.slice_ptr((^f32)(secondMemory), elements)
	}
	// SequentialAdamInit checks its Adam field, but the whole owner must be disjoint.
	ranges: [3]SequentialAdamMemoryRange
	valid = true
	ranges[0], valid = SequentialAdamRange(parameterMemory, count, size_of(^core.Node)); if !valid { _ = sequentialOwnedAdamRollback(owned); return false }
	ranges[1], valid = SequentialAdamRange(firstMemory, elements, size_of(f32)); if !valid { _ = sequentialOwnedAdamRollback(owned); return false }
	ranges[2], valid = SequentialAdamRange(secondMemory, elements, size_of(f32)); if !valid { _ = sequentialOwnedAdamRollback(owned); return false }
	for range in ranges { if SequentialAdamRangesOverlap(ownedRange, range) { _ = sequentialOwnedAdamRollback(owned); return false } }
	if !SequentialAdamInit(model, &owned.optimizer, parameterStorage, firstMoment, secondMoment, learningRate, beta1, beta2, epsilon) { _ = sequentialOwnedAdamRollback(owned); return false }
	owned.parameterStorage, owned.firstMoment, owned.secondMoment = parameterStorage, firstMoment, secondMoment
	owned.pending = {}
	owned.destroying = false
	return true
}

@(private="file")
sequentialOwnedAdamReleasePending :: proc(owned: ^SequentialOwnedAdam) -> bool {
	ok := true
	for index := len(owned.pending)-1; index >= 0; index -= 1 {
		if owned.pending[index] != nil {
			if mem.free(owned.pending[index], owned.allocator) == nil {
				owned.pending[index] = nil
			} else {
				ok = false
			}
		}
	}
	return ok
}

@(private="file")
sequentialOwnedAdamRollback :: proc(owned: ^SequentialOwnedAdam) -> bool {
	if !sequentialOwnedAdamReleasePending(owned) { return false }
	owned^ = {}
	return true
}

// Returns the stable in-place Adam for SequentialCompile, SequentialFitBatches,
// and checkpoint APIs, or nil for a nil, uninitialized, destroyed, copied, or
// cleanup-pending handle. The pointer and every compiled handle retaining it
// become invalid for use when the owner is destroyed. Do not rebind Adam's
// storage or parameter list except through a compatible CheckpointRead, and do
// not move the owner.
SequentialOwnedAdamOptimizer :: proc(owned: ^SequentialOwnedAdam) -> ^Adam {
	if owned == nil || owned.self != rawptr(owned) || owned.destroying || owned.pending != ([3]rawptr{}) { return nil }
	return &owned.optimizer
}

// Returns the full owned storage for CheckpointRead/CheckpointLoadFile, or
// (nil, nil, nil, false) for an invalid handle. The slices are borrowed: do not
// free them or manually alter the parameter list. To restore an Adam checkpoint,
// first build a destination model with sufficient requirements and initialize
// its owner, then call CheckpointRead with that same model,
// SequentialOwnedAdamOptimizer(owner), and these three slices. The read restores
// the model, parameter binding, hyperparameters, step and moments. Model type
// capacities must match the checkpoint, the owner must have enough storage, and
// CheckpointRead's disjointness rules apply. Restoring reconstructs the model and
// replaces any rebound parameter data with its inline storage. Checkpoint input,
// shuffle state, and file scratch must also be disjoint from the entire owner,
// not just its Adam field. The accessor still returns full allocated lengths
// after restoring a smaller checkpoint.
// Init rejects a live owner; destroying/reinitializing it or manually calling
// SequentialAdamInit would reset the restored state. Recompile any compiled handle
// after restoring the model. Checkpoints resume at epoch boundaries.
SequentialOwnedAdamStorage :: proc(owned: ^SequentialOwnedAdam) -> (parameters: []^core.Node, first, second: []f32, ok: bool) {
	if owned == nil || owned.self != rawptr(owned) || owned.destroying || owned.pending != ([3]rawptr{}) { return nil, nil, nil, false }
	return owned.parameterStorage, owned.firstMoment, owned.secondMoment, true
}

// Frees the original or pending allocations with their original allocator and
// clears the handle. Repeated destruction of a zero/destroyed handle succeeds;
// nil and copied/moved handles at a different address return false without freeing
// anything. Discard copies; never write one back to the original address. The
// allocator must support individual frees, and all borrowers must have stopped
// using the Adam. Once destruction begins, optimizer/storage borrows are invalid
// even if a free fails. Successful frees are remembered and later calls retry only
// the remaining allocations. Reinitialization is allowed only after full destruction.
SequentialOwnedAdamDestroy :: proc(owned: ^SequentialOwnedAdam) -> bool {
	if owned == nil || (owned.self != nil && owned.self != rawptr(owned)) { return false }
	if owned.self == nil && owned.pending == ([3]rawptr{}) { return true }
	if !owned.destroying {
		owned.destroying = true
		owned.optimizer = {}
	}
	pendingPresent := owned.pending != ([3]rawptr{})
	if !sequentialOwnedAdamReleasePending(owned) { return false }
	if pendingPresent {
		owned^ = {}
		return true
	}
	if raw_data(owned.secondMoment) != nil {
		if mem.free(rawptr(raw_data(owned.secondMoment)), owned.allocator) != nil { return false }
		owned.secondMoment = nil
	}
	if raw_data(owned.firstMoment) != nil {
		if mem.free(rawptr(raw_data(owned.firstMoment)), owned.allocator) != nil { return false }
		owned.firstMoment = nil
	}
	if raw_data(owned.parameterStorage) != nil {
		if mem.free(rawptr(raw_data(owned.parameterStorage)), owned.allocator) != nil { return false }
		owned.parameterStorage = nil
	}
	owned^ = {}
	return true
}
