package nn

import "../data"
import "../rl"
import "core:mem"
import "core:testing"

PPOContextNormalizedTestNoAlloc :: struct { calls: int }

ppoContextNormalizedTestNoAllocProc :: proc(
	data: rawptr, mode: mem.Allocator_Mode, size, alignment: int,
	oldMemory: rawptr, oldSize: int, loc := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	state := (^PPOContextNormalizedTestNoAlloc)(data)
	state.calls += 1
	return nil, .Out_Of_Memory
}

// Keep normalizer objects and their backing arrays in the atomicity snapshot as
// well as the trainer, models, and all four owned allocations.
PPOContextNormalizedTestSnapshot :: struct($pl, $pw, $pb, $vl, $vw, $vb: int) {
	trainerSnapshot: PPOContextCheckpointSnapshot(pl, pw, pb, vl, vw, vb),
	addresses: [2][3]rawptr,
	lengths: [2][3]int,
	bytes: [2][3][64]u8,
}

ppoContextNormalizedTestSnapshotTake :: proc(
	trainer: ^PPOTrainingContext($pl, $pw, $pb, $vl, $vw, $vb),
	allocator: ^PPOContextTestAllocator, normalizers: PPOTrainingNormalizers,
	snapshot: ^PPOContextNormalizedTestSnapshot(pl, pw, pb, vl, vw, vb),
) -> bool {
	if !PPOContextCheckpointSnapshotTake(trainer, allocator.allocated[:4], allocator.sizes[:4], &snapshot.trainerSnapshot) { return false }
	for normalizer, i in ([2]^data.RunningStandardizer{normalizers.observation, normalizers.reward}) {
		if normalizer == nil { continue }
		snapshot.addresses[i] = {rawptr(normalizer), rawptr(raw_data(normalizer.mean)), rawptr(raw_data(normalizer.m2))}
		snapshot.lengths[i] = {size_of(normalizer^), len(normalizer.mean)*size_of(f64), len(normalizer.m2)*size_of(f64)}
		for address, j in snapshot.addresses[i] {
			length := snapshot.lengths[i][j]
			if length > len(snapshot.bytes[i][j]) || length > 0 && address == nil { return false }
			copy(snapshot.bytes[i][j][:length], mem.slice_ptr((^u8)(address), length))
		}
	}
	return true
}

ppoContextNormalizedTestSnapshotEqual :: proc(
	trainer: ^PPOTrainingContext($pl, $pw, $pb, $vl, $vw, $vb),
	allocator: ^PPOContextTestAllocator, snapshot: ^PPOContextNormalizedTestSnapshot(pl, pw, pb, vl, vw, vb),
) -> bool {
	if !PPOContextCheckpointSnapshotEqual(trainer, allocator.allocated[:4], &snapshot.trainerSnapshot) { return false }
	for addresses, i in snapshot.addresses {
		for address, j in addresses {
			if !PPOContextTestBytesEqual(address, snapshot.bytes[i][j][:snapshot.lengths[i][j]]) { return false }
		}
	}
	return true
}

ppoContextNormalizedTestStart :: proc(
	target: ^PPOCheckpointInitTestTarget, allocator: ^PPOContextTestAllocator,
	options: PPOTrainingContextOptions, inputWidth: int = 2, actionWidth: int = 2, hiddenWidth: int = 0,
) -> bool {
	if !ppoCheckpointInitTestTargetInit(target) ||
		!PPOContextCheckpointBuildModels(&target.dest.policy, &target.dest.value, inputWidth, actionWidth, hiddenWidth) { return false }
	allocator^ = {backing = context.allocator}
	return PPOTrainingContextInit(&target.trainer, &target.dest.policy, &target.dest.value, options,
		mem.Allocator{procedure = PPOContextTestAllocatorProc, data = allocator}) == .None
}

ppoContextNormalizedTestMake :: proc(
	policy: ^Sequential($pl, $pw, $pb), value: ^Sequential($vl, $vw, $vb),
	options: PPOTrainingContextOptions, normalizers: PPOTrainingNormalizers, output: []u8,
) -> (int, PPOTrainingContextError) {
	trainer: PPOTrainingContext(pl, pw, pb, vl, vw, vb)
	err := PPOTrainingContextInit(&trainer, policy, value, options)
	if err != .None { return 0, err }
	defer PPOTrainingContextDestroy(&trainer)
	baseScratch, policyScratch, valueScratch: [4096]u8
	return PPOTrainingContextCheckpointWriteNormalized(&trainer, normalizers, output, baseScratch[:], policyScratch[:], valueScratch[:])
}

ppoContextNormalizedTestRejectRead :: proc(
	t: ^testing.T, label: string, trainer: ^PPOTrainingContext($pl, $pw, $pb, $vl, $vw, $vb),
	allocator: ^PPOContextTestAllocator, input: []u8, normalizers: PPOTrainingNormalizers, expected: PPOTrainingContextError,
) -> bool {
	snapshot: PPOContextNormalizedTestSnapshot(pl, pw, pb, vl, vw, vb)
	inputBefore: [4096]u8
	captured := len(input) <= len(inputBefore) && ppoContextNormalizedTestSnapshotTake(trainer, allocator, normalizers, &snapshot)
	testing.expectf(t, captured, "%s: snapshot", label)
	if !captured { return false }
	copy(inputBefore[:], input)
	result := PPOTrainingContextCheckpointReadNormalized(trainer, input, normalizers)
	unchanged := ppoContextNormalizedTestSnapshotEqual(trainer, allocator, &snapshot) &&
		PPOContextTestBytesEqual(rawptr(raw_data(input)), inputBefore[:len(input)])
	testing.expectf(t, result == expected && unchanged, "%s: got %v, expected %v, unchanged=%v", label, result, expected, unchanged)
	return result == expected && unchanged
}

ppoContextNormalizedTestRejectWrite :: proc(
	t: ^testing.T, label: string, trainer: ^PPOTrainingContext($pl, $pw, $pb, $vl, $vw, $vb),
	allocator: ^PPOContextTestAllocator, normalizers: PPOTrainingNormalizers,
	output, baseScratch, policyScratch, valueScratch: []u8,
) -> bool {
	snapshot: PPOContextNormalizedTestSnapshot(pl, pw, pb, vl, vw, vb)
	outputBefore: [4096]u8
	captured := len(output) <= len(outputBefore) && ppoContextNormalizedTestSnapshotTake(trainer, allocator, normalizers, &snapshot)
	testing.expectf(t, captured, "%s: snapshot", label)
	if !captured { return false }
	copy(outputBefore[:], output)
	size, result := PPOTrainingContextCheckpointWriteNormalized(trainer, normalizers, output, baseScratch, policyScratch, valueScratch)
	unchanged := ppoContextNormalizedTestSnapshotEqual(trainer, allocator, &snapshot) &&
		PPOContextTestBytesEqual(rawptr(raw_data(output)), outputBefore[:len(output)])
	testing.expectf(t, size == 0 && result == .CheckpointWriteFailed && unchanged,
		"%s: size=%d result=%v unchanged=%v", label, size, result, unchanged)
	return size == 0 && result == .CheckpointWriteFailed && unchanged
}

