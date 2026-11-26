package nn

import "core:math"
import "core:mem"
import "core:testing"

@(test)
CompiledEvaluateManyMatchesSingleMetrics :: proc(t: ^testing.T) {
	model: Sequential(1, 2, 2)
	compiled: CompiledSequential(1, 2, 2)
	initialized := SequentialInit(&model, 2, 11) && SequentialAddDense(&model, 2) &&
		SequentialCompile(&compiled, &model, Huber{1})
	testing.expect(t, initialized)
	if !initialized { return }
	TestDenseStorage(&model.layers[0]).weightData = {1, 0, 0, 1}
	inputs := [10]f32{1, -2, 3, 0, -1, 4, 2, 2, 10, -4}
	targets := [10]f32{0, 0, 1, 0, -2, 1, 1, 1, 5, 0}
	metrics := [2]SupervisedMetric{.MeanSquaredError, .MeanAbsoluteError}
	for batch in ([3]int{0, 1, 2}) {
		values: [2]f64
		loss: f64
		ok: bool
		{
			context.allocator = mem.panic_allocator()
			context.temp_allocator = mem.panic_allocator()
			loss, ok = CompiledSequentialEvaluateMany(&compiled, inputs[:], targets[:], metrics[:], values[:], batch)
		}
		first, firstOk := CompiledSequentialEvaluateMetrics(&compiled, inputs[:], targets[:], metrics[0], batch)
		second, secondOk := CompiledSequentialEvaluateMetrics(&compiled, inputs[:], targets[:], metrics[1], batch)
		testing.expect(t, ok && firstOk && secondOk && loss == first.dataLoss && loss == second.dataLoss)
		testing.expect(t, values[0] == first.metric && values[1] == second.metric && values == [2]f64{6.2, 2})
	}
}

@(test)
CompiledEvaluateManyClassification :: proc(t: ^testing.T) {
	model: Sequential(1, 2, 2)
	compiled: CompiledSequential(1, 2, 2)
	initialized := SequentialInit(&model, 2, 5) && SequentialAddDense(&model, 2) &&
		SequentialCompile(&compiled, &model, CCEWithLogits{})
	testing.expect(t, initialized)
	if !initialized { return }
	TestDenseStorage(&model.layers[0]).weightData = {1, 0, 0, 1}
	inputs := [6]f32{2, -1, -1, 2, 1, 2}
	targets := [6]f32{1, 0, 0, 1, 1, 0}
	metrics := [4]SupervisedMetric{.CategoricalAccuracyWithLogits, .MeanAbsoluteError, .BinaryAccuracyWithLogits, .MeanSquaredError}
	values: [4]f64
	loss, ok := CompiledSequentialEvaluateMany(&compiled, inputs[:], targets[:], metrics[:], values[:])
	testing.expect(t, ok && values[0] == f64(2)/3)
	for metric, index in metrics {
		separate, separateOk := CompiledSequentialEvaluateMetrics(&compiled, inputs[:], targets[:], metric)
		testing.expect(t, separateOk && loss == separate.dataLoss && values[index] == separate.metric)
	}
}

@(test)
CompiledEvaluateManyFailuresDoNotWriteOutput :: proc(t: ^testing.T) {
	model: Sequential(1, 1, 2)
	compiled: CompiledSequential(1, 1, 2)
	initialized := SequentialInit(&model, 1, 7) && SequentialAddDense(&model, 1) && SequentialCompile(&compiled, &model)
	testing.expect(t, initialized)
	if !initialized { return }
	inputs := [3]f32{1, 2, 3}
	targets := [3]f32{0, 1, 0.5}
	values := [2]f64{17, 18}
	metrics := [2]SupervisedMetric{.MeanAbsoluteError, .MeanSquaredError}
	badMetrics := [2]SupervisedMetric{.MeanAbsoluteError, SupervisedMetric(99)}
	_, ok := CompiledSequentialEvaluateMany(&compiled, inputs[:], targets[:], badMetrics[:], values[:])
	testing.expect(t, !ok && values == [2]f64{17, 18})
	duplicate := [2]SupervisedMetric{.MeanAbsoluteError, .MeanAbsoluteError}
	_, ok = CompiledSequentialEvaluateMany(&compiled, inputs[:], targets[:], duplicate[:], values[:])
	testing.expect(t, !ok && values == [2]f64{17, 18})
	_, ok = CompiledSequentialEvaluateMany(&compiled, inputs[:], targets[:], metrics[:], values[:1])
	testing.expect(t, !ok && values == [2]f64{17, 18})
	_, ok = CompiledSequentialEvaluateMany(&compiled, inputs[:], targets[:], nil, nil)
	testing.expect(t, !ok)
	binary := [2]SupervisedMetric{.MeanAbsoluteError, .BinaryAccuracyWithLogits}
	_, ok = CompiledSequentialEvaluateMany(&compiled, inputs[:], targets[:], binary[:], values[:])
	testing.expect(t, !ok && values == [2]f64{17, 18})

	// A later forward can fail numerically, but the caller's output is atomic.
	TestDenseStorage(&model.layers[0]).weightData[0] = 2
	inputs[2] = 3.4e38
	_, ok = CompiledSequentialEvaluateMany(&compiled, inputs[:], targets[:], metrics[:], values[:])
	testing.expect(t, !ok && values == [2]f64{17, 18})
	inputs[2] = 3
	// Output aliases a read-only input; validation rejects it before inference.
	aliased := mem.slice_ptr(cast(^f64)rawptr(&inputs[0]), 1)
	only := [1]SupervisedMetric{.MeanAbsoluteError}
	before := inputs
	_, ok = CompiledSequentialEvaluateMany(&compiled, inputs[:], targets[:], only[:], aliased)
	testing.expect(t, !ok && inputs == before)
}

