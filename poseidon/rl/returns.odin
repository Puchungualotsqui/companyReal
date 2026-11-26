package rl

import "core:math"

RolloutF64FitsF32 :: proc(value: f64) -> bool {
	return value >= -3.4028234663852886e+38 && value <= 3.4028234663852886e+38
}

RolloutReturnsInputsValid :: proc(buffer: ^RolloutBuffer, gamma: f32) -> bool {
	if !RolloutBufferValid(buffer) || buffer.count == 0 ||
		!RolloutFiniteF32(gamma) || gamma < 0 || gamma > 1 {
		return false
	}
	for index in 0..<buffer.count {
		if !RolloutFiniteF32(buffer.storage.rewards[index]) ||
			!RolloutFiniteF32(buffer.storage.values[index]) ||
			!RolloutFiniteF32(buffer.storage.nextValues[index]) ||
			buffer.storage.terminated[index] && buffer.storage.truncated[index] {
			return false
		}
	}
	return true
}

RolloutDiscountedReturnAt :: proc(buffer: ^RolloutBuffer, index: int, gamma, followingReturn: f64) -> f64 {
	reward := f64(buffer.storage.rewards[index])
	if buffer.storage.terminated[index] do return reward
	if buffer.storage.truncated[index] || index == buffer.count-1 {
		return reward + gamma*f64(buffer.storage.nextValues[index])
	}
	return reward + gamma*followingReturn
}

// RolloutComputeDiscountedReturns fills returns using rewards within each
// episode. Terminations do not bootstrap; truncations and a nonterminal final
// rollout step bootstrap from that transition's nextValue. Intermediate
// transitions must be in temporal order for one environment stream.
// Failure leaves returns unchanged.
RolloutComputeDiscountedReturns :: proc(buffer: ^RolloutBuffer, gamma: f32) -> bool {
	if !RolloutReturnsInputsValid(buffer, gamma) do return false
	gamma64 := f64(gamma)
	following: f64
	for index := buffer.count; index > 0; index -= 1 {
		slot := index-1
		value := RolloutDiscountedReturnAt(buffer, slot, gamma64, following)
		if !RolloutF64FitsF32(value) do return false
		following = value
	}

	following = 0
	for index := buffer.count; index > 0; index -= 1 {
		slot := index-1
		value := RolloutDiscountedReturnAt(buffer, slot, gamma64, following)
		buffer.storage.returns[slot] = f32(value)
		following = value
	}
	return true
}

RolloutAdvantageAt :: proc(
	buffer: ^RolloutBuffer,
	index: int,
	gamma, lambda, followingAdvantage: f64,
) -> (advantage, target: f64) {
	terminated := buffer.storage.terminated[index]
	truncated := buffer.storage.truncated[index]
	bootstrap: f64
	if !terminated { bootstrap = f64(buffer.storage.nextValues[index]) }
	delta := f64(buffer.storage.rewards[index]) + gamma*bootstrap - f64(buffer.storage.values[index])
	advantage = delta
	if !terminated && !truncated && index+1 < buffer.count {
		advantage += gamma*lambda*followingAdvantage
	}
	target = advantage + f64(buffer.storage.values[index])
	return
}

// RolloutComputeGAE fills advantages and value targets with Generalized
// Advantage Estimation. True terminations suppress value bootstrapping;
// truncations bootstrap from nextValue but stop advantage recursion across the
// episode boundary. A nonterminal final rollout step bootstraps its TD residual
// but has no later stored advantage to recurse into. Failure leaves both output
// arrays unchanged.
RolloutComputeGAE :: proc(buffer: ^RolloutBuffer, gamma, lambda: f32) -> bool {
	if !RolloutReturnsInputsValid(buffer, gamma) ||
		!RolloutFiniteF32(lambda) || lambda < 0 || lambda > 1 {
		return false
	}
	gamma64, lambda64 := f64(gamma), f64(lambda)
	followingAdvantage: f64
	for index := buffer.count; index > 0; index -= 1 {
		slot := index-1
		advantage, target := RolloutAdvantageAt(buffer, slot, gamma64, lambda64, followingAdvantage)
		if !RolloutF64FitsF32(advantage) || !RolloutF64FitsF32(target) do return false
		followingAdvantage = advantage
	}

	followingAdvantage = 0
	for index := buffer.count; index > 0; index -= 1 {
		slot := index-1
		advantage, target := RolloutAdvantageAt(buffer, slot, gamma64, lambda64, followingAdvantage)
		buffer.storage.advantages[slot] = f32(advantage)
		buffer.storage.returns[slot] = f32(target)
		followingAdvantage = advantage
	}
	return true
}

// RolloutNormalizeAdvantages standardizes the active advantages using
// population standard deviation. Constant advantages become zero. Failure
// leaves the advantage slice unchanged.
RolloutNormalizeAdvantages :: proc(buffer: ^RolloutBuffer) -> bool {
	if !RolloutBufferValid(buffer) || buffer.count == 0 do return false
	mean, m2: f64
	count := 0
	for value in buffer.storage.advantages[:buffer.count] {
		if !RolloutFiniteF32(value) do return false
		count += 1
		delta := f64(value)-mean
		mean += delta/f64(count)
		m2 += delta*(f64(value)-mean)
	}
	variance := max(m2/f64(count), 0)
	standardDeviation := math.sqrt(variance)
	if !RolloutFiniteF64(mean) || !RolloutFiniteF64(standardDeviation) do return false

	for value in buffer.storage.advantages[:buffer.count] {
		normalized: f64
		if standardDeviation > 0 { normalized = (f64(value)-mean)/standardDeviation }
		if !RolloutF64FitsF32(normalized) do return false
	}
	for &value in buffer.storage.advantages[:buffer.count] {
		if standardDeviation > 0 {
			value = f32((f64(value)-mean)/standardDeviation)
		} else {
			value = 0
		}
	}
	return true
}

// RolloutScaleRewards multiplies active rewards by a finite, nonnegative factor.
// It does not clip or normalize rewards. Failure leaves rewards unchanged.
RolloutScaleRewards :: proc(buffer: ^RolloutBuffer, scale: f32) -> bool {
	if !RolloutBufferValid(buffer) || buffer.count == 0 || !RolloutFiniteF32(scale) || scale < 0 {
		return false
	}
	for reward in buffer.storage.rewards[:buffer.count] {
		if !RolloutFiniteF32(reward) || !RolloutF64FitsF32(f64(reward)*f64(scale)) do return false
	}
	for &reward in buffer.storage.rewards[:buffer.count] { reward *= scale }
	return true
}
