package core

// Elementwise output may exactly alias an input; partial overlaps are invalid.
Add :: proc(output, a, b: Tensor) -> bool {
	if !TensorValid(output) || !TensorValid(a) || !TensorValid(b) || !SameShape(output, a) || !SameShape(a, b) {
		return false
	}
	for index in 0..<len(output.data) {
		output.data[index] = a.data[index] + b.data[index]
	}
	return true
}

Multiply :: proc(output, a, b: Tensor) -> bool {
	if !TensorValid(output) || !TensorValid(a) || !TensorValid(b) || !SameShape(output, a) || !SameShape(a, b) {
		return false
	}
	for index in 0..<len(output.data) {
		output.data[index] = a.data[index] * b.data[index]
	}
	return true
}

// MatMul requires output storage that does not overlap either input.
MatMul :: proc(output, a, b: Tensor) -> bool {
	if !TensorValid(output) || !TensorValid(a) || !TensorValid(b) || len(a.shape) != 2 || len(b.shape) != 2 || len(output.shape) != 2 {
		return false
	}
	rows, inner, columns := a.shape[0], a.shape[1], b.shape[1]
	if b.shape[0] != inner || output.shape[0] != rows || output.shape[1] != columns {
		return false
	}
	for row in 0..<rows {
		for column in 0..<columns {
			sum: f32 = 0
			for k in 0..<inner {
				sum += a.data[row*inner+k] * b.data[k*columns+column]
			}
			output.data[row*columns+column] = sum
		}
	}
	return true
}
