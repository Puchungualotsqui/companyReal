package main

// Run with: odin run example/ppo_batched_navigation.odin -file
import "../core"
import "../nn"
import "../rl"
import "core:fmt"
import "core:time"

BATCHED_ENVIRONMENT_COUNT :: 4
BATCHED_ROLLOUT_STEPS :: 8
BATCHED_OBSERVATION_WIDTH :: 2 // Two features: normalized position and a constant bias.
BATCHED_ACTION_COUNT :: 2
BATCHED_ROLLOUT_CAPACITY :: BATCHED_ENVIRONMENT_COUNT*BATCHED_ROLLOUT_STEPS
BATCHED_MINIBATCH_SIZE :: 8
BATCHED_EPISODE_LIMIT :: 8
BATCHED_TRAINING_ITERATIONS :: 8

main :: proc() {
	policy: nn.Sequential(3, 8, BATCHED_MINIBATCH_SIZE)
	value: nn.Sequential(3, 8, BATCHED_MINIBATCH_SIZE)
	assert(nn.SequentialInit(&policy, BATCHED_OBSERVATION_WIDTH, 101))
	assert(nn.SequentialAddDense(&policy, 8))
	assert(nn.SequentialAddActivation(&policy, .Tanh))
	assert(nn.SequentialAddDense(&policy, BATCHED_ACTION_COUNT))
	assert(nn.SequentialInit(&value, BATCHED_OBSERVATION_WIDTH, 202))
	assert(nn.SequentialAddDense(&value, 8))
	assert(nn.SequentialAddActivation(&value, .Tanh))
	assert(nn.SequentialAddDense(&value, 1))

	rolloutObservations: [BATCHED_ROLLOUT_CAPACITY*BATCHED_OBSERVATION_WIDTH]f32
	rolloutActions: [BATCHED_ROLLOUT_CAPACITY]int
	rolloutRewards, rolloutValues, rolloutNextValues: [BATCHED_ROLLOUT_CAPACITY]f32
	rolloutLogProbabilities: [BATCHED_ROLLOUT_CAPACITY]f64
	rolloutLegal: [BATCHED_ROLLOUT_CAPACITY*BATCHED_ACTION_COUNT]bool
	rolloutTerminated, rolloutTruncated: [BATCHED_ROLLOUT_CAPACITY]bool
	rolloutAdvantages, rolloutReturns: [BATCHED_ROLLOUT_CAPACITY]f32
	environmentIndices: [BATCHED_ROLLOUT_CAPACITY]int
	buffer: rl.BatchedRolloutBuffer
	assert(rl.BatchedRolloutBufferInit(
		&buffer,
		rl.BatchedRolloutStorage{
			transitions = rl.RolloutStorage{
				observations = rolloutObservations[:], actions = rolloutActions[:],
				rewards = rolloutRewards[:], values = rolloutValues[:], nextValues = rolloutNextValues[:],
				oldLogProbabilities = rolloutLogProbabilities[:], legalActions = rolloutLegal[:],
				terminated = rolloutTerminated[:], truncated = rolloutTruncated[:],
				advantages = rolloutAdvantages[:], returns = rolloutReturns[:],
			},
			environmentIndices = environmentIndices[:],
		},
		BATCHED_ROLLOUT_CAPACITY, BATCHED_ENVIRONMENT_COUNT, BATCHED_OBSERVATION_WIDTH, BATCHED_ACTION_COUNT,
	))
	returnScratchValues: [BATCHED_ENVIRONMENT_COUNT]f64
	returnScratchHasFollowing: [BATCHED_ENVIRONMENT_COUNT]bool
	returnScratch := rl.BatchedRolloutReturnScratch{returnScratchValues[:], returnScratchHasFollowing[:]}

	policyParameterStorage: [6]^core.Node
	valueParameterStorage: [6]^core.Node
	policyParameters, policyParametersOk := nn.SequentialParameters(&policy, policyParameterStorage[:])
	valueParameters, valueParametersOk := nn.SequentialParameters(&value, valueParameterStorage[:])
	assert(policyParametersOk && valueParametersOk)
	combinedParameters: [12]^core.Node
	copy(combinedParameters[:len(policyParameters)], policyParameters)
	copy(combinedParameters[len(policyParameters):len(policyParameters)+len(valueParameters)], valueParameters)
	parameterCount := len(policyParameters)+len(valueParameters)
	firstMoment, secondMoment: [75]f32
	adam: nn.Adam
	assert(nn.AdamInit(
		&adam, combinedParameters[:parameterCount], firstMoment[:], secondMoment[:], learningRate = 0.003,
	))

	indices: [BATCHED_ROLLOUT_CAPACITY]int
	batchObservations: [BATCHED_MINIBATCH_SIZE*BATCHED_OBSERVATION_WIDTH]f32
	batchActions: [BATCHED_MINIBATCH_SIZE]int
	batchLegal: [BATCHED_MINIBATCH_SIZE*BATCHED_ACTION_COUNT]bool
	batchLogProbabilities: [BATCHED_MINIBATCH_SIZE]f64
	batchAdvantages, batchReturns: [BATCHED_MINIBATCH_SIZE]f32
	epochMetrics: [4]nn.PPOEpochStats
	fitStorage := nn.PPOFitStorage{
		indices = indices[:], observations = batchObservations[:], actions = batchActions[:],
		legalActions = batchLegal[:], oldLogProbabilities = batchLogProbabilities[:],
		advantages = batchAdvantages[:], returns = batchReturns[:], epochMetrics = epochMetrics[:],
	}
	ppoConfig := nn.PPOConfig{clipRange = 0.2, entropyCoefficient = 0.01, valueCoefficient = 0.5, valueHuberDelta = 1}
	fitConfig := nn.PPOFitConfig{epochs = len(epochMetrics), batchSize = BATCHED_MINIBATCH_SIZE, maxGradientNorm = 0.5}
	trainingState: nn.PPOTrainingState
	assert(nn.PPOTrainingStateInit(&trainingState, 12345, 67890))

	positions: [BATCHED_ENVIRONMENT_COUNT]int
	episodeSteps: [BATCHED_ENVIRONMENT_COUNT]int
	for environment in 0..<BATCHED_ENVIRONMENT_COUNT { positions[environment] = environment }
	observations: [BATCHED_ENVIRONMENT_COUNT*BATCHED_OBSERVATION_WIDTH]f32
	legalActions: [BATCHED_ENVIRONMENT_COUNT*BATCHED_ACTION_COUNT]bool
	actions: [BATCHED_ENVIRONMENT_COUNT]int
	oldLogProbabilities: [BATCHED_ENVIRONMENT_COUNT]f64
	currentValues, nextValues: [BATCHED_ENVIRONMENT_COUNT]f32
	nextObservations: [BATCHED_ENVIRONMENT_COUNT*BATCHED_OBSERVATION_WIDTH]f32
	rewards: [BATCHED_ENVIRONMENT_COUNT]f32
	terminated, truncated: [BATCHED_ENVIRONMENT_COUNT]bool
	nextPositions, nextEpisodeSteps: [BATCHED_ENVIRONMENT_COUNT]int
	collectionNanoseconds, inferenceNanoseconds, trainingNanoseconds: i64

	for iteration in 0..<BATCHED_TRAINING_ITERATIONS {
		assert(rl.BatchedRolloutBufferReset(&buffer))
		for step in 0..<BATCHED_ROLLOUT_STEPS {
			phaseStart := time.tick_now()
			for environment in 0..<BATCHED_ENVIRONMENT_COUNT {
				observationStart := environment*BATCHED_OBSERVATION_WIDTH
				observations[observationStart] = f32(positions[environment])/4
				observations[observationStart+1] = 1
				legalStart := environment*BATCHED_ACTION_COUNT
				legalActions[legalStart], legalActions[legalStart+1] = true, true
			}
			collectionNanoseconds += i64(time.tick_since(phaseStart))

			phaseStart = time.tick_now()
			valueOk := nn.SequentialPredictBatches(&value, observations[:], currentValues[:])
			policyOk := nn.SequentialPolicyActions(
				&policy, observations[:], legalActions[:], .Stochastic,
				actions[:], oldLogProbabilities[:], &trainingState.policyRandomState,
			)
			assert(valueOk && policyOk)
			inferenceNanoseconds += i64(time.tick_since(phaseStart))

			phaseStart = time.tick_now()
			for environment in 0..<BATCHED_ENVIRONMENT_COUNT {
				position := positions[environment]
				nextPosition := position
				if actions[environment] == 1 {
					nextPosition = min(position+1, 4)
				} else {
					nextPosition = max(position-1, 0)
				}
				nextSteps := episodeSteps[environment]+1
				isTerminated := nextPosition == 4
				isTruncated := !isTerminated && nextSteps >= BATCHED_EPISODE_LIMIT
				reward := f32(-0.02+0.1*f32(nextPosition-position))
				if isTerminated { reward += 1 }
				nextPositions[environment], nextEpisodeSteps[environment] = nextPosition, nextSteps
				rewards[environment] = reward
				terminated[environment], truncated[environment] = isTerminated, isTruncated
				nextObservationStart := environment*BATCHED_OBSERVATION_WIDTH
			nextObservations[nextObservationStart] = f32(nextPosition)/4
			nextObservations[nextObservationStart+1] = 1
			}
			collectionNanoseconds += i64(time.tick_since(phaseStart))

			phaseStart = time.tick_now()
			nextValueOk := nn.SequentialPredictBatches(&value, nextObservations[:], nextValues[:])
			assert(nextValueOk)
			inferenceNanoseconds += i64(time.tick_since(phaseStart))

			phaseStart = time.tick_now()
			for environment in 0..<BATCHED_ENVIRONMENT_COUNT {
				observationStart := environment*BATCHED_OBSERVATION_WIDTH
				legalStart := environment*BATCHED_ACTION_COUNT
				assert(rl.BatchedRolloutBufferAppend(&buffer, environment, rl.RolloutTransition{
					observation = observations[observationStart:observationStart+BATCHED_OBSERVATION_WIDTH],
					action = actions[environment], reward = rewards[environment],
					value = currentValues[environment], nextValue = nextValues[environment],
					oldLogProbability = oldLogProbabilities[environment],
					legalActions = legalActions[legalStart:legalStart+BATCHED_ACTION_COUNT],
					terminated = terminated[environment], truncated = truncated[environment],
				}))
				positions[environment], episodeSteps[environment] = nextPositions[environment], nextEpisodeSteps[environment]
				if terminated[environment] || truncated[environment] {
					positions[environment], episodeSteps[environment] = environment, 0
				}
			}
			collectionNanoseconds += i64(time.tick_since(phaseStart))
		}

		phaseStart := time.tick_now()
		assert(rl.BatchedRolloutComputeGAE(&buffer, 0.99, 0.95, returnScratch))
		assert(rl.RolloutNormalizeAdvantages(&buffer.rollout))
		assert(nn.PPOTrainingStateRecordRollout(&trainingState))
		view, viewOk := rl.BatchedRolloutBufferTrainingView(&buffer)
		assert(viewOk)
		_, fitOk := nn.SequentialPPOFitStateful(
			&policy, &value, view, &trainingState, ppoConfig, fitConfig, &adam, fitStorage,
		)
		assert(fitOk)
		trainingNanoseconds += i64(time.tick_since(phaseStart))
	}

	totalNanoseconds := max(collectionNanoseconds+inferenceNanoseconds+trainingNanoseconds, 1)
	fmt.printf(
		"Profile (%d rollouts, %d envs, %d transitions/rollout): collection %.3f ms (%.1f%%), inference %.3f ms (%.1f%%), GAE+PPO training %.3f ms (%.1f%%)\n",
		BATCHED_TRAINING_ITERATIONS, BATCHED_ENVIRONMENT_COUNT, BATCHED_ROLLOUT_CAPACITY,
		f64(collectionNanoseconds)/1e6, 100*f64(collectionNanoseconds)/f64(totalNanoseconds),
		f64(inferenceNanoseconds)/1e6, 100*f64(inferenceNanoseconds)/f64(totalNanoseconds),
		f64(trainingNanoseconds)/1e6, 100*f64(trainingNanoseconds)/f64(totalNanoseconds),
	)
}
