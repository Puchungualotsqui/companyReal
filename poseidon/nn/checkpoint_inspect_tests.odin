package nn

import "../core"
import "core:mem"
import "core:testing"

// Frozen byte-validation pass from CheckpointRead before CheckpointInspect was
// introduced. This is a compatibility oracle for the existing v1/v2 formats.
checkpointInspectLegacyValid :: proc(input: []u8, maxLayers, maxWidth, batchCapacity: int, hasAdam: bool) -> bool {
	if maxLayers <= 0 || maxWidth <= 0 || batchCapacity <= 0 { return false }
	offset := 0
	header: [10]u64
	for &value in header { v, ok := CheckpointGet64(input, &offset); if !ok { return false }; value = v }
	if header[0] != CHECKPOINT_MAGIC || (header[1] != CHECKPOINT_VERSION && header[1] != CHECKPOINT_SPATIAL_VERSION) || header[2] != u64(maxLayers) || header[3] != u64(maxWidth) || header[4] != u64(batchCapacity) || header[5] == 0 || header[5] > u64(maxWidth) || header[6] > u64(maxLayers) || header[7] == 0 || header[9] > 1 || (header[9] == 1) != hasAdam { return false }
	width := int(header[5])
	spatial := false
	h, w, channels := 0, 0, 0
	if header[1] == CHECKPOINT_SPATIAL_VERSION {
		dims: [3]u64
		for &dim in dims { v, ok := CheckpointGet64(input, &offset); if !ok || v > u64(maxWidth) { return false }; dim = v }
		if dims != ([3]u64{}) {
			if dims[0] == 0 || dims[1] == 0 || dims[2] == 0 { return false }
			h, w, channels = int(dims[0]), int(dims[1]), int(dims[2])
			if h > maxWidth/w || h*w > maxWidth/channels || h*w*channels != width { return false }
			spatial = true
		}
	}
	parameterCount, elementCount := 0, 0
	for _ in 0..<int(header[6]) {
		kind, ok := CheckpointGet64(input, &offset); if !ok { return false }
		layerWidth, ok2 := CheckpointGet64(input, &offset); if !ok2 || kind > 9 || (header[1] == CHECKPOINT_VERSION && kind > 5) || layerWidth == 0 || layerWidth > u64(maxWidth) { return false }
		if kind != 0 && kind != 6 && kind != 8 && kind != 9 && layerWidth != u64(width) { return false }
		if kind == 0 {
			if spatial || width > max(int)/int(layerWidth) { return false }
			weights := width*int(layerWidth)
			if weights > max(int)-int(layerWidth) { return false }
			count := weights+int(layerWidth)
			if count > (len(input)-offset)/4 || elementCount > max(int)-count || parameterCount > max(int)-2 { return false }
			parameterCount += 2; elementCount += count
			for _ in 0..<count { value, valid := CheckpointGet32(input, &offset); if !valid || !AdamFinite(f64(value)) { return false } }
		} else if kind == 5 {
			rate, valid := CheckpointGet32(input, &offset)
			if !valid || !(rate >= 0 && rate < 1) { return false }
		} else if kind == 7 {
			spatial = false
		} else if kind == 8 || kind == 9 {
			if !spatial { return false }
			values: [3]u64
			for &value in values { v, ok := CheckpointGet64(input, &offset); if !ok || v > u64(max(int)) { return false }; value = v }
			kh, kw, stride := int(values[0]), int(values[1]), int(values[2])
			if kh <= 0 || kw <= 0 || stride <= 0 || kh > h || kw > w || kh > max(int)/kw { return false }
			oh, ow := (h-kh)/stride+1, (w-kw)/stride+1
			if oh > maxWidth/ow || oh*ow > maxWidth/channels || oh*ow*channels != int(layerWidth) { return false }
			h, w = oh, ow
		} else if kind == 6 {
			if !spatial || maxWidth > max(int)/maxWidth { return false }
			values: [5]u64
			for &value in values { v, ok := CheckpointGet64(input, &offset); if !ok || v > u64(max(int)) { return false }; value = v }
			kh, kw, oc, stride, pad := int(values[0]), int(values[1]), int(values[2]), int(values[3]), int(values[4])
			if kh <= 0 || kw <= 0 || oc <= 0 || oc > maxWidth { return false }
			capacity := maxWidth*maxWidth
			if kh > capacity/kw || kh*kw > capacity/channels || kh*kw*channels > capacity/oc { return false }
			oh, okh := Conv2DDimension(h, kh, stride, pad)
			ow, okw := Conv2DDimension(w, kw, stride, pad)
			if !okh || !okw || oh <= 0 || ow <= 0 || oh > maxWidth/ow || oh*ow > maxWidth/oc || oh*ow*oc != int(layerWidth) || oh-1 > (max(int)-(kh-1))/stride || ow-1 > (max(int)-(kw-1))/stride { return false }
			count := kh*kw*channels*oc
			if count > max(int)-oc { return false }
			count += oc
			if count > (len(input)-offset)/4 || elementCount > max(int)-count || parameterCount > max(int)-2 { return false }
			parameterCount += 2; elementCount += count
			for _ in 0..<count { value, valid := CheckpointGet32(input, &offset); if !valid || !AdamFinite(f64(value)) { return false } }
			h, w, channels = oh, ow, oc
		}
		width = int(layerWidth)
	}
	if hasAdam {
		_, ok := CheckpointGet64(input, &offset); if !ok { return false }
		config: [4]f32
		for &value in config { v, valid := CheckpointGet32(input, &offset); if !valid { return false }; value = v }
		if !AdamFinite(f64(config[0])) || config[0] <= 0 || !(config[1] >= 0 && config[1] < 1) || !(config[2] >= 0 && config[2] < 1) || !AdamFinite(f64(config[3])) || config[3] <= 0 { return false }
		if elementCount > (len(input)-offset)/8 { return false }
		for _ in 0..<elementCount { value, valid := CheckpointGet32(input, &offset); if !valid || !AdamFinite(f64(value)) { return false } }
		for _ in 0..<elementCount { value, valid := CheckpointGet32(input, &offset); if !valid || !AdamFinite(f64(value)) || value < 0 { return false } }
	}
	return offset == len(input)
}

