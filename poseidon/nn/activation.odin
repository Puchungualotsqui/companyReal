package nn

import "../core"
import "core:math"
import "core:thread"

Relu :: struct {
	input: ^core.Node,
	output: ^core.Node,
}

Sigmoid :: struct {
	input: ^core.Node,
	output: ^core.Node,
}

Tanh :: struct {
	input: ^core.Node,
	output: ^core.Node,
}

Softmax :: struct {
	input: ^core.Node,
	output: ^core.Node,
}

// All buffers, including mask, must be caller-owned and non-overlapping.
// A nonzero RNG state and a mask exactly matching the tensor size are required
// even in inference. Empty tensors succeed without advancing the RNG. Backward
// in training requires a preceding training forward with the same rate and mask;
// inference backward is identity. Changing mode between passes is unsupported.
Dropout :: struct {
	input, output: ^core.Node,
	mask: []f32,
	rate: f32,
	randomState: ^u64,
	training: bool,
}

DropoutValid :: proc(layer: ^Dropout, gradients: bool) -> bool {
	if layer == nil || layer.randomState == nil || layer.randomState^ == 0 ||
		math.is_nan(layer.rate) || math.is_inf(layer.rate) || layer.rate < 0 || layer.rate >= 1 ||
		!ActivationValid(layer.input, layer.output, gradients) {
		return false
	}
	return len(layer.mask) == len(layer.input.value.data)
}

DropoutNext :: proc(state: ^u64, rate: f32, scale: f32) -> f32 {
	state^ ~= state^ << 13
	state^ ~= state^ >> 7
	state^ ~= state^ << 17
	if f32(u32(state^ >> 40)) / f32(1 << 24) < rate { return 0 }
	return scale
}

// Validation and a dry run precede all writes, including RNG and mask updates.
DropoutForward :: proc(layer: ^Dropout) -> bool {
	if !DropoutValid(layer, false) { return false }
	scale: f32 = 1
	if layer.training { scale = 1 / (1 - layer.rate) }
	state := layer.randomState^
	for item in layer.input.value.data {
		if math.is_nan(item) || math.is_inf(item) { return false }
		multiplier: f32 = 1
		if layer.training { multiplier = DropoutNext(&state, layer.rate, scale) }
		result := item * multiplier
		if math.is_nan(result) || math.is_inf(result) { return false }
	}
	state = layer.randomState^
	for item, index in layer.input.value.data {
		multiplier: f32 = 1
		if layer.training { multiplier = DropoutNext(&state, layer.rate, scale) }
		layer.mask[index] = multiplier
		layer.output.value.data[index] = item * multiplier
	}
	layer.randomState^ = state
	return true
}

// Accumulates into input.grad; invalid or non-finite results leave it unchanged.
DropoutBackward :: proc(layer: ^Dropout) -> bool {
	if !DropoutValid(layer, true) { return false }
	for item, index in layer.output.grad.data {
		multiplier: f32 = 1
		if layer.training { multiplier = layer.mask[index] }
		previous := layer.input.grad.data[index]
		if math.is_nan(item) || math.is_inf(item) || math.is_nan(previous) || math.is_inf(previous) ||
			math.is_nan(multiplier) || math.is_inf(multiplier) { return false }
		result := previous + item * multiplier
		if math.is_nan(result) || math.is_inf(result) { return false }
	}
	for item, index in layer.output.grad.data {
		multiplier: f32 = 1
		if layer.training { multiplier = layer.mask[index] }
		layer.input.grad.data[index] += item * multiplier
	}
	return true
}

ActivationKind :: enum { Relu, Sigmoid, Tanh, Softmax }

ActivationValid :: proc(input, output: ^core.Node, gradients: bool) -> bool {
	if input == nil || output == nil || !core.TensorValid(input.value) ||
		!core.TensorValid(output.value) || !core.SameShape(input.value, output.value) {
		return false
	}
	if gradients {
		for node in ([2]^core.Node{input, output}) {
			if !core.TensorValid(node.grad) || !core.SameShape(node.value, node.grad) {
				return false
			}
		}
	}
	return true
}

// Buffers must not overlap; workers includes the caller and is capped at 16.
// Buffers and metadata must remain unchanged until the call returns.
SoftmaxForward :: proc(input, output: ^core.Node, workers := 1) -> bool {
	if !ActivationValid(input, output, false) || len(input.value.shape) == 0 { return false }
	width := input.value.shape[len(input.value.shape)-1]
	if width == 0 { return false }
	for item in input.value.data {
		if math.is_nan(item) || math.is_inf(item) { return false }
	}
	SoftmaxExecute(input, output, width, workers, false)
	return true
}

// Accumulates into input.grad; buffers and metadata follow the forward contract.
SoftmaxBackward :: proc(input, output: ^core.Node, workers := 1) -> bool {
	if !ActivationValid(input, output, true) || len(input.value.shape) == 0 { return false }
	width := input.value.shape[len(input.value.shape)-1]
	if width == 0 { return false }
	for item in input.value.data {
		if math.is_nan(item) || math.is_inf(item) { return false }
	}
	SoftmaxExecute(input, output, width, workers, true)
	return true
}

