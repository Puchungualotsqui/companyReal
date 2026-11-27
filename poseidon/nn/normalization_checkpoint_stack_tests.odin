package nn

import "../core"
import "../data"
import "core:math"
import "core:mem"
import "core:testing"

// Run the large-model cases with an 8 MiB stack and one test thread.
PPOStackNormStats :: struct {
	observation, reward: data.RunningStandardizer,
	observationMean, observationM2, rewardMean, rewardM2: [2]f64,
}

PPOStackNormStatsInit :: proc(stats: ^PPOStackNormStats, observationWidth, rewardWidth: int, populated: bool) -> bool {
	observationEpsilon, rewardEpsilon: f64 = 0.002, 0.003
	if !populated { observationEpsilon, rewardEpsilon = 0.04, 0.05 }
	if !data.RunningStandardizerInit(&stats.observation, stats.observationMean[:observationWidth], stats.observationM2[:observationWidth], observationEpsilon) ||
		!data.RunningStandardizerInit(&stats.reward, stats.rewardMean[:rewardWidth], stats.rewardM2[:rewardWidth], rewardEpsilon) { return false }
	if !populated { return true }
	observations := [4]f32{1, 2, 3, 4}
	rewards := [4]f32{-1, 2, 3, 4}
	return data.RunningStandardizerUpdate(&stats.observation, observations[:2*observationWidth]) &&
		data.RunningStandardizerUpdate(&stats.reward, rewards[:2*rewardWidth]) &&
		data.RunningStandardizerFreeze(&stats.observation)
}

PPOStackNormEqual :: proc(a, b: ^data.RunningStandardizer) -> bool {
	if a == nil || b == nil || a.count != b.count || a.epsilon != b.epsilon || a.frozen != b.frozen ||
		len(a.mean) != len(b.mean) || len(a.m2) != len(b.m2) { return false }
	for item, i in a.mean { if item != b.mean[i] || a.m2[i] != b.m2[i] { return false } }
	return true
}

@(test)
NormalizationCheckpointStackLargeRestore :: proc(t: ^testing.T) {
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
	sourceStats, restoredStats: PPOStackNormStats
	setup = PPOOwnedAdamInit(&owner, policy, value, learningRate = 0.01) &&
		PPOOwnedAdamInit(&restoredOwner, restoredPolicy, restoredValue) &&
		PPOStackNormStatsInit(&sourceStats, 1, 1, true) && PPOStackNormStatsInit(&restoredStats, 1, 1, false)
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
	checkpoint, baseScratch, policyScratch, valueScratch: [4096]u8
	size, saved := PPOCheckpointWriteNormalized(policy, value, adam, state, config, fit,
		{&sourceStats.observation, &sourceStats.reward}, checkpoint[:], baseScratch[:], policyScratch[:], valueScratch[:])
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
		restoredState, restoredConfig, restoredFit, restoredOptimizer, loaded = PPOCheckpointReadNormalized(
			restoredPolicy, restoredValue, checkpoint[:size], restoredAdam, parameters, first, second,
			{&restoredStats.observation, &restoredStats.reward},
		)
	}
	testing.expect(t, loaded && restoredState == state && restoredConfig == config && restoredFit == fit &&
		PPOStackTestAdamEqual(adam, restoredAdam) && PPOStackTestParametersEqual(policy, restoredPolicy) &&
		PPOStackTestParametersEqual(value, restoredValue) && PPOStackNormEqual(&sourceStats.observation, &restoredStats.observation) &&
		PPOStackNormEqual(&sourceStats.reward, &restoredStats.reward))
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
NormalizationCheckpointStackLargePolicyExport :: proc(t: ^testing.T) {
	models: PPOStackTestModels
	defer PPOStackTestModelsDestroy(&models)
	setup := PPOStackTestModelsInit(&models)
	testing.expect(t, setup && SequentialStorageSize(1, 1024, 2) > 8*1024*1024)
	if !setup { return }
	policy, restoredPolicy := OwnedSequentialModel(&models.policy), OwnedSequentialModel(&models.restoredPolicy)
	sourceStats, restoredStats: PPOStackNormStats
	setup = PPOStackNormStatsInit(&sourceStats, 1, 1, true) && PPOStackNormStatsInit(&restoredStats, 1, 1, false)
	testing.expect(t, setup)
	if !setup { return }
	exported, scratch: [4096]u8
	size, saved := PPOPolicyExportWrite(policy, &sourceStats.observation, exported[:], scratch[:])
	testing.expect(t, saved)
	if !saved { return }
	loaded: bool
	{
		context.allocator = mem.nil_allocator()
		loaded = PPOPolicyExportRead(restoredPolicy, exported[:size], &restoredStats.observation)
	}
	testing.expect(t, loaded && PPOStackTestParametersEqual(policy, restoredPolicy) &&
		PPOStackNormEqual(&sourceStats.observation, &restoredStats.observation))
	if !loaded { return }
	observation := [1]f32{2}
	sourceInput, restoredInput: [1]f32
	legal := [2]bool{true, true}
	setup = data.RunningStandardizerTransform(&sourceStats.observation, observation[:], sourceInput[:]) &&
		data.RunningStandardizerTransform(&restoredStats.observation, observation[:], restoredInput[:])
	action, log, actionOk := SequentialPolicyAction(policy, sourceInput[:], legal[:], .Greedy)
	restoredAction, restoredLog, restoredOk := SequentialPolicyAction(restoredPolicy, restoredInput[:], legal[:], .Greedy)
	testing.expect(t, setup && actionOk && restoredOk && action == restoredAction && log == restoredLog)
	size, saved = PPOPolicyExportWrite(policy, nil, exported[:], scratch[:])
	testing.expect(t, saved && PPOPolicyExportRead(restoredPolicy, exported[:size], nil) && PPOStackTestParametersEqual(policy, restoredPolicy))
}