checkpointInspectCompare :: proc(t: ^testing.T, input: []u8, destination: ^Sequential($layers, $width, $batch), hasAdam: bool) {
	info, err := CheckpointInspect(input)
	compatible := err.code == .None && info.maxLayers == layers && info.maxWidth == width &&
		info.batchCapacity == batch && info.hasAdam == hasAdam
	legacy := checkpointInspectLegacyValid(input, layers, width, batch, hasAdam)
	if compatible != legacy { testing.expect(t, false); return }

	parameters: [16]^core.Node
	first, second: [2048]f32
	adam := Adam{step = 77, learningRate = 0.25}
	shuffle: u64 = 91
	modelBefore: [size_of(Sequential(layers, width, batch))]u8
	copy(modelBefore[:], mem.slice_ptr((^u8)(rawptr(destination)), len(modelBefore)))
	adamBefore: [size_of(Adam)]u8
	copy(adamBefore[:], mem.slice_ptr((^u8)(rawptr(&adam)), len(adamBefore)))
	firstBefore, secondBefore, parametersBefore := first, second, parameters
	adamPointer: ^Adam
	if hasAdam { adamPointer = &adam }
	read := CheckpointRead(destination, adamPointer, &shuffle, input, parameters[:], first[:], second[:])
	testing.expect(t, read == legacy)
	if !read {
		for value, i in modelBefore { if value != mem.slice_ptr((^u8)(rawptr(destination)), len(modelBefore))[i] { testing.expect(t, false); break } }
		for value, i in adamBefore { if value != mem.slice_ptr((^u8)(rawptr(&adam)), len(adamBefore))[i] { testing.expect(t, false); break } }
		testing.expect(t, shuffle == 91 && first == firstBefore && second == secondBefore && parameters == parametersBefore)
	} else {
		if hasAdam {
			testing.expect(t, len(adam.parameters) == info.parameterPointers && len(adam.firstMoment) == info.momentElements && len(adam.secondMoment) == info.momentElements)
		}
		outputWidth, outputRank := destination.inputWidth, len(destination.input.value.shape)
		if info.layerCount > 0 {
			last := &destination.layers[info.layerCount-1]
			outputWidth, outputRank = last.width, len(last.output.value.shape)
			count, elements, valid := SequentialAdamRequirements(destination)
			testing.expect(t, valid && count == info.parameterPointers && elements == info.momentElements)
		}
		testing.expect(t, info.outputWidth == outputWidth && info.outputRank == outputRank)
	}
}

checkpointInspectDifferential :: proc(t: ^testing.T, input: []u8, destination: ^Sequential($layers, $width, $batch), hasAdam: bool) {
	checkpointInspectCompare(t, input, destination, hasAdam)
	for n in 0..<len(input) {
		info, err := CheckpointInspect(input[:n])
		testing.expect(t, info == (CheckpointInfo{}) && err.code == .Truncated && err.offset == n)
		checkpointInspectCompare(t, input[:n], destination, hasAdam)
	}
	mutated: [4096]u8
	testing.expect(t, len(input)+1 <= len(mutated))
	if len(input)+1 > len(mutated) { return }
	copy(mutated[:], input)
	mutated[len(input)] = 0xa5
	info, err := CheckpointInspect(mutated[:len(input)+1])
	testing.expect(t, info == (CheckpointInfo{}) && err.code == .TrailingData && err.offset == len(input))
	checkpointInspectCompare(t, mutated[:len(input)+1], destination, hasAdam)
	for i in 0..<len(input) {
		for bit in 0..<8 {
			mutated[i] ~= u8(1 << uint(bit))
			checkpointInspectCompare(t, mutated[:len(input)], destination, hasAdam)
			mutated[i] ~= u8(1 << uint(bit))
		}
	}
	seed := u64(0x9e3779b97f4a7c15)
	for _ in 0..<512 {
		copy(mutated[:], input)
		seed ~= seed << 13; seed ~= seed >> 7; seed ~= seed << 17
		for _ in 0..<1+int(seed%4) {
			seed ~= seed << 13; seed ~= seed >> 7; seed ~= seed << 17
			index := int(seed%u64(len(input)))
			mutated[index] ~= u8(seed >> 56)
		}
		checkpointInspectCompare(t, mutated[:len(input)], destination, hasAdam)
	}
}

@(test)
CheckpointInspectDifferentialDense :: proc(t: ^testing.T) {
	source, restored: Sequential(6, 3, 2)
	ok := CheckpointTestModel(&source)
	testing.expect(t, ok)
	if !ok { return }
	parameters: [4]^core.Node
	list, valid := SequentialParameters(&source, parameters[:])
	testing.expect(t, valid)
	if !valid { return }
	first, second: [17]f32
	for i in 0..<17 { first[i] = f32(i-8)*0.125; second[i] = f32(i)*0.25 }
	adam := Adam{list, first[:], second[:], max(u64), 0.01, 0.8, 0.95, 1e-6}
	for withAdam in ([2]bool{false, true}) {
		adamPointer: ^Adam
		if withAdam { adamPointer = &adam }
		data: [4096]u8
		size, written := CheckpointWrite(&source, adamPointer, 0, data[:])
		testing.expect(t, written)
		if !written { return }
		info, err := CheckpointInspect(data[:size])
		testing.expect(t, err.code == .None && info == (CheckpointInfo{
			version = 1, maxLayers = 6, maxWidth = 3, batchCapacity = 2, inputWidth = 2, layerCount = 6,
			hasAdam = withAdam, parameterPointers = 4, momentElements = 17, outputWidth = 2, outputRank = 2,
		}))
		checkpointInspectDifferential(t, data[:size], &restored, withAdam)
		// Version 2 also accepts a vector-only architecture and its Adam payload.
		noncanonical: [4096]u8
		testing.expect(t, size+24 <= len(noncanonical))
		if size+24 > len(noncanonical) { return }
		copy(noncanonical[:80], data[:80])
		position := 8
		CheckpointPut64(noncanonical[:], &position, 2)
		copy(noncanonical[104:], data[80:size])
		info, err = CheckpointInspect(noncanonical[:size+24])
		testing.expect(t, err.code == .None && info == (CheckpointInfo{
			version = 2, maxLayers = 6, maxWidth = 3, batchCapacity = 2, inputWidth = 2, layerCount = 6,
			hasAdam = withAdam, parameterPointers = 4, momentElements = 17, outputWidth = 2, outputRank = 2,
		}))
		checkpointInspectDifferential(t, noncanonical[:size+24], &restored, withAdam)
	}
}

