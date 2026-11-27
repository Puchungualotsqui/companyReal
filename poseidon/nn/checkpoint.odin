package nn

import "../core"



// Versions 1 and 2 use little-endian u64 fields and IEEE-754 f32 values. Version 1
// remains the encoding for dense-only architectures. Version 2 adds three input
// dimensions (all zero for rank 2), Conv2D kind 6 (kernel height, kernel width,
// output channels, stride, padding, then weights and bias), Flatten kind 7,
// and Pool2D kinds 8 (max) and 9 (average), followed by kernel height,
// kernel width and stride as u64 fields. Older readers may reject pooling.
// Both versions record
// capacities, architecture, model RNG state, parameters, shuffle state and,
// optionally, Adam's configuration, step and moments. Transient activations and
// gradients and dropout masks are not saved. Checkpoints support resuming at an
// epoch boundary, not a pending forward/backward pass or mid-epoch shuffle.
// Kind 5 adds a dropout rate to v1; older readers may reject checkpoints
// containing dropout. Inputs and outputs must not overlap any other storage.
CHECKPOINT_MAGIC :: u64(0x3154504b434e4e50)
CHECKPOINT_VERSION :: u64(1)
CHECKPOINT_SPATIAL_VERSION :: u64(2)

CheckpointPut64 :: proc(data: []u8, offset: ^int, value: u64) {
	for i in 0..<8 { data[offset^+i] = u8(value >> uint(8*i)) }
	offset^ += 8
}

CheckpointGet64 :: proc(data: []u8, offset: ^int) -> (u64, bool) {
	if offset^ < 0 || offset^ > len(data) || len(data)-offset^ < 8 { return 0, false }
	value: u64
	for i in 0..<8 { value |= u64(data[offset^+i]) << uint(8*i) }
	offset^ += 8
	return value, true
}

CheckpointPut32 :: proc(data: []u8, offset: ^int, value: f32) {
	bits := transmute(u32)value
	for i in 0..<4 { data[offset^+i] = u8(bits >> uint(8*i)) }
	offset^ += 4
}

CheckpointGet32 :: proc(data: []u8, offset: ^int) -> (f32, bool) {
	if offset^ < 0 || offset^ > len(data) || len(data)-offset^ < 4 { return 0, false }
	bits: u32
	for i in 0..<4 { bits |= u32(data[offset^+i]) << uint(8*i) }
	offset^ += 4
	return transmute(f32)bits, true
}

