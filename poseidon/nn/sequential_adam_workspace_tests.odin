package nn

import "../core"
import "core:math"
import "core:mem"
import "core:testing"

@(private="file")
SequentialAdamWorkspaceExpectBytes :: proc(t: ^testing.T, address: rawptr, expected: []u8) {
	actual := mem.slice_ptr(cast(^u8)address, len(expected))
	for byte, index in expected { testing.expect(t, actual[index] == byte) }
}

@(test)
SequentialAdamWorkspaceFitAndContinuation :: proc(t: ^testing.T) {
	model, reference: Sequential(4, 3, 2)
	for target in ([2]^Sequential(4, 3, 2){&model, &reference}) {
		ok := SequentialInit(target, 2, 17) && SequentialAddDense(target, 3) &&
			SequentialAddActivation(target, .Tanh) && SequentialAddDropout(target, 0.25) && SequentialAddDense(target, 1)
		testing.expect(t, ok)
		if !ok { return }
	}
	workspace: SequentialAdamWorkspace(6, 15)
	for &parameter in workspace.parameterStorage { parameter = &model.input }
	for &moment in workspace.firstMoment { moment = 7 }
	for &moment in workspace.secondMoment { moment = 8 }
	manualParameters: [4]^core.Node
	manualFirst, manualSecond: [13]f32
	manual: Adam
	compiled: CompiledSequential(4, 3, 2)
	count, elements: int
	requirementsOk, initialized, manualOk, compiledOk: bool
	{
		context.allocator = mem.nil_allocator()
		count, elements, requirementsOk = SequentialAdamRequirements(&model)
		initialized = SequentialAdamWorkspaceInit(&model, &workspace)
		manualOk = SequentialAdamInit(&reference, &manual, manualParameters[:], manualFirst[:], manualSecond[:])
		compiledOk = SequentialCompile(&compiled, &model, optimizer = SequentialAdamWorkspaceOptimizer(&workspace))
	}
	testing.expect(t, requirementsOk && count == 4 && elements == 13 && initialized && manualOk && compiledOk)
	if !initialized || !manualOk || !compiledOk { return }
	adam := SequentialAdamWorkspaceOptimizer(&workspace)
	testing.expect(t, adam == &workspace.optimizer && adam.step == 0 && adam.learningRate == 0.001 && adam.beta1 == 0.9 && adam.beta2 == 0.999 && adam.epsilon == 1e-8)
	testing.expect(t, len(adam.parameters) == 4 && len(adam.firstMoment) == 13 && len(adam.secondMoment) == 13)
	testing.expect(t, raw_data(adam.parameters) == raw_data(workspace.parameterStorage[:]) && raw_data(adam.firstMoment) == raw_data(workspace.firstMoment[:]) && raw_data(adam.secondMoment) == raw_data(workspace.secondMoment[:]))
	first, last := TestDenseStorage(&model.layers[0]), TestDenseStorage(&model.layers[3])
	testing.expect(t, workspace.parameterStorage == [6]^core.Node{&first.weights, &first.bias, &last.weights, &last.bias, &model.input, &model.input})
	for i in 0..<13 { testing.expect(t, workspace.firstMoment[i] == 0 && workspace.secondMoment[i] == 0) }
	testing.expect(t, workspace.firstMoment[13] == 7 && workspace.firstMoment[14] == 7 && workspace.secondMoment[13] == 8 && workspace.secondMoment[14] == 8)

	inputs := [6]f32{1, 2, -1, 3, 0, 1}
	targets := [3]f32{1, -1, 0.5}
	indices, referenceIndices: [3]int
	state, referenceState: u64 = 7, 7
	loss, referenceLoss: f32
	fitOk, referenceFitOk: bool
	{
		context.allocator = mem.nil_allocator()
		loss, fitOk = CompiledSequentialFit(&compiled, inputs[:], targets[:], indices[:], &state, epochs = 3)
		referenceLoss, referenceFitOk = SequentialFitBatches(&reference, inputs[:], targets[:], referenceIndices[:], &referenceState, epochs = 3, optimizer = &manual)
	}
	testing.expect(t, fitOk && referenceFitOk && loss == referenceLoss && state == referenceState && adam.step == 6 && manual.step == 6)
	loss, fitOk = CompiledSequentialFit(&compiled, inputs[:], targets[:], indices[:], &state, epochs = 2)
	referenceLoss, referenceFitOk = SequentialFitBatches(&reference, inputs[:], targets[:], referenceIndices[:], &referenceState, epochs = 2, optimizer = &manual)
	testing.expect(t, fitOk && referenceFitOk && loss == referenceLoss && state == referenceState && adam.step == 10 && manual.step == 10)
	nonzero := false
	for i in 0..<13 {
		testing.expect(t, workspace.firstMoment[i] == manualFirst[i] && workspace.secondMoment[i] == manualSecond[i])
		if workspace.secondMoment[i] != 0 { nonzero = true }
	}
	testing.expect(t, nonzero && workspace.firstMoment[13] == 7 && workspace.secondMoment[13] == 8)
	for layer in ([2]int{0, 3}) {
		a, b := TestDenseStorage(&model.layers[layer]), TestDenseStorage(&reference.layers[layer])
		testing.expect(t, a.weightData == b.weightData && a.biasData == b.biasData)
	}
}

