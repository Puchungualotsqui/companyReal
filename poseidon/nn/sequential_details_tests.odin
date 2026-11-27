package nn

import "../core"
import "core:mem"
import "core:testing"

SequentialDetailsTestEqualLayer :: proc(t: ^testing.T, a, b: SequentialLayerDetails) {
	testing.expect(t, a.summary == b.summary)
	switch config in a.config {
	case nil:
		switch other in b.config {
		case nil:
		case SequentialConv2DConfig, SequentialPool2DConfig, SequentialDropoutConfig:
			testing.expect(t, false)
		}
	case SequentialConv2DConfig:
		other, ok := b.config.(SequentialConv2DConfig)
		testing.expect(t, ok && config == other)
	case SequentialPool2DConfig:
		other, ok := b.config.(SequentialPool2DConfig)
		testing.expect(t, ok && config == other)
	case SequentialDropoutConfig:
		other, ok := b.config.(SequentialDropoutConfig)
		testing.expect(t, ok && config == other)
	}
}

SequentialDetailsTestEqualLayers :: proc(t: ^testing.T, a, b: []SequentialLayerDetails) {
	testing.expect(t, len(a) == len(b))
	if len(a) != len(b) { return }
	for entry, i in a { SequentialDetailsTestEqualLayer(t, entry, b[i]) }
}

