package rl

import "core:math"

// EvaluationAccumulator keeps allocation-free online episode statistics. The
// caller defines success and custom metric semantics; Poseidon never depends on
// a game outcome type.
EvaluationAccumulator :: struct {
	episodes:       u64,
	successes:      u64,
	totalLength:    u64,
	meanReturn:     f64,
	returnM2:       f64,
	customMeans:    []f64,
}

EvaluationSummary :: struct {
	episodes:       u64,
	meanReturn:     f64,
	returnStdDev:   f64, // Population standard deviation across episode returns.
	meanLength:     f64,
	successRate:    f64,
}

EvaluationFiniteF64 :: proc(value: f64) -> bool {
	return !math.is_nan(value) && !math.is_inf(value)
}

// Storage is caller-owned and must remain alive for the accumulator lifetime.
// Initialization resets the means and counters; it does not allocate.
EvaluationAccumulatorInit :: proc(accumulator: ^EvaluationAccumulator, customMeans: []f64) -> bool {
	if accumulator == nil do return false
	for &mean in customMeans { mean = 0 }
	accumulator^ = EvaluationAccumulator{customMeans = customMeans}
	return true
}

// Records one complete episode. customMetrics must match the number of custom
// metric slots. Invalid values and counter overflow leave the accumulator intact.
EvaluationRecordEpisode :: proc(
	accumulator: ^EvaluationAccumulator,
	episodeReturn: f64,
	episodeLength: u64,
	success: bool,
	customMetrics: []f64 = nil,
) -> bool {
	if accumulator == nil || len(customMetrics) != len(accumulator.customMeans) ||
		accumulator.episodes == max(u64) || accumulator.totalLength > max(u64)-episodeLength ||
		(success && accumulator.successes == max(u64)) || !EvaluationFiniteF64(episodeReturn) ||
		!EvaluationFiniteF64(accumulator.meanReturn) || !EvaluationFiniteF64(accumulator.returnM2) {
		return false
	}
	for metric, index in customMetrics {
		if !EvaluationFiniteF64(metric) || !EvaluationFiniteF64(accumulator.customMeans[index]) do return false
	}
	newCount := accumulator.episodes+1
	delta := episodeReturn-accumulator.meanReturn
	newMean := accumulator.meanReturn+delta/f64(newCount)
	newM2 := accumulator.returnM2+delta*(episodeReturn-newMean)
	if !EvaluationFiniteF64(newMean) || !EvaluationFiniteF64(newM2) do return false
	for metric, index in customMetrics {
		newCustomMean := accumulator.customMeans[index]+(metric-accumulator.customMeans[index])/f64(newCount)
		if !EvaluationFiniteF64(newCustomMean) do return false
	}

	accumulator.episodes = newCount
	accumulator.totalLength += episodeLength
	if success { accumulator.successes += 1 }
	accumulator.meanReturn = newMean
	accumulator.returnM2 = newM2
	for metric, index in customMetrics {
		accumulator.customMeans[index] += (metric-accumulator.customMeans[index])/f64(newCount)
	}
	return true
}

// Returns aggregate episode metrics and copies custom metric means to output.
// Custom output may alias the accumulator's customMeans slice.
EvaluationAccumulatorSummary :: proc(
	accumulator: ^EvaluationAccumulator,
	customMeans: []f64,
) -> (EvaluationSummary, bool) {
	if accumulator == nil || accumulator.episodes == 0 || accumulator.successes > accumulator.episodes ||
		len(customMeans) != len(accumulator.customMeans) ||
		!EvaluationFiniteF64(accumulator.meanReturn) || !EvaluationFiniteF64(accumulator.returnM2) {
		return {}, false
	}
	for mean in accumulator.customMeans { if !EvaluationFiniteF64(mean) do return {}, false }
	variance := max(accumulator.returnM2/f64(accumulator.episodes), 0)
	standardDeviation := math.sqrt(variance)
	summary := EvaluationSummary{
		episodes = accumulator.episodes,
		meanReturn = accumulator.meanReturn,
		returnStdDev = standardDeviation,
		meanLength = f64(accumulator.totalLength)/f64(accumulator.episodes),
		successRate = f64(accumulator.successes)/f64(accumulator.episodes),
	}
	if !EvaluationFiniteF64(summary.meanLength) || !EvaluationFiniteF64(summary.successRate) ||
		!EvaluationFiniteF64(summary.returnStdDev) {
		return {}, false
	}
	copy(customMeans, accumulator.customMeans)
	return summary, true
}
