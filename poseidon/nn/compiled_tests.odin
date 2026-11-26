package nn

import "../core"
import "core:testing"

@(test)
CompiledSequentialMatchesBatches :: proc(t: ^testing.T) {
	a, b: Sequential(1, 1, 2)
	testing.expect(t, SequentialInit(&a, 1, 7) && SequentialAddDense(&a, 1))
	testing.expect(t, SequentialInit(&b, 1, 7) && SequentialAddDense(&b, 1))
	pa, pb: [2]^core.Node
	paramsA, oka := SequentialParameters(&a, pa[:])
	paramsB, okb := SequentialParameters(&b, pb[:])
	testing.expect(t, oka && okb)
	ma, va, mb, vb: [2]f32
	adamA := Adam{paramsA, ma[:], va[:], 0, 0.01, 0.9, 0.999, 1e-8}
	adamB := Adam{paramsB, mb[:], vb[:], 0, 0.01, 0.9, 0.999, 1e-8}
	compiled: CompiledSequential(1, 1, 2)
	testing.expect(t, SequentialCompile(&compiled, &a, MAE{}, &adamA))
	inputs := [5]f32{-2, -1, 0, 1, 3}
	targets := [5]f32{1, 0, 2, -1, 4}
	ia, ib: [5]int
	sa, sb: u64 = 55, 55
	ha, hb: [3]EpochMetrics
	options := SequentialFitOptionsDefault()
	options.epochs = 3
	options.validationInputs, options.validationTargets, options.history = inputs[:], targets[:], ha[:]
	la, ca := CompiledSequentialFitWithOptions(&compiled, inputs[:], targets[:], ia[:], &sa, options)
	lb, cb := SequentialFitBatches(&b, inputs[:], targets[:], ib[:], &sb, loss = MAE{}, epochs = 3, optimizer = &adamB, validationInputs = inputs[:], validationTargets = targets[:], history = hb[:])
	testing.expect(t, ca && cb && la == lb && sa == sb && ia == ib && ha == hb)
	testing.expect(t, adamA.step == 9 && adamA.step == adamB.step && ma == mb && va == vb)
	testing.expect(t, TestDenseStorage(&a.layers[0]).weightData == TestDenseStorage(&b.layers[0]).weightData && TestDenseStorage(&a.layers[0]).biasData == TestDenseStorage(&b.layers[0]).biasData)
	ea, eoka := CompiledSequentialEvaluate(&compiled, inputs[:], targets[:])
	eb, eokb := SequentialEvaluateBatches(&b, inputs[:], targets[:], 2, MAE{})
	testing.expect(t, eoka && eokb && ea == eb && adamA.step == 9 && sa == sb)
	predictionsA, predictionsB: [5]f32
	predictA := CompiledSequentialPredict(&compiled, inputs[:], predictionsA[:])
	predictB := SequentialPredictBatches(&b, inputs[:], predictionsB[:])
	testing.expect(t, predictA && predictB && predictionsA == predictionsB && adamA.step == 9)
}

@(test)
CompiledSequentialInvalidAndRecompile :: proc(t: ^testing.T) {
	model: Sequential(1, 1, 2)
	compiled: CompiledSequential(1, 1, 2)
	inputs := [2]f32{1, 2}
	targets := [2]f32{0, 0}
	indices := [2]int{8, 9}
	state: u64 = 42
	output := [2]f32{7, 8}
	testing.expect(t, !CompiledSequentialPredict(&compiled, inputs[:], output[:]) && output == [2]f32{7, 8})
	_, ok := CompiledSequentialFit(&compiled, inputs[:], targets[:], indices[:], &state, epochs = 1)
	testing.expect(t, !ok && indices == [2]int{8, 9} && state == 42)
	testing.expect(t, !SequentialCompile(&compiled, &model))
	testing.expect(t, SequentialInit(&model, 1) && SequentialAddDense(&model, 1))
	testing.expect(t, SequentialCompile(&compiled, &model, MSE{}))
	testing.expect(t, !SequentialCompile(&compiled, nil) && compiled.model == &model)
	_, ok = CompiledSequentialFit(&compiled, inputs[:], targets[:], indices[:], &state, batchSize = 3, epochs = 1)
	testing.expect(t, !ok && indices == [2]int{8, 9} && state == 42)
	_, ok = CompiledSequentialEvaluate(&compiled, inputs[:], targets[:], -1)
	testing.expect(t, !ok)
	testing.expect(t, SequentialCompile(&compiled, &model, MAE{}))
	actual, aok := CompiledSequentialEvaluate(&compiled, inputs[:], targets[:], 1)
	expected, eok := SequentialEvaluateBatches(&model, inputs[:], targets[:], 1, MAE{})
	testing.expect(t, aok && eok && actual == expected)
}

