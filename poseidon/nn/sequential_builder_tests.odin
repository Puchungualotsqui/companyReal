package nn

import "../core"
import "core:math"
import "core:mem"
import "core:testing"

// Compare architecture, serialized parameters/RNG, and parameter node values.
SequentialBuilderExpectSame :: proc(t: ^testing.T, a, b: ^Sequential($maxLayers, $maxWidth, $batchCapacity)) {
	layersA, layersB: [maxLayers]SequentialLayerSummary
	summaryA, okA := SequentialSummary(a, layersA[:])
	summaryB, okB := SequentialSummary(b, layersB[:])
	testing.expect(t, okA && okB)
	if !okA || !okB { return }
	testing.expect(t, summaryA.input == summaryB.input && summaryA.output == summaryB.output &&
		summaryA.layerCount == summaryB.layerCount && summaryA.totalParameters == summaryB.totalParameters)
	for layer, i in summaryA.layers { testing.expect(t, layer == summaryB.layers[i]) }

	parametersA, parametersB: [2 * maxLayers]^core.Node
	nodesA, paramsA := SequentialParameters(a, parametersA[:])
	nodesB, paramsB := SequentialParameters(b, parametersB[:])
	testing.expect(t, paramsA && paramsB && len(nodesA) == len(nodesB))
	if paramsA && paramsB && len(nodesA) == len(nodesB) {
		for node, i in nodesA {
			testing.expect(t, len(node.value.data) == len(nodesB[i].value.data))
			if len(node.value.data) == len(nodesB[i].value.data) {
				for value, j in node.value.data { testing.expect(t, value == nodesB[i].value.data[j]) }
			}
		}
	}
	bytesA, bytesB: [8192]u8
	sizeA, writtenA := CheckpointWrite(a, nil, 123, bytesA[:])
	sizeB, writtenB := CheckpointWrite(b, nil, 123, bytesB[:])
	testing.expect(t, writtenA && writtenB && sizeA == sizeB && a.randomState == b.randomState)
	if writtenA && writtenB && sizeA == sizeB {
		for value, i in bytesA[:sizeA] { testing.expect(t, value == bytesB[i]) }
	}
}

@(test)
SequentialBuilderDenseAndRNG :: proc(t: ^testing.T) {
	built, explicit: Sequential(5, 4, 3)
	initialized := SequentialInit(&built, 2, 0) && SequentialInit(&explicit, 2, 0)
	testing.expect(t, initialized)
	if !initialized { return }
	specs := [3]SequentialLayerSpec{
		SequentialDenseSpec{4}, SequentialActivationSpec{.Tanh}, SequentialDropoutSpec{0.25},
	}
	index: int
	ok: bool
	{
		context.allocator = mem.panic_allocator()
		context.temp_allocator = mem.panic_allocator()
		index, ok = SequentialAddSpecs(&built, specs[:])
	}
	manual := SequentialAddDense(&explicit, 4) && SequentialAddActivation(&explicit, .Tanh) && SequentialAddDropout(&explicit, 0.25)
	testing.expect(t, ok && index == -1 && manual)
	if !ok || !manual { return }
	// Specs can be reused immediately; layers must not point into their storage.
	specs = {}
	SequentialBuilderExpectSame(t, &built, &explicit)
	dropout := &built.layers[2].operation.(Dropout)
	testing.expect(t, dropout.rate == 0.25 && dropout.randomState == &built.randomState &&
		&dropout.mask[0] == &TestDropoutStorage(&built.layers[2]).maskData[0])
	input := [4]f32{0.5, -1, 2, 0.25}
	state := built.randomState
	outputA, predA := SequentialPredict(&built, input[:], true)
	outputB, predB := SequentialPredict(&explicit, input[:], true)
	testing.expect(t, predA && predB && built.randomState == explicit.randomState && built.randomState != state)
	if predA && predB && len(outputA) == len(outputB) {
		for value, i in outputA { testing.expect(t, value == outputB[i]) }
	}
	// Later initialization consumes the RNG state advanced by training dropout.
	{
		context.allocator = mem.panic_allocator()
		context.temp_allocator = mem.panic_allocator()
		ok = SequentialAddSpec(&built, SequentialDenseSpec{2}) && SequentialAddSpec(&built, SequentialActivationSpec{.Sigmoid})
	}
	manual = SequentialAddDense(&explicit, 2) && SequentialAddActivation(&explicit, .Sigmoid)
	testing.expect(t, ok && manual)
	if !ok || !manual { return }
	SequentialBuilderExpectSame(t, &built, &explicit)
	state = built.randomState
	outputA, predA = SequentialPredict(&built, input[:])
	outputB, predB = SequentialPredict(&explicit, input[:])
	testing.expect(t, predA && predB && len(outputA) == 4 && len(outputB) == 4 && built.randomState == state && built.randomState == explicit.randomState)
	if predA && predB && len(outputA) == len(outputB) {
		for value, i in outputA { testing.expect(t, value == outputB[i]) }
	}
}

