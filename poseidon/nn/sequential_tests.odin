package nn

import "core:math"
import "core:testing"

@(test)
SequentialSeedAndInitialization :: proc(t: ^testing.T) {
	a, b, c, zero, zeroAgain: Sequential(3, 4, 2)
	testing.expect(t, SequentialInit(&a, 2, 42) && SequentialInit(&b, 2, 42))
	testing.expect(t, SequentialInit(&c, 2, 43) && SequentialInit(&zero, 2, 0) && SequentialInit(&zeroAgain, 2, 0))
	for model in ([5]^Sequential(3, 4, 2){&a, &b, &c, &zero, &zeroAgain}) {
		testing.expect(t, SequentialAddDense(model, 4))
		testing.expect(t, SequentialAddActivation(model, .Tanh))
		testing.expect(t, SequentialAddDense(model, 2))
	}
	different := false
	for layer in ([2]int{0, 2}) {
		limit := math.sqrt(f32(6) / f32(a.layers[layer].weightShape[0] + a.layers[layer].weightShape[1]))
		for weight, i in a.layers[layer].weights.value.data {
			testing.expect(t, weight == b.layers[layer].weightData[i] && math.abs(weight) <= limit)
			if weight != c.layers[layer].weightData[i] { different = true }
		}
		for bias in a.layers[layer].bias.value.data { testing.expect(t, bias == 0) }
		for weight, i in zero.layers[layer].weights.value.data { testing.expect(t, weight == zeroAgain.layers[layer].weightData[i]) }
	}
	testing.expect(t, different)
	input := [2]f32{0.3, -0.5}
	pa, oka := SequentialPredict(&a, input[:])
	pb, okb := SequentialPredict(&b, input[:])
	testing.expect(t, oka && okb && len(pa) == 2 && len(pb) == 2)
	if oka && okb { testing.expect(t, pa[0] == pb[0] && pa[1] == pb[1]) }
}

@(test)
SequentialBoundsAndCopy :: proc(t: ^testing.T) {
	model: Sequential(2, 3, 2)
	input := [6]f32{1, 2, 3, 4, 5, 6}
	target := [2]f32{0, 1}
	_, ok := SequentialPredict(&model, input[:2])
	testing.expect(t, !ok)
	testing.expect(t, !SequentialInit(&model, 0) && !SequentialInit(&model, 4))
	testing.expect(t, SequentialInit(&model, 2))
	_, ok = SequentialPredict(&model, input[:2])
	testing.expect(t, !ok)
	testing.expect(t, !SequentialAddDense(&model, 0) && !SequentialAddDense(&model, 4))
	testing.expect(t, !SequentialAddActivation(&model, ActivationKind(99)))
	testing.expect(t, model.layerCount == 0)
	testing.expect(t, SequentialAddDense(&model, 1) && SequentialAddActivation(&model, .Sigmoid))
	_, ok = SequentialFit(&model, input[:2], target[:1], BCEWithLogits{}, epochs = 0)
	testing.expect(t, !ok)
	testing.expect(t, !SequentialAddDense(&model, 1) && !SequentialAddActivation(&model, .Relu))
	_, ok = SequentialPredict(&model, nil)
	testing.expect(t, !ok)
	_, ok = SequentialPredict(&model, input[:3])
	testing.expect(t, !ok)
	_, ok = SequentialPredict(&model, input[:])
	testing.expect(t, !ok)
	copyModel := model
	_, ok = SequentialPredict(&copyModel, input[:2])
	testing.expect(t, !ok && !SequentialAddDense(&copyModel, 1))
	_, ok = SequentialFit(&copyModel, input[:2], target[:1])
	testing.expect(t, !ok)
	_, ok = SequentialPredict(&model, input[:2])
	testing.expect(t, ok)
	testing.expect(t, SequentialInit(&copyModel, 2) && SequentialAddDense(&copyModel, 1))
	_, ok = SequentialPredict(&copyModel, input[:2])
	testing.expect(t, ok)
}

