package nn

import "../core"
import "core:math"
import "core:mem"
import "core:testing"

@(test)
SequentialAdamDenseTraining :: proc(t: ^testing.T) {
	model, reference: Sequential(4, 3, 2)
	for target in ([2]^Sequential(4, 3, 2){&model, &reference}) {
		ok := SequentialInit(target, 2, 17) && SequentialAddDense(target, 3) &&
			SequentialAddActivation(target, .Tanh) && SequentialAddDropout(target, 0.25) && SequentialAddDense(target, 1)
		testing.expect(t, ok)
		if !ok { return }
	}
	parameters: [6]^core.Node
	first, second: [15]f32
	for &value in first { value = 7 }
	for &value in second { value = 8 }
	adam := Adam{step = 99}
	count, elements: int
	ok: bool
	initialized: bool
	{
		context.allocator = mem.nil_allocator()
		count, elements, ok = SequentialAdamRequirements(&model)
		initialized = SequentialAdamInit(&model, &adam, parameters[:], first[:], second[:], 0.02, 0.8, 0.95, 1e-6)
	}
	testing.expect(t, ok && count == 4 && elements == 13 && initialized)
	if !ok || !initialized { return }
	firstDense, lastDense := TestDenseStorage(&model.layers[0]), TestDenseStorage(&model.layers[3])
	testing.expect(t, parameters == [6]^core.Node{&firstDense.weights, &firstDense.bias, &lastDense.weights, &lastDense.bias, nil, nil})
	testing.expect(t, len(adam.parameters) == 4 && len(adam.firstMoment) == 13 && len(adam.secondMoment) == 13)
	testing.expect(t, adam.step == 0 && adam.learningRate == 0.02 && adam.beta1 == 0.8 && adam.beta2 == 0.95 && adam.epsilon == 1e-6)
	for i in 0..<13 { testing.expect(t, first[i] == 0 && second[i] == 0) }
	testing.expect(t, first[13] == 7 && first[14] == 7 && second[13] == 8 && second[14] == 8)

	referenceStorage: [4]^core.Node
	referenceParameters, referenceOk := SequentialParameters(&reference, referenceStorage[:])
	referenceFirst, referenceSecond: [13]f32
	referenceAdam: Adam
	testing.expect(t, referenceOk && AdamInit(&referenceAdam, referenceParameters, referenceFirst[:], referenceSecond[:], 0.02, 0.8, 0.95, 1e-6))
	inputs := [6]f32{1, 2, -1, 3, 0, 1}
	targets := [3]f32{1, -1, 0.5}
	indices, referenceIndices: [3]int
	state, referenceState: u64 = 7, 7
	loss, fitOk := SequentialFitBatches(&model, inputs[:], targets[:], indices[:], &state, epochs = 3, optimizer = &adam)
	referenceLoss, referenceFitOk := SequentialFitBatches(&reference, inputs[:], targets[:], referenceIndices[:], &referenceState, epochs = 3, optimizer = &referenceAdam)
	testing.expect(t, fitOk && referenceFitOk && loss == referenceLoss && state == referenceState && adam.step == referenceAdam.step && adam.step == 6)
	for i in 0..<13 { testing.expect(t, first[i] == referenceFirst[i] && second[i] == referenceSecond[i]) }
	for index in ([2]int{0, 3}) {
		a, b := TestDenseStorage(&model.layers[index]), TestDenseStorage(&reference.layers[index])
		testing.expect(t, a.weightData == b.weightData && a.biasData == b.biasData)
	}
	count, elements, ok = SequentialAdamRequirements(&model)
	testing.expect(t, ok && count == 4 && elements == 13)
	testing.expect(t, SequentialAdamInit(&model, &adam, parameters[:], first[:], second[:]))
	testing.expect(t, adam.step == 0 && adam.learningRate == 0.001 && adam.beta1 == 0.9 && adam.beta2 == 0.999 && adam.epsilon == 1e-8)
	for i in 0..<13 { testing.expect(t, first[i] == 0 && second[i] == 0) }
	testing.expect(t, first[13] == 7 && second[13] == 8)
}

