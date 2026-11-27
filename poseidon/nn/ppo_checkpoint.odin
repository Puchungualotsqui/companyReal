package nn

import "../core"

PPO_CHECKPOINT_MAGIC :: u64(0x3154504b43505050)
PPO_CHECKPOINT_VERSION :: u64(1)

PPOCheckpointOptimizerKind :: enum { SGD, Adam }

// Counts describe the combined policy-then-value structure, including for SGD.
// momentElements is the number of f32s in EACH Adam moment array. Adam-specific
// fields are zero for SGD. Model capacities are the encoded Sequential type
// capacities; inspection cannot guarantee that a matching type is available or
// allocatable, nor that caller-owned destination storage is disjoint.
PPOCheckpointInfo :: struct {
	policy, value: CheckpointInfo,
	state: PPOTrainingState,
	objective: PPOConfig,
	fit: PPOFitConfig,
	optimizer: PPOCheckpointOptimizerKind,
	parameterPointers, momentElements: int,
	learningRate, beta1, beta2, epsilon: f32,
	step: u64,
}

// Zero disables a limit; negative limits are invalid. The top-level pointer and
// moment limits apply to the combined model requirements, including for SGD.
// policy and value additionally limit their respective nested checkpoints.
PPOCheckpointInspectLimits :: struct {
	maxBytes, maxParameterPointers, maxMomentElements, maxEpochs: int,
	policy, value: CheckpointInspectLimits,
}

PPOCheckpointRange :: proc(data: rawptr, count, elementSize: int) -> (PPOFitMemoryRange, bool) {
	return PPOFitMemoryRangeOf(data, count, elementSize)
}

PPOCheckpointRangesDisjoint :: proc(ranges: []PPOFitMemoryRange) -> bool {
	for current, index in ranges {
		for previous in ranges[:index] {
			if PPOFitMemoryRangesOverlap(current, previous) do return false
		}
	}
	return true
}

PPOCheckpointWriteDisjoint :: proc(
	policy: rawptr, policySize: int,
	value: rawptr, valueSize: int,
	optimizer: ^Adam,
	output, policyScratch, valueScratch: []u8,
) -> bool {
	ranges: [9]PPOFitMemoryRange
	count := 0
	ok: bool
	ranges[count], ok = PPOCheckpointRange(rawptr(raw_data(output)), len(output), size_of(u8)); if !ok { return false }; count += 1
	ranges[count], ok = PPOCheckpointRange(rawptr(raw_data(policyScratch)), len(policyScratch), size_of(u8)); if !ok { return false }; count += 1
	ranges[count], ok = PPOCheckpointRange(rawptr(raw_data(valueScratch)), len(valueScratch), size_of(u8)); if !ok { return false }; count += 1
	ranges[count], ok = PPOCheckpointRange(policy, 1, policySize); if !ok { return false }; count += 1
	ranges[count], ok = PPOCheckpointRange(value, 1, valueSize); if !ok { return false }; count += 1
	if optimizer != nil {
		ranges[count], ok = PPOCheckpointRange(rawptr(optimizer), 1, size_of(Adam)); if !ok { return false }; count += 1
		ranges[count], ok = PPOCheckpointRange(rawptr(raw_data(optimizer.parameters)), len(optimizer.parameters), size_of(^core.Node)); if !ok { return false }; count += 1
		ranges[count], ok = PPOCheckpointRange(rawptr(raw_data(optimizer.firstMoment)), len(optimizer.firstMoment), size_of(f32)); if !ok { return false }; count += 1
		ranges[count], ok = PPOCheckpointRange(rawptr(raw_data(optimizer.secondMoment)), len(optimizer.secondMoment), size_of(f32)); if !ok { return false }; count += 1
	}
	return PPOCheckpointRangesDisjoint(ranges[:count])
}

