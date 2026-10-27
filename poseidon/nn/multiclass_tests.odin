package nn

import "../core"
import "core:math"
import "core:testing"

@(test)
MulticlassFullBatchAndSoftmax :: proc(t: ^testing.T) {
	logits, probabilities, batches: Sequential(2, 3, 3)
	for model in ([3]^Sequential(2, 3, 3){&logits, &probabilities, &batches}) {
		testing.expect(t, SequentialInit(model, 3, 17) && SequentialAddDense(model, 3))
	}
	testing.expect(t, SequentialAddActivation(&probabilities, .Softmax))
	inputs := [9]f32{1, 0, 0, 0, 1, 0, 0, 0, 1}
	targets := inputs
	indices: [3]int
	before, ok0 := SequentialFit(&logits, inputs[:], targets[:], CCEWithLogits{}, epochs = 0)
	full, ok1 := SequentialFit(&logits, inputs[:], targets[:], CCEWithLogits{}, epochs = 100, learningRate = 0.3)
	batched, ok2 := SequentialFitBatches(&batches, inputs[:], targets[:], indices[:], nil, loss = CCEWithLogits{}, epochs = 100, optimizer = SequentialSGD{0.3}, shuffle = false)
	testing.expect(t, ok0 && ok1 && ok2 && full < before && full < 0.1 && math.abs(full-batched) < 0.000001)
	for value, i in TestDenseStorage(&logits.layers[0]).weights.value.data { testing.expect(t, math.abs(value-TestDenseStorage(&batches.layers[0]).weightData[i]) < 0.000001) }
	for value, i in TestDenseStorage(&logits.layers[0]).bias.value.data { testing.expect(t, math.abs(value-TestDenseStorage(&batches.layers[0]).biasData[i]) < 0.000001) }
	copy(TestDenseStorage(&probabilities.layers[0]).weightData[:], TestDenseStorage(&logits.layers[0]).weightData[:])
	copy(TestDenseStorage(&probabilities.layers[0]).biasData[:], TestDenseStorage(&logits.layers[0]).biasData[:])
	output, predicted := SequentialPredict(&probabilities, inputs[:])
	testing.expect(t, predicted && len(output) == 9)
	if predicted {
		for row in 0..<3 {
			testing.expect(t, math.abs(output[row*3]+output[row*3+1]+output[row*3+2]-1) < 0.000001 && output[row*3+row] > 0.9)
		}
	}
	softBefore, ok3 := SequentialFit(&probabilities, inputs[:], targets[:], MSE{}, epochs = 0)
	softAfter, ok4 := SequentialFit(&probabilities, inputs[:], targets[:], MSE{}, epochs = 5, learningRate = 0.3)
	testing.expect(t, ok3 && ok4 && softAfter < softBefore)
	softBatched, ok5 := SequentialFitBatches(&probabilities, inputs[:], targets[:], indices[:], nil, loss = MSE{}, epochs = 5, optimizer = SequentialSGD{0.3}, shuffle = false)
	testing.expect(t, ok5 && softBatched < softAfter)
}

@(test)
MulticlassPartialBatchEvaluation :: proc(t: ^testing.T) {
	model: Sequential(1, 3, 2)
	testing.expect(t, SequentialInit(&model, 1) && SequentialAddDense(&model, 3))
	TestDenseStorage(&model.layers[0]).weightData = [9]f32{0, 0, 0, 0, 0, 0, 0, 0, 0}
	TestDenseStorage(&model.layers[0]).weightData[0] = 1
	inputs := [5]f32{0, 0, 0, 0, 4}
	targets := [15]f32{1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 0, 1, 0}
	indices: [5]int
	state: u64 = 123
	value, ok := SequentialFitBatches(&model, inputs[:], targets[:], indices[:], &state, loss = CCEWithLogits{}, epochs = 0)
	expected := (4 * math.ln(f64(3)) + math.ln(math.exp(f64(4)) + 2)) / 5
	testing.expect(t, ok && math.abs(f64(value)-expected) < 0.00001 && state == 123)
}

