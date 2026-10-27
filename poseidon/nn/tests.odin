package nn

import "../core"
import "core:testing"
import "core:math"
import "core:mem"
import "core:thread"

ForwardFailureAllocator :: struct {
	backing: mem.Allocator,
	allocations, frees: int,
}

ForwardFailureAllocatorProc :: proc(
	allocatorData: rawptr, mode: mem.Allocator_Mode, size, alignment: int,
	oldMemory: rawptr, oldSize: int, loc := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	state := (^ForwardFailureAllocator)(allocatorData)
	if mode == .Alloc {
		state.allocations += 1
		if state.allocations == 2 { return nil, nil }
	}
	if mode == .Free { state.frees += 1 }
	return state.backing.procedure(state.backing.data, mode, size, alignment, oldMemory, oldSize, loc)
}

@(test)
ForwardParallel :: proc(t: ^testing.T) {
	inputShape := [2]int{5, 3}
	weightShape := [2]int{3, 5}
	biasShape := [1]int{5}
	outputShape := [2]int{5, 5}
	inputData := [15]f32{0.1, -3, 7, 1, 2, 3, -5, 0.2, 6, 9, -4, 1, 3, 8, -2}
	weightData := [15]f32{1, 0.2, -3, 4, 5, -2, 7, 0.1, 1, 2, 5, -1, 3, 0.3, 9}
	biasData := [5]f32{0.1, -2, 3, 0.3, 5}
	outputData, expected: [25]f32
	input := core.Node{value = core.Tensor{inputShape[:], inputData[:]}}
	weights := core.Node{value = core.Tensor{weightShape[:], weightData[:]}}
	bias := core.Node{value = core.Tensor{biasShape[:], biasData[:]}}
	output := core.Node{value = core.Tensor{outputShape[:], outputData[:]}}
	layer := Dense{&input, &weights, &bias, &output}
	testing.expect(t, LayerForward(&layer))
	expected = outputData
	for workers in ([5]int{-1, 1, 2, 4, 32}) {
		outputData = {}
		testing.expect(t, DenseForwardParallel(&layer, workers) && outputData == expected)
	}
	{
		context.allocator = mem.nil_allocator()
		testing.expect(t, DenseForwardParallel(&layer, 3) && outputData == expected)
	}
	when thread.IS_SUPPORTED {
		state := ForwardFailureAllocator{backing = context.allocator}
		ok: bool
		{
			context.allocator = mem.Allocator{procedure = ForwardFailureAllocatorProc, data = &state}
			ok = DenseForwardParallel(&layer, 3)
		}
		testing.expect(t, ok && outputData == expected && state.allocations == 2 && state.frees == 1)
	}
	outputShape[1] = 4
	testing.expect(t, !DenseForwardParallel(&layer, 3) && outputData == expected)
	testing.expect(t, !DenseForwardParallel(nil, 3))
	inputShape = {5, 0}; weightShape = {0, 5}; outputShape = {5, 5}
	input.value.data = nil; weights.value.data = nil
	testing.expect(t, DenseForwardParallel(&layer, 3))
	for row in 0..<5 { for column in 0..<5 { testing.expect(t, outputData[row*5+column] == biasData[column]) } }
	inputShape[0] = 0; outputShape[0] = 0; output.value.data = nil
	testing.expect(t, DenseForwardParallel(&layer, 3))
}

@(test)
ConvForwardParallel :: proc(t: ^testing.T) {
	inputShape := [4]int{2, 3, 3, 2}
	weightShape := [4]int{2, 2, 2, 3}
	biasShape := [1]int{3}
	outputShape := [4]int{2, 4, 4, 3}
	inputData: [36]f32
	weightData: [24]f32
	biasData := [3]f32{0.1, -1, 0.3}
	outputData, expected: [96]f32
	for &value, i in inputData { value = f32(i-18)*0.1 }
	for &value, i in weightData { value = f32(i-12)*0.2 }
	input := core.Node{value = core.Tensor{inputShape[:], inputData[:]}}
	weights := core.Node{value = core.Tensor{weightShape[:], weightData[:]}}
	bias := core.Node{value = core.Tensor{biasShape[:], biasData[:]}}
	output := core.Node{value = core.Tensor{outputShape[:], outputData[:]}}
	layer := Conv2D{&input, &weights, &bias, &output, 1, 1}
	testing.expect(t, Conv2DForward(&layer))
	expected = outputData
	for workers in ([5]int{-1, 1, 2, 3, 32}) {
		outputData = {}
		testing.expect(t, Conv2DForwardParallel(&layer, workers) && outputData == expected)
	}
	{
		context.allocator = mem.nil_allocator()
		testing.expect(t, Conv2DForwardParallel(&layer, 3) && outputData == expected)
	}
	when thread.IS_SUPPORTED {
		state := ForwardFailureAllocator{backing = context.allocator}
		ok: bool
		{
			context.allocator = mem.Allocator{procedure = ForwardFailureAllocatorProc, data = &state}
			ok = Conv2DForwardParallel(&layer, 3)
		}
		testing.expect(t, ok && outputData == expected && state.allocations == 2 && state.frees == 1)
	}
	layer.stride = 2
	outputShape = {2, 2, 2, 3}
	output.value.data = outputData[:24]
	testing.expect(t, Conv2DForward(&layer))
	expected = outputData
	outputData = {}
	testing.expect(t, Conv2DForwardParallel(&layer, 3))
	for i in 0..<24 { testing.expect(t, outputData[i] == expected[i]) }
	testing.expect(t, !Conv2DForwardParallel(nil, 3))
}

@(test)
DenseReluTraining :: proc(t: ^testing.T) {
	inputShape := [2]int{2, 2}
	biasShape := [1]int{2}
	inputData := [4]f32{1, 2, -1, 1}
	weightData := [4]f32{1, -1, 2, 1}
	biasData := [2]f32{0, -3}
	hiddenData, outputData, targetData: [4]f32
	inputGrad, weightGrad, hiddenGrad, outputGrad: [4]f32
	biasGrad: [2]f32
	input := core.Node{value = core.Tensor{inputShape[:], inputData[:]}, grad = core.Tensor{inputShape[:], inputGrad[:]}}
	weights := core.Node{value = core.Tensor{inputShape[:], weightData[:]}, grad = core.Tensor{inputShape[:], weightGrad[:]}}
	bias := core.Node{value = core.Tensor{biasShape[:], biasData[:]}, grad = core.Tensor{biasShape[:], biasGrad[:]}}
	hidden := core.Node{value = core.Tensor{inputShape[:], hiddenData[:]}, grad = core.Tensor{inputShape[:], hiddenGrad[:]}}
	output := core.Node{value = core.Tensor{inputShape[:], outputData[:]}, grad = core.Tensor{inputShape[:], outputGrad[:]}}
	dense := Dense{&input, &weights, &bias, &hidden}
	relu := Relu{&hidden, &output}
	layers := [2]Layer{&dense, &relu}
	model := Model{layers[:]}
	target := core.Tensor{inputShape[:], targetData[:]}
	testing.expect(t, ModelForward(model))
	testing.expect(t, hiddenData == [4]f32{5, -2, 1, -1})
	testing.expect(t, outputData == [4]f32{5, 0, 1, 0})
	loss, ok := MeanSquaredError(output.value, target)
	testing.expect(t, ok && loss == 6.5)
	testing.expect(t, MeanSquaredErrorBackward(&output, target))
	testing.expect(t, ModelBackward(model))
	testing.expect(t, inputGrad == [4]f32{2.5, 5, 0.5, 1})
	testing.expect(t, weightGrad == [4]f32{2, 0, 5.5, 0})
	testing.expect(t, biasGrad == [2]f32{3, 0})
	parameters := [2]^core.Node{&weights, &bias}
	testing.expect(t, SGDStep(SGD{parameters[:], 0.1}))
	testing.expect(t, ModelForward(model))
	updatedLoss, updatedOk := MeanSquaredError(output.value, target)
	testing.expect(t, updatedOk && updatedLoss < loss)
	nodes := [5]^core.Node{&input, &weights, &bias, &hidden, &output}
	testing.expect(t, ClearGradients(nodes[:]))
	testing.expect(t, weightGrad == [4]f32{} && biasGrad == [2]f32{} && outputGrad == [4]f32{})
}

