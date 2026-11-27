package nn

import "core:math"
import "core:mem"
import "core:testing"

@(private="file")
ppoAgentTestOptions :: proc(options: ^PPOAgentOptions, policySpecs, valueSpecs: []SequentialLayerSpec) {
	options^ = PPOAgentOptionsDefault(2, 2, 4)
	options.policySpecs = policySpecs
	options.valueSpecs = valueSpecs
	options.trainer.policySeed = 17
	options.trainer.shuffleSeed = 29
	options.trainer.learningRate = 0.01
	options.trainer.fit = {epochs = 2, batchSize = 2, maxGradientNorm = 0.5}
}

@(test)
PPOAgentTrainingWorkflowAndCheckpoint :: proc(t: ^testing.T) {
	policySpecs := []SequentialLayerSpec{SequentialDenseSpec{8}, SequentialActivationSpec{.Tanh}, SequentialDenseSpec{2}}
	valueSpecs := []SequentialLayerSpec{SequentialDenseSpec{8}, SequentialActivationSpec{.Tanh}, SequentialDenseSpec{1}}
	options: PPOAgentOptions
	ppoAgentTestOptions(&options, policySpecs, valueSpecs)
	agent: PPOAgent(3, 8, 4, 3, 8, 4)
	initError := PPOAgentInit(&agent, options)
	initialized := initError == .None
	testing.expectf(t, initialized, "agent init: %v", initError)
	if !initialized { return }
	defer PPOAgentDestroy(&agent)
	policy, value, buffer := PPOAgentPolicy(&agent), PPOAgentValue(&agent), PPOAgentRollout(&agent)
	state := PPOAgentState(&agent)
	testing.expect(t, policy != nil && value != nil && buffer != nil && state != nil && PPOAgentActionCount(&agent) == 2)
	if policy == nil || value == nil || buffer == nil || state == nil { return }

	legal := [2]bool{true, true}
	observations := [5][2]f32{{0, 1}, {0.25, 1}, {0.5, 1}, {0.75, 1}, {1, 1}}
	rewards := [4]f32{0.1, 0.2, -0.1, 0.5}
	badMask := [2]bool{false, false}
	bad := PPOAgentStep(&agent, observations[0][:], badMask[:], 1, true, false, nil)
	testing.expect(t, bad.error == .InvalidActionMask && buffer.count == 0)
	badObservation := [1]f32{1}
	bad = PPOAgentStep(&agent, badObservation[:], legal[:], 1, false, false, observations[1][:])
	testing.expect(t, bad.error == .InvalidObservation && buffer.count == 0)
	for index in 0..<4 {
		result := PPOAgentStep(&agent, observations[index][:], legal[:], rewards[index], index == 3, false,
			observations[index+1][:], .Stochastic)
		testing.expect(t, result.error == .None && result.action >= 0 && result.action < 2 && buffer.count == index+1)
		if result.error != .None { return }
	}
	testing.expect(t, PPOAgentRolloutFull(&agent) && buffer.count == 4)
	full := PPOAgentStep(&agent, observations[0][:], legal[:], 1, true, false, nil)
	testing.expect(t, full.error == .RolloutFull && buffer.count == 4)

	updatesBefore := state.updateCount
	stats: PPOFitStats
	trainError: PPOAgentError
	{
		context.allocator = mem.panic_allocator()
		context.temp_allocator = mem.panic_allocator()
		stats, trainError = PPOAgentTrain(&agent)
	}
	testing.expect(t, trainError == .None && stats.updates > 0 && buffer.count == 0 && state.updateCount > updatesBefore)
	empty, emptyError := PPOAgentTrain(&agent)
	testing.expect(t, emptyError == .EmptyRollout && empty == (PPOFitStats{}))

	sizes, measureError := PPOAgentCheckpointMeasure(&agent)
	testing.expect(t, measureError == .None)
	if measureError != .None { return }
	output := make([]u8, sizes.output, context.allocator)
	policyScratch := make([]u8, sizes.policyScratch, context.allocator)
	valueScratch := make([]u8, sizes.valueScratch, context.allocator)
	defer { delete(output, context.allocator); delete(policyScratch, context.allocator); delete(valueScratch, context.allocator) }
	size, writeError := PPOAgentCheckpointWrite(&agent, output, policyScratch, valueScratch)
	testing.expect(t, writeError == .None && size == sizes.output)
	if writeError != .None { return }
	info, inspectError := PPOCheckpointInspect(output[:size])
	testing.expect(t, inspectError.code == .None && info.optimizer == .Adam && info.policy.inputWidth == 2)

	restored: PPOAgent(3, 8, 4, 3, 8, 4)
	initialized = PPOAgentInit(&restored, options) == .None
	testing.expect(t, initialized)
	if !initialized { return }
	defer PPOAgentDestroy(&restored)
	readError := PPOAgentCheckpointRead(&restored, output[:size])
	testing.expect(t, readError == .None && PPOAgentState(&restored)^ == state^)
	if readError != .None { return }
	restoredPolicy := PPOAgentPolicy(&restored)
	testing.expect(t, restoredPolicy != nil && restoredPolicy.layerCount == policy.layerCount)
}

