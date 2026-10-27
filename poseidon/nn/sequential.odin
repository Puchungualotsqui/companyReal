package nn

import "../core"
import "core:math"

SequentialOperation :: union { Dense, Relu, Sigmoid, Tanh, Softmax, Dropout }

// Each layer reserves maxWidth squared weights and batchCapacity * maxWidth values,
// plus a dropout mask of the latter size even for non-dropout layers.
// Initialize in its final location; do not copy or move an initialized model.
SequentialLayer :: struct($maxWidth, $batchCapacity: int) {
	outputData, outputGrad: [maxWidth * batchCapacity]f32,
	maskData: [maxWidth * batchCapacity]f32,
	weightData, weightGrad: [maxWidth * maxWidth]f32,
	biasData, biasGrad: [maxWidth]f32,
	outputShape, weightShape: [2]int,
	biasShape: [1]int,
	output, weights, bias: core.Node,
	operation: SequentialOperation, // Keep the active variant unchanged after wiring.
	layer: Layer,
	width: int,
}

Sequential :: struct($maxLayers, $maxWidth, $batchCapacity: int) {
	inputData, inputGrad: [maxWidth * batchCapacity]f32,
	inputShape: [2]int,
	input: core.Node,
	layers: [maxLayers]SequentialLayer(maxWidth, batchCapacity),
	inputWidth, layerCount: int,
	randomState: u64,
	self: rawptr,
}

MSE :: struct {}
MAE :: struct {}
Huber :: struct { delta: f32 }
BCEWithLogits :: struct {}
CCEWithLogits :: struct {}
SequentialLoss :: union { MSE, MAE, Huber, BCEWithLogits, CCEWithLogits }

SequentialSGD :: struct { learningRate: f32 }
SequentialOptimizer :: union { SequentialSGD, ^Adam }

// Losses are data losses only; they do not include any L2 penalty.
EpochMetrics :: struct {
	epoch: int,
	trainingLoss, validationLoss: f32,
	hasValidation: bool,
}

// A non-nil config enables early stopping and requires validation and a result.
// An improvement must reduce validation loss by more than minDelta. patience is
// the number of consecutive non-improving epochs that triggers a stop; zero
// and one both stop at the first non-improvement.
SequentialEarlyStopping :: struct {
	patience: int,
	minDelta: f32,
	result: ^SequentialEarlyStoppingResult,
}

// Describes the actual run, even when the best checkpoint is restored. The best
// epoch is selected using minDelta, not necessarily the absolute lowest loss.
SequentialEarlyStoppingResult :: struct {
	epochsRan: int,
	bestEpoch: int,
	bestValidationLoss: f32,
	stopped: bool,
}

// Seed zero is supported and maps to a fixed nonzero generator state.
SequentialInit :: proc(model: ^Sequential($maxLayers, $maxWidth, $batchCapacity), inputWidth: int, seed: u64 = 1) -> bool {
	if model == nil || maxLayers <= 0 || maxWidth <= 0 || batchCapacity <= 0 || inputWidth <= 0 || inputWidth > maxWidth { return false }
	model^ = {}
	model.inputWidth = inputWidth
	model.randomState = seed
	if seed == 0 { model.randomState = 0x9e3779b97f4a7c15 }
	model.inputShape = {batchCapacity, inputWidth}
	model.input = {value = core.Tensor{model.inputShape[:], model.inputData[:batchCapacity * inputWidth]}, grad = core.Tensor{model.inputShape[:], model.inputGrad[:batchCapacity * inputWidth]}}
	model.self = rawptr(model)
	return true
}

