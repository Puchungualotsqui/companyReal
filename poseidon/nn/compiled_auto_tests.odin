package nn

import "core:mem"
import "core:testing"

AutoFitCountingAllocator :: struct {
	backing: mem.Allocator,
	live: rawptr,
	allocations, frees, successfulFrees, invalidFrees: int,
	lastSize, lastAlignment: int,
	returnPointerAndError, failNextFree, freeBeforeError: bool,
}

AutoFitCountingAllocatorProc :: proc(
	data: rawptr, mode: mem.Allocator_Mode, size, alignment: int,
	oldMemory: rawptr, oldSize: int, loc := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	state := (^AutoFitCountingAllocator)(data)
	if mode == .Alloc {
		state.allocations += 1
		state.lastSize, state.lastAlignment = size, alignment
		memory, err := state.backing.procedure(state.backing.data, mode, size, alignment, oldMemory, oldSize, loc)
		state.live = raw_data(memory)
		if state.returnPointerAndError && state.live != nil { return memory, .Out_Of_Memory }
		return memory, err
	}
	if mode == .Free {
		state.frees += 1
		if oldMemory == nil || oldMemory != state.live {
			state.invalidFrees += 1
			return nil, .Invalid_Pointer
		}
		fail := state.failNextFree
		state.failNextFree = false
		if fail && !state.freeBeforeError { return nil, .Invalid_Argument }
		memory, err := state.backing.procedure(state.backing.data, mode, size, alignment, oldMemory, oldSize, loc)
		if err != nil { return memory, err }
		state.live = nil
		state.successfulFrees += 1
		if fail { return nil, .Invalid_Argument }
		return memory, nil
	}
	return state.backing.procedure(state.backing.data, mode, size, alignment, oldMemory, oldSize, loc)
}

@(test)
CompiledFitAutoMatchesExplicitStorage :: proc(t: ^testing.T) {
	model, reference: Sequential(1, 1, 2)
	workspace, referenceWorkspace: SequentialAdamWorkspace(2, 2)
	compiled, referenceCompiled: CompiledSequential(1, 1, 2)
	initialized := SequentialInit(&model, 1, 17) && SequentialAddDense(&model, 1) &&
		SequentialInit(&reference, 1, 17) && SequentialAddDense(&reference, 1) &&
		SequentialAdamWorkspaceInit(&model, &workspace, learningRate = 0.02) &&
		SequentialAdamWorkspaceInit(&reference, &referenceWorkspace, learningRate = 0.02) &&
		SequentialCompile(&compiled, &model, MSE{}, SequentialAdamWorkspaceOptimizer(&workspace)) &&
		SequentialCompile(&referenceCompiled, &reference, MSE{}, SequentialAdamWorkspaceOptimizer(&referenceWorkspace))
	testing.expect(t, initialized)
	if !initialized { return }
	inputs := [5]f32{-2, -1, 0, 1, 3}
	targets := [5]f32{1, 0, 2, -1, 4}
	indices: [5]int
	state, referenceState: u64 = 55, 55
	history, referenceHistory: [3]EpochMetrics
	metricHistory, referenceMetricHistory: [6]SupervisedEpochMetric
	metrics := [2]SupervisedMetric{.MeanAbsoluteError, .RootMeanSquaredError}
	tracking := SequentialFitMetricsTracking{metrics[:], metricHistory[:]}
	referenceTracking := SequentialFitMetricsTracking{metrics[:], referenceMetricHistory[:]}
	options := SequentialFitOptionsDefault()
	options.epochs, options.batchSize = 3, 2
	options.history, options.metricsMany = history[:], &tracking
	options.validationInputs, options.validationTargets = inputs[:], targets[:]
	referenceOptions := options
	referenceOptions.history, referenceOptions.metricsMany = referenceHistory[:], &referenceTracking
	allocatorState := AutoFitCountingAllocator{backing = context.allocator}
	allocator := mem.Allocator{procedure = AutoFitCountingAllocatorProc, data = &allocatorState}
	loss, ok := CompiledSequentialFitAuto(&compiled, inputs[:], targets[:], &state, options, allocator)
	referenceLoss, referenceOk := CompiledSequentialFitWithOptions(&referenceCompiled, inputs[:], targets[:], indices[:], &referenceState, referenceOptions)
	testing.expect(t, ok && referenceOk && loss == referenceLoss && state == referenceState)
	testing.expect(t, allocatorState.allocations == 1 && allocatorState.frees == 1 && allocatorState.successfulFrees == 1 && allocatorState.live == nil)
	testing.expect(t, allocatorState.lastSize == len(inputs)*size_of(int) && allocatorState.lastAlignment == align_of(int))
	testing.expect(t, history == referenceHistory && metricHistory == referenceMetricHistory)
	testing.expect(t, workspace.optimizer.step == referenceWorkspace.optimizer.step && workspace.firstMoment == referenceWorkspace.firstMoment && workspace.secondMoment == referenceWorkspace.secondMoment)
	testing.expect(t, TestDenseStorage(&model.layers[0]).weightData == TestDenseStorage(&reference.layers[0]).weightData && TestDenseStorage(&model.layers[0]).biasData == TestDenseStorage(&reference.layers[0]).biasData)
}

