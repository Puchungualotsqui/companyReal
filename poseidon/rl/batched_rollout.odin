package rl

// BatchedRolloutStorage stores transitions from independent environment streams
// in one flat training buffer. Append every transition in chronological order
// within each environment without gaps; transitions from different environments
// may be interleaved. Mark episode ends with the usual terminated/truncated flags.
BatchedRolloutStorage :: struct {
	transitions:        RolloutStorage,
	environmentIndices: []int,
}

// BatchedRolloutBuffer provides a PPO-compatible flat view after per-environment
// returns/advantages have been computed. capacity is the total transition count,
// not a per-environment step count.
BatchedRolloutBuffer :: struct {
	rollout:          RolloutBuffer,
	environmentIndices: []int,
	environmentCount: int,
	initialized:      bool,
}

// Return scratch is caller-owned and must be disjoint from the buffer. The
// arrays need one element per environment and are reused for each reverse pass.
BatchedRolloutReturnScratch :: struct {
	followingValues: []f64,
	hasFollowing:    []bool,
}

BatchedRolloutStorageDisjoint :: proc(storage: RolloutStorage, environmentIndices: []int) -> bool {
	if !RolloutStorageDisjoint(storage) do return false
	ranges: [12]RolloutMemoryRange
	ok: bool
	ranges[0], ok = RolloutMemoryRangeOf(rawptr(raw_data(storage.observations)), len(storage.observations), size_of(f32)); if !ok do return false
	ranges[1], ok = RolloutMemoryRangeOf(rawptr(raw_data(storage.actions)), len(storage.actions), size_of(int)); if !ok do return false
	ranges[2], ok = RolloutMemoryRangeOf(rawptr(raw_data(storage.rewards)), len(storage.rewards), size_of(f32)); if !ok do return false
	ranges[3], ok = RolloutMemoryRangeOf(rawptr(raw_data(storage.values)), len(storage.values), size_of(f32)); if !ok do return false
	ranges[4], ok = RolloutMemoryRangeOf(rawptr(raw_data(storage.nextValues)), len(storage.nextValues), size_of(f32)); if !ok do return false
	ranges[5], ok = RolloutMemoryRangeOf(rawptr(raw_data(storage.oldLogProbabilities)), len(storage.oldLogProbabilities), size_of(f64)); if !ok do return false
	ranges[6], ok = RolloutMemoryRangeOf(rawptr(raw_data(storage.legalActions)), len(storage.legalActions), size_of(bool)); if !ok do return false
	ranges[7], ok = RolloutMemoryRangeOf(rawptr(raw_data(storage.terminated)), len(storage.terminated), size_of(bool)); if !ok do return false
	ranges[8], ok = RolloutMemoryRangeOf(rawptr(raw_data(storage.truncated)), len(storage.truncated), size_of(bool)); if !ok do return false
	ranges[9], ok = RolloutMemoryRangeOf(rawptr(raw_data(storage.advantages)), len(storage.advantages), size_of(f32)); if !ok do return false
	ranges[10], ok = RolloutMemoryRangeOf(rawptr(raw_data(storage.returns)), len(storage.returns), size_of(f32)); if !ok do return false
	ranges[11], ok = RolloutMemoryRangeOf(rawptr(raw_data(environmentIndices)), len(environmentIndices), size_of(int)); if !ok do return false
	for index in 0..<len(ranges) {
		for previous in 0..<index {
			if RolloutRangesOverlap(ranges[index], ranges[previous]) do return false
		}
	}
	return true
}