// Dense weights use seeded Xavier uniform initialization; biases start at zero.
SequentialAddDense :: proc(model: ^Sequential($maxLayers, $maxWidth, $batchCapacity), width: int) -> bool {
	if model == nil || model.self != rawptr(model) || model.layerCount >= maxLayers || width <= 0 || width > maxWidth { return false }
	input := &model.input
	inputWidth := model.inputWidth
	if model.layerCount > 0 {
		previous := &model.layers[model.layerCount-1]
		input = &previous.output
		inputWidth = previous.width
	}
	item := &model.layers[model.layerCount]
	item.width = width
	item.outputShape = {batchCapacity, width}
	item.weightShape = {inputWidth, width}
	item.biasShape = {width}
	item.output = {value = core.Tensor{item.outputShape[:], item.outputData[:batchCapacity * width]}, grad = core.Tensor{item.outputShape[:], item.outputGrad[:batchCapacity * width]}}
	item.weights = {value = core.Tensor{item.weightShape[:], item.weightData[:inputWidth * width]}, grad = core.Tensor{item.weightShape[:], item.weightGrad[:inputWidth * width]}}
	item.bias = {value = core.Tensor{item.biasShape[:], item.biasData[:width]}, grad = core.Tensor{item.biasShape[:], item.biasGrad[:width]}}
	limit := math.sqrt(f32(6) / f32(inputWidth + width))
	for &weight in item.weights.value.data {
		state := model.randomState
		state ~= state << 13
		state ~= state >> 7
		state ~= state << 17
		model.randomState = state
		weight = (f32(u32(state >> 40)) / f32(1 << 24) * 2 - 1) * limit
	}
	item.operation = Dense{input, &item.weights, &item.bias, &item.output}
	switch &operation in item.operation {
	case Dense:
		item.layer = &operation
	case nil, Relu, Sigmoid, Tanh, Softmax, Dropout:
		return false
	}
	model.layerCount += 1
	return true
}

SequentialAddActivation :: proc(model: ^Sequential($maxLayers, $maxWidth, $batchCapacity), kind: ActivationKind) -> bool {
	if model == nil || model.self != rawptr(model) || model.layerCount >= maxLayers { return false }
	switch kind {
	case .Relu, .Sigmoid, .Tanh, .Softmax:
	case:
		return false
	}
	input := &model.input
	width := model.inputWidth
	if model.layerCount > 0 {
		previous := &model.layers[model.layerCount-1]
		input = &previous.output
		width = previous.width
	}
	item := &model.layers[model.layerCount]
	item.width = width
	item.outputShape = {batchCapacity, width}
	item.output = {value = core.Tensor{item.outputShape[:], item.outputData[:batchCapacity * width]}, grad = core.Tensor{item.outputShape[:], item.outputGrad[:batchCapacity * width]}}
	switch kind {
	case .Relu:
		item.operation = Relu{input, &item.output}
	case .Sigmoid:
		item.operation = Sigmoid{input, &item.output}
	case .Tanh:
		item.operation = Tanh{input, &item.output}
	case .Softmax:
		item.operation = Softmax{input, &item.output}
	}
	switch &operation in item.operation {
	case nil, Dense, Dropout:
		return false
	case Relu:
		item.layer = &operation
	case Sigmoid:
		item.layer = &operation
	case Tanh:
		item.layer = &operation
	case Softmax:
		item.layer = &operation
	}
	model.layerCount += 1
	return true
}

// Rate must be in [0, 1). Dropout shares the model RNG with weight initialization
// and other dropout layers, so training affects subsequent initialization. Its mask
// is inline storage; initialized models must remain in their final location.
// Training uses inverted dropout; prediction and evaluation use identity.
SequentialAddDropout :: proc(model: ^Sequential($maxLayers, $maxWidth, $batchCapacity), rate: f32 = 0.5) -> bool {
	if model == nil || model.self != rawptr(model) || model.layerCount < 0 || model.layerCount >= maxLayers || !(rate >= 0 && rate < 1) { return false }
	input := &model.input
	width := model.inputWidth
	if model.layerCount > 0 {
		previous := &model.layers[model.layerCount-1]
		input = &previous.output
		width = previous.width
	}
	if width <= 0 || width > maxWidth || model.randomState == 0 { return false }
	item := &model.layers[model.layerCount]
	item.width = width
	item.outputShape = {batchCapacity, width}
	item.output = {value = core.Tensor{item.outputShape[:], item.outputData[:batchCapacity * width]}, grad = core.Tensor{item.outputShape[:], item.outputGrad[:batchCapacity * width]}}
	item.operation = Dropout{input, &item.output, item.maskData[:batchCapacity * width], rate, &model.randomState, false}
	switch &operation in item.operation {
	case Dropout:
		item.layer = &operation
	case nil, Dense, Relu, Sigmoid, Tanh, Softmax:
		return false
	}
	model.layerCount += 1
	return true
}

