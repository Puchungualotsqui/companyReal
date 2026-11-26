package nn

import "../core"
import "core:math"
import "core:testing"

PPOTestNear :: proc(a, b: f64, tolerance: f64 = 0.0001) -> bool {
	return math.abs(a-b) <= tolerance
}

@(test)
PPOPolicyClippingAndEntropy :: proc(t: ^testing.T) {
	shape := [2]int{1, 2}
	logits := [2]f32{1.38629436, 0}
	actions := [1]int{0}
	legal := [2]bool{true, true}
	oldLogProbabilities := [1]f64{-0.6931471805599453}
	positiveAdvantage := [1]f32{1}
	policyLoss, entropy, approximateKL, clipFraction, ok := PPOPolicyObjective(
		core.Tensor{shape[:], logits[:]}, actions[:], legal[:], oldLogProbabilities[:], positiveAdvantage[:], 0.2,
	)
	expectedEntropy := -(0.8*math.ln(0.8)+0.2*math.ln(0.2))
	testing.expect(t, ok && PPOTestNear(policyLoss, -1.2) && PPOTestNear(entropy, expectedEntropy))
	testing.expect(t, PPOTestNear(approximateKL, -0.4700036292457356) && clipFraction == 1)

	negativeAdvantage := [1]f32{-1}
	policyLoss, _, _, clipFraction, ok = PPOPolicyObjective(
		core.Tensor{shape[:], logits[:]}, actions[:], legal[:], oldLogProbabilities[:], negativeAdvantage[:], 0.2,
	)
	testing.expect(t, ok && PPOTestNear(policyLoss, 1.6) && clipFraction == 1)

	logits = {-1.38629436, 0}
	policyLoss, _, _, _, ok = PPOPolicyObjective(
		core.Tensor{shape[:], logits[:]}, actions[:], legal[:], oldLogProbabilities[:], negativeAdvantage[:], 0.2,
	)
	testing.expect(t, ok && PPOTestNear(policyLoss, 0.8))
}

@(test)
PPOPolicyClippedGradient :: proc(t: ^testing.T) {
	shape := [2]int{1, 2}
	values := [2]f32{1.38629436, 0}
	gradients: [2]f32
	node := core.Node{value = core.Tensor{shape[:], values[:]}, grad = core.Tensor{shape[:], gradients[:]}}
	actions := [1]int{0}
	legal := [2]bool{true, true}
	oldLogProbabilities := [1]f64{-0.6931471805599453}
	positive := [1]f32{1}
	testing.expect(t, PPOPolicyObjectiveBackward(&node, actions[:], legal[:], oldLogProbabilities[:], positive[:], 0.2, 0))
	testing.expect(t, gradients == [2]f32{})

	values = {-1.38629436, 0}
	negative := [1]f32{-1}
	testing.expect(t, PPOPolicyObjectiveBackward(&node, actions[:], legal[:], oldLogProbabilities[:], negative[:], 0.2, 0))
	testing.expect(t, gradients == [2]f32{})
}

@(test)
PPOPolicyGradientNumerical :: proc(t: ^testing.T) {
	shape := [1]int{3}
	values := [3]f32{0.3, -0.4, 1000}
	gradients: [3]f32
	node := core.Node{
		value = core.Tensor{shape[:], values[:]},
		grad = core.Tensor{shape[:], gradients[:]},
	}
	actions := [1]int{0}
	legal := [3]bool{true, true, false}
	advantages := [1]f32{0.7}
	oldLogProbabilities: [1]f64
	testing.expect(t, CategoricalPolicyLogProbs(node.value, legal[:], actions[:], oldLogProbabilities[:]))
	entropyCoefficient: f32 = 0.05
	testing.expect(t, PPOPolicyObjectiveBackward(
		&node, actions[:], legal[:], oldLogProbabilities[:], advantages[:], 0.2, entropyCoefficient,
	))

	for index in 0..<len(values) {
		original := values[index]
		values[index] = original+0.001
		plusLoss, plusEntropy, _, _, plusOk := PPOPolicyObjective(
			node.value, actions[:], legal[:], oldLogProbabilities[:], advantages[:], 0.2,
		)
		values[index] = original-0.001
		minusLoss, minusEntropy, _, _, minusOk := PPOPolicyObjective(
			node.value, actions[:], legal[:], oldLogProbabilities[:], advantages[:], 0.2,
		)
		values[index] = original
		plus := plusLoss-f64(entropyCoefficient)*plusEntropy
		minus := minusLoss-f64(entropyCoefficient)*minusEntropy
		numerical := (plus-minus)/0.002
		testing.expect(t, plusOk && minusOk && PPOTestNear(f64(gradients[index]), numerical, 0.0005))
	}
	testing.expect(t, gradients[2] == 0)
}

