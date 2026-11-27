package nn

import "../core"
import "../data"
import "../rl"
import "core:math"
import "core:mem"
import "core:testing"

PPOOwnedAdamTestAllocator :: struct {
	backing: mem.Allocator,
	attempts, allocations, freeCalls, frees: int,
	failAt, pointerAndErrorAt, failFreeAt: int,
	failWithNil: bool,
	sizes, alignments: [3]int,
	allocated: [3]rawptr,
	freed: [6]rawptr,
}

PPOOwnedAdamTestAllocatorProc :: proc(
	data: rawptr, mode: mem.Allocator_Mode, size, alignment: int,
	oldMemory: rawptr, oldSize: int, loc := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	state := (^PPOOwnedAdamTestAllocator)(data)
	if mode == .Alloc {
		state.attempts += 1
		if state.attempts <= len(state.sizes) {
			state.sizes[state.attempts-1], state.alignments[state.attempts-1] = size, alignment
		}
		if state.attempts == state.failAt {
			if state.failWithNil { return nil, nil }
			return nil, .Out_Of_Memory
		}
		memory, err := state.backing.procedure(state.backing.data, mode, size, alignment, oldMemory, oldSize, loc)
		if raw_data(memory) != nil {
			state.allocations += 1
			if state.allocations <= len(state.allocated) { state.allocated[state.allocations-1] = rawptr(raw_data(memory)) }
			if state.attempts == state.pointerAndErrorAt { return memory, .Out_Of_Memory }
		}
		return memory, err
	}
	if mode == .Free {
		state.freeCalls += 1
		if state.freeCalls <= len(state.freed) { state.freed[state.freeCalls-1] = oldMemory }
		if state.freeCalls == state.failFreeAt { return nil, .Invalid_Argument }
		memory, err := state.backing.procedure(state.backing.data, mode, size, alignment, oldMemory, oldSize, loc)
		if err == nil { state.frees += 1 }
		return memory, err
	}
	return state.backing.procedure(state.backing.data, mode, size, alignment, oldMemory, oldSize, loc)
}

// Aliased returns deliberately violate the allocator contract; fake frees do
// not release the caller-owned memory used to exercise defensive checks.
PPOOwnedAdamTestAliasAllocator :: struct {
	backing: mem.Allocator,
	aliases: [3]rawptr,
	attempts, frees, fakeFrees: int,
}

PPOOwnedAdamTestAliasAllocatorProc :: proc(
	data: rawptr, mode: mem.Allocator_Mode, size, alignment: int,
	oldMemory: rawptr, oldSize: int, loc := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	state := (^PPOOwnedAdamTestAliasAllocator)(data)
	if mode == .Alloc {
		state.attempts += 1
		if state.attempts <= len(state.aliases) && state.aliases[state.attempts-1] != nil {
			return mem.slice_ptr((^u8)(state.aliases[state.attempts-1]), size), nil
		}
	}
	if mode == .Free {
		state.frees += 1
		for alias in state.aliases {
			if alias != nil && oldMemory == alias { state.fakeFrees += 1; return nil, nil }
		}
	}
	return state.backing.procedure(state.backing.data, mode, size, alignment, oldMemory, oldSize, loc)
}

PPOOwnedAdamTestExpectBytes :: proc(t: ^testing.T, address: rawptr, expected: []u8) {
	actual := mem.slice_ptr((^u8)(address), len(expected))
	for byte, index in expected { testing.expect(t, byte == actual[index]) }
}

PPOOwnedAdamTestSetup :: proc(
	policy: ^Sequential($policyLayers, $policyWidth, $policyBatch),
	value: ^Sequential($valueLayers, $valueWidth, $valueBatch),
) -> bool {
	return SequentialInit(policy, 1, 17) && SequentialAddDense(policy, 2) &&
		SequentialInit(value, 1, 29) && SequentialAddDense(value, 1)
}

PPOOwnedAdamTestModelsEqual :: proc(
	a: ^Sequential($maxLayers, $maxWidth, $batchCapacity),
	b: ^Sequential(maxLayers, maxWidth, batchCapacity),
) -> bool {
	aStorage, bStorage: [2*maxLayers]^core.Node
	aParameters, aOk := SequentialParameters(a, aStorage[:])
	bParameters, bOk := SequentialParameters(b, bStorage[:])
	if !aOk || !bOk || len(aParameters) != len(bParameters) { return false }
	for parameter, index in aParameters {
		other := bParameters[index]
		if len(parameter.value.data) != len(other.value.data) { return false }
		for item, element in parameter.value.data { if item != other.value.data[element] { return false } }
	}
	return true
}

@(test)
PPOOwnedAdamAllocationAndOrder :: proc(t: ^testing.T) {
	policy: Sequential(3, 3, 2)
	value: Sequential(2, 4, 3)
	ok := SequentialInit(&policy, 2, 17) && SequentialAddDense(&policy, 3) &&
		SequentialAddActivation(&policy, .Tanh) && SequentialAddDense(&policy, 2) &&
		SequentialInit(&value, 2, 29) && SequentialAddDense(&value, 3) && SequentialAddDense(&value, 1)
	testing.expect(t, ok)
	if !ok { return }
	policyBytes: [size_of(Sequential(3, 3, 2))]u8
	valueBytes: [size_of(Sequential(2, 4, 3))]u8
	copy(policyBytes[:], mem.slice_ptr((^u8)(rawptr(&policy)), len(policyBytes)))
	copy(valueBytes[:], mem.slice_ptr((^u8)(rawptr(&value)), len(valueBytes)))
	state := PPOOwnedAdamTestAllocator{backing = context.allocator}
	allocator := mem.Allocator{procedure = PPOOwnedAdamTestAllocatorProc, data = &state}
	owner: PPOOwnedAdam
	{
		context.allocator = allocator
		ok = PPOOwnedAdamInit(&owner, &policy, &value, 0.02, 0.8, 0.95, 1e-6)
	}
	testing.expect(t, ok)
	if !ok { return }
	defer PPOOwnedAdamDestroy(&owner)
	adam := PPOOwnedAdamOptimizer(&owner)
	parameters, first, second, storageOk := PPOOwnedAdamStorage(&owner)
	testing.expect(t, adam == &owner.optimizer && storageOk && len(parameters) == 8 && len(first) == 30 && len(second) == 30)
	testing.expect(t, state.attempts == 3 && state.allocations == 3 && state.frees == 0)
	testing.expect(t, state.sizes == [3]int{8*size_of(^core.Node), 30*size_of(f32), 30*size_of(f32)})
	testing.expect(t, state.alignments == [3]int{align_of(^core.Node), align_of(f32), align_of(f32)})
	if !storageOk || adam == nil { return }
	p0, p1 := TestDenseStorage(&policy.layers[0]), TestDenseStorage(&policy.layers[2])
	v0, v1 := TestDenseStorage(&value.layers[0]), TestDenseStorage(&value.layers[1])
	testing.expect(t, parameters[0] == &p0.weights && parameters[1] == &p0.bias && parameters[2] == &p1.weights && parameters[3] == &p1.bias)
	testing.expect(t, parameters[4] == &v0.weights && parameters[5] == &v0.bias && parameters[6] == &v1.weights && parameters[7] == &v1.bias)
	testing.expect(t, raw_data(adam.parameters) == raw_data(parameters) && raw_data(adam.firstMoment) == raw_data(first) && raw_data(adam.secondMoment) == raw_data(second))
	testing.expect(t, adam.step == 0 && adam.learningRate == 0.02 && adam.beta1 == 0.8 && adam.beta2 == 0.95 && adam.epsilon == 1e-6)
	for i in 0..<len(first) { testing.expect(t, first[i] == 0 && second[i] == 0) }
	PPOOwnedAdamTestExpectBytes(t, rawptr(&policy), policyBytes[:])
	PPOOwnedAdamTestExpectBytes(t, rawptr(&value), valueBytes[:])
	for parameter in parameters { for &gradient in parameter.grad.data { gradient = 1 } }
	beforePolicy, beforeValue := p0.weightData[0], v0.weightData[0]
	testing.expect(t, AdamStep(adam) && adam.step == 1 && p0.weightData[0] != beforePolicy && v0.weightData[0] != beforeValue)

	// Destruction uses the captured allocator and original slices, not Adam's
	// exposed (potentially shortened by checkpoint restoration) slices.
	adam.parameters, adam.firstMoment, adam.secondMoment = nil, nil, nil
	destroyed: bool
	{
		context.allocator = mem.nil_allocator()
		destroyed = PPOOwnedAdamDestroy(&owner)
	}
	testing.expect(t, destroyed && state.frees == 3 && state.freeCalls == 3 && PPOOwnedAdamOptimizer(&owner) == nil)
	_, _, _, storageOk = PPOOwnedAdamStorage(&owner)
	testing.expect(t, !storageOk && PPOOwnedAdamDestroy(&owner) && state.freeCalls == 3)
}

