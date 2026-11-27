package nn

import "../core"
import "../data"
import "core:mem"

// Callers may also inspect separately to obtain a detailed code and byte offset.
@(private)
ppoTrainingContextInspectionError :: proc(err: CheckpointError) -> PPOTrainingContextError {
	if err.code == .None { return .None }
	if err.code == .InvalidLimits { return .InvalidOptions }
	if err.code == .LimitExceeded { return .CheckpointIncompatible }
	return .InvalidCheckpoint
}

@(private="file")
ppoTrainingContextCheckpointEmpty :: proc(trainer: ^PPOTrainingContext($pl, $pw, $pb, $vl, $vw, $vb)) -> bool {
	return trainer != nil && trainer.self == nil && trainer.phase == .Empty && trainer.adam.self == nil &&
		trainer.scratch.self == nil && trainer.scratch.memory == nil && trainer.pending.blocks == ([4]rawptr{})
}

// Failure cleanup retains every allocation whose free reports an error. The
// allocator must leave failed frees intact if the caller will retry destruction.
@(private="file")
ppoTrainingContextInitRollback :: proc(
	trainer: ^PPOTrainingContext($pl, $pw, $pb, $vl, $vw, $vb),
	failure: PPOTrainingContextError,
) -> PPOTrainingContextError {
	trainer.phase = .Destroying
	if !ppoTrainingContextFreePending(&trainer.pending) { return .CleanupFailed }
	trainer^ = {}
	return failure
}

// Initialize an empty trainer from a validated base Adam PPO checkpoint. The
// destination model slots must be zero-valued or initialized in place with no
// layers; they must not be attached to another live optimizer or trainer. Their
// compile-time capacities must exactly match the checkpoint. rolloutCapacity is
// caller-selected because the checkpoint does not serialize a rollout.
//
// Inspection limits bound untrusted input; maxOwnedBytes bounds the requested
// scratch, pointer, and both moment allocations together (zero disables the
// bound; it excludes allocator overhead and caller-owned models/rollouts). The
// input must remain unchanged, valid and disjoint from the complete trainer,
// both model slots, allocator state, and all allocations through the call.
//
// On success the models are reconstructed in place and the trainer owns the
// Adam/scratch allocations; checkpoint state and optimizer moments are preserved.
// Invalid input and allocation failures leave model slots unchanged under
// PPOCheckpointRead's preflight/replay contract. Cleanup failure returns
// .CleanupFailed and leaves the trainer destroying; retry Destroy only when a
// failed free leaves the allocation intact. Inspection can be called separately
// for a detailed byte error. This API does not restore environment or rollout state.
PPOTrainingContextCheckpointInit :: proc(
	trainer: ^PPOTrainingContext($pl, $pw, $pb, $vl, $vw, $vb),
	policy: ^Sequential(pl, pw, pb), value: ^Sequential(vl, vw, vb),
	input: []u8, rolloutCapacity: int,
	limits: PPOCheckpointInspectLimits = {}, maxOwnedBytes: int = 0,
	allocator: mem.Allocator = context.allocator,
) -> PPOTrainingContextError {
	if !ppoTrainingContextCheckpointEmpty(trainer) { return .InvalidHandle }
	if rolloutCapacity <= 0 || maxOwnedBytes < 0 { return .InvalidOptions }
	info, err := PPOCheckpointInspect(input, limits)
	if err.code != .None { return ppoTrainingContextInspectionError(err) }
	return ppoTrainingContextInitInspected(trainer, policy, value, input, rolloutCapacity, maxOwnedBytes, allocator, info, {}, {}, false)
}

