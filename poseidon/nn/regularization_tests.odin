package nn

import "../core"
import "core:math"
import "core:testing"

@(test)
RegularizationAnalyticalSteps :: proc(t: ^testing.T) {
	for useAdam in ([2]bool{false, true}) {
		model: Sequential(3, 1, 1)
		testing.expect(t, SequentialInit(&model, 1) && SequentialAddDense(&model, 1) && SequentialAddActivation(&model, .Relu) && SequentialAddDense(&model, 1))
		TestDenseStorage(&model.layers[0]).weightData[0] = 2
		TestDenseStorage(&model.layers[0]).biasData[0] = 1
		TestDenseStorage(&model.layers[2]).weightData[0] = 3
		TestDenseStorage(&model.layers[2]).biasData[0] = 1
		// x=1 gives prediction 10, target 8: data gradients are 12, 12, 12, 4.
		// L2 adds 1 and 1.5 to the respective weights, but nothing to biases.
		storage: [4]^core.Node
		params, valid := SequentialParameters(&model, storage[:])
		testing.expect(t, valid)
		first, second: [4]f32
		adam := Adam{params, first[:], second[:], 0, 0.1, 0.5, 0.5, 0.01}
		optimizer: SequentialOptimizer = SequentialSGD{0.1}
		if useAdam { optimizer = &adam }
		input, target := [1]f32{1}, [1]f32{8}
		indices: [1]int
		value, ok := SequentialFitBatches(&model, input[:], target[:], indices[:], nil, epochs = 1, optimizer = optimizer, shuffle = false, l2 = 0.5)
		testing.expect(t, ok)
		gradients := [4]f32{13, 12, 13.5, 4}
		actual := [4]f32{TestDenseStorage(&model.layers[0]).weightData[0], TestDenseStorage(&model.layers[0]).biasData[0], TestDenseStorage(&model.layers[2]).weightData[0], TestDenseStorage(&model.layers[2]).biasData[0]}
		original := [4]f32{2, 1, 3, 1}
		for gradient, i in gradients {
			expected := original[i] - 0.1 * gradient
			if useAdam {
				expected = original[i] - 0.1 * gradient / (gradient + 0.01)
				testing.expect(t, math.abs(first[i] - 0.5 * gradient) < 0.00001 && math.abs(second[i] - 0.5 * gradient * gradient) < 0.00001)
			}
			testing.expect(t, math.abs(actual[i] - expected) < 0.00001)
		}
		testing.expect(t, math.abs(TestDenseStorage(&model.layers[0]).weightGrad[0] - 13) < 0.00001 && math.abs(TestDenseStorage(&model.layers[0]).biasGrad[0] - 12) < 0.00001)
		testing.expect(t, math.abs(TestDenseStorage(&model.layers[2]).weightGrad[0] - 13.5) < 0.00001 && math.abs(TestDenseStorage(&model.layers[2]).biasGrad[0] - 4) < 0.00001)
		prediction, predicted := SequentialPredict(&model, input[:])
		if predicted { testing.expect(t, math.abs(value - (prediction[0] - 8) * (prediction[0] - 8)) < 0.00001) }
		testing.expect(t, predicted)
		if useAdam { testing.expect(t, adam.step == 1) }
	}
}

