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

@(test)
GraphDiamondManualAndRepeat :: proc(t: ^testing.T) {
	shape := [1]int{2}
	xData := [2]f32{2, 3}
	xGrad, sharedData, sharedGrad, leftData, leftGrad, rightData, rightGrad, outData: [2]f32
	outGrad := [2]f32{1, 2}
	x := Node{value = Tensor{shape[:], xData[:]}, grad = Tensor{shape[:], xGrad[:]}}
	shared := Node{value = Tensor{shape[:], sharedData[:]}, grad = Tensor{shape[:], sharedGrad[:]}, op = MultiplyOp{&x, &x}}
	left := Node{value = Tensor{shape[:], leftData[:]}, grad = Tensor{shape[:], leftGrad[:]}, op = AddOp{&shared, &x}}
	right := Node{value = Tensor{shape[:], rightData[:]}, grad = Tensor{shape[:], rightGrad[:]}, op = MultiplyOp{&shared, &x}}
	out := Node{value = Tensor{shape[:], outData[:]}, grad = Tensor{shape[:], outGrad[:]}, op = AddOp{&left, &right}}
	order: [5]^Node
	stack: [5]GraphFrame
	nodes, ok := GraphBuild(&out, order[:], stack[:])
	testing.expect(t, ok && len(nodes) == 5)
	if !ok || len(nodes) != 5 { return }
	testing.expect(t, nodes[0] == &x && nodes[1] == &shared && nodes[2] == &left && nodes[3] == &right && nodes[4] == &out)
	testing.expect(t, GraphForward(nodes) && GraphBackward(nodes))
	testing.expect(t, outData == [2]f32{14, 39} && xGrad == [2]f32{17, 68})
	scheduledOut, scheduledX, scheduledShared, scheduledLeft, scheduledRight := outData, xGrad, sharedGrad, leftGrad, rightGrad
	// Both leaf and intermediate gradients must be cleared before another pass.
	xGrad = {}; sharedGrad = {}; leftGrad = {}; rightGrad = {}
	testing.expect(t, Forward(&x) && Forward(&shared) && Forward(&left) && Forward(&right) && Forward(&out))
	testing.expect(t, Backward(&out) && Backward(&right) && Backward(&left) && Backward(&shared) && Backward(&x))
	testing.expect(t, outData == scheduledOut && xGrad == scheduledX && sharedGrad == scheduledShared && leftGrad == scheduledLeft && rightGrad == scheduledRight)
	xGrad = {}; sharedGrad = {}; leftGrad = {}; rightGrad = {}
	testing.expect(t, GraphForward(nodes) && GraphBackward(nodes))
	testing.expect(t, xGrad == scheduledX && sharedGrad == scheduledShared && leftGrad == scheduledLeft && rightGrad == scheduledRight)
}

@(test)
GraphAllOperations :: proc(t: ^testing.T) {
	matrixShape := [2]int{2, 2}
	biasShape := [1]int{2}
	aData := [4]f32{1, 2, 3, 4}
	bData := [4]f32{1, 0, 0, 1}
	biasData := [2]f32{10, 20}
	aGrad, bGrad, productData, productGrad, broadcastData, broadcastGrad: [4]f32
	biasGrad, sumData: [2]f32
	sumGrad := [2]f32{1, 2}
	a := Node{value = Tensor{matrixShape[:], aData[:]}, grad = Tensor{matrixShape[:], aGrad[:]}}
	b := Node{value = Tensor{matrixShape[:], bData[:]}, grad = Tensor{matrixShape[:], bGrad[:]}}
	bias := Node{value = Tensor{biasShape[:], biasData[:]}, grad = Tensor{biasShape[:], biasGrad[:]}}
	product := Node{value = Tensor{matrixShape[:], productData[:]}, grad = Tensor{matrixShape[:], productGrad[:]}, op = MatMulOp{&a, &b}}
	broadcast := Node{value = Tensor{matrixShape[:], broadcastData[:]}, grad = Tensor{matrixShape[:], broadcastGrad[:]}, op = BroadcastAddOp{&product, &bias}}
	sum := Node{value = Tensor{biasShape[:], sumData[:]}, grad = Tensor{biasShape[:], sumGrad[:]}, op = SumAxisOp{&broadcast, 0, false}}
	order: [6]^Node
	stack: [6]GraphFrame
	nodes, ok := GraphBuild(&sum, order[:], stack[:])
	testing.expect(t, ok && len(nodes) == 6)
	if !ok || len(nodes) != 6 { return }
	testing.expect(t, nodes[0] == &a && nodes[1] == &b && nodes[2] == &product && nodes[3] == &bias && nodes[4] == &broadcast && nodes[5] == &sum)
	testing.expect(t, GraphForward(nodes) && GraphBackward(nodes))
	testing.expect(t, sumData == [2]f32{24, 46} && aGrad == [4]f32{1, 2, 1, 2})
	testing.expect(t, bGrad == [4]f32{4, 8, 6, 12} && biasGrad == [2]f32{2, 4})
}