PPOStackNormWrap :: proc(base: []u8, normalizers: PPOTrainingNormalizers, output: []u8) -> (int, bool) {
	observationBytes, observationOk := PPOCheckpointNormalizerByteSize(normalizers.observation)
	rewardBytes, rewardOk := PPOCheckpointNormalizerByteSize(normalizers.reward)
	if !observationOk || !rewardOk || len(output) < 24+observationBytes+rewardBytes ||
		len(base) > len(output)-24-observationBytes-rewardBytes { return 0, false }
	offset := 0
	CheckpointPut64(output, &offset, PPO_NORMALIZED_CHECKPOINT_MAGIC)
	CheckpointPut64(output, &offset, PPO_NORMALIZED_CHECKPOINT_VERSION)
	CheckpointPut64(output, &offset, u64(len(base)))
	PPOCheckpointPutNormalizer(output, &offset, normalizers.observation)
	PPOCheckpointPutNormalizer(output, &offset, normalizers.reward)
	copy(output[offset:offset+len(base)], base)
	return offset+len(base), true
}

PPOStackNormWrapExport :: proc(model: []u8, normalizer: ^data.RunningStandardizer, output: []u8) -> (int, bool) {
	normalizerBytes, normalizerOk := PPOCheckpointNormalizerByteSize(normalizer)
	if !normalizerOk || len(output) < 24+normalizerBytes || len(model) > len(output)-24-normalizerBytes { return 0, false }
	offset := 0
	CheckpointPut64(output, &offset, POLICY_EXPORT_MAGIC)
	CheckpointPut64(output, &offset, POLICY_EXPORT_VERSION)
	CheckpointPut64(output, &offset, u64(len(model)))
	PPOCheckpointPutNormalizer(output, &offset, normalizer)
	copy(output[offset:offset+len(model)], model)
	return offset+len(model), true
}

PPOStackNormTarget :: struct {
	policy, value: Sequential(6, 4, 2),
	stats: PPOStackNormStats,
	adam: Adam,
}

PPOStackNormTargetInit :: proc(target: ^PPOStackNormTarget, observationWidth, rewardWidth: int) -> bool {
	return SequentialInit(&target.policy, 1, 101) && SequentialAddDense(&target.policy, 2) &&
		SequentialInit(&target.value, 1, 103) && SequentialAddDense(&target.value, 1) &&
		PPOStackNormStatsInit(&target.stats, observationWidth, rewardWidth, false)
}

// The old readers are retained only as small-model differential oracles.
PPOStackNormProbeRead :: proc(
	policy, value: ^Sequential(6, 4, 2), input: []u8, adam: ^Adam, normalizers: PPOTrainingNormalizers,
) -> (PPOTrainingState, PPOConfig, PPOFitConfig, SequentialOptimizer, bool) {
	offset := 0
	magic, magicOk := CheckpointGet64(input, &offset)
	version, versionOk := CheckpointGet64(input, &offset)
	baseSize, sizeOk := CheckpointGet64(input, &offset)
	if !magicOk || !versionOk || !sizeOk || magic != PPO_NORMALIZED_CHECKPOINT_MAGIC ||
		version != PPO_NORMALIZED_CHECKPOINT_VERSION || baseSize > u64(max(int)) { return {}, {}, {}, nil, false }
	observation, observationOk := PPOCheckpointGetNormalizer(input, &offset)
	reward, rewardOk := PPOCheckpointGetNormalizer(input, &offset)
	if !observationOk || !rewardOk || !PPOCheckpointNormalizerTargetValid(observation, normalizers.observation) ||
		!PPOCheckpointNormalizerTargetValid(reward, normalizers.reward) || baseSize != u64(len(input)-offset) ||
		!PPOCheckpointNormalizedReadDisjoint(input, rawptr(policy), size_of(Sequential(6, 4, 2)),
			rawptr(value), size_of(Sequential(6, 4, 2)), adam, nil, nil, nil, normalizers) {
		return {}, {}, {}, nil, false
	}
	base := input[offset:]
	policyInput, valueInput, peekOk := PPOCheckpointPeekModelPayloads(base)
	if !peekOk { return {}, {}, {}, nil, false }
	policyProbe, valueProbe: Sequential(6, 4, 2)
	probeState: u64
	if !CheckpointRead(&policyProbe, nil, &probeState, policyInput, nil, nil, nil) ||
		!CheckpointRead(&valueProbe, nil, &probeState, valueInput, nil, nil, nil) ||
		observation.present && observation.width != policyProbe.inputWidth || reward.present && reward.width != 1 {
		return {}, {}, {}, nil, false
	}
	state, config, fit, optimizer, ok := PPOCheckpointRead(policy, value, base, adam, nil, nil, nil)
	if !ok { return {}, {}, {}, nil, false }
	PPOCheckpointApplyNormalizer(input, observation, normalizers.observation)
	PPOCheckpointApplyNormalizer(input, reward, normalizers.reward)
	return state, config, fit, optimizer, true
}

