package main

import "../core"
import "core:fmt"

// Run with: odin run example/autograd.odin -file
main :: proc() {
	shape := [1]int{2}
	xData := [2]f32{2, 3}
	squareData, resultData: [2]f32
	xGrad, squareGrad: [2]f32
	resultGrad := [2]f32{1, 1}
	x := core.Node{value = core.Tensor{shape[:], xData[:]}, grad = core.Tensor{shape[:], xGrad[:]}}
	square := core.Node{value = core.Tensor{shape[:], squareData[:]}, grad = core.Tensor{shape[:], squareGrad[:]}, op = core.MultiplyOp{&x, &x}}
	result := core.Node{value = core.Tensor{shape[:], resultData[:]}, grad = core.Tensor{shape[:], resultGrad[:]}, op = core.AddOp{&square, &x}}
	assert(core.Forward(&square) && core.Forward(&result))
	assert(core.Backward(&result) && core.Backward(&square))
	fmt.printf("x squared plus x: %v\ngradient: %v\n", resultData, xGrad)
}