ppoContextNormalizedTestCollect :: proc(
	policy: ^Sequential($pl, $pw, $pb), value: ^Sequential($vl, $vw, $vb), state: ^PPOTrainingState,
	buffer: ^rl.RolloutBuffer, normalizers: PPOTrainingNormalizers, count: int,
) -> bool {
	if !rl.RolloutBufferReset(buffer) { return false }
	for index in 0..<count {
		raw := [2]f32{f32(index)/4, 1}
		rawNext := [2]f32{f32(index+1)/4, 1}
		observation, nextObservation: [2]f32
		if !data.RunningStandardizerTransform(normalizers.observation, raw[:], observation[:]) ||
			!data.RunningStandardizerTransform(normalizers.observation, rawNext[:], nextObservation[:]) { return false }
		legal := [2]bool{true, index%3 != 1}
		action, logProbability, actionOk := SequentialPolicyAction(policy, observation[:], legal[:], .Stochastic, &state.policyRandomState)
		currentValue, valueOk := SequentialPredictScalar(value, observation[:])
		nextValue, nextOk := SequentialPredictScalar(value, nextObservation[:])
		rawReward := [1]f32{f32(index%2)+f32(action)/4}
		reward: [1]f32
		if !actionOk || !valueOk || !nextOk || !data.RunningStandardizerTransform(normalizers.reward, rawReward[:], reward[:]) ||
			!rl.RolloutBufferAppend(buffer, {observation = observation[:], action = action, reward = reward[0],
				value = currentValue, nextValue = nextValue, oldLogProbability = logProbability,
				legalActions = legal[:], terminated = index == count-1}) { return false }
	}
	return rl.RolloutComputeGAE(buffer, 0.9, 0.95) && rl.RolloutNormalizeAdvantages(buffer)
}

@(test)
PPOContextNormalizedCheckpointLiveRoundTripAndFit :: proc(t: ^testing.T) {
	source, restored: PPOCheckpointInitTestTarget
	allocator, restoredAllocator: PPOContextTestAllocator
	options := PPOTrainingContextOptionsDefault(5)
	options.objective = {0.15, 0.02, 0.6, 0.75}
	options.fit = {epochs = 2, batchSize = 2, maxGradientNorm = 0.01, finalLearningRate = 0.002}
	options.policySeed, options.shuffleSeed = 12345, 77
	options.learningRate, options.beta1, options.beta2, options.epsilon = 0.01, 0.8, 0.95, 1e-6
	setup := ppoContextNormalizedTestStart(&source, &allocator, options)
	testing.expect(t, setup)
	if !setup { return }
	defer PPOTrainingContextDestroy(&source.trainer)
	destOptions := options
	destOptions.rolloutCapacity, destOptions.fit.epochs = 7, 3
	destOptions.policySeed, destOptions.shuffleSeed = 999, 888
	setup = ppoContextNormalizedTestStart(&restored, &restoredAllocator, destOptions)
	testing.expect(t, setup)
	if !setup { return }
	defer PPOTrainingContextDestroy(&restored.trainer)
	observations, rewards := [4]f32{1, 10, 3, 14}, [3]f32{-2, 0, 2}
	setup = data.RunningStandardizerUpdate(&source.dest.observation, observations[:]) &&
		data.RunningStandardizerFreeze(&source.dest.observation) && data.RunningStandardizerUpdate(&source.dest.reward, rewards[:])
	backing, restoredBacking: PPOContextTestRolloutBacking
	buffer, restoredBuffer: rl.RolloutBuffer
	setup = setup && PPOContextTestRolloutInit(&buffer, &backing) && PPOContextTestRolloutInit(&restoredBuffer, &restoredBacking)
	testing.expect(t, setup)
	if !setup { return }
	for _ in 0..<2 {
		setup = ppoContextNormalizedTestCollect(&source.dest.policy, &source.dest.value, PPOTrainingContextState(&source.trainer), &buffer,
			ppoCheckpointInitTestNormalizers(&source), 5) && PPOTrainingContextRecordRollout(&source.trainer) == .None
		testing.expect(t, setup)
		if !setup { return }
		stats, err := PPOTrainingContextFit(&source.trainer, &buffer)
		testing.expect(t, err == .None && stats.updates == 6)
		if err != .None { return }
	}
	setup = ppoContextNormalizedTestCollect(&restored.dest.policy, &restored.dest.value, PPOTrainingContextState(&restored.trainer), &restoredBuffer,
		ppoCheckpointInitTestNormalizers(&restored), 5) && PPOTrainingContextRecordRollout(&restored.trainer) == .None
	testing.expect(t, setup)
	if !setup { return }
	_, fitError := PPOTrainingContextFit(&restored.trainer, &restoredBuffer)
	testing.expect(t, fitError == .None)
	if fitError != .None { return }
	state, adam := PPOTrainingContextState(&source.trainer), PPOTrainingContextOptimizer(&source.trainer)
	testing.expect(t, state.updateCount == 12 && state.rolloutCount == 2 && adam.step == 12 &&
		state.policyRandomState != options.policySeed && state.shuffleRandomState != options.shuffleSeed)

	checkpoint, roundTrip, baseScratch, policyScratch, valueScratch: [4096]u8
	// Catch even unsuccessful attempts to use either implicit allocator.
	forbidden: PPOContextNormalizedTestNoAlloc
	noAlloc := mem.Allocator{procedure = ppoContextNormalizedTestNoAllocProc, data = &forbidden}
	size: int
	writeError: PPOTrainingContextError
	{
		context.allocator = noAlloc
		context.temp_allocator = noAlloc
		size, writeError = PPOTrainingContextCheckpointWriteNormalized(&source.trainer, ppoCheckpointInitTestNormalizers(&source),
			checkpoint[:], baseScratch[:], policyScratch[:], valueScratch[:])
	}
	testing.expect(t, writeError == .None && size > 0 && forbidden.calls == 0)
	if writeError != .None || size <= 0 { return }
	inputBefore := checkpoint
	result, rejectedRead, rejectedWrite: PPOTrainingContextError
	failedSize: int
	{
		context.allocator = noAlloc
		context.temp_allocator = noAlloc
		result = PPOTrainingContextCheckpointReadNormalized(&restored.trainer, checkpoint[:size], ppoCheckpointInitTestNormalizers(&restored))
		rejectedRead = PPOTrainingContextCheckpointReadNormalized(&restored.trainer, checkpoint[:size-1], ppoCheckpointInitTestNormalizers(&restored))
		failedSize, rejectedWrite = PPOTrainingContextCheckpointWriteNormalized(&source.trainer, ppoCheckpointInitTestNormalizers(&source),
			roundTrip[:1], baseScratch[:], policyScratch[:], valueScratch[:])
	}
	testing.expect(t, result == .None && rejectedRead == .InvalidCheckpoint && failedSize == 0 && rejectedWrite == .CheckpointWriteFailed &&
		checkpoint == inputBefore && forbidden.calls == 0 &&
		allocator.attempts == 4 && restoredAllocator.attempts == 4 && allocator.freeCalls == 0 && restoredAllocator.freeCalls == 0)
	if result != .None { return }
	restoredState, restoredAdam := PPOTrainingContextState(&restored.trainer), PPOTrainingContextOptimizer(&restored.trainer)
	testing.expect(t, restored.trainer.rolloutCapacity == 7 && restored.trainer.objective == options.objective && restored.trainer.fitConfig == options.fit &&
		state^ == restoredState^ && PPOContextCheckpointOptimizersEqual(adam, restoredAdam) &&
		PPOContextTestModelsEqual(&source.dest.policy, &restored.dest.policy) && PPOContextTestModelsEqual(&source.dest.value, &restored.dest.value) &&
		ppoCheckpointInitTestNormalizersEqual(&source.dest.observation, &restored.dest.observation) &&
		ppoCheckpointInitTestNormalizersEqual(&source.dest.reward, &restored.dest.reward))
	restoredPolicyDense := &restored.dest.policy.layers[0].storage.(DenseStorage(3))
	restoredValueDense := &restored.dest.value.layers[0].storage.(DenseStorage(3))
	testing.expect(t, len(restoredAdam.parameters) == 4 && restoredAdam.parameters[0] == &restoredPolicyDense.weights &&
		restoredAdam.parameters[2] == &restoredValueDense.weights && restoredAdam.parameters[0] != adam.parameters[0])
	roundSize, roundError := PPOTrainingContextCheckpointWriteNormalized(&restored.trainer, ppoCheckpointInitTestNormalizers(&restored),
		roundTrip[:], baseScratch[:], policyScratch[:], valueScratch[:])
	testing.expect(t, roundError == .None && roundSize == size && PPOContextTestBytesEqual(rawptr(raw_data(roundTrip[:size])), checkpoint[:size]))
	for iteration in 0..<3 {
		setup = ppoContextNormalizedTestCollect(&source.dest.policy, &source.dest.value, state, &buffer, ppoCheckpointInitTestNormalizers(&source), 5) &&
			ppoContextNormalizedTestCollect(&restored.dest.policy, &restored.dest.value, restoredState, &restoredBuffer, ppoCheckpointInitTestNormalizers(&restored), 5)
		testing.expect(t, setup && backing == restoredBacking && state^ == restoredState^)
		if !setup { return }
		testing.expect(t, PPOTrainingContextRecordRollout(&source.trainer) == .None && PPOTrainingContextRecordRollout(&restored.trainer) == .None)
		stats, err := PPOTrainingContextFit(&source.trainer, &buffer)
		other, otherErr := PPOTrainingContextFit(&restored.trainer, &restoredBuffer)
		metrics, otherMetrics := PPOTrainingContextEpochMetrics(&source.trainer), PPOTrainingContextEpochMetrics(&restored.trainer)
		testing.expect(t, err == .None && otherErr == .None && stats == other && stats.updates == 6 &&
			state^ == restoredState^ && state.updateCount == u64(18+6*iteration) &&
			PPOContextCheckpointOptimizersEqual(adam, restoredAdam) &&
			PPOContextTestModelsEqual(&source.dest.policy, &restored.dest.policy) && PPOContextTestModelsEqual(&source.dest.value, &restored.dest.value) &&
			len(metrics) >= 2 && len(otherMetrics) >= 2 && metrics[0] == otherMetrics[0] && metrics[1] == otherMetrics[1])
		sample := [1]f32{f32(iteration)+0.25}
		testing.expect(t, data.RunningStandardizerUpdate(&source.dest.reward, sample[:]) &&
			data.RunningStandardizerUpdate(&restored.dest.reward, sample[:]) &&
			ppoCheckpointInitTestNormalizersEqual(&source.dest.reward, &restored.dest.reward) &&
			ppoCheckpointInitTestNormalizersEqual(&source.dest.observation, &restored.dest.observation))
		if err != .None || otherErr != .None { return }
	}
}

