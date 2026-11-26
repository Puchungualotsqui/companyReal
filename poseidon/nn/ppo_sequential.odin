package nn

import "../core"
import "core:math"
import "../rl"

PPOSequentialParametersAndNodes :: proc(
	model: ^Sequential($maxLayers, $maxWidth, $batchCapacity),
	parameterStorage, nodeStorage: []^core.Node,
) -> (parameters, nodes: []^core.Node, ok: bool) {
	if model == nil || model.self != rawptr(model) || model.layerCount <= 0 || model.layerCount > maxLayers ||
		model.inputWidth <= 0 || model.inputWidth > maxWidth || !SequentialInputShapeValid(model) {
		return nil, nil, false
	}
	parameters, ok = SequentialParameters(model, parameterStorage)
	if !ok || len(parameters) == 0 || len(nodeStorage) < 1+model.layerCount+len(parameters) {
		return nil, nil, false
	}
	count := 0
	nodeStorage[count] = &model.input
	count += 1
	for index in 0..<model.layerCount {
		nodeStorage[count] = &model.layers[index].output
		count += 1
	}
	for parameter in parameters {
		nodeStorage[count] = parameter
		count += 1
	}
	nodes = nodeStorage[:count]
	for node, index in nodes {
		if node == nil || !core.TensorValid(node.value) || !core.TensorValid(node.grad) ||
			!core.SameShape(node.value, node.grad) || core.BuffersOverlap(node.value, node.grad) {
			return nil, nil, false
		}
		for previous in nodes[:index] {
			if node == previous || core.BuffersOverlap(node.value, previous.value) ||
				core.BuffersOverlap(node.value, previous.grad) || core.BuffersOverlap(node.grad, previous.value) ||
				core.BuffersOverlap(node.grad, previous.grad) {
				return nil, nil, false
			}
		}
	}
	return parameters, nodes, true
}

PPOOptimizerValid :: proc(optimizer: SequentialOptimizer, parameters: []^core.Node) -> bool {
	if len(parameters) == 0 do return false
	for parameter, index in parameters {
		if parameter == nil do return false
		for previous in parameters[:index] { if parameter == previous do return false }
	}
	switch value in optimizer {
	case nil:
		return false
	case SequentialSGD:
		return value.learningRate > 0 && !math.is_nan(value.learningRate) && !math.is_inf(value.learningRate)
	case ^Adam:
		if value == nil || value.step == max(u64) || !AdamConfigValid(value) ||
			len(value.parameters) != len(parameters) {
			return false
		}
		for parameter, index in parameters {
			if value.parameters[index] != parameter do return false
		}
		for first, index in value.firstMoment {
			if !AdamFinite(f64(first)) || !AdamFinite(f64(value.secondMoment[index])) || value.secondMoment[index] < 0 {
				return false
			}
		}
		return true
	}
	return false
}

PPOUpdateParameters :: proc(optimizer: SequentialOptimizer, parameters: []^core.Node) -> bool {
	switch value in optimizer {
	case nil:
		return false
	case SequentialSGD:
		for parameter in parameters {
			for weight, index in parameter.value.data {
				gradient := parameter.grad.data[index]
				step := value.learningRate*gradient
				updated := weight-step
				if !AdamFinite(f64(weight)) || !AdamFinite(f64(gradient)) ||
					!AdamFinite(f64(step)) || !AdamFinite(f64(updated)) {
					return false
				}
			}
		}
		return SGDStep(SGD{parameters, value.learningRate})
	case ^Adam:
		return AdamStep(value)
	}
	return false
}

PPOBackwardSequential :: proc(
	model: ^Sequential($maxLayers, $maxWidth, $batchCapacity),
) -> bool {
	for index := model.layerCount; index > 0; index -= 1 {
		if !LayerBackward(model.layers[index-1].layer) do return false
	}
	return true
}

