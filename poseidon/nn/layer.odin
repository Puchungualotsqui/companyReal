package nn

import "../core"
import "core:math"
import "core:simd"

// Dense uses [batch, inputs] values, [inputs, outputs] weights and [outputs] bias.
// All nodes and their non-overlapping buffers are owned by the caller.
Dense :: struct {
	input: ^core.Node,
	weights: ^core.Node,
	bias: ^core.Node,
	output: ^core.Node,
}

// Flatten copies row-major input into caller-owned [batch, features] output.
// Features is the product of all dimensions after the batch; a zero feature
// dimension makes it zero. Empty tensors require no storage and do no work.
// Value buffers must be disjoint; backward additionally requires both gradient
// buffers to be disjoint from each other and from both value buffers.
Flatten :: struct {
	input, output: ^core.Node,
}

FlattenValid :: proc(layer: ^Flatten, gradients: bool) -> bool {
	if layer == nil || layer.input == nil || layer.output == nil { return false }
	input, output := layer.input.value, layer.output.value
	if !core.TensorValid(input) || !core.TensorValid(output) ||
		len(input.shape) < 2 || len(output.shape) != 2 { return false }
	features := 1
	for dimension in input.shape[1:] {
		if dimension == 0 { features = 0; break }
	}
	if features != 0 {
		for dimension in input.shape[1:] {
			if features > max(int)/dimension { return false }
			features *= dimension
		}
	}
	if output.shape[0] != input.shape[0] || output.shape[1] != features ||
		core.BuffersOverlap(input, output) { return false }
	if gradients {
		inputGrad, outputGrad := layer.input.grad, layer.output.grad
		if !core.TensorValid(inputGrad) || !core.TensorValid(outputGrad) ||
			!core.SameShape(input, inputGrad) || !core.SameShape(output, outputGrad) ||
			core.BuffersOverlap(input, inputGrad) || core.BuffersOverlap(input, outputGrad) ||
			core.BuffersOverlap(output, inputGrad) || core.BuffersOverlap(output, outputGrad) ||
			core.BuffersOverlap(inputGrad, outputGrad) { return false }
	}
	return true
}

FlattenForward :: proc(layer: ^Flatten) -> bool {
	if !FlattenValid(layer, false) { return false }
	copy(layer.output.value.data, layer.input.value.data)
	return true
}

FlattenBackward :: proc(layer: ^Flatten) -> bool {
	if !FlattenValid(layer, true) { return false }
	inputGrad, outputGrad := layer.input.grad.data, layer.output.grad.data
	i := 0
	for ; i <= len(inputGrad)-4; i += 4 {
		left := #simd[4]f32{inputGrad[i], inputGrad[i+1], inputGrad[i+2], inputGrad[i+3]}
		right := #simd[4]f32{outputGrad[i], outputGrad[i+1], outputGrad[i+2], outputGrad[i+3]}
		sum := left + right
		for lane in 0..<4 { inputGrad[i+lane] = simd.extract(sum, lane) }
	}
	for ; i < len(inputGrad); i += 1 { inputGrad[i] += outputGrad[i] }
	return true
}

// Pool2D operates on NHWC tensors with valid windows and a single positive stride.
// Buffers are caller-owned and disjoint. Backward accumulates into input.grad;
// for max pooling input values must remain unchanged between forward and backward.
// Max pooling rejects non-finite input values when the output is nonempty.
PoolKind :: enum { Max, Average }

Pool2D :: struct {
	input, output: ^core.Node,
	kind: PoolKind,
	kernelHeight, kernelWidth, stride: int,
}

