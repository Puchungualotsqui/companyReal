package nn

import "../core"
import "../rl"
import "core:math"
import "core:mem"
import "core:testing"

// A failed free leaves the block live, as required for a destruction retry.
PPOContextTestAllocator :: struct {
	backing: mem.Allocator,
	attempts, allocations, freeCalls, frees, badFrees: int,
	failAt, pointerAndErrorAt, failFreeAt: int,
	failWithNil: bool,
	allocated: [32]rawptr,
	sizes: [32]int,
	live: [32]bool,
	freeOrder: [64]rawptr,
}

PPOContextTestAllocatorProc :: proc(
	data: rawptr, mode: mem.Allocator_Mode, size, alignment: int,
	oldMemory: rawptr, oldSize: int, loc := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	state := (^PPOContextTestAllocator)(data)
	if mode == .Alloc {
		state.attempts += 1
		if state.attempts == state.failAt {
			if state.failWithNil { return nil, nil }
			return nil, .Out_Of_Memory
		}
		memory, err := state.backing.procedure(state.backing.data, mode, size, alignment, oldMemory, oldSize, loc)
		if raw_data(memory) != nil {
			index := state.allocations
			if index >= len(state.allocated) { return memory, err }
			state.allocated[index], state.sizes[index], state.live[index] = rawptr(raw_data(memory)), size, true
			state.allocations += 1
			if state.attempts == state.pointerAndErrorAt { return memory, .Out_Of_Memory }
		}
		return memory, err
	}
	if mode == .Free {
		state.freeCalls += 1
		if state.freeCalls <= len(state.freeOrder) { state.freeOrder[state.freeCalls-1] = oldMemory }
		index := -1
		for pointer, i in state.allocated[:state.allocations] {
			if pointer == oldMemory && state.live[i] { index = i; break }
		}
		if index < 0 { state.badFrees += 1; return nil, .Invalid_Pointer }
		if state.freeCalls == state.failFreeAt { return nil, .Invalid_Argument }
		memory, err := state.backing.procedure(state.backing.data, mode, size, alignment, oldMemory, oldSize, loc)
		if err == nil { state.live[index] = false; state.frees += 1 }
		return memory, err
	}
	return state.backing.procedure(state.backing.data, mode, size, alignment, oldMemory, oldSize, loc)
}

PPOContextTestBytesEqual :: proc(address: rawptr, expected: []u8) -> bool {
	actual := mem.slice_ptr((^u8)(address), len(expected))
	for byte, index in expected { if byte != actual[index] { return false } }
	return true
}

PPOContextTestSetup :: proc(
	policy: ^Sequential($pl, $pw, $pb), value: ^Sequential($vl, $vw, $vb), inputWidth: int = 2,
) -> bool {
	return SequentialInit(policy, inputWidth, 17) && SequentialAddDense(policy, 2) &&
		SequentialInit(value, inputWidth, 29) && SequentialAddDense(value, 1)
}

PPOContextTestModelsEqual :: proc(a, b: ^Sequential($layers, $width, $batch)) -> bool {
	aNodes, bNodes: [2*layers]^core.Node
	aParams, aOk := SequentialParameters(a, aNodes[:])
	bParams, bOk := SequentialParameters(b, bNodes[:])
	if !aOk || !bOk || len(aParams) != len(bParams) { return false }
	for parameter, index in aParams {
		other := bParams[index]
		if len(parameter.value.data) != len(other.value.data) { return false }
		for item, element in parameter.value.data { if item != other.value.data[element] { return false } }
	}
	return true
}

PPOContextTestRolloutBacking :: struct {
	observations: [14]f32,
	actions: [7]int,
	rewards, values, nextValues, advantages, returns: [7]f32,
	logs: [7]f64,
	legal: [14]bool,
	terminated, truncated: [7]bool,
}

PPOContextTestRolloutInit :: proc(buffer: ^rl.RolloutBuffer, backing: ^PPOContextTestRolloutBacking) -> bool {
	return rl.RolloutBufferInit(buffer, {
		observations = backing.observations[:], actions = backing.actions[:], rewards = backing.rewards[:],
		values = backing.values[:], nextValues = backing.nextValues[:], oldLogProbabilities = backing.logs[:],
		legalActions = backing.legal[:], terminated = backing.terminated[:], truncated = backing.truncated[:],
		advantages = backing.advantages[:], returns = backing.returns[:],
	}, 7, 2, 2)
}

PPOContextTestCollect :: proc(
	policy: ^Sequential($pl, $pw, $pb), value: ^Sequential($vl, $vw, $vb),
	state: ^PPOTrainingState, buffer: ^rl.RolloutBuffer, count: int,
) -> bool {
	if !rl.RolloutBufferReset(buffer) { return false }
	for index in 0..<count {
		observation := [2]f32{f32(index)/4, 1}
		legal := [2]bool{true, index%3 != 1}
		action, logProbability, actionOk := SequentialPolicyAction(policy, observation[:], legal[:], .Stochastic, &state.policyRandomState)
		currentValue, valueOk := SequentialPredictScalar(value, observation[:])
		nextObservation := [2]f32{f32(index+1)/4, 1}
		nextValue, nextOk := SequentialPredictScalar(value, nextObservation[:])
		if !actionOk || !valueOk || !nextOk || !rl.RolloutBufferAppend(buffer, {
			observation = observation[:], action = action, reward = f32(index%2)+f32(action)/4,
			value = currentValue, nextValue = nextValue, oldLogProbability = logProbability,
			legalActions = legal[:], terminated = index == count-1,
		}) { return false }
	}
	return rl.RolloutComputeGAE(buffer, 0.9, 0.95) && rl.RolloutNormalizeAdvantages(buffer)
}