@(test)
CheckpointInspectDifferentialSpatial :: proc(t: ^testing.T) {
	for poolKind in ([2]PoolKind{.Max, .Average}) {
		source, restored: Sequential(7, 16, 2)
		ok := SequentialInitSpatial(&source, 3, 3, 1, 42) && SequentialAddConv2D(&source, 2, 2, 2, 1, 0) &&
			SequentialAddActivation(&source, .Relu) && SequentialAddPool2D(&source, poolKind, 2, 2, 1) &&
			SequentialAddDropout(&source, 0.25) && SequentialAddFlatten(&source) && SequentialAddDense(&source, 2)
		testing.expect(t, ok)
		if !ok { return }
		parameters: [4]^core.Node
		list, valid := SequentialParameters(&source, parameters[:])
		testing.expect(t, valid)
		if !valid { return }
		first, second: [16]f32
		adam := Adam{list, first[:], second[:], 7, 0.01, 0.8, 0.99, 1e-6}
		for withAdam in ([2]bool{false, true}) {
			adamPointer: ^Adam
			if withAdam { adamPointer = &adam }
			data: [4096]u8
			size, written := CheckpointWrite(&source, adamPointer, 19, data[:])
			testing.expect(t, written)
			if !written { return }
			info, err := CheckpointInspect(data[:size])
			testing.expect(t, err.code == .None && info == (CheckpointInfo{
				version = 2, maxLayers = 7, maxWidth = 16, batchCapacity = 2, inputWidth = 9, layerCount = 6,
				hasAdam = withAdam, parameterPointers = 4, momentElements = 16, outputWidth = 2, outputRank = 2,
			}))
			checkpointInspectDifferential(t, data[:size], &restored, withAdam)
		}
	}
}

checkpointInspectExpectError :: proc(t: ^testing.T, input: []u8, code: CheckpointErrorCode, offset: int) {
	info, err := CheckpointInspect(input)
	testing.expect(t, info == (CheckpointInfo{}) && err.code == code && err.offset == offset)
}

@(test)
CheckpointInspectErrorsAndOffsets :: proc(t: ^testing.T) {
	source, destination: Sequential(2, 2, 2)
	ok := SequentialInit(&source, 2, 7) && SequentialAddDense(&source, 2) && SequentialAddDropout(&source, 0.25)
	testing.expect(t, ok)
	if !ok { return }
	parameters: [2]^core.Node
	list, valid := SequentialParameters(&source, parameters[:])
	testing.expect(t, valid)
	if !valid { return }
	first, second: [6]f32
	adam := Adam{list, first[:], second[:], 4, 0.01, 0.8, 0.99, 1e-6}
	data: [512]u8
	size, written := CheckpointWrite(&source, &adam, 0, data[:])
	testing.expect(t, written && size == 212)
	if !written || size != 212 { return }

	integerCases := [16]struct { offset: int, value: u64, code: CheckpointErrorCode, errorOffset: int }{
		{0, 0, .InvalidMagic, 0}, {8, 3, .UnsupportedVersion, 8},
		{16, 0, .InvalidHeader, 16}, {16, max(u64), .Overflow, 16},
		{24, 0, .InvalidHeader, 24}, {24, max(u64), .Overflow, 24},
		{32, 0, .InvalidHeader, 32}, {32, max(u64), .Overflow, 32},
		{40, 0, .InvalidHeader, 40}, {40, 3, .InvalidHeader, 40},
		{48, 3, .InvalidHeader, 48}, {56, 0, .InvalidHeader, 56},
		{72, 2, .InvalidHeader, 72}, {80, 10, .UnsupportedLayer, 80},
		{80, 6, .UnsupportedLayer, 80}, {88, 0, .InvalidArchitecture, 88},
	}
	for item in integerCases {
		bad := data
		position := item.offset
		CheckpointPut64(bad[:], &position, item.value)
		checkpointInspectExpectError(t, bad[:size], item.code, item.errorOffset)
		checkpointInspectCompare(t, bad[:size], &destination, true)
	}
	floatCases := [9]struct { offset: int, value: f32 }{
		{96, transmute(f32)u32(0x7fc00000)}, {136, 1},
		{136, transmute(f32)u32(0x7f800000)}, {148, 0}, {152, 1},
		{156, -0.1}, {160, 0}, {164, transmute(f32)u32(0x7fc00000)}, {188, -1},
	}
	for item in floatCases {
		bad := data
		position := item.offset
		CheckpointPut32(bad[:], &position, item.value)
		checkpointInspectExpectError(t, bad[:size], .InvalidValue, item.offset)
		checkpointInspectCompare(t, bad[:size], &destination, true)
	}
	bad := data
	position := 128
	CheckpointPut64(bad[:], &position, 1)
	checkpointInspectExpectError(t, bad[:size], .InvalidArchitecture, 128)
	checkpointInspectCompare(t, bad[:size], &destination, true)
	bad = data
	position = 72
	CheckpointPut64(bad[:], &position, 0)
	checkpointInspectExpectError(t, bad[:size], .TrailingData, 140)
	checkpointInspectCompare(t, bad[:size], &destination, true)
}