@(test)
CompiledSequentialFitOptionsDefaultsAndZeroEpochs :: proc(t: ^testing.T) {
	defaults := SequentialFitOptionsDefault()
	testing.expect(t, defaults.batchSize == 0 && defaults.epochs == 200 && defaults.shuffle && defaults.l2 == 0)
	model: Sequential(1, 1, 2)
	compiled: CompiledSequential(1, 1, 2)
	initialized := SequentialInit(&model, 1, 42) && SequentialAddDense(&model, 1) && SequentialCompile(&compiled, &model)
	testing.expect(t, initialized)
	if !initialized { return }
	inputs := [2]f32{1, 2}
	targets := [2]f32{2, 4}
	indices: [2]int
	state: u64 = 13
	weights := TestDenseStorage(&model.layers[0]).weightData
	loss, ok := CompiledSequentialFitWithOptions(&compiled, inputs[:], targets[:], indices[:], &state, {})
	expected, evaluated := CompiledSequentialEvaluate(&compiled, inputs[:], targets[:])
	testing.expect(t, ok && evaluated && loss == expected && state == 13)
	testing.expect(t, TestDenseStorage(&model.layers[0]).weightData == weights)
	options := SequentialFitOptionsDefault()
	options.epochs = -1
	beforeIndices, beforeState := indices, state
	_, ok = CompiledSequentialFitWithOptions(&compiled, inputs[:], targets[:], indices[:], &state, options)
	testing.expect(t, !ok && indices == beforeIndices && state == beforeState)
}

@(test)
CompiledSequentialFitOptionsOmittedUsesDefaults :: proc(t: ^testing.T) {
	model, reference: Sequential(1, 1, 2)
	initialized := SequentialInit(&model, 1, 29) && SequentialAddDense(&model, 1) &&
		SequentialInit(&reference, 1, 29) && SequentialAddDense(&reference, 1)
	testing.expect(t, initialized)
	if !initialized { return }
	compiled, referenceCompiled: CompiledSequential(1, 1, 2)
	testing.expect(t, SequentialCompile(&compiled, &model) && SequentialCompile(&referenceCompiled, &reference))
	inputs := [2]f32{-1, 1}
	targets := [2]f32{-2, 2}
	indices, referenceIndices: [2]int
	state, referenceState: u64 = 7, 7
	loss, ok := CompiledSequentialFitWithOptions(&compiled, inputs[:], targets[:], indices[:], &state)
	referenceLoss, referenceOk := CompiledSequentialFitWithOptions(
		&referenceCompiled, inputs[:], targets[:], referenceIndices[:], &referenceState, SequentialFitOptionsDefault(),
	)
	testing.expect(t, ok && referenceOk && loss == referenceLoss && state == referenceState && indices == referenceIndices)
	testing.expect(t, TestDenseStorage(&model.layers[0]).weightData == TestDenseStorage(&reference.layers[0]).weightData)
}

@(test)
CompiledSequentialFitOptionsForwardEarlyStoppingAndRestore :: proc(t: ^testing.T) {
	model, reference: Sequential(1, 1, 2)
	initialized := SequentialInit(&model, 1, 9) && SequentialAddDense(&model, 1) &&
		SequentialInit(&reference, 1, 9) && SequentialAddDense(&reference, 1)
	testing.expect(t, initialized)
	if !initialized { return }
	compiled: CompiledSequential(1, 1, 2)
	testing.expect(t, SequentialCompile(&compiled, &model, MSE{}, SequentialSGD{0.05}))
	inputs := [3]f32{-1, 0, 1}
	targets := [3]f32{-1, 1, 3}
	indices, referenceIndices: [3]int
	history, referenceHistory: [4]EpochMetrics
	snapshot, referenceSnapshot: [1024]u8
	result, referenceResult: SequentialEarlyStoppingResult
	stopping := SequentialEarlyStopping{patience = 1, minDelta = 1e6, result = &result}
	referenceStopping := SequentialEarlyStopping{patience = 1, minDelta = 1e6, result = &referenceResult}
	options := SequentialFitOptionsDefault()
	options.batchSize, options.epochs, options.shuffle = 1, 4, false
	options.validationInputs, options.validationTargets = inputs[:], targets[:]
	options.history, options.l2, options.earlyStopping, options.bestSnapshot = history[:], 0.01, &stopping, snapshot[:]
	loss, ok := CompiledSequentialFitWithOptions(&compiled, inputs[:], targets[:], indices[:], nil, options)
	referenceLoss, referenceOk := SequentialFitBatches(
		&reference, inputs[:], targets[:], referenceIndices[:], nil,
		batchSize = 1, epochs = 4, optimizer = SequentialSGD{0.05}, shuffle = false,
		validationInputs = inputs[:], validationTargets = targets[:], history = referenceHistory[:],
		l2 = 0.01, earlyStopping = &referenceStopping, bestSnapshot = referenceSnapshot[:],
	)
	testing.expect(t, ok && referenceOk && loss == referenceLoss && result == referenceResult && result.stopped)
	testing.expect(t, history == referenceHistory && indices == referenceIndices)
	testing.expect(t, TestDenseStorage(&model.layers[0]).weightData == TestDenseStorage(&reference.layers[0]).weightData)
	testing.expect(t, TestDenseStorage(&model.layers[0]).biasData == TestDenseStorage(&reference.layers[0]).biasData)
}
