package core

import "core:testing"

@(test)
SumAxisShapes :: proc(t: ^testing.T) {
	shape := [3]int{2, 3, 2}
	data := [12]f32{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12}
	input := Tensor{shape[:], data[:]}
	firstShape := [2]int{3, 2}
	first: [6]f32
	firstKeep := [3]int{1, 3, 2}
	for keep in ([2]bool{false, true}) {
		outShape := firstShape[:]
		if keep { outShape = firstKeep[:] }
		testing.expect(t, SumAxis(Tensor{outShape, first[:]}, input, 0, keep))
		testing.expect(t, first == [6]f32{8, 10, 12, 14, 16, 18})
	}
	middleShape := [2]int{2, 2}
	middleKeep := [3]int{2, 1, 2}
	middle: [4]f32
	for keep in ([2]bool{false, true}) {
		outShape := middleShape[:]
		if keep { outShape = middleKeep[:] }
		testing.expect(t, SumAxis(Tensor{outShape, middle[:]}, input, 1, keep))
		testing.expect(t, middle == [4]f32{9, 12, 27, 30})
	}
	lastShape := [2]int{2, 3}
	lastKeep := [3]int{2, 3, 1}
	last: [6]f32
	for keep in ([2]bool{false, true}) {
		outShape := lastShape[:]
		if keep { outShape = lastKeep[:] }
		testing.expect(t, SumAxis(Tensor{outShape, last[:]}, input, 2, keep))
		testing.expect(t, last == [6]f32{3, 7, 11, 15, 19, 23})
	}
	vectorShape := [1]int{3}
	vector := [3]f32{1, -2, 4}
	scalar: [1]f32
	testing.expect(t, SumAxis(Tensor{nil, scalar[:]}, Tensor{vectorShape[:], vector[:]}, 0))
	testing.expect(t, scalar[0] == 3)
}

@(test)
SumAxisEmpty :: proc(t: ^testing.T) {
	shape := [3]int{2, 0, 3}
	outShape := [2]int{2, 3}
	keepShape := [3]int{2, 1, 3}
	output := [6]f32{1, 2, 3, 4, 5, 6}
	testing.expect(t, SumAxis(Tensor{outShape[:], output[:]}, Tensor{shape[:], nil}, 1))
	testing.expect(t, output == [6]f32{})
	output[0] = 9
	testing.expect(t, SumAxis(Tensor{keepShape[:], output[:]}, Tensor{shape[:], nil}, 1, true))
	testing.expect(t, output == [6]f32{})
	emptyShape := [2]int{0, 3}
	testing.expect(t, SumAxis(Tensor{emptyShape[:], nil}, Tensor{shape[:], nil}, 0))
	emptyLast := [2]int{2, 0}
	testing.expect(t, SumAxis(Tensor{emptyLast[:], nil}, Tensor{shape[:], nil}, 2))
	vectorShape := [1]int{0}
	scalar := [1]f32{7}
	testing.expect(t, SumAxis(Tensor{nil, scalar[:]}, Tensor{vectorShape[:], nil}, 0) && scalar[0] == 0)
	largeShape := [3]int{0, max(int), max(int)}
	largeOutputShape := [2]int{0, max(int)}
	testing.expect(t, SumAxis(Tensor{largeOutputShape[:], nil}, Tensor{largeShape[:], nil}, 1))
}

@(test)
SumAxisInvalid :: proc(t: ^testing.T) {
	shape := [2]int{2, 3}
	data := [6]f32{1, 2, 3, 4, 5, 6}
	input := Tensor{shape[:], data[:]}
	outShape := [1]int{2}
	output := [2]f32{7, 8}
	out := Tensor{outShape[:], output[:]}
	badShape := [1]int{3}
	badKeep := [2]int{1, 2}
	testing.expect(t, !SumAxis(out, input, -1) && !SumAxis(out, input, 2))
	testing.expect(t, !SumAxis(Tensor{badShape[:], output[:]}, input, 1))
	testing.expect(t, !SumAxis(Tensor{badKeep[:], output[:]}, input, 1, true))
	testing.expect(t, !SumAxis(out, Tensor{shape[:], data[:5]}, 1))
	testing.expect(t, !SumAxis(Tensor{outShape[:], output[:1]}, input, 1))
	testing.expect(t, !SumAxis(out, Tensor{nil, output[:1]}, 0))
	testing.expect(t, output == [2]f32{7, 8})
	original := data
	testing.expect(t, !SumAxis(Tensor{outShape[:], data[:2]}, input, 1))
	testing.expect(t, !SumAxis(Tensor{outShape[:], data[4:]}, input, 1))
	testing.expect(t, data == original)
	shared := [8]f32{1, 2, 3, 4, 5, 6, 7, 8}
	originalShared := shared
	testing.expect(t, !SumAxis(Tensor{outShape[:], shared[:2]}, Tensor{shape[:], shared[1:7]}, 1))
	testing.expect(t, shared == originalShared)
	testing.expect(t, SumAxis(Tensor{outShape[:], shared[6:]}, Tensor{shape[:], shared[:6]}, 1))
	testing.expect(t, shared[6] == 6 && shared[7] == 15)
}
