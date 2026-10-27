package core

import "core:testing"

@(test)
BroadcastAutogradNumerical :: proc(t: ^testing.T) {
	aShape := [3]int{2, 1, 3}
	bShape := [2]int{4, 1}
	outShape := [3]int{2, 4, 3}
	aData := [6]f32{1, 2, 3, 4, 5, 6}
	bData := [4]f32{-1, 2, 0, 3}
	aGrad, bGrad: [6]f32
	outData, outGrad: [24]f32
	for i in 0..<len(outGrad) { outGrad[i] = f32(i%7) - 3 }
	a := Node{value = Tensor{aShape[:], aData[:]}, grad = Tensor{aShape[:], aGrad[:]}}
	b := Node{value = Tensor{bShape[:], bData[:]}, grad = Tensor{bShape[:], bGrad[:4]}}
	out := Node{value = Tensor{outShape[:], outData[:]}, grad = Tensor{outShape[:], outGrad[:]}, op = BroadcastAddOp{&a, &b}}
	testing.expect(t, Forward(&out) && Backward(&out))
	for which in 0..<2 {
		input := &a
		if which == 1 { input = &b }
		for i in 0..<len(input.value.data) {
			original := input.value.data[i]
			input.value.data[i] = original + 0.01
			testing.expect(t, Forward(&out))
			plus: f32
			for j in 0..<len(outData) { plus += outData[j] * outGrad[j] }
			input.value.data[i] = original - 0.01
			testing.expect(t, Forward(&out))
			minus: f32
			for j in 0..<len(outData) { minus += outData[j] * outGrad[j] }
			input.value.data[i] = original
			difference := (plus - minus) / 0.02 - input.grad.data[i]
			testing.expect(t, difference > -0.01 && difference < 0.01)
		}
	}
}

@(test)
SumAxisAutogradNumerical :: proc(t: ^testing.T) {
	shape := [3]int{2, 3, 2}
	data := [12]f32{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12}
	grad: [12]f32
	outData, outGrad: [6]f32
	input := Node{value = Tensor{shape[:], data[:]}, grad = Tensor{shape[:], grad[:]}}
	for axis in 0..<3 {
		for keep in 0..<2 {
			outShape: [3]int
			rank, count := 0, 1
			for dim, i in shape {
				if i == axis {
					if keep == 1 { outShape[rank] = 1; rank += 1 }
				} else { outShape[rank] = dim; rank += 1; count *= dim }
			}
			for i in 0..<12 { grad[i] = 0 }
			for i in 0..<count { outGrad[i] = f32(i) - 2 }
			out := Node{value = Tensor{outShape[:rank], outData[:count]}, grad = Tensor{outShape[:rank], outGrad[:count]}, op = SumAxisOp{&input, axis, keep == 1}}
			testing.expect(t, Forward(&out) && Backward(&out))
			for i in 0..<12 {
				original := data[i]
				data[i] = original + 0.01
				testing.expect(t, Forward(&out))
				plus: f32
				for j in 0..<count { plus += outData[j] * outGrad[j] }
				data[i] = original - 0.01
				testing.expect(t, Forward(&out))
				minus: f32
				for j in 0..<count { minus += outData[j] * outGrad[j] }
				data[i] = original
				difference := (plus - minus) / 0.02 - grad[i]
				testing.expect(t, difference > -0.01 && difference < 0.01)
			}
		}
	}
}

@(test)
BroadcastAutogradSharedAndEmpty :: proc(t: ^testing.T) {
	shape := [1]int{2}
	data := [2]f32{3, 4}
	grad := [2]f32{5, 6}
	outData: [2]f32
	outGrad := [2]f32{2, -1}
	x := Node{value = Tensor{shape[:], data[:]}, grad = Tensor{shape[:], grad[:]}}
	out := Node{value = Tensor{shape[:], outData[:]}, grad = Tensor{shape[:], outGrad[:]}, op = BroadcastAddOp{&x, &x}}
	testing.expect(t, Forward(&out) && Backward(&out))
	testing.expect(t, outData == [2]f32{6, 8} && grad == [2]f32{9, 4})
	zeroShape := [2]int{0, 2}
	empty := Node{value = Tensor{zeroShape[:], nil}, grad = Tensor{zeroShape[:], nil}}
	emptyOut := Node{value = Tensor{zeroShape[:], nil}, grad = Tensor{zeroShape[:], nil}, op = BroadcastAddOp{&empty, &x}}
	testing.expect(t, Forward(&emptyOut) && Backward(&emptyOut))
	testing.expect(t, grad == [2]f32{9, 4})
	sum := Node{value = Tensor{shape[:], outData[:]}, grad = Tensor{shape[:], outGrad[:]}, op = SumAxisOp{&empty, 0, false}}
	testing.expect(t, Forward(&sum) && Backward(&sum))
	testing.expect(t, outData == [2]f32{})
	oneShape := [1]int{1}
	scalarData := [1]f32{7}
	scalarGrad := [1]f32{3}
	scalar := Node{value = Tensor{nil, scalarData[:]}, grad = Tensor{nil, scalarGrad[:]}}
	singleData := [1]f32{2}
	singleGrad := [1]f32{0}
	single := Node{value = Tensor{oneShape[:], singleData[:]}, grad = Tensor{oneShape[:], singleGrad[:]}}
	scalarOutData: [1]f32
	scalarOutGrad := [1]f32{4}
	scalarOut := Node{value = Tensor{nil, scalarOutData[:]}, grad = Tensor{nil, scalarOutGrad[:]}, op = SumAxisOp{&single, 0, false}}
	testing.expect(t, Forward(&scalarOut) && Backward(&scalarOut) && singleGrad[0] == 4)
	outSingle := Node{value = Tensor{oneShape[:], singleData[:]}, grad = Tensor{oneShape[:], singleGrad[:]}, op = BroadcastAddOp{&scalar, &scalar}}
	testing.expect(t, !Forward(&outSingle) && !Backward(&outSingle))
}