@(test)
InvalidInputs :: proc(t: ^testing.T) {
	shape := [1]int{2}
	otherShape := [1]int{1}
	data: [2]f32
	other: [1]f32
	prediction := core.Node{value = core.Tensor{shape[:], data[:]}}
	target := core.Tensor{otherShape[:], other[:]}
	_, ok := MeanSquaredError(prediction.value, target)
	testing.expect(t, !ok)
	testing.expect(t, !MeanSquaredErrorBackward(&prediction, target))
	testing.expect(t, !LayerForward(nil))
	testing.expect(t, !LayerBackward(nil))
	badDense := Dense{}
	testing.expect(t, !LayerForward(&badDense))
	emptyShape := [1]int{0}
	empty := core.Tensor{emptyShape[:], nil}
	_, emptyOk := MeanSquaredError(empty, empty)
	testing.expect(t, !emptyOk)
}

@(test)
OptimizerValidation :: proc(t: ^testing.T) {
	shape := [1]int{2}
	data := [2]f32{1, 2}
	grad := [2]f32{3, 4}
	parameter := core.Node{value = core.Tensor{shape[:], data[:]}, grad = core.Tensor{shape[:], grad[:]}}
	parameters := [2]^core.Node{&parameter, nil}
	testing.expect(t, !SGDStep(SGD{parameters[:], 0.1}))
	testing.expect(t, data == [2]f32{1, 2})
	testing.expect(t, !ClearGradients(parameters[:]))
	testing.expect(t, grad == [2]f32{3, 4})
	parameters[1] = &parameter
	testing.expect(t, !SGDStep(SGD{parameters[:], 0.1}))
	testing.expect(t, !SGDStep(SGD{parameters[:1], 0}))
	testing.expect(t, !SGDStep(SGD{parameters[:1], -1}))
	testing.expect(t, data == [2]f32{1, 2})
	testing.expect(t, SGDStep(SGD{parameters[:1], 0.5}))
	testing.expect(t, data == [2]f32{-0.5, 0})
	testing.expect(t, grad == [2]f32{3, 4})
}

@(test)
SigmoidAndTanh :: proc(t: ^testing.T) {
	shape := [1]int{3}
	inputData := [3]f32{-2, 0, 2}
	outputData: [3]f32
	inputGrad := [3]f32{1, 1, 1}
	outputGrad := [3]f32{2, 2, 2}
	input := core.Node{value = core.Tensor{shape[:], inputData[:]}, grad = core.Tensor{shape[:], inputGrad[:]}}
	output := core.Node{value = core.Tensor{shape[:], outputData[:]}, grad = core.Tensor{shape[:], outputGrad[:]}}
	sigmoid := Sigmoid{&input, &output}
	sigmoidLayers := [1]Layer{&sigmoid}
	testing.expect(t, ModelForward(Model{sigmoidLayers[:]}))
	testing.expect(t, math.abs(outputData[0] - 0.11920292) < 0.00001)
	testing.expect(t, outputData[1] == 0.5)
	testing.expect(t, math.abs(outputData[2] - 0.88079708) < 0.00001)
	testing.expect(t, ModelBackward(Model{sigmoidLayers[:]}))
	testing.expect(t, math.abs(inputGrad[0] - 1.2099872) < 0.00001)
	testing.expect(t, inputGrad[1] == 1.5)
	testing.expect(t, math.abs(inputGrad[2] - 1.2099872) < 0.00001)
	inputGrad = [3]f32{0, 0, 0}
	tanh := Tanh{&input, &output}
	testing.expect(t, LayerForward(&tanh))
	testing.expect(t, math.abs(outputData[0] + 0.96402758) < 0.00001)
	testing.expect(t, outputData[1] == 0)
	testing.expect(t, math.abs(outputData[2] - 0.96402758) < 0.00001)
	testing.expect(t, LayerBackward(&tanh))
	testing.expect(t, math.abs(inputGrad[0] - 0.14130165) < 0.00001)
	testing.expect(t, inputGrad[1] == 2)
	testing.expect(t, math.abs(inputGrad[2] - 0.14130165) < 0.00001)
}

@(test)
ActivationEdgeCases :: proc(t: ^testing.T) {
	shape := [1]int{2}
	inputData := [2]f32{-1000, 1000}
	outputData: [2]f32
	input := core.Node{value = core.Tensor{shape[:], inputData[:]}}
	output := core.Node{value = core.Tensor{shape[:], outputData[:]}}
	sigmoid := Sigmoid{&input, &output}
	testing.expect(t, LayerForward(&sigmoid))
	testing.expect(t, outputData == [2]f32{0, 1})
	testing.expect(t, !LayerBackward(&sigmoid))
	bad := Tanh{}
	testing.expect(t, !LayerForward(&bad))
}

@(test)
ReluZeroAndAccumulation :: proc(t: ^testing.T) {
	shape := [1]int{3}
	inputData := [3]f32{-1, 0, 2}
	outputData: [3]f32
	inputGrad := [3]f32{1, 1, 1}
	outputGrad := [3]f32{2, 3, 4}
	input := core.Node{value = core.Tensor{shape[:], inputData[:]}, grad = core.Tensor{shape[:], inputGrad[:]}}
	output := core.Node{value = core.Tensor{shape[:], outputData[:]}, grad = core.Tensor{shape[:], outputGrad[:]}}
	relu := Relu{&input, &output}
	testing.expect(t, LayerForward(&relu))
	testing.expect(t, outputData == [3]f32{0, 0, 2})
	testing.expect(t, LayerBackward(&relu))
	testing.expect(t, inputGrad == [3]f32{1, 1, 5})
}

@(test)
Conv2DExactSeededGradient :: proc(t: ^testing.T) {
	inputShape := [4]int{1, 3, 3, 1}
	weightShape := [4]int{2, 2, 1, 1}
	biasShape := [1]int{1}
	outputShape := [4]int{1, 2, 2, 1}
	inputData := [9]f32{1, 2, 3, 4, 5, 6, 7, 8, 9}
	weightData := [4]f32{1, 0, 0, -1}
	biasData := [1]f32{1}
	outputData := [4]f32{99, 99, 99, 99}
	inputGrad: [9]f32
	weightGrad: [4]f32
	biasGrad: [1]f32
	outputGrad := [4]f32{1, 2, 3, 4}
	input := core.Node{value = core.Tensor{inputShape[:], inputData[:]}, grad = core.Tensor{inputShape[:], inputGrad[:]}}
	weights := core.Node{value = core.Tensor{weightShape[:], weightData[:]}, grad = core.Tensor{weightShape[:], weightGrad[:]}}
	bias := core.Node{value = core.Tensor{biasShape[:], biasData[:]}, grad = core.Tensor{biasShape[:], biasGrad[:]}}
	output := core.Node{value = core.Tensor{outputShape[:], outputData[:]}, grad = core.Tensor{outputShape[:], outputGrad[:]}}
	layer := Conv2D{&input, &weights, &bias, &output, 1, 0}

	testing.expect(t, Conv2DForward(&layer))
	testing.expect(t, outputData == [4]f32{-3, -3, -3, -3})
	testing.expect(t, Conv2DBackward(&layer))
	testing.expect(t, inputGrad == [9]f32{1, 2, 0, 3, 3, -2, 0, -3, -4})
	testing.expect(t, weightGrad == [4]f32{37, 47, 67, 77})
	testing.expect(t, biasGrad == [1]f32{10})
	testing.expect(t, outputGrad == [4]f32{1, 2, 3, 4})
	// A second backward pass must add, not replace, each gradient.
	testing.expect(t, Conv2DBackward(&layer))
	testing.expect(t, inputGrad == [9]f32{2, 4, 0, 6, 6, -4, 0, -6, -8})
	testing.expect(t, weightGrad == [4]f32{74, 94, 134, 154})
	testing.expect(t, biasGrad == [1]f32{20})
}

conv2dTestObjective :: proc(layer: ^Conv2D) -> (f32, bool) {
	if !Conv2DForward(layer) { return 0, false }
	result: f32
	for value, i in layer.output.value.data {
		result += value * layer.output.grad.data[i]
	}
	return result, true
}

