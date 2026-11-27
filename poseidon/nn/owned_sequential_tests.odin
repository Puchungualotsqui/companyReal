package nn

import "core:mem"
import "core:testing"

OwnedSequentialTestAllocation :: enum { Normal, Nil, Error, PointerAndError }

// Tracks a single outstanding allocation, including an allocation returned with
// an error. A failed free deliberately leaves the block available for retry.
OwnedSequentialTestAllocator :: struct {
	backing: mem.Allocator,
	allocation: OwnedSequentialTestAllocation,
	live: rawptr,
	allocations, frees, successfulFrees, badFrees: int,
	lastSize, lastAlignment: int,
	failNextFree: bool,
}

OwnedSequentialTestAllocatorProc :: proc(
	data: rawptr, mode: mem.Allocator_Mode, size, alignment: int,
	oldMemory: rawptr, oldSize: int, loc := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	state := (^OwnedSequentialTestAllocator)(data)
	switch mode {
	case .Alloc:
		state.allocations += 1
		state.lastSize, state.lastAlignment = size, alignment
		switch state.allocation {
		case .Nil:   return nil, nil
		case .Error: return nil, .Out_Of_Memory
		case .Normal, .PointerAndError:
		}
		bytes, err := state.backing.procedure(state.backing.data, mode, size, alignment, oldMemory, oldSize, loc)
		if raw_data(bytes) != nil {
			state.live = raw_data(bytes)
			if state.allocation == .PointerAndError { return bytes, .Out_Of_Memory }
		}
		return bytes, err
	case .Free:
		state.frees += 1
		if oldMemory == nil || oldMemory != state.live {
			state.badFrees += 1
			return nil, .Invalid_Pointer
		}
		if state.failNextFree {
			state.failNextFree = false
			return nil, .Invalid_Argument
		}
		bytes, err := state.backing.procedure(state.backing.data, mode, size, alignment, oldMemory, oldSize, loc)
		if err == nil {
			state.live = nil
			state.successfulFrees += 1
		}
		return bytes, err
	case .Free_All, .Resize, .Query_Features, .Query_Info, .Alloc_Non_Zeroed, .Resize_Non_Zeroed:
		return state.backing.procedure(state.backing.data, mode, size, alignment, oldMemory, oldSize, loc)
	}
	return nil, .Invalid_Argument
}