@(test)
SequentialAdamWorkspaceFailuresAreAtomic :: proc(t: ^testing.T) {
	small, large, noParameters: Sequential(1, 2, 2)
	ok := SequentialInit(&small, 1, 3) && SequentialAddDense(&small, 1) &&
		SequentialInit(&large, 2, 4) && SequentialAddDense(&large, 1) &&
		SequentialInit(&noParameters, 1) && SequentialAddActivation(&noParameters, .Tanh)
	testing.expect(t, ok)
	if !ok { return }

	tooFewParameters: SequentialAdamWorkspace(1, 3)
	testing.expect(t, SequentialAdamWorkspaceInit(&noParameters, &tooFewParameters))
	tooFewParameters.parameterStorage[0] = &noParameters.input
	tooFewParameters.firstMoment = {1, 2, 3}
	tooFewParameters.secondMoment = {4, 5, 6}
	tooFewParameters.optimizer.step = 9
	parameterSnapshot: [size_of(SequentialAdamWorkspace(1, 3))]u8
	copy(parameterSnapshot[:], mem.slice_ptr(cast(^u8)rawptr(&tooFewParameters), size_of(tooFewParameters)))
	testing.expect(t, !SequentialAdamWorkspaceInit(&large, &tooFewParameters))
	SequentialAdamWorkspaceExpectBytes(t, rawptr(&tooFewParameters), parameterSnapshot[:])
	testing.expect(t, SequentialAdamWorkspaceOptimizer(&tooFewParameters) == &tooFewParameters.optimizer && AdamStep(&tooFewParameters.optimizer) && tooFewParameters.optimizer.step == 10)

	tooFewElements: SequentialAdamWorkspace(2, 2)
	testing.expect(t, SequentialAdamWorkspaceInit(&small, &tooFewElements, 0.02, 0.8, 0.95, 1e-6))
	for parameter in tooFewElements.optimizer.parameters { for &gradient in parameter.grad.data { gradient = 1 } }
	testing.expect(t, AdamStep(&tooFewElements.optimizer))
	snapshot: [size_of(SequentialAdamWorkspace(2, 2))]u8
	copy(snapshot[:], mem.slice_ptr(cast(^u8)rawptr(&tooFewElements), size_of(tooFewElements)))
	weights, biases := TestDenseStorage(&small.layers[0]).weightData, TestDenseStorage(&small.layers[0]).biasData
	testing.expect(t, !SequentialAdamWorkspaceInit(&large, &tooFewElements))
	SequentialAdamWorkspaceExpectBytes(t, rawptr(&tooFewElements), snapshot[:])
	testing.expect(t, !SequentialAdamWorkspaceInit((^Sequential(1, 2, 2))(nil), &tooFewElements))
	testing.expect(t, !SequentialAdamWorkspaceInit(&small, (^SequentialAdamWorkspace(2, 2))(nil)))
	testing.expect(t, SequentialAdamWorkspaceOptimizer((^SequentialAdamWorkspace(2, 2))(nil)) == nil)
	SequentialAdamWorkspaceExpectBytes(t, rawptr(&tooFewElements), snapshot[:])
	testing.expect(t, !SequentialAdamWorkspaceInit(&small, &tooFewElements, learningRate = 0))
	testing.expect(t, !SequentialAdamWorkspaceInit(&small, &tooFewElements, learningRate = math.inf_f32(1)))
	testing.expect(t, !SequentialAdamWorkspaceInit(&small, &tooFewElements, beta1 = 1))
	testing.expect(t, !SequentialAdamWorkspaceInit(&small, &tooFewElements, beta2 = math.nan_f32()))
	testing.expect(t, !SequentialAdamWorkspaceInit(&small, &tooFewElements, epsilon = 0))
	SequentialAdamWorkspaceExpectBytes(t, rawptr(&tooFewElements), snapshot[:])
	copiedModel := small
	testing.expect(t, !SequentialAdamWorkspaceInit(&copiedModel, &tooFewElements))
	oldLayer := small.layers[0].layer
	small.layers[0].layer = nil
	testing.expect(t, !SequentialAdamWorkspaceInit(&small, &tooFewElements))
	small.layers[0].layer = oldLayer
	SequentialAdamWorkspaceExpectBytes(t, rawptr(&tooFewElements), snapshot[:])
	testing.expect(t, TestDenseStorage(&small.layers[0]).weightData == weights && TestDenseStorage(&small.layers[0]).biasData == biases)
	testing.expect(t, AdamStep(SequentialAdamWorkspaceOptimizer(&tooFewElements)) && tooFewElements.optimizer.step == 2)
}

