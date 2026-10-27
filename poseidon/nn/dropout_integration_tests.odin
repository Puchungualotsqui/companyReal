package nn

import "../core"
import "core:math"
import "core:testing"

DropoutIntegrationModel :: proc(model: ^Sequential(4, 3, 2), seed: u64) -> bool {
	return SequentialInit(model, 2, seed) && SequentialAddDense(model, 3) &&
		SequentialAddActivation(model, .Tanh) && SequentialAddDropout(model, 0.5) && SequentialAddDense(model, 1)
}

@(test)
DropoutSequentialInferenceAndSeededTraining :: proc(t: ^testing.T) {
	a, b: Sequential(1, 3, 2)
	for model in ([2]^Sequential(1, 3, 2){&a, &b}) {
		testing.expect(t, SequentialInit(model, 3, 12345) && SequentialAddDropout(model, 0.5))
	}
	input := [6]f32{1, 2, 3, 4, 5, 6}
	before := a.randomState
	prediction, ok := SequentialPredict(&a, input[:])
	testing.expect(t, ok && a.randomState == before && len(prediction) == len(input))
	if ok { for value, i in prediction { testing.expect(t, value == input[i]) } }
	first, firstOk := SequentialPredict(&a, input[:], true)
	firstCopy: [6]f32
	if firstOk { copy(firstCopy[:], first) }
	second, secondOk := SequentialPredict(&b, input[:], true)
	testing.expect(t, firstOk && secondOk && a.randomState == b.randomState && a.randomState != before)
	if secondOk { for value, i in second { testing.expect(t, value == firstCopy[i] && (value == 0 || value == input[i]*2)) } }
	trainingState := a.randomState
	prediction, ok = SequentialPredict(&a, input[:3])
	testing.expect(t, ok && a.randomState == trainingState && len(prediction) == 3)
	if ok { for value, i in prediction { testing.expect(t, value == input[i]) } }
	_, ok = SequentialPredict(&a, input[:], true)
	_, secondOk = SequentialPredict(&b, input[:], true)
	testing.expect(t, ok && secondOk && a.randomState == b.randomState && TestDropoutStorage(&a.layers[0]).maskData == TestDropoutStorage(&b.layers[0]).maskData)
}

@(test)
DropoutSeededFullBatchFit :: proc(t: ^testing.T) {
	a, b: Sequential(4, 3, 2)
	for model in ([2]^Sequential(4, 3, 2){&a, &b}) { testing.expect(t, DropoutIntegrationModel(model, 31)) }
	inputs := [4]f32{1, -2, 3, 0.5}
	targets := [2]f32{1, -1}
	initial := a.randomState
	la, oka := SequentialFit(&a, inputs[:], targets[:], epochs = 5, learningRate = 0.01)
	lb, okb := SequentialFit(&b, inputs[:], targets[:], epochs = 5, learningRate = 0.01)
	testing.expect(t, oka && okb && la == lb && a.randomState == b.randomState && a.randomState != initial)
	for layer in ([2]int{0, 3}) { testing.expect(t, TestDenseStorage(&a.layers[layer]).weightData == TestDenseStorage(&b.layers[layer]).weightData && TestDenseStorage(&a.layers[layer]).biasData == TestDenseStorage(&b.layers[layer]).biasData) }
}

