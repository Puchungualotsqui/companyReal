package rl

import "core:mem"
import "core:testing"

OwnedRolloutTestAllocation :: enum { Normal, Nil, Error, PointerAndError, Short, Misaligned, Wrapped, Alias }

OwnedRolloutTestAllocator :: struct {
	backing: mem.Allocator,
	mode: OwnedRolloutTestAllocation,
	base, returned, alias: rawptr,
	aliasLength: int,
	attempts, freeCalls, successfulFrees, badFrees: int,
	lastSize, lastAlignment: int,
	failNextFree: bool,
}

OwnedRolloutTestAllocatorProc :: proc(
	data: rawptr, mode: mem.Allocator_Mode, size, alignment: int,
	oldMemory: rawptr, oldSize: int, loc := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	state := (^OwnedRolloutTestAllocator)(data)
	switch mode {
	case .Alloc:
		state.attempts += 1
		state.lastSize, state.lastAlignment = size, alignment
		switch state.mode {
		case .Nil:
			return nil, nil
		case .Error:
			return nil, .Out_Of_Memory
		case .Wrapped:
			state.returned = rawptr(max(uintptr)-7)
			return mem.byte_slice(state.returned, size), nil
		case .Alias:
			state.returned = state.alias
			length := size
			if state.aliasLength > 0 { length = state.aliasLength }
			return mem.byte_slice(state.returned, length), nil
		case .Normal, .PointerAndError, .Short, .Misaligned:
		}
		actualSize := size
		if state.mode == .Misaligned { actualSize += alignment }
		bytes, err := state.backing.procedure(state.backing.data, mode, actualSize, alignment, oldMemory, oldSize, loc)
		if raw_data(bytes) == nil || err != nil { return bytes, err }
		state.base = rawptr(raw_data(bytes))
		state.returned = state.base
		if state.mode == .Misaligned { state.returned = rawptr(uintptr(state.base)+1) }
		length := size
		if state.mode == .Short { length -= 1 }
		result := mem.byte_slice(state.returned, length)
		if state.mode == .PointerAndError { return result, .Out_Of_Memory }
		return result, nil
	case .Free:
		state.freeCalls += 1
		if oldMemory == nil || oldMemory != state.returned {
			state.badFrees += 1
			return nil, .Invalid_Pointer
		}
		if state.failNextFree {
			state.failNextFree = false
			return nil, .Invalid_Argument
		}
		if state.base != nil {
			_, err := state.backing.procedure(state.backing.data, mode, size, alignment, state.base, oldSize, loc)
			if err != nil { return nil, err }
		}
		state.base, state.returned = nil, nil
		state.successfulFrees += 1
		return nil, nil
	case .Free_All, .Resize, .Query_Features, .Query_Info, .Alloc_Non_Zeroed, .Resize_Non_Zeroed:
		return nil, .Mode_Not_Implemented
	}
	return nil, .Invalid_Argument
}

OwnedRolloutTestAllocatorFor :: proc(state: ^OwnedRolloutTestAllocator) -> mem.Allocator {
	return {procedure = OwnedRolloutTestAllocatorProc, data = state}
}

OwnedRolloutTestCompare :: proc(t: ^testing.T, actual, expected: ^RolloutBuffer) {
	testing.expect(t, actual.count == expected.count && actual.capacity == expected.capacity &&
		actual.observationWidth == expected.observationWidth && actual.actionCount == expected.actionCount)
	if actual.count != expected.count { return }
	for index in 0..<actual.count {
		a, b := actual.storage, expected.storage
		testing.expect(t, a.actions[index] == b.actions[index] && a.rewards[index] == b.rewards[index] &&
			a.values[index] == b.values[index] && a.nextValues[index] == b.nextValues[index] &&
			a.oldLogProbabilities[index] == b.oldLogProbabilities[index] &&
			a.terminated[index] == b.terminated[index] && a.truncated[index] == b.truncated[index] &&
			a.advantages[index] == b.advantages[index] && a.returns[index] == b.returns[index])
		for column in 0..<actual.observationWidth {
			position := index*actual.observationWidth+column
			testing.expect(t, a.observations[position] == b.observations[position])
		}
		for column in 0..<actual.actionCount {
			position := index*actual.actionCount+column
			testing.expect(t, a.legalActions[position] == b.legalActions[position])
		}
	}
}

