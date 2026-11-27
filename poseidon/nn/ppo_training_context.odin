package nn

import "../core"
import "../rl"
import "core:mem"

// Errors identify the stage that failed. Setup failures from the underlying
// boolean APIs may mean allocation or another validation failure; FitFailed may
// occur after some minibatches have committed. None means success.
PPOTrainingContextError :: enum {
	None,
	InvalidHandle,
	InvalidOptions,
	InvalidModel,
	ScratchSetupFailed,
	OptimizerSetupFailed,
	CleanupFailed,
	InvalidState,
	InvalidRollout,
	FitFailed,
	InvalidCheckpoint,
	CheckpointIncompatible,
	CheckpointWriteFailed,
}

PPOTrainingContextOptions :: struct {
	rolloutCapacity: int,
	objective: PPOConfig,
	fit: PPOFitConfig,
	policySeed, shuffleSeed: u64,
	learningRate, beta1, beta2, epsilon: f32,
}

// The caller supplies the maximum number of transitions in a fit; model input
// and action widths and default minibatch size are inferred from the models.
PPOTrainingContextOptionsDefault :: proc(rolloutCapacity: int) -> PPOTrainingContextOptions {
	return {
		rolloutCapacity = rolloutCapacity,
		objective = {clipRange = 0.2, entropyCoefficient = 0.01, valueCoefficient = 0.5, valueHuberDelta = 1},
		fit = {epochs = 4, batchSize = 0, maxGradientNorm = 0.5},
		policySeed = 1, shuffleSeed = 2,
		learningRate = 0.001, beta1 = 0.9, beta2 = 0.999, epsilon = 1e-8,
	}
}

@(private)
PPOTrainingContextPhase :: enum { Empty, Initializing, Ready, Destroying }

// Initialization records every allocation until it can transfer ownership to
// the embedded fit/Adam owners. A reported free error leaves its pointer here.
@(private)
PPOTrainingContextPending :: struct {
	allocator: mem.Allocator,
	blocks: [4]rawptr,
}

@(private)
ppoTrainingContextFreePending :: proc(pending: ^PPOTrainingContextPending) -> bool {
	ok := true
	for index := len(pending.blocks)-1; index >= 0; index -= 1 {
		if pending.blocks[index] != nil {
			if mem.free(pending.blocks[index], pending.allocator) == nil {
				pending.blocks[index] = nil
			} else {
				ok = false
			}
		}
	}
	return ok
}

// Owns shared Adam buffers, reusable PPO fit scratch, and learner state/config;
// it does not own either model, the rollout, or an environment. The models and
// any external parameter data must outlive the trainer and remain at their final
// addresses. Initialize the zero-valued trainer at its final address and do not
// copy, move, overwrite or edit it while live. The guard detects ordinary copies,
// not dangling pointers, stale copies written back, or direct field tampering.
// Stop all borrowers before destroying, reinitializing or changing either model.
// External synchronization is required for the trainer, models and borrowers.
//
// The allocator and its state must remain alive and unmoved through destruction.
// Its allocations must be aligned, individually freeable, and disjoint from the
// whole trainer, both models, external parameter buffers, allocator state, rollout,
// and each other. Every non-nil pointer returned, including one returned with an
// allocation error, must be individually freeable. A reported free error leaves
// ownership ambiguous: retry Destroy only if the allocator guarantees that the
// allocation remains intact; otherwise use allocator-specific cleanup.
PPOTrainingContext :: struct(
	$policyMaxLayers, $policyMaxWidth, $policyBatchCapacity: int,
	$valueMaxLayers, $valueMaxWidth, $valueBatchCapacity: int,
) {
	policy: ^Sequential(policyMaxLayers, policyMaxWidth, policyBatchCapacity),
	value: ^Sequential(valueMaxLayers, valueMaxWidth, valueBatchCapacity),
	state: PPOTrainingState,
	objective: PPOConfig,
	fitConfig: PPOFitConfig,
	rolloutCapacity, observationWidth, actionCount: int,
	adam: PPOOwnedAdam,
	scratch: PPOOwnedFitStorage,
	pending: PPOTrainingContextPending,
	self: rawptr,
	phase: PPOTrainingContextPhase,
}

@(private="file")
ppoTrainingContextModelDisjoint :: proc(model: ^Sequential($maxLayers, $maxWidth, $batchCapacity), contextRange: PPOFitMemoryRange) -> bool {
	parameters: [2*maxLayers]^core.Node
	nodes: [1+3*maxLayers]^core.Node
	_, nodeList, ok := PPOSequentialParametersAndNodes(model, parameters[:], nodes[:])
	if !ok { return false }
	for node in nodeList {
		for tensor in ([2]core.Tensor{node.value, node.grad}) {
			range, valid := PPOFitMemoryRangeOf(rawptr(raw_data(tensor.data)), len(tensor.data), size_of(f32))
			if !valid || PPOFitMemoryRangesOverlap(range, contextRange) { return false }
		}
	}
	return true
}

