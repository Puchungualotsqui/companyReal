package nn

import "../core"

// Dimensions exclude the batch: rank 1 is [features], rank 3 is [height, width, channels].
// Unused dimensions are zero; width is the number of elements per sample.
SequentialSummaryShape :: struct {
	rank: int,
	dimensions: [3]int,
	width: int,
}

SequentialSummaryLayerKind :: enum {
	Dense,
	Conv2D,
	MaxPool2D,
	AveragePool2D,
	Flatten,
	Relu,
	Sigmoid,
	Tanh,
	Softmax,
	Dropout,
}

SequentialLayerSummary :: struct {
	kind: SequentialSummaryLayerKind,
	input, output: SequentialSummaryShape,
	weightCount, biasCount, parameterCount: int,
}

// The layers slice borrows the caller's storage and contains exactly layerCount entries.
SequentialModelSummary :: struct {
	input, output: SequentialSummaryShape,
	batchCapacity, layerCount: int,
	layers: []SequentialLayerSummary,
	totalParameters, trainableParameters, nonTrainableParameters: int,
}

// Summarizes an initialized, unmoved model without allocating or running it.
// Shapes omit the variable batch dimension. Dense and Conv2D weights and biases
// are all trainable; no frozen or non-trainable parameter nodes are supported.
// Empty models are valid. Feature nodes and dropout masks must retain their inline
// wiring; parameter data, gradients and shapes may be rebound. storage must have
// at least model.layerCount entries and be disjoint from the whole model and all
// parameter data, gradients and shape slices; its unused suffix is unchanged. Counts are
// per parameter node and do not deduplicate manually shared buffers. This checks
// architecture metadata, not numerical values or full forward/backward validity.
// On failure, returns ({}, false) and leaves model and storage unchanged. All slices
// must have valid backing storage; avoid concurrent mutation during both passes.
SequentialSummary :: proc(
	model: ^Sequential($maxLayers, $maxWidth, $batchCapacity),
	storage: []SequentialLayerSummary,
) -> (SequentialModelSummary, bool) {
	if model == nil || model.self != rawptr(model) || maxLayers <= 0 || maxWidth <= 0 || batchCapacity <= 0 ||
		model.layerCount < 0 || model.layerCount > maxLayers || len(storage) < model.layerCount ||
		model.inputWidth <= 0 || model.inputWidth > maxWidth { return {}, false }
	if len(storage) > 0 {
		if raw_data(storage) == nil { return {}, false }
		address, modelAddress := uintptr(raw_data(storage)), uintptr(rawptr(model))
		if address >= modelAddress {
			if address-modelAddress < uintptr(size_of(model^)) { return {}, false }
		} else if (modelAddress-address)/size_of(SequentialLayerSummary) < uintptr(len(storage)) {
			return {}, false
		}
	}
	input, valid := SequentialSummaryNodeShape(&model.input, &model.inputShape, model.inputData[:], model.inputGrad[:], model.inputWidth, batchCapacity)
	if !valid { return {}, false }
	result := SequentialModelSummary{
		input = input, output = input, batchCapacity = batchCapacity,
		layerCount = model.layerCount, layers = storage[:model.layerCount],
	}
	// The first pass validates every layer and the total before the second writes.
	for pass in 0..<2 {
		shape := input
		total := 0
		for i in 0..<model.layerCount {
			layer, ok := SequentialSummaryLayer(model, i, shape, storage)
			if !ok || total > max(int)-layer.parameterCount { return {}, false }
			total += layer.parameterCount
			shape = layer.output
			if pass == 1 { storage[i] = layer }
		}
		result.output = shape
		result.totalParameters = total
		result.trainableParameters = total
	}
	return result, true
}

// Checks owned tensor metadata but not the contents of values or gradients.
@(private="file")
SequentialSummaryNodeShape :: proc(node: ^core.Node, shape: ^[4]int, data, grad: []f32, width, batchCapacity: int) -> (SequentialSummaryShape, bool) {
	result: SequentialSummaryShape
	rank := len(node.value.shape)
	if (rank != 2 && rank != 4) || len(node.grad.shape) != rank ||
		raw_data(node.value.shape) != &shape[0] || raw_data(node.grad.shape) != &shape[0] ||
		width <= 0 || shape[0] <= 0 || shape[0] > batchCapacity ||
		width > len(data)/shape[0] || width > len(grad)/shape[0] { return {}, false }
	count := shape[0]*width
	if len(node.value.data) != count || len(node.grad.data) != count ||
		raw_data(node.value.data) != raw_data(data) || raw_data(node.grad.data) != raw_data(grad) { return {}, false }
	result.width = width
	if rank == 2 {
		if shape[1] != width || shape[2] != 0 || shape[3] != 0 { return {}, false }
		result.rank = 1
		result.dimensions = {width, 0, 0}
	} else {
		h, w, c := shape[1], shape[2], shape[3]
		if h <= 0 || w <= 0 || c <= 0 || h > width/w || h*w > width/c || h*w*c != width { return {}, false }
		result.rank = 3
		result.dimensions = {h, w, c}
	}
	return result, true
}

