package rl

import "core:mem"

// Optional ownership for one RolloutBuffer. Start with a zero-valued owner at
// its final address and destroy it before that address or the allocator state
// goes away. Do not copy, move, overwrite, or edit a live or cleanup-pending
// owner. The address guard rejects ordinary copies, but cannot detect a stale
// copy restored at the original address, field tampering, or dangling borrows.
// Externally synchronize the owner, allocator, and all borrowers.
//
// The allocator must supply the requested bytes and alignment, disjoint from
// the whole owner, its own state, and all other live objects. It must support
// individual frees, including for a non-nil pointer returned with an error.
// Its state must remain alive and unmoved, and its storage must not be reset or
// freed externally. Retry a failed free only if the allocator guarantees that
// the allocation remains intact. Panicking or otherwise invalid allocators are
// outside this contract. Init detects overlap with the owner and the address
// in allocator.data, but cannot determine the extent of allocator state or
// detect overlap with arbitrary other objects.
//
// If the requested extent, or the returned slice's larger claimed extent,
// overlaps the owner or allocator.data, the pointer is neither freed nor
// recorded: freeing it might destroy the owner or allocator state. A
// nonconforming allocator may already have overwritten them before returning;
// this cannot be undone and any cleanup is allocator-specific. The check
// cannot establish the actual extent or validity of allocator memory.
OwnedRolloutBuffer :: struct {
	buffer: RolloutBuffer,
	block:  ownedRolloutBlock,
}

// Optional ownership for a BatchedRolloutBuffer and its per-environment return
// scratch. Capacity is the total number of transitions across environments.
// OwnedRolloutBuffer's address, allocator, disjointness, synchronization, and
// failed-free contracts apply equally to this owner.
OwnedBatchedRolloutBuffer :: struct {
	buffer:  BatchedRolloutBuffer,
	scratch: BatchedRolloutReturnScratch,
	block:   ownedRolloutBlock,
}

@(private="file")
ownedRolloutBlock :: struct {
	memory:     rawptr,
	allocator:  mem.Allocator,
	self:       rawptr,
	destroying: bool,
}

@(private="file")
ownedRolloutLayout :: struct {
	counts, offsets: [14]int,
	total, alignment: int,
}

// Uses only fixed-size bookkeeping regardless of the requested dimensions.
@(private="file")
ownedRolloutMakeLayout :: proc(capacity, observationWidth, actionCount, environmentCount: int) -> (ownedRolloutLayout, bool) {
	if capacity <= 0 || observationWidth <= 0 || actionCount <= 0 || environmentCount < 0 ||
		capacity > max(int)/observationWidth || capacity > max(int)/actionCount {
		return {}, false
	}
	counts := [14]int{
		capacity*observationWidth, capacity, capacity, capacity, capacity,
		capacity, capacity*actionCount, capacity, capacity, capacity, capacity,
		0, 0, 0,
	}
	if environmentCount > 0 {
		counts[11], counts[12], counts[13] = capacity, environmentCount, environmentCount
	}
	sizes := [14]int{
		size_of(f32), size_of(int), size_of(f32), size_of(f32), size_of(f32),
		size_of(f64), size_of(bool), size_of(bool), size_of(bool), size_of(f32), size_of(f32),
		size_of(int), size_of(f64), size_of(bool),
	}
	alignments := [14]int{
		align_of(f32), align_of(int), align_of(f32), align_of(f32), align_of(f32),
		align_of(f64), align_of(bool), align_of(bool), align_of(bool), align_of(f32), align_of(f32),
		align_of(int), align_of(f64), align_of(bool),
	}
	layout := ownedRolloutLayout{counts = counts, alignment = 1}
	for count, index in counts {
		if count == 0 { continue }
		alignment := alignments[index]
		if alignment <= 0 || alignment & (alignment-1) != 0 { return {}, false }
		layout.alignment = max(layout.alignment, alignment)
		padding := (alignment-layout.total%alignment)%alignment
		if layout.total > max(int)-padding { return {}, false }
		layout.total += padding
		layout.offsets[index] = layout.total
		if count > (max(int)-layout.total)/sizes[index] { return {}, false }
		layout.total += count*sizes[index]
	}
	return layout, true
}

