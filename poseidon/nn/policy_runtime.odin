package nn

import "../data"
import "../rl"
import "core:mem"

PolicyRuntimeError :: enum {
	None,
	InvalidHandle,
	InvalidOptions,
	InvalidExport,
	ShapeMismatch,
	ModelSetupFailed,
	StorageSetupFailed,
	NormalizerSetupFailed,
	CleanupFailed,
	NotReady,
	InvalidObservation,
	InvalidActionMask,
	ActionSelectionFailed,
}

@(private)
PolicyRuntimePhase :: enum { Empty, Initializing, Ready, Destroying }

// Inference-only controller runtime. It owns one heap-allocated policy, optional
// observation moments, optional fixed-window history, and two reusable
// observation scratch buffers. It contains no critic, optimizer, rollout, learner
// state, or training entry point.
//
// The export does not record sensor width or history depth, so options supply
// them. The resulting policy input width is sensorWidth * max(1, historyDepth).
// An observation normalizer, when present, applies to the flattened window.
// One runtime is single-controller: model inference mutates inline scratch, so do
// not share a runtime or its policy across threads. Create one runtime per
// controller/player. Export bytes may be shared read-only; each runtime loads its
// own copy. No internal synchronization is provided.
PolicyRuntimeOptions :: struct {
	sensorWidth, historyDepth: int,
	randomSeed: u64,
}

PolicyRuntimeOptionsDefault :: proc(sensorWidth: int) -> PolicyRuntimeOptions {
	return {sensorWidth = sensorWidth, historyDepth = 1, randomSeed = 1}
}

PolicyRuntime :: struct($ml, $mw, $mb: int) {
	policy:  OwnedSequential(ml, mw, mb),
	observation: data.RunningStandardizer,
	history: rl.ObservationHistory,
	memory: rawptr,
	allocator: mem.Allocator,
	observationMean, observationM2: []f64,
	historyStorage: []f32,
	rawObservation, policyInput: []f32,
	sensorWidth, historyDepth, policyInputWidth, actionCount: int,
	hasObservationNormalizer: bool,
	randomState: u64,
	self: rawptr,
	phase: PolicyRuntimePhase,
}

@(private="file")
policyRuntimeLayout :: proc(hasNormalizer: bool, sensorWidth, historyDepth: int) -> (counts, offsets: [5]int, total, alignment: int, ok: bool) {
	if sensorWidth <= 0 || historyDepth <= 0 || sensorWidth > max(int)/historyDepth { return {}, {}, 0, 0, false }
	width := sensorWidth*historyDepth
	if hasNormalizer { counts[0], counts[1] = width, width }
	if historyDepth > 1 {
		if historyDepth > max(int)/sensorWidth { return {}, {}, 0, 0, false }
		counts[2] = historyDepth*sensorWidth
	}
	counts[3], counts[4] = width, width
	sizes := [5]int{size_of(f64), size_of(f64), size_of(f32), size_of(f32), size_of(f32)}
	alignments := [5]int{align_of(f64), align_of(f64), align_of(f32), align_of(f32), align_of(f32)}
	alignment = 1
	for count, index in counts {
		if count == 0 { continue }
		itemAlignment := alignments[index]
		alignment = max(alignment, itemAlignment)
		padding := (itemAlignment-total%itemAlignment)%itemAlignment
		if total > max(int)-padding { return {}, {}, 0, 0, false }
		total += padding
		offsets[index] = total
		if count > (max(int)-total)/sizes[index] { return {}, {}, 0, 0, false }
		total += count*sizes[index]
	}
	return counts, offsets, total, alignment, true
}

@(private="file")
policyRuntimePointers :: proc(runtime: ^PolicyRuntime($ml, $mw, $mb), hasNormalizer: bool, sensorWidth, historyDepth: int) -> bool {
	counts, offsets, total, alignment, layoutOk := policyRuntimeLayout(hasNormalizer, sensorWidth, historyDepth)
	if !layoutOk || runtime.allocator.procedure == nil { return false }
	bytes, err := mem.alloc_bytes(total, alignment, runtime.allocator)
	memory := rawptr(raw_data(bytes))
	if memory == nil || err != nil || len(bytes) < total || uintptr(memory)%uintptr(alignment) != 0 ||
		uintptr(memory) > max(uintptr)-uintptr(total) { if memory != nil { _ = mem.free(memory, runtime.allocator) }; return false }
	objectRange, objectOk := SequentialAdamRange(rawptr(runtime), 1, size_of(runtime^))
	memoryRange := SequentialAdamMemoryRange{uintptr(memory), uintptr(total)}
	if !objectOk || SequentialAdamRangesOverlap(objectRange, memoryRange) {
		_ = mem.free(memory, runtime.allocator)
		return false
	}
	runtime.memory = memory
	address := uintptr(memory)
	if counts[0] > 0 {
		runtime.observationMean = mem.slice_ptr((^f64)(rawptr(address+uintptr(offsets[0]))), counts[0])
		runtime.observationM2 = mem.slice_ptr((^f64)(rawptr(address+uintptr(offsets[1]))), counts[1])
	}
	if counts[2] > 0 { runtime.historyStorage = mem.slice_ptr((^f32)(rawptr(address+uintptr(offsets[2]))), counts[2]) }
	runtime.rawObservation = mem.slice_ptr((^f32)(rawptr(address+uintptr(offsets[3]))), counts[3])
	runtime.policyInput = mem.slice_ptr((^f32)(rawptr(address+uintptr(offsets[4]))), counts[4])
	return true
}

