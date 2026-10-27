package nn

import "../core"
import "core:math"

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

// Softmax uses caller-owned, non-overlapping buffers and normalizes the last axis.
SoftmaxForward :: proc(input, output: ^core.Node) -> bool {
	if !ActivationValid(input, output, false) || len(input.value.shape) == 0 { return false }
	width := input.value.shape[len(input.value.shape)-1]
	if width == 0 { return false }
	for item in input.value.data {
		if math.is_nan(item) || math.is_inf(item) { return false }
	}
	for start := 0; start < len(input.value.data); start += width {
		maximum := input.value.data[start]
		for item in input.value.data[start:start+width] { maximum = max(maximum, item) }
		sum: f64
		for index in start..<start+width {
			exponential := math.exp(f64(input.value.data[index]) - f64(maximum))
			output.value.data[index] = f32(exponential)
			sum += exponential
		}
		for index in start..<start+width { output.value.data[index] = f32(f64(output.value.data[index]) / sum) }
	}
	return true
}

// Backward accumulates the vector-Jacobian product using the forward output.
SoftmaxBackward :: proc(input, output: ^core.Node) -> bool {
	if !ActivationValid(input, output, true) || len(input.value.shape) == 0 { return false }
	width := input.value.shape[len(input.value.shape)-1]
	if width == 0 { return false }
	for item in input.value.data {
		if math.is_nan(item) || math.is_inf(item) { return false }
	}
	for start := 0; start < len(input.value.data); start += width {
		dot: f64
		for index in start..<start+width { dot += f64(output.value.data[index]) * f64(output.grad.data[index]) }
		for index in start..<start+width {
			input.grad.data[index] += f32(f64(output.value.data[index]) * (f64(output.grad.data[index]) - dot))
		}
	}
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