@(test)
DropoutValidationHistoryAndCheckpointResume :: proc(t: ^testing.T) {
	a, b, restored: Sequential(4, 3, 2)
	for model in ([2]^Sequential(4, 3, 2){&a, &b}) { testing.expect(t, DropoutIntegrationModel(model, 11)) }
	pa, pb, pr: [4]^core.Node
	paramsA, oka := SequentialParameters(&a, pa[:])
	paramsB, okb := SequentialParameters(&b, pb[:])
	testing.expect(t, oka && okb)
	if !oka || !okb { return }
	ma, va, mb, vb, mr, vr: [13]f32
	adamA := Adam{paramsA, ma[:], va[:], 0, 0.01, 0.9, 0.999, 1e-8}
	adamB := Adam{paramsB, mb[:], vb[:], 0, 0.01, 0.9, 0.999, 1e-8}
	inputs := [10]f32{-2, 1, -1, 2, 0, -1, 1, 3, 3, 0.5}
	targets := [5]f32{1, 0, 2, -1, 4}
	validation := [6]f32{-1, 2, 0, 1, 2, -1}
	validationTargets := [3]f32{1, -1, 2}
	ia, ib, ir: [5]int
	sa, sb, sr: u64 = 55, 55, 0
	history: [3]EpochMetrics
	_, ok1 := SequentialFitBatches(&a, inputs[:], targets[:], ia[:], &sa, epochs = 3, optimizer = &adamA)
	_, ok2 := SequentialFitBatches(&b, inputs[:], targets[:], ib[:], &sb, epochs = 3, optimizer = &adamB, validationInputs = validation[:], validationTargets = validationTargets[:], history = history[:])
	testing.expect(t, ok1 && ok2 && sa == sb && a.randomState == b.randomState && ma == mb && va == vb && adamA.step == adamB.step)
	for item, i in history { testing.expect(t, item.epoch == i+1 && item.hasValidation) }
	data, again: [1024]u8
	size, written := CheckpointWrite(&b, &adamB, sb, data[:])
	sizeA, writtenA := CheckpointWrite(&a, &adamA, sa, again[:])
	testing.expect(t, written && writtenA && size == sizeA)
	if !written || !writtenA || size != sizeA { return }
	for value, i in data[:size] { testing.expect(t, value == again[i]) }
	adamR: Adam
	read := CheckpointRead(&restored, &adamR, &sr, data[:size], pr[:], mr[:], vr[:])
	testing.expect(t, read && sr == sb && restored.randomState == b.randomState && mr == mb && vr == vb)
	if !read { return }
	dropout, isDropout := restored.layers[2].layer.(^Dropout)
	testing.expect(t, isDropout && dropout != nil)
	if isDropout && dropout != nil { testing.expect(t, dropout.rate == 0.5 && dropout.randomState == &restored.randomState) }
	sizeR, writtenR := CheckpointWrite(&restored, &adamR, sr, again[:])
	testing.expect(t, writtenR && sizeR == size)
	if writtenR && sizeR == size { for value, i in data[:size] { testing.expect(t, value == again[i]) } }
	la, ok3 := SequentialFitBatches(&a, inputs[:], targets[:], ia[:], &sa, epochs = 4, optimizer = &adamA)
	lr, ok4 := SequentialFitBatches(&restored, inputs[:], targets[:], ir[:], &sr, epochs = 4, optimizer = &adamR)
	testing.expect(t, ok3 && ok4 && la == lr && sa == sr && a.randomState == restored.randomState && adamA.step == 21 && adamR.step == adamA.step && ma == mr && va == vr)
	for layer in ([2]int{0, 3}) {
		testing.expect(t, TestDenseStorage(&a.layers[layer]).weightData == TestDenseStorage(&restored.layers[layer]).weightData && TestDenseStorage(&a.layers[layer]).biasData == TestDenseStorage(&restored.layers[layer]).biasData)
	}
}

@(test)
DropoutEarlyStoppingRestoresRandomState :: proc(t: ^testing.T) {
	restored, reference, actual: Sequential(4, 3, 2)
	for model in ([3]^Sequential(4, 3, 2){&restored, &reference, &actual}) { testing.expect(t, DropoutIntegrationModel(model, 11)) }
	pr, pp, pa: [4]^core.Node
	rp, rok := SequentialParameters(&restored, pr[:])
	p, pok := SequentialParameters(&reference, pp[:])
	ap, aok := SequentialParameters(&actual, pa[:])
	testing.expect(t, rok && pok && aok)
	if !rok || !pok || !aok { return }
	mr, vr, mp, vp, ma, va: [13]f32
	ar := Adam{rp, mr[:], vr[:], 0, 0.01, 0.9, 0.999, 1e-8}
	ax := Adam{p, mp[:], vp[:], 0, 0.01, 0.9, 0.999, 1e-8}
	aa := Adam{ap, ma[:], va[:], 0, 0.01, 0.9, 0.999, 1e-8}
	inputs := [10]f32{-2, 1, -1, 2, 0, -1, 1, 3, 3, 0.5}
	targets := [5]f32{1, 0, 2, -1, 4}
	ir, ip, ia: [5]int
	sr, sp, sa: u64 = 55, 55, 55
	history: [4]EpochMetrics
	result: SequentialEarlyStoppingResult
	stop := SequentialEarlyStopping{2, 1000000, &result}
	snapshot, expected: [1024]u8
	loss, ok := SequentialFitBatches(&restored, inputs[:], targets[:], ir[:], &sr, epochs = 4, optimizer = &ar, validationInputs = inputs[:], validationTargets = targets[:], history = history[:], earlyStopping = &stop, bestSnapshot = snapshot[:])
	best, ok2 := SequentialFitBatches(&reference, inputs[:], targets[:], ip[:], &sp, epochs = 1, optimizer = &ax)
	_, ok3 := SequentialFitBatches(&actual, inputs[:], targets[:], ia[:], &sa, epochs = 3, optimizer = &aa)
	testing.expect(t, ok && ok2 && ok3 && result.stopped && result.epochsRan == 3 && result.bestEpoch == 1 && loss == best)
	testing.expect(t, sr == sp && sr != sa && restored.randomState == reference.randomState && restored.randomState != actual.randomState && ar.step == ax.step && mr == mp && vr == vp)
	size, written := CheckpointWrite(&reference, &ax, sp, expected[:])
	testing.expect(t, written)
	if written { for value, i in expected[:size] { testing.expect(t, value == snapshot[i]) } }
	lr, ok4 := SequentialFitBatches(&restored, inputs[:], targets[:], ir[:], &sr, epochs = 2, optimizer = &ar)
	lp, ok5 := SequentialFitBatches(&reference, inputs[:], targets[:], ip[:], &sp, epochs = 2, optimizer = &ax)
	testing.expect(t, ok4 && ok5 && lr == lp && sr == sp && restored.randomState == reference.randomState && ar.step == ax.step && mr == mp && vr == vp)
	for layer in ([2]int{0, 3}) { testing.expect(t, TestDenseStorage(&restored.layers[layer]).weightData == TestDenseStorage(&reference.layers[layer]).weightData && TestDenseStorage(&restored.layers[layer]).biasData == TestDenseStorage(&reference.layers[layer]).biasData) }
}

