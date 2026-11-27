package nn

import "../core"
import "core:mem"
import "core:testing"

@(test)
PPOTrainingContextMultipleRollbackFreeFailures :: proc(t: ^testing.T) {
	policy, value: Sequential(1, 2, 2)
	setup := PPOContextTestSetup(&policy, &value)
	testing.expect(t, setup)
	if !setup { return }
	trainer: PPOTrainingContext(1, 2, 2, 1, 2, 2)
	state := PPOContextTestAllocator{backing = context.allocator, pointerAndErrorAt = 4, failFreeAt = 1, failFreeAt2 = 3}
	allocator := mem.Allocator{procedure = PPOContextTestAllocatorProc, data = &state}
	options := PPOTrainingContextOptionsDefault(5)
	testing.expect(t, PPOTrainingContextInit(&trainer, &policy, &value, options, allocator) == .CleanupFailed)
	testing.expect(t, state.allocations == 4 && state.freeCalls == 4 && state.frees == 2 && state.badFrees == 0)
	for i in 0..<4 {
		retained := i == 1 || i == 3
		testing.expect(t, state.freeOrder[i] == state.allocated[3-i] && state.live[i] == retained &&
			(trainer.pending.blocks[i] != nil) == retained)
	}
	state.failFreeAt, state.failFreeAt2 = 5, 0
	testing.expect(t, PPOTrainingContextDestroy(&trainer) == .CleanupFailed && state.freeCalls == 6 && state.frees == 3 &&
		state.freeOrder[4] == state.allocated[3] && state.freeOrder[5] == state.allocated[1] &&
		state.live[3] && !state.live[1] && trainer.pending.blocks[3] == state.allocated[3] && trainer.pending.blocks[1] == nil)
	state.failFreeAt = 0
	testing.expect(t, PPOTrainingContextDestroy(&trainer) == .None && state.freeCalls == 7 && state.frees == 4 &&
		state.freeOrder[6] == state.allocated[3] && state.badFrees == 0)
	testing.expect(t, PPOTrainingContextDestroy(&trainer) == .None && state.freeCalls == 7)
}

@(test)
PPOTrainingContextFreeErrorCanReleaseMemory :: proc(t: ^testing.T) {
	for duringInit in ([2]bool{true, false}) {
		policy, value: Sequential(1, 2, 2)
		setup := PPOContextTestSetup(&policy, &value)
		testing.expect(t, setup)
		if !setup { return }
		trainer: PPOTrainingContext(1, 2, 2, 1, 2, 2)
		state := PPOContextTestAllocator{backing = context.allocator, failFreeAt = 1, failFreeReleases = true}
		if duringInit { state.pointerAndErrorAt = 1 }
		allocator := mem.Allocator{procedure = PPOContextTestAllocatorProc, data = &state}
		options := PPOTrainingContextOptionsDefault(5)
		result := PPOTrainingContextInit(&trainer, &policy, &value, options, allocator)
		if duringInit {
			testing.expect(t, result == .CleanupFailed && state.allocations == 1 && state.frees == 1 &&
				!state.live[0] && trainer.pending.blocks[0] == state.allocated[0])
		} else {
			testing.expect(t, result == .None)
			if result != .None { return }
			testing.expect(t, PPOTrainingContextDestroy(&trainer) == .CleanupFailed && state.allocations == 4 && state.frees == 2 &&
				!state.live[3] && !state.live[0] && rawptr(raw_data(trainer.adam.secondMoment)) == state.allocated[3])
		}
		testing.expect(t, trainer.phase == .Destroying && PPOTrainingContextState(&trainer) == nil &&
			PPOTrainingContextOptimizer(&trainer) == nil && PPOTrainingContextInit(&trainer, &policy, &value, options, allocator) == .InvalidHandle)
		// Generic Destroy cannot know that the reported failure released memory.
		// This test allocator exposes its live blocks for allocator-specific cleanup;
		// do not retry Destroy on the now-ambiguous trainer.
		for pointer, i in state.allocated[:state.allocations] {
			if state.live[i] { testing.expect(t, mem.free(pointer, allocator) == nil) }
		}
		testing.expect(t, state.frees == state.allocations && state.badFrees == 0)
	}
}

