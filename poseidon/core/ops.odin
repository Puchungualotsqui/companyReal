package core

import "core:simd"

// Elementwise output may exactly alias an input; partial overlaps are invalid.
Add :: proc(output, a, b: Tensor) -> bool {
	if !TensorValid(output) || !TensorValid(a) || !TensorValid(b) || !SameShape(output, a) || !SameShape(a, b) {
		return false
	}
	index := 0
	for ; index <= len(output.data)-4; index += 4 {
		left := #simd[4]f32{a.data[index], a.data[index+1], a.data[index+2], a.data[index+3]}
		right := #simd[4]f32{b.data[index], b.data[index+1], b.data[index+2], b.data[index+3]}
		result := left + right
		for lane in 0..<4 { output.data[index+lane] = simd.extract(result, lane) }
	}
	for ; index < len(output.data); index += 1 {
		output.data[index] = a.data[index] + b.data[index]
	}
	return true
}

Multiply :: proc(output, a, b: Tensor) -> bool {
	if !TensorValid(output) || !TensorValid(a) || !TensorValid(b) || !SameShape(output, a) || !SameShape(a, b) {
		return false
	}
	index := 0
	for ; index <= len(output.data)-4; index += 4 {
		left := #simd[4]f32{a.data[index], a.data[index+1], a.data[index+2], a.data[index+3]}
		right := #simd[4]f32{b.data[index], b.data[index+1], b.data[index+2], b.data[index+3]}
		result := left * right
		for lane in 0..<4 { output.data[index+lane] = simd.extract(result, lane) }
	}
	for ; index < len(output.data); index += 1 {
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
		column := 0
		for ; column <= columns-4; column += 4 {
			sum: #simd[4]f32 = 0
			for k in 0..<inner {
				value := a.data[row*inner+k]
				index := k*columns + column
				left := #simd[4]f32{value, value, value, value}
				right := #simd[4]f32{b.data[index], b.data[index+1], b.data[index+2], b.data[index+3]}
				sum += left * right
			}
			for lane in 0..<4 {
				output.data[row*columns+column+lane] = simd.extract(sum, lane)
			}
		}
		for ; column < columns; column += 1 {
			sum: f32 = 0
			for k in 0..<inner {
				sum += a.data[row*inner+k] * b.data[k*columns+column]
			}
			output.data[row*columns+column] = sum
		}
	}
	return true
}