@(test)
PPOOwnedAdamEmptyAndOneSided :: proc(t: ^testing.T) {
	policy, value: Sequential(1, 2, 2)
	owner: PPOOwnedAdam
	ok := SequentialInit(&policy, 1) && SequentialAddActivation(&policy, .Tanh) &&
		SequentialInit(&value, 1) && SequentialAddActivation(&value, .Sigmoid) &&
		PPOOwnedAdamInit(&owner, &policy, &value, allocator = mem.nil_allocator())
	testing.expect(t, ok)
	if !ok { return }
	adam := PPOOwnedAdamOptimizer(&owner)
	parameters, first, second, storageOk := PPOOwnedAdamStorage(&owner)
	testing.expect(t, storageOk && len(parameters) == 0 && len(first) == 0 && len(second) == 0 && AdamStep(adam) && adam.step == 1)
	testing.expect(t, !PPOOptimizerValid(adam, parameters) && PPOOwnedAdamDestroy(&owner))

	// Each side may independently have zero parameters for Adam storage, but
	// PPOSequentialParametersAndNodes rejects that side for PPO itself.
	for policyEmpty in ([2]bool{false, true}) {
		if policyEmpty {
			ok = SequentialInit(&policy, 1) && SequentialAddActivation(&policy, .Tanh) &&
				SequentialInit(&value, 1) && SequentialAddDense(&value, 1)
		} else {
			ok = SequentialInit(&policy, 1) && SequentialAddDense(&policy, 2) &&
				SequentialInit(&value, 1) && SequentialAddActivation(&value, .Tanh)
		}
		state := PPOOwnedAdamTestAllocator{backing = context.allocator}
		allocator := mem.Allocator{procedure = PPOOwnedAdamTestAllocatorProc, data = &state}
		ok = ok && PPOOwnedAdamInit(&owner, &policy, &value, allocator = allocator)
		testing.expect(t, ok)
		if !ok { return }
		adam = PPOOwnedAdamOptimizer(&owner)
		expectedElements := 4
		if policyEmpty { expectedElements = 2 }
		testing.expect(t, len(adam.parameters) == 2 && len(adam.firstMoment) == expectedElements && state.attempts == 3)
		parameterScratch: [2]^core.Node
		nodeScratch: [4]^core.Node
		model := &value
		if policyEmpty { model = &policy }
		_, _, ppoOk := PPOSequentialParametersAndNodes(model, parameterScratch[:], nodeScratch[:])
		testing.expect(t, !ppoOk && AdamStep(adam) && PPOOwnedAdamDestroy(&owner) && state.frees == 3)
	}
}

@(test)
PPOOwnedAdamRejectsInvalidInputs :: proc(t: ^testing.T) {
	policy, value: Sequential(1, 2, 2)
	owner: PPOOwnedAdam
	ok := PPOOwnedAdamTestSetup(&policy, &value)
	testing.expect(t, ok)
	if !ok { return }
	policyBytes, valueBytes: [size_of(Sequential(1, 2, 2))]u8
	ownerBytes: [size_of(PPOOwnedAdam)]u8
	copy(policyBytes[:], mem.slice_ptr((^u8)(rawptr(&policy)), len(policyBytes)))
	copy(valueBytes[:], mem.slice_ptr((^u8)(rawptr(&value)), len(valueBytes)))
	copy(ownerBytes[:], mem.slice_ptr((^u8)(rawptr(&owner)), len(ownerBytes)))
	state := PPOOwnedAdamTestAllocator{backing = context.allocator}
	allocator := mem.Allocator{procedure = PPOOwnedAdamTestAllocatorProc, data = &state}
	testing.expect(t, !PPOOwnedAdamInit(nil, &policy, &value, allocator = allocator))
	testing.expect(t, !PPOOwnedAdamInit(&owner, (^Sequential(1, 2, 2))(nil), &value, allocator = allocator))
	testing.expect(t, !PPOOwnedAdamInit(&owner, &policy, (^Sequential(1, 2, 2))(nil), allocator = allocator))
	testing.expect(t, !PPOOwnedAdamInit(&owner, &policy, &policy, allocator = allocator))
	testing.expect(t, !PPOOwnedAdamInit(&owner, &policy, &value, learningRate = 0, allocator = allocator))
	testing.expect(t, !PPOOwnedAdamInit(&owner, &policy, &value, learningRate = math.inf_f32(1), allocator = allocator))
	testing.expect(t, !PPOOwnedAdamInit(&owner, &policy, &value, learningRate = math.nan_f32(), allocator = allocator))
	testing.expect(t, !PPOOwnedAdamInit(&owner, &policy, &value, beta1 = 1, allocator = allocator))
	testing.expect(t, !PPOOwnedAdamInit(&owner, &policy, &value, beta1 = -0.1, allocator = allocator))
	testing.expect(t, !PPOOwnedAdamInit(&owner, &policy, &value, beta2 = math.nan_f32(), allocator = allocator))
	testing.expect(t, !PPOOwnedAdamInit(&owner, &policy, &value, epsilon = 0, allocator = allocator))
	testing.expect(t, !PPOOwnedAdamInit(&owner, &policy, &value, epsilon = math.inf_f32(1), allocator = allocator))
	uninitialized: Sequential(1, 2, 2)
	testing.expect(t, !PPOOwnedAdamInit(&owner, &uninitialized, &value, allocator = allocator))
	testing.expect(t, !PPOOwnedAdamInit(&owner, &policy, &uninitialized, allocator = allocator))
	copiedPolicy, copiedValue := policy, value
	testing.expect(t, !PPOOwnedAdamInit(&owner, &copiedPolicy, &value, allocator = allocator))
	testing.expect(t, !PPOOwnedAdamInit(&owner, &policy, &copiedValue, allocator = allocator))
	mismatch: Sequential(1, 2, 2)
	testing.expect(t, SequentialInit(&mismatch, 2) && SequentialAddDense(&mismatch, 1))
	testing.expect(t, !PPOOwnedAdamInit(&owner, &policy, &mismatch, allocator = allocator))
	wrongValue: Sequential(1, 2, 2)
	testing.expect(t, SequentialInit(&wrongValue, 1) && SequentialAddDense(&wrongValue, 2))
	testing.expect(t, !PPOOwnedAdamInit(&owner, &policy, &wrongValue, allocator = allocator))
	softmax: Sequential(3, 2, 2)
	testing.expect(t, SequentialInit(&softmax, 1) && SequentialAddDense(&softmax, 2) &&
		SequentialAddActivation(&softmax, .Softmax) && SequentialAddDropout(&softmax))
	testing.expect(t, !PPOOwnedAdamInit(&owner, &softmax, &value, allocator = allocator))
	spatial: Sequential(1, 2, 2)
	testing.expect(t, SequentialInitSpatial(&spatial, 1, 1, 1) && SequentialAddActivation(&spatial, .Tanh))
	testing.expect(t, !PPOOwnedAdamInit(&owner, &spatial, &value, allocator = allocator))
	testing.expect(t, !PPOOwnedAdamInit(&owner, &policy, &spatial, allocator = allocator))
	testing.expect(t, state.attempts == 0 && PPOOwnedAdamOptimizer(&owner) == nil)
	PPOOwnedAdamTestExpectBytes(t, rawptr(&owner), ownerBytes[:])
	PPOOwnedAdamTestExpectBytes(t, rawptr(&policy), policyBytes[:])
	PPOOwnedAdamTestExpectBytes(t, rawptr(&value), valueBytes[:])
	testing.expect(t, !PPOOwnedAdamInit(&owner, &policy, &value, allocator = mem.nil_allocator()))
	testing.expect(t, PPOOwnedAdamDestroy(&owner))
}