@(test)
PPOTrainingContextDefaultsAndOptions :: proc(t: ^testing.T) {
	options := PPOTrainingContextOptionsDefault(2)
	testing.expect(t, options.rolloutCapacity == 2 && options.objective == PPOConfig{0.2, 0.01, 0.5, 1})
	testing.expect(t, options.fit == PPOFitConfig{epochs = 4, batchSize = 0, maxGradientNorm = 0.5})
	testing.expect(t, options.policySeed == 1 && options.shuffleSeed == 2 && options.learningRate == 0.001 &&
		options.beta1 == 0.9 && options.beta2 == 0.999 && options.epsilon == 1e-8)
	policy: Sequential(1, 2, 4)
	value: Sequential(1, 2, 3)
	trainer: PPOTrainingContext(1, 2, 4, 1, 2, 3)
	setup := PPOContextTestSetup(&policy, &value)
	testing.expect(t, setup)
	if !setup { return }
	policyBytes: [size_of(policy)]u8
	valueBytes: [size_of(value)]u8
	copy(policyBytes[:], mem.slice_ptr((^u8)(rawptr(&policy)), len(policyBytes)))
	copy(valueBytes[:], mem.slice_ptr((^u8)(rawptr(&value)), len(valueBytes)))
	options.shuffleSeed = 0
	result := PPOTrainingContextInit(&trainer, &policy, &value, options)
	testing.expect(t, result == .None)
	if result != .None { return }
	defer PPOTrainingContextDestroy(&trainer)
	testing.expect(t, PPOContextTestBytesEqual(rawptr(&policy), policyBytes[:]) && PPOContextTestBytesEqual(rawptr(&value), valueBytes[:]))
	testing.expect(t, trainer.policy == &policy && trainer.value == &value && trainer.rolloutCapacity == 2 &&
		trainer.observationWidth == 2 && trainer.actionCount == 2 && trainer.objective == options.objective && trainer.fitConfig == options.fit)
	state, adam := PPOTrainingContextState(&trainer), PPOTrainingContextOptimizer(&trainer)
	storage, storageOk := PPOOwnedFitStorageView(&trainer.scratch)
	metrics := PPOTrainingContextEpochMetrics(&trainer)
	testing.expect(t, state != nil && state^ == PPOTrainingState{policyRandomState = 1, shuffleRandomState = 0})
	testing.expect(t, adam != nil && adam.step == 0 && adam.learningRate == options.learningRate &&
		adam.beta1 == options.beta1 && adam.beta2 == options.beta2 && adam.epsilon == options.epsilon)
	testing.expect(t, storageOk && len(storage.indices) == 2 && len(storage.actions) == 2 &&
		len(storage.observations) == 4 && len(storage.legalActions) == 4 && len(metrics) == 4 &&
		raw_data(metrics) == raw_data(storage.epochMetrics))
	if adam == nil { return }
	testing.expect(t, len(adam.parameters) == 4 && len(adam.firstMoment) == 9 && len(adam.secondMoment) == 9)
	if len(adam.parameters) == 4 {
		policyDense := &policy.layers[0].storage.(DenseStorage(2))
		valueDense := &value.layers[0].storage.(DenseStorage(2))
		testing.expect(t, adam.parameters[0] == &policyDense.weights && adam.parameters[1] == &policyDense.bias &&
			adam.parameters[2] == &valueDense.weights && adam.parameters[3] == &valueDense.bias)
	}
	for moment, index in adam.firstMoment { testing.expect(t, moment == 0 && adam.secondMoment[index] == 0) }
}

@(test)
PPOTrainingContextSmallRolloutUsesBoundedScratch :: proc(t: ^testing.T) {
	for configuredBatch in ([2]int{0, 3}) {
		policy: Sequential(1, 2, 4)
		value: Sequential(1, 2, 3)
		trainer: PPOTrainingContext(1, 2, 4, 1, 2, 3)
		setup := PPOContextTestSetup(&policy, &value)
		testing.expect(t, setup)
		if !setup { return }
		options := PPOTrainingContextOptionsDefault(2)
		options.fit.batchSize, options.fit.epochs = configuredBatch, 2
		allocatorState := PPOContextTestAllocator{backing = context.allocator}
		allocator := mem.Allocator{procedure = PPOContextTestAllocatorProc, data = &allocatorState}
		result := PPOTrainingContextInit(&trainer, &policy, &value, options, allocator)
		testing.expect(t, result == .None)
		if result != .None { return }
		defer PPOTrainingContextDestroy(&trainer)
		storage, storageOk := PPOOwnedFitStorageView(&trainer.scratch)
		testing.expect(t, storageOk && len(storage.indices) == 2 && len(storage.actions) == 2 &&
			len(storage.observations) == 4 && len(storage.epochMetrics) == 2)
		backing: PPOContextTestRolloutBacking
		buffer: rl.RolloutBuffer
		state := PPOTrainingContextState(&trainer)
		setup = state != nil && PPOContextTestRolloutInit(&buffer, &backing) &&
			PPOContextTestCollect(&policy, &value, state, &buffer, 2)
		testing.expect(t, setup)
		if !setup { return }
		stats, fitError := PPOTrainingContextFit(&trainer, &buffer)
		testing.expect(t, fitError == .None && stats.epochs == 2 && stats.updates == 2 && state.updateCount == 2 &&
			state.rolloutCount == 0 && PPOTrainingContextOptimizer(&trainer).learningRate == options.learningRate &&
			allocatorState.allocations == 4 && allocatorState.freeCalls == 0)
		for metric in PPOTrainingContextEpochMetrics(&trainer) { testing.expect(t, metric.updates == 1) }
		testing.expect(t, PPOTrainingContextDestroy(&trainer) == .None && allocatorState.frees == 4)
	}
}