@(private="file")
SequentialSummaryOverlaps :: proc(storage: []SequentialLayerSummary, address: rawptr, count, elementSize: int) -> bool {
	if len(storage) == 0 || count == 0 { return false }
	a, b := uintptr(raw_data(storage)), uintptr(address)
	if a >= b { return (a-b)/uintptr(elementSize) < uintptr(count) }
	return (b-a)/size_of(SequentialLayerSummary) < uintptr(len(storage))
}

@(private="file")
SequentialSummaryParameterValid :: proc(node: ^core.Node, shape: []int, count: int, storage: []SequentialLayerSummary) -> bool {
	if count <= 0 || len(node.value.shape) != len(shape) || len(node.grad.shape) != len(shape) ||
		len(node.value.data) != count || len(node.grad.data) != count ||
		raw_data(node.value.shape) == nil || raw_data(node.grad.shape) == nil ||
		raw_data(node.value.data) == nil || raw_data(node.grad.data) == nil { return false }
	for tensor in ([2]core.Tensor{node.value, node.grad}) {
		if SequentialSummaryOverlaps(storage, rawptr(raw_data(tensor.shape)), len(tensor.shape), size_of(int)) ||
			SequentialSummaryOverlaps(storage, rawptr(raw_data(tensor.data)), len(tensor.data), size_of(f32)) { return false }
		for dimension, i in shape { if tensor.shape[i] != dimension { return false } }
	}
	return true
}

