package data

// SplitIndices fills indices with 0..<len(indices), optionally shuffles them,
// and returns disjoint views into that caller-owned storage. trainCount must be
// in [0, len(indices)]; failure returns nil slices without changing indices.
// The slice length is the dataset size, not its backing capacity. Keep the
// storage alive and unchanged while using the returned views. Equal seeds and
// lengths produce equal permutations; seed 0 is valid. The PRNG is not secure.
// Random row splitting is unsuitable for grouped or time-dependent data.
SplitIndices :: proc(indices: []int, trainCount: int, seed: u64 = 1, shuffle: bool = true) -> (train, validation: []int, ok: bool) {
	if trainCount < 0 || trainCount > len(indices) { return nil, nil, false }
	for i in 0..<len(indices) { indices[i] = i }
	if shuffle {
		state := seed
		for i := len(indices)-1; i > 0; i -= 1 {
			bound := u64(i) + 1
			// Reject the incomplete low interval to avoid modulo bias.
			threshold := (max(u64) - bound + 1) % bound
			value: u64
			for {
				state += 0x9e3779b97f4a7c15
				value = state
				value = (value ~ (value >> 30)) * 0xbf58476d1ce4e5b9
				value = (value ~ (value >> 27)) * 0x94d049bb133111eb
				value = value ~ (value >> 31)
				if value >= threshold { break }
			}
			j := int(value % bound)
			indices[i], indices[j] = indices[j], indices[i]
		}
	}
	return indices[:trainCount], indices[trainCount:], true
}

// GatherRows copies selected fixed-width, row-major rows to output in index
// order and returns the written prefix. width must be positive, source must
// contain whole rows, and output must fit len(indices)*width elements. Indices
// may repeat but must be in range. On failure output is unchanged. Source,
// indices and output must have disjoint backing storage and not be mutated
// concurrently. Use the same indices for each aligned dataset.
GatherRows :: proc(source: []$T, indices: []int, width: int, output: []T) -> (rows: []T, ok: bool) {
	if width <= 0 { return nil, false }
	if len(source) % width != 0 || len(indices) > len(output) / width { return nil, false }
	rowCount := len(source) / width
	for index in indices { if index < 0 || index >= rowCount { return nil, false } }
	for index, i in indices {
		copy(output[i*width:(i+1)*width], source[index*width:(index+1)*width])
	}
	return output[:len(indices)*width], true
}