// Inputs must not overlap model storage. The borrowed result is invalidated by
// the next prediction, fit, or initialization. One to batchCapacity rows are accepted.
// Inference is the default and does not advance the dropout RNG. Set training
// to sample dropout. Any prediction invalidates previous masks and activations.
SequentialPredict :: proc(model: ^Sequential($maxLayers, $maxWidth, $batchCapacity), inputs: []f32, training: bool = false) -> ([]f32, bool) {
	if model == nil || model.self != rawptr(model) || model.layerCount <= 0 || model.layerCount > maxLayers ||
		model.inputWidth <= 0 || model.inputWidth > maxWidth || len(inputs) == 0 ||
		len(inputs) % model.inputWidth != 0 || len(inputs) / model.inputWidth > batchCapacity { return nil, false }
	rows := len(inputs) / model.inputWidth
	model.inputShape[0] = rows
	model.input.value.data = model.inputData[:len(inputs)]
	model.input.grad.data = model.inputGrad[:len(inputs)]
	copy(model.input.value.data, inputs)
	for &item in model.layers[:model.layerCount] {
		item.outputShape[0] = rows
		item.output.value.data = item.outputData[:rows * item.width]
		item.output.grad.data = item.outputGrad[:rows * item.width]
		if dropout, isDropout := item.layer.(^Dropout); isDropout {
			if dropout == nil { return nil, false }
			dropout.training = training
			dropout.mask = item.maskData[:rows * item.width]
		}
		if !LayerForward(item.layer) { return nil, false }
	}
	return model.layers[model.layerCount-1].output.value.data, true
}

// Returns the last layer that is not dropout, or nil if all layers are dropout.
// The caller must validate the model and layer count first.
SequentialLogitsOutputLayer :: proc(model: ^Sequential($maxLayers, $maxWidth, $batchCapacity)) -> Layer {
	for index := model.layerCount; index > 0; index -= 1 {
		layer := model.layers[index-1].layer
		if _, isDropout := layer.(^Dropout); !isDropout { return layer }
	}
	return nil
}

