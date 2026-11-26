package nn

import "../core"

// Feature nodes must use the inline storage wired by Sequential constructors.
SequentialAdamOwnedNodeValid :: proc(node: ^core.Node, shape: []int, values, gradients: []f32) -> bool {
	if len(node.value.shape) != len(shape) || len(node.grad.shape) != len(shape) ||
		raw_data(node.value.shape) != raw_data(shape) || raw_data(node.grad.shape) != raw_data(shape) ||
		raw_data(node.value.data) != raw_data(values) || raw_data(node.grad.data) != raw_data(gradients) ||
		len(node.value.data) > len(values) || len(node.grad.data) > len(gradients) { return false }
	for dimension in shape { if dimension <= 0 { return false } }
	return core.TensorValid(node.value) && core.TensorValid(node.grad) && core.SameShape(node.value, node.grad)
}

// Parameter data may be rebound outside the model, but shapes remain inline.
SequentialAdamParameterNodeValid :: proc(node: ^core.Node, shape: []int, values, gradients: []f32, modelRange: SequentialAdamMemoryRange) -> bool {
	if len(node.value.shape) != len(shape) || len(node.grad.shape) != len(shape) ||
		raw_data(node.value.shape) != raw_data(shape) || raw_data(node.grad.shape) != raw_data(shape) ||
		len(node.value.data) > len(values) || len(node.grad.data) > len(gradients) { return false }
	for dimension in shape { if dimension <= 0 { return false } }
	if !core.TensorValid(node.value) || !core.TensorValid(node.grad) || !core.SameShape(node.value, node.grad) { return false }
	valueRange, valid := SequentialAdamRange(rawptr(raw_data(node.value.data)), len(node.value.data), size_of(f32))
	if !valid { return false }
	gradRange, gradValid := SequentialAdamRange(rawptr(raw_data(node.grad.data)), len(node.grad.data), size_of(f32))
	if !gradValid || SequentialAdamRangesOverlap(valueRange, gradRange) { return false }
	if raw_data(node.value.data) != raw_data(values) && SequentialAdamRangesOverlap(valueRange, modelRange) { return false }
	if raw_data(node.grad.data) != raw_data(gradients) && SequentialAdamRangesOverlap(gradRange, modelRange) { return false }
	return true
}

SequentialAdamFeatureNodeValid :: proc(node: ^core.Node, shape: []int, values, gradients: []f32, width, batchCapacity: int) -> bool {
	rank := len(node.value.shape)
	if (rank != 2 && rank != 4) || rank > len(shape) || width <= 0 ||
		!SequentialAdamOwnedNodeValid(node, shape[:rank], values, gradients) { return false }
	return shape[0] <= batchCapacity && len(node.value.data) / shape[0] == width
}

