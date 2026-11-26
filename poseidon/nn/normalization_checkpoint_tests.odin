package nn

import "../core"
import "../data"
import "core:testing"

@(test)
PPOTrainingCheckpointAndPolicyExportPreserveNormalization :: proc(t: ^testing.T) {
	policy, value: Sequential(1, 2, 2)
	initialized := SequentialInit(&policy, 1, 17) && SequentialAddDense(&policy, 2) &&
		SequentialInit(&value, 1, 29) && SequentialAddDense(&value, 1)
	testing.expect(t, initialized)
	if !initialized { return }

	observationMean, observationM2, rewardMean, rewardM2: [1]f64
	observationNormalizer, rewardNormalizer: data.RunningStandardizer
	testing.expect(t, data.RunningStandardizerInit(&observationNormalizer, observationMean[:], observationM2[:]))
	testing.expect(t, data.RunningStandardizerInit(&rewardNormalizer, rewardMean[:], rewardM2[:]))
	observations := [3]f32{0, 2, 4}
	rewards := [2]f32{-1, 1}
	testing.expect(t, data.RunningStandardizerUpdate(&observationNormalizer, observations[:]))
	testing.expect(t, data.RunningStandardizerUpdate(&rewardNormalizer, rewards[:]))
	testing.expect(t, data.RunningStandardizerFreeze(&observationNormalizer) && data.RunningStandardizerFreeze(&rewardNormalizer))
	normalizers := PPOTrainingNormalizers{&observationNormalizer, &rewardNormalizer}

	policyParameterStorage, valueParameterStorage: [2]^core.Node
	policyParameters, policyOk := SequentialParameters(&policy, policyParameterStorage[:])
	valueParameters, valueOk := SequentialParameters(&value, valueParameterStorage[:])
	testing.expect(t, policyOk && valueOk)
	if !policyOk || !valueOk { return }
	combinedParameters: [4]^core.Node
	copy(combinedParameters[:2], policyParameters)
	copy(combinedParameters[2:], valueParameters)
	firstMoment, secondMoment: [6]f32
	adam: Adam
	testing.expect(t, AdamInit(&adam, combinedParameters[:], firstMoment[:], secondMoment[:], learningRate = 0.005))
	state: PPOTrainingState
	testing.expect(t, PPOTrainingStateInit(&state, 1234, 5678))
	ppoConfig := PPOConfig{0.2, 0.01, 0.5, 1}
	fitConfig := PPOFitConfig{epochs = 2, batchSize = 2, maxGradientNorm = 0.5, finalLearningRate = 0.003}

	checkpoint, baseScratch, policyScratch, valueScratch: [2048]u8
	size, writeOk := PPOCheckpointWriteNormalized(
		&policy, &value, &adam, state, ppoConfig, fitConfig, normalizers,
		checkpoint[:], baseScratch[:], policyScratch[:], valueScratch[:],
	)
	testing.expect(t, writeOk && size > 0)
	if !writeOk { return }

	restoredPolicy, restoredValue: Sequential(1, 2, 2)
	restoredAdam: Adam
	restoredParameters: [4]^core.Node
	restoredFirst, restoredSecond: [6]f32
	restoredObservationMean, restoredObservationM2, restoredRewardMean, restoredRewardM2: [1]f64
	restoredObservationNormalizer, restoredRewardNormalizer: data.RunningStandardizer
	testing.expect(t, data.RunningStandardizerInit(&restoredObservationNormalizer, restoredObservationMean[:], restoredObservationM2[:]))
	testing.expect(t, data.RunningStandardizerInit(&restoredRewardNormalizer, restoredRewardMean[:], restoredRewardM2[:]))
	restoredNormalizers := PPOTrainingNormalizers{&restoredObservationNormalizer, &restoredRewardNormalizer}
	restoredState, restoredPPOConfig, restoredFitConfig, restoredOptimizer, readOk := PPOCheckpointReadNormalized(
		&restoredPolicy, &restoredValue, checkpoint[:size], &restoredAdam,
		restoredParameters[:], restoredFirst[:], restoredSecond[:], restoredNormalizers,
	)
	testing.expect(t, readOk && restoredState == state && restoredPPOConfig == ppoConfig && restoredFitConfig == fitConfig)
	testing.expect(t, readOk && restoredAdam.step == adam.step && restoredFirst == firstMoment && restoredSecond == secondMoment)
	testing.expect(t, readOk && restoredObservationNormalizer.count == 3 && restoredObservationNormalizer.frozen)
	testing.expect(t, readOk && restoredObservationMean == observationMean && restoredObservationM2 == observationM2)
	testing.expect(t, readOk && restoredRewardNormalizer.count == 2 && restoredRewardNormalizer.frozen)
	testing.expect(t, readOk && restoredRewardMean == rewardMean && restoredRewardM2 == rewardM2)
	if !readOk { return }
	if _, isAdam := restoredOptimizer.(^Adam); !isAdam { testing.expect(t, false); return }

	exportBytes, exportScratch: [1024]u8
	exportSize, exportOk := PPOPolicyExportWrite(
		&policy, &observationNormalizer, exportBytes[:], exportScratch[:],
	)
	testing.expect(t, exportOk && exportSize > 0)
	if !exportOk { return }
	exportedPolicy: Sequential(1, 2, 2)
	exportedMean, exportedM2: [1]f64
	exportedNormalizer: data.RunningStandardizer
	testing.expect(t, data.RunningStandardizerInit(&exportedNormalizer, exportedMean[:], exportedM2[:]))
	testing.expect(t, PPOPolicyExportRead(&exportedPolicy, exportBytes[:exportSize], &exportedNormalizer))
	testing.expect(t, exportedNormalizer.count == observationNormalizer.count && exportedNormalizer.frozen)
	testing.expect(t, exportedMean == observationMean && exportedM2 == observationM2)

	rawObservation := [1]f32{2}
	normalizedA, normalizedB: [1]f32
	testing.expect(t, data.RunningStandardizerTransform(&observationNormalizer, rawObservation[:], normalizedA[:]))
	testing.expect(t, data.RunningStandardizerTransform(&exportedNormalizer, rawObservation[:], normalizedB[:]))
	legal := [2]bool{true, true}
	actionA, logA, actionAOk := SequentialPolicyAction(&policy, normalizedA[:], legal[:], .Greedy)
	actionB, logB, actionBOk := SequentialPolicyAction(&exportedPolicy, normalizedB[:], legal[:], .Greedy)
	testing.expect(t, actionAOk && actionBOk && actionA == actionB && logA == logB)
}