@(test)
SequentialAdamSpatialAndCheckpoint :: proc(t: ^testing.T) {
	model, restored: Sequential(6, 16, 2)
	ok := SequentialInitSpatial(&model, 3, 3, 1, 42) && SequentialAddConv2D(&model, 2, 2, 2) &&
		SequentialAddActivation(&model, .Relu) && SequentialAddPool2D(&model, .Max, 2, 2, 1) &&
		SequentialAddFlatten(&model) && SequentialAddDense(&model, 1) && SequentialAddActivation(&model, .Softmax)
	testing.expect(t, ok)
	if !ok { return }
	count, elements, requirementsOk := SequentialAdamRequirements(&model)
	testing.expect(t, requirementsOk && count == 4 && elements == 13)
	parameters: [4]^core.Node
	first, second: [13]f32
	adam: Adam
	testing.expect(t, SequentialAdamInit(&model, &adam, parameters[:], first[:], second[:], learningRate = 0.1))
	conv := &model.layers[0].storage.(Conv2DStorage(16))
	dense := TestDenseStorage(&model.layers[4])
	testing.expect(t, parameters == [4]^core.Node{&conv.weights, &conv.bias, &dense.weights, &dense.bias})
	for parameter in adam.parameters { for &gradient in parameter.grad.data { gradient = 1 } }
	initialWeight, initialBias := conv.weightData[0], dense.biasData[0]
	testing.expect(t, AdamStep(&adam) && adam.step == 1)
	testing.expect(t, math.abs(conv.weightData[0]-(initialWeight-0.1)) < 0.000001 && math.abs(dense.biasData[0]-(initialBias-0.1)) < 0.000001)
	checkpoint: [4096]u8
	size, saved := CheckpointWrite(&model, &adam, 42, checkpoint[:])
	shuffle: u64
	otherParameters: [4]^core.Node
	otherFirst, otherSecond: [13]f32
	otherAdam: Adam
	restoredOk := saved && CheckpointRead(&restored, &otherAdam, &shuffle, checkpoint[:size], otherParameters[:], otherFirst[:], otherSecond[:])
	testing.expect(t, restoredOk && shuffle == 42 && otherAdam.step == 1 && otherFirst == first && otherSecond == second)
	if restoredOk {
		count, elements, requirementsOk = SequentialAdamRequirements(&restored)
		testing.expect(t, requirementsOk && count == 4 && elements == 13)
		for parameter in otherAdam.parameters { for &gradient in parameter.grad.data { gradient = 1 } }
		testing.expect(t, AdamStep(&adam) && AdamStep(&otherAdam) && adam.step == 2 && otherAdam.step == 2)
		testing.expect(t, first == otherFirst && second == otherSecond)
		restoredConv := &restored.layers[0].storage.(Conv2DStorage(16))
		testing.expect(t, conv.weightData == restoredConv.weightData && dense.biasData == TestDenseStorage(&restored.layers[4]).biasData)
		testing.expect(t, SequentialAdamInit(&restored, &otherAdam, otherParameters[:], otherFirst[:], otherSecond[:]))
		testing.expect(t, otherAdam.step == 0 && otherFirst == [13]f32{} && otherSecond == [13]f32{})
	}
}

@(test)
SequentialAdamEmptyAndInvalidModel :: proc(t: ^testing.T) {
	model: Sequential(3, 2, 2)
	count, elements, ok := SequentialAdamRequirements(&model)
	testing.expect(t, !ok && count == 0 && elements == 0)
	testing.expect(t, SequentialInit(&model, 2))
	count, elements, ok = SequentialAdamRequirements(&model)
	testing.expect(t, !ok && count == 0 && elements == 0)
	testing.expect(t, SequentialAddFlatten(&model) && SequentialAddActivation(&model, .Sigmoid))
	count, elements, ok = SequentialAdamRequirements(&model)
	testing.expect(t, ok && count == 0 && elements == 0)
	adam := Adam{step = 12}
	testing.expect(t, SequentialAdamInit(&model, &adam, nil, nil, nil))
	testing.expect(t, len(adam.parameters) == 0 && len(adam.firstMoment) == 0 && len(adam.secondMoment) == 0 && adam.step == 0 && AdamStep(&adam) && adam.step == 1)
	copyModel := model
	count, elements, ok = SequentialAdamRequirements(&copyModel)
	testing.expect(t, !ok && count == 0 && elements == 0)
	model.layerCount = -1
	_, _, ok = SequentialAdamRequirements(&model)
	testing.expect(t, !ok)
	model.layerCount = 4
	_, _, ok = SequentialAdamRequirements(&model)
	testing.expect(t, !ok)
}