@(test)
OwnedSequentialVectorCompiledTraining :: proc(t: ^testing.T) {
	state := OwnedSequentialTestAllocator{backing = context.allocator}
	allocator := mem.Allocator{procedure = OwnedSequentialTestAllocatorProc, data = &state}
	owned: OwnedSequential(1, 1, 2)
	reference: Sequential(1, 1, 2)
	ok := OwnedSequentialInit(&owned, 1, seed = 0, allocator = allocator)
	testing.expect(t, ok)
	if !ok { return }
	defer OwnedSequentialDestroy(&owned)
	model := OwnedSequentialModel(&owned)
	testing.expect(t, model != nil && rawptr(model) == state.live)
	if model == nil { return }
	testing.expect(t, model.self == rawptr(model) && model.randomState != 0)
	testing.expect(t, raw_data(model.input.value.shape) == &model.inputShape[0] && raw_data(model.input.value.data) == &model.inputData[0])
	testing.expect(t, state.allocations == 1 && state.frees == 0 && state.lastSize == size_of(Sequential(1, 1, 2)) && state.lastAlignment == align_of(Sequential(1, 1, 2)))
	ok = SequentialInit(&reference, 1, 0) && SequentialAddDense(model, 1) && SequentialAddDense(&reference, 1)
	testing.expect(t, ok && OwnedSequentialModel(&owned) == model)
	if !ok { return }
	workspace, referenceWorkspace: SequentialAdamWorkspace(2, 2)
	compiled, referenceCompiled: CompiledSequential(1, 1, 2)
	ok = SequentialAdamWorkspaceInit(model, &workspace, learningRate = 0.03) &&
		SequentialAdamWorkspaceInit(&reference, &referenceWorkspace, learningRate = 0.03) &&
		SequentialCompile(&compiled, model, MSE{}, SequentialAdamWorkspaceOptimizer(&workspace)) &&
		SequentialCompile(&referenceCompiled, &reference, MSE{}, SequentialAdamWorkspaceOptimizer(&referenceWorkspace))
	testing.expect(t, ok)
	if !ok { return }
	inputs := [5]f32{-2, -1, 0, 1, 2}
	targets := [5]f32{-3, -1, 1, 3, 5}
	before, evaluated := CompiledSequentialEvaluate(&compiled, inputs[:], targets[:])
	indices, referenceIndices: [5]int
	loss, trained := CompiledSequentialFit(&compiled, inputs[:], targets[:], indices[:], nil, epochs = 80, shuffle = false)
	referenceLoss, referenceTrained := CompiledSequentialFit(&referenceCompiled, inputs[:], targets[:], referenceIndices[:], nil, epochs = 80, shuffle = false)
	after, reevaluated := CompiledSequentialEvaluate(&compiled, inputs[:], targets[:])
	testing.expect(t, evaluated && trained && referenceTrained && reevaluated && after < before && loss == referenceLoss)
	testing.expect(t, workspace.optimizer.step == referenceWorkspace.optimizer.step && workspace.firstMoment == referenceWorkspace.firstMoment && workspace.secondMoment == referenceWorkspace.secondMoment)
	predictions, expected: [5]f32
	predicted := CompiledSequentialPredict(&compiled, inputs[:], predictions[:])
	referencePredicted := CompiledSequentialPredict(&referenceCompiled, inputs[:], expected[:])
	testing.expect(t, predicted && referencePredicted && predictions == expected)
	borrowed, predictedOne := SequentialPredict(model, inputs[:1])
	testing.expect(t, predictedOne && len(borrowed) == 1 && borrowed[0] == predictions[0])
	// Do not use model, borrowed output, compiled, or workspace after this point.
	testing.expect(t, OwnedSequentialDestroy(&owned))
	testing.expect(t, OwnedSequentialModel(&owned) == nil && state.live == nil && state.frees == 1 && state.successfulFrees == 1 && state.badFrees == 0)
}

@(test)
OwnedSequentialLargeModelOffStack :: proc(t: ^testing.T) {
	state := OwnedSequentialTestAllocator{backing = context.allocator}
	allocator := mem.Allocator{procedure = OwnedSequentialTestAllocatorProc, data = &state}
	owned: OwnedSequential(1, 1024, 2)
	ok := OwnedSequentialInit(&owned, 1, allocator = allocator)
	testing.expect(t, ok && state.lastSize > 8 * 1024 * 1024)
	if !ok { return }
	defer OwnedSequentialDestroy(&owned)
	model := OwnedSequentialModel(&owned)
	testing.expect(t, model != nil && model.self == rawptr(model))
	if model == nil { return }
	ok = SequentialAddActivation(model, .Relu)
	testing.expect(t, ok)
	if !ok { return }
	inputs := [1]f32{1}
	output, predicted := SequentialPredict(model, inputs[:])
	testing.expect(t, predicted && len(output) == 1 && output[0] == 1)
	testing.expect(t, OwnedSequentialDestroy(&owned) && state.live == nil && state.successfulFrees == 1)
}

