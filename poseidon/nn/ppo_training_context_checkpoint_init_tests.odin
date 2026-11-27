package nn

import "../core"
import "../data"
import "../rl"
import "core:mem"
import "core:testing"

PPOCheckpointInitTestDestinations :: struct {
	policy, value: Sequential(2, 3, 2),
	observation, reward: data.RunningStandardizer,
	observationMean, observationM2: [2]f64,
	rewardMean, rewardM2: [1]f64,
}

PPOCheckpointInitTestTarget :: struct {
	trainer: PPOTrainingContext(2, 3, 2, 2, 3, 2),
	dest: PPOCheckpointInitTestDestinations,
}

ppoCheckpointInitTestTargetInit :: proc(target: ^PPOCheckpointInitTestTarget) -> bool {
	d := &target.dest
	obs := [4]f32{9, 3, 5, 7}
	rewards := [2]f32{4, 8}
	return data.RunningStandardizerInit(&d.observation, d.observationMean[:], d.observationM2[:], 0.1) &&
		data.RunningStandardizerInit(&d.reward, d.rewardMean[:], d.rewardM2[:], 0.2) &&
		data.RunningStandardizerUpdate(&d.observation, obs[:]) && data.RunningStandardizerUpdate(&d.reward, rewards[:])
}

ppoCheckpointInitTestNormalizers :: proc(target: ^PPOCheckpointInitTestTarget) -> PPOTrainingNormalizers {
	return {&target.dest.observation, &target.dest.reward}
}

ppoCheckpointInitTestCall :: proc(
	target: ^PPOCheckpointInitTestTarget, input: []u8, normalized: bool,
	allocator: mem.Allocator, normalizers: PPOTrainingNormalizers,
	baseLimits: PPOCheckpointInspectLimits = {}, normalizedLimits: PPONormalizedCheckpointInspectLimits = {},
	maxOwnedBytes: int = 0, rolloutCapacity: int = 5,
) -> PPOTrainingContextError {
	if normalized {
		return PPOTrainingContextCheckpointInitNormalized(&target.trainer, &target.dest.policy, &target.dest.value,
			input, normalizers, rolloutCapacity, normalizedLimits, maxOwnedBytes, allocator)
	}
	return PPOTrainingContextCheckpointInit(&target.trainer, &target.dest.policy, &target.dest.value,
		input, rolloutCapacity, baseLimits, maxOwnedBytes, allocator)
}

// Check the complete destination and input bytes, including unused model storage.
ppoCheckpointInitTestReject :: proc(
	t: ^testing.T, label: string, target: ^PPOCheckpointInitTestTarget, input: []u8, normalized: bool,
	expected: PPOTrainingContextError, normalizers: PPOTrainingNormalizers,
	baseLimits: PPOCheckpointInspectLimits = {}, normalizedLimits: PPONormalizedCheckpointInspectLimits = {},
	maxOwnedBytes: int = 0, rolloutCapacity: int = 5,
) -> bool {
	before: [size_of(PPOCheckpointInitTestTarget)]u8
	inputBefore: [4096]u8
	if len(input) > len(inputBefore) { testing.expectf(t, false, "%s: fixture too large", label); return false }
	copy(before[:], mem.slice_ptr((^u8)(rawptr(target)), len(before)))
	copy(inputBefore[:], input)
	state := PPOContextTestAllocator{backing = context.allocator}
	allocator := mem.Allocator{procedure = PPOContextTestAllocatorProc, data = rawptr(&state)}
	result := ppoCheckpointInitTestCall(target, input, normalized, allocator, normalizers, baseLimits, normalizedLimits, maxOwnedBytes, rolloutCapacity)
	unchanged := PPOContextTestBytesEqual(rawptr(target), before[:]) &&
		PPOContextTestBytesEqual(rawptr(raw_data(input)), inputBefore[:len(input)])
	testing.expectf(t, result == expected && unchanged && state.attempts == 0,
		"%s: got %v, expected %v, unchanged=%v allocation attempts=%d", label, result, expected, unchanged, state.attempts)
	if result == .None { _ = PPOTrainingContextDestroy(&target.trainer) }
	return result == expected && unchanged && state.attempts == 0
}

ppoCheckpointInitTestNormalizersEqual :: proc(a, b: ^data.RunningStandardizer) -> bool {
	if a == nil || b == nil || a.count != b.count || a.epsilon != b.epsilon || a.frozen != b.frozen ||
		len(a.mean) != len(b.mean) || len(a.m2) != len(b.m2) { return false }
	for item, i in a.mean { if item != b.mean[i] || a.m2[i] != b.m2[i] { return false } }
	return true
}

@(test)
PPOCheckpointInitFrozenEmptyWriterRoundTrip :: proc(t: ^testing.T) {
	policy, value: Sequential(2, 3, 2)
	observationMean, observationM2: [2]f64
	rewardMean, rewardM2: [1]f64
	observation, reward: data.RunningStandardizer
	setup := SequentialInit(&policy, 2, 17) && SequentialAddDense(&policy, 2) &&
		SequentialInit(&value, 2, 29) && SequentialAddDense(&value, 1) &&
		data.RunningStandardizerInit(&observation, observationMean[:], observationM2[:], 0.02) &&
		data.RunningStandardizerInit(&reward, rewardMean[:], rewardM2[:], 0.03) &&
		data.RunningStandardizerSetMetadata(&observation, 0, 0.02, true) &&
		data.RunningStandardizerSetMetadata(&reward, 0, 0.03, true)
	parameters: [4]^core.Node
	first, second: [9]f32
	adam: Adam
	list, elements, parametersOk := PPOCheckpointCombinedParameters(&policy, &value, parameters[:])
	setup = setup && parametersOk && elements == 9 && AdamInit(&adam, list, first[:], second[:], learningRate = 0.01)
	// Negative zero is valid for empty moments and should retain its bits.
	observationMean[1] = transmute(f64)u64(0x8000000000000000)
	rewardM2[0] = transmute(f64)u64(0x8000000000000000)
	testing.expect(t, setup && data.RunningStandardizerValid(&observation) && data.RunningStandardizerValid(&reward))
	if !setup { return }
	adam.step = 7
	for &item, i in first { item = f32(i)-2 }
	for &item, i in second { item = f32(i)/2 }
	state := PPOTrainingState{5, 8, 17, 23}
	objective := PPOConfig{0.2, 0.01, 0.5, 1.5}
	fit := PPOFitConfig{epochs = 3, batchSize = 2, maxGradientNorm = 0.5, finalLearningRate = 0.001}
	checkpoint, baseScratch, policyScratch, valueScratch, exported, exportScratch: [4096]u8
	size, saved := PPOCheckpointWriteNormalized(&policy, &value, &adam, state, objective, fit, {&observation, &reward},
		checkpoint[:], baseScratch[:], policyScratch[:], valueScratch[:])
	exportSize, exportedOk := PPOPolicyExportWrite(&policy, &observation, exported[:], exportScratch[:])
	testing.expect(t, saved && exportedOk)
	if !saved || !exportedOk { return }
	before, exportBefore := checkpoint, exported
	// Frozen empty exports still reject nonzero mean or M2 without mutation.
	for which in 0..<2 {
		badExport := exported
		position := 24+40
		if which == 1 { position += 16 }
		normalizedInspectTestPutF64(badExport[:], &position, 1)
		badBefore := badExport
		target: NormalizedInspectTestTarget
		testing.expect(t, normalizedInspectTestTargetInit(&target))
		targetBefore: [size_of(NormalizedInspectTestTarget)]u8
		copy(targetBefore[:], mem.slice_ptr((^u8)(rawptr(&target)), len(targetBefore)))
		badLoaded := PPOPolicyExportRead(&target.policy, badExport[:exportSize], &target.observation)
		testing.expect(t, !badLoaded && badExport == badBefore && normalizedInspectTestMemoryEqual(rawptr(&target), targetBefore[:]))
	}

	direct, owned: PPOCheckpointInitTestTarget
	setup = ppoCheckpointInitTestTargetInit(&direct) && ppoCheckpointInitTestTargetInit(&owned)
	exportPolicy: Sequential(2, 3, 2)
	exportMean, exportM2: [2]f64
	exportNormalizer: data.RunningStandardizer
	sampleObservation, sampleReward := [2]f32{3, 5}, [1]f32{7}
	setup = setup && data.RunningStandardizerInit(&exportNormalizer, exportMean[:], exportM2[:], 0.5) &&
		data.RunningStandardizerUpdate(&exportNormalizer, sampleObservation[:])
	testing.expect(t, setup)
	if !setup { return }
	restoredAdam: Adam
	restoredParameters: [4]^core.Node
	restoredFirst, restoredSecond: [9]f32
	info: PPONormalizedCheckpointInfo
	inspectError: CheckpointError
	restoredState: PPOTrainingState
	restoredObjective: PPOConfig
	restoredFit: PPOFitConfig
	restoredOptimizer: SequentialOptimizer
	loaded, exportLoaded: bool
	{
		context.allocator = mem.nil_allocator()
		info, inspectError = PPOCheckpointInspectNormalized(checkpoint[:size])
		restoredState, restoredObjective, restoredFit, restoredOptimizer, loaded = PPOCheckpointReadNormalized(
			&direct.dest.policy, &direct.dest.value, checkpoint[:size], &restoredAdam,
			restoredParameters[:], restoredFirst[:], restoredSecond[:], ppoCheckpointInitTestNormalizers(&direct),
		)
		exportLoaded = PPOPolicyExportRead(&exportPolicy, exported[:exportSize], &exportNormalizer)
	}
	testing.expect(t, inspectError.code == .None && info.observation == (PPOCheckpointNormalizerInfo{true, 0, 2, 0.02, true}) &&
		info.reward == (PPOCheckpointNormalizerInfo{true, 0, 1, 0.03, true}) && info.base.state == state && info.base.optimizer == .Adam &&
		loaded && exportLoaded && restoredState == state && restoredObjective == objective && restoredFit == fit &&
		restoredAdam.step == 7 && restoredFirst == first && restoredSecond == second && checkpoint == before && exported == exportBefore)
	if inspectError.code != .None || !loaded || !exportLoaded { return }
	_, isAdam := restoredOptimizer.(^Adam)
	testing.expect(t, isAdam)

	allocatorState := PPOContextTestAllocator{backing = context.allocator}
	allocator := mem.Allocator{procedure = PPOContextTestAllocatorProc, data = &allocatorState}
	result := PPOTrainingContextCheckpointInitNormalized(&owned.trainer, &owned.dest.policy, &owned.dest.value,
		checkpoint[:size], ppoCheckpointInitTestNormalizers(&owned), 5, allocator = allocator)
	testing.expect(t, result == .None && allocatorState.allocations == 4 && checkpoint == before)
	if result != .None { return }
	defer PPOTrainingContextDestroy(&owned.trainer)
	ownedState, ownedAdam := PPOTrainingContextState(&owned.trainer), PPOTrainingContextOptimizer(&owned.trainer)
	testing.expect(t, ownedState != nil && ownedAdam != nil)
	if ownedState == nil || ownedAdam == nil { return }
	testing.expect(t, ownedState^ == state && ownedAdam.step == 7 && len(ownedAdam.firstMoment) == 9 && len(ownedAdam.secondMoment) == 9)
	for item, i in first { testing.expect(t, ownedAdam.firstMoment[i] == item && ownedAdam.secondMoment[i] == second[i]) }

	// Re-encoding before unfreezing must preserve the complete checkpoint bytes.
	roundTrip: [4096]u8
	roundSize, roundOk := PPOCheckpointWriteNormalized(&owned.dest.policy, &owned.dest.value, ownedAdam, ownedState^, objective, fit,
		ppoCheckpointInitTestNormalizers(&owned), roundTrip[:], baseScratch[:], policyScratch[:], valueScratch[:])
	testing.expect(t, roundOk && roundSize == size && PPOContextTestBytesEqual(rawptr(raw_data(roundTrip[:size])), checkpoint[:size]))

	normalizers := [5]^data.RunningStandardizer{
		&direct.dest.observation, &direct.dest.reward, &exportNormalizer, &owned.dest.observation, &owned.dest.reward,
	}
	for normalizer, i in normalizers {
		sample := sampleObservation[:]
		epsilon: f64 = 0.02
		if i == 1 || i == 4 { sample = sampleReward[:]; epsilon = 0.03 }
		testing.expectf(t, data.RunningStandardizerValid(normalizer) && normalizer.count == 0 && normalizer.frozen &&
			normalizer.epsilon == epsilon, "frozen empty normalizer %d metadata", i)
		for mean, j in normalizer.mean { testing.expect(t, mean == 0 && normalizer.m2[j] == 0) }
		if i == 1 || i == 4 {
			testing.expect(t, transmute(u64)normalizer.m2[0] == 0x8000000000000000)
		} else {
			testing.expect(t, transmute(u64)normalizer.mean[1] == 0x8000000000000000)
		}
		output := [2]f32{11, 13}
		testing.expect(t, !data.RunningStandardizerUpdate(normalizer, sample) &&
			!data.RunningStandardizerTransform(normalizer, sample, output[:len(sample)]) && output == ([2]f32{11, 13}) &&
			normalizer.count == 0 && normalizer.frozen && data.RunningStandardizerUnfreeze(normalizer) &&
			data.RunningStandardizerUpdate(normalizer, sample) && normalizer.count == 1 && !normalizer.frozen && normalizer.epsilon == epsilon)
		for value, j in sample { testing.expect(t, normalizer.mean[j] == f64(value) && normalizer.m2[j] == 0) }
	}
	testing.expect(t, observation.count == 0 && observation.frozen && reward.count == 0 && reward.frozen &&
		observationMean == ([2]f64{}) && observationM2 == ([2]f64{}) && rewardMean == ([1]f64{}) && rewardM2 == ([1]f64{}) &&
		transmute(u64)observationMean[1] == 0x8000000000000000 && transmute(u64)rewardM2[0] == 0x8000000000000000)
	testing.expect(t, PPOTrainingContextDestroy(&owned.trainer) == .None && allocatorState.frees == 4 && allocatorState.badFrees == 0)
}