Pool2DValid :: proc(layer: ^Pool2D, gradients: bool) -> bool {
	if layer == nil || layer.input == nil || layer.output == nil { return false }
	input, output := layer.input.value, layer.output.value
	if !core.TensorValid(input) || !core.TensorValid(output) ||
		len(input.shape) != 4 || len(output.shape) != 4 ||
		(layer.kind != .Max && layer.kind != .Average) ||
		layer.kernelHeight <= 0 || layer.kernelWidth <= 0 || layer.stride <= 0 ||
		layer.kernelHeight > max(int)/layer.kernelWidth { return false }
	height, width := 0, 0
	if input.shape[1] >= layer.kernelHeight {
		height = (input.shape[1] - layer.kernelHeight)/layer.stride + 1
	}
	if input.shape[2] >= layer.kernelWidth {
		width = (input.shape[2] - layer.kernelWidth)/layer.stride + 1
	}
	if output.shape[0] != input.shape[0] || output.shape[1] != height ||
		output.shape[2] != width || output.shape[3] != input.shape[3] ||
		core.BuffersOverlap(input, output) { return false }
	if gradients {
		inputGrad, outputGrad := layer.input.grad, layer.output.grad
		if !core.TensorValid(inputGrad) || !core.TensorValid(outputGrad) ||
			!core.SameShape(input, inputGrad) || !core.SameShape(output, outputGrad) ||
			core.BuffersOverlap(input, inputGrad) || core.BuffersOverlap(input, outputGrad) ||
			core.BuffersOverlap(output, inputGrad) || core.BuffersOverlap(output, outputGrad) ||
			core.BuffersOverlap(inputGrad, outputGrad) { return false }
	}
	if layer.kind == .Max && len(output.data) != 0 {
		for value in input.data {
			if math.is_nan(value) || math.is_inf(value) { return false }
		}
	}
	return true
}

Pool2DForward :: proc(layer: ^Pool2D) -> bool {
	if !Pool2DValid(layer, false) { return false }
	input, output := layer.input.value, layer.output.value
	if len(output.data) == 0 { return true }
	n, ih, iw, channels := input.shape[0], input.shape[1], input.shape[2], input.shape[3]
	oh, ow := output.shape[1], output.shape[2]
	for b in 0..<n {
		for y in 0..<oh {
			for x in 0..<ow {
				for c in 0..<channels {
					first := ((b*ih+y*layer.stride)*iw+x*layer.stride)*channels+c
					result := input.data[first]
					sum: f64
					for ky in 0..<layer.kernelHeight {
						for kx in 0..<layer.kernelWidth {
							value := input.data[((b*ih+y*layer.stride+ky)*iw+x*layer.stride+kx)*channels+c]
							if layer.kind == .Max { result = max(result, value) } else { sum += f64(value) }
						}
					}
					if layer.kind == .Average { result = f32(sum / f64(layer.kernelHeight*layer.kernelWidth)) }
					output.data[((b*oh+y)*ow+x)*channels+c] = result
				}
			}
		}
	}
	return true
}

Pool2DBackward :: proc(layer: ^Pool2D) -> bool {
	if !Pool2DValid(layer, true) { return false }
	input, output := layer.input.value, layer.output.value
	if len(output.data) == 0 { return true }
	n, ih, iw, channels := input.shape[0], input.shape[1], input.shape[2], input.shape[3]
	oh, ow := output.shape[1], output.shape[2]
	for b in 0..<n {
		for y in 0..<oh {
			for x in 0..<ow {
				for c in 0..<channels {
					gradient := layer.output.grad.data[((b*oh+y)*ow+x)*channels+c]
					best := ((b*ih+y*layer.stride)*iw+x*layer.stride)*channels+c
					if layer.kind == .Average { gradient /= f32(layer.kernelHeight*layer.kernelWidth) }
					for ky in 0..<layer.kernelHeight {
						for kx in 0..<layer.kernelWidth {
							index := ((b*ih+y*layer.stride+ky)*iw+x*layer.stride+kx)*channels+c
							if layer.kind == .Max {
								if input.data[index] > input.data[best] { best = index }
							} else {
								layer.input.grad.data[index] += gradient
							}
						}
					}
					if layer.kind == .Max { layer.input.grad.data[best] += gradient }
				}
			}
		}
	}
	return true
}

// Conv2D computes cross-correlation on NHWC values with [height, width,
// input channels, output channels] weights. Buffers must be disjoint.
// Padding is symmetric and stride must be positive. Forward overwrites output;
// backward accumulates gradients from the seeded output gradient.
Conv2D :: struct {
	input, weights, bias, output: ^core.Node,
	stride, padding: int,
}

// Returns the floored output dimension, rejecting negative sizes and overflow.
Conv2DDimension :: proc(size, kernel, stride, padding: int) -> (int, bool) {
	if size < 0 || kernel <= 0 || stride <= 0 || padding < 0 || padding > (max(int)-size)/2 {
		return 0, false
	}
	padded := size + 2*padding
	if padded < kernel {
		if kernel - padded > stride { return 0, false }
		return 0, true
	}
	quotient := (padded-kernel)/stride
	if quotient == max(int) { return 0, false }
	return quotient + 1, true
}