@(test)
OwnedSequentialSpatialCompiledTraining :: proc(t: ^testing.T) {
	owned: OwnedSequential(3, 4, 2)
	reference: Sequential(3, 4, 2)
	ok := OwnedSequentialInitSpatial(&owned, 2, 2, 1, seed = 42)
	testing.expect(t, ok)
	if !ok { return }
	defer OwnedSequentialDestroy(&owned)
	model := OwnedSequentialModel(&owned)
	if model == nil { testing.expect(t, false); return }
	testing.expect(t, model.inputWidth == 4 && model.inputShape == [4]int{2, 2, 2, 1})
	testing.expect(t, len(model.input.value.shape) == 4 && raw_data(model.input.value.shape) == &model.inputShape[0])
	ok = SequentialInitSpatial(&reference, 2, 2, 1, 42) &&
		SequentialAddConv2D(model, 1, 1, 1) && SequentialAddFlatten(model) && SequentialAddDense(model, 1) &&
		SequentialAddConv2D(&reference, 1, 1, 1) && SequentialAddFlatten(&reference) && SequentialAddDense(&reference, 1)
	compiled, referenceCompiled: CompiledSequential(3, 4, 2)
	ok = ok && SequentialCompile(&compiled, model, MSE{}, SequentialSGD{0.02}) &&
		SequentialCompile(&referenceCompiled, &reference, MSE{}, SequentialSGD{0.02})
	testing.expect(t, ok)
	if !ok { return }
	inputs := [12]f32{1, 0, 0, 1, 0, 1, 1, 0, 1, 1, 0, 0}
	targets := [3]f32{1, 0, 2}
	indices, referenceIndices: [3]int
	loss, trained := CompiledSequentialFit(&compiled, inputs[:], targets[:], indices[:], nil, epochs = 15, shuffle = false)
	referenceLoss, referenceTrained := CompiledSequentialFit(&referenceCompiled, inputs[:], targets[:], referenceIndices[:], nil, epochs = 15, shuffle = false)
	predictions, expected: [3]f32
	predicted := CompiledSequentialPredict(&compiled, inputs[:], predictions[:])
	referencePredicted := CompiledSequentialPredict(&referenceCompiled, inputs[:], expected[:])
	testing.expect(t, trained && referenceTrained && loss == referenceLoss && predicted && referencePredicted && predictions == expected)
}

@(test)
OwnedSequentialInvalidInitializationRollback :: proc(t: ^testing.T) {
	state := OwnedSequentialTestAllocator{backing = context.allocator}
	allocator := mem.Allocator{procedure = OwnedSequentialTestAllocatorProc, data = &state}
	owned: OwnedSequential(1, 4, 2)
	for width in ([4]int{-1, 0, 5, max(int)}) {
		testing.expect(t, !OwnedSequentialInit(&owned, width, allocator = allocator))
		testing.expect(t, OwnedSequentialModel(&owned) == nil && owned.model == nil && owned.self == nil && owned.allocator.procedure == nil && owned.allocator.data == nil)
		testing.expect(t, state.live == nil && state.allocations == state.successfulFrees)
	}
	for dims in ([8][3]int{{0, 1, 1}, {1, 0, 1}, {1, 1, 0}, {-1, 1, 1}, {1, -1, 1}, {1, 1, -1}, {2, max(int), 1}, {1, 1, max(int)}}) {
		testing.expect(t, !OwnedSequentialInitSpatial(&owned, dims[0], dims[1], dims[2], allocator = allocator))
		testing.expect(t, OwnedSequentialModel(&owned) == nil && owned.model == nil && owned.self == nil && owned.allocator.procedure == nil && owned.allocator.data == nil)
		testing.expect(t, state.live == nil && state.allocations == state.successfulFrees)
	}
	zeroLayers: OwnedSequential(0, 4, 2)
	zeroWidth: OwnedSequential(1, 0, 2)
	zeroBatch: OwnedSequential(1, 4, 0)
	testing.expect(t, !OwnedSequentialInit(&zeroLayers, 1, allocator = allocator))
	testing.expect(t, !OwnedSequentialInitSpatial(&zeroWidth, 1, 1, 1, allocator = allocator))
	testing.expect(t, !OwnedSequentialInit(&zeroBatch, 1, allocator = allocator))
	testing.expect(t, state.live == nil && state.allocations == 15 && state.frees == 15 && state.successfulFrees == 15 && state.badFrees == 0)
	// Failures did not poison the destination; it can subsequently be initialized.
	testing.expect(t, OwnedSequentialInit(&owned, 4, allocator = allocator))
	testing.expect(t, OwnedSequentialDestroy(&owned) && state.live == nil && state.successfulFrees == 16)
}

