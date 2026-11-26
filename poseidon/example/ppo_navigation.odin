package main

// Run with: odin run example/ppo_navigation.odin -file
import "../core"
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

	rolloutObservations: [ROLLOUT_CAPACITY*OBSERVATION_WIDTH]f32
	rolloutActions: [ROLLOUT_CAPACITY]int
	rolloutRewards, rolloutValues, rolloutNextValues: [ROLLOUT_CAPACITY]f32
	rolloutLogProbabilities: [ROLLOUT_CAPACITY]f64
	rolloutLegal: [ROLLOUT_CAPACITY*ACTION_COUNT]bool
	rolloutTerminated, rolloutTruncated: [ROLLOUT_CAPACITY]bool
	rolloutAdvantages, rolloutReturns: [ROLLOUT_CAPACITY]f32
	buffer: rl.RolloutBuffer
	assert(rl.RolloutBufferInit(
		&buffer,
		rl.RolloutStorage{
			observations = rolloutObservations[:], actions = rolloutActions[:],
			rewards = rolloutRewards[:], values = rolloutValues[:], nextValues = rolloutNextValues[:],
			oldLogProbabilities = rolloutLogProbabilities[:], legalActions = rolloutLegal[:],
			terminated = rolloutTerminated[:], truncated = rolloutTruncated[:],
			advantages = rolloutAdvantages[:], returns = rolloutReturns[:],
		},
		ROLLOUT_CAPACITY, OBSERVATION_WIDTH, ACTION_COUNT,
	))

	policyParametersStorage: [6]^core.Node
	valueParametersStorage: [6]^core.Node
	policyParameters, policyParamsOk := nn.SequentialParameters(&policy, policyParametersStorage[:])
	valueParameters, valueParamsOk := nn.SequentialParameters(&value, valueParametersStorage[:])
	assert(policyParamsOk && valueParamsOk)
	combinedParameters: [12]^core.Node
	copy(combinedParameters[:len(policyParameters)], policyParameters)
	copy(combinedParameters[len(policyParameters):len(policyParameters)+len(valueParameters)], valueParameters)
	parameterCount := len(policyParameters)+len(valueParameters)
	firstMoment, secondMoment: [75]f32
	adam: nn.Adam
	assert(nn.AdamInit(&adam, combinedParameters[:parameterCount], firstMoment[:], secondMoment[:], learningRate = 0.003))

	indices: [ROLLOUT_CAPACITY]int
	batchObservations: [BATCH_SIZE*OBSERVATION_WIDTH]f32
	batchActions: [BATCH_SIZE]int
	batchLegal: [BATCH_SIZE*ACTION_COUNT]bool
	batchLogProbabilities: [BATCH_SIZE]f64
	batchAdvantages, batchReturns: [BATCH_SIZE]f32
	epochMetrics: [4]nn.PPOEpochStats
	fitStorage := nn.PPOFitStorage{
		indices = indices[:], observations = batchObservations[:], actions = batchActions[:],
		legalActions = batchLegal[:], oldLogProbabilities = batchLogProbabilities[:],
		advantages = batchAdvantages[:], returns = batchReturns[:], epochMetrics = epochMetrics[:],
	}
	ppoConfig := nn.PPOConfig{clipRange = 0.2, entropyCoefficient = 0.01, valueCoefficient = 0.5, valueHuberDelta = 1}
	fitConfig := nn.PPOFitConfig{epochs = len(epochMetrics), batchSize = BATCH_SIZE, maxGradientNorm = 0.5}
	trainingState: nn.PPOTrainingState
	assert(nn.PPOTrainingStateInit(&trainingState, 12345, 67890))
	position, episodeSteps := 0, 0
	completedEpisodes, successfulEpisodes := 0, 0
	rolloutRewardTotal: f64

	initialReturn, initialSuccess, evalOk := PPOExampleEvaluate(&policy)
	assert(evalOk)
	fmt.printf("Initial greedy evaluation: return %.3f, success %.0f%%\n", initialReturn, initialSuccess*100)
	for iteration in 1..=20 {
		assert(rl.RolloutBufferReset(&buffer))
		legal := [ACTION_COUNT]bool{true, true}
		for buffer.count < buffer.capacity {
			observation := [OBSERVATION_WIDTH]f32{f32(position)/4, 1}
			predictions, valueOk := nn.SequentialPredict(&value, observation[:])
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
				nextPredictions, nextOk := nn.SequentialPredict(&value, nextObservation[:])
				assert(nextOk)
				nextValue = nextPredictions[0]
			}
			assert(rl.RolloutBufferAppend(&buffer, rl.RolloutTransition{
				observation = observation[:], action = action, reward = reward,
				value = predictions[0], nextValue = nextValue,
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
		assert(rl.RolloutComputeGAE(&buffer, 0.99, 0.95))
		assert(rl.RolloutNormalizeAdvantages(&buffer))
		assert(nn.PPOTrainingStateRecordRollout(&trainingState))
		stats, fitOk := nn.SequentialPPOFitStateful(
			&policy, &value, &buffer, &trainingState, ppoConfig, fitConfig, &adam, fitStorage,
		)
		assert(fitOk)
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
}