// SequentialPPOTrainStep performs one full-batch PPO actor-critic update. Policy
// and value parameters must be supplied together, in policy-then-value order, to
// one optimizer so the update is atomic across both models. Forward passes use
// inference mode (dropout layers act as identity). Metrics describe the batch
// before the update. All caller buffers, model buffers, and optimizer storage
// must be disjoint; models and buffers must not be mutated concurrently. Failure
// never updates parameters, but may leave forward scratch or gradients modified.
SequentialPPOTrainStep :: proc(
	policy: ^Sequential($policyMaxLayers, $policyMaxWidth, $policyBatchCapacity),
	value: ^Sequential($valueMaxLayers, $valueMaxWidth, $valueBatchCapacity),
	observations: []f32,
	actions: []int,
	legal: []bool,
	oldLogProbabilities: []f64,
	advantages, returns: []f32,
	config: PPOConfig,
	optimizer: SequentialOptimizer,
	maxGradientNorm: f32 = 0,
) -> (PPOStats, bool) {
	if policy == nil || value == nil || rawptr(policy) == rawptr(value) || !PPOConfigValid(config) ||
		math.is_nan(maxGradientNorm) || math.is_inf(maxGradientNorm) || maxGradientNorm < 0 ||
		policy.layerCount <= 0 || policy.layerCount > policyMaxLayers ||
		value.layerCount <= 0 || value.layerCount > valueMaxLayers ||
		policy.inputWidth <= 0 || value.inputWidth <= 0 || policy.inputWidth != value.inputWidth ||
		len(observations) == 0 || len(observations)%policy.inputWidth != 0 {
		return {}, false
	}
	rows := len(observations)/policy.inputWidth
	if rows <= 0 || rows > policyBatchCapacity || rows > valueBatchCapacity {
		return {}, false
	}
	for observation in observations { if math.is_nan(observation) || math.is_inf(observation) { return {}, false } }
	for advantage in advantages { if math.is_nan(advantage) || math.is_inf(advantage) { return {}, false } }
	for target in returns { if math.is_nan(target) || math.is_inf(target) { return {}, false } }
	if len(actions) != rows || len(advantages) != rows || len(returns) != rows ||
		len(oldLogProbabilities) != rows || len(legal) == 0 || len(legal)%rows != 0 {
		return {}, false
	}
	for oldLogProbability in oldLogProbabilities { if !PPOFiniteF64(oldLogProbability) { return {}, false } }
	actionCount := len(legal)/rows
	if actionCount <= 0 || actionCount > policyMaxWidth do return {}, false
	if _, isSoftmax := SequentialLogitsOutputLayer(policy).(^Softmax); isSoftmax { return {}, false }

	policyParameterStorage: [2*policyMaxLayers]^core.Node
	valueParameterStorage: [2*valueMaxLayers]^core.Node
	policyNodeStorage: [1+3*policyMaxLayers]^core.Node
	valueNodeStorage: [1+3*valueMaxLayers]^core.Node
	policyParameters, policyNodes, policyOk := PPOSequentialParametersAndNodes(
		policy, policyParameterStorage[:], policyNodeStorage[:],
	)
	valueParameters, valueNodes, valueOk := PPOSequentialParametersAndNodes(
		value, valueParameterStorage[:], valueNodeStorage[:],
	)
	if !policyOk || !valueOk || policy.layers[policy.layerCount-1].width != actionCount ||
		value.layers[value.layerCount-1].width != 1 {
		return {}, false
	}
	policyOutputShape := policy.layers[policy.layerCount-1].output.value.shape
	valueOutputShape := value.layers[value.layerCount-1].output.value.shape
	if len(policyOutputShape) != 2 || len(valueOutputShape) != 2 ||
		policyOutputShape[1] != actionCount || valueOutputShape[1] != 1 {
		return {}, false
	}

	parameterStorage: [2*(policyMaxLayers+valueMaxLayers)]^core.Node
	parameterCount := 0
	for parameter in policyParameters {
		parameterStorage[parameterCount] = parameter
		parameterCount += 1
	}
	for parameter in valueParameters {
		for previous in policyParameters { if parameter == previous do return {}, false }
		parameterStorage[parameterCount] = parameter
		parameterCount += 1
	}
	parameters := parameterStorage[:parameterCount]
	if !PPOOptimizerValid(optimizer, parameters) do return {}, false
	for policyNode in policyNodes {
		for valueNode in valueNodes {
			if core.BuffersOverlap(policyNode.value, valueNode.value) ||
				core.BuffersOverlap(policyNode.value, valueNode.grad) ||
				core.BuffersOverlap(policyNode.grad, valueNode.value) ||
				core.BuffersOverlap(policyNode.grad, valueNode.grad) {
				return {}, false
			}
		}
	}

	if _, ok := SequentialPredict(policy, observations, training = false); !ok { return {}, false }
	if _, ok := SequentialPredict(value, observations, training = false); !ok { return {}, false }
	logits := &policy.layers[policy.layerCount-1].output
	predictedValues := &value.layers[value.layerCount-1].output
	stats, ok := PPOComputeObjectives(
		logits.value, predictedValues.value, actions, legal, oldLogProbabilities,
		advantages, returns, config,
	)
	if !ok { return {}, false }

	if !ClearGradients(policyNodes) || !ClearGradients(valueNodes) ||
		!PPOPolicyObjectiveBackward(
			logits, actions, legal, oldLogProbabilities, advantages,
			config.clipRange, config.entropyCoefficient,
		) {
		return {}, false
	}
	valueTargets := core.Tensor{shape = predictedValues.value.shape, data = returns}
	if !HuberLossBackward(predictedValues, valueTargets, config.valueHuberDelta) { return {}, false }
	for &gradient in predictedValues.grad.data {
		result := f64(gradient)*f64(config.valueCoefficient)
		if !PPOFiniteF64(result) || math.abs(result) > 3.4028234663852886e+38 { return {}, false }
		gradient = f32(result)
	}
	if !PPOBackwardSequential(policy) || !PPOBackwardSequential(value) { return {}, false }
	gradientSquaredNorm: f64
	for parameter in parameters {
		for gradient in parameter.grad.data {
			if math.is_nan(gradient) || math.is_inf(gradient) { return {}, false }
			gradientSquaredNorm += f64(gradient)*f64(gradient)
		}
	}
	if !PPOFiniteF64(gradientSquaredNorm) do return {}, false
	stats.gradientNorm = math.sqrt(gradientSquaredNorm)
	if !PPOFiniteF64(stats.gradientNorm) do return {}, false
	if maxGradientNorm > 0 && stats.gradientNorm > f64(maxGradientNorm) {
		scale := f64(maxGradientNorm)/stats.gradientNorm
		for parameter in parameters {
			for &gradient in parameter.grad.data {
				clipped := f64(gradient)*scale
				if !PPOFiniteF64(clipped) || math.abs(clipped) > 3.4028234663852886e+38 { return {}, false }
				gradient = f32(clipped)
			}
		}
		stats.gradientClipped = true
	}
	if !PPOUpdateParameters(optimizer, parameters) { return {}, false }
	return stats, true
}