@(test)
Conv2DNumericalGradient :: proc(t: ^testing.T) {
	inputShape := [4]int{2, 3, 4, 2}
	weightShape := [4]int{2, 3, 2, 2}
	biasShape := [1]int{2}
	outputShape := [4]int{2, 2, 2, 2}
	inputData: [48]f32
	weightData: [24]f32
	biasData := [2]f32{0.2, -0.3}
	outputData, outputGrad: [16]f32
	inputGrad: [48]f32
	weightGrad: [24]f32
	biasGrad: [2]f32
	for &value, i in inputData { value = f32(i % 11 - 5) * 0.1 }
	for &value, i in weightData { value = f32(i % 7 - 3) * 0.15 }
	for &value, i in outputGrad { value = f32(i % 9 - 4) * 0.2 }
	input := core.Node{value = core.Tensor{inputShape[:], inputData[:]}, grad = core.Tensor{inputShape[:], inputGrad[:]}}
	weights := core.Node{value = core.Tensor{weightShape[:], weightData[:]}, grad = core.Tensor{weightShape[:], weightGrad[:]}}
	bias := core.Node{value = core.Tensor{biasShape[:], biasData[:]}, grad = core.Tensor{biasShape[:], biasGrad[:]}}
	output := core.Node{value = core.Tensor{outputShape[:], outputData[:]}, grad = core.Tensor{outputShape[:], outputGrad[:]}}
	layer := Conv2D{&input, &weights, &bias, &output, 2, 1}
	testing.expect(t, Conv2DForward(&layer))
	testing.expect(t, Conv2DBackward(&layer))
	for node in ([3]^core.Node{&input, &weights, &bias}) {
		for &value, i in node.value.data {
			original := value
			value = original + 0.001
			plus, plusOk := conv2dTestObjective(&layer)
			value = original - 0.001
			minus, minusOk := conv2dTestObjective(&layer)
			value = original
			testing.expect(t, plusOk && minusOk)
			testing.expect(t, math.abs((plus - minus) / 0.002 - node.grad.data[i]) < 0.001)
		}
	}
}

@(test)
Conv2DValidationAndNoMutation :: proc(t: ^testing.T) {
	testing.expect(t, !Conv2DForward(nil) && !Conv2DBackward(nil))
	for testCase in 0..<32 {
		inputShape := [4]int{1, 2, 2, 1}
		weightShape := [4]int{1, 1, 1, 1}
		biasShape := [1]int{1}
		outputShape := [4]int{1, 2, 2, 1}
		badShape := [4]int{1, 2, 2, 1}
		inputData := [4]f32{1, 2, 3, 4}
		weightData := [1]f32{2}
		biasData := [1]f32{3}
		outputData := [4]f32{4, 5, 6, 7}
		inputGrad := [4]f32{8, 9, 10, 11}
		weightGrad := [1]f32{12}
		biasGrad := [1]f32{13}
		outputGrad := [4]f32{14, 15, 16, 17}
		input := core.Node{value = core.Tensor{inputShape[:], inputData[:]}, grad = core.Tensor{inputShape[:], inputGrad[:]}}
		weights := core.Node{value = core.Tensor{weightShape[:], weightData[:]}, grad = core.Tensor{weightShape[:], weightGrad[:]}}
		bias := core.Node{value = core.Tensor{biasShape[:], biasData[:]}, grad = core.Tensor{biasShape[:], biasGrad[:]}}
		output := core.Node{value = core.Tensor{outputShape[:], outputData[:]}, grad = core.Tensor{outputShape[:], outputGrad[:]}}
		layer := Conv2D{&input, &weights, &bias, &output, 1, 0}
		gradientOnly := false
		switch testCase {
		case 0: layer.input = nil
		case 1: layer.weights = nil
		case 2: layer.bias = nil
		case 3: layer.output = nil
		case 4: layer.stride = 0
		case 5: layer.stride = -1
		case 6: layer.padding = -1
		case 7: layer.padding = max(int)
		case 8: input.value.shape = inputShape[:3]
		case 9: weights.value.shape = weightShape[:3]
		case 10: bias.value.shape = nil
		case 11: output.value.shape = outputShape[:3]
		case 12: badShape[0] = 2; badShape[1] = 1; badShape[2] = 1; badShape[3] = 2; input.value.shape = badShape[:]
		case 13: bias.value.data = nil
		case 14: output.value.data = outputData[:3]
		case 15: badShape[1] = 1; output.value.shape = badShape[:]; output.value.data = outputData[:2]
		case 16: badShape[0] = 0; output.value.shape = badShape[:]; output.value.data = nil
		case 17: weightShape[0] = 0; weights.value.data = nil
		case 18: weightShape[1] = 0; weights.value.data = nil
		case 19: weightShape[2] = 0; weights.value.data = nil
		case 20: weightShape[3] = 0; weights.value.data = nil
		case 21: gradientOnly = true; input.grad.data = inputGrad[:3]
		case 22: gradientOnly = true; weights.grad.data = nil
		case 23: gradientOnly = true; bias.grad.shape = nil
		case 24: gradientOnly = true; output.grad.data = outputGrad[:3]
		case 25: badShape[0] = 2; badShape[1] = 1; output.value.shape = badShape[:]
		case 26: badShape[1] = 1; badShape[3] = 2; output.value.shape = badShape[:]
		case 27: badShape[0] = -1; input.value.shape = badShape[:]
		case 28: gradientOnly = true; badShape[1] = 1; badShape[2] = 4; input.grad.shape = badShape[:]
		case 29: weightShape[0] = 4; weights.value.data = nil
		case 30: biasShape[0] = 0; bias.value.data = nil
		case 31: gradientOnly = true; badShape[1] = 1; badShape[2] = 4; output.grad.shape = badShape[:]
		}
		if !gradientOnly {
			testing.expect(t, !Conv2DForward(&layer))
			testing.expect(t, !Conv2DForwardParallel(&layer, 4))
		}
		testing.expect(t, !Conv2DBackward(&layer))
		testing.expect(t, inputData == [4]f32{1, 2, 3, 4} && weightData == [1]f32{2} && biasData == [1]f32{3})
		testing.expect(t, outputData == [4]f32{4, 5, 6, 7} && outputGrad == [4]f32{14, 15, 16, 17})
		testing.expect(t, inputGrad == [4]f32{8, 9, 10, 11} && weightGrad == [1]f32{12} && biasGrad == [1]f32{13})
	}
}

@(test)
Conv2DEmptyAndOverflow :: proc(t: ^testing.T) {
	inputShape := [4]int{0, 2, 2, 1}
	weightShape := [4]int{1, 1, 1, 1}
	biasShape := [1]int{1}
	outputShape := [4]int{0, 2, 2, 1}
	weightData := [1]f32{2}
	biasData := [1]f32{3}
	weightGrad := [1]f32{4}
	biasGrad := [1]f32{5}
	input := core.Node{value = core.Tensor{inputShape[:], nil}, grad = core.Tensor{inputShape[:], nil}}
	weights := core.Node{value = core.Tensor{weightShape[:], weightData[:]}, grad = core.Tensor{weightShape[:], weightGrad[:]}}
	bias := core.Node{value = core.Tensor{biasShape[:], biasData[:]}, grad = core.Tensor{biasShape[:], biasGrad[:]}}
	output := core.Node{value = core.Tensor{outputShape[:], nil}, grad = core.Tensor{outputShape[:], nil}}
	layer := Conv2D{&input, &weights, &bias, &output, 1, 0}
	testing.expect(t, Conv2DForward(&layer) && Conv2DBackward(&layer))
	testing.expect(t, weightGrad == [1]f32{4} && biasGrad == [1]f32{5})
	// Empty batch makes the tensor size valid, but padded dimensions still overflow.
	inputShape[1] = max(int)
	layer.padding = 1
	testing.expect(t, !Conv2DForward(&layer) && !Conv2DBackward(&layer))
	testing.expect(t, weightData == [1]f32{2} && biasData == [1]f32{3})
	testing.expect(t, weightGrad == [1]f32{4} && biasGrad == [1]f32{5})
}

@(test)
Conv2DAliasingAndLargeEmpty :: proc(t: ^testing.T) {
	shape := [4]int{1, 1, 2, 1}
	weightShape := [4]int{1, 1, 1, 1}
	biasShape := [1]int{1}
	data := [3]f32{1, 2, 0}
	weightData := [1]f32{2}
	biasData := [1]f32{1}
	inputGrad, outputGrad: [2]f32
	weightGrad, biasGrad: [1]f32
	input := core.Node{value = core.Tensor{shape[:], data[:2]}, grad = core.Tensor{shape[:], inputGrad[:]}}
	weights := core.Node{value = core.Tensor{weightShape[:], weightData[:]}, grad = core.Tensor{weightShape[:], weightGrad[:]}}
	bias := core.Node{value = core.Tensor{biasShape[:], biasData[:]}, grad = core.Tensor{biasShape[:], biasGrad[:]}}
	output := core.Node{value = core.Tensor{shape[:], data[1:]}, grad = core.Tensor{shape[:], outputGrad[:]}}
	layer := Conv2D{&input, &weights, &bias, &output, 1, 0}
	testing.expect(t, !Conv2DForward(&layer) && data == [3]f32{1, 2, 0})
	testing.expect(t, !Conv2DForwardParallel(&layer, 4) && data == [3]f32{1, 2, 0})
	outputData: [2]f32
	output.value.data = outputData[:]
	input.grad.data = data[:2]
	testing.expect(t, !Conv2DBackward(&layer) && data == [3]f32{1, 2, 0})
	shape = [4]int{max(int), 0, 1, 1}
	input.value.data = nil
	input.grad.data = nil
	output.value.data = nil
	output.grad.data = nil
	testing.expect(t, Conv2DForward(&layer) && Conv2DBackward(&layer))
	testing.expect(t, Conv2DForwardParallel(&layer, 4))
}

