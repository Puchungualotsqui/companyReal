package nn

import "../core"
import "../data"
import "core:math"
import "core:mem"
import "core:testing"

// Encode the normalized wrapper independently of its writer, including widths
// that the writer correctly refuses, around a real base PPO checkpoint.
normalizedInspectTestPut64 :: proc(bytes: []u8, offset: ^int, value: u64) {
	for i in 0..<8 { bytes[offset^+i] = u8(value >> uint(8*i)) }
	offset^ += 8
}

normalizedInspectTestPutF64 :: proc(bytes: []u8, offset: ^int, value: f64) {
	normalizedInspectTestPut64(bytes, offset, transmute(u64)value)
}

normalizedInspectTestPutF32 :: proc(bytes: []u8, offset: ^int, value: f32) {
	bits := transmute(u32)value
	for i in 0..<4 { bytes[offset^+i] = u8(bits >> uint(8*i)) }
	offset^ += 4
}

NormalizedInspectTestFixture :: struct {
	bytes: [4096]u8,
	size, observationAt, rewardAt, baseAt, baseSize, policyAt, valueAt: int,
}

normalizedInspectTestNormalizer :: proc(bytes: []u8, offset: ^int, width: int, observation, empty: bool) {
	if width == 0 { normalizedInspectTestPut64(bytes, offset, 0); return }
	normalizedInspectTestPut64(bytes, offset, 1)
	count: u64 = 3
	if observation { count = 2 }
	if empty { count = 0 }
	normalizedInspectTestPut64(bytes, offset, count)
	normalizedInspectTestPut64(bytes, offset, u64(width))
	epsilon: f64 = 0.03
	if observation { epsilon = 0.02 }
	normalizedInspectTestPutF64(bytes, offset, epsilon)
	frozen: u64
	if observation && !empty { frozen = 1 }
	normalizedInspectTestPut64(bytes, offset, frozen)
	for i in 0..<width {
		mean: f64
		if observation && !empty { mean = f64(2+10*i) }
		normalizedInspectTestPutF64(bytes, offset, mean)
	}
	for i in 0..<width {
		m2: f64
		if !empty {
			m2 = 8
			if observation { m2 = f64(2*(i+1)*(i+1)) }
		}
		normalizedInspectTestPutF64(bytes, offset, m2)
	}
}

normalizedInspectTestFixture :: proc(f: ^NormalizedInspectTestFixture, useAdam: bool, observationWidth, rewardWidth: int, empty: bool = false) -> bool {
	f^ = {}
	policy, value: Sequential(2, 3, 2)
	if !SequentialInit(&policy, 2, 17) || !SequentialAddDense(&policy, 2) ||
		!SequentialInit(&value, 2, 29) || !SequentialAddDense(&value, 1) { return false }
	parameters: [4]^core.Node
	first, second: [9]f32
	adam: Adam
	optimizer: SequentialOptimizer = SequentialSGD{0.025}
	if useAdam {
		list, elements, ok := PPOCheckpointCombinedParameters(&policy, &value, parameters[:])
		if !ok || elements != len(first) || !AdamInit(&adam, list, first[:], second[:], learningRate = 0.01) { return false }
		adam.step = 7
		for &item, i in first { item = f32(i)-2 }
		for &item, i in second { item = f32(i)/2 }
		optimizer = &adam
	}
	base, policyScratch, valueScratch: [2048]u8
	baseSize, ok := PPOCheckpointWrite(&policy, &value, optimizer, {5, 8, 17, 23},
		{0.2, 0.01, 0.5, 1.5}, {epochs = 3, batchSize = 2, maxGradientNorm = 0.5, finalLearningRate = 0.001},
		base[:], policyScratch[:], valueScratch[:])
	if !ok { return false }
	offset := 0
	normalizedInspectTestPut64(f.bytes[:], &offset, PPO_NORMALIZED_CHECKPOINT_MAGIC)
	normalizedInspectTestPut64(f.bytes[:], &offset, PPO_NORMALIZED_CHECKPOINT_VERSION)
	normalizedInspectTestPut64(f.bytes[:], &offset, u64(baseSize))
	f.observationAt = offset
	normalizedInspectTestNormalizer(f.bytes[:], &offset, observationWidth, true, empty)
	f.rewardAt = offset
	normalizedInspectTestNormalizer(f.bytes[:], &offset, rewardWidth, false, empty)
	f.baseAt, f.baseSize = offset, baseSize
	copy(f.bytes[offset:offset+baseSize], base[:baseSize])
	f.size = offset+baseSize
	policyOffset := 116
	if useAdam { policyOffset = 144+8*len(first) }
	position := 16
	policySize, policySizeOk := CheckpointGet64(base[:baseSize], &position)
	if !policySizeOk { return false }
	f.policyAt = f.baseAt+policyOffset
	f.valueAt = f.policyAt+int(policySize)
	return true
}

normalizedInspectTestError :: proc(t: ^testing.T, bytes: []u8, limits: PPONormalizedCheckpointInspectLimits, code: CheckpointErrorCode, offset: int) {
	info, err := PPOCheckpointInspectNormalized(bytes, limits)
	testing.expectf(t, info == (PPONormalizedCheckpointInfo{}) && err.code == code && err.offset == offset,
		"expected %v at %d, got %v at %d (zero info %v)", code, offset, err.code, err.offset, info == (PPONormalizedCheckpointInfo{}))
}

NormalizedInspectTestTarget :: struct {
	policy, value: Sequential(2, 3, 2),
	observation, reward: data.RunningStandardizer,
	observationMean, observationM2: [2]f64,
	rewardMean, rewardM2: [1]f64,
	adam: Adam,
	parameters: [8]^core.Node,
	first, second: [16]f32,
}

normalizedInspectTestTargetInit :: proc(target: ^NormalizedInspectTestTarget) -> bool {
	return SequentialInit(&target.policy, 2, 31) && SequentialAddDense(&target.policy, 2) &&
		SequentialInit(&target.value, 2, 37) && SequentialAddDense(&target.value, 1) &&
		data.RunningStandardizerInit(&target.observation, target.observationMean[:], target.observationM2[:]) &&
		data.RunningStandardizerInit(&target.reward, target.rewardMean[:], target.rewardM2[:])
}

