package nn

import "../core"
import "core:math"
import "core:testing"

@(test)
MetricsCategoricalValues :: proc(t: ^testing.T) {
	shape := [3]int{2, 2, 3}
	values := [12]f32{2, 2, -1, -1000, 1000, 0, 1, 3, 2, 9, 0, 1}
	targets := [12]f32{0.5, 0.5, 0, 0, 1, 0, 0.1, 0.2, 0.7, 0, 1, 0}
	originalValues, originalTargets := values, targets
	prediction := core.Tensor{shape[:], values[:]}
	target := core.Tensor{shape[:], targets[:]}
	value, ok := CategoricalAccuracyWithLogits(prediction, target)
	testing.expect(t, ok && value == 0.5)
	testing.expect(t, values == originalValues && targets == originalTargets)
	rowShape := [1]int{3}
	value, ok = CategoricalAccuracyWithLogits(core.Tensor{rowShape[:], values[:3]}, core.Tensor{rowShape[:], targets[:3]})
	testing.expect(t, ok && value == 1)
}

@(test)
MetricsBinaryValues :: proc(t: ^testing.T) {
	shape := [2]int{2, 3}
	values := [6]f32{-1000, 0, 1000, -1, 1, 0}
	targets := [6]f32{0, 1, 1, 1, 0, 0}
	originalValues, originalTargets := values, targets
	value, ok := BinaryAccuracyWithLogits(core.Tensor{shape[:], values[:]}, core.Tensor{shape[:], targets[:]})
	testing.expect(t, ok && value == 0.5)
	testing.expect(t, values == originalValues && targets == originalTargets)
	value, ok = BinaryAccuracyWithLogits(core.Tensor{nil, values[1:2]}, core.Tensor{nil, targets[1:2]})
	testing.expect(t, ok && value == 1)
}

@(test)
MetricsValidation :: proc(t: ^testing.T) {
	shape := [2]int{2, 2}
	values := [4]f32{1, 2, 3, 4}
	targets := [4]f32{0, 1, 1, 0}
	prediction := core.Tensor{shape[:], values[:]}
	target := core.Tensor{shape[:], targets[:]}
	for invalid in ([4]f32{-1, 2, transmute(f32)u32(0x7fc00000), transmute(f32)u32(0x7f800000)}) {
		targets[3] = invalid
		_, binaryOk := BinaryAccuracyWithLogits(prediction, target)
		_, categoricalOk := CategoricalAccuracyWithLogits(prediction, target)
		testing.expect(t, !binaryOk && !categoricalOk)
	}
	targets[3] = 0.5
	_, ok := BinaryAccuracyWithLogits(prediction, target)
	testing.expect(t, !ok)
	_, ok = CategoricalAccuracyWithLogits(prediction, target)
	testing.expect(t, !ok)
	targets[3] = 0
	for invalid in ([2]f32{transmute(f32)u32(0x7fc00000), transmute(f32)u32(0xff800000)}) {
		values[3] = invalid
		_, binaryOk := BinaryAccuracyWithLogits(prediction, target)
		_, categoricalOk := CategoricalAccuracyWithLogits(prediction, target)
		testing.expect(t, !binaryOk && !categoricalOk)
	}
	values[3] = 4
	badShape := [1]int{4}
	bad := core.Tensor{badShape[:], targets[:]}
	_, binaryOk := BinaryAccuracyWithLogits(prediction, bad)
	_, categoricalOk := CategoricalAccuracyWithLogits(prediction, bad)
	testing.expect(t, !binaryOk && !categoricalOk)
	bad = core.Tensor{shape[:], targets[:3]}
	_, binaryOk = BinaryAccuracyWithLogits(prediction, bad)
	_, categoricalOk = CategoricalAccuracyWithLogits(prediction, bad)
	testing.expect(t, !binaryOk && !categoricalOk)
	for emptyShape in ([2][2]int{{0, 2}, {2, 0}}) {
		shapeCopy := emptyShape
		empty := core.Tensor{shapeCopy[:], nil}
		_, binaryOk = BinaryAccuracyWithLogits(empty, empty)
		_, categoricalOk = CategoricalAccuracyWithLogits(empty, empty)
		testing.expect(t, !binaryOk && !categoricalOk)
	}
	scalar := core.Tensor{nil, targets[:1]}
	_, ok = CategoricalAccuracyWithLogits(scalar, scalar)
	testing.expect(t, !ok)
}

@(test)
MetricsExistingMeanAbsoluteError :: proc(t: ^testing.T) {
	shape := [1]int{3}
	values := [3]f32{-2, 0, 4}
	targets := [3]f32{1, 0, 1}
	prediction := core.Tensor{shape[:], values[:]}
	target := core.Tensor{shape[:], targets[:]}
	value, ok := MeanAbsoluteError(prediction, target)
	testing.expect(t, ok && math.abs(value - 2) < 0.000001)
	targets[1] = transmute(f32)u32(0x7fc00000)
	_, ok = MeanAbsoluteError(prediction, target)
	testing.expect(t, !ok)
}