BatchedRolloutBufferObjectDisjoint :: proc(
	buffer: ^BatchedRolloutBuffer,
	storage: BatchedRolloutStorage,
) -> bool {
	objectRange, objectOk := RolloutMemoryRangeOf(rawptr(buffer), 1, size_of(BatchedRolloutBuffer))
	if !objectOk do return false
	if !BatchedRolloutStorageDisjoint(storage.transitions, storage.environmentIndices) do return false
	ranges: [12]RolloutMemoryRange
	ok: bool
	ranges[0], ok = RolloutMemoryRangeOf(rawptr(raw_data(storage.transitions.observations)), len(storage.transitions.observations), size_of(f32)); if !ok do return false
	ranges[1], ok = RolloutMemoryRangeOf(rawptr(raw_data(storage.transitions.actions)), len(storage.transitions.actions), size_of(int)); if !ok do return false
	ranges[2], ok = RolloutMemoryRangeOf(rawptr(raw_data(storage.transitions.rewards)), len(storage.transitions.rewards), size_of(f32)); if !ok do return false
	ranges[3], ok = RolloutMemoryRangeOf(rawptr(raw_data(storage.transitions.values)), len(storage.transitions.values), size_of(f32)); if !ok do return false
	ranges[4], ok = RolloutMemoryRangeOf(rawptr(raw_data(storage.transitions.nextValues)), len(storage.transitions.nextValues), size_of(f32)); if !ok do return false
	ranges[5], ok = RolloutMemoryRangeOf(rawptr(raw_data(storage.transitions.oldLogProbabilities)), len(storage.transitions.oldLogProbabilities), size_of(f64)); if !ok do return false
	ranges[6], ok = RolloutMemoryRangeOf(rawptr(raw_data(storage.transitions.legalActions)), len(storage.transitions.legalActions), size_of(bool)); if !ok do return false
	ranges[7], ok = RolloutMemoryRangeOf(rawptr(raw_data(storage.transitions.terminated)), len(storage.transitions.terminated), size_of(bool)); if !ok do return false
	ranges[8], ok = RolloutMemoryRangeOf(rawptr(raw_data(storage.transitions.truncated)), len(storage.transitions.truncated), size_of(bool)); if !ok do return false
	ranges[9], ok = RolloutMemoryRangeOf(rawptr(raw_data(storage.transitions.advantages)), len(storage.transitions.advantages), size_of(f32)); if !ok do return false
	ranges[10], ok = RolloutMemoryRangeOf(rawptr(raw_data(storage.transitions.returns)), len(storage.transitions.returns), size_of(f32)); if !ok do return false
	ranges[11], ok = RolloutMemoryRangeOf(rawptr(raw_data(storage.environmentIndices)), len(storage.environmentIndices), size_of(int)); if !ok do return false
	for item in ranges {
		if RolloutRangesOverlap(objectRange, item) do return false
	}
	return true
}

BatchedRolloutBufferInit :: proc(
	buffer: ^BatchedRolloutBuffer,
	storage: BatchedRolloutStorage,
	capacity, environmentCount, observationWidth, actionCount: int,
) -> bool {
	if buffer == nil || environmentCount <= 0 || len(storage.environmentIndices) < capacity ||
		!RolloutStorageFits(storage.transitions, capacity, observationWidth, actionCount) ||
		!BatchedRolloutStorageDisjoint(storage.transitions, storage.environmentIndices) {
		return false
	}
	if !BatchedRolloutBufferObjectDisjoint(buffer, storage) do return false
	rollout: RolloutBuffer
	if !RolloutBufferInit(&rollout, storage.transitions, capacity, observationWidth, actionCount) do return false
	buffer^ = BatchedRolloutBuffer{
		rollout = rollout,
		environmentIndices = storage.environmentIndices,
		environmentCount = environmentCount,
		initialized = true,
	}
	return true
}

BatchedRolloutBufferValid :: proc(buffer: ^BatchedRolloutBuffer) -> bool {
	if buffer == nil || !buffer.initialized || buffer.environmentCount <= 0 ||
		!RolloutBufferValid(&buffer.rollout) || len(buffer.environmentIndices) < buffer.rollout.capacity {
		return false
	}
	storage := BatchedRolloutStorage{buffer.rollout.storage, buffer.environmentIndices}
	return BatchedRolloutBufferObjectDisjoint(buffer, storage)
}

BatchedRolloutBufferReset :: proc(buffer: ^BatchedRolloutBuffer) -> bool {
	if !BatchedRolloutBufferValid(buffer) do return false
	return RolloutBufferReset(&buffer.rollout)
}

BatchedRolloutBufferFull :: proc(buffer: ^BatchedRolloutBuffer) -> bool {
	return BatchedRolloutBufferValid(buffer) && RolloutBufferFull(&buffer.rollout)
}

BatchedRolloutBufferAppend :: proc(
	buffer: ^BatchedRolloutBuffer,
	environmentIndex: int,
	transition: RolloutTransition,
) -> bool {
	if !BatchedRolloutBufferValid(buffer) || environmentIndex < 0 ||
		environmentIndex >= buffer.environmentCount || buffer.rollout.count >= buffer.rollout.capacity {
		return false
	}
	index := buffer.rollout.count
	if !RolloutBufferAppend(&buffer.rollout, transition) do return false
	buffer.environmentIndices[index] = environmentIndex
	return true
}

// Returns the flat rollout view used by PPO fitting after batched return/GAE
// computation. Its rows are samples, not a single temporal stream.
BatchedRolloutBufferTrainingView :: proc(buffer: ^BatchedRolloutBuffer) -> (^RolloutBuffer, bool) {
	if !BatchedRolloutBufferValid(buffer) do return nil, false
	return &buffer.rollout, true
}

