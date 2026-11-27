package nn

import "../data"
import "../rl"
import "core:mem"
import "core:testing"

@(test)
PolicyRuntimeHistoryAndNormalizerParity :: proc(t: ^testing.T) {
	source: Sequential(3, 4, 4)
	specs := []SequentialLayerSpec{
		SequentialDenseSpec{3}, SequentialActivationSpec{.Tanh}, SequentialDenseSpec{2},
	}
	setup := SequentialInit(&source, 2, 17)
	_, specsOk := SequentialAddSpecs(&source, specs)
	setup = setup && specsOk
	testing.expect(t, setup)
	if !setup { return }
	mean, m2: [2]f64
	normalizer: data.RunningStandardizer
	testing.expect(t, data.RunningStandardizerInit(&normalizer, mean[:], m2[:], epsilon = 0.02))
	testing.expect(t, data.RunningStandardizerUpdate(&normalizer, []f32{1, 2, 3, 4}))
	outputSize, scratchSize, measureOk := PPOPolicyExportMeasure(&source, &normalizer)
	testing.expect(t, measureOk)
	if !measureOk { return }
	output := make([]u8, outputSize, context.allocator)
	scratch := make([]u8, scratchSize, context.allocator)
	defer { delete(output, context.allocator); delete(scratch, context.allocator) }
	size, exported := PPOPolicyExportWrite(&source, &normalizer, output, scratch)
	testing.expect(t, exported && size == outputSize)
	if !exported { return }
	info, inspectError := PPOPolicyExportInspect(output[:size])
	testing.expect(t, inspectError.code == .None && info.hasObservationNormalizer &&
		info.observation.width == 2 && info.model.inputWidth == 2)

	runtime: PolicyRuntime(3, 4, 4)
	options := PolicyRuntimeOptionsDefault(1)
	options.historyDepth = 2
	options.randomSeed = 123
	runtimeError := PolicyRuntimeInit(&runtime, output[:size], options)
	testing.expect(t, runtimeError == .None && PolicyRuntimeActionCount(&runtime) == 2)
	if runtimeError != .None { return }
	defer PolicyRuntimeDestroy(&runtime)

	history: rl.ObservationHistory
	historyStorage: [2]f32
	flattened, normalized: [2]f32
	testing.expect(t, rl.ObservationHistoryInit(&history, historyStorage[:], 2, 1))
	legal := [2]bool{true, true}
	observations := [4][1]f32{{0.5}, {1.5}, {-0.5}, {0.25}}
	for index in 0..<len(observations) {
		observation := observations[index]
		expectedAction: int
		expectedLog: f64
		expectedOk: bool
		runtimeAction: int
		runtimeLog: f64
		varResult: PolicyRuntimeError
		{
			context.allocator = mem.panic_allocator()
			context.temp_allocator = mem.panic_allocator()
			testing.expect(t, rl.ObservationHistoryPush(&history, observation[:]) &&
				rl.ObservationHistoryFlatten(&history, flattened[:]) &&
				data.RunningStandardizerTransform(&normalizer, flattened[:], normalized[:]))
			expectedAction, expectedLog, expectedOk = SequentialPolicyAction(&source, normalized[:], legal[:], .Greedy)
			runtimeAction, runtimeLog, varResult = PolicyRuntimeAction(&runtime, observation[:], legal[:], .Greedy)
		}
		testing.expectf(t, expectedOk && varResult == .None && runtimeAction == expectedAction && runtimeLog == expectedLog,
			"frame %d: expected %d/%v, runtime %d/%v %v", index, expectedAction, expectedLog, runtimeAction, runtimeLog, varResult)
		if varResult != .None { return }
	}
	testing.expect(t, PolicyRuntimeResetEpisode(&runtime) &&
		rl.ObservationHistoryReset(&history))
	frame := [1]f32{0.75}
	testing.expect(t, rl.ObservationHistoryPush(&history, frame[:]) && rl.ObservationHistoryFlatten(&history, flattened[:]) &&
		data.RunningStandardizerTransform(&normalizer, flattened[:], normalized[:]))
	expectedAction, expectedLog, expectedOk := SequentialPolicyAction(&source, normalized[:], legal[:], .Greedy)
	runtimeAction, runtimeLog, frameError := PolicyRuntimeAction(&runtime, frame[:], legal[:], .Greedy)
	testing.expect(t, expectedOk && frameError == .None && runtimeAction == expectedAction && runtimeLog == expectedLog)
}

@(test)
PolicyRuntimeRejectsShapeAndMaskErrors :: proc(t: ^testing.T) {
	source: Sequential(1, 4, 4)
	specs := []SequentialLayerSpec{SequentialDenseSpec{2}}
	setup := SequentialInit(&source, 2, 5)
	_, specsOk := SequentialAddSpecs(&source, specs)
	setup = setup && specsOk
	testing.expect(t, setup)
	if !setup { return }
	outputSize, scratchSize, measureOk := PPOPolicyExportMeasure(&source, nil)
	testing.expect(t, measureOk)
	if !measureOk { return }
	output := make([]u8, outputSize, context.allocator)
	scratch := make([]u8, scratchSize, context.allocator)
	defer { delete(output, context.allocator); delete(scratch, context.allocator) }
	size, exported := PPOPolicyExportWrite(&source, nil, output, scratch)
	testing.expect(t, exported)
	if !exported { return }

	badShape: PolicyRuntime(1, 4, 4)
	badOptions := PolicyRuntimeOptionsDefault(1)
	badOptions.historyDepth = 3
	testing.expect(t, PolicyRuntimeInit(&badShape, output[:size], badOptions) == .ShapeMismatch)

	runtime: PolicyRuntime(1, 4, 4)
	testing.expect(t, PolicyRuntimeInit(&runtime, output[:size], PolicyRuntimeOptionsDefault(2)) == .None)
	// The runtime above intentionally uses sensorWidth 2 against a width-2 policy.
	if PolicyRuntimeActionCount(&runtime) != 2 { testing.expect(t, false) }
	legal := [2]bool{true, true}
	observation := [2]f32{1, 2}
	_, _, shortError := PolicyRuntimeAction(&runtime, observation[:1], legal[:], .Greedy)
	_, _, maskError := PolicyRuntimeAction(&runtime, observation[:], []bool{false, false}, .Greedy)
	testing.expect(t, shortError == .InvalidObservation && maskError == .InvalidActionMask)
	testing.expect(t, PolicyRuntimeResetEpisode(&runtime))
	testing.expect(t, PolicyRuntimeDestroy(&runtime) == .None)
	testing.expect(t, PolicyRuntimeDestroy(&runtime) == .None)
}
