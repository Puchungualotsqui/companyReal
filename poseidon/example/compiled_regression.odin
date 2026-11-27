package main

// Run with: odin run example/compiled_regression.odin -file
import "../nn"
import "core:fmt"

main :: proc() {
	inputs := [9]f32{-4, -3, -2, -1, 0, 1, 2, 3, 4}
	targets := [9]f32{-7, -5, -3, -1, 1, 3, 5, 7, 9}

	// The owner allocates the model at its final address.
	ownedModel: nn.OwnedSequential(1, 1, 4)
	assert(nn.OwnedSequentialInit(&ownedModel, 1, seed = 42))
	defer nn.OwnedSequentialDestroy(&ownedModel)
	model := nn.OwnedSequentialModel(&ownedModel)
	assert(model != nil)
	specs := [1]nn.SequentialLayerSpec{nn.SequentialDenseSpec{1}}
	_, built := nn.SequentialAddSpecs(model, specs[:])
	assert(built)

	// Inspect the architecture and its model/Adam storage requirements.
	layers: [1]nn.SequentialLayerDetails
	summary, summarized := nn.SequentialDetails(model, layers[:])
	assert(summarized)
	fmt.printf("Model: %d layer(s), %d trainable parameters, %d inline bytes\n",
		summary.layerCount, summary.trainableParameters, summary.modelStorageBytes)
	for &layer, index in summary.layers {
		fmt.printf("  %d: %v %v -> %v, %d parameters\n", index, layer.summary.kind,
			layer.summary.input.dimensions[:layer.summary.input.rank],
			layer.summary.output.dimensions[:layer.summary.output.rank], layer.summary.parameterCount)
		switch config in layer.config {
		case nn.SequentialConv2DConfig:
			fmt.printf("     kernel %dx%d, stride %d, padding %d\n", config.kernelHeight, config.kernelWidth, config.stride, config.padding)
		case nn.SequentialPool2DConfig:
			fmt.printf("     window %dx%d, stride %d\n", config.kernelHeight, config.kernelWidth, config.stride)
		case nn.SequentialDropoutConfig:
			fmt.printf("     dropout %.2f\n", config.rate)
		case nil:
		}
	}

	// Adam allocates exactly the storage required by the built model. Its owner
	// must be destroyed before the model owner, as ensured by defer order.
	ownedAdam: nn.SequentialOwnedAdam
	assert(nn.SequentialOwnedAdamInit(model, &ownedAdam, learningRate = 0.05))
	defer nn.SequentialOwnedAdamDestroy(&ownedAdam)
	optimizer := nn.SequentialOwnedAdamOptimizer(&ownedAdam)
	assert(optimizer != nil)

	// Compile binds the loss and optimizer without moving either object.
	compiled: nn.CompiledSequential(1, 1, 4)
	assert(nn.SequentialCompile(&compiled, model, nn.MSE{}, optimizer))
	initialLoss, evaluated := nn.CompiledSequentialEvaluate(&compiled, inputs[:], targets[:])
	assert(evaluated)

	shuffleState: u64 = 42
	history: [100]nn.EpochMetrics
	metricNames := [2]nn.SupervisedMetric{.MeanAbsoluteError, .RootMeanSquaredError}
	metricHistory: [100*2]nn.SupervisedEpochMetric
	tracking := nn.SequentialFitMetricsTracking{metricNames[:], metricHistory[:]}
	options := nn.SequentialFitOptionsDefault()
	options.epochs, options.history, options.metricsMany = len(history), history[:], &tracking
	// The convenience fit allocates and frees its index scratch automatically.
	finalLoss, trained := nn.CompiledSequentialFitAuto(
		&compiled, inputs[:], targets[:], &shuffleState, options,
	)
	assert(trained)
	metricValues: [2]f64
	_, metricsOk := nn.CompiledSequentialEvaluateMany(&compiled, inputs[:], targets[:], metricNames[:], metricValues[:])
	assert(metricsOk)
	predictions: [9]f32
	assert(nn.CompiledSequentialPredict(&compiled, inputs[:], predictions[:]))
	lastEpoch := (len(history)-1)*len(metricNames)
	fmt.printf("MSE: %.6f -> %.6f; MAE: %.6f; RMSE: %.6f (epoch %d MAE: %.6f)\nPredictions: %v\n",
		initialLoss, finalLoss, metricValues[0], metricValues[1], metricHistory[lastEpoch].epoch, metricHistory[lastEpoch].trainingMetric, predictions)
}
