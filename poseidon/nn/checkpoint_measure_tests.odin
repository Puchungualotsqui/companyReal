package nn

import "../core"
import "core:mem"
import "core:testing"

checkpointMeasureExpectExact :: proc(t: ^testing.T, model: ^Sequential($maxLayers, $maxWidth, $batchCapacity), adam: ^Adam, shuffle: u64, expected, parameters, elements: int) {
	before: [size_of(type_of(model^))]u8
	modelBytes := mem.slice_ptr((^u8)(rawptr(model)), len(before))
	copy(before[:], modelBytes)
	modelState := model.randomState
	size, zeroSize, nilSize: int
	ok, zeroOk, nilOk: bool
	{
		context.allocator = mem.panic_allocator()
		context.temp_allocator = mem.panic_allocator()
		size, ok = CheckpointMeasure(model, adam, shuffle)
		zeroSize, zeroOk = CheckpointMeasure(model, adam, 0)
	}
	{
		context.allocator = mem.nil_allocator()
		context.temp_allocator = mem.nil_allocator()
		nilSize, nilOk = CheckpointMeasure(model, adam, max(u64))
	}
	testing.expect(t, ok && zeroOk && nilOk && size == expected && zeroSize == size && nilSize == size)
	testing.expect(t, model.randomState == modelState)
	for value, i in modelBytes { testing.expect(t, value == before[i]) }
	if !ok || size != expected || size <= 0 || size > 4096 { return }

	short, exact, generous: [4098]u8
	for &byte in short { byte = 0xa5 }
	for &byte in exact { byte = 0xa5 }
	for &byte in generous { byte = 0xa5 }
	count, written := CheckpointWrite(model, adam, shuffle, short[1:size])
	testing.expect(t, !written && count == 0)
	for value in short { testing.expect(t, value == 0xa5) }
	count, written = CheckpointWrite(model, adam, shuffle, exact[1:1+size])
	testing.expect(t, written && count == size && exact[0] == 0xa5)
	for value in exact[1+size:] { testing.expect(t, value == 0xa5) }
	otherCount, otherWritten := CheckpointWrite(model, adam, shuffle, generous[1:])
	testing.expect(t, otherWritten && otherCount == size)
	if written && otherWritten {
		for value, i in exact[1:1+size] { testing.expect(t, value == generous[1+i]) }
		info, err := CheckpointInspect(exact[1:1+size])
		testing.expect(t, err.code == .None && info.parameterPointers == parameters && info.momentElements == elements && info.hasAdam == (adam != nil))
	}
}

checkpointMeasureExpectInvalid :: proc(t: ^testing.T, model: ^Sequential($maxLayers, $maxWidth, $batchCapacity), adam: ^Adam) {
	output: [4096]u8
	for &byte in output { byte = 0xa5 }
	size, count: int
	measured, written: bool
	{
		context.allocator = mem.nil_allocator()
		context.temp_allocator = mem.nil_allocator()
		size, measured = CheckpointMeasure(model, adam, 17)
		count, written = CheckpointWrite(model, adam, 17, output[:])
	}
	testing.expect(t, !measured && size == 0 && !written && count == 0)
	for byte in output { testing.expect(t, byte == 0xa5) }
}

@(test)
CheckpointMeasureDenseAdamAndSGD :: proc(t: ^testing.T) {
	model: Sequential(6, 3, 2)
	ok := CheckpointTestModel(&model)
	testing.expect(t, ok)
	if !ok { return }
	// Exercise a real SGD update; only model state, not its optimizer, is saved.
	inputs := [4]f32{0.25, -0.5, 0.75, 1}
	targets := [4]f32{0, 1, 1, 0}
	indices: [2]int
	shuffle: u64 = 31
	_, fitted := SequentialFitBatches(&model, inputs[:], targets[:], indices[:], &shuffle, epochs = 1, optimizer = SequentialSGD{0.01})
	testing.expect(t, fitted)
	if !fitted { return }
	checkpointMeasureExpectExact(t, &model, nil, shuffle, 80+6*16+17*4, 4, 17)

	storage: [4]^core.Node
	list, valid := SequentialParameters(&model, storage[:])
	testing.expect(t, valid)
	if !valid { return }
	first, second: [17]f32
	for i in 0..<17 { first[i] = f32(i-8)*0.125; second[i] = f32(i)*0.25 }
	adam := Adam{list, first[:], second[:], max(u64), 0.01, 0.8, 0.95, 1e-6}
	firstBefore, secondBefore, adamBefore := first, second, adam
	checkpointMeasureExpectExact(t, &model, &adam, shuffle, 80+6*16+17*4+24+17*8, 4, 17)
	testing.expect(t, first == firstBefore && second == secondBefore && adam.step == adamBefore.step && adam.learningRate == adamBefore.learningRate && adam.beta1 == adamBefore.beta1 && adam.beta2 == adamBefore.beta2 && adam.epsilon == adamBefore.epsilon)
}

