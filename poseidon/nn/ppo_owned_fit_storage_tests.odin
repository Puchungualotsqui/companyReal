package nn

import "../core"
import "../rl"
import "core:mem"
import "core:testing"

PPOOwnedFitTestAllocation :: enum { Normal, Nil, Error, PointerAndError, Short, Misaligned, Wrap, OwnerAlias }

PPOOwnedFitTestAllocator :: struct {
	backing: mem.Allocator,
	mode: PPOOwnedFitTestAllocation,
	live, physical, alias: rawptr,
	allocations, frees, successfulFrees, badFrees: int,
	lastSize, lastAlignment: int,
	virtual, failNextFree, freeBeforeError: bool,
}

PPOOwnedFitTestAllocatorProc :: proc(
	data: rawptr, mode: mem.Allocator_Mode, size, alignment: int,
	oldMemory: rawptr, oldSize: int, loc := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	state := (^PPOOwnedFitTestAllocator)(data)
	switch mode {
	case .Alloc:
		state.allocations += 1
		state.lastSize, state.lastAlignment = size, alignment
		switch state.mode {
		case .Nil: return nil, nil
		case .Error: return nil, .Out_Of_Memory
		case .Wrap:
			state.virtual = true
			state.live = rawptr(max(uintptr)-uintptr(alignment-1))
			return mem.slice_ptr((^byte)(state.live), size), nil
		case .OwnerAlias:
			state.virtual = true
			state.live = state.alias
			return mem.slice_ptr((^byte)(state.live), size), nil
		case .Normal, .PointerAndError, .Short, .Misaligned:
		}
		requested := size
		if state.mode == .Misaligned { requested += alignment }
		bytes, err := state.backing.procedure(state.backing.data, mode, requested, alignment, oldMemory, oldSize, loc)
		if raw_data(bytes) == nil { return bytes, err }
		state.physical = rawptr(raw_data(bytes))
		state.live = state.physical
		if state.mode == .Misaligned {
			state.live = rawptr(uintptr(state.physical)+1)
			bytes = mem.slice_ptr((^byte)(state.live), size)
		} else if state.mode == .Short {
			bytes = bytes[:size-1]
		}
		if state.mode == .PointerAndError { return bytes, .Out_Of_Memory }
		return bytes, err
	case .Free:
		state.frees += 1
		if oldMemory == nil || oldMemory != state.live {
			state.badFrees += 1
			return nil, .Invalid_Pointer
		}
		fail := state.failNextFree
		state.failNextFree = false
		if fail && !state.freeBeforeError { return nil, .Invalid_Argument }
		if !state.virtual {
			_, err := state.backing.procedure(state.backing.data, mode, size, alignment, state.physical, oldSize, loc)
			if err != nil { return nil, err }
		}
		state.live, state.physical, state.virtual = nil, nil, false
		state.successfulFrees += 1
		if fail { return nil, .Invalid_Argument }
		return nil, nil
	case .Free_All, .Resize, .Query_Features, .Query_Info, .Alloc_Non_Zeroed, .Resize_Non_Zeroed:
		return state.backing.procedure(state.backing.data, mode, size, alignment, oldMemory, oldSize, loc)
	}
	return nil, .Invalid_Argument
}