@(test)
MulticlassInvalidLabelsAndIncompatibleSoftmax :: proc(t: ^testing.T) {
	model: Sequential(2, 3, 3)
	testing.expect(t, SequentialInit(&model, 1, 5) && SequentialAddDense(&model, 3))
	inputs := [3]f32{1, 2, 3}
	targets := [9]f32{1, 0, 0, 0, 1, 0, 0, 0.5, 0.4}
	weights, biases := TestDenseStorage(&model.layers[0]).weightData, TestDenseStorage(&model.layers[0]).biasData
	_, ok := SequentialFit(&model, inputs[:], targets[:], CCEWithLogits{}, epochs = 2)
	testing.expect(t, !ok && TestDenseStorage(&model.layers[0]).weightData == weights && TestDenseStorage(&model.layers[0]).biasData == biases)
	storage: [2]^core.Node
	parameters, valid := SequentialParameters(&model, storage[:])
	testing.expect(t, valid)
	first, second: [6]f32
	adam := Adam{parameters, first[:], second[:], 0, 0.01, 0.9, 0.999, 1e-8}
	indices := [3]int{7, 8, 9}
	state: u64 = 42
	_, ok = SequentialFitBatches(&model, inputs[:], targets[:], indices[:], &state, batchSize = 2, loss = CCEWithLogits{}, epochs = 2, optimizer = &adam)
	testing.expect(t, !ok && TestDenseStorage(&model.layers[0]).weightData == weights && TestDenseStorage(&model.layers[0]).biasData == biases)
	testing.expect(t, adam.step == 0 && first == [6]f32{} && second == [6]f32{} && state == 42 && indices == [3]int{7, 8, 9})
	targets[8] = 0.5
	testing.expect(t, SequentialAddActivation(&model, .Softmax))
	for loss in ([2]SequentialLoss{CCEWithLogits{}, BCEWithLogits{}}) {
		_, ok = SequentialFit(&model, inputs[:], targets[:], loss, epochs = 1)
		testing.expect(t, !ok)
		_, ok = SequentialFitBatches(&model, inputs[:], targets[:], indices[:], &state, loss = loss, epochs = 1, optimizer = &adam)
		testing.expect(t, !ok)
	}
	testing.expect(t, TestDenseStorage(&model.layers[0]).weightData == weights && TestDenseStorage(&model.layers[0]).biasData == biases && adam.step == 0 && state == 42)
}

@(test)
MulticlassAdamDeterministic :: proc(t: ^testing.T) {
	a, b: Sequential(1, 3, 2)
	for model in ([2]^Sequential(1, 3, 2){&a, &b}) {
		testing.expect(t, SequentialInit(model, 1, 19) && SequentialAddDense(model, 3))
	}
	pa, pb: [2]^core.Node
	paramsA, oka := SequentialParameters(&a, pa[:])
	paramsB, okb := SequentialParameters(&b, pb[:])
	testing.expect(t, oka && okb)
	ma, va, mb, vb: [6]f32
	adamA := Adam{paramsA, ma[:], va[:], 0, 0.05, 0.9, 0.999, 1e-8}
	adamB := Adam{paramsB, mb[:], vb[:], 0, 0.05, 0.9, 0.999, 1e-8}
	inputs := [5]f32{-2, -1, 0, 1, 2}
	targets := [15]f32{1, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 1}
	ia, ib: [5]int
	sa, sb: u64 = 37, 37
	before, ok0 := SequentialFitBatches(&a, inputs[:], targets[:], ia[:], &sa, loss = CCEWithLogits{}, epochs = 0, optimizer = &adamA)
	la, ok1 := SequentialFitBatches(&a, inputs[:], targets[:], ia[:], &sa, loss = CCEWithLogits{}, epochs = 20, optimizer = &adamA)
	_, ok2 := SequentialFitBatches(&b, inputs[:], targets[:], ib[:], &sb, loss = CCEWithLogits{}, epochs = 7, optimizer = &adamB)
	lb, ok3 := SequentialFitBatches(&b, inputs[:], targets[:], ib[:], &sb, loss = CCEWithLogits{}, epochs = 13, optimizer = &adamB)
	testing.expect(t, ok0 && ok1 && ok2 && ok3 && la < before && la == lb && sa == sb)
	testing.expect(t, adamA.step == 60 && adamB.step == 60 && ma == mb && va == vb && ma != [6]f32{})
	testing.expect(t, TestDenseStorage(&a.layers[0]).weightData == TestDenseStorage(&b.layers[0]).weightData && TestDenseStorage(&a.layers[0]).biasData == TestDenseStorage(&b.layers[0]).biasData)
}

