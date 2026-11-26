package nn

import "../core"
import "../data"

PPO_NORMALIZED_CHECKPOINT_MAGIC :: u64(0x31504e434f505050)
PPO_NORMALIZED_CHECKPOINT_VERSION :: u64(1)
POLICY_EXPORT_MAGIC :: u64(0x3154505845505050)
POLICY_EXPORT_VERSION :: u64(1)

// PPOTrainingNormalizers are optional, caller-owned observation and reward
// running statistics. Use the normalized checkpoint/export APIs whenever either
// normalizer affects collection or inference.
PPOTrainingNormalizers :: struct {
	observation: ^data.RunningStandardizer,
	reward:      ^data.RunningStandardizer,
}

PPOCheckpointNormalizerDescriptor :: struct {
	present:    bool,
	count:      u64,
	width:      int,
	epsilon:    f64,
	frozen:     bool,
	meanOffset: int,
	m2Offset:   int,
}

PPOCheckpointPutF64 :: proc(output: []u8, offset: ^int, value: f64) {
	CheckpointPut64(output, offset, transmute(u64)value)
}

PPOCheckpointGetF64 :: proc(input: []u8, offset: ^int) -> (f64, bool) {
	bits, ok := CheckpointGet64(input, offset)
	if !ok do return 0, false
	return transmute(f64)bits, true
}

PPOCheckpointNormalizerByteSize :: proc(normalizer: ^data.RunningStandardizer) -> (int, bool) {
	if normalizer == nil do return 8, true
	if !data.RunningStandardizerValid(normalizer) do return 0, false
	width := len(normalizer.mean)
	if width > (max(int)-40)/16 do return 0, false
	return 40+16*width, true
}

PPOCheckpointPutNormalizer :: proc(
	output: []u8,
	offset: ^int,
	normalizer: ^data.RunningStandardizer,
) {
	if normalizer == nil {
		CheckpointPut64(output, offset, 0)
		return
	}
	CheckpointPut64(output, offset, 1)
	CheckpointPut64(output, offset, normalizer.count)
	CheckpointPut64(output, offset, u64(len(normalizer.mean)))
	PPOCheckpointPutF64(output, offset, normalizer.epsilon)
	CheckpointPut64(output, offset, u64(normalizer.frozen))
	for item in normalizer.mean { PPOCheckpointPutF64(output, offset, item) }
	for item in normalizer.m2 { PPOCheckpointPutF64(output, offset, item) }
}

PPOCheckpointGetNormalizer :: proc(
	input: []u8,
	offset: ^int,
) -> (descriptor: PPOCheckpointNormalizerDescriptor, ok: bool) {
	present, presentOk := CheckpointGet64(input, offset)
	if !presentOk || present > 1 do return {}, false
	if present == 0 { return PPOCheckpointNormalizerDescriptor{}, true }
	count, countOk := CheckpointGet64(input, offset)
	width64, widthOk := CheckpointGet64(input, offset)
	if !countOk || !widthOk || width64 == 0 || width64 > u64(max(int)) do return {}, false
	epsilon, epsilonOk := PPOCheckpointGetF64(input, offset)
	frozen, frozenOk := CheckpointGet64(input, offset)
	if !epsilonOk || !frozenOk || frozen > 1 || frozen == 1 && count == 0 ||
		!data.RunningFiniteF64(epsilon) || epsilon <= 0 {
		return {}, false
	}
	width := int(width64)
	if width > (len(input)-offset^)/16 do return {}, false
	descriptor = PPOCheckpointNormalizerDescriptor{
		present = true,
		count = count,
		width = width,
		epsilon = epsilon,
		frozen = frozen == 1,
		meanOffset = offset^,
		m2Offset = offset^+width*8,
	}
	for _ in 0..<width {
		mean, readOk := PPOCheckpointGetF64(input, offset)
		if !readOk || !data.RunningFiniteF64(mean) || count == 0 && mean != 0 do return {}, false
	}
	for _ in 0..<width {
		m2, readOk := PPOCheckpointGetF64(input, offset)
		if !readOk || !data.RunningFiniteF64(m2) || m2 < 0 || count == 0 && m2 != 0 do return {}, false
	}
	return descriptor, true
}

