package nn

import "../core"
import "core:fmt"
import "core:os"
import "core:testing"

@(test)
CheckpointFileRoundTripAndResume :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "poseidon-checkpoint-test-*", context.allocator)
	testing.expect(t, err == nil)
	if err != nil { return }
	defer delete(dir)
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/checkpoint", dir)

	reference, partial, restored: Sequential(3, 3, 2)
	for model in ([2]^Sequential(3, 3, 2){&reference, &partial}) {
		ok := SequentialInit(model, 2, 11) && SequentialAddDense(model, 3) && SequentialAddActivation(model, .Tanh) && SequentialAddDense(model, 1)
		testing.expect(t, ok)
		if !ok { return }
	}
	pa, pb, pr: [4]^core.Node
	paramsA, oka := SequentialParameters(&reference, pa[:])
	paramsB, okb := SequentialParameters(&partial, pb[:])
	testing.expect(t, oka && okb)
	if !oka || !okb { return }
	ma, va, mb, vb, mr, vr: [13]f32
	adamA := Adam{paramsA, ma[:], va[:], 0, 0.01, 0.9, 0.999, 1e-8}
	adamB := Adam{paramsB, mb[:], vb[:], 0, 0.01, 0.9, 0.999, 1e-8}
	inputs := [10]f32{-2, 1, -1, 2, 0, -1, 1, 3, 3, 0.5}
	targets := [5]f32{1, 0, 2, -1, 4}
	ia, ib, ir: [5]int
	sa, sb, sr: u64 = 55, 55, 0
	la, ok1 := SequentialFitBatches(&reference, inputs[:], targets[:], ia[:], &sa, epochs = 7, optimizer = &adamA)
	_, ok2 := SequentialFitBatches(&partial, inputs[:], targets[:], ib[:], &sb, epochs = 3, optimizer = &adamB)
	testing.expect(t, ok1 && ok2)
	if !ok1 || !ok2 { return }
	scratch, expected, actual: [1024]u8
	size, encoded := CheckpointWrite(&partial, &adamB, sb, expected[:])
	testing.expect(t, encoded && CheckpointSaveFile(&partial, &adamB, sb, path, scratch[:]))
	if !encoded { return }
	adamR: Adam
	loaded := CheckpointLoadFile(&restored, &adamR, &sr, path, scratch[:size], pr[:], mr[:], vr[:])
	testing.expect(t, loaded)
	if !loaded { return }
	size2, encoded2 := CheckpointWrite(&restored, &adamR, sr, actual[:])
	testing.expect(t, encoded2 && size2 == size)
	if encoded2 && size2 == size { for byte, i in expected[:size] { testing.expect(t, byte == actual[i]) } }
	testing.expect(t, pr == [4]^core.Node{&restored.layers[0].weights, &restored.layers[0].bias, &restored.layers[2].weights, &restored.layers[2].bias})
	lr, ok3 := SequentialFitBatches(&restored, inputs[:], targets[:], ir[:], &sr, epochs = 4, optimizer = &adamR)
	testing.expect(t, ok3 && la == lr && sa == sr && adamA.step == 21 && adamR.step == adamA.step)
	testing.expect(t, ma == mr && va == vr && ma != [13]f32{} && va != [13]f32{})
	for layer in ([2]int{0, 2}) {
		for value, i in reference.layers[layer].weights.value.data { testing.expect(t, value == restored.layers[layer].weightData[i]) }
		for value, i in reference.layers[layer].bias.value.data { testing.expect(t, value == restored.layers[layer].biasData[i]) }
	}
}

// Each failed load must leave the model, optimizer, shuffle state and all caller storage untouched.
CheckpointFileExpectLoadFailure :: proc(t: ^testing.T, path: string, scratch: []u8, parameterCount, firstCount, secondCount: int) {
	destination: Sequential(6, 3, 2)
	ok := CheckpointTestModel(&destination)
	testing.expect(t, ok)
	if !ok { return }
	storage := [4]^core.Node{&destination.layers[0].bias, &destination.layers[0].bias, &destination.layers[0].bias, &destination.layers[0].bias}
	m, v: [17]f32
	for i in 0..<17 { m[i] = 12; v[i] = 13 }
	target := Adam{storage[:], m[:], v[:], 99, 0.25, 0.5, 0.75, 0.1}
	shuffle: u64 = 1234
	before, after: [1024]u8
	beforeSize, beforeOk := CheckpointWrite(&destination, nil, shuffle, before[:])
	testing.expect(t, beforeOk)
	if !beforeOk { return }
	testing.expect(t, !CheckpointLoadFile(&destination, &target, &shuffle, path, scratch, storage[:parameterCount], m[:firstCount], v[:secondCount]))
	testing.expect(t, shuffle == 1234 && target.step == 99 && target.learningRate == 0.25 && target.beta1 == 0.5 && target.beta2 == 0.75 && target.epsilon == 0.1)
	testing.expect(t, len(target.parameters) == 4 && len(target.firstMoment) == 17 && len(target.secondMoment) == 17 && &target.parameters[0] == &storage[0] && &target.firstMoment[0] == &m[0] && &target.secondMoment[0] == &v[0])
	for item in storage { testing.expect(t, item == &destination.layers[0].bias) }
	for value in m { testing.expect(t, value == 12) }
	for value in v { testing.expect(t, value == 13) }
	afterSize, afterOk := CheckpointWrite(&destination, nil, shuffle, after[:])
	testing.expect(t, afterOk && beforeSize == afterSize && destination.self == rawptr(&destination))
	if afterOk && beforeSize == afterSize { for byte, i in before[:beforeSize] { testing.expect(t, byte == after[i]) } }
}