normalizedInspectTestRead :: proc(target: ^NormalizedInspectTestTarget, bytes: []u8, useAdam, observation, reward: bool) -> (PPOTrainingState, PPOConfig, PPOFitConfig, SequentialOptimizer, bool) {
	normalizers: PPOTrainingNormalizers
	if observation { normalizers.observation = &target.observation }
	if reward { normalizers.reward = &target.reward }
	if useAdam {
		return PPOCheckpointReadNormalized(&target.policy, &target.value, bytes, &target.adam,
			target.parameters[:], target.first[:], target.second[:], normalizers)
	}
	return PPOCheckpointReadNormalized(&target.policy, &target.value, bytes, nil, nil, nil, nil, normalizers)
}

@(test)
PPOCheckpointInspectNormalizedPresenceAndNilAllocator :: proc(t: ^testing.T) {
	for useAdam in ([2]bool{false, true}) {
		for mask in 0..<4 {
			for empty in ([2]bool{false, true}) {
				obsWidth, rewardWidth := 0, 0
				if mask & 1 != 0 { obsWidth = 2 }
				if mask & 2 != 0 { rewardWidth = 1 }
				f: NormalizedInspectTestFixture
				built := normalizedInspectTestFixture(&f, useAdam, obsWidth, rewardWidth, empty)
				target: NormalizedInspectTestTarget
				setup := normalizedInspectTestTargetInit(&target)
				testing.expect(t, built && setup)
				if !built || !setup { return }
				before := f.bytes
				info, badInfo: PPONormalizedCheckpointInfo
				err, badErr: CheckpointError
				state: PPOTrainingState
				objective: PPOConfig
				fit: PPOFitConfig
				optimizer: SequentialOptimizer
				loaded: bool
				{
					context.allocator = mem.nil_allocator()
					info, err = PPOCheckpointInspectNormalized(f.bytes[:f.size])
					badInfo, badErr = PPOCheckpointInspectNormalized(f.bytes[:f.size-1])
					state, objective, fit, optimizer, loaded = normalizedInspectTestRead(&target, f.bytes[:f.size], useAdam, obsWidth != 0, rewardWidth != 0)
				}
				base, baseErr := PPOCheckpointInspect(f.bytes[f.baseAt:f.size])
				testing.expectf(t, err.code == .None && baseErr.code == .None && loaded && info.base == base && f.bytes == before,
					"adam=%v mask=%d empty=%v inspect=%v loaded=%v", useAdam, mask, empty, err, loaded)
				testing.expect(t, badInfo == (PPONormalizedCheckpointInfo{}) && badErr == (CheckpointError{.Truncated, f.size-1}))
				if err.code != .None || !loaded { continue }
				testing.expect(t, state == info.base.state && objective == info.base.objective && fit == info.base.fit &&
					info.base.policy.inputWidth == 2 && info.base.parameterPointers == 4 && info.base.momentElements == 9)
				if useAdam {
					_, isAdam := optimizer.(^Adam)
					testing.expect(t, isAdam && info.base.optimizer == .Adam && info.base.step == 7 && target.adam.step == 7)
				} else {
					_, isSGD := optimizer.(SequentialSGD)
					testing.expect(t, isSGD && info.base.optimizer == .SGD)
				}
				if obsWidth == 0 {
					testing.expect(t, info.observation == (PPOCheckpointNormalizerInfo{}))
				} else if empty {
					testing.expect(t, info.observation == (PPOCheckpointNormalizerInfo{true, 0, 2, 0.02, false}) &&
						target.observation.count == 0 && !target.observation.frozen && target.observationMean == ([2]f64{}))
				} else {
					testing.expect(t, info.observation == (PPOCheckpointNormalizerInfo{true, 2, 2, 0.02, true}) &&
						target.observation.count == 2 && target.observation.frozen && target.observation.epsilon == 0.02 &&
						target.observationMean == ([2]f64{2, 12}) && target.observationM2 == ([2]f64{2, 8}))
					raw, transformed := [2]f32{3, 14}, [2]f32{}
					transformedOk := data.RunningStandardizerTransform(&target.observation, raw[:], transformed[:])
					testing.expect(t, transformedOk && math.abs(f64(transformed[0])-1/math.sqrt(1.02)) < 1e-6 &&
						math.abs(f64(transformed[1])-2/math.sqrt(4.02)) < 1e-6)
				}
				if rewardWidth == 0 {
					testing.expect(t, info.reward == (PPOCheckpointNormalizerInfo{}))
				} else if empty {
					testing.expect(t, info.reward == (PPOCheckpointNormalizerInfo{true, 0, 1, 0.03, false}) && target.reward.count == 0)
				} else {
					testing.expect(t, info.reward == (PPOCheckpointNormalizerInfo{true, 3, 1, 0.03, false}) &&
						target.reward.count == 3 && !target.reward.frozen && target.reward.epsilon == 0.03 &&
						target.rewardMean == ([1]f64{0}) && target.rewardM2 == ([1]f64{8}))
					raw, transformed := [1]f32{2}, [1]f32{}
					transformedOk := data.RunningStandardizerTransform(&target.reward, raw[:], transformed[:])
					testing.expect(t, transformedOk && math.abs(f64(transformed[0])-2/math.sqrt(f64(8)/3+0.03)) < 1e-6)
				}
			}
		}
	}
}