@(test)
PPOContextNormalizedCheckpointPresenceWidthsAndHandles :: proc(t: ^testing.T) {
	options := PPOTrainingContextOptionsDefault(5)
	options.fit = {epochs = 3, batchSize = 2}
	source, target: PPOCheckpointInitTestTarget
	allocator, targetAllocator: PPOContextTestAllocator
	setup := ppoContextNormalizedTestStart(&source, &allocator, options)
	testing.expect(t, setup)
	if !setup { return }
	defer PPOTrainingContextDestroy(&source.trainer)
	setup = ppoContextNormalizedTestStart(&target, &targetAllocator, options)
	testing.expect(t, setup)
	if !setup { return }
	defer PPOTrainingContextDestroy(&target.trainer)
	checkpoint, baseScratch, policyScratch, valueScratch: [4096]u8
	for mask in 0..<4 {
		sourceNormalizers: PPOTrainingNormalizers
		if mask & 1 != 0 { sourceNormalizers.observation = &source.dest.observation }
		if mask & 2 != 0 { sourceNormalizers.reward = &source.dest.reward }
		size, err := PPOTrainingContextCheckpointWriteNormalized(&source.trainer, sourceNormalizers, checkpoint[:], baseScratch[:], policyScratch[:], valueScratch[:])
		testing.expectf(t, err == .None && size > 0, "writer presence mask=%d: %v", mask, err)
		if err != .None || size <= 0 { return }
		for targetMask in 0..<4 {
			normalizers: PPOTrainingNormalizers
			if targetMask & 1 != 0 { normalizers.observation = &target.dest.observation }
			if targetMask & 2 != 0 { normalizers.reward = &target.dest.reward }
			if mask != targetMask {
				_ = ppoContextNormalizedTestRejectRead(t, "normalizer presence", &target.trainer, &targetAllocator, checkpoint[:size], normalizers, .InvalidCheckpoint)
				continue
			}
			before := checkpoint
			result := PPOTrainingContextCheckpointReadNormalized(&target.trainer, checkpoint[:size], normalizers)
			testing.expectf(t, result == .None && checkpoint == before, "presence mask=%d: %v", mask, result)
			if result != .None { continue }
			if mask & 1 != 0 { testing.expect(t, ppoCheckpointInitTestNormalizersEqual(&source.dest.observation, &target.dest.observation)) }
			if mask & 2 != 0 { testing.expect(t, ppoCheckpointInitTestNormalizersEqual(&source.dest.reward, &target.dest.reward)) }
		}
	}
	size, err := PPOTrainingContextCheckpointWriteNormalized(&source.trainer, ppoCheckpointInitTestNormalizers(&source), checkpoint[:], baseScratch[:], policyScratch[:], valueScratch[:])
	testing.expect(t, err == .None && size > 0)
	if err != .None || size <= 0 { return }
	for mode in 0..<4 {
		normalizers := ppoCheckpointInitTestNormalizers(&target)
		wrongMean, wrongM2: [2]f64
		wrong: data.RunningStandardizer
		width := 1
		if mode == 1 { width = 2 }
		testing.expect(t, data.RunningStandardizerInit(&wrong, wrongMean[:width], wrongM2[:width]))
		switch mode {
		case 0: normalizers.observation = &wrong
		case 1: normalizers.reward = &wrong
		case 2: wrong.epsilon = 0; normalizers.reward = &wrong
		case 3: wrong.m2 = wrong.mean; normalizers.observation = &wrong
		}
		_ = ppoContextNormalizedTestRejectRead(t, "normalizer width or validity", &target.trainer, &targetAllocator, checkpoint[:size], normalizers, .InvalidCheckpoint)
		_ = ppoContextNormalizedTestRejectWrite(t, "normalizer width or validity", &target.trainer, &targetAllocator, normalizers,
			checkpoint[size:], baseScratch[:], policyScratch[:], valueScratch[:])
	}
	nilTrainer := (^PPOTrainingContext(2, 3, 2, 2, 3, 2))(nil)
	written, invalid := PPOTrainingContextCheckpointWriteNormalized(nilTrainer, {}, checkpoint[:], baseScratch[:], policyScratch[:], valueScratch[:])
	testing.expect(t, written == 0 && invalid == .InvalidHandle && PPOTrainingContextCheckpointReadNormalized(nilTrainer, checkpoint[:size], {}) == .InvalidHandle)
	copied := target.trainer
	written, invalid = PPOTrainingContextCheckpointWriteNormalized(&copied, {}, checkpoint[:], baseScratch[:], policyScratch[:], valueScratch[:])
	testing.expect(t, written == 0 && invalid == .InvalidHandle && PPOTrainingContextCheckpointReadNormalized(&copied, checkpoint[:size], {}) == .InvalidHandle)
}