SequentialAdamTestUnchanged :: proc(t: ^testing.T, model: ^Sequential(1, 2, 2), adam: ^Adam, parameters: []^core.Node, first, second: []f32) {
	testing.expect(t, adam.step == 77 && adam.learningRate == 0.5 && len(adam.parameters) == 0)
	testing.expect(t, parameters[0] == &model.input && parameters[1] == &model.input && parameters[2] == &model.input)
	testing.expect(t, first[0] == 1 && first[1] == 2 && first[2] == 3 && second[0] == 4 && second[1] == 5 && second[2] == 6)
	testing.expect(t, model.self == rawptr(model) && model.layerCount == 1 && TestDenseStorage(&model.layers[0]).biasData[0] == 0)
}

@(test)
SequentialAdamFailuresAreAtomic :: proc(t: ^testing.T) {
	model: Sequential(1, 2, 2)
	ok := SequentialInit(&model, 1) && SequentialAddDense(&model, 1)
	testing.expect(t, ok)
	if !ok { return }
	adam := Adam{step = 77, learningRate = 0.5}
	parameters := [3]^core.Node{&model.input, &model.input, &model.input}
	first := [3]f32{1, 2, 3}
	second := [3]f32{4, 5, 6}
	testing.expect(t, !SequentialAdamInit(&model, nil, parameters[:], first[:], second[:]))
	testing.expect(t, !SequentialAdamInit((^Sequential(1, 2, 2))(nil), &adam, parameters[:], first[:], second[:]))
	testing.expect(t, !SequentialAdamInit(&model, &adam, parameters[:1], first[:], second[:]))
	testing.expect(t, !SequentialAdamInit(&model, &adam, parameters[:], first[:1], second[:]))
	testing.expect(t, !SequentialAdamInit(&model, &adam, parameters[:], first[:], second[:1]))
	testing.expect(t, !SequentialAdamInit(&model, &adam, parameters[:], first[:], second[:], learningRate = 0))
	testing.expect(t, !SequentialAdamInit(&model, &adam, parameters[:], first[:], second[:], learningRate = math.inf_f32(1)))
	testing.expect(t, !SequentialAdamInit(&model, &adam, parameters[:], first[:], second[:], beta1 = 1))
	testing.expect(t, !SequentialAdamInit(&model, &adam, parameters[:], first[:], second[:], beta2 = math.nan_f32()))
	testing.expect(t, !SequentialAdamInit(&model, &adam, parameters[:], first[:], second[:], epsilon = 0))
	SequentialAdamTestUnchanged(t, &model, &adam, parameters[:], first[:], second[:])

	dense := TestDenseStorage(&model.layers[0])
	oldGrad := dense.weights.grad.data
	dense.weights.grad.data = dense.weights.value.data
	count, elements, valid := SequentialAdamRequirements(&model)
	testing.expect(t, !valid && count == 0 && elements == 0 && !SequentialAdamInit(&model, &adam, parameters[:], first[:], second[:]))
	dense.weights.grad.data = oldGrad
	oldShape := dense.weightShape
	dense.weightShape = {2, 1}
	testing.expect(t, !SequentialAdamInit(&model, &adam, parameters[:], first[:], second[:]))
	dense.weightShape = oldShape
	oldLayer := model.layers[0].layer
	wrongLayer: ^Dense
	model.layers[0].layer = wrongLayer
	testing.expect(t, !SequentialAdamInit(&model, &adam, parameters[:], first[:], second[:]))
	model.layers[0].layer = oldLayer
	oldData := dense.weights.value.data
	dense.weights.value.data = model.inputData[:1]
	testing.expect(t, !SequentialAdamInit(&model, &adam, parameters[:], first[:], second[:]))
	dense.weights.value.data = oldData
	SequentialAdamTestUnchanged(t, &model, &adam, parameters[:], first[:], second[:])
}