// Full-batch SGD, without shuffling. Inputs and targets must not overlap model
// storage. Logits losses reject a softmax before any trailing dropout; BCE also
// rejects a sigmoid there. Returns loss after the final update; epochs zero evaluates only.
// Failure may leave partial updates.
SequentialFit :: proc(model: ^Sequential($maxLayers, $maxWidth, $batchCapacity), inputs, targets: []f32, loss: SequentialLoss = MSE{}, epochs: int = 200, learningRate: f32 = 0.1) -> (f32, bool) {
	if model == nil || model.self != rawptr(model) || model.layerCount <= 0 || model.layerCount > maxLayers ||
		model.inputWidth <= 0 || model.inputWidth > maxWidth || len(inputs) == 0 ||
		len(inputs) % model.inputWidth != 0 || len(inputs) / model.inputWidth > batchCapacity ||
		len(targets) != (len(inputs) / model.inputWidth) * model.layers[model.layerCount-1].width ||
		epochs < 0 || !(learningRate > 0) || math.is_inf(learningRate) { return 0, false }
	switch value in loss {
	case nil:
		return 0, false
	case MSE, MAE:
	case BCEWithLogits:
		switch finalLayer in SequentialLogitsOutputLayer(model) {
		case ^Sigmoid, ^Softmax:
			return 0, false
		case nil, ^Dense, ^Relu, ^Tanh, ^Dropout:
		}
	case CCEWithLogits:
		if _, isSoftmax := SequentialLogitsOutputLayer(model).(^Softmax); isSoftmax { return 0, false }
		width := model.layers[model.layerCount-1].width
		if width <= 0 || width > maxWidth { return 0, false }
		shape := [2]int{len(inputs) / model.inputWidth, width}
		target := core.Tensor{shape[:], targets}
		if !CategoricalLogitsValid(target, target) { return 0, false }
	case Huber:
		if !(value.delta > 0) || math.is_inf(value.delta) { return 0, false }
	}
	output := &model.layers[model.layerCount-1].output
	parameters: [2 * maxLayers]^core.Node
	parameterCount := 0
	for &item in model.layers[:model.layerCount] {
		switch layer in item.layer {
		case nil:
			return 0, false
		case ^Dense:
			parameters[parameterCount] = layer.weights
			parameters[parameterCount+1] = layer.bias
			parameterCount += 2
		case ^Relu, ^Sigmoid, ^Tanh, ^Softmax, ^Dropout:
		}
	}
	for epoch in 0..=epochs {
		_, ok := SequentialPredict(model, inputs, epoch < epochs)
		if !ok { return 0, false }
		target := core.Tensor{output.value.shape, targets}
		result: f32
		switch value in loss {
		case nil:
			return 0, false
		case MSE:
			result, ok = MeanSquaredError(output.value, target)
		case MAE:
			result, ok = MeanAbsoluteError(output.value, target)
		case Huber:
			result, ok = HuberLoss(output.value, target, value.delta)
		case BCEWithLogits:
			result, ok = BinaryCrossEntropyWithLogits(output.value, target)
		case CCEWithLogits:
			result, ok = CategoricalCrossEntropyWithLogits(output.value, target)
		}
		if !ok || math.is_nan(result) || math.is_inf(result) { return 0, false }
		if epoch == epochs { return result, true }
		for &gradient in model.input.grad.data { gradient = 0 }
		for &item in model.layers[:model.layerCount] {
			for &gradient in item.output.grad.data { gradient = 0 }
		}
		for parameter in parameters[:parameterCount] {
			for &gradient in parameter.grad.data { gradient = 0 }
		}
		switch value in loss {
		case nil:
			return 0, false
		case MSE:
			ok = MeanSquaredErrorBackward(output, target)
		case MAE:
			ok = MeanAbsoluteErrorBackward(output, target)
		case Huber:
			ok = HuberLossBackward(output, target, value.delta)
		case BCEWithLogits:
			ok = BinaryCrossEntropyWithLogitsBackward(output, target)
		case CCEWithLogits:
			ok = CategoricalCrossEntropyWithLogitsBackward(output, target)
		}
		if !ok { return 0, false }
		for index := model.layerCount; index > 0; index -= 1 {
			if !LayerBackward(model.layers[index-1].layer) { return 0, false }
		}
		if !SGDStep(SGD{parameters[:parameterCount], learningRate}) { return 0, false }
	}
	return 0, false
}

// Writes dense weights and biases in layer order into storage; the returned slice
// borrows storage. Use it to initialize a caller-owned Adam in its final location.
SequentialParameters :: proc(model: ^Sequential($maxLayers, $maxWidth, $batchCapacity), storage: []^core.Node) -> ([]^core.Node, bool) {
	if model == nil || model.self != rawptr(model) || model.layerCount <= 0 || model.layerCount > maxLayers { return nil, false }
	count := 0
	for &item in model.layers[:model.layerCount] {
		switch layer in item.layer {
		case nil:
			return nil, false
		case ^Dense:
			if layer == nil || layer.weights == nil || layer.bias == nil { return nil, false }
			count += 2
		case ^Relu, ^Sigmoid, ^Tanh, ^Softmax, ^Dropout:
			if layer == nil { return nil, false }
		}
	}
	if len(storage) < count { return nil, false }
	count = 0
	for &item in model.layers[:model.layerCount] {
		switch layer in item.layer {
		case ^Dense:
			storage[count], storage[count+1] = layer.weights, layer.bias
			count += 2
		case nil, ^Relu, ^Sigmoid, ^Tanh, ^Softmax, ^Dropout:
		}
	}
	return storage[:count], true
}

