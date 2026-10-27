package nn

import "../core"
import "core:math"
import "core:testing"

@(test)
AdamInitialization :: proc(t: ^testing.T) {
	shape := [1]int{2}
	values := [2]f32{1, 2}
	gradients := [2]f32{3, 4}
	first := [2]f32{5, 6}
	second := [2]f32{7, 8}
	parameter := core.Node{value = core.Tensor{shape[:], values[:]}, grad = core.Tensor{shape[:], gradients[:]}}
	parameters := [2]^core.Node{&parameter, nil}
	optimizer := Adam{step = 42, learningRate = 0.25}
	testing.expect(t, !AdamInit(nil, parameters[:1], first[:], second[:]))
	testing.expect(t, !AdamInit(&optimizer, parameters[:], first[:], second[:]))
	parameters[1] = &parameter
	testing.expect(t, !AdamInit(&optimizer, parameters[:], first[:], second[:]))
	testing.expect(t, !AdamInit(&optimizer, parameters[:1], first[:1], second[:]))
	testing.expect(t, !AdamInit(&optimizer, parameters[:1], first[:1], second[:1]))
	testing.expect(t, !AdamInit(&optimizer, parameters[:1], first[:], second[:], learningRate = 0))
	testing.expect(t, !AdamInit(&optimizer, parameters[:1], first[:], second[:], beta1 = 1))
	testing.expect(t, !AdamInit(&optimizer, parameters[:1], first[:], second[:], beta2 = -1))
	testing.expect(t, !AdamInit(&optimizer, parameters[:1], first[:], second[:], epsilon = math.nan_f32()))
	testing.expect(t, optimizer.step == 42 && optimizer.learningRate == 0.25 && len(optimizer.parameters) == 0)
	testing.expect(t, first == [2]f32{5, 6} && second == [2]f32{7, 8})
	testing.expect(t, AdamInit(&optimizer, parameters[:1], first[:], second[:]))
	testing.expect(t, optimizer.step == 0 && optimizer.learningRate == 0.001 && optimizer.beta1 == 0.9 && optimizer.beta2 == 0.999 && optimizer.epsilon == 1e-8)
	testing.expect(t, len(optimizer.parameters) == 1 && optimizer.parameters[0] == &parameter)
	testing.expect(t, first == [2]f32{} && second == [2]f32{})
	testing.expect(t, AdamStep(&optimizer) && optimizer.step == 1)
	testing.expect(t, AdamInit(&optimizer, parameters[:1], first[:], second[:], 0.2, 0.5, 0.25, 0.01))
	testing.expect(t, optimizer.step == 0 && optimizer.learningRate == 0.2 && optimizer.beta1 == 0.5 && optimizer.beta2 == 0.25 && optimizer.epsilon == 0.01)
	testing.expect(t, first == [2]f32{} && second == [2]f32{})
}

@(test)
AdamReferenceSteps :: proc(t: ^testing.T) {
	shape := [1]int{1}
	values := [2]f32{1, -1}
	gradients := [2]f32{2, -2}
	first, second: [2]f32
	a := core.Node{value = core.Tensor{shape[:], values[:1]}, grad = core.Tensor{shape[:], gradients[:1]}}
	b := core.Node{value = core.Tensor{shape[:], values[1:]}, grad = core.Tensor{shape[:], gradients[1:]}}
	parameters := [2]^core.Node{&a, &b}
	optimizer := Adam{parameters[:], first[:], second[:], 0, 0.1, 0.5, 0.5, 1e-8}
	testing.expect(t, AdamStep(&optimizer))
	testing.expect(t, optimizer.step == 1 && math.abs(values[0]-0.9) < 0.000001 && math.abs(values[1]+0.9) < 0.000001)
	testing.expect(t, first == [2]f32{1, -1} && second == [2]f32{2, 2})
	gradients = [2]f32{4, -4}
	testing.expect(t, AdamStep(&optimizer))
	testing.expect(t, optimizer.step == 2 && math.abs(values[0]-0.80377495) < 0.000001 && math.abs(values[1]+0.80377495) < 0.000001)
	testing.expect(t, first == [2]f32{2.5, -2.5} && second == [2]f32{9, 9})
	testing.expect(t, gradients == [2]f32{4, -4})
}

@(test)
AdamInvalidInputs :: proc(t: ^testing.T) {
	shape := [1]int{2}
	values := [2]f32{1, 2}
	gradients := [2]f32{3, 4}
	first := [2]f32{0, 0}
	second := [2]f32{0, 0}
	parameter := core.Node{value = core.Tensor{shape[:], values[:]}, grad = core.Tensor{shape[:], gradients[:]}}
	parameters := [2]^core.Node{&parameter, nil}
	optimizer := Adam{parameters[:1], first[:], second[:], 0, 0.1, 0.9, 0.999, 1e-8}
	testing.expect(t, !AdamStep(nil))
	optimizer.parameters = parameters[:]
	testing.expect(t, !AdamStep(&optimizer))
	parameters[1] = &parameter
	testing.expect(t, !AdamStep(&optimizer))
	optimizer.parameters = parameters[:1]
	optimizer.firstMoment = first[:1]
	testing.expect(t, !AdamStep(&optimizer))
	optimizer.firstMoment = first[:]
	optimizer.learningRate = 0
	testing.expect(t, !AdamStep(&optimizer))
	optimizer.learningRate = 0.1
	optimizer.beta1 = 1
	testing.expect(t, !AdamStep(&optimizer))
	optimizer.beta1 = 0.9
	optimizer.beta2 = -1
	testing.expect(t, !AdamStep(&optimizer))
	optimizer.beta2 = 0.999
	optimizer.epsilon = 0
	testing.expect(t, !AdamStep(&optimizer))
	optimizer.epsilon = 1e-8
	optimizer.step = max(u64)
	testing.expect(t, !AdamStep(&optimizer))
	optimizer.step = 0
	second[1] = -1
	testing.expect(t, !AdamStep(&optimizer))
	second[1] = 0
	gradients[1] = math.inf_f32(1)
	testing.expect(t, !AdamStep(&optimizer))
	gradients[1] = 4
	values[1] = math.nan_f32()
	testing.expect(t, !AdamStep(&optimizer))
	values[1] = 2
	testing.expect(t, values == [2]f32{1, 2} && first == [2]f32{} && second == [2]f32{} && optimizer.step == 0)
}