PPOCheckpointReadDisjoint :: proc(
	input: []u8,
	policy: rawptr, policySize: int,
	value: rawptr, valueSize: int,
	adam: ^Adam,
	parameterStorage: []^core.Node,
	firstMoment, secondMoment: []f32,
) -> bool {
	ranges: [7]PPOFitMemoryRange
	count := 0
	ok: bool
	ranges[count], ok = PPOCheckpointRange(rawptr(raw_data(input)), len(input), size_of(u8)); if !ok { return false }; count += 1
	ranges[count], ok = PPOCheckpointRange(policy, 1, policySize); if !ok { return false }; count += 1
	ranges[count], ok = PPOCheckpointRange(value, 1, valueSize); if !ok { return false }; count += 1
	if len(parameterStorage) > 0 {
		ranges[count], ok = PPOCheckpointRange(rawptr(raw_data(parameterStorage)), len(parameterStorage), size_of(^core.Node)); if !ok { return false }; count += 1
	}
	if len(firstMoment) > 0 {
		ranges[count], ok = PPOCheckpointRange(rawptr(raw_data(firstMoment)), len(firstMoment), size_of(f32)); if !ok { return false }; count += 1
	}
	if len(secondMoment) > 0 {
		ranges[count], ok = PPOCheckpointRange(rawptr(raw_data(secondMoment)), len(secondMoment), size_of(f32)); if !ok { return false }; count += 1
	}
	if adam != nil {
		ranges[count], ok = PPOCheckpointRange(rawptr(adam), 1, size_of(Adam)); if !ok { return false }; count += 1
	}
	return PPOCheckpointRangesDisjoint(ranges[:count])
}

PPOCheckpointCombinedParameters :: proc(
	policy: ^Sequential($policyMaxLayers, $policyMaxWidth, $policyBatchCapacity),
	value: ^Sequential($valueMaxLayers, $valueMaxWidth, $valueBatchCapacity),
	parameterStorage: []^core.Node,
) -> (parameters: []^core.Node, elementCount: int, ok: bool) {
	policyParametersStorage: [2*policyMaxLayers]^core.Node
	valueParametersStorage: [2*valueMaxLayers]^core.Node
	policyNodesStorage: [1+3*policyMaxLayers]^core.Node
	valueNodesStorage: [1+3*valueMaxLayers]^core.Node
	policyParameters, policyNodes, policyOk := PPOSequentialParametersAndNodes(
		policy, policyParametersStorage[:], policyNodesStorage[:],
	)
	valueParameters, valueNodes, valueOk := PPOSequentialParametersAndNodes(
		value, valueParametersStorage[:], valueNodesStorage[:],
	)
	if !policyOk || !valueOk || rawptr(policy) == rawptr(value) ||
		policy.inputWidth != value.inputWidth || value.layers[value.layerCount-1].width != 1 ||
		len(policy.layers[policy.layerCount-1].output.value.shape) != 2 ||
		policy.layers[policy.layerCount-1].output.value.shape[1] != policy.layers[policy.layerCount-1].width ||
		len(value.layers[value.layerCount-1].output.value.shape) != 2 ||
		value.layers[value.layerCount-1].output.value.shape[1] != 1 {
		return nil, 0, false
	}
	if _, isSoftmax := SequentialLogitsOutputLayer(policy).(^Softmax); isSoftmax {
		return nil, 0, false
	}
	for policyNode in policyNodes {
		for valueNode in valueNodes {
			if core.BuffersOverlap(policyNode.value, valueNode.value) ||
				core.BuffersOverlap(policyNode.value, valueNode.grad) ||
				core.BuffersOverlap(policyNode.grad, valueNode.value) ||
				core.BuffersOverlap(policyNode.grad, valueNode.grad) {
				return nil, 0, false
			}
		}
	}
	if len(policyParameters) > max(int)-len(valueParameters) || len(parameterStorage) < len(policyParameters)+len(valueParameters) {
		return nil, 0, false
	}
	parameterCount := 0
	for parameter in policyParameters {
		parameterStorage[parameterCount] = parameter
		parameterCount += 1
	}
	for parameter in valueParameters {
		parameterStorage[parameterCount] = parameter
		parameterCount += 1
	}
	parameters = parameterStorage[:parameterCount]
	for parameter in parameters {
		if len(parameter.value.data) > max(int)-elementCount do return nil, 0, false
		elementCount += len(parameter.value.data)
	}
	return parameters, elementCount, true
}

PPOCheckpointOptimizerValid :: proc(optimizer: SequentialOptimizer, parameters: []^core.Node) -> (kind: u64, learningRate: f32, adam: ^Adam, ok: bool) {
	switch value in optimizer {
	case SequentialSGD:
		if value.learningRate <= 0 || !PPOFiniteF64(f64(value.learningRate)) do return 0, 0, nil, false
		return 0, value.learningRate, nil, true
	case ^Adam:
		if value == nil || !PPOOptimizerValid(optimizer, parameters) do return 0, 0, nil, false
		return 1, value.learningRate, value, true
	}
	return 0, 0, nil, false
}

