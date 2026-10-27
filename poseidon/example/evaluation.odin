package main

import "../core"
import "../nn"
import "core:fmt"

// Run with: odin run example/evaluation.odin -file
main :: proc() {
	inputs := [8]f32{-4, -3, -2, -1, 1, 2, 3, 4}
	targets := [8]f32{0, 0, 0, 0, 1, 1, 1, 1}
	validationInputs := [4]f32{-2.5, -0.5, 0.5, 2.5}
	validationTargets := [4]f32{0, 0, 1, 1}
	indices: [8]int
	shuffleState: u64 = 42
	history: [20]nn.EpochMetrics

	model: nn.Sequential(1, 1, 4) // Layers, maximum width, batch capacity
	assert(nn.SequentialInit(&model, 1, seed = 42))
	assert(nn.SequentialAddDense(&model, 1)) // Output logits, not probabilities.

	loss, trained := nn.SequentialFitBatches(
		&model, inputs[:], targets[:], indices[:], &shuffleState,
		loss = nn.BCEWithLogits{}, epochs = len(history), optimizer = nn.SequentialSGD{0.2},
		validationInputs = validationInputs[:], validationTargets = validationTargets[:], history = history[:],
	)
	assert(trained)
	for metrics in history {
		assert(metrics.hasValidation)
		fmt.printf("Epoch %d: training loss %.6f, validation loss %.6f\n", metrics.epoch, metrics.trainingLoss, metrics.validationLoss)
	}
	fmt.printf("Final training loss: %.6f\n", loss)

	// Prediction is borrowed and valid until the next prediction or fit.
	logits, predicted := nn.SequentialPredict(&model, validationInputs[:])
	assert(predicted)
	shape := [2]int{len(validationInputs), 1}
	accuracy, valid := nn.BinaryAccuracyWithLogits(core.Tensor{shape[:], logits}, core.Tensor{shape[:], validationTargets[:]})
	assert(valid)
	fmt.printf("Final validation accuracy: %.2f%%\n", accuracy * 100)
}
