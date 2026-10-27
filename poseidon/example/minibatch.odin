package main

import "../core"
import "../nn"
import "core:fmt"

// Run with: odin run example/minibatch.odin -file
main :: proc() {
	// Nine rows exceed the model's four-row batch capacity.
	inputs := [9]f32{-4, -3, -2, -1, 0, 1, 2, 3, 4}
	targets := [9]f32{-7, -5, -3, -1, 1, 3, 5, 7, 9}
	indices: [9]int
	shuffleState: u64 = 42

	model: nn.Sequential(1, 1, 4) // Layers, maximum width, batch capacity
	assert(nn.SequentialInit(&model, 1, seed = 42))
	assert(nn.SequentialAddDense(&model, 1))

	// Storage must outlive the optimizer; moments follow parameter element order.
	parameterStorage: [2]^core.Node
	parameters, ok := nn.SequentialParameters(&model, parameterStorage[:])
	assert(ok)
	firstMoment, secondMoment: [2]f32
	adam: nn.Adam
	assert(nn.AdamInit(&adam, parameters, firstMoment[:], secondMoment[:], learningRate = 0.05))

	// Default batchSize uses capacity, default loss is MSE, and shuffle defaults to true.
	initialLoss, evaluated := nn.SequentialFitBatches(&model, inputs[:], targets[:], indices[:], &shuffleState, epochs = 0, optimizer = &adam)
	assert(evaluated)
	for pass in 1..=2 {
		loss, trained := nn.SequentialFitBatches(&model, inputs[:], targets[:], indices[:], &shuffleState, epochs = 100, optimizer = &adam)
		assert(trained)
		fmt.printf("Pass %d: MSE %.6f (Adam step %d)\n", pass, loss, adam.step)
	}
	fmt.printf("Initial MSE: %.6f\n", initialLoss)

	// Prediction accepts at most one batch at a time.
	predictions, predicted := nn.SequentialPredict(&model, inputs[:4])
	assert(predicted)
	fmt.printf("First batch predictions: %v\n", predictions)
}