// Exact byte capacities required by PPOCheckpointWriteNormalized. For the base
// writer, checkpointScratch is zero. No allocation or mutation occurs.
PPOCheckpointBufferSizes :: struct {
	output, checkpointScratch, policyScratch, valueScratch: int,
}

@(private)
ppoCheckpointWritePlan :: struct {
	sizes: PPOCheckpointBufferSizes,
	kind: u64,
	learningRate: f32,
	adam: ^Adam,
	parameters: []^core.Node,
	elementCount: int,
	ok: bool,
}

@(private)
ppoCheckpointWriteLayout :: proc(
	policy: ^Sequential($policyMaxLayers, $policyMaxWidth, $policyBatchCapacity),
	value: ^Sequential($valueMaxLayers, $valueMaxWidth, $valueBatchCapacity),
	optimizer: SequentialOptimizer, state: PPOTrainingState, ppoConfig: PPOConfig, fitConfig: PPOFitConfig,
	parameterStorage: []^core.Node,
) -> ppoCheckpointWritePlan {
	if policy == nil || value == nil || state.policyRandomState == 0 ||
		!PPOConfigValid(ppoConfig) || !PPOFitConfigValid(fitConfig) ||
		fitConfig.batchSize > min(policyBatchCapacity, valueBatchCapacity) { return {} }
	parameters, elementCount, parametersOk := PPOCheckpointCombinedParameters(policy, value, parameterStorage)
	if !parametersOk { return {} }
	kind, learningRate, adam, optimizerOk := PPOCheckpointOptimizerValid(optimizer, parameters)
	if !optimizerOk { return {} }
	if adam != nil {
		for first, index in adam.firstMoment {
			if !AdamFinite(f64(first)) || !AdamFinite(f64(adam.secondMoment[index])) || adam.secondMoment[index] < 0 {
				return {}
			}
		}
	}
	policySize, policyOk := CheckpointMeasure(policy, nil, state.policyRandomState)
	valueSize, valueOk := CheckpointMeasure(value, nil, state.shuffleRandomState)
	if !policyOk || !valueOk { return {} }
	fixedSize := 112
	if kind == 0 {
		fixedSize += 4
	} else {
		if elementCount > (max(int)-fixedSize-32)/8 { return {} }
		fixedSize += 32+8*elementCount
	}
	if policySize > max(int)-fixedSize || valueSize > max(int)-fixedSize-policySize { return {} }
	return {
		sizes = {output = fixedSize+policySize+valueSize, policyScratch = policySize, valueScratch = valueSize},
		kind = kind, learningRate = learningRate, adam = adam, parameters = parameters, elementCount = elementCount, ok = true,
	}
}

// Measures the exact output, policy-staging, and value-staging byte capacities
// required by PPOCheckpointWrite. Validation and sizing match the writer. No
// allocation or mutation occurs. The model, optimizer and state must remain
// unchanged through a later write; the writer's disjointness and backing-storage
// requirements apply. This does not include rollout or environment state.
PPOCheckpointMeasure :: proc(
	policy: ^Sequential($policyMaxLayers, $policyMaxWidth, $policyBatchCapacity),
	value: ^Sequential($valueMaxLayers, $valueMaxWidth, $valueBatchCapacity),
	optimizer: SequentialOptimizer, state: PPOTrainingState, ppoConfig: PPOConfig, fitConfig: PPOFitConfig,
) -> (PPOCheckpointBufferSizes, bool) {
	parameterStorage: [2*(policyMaxLayers+valueMaxLayers)]^core.Node
	plan := ppoCheckpointWriteLayout(
		policy, value, optimizer, state, ppoConfig, fitConfig, parameterStorage[:],
	)
	return plan.sizes, plan.ok
}

