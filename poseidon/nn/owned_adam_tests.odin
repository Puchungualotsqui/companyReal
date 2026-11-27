package nn

import "../core"
import "core:math"
import "core:mem"
import "core:testing"

OwnedAdamTestAllocator :: struct {
	backing: mem.Allocator,
	attempts, successes, frees, failAt: int,
	pointerAndErrorAt: int,
	failWithNil: bool,
	sizes, alignments: [3]int,
}

OwnedAdamTestAllocatorProc :: proc(
	data: rawptr, mode: mem.Allocator_Mode, size, alignment: int,
	oldMemory: rawptr, oldSize: int, loc := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	state := (^OwnedAdamTestAllocator)(data)
	if mode == .Alloc {
		state.attempts += 1
		if state.attempts <= len(state.sizes) {
			state.sizes[state.attempts-1], state.alignments[state.attempts-1] = size, alignment
		}
		if state.attempts == state.failAt {
			if state.failWithNil { return nil, nil }
			return nil, .Out_Of_Memory
		}
		memory, err := state.backing.procedure(state.backing.data, mode, size, alignment, oldMemory, oldSize, loc)
		if raw_data(memory) != nil {
			state.successes += 1
			if state.attempts == state.pointerAndErrorAt { return memory, .Out_Of_Memory }
		}
		return memory, err
	}
	if mode == .Free { state.frees += 1 }
	return state.backing.procedure(state.backing.data, mode, size, alignment, oldMemory, oldSize, loc)
}

OwnedAdamTestExpectBytes :: proc(t: ^testing.T, address: rawptr, expected: []u8) {
	actual := mem.slice_ptr((^u8)(address), len(expected))
	for value, i in expected { testing.expect(t, value == actual[i]) }
}

OwnedAdamRetryAllocator :: struct {
	backing: mem.Allocator,
	frees: int,
}

OwnedAdamRetryAllocatorProc :: proc(
	data: rawptr, mode: mem.Allocator_Mode, size, alignment: int,
	oldMemory: rawptr, oldSize: int, loc := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	state := (^OwnedAdamRetryAllocator)(data)
	if mode == .Free {
		state.frees += 1
		if state.frees == 2 { return nil, .Invalid_Argument }
	}
	return state.backing.procedure(state.backing.data, mode, size, alignment, oldMemory, oldSize, loc)
}

@(test)
OwnedAdamDestroyRetriesFailedFrees :: proc(t: ^testing.T) {
	model: Sequential(1, 1, 2)
	owned: SequentialOwnedAdam
	state := OwnedAdamRetryAllocator{backing = context.allocator}
	allocator := mem.Allocator{procedure = OwnedAdamRetryAllocatorProc, data = &state}
	initialized := SequentialInit(&model, 1) && SequentialAddDense(&model, 1) &&
		SequentialOwnedAdamInit(&model, &owned, allocator = allocator)
	testing.expect(t, initialized)
	if !initialized { return }
	defer SequentialOwnedAdamDestroy(&owned)
	testing.expect(t, !SequentialOwnedAdamDestroy(&owned) && state.frees == 2 && owned.destroying)
	testing.expect(t, SequentialOwnedAdamOptimizer(&owned) == nil)
	_, _, _, valid := SequentialOwnedAdamStorage(&owned)
	testing.expect(t, !valid && !SequentialOwnedAdamInit(&model, &owned, allocator = allocator))
	testing.expect(t, SequentialOwnedAdamDestroy(&owned) && state.frees == 4 && !owned.destroying)
	testing.expect(t, SequentialOwnedAdamDestroy(&owned) && state.frees == 4)
}