// Allocates fit scratch and shared policy-then-value Adam storage. Both models
// must be built, mutually disjoint, PPO-compatible, and have trainable parameters;
// the critic must have one output and the actor raw categorical logits. The fit
// configuration's batch size cannot exceed either model's capacity. A zero batch
// size selects the smaller model capacity, bounded by rolloutCapacity for scratch.
//
// The trainer is usable only on .None. On setup failure it is normally empty; if
// cleanup reports an error, .CleanupFailed leaves a destroying trainer holding the
// affected pointers. Retry Destroy only when failed frees retain their allocations,
// as described above. Initialization does not change model parameters or RNG.
PPOTrainingContextInit :: proc(
	trainer: ^PPOTrainingContext($policyMaxLayers, $policyMaxWidth, $policyBatchCapacity, $valueMaxLayers, $valueMaxWidth, $valueBatchCapacity),
	policy: ^Sequential(policyMaxLayers, policyMaxWidth, policyBatchCapacity),
	value: ^Sequential(valueMaxLayers, valueMaxWidth, valueBatchCapacity),
	options: PPOTrainingContextOptions,
	allocator: mem.Allocator = context.allocator,
) -> PPOTrainingContextError {
	if trainer == nil || trainer.self != nil || trainer.phase != .Empty || trainer.adam.self != nil ||
		trainer.scratch.self != nil || trainer.scratch.memory != nil || trainer.pending.blocks != ([4]rawptr{}) { return .InvalidHandle }
	if options.rolloutCapacity <= 0 || options.policySeed == 0 || !PPOConfigValid(options.objective) ||
		!PPOFitConfigValid(options.fit) || options.fit.batchSize > min(policyBatchCapacity, valueBatchCapacity) {
		return .InvalidOptions
	}
	candidate := Adam{learningRate = options.learningRate, beta1 = options.beta1, beta2 = options.beta2, epsilon = options.epsilon}
	if !AdamConfigValid(&candidate) { return .InvalidOptions }
	if policy == nil || value == nil { return .InvalidModel }
	contextRange, contextOk := PPOFitMemoryRangeOf(rawptr(trainer), 1, size_of(trainer^))
	policyRange, policyRangeOk := PPOFitMemoryRangeOf(rawptr(policy), 1, size_of(policy^))
	valueRange, valueRangeOk := PPOFitMemoryRangeOf(rawptr(value), 1, size_of(value^))
	if !contextOk || !policyRangeOk || !valueRangeOk || PPOFitMemoryRangesOverlap(contextRange, policyRange) ||
		PPOFitMemoryRangesOverlap(contextRange, valueRange) || PPOFitMemoryRangesOverlap(policyRange, valueRange) ||
		!ppoTrainingContextModelDisjoint(policy, contextRange) || !ppoTrainingContextModelDisjoint(value, contextRange) {
		return .InvalidModel
	}
	parameterScratch: [2*(policyMaxLayers+valueMaxLayers)]^core.Node
	parameters, elements, modelsOk := PPOCheckpointCombinedParameters(policy, value, parameterScratch[:])
	if !modelsOk { return .InvalidModel }
	observationWidth := policy.inputWidth
	actionCount := policy.layers[policy.layerCount-1].width
	batchSize := options.fit.batchSize
	if batchSize == 0 { batchSize = min(policyBatchCapacity, valueBatchCapacity) }
	layout, layoutOk := ppoOwnedFitStorageLayout(options.rolloutCapacity, observationWidth, actionCount, batchSize, options.fit.epochs)
	if !layoutOk { return .ScratchSetupFailed }

	trainer.self, trainer.phase = rawptr(trainer), .Initializing
	trainer.pending.allocator = allocator
	sizes := [4]int{layout.total, 0, 0, 0}
	alignments := [4]int{layout.alignment, align_of(^core.Node), align_of(f32), align_of(f32)}
	ranges: [7]PPOFitMemoryRange
	ranges[0], ranges[1], ranges[2] = contextRange, policyRange, valueRange
	for index in 0..<len(sizes) {
		if index == 1 {
			// Preserve the stricter model wiring and cross-model checks performed by
			// PPOOwnedAdamInit, after scratch setup as in the original initializer.
			policyCount, policyElements, policyOk := SequentialAdamRequirements(policy)
			valueCount, valueElements, valueOk := SequentialAdamRequirements(value)
			if !policyOk || !valueOk || policyCount > max(int)-valueCount || policyElements > max(int)-valueElements ||
				policyCount+valueCount != len(parameters) || policyElements+valueElements != elements ||
				len(parameters) > max(int)/size_of(^core.Node) || elements > max(int)/size_of(f32) ||
				!ppoTrainingContextModelDisjoint(policy, valueRange) || !ppoTrainingContextModelDisjoint(value, policyRange) {
				return ppoTrainingContextRollback(trainer, .OptimizerSetupFailed)
			}
			policyParameters: [2*policyMaxLayers]^core.Node
			valueParameters: [2*valueMaxLayers]^core.Node
			policyList, policyListOk := SequentialParameters(policy, policyParameters[:])
			valueList, valueListOk := SequentialParameters(value, valueParameters[:])
			if !policyListOk || !valueListOk || len(policyList) != policyCount || len(valueList) != valueCount {
				return ppoTrainingContextRollback(trainer, .OptimizerSetupFailed)
			}
			sizes[1], sizes[2], sizes[3] = len(parameters)*size_of(^core.Node), elements*size_of(f32), elements*size_of(f32)
		}
		failure := PPOTrainingContextError.OptimizerSetupFailed
		if index == 0 { failure = .ScratchSetupFailed }
		bytes, err := mem.alloc_bytes(sizes[index], alignments[index], allocator)
		memory := rawptr(raw_data(bytes))
		trainer.pending.blocks[index] = memory
		if memory == nil || err != nil { return ppoTrainingContextRollback(trainer, failure) }
		allocated, rangeOk := SequentialAdamRange(memory, sizes[index], 1)
		if !rangeOk || len(bytes) < sizes[index] || uintptr(memory)%uintptr(alignments[index]) != 0 {
			return ppoTrainingContextRollback(trainer, failure)
		}
		allocatedRange := PPOFitMemoryRange{allocated.address, allocated.bytes}
		for previous in ranges[:3+index] {
			if PPOFitMemoryRangesOverlap(allocatedRange, previous) { return ppoTrainingContextRollback(trainer, failure) }
		}
		if !ppoTrainingContextModelDisjoint(policy, allocatedRange) || !ppoTrainingContextModelDisjoint(value, allocatedRange) {
			return ppoTrainingContextRollback(trainer, failure)
		}
		ranges[3+index] = allocatedRange
	}

	parameterStorage := mem.slice_ptr((^^core.Node)(trainer.pending.blocks[1]), len(parameters))
	first := mem.slice_ptr((^f32)(trainer.pending.blocks[2]), elements)
	second := mem.slice_ptr((^f32)(trainer.pending.blocks[3]), elements)
	copy(parameterStorage, parameters)
	if !AdamInit(&trainer.adam.optimizer, parameterStorage, first, second, options.learningRate, options.beta1, options.beta2, options.epsilon) {
		return ppoTrainingContextRollback(trainer, .OptimizerSetupFailed)
	}
	trainer.scratch = {storage = ppoOwnedFitStorageViewAt(trainer.pending.blocks[0], layout), memory = trainer.pending.blocks[0], allocator = allocator, self = rawptr(&trainer.scratch)}
	trainer.adam.parameterStorage, trainer.adam.firstMoment, trainer.adam.secondMoment = parameterStorage, first, second
	trainer.adam.allocator, trainer.adam.self = allocator, rawptr(&trainer.adam)
	trainer.pending = {}
	trainer.policy, trainer.value = policy, value
	trainer.objective, trainer.fitConfig = options.objective, options.fit
	trainer.rolloutCapacity, trainer.observationWidth, trainer.actionCount = options.rolloutCapacity, observationWidth, actionCount
	_ = PPOTrainingStateInit(&trainer.state, options.policySeed, options.shuffleSeed)
	trainer.phase = .Ready
	return .None
}

