package main

import "../core"
import "../nn"
import "core:fmt"

// Run with: odin run example/binary_classification.odin -file
main :: proc() {
	batchShape := [2]int{4, 1}
	weightShape := [2]int{1, 1}
	biasShape := [1]int{1}
	inputs := [4]f32{-2, -1, 1, 2}
	targets := [4]f32{0, 0, 1, 1}
	weight, bias: [1]f32
	logits: [4]f32
	inputGrad, logitsGrad: [4]f32
	weightGrad, biasGrad: [1]f32
	inputNode := core.Node{value = core.Tensor{batchShape[:], inputs[:]}, grad = core.Tensor{batchShape[:], inputGrad[:]}}
	weightNode := core.Node{value = core.Tensor{weightShape[:], weight[:]}, grad = core.Tensor{weightShape[:], weightGrad[:]}}
	biasNode := core.Node{value = core.Tensor{biasShape[:], bias[:]}, grad = core.Tensor{biasShape[:], biasGrad[:]}}
	logitsNode := core.Node{value = core.Tensor{batchShape[:], logits[:]}, grad = core.Tensor{batchShape[:], logitsGrad[:]}}
	dense := nn.Dense{&inputNode, &weightNode, &biasNode, &logitsNode}
	layers := [1]nn.Layer{&dense}
	model := nn.Model{layers[:]}
	parameters := [2]^core.Node{&weightNode, &biasNode}
	nodes := [4]^core.Node{&inputNode, &weightNode, &biasNode, &logitsNode}
	optimizer := nn.SGD{parameters[:], 0.2}
	target := core.Tensor{batchShape[:], targets[:]}
	for epoch in 0..<200 {
		assert(nn.ClearGradients(nodes[:]))
		assert(nn.ModelForward(model))
		assert(nn.BinaryCrossEntropyWithLogitsBackward(&logitsNode, target))
		assert(nn.ModelBackward(model))
		assert(nn.SGDStep(optimizer))
	}
	assert(nn.ModelForward(model))
	loss, ok := nn.BinaryCrossEntropyWithLogits(logitsNode.value, target)
	assert(ok)
	fmt.printf("weight: %.4f, bias: %.4f, loss: %.6f\n", weight[0], bias[0], loss)
	fmt.printf("logits: %v\n", logits)
}