@(test)
SequentialAdamWorkspaceOverlapAndReboundStorage :: proc(t: ^testing.T) {
	model: Sequential(1, 2, 2)
	ok := SequentialInit(&model, 2) && SequentialAddDense(&model, 1)
	testing.expect(t, ok)
	if !ok { return }
	workspace: SequentialAdamWorkspace(4, 8)
	testing.expect(t, SequentialAdamWorkspaceInit(&model, &workspace))
	for parameter in workspace.optimizer.parameters { for &gradient in parameter.grad.data { gradient = 1 } }
	testing.expect(t, AdamStep(&workspace.optimizer))
	snapshot: [size_of(SequentialAdamWorkspace(4, 8))]u8
	copy(snapshot[:], mem.slice_ptr(cast(^u8)rawptr(&workspace), size_of(workspace)))
	dense := TestDenseStorage(&model.layers[0])
	oldValues, oldGradients := dense.weights.value.data, dense.weights.grad.data
	// These are beyond the three elements and two pointers used by this model.
	dense.weights.value.data = workspace.firstMoment[3:5]
	_, _, valid := SequentialAdamRequirements(&model)
	testing.expect(t, valid && !SequentialAdamWorkspaceInit(&model, &workspace))
	dense.weights.value.data = oldValues
	SequentialAdamWorkspaceExpectBytes(t, rawptr(&workspace), snapshot[:])
	dense.weights.grad.data = workspace.secondMoment[3:5]
	_, _, valid = SequentialAdamRequirements(&model)
	testing.expect(t, valid && !SequentialAdamWorkspaceInit(&model, &workspace))
	dense.weights.grad.data = oldGradients
	SequentialAdamWorkspaceExpectBytes(t, rawptr(&workspace), snapshot[:])
	dense.weights.value.data = mem.slice_ptr(cast(^f32)rawptr(&workspace.parameterStorage[2]), 2)
	_, _, valid = SequentialAdamRequirements(&model)
	testing.expect(t, valid && !SequentialAdamWorkspaceInit(&model, &workspace))
	dense.weights.value.data = oldValues
	SequentialAdamWorkspaceExpectBytes(t, rawptr(&workspace), snapshot[:])

	modelSnapshot: [size_of(Sequential(1, 2, 2))]u8
	copy(modelSnapshot[:], mem.slice_ptr(cast(^u8)rawptr(&model), size_of(model)))
	testing.expect(t, !SequentialAdamWorkspaceInit(&model, cast(^SequentialAdamWorkspace(4, 8))rawptr(&model)))
	SequentialAdamWorkspaceExpectBytes(t, rawptr(&model), modelSnapshot[:])
	SequentialAdamWorkspaceExpectBytes(t, rawptr(&workspace), snapshot[:])

	values := [2]f32{1, 2}
	gradients := [2]f32{1, 1}
	dense.weights.value.data, dense.weights.grad.data = values[:], gradients[:]
	testing.expect(t, SequentialAdamWorkspaceInit(&model, &workspace, learningRate = 0.1))
	testing.expect(t, AdamStep(SequentialAdamWorkspaceOptimizer(&workspace)) && workspace.optimizer.step == 1)
	testing.expect(t, math.abs(values[0]-0.9) < 0.000001 && math.abs(values[1]-1.9) < 0.000001 && gradients == [2]f32{1, 1})
}

