package nn

import "../core"
import "core:mem"
import "core:testing"

// Deliberately encode the fixtures without either checkpoint writer.
ppoInspectTestPut64 :: proc(data: []u8, offset: ^int, value: u64) {
	for i in 0..<8 { data[offset^+i] = u8(value >> uint(8*i)) }
	offset^ += 8
}

ppoInspectTestPut32 :: proc(data: []u8, offset: ^int, value: f32) {
	bits := transmute(u32)value
	for i in 0..<4 { data[offset^+i] = u8(bits >> uint(8*i)) }
	offset^ += 4
}

ppoInspectTestModel :: proc(data: []u8, inputWidth, outputWidth: int, trainable, innerAdam: bool) -> int {
	offset := 0
	layers, hasAdam: u64
	if trainable { layers = 1 }
	if innerAdam { hasAdam = 1 }
	for item in ([10]u64{0x3154504b434e4e50, 1, 2, 3, 2, u64(inputWidth), layers, 19, 0, hasAdam}) {
		ppoInspectTestPut64(data, &offset, item)
	}
	elements := 0
	if trainable {
		ppoInspectTestPut64(data, &offset, 0)
		ppoInspectTestPut64(data, &offset, u64(outputWidth))
		elements = (inputWidth+1)*outputWidth
		for i in 0..<elements { ppoInspectTestPut32(data, &offset, f32(i+1)/10) }
	}
	if innerAdam {
		ppoInspectTestPut64(data, &offset, 1)
		for item in ([4]f32{0.01, 0.8, 0.99, 0.000001}) { ppoInspectTestPut32(data, &offset, item) }
		for _ in 0..<2*elements { ppoInspectTestPut32(data, &offset, 0) }
	}
	return offset
}

PPOInspectTestFixture :: struct {
	data: [2048]u8,
	size, policyOffset, policySize, valueOffset, valueSize: int,
}

ppoInspectTestAssemble :: proc(fixture: ^PPOInspectTestFixture, policy, value: []u8, adam: bool, count: int) {
	fixture^ = {}
	data := fixture.data[:]
	offset := 0
	for item in ([8]u64{0x3154504b43505050, 1, u64(len(policy)), u64(len(value)), 5, 8, 17, 0}) {
		ppoInspectTestPut64(data, &offset, item)
	}
	for item in ([4]f32{0.2, 0.01, 0.5, 1.5}) { ppoInspectTestPut32(data, &offset, item) }
	ppoInspectTestPut64(data, &offset, 3)
	ppoInspectTestPut64(data, &offset, 2)
	ppoInspectTestPut32(data, &offset, 0.5)
	ppoInspectTestPut32(data, &offset, 0.001)
	if adam {
		ppoInspectTestPut64(data, &offset, 1)
		ppoInspectTestPut64(data, &offset, 11)
		for item in ([4]f32{0.01, 0.8, 0.99, 0.000001}) { ppoInspectTestPut32(data, &offset, item) }
		ppoInspectTestPut64(data, &offset, u64(count))
		for i in 0..<count { ppoInspectTestPut32(data, &offset, f32(i)-2) }
		for i in 0..<count { ppoInspectTestPut32(data, &offset, f32(i)/2) }
	} else {
		ppoInspectTestPut64(data, &offset, 0)
		ppoInspectTestPut32(data, &offset, 0.025)
	}
	fixture.policyOffset, fixture.policySize = offset, len(policy)
	copy(data[offset:offset+len(policy)], policy); offset += len(policy)
	fixture.valueOffset, fixture.valueSize = offset, len(value)
	copy(data[offset:offset+len(value)], value); offset += len(value)
	fixture.size = offset
}

ppoInspectTestFixture :: proc(adam: bool, count: int = 6) -> PPOInspectTestFixture {
	policy, value: [512]u8
	policySize := ppoInspectTestModel(policy[:], 1, 2, true, false)
	valueSize := ppoInspectTestModel(value[:], 1, 1, true, false)
	fixture: PPOInspectTestFixture
	ppoInspectTestAssemble(&fixture, policy[:policySize], value[:valueSize], adam, count)
	return fixture
}

