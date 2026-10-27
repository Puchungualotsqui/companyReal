package nn

import "../core"
import "core:math"

// MeanSquaredError rejects empty tensors and does not modify either input.
MeanSquaredError :: proc(prediction, target: core.Tensor) -> (f32, bool) {
	if !core.TensorValid(prediction) || !core.TensorValid(target) || !core.SameShape(prediction, target) || len(prediction.data) == 0 {
		return 0, false
	}
	sum: f32 = 0
	for item, index in prediction.data {
		difference := item - target.data[index]
		sum += difference * difference
	}
	return sum / f32(len(prediction.data)), true
}

// MeanSquaredErrorBackward accumulates into prediction.grad; target is constant.
// Prediction value, gradient and target storage must not overlap.
MeanSquaredErrorBackward :: proc(prediction: ^core.Node, target: core.Tensor) -> bool {
	if prediction == nil || !core.TensorValid(prediction.value) || !core.TensorValid(prediction.grad) ||
		!core.TensorValid(target) || !core.SameShape(prediction.value, prediction.grad) ||
		!core.SameShape(prediction.value, target) || len(prediction.value.data) == 0 {
		return false
	}
	scale := f32(2) / f32(len(prediction.value.data))
	for item, index in prediction.value.data {
		prediction.grad.data[index] += scale * (item - target.data[index])
	}
	return true
}

// The losses below reject non-finite inputs. Backward requires distinct prediction
// value, gradient and target buffers, and accumulates into prediction.grad.
LossInputsValid :: proc(prediction, target: core.Tensor) -> bool {
	if !core.TensorValid(prediction) || !core.TensorValid(target) ||
		!core.SameShape(prediction, target) || len(prediction.data) == 0 {
		return false
	}
	for item, index in prediction.data {
		if math.is_nan(item) || math.is_inf(item) ||
			math.is_nan(target.data[index]) || math.is_inf(target.data[index]) {
			return false
		}
	}
	return true
}

LossBackwardValid :: proc(prediction: ^core.Node, target: core.Tensor) -> bool {
	return prediction != nil && LossInputsValid(prediction.value, target) &&
		core.TensorValid(prediction.grad) && core.SameShape(prediction.value, prediction.grad)
}

// MeanAbsoluteError averages absolute differences; its derivative at zero is zero.
MeanAbsoluteError :: proc(prediction, target: core.Tensor) -> (f32, bool) {
	if !LossInputsValid(prediction, target) { return 0, false }
	sum: f64
	for item, index in prediction.data {
		sum += math.abs(f64(item) - f64(target.data[index]))
	}
	result := f32(sum / f64(len(prediction.data)))
	if math.is_inf(result) { return 0, false }
	return result, true
}

MeanAbsoluteErrorBackward :: proc(prediction: ^core.Node, target: core.Tensor) -> bool {
	if !LossBackwardValid(prediction, target) { return false }
	scale := f32(1) / f32(len(prediction.value.data))
	for item, index in prediction.value.data {
		if item > target.data[index] {
			prediction.grad.data[index] += scale
		} else if item < target.data[index] {
			prediction.grad.data[index] -= scale
		}
	}
	return true
}

// HuberLoss averages the quadratic/linear loss with a positive finite delta.
HuberLoss :: proc(prediction, target: core.Tensor, delta: f32) -> (f32, bool) {
	if !LossInputsValid(prediction, target) || delta <= 0 || math.is_nan(delta) || math.is_inf(delta) {
		return 0, false
	}
	sum: f64
	for item, index in prediction.data {
		difference := math.abs(f64(item) - f64(target.data[index]))
		if difference <= f64(delta) {
			sum += 0.5 * difference * difference
		} else {
			sum += f64(delta) * (difference - 0.5 * f64(delta))
		}
	}
	result := f32(sum / f64(len(prediction.data)))
	if math.is_inf(result) { return 0, false }
	return result, true
}

HuberLossBackward :: proc(prediction: ^core.Node, target: core.Tensor, delta: f32) -> bool {
	if !LossBackwardValid(prediction, target) || delta <= 0 || math.is_nan(delta) || math.is_inf(delta) {
		return false
	}
	for item, index in prediction.value.data {
		difference := f64(item) - f64(target.data[index])
		derivative := clamp(difference, -f64(delta), f64(delta))
		prediction.grad.data[index] += f32(derivative / f64(len(prediction.value.data)))
	}
	return true
}

