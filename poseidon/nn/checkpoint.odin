package nn

import "../core"


// Version 1 uses little-endian u64 fields and IEEE-754 f32 values. It records
// capacities, architecture, model RNG state, parameters, shuffle state and,
// optionally, Adam's configuration, step and moments. Transient activations and
// gradients and dropout masks are not saved. Checkpoints support resuming at an
// epoch boundary, not a pending forward/backward pass or mid-epoch shuffle.
// Kind 5 adds a dropout rate to v1; older readers may reject checkpoints
// containing dropout. Inputs and outputs must not overlap any other storage.
CHECKPOINT_MAGIC :: u64(0x3154504b434e4e50)
CHECKPOINT_VERSION :: u64(1)

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
// present, must reference exactly the model's dense parameters in layer order.
// All slices and objects must have valid backing storage and be disjoint; no
// concurrent mutation is permitted. An initialized model must not have been copied.
CheckpointWrite :: proc(model: ^Sequential($maxLayers, $maxWidth, $batchCapacity), adam: ^Adam, shuffleState: u64, output: []u8) -> (int, bool) {
	if model == nil || model.self != rawptr(model) || maxLayers <= 0 || maxWidth <= 0 || batchCapacity <= 0 || model.inputWidth <= 0 || model.inputWidth > maxWidth || model.layerCount < 0 || model.layerCount > maxLayers || model.randomState == 0 { return 0, false }
	if adam != nil && !AdamConfigValid(adam) { return 0, false }
	// Accumulate against output length, avoiding arithmetic overflow.
	size := 80
	if len(output) < size { return 0, false }
	parameterCount, elementCount, width := 0, 0, model.inputWidth
	for i in 0..<model.layerCount {
		item := &model.layers[i]
		if item.width <= 0 || item.width > maxWidth || len(output)-size < 16 { return 0, false }
		size += 16
		switch &operation in item.operation {
		case Dense:
			if operation.weights != &item.weights || operation.bias != &item.bias || item.weightShape != ([2]int{width, item.width}) || item.biasShape != ([1]int{item.width}) ||
				!core.TensorValid(item.weights.value) || !core.TensorValid(item.bias.value) ||
				!core.SameShape(item.weights.value, core.Tensor{shape = item.weightShape[:]}) || !core.SameShape(item.bias.value, core.Tensor{shape = item.biasShape[:]}) { return 0, false }
			weights := width * item.width
			if weights > max(int)-item.width { return 0, false }
			count := weights + item.width
			if count > (len(output)-size)/4 { return 0, false }
			size += count*4
			if adam != nil {
				if parameterCount > len(adam.parameters) || len(adam.parameters)-parameterCount < 2 || adam.parameters[parameterCount] != &item.weights || adam.parameters[parameterCount+1] != &item.bias { return 0, false }
			}
			parameterCount += 2
			if elementCount > max(int)-count { return 0, false }
			elementCount += count
			for value in item.weights.value.data { if !AdamFinite(f64(value)) { return 0, false } }
			for value in item.bias.value.data { if !AdamFinite(f64(value)) { return 0, false } }
		case Relu, Sigmoid, Tanh, Softmax:
			if item.width != width { return 0, false }
		case Dropout:
			if item.width != width || !(operation.rate >= 0 && operation.rate < 1) || operation.randomState != &model.randomState || len(output)-size < 4 { return 0, false }
			size += 4
		case nil:
			return 0, false
		}
		width = item.width
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
	for value in ([10]u64{CHECKPOINT_MAGIC, CHECKPOINT_VERSION, u64(maxLayers), u64(maxWidth), u64(batchCapacity), u64(model.inputWidth), u64(model.layerCount), model.randomState, shuffleState, u64(adam != nil)}) { CheckpointPut64(output, &offset, value) }
	width = model.inputWidth
	for i in 0..<model.layerCount {
		item := &model.layers[i]
		kind: u64
		switch operation in item.operation {
		case Dense: kind = 0
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
			for value in item.weights.value.data { CheckpointPut32(output, &offset, value) }
			for value in item.bias.value.data { CheckpointPut32(output, &offset, value) }
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

// Restores directly into model's final location. On failure no destination is
// changed. Capacities must exactly match the checkpoint. If Adam is recorded,
// adam and storage of at least two node pointers per dense layer and one element
// per parameter in each moment slice are required. If absent, adam must be nil.
// Input, model, shuffleState, Adam and all storage slices must be disjoint and
// have valid backing storage; concurrent mutation is forbidden. Do not move or
// copy the restored model. Trailing input bytes are rejected.
CheckpointRead :: proc(model: ^Sequential($maxLayers, $maxWidth, $batchCapacity), adam: ^Adam, shuffleState: ^u64, input: []u8, parameterStorage: []^core.Node, firstMoment, secondMoment: []f32) -> bool {
	if model == nil || shuffleState == nil || maxLayers <= 0 || maxWidth <= 0 || batchCapacity <= 0 { return false }
	offset := 0
	header: [10]u64
	for &value in header { v, ok := CheckpointGet64(input, &offset); if !ok { return false }; value = v }
	if header[0] != CHECKPOINT_MAGIC || header[1] != CHECKPOINT_VERSION || header[2] != u64(maxLayers) || header[3] != u64(maxWidth) || header[4] != u64(batchCapacity) || header[5] == 0 || header[5] > u64(maxWidth) || header[6] > u64(maxLayers) || header[7] == 0 || header[9] > 1 || (header[9] == 1) != (adam != nil) { return false }
	width := int(header[5])
	parameterCount, elementCount := 0, 0
	for _ in 0..<int(header[6]) {
		kind, ok := CheckpointGet64(input, &offset); if !ok { return false }
		w, ok2 := CheckpointGet64(input, &offset); if !ok2 || kind > 5 || w == 0 || w > u64(maxWidth) { return false }
		if kind != 0 && w != u64(width) { return false }
		if kind == 0 {
			weights := width * int(w)
			if weights > max(int)-int(w) { return false }
			count := weights + int(w)
			if count > (len(input)-offset)/4 || elementCount > max(int)-count || parameterCount > max(int)-2 { return false }
			parameterCount += 2; elementCount += count
			for _ in 0..<count { value, valid := CheckpointGet32(input, &offset); if !valid || !AdamFinite(f64(value)) { return false } }
		} else if kind == 5 {
			rate, valid := CheckpointGet32(input, &offset)
			if !valid || !(rate >= 0 && rate < 1) { return false }
		}
		width = int(w)
	}
	step: u64
	config: [4]f32
	if adam != nil {
		if len(parameterStorage) < parameterCount || len(firstMoment) < elementCount || len(secondMoment) < elementCount { return false }
		ok: bool
		step, ok = CheckpointGet64(input, &offset); if !ok { return false }
		for &value in config { v, valid := CheckpointGet32(input, &offset); if !valid { return false }; value = v }
		if !AdamFinite(f64(config[0])) || config[0] <= 0 || !(config[1] >= 0 && config[1] < 1) || !(config[2] >= 0 && config[2] < 1) || !AdamFinite(f64(config[3])) || config[3] <= 0 { return false }
		if elementCount > (len(input)-offset)/8 { return false }
		for _ in 0..<elementCount { value, valid := CheckpointGet32(input, &offset); if !valid || !AdamFinite(f64(value)) { return false } }
		for _ in 0..<elementCount { value, valid := CheckpointGet32(input, &offset); if !valid || !AdamFinite(f64(value)) || value < 0 { return false } }
	}
	if offset != len(input) { return false }
	// All operations below are guaranteed by the validated architecture and capacities.
	SequentialInit(model, int(header[5]), 1)
	offset = 80
	width = int(header[5])
	parameterCount = 0
	for _ in 0..<int(header[6]) {
		kind, _ := CheckpointGet64(input, &offset)
		w, _ := CheckpointGet64(input, &offset)
		if kind == 0 {
			SequentialAddDense(model, int(w))
			item := &model.layers[model.layerCount-1]
			for &value in item.weightData[:width*int(w)] { value, _ = CheckpointGet32(input, &offset) }
			for &value in item.biasData[:int(w)] { value, _ = CheckpointGet32(input, &offset) }
			if adam != nil { parameterStorage[parameterCount] = &item.weights; parameterStorage[parameterCount+1] = &item.bias; parameterCount += 2 }
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

