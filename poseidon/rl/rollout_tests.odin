package rl

import "core:math"
import "core:testing"

RolloutTestBacking :: struct {
	observations:        [4]f32,
	actions:             [4]int,
	rewards:             [4]f32,
	values:              [4]f32,
	nextValues:          [4]f32,
	oldLogProbabilities: [4]f64,
	legalActions:        [8]bool,
	terminated:          [4]bool,
	truncated:           [4]bool,
	advantages:          [4]f32,
	returns:             [4]f32,
}

RolloutTestInit :: proc(backing: ^RolloutTestBacking, capacity := 4) -> (RolloutBuffer, bool) {
	buffer: RolloutBuffer
	storage := RolloutStorage {
		observations = backing.observations[:],
		actions = backing.actions[:],
		rewards = backing.rewards[:],
		values = backing.values[:],
		nextValues = backing.nextValues[:],
		oldLogProbabilities = backing.oldLogProbabilities[:],
		legalActions = backing.legalActions[:],
		terminated = backing.terminated[:],
		truncated = backing.truncated[:],
		advantages = backing.advantages[:],
		returns = backing.returns[:],
	}
	ok := RolloutBufferInit(&buffer, storage, capacity, 1, 2)
	return buffer, ok
}

RolloutTestAppend :: proc(
	buffer: ^RolloutBuffer,
	observation, reward, value, nextValue: f32,
	terminated := false,
	truncated := false,
) -> bool {
	observationRow := [1]f32{observation}
	legal := [2]bool{true, true}
	return RolloutBufferAppend(buffer, RolloutTransition{
		observation = observationRow[:],
		action = 0,
		reward = reward,
		value = value,
		nextValue = nextValue,
		oldLogProbability = -0.5,
		legalActions = legal[:],
		terminated = terminated,
		truncated = truncated,
	})
}

RolloutTestNear :: proc(a, b: f64, tolerance: f64 = 0.00001) -> bool {
	return math.abs(a-b) <= tolerance
}

@(test)
RolloutBufferAppendAccessReset :: proc(t: ^testing.T) {
	backing: RolloutTestBacking
	buffer, ok := RolloutTestInit(&backing, 2)
	testing.expect(t, ok && RolloutBufferValid(&buffer))
	observation := [1]f32{7}
	legal := [2]bool{true, false}
	transition := RolloutTransition{
		observation = observation[:],
		action = 0,
		reward = 2,
		value = 0.5,
		nextValue = 0.75,
		oldLogProbability = -0.25,
		legalActions = legal[:],
	}
	testing.expect(t, RolloutBufferAppend(&buffer, transition))
	observation[0] = 99
	legal[0] = false
	testing.expect(t, buffer.count == 1 && backing.observations[0] == 7)
	testing.expect(t, backing.legalActions[0] && !backing.legalActions[1])
	testing.expect(t, RolloutObservationAt(&buffer, 0)[0] == 7)
	testing.expect(t, RolloutLegalActionsAt(&buffer, 0)[0] && RolloutLegalActionsAt(&buffer, 0)[1] == false)
	testing.expect(t, RolloutObservationAt(&buffer, -1) == nil)
	testing.expect(t, RolloutLegalActionsAt(&buffer, 1) == nil)

	invalidMask := [2]bool{false, true}
	bothLegal := [2]bool{true, true}
	bad := RolloutTransition{
		observation = observation[:],
		action = 0,
		reward = 1,
		value = 1,
		nextValue = 1,
		oldLogProbability = 0,
		legalActions = invalidMask[:],
	}
	testing.expect(t, !RolloutBufferAppend(&buffer, bad) && buffer.count == 1)
	testing.expect(t, !RolloutBufferAppend(&buffer, RolloutTransition{
		observation = observation[:],
		action = 0,
		reward = 1,
		value = 1,
		nextValue = 1,
		oldLogProbability = 0,
		legalActions = bothLegal[:],
		terminated = true,
		truncated = true,
	}))
	testing.expect(t, buffer.count == 1)

	testing.expect(t, RolloutTestAppend(&buffer, 8, 3, 1, 2))
	testing.expect(t, RolloutBufferFull(&buffer))
	testing.expect(t, !RolloutTestAppend(&buffer, 9, 4, 1, 1) && buffer.count == 2)
	testing.expect(t, RolloutBufferReset(&buffer) && buffer.count == 0)
	testing.expect(t, !RolloutBufferFull(&buffer) && RolloutObservationAt(&buffer, 0) == nil)
}

