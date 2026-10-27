package core

import "core:simd"
import "core:thread"

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

MatMulJob :: struct {
	output, a, b: Tensor,
	firstRow, rowCount: int,
	run: bool,
}

MatMulWorker :: proc(worker: ^thread.Thread) {
	job := (^MatMulJob)(worker.data)
	if !job.run { return }
	inner, columns := job.a.shape[1], job.b.shape[1]
	aShape := [2]int{job.rowCount, inner}
	outShape := [2]int{job.rowCount, columns}
	a := Tensor{aShape[:], job.a.data[job.firstRow*inner:][:job.rowCount*inner]}
	output := Tensor{outShape[:], job.output.data[job.firstRow*columns:][:job.rowCount*columns]}
	_ = MatMul(output, a, job.b)
}

// workers includes the calling thread; output must not overlap either input.
// Thread creation failure falls back to serial multiplication.
MatMulParallel :: proc(output, a, b: Tensor, workers: int) -> bool {
	if !TensorValid(output) || !TensorValid(a) || !TensorValid(b) || len(a.shape) != 2 || len(b.shape) != 2 || len(output.shape) != 2 {
		return false
	}
	rows, inner, columns := a.shape[0], a.shape[1], b.shape[1]
	if b.shape[0] != inner || output.shape[0] != rows || output.shape[1] != columns {
		return false
	}
	when !thread.IS_SUPPORTED {
		return MatMul(output, a, b)
	}
	MAX_WORKERS :: 16
	count := min(max(workers, 1), rows, MAX_WORKERS)
	if count <= 1 || columns == 0 {
		return MatMul(output, a, b)
	}
	jobs: [MAX_WORKERS]MatMulJob
	threads: [MAX_WORKERS-1]^thread.Thread
	created := 0
	defer {
		for i in 0..<created { thread.destroy(threads[i]) }
	}
	for i in 0..<count {
		firstRow := i * (rows / count) + min(i, rows % count)
		rowCount := rows / count
		if i < rows % count { rowCount += 1 }
		jobs[i] = MatMulJob{output, a, b, firstRow, rowCount, false}
	}
	for i in 0..<count-1 {
		threads[i] = thread.create(MatMulWorker)
		if threads[i] == nil {
			for j in 0..<created { thread.start(threads[j]) }
			for j in 0..<created { thread.join(threads[j]) }
			for j in 0..<created { thread.destroy(threads[j]) }
			created = 0
			return MatMul(output, a, b)
		}
		threads[i].data = &jobs[i]
		created += 1
	}
	for i in 0..<count { jobs[i].run = true }
	for i in 0..<created { thread.start(threads[i]) }
	// The caller handles the final partition.
	job := &jobs[count-1]
	aShape := [2]int{job.rowCount, inner}
	outShape := [2]int{job.rowCount, columns}
	partA := Tensor{aShape[:], a.data[job.firstRow*inner:][:job.rowCount*inner]}
	partOutput := Tensor{outShape[:], output.data[job.firstRow*columns:][:job.rowCount*columns]}
	_ = MatMul(partOutput, partA, b)
	for i in 0..<created { thread.join(threads[i]) }
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