// BinaryCrossEntropyWithLogits averages over elements. Targets must be in [0, 1].
// Logits need not be passed through sigmoid; the stable formula handles large logits.
BinaryCrossEntropyWithLogits :: proc(prediction, target: core.Tensor) -> (f32, bool) {
	if !BinaryLogitsValid(prediction, target) { return 0, false }
	sum: f64
	for item, index in prediction.data {
		x := f64(item)
		sum += max(x, 0) - x * f64(target.data[index]) + math.log1p(math.exp(-math.abs(x)))
	}
	result := f32(sum / f64(len(prediction.data)))
	if math.is_inf(result) { return 0, false }
	return result, true
}

BinaryLogitsValid :: proc(prediction, target: core.Tensor) -> bool {
	if !LossInputsValid(prediction, target) { return false }
	for item in target.data {
		if item < 0 || item > 1 { return false }
	}
	return true
}

BinaryCrossEntropyWithLogitsBackward :: proc(prediction: ^core.Node, target: core.Tensor) -> bool {
	if prediction == nil || !BinaryLogitsValid(prediction.value, target) ||
		!core.TensorValid(prediction.grad) || !core.SameShape(prediction.value, prediction.grad) {
		return false
	}
	for item, index in prediction.value.data {
		x := f64(item)
		sigmoid: f64
		if x >= 0 {
			sigmoid = 1 / (1 + math.exp(-x))
		} else {
			exponential := math.exp(x)
			sigmoid = exponential / (1 + exponential)
		}
		prediction.grad.data[index] += f32((sigmoid - f64(target.data[index])) / f64(len(prediction.value.data)))
	}
	return true
}

// PolicyGradientInputsValid checks flattened rows along the last axis. Every logit,
// including masked logits, and every advantage must be finite. Each selected action
// must be legal. Masks are flattened in the same order as logits.
PolicyGradientInputsValid :: proc(logits: core.Tensor, actions: []int, legal: []bool, advantages: []f32) -> bool {
	if !core.TensorValid(logits) || len(logits.shape) == 0 || len(logits.data) == 0 { return false }
	classes := logits.shape[len(logits.shape) - 1]
	if classes <= 0 { return false }
	rows := len(logits.data) / classes
	if len(actions) != rows || len(advantages) != rows || len(legal) != len(logits.data) { return false }
	for value in logits.data {
		if math.is_nan(value) || math.is_inf(value) { return false }
	}
	for action, row in actions {
		if action < 0 || action >= classes || !legal[row * classes + action] ||
			math.is_nan(advantages[row]) || math.is_inf(advantages[row]) { return false }
	}
	return true
}

// PolicyGradientLoss averages -advantage * log pi(action) over rows. The last
// axis contains actions; illegal actions are excluded from normalization.
PolicyGradientLoss :: proc(logits: core.Tensor, actions: []int, legal: []bool, advantages: []f32) -> (f32, bool) {
	if !PolicyGradientInputsValid(logits, actions, legal, advantages) { return 0, false }
	classes := logits.shape[len(logits.shape) - 1]
	total: f64
	for action, row in actions {
		start := row * classes
		maximumIndex := start + action
		for i in start..<start + classes {
			if legal[i] && logits.data[i] > logits.data[maximumIndex] { maximumIndex = i }
		}
		maximum := f64(logits.data[maximumIndex])
		sum: f64
		for i in start..<start + classes {
			if legal[i] && i != maximumIndex { sum += math.exp(f64(logits.data[i]) - maximum) }
		}
		negativeLogProbability := maximum - f64(logits.data[start + action]) + math.log1p(sum)
		total += f64(advantages[row]) * negativeLogProbability
	}
	result := f32(total / f64(len(actions)))
	if math.is_nan(result) || math.is_inf(result) { return 0, false }
	return result, true
}

