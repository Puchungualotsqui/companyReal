package rl

import "core:mem"
import "core:testing"

OwnedRolloutTestLayout :: proc(
	t: ^testing.T, storage: RolloutStorage, environmentIndices: []int,
	scratch: BatchedRolloutReturnScratch, state: ^OwnedRolloutTestAllocator,
	owner: rawptr, ownerSize: int,
) {
	addresses := [14]uintptr{
		uintptr(raw_data(storage.observations)), uintptr(raw_data(storage.actions)),
		uintptr(raw_data(storage.rewards)), uintptr(raw_data(storage.values)), uintptr(raw_data(storage.nextValues)),
		uintptr(raw_data(storage.oldLogProbabilities)), uintptr(raw_data(storage.legalActions)),
		uintptr(raw_data(storage.terminated)), uintptr(raw_data(storage.truncated)),
		uintptr(raw_data(storage.advantages)), uintptr(raw_data(storage.returns)),
		uintptr(raw_data(environmentIndices)), uintptr(raw_data(scratch.followingValues)), uintptr(raw_data(scratch.hasFollowing)),
	}
	counts := [14]int{
		len(storage.observations), len(storage.actions), len(storage.rewards), len(storage.values), len(storage.nextValues),
		len(storage.oldLogProbabilities), len(storage.legalActions), len(storage.terminated), len(storage.truncated),
		len(storage.advantages), len(storage.returns), len(environmentIndices), len(scratch.followingValues), len(scratch.hasFollowing),
	}
	sizes := [14]int{
		size_of(f32), size_of(int), size_of(f32), size_of(f32), size_of(f32), size_of(f64), size_of(bool),
		size_of(bool), size_of(bool), size_of(f32), size_of(f32), size_of(int), size_of(f64), size_of(bool),
	}
	alignments := [14]int{
		align_of(f32), align_of(int), align_of(f32), align_of(f32), align_of(f32), align_of(f64), align_of(bool),
		align_of(bool), align_of(bool), align_of(f32), align_of(f32), align_of(int), align_of(f64), align_of(bool),
	}
	base := uintptr(state.returned)
	block := RolloutMemoryRange{base, uintptr(state.lastSize)}
	ownerRange := RolloutMemoryRange{uintptr(owner), uintptr(ownerSize)}
	testing.expect(t, state.returned != nil && state.lastAlignment >= align_of(f64) && base%uintptr(state.lastAlignment) == 0 &&
		!RolloutRangesOverlap(block, ownerRange) && !RolloutRangesOverlap(block, {uintptr(state), 1}))
	for address, index in addresses {
		if counts[index] == 0 { continue }
		bytes := uintptr(counts[index]*sizes[index])
		testing.expect(t, address%uintptr(alignments[index]) == 0 && address >= base &&
			address-base <= uintptr(state.lastSize) && bytes <= uintptr(state.lastSize)-(address-base) &&
			!RolloutRangesOverlap({address, bytes}, ownerRange))
		for previous in 0..<index {
			if counts[previous] == 0 { continue }
			other := RolloutMemoryRange{addresses[previous], uintptr(counts[previous]*sizes[previous])}
			testing.expect(t, !RolloutRangesOverlap({address, bytes}, other))
		}
	}
}

