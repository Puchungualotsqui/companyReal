package nn

import "core:testing"

@(test)
OwnedPipelineFitCheckpointAndResume :: proc(t: ^testing.T) {
	originalOwner, restoredOwner: OwnedSequential(1, 1, 2)
	initialized := OwnedSequentialInit(&originalOwner, 1, seed = 13)
	testing.expect(t, initialized)
	if !initialized { return }
	defer OwnedSequentialDestroy(&originalOwner)
	initialized = OwnedSequentialInit(&restoredOwner, 1, seed = 17)
	testing.expect(t, initialized)
	if !initialized { return }
	defer OwnedSequentialDestroy(&restoredOwner)
	model, restored := OwnedSequentialModel(&originalOwner), OwnedSequentialModel(&restoredOwner)
	if model == nil || restored == nil { testing.expect(t, false); return }
	specs := [1]SequentialLayerSpec{SequentialDenseSpec{1}}
	_, built := SequentialAddSpecs(model, specs[:])
	_, restoredBuilt := SequentialAddSpecs(restored, specs[:])
	testing.expect(t, built && restoredBuilt)
	if !built || !restoredBuilt { return }

	ownedAdam, restoredAdamOwner: SequentialOwnedAdam
	initialized = SequentialOwnedAdamInit(model, &ownedAdam, learningRate = 0.02)
	testing.expect(t, initialized)
	if !initialized { return }
	defer SequentialOwnedAdamDestroy(&ownedAdam)
	initialized = SequentialOwnedAdamInit(restored, &restoredAdamOwner)
	testing.expect(t, initialized)
	if !initialized { return }
	defer SequentialOwnedAdamDestroy(&restoredAdamOwner)
	adam, restoredAdam := SequentialOwnedAdamOptimizer(&ownedAdam), SequentialOwnedAdamOptimizer(&restoredAdamOwner)
	compiled, restoredCompiled: CompiledSequential(1, 1, 2)
	initialized = SequentialCompile(&compiled, model, MSE{}, adam)
	testing.expect(t, initialized)
	if !initialized { return }

	inputs := [5]f32{-2, -1, 0, 1, 2}
	targets := [5]f32{-3, -1, 1, 3, 5}
	state, restoredState: u64 = 91, 0
	options := SequentialFitOptionsDefault()
	options.epochs = 2
	_, fitted := CompiledSequentialFitAuto(&compiled, inputs[:], targets[:], &state, options)
	checkpoint: [1024]u8
	size, saved := CheckpointWrite(model, adam, state, checkpoint[:])
	testing.expect(t, fitted && saved && adam.step == 6)
	if !fitted || !saved { return }
	parameters, first, second, storageOk := SequentialOwnedAdamStorage(&restoredAdamOwner)
	loaded := storageOk && CheckpointRead(restored, restoredAdam, &restoredState, checkpoint[:size], parameters, first, second)
	testing.expect(t, loaded && restoredState == state && restoredAdam.step == adam.step)
	if !loaded { return }
	initialized = SequentialCompile(&restoredCompiled, restored, MSE{}, restoredAdam)
	testing.expect(t, initialized)
	if !initialized { return }

	options.epochs = 3
	loss, ok := CompiledSequentialFitAuto(&compiled, inputs[:], targets[:], &state, options)
	restoredLoss, restoredOk := CompiledSequentialFitAuto(&restoredCompiled, inputs[:], targets[:], &restoredState, options)
	testing.expect(t, ok && restoredOk && loss == restoredLoss && state == restoredState && adam.step == 15 && restoredAdam.step == 15)
	testing.expect(t, TestDenseStorage(&model.layers[0]).weightData == TestDenseStorage(&restored.layers[0]).weightData &&
		TestDenseStorage(&model.layers[0]).biasData == TestDenseStorage(&restored.layers[0]).biasData)
	for moment, index in adam.firstMoment { testing.expect(t, moment == restoredAdam.firstMoment[index]) }
	for moment, index in adam.secondMoment { testing.expect(t, moment == restoredAdam.secondMoment[index]) }
	layers: [1]SequentialLayerDetails
	details, detailsOk := SequentialDetails(restored, layers[:])
	testing.expect(t, detailsOk && details.layerCount == 1 && details.totalParameters == 2 && details.parameterNodeCount == 2)
}
