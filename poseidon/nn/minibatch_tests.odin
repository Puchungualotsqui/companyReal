package nn

import "../core"
import "core:math"
import "core:testing"

@(test)
MinibatchWeightedEvaluation :: proc(t: ^testing.T) {
	model: Sequential(1, 1, 2)
	testing.expect(t, SequentialInit(&model, 1) && SequentialAddDense(&model, 1))
	TestDenseStorage(&model.layers[0]).weightData[0] = 1
	inputs := [5]f32{0, 0, 0, 0, 5}
	targets: [5]f32
	indices: [5]int
	state: u64 = 123
	value, ok := SequentialFitBatches(&model, inputs[:], targets[:], indices[:], &state, epochs = 0)
	testing.expect(t, ok && math.abs(value - 5) < 0.00001 && state == 123)
	testing.expect(t, TestDenseStorage(&model.layers[0]).weightData[0] == 1 && TestDenseStorage(&model.layers[0]).biasData[0] == 0)
	value, ok = SequentialFitBatches(&model, inputs[:], targets[:], indices[:], nil, batchSize = 1, loss = MAE{}, epochs = 0)
	testing.expect(t, ok && math.abs(value - 1) < 0.00001)
}

@(test)
MinibatchFullBatchSGD :: proc(t: ^testing.T) {
	a, b: Sequential(3, 2, 4)
	testing.expect(t, SequentialInit(&a, 2, 17) && SequentialInit(&b, 2, 17))
	testing.expect(t, SequentialAddDense(&a, 2) && SequentialAddActivation(&a, .Tanh) && SequentialAddDense(&a, 1))
	testing.expect(t, SequentialAddDense(&b, 2) && SequentialAddActivation(&b, .Tanh) && SequentialAddDense(&b, 1))
	inputs := [8]f32{1, 2, -1, 3, 0, 1, 2, -2}
	targets := [4]f32{1, -1, 0.5, 2}
	indices: [4]int
	oldLoss, oldOk := SequentialFit(&a, inputs[:], targets[:], epochs = 8, learningRate = 0.03)
	newLoss, newOk := SequentialFitBatches(&b, inputs[:], targets[:], indices[:], nil, epochs = 8, optimizer = SequentialSGD{0.03}, shuffle = false)
	testing.expect(t, oldOk && newOk && math.abs(oldLoss-newLoss) < 0.000001)
	for layer in ([2]int{0, 2}) {
		for v, i in TestDenseStorage(&a.layers[layer]).weights.value.data { testing.expect(t, math.abs(v-TestDenseStorage(&b.layers[layer]).weightData[i]) < 0.000001) }
		for v, i in TestDenseStorage(&a.layers[layer]).bias.value.data { testing.expect(t, math.abs(v-TestDenseStorage(&b.layers[layer]).biasData[i]) < 0.000001) }
	}
}

@(test)
MinibatchShuffleContinuity :: proc(t: ^testing.T) {
	a, b, c: Sequential(1, 1, 2)
	for model in ([3]^Sequential(1, 1, 2){&a, &b, &c}) {
		testing.expect(t, SequentialInit(model, 1, 7) && SequentialAddDense(model, 1))
	}
	inputs := [5]f32{-2, -1, 0, 1, 3}
	targets := [5]f32{1, 0, 2, -1, 4}
	ia, ib, ic: [5]int
	sa, sb, sc: u64 = 0, 0, 0
	la, oka := SequentialFitBatches(&a, inputs[:], targets[:], ia[:], &sa, epochs = 7)
	_, okb := SequentialFitBatches(&b, inputs[:], targets[:], ib[:], &sb, epochs = 3)
	lb, okb2 := SequentialFitBatches(&b, inputs[:], targets[:], ib[:], &sb, epochs = 4)
	lc, okc := SequentialFitBatches(&c, inputs[:], targets[:], ic[:], &sc, epochs = 7)
	testing.expect(t, oka && okb && okb2 && okc && sa != 0 && sa == sb && sb == sc)
	testing.expect(t, la == lb && lb == lc)
	testing.expect(t, TestDenseStorage(&a.layers[0]).weightData[0] == TestDenseStorage(&b.layers[0]).weightData[0] && TestDenseStorage(&b.layers[0]).weightData[0] == TestDenseStorage(&c.layers[0]).weightData[0])
	testing.expect(t, TestDenseStorage(&a.layers[0]).biasData[0] == TestDenseStorage(&b.layers[0]).biasData[0] && TestDenseStorage(&b.layers[0]).biasData[0] == TestDenseStorage(&c.layers[0]).biasData[0])
}