BatchedRolloutReturnInputsValid :: proc(
	buffer: ^BatchedRolloutBuffer,
	gamma: f32,
	followingValues: []f64,
	hasFollowing: []bool,
) -> bool {
	if !BatchedRolloutBufferValid(buffer) || buffer.rollout.count == 0 ||
		len(followingValues) < buffer.environmentCount || len(hasFollowing) < buffer.environmentCount ||
		!RolloutFiniteF32(gamma) || gamma < 0 || gamma > 1 ||
		!BatchedRolloutReturnScratchDisjoint(buffer, followingValues, hasFollowing) {
		return false
	}
	for index in 0..<buffer.rollout.count {
		if buffer.environmentIndices[index] < 0 || buffer.environmentIndices[index] >= buffer.environmentCount ||
			!RolloutFiniteF32(buffer.rollout.storage.rewards[index]) ||
			!RolloutFiniteF32(buffer.rollout.storage.values[index]) ||
			!RolloutFiniteF32(buffer.rollout.storage.nextValues[index]) ||
			buffer.rollout.storage.terminated[index] && buffer.rollout.storage.truncated[index] {
			return false
		}
	}
	return true
}

BatchedRolloutReturnScratchDisjoint :: proc(
	buffer: ^BatchedRolloutBuffer,
	followingValues: []f64,
	hasFollowing: []bool,
) -> bool {
	ranges: [15]RolloutMemoryRange
	ok: bool
	ranges[0], ok = RolloutMemoryRangeOf(rawptr(buffer), 1, size_of(BatchedRolloutBuffer)); if !ok do return false
	ranges[1], ok = RolloutMemoryRangeOf(rawptr(raw_data(followingValues[:buffer.environmentCount])), buffer.environmentCount, size_of(f64)); if !ok do return false
	ranges[2], ok = RolloutMemoryRangeOf(rawptr(raw_data(hasFollowing[:buffer.environmentCount])), buffer.environmentCount, size_of(bool)); if !ok do return false
	ranges[3], ok = RolloutMemoryRangeOf(rawptr(raw_data(buffer.environmentIndices)), len(buffer.environmentIndices), size_of(int)); if !ok do return false
	ranges[4], ok = RolloutMemoryRangeOf(rawptr(raw_data(buffer.rollout.storage.observations)), len(buffer.rollout.storage.observations), size_of(f32)); if !ok do return false
	ranges[5], ok = RolloutMemoryRangeOf(rawptr(raw_data(buffer.rollout.storage.actions)), len(buffer.rollout.storage.actions), size_of(int)); if !ok do return false
	ranges[6], ok = RolloutMemoryRangeOf(rawptr(raw_data(buffer.rollout.storage.rewards)), len(buffer.rollout.storage.rewards), size_of(f32)); if !ok do return false
	ranges[7], ok = RolloutMemoryRangeOf(rawptr(raw_data(buffer.rollout.storage.values)), len(buffer.rollout.storage.values), size_of(f32)); if !ok do return false
	ranges[8], ok = RolloutMemoryRangeOf(rawptr(raw_data(buffer.rollout.storage.nextValues)), len(buffer.rollout.storage.nextValues), size_of(f32)); if !ok do return false
	ranges[9], ok = RolloutMemoryRangeOf(rawptr(raw_data(buffer.rollout.storage.oldLogProbabilities)), len(buffer.rollout.storage.oldLogProbabilities), size_of(f64)); if !ok do return false
	ranges[10], ok = RolloutMemoryRangeOf(rawptr(raw_data(buffer.rollout.storage.legalActions)), len(buffer.rollout.storage.legalActions), size_of(bool)); if !ok do return false
	ranges[11], ok = RolloutMemoryRangeOf(rawptr(raw_data(buffer.rollout.storage.terminated)), len(buffer.rollout.storage.terminated), size_of(bool)); if !ok do return false
	ranges[12], ok = RolloutMemoryRangeOf(rawptr(raw_data(buffer.rollout.storage.truncated)), len(buffer.rollout.storage.truncated), size_of(bool)); if !ok do return false
	ranges[13], ok = RolloutMemoryRangeOf(rawptr(raw_data(buffer.rollout.storage.advantages)), len(buffer.rollout.storage.advantages), size_of(f32)); if !ok do return false
	ranges[14], ok = RolloutMemoryRangeOf(rawptr(raw_data(buffer.rollout.storage.returns)), len(buffer.rollout.storage.returns), size_of(f32)); if !ok do return false
	for index in 0..<len(ranges) {
		for previous in 0..<index {
			if RolloutRangesOverlap(ranges[index], ranges[previous]) do return false
		}
	}
	return true
}

