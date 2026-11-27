package rl

import "core:mem"
import "core:testing"

@(test)
OwnedRolloutCapturedAllocatorCopyAndDestroyRetry :: proc(t: ^testing.T) {
	state := OwnedRolloutTestAllocator{backing = context.allocator}
	allocator := OwnedRolloutTestAllocatorFor(&state)
	owner: OwnedRolloutBuffer
	initialized := false
	{
		context.allocator = allocator
		initialized = OwnedRolloutBufferInit(&owner, 2, 1, 2)
	}
	testing.expect(t, initialized)
	if !initialized { return }
	defer OwnedRolloutBufferDestroy(&owner)
	buffer := OwnedRolloutBufferBorrow(&owner)
	copyOfOwner := owner
	testing.expect(t, buffer != nil && OwnedRolloutBufferBorrow(&copyOfOwner) == nil &&
		!OwnedRolloutBufferDestroy(&copyOfOwner) && !OwnedRolloutBufferInit(&copyOfOwner, 2, 1, 2, allocator) &&
		!OwnedRolloutBufferInit(&owner, 2, 1, 2, allocator) && state.attempts == 1 && state.freeCalls == 0)
	if buffer == nil { return }
	testing.expect(t, RolloutTestAppend(buffer, 3, 1, 0, 0))
	state.failNextFree = true
	destroyed := true
	{
		context.allocator = mem.nil_allocator()
		destroyed = OwnedRolloutBufferDestroy(&owner)
	}
	testing.expect(t, !destroyed && state.returned != nil && state.freeCalls == 1 && state.successfulFrees == 0 &&
		OwnedRolloutBufferBorrow(&owner) == nil && !OwnedRolloutBufferInit(&owner, 2, 1, 2, allocator))
	{
		context.allocator = mem.nil_allocator()
		destroyed = OwnedRolloutBufferDestroy(&owner)
	}
	testing.expect(t, destroyed && state.returned == nil && state.freeCalls == 2 && state.successfulFrees == 1 && state.badFrees == 0 &&
		OwnedRolloutBufferDestroy(&owner) && !OwnedRolloutBufferDestroy(&copyOfOwner) && OwnedRolloutBufferBorrow(&copyOfOwner) == nil)
	{
		context.allocator = mem.nil_allocator()
		initialized = OwnedRolloutBufferInit(&owner, 1, 1, 1, allocator)
	}
	testing.expect(t, initialized && state.attempts == 2 && OwnedRolloutBufferBorrow(&owner) != nil)
	if initialized { testing.expect(t, OwnedRolloutBufferDestroy(&owner)) }
	testing.expect(t, state.successfulFrees == 2 && !OwnedRolloutBufferDestroy(nil) && OwnedRolloutBufferBorrow(nil) == nil)
}

@(test)
OwnedBatchedRolloutCapturedAllocatorCopyAndDestroyRetry :: proc(t: ^testing.T) {
	state := OwnedRolloutTestAllocator{backing = context.allocator}
	allocator := OwnedRolloutTestAllocatorFor(&state)
	owner: OwnedBatchedRolloutBuffer
	initialized := false
	{
		context.allocator = allocator
		initialized = OwnedBatchedRolloutBufferInit(&owner, 2, 3, 1, 2)
	}
	testing.expect(t, initialized)
	if !initialized { return }
	defer OwnedBatchedRolloutBufferDestroy(&owner)
	buffer := OwnedBatchedRolloutBufferBorrow(&owner)
	copyOfOwner := owner
	_, copyScratchOk := OwnedBatchedRolloutBufferReturnScratch(&copyOfOwner)
	testing.expect(t, buffer != nil && OwnedBatchedRolloutBufferBorrow(&copyOfOwner) == nil && !copyScratchOk &&
		!OwnedBatchedRolloutBufferDestroy(&copyOfOwner) && !OwnedBatchedRolloutBufferInit(&copyOfOwner, 2, 3, 1, 2, allocator) &&
		!OwnedBatchedRolloutBufferInit(&owner, 2, 3, 1, 2, allocator) && state.attempts == 1 && state.freeCalls == 0)
	if buffer == nil { return }
	testing.expect(t, BatchedRolloutTestAppend(buffer, 2, 3, 1, 0, 0))
	state.failNextFree = true
	destroyed := true
	{
		context.allocator = mem.nil_allocator()
		destroyed = OwnedBatchedRolloutBufferDestroy(&owner)
	}
	_, scratchOk := OwnedBatchedRolloutBufferReturnScratch(&owner)
	testing.expect(t, !destroyed && state.returned != nil && state.freeCalls == 1 && state.successfulFrees == 0 &&
		OwnedBatchedRolloutBufferBorrow(&owner) == nil && !scratchOk && !OwnedBatchedRolloutBufferInit(&owner, 2, 3, 1, 2, allocator))
	{
		context.allocator = mem.nil_allocator()
		destroyed = OwnedBatchedRolloutBufferDestroy(&owner)
	}
	testing.expect(t, destroyed && state.returned == nil && state.freeCalls == 2 && state.successfulFrees == 1 && state.badFrees == 0 &&
		OwnedBatchedRolloutBufferDestroy(&owner) && !OwnedBatchedRolloutBufferDestroy(&copyOfOwner) && OwnedBatchedRolloutBufferBorrow(&copyOfOwner) == nil)
	{
		context.allocator = mem.nil_allocator()
		initialized = OwnedBatchedRolloutBufferInit(&owner, 1, 1, 1, 1, allocator)
	}
	testing.expect(t, initialized && state.attempts == 2 && OwnedBatchedRolloutBufferBorrow(&owner) != nil)
	if initialized { testing.expect(t, OwnedBatchedRolloutBufferDestroy(&owner)) }
	_, nilScratchOk := OwnedBatchedRolloutBufferReturnScratch(nil)
	testing.expect(t, state.successfulFrees == 2 && !OwnedBatchedRolloutBufferDestroy(nil) &&
		OwnedBatchedRolloutBufferBorrow(nil) == nil && !nilScratchOk)
}