@(test)
PPOTrainingContextNilAllocatorLeavesEverythingUnchanged :: proc(t: ^testing.T) {
	policy, value: Sequential(1, 2, 2)
	trainer: PPOTrainingContext(1, 2, 2, 1, 2, 2)
	setup := PPOContextTestSetup(&policy, &value)
	testing.expect(t, setup)
	if !setup { return }
	trainerBytes: [size_of(trainer)]u8
	policyBytes, valueBytes: [size_of(policy)]u8
	copy(trainerBytes[:], mem.slice_ptr((^u8)(rawptr(&trainer)), len(trainerBytes)))
	copy(policyBytes[:], mem.slice_ptr((^u8)(rawptr(&policy)), len(policyBytes)))
	copy(valueBytes[:], mem.slice_ptr((^u8)(rawptr(&value)), len(valueBytes)))
	testing.expect(t, PPOTrainingContextInit(&trainer, &policy, &value, PPOTrainingContextOptionsDefault(5), mem.nil_allocator()) == .ScratchSetupFailed &&
		PPOContextTestBytesEqual(rawptr(&trainer), trainerBytes[:]) && PPOContextTestBytesEqual(rawptr(&policy), policyBytes[:]) &&
		PPOContextTestBytesEqual(rawptr(&value), valueBytes[:]))
	testing.expect(t, PPOTrainingContextDestroy(&trainer) == .None && PPOTrainingContextDestroy(&trainer) == .None)
}

@(test)
PPOTrainingContextInitWithExternalParameterBuffers :: proc(t: ^testing.T) {
	policy, value: Sequential(1, 2, 2)
	trainer: PPOTrainingContext(1, 2, 2, 1, 2, 2)
	setup := PPOContextTestSetup(&policy, &value)
	testing.expect(t, setup)
	if !setup { return }
	policyDense := &policy.layers[0].storage.(DenseStorage(2))
	valueDense := &value.layers[0].storage.(DenseStorage(2))
	policyValues, policyGradients: [4]f32
	valueValues, valueGradients: [2]f32
	copy(policyValues[:], policyDense.weights.value.data); copy(policyGradients[:], policyDense.weights.grad.data)
	copy(valueValues[:], valueDense.weights.value.data); copy(valueGradients[:], valueDense.weights.grad.data)
	policyDense.weights.value.data, policyDense.weights.grad.data = policyValues[:], policyGradients[:]
	valueDense.weights.value.data, valueDense.weights.grad.data = valueValues[:], valueGradients[:]
	policyBefore, policyGradBefore, valueBefore, valueGradBefore := policyValues, policyGradients, valueValues, valueGradients
	policyBytes, valueBytes: [size_of(policy)]u8
	copy(policyBytes[:], mem.slice_ptr((^u8)(rawptr(&policy)), len(policyBytes)))
	copy(valueBytes[:], mem.slice_ptr((^u8)(rawptr(&value)), len(valueBytes)))
	state := PPOContextTestAllocator{backing = context.allocator}
	allocator := mem.Allocator{procedure = PPOContextTestAllocatorProc, data = &state}
	result := PPOTrainingContextInit(&trainer, &policy, &value, PPOTrainingContextOptionsDefault(5), allocator)
	testing.expect(t, result == .None)
	if result != .None { _ = PPOTrainingContextDestroy(&trainer); return }
	adam := PPOTrainingContextOptimizer(&trainer)
	testing.expect(t, adam != nil && len(adam.parameters) == 4 && len(adam.firstMoment) == 9 &&
		adam.parameters[0] == &policyDense.weights && adam.parameters[1] == &policyDense.bias &&
		adam.parameters[2] == &valueDense.weights && adam.parameters[3] == &valueDense.bias && state.allocations == 4)
	testing.expect(t, policyValues == policyBefore && policyGradients == policyGradBefore && valueValues == valueBefore &&
		valueGradients == valueGradBefore && PPOContextTestBytesEqual(rawptr(&policy), policyBytes[:]) && PPOContextTestBytesEqual(rawptr(&value), valueBytes[:]))
	testing.expect(t, PPOTrainingContextDestroy(&trainer) == .None && state.frees == 4 && state.badFrees == 0)
}

