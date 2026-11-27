package nn

import "../core"
import "../rl"
import "core:math"
import "core:mem"
import "core:testing"

// Run these large-model regressions with an 8 MiB stack and one test thread.
PPOStackTestModels :: struct {
	policy, value, restoredPolicy, restoredValue: OwnedSequential(1, 1024, 2),
}

PPOStackTestModelsInit :: proc(models: ^PPOStackTestModels) -> bool {
	if !OwnedSequentialInit(&models.policy, 1, 7) || !OwnedSequentialInit(&models.value, 1, 11) ||
		!OwnedSequentialInit(&models.restoredPolicy, 1, 13) || !OwnedSequentialInit(&models.restoredValue, 1, 19) {
		return false
	}
	policy, value := OwnedSequentialModel(&models.policy), OwnedSequentialModel(&models.value)
	restoredPolicy, restoredValue := OwnedSequentialModel(&models.restoredPolicy), OwnedSequentialModel(&models.restoredValue)
	return SequentialAddDense(policy, 2) && SequentialAddDense(value, 1) &&
		SequentialAddDense(restoredPolicy, 2) && SequentialAddDense(restoredValue, 1)
}

PPOStackTestModelsDestroy :: proc(models: ^PPOStackTestModels) {
	OwnedSequentialDestroy(&models.restoredValue)
	OwnedSequentialDestroy(&models.restoredPolicy)
	OwnedSequentialDestroy(&models.value)
	OwnedSequentialDestroy(&models.policy)
}

PPOStackTestRollout :: struct {
	observations, rewards, values, nextValues, advantages, returns: [1]f32,
	actions: [1]int,
	logs: [1]f64,
	legal: [2]bool,
	terminated, truncated: [1]bool,
	buffer: rl.RolloutBuffer,
}

PPOStackTestRolloutInit :: proc(backing: ^PPOStackTestRollout) -> bool {
	storage := rl.RolloutStorage{
		observations = backing.observations[:], actions = backing.actions[:], rewards = backing.rewards[:],
		values = backing.values[:], nextValues = backing.nextValues[:], oldLogProbabilities = backing.logs[:],
		legalActions = backing.legal[:], terminated = backing.terminated[:], truncated = backing.truncated[:],
		advantages = backing.advantages[:], returns = backing.returns[:],
	}
	observation := [1]f32{0.5}
	legal := [2]bool{true, true}
	return rl.RolloutBufferInit(&backing.buffer, storage, 1, 1, 2) &&
		rl.RolloutBufferAppend(&backing.buffer, {
			observation = observation[:], action = 0, reward = 1,
			oldLogProbability = -0.6931471805599453, legalActions = legal[:], terminated = true,
		}) && rl.RolloutComputeGAE(&backing.buffer, 0.99, 0.95)
}

PPOStackTestAdamEqual :: proc(a, b: ^Adam) -> bool {
	if a == nil || b == nil || a.step != b.step || a.learningRate != b.learningRate || a.beta1 != b.beta1 ||
		a.beta2 != b.beta2 || a.epsilon != b.epsilon || len(a.parameters) != len(b.parameters) ||
		len(a.firstMoment) != len(b.firstMoment) || len(a.secondMoment) != len(b.secondMoment) { return false }
	for moment, i in a.firstMoment { if moment != b.firstMoment[i] || a.secondMoment[i] != b.secondMoment[i] { return false } }
	return true
}

PPOStackTestParametersEqual :: proc(a, b: ^Sequential($layers, $width, $batch)) -> bool {
	as, bs: [2*layers]^core.Node
	ap, aOk := SequentialParameters(a, as[:])
	bp, bOk := SequentialParameters(b, bs[:])
	if !aOk || !bOk || len(ap) != len(bp) || a.randomState != b.randomState { return false }
	for parameter, i in ap {
		if len(parameter.value.data) != len(bp[i].value.data) { return false }
		for value, j in parameter.value.data { if value != bp[i].value.data[j] { return false } }
	}
	return true
}

