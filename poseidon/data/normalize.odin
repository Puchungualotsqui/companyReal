package data

import "core:math"

// StandardizationStats stores a feature's mean and population standard deviation.
// A constant training feature has scale 1.
StandardizationStats :: struct {
	mean:  f64,
	scale: f64,
}

// StandardizationFit fits only the supplied training rows. Data is row-major;
// len(stats) is the feature count. All slices must be disjoint. No allocation
// is performed, and stats is unchanged on failure.
StandardizationFit :: proc(input: []f32, stats: []StandardizationStats) -> bool {
	features := len(stats)
	if features == 0 || len(input) == 0 || len(input) % features != 0 { return false }
	for x in input { if math.is_nan(x) || math.is_inf(x) { return false } }

	// Recompute after validation to avoid scratch allocation and partial writes.
	for pass in 0..<2 {
		for feature in 0..<features {
			mean, m2: f64
			count := 0
			for row in 0..<len(input) / features {
				count += 1
				x := f64(input[row * features + feature])
				delta := x - mean
				mean += delta / f64(count)
				m2 += delta * (x - mean)
			}
			scale := math.sqrt(max(m2 / f64(count), 0))
			if math.is_nan(mean) || math.is_inf(mean) || math.is_nan(scale) || math.is_inf(scale) { return false }
			if scale == 0 { scale = 1 }
			if pass == 1 { stats[feature] = {mean, scale} }
		}
	}
	return true
}

// StandardizationTransform applies (x - mean) / scale, or its inverse when
// inverse is true. Input and output may be exactly the same slice or disjoint;
// partial overlap is unsupported. Stats must be disjoint from both. Slices
// must contain complete nonempty rows, and output must match input's length.
// Non-finite values, invalid stats, or results outside finite f32 range fail
// without modifying output. Rounding and underflow to zero are permitted.
// No allocation is performed.
StandardizationTransform :: proc(input: []f32, stats: []StandardizationStats, output: []f32, inverse := false) -> bool {
	features := len(stats)
	if features == 0 || len(input) == 0 || len(input) % features != 0 || len(output) != len(input) { return false }
	for stat in stats {
		if math.is_nan(stat.mean) || math.is_inf(stat.mean) || math.is_nan(stat.scale) || math.is_inf(stat.scale) || stat.scale <= 0 { return false }
	}
	for pass in 0..<2 {
		for x, index in input {
			if math.is_nan(x) || math.is_inf(x) { return false }
			stat := stats[index % features]
			value: f64
			if inverse {
				value = f64(x) * stat.scale + stat.mean
			} else {
				value = (f64(x) - stat.mean) / stat.scale
			}
			if math.is_nan(value) || math.is_inf(value) || math.abs(value) > 3.4028234663852886e38 { return false }
			if pass == 1 { output[index] = f32(value) }
		}
	}
	return true
}