PPOContextTransactionTestBox :: struct {
	trainer: PPOTrainingContext(1, 2, 2, 1, 2, 2),
	policy, value: Sequential(1, 2, 2),
	policyValues, policyGradients, valueValues, valueGradients: [8]u64,
	padding: [4096]u8,
}

@(test)
PPOTrainingContextRejectsAliasedAllocations :: proc(t: ^testing.T) {
	for position in 1..=4 {
		for kind in 0..<11 {
			if kind == 10 && position == 1 { continue }
			box: PPOContextTransactionTestBox
			setup := PPOContextTestSetup(&box.policy, &box.value)
			testing.expect(t, setup)
			if !setup { return }
			policyDense := &box.policy.layers[0].storage.(DenseStorage(2))
			valueDense := &box.value.layers[0].storage.(DenseStorage(2))
			policyWeights, valueWeights := &policyDense.weights, &valueDense.weights
			policyValues := mem.slice_ptr((^f32)(rawptr(&box.policyValues)), len(policyWeights.value.data))
			policyGradients := mem.slice_ptr((^f32)(rawptr(&box.policyGradients)), len(policyWeights.grad.data))
			valueValues := mem.slice_ptr((^f32)(rawptr(&box.valueValues)), len(valueWeights.value.data))
			valueGradients := mem.slice_ptr((^f32)(rawptr(&box.valueGradients)), len(valueWeights.grad.data))
			copy(policyValues, policyWeights.value.data); copy(policyGradients, policyWeights.grad.data)
			copy(valueValues, valueWeights.value.data); copy(valueGradients, valueWeights.grad.data)
			policyWeights.value.data, policyWeights.grad.data = policyValues, policyGradients
			valueWeights.value.data, valueWeights.grad.data = valueValues, valueGradients
			addresses := [10]rawptr{
				rawptr(&box.trainer), rawptr(&box.policy), rawptr(&box.value),
				rawptr(&box.policyValues), rawptr(&box.policyGradients), rawptr(&box.valueValues), rawptr(&box.valueGradients),
				rawptr(uintptr(rawptr(&box.trainer))+8), rawptr(uintptr(rawptr(&box.policy))+8), rawptr(uintptr(rawptr(&box.value))+8),
			}
			before: [size_of(box)]u8
			copy(before[:], mem.slice_ptr((^u8)(rawptr(&box)), len(before)))
			state := PPOCheckpointInitOverlapAllocator{backing = context.allocator, injectAt = position, overlapPrevious = kind == 10}
			if kind < 10 { state.overlap = addresses[kind] }
			allocator := mem.Allocator{procedure = ppoCheckpointInitOverlapAllocatorProc, data = &state}
			result := PPOTrainingContextInit(&box.trainer, &box.policy, &box.value, PPOTrainingContextOptionsDefault(5), allocator)
			expected := PPOTrainingContextError.OptimizerSetupFailed
			if position == 1 { expected = .ScratchSetupFailed }
			unchanged := PPOContextTestBytesEqual(rawptr(&box), before[:])
			testing.expectf(t, result == expected && unchanged && state.attempts == position && state.realAllocations == position-1 &&
				state.realFrees == position-1 && state.fakeFrees == 1 && state.badFrees == 0,
				"position=%d alias=%d result=%v unchanged=%v real=%d/%d fake=%d bad=%d",
				position, kind, result, unchanged, state.realFrees, state.realAllocations, state.fakeFrees, state.badFrees)
			testing.expect(t, PPOTrainingContextDestroy(&box.trainer) == .None)
		}
	}
}

