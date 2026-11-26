package nn

// These value-only specs correspond to the existing SequentialAdd* procedures.
// All fields are passed as-is: in particular, set conv stride to 1 and pool
// stride to 2 to match the procedural defaults. Dropout's procedural default is 0.5.
SequentialDenseSpec :: struct { width: int }
SequentialActivationSpec :: struct { kind: ActivationKind }
SequentialConv2DSpec :: struct {
	kernelHeight, kernelWidth, outputChannels: int,
	stride, padding: int,
}
SequentialPool2DSpec :: struct {
	kind: PoolKind,
	kernelHeight, kernelWidth, stride: int,
}
SequentialFlattenSpec :: struct {}
SequentialDropoutSpec :: struct { rate: f32 }

SequentialLayerSpec :: union {
	SequentialDenseSpec,
	SequentialActivationSpec,
	SequentialConv2DSpec,
	SequentialPool2DSpec,
	SequentialFlattenSpec,
	SequentialDropoutSpec,
}

// Adds one spec in place, returning false for nil or an invalid spec/model. The
// same validation, mutations and RNG behavior as the corresponding add apply.
// The spec is a value; no references to it are retained and no allocation occurs.
SequentialAddSpec :: proc(model: ^Sequential($maxLayers, $maxWidth, $batchCapacity), spec: SequentialLayerSpec) -> bool {
	switch value in spec {
	case SequentialDenseSpec:
		return SequentialAddDense(model, value.width)
	case SequentialActivationSpec:
		return SequentialAddActivation(model, value.kind)
	case SequentialConv2DSpec:
		return SequentialAddConv2D(model, value.kernelHeight, value.kernelWidth, value.outputChannels, value.stride, value.padding)
	case SequentialPool2DSpec:
		return SequentialAddPool2D(model, value.kind, value.kernelHeight, value.kernelWidth, value.stride)
	case SequentialFlattenSpec:
		return SequentialAddFlatten(model)
	case SequentialDropoutSpec:
		return SequentialAddDropout(model, value.rate)
	case nil:
		return false
	}
	return false
}

// Appends specs in order without allocation. Success returns (-1, true); an add
// failure returns (index, false), where index is zero-based in this slice. Prior
// successful additions, including their RNG advances, remain; later specs are not
// attempted. There is no rollback or whole-architecture prevalidation.
//
// Basic model/count or slice preflight failure returns (-1, false), with no
// mutation. The model must already be initialized in its final location; this
// does not validate all model wiring. An empty slice succeeds for such a model,
// even if it is full. Nonempty spec storage must be valid and disjoint from the
// entire model. Specs are borrowed only for the call; avoid concurrent mutation.
SequentialAddSpecs :: proc(
	model: ^Sequential($maxLayers, $maxWidth, $batchCapacity),
	specs: []SequentialLayerSpec,
) -> (failedIndex: int, ok: bool) {
	if model == nil || model.self != rawptr(model) || model.layerCount < 0 || model.layerCount > maxLayers ||
		len(specs) < 0 { return -1, false }
	if len(specs) > 0 {
		if raw_data(specs) == nil { return -1, false }
		address, modelAddress := uintptr(raw_data(specs)), uintptr(rawptr(model))
		if address >= modelAddress {
			if address-modelAddress < uintptr(size_of(model^)) { return -1, false }
		} else if (modelAddress-address)/size_of(SequentialLayerSpec) < uintptr(len(specs)) {
			return -1, false
		}
	}
	for spec, index in specs {
		if !SequentialAddSpec(model, spec) { return index, false }
	}
	return -1, true
}