@(test)
CompiledFitManyMetricsMatchPerEpochEvaluation :: proc(t: ^testing.T) {
	model, reference: Sequential(2, 1, 2)
	initialized := SequentialInit(&model, 1, 31) && SequentialAddDense(&model, 1) && SequentialAddDropout(&model, 0.2) &&
		SequentialInit(&reference, 1, 31) && SequentialAddDense(&reference, 1) && SequentialAddDropout(&reference, 0.2)
	testing.expect(t, initialized)
	if !initialized { return }
	compiled, referenceCompiled: CompiledSequential(2, 1, 2)
	initialized = SequentialCompile(&compiled, &model, BCEWithLogits{}, SequentialSGD{0.03}) &&
		SequentialCompile(&referenceCompiled, &reference, BCEWithLogits{}, SequentialSGD{0.03})
	testing.expect(t, initialized)
	if !initialized { return }
	inputs := [5]f32{-2, -1, 0, 1, 2}
	targets := [5]f32{0, 0, 1, 1, 1}
	validationInputs := [3]f32{-1.5, 0.5, 1.5}
	validationTargets := [3]f32{0, 1, 1}
	indices, referenceIndices: [5]int
	state, referenceState: u64 = 55, 55
	lossHistory: [3]EpochMetrics
	metricHistory: [6]SupervisedEpochMetric
	metrics := [2]SupervisedMetric{.BinaryAccuracyWithLogits, .MeanAbsoluteError}
	tracking := SequentialFitMetricsTracking{metrics[:], metricHistory[:]}
	options := SequentialFitOptionsDefault()
	options.epochs, options.batchSize = 3, 2
	options.validationInputs, options.validationTargets = validationInputs[:], validationTargets[:]
	options.history, options.metricsMany = lossHistory[:], &tracking
	loss, fitted := CompiledSequentialFitWithOptions(&compiled, inputs[:], targets[:], indices[:], &state, options)
	testing.expect(t, fitted)
	if !fitted { return }
	for epoch in 0..<3 {
		referenceLoss, fitOk := CompiledSequentialFit(&referenceCompiled, inputs[:], targets[:], referenceIndices[:], &referenceState, batchSize = 2, epochs = 1)
		trainingValues, validationValues: [2]f64
		trainLoss, trainOk := CompiledSequentialEvaluateMany(&referenceCompiled, inputs[:], targets[:], metrics[:], trainingValues[:], 2)
		validationLoss, validationOk := CompiledSequentialEvaluateMany(&referenceCompiled, validationInputs[:], validationTargets[:], metrics[:], validationValues[:], 2)
		testing.expect(t, fitOk && trainOk && validationOk && referenceLoss == f32(trainLoss))
		testing.expect(t, lossHistory[epoch].trainingLoss == f32(trainLoss) && lossHistory[epoch].validationLoss == f32(validationLoss))
		for index in 0..<2 {
			entry := metricHistory[epoch*2+index]
			testing.expect(t, entry.epoch == epoch+1 && entry.hasValidation && entry.trainingMetric == trainingValues[index] && entry.validationMetric == validationValues[index])
		}
	}
	testing.expect(t, loss == lossHistory[2].trainingLoss && state == referenceState && model.randomState == reference.randomState)
	testing.expect(t, TestDenseStorage(&model.layers[0]).weightData == TestDenseStorage(&reference.layers[0]).weightData)
}

