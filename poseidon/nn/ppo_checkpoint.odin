package nn

import "../core"

PPO_CHECKPOINT_MAGIC :: u64(0x3154504b43505050)
PPO_CHECKPOINT_VERSION :: u64(1)

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
	if policy == nil || value == nil || state.policyRandomState == 0 ||
		!PPOConfigValid(ppoConfig) || !PPOFitConfigValid(fitConfig) ||
		fitConfig.batchSize > min(policyBatchCapacity, valueBatchCapacity) ||
		!PPOCheckpointWriteDisjoint(
			rawptr(policy), size_of(Sequential(policyMaxLayers, policyMaxWidth, policyBatchCapacity)),
			rawptr(value), size_of(Sequential(valueMaxLayers, valueMaxWidth, valueBatchCapacity)),
			nil, output, policyScratch, valueScratch,
		) {
		return 0, false
	}
	parameterStorage: [2*(policyMaxLayers+valueMaxLayers)]^core.Node
	parameters, elementCount, parametersOk := PPOCheckpointCombinedParameters(
		policy, value, parameterStorage[:],
	)
	if !parametersOk do return 0, false
	kind, learningRate, adam, optimizerOk := PPOCheckpointOptimizerValid(optimizer, parameters)
	if !optimizerOk do return 0, false
	if !PPOCheckpointWriteDisjoint(
		rawptr(policy), size_of(Sequential(policyMaxLayers, policyMaxWidth, policyBatchCapacity)),
		rawptr(value), size_of(Sequential(valueMaxLayers, valueMaxWidth, valueBatchCapacity)),
		adam, output, policyScratch, valueScratch,
	) {
		return 0, false
	}
	if adam != nil {
		for first, index in adam.firstMoment {
			if !AdamFinite(f64(first)) || !AdamFinite(f64(adam.secondMoment[index])) || adam.secondMoment[index] < 0 {
				return 0, false
			}
		}
	}
	policySize, policyOk := CheckpointWrite(policy, nil, state.policyRandomState, policyScratch)
	valueSize, valueOk := CheckpointWrite(value, nil, state.shuffleRandomState, valueScratch)
	if !policyOk || !valueOk do return 0, false

	fixedSize := 112
	if kind == 0 {
		fixedSize += 4
	} else {
		if elementCount > (max(int)-fixedSize-32)/8 do return 0, false
		fixedSize += 32+8*elementCount
	}
	if policySize > max(int)-fixedSize || valueSize > max(int)-fixedSize-policySize do return 0, false
	totalSize := fixedSize+policySize+valueSize
	if len(output) < totalSize do return 0, false

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