ppoInspectTestError :: proc(t: ^testing.T, data: []u8, limits: PPOCheckpointInspectLimits, code: CheckpointErrorCode, offset: int) {
	info, err := PPOCheckpointInspect(data, limits)
	testing.expectf(t, info == (PPOCheckpointInfo{}) && err.code == code && err.offset == offset,
		"expected %v at %d, got %v at %d (zero info %v)", code, offset, err.code, err.offset, info == (PPOCheckpointInfo{}))
}

@(test)
PPOCheckpointInspectHandEncodedAndNilAllocator :: proc(t: ^testing.T) {
	for adam in ([2]bool{false, true}) {
		fixture := ppoInspectTestFixture(adam)
		before := fixture.data
		policy, value: Sequential(2, 3, 2)
		parameters: [4]^core.Node
		first, second: [6]f32
		target: Adam
		info, badInfo: PPOCheckpointInfo
		err, badErr: CheckpointError
		state: PPOTrainingState
		objective: PPOConfig
		fit: PPOFitConfig
		optimizer: SequentialOptimizer
		loaded: bool
		{
			context.allocator = mem.nil_allocator()
			info, err = PPOCheckpointInspect(fixture.data[:fixture.size])
			badInfo, badErr = PPOCheckpointInspect(fixture.data[:fixture.size-1])
			if adam {
				state, objective, fit, optimizer, loaded = PPOCheckpointRead(&policy, &value, fixture.data[:fixture.size], &target, parameters[:], first[:], second[:])
			} else {
				state, objective, fit, optimizer, loaded = PPOCheckpointRead(&policy, &value, fixture.data[:fixture.size], nil, nil, nil, nil)
			}
		}
		testing.expectf(t, err.code == .None && loaded, "hand encoded adam=%v: %v", adam, err)
		if err.code != .None || !loaded { continue }
		testing.expect(t, badInfo == (PPOCheckpointInfo{}) && badErr.code == .Truncated && badErr.offset == fixture.size-1)
		testing.expect(t, fixture.data == before)
		testing.expect(t, info.policy == (CheckpointInfo{1, 2, 3, 2, 1, 1, false, 2, 4, 2, 2}))
		testing.expect(t, info.value == (CheckpointInfo{1, 2, 3, 2, 1, 1, false, 2, 2, 1, 2}))
		testing.expect(t, info.parameterPointers == 4 && info.momentElements == 6)
		testing.expect(t, state == (PPOTrainingState{5, 8, 17, 0}) && info.state == state)
		testing.expect(t, objective == (PPOConfig{0.2, 0.01, 0.5, 1.5}) && info.objective == objective)
		testing.expect(t, fit == (PPOFitConfig{3, 2, 0.5, 0.001}) && info.fit == fit)
		if adam {
			_, isAdam := optimizer.(^Adam)
			testing.expect(t, isAdam && info.optimizer == .Adam && info.step == 11 && target.step == info.step)
			testing.expect(t, info.learningRate == 0.01 && info.beta1 == 0.8 && info.beta2 == 0.99 && info.epsilon == 0.000001)
			testing.expect(t, target.learningRate == info.learningRate && target.beta1 == info.beta1 && target.beta2 == info.beta2 && target.epsilon == info.epsilon)
			testing.expect(t, first == ([6]f32{-2, -1, 0, 1, 2, 3}) && second == ([6]f32{0, 0.5, 1, 1.5, 2, 2.5}))
			policyStorage, valueStorage: [2]^core.Node
			policyPointers, policyOk := SequentialParameters(&policy, policyStorage[:])
			valuePointers, valueOk := SequentialParameters(&value, valueStorage[:])
			testing.expect(t, policyOk && valueOk && target.parameters[0] == policyPointers[0] && target.parameters[1] == policyPointers[1] &&
				target.parameters[2] == valuePointers[0] && target.parameters[3] == valuePointers[1])
		} else {
			sgd, isSGD := optimizer.(SequentialSGD)
			testing.expect(t, isSGD && info.optimizer == .SGD && sgd.learningRate == 0.025 && info.learningRate == sgd.learningRate)
			testing.expect(t, info.beta1 == 0 && info.beta2 == 0 && info.epsilon == 0 && info.step == 0)
		}
	}
}

