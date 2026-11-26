package rl

// RolloutStorage contains caller-owned, non-overlapping backing slices. The
// observation and legal-action arrays are row-major by transition.
RolloutStorage :: struct {
	observations:       []f32,
	actions:            []int,
	rewards:            []f32,
	values:             []f32,
	nextValues:         []f32,
	oldLogProbabilities: []f64,
	legalActions:       []bool,
	terminated:         []bool,
	truncated:          []bool,
	advantages:         []f32,
	returns:            []f32,
}

// RolloutTransition is one sampled action and the value estimate for the
// resulting state. nextValue is used to bootstrap nonterminal and truncated
// transitions; it is ignored for terminated transitions.
RolloutTransition :: struct {
	observation:        []f32,
	action:             int,
	reward:             f32,
	value:              f32,
	nextValue:          f32,
	oldLogProbability:  f64,
	legalActions:       []bool,
	terminated:         bool,
	truncated:          bool,
}

// RolloutBuffer is a bounded, single-stream trajectory. Append copies each
// transition into storage. Do not mutate storage concurrently with buffer use.
RolloutBuffer :: struct {
	storage:          RolloutStorage,
	capacity:         int,
	observationWidth: int,
	actionCount:      int,
	count:            int,
	initialized:      bool,
}

RolloutMemoryRange :: struct {
	address: uintptr,
	bytes:   uintptr,
}

RolloutMemoryRangeOf :: proc(data: rawptr, count, elementSize: int) -> (RolloutMemoryRange, bool) {
	if count < 0 || elementSize <= 0 || uintptr(count) > max(uintptr) / uintptr(elementSize) {
		return {}, false
	}
	return RolloutMemoryRange{uintptr(data), uintptr(count) * uintptr(elementSize)}, true
}

RolloutRangesOverlap :: proc(a, b: RolloutMemoryRange) -> bool {
	if a.bytes == 0 || b.bytes == 0 do return false
	if a.address >= b.address do return a.address-b.address < b.bytes
	return b.address-a.address < a.bytes
}

RolloutStorageDisjoint :: proc(storage: RolloutStorage) -> bool {
	ranges: [11]RolloutMemoryRange
	ok: bool
	ranges[0], ok = RolloutMemoryRangeOf(rawptr(raw_data(storage.observations)), len(storage.observations), size_of(f32))
	if !ok do return false
	ranges[1], ok = RolloutMemoryRangeOf(rawptr(raw_data(storage.actions)), len(storage.actions), size_of(int))
	if !ok do return false
	ranges[2], ok = RolloutMemoryRangeOf(rawptr(raw_data(storage.rewards)), len(storage.rewards), size_of(f32))
	if !ok do return false
	ranges[3], ok = RolloutMemoryRangeOf(rawptr(raw_data(storage.values)), len(storage.values), size_of(f32))
	if !ok do return false
	ranges[4], ok = RolloutMemoryRangeOf(rawptr(raw_data(storage.nextValues)), len(storage.nextValues), size_of(f32))
	if !ok do return false
	ranges[5], ok = RolloutMemoryRangeOf(rawptr(raw_data(storage.oldLogProbabilities)), len(storage.oldLogProbabilities), size_of(f64))
	if !ok do return false
	ranges[6], ok = RolloutMemoryRangeOf(rawptr(raw_data(storage.legalActions)), len(storage.legalActions), size_of(bool))
	if !ok do return false
	ranges[7], ok = RolloutMemoryRangeOf(rawptr(raw_data(storage.terminated)), len(storage.terminated), size_of(bool))
	if !ok do return false
	ranges[8], ok = RolloutMemoryRangeOf(rawptr(raw_data(storage.truncated)), len(storage.truncated), size_of(bool))
	if !ok do return false
	ranges[9], ok = RolloutMemoryRangeOf(rawptr(raw_data(storage.advantages)), len(storage.advantages), size_of(f32))
	if !ok do return false
	ranges[10], ok = RolloutMemoryRangeOf(rawptr(raw_data(storage.returns)), len(storage.returns), size_of(f32))
	if !ok do return false

	for index in 0..<len(ranges) {
		for previous in 0..<index {
			if RolloutRangesOverlap(ranges[index], ranges[previous]) do return false
		}
	}
	return true
}

