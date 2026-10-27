package nn

import "../core"
import "core:testing"

CheckpointTestModel :: proc(model: ^Sequential(6, 3, 2)) -> bool {
	return SequentialInit(model, 2, 123) &&
		SequentialAddDense(model, 3) && SequentialAddActivation(model, .Relu) &&
		SequentialAddDense(model, 2) && SequentialAddActivation(model, .Sigmoid) &&
		SequentialAddActivation(model, .Tanh) && SequentialAddActivation(model, .Softmax)
}

@(test)
CheckpointRoundTripAdam :: proc(t: ^testing.T) {
	source, restored: Sequential(6, 3, 2)
	testing.expect(t, CheckpointTestModel(&source))
	parameters, restoredParameters: [4]^core.Node
	params, ok := SequentialParameters(&source, parameters[:])
	testing.expect(t, ok)
	first, second, restoredFirst, restoredSecond: [17]f32
	for i in 0..<17 { first[i] = f32(i-8) * 0.125; second[i] = f32(i+1) * 0.25 }
	adam := Adam{params, first[:], second[:], 987, 0.02, 0.8, 0.95, 0.0001}
	data, again: [1024]u8
	size, written := CheckpointWrite(&source, &adam, 0x123456789abcdef0, data[:])
	testing.expect(t, written && size > 0)
	if !written { return }
	shuffle: u64
	restoredAdam: Adam
	ok = CheckpointRead(&restored, &restoredAdam, &shuffle, data[:size], restoredParameters[:], restoredFirst[:], restoredSecond[:])
	testing.expect(t, ok)
	if !ok { return }
	testing.expect(t, shuffle == 0x123456789abcdef0 && restored.randomState == source.randomState)
	testing.expect(t, restored.inputWidth == 2 && restored.layerCount == 6 && restored.self == rawptr(&restored))
	testing.expect(t, restoredAdam.step == 987 && restoredAdam.learningRate == adam.learningRate && restoredAdam.beta1 == adam.beta1 && restoredAdam.beta2 == adam.beta2 && restoredAdam.epsilon == adam.epsilon)
	testing.expect(t, first == restoredFirst && second == restoredSecond)
	testing.expect(t, restoredParameters == [4]^core.Node{&TestDenseStorage(&restored.layers[0]).weights, &TestDenseStorage(&restored.layers[0]).bias, &TestDenseStorage(&restored.layers[2]).weights, &TestDenseStorage(&restored.layers[2]).bias})
	input := [4]f32{0.2, -0.7, 1.0, 0.4}
	a, aok := SequentialPredict(&source, input[:])
	b, bok := SequentialPredict(&restored, input[:])
	testing.expect(t, aok && bok && len(a) == len(b))
	if aok && bok && len(a) == len(b) { for value, i in a { testing.expect(t, value == b[i]) } }
	size2, written2 := CheckpointWrite(&restored, &restoredAdam, shuffle, again[:])
	testing.expect(t, written2 && size2 == size)
	if written2 && size2 == size { for byte, i in data[:size] { testing.expect(t, byte == again[i]) } }
}