@(test)
PolicyTrainStepDense :: proc(t: ^testing.T) {
	for useAdam in ([2]bool{false, true}) {
		linear: LinearModel(1, 3, 1)
		testing.expect(t, LinearInit(&linear))
		linear.inputData[0] = 1
		linear.outputGrad = {9, 9, 9}
		linear.weightGrad = {9, 9, 9}
		actions := [1]int{0}
		legal := [3]bool{true, true, false}
		advantages := [1]f32{2}
		first, second: [6]f32
		adam := Adam{linear.parameters[:], first[:], second[:], 0, 0.1, 0.9, 0.999, 1e-8}
		optimizer: SequentialOptimizer = SequentialSGD{0.1}
		if useAdam { optimizer = &adam }
		loss, ok := PolicyTrainStep(Model{linear.layers[:]}, &linear.output, actions[:], legal[:], advantages[:], linear.nodes[:], linear.parameters[:], optimizer)
		testing.expect(t, ok && math.abs(loss-f32(2*math.ln(f64(2)))) < 0.00001)
		testing.expect(t, linear.outputGrad == [3]f32{-1, 1, 0} && linear.weightGrad == [3]f32{-1, 1, 0} && linear.biasGrad == [3]f32{-1, 1, 0})
		testing.expect(t, linear.weightData[0] > 0 && linear.weightData[1] < 0 && linear.weightData[2] == 0)
		if useAdam { testing.expect(t, adam.step == 1 && math.abs(linear.weightData[0]-0.1) < 0.00001) } else {
			testing.expect(t, linear.weightData == [3]f32{0.1, -0.1, 0} && linear.biasData == [3]f32{0.1, -0.1, 0})
		}
		testing.expect(t, ModelForward(Model{linear.layers[:]}))
		after, valid := PolicyGradientLoss(linear.output.value, actions[:], legal[:], advantages[:])
		testing.expect(t, valid && after < loss)
	}
}

@(test)
PolicyTrainStepInvalid :: proc(t: ^testing.T) {
	linear: LinearModel(1, 2, 1)
	testing.expect(t, LinearInit(&linear))
	linear.inputData[0] = 1
	linear.outputData = {7, 8}
	linear.outputGrad = {3, 4}
	actions := [1]int{0}
	legal := [2]bool{false, true}
	advantages := [1]f32{1}
	model := Model{linear.layers[:]}
	_, ok := PolicyTrainStep(model, &linear.output, actions[:], legal[:], advantages[:], linear.nodes[:], linear.parameters[:], SequentialSGD{0.1})
	testing.expect(t, !ok && linear.outputData == [2]f32{7, 8} && linear.outputGrad == [2]f32{3, 4})
	legal[0] = true
	_, ok = PolicyTrainStep(model, &linear.output, actions[:], legal[:], advantages[:], linear.nodes[:3], linear.parameters[:], SequentialSGD{0.1})
	testing.expect(t, !ok)
	duplicate := [2]^core.Node{&linear.weights, &linear.weights}
	_, ok = PolicyTrainStep(model, &linear.output, actions[:], legal[:], advantages[:], linear.nodes[:], duplicate[:], SequentialSGD{0.1})
	testing.expect(t, !ok)
	first, second: [4]f32
	wrong := [2]^core.Node{&linear.bias, &linear.weights}
	adam := Adam{wrong[:], first[:], second[:], 0, 0.1, 0.9, 0.999, 1e-8}
	_, ok = PolicyTrainStep(model, &linear.output, actions[:], legal[:], advantages[:], linear.nodes[:], linear.parameters[:], &adam)
	testing.expect(t, !ok && adam.step == 0 && linear.outputData == [2]f32{7, 8} && linear.outputGrad == [2]f32{3, 4})
}