@(test)
PPOTrainingContextRejectsInvalidAllocationRanges :: proc(t: ^testing.T) {
	for position in 1..=4 {
		for kind in ([3]PPOCheckpointInitInvalidAllocation{.Short, .Misaligned, .Wrap}) {
			policy, value: Sequential(1, 2, 2)
			trainer: PPOTrainingContext(1, 2, 2, 1, 2, 2)
			setup := PPOContextTestSetup(&policy, &value)
			testing.expect(t, setup)
			if !setup { return }
			trainerBytes: [size_of(trainer)]u8
			policyBytes, valueBytes: [size_of(policy)]u8
			copy(trainerBytes[:], mem.slice_ptr((^u8)(rawptr(&trainer)), len(trainerBytes)))
			copy(policyBytes[:], mem.slice_ptr((^u8)(rawptr(&policy)), len(policyBytes)))
			copy(valueBytes[:], mem.slice_ptr((^u8)(rawptr(&value)), len(valueBytes)))
			state := PPOCheckpointInitInvalidAllocator{backing = context.allocator, kind = kind, injectAt = position}
			allocator := mem.Allocator{procedure = ppoCheckpointInitInvalidAllocatorProc, data = &state}
			result := PPOTrainingContextInit(&trainer, &policy, &value, PPOTrainingContextOptionsDefault(5), allocator)
			expected := PPOTrainingContextError.OptimizerSetupFailed
			if position == 1 { expected = .ScratchSetupFailed }
			unchanged := PPOContextTestBytesEqual(rawptr(&trainer), trainerBytes[:]) &&
				PPOContextTestBytesEqual(rawptr(&policy), policyBytes[:]) && PPOContextTestBytesEqual(rawptr(&value), valueBytes[:])
			testing.expectf(t, result == expected && unchanged && state.attempts == position && state.allocations == position &&
				state.frees == position && state.badFrees == 0,
				"position=%d kind=%v result=%v unchanged=%v allocated=%d freed=%d", position, kind, result, unchanged, state.allocations, state.frees)
			for i in 0..<position { testing.expect(t, state.freeOrder[i] == state.returned[position-1-i] && !state.live[i]) }
			testing.expect(t, PPOTrainingContextDestroy(&trainer) == .None && state.frees == position)
		}
	}
}