@(test)
PPOCheckpointInitRoundTripAndDeterministicFits :: proc(t: ^testing.T) {
	for normalized in ([2]bool{false, true}) {
		for layerless in ([2]bool{false, true}) {
			// Distinct policy/value capacities also exercise the default minibatch size.
			policy, restoredPolicy: Sequential(2, 3, 4)
			value, restoredValue: Sequential(1, 2, 3)
			source, restored: PPOTrainingContext(2, 3, 4, 1, 2, 3)
			setup := PPOContextTestSetup(&policy, &value)
			if layerless { setup = setup && SequentialInit(&restoredPolicy, 1, 7) && SequentialInit(&restoredValue, 2, 8) }
			obsMean, obsM2, restoredObsMean, restoredObsM2: [2]f64
			rewardMean, rewardM2, restoredRewardMean, restoredRewardM2: [1]f64
			observation, reward, restoredObservation, restoredReward: data.RunningStandardizer
			obsSamples, rewardSamples := [4]f32{1, 10, 3, 14}, [3]f32{-2, 0, 2}
			setup = setup && data.RunningStandardizerInit(&observation, obsMean[:], obsM2[:], 0.02) &&
				data.RunningStandardizerInit(&reward, rewardMean[:], rewardM2[:], 0.03) &&
				data.RunningStandardizerInit(&restoredObservation, restoredObsMean[:], restoredObsM2[:], 0.2) &&
				data.RunningStandardizerInit(&restoredReward, restoredRewardMean[:], restoredRewardM2[:], 0.3) &&
				data.RunningStandardizerUpdate(&observation, obsSamples[:]) && data.RunningStandardizerUpdate(&reward, rewardSamples[:]) &&
				data.RunningStandardizerFreeze(&observation)
			testing.expect(t, setup)
			if !setup { return }
			options := PPOTrainingContextOptionsDefault(5)
			options.objective = {0.15, 0.02, 0.6, 0.75}
			options.fit = {epochs = 2, batchSize = 0, maxGradientNorm = 0.01, finalLearningRate = 0.002}
			options.policySeed, options.shuffleSeed = 12345, 77
			options.learningRate, options.beta1, options.beta2, options.epsilon = 0.01, 0.8, 0.95, 1e-6
			sourceAllocator, restoredAllocator := PPOContextTestAllocator{backing = context.allocator}, PPOContextTestAllocator{backing = context.allocator}
			sourceMem := mem.Allocator{procedure = PPOContextTestAllocatorProc, data = &sourceAllocator}
			restoredMem := mem.Allocator{procedure = PPOContextTestAllocatorProc, data = &restoredAllocator}
			result := PPOTrainingContextInit(&source, &policy, &value, options, sourceMem)
			testing.expect(t, result == .None)
			if result != .None { return }
			defer PPOTrainingContextDestroy(&source)
			backing, restoredBacking: PPOContextTestRolloutBacking
			buffer, restoredBuffer: rl.RolloutBuffer
			setup = PPOContextTestRolloutInit(&buffer, &backing) && PPOContextTestRolloutInit(&restoredBuffer, &restoredBacking)
			testing.expect(t, setup)
			if !setup { return }
			for _ in 0..<2 {
				setup = PPOContextTestCollect(&policy, &value, PPOTrainingContextState(&source), &buffer, 5) &&
					PPOTrainingContextRecordRollout(&source) == .None
				testing.expect(t, setup)
				if !setup { return }
				stats, err := PPOTrainingContextFit(&source, &buffer)
				testing.expect(t, err == .None && stats.updates == 4)
				if err != .None { return }
			}
			sourceState, sourceAdam := PPOTrainingContextState(&source), PPOTrainingContextOptimizer(&source)
			testing.expect(t, sourceState.updateCount == 8 && sourceState.rolloutCount == 2 && sourceAdam.step == 8 &&
				sourceState.policyRandomState != options.policySeed && sourceState.shuffleRandomState != options.shuffleSeed)
			checkpoint, roundTrip, baseScratch, policyScratch, valueScratch: [4096]u8
			size: int
			saved: bool
			if normalized {
				size, saved = PPOCheckpointWriteNormalized(&policy, &value, sourceAdam, sourceState^, source.objective, source.fitConfig,
					{&observation, &reward}, checkpoint[:], baseScratch[:], policyScratch[:], valueScratch[:])
			} else {
				writeError: PPOTrainingContextError
				size, writeError = PPOTrainingContextCheckpointWrite(&source, checkpoint[:], policyScratch[:], valueScratch[:])
				saved = writeError == .None
			}
			testing.expect(t, saved && size > 0)
			if !saved || size <= 0 { return }
			before := checkpoint
			if normalized {
				result = PPOTrainingContextCheckpointInitNormalized(&restored, &restoredPolicy, &restoredValue, checkpoint[:size],
					{&restoredObservation, &restoredReward}, 7, allocator = restoredMem)
			} else {
				result = PPOTrainingContextCheckpointInit(&restored, &restoredPolicy, &restoredValue, checkpoint[:size], 7, allocator = restoredMem)
			}
			testing.expectf(t, result == .None && checkpoint == before, "normalized=%v layerless=%v result=%v", normalized, layerless, result)
			if result != .None { return }
			defer PPOTrainingContextDestroy(&restored)
			restoredState, restoredAdam := PPOTrainingContextState(&restored), PPOTrainingContextOptimizer(&restored)
			testing.expect(t, restoredState != nil && restoredAdam != nil)
			if restoredState == nil || restoredAdam == nil { return }
			testing.expect(t, restored.rolloutCapacity == 7 && restored.observationWidth == 2 && restored.actionCount == 2 &&
				restored.objective == options.objective && restored.fitConfig == options.fit && sourceState^ == restoredState^ &&
				PPOContextCheckpointOptimizersEqual(sourceAdam, restoredAdam) &&
				PPOContextTestModelsEqual(&policy, &restoredPolicy) && PPOContextTestModelsEqual(&value, &restoredValue))
			storage, storageOk := PPOOwnedFitStorageView(&restored.scratch)
			testing.expect(t, storageOk && len(storage.indices) == 7 && len(storage.actions) == 3 &&
				len(storage.observations) == 6 && len(storage.legalActions) == 6 && len(storage.epochMetrics) == 2)
			parameters: [8]^core.Node
			bound, elements, boundOk := PPOCheckpointCombinedParameters(&restoredPolicy, &restoredValue, parameters[:])
			testing.expect(t, boundOk && elements == len(restoredAdam.firstMoment) && len(bound) == len(restoredAdam.parameters))
			if boundOk && len(bound) == len(restoredAdam.parameters) {
				for node, i in bound { testing.expect(t, node == restoredAdam.parameters[i] && node != sourceAdam.parameters[i]) }
			}
			if normalized {
				testing.expect(t, ppoCheckpointInitTestNormalizersEqual(&observation, &restoredObservation) &&
					ppoCheckpointInitTestNormalizersEqual(&reward, &restoredReward))
				roundSize, ok := PPOCheckpointWriteNormalized(&restoredPolicy, &restoredValue, restoredAdam, restoredState^,
					restored.objective, restored.fitConfig, {&restoredObservation, &restoredReward},
					roundTrip[:], baseScratch[:], policyScratch[:], valueScratch[:])
				testing.expect(t, ok && roundSize == size && PPOContextTestBytesEqual(rawptr(raw_data(roundTrip[:size])), checkpoint[:size]))
			} else {
				roundSize, err := PPOTrainingContextCheckpointWrite(&restored, roundTrip[:], policyScratch[:], valueScratch[:])
				testing.expect(t, err == .None && roundSize == size && PPOContextTestBytesEqual(rawptr(raw_data(roundTrip[:size])), checkpoint[:size]))
			}
			for iteration in 0..<3 {
				setup = PPOContextTestCollect(&policy, &value, sourceState, &buffer, 5) &&
					PPOContextTestCollect(&restoredPolicy, &restoredValue, restoredState, &restoredBuffer, 5)
				testing.expect(t, setup && backing == restoredBacking && sourceState^ == restoredState^)
				if !setup { return }
				testing.expect(t, PPOTrainingContextRecordRollout(&source) == .None && PPOTrainingContextRecordRollout(&restored) == .None)
				stats, err := PPOTrainingContextFit(&source, &buffer)
				restoredStats, restoredErr := PPOTrainingContextFit(&restored, &restoredBuffer)
				testing.expect(t, err == .None && restoredErr == .None && stats == restoredStats && stats.updates == 4 &&
					sourceState^ == restoredState^ && sourceState.updateCount == u64(12+iteration*4) &&
					PPOContextCheckpointOptimizersEqual(sourceAdam, restoredAdam) && PPOContextTestModelsEqual(&policy, &restoredPolicy) &&
					PPOContextTestModelsEqual(&value, &restoredValue))
				metrics, restoredMetrics := PPOTrainingContextEpochMetrics(&source), PPOTrainingContextEpochMetrics(&restored)
				testing.expect(t, len(metrics) == 2 && len(restoredMetrics) == 2 && metrics[0] == restoredMetrics[0] && metrics[1] == restoredMetrics[1])
				if normalized {
					sample := [1]f32{f32(iteration)+0.25}
					testing.expect(t, data.RunningStandardizerUpdate(&reward, sample[:]) && data.RunningStandardizerUpdate(&restoredReward, sample[:]) &&
						ppoCheckpointInitTestNormalizersEqual(&reward, &restoredReward) && ppoCheckpointInitTestNormalizersEqual(&observation, &restoredObservation))
				}
				if err != .None || restoredErr != .None { return }
			}
			testing.expect(t, sourceAllocator.allocations == 4 && restoredAllocator.allocations == 4 &&
				sourceAllocator.freeCalls == 0 && restoredAllocator.freeCalls == 0)
				testing.expect(t, PPOTrainingContextDestroy(&restored) == .None && PPOTrainingContextDestroy(&source) == .None &&
					restoredAllocator.frees == 4 && sourceAllocator.frees == 4 && restoredAllocator.badFrees == 0 && sourceAllocator.badFrees == 0)
			}
		}
	}

	@(test)
	PPOCheckpointInitPresenceAndEmptyNormalizers :: proc(t: ^testing.T) {
		for mask in 0..<4 {
			for empty in ([2]bool{false, true}) {
				width, rewardWidth := 0, 0
				if mask & 1 != 0 { width = 2 }
				if mask & 2 != 0 { rewardWidth = 1 }
				fixture: NormalizedInspectTestFixture
				built := normalizedInspectTestFixture(&fixture, true, width, rewardWidth, empty)
				testing.expect(t, built)
				if !built { return }
				for targetMask in 0..<4 {
					target: PPOCheckpointInitTestTarget
					setup := ppoCheckpointInitTestTargetInit(&target)
					testing.expect(t, setup)
					if !setup { return }
					normalizers: PPOTrainingNormalizers
					if targetMask & 1 != 0 { normalizers.observation = &target.dest.observation }
					if targetMask & 2 != 0 { normalizers.reward = &target.dest.reward }
					if mask != targetMask {
						_ = ppoCheckpointInitTestReject(t, "normalizer presence", &target, fixture.bytes[:fixture.size], true,
							.CheckpointIncompatible, normalizers)
						continue
					}
					before := fixture.bytes
					state := PPOContextTestAllocator{backing = context.allocator}
					allocator := mem.Allocator{procedure = PPOContextTestAllocatorProc, data = &state}
					result := ppoCheckpointInitTestCall(&target, fixture.bytes[:fixture.size], true, allocator, normalizers)
					testing.expectf(t, result == .None && fixture.bytes == before && state.allocations == 4,
						"mask=%d empty=%v result=%v", mask, empty, result)
					if result != .None { continue }
					if mask & 1 != 0 {
						if empty {
							testing.expect(t, target.dest.observation.count == 0 && !target.dest.observation.frozen &&
								target.dest.observation.epsilon == 0.02 && target.dest.observationMean == ([2]f64{}) && target.dest.observationM2 == ([2]f64{}))
						} else {
							testing.expect(t, target.dest.observation.count == 2 && target.dest.observation.frozen &&
								target.dest.observation.epsilon == 0.02 && target.dest.observationMean == ([2]f64{2, 12}) && target.dest.observationM2 == ([2]f64{2, 8}))
						}
					}
					if mask & 2 != 0 {
						if empty {
							testing.expect(t, target.dest.reward.count == 0 && !target.dest.reward.frozen &&
								target.dest.reward.epsilon == 0.03 && target.dest.rewardMean == ([1]f64{}) && target.dest.rewardM2 == ([1]f64{}))
						} else {
							testing.expect(t, target.dest.reward.count == 3 && !target.dest.reward.frozen &&
								target.dest.reward.epsilon == 0.03 && target.dest.rewardMean == ([1]f64{0}) && target.dest.rewardM2 == ([1]f64{8}))
						}
					}
					testing.expect(t, PPOTrainingContextDestroy(&target.trainer) == .None && state.frees == 4 && state.badFrees == 0)
				}
			}
		}
		fixture: NormalizedInspectTestFixture
		testing.expect(t, normalizedInspectTestFixture(&fixture, true, 2, 1))
		for mode in 0..<3 {
			target: PPOCheckpointInitTestTarget
			testing.expect(t, ppoCheckpointInitTestTargetInit(&target))
			switch mode {
			case 0:
				target.dest.observation.mean = target.dest.observationMean[:1]
				target.dest.observation.m2 = target.dest.observationM2[:1]
			case 1: target.dest.reward.epsilon = 0
			case 2: target.dest.observation.m2 = target.dest.observation.mean
			}
			_ = ppoCheckpointInitTestReject(t, "normalizer width or validity", &target, fixture.bytes[:fixture.size], true,
				.CheckpointIncompatible, ppoCheckpointInitTestNormalizers(&target))
		}
	}

	@(test)
	PPOCheckpointInitInspectionLimitsAndBudget :: proc(t: ^testing.T) {
		fixture: NormalizedInspectTestFixture
		built := normalizedInspectTestFixture(&fixture, true, 2, 1)
		testing.expect(t, built)
		if !built { return }
		base := fixture.bytes[fixture.baseAt:fixture.size]
		baseLimits := []PPOCheckpointInspectLimits{
			{maxBytes = fixture.baseSize-1}, {maxParameterPointers = 3}, {maxMomentElements = 8}, {maxEpochs = 2},
			{policy = {maxBytes = fixture.valueAt-fixture.policyAt-1}}, {policy = {maxLayers = 1}}, {policy = {maxWidth = 2}},
			{policy = {maxBatchCapacity = 1}}, {policy = {maxParameterPointers = 1}}, {policy = {maxMomentElements = 5}},
			{value = {maxBytes = fixture.size-fixture.valueAt-1}}, {value = {maxLayers = 1}}, {value = {maxWidth = 2}},
			{value = {maxBatchCapacity = 1}}, {value = {maxParameterPointers = 1}}, {value = {maxMomentElements = 2}},
		}
		negative := []PPOCheckpointInspectLimits{
			{maxBytes = -1}, {maxParameterPointers = -1}, {maxMomentElements = -1}, {maxEpochs = -1},
			{policy = {maxBytes = -1}}, {policy = {maxLayers = -1}}, {policy = {maxWidth = -1}},
			{policy = {maxBatchCapacity = -1}}, {policy = {maxParameterPointers = -1}}, {policy = {maxMomentElements = -1}},
			{value = {maxBytes = -1}}, {value = {maxLayers = -1}}, {value = {maxWidth = -1}},
			{value = {maxBatchCapacity = -1}}, {value = {maxParameterPointers = -1}}, {value = {maxMomentElements = -1}},
		}
		target: PPOCheckpointInitTestTarget
		testing.expect(t, ppoCheckpointInitTestTargetInit(&target))
		for limits, i in baseLimits {
			_, inspectErr := PPOCheckpointInspect(base, limits)
			testing.expectf(t, inspectErr.code == .LimitExceeded, "base limit fixture %d: %v", i, inspectErr)
			_ = ppoCheckpointInitTestReject(t, "base limit", &target, base, false, .CheckpointIncompatible, {}, limits)
			_ = ppoCheckpointInitTestReject(t, "normalized nested limit", &target, fixture.bytes[:fixture.size], true,
				.CheckpointIncompatible, ppoCheckpointInitTestNormalizers(&target), normalizedLimits = {base = limits})
		}
		for limits in negative {
			_ = ppoCheckpointInitTestReject(t, "negative base limit", &target, base, false, .InvalidOptions, {}, limits)
			_ = ppoCheckpointInitTestReject(t, "negative normalized nested limit", &target, fixture.bytes[:fixture.size], true,
				.InvalidOptions, ppoCheckpointInitTestNormalizers(&target), normalizedLimits = {base = limits})
		}
		for limits in ([]PPONormalizedCheckpointInspectLimits{{maxBytes = fixture.size-1}, {maxObservationWidth = 1}}) {
			_ = ppoCheckpointInitTestReject(t, "normalized outer limit", &target, fixture.bytes[:fixture.size], true,
				.CheckpointIncompatible, ppoCheckpointInitTestNormalizers(&target), normalizedLimits = limits)
		}
		for limits in ([]PPONormalizedCheckpointInspectLimits{{maxBytes = -1}, {maxObservationWidth = -1}}) {
			_ = ppoCheckpointInitTestReject(t, "negative normalized outer limit", &target, fixture.bytes[:fixture.size], true,
				.InvalidOptions, ppoCheckpointInitTestNormalizers(&target), normalizedLimits = limits)
		}
		absent: NormalizedInspectTestFixture
		testing.expect(t, normalizedInspectTestFixture(&absent, true, 0, 1))
		_ = ppoCheckpointInitTestReject(t, "observation width limit with absent normalizer", &target, absent.bytes[:absent.size], true,
			.CheckpointIncompatible, {reward = &target.dest.reward}, normalizedLimits = {maxObservationWidth = 1})
		for normalized in ([2]bool{false, true}) {
			input := base
			if normalized { input = fixture.bytes[:fixture.size] }
			exact := PPOCheckpointInspectLimits{maxBytes = fixture.baseSize, maxParameterPointers = 4, maxMomentElements = 9, maxEpochs = 3,
				policy = {fixture.valueAt-fixture.policyAt, 2, 3, 2, 2, 6}, value = {fixture.size-fixture.valueAt, 2, 3, 2, 2, 3}}
			exactNormalized := PPONormalizedCheckpointInspectLimits{maxBytes = fixture.size, maxObservationWidth = 2, base = exact}
			state := PPOContextTestAllocator{backing = context.allocator}
			allocator := mem.Allocator{procedure = PPOContextTestAllocatorProc, data = &state}
			result := ppoCheckpointInitTestCall(&target, input, normalized, allocator, ppoCheckpointInitTestNormalizers(&target), exact, exactNormalized)
			testing.expect(t, result == .None && state.allocations == 4 && state.sizes[1] == 4*size_of(^core.Node) &&
				state.sizes[2] == 9*size_of(f32) && state.sizes[3] == 9*size_of(f32))
			if result != .None { return }
			total := state.sizes[0]+state.sizes[1]+state.sizes[2]+state.sizes[3]
			testing.expect(t, total > 1 && PPOTrainingContextDestroy(&target.trainer) == .None)
			// The restored models are nonempty: reset only after successful destruction.
			target = {}
			testing.expect(t, ppoCheckpointInitTestTargetInit(&target))
			_ = ppoCheckpointInitTestReject(t, "owned byte budget below exact", &target, input, normalized, .CheckpointIncompatible,
				ppoCheckpointInitTestNormalizers(&target), maxOwnedBytes = total-1)
			_ = ppoCheckpointInitTestReject(t, "negative byte budget", &target, input, normalized, .InvalidOptions,
				ppoCheckpointInitTestNormalizers(&target), maxOwnedBytes = -1)
			_ = ppoCheckpointInitTestReject(t, "zero rollout capacity", &target, input, normalized, .InvalidOptions,
				ppoCheckpointInitTestNormalizers(&target), rolloutCapacity = 0)
			_ = ppoCheckpointInitTestReject(t, "overflowing scratch size", &target, input, normalized, .CheckpointIncompatible,
				ppoCheckpointInitTestNormalizers(&target), rolloutCapacity = max(int))
			state = {backing = context.allocator}
			result = ppoCheckpointInitTestCall(&target, input, normalized, allocator, ppoCheckpointInitTestNormalizers(&target),
				exact, exactNormalized, total)
			testing.expect(t, result == .None && state.allocations == 4)
			if result == .None { testing.expect(t, PPOTrainingContextDestroy(&target.trainer) == .None && state.frees == 4) }
			target = {}
			testing.expect(t, ppoCheckpointInitTestTargetInit(&target))
		}
	}

	@(test)
	PPOCheckpointInitMalformedAndWrongFormat :: proc(t: ^testing.T) {
		fixture, sgd: NormalizedInspectTestFixture
		built := normalizedInspectTestFixture(&fixture, true, 2, 1) && normalizedInspectTestFixture(&sgd, false, 2, 1)
		testing.expect(t, built)
		if !built { return }
		for normalized in ([2]bool{false, true}) {
			target: PPOCheckpointInitTestTarget
			testing.expect(t, ppoCheckpointInitTestTargetInit(&target))
			input := fixture.bytes[fixture.baseAt:fixture.size]
			sgdInput := sgd.bytes[sgd.baseAt:sgd.size]
			if normalized { input, sgdInput = fixture.bytes[:fixture.size], sgd.bytes[:sgd.size] }
			for length in 0..<len(input) {
				ok := ppoCheckpointInitTestReject(t, "truncated input", &target, input[:length], normalized,
					.InvalidCheckpoint, ppoCheckpointInitTestNormalizers(&target))
				testing.expectf(t, ok, "normalized=%v truncation at %d/%d", normalized, length, len(input))
				if !ok { break }
			}
			_ = ppoCheckpointInitTestReject(t, "SGD checkpoint", &target, sgdInput, normalized,
				.CheckpointIncompatible, ppoCheckpointInitTestNormalizers(&target))
			mutated: [4096]u8
			for which in 0..<8 {
				copy(mutated[:], input)
				policyOffset, valueOffset := fixture.policyAt-fixture.baseAt, fixture.valueAt-fixture.baseAt
				if normalized { policyOffset, valueOffset = fixture.policyAt, fixture.valueAt }
				switch which {
				case 0: mutated[0] = 0
				case 1: mutated[8] = 0xff
				case 2: mutated[policyOffset] = 0
				case 3: mutated[valueOffset] = 0
				case 4:
					// Trailing input is never silently ignored.
					mutated[len(input)] = 0
				case 5:
					position := len(input)-4
					normalizedInspectTestPutF32(mutated[:], &position, transmute(f32)u32(0x7fc00000))
				case 6:
					position := 80
					if normalized { position += fixture.baseAt }
					normalizedInspectTestPut64(mutated[:], &position, 0)
				case 7:
					position := 144
					if normalized { position += fixture.baseAt }
					normalizedInspectTestPutF32(mutated[:], &position, transmute(f32)u32(0x7fc00000))
				}
				length := len(input)
				if which == 4 { length += 1 }
				_ = ppoCheckpointInitTestReject(t, "corrupt or trailing input", &target, mutated[:length], normalized,
					.InvalidCheckpoint, ppoCheckpointInitTestNormalizers(&target))
			}
			wrong := fixture.bytes[:fixture.size]
			if normalized { wrong = fixture.bytes[fixture.baseAt:fixture.size] }
			_ = ppoCheckpointInitTestReject(t, "wrong checkpoint format", &target, wrong, normalized,
				.InvalidCheckpoint, ppoCheckpointInitTestNormalizers(&target))
			if normalized {
				for which in 0..<2 {
					copy(mutated[:], input)
					position := fixture.observationAt
					value: u64 = 2 // Invalid presence flag.
					if which == 1 { position += 8; value = 0 } // Nonzero moments with count zero.
					normalizedInspectTestPut64(mutated[:], &position, value)
					_ = ppoCheckpointInitTestReject(t, "corrupt normalizer", &target, mutated[:len(input)], true,
						.InvalidCheckpoint, ppoCheckpointInitTestNormalizers(&target))
				}
			}
		}
	}

	@(test)
	PPOCheckpointInitModelAndHandleGuards :: proc(t: ^testing.T) {
		fixture: NormalizedInspectTestFixture
		testing.expect(t, normalizedInspectTestFixture(&fixture, true, 2, 1))
		for normalized in ([2]bool{false, true}) {
			input := fixture.bytes[fixture.baseAt:fixture.size]
			if normalized { input = fixture.bytes[:fixture.size] }
			for which in 0..<6 {
				target: PPOCheckpointInitTestTarget
				testing.expect(t, ppoCheckpointInitTestTargetInit(&target))
				switch which {
				case 0: target.trainer.phase = .Destroying
				case 1: target.trainer.self = rawptr(&target.trainer)
				case 2: target.trainer.adam.self = rawptr(&target.trainer.adam)
				case 3: target.trainer.scratch.self = rawptr(&target.trainer.scratch)
				case 4: target.trainer.scratch.memory = rawptr(&target.dest.policy)
				case 5: target.trainer.pending.blocks[0] = rawptr(&target.dest.policy)
				}
				_ = ppoCheckpointInitTestReject(t, "nonempty trainer handle", &target, input, normalized,
					.InvalidHandle, ppoCheckpointInitTestNormalizers(&target))
			}
			for which in 0..<4 {
				target: PPOCheckpointInitTestTarget
				testing.expect(t, ppoCheckpointInitTestTargetInit(&target))
				original: Sequential(2, 3, 2)
				switch which {
				case 0: testing.expect(t, SequentialInit(&target.dest.policy, 2, 1) && SequentialAddDense(&target.dest.policy, 2))
				case 1: testing.expect(t, SequentialInit(&target.dest.value, 2, 2) && SequentialAddDense(&target.dest.value, 1))
				case 2:
					testing.expect(t, SequentialInit(&original, 2, 3))
					target.dest.policy = original
				case 3:
					testing.expect(t, SequentialInit(&original, 2, 4))
					target.dest.value = original
				}
				_ = ppoCheckpointInitTestReject(t, "nonempty or copied model", &target, input, normalized,
					.InvalidModel, ppoCheckpointInitTestNormalizers(&target))
			}
			target: PPOCheckpointInitTestTarget
			testing.expect(t, ppoCheckpointInitTestTargetInit(&target))
			state := PPOContextTestAllocator{backing = context.allocator}
			allocator := mem.Allocator{procedure = PPOContextTestAllocatorProc, data = &state}
			normalizers := ppoCheckpointInitTestNormalizers(&target)
			nilTrainer := (^PPOTrainingContext(2, 3, 2, 2, 3, 2))(nil)
			result: PPOTrainingContextError
			if normalized {
				result = PPOTrainingContextCheckpointInitNormalized(nilTrainer, &target.dest.policy, &target.dest.value, input, normalizers, 5, allocator = allocator)
			} else {
				result = PPOTrainingContextCheckpointInit(nilTrainer, &target.dest.policy, &target.dest.value, input, 5, allocator = allocator)
			}
			testing.expect(t, result == .InvalidHandle && state.attempts == 0)
			for missingPolicy in ([2]bool{false, true}) {
				policy, value := &target.dest.policy, &target.dest.value
				if missingPolicy { policy = nil } else { value = nil }
				if normalized {
					result = PPOTrainingContextCheckpointInitNormalized(&target.trainer, policy, value, input, normalizers, 5, allocator = allocator)
				} else {
					result = PPOTrainingContextCheckpointInit(&target.trainer, policy, value, input, 5, allocator = allocator)
				}
				testing.expect(t, result == .InvalidModel && state.attempts == 0)
			}
			result = ppoCheckpointInitTestCall(&target, input, normalized, allocator, normalizers)
			testing.expect(t, result == .None)
			if result != .None { return }
			copyOfTrainer := target.trainer
			policy, value: Sequential(2, 3, 2)
			if normalized {
				result = PPOTrainingContextCheckpointInitNormalized(&copyOfTrainer, &policy, &value, input, normalizers, 5, allocator = allocator)
			} else {
				result = PPOTrainingContextCheckpointInit(&copyOfTrainer, &policy, &value, input, 5, allocator = allocator)
			}
			testing.expect(t, result == .InvalidHandle && PPOTrainingContextDestroy(&copyOfTrainer) == .InvalidHandle && state.freeCalls == 0)
			if normalized {
				result = PPOTrainingContextCheckpointInitNormalized(&target.trainer, &policy, &value, input, normalizers, 5, allocator = allocator)
			} else {
				result = PPOTrainingContextCheckpointInit(&target.trainer, &policy, &value, input, 5, allocator = allocator)
			}
			testing.expect(t, result == .InvalidHandle && state.allocations == 4 && state.freeCalls == 0)
			testing.expect(t, PPOTrainingContextDestroy(&target.trainer) == .None && state.frees == 4 && state.badFrees == 0)
		}
	}

	@(test)
	PPOCheckpointInitRejectsEachIndependentCapacity :: proc(t: ^testing.T) {
		fixture: NormalizedInspectTestFixture
		testing.expect(t, normalizedInspectTestFixture(&fixture, true, 2, 1))
		normalPolicy, normalValue: Sequential(2, 3, 2)
		policyLayers, valueLayers: Sequential(1, 3, 2)
		policyWidth, valueWidth: Sequential(2, 2, 2)
		policyBatch, valueBatch: Sequential(2, 3, 1)
		setup := PPOContextTestSetup(&normalPolicy, &normalValue) &&
			SequentialInit(&policyLayers, 2, 1) && SequentialAddDense(&policyLayers, 2) &&
			SequentialInit(&valueLayers, 2, 2) && SequentialAddDense(&valueLayers, 1) &&
			SequentialInit(&policyWidth, 2, 3) && SequentialAddDense(&policyWidth, 2) &&
			SequentialInit(&valueWidth, 2, 4) && SequentialAddDense(&valueWidth, 1) &&
			SequentialInit(&policyBatch, 2, 5) && SequentialAddDense(&policyBatch, 2) &&
			SequentialInit(&valueBatch, 2, 6) && SequentialAddDense(&valueBatch, 1)
		testing.expect(t, setup)
		if !setup { return }
		options := PPOTrainingContextOptionsDefault(5)
		options.fit = {epochs = 2, batchSize = 1}
		for mode in 0..<6 {
			base, wrapped: [4096]u8
			size: int
			err: PPOTrainingContextError
			switch mode {
			case 0: size, err = PPOContextCheckpointMake(&policyLayers, &normalValue, options, base[:])
			case 1: size, err = PPOContextCheckpointMake(&policyWidth, &normalValue, options, base[:])
			case 2: size, err = PPOContextCheckpointMake(&policyBatch, &normalValue, options, base[:])
			case 3: size, err = PPOContextCheckpointMake(&normalPolicy, &valueLayers, options, base[:])
			case 4: size, err = PPOContextCheckpointMake(&normalPolicy, &valueWidth, options, base[:])
			case 5: size, err = PPOContextCheckpointMake(&normalPolicy, &valueBatch, options, base[:])
			}
			testing.expectf(t, err == .None && size > 0, "capacity fixture %d: %v", mode, err)
			if err != .None || size <= 0 { return }
			copy(wrapped[:fixture.baseAt], fixture.bytes[:fixture.baseAt])
			position := 16
			normalizedInspectTestPut64(wrapped[:], &position, u64(size))
			copy(wrapped[fixture.baseAt:fixture.baseAt+size], base[:size])
			_, inspectErr := PPOCheckpointInspectNormalized(wrapped[:fixture.baseAt+size])
			testing.expectf(t, inspectErr.code == .None, "normalized capacity fixture %d: %v", mode, inspectErr)
			target: PPOCheckpointInitTestTarget
			testing.expect(t, ppoCheckpointInitTestTargetInit(&target))
			_ = ppoCheckpointInitTestReject(t, "base independent capacity", &target, base[:size], false, .CheckpointIncompatible, {})
			_ = ppoCheckpointInitTestReject(t, "normalized independent capacity", &target, wrapped[:fixture.baseAt+size], true,
				.CheckpointIncompatible, ppoCheckpointInitTestNormalizers(&target))
		}
	}

	@(test)
	PPOCheckpointInitAllocationFailuresAreAtomic :: proc(t: ^testing.T) {
		fixture: NormalizedInspectTestFixture
		testing.expect(t, normalizedInspectTestFixture(&fixture, true, 2, 1))
		for normalized in ([2]bool{false, true}) {
			input := fixture.bytes[fixture.baseAt:fixture.size]
			if normalized { input = fixture.bytes[:fixture.size] }
			for position in 1..=4 {
				for mode in 0..<3 {
					target: PPOCheckpointInitTestTarget
					testing.expect(t, ppoCheckpointInitTestTargetInit(&target))
					before: [size_of(PPOCheckpointInitTestTarget)]u8
					copy(before[:], mem.slice_ptr((^u8)(rawptr(&target)), len(before)))
					inputBefore := fixture.bytes
					state := PPOContextTestAllocator{backing = context.allocator}
					if mode == 2 { state.pointerAndErrorAt = position } else { state.failAt = position; state.failWithNil = mode == 1 }
					allocator := mem.Allocator{procedure = PPOContextTestAllocatorProc, data = &state}
					result := ppoCheckpointInitTestCall(&target, input, normalized, allocator, ppoCheckpointInitTestNormalizers(&target))
					expected := PPOTrainingContextError.OptimizerSetupFailed
					if position == 1 { expected = .ScratchSetupFailed }
					count := position-1
					if mode == 2 { count += 1 }
					unchanged := PPOContextTestBytesEqual(rawptr(&target), before[:]) && fixture.bytes == inputBefore
					testing.expectf(t, result == expected && unchanged && state.attempts == position && state.allocations == count &&
						state.freeCalls == count && state.frees == count && state.badFrees == 0,
						"normalized=%v position=%d mode=%d result=%v unchanged=%v allocations=%d frees=%d",
						normalized, position, mode, result, unchanged, state.allocations, state.frees)
					for i in 0..<count { testing.expect(t, state.freeOrder[i] == state.allocated[count-1-i] && !state.live[i]) }
					if result != expected { _ = PPOTrainingContextDestroy(&target.trainer); continue }
					testing.expect(t, PPOTrainingContextDestroy(&target.trainer) == .None && state.freeCalls == count)
					state.failAt, state.pointerAndErrorAt = 0, 0
					result = ppoCheckpointInitTestCall(&target, input, normalized, allocator, ppoCheckpointInitTestNormalizers(&target))
					testing.expect(t, result == .None && state.allocations == count+4)
					if result == .None { testing.expect(t, PPOTrainingContextDestroy(&target.trainer) == .None) }
					testing.expect(t, state.frees == state.allocations && state.badFrees == 0 &&
						PPOTrainingContextDestroy(&target.trainer) == .None && state.freeCalls == count+4)
				}
			}
			target: PPOCheckpointInitTestTarget
			testing.expect(t, ppoCheckpointInitTestTargetInit(&target))
			before: [size_of(PPOCheckpointInitTestTarget)]u8
			copy(before[:], mem.slice_ptr((^u8)(rawptr(&target)), len(before)))
			result := ppoCheckpointInitTestCall(&target, input, normalized, mem.nil_allocator(), ppoCheckpointInitTestNormalizers(&target))
			testing.expect(t, result == .ScratchSetupFailed && PPOContextTestBytesEqual(rawptr(&target), before[:]))
		}
	}

	@(test)
	PPOCheckpointInitRollbackFreeFailureRetainsPending :: proc(t: ^testing.T) {
		fixture: NormalizedInspectTestFixture
		testing.expect(t, normalizedInspectTestFixture(&fixture, true, 2, 1))
		for normalized in ([2]bool{false, true}) {
			input := fixture.bytes[fixture.baseAt:fixture.size]
			if normalized { input = fixture.bytes[:fixture.size] }
			for position in 1..=4 {
				for failedFree in 1..=position {
					target: PPOCheckpointInitTestTarget
					testing.expect(t, ppoCheckpointInitTestTargetInit(&target))
					destBefore: [size_of(PPOCheckpointInitTestDestinations)]u8
					copy(destBefore[:], mem.slice_ptr((^u8)(rawptr(&target.dest)), len(destBefore)))
					inputBefore := fixture.bytes
					state := PPOContextTestAllocator{backing = context.allocator, pointerAndErrorAt = position, failFreeAt = failedFree}
					allocator := mem.Allocator{procedure = PPOContextTestAllocatorProc, data = &state}
					result := ppoCheckpointInitTestCall(&target, input, normalized, allocator, ppoCheckpointInitTestNormalizers(&target))
					retained := position-failedFree
					testing.expectf(t, result == .CleanupFailed && target.trainer.phase == .Destroying && target.trainer.self == rawptr(&target.trainer) &&
						state.allocations == position && state.freeCalls == position && state.frees == position-1 && state.badFrees == 0 &&
						PPOContextTestBytesEqual(rawptr(&target.dest), destBefore[:]) && fixture.bytes == inputBefore,
						"normalized=%v position=%d free=%d result=%v frees=%d", normalized, position, failedFree, result, state.frees)
					for i in 0..<position {
						testing.expect(t, state.freeOrder[i] == state.allocated[position-1-i] && state.live[i] == (i == retained) &&
							(target.trainer.pending.blocks[i] != nil) == (i == retained))
					}
					testing.expect(t, target.trainer.pending.blocks[retained] == state.allocated[retained] &&
						PPOTrainingContextState(&target.trainer) == nil && PPOTrainingContextOptimizer(&target.trainer) == nil &&
						len(PPOTrainingContextEpochMetrics(&target.trainer)) == 0 && PPOTrainingContextRecordRollout(&target.trainer) == .InvalidHandle)
					_, fitError := PPOTrainingContextFit(&target.trainer, nil)
					testing.expect(t, fitError == .InvalidHandle &&
						ppoCheckpointInitTestCall(&target, input, normalized, allocator, ppoCheckpointInitTestNormalizers(&target)) == .InvalidHandle &&
						state.attempts == position)
					testing.expect(t, PPOTrainingContextDestroy(&target.trainer) == .None && state.freeCalls == position+1 &&
						state.freeOrder[position] == state.allocated[retained] && state.frees == position && state.badFrees == 0)
					testing.expect(t, PPOTrainingContextDestroy(&target.trainer) == .None && state.freeCalls == position+1 &&
						PPOContextTestBytesEqual(rawptr(&target.dest), destBefore[:]))
				}
			}
		}
	}

	@(test)
	PPOCheckpointInitDestroyFailureOrderingAndRetry :: proc(t: ^testing.T) {
		fixture: NormalizedInspectTestFixture
		testing.expect(t, normalizedInspectTestFixture(&fixture, true, 2, 1))
		for normalized in ([2]bool{false, true}) {
			input := fixture.bytes[fixture.baseAt:fixture.size]
			if normalized { input = fixture.bytes[:fixture.size] }
			for failedFree in 1..=4 {
				target: PPOCheckpointInitTestTarget
				testing.expect(t, ppoCheckpointInitTestTargetInit(&target))
				state := PPOContextTestAllocator{backing = context.allocator, failFreeAt = failedFree}
				allocator := mem.Allocator{procedure = PPOContextTestAllocatorProc, data = &state}
				result := ppoCheckpointInitTestCall(&target, input, normalized, allocator, ppoCheckpointInitTestNormalizers(&target))
				testing.expect(t, result == .None && state.allocations == 4)
				if result != .None { return }
				destBefore: [size_of(PPOCheckpointInitTestDestinations)]u8
				copy(destBefore[:], mem.slice_ptr((^u8)(rawptr(&target.dest)), len(destBefore)))
				testing.expect(t, PPOTrainingContextDestroy(&target.trainer) == .CleanupFailed && target.trainer.phase == .Destroying)
				for i in 0..<min(failedFree, 3) { testing.expect(t, state.freeOrder[i] == state.allocated[3-i]) }
				if failedFree <= 3 {
					testing.expect(t, state.freeCalls == failedFree+1 && state.freeOrder[failedFree] == state.allocated[0] &&
						!state.live[0] && state.live[4-failedFree])
				} else {
					testing.expect(t, state.freeCalls == 4 && state.freeOrder[3] == state.allocated[0] && state.live[0])
				}
				testing.expect(t, PPOTrainingContextState(&target.trainer) == nil && PPOTrainingContextOptimizer(&target.trainer) == nil &&
					len(PPOTrainingContextEpochMetrics(&target.trainer)) == 0 &&
					ppoCheckpointInitTestCall(&target, input, normalized, allocator, ppoCheckpointInitTestNormalizers(&target)) == .InvalidHandle &&
					PPOContextTestBytesEqual(rawptr(&target.dest), destBefore[:]))
				testing.expect(t, PPOTrainingContextDestroy(&target.trainer) == .None && state.freeCalls == 5 && state.frees == 4 && state.badFrees == 0)
				for live in state.live[:4] { testing.expect(t, !live) }
				testing.expect(t, PPOTrainingContextDestroy(&target.trainer) == .None && state.freeCalls == 5 &&
					PPOContextTestBytesEqual(rawptr(&target.dest), destBefore[:]))
			}
		}
	}

	PPOCheckpointInitOverlapAllocator :: struct {
		backing: mem.Allocator,
		overlap: rawptr,
		overlapPrevious: bool,
		injectAt, attempts, realAllocations, fakeFrees, realFrees, badFrees: int,
		real: [4]rawptr,
		live: [4]bool,
		fakeFreed: bool,
	}

	// The injected block is never dereferenced; Free records it rather than freeing
	// caller-owned memory. Earlier genuine allocations remain individually freeable.
	ppoCheckpointInitOverlapAllocatorProc :: proc(
		data: rawptr, mode: mem.Allocator_Mode, size, alignment: int,
		oldMemory: rawptr, oldSize: int, loc := #caller_location,
	) -> ([]byte, mem.Allocator_Error) {
		state := (^PPOCheckpointInitOverlapAllocator)(data)
		if mode == .Alloc {
			state.attempts += 1
			if state.attempts == state.injectAt {
				if state.overlapPrevious { state.overlap = rawptr(uintptr(state.real[0])+8) }
				return mem.slice_ptr((^byte)(state.overlap), size), nil
			}
			memory, err := state.backing.procedure(state.backing.data, mode, size, alignment, oldMemory, oldSize, loc)
			if raw_data(memory) != nil {
				i := state.realAllocations
				state.real[i], state.live[i] = rawptr(raw_data(memory)), true
				state.realAllocations += 1
			}
			return memory, err
		}
		if mode == .Free {
			if oldMemory == state.overlap && !state.fakeFreed {
				state.fakeFreed = true
				state.fakeFrees += 1
				return nil, nil
			}
			for pointer, i in state.real[:state.realAllocations] {
				if oldMemory == pointer && state.live[i] {
					bytes, err := state.backing.procedure(state.backing.data, mode, size, alignment, oldMemory, oldSize, loc)
					if err == nil { state.live[i] = false; state.realFrees += 1 }
					return bytes, err
				}
			}
			state.badFrees += 1
			return nil, .Invalid_Pointer
		}
		return state.backing.procedure(state.backing.data, mode, size, alignment, oldMemory, oldSize, loc)
	}

	PPOCheckpointInitOverlapTargetBox :: struct {
		target: PPOCheckpointInitTestTarget,
		padding: [4096]u8,
	}

	@(test)
	PPOCheckpointInitRejectsOverlappingAllocations :: proc(t: ^testing.T) {
		fixture: NormalizedInspectTestFixture
		testing.expect(t, normalizedInspectTestFixture(&fixture, true, 2, 1))
		for normalized in ([2]bool{false, true}) {
			input := fixture.bytes[fixture.baseAt:fixture.size]
			if normalized { input = fixture.bytes[:fixture.size] }
			for position in 1..=4 {
				for kind in 0..<11 {
					// Base initialization has no normalizers; a previous block exists only
					// after the first allocation.
					if !normalized && kind >= 4 && kind <= 9 || kind == 10 && position == 1 { continue }
					box: PPOCheckpointInitOverlapTargetBox
					target := &box.target
					testing.expect(t, ppoCheckpointInitTestTargetInit(target))
					addresses := [10]rawptr{
						rawptr(&target.trainer), rawptr(&target.dest.policy), rawptr(&target.dest.value), rawptr(raw_data(input)),
						rawptr(&target.dest.observation), rawptr(raw_data(target.dest.observation.mean)), rawptr(raw_data(target.dest.observation.m2)),
						rawptr(&target.dest.reward), rawptr(raw_data(target.dest.reward.mean)), rawptr(raw_data(target.dest.reward.m2)),
					}
					state := PPOCheckpointInitOverlapAllocator{backing = context.allocator, injectAt = position, overlapPrevious = kind == 10}
					if kind < 10 { state.overlap = addresses[kind] }
					allocator := mem.Allocator{procedure = ppoCheckpointInitOverlapAllocatorProc, data = &state}
					before: [size_of(PPOCheckpointInitTestTarget)]u8
					copy(before[:], mem.slice_ptr((^u8)(rawptr(target)), len(before)))
					inputBefore := fixture.bytes
					result := ppoCheckpointInitTestCall(target, input, normalized, allocator, ppoCheckpointInitTestNormalizers(target))
					expected := PPOTrainingContextError.OptimizerSetupFailed
					if position == 1 { expected = .ScratchSetupFailed }
					unchanged := PPOContextTestBytesEqual(rawptr(target), before[:]) && fixture.bytes == inputBefore
					testing.expectf(t, result == expected && unchanged && state.attempts == position &&
						state.realAllocations == position-1 && state.realFrees == position-1 && state.fakeFrees == 1 && state.badFrees == 0,
						"normalized=%v position=%d overlap=%d result=%v unchanged=%v real frees=%d/%d fake=%d bad=%d",
						normalized, position, kind, result, unchanged, state.realFrees, state.realAllocations, state.fakeFrees, state.badFrees)
					if result != expected { _ = PPOTrainingContextDestroy(&target.trainer) }
				}
			}
		}
	}

	PPOCheckpointInitNormalizerBox :: struct { prefix: [4096]u8, value: data.RunningStandardizer }
	PPOCheckpointInitObsArrayBox :: struct { prefix: [4096]u8, value: [2]f64 }
	PPOCheckpointInitRewardArrayBox :: struct { prefix: [4096]u8, value: [1]f64 }

	@(test)
	PPOCheckpointInitRejectsOverlappingInputsAndDestinations :: proc(t: ^testing.T) {
		fixture: NormalizedInspectTestFixture
		testing.expect(t, normalizedInspectTestFixture(&fixture, true, 2, 1))
		for normalized in ([2]bool{false, true}) {
			trainerBox: PPOContextCheckpointTrainerBox
			policyBox, valueBox: PPOContextCheckpointModelBox
			observationBox, rewardBox: PPOCheckpointInitNormalizerBox
			obsMean, obsM2: PPOCheckpointInitObsArrayBox
			rewardMean, rewardM2: PPOCheckpointInitRewardArrayBox
			setup := data.RunningStandardizerInit(&observationBox.value, obsMean.value[:], obsM2.value[:]) &&
				data.RunningStandardizerInit(&rewardBox.value, rewardMean.value[:], rewardM2.value[:])
			testing.expect(t, setup)
			if !setup { return }
			normalizers := PPOTrainingNormalizers{&observationBox.value, &rewardBox.value}
			original := fixture.bytes[fixture.baseAt:fixture.size]
			if normalized { original = fixture.bytes[:fixture.size] }
			addresses := [9]rawptr{rawptr(&trainerBox.trainer), rawptr(&policyBox.model), rawptr(&valueBox.model),
				rawptr(&observationBox.value), rawptr(&obsMean.value), rawptr(&obsM2.value),
				rawptr(&rewardBox.value), rawptr(&rewardMean.value), rawptr(&rewardM2.value)}
			count := 3
			if normalized { count = len(addresses) }
			for address, i in addresses[:count] {
				candidate: [4096]u8
				copy(candidate[:], original)
				// Keep the final nested-model float finite and preserve the one byte
				// shared with the destination, so preparing the fixture changes no object.
				size := len(original)
				candidate[size-4], candidate[size-3], candidate[size-2], candidate[size-1] = 0, 0, 0, (^u8)(address)^
				input := mem.slice_ptr((^u8)(rawptr(uintptr(address)-uintptr(size-1))), size)
				copy(input, candidate[:size])
				valid: bool
				if normalized { _, err := PPOCheckpointInspectNormalized(input); valid = err.code == .None } else { _, err := PPOCheckpointInspect(input); valid = err.code == .None }
				testing.expectf(t, valid, "normalized=%v overlap=%d must remain a valid checkpoint", normalized, i)
				if !valid { return }
				trainerBefore: [size_of(trainerBox.trainer)]u8
				policyBefore, valueBefore: [size_of(policyBox.model)]u8
				obsBefore, rewardBefore: [size_of(data.RunningStandardizer)]u8
				copy(trainerBefore[:], mem.slice_ptr((^u8)(rawptr(&trainerBox.trainer)), len(trainerBefore)))
				copy(policyBefore[:], mem.slice_ptr((^u8)(rawptr(&policyBox.model)), len(policyBefore)))
				copy(valueBefore[:], mem.slice_ptr((^u8)(rawptr(&valueBox.model)), len(valueBefore)))
				copy(obsBefore[:], mem.slice_ptr((^u8)(rawptr(&observationBox.value)), len(obsBefore)))
				copy(rewardBefore[:], mem.slice_ptr((^u8)(rawptr(&rewardBox.value)), len(rewardBefore)))
				obsMeanBefore, obsM2Before, rewardMeanBefore, rewardM2Before := obsMean.value, obsM2.value, rewardMean.value, rewardM2.value
				state := PPOContextTestAllocator{backing = context.allocator}
				allocator := mem.Allocator{procedure = PPOContextTestAllocatorProc, data = &state}
				result: PPOTrainingContextError
				if normalized {
					result = PPOTrainingContextCheckpointInitNormalized(&trainerBox.trainer, &policyBox.model, &valueBox.model, input, normalizers, 5, allocator = allocator)
				} else {
					result = PPOTrainingContextCheckpointInit(&trainerBox.trainer, &policyBox.model, &valueBox.model, input, 5, allocator = allocator)
				}
				unchanged := PPOContextTestBytesEqual(rawptr(&trainerBox.trainer), trainerBefore[:]) &&
					PPOContextTestBytesEqual(rawptr(&policyBox.model), policyBefore[:]) && PPOContextTestBytesEqual(rawptr(&valueBox.model), valueBefore[:]) &&
					PPOContextTestBytesEqual(rawptr(&observationBox.value), obsBefore[:]) && PPOContextTestBytesEqual(rawptr(&rewardBox.value), rewardBefore[:]) &&
					obsMean.value == obsMeanBefore && obsM2.value == obsM2Before && rewardMean.value == rewardMeanBefore && rewardM2.value == rewardM2Before &&
					PPOContextTestBytesEqual(rawptr(raw_data(input)), candidate[:size])
				testing.expectf(t, result == .CheckpointIncompatible && unchanged && state.attempts == 0,
					"normalized=%v input overlap=%d result=%v unchanged=%v attempts=%d", normalized, i, result, unchanged, state.attempts)
				if result == .None { _ = PPOTrainingContextDestroy(&trainerBox.trainer) }
			}
			// Policy and value cannot occupy the same empty model slot.
			state := PPOContextTestAllocator{backing = context.allocator}
			allocator := mem.Allocator{procedure = PPOContextTestAllocatorProc, data = &state}
			result: PPOTrainingContextError
			if normalized {
				result = PPOTrainingContextCheckpointInitNormalized(&trainerBox.trainer, &policyBox.model, &policyBox.model, original, normalizers, 5, allocator = allocator)
			} else {
				result = PPOTrainingContextCheckpointInit(&trainerBox.trainer, &policyBox.model, &policyBox.model, original, 5, allocator = allocator)
			}
			testing.expect(t, result == .CheckpointIncompatible && state.attempts == 0)
			// An empty trainer embedded at the beginning of an empty model overlaps it.
			embeddedTrainer := (^PPOTrainingContext(2, 3, 2, 2, 3, 2))(rawptr(&policyBox.model))
			if normalized {
				result = PPOTrainingContextCheckpointInitNormalized(embeddedTrainer, &policyBox.model, &valueBox.model, original, normalizers, 5, allocator = allocator)
			} else {
				result = PPOTrainingContextCheckpointInit(embeddedTrainer, &policyBox.model, &valueBox.model, original, 5, allocator = allocator)
			}
			testing.expect(t, result == .CheckpointIncompatible && state.attempts == 0)
		}
		for kind in 0..<2 {
			target: PPOCheckpointInitTestTarget
			testing.expect(t, ppoCheckpointInitTestTargetInit(&target))
			if kind == 0 {
				target.dest.reward.mean = target.dest.observation.mean[:1]
			} else {
				target.dest.observation.mean = mem.slice_ptr((^f64)(rawptr(&target.dest.policy)), 2)
			}
			testing.expect(t, data.RunningStandardizerValid(&target.dest.observation) && data.RunningStandardizerValid(&target.dest.reward))
			_ = ppoCheckpointInitTestReject(t, "overlapping normalizer backing", &target, fixture.bytes[:fixture.size], true,
				.CheckpointIncompatible, ppoCheckpointInitTestNormalizers(&target))
		}
	}