@(test)
SequentialBatchAndBorrowedOutput :: proc(t: ^testing.T) {
	model: Sequential(2, 2, 3)
	testing.expect(t, SequentialInit(&model, 1) && SequentialAddDense(&model, 1) && SequentialAddActivation(&model, .Relu))
	model.layers[0].weightData[0] = 2
	model.layers[0].biasData[0] = 1
	input := [3]f32{-1, 1, 2}
	output, ok := SequentialPredict(&model, input[:])
	testing.expect(t, ok && len(output) == 3)
	if !ok { return }
	testing.expect(t, output[0] == 0 && output[1] == 3 && output[2] == 5)
	snapshot: [3]f32
	copy(snapshot[:], output)
	output, ok = SequentialPredict(&model, input[1:2])
	testing.expect(t, ok && len(output) == 1 && output[0] == 3)
	testing.expect(t, snapshot == [3]f32{0, 3, 5})
	output, ok = SequentialPredict(&model, input[:])
	testing.expect(t, ok && len(output) == 3 && output[0] == 0 && output[1] == 3 && output[2] == 5)
	target := [3]f32{0, 3, 5}
	_, ok = SequentialFit(&model, input[:1], target[:1], epochs = 1)
	testing.expect(t, ok)
	loss, fitOk := SequentialFit(&model, input[:], target[:], epochs = 1)
	testing.expect(t, fitOk && loss == 0)
}

@(test)
SequentialLossesAndErrors :: proc(t: ^testing.T) {
	model: Sequential(1, 2, 2)
	testing.expect(t, SequentialInit(&model, 1) && SequentialAddDense(&model, 1))
	model.layers[0].weightData[0] = 1
	input := [2]f32{0, 2}
	target := [2]f32{0, 1}
	losses := [4]SequentialLoss{MSE{}, MAE{}, Huber{1}, BCEWithLogits{}}
	expected := [4]f32{0.5, 0.5, 0.25, 0.4100376}
	for loss, i in losses {
		value, ok := SequentialFit(&model, input[:], target[:], loss, epochs = 0)
		testing.expect(t, ok && math.abs(value - expected[i]) < 0.00001)
	}
	testing.expect(t, model.layers[0].weightData[0] == 1 && model.layers[0].biasData[0] == 0)
	_, ok := SequentialFit(&model, input[:], target[:1])
	testing.expect(t, !ok)
	_, ok = SequentialFit(&model, input[:], target[:], epochs = -1)
	testing.expect(t, !ok)
	for rate in ([4]f32{0, -1, transmute(f32)u32(0x7f800000), transmute(f32)u32(0x7fc00000)}) {
		_, ok = SequentialFit(&model, input[:], target[:], learningRate = rate)
		testing.expect(t, !ok)
	}
	for delta in ([4]f32{0, -1, transmute(f32)u32(0x7f800000), transmute(f32)u32(0x7fc00000)}) {
		_, ok = SequentialFit(&model, input[:], target[:], Huber{delta}, epochs = 0)
		testing.expect(t, !ok)
	}
	_, ok = SequentialFit(&model, input[:], target[:], nil, epochs = 0)
	testing.expect(t, !ok)
	nonFinite := [2]f32{0, transmute(f32)u32(0x7fc00000)}
	_, ok = SequentialFit(&model, input[:], nonFinite[:], epochs = 0)
	testing.expect(t, !ok)
	badTarget := [2]f32{0, 2}
	_, ok = SequentialFit(&model, input[:], badTarget[:], BCEWithLogits{}, epochs = 1)
	testing.expect(t, !ok)
	for loss in losses {
		model.layers[0].weightData[0] = 1
		model.layers[0].biasData[0] = 0
		before, beforeOk := SequentialFit(&model, input[:], target[:], loss, epochs = 0)
		after, afterOk := SequentialFit(&model, input[:], target[:], loss, epochs = 1, learningRate = 0.1)
		testing.expect(t, beforeOk && afterOk && after < before)
	}
}