// Returns bytes written, or (0, false) without changing output. Adam, when
// present, must reference exactly the model's dense and convolution parameters
// (weights then bias) in layer order.
// All slices and objects must have valid backing storage and be disjoint; no
// concurrent mutation is permitted. An initialized model must not have been copied.
CheckpointWrite :: proc(model: ^Sequential($maxLayers, $maxWidth, $batchCapacity), adam: ^Adam, shuffleState: u64, output: []u8) -> (int, bool) {
	if model == nil || model.self != rawptr(model) || maxLayers <= 0 || maxWidth <= 0 || batchCapacity <= 0 || model.inputWidth <= 0 || model.inputWidth > maxWidth || model.layerCount < 0 || model.layerCount > maxLayers || model.randomState == 0 { return 0, false }
	if adam != nil && !AdamConfigValid(adam) { return 0, false }
	// Accumulate against output length, avoiding arithmetic overflow.
	size := 80
	if len(output) < size { return 0, false }
	parameterCount, elementCount, width := 0, 0, model.inputWidth
	rank := len(model.input.value.shape)
	if rank != 2 && rank != 4 { return 0, false }
	spatial := rank == 4
	h, w, channels := 0, 0, 0
	version := CHECKPOINT_VERSION
	if spatial {
		h, w, channels = model.inputShape[1], model.inputShape[2], model.inputShape[3]
		if h <= 0 || w <= 0 || channels <= 0 || h > maxWidth/w || h*w > maxWidth/channels || h*w*channels != width { return 0, false }
		version = CHECKPOINT_SPATIAL_VERSION
	}
	for i in 0..<model.layerCount {
		switch operation in model.layers[i].operation {
		case Conv2D, Pool2D, Flatten: version = CHECKPOINT_SPATIAL_VERSION
		case Dense, Relu, Sigmoid, Tanh, Softmax, Dropout, nil:
		}
	}
	if version == CHECKPOINT_SPATIAL_VERSION {
		if len(output)-size < 24 { return 0, false }
		size += 24
	}
	rows := model.inputShape[0]
	if rows <= 0 || rows > batchCapacity || !core.TensorValid(model.input.value) || !core.SameShape(model.input.value, core.Tensor{shape = model.inputShape[:len(model.input.value.shape)]}) || (!spatial && model.inputShape[1] != width) { return 0, false }
	for i in 0..<model.layerCount {
		item := &model.layers[i]
		if item.width <= 0 || item.width > maxWidth || len(output)-size < 16 { return 0, false }
		size += 16
		input := &model.input
		if i > 0 { input = &model.layers[i-1].output }
		switch &operation in item.operation {
		case Dense:
			layer, ok := item.layer.(^Dense)
			if !ok || layer != &operation || operation.input != input || operation.output != &item.output { return 0, false }
		case Conv2D:
			layer, ok := item.layer.(^Conv2D)
			if !ok || layer != &operation || operation.input != input || operation.output != &item.output { return 0, false }
		case Pool2D:
			layer, ok := item.layer.(^Pool2D)
			if !ok || layer != &operation || operation.input != input || operation.output != &item.output { return 0, false }
		case Flatten:
			layer, ok := item.layer.(^Flatten)
			if !ok || layer != &operation || operation.input != input || operation.output != &item.output { return 0, false }
		case Relu:
			layer, ok := item.layer.(^Relu)
			if !ok || layer != &operation || operation.input != input || operation.output != &item.output { return 0, false }
		case Sigmoid:
			layer, ok := item.layer.(^Sigmoid)
			if !ok || layer != &operation || operation.input != input || operation.output != &item.output { return 0, false }
		case Tanh:
			layer, ok := item.layer.(^Tanh)
			if !ok || layer != &operation || operation.input != input || operation.output != &item.output { return 0, false }
		case Softmax:
			layer, ok := item.layer.(^Softmax)
			if !ok || layer != &operation || operation.input != input || operation.output != &item.output { return 0, false }
		case Dropout:
			layer, ok := item.layer.(^Dropout)
			if !ok || layer != &operation || operation.input != input || operation.output != &item.output { return 0, false }
		case nil:
			return 0, false
		}
		switch &operation in item.operation {
		case Dense:
			if spatial { return 0, false }
			dense: ^DenseStorage(maxWidth)
			switch &storage in item.storage {
			case DenseStorage(maxWidth): dense = &storage
			case nil, Conv2DStorage(maxWidth), DropoutStorage(maxWidth, batchCapacity): return 0, false
			}
			if operation.weights != &dense.weights || operation.bias != &dense.bias || dense.weightShape != ([2]int{width, item.width}) || dense.biasShape != ([1]int{item.width}) ||
				!core.TensorValid(dense.weights.value) || !core.TensorValid(dense.bias.value) ||
				!core.SameShape(dense.weights.value, core.Tensor{shape = dense.weightShape[:]}) || !core.SameShape(dense.bias.value, core.Tensor{shape = dense.biasShape[:]}) { return 0, false }
			if width > max(int)/item.width || parameterCount > max(int)-2 { return 0, false }
			weights := width * item.width
			if weights > max(int)-item.width { return 0, false }
			count := weights + item.width
			if count > (len(output)-size)/4 { return 0, false }
			size += count*4
			if adam != nil {
				if parameterCount > len(adam.parameters) || len(adam.parameters)-parameterCount < 2 || adam.parameters[parameterCount] != &dense.weights || adam.parameters[parameterCount+1] != &dense.bias { return 0, false }
			}
			parameterCount += 2
			if elementCount > max(int)-count { return 0, false }
			elementCount += count
			for value in dense.weights.value.data { if !AdamFinite(f64(value)) { return 0, false } }
			for value in dense.bias.value.data { if !AdamFinite(f64(value)) { return 0, false } }
		case Conv2D:
			if !spatial || maxWidth > max(int)/maxWidth { return 0, false }
			conv: ^Conv2DStorage(maxWidth)
			switch &storage in item.storage {
			case Conv2DStorage(maxWidth): conv = &storage
			case nil, DenseStorage(maxWidth), DropoutStorage(maxWidth, batchCapacity): return 0, false
			}
			kh, kw, ic, oc := conv.weightShape[0], conv.weightShape[1], conv.weightShape[2], conv.weightShape[3]
			if kh <= 0 || kw <= 0 || ic != channels || oc <= 0 || oc > maxWidth { return 0, false }
			capacity := maxWidth*maxWidth
			if kh > capacity/kw || kh*kw > capacity/channels || kh*kw*channels > capacity/oc { return 0, false }
			oh, okh := Conv2DDimension(h, kh, operation.stride, operation.padding)
			ow, okw := Conv2DDimension(w, kw, operation.stride, operation.padding)
			if !okh || !okw || oh <= 0 || ow <= 0 || oh > maxWidth/ow || oh*ow > maxWidth/oc || oh*ow*oc != item.width || oh-1 > (max(int)-(kh-1))/operation.stride || ow-1 > (max(int)-(kw-1))/operation.stride { return 0, false }
			if operation.weights != &conv.weights || operation.bias != &conv.bias || conv.biasShape != ([1]int{oc}) || !core.TensorValid(conv.weights.value) || !core.TensorValid(conv.bias.value) || !core.SameShape(conv.weights.value, core.Tensor{shape = conv.weightShape[:]}) || !core.SameShape(conv.bias.value, core.Tensor{shape = conv.biasShape[:]}) { return 0, false }
			count := kh*kw*channels*oc
			if count > max(int)-oc || parameterCount > max(int)-2 { return 0, false }
			count += oc
			if len(output)-size < 40 || count > (len(output)-size-40)/4 || elementCount > max(int)-count { return 0, false }
			size += 40 + count*4
			if adam != nil && (parameterCount > len(adam.parameters) || len(adam.parameters)-parameterCount < 2 || adam.parameters[parameterCount] != &conv.weights || adam.parameters[parameterCount+1] != &conv.bias) { return 0, false }
			parameterCount += 2; elementCount += count
			for value in conv.weights.value.data { if !AdamFinite(f64(value)) { return 0, false } }
			for value in conv.bias.value.data { if !AdamFinite(f64(value)) { return 0, false } }
			h, w, channels = oh, ow, oc
		case Pool2D:
			if !spatial || (operation.kind != .Max && operation.kind != .Average) { return 0, false }
			kh, kw, stride := operation.kernelHeight, operation.kernelWidth, operation.stride
			if kh <= 0 || kw <= 0 || stride <= 0 || kh > h || kw > w || kh > max(int)/kw { return 0, false }
			oh, ow := (h-kh)/stride+1, (w-kw)/stride+1
			if oh > maxWidth/ow || oh*ow > maxWidth/channels || oh*ow*channels != item.width || len(output)-size < 24 { return 0, false }
			size += 24
			h, w = oh, ow
		case Flatten:
			if item.width != width { return 0, false }
			spatial = false
		case Relu, Sigmoid, Tanh, Softmax:
			if item.width != width { return 0, false }
		case Dropout:
			if item.width != width || !(operation.rate >= 0 && operation.rate < 1) || operation.randomState != &model.randomState || len(output)-size < 4 { return 0, false }
			size += 4
		case nil:
			return 0, false
		}
		width = item.width
		outputRows := item.outputShape[0]
		expected := [4]int{outputRows, width, 0, 0}
		rank := 2
		if spatial { expected = {outputRows, h, w, channels}; rank = 4 }
		if outputRows <= 0 || outputRows > batchCapacity || !core.TensorValid(item.output.value) || !core.SameShape(item.output.value, core.Tensor{shape = expected[:rank]}) { return 0, false }
	}
	if adam != nil {
		if parameterCount != len(adam.parameters) || elementCount != len(adam.firstMoment) || len(output)-size < 24 { return 0, false }
		size += 24
		if elementCount > (len(output)-size)/8 { return 0, false }
		size += elementCount*8
		for value in adam.firstMoment { if !AdamFinite(f64(value)) { return 0, false } }
		for value in adam.secondMoment { if !AdamFinite(f64(value)) || value < 0 { return 0, false } }
	}
	offset := 0
	for value in ([10]u64{CHECKPOINT_MAGIC, version, u64(maxLayers), u64(maxWidth), u64(batchCapacity), u64(model.inputWidth), u64(model.layerCount), model.randomState, shuffleState, u64(adam != nil)}) { CheckpointPut64(output, &offset, value) }
	if version == CHECKPOINT_SPATIAL_VERSION {
		for i in 1..=3 {
			dim := 0
			if len(model.input.value.shape) == 4 { dim = model.inputShape[i] }
			CheckpointPut64(output, &offset, u64(dim))
		}
	}
	width = model.inputWidth
	for i in 0..<model.layerCount {
		item := &model.layers[i]
		kind: u64
		switch operation in item.operation {
		case Dense: kind = 0
		case Conv2D: kind = 6
		case Flatten: kind = 7
		case Pool2D:
			if operation.kind == .Max { kind = 8 } else { kind = 9 }
		case Relu: kind = 1
		case Sigmoid: kind = 2
		case Tanh: kind = 3
		case Softmax: kind = 4
		case Dropout: kind = 5
		case nil: return 0, false
		}
		CheckpointPut64(output, &offset, kind)
		CheckpointPut64(output, &offset, u64(item.width))
		if kind == 0 {
			dense := &item.storage.(DenseStorage(maxWidth))
			for value in dense.weights.value.data { CheckpointPut32(output, &offset, value) }
			for value in dense.bias.value.data { CheckpointPut32(output, &offset, value) }
		} else if kind == 6 {
			conv := &item.storage.(Conv2DStorage(maxWidth))
			operation := &item.operation.(Conv2D)
			for value in ([5]int{conv.weightShape[0], conv.weightShape[1], conv.weightShape[3], operation.stride, operation.padding}) { CheckpointPut64(output, &offset, u64(value)) }
			for value in conv.weights.value.data { CheckpointPut32(output, &offset, value) }
			for value in conv.bias.value.data { CheckpointPut32(output, &offset, value) }
		} else if kind == 8 || kind == 9 {
			operation := &item.operation.(Pool2D)
			for value in ([3]int{operation.kernelHeight, operation.kernelWidth, operation.stride}) { CheckpointPut64(output, &offset, u64(value)) }
		} else if kind == 5 {
			operation := &item.operation.(Dropout)
			CheckpointPut32(output, &offset, operation.rate)
		}
		width = item.width
	}
	if adam != nil {
		CheckpointPut64(output, &offset, adam.step)
		for value in ([4]f32{adam.learningRate, adam.beta1, adam.beta2, adam.epsilon}) { CheckpointPut32(output, &offset, value) }
		for value in adam.firstMoment { CheckpointPut32(output, &offset, value) }
		for value in adam.secondMoment { CheckpointPut32(output, &offset, value) }
	}
	return offset, true
}

