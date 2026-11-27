package nn

import "../core"
import "../rl"
import "core:math"
import "core:mem"
import "core:testing"

PPOContextCheckpointBuildModels :: proc(
	policy: ^Sequential($pl, $pw, $pb), value: ^Sequential($vl, $vw, $vb),
	inputWidth, actionWidth, hiddenWidth: int,
) -> bool {
	if !SequentialInit(policy, inputWidth, 17) || !SequentialInit(value, inputWidth, 29) { return false }
	if hiddenWidth > 0 && (!SequentialAddDense(policy, hiddenWidth) || !SequentialAddDense(value, hiddenWidth)) { return false }
	return SequentialAddDense(policy, actionWidth) && SequentialAddDense(value, 1)
}

PPOContextCheckpointMake :: proc(
	policy: ^Sequential($pl, $pw, $pb), value: ^Sequential($vl, $vw, $vb),
	options: PPOTrainingContextOptions, output: []u8,
) -> (int, PPOTrainingContextError) {
	trainer: PPOTrainingContext(pl, pw, pb, vl, vw, vb)
	result := PPOTrainingContextInit(&trainer, policy, value, options)
	if result != .None { return 0, result }
	defer PPOTrainingContextDestroy(&trainer)
	policyScratch, valueScratch: [4096]u8
	return PPOTrainingContextCheckpointWrite(&trainer, output, policyScratch[:], valueScratch[:])
}

PPOContextCheckpointSnapshot :: struct($pl, $pw, $pb, $vl, $vw, $vb: int) {
	trainer: [size_of(PPOTrainingContext(pl, pw, pb, vl, vw, vb))]u8,
	policy: [size_of(Sequential(pl, pw, pb))]u8,
	value: [size_of(Sequential(vl, vw, vb))]u8,
	sizes: [4]int,
	allocations: [4][4096]u8,
}

PPOContextCheckpointSnapshotTake :: proc(
	trainer: ^PPOTrainingContext($pl, $pw, $pb, $vl, $vw, $vb), pointers: []rawptr, sizes: []int,
	snapshot: ^PPOContextCheckpointSnapshot(pl, pw, pb, vl, vw, vb),
) -> bool {
	if len(pointers) != 4 || len(sizes) != 4 || trainer.policy == nil || trainer.value == nil { return false }
	copy(snapshot.trainer[:], mem.slice_ptr((^u8)(rawptr(trainer)), len(snapshot.trainer)))
	copy(snapshot.policy[:], mem.slice_ptr((^u8)(rawptr(trainer.policy)), len(snapshot.policy)))
	copy(snapshot.value[:], mem.slice_ptr((^u8)(rawptr(trainer.value)), len(snapshot.value)))
	for i in 0..<4 {
		if pointers[i] == nil || sizes[i] < 0 || sizes[i] > len(snapshot.allocations[i]) { return false }
		snapshot.sizes[i] = sizes[i]
		copy(snapshot.allocations[i][:sizes[i]], mem.slice_ptr((^u8)(pointers[i]), sizes[i]))
	}
	return true
}

PPOContextCheckpointSnapshotEqual :: proc(
	trainer: ^PPOTrainingContext($pl, $pw, $pb, $vl, $vw, $vb), pointers: []rawptr,
	snapshot: ^PPOContextCheckpointSnapshot(pl, pw, pb, vl, vw, vb),
) -> bool {
	if len(pointers) != 4 || !PPOContextTestBytesEqual(rawptr(trainer), snapshot.trainer[:]) ||
		!PPOContextTestBytesEqual(rawptr(trainer.policy), snapshot.policy[:]) ||
		!PPOContextTestBytesEqual(rawptr(trainer.value), snapshot.value[:]) { return false }
	for i in 0..<4 {
		if !PPOContextTestBytesEqual(pointers[i], snapshot.allocations[i][:snapshot.sizes[i]]) { return false }
	}
	return true
}

PPOContextCheckpointExpectReadFailure :: proc(
	t: ^testing.T, label: string, trainer: ^PPOTrainingContext($pl, $pw, $pb, $vl, $vw, $vb),
	pointers: []rawptr, sizes: []int, input: []u8, expected: PPOTrainingContextError,
	alternative: PPOTrainingContextError = .None,
) -> bool {
	snapshot: PPOContextCheckpointSnapshot(pl, pw, pb, vl, vw, vb)
	captured := PPOContextCheckpointSnapshotTake(trainer, pointers, sizes, &snapshot)
	testing.expectf(t, captured && len(input) <= 4096, "%s: snapshot", label)
	if !captured || len(input) > 4096 { return false }
	inputBefore: [4096]u8
	copy(inputBefore[:], input)
	result := PPOTrainingContextCheckpointRead(trainer, input)
	correct := result == expected || alternative != .None && result == alternative
	testing.expectf(t, correct, "%s: got %v, expected %v", label, result, expected)
	unchanged := PPOContextCheckpointSnapshotEqual(trainer, pointers, &snapshot) &&
		PPOContextTestBytesEqual(rawptr(raw_data(input)), inputBefore[:len(input)])
	testing.expectf(t, unchanged, "%s: destination or input changed", label)
	return correct && unchanged
}

PPOContextCheckpointOptimizersEqual :: proc(a, b: ^Adam) -> bool {
	if a == nil || b == nil || a.step != b.step || a.learningRate != b.learningRate ||
		a.beta1 != b.beta1 || a.beta2 != b.beta2 || a.epsilon != b.epsilon ||
		len(a.parameters) != len(b.parameters) || len(a.firstMoment) != len(b.firstMoment) ||
		len(a.secondMoment) != len(b.secondMoment) { return false }
	for item, i in a.firstMoment {
		if item != b.firstMoment[i] || a.secondMoment[i] != b.secondMoment[i] { return false }
	}
	return true
}

