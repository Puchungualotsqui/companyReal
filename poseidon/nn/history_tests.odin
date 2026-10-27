package nn

import "../core"
import "core:math"
import "core:testing"

// Evaluate one row at a time using the public prediction and loss APIs.
HistoryRowLoss :: proc(model: ^Sequential(1, 1, 2), inputs, targets: []f32, loss: SequentialLoss) -> (f32, bool) {
	total: f64
	for _, i in inputs {
		data, ok := SequentialPredict(model, inputs[i:i+1])
		if !ok { return 0, false }
		shape := [2]int{1, 1}
		prediction := core.Tensor{shape[:], data}
		target := core.Tensor{shape[:], targets[i:i+1]}
		value: f32
		switch option in loss {
		case nil: return 0, false
		case MSE: value, ok = MeanSquaredError(prediction, target)
		case MAE: value, ok = MeanAbsoluteError(prediction, target)
		case Huber: value, ok = HuberLoss(prediction, target, option.delta)
		case BCEWithLogits: value, ok = BinaryCrossEntropyWithLogits(prediction, target)
		case CCEWithLogits: value, ok = CategoricalCrossEntropyWithLogits(prediction, target)
		}
		if !ok { return 0, false }
		total += f64(value)

	}
	return f32(total / f64(len(inputs))), true
}

@(test)
HistoryPostUpdateLosses :: proc(t: ^testing.T) {
	inputs := [5]f32{-2, -1, 0, 1, 3}
	targets := [5]f32{0, 0, 1, 1, 1}
	validationInputs := [7]f32{-3, -2, -1, 0, 1, 2, 4}
	validationTargets := [7]f32{0, 0, 0, 1, 1, 1, 1}
	for loss in ([4]SequentialLoss{MSE{}, MAE{}, Huber{0.7}, BCEWithLogits{}}) {
		full, split: Sequential(1, 1, 2)
		testing.expect(t, SequentialInit(&full, 1, 17) && SequentialAddDense(&full, 1))
		testing.expect(t, SequentialInit(&split, 1, 17) && SequentialAddDense(&split, 1))
		indicesA, indicesB: [5]int
		stateA, stateB: u64 = 33, 33
		history: [4]EpochMetrics
		result, ok := SequentialFitBatches(&full, inputs[:], targets[:], indicesA[:], &stateA, loss = loss, epochs = 4, optimizer = SequentialSGD{0.05}, validationInputs = validationInputs[:], validationTargets = validationTargets[:], history = history[:])
		testing.expect(t, ok)
		for epoch in 0..<4 {
			oneLoss, oneOk := SequentialFitBatches(&split, inputs[:], targets[:], indicesB[:], &stateB, loss = loss, epochs = 1, optimizer = SequentialSGD{0.05})
			trainLoss, trainOk := HistoryRowLoss(&split, inputs[:], targets[:], loss)
			validationLoss, validationOk := HistoryRowLoss(&split, validationInputs[:], validationTargets[:], loss)
			testing.expect(t, oneOk && trainOk && validationOk)
			testing.expect(t, history[epoch].epoch == epoch + 1 && history[epoch].hasValidation)
			testing.expect(t, math.abs(history[epoch].trainingLoss - trainLoss) < 0.00001 && math.abs(oneLoss - trainLoss) < 0.00001)
			testing.expect(t, math.abs(history[epoch].validationLoss - validationLoss) < 0.00001)
		}
		testing.expect(t, math.abs(result - history[3].trainingLoss) < 0.00001 && stateA == stateB)
		testing.expect(t, TestDenseStorage(&full.layers[0]).weightData == TestDenseStorage(&split.layers[0]).weightData && TestDenseStorage(&full.layers[0]).biasData == TestDenseStorage(&split.layers[0]).biasData)
	}
}

