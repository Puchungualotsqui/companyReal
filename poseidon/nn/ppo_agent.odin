package nn

import "../rl"
import "core:mem"

PPOAgentError :: enum {
	None,
	InvalidHandle,
	InvalidOptions,
	InvalidModel,
	ModelSetupFailed,
	RolloutSetupFailed,
	TrainerSetupFailed,
	CleanupFailed,
	NotReady,
	InvalidObservation,
	InvalidActionMask,
	InvalidReward,
	RolloutFull,
	EmptyRollout,
	PendingStep,
	NoPendingStep,
	ActionSelectionFailed,
	ValuePredictionFailed,
	AppendFailed,
	ReturnCalculationFailed,
	FitFailed,
	CheckpointMeasureFailed,
	CheckpointWriteFailed,
	CheckpointReadFailed,
	PolicyExportFailed,
}

@(private)
PPOAgentPhase :: enum { Empty, Initializing, Ready, Destroying }

// A defaults-first training workflow. Layer specs describe the complete actor and
// critic stacks, including their final output layer; policySpecs must end at
// actionCount and valueSpecs at one. Input width is shared and must fit both model
// types. The agent owns heap-allocated models, one rollout, and its PPO context.
// Normalization and observation-history management remain adapter concerns; use
// the lower-level APIs when per-step preprocessing is required.
PPOAgentOptions :: struct {
	inputWidth, actionCount, rolloutCapacity: int,
	policySpecs, valueSpecs: []SequentialLayerSpec,
	trainer: PPOTrainingContextOptions,
	gamma, lambda: f32,
	normalizeAdvantages: bool,
}

PPOAgentOptionsDefault :: proc(inputWidth, actionCount, rolloutCapacity: int) -> PPOAgentOptions {
	options := PPOAgentOptions{
		inputWidth = inputWidth, actionCount = actionCount, rolloutCapacity = rolloutCapacity,
		trainer = PPOTrainingContextOptionsDefault(rolloutCapacity),
		gamma = 0.99, lambda = 0.95, normalizeAdvantages = true,
	}
	options.trainer.rolloutCapacity = rolloutCapacity
	return options
}

// Initialize at the final address. Capacity type parameters keep the explicit,
// compile-time storage model. On failure the agent is normally empty and reusable;
// if sub-owner cleanup reports an error it remains destroying and Destroy must be
// retried. Compile-time capacities must fit all specs; the actor must end in raw
// categorical logits, and the critic must end with one output value.
PPOAgent :: struct($pl, $pw, $pb: int, $vl, $vw, $vb: int) {
	policy:  OwnedSequential(pl, pw, pb),
	value:   OwnedSequential(vl, vw, vb),
	rollout: rl.OwnedRolloutBuffer,
	trainer: PPOTrainingContext(pl, pw, pb, vl, vw, vb),
	inputWidth, actionCount: int,
	gamma, lambda: f32,
	normalizeAdvantages: bool,
	allocator: mem.Allocator,
	pendingMemory: rawptr,
	pendingObservation: []f32,
	pendingLegal: []bool,
	pendingAction: int,
	pendingLogProbability: f64,
	pendingValue: f32,
	pendingValid: bool,
	self: rawptr,
	phase: PPOAgentPhase,
}

// Every action and reward is supplied by the caller. The values and action are
// computed from the current observation; nextObservation is used only when the
// episode continues. The transition is appended immediately, so the caller may
// compute and pass the environment's reward without a hidden pending-state API.
PPOAgentStepResult :: struct {
	action:         int,
	logProbability: f64,
	value:          f32,
	error:          PPOAgentError,
}