@(test)
CheckpointResumeShuffledAdam :: proc(t: ^testing.T) {
	a, b, restored: Sequential(3, 3, 2)
	for model in ([2]^Sequential(3, 3, 2){&a, &b}) {
		testing.expect(t, SequentialInit(model, 2, 11) && SequentialAddDense(model, 3) && SequentialAddActivation(model, .Tanh) && SequentialAddDense(model, 1))
	}
	pa, pb, pr: [4]^core.Node
	paramsA, oka := SequentialParameters(&a, pa[:])
	paramsB, okb := SequentialParameters(&b, pb[:])
	testing.expect(t, oka && okb)
	ma, va, mb, vb, mr, vr: [13]f32
	adamA := Adam{paramsA, ma[:], va[:], 0, 0.01, 0.9, 0.999, 1e-8}
	adamB := Adam{paramsB, mb[:], vb[:], 0, 0.01, 0.9, 0.999, 1e-8}
	inputs := [10]f32{-2, 1, -1, 2, 0, -1, 1, 3, 3, 0.5}
	targets := [5]f32{1, 0, 2, -1, 4}
	ia, ib, ir: [5]int
	sa, sb, sr: u64 = 55, 55, 0
	la, ok1 := SequentialFitBatches(&a, inputs[:], targets[:], ia[:], &sa, epochs = 7, optimizer = &adamA)
	_, ok2 := SequentialFitBatches(&b, inputs[:], targets[:], ib[:], &sb, epochs = 3, optimizer = &adamB)
	data: [1024]u8
	size, written := CheckpointWrite(&b, &adamB, sb, data[:])
	testing.expect(t, ok1 && ok2 && written && adamB.step == 9)
	if !written { return }
	adamR: Adam
	read := CheckpointRead(&restored, &adamR, &sr, data[:size], pr[:], mr[:], vr[:])
	testing.expect(t, read && sr == sb && mr == mb && vr == vb)
	if !read { return }
	lr, ok3 := SequentialFitBatches(&restored, inputs[:], targets[:], ir[:], &sr, epochs = 4, optimizer = &adamR)
	testing.expect(t, ok3 && la == lr && sa == sr && adamA.step == 21 && adamR.step == adamA.step)
	testing.expect(t, ma == mr && va == vr && ma != [13]f32{} && va != [13]f32{})
	for layer in ([2]int{0, 2}) {
		for value, i in TestDenseStorage(&a.layers[layer]).weights.value.data { testing.expect(t, value == TestDenseStorage(&restored.layers[layer]).weightData[i]) }
		for value, i in TestDenseStorage(&a.layers[layer]).bias.value.data { testing.expect(t, value == TestDenseStorage(&restored.layers[layer]).biasData[i]) }
	}
}

@(test)
CheckpointNoOptimizer :: proc(t: ^testing.T) {
	source, restored: Sequential(6, 3, 2)
	testing.expect(t, CheckpointTestModel(&source))
	data, again: [1024]u8
	size, ok := CheckpointWrite(&source, nil, 77, data[:])
	testing.expect(t, ok)
	if !ok { return }
	shuffle: u64
	testing.expect(t, CheckpointRead(&restored, nil, &shuffle, data[:size], nil, nil, nil) && shuffle == 77)
	size2, ok2 := CheckpointWrite(&restored, nil, shuffle, again[:])
	testing.expect(t, ok2 && size == size2)
	if ok2 && size == size2 { for byte, i in data[:size] { testing.expect(t, byte == again[i]) } }
	adam: Adam
	testing.expect(t, !CheckpointRead(&restored, &adam, &shuffle, data[:size], nil, nil, nil))
}

@(test)
CheckpointReboundParametersAndRandomState :: proc(t: ^testing.T) {
	source, restored: Sequential(1, 2, 1)
	testing.expect(t, SequentialInit(&source, 1) && SequentialAddDense(&source, 1))
	weights := [1]f32{7}
	bias := [1]f32{2}
	TestDenseStorage(&source.layers[0]).weights.value.data = weights[:]
	TestDenseStorage(&source.layers[0]).bias.value.data = bias[:]
	data: [256]u8
	size, ok := CheckpointWrite(&source, nil, 0, data[:])
	testing.expect(t, ok)
	if !ok { return }
	shuffle: u64
	testing.expect(t, CheckpointRead(&restored, nil, &shuffle, data[:size], nil, nil, nil))
	testing.expect(t, TestDenseStorage(&restored.layers[0]).weightData[0] == 7 && TestDenseStorage(&restored.layers[0]).biasData[0] == 2)
	position := 56
	CheckpointPut64(data[:], &position, 0)
	testing.expect(t, !CheckpointRead(&restored, nil, &shuffle, data[:size], nil, nil, nil))
	source.randomState = 0
	_, ok = CheckpointWrite(&source, nil, 0, data[:])
	testing.expect(t, !ok)
}