PPOOwnedFitTestExpectLayout :: proc(t: ^testing.T, owner: ^PPOOwnedFitStorage, size: int) {
	storage, ok := PPOOwnedFitStorageView(owner)
	testing.expect(t, ok)
	if !ok { return }
	ranges: [8]PPOFitMemoryRange
	ranges[0], ok = PPOFitMemoryRangeOf(rawptr(raw_data(storage.indices)), len(storage.indices), size_of(int))
	testing.expect(t, ok)
	ranges[1], ok = PPOFitMemoryRangeOf(rawptr(raw_data(storage.observations)), len(storage.observations), size_of(f32))
	testing.expect(t, ok)
	ranges[2], ok = PPOFitMemoryRangeOf(rawptr(raw_data(storage.actions)), len(storage.actions), size_of(int))
	testing.expect(t, ok)
	ranges[3], ok = PPOFitMemoryRangeOf(rawptr(raw_data(storage.legalActions)), len(storage.legalActions), size_of(bool))
	testing.expect(t, ok)
	ranges[4], ok = PPOFitMemoryRangeOf(rawptr(raw_data(storage.oldLogProbabilities)), len(storage.oldLogProbabilities), size_of(f64))
	testing.expect(t, ok)
	ranges[5], ok = PPOFitMemoryRangeOf(rawptr(raw_data(storage.advantages)), len(storage.advantages), size_of(f32))
	testing.expect(t, ok)
	ranges[6], ok = PPOFitMemoryRangeOf(rawptr(raw_data(storage.returns)), len(storage.returns), size_of(f32))
	testing.expect(t, ok)
	ranges[7], ok = PPOFitMemoryRangeOf(rawptr(raw_data(storage.epochMetrics)), len(storage.epochMetrics), size_of(PPOEpochStats))
	testing.expect(t, ok)
	alignments := [8]int{align_of(int), align_of(f32), align_of(int), align_of(bool), align_of(f64), align_of(f32), align_of(f32), align_of(PPOEpochStats)}
	base := uintptr(owner.memory)
	ownerRange := PPOFitMemoryRange{uintptr(rawptr(owner)), uintptr(size_of(owner^))}
	for range, index in ranges {
		testing.expect(t, range.address != 0 && range.bytes > 0 && range.address%uintptr(alignments[index]) == 0)
		testing.expect(t, range.address >= base && range.address-base <= uintptr(size) && range.bytes <= uintptr(size)-(range.address-base))
		testing.expect(t, !PPOFitMemoryRangesOverlap(range, ownerRange))
		for previous in ranges[:index] { testing.expect(t, !PPOFitMemoryRangesOverlap(range, previous)) }
	}
}

@(test)
PPOOwnedFitStorageLayoutAndReuse :: proc(t: ^testing.T) {
	state := PPOOwnedFitTestAllocator{backing = context.allocator}
	allocator := mem.Allocator{procedure = PPOOwnedFitTestAllocatorProc, data = &state}
	owner: PPOOwnedFitStorage
	ok := PPOOwnedFitStorageInit(&owner, 7, 3, 5, 3, 4, allocator)
	testing.expect(t, ok && state.allocations == 1 && state.frees == 0 && state.live == owner.memory)
	if !ok { return }
	defer PPOOwnedFitStorageDestroy(&owner)
	PPOOwnedFitTestExpectLayout(t, &owner, state.lastSize)
	storage, viewOk := PPOOwnedFitStorageView(&owner)
	testing.expect(t, viewOk && len(storage.indices) == 7 && len(storage.observations) == 9 &&
		len(storage.actions) == 3 && len(storage.legalActions) == 15 && len(storage.oldLogProbabilities) == 3 &&
		len(storage.advantages) == 3 && len(storage.returns) == 3 && len(storage.epochMetrics) == 4)
	if !viewOk { return }
	storage.indices[6], storage.observations[8], storage.actions[2] = 11, 12, 13
	storage.legalActions[14], storage.oldLogProbabilities[2] = true, 14
	storage.advantages[2], storage.returns[2], storage.epochMetrics[3].epoch = 15, 16, 17
	storage.actions = storage.actions[:1]
	again, againOk := PPOOwnedFitStorageView(&owner)
	testing.expect(t, againOk && len(again.actions) == 3 && again.indices[6] == 11 && again.observations[8] == 12 &&
		again.actions[2] == 13 && again.legalActions[14] && again.oldLogProbabilities[2] == 14 &&
		again.advantages[2] == 15 && again.returns[2] == 16 && again.epochMetrics[3].epoch == 17)
	testing.expect(t, PPOOwnedFitStorageDestroy(&owner) && state.live == nil && state.successfulFrees == 1 && state.badFrees == 0)
	_, viewOk = PPOOwnedFitStorageView(&owner)
	testing.expect(t, !viewOk && PPOOwnedFitStorageDestroy(&owner) && state.frees == 1)

	// Explicit oversized batches are capped by the rollout, just as the fitter does.
	ok = PPOOwnedFitStorageInit(&owner, 4, 2, 3, max(int), 1, allocator)
	testing.expect(t, ok)
	if !ok { return }
	storage, viewOk = PPOOwnedFitStorageView(&owner)
	testing.expect(t, viewOk && len(storage.indices) == 4 && len(storage.actions) == 4 &&
		len(storage.observations) == 8 && len(storage.legalActions) == 12 && len(storage.epochMetrics) == 1)
	testing.expect(t, PPOOwnedFitStorageDestroy(&owner) && state.allocations == 2 && state.successfulFrees == 2)
}