@(test)
SequentialAdamWorkspaceCopyAndModelReinitialization :: proc(t: ^testing.T) {
	model: Sequential(2, 2, 2)
	workspace: SequentialAdamWorkspace(4, 8)
	compiled: CompiledSequential(2, 2, 2)
	ok := SequentialInit(&model, 1, 17) && SequentialAddDense(&model, 1) &&
		SequentialAdamWorkspaceInit(&model, &workspace, learningRate = 0.02) &&
		SequentialCompile(&compiled, &model, optimizer = SequentialAdamWorkspaceOptimizer(&workspace))
	testing.expect(t, ok)
	if !ok { return }
	inputs, targets := [3]f32{-1, 0, 2}, [3]f32{1, -1, 3}
	indices: [3]int
	state: u64 = 5
	_, trained := CompiledSequentialFit(&compiled, inputs[:], targets[:], indices[:], &state, epochs = 2)
	testing.expect(t, trained && workspace.optimizer.step == 4 && workspace.firstMoment[0] != 0)
	borrowed := SequentialAdamWorkspaceOptimizer(&workspace)
	snapshot: [size_of(SequentialAdamWorkspace(4, 8))]u8
	copy(snapshot[:], mem.slice_ptr(cast(^u8)rawptr(&workspace), size_of(workspace)))
	moved := workspace
	testing.expect(t, SequentialAdamWorkspaceOptimizer(&moved) == nil)
	testing.expect(t, raw_data(moved.optimizer.firstMoment) == raw_data(workspace.firstMoment[:]))
	testing.expect(t, SequentialAdamWorkspaceInit(&model, &moved))
	testing.expect(t, SequentialAdamWorkspaceOptimizer(&moved) == &moved.optimizer && raw_data(moved.optimizer.firstMoment) == raw_data(moved.firstMoment[:]))
	testing.expect(t, moved.optimizer.step == 0 && moved.firstMoment[0] == 0 && moved.secondMoment[0] == 0)
	SequentialAdamWorkspaceExpectBytes(t, rawptr(&workspace), snapshot[:])
	testing.expect(t, SequentialAdamWorkspaceOptimizer(&workspace) == borrowed && borrowed.step == 4)

	// Rebuilding at the same address does not reset a previously borrowed Adam.
	testing.expect(t, SequentialInit(&model, 1, 19) && SequentialAddDense(&model, 2) && SequentialAddDense(&model, 1))
	_, trained = CompiledSequentialFit(&compiled, inputs[:], targets[:], indices[:], &state, epochs = 1)
	testing.expect(t, !trained && workspace.optimizer.step == 4)
	weights := TestDenseStorage(&model.layers[0]).weightData
	testing.expect(t, SequentialAdamWorkspaceInit(&model, &workspace, 0.03, 0.7, 0.8, 1e-5))
	testing.expect(t, SequentialAdamWorkspaceOptimizer(&workspace) == borrowed && borrowed.step == 0 && borrowed.learningRate == 0.03 && borrowed.beta1 == 0.7 && borrowed.beta2 == 0.8 && borrowed.epsilon == 1e-5)
	testing.expect(t, len(borrowed.parameters) == 4 && len(borrowed.firstMoment) == 7 && TestDenseStorage(&model.layers[0]).weightData == weights)
	for moment in borrowed.firstMoment { testing.expect(t, moment == 0) }
	for moment in borrowed.secondMoment { testing.expect(t, moment == 0) }
	_, trained = CompiledSequentialFit(&compiled, inputs[:], targets[:], indices[:], &state, epochs = 1)
	testing.expect(t, trained && borrowed.step == 2)
}

