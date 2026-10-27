package main

import "../nn"
import "core:fmt"

// Run with: odin run example/regularization.odin -file
main :: proc() {
	// Separate, caller-owned training and validation datasets.
	inputs := [8]f32{-4, -3, -2, -1, 1, 2, 3, 4}
	targets := [8]f32{-7, -5, -3, -1, 3, 5, 7, 9}
	validationInputs := [4]f32{-2.5, -0.5, 0.5, 2.5}
	validationTargets := [4]f32{-1.5, 0.5, 1.5, 3.5}
	indices: [8]int
	shuffleState: u64 = 42

	MAX_EPOCHS :: 100
	history: [MAX_EPOCHS]nn.EpochMetrics
	bestSnapshot: [1024]u8 // Caller-owned checkpoint storage on the stack.
	result: nn.SequentialEarlyStoppingResult
	stopping := nn.SequentialEarlyStopping{patience = 5, minDelta = 0.001, result = &result}

	model: nn.Sequential(1, 1, 4) // Layers, maximum width, batch capacity
	assert(nn.SequentialInit(&model, 1, seed = 42))
	assert(nn.SequentialAddDense(&model, 1))

	// L2 adds 0.1 * weight to dense weight gradients, but not bias gradients.
	loss, trained := nn.SequentialFitBatches(
		&model, inputs[:], targets[:], indices[:], &shuffleState,
		epochs = MAX_EPOCHS, optimizer = nn.SequentialSGD{0.05}, l2 = 0.1,
		validationInputs = validationInputs[:], validationTargets = validationTargets[:],
		history = history[:], earlyStopping = &stopping, bestSnapshot = bestSnapshot[:],
	)
	assert(trained)
	validationLoss, evaluated := nn.SequentialEvaluateBatches(&model, validationInputs[:], validationTargets[:], 4, nn.MSE{})
	assert(evaluated)

	fmt.println("L2 = 0.1; early stopping: patience = 5, min delta = 0.001")
	fmt.println("Post-epoch MSE (data loss only; excludes L2 penalty):")
	for metrics in history[:result.epochsRan] {
		fmt.printf("  Epoch %3d: training %.6f, validation %.6f\n", metrics.epoch, metrics.trainingLoss, metrics.validationLoss)
	}
	fmt.printf("Epochs run: %d/%d; stopped early: %v\n", result.epochsRan, MAX_EPOCHS, result.stopped)
	fmt.printf("Best monitored validation MSE: %.6f at epoch %d\n", result.bestValidationLoss, result.bestEpoch)
	fmt.printf("Restored best model: training MSE %.6f; validation MSE %.6f\n", loss, validationLoss)
	fmt.printf("Last epoch in history: training MSE %.6f; validation MSE %.6f\n", history[result.epochsRan-1].trainingLoss, history[result.epochsRan-1].validationLoss)
	fmt.println("History records the actual run; its final entry is the last epoch, not the restored best epoch.")
}