@(test)
HistoryAdamOptionalEvaluationEquivalence :: proc(t: ^testing.T) {
	a, b, c: Sequential(1, 1, 2)
	for model in ([3]^Sequential(1, 1, 2){&a, &b, &c}) {
		testing.expect(t, SequentialInit(model, 1, 11) && SequentialAddDense(model, 1))
	}
	pa, pb, pc: [2]^core.Node
	paramsA, oka := SequentialParameters(&a, pa[:])
	paramsB, okb := SequentialParameters(&b, pb[:])
	paramsC, okc := SequentialParameters(&c, pc[:])
	testing.expect(t, oka && okb && okc)
	ma, va, mb, vb, mc, vc: [2]f32
	adamA := Adam{paramsA, ma[:], va[:], 0, 0.01, 0.9, 0.999, 1e-8}
	adamB := Adam{paramsB, mb[:], vb[:], 0, 0.01, 0.9, 0.999, 1e-8}
	adamC := Adam{paramsC, mc[:], vc[:], 0, 0.01, 0.9, 0.999, 1e-8}
	inputs := [5]f32{-2, -1, 0, 1, 3}
	targets := [5]f32{1, 0, 2, -1, 4}
	validation := [3]f32{2, 0, -1}
	ia, ib, ic: [5]int
	sa, sb, sc: u64 = 55, 55, 55
	historyB, historyC: [4]EpochMetrics
	la, ok1 := SequentialFitBatches(&a, inputs[:], targets[:], ia[:], &sa, epochs = 4, optimizer = &adamA)
	lb, ok2 := SequentialFitBatches(&b, inputs[:], targets[:], ib[:], &sb, epochs = 4, optimizer = &adamB, history = historyB[:])
	lc, ok3 := SequentialFitBatches(&c, inputs[:], targets[:], ic[:], &sc, epochs = 4, optimizer = &adamC, validationInputs = validation[:], validationTargets = validation[:], history = historyC[:])
	testing.expect(t, ok1 && ok2 && ok3 && la == lb && lb == lc && sa == sb && sb == sc && sa != 55)
	testing.expect(t, adamA.step == 12 && adamB.step == 12 && adamC.step == 12 && ma == mb && mb == mc && va == vb && vb == vc && ma != [2]f32{})
	testing.expect(t, TestDenseStorage(&a.layers[0]).weightData == TestDenseStorage(&b.layers[0]).weightData && TestDenseStorage(&b.layers[0]).weightData == TestDenseStorage(&c.layers[0]).weightData)
	testing.expect(t, TestDenseStorage(&a.layers[0]).biasData == TestDenseStorage(&b.layers[0]).biasData && TestDenseStorage(&b.layers[0]).biasData == TestDenseStorage(&c.layers[0]).biasData)
	for item, i in historyB {
		testing.expect(t, !item.hasValidation && item.validationLoss == 0 && item.trainingLoss == historyC[i].trainingLoss && historyC[i].hasValidation)
	}
}

@(test)
HistoryBoundsAndNoEpochs :: proc(t: ^testing.T) {
	model: Sequential(1, 1, 2)
	testing.expect(t, SequentialInit(&model, 1, 3) && SequentialAddDense(&model, 1))
	inputs := [3]f32{1, 2, 3}
	targets := [3]f32{0, 1, 0}
	indices := [3]int{9, 9, 9}
	state: u64 = 42
	sentinel := EpochMetrics{99, 123, 456, true}
	history := [4]EpochMetrics{sentinel, sentinel, sentinel, sentinel}
	weight, bias := TestDenseStorage(&model.layers[0]).weightData, TestDenseStorage(&model.layers[0]).biasData
	_, ok := SequentialFitBatches(&model, inputs[:], targets[:], indices[:], &state, epochs = 2, history = history[1:2])
	testing.expect(t, !ok && history == [4]EpochMetrics{sentinel, sentinel, sentinel, sentinel} && indices == [3]int{9, 9, 9} && state == 42)
	testing.expect(t, TestDenseStorage(&model.layers[0]).weightData == weight && TestDenseStorage(&model.layers[0]).biasData == bias)
	zero, ok0 := SequentialFitBatches(&model, inputs[:], targets[:], indices[:], &state, epochs = 0, validationInputs = inputs[:], validationTargets = targets[:], history = history[1:1])
	expected, evalOk := HistoryRowLoss(&model, inputs[:], targets[:], MSE{})
	testing.expect(t, ok0 && evalOk && math.abs(zero - expected) < 0.00001 && state == 42 && history == [4]EpochMetrics{sentinel, sentinel, sentinel, sentinel})
	_, ok = SequentialFitBatches(&model, inputs[:], targets[:], indices[:], &state, epochs = 2, history = history[1:3])
	testing.expect(t, ok && history[0] == sentinel && history[3] == sentinel && history[1].epoch == 1 && history[2].epoch == 2)
}

