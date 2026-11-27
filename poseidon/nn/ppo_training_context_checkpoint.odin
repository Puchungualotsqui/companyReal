package nn

// epochMetrics is the final field in the checked scratch layout, so its end
// describes the complete allocation, including alignment padding between slices.
@(private)
ppoTrainingContextScratchRange :: proc(
	trainer: ^PPOTrainingContext($pl, $pw, $pb, $vl, $vw, $vb),
) -> (SequentialAdamMemoryRange, bool) {
	storage, ok := PPOOwnedFitStorageView(&trainer.scratch)
	if !ok { return {}, false }
	last, valid := SequentialAdamRange(rawptr(raw_data(storage.epochMetrics)), len(storage.epochMetrics), size_of(PPOEpochStats))
	start := uintptr(trainer.scratch.memory)
	if !valid || last.address < start || last.bytes > max(uintptr)-(last.address-start) { return {}, false }
	return {start, last.address-start+last.bytes}, true
}

// The checkpoint and staging buffers must also be disjoint from the complete
// trainer and its reusable fit allocation, not merely the exposed scratch slices.
@(private)
ppoTrainingContextCheckpointBufferDisjoint :: proc(
	trainer: ^PPOTrainingContext($pl, $pw, $pb, $vl, $vw, $vb),
	buffer: []u8,
) -> bool {
	trainerRange, trainerOk := SequentialAdamRange(rawptr(trainer), 1, size_of(trainer^))
	bufferRange, bufferOk := SequentialAdamRange(rawptr(raw_data(buffer)), len(buffer), size_of(u8))
	scratchRange, scratchOk := ppoTrainingContextScratchRange(trainer)
	return trainerOk && bufferOk && scratchOk && !SequentialAdamRangesOverlap(trainerRange, bufferRange) &&
		!SequentialAdamRangesOverlap(scratchRange, bufferRange)
}

// Writes a base PPO checkpoint using caller-owned output and model staging
// buffers. Save only at a successful fit boundary; rollout, environment and
// observation-history state are not saved. The buffers must obey the complete
// PPOCheckpointWrite disjointness contract and must not overlap the trainer or
// its fit scratch. No allocation occurs. This wrapper does not export normalizers.
PPOTrainingContextCheckpointWrite :: proc(
	trainer: ^PPOTrainingContext($pl, $pw, $pb, $vl, $vw, $vb),
	output, policyScratch, valueScratch: []u8,
) -> (int, PPOTrainingContextError) {
	state := PPOTrainingContextState(trainer)
	optimizer := PPOTrainingContextOptimizer(trainer)
	if state == nil || optimizer == nil { return 0, .InvalidHandle }
	if !ppoTrainingContextCheckpointBufferDisjoint(trainer, output) ||
		!ppoTrainingContextCheckpointBufferDisjoint(trainer, policyScratch) ||
		!ppoTrainingContextCheckpointBufferDisjoint(trainer, valueScratch) { return 0, .CheckpointWriteFailed }
	size, ok := PPOCheckpointWrite(trainer.policy, trainer.value, optimizer, state^, trainer.objective, trainer.fitConfig, output, policyScratch, valueScratch)
	if !ok { return 0, .CheckpointWriteFailed }
	return size, .None
}

// Restores a base Adam PPO checkpoint into this trainer's existing models and
// optimizer. The encoded model capacities must match their compile-time types;
// input/output widths must match the context, and checkpoint parameter counts,
// minibatch size and epoch count must fit the existing owned buffers. A context
// can therefore restore a smaller architecture but cannot grow its allocations.
// Initialize the context with sufficiently large models and options first.
//
// Before mutating destinations this checks the nested supervised payloads and
// storage requirements, then delegates full validation/restore to PPOCheckpointRead.
// Malformed/incompatible checkpoints leave the trainer and models unchanged under
// that reader's contract. Input must remain unchanged, valid and disjoint from the
// complete trainer, scratch, models and optimizer. Restoring reconstructs models
// using inline parameter buffers and invalidates existing model-internal borrows.
// Learner state, configs, Adam moments and RNGs are restored; rollout/environment
// state remains the adapter's responsibility. The reader does not allocate or use
// model-sized stack probes. Normalized PPO checkpoints are not accepted here.
PPOTrainingContextCheckpointRead :: proc(
	trainer: ^PPOTrainingContext($pl, $pw, $pb, $vl, $vw, $vb),
	input: []u8,
) -> PPOTrainingContextError {
	state := PPOTrainingContextState(trainer)
	optimizer := PPOTrainingContextOptimizer(trainer)
	if state == nil || optimizer == nil { return .InvalidHandle }
	if !ppoTrainingContextCheckpointBufferDisjoint(trainer, input) { return .InvalidCheckpoint }
	limits := PPOCheckpointInspectLimits{
		policy = {maxLayers = pl, maxWidth = pw, maxBatchCapacity = pb},
		value = {maxLayers = vl, maxWidth = vw, maxBatchCapacity = vb},
	}
	info, err := PPOCheckpointInspect(input, limits)
	if err.code == .InvalidValue && err.offset == 88 { return .CheckpointIncompatible }
	if err.code != .None { return ppoTrainingContextInspectionError(err) }
	if !ppoTrainingContextCheckpointCompatible(trainer, info) { return .CheckpointIncompatible }
	parameters, first, second, storageOk := PPOOwnedAdamStorage(&trainer.adam)
	if !storageOk { return .InvalidHandle }
	restoredState, objective, fitConfig, _, ok := PPOCheckpointRead(trainer.policy, trainer.value, input, optimizer, parameters, first, second)
	if !ok { return .InvalidCheckpoint }
	trainer.state, trainer.objective, trainer.fitConfig = restoredState, objective, fitConfig
	return .None
}

@(private)
ppoTrainingContextCheckpointCompatible :: proc(
	trainer: ^PPOTrainingContext($pl, $pw, $pb, $vl, $vw, $vb), info: PPOCheckpointInfo,
) -> bool {
	if info.optimizer != .Adam || info.policy.maxLayers != pl || info.policy.maxWidth != pw || info.policy.batchCapacity != pb ||
		info.value.maxLayers != vl || info.value.maxWidth != vw || info.value.batchCapacity != vb ||
		info.policy.inputWidth != trainer.observationWidth || info.value.inputWidth != trainer.observationWidth ||
		info.policy.outputWidth != trainer.actionCount || info.value.outputWidth != 1 { return false }
	parameters, first, second, adamOk := PPOOwnedAdamStorage(&trainer.adam)
	storage, scratchOk := PPOOwnedFitStorageView(&trainer.scratch)
	if !adamOk || !scratchOk || info.parameterPointers > len(parameters) || info.momentElements > len(first) ||
		info.momentElements > len(second) || info.fit.epochs > len(storage.epochMetrics) { return false }
	rows := info.fit.batchSize
	if rows == 0 { rows = min(pb, vb) }
	return min(rows, trainer.rolloutCapacity) <= len(storage.actions)
}
