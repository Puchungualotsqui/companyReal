package main

import "../nn"
import "core:fmt"

// Run with: odin run example/xor.odin -file
main :: proc() {
	// Four rows of two inputs, with one target per row.
	inputs := [8]f32{0, 0, 0, 1, 1, 0, 1, 1}
	targets := [4]f32{0, 1, 1, 0}

	// Layer capacity includes activations; all model storage is inline.
	// Initialize in place and do not copy the initialized model.
	model: nn.Sequential(3, 4, 4) // Layers, maximum width, batch capacity
	assert(nn.SequentialInit(&model, 2, seed = 42))
	assert(nn.SequentialAddDense(&model, 4))
	assert(nn.SequentialAddActivation(&model, .Tanh))
	assert(nn.SequentialAddDense(&model, 1))

	// Defaults are MSE and a 0.1 learning rate. Zero epochs measures the initial loss.
	initialLoss, ok := nn.SequentialFit(&model, inputs[:], targets[:], epochs = 0)
	assert(ok)
	loss, trained := nn.SequentialFit(&model, inputs[:], targets[:], epochs = 5000)
	assert(trained)
	predictions, predicted := nn.SequentialPredict(&model, inputs[:])
	assert(predicted)

	fmt.printf("MSE: %.6f -> %.6f\n", initialLoss, loss)
	for i in 0..<len(targets) {
		fmt.printf("%.0f XOR %.0f: target %.0f, prediction %.4f\n", inputs[2*i], inputs[2*i+1], targets[i], predictions[i])
	}
}