@(test)
RegularizationDisabledEquivalence :: proc(t: ^testing.T) {
	for useAdam in ([2]bool{false, true}) {
		a, b: Sequential(1, 1, 2)
		testing.expect(t, SequentialInit(&a, 1, 17) && SequentialAddDense(&a, 1))
		testing.expect(t, SequentialInit(&b, 1, 17) && SequentialAddDense(&b, 1))
		pa, pb: [2]^core.Node
		paramsA, oka := SequentialParameters(&a, pa[:])
		paramsB, okb := SequentialParameters(&b, pb[:])
		testing.expect(t, oka && okb)
		ma, va, mb, vb: [2]f32
		adamA := Adam{paramsA, ma[:], va[:], 0, 0.01, 0.9, 0.999, 1e-8}
		adamB := Adam{paramsB, mb[:], vb[:], 0, 0.01, 0.9, 0.999, 1e-8}
		oa: SequentialOptimizer = SequentialSGD{0.01}
		ob: SequentialOptimizer = SequentialSGD{0.01}
		if useAdam { oa = &adamA; ob = &adamB }
		inputs := [3]f32{-1, 0, 2}
		targets := [3]f32{1, 2, -1}
		ia, ib: [3]int
		sa, sb: u64 = 42, 42
		ha, hb: [3]EpochMetrics
		la, ok1 := SequentialFitBatches(&a, inputs[:], targets[:], ia[:], &sa, epochs = 3, optimizer = oa, history = ha[:])
		lb, ok2 := SequentialFitBatches(&b, inputs[:], targets[:], ib[:], &sb, epochs = 3, optimizer = ob, history = hb[:], l2 = 0, earlyStopping = nil)
		testing.expect(t, ok1 && ok2 && la == lb && sa == sb && ia == ib && ha == hb)
		testing.expect(t, TestDenseStorage(&a.layers[0]).weightData == TestDenseStorage(&b.layers[0]).weightData && TestDenseStorage(&a.layers[0]).biasData == TestDenseStorage(&b.layers[0]).biasData)
		testing.expect(t, ma == mb && va == vb && adamA.step == adamB.step)
	}
}

@(test)
RegularizationInvalidPreflight :: proc(t: ^testing.T) {
	model: Sequential(1, 1, 1)
	testing.expect(t, SequentialInit(&model, 1) && SequentialAddDense(&model, 1))
	storage: [2]^core.Node
	params, valid := SequentialParameters(&model, storage[:])
	testing.expect(t, valid)
	first, second: [2]f32
	adam := Adam{params, first[:], second[:], 0, 0.1, 0.9, 0.999, 1e-8}
	input, target := [1]f32{1}, [1]f32{2}
	indices := [1]int{99}
	state: u64 = 42
	sentinel := EpochMetrics{99, 123, 456, true}
	history := [2]EpochMetrics{sentinel, sentinel}
	result := SequentialEarlyStoppingResult{7, 6, 5, true}
	config := SequentialEarlyStopping{1, 0, &result}
	weight, bias := TestDenseStorage(&model.layers[0]).weightData, TestDenseStorage(&model.layers[0]).biasData
	for scenario in 0..<11 {
		lambda: f32 = 0
		config = SequentialEarlyStopping{1, 0, &result}
		vi, vt := input[:], target[:]
		switch scenario {
		case 0: lambda = -1
		case 1: lambda = math.nan_f32()
		case 2: lambda = math.inf_f32(1)
		case 3: lambda = math.inf_f32(-1)
		case 4: config.patience = -1
		case 5: config.minDelta = -1
		case 6: config.minDelta = math.nan_f32()
		case 7: config.minDelta = math.inf_f32(1)
		case 8: config.result = nil
		case 9: vi = nil; vt = nil
		case 10: vt = nil
		}
		_, ok := SequentialFitBatches(&model, input[:], target[:], indices[:], &state, epochs = 2, optimizer = &adam, validationInputs = vi, validationTargets = vt, history = history[:], l2 = lambda, earlyStopping = &config)
		testing.expect(t, !ok && result == SequentialEarlyStoppingResult{7, 6, 5, true})
		testing.expect(t, indices == [1]int{99} && state == 42 && history == [2]EpochMetrics{sentinel, sentinel})
		testing.expect(t, TestDenseStorage(&model.layers[0]).weightData == weight && TestDenseStorage(&model.layers[0]).biasData == bias && adam.step == 0 && first == [2]f32{} && second == [2]f32{})
	}
}

