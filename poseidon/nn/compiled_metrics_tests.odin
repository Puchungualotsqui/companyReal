package nn

import "../core"
import "core:math"
import "core:mem"
import "core:testing"

@(test)
CompiledMetricsBinaryUnevenAndState :: proc(t: ^testing.T) {
	model: Sequential(2, 2, 2)
	initialized := SequentialInit(&model, 1, 42) && SequentialAddDense(&model, 2) && SequentialAddDropout(&model, 0.5)
	testing.expect(t, initialized)
	if !initialized { return }
	dense := TestDenseStorage(&model.layers[0])
	dense.weightData = {1, -1, 0, 0}
	dense.weightGrad = {3, 4, 5, 6}
	dense.biasGrad = {7, 8}
	model.inputGrad = {1, 2, 3, 4}
	model.layers[0].outputGrad = {5, 6, 7, 8}
	model.layers[1].outputGrad = {9, 10, 11, 12}
	parameterStorage: [2]^core.Node
	parameters, valid := SequentialParameters(&model, parameterStorage[:])
	testing.expect(t, valid)
	if !valid { return }
	first := [4]f32{1, 2, 3, 4}
	second := [4]f32{5, 6, 7, 8}
	adam := Adam{parameters, first[:], second[:], 9, 0.01, 0.9, 0.999, 1e-8}
	compiled: CompiledSequential(2, 2, 2)
	testing.expect(t, SequentialCompile(&compiled, &model, BCEWithLogits{}, &adam))
	inputs := [5]f32{-2, -1, 0, 1, 2}
	targets := [10]f32{0, 1, 0, 1, 1, 0, 1, 0, 0, 1}
	originalInputs, originalTargets := inputs, targets
	weights, biases, weightGrad, biasGrad := dense.weightData, dense.biasData, dense.weightGrad, dense.biasGrad
	inputGrad, layerGrad, dropoutGrad := model.inputGrad, model.layers[0].outputGrad, model.layers[1].outputGrad
	state := model.randomState

	predictions: [10]f32
	testing.expect(t, CompiledSequentialPredict(&compiled, inputs[:], predictions[:]))
	shape := [2]int{5, 2}
	legacyAccuracy, accuracyOk := BinaryAccuracyWithLogits(core.Tensor{shape[:], predictions[:]}, core.Tensor{shape[:], targets[:]})
	testing.expect(t, accuracyOk && math.abs(f64(legacyAccuracy)-0.7) < 1e-7)
	for batchSize in ([3]int{0, 1, 2}) {
		result, ok := CompiledSequentialEvaluateMetrics(&compiled, inputs[:], targets[:], .BinaryAccuracyWithLogits, batchSize)
		legacyLoss, lossOk := CompiledSequentialEvaluate(&compiled, inputs[:], targets[:], batchSize)
		testing.expect(t, ok && lossOk && result.metric == f64(7)/10 && f32(result.dataLoss) == legacyLoss)
		testing.expect(t, math.abs(result.metric-f64(legacyAccuracy)) < 1e-7)
	}
	testing.expect(t, inputs == originalInputs && targets == originalTargets && model.randomState == state)
	testing.expect(t, dense.weightData == weights && dense.biasData == biases && dense.weightGrad == weightGrad && dense.biasGrad == biasGrad)
	testing.expect(t, model.inputGrad == inputGrad && model.layers[0].outputGrad == layerGrad && model.layers[1].outputGrad == dropoutGrad)
	testing.expect(t, adam.step == 9 && first == [4]f32{1, 2, 3, 4} && second == [4]f32{5, 6, 7, 8})
	compiled.optimizer = nil
	result, ok := CompiledSequentialEvaluateMetrics(&compiled, inputs[:], targets[:], .BinaryAccuracyWithLogits)
	testing.expect(t, ok && result.metric == f64(7)/10 && adam.step == 9)
}

