package nn

import "../core"
import "../data"
import "core:mem"
import "core:testing"

@(private="file")
ppoMeasureBytesEqual :: proc(data: rawptr, expected: []u8) -> bool {
	actual := mem.slice_ptr((^u8)(data), len(expected))
	for value, index in expected { if actual[index] != value { return false } }
	return true
}

@(private="file")
ppoMeasureTestModels :: proc(
	policy, value: ^Sequential(1, 2, 2), optimizer: ^Adam,
	parameters: []^core.Node, first, second: []f32,
) -> bool {
	if !SequentialInit(policy, 1, 17) || !SequentialAddDense(policy, 2) ||
		!SequentialInit(value, 1, 29) || !SequentialAddDense(value, 1) {
		return false
	}
	combined: [4]^core.Node
	list, elements, ok := PPOCheckpointCombinedParameters(policy, value, combined[:])
	if !ok || len(list) > len(parameters) || elements > len(first) || elements > len(second) { return false }
	copy(parameters, list)
	return AdamInit(optimizer, parameters[:len(list)], first[:elements], second[:elements], learningRate = 0.01)
}

@(test)
PPOCheckpointMeasureBaseExactSizesAndNoMutation :: proc(t: ^testing.T) {
	policy, value: Sequential(1, 2, 2)
	adam: Adam
	modelParameters: [4]^core.Node
	first, second: [6]f32
	initialized := ppoMeasureTestModels(&policy, &value, &adam, modelParameters[:], first[:], second[:])
	testing.expect(t, initialized)
	if !initialized { return }
	state := PPOTrainingState{updateCount = 3, rolloutCount = 4, policyRandomState = 7, shuffleRandomState = 11}
	objective := PPOConfig{0.2, 0.01, 0.5, 1}
	fit := PPOFitConfig{epochs = 2, batchSize = 2, maxGradientNorm = 0.5}

	policyBefore, valueBefore: [size_of(Sequential(1, 2, 2))]u8
	copy(policyBefore[:], mem.slice_ptr((^u8)(rawptr(&policy)), len(policyBefore)))
	copy(valueBefore[:], mem.slice_ptr((^u8)(rawptr(&value)), len(valueBefore)))
	firstBefore, secondBefore := first, second
	step := adam.step

	sizes, repeated: PPOCheckpointBufferSizes
	ok: bool
	{
		context.allocator = mem.panic_allocator()
		context.temp_allocator = mem.panic_allocator()
		sizes, ok = PPOCheckpointMeasure(&policy, &value, &adam, state, objective, fit)
		repeated, _ = PPOCheckpointMeasure(&policy, &value, &adam, state, objective, fit)
	}
	policySize, policyMeasureOk := CheckpointMeasure(&policy, nil, state.policyRandomState)
	valueSize, valueMeasureOk := CheckpointMeasure(&value, nil, state.shuffleRandomState)
	testing.expect(t, ok && repeated == sizes && policyMeasureOk && valueMeasureOk &&
		sizes.policyScratch == policySize && sizes.valueScratch == valueSize && sizes.checkpointScratch == 0 &&
		sizes.output == 112+32+8*len(first)+policySize+valueSize)
	testing.expect(t, adam.step == step && first == firstBefore && second == secondBefore)
	testing.expect(t, ppoMeasureBytesEqual(rawptr(&policy), policyBefore[:]) &&
		ppoMeasureBytesEqual(rawptr(&value), valueBefore[:]))
	if !ok { return }

	output := make([]u8, sizes.output, context.allocator)
	policyScratch := make([]u8, sizes.policyScratch, context.allocator)
	valueScratch := make([]u8, sizes.valueScratch, context.allocator)
	defer {
		delete(output, context.allocator)
		delete(policyScratch, context.allocator)
		delete(valueScratch, context.allocator)
	}
	written, writeOk := PPOCheckpointWrite(&policy, &value, &adam, state, objective, fit, output, policyScratch, valueScratch)
	testing.expect(t, writeOk && written == sizes.output)
	if !writeOk { return }
	short := output[:len(output)-1]
	shot, shortOk := PPOCheckpointWrite(&policy, &value, &adam, state, objective, fit, short, policyScratch, valueScratch)
	testing.expect(t, !shortOk && shot == 0)
	shortPolicy := policyScratch[:len(policyScratch)-1]
	shortPolicyOk, shortValueOk: bool
	written, shortPolicyOk = PPOCheckpointWrite(&policy, &value, &adam, state, objective, fit, output, shortPolicy, valueScratch)
	testing.expect(t, !shortPolicyOk && written == 0)
	written, shortValueOk = PPOCheckpointWrite(&policy, &value, &adam, state, objective, fit, output, policyScratch, valueScratch[:len(valueScratch)-1])
	testing.expect(t, !shortValueOk && written == 0)
}