@(private="file")
policyRuntimeSeed :: proc(seed: u64) -> u64 {
	return seed == 0 ? 0x9e3779b97f4a7c15 : seed
}

// Allocates all runtime state and loads an inference policy export. Model
// capacities must exactly match the export. Any encoded observation normalizer
// must have width equal to the flattened policy input width. Failure normally
// clears the runtime; if cleanup itself fails it remains destroying and Destroy
// must be retried.
PolicyRuntimeInit :: proc(
	runtime: ^PolicyRuntime($ml, $mw, $mb),
	export: []u8,
	options: PolicyRuntimeOptions,
	allocator: mem.Allocator = context.allocator,
) -> PolicyRuntimeError {
	if runtime == nil || runtime.self != nil || runtime.phase != .Empty { return .InvalidHandle }
	if options.sensorWidth <= 0 || options.historyDepth <= 0 || options.sensorWidth > max(int)/options.historyDepth {
		return .InvalidOptions
	}
	info, err := PPOPolicyExportInspect(export, PPOPolicyExportInspectLimits{
		model = {maxLayers = ml, maxWidth = mw, maxBatchCapacity = mb},
	})
	if err.code == .LimitExceeded { return .ShapeMismatch }
	if err.code != .None { return .InvalidExport }
	width := options.sensorWidth*options.historyDepth
	if info.model.maxLayers != ml || info.model.maxWidth != mw || info.model.batchCapacity != mb ||
		info.model.inputWidth != width || info.model.outputWidth <= 0 ||
		info.hasObservationNormalizer && info.observation.width != width {
		return .ShapeMismatch
	}

	runtime.allocator = allocator
	runtime.sensorWidth, runtime.historyDepth = options.sensorWidth, options.historyDepth
	runtime.policyInputWidth, runtime.actionCount = width, info.model.outputWidth
	runtime.hasObservationNormalizer = info.hasObservationNormalizer
	runtime.randomState = policyRuntimeSeed(options.randomSeed)
	runtime.self, runtime.phase = rawptr(runtime), .Initializing
	if !policyRuntimePointers(runtime, info.hasObservationNormalizer, options.sensorWidth, options.historyDepth) {
		return policyRuntimeRollback(runtime, .StorageSetupFailed)
	}
	if info.hasObservationNormalizer &&
		!data.RunningStandardizerInit(&runtime.observation, runtime.observationMean, runtime.observationM2) {
		return policyRuntimeRollback(runtime, .NormalizerSetupFailed)
	}
	if options.historyDepth > 1 &&
		!rl.ObservationHistoryInit(&runtime.history, runtime.historyStorage, options.historyDepth, options.sensorWidth) {
		return policyRuntimeRollback(runtime, .StorageSetupFailed)
	}
	if !OwnedSequentialInit(&runtime.policy, width, 1, allocator) {
		return policyRuntimeRollback(runtime, .ModelSetupFailed)
	}
	policy := OwnedSequentialModel(&runtime.policy)
	normalizer: ^data.RunningStandardizer
	if info.hasObservationNormalizer { normalizer = &runtime.observation }
	if policy == nil || !PPOPolicyExportRead(policy, export, normalizer) ||
		policy.inputWidth != width || policy.layers[policy.layerCount-1].width != runtime.actionCount {
		return policyRuntimeRollback(runtime, .InvalidExport)
	}
	runtime.phase = .Ready
	return .None
}

@(private="file")
policyRuntimeRollback :: proc(runtime: ^PolicyRuntime($ml, $mw, $mb), failure: PolicyRuntimeError) -> PolicyRuntimeError {
	runtime.phase = .Destroying
	ok := true
	if !OwnedSequentialDestroy(&runtime.policy) { ok = false }
	if runtime.memory != nil {
		if mem.free(runtime.memory, runtime.allocator) == nil { runtime.memory = nil } else { ok = false }
	}
	if !ok { return .CleanupFailed }
	runtime^ = {}
	return failure
}