PPOAgentInit :: proc(
	agent: ^PPOAgent($pl, $pw, $pb, $vl, $vw, $vb),
	options: PPOAgentOptions,
	allocator: mem.Allocator = context.allocator,
) -> PPOAgentError {
	if agent == nil || agent.self != nil || agent.phase != .Empty { return .InvalidHandle }
	if options.inputWidth <= 0 || options.actionCount <= 0 || options.rolloutCapacity <= 0 ||
		options.trainer.policySeed == 0 ||
		len(options.policySpecs) == 0 || len(options.valueSpecs) == 0 ||
		len(options.policySpecs) > pl || len(options.valueSpecs) > vl ||
		!(options.gamma >= 0 && options.gamma <= 1) || options.gamma > 3.4028234e38 ||
		!(options.lambda >= 0 && options.lambda <= 1) || options.lambda > 3.4028234e38 {
		return .InvalidOptions
	}
	trainerOptions := options.trainer
	trainerOptions.rolloutCapacity = options.rolloutCapacity
	agent.inputWidth, agent.actionCount, agent.allocator = options.inputWidth, options.actionCount, allocator
	agent.self, agent.phase = rawptr(agent), .Initializing
	if !ppoAgentAllocatePending(agent, allocator) { return ppoAgentRollback(agent, .RolloutSetupFailed) }
	if !OwnedSequentialInit(&agent.policy, options.inputWidth, options.trainer.policySeed, allocator) ||
		!OwnedSequentialInit(&agent.value, options.inputWidth, options.trainer.shuffleSeed, allocator) {
		return ppoAgentRollback(agent, .ModelSetupFailed)
	}
	policy, value := OwnedSequentialModel(&agent.policy), OwnedSequentialModel(&agent.value)
	if policy == nil || value == nil { return ppoAgentRollback(agent, .ModelSetupFailed) }
	_, policyOk := SequentialAddSpecs(policy, options.policySpecs)
	_, valueOk := SequentialAddSpecs(value, options.valueSpecs)
	if !policyOk || !valueOk { return ppoAgentRollback(agent, .ModelSetupFailed) }
	if value.layers[value.layerCount-1].width != 1 ||
		policy.layers[policy.layerCount-1].width != options.actionCount {
		return ppoAgentRollback(agent, .InvalidModel)
	}
	if _, isSoftmax := SequentialLogitsOutputLayer(policy).(^Softmax); isSoftmax {
		return ppoAgentRollback(agent, .InvalidModel)
	}
	if !rl.OwnedRolloutBufferInit(&agent.rollout, options.rolloutCapacity, options.inputWidth, options.actionCount, allocator) {
		return ppoAgentRollback(agent, .RolloutSetupFailed)
	}
	rollout := rl.OwnedRolloutBufferBorrow(&agent.rollout)
	if rollout == nil { return ppoAgentRollback(agent, .RolloutSetupFailed) }
	trainerError := PPOTrainingContextInit(&agent.trainer, policy, value, trainerOptions, allocator)
	if trainerError != .None {
		return ppoAgentRollback(agent, .TrainerSetupFailed)
	}
	agent.gamma, agent.lambda, agent.normalizeAdvantages = options.gamma, options.lambda, options.normalizeAdvantages
	agent.self, agent.phase = rawptr(agent), .Ready
	return .None
}

@(private="file")
ppoAgentAllocatePending :: proc(agent: ^PPOAgent($pl, $pw, $pb, $vl, $vw, $vb), allocator: mem.Allocator) -> bool {
	if agent.inputWidth <= 0 || agent.actionCount <= 0 || agent.inputWidth > max(int)/size_of(f32) ||
		agent.inputWidth*size_of(f32) > max(int)-agent.actionCount { return false }
	total := agent.inputWidth*size_of(f32)+agent.actionCount
	bytes, err := mem.alloc_bytes(total, align_of(f32), allocator)
	memory := rawptr(raw_data(bytes))
	if memory == nil || err != nil || len(bytes) < total || uintptr(memory)%uintptr(align_of(f32)) != 0 {
		if memory != nil { _ = mem.free(memory, allocator) }
		return false
	}
	agent.pendingMemory = memory
	agent.pendingObservation = mem.slice_ptr((^f32)(memory), agent.inputWidth)
	agent.pendingLegal = mem.slice_ptr((^bool)(rawptr(uintptr(memory)+uintptr(agent.inputWidth*size_of(f32)))), agent.actionCount)
	return true
}

@(private="file")
ppoAgentFreePending :: proc(agent: ^PPOAgent($pl, $pw, $pb, $vl, $vw, $vb)) -> bool {
	if agent.pendingMemory == nil { return true }
	if mem.free(agent.pendingMemory, agent.allocator) != nil { return false }
	agent.pendingMemory = nil
	agent.pendingObservation, agent.pendingLegal = nil, nil
	agent.pendingValid = false
	return true
}

