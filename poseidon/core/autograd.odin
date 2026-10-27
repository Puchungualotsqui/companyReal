package core

AddOp :: struct { a, b: ^Node }
MultiplyOp :: struct { a, b: ^Node }
MatMulOp :: struct { a, b: ^Node }
BroadcastAddOp :: struct { a, b: ^Node }
SumAxisOp :: struct { input: ^Node, axis: int, keepDims: bool }
Operation :: union { AddOp, MultiplyOp, MatMulOp, BroadcastAddOp, SumAxisOp }

// Nodes and their value and gradient storage are owned by the caller.
// A nil operation denotes a leaf. All value and gradient buffers must be disjoint.
Node :: struct {
	value: Tensor,
	grad: Tensor,
	op: Operation,
}

// Forward evaluates one node after its inputs have been evaluated.
Forward :: proc(node: ^Node) -> bool {
	if node == nil {
		return false
	}
	switch op in node.op {
	case nil:
		return TensorValid(node.value)
	case AddOp:
		if op.a == nil || op.b == nil { return false }
		return Add(node.value, op.a.value, op.b.value)
	case MultiplyOp:
		if op.a == nil || op.b == nil { return false }
		return Multiply(node.value, op.a.value, op.b.value)
	case MatMulOp:
		if op.a == nil || op.b == nil { return false }
		return MatMul(node.value, op.a.value, op.b.value)
	case BroadcastAddOp:
		if op.a == nil || op.b == nil || node == op.a || node == op.b { return false }
		if !BroadcastValid(node.value, op.a.value, op.b.value) ||
			BuffersOverlap(node.value, op.a.value) || BuffersOverlap(node.value, op.b.value) ||
			(op.a != op.b && BuffersOverlap(op.a.value, op.b.value)) { return false }
		return AddBroadcast(node.value, op.a.value, op.b.value)
	case SumAxisOp:
		if op.input == nil || node == op.input || !SumAxisValid(node.value, op.input.value, op.axis, op.keepDims) ||
			BuffersOverlap(node.value, op.input.value) { return false }
		return SumAxis(node.value, op.input.value, op.axis, op.keepDims)
	}
	return false
}

// Backward accumulates gradients for one node. Seed the output gradient first
// and visit nodes in reverse topological order, once per node.
Backward :: proc(node: ^Node) -> bool {
	if node == nil || !TensorValid(node.value) || !TensorValid(node.grad) || !SameShape(node.value, node.grad) {
		return false
	}
	switch op in node.op {
	case nil:
		return true
	case AddOp:
		if !ElementwiseGradValid(node, op.a, op.b) { return false }
		for index in 0..<len(node.grad.data) {
			op.a.grad.data[index] += node.grad.data[index]
			op.b.grad.data[index] += node.grad.data[index]
		}
	case MultiplyOp:
		if !ElementwiseGradValid(node, op.a, op.b) { return false }
		for index in 0..<len(node.grad.data) {
			gradient := node.grad.data[index]
			op.a.grad.data[index] += gradient * op.b.value.data[index]
			op.b.grad.data[index] += gradient * op.a.value.data[index]
		}
	case MatMulOp:
		if !InputsGradValid(op.a, op.b) || len(node.value.shape) != 2 || len(op.a.value.shape) != 2 || len(op.b.value.shape) != 2 { return false }
		rows, inner, columns := op.a.value.shape[0], op.a.value.shape[1], op.b.value.shape[1]
		if op.b.value.shape[0] != inner || node.value.shape[0] != rows || node.value.shape[1] != columns { return false }
		for row in 0..<rows {
			for column in 0..<columns {
				gradient := node.grad.data[row*columns+column]
				for k in 0..<inner {
					op.a.grad.data[row*inner+k] += gradient * op.b.value.data[k*columns+column]
					op.b.grad.data[k*columns+column] += gradient * op.a.value.data[row*inner+k]
				}
			}
		}
	case BroadcastAddOp:
		if !InputsGradValid(op.a, op.b) || node == op.a || node == op.b ||
			!BroadcastValid(node.value, op.a.value, op.b.value) ||
			!AutogradBuffersDisjoint(node, op.a, op.b) { return false }
		for index in 0..<len(node.grad.data) {
			remaining := index
			aOffset, bOffset := 0, 0
			aStride, bStride := 1, 1
			for axis := len(node.value.shape) - 1; axis >= 0; axis -= 1 {
				coordinate := remaining % node.value.shape[axis]
				remaining /= node.value.shape[axis]
				aAxis := axis - (len(node.value.shape) - len(op.a.value.shape))
				bAxis := axis - (len(node.value.shape) - len(op.b.value.shape))
				if aAxis >= 0 {
					if op.a.value.shape[aAxis] != 1 { aOffset += coordinate * aStride }
					aStride *= op.a.value.shape[aAxis]
				}
				if bAxis >= 0 {
					if op.b.value.shape[bAxis] != 1 { bOffset += coordinate * bStride }
					bStride *= op.b.value.shape[bAxis]
				}
			}
			gradient := node.grad.data[index]
			op.a.grad.data[aOffset] += gradient
			op.b.grad.data[bOffset] += gradient
		}
	case SumAxisOp:
		if op.input == nil || node == op.input || !TensorValid(op.input.value) ||
			!TensorValid(op.input.grad) || !SameShape(op.input.value, op.input.grad) ||
			!SumAxisValid(node.value, op.input.value, op.axis, op.keepDims) ||
			!AutogradBuffersDisjoint(node, op.input, op.input) { return false }
		if len(op.input.grad.data) == 0 { return true }
		inner := 1
		for axis in op.axis+1..<len(op.input.value.shape) { inner *= op.input.value.shape[axis] }
		axisSize := op.input.value.shape[op.axis]
		for index in 0..<len(op.input.grad.data) {
			outIndex := (index / (axisSize * inner)) * inner + index % inner
			op.input.grad.data[index] += node.grad.data[outIndex]
		}
	}
	return true
}