// Check the claimed allocation extent even if its address range wraps. A
// wrapping allocation cannot be used, but it must not be freed if it might
// overlap the owner or the allocator's data pointer.
@(private="file")
ownedRolloutOverlaps :: proc(address, bytes: uintptr, other: RolloutMemoryRange) -> bool {
	if bytes == 0 { return false }
	if address != 0 && bytes-1 > max(uintptr)-address {
		first := max(uintptr)-address+1
		return RolloutRangesOverlap({address, first}, other) || RolloutRangesOverlap({0, bytes-first}, other)
	}
	return RolloutRangesOverlap({address, bytes}, other)
}

// Installs a cleanup-pending block before validating allocator results, so a
// failed rollback can be retried. The caller must publish views only on success.
@(private="file")
ownedRolloutReserve :: proc(
	block: ^ownedRolloutBlock, owner: rawptr, ownerSize: int,
	layout: ownedRolloutLayout, allocator: mem.Allocator,
) -> rawptr {
	if block.self != nil || block.memory != nil || block.destroying ||
		uintptr(owner) > max(uintptr)-uintptr(ownerSize) {
		return nil
	}
	ownerRange := RolloutMemoryRange{uintptr(owner), uintptr(ownerSize)}
	if allocator.data != nil && RolloutRangesOverlap(ownerRange, {uintptr(allocator.data), 1}) {
		return nil
	}
	bytes, err := mem.alloc_bytes(layout.total, layout.alignment, allocator)
	memory := rawptr(raw_data(bytes))
	if memory == nil { return nil }
	address := uintptr(memory)
	extent := uintptr(max(layout.total, len(bytes)))
	if ownedRolloutOverlaps(address, extent, ownerRange) ||
		allocator.data != nil && ownedRolloutOverlaps(address, extent, {uintptr(allocator.data), 1}) {
		return nil
	}
	block^ = {memory = memory, allocator = allocator, self = owner, destroying = true}
	if err != nil || len(bytes) < layout.total || address%uintptr(layout.alignment) != 0 ||
		address > max(uintptr)-extent {
		_ = ownedRolloutRelease(block)
		return nil
	}
	return memory
}

@(private="file")
ownedRolloutRelease :: proc(block: ^ownedRolloutBlock) -> bool {
	if mem.free(block.memory, block.allocator) != nil { return false }
	block^ = {}
	return true
}

@(private="file")
ownedRolloutStorageAt :: proc(memory: rawptr, layout: ownedRolloutLayout) -> RolloutStorage {
	address := uintptr(memory)
	return {
		observations = mem.slice_ptr((^f32)(rawptr(address+uintptr(layout.offsets[0]))), layout.counts[0]),
		actions = mem.slice_ptr((^int)(rawptr(address+uintptr(layout.offsets[1]))), layout.counts[1]),
		rewards = mem.slice_ptr((^f32)(rawptr(address+uintptr(layout.offsets[2]))), layout.counts[2]),
		values = mem.slice_ptr((^f32)(rawptr(address+uintptr(layout.offsets[3]))), layout.counts[3]),
		nextValues = mem.slice_ptr((^f32)(rawptr(address+uintptr(layout.offsets[4]))), layout.counts[4]),
		oldLogProbabilities = mem.slice_ptr((^f64)(rawptr(address+uintptr(layout.offsets[5]))), layout.counts[5]),
		legalActions = mem.slice_ptr((^bool)(rawptr(address+uintptr(layout.offsets[6]))), layout.counts[6]),
		terminated = mem.slice_ptr((^bool)(rawptr(address+uintptr(layout.offsets[7]))), layout.counts[7]),
		truncated = mem.slice_ptr((^bool)(rawptr(address+uintptr(layout.offsets[8]))), layout.counts[8]),
		advantages = mem.slice_ptr((^f32)(rawptr(address+uintptr(layout.offsets[9]))), layout.counts[9]),
		returns = mem.slice_ptr((^f32)(rawptr(address+uintptr(layout.offsets[10]))), layout.counts[10]),
	}
}

