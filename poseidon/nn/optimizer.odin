package nn

import "../core"

// Parameters and their non-overlapping value and gradient buffers are caller-owned.
// List each trainable node once; activation outputs are normally not parameters.
SGD :: struct {
	parameters: []^core.Node,
	learningRate: f32,
}

// SGDStep validates all parameters before updating any values.
// Gradients are left unchanged so the caller can inspect or clear them.
SGDStep :: proc(optimizer: SGD) -> bool {
	if !(optimizer.learningRate > 0 && optimizer.learningRate <= 3.402823466e+38) {
		return false
	}
	for parameter, index in optimizer.parameters {
		if parameter == nil || !core.TensorValid(parameter.value) || !core.TensorValid(parameter.grad) ||
			!core.SameShape(parameter.value, parameter.grad) {
			return false
		}
		for previous in optimizer.parameters[:index] {
			if previous == parameter { return false }
		}
	}
	for parameter in optimizer.parameters {
		for gradient, index in parameter.grad.data {
			parameter.value.data[index] -= optimizer.learningRate * gradient
		}
	}
	return true
}

// ClearGradients accepts parameters and intermediate nodes for a new pass.
// Gradient buffers must not overlap value buffers.
ClearGradients :: proc(nodes: []^core.Node) -> bool {
	for node in nodes {
		if node == nil || !core.TensorValid(node.grad) || !core.TensorValid(node.value) ||
			!core.SameShape(node.value, node.grad) {
			return false
		}
	}
	for node in nodes {
		for &gradient in node.grad.data {
			gradient = 0
		}
	}
	return true
}
