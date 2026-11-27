package nn

import "core:math"
import "core:mem"
import "core:testing"

@(test)
SupervisedRMSEAggregatesAllElementsAcrossUnevenBatches :: proc(t: ^testing.T) {
	model: Sequential(1, 2, 3)
	compiled: CompiledSequential(1, 2, 3)
	initialized := SequentialInit(&model, 2, 11) && SequentialAddDense(&model, 2) &&
		SequentialCompile(&compiled, &model, Huber{1})
	testing.expect(t, initialized)
	if !initialized { return }
	TestDenseStorage(&model.layers[0]).weightData = {1, 0, 0, 1}
	TestDenseStorage(&model.layers[0]).biasData = {0, 0}
	inputs := [10]f32{1, -2, 3, 0, -1, 4, 2, 2, 10, -4}
	targets := [10]f32{0, 0, 1, 0, -2, 1, 1, 1, 5, 0}
	metrics := [3]SupervisedMetric{.RootMeanSquaredError, .MeanAbsoluteError, .MeanSquaredError}
	expectedMSE := f64(62)/10
	expectedRMSE := math.sqrt(expectedMSE)
	for batchSize in ([4]int{0, 1, 2, 3}) {
		values: [3]f64
		loss: f64
		ok: bool
		{
			context.allocator = mem.panic_allocator()
			context.temp_allocator = mem.panic_allocator()
			loss, ok = CompiledSequentialEvaluateMany(&compiled, inputs[:], targets[:], metrics[:], values[:], batchSize)
		}
		single, singleOk := CompiledSequentialEvaluateMetrics(&compiled, inputs[:], targets[:], .RootMeanSquaredError, batchSize)
		testing.expect(t, ok && singleOk && loss == single.dataLoss && values[0] == single.metric)
		testing.expect(t, values[1] == 2 && values[2] == expectedMSE && values[0] == expectedRMSE)
	}
	reordered := [3]SupervisedMetric{.MeanSquaredError, .RootMeanSquaredError, .MeanAbsoluteError}
	values: [3]f64
	_, reorderedOk := CompiledSequentialEvaluateMany(&compiled, inputs[:], targets[:], reordered[:], values[:], 2)
	testing.expect(t, reorderedOk && values == [3]f64{expectedMSE, expectedRMSE, 2})
	perfect, ok := CompiledSequentialEvaluateMetrics(&compiled, inputs[:], inputs[:], .RootMeanSquaredError, 2)
	testing.expect(t, ok && perfect.metric == 0 && perfect.dataLoss == 0)
}

@(test)
SupervisedRMSECoexistsWithEveryMetric :: proc(t: ^testing.T) {
	testing.expect(t, SUPERVISED_METRIC_COUNT == 5 &&
		int(SupervisedMetric.MeanAbsoluteError) == 0 && int(SupervisedMetric.MeanSquaredError) == 1 &&
		int(SupervisedMetric.BinaryAccuracyWithLogits) == 2 && int(SupervisedMetric.CategoricalAccuracyWithLogits) == 3 &&
		int(SupervisedMetric.RootMeanSquaredError) == 4)
	model: Sequential(1, 2, 2)
	compiled: CompiledSequential(1, 2, 2)
	initialized := SequentialInit(&model, 2, 5) && SequentialAddDense(&model, 2) &&
		SequentialCompile(&compiled, &model, CCEWithLogits{})
	testing.expect(t, initialized)
	if !initialized { return }
	TestDenseStorage(&model.layers[0]).weightData = {1, 0, 0, 1}
	TestDenseStorage(&model.layers[0]).biasData = {0, 0}
	inputs := [6]f32{2, -1, -1, 2, 1, 2}
	targets := [6]f32{1, 0, 0, 1, 1, 0}
	metrics := [SUPERVISED_METRIC_COUNT]SupervisedMetric{
		.RootMeanSquaredError, .CategoricalAccuracyWithLogits, .MeanAbsoluteError,
		.BinaryAccuracyWithLogits, .MeanSquaredError,
	}
	values: [SUPERVISED_METRIC_COUNT]f64
	loss, ok := CompiledSequentialEvaluateMany(&compiled, inputs[:], targets[:], metrics[:], values[:], 2)
	testing.expect(t, ok && values[0] == math.sqrt(f64(4)/3) && values[1] == f64(2)/3 &&
		values[2] == 1 && values[3] == f64(5)/6 && values[4] == f64(4)/3)
	for metric, index in metrics {
		single, singleOk := CompiledSequentialEvaluateMetrics(&compiled, inputs[:], targets[:], metric, 2)
		testing.expect(t, singleOk && loss == single.dataLoss && values[index] == single.metric)
	}
}

