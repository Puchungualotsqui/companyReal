package core

// Axes are nonnegative; scalars have no axis to reduce.
// This validates tensors and shapes, but not storage overlap.
SumAxisValid :: proc(output, input: Tensor, axis: int, keepDims: bool = false) -> bool {
	if !TensorValid(output) || !TensorValid(input) || axis < 0 || axis >= len(input.shape) {
		return false
	}
	expectedRank := len(input.shape) - 1
	if keepDims { expectedRank += 1 }
	if len(output.shape) != expectedRank { return false }
	for dimension, index in input.shape {
		if index == axis {
			if keepDims && output.shape[index] != 1 { return false }
		} else {
			outIndex := index
			if !keepDims && index > axis { outIndex -= 1 }
			if output.shape[outIndex] != dimension { return false }
		}
	}
	return true
}

// Output data must be disjoint from input data. Empty sums are zero.
SumAxis :: proc(output, input: Tensor, axis: int, keepDims: bool = false) -> bool {
	if !SumAxisValid(output, input, axis, keepDims) || BuffersOverlap(output, input) { return false }
	if len(output.data) == 0 { return true }
	axisSize := input.shape[axis]
	if axisSize == 0 {
		for index in 0..<len(output.data) { output.data[index] = 0 }
		return true
	}
	inner := 1
	for index in axis+1..<len(input.shape) { inner *= input.shape[index] }
	for index in 0..<len(output.data) {
		base := (index / inner) * axisSize * inner + index % inner
		sum: f32 = 0
		for k in 0..<axisSize { sum += input.data[base + k * inner] }
		output.data[index] = sum
	}
	return true
}
