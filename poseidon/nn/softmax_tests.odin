package nn

import "../core"
import "core:math"
import "core:testing"

@(test)
SoftmaxForwardAndBackward :: proc(t: ^testing.T) {
	shape := [3]int{2, 2, 3}
	inputData := [12]f32{1000, 1001, 1002, -1000, -1000, -1000, 0, 0, 0, -1000, 0, 1000}
	outputData: [12]f32
	inputGrad := [12]f32{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1}
	outputGrad := [12]f32{1, 2, 3, 2, -1, 4, 1, 1, 1, 2, 3, 4}
	input := core.Node{value = core.Tensor{shape[:], inputData[:]}, grad = core.Tensor{shape[:], inputGrad[:]}}
	output := core.Node{value = core.Tensor{shape[:], outputData[:]}, grad = core.Tensor{shape[:], outputGrad[:]}}
	softmax := Softmax{&input, &output}
	layers := [1]Layer{&softmax}
	model := Model{layers[:]}
	testing.expect(t, ModelForward(model))
	testing.expect(t, math.abs(outputData[0] - 0.09003057) < 0.00001)
	testing.expect(t, math.abs(outputData[1] - 0.24472847) < 0.00001)
	testing.expect(t, math.abs(outputData[2] - 0.66524096) < 0.00001)
	for start := 0; start < 12; start += 3 {
		testing.expect(t, math.abs(outputData[start] + outputData[start+1] + outputData[start+2] - 1) < 0.00001)
	}
	testing.expect(t, outputData[9] == 0 && outputData[10] == 0 && outputData[11] == 1)
	testing.expect(t, ModelBackward(model))
	testing.expect(t, math.abs(inputGrad[0] - (1 - 0.1418171)) < 0.00001)
	testing.expect(t, math.abs(inputGrad[1] - (1 - 0.1407704)) < 0.00001)
	testing.expect(t, math.abs(inputGrad[2] - (1 + 0.2825875)) < 0.00001)
	for i in 6..<12 { testing.expect(t, math.abs(inputGrad[i] - 1) < 0.00001) }
}

@(test)
SoftmaxFiniteDifference :: proc(t: ^testing.T) {
	shape := [1]int{3}
	inputData := [3]f32{-0.7, 0.2, 1.1}
	outputData, inputGrad: [3]f32
	outputGrad := [3]f32{0.5, -2, 1.3}
	input := core.Node{value = core.Tensor{shape[:], inputData[:]}, grad = core.Tensor{shape[:], inputGrad[:]}}
	output := core.Node{value = core.Tensor{shape[:], outputData[:]}, grad = core.Tensor{shape[:], outputGrad[:]}}
	softmax := Softmax{&input, &output}
	testing.expect(t, LayerForward(&softmax) && LayerBackward(&softmax))
	for i in 0..<3 {
		original := inputData[i]
		inputData[i] = original + 0.001
		testing.expect(t, LayerForward(&softmax))
		plus: f32
		for value, j in outputData { plus += value * outputGrad[j] }
		inputData[i] = original - 0.001
		testing.expect(t, LayerForward(&softmax))
		minus: f32
		for value, j in outputData { minus += value * outputGrad[j] }
		inputData[i] = original
		testing.expect(t, math.abs(inputGrad[i] - (plus - minus) / 0.002) < 0.0001)
	}
}

@(test)
SoftmaxValidation :: proc(t: ^testing.T) {
	shape := [1]int{2}
	inputData := [2]f32{0, 1}
	outputData := [2]f32{7, 8}
	inputGrad := [2]f32{3, 4}
	outputGrad := [2]f32{1, 2}
	input := core.Node{value = core.Tensor{shape[:], inputData[:]}, grad = core.Tensor{shape[:], inputGrad[:]}}
	output := core.Node{value = core.Tensor{shape[:], outputData[:]}, grad = core.Tensor{shape[:], outputGrad[:]}}
	softmax := Softmax{&input, &output}
	for bad in ([3]f32{transmute(f32)u32(0x7f800000), transmute(f32)u32(0xff800000), transmute(f32)u32(0x7fc00000)}) {
		inputData[1] = bad
		testing.expect(t, !LayerForward(&softmax) && !LayerBackward(&softmax))
		testing.expect(t, outputData == [2]f32{7, 8} && inputGrad == [2]f32{3, 4})
	}
	inputData[1] = 1
	output.grad = {}
	testing.expect(t, !LayerBackward(&softmax))
	output.grad = core.Tensor{shape[:], outputGrad[:]}
	otherShape := [1]int{1}
	output.value.shape = otherShape[:]
	testing.expect(t, !LayerForward(&softmax))
	output.value = core.Tensor{nil, outputData[:1]}
	input.value = core.Tensor{nil, inputData[:1]}
	testing.expect(t, !LayerForward(&softmax))
	emptyShape := [2]int{2, 0}
	input.value = core.Tensor{emptyShape[:], nil}
	output.value = core.Tensor{emptyShape[:], nil}
	testing.expect(t, !LayerForward(&softmax))
	emptyShape = {0, 2}
	testing.expect(t, LayerForward(&softmax))
	bad := Softmax{}
	testing.expect(t, !LayerForward(&bad) && !LayerBackward(&bad))
}