@(test)
PPOOwnedAdamAllocationFailuresAreAtomic :: proc(t: ^testing.T) {
	policy, value: Sequential(1, 2, 2)
	ok := PPOOwnedAdamTestSetup(&policy, &value)
	testing.expect(t, ok)
	if !ok { return }
	policyBytes, valueBytes: [size_of(Sequential(1, 2, 2))]u8
	copy(policyBytes[:], mem.slice_ptr((^u8)(rawptr(&policy)), len(policyBytes)))
	copy(valueBytes[:], mem.slice_ptr((^u8)(rawptr(&value)), len(valueBytes)))
	for failAt in 1..=3 {
		for nilFailure in ([2]bool{false, true}) {
			owner: PPOOwnedAdam
			ownerBytes: [size_of(PPOOwnedAdam)]u8
			copy(ownerBytes[:], mem.slice_ptr((^u8)(rawptr(&owner)), len(ownerBytes)))
			state := PPOOwnedAdamTestAllocator{backing = context.allocator, failAt = failAt, failWithNil = nilFailure}
			allocator := mem.Allocator{procedure = PPOOwnedAdamTestAllocatorProc, data = &state}
			testing.expect(t, !PPOOwnedAdamInit(&owner, &policy, &value, allocator = allocator))
			testing.expect(t, state.attempts == failAt && state.allocations == failAt-1 && state.frees == failAt-1)
			PPOOwnedAdamTestExpectBytes(t, rawptr(&owner), ownerBytes[:])
			PPOOwnedAdamTestExpectBytes(t, rawptr(&policy), policyBytes[:])
			PPOOwnedAdamTestExpectBytes(t, rawptr(&value), valueBytes[:])
			testing.expect(t, PPOOwnedAdamOptimizer(&owner) == nil && PPOOwnedAdamDestroy(&owner))
		}
		owner: PPOOwnedAdam
		state := PPOOwnedAdamTestAllocator{backing = context.allocator, pointerAndErrorAt = failAt}
		allocator := mem.Allocator{procedure = PPOOwnedAdamTestAllocatorProc, data = &state}
		testing.expect(t, !PPOOwnedAdamInit(&owner, &policy, &value, allocator = allocator))
		testing.expect(t, state.attempts == failAt && state.allocations == failAt && state.frees == failAt)
		testing.expect(t, PPOOwnedAdamOptimizer(&owner) == nil && PPOOwnedAdamDestroy(&owner))
		PPOOwnedAdamTestExpectBytes(t, rawptr(&policy), policyBytes[:])
		PPOOwnedAdamTestExpectBytes(t, rawptr(&value), valueBytes[:])
	}
}