@(test)
PPOTrainingContextInvalidOptions :: proc(t: ^testing.T) {
	policy, value: Sequential(1, 2, 2)
	trainer: PPOTrainingContext(1, 2, 2, 1, 2, 2)
	setup := PPOContextTestSetup(&policy, &value)
	testing.expect(t, setup)
	if !setup { return }
	allocatorState := PPOContextTestAllocator{backing = context.allocator}
	allocator := mem.Allocator{procedure = PPOContextTestAllocatorProc, data = &allocatorState}
	defaults := PPOTrainingContextOptionsDefault(5)
	bad: [24]PPOTrainingContextOptions
	for &option in bad { option = defaults }
	bad[0].rolloutCapacity = 0
	bad[1].rolloutCapacity = -1
	bad[2].policySeed = 0
	bad[3].objective.clipRange = 1
	bad[4].objective.clipRange = -0.1
	bad[5].objective.clipRange = math.nan_f32()
	bad[6].objective.entropyCoefficient = -1
	bad[7].objective.valueCoefficient = math.inf_f32(1)
	bad[8].objective.valueHuberDelta = 0
	bad[9].fit.epochs = 0
	bad[10].fit.batchSize = -1
	bad[11].fit.batchSize = 3
	bad[12].fit.maxGradientNorm = -1
	bad[13].fit.maxGradientNorm = math.nan_f32()
	bad[14].fit.finalLearningRate = -1
	bad[15].fit.finalLearningRate = math.inf_f32(1)
	bad[16].learningRate = 0
	bad[17].learningRate = math.nan_f32()
	bad[18].beta1 = 1
	bad[19].beta1 = -0.1
	bad[20].beta2 = 1
	bad[21].beta2 = math.nan_f32()
	bad[22].epsilon = 0
	bad[23].epsilon = math.inf_f32(1)
	trainerBytes: [size_of(trainer)]u8
	policyBytes, valueBytes: [size_of(policy)]u8
	copy(trainerBytes[:], mem.slice_ptr((^u8)(rawptr(&trainer)), len(trainerBytes)))
	copy(policyBytes[:], mem.slice_ptr((^u8)(rawptr(&policy)), len(policyBytes)))
	copy(valueBytes[:], mem.slice_ptr((^u8)(rawptr(&value)), len(valueBytes)))
	for option in bad { testing.expect(t, PPOTrainingContextInit(&trainer, &policy, &value, option, allocator) == .InvalidOptions) }
	testing.expect(t, allocatorState.attempts == 0 && PPOContextTestBytesEqual(rawptr(&trainer), trainerBytes[:]) &&
		PPOContextTestBytesEqual(rawptr(&policy), policyBytes[:]) && PPOContextTestBytesEqual(rawptr(&value), valueBytes[:]))
	// A huge but otherwise valid capacity reaches scratch setup, rather than allocation.
	defaults.rolloutCapacity = max(int)
	testing.expect(t, PPOTrainingContextInit(&trainer, &policy, &value, defaults, allocator) == .ScratchSetupFailed)
	testing.expect(t, allocatorState.attempts == 0 && PPOTrainingContextDestroy(&trainer) == .None)
}

@(test)
PPOTrainingContextInvalidModelsAndAliases :: proc(t: ^testing.T) {
	policy, value: Sequential(1, 2, 2)
	trainer: PPOTrainingContext(1, 2, 2, 1, 2, 2)
	setup := PPOContextTestSetup(&policy, &value)
	testing.expect(t, setup)
	if !setup { return }
	options := PPOTrainingContextOptionsDefault(5)
	allocatorState := PPOContextTestAllocator{backing = context.allocator}
	allocator := mem.Allocator{procedure = PPOContextTestAllocatorProc, data = &allocatorState}
	testing.expect(t, PPOTrainingContextInit(&trainer, (^Sequential(1, 2, 2))(nil), &value, options, allocator) == .InvalidModel)
	testing.expect(t, PPOTrainingContextInit(&trainer, &policy, (^Sequential(1, 2, 2))(nil), options, allocator) == .InvalidModel)
	uninitialized: Sequential(1, 2, 2)
	testing.expect(t, PPOTrainingContextInit(&trainer, &uninitialized, &value, options, allocator) == .InvalidModel)
	testing.expect(t, PPOTrainingContextInit(&trainer, &policy, &uninitialized, options, allocator) == .InvalidModel)
	copiedPolicy, copiedValue := policy, value
	testing.expect(t, PPOTrainingContextInit(&trainer, &copiedPolicy, &value, options, allocator) == .InvalidModel)
	testing.expect(t, PPOTrainingContextInit(&trainer, &policy, &copiedValue, options, allocator) == .InvalidModel)
	mismatch, wrongValue, parameterFree: Sequential(1, 2, 2)
	setup = SequentialInit(&mismatch, 1) && SequentialAddDense(&mismatch, 1) &&
		SequentialInit(&wrongValue, 2) && SequentialAddDense(&wrongValue, 2) &&
		SequentialInit(&parameterFree, 2) && SequentialAddActivation(&parameterFree, .Tanh)
	testing.expect(t, setup)
	if !setup { return }
	testing.expect(t, PPOTrainingContextInit(&trainer, &policy, &mismatch, options, allocator) == .InvalidModel)
	testing.expect(t, PPOTrainingContextInit(&trainer, &policy, &wrongValue, options, allocator) == .InvalidModel)
	testing.expect(t, PPOTrainingContextInit(&trainer, &parameterFree, &value, options, allocator) == .InvalidModel)
	oneInputPolicy, parameterFreeValue: Sequential(1, 2, 2)
	setup = SequentialInit(&oneInputPolicy, 1) && SequentialAddDense(&oneInputPolicy, 2) &&
		SequentialInit(&parameterFreeValue, 1) && SequentialAddActivation(&parameterFreeValue, .Tanh)
	testing.expect(t, setup)
	if !setup { return }
	testing.expect(t, PPOTrainingContextInit(&trainer, &oneInputPolicy, &parameterFreeValue, options, allocator) == .InvalidModel)
	softmax: Sequential(2, 2, 2)
	setup = SequentialInit(&softmax, 2) && SequentialAddDense(&softmax, 2) && SequentialAddActivation(&softmax, .Softmax)
	testing.expect(t, setup)
	if !setup { return }
	softmaxTrainer: PPOTrainingContext(2, 2, 2, 1, 2, 2)
	testing.expect(t, PPOTrainingContextInit(&softmaxTrainer, &softmax, &value, options, allocator) == .InvalidModel)
	testing.expect(t, PPOTrainingContextInit(&trainer, &policy, &policy, options, allocator) == .InvalidModel)
	partial := (^Sequential(1, 2, 2))(rawptr(uintptr(rawptr(&policy))+uintptr(align_of(Sequential(1, 2, 2)))))
	testing.expect(t, PPOTrainingContextInit(&trainer, &policy, partial, options, allocator) == .InvalidModel)
	contextAlias := (^Sequential(1, 2, 2))(rawptr(&trainer))
	partialContext := (^Sequential(1, 2, 2))(rawptr(uintptr(rawptr(&trainer))+uintptr(align_of(Sequential(1, 2, 2)))))
	testing.expect(t, PPOTrainingContextInit(&trainer, contextAlias, &value, options, allocator) == .InvalidModel)
	testing.expect(t, PPOTrainingContextInit(&trainer, &policy, contextAlias, options, allocator) == .InvalidModel)
	testing.expect(t, PPOTrainingContextInit(&trainer, partialContext, &value, options, allocator) == .InvalidModel)

	policyDense := &policy.layers[0].storage.(DenseStorage(2))
	weights := &policyDense.weights
	originalValue, originalGrad := weights.value.data, weights.grad.data
	weights.value.data = mem.slice_ptr((^f32)(rawptr(&trainer.state)), len(originalValue))
	testing.expect(t, PPOTrainingContextInit(&trainer, &policy, &value, options, allocator) == .InvalidModel)
	weights.value.data = originalValue
	weights.grad.data = mem.slice_ptr((^f32)(rawptr(&trainer.objective)), len(originalGrad))
	testing.expect(t, PPOTrainingContextInit(&trainer, &policy, &value, options, allocator) == .InvalidModel)
	weights.grad.data = originalGrad
	inputValue := policy.input.value.data
	policy.input.value.data = mem.slice_ptr((^f32)(rawptr(&trainer.state)), len(inputValue))
	testing.expect(t, PPOTrainingContextInit(&trainer, &policy, &value, options, allocator) == .InvalidModel)
	policy.input.value.data = inputValue
	shared: [8]f32
	valueDense := &value.layers[0].storage.(DenseStorage(2))
	valueWeights := &valueDense.weights
	originalValueWeights := valueWeights.value.data
	weights.value.data, valueWeights.value.data = shared[:4], shared[1:3]
	testing.expect(t, PPOTrainingContextInit(&trainer, &policy, &value, options, allocator) == .InvalidModel)
	weights.value.data, valueWeights.value.data = originalValue, originalValueWeights
	testing.expect(t, allocatorState.attempts == 0 && PPOTrainingContextState(&trainer) == nil && PPOTrainingContextDestroy(&trainer) == .None)
}

