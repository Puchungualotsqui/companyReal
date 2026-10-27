package core

// BroadcastValid checks tensor storage and the exact trailing-axis broadcast shape.
BroadcastValid :: proc(output, a, b: Tensor) -> bool {
	if !TensorValid(output) || !TensorValid(a) || !TensorValid(b) {
		return false
	}
	rank := max(len(a.shape), len(b.shape))
	if len(output.shape) != rank {
		return false
	}
	for axis in 0..<rank {
		aAxis := axis - (rank - len(a.shape))
		bAxis := axis - (rank - len(b.shape))
		aDim, bDim := 1, 1
		if aAxis >= 0 { aDim = a.shape[aAxis] }
		if bAxis >= 0 { bDim = b.shape[bAxis] }
		if aDim != bDim && aDim != 1 && bDim != 1 {
			return false
		}
		expected := aDim
		if aDim == 1 { expected = bDim }
		if output.shape[axis] != expected { return false }
	}
	return true
}

// AddBroadcast requires output storage that does not overlap either input.
AddBroadcast :: proc(output, a, b: Tensor) -> bool {
	if !BroadcastValid(output, a, b) || BuffersOverlap(output, a) || BuffersOverlap(output, b) { return false }
	for index in 0..<len(output.data) {
		remaining := index
		aOffset, bOffset := 0, 0
		aStride, bStride := 1, 1
		for axis := len(output.shape) - 1; axis >= 0; axis -= 1 {
			coordinate := remaining % output.shape[axis]
			remaining /= output.shape[axis]
			aAxis := axis - (len(output.shape) - len(a.shape))
			bAxis := axis - (len(output.shape) - len(b.shape))
			if aAxis >= 0 {
				if a.shape[aAxis] != 1 { aOffset += coordinate * aStride }
				aStride *= a.shape[aAxis]
			}
			if bAxis >= 0 {
				if b.shape[bAxis] != 1 { bOffset += coordinate * bStride }
				bStride *= b.shape[bAxis]
			}
		}
		output.data[index] = a.data[aOffset] + b.data[bOffset]
	}
	return true
}
