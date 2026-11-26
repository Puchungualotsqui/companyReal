package nn

import "../core"
import "core:mem"
import "core:testing"

SummaryVector :: proc(width: int) -> SequentialSummaryShape {
	return {1, {width, 0, 0}, width}
}

SummarySpatial :: proc(h, w, c: int) -> SequentialSummaryShape {
	return {3, {h, w, c}, h*w*c}
}

@(test)
SequentialSummaryDenseAndBatchIndependence :: proc(t: ^testing.T) {
	model: Sequential(8, 5, 4)
	built := SequentialInit(&model, 3, 42) && SequentialAddDense(&model, 4) &&
		SequentialAddActivation(&model, .Relu) && SequentialAddDense(&model, 2) &&
		SequentialAddActivation(&model, .Sigmoid) && SequentialAddActivation(&model, .Tanh) &&
		SequentialAddActivation(&model, .Softmax) && SequentialAddDropout(&model, 0.25)
	testing.expect(t, built)
	if !built { return }
	one := [3]f32{1, 2, 3}
	_, predicted := SequentialPredict(&model, one[:])
	testing.expect(t, predicted && SequentialAddFlatten(&model))
	if !predicted || model.layerCount != 8 { return }
	// Adding after prediction leaves different current batch sizes in the layers.
	testing.expect(t, model.layers[6].outputShape[0] == 1 && model.layers[7].outputShape[0] == 4)
	sentinel := SequentialLayerSummary{kind = .Dropout, parameterCount = 99}
	storage: [10]SequentialLayerSummary
	for &entry in storage { entry = sentinel }
	state, weights := model.randomState, TestDenseStorage(&model.layers[0]).weightData
	inputShape, lastShape := model.inputShape, model.layers[7].outputShape
	mask := TestDropoutStorage(&model.layers[6]).maskData
	result: SequentialModelSummary
	ok: bool
	{
		context.allocator = mem.panic_allocator()
		context.temp_allocator = mem.panic_allocator()
		result, ok = SequentialSummary(&model, storage[:])
	}
	testing.expect(t, ok)
	if !ok { return }
	testing.expect(t, result.input == SummaryVector(3) && result.output == SummaryVector(2))
	testing.expect(t, result.batchCapacity == 4 && result.layerCount == 8 && len(result.layers) == 8 && raw_data(result.layers) == &storage[0])
	testing.expect(t, result.totalParameters == 26 && result.trainableParameters == 26 && result.nonTrainableParameters == 0)
	kinds := [8]SequentialSummaryLayerKind{.Dense, .Relu, .Dense, .Sigmoid, .Tanh, .Softmax, .Dropout, .Flatten}
	inWidths := [8]int{3, 4, 4, 2, 2, 2, 2, 2}
	outWidths := [8]int{4, 4, 2, 2, 2, 2, 2, 2}
	weightsPerLayer := [8]int{12, 0, 8, 0, 0, 0, 0, 0}
	biasesPerLayer := [8]int{4, 0, 2, 0, 0, 0, 0, 0}
	for layer, i in result.layers {
		testing.expect(t, layer.kind == kinds[i] && layer.input == SummaryVector(inWidths[i]) && layer.output == SummaryVector(outWidths[i]))
		testing.expect(t, layer.weightCount == weightsPerLayer[i] && layer.biasCount == biasesPerLayer[i] && layer.parameterCount == weightsPerLayer[i]+biasesPerLayer[i])
	}
	testing.expect(t, storage[8] == sentinel && storage[9] == sentinel)
	testing.expect(t, model.randomState == state && TestDenseStorage(&model.layers[0]).weightData == weights &&
		model.inputShape == inputShape && model.layers[7].outputShape == lastShape && TestDropoutStorage(&model.layers[6]).maskData == mask)
	parameters: [4]^core.Node
	nodes, paramsOk := SequentialParameters(&model, parameters[:])
	count := 0
	if paramsOk { for node in nodes { count += len(node.value.data) } }
	testing.expect(t, paramsOk && count == result.totalParameters)
	before := storage
	three := [9]f32{1, 2, 3, 0, 0, 0, -1, -2, -3}
	_, predicted = SequentialPredict(&model, three[:], true)
	testing.expect(t, predicted)
	after: [8]SequentialLayerSummary
	later, laterOk := SequentialSummary(&model, after[:])
	testing.expect(t, laterOk && later.input == result.input && later.output == result.output && later.totalParameters == result.totalParameters)
	for layer, i in after { testing.expect(t, layer == before[i]) }
}