@(test)
SequentialDetailsDenseAndEmpty :: proc(t: ^testing.T) {
	empty: Sequential(3, 12, 2)
	testing.expect(t, SequentialInitSpatial(&empty, 2, 3, 2))
	emptyDetails, emptyOk := SequentialDetails(&empty, nil)
	testing.expect(t, emptyOk && emptyDetails.input == SummarySpatial(2, 3, 2) && emptyDetails.output == emptyDetails.input &&
		emptyDetails.layerCount == 0 && len(emptyDetails.layers) == 0 && emptyDetails.totalParameters == 0 &&
		emptyDetails.parameterNodeCount == 0 && emptyDetails.adamMomentElements == 0 && emptyDetails.modelStorageBytes == size_of(empty))
	_, _, adamEmptyOk := SequentialAdamRequirements(&empty)
	testing.expect(t, !adamEmptyOk)
	testing.expect(t, SequentialAddActivation(&empty, .Tanh) && SequentialAddDropout(&empty, 0) && SequentialAddFlatten(&empty))
	parameterless: [3]SequentialLayerDetails
	withoutWeights, withoutWeightsOk := SequentialDetails(&empty, parameterless[:])
	zeroRate, isDropout := parameterless[1].config.(SequentialDropoutConfig)
	nodes, moments, adamOk := SequentialAdamRequirements(&empty)
	testing.expect(t, withoutWeightsOk && withoutWeights.totalParameters == 0 && withoutWeights.parameterNodeCount == 0 &&
		withoutWeights.adamMomentElements == 0 && isDropout && zeroRate.rate == 0 && adamOk && nodes == 0 && moments == 0)

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
	// A newly added layer can have a different current batch size.
	testing.expect(t, model.layers[6].outputShape[0] == 1 && model.layers[7].outputShape[0] == 4)
	sentinel := SequentialLayerDetails{summary = {parameterCount = 99}, config = SequentialDropoutConfig{0.75}}
	storage: [10]SequentialLayerDetails
	for &entry in storage { entry = sentinel }
	before: [size_of(Sequential(8, 5, 4))]u8
	copy(before[:], (cast([^]u8)rawptr(&model))[:size_of(model)])
	result: SequentialModelDetails
	ok: bool
	{
		context.allocator = mem.panic_allocator()
		context.temp_allocator = mem.panic_allocator()
		result, ok = SequentialDetails(&model, storage[:])
	}
	after: [size_of(Sequential(8, 5, 4))]u8
	copy(after[:], (cast([^]u8)rawptr(&model))[:size_of(model)])
	testing.expect(t, ok && before == after)
	if !ok { return }
	testing.expect(t, result.input == SummaryVector(3) && result.output == SummaryVector(2) && result.batchCapacity == 4 &&
		result.layerCount == 8 && len(result.layers) == 8 && raw_data(result.layers) == &storage[0])
	testing.expect(t, result.totalParameters == 26 && result.trainableParameters == 26 && result.nonTrainableParameters == 0 &&
		result.modelStorageBytes == SequentialStorageSize(8, 5, 4) && result.parameterNodeCount == 4 && result.adamMomentElements == 26)
	base: [8]SequentialLayerSummary
	baseSummary, baseOk := SequentialSummary(&model, base[:])
	kinds := [8]SequentialSummaryLayerKind{.Dense, .Relu, .Dense, .Sigmoid, .Tanh, .Softmax, .Dropout, .Flatten}
	inWidths := [8]int{3, 4, 4, 2, 2, 2, 2, 2}
	outWidths := [8]int{4, 4, 2, 2, 2, 2, 2, 2}
	weights := [8]int{12, 0, 8, 0, 0, 0, 0, 0}
	biases := [8]int{4, 0, 2, 0, 0, 0, 0, 0}
	testing.expect(t, baseOk && baseSummary.totalParameters == result.totalParameters)
	for layer, i in result.layers {
		testing.expect(t, layer.summary == base[i] && layer.summary.kind == kinds[i] &&
			layer.summary.input == SummaryVector(inWidths[i]) && layer.summary.output == SummaryVector(outWidths[i]) &&
			layer.summary.weightCount == weights[i] && layer.summary.biasCount == biases[i] && layer.summary.parameterCount == weights[i]+biases[i])
		if i == 6 {
			config, valid := layer.config.(SequentialDropoutConfig)
			testing.expect(t, valid && config.rate == 0.25)
		} else {
			switch config in layer.config {
			case nil:
			case SequentialConv2DConfig, SequentialPool2DConfig, SequentialDropoutConfig: testing.expect(t, false)
			}
		}
	}
	SequentialDetailsTestEqualLayer(t, storage[8], sentinel)
	SequentialDetailsTestEqualLayer(t, storage[9], sentinel)
	nodeCount, elementCount, requirementsOk := SequentialAdamRequirements(&model)
	parameters: [4]^core.Node
	list, listOk := SequentialParameters(&model, parameters[:])
	first, second: [26]f32
	optimizer: Adam
	initialized := SequentialAdamInit(&model, &optimizer, parameters[:], first[:], second[:])
	testing.expect(t, requirementsOk && listOk && initialized && nodeCount == result.parameterNodeCount && len(list) == nodeCount &&
		elementCount == result.adamMomentElements && len(optimizer.firstMoment) == elementCount && len(optimizer.secondMoment) == elementCount)

	inputs := [6]f32{1, 2, 3, -1, 0, 1}
	targets := [4]f32{0, 1, 1, 0}
	_, trained := SequentialFit(&model, inputs[:], targets[:], epochs = 2, learningRate = 0.01)
	testing.expect(t, trained)
	if !trained { return }
	copy(before[:], (cast([^]u8)rawptr(&model))[:size_of(model)])
	trainedLayers: [8]SequentialLayerDetails
	trainedDetails, trainedOk := SequentialDetails(&model, trainedLayers[:])
	copy(after[:], (cast([^]u8)rawptr(&model))[:size_of(model)])
	testing.expect(t, trainedOk && before == after && trainedDetails.totalParameters == result.totalParameters &&
		trainedDetails.parameterNodeCount == result.parameterNodeCount && trainedDetails.adamMomentElements == result.adamMomentElements)
	SequentialDetailsTestEqualLayers(t, trainedLayers[:], result.layers)
}