@(test)
PPOTrainingContextRetainsAdamModelValidation :: proc(t: ^testing.T) {
	for defect in 0..<6 {
		for failFree in ([2]bool{false, true}) {
			policy, value: Sequential(2, 3, 2)
			trainer: PPOTrainingContext(2, 3, 2, 2, 3, 2)
			setup := SequentialInit(&policy, 2, 17) && SequentialAddDense(&policy, 2) && SequentialAddDropout(&policy, 0.25) &&
				SequentialInit(&value, 2, 29) && SequentialAddDense(&value, 1) && SequentialAddDropout(&value, 0.25)
			testing.expect(t, setup)
			if !setup { return }
			policyDense, valueDense := &policy.layers[0].operation.(Dense), &value.layers[0].operation.(Dense)
			policyDropout, valueDropout := &policy.layers[1].operation.(Dropout), &value.layers[1].operation.(Dropout)
			policyStorage, valueStorage := &policy.layers[0].storage.(DenseStorage(3)), &value.layers[0].storage.(DenseStorage(3))
			policyMask, valueMask := &policy.layers[1].storage.(DropoutStorage(3, 2)), &value.layers[1].storage.(DropoutStorage(3, 2))
			switch defect {
			case 0: policyDense.input = nil
			case 1: valueDense.output = nil
			case 2: policyDropout.randomState = nil
			case 3: valueDropout.randomState = nil
			case 4: policyStorage.weights.value.data = valueMask.maskData[:4]
			case 5: valueStorage.weights.grad.data = policyMask.maskData[:2]
			}
			parameters: [8]^core.Node
			_, _, combinedOk := PPOCheckpointCombinedParameters(&policy, &value, parameters[:])
			testing.expect(t, combinedOk)
			policyBytes, valueBytes: [size_of(policy)]u8
			copy(policyBytes[:], mem.slice_ptr((^u8)(rawptr(&policy)), len(policyBytes)))
			copy(valueBytes[:], mem.slice_ptr((^u8)(rawptr(&value)), len(valueBytes)))
			state := PPOContextTestAllocator{backing = context.allocator}
			if failFree { state.failFreeAt = 1 }
			allocator := mem.Allocator{procedure = PPOContextTestAllocatorProc, data = &state}
			result := PPOTrainingContextInit(&trainer, &policy, &value, PPOTrainingContextOptionsDefault(5), allocator)
			expected, expectedFrees := PPOTrainingContextError.OptimizerSetupFailed, 1
			if failFree { expected, expectedFrees = .CleanupFailed, 0 }
			testing.expectf(t, result == expected && state.attempts == 1 && state.allocations == 1 && state.freeCalls == 1 &&
				state.frees == expectedFrees && PPOContextTestBytesEqual(rawptr(&policy), policyBytes[:]) &&
				PPOContextTestBytesEqual(rawptr(&value), valueBytes[:]), "defect=%d failFree=%v result=%v", defect, failFree, result)
			if failFree {
				testing.expect(t, trainer.phase == .Destroying && trainer.pending.blocks[0] == state.allocated[0] && state.live[0])
			}
			testing.expect(t, PPOTrainingContextDestroy(&trainer) == .None && state.frees == 1 && state.badFrees == 0)
		}
	}
}

@(test)
PPOTrainingContextInitDoesNotAdvanceDropoutRNG :: proc(t: ^testing.T) {
	for failure in 0..=4 {
		policy, value: Sequential(2, 3, 2)
		trainer: PPOTrainingContext(2, 3, 2, 2, 3, 2)
		setup := SequentialInit(&policy, 2, 17) && SequentialAddDense(&policy, 2) && SequentialAddDropout(&policy, 0.25) &&
			SequentialInit(&value, 2, 29) && SequentialAddDense(&value, 1) && SequentialAddDropout(&value, 0.25)
		testing.expect(t, setup)
		if !setup { return }
		policyBytes, valueBytes: [size_of(policy)]u8
		copy(policyBytes[:], mem.slice_ptr((^u8)(rawptr(&policy)), len(policyBytes)))
		copy(valueBytes[:], mem.slice_ptr((^u8)(rawptr(&value)), len(valueBytes)))
		policyRandomBefore, valueRandomBefore := policy.randomState, value.randomState
		state := PPOContextTestAllocator{backing = context.allocator, pointerAndErrorAt = failure}
		allocator := mem.Allocator{procedure = PPOContextTestAllocatorProc, data = &state}
		options := PPOTrainingContextOptionsDefault(5)
		result := PPOTrainingContextInit(&trainer, &policy, &value, options, allocator)
		expected := PPOTrainingContextError.OptimizerSetupFailed
		if failure == 0 { expected = .None } else if failure == 1 { expected = .ScratchSetupFailed }
		testing.expectf(t, result == expected && policy.randomState == policyRandomBefore && value.randomState == valueRandomBefore &&
			PPOContextTestBytesEqual(rawptr(&policy), policyBytes[:]) && PPOContextTestBytesEqual(rawptr(&value), valueBytes[:]),
			"failure=%d result=%v", failure, result)
		if failure == 0 {
			learner := PPOTrainingContextState(&trainer)
			testing.expect(t, learner != nil && learner.policyRandomState == options.policySeed && learner.shuffleRandomState == options.shuffleSeed)
		}
		testing.expect(t, PPOTrainingContextDestroy(&trainer) == .None && state.frees == state.allocations && state.badFrees == 0)
	}
}