@(test)
PPOOwnedAdamRejectsModelAndParameterAliases :: proc(t: ^testing.T) {
	policy, value: Sequential(1, 2, 2)
	owner: PPOOwnedAdam
	ok := PPOOwnedAdamTestSetup(&policy, &value)
	testing.expect(t, ok)
	if !ok { return }
	policyBytes, valueBytes: [size_of(Sequential(1, 2, 2))]u8
	copy(policyBytes[:], mem.slice_ptr((^u8)(rawptr(&policy)), len(policyBytes)))
	copy(valueBytes[:], mem.slice_ptr((^u8)(rawptr(&value)), len(valueBytes)))
	state := PPOOwnedAdamTestAllocator{backing = context.allocator}
	allocator := mem.Allocator{procedure = PPOOwnedAdamTestAllocatorProc, data = &state}
	partial := (^Sequential(1, 2, 2))(rawptr(uintptr(rawptr(&policy))+uintptr(align_of(Sequential(1, 2, 2)))))
	testing.expect(t, !PPOOwnedAdamInit(&owner, &policy, partial, allocator = allocator))
	testing.expect(t, !PPOOwnedAdamInit((^PPOOwnedAdam)(rawptr(&policy)), &policy, &value, allocator = allocator))
	testing.expect(t, !PPOOwnedAdamInit((^PPOOwnedAdam)(rawptr(&value)), &policy, &value, allocator = allocator))
	p, v := &TestDenseStorage(&policy.layers[0]).weights, &TestDenseStorage(&value.layers[0]).weights
	pValue, pGrad, vValue, vGrad := p.value.data, p.grad.data, v.value.data, v.grad.data
	shared: [8]f32
	for policyGradient in ([2]bool{false, true}) {
		for valueGradient in ([2]bool{false, true}) {
			if policyGradient { p.grad.data = shared[:2] } else { p.value.data = shared[:2] }
			if valueGradient { v.grad.data = shared[1:2] } else { v.value.data = shared[1:2] }
			_, _, pOk := SequentialAdamRequirements(&policy)
			_, _, vOk := SequentialAdamRequirements(&value)
			testing.expect(t, pOk && vOk && !PPOOwnedAdamInit(&owner, &policy, &value, allocator = allocator))
			p.value.data, p.grad.data, v.value.data, v.grad.data = pValue, pGrad, vValue, vGrad
		}
	}
	// Rebinding into any part of the other model or the entire owner is invalid,
	// even when it does not overlap a trainable tensor.
	p.value.data = value.inputData[:2]
	testing.expect(t, !PPOOwnedAdamInit(&owner, &policy, &value, allocator = allocator))
	p.value.data = pValue
	v.grad.data = policy.inputGrad[:1]
	testing.expect(t, !PPOOwnedAdamInit(&owner, &policy, &value, allocator = allocator))
	v.grad.data = vGrad
	p.value.data = mem.slice_ptr((^f32)(rawptr(&owner.allocator)), 2)
	testing.expect(t, !PPOOwnedAdamInit(&owner, &policy, &value, allocator = allocator))
	p.value.data = pValue
	v.grad.data = mem.slice_ptr((^f32)(rawptr(&owner.allocator)), 1)
	testing.expect(t, !PPOOwnedAdamInit(&owner, &policy, &value, allocator = allocator))
	v.grad.data = vGrad
	// Internal tensor overlap and duplicate/shared node wiring are rejected.
	bias := &TestDenseStorage(&policy.layers[0]).bias
	oldBias := bias.value.data
	bias.value.data = p.value.data
	testing.expect(t, !PPOOwnedAdamInit(&owner, &policy, &value, allocator = allocator))
	bias.value.data = oldBias
	layer := policy.layers[0].layer.(^Dense)
	oldWeights := layer.weights
	layer.weights = &TestDenseStorage(&policy.layers[0]).bias
	testing.expect(t, !PPOOwnedAdamInit(&owner, &policy, &value, allocator = allocator))
	layer.weights = v
	testing.expect(t, !PPOOwnedAdamInit(&owner, &policy, &value, allocator = allocator))
	layer.weights = oldWeights
	testing.expect(t, state.attempts == 0)
	PPOOwnedAdamTestExpectBytes(t, rawptr(&policy), policyBytes[:])
	PPOOwnedAdamTestExpectBytes(t, rawptr(&value), valueBytes[:])

	// Non-overlapping external parameter buffers are accepted and updated.
	externalPolicy := [2]f32{1, 2}
	externalGradient := [1]f32{3}
	p.value.data, v.grad.data = externalPolicy[:], externalGradient[:]
	p.grad.data[0] = 2
	oldValue := v.value.data[0]
	ok = PPOOwnedAdamInit(&owner, &policy, &value, allocator = allocator)
	testing.expect(t, ok)
	if ok {
		adam := PPOOwnedAdamOptimizer(&owner)
		testing.expect(t, AdamStep(adam) && adam.step == 1 && externalPolicy[0] != 1 && v.value.data[0] != oldValue)
		testing.expect(t, PPOOwnedAdamDestroy(&owner) && state.frees == 3)
	}
	p.value.data, v.grad.data = pValue, vGrad
}

@(test)
PPOOwnedAdamRejectsAllocatorAliases :: proc(t: ^testing.T) {
	policy, value: Sequential(1, 2, 2)
	owner: PPOOwnedAdam
	ok := PPOOwnedAdamTestSetup(&policy, &value)
	testing.expect(t, ok)
	if !ok { return }
	backing: [16]u64
	backing[0] = 0x400000003f800000
	before := backing
	weights := &TestDenseStorage(&policy.layers[0]).weights
	original := weights.value.data
	weights.value.data = mem.slice_ptr((^f32)(rawptr(&backing)), 2)
	policyBytes, valueBytes: [size_of(Sequential(1, 2, 2))]u8
	ownerBytes: [size_of(PPOOwnedAdam)]u8
	copy(policyBytes[:], mem.slice_ptr((^u8)(rawptr(&policy)), len(policyBytes)))
	copy(valueBytes[:], mem.slice_ptr((^u8)(rawptr(&value)), len(valueBytes)))
	copy(ownerBytes[:], mem.slice_ptr((^u8)(rawptr(&owner)), len(ownerBytes)))
	for target in ([4]rawptr{rawptr(&owner), rawptr(&policy), rawptr(&value), rawptr(&backing)}) {
		for attempt in 0..<3 {
			state := PPOOwnedAdamTestAliasAllocator{backing = context.allocator}
			state.aliases[attempt] = target
			allocator := mem.Allocator{procedure = PPOOwnedAdamTestAliasAllocatorProc, data = &state}
			testing.expect(t, !PPOOwnedAdamInit(&owner, &policy, &value, allocator = allocator))
			testing.expect(t, state.attempts == 3 && state.frees == 3 && state.fakeFrees == 1)
			PPOOwnedAdamTestExpectBytes(t, rawptr(&owner), ownerBytes[:])
			PPOOwnedAdamTestExpectBytes(t, rawptr(&policy), policyBytes[:])
			PPOOwnedAdamTestExpectBytes(t, rawptr(&value), valueBytes[:])
			testing.expect(t, backing == before)
		}
	}
	// Detect partially overlapping returned allocations before writing to either.
	overlap: [16]u64
	state := PPOOwnedAdamTestAliasAllocator{backing = context.allocator}
	state.aliases[0], state.aliases[1] = rawptr(&overlap[0]), rawptr(&overlap[1])
	allocator := mem.Allocator{procedure = PPOOwnedAdamTestAliasAllocatorProc, data = &state}
	testing.expect(t, !PPOOwnedAdamInit(&owner, &policy, &value, allocator = allocator))
	testing.expect(t, state.attempts == 3 && state.frees == 3 && state.fakeFrees == 2 && overlap == [16]u64{})
	weights.value.data = original
}