PPOStackNormProbeExport :: proc(policy: ^Sequential(6, 4, 2), input: []u8, normalizer: ^data.RunningStandardizer) -> bool {
	offset := 0
	magic, magicOk := CheckpointGet64(input, &offset)
	version, versionOk := CheckpointGet64(input, &offset)
	modelSize, sizeOk := CheckpointGet64(input, &offset)
	if !magicOk || !versionOk || !sizeOk || magic != POLICY_EXPORT_MAGIC ||
		version != POLICY_EXPORT_VERSION || modelSize > u64(max(int)) { return false }
	descriptor, descriptorOk := PPOCheckpointGetNormalizer(input, &offset)
	if !descriptorOk || !PPOCheckpointNormalizerTargetValid(descriptor, normalizer) || modelSize != u64(len(input)-offset) { return false }
	inputRange, inputOk := PPOCheckpointRange(rawptr(raw_data(input)), len(input), size_of(u8))
	modelRange, modelOk := PPOCheckpointRange(rawptr(policy), 1, size_of(Sequential(6, 4, 2)))
	if !inputOk || !modelOk || PPOFitMemoryRangesOverlap(inputRange, modelRange) { return false }
	ranges: [6]PPOFitMemoryRange
	count := 0
	ranges[count] = inputRange; count += 1
	ranges[count] = modelRange; count += 1
	if !PPOCheckpointAppendNormalizerRanges(ranges[:], &count, normalizer) || !PPOCheckpointRangesDisjoint(ranges[:count]) { return false }
	modelInput := input[offset:]
	probe: Sequential(6, 4, 2)
	state: u64
	if !CheckpointRead(&probe, nil, &state, modelInput, nil, nil, nil) || !PPOPolicyExportModelValid(&probe) ||
		descriptor.present && descriptor.width != probe.inputWidth { return false }
	if !CheckpointRead(policy, nil, &state, modelInput, nil, nil, nil) { return false }
	PPOCheckpointApplyNormalizer(input, descriptor, normalizer)
	return true
}