// Inspection errors describe the supervised byte stream, not a destination model.
CheckpointErrorCode :: enum {
	None,
	Truncated,
	InvalidMagic,
	UnsupportedVersion,
	InvalidHeader,
	UnsupportedLayer,
	InvalidArchitecture,
	InvalidValue,
	Overflow,
	TrailingData,
	InvalidLimits,
	LimitExceeded,
}

// offset identifies the affected field, dimension group or layer; for Truncated
// it is the input length, and for TrailingData it is the first trailing byte.
// InvalidLimits and a maxBytes failure use zero. Offsets are input-relative.
CheckpointError :: struct {
	code: CheckpointErrorCode,
	offset: int,
}

// Counts are structural, whether or not Adam is present: parameterPointers is
// the number of ^core.Node entries, and momentElements is the number of f32s in
// EACH Adam moment array. Without Adam, CheckpointRead requires neither array.
// outputWidth is the flattened element count per sample; outputRank includes the
// batch dimension (2 for vectors, 4 for NHWC). An empty model reports its input.
CheckpointInfo :: struct {
	version: u64,
	maxLayers, maxWidth, batchCapacity: int,
	inputWidth, layerCount: int,
	hasAdam: bool,
	parameterPointers, momentElements: int,
	outputWidth, outputRank: int,
}