PPOFitConfig :: struct {
	epochs:             int,
	batchSize:          int, // Zero selects the smaller actor/critic capacity.
	maxGradientNorm:    f32, // Zero disables global actor-critic norm clipping.
	finalLearningRate:  f32, // Zero keeps the optimizer's initial rate; otherwise linearly anneal to this rate.
}

PPOFitConfigValid :: proc(config: PPOFitConfig) -> bool {
	return config.epochs > 0 && config.batchSize >= 0 &&
		PPOFiniteF64(f64(config.maxGradientNorm)) && config.maxGradientNorm >= 0 &&
		PPOFiniteF64(f64(config.finalLearningRate)) && config.finalLearningRate >= 0
}

PPOEpochStats :: struct {
	epoch:                    int,
	policyLoss, valueLoss:    f64,
	entropy, approximateKL:   f64,
	clipFraction, totalLoss:  f64,
	explainedVariance:        f64,
	gradientNorm:             f64,
	updates:                  int,
	gradientClippedUpdates:   int,
}

PPOFitStats :: struct {
	policyLoss, valueLoss:    f64,
	entropy, approximateKL:   f64,
	clipFraction, totalLoss:  f64,
	explainedVariance:        f64, // Evaluated after the final epoch.
	gradientNorm:             f64,
	epochs, updates:           int,
	gradientClippedUpdates:   int,
	finalLearningRate:        f32,
}

// Scratch and metric storage are caller-owned. Scratch must be disjoint from the
// rollout, both models, and optimizer state. All scratch slices must be mutually
// disjoint. `observations` and `legalActions` are row-major minibatch storage.
PPOFitStorage :: struct {
	indices:             []int,
	observations:        []f32,
	actions:             []int,
	legalActions:        []bool,
	oldLogProbabilities: []f64,
	advantages, returns: []f32,
	epochMetrics:        []PPOEpochStats,
}

PPOFitMemoryRange :: struct {
	address: uintptr,
	bytes:   uintptr,
}

PPOFitMemoryRangeOf :: proc(data: rawptr, count, elementSize: int) -> (PPOFitMemoryRange, bool) {
	if count < 0 || elementSize <= 0 || uintptr(count) > max(uintptr)/uintptr(elementSize) {
		return {}, false
	}
	return PPOFitMemoryRange{uintptr(data), uintptr(count)*uintptr(elementSize)}, true
}

PPOFitMemoryRangesOverlap :: proc(a, b: PPOFitMemoryRange) -> bool {
	if a.bytes == 0 || b.bytes == 0 do return false
	if a.address >= b.address do return a.address-b.address < b.bytes
	return b.address-a.address < a.bytes
}