// Run these with an 8 MiB stack: each model itself is larger than that stack.
ppoCheckpointInitLargeRolloutInit :: proc(buffer: ^rl.RolloutBuffer, backing: ^PPOContextTestRolloutBacking) -> bool {
return rl.RolloutBufferInit(buffer, {
	observations = backing.observations[:2], actions = backing.actions[:2], rewards = backing.rewards[:2],
	values = backing.values[:2], nextValues = backing.nextValues[:2], oldLogProbabilities = backing.logs[:2],
	legalActions = backing.legal[:4], terminated = backing.terminated[:2], truncated = backing.truncated[:2],
	advantages = backing.advantages[:2], returns = backing.returns[:2],
}, 2, 1, 2)
}

ppoCheckpointInitLargeCollect :: proc(
policy, value: ^Sequential(1, 1024, 2), state: ^PPOTrainingState, buffer: ^rl.RolloutBuffer,
) -> bool {
if !rl.RolloutBufferReset(buffer) { return false }
for i in 0..<2 {
	observation := [1]f32{f32(i)/2+0.25}
	nextObservation := [1]f32{f32(i)/2+0.75}
	legal := [2]bool{true, true}
	action, logProbability, actionOk := SequentialPolicyAction(policy, observation[:], legal[:], .Stochastic, &state.policyRandomState)
	currentValue, valueOk := SequentialPredictScalar(value, observation[:])
	nextValue, nextOk := SequentialPredictScalar(value, nextObservation[:])
	if !actionOk || !valueOk || !nextOk || !rl.RolloutBufferAppend(buffer, {
		observation = observation[:], action = action, reward = f32(i+1)+f32(action)/4,
		value = currentValue, nextValue = nextValue, oldLogProbability = logProbability,
		legalActions = legal[:], terminated = i == 1,
	}) { return false }
}
return rl.RolloutComputeGAE(buffer, 0.9, 0.95) && rl.RolloutNormalizeAdvantages(buffer)
}