@(test)
PPOCheckpointStackLargeBase :: proc(t: ^testing.T) {
	models: PPOStackTestModels
	defer PPOStackTestModelsDestroy(&models)
	setup := PPOStackTestModelsInit(&models)
	testing.expect(t, setup && SequentialStorageSize(1, 1024, 2) > 8*1024*1024)
	if !setup { return }
	policy, value := OwnedSequentialModel(&models.policy), OwnedSequentialModel(&models.value)
	restoredPolicy, restoredValue := OwnedSequentialModel(&models.restoredPolicy), OwnedSequentialModel(&models.restoredValue)
	owner, restoredOwner: PPOOwnedAdam
	defer PPOOwnedAdamDestroy(&owner)
	defer PPOOwnedAdamDestroy(&restoredOwner)
	setup = PPOOwnedAdamInit(&owner, policy, value, learningRate = 0.01) &&
		PPOOwnedAdamInit(&restoredOwner, restoredPolicy, restoredValue)
	testing.expect(t, setup)
	if !setup { return }
	adam, restoredAdam := PPOOwnedAdamOptimizer(&owner), PPOOwnedAdamOptimizer(&restoredOwner)
	backing: PPOStackTestRollout
	storageOwner: PPOOwnedFitStorage
	defer PPOOwnedFitStorageDestroy(&storageOwner)
	state: PPOTrainingState
	setup = PPOStackTestRolloutInit(&backing) && PPOTrainingStateInit(&state, 123, 456) &&
		PPOTrainingStateRecordRollout(&state) && PPOOwnedFitStorageInit(&storageOwner, 1, 1, 2, 1, 1)
	testing.expect(t, setup)
	if !setup { return }
	storage, storageOk := PPOOwnedFitStorageView(&storageOwner)
	config := PPOConfig{0.2, 0.01, 0.5, 1}
	fit := PPOFitConfig{epochs = 1, batchSize = 1}
	stats, fitOk := SequentialPPOFitStateful(policy, value, &backing.buffer, &state, config, fit, adam, storage)
	testing.expect(t, storageOk && fitOk && stats.updates == 1 && adam.step == 1)
	if !storageOk || !fitOk { return }
	checkpoint, policyScratch, valueScratch: [4096]u8
	size, saved := PPOCheckpointWrite(policy, value, adam, state, config, fit, checkpoint[:], policyScratch[:], valueScratch[:])
	testing.expect(t, saved)
	if !saved { return }
	parameters, first, second, available := PPOOwnedAdamStorage(&restoredOwner)
	testing.expect(t, available)
	if !available { return }
	restoredState: PPOTrainingState
	restoredConfig: PPOConfig
	restoredFit: PPOFitConfig
	restoredOptimizer: SequentialOptimizer
	loaded: bool
	{
		context.allocator = mem.nil_allocator()
		restoredState, restoredConfig, restoredFit, restoredOptimizer, loaded = PPOCheckpointRead(
			restoredPolicy, restoredValue, checkpoint[:size], restoredAdam, parameters, first, second,
		)
	}
	testing.expect(t, loaded && restoredState == state && restoredConfig == config && restoredFit == fit &&
		PPOStackTestAdamEqual(adam, restoredAdam) && PPOStackTestParametersEqual(policy, restoredPolicy) &&
		PPOStackTestParametersEqual(value, restoredValue))
	if !loaded { return }
	pointer, isAdam := restoredOptimizer.(^Adam)
	restoredPolicyDense := &restoredPolicy.layers[0].storage.(DenseStorage(1024))
	restoredValueDense := &restoredValue.layers[0].storage.(DenseStorage(1024))
	testing.expect(t, isAdam && pointer == restoredAdam && restoredAdam.parameters[0] == &restoredPolicyDense.weights &&
		restoredAdam.parameters[2] == &restoredValueDense.weights)
	next, nextOk := SequentialPPOFitStateful(policy, value, &backing.buffer, &state, config, fit, adam, storage)
	restoredNext, restoredOk := SequentialPPOFitStateful(restoredPolicy, restoredValue, &backing.buffer, &restoredState, restoredConfig, restoredFit, restoredOptimizer, storage)
	testing.expect(t, nextOk && restoredOk && next == restoredNext && state == restoredState &&
		PPOStackTestAdamEqual(adam, restoredAdam) && PPOStackTestParametersEqual(policy, restoredPolicy) &&
		PPOStackTestParametersEqual(value, restoredValue))
}