@(test)
OwnedRolloutAlignedDisjointStorage :: proc(t: ^testing.T) {
	state := OwnedRolloutTestAllocator{backing = context.allocator}
	owner: OwnedRolloutBuffer
	ok := OwnedRolloutBufferInit(&owner, 3, 3, 5, OwnedRolloutTestAllocatorFor(&state))
	testing.expect(t, ok)
	if !ok { return }
	defer OwnedRolloutBufferDestroy(&owner)
	buffer := OwnedRolloutBufferBorrow(&owner)
	testing.expect(t, buffer != nil && RolloutStorageDisjoint(buffer.storage))
	if buffer == nil { return }
	testing.expect(t, len(buffer.storage.observations) == 9 && len(buffer.storage.actions) == 3 &&
		len(buffer.storage.legalActions) == 15 && len(buffer.storage.oldLogProbabilities) == 3)
	OwnedRolloutTestLayout(t, buffer.storage, nil, {}, &state, rawptr(&owner), size_of(owner))

	batchedState := OwnedRolloutTestAllocator{backing = context.allocator}
	batchedOwner: OwnedBatchedRolloutBuffer
	ok = OwnedBatchedRolloutBufferInit(&batchedOwner, 3, 7, 3, 5, OwnedRolloutTestAllocatorFor(&batchedState))
	testing.expect(t, ok)
	if !ok { return }
	defer OwnedBatchedRolloutBufferDestroy(&batchedOwner)
	batch := OwnedBatchedRolloutBufferBorrow(&batchedOwner)
	scratch, scratchOk := OwnedBatchedRolloutBufferReturnScratch(&batchedOwner)
	testing.expect(t, batch != nil && scratchOk)
	if batch == nil || !scratchOk { return }
	testing.expect(t, len(batch.environmentIndices) == 3 && len(scratch.followingValues) == 7 && len(scratch.hasFollowing) == 7 &&
		BatchedRolloutStorageDisjoint(batch.rollout.storage, batch.environmentIndices) &&
		BatchedRolloutReturnScratchDisjoint(batch, scratch.followingValues, scratch.hasFollowing))
	OwnedRolloutTestLayout(t, batch.rollout.storage, batch.environmentIndices, scratch, &batchedState, rawptr(&batchedOwner), size_of(batchedOwner))
}

@(test)
OwnedRolloutRejectsInvalidDimensionsBeforeAllocating :: proc(t: ^testing.T) {
	state := OwnedRolloutTestAllocator{backing = context.allocator}
	allocator := OwnedRolloutTestAllocatorFor(&state)
	owner: OwnedRolloutBuffer
	batch: OwnedBatchedRolloutBuffer
	cases := [11][3]int{
		{0, 1, 1}, {-1, 1, 1}, {1, 0, 1}, {1, -1, 1}, {1, 1, 0}, {1, 1, -1},
		{max(int), 2, 1}, {max(int), 1, 2},
		{1, max(int)/size_of(f32)+1, 1},
		{1, max(int)/size_of(f32), 1},
		{max(int)/size_of(f64), 1, 1},
	}
	for dimensions in cases {
		testing.expect(t, !OwnedRolloutBufferInit(&owner, dimensions[0], dimensions[1], dimensions[2], allocator))
		testing.expect(t, !OwnedBatchedRolloutBufferInit(&batch, dimensions[0], 2, dimensions[1], dimensions[2], allocator))
	}
	for environments in ([5]int{0, -1, max(int), max(int)/size_of(f64)+1, max(int)/size_of(f64)}) {
		testing.expect(t, !OwnedBatchedRolloutBufferInit(&batch, 1, environments, 1, 1, allocator))
	}
	testing.expect(t, !OwnedRolloutBufferInit(nil, 1, 1, 1, allocator) &&
		!OwnedBatchedRolloutBufferInit(nil, 1, 1, 1, 1, allocator) && state.attempts == 0 &&
		OwnedRolloutBufferBorrow(&owner) == nil && OwnedBatchedRolloutBufferBorrow(&batch) == nil &&
		OwnedRolloutBufferDestroy(&owner) && OwnedBatchedRolloutBufferDestroy(&batch))
	testing.expect(t, !OwnedRolloutBufferInit(&owner, 1, 1, 1, mem.Allocator{}) &&
		!OwnedBatchedRolloutBufferInit(&batch, 1, 1, 1, 1, mem.nil_allocator()))
}