@(test)
CheckpointMeasureReboundValuesAndTransientGradients :: proc(t: ^testing.T) {
	model: Sequential(6, 3, 2)
	ok := CheckpointTestModel(&model)
	testing.expect(t, ok)
	if !ok { return }
	dense := TestDenseStorage(&model.layers[0])
	weights := [6]f32{1, -2, 3, -4, 5, -6}
	bias := [3]f32{0.5, 0.25, -0.75}
	dense.weights.value.data, dense.bias.value.data = weights[:], bias[:]
	// Gradient tensors are not serialized or checked for a model-only checkpoint.
	dense.weights.grad.data = dense.weights.grad.data[:1]
	checkpointMeasureExpectExact(t, &model, nil, 19, 80+6*16+17*4, 4, 17)
	parameters: [4]^core.Node
	list, valid := SequentialParameters(&model, parameters[:])
	testing.expect(t, valid)
	if !valid { return }
	first, second: [17]f32
	adam := Adam{list, first[:], second[:], 1, 0.01, 0.9, 0.999, 1e-8}
	checkpointMeasureExpectInvalid(t, &model, &adam)
}

@(test)
CheckpointMeasurePreservesWireFormat :: proc(t: ^testing.T) {
	model: Sequential(1, 1, 1)
	ok := SequentialInit(&model, 1, 11) && SequentialAddDense(&model, 1)
	testing.expect(t, ok)
	if !ok { return }
	dense := TestDenseStorage(&model.layers[0])
	dense.weightData[0], dense.biasData[0], model.randomState = 1.5, -2, 0x1020304050607080
	parameters: [2]^core.Node
	list, valid := SequentialParameters(&model, parameters[:])
	testing.expect(t, valid)
	if !valid { return }
	first := [2]f32{-0.25, 0.5}
	second := [2]f32{0.75, 1}
	adam := Adam{list, first[:], second[:], 0x8877665544332211, 0.01, 0.8, 0.99, 1e-6}
	expected: [144]u8
	offset := 0
	for value in ([10]u64{CHECKPOINT_MAGIC, 1, 1, 1, 1, 1, 1, 0x1020304050607080, 0xfedcba9876543210, 1}) { CheckpointPut64(expected[:], &offset, value) }
	CheckpointPut64(expected[:], &offset, 0)
	CheckpointPut64(expected[:], &offset, 1)
	CheckpointPut32(expected[:], &offset, 1.5)
	CheckpointPut32(expected[:], &offset, -2)
	CheckpointPut64(expected[:], &offset, 0x8877665544332211)
	for value in ([4]f32{0.01, 0.8, 0.99, 1e-6}) { CheckpointPut32(expected[:], &offset, value) }
	for value in first { CheckpointPut32(expected[:], &offset, value) }
	for value in second { CheckpointPut32(expected[:], &offset, value) }
	actual: [144]u8
	measured, measuredOk := CheckpointMeasure(&model, &adam, 0xfedcba9876543210)
	written, writtenOk := CheckpointWrite(&model, &adam, 0xfedcba9876543210, actual[:])
	testing.expect(t, measuredOk && writtenOk && measured == len(expected) && written == len(expected) && offset == len(expected) && expected == actual)
}