@(test)
PPOOwnedFitStorageInvalidDimensionsAndOverflow :: proc(t: ^testing.T) {
	state := PPOOwnedFitTestAllocator{backing = context.allocator}
	allocator := mem.Allocator{procedure = PPOOwnedFitTestAllocatorProc, data = &state}
	owner: PPOOwnedFitStorage
	cases := [][5]int{
		{0, 1, 1, 1, 1}, {-1, 1, 1, 1, 1}, {1, 0, 1, 1, 1}, {1, -1, 1, 1, 1},
		{1, 1, 0, 1, 1}, {1, 1, -1, 1, 1}, {1, 1, 1, -1, 1}, {1, 1, 1, 1, 0}, {1, 1, 1, 1, -1},
		{3, max(int), 1, 2, 1}, {3, 1, max(int), 2, 1}, {max(int), 1, 1, 1, 1},
		{1, 1, 1, 1, max(int)}, {max(int)/size_of(int), 1, 1, 1, 1},
		{1, 1, 1, 1, max(int)/size_of(PPOEpochStats)}, {2, max(int), 1, 0, 1},
	}
	before: [size_of(PPOOwnedFitStorage)]byte
	copy(before[:], mem.slice_ptr((^byte)(rawptr(&owner)), len(before)))
	for c in cases {
		testing.expect(t, !PPOOwnedFitStorageInit(&owner, c[0], c[1], c[2], c[3], c[4], allocator))
		after: [size_of(PPOOwnedFitStorage)]byte
		copy(after[:], mem.slice_ptr((^byte)(rawptr(&owner)), len(after)))
		testing.expect(t, before == after && state.allocations == 0 && state.frees == 0)
	}
	testing.expect(t, !PPOOwnedFitStorageInit(nil, 1, 1, 1, 1, 1, allocator))
	_, ok := PPOOwnedFitStorageView(nil)
	testing.expect(t, !ok && !PPOOwnedFitStorageDestroy(nil) && PPOOwnedFitStorageDestroy(&owner))
	testing.expect(t, state.allocations == 0)
}

@(test)
PPOOwnedFitStorageAllocatorFailuresAndRollback :: proc(t: ^testing.T) {
	state := PPOOwnedFitTestAllocator{backing = context.allocator}
	allocator := mem.Allocator{procedure = PPOOwnedFitTestAllocatorProc, data = &state}
	owner: PPOOwnedFitStorage
	before: [size_of(PPOOwnedFitStorage)]byte
	copy(before[:], mem.slice_ptr((^byte)(rawptr(&owner)), len(before)))
	testing.expect(t, !PPOOwnedFitStorageInit(&owner, 3, 2, 2, 2, 1, mem.nil_allocator()))
	testing.expect(t, !PPOOwnedFitStorageInit(&owner, 3, 2, 2, 2, 1, mem.Allocator{}))
	{
		context.allocator = mem.nil_allocator()
		testing.expect(t, !PPOOwnedFitStorageInit(&owner, 3, 2, 2, 2, 1))
	}
	state.alias = rawptr(&owner)
	for mode in ([7]PPOOwnedFitTestAllocation{.Nil, .Error, .PointerAndError, .Short, .Misaligned, .Wrap, .OwnerAlias}) {
		state.mode = mode
		testing.expect(t, !PPOOwnedFitStorageInit(&owner, 3, 2, 2, 2, 1, allocator))
		after: [size_of(PPOOwnedFitStorage)]byte
		copy(after[:], mem.slice_ptr((^byte)(rawptr(&owner)), len(after)))
		_, viewOk := PPOOwnedFitStorageView(&owner)
		testing.expect(t, before == after && !viewOk && state.live == nil && state.badFrees == 0)
	}
	testing.expect(t, state.allocations == 7 && state.frees == 5 && state.successfulFrees == 5)

	// If rollback free fails, Init cannot return the pointer: cleanup is allocator-specific.
	state.mode, state.failNextFree = .PointerAndError, true
	testing.expect(t, !PPOOwnedFitStorageInit(&owner, 3, 2, 2, 2, 1, allocator))
	testing.expect(t, state.live != nil && state.frees == 6 && state.successfulFrees == 5)
	testing.expect(t, mem.free(state.live, allocator) == nil && state.live == nil && state.successfulFrees == 6)
	state.mode = .Normal
	ok := PPOOwnedFitStorageInit(&owner, 3, 2, 2, 2, 1, allocator)
	testing.expect(t, ok)
	if ok { testing.expect(t, PPOOwnedFitStorageDestroy(&owner)) }
	testing.expect(t, state.allocations == 9 && state.live == nil && state.successfulFrees == 7 && state.badFrees == 0)
}

