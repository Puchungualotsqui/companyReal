package nn

import "../data"

// The lower-level normalized checkpoint APIs know the model and Adam ranges,
// but the normalizers must also be disjoint from the full trainer and scratch.
@(private="file")
ppoTrainingContextNormalizersDisjoint :: proc(
	trainer: ^PPOTrainingContext($pl, $pw, $pb, $vl, $vw, $vb), normalizers: PPOTrainingNormalizers,
) -> bool {
	trainerRange, valid := SequentialAdamRange(rawptr(trainer), 1, size_of(trainer^))
	scratchRange, scratchOk := ppoTrainingContextScratchRange(trainer)
	if !valid || !scratchOk { return false }
	for normalizer in ([2]^data.RunningStandardizer{normalizers.observation, normalizers.reward}) {
		if normalizer == nil { continue }
		if !data.RunningStandardizerValid(normalizer) { return false }
		ranges: [3]SequentialAdamMemoryRange
		ranges[0], valid = SequentialAdamRange(rawptr(normalizer), 1, size_of(normalizer^)); if !valid { return false }
		ranges[1], valid = SequentialAdamRange(rawptr(raw_data(normalizer.mean)), len(normalizer.mean), size_of(f64)); if !valid { return false }
		ranges[2], valid = SequentialAdamRange(rawptr(raw_data(normalizer.m2)), len(normalizer.m2), size_of(f64)); if !valid { return false }
		for range in ranges {
			if SequentialAdamRangesOverlap(range, trainerRange) || SequentialAdamRangesOverlap(range, scratchRange) { return false }
		}
	}
	return true
}

// Writes a normalized PPO checkpoint at a successful fit boundary. All four
// byte buffers and caller-owned normalizers must be mutually disjoint and obey
// PPOCheckpointWriteNormalized's contracts, including disjointness from the
// entire trainer and fit scratch. No allocation occurs.
PPOTrainingContextCheckpointWriteNormalized :: proc(
	trainer: ^PPOTrainingContext($pl, $pw, $pb, $vl, $vw, $vb),
	normalizers: PPOTrainingNormalizers,
	output, checkpointScratch, policyScratch, valueScratch: []u8,
) -> (int, PPOTrainingContextError) {
	state := PPOTrainingContextState(trainer)
	optimizer := PPOTrainingContextOptimizer(trainer)
	if state == nil || optimizer == nil { return 0, .InvalidHandle }
	if !ppoTrainingContextCheckpointBufferDisjoint(trainer, output) ||
		!ppoTrainingContextCheckpointBufferDisjoint(trainer, checkpointScratch) ||
		!ppoTrainingContextCheckpointBufferDisjoint(trainer, policyScratch) ||
		!ppoTrainingContextCheckpointBufferDisjoint(trainer, valueScratch) ||
		!ppoTrainingContextNormalizersDisjoint(trainer, normalizers) { return 0, .CheckpointWriteFailed }
	size, ok := PPOCheckpointWriteNormalized(trainer.policy, trainer.value, optimizer, state^, trainer.objective, trainer.fitConfig,
		normalizers, output, checkpointScratch, policyScratch, valueScratch)
	if !ok { return 0, .CheckpointWriteFailed }
	return size, .None
}

// Restores a normalized Adam checkpoint into an existing ready trainer. The
// encoded capacities, widths and optimizer/fit storage requirements must fit
// the trainer, and caller-owned normalizer targets must match presence and width.
// All pointers and buffers must be valid, disjoint and externally synchronized.
// Models are rebuilt in place; discard their previous internal borrows. The
// reader preflights the complete checkpoint before changing destinations.
PPOTrainingContextCheckpointReadNormalized :: proc(
	trainer: ^PPOTrainingContext($pl, $pw, $pb, $vl, $vw, $vb),
	input: []u8, normalizers: PPOTrainingNormalizers,
) -> PPOTrainingContextError {
	state := PPOTrainingContextState(trainer)
	optimizer := PPOTrainingContextOptimizer(trainer)
	if state == nil || optimizer == nil { return .InvalidHandle }
	if !ppoTrainingContextCheckpointBufferDisjoint(trainer, input) ||
		!ppoTrainingContextNormalizersDisjoint(trainer, normalizers) { return .InvalidCheckpoint }
	limits := PPONormalizedCheckpointInspectLimits{base = {
		policy = {maxLayers = pl, maxWidth = pw, maxBatchCapacity = pb},
		value = {maxLayers = vl, maxWidth = vw, maxBatchCapacity = vb},
	}}
	info, err := PPOCheckpointInspectNormalized(input, limits)
	if err.code != .None { return ppoTrainingContextInspectionError(err) }
	if !ppoTrainingContextCheckpointCompatible(trainer, info.base) { return .CheckpointIncompatible }
	parameters, first, second, storageOk := PPOOwnedAdamStorage(&trainer.adam)
	if !storageOk { return .InvalidHandle }
	restoredState, objective, fit, _, ok := PPOCheckpointReadNormalized(
		trainer.policy, trainer.value, input, optimizer, parameters, first, second, normalizers,
	)
	if !ok { return .InvalidCheckpoint }
	trainer.state, trainer.objective, trainer.fitConfig = restoredState, objective, fit
	return .None
}
