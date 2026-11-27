package nn

import "../core"
import "../rl"
import "core:testing"

PPOCheckpointTestBufferInit :: proc(buffer: ^rl.RolloutBuffer, storage: rl.RolloutStorage) -> bool {
	return rl.RolloutBufferInit(buffer, storage, 4, 1, 2)
}

PPOCheckpointTestCollect :: proc(
	policy: ^Sequential(1, 2, 2),
	value: ^Sequential(1, 2, 2),
	state: ^PPOTrainingState,
	buffer: ^rl.RolloutBuffer,
) -> bool {
	if !rl.RolloutBufferReset(buffer) do return false
	legal := [2]bool{true, true}
	for index in 0..<buffer.capacity {
		observation := [1]f32{f32(index%3)/2}
		action, logProbability, actionOk := SequentialPolicyAction(
			policy, observation[:], legal[:], .Stochastic, &state.policyRandomState,
		)
		currentValue, valueOk := SequentialPredictScalar(value, observation[:])
		if !actionOk || !valueOk do return false
		nextObservation := [1]f32{f32(min(index+1, 3))/3}
		nextValue: f32
		if index < buffer.capacity-1 {
			prediction, nextOk := SequentialPredictScalar(value, nextObservation[:])
			if !nextOk do return false
			nextValue = prediction
		}
		reward: f32 = -0.05
		if action == 1 { reward += 0.25 }
		if !rl.RolloutBufferAppend(buffer, rl.RolloutTransition{
			observation = observation[:], action = action, reward = reward,
			value = currentValue, nextValue = nextValue,
			oldLogProbability = logProbability, legalActions = legal[:],
			terminated = index == buffer.capacity-1,
		}) {
			return false
		}
	}
	return rl.RolloutComputeGAE(buffer, 0.95, 0.9) && rl.RolloutNormalizeAdvantages(buffer) &&
		PPOTrainingStateRecordRollout(state)
}

PPOCheckpointTestParametersEqual :: proc(modelA, modelB: ^Sequential(1, 2, 2)) -> bool {
	storageA, storageB: [2]^core.Node
	parametersA, okA := SequentialParameters(modelA, storageA[:])
	parametersB, okB := SequentialParameters(modelB, storageB[:])
	if !okA || !okB || len(parametersA) != len(parametersB) do return false
	for parameter, index in parametersA {
		if len(parameter.value.data) != len(parametersB[index].value.data) do return false
		for value, element in parameter.value.data {
			if value != parametersB[index].value.data[element] do return false
		}
	}
	return true
}

PPOCheckpointTestFit :: proc(
	policy: ^Sequential(1, 2, 2),
	value: ^Sequential(1, 2, 2),
	buffer: ^rl.RolloutBuffer,
	state: ^PPOTrainingState,
	config: PPOConfig,
	fitConfig: PPOFitConfig,
	optimizer: SequentialOptimizer,
	fitStorage: PPOFitStorage,
) -> bool {
	_, ok := SequentialPPOFitStateful(policy, value, buffer, state, config, fitConfig, optimizer, fitStorage)
	return ok
}