@(test)
CompiledFitAutoDefaultLocalShuffleState :: proc(t: ^testing.T) {
	model, reference: Sequential(1, 1, 2)
	compiled, referenceCompiled: CompiledSequential(1, 1, 2)
	initialized := SequentialInit(&model, 1, 17) && SequentialAddDense(&model, 1) &&
		SequentialInit(&reference, 1, 17) && SequentialAddDense(&reference, 1) &&
		SequentialCompile(&compiled, &model) && SequentialCompile(&referenceCompiled, &reference)
	testing.expect(t, initialized)
	if !initialized { return }
	inputs := [3]f32{-1, 0, 1}
	targets := [3]f32{0, 1, 2}
	indices: [3]int
	state: u64
	options := SequentialFitOptionsDefault()
	options.epochs = 3
	loss, ok := CompiledSequentialFitAuto(&compiled, inputs[:], targets[:], options = options)
	referenceLoss, referenceOk := CompiledSequentialFitWithOptions(&referenceCompiled, inputs[:], targets[:], indices[:], &state, options)
	testing.expect(t, ok && referenceOk && loss == referenceLoss && state != 0)
	testing.expect(t, TestDenseStorage(&model.layers[0]).weightData == TestDenseStorage(&reference.layers[0]).weightData && TestDenseStorage(&model.layers[0]).biasData == TestDenseStorage(&reference.layers[0]).biasData)
}

@(test)
CompiledFitAutoAllocationAndValidationFailures :: proc(t: ^testing.T) {
	model: Sequential(1, 1, 2)
	compiled: CompiledSequential(1, 1, 2)
	initialized := SequentialInit(&model, 1, 17) && SequentialAddDense(&model, 1) && SequentialCompile(&compiled, &model)
	testing.expect(t, initialized)
	if !initialized { return }
	inputs := [3]f32{-1, 0, 1}
	targets := [3]f32{0, 1, 2}
	state: u64 = 9
	weights, bias := TestDenseStorage(&model.layers[0]).weightData, TestDenseStorage(&model.layers[0]).biasData
	_, ok := CompiledSequentialFitAuto(&compiled, inputs[:], targets[:], &state, allocator = mem.nil_allocator())
	testing.expect(t, !ok && state == 9 && TestDenseStorage(&model.layers[0]).weightData == weights && TestDenseStorage(&model.layers[0]).biasData == bias)
	allocatorState := AutoFitCountingAllocator{backing = context.allocator}
	allocator := mem.Allocator{procedure = AutoFitCountingAllocatorProc, data = &allocatorState}
	options := SequentialFitOptionsDefault()
	options.epochs = -1
	_, ok = CompiledSequentialFitAuto(&compiled, inputs[:], targets[:], &state, options, allocator)
	testing.expect(t, !ok && allocatorState.allocations == 1 && allocatorState.frees == 1 && allocatorState.live == nil && state == 9)
	testing.expect(t, TestDenseStorage(&model.layers[0]).weightData == weights && TestDenseStorage(&model.layers[0]).biasData == bias)
	_, ok = CompiledSequentialFitAuto(&compiled, nil, targets[:], &state, allocator = allocator)
	testing.expect(t, !ok && allocatorState.allocations == 1 && allocatorState.frees == 1 && state == 9)
	allocatorState.returnPointerAndError = true
	_, ok = CompiledSequentialFitAuto(&compiled, inputs[:], targets[:], &state, allocator = allocator)
	testing.expect(t, !ok && allocatorState.allocations == 2 && allocatorState.frees == 2 && allocatorState.successfulFrees == 2 && allocatorState.live == nil && state == 9)
	allocatorState.returnPointerAndError = false
	// Even a failure after an earlier minibatch has updated the model frees scratch.
	lateTargets := [3]f32{0, 1, 3.4e38}
	options.epochs, options.shuffle = 1, false
	_, ok = CompiledSequentialFitAuto(&compiled, inputs[:], lateTargets[:], &state, options, allocator)
	testing.expect(t, !ok && allocatorState.allocations == 3 && allocatorState.frees == 3 && allocatorState.successfulFrees == 3 && allocatorState.invalidFrees == 0 && allocatorState.live == nil && state == 9)
}