// Allocates one block for all transition arrays and initializes the buffer in
// the owner's final location. Dimensions must be positive and all element,
// byte, padding, and address calculations must fit. The allocator defaults to
// context.allocator and is captured for cleanup. Nil, live, copied/moved, and
// cleanup-pending owners are rejected without replacing their allocations.
//
// On failure any returned block is freed, except for the unsafe overlap case
// described on OwnedRolloutBuffer. If that free fails, the owner retains the
// block in a cleanup-pending state: no borrow or reinitialization is permitted;
// call Destroy until it succeeds, subject to the allocator contract. Otherwise
// a failed Init leaves the zero-valued owner reusable. No data-sized stack
// arrays are used. See OwnedRolloutBufferBorrow for use and lifetime rules.
OwnedRolloutBufferInit :: proc(
	owner: ^OwnedRolloutBuffer, capacity, observationWidth, actionCount: int,
	allocator: mem.Allocator = context.allocator,
) -> bool {
	if owner == nil { return false }
	layout, ok := ownedRolloutMakeLayout(capacity, observationWidth, actionCount, 0)
	if !ok { return false }
	memory := ownedRolloutReserve(&owner.block, rawptr(owner), size_of(owner^), layout, allocator)
	if memory == nil { return false }
	storage := ownedRolloutStorageAt(memory, layout)
	if !RolloutBufferInit(&owner.buffer, storage, capacity, observationWidth, actionCount) {
		owner.buffer = {}
		_ = ownedRolloutRelease(&owner.block)
		return false
	}
	owner.block.destroying = false
	return true
}

// Borrows the in-place buffer, or nil for nil, empty, copied/moved, or cleanup-
// pending owners. Append, access, compute returns/GAE, normalize, scale, and
// reset using the existing RolloutBuffer APIs; they do not allocate. Reset
// preserves capacity and old bytes. Do not free or rebind the buffer or its
// slices, call RolloutBufferInit on it, or retain it or its slices after
// destruction begins. The guard cannot revoke an already-issued borrow.
// Existing transition input, disjointness, mutation, and concurrency rules
// still apply: notably, append inputs must not alias buffer storage. Keep
// other live objects and external training scratch disjoint from the entire
// owner and its allocation, not merely from the embedded buffer object.
OwnedRolloutBufferBorrow :: proc(owner: ^OwnedRolloutBuffer) -> ^RolloutBuffer {
	if owner == nil || owner.block.self != rawptr(owner) || owner.block.memory == nil || owner.block.destroying {
		return nil
	}
	return &owner.buffer
}

// Invalidates borrows, frees the block with the captured allocator, and clears
// the owner. Nil and copied/moved owners fail; an empty owner succeeds. If free
// fails, the owner remains cleanup-pending and later calls retry the same block.
// A failed free is retryable only if the allocator leaves the allocation intact.
OwnedRolloutBufferDestroy :: proc(owner: ^OwnedRolloutBuffer) -> bool {
	if owner == nil { return false }
	if owner.block.self == nil && owner.block.memory == nil && !owner.block.destroying { return true }
	if owner.block.self != rawptr(owner) || owner.block.memory == nil { return false }
	owner.block.destroying = true
	owner.buffer = {}
	if !ownedRolloutRelease(&owner.block) { return false }
	owner^ = {}
	return true
}