// PolicyGradientLossBackward accumulates into logits.grad. Logit values,
// gradients, masks, actions and advantages must not overlap in memory. All
// existing gradients must be finite, and failure leaves the gradient unchanged.
PolicyGradientLossBackward :: proc(logits: ^core.Node, actions: []int, legal: []bool, advantages: []f32) -> bool {
	if logits == nil || !PolicyGradientInputsValid(logits.value, actions, legal, advantages) ||
		!core.TensorValid(logits.grad) || !core.SameShape(logits.value, logits.grad) { return false }
	for value in logits.grad.data {
		if math.is_nan(value) || math.is_inf(value) { return false }
	}
	classes := logits.value.shape[len(logits.value.shape) - 1]
	// Preflight every result before writing any gradient, then repeat the calculation.
	for pass in 0..<2 {
		for action, row in actions {
			start := row * classes
			maximum := f64(logits.value.data[start + action])
			for i in start..<start + classes {
				if legal[i] { maximum = max(maximum, f64(logits.value.data[i])) }
			}
			sum, otherSum: f64
			for i in start..<start + classes {
				if legal[i] {
					exponential := math.exp(f64(logits.value.data[i]) - maximum)
					sum += exponential
					if i != start + action { otherSum += exponential }
				}
			}
			for i in start..<start + classes {
				if !legal[i] { continue }
				probability := math.exp(f64(logits.value.data[i]) - maximum) / sum
				if i == start + action { probability = -otherSum / sum }
				delta := f32(f64(advantages[row]) * probability / f64(len(actions)))
				result := logits.grad.data[i] + delta
				if math.is_nan(result) || math.is_inf(result) { return false }
				if pass == 1 { logits.grad.data[i] = result }
			}
		}
	}
	return true
}

// Categorical targets are distributions along the last axis, within 1e-5 of unit sum.
CategoricalLogitsValid :: proc(prediction, target: core.Tensor) -> bool {
	if !LossInputsValid(prediction, target) || len(prediction.shape) == 0 { return false }
	classes := prediction.shape[len(prediction.shape) - 1]
	if classes == 0 { return false }
	for start := 0; start < len(target.data); start += classes {
		sum: f64
		for i in start..<start + classes {
			item := target.data[i]
			if item < 0 || item > 1 { return false }
			sum += f64(item)
		}
		if math.abs(sum - 1) > 1e-5 { return false }
	}
	return true
}

// CategoricalCrossEntropyWithLogits averages cross-entropy over flattened rows.
CategoricalCrossEntropyWithLogits :: proc(prediction, target: core.Tensor) -> (f32, bool) {
	if !CategoricalLogitsValid(prediction, target) { return 0, false }
	classes := prediction.shape[len(prediction.shape) - 1]
	total: f64
	for start := 0; start < len(prediction.data); start += classes {
		maximum := f64(prediction.data[start])
		for i in start + 1..<start + classes { maximum = max(maximum, f64(prediction.data[i])) }
		exponentials, weighted, targetSum: f64
		for i in start..<start + classes {
			shifted := f64(prediction.data[i]) - maximum
			exponentials += math.exp(shifted)
			weighted -= f64(target.data[i]) * shifted
			targetSum += f64(target.data[i])
		}
		total += weighted + targetSum * math.ln(exponentials)
	}
	result := f32(total / f64(len(prediction.data) / classes))
	if math.is_inf(result) || math.is_nan(result) { return 0, false }
	return result, true
}

// Buffers must not overlap. Gradients are accumulated and averaged over rows.
CategoricalCrossEntropyWithLogitsBackward :: proc(prediction: ^core.Node, target: core.Tensor) -> bool {
	if prediction == nil || !CategoricalLogitsValid(prediction.value, target) ||
		!core.TensorValid(prediction.grad) || !core.SameShape(prediction.value, prediction.grad) {
		return false
	}
	classes := prediction.value.shape[len(prediction.value.shape) - 1]
	rows := len(prediction.value.data) / classes
	for start := 0; start < len(prediction.value.data); start += classes {
		maximum := f64(prediction.value.data[start])
		for i in start + 1..<start + classes { maximum = max(maximum, f64(prediction.value.data[i])) }
		exponentials, targetSum: f64
		for i in start..<start + classes {
			exponentials += math.exp(f64(prediction.value.data[i]) - maximum)
			targetSum += f64(target.data[i])
		}
		for i in start..<start + classes {
			probability := math.exp(f64(prediction.value.data[i]) - maximum) / exponentials
			prediction.grad.data[i] += f32((targetSum * probability - f64(target.data[i])) / f64(rows))
		}
	}
	return true
}