RolloutStorageFits :: proc(storage: RolloutStorage, capacity, observationWidth, actionCount: int) -> bool {
	if capacity <= 0 || observationWidth <= 0 || actionCount <= 0 ||
		capacity > max(int)/observationWidth || capacity > max(int)/actionCount {
		return false
	}
	return len(storage.observations) >= capacity*observationWidth &&
		len(storage.actions) >= capacity &&
		len(storage.rewards) >= capacity &&
		len(storage.values) >= capacity &&
		len(storage.nextValues) >= capacity &&
		len(storage.oldLogProbabilities) >= capacity &&
		len(storage.legalActions) >= capacity*actionCount &&
		len(storage.terminated) >= capacity &&
		len(storage.truncated) >= capacity &&
		len(storage.advantages) >= capacity &&
		len(storage.returns) >= capacity
}

RolloutBufferValid :: proc(buffer: ^RolloutBuffer) -> bool {
	return buffer != nil && buffer.initialized && buffer.count >= 0 && buffer.count <= buffer.capacity &&
		RolloutStorageFits(buffer.storage, buffer.capacity, buffer.observationWidth, buffer.actionCount) &&
		RolloutStorageDisjoint(buffer.storage)
}

// RolloutBufferInit validates all capacities and non-overlap before changing
// buffer. Extra backing capacity is allowed and remains unused.
RolloutBufferInit :: proc(
	buffer: ^RolloutBuffer,
	storage: RolloutStorage,
	capacity, observationWidth, actionCount: int,
) -> bool {
	if buffer == nil || !RolloutStorageFits(storage, capacity, observationWidth, actionCount) ||
		!RolloutStorageDisjoint(storage) {
		return false
	}
	buffer^ = RolloutBuffer{storage, capacity, observationWidth, actionCount, 0, true}
	return true
}

RolloutFiniteF32 :: proc(value: f32) -> bool {
	return value >= -3.402823466e+38 && value <= 3.402823466e+38
}

RolloutFiniteF64 :: proc(value: f64) -> bool {
	return value >= -1.7976931348623157e+308 && value <= 1.7976931348623157e+308
}

// RolloutBufferAppend rejects invalid actions, masks, non-finite values,
// contradictory episode flags, and full buffers without changing the buffer.
// Observation and legalActions must not alias the buffer's backing storage.
RolloutBufferAppend :: proc(buffer: ^RolloutBuffer, transition: RolloutTransition) -> bool {
	if !RolloutBufferValid(buffer) || buffer.count == buffer.capacity ||
		len(transition.observation) != buffer.observationWidth ||
		len(transition.legalActions) != buffer.actionCount ||
		transition.action < 0 || transition.action >= buffer.actionCount ||
		transition.terminated && transition.truncated ||
		!RolloutFiniteF32(transition.reward) || !RolloutFiniteF32(transition.value) ||
		!RolloutFiniteF32(transition.nextValue) || !RolloutFiniteF64(transition.oldLogProbability) {
		return false
	}
	for item in transition.observation {
		if !RolloutFiniteF32(item) do return false
	}
	legalAction := false
	for isLegal, action in transition.legalActions {
		if action == transition.action && isLegal { legalAction = true }
	}
	if !legalAction do return false

	index := buffer.count
	observationStart := index*buffer.observationWidth
	legalStart := index*buffer.actionCount
	copy(buffer.storage.observations[observationStart:observationStart+buffer.observationWidth], transition.observation)
	copy(buffer.storage.legalActions[legalStart:legalStart+buffer.actionCount], transition.legalActions)
	buffer.storage.actions[index] = transition.action
	buffer.storage.rewards[index] = transition.reward
	buffer.storage.values[index] = transition.value
	buffer.storage.nextValues[index] = transition.nextValue
	buffer.storage.oldLogProbabilities[index] = transition.oldLogProbability
	buffer.storage.terminated[index] = transition.terminated
	buffer.storage.truncated[index] = transition.truncated
	buffer.count += 1
	return true
}

// RolloutBufferReset keeps allocations and dimensions, discarding only the
// logical contents. Old bytes are left untouched and inaccessible by count.
RolloutBufferReset :: proc(buffer: ^RolloutBuffer) -> bool {
	if !RolloutBufferValid(buffer) do return false
	buffer.count = 0
	return true
}

RolloutBufferFull :: proc(buffer: ^RolloutBuffer) -> bool {
	return RolloutBufferValid(buffer) && buffer.count == buffer.capacity
}

RolloutObservationAt :: proc(buffer: ^RolloutBuffer, index: int) -> []f32 {
	if !RolloutBufferValid(buffer) || index < 0 || index >= buffer.count do return nil
	start := index*buffer.observationWidth
	return buffer.storage.observations[start:start+buffer.observationWidth]
}

RolloutLegalActionsAt :: proc(buffer: ^RolloutBuffer, index: int) -> []bool {
	if !RolloutBufferValid(buffer) || index < 0 || index >= buffer.count do return nil
	start := index*buffer.actionCount
	return buffer.storage.legalActions[start:start+buffer.actionCount]
}