@(test)
OwnedRolloutAllocationFailuresRollback :: proc(t: ^testing.T) {
	for mode in ([6]OwnedRolloutTestAllocation{.Nil, .Error, .PointerAndError, .Short, .Misaligned, .Wrapped}) {
		state := OwnedRolloutTestAllocator{backing = context.allocator, mode = mode}
		allocator := OwnedRolloutTestAllocatorFor(&state)
		owner: OwnedRolloutBuffer
		testing.expect(t, !OwnedRolloutBufferInit(&owner, 3, 2, 3, allocator) && state.attempts == 1)
		expectedFrees := 1
		if mode == .Nil || mode == .Error { expectedFrees = 0 }
		testing.expect(t, state.returned == nil && state.freeCalls == expectedFrees && state.successfulFrees == expectedFrees &&
			state.badFrees == 0 && OwnedRolloutBufferBorrow(&owner) == nil && OwnedRolloutBufferDestroy(&owner))
		state.mode = .Normal
		ok := OwnedRolloutBufferInit(&owner, 3, 2, 3, allocator)
		testing.expect(t, ok && OwnedRolloutBufferBorrow(&owner) != nil)
		if ok { testing.expect(t, OwnedRolloutBufferDestroy(&owner)) }
		testing.expect(t, state.returned == nil && state.badFrees == 0)

		batchState := OwnedRolloutTestAllocator{backing = context.allocator, mode = mode}
		batchAllocator := OwnedRolloutTestAllocatorFor(&batchState)
		batch: OwnedBatchedRolloutBuffer
		testing.expect(t, !OwnedBatchedRolloutBufferInit(&batch, 3, 4, 2, 3, batchAllocator) && batchState.attempts == 1)
		_, scratchOk := OwnedBatchedRolloutBufferReturnScratch(&batch)
		testing.expect(t, batchState.returned == nil && batchState.freeCalls == expectedFrees && batchState.successfulFrees == expectedFrees &&
			batchState.badFrees == 0 && OwnedBatchedRolloutBufferBorrow(&batch) == nil && !scratchOk && OwnedBatchedRolloutBufferDestroy(&batch))
		batchState.mode = .Normal
		ok = OwnedBatchedRolloutBufferInit(&batch, 3, 4, 2, 3, batchAllocator)
		testing.expect(t, ok && OwnedBatchedRolloutBufferBorrow(&batch) != nil)
		if ok { testing.expect(t, OwnedBatchedRolloutBufferDestroy(&batch)) }
		testing.expect(t, batchState.returned == nil && batchState.badFrees == 0)
	}
}

@(test)
OwnedRolloutRollbackFreeFailuresAreRecoverable :: proc(t: ^testing.T) {
	for mode in ([4]OwnedRolloutTestAllocation{.PointerAndError, .Short, .Misaligned, .Wrapped}) {
		state := OwnedRolloutTestAllocator{backing = context.allocator, mode = mode, failNextFree = true}
		allocator := OwnedRolloutTestAllocatorFor(&state)
		owner: OwnedRolloutBuffer
		testing.expect(t, !OwnedRolloutBufferInit(&owner, 3, 2, 3, allocator))
		retained := state.returned
		copyOfOwner := owner
		testing.expect(t, retained != nil && state.freeCalls == 1 && state.successfulFrees == 0 &&
			OwnedRolloutBufferBorrow(&owner) == nil && !OwnedRolloutBufferInit(&owner, 3, 2, 3, allocator) &&
			OwnedRolloutBufferBorrow(&copyOfOwner) == nil && !OwnedRolloutBufferDestroy(&copyOfOwner) && state.attempts == 1)
		destroyed := false
		{
			context.allocator = mem.nil_allocator()
			destroyed = OwnedRolloutBufferDestroy(&owner)
		}
		testing.expect(t, destroyed && state.returned == nil && state.freeCalls == 2 && state.successfulFrees == 1 &&
			state.badFrees == 0 && OwnedRolloutBufferDestroy(&owner))

		batchState := OwnedRolloutTestAllocator{backing = context.allocator, mode = mode, failNextFree = true}
		batchAllocator := OwnedRolloutTestAllocatorFor(&batchState)
		batch: OwnedBatchedRolloutBuffer
		testing.expect(t, !OwnedBatchedRolloutBufferInit(&batch, 3, 4, 2, 3, batchAllocator))
		batchCopy := batch
		_, scratchOk := OwnedBatchedRolloutBufferReturnScratch(&batch)
		testing.expect(t, batchState.returned != nil && batchState.freeCalls == 1 && batchState.successfulFrees == 0 &&
			OwnedBatchedRolloutBufferBorrow(&batch) == nil && !scratchOk &&
			!OwnedBatchedRolloutBufferInit(&batch, 3, 4, 2, 3, batchAllocator) &&
			!OwnedBatchedRolloutBufferDestroy(&batchCopy) && batchState.attempts == 1)
		{
			context.allocator = mem.nil_allocator()
			destroyed = OwnedBatchedRolloutBufferDestroy(&batch)
		}
		testing.expect(t, destroyed && batchState.returned == nil && batchState.freeCalls == 2 && batchState.successfulFrees == 1 &&
			batchState.badFrees == 0 && OwnedBatchedRolloutBufferDestroy(&batch))
	}
}