@(test)
OwnedAdamAllocationAndLifetime :: proc(t: ^testing.T) {
	model: Sequential(3, 3, 2)
	ok := SequentialInit(&model, 2, 17) && SequentialAddDense(&model, 3) &&
		SequentialAddActivation(&model, .Tanh) && SequentialAddDense(&model, 1)
	testing.expect(t, ok)
	if !ok { return }
	initialWeights, initialBias := TestDenseStorage(&model.layers[0]).weightData, TestDenseStorage(&model.layers[0]).biasData
	state := OwnedAdamTestAllocator{backing = context.allocator}
	allocator := mem.Allocator{procedure = OwnedAdamTestAllocatorProc, data = &state}
	owned: SequentialOwnedAdam
	{
		context.allocator = allocator
		ok = SequentialOwnedAdamInit(&model, &owned, 0.02, 0.8, 0.95, 1e-6)
	}
	testing.expect(t, ok)
	if !ok { return }
	defer SequentialOwnedAdamDestroy(&owned)
	adam := SequentialOwnedAdamOptimizer(&owned)
	parameters, first, second, storageOk := SequentialOwnedAdamStorage(&owned)
	testing.expect(t, adam == &owned.optimizer && storageOk && len(parameters) == 4 && len(first) == 13 && len(second) == 13)
	testing.expect(t, state.attempts == 3 && state.successes == 3 && state.frees == 0)
	testing.expect(t, state.sizes == [3]int{4*size_of(^core.Node), 13*size_of(f32), 13*size_of(f32)})
	testing.expect(t, state.alignments == [3]int{align_of(^core.Node), align_of(f32), align_of(f32)})
	testing.expect(t, raw_data(adam.parameters) == raw_data(parameters) && raw_data(adam.firstMoment) == raw_data(first) && raw_data(adam.secondMoment) == raw_data(second))
	firstDense, lastDense := TestDenseStorage(&model.layers[0]), TestDenseStorage(&model.layers[2])
	testing.expect(t, parameters[0] == &firstDense.weights && parameters[1] == &firstDense.bias && parameters[2] == &lastDense.weights && parameters[3] == &lastDense.bias)
	testing.expect(t, adam.step == 0 && adam.learningRate == 0.02 && adam.beta1 == 0.8 && adam.beta2 == 0.95 && adam.epsilon == 1e-6)
	for i in 0..<13 { testing.expect(t, first[i] == 0 && second[i] == 0) }
	testing.expect(t, firstDense.weightData == initialWeights && firstDense.biasData == initialBias)

	// Destroy must use the originally captured allocator and allocations, not the
	// current context or mutable slices in the exposed Adam.
	adam.parameters, adam.firstMoment, adam.secondMoment = nil, nil, nil
	destroyed: bool
	{
		context.allocator = mem.nil_allocator()
		destroyed = SequentialOwnedAdamDestroy(&owned)
	}
	testing.expect(t, destroyed && state.frees == 3 && SequentialOwnedAdamOptimizer(&owned) == nil)
	_, _, _, storageOk = SequentialOwnedAdamStorage(&owned)
	testing.expect(t, !storageOk && SequentialOwnedAdamDestroy(&owned) && state.frees == 3)
}