@(test)
PPOTrainingContextCheckpointResumeMatchesUninterrupted :: proc(t: ^testing.T) {
	policy, value, restoredPolicy, restoredValue: Sequential(1, 2, 2)
	trainer, restored: PPOTrainingContext(1, 2, 2, 1, 2, 2)
	setup := PPOContextTestSetup(&policy, &value) &&
		SequentialInit(&restoredPolicy, 2, 41) && SequentialAddDense(&restoredPolicy, 2) &&
		SequentialInit(&restoredValue, 2, 43) && SequentialAddDense(&restoredValue, 1)
	testing.expect(t, setup)
	if !setup { return }
	options := PPOTrainingContextOptionsDefault(5)
	options.objective = {0.15, 0.02, 0.6, 0.75}
	options.fit = {epochs = 2, batchSize = 2, maxGradientNorm = 0.01, finalLearningRate = 0.002}
	options.policySeed, options.shuffleSeed = 12345, 77
	options.learningRate, options.beta1, options.beta2, options.epsilon = 0.01, 0.8, 0.95, 1e-6
	destOptions := PPOTrainingContextOptionsDefault(7)
	destOptions.fit = {epochs = 3, batchSize = 0, maxGradientNorm = 0.7}
	destOptions.policySeed, destOptions.shuffleSeed = 999, 888
	allocatorState, restoredAllocatorState := PPOContextTestAllocator{backing = context.allocator}, PPOContextTestAllocator{backing = context.allocator}
	allocator := mem.Allocator{procedure = PPOContextTestAllocatorProc, data = &allocatorState}
	restoredAllocator := mem.Allocator{procedure = PPOContextTestAllocatorProc, data = &restoredAllocatorState}
	result := PPOTrainingContextInit(&trainer, &policy, &value, options, allocator)
	testing.expect(t, result == .None)
	if result != .None { return }
	defer PPOTrainingContextDestroy(&trainer)
	result = PPOTrainingContextInit(&restored, &restoredPolicy, &restoredValue, destOptions, restoredAllocator)
	testing.expect(t, result == .None)
	if result != .None { return }
	defer PPOTrainingContextDestroy(&restored)
	backing, restoredBacking: PPOContextTestRolloutBacking
	buffer, restoredBuffer: rl.RolloutBuffer
	setup = PPOContextTestRolloutInit(&buffer, &backing) && PPOContextTestRolloutInit(&restoredBuffer, &restoredBacking)
	testing.expect(t, setup)
	if !setup { return }
	// Give the source nonzero moments, counters and independently advanced RNGs.
	for _ in 0..<2 {
		state := PPOTrainingContextState(&trainer)
		setup = PPOContextTestCollect(&policy, &value, state, &buffer, 5) && PPOTrainingContextRecordRollout(&trainer) == .None
		testing.expect(t, setup)
		if !setup { return }
		stats, fitError := PPOTrainingContextFit(&trainer, &buffer)
		testing.expect(t, fitError == .None && stats.updates == 6)
		if fitError != .None { return }
	}
	testing.expect(t, PPOTrainingContextState(&trainer).updateCount == 12 && PPOTrainingContextState(&trainer).rolloutCount == 2 &&
		PPOTrainingContextOptimizer(&trainer).step == 12)
	// The destination is also live and nonempty before it is replaced.
	setup = PPOContextTestCollect(&restoredPolicy, &restoredValue, PPOTrainingContextState(&restored), &restoredBuffer, 5) &&
		PPOTrainingContextRecordRollout(&restored) == .None
	testing.expect(t, setup)
	if !setup { return }
	_, destFit := PPOTrainingContextFit(&restored, &restoredBuffer)
	testing.expect(t, destFit == .None)
	if destFit != .None { return }
	checkpoint, roundTrip, policyScratch, valueScratch: [4096]u8
	size, writeError := PPOTrainingContextCheckpointWrite(&trainer, checkpoint[:], policyScratch[:], valueScratch[:])
	testing.expect(t, writeError == .None && size > 0)
	if writeError != .None || size <= 0 { return }
	inputBefore := checkpoint
	result = PPOTrainingContextCheckpointRead(&restored, checkpoint[:size])
	testing.expect(t, result == .None && checkpoint == inputBefore)
	if result != .None { return }
	testing.expect(t, restored.rolloutCapacity == 7 && restored.observationWidth == 2 && restored.actionCount == 2 &&
		restored.objective == options.objective && restored.fitConfig == options.fit &&
		PPOTrainingContextState(&trainer)^ == PPOTrainingContextState(&restored)^ &&
		PPOContextCheckpointOptimizersEqual(PPOTrainingContextOptimizer(&trainer), PPOTrainingContextOptimizer(&restored)) &&
		PPOContextTestModelsEqual(&policy, &restoredPolicy) && PPOContextTestModelsEqual(&value, &restoredValue))
	roundSize, roundError := PPOTrainingContextCheckpointWrite(&restored, roundTrip[:], policyScratch[:], valueScratch[:])
	testing.expect(t, roundError == .None && roundSize == size && PPOContextTestBytesEqual(rawptr(raw_data(roundTrip[:size])), checkpoint[:size]))
	for iteration in 0..<3 {
		state, restoredState := PPOTrainingContextState(&trainer), PPOTrainingContextState(&restored)
		setup = PPOContextTestCollect(&policy, &value, state, &buffer, 5) &&
			PPOContextTestCollect(&restoredPolicy, &restoredValue, restoredState, &restoredBuffer, 5)
		testing.expect(t, setup && backing == restoredBacking && state^ == restoredState^)
		if !setup { return }
		testing.expect(t, PPOTrainingContextRecordRollout(&trainer) == .None && PPOTrainingContextRecordRollout(&restored) == .None)
		stats, fitError := PPOTrainingContextFit(&trainer, &buffer)
		restoredStats, restoredError := PPOTrainingContextFit(&restored, &restoredBuffer)
		testing.expect(t, fitError == .None && restoredError == .None && stats == restoredStats && stats.updates == 6 &&
			state^ == restoredState^ && state.updateCount == u64(18+iteration*6) &&
			PPOContextCheckpointOptimizersEqual(PPOTrainingContextOptimizer(&trainer), PPOTrainingContextOptimizer(&restored)) &&
			PPOContextTestModelsEqual(&policy, &restoredPolicy) && PPOContextTestModelsEqual(&value, &restoredValue))
		metrics, restoredMetrics := PPOTrainingContextEpochMetrics(&trainer), PPOTrainingContextEpochMetrics(&restored)
		testing.expect(t, len(metrics) >= 2 && len(restoredMetrics) >= 2 && metrics[0] == restoredMetrics[0] && metrics[1] == restoredMetrics[1])
		if fitError != .None || restoredError != .None { return }
	}
	testing.expect(t, allocatorState.allocations == 4 && allocatorState.freeCalls == 0 &&
		restoredAllocatorState.allocations == 4 && restoredAllocatorState.freeCalls == 0)
}

