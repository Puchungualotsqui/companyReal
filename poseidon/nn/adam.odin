package nn

import "../core"
import "core:math"

// All storage is caller-owned. Parameter nodes, their value and gradient data,
// both moment slices, and optimizer metadata must not overlap. This is not checked.
// Moments are flattened in parameter and element order and must match exactly.
// Initialize with AdamInit or zero moments and step manually; do not reorder parameters.
// Reset Adam after reinitializing or changing the model.
Adam :: struct {
	parameters: []^core.Node,
	firstMoment, secondMoment: []f32,
	step: u64,
	learningRate, beta1, beta2, epsilon: f32,
}

AdamFinite :: proc(value: f64) -> bool {
	return value >= -3.402823466e+38 && value <= 3.402823466e+38
}

// Integer exponentiation avoids losing step precision when step exceeds 2^53.
AdamPower :: proc(base: f64, exponent: u64) -> f64 {
	result: f64 = 1
	factor := base
	remaining := exponent
	for remaining > 0 {
		if remaining & 1 != 0 { result *= factor }
		factor *= factor
		remaining >>= 1
	}
	return result
}

AdamUpdate :: proc(value, gradient, first, second: f32, optimizer: ^Adam, correction1, correction2: f64) -> (f32, f32, f32, bool) {
	beta1, beta2 := f64(optimizer.beta1), f64(optimizer.beta2)
	m := beta1*f64(first) + (1-beta1)*f64(gradient)
	v := beta2*f64(second) + (1-beta2)*f64(gradient)*f64(gradient)
	updated := f64(value) - f64(optimizer.learningRate)*(m/correction1)/(math.sqrt(v/correction2)+f64(optimizer.epsilon))
	if !AdamFinite(m) || !AdamFinite(v) || !AdamFinite(updated) { return 0, 0, 0, false }
	return f32(updated), f32(m), f32(v), true
}

AdamConfigValid :: proc(optimizer: ^Adam) -> bool {
	if !AdamFinite(f64(optimizer.learningRate)) || optimizer.learningRate <= 0 ||
		!(optimizer.beta1 >= 0 && optimizer.beta1 < 1) ||
		!(optimizer.beta2 >= 0 && optimizer.beta2 < 1) ||
		!AdamFinite(f64(optimizer.epsilon)) || optimizer.epsilon <= 0 ||
		len(optimizer.firstMoment) != len(optimizer.secondMoment) {
		return false
	}
	count := 0
	for parameter, index in optimizer.parameters {
		if parameter == nil || !core.TensorValid(parameter.value) || !core.TensorValid(parameter.grad) ||
			!core.SameShape(parameter.value, parameter.grad) { return false }
		for previous in optimizer.parameters[:index] {
			if previous == parameter { return false }
		}
		if len(parameter.value.data) > len(optimizer.firstMoment)-count { return false }
		count += len(parameter.value.data)
	}
	return count == len(optimizer.firstMoment)
}

// Storage must satisfy Adam's disjointness contract, including the destination.
// Failure leaves the optimizer and moments unchanged. Values are checked by AdamStep.
AdamInit :: proc(optimizer: ^Adam, parameters: []^core.Node, firstMoment, secondMoment: []f32, learningRate: f32 = 0.001, beta1: f32 = 0.9, beta2: f32 = 0.999, epsilon: f32 = 1e-8) -> bool {
	if optimizer == nil { return false }
	candidate := Adam{parameters, firstMoment, secondMoment, 0, learningRate, beta1, beta2, epsilon}
	if !AdamConfigValid(&candidate) { return false }
	for &moment in firstMoment { moment = 0 }
	for &moment in secondMoment { moment = 0 }
	optimizer^ = candidate
	return true
}

// AdamStep leaves gradients unchanged and makes no changes on validation failure.
// Aliasing, concurrent mutation, and invalid slice backing storage are caller errors.
AdamStep :: proc(optimizer: ^Adam) -> bool {
	if optimizer == nil || optimizer.step == max(u64) || !AdamConfigValid(optimizer) { return false }
	step := optimizer.step + 1
	correction1 := 1 - AdamPower(f64(optimizer.beta1), step)
	correction2 := 1 - AdamPower(f64(optimizer.beta2), step)
	index := 0
	for parameter in optimizer.parameters {
		for value, element in parameter.value.data {
			gradient := parameter.grad.data[element]
			first, second := optimizer.firstMoment[index], optimizer.secondMoment[index]
			if !AdamFinite(f64(value)) || !AdamFinite(f64(gradient)) ||
				!AdamFinite(f64(first)) || !AdamFinite(f64(second)) || second < 0 { return false }
			_, _, _, ok := AdamUpdate(value, gradient, first, second, optimizer, correction1, correction2)
			if !ok { return false }
			index += 1
		}
	}
	index = 0
	for parameter in optimizer.parameters {
		for _, element in parameter.value.data {
			value, first, second, _ := AdamUpdate(parameter.value.data[element], parameter.grad.data[element], optimizer.firstMoment[index], optimizer.secondMoment[index], optimizer, correction1, correction2)
			parameter.value.data[element] = value
			optimizer.firstMoment[index] = first
			optimizer.secondMoment[index] = second
			index += 1
		}
	}
	optimizer.step = step
	return true
}