@(test)
PPOCheckpointInspectNormalizedWriterRoundTrip :: proc(t: ^testing.T) {
	policy, value: Sequential(2, 3, 2)
	obsMean, obsM2: [2]f64
	rewardMean, rewardM2: [1]f64
	observation, reward: data.RunningStandardizer
	setup := SequentialInit(&policy, 2, 17) && SequentialAddDense(&policy, 2) &&
		SequentialInit(&value, 2, 29) && SequentialAddDense(&value, 1) &&
		data.RunningStandardizerInit(&observation, obsMean[:], obsM2[:], 0.02) &&
		data.RunningStandardizerInit(&reward, rewardMean[:], rewardM2[:], 0.03)
	obsSamples, rewardSamples := [4]f32{1, 10, 3, 14}, [3]f32{-2, 0, 2}
	setup = setup && data.RunningStandardizerUpdate(&observation, obsSamples[:]) &&
		data.RunningStandardizerUpdate(&reward, rewardSamples[:]) && data.RunningStandardizerFreeze(&observation)
	testing.expect(t, setup)
	if !setup { return }
	bytes, base, policyScratch, valueScratch: [2048]u8
	size, written := PPOCheckpointWriteNormalized(&policy, &value, SequentialSGD{0.025}, {5, 8, 17, 23},
		{0.2, 0.01, 0.5, 1.5}, {epochs = 3, batchSize = 2, maxGradientNorm = 0.5, finalLearningRate = 0.001},
		{&observation, &reward}, bytes[:], base[:], policyScratch[:], valueScratch[:])
	f: NormalizedInspectTestFixture
	built := normalizedInspectTestFixture(&f, false, 2, 1)
	testing.expect(t, written && built && size == f.size)
	if !written || !built || size != f.size { return }
	for item, i in bytes[:size] { testing.expectf(t, item == f.bytes[i], "writer differs at %d", i) }
	info, err := PPOCheckpointInspectNormalized(bytes[:size])
	testing.expect(t, err.code == .None && info.observation.count == 2 && info.observation.frozen && info.reward.count == 3)
}

@(test)
PPOCheckpointInspectNormalizedMalformedNormalizers :: proc(t: ^testing.T) {
	f: NormalizedInspectTestFixture
	testing.expect(t, normalizedInspectTestFixture(&f, false, 2, 1))
	o, r := f.observationAt, f.rewardAt
	integerCases := []struct { at: int, value: u64, code: CheckpointErrorCode, errorAt: int }{
		{0, 0, .InvalidMagic, 0}, {8, 2, .UnsupportedVersion, 8}, {16, max(u64), .Overflow, 16},
		{o, 2, .InvalidHeader, o}, {o+16, 0, .InvalidHeader, o+16},
		{o+16, max(u64), .Overflow, o+16}, {o+16, u64(max(int)), .Overflow, o+16},
		{o+32, 2, .InvalidHeader, o+32}, {o+8, 0, .InvalidValue, o+40},
		{r, 2, .InvalidHeader, r}, {r+16, 0, .InvalidHeader, r+16},
		{r+16, max(u64), .Overflow, r+16}, {r+32, 2, .InvalidHeader, r+32},
	}
	for item in integerCases {
		bad := f.bytes
		position := item.at
		normalizedInspectTestPut64(bad[:], &position, item.value)
		normalizedInspectTestError(t, bad[:f.size], {}, item.code, item.errorAt)
	}
	nan, inf := transmute(f64)u64(0x7ff8000000000000), transmute(f64)u64(0x7ff0000000000000)
	floatCases := []struct { at: int, value: f64 }{
		{o+24, 0}, {o+24, -1}, {o+24, nan}, {o+24, inf},
		{o+40, nan}, {o+48, inf}, {o+56, -1}, {o+64, nan}, {o+64, inf},
		{r+24, 0}, {r+24, nan}, {r+40, nan}, {r+48, -1}, {r+48, inf},
	}
	for item in floatCases {
		bad := f.bytes
		position := item.at
		normalizedInspectTestPutF64(bad[:], &position, item.value)
		normalizedInspectTestError(t, bad[:f.size], {}, .InvalidValue, item.at)
	}
	// Empty moments must be zero, whether frozen or not; -0 is valid.
	for frozen in ([2]bool{false, true}) {
		for at in ([4]int{o+40, o+56, r+40, r+48}) {
			empty: NormalizedInspectTestFixture
			testing.expect(t, normalizedInspectTestFixture(&empty, false, 2, 1, true))
			if frozen {
				position := o+32
				normalizedInspectTestPut64(empty.bytes[:], &position, 1)
				position = r+32
				normalizedInspectTestPut64(empty.bytes[:], &position, 1)
			}
			position := at
			normalizedInspectTestPutF64(empty.bytes[:], &position, 1)
			normalizedInspectTestError(t, empty.bytes[:empty.size], {}, .InvalidValue, at)
			target: NormalizedInspectTestTarget
			testing.expect(t, normalizedInspectTestTargetInit(&target))
			before: [size_of(NormalizedInspectTestTarget)]u8
			copy(before[:], mem.slice_ptr((^u8)(rawptr(&target)), len(before)))
			inputBefore := empty.bytes
			_, _, _, _, loaded := normalizedInspectTestRead(&target, empty.bytes[:empty.size], false, true, true)
			testing.expect(t, !loaded && empty.bytes == inputBefore && normalizedInspectTestMemoryEqual(rawptr(&target), before[:]))
		}
	}
	negativeZero: NormalizedInspectTestFixture
	testing.expect(t, normalizedInspectTestFixture(&negativeZero, false, 2, 1, true))
	position := o+40
	normalizedInspectTestPut64(negativeZero.bytes[:], &position, 0x8000000000000000)
	_, zeroErr := PPOCheckpointInspectNormalized(negativeZero.bytes[:negativeZero.size])
	testing.expect(t, zeroErr.code == .None)
	frozenEmpty := negativeZero.bytes
	position = r+32
	normalizedInspectTestPut64(frozenEmpty[:], &position, 1)
	frozenInfo, frozenErr := PPOCheckpointInspectNormalized(frozenEmpty[:negativeZero.size])
	testing.expect(t, frozenErr.code == .None && frozenInfo.reward == (PPOCheckpointNormalizerInfo{true, 0, 1, 0.03, true}))
	maximumCount := f.bytes
	position = o+8
	normalizedInspectTestPut64(maximumCount[:], &position, max(u64))
	maxInfo, maxErr := PPOCheckpointInspectNormalized(maximumCount[:f.size])
	testing.expect(t, maxErr.code == .None && maxInfo.observation.count == max(u64))
	wrongObservation, wrongReward: NormalizedInspectTestFixture
	testing.expect(t, normalizedInspectTestFixture(&wrongObservation, false, 1, 1) && normalizedInspectTestFixture(&wrongReward, false, 2, 2))
	normalizedInspectTestError(t, wrongObservation.bytes[:wrongObservation.size], {}, .InvalidArchitecture, wrongObservation.observationAt+16)
	normalizedInspectTestError(t, wrongReward.bytes[:wrongReward.size], {}, .InvalidArchitecture, wrongReward.rewardAt+16)
	// Reject the impossible reward width before scanning its moments or base.
	normalizedInspectTestError(t, wrongReward.bytes[:wrongReward.rewardAt+24], {}, .InvalidArchitecture, wrongReward.rewardAt+16)
}

