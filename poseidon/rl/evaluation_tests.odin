package rl

import "core:math"
import "core:testing"

@(test)
EvaluationAccumulatorSummaryAndCustomMetrics :: proc(t: ^testing.T) {
	customMeans: [2]f64
	accumulator: EvaluationAccumulator
	testing.expect(t, EvaluationAccumulatorInit(&accumulator, customMeans[:]))
	firstCustom := [2]f64{1, 3}
	secondCustom := [2]f64{3, 5}
	testing.expect(t, EvaluationRecordEpisode(&accumulator, 1, 2, true, firstCustom[:]))
	testing.expect(t, EvaluationRecordEpisode(&accumulator, 3, 4, false, secondCustom[:]))
	customOutput: [2]f64
	summary, ok := EvaluationAccumulatorSummary(&accumulator, customOutput[:])
	testing.expect(t, ok && summary.episodes == 2 && summary.meanReturn == 2 && summary.returnStdDev == 1)
	testing.expect(t, summary.meanLength == 3 && summary.successRate == 0.5)
	testing.expect(t, customOutput == [2]f64{2, 4})

	oldAccumulator, oldMeans := accumulator, customMeans
	badCustom := [2]f64{math.nan_f64(), 9}
	testing.expect(t, !EvaluationRecordEpisode(&accumulator, 5, 1, true, badCustom[:]))
	testing.expect(t,
		accumulator.episodes == oldAccumulator.episodes && accumulator.successes == oldAccumulator.successes &&
		accumulator.totalLength == oldAccumulator.totalLength && accumulator.meanReturn == oldAccumulator.meanReturn &&
		accumulator.returnM2 == oldAccumulator.returnM2 && customMeans == oldMeans,
	)
	_, ok = EvaluationAccumulatorSummary(&accumulator, customOutput[:1])
	testing.expect(t, !ok)
}

@(test)
EvaluationAccumulatorEmptyAndOverflow :: proc(t: ^testing.T) {
	means: [1]f64
	accumulator: EvaluationAccumulator
	testing.expect(t, EvaluationAccumulatorInit(&accumulator, means[:]))
	output: [1]f64
	_, ok := EvaluationAccumulatorSummary(&accumulator, output[:])
	testing.expect(t, !ok)
	badCustom := [2]f64{1, 2}
	testing.expect(t, !EvaluationRecordEpisode(&accumulator, 1, 1, false, badCustom[:]))
	testing.expect(t, accumulator.episodes == 0)
}