@(test)
PPOCombinedObjectives :: proc(t: ^testing.T) {
	logitShape := [2]int{1, 2}
	logits := [2]f32{1.38629436, 0}
	valueShape := [2]int{1, 1}
	values := [1]f32{1.5}
	actions := [1]int{0}
	legal := [2]bool{true, true}
	oldLogProbabilities := [1]f64{-0.6931471805599453}
	advantages := [1]f32{1}
	returns := [1]f32{0}
	config := PPOConfig{0.2, 0.1, 0.5, 1}
	stats, ok := PPOComputeObjectives(
		core.Tensor{logitShape[:], logits[:]}, core.Tensor{valueShape[:], values[:]},
		actions[:], legal[:], oldLogProbabilities[:], advantages[:], returns[:], config,
	)
	expectedEntropy := -(0.8*math.ln(0.8)+0.2*math.ln(0.2))
	testing.expect(t, ok && PPOTestNear(stats.policyLoss, -1.2) && PPOTestNear(stats.valueLoss, 1))
	testing.expect(t, PPOTestNear(stats.entropy, expectedEntropy))
	testing.expect(t, PPOTestNear(stats.totalLoss, -1.2+0.5-0.1*expectedEntropy))
	config.clipRange = 1
	_, ok = PPOComputeObjectives(
		core.Tensor{logitShape[:], logits[:]}, core.Tensor{valueShape[:], values[:]},
		actions[:], legal[:], oldLogProbabilities[:], advantages[:], returns[:], config,
	)
	testing.expect(t, !ok)
}

@(test)
SequentialPPOActorCriticUpdate :: proc(t: ^testing.T) {
	policy, value: Sequential(1, 2, 4)
	policyOk := SequentialInit(&policy, 1, 7) && SequentialAddDense(&policy, 2)
	valueOk := SequentialInit(&value, 1, 11) && SequentialAddDense(&value, 1)
	testing.expect(t, policyOk && valueOk)
	if !policyOk || !valueOk { return }

	observations := [4]f32{-1, 0, 1, 2}
	actions := [4]int{0, 1, 0, 1}
	legal := [8]bool{true, true, true, true, true, true, true, true}
	advantages := [4]f32{1, -1, 0.5, -0.5}
	returns := [4]f32{0.5, -0.5, 1, -1}
	oldLogProbabilities: [4]f64
	logits, predictOk := SequentialPredict(&policy, observations[:])
	testing.expect(t, predictOk)
	if !predictOk { return }
	testing.expect(t, CategoricalPolicyLogProbs(
		policy.layers[0].output.value, legal[:], actions[:], oldLogProbabilities[:],
	))

	policyParameterStorage: [2]^core.Node
	valueParameterStorage: [2]^core.Node
	policyParameters, policyParamsOk := SequentialParameters(&policy, policyParameterStorage[:])
	valueParameters, valueParamsOk := SequentialParameters(&value, valueParameterStorage[:])
	testing.expect(t, policyParamsOk && valueParamsOk && len(policyParameters) == 2 && len(valueParameters) == 2)
	if !policyParamsOk || !valueParamsOk { return }
	combinedParameters: [4]^core.Node
	copy(combinedParameters[:2], policyParameters)
	copy(combinedParameters[2:], valueParameters)
	firstMoment, secondMoment: [6]f32
	adam: Adam
	testing.expect(t, AdamInit(&adam, combinedParameters[:], firstMoment[:], secondMoment[:], learningRate = 0.01))

	before: [6]f32
	parameterIndex := 0
	for parameter in combinedParameters {
		for weight in parameter.value.data {
			before[parameterIndex] = weight
			parameterIndex += 1
		}
	}
	config := PPOConfig{0.2, 0.01, 0.5, 1}

	stats, ok := SequentialPPOTrainStep(
		&policy, &value, observations[:], actions[:], legal[:], oldLogProbabilities[:],
		advantages[:], returns[:], config, &adam,
	)

	testing.expect(t, ok && adam.step == 1 && PPOFiniteF64(stats.totalLoss) && stats.entropy > 0)
	if !ok { return }
	changed := false
	parameterIndex = 0
	for parameter in combinedParameters {
		for weight in parameter.value.data {
			if weight != before[parameterIndex] { changed = true }
			parameterIndex += 1
		}
	}
	testing.expect(t, changed)

	adam.parameters = valueParameters
	stepBefore := adam.step
	weightBefore := value.layers[0].storage.(DenseStorage(2)).weightData
	_, ok = SequentialPPOTrainStep(
		&policy, &value, observations[:], actions[:], legal[:], oldLogProbabilities[:],
		advantages[:], returns[:], config, &adam,
	)
	testing.expect(t, !ok && adam.step == stepBefore && value.layers[0].storage.(DenseStorage(2)).weightData == weightBefore)
}
