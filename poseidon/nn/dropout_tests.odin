package nn

import "../core"
import "core:testing"

@(test)
DropoutTrainingAndInference :: proc(t: ^testing.T) {
	shape := [1]int{8}
	values := [8]f32{1, 2, 3, 4, 5, 6, 7, 8}
	out, grad: [8]f32
	upstream := [8]f32{1, 1, 1, 1, 1, 1, 1, 1}
	mask: [8]f32
	input := core.Node{value = core.Tensor{shape[:], values[:]}, grad = core.Tensor{shape[:], grad[:]}}
	output := core.Node{value = core.Tensor{shape[:], out[:]}, grad = core.Tensor{shape[:], upstream[:]}}
	state: u64 = 12345
	layer := Dropout{&input, &output, mask[:], 0.5, &state, true}
	testing.expect(t, LayerForward(&layer))
	firstMask, firstOut, finalState := mask, out, state
	for i in 0..<8 {
		testing.expect(t, (mask[i] == 0 || mask[i] == 2) && out[i] == values[i] * mask[i])
	}
	testing.expect(t, LayerBackward(&layer) && LayerBackward(&layer))
	for i in 0..<8 { testing.expect(t, grad[i] == 2 * mask[i]) }
	state = 12345
	testing.expect(t, LayerForward(&layer))
	testing.expect(t, mask == firstMask && out == firstOut && state == finalState)
	layer.training = false
	testing.expect(t, LayerForward(&layer))
	testing.expect(t, state == finalState && out == values)
	for item in mask { testing.expect(t, item == 1) }
	grad = {}
	testing.expect(t, LayerBackward(&layer))
	testing.expect(t, grad == upstream)
	layer.training = true
	layer.rate = 0
	testing.expect(t, LayerForward(&layer))
	testing.expect(t, out == values && state != finalState)
}

@(test)
DropoutValidation :: proc(t: ^testing.T) {
	shape := [1]int{2}
	values := [2]f32{1, 2}
	out := [2]f32{7, 8}
	grad := [2]f32{3, 4}
	upstream := [2]f32{1, 2}
	mask := [2]f32{9, 10}
	input := core.Node{value = core.Tensor{shape[:], values[:]}, grad = core.Tensor{shape[:], grad[:]}}
	output := core.Node{value = core.Tensor{shape[:], out[:]}, grad = core.Tensor{shape[:], upstream[:]}}
	state: u64 = 42
	layer := Dropout{&input, &output, mask[:], 0.5, &state, true}
	for bad in ([5]f32{-1, 1, transmute(f32)u32(0x7f800000), transmute(f32)u32(0xff800000), transmute(f32)u32(0x7fc00000)}) {
		layer.rate = bad
		testing.expect(t, !LayerForward(&layer) && !LayerBackward(&layer))
	}
	layer.rate = 0.5
	layer.mask = mask[:1]
	testing.expect(t, !LayerForward(&layer) && !LayerBackward(&layer))
	layer.mask = mask[:]
	state = 0
	testing.expect(t, !LayerForward(&layer) && !LayerBackward(&layer))
	state = 42
	values[1] = transmute(f32)u32(0x7fc00000)
	testing.expect(t, !LayerForward(&layer))
	values[1] = 2
	upstream[1] = transmute(f32)u32(0x7f800000)
	testing.expect(t, !LayerBackward(&layer))
	testing.expect(t, state == 42 && out == [2]f32{7, 8} && mask == [2]f32{9, 10} && grad == [2]f32{3, 4})
	bad := Dropout{}
	testing.expect(t, !LayerForward(&bad) && !LayerBackward(&bad))
}

@(test)
DropoutEmpty :: proc(t: ^testing.T) {
	shape := [2]int{3, 0}
	input := core.Node{value = core.Tensor{shape[:], nil}, grad = core.Tensor{shape[:], nil}}
	output := core.Node{value = core.Tensor{shape[:], nil}, grad = core.Tensor{shape[:], nil}}
	state: u64 = 7
	layer := Dropout{&input, &output, nil, 0.5, &state, true}
	testing.expect(t, LayerForward(&layer) && LayerBackward(&layer) && state == 7)
}