@(test)
PPOTrainingContextCheckpointSmallerArchitecture :: proc(t: ^testing.T) {
	smallPolicy, smallValue, largePolicy, largeValue: Sequential(2, 3, 2)
	small, large: PPOTrainingContext(2, 3, 2, 2, 3, 2)
	setup := PPOContextCheckpointBuildModels(&smallPolicy, &smallValue, 2, 2, 0) &&
		PPOContextCheckpointBuildModels(&largePolicy, &largeValue, 2, 2, 3)
	testing.expect(t, setup)
	if !setup { return }
	external := [6]f32{1, 2, 3, 4, 5, 6}
	largeDense := &largePolicy.layers[0].storage.(DenseStorage(3))
	largeDense.weights.value.data = external[:]
	options := PPOTrainingContextOptionsDefault(5)
	options.fit = {epochs = 2, batchSize = 2, finalLearningRate = 0.003}
	options.policySeed, options.shuffleSeed = 17, 29
	result := PPOTrainingContextInit(&small, &smallPolicy, &smallValue, options)
	testing.expect(t, result == .None)
	if result != .None { return }
	defer PPOTrainingContextDestroy(&small)
	largeOptions := options
	largeOptions.fit.epochs = 3
	result = PPOTrainingContextInit(&large, &largePolicy, &largeValue, largeOptions)
	testing.expect(t, result == .None)
	if result != .None { return }
	defer PPOTrainingContextDestroy(&large)
	backing, largeBacking: PPOContextTestRolloutBacking
	buffer, largeBuffer: rl.RolloutBuffer
	setup = PPOContextTestRolloutInit(&buffer, &backing) && PPOContextTestRolloutInit(&largeBuffer, &largeBacking) &&
		PPOContextTestCollect(&smallPolicy, &smallValue, PPOTrainingContextState(&small), &buffer, 5) &&
		PPOTrainingContextRecordRollout(&small) == .None
	testing.expect(t, setup)
	if !setup { return }
	_, fitError := PPOTrainingContextFit(&small, &buffer)
	testing.expect(t, fitError == .None)
	if fitError != .None { return }
	smallData, largeData, roundTrip, policyScratch, valueScratch: [4096]u8
	smallSize, smallError := PPOTrainingContextCheckpointWrite(&small, smallData[:], policyScratch[:], valueScratch[:])
	largeSize, largeError := PPOTrainingContextCheckpointWrite(&large, largeData[:], policyScratch[:], valueScratch[:])
	testing.expect(t, smallError == .None && largeError == .None && smallSize > 0 && largeSize > 0)
	if smallError != .None || largeError != .None { return }
	originalLargeState := PPOTrainingContextState(&large)^
	parameters, first, second, storageOk := PPOOwnedAdamStorage(&large.adam)
	testing.expect(t, storageOk && len(parameters) == 8 && len(first) == 30 && len(second) == 30)
	if !storageOk { return }
	parameterAddress, firstAddress, secondAddress := raw_data(parameters), raw_data(first), raw_data(second)
	result = PPOTrainingContextCheckpointRead(&large, smallData[:smallSize])
	testing.expect(t, result == .None)
	if result != .None { return }
	adam := PPOTrainingContextOptimizer(&large)
	newDense := &largePolicy.layers[0].storage.(DenseStorage(3))
	testing.expect(t, largePolicy.layerCount == 1 && largeValue.layerCount == 1 && external == [6]f32{1, 2, 3, 4, 5, 6} &&
		raw_data(newDense.weights.value.data) == raw_data(newDense.weightData[:]) &&
		len(adam.parameters) == 4 && len(adam.firstMoment) == 9 && adam.parameters[0] == &newDense.weights &&
		PPOContextCheckpointOptimizersEqual(PPOTrainingContextOptimizer(&small), adam) &&
		PPOTrainingContextState(&small)^ == PPOTrainingContextState(&large)^ && large.fitConfig == small.fitConfig)
	parameters, first, second, storageOk = PPOOwnedAdamStorage(&large.adam)
	testing.expect(t, storageOk && len(parameters) == 8 && len(first) == 30 && len(second) == 30 &&
		raw_data(parameters) == parameterAddress && raw_data(first) == firstAddress && raw_data(second) == secondAddress)
	roundSize, roundError := PPOTrainingContextCheckpointWrite(&large, roundTrip[:], policyScratch[:], valueScratch[:])
	testing.expect(t, roundError == .None && roundSize == smallSize && PPOContextTestBytesEqual(rawptr(raw_data(roundTrip[:smallSize])), smallData[:smallSize]))
	for _ in 0..<2 {
		setup = PPOContextTestCollect(&smallPolicy, &smallValue, PPOTrainingContextState(&small), &buffer, 5) &&
			PPOContextTestCollect(&largePolicy, &largeValue, PPOTrainingContextState(&large), &largeBuffer, 5)
		testing.expect(t, setup && backing == largeBacking)
		if !setup { return }
		testing.expect(t, PPOTrainingContextRecordRollout(&small) == .None && PPOTrainingContextRecordRollout(&large) == .None)
		stats, err := PPOTrainingContextFit(&small, &buffer)
		other, otherErr := PPOTrainingContextFit(&large, &largeBuffer)
		testing.expect(t, err == .None && otherErr == .None && stats == other &&
			PPOTrainingContextState(&small)^ == PPOTrainingContextState(&large)^ &&
			PPOContextCheckpointOptimizersEqual(PPOTrainingContextOptimizer(&small), PPOTrainingContextOptimizer(&large)) &&
			PPOContextTestModelsEqual(&smallPolicy, &largePolicy) && PPOContextTestModelsEqual(&smallValue, &largeValue))
		if err != .None || otherErr != .None { return }
	}
	// Shrinking the active Adam binding must not discard the larger owned capacity.
	result = PPOTrainingContextCheckpointRead(&large, largeData[:largeSize])
	testing.expect(t, result == .None && largePolicy.layerCount == 2 && largeValue.layerCount == 2 &&
		PPOTrainingContextState(&large)^ == originalLargeState && len(PPOTrainingContextOptimizer(&large).parameters) == 8 &&
		len(PPOTrainingContextOptimizer(&large).firstMoment) == 30 && external == [6]f32{1, 2, 3, 4, 5, 6})
	if result != .None { return }
	setup = PPOContextTestCollect(&largePolicy, &largeValue, PPOTrainingContextState(&large), &largeBuffer, 5)
	testing.expect(t, setup)
	if !setup { return }
	_, fitError = PPOTrainingContextFit(&large, &largeBuffer)
	testing.expect(t, fitError == .None)
}