// Evaluate contiguous rows without changing parameters or optimizer state.
// Prediction scratch is overwritten; inputs and targets must not overlap it.
SequentialEvaluateBatches :: proc(model: ^Sequential($maxLayers, $maxWidth, $batchCapacity), inputs, targets: []f32, batchSize: int, loss: SequentialLoss) -> (f32, bool) {
	if model == nil || model.self != rawptr(model) || model.layerCount <= 0 || model.layerCount > maxLayers ||
		model.inputWidth <= 0 || model.inputWidth > maxWidth || batchSize <= 0 || batchSize > batchCapacity ||
		len(inputs) == 0 || len(inputs) % model.inputWidth != 0 { return 0, false }
	outputWidth := model.layers[model.layerCount-1].width
	if outputWidth <= 0 || outputWidth > maxWidth || len(targets) % outputWidth != 0 ||
		len(targets) / outputWidth != len(inputs) / model.inputWidth { return 0, false }
	rows := len(inputs) / model.inputWidth
	output := &model.layers[model.layerCount-1].output
	width := model.layers[model.layerCount-1].width
	total: f64
	for start := 0; start < rows; {
		count := min(batchSize, rows-start)
		_, ok := SequentialPredict(model, inputs[start*model.inputWidth:(start+count)*model.inputWidth])
		if !ok { return 0, false }
		target := core.Tensor{output.value.shape, targets[start*width:(start+count)*width]}
		result: f32
		switch value in loss {
		case nil:
			return 0, false
		case MSE:
			result, ok = MeanSquaredError(output.value, target)
		case MAE:
			result, ok = MeanAbsoluteError(output.value, target)
		case Huber:
			result, ok = HuberLoss(output.value, target, value.delta)
		case BCEWithLogits:
			result, ok = BinaryCrossEntropyWithLogits(output.value, target)
		case CCEWithLogits:
			result, ok = CategoricalCrossEntropyWithLogits(output.value, target)
		}
		if !ok || math.is_nan(result) || math.is_inf(result) { return 0, false }
		total += f64(result) * f64(count) / f64(rows)
		start += count
	}
	return f32(total), true
}

