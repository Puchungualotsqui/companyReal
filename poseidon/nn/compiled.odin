package nn

// A non-owning supervised configuration. The model must remain initialized in
// place, and an Adam optimizer and its backing storage must outlive this handle.
// Compile only binds configuration; data, loss/optimizer compatibility and
// optimizer state are validated by the underlying batch operations at use time.
// This API does not allocate, infer metrics, split data, or own scratch/history.
CompiledSequential :: struct($maxLayers, $maxWidth, $batchCapacity: int) {
	model: ^Sequential(maxLayers, maxWidth, batchCapacity),
	loss: SequentialLoss,
	optimizer: SequentialOptimizer,
}

// On failure the destination is unchanged. Recompiling replaces the binding;
// it does not reset or initialize the model or optimizer.
SequentialCompile :: proc(compiled: ^CompiledSequential($maxLayers, $maxWidth, $batchCapacity), model: ^Sequential(maxLayers, maxWidth, batchCapacity), loss: SequentialLoss = MSE{}, optimizer: SequentialOptimizer = SequentialSGD{0.1}) -> bool {
	if compiled == nil || model == nil || model.self != rawptr(model) || model.layerCount <= 0 || model.layerCount > maxLayers { return false }
	compiled^ = {model, loss, optimizer}
	return true
}

// Groups optional supervised fit settings. Start from SequentialFitOptionsDefault
// rather than a zero value if you want the same defaults as CompiledSequentialFit.
// A zero epochs value deliberately requests evaluation without training.
SequentialFitOptions :: struct {
	batchSize:         int,
	epochs:            int,
	shuffle:           bool,
	validationInputs:  []f32,
	validationTargets: []f32,
	history:           []EpochMetrics,
	l2:                f32,
	earlyStopping:     ^SequentialEarlyStopping,
	bestSnapshot:      []u8,
}

SequentialFitOptionsDefault :: proc() -> SequentialFitOptions {
	return SequentialFitOptions{epochs = 200, shuffle = true}
}

// All buffers and RNG remain caller-owned; see SequentialFitBatches for their
// sizes, overlap rules, mutation behavior, and early-stopping semantics.
CompiledSequentialFitWithOptions :: proc(
	compiled: ^CompiledSequential($maxLayers, $maxWidth, $batchCapacity),
	inputs, targets: []f32,
	indices: []int,
	state: ^u64,
	options: SequentialFitOptions = SequentialFitOptions{epochs = 200, shuffle = true},
) -> (f32, bool) {
	if compiled == nil || compiled.model == nil { return 0, false }
	return SequentialFitBatches(
		compiled.model, inputs, targets, indices, state, options.batchSize, compiled.loss,
		options.epochs, compiled.optimizer, options.shuffle, options.validationInputs,
		options.validationTargets, options.history, options.l2, options.earlyStopping, options.bestSnapshot,
	)
}

// Positional/named-argument variant kept for compatibility. All buffers and RNG
// remain caller-owned; see SequentialFitBatches for the full contract.
CompiledSequentialFit :: proc(compiled: ^CompiledSequential($maxLayers, $maxWidth, $batchCapacity), inputs, targets: []f32, indices: []int, state: ^u64, batchSize: int = 0, epochs: int = 200, shuffle: bool = true, validationInputs: []f32 = nil, validationTargets: []f32 = nil, history: []EpochMetrics = nil, l2: f32 = 0, earlyStopping: ^SequentialEarlyStopping = nil, bestSnapshot: []u8 = nil) -> (f32, bool) {
	if compiled == nil || compiled.model == nil { return 0, false }
	return SequentialFitBatches(compiled.model, inputs, targets, indices, state, batchSize, compiled.loss, epochs, compiled.optimizer, shuffle, validationInputs, validationTargets, history, l2, earlyStopping, bestSnapshot)
}

// Writes predictions into caller-owned output; see SequentialPredictBatches for
// shape, overlap, and mutation requirements. No compilation state is modified.
CompiledSequentialPredict :: proc(compiled: ^CompiledSequential($maxLayers, $maxWidth, $batchCapacity), inputs, outputs: []f32, batchSize: int = 0) -> bool {
	if compiled == nil || compiled.model == nil do return false
	return SequentialPredictBatches(compiled.model, inputs, outputs, batchSize)
}

// Evaluation returns only data loss, uses model activation scratch, and cannot
// run concurrently with training on the same model. Zero batchSize means the
// model capacity, matching fit. Optimizer state is not consulted or modified.
CompiledSequentialEvaluate :: proc(compiled: ^CompiledSequential($maxLayers, $maxWidth, $batchCapacity), inputs, targets: []f32, batchSize: int = 0) -> (f32, bool) {
	if compiled == nil || compiled.model == nil { return 0, false }
	actualBatchSize := batchSize
	if actualBatchSize == 0 { actualBatchSize = batchCapacity }
	return SequentialEvaluateBatches(compiled.model, inputs, targets, actualBatchSize, compiled.loss)
}
