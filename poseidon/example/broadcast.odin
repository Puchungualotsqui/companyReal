package main

import "../core"
import "core:fmt"

// Run with: odin run example/broadcast.odin -file
main :: proc() {
	inputShape := [2]int{2, 3}
	biasShape := [1]int{3}
	totalShape := [1]int{2}
	inputs := [6]f32{1, 2, 3, 4, 5, 6}
	bias := [3]f32{10, 20, 30}
	output, inputGrad: [6]f32
	biasGrad: [3]f32
	outputGrad: [6]f32
	totals: [2]f32
	totalGrad := [2]f32{1, 1}
	inputNode := core.Node{value = core.Tensor{inputShape[:], inputs[:]}, grad = core.Tensor{inputShape[:], inputGrad[:]}}
	biasNode := core.Node{value = core.Tensor{biasShape[:], bias[:]}, grad = core.Tensor{biasShape[:], biasGrad[:]}}
	outputNode := core.Node{value = core.Tensor{inputShape[:], output[:]}, grad = core.Tensor{inputShape[:], outputGrad[:]}, op = core.BroadcastAddOp{&inputNode, &biasNode}}
	totalNode := core.Node{value = core.Tensor{totalShape[:], totals[:]}, grad = core.Tensor{totalShape[:], totalGrad[:]}, op = core.SumAxisOp{&outputNode, 1, false}}
	assert(core.Forward(&outputNode) && core.Forward(&totalNode))
	assert(core.Backward(&totalNode) && core.Backward(&outputNode))
	fmt.printf("Row sums: %v\nBias gradient: %v\n", totals, biasGrad)
}
