package nn

import "../rl"

// PPOTrainingState is the caller-owned, resumable learner state at PPO update
// boundaries. The game adapter owns environment state; save/reset it separately.
PPOTrainingState :: struct {
	updateCount:        u64,
	rolloutCount:       u64,
	policyRandomState:  u64,
	shuffleRandomState: u64,
}

// Policy sampling uses xorshift and therefore requires a nonzero initial seed.
// A zero shuffle seed is valid. Initialization leaves both counters at zero.
PPOTrainingStateInit :: proc(state: ^PPOTrainingState, policySeed, shuffleSeed: u64) -> bool {
	if state == nil || policySeed == 0 do return false
	state^ = PPOTrainingState{
		policyRandomState = policySeed,
		shuffleRandomState = shuffleSeed,
	}
	return true
}

// Call once after collection and return/advantage calculation complete. Poseidon
// does not own the environment loop or automatically increment this counter.
PPOTrainingStateRecordRollout :: proc(state: ^PPOTrainingState) -> bool {
	if state == nil || state.policyRandomState == 0 || state.rolloutCount == max(u64) do return false
	state.rolloutCount += 1
	return true
}

PPOFitMaximumUpdates :: proc(count, batchSize, epochs: int) -> (u64, bool) {
	if count <= 0 || batchSize <= 0 || epochs <= 0 do return 0, false
	updatesPerEpoch := 1+(count-1)/batchSize
	if epochs > max(int)/updatesPerEpoch do return 0, false
	updates := epochs*updatesPerEpoch
	return u64(updates), true
}

// Stateful PPO fit advances the shuffle RNG and cumulative update counter. It
// counts every minibatch that actually committed, even if a later minibatch
// fails; checkpoint only after a successful fit to preserve the update boundary.
SequentialPPOFitStateful :: proc(
	policy: ^Sequential($policyMaxLayers, $policyMaxWidth, $policyBatchCapacity),
	value: ^Sequential($valueMaxLayers, $valueMaxWidth, $valueBatchCapacity),
	buffer: ^rl.RolloutBuffer,
	state: ^PPOTrainingState,
	config: PPOConfig,
	fitConfig: PPOFitConfig,
	optimizer: SequentialOptimizer,
	storage: PPOFitStorage,
) -> (PPOFitStats, bool) {
	if state == nil || state.policyRandomState == 0 || !rl.RolloutBufferValid(buffer) ||
		!PPOFitConfigValid(fitConfig) || buffer.count <= 0 {
		return {}, false
	}
	batchSize := fitConfig.batchSize
	if batchSize == 0 { batchSize = min(policyBatchCapacity, valueBatchCapacity) }
	batchSize = min(batchSize, buffer.count)
	if batchSize <= 0 do return {}, false
	maximumUpdates, countOk := PPOFitMaximumUpdates(buffer.count, batchSize, fitConfig.epochs)
	if !countOk || state.updateCount > max(u64)-maximumUpdates do return {}, false
	stats, ok := SequentialPPOFit(
		policy, value, buffer, &state.shuffleRandomState, config, fitConfig, optimizer, storage,
	)
	state.updateCount += u64(stats.updates)
	return stats, ok
}