@(test)
SupervisedRMSESupportsSpatialAndProbabilityOutputs :: proc(t: ^testing.T) {
	spatial: Sequential(1, 2, 2)
	compiled: CompiledSequential(1, 2, 2)
	initialized := SequentialInitSpatial(&spatial, 1, 1, 2) && SequentialAddActivation(&spatial, .Relu) &&
		SequentialCompile(&compiled, &spatial, MSE{})
	testing.expect(t, initialized)
	if !initialized { return }
	inputs := [6]f32{-1, 1, 1, -1, 0, 0}
	targets := [6]f32{0, 1, 1, 0, 1, 1}
	result, ok := CompiledSequentialEvaluateMetrics(&compiled, inputs[:], targets[:], .RootMeanSquaredError, 2)
	testing.expect(t, ok && result.metric == math.sqrt(f64(1)/3))

	for activation in ([2]ActivationKind{.Sigmoid, .Softmax}) {
		model: Sequential(2, 2, 2)
		head: CompiledSequential(2, 2, 2)
		ready := SequentialInit(&model, 2) && SequentialAddDense(&model, 2) &&
			SequentialAddActivation(&model, activation) && SequentialCompile(&head, &model, MSE{})
		testing.expect(t, ready)
		if !ready { return }
		metrics := [2]SupervisedMetric{.RootMeanSquaredError, .MeanSquaredError}
		values: [2]f64
		_, evaluated := CompiledSequentialEvaluateMany(&head, inputs[:], targets[:], metrics[:], values[:], 2)
		testing.expect(t, evaluated && values[0] == math.sqrt(values[1]))
	}
}

@(test)
SupervisedRMSEUsesF64AndRespectsLossFailures :: proc(t: ^testing.T) {
	model: Sequential(1, 1, 2)
	compiled: CompiledSequential(1, 1, 2)
	initialized := SequentialInit(&model, 1) && SequentialAddDense(&model, 1) &&
		SequentialCompile(&compiled, &model, MAE{})
	testing.expect(t, initialized)
	if !initialized { return }
	TestDenseStorage(&model.layers[0]).weightData[0] = 1
	TestDenseStorage(&model.layers[0]).biasData[0] = 0
	// The first difference exceeds f32 range, but this batch's MAE is finite.
	inputs := [2]f32{2e38, 0}
	targets := [2]f32{-2e38, 0}
	metrics := [2]SupervisedMetric{.RootMeanSquaredError, .MeanSquaredError}
	values: [2]f64
	_, ok := CompiledSequentialEvaluateMany(&compiled, inputs[:], targets[:], metrics[:], values[:])
	difference := f64(inputs[0])-f64(targets[0])
	bigRMSE := math.sqrt(difference*difference/2)
	testing.expect(t, ok && difference > f64(3.4e38) && values[0] == bigRMSE && values[1] == difference*difference/2)

	compiled.loss = MSE{}
	values = {17, 18}
	loss: f64
	loss, ok = CompiledSequentialEvaluateMany(&compiled, inputs[:], targets[:], metrics[:], values[:])
	testing.expect(t, !ok && loss == 0 && values == [2]f64{17, 18})

	// The f32 loss can underflow even though the f64 metric remains nonzero.
	tinyInputs := [2]f32{1e-30, -1e-30}
	zeroTargets := [2]f32{0, 0}
	loss, ok = CompiledSequentialEvaluateMany(&compiled, tinyInputs[:], zeroTargets[:], metrics[:], values[:])
	expected := f64(tinyInputs[0])
	testing.expect(t, ok && loss == 0 && values[0] > 0 && values[1] > 0 &&
		math.abs(values[0]-expected)/expected < 1e-15 && values[1] == expected*expected)
}