@(test)
PPOCheckpointInspectNormalizedFrozenEmpty :: proc(t: ^testing.T) {
	for useAdam in ([2]bool{false, true}) {
		for presence in 0..<4 {
			for frozen in 0..<4 {
				obsWidth, rewardWidth := 0, 0
				if presence & 1 != 0 { obsWidth = 2 }
				if presence & 2 != 0 { rewardWidth = 1 }
				f: NormalizedInspectTestFixture
				target: NormalizedInspectTestTarget
				setup := normalizedInspectTestFixture(&f, useAdam, obsWidth, rewardWidth, true) && normalizedInspectTestTargetInit(&target)
				testing.expect(t, setup)
				if !setup { return }
				if obsWidth != 0 && frozen & 1 != 0 {
					position := f.observationAt+32
					normalizedInspectTestPut64(f.bytes[:], &position, 1)
				}
				if rewardWidth != 0 && frozen & 2 != 0 {
					position := f.rewardAt+32
					normalizedInspectTestPut64(f.bytes[:], &position, 1)
				}
				before := f.bytes
				info: PPONormalizedCheckpointInfo
				err: CheckpointError
				loaded: bool
				{
					context.allocator = mem.nil_allocator()
					info, err = PPOCheckpointInspectNormalized(f.bytes[:f.size])
					_, _, _, _, loaded = normalizedInspectTestRead(&target, f.bytes[:f.size], useAdam, obsWidth != 0, rewardWidth != 0)
				}
				testing.expectf(t, err.code == .None && loaded && f.bytes == before,
					"adam=%v presence=%d frozen=%d inspect=%v loaded=%v", useAdam, presence, frozen, err, loaded)
				if err.code != .None || !loaded { continue }
				if obsWidth != 0 {
					isFrozen := frozen & 1 != 0
					testing.expect(t, info.observation == (PPOCheckpointNormalizerInfo{true, 0, 2, 0.02, isFrozen}) &&
						target.observation.count == 0 && target.observation.frozen == isFrozen && target.observation.epsilon == 0.02 &&
						target.observationMean == ([2]f64{}) && target.observationM2 == ([2]f64{}))
					sample := [2]f32{3, 5}
					if isFrozen {
						testing.expect(t, !data.RunningStandardizerUpdate(&target.observation, sample[:]) &&
							data.RunningStandardizerUnfreeze(&target.observation))
					}
					testing.expect(t, data.RunningStandardizerUpdate(&target.observation, sample[:]) && target.observation.count == 1 &&
						!target.observation.frozen && target.observationMean == ([2]f64{3, 5}) && target.observationM2 == ([2]f64{}))
				} else { testing.expect(t, info.observation == (PPOCheckpointNormalizerInfo{})) }
				if rewardWidth != 0 {
					isFrozen := frozen & 2 != 0
					testing.expect(t, info.reward == (PPOCheckpointNormalizerInfo{true, 0, 1, 0.03, isFrozen}) &&
						target.reward.count == 0 && target.reward.frozen == isFrozen && target.reward.epsilon == 0.03 &&
						target.rewardMean == ([1]f64{}) && target.rewardM2 == ([1]f64{}))
					sample := [1]f32{7}
					if isFrozen {
						testing.expect(t, !data.RunningStandardizerUpdate(&target.reward, sample[:]) &&
							data.RunningStandardizerUnfreeze(&target.reward))
					}
					testing.expect(t, data.RunningStandardizerUpdate(&target.reward, sample[:]) && target.reward.count == 1 &&
						!target.reward.frozen && target.rewardMean == ([1]f64{7}) && target.rewardM2 == ([1]f64{}))
				} else { testing.expect(t, info.reward == (PPOCheckpointNormalizerInfo{})) }
			}
		}
	}
}

@(test)
PPOCheckpointInspectNormalizedTruncationAndNestedErrors :: proc(t: ^testing.T) {
	for useAdam in ([2]bool{false, true}) {
		f: NormalizedInspectTestFixture
		testing.expect(t, normalizedInspectTestFixture(&f, useAdam, 2, 1))
		for cut in 0..<f.size { normalizedInspectTestError(t, f.bytes[:cut], {}, .Truncated, cut) }
		before := f.bytes
		bad := f.bytes
		bad[f.size] = 42
		normalizedInspectTestError(t, bad[:f.size+1], {}, .TrailingData, f.size)
		position := 16
		normalizedInspectTestPut64(bad[:], &position, u64(f.baseSize+1))
		normalizedInspectTestError(t, bad[:f.size], {}, .Truncated, f.size)
		position = 16
		normalizedInspectTestPut64(bad[:], &position, u64(f.baseSize-1))
		normalizedInspectTestError(t, bad[:f.size], {}, .TrailingData, f.size-1)
		// The wrapper contains a complete declared base payload, which itself is truncated.
		normalizedInspectTestError(t, bad[:f.size-1], {}, .Truncated, f.size-1)
		bad = f.bytes
		bad[f.size] = 42
		position = 16
		normalizedInspectTestPut64(bad[:], &position, u64(f.baseSize+1))
		normalizedInspectTestError(t, bad[:f.size+1], {}, .TrailingData, f.size)
		cases := []struct { at: int, code: CheckpointErrorCode }{
			{f.baseAt, .InvalidMagic}, {f.policyAt, .InvalidMagic}, {f.valueAt, .InvalidMagic},
		}
		for item in cases {
			bad = f.bytes
			bad[item.at] ~= 0xff
			normalizedInspectTestError(t, bad[:f.size], {}, item.code, item.at)
		}
		bad = f.bytes
		position = f.policyAt+96
		normalizedInspectTestPutF32(bad[:], &position, transmute(f32)u32(0x7fc00000))
		normalizedInspectTestError(t, bad[:f.size], {}, .InvalidValue, f.policyAt+96)
		if useAdam {
			bad = f.bytes
			position = f.baseAt+144+9*4
			normalizedInspectTestPutF32(bad[:], &position, -1)
			normalizedInspectTestError(t, bad[:f.size], {}, .InvalidValue, f.baseAt+144+9*4)
		}
		// Remove one byte from the policy payload while preserving the following value payload.
		bad = f.bytes
		for i in f.valueAt-1..<f.size-1 { bad[i] = bad[i+1] }
		position = 16
		normalizedInspectTestPut64(bad[:], &position, u64(f.baseSize-1))
		position = f.baseAt+16
		normalizedInspectTestPut64(bad[:], &position, u64(f.valueAt-f.policyAt-1))
		normalizedInspectTestError(t, bad[:f.size-1], {}, .Truncated, f.valueAt-1)
		// A trailing byte within the policy is not confused with the value payload.
		bad = f.bytes
		for i := f.size; i > f.valueAt; i -= 1 { bad[i] = bad[i-1] }
		bad[f.valueAt] = 42
		position = 16
		normalizedInspectTestPut64(bad[:], &position, u64(f.baseSize+1))
		position = f.baseAt+16
		normalizedInspectTestPut64(bad[:], &position, u64(f.valueAt-f.policyAt+1))
		normalizedInspectTestError(t, bad[:f.size+1], {}, .TrailingData, f.valueAt)
		testing.expect(t, f.bytes == before)
	}
}

