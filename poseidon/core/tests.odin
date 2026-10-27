package core

import "core:testing"

@(test)
TensorValidation :: proc(t: ^testing.T) {
	shape := [2]int{2, 3}
	data: [6]f32
	testing.expect(t, TensorValid(Tensor{shape[:], data[:]}))
	testing.expect(t, !TensorValid(Tensor{shape[:], data[:5]}))
	badShape := [1]int{-1}
	testing.expect(t, !TensorValid(Tensor{badShape[:], data[:]}))
	scalar: [1]f32
	testing.expect(t, TensorValid(Tensor{nil, scalar[:]}))
}

@(test)
ElementwiseAutograd :: proc(t: ^testing.T) {
	shape := [1]int{2}
	aData := [2]f32{2, 3}
	bData := [2]f32{4, 5}
	productData, outputData: [2]f32
	aGrad, bGrad, productGrad: [2]f32
	outputGrad := [2]f32{1, 1}
	a := Node{value = Tensor{shape[:], aData[:]}, grad = Tensor{shape[:], aGrad[:]}}
	b := Node{value = Tensor{shape[:], bData[:]}, grad = Tensor{shape[:], bGrad[:]}}
	product := Node{value = Tensor{shape[:], productData[:]}, grad = Tensor{shape[:], productGrad[:]}, op = MultiplyOp{&a, &b}}
	output := Node{value = Tensor{shape[:], outputData[:]}, grad = Tensor{shape[:], outputGrad[:]}, op = AddOp{&product, &a}}
	testing.expect(t, Forward(&product) && Forward(&output))
	testing.expect(t, outputData == [2]f32{10, 18})
	testing.expect(t, Backward(&output) && Backward(&product))
	testing.expect(t, aGrad == [2]f32{5, 6})
	testing.expect(t, bGrad == [2]f32{2, 3})
}

@(test)
MatrixAutograd :: proc(t: ^testing.T) {
	aShape := [2]int{2, 3}
	bShape := [2]int{3, 2}
	outShape := [2]int{2, 2}
	aData := [6]f32{1, 2, 3, 4, 5, 6}
	bData := [6]f32{7, 8, 9, 10, 11, 12}
	outData: [4]f32
	aGrad, bGrad: [6]f32
	outGrad := [4]f32{1, 1, 1, 1}
	a := Node{value = Tensor{aShape[:], aData[:]}, grad = Tensor{aShape[:], aGrad[:]}}
	b := Node{value = Tensor{bShape[:], bData[:]}, grad = Tensor{bShape[:], bGrad[:]}}
	output := Node{value = Tensor{outShape[:], outData[:]}, grad = Tensor{outShape[:], outGrad[:]}, op = MatMulOp{&a, &b}}
	testing.expect(t, Forward(&output))
	testing.expect(t, outData == [4]f32{58, 64, 139, 154})
	testing.expect(t, Backward(&output))
	testing.expect(t, aGrad == [6]f32{15, 19, 23, 15, 19, 23})
	testing.expect(t, bGrad == [6]f32{5, 5, 7, 7, 9, 9})
}

@(test)
InvalidShapes :: proc(t: ^testing.T) {
	shape := [1]int{2}
	otherShape := [1]int{1}
	data: [2]f32
	other: [1]f32
	testing.expect(t, !Add(Tensor{shape[:], data[:]}, Tensor{shape[:], data[:]}, Tensor{otherShape[:], other[:]}))
	testing.expect(t, !MatMul(Tensor{shape[:], data[:]}, Tensor{shape[:], data[:]}, Tensor{shape[:], data[:]}))
}

@(test)
TensorEdgeCases :: proc(t: ^testing.T) {
	zeroShape := [3]int{2, 0, 3}
	otherZeroShape := [2]int{0, 6}
	overflowShape := [2]int{max(int), 2}
	negativeShape := [2]int{0, -1}
	scalarData := [1]f32{7}
	zero := Tensor{zeroShape[:], nil}
	testing.expect(t, TensorValid(zero))
	testing.expect(t, !TensorValid(Tensor{zeroShape[:], scalarData[:]}))
	testing.expect(t, !TensorValid(Tensor{overflowShape[:], nil}))
	testing.expect(t, !TensorValid(Tensor{negativeShape[:], nil}))
	testing.expect(t, !TensorValid(Tensor{nil, nil}))
	testing.expect(t, SameShape(zero, Tensor{zeroShape[:], nil}))
	testing.expect(t, !SameShape(zero, Tensor{otherZeroShape[:], nil}))
	testing.expect(t, !SameShape(Tensor{nil, scalarData[:]}, Tensor{zeroShape[:], nil}))
}

@(test)
ElementwiseOperations :: proc(t: ^testing.T) {
	shape := [1]int{3}
	otherShape := [2]int{1, 3}
	aData := [3]f32{2, -3, 0}
	bData := [3]f32{4, 5, -2}
	outData := [3]f32{9, 9, 9}
	a := Tensor{shape[:], aData[:]}
	b := Tensor{shape[:], bData[:]}
	output := Tensor{shape[:], outData[:]}
	testing.expect(t, Add(output, a, b))
	testing.expect(t, outData == [3]f32{6, 2, -2})
	testing.expect(t, Multiply(output, a, b))
	testing.expect(t, outData == [3]f32{8, -15, 0})
	testing.expect(t, Add(a, a, b))
	testing.expect(t, aData == [3]f32{6, 2, -2})
	testing.expect(t, Multiply(b, a, b))
	testing.expect(t, bData == [3]f32{24, 10, 4})
	testing.expect(t, !Add(output, a, Tensor{otherShape[:], bData[:]}))
	testing.expect(t, !Multiply(output, Tensor{shape[:], aData[:2]}, b))
	testing.expect(t, outData == [3]f32{8, -15, 0})

	scalarA := [1]f32{3}
	scalarB := [1]f32{-2}
	scalarOut: [1]f32
	testing.expect(t, Multiply(Tensor{nil, scalarOut[:]}, Tensor{nil, scalarA[:]}, Tensor{nil, scalarB[:]}))
	testing.expect(t, scalarOut == [1]f32{-6})
	zeroShape := [1]int{0}
	zero := Tensor{zeroShape[:], nil}
	testing.expect(t, Add(zero, zero, zero) && Multiply(zero, zero, zero))
}