@(test)
CheckpointInspectLimitsAndUnrepresentableCapacities :: proc(t: ^testing.T) {
	source: Sequential(2, 2, 2)
	ok := SequentialInit(&source, 2) && SequentialAddDense(&source, 2) && SequentialAddDropout(&source, 0.25)
	testing.expect(t, ok)
	if !ok { return }
	data: [512]u8
	size, written := CheckpointWrite(&source, nil, 0, data[:])
	testing.expect(t, written)
	if !written { return }
	limits := CheckpointInspectLimits{size, 2, 2, 2, 2, 6}
	info, err := CheckpointInspect(data[:size], limits)
	testing.expect(t, err.code == .None && info.parameterPointers == 2 && info.momentElements == 6 && !info.hasAdam)
	limitCases := [6]struct { limits: CheckpointInspectLimits, offset: int }{
		{{size-1, 2, 2, 2, 2, 6}, 0}, {{size, 1, 2, 2, 2, 6}, 16},
		{{size, 2, 1, 2, 2, 6}, 24}, {{size, 2, 2, 1, 2, 6}, 32},
		{{size, 2, 2, 2, 1, 6}, 80}, {{size, 2, 2, 2, 2, 5}, 80},
	}
	for item in limitCases {
		limited, failure := CheckpointInspect(data[:size], item.limits)
		testing.expect(t, limited == (CheckpointInfo{}) && failure.code == .LimitExceeded && failure.offset == item.offset)
	}
	negativeCases := [6]CheckpointInspectLimits{
		{-1, 0, 0, 0, 0, 0}, {0, -1, 0, 0, 0, 0}, {0, 0, -1, 0, 0, 0},
		{0, 0, 0, -1, 0, 0}, {0, 0, 0, 0, -1, 0}, {0, 0, 0, 0, 0, -1},
	}
	for item in negativeCases {
		limited, failure := CheckpointInspect(data[:size], item)
		testing.expect(t, limited == (CheckpointInfo{}) && failure.code == .InvalidLimits && failure.offset == 0)
	}

	// A structurally valid zero-layer stream need not correspond to an available
	// or allocatable compile-time Sequential type.
	forged: [256]u8
	position := 0
	for value in ([10]u64{CHECKPOINT_MAGIC, 1, u64(max(int)), u64(max(int)), u64(max(int)), 1, 0, 1, 0, 0}) {
		CheckpointPut64(forged[:], &position, value)
	}
	info, err = CheckpointInspect(forged[:position])
	testing.expect(t, err.code == .None && info.maxLayers == max(int) && info.maxWidth == max(int) && info.batchCapacity == max(int))
	_, err = CheckpointInspect(forged[:position], CheckpointInspectLimits{maxLayers = 4})
	testing.expect(t, err.code == .LimitExceeded && err.offset == 16)

	// Reject overflowing dimensions before multiplying or reading parameter data.
	position = 0
	for value in ([12]u64{CHECKPOINT_MAGIC, 1, 1, u64(max(int)), 1, 2, 1, 1, 0, 0, 0, u64(max(int))}) {
		CheckpointPut64(forged[:], &position, value)
	}
	checkpointInspectExpectError(t, forged[:position], .Overflow, 88)
	position = 0
	for value in ([15]u64{CHECKPOINT_MAGIC, 2, 1, u64(max(int)), 1, 1, 1, 1, 0, 0, 1, 1, 1, 6, 1}) {
		CheckpointPut64(forged[:], &position, value)
	}
	checkpointInspectExpectError(t, forged[:position], .Overflow, 24)
}

@(test)
CheckpointInspectEmptyAndNoncanonical :: proc(t: ^testing.T) {
	source, restored: Sequential(3, 2, 1)
	ok := SequentialInit(&source, 1)
	testing.expect(t, ok)
	if !ok { return }
	adam := Adam{step = max(u64), learningRate = 0.01, beta1 = 0.8, beta2 = 0.9, epsilon = 1e-6}
	for withAdam in ([2]bool{false, true}) {
		adamPointer: ^Adam
		if withAdam { adamPointer = &adam }
		data: [512]u8
		size, written := CheckpointWrite(&source, adamPointer, 0, data[:])
		testing.expect(t, written)
		if !written { return }
		info, err := CheckpointInspect(data[:size])
		testing.expect(t, err.code == .None && info.layerCount == 0 && info.parameterPointers == 0 && info.momentElements == 0 && info.hasAdam == withAdam)
		checkpointInspectDifferential(t, data[:size], &restored, withAdam)
	}
	ok = SequentialAddDropout(&source, 0.5) && SequentialAddActivation(&source, .Tanh)
	testing.expect(t, ok)
	if !ok { return }
	data: [512]u8
	size, written := CheckpointWrite(&source, &adam, 0, data[:])
	testing.expect(t, written)
	if !written { return }
	info, err := CheckpointInspect(data[:size])
	testing.expect(t, err.code == .None && info.version == 1 && info.layerCount == 2 && info.parameterPointers == 0 && info.momentElements == 0)
	checkpointInspectDifferential(t, data[:size], &restored, true)

	// Readers accept version 2 with vector dimensions even when the writer would
	// choose version 1. Preserve that acceptance and the maximum Adam step.
	noncanonical: [512]u8
	copy(noncanonical[:80], data[:80])
	position := 8
	CheckpointPut64(noncanonical[:], &position, 2)
	copy(noncanonical[104:], data[80:size])
	info, err = CheckpointInspect(noncanonical[:size+24])
	testing.expect(t, err.code == .None && info.version == 2 && info.hasAdam && info.momentElements == 0)
	checkpointInspectDifferential(t, noncanonical[:size+24], &restored, true)
	target: Adam
	state: u64 = 5
	loaded := CheckpointRead(&restored, &target, &state, noncanonical[:size+24], nil, nil, nil)
	testing.expect(t, loaded && target.step == max(u64) && state == 0)
	again: [512]u8
	againSize, encoded := CheckpointWrite(&restored, &target, state, again[:])
	testing.expect(t, encoded && againSize == size && again[8] == 1)
}

@(test)
CheckpointInspectNilAllocatorAndInputUnchanged :: proc(t: ^testing.T) {
	source, restored: Sequential(1, 2, 1)
	ok := SequentialInit(&source, 2) && SequentialAddDense(&source, 1)
	testing.expect(t, ok)
	if !ok { return }
	parameters: [2]^core.Node
	list, valid := SequentialParameters(&source, parameters[:])
	testing.expect(t, valid)
	if !valid { return }
	first, second: [3]f32
	adam := Adam{list, first[:], second[:], 3, 0.01, 0.9, 0.999, 1e-6}
	data: [256]u8
	size, written := CheckpointWrite(&source, &adam, 0, data[:])
	testing.expect(t, written)
	if !written { return }
	before := data
	varInfo, badInfo: CheckpointInfo
	varErr, badErr: CheckpointError
	target: Adam
	targetParameters: [2]^core.Node
	targetFirst, targetSecond: [3]f32
	state: u64
	loaded: bool
	{
		context.allocator = mem.nil_allocator()
		varInfo, varErr = CheckpointInspect(data[:size])
		badInfo, badErr = CheckpointInspect(data[:size-1])
		loaded = CheckpointRead(&restored, &target, &state, data[:size], targetParameters[:], targetFirst[:], targetSecond[:])
	}
	testing.expect(t, varErr.code == .None && varInfo.parameterPointers == 2 && varInfo.momentElements == 3 && varInfo.hasAdam)
	testing.expect(t, badInfo == (CheckpointInfo{}) && badErr.code == .Truncated && badErr.offset == size-1)
	testing.expect(t, loaded && target.step == 3 && data == before)
}

