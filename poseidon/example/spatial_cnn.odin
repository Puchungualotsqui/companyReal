package main

import "../core"
import "../nn"
import "core:fmt"

// Run with: odin run example/spatial_cnn.odin -file
main :: proc() {
	// Four 4x4 grayscale images in NHWC order, with one-hot class labels.
	// Class 0 is bright on the left; class 1 is bright on the right.
	images := [64]f32{
		1, 0, 0, 0,  1, 0, 0, 0,  1, 0, 0, 0,  1, 0, 0, 0,
		0, 0.8, 0, 0,  0, 1, 0, 0,  0, 0.8, 0, 0,  0, 1, 0, 0,
		0, 0, 0, 1,  0, 0, 0, 1,  0, 0, 0, 1,  0, 0, 0, 1,
		0, 0, 0.8, 0,  0, 0, 1, 0,  0, 0, 0.8, 0,  0, 0, 1, 0,
	}
	targets := [8]f32{1, 0, 1, 0, 0, 1, 0, 1}
	indices: [4]int
	shuffleState: u64 = 42

	// maxWidth bounds elements per sample, including intermediate outputs.
	// Initialize inline storage in place and do not copy the initialized model.
	model: nn.Sequential(5, 32, 2) // Layers, maximum width, batch capacity
	assert(nn.SequentialInitSpatial(&model, 4, 4, 1, seed = 42))
	assert(nn.SequentialAddConv2D(&model, 1, 1, 2)) // 4x4x2 output
	assert(nn.SequentialAddActivation(&model, .Relu))
	assert(nn.SequentialAddPool2D(&model, .Max, 2, 2, 2)) // 2x2x2 output
	assert(nn.SequentialAddFlatten(&model))
	assert(nn.SequentialAddDense(&model, 2)) // Raw class logits, not softmax

	// Adam retains the caller-owned parameter list and moments. There are
	// 2 convolution weights + 2 biases + 16 dense weights + 2 biases.
	parameterStorage: [4]^core.Node
	parameters, ok := nn.SequentialParameters(&model, parameterStorage[:])
	assert(ok)
	firstMoment, secondMoment: [22]f32
	optimizer: nn.Adam
	assert(nn.AdamInit(&optimizer, parameters, firstMoment[:], secondMoment[:], learningRate = 0.05))

	initialLoss, evaluated := nn.SequentialFitBatches(&model, images[:], targets[:], indices[:], &shuffleState, loss = nn.CCEWithLogits{}, epochs = 0, optimizer = &optimizer)
	assert(evaluated)
	loss, trained := nn.SequentialFitBatches(&model, images[:], targets[:], indices[:], &shuffleState, loss = nn.CCEWithLogits{}, epochs = 200, optimizer = &optimizer)
	fmt.printf("CCE loss: %.6f -> %.6f\n", initialLoss, loss)
	assert(trained && loss < initialLoss && loss < 0.01)

	// Prediction is limited to batch capacity; its result is borrowed until
	// the next prediction or fit. Argmax of logits gives the predicted class.
	correct := 0
	for start := 0; start < 4; start += 2 {
		logits, predicted := nn.SequentialPredict(&model, images[start*16:(start+2)*16])
		assert(predicted)
		for i in 0..<2 {
			class := 0
			if logits[2*i+1] > logits[2*i] { class = 1 }
			expected := 0
			if targets[2*(start+i)+1] == 1 { expected = 1 }
			if class == expected { correct += 1 }
			fmt.printf("image %d: class %d (expected %d), logits [%.4f, %.4f]\n", start+i, class, expected, logits[2*i], logits[2*i+1])
		}
	}
	fmt.printf("training accuracy: %d/4\n", correct)
	assert(correct == 4)
}