@(test)
CheckpointMeasureEmptyDropoutSpatial :: proc(t: ^testing.T) {
	empty: Sequential(3, 2, 1)
	ok := SequentialInit(&empty, 1)
	testing.expect(t, ok)
	if !ok { return }
	adam := Adam{learningRate = 0.01, beta1 = 0.8, beta2 = 0.9, epsilon = 1e-6}
	checkpointMeasureExpectExact(t, &empty, nil, 0, 80, 0, 0)
	checkpointMeasureExpectExact(t, &empty, &adam, 0, 104, 0, 0)
	ok = SequentialAddDropout(&empty, 0.5) && SequentialAddActivation(&empty, .Tanh)
	testing.expect(t, ok)
	if !ok { return }
	checkpointMeasureExpectExact(t, &empty, nil, 5, 80+2*16+4, 0, 0)
	checkpointMeasureExpectExact(t, &empty, &adam, 5, 80+2*16+4+24, 0, 0)

	spatial: Sequential(6, 16, 2)
	ok = SequentialInitSpatial(&spatial, 3, 3, 1, 42) && SequentialAddConv2D(&spatial, 2, 2, 2, 1, 0) && SequentialAddActivation(&spatial, .Relu) && SequentialAddDropout(&spatial, 0.25) && SequentialAddFlatten(&spatial) && SequentialAddDense(&spatial, 2) && SequentialAddActivation(&spatial, .Softmax)
	testing.expect(t, ok)
	if !ok { return }
	checkpointMeasureExpectExact(t, &spatial, nil, 123, 80+24+6*16+40+4+28*4, 4, 28)
	storage: [4]^core.Node
	list, valid := SequentialParameters(&spatial, storage[:])
	testing.expect(t, valid)
	if !valid { return }
	first, second: [28]f32
	spatialAdam := Adam{list, first[:], second[:], 7, 0.01, 0.8, 0.99, 1e-8}
	checkpointMeasureExpectExact(t, &spatial, &spatialAdam, 123, 80+24+6*16+40+4+28*4+24+28*8, 4, 28)

	for kind in ([2]PoolKind{.Max, .Average}) {
		pool: Sequential(3, 16, 2)
		ok = SequentialInitSpatial(&pool, 3, 3, 1) && SequentialAddPool2D(&pool, kind, 2, 2, 1) && SequentialAddFlatten(&pool) && SequentialAddDense(&pool, 2)
		testing.expect(t, ok)
		if ok { checkpointMeasureExpectExact(t, &pool, nil, 0, 80+24+3*16+24+10*4, 2, 10) }
	}
}

checkpointMeasureTestRandom :: proc(state: ^u64) -> u64 {
	state^ ~= state^ << 13
	state^ ~= state^ >> 7
	state^ ~= state^ << 17
	return state^
}

@(test)
CheckpointMeasureRandomArchitectures :: proc(t: ^testing.T) {
	random: u64 = 0x4d595df4d0f33173
	for trial in 0..<96 {
		model: Sequential(8, 5, 2)
		width := 1+int(checkpointMeasureTestRandom(&random)%5)
		ok := SequentialInit(&model, width, checkpointMeasureTestRandom(&random))
		layerCount := 1+int(checkpointMeasureTestRandom(&random)%8)
		expected, elements, pointerCount := 80, 0, 0
		spatialVersion := false
		for _ in 0..<layerCount {
			expected += 16
			switch checkpointMeasureTestRandom(&random)%6 {
			case 0, 1:
				out := 1+int(checkpointMeasureTestRandom(&random)%5)
				count := width*out+out
				expected += count*4; elements += count; pointerCount += 2
				ok = ok && SequentialAddDense(&model, out)
				width = out
			case 2: expected += 4; ok = ok && SequentialAddDropout(&model, 0.25)
			case 3: ok = ok && SequentialAddActivation(&model, .Relu)
			case 4: ok = ok && SequentialAddActivation(&model, .Tanh)
			case 5: spatialVersion = true; ok = ok && SequentialAddFlatten(&model)
			}
		}
		testing.expect(t, ok)
		if !ok { return }
		if spatialVersion { expected += 24 }
		storage: [16]^core.Node
		list, valid := SequentialParameters(&model, storage[:])
		testing.expect(t, valid && len(list) == pointerCount)
		if !valid { return }
		first, second: [240]f32
		for i in 0..<elements { first[i] = f32(i-20)*0.125; second[i] = f32(i)*0.25 }
		adam := Adam{list, first[:elements], second[:elements], u64(trial), 0.01, 0.8, 0.99, 1e-6}
		checkpointMeasureExpectExact(t, &model, nil, random, expected, pointerCount, elements)
		checkpointMeasureExpectExact(t, &model, &adam, random, expected+24+elements*8, pointerCount, elements)
	}
}