@(test)
SequentialRepeatedTraining :: proc(t: ^testing.T) {
	a, b: Sequential(1, 1, 4)
	testing.expect(t, SequentialInit(&a, 1, 7) && SequentialInit(&b, 1, 7))
	testing.expect(t, SequentialAddDense(&a, 1) && SequentialAddDense(&b, 1))
	inputs := [4]f32{-1, 0, 1, 2}
	targets := [4]f32{-1, 1, 3, 5}
	_, ok1 := SequentialFit(&a, inputs[:], targets[:], epochs = 30)
	loss1, ok2 := SequentialFit(&a, inputs[:], targets[:], epochs = 70)
	loss2, ok3 := SequentialFit(&b, inputs[:], targets[:], epochs = 100)
	testing.expect(t, ok1 && ok2 && ok3 && loss1 < 0.0001 && loss1 == loss2)
	testing.expect(t, a.layers[0].weightData[0] == b.layers[0].weightData[0] && a.layers[0].biasData[0] == b.layers[0].biasData[0])
}

@(test)
SequentialXOR :: proc(t: ^testing.T) {
	model: Sequential(4, 4, 4)
	testing.expect(t, SequentialInit(&model, 2, 42))
	testing.expect(t, SequentialAddDense(&model, 4) && SequentialAddActivation(&model, .Tanh))
	testing.expect(t, SequentialAddDense(&model, 1) && SequentialAddActivation(&model, .Sigmoid))
	inputs := [8]f32{0, 0, 0, 1, 1, 0, 1, 1}
	targets := [4]f32{0, 1, 1, 0}
	loss, ok := SequentialFit(&model, inputs[:], targets[:], epochs = 10000, learningRate = 0.5)
	testing.expect(t, ok && loss < 0.01)
	output, predicted := SequentialPredict(&model, inputs[:])
	if !predicted { testing.expect(t, false); return }
	for value, i in output { testing.expect(t, math.abs(value - targets[i]) < 0.15) }
}

@(test)
SequentialNumericalGradient :: proc(t: ^testing.T) {
	model: Sequential(3, 2, 2)
	testing.expect(t, SequentialInit(&model, 2, 123))
	testing.expect(t, SequentialAddDense(&model, 2) && SequentialAddActivation(&model, .Tanh) && SequentialAddDense(&model, 1))
	inputs := [4]f32{0.2, -0.7, 1, 0.4}
	targets := [2]f32{0.3, -0.2}
	// A single SGD step exposes the gradients computed by the complete fit path.
	_, ok := SequentialFit(&model, inputs[:], targets[:], epochs = 1, learningRate = 0.01)
	testing.expect(t, ok)
	for layer in ([2]int{0, 2}) {
		item := &model.layers[layer]
		for i in 0..<len(item.weights.value.data) {
			gradient := item.weightGrad[i]
			// Restore the pre-update parameter before taking finite differences.
			item.weightData[i] += 0.01 * gradient
		}
		for i in 0..<len(item.bias.value.data) { item.biasData[i] += 0.01 * item.biasGrad[i] }
	}
	for layer in ([2]int{0, 2}) {
		item := &model.layers[layer]
		for i in 0..<len(item.weights.value.data) {
			original := item.weightData[i]
			item.weightData[i] = original + 0.001
			plus, plusOk := SequentialFit(&model, inputs[:], targets[:], epochs = 0)
			item.weightData[i] = original - 0.001
			minus, minusOk := SequentialFit(&model, inputs[:], targets[:], epochs = 0)
			item.weightData[i] = original
			testing.expect(t, plusOk && minusOk && math.abs(item.weightGrad[i] - (plus - minus) / 0.002) < 0.0002)
		}
		for i in 0..<len(item.bias.value.data) {
			original := item.biasData[i]
			item.biasData[i] = original + 0.001
			plus, plusOk := SequentialFit(&model, inputs[:], targets[:], epochs = 0)
			item.biasData[i] = original - 0.001
			minus, minusOk := SequentialFit(&model, inputs[:], targets[:], epochs = 0)
			item.biasData[i] = original
			testing.expect(t, plusOk && minusOk && math.abs(item.biasGrad[i] - (plus - minus) / 0.002) < 0.0002)
		}
	}
}