@(test)
PPOContextNormalizedCheckpointIncompatibleStorageAndDimensions :: proc(t: ^testing.T) {
	options := PPOTrainingContextOptionsDefault(5)
	options.fit = {epochs = 2, batchSize = 2}
	source, big: PPOCheckpointInitTestTarget
	setup := ppoCheckpointInitTestTargetInit(&source) && ppoCheckpointInitTestTargetInit(&big) &&
		PPOContextCheckpointBuildModels(&source.dest.policy, &source.dest.value, 2, 2, 0) &&
		PPOContextCheckpointBuildModels(&big.dest.policy, &big.dest.value, 2, 2, 3)
	testing.expect(t, setup)
	if !setup { return }
	smallData, bigData, epochData, defaultData: [4096]u8
	smallSize, smallErr := ppoContextNormalizedTestMake(&source.dest.policy, &source.dest.value, options, ppoCheckpointInitTestNormalizers(&source), smallData[:])
	bigSize, bigErr := ppoContextNormalizedTestMake(&big.dest.policy, &big.dest.value, options, ppoCheckpointInitTestNormalizers(&big), bigData[:])
	epochOptions := options
	epochOptions.fit.epochs = 3
	epochSize, epochErr := ppoContextNormalizedTestMake(&source.dest.policy, &source.dest.value, epochOptions, ppoCheckpointInitTestNormalizers(&source), epochData[:])
	defaultOptions := options
	defaultOptions.fit.batchSize = 0
	defaultSize, defaultErr := ppoContextNormalizedTestMake(&source.dest.policy, &source.dest.value, defaultOptions, ppoCheckpointInitTestNormalizers(&source), defaultData[:])
	testing.expect(t, smallErr == .None && bigErr == .None && epochErr == .None && defaultErr == .None)
	if smallErr != .None || bigErr != .None || epochErr != .None || defaultErr != .None { return }
	for mode in 0..<7 {
		target: PPOCheckpointInitTestTarget
		allocator: PPOContextTestAllocator
		destOptions := options
		inputWidth, actionWidth, hidden := 2, 2, 0
		if mode == 1 { hidden = 1 } // Same pointer count, fewer moment elements.
		if mode == 2 || mode == 4 { destOptions.fit.batchSize = 1 }
		if mode == 5 { inputWidth = 1 }
		if mode == 6 { actionWidth = 1 }
		setup = ppoContextNormalizedTestStart(&target, &allocator, destOptions, inputWidth, actionWidth, hidden)
		testing.expectf(t, setup, "incompatible fixture %d", mode)
		if !setup { return }
		input := smallData[:smallSize]
		label := "observation/action width"
		switch mode {
		case 0: input = bigData[:bigSize]; label = "optimizer pointer capacity"
		case 1: input = bigData[:bigSize]; label = "optimizer moment capacity"
		case 2: label = "minibatch scratch capacity"
		case 3: input = epochData[:epochSize]; label = "epoch scratch capacity"
		case 4: input = defaultData[:defaultSize]; label = "default minibatch scratch capacity"
		}
		_ = ppoContextNormalizedTestRejectRead(t, label, &target.trainer, &allocator, input, ppoCheckpointInitTestNormalizers(&target), .CheckpointIncompatible)
		testing.expect(t, PPOTrainingContextDestroy(&target.trainer) == .None && allocator.frees == 4 && allocator.badFrees == 0)
	}
	// SGD is a valid normalized checkpoint but cannot restore an Adam trainer.
	sgd: NormalizedInspectTestFixture
	setup = normalizedInspectTestFixture(&sgd, false, 2, 1)
	testing.expect(t, setup)
	if !setup { return }
	target: PPOCheckpointInitTestTarget
	allocator: PPOContextTestAllocator
	setup = ppoContextNormalizedTestStart(&target, &allocator, epochOptions)
	testing.expect(t, setup)
	if !setup { return }
	defer PPOTrainingContextDestroy(&target.trainer)
	_ = ppoContextNormalizedTestRejectRead(t, "SGD optimizer", &target.trainer, &allocator, sgd.bytes[:sgd.size], ppoCheckpointInitTestNormalizers(&target), .CheckpointIncompatible)
}

ppoContextNormalizedTestCapacityTarget :: proc(
	t: ^testing.T, policy: ^Sequential($pl, $pw, $pb), value: ^Sequential($vl, $vw, $vb),
	options: PPOTrainingContextOptions, input: []u8,
) {
	trainer: PPOTrainingContext(pl, pw, pb, vl, vw, vb)
	allocator := PPOContextTestAllocator{backing = context.allocator}
	err := PPOTrainingContextInit(&trainer, policy, value, options, mem.Allocator{procedure = PPOContextTestAllocatorProc, data = &allocator})
	testing.expect(t, err == .None)
	if err != .None { return }
	defer PPOTrainingContextDestroy(&trainer)
	_ = ppoContextNormalizedTestRejectRead(t, "larger encoded actor/critic capacity", &trainer, &allocator, input, {}, .CheckpointIncompatible)
}