@(test)
OwnedRolloutSingleParityAndReuse :: proc(t: ^testing.T) {
	state := OwnedRolloutTestAllocator{backing = context.allocator}
	allocator := OwnedRolloutTestAllocatorFor(&state)
	owner: OwnedRolloutBuffer
	ok := OwnedRolloutBufferInit(&owner, 4, 1, 2, allocator)
	testing.expect(t, ok && state.attempts == 1)
	if !ok { return }
	defer OwnedRolloutBufferDestroy(&owner)
	buffer := OwnedRolloutBufferBorrow(&owner)
	backing: RolloutTestBacking
	reference, referenceOk := RolloutTestInit(&backing)
	testing.expect(t, buffer != nil && referenceOk && RolloutBufferValid(buffer))
	if buffer == nil || !referenceOk { return }

	populated, referencePopulated, gae, referenceGAE, discounted, referenceDiscounted: bool
	badGAE, fullRejected, normalized, referenceNormalized, scaled, referenceScaled: bool
	advantages, targets, returns: [4]f32
	{
		context.allocator = mem.panic_allocator()
		context.temp_allocator = mem.panic_allocator()
		populated = RolloutTestAppend(buffer, 0, 1, 0.5, 1) &&
			RolloutTestAppend(buffer, 1, 2, 1, 4, truncated = true) &&
			RolloutTestAppend(buffer, 2, 3, 2, 99, terminated = true) &&
			RolloutTestAppend(buffer, 3, 1, 0.5, 3)
		referencePopulated = RolloutTestAppend(&reference, 0, 1, 0.5, 1) &&
			RolloutTestAppend(&reference, 1, 2, 1, 4, truncated = true) &&
			RolloutTestAppend(&reference, 2, 3, 2, 99, terminated = true) &&
			RolloutTestAppend(&reference, 3, 1, 0.5, 3)
		fullRejected = RolloutBufferFull(buffer) && !RolloutTestAppend(buffer, 4, 1, 0, 0)
		gae = RolloutComputeGAE(buffer, 0.5, 0.5)
		referenceGAE = RolloutComputeGAE(&reference, 0.5, 0.5)
		copy(advantages[:], buffer.storage.advantages[:4])
		copy(targets[:], buffer.storage.returns[:4])
		badGAE = !RolloutComputeGAE(buffer, 0.5, -1)
		discounted = RolloutComputeDiscountedReturns(buffer, 0.5)
		referenceDiscounted = RolloutComputeDiscountedReturns(&reference, 0.5)
		copy(returns[:], buffer.storage.returns[:4])
		normalized = RolloutNormalizeAdvantages(buffer)
		referenceNormalized = RolloutNormalizeAdvantages(&reference)
		scaled = RolloutScaleRewards(buffer, 0.5)
		referenceScaled = RolloutScaleRewards(&reference, 0.5)
	}
	testing.expect(t, populated && referencePopulated && fullRejected && gae && referenceGAE && badGAE &&
		discounted && referenceDiscounted && normalized && referenceNormalized && scaled && referenceScaled)
	testing.expect(t, advantages == [4]f32{1.75, 3, 1, 2})
	testing.expect(t, targets == [4]f32{2.25, 4, 3, 2.5})
	testing.expect(t, returns == [4]f32{3, 4, 3, 2.5})
	OwnedRolloutTestCompare(t, buffer, &reference)
	testing.expect(t, RolloutObservationAt(buffer, 2)[0] == 2 && RolloutLegalActionsAt(buffer, 2)[0])
	testing.expect(t, state.attempts == 1 && state.freeCalls == 0)

	original := raw_data(buffer.storage.observations)
	reset, appended: bool
	{
		context.allocator = mem.panic_allocator()
		context.temp_allocator = mem.panic_allocator()
		reset = RolloutBufferReset(buffer)
		appended = RolloutTestAppend(buffer, 9, 7, 0, 0)
	}
	testing.expect(t, reset && appended && buffer.count == 1 && buffer.storage.observations[0] == 9 &&
		raw_data(buffer.storage.observations) == original && state.attempts == 1)
}

