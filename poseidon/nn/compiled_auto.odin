package nn

import "core:mem"

// Fits a compiled model with an automatically allocated shuffle-index buffer.
// The allocator must return disjoint storage and support individual frees; the
// temporary index buffer is freed before return. Inputs, model, optimizer, options
// storage, and an optional shuffle state follow SequentialFitBatches' lifetime
// and non-overlap rules. History, metric history, validation, snapshots, and the
// model/optimizer remain caller-owned.
//
// A non-nil state persists shuffle RNG across calls. If state is nil, this call
// uses a local zero seed (the underlying fitter maps it to its fixed nonzero
// seed), so repeated calls restart the shuffle stream. Allocation or argument
// failure returns (0, false); a later fit failure can leave partial updates, as
// with CompiledSequentialFitWithOptions. The temporary allocation is
// trainingRows * size_of(int) bytes; it is not retained.
CompiledSequentialFitAuto :: proc(
	compiled: ^CompiledSequential($maxLayers, $maxWidth, $batchCapacity),
	inputs, targets: []f32,
	state: ^u64 = nil,
	options: SequentialFitOptions = SequentialFitOptions{epochs = 200, shuffle = true},
	allocator := context.allocator,
) -> (f32, bool) {
	if compiled == nil || compiled.model == nil || compiled.model.self != rawptr(compiled.model) ||
		compiled.model.inputWidth <= 0 || len(inputs) == 0 || len(inputs)%compiled.model.inputWidth != 0 {
		return 0, false
	}
	rows := len(inputs)/compiled.model.inputWidth
	if rows > max(int)/size_of(int) { return 0, false }
	storage, err := mem.alloc(rows*size_of(int), align_of(int), allocator)
	if storage == nil { return 0, false }
	if err != nil {
		_ = mem.free(storage, allocator)
		return 0, false
	}
	defer mem.free(storage, allocator)
	indices := mem.slice_ptr(cast(^int)storage, rows)
	localState: u64
	shuffleState := state
	if shuffleState == nil { shuffleState = &localState }
	return CompiledSequentialFitWithOptions(compiled, inputs, targets, indices, shuffleState, options)
}