@(test)
PPOTrainingContextOwnerGuardsAndRecord :: proc(t: ^testing.T) {
	policy, value: Sequential(1, 2, 2)
	trainer: PPOTrainingContext(1, 2, 2, 1, 2, 2)
	setup := PPOContextTestSetup(&policy, &value)
	testing.expect(t, setup)
	if !setup { return }
	nilTrainer := (^PPOTrainingContext(1, 2, 2, 1, 2, 2))(nil)
	options := PPOTrainingContextOptionsDefault(5)
	testing.expect(t, PPOTrainingContextInit(nilTrainer, &policy, &value, options) == .InvalidHandle)
	testing.expect(t, PPOTrainingContextState(nilTrainer) == nil && PPOTrainingContextOptimizer(nilTrainer) == nil &&
		len(PPOTrainingContextEpochMetrics(nilTrainer)) == 0 && PPOTrainingContextRecordRollout(nilTrainer) == .InvalidHandle &&
		PPOTrainingContextDestroy(nilTrainer) == .InvalidHandle)
	_, nilFit := PPOTrainingContextFit(nilTrainer, nil)
	testing.expect(t, nilFit == .InvalidHandle)
	testing.expect(t, PPOTrainingContextState(&trainer) == nil && PPOTrainingContextOptimizer(&trainer) == nil &&
		len(PPOTrainingContextEpochMetrics(&trainer)) == 0 && PPOTrainingContextRecordRollout(&trainer) == .InvalidHandle &&
		PPOTrainingContextDestroy(&trainer) == .None)
	_, emptyFit := PPOTrainingContextFit(&trainer, nil)
	testing.expect(t, emptyFit == .InvalidHandle)
	trainer.phase = .Ready
	testing.expect(t, PPOTrainingContextInit(&trainer, &policy, &value, options) == .InvalidHandle &&
		PPOTrainingContextState(&trainer) == nil && PPOTrainingContextDestroy(&trainer) == .InvalidHandle)
	trainer.phase = .Empty
	trainer.adam.self = rawptr(&trainer.adam)
	testing.expect(t, PPOTrainingContextInit(&trainer, &policy, &value, options) == .InvalidHandle)
	trainer.adam = {}
	trainer.scratch.self = rawptr(&trainer.scratch)
	testing.expect(t, PPOTrainingContextInit(&trainer, &policy, &value, options) == .InvalidHandle)
	trainer.scratch = {}
	trainer.scratch.memory = rawptr(&trainer.state)
	testing.expect(t, PPOTrainingContextInit(&trainer, &policy, &value, options) == .InvalidHandle)
	trainer.scratch = {}
	allocatorState := PPOContextTestAllocator{backing = context.allocator}
	allocator := mem.Allocator{procedure = PPOContextTestAllocatorProc, data = &allocatorState}
	result := PPOTrainingContextInit(&trainer, &policy, &value, options, allocator)
	testing.expect(t, result == .None)
	if result != .None { return }
	defer PPOTrainingContextDestroy(&trainer)
	copied := trainer
	moved := trainer
	ownerBytes, copyBytes, movedBytes: [size_of(trainer)]u8
	copy(ownerBytes[:], mem.slice_ptr((^u8)(rawptr(&trainer)), len(ownerBytes)))
	copy(copyBytes[:], mem.slice_ptr((^u8)(rawptr(&copied)), len(copyBytes)))
	copy(movedBytes[:], mem.slice_ptr((^u8)(rawptr(&moved)), len(movedBytes)))
	for invalid in ([2]^PPOTrainingContext(1, 2, 2, 1, 2, 2){&copied, &moved}) {
		testing.expect(t, PPOTrainingContextState(invalid) == nil && PPOTrainingContextOptimizer(invalid) == nil &&
			len(PPOTrainingContextEpochMetrics(invalid)) == 0 && PPOTrainingContextRecordRollout(invalid) == .InvalidHandle &&
			PPOTrainingContextInit(invalid, &policy, &value, options, allocator) == .InvalidHandle &&
			PPOTrainingContextDestroy(invalid) == .InvalidHandle)
		_, fitError := PPOTrainingContextFit(invalid, nil)
		testing.expect(t, fitError == .InvalidHandle)
	}
	testing.expect(t, PPOTrainingContextInit(&trainer, &policy, &value, options, allocator) == .InvalidHandle &&
		allocatorState.allocations == 4 && allocatorState.freeCalls == 0 &&
		PPOContextTestBytesEqual(rawptr(&trainer), ownerBytes[:]) && PPOContextTestBytesEqual(rawptr(&copied), copyBytes[:]) &&
		PPOContextTestBytesEqual(rawptr(&moved), movedBytes[:]))
	state := PPOTrainingContextState(&trainer)
	testing.expect(t, state != nil && PPOTrainingContextRecordRollout(&trainer) == .None && state.rolloutCount == 1)
	if state == nil { return }
	state.policyRandomState = 0
	before := state^
	testing.expect(t, PPOTrainingContextRecordRollout(&trainer) == .InvalidState && state^ == before)
	state.policyRandomState, state.rolloutCount = options.policySeed, max(u64)
	before = state^
	testing.expect(t, PPOTrainingContextRecordRollout(&trainer) == .InvalidState && state^ == before)
	state.rolloutCount = 1
	testing.expect(t, PPOTrainingContextDestroy(&trainer) == .None && PPOTrainingContextDestroy(&trainer) == .None &&
		allocatorState.frees == 4 && PPOTrainingContextState(&trainer) == nil && PPOTrainingContextOptimizer(&trainer) == nil)
	testing.expect(t, PPOTrainingContextDestroy(&copied) == .InvalidHandle && PPOTrainingContextDestroy(&moved) == .InvalidHandle)
	result = PPOTrainingContextInit(&trainer, &policy, &value, options, allocator)
	testing.expect(t, result == .None)
	if result == .None {
		freshState, freshAdam := PPOTrainingContextState(&trainer), PPOTrainingContextOptimizer(&trainer)
		testing.expect(t, freshState != nil && freshState.rolloutCount == 0 && freshState.updateCount == 0 &&
			freshState.policyRandomState == options.policySeed && freshAdam != nil && freshAdam.step == 0)
	}
}