@(test)
PPOCheckpointInspectMalformedOffsets :: proc(t: ^testing.T) {
	fixture := ppoInspectTestFixture(false)
	p, v := fixture.policyOffset, fixture.valueOffset
	integerCases := []struct { at: int, value: u64, code: CheckpointErrorCode, errorAt: int }{
		{0, 0, .InvalidMagic, 0}, {8, 2, .UnsupportedVersion, 8},
		{16, max(u64), .Overflow, 16}, {24, max(u64), .Overflow, 24},
		{16, u64(max(int)), .Overflow, 24}, {48, 0, .InvalidHeader, 48},
		{80, 0, .InvalidValue, 80}, {80, max(u64), .Overflow, 80},
		{88, max(u64), .Overflow, 88}, {88, 3, .InvalidValue, 88}, {104, 2, .InvalidHeader, 104},
		{p, 0, .InvalidMagic, p}, {p+8, 3, .UnsupportedVersion, p+8},
		{p+16, 0, .InvalidHeader, p+16}, {p+24, 0, .InvalidHeader, p+24},
		{p+32, 0, .InvalidHeader, p+32}, {p+40, 0, .InvalidHeader, p+40},
		{p+48, 3, .InvalidHeader, p+48}, {p+56, 0, .InvalidHeader, p+56},
		{p+72, 2, .InvalidHeader, p+72}, {p+80, 10, .UnsupportedLayer, p+80},
		{p+88, 0, .InvalidArchitecture, p+88}, {v, 0, .InvalidMagic, v},
		{v+80, 10, .UnsupportedLayer, v+80}, {v+88, 0, .InvalidArchitecture, v+88},
	}
	for item in integerCases {
		bad := fixture.data
		position := item.at
		ppoInspectTestPut64(bad[:], &position, item.value)
		ppoInspectTestError(t, bad[:fixture.size], {}, item.code, item.errorAt)
	}
	nan := transmute(f32)u32(0x7fc00000)
	inf := transmute(f32)u32(0x7f800000)
	floatCases := []struct { at: int, value: f32 }{
		{64, nan}, {64, 1}, {68, -1}, {68, inf}, {72, -1}, {72, nan},
		{76, 0}, {76, inf}, {96, -1}, {96, nan}, {100, -1}, {100, inf},
		{112, 0}, {112, inf}, {p+96, nan}, {v+96, inf},
	}
	for item in floatCases {
		bad := fixture.data
		position := item.at
		ppoInspectTestPut32(bad[:], &position, item.value)
		ppoInspectTestError(t, bad[:fixture.size], {}, .InvalidValue, item.at)
	}
	bad := fixture.data
	bad[fixture.size] = 123
	ppoInspectTestError(t, bad[:fixture.size+1], {}, .TrailingData, fixture.size)

	adam := ppoInspectTestFixture(true)
	integerAdam := []struct { at: int, value: u64, code: CheckpointErrorCode }{
		{112, max(u64), .InvalidValue}, {136, max(u64), .Overflow},
		{136, u64(max(int)/8), .Overflow},
	}
	for item in integerAdam {
		bad = adam.data
		position := item.at
		ppoInspectTestPut64(bad[:], &position, item.value)
		ppoInspectTestError(t, bad[:adam.size], {}, item.code, item.at)
	}
	floatAdam := []struct { at: int, value: f32 }{
		{120, 0}, {120, nan}, {124, -1}, {124, 1}, {124, nan},
		{128, -1}, {128, 1}, {128, inf}, {132, 0}, {132, nan},
		{144, nan}, {148, inf}, {168, -1}, {172, nan}, {176, inf},
	}
	for item in floatAdam {
		bad = adam.data
		position := item.at
		ppoInspectTestPut32(bad[:], &position, item.value)
		ppoInspectTestError(t, bad[:adam.size], {}, .InvalidValue, item.at)
	}
	for count in ([3]int{0, 5, 7}) {
		mismatch := ppoInspectTestFixture(true, count)
		ppoInspectTestError(t, mismatch.data[:mismatch.size], {}, .InvalidArchitecture, 136)
	}
}