@(test)
PPOOwnedAdamDestroyCopiesAndRetries :: proc(t: ^testing.T) {
	policy, value: Sequential(1, 2, 2)
	ok := PPOOwnedAdamTestSetup(&policy, &value)
	testing.expect(t, ok)
	if !ok { return }
	testing.expect(t, PPOOwnedAdamOptimizer(nil) == nil && !PPOOwnedAdamDestroy(nil))
	_, _, _, nilStorageOk := PPOOwnedAdamStorage(nil)
	testing.expect(t, !nilStorageOk)
	for failAt in 1..=3 {
		owner: PPOOwnedAdam
		state := PPOOwnedAdamTestAllocator{backing = context.allocator, failFreeAt = failAt}
		allocator := mem.Allocator{procedure = PPOOwnedAdamTestAllocatorProc, data = &state}
		ok = PPOOwnedAdamInit(&owner, &policy, &value, allocator = allocator)
		testing.expect(t, ok)
		if !ok { return }
		adam := PPOOwnedAdamOptimizer(&owner)
		for parameter in adam.parameters { for &gradient in parameter.grad.data { gradient = 1 } }
		testing.expect(t, AdamStep(adam) && adam.step == 1)
		copied := owner
		ownerBytes, copyBytes: [size_of(PPOOwnedAdam)]u8
		copy(ownerBytes[:], mem.slice_ptr((^u8)(rawptr(&owner)), len(ownerBytes)))
		copy(copyBytes[:], mem.slice_ptr((^u8)(rawptr(&copied)), len(copyBytes)))
		_, _, _, copiedStorageOk := PPOOwnedAdamStorage(&copied)
		testing.expect(t, PPOOwnedAdamOptimizer(&copied) == nil && !copiedStorageOk && !PPOOwnedAdamDestroy(&copied))
		testing.expect(t, !PPOOwnedAdamInit(&copied, &policy, &value, allocator = allocator))
		testing.expect(t, !PPOOwnedAdamInit(&owner, &policy, &value, allocator = allocator))
		PPOOwnedAdamTestExpectBytes(t, rawptr(&owner), ownerBytes[:])
		PPOOwnedAdamTestExpectBytes(t, rawptr(&copied), copyBytes[:])
		testing.expect(t, !PPOOwnedAdamDestroy(&owner) && owner.destroying && state.freeCalls == failAt && state.frees == failAt-1)
		testing.expect(t, state.freed[failAt-1] == state.allocated[3-failAt])
		_, _, _, storageOk := PPOOwnedAdamStorage(&owner)
		testing.expect(t, !storageOk && PPOOwnedAdamOptimizer(&owner) == nil && !PPOOwnedAdamInit(&owner, &policy, &value, allocator = allocator))
		testing.expect(t, PPOOwnedAdamDestroy(&owner) && state.freeCalls == 4 && state.frees == 3)
		testing.expect(t, state.freed[failAt] == state.allocated[3-failAt])
		testing.expect(t, PPOOwnedAdamDestroy(&owner) && state.freeCalls == 4 && !PPOOwnedAdamDestroy(&copied))
		testing.expect(t, !PPOOwnedAdamInit(&copied, &policy, &value, allocator = allocator))
		PPOOwnedAdamTestExpectBytes(t, rawptr(&copied), copyBytes[:])
		ok = PPOOwnedAdamInit(&owner, &policy, &value, allocator = allocator)
		testing.expect(t, ok)
		if !ok { return }
		fresh := PPOOwnedAdamOptimizer(&owner)
		testing.expect(t, fresh == adam && fresh.step == 0 && fresh.learningRate == 0.001 && fresh.beta1 == 0.9 && fresh.beta2 == 0.999 && fresh.epsilon == 1e-8)
		for i in 0..<len(fresh.firstMoment) { testing.expect(t, fresh.firstMoment[i] == 0 && fresh.secondMoment[i] == 0) }
		testing.expect(t, PPOOwnedAdamDestroy(&owner) && state.attempts == 6 && state.frees == 6)
	}
}

@(test)
PPOOwnedAdamFailedRollbackAndInitRetry :: proc(t: ^testing.T) {
	policy, value: Sequential(1, 2, 2)
	owner: PPOOwnedAdam
	ok := PPOOwnedAdamTestSetup(&policy, &value)
	testing.expect(t, ok)
	if !ok { return }
	policyBytes, valueBytes: [size_of(Sequential(1, 2, 2))]u8
	ownerBytes: [size_of(PPOOwnedAdam)]u8
	copy(policyBytes[:], mem.slice_ptr((^u8)(rawptr(&policy)), len(policyBytes)))
	copy(valueBytes[:], mem.slice_ptr((^u8)(rawptr(&value)), len(valueBytes)))
	copy(ownerBytes[:], mem.slice_ptr((^u8)(rawptr(&owner)), len(ownerBytes)))
	state := PPOOwnedAdamTestAllocator{backing = context.allocator, failAt = 3, failFreeAt = 1}
	allocator := mem.Allocator{procedure = PPOOwnedAdamTestAllocatorProc, data = &state}
	testing.expect(t, !PPOOwnedAdamInit(&owner, &policy, &value, allocator = allocator))
	testing.expect(t, state.allocations == 2 && state.freeCalls == 2 && state.frees == 1 && state.freed[0] == state.allocated[1])
	PPOOwnedAdamTestExpectBytes(t, rawptr(&owner), ownerBytes[:])
	PPOOwnedAdamTestExpectBytes(t, rawptr(&policy), policyBytes[:])
	PPOOwnedAdamTestExpectBytes(t, rawptr(&value), valueBytes[:])
	// Rollback has no live owner to retry through; this test allocator exposes
	// its failed free so the test can recover it explicitly.
	testing.expect(t, mem.free(state.allocated[1], allocator) == nil && state.frees == 2)
	ok = PPOOwnedAdamInit(&owner, &policy, &value, allocator = allocator)
	testing.expect(t, ok)
	if !ok { return }
	testing.expect(t, PPOOwnedAdamOptimizer(&owner) != nil && PPOOwnedAdamDestroy(&owner) && state.allocations == 5 && state.frees == 5)
}

@(test)
PPOOwnedAdamModelMismatchAndArchitectureChange :: proc(t: ^testing.T) {
	policy, value, otherPolicy, otherValue: Sequential(2, 2, 2)
	owner: PPOOwnedAdam
	ok := PPOOwnedAdamTestSetup(&policy, &value) && PPOOwnedAdamTestSetup(&otherPolicy, &otherValue) &&
		PPOOwnedAdamInit(&owner, &policy, &value)
	testing.expect(t, ok)
	if !ok { return }
	defer PPOOwnedAdamDestroy(&owner)
	adam := PPOOwnedAdamOptimizer(&owner)
	config := PPOConfig{0.2, 0.01, 0.5, 1}
	otherBytes, valueBytes: [size_of(Sequential(2, 2, 2))]u8
	ownerBytes: [size_of(PPOOwnedAdam)]u8
	copy(otherBytes[:], mem.slice_ptr((^u8)(rawptr(&otherPolicy)), len(otherBytes)))
	copy(valueBytes[:], mem.slice_ptr((^u8)(rawptr(&value)), len(valueBytes)))
	copy(ownerBytes[:], mem.slice_ptr((^u8)(rawptr(&owner)), len(ownerBytes)))
	_, trained := PPOOwnedAdamTestUpdate(&otherPolicy, &value, adam, config)
	testing.expect(t, !trained && adam.step == 0 && !PPOOwnedAdamInit(&owner, &otherPolicy, &otherValue))
	checkpoint, policyScratch, valueScratch: [1024]u8
	_, saved := PPOCheckpointWrite(&otherPolicy, &value, adam,
		PPOTrainingState{policyRandomState = 1}, config, PPOFitConfig{epochs = 1},
		checkpoint[:], policyScratch[:], valueScratch[:])
	testing.expect(t, !saved)
	PPOOwnedAdamTestExpectBytes(t, rawptr(&otherPolicy), otherBytes[:])
	PPOOwnedAdamTestExpectBytes(t, rawptr(&value), valueBytes[:])
	PPOOwnedAdamTestExpectBytes(t, rawptr(&owner), ownerBytes[:])
	testing.expect(t, PPOOwnedAdamDestroy(&owner) && SequentialAddDense(&policy, 2))
	ok = PPOOwnedAdamInit(&owner, &policy, &value)
	testing.expect(t, ok)
	if !ok { return }
	adam = PPOOwnedAdamOptimizer(&owner)
	testing.expect(t, len(adam.parameters) == 6 && len(adam.firstMoment) == 12 &&
		adam.parameters[2] == &TestDenseStorage(&policy.layers[1]).weights &&
		adam.parameters[4] == &TestDenseStorage(&value.layers[0]).weights)
	_, trained = PPOOwnedAdamTestUpdate(&policy, &value, adam, config)
	testing.expect(t, trained && adam.step == 1)
}