@(test)
CheckpointFailuresAreAtomic :: proc(t: ^testing.T) {
	source, destination: Sequential(6, 3, 2)
	testing.expect(t, CheckpointTestModel(&source) && CheckpointTestModel(&destination))
	params: [4]^core.Node
	p, ok := SequentialParameters(&source, params[:])
	testing.expect(t, ok)
	first, second: [17]f32
	adam := Adam{p, first[:], second[:], 3, 0.01, 0.9, 0.999, 1e-8}
	data: [1024]u8
	size, written := CheckpointWrite(&source, &adam, 42, data[:])
	testing.expect(t, written)
	if !written { return }
	storage := [4]^core.Node{&TestDenseStorage(&destination.layers[0]).bias, &TestDenseStorage(&destination.layers[0]).bias, &TestDenseStorage(&destination.layers[0]).bias, &TestDenseStorage(&destination.layers[0]).bias}
	m, v: [17]f32
	for i in 0..<17 { m[i] = 12; v[i] = 13 }
	target := Adam{storage[:], m[:], v[:], 99, 0.25, 0.5, 0.75, 0.1}
	shuffle: u64 = 1234
	before: [1024]u8
	beforeSize, beforeOk := CheckpointWrite(&destination, nil, shuffle, before[:])
	testing.expect(t, beforeOk)
	// Every truncated prefix, including cuts through parameters and optimizer state.
	for n in 0..<size {
		testing.expect(t, !CheckpointRead(&destination, &target, &shuffle, data[:n], storage[:], m[:], v[:]))
	}
	testing.expect(t, !CheckpointRead(&destination, &target, &shuffle, data[:size], storage[:3], m[:], v[:]))
	testing.expect(t, !CheckpointRead(&destination, &target, &shuffle, data[:size], storage[:], m[:16], v[:]))
	testing.expect(t, !CheckpointRead(&destination, &target, &shuffle, data[:size], storage[:], m[:], v[:16]))
	testing.expect(t, !CheckpointRead(&destination, nil, &shuffle, data[:size], storage[:], m[:], v[:]))
	testing.expect(t, !CheckpointRead(&destination, &target, &shuffle, data[:size+1], storage[:], m[:], v[:]))
	// Corrupt each header field and selected layer/optimizer fields independently.
	for offset in ([9]int{0, 8, 16, 24, 32, 40, 48, 72, 80}) {
		bad := data
		pos := offset
		CheckpointPut64(bad[:], &pos, max(u64))
		testing.expect(t, !CheckpointRead(&destination, &target, &shuffle, bad[:size], storage[:], m[:], v[:]))
	}
	// Invalid activation width, non-finite parameter/config/moment, and negative variance.
	for offset in ([5]int{96, 252, 256, 268, 336}) {
		bad := data
		pos := offset
		CheckpointPut32(bad[:], &pos, transmute(f32)u32(0x7fc00000))
		testing.expect(t, !CheckpointRead(&destination, &target, &shuffle, bad[:size], storage[:], m[:], v[:]))
	}
	badWidth := data
	pos := 140
	CheckpointPut64(badWidth[:], &pos, 1)
	testing.expect(t, !CheckpointRead(&destination, &target, &shuffle, badWidth[:size], storage[:], m[:], v[:]))
	badVariance := data
	pos = 336
	CheckpointPut32(badVariance[:], &pos, -1)
	testing.expect(t, !CheckpointRead(&destination, &target, &shuffle, badVariance[:size], storage[:], m[:], v[:]))
	otherLayers: Sequential(5, 3, 2)
	otherWidth: Sequential(6, 4, 2)
	otherBatch: Sequential(6, 3, 3)
	testing.expect(t, !CheckpointRead(&otherLayers, &target, &shuffle, data[:size], storage[:], m[:], v[:]))
	testing.expect(t, !CheckpointRead(&otherWidth, &target, &shuffle, data[:size], storage[:], m[:], v[:]))
	testing.expect(t, !CheckpointRead(&otherBatch, &target, &shuffle, data[:size], storage[:], m[:], v[:]))
	testing.expect(t, shuffle == 1234 && target.step == 99 && target.learningRate == 0.25 && target.beta1 == 0.5 && target.beta2 == 0.75 && target.epsilon == 0.1)
	testing.expect(t, len(target.parameters) == 4 && len(target.firstMoment) == 17 && len(target.secondMoment) == 17 && &target.parameters[0] == &storage[0] && &target.firstMoment[0] == &m[0] && &target.secondMoment[0] == &v[0])
	for item in storage { testing.expect(t, item == &TestDenseStorage(&destination.layers[0]).bias) }
	for value in m { testing.expect(t, value == 12) }
	for value in v { testing.expect(t, value == 13) }
	after: [1024]u8
	afterSize, afterOk := CheckpointWrite(&destination, nil, shuffle, after[:])
	testing.expect(t, afterOk && beforeSize == afterSize && destination.self == rawptr(&destination))
	if beforeOk && afterOk && beforeSize == afterSize { for byte, i in before[:beforeSize] { testing.expect(t, byte == after[i]) } }
	output: [1024]u8
	for &byte in output { byte = 0xa5 }
	count, failed := CheckpointWrite(&source, &adam, 42, output[:size-1])
	testing.expect(t, !failed && count == 0)
	for byte in output { testing.expect(t, byte == 0xa5) }
	adam.beta1 = 1
	count, failed = CheckpointWrite(&source, &adam, 42, output[:])
	testing.expect(t, !failed && count == 0)
	for byte in output { testing.expect(t, byte == 0xa5) }
}

