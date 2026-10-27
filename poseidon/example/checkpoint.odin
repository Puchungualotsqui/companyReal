package main

import "../core"
import "../nn"
import "core:fmt"

// Run with: odin run example/checkpoint.odin -file
main :: proc() {
	// Five two-feature rows require three batches at capacity two.
	inputs := [10]f32{-2, 1, -1, 2, 0, -1, 1, 3, 3, 0.5}
	targets := [5]f32{1, 0, 2, -1, 4}
	indices, restoredIndices: [5]int
	shuffleState: u64 = 55

	// Layer capacity includes the activation. Initialize in place; do not copy
	// an initialized or restored Sequential, because it contains self-pointers.
	model: nn.Sequential(3, 3, 2)
	assert(nn.SequentialInit(&model, 2, seed = 11))
	assert(nn.SequentialAddDense(&model, 3))
	assert(nn.SequentialAddActivation(&model, .Tanh))
	assert(nn.SequentialAddDense(&model, 1))

	// Two dense layers have four parameter nodes and 2*3+3+3*1+1 = 13
	// scalar parameters. These arrays must outlive the optimizer.
	parameterStorage: [4]^core.Node
	parameters, ok := nn.SequentialParameters(&model, parameterStorage[:])
	assert(ok)
	firstMoment, secondMoment: [13]f32
	adam: nn.Adam
	assert(nn.AdamInit(&adam, parameters, firstMoment[:], secondMoment[:], learningRate = 0.01))

	initialLoss, evaluated := nn.SequentialFitBatches(&model, inputs[:], targets[:], indices[:], &shuffleState, epochs = 0, optimizer = &adam)
	assert(evaluated)
	beforeLoss, trained := nn.SequentialFitBatches(&model, inputs[:], targets[:], indices[:], &shuffleState, epochs = 3, optimizer = &adam)
	assert(trained && adam.step == 9)

	// CheckpointWrite allocates nothing: supply disjoint output storage and use
	// only the returned byte count. The buffer must be large enough for the model.
	checkpoint: [1024]u8
	size, written := nn.CheckpointWrite(&model, &adam, shuffleState, checkpoint[:])
	assert(written && size > 0)

	// Restore into a fresh model at its final address, with exactly matching
	// capacities. Read builds the architecture and binds Adam to these new nodes;
	// all destination buffers must be disjoint and outlive the restored optimizer.
	restored: nn.Sequential(3, 3, 2)
	restoredAdam: nn.Adam
	restoredShuffle: u64
	restoredParameters: [4]^core.Node
	restoredFirst, restoredSecond: [13]f32
	read := nn.CheckpointRead(&restored, &restoredAdam, &restoredShuffle, checkpoint[:size], restoredParameters[:], restoredFirst[:], restoredSecond[:])
	assert(read)
	assert(restoredShuffle == shuffleState && restored.randomState == model.randomState)
	assert(restoredAdam.step == adam.step && restoredFirst == firstMoment && restoredSecond == secondMoment)

	// Continue both paths with shuffle and Adam. Matching checkpoints confirm
	// parameters, architecture, RNG, optimizer configuration and moments agree.
	originalLoss, originalTrained := nn.SequentialFitBatches(&model, inputs[:], targets[:], indices[:], &shuffleState, epochs = 4, optimizer = &adam)
	resumedLoss, resumed := nn.SequentialFitBatches(&restored, inputs[:], targets[:], restoredIndices[:], &restoredShuffle, epochs = 4, optimizer = &restoredAdam)
	assert(originalTrained && resumed && originalLoss == resumedLoss)
	assert(adam.step == 21 && restoredAdam.step == adam.step && restoredShuffle == shuffleState)
	originalBytes, restoredBytes: [1024]u8
	originalSize, originalWritten := nn.CheckpointWrite(&model, &adam, shuffleState, originalBytes[:])
	restoredSize, restoredWritten := nn.CheckpointWrite(&restored, &restoredAdam, restoredShuffle, restoredBytes[:])
	assert(originalWritten && restoredWritten && originalSize == restoredSize)
	for byte, i in originalBytes[:originalSize] {
		assert(byte == restoredBytes[i])
	}

	fmt.printf("MSE: %.6f initially, %.6f at checkpoint, %.6f after resume\n", initialLoss, beforeLoss, resumedLoss)
	fmt.printf("Checkpoint: %d bytes; resumed Adam step %d; continued states match\n", size, restoredAdam.step)
}