@(test)
PPOCheckpointStackLargeContext :: proc(t: ^testing.T) {
	models: PPOStackTestModels
	defer PPOStackTestModelsDestroy(&models)
	setup := PPOStackTestModelsInit(&models)
	testing.expect(t, setup && SequentialStorageSize(1, 1024, 2) > 8*1024*1024)
	if !setup { return }
	policy, value := OwnedSequentialModel(&models.policy), OwnedSequentialModel(&models.value)
	restoredPolicy, restoredValue := OwnedSequentialModel(&models.restoredPolicy), OwnedSequentialModel(&models.restoredValue)
	trainer, restored: PPOTrainingContext(1, 1024, 2, 1, 1024, 2)
	defer PPOTrainingContextDestroy(&trainer)
	defer PPOTrainingContextDestroy(&restored)
	options := PPOTrainingContextOptionsDefault(1)
	options.fit = {epochs = 1, batchSize = 1}
	setup = PPOTrainingContextInit(&trainer, policy, value, options) == .None &&
		PPOTrainingContextInit(&restored, restoredPolicy, restoredValue, options) == .None
	testing.expect(t, setup)
	if !setup { return }
	backing: PPOStackTestRollout
	setup = PPOStackTestRolloutInit(&backing) && PPOTrainingContextRecordRollout(&trainer) == .None
	testing.expect(t, setup)
	if !setup { return }
	stats, fitError := PPOTrainingContextFit(&trainer, &backing.buffer)
	testing.expect(t, fitError == .None && stats.updates == 1)
	if fitError != .None { return }
	checkpoint, policyScratch, valueScratch: [4096]u8
	size, writeError := PPOTrainingContextCheckpointWrite(&trainer, checkpoint[:], policyScratch[:], valueScratch[:])
	testing.expect(t, writeError == .None)
	if writeError != .None { return }
	readError: PPOTrainingContextError
	{
		context.allocator = mem.nil_allocator()
		readError = PPOTrainingContextCheckpointRead(&restored, checkpoint[:size])
	}
	testing.expect(t, readError == .None && PPOTrainingContextState(&trainer)^ == PPOTrainingContextState(&restored)^ &&
		PPOStackTestAdamEqual(PPOTrainingContextOptimizer(&trainer), PPOTrainingContextOptimizer(&restored)) &&
		PPOStackTestParametersEqual(policy, restoredPolicy) && PPOStackTestParametersEqual(value, restoredValue))
	if readError != .None { return }
	next, nextError := PPOTrainingContextFit(&trainer, &backing.buffer)
	restoredNext, restoredError := PPOTrainingContextFit(&restored, &backing.buffer)
	testing.expect(t, nextError == .None && restoredError == .None && next == restoredNext &&
		PPOTrainingContextState(&trainer)^ == PPOTrainingContextState(&restored)^ &&
		PPOStackTestAdamEqual(PPOTrainingContextOptimizer(&trainer), PPOTrainingContextOptimizer(&restored)) &&
		PPOStackTestParametersEqual(policy, restoredPolicy) && PPOStackTestParametersEqual(value, restoredValue))
}

// Assemble an SGD envelope so PPO-incompatible but individually valid supervised
// models can be tested without the writer rejecting them first.
PPOStackTestSGDEnvelope :: proc(policy, value, output: []u8) -> (int, bool) {
	if len(output) < 116 || len(policy) > len(output)-116 || len(value) > len(output)-116-len(policy) { return 0, false }
	offset := 0
	for item in ([8]u64{PPO_CHECKPOINT_MAGIC, PPO_CHECKPOINT_VERSION, u64(len(policy)), u64(len(value)), 3, 2, 17, 29}) {
		CheckpointPut64(output, &offset, item)
	}
	for item in ([4]f32{0.2, 0.01, 0.5, 1}) { CheckpointPut32(output, &offset, item) }
	CheckpointPut64(output, &offset, 1)
	CheckpointPut64(output, &offset, 1)
	CheckpointPut32(output, &offset, 0)
	CheckpointPut32(output, &offset, 0)
	CheckpointPut64(output, &offset, 0)
	CheckpointPut32(output, &offset, 0.01)
	copy(output[offset:offset+len(policy)], policy); offset += len(policy)
	copy(output[offset:offset+len(value)], value); offset += len(value)
	return offset, true
}