@(test)
Conv2DStandaloneTest :: proc(t: ^testing.T) {
	inputShape := [4]int{1, 2, 2, 1}
	weightShape := [4]int{2, 2, 1, 1}
	biasShape := [1]int{1}
	inputData := [4]f32{1, 2, 3, 4}
	weightData := [4]f32{1, 2, 3, 4}
	biasData := [1]f32{1}
	outputData := [4]f32{-1, -1, -1, -1}
	inputGrad := [4]f32{1, 1, 1, 1}
	weightGrad := [4]f32{1, 1, 1, 1}
	biasGrad := [1]f32{1}
	outputGrad := [4]f32{1, 1, 1, 1}
	input := core.Node{value = core.Tensor{inputShape[:], inputData[:]}, grad = core.Tensor{inputShape[:], inputGrad[:]}}
	weights := core.Node{value = core.Tensor{weightShape[:], weightData[:]}, grad = core.Tensor{weightShape[:], weightGrad[:]}}
	bias := core.Node{value = core.Tensor{biasShape[:], biasData[:]}, grad = core.Tensor{biasShape[:], biasGrad[:]}}
	output := core.Node{value = core.Tensor{inputShape[:], outputData[:]}, grad = core.Tensor{inputShape[:], outputGrad[:]}}
	layer := Conv2D{&input, &weights, &bias, &output, 2, 1}
	testing.expect(t, Conv2DForward(&layer))
	testing.expect(t, outputData == [4]f32{5, 7, 7, 5})
	testing.expect(t, Conv2DBackward(&layer))
	testing.expect(t, inputGrad == [4]f32{5, 4, 3, 2})
	testing.expect(t, weightGrad == [4]f32{5, 4, 3, 2})
	testing.expect(t, biasGrad == [1]f32{5})
	layer.stride = 0
	testing.expect(t, !Conv2DForward(&layer) && !Conv2DBackward(&layer))
	testing.expect(t, outputData == [4]f32{5, 7, 7, 5} && biasGrad == [1]f32{5})
	layer.stride = 2
	output.grad.data = output.grad.data[:3]
	testing.expect(t, !Conv2DBackward(&layer) && biasGrad == [1]f32{5})
	_, overflow := Conv2DDimension(max(int), 1, 1, 1)
	testing.expect(t, !overflow)
	dim, ok := Conv2DDimension(0, 2, 2, 0)
	testing.expect(t, ok && dim == 0)
	_, negative := Conv2DDimension(0, 3, 2, 0)
	testing.expect(t, !negative)
}

@(test)
Conv2DChannelsAndEmptyTest :: proc(t: ^testing.T) {
	inputShape := [4]int{1, 1, 2, 2}
	weightShape := [4]int{1, 1, 2, 2}
	biasShape := [1]int{2}
	inputData := [4]f32{1, 2, 3, 4}
	weightData := [4]f32{1, 2, 3, 4}
	biasData := [2]f32{1, -1}
	outputData: [4]f32
	inputGrad, weightGrad: [4]f32
	biasGrad: [2]f32
	outputGrad := [4]f32{1, 2, 3, 4}
	input := core.Node{value = core.Tensor{inputShape[:], inputData[:]}, grad = core.Tensor{inputShape[:], inputGrad[:]}}
	weights := core.Node{value = core.Tensor{weightShape[:], weightData[:]}, grad = core.Tensor{weightShape[:], weightGrad[:]}}
	bias := core.Node{value = core.Tensor{biasShape[:], biasData[:]}, grad = core.Tensor{biasShape[:], biasGrad[:]}}
	output := core.Node{value = core.Tensor{inputShape[:], outputData[:]}, grad = core.Tensor{inputShape[:], outputGrad[:]}}
	layer := Conv2D{&input, &weights, &bias, &output, 1, 0}
	testing.expect(t, Conv2DForward(&layer) && outputData == [4]f32{8, 9, 16, 21})
	testing.expect(t, Conv2DBackward(&layer))
	testing.expect(t, inputGrad == [4]f32{5, 11, 11, 25})
	testing.expect(t, weightGrad == [4]f32{10, 14, 14, 20} && biasGrad == [2]f32{4, 6})
	inputShape[0] = 0
	input.value.data = nil
	input.grad.data = nil
	output.value.data = nil
	output.grad.data = nil
	testing.expect(t, Conv2DForward(&layer) && Conv2DBackward(&layer))
	testing.expect(t, weightGrad == [4]f32{10, 14, 14, 20} && biasGrad == [2]f32{4, 6})
	layer.padding = max(int)
	testing.expect(t, !Conv2DForward(&layer) && !Conv2DBackward(&layer))
}

@(test)
FlattenNumericalAndAllocation :: proc(t: ^testing.T) {
	inputShape := [3]int{2, 2, 2}
	outputShape := [2]int{2, 4}
	inputData := [8]f32{1, 2, 3, 4, -1, -2, -3, -4}
	outputData: [8]f32
	inputGrad := [8]f32{1, 1, 1, 1, 1, 1, 1, 1}
	outputGrad := [8]f32{0.5, -0.25, 1, 2, -1, 0.75, 0.25, -2}
	input := core.Node{value = core.Tensor{inputShape[:], inputData[:]}, grad = core.Tensor{inputShape[:], inputGrad[:]}}
	output := core.Node{value = core.Tensor{outputShape[:], outputData[:]}, grad = core.Tensor{outputShape[:], outputGrad[:]}}
	layer := Flatten{&input, &output}
	forwardOk, backwardOk: bool
	{
		context.allocator = {}
		forwardOk = FlattenForward(&layer)
		backwardOk = FlattenBackward(&layer)
	}
	testing.expect(t, forwardOk && backwardOk && outputData == inputData)
	for gradient, i in inputGrad { testing.expect(t, gradient == 1 + outputGrad[i]) }
	testing.expect(t, FlattenBackward(&layer))
	for gradient, i in inputGrad { testing.expect(t, gradient == 1 + 2*outputGrad[i]) }
	for &value, i in inputData {
		original := value
		value = original + 0.001
		plusOk := FlattenForward(&layer)
		plus: f32
		for v, j in outputData { plus += v * outputGrad[j] }
		value = original - 0.001
		minusOk := FlattenForward(&layer)
		minus: f32
		for v, j in outputData { minus += v * outputGrad[j] }
		value = original
		testing.expect(t, plusOk && minusOk && math.abs((plus-minus)/0.002 - outputGrad[i]) < 0.002)
	}
	// Rank two is an identity reshape, still requiring a distinct output.
	input.value.shape = outputShape[:]
	input.grad.shape = outputShape[:]
	testing.expect(t, FlattenForward(&layer) && FlattenBackward(&layer))
}