@(private="file")
ppoAgentRollback :: proc(agent: ^PPOAgent($pl, $pw, $pb, $vl, $vw, $vb), failure: PPOAgentError) -> PPOAgentError {
	agent.phase = .Destroying
	ok := true
	if PPOTrainingContextDestroy(&agent.trainer) != .None { ok = false }
	if !rl.OwnedRolloutBufferDestroy(&agent.rollout) { ok = false }
	if !ppoAgentFreePending(agent) { ok = false }
	if !OwnedSequentialDestroy(&agent.value) { ok = false }
	if !OwnedSequentialDestroy(&agent.policy) { ok = false }
	if !ok { return .CleanupFailed }
	agent^ = {}
	agent.phase = .Empty
	return failure
}

PPOAgentPolicy :: proc(agent: ^PPOAgent($pl, $pw, $pb, $vl, $vw, $vb)) -> ^Sequential(pl, pw, pb) {
	if agent == nil || agent.self != rawptr(agent) || agent.phase != .Ready { return nil }
	return OwnedSequentialModel(&agent.policy)
}

PPOAgentValue :: proc(agent: ^PPOAgent($pl, $pw, $pb, $vl, $vw, $vb)) -> ^Sequential(vl, vw, vb) {
	if agent == nil || agent.self != rawptr(agent) || agent.phase != .Ready { return nil }
	return OwnedSequentialModel(&agent.value)
}

PPOAgentRollout :: proc(agent: ^PPOAgent($pl, $pw, $pb, $vl, $vw, $vb)) -> ^rl.RolloutBuffer {
	if agent == nil || agent.self != rawptr(agent) || agent.phase != .Ready { return nil }
	return rl.OwnedRolloutBufferBorrow(&agent.rollout)
}

PPOAgentState :: proc(agent: ^PPOAgent($pl, $pw, $pb, $vl, $vw, $vb)) -> ^PPOTrainingState {
	if agent == nil || agent.self != rawptr(agent) || agent.phase != .Ready { return nil }
	return PPOTrainingContextState(&agent.trainer)
}

PPOAgentActionCount :: proc(agent: ^PPOAgent($pl, $pw, $pb, $vl, $vw, $vb)) -> int {
	if agent == nil || agent.self != rawptr(agent) || agent.phase != .Ready { return 0 }
	return agent.actionCount
}

PPOAgentRolloutFull :: proc(agent: ^PPOAgent($pl, $pw, $pb, $vl, $vw, $vb)) -> bool {
	buffer := PPOAgentRollout(agent)
	return buffer != nil && rl.RolloutBufferFull(buffer)
}

// Computes the current value and action and stores a pending transition. Call this
// before stepping the environment, then call Observe with the resulting reward and
// flags. Inputs are validated before pending state changes. Caller buffers may not
// alias agent storage. One pending step may exist at a time.
PPOAgentAct :: proc(
	agent: ^PPOAgent($pl, $pw, $pb, $vl, $vw, $vb),
	observation: []f32,
	legal: []bool,
	mode: PolicyEvaluationMode = .Stochastic,
) -> PPOAgentStepResult {
	if agent == nil || agent.self != rawptr(agent) || agent.phase != .Ready { return {error = .InvalidHandle} }
	policy, value, buffer := PPOAgentPolicy(agent), PPOAgentValue(agent), PPOAgentRollout(agent)
	state := PPOAgentState(agent)
	if policy == nil || value == nil || buffer == nil || state == nil || agent.pendingMemory == nil { return {error = .NotReady} }
	if agent.pendingValid { return {error = .PendingStep} }
	if rl.RolloutBufferFull(buffer) { return {error = .RolloutFull} }
	if len(observation) != agent.inputWidth { return {error = .InvalidObservation} }
	if len(legal) != agent.actionCount { return {error = .InvalidActionMask} }
	for item in observation { if !rolloutFiniteF32(item) { return {error = .InvalidObservation} } }
	legalCount := 0
	for allowed in legal { if allowed { legalCount += 1 } }
	if legalCount == 0 { return {error = .InvalidActionMask} }
	currentValue, valueOk := SequentialPredictScalar(value, observation)
	if !valueOk { return {error = .ValuePredictionFailed} }
	action, logProbability, actionOk := SequentialPolicyAction(policy, observation, legal, mode, &state.policyRandomState)
	if !actionOk { return {error = .ActionSelectionFailed} }
	copy(agent.pendingObservation, observation)
	copy(agent.pendingLegal, legal)
	agent.pendingAction, agent.pendingLogProbability, agent.pendingValue = action, logProbability, currentValue
	agent.pendingValid = true
	return {action = action, logProbability = logProbability, value = currentValue, error = .None}
}