// Restores a PPO checkpoint atomically with respect to malformed/truncated input.
// Models must be destination objects at their final addresses. For Adam snapshots,
// supply disjoint parameter and moment storage plus an Adam destination; for SGD,
// pass nil Adam and empty moment storage. Caller storage must not overlap input or
// either model. The game environment is adapter-owned and is not restored here.
PPOCheckpointRead :: proc(
	policy: ^Sequential($policyMaxLayers, $policyMaxWidth, $policyBatchCapacity),
	value: ^Sequential($valueMaxLayers, $valueMaxWidth, $valueBatchCapacity),
	input: []u8,
	restoredAdam: ^Adam,
	parameterStorage: []^core.Node,
	firstMoment, secondMoment: []f32,
) -> (state: PPOTrainingState, ppoConfig: PPOConfig, fitConfig: PPOFitConfig, optimizer: SequentialOptimizer, ok: bool) {
	if policy == nil || value == nil || rawptr(policy) == rawptr(value) do return {}, {}, {}, nil, false
	offset := 0
	magic, magicOk := CheckpointGet64(input, &offset)
	if !magicOk || magic != PPO_CHECKPOINT_MAGIC do return {}, {}, {}, nil, false
	version, versionOk := CheckpointGet64(input, &offset)
	if !versionOk || version != PPO_CHECKPOINT_VERSION do return {}, {}, {}, nil, false
	policySize64, policySizeOk := CheckpointGet64(input, &offset)
	if !policySizeOk do return {}, {}, {}, nil, false
	valueSize64, valueSizeOk := CheckpointGet64(input, &offset)
	if !valueSizeOk || policySize64 > u64(max(int)) || valueSize64 > u64(max(int)) do return {}, {}, {}, nil, false
	stateValues: [4]u64
	for &item in stateValues {
		stateValue, stateReadOk := CheckpointGet64(input, &offset)
		if !stateReadOk do return {}, {}, {}, nil, false
		item = stateValue
	}
	if stateValues[2] == 0 do return {}, {}, {}, nil, false
	for index in 0..<4 {
		configValue, configReadOk := CheckpointGet32(input, &offset)
		if !configReadOk do return {}, {}, {}, nil, false
		switch index {
		case 0: ppoConfig.clipRange = configValue
		case 1: ppoConfig.entropyCoefficient = configValue
		case 2: ppoConfig.valueCoefficient = configValue
		case 3: ppoConfig.valueHuberDelta = configValue
		}
	}
	if !PPOConfigValid(ppoConfig) do return {}, {}, {}, nil, false
	epochs64, epochsOk := CheckpointGet64(input, &offset)
	if !epochsOk || epochs64 > u64(max(int)) do return {}, {}, {}, nil, false
	batchSize64, batchSizeOk := CheckpointGet64(input, &offset)
	if !batchSizeOk || batchSize64 > u64(max(int)) do return {}, {}, {}, nil, false
	fitConfig.epochs, fitConfig.batchSize = int(epochs64), int(batchSize64)
	maxGradientNorm, maxGradientNormOk := CheckpointGet32(input, &offset)
	if !maxGradientNormOk do return {}, {}, {}, nil, false
	fitConfig.maxGradientNorm = maxGradientNorm
	finalLearningRate, finalLearningRateOk := CheckpointGet32(input, &offset)
	if !finalLearningRateOk do return {}, {}, {}, nil, false
	fitConfig.finalLearningRate = finalLearningRate
	if !PPOFitConfigValid(fitConfig) || fitConfig.batchSize > min(policyBatchCapacity, valueBatchCapacity) {
		return {}, {}, {}, nil, false
	}
	kind, kindOk := CheckpointGet64(input, &offset)
	if !kindOk || kind > 1 do return {}, {}, {}, nil, false
	adamStep: u64
	adamConfig: [4]f32
	storedElementCount := 0
	adamMomentsOffset := 0
	if kind == 0 {
		if restoredAdam != nil || len(parameterStorage) != 0 || len(firstMoment) != 0 || len(secondMoment) != 0 {
			return {}, {}, {}, nil, false
		}
		learningRate, readOk := CheckpointGet32(input, &offset)
		if !readOk || learningRate <= 0 || !PPOFiniteF64(f64(learningRate)) do return {}, {}, {}, nil, false
		optimizer = SequentialSGD{learningRate}
	} else {
		if restoredAdam == nil do return {}, {}, {}, nil, false
		stepValue, stepReadOk := CheckpointGet64(input, &offset)
		if !stepReadOk || stepValue == max(u64) do return {}, {}, {}, nil, false
		adamStep = stepValue
		for &item in adamConfig {
			configValue, configReadOk := CheckpointGet32(input, &offset)
			if !configReadOk do return {}, {}, {}, nil, false
			item = configValue
		}
		if !AdamFinite(f64(adamConfig[0])) || adamConfig[0] <= 0 ||
			!(adamConfig[1] >= 0 && adamConfig[1] < 1) || !(adamConfig[2] >= 0 && adamConfig[2] < 1) ||
			!AdamFinite(f64(adamConfig[3])) || adamConfig[3] <= 0 {
			return {}, {}, {}, nil, false
		}
		elementCount64, readOk := CheckpointGet64(input, &offset)
		if !readOk || elementCount64 > u64(max(int)) do return {}, {}, {}, nil, false
		storedElementCount = int(elementCount64)
		if storedElementCount > (len(input)-offset)/8 do return {}, {}, {}, nil, false
		adamMomentsOffset = offset
		for _ in 0..<storedElementCount {
			moment, readOk := CheckpointGet32(input, &offset)
			if !readOk || !AdamFinite(f64(moment)) do return {}, {}, {}, nil, false
		}
		for _ in 0..<storedElementCount {
			moment, readOk := CheckpointGet32(input, &offset)
			if !readOk || !AdamFinite(f64(moment)) || moment < 0 do return {}, {}, {}, nil, false
		}
	}
	if policySize64 > u64(len(input)-offset) || valueSize64 > u64(len(input)-offset)-policySize64 ||
		policySize64+valueSize64 != u64(len(input)-offset) {
		return {}, {}, {}, nil, false
	}
	policySize, valueSize := int(policySize64), int(valueSize64)
	policyInput := input[offset:offset+policySize]
	offset += policySize
	valueInput := input[offset:offset+valueSize]

	// Inspection shares CheckpointRead's parser. Its layer, rank, dimension,
	// parameter and RNG checks establish that the constructors can be replayed
	// for these exact model types; their node buffers are then distinct and inline.
	policyInfo, policyDetails, policyError := CheckpointInspectWithDetails(policyInput)
	valueInfo, valueError := CheckpointInspect(valueInput)
	if policyError.code != .None || valueError.code != .None ||
		policyInfo.maxLayers != policyMaxLayers || policyInfo.maxWidth != policyMaxWidth || policyInfo.batchCapacity != policyBatchCapacity ||
		valueInfo.maxLayers != valueMaxLayers || valueInfo.maxWidth != valueMaxWidth || valueInfo.batchCapacity != valueBatchCapacity ||
		policyInfo.hasAdam || valueInfo.hasAdam || policyInfo.parameterPointers == 0 || valueInfo.parameterPointers == 0 ||
		policyInfo.inputWidth != valueInfo.inputWidth || policyInfo.outputRank != 2 || valueInfo.outputRank != 2 ||
		valueInfo.outputWidth != 1 || policyDetails.effectiveOutputIsSoftmax ||
		policyInfo.parameterPointers > max(int)-valueInfo.parameterPointers ||
		policyInfo.momentElements > max(int)-valueInfo.momentElements {
		return {}, {}, {}, nil, false
	}
	parameterCount := policyInfo.parameterPointers+valueInfo.parameterPointers
	actualElementCount := policyInfo.momentElements+valueInfo.momentElements
	if kind == 1 && (actualElementCount != storedElementCount || len(parameterStorage) < parameterCount ||
		len(firstMoment) < storedElementCount || len(secondMoment) < storedElementCount) {
		return {}, {}, {}, nil, false
	}
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
	if kind == 1 {
		actualParameters, actualCount, actualOk := PPOCheckpointCombinedParameters(
			policy, value, parameterStorage,
		)
		if !actualOk || actualCount != storedElementCount { return {}, {}, {}, nil, false }
		momentOffset := adamMomentsOffset
		for index in 0..<storedElementCount {
			firstMoment[index], _ = CheckpointGet32(input, &momentOffset)
		}
		for index in 0..<storedElementCount {
			secondMoment[index], _ = CheckpointGet32(input, &momentOffset)
		}
		restoredAdam^ = Adam{
			parameters = actualParameters,
			firstMoment = firstMoment[:storedElementCount],
			secondMoment = secondMoment[:storedElementCount],
			step = adamStep,
			learningRate = adamConfig[0], beta1 = adamConfig[1], beta2 = adamConfig[2], epsilon = adamConfig[3],
		}
		optimizer = restoredAdam
	}
	state = PPOTrainingState{
		updateCount = stateValues[0], rolloutCount = stateValues[1],
		policyRandomState = stateValues[2], shuffleRandomState = stateValues[3],
	}
	return state, ppoConfig, fitConfig, optimizer, true
}