@(test)
PPOTrainingContextAllocationFailuresAndRetry :: proc(t: ^testing.T) {
	policy, value: Sequential(1, 2, 2)
	setup := PPOContextTestSetup(&policy, &value)
	testing.expect(t, setup)
	if !setup { return }
	options := PPOTrainingContextOptionsDefault(5)
	policyBytes, valueBytes: [size_of(policy)]u8
	copy(policyBytes[:], mem.slice_ptr((^u8)(rawptr(&policy)), len(policyBytes)))
	copy(valueBytes[:], mem.slice_ptr((^u8)(rawptr(&value)), len(valueBytes)))
	for failAt in 1..=4 {
		for mode in 0..<3 {
			trainer: PPOTrainingContext(1, 2, 2, 1, 2, 2)
			trainerBytes: [size_of(trainer)]u8
			copy(trainerBytes[:], mem.slice_ptr((^u8)(rawptr(&trainer)), len(trainerBytes)))
			state := PPOContextTestAllocator{backing = context.allocator}
			if mode == 2 { state.pointerAndErrorAt = failAt } else { state.failAt = failAt; state.failWithNil = mode == 1 }
			allocator := mem.Allocator{procedure = PPOContextTestAllocatorProc, data = &state}
			result := PPOTrainingContextInit(&trainer, &policy, &value, options, allocator)
			expected := PPOTrainingContextError.OptimizerSetupFailed
			if failAt == 1 { expected = .ScratchSetupFailed }
			expectedAllocations := failAt-1
			if mode == 2 { expectedAllocations += 1 }
			testing.expect(t, result == expected && state.attempts == failAt && state.allocations == expectedAllocations &&
				state.frees == expectedAllocations && state.badFrees == 0 && PPOTrainingContextState(&trainer) == nil &&
				PPOContextTestBytesEqual(rawptr(&trainer), trainerBytes[:]))
			testing.expect(t, PPOContextTestBytesEqual(rawptr(&policy), policyBytes[:]) && PPOContextTestBytesEqual(rawptr(&value), valueBytes[:]))
			testing.expect(t, PPOTrainingContextDestroy(&trainer) == .None)
			state.failAt, state.pointerAndErrorAt = 0, 0
			result = PPOTrainingContextInit(&trainer, &policy, &value, options, allocator)
			testing.expect(t, result == .None)
			if result == .None { testing.expect(t, PPOTrainingContextDestroy(&trainer) == .None) }
			testing.expect(t, state.frees == state.allocations && state.badFrees == 0)
		}
	}
}

@(test)
PPOTrainingContextInitCleanupFailureRetry :: proc(t: ^testing.T) {
	policy, value: Sequential(1, 2, 2)
	setup := PPOContextTestSetup(&policy, &value)
	testing.expect(t, setup)
	if !setup { return }
	options := PPOTrainingContextOptionsDefault(5)
	for failAt in 2..=4 {
		trainer: PPOTrainingContext(1, 2, 2, 1, 2, 2)
		state := PPOContextTestAllocator{backing = context.allocator, failAt = failAt, failFreeAt = failAt-1}
		allocator := mem.Allocator{procedure = PPOContextTestAllocatorProc, data = &state}
		result := PPOTrainingContextInit(&trainer, &policy, &value, options, allocator)
		testing.expect(t, result == .CleanupFailed && state.allocations == failAt-1 && state.frees == failAt-2 &&
			state.freeOrder[state.freeCalls-1] == state.allocated[0] && state.live[0])
		testing.expect(t, PPOTrainingContextState(&trainer) == nil && PPOTrainingContextOptimizer(&trainer) == nil &&
			len(PPOTrainingContextEpochMetrics(&trainer)) == 0 && PPOTrainingContextRecordRollout(&trainer) == .InvalidHandle &&
			PPOTrainingContextInit(&trainer, &policy, &value, options, allocator) == .InvalidHandle)
		_, fitError := PPOTrainingContextFit(&trainer, nil)
		testing.expect(t, fitError == .InvalidHandle)
		testing.expect(t, PPOTrainingContextDestroy(&trainer) == .None && state.frees == state.allocations &&
			state.freeOrder[state.freeCalls-1] == state.allocated[0] && state.badFrees == 0)
		state.failAt = 0
		result = PPOTrainingContextInit(&trainer, &policy, &value, options, allocator)
		testing.expect(t, result == .None)
		if result == .None { testing.expect(t, PPOTrainingContextDestroy(&trainer) == .None) }
		testing.expect(t, state.frees == state.allocations && state.badFrees == 0)
	}
}

@(test)
PPOTrainingContextUnderlyingRollbackFailure :: proc(t: ^testing.T) {
	policy, value: Sequential(1, 2, 2)
	setup := PPOContextTestSetup(&policy, &value)
	testing.expect(t, setup)
	if !setup { return }
	options := PPOTrainingContextOptionsDefault(5)
	for scratchFailure in ([2]bool{true, false}) {
		trainer: PPOTrainingContext(1, 2, 2, 1, 2, 2)
		state := PPOContextTestAllocator{backing = context.allocator, failFreeAt = 1}
		if scratchFailure { state.pointerAndErrorAt = 1 } else { state.failAt = 4 }
		allocator := mem.Allocator{procedure = PPOContextTestAllocatorProc, data = &state}
		result := PPOTrainingContextInit(&trainer, &policy, &value, options, allocator)
		if scratchFailure {
			testing.expect(t, result == .ScratchSetupFailed && state.allocations == 1 && state.live[0])
		} else {
			testing.expect(t, result == .OptimizerSetupFailed && state.allocations == 3 &&
				!state.live[0] && !state.live[1] && state.live[2])
		}
		// Internal rollback does not expose a retained block through the context.
		testing.expect(t, PPOTrainingContextState(&trainer) == nil && PPOTrainingContextDestroy(&trainer) == .None &&
			state.frees == state.allocations-1 && state.badFrees == 0)
		for pointer, index in state.allocated[:state.allocations] {
			if state.live[index] { testing.expect(t, mem.free(pointer, allocator) == nil) }
		}
		testing.expect(t, state.frees == state.allocations && state.badFrees == 0)
	}
}