@(test)
PPOTrainingContextCheckpointIncompatibleStorageAndWidths :: proc(t: ^testing.T) {
	sourcePolicy, sourceValue, bigPolicy, bigValue: Sequential(2, 3, 2)
	setup := PPOContextCheckpointBuildModels(&sourcePolicy, &sourceValue, 2, 2, 0) &&
		PPOContextCheckpointBuildModels(&bigPolicy, &bigValue, 2, 2, 3)
	testing.expect(t, setup)
	if !setup { return }
	options := PPOTrainingContextOptionsDefault(5)
	options.fit = {epochs = 2, batchSize = 2}
	smallData, bigData, epochData: [4096]u8
	smallSize, smallError := PPOContextCheckpointMake(&sourcePolicy, &sourceValue, options, smallData[:])
	bigSize, bigError := PPOContextCheckpointMake(&bigPolicy, &bigValue, options, bigData[:])
	epochOptions := options
	epochOptions.fit.epochs = 3
	epochSize, epochError := PPOContextCheckpointMake(&sourcePolicy, &sourceValue, epochOptions, epochData[:])
	testing.expect(t, smallError == .None && bigError == .None && epochError == .None)
	if smallError != .None || bigError != .None || epochError != .None { return }
	for mode in 0..<4 {
		policy, value: Sequential(2, 3, 2)
		trainer: PPOTrainingContext(2, 3, 2, 2, 3, 2)
		hidden := 0
		if mode == 1 { hidden = 1 } // Same pointer count as the big checkpoint, but fewer moments.
		setup = PPOContextCheckpointBuildModels(&policy, &value, 2, 2, hidden)
		testing.expect(t, setup)
		if !setup { return }
		destOptions := options
		if mode == 2 { destOptions.fit.batchSize = 1 }
		allocatorState := PPOContextTestAllocator{backing = context.allocator}
		allocator := mem.Allocator{procedure = PPOContextTestAllocatorProc, data = &allocatorState}
		result := PPOTrainingContextInit(&trainer, &policy, &value, destOptions, allocator)
		testing.expect(t, result == .None)
		if result != .None { return }
		defer PPOTrainingContextDestroy(&trainer)
		input := bigData[:bigSize]
		label := "optimizer pointers"
		if mode == 1 { label = "optimizer moments" }
		if mode == 2 { input = smallData[:smallSize]; label = "minibatch scratch" }
		if mode == 3 { input = epochData[:epochSize]; label = "epoch scratch" }
		if !PPOContextCheckpointExpectReadFailure(t, label, &trainer, allocatorState.allocated[:4], allocatorState.sizes[:4], input, .CheckpointIncompatible) { return }
	}
	for mode in 0..<2 {
		policy, value: Sequential(2, 3, 2)
		trainer: PPOTrainingContext(2, 3, 2, 2, 3, 2)
		inputWidth, actionWidth := 1, 2
		if mode == 1 { inputWidth, actionWidth = 2, 1 }
		setup = PPOContextCheckpointBuildModels(&policy, &value, inputWidth, actionWidth, 0)
		testing.expect(t, setup)
		if !setup { return }
		allocatorState := PPOContextTestAllocator{backing = context.allocator}
		allocator := mem.Allocator{procedure = PPOContextTestAllocatorProc, data = &allocatorState}
		result := PPOTrainingContextInit(&trainer, &policy, &value, options, allocator)
		testing.expect(t, result == .None)
		if result != .None { return }
		defer PPOTrainingContextDestroy(&trainer)
		if !PPOContextCheckpointExpectReadFailure(t, "observation/action width", &trainer, allocatorState.allocated[:4], allocatorState.sizes[:4], smallData[:smallSize], .CheckpointIncompatible) { return }
	}
	// A zero checkpoint batch means the model default, not the destination's explicit batch of one.
	defaultData: [4096]u8
	defaultOptions := options
	defaultOptions.fit.batchSize = 0
	defaultSize, defaultError := PPOContextCheckpointMake(&sourcePolicy, &sourceValue, defaultOptions, defaultData[:])
	testing.expect(t, defaultError == .None)
	if defaultError != .None { return }
	policy, value: Sequential(2, 3, 2)
	trainer: PPOTrainingContext(2, 3, 2, 2, 3, 2)
	setup = PPOContextCheckpointBuildModels(&policy, &value, 2, 2, 0)
	testing.expect(t, setup)
	if !setup { return }
	allocatorState := PPOContextTestAllocator{backing = context.allocator}
	allocator := mem.Allocator{procedure = PPOContextTestAllocatorProc, data = &allocatorState}
	narrow := options
	narrow.fit.batchSize = 1
	result := PPOTrainingContextInit(&trainer, &policy, &value, narrow, allocator)
	testing.expect(t, result == .None)
	if result != .None { return }
	defer PPOTrainingContextDestroy(&trainer)
	_ = PPOContextCheckpointExpectReadFailure(t, "default minibatch scratch", &trainer, allocatorState.allocated[:4], allocatorState.sizes[:4], defaultData[:defaultSize], .CheckpointIncompatible)
}

