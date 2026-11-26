package nn


PolicyEvaluationMode :: enum {
	Greedy,
	Stochastic,
}

// SequentialPolicyAction selects one legal categorical action from a single
// observation. Greedy mode is deterministic and ignores randomState; stochastic
// mode samples from the policy using the explicit nonzero RNG state. It runs in
// inference mode and does not update parameters, gradients, or optimizer state,
// but it does overwrite the model's ordinary forward-pass activation buffers.
// Observation, legal mask, RNG state, and model storage must be disjoint.
SequentialPolicyAction :: proc(
	policy: ^Sequential($maxLayers, $maxWidth, $batchCapacity),
	observation: []f32,
	legal: []bool,
	mode: PolicyEvaluationMode,
	randomState: ^u64 = nil,
) -> (action: int, logProbability: f64, ok: bool) {
	if policy == nil || policy.layerCount <= 0 || policy.layerCount > maxLayers ||
		len(observation) != policy.inputWidth || len(legal) == 0 ||
		(mode != .Greedy && mode != .Stochastic) {
		return 0, 0, false
	}
	if _, isSoftmax := SequentialLogitsOutputLayer(policy).(^Softmax); isSoftmax {
		return 0, 0, false
	}
	if _, predictOk := SequentialPredict(policy, observation, training = false); !predictOk {
		return 0, 0, false
	}
	logits := &policy.layers[policy.layerCount-1].output
	if len(logits.value.data) != len(legal) || !CategoricalPolicyValid(logits.value, legal) {
		return 0, 0, false
	}
	if mode == .Greedy {
		first := true
		for value, index in logits.value.data {
			if legal[index] && (first || value > logits.value.data[action]) {
				action = index
				first = false
			}
		}
		if first do return 0, 0, false
	} else {
		if randomState == nil do return 0, 0, false
		selected: [1]int
		if !CategoricalPolicySample(logits.value, legal, randomState, selected[:]) do return 0, 0, false
		action = selected[0]
	}
	logProbability, _ = PPOPolicyRowStats(logits.value.data, legal, action)
	return action, logProbability, PPOFiniteF64(logProbability)
}

// SequentialPolicyActions runs one inference pass for a batch of row-major
// observations and selects one masked categorical action per row. A stochastic
// call advances the supplied RNG once per row, after validation succeeds. It
// does not allocate or alter parameters/gradients, but overwrites model scratch.
// Inputs, outputs, RNG, and the complete model object must be disjoint.
SequentialPolicyActions :: proc(
	policy: ^Sequential($maxLayers, $maxWidth, $batchCapacity),
	observations: []f32,
	legalActions: []bool,
	mode: PolicyEvaluationMode,
	actions: []int,
	logProbabilities: []f64,
	randomState: ^u64 = nil,
) -> bool {
	if policy == nil || policy.self != rawptr(policy) || policy.layerCount <= 0 ||
		policy.layerCount > maxLayers || policy.inputWidth <= 0 || policy.inputWidth > maxWidth ||
		len(observations) == 0 || len(observations)%policy.inputWidth != 0 ||
		(mode != .Greedy && mode != .Stochastic) {
		return false
	}
	rows := len(observations)/policy.inputWidth
	actionCount := policy.layers[policy.layerCount-1].width
	if actionCount <= 0 || rows > max(int)/actionCount || len(legalActions) != rows*actionCount ||
		len(actions) != rows || len(logProbabilities) != rows ||
		(mode == .Stochastic && (randomState == nil || randomState^ == 0)) {
		return false
	}
	if _, isSoftmax := SequentialLogitsOutputLayer(policy).(^Softmax); isSoftmax do return false

	ranges: [6]PPOFitMemoryRange
	ok: bool
	ranges[0], ok = PPOFitMemoryRangeOf(rawptr(policy), 1, size_of(Sequential(maxLayers, maxWidth, batchCapacity))); if !ok do return false
	ranges[1], ok = PPOFitMemoryRangeOf(rawptr(raw_data(observations)), len(observations), size_of(f32)); if !ok do return false
	ranges[2], ok = PPOFitMemoryRangeOf(rawptr(raw_data(legalActions)), len(legalActions), size_of(bool)); if !ok do return false
	ranges[3], ok = PPOFitMemoryRangeOf(rawptr(raw_data(actions)), len(actions), size_of(int)); if !ok do return false
	ranges[4], ok = PPOFitMemoryRangeOf(rawptr(raw_data(logProbabilities)), len(logProbabilities), size_of(f64)); if !ok do return false
	randomCount := 0
	if randomState != nil { randomCount = 1 }
	ranges[5], ok = PPOFitMemoryRangeOf(rawptr(randomState), randomCount, size_of(u64)); if !ok do return false
	for index in 0..<len(ranges) {
		for previous in 0..<index {
			if PPOFitMemoryRangesOverlap(ranges[index], ranges[previous]) do return false
		}
	}

	if _, predictOk := SequentialPredict(policy, observations, training = false); !predictOk do return false
	logits := &policy.layers[policy.layerCount-1].output
	if !CategoricalPolicyValid(logits.value, legalActions) do return false
	state: u64
	if mode == .Stochastic { state = randomState^ }
	if mode == .Stochastic {
		if !CategoricalPolicySample(logits.value, legalActions, &state, actions) do return false
	} else {
		for row in 0..<rows {
			start := row*actionCount
			chosen := -1
			for action in 0..<actionCount {
				if legalActions[start+action] &&
					(chosen < 0 || logits.value.data[start+action] > logits.value.data[start+chosen]) {
					chosen = action
				}
			}
			if chosen < 0 do return false
			actions[row] = chosen
		}
	}
	for row in 0..<rows {
		start := row*actionCount
		maximum, _, logSum := CategoricalPolicyRowStats(
			logits.value.data[start:start+actionCount], legalActions[start:start+actionCount],
		)
		logProbabilities[row] = (f64(logits.value.data[start+actions[row]])-maximum)-logSum
	}
	if mode == .Stochastic { randomState^ = state }
	return true
}