@(test)
SequentialDetailsSpatialInferenceAndRestore :: proc(t: ^testing.T) {
	model, restored: Sequential(8, 40, 4)
	built := SequentialInitSpatial(&model, 4, 5, 2, 9) && SequentialAddConv2D(&model, 3, 2, 3, 2, 1) &&
		SequentialAddActivation(&model, .Softmax) && SequentialAddDropout(&model, 0.2) &&
		SequentialAddPool2D(&model, .Max, 2, 2, 1) && SequentialAddPool2D(&model, .Average, 1, 2, 2) &&
		SequentialAddFlatten(&model) && SequentialAddDense(&model, 4) && SequentialAddActivation(&model, .Sigmoid)
	testing.expect(t, built)
	if !built { return }
	originalLayers: [8]SequentialLayerDetails
	original, valid := SequentialDetails(&model, originalLayers[:])
	testing.expect(t, valid)
	if !valid { return }
	testing.expect(t, original.input == SummarySpatial(4, 5, 2) && original.output == SummaryVector(4) &&
		original.totalParameters == 55 && original.parameterNodeCount == 4 && original.adamMomentElements == 55)
	shapes := [9]SequentialSummaryShape{
		SummarySpatial(4, 5, 2), SummarySpatial(2, 3, 3), SummarySpatial(2, 3, 3), SummarySpatial(2, 3, 3),
		SummarySpatial(1, 2, 3), SummarySpatial(1, 1, 3), SummaryVector(3), SummaryVector(4), SummaryVector(4),
	}
	kinds := [8]SequentialSummaryLayerKind{.Conv2D, .Softmax, .Dropout, .MaxPool2D, .AveragePool2D, .Flatten, .Dense, .Sigmoid}
	for layer, i in original.layers {
		testing.expect(t, layer.summary.kind == kinds[i] && layer.summary.input == shapes[i] && layer.summary.output == shapes[i+1])
		if i != 0 && i != 2 && i != 3 && i != 4 {
			switch config in layer.config {
			case nil:
			case SequentialConv2DConfig, SequentialPool2DConfig, SequentialDropoutConfig: testing.expect(t, false)
			}
		}
	}
	testing.expect(t, originalLayers[0].summary.weightCount == 36 && originalLayers[0].summary.biasCount == 3 && originalLayers[0].summary.parameterCount == 39 &&
		originalLayers[6].summary.weightCount == 12 && originalLayers[6].summary.biasCount == 4 && originalLayers[6].summary.parameterCount == 16)
	conv, convOk := originalLayers[0].config.(SequentialConv2DConfig)
	dropout, dropoutOk := originalLayers[2].config.(SequentialDropoutConfig)
	maxPool, maxOk := originalLayers[3].config.(SequentialPool2DConfig)
	avgPool, avgOk := originalLayers[4].config.(SequentialPool2DConfig)
	testing.expect(t, convOk && conv == (SequentialConv2DConfig{3, 2, 2, 1}) && dropoutOk && dropout.rate == 0.2 &&
		maxOk && maxPool == (SequentialPool2DConfig{2, 2, 1, 0}) && avgOk && avgPool == (SequentialPool2DConfig{1, 2, 2, 0}))
	nodeCount, elementCount, requirementsOk := SequentialAdamRequirements(&model)
	testing.expect(t, requirementsOk && nodeCount == original.parameterNodeCount && elementCount == original.adamMomentElements)

	input: [80]f32
	for i in 0..<len(input) { input[i] = f32(i%7-3) / 4 }
	for training in ([2]bool{false, true}) {
		rows := 1
		if training { rows = 2 }
		_, predicted := SequentialPredict(&model, input[:rows*40], training)
		testing.expect(t, predicted)
		if !predicted { return }
		before: [size_of(Sequential(8, 40, 4))]u8
		copy(before[:], (cast([^]u8)rawptr(&model))[:size_of(model)])
		laterLayers: [8]SequentialLayerDetails
		later, laterOk := SequentialDetails(&model, laterLayers[:])
		after: [size_of(Sequential(8, 40, 4))]u8
		copy(after[:], (cast([^]u8)rawptr(&model))[:size_of(model)])
		testing.expect(t, laterOk && before == after && later.input == original.input && later.output == original.output &&
			later.totalParameters == original.totalParameters && later.modelStorageBytes == original.modelStorageBytes)
		SequentialDetailsTestEqualLayers(t, laterLayers[:], originalLayers[:])
	}
	checkpoint: [4096]u8
	size, written := CheckpointWrite(&model, nil, 23, checkpoint[:])
	shuffle: u64
	read := false
	if written { read = CheckpointRead(&restored, nil, &shuffle, checkpoint[:size], nil, nil, nil) }
	testing.expect(t, written && read && shuffle == 23)
	if !read { return }
	before: [size_of(Sequential(8, 40, 4))]u8
	copy(before[:], (cast([^]u8)rawptr(&restored))[:size_of(restored)])
	restoredLayers: [8]SequentialLayerDetails
	loaded, loadedOk := SequentialDetails(&restored, restoredLayers[:])
	after: [size_of(Sequential(8, 40, 4))]u8
	copy(after[:], (cast([^]u8)rawptr(&restored))[:size_of(restored)])
	testing.expect(t, loadedOk && before == after && loaded.input == original.input && loaded.output == original.output &&
		loaded.totalParameters == original.totalParameters && loaded.parameterNodeCount == original.parameterNodeCount &&
		loaded.adamMomentElements == original.adamMomentElements && loaded.modelStorageBytes == original.modelStorageBytes)
	SequentialDetailsTestEqualLayers(t, restoredLayers[:], originalLayers[:])

	_, predicted := SequentialPredict(&restored, input[:40], true)
	state: u64
	bestRestored := SequentialRestoreBest(&restored, nil, &state, checkpoint[:size])
	testing.expect(t, predicted && bestRestored && state == 23)
	if !bestRestored { return }
	copy(before[:], (cast([^]u8)rawptr(&restored))[:size_of(restored)])
	bestLayers: [8]SequentialLayerDetails
	best, bestOk := SequentialDetails(&restored, bestLayers[:])
	copy(after[:], (cast([^]u8)rawptr(&restored))[:size_of(restored)])
	testing.expect(t, bestOk && before == after && best.input == original.input && best.output == original.output &&
		best.totalParameters == original.totalParameters && best.parameterNodeCount == original.parameterNodeCount &&
		best.adamMomentElements == original.adamMomentElements)
	SequentialDetailsTestEqualLayers(t, bestLayers[:], originalLayers[:])
}