ppoCheckpointInitLargeHeapRoundTrip :: proc(t: ^testing.T, normalized: bool) {
models: PPOStackTestModels
defer PPOStackTestModelsDestroy(&models)
setup := OwnedSequentialInit(&models.policy, 1, 7) && OwnedSequentialInit(&models.value, 1, 11) &&
	OwnedSequentialInit(&models.restoredPolicy, 1, 13) && OwnedSequentialInit(&models.restoredValue, 1, 19)
testing.expect(t, setup && SequentialStorageSize(1, 1024, 2) > 8*1024*1024)
if !setup { return }
policy, value := OwnedSequentialModel(&models.policy), OwnedSequentialModel(&models.value)
restoredPolicy, restoredValue := OwnedSequentialModel(&models.restoredPolicy), OwnedSequentialModel(&models.restoredValue)
setup = policy != nil && value != nil && restoredPolicy != nil && restoredValue != nil
testing.expect(t, setup)
if !setup { return }
testing.expect(t, restoredPolicy.layerCount == 0 && restoredValue.layerCount == 0 &&
	restoredPolicy.self == rawptr(restoredPolicy) && restoredValue.self == rawptr(restoredValue))
setup = SequentialAddDense(policy, 2) && SequentialAddDense(value, 1)
testing.expect(t, setup)
if !setup { return }

sourceStats, restoredStats: PPOStackNormStats
setup = PPOStackNormStatsInit(&sourceStats, 1, 1, true) && PPOStackNormStatsInit(&restoredStats, 1, 1, false)
testing.expect(t, setup)
if !setup { return }
source, restored: PPOTrainingContext(1, 1024, 2, 1, 1024, 2)
defer PPOTrainingContextDestroy(&source)
defer PPOTrainingContextDestroy(&restored)
options := PPOTrainingContextOptionsDefault(2)
options.objective = {0.15, 0.02, 0.6, 0.75}
options.fit = {epochs = 2, batchSize = 1, maxGradientNorm = 0.1, finalLearningRate = 0.002}
options.policySeed, options.shuffleSeed = 12345, 77
options.learningRate, options.beta1, options.beta2, options.epsilon = 0.01, 0.8, 0.95, 1e-6
sourceAllocator, restoredAllocator := PPOContextTestAllocator{backing = context.allocator}, PPOContextTestAllocator{backing = context.allocator}
sourceMem := mem.Allocator{procedure = PPOContextTestAllocatorProc, data = &sourceAllocator}
restoredMem := mem.Allocator{procedure = PPOContextTestAllocatorProc, data = &restoredAllocator}
result := PPOTrainingContextInit(&source, policy, value, options, sourceMem)
testing.expect(t, result == .None)
if result != .None { return }
backing, restoredBacking: PPOContextTestRolloutBacking
buffer, restoredBuffer: rl.RolloutBuffer
setup = ppoCheckpointInitLargeRolloutInit(&buffer, &backing) && ppoCheckpointInitLargeRolloutInit(&restoredBuffer, &restoredBacking)
state, adam := PPOTrainingContextState(&source), PPOTrainingContextOptimizer(&source)
setup = setup && state != nil && adam != nil
testing.expect(t, setup)
if !setup { return }
setup = ppoCheckpointInitLargeCollect(policy, value, state, &buffer) && PPOTrainingContextRecordRollout(&source) == .None
testing.expect(t, setup)
if !setup { return }
stats, fitError := PPOTrainingContextFit(&source, &buffer)
testing.expect(t, fitError == .None && stats.updates == 4 && state.updateCount == 4 && state.rolloutCount == 1 &&
	adam.step == 4 && state.policyRandomState != options.policySeed && state.shuffleRandomState != options.shuffleSeed)
if fitError != .None { return }
nonzeroMoment := false
for moment in adam.firstMoment { if moment != 0 { nonzeroMoment = true; break } }
testing.expect(t, nonzeroMoment && len(adam.parameters) == 4 && len(adam.firstMoment) == 6)

checkpoint, roundTrip, baseScratch, policyScratch, valueScratch: [4096]u8
size: int
saved: bool
if normalized {
	size, saved = PPOCheckpointWriteNormalized(policy, value, adam, state^, source.objective, source.fitConfig,
		{&sourceStats.observation, &sourceStats.reward}, checkpoint[:], baseScratch[:], policyScratch[:], valueScratch[:])
} else {
	writeError: PPOTrainingContextError
	size, writeError = PPOTrainingContextCheckpointWrite(&source, checkpoint[:], policyScratch[:], valueScratch[:])
	saved = writeError == .None
}
testing.expect(t, saved && size > 0 && size <= len(checkpoint))
if !saved || size <= 0 || size > len(checkpoint) { return }
before := checkpoint
info: PPOCheckpointInfo
inspectError: CheckpointError
normalizedInfo: PPONormalizedCheckpointInfo
{
	context.allocator = mem.nil_allocator()
	if normalized {
		normalizedInfo, inspectError = PPOCheckpointInspectNormalized(checkpoint[:size], {maxObservationWidth = 1})
		info = normalizedInfo.base
	} else {
		info, inspectError = PPOCheckpointInspect(checkpoint[:size])
	}
}
testing.expect(t, inspectError.code == .None && info.optimizer == .Adam && info.policy.maxLayers == 1 &&
	info.policy.maxWidth == 1024 && info.policy.batchCapacity == 2 && info.value.maxLayers == 1 &&
	info.value.maxWidth == 1024 && info.value.batchCapacity == 2 && info.policy.inputWidth == 1 &&
	info.policy.outputWidth == 2 && info.value.outputWidth == 1 && info.parameterPointers == 4 && info.momentElements == 6 &&
	info.state == state^ && info.objective == options.objective && info.fit == options.fit && info.step == adam.step)
if normalized {
	testing.expect(t, normalizedInfo.observation.present && normalizedInfo.observation.width == 1 &&
		normalizedInfo.observation.count == sourceStats.observation.count && normalizedInfo.observation.frozen &&
		normalizedInfo.reward.present && normalizedInfo.reward.width == 1 && normalizedInfo.reward.count == sourceStats.reward.count)
}
if inspectError.code != .None { return }
if normalized {
	result = PPOTrainingContextCheckpointInitNormalized(&restored, restoredPolicy, restoredValue, checkpoint[:size],
		{&restoredStats.observation, &restoredStats.reward}, 3, allocator = restoredMem)
} else {
	result = PPOTrainingContextCheckpointInit(&restored, restoredPolicy, restoredValue, checkpoint[:size], 3, allocator = restoredMem)
}
testing.expectf(t, result == .None && checkpoint == before && restoredAllocator.allocations == 4,
	"large heap normalized=%v result=%v allocations=%d", normalized, result, restoredAllocator.allocations)
if result != .None { return }
restoredState, restoredAdam := PPOTrainingContextState(&restored), PPOTrainingContextOptimizer(&restored)
testing.expect(t, restoredState != nil && restoredAdam != nil)
if restoredState == nil || restoredAdam == nil { return }
testing.expect(t, restored.rolloutCapacity == 3 && restored.objective == source.objective && restored.fitConfig == source.fitConfig &&
	restoredState^ == state^ && PPOStackTestAdamEqual(adam, restoredAdam) &&
	PPOStackTestParametersEqual(policy, restoredPolicy) && PPOStackTestParametersEqual(value, restoredValue) &&
	restoredPolicy.self == rawptr(restoredPolicy) && restoredValue.self == rawptr(restoredValue) &&
	restoredPolicy.layerCount == 1 && restoredValue.layerCount == 1)
if normalized {
	testing.expect(t, PPOStackNormEqual(&sourceStats.observation, &restoredStats.observation) &&
		PPOStackNormEqual(&sourceStats.reward, &restoredStats.reward))
}
parameters: [4]^core.Node
bound, elements, boundOk := PPOCheckpointCombinedParameters(restoredPolicy, restoredValue, parameters[:])
testing.expect(t, boundOk && elements == 6 && len(bound) == 4 && len(restoredAdam.parameters) == 4)
if boundOk && len(bound) == 4 && len(restoredAdam.parameters) == 4 {
	for node, i in bound { testing.expect(t, restoredAdam.parameters[i] == node && node != adam.parameters[i]) }
}
if normalized {
	roundSize, ok := PPOCheckpointWriteNormalized(restoredPolicy, restoredValue, restoredAdam, restoredState^,
		restored.objective, restored.fitConfig, {&restoredStats.observation, &restoredStats.reward},
		roundTrip[:], baseScratch[:], policyScratch[:], valueScratch[:])
	testing.expect(t, ok && roundSize == size && PPOContextTestBytesEqual(rawptr(raw_data(roundTrip[:size])), checkpoint[:size]))
} else {
	roundSize, err := PPOTrainingContextCheckpointWrite(&restored, roundTrip[:], policyScratch[:], valueScratch[:])
	testing.expect(t, err == .None && roundSize == size && PPOContextTestBytesEqual(rawptr(raw_data(roundTrip[:size])), checkpoint[:size]))
}
setup = ppoCheckpointInitLargeCollect(policy, value, state, &buffer) &&
	ppoCheckpointInitLargeCollect(restoredPolicy, restoredValue, restoredState, &restoredBuffer)
testing.expect(t, setup && backing == restoredBacking && state^ == restoredState^)
if !setup { return }
testing.expect(t, PPOTrainingContextRecordRollout(&source) == .None && PPOTrainingContextRecordRollout(&restored) == .None)
next, nextError := PPOTrainingContextFit(&source, &buffer)
restoredNext, restoredError := PPOTrainingContextFit(&restored, &restoredBuffer)
testing.expect(t, nextError == .None && restoredError == .None && next == restoredNext && next.updates == 4 &&
	state^ == restoredState^ && state.updateCount == 8 && state.rolloutCount == 2 &&
	PPOStackTestAdamEqual(adam, restoredAdam) && PPOStackTestParametersEqual(policy, restoredPolicy) &&
	PPOStackTestParametersEqual(value, restoredValue))
if normalized {
	testing.expect(t, PPOStackNormEqual(&sourceStats.observation, &restoredStats.observation) &&
		PPOStackNormEqual(&sourceStats.reward, &restoredStats.reward))
}
testing.expect(t, sourceAllocator.allocations == 4 && sourceAllocator.freeCalls == 0 &&
	restoredAllocator.allocations == 4 && restoredAllocator.freeCalls == 0)
testing.expect(t, PPOTrainingContextDestroy(&restored) == .None && PPOTrainingContextDestroy(&source) == .None &&
	restoredAllocator.frees == 4 && sourceAllocator.frees == 4 && restoredAllocator.badFrees == 0 && sourceAllocator.badFrees == 0)
}