@(test)
CompiledFitAutoFreeFailureAfterSuccessfulFit :: proc(t: ^testing.T) {
	model, reference: Sequential(1, 1, 2)
	workspace, referenceWorkspace: SequentialAdamWorkspace(2, 2)
	compiled, referenceCompiled: CompiledSequential(1, 1, 2)
	initialized := SequentialInit(&model, 1, 17) && SequentialAddDense(&model, 1) &&
		SequentialInit(&reference, 1, 17) && SequentialAddDense(&reference, 1) &&
		SequentialAdamWorkspaceInit(&model, &workspace, learningRate = 0.02) &&
		SequentialAdamWorkspaceInit(&reference, &referenceWorkspace, learningRate = 0.02) &&
		SequentialCompile(&compiled, &model, MSE{}, SequentialAdamWorkspaceOptimizer(&workspace)) &&
		SequentialCompile(&referenceCompiled, &reference, MSE{}, SequentialAdamWorkspaceOptimizer(&referenceWorkspace))
	testing.expect(t, initialized)
	if !initialized { return }
	inputs := [5]f32{-2, -1, 0, 1, 3}
	targets := [5]f32{1, 0, 2, -1, 4}
	indices: [5]int
	state, referenceState: u64 = 55, 55
	history, referenceHistory: [2]EpochMetrics
	options := SequentialFitOptionsDefault()
	options.epochs, options.history = 2, history[:]
	referenceOptions := options
	referenceOptions.history = referenceHistory[:]
	weights := TestDenseStorage(&model.layers[0]).weightData
	allocatorState := AutoFitCountingAllocator{backing = context.allocator, failNextFree = true}
	allocator := mem.Allocator{procedure = AutoFitCountingAllocatorProc, data = &allocatorState}
	defer {
		allocatorState.failNextFree = false
		_ = mem.free(allocatorState.live, allocator)
	}
	loss, ok := CompiledSequentialFitAuto(&compiled, inputs[:], targets[:], &state, options, allocator)
	referenceLoss, referenceOk := CompiledSequentialFitWithOptions(&referenceCompiled, inputs[:], targets[:], indices[:], &referenceState, referenceOptions)
	testing.expect(t, !ok && loss == 0 && referenceOk && referenceLoss > 0)
	testing.expect(t, allocatorState.allocations == 1 && allocatorState.frees == 1 && allocatorState.successfulFrees == 0 && allocatorState.live != nil)
	testing.expect(t, state == referenceState && state != 55 && history == referenceHistory)
	testing.expect(t, workspace.optimizer.step == referenceWorkspace.optimizer.step && workspace.optimizer.step > 0 && workspace.firstMoment == referenceWorkspace.firstMoment && workspace.secondMoment == referenceWorkspace.secondMoment)
	testing.expect(t, TestDenseStorage(&model.layers[0]).weightData != weights && TestDenseStorage(&model.layers[0]).weightData == TestDenseStorage(&reference.layers[0]).weightData && TestDenseStorage(&model.layers[0]).biasData == TestDenseStorage(&reference.layers[0]).biasData)
	// The test allocator tracks the otherwise inaccessible allocation for cleanup.
	cleanupError := mem.free(allocatorState.live, allocator)
	testing.expect(t, cleanupError == nil && allocatorState.live == nil && allocatorState.frees == 2 && allocatorState.invalidFrees == 0)
}

