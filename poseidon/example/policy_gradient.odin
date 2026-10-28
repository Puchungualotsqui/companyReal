package main

import "../core"
import "../nn"
import "core:fmt"

// Run with: odin run example/policy_gradient.odin -file
main :: proc() {
	// A one-step bandit: action 0 pays 1, action 1 pays 0, action 2 is unavailable.
	rewards := [3]f32{1, 0, 0}
	legal := [3]bool{true, true, false}
	baseline: f32 = 0.5

	// One constant observation produces three logits. All tensor and gradient
	// storage is caller-owned; the training loop does not allocate on the heap.
	inputShape := [2]int{1, 1}
	weightShape := [2]int{1, 3}
	biasShape := [1]int{3}
	outputShape := [2]int{1, 3}
	inputData := [1]f32{1}
	inputGrad: [1]f32
	weightData, weightGrad: [3]f32
	biasData, biasGrad: [3]f32
	logitData, logitGrad: [3]f32
	input := core.Node{value = core.Tensor{inputShape[:], inputData[:]}, grad = core.Tensor{inputShape[:], inputGrad[:]}}
	weights := core.Node{value = core.Tensor{weightShape[:], weightData[:]}, grad = core.Tensor{weightShape[:], weightGrad[:]}}
	bias := core.Node{value = core.Tensor{biasShape[:], biasData[:]}, grad = core.Tensor{biasShape[:], biasGrad[:]}}
	logits := core.Node{value = core.Tensor{outputShape[:], logitData[:]}, grad = core.Tensor{outputShape[:], logitGrad[:]}}
	dense := nn.Dense{&input, &weights, &bias, &logits}
	layers := [1]nn.Layer{&dense}
	model := nn.Model{layers[:]}
	nodes := [4]^core.Node{&input, &weights, &bias, &logits}
	parameters := [2]^core.Node{&weights, &bias}
	optimizer := nn.SequentialSGD{0.1}

	actions: [1]int
	advantages: [1]f32
	probabilities: [3]f32
	randomState: u64 = 42 // Nonzero seed makes the action sequence reproducible.
	assert(nn.ModelForward(model))
	assert(nn.CategoricalPolicyProbabilities(logits.value, legal[:], probabilities[:]))
	fmt.printf("Initial logits: %v, legal probabilities: %v\n", logitData, probabilities)

	// Each sample is a complete episode; the fixed baseline gives signed advantages.
	firstAction: int
	firstReward, firstAdvantage: f32
	for step in 0..<500 {
		assert(nn.ModelForward(model))
		assert(nn.CategoricalPolicySample(logits.value, legal[:], &randomState, actions[:]))
		reward := rewards[actions[0]]
		advantages[0] = reward - baseline
		if step == 0 {
			firstAction, firstReward, firstAdvantage = actions[0], reward, advantages[0]
		}
		_, ok := nn.PolicyTrainStep(model, &logits, actions[:], legal[:], advantages[:], nodes[:], parameters[:], optimizer)
		assert(ok)
	}

	fmt.printf("First sample: action %d, reward %.0f, advantage %.1f\n", firstAction, firstReward, firstAdvantage)
	assert(nn.ModelForward(model))
	assert(nn.CategoricalPolicyProbabilities(logits.value, legal[:], probabilities[:]))
	fmt.printf("After 500 episodes, logits: %v, legal probabilities: %v\n", logitData, probabilities)
	fmt.printf("Probability of reward 1: %.4f\n", probabilities[0])
}