@(test)
PPOCheckpointInspectNormalizedLimits :: proc(t: ^testing.T) {
	f: NormalizedInspectTestFixture
	testing.expect(t, normalizedInspectTestFixture(&f, true, 2, 1))
	baseInfo, baseErr := PPOCheckpointInspect(f.bytes[f.baseAt:f.size])
	testing.expect(t, baseErr.code == .None)
	exact := PPONormalizedCheckpointInspectLimits{
		maxBytes = f.size, maxObservationWidth = 2,
		base = {maxBytes = f.baseSize, maxParameterPointers = 4, maxMomentElements = 9, maxEpochs = 3,
			policy = {maxBytes = f.valueAt-f.policyAt, maxLayers = 2, maxWidth = 3, maxBatchCapacity = 2, maxParameterPointers = 2, maxMomentElements = 6},
			value = {maxBytes = f.size-f.valueAt, maxLayers = 2, maxWidth = 3, maxBatchCapacity = 2, maxParameterPointers = 2, maxMomentElements = 3}},
	}
	info, err := PPOCheckpointInspectNormalized(f.bytes[:f.size], exact)
	testing.expect(t, err.code == .None && info.base == baseInfo)
	cases := []struct { limits: PPONormalizedCheckpointInspectLimits, offset: int }{
		{{maxBytes = f.size-1}, 0}, {{maxObservationWidth = 1}, f.observationAt+16},
		{{base = {maxBytes = f.baseSize-1}}, f.baseAt}, {{base = {maxEpochs = 2}}, f.baseAt+80},
		{{base = {maxMomentElements = 8}}, f.baseAt+136},
		{{base = {policy = {maxBytes = f.valueAt-f.policyAt-1}}}, f.policyAt},
		{{base = {value = {maxBytes = f.size-f.valueAt-1}}}, f.valueAt},
		{{base = {policy = {maxWidth = 2}}}, f.policyAt+24},
		{{base = {value = {maxWidth = 2}}}, f.valueAt+24},
		{{base = {maxParameterPointers = 2}}, f.valueAt+80},
	}
	for item in cases { normalizedInspectTestError(t, f.bytes[:f.size], item.limits, .LimitExceeded, item.offset) }
	// Every nested resource limit is passed through to the base inspector with
	// exactly the same error, translated into the outer input.
	baseLimits := []PPOCheckpointInspectLimits{
		{maxBytes = f.baseSize-1}, {maxParameterPointers = 2}, {maxMomentElements = 8}, {maxEpochs = 2},
		{policy = {maxBytes = f.valueAt-f.policyAt-1}}, {policy = {maxLayers = 1}}, {policy = {maxWidth = 2}},
		{policy = {maxBatchCapacity = 1}}, {policy = {maxParameterPointers = 1}}, {policy = {maxMomentElements = 5}},
		{value = {maxBytes = f.size-f.valueAt-1}}, {value = {maxLayers = 1}}, {value = {maxWidth = 2}},
		{value = {maxBatchCapacity = 1}}, {value = {maxParameterPointers = 1}}, {value = {maxMomentElements = 2}},
	}
	for item in baseLimits {
		_, baseLimitErr := PPOCheckpointInspect(f.bytes[f.baseAt:f.size], item)
		testing.expectf(t, baseLimitErr.code == .LimitExceeded, "base limit unexpectedly returned %v", baseLimitErr)
		normalizedInspectTestError(t, f.bytes[:f.size], {base = item}, baseLimitErr.code, f.baseAt+baseLimitErr.offset)
	}
	// The width limit is enforced as soon as the field is available, even on a truncated input.
	normalizedInspectTestError(t, f.bytes[:f.observationAt+24], {maxObservationWidth = 1}, .LimitExceeded, f.observationAt+16)
	negative := []PPONormalizedCheckpointInspectLimits{
		{maxBytes = -1}, {maxObservationWidth = -1}, {base = {maxBytes = -1}},
		{base = {maxParameterPointers = -1}}, {base = {maxMomentElements = -1}}, {base = {maxEpochs = -1}},
		{base = {policy = {maxBytes = -1}}}, {base = {policy = {maxLayers = -1}}},
		{base = {policy = {maxWidth = -1}}}, {base = {policy = {maxBatchCapacity = -1}}},
		{base = {policy = {maxParameterPointers = -1}}}, {base = {policy = {maxMomentElements = -1}}},
		{base = {value = {maxBytes = -1}}}, {base = {value = {maxLayers = -1}}},
		{base = {value = {maxWidth = -1}}}, {base = {value = {maxBatchCapacity = -1}}},
		{base = {value = {maxParameterPointers = -1}}}, {base = {value = {maxMomentElements = -1}}},
	}
	for item in negative {
		normalizedInspectTestError(t, nil, item, .InvalidLimits, 0)
		normalizedInspectTestError(t, f.bytes[:f.size], item, .InvalidLimits, 0)
	}
	absent: NormalizedInspectTestFixture
	testing.expect(t, normalizedInspectTestFixture(&absent, false, 0, 1))
	_, absentErr := PPOCheckpointInspectNormalized(absent.bytes[:absent.size], {maxObservationWidth = 2})
	testing.expect(t, absentErr.code == .None)
	normalizedInspectTestError(t, absent.bytes[:absent.size], {maxObservationWidth = 1}, .LimitExceeded, absent.policyAt+40)
	// Large encoded model capacities must not require model-sized storage or a probe.
	for at in ([2]int{f.policyAt+24, f.valueAt+24}) {
		position := at
		normalizedInspectTestPut64(f.bytes[:], &position, 65536)
	}
	before := f.bytes
	{
		context.allocator = mem.nil_allocator()
		info, err = PPOCheckpointInspectNormalized(f.bytes[:f.size])
	}
	testing.expect(t, err.code == .None && info.base.policy.maxWidth == 65536 && info.base.value.maxWidth == 65536 && f.bytes == before)
}

