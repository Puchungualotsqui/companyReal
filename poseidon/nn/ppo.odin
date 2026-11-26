package nn

import "../core"
import "core:math"

PPOConfig :: struct {
	clipRange:          f32, // Probability-ratio clipping epsilon in [0, 1)
	entropyCoefficient: f32, // Entropy bonus weight; nonnegative
	valueCoefficient:   f32, // Critic loss weight; nonnegative
	valueHuberDelta:    f32, // Positive Huber threshold for value error
}

PPOStats :: struct {
	policyLoss:    f64, // Mean negative clipped surrogate
	valueLoss:     f64, // Mean Huber critic loss, before valueCoefficient
	entropy:       f64, // Mean categorical entropy in nats
	approximateKL: f64, // Mean old log probability minus new log probability
	clipFraction:  f64, // Fraction of ratios outside the clip interval
	totalLoss:     f64, // Weighted objective minimized by the update
	gradientNorm:     f64, // Global norm before clipping; zero for objective-only evaluation
	gradientClipped:  bool, // Whether the training step applied gradient clipping
}

PPOConfigValid :: proc(config: PPOConfig) -> bool {
	return !math.is_nan(config.clipRange) && !math.is_inf(config.clipRange) &&
		config.clipRange >= 0 && config.clipRange < 1 &&
		!math.is_nan(config.entropyCoefficient) && !math.is_inf(config.entropyCoefficient) &&
		config.entropyCoefficient >= 0 &&
		!math.is_nan(config.valueCoefficient) && !math.is_inf(config.valueCoefficient) &&
		config.valueCoefficient >= 0 &&
		!math.is_nan(config.valueHuberDelta) && !math.is_inf(config.valueHuberDelta) &&
		config.valueHuberDelta > 0
}

PPOFiniteF64 :: proc(value: f64) -> bool {
	return !math.is_nan(value) && !math.is_inf(value)
}

PPOPolicyRowStats :: proc(logits: []f32, legalMask: []bool, action: int) -> (logProbability, entropy: f64) {
	maximum, _, logSum := CategoricalPolicyRowStats(logits, legalMask)
	logProbability = (f64(logits[action])-maximum)-logSum
	for value, index in logits {
		if legalMask[index] {
			actionLogProbability := (f64(value)-maximum)-logSum
			probability := math.exp(actionLogProbability)
			entropy -= probability*actionLogProbability
		}
	}
	return
}

PPOPolicyInputsValid :: proc(
	logits: core.Tensor,
	actions: []int,
	legal: []bool,
	oldLogProbabilities: []f64,
	advantages: []f32,
	clipRange: f32,
) -> bool {
	if !CategoricalPolicyValid(logits, legal) || len(logits.data) == 0 ||
		math.is_nan(clipRange) || math.is_inf(clipRange) || clipRange < 0 || clipRange >= 1 {
		return false
	}
	width := logits.shape[len(logits.shape)-1]
	rows := len(logits.data)/width
	if len(actions) != rows || len(oldLogProbabilities) != rows || len(advantages) != rows { return false }
	for oldLogProbability, row in oldLogProbabilities {
		if !PPOFiniteF64(oldLogProbability) || math.is_nan(advantages[row]) || math.is_inf(advantages[row]) {
			return false
		}
		action := actions[row]
		if action < 0 || action >= width || !legal[row*width+action] { return false }
	}
	return true
}

PPOLogRatioClipped :: proc(logRatio, clipRange: f64) -> bool {
	lowerLog := math.ln(1-clipRange)
	upperLog := math.ln(1+clipRange)
	return logRatio < lowerLog || logRatio > upperLog
}

PPOPolicyRatio :: proc(logRatio, advantage, clipRange: f64) -> (ratio, surrogate: f64, clipped: bool, ok: bool) {
	lower, upper := 1-clipRange, 1+clipRange
	lowerLog, upperLog := math.ln(lower), math.ln(upper)
	if advantage > 0 && logRatio > upperLog {
		return upper, upper*advantage, true, true
	}
	if advantage < 0 && logRatio < lowerLog {
		return lower, lower*advantage, true, true
	}
	if advantage == 0 { return 1, 0, PPOLogRatioClipped(logRatio, clipRange), true }
	if logRatio > 709.78 { return 0, 0, false, false }
	ratio = math.exp(logRatio)
	surrogate = ratio*advantage
	return ratio, surrogate, PPOLogRatioClipped(logRatio, clipRange), PPOFiniteF64(ratio) && PPOFiniteF64(surrogate)
}

// PPOPolicyObjective returns the mean negative clipped surrogate, entropy,
// approximateKL, clip fraction, and validity. The legal mask excludes invalid
// actions from both the policy distribution and entropy.
PPOPolicyObjective :: proc(
	logits: core.Tensor,
	actions: []int,
	legal: []bool,
	oldLogProbabilities: []f64,
	advantages: []f32,
	clipRange: f32,
) -> (policyLoss, entropy, approximateKL, clipFraction: f64, ok: bool) {
	if !PPOPolicyInputsValid(logits, actions, legal, oldLogProbabilities, advantages, clipRange) {
		return 0, 0, 0, 0, false
	}
	width := logits.shape[len(logits.shape)-1]
	rows := len(actions)
	lowerLog, upperLog := math.ln(1-f64(clipRange)), math.ln(1+f64(clipRange))
	policyTotal, entropyTotal, klTotal: f64
	clippedRows := 0
	for action, row in actions {
		start := row*width
		newLogProbability, rowEntropy := PPOPolicyRowStats(
			logits.data[start:start+width], legal[start:start+width], action,
		)
		logRatio := newLogProbability-oldLogProbabilities[row]
		if !PPOFiniteF64(logRatio) || !PPOFiniteF64(rowEntropy) { return 0, 0, 0, 0, false }
		_, surrogate, _, ratioOk := PPOPolicyRatio(logRatio, f64(advantages[row]), f64(clipRange))
		if !ratioOk { return 0, 0, 0, 0, false }
		policyTotal -= surrogate
		entropyTotal += rowEntropy
		klTotal += oldLogProbabilities[row]-newLogProbability
		if logRatio < lowerLog || logRatio > upperLog { clippedRows += 1 }
	}
	rows64 := f64(rows)
	policyLoss = policyTotal/rows64
	entropy = entropyTotal/rows64
	approximateKL = klTotal/rows64
	clipFraction = f64(clippedRows)/rows64
	ok = PPOFiniteF64(policyLoss) && PPOFiniteF64(entropy) &&
		PPOFiniteF64(approximateKL) && PPOFiniteF64(clipFraction)
	return
}

