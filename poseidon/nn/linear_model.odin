package nn

import "../core"
import "core:math"

// LinearModel is a single linear dense layer with capacity for batchCapacity rows.
// inputCount, outputCount and batchCapacity must be positive compile-time constants. All storage
// is inline; initialize in its final location and do not copy or move it afterward.
LinearModel :: struct($inputCount, $outputCount, $batchCapacity: int) {
	inputData, inputGrad: [inputCount * batchCapacity]f32,
	weightData, weightGrad: [inputCount * outputCount]f32,
	biasData, biasGrad: [outputCount]f32,
	outputData, outputGrad: [outputCount * batchCapacity]f32,
	inputShape, weightShape, outputShape: [2]int,
	biasShape: [1]int,
	input, weights, bias, output: core.Node,
	dense: Dense,
	layers: [1]Layer,
	parameters: [2]^core.Node,
	nodes: [4]^core.Node,
	self: rawptr,
}

// LinearInit resets parameters to zero and wires the model in place.
// Reinitializing discards trained parameters.
LinearInit :: proc(model: ^LinearModel($inputCount, $outputCount, $batchCapacity)) -> bool {
	if model == nil || inputCount <= 0 || outputCount <= 0 || batchCapacity <= 0 { return false }
	model^ = {}
	model.inputShape = {batchCapacity, inputCount}
	model.weightShape = {inputCount, outputCount}
	model.biasShape = {outputCount}
	model.outputShape = {batchCapacity, outputCount}
	model.input = {value = core.Tensor{model.inputShape[:], model.inputData[:]}, grad = core.Tensor{model.inputShape[:], model.inputGrad[:]}}
	model.weights = {value = core.Tensor{model.weightShape[:], model.weightData[:]}, grad = core.Tensor{model.weightShape[:], model.weightGrad[:]}}
	model.bias = {value = core.Tensor{model.biasShape[:], model.biasData[:]}, grad = core.Tensor{model.biasShape[:], model.biasGrad[:]}}
	model.output = {value = core.Tensor{model.outputShape[:], model.outputData[:]}, grad = core.Tensor{model.outputShape[:], model.outputGrad[:]}}
	model.dense = {&model.input, &model.weights, &model.bias, &model.output}
	model.layers = {&model.dense}
	model.parameters = {&model.weights, &model.bias}
	model.nodes = {&model.input, &model.weights, &model.bias, &model.output}
	model.self = rawptr(model)
	return true
}

// LinearPredict accepts row-major inputs for 1..batchCapacity rows. The returned
// slice is borrowed and is overwritten by the next prediction or training call.
LinearPredict :: proc(model: ^LinearModel($inputCount, $outputCount, $batchCapacity), inputs: []f32) -> ([]f32, bool) {
	if model == nil || model.self != rawptr(model) || inputCount <= 0 || outputCount <= 0 || batchCapacity <= 0 ||
		len(inputs) == 0 || len(inputs) % inputCount != 0 || len(inputs) / inputCount > batchCapacity {
		return nil, false
	}
	rows := len(inputs) / inputCount
	model.inputShape[0] = rows
	model.outputShape[0] = rows
	model.input.value.data = model.inputData[:len(inputs)]
	model.input.grad.data = model.inputGrad[:len(inputs)]
	model.output.value.data = model.outputData[:rows * outputCount]
	model.output.grad.data = model.outputGrad[:rows * outputCount]
	copy(model.input.value.data, inputs)
	if !ModelForward(Model{model.layers[:]}) { return nil, false }
	return model.output.value.data, true
}

// LinearFit performs full-batch MSE/SGD updates on row-major data. It
// returns the MSE after the final update. inputCount and targets must not alias the
// model's internal buffers. No shuffling, minibatching or allocation is done.
LinearFit :: proc(model: ^LinearModel($inputCount, $outputCount, $batchCapacity), inputs, targets: []f32, epochs: int = 200, learningRate: f32 = 0.1) -> (f32, bool) {
	if model == nil || model.self != rawptr(model) || inputCount <= 0 || outputCount <= 0 || batchCapacity <= 0 ||
		len(inputs) == 0 || len(inputs) % inputCount != 0 || len(inputs) / inputCount > batchCapacity ||
		len(targets) != (len(inputs) / inputCount) * outputCount || epochs < 0 ||
		learningRate <= 0 || math.is_nan(learningRate) || math.is_inf(learningRate) {
		return 0, false
	}
	for _ in 0..<epochs {
		_, ok := LinearPredict(model, inputs)
		if !ok { return 0, false }
		target := core.Tensor{model.outputShape[:], targets}
		if !ClearGradients(model.nodes[:]) || !MeanSquaredErrorBackward(&model.output, target) ||
			!ModelBackward(Model{model.layers[:]}) || !SGDStep(SGD{model.parameters[:], learningRate}) {
			return 0, false
		}
	}
	_, ok := LinearPredict(model, inputs)
	if !ok { return 0, false }
	return MeanSquaredError(model.output.value, core.Tensor{model.outputShape[:], targets})
}