@(test)
PPOCheckpointInitLargeHeapBase :: proc(t: ^testing.T) {
ppoCheckpointInitLargeHeapRoundTrip(t, false)
}

@(test)
PPOCheckpointInitLargeHeapNormalized :: proc(t: ^testing.T) {
	ppoCheckpointInitLargeHeapRoundTrip(t, true)
}

PPOCheckpointInitInvalidAllocation :: enum { Short, Misaligned, Wrap }

PPOCheckpointInitInvalidAllocator :: struct {
	backing: mem.Allocator,
	kind: PPOCheckpointInitInvalidAllocation,
	injectAt, attempts, allocations, frees, badFrees: int,
	returned, physical, freeOrder: [4]rawptr,
	requestedSize, returnedSize, alignment: [4]int,
	live, virtual: [4]bool,
}

// Physical storage backs the short/misaligned results. The wrapping result is
// only an address-range probe: neither this allocator nor Free dereferences it.
ppoCheckpointInitInvalidAllocatorProc :: proc(
	data: rawptr, mode: mem.Allocator_Mode, size, alignment: int,
	oldMemory: rawptr, oldSize: int, loc := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	state := (^PPOCheckpointInitInvalidAllocator)(data)
	if mode == .Alloc {
		state.attempts += 1
		i := state.attempts-1
		if i >= len(state.returned) { return nil, .Out_Of_Memory }
		state.requestedSize[i], state.alignment[i] = size, alignment
		injected := state.attempts == state.injectAt
		if injected && state.kind == .Wrap {
			state.returned[i] = rawptr(max(uintptr)-uintptr(alignment-1))
			state.returnedSize[i], state.live[i], state.virtual[i] = size, true, true
			state.allocations += 1
			return mem.slice_ptr((^byte)(state.returned[i]), size), nil
		}
		requested := size
		if injected && state.kind == .Misaligned { requested += alignment }
		bytes, err := state.backing.procedure(state.backing.data, mode, requested, alignment, oldMemory, oldSize, loc)
		if raw_data(bytes) == nil || err != nil { return bytes, err }
		state.physical[i] = rawptr(raw_data(bytes))
		if injected {
			switch state.kind {
			case .Short: bytes = bytes[:size-1]
			case .Misaligned: bytes = bytes[1:size+1]
			case .Wrap:
			}
		}
		state.returned[i], state.returnedSize[i], state.live[i] = rawptr(raw_data(bytes)), len(bytes), true
		state.allocations += 1
		return bytes, nil
	}
	if mode == .Free {
		for pointer, i in state.returned {
			if oldMemory == pointer && pointer != nil && state.live[i] {
				state.freeOrder[state.frees] = oldMemory
				if !state.virtual[i] {
					_, err := state.backing.procedure(state.backing.data, mode, size, alignment, state.physical[i], oldSize, loc)
					if err != nil { return nil, err }
				}
				state.live[i] = false
				state.frees += 1
				return nil, nil
			}
		}
		state.badFrees += 1
		return nil, .Invalid_Pointer
	}
	return state.backing.procedure(state.backing.data, mode, size, alignment, oldMemory, oldSize, loc)
}

