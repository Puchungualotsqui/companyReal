package nn

import "core:mem"

// Fits a compiled model with an automatically allocated shuffle-index buffer of
// trainingRows * size_of(int) bytes. The allocator and its state must remain valid
// for the call and return correctly sized, aligned, disjoint storage. Every
// non-nil allocation, including a pointer returned with an error, must be
// individually freeable. For leak-free use, each free must actually release the
// allocation and report success. Inputs, model, optimizer, options storage, and
// optional shuffle state follow SequentialFitBatches' lifetime and non-overlap
// rules; history, validation, snapshots, and model/optimizer remain caller-owned.
//
// A non-nil state persists shuffle RNG across calls. If state is nil, this call
// uses a local zero seed (the underlying fitter maps it to its fixed nonzero
// seed), so repeated calls restart the shuffle stream. Returns (0, false) on
// allocation, fit, or reported free failure; true means the fit succeeded and the
// allocator reported free success. A later fit failure can leave partial updates.
// A free failure can occur after fitting, which may have completed and changed
// model, optimizer, state, history, or other outputs; do not blindly retry the fit.
//
// One free is attempted per non-nil allocation, including after an allocation
// error. If it reports an error, the allocator may have retained or released the
// storage. This API neither retries nor returns the pointer, so cleanup may leak
// and cannot be retried through this API; the boolean cannot distinguish cleanup
// from other failures. Use CompiledSequentialFitWithOptions and caller-managed
// index storage when allocation ownership or cleanup must be recoverable.
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
	loss: f32
	ok: bool
	if err == nil {
		indices := mem.slice_ptr(cast(^int)storage, rows)
		localState: u64
		shuffleState := state
		if shuffleState == nil { shuffleState = &localState }
		loss, ok = CompiledSequentialFitWithOptions(compiled, inputs, targets, indices, shuffleState, options)
	}
	if mem.free(storage, allocator) != nil { return 0, false }
	return loss, ok
}