@(test)
SequentialSummarySpatial :: proc(t: ^testing.T) {
	model: Sequential(8, 40, 4)
	built := SequentialInitSpatial(&model, 4, 5, 2, 9) && SequentialAddConv2D(&model, 3, 2, 3, 2, 1) &&
		SequentialAddActivation(&model, .Softmax) && SequentialAddDropout(&model, 0.2) &&
		SequentialAddPool2D(&model, .Max, 2, 2, 1) && SequentialAddPool2D(&model, .Average, 1, 2, 2) &&
		SequentialAddFlatten(&model) && SequentialAddDense(&model, 4) && SequentialAddActivation(&model, .Sigmoid)
	testing.expect(t, built)
	if !built { return }
	storage: [8]SequentialLayerSummary
	result, ok := SequentialSummary(&model, storage[:])
	testing.expect(t, ok)
	if !ok { return }
	testing.expect(t, result.input == SummarySpatial(4, 5, 2) && result.output == SummaryVector(4))
	testing.expect(t, result.totalParameters == 55 && result.trainableParameters == 55 && result.nonTrainableParameters == 0)
	shapes := [9]SequentialSummaryShape{
		SummarySpatial(4, 5, 2), SummarySpatial(2, 3, 3), SummarySpatial(2, 3, 3), SummarySpatial(2, 3, 3),
		SummarySpatial(1, 2, 3), SummarySpatial(1, 1, 3), SummaryVector(3), SummaryVector(4), SummaryVector(4),
	}
	kinds := [8]SequentialSummaryLayerKind{.Conv2D, .Softmax, .Dropout, .MaxPool2D, .AveragePool2D, .Flatten, .Dense, .Sigmoid}
	for layer, i in result.layers {
		testing.expect(t, layer.kind == kinds[i] && layer.input == shapes[i] && layer.output == shapes[i+1])
		if i != 0 && i != 6 { testing.expect(t, layer.parameterCount == 0 && layer.weightCount == 0 && layer.biasCount == 0) }
	}
	testing.expect(t, storage[0].weightCount == 36 && storage[0].biasCount == 3 && storage[0].parameterCount == 39)
	testing.expect(t, storage[6].weightCount == 12 && storage[6].biasCount == 4 && storage[6].parameterCount == 16)
	parameters: [4]^core.Node
	nodes, paramsOk := SequentialParameters(&model, parameters[:])
	count := 0
	if paramsOk { for node in nodes { count += len(node.value.data) } }
	testing.expect(t, paramsOk && count == result.totalParameters)
	input: [40]f32
	_, predicted := SequentialPredict(&model, input[:])
	second: [8]SequentialLayerSummary
	again, againOk := SequentialSummary(&model, second[:])
	testing.expect(t, predicted && againOk && again.output == result.output && again.totalParameters == result.totalParameters && second == storage)
}

@(test)
SequentialSummaryEmptyAndNonTrainable :: proc(t: ^testing.T) {
	model: Sequential(3, 12, 2)
	_, invalid := SequentialSummary(&model, nil)
	testing.expect(t, !invalid)
	testing.expect(t, SequentialInitSpatial(&model, 2, 3, 2))
	empty, ok := SequentialSummary(&model, nil)
	testing.expect(t, ok && empty.layerCount == 0 && len(empty.layers) == 0 && empty.input == SummarySpatial(2, 3, 2) && empty.output == empty.input && empty.totalParameters == 0)
	testing.expect(t, SequentialAddActivation(&model, .Tanh) && SequentialAddDropout(&model, 0) && SequentialAddFlatten(&model))
	storage: [3]SequentialLayerSummary
	nonTrainable, valid := SequentialSummary(&model, storage[:])
	testing.expect(t, valid && nonTrainable.totalParameters == 0 && nonTrainable.trainableParameters == 0 && nonTrainable.nonTrainableParameters == 0)
	if valid {
		testing.expect(t, storage[0].input == SummarySpatial(2, 3, 2) && storage[0].output == SummarySpatial(2, 3, 2))
		testing.expect(t, storage[1].output == SummarySpatial(2, 3, 2) && storage[2].output == SummaryVector(12))
	}
	missing: ^Sequential(3, 12, 2)
	_, valid = SequentialSummary(missing, storage[:])
	testing.expect(t, !valid)
	copied := model
	_, valid = SequentialSummary(&copied, storage[:])
	testing.expect(t, !valid)
}

