package main

// Run with: odin run example/ppo_navigation.odin -file
import "../nn"
import "../rl"
import "core:fmt"

OBSERVATION_WIDTH :: 2
ACTION_COUNT :: 2
ROLLOUT_CAPACITY :: 32
BATCH_SIZE :: 8
MAX_EPISODE_STEPS :: 8

PPOExampleEvaluate :: proc(policy: ^nn.Sequential(3, 8, 8)) -> (meanReturn: f64, successRate: f64, ok: bool) {
	accumulator: rl.EvaluationAccumulator
	if !rl.EvaluationAccumulatorInit(&accumulator, nil) do return 0, 0, false
	legal := [ACTION_COUNT]bool{true, true}
	for startPosition in 0..<5 {
		position := startPosition
		episodeReturn: f64
		episodeLength: u64
		success := false
		for _ in 0..<MAX_EPISODE_STEPS {
			observation := [OBSERVATION_WIDTH]f32{f32(position)/4, 1}
			action, _, actionOk := nn.SequentialPolicyAction(policy, observation[:], legal[:], .Greedy)
			if !actionOk do return 0, 0, false
			previousPosition := position
			if action == 1 { position = min(position+1, 4) } else { position = max(position-1, 0) }
			episodeLength += 1
			episodeReturn += f64(-0.02 + 0.1*f32(position-previousPosition))
			if position == 4 {
				episodeReturn += 1
				success = true
				break
			}
		}
		if !rl.EvaluationRecordEpisode(&accumulator, episodeReturn, episodeLength, success) {
			return 0, 0, false
		}
	}
	summary, summaryOk := rl.EvaluationAccumulatorSummary(&accumulator, nil)
	if !summaryOk do return 0, 0, false
	return summary.meanReturn, summary.successRate, true
}

