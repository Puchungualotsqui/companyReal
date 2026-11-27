package nn

import "../core"

SequentialConv2DConfig :: struct {
	kernelHeight, kernelWidth: int,
	stride, padding: int, // Equal stride and padding on both spatial axes.
}

SequentialPool2DConfig :: struct {
	kernelHeight, kernelWidth: int,
	stride, padding: int, // Pooling currently always uses zero padding.
}

SequentialDropoutConfig :: struct {
	rate: f32,
}

// nil means no extra configuration is reported, not that an unknown value is zero.
// Dense, activation and flatten currently have no additional retained config.
// Initializer/seed, loss and optimizer settings cannot be recovered from the model.
// Unsupported layer kinds fail SequentialSummary validation rather than producing
// an unknown kind; layer kind distinguishes the parameterless layers.
SequentialLayerConfig :: union { SequentialConv2DConfig, SequentialPool2DConfig, SequentialDropoutConfig }

SequentialLayerDetails :: struct {
	summary: SequentialLayerSummary,
	config: SequentialLayerConfig,
}

SequentialModelDetails :: struct {
	input, output: SequentialSummaryShape,
	batchCapacity, layerCount: int,
	layers: []SequentialLayerDetails, // Borrows the caller's storage prefix.
	totalParameters, trainableParameters, nonTrainableParameters: int,
	modelStorageBytes: int, // Entire inline model, including unused capacity and padding.
	parameterNodeCount: int, // Dense/conv weights and bias pointers, in layer order.
	adamMomentElements: int, // f32 elements needed in EACH Adam moment buffer.
}

// Returns a snapshot of SequentialSummary metadata and the configurations retained
// by the model. Shapes exclude batch; pooling uses valid windows. No inference,
// training, activation/mask/RNG mutation, or heap allocation occurs. Scratch space
// is proportional to maxLayers on the stack. The layer records contain values, not
// references to the model; result.layers borrows storage[:layerCount] and remains
// valid until that storage is changed or freed. Unused storage entries are untouched.
//
// storage must have at least layerCount entries and its ENTIRE slice must be disjoint
// from the model and all parameter value/gradient data and shape slices, including
// rebound buffers. All pointers/slice backing storage must be valid; do not mutate
// the model or buffers concurrently. On failure returns ({}, false) and changes
// neither model nor storage. Validation has the same scope as SequentialSummary:
// it checks architecture, not parameter values or full forward/backward validity.
//
// modelStorageBytes is size_of(Sequential(...)), not external rebound data, Adam,
// workspace or this call's scratch. Parameter and moment counts are structural,
// per node, without deduplication. They describe the buffers for Adam on compatible
// models, but do not establish compatibility: SequentialAdamRequirements has
// stricter wiring/disjointness checks and rejects empty models. Use it before Adam
// initialization. All current parameters are trainable.
SequentialDetails :: proc(
	model: ^Sequential($maxLayers, $maxWidth, $batchCapacity),
	storage: []SequentialLayerDetails,
) -> (SequentialModelDetails, bool) {
	if model == nil || len(storage) < model.layerCount { return {}, false }
	destination, valid := SequentialAdamRange(rawptr(raw_data(storage)), len(storage), size_of(SequentialLayerDetails))
	if !valid { return {}, false }
	modelRange, modelValid := SequentialAdamRange(rawptr(model), 1, size_of(model^))
	if !modelValid || SequentialAdamRangesOverlap(destination, modelRange) { return {}, false }

	summaries: [maxLayers]SequentialLayerSummary
	summary, summaryValid := SequentialSummary(model, summaries[:])
	if !summaryValid { return {}, false }

	parameterNodeCount := 0
	for &item in model.layers[:model.layerCount] {
		weights, bias: ^core.Node
		switch &operation in item.operation {
		case Dense: weights, bias = operation.weights, operation.bias
		case Conv2D: weights, bias = operation.weights, operation.bias
		case nil, Pool2D, Flatten, Relu, Sigmoid, Tanh, Softmax, Dropout:
		}
		if weights != nil {
			if parameterNodeCount > max(int)-2 { return {}, false }
			parameterNodeCount += 2
			for parameter in ([2]^core.Node{weights, bias}) {
				for tensor in ([2]core.Tensor{parameter.value, parameter.grad}) {
					shapeRange, shapeValid := SequentialAdamRange(rawptr(raw_data(tensor.shape)), len(tensor.shape), size_of(int))
					dataRange, dataValid := SequentialAdamRange(rawptr(raw_data(tensor.data)), len(tensor.data), size_of(f32))
					if !shapeValid || !dataValid || SequentialAdamRangesOverlap(destination, shapeRange) ||
						SequentialAdamRangesOverlap(destination, dataRange) { return {}, false }
				}
			}
		}
	}

	// All fallible checks precede the first write to caller storage.
	for &item, i in model.layers[:model.layerCount] {
		entry := SequentialLayerDetails{summary = summaries[i]}
		switch &operation in item.operation {
		case Conv2D:
			shape := operation.weights.value.shape
			entry.config = SequentialConv2DConfig{shape[0], shape[1], operation.stride, operation.padding}
		case Pool2D:
			entry.config = SequentialPool2DConfig{operation.kernelHeight, operation.kernelWidth, operation.stride, 0}
		case Dropout:
			entry.config = SequentialDropoutConfig{operation.rate}
		case nil, Dense, Flatten, Relu, Sigmoid, Tanh, Softmax:
		}
		storage[i] = entry
	}
	return SequentialModelDetails{
		input = summary.input, output = summary.output,
		batchCapacity = summary.batchCapacity, layerCount = summary.layerCount,
		layers = storage[:summary.layerCount], totalParameters = summary.totalParameters,
		trainableParameters = summary.trainableParameters, nonTrainableParameters = summary.nonTrainableParameters,
		modelStorageBytes = size_of(model^), parameterNodeCount = parameterNodeCount,
		adamMomentElements = summary.totalParameters,
	}, true
}