@(test)
PPOCheckpointMeasureNormalizedExactSizes :: proc(t: ^testing.T) {
	policy, value: Sequential(1, 2, 2)
	adam: Adam
	modelParameters: [4]^core.Node
	firstMoments, secondMoments: [6]f32
	initialized := ppoMeasureTestModels(&policy, &value, &adam, modelParameters[:], firstMoments[:], secondMoments[:])
	testing.expect(t, initialized)
	if !initialized { return }
	observationMean, observationM2: [1]f64
	rewardMean, rewardM2: [1]f64
	observation, reward: data.RunningStandardizer
	testing.expect(t, data.RunningStandardizerInit(&observation, observationMean[:], observationM2[:], epsilon = 0.02) &&
		data.RunningStandardizerInit(&reward, rewardMean[:1], rewardM2[:1], epsilon = 0.03))
	testing.expect(t, data.RunningStandardizerSetMetadata(&observation, 2, 0.02, true) &&
		data.RunningStandardizerSetMetadata(&reward, 3, 0.03, false))
	normalizers := PPOTrainingNormalizers{&observation, &reward}
	state := PPOTrainingState{updateCount = 1, rolloutCount = 2, policyRandomState = 5, shuffleRandomState = 6}
	objective := PPOConfig{0.2, 0.01, 0.5, 1}
	fit := PPOFitConfig{epochs = 2, batchSize = 2}
	base: PPOCheckpointBufferSizes
	normalized: PPOCheckpointBufferSizes
	baseOk, normalizedOk: bool
	{
		context.allocator = mem.panic_allocator()
		context.temp_allocator = mem.panic_allocator()
		base, baseOk = PPOCheckpointMeasure(&policy, &value, &adam, state, objective, fit)
		normalized, normalizedOk = PPOCheckpointMeasureNormalized(&policy, &value, &adam, state, objective, fit, normalizers)
	}
	observationBytes, observationSizeOk := PPOCheckpointNormalizerByteSize(&observation)
	rewardBytes, rewardSizeOk := PPOCheckpointNormalizerByteSize(&reward)
	testing.expectf(t, baseOk && normalizedOk && observationSizeOk && rewardSizeOk &&
		normalized.output == 24+observationBytes+rewardBytes+base.output &&
		normalized.checkpointScratch == base.output && normalized.policyScratch == base.policyScratch &&
		normalized.valueScratch == base.valueScratch,
		"base %v/%v norm %v/%v obs %v reward %v", baseOk, base, normalizedOk, normalized, observationBytes, rewardBytes)
	if !normalizedOk { return }
	output := make([]u8, normalized.output, context.allocator)
	checkpointScratch := make([]u8, normalized.checkpointScratch, context.allocator)
	policyScratch := make([]u8, normalized.policyScratch, context.allocator)
	valueScratch := make([]u8, normalized.valueScratch, context.allocator)
	defer {
		delete(output, context.allocator)
		delete(checkpointScratch, context.allocator)
		delete(policyScratch, context.allocator)
		delete(valueScratch, context.allocator)
	}
	written, ok := PPOCheckpointWriteNormalized(&policy, &value, &adam, state, objective, fit, normalizers, output, checkpointScratch, policyScratch, valueScratch)
	testing.expect(t, ok && written == normalized.output)
	written, ok = PPOCheckpointWriteNormalized(&policy, &value, &adam, state, objective, fit, normalizers,
		output[:len(output)-1], checkpointScratch, policyScratch, valueScratch)
	testing.expect(t, !ok && written == 0)
	written, ok = PPOCheckpointWriteNormalized(&policy, &value, &adam, state, objective, fit, normalizers,
		output, checkpointScratch[:len(checkpointScratch)-1], policyScratch, valueScratch)
	testing.expect(t, !ok && written == 0)
}

@(test)
PPOCheckpointMeasureRejectsInvalidConfiguration :: proc(t: ^testing.T) {
	policy, value: Sequential(1, 2, 2)
	adam: Adam
	parameters: [4]^core.Node
	first, second: [6]f32
	initialized := ppoMeasureTestModels(&policy, &value, &adam, parameters[:], first[:], second[:])
	testing.expect(t, initialized)
	if !initialized { return }
	state := PPOTrainingState{policyRandomState = 1, shuffleRandomState = 2}
	objective := PPOConfig{0.2, 0.01, 0.5, 1}
	fit := PPOFitConfig{epochs = 2, batchSize = 2}
	observationMean, observationM2: [2]f64
	observation: data.RunningStandardizer
	testing.expect(t, data.RunningStandardizerInit(&observation, observationMean[:], observationM2[:]))
	invalid: PPOConfig
	invalidFit: PPOFitConfig
	missingState: PPOTrainingState
	badSizes: PPOCheckpointBufferSizes
	missingPolicy: ^Sequential(1, 2, 2)
	missingValue: ^Sequential(1, 2, 2)
	ok1, ok2, ok3, ok4, ok5, ok6: bool
	{
		context.allocator = mem.nil_allocator()
		context.temp_allocator = mem.nil_allocator()
		badSizes, ok1 = PPOCheckpointMeasure(missingPolicy, &value, &adam, state, objective, fit)
		badSizes, ok2 = PPOCheckpointMeasure(&policy, missingValue, &adam, state, objective, fit)
		badSizes, ok3 = PPOCheckpointMeasure(&policy, &value, &adam, missingState, objective, fit)
		invalid = objective; invalid.clipRange = 1
		badSizes, ok4 = PPOCheckpointMeasure(&policy, &value, &adam, state, invalid, fit)
		invalidFit = fit; invalidFit.epochs = 0
		badSizes, ok5 = PPOCheckpointMeasure(&policy, &value, &adam, state, objective, invalidFit)
		badSizes, ok6 = PPOCheckpointMeasureNormalized(&policy, &value, &adam, state, objective, fit, {&observation, nil})
	}
	testing.expect(t, !ok1 && !ok2 && !ok3 && !ok4 && !ok5 && !ok6 && badSizes == (PPOCheckpointBufferSizes{}))
	missingOptimizer: SequentialOptimizer
	badSizes, ok1 = PPOCheckpointMeasure(&policy, &value, missingOptimizer, state, objective, fit)
	testing.expect(t, !ok1 && badSizes == (PPOCheckpointBufferSizes{}))
}