@(test)
OwnedAdamAllocationFailuresAreAtomic :: proc(t: ^testing.T) {
	model: Sequential(1, 2, 2)
	ok := SequentialInit(&model, 2, 23) && SequentialAddDense(&model, 1)
	testing.expect(t, ok)
	if !ok { return }
	modelBytes: [size_of(Sequential(1, 2, 2))]u8
	copy(modelBytes[:], mem.slice_ptr((^u8)(rawptr(&model)), len(modelBytes)))
	for failAt in 1..=3 {
		for nilFailure in ([2]bool{false, true}) {
			state := OwnedAdamTestAllocator{backing = context.allocator, failAt = failAt, failWithNil = nilFailure}
			allocator := mem.Allocator{procedure = OwnedAdamTestAllocatorProc, data = &state}
			owned: SequentialOwnedAdam
			ownedBytes: [size_of(SequentialOwnedAdam)]u8
			copy(ownedBytes[:], mem.slice_ptr((^u8)(rawptr(&owned)), len(ownedBytes)))
			testing.expect(t, !SequentialOwnedAdamInit(&model, &owned, allocator = allocator))
			testing.expect(t, state.attempts == failAt && state.successes == failAt-1 && state.frees == failAt-1)
			OwnedAdamTestExpectBytes(t, rawptr(&owned), ownedBytes[:])
			OwnedAdamTestExpectBytes(t, rawptr(&model), modelBytes[:])
			testing.expect(t, SequentialOwnedAdamOptimizer(&owned) == nil && SequentialOwnedAdamDestroy(&owned))
		}
	}
	for failAt in 1..=3 {
		state := OwnedAdamTestAllocator{backing = context.allocator, pointerAndErrorAt = failAt}
		allocator := mem.Allocator{procedure = OwnedAdamTestAllocatorProc, data = &state}
		owned: SequentialOwnedAdam
		testing.expect(t, !SequentialOwnedAdamInit(&model, &owned, allocator = allocator))
		testing.expect(t, state.attempts == failAt && state.successes == failAt && state.frees == failAt)
		testing.expect(t, SequentialOwnedAdamOptimizer(&owned) == nil && SequentialOwnedAdamDestroy(&owned))
		OwnedAdamTestExpectBytes(t, rawptr(&model), modelBytes[:])
	}
	owned: SequentialOwnedAdam
	state := OwnedAdamTestAllocator{backing = context.allocator}
	allocator := mem.Allocator{procedure = OwnedAdamTestAllocatorProc, data = &state}
	testing.expect(t, !SequentialOwnedAdamInit((^Sequential(1, 2, 2))(nil), &owned, allocator = allocator))
	testing.expect(t, !SequentialOwnedAdamInit(&model, nil, allocator = allocator))
	testing.expect(t, !SequentialOwnedAdamInit(&model, &owned, learningRate = 0, allocator = allocator))
	testing.expect(t, !SequentialOwnedAdamInit(&model, &owned, learningRate = math.inf_f32(1), allocator = allocator))
	testing.expect(t, !SequentialOwnedAdamInit(&model, &owned, beta1 = 1, allocator = allocator))
	testing.expect(t, !SequentialOwnedAdamInit(&model, &owned, beta2 = math.nan_f32(), allocator = allocator))
	testing.expect(t, !SequentialOwnedAdamInit(&model, &owned, epsilon = 0, allocator = allocator))
	copiedModel := model
	testing.expect(t, !SequentialOwnedAdamInit(&copiedModel, &owned, allocator = allocator))
	testing.expect(t, !SequentialOwnedAdamInit(&model, &owned, allocator = mem.nil_allocator()))
	testing.expect(t, state.attempts == 0 && SequentialOwnedAdamOptimizer(&owned) == nil)
	OwnedAdamTestExpectBytes(t, rawptr(&model), modelBytes[:])
}

// Deliberately violates the allocator disjointness contract without zeroing the
// aliased block, so the initializer's defensive overlap checks can be exercised.
OwnedAdamTestAliasAllocator :: struct {
	backing: mem.Allocator,
	alias: rawptr,
	allocations, frees, aliasFrees: int,
}

OwnedAdamTestAliasAllocatorProc :: proc(
	data: rawptr, mode: mem.Allocator_Mode, size, alignment: int,
	oldMemory: rawptr, oldSize: int, loc := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	state := (^OwnedAdamTestAliasAllocator)(data)
	if mode == .Alloc {
		state.allocations += 1
		if state.allocations == 1 { return mem.slice_ptr((^u8)(state.alias), size), nil }
	}
	if mode == .Free {
		state.frees += 1
		if oldMemory == state.alias { state.aliasFrees += 1; return nil, nil }
	}
	return state.backing.procedure(state.backing.data, mode, size, alignment, oldMemory, oldSize, loc)
}