@(test)
SequentialAdamWiringValidation :: proc(t: ^testing.T) {
	model: Sequential(3, 2, 2)
	ok := SequentialInit(&model, 1) && SequentialAddDense(&model, 1) && SequentialAddDropout(&model, 0.25) && SequentialAddActivation(&model, .Relu)
	testing.expect(t, ok)
	if !ok { return }
	parameters := [2]^core.Node{&model.input, &model.input}
	first := [2]f32{4, 5}
	second := [2]f32{6, 7}
	adam := Adam{step = 23}
	dense := TestDenseStorage(&model.layers[0])
	externalShape := [2]int{1, 1}
	oldShape := dense.weights.value.shape
	dense.weights.value.shape = externalShape[:]
	testing.expect(t, !SequentialAdamInit(&model, &adam, parameters[:], first[:], second[:]))
	dense.weights.value.shape = oldShape
	externalFeatures: [2]f32
	oldOutput := model.layers[2].output.grad.data
	model.layers[2].output.grad.data = externalFeatures[:]
	testing.expect(t, !SequentialAdamInit(&model, &adam, parameters[:], first[:], second[:]))
	model.layers[2].output.grad.data = oldOutput
	dropout := &model.layers[1].operation.(Dropout)
	oldMask := dropout.mask
	dropout.mask = externalFeatures[:]
	testing.expect(t, !SequentialAdamInit(&model, &adam, parameters[:], first[:], second[:]))
	dropout.mask = oldMask
	oldInput := dropout.input
	dropout.input = &model.input
	testing.expect(t, !SequentialAdamInit(&model, &adam, parameters[:], first[:], second[:]))
	dropout.input = oldInput
	oldLayer := model.layers[2].layer
	model.layers[2].layer = nil
	testing.expect(t, !SequentialAdamInit(&model, &adam, parameters[:], first[:], second[:]))
	model.layers[2].layer = oldLayer
	testing.expect(t, adam.step == 23 && parameters == [2]^core.Node{&model.input, &model.input} && first == [2]f32{4, 5} && second == [2]f32{6, 7})
	dense.weightData[0] = math.nan_f32()
	testing.expect(t, SequentialAdamInit(&model, &adam, parameters[:], first[:], second[:]))
	testing.expect(t, !AdamStep(&adam) && adam.step == 0 && first == [2]f32{} && second == [2]f32{})
}

SequentialAdamTestNodePointer :: ^core.Node

@(test)
SequentialAdamReboundParameterBuffers :: proc(t: ^testing.T) {
	model: Sequential(1, 2, 2)
	ok := SequentialInit(&model, 2) && SequentialAddDense(&model, 1)
	testing.expect(t, ok)
	if !ok { return }
	dense := TestDenseStorage(&model.layers[0])
	// Use aligned backing so it can also exercise a pointer-list overlap.
	valueBacking: [2]u64
	values := mem.slice_ptr(cast(^f32)rawptr(&valueBacking[0]), 4)
	values[0], values[1], values[2], values[3] = 1, 2, 3, 99
	gradients := [3]f32{1, 2, 3}
	dense.weights.value.data, dense.bias.value.data = values[:2], values[2:3]
	dense.weights.grad.data, dense.bias.grad.data = gradients[:2], gradients[2:]
	count, elements, valid := SequentialAdamRequirements(&model)
	testing.expect(t, valid && count == 2 && elements == 3)
	parameters := [2]^core.Node{&model.input, &model.input}
	first := [3]f32{4, 5, 6}
	second := [3]f32{7, 8, 9}
	adam := Adam{step = 77, learningRate = 0.5}
	aliasedList := mem.slice_ptr(cast(^SequentialAdamTestNodePointer)rawptr(&valueBacking[0]), 2)
	testing.expect(t, !SequentialAdamInit(&model, &adam, parameters[:], values[:3], second[:]))
	testing.expect(t, !SequentialAdamInit(&model, &adam, parameters[:], first[:], gradients[:]))
	testing.expect(t, !SequentialAdamInit(&model, &adam, aliasedList, first[:], second[:]))
	oldWeights := dense.weights.value.data
	dense.weights.value.data = mem.slice_ptr(cast(^f32)rawptr(&adam), 2)
	testing.expect(t, !SequentialAdamInit(&model, &adam, parameters[:], first[:], second[:]))
	dense.weights.value.data = oldWeights
	oldBias := dense.bias.value.data
	dense.bias.value.data = values[1:2]
	_, _, valid = SequentialAdamRequirements(&model)
	testing.expect(t, !valid && !SequentialAdamInit(&model, &adam, parameters[:], first[:], second[:]))
	dense.bias.value.data = oldBias
	oldBiasGrad := dense.bias.grad.data
	dense.bias.grad.data = values[:1]
	_, _, valid = SequentialAdamRequirements(&model)
	testing.expect(t, !valid && !SequentialAdamInit(&model, &adam, parameters[:], first[:], second[:]))
	dense.bias.grad.data = oldBiasGrad
	testing.expect(t, adam.step == 77 && adam.learningRate == 0.5 && parameters == [2]^core.Node{&model.input, &model.input})
	testing.expect(t, first == [3]f32{4, 5, 6} && second == [3]f32{7, 8, 9} && values[0] == 1 && values[1] == 2 && values[2] == 3 && values[3] == 99 && gradients == [3]f32{1, 2, 3})
	initialized: bool
	{
		context.allocator = mem.nil_allocator()
		initialized = SequentialAdamInit(&model, &adam, parameters[:], first[:], second[:], learningRate = 0.1)
	}
	testing.expect(t, initialized && AdamStep(&adam) && adam.step == 1)
	for index in 0..<3 { testing.expect(t, math.abs(values[index] - (f32(index+1)-0.1)) < 0.000001) }
	testing.expect(t, values[3] == 99 && gradients == [3]f32{1, 2, 3})
}