// Completes the pending Act after the environment has advanced. The pending
// transition is appended using the stored observation/legal mask and the supplied
// reward/flags. On failure the pending step is retained so the caller can correct
// transient input errors and retry. A terminal step ignores nextObservation.
PPOAgentObserve :: proc(
	agent: ^PPOAgent($pl, $pw, $pb, $vl, $vw, $vb),
	reward: f32,
	terminated, truncated: bool,
	nextObservation: []f32,
) -> PPOAgentError {
	if agent == nil || agent.self != rawptr(agent) || agent.phase != .Ready { return .InvalidHandle }
	if !agent.pendingValid { return .NoPendingStep }
	if terminated && truncated { return .InvalidReward }
	if !rolloutFiniteF32(reward) { return .InvalidReward }
	buffer, value := PPOAgentRollout(agent), PPOAgentValue(agent)
	if buffer == nil || value == nil { return .NotReady }
	nextValue: f32
	if !terminated {
		if len(nextObservation) != agent.inputWidth { return .InvalidObservation }
		for item in nextObservation { if !rolloutFiniteF32(item) { return .InvalidObservation } }
		prediction, nextOk := SequentialPredictScalar(value, nextObservation)
		if !nextOk { return .ValuePredictionFailed }
		nextValue = prediction
	}
	if !rl.RolloutBufferAppend(buffer, rl.RolloutTransition{
		observation = agent.pendingObservation, action = agent.pendingAction, reward = reward,
		value = agent.pendingValue, nextValue = nextValue,
		oldLogProbability = agent.pendingLogProbability, legalActions = agent.pendingLegal,
		terminated = terminated, truncated = truncated,
	}) { return .AppendFailed }
	agent.pendingValid = false
	return .None
}

// Convenience for synthetic loops where the reward is known immediately. Real
// environments should call Act, advance their state, then Observe.
PPOAgentStep :: proc(
	agent: ^PPOAgent($pl, $pw, $pb, $vl, $vw, $vb),
	observation: []f32,
	legal: []bool,
	reward: f32,
	terminated, truncated: bool,
	nextObservation: []f32,
	mode: PolicyEvaluationMode = .Stochastic,
) -> PPOAgentStepResult {
	result := PPOAgentAct(agent, observation, legal, mode)
	if result.error != .None { return result }
	result.error = PPOAgentObserve(agent, reward, terminated, truncated, nextObservation)
	return result
}

// Computes GAE, optionally normalizes advantages, records the rollout, and fits.
// On success the rollout is reset; on failure it is preserved for inspection.
// A late FitFailed can still have committed minibatches and advanced RNG state.
PPOAgentTrain :: proc(agent: ^PPOAgent($pl, $pw, $pb, $vl, $vw, $vb)) -> (PPOFitStats, PPOAgentError) {
	if agent == nil || agent.self != rawptr(agent) || agent.phase != .Ready { return {}, .InvalidHandle }
	if agent.pendingValid { return {}, .PendingStep }
	buffer := PPOAgentRollout(agent)
	if buffer == nil || buffer.count <= 0 { return {}, .EmptyRollout }
	if !rl.RolloutComputeGAE(buffer, agent.gamma, agent.lambda) { return {}, .ReturnCalculationFailed }
	if agent.normalizeAdvantages && !rl.RolloutNormalizeAdvantages(buffer) { return {}, .ReturnCalculationFailed }
	if PPOTrainingContextRecordRollout(&agent.trainer) != .None { return {}, .ReturnCalculationFailed }
	stats, fitError := PPOTrainingContextFit(&agent.trainer, buffer)
	if fitError != .None { return stats, .FitFailed }
	if !rl.RolloutBufferReset(buffer) { return stats, .ReturnCalculationFailed }
	return stats, .None
}