// Like PPOTrainingContextCheckpointInit, but validates and restores a normalized
// PPO checkpoint and the supplied caller-owned normalizers. Presence and widths
// must match the checkpoint; initialize their backing arrays before this call.
// Normalizer objects and arrays must be disjoint from every other live object,
// input, and owned allocation. Both model and normalizer destinations remain
// unchanged on precommit failure, subject to the underlying reader contract.
PPOTrainingContextCheckpointInitNormalized :: proc(
	trainer: ^PPOTrainingContext($pl, $pw, $pb, $vl, $vw, $vb),
	policy: ^Sequential(pl, pw, pb), value: ^Sequential(vl, vw, vb),
	input: []u8, normalizers: PPOTrainingNormalizers, rolloutCapacity: int,
	limits: PPONormalizedCheckpointInspectLimits = {}, maxOwnedBytes: int = 0,
	allocator: mem.Allocator = context.allocator,
) -> PPOTrainingContextError {
	if !ppoTrainingContextCheckpointEmpty(trainer) { return .InvalidHandle }
	if rolloutCapacity <= 0 || maxOwnedBytes < 0 { return .InvalidOptions }
	info, err := PPOCheckpointInspectNormalized(input, limits)
	if err.code != .None { return ppoTrainingContextInspectionError(err) }
	return ppoTrainingContextInitInspected(trainer, policy, value, input, rolloutCapacity, maxOwnedBytes, allocator, info.base, info, normalizers, true)
}

