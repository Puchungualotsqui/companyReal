package data

import "core:math"
import "core:testing"

@(test)
StandardizationTrainingAndRoundTrip :: proc(t: ^testing.T) {
	training := [6]f32{1, 5, 3, 5, 5, 5}
	stats: [2]StandardizationStats
	testing.expect(t, StandardizationFit(training[:], stats[:]))
	testing.expect(t, stats[0].mean == 3 && math.abs(stats[0].scale - math.sqrt(f64(8.0/3.0))) < 1e-12)
	testing.expect(t, stats[1].mean == 5 && stats[1].scale == 1)
	validation := [4]f32{3, 7, 5, 4}
	original := validation
	output: [4]f32
	testing.expect(t, StandardizationTransform(validation[:], stats[:], output[:]))
	testing.expect(t, validation == original && output[0] == 0 && output[1] == 2 && output[3] == -1)
	testing.expect(t, StandardizationTransform(output[:], stats[:], output[:], inverse = true))
	for x, i in output { testing.expect(t, math.abs(x - original[i]) < 1e-6) }
	testing.expect(t, StandardizationTransform(validation[:], stats[:], validation[:]))
	testing.expect(t, StandardizationTransform(validation[:], stats[:], validation[:], inverse = true))
	for x, i in validation { testing.expect(t, math.abs(x - original[i]) < 1e-6) }
}

@(test)
StandardizationHeldOutIsolation :: proc(t: ^testing.T) {
	training := [2]f32{0, 2}
	validation := [1]f32{100}
	stats: [1]StandardizationStats
	output: [1]f32
	testing.expect(t, StandardizationFit(training[:], stats[:]))
	testing.expect(t, stats[0].mean == 1 && stats[0].scale == 1)
	before := stats
	testing.expect(t, StandardizationTransform(validation[:], stats[:], output[:]))
	testing.expect(t, output[0] == 99 && stats == before)
	validation[0] = -100
	testing.expect(t, StandardizationTransform(validation[:], stats[:], output[:]))
	testing.expect(t, output[0] == -101 && stats == before)
}

@(test)
StandardizationStableAndExtreme :: proc(t: ^testing.T) {
	values := [3]f32{100000000, 100000008, 100000016}
	stats: [1]StandardizationStats
	testing.expect(t, StandardizationFit(values[:], stats[:]))
	testing.expect(t, stats[0].mean == 100000008 && math.abs(stats[0].scale - math.sqrt(f64(128.0/3.0))) < 1e-10)
	largest := transmute(f32)u32(0x7f7fffff)
	extremes := [2]f32{-largest, largest}
	testing.expect(t, StandardizationFit(extremes[:], stats[:]))
	testing.expect(t, stats[0].mean == 0 && stats[0].scale == f64(largest))
	output: [2]f32
	testing.expect(t, StandardizationTransform(extremes[:], stats[:], output[:]))
	testing.expect(t, output == [2]f32{-1, 1})
	testing.expect(t, StandardizationTransform(output[:], stats[:], output[:], inverse = true))
	testing.expect(t, output == extremes)
	smallest := transmute(f32)u32(1)
	tiny := [2]f32{0, smallest}
	testing.expect(t, StandardizationFit(tiny[:], stats[:]))
	testing.expect(t, stats[0].scale == f64(smallest) / 2)
	testing.expect(t, StandardizationTransform(tiny[:], stats[:], output[:]))
	testing.expect(t, output == [2]f32{-1, 1})
}

@(test)
StandardizationValidation :: proc(t: ^testing.T) {
	input := [4]f32{1, 2, 3, 4}
	stats := [2]StandardizationStats{{10, 2}, {20, 3}}
	originalStats := stats
	output := [4]f32{7, 7, 7, 7}
	originalOutput := output
	testing.expect(t, !StandardizationFit(nil, stats[:]))
	testing.expect(t, !StandardizationFit(input[:3], stats[:]))
	testing.expect(t, !StandardizationFit(input[:], nil))
	for invalid in ([3]f32{transmute(f32)u32(0x7fc00000), transmute(f32)u32(0x7f800000), transmute(f32)u32(0xff800000)}) {
		input[3] = invalid
		testing.expect(t, !StandardizationFit(input[:], stats[:]) && stats == originalStats)
		testing.expect(t, !StandardizationTransform(input[:], stats[:], output[:]) && output == originalOutput)
	}
	input[3] = 4
	testing.expect(t, !StandardizationTransform(input[:3], stats[:], output[:3]))
	testing.expect(t, !StandardizationTransform(input[:], stats[:], output[:3]))
	testing.expect(t, !StandardizationTransform(nil, stats[:], nil))
	testing.expect(t, !StandardizationTransform(input[:], nil, output[:]))
	for invalid in ([4]f64{0, -1, transmute(f64)u64(0x7ff8000000000000), transmute(f64)u64(0x7ff0000000000000)}) {
		stats[1].scale = invalid
		testing.expect(t, !StandardizationTransform(input[:], stats[:], output[:]) && output == originalOutput)
	}
	stats = originalStats
	stats[1].mean = transmute(f64)u64(0x7ff0000000000000)
	testing.expect(t, !StandardizationTransform(input[:], stats[:], output[:]) && output == originalOutput)
	stats = originalStats
	stats[1].scale = 1e-300
	testing.expect(t, !StandardizationTransform(input[:], stats[:], output[:]) && output == originalOutput)
	stats[1] = {0, 1e300}
	testing.expect(t, !StandardizationTransform(input[:], stats[:], output[:], inverse = true) && output == originalOutput)
	before := input
	testing.expect(t, !StandardizationTransform(input[:], stats[:], input[:], inverse = true) && input == before)
}
