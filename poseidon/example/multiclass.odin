package main

import "../nn"
import "core:fmt"

// Run with: odin run example/multiclass.odin -file
main :: proc() {
	// Six rows of two inputs and three one-hot target classes.
	inputs := [12]f32{2, 0, 3, 1, 0, 2, 1, 3, -2, -2, -3, -1}
	targets := [18]f32{
		1, 0, 0,
		1, 0, 0,
		0, 1, 0,
		0, 1, 0,
		0, 0, 1,
		0, 0, 1,
	}

	// The dense layer outputs logits; CCEWithLogits applies softmax in the loss.
	model: nn.Sequential(1, 3, 6) // Layers, maximum width, batch capacity
	assert(nn.SequentialInit(&model, 2, seed = 42))
	assert(nn.SequentialAddDense(&model, 3))

	initialLoss, ok := nn.SequentialFit(&model, inputs[:], targets[:], loss = nn.CCEWithLogits{}, epochs = 0)
	assert(ok)
	loss, trained := nn.SequentialFit(&model, inputs[:], targets[:], loss = nn.CCEWithLogits{}, epochs = 500, learningRate = 0.1)
	assert(trained && loss < initialLoss)
	logits, predicted := nn.SequentialPredict(&model, inputs[:])
	assert(predicted)

	fmt.printf("Categorical cross-entropy: %.6f -> %.6f\n", initialLoss, loss)
	for row in 0..<6 {
		// Softmax preserves the ordering of logits, so argmax gives the class.
		class := 0
		for candidate in 1..<3 {
			if logits[row*3+candidate] > logits[row*3+class] { class = candidate }
		}
		assert(targets[row*3+class] == 1)
		fmt.printf("(%.0f, %.0f): target %d, predicted %d, logits %v\n", inputs[row*2], inputs[row*2+1], row / 2, class, logits[row*3:row*3+3])
	}
}