SoftmaxJob :: struct {
	input, output: ^core.Node,
	width, firstRow, rowCount: int,
	backward, run: bool,
}

SoftmaxRows :: proc(job: ^SoftmaxJob) {
	for row in job.firstRow..<job.firstRow+job.rowCount {
		start := row * job.width
		end := start + job.width
		if job.backward {
			dot: f64
			for index in start..<end { dot += f64(job.output.value.data[index]) * f64(job.output.grad.data[index]) }
			for index in start..<end {
				job.input.grad.data[index] += f32(f64(job.output.value.data[index]) * (f64(job.output.grad.data[index]) - dot))
			}
		} else {
			maximum := job.input.value.data[start]
			for item in job.input.value.data[start:end] { maximum = max(maximum, item) }
			sum: f64
			for index in start..<end {
				exponential := math.exp(f64(job.input.value.data[index]) - f64(maximum))
				job.output.value.data[index] = f32(exponential)
				sum += exponential
			}
			for index in start..<end { job.output.value.data[index] = f32(f64(job.output.value.data[index]) / sum) }
		}
	}
}

SoftmaxWorker :: proc(worker: ^thread.Thread) {
	job := (^SoftmaxJob)(worker.data)
	if job.run { SoftmaxRows(job) }
}

SoftmaxExecute :: proc(input, output: ^core.Node, width, workers: int, backward: bool) {
	rows := len(input.value.data) / width
	MAX_WORKERS :: 16
	count := min(max(workers, 1), rows, MAX_WORKERS)
	job := SoftmaxJob{input, output, width, 0, rows, backward, true}
	when !thread.IS_SUPPORTED {
		SoftmaxRows(&job)
		return
	}
	if count <= 1 {
		SoftmaxRows(&job)
		return
	}
	jobs: [MAX_WORKERS]SoftmaxJob
	threads: [MAX_WORKERS-1]^thread.Thread
	created := 0
	defer {
		for i in 0..<created { thread.destroy(threads[i]) }
	}
	for i in 0..<count {
		firstRow := i * (rows / count) + min(i, rows % count)
		rowCount := rows / count
		if i < rows % count { rowCount += 1 }
		jobs[i] = SoftmaxJob{input, output, width, firstRow, rowCount, backward, false}
	}
	for i in 0..<count-1 {
		threads[i] = thread.create(SoftmaxWorker)
		if threads[i] == nil {
			for j in 0..<created { thread.start(threads[j]) }
			for j in 0..<created { thread.join(threads[j]) }
			for j in 0..<created { thread.destroy(threads[j]) }
			created = 0
			SoftmaxRows(&job)
			return
		}
		threads[i].data = &jobs[i]
		created += 1
	}
	for i in 0..<count { jobs[i].run = true }
	for i in 0..<created { thread.start(threads[i]) }
	SoftmaxRows(&jobs[count-1])
	for i in 0..<created { thread.join(threads[i]) }
}

// Categorical policy buffers (including shape, mask, actions, outputs and RNG
// state) must be caller-owned and mutually non-overlapping. Logits have a
// nonempty last axis; preceding axes enumerate rows, including zero rows. Mask
// has one bool per logit, true meaning legal. All logits, even masked ones,
// must be finite and every row must have a legal action. No procedure allocates.
// Invalid inputs leave outputs and RNG unchanged. Log probabilities and entropy
// use f64 to represent differences across the full finite f32 range.
CategoricalPolicyValid :: proc(logits: core.Tensor, mask: []bool) -> bool {
	if !core.TensorValid(logits) || len(logits.shape) == 0 ||
		logits.shape[len(logits.shape)-1] == 0 || len(mask) != len(logits.data) { return false }
	width := logits.shape[len(logits.shape)-1]
	for start := 0; start < len(logits.data); start += width {
		legal := false
		for index in start..<start+width {
			value := logits.data[index]
			if math.is_nan(value) || math.is_inf(value) { return false }
			legal = legal || mask[index]
		}
		if !legal { return false }
	}
	return true
}

CategoricalPolicyRowStats :: proc(logits: []f32, mask: []bool) -> (maximum, sum, logSum: f64) {
	first := true
	for value, index in logits {
		if mask[index] && (first || f64(value) > maximum) {
			maximum = f64(value)
			first = false
		}
	}
	// Exclude exactly one maximum so a tiny tail is not rounded away by 1.
	tail: f64
	skippedMaximum := false
	for value, index in logits {
		if mask[index] {
			weight := math.exp(f64(value) - maximum)
			sum += weight
			if !skippedMaximum && f64(value) == maximum {
				skippedMaximum = true
			} else {
				tail += weight
			}
		}
	}
	logSum = math.log1p(tail)
	return
}