PPOCheckpointPeekModelPayloads :: proc(input: []u8) -> (policyInput, valueInput: []u8, ok: bool) {
	offset := 0
	magic, magicOk := CheckpointGet64(input, &offset)
	version, versionOk := CheckpointGet64(input, &offset)
	policySize64, policySizeOk := CheckpointGet64(input, &offset)
	valueSize64, valueSizeOk := CheckpointGet64(input, &offset)
	if !magicOk || !versionOk || !policySizeOk || !valueSizeOk || magic != PPO_CHECKPOINT_MAGIC ||
		version != PPO_CHECKPOINT_VERSION || policySize64 > u64(max(int)) || valueSize64 > u64(max(int)) {
		return nil, nil, false
	}
	if len(input)-offset < 32+16+24+8 do return nil, nil, false
	offset += 32+16+24
	kind, kindOk := CheckpointGet64(input, &offset)
	if !kindOk || kind > 1 do return nil, nil, false
	if kind == 0 {
		if len(input)-offset < 4 do return nil, nil, false
		offset += 4
	} else {
		if len(input)-offset < 32 do return nil, nil, false
		offset += 24
		elementCount, elementCountOk := CheckpointGet64(input, &offset)
		if !elementCountOk || elementCount > u64(max(int)) || elementCount > u64((len(input)-offset)/8) {
			return nil, nil, false
		}
		offset += int(elementCount)*8
	}
	if policySize64 > u64(len(input)-offset) || valueSize64 > u64(len(input)-offset)-policySize64 ||
		policySize64+valueSize64 != u64(len(input)-offset) {
		return nil, nil, false
	}
	policySize := int(policySize64)
	policyInput = input[offset:offset+policySize]
	offset += policySize
	valueInput = input[offset:]
	return policyInput, valueInput, true
}

PPOCheckpointNormalizerTargetValid :: proc(
	descriptor: PPOCheckpointNormalizerDescriptor,
	normalizer: ^data.RunningStandardizer,
) -> bool {
	if descriptor.present != (normalizer != nil) do return false
	if !descriptor.present do return true
	return data.RunningStandardizerValid(normalizer) &&
		len(normalizer.mean) == descriptor.width && len(normalizer.m2) == descriptor.width
}

PPOCheckpointApplyNormalizer :: proc(
	input: []u8,
	descriptor: PPOCheckpointNormalizerDescriptor,
	normalizer: ^data.RunningStandardizer,
) {
	if !descriptor.present do return
	meanOffset, m2Offset := descriptor.meanOffset, descriptor.m2Offset
	for index in 0..<descriptor.width {
		normalizer.mean[index], _ = PPOCheckpointGetF64(input, &meanOffset)
		 normalizer.m2[index], _ = PPOCheckpointGetF64(input, &m2Offset)
	}
	_ = data.RunningStandardizerSetMetadata(
		normalizer, descriptor.count, descriptor.epsilon, descriptor.frozen,
	)
}

PPOCheckpointAppendRange :: proc(
	ranges: []PPOFitMemoryRange,
	count: ^int,
	dataPointer: rawptr,
	elementCount, elementSize: int,
) -> bool {
	if count == nil || count^ < 0 || count^ >= len(ranges) do return false
	range, ok := PPOCheckpointRange(dataPointer, elementCount, elementSize)
	if !ok do return false
	ranges[count^] = range
	count^ += 1
	return true
}

PPOCheckpointAppendNormalizerRanges :: proc(
	ranges: []PPOFitMemoryRange,
	count: ^int,
	normalizer: ^data.RunningStandardizer,
) -> bool {
	if normalizer == nil do return true
	return PPOCheckpointAppendRange(ranges, count, rawptr(normalizer), 1, size_of(data.RunningStandardizer)) &&
		PPOCheckpointAppendRange(ranges, count, rawptr(raw_data(normalizer.mean)), len(normalizer.mean), size_of(f64)) &&
		PPOCheckpointAppendRange(ranges, count, rawptr(raw_data(normalizer.m2)), len(normalizer.m2), size_of(f64))
}