@(test)
PPOOwnedFitStorageCopyAndFreeRetry :: proc(t: ^testing.T) {
	state := PPOOwnedFitTestAllocator{backing = context.allocator}
	allocator := mem.Allocator{procedure = PPOOwnedFitTestAllocatorProc, data = &state}
	owner: PPOOwnedFitStorage
	initialized := false
	{
		context.allocator = allocator
		initialized = PPOOwnedFitStorageInit(&owner, 5, 2, 3, 0, 2)
	}
	testing.expect(t, initialized && state.allocations == 1)
	if !initialized { return }
	defer PPOOwnedFitStorageDestroy(&owner)
	storage, ok := PPOOwnedFitStorageView(&owner)
	testing.expect(t, ok && len(storage.actions) == 5 && len(storage.observations) == 10 && len(storage.legalActions) == 15)
	if !ok { return }
	storage.indices[0], storage.epochMetrics[0].epoch = 123, 456
	copied := owner
	_, ok = PPOOwnedFitStorageView(&copied)
	testing.expect(t, !ok && !PPOOwnedFitStorageDestroy(&copied) && !PPOOwnedFitStorageInit(&copied, 1, 1, 1, 1, 1, allocator))
	testing.expect(t, !PPOOwnedFitStorageInit(&owner, 1, 1, 1, 1, 1, allocator) && state.allocations == 1 && state.frees == 0)
	state.failNextFree = true
	testing.expect(t, !PPOOwnedFitStorageDestroy(&owner) && state.live == owner.memory && state.frees == 1)
	again, againOk := PPOOwnedFitStorageView(&owner)
	testing.expect(t, againOk && raw_data(again.indices) == raw_data(storage.indices) && again.indices[0] == 123 && again.epochMetrics[0].epoch == 456)
	destroyed := false
	{
		context.allocator = mem.nil_allocator()
		destroyed = PPOOwnedFitStorageDestroy(&owner)
	}
	testing.expect(t, destroyed && state.live == nil && state.frees == 2 && state.successfulFrees == 1 && state.badFrees == 0)
	_, ok = PPOOwnedFitStorageView(&copied)
	testing.expect(t, !ok && !PPOOwnedFitStorageDestroy(&copied) && !PPOOwnedFitStorageInit(&copied, 1, 1, 1, 1, 1, allocator))
	testing.expect(t, PPOOwnedFitStorageDestroy(&owner) && state.frees == 2)
	initialized = PPOOwnedFitStorageInit(&owner, 1, 1, 1, 1, 1, allocator)
	testing.expect(t, initialized && state.allocations == 2)
	if initialized { testing.expect(t, PPOOwnedFitStorageDestroy(&owner)) }
	testing.expect(t, state.successfulFrees == 2 && state.badFrees == 0)
}

@(test)
PPOOwnedFitStorageAmbiguousFreeError :: proc(t: ^testing.T) {
	state := PPOOwnedFitTestAllocator{backing = context.allocator, freeBeforeError = true}
	allocator := mem.Allocator{procedure = PPOOwnedFitTestAllocatorProc, data = &state}
	owner: PPOOwnedFitStorage
	ok := PPOOwnedFitStorageInit(&owner, 3, 2, 2, 2, 1, allocator)
	testing.expect(t, ok)
	if !ok { return }
	before: [size_of(PPOOwnedFitStorage)]byte
	copy(before[:], mem.slice_ptr((^byte)(rawptr(&owner)), len(before)))
	state.failNextFree = true
	testing.expect(t, !PPOOwnedFitStorageDestroy(&owner))
	after: [size_of(PPOOwnedFitStorage)]byte
	copy(after[:], mem.slice_ptr((^byte)(rawptr(&owner)), len(after)))
	testing.expect(t, before == after && state.frees == 1 && state.successfulFrees == 1 && state.live == nil && state.badFrees == 0)
	// The allocator freed despite reporting an error: the stale owner is discarded.

	other: PPOOwnedFitStorage
	state.mode, state.failNextFree = .PointerAndError, true
	testing.expect(t, !PPOOwnedFitStorageInit(&other, 3, 2, 2, 2, 1, allocator))
	_, viewOk := PPOOwnedFitStorageView(&other)
	testing.expect(t, !viewOk && state.frees == 2 && state.successfulFrees == 2 && state.live == nil && state.badFrees == 0)
}