// Produces valid supervised payloads, including intentionally PPO-invalid topologies.
PPOStackNormModelPayloads :: proc(mode: int, policyData, valueData: []u8) -> (int, int, bool) {
	policy, value: Sequential(6, 4, 2)
	setup := SequentialInit(&policy, 1, 7) && SequentialInit(&value, 1, 11)
	if mode == 3 || mode == 4 { setup = setup && SequentialInitSpatial(&policy, 1, 1, 1, 7) }
	if mode == 11 || mode == 12 { setup = setup && SequentialInitSpatial(&value, 1, 1, 1, 11) }
	if mode == 10 { setup = setup && SequentialInit(&value, 2, 11) }
	switch mode {
	case 3, 4:
		setup = setup && SequentialAddConv2D(&policy, 1, 1, 2)
		if mode == 4 { setup = setup && SequentialAddFlatten(&policy) }
	case 8: setup = setup && SequentialAddFlatten(&policy)
	case: setup = setup && SequentialAddDense(&policy, 2)
	}
	switch mode {
	case 1: setup = setup && SequentialAddActivation(&policy, .Softmax)
	case 2: setup = setup && SequentialAddActivation(&policy, .Softmax) && SequentialAddDropout(&policy) && SequentialAddFlatten(&policy)
	case 5: setup = setup && SequentialAddActivation(&policy, .Softmax) && SequentialAddFlatten(&policy) && SequentialAddActivation(&policy, .Tanh) && SequentialAddDropout(&policy)
	case 6: setup = setup && SequentialAddActivation(&policy, .Softmax) && SequentialAddDense(&policy, 2)
	}
	switch mode {
	case 7: setup = setup && SequentialAddFlatten(&value)
	case 9: setup = setup && SequentialAddDense(&value, 2)
	case 11, 12:
		setup = setup && SequentialAddConv2D(&value, 1, 1, 1)
		if mode == 12 { setup = setup && SequentialAddFlatten(&value) }
	case: setup = setup && SequentialAddDense(&value, 1)
	}
	if !setup { return 0, 0, false }
	adam: Adam
	parameters: [12]^core.Node
	first, second: [32]f32
	policyAdam, valueAdam: ^Adam
	if mode == 13 || mode == 37 {
		model := &policy
		if mode == 37 { model = &value }
		list, listOk := SequentialParameters(model, parameters[:])
		_, elements, requirementsOk := SequentialAdamRequirements(model)
		if !listOk || !requirementsOk || !AdamInit(&adam, list, first[:elements], second[:elements]) { return 0, 0, false }
		if mode == 13 { policyAdam = &adam } else { valueAdam = &adam }
	}
	policySize, policyOk := CheckpointWrite(&policy, policyAdam, 0, policyData)
	valueSize, valueOk := CheckpointWrite(&value, valueAdam, 0, valueData)
	if !policyOk || !valueOk { return 0, 0, false }
	position := 0
	switch mode {
	case 14: position = 16; CheckpointPut64(policyData, &position, 5)
	case 15: position = 24; CheckpointPut64(valueData, &position, 3)
	case 16: policyData[0] ~= 0xff
	case 17: valueData[0] ~= 0xff
	case 18: position = 80; CheckpointPut64(policyData, &position, 99)
	}
	return policySize, valueSize, true
}

@(test)
NormalizationCheckpointStackProbeDifferential :: proc(t: ^testing.T) {
	for mode in 0..<40 {
		policyData, valueData, base, checkpoint: [4096]u8
		policySize, valueSize, built := PPOStackNormModelPayloads(mode, policyData[:], valueData[:])
		baseSize, assembled := PPOStackTestSGDEnvelope(policyData[:policySize], valueData[:valueSize], base[:])
		observationWidth, rewardWidth := 1, 1
		if mode == 19 { observationWidth = 2 }
		if mode == 20 { rewardWidth = 2 }
		sourceStats: PPOStackNormStats
		setup := PPOStackNormStatsInit(&sourceStats, observationWidth, rewardWidth, mode != 38)
		sourceNormalizers := PPOTrainingNormalizers{&sourceStats.observation, &sourceStats.reward}
		if mode == 24 || mode == 25 || mode == 35 { sourceNormalizers.observation = nil }
		if mode == 24 || mode == 26 || mode == 36 { sourceNormalizers.reward = nil }
		size, wrapped := PPOStackNormWrap(base[:baseSize], sourceNormalizers, checkpoint[:])
		testing.expectf(t, built && assembled && setup && wrapped, "normalized case %d setup", mode)
		if !built || !assembled || !setup || !wrapped { return }
		offset := 24
		observationDescriptor, observationOk := PPOCheckpointGetNormalizer(checkpoint[:size], &offset)
		rewardDescriptor, rewardOk := PPOCheckpointGetNormalizer(checkpoint[:size], &offset)
		testing.expect(t, observationOk && rewardOk)
		if !observationOk || !rewardOk { return }
		position := 0
		switch mode {
		case 27: position = observationDescriptor.meanOffset; PPOCheckpointPutF64(checkpoint[:], &position, math.nan_f64())
		case 28: position = rewardDescriptor.m2Offset; PPOCheckpointPutF64(checkpoint[:], &position, -1)
		case 29: position = 32; CheckpointPut64(checkpoint[:], &position, 0)
		case 32: checkpoint[size] = 0xa5; size += 1
		}
		expectedTarget, actualTarget: PPOStackNormTarget
		setup = PPOStackNormTargetInit(&expectedTarget, observationWidth, rewardWidth) && PPOStackNormTargetInit(&actualTarget, observationWidth, rewardWidth)
		testing.expect(t, setup)
		if !setup { return }
		expectedNormalizers := PPOTrainingNormalizers{&expectedTarget.stats.observation, &expectedTarget.stats.reward}
		actualNormalizers := PPOTrainingNormalizers{&actualTarget.stats.observation, &actualTarget.stats.reward}
		if mode == 24 || mode == 25 || mode == 22 { expectedNormalizers.observation, actualNormalizers.observation = nil, nil }
		if mode == 24 || mode == 26 || mode == 23 { expectedNormalizers.reward, actualNormalizers.reward = nil, nil }
		if mode == 21 { expectedNormalizers.reward, actualNormalizers.reward = expectedNormalizers.observation, actualNormalizers.observation }
		if mode == 30 { expectedTarget.stats.observation.epsilon, actualTarget.stats.observation.epsilon = 0, 0 }
		if mode == 39 { expectedTarget.stats.observationMean[0], actualTarget.stats.observationMean[0] = 1, 1 }
		expectedAdam, actualAdam: ^Adam
		if mode == 31 { expectedAdam, actualAdam = &expectedTarget.adam, &actualTarget.adam }
		expectedPolicy, actualPolicy := &expectedTarget.policy, &actualTarget.policy
		expectedValue, actualValue := &expectedTarget.value, &actualTarget.value
		if mode == 33 { expectedPolicy, actualPolicy = nil, nil }
		if mode == 34 { expectedValue, actualValue = nil, nil }
		expectedBefore, actualBefore: [size_of(PPOStackNormTarget)]u8
		copy(expectedBefore[:], mem.slice_ptr((^u8)(rawptr(&expectedTarget)), len(expectedBefore)))
		copy(actualBefore[:], mem.slice_ptr((^u8)(rawptr(&actualTarget)), len(actualBefore)))
		inputBefore := checkpoint
		expectedState, expectedConfig, expectedFit, _, expected := PPOStackNormProbeRead(
			expectedPolicy, expectedValue, checkpoint[:size], expectedAdam, expectedNormalizers,
		)
		actualState, actualConfig, actualFit, _, actual := PPOCheckpointReadNormalized(
			actualPolicy, actualValue, checkpoint[:size], actualAdam, nil, nil, nil, actualNormalizers,
		)
		shouldAccept := mode == 0 || mode == 4 || mode == 5 || mode == 6 || mode == 12 || mode == 24 || mode == 25 || mode == 26 || mode == 38
		testing.expectf(t, expected == shouldAccept && actual == expected && checkpoint == inputBefore,
			"normalized case %d: new %v, probe %v", mode, actual, expected)
		if actual && expected {
			testing.expectf(t, actualState == expectedState && actualConfig == expectedConfig && actualFit == expectedFit &&
				PPOStackTestParametersEqual(&expectedTarget.policy, &actualTarget.policy) &&
				PPOStackTestParametersEqual(&expectedTarget.value, &actualTarget.value) &&
				PPOStackNormEqual(&expectedTarget.stats.observation, &actualTarget.stats.observation) &&
				PPOStackNormEqual(&expectedTarget.stats.reward, &actualTarget.stats.reward), "normalized case %d restored state", mode)
		} else if !actual && !expected {
			testing.expectf(t, PPOStackTestBytesEqual(rawptr(&expectedTarget), expectedBefore[:]) &&
				PPOStackTestBytesEqual(rawptr(&actualTarget), actualBefore[:]), "normalized case %d mutated destinations", mode)
		}
	}
}

