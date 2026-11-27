package nn

import "../rl"
import "core:testing"

PPOValueLifetimeTestStorage :: struct {
	observations:        [10]f32,
	actions:             [5]int,
	rewards:             [5]f32,
	values:              [5]f32,
	nextValues:          [5]f32,
	oldLogProbabilities: [5]f64,
	legalActions:        [10]bool,
	terminated:          [5]bool,
	truncated:           [5]bool,
	advantages:          [5]f32,
	returns:             [5]f32,
}

PPOValueLifetimeStorage :: proc(backing: ^PPOValueLifetimeTestStorage) -> rl.RolloutStorage {
	return rl.RolloutStorage{
		observations = backing.observations[:], actions = backing.actions[:], rewards = backing.rewards[:],
		values = backing.values[:], nextValues = backing.nextValues[:], oldLogProbabilities = backing.oldLogProbabilities[:],
		legalActions = backing.legalActions[:], terminated = backing.terminated[:], truncated = backing.truncated[:],
		advantages = backing.advantages[:], returns = backing.returns[:],
	}
}

PPOValueLifetimeCheckRollout :: proc(
	t: ^testing.T,
	buffer: ^rl.RolloutBuffer,
	values, nextValues, advantages, returns: []f32,
) {
	testing.expect(t, buffer.count == len(values))
	if buffer.count != len(values) { return }
	for index in 0..<buffer.count {
		testing.expect(t, PPOTestNear(f64(buffer.storage.values[index]), f64(values[index]), 0.00001))
		testing.expect(t, PPOTestNear(f64(buffer.storage.nextValues[index]), f64(nextValues[index]), 0.00001))
	}
	// With gamma = lambda = 0.5, each GAE adds one quarter of the following advantage.
	gaeOk := rl.RolloutComputeGAE(buffer, 0.5, 0.5)
	testing.expect(t, gaeOk)
	if !gaeOk { return }
	for index in 0..<buffer.count {
		testing.expect(t, PPOTestNear(f64(buffer.storage.advantages[index]), f64(advantages[index]), 0.00001))
		testing.expect(t, PPOTestNear(f64(buffer.storage.returns[index]), f64(returns[index]), 0.00001))
	}
}

@(test)
PPOCheckpointCollectPreservesCurrentValue :: proc(t: ^testing.T) {
	policy, value: Sequential(1, 2, 2)
	state: PPOTrainingState
	setup := SequentialInit(&policy, 1, 7) && SequentialAddDense(&policy, 2) &&
		SequentialInit(&value, 1, 11) && SequentialAddDense(&value, 1) && PPOTrainingStateInit(&state, 123, 456)
	testing.expect(t, setup)
	if !setup { return }
	policyDense := TestDenseStorage(&policy.layers[0])
	policyDense.weightData[0], policyDense.weightData[1] = 0, 0
	policyDense.biasData[0], policyDense.biasData[1] = -100, 100
	valueDense := TestDenseStorage(&value.layers[0])
	valueDense.weightData[0], valueDense.biasData[0] = 3, 1 // V(x) = 3x + 1.

	backing: PPOValueLifetimeTestStorage
	buffer: rl.RolloutBuffer
	initialized := PPOCheckpointTestBufferInit(&buffer, PPOValueLifetimeStorage(&backing))
	collected := initialized && PPOCheckpointTestCollect(&policy, &value, &state, &buffer)
	testing.expect(t, collected)
	if !collected { return }
	for index in 0..<buffer.count {
		testing.expect(t, backing.actions[index] == 1 && PPOTestNear(f64(backing.rewards[index]), 0.2))
	}
	values := [4]f32{1, 2.5, 4, 1}
	nextValues := [4]f32{2, 3, 4, 0}
	advantages := [4]f32{-0.125, -1.3, -2, -0.8}
	returns := [4]f32{0.875, 1.2, 2, 0.2}
	testing.expect(t, values[0] != nextValues[0] && values[1] != nextValues[1])
	PPOValueLifetimeCheckRollout(t, &buffer, values[:], nextValues[:], advantages[:], returns[:])
}

@(test)
PPOSequentialCollectPreservesCurrentValue :: proc(t: ^testing.T) {
	policy, value: Sequential(1, 2, 3)
	setup := SequentialInit(&policy, 2, 7) && SequentialAddDense(&policy, 2) &&
		SequentialInit(&value, 2, 11) && SequentialAddDense(&value, 1)
	testing.expect(t, setup)
	if !setup { return }
	valueDense := TestDenseStorage(&value.layers[0])
	valueDense.weightData[0], valueDense.weightData[1], valueDense.biasData[0] = 4, 0, 1 // V(x, 1) = 4x + 1.

	backing: PPOValueLifetimeTestStorage
	buffer: rl.RolloutBuffer
	initialized := rl.RolloutBufferInit(&buffer, PPOValueLifetimeStorage(&backing), 5, 2, 2)
	collected := initialized && PPOSequentialTestCollect(&policy, &value, &buffer)
	testing.expect(t, collected)
	if !collected { return }
	values := [5]f32{1, 2, 3, 4, 5}
	nextValues := [5]f32{1.4, 2.4, 3.4, 4.4, 0}
	advantages := [5]f32{-0.36328125, -0.253125, -1.8125, -2.05, -5}
	returns := [5]f32{0.63671875, 1.746875, 1.1875, 1.95, 0}
	testing.expect(t, values[0] != nextValues[0] && values[1] != nextValues[1])
	PPOValueLifetimeCheckRollout(t, &buffer, values[:], nextValues[:], advantages[:], returns[:])
}