PPOAgentCheckpointMeasure :: proc(agent: ^PPOAgent($pl, $pw, $pb, $vl, $vw, $vb)) -> (PPOCheckpointBufferSizes, PPOAgentError) {
	if agent == nil || agent.self != rawptr(agent) || agent.phase != .Ready { return {}, .InvalidHandle }
	optimizer, state := PPOTrainingContextOptimizer(&agent.trainer), PPOAgentState(agent)
	if optimizer == nil || state == nil { return {}, .NotReady }
	sizes, ok := PPOCheckpointMeasure(PPOAgentPolicy(agent), PPOAgentValue(agent), optimizer, state^, agent.trainer.objective, agent.trainer.fitConfig)
	if !ok { return {}, .CheckpointMeasureFailed }
	return sizes, .None
}

PPOAgentCheckpointWrite :: proc(
	agent: ^PPOAgent($pl, $pw, $pb, $vl, $vw, $vb),
	output, policyScratch, valueScratch: []u8,
) -> (int, PPOAgentError) {
	if agent == nil || agent.self != rawptr(agent) || agent.phase != .Ready { return 0, .InvalidHandle }
	if agent.pendingValid { return 0, .PendingStep }
	size, writeError := PPOTrainingContextCheckpointWrite(&agent.trainer, output, policyScratch, valueScratch)
	if writeError != .None { return 0, .CheckpointWriteFailed }
	return size, .None
}

PPOAgentCheckpointRead :: proc(agent: ^PPOAgent($pl, $pw, $pb, $vl, $vw, $vb), input: []u8) -> PPOAgentError {
	if agent == nil || agent.self != rawptr(agent) || agent.phase != .Ready { return .InvalidHandle }
	if agent.pendingValid { return .PendingStep }
	if PPOTrainingContextCheckpointRead(&agent.trainer, input) != .None { return .CheckpointReadFailed }
	return .None
}

PPOAgentPolicyExportMeasure :: proc(agent: ^PPOAgent($pl, $pw, $pb, $vl, $vw, $vb)) -> (int, int, PPOAgentError) {
	if agent == nil || agent.self != rawptr(agent) || agent.phase != .Ready { return 0, 0, .InvalidHandle }
	output, scratch, ok := PPOPolicyExportMeasure(PPOAgentPolicy(agent), nil)
	if !ok { return 0, 0, .CheckpointMeasureFailed }
	return output, scratch, .None
}

PPOAgentPolicyExportWrite :: proc(agent: ^PPOAgent($pl, $pw, $pb, $vl, $vw, $vb), output, modelScratch: []u8) -> (int, PPOAgentError) {
	if agent == nil || agent.self != rawptr(agent) || agent.phase != .Ready { return 0, .InvalidHandle }
	size, ok := PPOPolicyExportWrite(PPOAgentPolicy(agent), nil, output, modelScratch)
	if !ok { return 0, .PolicyExportFailed }
	return size, .None
}

PPOAgentDestroy :: proc(agent: ^PPOAgent($pl, $pw, $pb, $vl, $vw, $vb)) -> PPOAgentError {
	if agent == nil { return .InvalidHandle }
	if agent.self == nil && agent.phase == .Empty { return .None }
	if agent.self != rawptr(agent) { return .InvalidHandle }
	agent.phase = .Destroying
	ok := true
	if PPOTrainingContextDestroy(&agent.trainer) != .None { ok = false }
	if PPOTrainingContextDestroy(&agent.trainer) != .None { ok = false }
	if !rl.OwnedRolloutBufferDestroy(&agent.rollout) { ok = false }
	if !ppoAgentFreePending(agent) { ok = false }
	if !OwnedSequentialDestroy(&agent.value) { ok = false }
	if !OwnedSequentialDestroy(&agent.policy) { ok = false }
	if !ok { return .CleanupFailed }
	agent^ = {}
	return .None
}

@(private)
rolloutFiniteF32 :: proc(value: f32) -> bool {
	return value >= -3.402823466e+38 && value <= 3.402823466e+38
}