// PPOPolicyObjectiveBackward accumulates the derivative of policyLoss minus
// entropyCoefficient times entropy into logits.grad. Illegal actions contribute
// no gradient. Validation and a dry run precede writes; existing gradients must
// be finite, and value/gradient storage plus inputs must be disjoint.
PPOPolicyObjectiveBackward :: proc(
	logits: ^core.Node,
	actions: []int,
	legal: []bool,
	oldLogProbabilities: []f64,
	advantages: []f32,
	clipRange, entropyCoefficient: f32,
) -> bool {
	if logits == nil || !core.TensorValid(logits.value) || !core.TensorValid(logits.grad) ||
		!core.SameShape(logits.value, logits.grad) || core.BuffersOverlap(logits.value, logits.grad) ||
		math.is_nan(entropyCoefficient) || math.is_inf(entropyCoefficient) || entropyCoefficient < 0 {
		return false
	}
	if _, _, _, _, ok := PPOPolicyObjective(logits.value, actions, legal, oldLogProbabilities, advantages, clipRange); !ok {
		return false
	}
	for value in logits.grad.data {
		if math.is_nan(value) || math.is_inf(value) { return false }
	}
	width := logits.value.shape[len(logits.value.shape)-1]
	rows := len(actions)
	lowerLog, upperLog := math.ln(1-f64(clipRange)), math.ln(1+f64(clipRange))
	for pass in 0..<2 {
		for action, row in actions {
			start := row*width
			newLogProbability, rowEntropy := PPOPolicyRowStats(
				logits.value.data[start:start+width], legal[start:start+width], action,
			)
			logRatio := newLogProbability-oldLogProbabilities[row]
			advantage := f64(advantages[row])
			ratio, _, _, ratioOk := PPOPolicyRatio(logRatio, advantage, f64(clipRange))
			if !ratioOk { return false }
			policyActive := !(advantage > 0 && logRatio > upperLog) &&
				!(advantage < 0 && logRatio < lowerLog) && advantage != 0
			maximum, _, logSum := CategoricalPolicyRowStats(
				logits.value.data[start:start+width], legal[start:start+width],
			)
			for index in 0..<width {
				if !legal[start+index] do continue
				value := f64(logits.value.data[start+index])
				logProbability := (value-maximum)-logSum
				probability := math.exp(logProbability)
				gradient: f64
				if policyActive {
					gradient += advantage*ratio*(probability-boolToF64(index == action))/f64(rows)
				}
				gradient += f64(entropyCoefficient)*probability*(logProbability+rowEntropy)/f64(rows)
				result := f64(logits.grad.data[start+index])+gradient
				if !PPOFiniteF64(result) || math.abs(result) > 3.4028234663852886e+38 { return false }
				if pass == 1 { logits.grad.data[start+index] = f32(result) }
			}
		}
	}
	return true
}

boolToF64 :: proc(value: bool) -> f64 {
	if value { return 1 }
	return 0
}

// PPOComputeObjectives evaluates the clipped actor objective, Huber critic loss,
// entropy bonus, approximate KL, clip fraction, and combined loss. Critic values
// must have shape [rows, 1]; all data is borrowed and left unchanged.
PPOComputeObjectives :: proc(
	logits: core.Tensor,
	values: core.Tensor,
	actions: []int,
	legal: []bool,
	oldLogProbabilities: []f64,
	advantages, returns: []f32,
	config: PPOConfig,
) -> (PPOStats, bool) {
	if !PPOConfigValid(config) || len(values.shape) != 2 || values.shape[1] != 1 ||
		!core.TensorValid(values) || len(values.data) != len(actions) ||
		len(returns) != len(actions) || len(advantages) != len(actions) {
		return {}, false
	}
	policyLoss, entropy, approximateKL, clipFraction, ok := PPOPolicyObjective(
		logits, actions, legal, oldLogProbabilities, advantages, config.clipRange,
	)
	if !ok { return {}, false }
	for value in values.data { if math.is_nan(value) || math.is_inf(value) { return {}, false } }
	for target in returns { if math.is_nan(target) || math.is_inf(target) { return {}, false } }
	valueTarget := core.Tensor{shape = values.shape, data = returns}
	valueLoss, valueOk := HuberLoss(values, valueTarget, config.valueHuberDelta)
	if !valueOk { return {}, false }
	totalLoss := policyLoss + f64(config.valueCoefficient)*f64(valueLoss) - f64(config.entropyCoefficient)*entropy
	if !PPOFiniteF64(totalLoss) { return {}, false }
	return PPOStats{
		policyLoss = policyLoss,
		valueLoss = f64(valueLoss),
		entropy = entropy,
		approximateKL = approximateKL,
		clipFraction = clipFraction,
		totalLoss = totalLoss,
	}, true
}