@(test)
CompiledMetricsCategoricalUnevenAndTies :: proc(t: ^testing.T) {
	model: Sequential(1, 3, 2)
	initialized := SequentialInit(&model, 3, 7) && SequentialAddDense(&model, 3)
	testing.expect(t, initialized)
	if !initialized { return }
	TestDenseStorage(&model.layers[0]).weightData = {1, 0, 0, 0, 1, 0, 0, 0, 1}
	compiled: CompiledSequential(1, 3, 2)
	testing.expect(t, SequentialCompile(&compiled, &model, CCEWithLogits{}))
	inputs := [15]f32{2, 2, -1, -1000, 1000, 0, 1, 3, 2, 9, 0, 1, 0, 0, 0}
	targets := [15]f32{0.5, 0.5, 0, 0, 1, 0, 0.1, 0.2, 0.7, 0, 1, 0, 0, 0, 1}
	predictions: [15]f32
	testing.expect(t, CompiledSequentialPredict(&compiled, inputs[:], predictions[:]))
	shape := [2]int{5, 3}
	legacyAccuracy, accuracyOk := CategoricalAccuracyWithLogits(core.Tensor{shape[:], predictions[:]}, core.Tensor{shape[:], targets[:]})
	testing.expect(t, accuracyOk && math.abs(f64(legacyAccuracy)-0.4) < 1e-7)
	for batchSize in ([3]int{0, 1, 2}) {
		result, ok := CompiledSequentialEvaluateMetrics(&compiled, inputs[:], targets[:], .CategoricalAccuracyWithLogits, batchSize)
		legacyLoss, lossOk := CompiledSequentialEvaluate(&compiled, inputs[:], targets[:], batchSize)
		testing.expect(t, ok && lossOk && result.metric == f64(2)/5 && f32(result.dataLoss) == legacyLoss)
		testing.expect(t, math.abs(result.metric-f64(legacyAccuracy)) < 1e-7)
	}
}

@(test)
CompiledMetricsRegressionAndIndependentLoss :: proc(t: ^testing.T) {
	model: Sequential(1, 2, 2)
	initialized := SequentialInit(&model, 2, 11) && SequentialAddDense(&model, 2)
	testing.expect(t, initialized)
	if !initialized { return }
	TestDenseStorage(&model.layers[0]).weightData = {1, 0, 0, 1}
	compiled: CompiledSequential(1, 2, 2)
	inputs := [10]f32{1, -2, 3, 0, -1, 4, 2, 2, 10, -4}
	targets := [10]f32{0, 0, 1, 0, -2, 1, 1, 1, 5, 0}
	shape := [2]int{5, 2}
	mae, maeOk := MeanAbsoluteError(core.Tensor{shape[:], inputs[:]}, core.Tensor{shape[:], targets[:]})
	mse, mseOk := MeanSquaredError(core.Tensor{shape[:], inputs[:]}, core.Tensor{shape[:], targets[:]})
	testing.expect(t, maeOk && mseOk && mae == 2 && math.abs(mse-6.2) < 1e-6)
	for loss in ([3]SequentialLoss{MSE{}, MAE{}, Huber{1}}) {
		testing.expect(t, SequentialCompile(&compiled, &model, loss))
		for batchSize in ([3]int{0, 1, 2}) {
			legacy, lossOk := CompiledSequentialEvaluate(&compiled, inputs[:], targets[:], batchSize)
			absolute, aok := CompiledSequentialEvaluateMetrics(&compiled, inputs[:], targets[:], .MeanAbsoluteError, batchSize)
			squared, sok := CompiledSequentialEvaluateMetrics(&compiled, inputs[:], targets[:], .MeanSquaredError, batchSize)
			testing.expect(t, lossOk && aok && sok && f32(absolute.dataLoss) == legacy && f32(squared.dataLoss) == legacy)
			testing.expect(t, absolute.metric == 2 && squared.metric == f64(62)/10)
		}
	}
	result, ok := CompiledSequentialEvaluateMetrics(&compiled, inputs[:], inputs[:], .MeanAbsoluteError)
	testing.expect(t, ok && result.metric == 0 && result.dataLoss == 0)
	inputBefore := model.inputData
	result, ok = CompiledSequentialEvaluateMetrics(&compiled, inputs[:9], targets[:], .MeanAbsoluteError)
	testing.expect(t, !ok && result == SupervisedEvaluation{} && model.inputData == inputBefore)
}