@(test)
GraphWorkspaceAndInvalidInputs :: proc(t: ^testing.T) {
	a, b, c, root: Node
	root.op = AddOp{&a, &b}
	order: [4]^Node
	stack: [4]GraphFrame
	nodes, ok := GraphBuild(nil, order[:], stack[:])
	testing.expect(t, !ok && nodes == nil)
	for workspace in 0..<4 {
		orderLen, stackLen := 3, 2
		if workspace == 0 { orderLen = 0 }
		if workspace == 1 { orderLen = 2 }
		if workspace == 2 { stackLen = 0 }
		if workspace == 3 { stackLen = 1 }
		nodes, ok = GraphBuild(&root, order[:orderLen], stack[:stackLen])
		testing.expect(t, !ok && nodes == nil)
	}
	nodes, ok = GraphBuild(&root, order[:3], stack[:2])
	testing.expect(t, ok && len(nodes) == 3)
	invalid := [9]Operation{AddOp{nil, &a}, AddOp{&a, nil}, MultiplyOp{nil, &a}, MultiplyOp{&a, nil}, MatMulOp{nil, &a}, MatMulOp{&a, nil}, BroadcastAddOp{nil, &a}, BroadcastAddOp{&a, nil}, SumAxisOp{input = nil}}
	for op in invalid {
		root.op = op
		nodes, ok = GraphBuild(&root, order[:], stack[:])
		testing.expect(t, !ok && nodes == nil)
	}
	root.op = SumAxisOp{input = &root}
	nodes, ok = GraphBuild(&root, order[:], stack[:])
	testing.expect(t, !ok && nodes == nil)
	root.op = AddOp{&a, &b}
	b.op = SumAxisOp{input = &c}
	c.op = MultiplyOp{&a, &root}
	nodes, ok = GraphBuild(&root, order[:], stack[:])
	testing.expect(t, !ok && nodes == nil)
}

@(test)
GraphEmptyOutputAndRebuild :: proc(t: ^testing.T) {
	shape := [2]int{0, 2}
	x := Node{value = Tensor{shape[:], nil}, grad = Tensor{shape[:], nil}}
	y := Node{value = Tensor{shape[:], nil}, grad = Tensor{shape[:], nil}}
	out := Node{value = Tensor{shape[:], nil}, grad = Tensor{shape[:], nil}, op = AddOp{&x, &x}}
	order: [3]^Node
	stack: [3]GraphFrame
	nodes, ok := GraphBuild(&out, order[:], stack[:])
	testing.expect(t, ok && len(nodes) == 2)
	if !ok { return }
	testing.expect(t, nodes[0] == &x && nodes[1] == &out && GraphForward(nodes) && GraphBackward(nodes))
	// Changing an operation invalidates the old order; rebuild before evaluation.
	out.op = AddOp{&x, &y}
	nodes, ok = GraphBuild(&out, order[:], stack[:])
	testing.expect(t, ok && len(nodes) == 3)
	if !ok || len(nodes) != 3 { return }
	testing.expect(t, nodes[0] == &x && nodes[1] == &y && nodes[2] == &out)
	testing.expect(t, GraphForward(nodes) && GraphBackward(nodes))
}

