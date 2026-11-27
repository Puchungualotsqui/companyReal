package nn

import "../core"
import "core:mem"

// Owns only the shared Adam's parameter-pointer and moment buffers, not the
// policy or value models. Initialize a zero-valued owner at its final address;
// do not copy, move, overwrite, or edit a live owner. The address guard rejects
// ordinary copies, but cannot detect a stale copy written back to its original
// address, field tampering, dangling model pointers, or already-issued borrows.
// Both models, rebound parameter data/gradients, allocator state, and the owner
// must remain alive and unmoved while Adam or any borrower is in use. Stop all
// borrowers before destruction or model changes. Externally synchronize access.
PPOOwnedAdam :: struct {
	optimizer: Adam,
	parameterStorage: []^core.Node,
	firstMoment, secondMoment: []f32,
	allocator: mem.Allocator,
	self: rawptr,
	destroying: bool,
}

// Allocates exactly the combined SequentialAdamRequirements, in policy-then-
// value order. The independently typed models must be valid and disjoint, have
// matching input widths and rank-2 outputs, with a scalar value output and no
// terminal policy softmax (including through dropout/flatten). Rebound parameter
// data and gradients must be disjoint from both models, the owner, and each other,
// except for their own model's original inline parameter storage. Parameter-free
// nonempty models are supported without unnecessary allocations, but PPO training
// and PPO checkpoints currently require parameters in *each* model. This is not a
// substitute for the other validation and disjointness rules of those APIs.
//
// The allocator defaults to context.allocator and is retained for destruction.
// It must return aligned, independently freeable allocations disjoint from the
// owner, models, rebound buffers, allocator state, and one another. Its state must
// remain alive and unmoved. A pointer returned with an error must be freeable;
// rollback frees must succeed to avoid leaks. A failed destroy free must leave its
// allocation intact for retry. Invalid/nonconforming allocators are outside this
// contract. Failure leaves the owner and models unchanged; a live, destroying, or
// copied owner cannot be reinitialized. Success resets Adam's step and moments.
// Except for a compatible PPO checkpoint restore, destroy before changing model
// architecture, reinitializing a model, or rebinding parameter buffers; then
// initialize again and discard/rebind any consumers of the old optimizer.
PPOOwnedAdamInit :: proc(
	owner: ^PPOOwnedAdam,
	policy: ^Sequential($policyMaxLayers, $policyMaxWidth, $policyBatchCapacity),
	value: ^Sequential($valueMaxLayers, $valueMaxWidth, $valueBatchCapacity),
	learningRate: f32 = 0.001, beta1: f32 = 0.9, beta2: f32 = 0.999, epsilon: f32 = 1e-8,
	allocator: mem.Allocator = context.allocator,
) -> bool {
	if owner == nil || policy == nil || value == nil { return false }
	ranges: [6]SequentialAdamMemoryRange
	valid: bool
	ranges[0], valid = SequentialAdamRange(rawptr(policy), 1, size_of(policy^)); if !valid { return false }
	ranges[1], valid = SequentialAdamRange(rawptr(value), 1, size_of(value^)); if !valid { return false }
	ranges[2], valid = SequentialAdamRange(rawptr(owner), 1, size_of(owner^)); if !valid { return false }
	for range, index in ranges[:3] {
		for previous in ranges[:index] { if SequentialAdamRangesOverlap(range, previous) { return false } }
	}
	if owner.self != nil { return false }
	candidate := Adam{learningRate = learningRate, beta1 = beta1, beta2 = beta2, epsilon = epsilon}
	if !AdamConfigValid(&candidate) { return false }

	policyCount, policyElements, policyOk := SequentialAdamRequirements(policy)
	valueCount, valueElements, valueOk := SequentialAdamRequirements(value)
	if !policyOk || !valueOk || policy.inputWidth != value.inputWidth ||
		value.layers[value.layerCount-1].width != 1 ||
		len(policy.layers[policy.layerCount-1].output.value.shape) != 2 ||
		policy.layers[policy.layerCount-1].output.value.shape[1] != policy.layers[policy.layerCount-1].width ||
		len(value.layers[value.layerCount-1].output.value.shape) != 2 ||
		value.layers[value.layerCount-1].output.value.shape[1] != 1 {
		return false
	}
	if _, isSoftmax := SequentialLogitsOutputLayer(policy).(^Softmax); isSoftmax { return false }
	if policyCount > max(int)-valueCount || policyElements > max(int)-valueElements { return false }
	count, elements := policyCount+valueCount, policyElements+valueElements
	if count > max(int)/size_of(^core.Node) || elements > max(int)/size_of(f32) { return false }

	parameterScratch: [2*(policyMaxLayers+valueMaxLayers)]^core.Node
	policyParameters, policyListOk := SequentialParameters(policy, parameterScratch[:])
	if !policyListOk || len(policyParameters) != policyCount { return false }
	valueParameters, valueListOk := SequentialParameters(value, parameterScratch[policyCount:])
	if !valueListOk || len(valueParameters) != valueCount { return false }
	parameters := parameterScratch[:count]
	for parameter, index in parameters {
		for previous in parameters[:index] {
			if parameter == previous || core.BuffersOverlap(parameter.value, previous.value) ||
				core.BuffersOverlap(parameter.value, previous.grad) || core.BuffersOverlap(parameter.grad, previous.value) ||
				core.BuffersOverlap(parameter.grad, previous.grad) { return false }
		}
		otherModel := ranges[0]
		if index < policyCount { otherModel = ranges[1] }
		for tensor in ([2]core.Tensor{parameter.value, parameter.grad}) {
			dataRange, dataValid := SequentialAdamRange(rawptr(raw_data(tensor.data)), len(tensor.data), size_of(f32))
			if !dataValid || SequentialAdamRangesOverlap(dataRange, otherModel) ||
				SequentialAdamRangesOverlap(dataRange, ranges[2]) { return false }
		}
	}

	parameterMemory, firstMemory, secondMemory: rawptr
	committed := false
	defer if !committed {
		mem.free(secondMemory, allocator)
		mem.free(firstMemory, allocator)
		mem.free(parameterMemory, allocator)
	}
	if count > 0 {
		err: mem.Allocator_Error
		parameterMemory, err = mem.alloc(count*size_of(^core.Node), align_of(^core.Node), allocator)
		if err != nil || parameterMemory == nil { return false }
	}
	if elements > 0 {
		err: mem.Allocator_Error
		firstMemory, err = mem.alloc(elements*size_of(f32), align_of(f32), allocator)
		if err != nil || firstMemory == nil { return false }
		secondMemory, err = mem.alloc(elements*size_of(f32), align_of(f32), allocator)
		if err != nil || secondMemory == nil { return false }
	}
	ranges[3], valid = SequentialAdamRange(parameterMemory, count, size_of(^core.Node)); if !valid { return false }
	ranges[4], valid = SequentialAdamRange(firstMemory, elements, size_of(f32)); if !valid { return false }
	ranges[5], valid = SequentialAdamRange(secondMemory, elements, size_of(f32)); if !valid { return false }
	for range, index in ranges[3:] {
		for previous in ranges[:index+3] { if SequentialAdamRangesOverlap(range, previous) { return false } }
	}
	for parameter in parameters {
		for tensor in ([2]core.Tensor{parameter.value, parameter.grad}) {
			dataRange, dataValid := SequentialAdamRange(rawptr(raw_data(tensor.data)), len(tensor.data), size_of(f32))
			if !dataValid { return false }
			for range in ranges[3:] { if SequentialAdamRangesOverlap(dataRange, range) { return false } }
		}
	}

	parameterStorage: []^core.Node
	firstMoment, secondMoment: []f32
	if count > 0 { parameterStorage = mem.slice_ptr((^^core.Node)(parameterMemory), count) }
	if elements > 0 {
		firstMoment = mem.slice_ptr((^f32)(firstMemory), elements)
		secondMoment = mem.slice_ptr((^f32)(secondMemory), elements)
	}
	copy(parameterStorage, parameters)
	if !AdamInit(&candidate, parameterStorage, firstMoment, secondMoment, learningRate, beta1, beta2, epsilon) { return false }
	owner.optimizer = candidate
	owner.parameterStorage, owner.firstMoment, owner.secondMoment = parameterStorage, firstMoment, secondMoment
	owner.allocator, owner.self = allocator, rawptr(owner)
	committed = true
	return true
}