@(test)
CompiledMetricsPreflightAndOverlap :: proc(t: ^testing.T) {
	model: Sequential(1, 1, 2)
	initialized := SequentialInit(&model, 1, 7) && SequentialAddDense(&model, 1)
	testing.expect(t, initialized)
	if !initialized { return }
	TestDenseStorage(&model.layers[0]).weightData[0] = 1
	compiled: CompiledSequential(1, 1, 2)
	testing.expect(t, SequentialCompile(&compiled, &model))
	inputs := [3]f32{-1, 0, 1}
	targets := [3]f32{0, 1, 1}
	badInputs, badTargets := inputs, targets
	badInputs[2] = math.nan_f32()
	badTargets[2] = math.inf_f32(1)
	badBinary := [3]f32{0, 1, 0.5}
	model.inputData = {11, 12}
	model.layers[0].outputData = {13, 14}
	inputBefore, outputBefore, shapeBefore := model.inputData, model.layers[0].outputData, model.inputShape
	rng := model.randomState
	cases := [9]struct { inputs, targets: []f32, metric: SupervisedMetric, batchSize: int }{
		{nil, targets[:], .MeanAbsoluteError, 0},
		{inputs[:], nil, .MeanAbsoluteError, 0},
		{inputs[:], targets[:2], .MeanAbsoluteError, 0},
		{inputs[:], targets[:], .MeanAbsoluteError, -1},
		{inputs[:], targets[:], .MeanAbsoluteError, 3},
		{inputs[:], targets[:], SupervisedMetric(99), 0},
		{badInputs[:], targets[:], .MeanAbsoluteError, 0},
		{inputs[:], badTargets[:], .MeanSquaredError, 0},
		{inputs[:], badBinary[:], .BinaryAccuracyWithLogits, 0},
	}
	for item in cases {
		result, ok := CompiledSequentialEvaluateMetrics(&compiled, item.inputs, item.targets, item.metric, item.batchSize)
		testing.expect(t, !ok && result == SupervisedEvaluation{})
		testing.expect(t, model.inputData == inputBefore && model.layers[0].outputData == outputBefore && model.inputShape == shapeBefore && model.randomState == rng)
	}
	for which in 0..<2 {
		result: SupervisedEvaluation
		ok: bool
		if which == 0 {
			result, ok = CompiledSequentialEvaluateMetrics(&compiled, model.inputData[:], targets[:2], .MeanAbsoluteError)
		} else {
			result, ok = CompiledSequentialEvaluateMetrics(&compiled, inputs[:2], model.layers[0].outputData[:], .MeanAbsoluteError)
		}
		testing.expect(t, !ok && result == SupervisedEvaluation{} && model.inputData == inputBefore && model.layers[0].outputData == outputBefore)
	}
	compiledFloats := mem.slice_ptr(cast(^f32)rawptr(&compiled), 2)
	result, ok := CompiledSequentialEvaluateMetrics(&compiled, compiledFloats, targets[:2], .MeanAbsoluteError)
	testing.expect(t, !ok && result == SupervisedEvaluation{} && model.inputData == inputBefore)
	result, ok = CompiledSequentialEvaluateMetrics(&compiled, inputs[:2], compiledFloats, .MeanAbsoluteError)
	testing.expect(t, !ok && result == SupervisedEvaluation{} && model.inputData == inputBefore)
	compiled.loss = nil
	result, ok = CompiledSequentialEvaluateMetrics(&compiled, inputs[:], targets[:], .MeanAbsoluteError)
	testing.expect(t, !ok && result == SupervisedEvaluation{} && model.inputData == inputBefore)
	for delta in ([4]f32{0, -1, math.nan_f32(), math.inf_f32(1)}) {
		compiled.loss = Huber{delta}
		result, ok = CompiledSequentialEvaluateMetrics(&compiled, inputs[:], targets[:], .MeanAbsoluteError)
		testing.expect(t, !ok && result == SupervisedEvaluation{} && model.inputData == inputBefore)
	}
	compiled.loss = BCEWithLogits{}
	badBinary[2] = 2
	result, ok = CompiledSequentialEvaluateMetrics(&compiled, inputs[:], badBinary[:], .MeanAbsoluteError)
	testing.expect(t, !ok && result == SupervisedEvaluation{} && model.inputData == inputBefore)
	compiled.loss = MSE{}
	model.layers[0].width = 3
	result, ok = CompiledSequentialEvaluateMetrics(&compiled, inputs[:], targets[:], .MeanAbsoluteError)
	testing.expect(t, !ok && result == SupervisedEvaluation{} && model.inputData == inputBefore)
	model.layers[0].width = 1
	model.inputShape[1] = 2
	result, ok = CompiledSequentialEvaluateMetrics(&compiled, inputs[:], targets[:], .MeanAbsoluteError)
	testing.expect(t, !ok && result == SupervisedEvaluation{} && model.inputData == inputBefore)
	model.inputShape[1] = 1
	model.layers[0].outputShape[1] = 2
	result, ok = CompiledSequentialEvaluateMetrics(&compiled, inputs[:], targets[:], .MeanAbsoluteError)
	testing.expect(t, !ok && result == SupervisedEvaluation{} && model.inputData == inputBefore)
	model.layers[0].outputShape[1] = 1
	copied := model
	compiled.model = &copied
	result, ok = CompiledSequentialEvaluateMetrics(&compiled, inputs[:], targets[:], .MeanAbsoluteError)
	testing.expect(t, !ok && result == SupervisedEvaluation{} && copied.inputData == inputBefore)
	compiled.model = nil
	result, ok = CompiledSequentialEvaluateMetrics(&compiled, inputs[:], targets[:], .MeanAbsoluteError)
	testing.expect(t, !ok && result == SupervisedEvaluation{})
	result, ok = CompiledSequentialEvaluateMetrics((^CompiledSequential(1, 1, 2))(nil), inputs[:], targets[:], .MeanAbsoluteError)
	testing.expect(t, !ok && result == SupervisedEvaluation{})

	backing: struct { prefix: [2]f32, model: Sequential(1, 1, 2) }
	initialized = SequentialInit(&backing.model, 1) && SequentialAddDense(&backing.model, 1)
	testing.expect(t, initialized)
	if !initialized { return }
	compiled.model = &backing.model
	crossesModel := mem.slice_ptr(&backing.prefix[1], 2)
	testing.expect(t, uintptr(rawptr(&backing.model)) == uintptr(rawptr(&backing.prefix[1]))+size_of(f32))
	result, ok = CompiledSequentialEvaluateMetrics(&compiled, crossesModel, targets[:2], .MeanAbsoluteError)
	testing.expect(t, !ok && result == SupervisedEvaluation{} && backing.model.inputData == [2]f32{})
}