PolicyRuntimePolicy :: proc(runtime: ^PolicyRuntime($ml, $mw, $mb)) -> ^Sequential(ml, mw, mb) {
	if runtime == nil || runtime.self != rawptr(runtime) || runtime.phase != .Ready { return nil }
	return OwnedSequentialModel(&runtime.policy)
}

PolicyRuntimeActionCount :: proc(runtime: ^PolicyRuntime($ml, $mw, $mb)) -> int {
	if runtime == nil || runtime.self != rawptr(runtime) || runtime.phase != .Ready { return 0 }
	return runtime.actionCount
}

PolicyRuntimeRandomState :: proc(runtime: ^PolicyRuntime($ml, $mw, $mb)) -> ^u64 {
	if runtime == nil || runtime.self != rawptr(runtime) || runtime.phase != .Ready { return nil }
	return &runtime.randomState
}

PolicyRuntimeSetRandom :: proc(runtime: ^PolicyRuntime($ml, $mw, $mb), seed: u64) -> bool {
	if runtime == nil || runtime.self != rawptr(runtime) || runtime.phase != .Ready { return false }
	runtime.randomState = policyRuntimeSeed(seed)
	return true
}

PolicyRuntimeResetEpisode :: proc(runtime: ^PolicyRuntime($ml, $mw, $mb)) -> bool {
	if runtime == nil || runtime.self != rawptr(runtime) || runtime.phase != .Ready { return false }
	return runtime.historyDepth <= 1 || rl.ObservationHistoryReset(&runtime.history)
}

// Selects an action for one raw sensor observation. History is pushed exactly once;
// normalization uses frozen/current statistics without updating them. No allocation
// occurs. On failure history cursors are restored, though its stored bytes and model
// activation scratch may have changed.
PolicyRuntimeAction :: proc(
	runtime: ^PolicyRuntime($ml, $mw, $mb),
	observation: []f32,
	legal: []bool,
	mode: PolicyEvaluationMode = .Stochastic,
	randomState: ^u64 = nil,
) -> (action: int, logProbability: f64, error: PolicyRuntimeError) {
	if runtime == nil || runtime.self != rawptr(runtime) || runtime.phase != .Ready { return 0, 0, .InvalidHandle }
	if len(observation) != runtime.sensorWidth { return 0, 0, .InvalidObservation }
	if len(legal) != runtime.actionCount { return 0, 0, .InvalidActionMask }
	for value in observation { if !rolloutFiniteF32(value) { return 0, 0, .InvalidObservation } }
	legalCount := 0
	for allowed in legal { if allowed { legalCount += 1 } }
	if legalCount == 0 { return 0, 0, .InvalidActionMask }
	policy := OwnedSequentialModel(&runtime.policy)
	if policy == nil { return 0, 0, .NotReady }

	oldCount, oldNext := runtime.history.count, runtime.history.nextIndex
	if runtime.historyDepth > 1 {
		if !rl.ObservationHistoryPush(&runtime.history, observation) { return 0, 0, .InvalidObservation }
		if !rl.ObservationHistoryFlatten(&runtime.history, runtime.rawObservation) {
			runtime.history.count, runtime.history.nextIndex = oldCount, oldNext
			return 0, 0, .InvalidObservation
		}
	} else {
		copy(runtime.rawObservation, observation)
	}
	if runtime.hasObservationNormalizer && runtime.observation.count > 0 {
		if !data.RunningStandardizerTransform(&runtime.observation, runtime.rawObservation, runtime.policyInput) {
			runtime.history.count, runtime.history.nextIndex = oldCount, oldNext
			return 0, 0, .InvalidObservation
		}
	} else {
		copy(runtime.policyInput, runtime.rawObservation)
	}
	state := randomState
	if state == nil { state = &runtime.randomState }
	ok: bool
	action, logProbability, ok = SequentialPolicyAction(policy, runtime.policyInput, legal, mode, state)
	if !ok {
		runtime.history.count, runtime.history.nextIndex = oldCount, oldNext
		return 0, 0, .ActionSelectionFailed
	}
	return action, logProbability, .None
}

PolicyRuntimeDestroy :: proc(runtime: ^PolicyRuntime($ml, $mw, $mb)) -> PolicyRuntimeError {
	if runtime == nil { return .InvalidHandle }
	if runtime.self == nil && runtime.phase == .Empty { return .None }
	if runtime.self != rawptr(runtime) { return .InvalidHandle }
	runtime.phase = .Destroying
	ok := true
	if !OwnedSequentialDestroy(&runtime.policy) { ok = false }
	if runtime.memory != nil {
		if mem.free(runtime.memory, runtime.allocator) == nil { runtime.memory = nil } else { ok = false }
	}
	if !ok { return .CleanupFailed }
	runtime^ = {}
	return .None
}