@(test)
CheckpointInspectSpatialMalformed :: proc(t: ^testing.T) {
	source, destination: Sequential(3, 16, 1)
	ok := SequentialInitSpatial(&source, 3, 3, 1) && SequentialAddConv2D(&source, 2, 2, 2, 1, 0) &&
		SequentialAddActivation(&source, .Relu) && SequentialAddPool2D(&source, .Max, 2, 2, 1)
	testing.expect(t, ok)
	if !ok { return }
	data: [512]u8
	size, written := CheckpointWrite(&source, nil, 0, data[:])
	testing.expect(t, written && size == 256)
	if !written || size != 256 { return }
	cases := [9]struct { offset: int, value: u64, code: CheckpointErrorCode, errorOffset: int }{
		{80, 0, .InvalidArchitecture, 80}, {80, 17, .InvalidArchitecture, 80},
		{120, 0, .InvalidArchitecture, 104}, {128, max(u64), .Overflow, 128},
		{136, 0, .InvalidArchitecture, 104}, {144, 0, .InvalidArchitecture, 104},
		{152, u64(max(int)), .Overflow, 152}, {232, 0, .InvalidArchitecture, 216},
		{248, 0, .InvalidArchitecture, 216},
	}
	for item in cases {
		bad := data
		position := item.offset
		CheckpointPut64(bad[:], &position, item.value)
		checkpointInspectExpectError(t, bad[:size], item.code, item.errorOffset)
		checkpointInspectCompare(t, bad[:size], &destination, false)
	}
}

@(test)
CheckpointInspectValidBytesDoNotGuaranteeDestination :: proc(t: ^testing.T) {
	source, destination: Sequential(2, 2, 2)
	ok := SequentialInit(&source, 2, 7) && SequentialAddDense(&source, 2) && SequentialAddDropout(&source, 0.25) &&
		SequentialInit(&destination, 1, 19) && SequentialAddDense(&destination, 1)
	testing.expect(t, ok)
	if !ok { return }
	sourceParameters: [2]^core.Node
	list, valid := SequentialParameters(&source, sourceParameters[:])
	testing.expect(t, valid)
	if !valid { return }
	first, second: [6]f32
	sourceAdam := Adam{list, first[:], second[:], 3, 0.01, 0.9, 0.999, 1e-6}
	data: [512]u8
	size, written := CheckpointWrite(&source, &sourceAdam, 23, data[:])
	testing.expect(t, written)
	if !written { return }
	info, err := CheckpointInspect(data[:size])
	testing.expect(t, err.code == .None && info.parameterPointers == 2 && info.momentElements == 6)

	targetParameters := [2]^core.Node{&TestDenseStorage(&destination.layers[0]).bias, &TestDenseStorage(&destination.layers[0]).bias}
	targetFirst, targetSecond: [6]f32
	for &value in targetFirst { value = 12 }
	for &value in targetSecond { value = 13 }
	target := Adam{targetParameters[:], targetFirst[:], targetSecond[:], 99, 0.25, 0.5, 0.75, 0.1}
	state: u64 = 123
	modelBefore: [size_of(Sequential(2, 2, 2))]u8
	adamBefore: [size_of(Adam)]u8
	copy(modelBefore[:], mem.slice_ptr((^u8)(rawptr(&destination)), len(modelBefore)))
	copy(adamBefore[:], mem.slice_ptr((^u8)(rawptr(&target)), len(adamBefore)))
	parametersBefore, firstBefore, secondBefore := targetParameters, targetFirst, targetSecond
	for failure in 0..<8 {
		loaded := false
		switch failure {
		case 0: loaded = CheckpointRead(&destination, nil, &state, data[:size], targetParameters[:], targetFirst[:], targetSecond[:])
		case 1: loaded = CheckpointRead(&destination, &target, &state, data[:size], targetParameters[:1], targetFirst[:], targetSecond[:])
		case 2: loaded = CheckpointRead(&destination, &target, &state, data[:size], targetParameters[:], targetFirst[:5], targetSecond[:])
		case 3: loaded = CheckpointRead(&destination, &target, &state, data[:size], targetParameters[:], targetFirst[:], targetSecond[:5])
		case 4: loaded = CheckpointRead(&destination, &target, nil, data[:size], targetParameters[:], targetFirst[:], targetSecond[:])
		case 5, 6, 7:
			bad := data
			position := 16+(failure-5)*8
			CheckpointPut64(bad[:], &position, 3)
			badInfo, badErr := CheckpointInspect(bad[:size])
			testing.expect(t, badErr.code == .None && badInfo.hasAdam)
			loaded = CheckpointRead(&destination, &target, &state, bad[:size], targetParameters[:], targetFirst[:], targetSecond[:])
		}
		testing.expect(t, !loaded && state == 123 && targetParameters == parametersBefore && targetFirst == firstBefore && targetSecond == secondBefore)
		for value, i in modelBefore { if value != mem.slice_ptr((^u8)(rawptr(&destination)), len(modelBefore))[i] { testing.expect(t, false); break } }
		for value, i in adamBefore { if value != mem.slice_ptr((^u8)(rawptr(&target)), len(adamBefore))[i] { testing.expect(t, false); break } }
	}

	// Model-only reads ignore supplied optimizer buffers when Adam is nil.
	modelOnly: [512]u8
	modelOnlySize, modelOnlyWritten := CheckpointWrite(&source, nil, 0, modelOnly[:])
	testing.expect(t, modelOnlyWritten)
	if !modelOnlyWritten { return }
	loaded := CheckpointRead(&destination, nil, &state, modelOnly[:modelOnlySize], targetParameters[:], targetFirst[:], targetSecond[:])
	testing.expect(t, loaded && targetParameters == parametersBefore && targetFirst == firstBefore && targetSecond == secondBefore)
}