@(test)
SequentialDetailsFailureAndCapacity :: proc(t: ^testing.T) {
	box: struct { prefix: SequentialLayerDetails, model: Sequential(2, 3, 2) }
	built := SequentialInit(&box.model, 2) && SequentialAddDense(&box.model, 3) && SequentialAddActivation(&box.model, .Relu)
	testing.expect(t, built)
	if !built { return }
	sentinel := SequentialLayerDetails{summary = {kind = .Dropout, parameterCount = 97}, config = SequentialDropoutConfig{0.5}}
	storage := [2]SequentialLayerDetails{sentinel, sentinel}
	box.prefix = sentinel
	before: [size_of(Sequential(2, 3, 2))]u8
	copy(before[:], (cast([^]u8)rawptr(&box.model))[:size_of(box.model)])
	_, shortOk := SequentialDetails(&box.model, storage[:1])
	_, nilStorageOk := SequentialDetails(&box.model, nil)
	inside := (cast([^]SequentialLayerDetails)rawptr(&box.model))[:2]
	_, insideOk := SequentialDetails(&box.model, inside)
	partial := (cast([^]SequentialLayerDetails)rawptr(&box.prefix))[:2]
	_, partialOk := SequentialDetails(&box.model, partial)
	missing: ^Sequential(2, 3, 2)
	_, nilModelOk := SequentialDetails(missing, storage[:])
	copied := box.model
	_, copiedOk := SequentialDetails(&copied, storage[:])
	after: [size_of(Sequential(2, 3, 2))]u8
	copy(after[:], (cast([^]u8)rawptr(&box.model))[:size_of(box.model)])
	testing.expect(t, !shortOk && !nilStorageOk && !insideOk && !partialOk && !nilModelOk && !copiedOk && before == after)
	SequentialDetailsTestEqualLayer(t, box.prefix, sentinel)
	SequentialDetailsTestEqualLayer(t, storage[0], sentinel)
	SequentialDetailsTestEqualLayer(t, storage[1], sentinel)

	for failure in 0..<10 {
		model: Sequential(5, 32, 2)
		ok := SequentialInitSpatial(&model, 4, 4, 1) && SequentialAddConv2D(&model, 2, 2, 2) &&
			SequentialAddPool2D(&model, .Max, 2, 2, 2) && SequentialAddFlatten(&model) &&
			SequentialAddDense(&model, 2) && SequentialAddDropout(&model, 0.3)
		testing.expect(t, ok)
		if !ok { return }
		dropout := &model.layers[4].operation.(Dropout)
		pool := &model.layers[1].operation.(Pool2D)
		conv := &model.layers[0].operation.(Conv2D)
		dense := &model.layers[3].storage.(DenseStorage(32))
		switch failure {
		case 0: dropout.rate = transmute(f32)u32(0x7fc00000)
		case 1: model.layers[4].layer = nil
		case 2: pool.stride = 0
		case 3: conv.padding = max(int)
		case 4: dense.weightShape[0] += 1
		case 5: model.inputShape[3] = 0
		case 6: model.layerCount = 6
		case 7: model.layerCount = -1
		case 8: dropout.mask = nil
		case 9: model.layers[3].output.grad.data = model.layers[3].outputData[:len(model.layers[3].output.grad.data)]
		}
		output := [5]SequentialLayerDetails{sentinel, sentinel, sentinel, sentinel, sentinel}
		beforeModel: [size_of(Sequential(5, 32, 2))]u8
		copy(beforeModel[:], (cast([^]u8)rawptr(&model))[:size_of(model)])
		result, valid := SequentialDetails(&model, output[:])
		afterModel: [size_of(Sequential(5, 32, 2))]u8
		copy(afterModel[:], (cast([^]u8)rawptr(&model))[:size_of(model)])
		testing.expect(t, !valid && result.layerCount == 0 && len(result.layers) == 0 && beforeModel == afterModel)
		for entry in output { SequentialDetailsTestEqualLayer(t, entry, sentinel) }
	}
}