// Writes one resumable PPO training boundary. Both model payloads and the shared
// optimizer are staged before output is changed. The workspace buffers and output
// must be disjoint from models/optimizer and each other. No rollout is serialized:
// only save after SequentialPPOFit succeeds, and let the game adapter separately
// persist or reset its environment state.
PPOCheckpointWrite :: proc(
	policy: ^Sequential($policyMaxLayers, $policyMaxWidth, $policyBatchCapacity),
	value: ^Sequential($valueMaxLayers, $valueMaxWidth, $valueBatchCapacity),
	optimizer: SequentialOptimizer,
	state: PPOTrainingState,
	ppoConfig: PPOConfig,
	fitConfig: PPOFitConfig,
	output, policyScratch, valueScratch: []u8,
) -> (int, bool) {
	if !PPOCheckpointWriteDisjoint(
		rawptr(policy), size_of(Sequential(policyMaxLayers, policyMaxWidth, policyBatchCapacity)),
		rawptr(value), size_of(Sequential(valueMaxLayers, valueMaxWidth, valueBatchCapacity)),
		nil, output, policyScratch, valueScratch,
	) { return 0, false }
	parameterStorage: [2*(policyMaxLayers+valueMaxLayers)]^core.Node
	plan := ppoCheckpointWriteLayout(
		policy, value, optimizer, state, ppoConfig, fitConfig, parameterStorage[:],
	)
	if !plan.ok { return 0, false }
	sizes, kind, learningRate, adam, elementCount := plan.sizes, plan.kind, plan.learningRate, plan.adam, plan.elementCount
	if !PPOCheckpointWriteDisjoint(
		rawptr(policy), size_of(Sequential(policyMaxLayers, policyMaxWidth, policyBatchCapacity)),
		rawptr(value), size_of(Sequential(valueMaxLayers, valueMaxWidth, valueBatchCapacity)),
		adam, output, policyScratch, valueScratch,
	) || len(output) < sizes.output || len(policyScratch) < sizes.policyScratch ||
		len(valueScratch) < sizes.valueScratch { return 0, false }
	policySize, policyOk := CheckpointWrite(policy, nil, state.policyRandomState, policyScratch)
	valueSize, valueOk := CheckpointWrite(value, nil, state.shuffleRandomState, valueScratch)
	if !policyOk || !valueOk || policySize != sizes.policyScratch || valueSize != sizes.valueScratch { return 0, false }

	offset := 0
	CheckpointPut64(output, &offset, PPO_CHECKPOINT_MAGIC)
	CheckpointPut64(output, &offset, PPO_CHECKPOINT_VERSION)
	CheckpointPut64(output, &offset, u64(policySize))
	CheckpointPut64(output, &offset, u64(valueSize))
	CheckpointPut64(output, &offset, state.updateCount)
	CheckpointPut64(output, &offset, state.rolloutCount)
	CheckpointPut64(output, &offset, state.policyRandomState)
	CheckpointPut64(output, &offset, state.shuffleRandomState)
	for item in ([4]f32{ppoConfig.clipRange, ppoConfig.entropyCoefficient, ppoConfig.valueCoefficient, ppoConfig.valueHuberDelta}) {
		CheckpointPut32(output, &offset, item)
	}
	CheckpointPut64(output, &offset, u64(fitConfig.epochs))
	CheckpointPut64(output, &offset, u64(fitConfig.batchSize))
	CheckpointPut32(output, &offset, fitConfig.maxGradientNorm)
	CheckpointPut32(output, &offset, fitConfig.finalLearningRate)
	CheckpointPut64(output, &offset, kind)
	if adam == nil {
		CheckpointPut32(output, &offset, learningRate)
	} else {
		CheckpointPut64(output, &offset, adam.step)
		for item in ([4]f32{adam.learningRate, adam.beta1, adam.beta2, adam.epsilon}) {
			CheckpointPut32(output, &offset, item)
		}
		CheckpointPut64(output, &offset, u64(elementCount))
		for item in adam.firstMoment { CheckpointPut32(output, &offset, item) }
		for item in adam.secondMoment { CheckpointPut32(output, &offset, item) }
	}
	copy(output[offset:offset+policySize], policyScratch[:policySize])
	offset += policySize
	copy(output[offset:offset+valueSize], valueScratch[:valueSize])
	offset += valueSize
	return offset, true
}

@(private="file")
ppoCheckpointReadTarget :: struct {
	policy, value: checkpointReadTarget,
	hasAdam, storageEmpty: bool,
	parameterCapacity, firstCapacity, secondCapacity: int,
}

@(private="file")
ppoCheckpointParsed :: struct {
	info: PPOCheckpointInfo,
	policyOffset, policySize, valueOffset, valueSize, momentsOffset: int,
	targetRejected: bool,
}