@(test)
RolloutBufferValidationAndOverflow :: proc(t: ^testing.T) {
	backing: RolloutTestBacking
	buffer, ok := RolloutTestInit(&backing, 1)
	testing.expect(t, ok)
	observation := [1]f32{1}
	legal := [2]bool{true, false}
	bad := RolloutTransition{
		observation = observation[:], action = 0, reward = 1, value = 0,
		nextValue = 0, oldLogProbability = 0, legalActions = legal[:],
	}
	bad.reward = transmute(f32)u32(0x7f800000)
	testing.expect(t, !RolloutBufferAppend(&buffer, bad) && buffer.count == 0)
	bad.reward = 1
	bad.observation = nil
	testing.expect(t, !RolloutBufferAppend(&buffer, bad) && buffer.count == 0)

	invalidBacking: RolloutTestBacking
	invalidBuffer: RolloutBuffer
	invalidStorage := RolloutStorage{actions = invalidBacking.actions[:], rewards = invalidBacking.rewards[:], values = invalidBacking.values[:], nextValues = invalidBacking.nextValues[:], oldLogProbabilities = invalidBacking.oldLogProbabilities[:], legalActions = invalidBacking.legalActions[:], terminated = invalidBacking.terminated[:], truncated = invalidBacking.truncated[:], advantages = invalidBacking.advantages[:], returns = invalidBacking.returns[:]}
	testing.expect(t, !RolloutBufferInit(&invalidBuffer, invalidStorage, 1, 1, 2))

	aliasedBacking: RolloutTestBacking
	aliasedStorage := RolloutStorage{
		observations = aliasedBacking.observations[:],
		actions = aliasedBacking.actions[:],
		rewards = aliasedBacking.observations[:],
		values = aliasedBacking.values[:],
		nextValues = aliasedBacking.nextValues[:],
		oldLogProbabilities = aliasedBacking.oldLogProbabilities[:],
		legalActions = aliasedBacking.legalActions[:],
		terminated = aliasedBacking.terminated[:],
		truncated = aliasedBacking.truncated[:],
		advantages = aliasedBacking.advantages[:],
		returns = aliasedBacking.returns[:],
	}
	testing.expect(t, !RolloutBufferInit(&invalidBuffer, aliasedStorage, 1, 1, 2))
}

@(test)
RolloutDiscountedReturnsBoundaries :: proc(t: ^testing.T) {
	backing: RolloutTestBacking
	buffer, ok := RolloutTestInit(&backing)
	testing.expect(t, ok)
	testing.expect(t, RolloutTestAppend(&buffer, 0, 1, 0.5, 1))
	testing.expect(t, RolloutTestAppend(&buffer, 1, 2, 1, 4, truncated = true))
	testing.expect(t, RolloutTestAppend(&buffer, 2, 10, 4, 99, terminated = true))
	testing.expect(t, RolloutTestAppend(&buffer, 3, 3, 2, 6))
	testing.expect(t, RolloutComputeDiscountedReturns(&buffer, 0.5))
	testing.expect(t, RolloutTestNear(f64(backing.returns[0]), 3))
	testing.expect(t, RolloutTestNear(f64(backing.returns[1]), 4))
	testing.expect(t, RolloutTestNear(f64(backing.returns[2]), 10))
	testing.expect(t, RolloutTestNear(f64(backing.returns[3]), 6))

	original := backing.returns
	testing.expect(t, !RolloutComputeDiscountedReturns(&buffer, 1.1))
	testing.expect(t, backing.returns == original)
}