PPOOwnedAdamTestUpdate :: proc(
	policy: ^Sequential($policyLayers, $policyWidth, $policyBatch),
	value: ^Sequential($valueLayers, $valueWidth, $valueBatch),
	adam: ^Adam,
	config: PPOConfig,
) -> (PPOStats, bool) {
	observations := [2]f32{0.25, 0.75}
	actions := [2]int{0, 1}
	legal := [4]bool{true, true, true, true}
	oldLogs := [2]f64{-0.6931471805599453, -0.6931471805599453}
	advantages := [2]f32{1, -1}
	returns := [2]f32{0.5, -0.25}
	return SequentialPPOTrainStep(policy, value, observations[:], actions[:], legal[:], oldLogs[:], advantages[:], returns[:], config, adam, 0.5)
}

@(test)
PPOOwnedAdamSpatialModels :: proc(t: ^testing.T) {
	policy: Sequential(4, 4, 2)
	value: Sequential(3, 4, 3)
	owner: PPOOwnedAdam
	ok := SequentialInitSpatial(&policy, 2, 2, 1, 7) && SequentialAddConv2D(&policy, 2, 2, 1) &&
		SequentialAddFlatten(&policy) && SequentialAddDense(&policy, 2) &&
		SequentialInitSpatial(&value, 2, 2, 1, 11) && SequentialAddConv2D(&value, 2, 2, 1) &&
		SequentialAddFlatten(&value) && SequentialAddDense(&value, 1) && PPOOwnedAdamInit(&owner, &policy, &value)
	testing.expect(t, ok)
	if !ok { return }
	defer PPOOwnedAdamDestroy(&owner)
	adam := PPOOwnedAdamOptimizer(&owner)
	pConv := &policy.layers[0].storage.(Conv2DStorage(4))
	vConv := &value.layers[0].storage.(Conv2DStorage(4))
	testing.expect(t, len(adam.parameters) == 8 && len(adam.firstMoment) == 16 &&
		adam.parameters[0] == &pConv.weights && adam.parameters[1] == &pConv.bias &&
		adam.parameters[4] == &vConv.weights && adam.parameters[5] == &vConv.bias)
	observations := [4]f32{1, 0.5, -0.25, 0.75}
	actions := [1]int{0}
	legal := [2]bool{true, true}
	oldLogs := [1]f64{-0.6931471805599453}
	advantages := [1]f32{0.75}
	returns := [1]f32{1}
	_, trained := SequentialPPOTrainStep(
		&policy, &value, observations[:], actions[:], legal[:], oldLogs[:], advantages[:], returns[:],
		PPOConfig{0.2, 0.01, 0.5, 1}, adam,
	)
	testing.expect(t, trained && adam.step == 1)
}

@(test)
PPOOwnedAdamStatefulFit :: proc(t: ^testing.T) {
	policy, value: Sequential(1, 2, 2)
	owner: PPOOwnedAdam
	ok := PPOOwnedAdamTestSetup(&policy, &value) && PPOOwnedAdamInit(&owner, &policy, &value, learningRate = 0.01)
	testing.expect(t, ok)
	if !ok { return }
	defer PPOOwnedAdamDestroy(&owner)
	observations: [4]f32
	actions: [4]int
	rewards, values, next, advantages, returns: [4]f32
	logs: [4]f64
	legal: [8]bool
	terminated, truncated: [4]bool
	buffer: rl.RolloutBuffer
	rolloutStorage := rl.RolloutStorage{
		observations = observations[:], actions = actions[:], rewards = rewards[:], values = values[:],
		nextValues = next[:], oldLogProbabilities = logs[:], legalActions = legal[:],
		terminated = terminated[:], truncated = truncated[:], advantages = advantages[:], returns = returns[:],
	}
	state: PPOTrainingState
	ok = rl.RolloutBufferInit(&buffer, rolloutStorage, 4, 1, 2) && PPOTrainingStateInit(&state, 123, 456) &&
		PPOCheckpointTestCollect(&policy, &value, &state, &buffer)
	testing.expect(t, ok)
	if !ok { return }
	indices: [4]int
	batchObs: [2]f32
	batchActions: [2]int
	batchLegal: [4]bool
	batchLogs: [2]f64
	batchAdv, batchReturns: [2]f32
	epochMetrics: [2]PPOEpochStats
	fitStorage := PPOFitStorage{
		indices = indices[:], observations = batchObs[:], actions = batchActions[:], legalActions = batchLegal[:],
		oldLogProbabilities = batchLogs[:], advantages = batchAdv[:], returns = batchReturns[:], epochMetrics = epochMetrics[:],
	}
	adam := PPOOwnedAdamOptimizer(&owner)
	beforePolicy := TestDenseStorage(&policy.layers[0]).weightData
	beforeValue := TestDenseStorage(&value.layers[0]).weightData
	stats, fitOk := SequentialPPOFitStateful(
		&policy, &value, &buffer, &state, PPOConfig{0.2, 0.01, 0.5, 1},
		PPOFitConfig{epochs = 2, batchSize = 2, finalLearningRate = 0.003}, adam, fitStorage,
	)
	testing.expect(t, fitOk && stats.updates == 4 && state.updateCount == 4 && state.rolloutCount == 1 && adam.step == 4)
	testing.expect(t, fitOk && adam.learningRate == 0.003 && TestDenseStorage(&policy.layers[0]).weightData != beforePolicy && TestDenseStorage(&value.layers[0]).weightData != beforeValue)
}