@(test)
FlattenInvalidAndNoMutation :: proc(t: ^testing.T) {
	testing.expect(t, !FlattenForward(nil) && !FlattenBackward(nil))
	for testCase in 0..<19 {
		inputShape := [3]int{1, 2, 2}
		outputShape := [2]int{1, 4}
		badInputShape := [3]int{1, 1, 4}
		badOutputShape := [2]int{2, 2}
		inputData := [5]f32{1, 2, 3, 4, 5}
		outputData := [5]f32{6, 7, 8, 9, 10}
		inputGrad := [5]f32{11, 12, 13, 14, 15}
		outputGrad := [5]f32{16, 17, 18, 19, 20}
		input := core.Node{value = core.Tensor{inputShape[:], inputData[:4]}, grad = core.Tensor{inputShape[:], inputGrad[:4]}}
		output := core.Node{value = core.Tensor{outputShape[:], outputData[:4]}, grad = core.Tensor{outputShape[:], outputGrad[:4]}}
		layer := Flatten{&input, &output}
		gradientOnly := false
		switch testCase {
		case 0: layer.input = nil
		case 1: layer.output = nil
		case 2: input.value.shape = inputShape[:1]
		case 3: output.value.shape = outputShape[:1]
		case 4: input.value.data = inputData[:3]
		case 5: output.value.data = outputData[:3]
		case 6: output.value.shape = badOutputShape[:]
		case 7: inputShape[1] = -1
		case 8: output.value.data = inputData[1:]
		case 9: gradientOnly = true; input.grad.data = inputGrad[:3]
		case 10: gradientOnly = true; output.grad.data = outputGrad[:3]
		case 11: gradientOnly = true; input.grad.shape = badInputShape[:]
		case 12: gradientOnly = true; output.grad.shape = badOutputShape[:]
		case 13: gradientOnly = true; input.grad.data = inputData[1:]
		case 14: gradientOnly = true; output.grad.data = inputData[1:]
		case 15: gradientOnly = true; input.grad.data = outputData[1:]
		case 16: gradientOnly = true; output.grad.data = outputData[1:]
		case 17: gradientOnly = true; output.grad.data = inputGrad[1:]
		case 18: layer.output = &input
		}
		if !gradientOnly { testing.expect(t, !FlattenForward(&layer)) }
		testing.expect(t, !FlattenBackward(&layer))
		testing.expect(t, inputData == [5]f32{1, 2, 3, 4, 5} && outputData == [5]f32{6, 7, 8, 9, 10})
		testing.expect(t, inputGrad == [5]f32{11, 12, 13, 14, 15} && outputGrad == [5]f32{16, 17, 18, 19, 20})
	}
}

@(test)
FlattenEmptyAndOverflow :: proc(t: ^testing.T) {
	inputShape := [4]int{0, 2, 3, 4}
	outputShape := [2]int{0, 24}
	input := core.Node{value = core.Tensor{inputShape[:], nil}, grad = core.Tensor{inputShape[:], nil}}
	output := core.Node{value = core.Tensor{outputShape[:], nil}, grad = core.Tensor{outputShape[:], nil}}
	layer := Flatten{&input, &output}
	testing.expect(t, FlattenForward(&layer) && FlattenBackward(&layer))
	inputShape = [4]int{max(int), 0, max(int), max(int)}
	outputShape = [2]int{max(int), 0}
	testing.expect(t, FlattenForward(&layer) && FlattenBackward(&layer))
	inputShape = [4]int{0, max(int), max(int), 0}
	outputShape = [2]int{0, 0}
	testing.expect(t, FlattenForward(&layer) && FlattenBackward(&layer))
	inputShape = [4]int{0, max(int), 2, 1}
	outputShape = [2]int{0, 0}
	testing.expect(t, !FlattenForward(&layer) && !FlattenBackward(&layer))
	inputShape = [4]int{1, max(int), 2, 0}
	testing.expect(t, !FlattenForward(&layer) && !FlattenBackward(&layer))
}

SpatialTestModel :: proc(model: ^Sequential(4, 8, 2)) -> bool {
	return SequentialInitSpatial(model, 2, 2, 1, 7) && SequentialAddConv2D(model, 1, 1, 1) && SequentialAddActivation(model, .Relu) && SequentialAddFlatten(model) && SequentialAddDense(model, 1)
}

@(test)
SequentialSpatialForwardAndParameters :: proc(t: ^testing.T) {
	model: Sequential(4, 8, 2)
	ok := SpatialTestModel(&model)
	testing.expect(t, ok)
	if !ok { return }
	conv := &model.layers[0].storage.(Conv2DStorage(8))
	dense := &model.layers[3].storage.(DenseStorage(8))
	conv.weightData[0], conv.biasData[0] = 2, -1
	copy(dense.weightData[:4], []f32{1, -1, 2, 0.5})
	dense.biasData[0] = 0.25
	storage: [4]^core.Node
	params, valid := SequentialParameters(&model, storage[:])
	testing.expect(t, valid && len(params) == 4 && params[0] == &conv.weights && params[1] == &conv.bias && params[2] == &dense.weights && params[3] == &dense.bias)
	short := [3]^core.Node{&dense.bias, &dense.bias, &dense.bias}
	_, valid = SequentialParameters(&model, short[:])
	testing.expect(t, !valid && short == [3]^core.Node{&dense.bias, &dense.bias, &dense.bias})
	inputs := [8]f32{0, 1, 2, 3, -1, 0.5, 1.5, 2.5}
	inputShape := [4]int{2, 2, 2, 1}
	flatShape := [2]int{2, 4}
	outputShape := [2]int{2, 1}
	convData, reluData, flatData: [8]f32
	outputData: [2]f32
	input := core.Node{value = core.Tensor{inputShape[:], inputs[:]}}
	convOut := core.Node{value = core.Tensor{inputShape[:], convData[:]}}
	reluOut := core.Node{value = core.Tensor{inputShape[:], reluData[:]}}
	flatOut := core.Node{value = core.Tensor{flatShape[:], flatData[:]}}
	output := core.Node{value = core.Tensor{outputShape[:], outputData[:]}}
	c := Conv2D{&input, &conv.weights, &conv.bias, &convOut, 1, 0}
	r := Relu{&convOut, &reluOut}
	f := Flatten{&reluOut, &flatOut}
	d := Dense{&flatOut, &dense.weights, &dense.bias, &output}
	testing.expect(t, LayerForward(&c) && LayerForward(&r) && LayerForward(&f) && LayerForward(&d))
	prediction, predicted := SequentialPredict(&model, inputs[:])
	testing.expect(t, predicted && len(prediction) == 2)
	if predicted {
		for value, i in prediction { testing.expect(t, value == outputData[i]) }
		for value, i in convData { testing.expect(t, value == model.layers[0].outputData[i] && reluData[i] == model.layers[1].outputData[i] && flatData[i] == model.layers[2].outputData[i]) }
	}
	prediction, predicted = SequentialPredict(&model, inputs[:4])
	testing.expect(t, predicted && len(prediction) == 1 && prediction[0] == outputData[0] && model.inputShape[0] == 1 && model.layers[2].outputShape[0] == 1)
	prediction, predicted = SequentialPredict(&model, inputs[:])
	testing.expect(t, predicted && len(prediction) == 2 && prediction[1] == outputData[1])
}

@(test)
SequentialSpatialNumericalGradient :: proc(t: ^testing.T) {
	model: Sequential(4, 8, 2)
	ok := SpatialTestModel(&model)
	testing.expect(t, ok)
	if !ok { return }
	conv := &model.layers[0].storage.(Conv2DStorage(8))
	dense := &model.layers[3].storage.(DenseStorage(8))
	conv.weightData[0], conv.biasData[0] = 0.7, 0.4
	copy(dense.weightData[:4], []f32{0.2, -0.3, 0.4, 0.1})
	dense.biasData[0] = 0.2
	inputs := [8]f32{0.2, 0.4, 0.6, 0.8, 0.3, 0.5, 0.7, 0.9}
	targets := [2]f32{0.1, 0.7}
	storage: [4]^core.Node
	params, valid := SequentialParameters(&model, storage[:])
	if !valid { testing.expect(t, false); return }
	_, ok = SequentialFit(&model, inputs[:], targets[:], epochs = 1, learningRate = 0.01)
	testing.expect(t, ok)
	if !ok { return }
	for param in params { for &value, i in param.value.data { value += 0.01 * param.grad.data[i] } }
	for param in params {
		for &value, i in param.value.data {
			original := value
			value = original + 0.001
			plus, plusOk := SequentialFit(&model, inputs[:], targets[:], epochs = 0)
			value = original - 0.001
			minus, minusOk := SequentialFit(&model, inputs[:], targets[:], epochs = 0)
			value = original
			testing.expect(t, plusOk && minusOk && math.abs(param.grad.data[i] - (plus-minus)/0.002) < 0.0003)
		}
	}
}

