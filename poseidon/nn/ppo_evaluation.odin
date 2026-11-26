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