PPOFitStorageAndRolloutDisjoint :: proc(storage: PPOFitStorage, buffer: ^rl.RolloutBuffer) -> bool {
	ranges: [19]PPOFitMemoryRange
	ok: bool
	ranges[0], ok = PPOFitMemoryRangeOf(rawptr(raw_data(storage.indices)), len(storage.indices), size_of(int))
	if !ok do return false
	ranges[1], ok = PPOFitMemoryRangeOf(rawptr(raw_data(storage.observations)), len(storage.observations), size_of(f32))
	if !ok do return false
	ranges[2], ok = PPOFitMemoryRangeOf(rawptr(raw_data(storage.actions)), len(storage.actions), size_of(int))
	if !ok do return false
	ranges[3], ok = PPOFitMemoryRangeOf(rawptr(raw_data(storage.legalActions)), len(storage.legalActions), size_of(bool))
	if !ok do return false
	ranges[4], ok = PPOFitMemoryRangeOf(rawptr(raw_data(storage.oldLogProbabilities)), len(storage.oldLogProbabilities), size_of(f64))
	if !ok do return false
	ranges[5], ok = PPOFitMemoryRangeOf(rawptr(raw_data(storage.advantages)), len(storage.advantages), size_of(f32))
	if !ok do return false
	ranges[6], ok = PPOFitMemoryRangeOf(rawptr(raw_data(storage.returns)), len(storage.returns), size_of(f32))
	if !ok do return false
	ranges[7], ok = PPOFitMemoryRangeOf(rawptr(raw_data(storage.epochMetrics)), len(storage.epochMetrics), size_of(PPOEpochStats))
	if !ok do return false
	ranges[8], ok = PPOFitMemoryRangeOf(rawptr(raw_data(buffer.storage.observations)), len(buffer.storage.observations), size_of(f32))
	if !ok do return false
	ranges[9], ok = PPOFitMemoryRangeOf(rawptr(raw_data(buffer.storage.actions)), len(buffer.storage.actions), size_of(int))
	if !ok do return false
	ranges[10], ok = PPOFitMemoryRangeOf(rawptr(raw_data(buffer.storage.rewards)), len(buffer.storage.rewards), size_of(f32))
	if !ok do return false
	ranges[11], ok = PPOFitMemoryRangeOf(rawptr(raw_data(buffer.storage.values)), len(buffer.storage.values), size_of(f32))
	if !ok do return false
	ranges[12], ok = PPOFitMemoryRangeOf(rawptr(raw_data(buffer.storage.nextValues)), len(buffer.storage.nextValues), size_of(f32))
	if !ok do return false
	ranges[13], ok = PPOFitMemoryRangeOf(rawptr(raw_data(buffer.storage.oldLogProbabilities)), len(buffer.storage.oldLogProbabilities), size_of(f64))
	if !ok do return false
	ranges[14], ok = PPOFitMemoryRangeOf(rawptr(raw_data(buffer.storage.legalActions)), len(buffer.storage.legalActions), size_of(bool))
	if !ok do return false
	ranges[15], ok = PPOFitMemoryRangeOf(rawptr(raw_data(buffer.storage.terminated)), len(buffer.storage.terminated), size_of(bool))
	if !ok do return false
	ranges[16], ok = PPOFitMemoryRangeOf(rawptr(raw_data(buffer.storage.truncated)), len(buffer.storage.truncated), size_of(bool))
	if !ok do return false
	ranges[17], ok = PPOFitMemoryRangeOf(rawptr(raw_data(buffer.storage.advantages)), len(buffer.storage.advantages), size_of(f32))
	if !ok do return false
	ranges[18], ok = PPOFitMemoryRangeOf(rawptr(raw_data(buffer.storage.returns)), len(buffer.storage.returns), size_of(f32))
	if !ok do return false
	for index in 0..<len(ranges) {
		for previous in 0..<index {
			if PPOFitMemoryRangesOverlap(ranges[index], ranges[previous]) do return false
		}
	}
	return true
}

