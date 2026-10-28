package main

import "../core"
import "../nn"
import "core:fmt"

// Run with: odin run example/conv2d.odin -file
main :: proc() {
	// Four 2x2 grayscale images: class 0 has a bright left column,
	// class 1 a bright right column. Input and output use NHWC layout.
	inputShape := [4]int{4, 2, 2, 1}
	weightShape := [4]int{2, 2, 1, 2}
	biasShape := [1]int{2}
	outputShape := [4]int{4, 1, 1, 2}
	images := [16]f32{
		1, 0, 1, 0,
		0.8, 0.1, 1, 0,
		0, 1, 0, 1,
		0.1, 0.8, 0, 1,
	}
	targets := [8]f32{1, 0, 1, 0, 0, 1, 0, 1}
	weights: [8]f32
	bias: [2]f32
	logits: [8]f32
	inputGrad: [16]f32
	weightGrad, logitsGrad: [8]f32
	biasGrad: [2]f32

	inputNode := core.Node{value = core.Tensor{inputShape[:], images[:]}, grad = core.Tensor{inputShape[:], inputGrad[:]}}
	weightNode := core.Node{value = core.Tensor{weightShape[:], weights[:]}, grad = core.Tensor{weightShape[:], weightGrad[:]}}
	biasNode := core.Node{value = core.Tensor{biasShape[:], bias[:]}, grad = core.Tensor{biasShape[:], biasGrad[:]}}
	logitsNode := core.Node{value = core.Tensor{outputShape[:], logits[:]}, grad = core.Tensor{outputShape[:], logitsGrad[:]}}
	conv := nn.Conv2D{input = &inputNode, weights = &weightNode, bias = &biasNode, output = &logitsNode, stride = 1}
	target := core.Tensor{outputShape[:], targets[:]}
	parameters := [2]^core.Node{&weightNode, &biasNode}
	nodes := [4]^core.Node{&inputNode, &weightNode, &biasNode, &logitsNode}
	optimizer := nn.SGD{parameters[:], 0.2}

	assert(nn.Conv2DForward(&conv))
	initialLoss, ok := nn.CategoricalCrossEntropyWithLogits(logitsNode.value, target)
	assert(ok)
	for epoch in 0..<200 {
		// Both loss and convolution backward accumulate, so clear every node.
		assert(nn.ClearGradients(nodes[:]))
		assert(nn.Conv2DForward(&conv))
		assert(nn.CategoricalCrossEntropyWithLogitsBackward(&logitsNode, target))
		assert(nn.Conv2DBackward(&conv))
		assert(nn.SGDStep(optimizer))
	}

	assert(nn.Conv2DForward(&conv))
	loss, lossOK := nn.CategoricalCrossEntropyWithLogits(logitsNode.value, target)
	assert(lossOK && loss < initialLoss)
	fmt.printf("CCE loss: %.6f -> %.6f\n", initialLoss, loss)
	correct := 0
	for i in 0..<4 {
		prediction := 0
		if logits[2*i+1] > logits[2*i] { prediction = 1 }
		expected := 0
		if targets[2*i+1] == 1 { expected = 1 }
		if prediction == expected { correct += 1 }
		fmt.printf("image %d: class %d (expected %d), logits [%.4f, %.4f]\n", i, prediction, expected, logits[2*i], logits[2*i+1])
	}
	fmt.printf("training accuracy: %d/4\n", correct)
	assert(correct == 4)
}