SequentialDetailsTestParameterOverlap :: proc(t: ^testing.T, model: ^Sequential($maxLayers, $maxWidth, $batchCapacity)) {
	weights, bias: ^core.Node
	switch &operation in model.layers[0].operation {
	case Dense: weights, bias = operation.weights, operation.bias
	case Conv2D: weights, bias = operation.weights, operation.bias
	case nil, Pool2D, Flatten, Relu, Sigmoid, Tanh, Softmax, Dropout: testing.expect(t, false); return
	}
	for failure in 0..<8 {
		output: [2]SequentialLayerDetails
		output[0] = {summary = {parameterCount = 77}, config = SequentialDropoutConfig{0.5}}
		output[1] = {summary = {parameterCount = 88}, config = SequentialDropoutConfig{0.75}}
		node := weights
		if failure >= 4 { node = bias }
		tensor := &node.value
		if (failure / 2) % 2 == 1 { tensor = &node.grad }
		original := tensor^
		if failure % 2 == 0 {
			tensor.data = mem.slice_ptr(cast(^f32)rawptr(&output[1].summary.input.dimensions[0]), len(tensor.data))
		} else {
			alias := mem.slice_ptr(cast(^int)rawptr(&output[1].summary.input.dimensions[0]), len(tensor.shape))
			copy(alias, tensor.shape)
			tensor.shape = alias
		}
		before := output
		beforeModel: [size_of(Sequential(maxLayers, maxWidth, batchCapacity))]u8
		copy(beforeModel[:], (cast([^]u8)rawptr(model))[:size_of(model^)])
		valid: bool
		{
			context.allocator = mem.panic_allocator()
			context.temp_allocator = mem.panic_allocator()
			_, valid = SequentialDetails(model, output[:])
		}
		afterModel: [size_of(Sequential(maxLayers, maxWidth, batchCapacity))]u8
		copy(afterModel[:], (cast([^]u8)rawptr(model))[:size_of(model^)])
		testing.expect(t, !valid && beforeModel == afterModel)
		SequentialDetailsTestEqualLayers(t, output[:], before[:])
		tensor^ = original
	}
}