@(test)
PPOContextNormalizedCheckpointIndependentModelCapacities :: proc(t: ^testing.T) {
	policy, value: Sequential(2, 3, 2)
	policyLayers, valueLayers: Sequential(1, 3, 2)
	policyWidth, valueWidth: Sequential(2, 2, 2)
	policyBatch, valueBatch: Sequential(2, 3, 1)
	setup := PPOContextCheckpointBuildModels(&policy, &value, 2, 2, 0) &&
		SequentialInit(&policyLayers, 2, 1) && SequentialAddDense(&policyLayers, 2) &&
		SequentialInit(&valueLayers, 2, 2) && SequentialAddDense(&valueLayers, 1) &&
		SequentialInit(&policyWidth, 2, 3) && SequentialAddDense(&policyWidth, 2) &&
		SequentialInit(&valueWidth, 2, 4) && SequentialAddDense(&valueWidth, 1) &&
		SequentialInit(&policyBatch, 2, 5) && SequentialAddDense(&policyBatch, 2) &&
		SequentialInit(&valueBatch, 2, 6) && SequentialAddDense(&valueBatch, 1)
	testing.expect(t, setup)
	if !setup { return }
	options := PPOTrainingContextOptionsDefault(5)
	options.fit = {epochs = 2, batchSize = 1}
	target: PPOCheckpointInitTestTarget
	allocator: PPOContextTestAllocator
	setup = ppoContextNormalizedTestStart(&target, &allocator, options)
	testing.expect(t, setup)
	if !setup { return }
	defer PPOTrainingContextDestroy(&target.trainer)
	checkpoint: [4096]u8
	for mode in 0..<6 {
		size: int
		err: PPOTrainingContextError
		switch mode {
		case 0: size, err = ppoContextNormalizedTestMake(&policyLayers, &value, options, {}, checkpoint[:])
		case 1: size, err = ppoContextNormalizedTestMake(&policyWidth, &value, options, {}, checkpoint[:])
		case 2: size, err = ppoContextNormalizedTestMake(&policyBatch, &value, options, {}, checkpoint[:])
		case 3: size, err = ppoContextNormalizedTestMake(&policy, &valueLayers, options, {}, checkpoint[:])
		case 4: size, err = ppoContextNormalizedTestMake(&policy, &valueWidth, options, {}, checkpoint[:])
		case 5: size, err = ppoContextNormalizedTestMake(&policy, &valueBatch, options, {}, checkpoint[:])
		}
		testing.expectf(t, err == .None && size > 0, "capacity fixture %d: %v", mode, err)
		if err != .None || size <= 0 { return }
		_ = ppoContextNormalizedTestRejectRead(t, "independent actor/critic capacity", &target.trainer, &allocator, checkpoint[:size], {}, .CheckpointIncompatible)
	}
	// Exercise the inverse direction too: inspection limits must reject each
	// independently oversized encoded capacity before touching a smaller target.
	size, err := ppoContextNormalizedTestMake(&policy, &value, options, {}, checkpoint[:])
	testing.expect(t, err == .None && size > 0)
	if err != .None || size <= 0 { return }
	ppoContextNormalizedTestCapacityTarget(t, &policyLayers, &value, options, checkpoint[:size])
	ppoContextNormalizedTestCapacityTarget(t, &policyWidth, &value, options, checkpoint[:size])
	ppoContextNormalizedTestCapacityTarget(t, &policyBatch, &value, options, checkpoint[:size])
	ppoContextNormalizedTestCapacityTarget(t, &policy, &valueLayers, options, checkpoint[:size])
	ppoContextNormalizedTestCapacityTarget(t, &policy, &valueWidth, options, checkpoint[:size])
	ppoContextNormalizedTestCapacityTarget(t, &policy, &valueBatch, options, checkpoint[:size])
}

@(test)
PPOContextNormalizedCheckpointMalformedIsAtomic :: proc(t: ^testing.T) {
	fixture: NormalizedInspectTestFixture
	setup := normalizedInspectTestFixture(&fixture, true, 2, 1)
	options := PPOTrainingContextOptionsDefault(5)
	options.fit = {epochs = 3, batchSize = 2}
	target: PPOCheckpointInitTestTarget
	allocator: PPOContextTestAllocator
	setup = setup && ppoContextNormalizedTestStart(&target, &allocator, options)
	testing.expect(t, setup)
	if !setup { return }
	defer PPOTrainingContextDestroy(&target.trainer)
	backing: PPOContextTestRolloutBacking
	buffer: rl.RolloutBuffer
	setup = PPOContextTestRolloutInit(&buffer, &backing) &&
		PPOContextTestCollect(&target.dest.policy, &target.dest.value, PPOTrainingContextState(&target.trainer), &buffer, 5) &&
		PPOTrainingContextRecordRollout(&target.trainer) == .None
	testing.expect(t, setup)
	if !setup { return }
	_, fitErr := PPOTrainingContextFit(&target.trainer, &buffer)
	testing.expect(t, fitErr == .None)
	if fitErr != .None { return }
	normalizers := ppoCheckpointInitTestNormalizers(&target)
	for length in 0..<fixture.size {
		ok := ppoContextNormalizedTestRejectRead(t, "truncated normalized checkpoint", &target.trainer, &allocator, fixture.bytes[:length], normalizers, .InvalidCheckpoint)
		testing.expectf(t, ok, "truncation at %d/%d", length, fixture.size)
		if !ok { return }
	}
	_ = ppoContextNormalizedTestRejectRead(t, "base format", &target.trainer, &allocator, fixture.bytes[fixture.baseAt:fixture.size], normalizers, .InvalidCheckpoint)
	for mode in 0..<15 {
		bad := fixture.bytes
		length := fixture.size
		position := 0
		switch mode {
		case 0: bad[0] ~= 0xff
		case 1: position = 8; normalizedInspectTestPut64(bad[:], &position, 99)
		case 2: position = 16; normalizedInspectTestPut64(bad[:], &position, max(u64))
		case 3: position = fixture.observationAt; normalizedInspectTestPut64(bad[:], &position, 2)
		case 4: position = fixture.observationAt+8; normalizedInspectTestPut64(bad[:], &position, 0)
		case 5: position = fixture.observationAt+24; normalizedInspectTestPutF64(bad[:], &position, 0)
		case 6: position = fixture.observationAt+56; normalizedInspectTestPutF64(bad[:], &position, -1)
		case 7: position = fixture.rewardAt+16; normalizedInspectTestPut64(bad[:], &position, 2)
		case 8: position = fixture.rewardAt+48; normalizedInspectTestPutF64(bad[:], &position, -1)
		case 9: bad[fixture.policyAt] ~= 0xff
		case 10: bad[fixture.valueAt] ~= 0xff
		case 11: position = fixture.baseAt+80; normalizedInspectTestPut64(bad[:], &position, 0)
		case 12: position = fixture.baseAt+144; normalizedInspectTestPutF32(bad[:], &position, transmute(f32)u32(0x7fc00000))
		case 13: position = fixture.size-4; normalizedInspectTestPutF32(bad[:], &position, transmute(f32)u32(0x7fc00000))
		case 14: bad[fixture.size] = 0x5a; length += 1
		}
		_ = ppoContextNormalizedTestRejectRead(t, "malformed normalized checkpoint", &target.trainer, &allocator, bad[:length], normalizers, .InvalidCheckpoint)
	}
	// Critic input disagreement or a non-scalar critic cannot form a valid PPO
	// checkpoint. Replace only the critic with an independently valid model.
	for mode in 0..<2 {
		critic: Sequential(2, 3, 2)
		inputWidth, outputWidth := 1, 1
		if mode == 1 { inputWidth, outputWidth = 2, 2 }
		setup = SequentialInit(&critic, inputWidth, 83) && SequentialAddDense(&critic, outputWidth)
		testing.expect(t, setup)
		if !setup { return }
		modelBytes, bad: [4096]u8
		modelSize, saved := CheckpointWrite(&critic, nil, 17, modelBytes[:])
		length := fixture.valueAt+modelSize
		testing.expect(t, saved && length <= len(bad))
		if !saved || length > len(bad) { return }
		copy(bad[:fixture.valueAt], fixture.bytes[:fixture.valueAt])
		copy(bad[fixture.valueAt:length], modelBytes[:modelSize])
		position := 16
		normalizedInspectTestPut64(bad[:], &position, u64(length-fixture.baseAt))
		position = fixture.baseAt+24
		normalizedInspectTestPut64(bad[:], &position, u64(modelSize))
		_, nestedErr := CheckpointInspect(bad[fixture.valueAt:length])
		_, inspectErr := PPOCheckpointInspectNormalized(bad[:length])
		testing.expectf(t, nestedErr.code == .None && inspectErr.code == .InvalidArchitecture, "critic dimensions %d", mode)
		_ = ppoContextNormalizedTestRejectRead(t, "invalid critic dimensions", &target.trainer, &allocator, bad[:length], normalizers, .InvalidCheckpoint)
	}
}