@(test)
MinibatchAdamContinuity :: proc(t: ^testing.T) {
	a, b: Sequential(1, 1, 2)
	testing.expect(t, SequentialInit(&a, 1, 11) && SequentialInit(&b, 1, 11))
	testing.expect(t, SequentialAddDense(&a, 1) && SequentialAddDense(&b, 1))
	pa, pb: [2]^core.Node
	paramsA, oka := SequentialParameters(&a, pa[:])
	paramsB, okb := SequentialParameters(&b, pb[:])
	testing.expect(t, oka && okb && len(paramsA) == 2 && len(paramsB) == 2)
	ma, va, mb, vb: [2]f32
	adamA := Adam{paramsA, ma[:], va[:], 0, 0.01, 0.9, 0.999, 1e-8}
	adamB := Adam{paramsB, mb[:], vb[:], 0, 0.01, 0.9, 0.999, 1e-8}
	inputs := [5]f32{-2, -1, 0, 1, 3}
	targets := [5]f32{1, 0, 2, -1, 4}
	ia, ib: [5]int
	sa, sb: u64 = 55, 55
	la, ok1 := SequentialFitBatches(&a, inputs[:], targets[:], ia[:], &sa, epochs = 4, optimizer = &adamA)
	_, ok2 := SequentialFitBatches(&b, inputs[:], targets[:], ib[:], &sb, epochs = 1, optimizer = &adamB)
	testing.expect(t, ok2 && adamB.step == 3)
	lb, ok3 := SequentialFitBatches(&b, inputs[:], targets[:], ib[:], &sb, epochs = 3, optimizer = &adamB)
	testing.expect(t, ok1 && ok3 && adamA.step == 12 && adamB.step == 12 && sa == sb && la == lb)
	testing.expect(t, ma == mb && va == vb && ma != [2]f32{} && va != [2]f32{})
	testing.expect(t, TestDenseStorage(&a.layers[0]).weightData[0] == TestDenseStorage(&b.layers[0]).weightData[0] && TestDenseStorage(&a.layers[0]).biasData[0] == TestDenseStorage(&b.layers[0]).biasData[0])
	_, ok4 := SequentialFitBatches(&b, inputs[:], targets[:], ib[:], &sb, epochs = 0, optimizer = &adamB)
	testing.expect(t, ok4 && adamB.step == 12 && sa == sb)
}

@(test)
MinibatchValidation :: proc(t: ^testing.T) {
	model, other: Sequential(1, 2, 2)
	testing.expect(t, SequentialInit(&model, 2) && SequentialAddDense(&model, 1))
	testing.expect(t, SequentialInit(&other, 2) && SequentialAddDense(&other, 1))
	inputs := [6]f32{1, 2, 3, 4, 5, 6}
	targets := [3]f32{0, 1, 0}
	indices: [3]int
	state: u64 = 42
	weight := TestDenseStorage(&model.layers[0]).weightData
	_, ok := SequentialFitBatches(&model, inputs[:], targets[:], indices[:], nil, epochs = 1)
	testing.expect(t, !ok)
	_, ok = SequentialFitBatches(&model, inputs[:5], targets[:], indices[:], &state)
	testing.expect(t, !ok)
	_, ok = SequentialFitBatches(&model, inputs[:], targets[:2], indices[:], &state)
	testing.expect(t, !ok)
	_, ok = SequentialFitBatches(&model, inputs[:], targets[:], indices[:2], &state)
	testing.expect(t, !ok)
	for size in ([2]int{-1, 3}) {
		_, ok = SequentialFitBatches(&model, inputs[:], targets[:], indices[:], &state, batchSize = size)
		testing.expect(t, !ok)
	}
	_, ok = SequentialFitBatches(&model, inputs[:], targets[:], indices[:], &state, epochs = -1)
	testing.expect(t, !ok)
	_, ok = SequentialFitBatches(&model, inputs[:], targets[:], indices[:], &state, loss = Huber{0}, epochs = 0)
	testing.expect(t, !ok)
	_, ok = SequentialFitBatches(&model, inputs[:], targets[:], indices[:], &state, optimizer = SequentialSGD{0})
	testing.expect(t, !ok)
	badTargets := [3]f32{0, 1, 2}
	_, ok = SequentialFitBatches(&model, inputs[:], badTargets[:], indices[:], &state, loss = BCEWithLogits{}, epochs = 1)
	testing.expect(t, !ok)
	badTargets[2] = math.nan_f32()
	_, ok = SequentialFitBatches(&model, inputs[:], badTargets[:], indices[:], &state, epochs = 1)
	testing.expect(t, !ok)
	copyModel := model
	_, ok = SequentialFitBatches(&copyModel, inputs[:], targets[:], indices[:], &state, epochs = 0)
	testing.expect(t, !ok)
	storage, otherStorage: [2]^core.Node
	params, paramsOk := SequentialParameters(&model, storage[:])
	foreignParams, foreignOk := SequentialParameters(&other, otherStorage[:])
	testing.expect(t, paramsOk && foreignOk)
	first, second: [3]f32
	adam := Adam{params, first[:], second[:], 0, 0.01, 0.9, 0.999, 1e-8}
	adam.parameters = foreignParams
	_, ok = SequentialFitBatches(&model, inputs[:], targets[:], indices[:], &state, epochs = 1, optimizer = &adam)
	testing.expect(t, !ok && adam.step == 0 && first == [3]f32{} && second == [3]f32{})
	adam.parameters = params
	storage[0], storage[1] = storage[1], storage[0]
	_, ok = SequentialFitBatches(&model, inputs[:], targets[:], indices[:], &state, epochs = 1, optimizer = &adam)
	testing.expect(t, !ok && adam.step == 0)
	storage[0], storage[1] = storage[1], storage[0]
	adam.step = max(u64)
	_, ok = SequentialFitBatches(&model, inputs[:], targets[:], indices[:], &state, epochs = 1, optimizer = &adam)
	testing.expect(t, !ok && adam.step == max(u64))
	_, ok = SequentialFitBatches(&model, inputs[:], targets[:], indices[:], &state, epochs = 0, optimizer = &adam)
	testing.expect(t, ok && adam.step == max(u64))
	testing.expect(t, state == 42 && TestDenseStorage(&model.layers[0]).weightData == weight && TestDenseStorage(&model.layers[0]).biasData[0] == 0)
}