@(test)
PPOTrainingContextDestroyFailureSequencing :: proc(t: ^testing.T) {
	policy, value: Sequential(1, 2, 2)
	setup := PPOContextTestSetup(&policy, &value)
	testing.expect(t, setup)
	if !setup { return }
	options := PPOTrainingContextOptionsDefault(5)
	policyBytes, valueBytes: [size_of(policy)]u8
	copy(policyBytes[:], mem.slice_ptr((^u8)(rawptr(&policy)), len(policyBytes)))
	copy(valueBytes[:], mem.slice_ptr((^u8)(rawptr(&value)), len(valueBytes)))
	for failAt in 1..=4 {
		trainer: PPOTrainingContext(1, 2, 2, 1, 2, 2)
		state := PPOContextTestAllocator{backing = context.allocator, failFreeAt = failAt}
		allocator := mem.Allocator{procedure = PPOContextTestAllocatorProc, data = &state}
		result := PPOTrainingContextInit(&trainer, &policy, &value, options, allocator)
		testing.expect(t, result == .None && state.allocations == 4)
		if result != .None { return }
		testing.expect(t, PPOTrainingContextDestroy(&trainer) == .CleanupFailed)
		for index in 0..<min(failAt, 3) { testing.expect(t, state.freeOrder[index] == state.allocated[3-index]) }
		if failAt <= 3 {
			testing.expect(t, state.freeCalls == failAt+1 && state.freeOrder[failAt-1] == state.allocated[4-failAt] &&
				state.freeOrder[failAt] == state.allocated[0] && !state.live[0] && state.live[4-failAt])
		} else {
			testing.expect(t, state.freeCalls == 4 && state.freeOrder[3] == state.allocated[0] && state.live[0])
		}
		testing.expect(t, PPOTrainingContextState(&trainer) == nil && PPOTrainingContextOptimizer(&trainer) == nil &&
			len(PPOTrainingContextEpochMetrics(&trainer)) == 0 && PPOTrainingContextRecordRollout(&trainer) == .InvalidHandle &&
			PPOTrainingContextInit(&trainer, &policy, &value, options, allocator) == .InvalidHandle)
		_, fitError := PPOTrainingContextFit(&trainer, nil)
		testing.expect(t, fitError == .InvalidHandle)
		testing.expect(t, PPOTrainingContextDestroy(&trainer) == .None && state.freeCalls == 5 && state.frees == 4 && state.badFrees == 0)
		for live in state.live[:4] { testing.expect(t, !live) }
		testing.expect(t, PPOTrainingContextDestroy(&trainer) == .None && state.freeCalls == 5 &&
			PPOContextTestBytesEqual(rawptr(&policy), policyBytes[:]) && PPOContextTestBytesEqual(rawptr(&value), valueBytes[:]))
	}
	trainer: PPOTrainingContext(1, 2, 2, 1, 2, 2)
	state := PPOContextTestAllocator{backing = context.allocator, failFreeAt = 1}
	allocator := mem.Allocator{procedure = PPOContextTestAllocatorProc, data = &state}
	result := PPOTrainingContextInit(&trainer, &policy, &value, options, allocator)
	testing.expect(t, result == .None)
	if result != .None { return }
	testing.expect(t, PPOTrainingContextDestroy(&trainer) == .CleanupFailed && state.freeCalls == 2 && !state.live[0])
	state.failFreeAt = 3
	testing.expect(t, PPOTrainingContextDestroy(&trainer) == .CleanupFailed && state.freeCalls == 3 && state.live[3] &&
		state.freeOrder[0] == state.allocated[3] && state.freeOrder[2] == state.allocated[3])
	state.failFreeAt = 0
	testing.expect(t, PPOTrainingContextDestroy(&trainer) == .None && state.freeCalls == 6 && state.frees == 4 && state.badFrees == 0)
}