@(test)
BroadcastAutogradValidation :: proc(t: ^testing.T) {
	shape := [1]int{2}
	data := [2]f32{1, 2}
	grad := [2]f32{3, 4}
	otherData := [2]f32{5, 6}
	otherGrad := [2]f32{7, 8}
	outData := [2]f32{9, 10}
	outGrad := [2]f32{11, 12}
	a := Node{value = Tensor{shape[:], data[:]}, grad = Tensor{shape[:], grad[:]}}
	b := Node{value = Tensor{shape[:], otherData[:]}, grad = Tensor{shape[:], otherGrad[:]}}
	out := Node{value = Tensor{shape[:], outData[:]}, grad = Tensor{shape[:], outGrad[:]}, op = BroadcastAddOp{&a, &b}}
	b.grad.data = otherGrad[:1]
	testing.expect(t, !Backward(&out) && grad == [2]f32{3, 4} && otherGrad == [2]f32{7, 8})
	b.grad.data = otherGrad[:]
	b.grad.data = grad[:]
	testing.expect(t, !Backward(&out) && grad == [2]f32{3, 4})
	b.grad.data = otherGrad[:]
	out.value.data = data[:]
	testing.expect(t, !Forward(&out) && data == [2]f32{1, 2})
	out.value.data = outData[:]
	out.op = SumAxisOp{&a, 1, false}
	testing.expect(t, !Forward(&out) && !Backward(&out))
	testing.expect(t, outData == [2]f32{9, 10} && grad == [2]f32{3, 4})
	out.op = BroadcastAddOp{&a, nil}
	testing.expect(t, !Forward(&out) && !Backward(&out))
}

@(test)
BroadcastScalarAndPartialOverlap :: proc(t: ^testing.T) {
	shape := [1]int{3}
	scalarData := [1]f32{2}
	scalarGrad := [1]f32{10}
	data := [3]f32{1, 2, 3}
	grad := [3]f32{1, 1, 1}
	outData: [3]f32
	outGrad := [3]f32{1, -2, 4}
	scalar := Node{value = Tensor{nil, scalarData[:]}, grad = Tensor{nil, scalarGrad[:]}}
	x := Node{value = Tensor{shape[:], data[:]}, grad = Tensor{shape[:], grad[:]}}
	out := Node{value = Tensor{shape[:], outData[:]}, grad = Tensor{shape[:], outGrad[:]}, op = BroadcastAddOp{&scalar, &x}}
	testing.expect(t, Forward(&out) && Backward(&out))
	testing.expect(t, outData == [3]f32{3, 4, 5} && scalarGrad[0] == 13 && grad == [3]f32{2, -1, 5})
	storage := [4]f32{1, 2, 3, 4}
	x.value.data = storage[:3]
	out.value.data = storage[1:]
	testing.expect(t, !Forward(&out) && storage == [4]f32{1, 2, 3, 4})
	out.value.data = outData[:]
	x.grad.data = storage[1:]
	testing.expect(t, !Backward(&out) && storage == [4]f32{1, 2, 3, 4} && scalarGrad[0] == 13)
}

@(test)
SumAxisInvalidBuffersAndEmptyDimensions :: proc(t: ^testing.T) {
	shape := [2]int{2, 2}
	outShape := [1]int{2}
	data := [4]f32{1, 2, 3, 4}
	grad := [4]f32{5, 6, 7, 8}
	outData := [2]f32{9, 10}
	outGrad := [2]f32{11, 12}
	x := Node{value = Tensor{shape[:], data[:]}, grad = Tensor{shape[:], grad[:]}}
	out := Node{value = Tensor{outShape[:], outData[:]}, grad = Tensor{outShape[:], outGrad[:]}, op = SumAxisOp{&x, 0, false}}
	x.grad.data = grad[:3]
	testing.expect(t, !Backward(&out) && grad == [4]f32{5, 6, 7, 8})
	x.grad.data = grad[:]
	out.grad.data = grad[1:3]
	testing.expect(t, !Backward(&out) && grad == [4]f32{5, 6, 7, 8})
	out.grad.data = outGrad[:]
	out.value.data = data[1:3]
	testing.expect(t, !Forward(&out) && data == [4]f32{1, 2, 3, 4})
	out.value.data = outData[:]
	out.op = SumAxisOp{nil, 0, false}
	testing.expect(t, !Forward(&out) && !Backward(&out))
	zeroShape := [3]int{0, max(int), max(int)}
	zeroOutShape := [2]int{0, max(int)}
	empty := Node{value = Tensor{zeroShape[:], nil}, grad = Tensor{zeroShape[:], nil}}
	emptyOut := Node{value = Tensor{zeroOutShape[:], nil}, grad = Tensor{zeroOutShape[:], nil}, op = SumAxisOp{&empty, 1, false}}
	testing.expect(t, Forward(&emptyOut) && Backward(&emptyOut))
}