normalizedInspectTestMemoryEqual :: proc(address: rawptr, expected: []u8) -> bool {
	actual := mem.slice_ptr((^u8)(address), len(expected))
	for item, i in expected { if actual[i] != item { return false } }
	return true
}

@(test)
PPOCheckpointInspectNormalizedReaderAtomicity :: proc(t: ^testing.T) {
	for mode in 0..<7 {
		f: NormalizedInspectTestFixture
		target: NormalizedInspectTestTarget
		setup := normalizedInspectTestFixture(&f, true, 2, 1) && normalizedInspectTestTargetInit(&target)
		testing.expect(t, setup)
		if !setup { return }
		normalizers := PPOTrainingNormalizers{&target.observation, &target.reward}
		policy, value := &target.policy, &target.value
		parameters, first, second := target.parameters[:], target.first[:], target.second[:]
		switch mode {
		case 0:
			position := f.observationAt+40
			normalizedInspectTestPutF64(f.bytes[:], &position, transmute(f64)u64(0x7ff8000000000000))
		case 1: normalizers.observation = nil
		case 2: target.reward.mean = target.observation.mean[:1]
		case 3: second = first
		case 4: parameters = parameters[:3]
		case 5: value = policy
		case 6:
			target.observation.count = 2
			target.observation.mean = mem.slice_ptr((^f64)(rawptr(&f.bytes[f.observationAt+40])), 2)
			target.observation.m2 = mem.slice_ptr((^f64)(rawptr(&f.bytes[f.observationAt+56])), 2)
		}
		beforeInput := f.bytes
		beforeTarget: [size_of(NormalizedInspectTestTarget)]u8
		copy(beforeTarget[:], mem.slice_ptr((^u8)(rawptr(&target)), len(beforeTarget)))
		state, objective, fit, optimizer, loaded := PPOCheckpointReadNormalized(policy, value, f.bytes[:f.size],
			&target.adam, parameters, first, second, normalizers)
		testing.expectf(t, !loaded && state == (PPOTrainingState{}) && objective == (PPOConfig{}) && fit == (PPOFitConfig{}) &&
			optimizer == nil && f.bytes == beforeInput && normalizedInspectTestMemoryEqual(rawptr(&target), beforeTarget[:]), "atomic failure %d", mode)
	}
}

@(test)
PPOCheckpointInspectNormalizedReaderByteDifferential :: proc(t: ^testing.T) {
	accepted, rejected := 0, 0
	for useAdam in ([2]bool{false, true}) {
		f: NormalizedInspectTestFixture
		testing.expect(t, normalizedInspectTestFixture(&f, useAdam, 2, 1))
		for index in 0..<f.size {
			for bit in 0..<8 {
				f.bytes[index] ~= u8(1 << uint(bit))
				before := f.bytes
				info, err := PPOCheckpointInspectNormalized(f.bytes[:f.size])
				compatible := err.code == .None && info.base.policy.maxLayers == 2 && info.base.policy.maxWidth == 3 &&
					info.base.policy.batchCapacity == 2 && info.base.value.maxLayers == 2 && info.base.value.maxWidth == 3 &&
					info.base.value.batchCapacity == 2 && info.base.parameterPointers <= 8 && info.base.momentElements <= 16
				target: NormalizedInspectTestTarget
				if !normalizedInspectTestTargetInit(&target) { testing.expect(t, false); return }
				observation, reward := true, true
				adam := useAdam
				if err.code == .None {
					observation, reward = info.observation.present, info.reward.present
					adam = info.base.optimizer == .Adam
				}
				_, _, _, _, loaded := normalizedInspectTestRead(&target, f.bytes[:f.size], adam, observation, reward)
				if loaded != compatible || err.code != .None && info != (PPONormalizedCheckpointInfo{}) || f.bytes != before {
					testing.expectf(t, false, "byte differential adam=%v byte=%d bit=%d inspect=%v compatible=%v read=%v", useAdam, index, bit, err, compatible, loaded)
					return
				}
				if err.code == .None { accepted += 1 } else { rejected += 1 }
				f.bytes[index] ~= u8(1 << uint(bit))
			}
		}
	}
	testing.expect(t, accepted > 0 && rejected > 0)
}