@(private="file")
ppoCheckpointLimitsValid :: proc(limits: PPOCheckpointInspectLimits) -> bool {
	if limits.maxBytes < 0 || limits.maxParameterPointers < 0 || limits.maxMomentElements < 0 || limits.maxEpochs < 0 {
		return false
	}
	for nested in ([2]CheckpointInspectLimits{limits.policy, limits.value}) {
		if nested.maxBytes < 0 || nested.maxLayers < 0 || nested.maxWidth < 0 || nested.maxBatchCapacity < 0 ||
			nested.maxParameterPointers < 0 || nested.maxMomentElements < 0 { return false }
	}
	return true
}

// Intersect a nested limit with the unused combined allowance. A trainable layer
// contributes at least two pointers and two elements, so 1 represents an exhausted
// allowance without accidentally turning the nested parser's limit off (zero).
@(private="file")
ppoCheckpointRemainingLimit :: proc(nested, combined, used: int) -> int {
	if combined == 0 { return nested }
	remaining := max(combined-used, 1)
	if nested == 0 || remaining < nested { return remaining }
	return nested
}

// Validates a complete base PPO checkpoint without allocation or a destination.
// Zero limits disable policy limits; set them for untrusted input. Input must have
// valid backing storage and remain unchanged during inspection and subsequent
// restore. On failure info is zero. Error offsets are absolute within input:
// nested errors are translated, nested truncation points to the end of that
// payload, and PPO topology errors identify the affected model's payload/header.
// InvalidLimits and the outer maxBytes failure use offset zero. This does not
// inspect normalized checkpoints; PPOCheckpointRead revalidates without limits.
PPOCheckpointInspect :: proc(input: []u8, limits: PPOCheckpointInspectLimits = {}) -> (PPOCheckpointInfo, CheckpointError) {
	parsed, err := ppoCheckpointParse(input, limits, nil)
	if err.code != .None { return {}, err }
	return parsed.info, {}
}