@(test)
GraphDeepChain :: proc(t: ^testing.T) {
	DEPTH :: 2048
	shape := [1]int{1}
	data, grads: [DEPTH]f32
	chain: [DEPTH]Node
	order: [DEPTH]^Node
	stack: [DEPTH]GraphFrame
	data[0] = 1
	for i in 0..<DEPTH {
		chain[i] = Node{value = Tensor{shape[:], data[i:i+1]}, grad = Tensor{shape[:], grads[i:i+1]}}
		if i > 0 { chain[i].op = AddOp{&chain[i-1], &chain[0]} }
	}
	nodes, ok := GraphBuild(&chain[DEPTH-1], order[:], stack[:DEPTH-1])
	testing.expect(t, !ok && nodes == nil)
	nodes, ok = GraphBuild(&chain[DEPTH-1], order[:], stack[:])
	testing.expect(t, ok && len(nodes) == DEPTH)
	if !ok || len(nodes) != DEPTH { return }
	for i in 0..<DEPTH { testing.expect(t, nodes[i] == &chain[i]) }
	grads[DEPTH-1] = 1
	testing.expect(t, GraphForward(nodes) && data[DEPTH-1] == DEPTH)
	testing.expect(t, GraphBackward(nodes) && grads[0] == DEPTH)
}

@(test)
GraphSharedAutograd :: proc(t: ^testing.T) {
	shape := [1]int{2}
	xData := [2]f32{2, -3}
	xGrad := [2]f32{10, 20}
	squareData, squareGrad, sumData: [2]f32
	sumGrad := [2]f32{2, -1}
	x := Node{value = Tensor{shape[:], xData[:]}, grad = Tensor{shape[:], xGrad[:]}}
	square := Node{value = Tensor{shape[:], squareData[:]}, grad = Tensor{shape[:], squareGrad[:]}, op = MultiplyOp{&x, &x}}
	sum := Node{value = Tensor{shape[:], sumData[:]}, grad = Tensor{shape[:], sumGrad[:]}, op = AddOp{&square, &square}}
	order: [3]^Node
	stack := [3]GraphFrame{{&sum, 99}, {&x, 99}, {&square, 99}}
	nodes, ok := GraphBuild(&sum, order[:], stack[:])
	testing.expect(t, ok && len(nodes) == 3)
	if !ok { return }
	testing.expect(t, nodes[0] == &x && nodes[1] == &square && nodes[2] == &sum)
	testing.expect(t, GraphForward(nodes) && sumData == [2]f32{8, 18})
	testing.expect(t, GraphBackward(nodes) && xGrad == [2]f32{26, 32})
}

@(test)
GraphBuildFailures :: proc(t: ^testing.T) {
	leaf := Node{}
	other := Node{}
	root := Node{op = AddOp{&leaf, &other}}
	order: [3]^Node
	stack: [3]GraphFrame
	nodes, ok := GraphBuild(nil, order[:], stack[:])
	testing.expect(t, !ok && nodes == nil)
	nodes, ok = GraphBuild(&root, order[:], stack[:0])
	testing.expect(t, !ok && nodes == nil)
	nodes, ok = GraphBuild(&root, order[:2], stack[:])
	testing.expect(t, !ok && nodes == nil)
	nodes, ok = GraphBuild(&root, order[:], stack[:1])
	testing.expect(t, !ok && nodes == nil)
	root.op = AddOp{&leaf, nil}
	nodes, ok = GraphBuild(&root, order[:], stack[:])
	testing.expect(t, !ok && nodes == nil)
	root.op = SumAxisOp{input = &root}
	nodes, ok = GraphBuild(&root, order[:], stack[:])
	testing.expect(t, !ok && nodes == nil)
	root.op = AddOp{&leaf, &other}
	other.op = SumAxisOp{input = &root}
	nodes, ok = GraphBuild(&root, order[:], stack[:])
	testing.expect(t, !ok && nodes == nil)
}
