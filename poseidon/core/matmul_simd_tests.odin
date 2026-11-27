package core

import "core:math"
import "core:testing"

@(test)
MatMulSimdBoundaries :: proc(t: ^testing.T) {
	for rows in 0..=2 {
		for inner in ([3]int{0, 1, 7}) {
			for columns in 0..=35 {
				for offset in 0..<4 {
					aShape := [2]int{rows, inner}
					bShape := [2]int{inner, columns}
					outShape := [2]int{rows, columns}
					aStorage: [14]f32
					bStorage: [249]f32
					outStorage: [74]f32
					a := aStorage[:rows*inner]
					b := bStorage[offset:][:inner*columns]
					outOffset := 3 - offset
					out := outStorage[outOffset:][:rows*columns]
					for &value, index in a { value = f32((index*7)%19-9) / 3 }
					for &value, index in b { value = f32((index*11)%23-11) / 5 }
					for &value in outStorage { value = -391 }
					testing.expect(t, MatMul(Tensor{outShape[:], out}, Tensor{aShape[:], a}, Tensor{bShape[:], b}))
					for row in 0..<rows {
						for column in 0..<columns {
							sum: f32 = 0
							for k in 0..<inner { sum += a[row*inner+k] * b[k*columns+column] }
							testing.expectf(t, transmute(u32)out[row*columns+column] == transmute(u32)sum,
								"rows=%d inner=%d columns=%d offset=%d row=%d column=%d", rows, inner, columns, offset, row, column)
						}
					}
					for value, index in outStorage {
						if index < outOffset || index >= outOffset + len(out) { testing.expect(t, value == -391) }
					}
				}
			}
		}
	}
}

@(test)
MatMulSimdEmpty :: proc(t: ^testing.T) {
	aShape := [2]int{2, 0}
	bShape := [2]int{0, 23}
	outShape := [2]int{2, 23}
	out: [46]f32
	for &value in out { value = 91 }
	a, b, output := Tensor{aShape[:], nil}, Tensor{bShape[:], nil}, Tensor{outShape[:], out[:]}
	testing.expect(t, MatMul(output, a, b))
	for value in out { testing.expect(t, transmute(u32)value == 0) }
	for &value in out { value = 91 }
	testing.expect(t, MatMulParallel(output, a, b, 2))
	for value in out { testing.expect(t, transmute(u32)value == 0) }

	aShape = {0, 4}
	bShape = {4, 23}
	outShape = {0, 23}
	weights: [92]f32
	testing.expect(t, MatMul(Tensor{outShape[:], nil}, Tensor{aShape[:], nil}, Tensor{bShape[:], weights[:]}))
	aShape = {2, 4}
	bShape = {4, 0}
	outShape = {2, 0}
	inputs: [8]f32
	testing.expect(t, MatMul(Tensor{outShape[:], nil}, Tensor{aShape[:], inputs[:]}, Tensor{bShape[:], nil}))
}

@(test)
MatMulSimdSpecialValues :: proc(t: ^testing.T) {
	inf := math.inf_f32(1)
	nan := math.nan_f32()
	negativeZero := transmute(f32)u32(0x8000_0000)
	tiny := transmute(f32)u32(1)
	patterns := [8][4]f32{
		{1e20, 1, -1e20, 1},
		{inf, 0, 0, 0},
		{-inf, 0, 0, 0},
		{inf, -inf, 0, 0},
		{nan, 1, 2, 3},
		{negativeZero, negativeZero, negativeZero, negativeZero},
		{tiny, tiny, -tiny, 0},
		{3, -4, 5, -6},
	}
	aShape := [2]int{4, 4}
	a := [16]f32{1, 1, 1, 1, 0, 1, 1, 1, nan, 1, 1, 1, inf, 1, 1, 1}
	for columns in 16..=23 {
		bShape := [2]int{4, columns}
		outShape := [2]int{4, columns}
		bStorage: [92]f32
		outStorage: [92]f32
		b := bStorage[:4*columns]
		out := outStorage[:4*columns]
		for column in 0..<columns {
			for k in 0..<4 { b[k*columns+column] = patterns[column%len(patterns)][k] }
		}
		testing.expect(t, MatMul(Tensor{outShape[:], out}, Tensor{aShape[:], a[:]}, Tensor{bShape[:], b}))
		for row in 0..<4 {
			for column in 0..<columns {
				sum: f32 = 0
				for k in 0..<4 { sum += a[row*4+k] * b[k*columns+column] }
				actual := out[row*columns+column]
				matches := math.is_nan(actual) if math.is_nan(sum) else transmute(u32)actual == transmute(u32)sum
				testing.expectf(t, matches, "columns=%d row=%d column=%d", columns, row, column)
			}
		}
		// These are sensitive to reordering, infinity handling, and the initial +0.
		testing.expect(t, out[0] == 1 && math.is_inf(out[1], 1) && math.is_inf(out[2], -1))
		testing.expect(t, math.is_nan(out[3]) && math.is_nan(out[4]))
		testing.expect(t, transmute(u32)out[5] == 0 && math.is_nan(out[columns+1]))
		for column in 0..<columns { testing.expect(t, math.is_nan(out[2*columns+column])) }
	}
}

@(test)
MatMulSimdDoesNotFuse :: proc(t: ^testing.T) {
	// The product rounds to 1 before it is added to -1; an FMA gives a nonzero result.
	aShape := [2]int{1, 2}
	bShape := [2]int{2, 23}
	outShape := [2]int{1, 23}
	a := [2]f32{-1, transmute(f32)u32(0x3f80_0001)}
	b: [46]f32
	out: [23]f32
	for column in 0..<23 {
		b[column] = 1
		b[23+column] = transmute(f32)u32(0x3f7f_fffe)
	}
	testing.expect(t, MatMul(Tensor{outShape[:], out[:]}, Tensor{aShape[:], a[:]}, Tensor{bShape[:], b[:]}))
	for value in out { testing.expect(t, transmute(u32)value == 0) }
}

@(test)
MatMulSimdInputAlias :: proc(t: ^testing.T) {
	aShape := [2]int{2, 4}
	bShape := [2]int{4, 23}
	outShape := [2]int{2, 23}
	for offset in 0..=1 {
		storage: [93]f32
		output, expected: [46]f32
		for &value, index in storage { value = f32((index*7)%19-9) / 3 }
		original := storage
		a, b := storage[:8], storage[offset:][:92]
		for row in 0..<2 {
			for column in 0..<23 {
				sum: f32 = 0
				for k in 0..<4 { sum += a[row*4+k] * b[k*23+column] }
				expected[row*23+column] = sum
			}
		}
		aTensor, bTensor := Tensor{aShape[:], a}, Tensor{bShape[:], b}
		outTensor := Tensor{outShape[:], output[:]}
		testing.expect(t, MatMul(outTensor, aTensor, bTensor))
		testing.expect(t, output == expected && storage == original)
		output = {}
		testing.expect(t, MatMulParallel(outTensor, aTensor, bTensor, 2))
		testing.expect(t, output == expected && storage == original)
	}
}
