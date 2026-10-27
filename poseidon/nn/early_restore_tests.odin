package nn

import "../core"
import "core:math"
import "core:testing"

@(test)
EarlyRestoreReferenceAndResume :: proc(t: ^testing.T) {
	inputs := [5]f32{-2, -1, 0, 1, 3}
	targets := [5]f32{1, 0, 2, -1, 4}
	validation := [3]f32{-1, 0, 2}
	validationTargets := [3]f32{2, -1, 0}
	for useAdam in ([2]bool{false, true}) {
		for stopped in ([2]bool{false, true}) {
			restored, reference, actual: Sequential(1, 1, 2)
			for model in ([3]^Sequential(1, 1, 2){&restored, &reference, &actual}) {
				testing.expect(t, SequentialInit(model, 1, 11) && SequentialAddDense(model, 1))
			}
			pr, pp, pa: [2]^core.Node
			rp, rok := SequentialParameters(&restored, pr[:])
			p, pok := SequentialParameters(&reference, pp[:])
			ap, aok := SequentialParameters(&actual, pa[:])
			testing.expect(t, rok && pok && aok)
			mr, vr, mp, vp, ma, va: [2]f32
			ar := Adam{rp, mr[:], vr[:], 0, 0.01, 0.9, 0.999, 1e-8}
			ax := Adam{p, mp[:], vp[:], 0, 0.01, 0.9, 0.999, 1e-8}
			aa := Adam{ap, ma[:], va[:], 0, 0.01, 0.9, 0.999, 1e-8}
			or: SequentialOptimizer = SequentialSGD{0.05}
			op: SequentialOptimizer = SequentialSGD{0.05}
			oa: SequentialOptimizer = SequentialSGD{0.05}
			if useAdam { or = &ar; op = &ax; oa = &aa }
			ir, ip, ia: [5]int
			sr, sp, sa: u64 = 55, 55, 55
			sentinel := EpochMetrics{99, 123, 456, true}
			history := [4]EpochMetrics{sentinel, sentinel, sentinel, sentinel}
			actualHistory: [4]EpochMetrics
			result := SequentialEarlyStoppingResult{99, 99, 99, true}
			patience := 10
			ran := 4
			if stopped { patience = 2; ran = 3 }
			stop := SequentialEarlyStopping{patience, 1000000, &result}
			snapshot: [1024]u8
			loss, ok := SequentialFitBatches(&restored, inputs[:], targets[:], ir[:], &sr, epochs = 4, optimizer = or, validationInputs = validation[:], validationTargets = validationTargets[:], history = history[:], earlyStopping = &stop, bestSnapshot = snapshot[:])
			bestLoss, bestOk := SequentialFitBatches(&reference, inputs[:], targets[:], ip[:], &sp, epochs = 1, optimizer = op, validationInputs = validation[:], validationTargets = validationTargets[:])
			_, actualOk := SequentialFitBatches(&actual, inputs[:], targets[:], ia[:], &sa, epochs = ran, optimizer = oa, validationInputs = validation[:], validationTargets = validationTargets[:], history = actualHistory[:])
			testing.expect(t, ok && bestOk && actualOk)
			testing.expect(t, result.epochsRan == ran && result.bestEpoch == 1 && result.stopped == stopped && result.bestValidationLoss == history[0].validationLoss)
			testing.expect(t, loss == bestLoss && loss == history[0].trainingLoss)
			for i in 0..<ran { testing.expect(t, history[i] == actualHistory[i] && history[i].epoch == i+1 && history[i].hasValidation) }
			if stopped { testing.expect(t, history[3] == sentinel) }
			testing.expect(t, sr == sp && sr != sa && TestDenseStorage(&restored.layers[0]).weightData == TestDenseStorage(&reference.layers[0]).weightData && TestDenseStorage(&restored.layers[0]).biasData == TestDenseStorage(&reference.layers[0]).biasData)
			if useAdam { testing.expect(t, ar.step == 3 && ar.step == ax.step && mr == mp && vr == vp && mr != [2]f32{} && vr != [2]f32{}) }
			checkpointAdam: ^Adam
			if useAdam { checkpointAdam = &ax }
			encoded: [1024]u8
			size, written := CheckpointWrite(&reference, checkpointAdam, sp, encoded[:])
			testing.expect(t, written && size > 0)
			if written { for b, i in encoded[:size] { testing.expect(t, snapshot[i] == b) } }
			// Restored wiring must remain usable, including after another shuffled update.
			lr, rr := SequentialFitBatches(&restored, inputs[:], targets[:], ir[:], &sr, epochs = 2, optimizer = or)
			lp, rpOk := SequentialFitBatches(&reference, inputs[:], targets[:], ip[:], &sp, epochs = 2, optimizer = op)
			testing.expect(t, rr && rpOk && lr == lp && sr == sp && restored.self == rawptr(&restored))
			testing.expect(t, TestDenseStorage(&restored.layers[0]).weightData == TestDenseStorage(&reference.layers[0]).weightData && TestDenseStorage(&restored.layers[0]).biasData == TestDenseStorage(&reference.layers[0]).biasData)
			if useAdam { testing.expect(t, ar.step == ax.step && ar.step == 9 && mr == mp && vr == vp && pr[0] == &TestDenseStorage(&restored.layers[0]).weights && pr[1] == &TestDenseStorage(&restored.layers[0]).bias) }
		}
	}
}