@(test)
CheckpointMeasureInvalidModelsAndAdam :: proc(t: ^testing.T) {
	checkpointMeasureExpectInvalid(t, (^Sequential(6, 3, 2))(nil), nil)
	uninitialized: Sequential(6, 3, 2)
	checkpointMeasureExpectInvalid(t, &uninitialized, nil)
	for which in 0..<25 {
		model: Sequential(6, 3, 2)
		ok := CheckpointTestModel(&model)
		testing.expect(t, ok)
		if !ok { return }
		storage: [4]^core.Node
		list, valid := SequentialParameters(&model, storage[:])
		testing.expect(t, valid)
		if !valid { return }
		first, second: [17]f32
		adam := Adam{list, first[:], second[:], 3, 0.01, 0.9, 0.999, 1e-8}
		dense := TestDenseStorage(&model.layers[0])
		denseOperation := &model.layers[0].operation.(Dense)
		switch which {
		case 0: model.inputWidth = 0
		case 1: model.inputWidth = max(int)
		case 2: model.layerCount = -1
		case 3: model.layerCount = max(int)
		case 4: model.randomState = 0
		case 5: model.inputShape[0] = 0
		case 6: model.inputShape[1] = max(int)
		case 7: model.input.value.shape = model.inputShape[:1]
		case 8: model.layers[0].width = 0
		case 9: model.layers[0].width = max(int)
		case 10: model.layers[0].layer = nil
		case 11: dense.weightShape[0] = max(int)
		case 12: dense.weights.value.data = dense.weights.value.data[:1]
		case 13: dense.weightData[0] = transmute(f32)u32(0x7fc00000)
		case 14: dense.biasData[0] = transmute(f32)u32(0x7f800000)
		case 15: adam.beta1 = 1
		case 16: adam.epsilon = 0
		case 17: adam.firstMoment = first[:16]
		case 18: storage[0], storage[1] = storage[1], storage[0]
		case 19: first[16] = transmute(f32)u32(0x7fc00000)
		case 20: second[16] = -1
		case 21: second[16] = transmute(f32)u32(0x7f800000)
		case 22: denseOperation.input = nil
		case 23: adam.parameters, adam.firstMoment, adam.secondMoment = list[:2], first[:9], second[:9]
		case 24: adam.parameters, adam.firstMoment, adam.secondMoment = list[2:], first[:8], second[:8]
		}
		checkpointMeasureExpectInvalid(t, &model, &adam)
		if which <= 14 || which == 22 { checkpointMeasureExpectInvalid(t, &model, nil) }
	}
	original: Sequential(6, 3, 2)
	ok := CheckpointTestModel(&original)
	testing.expect(t, ok)
	if ok { copied := original; checkpointMeasureExpectInvalid(t, &copied, nil) }
}