@(test)
RolloutGAEFlagsAndBootstrap :: proc(t: ^testing.T) {
	backing: RolloutTestBacking
	buffer, ok := RolloutTestInit(&backing)
	testing.expect(t, ok)
	testing.expect(t, RolloutTestAppend(&buffer, 0, 1, 0.5, 1))
	testing.expect(t, RolloutTestAppend(&buffer, 1, 2, 1, 4, truncated = true))
	testing.expect(t, RolloutTestAppend(&buffer, 2, 3, 2, 99, terminated = true))
	testing.expect(t, RolloutComputeGAE(&buffer, 0.5, 0.5))
	testing.expect(t, RolloutTestNear(f64(backing.advantages[0]), 1.75))
	testing.expect(t, RolloutTestNear(f64(backing.returns[0]), 2.25))
	testing.expect(t, RolloutTestNear(f64(backing.advantages[1]), 3))
	testing.expect(t, RolloutTestNear(f64(backing.returns[1]), 4))
	testing.expect(t, RolloutTestNear(f64(backing.advantages[2]), 1))
	testing.expect(t, RolloutTestNear(f64(backing.returns[2]), 3))

	testing.expect(t, RolloutBufferReset(&buffer))
	testing.expect(t, RolloutTestAppend(&buffer, 3, 1, 0.5, 3))
	testing.expect(t, RolloutComputeGAE(&buffer, 0.5, 0.8))
	testing.expect(t, RolloutTestNear(f64(backing.advantages[0]), 2))
	testing.expect(t, RolloutTestNear(f64(backing.returns[0]), 2.5))

	originalAdvantages, originalReturns := backing.advantages, backing.returns
	testing.expect(t, !RolloutComputeGAE(&buffer, 0.5, -0.1))
	testing.expect(t, backing.advantages == originalAdvantages && backing.returns == originalReturns)
}

@(test)
RolloutNormalizationAndRewardScaling :: proc(t: ^testing.T) {
	backing: RolloutTestBacking
	buffer, ok := RolloutTestInit(&backing, 3)
	testing.expect(t, ok)
	testing.expect(t, RolloutTestAppend(&buffer, 0, 2, 0, 0))
	testing.expect(t, RolloutTestAppend(&buffer, 1, 4, 0, 0))
	testing.expect(t, RolloutTestAppend(&buffer, 2, 6, 0, 0))
	initialAdvantages := [3]f32{1, 2, 3}
	copy(backing.advantages[:3], initialAdvantages[:])
	testing.expect(t, RolloutNormalizeAdvantages(&buffer))
	testing.expect(t, RolloutTestNear(f64(backing.advantages[0]), -math.sqrt(1.5)))
	testing.expect(t, backing.advantages[1] == 0)
	testing.expect(t, RolloutTestNear(f64(backing.advantages[2]), math.sqrt(1.5)))
	testing.expect(t, RolloutScaleRewards(&buffer, 0.5))
	testing.expect(t, backing.rewards[0] == 1 && backing.rewards[1] == 2 && backing.rewards[2] == 3)

	constantAdvantages := [3]f32{5, 5, 5}
	copy(backing.advantages[:3], constantAdvantages[:])
	testing.expect(t, RolloutNormalizeAdvantages(&buffer))
	testing.expect(t, backing.advantages[0] == 0 && backing.advantages[1] == 0 && backing.advantages[2] == 0)
	originalRewards := backing.rewards
	testing.expect(t, !RolloutScaleRewards(&buffer, -1))
	testing.expect(t, backing.rewards == originalRewards)
}

@(test)
RolloutDiscountedReturnsOverflowIsAtomic :: proc(t: ^testing.T) {
	backing: RolloutTestBacking
	buffer, ok := RolloutTestInit(&backing, 2)
	testing.expect(t, ok)
	maximum := f32(3.402823466e+38)
	testing.expect(t, RolloutTestAppend(&buffer, 0, maximum, 0, 0))
	testing.expect(t, RolloutTestAppend(&buffer, 1, maximum, 0, 0))
	backing.returns[0], backing.returns[1] = 17, 18
	testing.expect(t, !RolloutComputeDiscountedReturns(&buffer, 1))
	testing.expect(t, backing.returns[0] == 17 && backing.returns[1] == 18)
}