// Describes the last layer other than dropout/flatten. False also covers models
// with no such layer. This is structural metadata, not a PPO compatibility check.
CheckpointInspectDetails :: struct {
	effectiveOutputIsSoftmax: bool,
}

// Zero means no additional limit; negative limits are invalid. Capacity limits
// apply to the encoded capacities, not merely the number of used layers or width.
// Pointer and moment limits are checked as soon as each layer's counts are known,
// even if that layer's parameter payload is incomplete.
CheckpointInspectLimits :: struct {
	maxBytes, maxLayers, maxWidth, maxBatchCapacity: int,
	maxParameterPointers, maxMomentElements: int,
}

@(private)
checkpointReadTarget :: struct {
	maxLayers, maxWidth, batchCapacity: int,
	hasAdam: bool,
	parameterCapacity, firstCapacity, secondCapacity: int,
}

@(private)
checkpointParsed :: struct {
	info: CheckpointInfo,
	details: CheckpointInspectDetails,
	header: [10]u64,
	step: u64,
	config: [4]f32,
	// A rejected target stops parsing early; the remaining bytes are not validated.
	targetRejected: bool,
}

@(private="file")
checkpointParameterValues :: proc(input: []u8, offset: ^int, count: int, info: ^CheckpointInfo, limits: CheckpointInspectLimits, target: ^checkpointReadTarget, layerOffset: int) -> (CheckpointError, bool) {
	if info.momentElements > max(int)-count || info.parameterPointers > max(int)-2 { return {.Overflow, layerOffset}, false }
	info.parameterPointers += 2
	info.momentElements += count
	if limits.maxParameterPointers > 0 && info.parameterPointers > limits.maxParameterPointers ||
		limits.maxMomentElements > 0 && info.momentElements > limits.maxMomentElements {
		return {.LimitExceeded, layerOffset}, false
	}
	if target != nil && target.hasAdam && (info.parameterPointers > target.parameterCapacity ||
		info.momentElements > target.firstCapacity || info.momentElements > target.secondCapacity) {
		return {}, true
	}
	if count > (len(input)-offset^)/4 { return {.Truncated, len(input)}, false }
	for _ in 0..<count {
		valueOffset := offset^
		value, valid := CheckpointGet32(input, offset)
		if !valid { return {.Truncated, len(input)}, false }
		if !AdamFinite(f64(value)) { return {.InvalidValue, valueOffset}, false }
	}
	return {}, false
}