@(test)
SupervisedRMSEFailuresLeaveMetricOutputUnchanged :: proc(t: ^testing.T) {
	model: Sequential(1, 1, 2)
	compiled: CompiledSequential(1, 1, 2)
	initialized := SequentialInit(&model, 1, 7) && SequentialAddDense(&model, 1) && SequentialCompile(&compiled, &model)
	testing.expect(t, initialized)
	if !initialized { return }
	TestDenseStorage(&model.layers[0]).weightData[0] = 1
	TestDenseStorage(&model.layers[0]).biasData[0] = 0
	inputs := [3]f32{1, 2, 3}
	targets := [3]f32{0, 1, 0}
	badInputs, badTargets := inputs, targets
	badInputs[2], badTargets[2] = math.nan_f32(), math.inf_f32(1)
	model.inputData[0] = 17
	values := [2]f64{17, 18}
	metrics := [2]SupervisedMetric{.RootMeanSquaredError, .MeanSquaredError}
	duplicates := [2]SupervisedMetric{.RootMeanSquaredError, .RootMeanSquaredError}
	invalid := [2]SupervisedMetric{.RootMeanSquaredError, SupervisedMetric(SUPERVISED_METRIC_COUNT)}
	for selection in ([2][]SupervisedMetric{duplicates[:], invalid[:]}) {
		loss, ok := CompiledSequentialEvaluateMany(&compiled, inputs[:], targets[:], selection, values[:])
		testing.expect(t, !ok && loss == 0 && values == [2]f64{17, 18} && model.inputData[0] == 17)
	}
	for data in ([3]struct { inputs, targets: []f32 }{
		{badInputs[:], targets[:]}, {inputs[:], badTargets[:]}, {inputs[:], targets[:2]},
	}) {
		loss, ok := CompiledSequentialEvaluateMany(&compiled, data.inputs, data.targets, metrics[:], values[:])
		testing.expect(t, !ok && loss == 0 && values == [2]f64{17, 18} && model.inputData[0] == 17)
	}
	_, ok := CompiledSequentialEvaluateMany(&compiled, inputs[:], targets[:], metrics[:], values[:1])
	testing.expect(t, !ok && values == [2]f64{17, 18} && model.inputData[0] == 17)
	aliased := mem.slice_ptr(cast(^f64)rawptr(&inputs[0]), 1)
	before := inputs
	_, ok = CompiledSequentialEvaluateMany(&compiled, inputs[:], targets[:], metrics[:1], aliased)
	testing.expect(t, !ok && inputs == before && model.inputData[0] == 17)

	// The first minibatch succeeds but the last f32 MSE loss overflows.
	inputs[2] = 1e20
	loss, lateOk := CompiledSequentialEvaluateMany(&compiled, inputs[:], targets[:], metrics[:], values[:], 2)
	testing.expect(t, !lateOk && loss == 0 && values == [2]f64{17, 18} && model.inputData[0] == inputs[2])
	TestDenseStorage(&model.layers[0]).weightData[0] = 2
	inputs[2] = 3.4e38
	loss, lateOk = CompiledSequentialEvaluateMany(&compiled, inputs[:], targets[:], metrics[:], values[:], 2)
	testing.expect(t, !lateOk && loss == 0 && values == [2]f64{17, 18} && model.inputData[0] == inputs[2])
}

