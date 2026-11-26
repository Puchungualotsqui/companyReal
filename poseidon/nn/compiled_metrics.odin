package nn

import "../core"
import "core:math"

SupervisedMetric :: enum {
	MeanAbsoluteError,
	MeanSquaredError,
	BinaryAccuracyWithLogits,
	CategoricalAccuracyWithLogits,
}

SupervisedEvaluation :: struct {
	dataLoss, metric: f64,
}

// One post-update, inference-mode metric per completed epoch. If validation
// data is absent, hasValidation is false and validationMetric is zero.
SupervisedEpochMetric :: struct {
	epoch:                       int,
	trainingMetric, validationMetric: f64,
	hasValidation:               bool,
}

// Optional fit metric and caller-owned per-epoch output. History needs at least
// the requested number of epochs. It records the actual run even when early
// stopping restores an earlier best checkpoint.
SequentialFitMetricTracking :: struct {
	metric:  SupervisedMetric,
	history: []SupervisedEpochMetric,
}

// Evaluates the compiled data loss and an explicitly selected metric over all
// row-major samples. batchSize zero uses model capacity; otherwise it must be
// in [1, batchCapacity]. No prediction buffer or heap allocation is needed.
// MAE/MSE and binary accuracy average over elements, including spatial outputs.
// Binary logits >= 0 predict 1 and targets must be exactly 0 or 1. Categorical
// accuracy requires [batch, classes] output and distribution targets summing to
// 1 within 1e-5; prediction and target argmax ties select the first class.
// Loss-specific target and shape rules also apply. Logits metrics and BCE loss
// reject a final sigmoid or softmax; CCE loss rejects a final softmax, including
// before trailing dropout/flatten. The caller must otherwise ensure outputs really
// are logits; this cannot be inferred.
//
// Inputs and targets may overlap each other, but must not overlap the model or
// compiled handle; the model and handle must also be disjoint. Model wiring and
// any externally rebound parameters/optimizer storage must be valid and disjoint
// from model scratch. All slices must have valid backing storage. Inputs, targets,
// options and shapes are preflighted before inference. On any failure returns
// ({}, false); a later forward/numerical failure may still overwrite model scratch.
// Inference leaves parameters, gradients, RNG and optimizer state unchanged, but
// invalidates borrowed predictions and pending backward state; do not run it
// concurrently with another operation on the model. Data loss excludes L2 and is
// aggregated in f64 from the existing f32 minibatch losses, as in batch evaluation.
// Those losses can round differently by batch size or overflow even when the f64
// metric is representable; a non-finite minibatch loss causes failure.
CompiledSequentialEvaluateMetrics :: proc(
	compiled: ^CompiledSequential($maxLayers, $maxWidth, $batchCapacity),
	inputs, targets: []f32,
	metric: SupervisedMetric,
	batchSize: int = 0,
) -> (SupervisedEvaluation, bool) {
	if compiled == nil || compiled.model == nil { return {}, false }
	model := compiled.model
	actualBatchSize := batchSize
	if actualBatchSize == 0 { actualBatchSize = batchCapacity }
	if model.self != rawptr(model) || model.layerCount <= 0 || model.layerCount > maxLayers ||
		model.inputWidth <= 0 || model.inputWidth > maxWidth || actualBatchSize <= 0 || actualBatchSize > batchCapacity ||
		len(inputs) == 0 || len(inputs) % model.inputWidth != 0 || raw_data(inputs) == nil || raw_data(targets) == nil {
		return {}, false
	}
	rows := len(inputs) / model.inputWidth
	output := &model.layers[model.layerCount-1]
	width := output.width
	if width <= 0 || width > maxWidth || len(targets) % width != 0 || len(targets) / width != rows {
		return {}, false
	}
	if !CompiledMetricsNodeValid(&model.input, &model.inputShape, model.inputData[:], model.inputGrad[:], model.inputWidth, batchCapacity) {
		return {}, false
	}
	for &layer in model.layers[:model.layerCount] {
		if layer.width <= 0 || layer.width > maxWidth ||
			!CompiledMetricsNodeValid(&layer.output, &layer.outputShape, layer.outputData[:], layer.outputGrad[:], layer.width, batchCapacity) {
			return {}, false
		}
	}

	// Only the two read-only data slices may overlap each other.
	ranges: [4]PPOFitMemoryRange
	ok: bool
	ranges[0], ok = PPOFitMemoryRangeOf(rawptr(model), 1, size_of(model^)); if !ok { return {}, false }
	ranges[1], ok = PPOFitMemoryRangeOf(rawptr(compiled), 1, size_of(compiled^)); if !ok { return {}, false }
	ranges[2], ok = PPOFitMemoryRangeOf(rawptr(raw_data(inputs)), len(inputs), size_of(f32)); if !ok { return {}, false }
	ranges[3], ok = PPOFitMemoryRangeOf(rawptr(raw_data(targets)), len(targets), size_of(f32)); if !ok { return {}, false }
	if PPOFitMemoryRangesOverlap(ranges[0], ranges[1]) { return {}, false }
	for i in 2..<len(ranges) {
		if PPOFitMemoryRangesOverlap(ranges[i], ranges[0]) || PPOFitMemoryRangesOverlap(ranges[i], ranges[1]) { return {}, false }
	}

	binaryMetric, categoricalMetric := false, false
	switch metric {
	case .MeanAbsoluteError, .MeanSquaredError:
	case .BinaryAccuracyWithLogits: binaryMetric = true
	case .CategoricalAccuracyWithLogits: categoricalMetric = true
	case: return {}, false
	}
	binaryLoss, categoricalLoss := false, false
	switch value in compiled.loss {
	case nil: return {}, false
	case MSE, MAE:
	case Huber:
		if !(value.delta > 0) || math.is_inf(value.delta) { return {}, false }
	case BCEWithLogits: binaryLoss = true
	case CCEWithLogits: categoricalLoss = true
	}
	if categoricalMetric || categoricalLoss {
		if len(output.output.value.shape) != 2 { return {}, false }
		shape := [2]int{rows, width}
		target := core.Tensor{shape[:], targets}
		if !CategoricalLogitsValid(target, target) { return {}, false }
	}
	if binaryMetric || categoricalMetric || binaryLoss || categoricalLoss {
		switch finalLayer in SequentialLogitsOutputLayer(model) {
		case ^Softmax: return {}, false
		case ^Sigmoid:
			if binaryMetric || categoricalMetric || binaryLoss { return {}, false }
		case nil, ^Dense, ^Conv2D, ^Pool2D, ^Flatten, ^Relu, ^Tanh, ^Dropout:
		}
	}
	for value in inputs { if math.is_nan(value) || math.is_inf(value) { return {}, false } }
	for value in targets {
		if math.is_nan(value) || math.is_inf(value) ||
			(binaryMetric && value != 0 && value != 1) ||
			(binaryLoss && (value < 0 || value > 1)) { return {}, false }
	}

	dataLoss, metricSum: f64
	correct := 0
	for start := 0; start < rows; {
		count := min(actualBatchSize, rows-start)
		prediction, predicted := SequentialPredict(model, inputs[start*model.inputWidth:(start+count)*model.inputWidth])
		if !predicted || len(prediction) != count*width { return {}, false }
		for value in prediction { if math.is_nan(value) || math.is_inf(value) { return {}, false } }
		labels := targets[start*width:(start+count)*width]
		predictionTensor := output.output.value
		targetTensor := core.Tensor{predictionTensor.shape, labels}
		batchLoss: f32
		switch value in compiled.loss {
		case nil: return {}, false
		case MSE: batchLoss, ok = MeanSquaredError(predictionTensor, targetTensor)
		case MAE: batchLoss, ok = MeanAbsoluteError(predictionTensor, targetTensor)
		case Huber: batchLoss, ok = HuberLoss(predictionTensor, targetTensor, value.delta)
		case BCEWithLogits: batchLoss, ok = BinaryCrossEntropyWithLogits(predictionTensor, targetTensor)
		case CCEWithLogits: batchLoss, ok = CategoricalCrossEntropyWithLogits(predictionTensor, targetTensor)
		}
		if !ok || math.is_nan(batchLoss) || math.is_inf(batchLoss) { return {}, false }
		dataLoss += f64(batchLoss) * f64(count) / f64(rows)
		switch metric {
		case .MeanAbsoluteError, .MeanSquaredError:
			for value, i in prediction {
				difference := f64(value) - f64(labels[i])
				if metric == .MeanAbsoluteError { metricSum += math.abs(difference) } else { metricSum += difference * difference }
			}
		case .BinaryAccuracyWithLogits:
			for value, i in prediction { if (value >= 0) == (labels[i] == 1) { correct += 1 } }
		case .CategoricalAccuracyWithLogits:
			for row in 0..<count {
				first := row*width
				predictedClass, targetClass := first, first
				for i in first+1..<first+width {
					if prediction[i] > prediction[predictedClass] { predictedClass = i }
					if labels[i] > labels[targetClass] { targetClass = i }
				}
				if predictedClass == targetClass { correct += 1 }
			}
		case: return {}, false
		}
		start += count
	}
	if categoricalMetric { metricSum = f64(correct) / f64(rows) } else if binaryMetric {
		metricSum = f64(correct) / f64(len(targets))
	} else {
		metricSum /= f64(len(targets))
	}
	if math.is_nan(dataLoss) || math.is_inf(dataLoss) || math.is_nan(metricSum) || math.is_inf(metricSum) { return {}, false }
	return SupervisedEvaluation{dataLoss, metricSum}, true
}

// SequentialPredict updates these inline nodes in place on every batch.
@(private="file")
CompiledMetricsNodeValid :: proc(node: ^core.Node, shape: ^[4]int, data, grad: []f32, width, capacity: int) -> bool {
	rank := len(node.value.shape)
	if (rank != 2 && rank != 4) || len(node.grad.shape) != rank ||
		raw_data(node.value.shape) != &shape[0] || raw_data(node.grad.shape) != &shape[0] ||
		width <= 0 || shape[0] <= 0 || shape[0] > capacity ||
		width > len(data)/shape[0] || width > len(grad)/shape[0] { return false }
	count := shape[0]*width
	if len(node.value.data) != count || len(node.grad.data) != count ||
		raw_data(node.value.data) != raw_data(data) || raw_data(node.grad.data) != raw_data(grad) ||
		!core.TensorValid(node.value) { return false }
	if rank == 2 { return shape[1] == width && shape[2] == 0 && shape[3] == 0 }
	return true
}