@(test)
DropoutTrailingLogitsRejection :: proc(t: ^testing.T) {
	for scenario in 0..<3 {
		model: Sequential(4, 2, 2)
		activation := ActivationKind.Sigmoid
		loss: SequentialLoss = BCEWithLogits{}
		if scenario > 0 { activation = .Softmax }
		if scenario == 2 { loss = CCEWithLogits{} }
		ok := SequentialInit(&model, 2, 7) && SequentialAddDense(&model, 2) && SequentialAddActivation(&model, activation) && SequentialAddDropout(&model, 0.2) && SequentialAddDropout(&model, 0.5)
		testing.expect(t, ok)
		if !ok { return }
		inputs := [4]f32{1, 2, 3, 4}
		targets := [4]f32{1, 0, 0, 1}
		indices := [2]int{8, 9}
		state: u64 = 42
		rng, weights, bias := model.randomState, TestDenseStorage(&model.layers[0]).weightData, TestDenseStorage(&model.layers[0]).biasData
		_, fullOk := SequentialFit(&model, inputs[:], targets[:], loss = loss, epochs = 1)
		_, batchOk := SequentialFitBatches(&model, inputs[:], targets[:], indices[:], &state, loss = loss, epochs = 1)
		testing.expect(t, !fullOk && !batchOk && state == 42 && indices == [2]int{8, 9} && model.randomState == rng && TestDenseStorage(&model.layers[0]).weightData == weights && TestDenseStorage(&model.layers[0]).biasData == bias)
	}
}

@(test)
DropoutCheckpointRateValidation :: proc(t: ^testing.T) {
	source, destination: Sequential(1, 2, 2)
	testing.expect(t, SequentialInit(&source, 2, 7) && SequentialAddDropout(&source, 0.25))
	testing.expect(t, SequentialInit(&destination, 2, 9) && SequentialAddDropout(&destination, 0.75))
	data, before, after: [256]u8
	size, ok := CheckpointWrite(&source, nil, 42, data[:])
	beforeSize, beforeOk := CheckpointWrite(&destination, nil, 123, before[:])
	testing.expect(t, ok && beforeOk && size == 100)
	if !ok || !beforeOk || size != 100 { return }
	for rate in ([5]f32{-0.1, 1, math.nan_f32(), math.inf_f32(1), math.inf_f32(-1)}) {
		bad := data
		position := 96
		CheckpointPut32(bad[:], &position, rate)
		shuffle: u64 = 123
		testing.expect(t, !CheckpointRead(&destination, nil, &shuffle, bad[:size], nil, nil, nil) && shuffle == 123)
		afterSize, afterOk := CheckpointWrite(&destination, nil, shuffle, after[:])
		testing.expect(t, afterOk && afterSize == beforeSize)
		if afterOk && afterSize == beforeSize { for value, i in before[:beforeSize] { testing.expect(t, value == after[i]) } }
		dropout := &source.layers[0].operation.(Dropout)
		dropout.rate = rate
		for &value in after { value = 0xa5 }
		count, writeOk := CheckpointWrite(&source, nil, 42, after[:])
		testing.expect(t, !writeOk && count == 0)
		for value in after { testing.expect(t, value == 0xa5) }
		dropout.rate = 0.25
	}
	for rate in ([3]f32{0, 0.25, transmute(f32)u32(0x3f7fffff)}) {
		sourceDropout := &source.layers[0].operation.(Dropout)
		sourceDropout.rate = rate
		encodedSize, encoded := CheckpointWrite(&source, nil, 42, data[:])
		shuffle: u64
		read := encoded && CheckpointRead(&destination, nil, &shuffle, data[:encodedSize], nil, nil, nil)
		testing.expect(t, read && shuffle == 42)
		if !read { continue }
		dropout, isDropout := destination.layers[0].layer.(^Dropout)
		testing.expect(t, isDropout && dropout != nil)
		if isDropout && dropout != nil { testing.expect(t, dropout.rate == rate && dropout.randomState == &destination.randomState) }
	}
}
