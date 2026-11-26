package main

import "../data"
import "core:fmt"

// Run with: odin run example/running_normalization.odin -file
main :: proc() {
	observationMean, observationM2: [2]f64
	observationNormalizer: data.RunningStandardizer
	assert(data.RunningStandardizerInit(&observationNormalizer, observationMean[:], observationM2[:]))

	// Update from training observations only, then freeze for evaluation.
	trainingObservations := [8]f32{0, 1, 0.25, 1, 0.5, 1, 0.75, 1}
	assert(data.RunningStandardizerUpdate(&observationNormalizer, trainingObservations[:]))
	assert(data.RunningStandardizerFreeze(&observationNormalizer))

	evaluationObservation := [2]f32{0.6, 1}
	normalizedObservation: [2]f32
	assert(data.RunningStandardizerTransform(
		&observationNormalizer, evaluationObservation[:], normalizedObservation[:],
	))
	fmt.printf("Observation mean: %v\n", observationMean)
	fmt.printf("Normalized evaluation input: %v\n", normalizedObservation)

	rewards := [3]f32{-1, 0, 1}
	rewardMean, rewardM2: [1]f64
	rewardNormalizer: data.RunningStandardizer
	assert(data.RunningStandardizerInit(&rewardNormalizer, rewardMean[:], rewardM2[:]))
	assert(data.RunningStandardizerUpdate(&rewardNormalizer, rewards[:]))
	assert(data.RunningStandardizerFreeze(&rewardNormalizer))
	normalizedRewards: [3]f32
	assert(data.RunningStandardizerTransform(&rewardNormalizer, rewards[:], normalizedRewards[:]))
	fmt.printf("Normalized reward samples: %v\n", normalizedRewards)
	assert(!data.RunningStandardizerUpdate(&observationNormalizer, evaluationObservation[:]))
}