// Deliberately let the specs go out of scope before the model is used.
SequentialBuilderSpatialFromLocalSpecs :: proc(model: ^Sequential(8, 40, 4)) -> (int, bool) {
	specs := [8]SequentialLayerSpec{
		SequentialConv2DSpec{kernelHeight = 3, kernelWidth = 2, outputChannels = 3, stride = 2, padding = 1},
		SequentialActivationSpec{.Softmax},
		SequentialDropoutSpec{0.2},
		SequentialPool2DSpec{.Max, 2, 2, 1},
		SequentialPool2DSpec{.Average, 1, 2, 2},
		SequentialFlattenSpec{},
		SequentialDenseSpec{4},
		SequentialActivationSpec{.Relu},
	}
	return SequentialAddSpecs(model, specs[:])
}

@(test)
SequentialBuilderSpatialAndLifetime :: proc(t: ^testing.T) {
	built, explicit: Sequential(8, 40, 4)
	initialized := SequentialInitSpatial(&built, 4, 5, 2, 9) && SequentialInitSpatial(&explicit, 4, 5, 2, 9)
	testing.expect(t, initialized)
	if !initialized { return }
	index: int
	ok: bool
	{
		context.allocator = mem.panic_allocator()
		context.temp_allocator = mem.panic_allocator()
		index, ok = SequentialBuilderSpatialFromLocalSpecs(&built)
	}
	manual := SequentialAddConv2D(&explicit, 3, 2, 3, 2, 1) && SequentialAddActivation(&explicit, .Softmax) &&
		SequentialAddDropout(&explicit, 0.2) && SequentialAddPool2D(&explicit, .Max, 2, 2, 1) &&
		SequentialAddPool2D(&explicit, .Average, 1, 2, 2) && SequentialAddFlatten(&explicit) &&
		SequentialAddDense(&explicit, 4) && SequentialAddActivation(&explicit, .Relu)
	testing.expect(t, ok && index == -1 && manual)
	if !ok || !manual { return }
	SequentialBuilderExpectSame(t, &built, &explicit)
	summaries: [8]SequentialLayerSummary
	summary, summarized := SequentialSummary(&built, summaries[:])
	testing.expect(t, summarized && summary.input == SummarySpatial(4, 5, 2) && summary.output == SummaryVector(4) && summary.totalParameters == 55)
	input: [80]f32
	for &value, i in input { value = f32(i%13-6) / 10 }
	for training in ([2]bool{false, true}) {
		outputA, predA := SequentialPredict(&built, input[:], training)
		outputB, predB := SequentialPredict(&explicit, input[:], training)
		testing.expect(t, predA && predB && built.randomState == explicit.randomState && len(outputA) == 8 && len(outputB) == 8)
		if predA && predB && len(outputA) == len(outputB) {
			for value, i in outputA { testing.expect(t, value == outputB[i]) }
		}
	}
	SequentialBuilderExpectSame(t, &built, &explicit)
}

