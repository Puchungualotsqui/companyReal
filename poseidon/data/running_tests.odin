package data

import "core:math"
import "core:testing"

RunningTestNear :: proc(a, b: f64, epsilon: f64 = 1e-6) -> bool {
	return math.abs(a-b) <= epsilon
}

@(test)
RunningStandardizerLifecycleAndTransform :: proc(t: ^testing.T) {
	means, m2: [2]f64
	normalizer: RunningStandardizer
	testing.expect(t, RunningStandardizerInit(&normalizer, means[:], m2[:]))
	observations := [6]f32{1, 10, 3, 14, 5, 18}
	testing.expect(t, RunningStandardizerUpdate(&normalizer, observations[:]))
	testing.expect(t, normalizer.count == 3 && means == [2]f64{3, 14} && m2 == [2]f64{8, 32})
	testing.expect(t, RunningStandardizerFreeze(&normalizer) && normalizer.frozen)
	beforeMeans, beforeM2 := means, m2
	additional := [2]f32{7, 22}
	testing.expect(t, !RunningStandardizerUpdate(&normalizer, additional[:]))
	testing.expect(t, means == beforeMeans && m2 == beforeM2 && normalizer.count == 3)

	transformed: [6]f32
	testing.expect(t, RunningStandardizerTransform(&normalizer, observations[:], transformed[:]))
	denominator := math.sqrt((8.0/3.0)+normalizer.epsilon)
	testing.expect(t, RunningTestNear(f64(transformed[0]), -2/denominator))
	testing.expect(t, RunningTestNear(f64(transformed[1]), -4/math.sqrt(32.0/3.0+normalizer.epsilon)))
	testing.expect(t, RunningTestNear(f64(transformed[4]), 2/denominator))

	testing.expect(t, RunningStandardizerUnfreeze(&normalizer) && !normalizer.frozen)
	testing.expect(t, RunningStandardizerUpdate(&normalizer, additional[:]))
	testing.expect(t, normalizer.count == 4 && means == [2]f64{4, 16})
	bad := additional
	bad[1] = math.nan_f32()
	beforeMeans, beforeM2 = means, m2
	testing.expect(t, !RunningStandardizerUpdate(&normalizer, bad[:]))
	testing.expect(t, means == beforeMeans && m2 == beforeM2 && normalizer.count == 4)
}

@(test)
RunningStandardizerScalarAndMetadataRestore :: proc(t: ^testing.T) {
	means, m2: [1]f64
	normalizer: RunningStandardizer
	testing.expect(t, RunningStandardizerInit(&normalizer, means[:], m2[:], epsilon = 1e-6))
	rewards := [3]f32{-2, 0, 2}
	testing.expect(t, RunningStandardizerUpdate(&normalizer, rewards[:]))
	testing.expect(t, means[0] == 0 && m2[0] == 8 && normalizer.count == 3)
	testing.expect(t, RunningStandardizerSetMetadata(&normalizer, normalizer.count, normalizer.epsilon, frozen = true))
	testing.expect(t, RunningStandardizerValid(&normalizer) && normalizer.frozen)
	restoredMean, restoredM2: [1]f64
	restored: RunningStandardizer
	testing.expect(t, RunningStandardizerInit(&restored, restoredMean[:], restoredM2[:]))
	restoredMean, restoredM2 = means, m2
	testing.expect(t, RunningStandardizerSetMetadata(&restored, 3, normalizer.epsilon, normalizer.frozen))
	testing.expect(t, RunningStandardizerValid(&restored) && restoredMean == means && restoredM2 == m2)
}