@(test)
PPOOwnedAdamCheckpointContinuityAndCapacity :: proc(t: ^testing.T) {
	smallPolicy, smallValue, largePolicy, largeValue, destPolicy, destValue: Sequential(3, 3, 2)
	smallOwner, largeOwner, destOwner: PPOOwnedAdam
	ok := PPOOwnedAdamTestSetup(&smallPolicy, &smallValue) &&
		SequentialInit(&largePolicy, 1, 7) && SequentialAddDense(&largePolicy, 3) &&
		SequentialAddActivation(&largePolicy, .Tanh) && SequentialAddDense(&largePolicy, 2) &&
		SequentialInit(&largeValue, 1, 11) && SequentialAddDense(&largeValue, 3) &&
		SequentialAddActivation(&largeValue, .Tanh) && SequentialAddDense(&largeValue, 1) &&
		SequentialInit(&destPolicy, 1, 13) && SequentialAddDense(&destPolicy, 3) &&
		SequentialAddActivation(&destPolicy, .Tanh) && SequentialAddDense(&destPolicy, 2) &&
		SequentialInit(&destValue, 1, 19) && SequentialAddDense(&destValue, 3) &&
		SequentialAddActivation(&destValue, .Tanh) && SequentialAddDense(&destValue, 1)
	testing.expect(t, ok)
	if !ok { return }
	external := [3]f32{1, 2, 3}
	TestDenseStorage(&destPolicy.layers[0]).weights.value.data = external[:]
	ok = PPOOwnedAdamInit(&smallOwner, &smallPolicy, &smallValue, 0.02, 0.8, 0.95, 1e-6)
	testing.expect(t, ok)
	if !ok { return }
	defer PPOOwnedAdamDestroy(&smallOwner)
	ok = PPOOwnedAdamInit(&largeOwner, &largePolicy, &largeValue, learningRate = 0.005)
	testing.expect(t, ok)
	if !ok { return }
	defer PPOOwnedAdamDestroy(&largeOwner)
	ok = PPOOwnedAdamInit(&destOwner, &destPolicy, &destValue)
	testing.expect(t, ok)
	if !ok { return }
	defer PPOOwnedAdamDestroy(&destOwner)
	smallAdam, largeAdam, destAdam := PPOOwnedAdamOptimizer(&smallOwner), PPOOwnedAdamOptimizer(&largeOwner), PPOOwnedAdamOptimizer(&destOwner)
	config := PPOConfig{0.2, 0.01, 0.5, 1}
	fitConfig := PPOFitConfig{epochs = 2, batchSize = 2, maxGradientNorm = 0.5, finalLearningRate = 0.003}
	state := PPOTrainingState{updateCount = 3, rolloutCount = 2, policyRandomState = 17, shuffleRandomState = 29}
	_, smallTrained := PPOOwnedAdamTestUpdate(&smallPolicy, &smallValue, smallAdam, config)
	_, largeTrained := PPOOwnedAdamTestUpdate(&largePolicy, &largeValue, largeAdam, config)
	testing.expect(t, smallTrained && largeTrained)
	if !smallTrained || !largeTrained { return }
	smallData, largeData, roundTrip, policyScratch, valueScratch: [4096]u8
	smallSize, smallSaved := PPOCheckpointWrite(&smallPolicy, &smallValue, smallAdam, state, config, fitConfig, smallData[:], policyScratch[:], valueScratch[:])
	largeSize, largeSaved := PPOCheckpointWrite(&largePolicy, &largeValue, largeAdam, state, config, fitConfig, largeData[:], policyScratch[:], valueScratch[:])
	testing.expect(t, smallSaved && largeSaved)
	if !smallSaved || !largeSaved { return }
	parameters, first, second, storageOk := PPOOwnedAdamStorage(&destOwner)
	testing.expect(t, storageOk && len(parameters) == 8 && len(first) == 24 && len(second) == 24)
	if !storageOk { return }
	destPolicyBytes, destValueBytes: [size_of(Sequential(3, 3, 2))]u8
	destOwnerBytes: [size_of(PPOOwnedAdam)]u8
	copy(destPolicyBytes[:], mem.slice_ptr((^u8)(rawptr(&destPolicy)), len(destPolicyBytes)))
	copy(destValueBytes[:], mem.slice_ptr((^u8)(rawptr(&destValue)), len(destValueBytes)))
	copy(destOwnerBytes[:], mem.slice_ptr((^u8)(rawptr(&destOwner)), len(destOwnerBytes)))
	oldParameters: [8]^core.Node
	oldFirst, oldSecond: [24]f32
	copy(oldParameters[:], parameters); copy(oldFirst[:], first); copy(oldSecond[:], second)
	_, _, _, _, badRead := PPOCheckpointRead(&destPolicy, &destValue, smallData[:smallSize-1], destAdam, parameters, first, second)
	testing.expect(t, !badRead && external == [3]f32{1, 2, 3})
	PPOOwnedAdamTestExpectBytes(t, rawptr(&destPolicy), destPolicyBytes[:])
	PPOOwnedAdamTestExpectBytes(t, rawptr(&destValue), destValueBytes[:])
	PPOOwnedAdamTestExpectBytes(t, rawptr(&destOwner), destOwnerBytes[:])
	for index in 0..<len(parameters) { testing.expect(t, parameters[index] == oldParameters[index]) }
	for index in 0..<len(first) { testing.expect(t, first[index] == oldFirst[index] && second[index] == oldSecond[index]) }

	restoredState, restoredConfig, restoredFit, restoredOptimizer, loaded := PPOCheckpointRead(
		&destPolicy, &destValue, smallData[:smallSize], destAdam, parameters, first, second,
	)
	testing.expect(t, loaded && restoredState == state && restoredConfig == config && restoredFit == fitConfig)
	if !loaded { return }
	restoredPointer, isAdam := restoredOptimizer.(^Adam)
	testing.expect(t, isAdam && restoredPointer == destAdam && PPOOwnedAdamOptimizer(&destOwner) == destAdam && destAdam.step == smallAdam.step)
	testing.expect(t, destAdam.learningRate == smallAdam.learningRate && destAdam.beta1 == smallAdam.beta1 && destAdam.beta2 == smallAdam.beta2 && destAdam.epsilon == smallAdam.epsilon)
	testing.expect(t, len(destAdam.parameters) == 4 && len(destAdam.firstMoment) == 6 && len(destAdam.secondMoment) == 6)
	testing.expect(t, destAdam.parameters[0] == &TestDenseStorage(&destPolicy.layers[0]).weights && destAdam.parameters[2] == &TestDenseStorage(&destValue.layers[0]).weights)
	testing.expect(t, raw_data(TestDenseStorage(&destPolicy.layers[0]).weights.value.data) == raw_data(TestDenseStorage(&destPolicy.layers[0]).weightData[:]) && external == [3]f32{1, 2, 3})
	for index in 0..<len(destAdam.firstMoment) { testing.expect(t, destAdam.firstMoment[index] == smallAdam.firstMoment[index] && destAdam.secondMoment[index] == smallAdam.secondMoment[index]) }
	size, saved := PPOCheckpointWrite(&destPolicy, &destValue, destAdam, restoredState, restoredConfig, restoredFit, roundTrip[:], policyScratch[:], valueScratch[:])
	testing.expect(t, saved && size == smallSize)
	if saved && size == smallSize { for byte, index in smallData[:smallSize] { testing.expect(t, byte == roundTrip[index]) } }
	statsA, trainedA := PPOOwnedAdamTestUpdate(&smallPolicy, &smallValue, smallAdam, config)
	statsB, trainedB := PPOOwnedAdamTestUpdate(&destPolicy, &destValue, destAdam, restoredConfig)
	testing.expect(t, trainedA && trainedB && statsA == statsB && smallAdam.step == destAdam.step)
	testing.expect(t, PPOOwnedAdamTestModelsEqual(&smallPolicy, &destPolicy) && PPOOwnedAdamTestModelsEqual(&smallValue, &destValue))
	for index in 0..<len(destAdam.firstMoment) { testing.expect(t, destAdam.firstMoment[index] == smallAdam.firstMoment[index] && destAdam.secondMoment[index] == smallAdam.secondMoment[index]) }

	// The small owner cannot restore the large checkpoint, atomically.
	smallParameters, smallFirst, smallSecond, smallStorageOk := PPOOwnedAdamStorage(&smallOwner)
	testing.expect(t, smallStorageOk && len(smallParameters) == 4 && len(smallFirst) == 6)
	if !smallStorageOk { return }
	smallPolicyBytes, smallValueBytes: [size_of(Sequential(3, 3, 2))]u8
	smallOwnerBytes: [size_of(PPOOwnedAdam)]u8
	copy(smallPolicyBytes[:], mem.slice_ptr((^u8)(rawptr(&smallPolicy)), len(smallPolicyBytes)))
	copy(smallValueBytes[:], mem.slice_ptr((^u8)(rawptr(&smallValue)), len(smallValueBytes)))
	copy(smallOwnerBytes[:], mem.slice_ptr((^u8)(rawptr(&smallOwner)), len(smallOwnerBytes)))
	oldSmallFirst, oldSmallSecond: [6]f32
	copy(oldSmallFirst[:], smallFirst); copy(oldSmallSecond[:], smallSecond)
	_, _, _, _, tooLarge := PPOCheckpointRead(&smallPolicy, &smallValue, largeData[:largeSize], smallAdam, smallParameters, smallFirst, smallSecond)
	testing.expect(t, !tooLarge)
	PPOOwnedAdamTestExpectBytes(t, rawptr(&smallPolicy), smallPolicyBytes[:])
	PPOOwnedAdamTestExpectBytes(t, rawptr(&smallValue), smallValueBytes[:])
	PPOOwnedAdamTestExpectBytes(t, rawptr(&smallOwner), smallOwnerBytes[:])
	for index in 0..<len(smallFirst) { testing.expect(t, smallFirst[index] == oldSmallFirst[index] && smallSecond[index] == oldSmallSecond[index]) }

	// Full owner storage remains available for a later larger restore.
	fullParameters, fullFirst, fullSecond, fullOk := PPOOwnedAdamStorage(&destOwner)
	testing.expect(t, fullOk && len(fullParameters) == 8 && len(fullFirst) == 24 && len(fullSecond) == 24 &&
		raw_data(fullParameters) == raw_data(parameters) && raw_data(fullFirst) == raw_data(first) && raw_data(fullSecond) == raw_data(second))
	if !fullOk { return }
	_, _, _, _, loaded = PPOCheckpointRead(&destPolicy, &destValue, largeData[:largeSize], destAdam, fullParameters, fullFirst, fullSecond)
	testing.expect(t, loaded && len(destAdam.parameters) == 8 && len(destAdam.firstMoment) == 24 && destAdam.step == largeAdam.step)
	if !loaded { return }
	size, saved = PPOCheckpointWrite(&destPolicy, &destValue, destAdam, state, config, fitConfig, roundTrip[:], policyScratch[:], valueScratch[:])
	testing.expect(t, saved && size == largeSize)
	if saved && size == largeSize { for byte, index in largeData[:largeSize] { testing.expect(t, byte == roundTrip[index]) } }

	// Equal-sized optimizer storage is not enough when a model's type capacities differ.
	wrongPolicy: Sequential(2, 3, 2)
	wrongValue: Sequential(3, 3, 2)
	wrongOwner: PPOOwnedAdam
	ok = PPOOwnedAdamTestSetup(&wrongPolicy, &wrongValue) && PPOOwnedAdamInit(&wrongOwner, &wrongPolicy, &wrongValue)
	testing.expect(t, ok)
	if !ok { return }
	defer PPOOwnedAdamDestroy(&wrongOwner)
	wrongAdam := PPOOwnedAdamOptimizer(&wrongOwner)
	wrongParameters, wrongFirst, wrongSecond, wrongStorageOk := PPOOwnedAdamStorage(&wrongOwner)
	testing.expect(t, wrongStorageOk && len(wrongParameters) == 4 && len(wrongFirst) == 6)
	if !wrongStorageOk { return }
	wrongPolicyBytes: [size_of(Sequential(2, 3, 2))]u8
	copy(wrongPolicyBytes[:], mem.slice_ptr((^u8)(rawptr(&wrongPolicy)), len(wrongPolicyBytes)))
	_, _, _, _, wrongTypeLoaded := PPOCheckpointRead(&wrongPolicy, &wrongValue, smallData[:smallSize], wrongAdam, wrongParameters, wrongFirst, wrongSecond)
	testing.expect(t, !wrongTypeLoaded && wrongAdam.step == 0)
	PPOOwnedAdamTestExpectBytes(t, rawptr(&wrongPolicy), wrongPolicyBytes[:])
}