main :: proc() {
	policy: nn.Sequential(3, 8, 8)
	value: nn.Sequential(3, 8, 8)
	assert(nn.SequentialInit(&policy, OBSERVATION_WIDTH, 17))
	assert(nn.SequentialAddDense(&policy, 8))
	assert(nn.SequentialAddActivation(&policy, .Tanh))
	assert(nn.SequentialAddDense(&policy, ACTION_COUNT))
	assert(nn.SequentialInit(&value, OBSERVATION_WIDTH, 29))
	assert(nn.SequentialAddDense(&value, 8))
	assert(nn.SequentialAddActivation(&value, .Tanh))
	assert(nn.SequentialAddDense(&value, 1))

	ownedRollout: rl.OwnedRolloutBuffer
	assert(rl.OwnedRolloutBufferInit(&ownedRollout, ROLLOUT_CAPACITY, OBSERVATION_WIDTH, ACTION_COUNT))
	defer assert(rl.OwnedRolloutBufferDestroy(&ownedRollout))
	buffer := rl.OwnedRolloutBufferBorrow(&ownedRollout)
	assert(buffer != nil)

	options := nn.PPOTrainingContextOptionsDefault(ROLLOUT_CAPACITY)
	options.fit.batchSize = BATCH_SIZE
	options.learningRate = 0.003
	options.policySeed, options.shuffleSeed = 12345, 67890
	trainer: nn.PPOTrainingContext(3, 8, 8, 3, 8, 8)
	assert(nn.PPOTrainingContextInit(&trainer, &policy, &value, options) == .None)
	defer assert(nn.PPOTrainingContextDestroy(&trainer) == .None)
	trainingState := nn.PPOTrainingContextState(&trainer)
	assert(trainingState != nil)
	position, episodeSteps := 0, 0
	completedEpisodes, successfulEpisodes := 0, 0
	rolloutRewardTotal: f64

	initialReturn, initialSuccess, evalOk := PPOExampleEvaluate(&policy)
	assert(evalOk)
	fmt.printf("Initial greedy evaluation: return %.3f, success %.0f%%\n", initialReturn, initialSuccess*100)
	for iteration in 1..=20 {
		assert(rl.RolloutBufferReset(buffer))
		legal := [ACTION_COUNT]bool{true, true}
		for buffer.count < buffer.capacity {
			observation := [OBSERVATION_WIDTH]f32{f32(position)/4, 1}
			currentValue, valueOk := nn.SequentialPredictScalar(&value, observation[:])
			assert(valueOk)
			action, logProbability, actionOk := nn.SequentialPolicyAction(
				&policy, observation[:], legal[:], .Stochastic, &trainingState.policyRandomState,
			)
			assert(actionOk)

			previousPosition := position
			if action == 1 { position = min(position+1, 4) } else { position = max(position-1, 0) }
			episodeSteps += 1
			terminated := position == 4
			truncated := !terminated && episodeSteps >= MAX_EPISODE_STEPS
			reward := f32(-0.02 + 0.1*f32(position-previousPosition))
			if terminated { reward += 1 }
			nextObservation := [OBSERVATION_WIDTH]f32{f32(position)/4, 1}
			nextValue: f32
			if !terminated {
				prediction, nextOk := nn.SequentialPredictScalar(&value, nextObservation[:])
				assert(nextOk)
				nextValue = prediction
			}
			assert(rl.RolloutBufferAppend(buffer, rl.RolloutTransition{
				observation = observation[:], action = action, reward = reward,
				value = currentValue, nextValue = nextValue,
				oldLogProbability = logProbability, legalActions = legal[:],
				terminated = terminated, truncated = truncated,
			}))
			rolloutRewardTotal += f64(reward)
			if terminated || truncated {
				completedEpisodes += 1
				if terminated { successfulEpisodes += 1 }
				position, episodeSteps = 0, 0
			}

		}
		assert(rl.RolloutComputeGAE(buffer, 0.99, 0.95))
		assert(rl.RolloutNormalizeAdvantages(buffer))
		assert(nn.PPOTrainingContextRecordRollout(&trainer) == .None)
		stats, fitError := nn.PPOTrainingContextFit(&trainer, buffer)
		assert(fitError == .None)
		evaluationReturn, successRate, evalOk := PPOExampleEvaluate(&policy)
		assert(evalOk)
		rolloutMeanReward: f64
		if buffer.count > 0 { rolloutMeanReward = rolloutRewardTotal/f64(buffer.count) }
		rolloutSuccessRate: f64
		if completedEpisodes > 0 { rolloutSuccessRate = f64(successfulEpisodes)/f64(completedEpisodes) }
		fmt.printf(
			"Update %2d: policy %.3f value %.3f entropy %.3f KL %.4f EV %.3f | rollout reward/step %.3f success %.0f%% | greedy return %.3f success %.0f%%\n",
			iteration, stats.policyLoss, stats.valueLoss, stats.entropy, stats.approximateKL,
			stats.explainedVariance, rolloutMeanReward, rolloutSuccessRate*100, evaluationReturn, successRate*100,
		)
		completedEpisodes, successfulEpisodes = 0, 0
		rolloutRewardTotal = 0
	}

	// Checkpoint at a successful fit boundary. The destination models need no
	// layers beforehand; the inspected capacities choose the compiled model type.
	checkpoint, policyScratch, valueScratch: [4096]u8
	size, saveError := nn.PPOTrainingContextCheckpointWrite(&trainer, checkpoint[:], policyScratch[:], valueScratch[:])
	assert(saveError == .None)
	limits := nn.PPOCheckpointInspectLimits{
		maxBytes = len(checkpoint), maxParameterPointers = 12, maxMomentElements = 256, maxEpochs = 4,
		policy = {maxLayers = 3, maxWidth = 8, maxBatchCapacity = 8},
		value = {maxLayers = 3, maxWidth = 8, maxBatchCapacity = 8},
	}
	info, inspectError := nn.PPOCheckpointInspect(checkpoint[:size], limits)
	assert(inspectError.code == .None && info.optimizer == .Adam)
	restoredPolicy, restoredValue: nn.Sequential(3, 8, 8)
	restoredTrainer: nn.PPOTrainingContext(3, 8, 8, 3, 8, 8)
	restoreError := nn.PPOTrainingContextCheckpointInit(
		&restoredTrainer, &restoredPolicy, &restoredValue, checkpoint[:size], ROLLOUT_CAPACITY, limits,
	)
	assert(restoreError == .None)
	defer assert(nn.PPOTrainingContextDestroy(&restoredTrainer) == .None)
	restoredState := nn.PPOTrainingContextState(&restoredTrainer)
	assert(restoredState != nil && restoredState^ == trainingState^)
	restoredReturn, restoredSuccess, restoredOk := PPOExampleEvaluate(&restoredPolicy)
	assert(restoredOk)
	fmt.printf("Restored %d-byte checkpoint: %d updates, greedy return %.3f, success %.0f%%\n",
		size, restoredState.updateCount, restoredReturn, restoredSuccess*100)
}