@(test)
OwnedAdamRejectsAliases :: proc(t: ^testing.T) {
	model: Sequential(1, 2, 2)
	ok := SequentialInit(&model, 2, 5) && SequentialAddDense(&model, 1)
	testing.expect(t, ok)
	if !ok { return }
	owned: SequentialOwnedAdam
	state := OwnedAdamTestAllocator{backing = context.allocator}
	allocator := mem.Allocator{procedure = OwnedAdamTestAllocatorProc, data = &state}
	modelBytes: [size_of(Sequential(1, 2, 2))]u8
	copy(modelBytes[:], mem.slice_ptr((^u8)(rawptr(&model)), len(modelBytes)))
	testing.expect(t, !SequentialOwnedAdamInit(&model, (^SequentialOwnedAdam)(rawptr(&model)), allocator = allocator))
	OwnedAdamTestExpectBytes(t, rawptr(&model), modelBytes[:])

	dense := TestDenseStorage(&model.layers[0])
	oldValues, oldGradients := dense.weights.value.data, dense.weights.grad.data
	// The allocator field lies outside Adam itself but is part of the owner.
	ownedValues := mem.slice_ptr((^f32)(rawptr(&owned.allocator)), 2)
	dense.weights.value.data = ownedValues
	_, _, valid := SequentialAdamRequirements(&model)
	testing.expect(t, valid && !SequentialOwnedAdamInit(&model, &owned, allocator = allocator))
	dense.weights.value.data = oldValues
	dense.weights.grad.data = ownedValues
	_, _, valid = SequentialAdamRequirements(&model)
	testing.expect(t, valid && !SequentialOwnedAdamInit(&model, &owned, allocator = allocator))
	dense.weights.grad.data = oldGradients
	testing.expect(t, state.attempts == 0 && SequentialOwnedAdamOptimizer(&owned) == nil)
	OwnedAdamTestExpectBytes(t, rawptr(&model), modelBytes[:])

	// Even a broken allocator returning an owner's non-Adam field is rejected.
	ownerAlias := OwnedAdamTestAliasAllocator{backing = context.allocator, alias = rawptr(&owned.allocator)}
	ownerAllocator := mem.Allocator{procedure = OwnedAdamTestAliasAllocatorProc, data = &ownerAlias}
	testing.expect(t, !SequentialOwnedAdamInit(&model, &owned, allocator = ownerAllocator))
	testing.expect(t, ownerAlias.allocations == 3 && ownerAlias.frees == 3 && ownerAlias.aliasFrees == 1 && SequentialOwnedAdamOptimizer(&owned) == nil)
	OwnedAdamTestExpectBytes(t, rawptr(&model), modelBytes[:])

	// SequentialAdamInit also rejects allocations overlapping rebound parameters.
	backing := [2]u64{0x400000003f800000, 0x123456789abcdef0}
	before := backing
	dense.weights.value.data = mem.slice_ptr((^f32)(rawptr(&backing)), 2)
	parameterAlias := OwnedAdamTestAliasAllocator{backing = context.allocator, alias = rawptr(&backing)}
	parameterAllocator := mem.Allocator{procedure = OwnedAdamTestAliasAllocatorProc, data = &parameterAlias}
	testing.expect(t, !SequentialOwnedAdamInit(&model, &owned, allocator = parameterAllocator))
	testing.expect(t, parameterAlias.allocations == 3 && parameterAlias.frees == 3 && parameterAlias.aliasFrees == 1 && backing == before)
	dense.weights.value.data = oldValues
	OwnedAdamTestExpectBytes(t, rawptr(&model), modelBytes[:])
}