// Empty slices never overlap. Subtraction avoids overflowing address arithmetic.
BuffersOverlap :: proc(a, b: Tensor) -> bool {
	if len(a.data) == 0 || len(b.data) == 0 { return false }
	aAddress, bAddress := uintptr(raw_data(a.data)), uintptr(raw_data(b.data))
	if aAddress >= bAddress { return (aAddress - bAddress) / size_of(f32) < uintptr(len(b.data)) }
	return (bAddress - aAddress) / size_of(f32) < uintptr(len(a.data))
}

AutogradBuffersDisjoint :: proc(output, a, b: ^Node) -> bool {
	nodes := [3]^Node{output, a, b}
	for i in 0..<len(nodes) {
		if i == 2 && b == a { continue }
		if BuffersOverlap(nodes[i].value, nodes[i].grad) { return false }
		for j in 0..<i {
			if BuffersOverlap(nodes[i].value, nodes[j].value) ||
				BuffersOverlap(nodes[i].value, nodes[j].grad) ||
				BuffersOverlap(nodes[i].grad, nodes[j].value) ||
				BuffersOverlap(nodes[i].grad, nodes[j].grad) { return false }
		}
	}
	return true
}

InputsGradValid :: proc(a, b: ^Node) -> bool {
	if a == nil || b == nil { return false }
	return TensorValid(a.value) && TensorValid(a.grad) && SameShape(a.value, a.grad) &&
		TensorValid(b.value) && TensorValid(b.grad) && SameShape(b.value, b.grad)
}

ElementwiseGradValid :: proc(node, a, b: ^Node) -> bool {
	return InputsGradValid(a, b) && SameShape(node.value, a.value) && SameShape(a.value, b.value)
}



// GraphFrame is scratch storage for GraphBuild. Its initial contents are ignored.
GraphFrame :: struct {
	node: ^Node,
	next: int,
}

// GraphBuild constructs an input-before-output order without evaluating nodes.
// order must have room for every distinct node and stack for the maximum DFS
// depth. On success, nodes aliases order; on failure, nodes is nil. Scratch may
// be modified even on failure. The caller owns all nodes and workspace, which
// must remain valid and must not overlap. The graph must not change during the
// build or between building and evaluation. Reusing order invalidates prior
// results, even if the next build fails. Scans take O(V^2) time.
GraphBuild :: proc(output: ^Node, order: []^Node, stack: []GraphFrame) -> (nodes: []^Node, ok: bool) {
	if output == nil || len(stack) == 0 { return nil, false }
	count, depth := 0, 1
	stack[0] = GraphFrame{output, 0}
	for depth > 0 {
		frame := &stack[depth-1]
		inputs: [2]^Node
		inputCount := 0
		switch op in frame.node.op {
		case nil:
		case AddOp:
			inputs = {op.a, op.b}
			inputCount = 2
		case MultiplyOp:
			inputs = {op.a, op.b}
			inputCount = 2
		case MatMulOp:
			inputs = {op.a, op.b}
			inputCount = 2
		case BroadcastAddOp:
			inputs = {op.a, op.b}
			inputCount = 2
		case SumAxisOp:
			inputs[0] = op.input
			inputCount = 1
		}
		if frame.next < inputCount {
			input := inputs[frame.next]
			frame.next += 1
			if input == nil { return nil, false }
			for i in 0..<depth {
				if stack[i].node == input { return nil, false }
			}
			visited := false
			for i in 0..<count {
				if order[i] == input {
					visited = true
					break
				}
			}
			if visited { continue }
			if depth == len(stack) { return nil, false }
			stack[depth] = GraphFrame{input, 0}
			depth += 1
		} else {
			if count == len(order) { return nil, false }
			order[count] = frame.node
			count += 1
			depth -= 1
		}
	}
	return order[:count], true
}

// GraphForward evaluates a successful GraphBuild order. The graph and order
// must remain unchanged since the build; arbitrary lists are not validated.
// Graph-wide buffers must be disjoint; concurrent mutation is unsupported.
// Failure may leave earlier nodes evaluated.
GraphForward :: proc(nodes: []^Node) -> bool {
	for node in nodes {
		if !Forward(node) { return false }
	}
	return true
}

// GraphBackward traverses a successful GraphBuild order in reverse. The graph
// and order must remain unchanged since the build; arbitrary lists are not
// validated. Values must match the forward pass and remain unchanged.
// Seed outputs and clear intermediate gradients before each independent pass;
// retain leaf gradients only when accumulation is intended. Failure may leave
// gradients partially accumulated.
GraphBackward :: proc(nodes: []^Node) -> bool {
	for i := len(nodes) - 1; i >= 0; i -= 1 {
		if !Backward(nodes[i]) { return false }
	}
	return true
}