@(test)
PPOCheckpointInspectNormalizedEarlyReadRejection :: proc(t: ^testing.T) {
	for mode in 0..<8 {
		f: NormalizedInspectTestFixture
		target: NormalizedInspectTestTarget
		setup := normalizedInspectTestFixture(&f, true, 2, 1) && normalizedInspectTestTargetInit(&target)
		testing.expect(t, setup)
		if !setup { return }
		position := f.policyAt+96
		normalizedInspectTestPutF32(f.bytes[:], &position, transmute(f32)u32(0x7fc00000))
		policy, value := &target.policy, &target.value
		normalizers := PPOTrainingNormalizers{&target.observation, &target.reward}
		parameters, first, second := target.parameters[:], target.first[:], target.second[:]
		preflight := ppoNormalizedCheckpointReadTarget{
			policy = rawptr(policy), policySize = size_of(Sequential(2, 3, 2)),
			value = rawptr(value), valueSize = size_of(Sequential(2, 3, 2)),
			adam = &target.adam, parameterStorage = parameters, firstMoment = first,
			secondMoment = second, normalizers = normalizers,
		}
		// A compatible target reaches the later corruption, making early rejection
		// observable without relying on timing or inaccessible memory.
		parsed, baseError := ppoCheckpointParseNormalized(f.bytes[:f.size], {}, &preflight)
		testing.expect(t, !parsed.targetRejected && baseError == (CheckpointError{.InvalidValue, f.policyAt+96}))
		switch mode {
		case 0: normalizers.observation = nil
		case 1: normalizers.reward = nil
		case 2:
			target.observation.mean = target.observationMean[:1]
			target.observation.m2 = target.observationM2[:1]
		case 3: target.observation.epsilon = 0
		case 4: value = policy
		case 5: second = first
		case 6: parameters = mem.slice_ptr((^^core.Node)(rawptr(&f.bytes[f.baseAt])), 4)
		case 7: policy = nil
		}
		preflight.policy, preflight.value = rawptr(policy), rawptr(value)
		preflight.parameterStorage, preflight.firstMoment, preflight.secondMoment = parameters, first, second
		preflight.normalizers = normalizers
		beforeInput := f.bytes
		beforeTarget: [size_of(NormalizedInspectTestTarget)]u8
		copy(beforeTarget[:], mem.slice_ptr((^u8)(rawptr(&target)), len(beforeTarget)))
		state: PPOTrainingState
		objective: PPOConfig
		fit: PPOFitConfig
		optimizer: SequentialOptimizer
		loaded: bool
		{
			context.allocator = mem.nil_allocator()
			parsed, baseError = ppoCheckpointParseNormalized(f.bytes[:f.size], {}, &preflight)
			state, objective, fit, optimizer, loaded = PPOCheckpointReadNormalized(
				policy, value, f.bytes[:f.size], &target.adam, parameters, first, second, normalizers,
			)
		}
		testing.expectf(t, parsed.targetRejected && baseError.code == .None && !loaded &&
			state == (PPOTrainingState{}) && objective == (PPOConfig{}) && fit == (PPOFitConfig{}) && optimizer == nil &&
			f.bytes == beforeInput && normalizedInspectTestMemoryEqual(rawptr(&target), beforeTarget[:]),
			"early target rejection %d: parsed=%v error=%v read=%v", mode, parsed.targetRejected, baseError, loaded)
	}
}

@(test)
PPOCheckpointInspectNormalizedAbsentWidthSpatial :: proc(t: ^testing.T) {
	policy, value: Sequential(3, 4, 2)
	setup := SequentialInitSpatial(&policy, 1, 2, 1, 17) && SequentialAddConv2D(&policy, 1, 1, 2) &&
		SequentialAddFlatten(&policy) && SequentialInitSpatial(&value, 1, 2, 1, 29) &&
		SequentialAddFlatten(&value) && SequentialAddDense(&value, 1)
	testing.expect(t, setup)
	if !setup { return }
	bytes, baseScratch, policyScratch, valueScratch: [4096]u8
	size, written := PPOCheckpointWriteNormalized(&policy, &value, SequentialSGD{0.025}, {5, 8, 17, 23},
		{0.2, 0.01, 0.5, 1.5}, {epochs = 3, batchSize = 2}, {},
		bytes[:], baseScratch[:], policyScratch[:], valueScratch[:])
	testing.expect(t, written)
	if !written { return }
	info, err := PPOCheckpointInspectNormalized(bytes[:size], {maxObservationWidth = 2})
	testing.expect(t, err.code == .None && info.base.policy.version == CHECKPOINT_SPATIAL_VERSION && info.base.policy.inputWidth == 2)
	policyAt := 40+116 // two absent normalizers and the SGD base header
	position := policyAt+80+24+16+40 // first convolution parameter
	normalizedInspectTestPutF32(bytes[:], &position, transmute(f32)u32(0x7fc00000))
	normalizedInspectTestError(t, bytes[:size], {maxObservationWidth = 1}, .LimitExceeded, policyAt+40)
	normalizedInspectTestError(t, bytes[:size], {maxObservationWidth = 2}, .InvalidValue, policyAt+80+24+16+40)
}

@(test)
PPOCheckpointInspectNormalizedPresentWidthEarlyLimit :: proc(t: ^testing.T) {
	for useAdam in ([2]bool{false, true}) {
		for rewardWidth in ([2]int{0, 1}) {
			f: NormalizedInspectTestFixture
			setup := normalizedInspectTestFixture(&f, useAdam, 1, rewardWidth)
			testing.expect(t, setup)
			if !setup { return }
			// The descriptor is within the limit, but the policy input width is 2.
			normalizedInspectTestError(t, f.bytes[:f.size], {}, .InvalidArchitecture, f.observationAt+16)
			normalizedInspectTestError(t, f.bytes[:f.size], {maxObservationWidth = 1}, .LimitExceeded, f.policyAt+40)
			bad := f.bytes
			position := f.policyAt+96
			normalizedInspectTestPutF32(bad[:], &position, transmute(f32)u32(0x7fc00000))
			before := bad
			info: PPONormalizedCheckpointInfo
			err: CheckpointError
			{
				context.allocator = mem.nil_allocator()
				info, err = PPOCheckpointInspectNormalized(bad[:f.size], {maxObservationWidth = 1})
			}
			testing.expectf(t, info == (PPONormalizedCheckpointInfo{}) && err == (CheckpointError{.LimitExceeded, f.policyAt+40}) && bad == before,
				"present observation adam=%v reward=%d: %v", useAdam, rewardWidth, err)
			normalizedInspectTestError(t, bad[:f.size], {maxObservationWidth = 2}, .InvalidValue, f.policyAt+96)
			normalizedInspectTestError(t, bad[:f.size], {maxObservationWidth = 1, base = {maxBytes = f.baseSize-1}}, .LimitExceeded, f.baseAt)
			normalizedInspectTestError(t, bad[:f.size], {maxObservationWidth = 1, base = {policy = {maxWidth = 2}}}, .LimitExceeded, f.policyAt+24)
			if useAdam {
				bad = f.bytes
				position = f.baseAt+144
				normalizedInspectTestPutF32(bad[:], &position, transmute(f32)u32(0x7fc00000))
				normalizedInspectTestError(t, bad[:f.size], {maxObservationWidth = 1}, .LimitExceeded, f.policyAt+40)
				normalizedInspectTestError(t, bad[:f.size], {maxObservationWidth = 2}, .InvalidValue, f.baseAt+144)
			}
		}
	}
}