@(test)
OwnedRolloutBatchedParityAndReuse :: proc(t: ^testing.T) {
	state := OwnedRolloutTestAllocator{backing = context.allocator}
	owner: OwnedBatchedRolloutBuffer
	ok := OwnedBatchedRolloutBufferInit(&owner, 5, 2, 1, 2, OwnedRolloutTestAllocatorFor(&state))
	testing.expect(t, ok && state.attempts == 1)
	if !ok { return }
	defer OwnedBatchedRolloutBufferDestroy(&owner)
	buffer := OwnedBatchedRolloutBufferBorrow(&owner)
	scratch, scratchOk := OwnedBatchedRolloutBufferReturnScratch(&owner)
	backing: BatchedRolloutTestStorage
	reference, referenceOk := BatchedRolloutTestInit(&backing, 5)
	testing.expect(t, buffer != nil && scratchOk && referenceOk && len(scratch.followingValues) == 2 && len(scratch.hasFollowing) == 2)
	if buffer == nil || !scratchOk || !referenceOk { return }
	referenceScratch := BatchedRolloutTestScratch(&backing)
	populated, referencePopulated, gae, referenceGAE, discounted, referenceDiscounted: bool
	fullRejected, invalidGAE, reset, reuse: bool
	advantages, targets, returns: [5]f32
	{
		context.allocator = mem.panic_allocator()
		context.temp_allocator = mem.panic_allocator()
		populated = BatchedRolloutTestPopulate(buffer)
		referencePopulated = BatchedRolloutTestPopulate(&reference)
		fullRejected = BatchedRolloutBufferFull(buffer) && !BatchedRolloutTestAppend(buffer, 0, 0, 1, 0, 0)
		gae = BatchedRolloutComputeGAE(buffer, 0.9, 0.8, scratch)
		referenceGAE = BatchedRolloutComputeGAE(&reference, 0.9, 0.8, referenceScratch)
		copy(advantages[:], buffer.rollout.storage.advantages[:5])
		copy(targets[:], buffer.rollout.storage.returns[:5])
		invalidGAE = !BatchedRolloutComputeGAE(buffer, 0.9, 2, scratch)
		discounted = BatchedRolloutComputeDiscountedReturns(buffer, 0.9, scratch)
		referenceDiscounted = BatchedRolloutComputeDiscountedReturns(&reference, 0.9, referenceScratch)
		copy(returns[:], buffer.rollout.storage.returns[:5])
	}
	testing.expect(t, populated && referencePopulated && fullRejected && gae && referenceGAE && invalidGAE && discounted && referenceDiscounted)
	expectedAdvantages := [5]f32{2.12, 25.836, 1, 21.3, 4.6}
	expectedTargets := [5]f32{2.62, 29.836, 2, 26.3, 6.6}
	expectedReturns := [5]f32{2.8, 33.67, 2, 26.3, 6.6}
	for index in 0..<5 {
		testing.expect(t, RolloutTestNear(f64(advantages[index]), f64(expectedAdvantages[index]), 0.0001) &&
			RolloutTestNear(f64(targets[index]), f64(expectedTargets[index]), 0.0001) &&
			RolloutTestNear(f64(returns[index]), f64(expectedReturns[index]), 0.0001))
		testing.expect(t, buffer.environmentIndices[index] == reference.environmentIndices[index])
	}
	OwnedRolloutTestCompare(t, &buffer.rollout, &reference.rollout)
	view, viewOk := BatchedRolloutBufferTrainingView(buffer)
	testing.expect(t, viewOk && view == &buffer.rollout && view.count == 5)
	original := raw_data(scratch.followingValues)
	{
		context.allocator = mem.panic_allocator()
		context.temp_allocator = mem.panic_allocator()
		reset = BatchedRolloutBufferReset(buffer)
		reuse = BatchedRolloutTestAppend(buffer, 1, 8, 2, 1, 4) && BatchedRolloutComputeGAE(buffer, 0.5, 0.5, scratch)
	}
	scratchAgain, againOk := OwnedBatchedRolloutBufferReturnScratch(&owner)
	testing.expect(t, reset && reuse && againOk && buffer.rollout.count == 1 && buffer.environmentIndices[0] == 1 &&
		raw_data(scratchAgain.followingValues) == original && state.attempts == 1 && state.freeCalls == 0)
}