@(test)
PPOAgentPendingStepWorkflow :: proc(t: ^testing.T) {
	policySpecs := []SequentialLayerSpec{SequentialDenseSpec{2}}
	valueSpecs := []SequentialLayerSpec{SequentialDenseSpec{1}}
	options: PPOAgentOptions
	ppoAgentTestOptions(&options, policySpecs, valueSpecs)
	options.inputWidth, options.actionCount = 1, 2
	options.rolloutCapacity = 2
	options.trainer.rolloutCapacity = 2
	agent: PPOAgent(1, 4, 2, 1, 4, 2)
	initError := PPOAgentInit(&agent, options)
	testing.expectf(t, initError == .None, "agent init: %v", initError)
	if initError != .None { return }
	defer PPOAgentDestroy(&agent)
	buffer := PPOAgentRollout(&agent)
	legal := [2]bool{true, true}
	observation, nextObservation := [1]f32{0.5}, [1]f32{0.75}
	act := PPOAgentAct(&agent, observation[:], legal[:])
	testing.expect(t, act.error == .None && buffer.count == 0)
	duplicate := PPOAgentAct(&agent, observation[:], legal[:])
	testing.expect(t, duplicate.error == .PendingStep && buffer.count == 0)
	_, trainError := PPOAgentTrain(&agent)
	testing.expect(t, trainError == .PendingStep)
	testing.expect(t, PPOAgentObserve(&agent, math.nan_f32(), false, false, nextObservation[:]) == .InvalidReward)
	testing.expect(t, PPOAgentObserve(&agent, 0.25, false, false, observation[:0]) == .InvalidObservation)
	testing.expect(t, PPOAgentObserve(&agent, 0.25, false, false, nextObservation[:]) == .None && buffer.count == 1)
	testing.expect(t, PPOAgentObserve(&agent, 0.25, false, false, nextObservation[:]) == .NoPendingStep && buffer.count == 1)
	testing.expect(t, PPOAgentObserve(&agent, 0, true, false, nil) == .NoPendingStep)
}

@(test)
PPOAgentPolicyExportRoundTrip :: proc(t: ^testing.T) {
	policySpecs := []SequentialLayerSpec{SequentialDenseSpec{8}, SequentialActivationSpec{.Tanh}, SequentialDenseSpec{2}}
	valueSpecs := []SequentialLayerSpec{SequentialDenseSpec{8}, SequentialActivationSpec{.Tanh}, SequentialDenseSpec{1}}
	options: PPOAgentOptions
	ppoAgentTestOptions(&options, policySpecs, valueSpecs)
	agent: PPOAgent(3, 8, 4, 3, 8, 4)
	initError := PPOAgentInit(&agent, options)
	initialized := initError == .None
	testing.expectf(t, initialized, "agent init: %v", initError)
	if !initialized { return }
	defer PPOAgentDestroy(&agent)
	outputSize, scratchSize, measureError := PPOAgentPolicyExportMeasure(&agent)
	testing.expect(t, measureError == .None)
	if measureError != .None { return }
	output := make([]u8, outputSize, context.allocator)
	scratch := make([]u8, scratchSize, context.allocator)
	defer { delete(output, context.allocator); delete(scratch, context.allocator) }
	size, exportError := PPOAgentPolicyExportWrite(&agent, output, scratch)
	testing.expect(t, exportError == .None && size == outputSize)
	if exportError != .None { return }
	info, inspectError := PPOPolicyExportInspect(output[:size])
	testing.expect(t, inspectError.code == .None && info.model.inputWidth == 2 && info.model.outputWidth == 2)

	runtime: PolicyRuntime(3, 8, 4)
	runtimeError := PolicyRuntimeInit(&runtime, output[:size], PolicyRuntimeOptionsDefault(2))
	testing.expect(t, runtimeError == .None && PolicyRuntimeActionCount(&runtime) == 2)
	if runtimeError != .None { return }
	defer PolicyRuntimeDestroy(&runtime)
	legal := [2]bool{true, true}
	observation := [2]f32{0.25, 1}
	agentAction, agentLog, agentOk := SequentialPolicyAction(PPOAgentPolicy(&agent), observation[:], legal[:], .Greedy)
	runtimeAction, runtimeLog, actionError := PolicyRuntimeAction(&runtime, observation[:], legal[:], .Greedy)
	testing.expect(t, agentOk && actionError == .None && agentAction == runtimeAction && agentLog == runtimeLog)
}