@(test)
SequentialDetailsReboundAndOverlap :: proc(t: ^testing.T) {
	denseModel: Sequential(1, 3, 2)
	testing.expect(t, SequentialInit(&denseModel, 2) && SequentialAddDense(&denseModel, 3))
	SequentialDetailsTestParameterOverlap(t, &denseModel)
	convModel: Sequential(1, 16, 2)
	testing.expect(t, SequentialInitSpatial(&convModel, 2, 2, 1) && SequentialAddConv2D(&convModel, 1, 1, 2))
	SequentialDetailsTestParameterOverlap(t, &convModel)

	dense := TestDenseStorage(&denseModel.layers[0])
	weights, gradients := [6]f32{1, 2, 3, 4, 5, 6}, [6]f32{6, 5, 4, 3, 2, 1}
	bias, biasGrad := [3]f32{1, 2, 3}, [3]f32{3, 2, 1}
	weightShape, biasShape := [2]int{2, 3}, [1]int{3}
	dense.weights.value.data, dense.weights.grad.data = weights[:], gradients[:]
	dense.bias.value.data, dense.bias.grad.data = bias[:], biasGrad[:]
	dense.weights.value.shape, dense.weights.grad.shape = weightShape[:], weightShape[:]
	dense.bias.value.shape, dense.bias.grad.shape = biasShape[:], biasShape[:]
	storage: [1]SequentialLayerDetails
	details, ok := SequentialDetails(&denseModel, storage[:])
	_, _, compatible := SequentialAdamRequirements(&denseModel)
	testing.expect(t, ok && details.totalParameters == 9 && details.parameterNodeCount == 2 && details.adamMomentElements == 9 && !compatible &&
		weights == [6]f32{1, 2, 3, 4, 5, 6} && gradients == [6]f32{6, 5, 4, 3, 2, 1} &&
		weightShape == [2]int{2, 3} && biasShape == [1]int{3})

	// The parameter range starts before the destination but extends into it.
	backing: struct { values: [6]f32, output: [1]SequentialLayerDetails }
	backing.output[0] = {summary = {parameterCount = 81}}
	dense.weights.value.data = mem.slice_ptr(&backing.values[4], 6)
	before := backing
	_, overlapOk := SequentialDetails(&denseModel, backing.output[:])
	testing.expect(t, !overlapOk && backing.values == before.values)
	SequentialDetailsTestEqualLayers(t, backing.output[:], before.output[:])
	// Exactly adjacent external data is allowed.
	dense.weights.value.data = backing.values[:]
	_, adjacentOk := SequentialDetails(&denseModel, backing.output[:])
	testing.expect(t, adjacentOk && backing.output[0].summary.parameterCount == 9)

	// A later layer's rebound buffer must be checked before writing any records.
	late: Sequential(3, 3, 2)
	built := SequentialInit(&late, 2) && SequentialAddDense(&late, 3) &&
		SequentialAddActivation(&late, .Relu) && SequentialAddDense(&late, 2)
	testing.expect(t, built)
	if !built { return }
	lateOutput: [3]SequentialLayerDetails
	for &entry in lateOutput { entry = {summary = {parameterCount = 42}, config = SequentialDropoutConfig{0.25}} }
	lateBias := &TestDenseStorage(&late.layers[2]).bias
	lateBias.grad.data = mem.slice_ptr(cast(^f32)rawptr(&lateOutput[2].summary.input.dimensions[0]), len(lateBias.grad.data))
	beforeOutput := lateOutput
	beforeModel: [size_of(Sequential(3, 3, 2))]u8
	copy(beforeModel[:], (cast([^]u8)rawptr(&late))[:size_of(late)])
	_, lateOk := SequentialDetails(&late, lateOutput[:])
	afterModel: [size_of(Sequential(3, 3, 2))]u8
	copy(afterModel[:], (cast([^]u8)rawptr(&late))[:size_of(late)])
	testing.expect(t, !lateOk && beforeModel == afterModel)
	SequentialDetailsTestEqualLayers(t, lateOutput[:], beforeOutput[:])

	// Shared parameter buffers are counted per node, not deduplicated.
	sharedModel: Sequential(2, 1, 1)
	built = SequentialInit(&sharedModel, 1) && SequentialAddDense(&sharedModel, 1) && SequentialAddDense(&sharedModel, 1)
	testing.expect(t, built)
	if !built { return }
	shared := [1]f32{7}
	TestDenseStorage(&sharedModel.layers[0]).weights.value.data = shared[:]
	TestDenseStorage(&sharedModel.layers[1]).weights.value.data = shared[:]
	sharedLayers: [2]SequentialLayerDetails
	sharedDetails, sharedOk := SequentialDetails(&sharedModel, sharedLayers[:])
	_, _, sharedAdamOk := SequentialAdamRequirements(&sharedModel)
	testing.expect(t, sharedOk && sharedDetails.totalParameters == 4 && sharedDetails.parameterNodeCount == 4 &&
		sharedDetails.adamMomentElements == 4 && !sharedAdamOk && shared[0] == 7)
}