@(test)
OwnedAdamCopiesAndRepeatedDestroy :: proc(t: ^testing.T) {
	model: Sequential(1, 1, 2)
	owned: SequentialOwnedAdam
	state := OwnedAdamTestAllocator{backing = context.allocator}
	allocator := mem.Allocator{procedure = OwnedAdamTestAllocatorProc, data = &state}
	ok := SequentialInit(&model, 1, 17) && SequentialAddDense(&model, 1) && SequentialOwnedAdamInit(&model, &owned, allocator = allocator)
	testing.expect(t, ok)
	if !ok { return }
	defer SequentialOwnedAdamDestroy(&owned)
	adam := SequentialOwnedAdamOptimizer(&owned)
	for parameter in adam.parameters { for &gradient in parameter.grad.data { gradient = 1 } }
	testing.expect(t, AdamStep(adam) && adam.step == 1)
	ownedCopy := owned
	copyBytes, liveBytes: [size_of(SequentialOwnedAdam)]u8
	copy(copyBytes[:], mem.slice_ptr((^u8)(rawptr(&ownedCopy)), len(copyBytes)))
	copy(liveBytes[:], mem.slice_ptr((^u8)(rawptr(&owned)), len(liveBytes)))
	firstBefore, secondBefore := [2]f32{adam.firstMoment[0], adam.firstMoment[1]}, [2]f32{adam.secondMoment[0], adam.secondMoment[1]}
	weightBefore, biasBefore := TestDenseStorage(&model.layers[0]).weightData, TestDenseStorage(&model.layers[0]).biasData
	testing.expect(t, SequentialOwnedAdamOptimizer(nil) == nil && SequentialOwnedAdamOptimizer(&ownedCopy) == nil && !SequentialOwnedAdamDestroy(nil))
	_, _, _, valid := SequentialOwnedAdamStorage(&ownedCopy)
	testing.expect(t, !valid && !SequentialOwnedAdamDestroy(&ownedCopy))
	testing.expect(t, !SequentialOwnedAdamInit(&model, &ownedCopy, allocator = allocator))
	testing.expect(t, !SequentialOwnedAdamInit(&model, &owned, allocator = allocator))
	OwnedAdamTestExpectBytes(t, rawptr(&ownedCopy), copyBytes[:])
	OwnedAdamTestExpectBytes(t, rawptr(&owned), liveBytes[:])
	testing.expect(t, state.attempts == 3 && state.frees == 0 && SequentialOwnedAdamOptimizer(&owned) == adam && adam.step == 1)
	testing.expect(t, [2]f32{adam.firstMoment[0], adam.firstMoment[1]} == firstBefore && [2]f32{adam.secondMoment[0], adam.secondMoment[1]} == secondBefore)
	testing.expect(t, TestDenseStorage(&model.layers[0]).weightData == weightBefore && TestDenseStorage(&model.layers[0]).biasData == biasBefore)
	testing.expect(t, AdamStep(adam) && adam.step == 2)
	weights, bias := TestDenseStorage(&model.layers[0]).weightData, TestDenseStorage(&model.layers[0]).biasData
	testing.expect(t, SequentialOwnedAdamDestroy(&owned) && SequentialOwnedAdamDestroy(&owned) && state.frees == 3)
	testing.expect(t, !SequentialOwnedAdamDestroy(&ownedCopy) && !SequentialOwnedAdamInit(&model, &ownedCopy, allocator = allocator) && state.frees == 3)
	OwnedAdamTestExpectBytes(t, rawptr(&ownedCopy), copyBytes[:])
	testing.expect(t, SequentialOwnedAdamInit(&model, &owned, allocator = allocator))
	fresh := SequentialOwnedAdamOptimizer(&owned)
	testing.expect(t, fresh == adam && fresh.step == 0 && fresh.firstMoment[0] == 0 && fresh.secondMoment[0] == 0)
	testing.expect(t, fresh.learningRate == 0.001 && fresh.beta1 == 0.9 && fresh.beta2 == 0.999 && fresh.epsilon == 1e-8)
	testing.expect(t, TestDenseStorage(&model.layers[0]).weightData == weights && TestDenseStorage(&model.layers[0]).biasData == bias)
	testing.expect(t, SequentialOwnedAdamDestroy(&owned) && state.attempts == 6 && state.frees == 6)
}

@(test)
OwnedAdamEmptyAndSpatial :: proc(t: ^testing.T) {
	empty: Sequential(2, 1, 2)
	owned: SequentialOwnedAdam
	ok := SequentialInit(&empty, 1) && SequentialAddActivation(&empty, .Tanh) && SequentialOwnedAdamInit(&empty, &owned, allocator = mem.nil_allocator())
	testing.expect(t, ok)
	if !ok { return }
	adam := SequentialOwnedAdamOptimizer(&owned)
	parameters, first, second, valid := SequentialOwnedAdamStorage(&owned)
	testing.expect(t, valid && len(parameters) == 0 && len(first) == 0 && len(second) == 0 && AdamStep(adam) && adam.step == 1)
	testing.expect(t, !SequentialOwnedAdamInit(&empty, &owned, allocator = mem.nil_allocator()) && SequentialOwnedAdamDestroy(&owned))

	spatial: Sequential(6, 16, 2)
	ok = SequentialInitSpatial(&spatial, 3, 3, 1, 42) && SequentialAddConv2D(&spatial, 2, 2, 2) &&
		SequentialAddActivation(&spatial, .Relu) && SequentialAddPool2D(&spatial, .Max, 2, 2, 1) &&
		SequentialAddFlatten(&spatial) && SequentialAddDense(&spatial, 1) && SequentialAddActivation(&spatial, .Softmax) &&
		SequentialOwnedAdamInit(&spatial, &owned, learningRate = 0.1)
	testing.expect(t, ok)
	if !ok { return }
	defer SequentialOwnedAdamDestroy(&owned)
	adam = SequentialOwnedAdamOptimizer(&owned)
	conv := &spatial.layers[0].storage.(Conv2DStorage(16))
	dense := TestDenseStorage(&spatial.layers[4])
	testing.expect(t, len(adam.parameters) == 4 && len(adam.firstMoment) == 13 && adam.parameters[0] == &conv.weights && adam.parameters[1] == &conv.bias && adam.parameters[2] == &dense.weights && adam.parameters[3] == &dense.bias)
	for parameter in adam.parameters { for &gradient in parameter.grad.data { gradient = 1 } }
	old := conv.weightData[0]
	testing.expect(t, AdamStep(adam) && adam.step == 1 && math.abs(conv.weightData[0]-(old-0.1)) < 0.000001)
}