@(test)
PPOCheckpointInspectTruncationAndNestedOffsets :: proc(t: ^testing.T) {
	for adam in ([2]bool{false, true}) {
		fixture := ppoInspectTestFixture(adam)
		for cut in 0..<fixture.size {
			ppoInspectTestError(t, fixture.data[:cut], {}, .Truncated, cut)
		}
	}
	policy, value: [512]u8
	pSize := ppoInspectTestModel(policy[:], 1, 2, true, false)
	vSize := ppoInspectTestModel(value[:], 1, 1, true, false)
	fixture: PPOInspectTestFixture
	// The outer envelope is complete even though one declared nested payload is not.
	ppoInspectTestAssemble(&fixture, policy[:pSize-1], value[:vSize], false, 0)
	ppoInspectTestError(t, fixture.data[:fixture.size], {}, .Truncated, fixture.valueOffset)
	ppoInspectTestAssemble(&fixture, policy[:pSize], value[:vSize-1], false, 0)
	ppoInspectTestError(t, fixture.data[:fixture.size], {}, .Truncated, fixture.size)
	// A complete but too-short nested header must also report its own absolute end.
	ppoInspectTestAssemble(&fixture, policy[:23], value[:vSize], false, 0)
	ppoInspectTestError(t, fixture.data[:fixture.size], {}, .Truncated, fixture.valueOffset)
	// Nested trailing bytes retain the nested parser's offset, translated to input.
	policy[pSize] = 0
	ppoInspectTestAssemble(&fixture, policy[:pSize+1], value[:vSize], false, 0)
	ppoInspectTestError(t, fixture.data[:fixture.size], {}, .TrailingData, fixture.policyOffset+pSize)
	value[vSize] = 0
	ppoInspectTestAssemble(&fixture, policy[:pSize], value[:vSize+1], false, 0)
	ppoInspectTestError(t, fixture.data[:fixture.size], {}, .TrailingData, fixture.valueOffset+vSize)
	// The nested dimension multiplication overflows before any parameter scan.
	position := 24
	ppoInspectTestPut64(policy[:], &position, u64(max(int)))
	position = 40
	ppoInspectTestPut64(policy[:], &position, 2)
	position = 88
	ppoInspectTestPut64(policy[:], &position, u64(max(int)))
	ppoInspectTestAssemble(&fixture, policy[:96], value[:vSize], false, 0)
	ppoInspectTestError(t, fixture.data[:fixture.size], {}, .Overflow, fixture.policyOffset+88)
	pSize = ppoInspectTestModel(policy[:], 1, 2, true, false)
	position = 24
	ppoInspectTestPut64(value[:], &position, u64(max(int)))
	position = 40
	ppoInspectTestPut64(value[:], &position, 2)
	position = 88
	ppoInspectTestPut64(value[:], &position, u64(max(int)))
	ppoInspectTestAssemble(&fixture, policy[:pSize], value[:96], false, 0)
	ppoInspectTestError(t, fixture.data[:fixture.size], {}, .Overflow, fixture.valueOffset+88)
}