PPOFitBufferOverlaps :: proc(buffer: ^rl.RolloutBuffer, data: rawptr, count, elementSize: int) -> bool {
	target, ok := PPOFitMemoryRangeOf(data, count, elementSize)
	if !ok do return true
	ranges: [11]PPOFitMemoryRange
	ranges[0], ok = PPOFitMemoryRangeOf(rawptr(raw_data(buffer.storage.observations)), len(buffer.storage.observations), size_of(f32))
	if !ok do return true
	ranges[1], ok = PPOFitMemoryRangeOf(rawptr(raw_data(buffer.storage.actions)), len(buffer.storage.actions), size_of(int))
	if !ok do return true
	ranges[2], ok = PPOFitMemoryRangeOf(rawptr(raw_data(buffer.storage.rewards)), len(buffer.storage.rewards), size_of(f32))
	if !ok do return true
	ranges[3], ok = PPOFitMemoryRangeOf(rawptr(raw_data(buffer.storage.values)), len(buffer.storage.values), size_of(f32))
	if !ok do return true
	ranges[4], ok = PPOFitMemoryRangeOf(rawptr(raw_data(buffer.storage.nextValues)), len(buffer.storage.nextValues), size_of(f32))
	if !ok do return true
	ranges[5], ok = PPOFitMemoryRangeOf(rawptr(raw_data(buffer.storage.oldLogProbabilities)), len(buffer.storage.oldLogProbabilities), size_of(f64))
	if !ok do return true
	ranges[6], ok = PPOFitMemoryRangeOf(rawptr(raw_data(buffer.storage.legalActions)), len(buffer.storage.legalActions), size_of(bool))
	if !ok do return true
	ranges[7], ok = PPOFitMemoryRangeOf(rawptr(raw_data(buffer.storage.terminated)), len(buffer.storage.terminated), size_of(bool))
	if !ok do return true
	ranges[8], ok = PPOFitMemoryRangeOf(rawptr(raw_data(buffer.storage.truncated)), len(buffer.storage.truncated), size_of(bool))
	if !ok do return true
	ranges[9], ok = PPOFitMemoryRangeOf(rawptr(raw_data(buffer.storage.advantages)), len(buffer.storage.advantages), size_of(f32))
	if !ok do return true
	ranges[10], ok = PPOFitMemoryRangeOf(rawptr(raw_data(buffer.storage.returns)), len(buffer.storage.returns), size_of(f32))
	if !ok do return true
	for range in ranges {
		if PPOFitMemoryRangesOverlap(range, target) do return true
	}
	return false
}

PPOFitScratchOverlaps :: proc(storage: PPOFitStorage, data: rawptr, count, elementSize: int) -> bool {
	target, ok := PPOFitMemoryRangeOf(data, count, elementSize)
	if !ok do return true
	ranges: [8]PPOFitMemoryRange
	ranges[0], ok = PPOFitMemoryRangeOf(rawptr(raw_data(storage.indices)), len(storage.indices), size_of(int))
	if !ok do return true
	ranges[1], ok = PPOFitMemoryRangeOf(rawptr(raw_data(storage.observations)), len(storage.observations), size_of(f32))
	if !ok do return true
	ranges[2], ok = PPOFitMemoryRangeOf(rawptr(raw_data(storage.actions)), len(storage.actions), size_of(int))
	if !ok do return true
	ranges[3], ok = PPOFitMemoryRangeOf(rawptr(raw_data(storage.legalActions)), len(storage.legalActions), size_of(bool))
	if !ok do return true
	ranges[4], ok = PPOFitMemoryRangeOf(rawptr(raw_data(storage.oldLogProbabilities)), len(storage.oldLogProbabilities), size_of(f64))
	if !ok do return true
	ranges[5], ok = PPOFitMemoryRangeOf(rawptr(raw_data(storage.advantages)), len(storage.advantages), size_of(f32))
	if !ok do return true
	ranges[6], ok = PPOFitMemoryRangeOf(rawptr(raw_data(storage.returns)), len(storage.returns), size_of(f32))
	if !ok do return true
	ranges[7], ok = PPOFitMemoryRangeOf(rawptr(raw_data(storage.epochMetrics)), len(storage.epochMetrics), size_of(PPOEpochStats))
	if !ok do return true
	for range in ranges {
		if PPOFitMemoryRangesOverlap(range, target) do return true
	}
	return false
}

PPOFitLearningRate :: proc(optimizer: SequentialOptimizer) -> (f32, bool) {
	switch value in optimizer {
	case SequentialSGD:
		return value.learningRate, value.learningRate > 0 && PPOFiniteF64(f64(value.learningRate))
	case ^Adam:
		if value == nil || !AdamConfigValid(value) do return 0, false
		return value.learningRate, true
	}
	return 0, false
}

PPOFitSetLearningRate :: proc(optimizer: SequentialOptimizer, learningRate: f32) -> (SequentialOptimizer, bool) {
	if learningRate <= 0 || !PPOFiniteF64(f64(learningRate)) do return optimizer, false
	updated := optimizer
	switch &value in updated {
	case SequentialSGD:
		value.learningRate = learningRate
	case ^Adam:
		if value == nil do return optimizer, false
		value.learningRate = learningRate
	}
	return updated, true
}

