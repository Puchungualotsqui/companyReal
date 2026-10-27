package main

import "../nn"
import "core:fmt"

// Run with: odin run example/dropout.odin -file
main :: proc() {
	// Four supervised examples, each with two inputs and one target.
	inputs := [8]f32{0, 0, 0, 1, 1, 0, 1, 1}
	targets := [4]f32{0, 1, 1, 2}

	// All model and data storage is caller-owned; initialize models in place
	// and do not copy them, since their layers contain self-pointers.
	model, replica: nn.Sequential(4, 4, 4) // Layers, maximum width, batch capacity
	assert(nn.SequentialInit(&model, 2, seed = 42))
	assert(nn.SequentialInit(&replica, 2, seed = 42))
	models := [2]^nn.Sequential(4, 4, 4){&model, &replica}
	for current in models {
		assert(nn.SequentialAddDense(current, 4))
		assert(nn.SequentialAddActivation(current, .Tanh))
		assert(nn.SequentialAddDropout(current, rate = 0.2))
		assert(nn.SequentialAddDense(current, 1))
	}

	// Fit uses dropout during training. The seed controls initialization and
	// dropout masks, so the same data and training steps reproduce the result.
	initialLoss, ok := nn.SequentialFit(&model, inputs[:], targets[:], epochs = 0)
	assert(ok)
	loss, trained := nn.SequentialFit(&model, inputs[:], targets[:], epochs = 1000, learningRate = 0.05)
	assert(trained)
	replicaLoss, replicaTrained := nn.SequentialFit(&replica, inputs[:], targets[:], epochs = 1000, learningRate = 0.05)
	assert(replicaTrained && loss == replicaLoss)

	// Predict disables dropout. Its output is borrowed until the next model
	// operation, so save it in caller-owned storage before predicting again.
	predictions, predicted := nn.SequentialPredict(&model, inputs[:])
	assert(predicted)
	snapshot: [4]f32
	copy(snapshot[:], predictions)
	predictions, predicted = nn.SequentialPredict(&model, inputs[:])
	assert(predicted)
	replicaPredictions, replicaPredicted := nn.SequentialPredict(&replica, inputs[:])
	assert(replicaPredicted)
	for value, i in predictions {
		assert(value == snapshot[i] && value == replicaPredictions[i])
	}

	fmt.printf("MSE: %.6f -> %.6f\n", initialLoss, loss)
	fmt.println("Repeated inference and seeded training produce identical predictions:")
	for value, i in snapshot {
		fmt.printf("%.0f + %.0f: target %.0f, prediction %.4f\n", inputs[2*i], inputs[2*i+1], targets[i], value)
	}
}