@(test)
PPOContextNormalizedCheckpointValidBufferAliases :: proc(t: ^testing.T) {
	policyBox, valueBox: PPOContextCheckpointModelBox
	trainerBox: PPOContextCheckpointTrainerBox
	policy, value, trainer := &policyBox.model, &valueBox.model, &trainerBox.trainer
	setup := PPOContextCheckpointBuildModels(policy, value, 2, 2, 0)
	options := PPOTrainingContextOptionsDefault(5)
	options.fit = {epochs = 2, batchSize = 2}
	guard := PPOContextCheckpointGuardAllocator{backing = context.allocator}
	allocator := mem.Allocator{procedure = PPOContextCheckpointGuardAllocatorProc, data = &guard}
	if setup { setup = PPOTrainingContextInit(trainer, policy, value, options, allocator) == .None }
	testing.expect(t, setup && guard.allocations == 4)
	if !setup { return }
	defer PPOTrainingContextDestroy(trainer)
	tracked: PPOContextTestAllocator
	for i in 0..<4 { tracked.allocated[i], tracked.sizes[i] = guard.allocated[i], guard.sizes[i] }
	observationBox, rewardBox: PPOCheckpointInitNormalizerBox
	observationMean, observationM2: PPOCheckpointInitObsArrayBox
	rewardMean, rewardM2: PPOCheckpointInitRewardArrayBox
	setup = data.RunningStandardizerInit(&observationBox.value, observationMean.value[:], observationM2.value[:]) &&
		data.RunningStandardizerInit(&rewardBox.value, rewardMean.value[:], rewardM2.value[:])
	observations, rewards := [4]f32{1, 2, 3, 4}, [2]f32{-1, 1}
	setup = setup && data.RunningStandardizerUpdate(&observationBox.value, observations[:]) &&
		data.RunningStandardizerUpdate(&rewardBox.value, rewards[:])
	testing.expect(t, setup)
	if !setup { return }
	normalizers := PPOTrainingNormalizers{&observationBox.value, &rewardBox.value}
	checkpoint, candidate, output, baseScratch, policyScratch, valueScratch: [4096]u8
	size, err := PPOTrainingContextCheckpointWriteNormalized(trainer, normalizers, checkpoint[:], baseScratch[:], policyScratch[:], valueScratch[:])
	testing.expect(t, err == .None && size >= 4 && size < 4096)
	if err != .None || size < 4 || size >= 4096 { return }
	// Each target has a private prefix, so the overlapping buffers are large
	// enough to succeed and touch only one byte of the live destination.
	targets := [13]rawptr{
		rawptr(trainer), guard.allocated[0], rawptr(policy), rawptr(value), guard.allocated[1], guard.allocated[2], guard.allocated[3],
		rawptr(&observationBox.value), rawptr(&observationMean.value), rawptr(&observationM2.value),
		rawptr(&rewardBox.value), rawptr(&rewardMean.value), rawptr(&rewardM2.value),
	}
	for target, index in targets {
		for role in 0..<4 {
			overlap := mem.slice_ptr((^u8)(rawptr(uintptr(target)-4095)), 4096)
			out, base, p, v := output[:], baseScratch[:], policyScratch[:], valueScratch[:]
			switch role {
			case 0: out = overlap
			case 1: base = overlap
			case 2: p = overlap
			case 3: v = overlap
			}
			ok := ppoContextNormalizedTestRejectWrite(t, "overlapping full-size write buffer", trainer, &tracked, normalizers, out, base, p, v)
			testing.expectf(t, ok, "write alias target=%d buffer=%d", index, role)
			if !ok { return }
		}
		candidate = checkpoint
		// Preserve the live byte while keeping the final encoded f32 finite.
		candidate[size-4], candidate[size-3], candidate[size-2] = 0, 0, 0
		candidate[size-1] = (^u8)(target)^
		input := mem.slice_ptr((^u8)(rawptr(uintptr(target)-uintptr(size-1))), size)
		copy(input, candidate[:size])
		_, inspectErr := PPOCheckpointInspectNormalized(input)
		probe: NormalizedInspectTestTarget
		setup = normalizedInspectTestTargetInit(&probe)
		_, _, _, _, readable := normalizedInspectTestRead(&probe, input, true, true, true)
		testing.expectf(t, setup && inspectErr.code == .None && readable, "alias input %d is otherwise valid", index)
		if !setup || inspectErr.code != .None || !readable { return }
		ok := ppoContextNormalizedTestRejectRead(t, "valid overlapping input", trainer, &tracked, input, normalizers, .InvalidCheckpoint)
		testing.expectf(t, ok, "read alias target=%d", index)
		if !ok { return }
	}
	testing.expect(t, PPOTrainingContextDestroy(trainer) == .None && guard.frees == 4 && guard.badFrees == 0)
}

