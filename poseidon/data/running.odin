package data

import "core:math"

// RunningStandardizer stores per-feature population moments using Welford's
// online algorithm. Mean and M2 slices are caller-owned and remain attached to
// the object; do not move/copy initialized instances when another object refers
// to their storage.
RunningStandardizer :: struct {
	count:  u64,
	mean:   []f64,
	m2:     []f64,
	epsilon: f64,
	frozen: bool,
}

RunningRange :: struct {
	address: uintptr,
	bytes:   uintptr,
}

RunningRangeOf :: proc(data: rawptr, count, elementSize: int) -> (RunningRange, bool) {
	if count < 0 || elementSize <= 0 || uintptr(count) > max(uintptr)/uintptr(elementSize) {
		return {}, false
	}
	return RunningRange{uintptr(data), uintptr(count)*uintptr(elementSize)}, true
}

RunningRangesOverlap :: proc(a, b: RunningRange) -> bool {
	if a.bytes == 0 || b.bytes == 0 do return false
	if a.address >= b.address do return a.address-b.address < b.bytes
	return b.address-a.address < a.bytes
}

RunningFiniteF64 :: proc(value: f64) -> bool {
	return !math.is_nan(value) && !math.is_inf(value)
}

RunningStandardizerValid :: proc(normalizer: ^RunningStandardizer) -> bool {
	if normalizer == nil || len(normalizer.mean) == 0 || len(normalizer.mean) != len(normalizer.m2) ||
		!RunningFiniteF64(normalizer.epsilon) || normalizer.epsilon <= 0 {
		return false
	}
	meanRange, meanOk := RunningRangeOf(rawptr(raw_data(normalizer.mean)), len(normalizer.mean), size_of(f64))
	m2Range, m2Ok := RunningRangeOf(rawptr(raw_data(normalizer.m2)), len(normalizer.m2), size_of(f64))
	if !meanOk || !m2Ok || RunningRangesOverlap(meanRange, m2Range) do return false
	for mean, feature in normalizer.mean {
		if !RunningFiniteF64(mean) || !RunningFiniteF64(normalizer.m2[feature]) || normalizer.m2[feature] < 0 {
			return false
		}
		if normalizer.count == 0 && (mean != 0 || normalizer.m2[feature] != 0) do return false
	}
	return true
}

// Initializes empty running moments. Epsilon is added to each population
// variance before taking the square root. Mean and M2 storage must be disjoint
// from the normalizer object and each other. No allocation is performed.
RunningStandardizerInit :: proc(
	normalizer: ^RunningStandardizer,
	mean, m2: []f64,
	epsilon: f64 = 1e-8,
) -> bool {
	if normalizer == nil || len(mean) == 0 || len(mean) != len(m2) ||
		!RunningFiniteF64(epsilon) || epsilon <= 0 {
		return false
	}
	meanRange, meanOk := RunningRangeOf(rawptr(raw_data(mean)), len(mean), size_of(f64))
	m2Range, m2Ok := RunningRangeOf(rawptr(raw_data(m2)), len(m2), size_of(f64))
	objectRange, objectOk := RunningRangeOf(rawptr(normalizer), 1, size_of(RunningStandardizer))
	if !meanOk || !m2Ok || !objectOk || RunningRangesOverlap(meanRange, m2Range) ||
		RunningRangesOverlap(meanRange, objectRange) || RunningRangesOverlap(m2Range, objectRange) {
		return false
	}
	for &value in mean { value = 0 }
	for &value in m2 { value = 0 }
	normalizer^ = RunningStandardizer{mean = mean, m2 = m2, epsilon = epsilon}
	return true
}