Conv2DValid :: proc(layer: ^Conv2D, gradients: bool) -> bool {
	if layer == nil || layer.input == nil || layer.weights == nil || layer.bias == nil || layer.output == nil {
		return false
	}
	input, weights, bias, output := layer.input.value, layer.weights.value, layer.bias.value, layer.output.value
	if !core.TensorValid(input) || !core.TensorValid(weights) || !core.TensorValid(bias) || !core.TensorValid(output) ||
		len(input.shape) != 4 || len(weights.shape) != 4 || len(bias.shape) != 1 || len(output.shape) != 4 {
		return false
	}
	if weights.shape[0] <= 0 || weights.shape[1] <= 0 || weights.shape[2] <= 0 || weights.shape[3] <= 0 ||
		input.shape[3] != weights.shape[2] || bias.shape[0] != weights.shape[3] ||
		output.shape[0] != input.shape[0] || output.shape[3] != weights.shape[3] {
		return false
	}
	height, heightOk := Conv2DDimension(input.shape[1], weights.shape[0], layer.stride, layer.padding)
	width, widthOk := Conv2DDimension(input.shape[2], weights.shape[1], layer.stride, layer.padding)
	if !heightOk || !widthOk || output.shape[1] != height || output.shape[2] != width { return false }
	nodes := [4]^core.Node{layer.input, layer.weights, layer.bias, layer.output}
	for node, i in nodes {
		if gradients && (!core.TensorValid(node.grad) || !core.SameShape(node.value, node.grad)) { return false }
		if gradients && core.BuffersOverlap(node.value, node.grad) { return false }
		for previous in nodes[:i] {
			if core.BuffersOverlap(node.value, previous.value) { return false }
			if gradients && (core.BuffersOverlap(node.value, previous.grad) ||
				core.BuffersOverlap(node.grad, previous.value) || core.BuffersOverlap(node.grad, previous.grad)) { return false }
		}
	}
	return true
}

Conv2DForward :: proc(layer: ^Conv2D) -> bool {
	if !Conv2DValid(layer, false) { return false }
	input, weights, bias, output := layer.input.value, layer.weights.value, layer.bias.value, layer.output.value
	if len(output.data) == 0 { return true }
	n, ih, iw, ic := input.shape[0], input.shape[1], input.shape[2], input.shape[3]
	kh, kw, oc := weights.shape[0], weights.shape[1], weights.shape[3]
	oh, ow := output.shape[1], output.shape[2]
	for b in 0..<n {
		for y in 0..<oh {
			for x in 0..<ow {
				for o in 0..<oc {
					sum := bias.data[o]
					for ky in 0..<kh {
						sy := y*layer.stride + ky - layer.padding
						if sy < 0 || sy >= ih { continue }
						for kx in 0..<kw {
							sx := x*layer.stride + kx - layer.padding
							if sx < 0 || sx >= iw { continue }
							for c in 0..<ic {
								sum += input.data[((b*ih+sy)*iw+sx)*ic+c] * weights.data[((ky*kw+kx)*ic+c)*oc+o]
							}
						}
					}
					output.data[((b*oh+y)*ow+x)*oc+o] = sum
				}
			}
		}
	}
	return true
}

Conv2DBackward :: proc(layer: ^Conv2D) -> bool {
	if !Conv2DValid(layer, true) { return false }
	input, weights, output := layer.input.value, layer.weights.value, layer.output.value
	if len(output.data) == 0 { return true }
	n, ih, iw, ic := input.shape[0], input.shape[1], input.shape[2], input.shape[3]
	kh, kw, oc := weights.shape[0], weights.shape[1], weights.shape[3]
	oh, ow := output.shape[1], output.shape[2]
	for b in 0..<n {
		for y in 0..<oh {
			for x in 0..<ow {
				for o in 0..<oc {
					gradient := layer.output.grad.data[((b*oh+y)*ow+x)*oc+o]
					layer.bias.grad.data[o] += gradient
					for ky in 0..<kh {
						sy := y*layer.stride + ky - layer.padding
						if sy < 0 || sy >= ih { continue }
						for kx in 0..<kw {
							sx := x*layer.stride + kx - layer.padding
							if sx < 0 || sx >= iw { continue }
							for c in 0..<ic {
								ii := ((b*ih+sy)*iw+sx)*ic+c
								wi := ((ky*kw+kx)*ic+c)*oc+o
								layer.input.grad.data[ii] += gradient * weights.data[wi]
								layer.weights.grad.data[wi] += gradient * input.data[ii]
							}
						}
					}
				}
			}
		}
	}
	return true
}