@(test)
PPOCheckpointInspectLimitPolicies :: proc(t: ^testing.T) {
	fixture := ppoInspectTestFixture(false)
	p, v := fixture.policyOffset, fixture.valueOffset
	exact := PPOCheckpointInspectLimits{
		maxBytes = fixture.size, maxParameterPointers = 4, maxMomentElements = 6, maxEpochs = 3,
		policy = {fixture.policySize, 2, 3, 2, 2, 4}, value = {fixture.valueSize, 2, 3, 2, 2, 2},
	}
	info, err := PPOCheckpointInspect(fixture.data[:fixture.size], exact)
	testing.expect(t, err.code == .None && info.parameterPointers == 4 && info.momentElements == 6)
	cases := []struct { limits: PPOCheckpointInspectLimits, offset: int }{
		{{maxBytes = fixture.size-1}, 0}, {{maxEpochs = 2}, 80},
		{{maxParameterPointers = 1}, p+80}, {{maxParameterPointers = 2}, v+80},
		{{maxParameterPointers = 3}, v+80}, {{maxMomentElements = 3}, p+80},
		{{maxMomentElements = 4}, v+80}, {{maxMomentElements = 5}, v+80},
		{{policy = {maxBytes = fixture.policySize-1}}, p}, {{policy = {maxLayers = 1}}, p+16},
		{{policy = {maxWidth = 2}}, p+24}, {{policy = {maxBatchCapacity = 1}}, p+32},
		{{policy = {maxParameterPointers = 1}}, p+80}, {{policy = {maxMomentElements = 3}}, p+80},
		{{value = {maxBytes = fixture.valueSize-1}}, v}, {{value = {maxLayers = 1}}, v+16},
		{{value = {maxWidth = 2}}, v+24}, {{value = {maxBatchCapacity = 1}}, v+32},
		{{value = {maxParameterPointers = 1}}, v+80}, {{value = {maxMomentElements = 1}}, v+80},
	}
	for item in cases { ppoInspectTestError(t, fixture.data[:fixture.size], item.limits, .LimitExceeded, item.offset) }
	negative := []PPOCheckpointInspectLimits{
		{maxBytes = -1}, {maxParameterPointers = -1}, {maxMomentElements = -1}, {maxEpochs = -1},
		{policy = {maxBytes = -1}}, {policy = {maxLayers = -1}}, {policy = {maxWidth = -1}},
		{policy = {maxBatchCapacity = -1}}, {policy = {maxParameterPointers = -1}}, {policy = {maxMomentElements = -1}},
		{value = {maxBytes = -1}}, {value = {maxLayers = -1}}, {value = {maxWidth = -1}},
		{value = {maxBatchCapacity = -1}}, {value = {maxParameterPointers = -1}}, {value = {maxMomentElements = -1}},
	}
	for item in negative { ppoInspectTestError(t, nil, item, .InvalidLimits, 0) }

	adam := ppoInspectTestFixture(true)
	ppoInspectTestError(t, adam.data[:144], {maxMomentElements = 5}, .LimitExceeded, 136)
	ppoInspectTestError(t, adam.data[:88], {maxEpochs = 2}, .LimitExceeded, 80)
	// Even an incomplete parameter payload hits its structural limit before scanning.
	policy, value: [512]u8
	pSize := ppoInspectTestModel(policy[:], 1, 2, true, false)
	vSize := ppoInspectTestModel(value[:], 1, 1, true, false)
	short: PPOInspectTestFixture
	ppoInspectTestAssemble(&short, policy[:96], value[:vSize], false, 0)
	ppoInspectTestError(t, short.data[:short.size], {maxMomentElements = 3}, .LimitExceeded, short.policyOffset+80)
	ppoInspectTestAssemble(&short, policy[:pSize], value[:96], false, 0)
	ppoInspectTestError(t, short.data[:short.size], {maxParameterPointers = 2}, .LimitExceeded, short.valueOffset+80)
	ppoInspectTestError(t, short.data[:short.size], {maxMomentElements = 4}, .LimitExceeded, short.valueOffset+80)
	// Both nested byte sizes are known before scanning either parameter payload.
	position := short.policyOffset+96
	ppoInspectTestPut32(short.data[:], &position, transmute(f32)u32(0x7fc00000))
	ppoInspectTestError(t, short.data[:short.size], {value = {maxBytes = 95}}, .LimitExceeded, short.valueOffset)
}

// Probe the reconstructed models rather than the PPO inspector's topology data.
ppoInspectTestProbe :: proc(policyInput, valueInput: []u8) -> bool {
	policy, value: Sequential(6, 4, 2)
	policyState, valueState: u64
	if !CheckpointRead(&policy, nil, &policyState, policyInput, nil, nil, nil) ||
		!CheckpointRead(&value, nil, &valueState, valueInput, nil, nil, nil) { return false }
	parameters: [24]^core.Node
	_, _, ok := PPOCheckpointCombinedParameters(&policy, &value, parameters[:])
	return ok
}