@(test)
PPOOwnedAdamNormalizedCheckpoint :: proc(t: ^testing.T) {
	policy, value, restoredPolicy, restoredValue: Sequential(1, 2, 2)
	owner, restoredOwner: PPOOwnedAdam
	ok := PPOOwnedAdamTestSetup(&policy, &value) && PPOOwnedAdamTestSetup(&restoredPolicy, &restoredValue) &&
		PPOOwnedAdamInit(&owner, &policy, &value, learningRate = 0.005)
	testing.expect(t, ok)
	if !ok { return }
	defer PPOOwnedAdamDestroy(&owner)
	ok = PPOOwnedAdamInit(&restoredOwner, &restoredPolicy, &restoredValue)
	testing.expect(t, ok)
	if !ok { return }
	defer PPOOwnedAdamDestroy(&restoredOwner)
	adam, restoredAdam := PPOOwnedAdamOptimizer(&owner), PPOOwnedAdamOptimizer(&restoredOwner)
	config := PPOConfig{0.2, 0.01, 0.5, 1}
	_, trained := PPOOwnedAdamTestUpdate(&policy, &value, adam, config)
	testing.expect(t, trained)
	if !trained { return }
	mean, m2, restoredMean, restoredM2: [1]f64
	normalizer, restoredNormalizer: data.RunningStandardizer
	observations := [3]f32{0, 2, 4}
	ok = data.RunningStandardizerInit(&normalizer, mean[:], m2[:]) &&
		data.RunningStandardizerUpdate(&normalizer, observations[:]) && data.RunningStandardizerFreeze(&normalizer) &&
		data.RunningStandardizerInit(&restoredNormalizer, restoredMean[:], restoredM2[:])
	testing.expect(t, ok)
	if !ok { return }
	state := PPOTrainingState{updateCount = 1, policyRandomState = 123, shuffleRandomState = 456}
	fitConfig := PPOFitConfig{epochs = 1, batchSize = 2}
	checkpoint, baseScratch, policyScratch, valueScratch: [2048]u8
	size, saved := PPOCheckpointWriteNormalized(
		&policy, &value, adam, state, config, fitConfig, PPOTrainingNormalizers{observation = &normalizer},
		checkpoint[:], baseScratch[:], policyScratch[:], valueScratch[:],
	)
	testing.expect(t, saved)
	if !saved { return }
	parameters, first, second, storageOk := PPOOwnedAdamStorage(&restoredOwner)
	testing.expect(t, storageOk)
	if !storageOk { return }
	restoredState, restoredConfig, restoredFit, optimizer, loaded := PPOCheckpointReadNormalized(
		&restoredPolicy, &restoredValue, checkpoint[:size], restoredAdam, parameters, first, second,
		PPOTrainingNormalizers{observation = &restoredNormalizer},
	)
	pointer, isAdam := optimizer.(^Adam)
	testing.expect(t, loaded && isAdam && pointer == restoredAdam && restoredState == state && restoredConfig == config && restoredFit == fitConfig)
	testing.expect(t, loaded && restoredNormalizer.count == normalizer.count && restoredNormalizer.frozen && restoredMean == mean && restoredM2 == m2)
	if !loaded { return }
	for index in 0..<len(adam.firstMoment) { testing.expect(t, restoredAdam.firstMoment[index] == adam.firstMoment[index] && restoredAdam.secondMoment[index] == adam.secondMoment[index]) }
	statsA, trainedA := PPOOwnedAdamTestUpdate(&policy, &value, adam, config)
	statsB, trainedB := PPOOwnedAdamTestUpdate(&restoredPolicy, &restoredValue, restoredAdam, restoredConfig)
	testing.expect(t, trainedA && trainedB && statsA == statsB && PPOOwnedAdamTestModelsEqual(&policy, &restoredPolicy) && PPOOwnedAdamTestModelsEqual(&value, &restoredValue))
}