Layer :: union { ^Dense, ^Conv2D, ^Pool2D, ^Flatten, ^Relu, ^Sigmoid, ^Tanh, ^Softmax, ^Dropout }

DenseValid :: proc(layer: ^Dense, gradients: bool) -> bool {
	if layer == nil || layer.input == nil || layer.weights == nil || layer.bias == nil || layer.output == nil {
		return false
	}
	input, weights, bias, output := layer.input.value, layer.weights.value, layer.bias.value, layer.output.value
	if !core.TensorValid(input) || !core.TensorValid(weights) || !core.TensorValid(bias) || !core.TensorValid(output) ||
		len(input.shape) != 2 || len(weights.shape) != 2 || len(bias.shape) != 1 || len(output.shape) != 2 {
		return false
	}
	if input.shape[1] != weights.shape[0] || weights.shape[1] != bias.shape[0] ||
		output.shape[0] != input.shape[0] || output.shape[1] != weights.shape[1] {
		return false
	}
	if gradients {
		for node in ([4]^core.Node{layer.input, layer.weights, layer.bias, layer.output}) {
			if !core.TensorValid(node.grad) || !core.SameShape(node.value, node.grad) {
				return false
			}
		}
	}
	return true
}


// LayerForward requires distinct input and output value buffers.
LayerForward :: proc(layer: Layer) -> bool {
	switch value in layer {
	case nil:
		return false
	case ^Dense:
		if !DenseValid(value, false) { return false }
		if !core.MatMul(value.output.value, value.input.value, value.weights.value) { return false }
		columns := value.bias.value.shape[0]
		for row in 0..<value.input.value.shape[0] {
			for column in 0..<columns {
				value.output.value.data[row*columns+column] += value.bias.value.data[column]
			}
		}
	case ^Conv2D:
		return Conv2DForward(value)
	case ^Pool2D:
		return Pool2DForward(value)
	case ^Flatten:
		return FlattenForward(value)
	case ^Relu:
		if value == nil { return false }
		return ActivationForward(value.input, value.output, .Relu)
	case ^Sigmoid:
		if value == nil { return false }
		return ActivationForward(value.input, value.output, .Sigmoid)
	case ^Tanh:
		if value == nil { return false }
		return ActivationForward(value.input, value.output, .Tanh)
	case ^Softmax:
		if value == nil { return false }
		return SoftmaxForward(value.input, value.output)
	case ^Dropout:
		return DropoutForward(value)
	}
	return true
}

// LayerBackward accumulates gradients; the caller seeds and clears them.
LayerBackward :: proc(layer: Layer) -> bool {
	switch value in layer {
	case nil:
		return false
	case ^Dense:
		if !DenseValid(value, true) { return false }
		rows := value.input.value.shape[0]
		inputs := value.input.value.shape[1]
		outputs := value.bias.value.shape[0]
		for row in 0..<rows {
			for column in 0..<outputs {
				gradient := value.output.grad.data[row*outputs+column]
				value.bias.grad.data[column] += gradient
				for k in 0..<inputs {
					value.input.grad.data[row*inputs+k] += gradient * value.weights.value.data[k*outputs+column]
					value.weights.grad.data[k*outputs+column] += gradient * value.input.value.data[row*inputs+k]
				}
			}
		}
	case ^Conv2D:
		return Conv2DBackward(value)
	case ^Pool2D:
		return Pool2DBackward(value)
	case ^Flatten:
		return FlattenBackward(value)
	case ^Relu:
		if value == nil { return false }
		return ActivationBackward(value.input, value.output, .Relu)
	case ^Sigmoid:
		if value == nil { return false }
		return ActivationBackward(value.input, value.output, .Sigmoid)
	case ^Tanh:
		if value == nil { return false }
		return ActivationBackward(value.input, value.output, .Tanh)
	case ^Softmax:
		if value == nil { return false }
		return SoftmaxBackward(value.input, value.output)
	case ^Dropout:
		return DropoutBackward(value)
	}
	return true
}