// Validates a complete supervised checkpoint without allocation or a destination.
// The input must have valid backing storage and must not be concurrently mutated.
// A zero limits struct disables policy limits, so set them for untrusted input.
// Success reports encoded capacities and structural requirements, not proof that
// a matching compiled Sequential type exists, can be allocated, or is compatible
// with a particular destination. On failure info is zero and error identifies the
// byte problem or limit. An inspection applies only to the bytes inspected;
// keep them unchanged through restore. CheckpointRead revalidates its input but
// does not apply these policy limits. This does not inspect PPO or normalized
// checkpoints.
CheckpointInspect :: proc(input: []u8, limits: CheckpointInspectLimits = {}) -> (CheckpointInfo, CheckpointError) {
	info, _, err := CheckpointInspectWithDetails(input, limits)
	return info, err
}

// Applies the same validation as CheckpointInspect and also reports effective
// output topology. Both metadata values are zero on failure.
CheckpointInspectWithDetails :: proc(input: []u8, limits: CheckpointInspectLimits = {}) -> (CheckpointInfo, CheckpointInspectDetails, CheckpointError) {
	parsed, err := checkpointParse(input, limits, nil)
	if err.code != .None { return {}, {}, err }
	return parsed.info, parsed.details, {}
}

@(private)
checkpointParse :: proc(input: []u8, limits: CheckpointInspectLimits, target: ^checkpointReadTarget) -> (checkpointParsed, CheckpointError) {
	if limits.maxBytes < 0 || limits.maxLayers < 0 || limits.maxWidth < 0 || limits.maxBatchCapacity < 0 ||
		limits.maxParameterPointers < 0 || limits.maxMomentElements < 0 { return {}, {.InvalidLimits, 0} }
	if limits.maxBytes > 0 && len(input) > limits.maxBytes { return {}, {.LimitExceeded, 0} }

	parsed: checkpointParsed
	offset := 0
	for &value in parsed.header {
		v, ok := CheckpointGet64(input, &offset)
		if !ok { return {}, {.Truncated, len(input)} }
		value = v
	}
	header := parsed.header
	if header[0] != CHECKPOINT_MAGIC { return {}, {.InvalidMagic, 0} }
	if header[1] != CHECKPOINT_VERSION && header[1] != CHECKPOINT_SPATIAL_VERSION { return {}, {.UnsupportedVersion, 8} }
	for i in 2..=4 {
		if header[i] == 0 { return {}, {.InvalidHeader, i*8} }
		if header[i] > u64(max(int)) { return {}, {.Overflow, i*8} }
	}
	maxLayers, maxWidth, batchCapacity := int(header[2]), int(header[3]), int(header[4])
	if limits.maxLayers > 0 && maxLayers > limits.maxLayers { return {}, {.LimitExceeded, 16} }
	if limits.maxWidth > 0 && maxWidth > limits.maxWidth { return {}, {.LimitExceeded, 24} }
	if limits.maxBatchCapacity > 0 && batchCapacity > limits.maxBatchCapacity { return {}, {.LimitExceeded, 32} }
	if header[5] == 0 || header[5] > u64(maxWidth) { return {}, {.InvalidHeader, 40} }
	if header[6] > u64(maxLayers) { return {}, {.InvalidHeader, 48} }
	if header[7] == 0 { return {}, {.InvalidHeader, 56} }
	if header[9] > 1 { return {}, {.InvalidHeader, 72} }
	parsed.info = CheckpointInfo{
		version = header[1], maxLayers = maxLayers, maxWidth = maxWidth, batchCapacity = batchCapacity,
		inputWidth = int(header[5]), layerCount = int(header[6]), hasAdam = header[9] == 1,
	}
	if target != nil && (maxLayers != target.maxLayers || maxWidth != target.maxWidth ||
		batchCapacity != target.batchCapacity || parsed.info.hasAdam != target.hasAdam) {
		return checkpointParsed{targetRejected = true}, {}
	}
	width := parsed.info.inputWidth
	spatial := false
	h, w, channels := 0, 0, 0
	if header[1] == CHECKPOINT_SPATIAL_VERSION {
		dims: [3]u64
		for &dim, i in dims {
			v, ok := CheckpointGet64(input, &offset)
			if !ok { return {}, {.Truncated, len(input)} }
			if v > u64(maxWidth) { return {}, {.InvalidArchitecture, 80+i*8} }
			dim = v
		}
		if dims != ([3]u64{}) {
			if dims[0] == 0 || dims[1] == 0 || dims[2] == 0 { return {}, {.InvalidArchitecture, 80} }
			h, w, channels = int(dims[0]), int(dims[1]), int(dims[2])
			if h > maxWidth/w || h*w > maxWidth/channels || h*w*channels != width { return {}, {.InvalidArchitecture, 80} }
			spatial = true
		}
	}
	for _ in 0..<parsed.info.layerCount {
		layerOffset := offset
		kind, ok := CheckpointGet64(input, &offset); if !ok { return {}, {.Truncated, len(input)} }
		layerWidth, ok2 := CheckpointGet64(input, &offset); if !ok2 { return {}, {.Truncated, len(input)} }
		if kind > 9 || header[1] == CHECKPOINT_VERSION && kind > 5 { return {}, {.UnsupportedLayer, layerOffset} }
		if kind != 5 && kind != 7 { parsed.details.effectiveOutputIsSoftmax = kind == 4 }
		if layerWidth == 0 || layerWidth > u64(maxWidth) { return {}, {.InvalidArchitecture, layerOffset+8} }
		if kind != 0 && kind != 6 && kind != 8 && kind != 9 && layerWidth != u64(width) { return {}, {.InvalidArchitecture, layerOffset+8} }
		if kind == 0 {
			if spatial { return {}, {.InvalidArchitecture, layerOffset} }
			if width > max(int)/int(layerWidth) { return {}, {.Overflow, layerOffset+8} }
			weights := width*int(layerWidth)
			if weights > max(int)-int(layerWidth) { return {}, {.Overflow, layerOffset+8} }
			err, rejected := checkpointParameterValues(input, &offset, weights+int(layerWidth), &parsed.info, limits, target, layerOffset)
			if err.code != .None { return {}, err }
			if rejected { return checkpointParsed{targetRejected = true}, {} }
		} else if kind == 5 {
			rateOffset := offset
			rate, valid := CheckpointGet32(input, &offset)
			if !valid { return {}, {.Truncated, len(input)} }
			if !(rate >= 0 && rate < 1) { return {}, {.InvalidValue, rateOffset} }
		} else if kind == 7 {
			spatial = false
		} else if kind == 8 || kind == 9 {
			if !spatial { return {}, {.InvalidArchitecture, layerOffset} }
			values: [3]u64
			for &value in values {
				fieldOffset := offset
				v, valid := CheckpointGet64(input, &offset)
				if !valid { return {}, {.Truncated, len(input)} }
				if v > u64(max(int)) { return {}, {.Overflow, fieldOffset} }
				value = v
			}
			kh, kw, stride := int(values[0]), int(values[1]), int(values[2])
			if kh <= 0 || kw <= 0 || stride <= 0 || kh > h || kw > w { return {}, {.InvalidArchitecture, layerOffset} }
			if kh > max(int)/kw { return {}, {.Overflow, layerOffset} }
			oh, ow := (h-kh)/stride+1, (w-kw)/stride+1
			if oh > maxWidth/ow || oh*ow > maxWidth/channels || oh*ow*channels != int(layerWidth) { return {}, {.InvalidArchitecture, layerOffset} }
			h, w = oh, ow
		} else if kind == 6 {
			if !spatial { return {}, {.InvalidArchitecture, layerOffset} }
			if maxWidth > max(int)/maxWidth { return {}, {.Overflow, 24} }
			values: [5]u64
			for &value in values {
				fieldOffset := offset
				v, valid := CheckpointGet64(input, &offset)
				if !valid { return {}, {.Truncated, len(input)} }
				if v > u64(max(int)) { return {}, {.Overflow, fieldOffset} }
				value = v
			}
			kh, kw, oc, stride, pad := int(values[0]), int(values[1]), int(values[2]), int(values[3]), int(values[4])
			if kh <= 0 || kw <= 0 || oc <= 0 || oc > maxWidth { return {}, {.InvalidArchitecture, layerOffset} }
			capacity := maxWidth*maxWidth
			if kh > max(int)/kw { return {}, {.Overflow, layerOffset+24} }
			area := kh*kw
			if area > max(int)/channels { return {}, {.Overflow, layerOffset} }
			fanIn := area*channels
			if fanIn > max(int)/oc { return {}, {.Overflow, layerOffset+32} }
			count := fanIn*oc
			if count > capacity { return {}, {.InvalidArchitecture, layerOffset} }
			if stride <= 0 { return {}, {.InvalidArchitecture, layerOffset} }
			if pad > (max(int)-h)/2 || pad > (max(int)-w)/2 { return {}, {.Overflow, layerOffset+48} }
			oh, okh := Conv2DDimension(h, kh, stride, pad)
			ow, okw := Conv2DDimension(w, kw, stride, pad)
			if !okh || !okw || oh <= 0 || ow <= 0 { return {}, {.InvalidArchitecture, layerOffset} }
			if oh > max(int)/ow { return {}, {.Overflow, layerOffset} }
			spatialArea := oh*ow
			if spatialArea > max(int)/oc { return {}, {.Overflow, layerOffset} }
			outputCount := spatialArea*oc
			if outputCount > maxWidth || outputCount != int(layerWidth) { return {}, {.InvalidArchitecture, layerOffset} }
			if oh-1 > (max(int)-(kh-1))/stride || ow-1 > (max(int)-(kw-1))/stride { return {}, {.Overflow, layerOffset+40} }
			if count > max(int)-oc { return {}, {.Overflow, layerOffset} }
			err, rejected := checkpointParameterValues(input, &offset, count+oc, &parsed.info, limits, target, layerOffset)
			if err.code != .None { return {}, err }
			if rejected { return checkpointParsed{targetRejected = true}, {} }
			h, w, channels = oh, ow, oc
		}
		width = int(layerWidth)
	}
	parsed.info.outputWidth = width
	parsed.info.outputRank = 2
	if spatial { parsed.info.outputRank = 4 }
	if parsed.info.hasAdam {
		ok: bool
		parsed.step, ok = CheckpointGet64(input, &offset); if !ok { return {}, {.Truncated, len(input)} }
		configOffset := offset
		for &value in parsed.config {
			v, valid := CheckpointGet32(input, &offset)
			if !valid { return {}, {.Truncated, len(input)} }
			value = v
		}
		config := parsed.config
		if !AdamFinite(f64(config[0])) || config[0] <= 0 { return {}, {.InvalidValue, configOffset} }
		if !(config[1] >= 0 && config[1] < 1) { return {}, {.InvalidValue, configOffset+4} }
		if !(config[2] >= 0 && config[2] < 1) { return {}, {.InvalidValue, configOffset+8} }
		if !AdamFinite(f64(config[3])) || config[3] <= 0 { return {}, {.InvalidValue, configOffset+12} }
		if parsed.info.momentElements > (len(input)-offset)/8 { return {}, {.Truncated, len(input)} }
		for _ in 0..<parsed.info.momentElements {
			valueOffset := offset
			value, valid := CheckpointGet32(input, &offset)
			if !valid { return {}, {.Truncated, len(input)} }
			if !AdamFinite(f64(value)) { return {}, {.InvalidValue, valueOffset} }
		}
		for _ in 0..<parsed.info.momentElements {
			valueOffset := offset
			value, valid := CheckpointGet32(input, &offset)
			if !valid { return {}, {.Truncated, len(input)} }
			if !AdamFinite(f64(value)) || value < 0 { return {}, {.InvalidValue, valueOffset} }
		}
	}
	if offset != len(input) { return {}, {.TrailingData, offset} }
	return parsed, {}
}

