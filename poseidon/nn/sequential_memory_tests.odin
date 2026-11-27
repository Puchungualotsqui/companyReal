package nn

import "../core"
import "core:mem"
import "core:testing"

// From poseidon/ on Linux, run the memory regressions with an 8 MiB stack:
// (ulimit -c 0; ulimit -s 8192; timeout 120s odin test nn -o:none -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_NAMES=nn.SequentialMemoryLargeDense,nn.SequentialMemoryLargeConv,nn.SequentialMemoryLargeDropout,nn.SequentialMemoryVariantZeroing)

@(test)
SequentialMemoryLargeDense :: proc(t: ^testing.T) {
	owner, restoredOwner: OwnedSequential(1, 1024, 2)
	initialized := OwnedSequentialInit(&owner, 1, seed = 42)
	testing.expect(t, initialized && SequentialStorageSize(1, 1024, 2) > 8 * 1024 * 1024)
	if !initialized { return }
	defer OwnedSequentialDestroy(&owner)
	initialized = OwnedSequentialInit(&restoredOwner, 1)
	testing.expect(t, initialized)
	if !initialized { return }
	defer OwnedSequentialDestroy(&restoredOwner)
	model, restored := OwnedSequentialModel(&owner), OwnedSequentialModel(&restoredOwner)
	testing.expect(t, model != nil && restored != nil && model.self == rawptr(model))
	if model == nil || restored == nil { return }

	// The same seed and active dimensions must have the same initialization at a
	// small capacity; larger inline capacity must not affect the RNG stream.
	reference: Sequential(1, 1, 2)
	ok := SequentialInit(&reference, 1, 42) && SequentialAddDense(&reference, 1) && SequentialAddDense(model, 1)
	testing.expect(t, ok)
	if !ok { return }
	dense := &model.layers[0].storage.(DenseStorage(1024))
	operation := &model.layers[0].operation.(Dense)
	testing.expect(t, dense.weightData[0] == TestDenseStorage(&reference.layers[0]).weightData[0] && model.randomState == reference.randomState)
	testing.expect(t, dense.weightGrad[0] == 0 && dense.biasData[0] == 0 && dense.biasGrad[0] == 0)
	testing.expect(t, operation.input == &model.input && operation.output == &model.layers[0].output && operation.weights == &dense.weights && operation.bias == &dense.bias)
	testing.expect(t, raw_data(dense.weights.value.data) == &dense.weightData[0] && raw_data(dense.weights.grad.data) == &dense.weightGrad[0])
	parameterCount, elementCount, valid := SequentialAdamRequirements(model)
	testing.expect(t, valid && parameterCount == 2 && elementCount == 2)

	dense.weightData[0], dense.biasData[0] = 3, -2
	parameters, restoredParameters: [2]^core.Node
	first, second, restoredFirst, restoredSecond: [2]f32
	adam, restoredAdam: Adam
	ok = SequentialAdamInit(model, &adam, parameters[:], first[:], second[:])
	testing.expect(t, ok && parameters[0] == &dense.weights && parameters[1] == &dense.bias)
	if !ok { return }
	adam.step = 7
	first = {0.25, -0.5}
	second = {0.5, 0.75}
	checkpoint, again: [256]u8
	size, written := CheckpointWrite(model, &adam, 77, checkpoint[:])
	testing.expect(t, written)
	if !written { return }
	shuffle: u64
	ok = CheckpointRead(restored, &restoredAdam, &shuffle, checkpoint[:size], restoredParameters[:], restoredFirst[:], restoredSecond[:])
	testing.expect(t, ok && shuffle == 77 && restored.self == rawptr(restored) && restored.randomState == model.randomState)
	if !ok { return }
	restoredDense := &restored.layers[0].storage.(DenseStorage(1024))
	testing.expect(t, restoredDense.weightData[0] == 3 && restoredDense.biasData[0] == -2 && restoredDense.weightGrad[0] == 0 && restoredDense.biasGrad[0] == 0)
	testing.expect(t, restoredParameters[0] == &restoredDense.weights && restoredParameters[1] == &restoredDense.bias && restoredAdam.step == adam.step && restoredFirst == first && restoredSecond == second)
	sizeAgain, writtenAgain := CheckpointWrite(restored, &restoredAdam, shuffle, again[:])
	testing.expect(t, writtenAgain && sizeAgain == size)
	if writtenAgain && sizeAgain == size {
		for i in 0..<size { if checkpoint[i] != again[i] { testing.expect(t, false); break } }
	}
	input := [1]f32{2}
	output, predicted := SequentialPredict(restored, input[:])
	testing.expect(t, predicted && len(output) == 1 && output[0] == 4)
}