// inputShape was validated by the previous iteration; index is in bounds.
@(private="file")
SequentialSummaryLayer :: proc(
	model: ^Sequential($maxLayers, $maxWidth, $batchCapacity), index: int, inputShape: SequentialSummaryShape, summaries: []SequentialLayerSummary,
) -> (SequentialLayerSummary, bool) {
	item := &model.layers[index]
	input := &model.input
	if index > 0 { input = &model.layers[index-1].output }
	if item.width <= 0 || item.width > maxWidth { return {}, false }
	result := SequentialLayerSummary{input = inputShape, output = inputShape}
	switch &operation in item.operation {
	case Dense:
		layer, ok := item.layer.(^Dense)
		if !ok || layer != &operation || operation.input != input || operation.output != &item.output || inputShape.rank != 1 { return {}, false }
		storage: ^DenseStorage(maxWidth)
		switch &value in item.storage {
		case DenseStorage(maxWidth): storage = &value
		case nil, Conv2DStorage(maxWidth), DropoutStorage(maxWidth, batchCapacity): return {}, false
		}
		if inputShape.width > max(int)/item.width { return {}, false }
		weights := inputShape.width*item.width
		if weights > max(int)-item.width || storage.weightShape != ([2]int{inputShape.width, item.width}) ||
			storage.biasShape != ([1]int{item.width}) || operation.weights != &storage.weights || operation.bias != &storage.bias ||
			!SequentialSummaryParameterValid(&storage.weights, storage.weightShape[:], weights, summaries) ||
			!SequentialSummaryParameterValid(&storage.bias, storage.biasShape[:], item.width, summaries) { return {}, false }
		result.kind = .Dense
		result.output = {1, {item.width, 0, 0}, item.width}
		result.weightCount, result.biasCount = weights, item.width
	case Conv2D:
		layer, ok := item.layer.(^Conv2D)
		if !ok || layer != &operation || operation.input != input || operation.output != &item.output || inputShape.rank != 3 { return {}, false }
		storage: ^Conv2DStorage(maxWidth)
		switch &value in item.storage {
		case Conv2DStorage(maxWidth): storage = &value
		case nil, DenseStorage(maxWidth), DropoutStorage(maxWidth, batchCapacity): return {}, false
		}
		kh, kw, ic, oc := storage.weightShape[0], storage.weightShape[1], storage.weightShape[2], storage.weightShape[3]
		if kh <= 0 || kw <= 0 || ic != inputShape.dimensions[2] || oc <= 0 || oc > maxWidth { return {}, false }
		capacity := len(storage.weightData)
		if kh > capacity/kw || kh*kw > capacity/ic || kh*kw*ic > capacity/oc { return {}, false }
		weights := kh*kw*ic*oc
		if weights > max(int)-oc || storage.biasShape != ([1]int{oc}) || operation.weights != &storage.weights || operation.bias != &storage.bias ||
			!SequentialSummaryParameterValid(&storage.weights, storage.weightShape[:], weights, summaries) ||
			!SequentialSummaryParameterValid(&storage.bias, storage.biasShape[:], oc, summaries) { return {}, false }
		h, hOk := Conv2DDimension(inputShape.dimensions[0], kh, operation.stride, operation.padding)
		w, wOk := Conv2DDimension(inputShape.dimensions[1], kw, operation.stride, operation.padding)
		if !hOk || !wOk || h <= 0 || w <= 0 || h > maxWidth/w || h*w > maxWidth/oc || h*w*oc != item.width ||
			h-1 > (max(int)-(kh-1))/operation.stride || w-1 > (max(int)-(kw-1))/operation.stride { return {}, false }
		result.kind = .Conv2D
		result.output = {3, {h, w, oc}, item.width}
		result.weightCount, result.biasCount = weights, oc
	case Pool2D:
		layer, ok := item.layer.(^Pool2D)
		if !ok || layer != &operation || operation.input != input || operation.output != &item.output || inputShape.rank != 3 { return {}, false }
		kh, kw, stride := operation.kernelHeight, operation.kernelWidth, operation.stride
		h, w, c := inputShape.dimensions[0], inputShape.dimensions[1], inputShape.dimensions[2]
		if (operation.kind != .Max && operation.kind != .Average) || kh <= 0 || kw <= 0 || stride <= 0 || kh > h || kw > w || kh > max(int)/kw { return {}, false }
		h, w = (h-kh)/stride+1, (w-kw)/stride+1
		if h > maxWidth/w || h*w > maxWidth/c || h*w*c != item.width { return {}, false }
		result.kind = .MaxPool2D
		if operation.kind == .Average { result.kind = .AveragePool2D }
		result.output = {3, {h, w, c}, item.width}
	case Flatten:
		layer, ok := item.layer.(^Flatten)
		if !ok || layer != &operation || operation.input != input || operation.output != &item.output || item.width != inputShape.width { return {}, false }
		result.kind = .Flatten
		result.output = {1, {item.width, 0, 0}, item.width}
	case Relu:
		layer, ok := item.layer.(^Relu)
		if !ok || layer != &operation || operation.input != input || operation.output != &item.output || item.width != inputShape.width { return {}, false }
		result.kind = .Relu
	case Sigmoid:
		layer, ok := item.layer.(^Sigmoid)
		if !ok || layer != &operation || operation.input != input || operation.output != &item.output || item.width != inputShape.width { return {}, false }
		result.kind = .Sigmoid
	case Tanh:
		layer, ok := item.layer.(^Tanh)
		if !ok || layer != &operation || operation.input != input || operation.output != &item.output || item.width != inputShape.width { return {}, false }
		result.kind = .Tanh
	case Softmax:
		layer, ok := item.layer.(^Softmax)
		if !ok || layer != &operation || operation.input != input || operation.output != &item.output || item.width != inputShape.width { return {}, false }
		result.kind = .Softmax
	case Dropout:
		layer, ok := item.layer.(^Dropout)
		if !ok || layer != &operation || operation.input != input || operation.output != &item.output || item.width != inputShape.width ||
			!(operation.rate >= 0 && operation.rate < 1) || operation.randomState != &model.randomState { return {}, false }
		storage: ^DropoutStorage(maxWidth, batchCapacity)
		switch &value in item.storage {
		case DropoutStorage(maxWidth, batchCapacity): storage = &value
		case nil, DenseStorage(maxWidth), Conv2DStorage(maxWidth): return {}, false
		}
		if raw_data(operation.mask) != raw_data(storage.maskData[:]) || len(operation.mask) != len(item.output.value.data) { return {}, false }
		result.kind = .Dropout
	case nil:
		return {}, false
	}
	result.parameterCount = result.weightCount + result.biasCount
	output, valid := SequentialSummaryNodeShape(&item.output, &item.outputShape, item.outputData[:], item.outputGrad[:], item.width, batchCapacity)
	if !valid || output != result.output { return {}, false }
	return result, true
}