@(test)
PolicyExportStackProbeDifferential :: proc(t: ^testing.T) {
	cases := [22]int{0, 1, 2, 3, 4, 5, 6, 8, 13, 14, 16, 18, 19, 22, 24, 27, 30, 32, 33, 35, 38, 39}
	for mode in cases {
		policyData, valueData, exported: [4096]u8
		policySize, _, built := PPOStackNormModelPayloads(mode, policyData[:], valueData[:])
		observationWidth := 1
		if mode == 19 { observationWidth = 2 }
		sourceStats: PPOStackNormStats
		setup := PPOStackNormStatsInit(&sourceStats, observationWidth, 1, mode != 38)
		sourceNormalizer := &sourceStats.observation
		if mode == 24 || mode == 35 { sourceNormalizer = nil }
		size, wrapped := PPOStackNormWrapExport(policyData[:policySize], sourceNormalizer, exported[:])
		testing.expectf(t, built && setup && wrapped, "export case %d setup", mode)
		if !built || !setup || !wrapped { return }
		offset := 24
		descriptor, descriptorOk := PPOCheckpointGetNormalizer(exported[:size], &offset)
		testing.expect(t, descriptorOk)
		if !descriptorOk { return }
		if mode == 27 { position := descriptor.meanOffset; PPOCheckpointPutF64(exported[:], &position, math.nan_f64()) }
		if mode == 32 { exported[size] = 0xa5; size += 1 }
		expectedTarget, actualTarget: PPOStackNormTarget
		setup = PPOStackNormTargetInit(&expectedTarget, observationWidth, 1) && PPOStackNormTargetInit(&actualTarget, observationWidth, 1)
		testing.expect(t, setup)
		if !setup { return }
		expectedNormalizer, actualNormalizer := &expectedTarget.stats.observation, &actualTarget.stats.observation
		if mode == 22 || mode == 24 { expectedNormalizer, actualNormalizer = nil, nil }
		if mode == 30 { expectedTarget.stats.observation.epsilon, actualTarget.stats.observation.epsilon = 0, 0 }
		if mode == 39 { expectedTarget.stats.observationMean[0], actualTarget.stats.observationMean[0] = 1, 1 }
		expectedPolicy, actualPolicy := &expectedTarget.policy, &actualTarget.policy
		if mode == 33 { expectedPolicy, actualPolicy = nil, nil }
		expectedBefore, actualBefore: [size_of(PPOStackNormTarget)]u8
		copy(expectedBefore[:], mem.slice_ptr((^u8)(rawptr(&expectedTarget)), len(expectedBefore)))
		copy(actualBefore[:], mem.slice_ptr((^u8)(rawptr(&actualTarget)), len(actualBefore)))
		inputBefore := exported
		expected := PPOStackNormProbeExport(expectedPolicy, exported[:size], expectedNormalizer)
		actual := PPOPolicyExportRead(actualPolicy, exported[:size], actualNormalizer)
		shouldAccept := mode == 0 || mode == 4 || mode == 5 || mode == 6 || mode == 24 || mode == 38
		testing.expectf(t, expected == shouldAccept && actual == expected && exported == inputBefore,
			"export case %d: new %v, probe %v", mode, actual, expected)
		if actual && expected {
			testing.expectf(t, PPOStackTestParametersEqual(&expectedTarget.policy, &actualTarget.policy) &&
				PPOStackNormEqual(&expectedTarget.stats.observation, &actualTarget.stats.observation), "export case %d restored state", mode)
		} else if !actual && !expected {
			testing.expectf(t, PPOStackTestBytesEqual(rawptr(&expectedTarget), expectedBefore[:]) &&
				PPOStackTestBytesEqual(rawptr(&actualTarget), actualBefore[:]), "export case %d mutated destinations", mode)
		}
	}
}