PPOCheckpointNormalizedWriteDisjoint :: proc(
	policy: rawptr, policySize: int,
	value: rawptr, valueSize: int,
	adam: ^Adam,
	output, checkpointScratch, policyScratch, valueScratch: []u8,
	normalizers: PPOTrainingNormalizers,
) -> bool {
	ranges: [16]PPOFitMemoryRange
	count := 0
	if !PPOCheckpointAppendRange(ranges[:], &count, rawptr(raw_data(output)), len(output), size_of(u8)) ||
		!PPOCheckpointAppendRange(ranges[:], &count, rawptr(raw_data(checkpointScratch)), len(checkpointScratch), size_of(u8)) ||
		!PPOCheckpointAppendRange(ranges[:], &count, rawptr(raw_data(policyScratch)), len(policyScratch), size_of(u8)) ||
		!PPOCheckpointAppendRange(ranges[:], &count, rawptr(raw_data(valueScratch)), len(valueScratch), size_of(u8)) ||
		!PPOCheckpointAppendRange(ranges[:], &count, policy, 1, policySize) ||
		!PPOCheckpointAppendRange(ranges[:], &count, value, 1, valueSize) ||
		!PPOCheckpointAppendNormalizerRanges(ranges[:], &count, normalizers.observation) ||
		!PPOCheckpointAppendNormalizerRanges(ranges[:], &count, normalizers.reward) {
		return false
	}
	if adam != nil {
		if !PPOCheckpointAppendRange(ranges[:], &count, rawptr(adam), 1, size_of(Adam)) ||
			!PPOCheckpointAppendRange(ranges[:], &count, rawptr(raw_data(adam.parameters)), len(adam.parameters), size_of(^core.Node)) ||
			!PPOCheckpointAppendRange(ranges[:], &count, rawptr(raw_data(adam.firstMoment)), len(adam.firstMoment), size_of(f32)) ||
			!PPOCheckpointAppendRange(ranges[:], &count, rawptr(raw_data(adam.secondMoment)), len(adam.secondMoment), size_of(f32)) {
			return false
		}
	}
	return PPOCheckpointRangesDisjoint(ranges[:count])
}

PPOCheckpointNormalizedReadDisjoint :: proc(
	input: []u8,
	policy: rawptr, policySize: int,
	value: rawptr, valueSize: int,
	adam: ^Adam,
	parameterStorage: []^core.Node,
	firstMoment, secondMoment: []f32,
	normalizers: PPOTrainingNormalizers,
) -> bool {
	ranges: [13]PPOFitMemoryRange
	count := 0
	if !PPOCheckpointAppendRange(ranges[:], &count, rawptr(raw_data(input)), len(input), size_of(u8)) ||
		!PPOCheckpointAppendRange(ranges[:], &count, policy, 1, policySize) ||
		!PPOCheckpointAppendRange(ranges[:], &count, value, 1, valueSize) ||
		!PPOCheckpointAppendNormalizerRanges(ranges[:], &count, normalizers.observation) ||
		!PPOCheckpointAppendNormalizerRanges(ranges[:], &count, normalizers.reward) {
		return false
	}
	if len(parameterStorage) > 0 && !PPOCheckpointAppendRange(
		ranges[:], &count, rawptr(raw_data(parameterStorage)), len(parameterStorage), size_of(^core.Node),
	) { return false }
	if len(firstMoment) > 0 && !PPOCheckpointAppendRange(
		ranges[:], &count, rawptr(raw_data(firstMoment)), len(firstMoment), size_of(f32),
	) { return false }
	if len(secondMoment) > 0 && !PPOCheckpointAppendRange(
		ranges[:], &count, rawptr(raw_data(secondMoment)), len(secondMoment), size_of(f32),
	) { return false }
	if adam != nil && !PPOCheckpointAppendRange(ranges[:], &count, rawptr(adam), 1, size_of(Adam)) {
		return false
	}
	return PPOCheckpointRangesDisjoint(ranges[:count])
}

PPOTrainingNormalizerTargetsValid :: proc(normalizers: PPOTrainingNormalizers) -> bool {
	if normalizers.observation != nil && !data.RunningStandardizerValid(normalizers.observation) do return false
	if normalizers.reward != nil && !data.RunningStandardizerValid(normalizers.reward) do return false
	return true
}