@(test)
HistoryValidationPreflight :: proc(t: ^testing.T) {
	model: Sequential(1, 2, 2)
	testing.expect(t, SequentialInit(&model, 2, 9) && SequentialAddDense(&model, 1))
	storage: [2]^core.Node
	params, ok := SequentialParameters(&model, storage[:])
	testing.expect(t, ok)
	first, second: [3]f32
	adam := Adam{params, first[:], second[:], 0, 0.01, 0.9, 0.999, 1e-8}
	inputs := [6]f32{1, 2, 3, 4, 5, 6}
	targets := [3]f32{0, 1, 0}
	valInputs := [6]f32{1, 2, 3, 4, 5, 6}
	valTargets := [3]f32{0, 1, 0}
	badInputs := valInputs
	badInputs[5] = math.nan_f32()
	badTargets := valTargets
	badTargets[2] = math.inf_f32(1)
	badBinary := [3]f32{0, 1, 2}
	indices := [3]int{7, 8, 9}
	state: u64 = 42
	sentinel := EpochMetrics{99, 123, 456, true}
	history := [2]EpochMetrics{sentinel, sentinel}
	weight, bias := TestDenseStorage(&model.layers[0]).weightData, TestDenseStorage(&model.layers[0]).biasData
	for scenario in 0..<8 {
		vi, vt := valInputs[:], valTargets[:]
		loss: SequentialLoss = MSE{}
		switch scenario {
		case 0: vi = nil
		case 1: vt = nil
		case 2: vi = valInputs[:0]
		case 3: vi = valInputs[:5]
		case 4: vt = valTargets[:2]
		case 5: vi = badInputs[:]
		case 6: vt = badTargets[:]
		case 7: vt = badBinary[:]; loss = BCEWithLogits{}
		}
		_, valid := SequentialFitBatches(&model, inputs[:], targets[:], indices[:], &state, loss = loss, epochs = 2, optimizer = &adam, validationInputs = vi, validationTargets = vt, history = history[:])
		testing.expect(t, !valid && state == 42 && indices == [3]int{7, 8, 9} && history == [2]EpochMetrics{sentinel, sentinel})
		testing.expect(t, adam.step == 0 && first == [3]f32{} && second == [3]f32{} && TestDenseStorage(&model.layers[0]).weightData == weight && TestDenseStorage(&model.layers[0]).biasData == bias)
	}
}

@(test)
HistoryCategoricalValidation :: proc(t: ^testing.T) {
    full, split: Sequential(1, 3, 2)
    testing.expect(t, SequentialInit(&full, 1, 12) && SequentialAddDense(&full, 3))
    testing.expect(t, SequentialInit(&split, 1, 12) && SequentialAddDense(&split, 3))
    inputs := [3]f32{-1, 0, 2}
    targets := [9]f32{1, 0, 0, 0, 1, 0, 0, 0, 1}
    validationInputs := [5]f32{-2, -1, 0, 1, 3}
    validationTargets := [15]f32{1, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 1}
    ia, ib: [3]int
    sa, sb: u64 = 71, 71
    history: [2]EpochMetrics
    result, ok := SequentialFitBatches(&full, inputs[:], targets[:], ia[:], &sa, loss = CCEWithLogits{}, epochs = 2, validationInputs = validationInputs[:], validationTargets = validationTargets[:], history = history[:])
    testing.expect(t, ok)
    for epoch in 0..<2 {
        train, splitOk := SequentialFitBatches(&split, inputs[:], targets[:], ib[:], &sb, loss = CCEWithLogits{}, epochs = 1, validationInputs = validationInputs[:], validationTargets = validationTargets[:])
        sum: f64
        for _, i in validationInputs {
            data, predictOk := SequentialPredict(&split, validationInputs[i:i+1])
            shape := [2]int{1, 3}
            value, lossOk := CategoricalCrossEntropyWithLogits(core.Tensor{shape[:], data}, core.Tensor{shape[:], validationTargets[i*3:(i+1)*3]})
            testing.expect(t, predictOk && lossOk)
            sum += f64(value)
        }
        testing.expect(t, splitOk && history[epoch].epoch == epoch + 1 && history[epoch].hasValidation)
        testing.expect(t, math.abs(train - history[epoch].trainingLoss) < 0.00001 && math.abs(f32(sum / 5) - history[epoch].validationLoss) < 0.00001)
    }
    testing.expect(t, result == history[1].trainingLoss && sa == sb && TestDenseStorage(&full.layers[0]).weightData == TestDenseStorage(&split.layers[0]).weightData && TestDenseStorage(&full.layers[0]).biasData == TestDenseStorage(&split.layers[0]).biasData)
    invalid := validationTargets
    invalid[14] = 2
    beforeWeight, beforeBias := TestDenseStorage(&full.layers[0]).weightData, TestDenseStorage(&full.layers[0]).biasData
    beforeState, beforeIndices, beforeHistory := sa, ia, history
    _, valid := SequentialFitBatches(&full, inputs[:], targets[:], ia[:], &sa, loss = CCEWithLogits{}, epochs = 2, validationInputs = validationInputs[:], validationTargets = invalid[:], history = history[:])
    testing.expect(t, !valid && sa == beforeState && ia == beforeIndices && history == beforeHistory && TestDenseStorage(&full.layers[0]).weightData == beforeWeight && TestDenseStorage(&full.layers[0]).biasData == beforeBias)
}
