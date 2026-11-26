package nn

import "core:testing"

@(test)
CompiledFitMetricsMatchSeparateEpochEvaluation :: proc(t: ^testing.T) {
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
	metricHistory: [3]SupervisedEpochMetric
	tracking := SequentialFitMetricTracking{.BinaryAccuracyWithLogits, metricHistory[:]}
	options := SequentialFitOptionsDefault()
	options.epochs, options.batchSize = 3, 2
	options.validationInputs, options.validationTargets = validationInputs[:], validationTargets[:]
	options.history, options.metrics = lossHistory[:], &tracking
	loss, fitted := CompiledSequentialFitWithOptions(&compiled, inputs[:], targets[:], indices[:], &state, options)
	testing.expect(t, fitted)
	if !fitted { return }
	for epoch in 0..<3 {
		referenceLoss, fitOk := CompiledSequentialFit(&referenceCompiled, inputs[:], targets[:], referenceIndices[:], &referenceState, batchSize = 2, epochs = 1)
		train, trainOk := CompiledSequentialEvaluateMetrics(&referenceCompiled, inputs[:], targets[:], .BinaryAccuracyWithLogits, 2)
		validation, validationOk := CompiledSequentialEvaluateMetrics(&referenceCompiled, validationInputs[:], validationTargets[:], .BinaryAccuracyWithLogits, 2)
		testing.expect(t, fitOk && trainOk && validationOk)
		testing.expect(t, lossHistory[epoch].epoch == epoch+1 && lossHistory[epoch].hasValidation)
		testing.expect(t, lossHistory[epoch].trainingLoss == f32(train.dataLoss) && lossHistory[epoch].validationLoss == f32(validation.dataLoss))
		testing.expect(t, referenceLoss == f32(train.dataLoss))
		testing.expect(t, metricHistory[epoch].epoch == epoch+1 && metricHistory[epoch].hasValidation)
		testing.expect(t, metricHistory[epoch].trainingMetric == train.metric && metricHistory[epoch].validationMetric == validation.metric)
	}
	testing.expect(t, loss == lossHistory[2].trainingLoss && state == referenceState && model.randomState == reference.randomState)
	testing.expect(t, TestDenseStorage(&model.layers[0]).weightData == TestDenseStorage(&reference.layers[0]).weightData)
	testing.expect(t, TestDenseStorage(&model.layers[0]).biasData == TestDenseStorage(&reference.layers[0]).biasData)
}

@(test)
CompiledFitCategoricalMetricsWithoutValidation :: proc(t: ^testing.T) {
	model: Sequential(1, 2, 2)
	compiled: CompiledSequential(1, 2, 2)
	initialized := SequentialInit(&model, 1, 23) && SequentialAddDense(&model, 2) &&
		SequentialCompile(&compiled, &model, CCEWithLogits{}, SequentialSGD{0.03})
	testing.expect(t, initialized)
	if !initialized { return }
	inputs := [3]f32{-1, 0, 1}
	targets := [6]f32{1, 0, 0, 1, 0, 1}
	indices: [3]int
	state: u64 = 7
	metrics: [2]SupervisedEpochMetric
	tracking := SequentialFitMetricTracking{.CategoricalAccuracyWithLogits, metrics[:]}
	options := SequentialFitOptionsDefault()
	options.epochs, options.metrics = 2, &tracking
	_, fitted := CompiledSequentialFitWithOptions(&compiled, inputs[:], targets[:], indices[:], &state, options)
	evaluation, evaluated := CompiledSequentialEvaluateMetrics(&compiled, inputs[:], targets[:], .CategoricalAccuracyWithLogits)
	testing.expect(t, fitted && evaluated && metrics[0].epoch == 1 && metrics[1].epoch == 2)
	testing.expect(t, !metrics[0].hasValidation && !metrics[1].hasValidation && metrics[1].validationMetric == 0)
	testing.expect(t, metrics[1].trainingMetric == evaluation.metric)
}