@(test)
EarlyRestorePreflightAndZeroEpochs :: proc(t: ^testing.T) {
	model: Sequential(1, 1, 2)
	testing.expect(t, SequentialInit(&model, 1, 11) && SequentialAddDense(&model, 1))
	parameters: [2]^core.Node
	params, paramsOk := SequentialParameters(&model, parameters[:])
	testing.expect(t, paramsOk)
	first := [2]f32{1, 2}
	second := [2]f32{3, 4}
	adam := Adam{params, first[:], second[:], 7, 0.01, 0.9, 0.999, 1e-8}
	inputs := [3]f32{-1, 0, 2}
	targets := [3]f32{1, 0, 2}
	indices := [3]int{7, 8, 9}
	state: u64 = 42
	sentinel := EpochMetrics{99, 123, 456, true}
	history := [2]EpochMetrics{sentinel, sentinel}
	originalResult := SequentialEarlyStoppingResult{9, 8, 7, true}
	result := originalResult
	stop := SequentialEarlyStopping{2, 0, &result}
	weights, biases := TestDenseStorage(&model.layers[0]).weightData, TestDenseStorage(&model.layers[0]).biasData
	snapshot: [1024]u8
	for &b in snapshot { b = 0xa5 }
	originalSnapshot := snapshot
	data: [1024]u8
	size, written := CheckpointWrite(&model, &adam, state, data[:])
	testing.expect(t, written && size > 0)
	if !written || size == 0 { return }
	_, ok := SequentialFitBatches(&model, inputs[:], targets[:], indices[:], &state, epochs = 2, optimizer = &adam, validationInputs = inputs[:], validationTargets = targets[:], history = history[:], earlyStopping = &stop, bestSnapshot = snapshot[:size-1])
	testing.expect(t, !ok && snapshot == originalSnapshot && result == originalResult && history == [2]EpochMetrics{sentinel, sentinel} && indices == [3]int{7, 8, 9} && state == 42)
	testing.expect(t, TestDenseStorage(&model.layers[0]).weightData == weights && TestDenseStorage(&model.layers[0]).biasData == biases && adam.step == 7 && first == [2]f32{1, 2} && second == [2]f32{3, 4})
	_, ok = SequentialFitBatches(&model, inputs[:], targets[:], indices[:], &state, epochs = 2, optimizer = &adam, validationInputs = inputs[:], validationTargets = targets[:], history = history[:], bestSnapshot = snapshot[:])
	testing.expect(t, !ok && snapshot == originalSnapshot && history == [2]EpochMetrics{sentinel, sentinel} && state == 42 && indices == [3]int{7, 8, 9} && adam.step == 7)
	copyModel := model
	_, ok = SequentialFitBatches(&copyModel, inputs[:], targets[:], indices[:], &state, epochs = 2, validationInputs = inputs[:], validationTargets = targets[:], history = history[:], earlyStopping = &stop, bestSnapshot = snapshot[:])
	testing.expect(t, !ok && snapshot == originalSnapshot && result == originalResult && state == 42 && indices == [3]int{7, 8, 9})
	zero, zeroOk := SequentialFitBatches(&model, inputs[:], targets[:], indices[:], &state, epochs = 0, optimizer = &adam, validationInputs = inputs[:], validationTargets = targets[:], history = history[:], earlyStopping = &stop, bestSnapshot = snapshot[:0])
	expected, evalOk := HistoryRowLoss(&model, inputs[:], targets[:], MSE{})
	testing.expect(t, zeroOk && evalOk && math.abs(zero-expected) < 0.00001 && result == SequentialEarlyStoppingResult{} && snapshot == originalSnapshot)
	testing.expect(t, state == 42 && indices == [3]int{0, 1, 2} && history == [2]EpochMetrics{sentinel, sentinel} && adam.step == 7 && first == [2]f32{1, 2} && second == [2]f32{3, 4} && TestDenseStorage(&model.layers[0]).weightData == weights && TestDenseStorage(&model.layers[0]).biasData == biases)
}