@(test)
PPOCheckpointResumeMatchesUninterruptedTraining :: proc(t: ^testing.T) {
	policyA, valueA, policyB, valueB: Sequential(1, 2, 2)
	setupA := SequentialInit(&policyA, 1, 17) && SequentialAddDense(&policyA, 2) &&
		SequentialInit(&valueA, 1, 29) && SequentialAddDense(&valueA, 1)
	setupB := SequentialInit(&policyB, 1, 17) && SequentialAddDense(&policyB, 2) &&
		SequentialInit(&valueB, 1, 29) && SequentialAddDense(&valueB, 1)
	testing.expect(t, setupA && setupB)
	if !setupA || !setupB { return }

	policyParamsAStorage, valueParamsAStorage: [2]^core.Node
	policyParamsBStorage, valueParamsBStorage: [2]^core.Node
	policyParamsA, policyParamsAOk := SequentialParameters(&policyA, policyParamsAStorage[:])
	valueParamsA, valueParamsAOk := SequentialParameters(&valueA, valueParamsAStorage[:])
	policyParamsB, policyParamsBOk := SequentialParameters(&policyB, policyParamsBStorage[:])
	valueParamsB, valueParamsBOk := SequentialParameters(&valueB, valueParamsBStorage[:])
	testing.expect(t, policyParamsAOk && valueParamsAOk && policyParamsBOk && valueParamsBOk)
	if !policyParamsAOk || !valueParamsAOk || !policyParamsBOk || !valueParamsBOk { return }
	parametersA, parametersB: [4]^core.Node
	copy(parametersA[:2], policyParamsA)
	copy(parametersA[2:], valueParamsA)
	copy(parametersB[:2], policyParamsB)
	copy(parametersB[2:], valueParamsB)
	firstA, secondA, firstB, secondB: [6]f32
	adamA, adamB: Adam
	testing.expect(t, AdamInit(&adamA, parametersA[:], firstA[:], secondA[:], learningRate = 0.01))
	testing.expect(t, AdamInit(&adamB, parametersB[:], firstB[:], secondB[:], learningRate = 0.01))

	obsA, obsB: [4]f32
	actionsA, actionsB: [4]int
	rewardsA, rewardsB, valuesA, valuesB, nextA, nextB, advantagesA, advantagesB, returnsA, returnsB: [4]f32
	logsA, logsB: [4]f64
	legalA, legalB: [8]bool
	terminatedA, terminatedB, truncatedA, truncatedB: [4]bool
	bufferA, bufferB: rl.RolloutBuffer
	storageA := rl.RolloutStorage{
		observations = obsA[:], actions = actionsA[:], rewards = rewardsA[:], values = valuesA[:],
		nextValues = nextA[:], oldLogProbabilities = logsA[:], legalActions = legalA[:],
		terminated = terminatedA[:], truncated = truncatedA[:], advantages = advantagesA[:], returns = returnsA[:],
	}
	storageB := rl.RolloutStorage{
		observations = obsB[:], actions = actionsB[:], rewards = rewardsB[:], values = valuesB[:],
		nextValues = nextB[:], oldLogProbabilities = logsB[:], legalActions = legalB[:],
		terminated = terminatedB[:], truncated = truncatedB[:], advantages = advantagesB[:], returns = returnsB[:],
	}
	testing.expect(t, PPOCheckpointTestBufferInit(&bufferA, storageA) && PPOCheckpointTestBufferInit(&bufferB, storageB))

	indicesA, indicesB: [4]int
	batchObsA, batchObsB: [2]f32
	batchActionsA, batchActionsB: [2]int
	batchLegalA, batchLegalB: [4]bool
	batchLogsA, batchLogsB: [2]f64
	batchAdvA, batchAdvB, batchReturnsA, batchReturnsB: [2]f32
	metricsA, metricsB: [2]PPOEpochStats
	fitStorageA := PPOFitStorage{
		indices = indicesA[:], observations = batchObsA[:], actions = batchActionsA[:], legalActions = batchLegalA[:],
		oldLogProbabilities = batchLogsA[:], advantages = batchAdvA[:], returns = batchReturnsA[:], epochMetrics = metricsA[:],
	}
	fitStorageB := PPOFitStorage{
		indices = indicesB[:], observations = batchObsB[:], actions = batchActionsB[:], legalActions = batchLegalB[:],
		oldLogProbabilities = batchLogsB[:], advantages = batchAdvB[:], returns = batchReturnsB[:], epochMetrics = metricsB[:],
	}
	stateA, stateB: PPOTrainingState
	testing.expect(t, PPOTrainingStateInit(&stateA, 123, 456) && PPOTrainingStateInit(&stateB, 123, 456))
	ppoConfig := PPOConfig{0.2, 0.01, 0.5, 1}
	fitConfig := PPOFitConfig{epochs = 2, batchSize = 2, maxGradientNorm = 0.5, finalLearningRate = 0.003}
	testing.expect(t, PPOCheckpointTestCollect(&policyA, &valueA, &stateA, &bufferA))
	testing.expect(t, PPOCheckpointTestCollect(&policyB, &valueB, &stateB, &bufferB))
	testing.expect(t, PPOCheckpointTestFit(&policyA, &valueA, &bufferA, &stateA, ppoConfig, fitConfig, &adamA, fitStorageA))
	testing.expect(t, PPOCheckpointTestFit(&policyB, &valueB, &bufferB, &stateB, ppoConfig, fitConfig, &adamB, fitStorageB))
	testing.expect(t, stateA == stateB && adamA.step == adamB.step && firstA == firstB && secondA == secondB)

	checkpoint, policyScratch, valueScratch: [1024]u8
	size, saved := PPOCheckpointWrite(
		&policyB, &valueB, &adamB, stateB, ppoConfig, fitConfig,
		checkpoint[:], policyScratch[:], valueScratch[:],
	)
	testing.expect(t, saved && size > 0)
	if !saved { return }

	policyRestored, valueRestored: Sequential(1, 2, 2)
	adamRestored: Adam
	parameterStorage: [4]^core.Node
	firstRestored, secondRestored: [6]f32
	restoredState, restoredPPOConfig, restoredFitConfig, restoredOptimizer, loaded := PPOCheckpointRead(
		&policyRestored, &valueRestored, checkpoint[:size], &adamRestored,
		parameterStorage[:], firstRestored[:], secondRestored[:],
	)
	testing.expect(t, loaded && restoredState == stateB && restoredPPOConfig == ppoConfig && restoredFitConfig == fitConfig)
	testing.expect(t, loaded && adamRestored.step == adamB.step && firstRestored == firstB && secondRestored == secondB)
	if !loaded { return }
	if _, isAdam := restoredOptimizer.(^Adam); !isAdam { testing.expect(t, false); return }

	obsR: [4]f32
	actionsR: [4]int
	rewardsR, valuesR, nextR, advantagesR, returnsR: [4]f32
	logsR: [4]f64
	legalR: [8]bool
	terminatedR, truncatedR: [4]bool
	bufferR: rl.RolloutBuffer
	storageR := rl.RolloutStorage{
		observations = obsR[:], actions = actionsR[:], rewards = rewardsR[:], values = valuesR[:],
		nextValues = nextR[:], oldLogProbabilities = logsR[:], legalActions = legalR[:],
		terminated = terminatedR[:], truncated = truncatedR[:], advantages = advantagesR[:], returns = returnsR[:],
	}
	testing.expect(t, PPOCheckpointTestBufferInit(&bufferR, storageR))
	testing.expect(t, PPOCheckpointTestCollect(&policyA, &valueA, &stateA, &bufferA))
	testing.expect(t, PPOCheckpointTestCollect(&policyRestored, &valueRestored, &restoredState, &bufferR))
	statsA, fitA := SequentialPPOFitStateful(
		&policyA, &valueA, &bufferA, &stateA, ppoConfig, fitConfig, &adamA, fitStorageA,
	)
	statsR, fitR := SequentialPPOFitStateful(
		&policyRestored, &valueRestored, &bufferR, &restoredState,
		restoredPPOConfig, restoredFitConfig, restoredOptimizer, fitStorageB,
	)

	testing.expect(t, fitA && fitR && statsA.totalLoss == statsR.totalLoss)
	testing.expect(t, stateA == restoredState && adamA.step == adamRestored.step &&
		firstA == firstRestored && secondA == secondRestored)
	testing.expect(t, PPOCheckpointTestParametersEqual(&policyA, &policyRestored))
	testing.expect(t, PPOCheckpointTestParametersEqual(&valueA, &valueRestored))

	badCheckpoint := checkpoint
	badCheckpoint[0] ~= 0xff
	untouchedPolicy, untouchedValue: Sequential(1, 2, 2)
	untouchedAdam := Adam{step = 99}
	untouchedParameters: [4]^core.Node
	untouchedFirst, untouchedSecond: [6]f32
	for &item in untouchedFirst { item = 17 }
	for &item in untouchedSecond { item = 19 }
	_, _, _, _, badRead := PPOCheckpointRead(
		&untouchedPolicy, &untouchedValue, badCheckpoint[:size], &untouchedAdam,
		untouchedParameters[:], untouchedFirst[:], untouchedSecond[:],
	)
	testing.expect(t, !badRead && untouchedPolicy.self == nil && untouchedValue.self == nil)
	testing.expect(t, untouchedAdam.step == 99 && untouchedFirst == [6]f32{17, 17, 17, 17, 17, 17})
	testing.expect(t, untouchedSecond == [6]f32{19, 19, 19, 19, 19, 19})

	sgdCheckpoint, sgdPolicyScratch, sgdValueScratch: [1024]u8
	sgdSize, sgdSaved := PPOCheckpointWrite(
		&policyB, &valueB, SequentialSGD{0.025}, stateB, ppoConfig, fitConfig,
		sgdCheckpoint[:], sgdPolicyScratch[:], sgdValueScratch[:],
	)
	sgdPolicy, sgdValue: Sequential(1, 2, 2)
	_, _, _, sgdOptimizer, sgdLoaded := PPOCheckpointRead(
		&sgdPolicy, &sgdValue, sgdCheckpoint[:sgdSize], nil, nil, nil, nil,
	)
	sgdRate: f32
	if sgd, isSGD := sgdOptimizer.(SequentialSGD); isSGD { sgdRate = sgd.learningRate }
	testing.expect(t, sgdSaved && sgdLoaded && sgdRate == 0.025)
}