@(test)
RegularizationEarlyStopping :: proc(t: ^testing.T) {
	for patience in ([3]int{0, 1, 2}) {
		model: Sequential(1, 1, 1)
		testing.expect(t, SequentialInit(&model, 1) && SequentialAddDense(&model, 1))
		TestDenseStorage(&model.layers[0]).weightData[0] = 0
		TestDenseStorage(&model.layers[0]).biasData[0] = 1
		input, target := [1]f32{0}, [1]f32{0}
		indices: [1]int
		sentinel := EpochMetrics{99, 123, 456, true}
		history := [8]EpochMetrics{sentinel, sentinel, sentinel, sentinel, sentinel, sentinel, sentinel, sentinel}
		result := SequentialEarlyStoppingResult{9, 8, 7, true}
		config := SequentialEarlyStopping{patience, 0.3, &result}
		value, ok := SequentialFitBatches(&model, input[:], target[:], indices[:], nil, epochs = 6, optimizer = SequentialSGD{0.1}, shuffle = false, validationInputs = input[:], validationTargets = target[:], history = history[1:7], l2 = 0.5, earlyStopping = &config)
		expectedEpochs := 2
		if patience == 2 { expectedEpochs = 5 }
		testing.expect(t, ok && result.stopped && result.epochsRan == expectedEpochs)
		if patience == 2 {
			testing.expect(t, result.bestEpoch == 3 && math.abs(result.bestValidationLoss - 0.262144) < 0.00001)
		} else {
			testing.expect(t, result.bestEpoch == 1 && math.abs(result.bestValidationLoss - 0.64) < 0.00001)
		}
		for i in 0..<expectedEpochs {
			testing.expect(t, history[i+1].epoch == i+1 && history[i+1].hasValidation && history[i+1].trainingLoss == history[i+1].validationLoss)
		}
		for i in expectedEpochs..<6 { testing.expect(t, history[i+1] == sentinel) }
		testing.expect(t, history[0] == sentinel && history[7] == sentinel)
		prediction, predicted := SequentialPredict(&model, input[:])
		if predicted { testing.expect(t, math.abs(value - prediction[0]*prediction[0]) < 0.00001 && value == history[expectedEpochs].trainingLoss) }
		testing.expect(t, predicted && value < result.bestValidationLoss)
	}
}

@(test)
RegularizationZeroEpochsAndCompletedRun :: proc(t: ^testing.T) {
	model: Sequential(1, 1, 1)
	testing.expect(t, SequentialInit(&model, 1) && SequentialAddDense(&model, 1))
	TestDenseStorage(&model.layers[0]).weightData[0] = 2
	TestDenseStorage(&model.layers[0]).biasData[0] = 1
	input, target := [1]f32{1}, [1]f32{0}
	indices := [1]int{9}
	state: u64 = 42
	sentinel := EpochMetrics{99, 123, 456, true}
	history := [3]EpochMetrics{sentinel, sentinel, sentinel}
	result := SequentialEarlyStoppingResult{9, 8, 7, true}
	config := SequentialEarlyStopping{2, 0, &result}
	value, ok := SequentialFitBatches(&model, input[:], target[:], indices[:], &state, epochs = 0, validationInputs = input[:], validationTargets = target[:], history = history[:0], l2 = 3, earlyStopping = &config)
	testing.expect(t, ok && value == 9 && result == SequentialEarlyStoppingResult{} && state == 42 && history == [3]EpochMetrics{sentinel, sentinel, sentinel})
	testing.expect(t, TestDenseStorage(&model.layers[0]).weightData[0] == 2 && TestDenseStorage(&model.layers[0]).biasData[0] == 1)
	value, ok = SequentialFitBatches(&model, input[:], target[:], indices[:], nil, epochs = 2, optimizer = SequentialSGD{0.1}, shuffle = false, validationInputs = input[:], validationTargets = target[:], history = history[:2], l2 = 0.5, earlyStopping = &config)
	testing.expect(t, ok && !result.stopped && result.epochsRan == 2 && result.bestEpoch == 2 && result.bestValidationLoss == history[1].validationLoss && history[2] == sentinel)
	prediction, predicted := SequentialPredict(&model, input[:])
	if predicted { testing.expect(t, math.abs(value - prediction[0]*prediction[0]) < 0.00001 && value == history[1].trainingLoss) }
	testing.expect(t, predicted)
}