@(test)
PPOCheckpointInspectTopologyDifferential :: proc(t: ^testing.T) {
	for mode in 0..<15 {
		policy, value: Sequential(6, 4, 2)
		setup := SequentialInit(&policy, 1, 7) && SequentialInit(&value, 1, 11)
		if mode == 9 || mode == 10 { setup = setup && SequentialInitSpatial(&policy, 1, 1, 1, 7) }
		if mode == 11 || mode == 12 { setup = setup && SequentialInitSpatial(&value, 1, 1, 1, 11) }
		if mode == 13 { setup = setup && SequentialInit(&value, 2, 11) }
		switch mode {
		case 7: setup = setup && SequentialAddFlatten(&policy)
		case 9, 10:
			setup = setup && SequentialAddConv2D(&policy, 1, 1, 2)
			if mode == 10 { setup = setup && SequentialAddFlatten(&policy) }
		case: setup = setup && SequentialAddDense(&policy, 2)
		}
		switch mode {
		case 1: setup = setup && SequentialAddActivation(&policy, .Softmax)
		case 2: setup = setup && SequentialAddActivation(&policy, .Softmax) && SequentialAddDropout(&policy)
		case 3:
			setup = setup && SequentialAddActivation(&policy, .Softmax) && SequentialAddDropout(&policy) &&
				SequentialAddFlatten(&policy) && SequentialAddDropout(&policy)
		case 4:
			setup = setup && SequentialAddActivation(&policy, .Softmax) && SequentialAddFlatten(&policy) &&
				SequentialAddActivation(&policy, .Tanh) && SequentialAddDropout(&policy)
		case 5: setup = setup && SequentialAddActivation(&policy, .Softmax) && SequentialAddDense(&policy, 2)
		}
		switch mode {
		case 8: setup = setup && SequentialAddFlatten(&value)
		case 11, 12:
			setup = setup && SequentialAddConv2D(&value, 1, 1, 1)
			if mode == 12 { setup = setup && SequentialAddFlatten(&value) }
		case 14: setup = setup && SequentialAddDense(&value, 2)
		case: setup = setup && SequentialAddDense(&value, 1)
		}
		if mode == 6 { setup = setup && SequentialAddActivation(&value, .Softmax) }
		testing.expectf(t, setup, "topology setup %d", mode)
		if !setup { return }
		policyData, valueData: [1024]u8
		pSize, pOk := CheckpointWrite(&policy, nil, 0, policyData[:])
		vSize, vOk := CheckpointWrite(&value, nil, 0, valueData[:])
		testing.expectf(t, pOk && vOk, "topology encode %d", mode)
		if !pOk || !vOk { return }
		fixture: PPOInspectTestFixture
		ppoInspectTestAssemble(&fixture, policyData[:pSize], valueData[:vSize], false, 0)
		expected := ppoInspectTestProbe(policyData[:pSize], valueData[:vSize])
		known := mode == 0 || mode == 4 || mode == 5 || mode == 6 || mode == 10 || mode == 12
		info, err := PPOCheckpointInspect(fixture.data[:fixture.size])
		restoredPolicy, restoredValue: Sequential(6, 4, 2)
		_, _, _, _, loaded := PPOCheckpointRead(&restoredPolicy, &restoredValue, fixture.data[:fixture.size], nil, nil, nil, nil)
		testing.expectf(t, expected == known && (err.code == .None) == expected && loaded == expected,
			"topology %d: probe %v, inspector %v, read %v", mode, expected, err, loaded)
		if !expected { testing.expect(t, info == (PPOCheckpointInfo{})) }
	}
	// A valid nested supervised checkpoint with its own Adam is not a PPO model payload.
	policy, value: [512]u8
	pSize := ppoInspectTestModel(policy[:], 1, 2, true, true)
	vSize := ppoInspectTestModel(value[:], 1, 1, true, false)
	fixture: PPOInspectTestFixture
	ppoInspectTestAssemble(&fixture, policy[:pSize], value[:vSize], false, 0)
	ppoInspectTestError(t, fixture.data[:fixture.size], {}, .InvalidArchitecture, fixture.policyOffset+72)
	pSize = ppoInspectTestModel(policy[:], 1, 2, true, false)
	vSize = ppoInspectTestModel(value[:], 1, 1, true, true)
	ppoInspectTestAssemble(&fixture, policy[:pSize], value[:vSize], false, 0)
	ppoInspectTestError(t, fixture.data[:fixture.size], {}, .InvalidArchitecture, fixture.valueOffset+72)
	// Valid nested model with a different input width: report the value header field.
	vSize = ppoInspectTestModel(value[:], 2, 1, true, false)
	ppoInspectTestAssemble(&fixture, policy[:pSize], value[:vSize], false, 0)
	ppoInspectTestError(t, fixture.data[:fixture.size], {}, .InvalidArchitecture, fixture.valueOffset+40)
}

