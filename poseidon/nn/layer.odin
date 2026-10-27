package nn

import "../core"

// Dense uses [batch, inputs] values, [inputs, outputs] weights and [outputs] bias.
// All nodes and their non-overlapping buffers are owned by the caller.
Dense :: struct {
	input: ^core.Node,
	weights: ^core.Node,
	bias: ^core.Node,
	output: ^core.Node,
}

Layer :: union { ^Dense, ^Relu, ^Sigmoid, ^Tanh, ^Softmax, ^Dropout }

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