@(test)
RegularizationMinDeltaStrictBoundary :: proc(t: ^testing.T) {
	model: Sequential(1, 1, 1)
	testing.expect(t, SequentialInit(&model, 1) && SequentialAddDense(&model, 1))
	TestDenseStorage(&model.layers[0]).weightData[0] = 0
	TestDenseStorage(&model.layers[0]).biasData[0] = 2
	input, target := [1]f32{0}, [1]f32{0}
	indices: [1]int
	result: SequentialEarlyStoppingResult
	config := SequentialEarlyStopping{1, 0.75, &result}
	history: [3]EpochMetrics
	value, ok := SequentialFitBatches(&model, input[:], target[:], indices[:], nil, epochs = 3, optimizer = SequentialSGD{0.25}, shuffle = false, validationInputs = input[:], validationTargets = target[:], history = history[:], earlyStopping = &config)
	testing.expect(t, ok && result.stopped && result.epochsRan == 2 && result.bestEpoch == 1 && result.bestValidationLoss == 1)
	testing.expect(t, history[0].validationLoss == 1 && history[1].validationLoss == 0.25 && value == 0.25)
}

@(test)
SequentialL2AndEarlyStopping :: proc(t: ^testing.T) {
	for useAdam in ([2]bool{false, true}) {
		model: Sequential(1, 1, 1)
		testing.expect(t, SequentialInit(&model, 1) && SequentialAddDense(&model, 1))
		TestDenseStorage(&model.layers[0]).weightData[0] = 2
		TestDenseStorage(&model.layers[0]).biasData[0] = 0
		storage: [2]^core.Node
		parameters, valid := SequentialParameters(&model, storage[:])
		testing.expect(t, valid)
		first, second: [2]f32
		adam := Adam{parameters, first[:], second[:], 0, 0.1, 0.9, 0.999, 1e-8}
		optimizer: SequentialOptimizer = SequentialSGD{0.1}
		if useAdam { optimizer = &adam }
		input, target := [1]f32{0}, [1]f32{0}
		indices: [1]int
		result: SequentialEarlyStoppingResult
		config := SequentialEarlyStopping{2, 0, &result}
		history: [5]EpochMetrics
		value, ok := SequentialFitBatches(&model, input[:], target[:], indices[:], nil, epochs = 5, optimizer = optimizer, shuffle = false, validationInputs = input[:], validationTargets = target[:], history = history[:], l2 = 0.5, earlyStopping = &config)
		testing.expect(t, ok && value == 0 && result.epochsRan == 3 && result.bestEpoch == 1 && result.bestValidationLoss == 0 && result.stopped)
		testing.expect(t, history[2].epoch == 3 && history[3].epoch == 0 && history[2].trainingLoss == 0 && history[2].validationLoss == 0)
		testing.expect(t, TestDenseStorage(&model.layers[0]).weightData[0] < 2 && TestDenseStorage(&model.layers[0]).biasData[0] == 0)
		if useAdam { testing.expect(t, adam.step == 3 && first[0] > 0 && first[1] == 0) }
		before := result
		_, invalid := SequentialFitBatches(&model, input[:], target[:], indices[:], nil, epochs = 1, shuffle = false, l2 = math.nan_f32(), earlyStopping = &config)
		testing.expect(t, !invalid && result == before)
		_, zero := SequentialFitBatches(&model, input[:], target[:], indices[:], nil, epochs = 0, shuffle = false, validationInputs = input[:], validationTargets = target[:], earlyStopping = &config)
		testing.expect(t, zero && result == SequentialEarlyStoppingResult{})
	}
}

@(test)
SequentialL2SingleStep :: proc(t: ^testing.T) {
	model: Sequential(1, 1, 1)
	testing.expect(t, SequentialInit(&model, 1) && SequentialAddDense(&model, 1))
	TestDenseStorage(&model.layers[0]).weightData[0] = 2
	TestDenseStorage(&model.layers[0]).biasData[0] = 1
	input, target := [1]f32{0}, [1]f32{1}
	indices: [1]int
	loss, ok := SequentialFitBatches(&model, input[:], target[:], indices[:], nil, epochs = 1, optimizer = SequentialSGD{0.1}, shuffle = false, l2 = 0.5)
	testing.expect(t, ok && loss == 0 && math.abs(TestDenseStorage(&model.layers[0]).weightData[0] - 1.9) < 0.000001 && TestDenseStorage(&model.layers[0]).biasData[0] == 1)
}

