package main

import "../nn"
import "core:fmt"

// Run with: odin run example/binary_classification.odin -file
main :: proc() {
	inputs := [4]f32{-2, -1, 1, 2}
	targets := [4]f32{0, 0, 1, 1}

	// BCEWithLogits expects raw logits, not sigmoid probabilities.
	model: nn.Sequential(1, 1, 4) // Layers, maximum width, batch capacity
	assert(nn.SequentialInit(&model, 1, seed = 42))
	assert(nn.SequentialAddDense(&model, 1))

	initialLoss, ok := nn.SequentialFit(&model, inputs[:], targets[:], loss = nn.BCEWithLogits{}, epochs = 0)
	assert(ok)
	loss, trained := nn.SequentialFit(&model, inputs[:], targets[:], loss = nn.BCEWithLogits{}, epochs = 200, learningRate = 0.2)
	assert(trained && loss < initialLoss)
	logits, predicted := nn.SequentialPredict(&model, inputs[:])
	assert(predicted)

	fmt.printf("Binary cross-entropy: %.6f -> %.6f\n", initialLoss, loss)
	for logit, i in logits {
		// A zero logit corresponds to a probability of 0.5.
		class := 0
		if logit >= 0 { class = 1 }
		assert(f32(class) == targets[i])
		fmt.printf("%.0f: target %.0f, predicted %d, logit %.4f\n", inputs[i], targets[i], class, logit)
	}
}
