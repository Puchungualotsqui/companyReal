package rl

import "core:math"
import "core:testing"

BatchedRolloutTestStorage :: struct {
	observations:        [6]f32,
	actions:             [6]int,
	rewards:             [6]f32,
	values:              [6]f32,
	nextValues:          [6]f32,
	oldLogProbabilities: [6]f64,
	legalActions:        [12]bool,
	terminated:          [6]bool,
	truncated:           [6]bool,
	advantages:          [6]f32,
	returns:             [6]f32,
	environmentIndices:  [6]int,
	followingValues:     [2]f64,
	hasFollowing:        [2]bool,
}

BatchedRolloutTestInit :: proc(backing: ^BatchedRolloutTestStorage, capacity := 6) -> (BatchedRolloutBuffer, bool) {
	storage := BatchedRolloutStorage{
		transitions = RolloutStorage{
			observations = backing.observations[:], actions = backing.actions[:],
			rewards = backing.rewards[:], values = backing.values[:], nextValues = backing.nextValues[:],
			oldLogProbabilities = backing.oldLogProbabilities[:], legalActions = backing.legalActions[:],
			terminated = backing.terminated[:], truncated = backing.truncated[:],
			advantages = backing.advantages[:], returns = backing.returns[:],
		},
		environmentIndices = backing.environmentIndices[:],
	}
	buffer: BatchedRolloutBuffer
	ok := BatchedRolloutBufferInit(&buffer, storage, capacity, 2, 1, 2)
	return buffer, ok
}

BatchedRolloutTestAppend :: proc(
	buffer: ^BatchedRolloutBuffer,
	environment: int,
	observation, reward, value, nextValue: f32,
	terminated := false,
	truncated := false,
) -> bool {
	observationRow := [1]f32{observation}
	legal := [2]bool{true, true}
	return BatchedRolloutBufferAppend(buffer, environment, RolloutTransition{
		observation = observationRow[:], action = 0, reward = reward,
		value = value, nextValue = nextValue, oldLogProbability = -0.5,
		legalActions = legal[:], terminated = terminated, truncated = truncated,
	})
}

BatchedRolloutTestScratch :: proc(backing: ^BatchedRolloutTestStorage) -> BatchedRolloutReturnScratch {
	return BatchedRolloutReturnScratch{backing.followingValues[:], backing.hasFollowing[:]}
}

BatchedRolloutTestPopulate :: proc(buffer: ^BatchedRolloutBuffer) -> bool {
	return BatchedRolloutTestAppend(buffer, 0, 0, 1, 0.5, 1) &&
		BatchedRolloutTestAppend(buffer, 1, 1, 10, 4, 5) &&
		BatchedRolloutTestAppend(buffer, 0, 0.5, 2, 1, 2, terminated = true) &&
		BatchedRolloutTestAppend(buffer, 1, 1.5, 20, 5, 7, truncated = true) &&
		BatchedRolloutTestAppend(buffer, 1, 2, 3, 2, 4)
}

@(test)
BatchedRolloutGAESeparatesInterleavedEnvironments :: proc(t: ^testing.T) {
	backing: BatchedRolloutTestStorage
	buffer, initOk := BatchedRolloutTestInit(&backing, 5)
	appendOk := initOk && BatchedRolloutTestPopulate(&buffer)
	testing.expect(t, appendOk && buffer.rollout.count == 5 && BatchedRolloutBufferFull(&buffer))
	if !appendOk { return }
	testing.expect(t, !BatchedRolloutBufferAppend(&buffer, 2, {}))
	scratch := BatchedRolloutTestScratch(&backing)
	testing.expect(t, BatchedRolloutComputeGAE(&buffer, 0.9, 0.8, scratch))
	expectedAdvantages := [5]f32{2.12, 25.836, 1, 21.3, 4.6}
	expectedReturns := [5]f32{2.62, 29.836, 2, 26.3, 6.6}
	for index in 0..<5 {
		testing.expect(t, math.abs(f64(backing.advantages[index]-expectedAdvantages[index])) < 0.0001)
		testing.expect(t, math.abs(f64(backing.returns[index]-expectedReturns[index])) < 0.0001)
	}
	view, viewOk := BatchedRolloutBufferTrainingView(&buffer)
	testing.expect(t, viewOk && view == &buffer.rollout && view.count == 5)

	previousAdvantages, previousReturns := backing.advantages, backing.returns
	backing.environmentIndices[1] = 2
	testing.expect(t, !BatchedRolloutComputeGAE(&buffer, 0.9, 0.8, scratch))
	testing.expect(t, backing.advantages == previousAdvantages && backing.returns == previousReturns)
	backing.environmentIndices[1] = 1
}

@(test)
BatchedRolloutDiscountedReturnsAndReset :: proc(t: ^testing.T) {
	backing: BatchedRolloutTestStorage
	buffer, initOk := BatchedRolloutTestInit(&backing, 5)
	testing.expect(t, initOk && BatchedRolloutTestPopulate(&buffer))
	if !initOk { return }
	scratch := BatchedRolloutTestScratch(&backing)
	testing.expect(t, BatchedRolloutComputeDiscountedReturns(&buffer, 0.9, scratch))
	expectedReturns := [5]f32{2.8, 33.67, 2, 26.3, 6.6}
	for index in 0..<5 {
		testing.expect(t, math.abs(f64(backing.returns[index]-expectedReturns[index])) < 0.0001)
	}
	originalReturns := backing.returns
	testing.expect(t, !BatchedRolloutComputeDiscountedReturns(&buffer, 1.1, scratch))
	testing.expect(t, backing.returns == originalReturns)
	testing.expect(t, BatchedRolloutBufferReset(&buffer) && buffer.rollout.count == 0)
	testing.expect(t, !BatchedRolloutComputeDiscountedReturns(&buffer, 0.9, scratch))
}

@(test)
BatchedRolloutInitRejectsAliasedEnvironmentIds :: proc(t: ^testing.T) {
	backing: BatchedRolloutTestStorage
	storage := BatchedRolloutStorage{
		transitions = RolloutStorage{
			observations = backing.observations[:], actions = backing.actions[:],
			rewards = backing.rewards[:], values = backing.values[:], nextValues = backing.nextValues[:],
			oldLogProbabilities = backing.oldLogProbabilities[:], legalActions = backing.legalActions[:],
			terminated = backing.terminated[:], truncated = backing.truncated[:],
			advantages = backing.advantages[:], returns = backing.returns[:],
		},
		environmentIndices = backing.actions[:],
	}
	buffer: BatchedRolloutBuffer
	testing.expect(t, !BatchedRolloutBufferInit(&buffer, storage, 6, 2, 1, 2))
}