@(test)
MatrixEdgeCases :: proc(t: ^testing.T) {
	aShape := [2]int{2, 0}
	bShape := [2]int{0, 3}
	outShape := [2]int{2, 3}
	outData := [6]f32{1, 1, 1, 1, 1, 1}
	a := Tensor{aShape[:], nil}
	b := Tensor{bShape[:], nil}
	output := Tensor{outShape[:], outData[:]}
	testing.expect(t, MatMul(output, a, b))
	testing.expect(t, outData == [6]f32{})
	badInnerShape := [2]int{1, 3}
	badInnerData: [3]f32
	badOutShape := [2]int{3, 2}
	testing.expect(t, !MatMul(output, a, Tensor{badInnerShape[:], badInnerData[:]}))
	testing.expect(t, !MatMul(Tensor{badOutShape[:], outData[:]}, a, b))
}

@(test)
SharedNodeAutograd :: proc(t: ^testing.T) {
	shape := [1]int{2}
	xData := [2]f32{2, -3}
	xGrad := [2]f32{10, 20}
	squareData, squareGrad, sumData: [2]f32
	sumGrad := [2]f32{2, -1}
	x := Node{value = Tensor{shape[:], xData[:]}, grad = Tensor{shape[:], xGrad[:]}}
	square := Node{value = Tensor{shape[:], squareData[:]}, grad = Tensor{shape[:], squareGrad[:]}, op = MultiplyOp{&x, &x}}
	sum := Node{value = Tensor{shape[:], sumData[:]}, grad = Tensor{shape[:], sumGrad[:]}, op = AddOp{&square, &square}}
	testing.expect(t, Forward(&x) && Forward(&square) && Forward(&sum))
	testing.expect(t, sumData == [2]f32{8, 18})
	testing.expect(t, Backward(&sum) && Backward(&square) && Backward(&x))
	testing.expect(t, squareGrad == [2]f32{4, -2})
	testing.expect(t, xGrad == [2]f32{26, 32})
}

@(test)
MatrixAutogradSeeded :: proc(t: ^testing.T) {
	aShape := [2]int{2, 2}
	bShape := [2]int{2, 1}
	outShape := [2]int{2, 1}
	aData := [4]f32{1, 2, 3, 4}
	bData := [2]f32{5, 6}
	outData: [2]f32
	aGrad := [4]f32{1, 1, 1, 1}
	bGrad := [2]f32{2, 2}
	outGrad := [2]f32{2, -1}
	a := Node{value = Tensor{aShape[:], aData[:]}, grad = Tensor{aShape[:], aGrad[:]}}
	b := Node{value = Tensor{bShape[:], bData[:]}, grad = Tensor{bShape[:], bGrad[:]}}
	output := Node{value = Tensor{outShape[:], outData[:]}, grad = Tensor{outShape[:], outGrad[:]}, op = MatMulOp{&a, &b}}
	testing.expect(t, Forward(&output) && Backward(&output))
	testing.expect(t, outData == [2]f32{17, 39})
	testing.expect(t, aGrad == [4]f32{11, 13, -4, -5})
	testing.expect(t, bGrad == [2]f32{1, 2})
}

@(test)
InvalidAutograd :: proc(t: ^testing.T) {
	shape := [1]int{2}
	otherShape := [2]int{1, 2}
	data, grad: [2]f32
	valid := Node{value = Tensor{shape[:], data[:]}, grad = Tensor{shape[:], grad[:]}}
	invalidGrad := Node{value = Tensor{shape[:], data[:]}, grad = Tensor{otherShape[:], grad[:]}}
	invalidValue := Node{value = Tensor{shape[:], data[:1]}, grad = Tensor{shape[:], grad[:]}}
	testing.expect(t, !Forward(nil) && !Backward(nil))
	testing.expect(t, !Forward(&invalidValue) && !Backward(&invalidValue))
	testing.expect(t, Forward(&invalidGrad) && !Backward(&invalidGrad))

	outputData, outputGrad: [2]f32
	output := Node{value = Tensor{shape[:], outputData[:]}, grad = Tensor{shape[:], outputGrad[:]}}
	output.op = AddOp{&valid, nil}
	testing.expect(t, !Forward(&output) && !Backward(&output))
	output.op = MultiplyOp{nil, &valid}
	testing.expect(t, !Forward(&output) && !Backward(&output))
	output.op = MatMulOp{&valid, nil}
	testing.expect(t, !Forward(&output) && !Backward(&output))
	output.op = AddOp{&valid, &invalidGrad}
	testing.expect(t, Forward(&output) && !Backward(&output))
	output.op = MultiplyOp{&valid, &invalidGrad}
	testing.expect(t, Forward(&output) && !Backward(&output))
	output.op = MatMulOp{&valid, &valid}
	testing.expect(t, !Forward(&output) && !Backward(&output))
	testing.expect(t, grad == [2]f32{})
}