@(private="file")
ppoTrainingContextRollback :: proc(
	trainer: ^PPOTrainingContext($pl, $pw, $pb, $vl, $vw, $vb), failure: PPOTrainingContextError,
) -> PPOTrainingContextError {
	if PPOTrainingContextDestroy(trainer) != .None { return .CleanupFailed }
	return failure
}

// Borrows the state for action sampling and rollout recording. The pointer cannot
// be used once destruction begins; do not copy the live trainer or edit counters
// and RNGs except through the documented PPO state/action APIs.
PPOTrainingContextState :: proc(trainer: ^PPOTrainingContext($pl, $pw, $pb, $vl, $vw, $vb)) -> ^PPOTrainingState {
	if trainer == nil || trainer.self != rawptr(trainer) || trainer.phase != .Ready { return nil }
	return &trainer.state
}

// Borrows the shared optimizer for compatible checkpoint/inspection APIs. Do not
// manually change its parameter or moment bindings or destroy it independently.
PPOTrainingContextOptimizer :: proc(trainer: ^PPOTrainingContext($pl, $pw, $pb, $vl, $vw, $vb)) -> ^Adam {
	if trainer == nil || trainer.self != rawptr(trainer) || trainer.phase != .Ready { return nil }
	return PPOOwnedAdamOptimizer(&trainer.adam)
}

