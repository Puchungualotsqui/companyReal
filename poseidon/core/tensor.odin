package core

// Tensor borrows its shape and row-major data; the caller owns both slices.
Tensor :: struct {
	shape: []int,
	data:  []f32,
}

// A scalar has an empty shape and one element. Zero-sized dimensions are valid.
TensorValid :: proc(tensor: Tensor) -> bool {
	count := 1
	for dimension in tensor.shape {
		if dimension < 0 {
			return false
		}
		if dimension != 0 && count > max(int) / dimension {
			return false
		}
		count *= dimension
	}
	return count == len(tensor.data)
}

SameShape :: proc(a, b: Tensor) -> bool {
	if len(a.shape) != len(b.shape) {
		return false
	}
	for dimension, index in a.shape {
		if dimension != b.shape[index] {
			return false
		}
	}
	return true
}
