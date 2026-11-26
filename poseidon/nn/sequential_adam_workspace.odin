package nn

import "../core"

// Inline storage for parameterCapacity node pointers and elementCapacity floats
// in EACH moment buffer. Size these from SequentialAdamRequirements; zero
// capacities are allowed for a nonempty model without trainable layers.
// Initialize in the final location. After initialization, neither the model nor
// workspace may be copied or moved while borrowed pointers are in use. The model,
// workspace, and any rebound parameter data must outlive the optimizer and every
// compiled handle using it. No concurrent mutation is permitted.
SequentialAdamWorkspace :: struct($parameterCapacity, $elementCapacity: int) {
	optimizer: Adam,
	parameterStorage: [parameterCapacity]^core.Node,
	firstMoment, secondMoment: [elementCapacity]f32,
	self: rawptr,
}

// Initializes or resets the workspace in place, using the same defaults and
// parameter order as SequentialAdamInit. Only required array prefixes are
// modified; unused tails are retained. Failure leaves the entire workspace and
// model unchanged. The whole workspace must be disjoint from the model and all
// parameter value/gradient data, including externally rebound data. Other live
// objects must not overlap it either. All backing storage must be valid.
//
// Reinitialize after changing/reinitializing the model; success resets moments
// and step and may change the binding. A compiled handle retaining the optimizer
// address sees that reset; recompile it when binding to a different model.
// No heap allocation; validation uses scratch proportional to maxLayers.
SequentialAdamWorkspaceInit :: proc(
	model: ^Sequential($maxLayers, $maxWidth, $batchCapacity),
	workspace: ^SequentialAdamWorkspace($parameterCapacity, $elementCapacity),
	learningRate: f32 = 0.001, beta1: f32 = 0.9, beta2: f32 = 0.999, epsilon: f32 = 1e-8,
) -> bool {
	if model == nil || workspace == nil { return false }
	modelRange, valid := SequentialAdamRange(rawptr(model), 1, size_of(model^))
	if !valid { return false }
	workspaceRange, workspaceValid := SequentialAdamRange(rawptr(workspace), 1, size_of(workspace^))
	if !workspaceValid || SequentialAdamRangesOverlap(modelRange, workspaceRange) { return false }

	count, elements, requirementsOk := SequentialAdamRequirements(model)
	if !requirementsOk || count > parameterCapacity || elements > elementCapacity { return false }
	parameters: [2 * maxLayers]^core.Node
	list, listOk := SequentialParameters(model, parameters[:])
	if !listOk || len(list) != count { return false }
	for parameter in list {
		for tensor in ([2]core.Tensor{parameter.value, parameter.grad}) {
			dataRange, dataValid := SequentialAdamRange(rawptr(raw_data(tensor.data)), len(tensor.data), size_of(f32))
			if !dataValid || SequentialAdamRangesOverlap(workspaceRange, dataRange) { return false }
		}
	}
	if !SequentialAdamInit(model, &workspace.optimizer, workspace.parameterStorage[:], workspace.firstMoment[:], workspace.secondMoment[:], learningRate, beta1, beta2, epsilon) { return false }
	workspace.self = rawptr(workspace)
	return true
}

// Returns the in-place Adam for SequentialCompile/SequentialFitBatches, or nil
// for an uninitialized, nil, or copied/moved workspace. This only checks the
// workspace address: it cannot validate the model's lifetime or invalidate a
// pointer already handed out. Never copy or move a workspace with live borrowers.
//
// CheckpointRead can restore directly into an already initialized workspace by
// passing &workspace.optimizer and its three storage slices. Respect that API's
// disjointness requirements. Do NOT call Init after restoring Adam: it resets the
// restored moments and step. A model-only restore requires reinitialization.
SequentialAdamWorkspaceOptimizer :: proc(workspace: ^SequentialAdamWorkspace($parameterCapacity, $elementCapacity)) -> ^Adam {
	if workspace == nil || workspace.self != rawptr(workspace) { return nil }
	return &workspace.optimizer
}