@(test)
SequentialSummaryPreflight :: proc(t: ^testing.T) {
	for failure in 0..<26 {
		model: Sequential(5, 32, 2)
		built := SequentialInitSpatial(&model, 4, 4, 1) && SequentialAddConv2D(&model, 2, 2, 2) &&
			SequentialAddPool2D(&model, .Max, 2, 2, 2) && SequentialAddFlatten(&model) &&
			SequentialAddDense(&model, 2) && SequentialAddDropout(&model, 0.3)
		testing.expect(t, built)
		if !built { return }
		conv := &model.layers[0].operation.(Conv2D)
		convStorage := &model.layers[0].storage.(Conv2DStorage(32))
		pool := &model.layers[1].operation.(Pool2D)
		dense := &model.layers[3].storage.(DenseStorage(32))
		denseOperation := &model.layers[3].operation.(Dense)
		dropout := &model.layers[4].operation.(Dropout)
		switch failure {
		case 0: dense.weightShape[0] += 1
		case 1: dense.weights.value.data = dense.weights.value.data[:1]
		case 2: model.layers[4].layer = nil
		case 3: pool.kind = PoolKind(99)
		case 4: pool.kernelWidth = max(int)
		case 5: conv.stride = 0
		case 6: model.layers[0].outputShape[1] = 2
		case 7: dropout.rate = transmute(f32)u32(0x7fc00000)
		case 8: dropout.mask = dropout.mask[:1]
		case 9: model.inputShape[3] = 0
		case 10: model.layers[3].output.value.shape = model.inputShape[:2]
		case 11: model.layers[3].output.grad.data = model.layers[3].outputData[:len(model.layers[3].output.grad.data)]
		case 12: convStorage.weightShape[0] = max(int)
		case 13: model.layerCount = 6
		case 14: model.layers[0].outputShape[0] = 0
		case 15: pool.input = &model.input
		case 16: conv.padding = max(int)
		case 17: model.layers[4].width = 3
		case 18: convStorage.biasShape[0] = 1
		case 19: model.inputShape[1] = max(int)
		case 20: convStorage.weightShape[1] = max(int)
		case 21: model.inputShape[2] = max(int)
		case 22: dense.weights.value.shape = nil
		case 23: denseOperation.weights = &model.input
		case 24: model.layers[4].operation = nil
		case 25: model.layerCount = -1
		}
		sentinel := SequentialLayerSummary{kind = .Dropout, input = SummaryVector(7), parameterCount = 77}
		storage := [5]SequentialLayerSummary{sentinel, sentinel, sentinel, sentinel, sentinel}
		before: [size_of(Sequential(5, 32, 2))]u8
		copy(before[:], (cast([^]u8)rawptr(&model))[:size_of(model)])
		result, valid := SequentialSummary(&model, storage[:])
		after: [size_of(Sequential(5, 32, 2))]u8
		copy(after[:], (cast([^]u8)rawptr(&model))[:size_of(model)])
		testing.expect(t, !valid && result.layerCount == 0 && len(result.layers) == 0)
		testing.expect(t, storage == [5]SequentialLayerSummary{sentinel, sentinel, sentinel, sentinel, sentinel} && before == after)
	}
}

