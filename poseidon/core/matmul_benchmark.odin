package core

import "core:fmt"
import "core:simd"
import "core:testing"
import "core:time"

// Run with -define:POSEIDON_MATMUL_BENCH=true and -define:ODIN_TEST_NAMES=core.MatMulBenchmark.
when #config(POSEIDON_MATMUL_BENCH, false) {
	@(test)
	MatMulBenchmark :: proc(t: ^testing.T) {
		cases := [4]struct{rows, inner, columns, iterations: int}{
			{1, 8, 8, 100_000},
			{1, 64, 64, 10_000},
			{8, 17, 65, 2_000},
			{32, 128, 128, 200},
		}
		aStorage: [4096]f32
		bStorage: [16384]f32
		outputStorage, expectedStorage: [4096]f32
		for &value, index in aStorage { value = f32((index*7)%19-9) / 10 }
		for &value, index in bStorage { value = f32((index*11)%23-11) / 10 }
		checksum: f64
		for item in cases {
			aShape := [2]int{item.rows, item.inner}
			bShape := [2]int{item.inner, item.columns}
			outShape := [2]int{item.rows, item.columns}
			a := Tensor{aShape[:], aStorage[:item.rows*item.inner]}
			b := Tensor{bShape[:], bStorage[:item.inner*item.columns]}
			output := Tensor{outShape[:], outputStorage[:item.rows*item.columns]}
			expected := Tensor{outShape[:], expectedStorage[:item.rows*item.columns]}
			testing.expect(t, MatMulBenchmarkOriginal(expected, a, b) && MatMul(output, a, b))
			for value, index in output.data { testing.expect(t, value == expected.data[index]) }
			for trial in 0..<3 {
				for round in 0..<2 {
					baseline := (trial + round) % 2 == 0
					start := time.tick_now()
					if baseline {
						for iteration in 0..<item.iterations {
							_ = MatMulBenchmarkOriginal(output, a, b)
							checksum += f64(output.data[iteration%len(output.data)])
						}
					} else {
						for iteration in 0..<item.iterations {
							_ = MatMul(output, a, b)
							checksum += f64(output.data[iteration%len(output.data)])
						}
					}
					nanoseconds := f64(i64(time.tick_since(start))) / f64(item.iterations)
					label := "optimized"
					if baseline { label = "original" }
					fmt.printf("MatMul %dx%dx%d %s trial %d: %.1f ns/call\n", item.rows, item.inner, item.columns, label, trial+1, nanoseconds)
				}
			}
		}
		fmt.printf("MatMul benchmark checksum: %v\n", checksum)
	}

	// Frozen copy of MatMul before column blocking, for reproducible comparisons.
	MatMulBenchmarkOriginal :: proc(output, a, b: Tensor) -> bool {
		if !TensorValid(output) || !TensorValid(a) || !TensorValid(b) || len(a.shape) != 2 || len(b.shape) != 2 || len(output.shape) != 2 {
			return false
		}
		rows, inner, columns := a.shape[0], a.shape[1], b.shape[1]
		if b.shape[0] != inner || output.shape[0] != rows || output.shape[1] != columns { return false }
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
				for lane in 0..<4 { output.data[row*columns+column+lane] = simd.extract(sum, lane) }
			}
			for ; column < columns; column += 1 {
				sum: f32 = 0
				for k in 0..<inner { sum += a.data[row*inner+k] * b.data[k*columns+column] }
				output.data[row*columns+column] = sum
			}
		}
		return true
	}
}