@(test)
SequentialAdamRangeBounds :: proc(t: ^testing.T) {
	_, valid := SequentialAdamRange(nil, 1, size_of(f32))
	testing.expect(t, !valid)
	_, valid = SequentialAdamRange(rawptr(uintptr(1)), -1, size_of(f32))
	testing.expect(t, !valid)
	_, valid = SequentialAdamRange(rawptr(uintptr(1)), max(int), size_of(u64))
	testing.expect(t, !valid)
	_, valid = SequentialAdamRange(rawptr(max(uintptr)-1), 1, size_of(f32))
	testing.expect(t, !valid)
	empty, emptyValid := SequentialAdamRange(nil, 0, size_of(f32))
	first, firstValid := SequentialAdamRange(rawptr(uintptr(100)), 2, size_of(f32))
	adjacent, adjacentValid := SequentialAdamRange(rawptr(uintptr(108)), 1, size_of(f32))
	partial, partialValid := SequentialAdamRange(rawptr(uintptr(107)), 1, size_of(f32))
	testing.expect(t, emptyValid && firstValid && adjacentValid && partialValid &&
		!SequentialAdamRangesOverlap(empty, first) && !SequentialAdamRangesOverlap(first, adjacent) &&
		SequentialAdamRangesOverlap(first, partial) && SequentialAdamRangesOverlap(partial, first))
}

@(test)
SequentialAdamOverlapAndUnusedTails :: proc(t: ^testing.T) {
	model: Sequential(1, 2, 2)
	ok := SequentialInit(&model, 1) && SequentialAddDense(&model, 1)
	testing.expect(t, ok)
	if !ok { return }
	adam := Adam{step = 77, learningRate = 0.5}
	parameters := [3]^core.Node{&model.input, &model.input, &model.input}
	first := [3]f32{1, 2, 3}
	second := [3]f32{4, 5, 6}
	shared := [4]f32{11, 12, 13, 14}
	modelParameters := mem.slice_ptr(cast(^SequentialAdamTestNodePointer)rawptr(&model), 2)
	optimizerParameters := mem.slice_ptr(cast(^SequentialAdamTestNodePointer)rawptr(&adam), 2)
	parameterFloats := mem.slice_ptr(cast(^f32)rawptr(&parameters[0]), 2)
	optimizerFloats := mem.slice_ptr(cast(^f32)rawptr(&adam), 2)
	testing.expect(t, !SequentialAdamInit(&model, cast(^Adam)rawptr(&model), parameters[:], first[:], second[:]))
	testing.expect(t, !SequentialAdamInit(&model, &adam, modelParameters, first[:], second[:]))
	testing.expect(t, !SequentialAdamInit(&model, &adam, parameters[:], model.inputData[:2], second[:]))
	testing.expect(t, !SequentialAdamInit(&model, &adam, parameters[:], first[:], model.inputGrad[:2]))
	testing.expect(t, !SequentialAdamInit(&model, &adam, optimizerParameters, first[:], second[:]))
	testing.expect(t, !SequentialAdamInit(&model, &adam, parameters[:], optimizerFloats, second[:]))
	testing.expect(t, !SequentialAdamInit(&model, &adam, parameters[:], first[:], optimizerFloats))
	testing.expect(t, !SequentialAdamInit(&model, &adam, parameters[:], parameterFloats, second[:]))
	testing.expect(t, !SequentialAdamInit(&model, &adam, parameters[:], first[:], parameterFloats))
	testing.expect(t, !SequentialAdamInit(&model, &adam, parameters[:], shared[:2], shared[1:3]))
	SequentialAdamTestUnchanged(t, &model, &adam, parameters[:], first[:], second[:])
	testing.expect(t, shared == [4]f32{11, 12, 13, 14})
	// The overlapping supplied tails are not borrowed or modified.
	testing.expect(t, SequentialAdamInit(&model, &adam, parameters[:], shared[:], shared[2:]))
	testing.expect(t, shared == [4]f32{} && len(adam.firstMoment) == 2 && len(adam.secondMoment) == 2 && parameters[2] == &model.input)
}