@(test)
PPOCheckpointInspectNormalizedAbsentWidthEarlyLimit :: proc(t: ^testing.T) {
	for useAdam in ([2]bool{false, true}) {
		for rewardWidth in ([2]int{0, 1}) {
			f: NormalizedInspectTestFixture
			setup := normalizedInspectTestFixture(&f, useAdam, 0, rewardWidth)
			testing.expect(t, setup)
			if !setup { return }
			bad := f.bytes
			position := f.policyAt+96
			normalizedInspectTestPutF32(bad[:], &position, transmute(f32)u32(0x7fc00000))
			before := bad
			info: PPONormalizedCheckpointInfo
			err: CheckpointError
			{
				context.allocator = mem.nil_allocator()
				info, err = PPOCheckpointInspectNormalized(bad[:f.size], {maxObservationWidth = 1})
			}
			testing.expectf(t, info == (PPONormalizedCheckpointInfo{}) && err == (CheckpointError{.LimitExceeded, f.policyAt+40}) && bad == before,
				"absent observation adam=%v reward=%d: %v", useAdam, rewardWidth, err)
			normalizedInspectTestError(t, bad[:f.size], {}, .InvalidValue, f.policyAt+96)
			normalizedInspectTestError(t, bad[:f.size], {maxObservationWidth = 2}, .InvalidValue, f.policyAt+96)
			if useAdam {
				bad = f.bytes
				position = f.baseAt+144
				normalizedInspectTestPutF32(bad[:], &position, transmute(f32)u32(0x7fc00000))
				normalizedInspectTestError(t, bad[:f.size], {maxObservationWidth = 1}, .LimitExceeded, f.policyAt+40)
				normalizedInspectTestError(t, bad[:f.size], {maxObservationWidth = 2}, .InvalidValue, f.baseAt+144)
				normalizedInspectTestError(t, bad[:f.size], {maxObservationWidth = 1, base = {maxMomentElements = 8}}, .LimitExceeded, f.baseAt+136)
			}
			bad = f.bytes
			position = f.policyAt+96
			normalizedInspectTestPutF32(bad[:], &position, transmute(f32)u32(0x7fc00000))
			priority := []struct { limits: PPONormalizedCheckpointInspectLimits, code: CheckpointErrorCode, at: int }{
				{{maxObservationWidth = 1, maxBytes = f.size-1}, .LimitExceeded, 0},
				{{maxObservationWidth = 1, base = {maxBytes = f.baseSize-1}}, .LimitExceeded, f.baseAt},
				{{maxObservationWidth = 1, base = {maxEpochs = 2}}, .LimitExceeded, f.baseAt+80},
				{{maxObservationWidth = 1, base = {policy = {maxBytes = f.valueAt-f.policyAt-1}}}, .LimitExceeded, f.policyAt},
				{{maxObservationWidth = 1, base = {value = {maxBytes = f.size-f.valueAt-1}}}, .LimitExceeded, f.valueAt},
				{{maxObservationWidth = 1, base = {policy = {maxWidth = 2}}}, .LimitExceeded, f.policyAt+24},
				{{maxObservationWidth = 1, base = {policy = {maxLayers = -1}}}, .InvalidLimits, 0},
			}
			for item in priority { normalizedInspectTestError(t, bad[:f.size], item.limits, item.code, item.at) }
			bad = f.bytes
			bad[f.policyAt] ~= 0xff
			normalizedInspectTestError(t, bad[:f.size], {maxObservationWidth = 1}, .InvalidMagic, f.policyAt)
			bad = f.bytes
			position = f.baseAt+48
			normalizedInspectTestPut64(bad[:], &position, 0)
			normalizedInspectTestError(t, bad[:f.size], {maxObservationWidth = 1}, .InvalidHeader, f.baseAt+48)
			bad = f.bytes
			position = f.baseAt+16
			normalizedInspectTestPut64(bad[:], &position, max(u64))
			normalizedInspectTestError(t, bad[:f.size], {maxObservationWidth = 1}, .Overflow, f.baseAt+16)
			bad = f.bytes
			position = f.policyAt+24
			normalizedInspectTestPut64(bad[:], &position, u64(max(int)))
			position = f.policyAt+40
			normalizedInspectTestPut64(bad[:], &position, u64(max(int)))
			normalizedInspectTestError(t, bad[:f.size], {maxObservationWidth = 1}, .LimitExceeded, f.policyAt+40)
			position = f.policyAt+40
			normalizedInspectTestPut64(bad[:], &position, max(u64))
			normalizedInspectTestError(t, bad[:f.size], {maxObservationWidth = 1}, .InvalidHeader, f.policyAt+40)

			// The policy payload boundary, not the following value bytes, bounds the
			// header probe. A complete header can trigger the limit before its layer.
			for policySize in ([7]int{0, 39, 47, 48, 79, 80, 81}) {
				short := f.bytes
				valueSize := f.size-f.valueAt
				for i in 0..<valueSize { short[f.policyAt+policySize+i] = f.bytes[f.valueAt+i] }
				shortSize := f.policyAt+policySize+valueSize
				position = 16
				normalizedInspectTestPut64(short[:], &position, u64(shortSize-f.baseAt))
				position = f.baseAt+16
				normalizedInspectTestPut64(short[:], &position, u64(policySize))
				if policySize < 80 {
					normalizedInspectTestError(t, short[:shortSize], {maxObservationWidth = 1}, .Truncated, f.policyAt+policySize)
				} else {
					normalizedInspectTestError(t, short[:shortSize], {maxObservationWidth = 1}, .LimitExceeded, f.policyAt+40)
				}
			}
		}
	}
}