PPOStackNormAdamTarget :: struct {
	policy, value: Sequential(2, 3, 2),
	stats: PPOStackNormStats,
	adam: Adam,
	parameters: [4]^core.Node,
	firstBacking, secondBacking: [3]u64,
}

PPOStackNormAdamTargetInit :: proc(target: ^PPOStackNormAdamTarget) -> bool {
	return SequentialInit(&target.policy, 1, 101) && SequentialAddDense(&target.policy, 2) &&
		SequentialInit(&target.value, 1, 103) && SequentialAddDense(&target.value, 1) &&
		PPOStackNormStatsInit(&target.stats, 1, 1, false)
}

@(test)
NormalizationCheckpointStackAdamFailuresAreAtomic :: proc(t: ^testing.T) {
	policy, value: Sequential(2, 3, 2)
	owner: PPOOwnedAdam
	defer PPOOwnedAdamDestroy(&owner)
	sourceStats: PPOStackNormStats
	setup := SequentialInit(&policy, 1, 7) && SequentialAddDense(&policy, 2) &&
		SequentialInit(&value, 1, 11) && SequentialAddDense(&value, 1) &&
		PPOOwnedAdamInit(&owner, &policy, &value) && PPOStackNormStatsInit(&sourceStats, 1, 1, true)
	testing.expect(t, setup)
	if !setup { return }
	checkpoint, baseScratch, policyScratch, valueScratch: [4096]u8
	size, saved := PPOCheckpointWriteNormalized(&policy, &value, PPOOwnedAdamOptimizer(&owner),
		PPOTrainingState{policyRandomState = 17, shuffleRandomState = 0}, PPOConfig{0.2, 0.01, 0.5, 1},
		PPOFitConfig{epochs = 1, batchSize = 1}, {&sourceStats.observation, &sourceStats.reward},
		checkpoint[:], baseScratch[:], policyScratch[:], valueScratch[:])
	testing.expect(t, saved)
	if !saved { return }
	baseOffset := 24
	_, observationOk := PPOCheckpointGetNormalizer(checkpoint[:size], &baseOffset)
	rewardDescriptor, rewardOk := PPOCheckpointGetNormalizer(checkpoint[:size], &baseOffset)
	policyInput, valueInput, peekOk := PPOCheckpointPeekModelPayloads(checkpoint[baseOffset:size])
	testing.expect(t, observationOk && rewardOk && peekOk)
	if !observationOk || !rewardOk || !peekOk { return }
	policyOffset := int(uintptr(rawptr(raw_data(policyInput)))-uintptr(rawptr(raw_data(checkpoint[:]))))
	valueOffset := int(uintptr(rawptr(raw_data(valueInput)))-uintptr(rawptr(raw_data(checkpoint[:]))))
	for mode in 0..<20 {
		target: PPOStackNormAdamTarget
		setup = PPOStackNormAdamTargetInit(&target)
		testing.expect(t, setup)
		if !setup { return }
		target.adam.step = 99
		candidateWords: [512]u64
		candidate := mem.slice_ptr((^u8)(rawptr(&candidateWords[0])), size_of(candidateWords))
		copy(candidate, checkpoint[:])
		inputSize := size
		input := candidate[:inputSize]
		parameters := target.parameters[:]
		first := mem.slice_ptr((^f32)(rawptr(&target.firstBacking[0])), 6)
		second := mem.slice_ptr((^f32)(rawptr(&target.secondBacking[0])), 6)
		normalizers := PPOTrainingNormalizers{&target.stats.observation, &target.stats.reward}
		position := 0
		switch mode {
		case 0: inputSize -= 1
		case 1: position = 48; PPOCheckpointPutF64(candidate, &position, 0)
		case 2: candidate[policyOffset] ~= 0xff
		case 3: candidate[valueOffset] ~= 0xff
		case 4: position = baseOffset+120; CheckpointPut32(candidate, &position, 0)
		case 5: position = baseOffset+144; CheckpointPut32(candidate, &position, math.nan_f32())
		case 6: position = baseOffset+144+6*4; CheckpointPut32(candidate, &position, -1)
		case 7: parameters = parameters[:3]
		case 8: first = first[:5]
		case 9: second = second[:5]
		case 10: parameters = mem.slice_ptr((^^core.Node)(rawptr(raw_data(candidate))), 4)
		case 11:
			target.stats.observation.mean = mem.slice_ptr((^f64)(rawptr(uintptr(rawptr(raw_data(candidate)))+uintptr(baseOffset+56))), 1)
			testing.expect(t, data.RunningStandardizerValid(&target.stats.observation))
		case 12: normalizers.reward = normalizers.observation
		case 13:
			target.stats.observation.mean = mem.slice_ptr((^f64)(rawptr(&target.firstBacking[0])), 1)
			testing.expect(t, data.RunningStandardizerValid(&target.stats.observation))
		case 14: position = rewardDescriptor.m2Offset; PPOCheckpointPutF64(candidate, &position, -1)
		case 15: position = policyOffset+80; CheckpointPut64(candidate, &position, 99)
		case 16: position = 32; CheckpointPut64(candidate, &position, 0)
		case 17:
			target.stats.observation.mean = mem.slice_ptr((^f64)(rawptr(&target.policy.inputData[0])), 1)
			testing.expect(t, data.RunningStandardizerValid(&target.stats.observation))
		case 18: second = first
		case 19:
			input = mem.slice_ptr((^u8)(rawptr(&target.policy)), inputSize)
			copy(input, checkpoint[:inputSize])
		}
		if mode != 19 { input = candidate[:inputSize] }
		targetBefore: [size_of(PPOStackNormAdamTarget)]u8
		copy(targetBefore[:], mem.slice_ptr((^u8)(rawptr(&target)), len(targetBefore)))
		candidateBefore := candidateWords
		state, config, fit, optimizer, loaded := PPOCheckpointReadNormalized(
			&target.policy, &target.value, input, &target.adam, parameters, first, second, normalizers,
		)
		testing.expectf(t, !loaded && state == (PPOTrainingState{}) && config == (PPOConfig{}) && fit == (PPOFitConfig{}) && optimizer == nil &&
			PPOStackTestBytesEqual(rawptr(&target), targetBefore[:]) && candidateWords == candidateBefore,
			"normalized Adam atomic failure %d", mode)
	}
}