@(test)
SupervisedRMSEMultiFitHistoryMatchesEachEpoch :: proc(t: ^testing.T) {
	model, reference: Sequential(2, 2, 2)
	initialized := SequentialInit(&model, 2, 31) && SequentialAddDense(&model, 2) && SequentialAddDropout(&model, 0.2) &&
		SequentialInit(&reference, 2, 31) && SequentialAddDense(&reference, 2) && SequentialAddDropout(&reference, 0.2)
	testing.expect(t, initialized)
	if !initialized { return }
	compiled, referenceCompiled: CompiledSequential(2, 2, 2)
	initialized = SequentialCompile(&compiled, &model, MSE{}, SequentialSGD{0.03}) &&
		SequentialCompile(&referenceCompiled, &reference, MSE{}, SequentialSGD{0.03})
	testing.expect(t, initialized)
	if !initialized { return }
	inputs := [10]f32{-2, 1, -1, 0, 0, 1, 1, -1, 2, 0}
	targets := [10]f32{1, 0, 1, 0, 0, 1, 0, 1, 1, 0}
	validationInputs := [6]f32{-1.5, 0, 0.5, 1, 1.5, -1}
	validationTargets := [6]f32{1, 0, 0, 1, 1, 0}
	indices, referenceIndices: [5]int
	state, referenceState: u64 = 55, 55
	metrics := [SUPERVISED_METRIC_COUNT]SupervisedMetric{
		.RootMeanSquaredError, .BinaryAccuracyWithLogits, .MeanSquaredError,
		.CategoricalAccuracyWithLogits, .MeanAbsoluteError,
	}
	sentinel := SupervisedEpochMetric{99, 12, 34, true}
	history: [3*SUPERVISED_METRIC_COUNT+1]SupervisedEpochMetric
	for &entry in history { entry = sentinel }
	tracking := SequentialFitMetricsTracking{metrics[:], history[:]}
	options := SequentialFitOptionsDefault()
	options.epochs, options.batchSize, options.metricsMany = 3, 2, &tracking
	options.validationInputs, options.validationTargets = validationInputs[:], validationTargets[:]
	fitted: bool
	{
		context.allocator = mem.panic_allocator()
		context.temp_allocator = mem.panic_allocator()
		_, fitted = CompiledSequentialFitWithOptions(&compiled, inputs[:], targets[:], indices[:], &state, options)
	}
	testing.expect(t, fitted)
	if !fitted { return }
	for epoch in 0..<3 {
		_, fitOk := CompiledSequentialFit(&referenceCompiled, inputs[:], targets[:], referenceIndices[:], &referenceState, batchSize = 2, epochs = 1)
		trainingValues, validationValues: [SUPERVISED_METRIC_COUNT]f64
		_, trainOk := CompiledSequentialEvaluateMany(&referenceCompiled, inputs[:], targets[:], metrics[:], trainingValues[:], 2)
		_, validationOk := CompiledSequentialEvaluateMany(&referenceCompiled, validationInputs[:], validationTargets[:], metrics[:], validationValues[:], 2)
		testing.expect(t, fitOk && trainOk && validationOk)
		for index in 0..<SUPERVISED_METRIC_COUNT {
			entry := history[epoch*SUPERVISED_METRIC_COUNT+index]
			testing.expect(t, entry.epoch == epoch+1 && entry.hasValidation &&
				entry.trainingMetric == trainingValues[index] && entry.validationMetric == validationValues[index])
		}
		testing.expect(t, trainingValues[0] == math.sqrt(trainingValues[2]) && validationValues[0] == math.sqrt(validationValues[2]))
	}
	testing.expect(t, history[3*SUPERVISED_METRIC_COUNT] == sentinel && state == referenceState && model.randomState == reference.randomState)
	testing.expect(t, TestDenseStorage(&model.layers[0]).weightData == TestDenseStorage(&reference.layers[0]).weightData &&
		TestDenseStorage(&model.layers[0]).biasData == TestDenseStorage(&reference.layers[0]).biasData)
}

@(test)
SupervisedRMSESingleFitHistoryAndZeroEpochs :: proc(t: ^testing.T) {
	model, reference: Sequential(1, 1, 2)
	compiled, referenceCompiled: CompiledSequential(1, 1, 2)
	initialized := SequentialInit(&model, 1, 9) && SequentialAddDense(&model, 1) && SequentialCompile(&compiled, &model) &&
		SequentialInit(&reference, 1, 9) && SequentialAddDense(&reference, 1) && SequentialCompile(&referenceCompiled, &reference)
	testing.expect(t, initialized)
	if !initialized { return }
	inputs := [3]f32{-1, 0, 1}
	targets := [3]f32{-1, 1, 3}
	indices, referenceIndices: [3]int
	state, referenceState: u64 = 42, 42
	sentinel := SupervisedEpochMetric{99, 12, 34, true}
	history := [3]SupervisedEpochMetric{sentinel, sentinel, sentinel}
	tracking := SequentialFitMetricTracking{.RootMeanSquaredError, history[:]}
	options := SequentialFitOptionsDefault()
	options.epochs, options.batchSize, options.metrics = 0, 2, &tracking
	weights := TestDenseStorage(&model.layers[0]).weightData
	_, zeroOk := CompiledSequentialFitWithOptions(&compiled, inputs[:], targets[:], indices[:], &state, options)
	testing.expect(t, zeroOk && state == 42 && history == [3]SupervisedEpochMetric{sentinel, sentinel, sentinel} &&
		TestDenseStorage(&model.layers[0]).weightData == weights)
	options.epochs = 2
	_, fitted := CompiledSequentialFitWithOptions(&compiled, inputs[:], targets[:], indices[:], &state, options)
	testing.expect(t, fitted)
	if !fitted { return }
	for epoch in 0..<2 {
		_, fitOk := CompiledSequentialFit(&referenceCompiled, inputs[:], targets[:], referenceIndices[:], &referenceState, batchSize = 2, epochs = 1)
		evaluation, evalOk := CompiledSequentialEvaluateMetrics(&referenceCompiled, inputs[:], targets[:], .RootMeanSquaredError, 2)
		entry := history[epoch]
		testing.expect(t, fitOk && evalOk && entry.epoch == epoch+1 && !entry.hasValidation &&
			entry.validationMetric == 0 && entry.trainingMetric == evaluation.metric)
	}
	testing.expect(t, history[2] == sentinel && state == referenceState)
}

