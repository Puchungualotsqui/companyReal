package nn

import "core:testing"

@(test)
SequentialPolicyActionGreedyAndSeededSampling :: proc(t: ^testing.T) {
	policy: Sequential(1, 2, 2)
	ok := SequentialInit(&policy, 1, 7) && SequentialAddDense(&policy, 2)
	testing.expect(t, ok)
	if !ok { return }
	storage := &policy.layers[0].storage.(DenseStorage(2))
	storage.weightData[0], storage.weightData[1] = 0, 0
	storage.biasData[0], storage.biasData[1] = -1, 1
	observation := [1]f32{0.5}
	legal := [2]bool{true, true}
	policyWeightsBefore := [2]f32{storage.weightData[0], storage.weightData[1]}
	policyBiasBefore := [2]f32{storage.biasData[0], storage.biasData[1]}

	greedyRandomState: u64 = 77
	greedyAction, greedyLogProbability, greedyOk := SequentialPolicyAction(
		&policy, observation[:], legal[:], .Greedy, &greedyRandomState,
	)
	testing.expect(t, greedyOk && greedyAction == 1 && greedyLogProbability < 0)
	testing.expect(t,
		greedyRandomState == 77 && [2]f32{storage.weightData[0], storage.weightData[1]} == policyWeightsBefore &&
		[2]f32{storage.biasData[0], storage.biasData[1]} == policyBiasBefore,
	)

	firstState, secondState: u64 = 9182, 9182
	firstAction, firstLogProbability, firstOk := SequentialPolicyAction(
		&policy, observation[:], legal[:], .Stochastic, &firstState,
	)
	secondAction, secondLogProbability, secondOk := SequentialPolicyAction(
		&policy, observation[:], legal[:], .Stochastic, &secondState,
	)
	testing.expect(t, firstOk && secondOk && firstAction == secondAction && firstLogProbability == secondLogProbability)
	testing.expect(t, firstState == secondState && firstState != 9182)
	onlyFirstLegal := [2]bool{true, false}
	action, _, maskedOk := SequentialPolicyAction(&policy, observation[:], onlyFirstLegal[:], .Greedy)
	testing.expect(t, maskedOk && action == 0)
}

@(test)
SequentialPolicyActionsBatchedGreedyAndSeededSampling :: proc(t: ^testing.T) {
	policy: Sequential(1, 2, 3)
	initialized := SequentialInit(&policy, 1, 17) && SequentialAddDense(&policy, 2)
	testing.expect(t, initialized)
	if !initialized { return }
	storage := &policy.layers[0].storage.(DenseStorage(2))
	storage.weightData[0], storage.weightData[1] = 0, 0
	storage.biasData[0], storage.biasData[1] = -1, 1
	observations := [3]f32{0, 1, 2}
	legal := [6]bool{true, true, true, false, false, true}
	actions: [3]int
	logProbabilities: [3]f64
	greedyRng: u64 = 81
	greedyOk := SequentialPolicyActions(
		&policy, observations[:], legal[:], .Greedy, actions[:], logProbabilities[:], &greedyRng,
	)
	testing.expect(t, greedyOk && actions == [3]int{1, 0, 1} && greedyRng == 81)
	testing.expect(t, greedyOk && logProbabilities[0] < 0 && logProbabilities[1] == 0 && logProbabilities[2] == 0)

	firstActions, secondActions: [3]int
	firstLogProbabilities, secondLogProbabilities: [3]f64
	firstRng, secondRng: u64 = 9123, 9123
	firstOk := SequentialPolicyActions(
		&policy, observations[:], legal[:], .Stochastic, firstActions[:], firstLogProbabilities[:], &firstRng,
	)
	secondOk := SequentialPolicyActions(
		&policy, observations[:], legal[:], .Stochastic, secondActions[:], secondLogProbabilities[:], &secondRng,
	)
	testing.expect(t,
		firstOk && secondOk && firstActions == secondActions && firstLogProbabilities == secondLogProbabilities &&
		firstRng == secondRng && firstRng != 9123,
	)
	for action, row in firstActions { testing.expect(t, legal[row*2+action]) }

	invalidLegal := [6]bool{true, true, false, false, false, true}
	beforeActions, beforeLogs, beforeRng := firstActions, firstLogProbabilities, firstRng
	invalidOk := SequentialPolicyActions(
		&policy, observations[:], invalidLegal[:], .Stochastic,
		firstActions[:], firstLogProbabilities[:], &firstRng,
	)
	testing.expect(t, !invalidOk && firstActions == beforeActions && firstLogProbabilities == beforeLogs && firstRng == beforeRng)
}
