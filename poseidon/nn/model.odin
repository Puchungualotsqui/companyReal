package nn

import "../core"

// Layers must connect in order through shared nodes; the caller owns the slice.
Model :: struct {
	layers: []Layer,
}

// On failure, earlier layers may already have been evaluated.
ModelForward :: proc(model: Model) -> bool {
	for layer in model.layers {
		if !LayerForward(layer) { return false }
	}
	return true
}

// On failure, later layers may already have accumulated gradients.
ModelBackward :: proc(model: Model) -> bool {
	for index := len(model.layers); index > 0; index -= 1 {
		if !LayerBackward(model.layers[index-1]) { return false }
	}
	return true
}

// PolicyTrainStep performs one full-batch update and returns the pre-update loss.
// Supply input values, connected layers, the final logits node, every graph node
// exactly once, and the trainable subset in optimizer order. Graph connectivity
// and completeness are not checked. The caller controls dropout mode and state.
// Node value and gradient buffers must be disjoint, as must actions, legal,
// advantages, layer state and optimizer storage from mutable buffers. External
// aliasing is not checked. No node storage is allocated. Failure returns (0, false);
// forward values, gradients or dropout state may already have changed.
PolicyTrainStep :: proc(model: Model, output: ^core.Node, actions: []int, legal: []bool, advantages: []f32, nodes, parameters: []^core.Node, optimizer: SequentialOptimizer) -> (f32, bool) {
	if output == nil || len(model.layers) == 0 || len(parameters) == 0 { return 0, false }
	foundOutput := false
	for node, i in nodes {
		if node == nil || !core.TensorValid(node.value) || !core.TensorValid(node.grad) ||
			!core.SameShape(node.value, node.grad) || core.BuffersOverlap(node.value, node.grad) { return 0, false }
		if node == output { foundOutput = true }
		for previous in nodes[:i] {
			if node == previous || core.BuffersOverlap(node.value, previous.value) ||
				core.BuffersOverlap(node.value, previous.grad) || core.BuffersOverlap(node.grad, previous.value) ||
				core.BuffersOverlap(node.grad, previous.grad) { return 0, false }
		}
	}
	if !foundOutput || len(output.value.shape) == 0 || len(output.value.data) == 0 { return 0, false }
	classes := output.value.shape[len(output.value.shape)-1]
	if classes <= 0 || len(actions) != len(output.value.data)/classes ||
		len(advantages) != len(actions) || len(legal) != len(output.value.data) { return 0, false }
	for action, row in actions {
		if action < 0 || action >= classes || !legal[row*classes+action] || !AdamFinite(f64(advantages[row])) { return 0, false }
	}
	for parameter, i in parameters {
		found := false
		for node in nodes { if node == parameter { found = true; break } }
		if !found || parameter == output { return 0, false }
		for previous in parameters[:i] { if parameter == previous { return 0, false } }
	}
	switch value in optimizer {
	case nil:
		return 0, false
	case SequentialSGD:
		if !(value.learningRate > 0) || !AdamFinite(f64(value.learningRate)) { return 0, false }
	case ^Adam:
		if value == nil || value.step == max(u64) || !AdamConfigValid(value) || len(value.parameters) != len(parameters) { return 0, false }
		for parameter, i in parameters { if value.parameters[i] != parameter { return 0, false } }
		for first, i in value.firstMoment {
			if !AdamFinite(f64(first)) || !AdamFinite(f64(value.secondMoment[i])) || value.secondMoment[i] < 0 { return 0, false }
		}
	}
	if !ModelForward(model) { return 0, false }
	loss, ok := PolicyGradientLoss(output.value, actions, legal, advantages)
	if !ok || !ClearGradients(nodes) || !PolicyGradientLossBackward(output, actions, legal, advantages) || !ModelBackward(model) { return 0, false }
	switch value in optimizer {
	case nil:
		return 0, false
	case SequentialSGD:
		for parameter in parameters {
			for weight, i in parameter.value.data {
				gradient := parameter.grad.data[i]
				if !AdamFinite(f64(weight)) || !AdamFinite(f64(gradient)) ||
					!AdamFinite(f64(weight) - f64(value.learningRate)*f64(gradient)) ||
					!AdamFinite(f64(value.learningRate * gradient)) { return 0, false }
			}
		}
		if !SGDStep(SGD{parameters, value.learningRate}) { return 0, false }
	case ^Adam:
		if !AdamStep(value) { return 0, false }
	}
	return loss, true
}
