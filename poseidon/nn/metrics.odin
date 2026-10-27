package nn

import "../core"

// CategoricalAccuracyWithLogits compares the argmax of logits and target
// distributions along the last axis, averaging over all rows. Ties select the
// first class. Targets follow CategoricalLogitsValid's distribution rules.
// Inputs are borrowed, never modified, and no allocation is performed.
CategoricalAccuracyWithLogits :: proc(prediction, target: core.Tensor) -> (f32, bool) {
	if !CategoricalLogitsValid(prediction, target) { return 0, false }
	classes := prediction.shape[len(prediction.shape) - 1]
	correct := 0
	for start := 0; start < len(prediction.data); start += classes {
		predicted, expected := start, start
		for i in start + 1..<start + classes {
			if prediction.data[i] > prediction.data[predicted] { predicted = i }
			if target.data[i] > target.data[expected] { expected = i }
		}
		if predicted == expected { correct += 1 }
	}
	return f32(f64(correct) / f64(len(prediction.data) / classes)), true
}

// BinaryAccuracyWithLogits averages elementwise accuracy. Logits >= 0 predict
// class 1; targets must be exactly 0 or 1. Scalars are accepted. Inputs are
// borrowed, never modified, and no allocation is performed.
BinaryAccuracyWithLogits :: proc(prediction, target: core.Tensor) -> (f32, bool) {
	if !LossInputsValid(prediction, target) { return 0, false }
	correct := 0
	for item, i in prediction.data {
		label := target.data[i]
		if label != 0 && label != 1 { return 0, false }
		if (item >= 0) == (label == 1) { correct += 1 }
	}
	return f32(f64(correct) / f64(len(prediction.data))), true
}