@(test)
SequentialMemoryLargeConv :: proc(t: ^testing.T) {
	owner: OwnedSequential(1, 1024, 2)
	initialized := OwnedSequentialInitSpatial(&owner, 1, 1, 1, seed = 17)
	testing.expect(t, initialized)
	if !initialized { return }
	defer OwnedSequentialDestroy(&owner)
	model := OwnedSequentialModel(&owner)
	if model == nil { testing.expect(t, false); return }
	reference: Sequential(1, 1, 2)
	ok := SequentialInitSpatial(&reference, 1, 1, 1, 17) && SequentialAddConv2D(&reference, 1, 1, 1) && SequentialAddConv2D(model, 1, 1, 1)
	testing.expect(t, ok)
	if !ok { return }
	conv := &model.layers[0].storage.(Conv2DStorage(1024))
	ref := &reference.layers[0].storage.(Conv2DStorage(1))
	operation := &model.layers[0].operation.(Conv2D)
	testing.expect(t, conv.weightData[0] == ref.weightData[0] && model.randomState == reference.randomState)
	testing.expect(t, conv.weightGrad[0] == 0 && conv.biasData[0] == 0 && conv.biasGrad[0] == 0)
	testing.expect(t, operation.input == &model.input && operation.output == &model.layers[0].output && operation.weights == &conv.weights && operation.bias == &conv.bias)
	parameterCount, elementCount, valid := SequentialAdamRequirements(model)
	testing.expect(t, valid && parameterCount == 2 && elementCount == 2)
	conv.weightData[0], conv.biasData[0] = 4, -1
	checkpoint: [256]u8
	size, written := CheckpointWrite(model, nil, 31, checkpoint[:])
	testing.expect(t, written)
	if !written { return }
	state := model.randomState
	shuffle: u64
	ok = CheckpointRead(model, nil, &shuffle, checkpoint[:size], nil, nil, nil)
	testing.expect(t, ok && shuffle == 31 && model.self == rawptr(model) && model.randomState == state)
	if !ok { return }
	conv = &model.layers[0].storage.(Conv2DStorage(1024))
	operation = &model.layers[0].operation.(Conv2D)
	testing.expect(t, conv.weightData[0] == 4 && conv.biasData[0] == -1 && operation.weights == &conv.weights && operation.bias == &conv.bias)
	input := [1]f32{3}
	output, predicted := SequentialPredict(model, input[:])
	testing.expect(t, predicted && len(output) == 1 && output[0] == 11)
}

@(test)
SequentialMemoryLargeDropout :: proc(t: ^testing.T) {
	BatchCapacity :: 2 * 1024 * 1024
	owner: OwnedSequential(1, 1, BatchCapacity)
	initialized := OwnedSequentialInit(&owner, 1, seed = 29)
	testing.expect(t, initialized && size_of(DropoutStorage(1, BatchCapacity)) >= 8 * 1024 * 1024)
	if !initialized { return }
	defer OwnedSequentialDestroy(&owner)
	model := OwnedSequentialModel(&owner)
	if model == nil { testing.expect(t, false); return }
	ok := SequentialAddDropout(model, 0.25)
	testing.expect(t, ok)
	if !ok { return }
	storage := &model.layers[0].storage.(DropoutStorage(1, BatchCapacity))
	dropout := &model.layers[0].operation.(Dropout)
	testing.expect(t, storage.maskData[0] == 0 && storage.maskData[BatchCapacity-1] == 0 && raw_data(dropout.mask) == &storage.maskData[0] && dropout.randomState == &model.randomState)
	parameterCount, elementCount, valid := SequentialAdamRequirements(model)
	testing.expect(t, valid && parameterCount == 0 && elementCount == 0)
	storage.maskData[BatchCapacity-1] = 7
	checkpoint: [128]u8
	size, written := CheckpointWrite(model, nil, 53, checkpoint[:])
	testing.expect(t, written)
	if !written { return }
	shuffle: u64
	ok = CheckpointRead(model, nil, &shuffle, checkpoint[:size], nil, nil, nil)
	testing.expect(t, ok && shuffle == 53 && model.self == rawptr(model) && model.randomState == 29)
	if !ok { return }
	storage = &model.layers[0].storage.(DropoutStorage(1, BatchCapacity))
	dropout = &model.layers[0].operation.(Dropout)
	testing.expect(t, storage.maskData[BatchCapacity-1] == 0 && raw_data(dropout.mask) == &storage.maskData[0] && dropout.randomState == &model.randomState)
	input := [1]f32{2}
	output, predicted := SequentialPredict(model, input[:])
	testing.expect(t, predicted && len(output) == 1 && output[0] == 2 && len(dropout.mask) == 1)
}

