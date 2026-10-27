package nn

import "../core"
import "core:math"
import "core:testing"

@(test)
AdditionalLossValuesAndGradients :: proc(t: ^testing.T) {
	shape := [1]int{4}
	values := [4]f32{-2, 0, 1, 3}
	targets := [4]f32{0, 0, 0, 1}
	grad := [4]f32{1, 1, 1, 1}
	prediction := core.Node{value = core.Tensor{shape[:], values[:]}, grad = core.Tensor{shape[:], grad[:]}}
	target := core.Tensor{shape[:], targets[:]}
	loss, ok := MeanAbsoluteError(prediction.value, target)
	testing.expect(t, ok && loss == 1.25)
	testing.expect(t, MeanAbsoluteErrorBackward(&prediction, target))
	testing.expect(t, grad == [4]f32{0.75, 1, 1.25, 1.25})
	grad = [4]f32{1, 1, 1, 1}
	loss, ok = HuberLoss(prediction.value, target, 1)
	testing.expect(t, ok && loss == 0.875)
	testing.expect(t, HuberLossBackward(&prediction, target, 1))
	testing.expect(t, grad == [4]f32{0.75, 1, 1.25, 1.25})

	grad = [4]f32{}
	loss, ok = BinaryCrossEntropyWithLogits(prediction.value, target)
	testing.expect(t, ok && math.abs(loss - 0.5454816) < 0.00001)
	testing.expect(t, BinaryCrossEntropyWithLogitsBackward(&prediction, target))
	for i in 0..<len(values) {
		original := values[i]
		values[i] = original + 0.001
		plus, plusOk := BinaryCrossEntropyWithLogits(prediction.value, target)
		values[i] = original - 0.001
		minus, minusOk := BinaryCrossEntropyWithLogits(prediction.value, target)
		values[i] = original
		testing.expect(t, plusOk && minusOk && math.abs(grad[i] - (plus - minus) / 0.002) < 0.0001)
	}
}

@(test)
AdditionalLossFiniteDifferences :: proc(t: ^testing.T) {
	shape := [1]int{3}
	values := [3]f32{-2, 0.25, 2}
	targets := [3]f32{0, 0, 0}
	grad: [3]f32
	prediction := core.Node{value = core.Tensor{shape[:], values[:]}, grad = core.Tensor{shape[:], grad[:]}}
	target := core.Tensor{shape[:], targets[:]}
	for huber in ([2]bool{false, true}) {
		grad = [3]f32{}
		if huber {
			testing.expect(t, HuberLossBackward(&prediction, target, 1))
		} else {
			testing.expect(t, MeanAbsoluteErrorBackward(&prediction, target))
		}
		for i in 0..<len(values) {
			original := values[i]
			values[i] = original + 0.001
			plus: f32
			plusOk: bool
			minus: f32
			minusOk: bool
			if huber { plus, plusOk = HuberLoss(prediction.value, target, 1) } else { plus, plusOk = MeanAbsoluteError(prediction.value, target) }
			values[i] = original - 0.001
			if huber { minus, minusOk = HuberLoss(prediction.value, target, 1) } else { minus, minusOk = MeanAbsoluteError(prediction.value, target) }
			values[i] = original
			testing.expect(t, plusOk && minusOk && math.abs(grad[i] - (plus - minus) / 0.002) < 0.0001)
		}
	}
}

@(test)
AdditionalLossValidation :: proc(t: ^testing.T) {
	shape := [1]int{2}
	values := [2]f32{-1000, 1000}
	targets := [2]f32{0, 1}
	grad := [2]f32{3, 4}
	prediction := core.Node{value = core.Tensor{shape[:], values[:]}, grad = core.Tensor{shape[:], grad[:]}}
	target := core.Tensor{shape[:], targets[:]}
	loss, ok := BinaryCrossEntropyWithLogits(prediction.value, target)
	testing.expect(t, ok && loss == 0)
	testing.expect(t, BinaryCrossEntropyWithLogitsBackward(&prediction, target))
	testing.expect(t, grad == [2]f32{3, 4})
	targets[1] = 2
	_, ok = BinaryCrossEntropyWithLogits(prediction.value, target)
	testing.expect(t, !ok && !BinaryCrossEntropyWithLogitsBackward(&prediction, target))
	testing.expect(t, !HuberLossBackward(&prediction, target, 0))
	_, ok = HuberLoss(prediction.value, target, -1)
	testing.expect(t, !ok && grad == [2]f32{3, 4})
	testing.expect(t, !MeanAbsoluteErrorBackward(nil, target))
	badShape := [1]int{1}
	bad := core.Tensor{badShape[:], targets[:1]}
	_, ok = MeanAbsoluteError(prediction.value, bad)
	testing.expect(t, !ok && !HuberLossBackward(&prediction, bad, 1))
	emptyShape := [1]int{0}
	empty := core.Tensor{emptyShape[:], nil}
	_, ok = BinaryCrossEntropyWithLogits(empty, empty)
	testing.expect(t, !ok)
	values[1] = transmute(f32)u32(0x7f800000)
	_, ok = MeanAbsoluteError(prediction.value, target)
	testing.expect(t, !ok && !MeanAbsoluteErrorBackward(&prediction, target))
	values[1] = 0
	targets[1] = transmute(f32)u32(0x7fc00000)
	_, ok = BinaryCrossEntropyWithLogits(prediction.value, target)
	testing.expect(t, !ok && !BinaryCrossEntropyWithLogitsBackward(&prediction, target))
	targets[1] = 1
	_, ok = HuberLoss(prediction.value, target, transmute(f32)u32(0x7fc00000))
	testing.expect(t, !ok && !HuberLossBackward(&prediction, target, transmute(f32)u32(0x7f800000)))
	prediction.grad = bad
	testing.expect(t, !MeanAbsoluteErrorBackward(&prediction, target))
	testing.expect(t, grad == [2]f32{3, 4})
}