@(test)
PolicyExportStackAliasesAreAtomic :: proc(t: ^testing.T) {
	policy: Sequential(2, 3, 2)
	sourceStats: PPOStackNormStats
	setup := SequentialInit(&policy, 1, 7) && SequentialAddDense(&policy, 2) && PPOStackNormStatsInit(&sourceStats, 1, 1, true)
	testing.expect(t, setup)
	if !setup { return }
	exported, scratch: [4096]u8
	size, saved := PPOPolicyExportWrite(&policy, &sourceStats.observation, exported[:], scratch[:])
	testing.expect(t, saved)
	if !saved { return }
	offset := 24
	descriptor, descriptorOk := PPOCheckpointGetNormalizer(exported[:size], &offset)
	testing.expect(t, descriptorOk)
	if !descriptorOk { return }
	for mode in 0..<6 {
		target: PPOStackNormAdamTarget
		setup = PPOStackNormAdamTargetInit(&target)
		testing.expect(t, setup)
		if !setup { return }
		candidateWords: [512]u64
		candidate := mem.slice_ptr((^u8)(rawptr(&candidateWords[0])), size_of(candidateWords))
		copy(candidate, exported[:])
		input := candidate[:size]
		normalizer := &target.stats.observation
		switch mode {
		case 0:
			input = mem.slice_ptr((^u8)(rawptr(&target.policy)), size)
			copy(input, exported[:size])
		case 1:
			target.stats.observation.mean = mem.slice_ptr((^f64)(rawptr(uintptr(rawptr(raw_data(candidate)))+uintptr(descriptor.meanOffset))), 1)
			target.stats.observation.count = 1
			testing.expect(t, data.RunningStandardizerValid(normalizer))
		case 2:
			target.stats.observation.mean = mem.slice_ptr((^f64)(rawptr(&target.policy.inputData[0])), 1)
			testing.expect(t, data.RunningStandardizerValid(normalizer))
		case 3: normalizer = nil
		case 4: position := descriptor.meanOffset; PPOCheckpointPutF64(candidate, &position, math.nan_f64())
		case 5: position := offset+16; CheckpointPut64(candidate, &position, 1)
		}
		targetBefore: [size_of(PPOStackNormAdamTarget)]u8
		copy(targetBefore[:], mem.slice_ptr((^u8)(rawptr(&target)), len(targetBefore)))
		candidateBefore := candidateWords
		loaded := PPOPolicyExportRead(&target.policy, input, normalizer)
		testing.expectf(t, !loaded && PPOStackTestBytesEqual(rawptr(&target), targetBefore[:]) && candidateWords == candidateBefore,
			"export atomic failure %d", mode)
	}
}