// Returns the number of node pointers and the number of f32 elements required
// in EACH moment buffer. Failure returns (0, 0, false) without changing anything.
// A nonempty model with no trainable layers has requirements (0, 0, true).
// Checks ownership, parameter wiring and buffer disjointness, not every model
// forward/backward invariant. Parameter value/gradient data may be rebound outside
// the model; nodes, shapes, feature buffers and dropout masks must remain inline.
// All pointers and backing storage must be valid and not concurrently mutated.
SequentialAdamRequirements :: proc(model: ^Sequential($maxLayers, $maxWidth, $batchCapacity)) -> (parameterCount, elementCount: int, ok: bool) {
	if model == nil || model.self != rawptr(model) || maxLayers <= 0 || maxWidth <= 0 || batchCapacity <= 0 ||
		model.layerCount <= 0 || model.layerCount > maxLayers || model.inputWidth <= 0 || model.inputWidth > maxWidth ||
		!SequentialAdamFeatureNodeValid(&model.input, model.inputShape[:], model.inputData[:], model.inputGrad[:], model.inputWidth, batchCapacity) { return 0, 0, false }
	modelRange, rangeValid := SequentialAdamRange(rawptr(model), 1, size_of(model^))
	if !rangeValid { return 0, 0, false }
	parameters: [2 * maxLayers]^core.Node
	count, elements, inputWidth := 0, 0, model.inputWidth
	input := &model.input
	for &item in model.layers[:model.layerCount] {
		if item.width <= 0 || item.width > maxWidth ||
			!SequentialAdamFeatureNodeValid(&item.output, item.outputShape[:], item.outputData[:], item.outputGrad[:], item.width, batchCapacity) { return 0, 0, false }
		weights, bias: ^core.Node
		switch &operation in item.operation {
		case Dense:
			layer, valid := item.layer.(^Dense)
			if !valid || layer != &operation || operation.input != input || operation.output != &item.output || len(input.value.shape) != 2 { return 0, 0, false }
			switch &storage in item.storage {
			case DenseStorage(maxWidth):
				if operation.weights != &storage.weights || operation.bias != &storage.bias ||
					storage.weightShape != ([2]int{inputWidth, item.width}) || storage.biasShape != ([1]int{item.width}) ||
					!SequentialAdamParameterNodeValid(&storage.weights, storage.weightShape[:], storage.weightData[:], storage.weightGrad[:], modelRange) ||
					!SequentialAdamParameterNodeValid(&storage.bias, storage.biasShape[:], storage.biasData[:], storage.biasGrad[:], modelRange) { return 0, 0, false }
				weights, bias = &storage.weights, &storage.bias
			case nil, Conv2DStorage(maxWidth), DropoutStorage(maxWidth, batchCapacity): return 0, 0, false
			}
		case Conv2D:
			layer, valid := item.layer.(^Conv2D)
			if !valid || layer != &operation || operation.input != input || operation.output != &item.output ||
				len(input.value.shape) != 4 || len(item.output.value.shape) != 4 { return 0, 0, false }
			switch &storage in item.storage {
			case Conv2DStorage(maxWidth):
				if operation.weights != &storage.weights || operation.bias != &storage.bias ||
					storage.weightShape[2] != input.value.shape[3] || storage.weightShape[3] != item.output.value.shape[3] ||
					storage.biasShape[0] != storage.weightShape[3] ||
					!SequentialAdamParameterNodeValid(&storage.weights, storage.weightShape[:], storage.weightData[:], storage.weightGrad[:], modelRange) ||
					!SequentialAdamParameterNodeValid(&storage.bias, storage.biasShape[:], storage.biasData[:], storage.biasGrad[:], modelRange) { return 0, 0, false }
				weights, bias = &storage.weights, &storage.bias
			case nil, DenseStorage(maxWidth), DropoutStorage(maxWidth, batchCapacity): return 0, 0, false
			}
		case Pool2D:
			layer, valid := item.layer.(^Pool2D)
			if !valid || layer != &operation || operation.input != input || operation.output != &item.output { return 0, 0, false }
		case Flatten:
			layer, valid := item.layer.(^Flatten)
			if !valid || layer != &operation || operation.input != input || operation.output != &item.output { return 0, 0, false }
		case Relu:
			layer, valid := item.layer.(^Relu)
			if !valid || layer != &operation || operation.input != input || operation.output != &item.output { return 0, 0, false }
		case Sigmoid:
			layer, valid := item.layer.(^Sigmoid)
			if !valid || layer != &operation || operation.input != input || operation.output != &item.output { return 0, 0, false }
		case Tanh:
			layer, valid := item.layer.(^Tanh)
			if !valid || layer != &operation || operation.input != input || operation.output != &item.output { return 0, 0, false }
		case Softmax:
			layer, valid := item.layer.(^Softmax)
			if !valid || layer != &operation || operation.input != input || operation.output != &item.output { return 0, 0, false }
		case Dropout:
			layer, valid := item.layer.(^Dropout)
			if !valid || layer != &operation || operation.input != input || operation.output != &item.output || operation.randomState != &model.randomState { return 0, 0, false }
			switch &storage in item.storage {
			case DropoutStorage(maxWidth, batchCapacity):
				if raw_data(operation.mask) != raw_data(storage.maskData[:]) || len(operation.mask) != len(item.output.value.data) || len(operation.mask) > len(storage.maskData) { return 0, 0, false }
			case nil, DenseStorage(maxWidth), Conv2DStorage(maxWidth): return 0, 0, false
			}
		case nil: return 0, 0, false
		}
		if weights != nil {
			if count > max(int)-2 { return 0, 0, false }
			for parameter in ([2]^core.Node{weights, bias}) {
				for previous in parameters[:count] {
					if core.BuffersOverlap(parameter.value, previous.value) || core.BuffersOverlap(parameter.value, previous.grad) ||
						core.BuffersOverlap(parameter.grad, previous.value) || core.BuffersOverlap(parameter.grad, previous.grad) { return 0, 0, false }
				}
				if len(parameter.value.data) > max(int)-elements { return 0, 0, false }
				parameters[count] = parameter
				count += 1
				elements += len(parameter.value.data)
			}
		}
		input, inputWidth = &item.output, item.width
	}
	return count, elements, true
}