@(test)
SequentialBuilderInvalidSpecs :: proc(t: ^testing.T) {
	vector: Sequential(4, 16, 2)
	testing.expect(t, SequentialInit(&vector, 3, 17))
	invalid := [15]SequentialLayerSpec{
		nil, SequentialDenseSpec{0}, SequentialDenseSpec{-1}, SequentialDenseSpec{17},
		SequentialActivationSpec{ActivationKind(99)},
		SequentialDropoutSpec{-0.1}, SequentialDropoutSpec{1},
		SequentialDropoutSpec{math.nan_f32()}, SequentialDropoutSpec{math.inf_f32(1)}, SequentialDropoutSpec{math.inf_f32(-1)},
		SequentialConv2DSpec{1, 1, 1, 1, 0}, SequentialPool2DSpec{.Max, 1, 1, 1},
		SequentialConv2DSpec{1, 1, 1, 0, 0}, SequentialPool2DSpec{PoolKind(99), 1, 1, 1},
		SequentialPool2DSpec{.Average, 1, 1, 0},
	}
	state := vector.randomState
	for spec in invalid {
		only := [1]SequentialLayerSpec{spec}
		index, ok := SequentialAddSpecs(&vector, only[:])
		testing.expect(t, !ok && index == 0 && !SequentialAddSpec(&vector, spec) && vector.layerCount == 0 && vector.randomState == state)
	}
	spatial: Sequential(3, 16, 2)
	testing.expect(t, SequentialInitSpatial(&spatial, 3, 3, 1, 17))
	invalidSpatial := [13]SequentialLayerSpec{
		SequentialDenseSpec{1},
		SequentialConv2DSpec{0, 1, 1, 1, 0}, SequentialConv2DSpec{1, 1, 0, 1, 0},
		SequentialConv2DSpec{1, 1, 17, 1, 0}, SequentialConv2DSpec{1, 1, 2, 1, 0},
		SequentialConv2DSpec{1, 1, 1, 0, 0}, SequentialConv2DSpec{1, 1, 1, 1, -1},
		SequentialConv2DSpec{max(int), 2, 1, 1, 0},
		SequentialPool2DSpec{PoolKind(99), 1, 1, 1}, SequentialPool2DSpec{.Max, 0, 1, 1},
		SequentialPool2DSpec{.Max, 4, 1, 1}, SequentialPool2DSpec{.Average, 1, 1, 0},
		SequentialPool2DSpec{.Max, max(int), 2, 1},
	}
	state = spatial.randomState
	for spec in invalidSpatial {
		only := [1]SequentialLayerSpec{spec}
		index, ok := SequentialAddSpecs(&spatial, only[:])
		testing.expect(t, !ok && index == 0 && !SequentialAddSpec(&spatial, spec) && spatial.layerCount == 0 && spatial.randomState == state)
	}
	// Flatten also delegates shape validation rather than accepting broken metadata.
	spatial.inputShape[1] = 0
	testing.expect(t, !SequentialAddSpec(&spatial, SequentialFlattenSpec{}) && spatial.layerCount == 0 && spatial.randomState == state)
}

@(test)
SequentialBuilderPartialFailureAndResume :: proc(t: ^testing.T) {
	built, explicit: Sequential(6, 4, 2)
	initialized := SequentialInit(&built, 2, 42) && SequentialInit(&explicit, 2, 42) &&
		SequentialAddActivation(&built, .Relu) && SequentialAddActivation(&explicit, .Relu)
	testing.expect(t, initialized)
	if !initialized { return }
	specs := [4]SequentialLayerSpec{SequentialDenseSpec{3}, SequentialActivationSpec{.Tanh}, SequentialDropoutSpec{1}, SequentialDenseSpec{1}}
	index, ok := SequentialAddSpecs(&built, specs[:])
	manual := SequentialAddDense(&explicit, 3) && SequentialAddActivation(&explicit, .Tanh) && !SequentialAddDropout(&explicit, 1)
	testing.expect(t, !ok && index == 2 && manual && built.layerCount == 3 && built.randomState == explicit.randomState)
	if !manual || built.layerCount != 3 { return }
	SequentialBuilderExpectSame(t, &built, &explicit)
	input := [2]f32{1, -1}
	_, predicted := SequentialPredict(&built, input[:])
	testing.expect(t, predicted)
	specs[2] = SequentialDropoutSpec{0.5}
	index, ok = SequentialAddSpecs(&built, specs[2:])
	manual = SequentialAddDropout(&explicit, 0.5) && SequentialAddDense(&explicit, 1)
	testing.expect(t, ok && index == -1 && manual && built.layerCount == 5)
	if ok && manual { SequentialBuilderExpectSame(t, &built, &explicit) }

	full: Sequential(2, 2, 1)
	testing.expect(t, SequentialInit(&full, 1, 3) && SequentialAddDense(&full, 2))
	tooMany := [2]SequentialLayerSpec{SequentialActivationSpec{.Relu}, SequentialDenseSpec{1}}
	state := full.randomState
	index, ok = SequentialAddSpecs(&full, tooMany[:])
	testing.expect(t, !ok && index == 1 && full.layerCount == 2 && full.randomState == state)
	index, ok = SequentialAddSpecs(&full, nil)
	testing.expect(t, ok && index == -1 && full.layerCount == 2)
	testing.expect(t, !SequentialAddSpec(&full, SequentialFlattenSpec{}))
}