// Writes both PPO learner state and optional observation/reward running moments.
// This wrapper is required whenever normalization is used; the base checkpoint
// API intentionally has no normalizer dependency. All scratch, output, models,
// optimizer and normalizer storage must be disjoint.
PPOCheckpointWriteNormalized :: proc(
	policy: ^Sequential($policyMaxLayers, $policyMaxWidth, $policyBatchCapacity),
	value: ^Sequential($valueMaxLayers, $valueMaxWidth, $valueBatchCapacity),
	optimizer: SequentialOptimizer,
	state: PPOTrainingState,
	ppoConfig: PPOConfig,
	fitConfig: PPOFitConfig,
	normalizers: PPOTrainingNormalizers,
	output, checkpointScratch, policyScratch, valueScratch: []u8,
) -> (int, bool) {
	if policy == nil || value == nil || !PPOTrainingNormalizerTargetsValid(normalizers) ||
		normalizers.observation != nil && len(normalizers.observation.mean) != policy.inputWidth ||
		normalizers.reward != nil && len(normalizers.reward.mean) != 1 {
		return 0, false
	}
	policyNormalizerBytes, policyNormalizerOk := PPOCheckpointNormalizerByteSize(normalizers.observation)
	rewardNormalizerBytes, rewardNormalizerOk := PPOCheckpointNormalizerByteSize(normalizers.reward)
	if !policyNormalizerOk || !rewardNormalizerOk do return 0, false
	adam: ^Adam
	switch item in optimizer {
	case ^Adam: adam = item
	case SequentialSGD:
	}
	if !PPOCheckpointNormalizedWriteDisjoint(
		rawptr(policy), size_of(Sequential(policyMaxLayers, policyMaxWidth, policyBatchCapacity)),
		rawptr(value), size_of(Sequential(valueMaxLayers, valueMaxWidth, valueBatchCapacity)),
		adam, output, checkpointScratch, policyScratch, valueScratch, normalizers,
	) { return 0, false }
	baseSize, baseOk := PPOCheckpointWrite(
		policy, value, optimizer, state, ppoConfig, fitConfig,
		checkpointScratch, policyScratch, valueScratch,
	)
	if !baseOk do return 0, false
	fixedSize := 24+policyNormalizerBytes+rewardNormalizerBytes
	if baseSize > max(int)-fixedSize do return 0, false
	totalSize := fixedSize+baseSize
	if len(output) < totalSize do return 0, false
	offset := 0
	CheckpointPut64(output, &offset, PPO_NORMALIZED_CHECKPOINT_MAGIC)
	CheckpointPut64(output, &offset, PPO_NORMALIZED_CHECKPOINT_VERSION)
	CheckpointPut64(output, &offset, u64(baseSize))
	PPOCheckpointPutNormalizer(output, &offset, normalizers.observation)
	PPOCheckpointPutNormalizer(output, &offset, normalizers.reward)
	copy(output[offset:offset+baseSize], checkpointScratch[:baseSize])
	offset += baseSize
	return offset, true
}