@(test)
OwnedRolloutRejectsOverlappingAllocatorMemory :: proc(t: ^testing.T) {
	for variant in 0..<4 {
		owner: OwnedRolloutBuffer
		state := OwnedRolloutTestAllocator{backing = context.allocator, mode = .Alias}
		state.alias = rawptr(&owner)
		if variant == 1 { state.alias = rawptr(uintptr(rawptr(&owner))-8) }
		if variant == 2 { state.alias = rawptr(&state) }
		if variant == 3 {
			// The requested prefix ends immediately before the owner, but the
			// allocator claims a larger slice extending into it.
			probeState := OwnedRolloutTestAllocator{backing = context.allocator}
			probe: OwnedRolloutBuffer
			probeOk := OwnedRolloutBufferInit(&probe, 2, 1, 2, OwnedRolloutTestAllocatorFor(&probeState))
			testing.expect(t, probeOk)
			if !probeOk { return }
			size := probeState.lastSize
			testing.expect(t, OwnedRolloutBufferDestroy(&probe))
			state.alias = rawptr(uintptr(rawptr(&owner))-uintptr(size))
			state.aliasLength = size+8
		}
		allocator := OwnedRolloutTestAllocatorFor(&state)
		testing.expect(t, !OwnedRolloutBufferInit(&owner, 2, 1, 2, allocator) && state.attempts == 1 && state.freeCalls == 0 &&
			OwnedRolloutBufferBorrow(&owner) == nil && OwnedRolloutBufferDestroy(&owner))
	}
	for variant in 0..<3 {
		owner: OwnedBatchedRolloutBuffer
		state := OwnedRolloutTestAllocator{backing = context.allocator, mode = .Alias}
		state.alias = rawptr(&owner)
		if variant == 1 { state.alias = rawptr(uintptr(rawptr(&owner))-8) }
		if variant == 2 { state.alias = rawptr(&state) }
		testing.expect(t, !OwnedBatchedRolloutBufferInit(&owner, 2, 2, 1, 2, OwnedRolloutTestAllocatorFor(&state)) &&
			state.attempts == 1 && state.freeCalls == 0 && OwnedBatchedRolloutBufferBorrow(&owner) == nil &&
			OwnedBatchedRolloutBufferDestroy(&owner))
	}
	owner: OwnedRolloutBuffer
	batch: OwnedBatchedRolloutBuffer
	// Allocator data pointing inside the owner is rejected before calling it.
	testing.expect(t, !OwnedRolloutBufferInit(&owner, 1, 1, 1, {procedure = OwnedRolloutTestAllocatorProc, data = &owner}) &&
		!OwnedBatchedRolloutBufferInit(&batch, 1, 1, 1, 1, {procedure = OwnedRolloutTestAllocatorProc, data = &batch}))
}