@(test)
CheckpointReadRejectsIncompatibleTargetEarly :: proc(t: ^testing.T) {
	source, destination: Sequential(2, 2, 2)
	ok := SequentialInit(&source, 2) && SequentialAddDense(&source, 2) && SequentialAddDense(&source, 2) &&
		SequentialInit(&destination, 1) && SequentialAddActivation(&destination, .Tanh)
	testing.expect(t, ok)
	if !ok { return }
	parameters: [4]^core.Node
	list, valid := SequentialParameters(&source, parameters[:])
	testing.expect(t, valid)
	if !valid { return }
	first, second: [12]f32
	sourceAdam := Adam{list, first[:], second[:], 3, 0.01, 0.9, 0.999, 1e-6}
	data: [512]u8
	size, written := CheckpointWrite(&source, &sourceAdam, 23, data[:])
	testing.expect(t, written && size == 280)
	if !written || size != 280 { return }

	matching := checkpointReadTarget{2, 2, 2, true, 4, 12, 12}
	headerMismatches := [4]checkpointReadTarget{
		{1, 2, 2, true, 4, 12, 12}, {2, 1, 2, true, 4, 12, 12},
		{2, 2, 1, true, 4, 12, 12}, {2, 2, 2, false, 4, 12, 12},
	}
	for &target in headerMismatches {
		// No layer bytes exist, so a non-rejected parse would be truncated.
		parsed, err := checkpointParse(data[:80], {}, &target)
		testing.expect(t, parsed.targetRejected && err.code == .None)
	}
	parsed, err := checkpointParse(data[:80], {}, &matching)
	testing.expect(t, !parsed.targetRejected && err.code == .Truncated && err.offset == 80)
	modelOnly: [512]u8
	modelOnlySize, modelOnlyWritten := CheckpointWrite(&source, nil, 0, modelOnly[:])
	testing.expect(t, modelOnlyWritten)
	if !modelOnlyWritten { return }
	parsed, err = checkpointParse(modelOnly[:80], {}, &matching)
	testing.expect(t, parsed.targetRejected && err.code == .None)
	noAdam := checkpointReadTarget{2, 2, 2, false, 0, 0, 0}
	parsed, err = checkpointParse(modelOnly[:modelOnlySize], {}, &noAdam)
	testing.expect(t, !parsed.targetRejected && err.code == .None)

	// Check each storage kind as soon as the first layer's counts are known.
	storageMismatches := [3]checkpointReadTarget{
		{2, 2, 2, true, 1, 12, 12}, {2, 2, 2, true, 4, 5, 12}, {2, 2, 2, true, 4, 12, 5},
	}
	for &target in storageMismatches {
		parsed, err = checkpointParse(data[:96], {}, &target)
		testing.expect(t, parsed.targetRejected && err.code == .None)
	}
	parsed, err = checkpointParse(data[:96], {}, &matching)
	testing.expect(t, !parsed.targetRejected && err.code == .Truncated && err.offset == 96)
	// The second layer pushes the cumulative requirements over these capacities.
	cumulativeMismatches := [3]checkpointReadTarget{
		{2, 2, 2, true, 3, 12, 12}, {2, 2, 2, true, 4, 11, 12}, {2, 2, 2, true, 4, 12, 11},
	}
	for &target in cumulativeMismatches {
		parsed, err = checkpointParse(data[:136], {}, &target)
		testing.expect(t, parsed.targetRejected && err.code == .None)
	}
	parsed, err = checkpointParse(data[:136], {}, &matching)
	testing.expect(t, !parsed.targetRejected && err.code == .Truncated && err.offset == 136)

	targetParameters: [4]^core.Node
	targetFirst, targetSecond: [12]f32
	for &value in targetFirst { value = 12 }
	for &value in targetSecond { value = 13 }
	adam := Adam{step = 77, learningRate = 0.25}
	state: u64 = 91
	modelBefore: [size_of(Sequential(2, 2, 2))]u8
	adamBefore: [size_of(Adam)]u8
	copy(modelBefore[:], mem.slice_ptr((^u8)(rawptr(&destination)), len(modelBefore)))
	copy(adamBefore[:], mem.slice_ptr((^u8)(rawptr(&adam)), len(adamBefore)))
	parametersBefore, firstBefore, secondBefore := targetParameters, targetFirst, targetSecond
	testing.expect(t, !CheckpointRead(&destination, nil, &state, data[:80], targetParameters[:], targetFirst[:], targetSecond[:]))
	testing.expect(t, !CheckpointRead(&destination, &adam, &state, modelOnly[:80], targetParameters[:], targetFirst[:], targetSecond[:]))
	testing.expect(t, !CheckpointRead(&destination, &adam, &state, data[:96], targetParameters[:1], targetFirst[:], targetSecond[:]))
	testing.expect(t, !CheckpointRead(&destination, &adam, &state, data[:96], targetParameters[:], targetFirst[:5], targetSecond[:]))
	testing.expect(t, !CheckpointRead(&destination, &adam, &state, data[:96], targetParameters[:], targetFirst[:], targetSecond[:5]))
	wrongLayers: Sequential(1, 2, 2)
	wrongWidth: Sequential(2, 3, 2)
	wrongBatch: Sequential(2, 2, 3)
	testing.expect(t, !CheckpointRead(&wrongLayers, &adam, &state, data[:80], targetParameters[:], targetFirst[:], targetSecond[:]))
	testing.expect(t, !CheckpointRead(&wrongWidth, &adam, &state, data[:80], targetParameters[:], targetFirst[:], targetSecond[:]))
	testing.expect(t, !CheckpointRead(&wrongBatch, &adam, &state, data[:80], targetParameters[:], targetFirst[:], targetSecond[:]))
	testing.expect(t, state == 91 && targetParameters == parametersBefore && targetFirst == firstBefore && targetSecond == secondBefore)
	for value, i in modelBefore { if value != mem.slice_ptr((^u8)(rawptr(&destination)), len(modelBefore))[i] { testing.expect(t, false); break } }
	for value, i in adamBefore { if value != mem.slice_ptr((^u8)(rawptr(&adam)), len(adamBefore))[i] { testing.expect(t, false); break } }
	testing.expect(t, wrongLayers.self == nil && wrongWidth.self == nil && wrongBatch.self == nil)
	testing.expect(t, CheckpointRead(&destination, &adam, &state, data[:size], targetParameters[:], targetFirst[:], targetSecond[:]) && state == 23)
}