// Writes one probability per logit; masked actions receive zero.
CategoricalPolicyProbabilities :: proc(logits: core.Tensor, mask: []bool, probabilities: []f32) -> bool {
	if !CategoricalPolicyValid(logits, mask) || len(probabilities) != len(logits.data) { return false }
	width := logits.shape[len(logits.shape)-1]
	for start := 0; start < len(logits.data); start += width {
		maximum, sum, _ := CategoricalPolicyRowStats(logits.data[start:start+width], mask[start:start+width])
		for index in start..<start+width {
			probabilities[index] = 0
			if mask[index] { probabilities[index] = f32(math.exp(f64(logits.data[index]) - maximum) / sum) }
		}
	}
	return true
}

// Actions and logProbs contain one entry per row; selected actions must be legal.
CategoricalPolicyLogProbs :: proc(logits: core.Tensor, mask: []bool, actions: []int, logProbs: []f64) -> bool {
	if !CategoricalPolicyValid(logits, mask) { return false }
	width := logits.shape[len(logits.shape)-1]
	rows := len(logits.data) / width
	if len(actions) != rows || len(logProbs) != rows { return false }
	for action, row in actions {
		if action < 0 || action >= width || !mask[row * width + action] { return false }
	}
	for action, row in actions {
		start := row * width
		maximum, _, logSum := CategoricalPolicyRowStats(logits.data[start:start+width], mask[start:start+width])
		logProbs[row] = (f64(logits.data[start+action]) - maximum) - logSum
	}
	return true
}

// Entropy contains one entry per row, in nats.
CategoricalPolicyEntropy :: proc(logits: core.Tensor, mask: []bool, entropy: []f64) -> bool {
	if !CategoricalPolicyValid(logits, mask) { return false }
	width := logits.shape[len(logits.shape)-1]
	if len(entropy) != len(logits.data) / width { return false }
	for start := 0; start < len(logits.data); start += width {
		maximum, sum, logSum := CategoricalPolicyRowStats(logits.data[start:start+width], mask[start:start+width])
		weighted: f64
		for index in start..<start+width {
			if mask[index] {
				difference := f64(logits.data[index]) - maximum
				weighted += math.exp(difference) * difference
			}
		}
		entropy[start / width] = logSum - weighted / sum
	}
	return true
}

// Xorshift64 (13, 7, 17), nonzero state, one step per row; the high
// 53 bits select a point in [0, 1). Identical inputs and state reproduce the
// same results on the same math implementation. Empty batches do not advance it.
CategoricalPolicySample :: proc(logits: core.Tensor, mask: []bool, randomState: ^u64, actions: []int) -> bool {
	if randomState == nil || randomState^ == 0 || !CategoricalPolicyValid(logits, mask) { return false }
	width := logits.shape[len(logits.shape)-1]
	if len(actions) != len(logits.data) / width { return false }
	state := randomState^
	for start := 0; start < len(logits.data); start += width {
		maximum, sum, _ := CategoricalPolicyRowStats(logits.data[start:start+width], mask[start:start+width])
		state ~= state << 13
		state ~= state >> 7
		state ~= state << 17
		target := f64(state >> 11) / f64(1 << 53) * sum
		cumulative: f64
		chosen := 0
		for index in start..<start+width {
			if mask[index] {
				weight := math.exp(f64(logits.data[index]) - maximum)
				if weight > 0 { chosen = index - start }
				cumulative += weight
				if target < cumulative { break }
			}
		}
		actions[start / width] = chosen
	}
	randomState^ = state
	return true
}

// Values and gradients must use distinct buffers. Backward uses the forward output.
ActivationForward :: proc(input, output: ^core.Node, kind: ActivationKind) -> bool {
	if kind == .Softmax { return SoftmaxForward(input, output) }
	if !ActivationValid(input, output, false) { return false }
	for item, index in input.value.data {
		switch kind {
		case .Relu:
			output.value.data[index] = max(item, 0)
		case .Sigmoid:
			if item >= 0 {
				output.value.data[index] = 1 / (1 + math.exp(-item))
			} else {
				exponential := math.exp(item)
				output.value.data[index] = exponential / (1 + exponential)
			}
		case .Tanh:
			output.value.data[index] = math.tanh(item)
		case .Softmax:
			return false
		}
	}
	return true
}

// Accumulates into input.grad. ReLU has zero derivative at zero.
ActivationBackward :: proc(input, output: ^core.Node, kind: ActivationKind) -> bool {
	if kind == .Softmax { return SoftmaxBackward(input, output) }
	if !ActivationValid(input, output, true) { return false }
	for item, index in input.value.data {
		derivative: f32
		switch kind {
		case .Relu:
			if item > 0 { derivative = 1 }
		case .Sigmoid:
			result := output.value.data[index]
			derivative = result * (1 - result)
		case .Tanh:
			result := output.value.data[index]
			derivative = 1 - result * result
		case .Softmax:
			return false
		}
		input.grad.data[index] += output.grad.data[index] * derivative
	}
	return true
}