@(test)
SequentialSpatialTrainingBatches :: proc(t: ^testing.T) {
	sgd, adamModel: Sequential(4, 8, 2)
	ok := SpatialTestModel(&sgd) && SpatialTestModel(&adamModel)
	testing.expect(t, ok)
	if !ok { return }
	for model in ([2]^Sequential(4, 8, 2){&sgd, &adamModel}) {
		conv := &model.layers[0].storage.(Conv2DStorage(8))
		dense := &model.layers[3].storage.(DenseStorage(8))
		conv.weightData[0], conv.biasData[0] = 0.5, 0.5
		copy(dense.weightData[:4], []f32{0.1, 0.1, 0.1, 0.1})
	}
	inputs := [20]f32{0.1, 0.2, 0.3, 0.4, 0.2, 0.3, 0.4, 0.5, 0.3, 0.4, 0.5, 0.6, 0.4, 0.5, 0.6, 0.7, 0.5, 0.6, 0.7, 0.8}
	targets := [5]f32{1, 1.2, 1.4, 1.6, 1.8}
	indices: [5]int
	before, beforeOk := SequentialEvaluateBatches(&sgd, inputs[:], targets[:], 2, MSE{})
	storage: [4]^core.Node
	params, valid := SequentialParameters(&adamModel, storage[:])
	testing.expect(t, beforeOk && valid)
	if !beforeOk || !valid { return }
	first, second: [7]f32
	adam := Adam{params, first[:], second[:], 0, 0.03, 0.9, 0.999, 1e-8}
	sgdLoss, sgdOk := SequentialFitBatches(&sgd, inputs[:], targets[:], indices[:], nil, epochs = 80, optimizer = SequentialSGD{0.03}, shuffle = false)
	adamLoss, adamOk := SequentialFitBatches(&adamModel, inputs[:], targets[:], indices[:], nil, epochs = 80, optimizer = &adam, shuffle = false)
	testing.expect(t, sgdOk && adamOk && sgdLoss < before * 0.1 && adamLoss < before * 0.1 && adam.step == 240)
	testing.expect(t, first[0] != 0 && first[2] != 0 && sgd.layers[0].storage.(Conv2DStorage(8)).weightData[0] != 0.5 && adamModel.layers[3].storage.(DenseStorage(8)).weightData[0] != 0.1)
}

@(test)
SequentialFlattenLogitsValidation :: proc(t: ^testing.T) {
	for kind in ([2]ActivationKind{.Sigmoid, .Softmax}) {
		model: Sequential(3, 4, 1)
		testing.expect(t, SequentialInitSpatial(&model, 1, 1, 2) && SequentialAddActivation(&model, kind) && SequentialAddFlatten(&model))
		inputs := [2]f32{1, -1}
		targets := [2]f32{1, 0}
		indices: [1]int
		_, ok := SequentialFit(&model, inputs[:], targets[:], BCEWithLogits{}, epochs = 1)
		testing.expect(t, !ok)
		_, ok = SequentialFitBatches(&model, inputs[:], targets[:], indices[:], nil, loss = BCEWithLogits{}, epochs = 1, shuffle = false)
		testing.expect(t, !ok)
		if kind == .Softmax {
			_, ok = SequentialFit(&model, inputs[:], targets[:], CCEWithLogits{}, epochs = 1)
			testing.expect(t, !ok)
			_, ok = SequentialFitBatches(&model, inputs[:], targets[:], indices[:], nil, loss = CCEWithLogits{}, epochs = 1, shuffle = false)
			testing.expect(t, !ok)
		}
	}
}

@(test)
SequentialSpatialValidation :: proc(t: ^testing.T) {
	model: Sequential(4, 8, 2)
	testing.expect(t, !SequentialInitSpatial(&model, 0, 2, 1) && !SequentialInitSpatial(&model, 2, -1, 1) && !SequentialInitSpatial(&model, 2, 2, 0) && !SequentialInitSpatial(&model, max(int), 2, 1) && !SequentialInitSpatial(&model, 2, 2, 3))
	testing.expect(t, SequentialInitSpatial(&model, 2, 2, 1))
	testing.expect(t, !SequentialAddDense(&model, 1) && !SequentialAddConv2D(&model, 0, 1, 1) && !SequentialAddConv2D(&model, 1, 1, 0) && !SequentialAddConv2D(&model, 1, 1, 1, 0) && !SequentialAddConv2D(&model, 1, 1, 1, 1, -1))
	testing.expect(t, !SequentialAddConv2D(&model, 3, 3, 1) && !SequentialAddConv2D(&model, 1, 1, 3) && !SequentialAddConv2D(&model, max(int), 2, 1) && model.layerCount == 0)
	testing.expect(t, SequentialAddConv2D(&model, 1, 1, 1) && SequentialAddActivation(&model, .Relu) && SequentialAddFlatten(&model))
	testing.expect(t, !SequentialAddConv2D(&model, 1, 1, 1) && SequentialAddDense(&model, 1))
	testing.expect(t, !SequentialAddFlatten(&model) && !SequentialAddConv2D(&model, 1, 1, 1) && model.layerCount == 4)
	inputs: [12]f32
	_, ok := SequentialPredict(&model, inputs[:3])
	testing.expect(t, !ok)
	_, ok = SequentialPredict(&model, inputs[:])
	testing.expect(t, !ok)
}

PoolIntegrationModel :: proc(model: ^Sequential(4, 16, 2), kind: PoolKind) -> bool {
	return SequentialInitSpatial(model, 3, 3, 1, 7) && SequentialAddConv2D(model, 1, 1, 1) && SequentialAddPool2D(model, kind, 2, 2, 1) && SequentialAddFlatten(model) && SequentialAddDense(model, 1)
}

@(test)
SequentialPoolIntegration :: proc(t: ^testing.T) {
	for kind in ([2]PoolKind{.Max, .Average}) {
		model: Sequential(4, 16, 2)
		ok := PoolIntegrationModel(&model, kind)
		testing.expect(t, ok)
		if !ok { continue }
		conv := &model.layers[0].storage.(Conv2DStorage(16))
		dense := &model.layers[3].storage.(DenseStorage(16))
		conv.weightData[0], conv.biasData[0] = 2, 1
		copy(dense.weightData[:4], []f32{1, 2, 3, 4})
		dense.biasData[0] = 0.5
		storage: [4]^core.Node
		params, valid := SequentialParameters(&model, storage[:])
		testing.expect(t, valid && len(params) == 4 && params[0] == &conv.weights && params[1] == &conv.bias && params[2] == &dense.weights && params[3] == &dense.bias)
		if valid { testing.expect(t, len(params[0].value.data)+len(params[1].value.data)+len(params[2].value.data)+len(params[3].value.data) == 7) }
		inputs := [18]f32{1, 2, 3, 4, 5, 6, 7, 8, 9, 2, 3, 4, 5, 6, 7, 8, 9, 10}
		prediction, predicted := SequentialPredict(&model, inputs[:])
		expected: f32 = 164.5
		if kind == .Average { expected = 124.5 }
		testing.expect(t, predicted && len(prediction) == 2)
		if predicted && len(prediction) == 2 { testing.expect(t, prediction[0] == expected && prediction[1] == expected+20) }
		prediction, predicted = SequentialPredict(&model, inputs[:9])
		testing.expect(t, predicted && len(prediction) == 1 && prediction[0] == expected && model.layers[1].outputShape[0] == 1)
		prediction, predicted = SequentialPredict(&model, inputs[:])
		testing.expect(t, predicted && len(prediction) == 2 && prediction[1] == expected+20 && model.layers[1].outputShape[0] == 2)
		// Compare gradients through convolution and pooling with finite differences.
		conv.weightData[0], conv.biasData[0] = 0.7, 0.4
		copy(dense.weightData[:4], []f32{0.2, -0.3, 0.4, 0.1})
		dense.biasData[0] = 0.2
		gradientInputs := [18]f32{0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8,0.9, 0.2,0.3,0.4,0.5,0.6,0.7,0.8,0.9,1.0}
		targets := [2]f32{0.1, 0.7}
		_, trained := SequentialFit(&model, gradientInputs[:], targets[:], epochs = 1, learningRate = 0.000001)
		testing.expect(t, trained)
		if !trained || !valid { continue }
		for param in params { for &value, i in param.value.data { value += 0.000001 * param.grad.data[i] } }
		for param in params {
			for &value, i in param.value.data {
				original := value
				value = original + 0.001
				plus, plusOk := SequentialFit(&model, gradientInputs[:], targets[:], epochs = 0)
				value = original - 0.001
				minus, minusOk := SequentialFit(&model, gradientInputs[:], targets[:], epochs = 0)
				value = original
				testing.expect(t, plusOk && minusOk && math.abs(param.grad.data[i] - (plus-minus)/0.002) < 0.0003)
			}
		}
	}
}

