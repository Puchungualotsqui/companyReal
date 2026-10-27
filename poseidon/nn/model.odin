package nn

// Layers must connect in order through shared nodes; the caller owns the slice.
Model :: struct {
	layers: []Layer,
}

// On failure, earlier layers may already have been evaluated.
ModelForward :: proc(model: Model) -> bool {
	for layer in model.layers {
		if !LayerForward(layer) { return false }
	}
	return true
}

// On failure, later layers may already have accumulated gradients.
ModelBackward :: proc(model: Model) -> bool {
	for index := len(model.layers); index > 0; index -= 1 {
		if !LayerBackward(model.layers[index-1]) { return false }
	}
	return true
}
