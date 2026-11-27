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

// Metadata needed to provision a normalizer for a later owned restore. An absent
// normalizer has all-zero metadata. Moments are validated during inspection but
// remain in the checkpoint input.
PPOCheckpointNormalizerInfo :: struct {
	present: bool,
	count:   u64,
	width:   int,
	epsilon: f64,
	frozen:  bool,
}

PPONormalizedCheckpointInfo :: struct {
	base:                PPOCheckpointInfo,
	observation, reward: PPOCheckpointNormalizerInfo,
}

// Zero disables a limit; negative limits are invalid. maxBytes applies to the
// entire normalized input, while base limits apply to the embedded PPO payload.
// maxObservationWidth bounds the policy input even without a normalizer. It
// rejects an oversized descriptor before scanning its moments, or an oversized
// policy input header before scanning model parameters or optimizer moments.
PPONormalizedCheckpointInspectLimits :: struct {
	maxBytes, maxObservationWidth: int,
	base: PPOCheckpointInspectLimits,
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

// Shared by normalized checkpoints and policy exports. Empty normalizers may
// be frozen, but their moments must still be zero.
@(private="file")
ppoCheckpointParseNormalizer :: proc(
	input: []u8,
	offset: ^int,
	maxWidth, requiredWidth: int,
) -> (PPOCheckpointNormalizerDescriptor, CheckpointError) {
	presentOffset := offset^
	present, ok := CheckpointGet64(input, offset)
	if !ok { return {}, {.Truncated, len(input)} }
	if present > 1 { return {}, {.InvalidHeader, presentOffset} }
	if present == 0 { return {}, {} }
	count, countOk := CheckpointGet64(input, offset)
	if !countOk { return {}, {.Truncated, len(input)} }
	widthOffset := offset^
	width64, widthOk := CheckpointGet64(input, offset)
	if !widthOk { return {}, {.Truncated, len(input)} }
	if width64 == 0 { return {}, {.InvalidHeader, widthOffset} }
	if width64 > u64(max(int)) { return {}, {.Overflow, widthOffset} }
	if maxWidth > 0 && width64 > u64(maxWidth) { return {}, {.LimitExceeded, widthOffset} }
	if requiredWidth > 0 && width64 != u64(requiredWidth) { return {}, {.InvalidArchitecture, widthOffset} }
	epsilonOffset := offset^
	epsilon, epsilonOk := PPOCheckpointGetF64(input, offset)
	if !epsilonOk { return {}, {.Truncated, len(input)} }
	if !data.RunningFiniteF64(epsilon) || epsilon <= 0 { return {}, {.InvalidValue, epsilonOffset} }
	frozenOffset := offset^
	frozen, frozenOk := CheckpointGet64(input, offset)
	if !frozenOk { return {}, {.Truncated, len(input)} }
	if frozen > 1 { return {}, {.InvalidHeader, frozenOffset} }
	width := int(width64)
	if width > (max(int)-offset^)/16 { return {}, {.Overflow, widthOffset} }
	if width > (len(input)-offset^)/16 { return {}, {.Truncated, len(input)} }
	descriptor := PPOCheckpointNormalizerDescriptor{
		present = true,
		count = count,
		width = width,
		epsilon = epsilon,
		frozen = frozen == 1,
		meanOffset = offset^,
		m2Offset = offset^+width*8,
	}
	for _ in 0..<width {
		at := offset^
		mean, _ := PPOCheckpointGetF64(input, offset)
		if !data.RunningFiniteF64(mean) || count == 0 && mean != 0 { return {}, {.InvalidValue, at} }
	}
	for _ in 0..<width {
		at := offset^
		m2, _ := PPOCheckpointGetF64(input, offset)
		if !data.RunningFiniteF64(m2) || m2 < 0 || count == 0 && m2 != 0 { return {}, {.InvalidValue, at} }
	}
	return descriptor, {}
}

PPOCheckpointGetNormalizer :: proc(
	input: []u8,
	offset: ^int,
) -> (PPOCheckpointNormalizerDescriptor, bool) {
	descriptor, err := ppoCheckpointParseNormalizer(input, offset, 0, 0)
	return descriptor, err.code == .None
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

@(private="file")
ppoNormalizedCheckpointWriteLayout :: proc(
	policy: ^Sequential($policyMaxLayers, $policyMaxWidth, $policyBatchCapacity),
	value: ^Sequential($valueMaxLayers, $valueMaxWidth, $valueBatchCapacity),
	optimizer: SequentialOptimizer, state: PPOTrainingState, ppoConfig: PPOConfig, fitConfig: PPOFitConfig,
	normalizers: PPOTrainingNormalizers, parameterStorage: []^core.Node,
) -> (sizes: PPOCheckpointBufferSizes, adam: ^Adam, ok: bool) {
	if policy == nil || value == nil || !PPOTrainingNormalizerTargetsValid(normalizers) ||
		normalizers.observation != nil && len(normalizers.observation.mean) != policy.inputWidth ||
		normalizers.reward != nil && len(normalizers.reward.mean) != 1 { return {}, nil, false }
	policyNormalizerBytes, policyNormalizerOk := PPOCheckpointNormalizerByteSize(normalizers.observation)
	rewardNormalizerBytes, rewardNormalizerOk := PPOCheckpointNormalizerByteSize(normalizers.reward)
	if !policyNormalizerOk || !rewardNormalizerOk { return {}, nil, false }
	basePlan := ppoCheckpointWriteLayout(
		policy, value, optimizer, state, ppoConfig, fitConfig, parameterStorage,
	)
	if !basePlan.ok { return {}, nil, false }
	fixedSize := 24+policyNormalizerBytes+rewardNormalizerBytes
	if basePlan.sizes.output > max(int)-fixedSize { return {}, nil, false }
	sizes = {
		output = fixedSize+basePlan.sizes.output,
		checkpointScratch = basePlan.sizes.output,
		policyScratch = basePlan.sizes.policyScratch,
		valueScratch = basePlan.sizes.valueScratch,
	}
	return sizes, basePlan.adam, true
}

// Measures exact output/checkpoint-scratch/policy-scratch/value-scratch byte
// capacities for PPOCheckpointWriteNormalized. Validation and sizing match the
// writer and allocate nothing. Keep models, optimizer, normalizers and state
// unchanged through a later write; the writer's disjointness/backing requirements
// apply. Rollout and environment state are not included.
PPOCheckpointMeasureNormalized :: proc(
	policy: ^Sequential($policyMaxLayers, $policyMaxWidth, $policyBatchCapacity),
	value: ^Sequential($valueMaxLayers, $valueMaxWidth, $valueBatchCapacity),
	optimizer: SequentialOptimizer, state: PPOTrainingState, ppoConfig: PPOConfig, fitConfig: PPOFitConfig,
	normalizers: PPOTrainingNormalizers,
) -> (PPOCheckpointBufferSizes, bool) {
	parameterStorage: [2*(policyMaxLayers+valueMaxLayers)]^core.Node
	sizes, _, ok := ppoNormalizedCheckpointWriteLayout(
		policy, value, optimizer, state, ppoConfig, fitConfig, normalizers, parameterStorage[:],
	)
	return sizes, ok
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
	parameterStorage: [2*(policyMaxLayers+valueMaxLayers)]^core.Node
	sizes, adam, layoutOk := ppoNormalizedCheckpointWriteLayout(
		policy, value, optimizer, state, ppoConfig, fitConfig, normalizers, parameterStorage[:],
	)
	if !layoutOk { return 0, false }
	if !PPOCheckpointNormalizedWriteDisjoint(
		rawptr(policy), size_of(Sequential(policyMaxLayers, policyMaxWidth, policyBatchCapacity)),
		rawptr(value), size_of(Sequential(valueMaxLayers, valueMaxWidth, valueBatchCapacity)),
		adam, output, checkpointScratch, policyScratch, valueScratch, normalizers,
	) || len(output) < sizes.output || len(checkpointScratch) < sizes.checkpointScratch ||
		len(policyScratch) < sizes.policyScratch || len(valueScratch) < sizes.valueScratch { return 0, false }
	baseSize, baseOk := PPOCheckpointWrite(
		policy, value, optimizer, state, ppoConfig, fitConfig,
		checkpointScratch, policyScratch, valueScratch,
	)
	if !baseOk || baseSize != sizes.checkpointScratch { return 0, false }
	policyNormalizerBytes, _ := PPOCheckpointNormalizerByteSize(normalizers.observation)
	rewardNormalizerBytes, _ := PPOCheckpointNormalizerByteSize(normalizers.reward)
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

@(private)
ppoNormalizedCheckpointReadTarget :: struct {
	policy: rawptr,
	policySize: int,
	value: rawptr,
	valueSize: int,
	adam: ^Adam,
	parameterStorage: []^core.Node,
	firstMoment, secondMoment: []f32,
	normalizers: PPOTrainingNormalizers,
}

@(private)
ppoNormalizedCheckpointParsed :: struct {
	info: PPONormalizedCheckpointInfo,
	observation, reward: PPOCheckpointNormalizerDescriptor,
	baseOffset: int,
	targetRejected: bool,
}

@(private="file")
ppoCheckpointNormalizerInfo :: proc(descriptor: PPOCheckpointNormalizerDescriptor) -> PPOCheckpointNormalizerInfo {
	return {descriptor.present, descriptor.count, descriptor.width, descriptor.epsilon, descriptor.frozen}
}

// Validate the base envelope up to its policy payload without scanning model
// parameters or Adam moments. A one-byte policy limit makes the authoritative
// base parser stop at that payload; the peek is used only to locate its header.
@(private="file")
ppoCheckpointPreflightObservationWidth :: proc(input: []u8, maxWidth: int, limits: PPOCheckpointInspectLimits) -> CheckpointError {
	policyInput, valueInput, found := PPOCheckpointPeekModelPayloads(input)
	if !found || len(policyInput) < 80 { return {} }
	policyOffset := len(input)-len(policyInput)-len(valueInput)
	valueOffset := policyOffset+len(policyInput)
	guardLimits := limits
	guardLimits.policy.maxBytes = 1
	_, err := PPOCheckpointInspect(input, guardLimits)
	if err.code != .LimitExceeded || err.offset != policyOffset { return err }
	// Preserve the real nested byte-limit order before inspecting either model.
	if limits.policy.maxBytes > 0 && len(policyInput) > limits.policy.maxBytes { return {.LimitExceeded, policyOffset} }
	if limits.value.maxBytes > 0 && len(valueInput) > limits.value.maxBytes { return {.LimitExceeded, valueOffset} }

	// Inspect just the fixed model header, so its errors and capacity limits retain
	// priority without visiting any layer or parameter payload.
	headerLimits := limits.policy
	headerLimits.maxBytes = 0
	_, headerError := CheckpointInspect(policyInput[:80], headerLimits)
	if headerError.code != .None && headerError.code != .Truncated {
		headerError.offset += policyOffset
		return headerError
	}
	widthOffset := 40
	width, ok := CheckpointGet64(policyInput, &widthOffset)
	if ok && width > u64(maxWidth) { return {.LimitExceeded, policyOffset+40} }
	return {}
}

// This is the shared interpretation of the normalized envelope. A target can
// reject incompatible or overlapping storage before the base scan; only the
// target-free path promises complete validation. No model-sized probe is needed.
@(private)
ppoCheckpointParseNormalized :: proc(
	input: []u8,
	limits: PPONormalizedCheckpointInspectLimits,
	target: ^ppoNormalizedCheckpointReadTarget = nil,
) -> (ppoNormalizedCheckpointParsed, CheckpointError) {
	if limits.maxBytes < 0 || limits.maxObservationWidth < 0 { return {}, {.InvalidLimits, 0} }
	// Let the base inspector own the validation of its complete limits hierarchy,
	// even when the outer envelope is malformed or exceeds its own byte limit.
	_, limitsError := PPOCheckpointInspect(nil, limits.base)
	if limitsError.code == .InvalidLimits { return {}, limitsError }
	if limits.maxBytes > 0 && len(input) > limits.maxBytes { return {}, {.LimitExceeded, 0} }

	offset := 0
	magic, ok := CheckpointGet64(input, &offset)
	if !ok { return {}, {.Truncated, len(input)} }
	if magic != PPO_NORMALIZED_CHECKPOINT_MAGIC { return {}, {.InvalidMagic, 0} }
	version, versionOk := CheckpointGet64(input, &offset)
	if !versionOk { return {}, {.Truncated, len(input)} }
	if version != PPO_NORMALIZED_CHECKPOINT_VERSION { return {}, {.UnsupportedVersion, 8} }
	baseSize64, sizeOk := CheckpointGet64(input, &offset)
	if !sizeOk { return {}, {.Truncated, len(input)} }
	if baseSize64 > u64(max(int)) { return {}, {.Overflow, 16} }

	parsed: ppoNormalizedCheckpointParsed
	observation, observationError := ppoCheckpointParseNormalizer(input, &offset, limits.maxObservationWidth, 0)
	if observationError.code != .None { return {}, observationError }
	reward, rewardError := ppoCheckpointParseNormalizer(input, &offset, 0, 1)
	if rewardError.code != .None { return {}, rewardError }
	remaining := len(input)-offset
	if baseSize64 > u64(remaining) { return {}, {.Truncated, len(input)} }
	if baseSize64 < u64(remaining) { return {}, {.TrailingData, offset+int(baseSize64)} }
	parsed.baseOffset = offset
	if target != nil && (target.policy == nil || target.value == nil || target.policy == target.value ||
		!PPOCheckpointNormalizerTargetValid(observation, target.normalizers.observation) ||
		!PPOCheckpointNormalizerTargetValid(reward, target.normalizers.reward) ||
		!PPOCheckpointNormalizedReadDisjoint(input, target.policy, target.policySize, target.value, target.valueSize,
			target.adam, target.parameterStorage, target.firstMoment, target.secondMoment, target.normalizers)) {
		return ppoNormalizedCheckpointParsed{targetRejected = true}, {}
	}
	baseInput := input[offset:]
	if limits.maxObservationWidth > 0 {
		widthError := ppoCheckpointPreflightObservationWidth(baseInput, limits.maxObservationWidth, limits.base)
		if widthError.code != .None { widthError.offset += offset; return {}, widthError }
	}
	base, baseError := PPOCheckpointInspect(baseInput, limits.base)
	if baseError.code != .None { baseError.offset += offset; return {}, baseError }
	if observation.present && observation.width != base.policy.inputWidth {
		return {}, {.InvalidArchitecture, observation.meanOffset-24}
	}
	parsed.observation, parsed.reward = observation, reward
	parsed.info = PPONormalizedCheckpointInfo{
		base = base,
		observation = ppoCheckpointNormalizerInfo(observation),
		reward = ppoCheckpointNormalizerInfo(reward),
	}
	return parsed, {}
}

// Validates the complete normalized checkpoint without allocation or a target.
// Success describes encoded requirements, not whether a particular destination
// is compatible. Input must have valid backing storage and remain unchanged during
// inspection and any later restore; the reader revalidates without these limits.
// On failure info is zero. Offsets are absolute within input, including nested
// errors; truncation points to the end of the affected payload, trailing data to
// its first byte, width mismatches to the normalizer width field. A
// maxObservationWidth failure points to the oversized descriptor's width field
// or to the policy input-width field, whether or not a normalizer is present.
// InvalidLimits and an outer maxBytes failure use zero; base maxBytes uses the
// base start.
PPOCheckpointInspectNormalized :: proc(input: []u8, limits: PPONormalizedCheckpointInspectLimits = {}) -> (PPONormalizedCheckpointInfo, CheckpointError) {
	parsed, err := ppoCheckpointParseNormalized(input, limits)
	if err.code != .None { return {}, err }
	return parsed.info, {}
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
	target := ppoNormalizedCheckpointReadTarget{
		policy = rawptr(policy), policySize = size_of(Sequential(policyMaxLayers, policyMaxWidth, policyBatchCapacity)),
		value = rawptr(value), valueSize = size_of(Sequential(valueMaxLayers, valueMaxWidth, valueBatchCapacity)),
		adam = restoredAdam, parameterStorage = parameterStorage, firstMoment = firstMoment,
		secondMoment = secondMoment, normalizers = normalizers,
	}
	parsed, err := ppoCheckpointParseNormalized(input, {}, &target)
	if err.code != .None || parsed.targetRejected { return {}, {}, {}, nil, false }
	baseInput := input[parsed.baseOffset:]
	restoredState, restoredPPOConfig, restoredFitConfig, restoredOptimizer, readOk := PPOCheckpointRead(
		policy, value, baseInput, restoredAdam, parameterStorage, firstMoment, secondMoment,
	)
	if !readOk do return {}, {}, {}, nil, false
	PPOCheckpointApplyNormalizer(input, parsed.observation, normalizers.observation)
	PPOCheckpointApplyNormalizer(input, parsed.reward, normalizers.reward)
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
	info, details, inspectError := CheckpointInspectWithDetails(modelInput)
	if policy == nil || inspectError.code != .None || info.maxLayers != maxLayers || info.maxWidth != maxWidth ||
		info.batchCapacity != batchCapacity || info.hasAdam || info.parameterPointers == 0 ||
		info.outputRank != 2 || info.outputWidth <= 0 || details.effectiveOutputIsSoftmax ||
		descriptor.present && descriptor.width != info.inputWidth {
		return false
	}
	// Inspection shares CheckpointRead's parser; exact capacities and the
	// model-only flag make reconstruction deterministic for this destination.
	innerState: u64
	if !CheckpointRead(policy, nil, &innerState, modelInput, nil, nil, nil) do return false
	PPOCheckpointApplyNormalizer(input, descriptor, observationNormalizer)
	return true
}
