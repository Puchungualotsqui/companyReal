package nn

// The checkpoint and staging buffers must also be disjoint from the complete
// trainer and its reusable fit scratch, not merely its embedded Adam field.
@(private="file")
ppoTrainingContextCheckpointBufferDisjoint :: proc(
	trainer: ^PPOTrainingContext($pl, $pw, $pb, $vl, $vw, $vb),
	buffer: []u8,
) -> bool {
	trainerRange, trainerOk := PPOFitMemoryRangeOf(rawptr(trainer), 1, size_of(trainer^))
	bufferRange, bufferOk := PPOFitMemoryRangeOf(rawptr(raw_data(buffer)), len(buffer), size_of(u8))
	storage, storageOk := PPOOwnedFitStorageView(&trainer.scratch)
	return trainerOk && bufferOk && storageOk && !PPOFitMemoryRangesOverlap(trainerRange, bufferRange) &&
		!PPOFitScratchOverlaps(storage, rawptr(raw_data(buffer)), len(buffer), size_of(u8))
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
	policyInput, valueInput, peekOk := PPOCheckpointPeekModelPayloads(input)
	if !peekOk { return .InvalidCheckpoint }
	policyInfo, policyError := CheckpointInspect(policyInput, CheckpointInspectLimits{maxLayers = pl, maxWidth = pw, maxBatchCapacity = pb})
	valueInfo, valueError := CheckpointInspect(valueInput, CheckpointInspectLimits{maxLayers = vl, maxWidth = vw, maxBatchCapacity = vb})
	if policyError.code == .LimitExceeded || valueError.code == .LimitExceeded { return .CheckpointIncompatible }
	if policyError.code != .None || valueError.code != .None { return .InvalidCheckpoint }
	if policyInfo.maxLayers != pl || policyInfo.maxWidth != pw || policyInfo.batchCapacity != pb ||
		valueInfo.maxLayers != vl || valueInfo.maxWidth != vw || valueInfo.batchCapacity != vb ||
		policyInfo.hasAdam || valueInfo.hasAdam || policyInfo.inputWidth != trainer.observationWidth ||
		valueInfo.inputWidth != trainer.observationWidth || policyInfo.outputRank != 2 || valueInfo.outputRank != 2 ||
		policyInfo.outputWidth != trainer.actionCount || valueInfo.outputWidth != 1 {
		return .CheckpointIncompatible
	}
	parameters, first, second, storageOk := PPOOwnedAdamStorage(&trainer.adam)
	storage, fitStorageOk := PPOOwnedFitStorageView(&trainer.scratch)
	if !storageOk || !fitStorageOk { return .InvalidHandle }
	if policyInfo.parameterPointers > max(int)-valueInfo.parameterPointers || policyInfo.momentElements > max(int)-valueInfo.momentElements ||
		policyInfo.parameterPointers+valueInfo.parameterPointers > len(parameters) ||
		policyInfo.momentElements+valueInfo.momentElements > len(first) ||
		policyInfo.momentElements+valueInfo.momentElements > len(second) { return .CheckpointIncompatible }

	// PPO checkpoint v1 stores epochs and batch size after its fixed header,
	// learner state and four objective floats. PeekModelPayloads checked version.
	offset := 80
	epochs, epochsOk := CheckpointGet64(input, &offset)
	batchSize, batchOk := CheckpointGet64(input, &offset)
	if !epochsOk || !batchOk || epochs == 0 || epochs > u64(max(int)) || batchSize > u64(max(int)) { return .InvalidCheckpoint }
	_, gradientOk := CheckpointGet32(input, &offset)
	_, rateOk := CheckpointGet32(input, &offset)
	kind, kindOk := CheckpointGet64(input, &offset)
	if !gradientOk || !rateOk || !kindOk || kind > 1 { return .InvalidCheckpoint }
	if kind != 1 || epochs > u64(len(storage.epochMetrics)) || batchSize > u64(min(pb, vb)) { return .CheckpointIncompatible }
	rows := int(batchSize)
	if rows == 0 { rows = min(pb, vb) }
	rows = min(rows, trainer.rolloutCapacity)
	if rows > len(storage.actions) { return .CheckpointIncompatible }

	restoredState, objective, fitConfig, _, ok := PPOCheckpointRead(trainer.policy, trainer.value, input, optimizer, parameters, first, second)
	if !ok { return .InvalidCheckpoint }
	trainer.state, trainer.objective, trainer.fitConfig = restoredState, objective, fitConfig
	return .None
}
