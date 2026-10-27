package main

import "../nn"
import "core:fmt"

// Run with: odin run example/linear_regression.odin -file
main :: proc() {
	inputs := [4]f32{-1, 0, 1, 2}
	targets := [4]f32{-1, 1, 3, 5}

	// Initialize in place and do not copy the model.
	model: nn.Sequential(1, 1, 4) // Layers, maximum width, batch capacity
	assert(nn.SequentialInit(&model, 1, seed = 42))
	assert(nn.SequentialAddDense(&model, 1))

	initialLoss, ok := nn.SequentialFit(&model, inputs[:], targets[:], epochs = 0)
	assert(ok)
	loss, trained := nn.SequentialFit(&model, inputs[:], targets[:])
	assert(trained && loss < initialLoss)
	predictions, predicted := nn.SequentialPredict(&model, inputs[:])
	assert(predicted)
	fmt.printf("MSE: %.6f -> %.6f, predictions: %v\n", initialLoss, loss, predictions)
}
