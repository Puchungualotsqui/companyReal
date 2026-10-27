package main

import "../nn"
import "core:fmt"

// Run with: odin run example/linear_regression.odin -file
main :: proc() {
	inputs := [4]f32{-1, 0, 1, 2}
	targets := [4]f32{-1, 1, 3, 5}

	model: nn.LinearModel(1, 1, 4) // Inputs, outputs, batch capacity
	assert(nn.LinearInit(&model))
	loss, ok := nn.LinearFit(&model, inputs[:], targets[:])
	assert(ok)
	predictions, predicted := nn.LinearPredict(&model, inputs[:])
	assert(predicted)
	fmt.printf("MSE: %.6f, predictions: %v\n", loss, predictions)
}