@(test)
PPOTrainingContextRepeatedFitsMatchExplicitAdam :: proc(t: ^testing.T) {
	for configuredBatch in ([2]int{0, 2}) {
		policy, referencePolicy: Sequential(1, 2, 4)
		value, referenceValue: Sequential(1, 2, 3)
		trainer: PPOTrainingContext(1, 2, 4, 1, 2, 3)
		setup := PPOContextTestSetup(&policy, &value) && PPOContextTestSetup(&referencePolicy, &referenceValue)
		testing.expect(t, setup)
		if !setup { return }
		options := PPOTrainingContextOptionsDefault(7)
		options.objective = {0.15, 0.02, 0.6, 0.75}
		options.fit = {epochs = 3, batchSize = configuredBatch, maxGradientNorm = 0.01, finalLearningRate = 0.002}
		options.policySeed, options.shuffleSeed = 12345, 0
		options.learningRate, options.beta1, options.beta2, options.epsilon = 0.01, 0.8, 0.95, 1e-6
		allocatorState := PPOContextTestAllocator{backing = context.allocator}
		allocator := mem.Allocator{procedure = PPOContextTestAllocatorProc, data = &allocatorState}
		result := PPOTrainingContextInit(&trainer, &policy, &value, options, allocator)
		testing.expect(t, result == .None)
		if result != .None { return }
		defer PPOTrainingContextDestroy(&trainer)
		referenceState: PPOTrainingState
		setup = PPOTrainingStateInit(&referenceState, options.policySeed, options.shuffleSeed)
		policyNodes, valueNodes: [2]^core.Node
		policyParameters, policyOk := SequentialParameters(&referencePolicy, policyNodes[:])
		valueParameters, valueOk := SequentialParameters(&referenceValue, valueNodes[:])
		testing.expect(t, setup && policyOk && valueOk)
		if !setup || !policyOk || !valueOk { return }
		parameters: [4]^core.Node
		copy(parameters[:2], policyParameters)
		copy(parameters[2:], valueParameters)
		first, second: [9]f32
		referenceAdam: Adam
		setup = AdamInit(&referenceAdam, parameters[:], first[:], second[:], options.learningRate, options.beta1, options.beta2, options.epsilon)
		testing.expect(t, setup)
		if !setup { return }
		indices: [7]int
		batchObservations: [6]f32
		batchActions: [3]int
		batchLegal: [6]bool
		batchLogs: [3]f64
		batchAdvantages, batchReturns: [3]f32
		metrics: [3]PPOEpochStats
		scratch := PPOFitStorage{indices = indices[:], observations = batchObservations[:], actions = batchActions[:],
			legalActions = batchLegal[:], oldLogProbabilities = batchLogs[:], advantages = batchAdvantages[:],
			returns = batchReturns[:], epochMetrics = metrics[:]}
		backing, referenceBacking: PPOContextTestRolloutBacking
		buffer, referenceBuffer: rl.RolloutBuffer
		setup = PPOContextTestRolloutInit(&buffer, &backing) && PPOContextTestRolloutInit(&referenceBuffer, &referenceBacking)
		testing.expect(t, setup)
		if !setup { return }
		state := PPOTrainingContextState(&trainer)
		adam := PPOTrainingContextOptimizer(&trainer)
		testing.expect(t, state != nil && adam != nil)
		if state == nil || adam == nil { return }
		observation := [2]f32{0.25, 1}
		legal := [2]bool{true, true}
		greedy, greedyLog, greedyOk := SequentialPolicyAction(&policy, observation[:], legal[:], .Greedy, &state.policyRandomState)
		referenceGreedy, referenceLog, referenceGreedyOk := SequentialPolicyAction(&referencePolicy, observation[:], legal[:], .Greedy, &referenceState.policyRandomState)
		testing.expect(t, greedyOk && referenceGreedyOk && greedy == referenceGreedy && greedyLog == referenceLog &&
			state.policyRandomState == options.policySeed && referenceState.policyRandomState == options.policySeed)
		invalidLegal := [2]bool{false, false}
		_, _, invalidOk := SequentialPolicyAction(&policy, observation[:], invalidLegal[:], .Stochastic, &state.policyRandomState)
		testing.expect(t, !invalidOk && state.policyRandomState == options.policySeed)
		totalUpdates := 0
		for iteration in 0..<3 {
			count := 5
			if iteration == 1 { count = 2 }
			setup = PPOContextTestCollect(&policy, &value, state, &buffer, count) &&
				PPOContextTestCollect(&referencePolicy, &referenceValue, &referenceState, &referenceBuffer, count)
			testing.expect(t, setup && backing == referenceBacking && state^ == referenceState && state.policyRandomState != options.policySeed)
			if !setup { return }
			testing.expect(t, PPOTrainingContextRecordRollout(&trainer) == .None && PPOTrainingStateRecordRollout(&referenceState))
			rolloutBefore := backing
			stats, fitError := PPOTrainingContextFit(&trainer, &buffer)
			referenceStats, referenceOk := SequentialPPOFitStateful(&referencePolicy, &referenceValue, &referenceBuffer,
				&referenceState, options.objective, options.fit, &referenceAdam, scratch)
			batchSize := configuredBatch
			if batchSize == 0 { batchSize = 3 }
			updates := 3*(1+(count-1)/min(batchSize, count))
			totalUpdates += updates
			testing.expect(t, fitError == .None && referenceOk && stats == referenceStats && stats.epochs == 3 &&
				stats.updates == updates && stats.finalLearningRate == options.fit.finalLearningRate)
			testing.expect(t, state^ == referenceState && state.updateCount == u64(totalUpdates) && state.rolloutCount == u64(iteration+1) &&
				adam.step == u64(totalUpdates) && adam.step == referenceAdam.step && adam.learningRate == referenceAdam.learningRate &&
				PPOContextTestModelsEqual(&policy, &referencePolicy) && PPOContextTestModelsEqual(&value, &referenceValue))
			for moment, index in adam.firstMoment { testing.expect(t, moment == first[index] && adam.secondMoment[index] == second[index]) }
			actualMetrics := PPOTrainingContextEpochMetrics(&trainer)
			testing.expect(t, len(actualMetrics) == len(metrics))
			if len(actualMetrics) == len(metrics) {
				for metric, index in metrics { testing.expect(t, actualMetrics[index] == metric && metric.epoch == index+1) }
			}
			testing.expect(t, backing == rolloutBefore && referenceBacking == rolloutBefore && allocatorState.allocations == 4 && allocatorState.freeCalls == 0)
			if fitError != .None || !referenceOk { return }
		}
		testing.expect(t, PPOTrainingContextDestroy(&trainer) == .None && allocatorState.frees == 4 && allocatorState.badFrees == 0)
	}
}