@(test)
CompiledMetricsCategoricalValidationAndSpatial :: proc(t: ^testing.T) {
	model: Sequential(1, 3, 2)
	initialized := SequentialInit(&model, 3) && SequentialAddDense(&model, 3)
	testing.expect(t, initialized)
	if !initialized { return }
	compiled: CompiledSequential(1, 3, 2)
	testing.expect(t, SequentialCompile(&compiled, &model, MSE{}))
	inputs := [9]f32{1, 0, 0, 0, 1, 0, 0, 0, 1}
	targets := [9]f32{1, 0, 0, 0, 1, 0, 0, 0.5, 0.5}
	model.inputData[0] = 17
	for invalid in ([5]f32{-0.1, 1.1, 0.4, math.nan_f32(), math.inf_f32(1)}) {
		targets[8] = invalid
		result, ok := CompiledSequentialEvaluateMetrics(&compiled, inputs[:], targets[:], .CategoricalAccuracyWithLogits)
		testing.expect(t, !ok && result == SupervisedEvaluation{} && model.inputData[0] == 17)
		compiled.loss = CCEWithLogits{}
		result, ok = CompiledSequentialEvaluateMetrics(&compiled, inputs[:], targets[:], .MeanAbsoluteError)
		testing.expect(t, !ok && result == SupervisedEvaluation{} && model.inputData[0] == 17)
		compiled.loss = MSE{}
	}
	targets[8] = 0.5
	result, ok := CompiledSequentialEvaluateMetrics(&compiled, inputs[:], targets[:], .BinaryAccuracyWithLogits)
	testing.expect(t, !ok && result == SupervisedEvaluation{} && model.inputData[0] == 17)
	targets[8] = 0.499995
	{
		context.allocator = mem.panic_allocator()
		context.temp_allocator = mem.panic_allocator()
		result, ok = CompiledSequentialEvaluateMetrics(&compiled, inputs[:], targets[:], .CategoricalAccuracyWithLogits)
	}
	testing.expect(t, ok)
	targets[8] = 0.49998
	result, ok = CompiledSequentialEvaluateMetrics(&compiled, inputs[:], targets[:], .CategoricalAccuracyWithLogits)
	testing.expect(t, !ok && result == SupervisedEvaluation{})

	spatial: Sequential(1, 2, 2)
	initialized = SequentialInitSpatial(&spatial, 1, 1, 2) && SequentialAddActivation(&spatial, .Relu)
	testing.expect(t, initialized)
	if !initialized { return }
	spatialCompiled: CompiledSequential(1, 2, 2)
	testing.expect(t, SequentialCompile(&spatialCompiled, &spatial, MSE{}))
	spatialInputs := [6]f32{-1, 1, 1, -1, 0, 0}
	spatialTargets := [6]f32{0, 1, 1, 0, 1, 1}
	result, ok = CompiledSequentialEvaluateMetrics(&spatialCompiled, spatialInputs[:], spatialTargets[:], .CategoricalAccuracyWithLogits)
	testing.expect(t, !ok && result == SupervisedEvaluation{})
	result, ok = CompiledSequentialEvaluateMetrics(&spatialCompiled, spatialInputs[:], spatialTargets[:], .BinaryAccuracyWithLogits)
	testing.expect(t, ok && result.metric == f64(4)/6)
	spatialCompiled.loss = CCEWithLogits{}
	result, ok = CompiledSequentialEvaluateMetrics(&spatialCompiled, spatialInputs[:], spatialTargets[:], .MeanAbsoluteError)
	testing.expect(t, !ok && result == SupervisedEvaluation{})
}

