package main

// Run with: odin run example/compiled_regression.odin -file
import "../nn"
import "core:fmt"

main :: proc() {
	inputs := [9]f32{-4, -3, -2, -1, 0, 1, 2, 3, 4}
	targets := [9]f32{-7, -5, -3, -1, 1, 3, 5, 7, 9}

	// Models own inline storage and must be initialized at their final address.
	model: nn.Sequential(1, 1, 4)
	assert(nn.SequentialInit(&model, 1, seed = 42))
	specs := [1]nn.SequentialLayerSpec{nn.SequentialDenseSpec{1}}
	_, built := nn.SequentialAddSpecs(&model, specs[:])
	assert(built)

	// Inspect the model and determine how much optimizer storage it needs.
	layers: [1]nn.SequentialLayerSummary
	summary, summarized := nn.SequentialSummary(&model, layers[:])
	parameterCount, elementCount, requirementsOk := nn.SequentialAdamRequirements(&model)
	assert(summarized && requirementsOk)
	fmt.printf("Model: %d layer(s), %d trainable parameters\n", summary.layerCount, summary.trainableParameters)

	// The workspace stores Adam, its parameter pointers, and both moment arrays.
	workspace: nn.SequentialAdamWorkspace(2, 2)
	assert(parameterCount <= len(workspace.parameterStorage) && elementCount <= len(workspace.firstMoment))
	assert(nn.SequentialAdamWorkspaceInit(&model, &workspace, learningRate = 0.05))

	// Compile binds the loss and optimizer without allocating or moving the model.
	compiled: nn.CompiledSequential(1, 1, 4)
	assert(nn.SequentialCompile(&compiled, &model, nn.MSE{}, nn.SequentialAdamWorkspaceOptimizer(&workspace)))
	initialLoss, evaluated := nn.CompiledSequentialEvaluate(&compiled, inputs[:], targets[:])
	assert(evaluated)

	indices: [9]int
	shuffleState: u64 = 42
	history: [100]nn.EpochMetrics
	metricHistory: [100]nn.SupervisedEpochMetric
	tracking := nn.SequentialFitMetricTracking{.MeanAbsoluteError, metricHistory[:]}
	options := nn.SequentialFitOptionsDefault()
	options.epochs, options.history, options.metrics = len(history), history[:], &tracking
	finalLoss, trained := nn.CompiledSequentialFitWithOptions(
		&compiled, inputs[:], targets[:], indices[:], &shuffleState, options,
	)
	assert(trained)
	metrics, metricsOk := nn.CompiledSequentialEvaluateMetrics(&compiled, inputs[:], targets[:], .MeanAbsoluteError)
	assert(metricsOk)
	predictions: [9]f32
	assert(nn.CompiledSequentialPredict(&compiled, inputs[:], predictions[:]))
	fmt.printf("MSE: %.6f -> %.6f; MAE: %.6f (epoch %d: %.6f)\nPredictions: %v\n",
		initialLoss, finalLoss, metrics.metric, metricHistory[99].epoch, metricHistory[99].trainingMetric, predictions)
}