@(test)
SupervisedRMSEFitPreflightAndEarlyStopping :: proc(t: ^testing.T) {
	model: Sequential(1, 1, 2)
	compiled: CompiledSequential(1, 1, 2)
	initialized := SequentialInit(&model, 1, 9) && SequentialAddDense(&model, 1) && SequentialCompile(&compiled, &model)
	testing.expect(t, initialized)
	if !initialized { return }
	inputs := [3]f32{-1, 0, 1}
	targets := [3]f32{-1, 1, 3}
	indices := [3]int{7, 8, 9}
	state: u64 = 42
	sentinel := SupervisedEpochMetric{99, 12, 34, true}
	history := [8]SupervisedEpochMetric{sentinel, sentinel, sentinel, sentinel, sentinel, sentinel, sentinel, sentinel}
	metrics := [2]SupervisedMetric{.RootMeanSquaredError, .RootMeanSquaredError}
	tracking := SequentialFitMetricsTracking{metrics[:], history[:]}
	options := SequentialFitOptionsDefault()
	options.epochs, options.batchSize, options.metricsMany = 4, 2, &tracking
	options.validationInputs, options.validationTargets = inputs[:], targets[:]
	weights, bias := TestDenseStorage(&model.layers[0]).weightData, TestDenseStorage(&model.layers[0]).biasData
	_, ok := CompiledSequentialFitWithOptions(&compiled, inputs[:], targets[:], indices[:], &state, options)
	testing.expect(t, !ok && state == 42 && indices == [3]int{7, 8, 9} && history[0] == sentinel &&
		TestDenseStorage(&model.layers[0]).weightData == weights && TestDenseStorage(&model.layers[0]).biasData == bias)
	metrics[1] = .MeanSquaredError
	tracking.history = history[:7]
	_, ok = CompiledSequentialFitWithOptions(&compiled, inputs[:], targets[:], indices[:], &state, options)
	testing.expect(t, !ok && state == 42 && indices == [3]int{7, 8, 9} && history[0] == sentinel)

	tracking.history = history[:]
	invalidValidation := [3]f32{-1, 1, math.inf_f32(1)}
	options.validationTargets = invalidValidation[:]
	_, ok = CompiledSequentialFitWithOptions(&compiled, inputs[:], targets[:], indices[:], &state, options)
	testing.expect(t, !ok && state == 42 && indices == [3]int{7, 8, 9} && history[0] == sentinel &&
		TestDenseStorage(&model.layers[0]).weightData == weights && TestDenseStorage(&model.layers[0]).biasData == bias)
	options.validationTargets = targets[:]
	result: SequentialEarlyStoppingResult
	stopping := SequentialEarlyStopping{patience = 1, minDelta = 1e6, result = &result}
	snapshot: [1024]u8
	options.earlyStopping, options.bestSnapshot = &stopping, snapshot[:]
	_, ok = CompiledSequentialFitWithOptions(&compiled, inputs[:], targets[:], indices[:], &state, options)
	testing.expect(t, ok && result.stopped && result.bestEpoch == 1 && result.epochsRan == 2)
	if !ok { return }
	for epoch in 0..<2 {
		rmse, mse := history[epoch*2], history[epoch*2+1]
		testing.expect(t, rmse.epoch == epoch+1 && mse.epoch == epoch+1 && rmse.hasValidation && mse.hasValidation &&
			rmse.trainingMetric == math.sqrt(mse.trainingMetric) && rmse.validationMetric == math.sqrt(mse.validationMetric))
	}
	for entry in history[4:] { testing.expect(t, entry == sentinel) }
	values: [2]f64
	_, evaluated := CompiledSequentialEvaluateMany(&compiled, inputs[:], targets[:], metrics[:], values[:], 2)
	testing.expect(t, evaluated && values[0] == history[0].trainingMetric && values[1] == history[1].trainingMetric)
}