@(test)
OwnedSequentialAllocatorFailures :: proc(t: ^testing.T) {
	owned: OwnedSequential(1, 2, 2)
	nilOwner: ^OwnedSequential(1, 2, 2)
	state := OwnedSequentialTestAllocator{backing = context.allocator}
	allocator := mem.Allocator{procedure = OwnedSequentialTestAllocatorProc, data = &state}
	testing.expect(t, !OwnedSequentialInit(nilOwner, 1, allocator = allocator))
	testing.expect(t, !OwnedSequentialInitSpatial(nilOwner, 1, 1, 1, allocator = allocator))
	testing.expect(t, OwnedSequentialModel(nilOwner) == nil && !OwnedSequentialDestroy(nilOwner) && state.allocations == 0)
	testing.expect(t, OwnedSequentialModel(&owned) == nil && OwnedSequentialDestroy(&owned))
	testing.expect(t, !OwnedSequentialInit(&owned, 1, allocator = mem.nil_allocator()))
	testing.expect(t, !OwnedSequentialInitSpatial(&owned, 1, 1, 1, allocator = mem.Allocator{}))
	initialized := false
	{
		context.allocator = mem.nil_allocator()
		initialized = OwnedSequentialInit(&owned, 1)
	}
	testing.expect(t, !initialized)
	for mode in ([3]OwnedSequentialTestAllocation{.Nil, .Error, .PointerAndError}) {
		state.allocation = mode
		testing.expect(t, !OwnedSequentialInit(&owned, 1, allocator = allocator))
		testing.expect(t, !OwnedSequentialInitSpatial(&owned, 1, 1, 1, allocator = allocator))
		testing.expect(t, OwnedSequentialModel(&owned) == nil && owned.model == nil && owned.self == nil && owned.allocator.procedure == nil && owned.allocator.data == nil)
		testing.expect(t, state.live == nil && state.badFrees == 0)
	}
	testing.expect(t, state.allocations == 6 && state.frees == 2 && state.successfulFrees == 2)
	state.allocation = .Normal
	testing.expect(t, OwnedSequentialInit(&owned, 1, allocator = allocator))
	testing.expect(t, OwnedSequentialDestroy(&owned) && state.allocations == 7 && state.successfulFrees == 3 && state.live == nil)
}

@(test)
OwnedSequentialAllocatorCapturedAndFreeRetry :: proc(t: ^testing.T) {
	state := OwnedSequentialTestAllocator{backing = context.allocator}
	allocator := mem.Allocator{procedure = OwnedSequentialTestAllocatorProc, data = &state}
	owned: OwnedSequential(1, 1, 1)
	initialized := false
	{
		context.allocator = allocator
		initialized = OwnedSequentialInit(&owned, 1)
	}
	testing.expect(t, initialized && state.allocations == 1 && state.live != nil)
	if !initialized { return }
	defer OwnedSequentialDestroy(&owned)
	model := OwnedSequentialModel(&owned)
	state.failNextFree = true
	testing.expect(t, !OwnedSequentialDestroy(&owned) && OwnedSequentialModel(&owned) == nil && state.live == rawptr(model))
	testing.expect(t, state.frees == 1 && state.successfulFrees == 0)
	destroyed := false
	{
		context.allocator = mem.nil_allocator()
		destroyed = OwnedSequentialDestroy(&owned)
	}
	testing.expect(t, destroyed && state.frees == 2 && state.successfulFrees == 1 && state.live == nil && state.badFrees == 0)
	testing.expect(t, OwnedSequentialDestroy(&owned) && state.frees == 2)
	// An explicit allocator also overrides a different current context.
	{
		context.allocator = mem.nil_allocator()
		initialized = OwnedSequentialInitSpatial(&owned, 1, 1, 1, allocator = allocator)
	}
	testing.expect(t, initialized && state.allocations == 2)
	testing.expect(t, OwnedSequentialDestroy(&owned) && state.successfulFrees == 2 && state.live == nil)
}