PPOFitShuffle :: proc(indices: []int, randomState: ^u64) -> bool {
	if randomState == nil do return false
	for index in 0..<len(indices) { indices[index] = index }
	for index := len(indices)-1; index > 0; index -= 1 {
		bound := u64(index)+1
		threshold := (max(u64)-bound+1)%bound
		value: u64
		for {
			randomState^ += 0x9e3779b97f4a7c15
			value = randomState^
			value = (value ~ (value >> 30))*0xbf58476d1ce4e5b9
			value = (value ~ (value >> 27))*0x94d049bb133111eb
			value = value ~ (value >> 31)
			if value >= threshold do break
		}
		other := int(value%bound)
		indices[index], indices[other] = indices[other], indices[index]
	}
	return true
}

PPOFitGatherBatch :: proc(
	buffer: ^rl.RolloutBuffer,
	indices: []int,
	storage: PPOFitStorage,
) -> bool {
	for sourceIndex, row in indices {
		if sourceIndex < 0 || sourceIndex >= buffer.count do return false
		observationStart := sourceIndex*buffer.observationWidth
		batchObservationStart := row*buffer.observationWidth
		copy(
			storage.observations[batchObservationStart:batchObservationStart+buffer.observationWidth],
			buffer.storage.observations[observationStart:observationStart+buffer.observationWidth],
		)
		legalStart := sourceIndex*buffer.actionCount
		batchLegalStart := row*buffer.actionCount
		copy(
			storage.legalActions[batchLegalStart:batchLegalStart+buffer.actionCount],
			buffer.storage.legalActions[legalStart:legalStart+buffer.actionCount],
		)
		storage.actions[row] = buffer.storage.actions[sourceIndex]
		storage.oldLogProbabilities[row] = buffer.storage.oldLogProbabilities[sourceIndex]
		storage.advantages[row] = buffer.storage.advantages[sourceIndex]
		storage.returns[row] = buffer.storage.returns[sourceIndex]
	}
	return true
}

PPOFitExplainedVariance :: proc(
	value: ^Sequential($maxLayers, $maxWidth, $batchCapacity),
	buffer: ^rl.RolloutBuffer,
	observationScratch: []f32,
	chunkSize: int,
) -> (f64, bool) {
	if value == nil || chunkSize <= 0 || len(observationScratch) < chunkSize*buffer.observationWidth do return 0, false
	count := 0
	targetMean, targetM2, errorMean, errorM2: f64
	for start := 0; start < buffer.count; start += chunkSize {
		rows := min(chunkSize, buffer.count-start)
		for row in 0..<rows {
			sourceStart := (start+row)*buffer.observationWidth
			targetStart := row*buffer.observationWidth
			copy(
				observationScratch[targetStart:targetStart+buffer.observationWidth],
				buffer.storage.observations[sourceStart:sourceStart+buffer.observationWidth],
			)
		}
		predictions, ok := SequentialPredict(value, observationScratch[:rows*buffer.observationWidth], training = false)
		if !ok || len(predictions) != rows do return 0, false
		for prediction, row in predictions {
			target := f64(buffer.storage.returns[start+row])
			residual := target-f64(prediction)
			if !PPOFiniteF64(target) || !PPOFiniteF64(residual) do return 0, false
			count += 1
			targetDelta := target-targetMean
			targetMean += targetDelta/f64(count)
			targetM2 += targetDelta*(target-targetMean)
			errorDelta := residual-errorMean
			errorMean += errorDelta/f64(count)
			errorM2 += errorDelta*(residual-errorMean)
		}
	}
	if count == 0 || !PPOFiniteF64(targetM2) || !PPOFiniteF64(errorM2) do return 0, false
	targetVariance := max(targetM2/f64(count), 0)
	if targetVariance == 0 do return 0, true
	explained := 1-max(errorM2/f64(count), 0)/targetVariance
	return explained, PPOFiniteF64(explained)
}

