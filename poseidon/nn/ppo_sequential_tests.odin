package nn

import "../core"
import "../rl"
import "core:math"
import "core:testing"

PPOSequentialTestCollect :: proc(
	policy, value: ^Sequential(1, 2, 3),
	buffer: ^rl.RolloutBuffer,
) -> bool {
	legal := [2]bool{true, true}
	for index in 0..<5 {
		observation := [2]f32{f32(index)/4, 1}
		action := index%2
		logits, policyPredictOk := SequentialPredict(policy, observation[:])
		currentValue, valuePredictOk := SequentialPredictScalar(value, observation[:])
		if !policyPredictOk || !valuePredictOk do return false
		singleAction := [1]int{action}
		logProbability: [1]f64
		if !CategoricalPolicyLogProbs(
			core.Tensor{policy.layers[0].output.value.shape, logits}, legal[:], singleAction[:], logProbability[:],
		) { return false }
		nextObservation := observation
		nextObservation[0] += 0.1
		nextValue: f32
		if index < 4 {
			prediction, nextOk := SequentialPredictScalar(value, nextObservation[:])
			if !nextOk do return false
			nextValue = prediction
		}
		transition := rl.RolloutTransition{
			observation = observation[:], action = action, reward = f32(index%2),
			value = currentValue, nextValue = nextValue, oldLogProbability = logProbability[0],
			legalActions = legal[:], terminated = index == 4,
		}
		if !rl.RolloutBufferAppend(buffer, transition) do return false
	}
	return true
}

@(test)
PPOFitShuffleIsDeterministic :: proc(t: ^testing.T) {
	first, second: [9]int
	firstState: u64 = 0
	secondState: u64 = 0
	firstOk := PPOFitShuffle(first[:], &firstState)
	secondOk := PPOFitShuffle(second[:], &secondState)
	testing.expect(t, firstOk && secondOk && first == second && firstState == secondState)
	for value, index in first {
		testing.expect(t, value >= 0 && value < len(first))
		for previous in first[:index] { testing.expect(t, value != previous) }
	}
}

@(test)
SequentialPPOFitMinibatchesAndSchedule :: proc(t: ^testing.T) {
	policy: Sequential(1, 2, 3)
	value: Sequential(1, 2, 3)
	policyOk := SequentialInit(&policy, 2, 7) && SequentialAddDense(&policy, 2)
	valueOk := SequentialInit(&value, 2, 11) && SequentialAddDense(&value, 1)
	testing.expect(t, policyOk && valueOk)
	if !policyOk || !valueOk { return }

	observations: [10]f32
	actions: [5]int
	rewards: [5]f32
	values: [5]f32
	nextValues: [5]f32
	oldLogProbabilities: [5]f64
	legalActions: [10]bool
	terminated: [5]bool
	truncated: [5]bool
	advantages: [5]f32
	returns: [5]f32
	buffer: rl.RolloutBuffer
	storage := rl.RolloutStorage{
		observations = observations[:], actions = actions[:], rewards = rewards[:], values = values[:],
		nextValues = nextValues[:], oldLogProbabilities = oldLogProbabilities[:],
		legalActions = legalActions[:], terminated = terminated[:], truncated = truncated[:],
		advantages = advantages[:], returns = returns[:],
	}
	bufferOk := rl.RolloutBufferInit(&buffer, storage, 5, 2, 2)
	collected := bufferOk && PPOSequentialTestCollect(&policy, &value, &buffer)
	testing.expect(t, collected)
	if !collected { return }
	testing.expect(t, rl.RolloutComputeGAE(&buffer, 0.9, 0.95))
	testing.expect(t, rl.RolloutNormalizeAdvantages(&buffer))

	policyParameterStorage: [2]^core.Node
	valueParameterStorage: [2]^core.Node
	policyParameters, policyParametersOk := SequentialParameters(&policy, policyParameterStorage[:])
	valueParameters, valueParametersOk := SequentialParameters(&value, valueParameterStorage[:])
	testing.expect(t, policyParametersOk && valueParametersOk)
	if !policyParametersOk || !valueParametersOk { return }
	combinedParameters: [4]^core.Node
	copy(combinedParameters[:2], policyParameters)
	copy(combinedParameters[2:], valueParameters)
	firstMoment, secondMoment: [9]f32
	adam: Adam
	testing.expect(t, AdamInit(&adam, combinedParameters[:], firstMoment[:], secondMoment[:], learningRate = 0.01))

	indices: [5]int
	batchObservations: [4]f32
	batchActions: [2]int
	batchLegal: [4]bool
	batchLogProbabilities: [2]f64
	batchAdvantages, batchReturns: [2]f32
	epochMetrics: [2]PPOEpochStats
	fitStorage := PPOFitStorage{
		indices = indices[:], observations = batchObservations[:], actions = batchActions[:],
		legalActions = batchLegal[:], oldLogProbabilities = batchLogProbabilities[:],
		advantages = batchAdvantages[:], returns = batchReturns[:], epochMetrics = epochMetrics[:],
	}
	config := PPOConfig{0.2, 0.01, 0.5, 1}
	fitConfig := PPOFitConfig{epochs = 2, batchSize = 2, maxGradientNorm = 0.000001, finalLearningRate = 0.002}
	randomState: u64 = 42
	stats, fitOk := SequentialPPOFit(
		&policy, &value, &buffer, &randomState, config, fitConfig, &adam, fitStorage,
	)
	testing.expect(t, fitOk && stats.epochs == 2 && stats.updates == 6 && adam.step == 6)
	testing.expect(t, fitOk && stats.gradientClippedUpdates > 0 && stats.finalLearningRate == 0.002)
	testing.expect(t, fitOk && adam.learningRate == 0.002 && PPOFiniteF64(stats.explainedVariance))
	if !fitOk { return }
	for metric, epoch in epochMetrics {
		testing.expect(t, metric.epoch == epoch+1 && metric.updates == 3)
		testing.expect(t, PPOFiniteF64(metric.totalLoss) && PPOFiniteF64(metric.explainedVariance))
		testing.expect(t, metric.gradientClippedUpdates > 0 && metric.gradientNorm > 0)
	}
	clippedNormSquared: f64
	for parameter in combinedParameters {
		for gradient in parameter.grad.data { clippedNormSquared += f64(gradient)*f64(gradient) }
	}
	testing.expect(t, math.sqrt(clippedNormSquared) <= 0.00000101)

	stateBefore, stepBefore := randomState, adam.step
	fitConfig.epochs = 3 // The metrics slice is too small; reject before RNG/optimizer changes.
	_, fitOk = SequentialPPOFit(&policy, &value, &buffer, &randomState, config, fitConfig, &adam, fitStorage)
	testing.expect(t, !fitOk && randomState == stateBefore && adam.step == stepBefore)

}
