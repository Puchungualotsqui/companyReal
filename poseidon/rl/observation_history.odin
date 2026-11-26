package rl

// ObservationHistory keeps a fixed window of recent row-major observations for
// feed-forward policies in partially observed environments. Storage is
// caller-owned; no model, game, or episode types are involved.
ObservationHistory :: struct {
	storage:          []f32,
	observationWidth: int,
	depth:            int,
	count:            int,
	nextIndex:        int,
	initialized:      bool,
}

ObservationHistoryValid :: proc(history: ^ObservationHistory) -> bool {
	if history == nil || !history.initialized || history.observationWidth <= 0 || history.depth <= 0 ||
		history.observationWidth > max(int)/history.depth || history.count < 0 || history.count > history.depth ||
		history.nextIndex < 0 || history.nextIndex >= history.depth ||
		len(history.storage) < history.observationWidth*history.depth {
		return false
	}
	objectRange, objectOk := RolloutMemoryRangeOf(rawptr(history), 1, size_of(ObservationHistory))
	storageRange, storageOk := RolloutMemoryRangeOf(rawptr(raw_data(history.storage)), len(history.storage), size_of(f32))
	return objectOk && storageOk && !RolloutRangesOverlap(objectRange, storageRange)
}

// Initializes an empty history. Missing frames are represented as leading zero
// rows when flattened. Storage must be caller-owned and disjoint from history.
ObservationHistoryInit :: proc(
	history: ^ObservationHistory,
	storage: []f32,
	depth, observationWidth: int,
) -> bool {
	if history == nil || depth <= 0 || observationWidth <= 0 ||
		observationWidth > max(int)/depth || len(storage) < depth*observationWidth {
		return false
	}
	objectRange, objectOk := RolloutMemoryRangeOf(rawptr(history), 1, size_of(ObservationHistory))
	storageRange, storageOk := RolloutMemoryRangeOf(rawptr(raw_data(storage)), len(storage), size_of(f32))
	if !objectOk || !storageOk || RolloutRangesOverlap(objectRange, storageRange) do return false
	used := depth*observationWidth
	for &value in storage[:used] { value = 0 }
	history^ = ObservationHistory{
		storage = storage,
		observationWidth = observationWidth,
		depth = depth,
		count = 0,
		nextIndex = 0,
		initialized = true,
	}
	return true
}

// Reset discards episode history and restores zero padding. Call it before
// collecting the first observation of each new episode.
ObservationHistoryReset :: proc(history: ^ObservationHistory) -> bool {
	if !ObservationHistoryValid(history) do return false
	for &value in history.storage[:history.depth*history.observationWidth] { value = 0 }
	history.count = 0
	history.nextIndex = 0
	return true
}

// Push adds one complete finite observation. Push each timestep exactly once;
// the ring overwrites the oldest observation after reaching depth.
ObservationHistoryPush :: proc(history: ^ObservationHistory, observation: []f32) -> bool {
	if !ObservationHistoryValid(history) || len(observation) != history.observationWidth do return false
	inputRange, inputOk := RolloutMemoryRangeOf(rawptr(raw_data(observation)), len(observation), size_of(f32))
	objectRange, objectOk := RolloutMemoryRangeOf(rawptr(history), 1, size_of(ObservationHistory))
	storageRange, storageOk := RolloutMemoryRangeOf(rawptr(raw_data(history.storage)), len(history.storage), size_of(f32))
	if !inputOk || !objectOk || !storageOk || RolloutRangesOverlap(inputRange, objectRange) ||
		RolloutRangesOverlap(inputRange, storageRange) {
		return false
	}
	for value in observation {
		if !RolloutFiniteF32(value) do return false
	}
	start := history.nextIndex*history.observationWidth
	copy(history.storage[start:start+history.observationWidth], observation)
	history.nextIndex = (history.nextIndex+1)%history.depth
	history.count = min(history.count+1, history.depth)
	return true
}

// Flattens the history into exactly depth*observationWidth values, ordered from
// oldest to newest. A not-yet-full window has leading zero rows. Output must be
// disjoint from history storage; failure leaves output unchanged.
ObservationHistoryFlatten :: proc(history: ^ObservationHistory, output: []f32) -> bool {
	if !ObservationHistoryValid(history) ||
		len(output) != history.depth*history.observationWidth {
		return false
	}
	outputRange, outputOk := RolloutMemoryRangeOf(rawptr(raw_data(output)), len(output), size_of(f32))
	objectRange, objectOk := RolloutMemoryRangeOf(rawptr(history), 1, size_of(ObservationHistory))
	storageRange, storageOk := RolloutMemoryRangeOf(rawptr(raw_data(history.storage)), len(history.storage), size_of(f32))
	if !outputOk || !objectOk || !storageOk || RolloutRangesOverlap(outputRange, objectRange) ||
		RolloutRangesOverlap(outputRange, storageRange) {
		return false
	}
	padding := history.depth-history.count
	startIndex := (history.nextIndex-history.count+history.depth)%history.depth
	for row in 0..<history.count {
		physicalRow := (startIndex+row)%history.depth
		start := physicalRow*history.observationWidth
		for value in history.storage[start:start+history.observationWidth] {
			if !RolloutFiniteF32(value) do return false
		}
	}
	for row in 0..<history.depth {
		outputStart := row*history.observationWidth
		if row < padding {
			for index in 0..<history.observationWidth { output[outputStart+index] = 0 }
			continue
		}
		physicalRow := (startIndex+row-padding)%history.depth
		inputStart := physicalRow*history.observationWidth
		copy(output[outputStart:outputStart+history.observationWidth], history.storage[inputStart:inputStart+history.observationWidth])
	}
	return true
}