@(test)
OwnedSequentialRollbackFreeFailureIsRetryable :: proc(t: ^testing.T) {
	state := OwnedSequentialTestAllocator{backing = context.allocator}
	allocator := mem.Allocator{procedure = OwnedSequentialTestAllocatorProc, data = &state}
	owned: OwnedSequential(1, 4, 2)
	state.failNextFree = true
	testing.expect(t, !OwnedSequentialInit(&owned, 5, allocator = allocator))
	testing.expect(t, owned.pending != nil && owned.self == rawptr(&owned) && owned.destroying &&
		OwnedSequentialModel(&owned) == nil && state.live == owned.pending && state.successfulFrees == 0)
	testing.expect(t, !OwnedSequentialInit(&owned, 1, allocator = allocator) && state.allocations == 1)
	testing.expect(t, OwnedSequentialDestroy(&owned) && state.live == nil && state.successfulFrees == 1 && owned.pending == nil)
	testing.expect(t, OwnedSequentialInit(&owned, 1, allocator = allocator))
	testing.expect(t, OwnedSequentialDestroy(&owned))
}

@(test)
OwnedSequentialCopyAndReinitializationGuards :: proc(t: ^testing.T) {
	state := OwnedSequentialTestAllocator{backing = context.allocator}
	allocator := mem.Allocator{procedure = OwnedSequentialTestAllocatorProc, data = &state}
	owned: OwnedSequential(1, 2, 2)
	ok := OwnedSequentialInit(&owned, 1, allocator = allocator)
	testing.expect(t, ok)
	if !ok { return }
	defer OwnedSequentialDestroy(&owned)
	model := OwnedSequentialModel(&owned)
	testing.expect(t, SequentialAddDense(model, 1))
	copyOfOwner := owned
	testing.expect(t, OwnedSequentialModel(&copyOfOwner) == nil)
	testing.expect(t, !OwnedSequentialInit(&copyOfOwner, 1, allocator = allocator))
	testing.expect(t, !OwnedSequentialInitSpatial(&copyOfOwner, 1, 1, 1, allocator = allocator))
	testing.expect(t, !OwnedSequentialDestroy(&copyOfOwner) && state.frees == 0)
	// Reinitialization of the original cannot replace a live allocation either.
	testing.expect(t, !OwnedSequentialInit(&owned, 2, allocator = allocator))
	testing.expect(t, !OwnedSequentialInitSpatial(&owned, 1, 1, 1, allocator = allocator))
	testing.expect(t, state.allocations == 1 && OwnedSequentialModel(&owned) == model && model.layerCount == 1)
	inputs := [1]f32{1}
	_, predicted := SequentialPredict(model, inputs[:])
	testing.expect(t, predicted && OwnedSequentialDestroy(&owned) && state.successfulFrees == 1)
	// A stale copied handle is rejected without dereferencing the freed model.
	testing.expect(t, OwnedSequentialModel(&copyOfOwner) == nil && !OwnedSequentialDestroy(&copyOfOwner))
	testing.expect(t, !OwnedSequentialInit(&copyOfOwner, 1, allocator = allocator) && state.allocations == 1)
	testing.expect(t, OwnedSequentialDestroy(&owned) && state.frees == 1)
	ok = OwnedSequentialInitSpatial(&owned, 1, 1, 2, allocator = allocator)
	testing.expect(t, ok && OwnedSequentialModel(&owned) != nil && state.allocations == 2)
	testing.expect(t, OwnedSequentialModel(&copyOfOwner) == nil && !OwnedSequentialDestroy(&copyOfOwner))
	testing.expect(t, OwnedSequentialDestroy(&owned) && state.successfulFrees == 2 && state.live == nil && state.badFrees == 0)
}
