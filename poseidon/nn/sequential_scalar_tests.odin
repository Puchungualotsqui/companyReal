package nn

import "core:mem"
import "core:testing"

@(test)
SequentialPredictScalarOwnedValue :: proc(t: ^testing.T) {
	model: Sequential(2, 2, 2)
	compiled: CompiledSequential(2, 2, 2)
	initialized := SequentialInit(&model, 2, 17) && SequentialAddDense(&model, 1) &&
		SequentialAddDropout(&model, 0.5) && SequentialCompile(&compiled, &model)
	testing.expect(t, initialized)
	if !initialized { return }
	dense := TestDenseStorage(&model.layers[0])
	dense.weightData[0], dense.weightData[1], dense.biasData[0] = 3, -1, 1
	dense.weightGrad[0], dense.biasGrad[0] = 7, 8
	input, nextInput := [2]f32{2, 1}, [2]f32{4, 1}
	state := model.randomState
	current, next: f32
	currentOk, nextOk: bool
	{
		context.allocator = mem.nil_allocator()
		current, currentOk = SequentialPredictScalar(&model, input[:])
		next, nextOk = CompiledSequentialPredictScalar(&compiled, nextInput[:])
	}
	testing.expect(t, currentOk && nextOk && current == 6 && next == 12)
	testing.expect(t, input == [2]f32{2, 1} && nextInput == [2]f32{4, 1})
	testing.expect(t, model.randomState == state && dense.weightData[0] == 3 && dense.weightData[1] == -1 && dense.biasData[0] == 1)
	testing.expect(t, dense.weightGrad[0] == 7 && dense.biasGrad[0] == 8)
	dropout := &model.layers[1].operation.(Dropout)
	testing.expect(t, !dropout.training)
	// Returned scalars survive further inference, unlike the borrowed prediction.
	borrowed, ok := SequentialPredict(&model, input[:])
	testing.expect(t, ok && len(borrowed) == 1)
	if !ok || len(borrowed) != 1 { return }
	testing.expect(t, borrowed[0] == current)
	third, thirdOk := SequentialPredictScalar(&model, nextInput[:])
	testing.expect(t, thirdOk && third == next && current == 6 && borrowed[0] == next)
}

@(test)
SequentialPredictScalarRejectsInvalidInput :: proc(t: ^testing.T) {
	model: Sequential(1, 2, 2)
	initialized := SequentialInit(&model, 2) && SequentialAddDense(&model, 1)
	testing.expect(t, initialized)
	if !initialized { return }
	input := [2]f32{1, 2}
	_, predicted := SequentialPredictScalar(&model, input[:])
	testing.expect(t, predicted)
	shape, scratch, state := model.inputShape, model.inputData, model.randomState
	missing: ^Sequential(1, 2, 2)
	missingCompiled: ^CompiledSequential(1, 2, 2)
	_, ok := SequentialPredictScalar(missing, input[:])
	testing.expect(t, !ok)
	_, ok = CompiledSequentialPredictScalar(missingCompiled, input[:])
	testing.expect(t, !ok)
	emptyCompiled: CompiledSequential(1, 2, 2)
	_, ok = CompiledSequentialPredictScalar(&emptyCompiled, input[:])
	testing.expect(t, !ok)
	_, ok = SequentialPredictScalar(&model, nil)
	testing.expect(t, !ok)
	_, ok = SequentialPredictScalar(&model, input[:1])
	testing.expect(t, !ok)
	twoRows := [4]f32{1, 2, 3, 4}
	_, ok = SequentialPredictScalar(&model, twoRows[:])
	testing.expect(t, !ok)
	_, ok = SequentialPredictScalar(&model, model.inputData[:2])
	testing.expect(t, !ok)
	bad := [2]f32{transmute(f32)u32(0x7fc00000), 1}
	_, ok = SequentialPredictScalar(&model, bad[:])
	testing.expect(t, !ok)
	bad[0] = transmute(f32)u32(0x7f800000)
	_, ok = SequentialPredictScalar(&model, bad[:])
	testing.expect(t, !ok)
	testing.expect(t, model.inputShape == shape && model.inputData == scratch && model.randomState == state)
	copied := model
	_, ok = SequentialPredictScalar(&copied, input[:])
	testing.expect(t, !ok)

	wideOutput: Sequential(1, 2, 2)
	initialized = SequentialInit(&wideOutput, 2) && SequentialAddDense(&wideOutput, 2)
	testing.expect(t, initialized)
	if !initialized { return }
	before := wideOutput.inputShape
	_, ok = SequentialPredictScalar(&wideOutput, input[:])
	testing.expect(t, !ok && wideOutput.inputShape == before)
}

@(test)
SequentialPredictScalarRejectsNonFiniteResult :: proc(t: ^testing.T) {
	model: Sequential(1, 1, 1)
	initialized := SequentialInit(&model, 1) && SequentialAddDense(&model, 1)
	testing.expect(t, initialized)
	if !initialized { return }
	TestDenseStorage(&model.layers[0]).weightData[0] = 2
	input := [1]f32{3.4e38}
	result, ok := SequentialPredictScalar(&model, input[:])
	testing.expect(t, !ok && result == 0)
}