// Update consumes one or more row-major observations. Frozen statistics reject
// updates until explicitly unfrozen. Inputs must be disjoint from moment storage.
// Invalid or non-finite inputs are rejected before any moments change.
RunningStandardizerUpdate :: proc(normalizer: ^RunningStandardizer, observations: []f32) -> bool {
	if !RunningStandardizerValid(normalizer) || normalizer.frozen || len(observations) == 0 ||
		len(observations)%len(normalizer.mean) != 0 {
		return false
	}
	rows := len(observations)/len(normalizer.mean)
	if u64(rows) > max(u64)-normalizer.count do return false
	inputRange, inputOk := RunningRangeOf(rawptr(raw_data(observations)), len(observations), size_of(f32))
	meanRange, meanOk := RunningRangeOf(rawptr(raw_data(normalizer.mean)), len(normalizer.mean), size_of(f64))
	m2Range, m2Ok := RunningRangeOf(rawptr(raw_data(normalizer.m2)), len(normalizer.m2), size_of(f64))
	if !inputOk || !meanOk || !m2Ok || RunningRangesOverlap(inputRange, meanRange) ||
		RunningRangesOverlap(inputRange, m2Range) {
		return false
	}
	for item in observations {
		if math.is_nan(item) || math.is_inf(item) do return false
	}
	for row in 0..<rows {
		count := normalizer.count+u64(row)+1
		for feature in 0..<len(normalizer.mean) {
			item := f64(observations[row*len(normalizer.mean)+feature])
			delta := item-normalizer.mean[feature]
			mean := normalizer.mean[feature]+delta/f64(count)
			m2 := normalizer.m2[feature]+delta*(item-mean)
			normalizer.mean[feature] = mean
			normalizer.m2[feature] = max(m2, 0)
		}
	}
	normalizer.count += u64(rows)
	return true
}

RunningStandardizerFreeze :: proc(normalizer: ^RunningStandardizer) -> bool {
	if !RunningStandardizerValid(normalizer) || normalizer.count == 0 do return false
	normalizer.frozen = true
	return true
}

RunningStandardizerUnfreeze :: proc(normalizer: ^RunningStandardizer) -> bool {
	if !RunningStandardizerValid(normalizer) do return false
	normalizer.frozen = false
	return true
}

// Applies (x - mean) / sqrt(populationVariance + epsilon) to complete rows.
// Input and output may be the same slice or disjoint; partial overlap is
// unsupported. Both must be disjoint from the moment arrays. No allocation is
// performed, and output is unchanged on validation or numeric failure.
RunningStandardizerTransform :: proc(normalizer: ^RunningStandardizer, input, output: []f32) -> bool {
	if !RunningStandardizerValid(normalizer) || normalizer.count == 0 || len(input) == 0 ||
		len(input)%len(normalizer.mean) != 0 || len(output) != len(input) {
		return false
	}
	inputRange, inputOk := RunningRangeOf(rawptr(raw_data(input)), len(input), size_of(f32))
	outputRange, outputOk := RunningRangeOf(rawptr(raw_data(output)), len(output), size_of(f32))
	meanRange, meanOk := RunningRangeOf(rawptr(raw_data(normalizer.mean)), len(normalizer.mean), size_of(f64))
	m2Range, m2Ok := RunningRangeOf(rawptr(raw_data(normalizer.m2)), len(normalizer.m2), size_of(f64))
	if !inputOk || !outputOk || !meanOk || !m2Ok ||
		(RunningRangesOverlap(inputRange, outputRange) && inputRange.address != outputRange.address) ||
		RunningRangesOverlap(inputRange, meanRange) || RunningRangesOverlap(inputRange, m2Range) ||
		RunningRangesOverlap(outputRange, meanRange) || RunningRangesOverlap(outputRange, m2Range) {
		return false
	}
	for pass in 0..<2 {
		for item, index in input {
			if math.is_nan(item) || math.is_inf(item) do return false
			feature := index%len(normalizer.mean)
			variance := max(normalizer.m2[feature]/f64(normalizer.count), 0)
			scale := math.sqrt(variance+normalizer.epsilon)
			standardized := (f64(item)-normalizer.mean[feature])/scale
			if !RunningFiniteF64(standardized) || math.abs(standardized) > 3.4028234663852886e+38 {
				return false
			}
			if pass == 1 { output[index] = f32(standardized) }
		}
	}
	return true
}

// Loads metadata after the caller has validated/copied mean and M2 values into
// the attached storage. Used by checkpoint restore; storage slices stay intact.
RunningStandardizerSetMetadata :: proc(
	normalizer: ^RunningStandardizer,
	count: u64,
	epsilon: f64,
	frozen: bool,
) -> bool {
	if normalizer == nil || len(normalizer.mean) == 0 || len(normalizer.mean) != len(normalizer.m2) ||
		!RunningFiniteF64(epsilon) || epsilon <= 0 {
		return false
	}
	candidate := RunningStandardizer{count, normalizer.mean, normalizer.m2, epsilon, frozen}
	if !RunningStandardizerValid(&candidate) do return false
	normalizer.count = count
	normalizer.epsilon = epsilon
	normalizer.frozen = frozen
	return true
}