@(test)
CheckpointMeasureInvalidSpatialAndOverflow :: proc(t: ^testing.T) {
	for which in 0..<8 {
		model: Sequential(4, 16, 2)
		ok := SequentialInitSpatial(&model, 3, 3, 1) && SequentialAddConv2D(&model, 2, 2, 2) && SequentialAddDropout(&model, 0.25) && SequentialAddPool2D(&model, .Max, 2, 2, 1) && SequentialAddFlatten(&model)
		testing.expect(t, ok)
		if !ok { return }
		convStorage := &model.layers[0].storage.(Conv2DStorage(16))
		conv := &model.layers[0].operation.(Conv2D)
		dropout := &model.layers[1].operation.(Dropout)
		pool := &model.layers[2].operation.(Pool2D)
		switch which {
		case 0: model.inputShape[1] = max(int)
		case 1: model.inputShape[2] = 0
		case 2: convStorage.weightShape[0] = max(int)
		case 3: conv.stride = 0
		case 4: dropout.rate = transmute(f32)u32(0x7fc00000)
		case 5: dropout.randomState = nil
		case 6: pool.kernelWidth = max(int)
		case 7: pool.stride = 0
		}
		checkpointMeasureExpectInvalid(t, &model, nil)
	}
	// Exercise exact int boundaries directly: impractically large valid backing
	// storage cannot be constructed safely just to drive these arithmetic paths.
	size := max(int)-8
	testing.expect(t, checkpointSizeAdd(&size, 2, 4) && size == max(int))
	testing.expect(t, !checkpointSizeAdd(&size, 1, 1) && size == max(int))
	size = 80
	count := (max(int)-size)/8
	testing.expect(t, checkpointSizeAdd(&size, count, 8) && size == 80+count*8)
	before := size
	testing.expect(t, !checkpointSizeAdd(&size, max(int), 8) && size == before)
	testing.expect(t, !checkpointSizeAdd(&size, -1, 4) && size == before)
	testing.expect(t, !checkpointSizeAdd(&size, 1, 0) && size == before)
	size = -1
	testing.expect(t, !checkpointSizeAdd(&size, 1, 1) && size == -1)
}

@(test)
CheckpointOwnedBufferLifecycle :: proc(t: ^testing.T) {
	model: Sequential(1, 2, 1)
	ok := SequentialInit(&model, 2) && SequentialAddDense(&model, 1)
	testing.expect(t, ok)
	if !ok { return }
	expected: [256]u8
	size, written := CheckpointWrite(&model, nil, 19, expected[:])
	testing.expect(t, written)
	if !written { return }
	state := AutoFitCountingAllocator{backing = context.allocator}
	allocator := mem.Allocator{procedure = AutoFitCountingAllocatorProc, data = &state}
	owner: CheckpointOwnedBuffer
	defer if state.live != nil { _ = CheckpointOwnedBufferDestroy(&owner) }
	testing.expect(t, !CheckpointOwnedBufferSave(nil, &model, nil, 19, allocator))
	testing.expect(t, CheckpointOwnedBufferBytes(nil) == nil && !CheckpointOwnedBufferDestroy(nil))
	testing.expect(t, !CheckpointOwnedBufferSave(&owner, &model, nil, 19, mem.nil_allocator()))
	testing.expect(t, CheckpointOwnedBufferBytes(&owner) == nil && CheckpointOwnedBufferDestroy(&owner))
	ok = CheckpointOwnedBufferSave(&owner, &model, nil, 19, allocator)
	testing.expect(t, ok && state.allocations == 1 && state.lastSize == size)
	if !ok { return }
	bytes := CheckpointOwnedBufferBytes(&owner)
	testing.expect(t, len(bytes) == size)
	if len(bytes) == size { for value, i in bytes { testing.expect(t, value == expected[i]) } }
	testing.expect(t, !CheckpointOwnedBufferSave(&owner, &model, nil, 19, allocator) && state.allocations == 1)
	copied := owner
	testing.expect(t, CheckpointOwnedBufferBytes(&copied) == nil && !CheckpointOwnedBufferDestroy(&copied) && !CheckpointOwnedBufferSave(&copied, &model, nil, 19, allocator))
	state.failNextFree = true
	testing.expect(t, !CheckpointOwnedBufferDestroy(&owner) && state.live != nil && CheckpointOwnedBufferBytes(&owner) == nil)
	{
		context.allocator = mem.nil_allocator()
		ok = CheckpointOwnedBufferDestroy(&owner)
	}
	testing.expect(t, ok && state.live == nil && state.frees == 2 && state.successfulFrees == 1 && state.invalidFrees == 0)
	testing.expect(t, CheckpointOwnedBufferDestroy(&owner) && CheckpointOwnedBufferBytes(&owner) == nil)
	{
		context.allocator = mem.nil_allocator()
		ok = CheckpointOwnedBufferSave(&owner, &model, nil, 19)
	}
	testing.expect(t, !ok && CheckpointOwnedBufferDestroy(&owner))
	ok = CheckpointOwnedBufferSave(&owner, &model, nil, 19)
	testing.expect(t, ok && len(CheckpointOwnedBufferBytes(&owner)) == size)
	testing.expect(t, CheckpointOwnedBufferDestroy(&owner))
}