@(test)
CheckpointInspectCountLimitsBeforePayload :: proc(t: ^testing.T) {
	source: Sequential(2, 2, 2)
	ok := SequentialInit(&source, 2) && SequentialAddDense(&source, 2) && SequentialAddDense(&source, 2)
	testing.expect(t, ok)
	if !ok { return }
	data: [512]u8
	size, written := CheckpointWrite(&source, nil, 0, data[:])
	testing.expect(t, written && size == 160)
	if !written || size != 160 { return }
	cases := [4]struct { prefix: int, limits: CheckpointInspectLimits, offset: int }{
		{96, {maxParameterPointers = 1}, 80}, {96, {maxMomentElements = 5}, 80},
		{136, {maxParameterPointers = 3}, 120}, {136, {maxMomentElements = 11}, 120},
	}
	for item in cases {
		info, err := CheckpointInspect(data[:item.prefix], item.limits)
		testing.expect(t, info == (CheckpointInfo{}) && err.code == .LimitExceeded && err.offset == item.offset)
	}
	for prefix in ([2]int{95, 135}) {
		_, err := CheckpointInspect(data[:prefix], CheckpointInspectLimits{maxParameterPointers = 1, maxMomentElements = 5})
		if prefix == 95 {
			testing.expect(t, err.code == .Truncated && err.offset == prefix)
		} else {
			testing.expect(t, err.code == .LimitExceeded && err.offset == 80)
		}
	}
	_, err := CheckpointInspect(data[:135], CheckpointInspectLimits{maxParameterPointers = 3, maxMomentElements = 11})
	testing.expect(t, err.code == .Truncated && err.offset == 135)
	_, err = CheckpointInspect(data[:136], CheckpointInspectLimits{maxParameterPointers = 4, maxMomentElements = 12})
	testing.expect(t, err.code == .Truncated && err.offset == 136)
	bad := data
	position := 96
	CheckpointPut32(bad[:], &position, transmute(f32)u32(0x7fc00000))
	_, err = CheckpointInspect(bad[:size], CheckpointInspectLimits{maxParameterPointers = 1})
	testing.expect(t, err.code == .LimitExceeded && err.offset == 80)

	spatial: Sequential(1, 16, 1)
	ok = SequentialInitSpatial(&spatial, 3, 3, 1) && SequentialAddConv2D(&spatial, 2, 2, 2, 1, 0)
	testing.expect(t, ok)
	if !ok { return }
	spatialParameters: [2]^core.Node
	list, valid := SequentialParameters(&spatial, spatialParameters[:])
	testing.expect(t, valid)
	if !valid { return }
	first, second: [10]f32
	adam := Adam{list, first[:], second[:], 3, 0.01, 0.9, 0.999, 1e-6}
	spatialSize, spatialWritten := CheckpointWrite(&spatial, &adam, 0, data[:])
	testing.expect(t, spatialWritten && spatialSize > 160)
	if !spatialWritten || spatialSize <= 160 { return }
	for limits in ([2]CheckpointInspectLimits{{maxParameterPointers = 1}, {maxMomentElements = 9}}) {
		_, err = CheckpointInspect(data[:160], limits)
		testing.expect(t, err.code == .LimitExceeded && err.offset == 104)
	}
	_, err = CheckpointInspect(data[:160], CheckpointInspectLimits{maxParameterPointers = 2, maxMomentElements = 10})
	testing.expect(t, err.code == .Truncated && err.offset == 160)
	_, err = CheckpointInspect(data[:159], CheckpointInspectLimits{maxParameterPointers = 1})
	testing.expect(t, err.code == .Truncated && err.offset == 159)
	target := checkpointReadTarget{1, 16, 1, true, 2, 9, 10}
	parsed, parseErr := checkpointParse(data[:160], {}, &target)
	testing.expect(t, parsed.targetRejected && parseErr.code == .None)
	target.firstCapacity = 10
	parsed, parseErr = checkpointParse(data[:160], {}, &target)
	testing.expect(t, !parsed.targetRejected && parseErr.code == .Truncated && parseErr.offset == 160)
	spatialDestination: Sequential(1, 16, 1)
	loadedAdam := Adam{step = 99}
	loadedParameters: [2]^core.Node
	state: u64 = 7
	testing.expect(t, !CheckpointRead(&spatialDestination, &loadedAdam, &state, data[:160], loadedParameters[:], first[:9], second[:]))
	testing.expect(t, spatialDestination.self == nil && loadedAdam.step == 99 && state == 7 && loadedParameters == [2]^core.Node{})
}