// Restores directly into model's final location. On failure no destination is
// changed. Capacities must exactly match the checkpoint. If Adam is recorded,
// adam and storage of at least two node pointers per trainable layer and one element
// per parameter in each moment slice are required. If absent, adam must be nil.
// Incompatible header capacities/Adam presence and insufficient optimizer storage
// are rejected as soon as the relevant information is available.
// Input, model, shuffleState, Adam and all storage slices must be disjoint and
// have valid backing storage; concurrent mutation is forbidden. Do not move or
// copy the restored model. Trailing input bytes are rejected.
CheckpointRead :: proc(model: ^Sequential($maxLayers, $maxWidth, $batchCapacity), adam: ^Adam, shuffleState: ^u64, input: []u8, parameterStorage: []^core.Node, firstMoment, secondMoment: []f32) -> bool {
	if model == nil || shuffleState == nil || maxLayers <= 0 || maxWidth <= 0 || batchCapacity <= 0 { return false }
	target := checkpointReadTarget{
		maxLayers = maxLayers, maxWidth = maxWidth, batchCapacity = batchCapacity, hasAdam = adam != nil,
		parameterCapacity = len(parameterStorage), firstCapacity = len(firstMoment), secondCapacity = len(secondMoment),
	}
	parsed, err := checkpointParse(input, {}, &target)
	if err.code != .None || parsed.targetRejected { return false }
	info := parsed.info
	header, step, config := parsed.header, parsed.step, parsed.config
	offset := 0
	width := int(header[5])
	parameterCount := 0
	elementCount := info.momentElements
	// All operations below are guaranteed by the validated architecture and capacities.
	if header[1] == CHECKPOINT_SPATIAL_VERSION {
		offset = 80
		ih, _ := CheckpointGet64(input, &offset)
		iw, _ := CheckpointGet64(input, &offset)
		ic, _ := CheckpointGet64(input, &offset)
		if ih != 0 { SequentialInitSpatial(model, int(ih), int(iw), int(ic), 1) } else { SequentialInit(model, int(header[5]), 1) }
	} else {
		SequentialInit(model, int(header[5]), 1)
		offset = 80
	}
	width = int(header[5])
	parameterCount = 0
	for _ in 0..<int(header[6]) {
		kind, _ := CheckpointGet64(input, &offset)
		w, _ := CheckpointGet64(input, &offset)
		if kind == 0 {
			SequentialAddDense(model, int(w))
			item := &model.layers[model.layerCount-1]
			dense := &item.storage.(DenseStorage(maxWidth))
			for &value in dense.weightData[:width*int(w)] { value, _ = CheckpointGet32(input, &offset) }
			for &value in dense.biasData[:int(w)] { value, _ = CheckpointGet32(input, &offset) }
			if adam != nil { parameterStorage[parameterCount] = &dense.weights; parameterStorage[parameterCount+1] = &dense.bias; parameterCount += 2 }
		} else if kind == 6 {
			values: [5]u64
			for &value in values { value, _ = CheckpointGet64(input, &offset) }
			SequentialAddConv2D(model, int(values[0]), int(values[1]), int(values[2]), int(values[3]), int(values[4]))
			item := &model.layers[model.layerCount-1]
			conv := &item.storage.(Conv2DStorage(maxWidth))
			for &value in conv.weights.value.data { value, _ = CheckpointGet32(input, &offset) }
			for &value in conv.bias.value.data { value, _ = CheckpointGet32(input, &offset) }
			if adam != nil { parameterStorage[parameterCount] = &conv.weights; parameterStorage[parameterCount+1] = &conv.bias; parameterCount += 2 }
		} else if kind == 8 || kind == 9 {
			values: [3]u64
			for &value in values { value, _ = CheckpointGet64(input, &offset) }
			poolKind := PoolKind.Max
			if kind == 9 { poolKind = .Average }
			SequentialAddPool2D(model, poolKind, int(values[0]), int(values[1]), int(values[2]))
		} else if kind == 7 {
			SequentialAddFlatten(model)
		} else if kind == 5 {
			rate, _ := CheckpointGet32(input, &offset)
			SequentialAddDropout(model, rate)
		} else {
			SequentialAddActivation(model, ActivationKind(kind-1))
		}
		width = int(w)
	}
	model.randomState = header[7]
	shuffleState^ = header[8]
	if adam != nil {
		offset += 24
		for i in 0..<elementCount { firstMoment[i], _ = CheckpointGet32(input, &offset) }
		for i in 0..<elementCount { secondMoment[i], _ = CheckpointGet32(input, &offset) }
		adam^ = Adam{parameterStorage[:parameterCount], firstMoment[:elementCount], secondMoment[:elementCount], step, config[0], config[1], config[2], config[3]}
	}
	return true
}