// This is the single validating interpretation of the PPO envelope for both
// inspection and restore. A target can stop parsing early on an incompatible
// destination; only the target-free path promises complete byte validation.
@(private="file")
ppoCheckpointParse :: proc(input: []u8, limits: PPOCheckpointInspectLimits, target: ^ppoCheckpointReadTarget) -> (ppoCheckpointParsed, CheckpointError) {
	if !ppoCheckpointLimitsValid(limits) { return {}, {.InvalidLimits, 0} }
	if limits.maxBytes > 0 && len(input) > limits.maxBytes { return {}, {.LimitExceeded, 0} }

	parsed: ppoCheckpointParsed
	info := &parsed.info
	offset := 0
	magic, ok := CheckpointGet64(input, &offset)
	if !ok { return {}, {.Truncated, len(input)} }
	if magic != PPO_CHECKPOINT_MAGIC { return {}, {.InvalidMagic, 0} }
	version, versionOk := CheckpointGet64(input, &offset)
	if !versionOk { return {}, {.Truncated, len(input)} }
	if version != PPO_CHECKPOINT_VERSION { return {}, {.UnsupportedVersion, 8} }
	policySize64, policySizeOk := CheckpointGet64(input, &offset)
	if !policySizeOk { return {}, {.Truncated, len(input)} }
	if policySize64 > u64(max(int)) { return {}, {.Overflow, 16} }
	valueSize64, valueSizeOk := CheckpointGet64(input, &offset)
	if !valueSizeOk { return {}, {.Truncated, len(input)} }
	if valueSize64 > u64(max(int)) || valueSize64 > u64(max(int))-policySize64 { return {}, {.Overflow, 24} }
	parsed.policySize, parsed.valueSize = int(policySize64), int(valueSize64)

	stateValues: [4]u64
	for &item in stateValues {
		item, ok = CheckpointGet64(input, &offset)
		if !ok { return {}, {.Truncated, len(input)} }
	}
	if stateValues[2] == 0 { return {}, {.InvalidHeader, 48} }
	info.state = PPOTrainingState{stateValues[0], stateValues[1], stateValues[2], stateValues[3]}
	objective: [4]f32
	for &item in objective {
		item, ok = CheckpointGet32(input, &offset)
		if !ok { return {}, {.Truncated, len(input)} }
	}
	info.objective = PPOConfig{objective[0], objective[1], objective[2], objective[3]}
	if !PPOConfigValid(info.objective) {
		// Ask the authoritative config validator which field is invalid.
		isolated := [4]PPOConfig{{objective[0], 0, 0, 1}, {0, objective[1], 0, 1}, {0, 0, objective[2], 1}, {0, 0, 0, objective[3]}}
		for candidate, index in isolated {
			if !PPOConfigValid(candidate) { return {}, {.InvalidValue, 64+4*index} }
		}
		return {}, {.InvalidValue, 64}
	}
	epochs, epochsOk := CheckpointGet64(input, &offset)
	if !epochsOk { return {}, {.Truncated, len(input)} }
	if epochs > u64(max(int)) { return {}, {.Overflow, 80} }
	if epochs == 0 { return {}, {.InvalidValue, 80} }
	if limits.maxEpochs > 0 && epochs > u64(limits.maxEpochs) { return {}, {.LimitExceeded, 80} }
	batchSize, batchOk := CheckpointGet64(input, &offset)
	if !batchOk { return {}, {.Truncated, len(input)} }
	if batchSize > u64(max(int)) { return {}, {.Overflow, 88} }
	info.fit.epochs, info.fit.batchSize = int(epochs), int(batchSize)
	info.fit.maxGradientNorm, ok = CheckpointGet32(input, &offset)
	if !ok { return {}, {.Truncated, len(input)} }
	info.fit.finalLearningRate, ok = CheckpointGet32(input, &offset)
	if !ok { return {}, {.Truncated, len(input)} }
	if !PPOFitConfigValid(info.fit) {
		if !PPOFitConfigValid(PPOFitConfig{epochs = 1, maxGradientNorm = info.fit.maxGradientNorm}) {
			return {}, {.InvalidValue, 96}
		}
		return {}, {.InvalidValue, 100}
	}
	if target != nil && info.fit.batchSize > min(target.policy.batchCapacity, target.value.batchCapacity) {
		return ppoCheckpointParsed{targetRejected = true}, {}
	}

	kind, kindOk := CheckpointGet64(input, &offset)
	if !kindOk { return {}, {.Truncated, len(input)} }
	if kind > 1 { return {}, {.InvalidHeader, 104} }
	storedElements := 0
	if kind == 0 {
		info.optimizer = .SGD
		if target != nil && (target.hasAdam || !target.storageEmpty) { return ppoCheckpointParsed{targetRejected = true}, {} }
		info.learningRate, ok = CheckpointGet32(input, &offset)
		if !ok { return {}, {.Truncated, len(input)} }
		if info.learningRate <= 0 || !PPOFiniteF64(f64(info.learningRate)) { return {}, {.InvalidValue, 112} }
	} else {
		info.optimizer = .Adam
		if target != nil && !target.hasAdam { return ppoCheckpointParsed{targetRejected = true}, {} }
		info.step, ok = CheckpointGet64(input, &offset)
		if !ok { return {}, {.Truncated, len(input)} }
		if info.step == max(u64) { return {}, {.InvalidValue, 112} }
		config: [4]f32
		for &item in config {
			item, ok = CheckpointGet32(input, &offset)
			if !ok { return {}, {.Truncated, len(input)} }
		}
		if !AdamFinite(f64(config[0])) || config[0] <= 0 { return {}, {.InvalidValue, 120} }
		if !(config[1] >= 0 && config[1] < 1) { return {}, {.InvalidValue, 124} }
		if !(config[2] >= 0 && config[2] < 1) { return {}, {.InvalidValue, 128} }
		if !AdamFinite(f64(config[3])) || config[3] <= 0 { return {}, {.InvalidValue, 132} }
		info.learningRate, info.beta1, info.beta2, info.epsilon = config[0], config[1], config[2], config[3]
		count, countOk := CheckpointGet64(input, &offset)
		if !countOk { return {}, {.Truncated, len(input)} }
		if count > u64((max(int)-offset)/8) { return {}, {.Overflow, 136} }
		storedElements = int(count)
		if limits.maxMomentElements > 0 && storedElements > limits.maxMomentElements { return {}, {.LimitExceeded, 136} }
		if target != nil && (storedElements > target.firstCapacity || storedElements > target.secondCapacity) {
			return ppoCheckpointParsed{targetRejected = true}, {}
		}
		parsed.momentsOffset = offset
		if storedElements > (len(input)-offset)/8 { return {}, {.Truncated, len(input)} }
		offset += storedElements*8
	}

	remaining := len(input)-offset
	if parsed.policySize > remaining || parsed.valueSize > remaining-parsed.policySize { return {}, {.Truncated, len(input)} }
	parsed.policyOffset = offset
	parsed.valueOffset = offset+parsed.policySize
	end := parsed.valueOffset+parsed.valueSize
	if end != len(input) { return {}, {.TrailingData, end} }
	if limits.policy.maxBytes > 0 && parsed.policySize > limits.policy.maxBytes { return {}, {.LimitExceeded, parsed.policyOffset} }
	if limits.value.maxBytes > 0 && parsed.valueSize > limits.value.maxBytes { return {}, {.LimitExceeded, parsed.valueOffset} }
	policyInput := input[parsed.policyOffset:parsed.valueOffset]
	valueInput := input[parsed.valueOffset:end]

	policyLimits := limits.policy
	policyLimits.maxParameterPointers = ppoCheckpointRemainingLimit(policyLimits.maxParameterPointers, limits.maxParameterPointers, 0)
	policyLimits.maxMomentElements = ppoCheckpointRemainingLimit(policyLimits.maxMomentElements, limits.maxMomentElements, 0)
	if target != nil && target.hasAdam {
		// Stop on insufficient pointer storage as soon as a layer's count is known.
		policyLimits.maxParameterPointers = ppoCheckpointRemainingLimit(policyLimits.maxParameterPointers, max(target.parameterCapacity, 1), 0)
	}
	policyTarget: ^checkpointReadTarget
	if target != nil { policyTarget = &target.policy }
	policy, policyError := checkpointParse(policyInput, policyLimits, policyTarget)
	if policyError.code != .None { policyError.offset += parsed.policyOffset; return {}, policyError }
	if policy.targetRejected { return ppoCheckpointParsed{targetRejected = true}, {} }
	info.policy = policy.info
	if info.policy.hasAdam { return {}, {.InvalidArchitecture, parsed.policyOffset+72} }
	if info.policy.parameterPointers == 0 || info.policy.outputRank != 2 || policy.details.effectiveOutputIsSoftmax {
		return {}, {.InvalidArchitecture, parsed.policyOffset}
	}

	valueLimits := limits.value
	valueLimits.maxParameterPointers = ppoCheckpointRemainingLimit(valueLimits.maxParameterPointers, limits.maxParameterPointers, info.policy.parameterPointers)
	valueLimits.maxMomentElements = ppoCheckpointRemainingLimit(valueLimits.maxMomentElements, limits.maxMomentElements, info.policy.momentElements)
	if target != nil && target.hasAdam {
		valueLimits.maxParameterPointers = ppoCheckpointRemainingLimit(valueLimits.maxParameterPointers, max(target.parameterCapacity, 1), info.policy.parameterPointers)
	}
	valueTarget: ^checkpointReadTarget
	if target != nil { valueTarget = &target.value }
	value, valueError := checkpointParse(valueInput, valueLimits, valueTarget)
	if valueError.code != .None { valueError.offset += parsed.valueOffset; return {}, valueError }
	if value.targetRejected { return ppoCheckpointParsed{targetRejected = true}, {} }
	info.value = value.info
	if info.value.hasAdam { return {}, {.InvalidArchitecture, parsed.valueOffset+72} }
	if info.value.parameterPointers == 0 || info.value.outputRank != 2 || info.value.outputWidth != 1 {
		return {}, {.InvalidArchitecture, parsed.valueOffset}
	}
	if info.policy.inputWidth != info.value.inputWidth { return {}, {.InvalidArchitecture, parsed.valueOffset+40} }
	if info.fit.batchSize > min(info.policy.batchCapacity, info.value.batchCapacity) { return {}, {.InvalidValue, 88} }
	if info.policy.parameterPointers > max(int)-info.value.parameterPointers || info.policy.momentElements > max(int)-info.value.momentElements {
		return {}, {.Overflow, parsed.valueOffset}
	}
	info.parameterPointers = info.policy.parameterPointers+info.value.parameterPointers
	info.momentElements = info.policy.momentElements+info.value.momentElements
	if kind == 1 {
		if storedElements != info.momentElements { return {}, {.InvalidArchitecture, 136} }
		if target != nil && (info.parameterPointers > target.parameterCapacity ||
			storedElements > target.firstCapacity || storedElements > target.secondCapacity) {
			return ppoCheckpointParsed{targetRejected = true}, {}
		}
		momentOffset := parsed.momentsOffset
		for _ in 0..<storedElements {
			at := momentOffset
			moment, _ := CheckpointGet32(input, &momentOffset)
			if !AdamFinite(f64(moment)) { return {}, {.InvalidValue, at} }
		}
		for _ in 0..<storedElements {
			at := momentOffset
			moment, _ := CheckpointGet32(input, &momentOffset)
			if !AdamFinite(f64(moment)) || moment < 0 { return {}, {.InvalidValue, at} }
		}
	}
	return parsed, {}
}