@(test)
CompiledMetricsRejectProbabilityHeads :: proc(t: ^testing.T) {
	for activation in ([2]ActivationKind{.Sigmoid, .Softmax}) {
		model: Sequential(4, 2, 2)
		initialized := SequentialInit(&model, 2) && SequentialAddDense(&model, 2) && SequentialAddActivation(&model, activation) && SequentialAddDropout(&model, 0.5) && SequentialAddFlatten(&model)
		testing.expect(t, initialized)
		if !initialized { return }
		compiled: CompiledSequential(4, 2, 2)
		testing.expect(t, SequentialCompile(&compiled, &model, MSE{}))
		inputs := [4]f32{1, 0, 0, 1}
		targets := [4]f32{1, 0, 0, 1}
		model.inputData[0] = 17
		for metric in ([2]SupervisedMetric{.BinaryAccuracyWithLogits, .CategoricalAccuracyWithLogits}) {
			result, ok := CompiledSequentialEvaluateMetrics(&compiled, inputs[:], targets[:], metric)
			testing.expect(t, !ok && result == SupervisedEvaluation{} && model.inputData[0] == 17)
		}
		compiled.loss = BCEWithLogits{}
		result, lossOk := CompiledSequentialEvaluateMetrics(&compiled, inputs[:], targets[:], .MeanAbsoluteError)
		testing.expect(t, !lossOk && result == SupervisedEvaluation{} && model.inputData[0] == 17)
		compiled.loss = CCEWithLogits{}
		result, lossOk = CompiledSequentialEvaluateMetrics(&compiled, inputs[:], targets[:], .MeanAbsoluteError)
		if activation == .Softmax {
			testing.expect(t, !lossOk && result == SupervisedEvaluation{} && model.inputData[0] == 17)
		} else {
			legacyLoss, legacyOk := CompiledSequentialEvaluate(&compiled, inputs[:], targets[:])
			testing.expect(t, lossOk && legacyOk && math.abs(result.dataLoss-f64(legacyLoss)) < 0.000001)
		}
		compiled.loss = MSE{}
		_, ok := CompiledSequentialEvaluateMetrics(&compiled, inputs[:], targets[:], .MeanSquaredError)
		testing.expect(t, ok)
	}
}