@(test)
PPOCheckpointInspectByteDifferential :: proc(t: ^testing.T) {
	accepted, rejected := 0, 0
	for adam in ([2]bool{false, true}) {
		fixture := ppoInspectTestFixture(adam)
		for index in 0..<fixture.size {
			for bit in 0..<8 {
				fixture.data[index] ~= u8(1 << uint(bit))
				info, err := PPOCheckpointInspect(fixture.data[:fixture.size])
				policy, value: Sequential(2, 3, 2)
				_, _, _, _, sgdRead := PPOCheckpointRead(&policy, &value, fixture.data[:fixture.size], nil, nil, nil, nil)
				parameters: [32]^core.Node
				first, second: [256]f32
				target: Adam
				_, _, _, _, adamRead := PPOCheckpointRead(&policy, &value, fixture.data[:fixture.size], &target, parameters[:], first[:], second[:])
				compatible := err.code == .None && info.policy.maxLayers == 2 && info.policy.maxWidth == 3 && info.policy.batchCapacity == 2 &&
					info.value.maxLayers == 2 && info.value.maxWidth == 3 && info.value.batchCapacity == 2 &&
					info.parameterPointers <= len(parameters) && info.momentElements <= len(first)
				matches := !sgdRead && !adamRead
				if compatible {
					if info.optimizer == .SGD { matches = sgdRead && !adamRead } else { matches = adamRead && !sgdRead }
				}
				if err.code != .None && info != (PPOCheckpointInfo{}) { matches = false }
				if !matches {
					testing.expectf(t, false, "byte differential adam=%v byte=%d bit=%d inspect=%v sgd=%v adamRead=%v", adam, index, bit, err, sgdRead, adamRead)
					return
				}
				if err.code == .None { accepted += 1 } else { rejected += 1 }
				fixture.data[index] ~= u8(1 << uint(bit))
			}
		}
	}
	testing.expect(t, accepted > 0 && rejected > 0)
}

@(test)
PPOCheckpointInspectIndependentCapacities :: proc(t: ^testing.T) {
	policy: Sequential(2, 4, 3)
	value: Sequential(3, 5, 2)
	setup := SequentialInit(&policy, 2, 7) && SequentialAddDense(&policy, 2) &&
		SequentialInit(&value, 2, 11) && SequentialAddDense(&value, 1)
	testing.expect(t, setup)
	if !setup { return }
	data, policyScratch, valueScratch: [2048]u8
	size, written := PPOCheckpointWrite(&policy, &value, SequentialSGD{0.01}, PPOTrainingState{policyRandomState = 17},
		PPOConfig{0.2, 0.01, 0.5, 1}, PPOFitConfig{epochs = 3, batchSize = 2}, data[:], policyScratch[:], valueScratch[:])
	testing.expect(t, written)
	if !written { return }
	info, err := PPOCheckpointInspect(data[:size])
	testing.expect(t, err.code == .None && info.policy.maxLayers == 2 && info.policy.maxWidth == 4 && info.policy.batchCapacity == 3 &&
		info.value.maxLayers == 3 && info.value.maxWidth == 5 && info.value.batchCapacity == 2 &&
		info.parameterPointers == 4 && info.momentElements == 9)
	restoredPolicy: Sequential(2, 4, 3)
	restoredValue: Sequential(3, 5, 2)
	_, _, _, _, loaded := PPOCheckpointRead(&restoredPolicy, &restoredValue, data[:size], nil, nil, nil, nil)
	testing.expect(t, loaded)
	wrongPolicy: Sequential(3, 4, 3)
	wrongValue: Sequential(3, 5, 3)
	_, _, _, _, badPolicy := PPOCheckpointRead(&wrongPolicy, &restoredValue, data[:size], nil, nil, nil, nil)
	_, _, _, _, badValue := PPOCheckpointRead(&restoredPolicy, &wrongValue, data[:size], nil, nil, nil, nil)
	testing.expect(t, !badPolicy && !badValue && wrongPolicy.self == nil && wrongValue.self == nil)
	bad := data
	position := 88
	ppoInspectTestPut64(bad[:], &position, 3)
	ppoInspectTestError(t, bad[:size], {}, .InvalidValue, 88)
	position = 88
	ppoInspectTestPut64(bad[:], &position, 0)
	zeroBatch, zeroErr := PPOCheckpointInspect(bad[:size])
	testing.expect(t, zeroErr.code == .None && zeroBatch.fit.batchSize == 0)
}

@(test)
PPOCheckpointInspectLargeEncodedCapacities :: proc(t: ^testing.T) {
	fixture := ppoInspectTestFixture(false)
	for base in ([2]int{fixture.policyOffset, fixture.valueOffset}) {
		position := base+24
		ppoInspectTestPut64(fixture.data[:], &position, 65536)
	}
	before := fixture.data
	info: PPOCheckpointInfo
	err: CheckpointError
	{
		context.allocator = mem.nil_allocator()
		info, err = PPOCheckpointInspect(fixture.data[:fixture.size])
	}
	testing.expect(t, err.code == .None && info.policy.maxWidth == 65536 && info.value.maxWidth == 65536 &&
		info.parameterPointers == 4 && info.momentElements == 6 && fixture.data == before)
	ppoInspectTestError(t, fixture.data[:fixture.size], {policy = {maxWidth = 1024}}, .LimitExceeded, fixture.policyOffset+24)
	ppoInspectTestError(t, fixture.data[:fixture.size], {value = {maxWidth = 1024}}, .LimitExceeded, fixture.valueOffset+24)
}