// Returns the in-place Adam for SequentialPPOTrainStep, SequentialPPOFit and
// checkpoint APIs, or nil for a nil, empty, copied, or destroying owner. This
// borrow becomes invalid when destruction begins. Do not rebind Adam's buffers
// or parameters except through a compatible PPO checkpoint restore.
PPOOwnedAdamOptimizer :: proc(owner: ^PPOOwnedAdam) -> ^Adam {
	if owner == nil || owner.self != rawptr(owner) || owner.destroying { return nil }
	return &owner.optimizer
}

// Returns the full borrowed allocations for PPOCheckpointRead (or its normalized
// variant), or (nil, nil, nil, false) for an invalid owner. Do not free the slices
// or manually alter the parameter list. Build both destination models at their
// final addresses with enough parameter and element capacity, initialize their
// owner, and pass those same models, these slices and PPOOwnedAdamOptimizer(owner)
// to PPOCheckpointRead.
// The model type capacities must match the checkpoint. A successful read replaces
// both models, restores Adam's binding, step, hyperparameters and moments, and
// replaces rebound parameter data with inline storage. The accessor still exposes
// the full allocations after restoring a smaller architecture; its unused pointer
// tail may be stale, so use Adam.parameters for the active binding. Input, state,
// normalizers and checkpoint scratch must be disjoint from the *entire* owner as
// well as the models and owned buffers. Follow the checkpoint API's other rules;
// discard/rebind any dependent handles after a restore. Do not reinitialize Adam
// after a successful restore, since doing so would reset the restored state.
PPOOwnedAdamStorage :: proc(owner: ^PPOOwnedAdam) -> (parameters: []^core.Node, first, second: []f32, ok: bool) {
	if owner == nil || owner.self != rawptr(owner) || owner.destroying { return nil, nil, nil, false }
	return owner.parameterStorage, owner.firstMoment, owner.secondMoment, true
}

