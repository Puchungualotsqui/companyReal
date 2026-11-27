package nn

import "core:mem"
import "core:testing"

AutoFitCountingAllocator :: struct {
	backing: mem.Allocator,
	allocations, frees: int,
	returnPointerAndError: bool,
}

AutoFitCountingAllocatorProc :: proc(
	data: rawptr, mode: mem.Allocator_Mode, size, alignment: int,
	oldMemory: rawptr, oldSize: int, loc := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	state := (^AutoFitCountingAllocator)(data)
	if mode == .Alloc {
		state.allocations += 1
		memory, err := state.backing.procedure(state.backing.data, mode, size, alignment, oldMemory, oldSize, loc)
		if state.returnPointerAndError && raw_data(memory) != nil { return memory, .Out_Of_Memory }
		return memory, err
	}
	if mode == .Free { state.frees += 1 }
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
	testing.expect(t, allocatorState.allocations == 1 && allocatorState.frees == 1)
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
	testing.expect(t, !ok && allocatorState.allocations == 1 && allocatorState.frees == 1 && state == 9)
	testing.expect(t, TestDenseStorage(&model.layers[0]).weightData == weights && TestDenseStorage(&model.layers[0]).biasData == bias)
	_, ok = CompiledSequentialFitAuto(&compiled, nil, targets[:], &state, allocator = allocator)
	testing.expect(t, !ok && allocatorState.allocations == 1 && allocatorState.frees == 1 && state == 9)
	allocatorState.returnPointerAndError = true
	_, ok = CompiledSequentialFitAuto(&compiled, inputs[:], targets[:], &state, allocator = allocator)
	testing.expect(t, !ok && allocatorState.allocations == 2 && allocatorState.frees == 2 && state == 9)
	allocatorState.returnPointerAndError = false
	// Even a failure after an earlier minibatch has updated the model frees scratch.
	lateTargets := [3]f32{0, 1, 3.4e38}
	options.epochs, options.shuffle = 1, false
	_, ok = CompiledSequentialFitAuto(&compiled, inputs[:], lateTargets[:], &state, options, allocator)
	testing.expect(t, !ok && allocatorState.allocations == 3 && allocatorState.frees == 3 && state == 9)
}