@(test)
SequentialMemoryVariantZeroing :: proc(t: ^testing.T) {
	// Start each add with a dirty storage variant, including inactive array tails.
	// A dropout-dominated slot also exercises tag placement beyond dense/conv data.
	model: Sequential(1, 4, 32)
	ok := SequentialInit(&model, 2, 5)
	testing.expect(t, ok)
	if !ok { return }
	item := &model.layers[0]
	item.storage = DropoutStorage(4, 32){}
	mask := &item.storage.(DropoutStorage(4, 32))
	for &value in mask.maskData { value = 3 }
	state := model.randomState
	testing.expect(t, !SequentialAddDense(&model, 0) && model.layerCount == 0 && model.randomState == state && mask.maskData[0] == 3)
	{
		context.allocator = mem.nil_allocator()
		ok = SequentialAddDense(&model, 2)
	}
	testing.expect(t, ok)
	if !ok { return }
	dense := &item.storage.(DenseStorage(4))
	for value, i in dense.weightData { if i >= 4 { testing.expect(t, value == 0) } }
	for value in dense.weightGrad { testing.expect(t, value == 0) }
	for value in dense.biasData { testing.expect(t, value == 0) }
	for value in dense.biasGrad { testing.expect(t, value == 0) }

	ok = SequentialInitSpatial(&model, 1, 1, 1, 5)
	testing.expect(t, ok)
	if !ok { return }
	item.storage = DropoutStorage(4, 32){}
	mask = &item.storage.(DropoutStorage(4, 32))
	for &value in mask.maskData { value = 3 }
	state = model.randomState
	testing.expect(t, !SequentialAddConv2D(&model, 2, 2, 1) && model.layerCount == 0 && model.randomState == state && mask.maskData[0] == 3)
	{
		context.allocator = mem.nil_allocator()
		ok = SequentialAddConv2D(&model, 1, 1, 1)
	}
	testing.expect(t, ok)
	if !ok { return }
	conv := &item.storage.(Conv2DStorage(4))
	for value, i in conv.weightData { if i >= 1 { testing.expect(t, value == 0) } }
	for value in conv.weightGrad { testing.expect(t, value == 0) }
	for value in conv.biasData { testing.expect(t, value == 0) }
	for value in conv.biasGrad { testing.expect(t, value == 0) }

	ok = SequentialInit(&model, 2, 5)
	testing.expect(t, ok)
	if !ok { return }
	item.storage = DropoutStorage(4, 32){}
	mask = &item.storage.(DropoutStorage(4, 32))
	for &value in mask.maskData { value = 3 }
	state = model.randomState
	testing.expect(t, !SequentialAddDropout(&model, 1) && model.layerCount == 0 && model.randomState == state && mask.maskData[0] == 3)
	{
		context.allocator = mem.nil_allocator()
		ok = SequentialAddDropout(&model, 0.25)
	}
	testing.expect(t, ok)
	if !ok { return }
	storage := &item.storage.(DropoutStorage(4, 32))
	for value in storage.maskData { testing.expect(t, value == 0) }

	// Switching from a different active variant must clear its overlapping bytes.
	ok = SequentialInit(&model, 2, 5)
	testing.expect(t, ok)
	if !ok { return }
	item.storage = Conv2DStorage(4){}
	conv = &item.storage.(Conv2DStorage(4))
	conv.weightData[0], conv.weightGrad[0], conv.biasData[0] = 3, 3, 3
	ok = SequentialAddDropout(&model, 0.25)
	testing.expect(t, ok)
	if !ok { return }
	storage = &item.storage.(DropoutStorage(4, 32))
	for value in storage.maskData { testing.expect(t, value == 0) }
}