@(test)
CompiledFitAutoFreeFailureOnOtherFailurePaths :: proc(t: ^testing.T) {
	model: Sequential(1, 1, 2)
	compiled: CompiledSequential(1, 1, 2)
	initialized := SequentialInit(&model, 1, 17) && SequentialAddDense(&model, 1) && SequentialCompile(&compiled, &model)
	testing.expect(t, initialized)
	if !initialized { return }
	inputs := [3]f32{-1, 0, 1}
	targets := [3]f32{0, 1, 2}
	lateTargets := [3]f32{0, 1, 3.4e38}
	state: u64 = 9
	weights, bias := TestDenseStorage(&model.layers[0]).weightData, TestDenseStorage(&model.layers[0]).biasData
	allocatorState := AutoFitCountingAllocator{backing = context.allocator}
	allocator := mem.Allocator{procedure = AutoFitCountingAllocatorProc, data = &allocatorState}
	defer {
		allocatorState.failNextFree = false
		_ = mem.free(allocatorState.live, allocator)
	}
	// Exercise prevalidation, pointer-with-allocation-error, and partial-fit failures.
	for failureCase in 0..<3 {
		allocatorState.failNextFree = true
		allocatorState.returnPointerAndError = failureCase == 1
		options := SequentialFitOptionsDefault()
		options.epochs = -1
		fitTargets := targets[:]
		if failureCase == 1 { options.epochs = 1 }
		if failureCase == 2 {
			options.epochs, options.shuffle = 1, false
			fitTargets = lateTargets[:]
		}
		loss, ok := CompiledSequentialFitAuto(&compiled, inputs[:], fitTargets, &state, options, allocator)
		testing.expect(t, !ok && loss == 0 && state == 9)
		testing.expect(t, allocatorState.allocations == failureCase+1 && allocatorState.frees == 2*failureCase+1 && allocatorState.live != nil)
		if failureCase < 2 {
			testing.expect(t, TestDenseStorage(&model.layers[0]).weightData == weights && TestDenseStorage(&model.layers[0]).biasData == bias)
		} else {
			testing.expect(t, TestDenseStorage(&model.layers[0]).weightData != weights || TestDenseStorage(&model.layers[0]).biasData != bias)
		}
		cleanupError := mem.free(allocatorState.live, allocator)
		testing.expect(t, cleanupError == nil && allocatorState.live == nil && allocatorState.frees == 2*(failureCase+1) && allocatorState.invalidFrees == 0)
	}
}

@(test)
CompiledFitAutoDoesNotRetryAmbiguousFree :: proc(t: ^testing.T) {
	model: Sequential(1, 1, 2)
	compiled: CompiledSequential(1, 1, 2)
	initialized := SequentialInit(&model, 1, 17) && SequentialAddDense(&model, 1) && SequentialCompile(&compiled, &model)
	testing.expect(t, initialized)
	if !initialized { return }
	inputs := [2]f32{-1, 1}
	targets := [2]f32{0, 2}
	allocatorState := AutoFitCountingAllocator{backing = context.allocator, failNextFree = true, freeBeforeError = true}
	allocator := mem.Allocator{procedure = AutoFitCountingAllocatorProc, data = &allocatorState}
	defer {
		allocatorState.failNextFree = false
		_ = mem.free(allocatorState.live, allocator)
	}
	expected, evaluated := CompiledSequentialEvaluate(&compiled, inputs[:], targets[:])
	loss, ok := CompiledSequentialFitAuto(&compiled, inputs[:], targets[:], options = {}, allocator = allocator)
	testing.expect(t, evaluated && expected > 0 && !ok && loss == 0)
	testing.expect(t, allocatorState.allocations == 1 && allocatorState.frees == 1 && allocatorState.successfulFrees == 1 && allocatorState.invalidFrees == 0 && allocatorState.live == nil)
}

@(test)
CompiledFitAutoReportsUnsupportedArenaFree :: proc(t: ^testing.T) {
	model: Sequential(1, 1, 2)
	compiled: CompiledSequential(1, 1, 2)
	initialized := SequentialInit(&model, 1, 17) && SequentialAddDense(&model, 1) && SequentialCompile(&compiled, &model)
	testing.expect(t, initialized)
	if !initialized { return }
	inputs := [2]f32{-1, 1}
	targets := [2]f32{0, 2}
	weights, bias := TestDenseStorage(&model.layers[0]).weightData, TestDenseStorage(&model.layers[0]).biasData
	backing: [64]byte
	arena: mem.Arena
	mem.arena_init(&arena, backing[:])
	options := SequentialFitOptionsDefault()
	options.epochs, options.shuffle = 1, false
	loss, ok := CompiledSequentialFitAuto(&compiled, inputs[:], targets[:], options = options, allocator = mem.arena_allocator(&arena))
	testing.expect(t, !ok && loss == 0 && arena.offset >= len(inputs)*size_of(int))
	testing.expect(t, TestDenseStorage(&model.layers[0]).weightData != weights || TestDenseStorage(&model.layers[0]).biasData != bias)
	mem.arena_free_all(&arena)
	testing.expect(t, arena.offset == 0)
}