// Like OwnedRolloutBufferInit, but also allocates one environment index per
// transition and the two arrays required by BatchedRolloutComputeGAE and
// BatchedRolloutComputeDiscountedReturns. environmentCount must be positive.
// All failure, rollback, allocator, and final-address rules are identical.
OwnedBatchedRolloutBufferInit :: proc(
	owner: ^OwnedBatchedRolloutBuffer, capacity, environmentCount, observationWidth, actionCount: int,
	allocator: mem.Allocator = context.allocator,
) -> bool {
	if owner == nil || environmentCount <= 0 { return false }
	layout, ok := ownedRolloutMakeLayout(capacity, observationWidth, actionCount, environmentCount)
	if !ok { return false }
	memory := ownedRolloutReserve(&owner.block, rawptr(owner), size_of(owner^), layout, allocator)
	if memory == nil { return false }
	address := uintptr(memory)
	storage := BatchedRolloutStorage{
		transitions = ownedRolloutStorageAt(memory, layout),
		environmentIndices = mem.slice_ptr((^int)(rawptr(address+uintptr(layout.offsets[11]))), layout.counts[11]),
	}
	scratch := BatchedRolloutReturnScratch{
		followingValues = mem.slice_ptr((^f64)(rawptr(address+uintptr(layout.offsets[12]))), layout.counts[12]),
		hasFollowing = mem.slice_ptr((^bool)(rawptr(address+uintptr(layout.offsets[13]))), layout.counts[13]),
	}
	if !BatchedRolloutBufferInit(&owner.buffer, storage, capacity, environmentCount, observationWidth, actionCount) ||
		!BatchedRolloutReturnScratchDisjoint(&owner.buffer, scratch.followingValues, scratch.hasFollowing) {
		owner.buffer = {}
		_ = ownedRolloutRelease(&owner.block)
		return false
	}
	owner.scratch = scratch
	owner.block.destroying = false
	return true
}

// Borrows the in-place batched buffer; invalid owners return nil. Append in
// chronological order within each environment, use the batched return/GAE
// functions with OwnedBatchedRolloutBufferReturnScratch, and obtain the flat
// PPO training view with BatchedRolloutBufferTrainingView. Do not apply the
// single-stream return/GAE routines to interleaved rows. Reset with
// BatchedRolloutBufferReset. Borrow and input rules match the single owner;
// do not reinitialize or rebind the batched buffer or its embedded rollout.
OwnedBatchedRolloutBufferBorrow :: proc(owner: ^OwnedBatchedRolloutBuffer) -> ^BatchedRolloutBuffer {
	if owner == nil || owner.block.self != rawptr(owner) || owner.block.memory == nil || owner.block.destroying {
		return nil
	}
	return &owner.buffer
}

// Returns borrowed scratch for the batched return functions, or ({}, false)
// for an invalid owner. Both slices have environmentCount elements, are
// disjoint from each other and the owned buffer, and are reused by each pass.
// Do not free them, rebind the owner's scratch, or use any borrowed slice once
// destruction begins. Return computations may modify scratch even on failure.
OwnedBatchedRolloutBufferReturnScratch :: proc(owner: ^OwnedBatchedRolloutBuffer) -> (BatchedRolloutReturnScratch, bool) {
	if OwnedBatchedRolloutBufferBorrow(owner) == nil { return {}, false }
	return owner.scratch, true
}

// Same invalidation, retry, allocator, and idempotence rules as
// OwnedRolloutBufferDestroy. The training view and return scratch are borrows.
OwnedBatchedRolloutBufferDestroy :: proc(owner: ^OwnedBatchedRolloutBuffer) -> bool {
	if owner == nil { return false }
	if owner.block.self == nil && owner.block.memory == nil && !owner.block.destroying { return true }
	if owner.block.self != rawptr(owner) || owner.block.memory == nil { return false }
	owner.block.destroying = true
	owner.buffer = {}
	owner.scratch = {}
	if !ownedRolloutRelease(&owner.block) { return false }
	owner^ = {}
	return true
}
