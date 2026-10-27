package nn

import "core:testing"
import "core:math"

@(test)
LinearModelTraining :: proc(t: ^testing.T) {
	model: LinearModel(1, 1, 4)
	inputs := [4]f32{-1, 0, 1, 2}
	targets := [4]f32{-1, 1, 3, 5}
	testing.expect(t, LinearInit(&model))
	loss, ok := LinearFit(&model, inputs[:], targets[:])
	testing.expect(t, ok && loss < 0.00001)
	predictions, predicted := LinearPredict(&model, inputs[:])
	testing.expect(t, predicted && math.abs(predictions[3] - 5) < 0.01)
	testing.expect(t, math.abs(model.weightData[0] - 2) < 0.01 && math.abs(model.biasData[0] - 1) < 0.01)
}

@(test)
LinearModelValidationAndBatch :: proc(t: ^testing.T) {
	model: LinearModel(2, 2, 3)
	input := [4]f32{1, 2, 3, 4}
	target := [4]f32{1, 2, 3, 4}
	_, before := LinearPredict(&model, input[:])
	testing.expect(t, !before)
	testing.expect(t, LinearInit(&model))
	_, bad := LinearFit(&model, input[:], target[:3])
	testing.expect(t, !bad)
	_, bad = LinearFit(&model, input[:], target[:], learningRate = 0)
	testing.expect(t, !bad)
	_, bad = LinearPredict(&model, input[:3])
	testing.expect(t, !bad)
	_, ok := LinearFit(&model, input[:], target[:], epochs = 1, learningRate = 0.01)
	testing.expect(t, ok)
	output, predicted := LinearPredict(&model, input[:2])
	testing.expect(t, predicted && len(output) == 2)
	copyModel := model
	_, ok = LinearPredict(&copyModel, input[:])
	testing.expect(t, !ok)
}