@(test)
PPOContextNormalizedCheckpointNormalizerAliases :: proc(t: ^testing.T) {
	target: PPOCheckpointInitTestTarget
	allocator: PPOContextTestAllocator
	options := PPOTrainingContextOptionsDefault(5)
	options.fit = {epochs = 2, batchSize = 2}
	setup := ppoContextNormalizedTestStart(&target, &allocator, options)
	testing.expect(t, setup)
	if !setup { return }
	defer PPOTrainingContextDestroy(&target.trainer)
	checkpoint, output, baseScratch, policyScratch, valueScratch: [4096]u8
	size, err := PPOTrainingContextCheckpointWriteNormalized(&target.trainer, ppoCheckpointInitTestNormalizers(&target),
		checkpoint[:], baseScratch[:], policyScratch[:], valueScratch[:])
	testing.expect(t, err == .None && size > 0)
	if err != .None || size <= 0 { return }
	for &byte in output { byte = 0xa5 }
	// Place a valid normalizer object inside either the trainer or its last
	// scratch slice, then restore the temporarily borrowed bytes after the test.
	for mode in 0..<4 {
		address := rawptr(&target.trainer.state)
		if mode%2 == 1 { address = rawptr(uintptr(target.trainer.scratch.memory)+uintptr(allocator.sizes[0]-size_of(data.RunningStandardizer))) }
		saved: [size_of(data.RunningStandardizer)]u8
		region := mem.slice_ptr((^u8)(address), len(saved))
		copy(saved[:], region)
		mean, m2: [2]f64
		width := 2
		if mode >= 2 { width = 1 }
		aliased := (^data.RunningStandardizer)(address)
		setup = data.RunningStandardizerInit(aliased, mean[:width], m2[:width]) && data.RunningStandardizerValid(aliased)
		testing.expectf(t, setup, "normalizer object alias %d", mode)
		if setup {
			normalizers := PPOTrainingNormalizers{aliased, &target.dest.reward}
			if mode >= 2 { normalizers = {&target.dest.observation, aliased} }
			_ = ppoContextNormalizedTestRejectWrite(t, "normalizer object in trainer/scratch", &target.trainer, &allocator, normalizers,
				output[:], baseScratch[:], policyScratch[:], valueScratch[:])
			_ = ppoContextNormalizedTestRejectRead(t, "normalizer object in trainer/scratch", &target.trainer, &allocator,
				checkpoint[:size], normalizers, .InvalidCheckpoint)
		}
		copy(region, saved[:])
	}
	// Independently alias mean and M2 with both the trainer and the beginning
	// or end of the complete scratch block, not just the active fit batch.
	for mode in 0..<12 {
		location := mode%6
		address := rawptr(&target.trainer.pending.blocks[0])
		if location >= 2 {
			address = target.trainer.scratch.memory
			if location >= 4 { address = rawptr(uintptr(address)+uintptr(allocator.sizes[0]-2*size_of(f64))) }
		}
		saved: [2*size_of(f64)]u8
		region := mem.slice_ptr((^u8)(address), len(saved))
		copy(saved[:], region)
		for &byte in region { byte = 0 }
		mean, m2: [2]f64
		width := 2
		if mode >= 6 { width = 1 }
		aliased: data.RunningStandardizer
		setup = data.RunningStandardizerInit(&aliased, mean[:width], m2[:width])
		aliased.count = 1
		if location%2 == 0 { aliased.mean = mem.slice_ptr((^f64)(address), width) } else { aliased.m2 = mem.slice_ptr((^f64)(address), width) }
		setup = setup && data.RunningStandardizerValid(&aliased)
		testing.expectf(t, setup, "normalizer moment alias %d", mode)
		if setup {
			normalizers := PPOTrainingNormalizers{&aliased, &target.dest.reward}
			if mode >= 6 { normalizers = {&target.dest.observation, &aliased} }
			_ = ppoContextNormalizedTestRejectWrite(t, "normalizer moments in trainer/scratch", &target.trainer, &allocator, normalizers,
				output[:], baseScratch[:], policyScratch[:], valueScratch[:])
			_ = ppoContextNormalizedTestRejectRead(t, "normalizer moments in trainer/scratch", &target.trainer, &allocator,
				checkpoint[:size], normalizers, .InvalidCheckpoint)
		}
		copy(region, saved[:])
	}
	// Both valid normalizers can still overlap each other's backing storage.
	originalMean := target.dest.reward.mean
	target.dest.reward.mean = target.dest.observation.mean[:1]
	testing.expect(t, data.RunningStandardizerValid(&target.dest.observation) && data.RunningStandardizerValid(&target.dest.reward))
	normalizers := ppoCheckpointInitTestNormalizers(&target)
	_ = ppoContextNormalizedTestRejectWrite(t, "normalizers share moments", &target.trainer, &allocator, normalizers,
		output[:], baseScratch[:], policyScratch[:], valueScratch[:])
	_ = ppoContextNormalizedTestRejectRead(t, "normalizers share moments", &target.trainer, &allocator,
		checkpoint[:size], normalizers, .InvalidCheckpoint)
	target.dest.reward.mean = originalMean
}

@(test)
PPOContextNormalizedCheckpointEntireScratchRange :: proc(t: ^testing.T) {
	target: PPOCheckpointInitTestTarget
	allocator: PPOContextTestAllocator
	options := PPOTrainingContextOptionsDefault(5)
	options.fit = {epochs = 2, batchSize = 1}
	setup := ppoContextNormalizedTestStart(&target, &allocator, options)
	testing.expect(t, setup)
	if !setup { return }
	defer PPOTrainingContextDestroy(&target.trainer)
	storage, storageOk := PPOOwnedFitStorageView(&target.trainer.scratch)
	testing.expect(t, storageOk && allocator.allocated[0] == target.trainer.scratch.memory)
	if !storageOk { return }
	start := uintptr(target.trainer.scratch.memory)
	gapStart := uintptr(rawptr(raw_data(storage.legalActions)))+uintptr(len(storage.legalActions))
	gapEnd := uintptr(rawptr(raw_data(storage.oldLogProbabilities)))
	testing.expect(t, gapEnd > gapStart && gapEnd <= start+uintptr(allocator.sizes[0]))
	if gapEnd <= gapStart { return }
	missed := 0
	for offset in 0..<allocator.sizes[0] {
		one := mem.slice_ptr((^u8)(rawptr(start+uintptr(offset))), 1)
		if ppoTrainingContextCheckpointBufferDisjoint(&target.trainer, one) { missed += 1 }
	}
	// Small padding-only slices cannot hold a checkpoint, so directly check the
	// wrapper's buffer guard as well as the public failure paths below.
	testing.expectf(t, missed == 0, "scratch buffer guard missed %d bytes, including alignment padding [%d,%d)", missed, gapStart-start, gapEnd-start)
	checkpoint, output, baseScratch, policyScratch, valueScratch: [4096]u8
	size, err := PPOTrainingContextCheckpointWriteNormalized(&target.trainer, ppoCheckpointInitTestNormalizers(&target),
		checkpoint[:], baseScratch[:], policyScratch[:], valueScratch[:])
	testing.expect(t, err == .None && size > 0)
	if err != .None || size <= 0 { return }
	for address := gapStart; address < gapEnd; address += 1 {
		one := mem.slice_ptr((^u8)(rawptr(address)), 1)
		for role in 0..<4 {
			out, base, p, v := output[:], baseScratch[:], policyScratch[:], valueScratch[:]
			switch role {
			case 0: out = one
			case 1: base = one
			case 2: p = one
			case 3: v = one
			}
			_ = ppoContextNormalizedTestRejectWrite(t, "scratch padding write buffer", &target.trainer, &allocator,
				ppoCheckpointInitTestNormalizers(&target), out, base, p, v)
		}
		_ = ppoContextNormalizedTestRejectRead(t, "scratch padding input", &target.trainer, &allocator, one,
			ppoCheckpointInitTestNormalizers(&target), .InvalidCheckpoint)
	}
}

