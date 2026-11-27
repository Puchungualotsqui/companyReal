package nn

import "core:mem"

// Optional ownership for PPOFitStorage only; models, optimizer, rollout, and RNG
// remain caller-owned. Initialize a zero-valued owner at its final address and
// destroy it before that address goes out of scope. Do not copy, move, overwrite,
// or edit a live owner. The address guard rejects ordinary copies/moves, but cannot
// detect field tampering, a stale copy restored to the same address, or dangling
// borrows. Synchronize the owner and all borrowers externally.
//
// The allocator and its state must remain valid and unmoved through rollback or
// destruction. The owner, allocator state, and allocated block must be mutually
// disjoint and disjoint from the rollout, models, optimizer, RNG, and other live
// objects, except for intended borrows. The allocator must provide the requested
// size and alignment and support individual frees. Every returned non-nil pointer,
// including one returned with an error, must be
// independently freeable. Do not externally free or reset its storage. A failed
// rollback free can leak because Init leaves the owner unchanged and cannot expose
// the allocation. A failed destroy is retryable only if the allocator guarantees
// that a reported free error leaves the allocation intact. Panicking or otherwise
// nonconforming allocators are outside this contract.
PPOOwnedFitStorage :: struct {
	storage:   PPOFitStorage,
	memory:    rawptr,
	allocator: mem.Allocator,
	self:      rawptr,
}

// Allocates one block containing all eight scratch slices, including epochMetrics.
// rolloutCapacity, observationWidth, actionCount, and epochs must be positive;
// batchSize must be nonnegative. Positive batchSize reserves min(batchSize,
// rolloutCapacity) rows. Like PPOFitConfig, zero selects the default batch size;
// because model capacities are unknown here, zero reserves rolloutCapacity rows,
// enough for any model capacities. For a tighter allocation, pass the known smaller
// model capacity explicitly. epochs is a capacity, not a default: PPO requires > 0.
//
// Indices cover rolloutCapacity; observation and mask slices cover the reserved
// rows times their respective widths; the other batch slices cover those rows;
// epochMetrics covers epochs. These are allocated lengths, not actual fit usage.
// A fit uses buffer.count, its effective batch size, actual widths, and requested
// epochs; only completed epoch entries are written. Reuse retains prior contents,
// including unused or unwritten metrics. Fit still validates all its own inputs,
// model capacities, lengths, and non-overlap requirements.
//
// The allocator defaults to context.allocator and is captured for destruction.
// Init rejects nil, live, and copied/moved owners. Failure leaves the owner
// unchanged and attempts to free any returned pointer once; leak-free rollback
// requires that free to succeed.
PPOOwnedFitStorageInit :: proc(
	owner: ^PPOOwnedFitStorage,
	rolloutCapacity, observationWidth, actionCount, batchSize, epochs: int,
	allocator: mem.Allocator = context.allocator,
) -> bool {
	if owner == nil || owner.self != nil || owner.memory != nil ||
		rolloutCapacity <= 0 || observationWidth <= 0 || actionCount <= 0 || batchSize < 0 || epochs <= 0 {
		return false
	}
	rows := rolloutCapacity
	if batchSize > 0 { rows = min(batchSize, rolloutCapacity) }
	if rows > max(int)/observationWidth || rows > max(int)/actionCount { return false }

	counts := [8]int{rolloutCapacity, rows*observationWidth, rows, rows*actionCount, rows, rows, rows, epochs}
	sizes := [8]int{size_of(int), size_of(f32), size_of(int), size_of(bool), size_of(f64), size_of(f32), size_of(f32), size_of(PPOEpochStats)}
	alignments := [8]int{align_of(int), align_of(f32), align_of(int), align_of(bool), align_of(f64), align_of(f32), align_of(f32), align_of(PPOEpochStats)}
	offsets: [8]int
	total, alignment := 0, 1
	for count, index in counts {
		itemAlignment := alignments[index]
		alignment = max(alignment, itemAlignment)
		padding := (itemAlignment-total%itemAlignment)%itemAlignment
		if total > max(int)-padding { return false }
		total += padding
		offsets[index] = total
		if count > (max(int)-total)/sizes[index] { return false }
		total += count*sizes[index]
	}

	bytes, err := mem.alloc_bytes(total, alignment, allocator)
	memory := rawptr(raw_data(bytes))
	if memory == nil { return false }
	committed := false
	defer if !committed { _ = mem.free(memory, allocator) }
	address, ownerAddress := uintptr(memory), uintptr(rawptr(owner))
	if err != nil || len(bytes) < total || address%uintptr(alignment) != 0 ||
		address > max(uintptr)-uintptr(total) || ownerAddress > max(uintptr)-uintptr(size_of(owner^)) ||
		PPOFitMemoryRangesOverlap({address, uintptr(total)}, {ownerAddress, uintptr(size_of(owner^))}) {
		return false
	}

	storage := PPOFitStorage{
		indices = mem.slice_ptr((^int)(rawptr(address+uintptr(offsets[0]))), counts[0]),
		observations = mem.slice_ptr((^f32)(rawptr(address+uintptr(offsets[1]))), counts[1]),
		actions = mem.slice_ptr((^int)(rawptr(address+uintptr(offsets[2]))), counts[2]),
		legalActions = mem.slice_ptr((^bool)(rawptr(address+uintptr(offsets[3]))), counts[3]),
		oldLogProbabilities = mem.slice_ptr((^f64)(rawptr(address+uintptr(offsets[4]))), counts[4]),
		advantages = mem.slice_ptr((^f32)(rawptr(address+uintptr(offsets[5]))), counts[5]),
		returns = mem.slice_ptr((^f32)(rawptr(address+uintptr(offsets[6]))), counts[6]),
		epochMetrics = mem.slice_ptr((^PPOEpochStats)(rawptr(address+uintptr(offsets[7]))), counts[7]),
	}
	owner^ = {storage, memory, allocator, rawptr(owner)}
	committed = true
	return true
}

// Returns a borrowed PPOFitStorage value and true, or ({}, false) for nil,
// uninitialized, destroyed, or copied/moved owners. Pass the value directly to
// SequentialPPOFit or SequentialPPOFitStateful. Changing the returned slice headers
// does not change the owner, but their contents are shared. Do not free the slices;
// all borrows become invalid after successful destruction, even if a later owner
// happens to reuse the same address. An already-issued borrow cannot be revoked.
PPOOwnedFitStorageView :: proc(owner: ^PPOOwnedFitStorage) -> (storage: PPOFitStorage, ok: bool) {
	if owner == nil || owner.self != rawptr(owner) || owner.memory == nil { return {}, false }
	return owner.storage, true
}

// Frees the block with its captured allocator and clears the owner. Empty owners
// succeed; nil and copied/moved live owners fail without freeing. A reported free
// error leaves the owner unchanged. Continue using or retrying it only if the
// allocator guarantees the allocation was retained; otherwise its state is
// ambiguous and the caller must use allocator-specific cleanup instead.
PPOOwnedFitStorageDestroy :: proc(owner: ^PPOOwnedFitStorage) -> bool {
	if owner == nil { return false }
	if owner.self == nil && owner.memory == nil { return true }
	if owner.self != rawptr(owner) || owner.memory == nil { return false }
	if mem.free(owner.memory, owner.allocator) != nil { return false }
	owner^ = {}
	return true
}