@(test)
PPOTrainingContextCheckpointCapacityAndOptimizerKind :: proc(t: ^testing.T) {
	smallPolicy, smallValue: Sequential(1, 2, 2)
	largePolicy, largeValue: Sequential(2, 3, 2)
	setup := PPOContextCheckpointBuildModels(&smallPolicy, &smallValue, 2, 2, 0) &&
		PPOContextCheckpointBuildModels(&largePolicy, &largeValue, 2, 2, 0)
	testing.expect(t, setup)
	if !setup { return }
	options := PPOTrainingContextOptionsDefault(5)
	options.fit = {epochs = 2, batchSize = 2}
	smallData, largeData, sgdData, policyScratch, valueScratch: [4096]u8
	smallSize, smallError := PPOContextCheckpointMake(&smallPolicy, &smallValue, options, smallData[:])
	largeSize, largeError := PPOContextCheckpointMake(&largePolicy, &largeValue, options, largeData[:])
	sgdSize, sgdOk := PPOCheckpointWrite(&largePolicy, &largeValue, SequentialSGD{0.01},
		PPOTrainingState{policyRandomState = 17, shuffleRandomState = 29}, options.objective, options.fit,
		sgdData[:], policyScratch[:], valueScratch[:])
	testing.expect(t, smallError == .None && largeError == .None && sgdOk)
	if smallError != .None || largeError != .None || !sgdOk { return }
	probePolicy, probeValue: Sequential(2, 3, 2)
	_, _, _, _, sgdReadable := PPOCheckpointRead(&probePolicy, &probeValue, sgdData[:sgdSize], nil, nil, nil, nil)
	probeAdam: Adam
	probeParameters: [4]^core.Node
	probeFirst, probeSecond: [9]f32
	_, _, _, _, largeReadable := PPOCheckpointRead(&probePolicy, &probeValue, largeData[:largeSize], &probeAdam, probeParameters[:], probeFirst[:], probeSecond[:])
	testing.expect(t, sgdReadable && largeReadable)
	if !sgdReadable || !largeReadable { return }
	{
		policy, value: Sequential(2, 3, 2)
		trainer: PPOTrainingContext(2, 3, 2, 2, 3, 2)
		setup = PPOContextCheckpointBuildModels(&policy, &value, 2, 2, 0)
		testing.expect(t, setup)
		if !setup { return }
		state := PPOContextTestAllocator{backing = context.allocator}
		allocator := mem.Allocator{procedure = PPOContextTestAllocatorProc, data = &state}
		result := PPOTrainingContextInit(&trainer, &policy, &value, options, allocator)
		testing.expect(t, result == .None)
		if result != .None { return }
		defer PPOTrainingContextDestroy(&trainer)
		if !PPOContextCheckpointExpectReadFailure(t, "smaller encoded type", &trainer, state.allocated[:4], state.sizes[:4], smallData[:smallSize], .CheckpointIncompatible) { return }
		// A structurally valid SGD checkpoint is not an Adam context checkpoint.
		if !PPOContextCheckpointExpectReadFailure(t, "SGD optimizer", &trainer, state.allocated[:4], state.sizes[:4], sgdData[:sgdSize], .CheckpointIncompatible) { return }
	}
	{
		policy, value: Sequential(1, 2, 2)
		trainer: PPOTrainingContext(1, 2, 2, 1, 2, 2)
		setup = PPOContextCheckpointBuildModels(&policy, &value, 2, 2, 0)
		testing.expect(t, setup)
		if !setup { return }
		state := PPOContextTestAllocator{backing = context.allocator}
		allocator := mem.Allocator{procedure = PPOContextTestAllocatorProc, data = &state}
		result := PPOTrainingContextInit(&trainer, &policy, &value, options, allocator)
		testing.expect(t, result == .None)
		if result != .None { return }
		defer PPOTrainingContextDestroy(&trainer)
		_ = PPOContextCheckpointExpectReadFailure(t, "larger encoded type", &trainer, state.allocated[:4], state.sizes[:4], largeData[:largeSize], .CheckpointIncompatible)
	}
}

@(test)
PPOTrainingContextCheckpointIndependentModelCapacities :: proc(t: ^testing.T) {
	normalPolicy, normalValue, policy, value: Sequential(2, 3, 2)
	policyLayers, valueLayers: Sequential(1, 3, 2)
	policyWidth, valueWidth: Sequential(2, 2, 2)
	policyBatch, valueBatch: Sequential(2, 3, 1)
	setup := PPOContextCheckpointBuildModels(&normalPolicy, &normalValue, 2, 2, 0) &&
		PPOContextCheckpointBuildModels(&policy, &value, 2, 2, 0) &&
		SequentialInit(&policyLayers, 2, 1) && SequentialAddDense(&policyLayers, 2) &&
		SequentialInit(&valueLayers, 2, 2) && SequentialAddDense(&valueLayers, 1) &&
		SequentialInit(&policyWidth, 2, 3) && SequentialAddDense(&policyWidth, 2) &&
		SequentialInit(&valueWidth, 2, 4) && SequentialAddDense(&valueWidth, 1) &&
		SequentialInit(&policyBatch, 2, 5) && SequentialAddDense(&policyBatch, 2) &&
		SequentialInit(&valueBatch, 2, 6) && SequentialAddDense(&valueBatch, 1)
	testing.expect(t, setup)
	if !setup { return }
	trainer: PPOTrainingContext(2, 3, 2, 2, 3, 2)
	options := PPOTrainingContextOptionsDefault(5)
	options.fit = {epochs = 2, batchSize = 1}
	state := PPOContextTestAllocator{backing = context.allocator}
	allocator := mem.Allocator{procedure = PPOContextTestAllocatorProc, data = &state}
	result := PPOTrainingContextInit(&trainer, &policy, &value, options, allocator)
	testing.expect(t, result == .None)
	if result != .None { return }
	defer PPOTrainingContextDestroy(&trainer)
	checkpoint: [4096]u8
	for mode in 0..<6 {
		size: int
		error: PPOTrainingContextError
		switch mode {
		case 0: size, error = PPOContextCheckpointMake(&policyLayers, &normalValue, options, checkpoint[:])
		case 1: size, error = PPOContextCheckpointMake(&policyWidth, &normalValue, options, checkpoint[:])
		case 2: size, error = PPOContextCheckpointMake(&policyBatch, &normalValue, options, checkpoint[:])
		case 3: size, error = PPOContextCheckpointMake(&normalPolicy, &valueLayers, options, checkpoint[:])
		case 4: size, error = PPOContextCheckpointMake(&normalPolicy, &valueWidth, options, checkpoint[:])
		case 5: size, error = PPOContextCheckpointMake(&normalPolicy, &valueBatch, options, checkpoint[:])
		}
		testing.expectf(t, error == .None && size > 0, "capacity fixture %d", mode)
		if error != .None || size <= 0 { return }
		if !PPOContextCheckpointExpectReadFailure(t, "independent model capacity", &trainer, state.allocated[:4], state.sizes[:4], checkpoint[:size], .CheckpointIncompatible) { return }
	}
}