ppoInspectTestMemoryEqual :: proc(address: rawptr, expected: []u8) -> bool {
	actual := mem.slice_ptr((^u8)(address), len(expected))
	for item, index in expected { if actual[index] != item { return false } }
	return true
}

@(test)
PPOCheckpointInspectStorageAndAtomicity :: proc(t: ^testing.T) {
	fixture := ppoInspectTestFixture(true)
	policy, value: Sequential(2, 3, 2)
	setup := SequentialInit(&policy, 1, 31) && SequentialAddDense(&policy, 2) &&
		SequentialInit(&value, 1, 37) && SequentialAddDense(&value, 1)
	testing.expect(t, setup)
	if !setup { return }
	for mode in 0..<8 {
		parameters: [4]^core.Node
		first, second: [6]f32
		for &item in first { item = 7 }
		for &item in second { item = 9 }
		target := Adam{step = 77, learningRate = 0.25}
		parameterView, firstView, secondView, adamView := parameters[:], first[:], second[:], &target
		switch mode {
		case 0: adamView = nil
		case 1: parameterView = parameters[:3]
		case 2: firstView = first[:5]
		case 3: secondView = second[:5]
		case 4: secondView = first[:]
		case 5: firstView = mem.slice_ptr((^f32)(rawptr(&policy)), 6)
		case 6: parameterView = mem.slice_ptr((^^core.Node)(rawptr(raw_data(fixture.data[:]))), 4)
		case 7: adamView = (^Adam)(rawptr(&value))
		}
		policyBefore, valueBefore: [size_of(Sequential(2, 3, 2))]u8
		adamBefore: [size_of(Adam)]u8
		copy(policyBefore[:], mem.slice_ptr((^u8)(rawptr(&policy)), len(policyBefore)))
		copy(valueBefore[:], mem.slice_ptr((^u8)(rawptr(&value)), len(valueBefore)))
		copy(adamBefore[:], mem.slice_ptr((^u8)(rawptr(&target)), len(adamBefore)))
		parametersBefore, firstBefore, secondBefore, inputBefore := parameters, first, second, fixture.data
		state, objective, fit, optimizer, loaded := PPOCheckpointRead(&policy, &value, fixture.data[:fixture.size], adamView, parameterView, firstView, secondView)
		testing.expectf(t, !loaded && state == (PPOTrainingState{}) && objective == (PPOConfig{}) && fit == (PPOFitConfig{}) && optimizer == nil &&
			ppoInspectTestMemoryEqual(rawptr(&policy), policyBefore[:]) && ppoInspectTestMemoryEqual(rawptr(&value), valueBefore[:]) &&
			ppoInspectTestMemoryEqual(rawptr(&target), adamBefore[:]) && parameters == parametersBefore && first == firstBefore &&
			second == secondBefore && fixture.data == inputBefore, "atomic storage failure %d", mode)
	}
	// SGD accepts no Adam or optimizer storage, even when the structural counts are nonzero.
	sgd := ppoInspectTestFixture(false)
	parameters: [4]^core.Node
	first, second: [6]f32
	target: Adam
	_, _, _, _, withAdam := PPOCheckpointRead(&policy, &value, sgd.data[:sgd.size], &target, nil, nil, nil)
	_, _, _, _, withPointers := PPOCheckpointRead(&policy, &value, sgd.data[:sgd.size], nil, parameters[:], nil, nil)
	_, _, _, _, withFirst := PPOCheckpointRead(&policy, &value, sgd.data[:sgd.size], nil, nil, first[:], nil)
	_, _, _, _, withSecond := PPOCheckpointRead(&policy, &value, sgd.data[:sgd.size], nil, nil, nil, second[:])
	_, _, _, _, withoutStorage := PPOCheckpointRead(&policy, &value, sgd.data[:sgd.size], nil, nil, nil, nil)
	testing.expect(t, !withAdam && !withPointers && !withFirst && !withSecond && withoutStorage)
}