CheckpointMeasureMutatingAllocator :: struct {
	backing: mem.Allocator,
	model: ^Sequential(1, 2, 1),
	live: rawptr,
}

CheckpointMeasureMutatingAllocatorProc :: proc(data: rawptr, mode: mem.Allocator_Mode, size, alignment: int, oldMemory: rawptr, oldSize: int, loc := #caller_location) -> ([]byte, mem.Allocator_Error) {
	state := (^CheckpointMeasureMutatingAllocator)(data)
	memory, err := state.backing.procedure(state.backing.data, mode, size, alignment, oldMemory, oldSize, loc)
	if mode == .Alloc {
		state.live = raw_data(memory)
		state.model.randomState = 0
	} else if mode == .Free && err == nil {
		state.live = nil
	}
	return memory, err
}

@(test)
CheckpointOwnedBufferWriteFailureRetainsAllocation :: proc(t: ^testing.T) {
	model: Sequential(1, 2, 1)
	ok := SequentialInit(&model, 2) && SequentialAddDense(&model, 1)
	testing.expect(t, ok)
	if !ok { return }
	state := CheckpointMeasureMutatingAllocator{backing = context.allocator, model = &model}
	allocator := mem.Allocator{procedure = CheckpointMeasureMutatingAllocatorProc, data = &state}
	owner: CheckpointOwnedBuffer
	defer if state.live != nil { _ = CheckpointOwnedBufferDestroy(&owner) }
	// Simulate a model becoming invalid between measurement and writing.
	testing.expect(t, !CheckpointOwnedBufferSave(&owner, &model, nil, 1, allocator))
	testing.expect(t, state.live != nil && CheckpointOwnedBufferBytes(&owner) == nil)
	testing.expect(t, CheckpointOwnedBufferDestroy(&owner) && state.live == nil)
}

@(test)
CheckpointOwnedBufferFailureOwnership :: proc(t: ^testing.T) {
	model: Sequential(1, 2, 1)
	ok := SequentialInit(&model, 2) && SequentialAddDense(&model, 1)
	testing.expect(t, ok)
	if !ok { return }
	state := AutoFitCountingAllocator{backing = context.allocator, returnPointerAndError = true}
	allocator := mem.Allocator{procedure = AutoFitCountingAllocatorProc, data = &state}
	owner: CheckpointOwnedBuffer
	defer if state.live != nil { _ = CheckpointOwnedBufferDestroy(&owner) }
	model.randomState = 0
	testing.expect(t, !CheckpointOwnedBufferSave(&owner, &model, nil, 1, allocator) && state.allocations == 0)
	model.randomState = 1
	testing.expect(t, !CheckpointOwnedBufferSave(&owner, &model, nil, 1, allocator))
	testing.expect(t, state.allocations == 1 && state.live != nil && state.frees == 0 && CheckpointOwnedBufferBytes(&owner) == nil)
	testing.expect(t, !CheckpointOwnedBufferSave(&owner, &model, nil, 1, allocator))
	testing.expect(t, CheckpointOwnedBufferDestroy(&owner) && state.live == nil && state.successfulFrees == 1)
	state.returnPointerAndError = false
	testing.expect(t, CheckpointOwnedBufferSave(&owner, &model, nil, 1, allocator))
	state.failNextFree, state.freeBeforeError = true, true
	testing.expect(t, !CheckpointOwnedBufferDestroy(&owner) && state.live == nil && CheckpointOwnedBufferBytes(&owner) == nil)
	// The allocator released memory despite reporting an error; retrying would be unsafe.
}