@(test)
NormalizationCheckpointStackDifferentialBytes :: proc(t: ^testing.T) {
	policyData, valueData, base, normalized, exported: [4096]u8
	policySize, valueSize, built := PPOStackNormModelPayloads(0, policyData[:], valueData[:])
	baseSize, assembled := PPOStackTestSGDEnvelope(policyData[:policySize], valueData[:valueSize], base[:])
	sourceStats: PPOStackNormStats
	setup := PPOStackNormStatsInit(&sourceStats, 1, 1, true)
	normalizedSize, wrapped := PPOStackNormWrap(base[:baseSize], {&sourceStats.observation, &sourceStats.reward}, normalized[:])
	exportedSize, exportedOk := PPOStackNormWrapExport(policyData[:policySize], &sourceStats.observation, exported[:])
	testing.expect(t, built && assembled && setup && wrapped && exportedOk)
	if !built || !assembled || !setup || !wrapped || !exportedOk { return }
	accepted, rejected := 0, 0
	for format in 0..<2 {
		input := normalized[:normalizedSize]
		if format == 1 { input = exported[:exportedSize] }
		for index in 0..<len(input) {
			for bit in 0..<8 {
				mask := u8(1 << uint(bit))
				input[index] ~= mask
				expectedTarget, actualTarget: PPOStackNormTarget
				setup = PPOStackNormTargetInit(&expectedTarget, 1, 1) && PPOStackNormTargetInit(&actualTarget, 1, 1)
				if !setup { testing.expect(t, false); return }
				expectedBefore, actualBefore: [size_of(PPOStackNormTarget)]u8
				copy(expectedBefore[:], mem.slice_ptr((^u8)(rawptr(&expectedTarget)), len(expectedBefore)))
				copy(actualBefore[:], mem.slice_ptr((^u8)(rawptr(&actualTarget)), len(actualBefore)))
				inputBefore: [4096]u8
				copy(inputBefore[:], input)
				expected, actual: bool
				if format == 0 {
					_, _, _, _, expected = PPOStackNormProbeRead(&expectedTarget.policy, &expectedTarget.value, input, nil,
						{&expectedTarget.stats.observation, &expectedTarget.stats.reward})
					_, _, _, _, actual = PPOCheckpointReadNormalized(&actualTarget.policy, &actualTarget.value, input, nil, nil, nil, nil,
						{&actualTarget.stats.observation, &actualTarget.stats.reward})
				} else {
					expected = PPOStackNormProbeExport(&expectedTarget.policy, input, &expectedTarget.stats.observation)
					actual = PPOPolicyExportRead(&actualTarget.policy, input, &actualTarget.stats.observation)
				}
				if actual { accepted += 1 } else { rejected += 1 }
				valid := actual == expected && PPOStackTestBytesEqual(rawptr(raw_data(input)), inputBefore[:len(input)])
				if actual && expected {
					valid = valid && PPOStackTestParametersEqual(&expectedTarget.policy, &actualTarget.policy) &&
						PPOStackTestParametersEqual(&expectedTarget.value, &actualTarget.value) &&
						PPOStackNormEqual(&expectedTarget.stats.observation, &actualTarget.stats.observation) &&
						PPOStackNormEqual(&expectedTarget.stats.reward, &actualTarget.stats.reward)
				} else if !actual && !expected {
					valid = valid && PPOStackTestBytesEqual(rawptr(&expectedTarget), expectedBefore[:]) &&
						PPOStackTestBytesEqual(rawptr(&actualTarget), actualBefore[:])
				}
				if !valid {
					testing.expectf(t, false, "format %d byte %d bit %d: new %v, probe %v", format, index, bit, actual, expected)
					return
				}
				input[index] ~= mask
			}
		}
	}
	testing.expect(t, accepted > 0 && rejected > 0)
}