@(test)
CheckpointSpatialWithoutAdam :: proc(t: ^testing.T) {
	for spatialInput in ([2]bool{false, true}) {
		source, restored: Sequential(3, 16, 2)
		ok := false
		if spatialInput { ok = SequentialInitSpatial(&source, 2, 2, 2) } else { ok = SequentialInit(&source, 8) }
		ok = ok && SequentialAddFlatten(&source) && SequentialAddActivation(&source, .Tanh) && SequentialAddDropout(&source, 0.5)
		testing.expect(t, ok)
		if !ok { continue }
		data, again: [512]u8
		size, written := CheckpointWrite(&source, nil, 55, data[:])
		testing.expect(t, written && data[8] == 2)
		if !written { continue }
		state: u64
		ok = CheckpointRead(&restored, nil, &state, data[:size], nil, nil, nil)
		testing.expect(t, ok && state == 55)
		if !ok { continue }
		n, encoded := CheckpointWrite(&restored, nil, state, again[:])
		testing.expect(t, encoded && n == size)
		if encoded && n == size { for b, i in data[:size] { testing.expect(t, b == again[i]) } }
	}
}

@(test)
CheckpointPoolingRoundTrip :: proc(t: ^testing.T) {
	for kind in ([2]PoolKind{.Max, .Average}) {
		source, restored: Sequential(3, 16, 2)
		ok := SequentialInitSpatial(&source, 3, 3, 1) && SequentialAddPool2D(&source, kind, 2, 2, 1) && SequentialAddFlatten(&source) && SequentialAddDense(&source, 2)
		testing.expect(t, ok)
		if !ok { continue }
		data, again: [512]u8
		size, written := CheckpointWrite(&source, nil, 17, data[:])
		testing.expect(t, written && data[8] == 2)
		if !written { continue }
		state: u64
		ok = CheckpointRead(&restored, nil, &state, data[:size], nil, nil, nil)
		testing.expect(t, ok && state == 17)
		if !ok { continue }
		n, encoded := CheckpointWrite(&restored, nil, state, again[:])
		testing.expect(t, encoded && n == size)
		if encoded && n == size { for b, i in data[:size] { testing.expect(t, b == again[i]) } }
		input := [9]f32{1, 2, 3, 4, 5, 6, 7, 8, 9}
		a, aok := SequentialPredict(&source, input[:])
		b, bok := SequentialPredict(&restored, input[:])
		testing.expect(t, aok && bok && len(a) == len(b))
		if aok && bok && len(a) == len(b) { for value, i in a { testing.expect(t, value == b[i]) } }
		for &byte in again { byte = 0xa5 }
		_, written = CheckpointWrite(&source, nil, 17, again[:size-1])
		testing.expect(t, !written)
		for byte in again { testing.expect(t, byte == 0xa5) }
	}
}

