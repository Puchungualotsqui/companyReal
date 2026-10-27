package main

import "../data"
import "../nn"
import "core:fmt"

// Run with: odin run example/preprocessing.odin -file
main :: proc() {
	// Row-major features and corresponding regression targets.
	inputs := [16]f32{1, 10, 2, 12, 3, 9, 4, 15, 5, 11, 6, 17, 7, 13, 8, 19}
	targets := [8]f32{3, 4.4, 4.8, 7, 7.2, 9.4, 9.6, 11.8}
	indices: [8]int
	trainIndices, validationIndices, ok := data.SplitIndices(indices[:], 6, seed = 42)
	assert(ok)

	trainInputStorage: [12]f32
	validationInputStorage: [4]f32
	trainTargetStorage: [6]f32
	validationTargetStorage: [2]f32
	trainInputs, trainInputsOk := data.GatherRows(inputs[:], trainIndices, 2, trainInputStorage[:])
	trainTargets, trainTargetsOk := data.GatherRows(targets[:], trainIndices, 1, trainTargetStorage[:])
	validationInputs, validationInputsOk := data.GatherRows(inputs[:], validationIndices, 2, validationInputStorage[:])
	validationTargets, validationTargetsOk := data.GatherRows(targets[:], validationIndices, 1, validationTargetStorage[:])
	assert(trainInputsOk && trainTargetsOk && validationInputsOk && validationTargetsOk)

	// Reuse training statistics for validation to avoid leaking held-out data.
	stats: [2]data.StandardizationStats
	assert(data.StandardizationFit(trainInputs, stats[:]))
	assert(data.StandardizationTransform(trainInputs, stats[:], trainInputs))
	assert(data.StandardizationTransform(validationInputs, stats[:], validationInputs))
	fmt.printf("Training indices: %v, validation indices: %v\n", trainIndices, validationIndices)
	for stat, feature in stats {
		fmt.printf("Feature %d: training mean %.4f, scale %.4f\n", feature, stat.mean, stat.scale)
	}

	model: nn.Sequential(1, 2, 6) // Layers, maximum width, batch capacity
	assert(nn.SequentialInit(&model, 2, seed = 42))
	assert(nn.SequentialAddDense(&model, 1))
	batchIndices: [6]int
	shuffleState: u64 = 42
	history: [100]nn.EpochMetrics
	loss, trained := nn.SequentialFitBatches(
		&model, trainInputs, trainTargets, batchIndices[:], &shuffleState,
		epochs = len(history), optimizer = nn.SequentialSGD{0.05},
		validationInputs = validationInputs, validationTargets = validationTargets, history = history[:],
	)
	assert(trained && history[len(history)-1].hasValidation)
	fmt.printf("Final training MSE: %.6f, validation MSE: %.6f\n", loss, history[len(history)-1].validationLoss)
}