@(test)
PPOTrainingContextCheckpointMalformedIsAtomic :: proc(t: ^testing.T) {
	policy, value: Sequential(2, 3, 2)
	trainer: PPOTrainingContext(2, 3, 2, 2, 3, 2)
	setup := PPOContextCheckpointBuildModels(&policy, &value, 2, 2, 0)
	testing.expect(t, setup)
	if !setup { return }
	options := PPOTrainingContextOptionsDefault(5)
	options.fit = {epochs = 2, batchSize = 2}
	state := PPOContextTestAllocator{backing = context.allocator}
	allocator := mem.Allocator{procedure = PPOContextTestAllocatorProc, data = &state}
	result := PPOTrainingContextInit(&trainer, &policy, &value, options, allocator)
	testing.expect(t, result == .None)
	if result != .None { return }
	defer PPOTrainingContextDestroy(&trainer)
	backing: PPOContextTestRolloutBacking
	buffer: rl.RolloutBuffer
	setup = PPOContextTestRolloutInit(&buffer, &backing) && PPOContextTestCollect(&policy, &value, PPOTrainingContextState(&trainer), &buffer, 5) &&
		PPOTrainingContextRecordRollout(&trainer) == .None
	testing.expect(t, setup)
	if !setup { return }
	_, fitError := PPOTrainingContextFit(&trainer, &buffer)
	testing.expect(t, fitError == .None)
	if fitError != .None { return }
	checkpoint, altered, policyScratch, valueScratch: [4096]u8
	size, writeError := PPOTrainingContextCheckpointWrite(&trainer, checkpoint[:], policyScratch[:], valueScratch[:])
	testing.expect(t, writeError == .None && size > 0 && size < len(checkpoint))
	if writeError != .None || size <= 0 || size >= len(checkpoint) { return }
	for length in 0..<size {
		if !PPOContextCheckpointExpectReadFailure(t, "truncated", &trainer, state.allocated[:4], state.sizes[:4], checkpoint[:length], .InvalidCheckpoint) { return }
	}
	policyInput, valueInput, peekOk := PPOCheckpointPeekModelPayloads(checkpoint[:size])
	testing.expect(t, peekOk)
	if !peekOk { return }
	policyOffset := int(uintptr(rawptr(raw_data(policyInput)))-uintptr(rawptr(raw_data(checkpoint[:]))))
	valueOffset := int(uintptr(rawptr(raw_data(valueInput)))-uintptr(rawptr(raw_data(checkpoint[:]))))
	for mode in 0..<14 {
		altered = checkpoint
		inputLength := size
		offset := 0
		switch mode {
		case 0: altered[0] ~= 0xff
		case 1: offset = 8; CheckpointPut64(altered[:], &offset, 99)
		case 2: offset = 16; CheckpointPut64(altered[:], &offset, max(u64))
		case 3: offset = 48; CheckpointPut64(altered[:], &offset, 0)
		case 4: offset = 64; CheckpointPut32(altered[:], &offset, math.nan_f32())
		case 5: offset = 80; CheckpointPut64(altered[:], &offset, 0)
		case 6: offset = 104; CheckpointPut64(altered[:], &offset, 2)
		case 7: offset = 112; CheckpointPut64(altered[:], &offset, max(u64))
		case 8: offset = 120; CheckpointPut32(altered[:], &offset, 0)
		case 9: offset = 144; CheckpointPut32(altered[:], &offset, math.nan_f32())
		case 10: altered[policyOffset] ~= 0xff
		case 11: altered[valueOffset] ~= 0xff
		case 12: altered[size] = 0x5a; inputLength += 1
		case 13: offset = 144+9*4; CheckpointPut32(altered[:], &offset, -1)
		}
		if mode == 3 || mode == 4 || mode == 7 || mode == 8 || mode == 9 || mode == 13 {
			p, v, ok := PPOCheckpointPeekModelPayloads(altered[:inputLength])
			_, pError := CheckpointInspect(p)
			_, vError := CheckpointInspect(v)
			testing.expect(t, ok && pError.code == .None && vError.code == .None)
		}
		if !PPOContextCheckpointExpectReadFailure(t, "malformed", &trainer, state.allocated[:4], state.sizes[:4], altered[:inputLength], .InvalidCheckpoint) { return }
	}
	// Both nested payloads inspect successfully, but a terminal softmax is not a PPO logits model.
	softmaxPolicy: Sequential(2, 3, 2)
	setup = SequentialInit(&softmaxPolicy, 2, 7) && SequentialAddDense(&softmaxPolicy, 2) && SequentialAddActivation(&softmaxPolicy, .Softmax)
	testing.expect(t, setup)
	if !setup { return }
	softmaxSize, softmaxOk := CheckpointWrite(&softmaxPolicy, nil, 17, policyScratch[:])
	altered = {}
	newSize := policyOffset+softmaxSize+len(valueInput)
	testing.expect(t, softmaxOk && newSize <= len(altered))
	if !softmaxOk || newSize > len(altered) { return }
	copy(altered[:policyOffset], checkpoint[:policyOffset])
	copy(altered[policyOffset:policyOffset+softmaxSize], policyScratch[:softmaxSize])
	copy(altered[policyOffset+softmaxSize:newSize], valueInput)
	sizeOffset := 16
	CheckpointPut64(altered[:], &sizeOffset, u64(softmaxSize))
	p, v, ok := PPOCheckpointPeekModelPayloads(altered[:newSize])
	_, pError := CheckpointInspect(p)
	_, vError := CheckpointInspect(v)
	testing.expect(t, ok && pError.code == .None && vError.code == .None)
	if !PPOContextCheckpointExpectReadFailure(t, "PPO-invalid nested model", &trainer, state.allocated[:4], state.sizes[:4], altered[:newSize], .InvalidCheckpoint) { return }
	// The public wrapper rejects a batch that exceeds the model capacities before commit.
	altered = checkpoint
	offset := 88
	CheckpointPut64(altered[:], &offset, 3)
	_ = PPOContextCheckpointExpectReadFailure(t, "incompatible encoded batch", &trainer, state.allocated[:4], state.sizes[:4], altered[:size], .CheckpointIncompatible)
}