@(test)
SequentialSummaryCapacityAndOverlap :: proc(t: ^testing.T) {
	box: struct { prefix: SequentialLayerSummary, model: Sequential(2, 3, 2) }
	built := SequentialInit(&box.model, 2) && SequentialAddDense(&box.model, 3) && SequentialAddActivation(&box.model, .Relu)
	testing.expect(t, built)
	if !built { return }
	sentinel := SequentialLayerSummary{parameterCount = 97}
	storage := [2]SequentialLayerSummary{sentinel, sentinel}
	state, weights := box.model.randomState, TestDenseStorage(&box.model.layers[0]).weightData
	beforeModel: [size_of(Sequential(2, 3, 2))]u8
	copy(beforeModel[:], (cast([^]u8)rawptr(&box.model))[:size_of(box.model)])
	_, shortOk := SequentialSummary(&box.model, storage[:1])
	_, nilOk := SequentialSummary(&box.model, nil)
	inside := (cast([^]SequentialLayerSummary)rawptr(&box.model))[:2]
	_, insideOk := SequentialSummary(&box.model, inside)
	box.prefix = sentinel
	partial := (cast([^]SequentialLayerSummary)rawptr(&box.prefix))[:2]
	_, partialOk := SequentialSummary(&box.model, partial)
	testing.expect(t, !shortOk && !nilOk && !insideOk && !partialOk && box.prefix == sentinel && storage == [2]SequentialLayerSummary{sentinel, sentinel})
	afterModel: [size_of(Sequential(2, 3, 2))]u8
	copy(afterModel[:], (cast([^]u8)rawptr(&box.model))[:size_of(box.model)])
	testing.expect(t, box.model.randomState == state && TestDenseStorage(&box.model.layers[0]).weightData == weights && beforeModel == afterModel)
	// A larger destination keeps its unused suffix unchanged.
	oneLayer: Sequential(1, 1, 1)
	testing.expect(t, SequentialInit(&oneLayer, 1) && SequentialAddDense(&oneLayer, 1))
	_, success := SequentialSummary(&oneLayer, storage[:])
	testing.expect(t, success && storage[1] == sentinel)
}

@(test)
SequentialSummarySpatialOutput :: proc(t: ^testing.T) {
	model: Sequential(2, 32, 3)
	built := SequentialInitSpatial(&model, 1, 1, 2) && SequentialAddConv2D(&model, 1, 1, 3, 1, 1) &&
		SequentialAddPool2D(&model, .Average, 2, 2, 1)
	testing.expect(t, built)
	if !built { return }
	storage: [2]SequentialLayerSummary
	result, ok := SequentialSummary(&model, storage[:])
	testing.expect(t, ok && result.output == SummarySpatial(2, 2, 3) && result.totalParameters == 9)
	if ok {
		testing.expect(t, storage[0].output == SummarySpatial(3, 3, 3) && storage[0].weightCount == 6 && storage[0].biasCount == 3)
		testing.expect(t, storage[1].kind == .AveragePool2D && storage[1].output == result.output && storage[1].parameterCount == 0)
	}
	input := [2]f32{1, -1}
	output, predicted := SequentialPredict(&model, input[:])
	testing.expect(t, predicted && len(output) == 12)
}