@(test)
OwnedAdamCompiledTrainingMatchesWorkspace :: proc(t: ^testing.T) {
	model, reference: Sequential(4, 3, 2)
	owned: SequentialOwnedAdam
	workspace: SequentialAdamWorkspace(4, 13)
	compiled, referenceCompiled: CompiledSequential(4, 3, 2)
	ok := SequentialInit(&model, 2, 17) && SequentialAddDense(&model, 3) && SequentialAddActivation(&model, .Tanh) && SequentialAddDropout(&model, 0.25) && SequentialAddDense(&model, 1) &&
		SequentialInit(&reference, 2, 17) && SequentialAddDense(&reference, 3) && SequentialAddActivation(&reference, .Tanh) && SequentialAddDropout(&reference, 0.25) && SequentialAddDense(&reference, 1) &&
		SequentialOwnedAdamInit(&model, &owned, 0.02, 0.8, 0.95, 1e-6)
	testing.expect(t, ok)
	if !ok { return }
	defer SequentialOwnedAdamDestroy(&owned)
	ok = SequentialAdamWorkspaceInit(&reference, &workspace, 0.02, 0.8, 0.95, 1e-6) &&
		SequentialCompile(&compiled, &model, optimizer = SequentialOwnedAdamOptimizer(&owned)) &&
		SequentialCompile(&referenceCompiled, &reference, optimizer = SequentialAdamWorkspaceOptimizer(&workspace))
	testing.expect(t, ok)
	if !ok { return }
	initialWeights := TestDenseStorage(&model.layers[0]).weightData
	inputs := [6]f32{1, 2, -1, 3, 0, 1}
	targets := [3]f32{1, -1, 0.5}
	indices: [3]int
	state, referenceState: u64 = 7, 7
	options := SequentialFitOptionsDefault()
	options.epochs = 3
	loss, fitOk := CompiledSequentialFitAuto(&compiled, inputs[:], targets[:], &state, options)
	referenceLoss, referenceOk := CompiledSequentialFitWithOptions(&referenceCompiled, inputs[:], targets[:], indices[:], &referenceState, options)
	adam := SequentialOwnedAdamOptimizer(&owned)
	testing.expect(t, fitOk && referenceOk && loss == referenceLoss && state == referenceState && adam.step == 6 && adam.step == workspace.optimizer.step)
	testing.expect(t, TestDenseStorage(&model.layers[0]).weightData != initialWeights)
	for i in 0..<13 { testing.expect(t, adam.firstMoment[i] == workspace.firstMoment[i] && adam.secondMoment[i] == workspace.secondMoment[i]) }
	for index in ([2]int{0, 3}) {
		a, b := TestDenseStorage(&model.layers[index]), TestDenseStorage(&reference.layers[index])
		testing.expect(t, a.weightData == b.weightData && a.biasData == b.biasData)
	}
}