// SequentialPPOFit runs shuffled minibatch PPO epochs over one ordered rollout.
// Rollout advantages and returns must already be computed. Random state advances
// once per epoch shuffle. A linear learning-rate schedule starts at the optimizer's
// current rate and ends at finalLearningRate on the final update; zero disables it.
// Each individual minibatch update applies policy and value gradients together.
// A failure after training begins may leave earlier successful minibatches applied.
SequentialPPOFit :: proc(
	policy: ^Sequential($policyMaxLayers, $policyMaxWidth, $policyBatchCapacity),
	value: ^Sequential($valueMaxLayers, $valueMaxWidth, $valueBatchCapacity),
	buffer: ^rl.RolloutBuffer,
	randomState: ^u64,
	config: PPOConfig,
	fitConfig: PPOFitConfig,
	optimizer: SequentialOptimizer,
	storage: PPOFitStorage,
) -> (PPOFitStats, bool) {
	if policy == nil || value == nil || rawptr(policy) == rawptr(value) || randomState == nil ||
		!rl.RolloutBufferValid(buffer) || buffer.count <= 0 || !PPOConfigValid(config) ||
		!PPOFitConfigValid(fitConfig) ||
		policy.inputWidth != buffer.observationWidth || value.inputWidth != buffer.observationWidth ||
		buffer.actionCount > policyMaxWidth || len(storage.indices) < buffer.count ||
		len(storage.epochMetrics) < fitConfig.epochs || !PPOFitStorageAndRolloutDisjoint(storage, buffer) {
		return {}, false
	}
	batchSize := fitConfig.batchSize
	if batchSize == 0 { batchSize = min(policyBatchCapacity, valueBatchCapacity) }
	batchSize = min(batchSize, buffer.count)
	if batchSize <= 0 || batchSize > policyBatchCapacity || batchSize > valueBatchCapacity ||
		buffer.count > max(int)-batchSize ||
		len(storage.observations) < batchSize*buffer.observationWidth ||
		len(storage.actions) < batchSize || len(storage.legalActions) < batchSize*buffer.actionCount ||
		len(storage.oldLogProbabilities) < batchSize || len(storage.advantages) < batchSize ||
		len(storage.returns) < batchSize {
		return {}, false
	}
	updatesPerEpoch := 1+(buffer.count-1)/batchSize
	if fitConfig.epochs > max(int)/updatesPerEpoch do return {}, false
	totalUpdates := fitConfig.epochs*updatesPerEpoch
	initialLearningRate, rateOk := PPOFitLearningRate(optimizer)
	if !rateOk do return {}, false

	policyParameterStorage: [2*policyMaxLayers]^core.Node
	valueParameterStorage: [2*valueMaxLayers]^core.Node
	policyNodeStorage: [1+3*policyMaxLayers]^core.Node
	valueNodeStorage: [1+3*valueMaxLayers]^core.Node
	policyParameters, policyNodes, policyOk := PPOSequentialParametersAndNodes(policy, policyParameterStorage[:], policyNodeStorage[:])
	valueParameters, valueNodes, valueOk := PPOSequentialParametersAndNodes(value, valueParameterStorage[:], valueNodeStorage[:])
	if !policyOk || !valueOk do return {}, false
	for node in policyNodes {
		if PPOFitScratchOverlaps(storage, rawptr(raw_data(node.value.data)), len(node.value.data), size_of(f32)) ||
			PPOFitScratchOverlaps(storage, rawptr(raw_data(node.grad.data)), len(node.grad.data), size_of(f32)) ||
			PPOFitBufferOverlaps(buffer, rawptr(raw_data(node.value.data)), len(node.value.data), size_of(f32)) ||
			PPOFitBufferOverlaps(buffer, rawptr(raw_data(node.grad.data)), len(node.grad.data), size_of(f32)) {
			return {}, false
		}
	}
	for node in valueNodes {
		if PPOFitScratchOverlaps(storage, rawptr(raw_data(node.value.data)), len(node.value.data), size_of(f32)) ||
			PPOFitScratchOverlaps(storage, rawptr(raw_data(node.grad.data)), len(node.grad.data), size_of(f32)) ||
			PPOFitBufferOverlaps(buffer, rawptr(raw_data(node.value.data)), len(node.value.data), size_of(f32)) ||
			PPOFitBufferOverlaps(buffer, rawptr(raw_data(node.grad.data)), len(node.grad.data), size_of(f32)) {
			return {}, false
		}
	}
	for node in policyNodes {
		for other in valueNodes {
			if core.BuffersOverlap(node.value, other.value) || core.BuffersOverlap(node.value, other.grad) ||
				core.BuffersOverlap(node.grad, other.value) || core.BuffersOverlap(node.grad, other.grad) {
				return {}, false
			}
		}
	}
	_ = policyParameters
	_ = valueParameters
	switch value in optimizer {
	case ^Adam:
		if PPOFitScratchOverlaps(storage, rawptr(raw_data(value.firstMoment)), len(value.firstMoment), size_of(f32)) ||
			PPOFitScratchOverlaps(storage, rawptr(raw_data(value.secondMoment)), len(value.secondMoment), size_of(f32)) ||
			PPOFitBufferOverlaps(buffer, rawptr(raw_data(value.firstMoment)), len(value.firstMoment), size_of(f32)) ||
			PPOFitBufferOverlaps(buffer, rawptr(raw_data(value.secondMoment)), len(value.secondMoment), size_of(f32)) {
			return {}, false
		}
	case SequentialSGD:
	}

	initialLearningRate64 := f64(initialLearningRate)
	finalLearningRate := initialLearningRate
	if fitConfig.finalLearningRate > 0 { finalLearningRate = fitConfig.finalLearningRate }
	fitStats: PPOFitStats
	allPolicyLoss, allValueLoss, allEntropy, allKL, allClipFraction, allTotalLoss, allGradientNorm: f64
	for epoch in 0..<fitConfig.epochs {
		if !PPOFitShuffle(storage.indices[:buffer.count], randomState) do return fitStats, false
		epochPolicyLoss, epochValueLoss, epochEntropy, epochKL, epochClipFraction, epochTotalLoss, epochGradientNorm: f64
		epochClippedUpdates, epochUpdates := 0, 0
		for start := 0; start < buffer.count; start += batchSize {
			rows := min(batchSize, buffer.count-start)
			batchIndices := storage.indices[start:start+rows]
			if !PPOFitGatherBatch(buffer, batchIndices, storage) do return fitStats, false
			learningRate := initialLearningRate
			if fitConfig.finalLearningRate > 0 {
				if totalUpdates == 1 {
					learningRate = finalLearningRate
				} else {
					progress := f64(fitStats.updates)/f64(totalUpdates-1)
					learningRate = f32(initialLearningRate64+(f64(finalLearningRate)-initialLearningRate64)*progress)
				}
			}
			optimizer, rateOk := PPOFitSetLearningRate(optimizer, learningRate)
			if !rateOk do return fitStats, false
			batchStats, updateOk := SequentialPPOTrainStep(
				policy, value,
				storage.observations[:rows*buffer.observationWidth], storage.actions[:rows],
				storage.legalActions[:rows*buffer.actionCount], storage.oldLogProbabilities[:rows],
				storage.advantages[:rows], storage.returns[:rows], config, optimizer,
				fitConfig.maxGradientNorm,
			)
			if !updateOk do return fitStats, false
			weight := f64(rows)
			epochPolicyLoss += batchStats.policyLoss*weight
			epochValueLoss += batchStats.valueLoss*weight
			epochEntropy += batchStats.entropy*weight
			epochKL += batchStats.approximateKL*weight
			epochClipFraction += batchStats.clipFraction*weight
			epochTotalLoss += batchStats.totalLoss*weight
			epochGradientNorm += batchStats.gradientNorm*weight
			if batchStats.gradientClipped { epochClippedUpdates += 1 }
			epochUpdates += 1
			fitStats.updates += 1
		}
		divisor := f64(buffer.count)
		explainedVariance, explainedOk := PPOFitExplainedVariance(value, buffer, storage.observations, batchSize)
		if !explainedOk do return fitStats, false
		epochMetric := PPOEpochStats{
			epoch = epoch+1,
			policyLoss = epochPolicyLoss/divisor,
			valueLoss = epochValueLoss/divisor,
			entropy = epochEntropy/divisor,
			approximateKL = epochKL/divisor,
			clipFraction = epochClipFraction/divisor,
			totalLoss = epochTotalLoss/divisor,
			explainedVariance = explainedVariance,
			gradientNorm = epochGradientNorm/divisor,
			updates = epochUpdates,
			gradientClippedUpdates = epochClippedUpdates,
		}
		storage.epochMetrics[epoch] = epochMetric
		allPolicyLoss += epochPolicyLoss
		allValueLoss += epochValueLoss
		allEntropy += epochEntropy
		allKL += epochKL
		allClipFraction += epochClipFraction
		allTotalLoss += epochTotalLoss
		allGradientNorm += epochGradientNorm
		fitStats.gradientClippedUpdates += epochClippedUpdates
		fitStats.epochs += 1
		fitStats.explainedVariance = explainedVariance
	}
	presentationCount := f64(buffer.count)*f64(fitConfig.epochs)
	fitStats.policyLoss = allPolicyLoss/presentationCount
	fitStats.valueLoss = allValueLoss/presentationCount
	fitStats.entropy = allEntropy/presentationCount
	fitStats.approximateKL = allKL/presentationCount
	fitStats.clipFraction = allClipFraction/presentationCount
	fitStats.totalLoss = allTotalLoss/presentationCount
	fitStats.gradientNorm = allGradientNorm/presentationCount
	fitStats.finalLearningRate = finalLearningRate
	return fitStats, true
}