// This is the previous probe-based PPO topology check, retained as a small-model
// differential oracle; it must not be used for the large-model tests.
PPOStackTestProbeValid :: proc(policyInput, valueInput: []u8) -> bool {
	policy, value: Sequential(6, 4, 2)
	policyState, valueState: u64
	if !CheckpointRead(&policy, nil, &policyState, policyInput, nil, nil, nil) ||
		!CheckpointRead(&value, nil, &valueState, valueInput, nil, nil, nil) { return false }
	parameters: [24]^core.Node
	_, _, ok := PPOCheckpointCombinedParameters(&policy, &value, parameters[:])
	return ok
}

PPOStackTestBytesEqual :: proc(address: rawptr, expected: []u8) -> bool {
	actual := mem.slice_ptr((^u8)(address), len(expected))
	for item, i in expected { if item != actual[i] { return false } }
	return true
}

@(test)
PPOCheckpointStackTopologyAndInspection :: proc(t: ^testing.T) {
	for mode in 0..<25 {
		policy, value: Sequential(6, 4, 2)
		setup := SequentialInit(&policy, 1, 7) && SequentialInit(&value, 1, 11)
		if mode == 9 || mode == 10 || mode == 22 || mode == 23 { setup = setup && SequentialInitSpatial(&policy, 1, 1, 1, 7) }
		if mode == 11 || mode == 12 { setup = setup && SequentialInitSpatial(&value, 1, 1, 1, 11) }
		if mode == 13 { setup = setup && SequentialInit(&value, 2, 11) }
		if mode == 20 || mode == 21 {
			setup = setup && SequentialInitSpatial(&policy, 2, 2, 1, 7) && SequentialInit(&value, 4, 11)
		}
		switch mode {
		case 7: setup = setup && SequentialAddFlatten(&policy)
		case 9, 10:
			setup = setup && SequentialAddConv2D(&policy, 1, 1, 2)
			if mode == 10 { setup = setup && SequentialAddFlatten(&policy) }
		case 20, 21:
			poolKind := PoolKind.Max
			if mode == 21 { poolKind = .Average }
			setup = setup && SequentialAddConv2D(&policy, 1, 1, 1) && SequentialAddPool2D(&policy, poolKind, 2, 2, 1) &&
				SequentialAddFlatten(&policy) && SequentialAddDense(&policy, 2)
		case 22, 23:
			setup = setup && SequentialAddConv2D(&policy, 1, 1, 2) && SequentialAddActivation(&policy, .Softmax)
			if mode == 23 { setup = setup && SequentialAddPool2D(&policy, .Max, 1, 1, 1) }
			setup = setup && SequentialAddFlatten(&policy) && SequentialAddDropout(&policy)
		case 16:
		case 17: setup = setup && SequentialAddDropout(&policy) && SequentialAddFlatten(&policy)
		case: setup = setup && SequentialAddDense(&policy, 2)
		}
		switch mode {
		case 1: setup = setup && SequentialAddActivation(&policy, .Softmax)
		case 2: setup = setup && SequentialAddActivation(&policy, .Softmax) && SequentialAddDropout(&policy)
		case 3: setup = setup && SequentialAddActivation(&policy, .Softmax) && SequentialAddDropout(&policy) && SequentialAddFlatten(&policy) && SequentialAddDropout(&policy)
		case 4: setup = setup && SequentialAddActivation(&policy, .Softmax) && SequentialAddFlatten(&policy) && SequentialAddActivation(&policy, .Tanh) && SequentialAddDropout(&policy)
		case 5: setup = setup && SequentialAddActivation(&policy, .Softmax) && SequentialAddDense(&policy, 2)
		case 18: setup = setup && SequentialAddActivation(&policy, .Softmax) && SequentialAddFlatten(&policy) && SequentialAddDense(&policy, 2)
		}
		switch mode {
		case 8: setup = setup && SequentialAddFlatten(&value)
		case 11, 12:
			setup = setup && SequentialAddConv2D(&value, 1, 1, 1)
			if mode == 12 { setup = setup && SequentialAddFlatten(&value) }
		case 14: setup = setup && SequentialAddDense(&value, 2)
		case: setup = setup && SequentialAddDense(&value, 1)
		}
		if mode == 6 { setup = setup && SequentialAddActivation(&value, .Softmax) }
		testing.expectf(t, setup, "topology %d setup", mode)
		if !setup { return }
		policyData, valueData, checkpoint: [4096]u8
		policyAdam, valueAdam: Adam
		policyParameters, valueParameters: [12]^core.Node
		policyFirst, policySecond, valueFirst, valueSecond: [32]f32
		policyAdamPointer, valueAdamPointer: ^Adam
		if mode == 15 || mode == 19 {
			p, pOk := SequentialParameters(&policy, policyParameters[:])
			v, vOk := SequentialParameters(&value, valueParameters[:])
			_, pElements, prOk := SequentialAdamRequirements(&policy)
			_, vElements, vrOk := SequentialAdamRequirements(&value)
			setup = pOk && vOk && prOk && vrOk && AdamInit(&policyAdam, p, policyFirst[:pElements], policySecond[:pElements]) &&
				AdamInit(&valueAdam, v, valueFirst[:vElements], valueSecond[:vElements])
			if mode == 15 { policyAdamPointer = &policyAdam } else { valueAdamPointer = &valueAdam }
		}
		policySize, pWritten := CheckpointWrite(&policy, policyAdamPointer, 0, policyData[:])
		valueSize, vWritten := CheckpointWrite(&value, valueAdamPointer, 0, valueData[:])
		if mode == 24 && pWritten {
			// Version 2 with zero spatial dimensions is valid even for a dense-only model.
			original := policyData
			policyData = {}
			copy(policyData[:80], original[:80])
			position := 8
			CheckpointPut64(policyData[:], &position, CHECKPOINT_SPATIAL_VERSION)
			copy(policyData[104:], original[80:policySize])
			policySize += 24
		}
		size, assembled := PPOStackTestSGDEnvelope(policyData[:policySize], valueData[:valueSize], checkpoint[:])
		testing.expectf(t, setup && pWritten && vWritten && assembled, "topology %d encoded", mode)
		if !setup || !pWritten || !vWritten || !assembled { return }
		_, details, inspectError := CheckpointInspectWithDetails(policyData[:policySize])
		_, lastIsSoftmax := SequentialLogitsOutputLayer(&policy).(^Softmax)
		testing.expectf(t, inspectError.code == .None && details.effectiveOutputIsSoftmax == lastIsSoftmax, "topology %d details", mode)
		_, badDetails, truncatedError := CheckpointInspectWithDetails(policyData[:policySize-1])
		testing.expectf(t, truncatedError.code != .None && badDetails == (CheckpointInspectDetails{}), "topology %d failed inspection", mode)
		expected := PPOStackTestProbeValid(policyData[:policySize], valueData[:valueSize])
		shouldAccept := mode == 0 || mode == 4 || mode == 5 || mode == 6 || mode == 10 || mode == 12 ||
			mode == 18 || mode == 20 || mode == 21 || mode == 23 || mode == 24
		testing.expectf(t, expected == shouldAccept, "topology %d: unexpected probe result %v", mode, expected)
		restoredPolicy, restoredValue: Sequential(6, 4, 2)
		setup = SequentialInit(&restoredPolicy, 1, 101) && SequentialAddDense(&restoredPolicy, 1) &&
			SequentialInit(&restoredValue, 1, 103) && SequentialAddDense(&restoredValue, 1)
		testing.expect(t, setup)
		if !setup { return }
		policyBefore, valueBefore: [size_of(Sequential(6, 4, 2))]u8
		copy(policyBefore[:], mem.slice_ptr((^u8)(rawptr(&restoredPolicy)), len(policyBefore)))
		copy(valueBefore[:], mem.slice_ptr((^u8)(rawptr(&restoredValue)), len(valueBefore)))
		_, _, _, _, loaded := PPOCheckpointRead(&restoredPolicy, &restoredValue, checkpoint[:size], nil, nil, nil, nil)
		testing.expectf(t, loaded == expected, "topology %d: read %v, probe %v", mode, loaded, expected)
		if !loaded {
			testing.expectf(t, PPOStackTestBytesEqual(rawptr(&restoredPolicy), policyBefore[:]) &&
				PPOStackTestBytesEqual(rawptr(&restoredValue), valueBefore[:]), "topology %d mutated destinations", mode)
		}
	}
}

