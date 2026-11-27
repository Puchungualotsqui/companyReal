package main

// Run with: odin run example/ppo_agent/ppo_agent_navigation.odin -file
import "../../nn"
import "core:fmt"

AGENT_OBSERVATION_WIDTH :: 2
AGENT_ACTION_COUNT :: 2
AGENT_ROLLOUT_CAPACITY :: 32
AGENT_BATCH_SIZE :: 8
AGENT_MAX_EPISODE_STEPS :: 8

AgentEvaluate :: proc(policy: ^nn.Sequential(3, 8, 8)) -> (meanReturn: f64, successRate: f64, ok: bool) {
	legal := [AGENT_ACTION_COUNT]bool{true, true}
	totalReturn: f64
	successes: int
	for startPosition in 0..<5 {
		position := startPosition
		for _ in 0..<AGENT_MAX_EPISODE_STEPS {
			observation := [AGENT_OBSERVATION_WIDTH]f32{f32(position)/4, 1}
			action, _, actionOk := nn.SequentialPolicyAction(policy, observation[:], legal[:], .Greedy)
			if !actionOk { return 0, 0, false }
			previous := position
			if action == 1 { position = min(position+1, 4) } else { position = max(position-1, 0) }
			totalReturn += f64(-0.02+0.1*f32(position-previous))
			if position == 4 {
				totalReturn += 1
				successes += 1
				break
			}
		}
	}
	return totalReturn/5, f64(successes)/5, true
}

main :: proc() {
	policySpecs := []nn.SequentialLayerSpec{nn.SequentialDenseSpec{8}, nn.SequentialActivationSpec{.Tanh}, nn.SequentialDenseSpec{AGENT_ACTION_COUNT}}
	valueSpecs := []nn.SequentialLayerSpec{nn.SequentialDenseSpec{8}, nn.SequentialActivationSpec{.Tanh}, nn.SequentialDenseSpec{1}}
	options := nn.PPOAgentOptionsDefault(AGENT_OBSERVATION_WIDTH, AGENT_ACTION_COUNT, AGENT_ROLLOUT_CAPACITY)
	options.policySpecs, options.valueSpecs = policySpecs, valueSpecs
	options.trainer.fit = {epochs = 4, batchSize = AGENT_BATCH_SIZE, maxGradientNorm = 0.5}
	options.trainer.learningRate = 0.003
	options.trainer.policySeed, options.trainer.shuffleSeed = 17, 29

	agent: nn.PPOAgent(3, 8, 8, 3, 8, 8)
	initError := nn.PPOAgentInit(&agent, options)
	assert(initError == .None)
	defer assert(nn.PPOAgentDestroy(&agent) == .None)
	buffer := nn.PPOAgentRollout(&agent)
	assert(buffer != nil)
	legal := [AGENT_ACTION_COUNT]bool{true, true}
	position, episodeSteps := 0, 0
	evaluatedReturn, evaluatedSuccess, evalOk := AgentEvaluate(nn.PPOAgentPolicy(&agent))
	assert(evalOk)
	fmt.printf("Initial greedy evaluation: return %.3f, success %.0f%%\n", evaluatedReturn, evaluatedSuccess*100)

	for iteration in 1..=10 {
		for buffer.count < buffer.capacity {
			observation := [AGENT_OBSERVATION_WIDTH]f32{f32(position)/4, 1}
			result := nn.PPOAgentAct(&agent, observation[:], legal[:])
			assert(result.error == .None)
			previous := position
			if result.action == 1 { position = min(position+1, 4) } else { position = max(position-1, 0) }
			episodeSteps += 1
			terminated := position == 4
			truncated := !terminated && episodeSteps >= AGENT_MAX_EPISODE_STEPS
			reward := f32(-0.02+0.1*f32(position-previous))
			if terminated { reward += 1 }
			nextObservation := [AGENT_OBSERVATION_WIDTH]f32{f32(position)/4, 1}
			observeError := nn.PPOAgentObserve(&agent, reward, terminated, truncated,
				terminated ? nil : nextObservation[:])
			assert(observeError == .None)
			if terminated || truncated { position, episodeSteps = 0, 0 }
		}
		stats, trainError := nn.PPOAgentTrain(&agent)
		assert(trainError == .None)
		evaluatedReturn, evaluatedSuccess, evalOk = AgentEvaluate(nn.PPOAgentPolicy(&agent))
		assert(evalOk)
		fmt.printf("Update %2d: policy %.3f value %.3f entropy %.3f EV %.3f | greedy return %.3f success %.0f%%\n",
			iteration, stats.policyLoss, stats.valueLoss, stats.entropy, stats.explainedVariance,
			evaluatedReturn, evaluatedSuccess*100)
	}

	exportOutputSize, exportScratchSize, measureError := nn.PPOAgentPolicyExportMeasure(&agent)
	assert(measureError == .None)
	exportData: [4096]u8
	exportScratch: [4096]u8
	assert(exportOutputSize <= len(exportData) && exportScratchSize <= len(exportScratch))
	exportSize, exportError := nn.PPOAgentPolicyExportWrite(&agent, exportData[:], exportScratch[:])
	assert(exportError == .None)

	runtime: nn.PolicyRuntime(3, 8, 8)
	runtimeOptions := nn.PolicyRuntimeOptionsDefault(AGENT_OBSERVATION_WIDTH)
	runtimeError := nn.PolicyRuntimeInit(&runtime, exportData[:exportSize], runtimeOptions)
	assert(runtimeError == .None)
	defer assert(nn.PolicyRuntimeDestroy(&runtime) == .None)
	observation := [AGENT_OBSERVATION_WIDTH]f32{0, 1}
	runtimeAction, runtimeLog, actionError := nn.PolicyRuntimeAction(&runtime, observation[:], legal[:], .Greedy)
	assert(actionError == .None)
	fmt.printf("Inference runtime: action %d, log probability %.4f\n", runtimeAction, runtimeLog)
}
