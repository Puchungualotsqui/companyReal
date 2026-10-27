package core

import "core:testing"

@(test)
BroadcastScalarsAndAxes :: proc(t: ^testing.T) {
	scalarA := [1]f32{2}
	scalarB := [1]f32{3}
	scalarOut: [1]f32
	a := Tensor{nil, scalarA[:]}
	b := Tensor{nil, scalarB[:]}
	output := Tensor{nil, scalarOut[:]}
	testing.expect(t, BroadcastValid(output, a, b) && AddBroadcast(output, a, b))
	testing.expect(t, scalarOut == [1]f32{5})

	aShape := [3]int{2, 1, 3}
	bShape := [2]int{4, 1}
	outShape := [3]int{2, 4, 3}
	aData := [6]f32{1, 2, 3, 4, 5, 6}
	bData := [4]f32{10, 20, 30, 40}
	outData: [24]f32
	a = Tensor{aShape[:], aData[:]}
	b = Tensor{bShape[:], bData[:]}
	output = Tensor{outShape[:], outData[:]}
	testing.expect(t, AddBroadcast(output, a, b))
	testing.expect(t, outData == [24]f32{11, 12, 13, 21, 22, 23, 31, 32, 33, 41, 42, 43, 14, 15, 16, 24, 25, 26, 34, 35, 36, 44, 45, 46})
	testing.expect(t, AddBroadcast(output, b, a))
	testing.expect(t, outData == [24]f32{11, 12, 13, 21, 22, 23, 31, 32, 33, 41, 42, 43, 14, 15, 16, 24, 25, 26, 34, 35, 36, 44, 45, 46})
	shape := [1]int{6}
	vectorOut: [6]f32
	testing.expect(t, AddBroadcast(Tensor{shape[:], vectorOut[:]}, Tensor{shape[:], aData[:]}, Tensor{nil, scalarA[:]}))
	testing.expect(t, vectorOut == [6]f32{3, 4, 5, 6, 7, 8})
}

@(test)
BroadcastZeroDimensions :: proc(t: ^testing.T) {
	zeroShape := [3]int{2, 0, 3}
	oneShape := [2]int{1, 3}
	oneData := [3]f32{1, 2, 3}
	zero := Tensor{zeroShape[:], nil}
	one := Tensor{oneShape[:], oneData[:]}
	testing.expect(t, AddBroadcast(zero, zero, one))
	testing.expect(t, AddBroadcast(zero, one, zero))
	testing.expect(t, AddBroadcast(zero, zero, zero))
	badShape := [2]int{2, 3}
	badData: [6]f32
	testing.expect(t, !BroadcastValid(zero, zero, Tensor{badShape[:], badData[:]}))
}

@(test)
BroadcastInvalidDoesNotMutate :: proc(t: ^testing.T) {
	shape := [1]int{2}
	wrongShape := [2]int{1, 2}
	threeShape := [1]int{3}
	overflowShape := [2]int{max(int), 2}
	negativeShape := [1]int{-1}
	aData := [2]f32{1, 2}
	bData := [3]f32{3, 4, 5}
	outData := [2]f32{91, 92}
	output := Tensor{shape[:], outData[:]}
	a := Tensor{shape[:], aData[:]}
	testing.expect(t, !AddBroadcast(output, a, Tensor{threeShape[:], bData[:]}))
	testing.expect(t, !AddBroadcast(Tensor{wrongShape[:], outData[:]}, a, a))
	testing.expect(t, !AddBroadcast(Tensor{shape[:], outData[:1]}, a, a))
	testing.expect(t, !AddBroadcast(output, Tensor{shape[:], aData[:1]}, a))
	testing.expect(t, !AddBroadcast(output, a, Tensor{overflowShape[:], nil}))
	testing.expect(t, !AddBroadcast(output, a, Tensor{negativeShape[:], nil}))
	testing.expect(t, outData == [2]f32{91, 92})
}