@(test)
OwnedAdamCheckpointContinuity :: proc(t: ^testing.T) {
	model, restored: Sequential(3, 3, 2)
	owned, restoredOwned: SequentialOwnedAdam
	ok := SequentialInit(&model, 2, 11) && SequentialAddDense(&model, 3) && SequentialAddActivation(&model, .Tanh) && SequentialAddDense(&model, 1) &&
		SequentialInit(&restored, 2, 99) && SequentialAddDense(&restored, 3) && SequentialAddActivation(&restored, .Tanh) && SequentialAddDense(&restored, 1) &&
		SequentialOwnedAdamInit(&model, &owned, 0.01, 0.8, 0.95, 1e-6)
	testing.expect(t, ok)
	if !ok { return }
	defer SequentialOwnedAdamDestroy(&owned)
	ok = SequentialOwnedAdamInit(&restored, &restoredOwned)
	testing.expect(t, ok)
	if !ok { return }
	defer SequentialOwnedAdamDestroy(&restoredOwned)
	inputs := [10]f32{-2, 1, -1, 2, 0, -1, 1, 3, 3, 0.5}
	targets := [5]f32{1, 0, 2, -1, 4}
	indices, restoredIndices: [5]int
	state, restoredState: u64 = 55, 0
	adam, restoredAdam := SequentialOwnedAdamOptimizer(&owned), SequentialOwnedAdamOptimizer(&restoredOwned)
	_, trained := SequentialFitBatches(&model, inputs[:], targets[:], indices[:], &state, epochs = 3, optimizer = adam)
	checkpoint, roundTrip: [1024]u8
	size, saved := CheckpointWrite(&model, adam, state, checkpoint[:])
	testing.expect(t, trained && saved && adam.step == 9)
	if !trained || !saved { return }
	parameters, first, second, valid := SequentialOwnedAdamStorage(&restoredOwned)
	testing.expect(t, valid && len(parameters) == 4 && len(first) == 13 && len(second) == 13)
	if !valid { return }
	testing.expect(t, !CheckpointRead(&restored, restoredAdam, &restoredState, checkpoint[:size-1], parameters, first, second) && restoredAdam.step == 0 && restoredState == 0)
	loaded := CheckpointRead(&restored, restoredAdam, &restoredState, checkpoint[:size], parameters, first, second)
	testing.expect(t, loaded && restoredState == state && SequentialOwnedAdamOptimizer(&restoredOwned) == restoredAdam && restoredAdam.step == adam.step)
	if !loaded { return }
	testing.expect(t, restoredAdam.learningRate == adam.learningRate && restoredAdam.beta1 == adam.beta1 && restoredAdam.beta2 == adam.beta2 && restoredAdam.epsilon == adam.epsilon)
	for i in 0..<13 { testing.expect(t, first[i] == adam.firstMoment[i] && second[i] == adam.secondMoment[i]) }
	size2, saved2 := CheckpointWrite(&restored, restoredAdam, restoredState, roundTrip[:])
	testing.expect(t, saved2 && size2 == size)
	if saved2 && size2 == size { for value, i in checkpoint[:size] { testing.expect(t, value == roundTrip[i]) } }
	compiled, restoredCompiled: CompiledSequential(3, 3, 2)
	ok = SequentialCompile(&compiled, &model, optimizer = adam) && SequentialCompile(&restoredCompiled, &restored, optimizer = restoredAdam)
	testing.expect(t, ok)
	if !ok { return }
	loss, fitOk := CompiledSequentialFit(&compiled, inputs[:], targets[:], indices[:], &state, epochs = 4)
	restoredLoss, restoredFitOk := CompiledSequentialFit(&restoredCompiled, inputs[:], targets[:], restoredIndices[:], &restoredState, epochs = 4)
	testing.expect(t, fitOk && restoredFitOk && loss == restoredLoss && state == restoredState && adam.step == 21 && restoredAdam.step == adam.step)
	for i in 0..<13 { testing.expect(t, first[i] == adam.firstMoment[i] && second[i] == adam.secondMoment[i]) }
	for index in ([2]int{0, 2}) {
		a, b := TestDenseStorage(&model.layers[index]), TestDenseStorage(&restored.layers[index])
		testing.expect(t, a.weightData == b.weightData && a.biasData == b.biasData)
	}
}

