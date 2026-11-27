package nn

import "core:mem"

// Optional heap ownership for a Sequential with the same compile-time capacities.
// Start with a zero-valued handle and initialize it at its final address; destroy
// it before that address goes out of scope. Do not copy, move, overwrite, or edit
// the fields of a live handle, or free its model by other means. An address guard
// rejects ordinary copies/moves, but cannot prevent overwriting the original,
// field tampering, use of dangling pointers, or reuse of the same address.
//
// The allocated model is initialized in its final location and must not be copied
// or moved. OwnedSequentialModel returns a borrow, not a second owner. The model,
// its nodes, tensors and SequentialPredict output, compiled configurations, Adam
// bindings/workspaces, PPO bindings, and any other pointers or slices into it must
// not be used after successful destruction. Discard/rebind dependent objects
// before reuse, even if a later allocation happens to have the same address.
// Existing model APIs' rules for reinitialization, architecture changes, scratch
// invalidation, disjointness and concurrent access still apply. Layer storage is
// initialized in place, but heap ownership does not eliminate stack scratch in
// other model, fit, optimizer, and checkpoint APIs; size capacities accordingly.
// This handle does not own external optimizer, data, or scratch storage. Externally
// synchronize operations on the owner, model, and borrowers; a shared allocator
// must itself support any concurrent use.
//
// The allocator's backing data must remain valid, and address-sensitive state
// must remain unmoved, through rollback or destruction. It must return storage
// of the requested size and alignment, disjoint from the handle and other live
// objects, and support individual .Free calls that actually free allocations.
// Do not externally free/reset its storage. If an allocator returns
// both a pointer and an error, that pointer must be independently freeable. If a
// failed initialization's rollback free reports an error, the allocation is
// retained in a cleanup-only state and Destroy must be retried. A failed destroy
// keeps its allocation for retry, so a failed .Free must leave it intact if the
// caller will continue using it. Panicking, invalid, or nonconforming allocators
// are outside this contract.
OwnedSequential :: struct($maxLayers, $maxWidth, $batchCapacity: int) {
	model: ^Sequential(maxLayers, maxWidth, batchCapacity),
	allocator: mem.Allocator,
	self: rawptr,
	pending: rawptr,
	destroying: bool,
}

// Allocates and initializes a vector-input model. The allocator defaults to the
// current context.allocator and is retained for destruction, even if the context
// later changes. seed=0 has the same meaning as in SequentialInit. Ordinary failure
// leaves the handle unchanged and reusable; if rollback cleanup itself fails, the
// handle retains that allocation in a cleanup-only state and must be passed to
// OwnedSequentialDestroy. Nil, copied/moved live, cleanup-pending, and already-live
// handles are rejected. After successful destruction it may be initialized again.
OwnedSequentialInit :: proc(
	owner: ^OwnedSequential($maxLayers, $maxWidth, $batchCapacity),
	inputWidth: int,
	seed: u64 = 1,
	allocator: mem.Allocator = context.allocator,
) -> bool {
	return ownedSequentialInit(owner, inputWidth, 0, 0, false, seed, allocator)
}

// Allocates and initializes an NHWC spatial-input model, with the dimensions and
// bounds accepted by SequentialInitSpatial. Ownership, allocator, seed and
// failure semantics are identical to OwnedSequentialInit.
OwnedSequentialInitSpatial :: proc(
	owner: ^OwnedSequential($maxLayers, $maxWidth, $batchCapacity),
	height, width, channels: int,
	seed: u64 = 1,
	allocator: mem.Allocator = context.allocator,
) -> bool {
	return ownedSequentialInit(owner, height, width, channels, true, seed, allocator)
}

@(private="file")
ownedSequentialRollback :: proc(owner: ^OwnedSequential($maxLayers, $maxWidth, $batchCapacity)) -> bool {
	if mem.free(owner.pending, owner.allocator) != nil { return false }
	owner^ = {}
	return true
}

@(private="file")
ownedSequentialInit :: proc(
	owner: ^OwnedSequential($maxLayers, $maxWidth, $batchCapacity),
	a, b, c: int,
	spatial: bool,
	seed: u64,
	allocator: mem.Allocator,
) -> bool {
	if owner == nil || owner.model != nil || owner.self != nil || owner.pending != nil || owner.destroying { return false }
	Model :: Sequential(maxLayers, maxWidth, batchCapacity)
	storage, err := mem.alloc(size_of(Model), align_of(Model), allocator)
	if storage == nil { return false }
	owner.allocator = allocator
	owner.pending = storage
	owner.self = rawptr(owner)
	owner.destroying = true
	if err != nil { _ = ownedSequentialRollback(owner); return false }
	model := cast(^Model)storage
	initialized := false
	if spatial {
		initialized = SequentialInitSpatial(model, a, b, c, seed)
	} else {
		initialized = SequentialInit(model, a, seed)
	}
	if !initialized { _ = ownedSequentialRollback(owner); return false }
	owner.model = model
	owner.pending = nil
	owner.destroying = false
	return true
}

// Returns a borrowed model, or nil for nil, empty, copied/moved, destroying, or
// cleanup-pending handles. The guard does not validate already-issued borrows or
// the allocator's lifetime; see OwnedSequential for the full lifetime rules.
OwnedSequentialModel :: proc(owner: ^OwnedSequential($maxLayers, $maxWidth, $batchCapacity)) -> ^Sequential(maxLayers, maxWidth, batchCapacity) {
	if owner == nil || owner.self != rawptr(owner) || owner.model == nil || owner.pending != nil || owner.destroying { return nil }
	return owner.model
}

// Frees the live or cleanup-pending allocation using its original allocator and
// clears the handle. Returns true for a successful free or an already-empty handle;
// nil and copied/moved handles return false without freeing. Once destruction
// begins, model borrows are invalid even if the free fails. On a .Free error the
// handle remains cleanup-pending and a later call retries the same allocation.
OwnedSequentialDestroy :: proc(owner: ^OwnedSequential($maxLayers, $maxWidth, $batchCapacity)) -> bool {
	if owner == nil { return false }
	if owner.self == nil && owner.model == nil && owner.pending == nil { return true }
	if owner.self != rawptr(owner) { return false }
	owner.destroying = true
	memory := owner.pending
	if memory == nil { memory = rawptr(owner.model) }
	if memory == nil { owner^ = {}; return true }
	if mem.free(memory, owner.allocator) != nil { return false }
	owner^ = {}
	return true
}