@(test)
PPOCheckpointStackFailuresAreAtomic :: proc(t: ^testing.T) {
	policy, value, destinationPolicy, destinationValue: Sequential(2, 3, 2)
	owner: PPOOwnedAdam
	defer PPOOwnedAdamDestroy(&owner)
	setup := SequentialInit(&policy, 1, 7) && SequentialAddDense(&policy, 2) &&
		SequentialInit(&value, 1, 11) && SequentialAddDense(&value, 1) &&
		SequentialInit(&destinationPolicy, 1, 13) && SequentialAddDense(&destinationPolicy, 2) &&
		SequentialInit(&destinationValue, 1, 19) && SequentialAddDense(&destinationValue, 1) &&
		PPOOwnedAdamInit(&owner, &policy, &value)
	testing.expect(t, setup)
	if !setup { return }
	checkpoint, policyScratch, valueScratch: [4096]u8
	size, saved := PPOCheckpointWrite(&policy, &value, PPOOwnedAdamOptimizer(&owner),
		PPOTrainingState{updateCount = 1, policyRandomState = 17, shuffleRandomState = 29},
		PPOConfig{0.2, 0.01, 0.5, 1}, PPOFitConfig{epochs = 1, batchSize = 1},
		checkpoint[:], policyScratch[:], valueScratch[:])
	testing.expect(t, saved)
	if !saved { return }
	policyInput, valueInput, peekOk := PPOCheckpointPeekModelPayloads(checkpoint[:size])
	testing.expect(t, peekOk)
	if !peekOk { return }
	policyOffset := int(uintptr(rawptr(raw_data(policyInput)))-uintptr(rawptr(raw_data(checkpoint[:]))))
	valueOffset := int(uintptr(rawptr(raw_data(valueInput)))-uintptr(rawptr(raw_data(checkpoint[:]))))
	for mode in 0..<21 {
		candidateWords: [512]u64
		candidate := mem.slice_ptr((^u8)(rawptr(&candidateWords[0])), size_of(candidateWords))
		copy(candidate, checkpoint[:])
		inputSize := size
		parameters: [4]^core.Node
		first, second: [6]f32
		for &item in first { item = 2 }
		for &item in second { item = 3 }
		adam := Adam{step = 123, learningRate = 0.25}
		parameterView, firstView, secondView := parameters[:], first[:], second[:]
		adamView := &adam
		input := candidate[:inputSize]
		position := 0
		switch mode {
		case 0: inputSize -= 1
		case 1: candidate[policyOffset] ~= 0xff
		case 2: candidate[valueOffset] ~= 0xff
		case 3: position = policyOffset+16; CheckpointPut64(candidate, &position, 1)
		case 4: position = valueOffset+24; CheckpointPut64(candidate, &position, 2)
		case 5: position = 64; CheckpointPut32(candidate, &position, math.nan_f32())
		case 6: position = 144; CheckpointPut32(candidate, &position, math.nan_f32())
		case 7: position = 144+6*4; CheckpointPut32(candidate, &position, -1)
		case 8:
			// Remove one entry from each moment array while retaining complete nested payloads.
			copy(candidate[144+5*4:144+10*4], checkpoint[144+6*4:144+11*4])
			copy(candidate[144+10*4:], checkpoint[144+12*4:size])
			inputSize -= 8
			position = 136; CheckpointPut64(candidate, &position, 5)
		case 9: parameterView = parameters[:3]
		case 10: firstView = first[:5]
		case 11: secondView = second[:5]
		case 12: secondView = first[:]
		case 13: parameterView = mem.slice_ptr((^^core.Node)(rawptr(raw_data(candidate))), 4)
		case 14: adamView = (^Adam)(rawptr(&destinationPolicy))
		case 15: parameterView = mem.slice_ptr((^^core.Node)(rawptr(&destinationValue)), 4)
		case 16: position = policyOffset+72; CheckpointPut64(candidate, &position, 1)
		case 17:
			input = mem.slice_ptr((^u8)(rawptr(&destinationPolicy)), inputSize)
			copy(input, checkpoint[:inputSize])
		case 18: firstView = mem.slice_ptr((^f32)(rawptr(&destinationValue)), 6)
		case 19: secondView = mem.slice_ptr((^f32)(rawptr(raw_data(parameters[:]))), 6)
		case 20: position = policyOffset+80; CheckpointPut64(candidate, &position, 99)
		}
		if mode != 17 { input = candidate[:inputSize] }
		if mode == 8 {
			p, v, valid := PPOCheckpointPeekModelPayloads(candidate[:inputSize])
			_, pe := CheckpointInspect(p)
			_, ve := CheckpointInspect(v)
			testing.expect(t, valid && pe.code == .None && ve.code == .None)
		}
		policyBefore, valueBefore: [size_of(Sequential(2, 3, 2))]u8
		adamBefore: [size_of(Adam)]u8
		copy(policyBefore[:], mem.slice_ptr((^u8)(rawptr(&destinationPolicy)), len(policyBefore)))
		copy(valueBefore[:], mem.slice_ptr((^u8)(rawptr(&destinationValue)), len(valueBefore)))
		copy(adamBefore[:], mem.slice_ptr((^u8)(rawptr(&adam)), len(adamBefore)))
		parametersBefore, firstBefore, secondBefore := parameters, first, second
		candidateBefore := candidateWords
		_, _, _, _, loaded := PPOCheckpointRead(&destinationPolicy, &destinationValue, input, adamView, parameterView, firstView, secondView)
		testing.expectf(t, !loaded && PPOStackTestBytesEqual(rawptr(&destinationPolicy), policyBefore[:]) &&
			PPOStackTestBytesEqual(rawptr(&destinationValue), valueBefore[:]) && PPOStackTestBytesEqual(rawptr(&adam), adamBefore[:]) &&
			parameters == parametersBefore && first == firstBefore && second == secondBefore && candidateWords == candidateBefore,
			"atomic failure %d", mode)
	}
}