@(test)
SequentialPoolValidationAndBatches :: proc(t: ^testing.T) {
	model: Sequential(4, 16, 2)
	testing.expect(t, SequentialInitSpatial(&model, 3, 3, 1))
	testing.expect(t, !SequentialAddPool2D(&model, PoolKind(99), 2, 2) && !SequentialAddPool2D(&model, .Max, 0, 2) && !SequentialAddPool2D(&model, .Max, 2, -1) && !SequentialAddPool2D(&model, .Max, 2, 2, 0) && !SequentialAddPool2D(&model, .Max, 4, 2) && !SequentialAddPool2D(&model, .Max, max(int), 2) && model.layerCount == 0)
	testing.expect(t, SequentialAddFlatten(&model) && !SequentialAddPool2D(&model, .Max, 1, 1) && model.layerCount == 1)
	full: Sequential(1, 16, 2)
	testing.expect(t, SequentialInitSpatial(&full, 3, 3, 1) && SequentialAddPool2D(&full, .Average, 2, 2) && !SequentialAddPool2D(&full, .Max, 1, 1) && full.layerCount == 1)
	badInputs: [27]f32
	_, validShape := SequentialPredict(&full, badInputs[:8])
	_, validCapacity := SequentialPredict(&full, badInputs[:])
	testing.expect(t, !validShape && !validCapacity)
	for kind in ([2]PoolKind{.Max, .Average}) {
		trained: Sequential(4, 16, 2)
		ok := PoolIntegrationModel(&trained, kind)
		testing.expect(t, ok)
		if !ok { continue }
		conv := &trained.layers[0].storage.(Conv2DStorage(16))
		dense := &trained.layers[3].storage.(DenseStorage(16))
		conv.weightData[0], conv.biasData[0] = 0.5, 0.1
		copy(dense.weightData[:4], []f32{0.1, 0.1, 0.1, 0.1})
		inputs := [45]f32{1,2,3,4,5,6,7,8,9, 2,3,4,5,6,7,8,9,10, 3,4,5,6,7,8,9,10,11, 4,5,6,7,8,9,10,11,12, 5,6,7,8,9,10,11,12,13}
		targets := [5]f32{1, 1, 1, 1, 1}
		indices: [5]int
		before, valid := SequentialEvaluateBatches(&trained, inputs[:], targets[:], 2, MSE{})
		loss, fit := SequentialFitBatches(&trained, inputs[:], targets[:], indices[:], nil, batchSize = 2, epochs = 30, optimizer = SequentialSGD{0.001}, shuffle = false)
		testing.expect(t, valid && fit && loss < before && conv.weightData[0] != 0.5 && dense.weightData[0] != 0.1)
	}
}

poolTestObjective :: proc(layer: ^Pool2D) -> (f32, bool) {
	if !Pool2DForward(layer) { return 0, false }
	result: f32
	for value, i in layer.output.value.data { result += value * layer.output.grad.data[i] }
	return result, true
}

@(test)
Pool2DNumericalGradient :: proc(t: ^testing.T) {
	inputShape := [4]int{2, 3, 4, 2}
	outputShape := [4]int{2, 2, 3, 2}
	inputData, inputGrad: [48]f32
	outputData, outputGrad: [24]f32
	for &value, i in inputData { value = f32((i*17)%47)*0.1 }
	for &value, i in outputGrad { value = f32(i%7-3)*0.2 }
	input := core.Node{value = {inputShape[:], inputData[:]}, grad = {inputShape[:], inputGrad[:]}}
	output := core.Node{value = {outputShape[:], outputData[:]}, grad = {outputShape[:], outputGrad[:]}}
	layer := Pool2D{&input, &output, .Max, 2, 2, 1}
	for kind in ([2]PoolKind{.Max, .Average}) {
		layer.kind = kind
		for &gradient in inputGrad { gradient = 0 }
		testing.expect(t, Pool2DForward(&layer) && Pool2DBackward(&layer))
		for &value, i in inputData {
			original := value
			value = original + 0.001
			plus, plusOk := poolTestObjective(&layer)
			value = original - 0.001
			minus, minusOk := poolTestObjective(&layer)
			value = original
			testing.expect(t, plusOk && minusOk && math.abs((plus-minus)/0.002-inputGrad[i]) < 0.003)
		}
	}
}

@(test)
Pool2DAverageLargeValues :: proc(t: ^testing.T) {
	inputShape := [4]int{1, 1, 2, 1}
	outputShape := [4]int{1, 1, 1, 1}
	largest := transmute(f32)u32(0x7f7fffff)
	inputData := [2]f32{largest, largest}
	outputData: [1]f32
	input := core.Node{value = {inputShape[:], inputData[:]}}
	output := core.Node{value = {outputShape[:], outputData[:]}}
	layer := Pool2D{&input, &output, .Average, 1, 2, 1}
	testing.expect(t, Pool2DForward(&layer) && outputData[0] == largest)
}

@(test)
Pool2DTiesAndAccumulation :: proc(t: ^testing.T) {
	inputShape := [4]int{1, 2, 3, 1}
	outputShape := [4]int{1, 1, 2, 1}
	inputData := [6]f32{5, 5, 1, 5, 5, 0}
	inputGrad := [6]f32{1, 1, 1, 1, 1, 1}
	outputData: [2]f32
	outputGrad := [2]f32{2, 3}
	input := core.Node{value = {inputShape[:], inputData[:]}, grad = {inputShape[:], inputGrad[:]}}
	output := core.Node{value = {outputShape[:], outputData[:]}, grad = {outputShape[:], outputGrad[:]}}
	layer := Pool2D{&input, &output, .Max, 2, 2, 1}
	testing.expect(t, Pool2DForward(&layer) && outputData == [2]f32{5, 5})
	testing.expect(t, Pool2DBackward(&layer) && inputGrad == [6]f32{3, 4, 1, 1, 1, 1})
	layer.kind = .Average
	testing.expect(t, Pool2DForward(&layer) && outputData == [2]f32{5, 2.75})
	testing.expect(t, Pool2DBackward(&layer) && inputGrad == [6]f32{3.5, 5.25, 1.75, 1.5, 2.25, 1.75})
}

@(test)
Pool2DValidationAndEmpty :: proc(t: ^testing.T) {
	testing.expect(t, !Pool2DForward(nil) && !Pool2DBackward(nil))
	for testCase in 0..<19 {
		shape := [4]int{1, 2, 2, 1}
		badShape := [4]int{1, 1, 4, 1}
		inputData := [4]f32{1, 2, 3, 4}
		outputData := [4]f32{5, 6, 7, 8}
		inputGrad := [4]f32{9, 10, 11, 12}
		outputGrad := [4]f32{13, 14, 15, 16}
		input := core.Node{value = {shape[:], inputData[:]}, grad = {shape[:], inputGrad[:]}}
		output := core.Node{value = {shape[:], outputData[:]}, grad = {shape[:], outputGrad[:]}}
		layer := Pool2D{&input, &output, .Max, 1, 1, 1}
		gradientOnly := false
		switch testCase {
		case 0: layer.input = nil
		case 1: layer.output = nil
		case 2: layer.kind = PoolKind(99)
		case 3: layer.kernelHeight = 0
		case 4: layer.kernelWidth = -1
		case 5: layer.stride = 0
		case 6: layer.kernelHeight = max(int); layer.kernelWidth = 2
		case 7: input.value.shape = shape[:3]
		case 8: output.value.shape = badShape[:]
		case 9: input.value.data = inputData[:3]
		case 10: output.value.data = inputData[:]
		case 11: gradientOnly = true; input.grad.data = inputGrad[:3]
		case 12: gradientOnly = true; output.grad.shape = badShape[:]
		case 13: gradientOnly = true; input.grad.data = inputData[:]
		case 14: gradientOnly = true; output.grad.data = outputData[:]
		case 15: gradientOnly = true; output.grad.data = inputGrad[:]
		case 16: gradientOnly = true; output.grad.data = inputData[:]
		case 17: gradientOnly = true; input.grad.data = outputData[:]
		case 18: inputData[3] = transmute(f32)u32(0x7fc00000)
		}
		if !gradientOnly { testing.expect(t, !Pool2DForward(&layer)) }
		testing.expect(t, !Pool2DBackward(&layer))
		testing.expect(t, outputData == [4]f32{5, 6, 7, 8} && inputGrad == [4]f32{9, 10, 11, 12} && outputGrad == [4]f32{13, 14, 15, 16})
	}
	inputShape := [4]int{1, 2, 3, 1}
	outputShape := [4]int{1, 0, 2, 1}
	inputData := [6]f32{1, 2, 3, 4, 5, 6}
	inputGrad := [6]f32{1, 2, 3, 4, 5, 6}
	input := core.Node{value = {inputShape[:], inputData[:]}, grad = {inputShape[:], inputGrad[:]}}
	output := core.Node{value = {outputShape[:], nil}, grad = {outputShape[:], nil}}
	layer := Pool2D{&input, &output, .Max, 3, 2, 1}
	testing.expect(t, Pool2DForward(&layer) && Pool2DBackward(&layer) && inputGrad == [6]f32{1, 2, 3, 4, 5, 6})
	inputShape = [4]int{0, max(int), max(int), 1}
	outputShape = [4]int{0, max(int), max(int), 1}
	input.value.data = nil; input.grad.data = nil
	layer.kernelHeight = 1; layer.kernelWidth = 1
	testing.expect(t, Pool2DForward(&layer) && Pool2DBackward(&layer))
}