@(test)
PPOOwnedFitStorageLargeAllocationOffStack :: proc(t: ^testing.T) {
	state := PPOOwnedFitTestAllocator{backing = context.allocator}
	allocator := mem.Allocator{procedure = PPOOwnedFitTestAllocatorProc, data = &state}
	owner: PPOOwnedFitStorage
	ok := PPOOwnedFitStorageInit(&owner, 64, 32769, 3, 64, 2, allocator)
	testing.expect(t, ok && state.lastSize > 8*1024*1024)
	if !ok { return }
	defer PPOOwnedFitStorageDestroy(&owner)
	storage, viewOk := PPOOwnedFitStorageView(&owner)
	testing.expect(t, viewOk && len(storage.observations) == 64*32769)
	if !viewOk { return }
	storage.observations[0], storage.observations[len(storage.observations)-1] = 1, 2
	testing.expect(t, storage.observations[0] == 1 && storage.observations[len(storage.observations)-1] == 2)
	testing.expect(t, PPOOwnedFitStorageDestroy(&owner) && state.successfulFrees == 1 && state.live == nil)
}

PPOOwnedFitTestModelsEqual :: proc(a, b: ^Sequential($maxLayers, $maxWidth, $batchCapacity)) -> bool {
	storageA, storageB: [2*maxLayers]^core.Node
	parametersA, okA := SequentialParameters(a, storageA[:])
	parametersB, okB := SequentialParameters(b, storageB[:])
	if !okA || !okB || len(parametersA) != len(parametersB) { return false }
	for parameter, index in parametersA {
		if len(parameter.value.data) != len(parametersB[index].value.data) { return false }
		for value, element in parameter.value.data {
			if value != parametersB[index].value.data[element] { return false }
		}
	}
	return true
}