@(test)
OwnedRolloutInvalidInputsAndReturnOverflowAreAtomic :: proc(t: ^testing.T) {
	owner: OwnedRolloutBuffer
	ok := OwnedRolloutBufferInit(&owner, 2, 1, 2)
	testing.expect(t, ok)
	if !ok { return }
	defer OwnedRolloutBufferDestroy(&owner)
	buffer := OwnedRolloutBufferBorrow(&owner)
	if buffer == nil { testing.expect(t, false); return }
	observation := [1]f32{1}
	legal := [2]bool{false, true}
	invalid := RolloutTransition{observation = observation[:], legalActions = legal[:], action = 0}
	testing.expect(t, !RolloutBufferAppend(buffer, invalid) && buffer.count == 0)
	maximum := f32(3.402823466e+38)
	testing.expect(t, RolloutTestAppend(buffer, 0, maximum, 0, 0) && RolloutTestAppend(buffer, 1, maximum, 0, 0))
	buffer.storage.advantages[0], buffer.storage.advantages[1] = 11, 12
	buffer.storage.returns[0], buffer.storage.returns[1] = 21, 22
	testing.expect(t, !RolloutComputeGAE(buffer, 1, 1) && !RolloutComputeDiscountedReturns(buffer, 1) &&
		buffer.storage.advantages[0] == 11 && buffer.storage.advantages[1] == 12 &&
		buffer.storage.returns[0] == 21 && buffer.storage.returns[1] == 22)

	batchOwner: OwnedBatchedRolloutBuffer
	ok = OwnedBatchedRolloutBufferInit(&batchOwner, 2, 2, 1, 2)
	testing.expect(t, ok)
	if !ok { return }
	defer OwnedBatchedRolloutBufferDestroy(&batchOwner)
	batch := OwnedBatchedRolloutBufferBorrow(&batchOwner)
	scratch, scratchOk := OwnedBatchedRolloutBufferReturnScratch(&batchOwner)
	testing.expect(t, batch != nil && scratchOk)
	if batch == nil || !scratchOk { return }
	testing.expect(t, !BatchedRolloutBufferAppend(batch, 2, invalid) && batch.rollout.count == 0 &&
		BatchedRolloutTestAppend(batch, 0, 0, maximum, 0, 0) && BatchedRolloutTestAppend(batch, 0, 1, maximum, 0, 0))
	batch.rollout.storage.advantages[0], batch.rollout.storage.advantages[1] = 31, 32
	batch.rollout.storage.returns[0], batch.rollout.storage.returns[1] = 41, 42
	badScratch := BatchedRolloutReturnScratch{batch.rollout.storage.oldLogProbabilities[:2], scratch.hasFollowing}
	aliasedScratch := BatchedRolloutReturnScratch{scratch.followingValues, mem.slice_ptr((^bool)(raw_data(scratch.followingValues)), 2)}
	testing.expect(t, !BatchedRolloutComputeGAE(batch, 1, 1, badScratch) &&
		!BatchedRolloutComputeDiscountedReturns(batch, 1, aliasedScratch) &&
		!BatchedRolloutComputeGAE(batch, 1, 1, scratch) && !BatchedRolloutComputeDiscountedReturns(batch, 1, scratch) &&
		batch.rollout.storage.advantages[0] == 31 && batch.rollout.storage.advantages[1] == 32 &&
		batch.rollout.storage.returns[0] == 41 && batch.rollout.storage.returns[1] == 42)
}