@(test)
PPOContextNormalizedCheckpointWriteFailuresAreAtomic :: proc(t: ^testing.T) {
	target: PPOCheckpointInitTestTarget
	allocator: PPOContextTestAllocator
	options := PPOTrainingContextOptionsDefault(5)
	options.fit = {epochs = 2, batchSize = 2}
	setup := ppoContextNormalizedTestStart(&target, &allocator, options)
	testing.expect(t, setup)
	if !setup { return }
	defer PPOTrainingContextDestroy(&target.trainer)
	for mode in 0..<8 {
		output, baseScratch, policyScratch, valueScratch: [4096]u8
		for &byte in output { byte = 0xa5 }
		before := output
		out, base, p, v := output[:], baseScratch[:], policyScratch[:], valueScratch[:]
		switch mode {
		case 0: out = output[:1]
		case 1: base = baseScratch[:1]
		case 2: p = policyScratch[:1]
		case 3: v = valueScratch[:1]
		case 4: base = output[:]
		case 5: p = output[1:]
		case 6: v = baseScratch[1:]
		case 7: v = policyScratch[:]
		}
		ok := ppoContextNormalizedTestRejectWrite(t, "undersized or mutually overlapping write buffers", &target.trainer, &allocator,
			ppoCheckpointInitTestNormalizers(&target), out, base, p, v)
		testing.expectf(t, ok && output == before, "write failure mode %d", mode)
	}
	for mode in 0..<2 {
		originalRandomState := target.trainer.state.policyRandomState
		adam := PPOTrainingContextOptimizer(&target.trainer)
		originalMoment := adam.secondMoment[0]
		if mode == 0 { target.trainer.state.policyRandomState = 0 } else { adam.secondMoment[0] = -1 }
		output, baseScratch, policyScratch, valueScratch: [4096]u8
		for &byte in output { byte = 0xa5 }
		_ = ppoContextNormalizedTestRejectWrite(t, "invalid learner state or Adam moment", &target.trainer, &allocator,
			ppoCheckpointInitTestNormalizers(&target), output[:], baseScratch[:], policyScratch[:], valueScratch[:])
		target.trainer.state.policyRandomState, adam.secondMoment[0] = originalRandomState, originalMoment
	}
}

@(test)
PPOContextNormalizedCheckpointLargeModelsUnderStackLimit :: proc(t: ^testing.T) {
	models: PPOStackTestModels
	defer PPOStackTestModelsDestroy(&models)
	setup := PPOStackTestModelsInit(&models)
	testing.expect(t, setup && SequentialStorageSize(1, 1024, 2) > 8*1024*1024)
	if !setup { return }
	policy, value := OwnedSequentialModel(&models.policy), OwnedSequentialModel(&models.value)
	restoredPolicy, restoredValue := OwnedSequentialModel(&models.restoredPolicy), OwnedSequentialModel(&models.restoredValue)
	trainer, restored: PPOTrainingContext(1, 1024, 2, 1, 1024, 2)
	defer PPOTrainingContextDestroy(&trainer)
	defer PPOTrainingContextDestroy(&restored)
	stats, restoredStats: PPOStackNormStats
	setup = PPOStackNormStatsInit(&stats, 1, 1, true) && PPOStackNormStatsInit(&restoredStats, 1, 1, false)
	options := PPOTrainingContextOptionsDefault(1)
	options.fit = {epochs = 1, batchSize = 1}
	allocator, restoredAllocator := PPOContextTestAllocator{backing = context.allocator}, PPOContextTestAllocator{backing = context.allocator}
	if setup {
		setup = PPOTrainingContextInit(&trainer, policy, value, options, mem.Allocator{procedure = PPOContextTestAllocatorProc, data = &allocator}) == .None &&
			PPOTrainingContextInit(&restored, restoredPolicy, restoredValue, options, mem.Allocator{procedure = PPOContextTestAllocatorProc, data = &restoredAllocator}) == .None
	}
	testing.expect(t, setup)
	if !setup { return }
	backing: PPOStackTestRollout
	setup = PPOStackTestRolloutInit(&backing) && PPOTrainingContextRecordRollout(&trainer) == .None
	testing.expect(t, setup)
	if !setup { return }
	fit, fitError := PPOTrainingContextFit(&trainer, &backing.buffer)
	testing.expect(t, fitError == .None && fit.updates == 1)
	if fitError != .None { return }
	checkpoint, baseScratch, policyScratch, valueScratch: [4096]u8
	forbidden: PPOContextNormalizedTestNoAlloc
	noAlloc := mem.Allocator{procedure = ppoContextNormalizedTestNoAllocProc, data = &forbidden}
	size: int
	writeError, readError: PPOTrainingContextError
	{
		context.allocator = noAlloc
		context.temp_allocator = noAlloc
		size, writeError = PPOTrainingContextCheckpointWriteNormalized(&trainer, {&stats.observation, &stats.reward},
			checkpoint[:], baseScratch[:], policyScratch[:], valueScratch[:])
		if writeError == .None {
			readError = PPOTrainingContextCheckpointReadNormalized(&restored, checkpoint[:size], {&restoredStats.observation, &restoredStats.reward})
		}
	}
	testing.expect(t, writeError == .None && readError == .None && size > 0 && forbidden.calls == 0 &&
		allocator.attempts == 4 && restoredAllocator.attempts == 4 &&
		PPOTrainingContextState(&trainer)^ == PPOTrainingContextState(&restored)^ &&
		PPOStackTestAdamEqual(PPOTrainingContextOptimizer(&trainer), PPOTrainingContextOptimizer(&restored)) &&
		PPOStackTestParametersEqual(policy, restoredPolicy) && PPOStackTestParametersEqual(value, restoredValue) &&
		PPOStackNormEqual(&stats.observation, &restoredStats.observation) && PPOStackNormEqual(&stats.reward, &restoredStats.reward))
	if writeError != .None || readError != .None { return }
	next, nextError := PPOTrainingContextFit(&trainer, &backing.buffer)
	other, otherError := PPOTrainingContextFit(&restored, &backing.buffer)
	testing.expect(t, nextError == .None && otherError == .None && next == other &&
		PPOTrainingContextState(&trainer)^ == PPOTrainingContextState(&restored)^ &&
		PPOStackTestAdamEqual(PPOTrainingContextOptimizer(&trainer), PPOTrainingContextOptimizer(&restored)) &&
		PPOStackTestParametersEqual(policy, restoredPolicy) && PPOStackTestParametersEqual(value, restoredValue))
}