@(test)
PPOCheckpointStackDifferentialNestedBytes :: proc(t: ^testing.T) {
	policy, value, destinationPolicy, destinationValue: Sequential(6, 4, 2)
	setup := SequentialInit(&policy, 4, 7) && SequentialAddDense(&policy, 2) &&
		SequentialAddActivation(&policy, .Tanh) && SequentialAddDropout(&policy, 0.25) && SequentialAddFlatten(&policy) &&
		SequentialInit(&value, 4, 11) && SequentialAddDense(&value, 1) &&
		SequentialInit(&destinationPolicy, 1, 13) && SequentialAddDense(&destinationPolicy, 2) &&
		SequentialInit(&destinationValue, 1, 19) && SequentialAddDense(&destinationValue, 1)
	testing.expect(t, setup)
	if !setup { return }
	policyData, valueData, checkpoint: [4096]u8
	policySize, policyOk := CheckpointWrite(&policy, nil, 0, policyData[:])
	valueSize, valueOk := CheckpointWrite(&value, nil, 0, valueData[:])
	testing.expect(t, policyOk && valueOk && PPOStackTestProbeValid(policyData[:policySize], valueData[:valueSize]))
	if !policyOk || !valueOk { return }
	accepted, rejected := 0, 0
	for side in 0..<2 {
		payload := policyData[:policySize]
		if side == 1 { payload = valueData[:valueSize] }
		for index in 0..<len(payload) {
			for bit in 0..<8 {
				mask := u8(1 << uint(bit))
				payload[index] ~= mask
				expected := PPOStackTestProbeValid(policyData[:policySize], valueData[:valueSize])
				size, assembled := PPOStackTestSGDEnvelope(policyData[:policySize], valueData[:valueSize], checkpoint[:])
				if !assembled { testing.expect(t, false); return }
				policyBefore, valueBefore: [size_of(Sequential(6, 4, 2))]u8
				copy(policyBefore[:], mem.slice_ptr((^u8)(rawptr(&destinationPolicy)), len(policyBefore)))
				copy(valueBefore[:], mem.slice_ptr((^u8)(rawptr(&destinationValue)), len(valueBefore)))
				_, _, _, _, loaded := PPOCheckpointRead(&destinationPolicy, &destinationValue, checkpoint[:size], nil, nil, nil, nil)
				if loaded { accepted += 1 } else { rejected += 1 }
				if loaded != expected || !loaded && (!PPOStackTestBytesEqual(rawptr(&destinationPolicy), policyBefore[:]) ||
					!PPOStackTestBytesEqual(rawptr(&destinationValue), valueBefore[:])) {
					testing.expectf(t, false, "differential side %d byte %d bit %d: read %v, probe %v", side, index, bit, loaded, expected)
					return
				}
				payload[index] ~= mask
			}
		}
	}
	testing.expect(t, accepted > 0 && rejected > 0)
}