// Reads the normalized training format. Normalizer targets must be initialized
// with the expected feature widths and caller-owned storage. The base PPO reader
// preflights both models before commit; normalization moments are copied only
// after that succeeds.
PPOCheckpointReadNormalized :: proc(
	policy: ^Sequential($policyMaxLayers, $policyMaxWidth, $policyBatchCapacity),
	value: ^Sequential($valueMaxLayers, $valueMaxWidth, $valueBatchCapacity),
	input: []u8,
	restoredAdam: ^Adam,
	parameterStorage: []^core.Node,
	firstMoment, secondMoment: []f32,
	normalizers: PPOTrainingNormalizers,
) -> (state: PPOTrainingState, ppoConfig: PPOConfig, fitConfig: PPOFitConfig, optimizer: SequentialOptimizer, ok: bool) {
	offset := 0
	magic, magicOk := CheckpointGet64(input, &offset)
	version, versionOk := CheckpointGet64(input, &offset)
	baseSize64, baseSizeOk := CheckpointGet64(input, &offset)
	if !magicOk || !versionOk || !baseSizeOk || magic != PPO_NORMALIZED_CHECKPOINT_MAGIC ||
		version != PPO_NORMALIZED_CHECKPOINT_VERSION || baseSize64 > u64(max(int)) {
		return {}, {}, {}, nil, false
	}
	observationDescriptor, observationOk := PPOCheckpointGetNormalizer(input, &offset)
	rewardDescriptor, rewardOk := PPOCheckpointGetNormalizer(input, &offset)
	if !observationOk || !rewardOk ||
		!PPOCheckpointNormalizerTargetValid(observationDescriptor, normalizers.observation) ||
		!PPOCheckpointNormalizerTargetValid(rewardDescriptor, normalizers.reward) {
		return {}, {}, {}, nil, false
	}
	if baseSize64 != u64(len(input)-offset) do return {}, {}, {}, nil, false
	if !PPOCheckpointNormalizedReadDisjoint(
		input,
		rawptr(policy), size_of(Sequential(policyMaxLayers, policyMaxWidth, policyBatchCapacity)),
		rawptr(value), size_of(Sequential(valueMaxLayers, valueMaxWidth, valueBatchCapacity)),
		restoredAdam, parameterStorage, firstMoment, secondMoment, normalizers,
	) { return {}, {}, {}, nil, false }
	baseInput := input[offset:]
	policyInput, valueInput, payloadsOk := PPOCheckpointPeekModelPayloads(baseInput)
	if !payloadsOk do return {}, {}, {}, nil, false
	policyProbe: Sequential(policyMaxLayers, policyMaxWidth, policyBatchCapacity)
	valueProbe: Sequential(valueMaxLayers, valueMaxWidth, valueBatchCapacity)
	probeState: u64
	if !CheckpointRead(&policyProbe, nil, &probeState, policyInput, nil, nil, nil) ||
		!CheckpointRead(&valueProbe, nil, &probeState, valueInput, nil, nil, nil) ||
		observationDescriptor.present && observationDescriptor.width != policyProbe.inputWidth ||
		rewardDescriptor.present && rewardDescriptor.width != 1 {
		return {}, {}, {}, nil, false
	}
	restoredState, restoredPPOConfig, restoredFitConfig, restoredOptimizer, readOk := PPOCheckpointRead(
		policy, value, baseInput, restoredAdam, parameterStorage, firstMoment, secondMoment,
	)
	if !readOk do return {}, {}, {}, nil, false
	PPOCheckpointApplyNormalizer(input, observationDescriptor, normalizers.observation)
	PPOCheckpointApplyNormalizer(input, rewardDescriptor, normalizers.reward)
	return restoredState, restoredPPOConfig, restoredFitConfig, restoredOptimizer, true
}

PPOPolicyExportModelValid :: proc(model: ^Sequential($maxLayers, $maxWidth, $batchCapacity)) -> bool {
	parameterStorage: [2*maxLayers]^core.Node
	nodeStorage: [1+3*maxLayers]^core.Node
	_, _, valid := PPOSequentialParametersAndNodes(model, parameterStorage[:], nodeStorage[:])
	if !valid || model.layers[model.layerCount-1].width <= 0 ||
		len(model.layers[model.layerCount-1].output.value.shape) != 2 ||
		model.layers[model.layerCount-1].output.value.shape[1] != model.layers[model.layerCount-1].width {
		return false
	}
	if _, isSoftmax := SequentialLogitsOutputLayer(model).(^Softmax); isSoftmax do return false
	return true
}