// Returns the borrowed epoch-metric capacity. Only the prefix reported by a
// successful or partial fit is current; unused entries may contain prior results.
PPOTrainingContextEpochMetrics :: proc(trainer: ^PPOTrainingContext($pl, $pw, $pb, $vl, $vw, $vb)) -> []PPOEpochStats {
	if trainer == nil || trainer.self != rawptr(trainer) || trainer.phase != .Ready { return nil }
	storage, ok := PPOOwnedFitStorageView(&trainer.scratch)
	if !ok { return nil }
	return storage.epochMetrics
}

// Record after collecting a rollout and calculating its returns/advantages.
PPOTrainingContextRecordRollout :: proc(trainer: ^PPOTrainingContext($pl, $pw, $pb, $vl, $vw, $vb)) -> PPOTrainingContextError {
	state := PPOTrainingContextState(trainer)
	if state == nil { return .InvalidHandle }
	if !PPOTrainingStateRecordRollout(state) { return .InvalidState }
	return .None
}

// Fits already-computed returns/advantages without allocating. The rollout and
// its storage must be disjoint from the entire trainer, models and owned buffers.
// A late .FitFailed may leave successful minibatch updates, RNG advances, metrics
// and scratch changes; stats.updates and state.updateCount include committed work.
PPOTrainingContextFit :: proc(
	trainer: ^PPOTrainingContext($pl, $pw, $pb, $vl, $vw, $vb),
	buffer: ^rl.RolloutBuffer,
) -> (PPOFitStats, PPOTrainingContextError) {
	state := PPOTrainingContextState(trainer)
	optimizer := PPOTrainingContextOptimizer(trainer)
	if state == nil || optimizer == nil { return {}, .InvalidHandle }
	if !rl.RolloutBufferValid(buffer) || buffer.count <= 0 || buffer.count > trainer.rolloutCapacity ||
		buffer.observationWidth != trainer.observationWidth || buffer.actionCount != trainer.actionCount {
		return {}, .InvalidRollout
	}
	contextRange, _ := PPOFitMemoryRangeOf(rawptr(trainer), 1, size_of(trainer^))
	bufferRange, ok := PPOFitMemoryRangeOf(rawptr(buffer), 1, size_of(buffer^))
	if !ok || PPOFitMemoryRangesOverlap(contextRange, bufferRange) ||
		PPOFitBufferOverlaps(buffer, rawptr(trainer), 1, size_of(trainer^)) { return {}, .InvalidRollout }
	storage, storageOk := PPOOwnedFitStorageView(&trainer.scratch)
	if !storageOk { return {}, .InvalidHandle }
	stats, fitOk := SequentialPPOFitStateful(trainer.policy, trainer.value, buffer, state, trainer.objective, trainer.fitConfig, optimizer, storage)
	if !fitOk { return stats, .FitFailed }
	return stats, .None
}

// Frees both owners and any pending initialization blocks with their captured
// allocator. Once destruction starts all trainer borrows are invalid. On a free
// error .CleanupFailed remembers the pointer, but retry is safe only if the allocator
// left the allocation intact; otherwise use allocator-specific cleanup.
// An empty/destroyed trainer succeeds; a nil, copied, or moved trainer fails.
PPOTrainingContextDestroy :: proc(trainer: ^PPOTrainingContext($pl, $pw, $pb, $vl, $vw, $vb)) -> PPOTrainingContextError {
	if trainer == nil { return .InvalidHandle }
	if trainer.self == nil && trainer.phase == .Empty && trainer.pending.blocks == ([4]rawptr{}) { return .None }
	if trainer.self != rawptr(trainer) { return .InvalidHandle }
	trainer.phase = .Destroying
	adamOk := PPOOwnedAdamDestroy(&trainer.adam)
	scratchOk := PPOOwnedFitStorageDestroy(&trainer.scratch)
	pendingOk := ppoTrainingContextFreePending(&trainer.pending)
	if !adamOk || !scratchOk || !pendingOk { return .CleanupFailed }
	trainer^ = {}
	return .None
}