@(test)
SequentialBuilderModelPreflight :: proc(t: ^testing.T) {
	model: Sequential(2, 2, 1)
	specs := [1]SequentialLayerSpec{SequentialDenseSpec{1}}
	index, ok := SequentialAddSpecs(&model, specs[:])
	testing.expect(t, !ok && index == -1 && !SequentialAddSpec(&model, specs[0]))
	index, ok = SequentialAddSpecs(&model, nil)
	testing.expect(t, !ok && index == -1)
	index, ok = SequentialAddSpecs(cast(^Sequential(2, 2, 1))nil, specs[:])
	testing.expect(t, !ok && index == -1 && !SequentialAddSpec(cast(^Sequential(2, 2, 1))nil, specs[0]))
	testing.expect(t, SequentialInit(&model, 1, 7))
	index, ok = SequentialAddSpecs(&model, nil)
	testing.expect(t, ok && index == -1 && model.layerCount == 0)
	copyModel := model
	index, ok = SequentialAddSpecs(&copyModel, specs[:])
	testing.expect(t, !ok && index == -1 && !SequentialAddSpec(&copyModel, specs[0]) && model.layerCount == 0)
	index, ok = SequentialAddSpecs(&copyModel, nil)
	testing.expect(t, !ok && index == -1)
	for count in ([2]int{-1, 3}) {
		model.layerCount = count
		index, ok = SequentialAddSpecs(&model, specs[:])
		testing.expect(t, !ok && index == -1 && model.layerCount == count)
	}
	model.layerCount = 0
	testing.expect(t, SequentialAddSpec(&model, SequentialActivationSpec{.Sigmoid}))
	input := [1]f32{1}
	_, predicted := SequentialPredict(&model, input[:])
	testing.expect(t, predicted)
}

@(test)
SequentialBuilderOverlap :: proc(t: ^testing.T) {
	box: struct { prefix: [1]SequentialLayerSpec, model: Sequential(3, 4, 2), suffix: [1]SequentialLayerSpec }
	box.prefix[0] = SequentialDenseSpec{2}
	box.suffix[0] = SequentialActivationSpec{.Tanh}
	testing.expect(t, SequentialInit(&box.model, 2, 9))
	before: [size_of(Sequential(3, 4, 2))]u8
	copy(before[:], (cast([^]u8)rawptr(&box.model))[:size_of(box.model)])
	inside := mem.slice_ptr(cast(^SequentialLayerSpec)rawptr(&box.model), 1)
	crossing := mem.slice_ptr(&box.prefix[0], 2)
	testing.expect(t, uintptr(rawptr(&box.model)) == uintptr(rawptr(&box.prefix[0])) + size_of(SequentialLayerSpec))
	index, ok := SequentialAddSpecs(&box.model, inside)
	testing.expect(t, !ok && index == -1)
	index, ok = SequentialAddSpecs(&box.model, crossing)
	testing.expect(t, !ok && index == -1)
	after: [size_of(Sequential(3, 4, 2))]u8
	copy(after[:], (cast([^]u8)rawptr(&box.model))[:size_of(box.model)])
	testing.expect(t, before == after)
	index, ok = SequentialAddSpecs(&box.model, inside[:0])
	testing.expect(t, ok && index == -1)
	// Adjacent, non-overlapping specs on either side of the model are allowed.
	index, ok = SequentialAddSpecs(&box.model, box.prefix[:])
	testing.expect(t, ok && index == -1)
	index, ok = SequentialAddSpecs(&box.model, box.suffix[:])
	testing.expect(t, ok && index == -1 && box.model.layerCount == 2)
	input := [2]f32{1, 2}
	_, predicted := SequentialPredict(&box.model, input[:])
	testing.expect(t, predicted)
}

@(test)
SequentialBuilderCapacities :: proc(t: ^testing.T) {
	// More layers than a small fixed builder scratch array would support.
	model: Sequential(145, 1, 1)
	testing.expect(t, SequentialInit(&model, 1, 5))
	specs: [145]SequentialLayerSpec
	for &spec, i in specs {
		if i % 2 == 0 { spec = SequentialActivationSpec{.Sigmoid} } else { spec = SequentialFlattenSpec{} }
	}
	index: int
	ok: bool
	{
		context.allocator = mem.panic_allocator()
		context.temp_allocator = mem.panic_allocator()
		index, ok = SequentialAddSpecs(&model, specs[:])
	}
	testing.expect(t, ok && index == -1 && model.layerCount == len(specs))
	input := [1]f32{1}
	_, predicted := SequentialPredict(&model, input[:])
	testing.expect(t, predicted)
	small: Sequential(1, 1, 1)
	testing.expect(t, SequentialInit(&small, 1, 5) && SequentialAddSpec(&small, SequentialDenseSpec{1}) && !SequentialAddSpec(&small, SequentialDenseSpec{1}))
}
