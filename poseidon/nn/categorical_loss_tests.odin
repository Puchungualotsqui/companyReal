package nn

import "../core"
import "core:math"
import "core:testing"

@(test)
CategoricalLossValuesAndGradient :: proc(t: ^testing.T) {
	shape := [3]int{2, 2, 3}
	values := [12]f32{0, 0, 0, 1, 2, 3, -1, 0, 1, 4, -2, 1}
	targets := [12]f32{1, 0, 0, 0, 0, 1, 0.2, 0.3, 0.5, 0.1, 0.7, 0.2}
	grad: [12]f32
	prediction := core.Node{value = core.Tensor{shape[:], values[:]}, grad = core.Tensor{shape[:], grad[:]}}
	target := core.Tensor{shape[:], targets[:]}
	loss, ok := CategoricalCrossEntropyWithLogits(prediction.value, target)
	expected := (math.ln(f64(3)) + 0.4076059644 + 1.1076059644 + 4.85094576) / 4
	testing.expect(t, ok && math.abs(f64(loss) - expected) < 0.00001)
	testing.expect(t, CategoricalCrossEntropyWithLogitsBackward(&prediction, target))
	testing.expect(t, math.abs(grad[0] + 1.0/6.0) < 0.000001)
	testing.expect(t, math.abs(grad[1] - 1.0/12.0) < 0.000001)
	for i in 0..<len(values) {
		original := values[i]
		values[i] = original + 0.001
		plus, plusOk := CategoricalCrossEntropyWithLogits(prediction.value, target)
		values[i] = original - 0.001
		minus, minusOk := CategoricalCrossEntropyWithLogits(prediction.value, target)
		values[i] = original
		testing.expect(t, plusOk && minusOk && math.abs(grad[i] - (plus - minus) / 0.002) < 0.0002)
	}
	first := grad
	testing.expect(t, CategoricalCrossEntropyWithLogitsBackward(&prediction, target))
	for i in 0..<len(grad) { testing.expect(t, math.abs(grad[i] - 2 * first[i]) < 0.000001) }
}

@(test)
CategoricalLossExtremeAndSingleRow :: proc(t: ^testing.T) {
	shape := [1]int{3}
	values := [3]f32{1000, -1000, 999}
	targets := [3]f32{0, 1, 0}
	grad: [3]f32
	prediction := core.Node{value = core.Tensor{shape[:], values[:]}, grad = core.Tensor{shape[:], grad[:]}}
	target := core.Tensor{shape[:], targets[:]}
	loss, ok := CategoricalCrossEntropyWithLogits(prediction.value, target)
	testing.expect(t, ok && math.abs(loss - 2000.3132617) < 0.0002)
	testing.expect(t, CategoricalCrossEntropyWithLogitsBackward(&prediction, target))
	testing.expect(t, math.abs(grad[0] - 0.7310586) < 0.000001 && grad[1] == -1 && math.abs(grad[2] - 0.2689414) < 0.000001)
	values = [3]f32{3e38, -3e38, 3e38}
	targets = [3]f32{0, 1, 0}
	_, ok = CategoricalCrossEntropyWithLogits(prediction.value, target)
	testing.expect(t, !ok)
	targets = [3]f32{0.5, 0, 0.5}
	loss, ok = CategoricalCrossEntropyWithLogits(prediction.value, target)
	testing.expect(t, ok && math.abs(loss - 0.69314718) < 0.000001)
}

@(test)
CategoricalLossValidation :: proc(t: ^testing.T) {
	shape := [2]int{2, 2}
	values := [4]f32{1, 2, 3, 4}
	targets := [4]f32{1, 0, 0, 1}
	grad := [4]f32{1, 2, 3, 4}
	prediction := core.Node{value = core.Tensor{shape[:], values[:]}, grad = core.Tensor{shape[:], grad[:]}}
	target := core.Tensor{shape[:], targets[:]}
	for invalid in ([5]f32{-0.1, 1.1, 0.5, transmute(f32)u32(0x7fc00000), transmute(f32)u32(0x7f800000)}) {
		targets[3] = invalid
		_, ok := CategoricalCrossEntropyWithLogits(prediction.value, target)
		testing.expect(t, !ok && !CategoricalCrossEntropyWithLogitsBackward(&prediction, target))
		testing.expect(t, grad == [4]f32{1, 2, 3, 4})
	}
	targets[3] = 0.999995
	_, ok := CategoricalCrossEntropyWithLogits(prediction.value, target)
	testing.expect(t, ok && CategoricalCrossEntropyWithLogitsBackward(&prediction, target))
	grad = [4]f32{1, 2, 3, 4}
	targets[3] = 0.99998
	_, ok = CategoricalCrossEntropyWithLogits(prediction.value, target)
	testing.expect(t, !ok && !CategoricalCrossEntropyWithLogitsBackward(&prediction, target))
	targets[3] = 1
	values[3] = transmute(f32)u32(0xff800000)
	_, ok = CategoricalCrossEntropyWithLogits(prediction.value, target)
	testing.expect(t, !ok && !CategoricalCrossEntropyWithLogitsBackward(&prediction, target))
	values[3] = 4
	testing.expect(t, !CategoricalCrossEntropyWithLogitsBackward(nil, target))
	badShape := [1]int{4}
	bad := core.Tensor{badShape[:], targets[:]}
	_, ok = CategoricalCrossEntropyWithLogits(prediction.value, bad)
	testing.expect(t, !ok && !CategoricalCrossEntropyWithLogitsBackward(&prediction, bad))
	prediction.grad = bad
	testing.expect(t, !CategoricalCrossEntropyWithLogitsBackward(&prediction, target))
	testing.expect(t, grad == [4]f32{1, 2, 3, 4})
	scalar := core.Tensor{nil, values[:1]}
	_, ok = CategoricalCrossEntropyWithLogits(scalar, scalar)
	testing.expect(t, !ok)
	for shapeValue in ([2][2]int{{2, 0}, {0, 2}}) {
		emptyShape := shapeValue
		empty := core.Tensor{emptyShape[:], nil}
		_, ok = CategoricalCrossEntropyWithLogits(empty, empty)
		testing.expect(t, !ok && !CategoricalCrossEntropyWithLogitsBackward(&core.Node{value = empty, grad = empty}, empty))
	}
}