@(test)
PPOCheckpointStackIndependentCapacities :: proc(t: ^testing.T) {
	policy, restoredPolicy: Sequential(2, 4, 3)
	value, restoredValue: Sequential(3, 5, 2)
	owner, restoredOwner: PPOOwnedAdam
	defer PPOOwnedAdamDestroy(&owner)
	defer PPOOwnedAdamDestroy(&restoredOwner)
	setup := SequentialInit(&policy, 2, 7) && SequentialAddDense(&policy, 2) &&
		SequentialInit(&value, 2, 11) && SequentialAddDense(&value, 1) &&
		SequentialInit(&restoredPolicy, 2, 13) && SequentialAddDense(&restoredPolicy, 2) &&
		SequentialInit(&restoredValue, 2, 19) && SequentialAddDense(&restoredValue, 1) &&
		PPOOwnedAdamInit(&owner, &policy, &value) && PPOOwnedAdamInit(&restoredOwner, &restoredPolicy, &restoredValue)
	testing.expect(t, setup)
	if !setup { return }
	adam, restoredAdam := PPOOwnedAdamOptimizer(&owner), PPOOwnedAdamOptimizer(&restoredOwner)
	for parameter in adam.parameters { for &gradient in parameter.grad.data { gradient = 1 } }
	setup = AdamStep(adam)
	testing.expect(t, setup)
	if !setup { return }
	state := PPOTrainingState{updateCount = 1, rolloutCount = 1, policyRandomState = 23, shuffleRandomState = 29}
	config := PPOConfig{0.2, 0.01, 0.5, 1}
	fit := PPOFitConfig{epochs = 2, batchSize = 2}
	checkpoint, policyScratch, valueScratch: [4096]u8
	size, saved := PPOCheckpointWrite(&policy, &value, adam, state, config, fit, checkpoint[:], policyScratch[:], valueScratch[:])
	testing.expect(t, saved)
	if !saved { return }
	parameters, first, second, available := PPOOwnedAdamStorage(&restoredOwner)
	testing.expect(t, available)
	if !available { return }
	restoredState, restoredConfig, restoredFit, _, loaded := PPOCheckpointRead(
		&restoredPolicy, &restoredValue, checkpoint[:size], restoredAdam, parameters, first, second,
	)
	testing.expect(t, loaded && restoredState == state && restoredConfig == config && restoredFit == fit &&
		PPOStackTestAdamEqual(adam, restoredAdam) && PPOStackTestParametersEqual(&policy, &restoredPolicy) &&
		PPOStackTestParametersEqual(&value, &restoredValue))
}