@(test)
PPOOwnedFitStorageActualRepeatedFits :: proc(t: ^testing.T) {
	policy, referencePolicy: Sequential(1, 2, 4)
	value, referenceValue: Sequential(1, 2, 3)
	setup := SequentialInit(&policy, 2, 7) && SequentialAddDense(&policy, 2) &&
		SequentialInit(&value, 2, 11) && SequentialAddDense(&value, 1) &&
		SequentialInit(&referencePolicy, 2, 7) && SequentialAddDense(&referencePolicy, 2) &&
		SequentialInit(&referenceValue, 2, 11) && SequentialAddDense(&referenceValue, 1)
	testing.expect(t, setup)
	if !setup { return }

	observations: [14]f32
	actions: [7]int
	rewards, values, nextValues, advantages, returns: [7]f32
	logs: [7]f64
	legal: [14]bool
	terminated, truncated: [7]bool
	rollout: rl.RolloutBuffer
	rolloutStorage := rl.RolloutStorage{
		observations = observations[:], actions = actions[:], rewards = rewards[:], values = values[:],
		nextValues = nextValues[:], oldLogProbabilities = logs[:], legalActions = legal[:],
		terminated = terminated[:], truncated = truncated[:], advantages = advantages[:], returns = returns[:],
	}
	setup = rl.RolloutBufferInit(&rollout, rolloutStorage, 7, 2, 2)
	mask := [2]bool{true, true}
	for index in 0..<5 {
		observation := [2]f32{f32(index)/4, 1}
		action, logProbability, policyOk := SequentialPolicyAction(&policy, observation[:], mask[:], .Greedy)
		currentValue, valueOk := SequentialPredictScalar(&value, observation[:])
		nextObservation := [2]f32{f32(index+1)/4, 1}
		nextValue, nextOk := SequentialPredictScalar(&value, nextObservation[:])
		setup = setup && policyOk && valueOk && nextOk && rl.RolloutBufferAppend(&rollout, {
			observation = observation[:], action = action, reward = f32(index%2), value = currentValue,
			nextValue = nextValue, oldLogProbability = logProbability, legalActions = mask[:], terminated = index == 4,
		})
	}
	setup = setup && rl.RolloutComputeGAE(&rollout, 0.9, 0.95) && rl.RolloutNormalizeAdvantages(&rollout)
	testing.expect(t, setup)
	if !setup { return }

	allocatorState := PPOOwnedFitTestAllocator{backing = context.allocator}
	allocator := mem.Allocator{procedure = PPOOwnedFitTestAllocatorProc, data = &allocatorState}
	owner: PPOOwnedFitStorage
	setup = PPOOwnedFitStorageInit(&owner, 7, 2, 2, 0, 3, allocator)
	testing.expect(t, setup)
	if !setup { return }
	defer PPOOwnedFitStorageDestroy(&owner)
	storage, viewOk := PPOOwnedFitStorageView(&owner)
	testing.expect(t, viewOk && PPOFitStorageAndRolloutDisjoint(storage, &rollout))
	if !viewOk { return }

	referenceIndices: [7]int
	referenceObservations: [14]f32
	referenceActions: [7]int
	referenceLegal: [14]bool
	referenceLogs: [7]f64
	referenceAdvantages, referenceReturns: [7]f32
	referenceMetrics: [3]PPOEpochStats
	referenceStorage := PPOFitStorage{
		indices = referenceIndices[:], observations = referenceObservations[:], actions = referenceActions[:],
		legalActions = referenceLegal[:], oldLogProbabilities = referenceLogs[:], advantages = referenceAdvantages[:],
		returns = referenceReturns[:], epochMetrics = referenceMetrics[:],
	}
	storage.indices[5], storage.indices[6], storage.epochMetrics[2].epoch = 101, 102, 777
	referenceIndices[5], referenceIndices[6], referenceMetrics[2].epoch = 101, 102, 777
	state, referenceState: PPOTrainingState
	setup = PPOTrainingStateInit(&state, 123, 456) && PPOTrainingStateInit(&referenceState, 123, 456)
	testing.expect(t, setup)
	if !setup { return }
	config := PPOConfig{0.2, 0.01, 0.5, 1}
	fitConfig := PPOFitConfig{epochs = 2, batchSize = 2}
	stats, fitOk := SequentialPPOFitStateful(&policy, &value, &rollout, &state, config, fitConfig, SequentialSGD{0.01}, storage)
	referenceStats, referenceOk := SequentialPPOFitStateful(&referencePolicy, &referenceValue, &rollout, &referenceState, config, fitConfig, SequentialSGD{0.01}, referenceStorage)
	testing.expect(t, fitOk && referenceOk && stats == referenceStats && stats.epochs == 2 && stats.updates == 6)
	testing.expect(t, state == referenceState && state.updateCount == 6 && PPOOwnedFitTestModelsEqual(&policy, &referencePolicy) && PPOOwnedFitTestModelsEqual(&value, &referenceValue))
	testing.expect(t, storage.epochMetrics[0] == referenceMetrics[0] && storage.epochMetrics[1] == referenceMetrics[1] && storage.epochMetrics[2].epoch == 777)
	testing.expect(t, storage.indices[5] == 101 && storage.indices[6] == 102 && allocatorState.allocations == 1 && allocatorState.frees == 0)
	if !fitOk || !referenceOk { return }

	previousMetric := storage.epochMetrics[1]
	// Zero uses the smaller model capacity (3), not the actor capacity (4).
	fitConfig = {epochs = 1, batchSize = 0}
	stats, fitOk = SequentialPPOFitStateful(&policy, &value, &rollout, &state, config, fitConfig, SequentialSGD{0.01}, storage)
	referenceStats, referenceOk = SequentialPPOFitStateful(&referencePolicy, &referenceValue, &rollout, &referenceState, config, fitConfig, SequentialSGD{0.01}, referenceStorage)
	testing.expect(t, fitOk && referenceOk && stats == referenceStats && stats.epochs == 1 && stats.updates == 2)
	testing.expect(t, state == referenceState && state.updateCount == 8 && PPOOwnedFitTestModelsEqual(&policy, &referencePolicy) && PPOOwnedFitTestModelsEqual(&value, &referenceValue))
	testing.expect(t, storage.epochMetrics[0] == referenceMetrics[0] && storage.epochMetrics[1] == previousMetric && storage.epochMetrics[2].epoch == 777)
	again, againOk := PPOOwnedFitStorageView(&owner)
	testing.expect(t, againOk && raw_data(again.indices) == raw_data(storage.indices) && raw_data(again.epochMetrics) == raw_data(storage.epochMetrics))
	testing.expect(t, allocatorState.allocations == 1 && allocatorState.frees == 0)
	if !fitOk || !referenceOk { return }

	// The same scratch also works with the non-stateful entry point and Adam.
	policyPointers, valuePointers, referencePolicyPointers, referenceValuePointers: [2]^core.Node
	policyParameters, policyOk := SequentialParameters(&policy, policyPointers[:])
	valueParameters, valueOk := SequentialParameters(&value, valuePointers[:])
	referencePolicyParameters, referencePolicyOk := SequentialParameters(&referencePolicy, referencePolicyPointers[:])
	referenceValueParameters, referenceValueOk := SequentialParameters(&referenceValue, referenceValuePointers[:])
	setup = policyOk && valueOk && referencePolicyOk && referenceValueOk
	testing.expect(t, setup)
	if !setup { return }
	parameters, referenceParameters: [4]^core.Node
	copy(parameters[:2], policyParameters)
	copy(parameters[2:], valueParameters)
	copy(referenceParameters[:2], referencePolicyParameters)
	copy(referenceParameters[2:], referenceValueParameters)
	firstMoment, secondMoment, referenceFirstMoment, referenceSecondMoment: [9]f32
	adam, referenceAdam: Adam
	setup = AdamInit(&adam, parameters[:], firstMoment[:], secondMoment[:], learningRate = 0.01) &&
		AdamInit(&referenceAdam, referenceParameters[:], referenceFirstMoment[:], referenceSecondMoment[:], learningRate = 0.01)
	testing.expect(t, setup)
	if !setup { return }
	randomState, referenceRandomState: u64 = 789, 789
	stats, fitOk = SequentialPPOFit(&policy, &value, &rollout, &randomState, config, fitConfig, &adam, storage)
	referenceStats, referenceOk = SequentialPPOFit(&referencePolicy, &referenceValue, &rollout, &referenceRandomState, config, fitConfig, &referenceAdam, referenceStorage)
	testing.expect(t, fitOk && referenceOk && stats == referenceStats && stats.updates == 2 && adam.step == 2 && referenceAdam.step == 2)
	testing.expect(t, randomState == referenceRandomState && firstMoment == referenceFirstMoment && secondMoment == referenceSecondMoment &&
		PPOOwnedFitTestModelsEqual(&policy, &referencePolicy) && PPOOwnedFitTestModelsEqual(&value, &referenceValue))
	testing.expect(t, storage.epochMetrics[0] == referenceMetrics[0] && allocatorState.allocations == 1 && allocatorState.frees == 0)
	if !fitOk || !referenceOk { return }

	// A smaller explicit allocation rejects the default model batch before training.
	small: PPOOwnedFitStorage
	setup = PPOOwnedFitStorageInit(&small, 7, 2, 2, 2, 1)
	testing.expect(t, setup)
	if !setup { return }
	defer PPOOwnedFitStorageDestroy(&small)
	smallStorage, smallOk := PPOOwnedFitStorageView(&small)
	testing.expect(t, smallOk)
	if !smallOk { return }
	before := state
	_, fitOk = SequentialPPOFitStateful(&policy, &value, &rollout, &state, config, fitConfig, SequentialSGD{0.01}, smallStorage)
	testing.expect(t, !fitOk && state == before && PPOOwnedFitTestModelsEqual(&policy, &referencePolicy) && PPOOwnedFitTestModelsEqual(&value, &referenceValue))
	fitConfig.batchSize = 2
	stats, fitOk = SequentialPPOFitStateful(&policy, &value, &rollout, &state, config, fitConfig, SequentialSGD{0.01}, smallStorage)
	testing.expect(t, fitOk && stats.updates == 3 && state.updateCount == 11)
}