// Row-major inputs and targets can contain any positive number of rows. indices
// must hold one int per row; staging is local and bounded by model capacity.
// A zero batchSize selects the model's batch capacity. Logits losses reject a
// softmax before trailing dropout; BCE also rejects a sigmoid there.
// With shuffle enabled, state must be non-nil and persists across calls; zero
// seeds the same fixed nonzero state as SequentialInit. Each epoch starts from
// canonical row order, then shuffles. No shuffle occurs for evaluation only.
// Return the row-weighted mean loss over the entire dataset after all updates.
// Optional validation inputs and targets must both be nonempty and have matching
// rows. Optional history must hold at least epochs entries; entries use 1-based
// epoch numbers and are written only after both evaluations succeed. Zero epochs
// writes no history and returns the training loss. No buffers are retained.
// l2 is finite and nonnegative. It adds l2 * weights to each dense weight
// gradient per batch (objective penalty l2/2 * sum(weights^2)); biases are
// excluded. Returned and recorded losses are data losses, without the penalty.
// A non-nil earlyStopping monitors post-epoch validation loss. Its result is
// reset after prevalidation on every call, including zero epochs; bestEpoch is
// 1-based, or zero when no epoch completed. There is no cross-call continuity.
// bestSnapshot requires earlyStopping and is caller-owned checkpoint storage,
// disjoint from all other storage and large enough for CheckpointWrite. Its
// prevalidation writes the initial checkpoint; zero epochs do not touch it.
// Adam's parameter and moment slices must remain valid for restore.
// If bestSnapshot is non-nil and at least one epoch completes, successful stops
// and normal completion restore the best model, Adam state, and non-nil shuffle
// state, returning that epoch's training loss. Otherwise the current model and
// its training loss are returned. History and result describe the actual run.
// Checkpoints omit transient activations and gradients and do not store fit
// configuration such as l2; supply the desired configuration when resuming.
// Training forwards sample dropout; all reported and validation losses use inference.
// All caller buffers, model storage, Adam storage and state must not overlap.
// Invalid arguments leave the result untouched; snapshot prevalidation may write
// its buffer. Later failure can leave partial updates, completed history/result
// entries, modified indices, state, snapshot, or scratch; no rollback is promised.
SequentialFitBatches :: proc(model: ^Sequential($maxLayers, $maxWidth, $batchCapacity), inputs, targets: []f32, indices: []int, state: ^u64, batchSize: int = 0, loss: SequentialLoss = MSE{}, epochs: int = 200, optimizer: SequentialOptimizer = SequentialSGD{0.1}, shuffle: bool = true, validationInputs: []f32 = nil, validationTargets: []f32 = nil, history: []EpochMetrics = nil, l2: f32 = 0, earlyStopping: ^SequentialEarlyStopping = nil, bestSnapshot: []u8 = nil) -> (f32, bool) {
	actualBatchSize := batchSize
	if actualBatchSize == 0 { actualBatchSize = batchCapacity }
	if model == nil || model.self != rawptr(model) || model.layerCount <= 0 || model.layerCount > maxLayers ||
		model.inputWidth <= 0 || model.inputWidth > maxWidth || len(inputs) == 0 ||
		len(inputs) % model.inputWidth != 0 || actualBatchSize <= 0 || actualBatchSize > batchCapacity || epochs < 0 { return 0, false }
	rows := len(inputs) / model.inputWidth
	outputWidth := model.layers[model.layerCount-1].width
	if outputWidth <= 0 || outputWidth > maxWidth || len(targets) % outputWidth != 0 ||
		len(targets) / outputWidth != rows || len(indices) < rows || (shuffle && epochs > 0 && state == nil) { return 0, false }
	hasValidation := validationInputs != nil || validationTargets != nil
	if !(l2 >= 0) || math.is_inf(l2) { return 0, false }
	if bestSnapshot != nil && earlyStopping == nil { return 0, false }
	if earlyStopping != nil && (!hasValidation || earlyStopping.result == nil || earlyStopping.patience < 0 ||
		!(earlyStopping.minDelta >= 0) || math.is_inf(earlyStopping.minDelta)) { return 0, false }
	if history != nil && len(history) < epochs { return 0, false }
	if hasValidation && (len(validationInputs) == 0 || len(validationTargets) == 0 ||
		len(validationInputs) % model.inputWidth != 0 || len(validationTargets) % outputWidth != 0 ||
		len(validationInputs) / model.inputWidth != len(validationTargets) / outputWidth) { return 0, false }
	switch value in loss {
	case nil:
		return 0, false
	case MSE, MAE:
	case Huber:
		if !(value.delta > 0) || math.is_inf(value.delta) { return 0, false }
	case BCEWithLogits:
		switch finalLayer in SequentialLogitsOutputLayer(model) {
		case ^Sigmoid, ^Softmax:
			return 0, false
		case nil, ^Dense, ^Relu, ^Tanh, ^Dropout:
		}
	case CCEWithLogits:
		if _, isSoftmax := SequentialLogitsOutputLayer(model).(^Softmax); isSoftmax { return 0, false }
		shape := [2]int{rows, outputWidth}
		target := core.Tensor{shape[:], targets}
		if !CategoricalLogitsValid(target, target) { return 0, false }
		if hasValidation {
			validationShape := [2]int{len(validationInputs) / model.inputWidth, outputWidth}
			validationTarget := core.Tensor{validationShape[:], validationTargets}
			if !CategoricalLogitsValid(validationTarget, validationTarget) { return 0, false }
		}
	}
	parameterStorage: [2 * maxLayers]^core.Node
	parameters, valid := SequentialParameters(model, parameterStorage[:])
	if !valid { return 0, false }
	parameterElements := 0
	for parameter in parameters {
		if !core.TensorValid(parameter.value) || !core.TensorValid(parameter.grad) || !core.SameShape(parameter.value, parameter.grad) { return 0, false }
		parameterElements += len(parameter.value.data)
	}
	switch value in optimizer {
	case nil:
		return 0, false
	case SequentialSGD:
		if !(value.learningRate > 0) || math.is_inf(value.learningRate) { return 0, false }
	case ^Adam:
		if value == nil || len(value.parameters) != len(parameters) ||
			len(value.firstMoment) != parameterElements || len(value.secondMoment) != parameterElements ||
			!(value.learningRate > 0) || math.is_inf(value.learningRate) ||
			!(value.beta1 >= 0 && value.beta1 < 1) || !(value.beta2 >= 0 && value.beta2 < 1) ||
			!(value.epsilon > 0) || math.is_inf(value.epsilon) { return 0, false }
		for parameter, index in parameters {
			if value.parameters[index] != parameter { return 0, false }
		}
		if epochs > 0 && value.step == max(u64) { return 0, false }
		for moment, index in value.firstMoment {
			second := value.secondMoment[index]
			if math.is_nan(moment) || math.is_inf(moment) || math.is_nan(second) || math.is_inf(second) || second < 0 { return 0, false }
		}
	}
	// Reject invalid data before any updates, including invalid BCE targets.
	for x in inputs { if math.is_nan(x) || math.is_inf(x) { return 0, false } }
	for x in targets {
		if math.is_nan(x) || math.is_inf(x) { return 0, false }
		if _, isBCE := loss.(BCEWithLogits); isBCE && (x < 0 || x > 1) { return 0, false }
	}
	for x in validationInputs { if math.is_nan(x) || math.is_inf(x) { return 0, false } }
	for x in validationTargets {
		if math.is_nan(x) || math.is_inf(x) { return 0, false }
		if _, isBCE := loss.(BCEWithLogits); isBCE && (x < 0 || x > 1) { return 0, false }
	}
	snapshotEnabled := bestSnapshot != nil && epochs > 0
	snapshotAdam: ^Adam
	if value, isAdam := optimizer.(^Adam); isAdam { snapshotAdam = value }
	snapshotSize := 0
	if snapshotEnabled {
		shuffleState: u64
		if state != nil { shuffleState = state^ }
		ok: bool
		snapshotSize, ok = CheckpointWrite(model, snapshotAdam, shuffleState, bestSnapshot)
		if !ok { return 0, false }
	}
	if earlyStopping != nil { earlyStopping.result^ = {} }
	badEpochs := 0
	bestTrainingLoss: f32
	inputBatch: [maxWidth * batchCapacity]f32
	targetBatch: [maxWidth * batchCapacity]f32
	output := &model.layers[model.layerCount-1].output
	for epoch in 0..=epochs {
		training := epoch < epochs
		for i in 0..<rows { indices[i] = i }
		if training && shuffle {
			if state^ == 0 { state^ = 0x9e3779b97f4a7c15 }
			for i := rows-1; i > 0; i -= 1 {
				random := state^
				random ~= random << 13
				random ~= random >> 7
				random ~= random << 17
				state^ = random
				j := int(random % u64(i+1))
				indices[i], indices[j] = indices[j], indices[i]
			}
		}
		total: f64
		for start := 0; start < rows; {
			count := min(actualBatchSize, rows-start)
			for i in 0..<count {
				row := indices[start+i]
				copy(inputBatch[i*model.inputWidth:(i+1)*model.inputWidth], inputs[row*model.inputWidth:(row+1)*model.inputWidth])
				copy(targetBatch[i*outputWidth:(i+1)*outputWidth], targets[row*outputWidth:(row+1)*outputWidth])
			}
			_, ok := SequentialPredict(model, inputBatch[:count*model.inputWidth], training)
			if !ok { return 0, false }
			target := core.Tensor{output.value.shape, targetBatch[:count*outputWidth]}
			result: f32
			switch value in loss {
			case nil:
				return 0, false
			case MSE:
				result, ok = MeanSquaredError(output.value, target)
			case MAE:
				result, ok = MeanAbsoluteError(output.value, target)
			case Huber:
				result, ok = HuberLoss(output.value, target, value.delta)
			case BCEWithLogits:
				result, ok = BinaryCrossEntropyWithLogits(output.value, target)
			case CCEWithLogits:
				result, ok = CategoricalCrossEntropyWithLogits(output.value, target)
			}
			if !ok || math.is_nan(result) || math.is_inf(result) { return 0, false }
			if !training {
				total += f64(result) * f64(count) / f64(rows)
				start += count
				continue
			}
			for &gradient in model.input.grad.data { gradient = 0 }
			for &item in model.layers[:model.layerCount] { for &gradient in item.output.grad.data { gradient = 0 } }
			for parameter in parameters { for &gradient in parameter.grad.data { gradient = 0 } }
			switch value in loss {
			case nil:
				return 0, false
			case MSE:
				ok = MeanSquaredErrorBackward(output, target)
			case MAE:
				ok = MeanAbsoluteErrorBackward(output, target)
			case Huber:
				ok = HuberLossBackward(output, target, value.delta)
			case BCEWithLogits:
				ok = BinaryCrossEntropyWithLogitsBackward(output, target)
			case CCEWithLogits:
				ok = CategoricalCrossEntropyWithLogitsBackward(output, target)
			}
			if !ok { return 0, false }
			for index := model.layerCount; index > 0; index -= 1 {
				if !LayerBackward(model.layers[index-1].layer) { return 0, false }
			}
			if l2 != 0 {
				// Validate every adjusted gradient before modifying any of them.
				for &item in model.layers[:model.layerCount] {
					if layer, dense := item.layer.(^Dense); dense {
						for weight, i in layer.weights.value.data {
							adjusted := f64(layer.weights.grad.data[i]) + f64(l2)*f64(weight)
							if !AdamFinite(adjusted) { return 0, false }
						}
					}
				}
				for &item in model.layers[:model.layerCount] {
					if layer, dense := item.layer.(^Dense); dense {
						for weight, i in layer.weights.value.data {
							layer.weights.grad.data[i] = f32(f64(layer.weights.grad.data[i]) + f64(l2)*f64(weight))
						}
					}
				}
			}
			switch value in optimizer {
			case nil:
				return 0, false
			case SequentialSGD:
				// SGDStep does not check arithmetic; preflight the entire step.
				for parameter in parameters {
					for weight, i in parameter.value.data {
						gradient := parameter.grad.data[i]
						if !AdamFinite(f64(weight)) || !AdamFinite(f64(gradient)) ||
							!AdamFinite(f64(value.learningRate)*f64(gradient)) ||
							!AdamFinite(f64(weight) - f64(f32(f64(value.learningRate)*f64(gradient)))) { return 0, false }
					}
				}
				ok = SGDStep(SGD{parameters, value.learningRate})
			case ^Adam:
				ok = AdamStep(value)
			}
			if !ok { return 0, false }
			start += count
		}
		if !training { return f32(total), true }
		if history != nil || hasValidation {
			trainingLoss, ok := SequentialEvaluateBatches(model, inputs, targets, actualBatchSize, loss)
			if !ok { return 0, false }
			validationLoss: f32
			if hasValidation {
				validationLoss, ok = SequentialEvaluateBatches(model, validationInputs, validationTargets, actualBatchSize, loss)
				if !ok { return 0, false }
			}
			if history != nil {
				history[epoch] = EpochMetrics{epoch + 1, trainingLoss, validationLoss, hasValidation}
			}
			if earlyStopping != nil {
				result := earlyStopping.result
				result.epochsRan = epoch + 1
				if result.bestEpoch == 0 || f64(result.bestValidationLoss) - f64(validationLoss) > f64(earlyStopping.minDelta) {
					if snapshotEnabled {
						shuffleState: u64
						if state != nil { shuffleState = state^ }
						ok: bool
						snapshotSize, ok = CheckpointWrite(model, snapshotAdam, shuffleState, bestSnapshot)
						if !ok { return 0, false }
						bestTrainingLoss = trainingLoss
					}
					result.bestEpoch = epoch + 1
					result.bestValidationLoss = validationLoss
					badEpochs = 0
				} else {
					badEpochs += 1
					if badEpochs >= max(1, earlyStopping.patience) {
						result.stopped = true
						if snapshotEnabled {
							if !SequentialRestoreBest(model, snapshotAdam, state, bestSnapshot[:snapshotSize]) { return 0, false }
							return bestTrainingLoss, true
						}
						return trainingLoss, true
					}
				}
			}
		}
		if snapshotEnabled && epoch == epochs-1 {
			if !SequentialRestoreBest(model, snapshotAdam, state, bestSnapshot[:snapshotSize]) { return 0, false }
			return bestTrainingLoss, true
		}
	}
	return 0, false
}

SequentialRestoreBest :: proc(model: ^Sequential($maxLayers, $maxWidth, $batchCapacity), adam: ^Adam, state: ^u64, snapshot: []u8) -> bool {
	shuffleState: u64
	parameters: []^core.Node
	first, second: []f32
	if adam != nil {
		parameters, first, second = adam.parameters, adam.firstMoment, adam.secondMoment
	}
	if !CheckpointRead(model, adam, &shuffleState, snapshot, parameters, first, second) { return false }
	if state != nil { state^ = shuffleState }
	return true
}