@(private="file")
ppoTrainingContextInitInspected :: proc(
	trainer: ^PPOTrainingContext($pl, $pw, $pb, $vl, $vw, $vb),
	policy: ^Sequential(pl, pw, pb), value: ^Sequential(vl, vw, vb),
	input: []u8, rolloutCapacity, maxOwnedBytes: int, allocator: mem.Allocator,
	info: PPOCheckpointInfo, normalizedInfo: PPONormalizedCheckpointInfo,
	normalizers: PPOTrainingNormalizers, normalized: bool,
) -> PPOTrainingContextError {
	if !ppoTrainingContextCheckpointEmpty(trainer) { return .InvalidHandle }
	if policy == nil || value == nil || policy.layerCount != 0 || value.layerCount != 0 ||
		policy.self != nil && policy.self != rawptr(policy) || value.self != nil && value.self != rawptr(value) {
		return .InvalidModel
	}
	if info.optimizer != .Adam || info.policy.maxLayers != pl || info.policy.maxWidth != pw || info.policy.batchCapacity != pb ||
		info.value.maxLayers != vl || info.value.maxWidth != vw || info.value.batchCapacity != vb { return .CheckpointIncompatible }
	if normalized {
		observation := PPOCheckpointNormalizerDescriptor{present = normalizedInfo.observation.present, width = normalizedInfo.observation.width}
		reward := PPOCheckpointNormalizerDescriptor{present = normalizedInfo.reward.present, width = normalizedInfo.reward.width}
		if !PPOCheckpointNormalizerTargetValid(observation, normalizers.observation) ||
			!PPOCheckpointNormalizerTargetValid(reward, normalizers.reward) { return .CheckpointIncompatible }
	}

	batchSize := info.fit.batchSize
	if batchSize == 0 { batchSize = min(pb, vb) }
	layout, layoutOk := ppoOwnedFitStorageLayout(rolloutCapacity, info.policy.inputWidth, info.policy.outputWidth, batchSize, info.fit.epochs)
	if !layoutOk || info.parameterPointers <= 0 || info.momentElements <= 0 ||
		info.parameterPointers > max(int)/size_of(^core.Node) || info.momentElements > max(int)/size_of(f32) {
		return .CheckpointIncompatible
	}
	sizes := [4]int{layout.total, info.parameterPointers*size_of(^core.Node), info.momentElements*size_of(f32), info.momentElements*size_of(f32)}
	alignments := [4]int{layout.alignment, align_of(^core.Node), align_of(f32), align_of(f32)}
	total := 0
	for size in sizes {
		if size > max(int)-total { return .CheckpointIncompatible }
		total += size
	}
	if maxOwnedBytes > 0 && total > maxOwnedBytes { return .CheckpointIncompatible }

	// Protect the complete trainer, destinations, input and each normalizer object
	// and backing array, not just the embedded Adam field or active model buffers.
	ranges: [14]SequentialAdamMemoryRange
	count := 0
	ok: bool
	ranges[count], ok = SequentialAdamRange(rawptr(trainer), 1, size_of(trainer^)); if !ok { return .InvalidHandle }; count += 1
	ranges[count], ok = SequentialAdamRange(rawptr(policy), 1, size_of(policy^)); if !ok { return .InvalidModel }; count += 1
	ranges[count], ok = SequentialAdamRange(rawptr(value), 1, size_of(value^)); if !ok { return .InvalidModel }; count += 1
	ranges[count], ok = SequentialAdamRange(rawptr(raw_data(input)), len(input), size_of(u8)); if !ok { return .InvalidCheckpoint }; count += 1
	if normalized {
		for normalizer in ([2]^data.RunningStandardizer{normalizers.observation, normalizers.reward}) {
			if normalizer == nil { continue }
			ranges[count], ok = SequentialAdamRange(rawptr(normalizer), 1, size_of(normalizer^)); if !ok { return .CheckpointIncompatible }; count += 1
			ranges[count], ok = SequentialAdamRange(rawptr(raw_data(normalizer.mean)), len(normalizer.mean), size_of(f64)); if !ok { return .CheckpointIncompatible }; count += 1
			ranges[count], ok = SequentialAdamRange(rawptr(raw_data(normalizer.m2)), len(normalizer.m2), size_of(f64)); if !ok { return .CheckpointIncompatible }; count += 1
		}
	}
	for current, index in ranges[:count] {
		for previous in ranges[:index] { if SequentialAdamRangesOverlap(current, previous) { return .CheckpointIncompatible } }
	}

	trainer.self, trainer.phase = rawptr(trainer), .Initializing
	trainer.pending.allocator = allocator
	for size, index in sizes {
		bytes, err := mem.alloc_bytes(size, alignments[index], allocator)
		memory := rawptr(raw_data(bytes))
		trainer.pending.blocks[index] = memory
		failure := PPOTrainingContextError.OptimizerSetupFailed
		if index == 0 { failure = .ScratchSetupFailed }
		if memory == nil || err != nil { return ppoTrainingContextInitRollback(trainer, failure) }
		allocatedRange, rangeOk := SequentialAdamRange(memory, size, 1)
		if !rangeOk || len(bytes) < size || uintptr(memory)%uintptr(alignments[index]) != 0 {
			return ppoTrainingContextInitRollback(trainer, failure)
		}
		for previous in ranges[:count] {
			if SequentialAdamRangesOverlap(allocatedRange, previous) { return ppoTrainingContextInitRollback(trainer, failure) }
		}
		ranges[count] = allocatedRange
		count += 1
	}

	parameters := mem.slice_ptr((^^core.Node)(trainer.pending.blocks[1]), info.parameterPointers)
	first := mem.slice_ptr((^f32)(trainer.pending.blocks[2]), info.momentElements)
	second := mem.slice_ptr((^f32)(trainer.pending.blocks[3]), info.momentElements)
	state: PPOTrainingState
	objective: PPOConfig
	fit: PPOFitConfig
	readOk: bool
	if normalized {
		state, objective, fit, _, readOk = PPOCheckpointReadNormalized(policy, value, input, &trainer.adam.optimizer, parameters, first, second, normalizers)
	} else {
		state, objective, fit, _, readOk = PPOCheckpointRead(policy, value, input, &trainer.adam.optimizer, parameters, first, second)
	}
	if !readOk { return ppoTrainingContextInitRollback(trainer, .InvalidCheckpoint) }

	// Publication uses only non-failing assignments after the reader has bound
	// optimizer pointers and moments at the final model/owner addresses.
	trainer.scratch = {storage = ppoOwnedFitStorageViewAt(trainer.pending.blocks[0], layout), memory = trainer.pending.blocks[0], allocator = allocator, self = rawptr(&trainer.scratch)}
	trainer.adam.parameterStorage, trainer.adam.firstMoment, trainer.adam.secondMoment = parameters, first, second
	trainer.adam.allocator, trainer.adam.self = allocator, rawptr(&trainer.adam)
	trainer.pending = {}
	trainer.policy, trainer.value = policy, value
	trainer.state, trainer.objective, trainer.fitConfig = state, objective, fit
	trainer.rolloutCapacity, trainer.observationWidth, trainer.actionCount = rolloutCapacity, info.policy.inputWidth, info.policy.outputWidth
	trainer.phase = .Ready
	return .None
}