@(test)
PPOCheckpointInitInvalidAllocatorRangesAreAtomic :: proc(t: ^testing.T) {
	fixture: NormalizedInspectTestFixture
	built := normalizedInspectTestFixture(&fixture, true, 2, 1)
	testing.expect(t, built)
	if !built { return }
	for normalized in ([2]bool{false, true}) {
		input := fixture.bytes[fixture.baseAt:fixture.size]
		if normalized { input = fixture.bytes[:fixture.size] }
		for position in 1..=4 {
			for kind in ([3]PPOCheckpointInitInvalidAllocation{.Short, .Misaligned, .Wrap}) {
				target: PPOCheckpointInitTestTarget
				setup := ppoCheckpointInitTestTargetInit(&target)
				testing.expect(t, setup)
				if !setup { return }
				before: [size_of(PPOCheckpointInitTestTarget)]u8
				copy(before[:], mem.slice_ptr((^u8)(rawptr(&target)), len(before)))
				inputBefore := fixture.bytes
				state := PPOCheckpointInitInvalidAllocator{backing = context.allocator, kind = kind, injectAt = position}
				allocator := mem.Allocator{procedure = ppoCheckpointInitInvalidAllocatorProc, data = &state}
				result := ppoCheckpointInitTestCall(&target, input, normalized, allocator, ppoCheckpointInitTestNormalizers(&target))
				expected := PPOTrainingContextError.OptimizerSetupFailed
				if position == 1 { expected = .ScratchSetupFailed }
				unchanged := PPOContextTestBytesEqual(rawptr(&target), before[:]) && fixture.bytes == inputBefore
				testing.expectf(t, result == expected && unchanged && state.attempts == position && state.allocations == position &&
					state.frees == position && state.badFrees == 0,
					"normalized=%v position=%d kind=%v result=%v unchanged=%v allocations=%d frees=%d bad=%d",
					normalized, position, kind, result, unchanged, state.allocations, state.frees, state.badFrees)
				for i in 0..<position {
					testing.expect(t, state.freeOrder[i] == state.returned[position-1-i] && !state.live[i])
				}
				i := position-1
				hasInjectedResult := state.returned[i] != nil && state.requestedSize[i] > 1 && state.alignment[i] > 1
				testing.expect(t, hasInjectedResult)
				if !hasInjectedResult {
					_ = PPOTrainingContextDestroy(&target.trainer)
					continue
				}
				switch kind {
				case .Short:
					testing.expect(t, state.returnedSize[i] == state.requestedSize[i]-1 && state.returned[i] == state.physical[i])
				case .Misaligned:
					testing.expect(t, state.returnedSize[i] == state.requestedSize[i] &&
						uintptr(state.returned[i])%uintptr(state.alignment[i]) != 0 && uintptr(state.returned[i]) == uintptr(state.physical[i])+1)
				case .Wrap:
					testing.expect(t, state.virtual[i] && state.physical[i] == nil && state.returnedSize[i] == state.requestedSize[i] &&
						uintptr(state.returned[i])%uintptr(state.alignment[i]) == 0 &&
						uintptr(state.returned[i]) > max(uintptr)-uintptr(state.requestedSize[i]-1))
				}
				if result != expected { _ = PPOTrainingContextDestroy(&target.trainer) }
				testing.expect(t, PPOTrainingContextDestroy(&target.trainer) == .None && state.frees == position && state.badFrees == 0)
			}
		}
	}
}