SequentialAdamMemoryRange :: struct { address, bytes: uintptr }

SequentialAdamRange :: proc(data: rawptr, count, elementSize: int) -> (SequentialAdamMemoryRange, bool) {
	if count < 0 || elementSize <= 0 || uintptr(count) > max(uintptr)/uintptr(elementSize) { return {}, false }
	bytes, address := uintptr(count)*uintptr(elementSize), uintptr(data)
	if bytes != 0 && (address == 0 || bytes-1 > max(uintptr)-address) { return {}, false }
	return {address, bytes}, true
}

SequentialAdamRangesOverlap :: proc(a, b: SequentialAdamMemoryRange) -> bool {
	if a.bytes == 0 || b.bytes == 0 { return false }
	if a.address >= b.address { return a.address-b.address < b.bytes }
	return b.address-a.address < a.bytes
}

// Initializes Adam with dense/conv weights then biases in layer order. Only the
// required prefixes of the supplied buffers are borrowed or modified; unused
// tails are untouched. Used prefixes and optimizer metadata must be disjoint
// from each other, the entire model and any rebound parameter data/gradients.
// Invalid input leaves all destinations unchanged. All pointers and used backing
// storage must be valid; concurrent mutation is forbidden. The model and all
// borrowed buffers must remain alive and unmoved while Adam is in use. Keep the
// optimizer in place while consumers retain its address; do not alter the list.
// Rebind after changing/reinitializing the model. This resets step and moments;
// CheckpointRead with an Adam already restores its binding and state. Values and
// gradients are checked by AdamStep. No heap allocation is performed; scratch
// is proportional to maxLayers on the stack.
SequentialAdamInit :: proc(model: ^Sequential($maxLayers, $maxWidth, $batchCapacity), optimizer: ^Adam, parameterStorage: []^core.Node, firstMoment, secondMoment: []f32, learningRate: f32 = 0.001, beta1: f32 = 0.9, beta2: f32 = 0.999, epsilon: f32 = 1e-8) -> bool {
	if optimizer == nil { return false }
	candidate := Adam{learningRate = learningRate, beta1 = beta1, beta2 = beta2, epsilon = epsilon}
	if !AdamConfigValid(&candidate) { return false }
	count, elements, valid := SequentialAdamRequirements(model)
	if !valid || len(parameterStorage) < count || len(firstMoment) < elements || len(secondMoment) < elements { return false }
	ranges: [5]SequentialAdamMemoryRange
	ranges[0], valid = SequentialAdamRange(rawptr(model), 1, size_of(model^)); if !valid { return false }
	ranges[1], valid = SequentialAdamRange(rawptr(optimizer), 1, size_of(Adam)); if !valid { return false }
	ranges[2], valid = SequentialAdamRange(rawptr(raw_data(parameterStorage)), count, size_of(^core.Node)); if !valid { return false }
	ranges[3], valid = SequentialAdamRange(rawptr(raw_data(firstMoment)), elements, size_of(f32)); if !valid { return false }
	ranges[4], valid = SequentialAdamRange(rawptr(raw_data(secondMoment)), elements, size_of(f32)); if !valid { return false }
	for range, index in ranges {
		for previous in ranges[:index] { if SequentialAdamRangesOverlap(range, previous) { return false } }
	}
	parameters: [2 * maxLayers]^core.Node
	list, listValid := SequentialParameters(model, parameters[:])
	if !listValid || len(list) != count { return false }
	for parameter in list {
		for tensor in ([2]core.Tensor{parameter.value, parameter.grad}) {
			dataRange, dataValid := SequentialAdamRange(rawptr(raw_data(tensor.data)), len(tensor.data), size_of(f32))
			if !dataValid { return false }
			for range in ranges[1:] { if SequentialAdamRangesOverlap(dataRange, range) { return false } }
		}
	}
	// All fallible checks precede writes to any caller-owned destination.
	copy(parameterStorage[:count], list)
	candidate.parameters = parameterStorage[:count]
	candidate.firstMoment, candidate.secondMoment = firstMoment[:elements], secondMoment[:elements]
	for &moment in candidate.firstMoment { moment = 0 }
	for &moment in candidate.secondMoment { moment = 0 }
	optimizer^ = candidate
	return true
}