// Inference-only export contains one categorical policy and optional observation
// normalization state, but no critic, optimizer, counters or training RNG. Action
// sampling still takes a caller-owned evaluation RNG through SequentialPolicyAction.
PPOPolicyExportWrite :: proc(
	policy: ^Sequential($maxLayers, $maxWidth, $batchCapacity),
	observationNormalizer: ^data.RunningStandardizer,
	output, modelScratch: []u8,
) -> (int, bool) {
	if !PPOPolicyExportModelValid(policy) || observationNormalizer != nil &&
		(!data.RunningStandardizerValid(observationNormalizer) || len(observationNormalizer.mean) != policy.inputWidth) {
		return 0, false
	}
	normalizerBytes, normalizerOk := PPOCheckpointNormalizerByteSize(observationNormalizer)
	if !normalizerOk do return 0, false
	ranges: [6]PPOFitMemoryRange
	rangeCount := 0
	if !PPOCheckpointAppendRange(ranges[:], &rangeCount, rawptr(raw_data(output)), len(output), size_of(u8)) ||
		!PPOCheckpointAppendRange(ranges[:], &rangeCount, rawptr(raw_data(modelScratch)), len(modelScratch), size_of(u8)) ||
		!PPOCheckpointAppendRange(ranges[:], &rangeCount, rawptr(policy), 1, size_of(Sequential(maxLayers, maxWidth, batchCapacity))) ||
		!PPOCheckpointAppendNormalizerRanges(ranges[:], &rangeCount, observationNormalizer) ||
		!PPOCheckpointRangesDisjoint(ranges[:rangeCount]) {
		return 0, false
	}
	modelSize, modelOk := CheckpointWrite(policy, nil, 0, modelScratch)
	if !modelOk || modelSize > max(int)-24-normalizerBytes do return 0, false
	totalSize := 24+normalizerBytes+modelSize
	if len(output) < totalSize do return 0, false
	offset := 0
	CheckpointPut64(output, &offset, POLICY_EXPORT_MAGIC)
	CheckpointPut64(output, &offset, POLICY_EXPORT_VERSION)
	CheckpointPut64(output, &offset, u64(modelSize))
	PPOCheckpointPutNormalizer(output, &offset, observationNormalizer)
	copy(output[offset:offset+modelSize], modelScratch[:modelSize])
	offset += modelSize
	return offset, true
}

// Loads an inference-only categorical policy and optional observation moments.
// Initialize the normalizer with the expected input width before loading.
PPOPolicyExportRead :: proc(
	policy: ^Sequential($maxLayers, $maxWidth, $batchCapacity),
	input: []u8,
	observationNormalizer: ^data.RunningStandardizer,
) -> bool {
	offset := 0
	magic, magicOk := CheckpointGet64(input, &offset)
	version, versionOk := CheckpointGet64(input, &offset)
	modelSize64, modelSizeOk := CheckpointGet64(input, &offset)
	if !magicOk || !versionOk || !modelSizeOk || magic != POLICY_EXPORT_MAGIC ||
		version != POLICY_EXPORT_VERSION || modelSize64 > u64(max(int)) {
		return false
	}
	descriptor, descriptorOk := PPOCheckpointGetNormalizer(input, &offset)
	if !descriptorOk || !PPOCheckpointNormalizerTargetValid(descriptor, observationNormalizer) ||
		modelSize64 != u64(len(input)-offset) {
		return false
	}
	inputRange, inputOk := PPOCheckpointRange(rawptr(raw_data(input)), len(input), size_of(u8))
	modelRange, modelOk := PPOCheckpointRange(rawptr(policy), 1, size_of(Sequential(maxLayers, maxWidth, batchCapacity)))
	if !inputOk || !modelOk || PPOFitMemoryRangesOverlap(inputRange, modelRange) do return false
	ranges: [6]PPOFitMemoryRange
	rangeCount := 0
	ranges[rangeCount] = inputRange; rangeCount += 1
	ranges[rangeCount] = modelRange; rangeCount += 1
	if !PPOCheckpointAppendNormalizerRanges(ranges[:], &rangeCount, observationNormalizer) ||
		!PPOCheckpointRangesDisjoint(ranges[:rangeCount]) {
		return false
	}
	modelInput := input[offset:]
	probe: Sequential(maxLayers, maxWidth, batchCapacity)
	innerState: u64
	if !CheckpointRead(&probe, nil, &innerState, modelInput, nil, nil, nil) || !PPOPolicyExportModelValid(&probe) {
		return false
	}
	if descriptor.present && descriptor.width != probe.inputWidth do return false
	if !CheckpointRead(policy, nil, &innerState, modelInput, nil, nil, nil) do return false
	PPOCheckpointApplyNormalizer(input, descriptor, observationNormalizer)
	return true
}