// Restores a PPO checkpoint atomically with respect to malformed/truncated input.
// Models must be destination objects at their final addresses. For Adam snapshots,
// supply disjoint parameter and moment storage plus an Adam destination; for SGD,
// pass nil Adam and empty optimizer storage. Caller storage must not overlap input
// or either model; input must have valid backing storage and remain unchanged during
// the call. No allocation or model-sized stack probe is used. The game environment
// is adapter-owned and is not restored here.
PPOCheckpointRead :: proc(
	policy: ^Sequential($policyMaxLayers, $policyMaxWidth, $policyBatchCapacity),
	value: ^Sequential($valueMaxLayers, $valueMaxWidth, $valueBatchCapacity),
	input: []u8,
	restoredAdam: ^Adam,
	parameterStorage: []^core.Node,
	firstMoment, secondMoment: []f32,
) -> (state: PPOTrainingState, ppoConfig: PPOConfig, fitConfig: PPOFitConfig, optimizer: SequentialOptimizer, ok: bool) {
	if policy == nil || value == nil || rawptr(policy) == rawptr(value) do return {}, {}, {}, nil, false
	target := ppoCheckpointReadTarget{
		policy = {maxLayers = policyMaxLayers, maxWidth = policyMaxWidth, batchCapacity = policyBatchCapacity},
		value = {maxLayers = valueMaxLayers, maxWidth = valueMaxWidth, batchCapacity = valueBatchCapacity},
		hasAdam = restoredAdam != nil,
		storageEmpty = len(parameterStorage) == 0 && len(firstMoment) == 0 && len(secondMoment) == 0,
		parameterCapacity = len(parameterStorage), firstCapacity = len(firstMoment), secondCapacity = len(secondMoment),
	}
	parsed, err := ppoCheckpointParse(input, {}, &target)
	if err.code != .None || parsed.targetRejected { return {}, {}, {}, nil, false }
	info := parsed.info
	policyInput := input[parsed.policyOffset:parsed.policyOffset+parsed.policySize]
	valueInput := input[parsed.valueOffset:parsed.valueOffset+parsed.valueSize]
	if !PPOCheckpointReadDisjoint(
		input,
		rawptr(policy), size_of(Sequential(policyMaxLayers, policyMaxWidth, policyBatchCapacity)),
		rawptr(value), size_of(Sequential(valueMaxLayers, valueMaxWidth, valueBatchCapacity)),
		restoredAdam, parameterStorage, firstMoment, secondMoment,
	) {
		return {}, {}, {}, nil, false
	}

	// Both complete payloads and all destination ranges were checked above.
	// Exact capacities and model-only flags make these deterministic commits.
	policyInnerState, valueInnerState: u64
	if !CheckpointRead(policy, nil, &policyInnerState, policyInput, nil, nil, nil) ||
		!CheckpointRead(value, nil, &valueInnerState, valueInput, nil, nil, nil) {
		return {}, {}, {}, nil, false
	}
	if info.optimizer == .Adam {
		actualParameters, actualCount, actualOk := PPOCheckpointCombinedParameters(
			policy, value, parameterStorage,
		)
		if !actualOk || actualCount != info.momentElements { return {}, {}, {}, nil, false }
		momentOffset := parsed.momentsOffset
		for index in 0..<info.momentElements {
			firstMoment[index], _ = CheckpointGet32(input, &momentOffset)
		}
		for index in 0..<info.momentElements {
			secondMoment[index], _ = CheckpointGet32(input, &momentOffset)
		}
		restoredAdam^ = Adam{
			parameters = actualParameters,
			firstMoment = firstMoment[:info.momentElements],
			secondMoment = secondMoment[:info.momentElements],
			step = info.step,
			learningRate = info.learningRate, beta1 = info.beta1, beta2 = info.beta2, epsilon = info.epsilon,
		}
		optimizer = restoredAdam
	} else {
		optimizer = SequentialSGD{info.learningRate}
	}
	return info.state, info.objective, info.fit, optimizer, true
}