@(test)
PPOTrainingContextCheckpointAdamStepBoundary :: proc(t: ^testing.T) {
	policy, value: Sequential(1, 2, 2)
	trainer: PPOTrainingContext(1, 2, 2, 1, 2, 2)
	setup := PPOContextTestSetup(&policy, &value)
	testing.expect(t, setup)
	if !setup { return }
	options := PPOTrainingContextOptionsDefault(1)
	options.fit = {epochs = 1, batchSize = 1}
	allocatorState := PPOContextTestAllocator{backing = context.allocator}
	allocator := mem.Allocator{procedure = PPOContextTestAllocatorProc, data = &allocatorState}
	result := PPOTrainingContextInit(&trainer, &policy, &value, options, allocator)
	testing.expect(t, result == .None)
	if result != .None { return }
	defer PPOTrainingContextDestroy(&trainer)
	checkpoint, output, policyScratch, valueScratch: [4096]u8
	size, err := PPOTrainingContextCheckpointWrite(&trainer, checkpoint[:], policyScratch[:], valueScratch[:])
	testing.expect(t, err == .None && size > 112+8)
	if err != .None || size <= 112+8 { return }
	offset := 32
	CheckpointPut64(checkpoint[:], &offset, max(u64)-1)
	offset = 112
	CheckpointPut64(checkpoint[:], &offset, max(u64)-1)
	result = PPOTrainingContextCheckpointRead(&trainer, checkpoint[:size])
	testing.expect(t, result == .None && PPOTrainingContextOptimizer(&trainer).step == max(u64)-1 &&
		PPOTrainingContextState(&trainer).updateCount == max(u64)-1)
	if result != .None { return }
	backing: PPOContextTestRolloutBacking
	buffer: rl.RolloutBuffer
	setup = PPOContextTestRolloutInit(&buffer, &backing) && PPOContextTestCollect(&policy, &value, PPOTrainingContextState(&trainer), &buffer, 1)
	testing.expect(t, setup)
	if !setup { return }
	stats, fitError := PPOTrainingContextFit(&trainer, &buffer)
	testing.expect(t, fitError == .None && stats.updates == 1 && PPOTrainingContextOptimizer(&trainer).step == max(u64) &&
		PPOTrainingContextState(&trainer).updateCount == max(u64))
	if fitError != .None { return }
	// Adam accepts its final step, but checkpointing rejects an exhausted optimizer.
	snapshot: PPOContextCheckpointSnapshot(1, 2, 2, 1, 2, 2)
	setup = PPOContextCheckpointSnapshotTake(&trainer, allocatorState.allocated[:4], allocatorState.sizes[:4], &snapshot)
	testing.expect(t, setup)
	if !setup { return }
	for &byte in output { byte = 0xa5 }
	before := output
	outputSize, writeError := PPOTrainingContextCheckpointWrite(&trainer, output[:], policyScratch[:], valueScratch[:])
	testing.expect(t, writeError == .CheckpointWriteFailed && outputSize == 0 && output == before &&
		PPOContextCheckpointSnapshotEqual(&trainer, allocatorState.allocated[:4], &snapshot))
}

// Each returned allocation has a private prefix so a complete valid checkpoint
// can overlap its first byte without overwriting unrelated memory.
PPOContextCheckpointGuardAllocator :: struct {
	backing: mem.Allocator,
	allocated, physical: [4]rawptr,
	sizes: [4]int,
	allocations, frees, badFrees: int,
}

PPOContextCheckpointGuardAllocatorProc :: proc(
	data: rawptr, mode: mem.Allocator_Mode, size, alignment: int,
	oldMemory: rawptr, oldSize: int, loc := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	state := (^PPOContextCheckpointGuardAllocator)(data)
	if mode == .Alloc {
		if state.allocations >= 4 || alignment > 4096 || size > max(int)-4096 { return nil, .Out_Of_Memory }
		memory, err := state.backing.procedure(state.backing.data, mode, size+4096, alignment, oldMemory, oldSize, loc)
		if raw_data(memory) == nil || err != nil { return memory, err }
		i := state.allocations
		state.physical[i] = rawptr(raw_data(memory))
		state.allocated[i] = rawptr(raw_data(memory[4096:]))
		state.sizes[i] = size
		state.allocations += 1
		return memory[4096:4096+size], nil
	}
	if mode == .Free {
		for pointer, i in state.allocated {
			if pointer == oldMemory && pointer != nil {
				memory, err := state.backing.procedure(state.backing.data, mode, size, alignment, state.physical[i], oldSize, loc)
				if err == nil { state.allocated[i] = nil; state.frees += 1 }
				return memory, err
			}
		}
		state.badFrees += 1
		return nil, .Invalid_Pointer
	}
	return state.backing.procedure(state.backing.data, mode, size, alignment, oldMemory, oldSize, loc)
}

PPOContextCheckpointModelBox :: struct {
	prefix: [4096]u8,
	model: Sequential(2, 3, 2),
}
PPOContextCheckpointTrainerBox :: struct {
	prefix: [4096]u8,
	trainer: PPOTrainingContext(2, 3, 2, 2, 3, 2),
}

@(test)
PPOTrainingContextCheckpointValidInputOverlaps :: proc(t: ^testing.T) {
	policyBox, valueBox: PPOContextCheckpointModelBox
	trainerBox: PPOContextCheckpointTrainerBox
	policy, value, trainer := &policyBox.model, &valueBox.model, &trainerBox.trainer
	setup := PPOContextCheckpointBuildModels(policy, value, 2, 2, 0)
	testing.expect(t, setup)
	if !setup { return }
	options := PPOTrainingContextOptionsDefault(5)
	options.fit = {epochs = 2, batchSize = 2}
	state := PPOContextCheckpointGuardAllocator{backing = context.allocator}
	allocator := mem.Allocator{procedure = PPOContextCheckpointGuardAllocatorProc, data = &state}
	result := PPOTrainingContextInit(trainer, policy, value, options, allocator)
	testing.expect(t, result == .None && state.allocations == 4)
	if result != .None { return }
	defer PPOTrainingContextDestroy(trainer)
	checkpoint, candidate, policyScratch, valueScratch: [4096]u8
	size, writeError := PPOTrainingContextCheckpointWrite(trainer, checkpoint[:], policyScratch[:], valueScratch[:])
	testing.expect(t, writeError == .None && size >= 4 && size <= 4096)
	if writeError != .None || size < 4 || size > 4096 { return }
	targets := [7]rawptr{rawptr(trainer), state.allocated[0], rawptr(policy), rawptr(value),
		state.allocated[1], state.allocated[2], state.allocated[3]}
	for target, index in targets {
		candidate = checkpoint
		// The last nested-model float is kept finite and its last byte matches
		// the destination byte, so preparing this overlap changes no live data.
		candidate[size-4], candidate[size-3], candidate[size-2] = 0, 0, 0
		candidate[size-1] = (^u8)(target)^
		input := mem.slice_ptr((^u8)(rawptr(uintptr(target)-uintptr(size-1))), size)
		copy(input, candidate[:size])
		p, v, ok := PPOCheckpointPeekModelPayloads(input)
		_, pError := CheckpointInspect(p)
		_, vError := CheckpointInspect(v)
		testing.expectf(t, ok && pError.code == .None && vError.code == .None, "overlap %d has valid nested models", index)
		if !ok || pError.code != .None || vError.code != .None { return }
		probePolicy, probeValue: Sequential(2, 3, 2)
		probeAdam: Adam
		probeParameters: [4]^core.Node
		probeFirst, probeSecond: [9]f32
		_, _, _, _, readable := PPOCheckpointRead(&probePolicy, &probeValue, input, &probeAdam, probeParameters[:], probeFirst[:], probeSecond[:])
		testing.expectf(t, readable, "overlap %d is otherwise readable", index)
		if !readable { return }
		if !PPOContextCheckpointExpectReadFailure(t, "valid overlapping input", trainer, state.allocated[:], state.sizes[:], input, .InvalidCheckpoint) { return }
	}
	testing.expect(t, PPOTrainingContextDestroy(trainer) == .None && state.frees == 4 && state.badFrees == 0)
}