BatchedRolloutGAEAt :: proc(
	buffer: ^BatchedRolloutBuffer,
	index: int,
	gamma, lambda, followingAdvantage: f64,
	hasFollowing: bool,
) -> (advantage, target: f64) {
	terminated := buffer.rollout.storage.terminated[index]
	truncated := buffer.rollout.storage.truncated[index]
	bootstrap: f64
	if !terminated { bootstrap = f64(buffer.rollout.storage.nextValues[index]) }
	advantage = f64(buffer.rollout.storage.rewards[index]) + gamma*bootstrap - f64(buffer.rollout.storage.values[index])
	if !terminated && !truncated && hasFollowing {
		advantage += gamma*lambda*followingAdvantage
	}
	target = advantage+f64(buffer.rollout.storage.values[index])
	return
}

BatchedRolloutDiscountedReturnAt :: proc(
	buffer: ^BatchedRolloutBuffer,
	index: int,
	gamma, followingReturn: f64,
	hasFollowing: bool,
) -> f64 {
	reward := f64(buffer.rollout.storage.rewards[index])
	if buffer.rollout.storage.terminated[index] do return reward
	if buffer.rollout.storage.truncated[index] || !hasFollowing {
		return reward+gamma*f64(buffer.rollout.storage.nextValues[index])
	}
	return reward+gamma*followingReturn
}

// Computes GAE independently for each environment. Transitions may be
// interleaved, but each environment's appends must be chronological. Truncation
// bootstraps the value and stops recursion across that episode boundary. Failure
// leaves advantages and returns unchanged; the supplied scratch may be modified.
BatchedRolloutComputeGAE :: proc(
	buffer: ^BatchedRolloutBuffer,
	gamma, lambda: f32,
	scratch: BatchedRolloutReturnScratch,
) -> bool {
	if !BatchedRolloutReturnInputsValid(buffer, gamma, scratch.followingValues, scratch.hasFollowing) ||
		!RolloutFiniteF32(lambda) || lambda < 0 || lambda > 1 {
		return false
	}
	gamma64, lambda64 := f64(gamma), f64(lambda)
	for index in 0..<buffer.environmentCount {
		scratch.followingValues[index] = 0
		scratch.hasFollowing[index] = false
	}
	for position := buffer.rollout.count; position > 0; position -= 1 {
		index := position-1
		environment := buffer.environmentIndices[index]
		advantage, target := BatchedRolloutGAEAt(
			buffer, index, gamma64, lambda64,
			scratch.followingValues[environment], scratch.hasFollowing[environment],
		)
		if !RolloutF64FitsF32(advantage) || !RolloutF64FitsF32(target) do return false
		scratch.followingValues[environment] = advantage
		scratch.hasFollowing[environment] = true
	}
	for index in 0..<buffer.environmentCount {
		scratch.followingValues[index] = 0
		scratch.hasFollowing[index] = false
	}
	for position := buffer.rollout.count; position > 0; position -= 1 {
		index := position-1
		environment := buffer.environmentIndices[index]
		advantage, target := BatchedRolloutGAEAt(
			buffer, index, gamma64, lambda64,
			scratch.followingValues[environment], scratch.hasFollowing[environment],
		)
		buffer.rollout.storage.advantages[index] = f32(advantage)
		buffer.rollout.storage.returns[index] = f32(target)
		scratch.followingValues[environment] = advantage
		scratch.hasFollowing[environment] = true
	}
	return true
}

// Computes discounted returns independently per environment. A final in-rollout
// transition bootstraps from its nextValue; terminations do not bootstrap.
BatchedRolloutComputeDiscountedReturns :: proc(
	buffer: ^BatchedRolloutBuffer,
	gamma: f32,
	scratch: BatchedRolloutReturnScratch,
) -> bool {
	if !BatchedRolloutReturnInputsValid(buffer, gamma, scratch.followingValues, scratch.hasFollowing) do return false
	gamma64 := f64(gamma)
	for index in 0..<buffer.environmentCount {
		scratch.followingValues[index] = 0
		scratch.hasFollowing[index] = false
	}
	for position := buffer.rollout.count; position > 0; position -= 1 {
		index := position-1
		environment := buffer.environmentIndices[index]
		value := BatchedRolloutDiscountedReturnAt(
			buffer, index, gamma64,
			scratch.followingValues[environment], scratch.hasFollowing[environment],
		)
		if !RolloutF64FitsF32(value) do return false
		scratch.followingValues[environment] = value
		scratch.hasFollowing[environment] = true
	}
	for index in 0..<buffer.environmentCount {
		scratch.followingValues[index] = 0
		scratch.hasFollowing[index] = false
	}
	for position := buffer.rollout.count; position > 0; position -= 1 {
		index := position-1
		environment := buffer.environmentIndices[index]
		value := BatchedRolloutDiscountedReturnAt(
			buffer, index, gamma64,
			scratch.followingValues[environment], scratch.hasFollowing[environment],
		)
		buffer.rollout.storage.returns[index] = f32(value)
		scratch.followingValues[environment] = value
		scratch.hasFollowing[environment] = true
	}
	return true
}