@(test)
CompiledFitMetricsEarlyStopAndBestRestore :: proc(t: ^testing.T) {
	model: Sequential(1, 1, 2)
	compiled: CompiledSequential(1, 1, 2)
	initialized := SequentialInit(&model, 1, 9) && SequentialAddDense(&model, 1) && SequentialCompile(&compiled, &model)
	testing.expect(t, initialized)
	if !initialized { return }
	inputs := [3]f32{-1, 0, 1}
	targets := [3]f32{-1, 1, 3}
	indices: [3]int
	state: u64 = 42
	result: SequentialEarlyStoppingResult
	stopping := SequentialEarlyStopping{patience = 1, minDelta = 1e6, result = &result}
	sentinel := SupervisedEpochMetric{99, 12, 34, true}
	metrics := [4]SupervisedEpochMetric{sentinel, sentinel, sentinel, sentinel}
	tracking := SequentialFitMetricTracking{.MeanAbsoluteError, metrics[:]}
	snapshot: [1024]u8
	options := SequentialFitOptionsDefault()
	options.epochs, options.metrics = 4, &tracking
	options.validationInputs, options.validationTargets = inputs[:], targets[:]
	options.earlyStopping, options.bestSnapshot = &stopping, snapshot[:]
	_, fitted := CompiledSequentialFitWithOptions(&compiled, inputs[:], targets[:], indices[:], &state, options)
	testing.expect(t, fitted && result.stopped && result.bestEpoch == 1 && result.epochsRan == 2)
	testing.expect(t, metrics[0].epoch == 1 && metrics[1].epoch == 2 && metrics[0].hasValidation && metrics[1].hasValidation)
	testing.expect(t, metrics[2] == sentinel && metrics[3] == sentinel)
	evaluation, evaluated := CompiledSequentialEvaluateMetrics(&compiled, inputs[:], targets[:], .MeanAbsoluteError)
	testing.expect(t, evaluated && evaluation.metric == metrics[0].trainingMetric && metrics[0].trainingMetric == metrics[0].validationMetric)
}

@(test)
CompiledFitMetricsRejectInvalidBeforeTraining :: proc(t: ^testing.T) {
	model: Sequential(1, 1, 2)
	compiled: CompiledSequential(1, 1, 2)
	initialized := SequentialInit(&model, 1, 7) && SequentialAddDense(&model, 1) && SequentialCompile(&compiled, &model)
	testing.expect(t, initialized)
	if !initialized { return }
	inputs := [3]f32{0, 1, 2}
	targets := [3]f32{0, 0.5, 1}
	indices := [3]int{7, 8, 9}
	state: u64 = 42
	sentinel := SupervisedEpochMetric{99, 12, 34, true}
	metrics := [2]SupervisedEpochMetric{sentinel, sentinel}
	tracking := SequentialFitMetricTracking{.BinaryAccuracyWithLogits, metrics[:]}
	options := SequentialFitOptionsDefault()
	options.epochs, options.metrics = 2, &tracking
	weights, bias := TestDenseStorage(&model.layers[0]).weightData, TestDenseStorage(&model.layers[0]).biasData
	_, ok := CompiledSequentialFitWithOptions(&compiled, inputs[:], targets[:], indices[:], &state, options)
	testing.expect(t, !ok && state == 42 && indices == [3]int{7, 8, 9} && metrics == [2]SupervisedEpochMetric{sentinel, sentinel})
	testing.expect(t, TestDenseStorage(&model.layers[0]).weightData == weights && TestDenseStorage(&model.layers[0]).biasData == bias)
	targets[1] = 1
	tracking.metric = SupervisedMetric(99)
	_, ok = CompiledSequentialFitWithOptions(&compiled, inputs[:], targets[:], indices[:], &state, options)
	testing.expect(t, !ok && state == 42 && metrics == [2]SupervisedEpochMetric{sentinel, sentinel})
	tracking.metric, tracking.history = .MeanAbsoluteError, metrics[:1]
	_, ok = CompiledSequentialFitWithOptions(&compiled, inputs[:], targets[:], indices[:], &state, options)
	testing.expect(t, !ok && state == 42 && metrics == [2]SupervisedEpochMetric{sentinel, sentinel})
	options.epochs = 0
	tracking.history = nil
	loss: f32
	loss, ok = CompiledSequentialFitWithOptions(&compiled, inputs[:], targets[:], indices[:], &state, options)
	evaluated, evaluationOk := CompiledSequentialEvaluate(&compiled, inputs[:], targets[:])
	testing.expect(t, ok && evaluationOk && loss == evaluated && state == 42)
	testing.expect(t, metrics == [2]SupervisedEpochMetric{sentinel, sentinel})
}