@(test)
SequentialAdamWorkspaceEmptyAndSpatial :: proc(t: ^testing.T) {
	empty: Sequential(1, 1, 2)
	zero: SequentialAdamWorkspace(0, 0)
	compiled: CompiledSequential(1, 1, 2)
	testing.expect(t, SequentialAdamWorkspaceOptimizer(&zero) == nil)
	ok := SequentialInit(&empty, 1) && SequentialAddActivation(&empty, .Sigmoid) && SequentialAdamWorkspaceInit(&empty, &zero) &&
		SequentialCompile(&compiled, &empty, optimizer = SequentialAdamWorkspaceOptimizer(&zero))
	testing.expect(t, ok)
	if !ok { return }
	count, elements, valid := SequentialAdamRequirements(&empty)
	testing.expect(t, valid && count == 0 && elements == 0 && len(zero.optimizer.parameters) == 0 && len(zero.optimizer.firstMoment) == 0)
	inputs, targets := [2]f32{0, 1}, [2]f32{0, 1}
	indices: [2]int
	_, trained := CompiledSequentialFit(&compiled, inputs[:], targets[:], indices[:], nil, epochs = 1, shuffle = false)
	testing.expect(t, trained && zero.optimizer.step == 1)

	spatial: Sequential(3, 16, 2)
	spatialWorkspace: SequentialAdamWorkspace(4, 19)
	ok = SequentialInitSpatial(&spatial, 3, 3, 1, 42) && SequentialAddConv2D(&spatial, 2, 2, 2) &&
		SequentialAddFlatten(&spatial) && SequentialAddDense(&spatial, 1)
	testing.expect(t, ok)
	if !ok { return }
	count, elements, valid = SequentialAdamRequirements(&spatial)
	testing.expect(t, valid && count == 4 && elements == 19 && SequentialAdamWorkspaceInit(&spatial, &spatialWorkspace))
	conv := &spatial.layers[0].storage.(Conv2DStorage(16))
	dense := TestDenseStorage(&spatial.layers[2])
	testing.expect(t, spatialWorkspace.parameterStorage == [4]^core.Node{&conv.weights, &conv.bias, &dense.weights, &dense.bias})
	for parameter in spatialWorkspace.optimizer.parameters { for &gradient in parameter.grad.data { gradient = 1 } }
	testing.expect(t, AdamStep(SequentialAdamWorkspaceOptimizer(&spatialWorkspace)) && spatialWorkspace.optimizer.step == 1)
}