@(test)
CheckpointInspectConvArithmeticOverflow :: proc(t: ^testing.T) {
	source, destination: Sequential(1, 16, 1)
	ok := SequentialInitSpatial(&source, 3, 3, 1) && SequentialAddConv2D(&source, 2, 2, 2, 1, 0)
	testing.expect(t, ok)
	if !ok { return }
	data: [512]u8
	size, written := CheckpointWrite(&source, nil, 0, data[:])
	testing.expect(t, written && size == 200)
	if !written || size != 200 { return }

	// Padding overflow, output-area overflow and oversized but representable
	// geometry must be classified separately.
	for pad in ([2]u64{u64((max(int)-3)/2+1), u64(max(int))}) {
		bad := data
		position := 152
		CheckpointPut64(bad[:], &position, pad)
		checkpointInspectExpectError(t, bad[:size], .Overflow, 152)
		checkpointInspectCompare(t, bad[:size], &destination, false)
	}
	bad := data
	position := 152
	CheckpointPut64(bad[:], &position, u64((max(int)-3)/2))
	checkpointInspectExpectError(t, bad[:size], .Overflow, 104)
	checkpointInspectCompare(t, bad[:size], &destination, false)
	bad = data
	position = 152
	CheckpointPut64(bad[:], &position, 2)
	checkpointInspectExpectError(t, bad[:size], .InvalidArchitecture, 104)
	checkpointInspectCompare(t, bad[:size], &destination, false)
	bad = data
	position = 152
	when size_of(int) == 8 {
		CheckpointPut64(bad[:], &position, 1 << 30)
	} else {
		CheckpointPut64(bad[:], &position, 1 << 14)
	}
	checkpointInspectExpectError(t, bad[:size], .Overflow, 104)
	checkpointInspectCompare(t, bad[:size], &destination, false)

	// Kernel-area, input-channel and output-channel products can independently
	// overflow even though each encoded dimension fits in int.
	bad = data
	position = 120; CheckpointPut64(bad[:], &position, u64(max(int)))
	checkpointInspectExpectError(t, bad[:size], .Overflow, 128)
	checkpointInspectCompare(t, bad[:size], &destination, false)
	bad = data
	position = 40; CheckpointPut64(bad[:], &position, 2)
	position = 80; CheckpointPut64(bad[:], &position, 1)
	position = 88; CheckpointPut64(bad[:], &position, 1)
	position = 96; CheckpointPut64(bad[:], &position, 2)
	position = 120; CheckpointPut64(bad[:], &position, u64(max(int)))
	position = 128; CheckpointPut64(bad[:], &position, 1)
	position = 136; CheckpointPut64(bad[:], &position, 1)
	checkpointInspectExpectError(t, bad[:size], .Overflow, 104)
	checkpointInspectCompare(t, bad[:size], &destination, false)
	bad = data
	position = 120; CheckpointPut64(bad[:], &position, u64(max(int)))
	position = 128; CheckpointPut64(bad[:], &position, 1)
	checkpointInspectExpectError(t, bad[:size], .Overflow, 136)
	checkpointInspectCompare(t, bad[:size], &destination, false)
	bad = data
	position = 120; CheckpointPut64(bad[:], &position, 129)
	position = 128; CheckpointPut64(bad[:], &position, 1)
	checkpointInspectExpectError(t, bad[:size], .InvalidArchitecture, 104)
	checkpointInspectCompare(t, bad[:size], &destination, false)

	// Only one spatial axis can overflow at the padding boundary.
	for dims in ([2][2]int{{1, 2}, {2, 1}}) {
		asymmetric: Sequential(1, 2, 1)
		built := SequentialInitSpatial(&asymmetric, dims[0], dims[1], 1) && SequentialAddConv2D(&asymmetric, 1, 1, 1, 1, 0)
		testing.expect(t, built)
		if !built { return }
		asymmetricData: [256]u8
		asymmetricSize, encoded := CheckpointWrite(&asymmetric, nil, 0, asymmetricData[:])
		testing.expect(t, encoded)
		if !encoded { return }
		position = 152
		CheckpointPut64(asymmetricData[:], &position, u64((max(int)-1)/2))
		checkpointInspectExpectError(t, asymmetricData[:asymmetricSize], .Overflow, 152)
	}
}

checkpointInspectOutputShape :: proc(t: ^testing.T, model: ^Sequential($maxLayers, $maxWidth, $batchCapacity), expectedWidth, expectedRank: int) {
	data: [4096]u8
	size, written := CheckpointWrite(model, nil, 0, data[:])
	testing.expect(t, written)
	if !written { return }
	info, err := CheckpointInspect(data[:size])
	testing.expect(t, err.code == .None && info.outputWidth == expectedWidth && info.outputRank == expectedRank)
	restored: Sequential(maxLayers, maxWidth, batchCapacity)
	state: u64
	loaded := CheckpointRead(&restored, nil, &state, data[:size], nil, nil, nil)
	testing.expect(t, loaded)
	if !loaded { return }
	actualWidth, actualRank := restored.inputWidth, len(restored.input.value.shape)
	if restored.layerCount > 0 {
		last := &restored.layers[restored.layerCount-1]
		actualWidth, actualRank = last.width, len(last.output.value.shape)
	}
	testing.expect(t, info.outputWidth == actualWidth && info.outputRank == actualRank)
}

@(test)
CheckpointInspectOutputDense :: proc(t: ^testing.T) {
	model: Sequential(4, 8, 2)
	ok := SequentialInit(&model, 3) && SequentialAddDense(&model, 6)
	testing.expect(t, ok)
	if !ok { return }
	checkpointInspectOutputShape(t, &model, 6, 2)
	ok = SequentialAddActivation(&model, .Tanh) && SequentialAddDense(&model, 2) && SequentialAddDropout(&model, 0.25)
	testing.expect(t, ok)
	if !ok { return }
	checkpointInspectOutputShape(t, &model, 2, 2)
}

@(test)
CheckpointInspectOutputSpatialAndFlatten :: proc(t: ^testing.T) {
	model: Sequential(6, 16, 2)
	ok := SequentialInitSpatial(&model, 3, 3, 1) && SequentialAddConv2D(&model, 2, 2, 2, 1, 0)
	testing.expect(t, ok)
	if !ok { return }
	checkpointInspectOutputShape(t, &model, 8, 4)
	ok = SequentialAddActivation(&model, .Relu) && SequentialAddPool2D(&model, .Max, 2, 2, 1) && SequentialAddDropout(&model, 0.25)
	testing.expect(t, ok)
	if !ok { return }
	checkpointInspectOutputShape(t, &model, 2, 4)
	ok = SequentialAddFlatten(&model)
	testing.expect(t, ok)
	if !ok { return }
	checkpointInspectOutputShape(t, &model, 2, 2)
	ok = SequentialAddDense(&model, 3)
	testing.expect(t, ok)
	if !ok { return }
	checkpointInspectOutputShape(t, &model, 3, 2)
}

@(test)
CheckpointInspectOutputEmpty :: proc(t: ^testing.T) {
	vector, spatial: Sequential(2, 16, 2)
	ok := SequentialInit(&vector, 5) && SequentialInitSpatial(&spatial, 2, 3, 2)
	testing.expect(t, ok)
	if !ok { return }
	checkpointInspectOutputShape(t, &vector, 5, 2)
	checkpointInspectOutputShape(t, &spatial, 12, 4)
	ok = SequentialAddFlatten(&vector) && SequentialAddFlatten(&spatial)
	testing.expect(t, ok)
	if !ok { return }
	checkpointInspectOutputShape(t, &vector, 5, 2)
	checkpointInspectOutputShape(t, &spatial, 12, 2)
}
