package data

import "core:testing"

@(test)
SplitDeterministicAndPermutation :: proc(t: ^testing.T) {
	a, b, c: [32]int
	train, validation, ok := SplitIndices(a[:], 19)
	_, _, ok2 := SplitIndices(b[:], 19, seed = 1)
	_, _, ok3 := SplitIndices(c[:], 19, seed = 2)
	testing.expect(t, ok && ok2 && ok3 && a == b && a != c)
	testing.expect(t, len(train) == 19 && len(validation) == 13)
	seen: [32]bool
	for index in a {
		testing.expect(t, index >= 0 && index < len(seen))
		if index >= 0 && index < len(seen) {
			testing.expect(t, !seen[index])
			seen[index] = true
		}
	}
	for value in seen { testing.expect(t, value) }
	train[0] = 99
	testing.expect(t, a[0] == 99)
}

@(test)
SplitEdgesAndFailures :: proc(t: ^testing.T) {
	values := [4]int{9, 8, 7, 6}
	for count in ([2]int{-1, 5}) {
		before := values
		train, validation, ok := SplitIndices(values[:], count)
		testing.expect(t, !ok && len(train) == 0 && len(validation) == 0 && values == before)
	}
	for count in ([3]int{0, 2, 4}) {
		train, validation, ok := SplitIndices(values[:], count, shuffle = false)
		testing.expect(t, ok && len(train) == count && len(validation) == 4-count && values == [4]int{0, 1, 2, 3})
	}
	train, validation, ok := SplitIndices(nil, 0, seed = 0)
	testing.expect(t, ok && len(train) == 0 && len(validation) == 0)
	one := [1]int{9}
	train, validation, ok = SplitIndices(one[:], 1, seed = 0)
	testing.expect(t, ok && len(train) == 1 && len(validation) == 0 && one[0] == 0)
	zeroA, zeroB: [8]int
	_, _, _ = SplitIndices(zeroA[:], 4, seed = 0)
	_, _, _ = SplitIndices(zeroB[:], 4, seed = 0)
	testing.expect(t, zeroA == zeroB)
}

@(test)
GatherRowsValidAndAtomic :: proc(t: ^testing.T) {
	source := [6]int{10, 11, 20, 21, 30, 31}
	labels := [3]f32{1, 2, 3}
	indices := [3]int{2, 0, 2}
	output := [8]int{-1, -1, -1, -1, -1, -1, -1, -1}
	labelOutput: [3]f32
	rows, ok := GatherRows(source[:], indices[:], 2, output[:])
	gatheredLabels, labelsOk := GatherRows(labels[:], indices[:], 1, labelOutput[:])
	testing.expect(t, ok && len(rows) == 6 && output == [8]int{30, 31, 10, 11, 30, 31, -1, -1})
	testing.expect(t, labelsOk && len(gatheredLabels) == 3 && labelOutput == [3]f32{3, 1, 3})
	before := output
	badIndices := [3]int{0, 1, 3}
	_, ok = GatherRows(source[:], badIndices[:], 2, output[:])
	testing.expect(t, !ok && output == before)
	badIndices[2] = -1
	_, ok = GatherRows(source[:], badIndices[:], 2, output[:])
	testing.expect(t, !ok && output == before)
	_, ok = GatherRows(source[:], indices[:], 2, output[:5])
	testing.expect(t, !ok && output == before)
	_, ok = GatherRows(source[:5], indices[:], 2, output[:])
	testing.expect(t, !ok && output == before)
	for width in ([2]int{0, -1}) {
		_, ok = GatherRows(source[:], indices[:], width, output[:])
		testing.expect(t, !ok && output == before)
	}
	rows, ok = GatherRows(source[:], indices[:0], 2, output[:])
	testing.expect(t, ok && len(rows) == 0 && output == before)
}