@(test)
SequentialAdamWorkspaceCheckpointResumeAndReset :: proc(t: ^testing.T) {
	model, restored: Sequential(1, 1, 2)
	workspace, restoredWorkspace: SequentialAdamWorkspace(4, 4)
	compiled, restoredCompiled: CompiledSequential(1, 1, 2)
	ok := SequentialInit(&model, 1, 11) && SequentialAddDense(&model, 1) &&
		SequentialAdamWorkspaceInit(&model, &workspace, 0.02, 0.8, 0.95, 1e-6) &&
		SequentialCompile(&compiled, &model, optimizer = SequentialAdamWorkspaceOptimizer(&workspace)) &&
		SequentialInit(&restored, 1, 99) && SequentialAddDense(&restored, 1) &&
		SequentialAdamWorkspaceInit(&restored, &restoredWorkspace) &&
		SequentialCompile(&restoredCompiled, &restored, optimizer = SequentialAdamWorkspaceOptimizer(&restoredWorkspace))
	testing.expect(t, ok)
	if !ok { return }
	inputs := [5]f32{-2, -1, 0, 1, 3}
	targets := [5]f32{1, 0, 2, -1, 4}
	indices, restoredIndices: [5]int
	state, restoredState: u64 = 55, 0
	_, trained := CompiledSequentialFit(&compiled, inputs[:], targets[:], indices[:], &state, epochs = 2)
	testing.expect(t, trained && workspace.optimizer.step == 6 && workspace.firstMoment[0] != 0 && workspace.secondMoment[0] != 0)
	checkpoint: [1024]u8
	size, saved := CheckpointWrite(&model, SequentialAdamWorkspaceOptimizer(&workspace), state, checkpoint[:])
	testing.expect(t, saved)
	if !saved { return }
	restoredWorkspace.firstMoment[2], restoredWorkspace.secondMoment[2] = 17, 18
	loaded := CheckpointRead(&restored, &restoredWorkspace.optimizer, &restoredState, checkpoint[:size], restoredWorkspace.parameterStorage[:], restoredWorkspace.firstMoment[:], restoredWorkspace.secondMoment[:])
	testing.expect(t, loaded)
	if !loaded { return }
	testing.expect(t, SequentialAdamWorkspaceOptimizer(&restoredWorkspace) == &restoredWorkspace.optimizer && restoredState == state)
	testing.expect(t, restoredWorkspace.optimizer.step == 6 && restoredWorkspace.optimizer.learningRate == 0.02 && restoredWorkspace.optimizer.beta1 == 0.8 && restoredWorkspace.optimizer.beta2 == 0.95 && restoredWorkspace.optimizer.epsilon == 1e-6)
	for i in 0..<2 { testing.expect(t, restoredWorkspace.firstMoment[i] == workspace.firstMoment[i] && restoredWorkspace.secondMoment[i] == workspace.secondMoment[i]) }
	testing.expect(t, restoredWorkspace.firstMoment[2] == 17 && restoredWorkspace.secondMoment[2] == 18)
	loss, fitOk := CompiledSequentialFit(&compiled, inputs[:], targets[:], indices[:], &state, epochs = 2)
	restoredLoss, restoredFitOk := CompiledSequentialFit(&restoredCompiled, inputs[:], targets[:], restoredIndices[:], &restoredState, epochs = 2)
	testing.expect(t, fitOk && restoredFitOk && loss == restoredLoss && state == restoredState && workspace.optimizer.step == 12 && restoredWorkspace.optimizer.step == 12)
	testing.expect(t, TestDenseStorage(&model.layers[0]).weightData == TestDenseStorage(&restored.layers[0]).weightData && TestDenseStorage(&model.layers[0]).biasData == TestDenseStorage(&restored.layers[0]).biasData)
	for i in 0..<2 { testing.expect(t, restoredWorkspace.firstMoment[i] == workspace.firstMoment[i] && restoredWorkspace.secondMoment[i] == workspace.secondMoment[i]) }

	weights, biases := TestDenseStorage(&restored.layers[0]).weightData, TestDenseStorage(&restored.layers[0]).biasData
	testing.expect(t, SequentialAdamWorkspaceInit(&restored, &restoredWorkspace, 0.02, 0.8, 0.95, 1e-6))
	testing.expect(t, restoredWorkspace.optimizer.step == 0)
	for i in 0..<2 {
		testing.expect(t, restoredWorkspace.firstMoment[i] == 0 && restoredWorkspace.secondMoment[i] == 0)
	}
	testing.expect(t, restoredWorkspace.firstMoment[2] == 17 && restoredWorkspace.secondMoment[2] == 18 && TestDenseStorage(&restored.layers[0]).weightData == weights && TestDenseStorage(&restored.layers[0]).biasData == biases)
	_, fitOk = CompiledSequentialFit(&compiled, inputs[:], targets[:], indices[:], &state, epochs = 1)
	_, restoredFitOk = CompiledSequentialFit(&restoredCompiled, inputs[:], targets[:], restoredIndices[:], &restoredState, epochs = 1)
	testing.expect(t, fitOk && restoredFitOk && workspace.optimizer.step == 15 && restoredWorkspace.optimizer.step == 3)
	testing.expect(t, TestDenseStorage(&model.layers[0]).weightData != TestDenseStorage(&restored.layers[0]).weightData)
}
