package nn

import "../core"
import "core:testing"
import "core:math"

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