@(test)
OwnedAdamCheckpointStorageCapacity :: proc(t: ^testing.T) {
	small, large, destination: Sequential(3, 3, 2)
	smallOwner, largeOwner, destinationOwner: SequentialOwnedAdam
	ok := SequentialInit(&small, 1, 5) && SequentialAddDense(&small, 1) &&
		SequentialInit(&large, 2, 7) && SequentialAddDense(&large, 3) && SequentialAddActivation(&large, .Tanh) && SequentialAddDense(&large, 1) &&
		SequentialInit(&destination, 2, 9) && SequentialAddDense(&destination, 3) && SequentialAddActivation(&destination, .Tanh) && SequentialAddDense(&destination, 1) &&
		SequentialOwnedAdamInit(&small, &smallOwner)
	testing.expect(t, ok)
	if !ok { return }
	defer SequentialOwnedAdamDestroy(&smallOwner)
	ok = SequentialOwnedAdamInit(&large, &largeOwner)
	testing.expect(t, ok)
	if !ok { return }
	defer SequentialOwnedAdamDestroy(&largeOwner)
	ok = SequentialOwnedAdamInit(&destination, &destinationOwner)
	testing.expect(t, ok)
	if !ok { return }
	defer SequentialOwnedAdamDestroy(&destinationOwner)
	smallAdam, largeAdam := SequentialOwnedAdamOptimizer(&smallOwner), SequentialOwnedAdamOptimizer(&largeOwner)
	for parameter in smallAdam.parameters { for &gradient in parameter.grad.data { gradient = 1 } }
	for parameter in largeAdam.parameters { for &gradient in parameter.grad.data { gradient = 2 } }
	testing.expect(t, AdamStep(smallAdam) && AdamStep(largeAdam) && AdamStep(largeAdam))
	smallData, largeData, roundTrip: [1024]u8
	smallSize, smallSaved := CheckpointWrite(&small, smallAdam, 31, smallData[:])
	largeSize, largeSaved := CheckpointWrite(&large, largeAdam, 73, largeData[:])
	testing.expect(t, smallSaved && largeSaved)
	if !smallSaved || !largeSaved { return }

	// An insufficiently sized owner fails without changing model, state or Adam.
	smallParameters, smallFirst, smallSecond, valid := SequentialOwnedAdamStorage(&smallOwner)
	testing.expect(t, valid && len(smallParameters) == 2 && len(smallFirst) == 2 && len(smallSecond) == 2)
	if !valid { return }
	modelBytes: [size_of(Sequential(3, 3, 2))]u8
	ownerBytes: [size_of(SequentialOwnedAdam)]u8
	copy(modelBytes[:], mem.slice_ptr((^u8)(rawptr(&small)), len(modelBytes)))
	copy(ownerBytes[:], mem.slice_ptr((^u8)(rawptr(&smallOwner)), len(ownerBytes)))
	oldFirst, oldSecond := [2]f32{smallFirst[0], smallFirst[1]}, [2]f32{smallSecond[0], smallSecond[1]}
	shuffle: u64 = 44
	testing.expect(t, !CheckpointRead(&small, smallAdam, &shuffle, largeData[:largeSize], smallParameters, smallFirst, smallSecond) && shuffle == 44)
	OwnedAdamTestExpectBytes(t, rawptr(&small), modelBytes[:])
	OwnedAdamTestExpectBytes(t, rawptr(&smallOwner), ownerBytes[:])
	testing.expect(t, [2]f32{smallFirst[0], smallFirst[1]} == oldFirst && [2]f32{smallSecond[0], smallSecond[1]} == oldSecond)

	// Loading a smaller architecture shortens Adam's slices, not the owner's
	// original storage; a later larger restore can reuse the full capacity.
	destinationAdam := SequentialOwnedAdamOptimizer(&destinationOwner)
	parameters, first, second, storageOk := SequentialOwnedAdamStorage(&destinationOwner)
	testing.expect(t, storageOk && len(parameters) == 4 && len(first) == 13 && len(second) == 13)
	if !storageOk { return }
	ok = CheckpointRead(&destination, destinationAdam, &shuffle, smallData[:smallSize], parameters, first, second)
	testing.expect(t, ok && shuffle == 31 && destinationAdam.step == 1 && len(destinationAdam.parameters) == 2 && len(destinationAdam.firstMoment) == 2)
	if !ok { return }
	fullParameters, fullFirst, fullSecond, fullOk := SequentialOwnedAdamStorage(&destinationOwner)
	testing.expect(t, fullOk && len(fullParameters) == 4 && len(fullFirst) == 13 && len(fullSecond) == 13 &&
		raw_data(fullParameters) == raw_data(parameters) && raw_data(fullFirst) == raw_data(first) && raw_data(fullSecond) == raw_data(second))
	if !fullOk { return }
	ok = CheckpointRead(&destination, destinationAdam, &shuffle, largeData[:largeSize], fullParameters, fullFirst, fullSecond)
	testing.expect(t, ok && shuffle == 73 && destinationAdam.step == 2 && len(destinationAdam.parameters) == 4 && len(destinationAdam.firstMoment) == 13)
	if !ok { return }
	size, saved := CheckpointWrite(&destination, destinationAdam, shuffle, roundTrip[:])
	testing.expect(t, saved && size == largeSize)
	if saved && size == largeSize { for value, i in largeData[:largeSize] { testing.expect(t, value == roundTrip[i]) } }
}