@(test)
CheckpointSpatialCases :: proc(t: ^testing.T) {
	source, restored: Sequential(6, 16, 2)
	ok := SequentialInitSpatial(&source, 3, 3, 1, 42) && SequentialAddConv2D(&source, 2, 2, 2, 1, 0) && SequentialAddActivation(&source, .Relu) && SequentialAddDropout(&source, 0.25) && SequentialAddFlatten(&source) && SequentialAddDense(&source, 2) && SequentialAddActivation(&source, .Softmax)
	testing.expect(t, ok)
	if !ok { return }
	parameters, restoredParameters: [4]^core.Node
	params, valid := SequentialParameters(&source, parameters[:])
	testing.expect(t, valid)
	if !valid { return }
	first, second, restoredFirst, restoredSecond: [28]f32
	for i in 0..<28 { first[i] = f32(i)*0.125; second[i] = f32(i)*0.25 }
	adam := Adam{params, first[:], second[:], 7, 0.01, 0.8, 0.99, 1e-8}
	data, again: [4096]u8
	size, written := CheckpointWrite(&source, &adam, 123, data[:])
	testing.expect(t, written && data[8] == 2)
	if !written { return }
	state: u64 = 99
	loadedAdam: Adam
	for n in 0..<size {
		testing.expect(t, !CheckpointRead(&restored, &loadedAdam, &state, data[:n], restoredParameters[:], restoredFirst[:], restoredSecond[:]))
	}
	testing.expect(t, state == 99 && restored.self == nil && loadedAdam.parameters == nil && restoredFirst == [28]f32{} && restoredSecond == [28]f32{})
	testing.expect(t, !CheckpointRead(&restored, &loadedAdam, &state, data[:size+1], restoredParameters[:], restoredFirst[:], restoredSecond[:]))
	testing.expect(t, !CheckpointRead(&restored, &loadedAdam, &state, data[:size], restoredParameters[:3], restoredFirst[:], restoredSecond[:]))
	testing.expect(t, !CheckpointRead(&restored, &loadedAdam, &state, data[:size], restoredParameters[:], restoredFirst[:27], restoredSecond[:]))
	// The first layer's stride is the fourth u64 after its kind and width.
	strideOffset := 80+24+16+24
	old := data[strideOffset]
	data[strideOffset] = 0
	testing.expect(t, !CheckpointRead(&restored, &loadedAdam, &state, data[:size], restoredParameters[:], restoredFirst[:], restoredSecond[:]))
	data[strideOffset] = old
	testing.expect(t, state == 99 && restored.self == nil)
	ok = CheckpointRead(&restored, &loadedAdam, &state, data[:size], restoredParameters[:], restoredFirst[:], restoredSecond[:])
	testing.expect(t, ok && state == 123 && restoredFirst == first && restoredSecond == second && loadedAdam.step == 7 && restored.randomState == source.randomState)
	if !ok { return }
	n, encoded := CheckpointWrite(&restored, &loadedAdam, state, again[:])
	testing.expect(t, encoded && n == size)
	if encoded && n == size { for b, i in data[:size] { testing.expect(t, b == again[i]) } }
	testing.expect(t, SequentialRestoreBest(&restored, &loadedAdam, &state, data[:size]))
	n, encoded = CheckpointWrite(&restored, &loadedAdam, state, again[:])
	testing.expect(t, encoded && n == size)
	if encoded && n == size { for b, i in data[:size] { testing.expect(t, b == again[i]) } }
}