// Frees the original allocations with the captured allocator. A nil or copied
// owner returns false; repeated destruction of a zero/destroyed owner succeeds.
// Once destruction starts, optimizer and storage borrows are invalid, even if a
// free fails. Successful frees are remembered and a later call retries only the
// remaining allocations. Reinitialization is allowed only after full destruction.
PPOOwnedAdamDestroy :: proc(owner: ^PPOOwnedAdam) -> bool {
	if owner == nil || (owner.self != nil && owner.self != rawptr(owner)) { return false }
	if owner.self == nil { return true }
	if !owner.destroying {
		owner.destroying = true
		owner.optimizer = {}
	}
	if raw_data(owner.secondMoment) != nil {
		if mem.free(rawptr(raw_data(owner.secondMoment)), owner.allocator) != nil { return false }
		owner.secondMoment = nil
	}
	if raw_data(owner.firstMoment) != nil {
		if mem.free(rawptr(raw_data(owner.firstMoment)), owner.allocator) != nil { return false }
		owner.firstMoment = nil
	}
	if raw_data(owner.parameterStorage) != nil {
		if mem.free(rawptr(raw_data(owner.parameterStorage)), owner.allocator) != nil { return false }
		owner.parameterStorage = nil
	}
	owner^ = {}
	return true
}