@(test)
CheckpointFileFailures :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "poseidon-checkpoint-test-*", context.allocator)
	testing.expect(t, err == nil)
	if err != nil { return }
	defer delete(dir)
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/checkpoint", dir)
	missing := fmt.tprintf("%s/missing/checkpoint", dir)
	source: Sequential(6, 3, 2)
	ok := CheckpointTestModel(&source)
	testing.expect(t, ok)
	if !ok { return }
	parameters: [4]^core.Node
	params, paramsOk := SequentialParameters(&source, parameters[:])
	testing.expect(t, paramsOk)
	if !paramsOk { return }
	first, second: [17]f32
	adam := Adam{params, first[:], second[:], 3, 0.01, 0.9, 0.999, 1e-8}
	data, scratch, loaded: [1024]u8
	size, encoded := CheckpointWrite(&source, &adam, 42, data[:])
	testing.expect(t, encoded)
	if !encoded { return }
	saved := CheckpointSaveFile(&source, &adam, 42, path, scratch[:])
	testing.expect(t, saved)
	if !saved { return }
	// Neither validation nor an undersized serialization buffer may replace the old file.
	adam.beta1 = 1
	testing.expect(t, !CheckpointSaveFile(&source, &adam, 43, path, scratch[:]))
	adam.beta1 = 0.9
	testing.expect(t, !CheckpointSaveFile(&source, &adam, 43, path, scratch[:size-1]))
	restored: Sequential(6, 3, 2)
	rp: [4]^core.Node
	rm, rv: [17]f32
	radam: Adam
	shuffle: u64
	ok = CheckpointLoadFile(&restored, &radam, &shuffle, path, scratch[:], rp[:], rm[:], rv[:])
	testing.expect(t, ok)
	if !ok { return }
	readSize, readOk := CheckpointWrite(&restored, &radam, shuffle, loaded[:])
	testing.expect(t, readOk && readSize == size)
	if readOk && readSize == size { for byte, i in data[:size] { testing.expect(t, byte == loaded[i]) } }
	testing.expect(t, !CheckpointSaveFile(&source, &adam, 42, missing, scratch[:]))
	testing.expect(t, !CheckpointSaveFile(&source, &adam, 42, dir, scratch[:]))
	testing.expect(t, !CheckpointSaveFile(&source, &adam, 42, "", scratch[:]))
	CheckpointFileExpectLoadFailure(t, missing, scratch[:], 4, 17, 17)
	CheckpointFileExpectLoadFailure(t, dir, scratch[:], 4, 17, 17)
	CheckpointFileExpectLoadFailure(t, "", scratch[:], 4, 17, 17)
	CheckpointFileExpectLoadFailure(t, path, scratch[:size-1], 4, 17, 17)
	CheckpointFileExpectLoadFailure(t, path, scratch[:], 3, 17, 17)
	CheckpointFileExpectLoadFailure(t, path, scratch[:], 4, 16, 17)
	CheckpointFileExpectLoadFailure(t, path, scratch[:], 4, 17, 16)
	testing.expect(t, os.write_entire_file(path, data[:size-1]) == nil)
	CheckpointFileExpectLoadFailure(t, path, scratch[:], 4, 17, 17)
	bad := data
	bad[0] = 0
	testing.expect(t, os.write_entire_file(path, bad[:size]) == nil)
	CheckpointFileExpectLoadFailure(t, path, scratch[:], 4, 17, 17)
	data[size] = 0xa5
	testing.expect(t, os.write_entire_file(path, data[:size+1]) == nil)
	CheckpointFileExpectLoadFailure(t, path, scratch[:size], 4, 17, 17)
	CheckpointFileExpectLoadFailure(t, path, scratch[:], 4, 17, 17)
}