@(test)
PPOTrainingContextInvalidRolloutsDoNotMutate :: proc(t: ^testing.T) {
	policy, value: Sequential(1, 2, 3)
	trainer: PPOTrainingContext(1, 2, 3, 1, 2, 3)
	setup := PPOContextTestSetup(&policy, &value)
	testing.expect(t, setup)
	if !setup { return }
	options := PPOTrainingContextOptionsDefault(5)
	allocatorState := PPOContextTestAllocator{backing = context.allocator}
	allocator := mem.Allocator{procedure = PPOContextTestAllocatorProc, data = &allocatorState}
	result := PPOTrainingContextInit(&trainer, &policy, &value, options, allocator)
	testing.expect(t, result == .None)
	if result != .None { return }
	defer PPOTrainingContextDestroy(&trainer)
	backing: PPOContextTestRolloutBacking
	buffer: rl.RolloutBuffer
	setup = PPOContextTestRolloutInit(&buffer, &backing) && PPOContextTestCollect(&policy, &value, PPOTrainingContextState(&trainer), &buffer, 5)
	testing.expect(t, setup)
	if !setup { return }
	warmup, warmupError := PPOTrainingContextFit(&trainer, &buffer)
	testing.expect(t, warmupError == .None && warmup.updates > 0 && PPOTrainingContextOptimizer(&trainer).step > 0)
	if warmupError != .None { return }
	trainerBytes: [size_of(trainer)]u8
	policyBytes, valueBytes: [size_of(policy)]u8
	allocationBytes: [4][4096]u8
	copy(trainerBytes[:], mem.slice_ptr((^u8)(rawptr(&trainer)), len(trainerBytes)))
	copy(policyBytes[:], mem.slice_ptr((^u8)(rawptr(&policy)), len(policyBytes)))
	copy(valueBytes[:], mem.slice_ptr((^u8)(rawptr(&value)), len(valueBytes)))
	for i in 0..<4 {
		testing.expect(t, allocatorState.sizes[i] <= len(allocationBytes[i]))
		if allocatorState.sizes[i] > len(allocationBytes[i]) { return }
		copy(allocationBytes[i][:allocatorState.sizes[i]], mem.slice_ptr((^u8)(allocatorState.allocated[i]), allocatorState.sizes[i]))
	}
	for kind in 0..<13 {
		bad := buffer
		expected := PPOTrainingContextError.InvalidRollout
		switch kind {
		case 0: bad.initialized = false
		case 1: bad.count = 0
		case 2: bad.count = 6 // Valid buffer, but above the context's capacity.
		case 3: bad.count = 8
		case 4: bad.count = -1
		case 5: bad.observationWidth = 1
		case 6: bad.actionCount = 1
		case 7: bad.storage.observations = bad.storage.observations[:1]
		case 8: bad.storage.returns = bad.storage.advantages
		case 9:
			bad.storage.observations = mem.slice_ptr((^f32)(rawptr(&trainer.state)), 14)
			testing.expect(t, rl.RolloutBufferValid(&bad))
		case 10:
			bad.capacity = 5
			bad.storage.returns = policy.inputData[:5]
			expected = .FitFailed // Lower-level overlap validation rejects model storage.
			testing.expect(t, rl.RolloutBufferValid(&bad))
		case 11:
			bad.storage.returns = mem.slice_ptr((^f32)(rawptr(raw_data(trainer.scratch.storage.indices))), 7)
			expected = .FitFailed
			testing.expect(t, rl.RolloutBufferValid(&bad))
		case 12:
			bad.storage.returns = PPOTrainingContextOptimizer(&trainer).firstMoment[:7]
			expected = .FitFailed
			testing.expect(t, rl.RolloutBufferValid(&bad))
		}
		badBytes: [size_of(bad)]u8
		backingBefore := backing
		copy(badBytes[:], mem.slice_ptr((^u8)(rawptr(&bad)), len(badBytes)))
		stats, fitError := PPOTrainingContextFit(&trainer, &bad)
		testing.expect(t, fitError == expected && stats == PPOFitStats{} && backing == backingBefore &&
			PPOContextTestBytesEqual(rawptr(&bad), badBytes[:]) && PPOContextTestBytesEqual(rawptr(&trainer), trainerBytes[:]) &&
			PPOContextTestBytesEqual(rawptr(&policy), policyBytes[:]) && PPOContextTestBytesEqual(rawptr(&value), valueBytes[:]))
		for i in 0..<4 { testing.expect(t, PPOContextTestBytesEqual(allocatorState.allocated[i], allocationBytes[i][:allocatorState.sizes[i]])) }
	}
	stats, fitError := PPOTrainingContextFit(&trainer, nil)
	testing.expect(t, fitError == .InvalidRollout && stats == PPOFitStats{} && PPOContextTestBytesEqual(rawptr(&trainer), trainerBytes[:]))
	state := PPOTrainingContextState(&trainer)
	state.updateCount = max(u64)
	copy(trainerBytes[:], mem.slice_ptr((^u8)(rawptr(&trainer)), len(trainerBytes)))
	stats, fitError = PPOTrainingContextFit(&trainer, &buffer)
	testing.expect(t, fitError == .FitFailed && stats == PPOFitStats{} && PPOContextTestBytesEqual(rawptr(&trainer), trainerBytes[:]) &&
		PPOContextTestBytesEqual(rawptr(&policy), policyBytes[:]) && PPOContextTestBytesEqual(rawptr(&value), valueBytes[:]))
	for i in 0..<4 { testing.expect(t, PPOContextTestBytesEqual(allocatorState.allocated[i], allocationBytes[i][:allocatorState.sizes[i]])) }
}

@(test)
PPOTrainingContextPartialFitReportsCommittedUpdates :: proc(t: ^testing.T) {
	policy, value: Sequential(1, 2, 3)
	trainer: PPOTrainingContext(1, 2, 3, 1, 2, 3)
	setup := PPOContextTestSetup(&policy, &value)
	testing.expect(t, setup)
	if !setup { return }
	options := PPOTrainingContextOptionsDefault(5)
	options.fit = {epochs = 2, batchSize = 2, finalLearningRate = 0.0005}
	options.shuffleSeed = 123
	result := PPOTrainingContextInit(&trainer, &policy, &value, options)
	testing.expect(t, result == .None)
	if result != .None { return }
	defer PPOTrainingContextDestroy(&trainer)
	backing: PPOContextTestRolloutBacking
	buffer: rl.RolloutBuffer
	state, adam := PPOTrainingContextState(&trainer), PPOTrainingContextOptimizer(&trainer)
	setup = state != nil && adam != nil && PPOContextTestRolloutInit(&buffer, &backing) && PPOContextTestCollect(&policy, &value, state, &buffer, 5)
	testing.expect(t, setup)
	if !setup { return }
	indices: [5]int
	expectedShuffle := state.shuffleRandomState
	testing.expect(t, PPOFitShuffle(indices[:], &expectedShuffle))
	badIndex := indices[4]
	goodAdvantage := backing.advantages[badIndex]
	backing.advantages[badIndex] = math.nan_f32()
	beforePolicy := policy.layers[0].storage.(DenseStorage(2)).weightData
	metrics := PPOTrainingContextEpochMetrics(&trainer)
	metrics[0].epoch = 777
	stats, fitError := PPOTrainingContextFit(&trainer, &buffer)
	testing.expect(t, fitError == .FitFailed && stats.updates == 2 && stats.epochs == 0 && state.updateCount == 2 &&
		adam.step == 2 && state.shuffleRandomState == expectedShuffle && metrics[0].epoch == 777 &&
		policy.layers[0].storage.(DenseStorage(2)).weightData != beforePolicy)
	backing.advantages[badIndex] = goodAdvantage
	stats, fitError = PPOTrainingContextFit(&trainer, &buffer)
	testing.expect(t, fitError == .None && stats.updates == 6 && stats.epochs == 2 && state.updateCount == 8 && adam.step == 8 &&
		metrics[0].epoch == 1 && metrics[1].epoch == 2)
}