@(test)
CategoricalPolicyValuesAndSampling :: proc(t: ^testing.T) {
	shape := [3]int{1, 2, 3}
	data := [6]f32{1000, 1000, 9999, -1000, 0, 1000}
	mask := [6]bool{true, true, false, false, true, false}
	logits := core.Tensor{shape[:], data[:]}
	probabilities: [6]f32
	actions := [2]int{1, 1}
	logs, entropy: [2]f64
	testing.expect(t, CategoricalPolicyProbabilities(logits, mask[:], probabilities[:]))
	testing.expect(t, probabilities == [6]f32{0.5, 0.5, 0, 0, 1, 0})
	testing.expect(t, CategoricalPolicyLogProbs(logits, mask[:], actions[:], logs[:]))
	testing.expect(t, CategoricalPolicyEntropy(logits, mask[:], entropy[:]))
	testing.expect(t, math.abs(logs[0] + math.ln(f64(2))) < 1e-12 && logs[1] == 0)
	testing.expect(t, math.abs(entropy[0] - math.ln(f64(2))) < 1e-12 && entropy[1] == 0)
	seedA, seedB: u64 = 123, 123
	sampleA, sampleB: [2]int
	for _ in 0..<100 {
		testing.expect(t, CategoricalPolicySample(logits, mask[:], &seedA, sampleA[:]))
		testing.expect(t, CategoricalPolicySample(logits, mask[:], &seedB, sampleB[:]))
		testing.expect(t, sampleA == sampleB && seedA == seedB && sampleA[0] < 2 && sampleA[1] == 1)
	}
	data = {transmute(f32)u32(0x7f7fffff), transmute(f32)u32(0xff7fffff), 0, 0, 0, 0}
	actions[0] = 1
	testing.expect(t, CategoricalPolicyLogProbs(logits, mask[:], actions[:], logs[:]))
	testing.expect(t, logs[0] < -6e38 && !math.is_inf(logs[0]))
	testing.expect(t, CategoricalPolicyEntropy(logits, mask[:], entropy[:]) && entropy[0] == 0)
}

@(test)
CategoricalPolicyTinyTail :: proc(t: ^testing.T) {
	shape := [2]int{2, 3}
	data := [6]f32{0, -40, 100, 0, -40, 0}
	mask := [6]bool{true, true, false, true, true, false}
	logits := core.Tensor{shape[:], data[:]}
	actions := [2]int{0, 0}
	logs := [2]f64{7, 7}
	entropy := [2]f64{7, 7}
	tail := math.exp(f64(-40))
	testing.expect(t, CategoricalPolicyLogProbs(logits, mask[:], actions[:], logs[:]))
	testing.expect(t, math.abs(logs[0] + tail) < tail * 1e-12 && math.abs(logs[1] + tail) < tail * 1e-12)
	testing.expect(t, CategoricalPolicyEntropy(logits, mask[:], entropy[:]))
	testing.expect(t, math.abs(entropy[0] - 41 * tail) < tail * 1e-12)
	logs = {7, 7}; entropy = {7, 7}
	actions[1] = 2
	testing.expect(t, !CategoricalPolicyLogProbs(logits, mask[:], actions[:], logs[:]) && logs == [2]f64{7, 7})
	mask[3] = false; mask[4] = false
	testing.expect(t, !CategoricalPolicyEntropy(logits, mask[:], entropy[:]) && entropy == [2]f64{7, 7})
}

@(test)
CategoricalPolicyValidation :: proc(t: ^testing.T) {
	shape := [2]int{2, 2}
	data := [4]f32{0, 1, 2, 3}
	mask := [4]bool{true, true, true, true}
	logits := core.Tensor{shape[:], data[:]}
	probabilities := [4]f32{7, 7, 7, 7}
	actions := [2]int{0, 1}
	logs := [2]f64{7, 7}
	entropy := [2]f64{7, 7}
	samples := [2]int{7, 7}
	seed: u64 = 123
	for bad in ([3]f32{transmute(f32)u32(0x7fc00000), transmute(f32)u32(0x7f800000), transmute(f32)u32(0xff800000)}) {
		data[3] = bad
		mask[3] = false
		testing.expect(t, !CategoricalPolicyProbabilities(logits, mask[:], probabilities[:]))
		testing.expect(t, !CategoricalPolicyLogProbs(logits, mask[:], actions[:], logs[:]))
		testing.expect(t, !CategoricalPolicyEntropy(logits, mask[:], entropy[:]))
		testing.expect(t, !CategoricalPolicySample(logits, mask[:], &seed, samples[:]))
	}
	data[3] = 3
	mask[2] = false
	testing.expect(t, !CategoricalPolicySample(logits, mask[:], &seed, samples[:]))
	testing.expect(t, !CategoricalPolicyProbabilities(logits, mask[:], probabilities[:]))
	mask[2] = true
	for badAction in ([3]int{-1, 2, 1}) {
		actions[1] = badAction
		testing.expect(t, !CategoricalPolicyLogProbs(logits, mask[:], actions[:], logs[:]))
	}
	testing.expect(t, !CategoricalPolicyEntropy(logits, mask[:3], entropy[:]))
	testing.expect(t, !CategoricalPolicySample(logits, mask[:], nil, samples[:]))
	testing.expect(t, !CategoricalPolicySample(logits, mask[:], &seed, samples[:1]))
	testing.expect(t, probabilities == [4]f32{7, 7, 7, 7} && logs == [2]f64{7, 7} && entropy == [2]f64{7, 7} && samples == [2]int{7, 7} && seed == 123)
	zeroSeed: u64
	testing.expect(t, !CategoricalPolicySample(logits, mask[:], &zeroSeed, samples[:]))
	emptyShape := [2]int{0, 2}
	empty := core.Tensor{emptyShape[:], nil}
	testing.expect(t, CategoricalPolicyProbabilities(empty, nil, nil) && CategoricalPolicyLogProbs(empty, nil, nil, nil) && CategoricalPolicyEntropy(empty, nil, nil) && CategoricalPolicySample(empty, nil, &seed, nil) && seed == 123)
	emptyShape = {2, 0}
	testing.expect(t, !CategoricalPolicyEntropy(empty, nil, nil))
}


@(test)
FlattenVectorBoundaries :: proc(t: ^testing.T) {
	for count in 0..<12 {
		inputShape := [3]int{1, 1, count}
		outputShape := [2]int{1, count}
		inputData, outputData, inputGrad, outputGrad: [13]f32
		for i in 0..<13 {
			inputData[i] = f32(i - 6)
			outputData[i] = 99
			inputGrad[i] = f32(i) * 0.25
			outputGrad[i] = f32(i - 4) * 0.5
		}
		input := core.Node{value = core.Tensor{inputShape[:], inputData[1:count+1]}, grad = core.Tensor{inputShape[:], inputGrad[1:count+1]}}
		output := core.Node{value = core.Tensor{outputShape[:], outputData[1:count+1]}, grad = core.Tensor{outputShape[:], outputGrad[1:count+1]}}
		layer := Flatten{&input, &output}
		testing.expect(t, FlattenForward(&layer) && FlattenBackward(&layer))
		for i in 1..<count+1 {
			testing.expect(t, outputData[i] == inputData[i])
			testing.expect(t, inputGrad[i] == f32(i)*0.25 + outputGrad[i])
		}
		testing.expect(t, outputData[0] == 99 && outputData[count+1] == 99)
		testing.expect(t, inputGrad[0] == 0 && inputGrad[count+1] == f32(count+1)*0.25)
	}
}