@(test)
SequentialSummaryReboundParameters :: proc(t: ^testing.T) {
	model: Sequential(1, 3, 2)
	built := SequentialInit(&model, 2) && SequentialAddDense(&model, 3)
	testing.expect(t, built)
	if !built { return }
	dense := TestDenseStorage(&model.layers[0])
	weights := [6]f32{1, 2, 3, 4, 5, 6}
	weightGrad := [6]f32{6, 5, 4, 3, 2, 1}
	bias := [3]f32{1, 2, 3}
	biasGrad := [3]f32{3, 2, 1}
	weightShape := [2]int{2, 3}
	biasShape := [1]int{3}
	dense.weights.value.data, dense.weights.grad.data = weights[:], weightGrad[:]
	dense.bias.value.data, dense.bias.grad.data = bias[:], biasGrad[:]
	dense.weights.value.shape, dense.weights.grad.shape = weightShape[:], weightShape[:]
	dense.bias.value.shape, dense.bias.grad.shape = biasShape[:], biasShape[:]
	storage: [2]SequentialLayerSummary
	result, ok := SequentialSummary(&model, storage[:])
	testing.expect(t, ok && result.totalParameters == 9 && storage[0].weightCount == 6 && storage[0].biasCount == 3)
	testing.expect(t, weights == [6]f32{1, 2, 3, 4, 5, 6} && weightGrad == [6]f32{6, 5, 4, 3, 2, 1})
	// Contents are not inspected, so non-finite weights do not hide the architecture.
	weights[0] = transmute(f32)u32(0x7fc00000)
	_, ok = SequentialSummary(&model, storage[:])
	testing.expect(t, ok)
	weights[0] = 1
	for failure in 0..<4 {
		output := [2]SequentialLayerSummary{{parameterCount = 77}, {parameterCount = 88}}
		aliasedShape := output[1].input.dimensions[:2]
		aliasedShape[0], aliasedShape[1] = 2, 3
		aliasedData := mem.slice_ptr(cast(^f32)rawptr(&output[1].input.dimensions[0]), 6)
		switch failure {
		case 0: dense.weights.value.data = aliasedData
		case 1: dense.weights.grad.data = aliasedData
		case 2: dense.weights.value.shape = aliasedShape
		case 3: dense.weights.grad.shape = aliasedShape
		}
		before := output
		valid: bool
		{
			context.allocator = mem.panic_allocator()
			context.temp_allocator = mem.panic_allocator()
			_, valid = SequentialSummary(&model, output[:])
		}
		testing.expect(t, !valid && output == before)
		dense.weights.value.data, dense.weights.grad.data = weights[:], weightGrad[:]
		dense.weights.value.shape, dense.weights.grad.shape = weightShape[:], weightShape[:]
	}
	// The rebound data starts before the destination but extends into it.
	backing: struct { values: [6]f32, output: [1]SequentialLayerSummary }
	backing.output[0] = {parameterCount = 81}
	before := backing
	dense.weights.value.data = mem.slice_ptr(&backing.values[4], 6)
	_, valid := SequentialSummary(&model, backing.output[:])
	testing.expect(t, !valid && backing == before)
}

@(test)
SequentialSummarySharedBuffersCountNodes :: proc(t: ^testing.T) {
	model: Sequential(2, 1, 1)
	built := SequentialInit(&model, 1) && SequentialAddDense(&model, 1) && SequentialAddDense(&model, 1)
	testing.expect(t, built)
	if !built { return }
	shared := [1]f32{7}
	TestDenseStorage(&model.layers[0]).weights.value.data = shared[:]
	TestDenseStorage(&model.layers[1]).weights.value.data = shared[:]
	storage: [2]SequentialLayerSummary
	result, ok := SequentialSummary(&model, storage[:])
	testing.expect(t, ok && storage[0].parameterCount == 2 && storage[1].parameterCount == 2 && result.totalParameters == 4 && shared[0] == 7)
}

@(test)
SequentialSummaryTrainingAndCheckpoint :: proc(t: ^testing.T) {
	model, restored: Sequential(3, 4, 3)
	built := SequentialInit(&model, 2, 19) && SequentialAddDense(&model, 4) &&
		SequentialAddDropout(&model, 0.2) && SequentialAddDense(&model, 1)
	testing.expect(t, built)
	if !built { return }
	inputs := [6]f32{1, 2, 2, 1, -1, 0}
	targets := [3]f32{1, 1, -1}
	_, trained := SequentialFit(&model, inputs[:], targets[:], epochs = 3)
	testing.expect(t, trained)
	if !trained { return }
	before: [size_of(Sequential(3, 4, 3))]u8
	copy(before[:], (cast([^]u8)rawptr(&model))[:size_of(model)])
	first: [3]SequentialLayerSummary
	original, ok := SequentialSummary(&model, first[:])
	after: [size_of(Sequential(3, 4, 3))]u8
	copy(after[:], (cast([^]u8)rawptr(&model))[:size_of(model)])
	testing.expect(t, ok && original.totalParameters == 17 && before == after)
	checkpoint: [2048]u8
	size, written := CheckpointWrite(&model, nil, 23, checkpoint[:])
	shuffle: u64
	read := false
	if written { read = CheckpointRead(&restored, nil, &shuffle, checkpoint[:size], nil, nil, nil) }
	testing.expect(t, written && read && shuffle == 23)
	if !read { return }
	second: [3]SequentialLayerSummary
	copySummary, restoredOk := SequentialSummary(&restored, second[:])
	testing.expect(t, restoredOk && first == second && copySummary.input == original.input && copySummary.output == original.output && copySummary.totalParameters == original.totalParameters)
}