@(test)
OwnedRolloutBatchedMatchesIndependentStreams :: proc(t: ^testing.T) {
	owner: OwnedBatchedRolloutBuffer
	ok := OwnedBatchedRolloutBufferInit(&owner, 8, 4, 1, 2)
	testing.expect(t, ok)
	if !ok { return }
	defer OwnedBatchedRolloutBufferDestroy(&owner)
	batch := OwnedBatchedRolloutBufferBorrow(&owner)
	scratch, scratchOk := OwnedBatchedRolloutBufferReturnScratch(&owner)
	backing0, backing1: RolloutTestBacking
	stream0, ok0 := RolloutTestInit(&backing0)
	stream1, ok1 := RolloutTestInit(&backing1)
	testing.expect(t, batch != nil && scratchOk && ok0 && ok1)
	if batch == nil || !scratchOk || !ok0 || !ok1 { return }
	environments := [8]int{0, 1, 0, 1, 1, 0, 1, 0}
	rewards := [8]f32{1, 2, 3, 4, 5, 6, 7, 8}
	terminations := [8]bool{false, false, false, true, false, true, false, false}
	truncations := [8]bool{false, false, true, false, false, false, false, false}
	appended := true
	{
		context.allocator = mem.panic_allocator()
		context.temp_allocator = mem.panic_allocator()
		for environment, index in environments {
			stream := &stream0
			if environment == 1 { stream = &stream1 }
			appended = appended && BatchedRolloutTestAppend(batch, environment, f32(index), rewards[index], 0.5, 1.5, terminations[index], truncations[index]) &&
				RolloutTestAppend(stream, f32(index), rewards[index], 0.5, 1.5, terminations[index], truncations[index])
		}
		appended = appended && BatchedRolloutComputeGAE(batch, 0.9, 0.8, scratch) &&
			RolloutComputeGAE(&stream0, 0.9, 0.8) && RolloutComputeGAE(&stream1, 0.9, 0.8)
	}
	testing.expect(t, appended)
	positions := [2]int{}
	for environment, index in environments {
		stream := &stream0
		if environment == 1 { stream = &stream1 }
		position := positions[environment]
		testing.expect(t, batch.rollout.storage.advantages[index] == stream.storage.advantages[position] &&
			batch.rollout.storage.returns[index] == stream.storage.returns[position])
		positions[environment] += 1
	}
	computed := false
	{
		context.allocator = mem.panic_allocator()
		context.temp_allocator = mem.panic_allocator()
		computed = BatchedRolloutComputeDiscountedReturns(batch, 0.9, scratch) &&
			RolloutComputeDiscountedReturns(&stream0, 0.9) && RolloutComputeDiscountedReturns(&stream1, 0.9)
	}
	testing.expect(t, computed)
	positions = {}
	for environment, index in environments {
		stream := &stream0
		if environment == 1 { stream = &stream1 }
		testing.expect(t, batch.rollout.storage.returns[index] == stream.storage.returns[positions[environment]])
		positions[environment] += 1
	}
}