@(test)
PPOTrainingContextCheckpointWriteFailuresBeforeCommit :: proc(t: ^testing.T) {
	policy, value: Sequential(2, 3, 2)
	trainer: PPOTrainingContext(2, 3, 2, 2, 3, 2)
	setup := PPOContextCheckpointBuildModels(&policy, &value, 2, 2, 0)
	testing.expect(t, setup)
	if !setup { return }
	options := PPOTrainingContextOptionsDefault(5)
	options.fit = {epochs = 2, batchSize = 2}
	state := PPOContextTestAllocator{backing = context.allocator}
	allocator := mem.Allocator{procedure = PPOContextTestAllocatorProc, data = &state}
	result := PPOTrainingContextInit(&trainer, &policy, &value, options, allocator)
	testing.expect(t, result == .None)
	if result != .None { return }
	defer PPOTrainingContextDestroy(&trainer)
	snapshot: PPOContextCheckpointSnapshot(2, 3, 2, 2, 3, 2)
	setup = PPOContextCheckpointSnapshotTake(&trainer, state.allocated[:4], state.sizes[:4], &snapshot)
	testing.expect(t, setup)
	if !setup { return }
	for mode in 0..<12 {
		output, policyScratch, valueScratch: [4096]u8
		for &byte in output { byte = 0xa5 }
		outputBefore := output
		out, pScratch, vScratch := output[:], policyScratch[:], valueScratch[:]
		switch mode {
		case 0: out = output[:1]
		case 1: pScratch = policyScratch[:1]
		case 2: vScratch = valueScratch[:1]
		case 3: pScratch = output[:]
		case 4: vScratch = policyScratch[:]
		case 5: out = mem.slice_ptr((^u8)(rawptr(&trainer.state)), size_of(trainer.state))
		case 6: pScratch = mem.slice_ptr((^u8)(state.allocated[0]), state.sizes[0])
		case 7: vScratch = mem.slice_ptr((^u8)(rawptr(&policy)), size_of(policy))
		case 8: out = mem.slice_ptr((^u8)(state.allocated[2]), state.sizes[2])
		case 9: pScratch = mem.slice_ptr((^u8)(state.allocated[3]), state.sizes[3])
		case 10: pScratch = output[1:]
		case 11: vScratch = mem.slice_ptr((^u8)(rawptr(&value)), size_of(value))
		}
		written, writeError := PPOTrainingContextCheckpointWrite(&trainer, out, pScratch, vScratch)
		testing.expectf(t, written == 0 && writeError == .CheckpointWriteFailed && output == outputBefore &&
			PPOContextCheckpointSnapshotEqual(&trainer, state.allocated[:4], &snapshot), "write failure %d", mode)
	}
	for mode in 0..<2 {
		originalRandomState := trainer.state.policyRandomState
		adam := PPOTrainingContextOptimizer(&trainer)
		originalMoment := adam.secondMoment[0]
		if mode == 0 { trainer.state.policyRandomState = 0 } else { adam.secondMoment[0] = -1 }
		setup = PPOContextCheckpointSnapshotTake(&trainer, state.allocated[:4], state.sizes[:4], &snapshot)
		testing.expect(t, setup)
		if !setup { return }
		output, pScratch, vScratch: [4096]u8
		for &byte in output { byte = 0xa5 }
		before := output
		written, writeError := PPOTrainingContextCheckpointWrite(&trainer, output[:], pScratch[:], vScratch[:])
		testing.expect(t, written == 0 && writeError == .CheckpointWriteFailed && output == before &&
			PPOContextCheckpointSnapshotEqual(&trainer, state.allocated[:4], &snapshot))
		trainer.state.policyRandomState, adam.secondMoment[0] = originalRandomState, originalMoment
	}
	nilTrainer := (^PPOTrainingContext(2, 3, 2, 2, 3, 2))(nil)
	output, pScratch, vScratch: [4096]u8
	written, writeError := PPOTrainingContextCheckpointWrite(nilTrainer, output[:], pScratch[:], vScratch[:])
	testing.expect(t, written == 0 && writeError == .InvalidHandle && PPOTrainingContextCheckpointRead(nilTrainer, nil) == .InvalidHandle)
	copied := trainer
	written, writeError = PPOTrainingContextCheckpointWrite(&copied, output[:], pScratch[:], vScratch[:])
	testing.expect(t, written == 0 && writeError == .InvalidHandle && PPOTrainingContextCheckpointRead(&copied, nil) == .InvalidHandle)
	state.failFreeAt = 1
	testing.expect(t, PPOTrainingContextDestroy(&trainer) == .CleanupFailed)
	written, writeError = PPOTrainingContextCheckpointWrite(&trainer, output[:], pScratch[:], vScratch[:])
	testing.expect(t, written == 0 && writeError == .InvalidHandle && PPOTrainingContextCheckpointRead(&trainer, nil) == .InvalidHandle)
	testing.expect(t, PPOTrainingContextDestroy(&trainer) == .None && state.frees == 4 && state.badFrees == 0)
}