@(test)
CompiledFitManyMetricsWithoutValidation :: proc(t: ^testing.T) {
	model: Sequential(1, 1, 2)
	compiled: CompiledSequential(1, 1, 2)
	initialized := SequentialInit(&model, 1, 7) && SequentialAddDense(&model, 1) && SequentialCompile(&compiled, &model)
	testing.expect(t, initialized)
	if !initialized { return }
	inputs := [3]f32{0, 1, 2}
	targets := [3]f32{1, 0, 1}
	metrics := [2]SupervisedMetric{.MeanSquaredError, .MeanAbsoluteError}
	history: [4]SupervisedEpochMetric
	tracking := SequentialFitMetricsTracking{metrics[:], history[:]}
	options := SequentialFitOptionsDefault()
	options.epochs, options.metricsMany = 2, &tracking
	indices: [3]int
	state: u64 = 7
	_, ok := CompiledSequentialFitWithOptions(&compiled, inputs[:], targets[:], indices[:], &state, options)
	values: [2]f64
	_, evaluated := CompiledSequentialEvaluateMany(&compiled, inputs[:], targets[:], metrics[:], values[:])
	testing.expect(t, ok && evaluated)
	for entry, index in history {
		testing.expect(t, entry.epoch == index/2+1 && !entry.hasValidation && entry.validationMetric == 0)
	}
	testing.expect(t, history[2].trainingMetric == values[0] && history[3].trainingMetric == values[1])
}

@(test)
CompiledFitManyMetricsFailureAndEarlyStop :: proc(t: ^testing.T) {
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
	metrics := [2]SupervisedMetric{.MeanAbsoluteError, .MeanSquaredError}
	tracking := SequentialFitMetricsTracking{metrics[:], history[:]}
	options := SequentialFitOptionsDefault()
	options.epochs, options.metricsMany = 4, &tracking
	options.validationInputs, options.validationTargets = inputs[:], targets[:]
	weights := TestDenseStorage(&model.layers[0]).weightData
	tracking.history = history[:7]
	_, ok := CompiledSequentialFitWithOptions(&compiled, inputs[:], targets[:], indices[:], &state, options)
	testing.expect(t, !ok && state == 42 && indices == [3]int{7, 8, 9} && history[0] == sentinel && TestDenseStorage(&model.layers[0]).weightData == weights)
	tracking.history = history[:]
	metrics[1] = metrics[0]
	_, ok = CompiledSequentialFitWithOptions(&compiled, inputs[:], targets[:], indices[:], &state, options)
	testing.expect(t, !ok && state == 42 && history[0] == sentinel)
	metrics[1] = .MeanSquaredError
	singleHistory: [4]SupervisedEpochMetric
	single := SequentialFitMetricTracking{.MeanAbsoluteError, singleHistory[:]}
	options.metrics = &single
	_, ok = CompiledSequentialFitWithOptions(&compiled, inputs[:], targets[:], indices[:], &state, options)
	testing.expect(t, !ok && state == 42 && history[0] == sentinel)
	options.metrics = nil
	options.epochs = 0
	tracking.history = nil
	_, ok = CompiledSequentialFitWithOptions(&compiled, inputs[:], targets[:], indices[:], &state, options)
	testing.expect(t, ok && state == 42 && history[0] == sentinel)

	tracking.history = history[:]
	result: SequentialEarlyStoppingResult
	stopping := SequentialEarlyStopping{patience = 1, minDelta = 1e6, result = &result}
	snapshot: [1024]u8
	options.epochs, options.earlyStopping, options.bestSnapshot = 4, &stopping, snapshot[:]
	_, ok = CompiledSequentialFitWithOptions(&compiled, inputs[:], targets[:], indices[:], &state, options)
	testing.expect(t, ok && result.stopped && result.bestEpoch == 1 && result.epochsRan == 2)
	for i in 0..<4 { testing.expect(t, history[i].epoch == i/2+1 && history[i].hasValidation) }
	for i in 4..<8 { testing.expect(t, history[i] == sentinel) }
	values: [2]f64
	_, ok = CompiledSequentialEvaluateMany(&compiled, inputs[:], targets[:], metrics[:], values[:])
	testing.expect(t, ok && math.abs(values[0]-history[0].trainingMetric) < 1e-12 && math.abs(values[1]-history[1].trainingMetric) < 1e-12)
}