@(test)
CompiledMetricsLateFailureAndCapacity :: proc(t: ^testing.T) {
	model: Sequential(1, 1, 2)
	initialized := SequentialInit(&model, 1) && SequentialAddDense(&model, 1)
	testing.expect(t, initialized)
	if !initialized { return }
	TestDenseStorage(&model.layers[0]).weightData[0] = 2
	compiled: CompiledSequential(1, 1, 2)
	testing.expect(t, SequentialCompile(&compiled, &model))
	inputs := [3]f32{1, 2, 3.4e38}
	targets := [3]f32{0, 0, 0}
	result, ok := CompiledSequentialEvaluateMetrics(&compiled, inputs[:], targets[:], .MeanAbsoluteError)
	testing.expect(t, !ok && result == SupervisedEvaluation{} && TestDenseStorage(&model.layers[0]).weightData[0] == 2)
	testing.expect(t, model.inputData[0] == inputs[2])

	wide: Sequential(1, 128, 2)
	initialized = SequentialInit(&wide, 1) && SequentialAddDense(&wide, 128)
	testing.expect(t, initialized)
	if !initialized { return }
	dense := TestDenseStorage(&wide.layers[0])
	for &weight in dense.weightData { weight = 0 }
	for &bias in dense.biasData { bias = 1 }
	wideCompiled: CompiledSequential(1, 128, 2)
	testing.expect(t, SequentialCompile(&wideCompiled, &wide))
	wideInputs := [7]f32{1, 2, 3, 4, 5, 6, 7}
	wideTargets: [7*128]f32
	{
		context.allocator = mem.panic_allocator()
		context.temp_allocator = mem.panic_allocator()
		result, ok = CompiledSequentialEvaluateMetrics(&wideCompiled, wideInputs[:], wideTargets[:], .MeanSquaredError)
	}
	testing.expect(t, ok && result.dataLoss == 1 && result.metric == 1)
	result, ok = CompiledSequentialEvaluateMetrics(&wideCompiled, wideInputs[:], wideTargets[:], .MeanSquaredError, 3)
	testing.expect(t, !ok && result == SupervisedEvaluation{})
}

@(test)
CompiledMetricsSingleCapacityAndF64Precision :: proc(t: ^testing.T) {
	model: Sequential(1, 1, 1)
	initialized := SequentialInit(&model, 1) && SequentialAddDense(&model, 1)
	testing.expect(t, initialized)
	if !initialized { return }
	TestDenseStorage(&model.layers[0]).weightData[0] = 1
	compiled: CompiledSequential(1, 1, 1)
	testing.expect(t, SequentialCompile(&compiled, &model, MSE{}))
	inputs := [3]f32{0, 2, 3}
	targets := [3]f32{1, 0, 1}
	result, ok := CompiledSequentialEvaluateMetrics(&compiled, inputs[:], targets[:], .BinaryAccuracyWithLogits)
	testing.expect(t, ok && result.metric == f64(2)/3 && result.dataLoss == 3)
	result, ok = CompiledSequentialEvaluateMetrics(&compiled, inputs[:], targets[:], .BinaryAccuracyWithLogits, 2)
	testing.expect(t, !ok && result == SupervisedEvaluation{})

	largeInputs := [2]f32{1e38, -1e38}
	largeTargets := [2]f32{-1e38, 1e38}
	compiled.loss = MAE{}
	result, ok = CompiledSequentialEvaluateMetrics(&compiled, largeInputs[:], largeTargets[:], .MeanSquaredError)
	difference := f64(largeInputs[0])-f64(largeTargets[0])
	testing.expect(t, ok && result.metric == difference*difference && result.metric > 1e76)
	compiled.loss = MSE{}
	result, ok = CompiledSequentialEvaluateMetrics(&compiled, largeInputs[:], largeTargets[:], .MeanAbsoluteError)
	testing.expect(t, !ok && result == SupervisedEvaluation{})
}