@(test)
OwnedBatchedRolloutLargeEnvironmentScratchStaysOffStack :: proc(t: ^testing.T) {
	state := OwnedRolloutTestAllocator{backing = context.allocator}
	owner: OwnedBatchedRolloutBuffer
	environments := 1_050_000
	ok := OwnedBatchedRolloutBufferInit(&owner, 1, environments, 1, 1, OwnedRolloutTestAllocatorFor(&state))
	testing.expect(t, ok && state.lastSize > 8*1024*1024)
	if !ok { return }
	defer OwnedBatchedRolloutBufferDestroy(&owner)
	buffer := OwnedBatchedRolloutBufferBorrow(&owner)
	scratch, scratchOk := OwnedBatchedRolloutBufferReturnScratch(&owner)
	testing.expect(t, buffer != nil && scratchOk && len(scratch.followingValues) == environments && len(scratch.hasFollowing) == environments)
	if buffer == nil || !scratchOk { return }
	observation := [1]f32{1}
	legal := [1]bool{true}
	transition := RolloutTransition{
		observation = observation[:], legalActions = legal[:], action = 0,
		reward = 2, value = 0.5, nextValue = 3,
	}
	appended, computed: bool
	{
		context.allocator = mem.panic_allocator()
		context.temp_allocator = mem.panic_allocator()
		appended = BatchedRolloutBufferAppend(buffer, environments-1, transition)
		computed = BatchedRolloutComputeGAE(buffer, 0.5, 0.5, scratch)
	}
	testing.expect(t, appended && computed && buffer.rollout.storage.advantages[0] == 3 &&
		buffer.rollout.storage.returns[0] == 3.5 && !scratch.hasFollowing[0] &&
		scratch.hasFollowing[environments-1] && state.attempts == 1 && state.freeCalls == 0)
}

@(test)
OwnedRolloutLargeStorageStaysOffStack :: proc(t: ^testing.T) {
	width := 2_100_000
	allocator := context.allocator
	inputBytes, err := mem.alloc_bytes(width*size_of(f32), align_of(f32), allocator)
	testing.expect(t, err == nil && len(inputBytes) == width*size_of(f32))
	if err != nil || len(inputBytes) != width*size_of(f32) { return }
	defer mem.free(rawptr(raw_data(inputBytes)), allocator)
	input := mem.slice_ptr((^f32)(raw_data(inputBytes)), width)
	input[0], input[width-1] = 13, 17
	legal := [1]bool{true}
	transition := RolloutTransition{observation = input, action = 0, legalActions = legal[:]}
	state := OwnedRolloutTestAllocator{backing = allocator}
	owner: OwnedRolloutBuffer
	ok := OwnedRolloutBufferInit(&owner, 1, width, 1, OwnedRolloutTestAllocatorFor(&state))
	testing.expect(t, ok && state.lastSize > 8*1024*1024)
	if !ok { return }
	defer OwnedRolloutBufferDestroy(&owner)
	buffer := OwnedRolloutBufferBorrow(&owner)
	if buffer == nil { testing.expect(t, false); return }
	appended, computed, reset: bool
	{
		context.allocator = mem.panic_allocator()
		context.temp_allocator = mem.panic_allocator()
		appended = RolloutBufferAppend(buffer, transition)
		computed = RolloutComputeGAE(buffer, 0.9, 0.8)
		reset = RolloutBufferReset(buffer)
	}
	testing.expect(t, appended && computed && reset && buffer.storage.observations[0] == 13 &&
		buffer.storage.observations[width-1] == 17 && buffer.count == 0 && state.attempts == 1)

	batchState := OwnedRolloutTestAllocator{backing = allocator}
	batchOwner: OwnedBatchedRolloutBuffer
	ok = OwnedBatchedRolloutBufferInit(&batchOwner, 1, 3, width, 1, OwnedRolloutTestAllocatorFor(&batchState))
	testing.expect(t, ok && batchState.lastSize > 8*1024*1024)
	if !ok { return }
	defer OwnedBatchedRolloutBufferDestroy(&batchOwner)
	batch := OwnedBatchedRolloutBufferBorrow(&batchOwner)
	scratch, scratchOk := OwnedBatchedRolloutBufferReturnScratch(&batchOwner)
	if batch == nil || !scratchOk { testing.expect(t, false); return }
	{
		context.allocator = mem.panic_allocator()
		context.temp_allocator = mem.panic_allocator()
		appended = BatchedRolloutBufferAppend(batch, 2, transition)
		computed = BatchedRolloutComputeGAE(batch, 0.9, 0.8, scratch)
		reset = BatchedRolloutBufferReset(batch)
	}
	testing.expect(t, appended && computed && reset && batch.rollout.storage.observations[0] == 13 &&
		batch.rollout.storage.observations[width-1] == 17 && batch.rollout.count == 0 && batchState.attempts == 1)
}
