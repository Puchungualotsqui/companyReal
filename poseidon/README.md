# Poseidon

Poseidon is a caller-owned-storage ML/RL toolkit for the game repository. It provides tensors and layers, supervised training utilities, masked categorical policies, single- and multi-environment rollouts, fixed-window observation histories, return/advantage calculations, PPO actor-critic updates, evaluation primitives, running normalization, and resumable checkpoints.

Poseidon deliberately does **not** depend on game, controller, multiplayer, or rendering types. The game adapter owns the environment loop and translates between game state and observations, legal-action masks, rewards, termination/truncation flags, and policy actions. A controller can call the same policy API in single-player, evaluation, or multiplayer code.

## Current RL scope and limitations

- Discrete categorical actions with per-row legal-action masks are the supported policy distribution. Continuous, parameterized, and multiple-head policies are not implemented; a game adapter can enumerate legal command candidates and map the chosen index to a command and its parameters.
- `RolloutBuffer` represents one stream. `BatchedRolloutBuffer` supports caller-driven interleaving from independent environments, but does not step environments or add parallel execution.
- PPO uses feed-forward `Sequential` actor and critic models, one shared optimizer, caller-owned minibatch scratch, and precomputed returns/advantages.
- Learned recurrent policies, backpropagation through time, and automatic environment stepping are not implemented. `rl.ObservationHistory` provides a fixed-window frame stack for feed-forward policies.
- Checkpoints capture learner state at successful PPO fit boundaries. They do not serialize a pending rollout, game environment state, or observation-history state.

## Build, tests, and examples

Run package tests from the `poseidon/` directory:

```sh
odin test core
odin test data
odin test nn
odin test rl
```

Runnable examples include:

```sh
odin run example/compiled_regression.odin -file
odin run example/ppo_navigation.odin -file
odin run example/ppo_batched_navigation.odin -file
odin run example/partial_observation_history.odin -file
odin run example/policy_gradient.odin -file
odin run example/running_normalization.odin -file
```

`ppo_navigation.odin` is a seeded single-stream task that collects a rollout, computes GAE, trains minibatch PPO, and prints greedy evaluation results. `ppo_batched_navigation.odin` demonstrates independent caller-stepped environments, grouped GAE, batched policy inference, PPO fitting, and separate timings for rollout collection, inference, and GAE/training. `partial_observation_history.odin` demonstrates zero-padded frame stacking and episode reset semantics. The policy-gradient example is a smaller one-step bandit. `running_normalization.odin` demonstrates updating and freezing observation/reward statistics and transforming evaluation inputs. The profile numbers are illustrative for that small example, not a performance baseline.

## Model capacities and lifetime

`Sequential(maxLayers, maxWidth, batchCapacity)` owns its tensor, layer, parameter, and forward/backward scratch inline:

- `maxLayers` is the number of layer slots, including activations, dropout, flattening, and other non-trainable layers.
- `maxWidth` bounds the per-sample input and intermediate feature width. For spatial models it also bounds the framework's documented intermediate storage.
- `batchCapacity` is the maximum number of rows a model can process in one forward or training call.

Initialize models **in their final location** with `SequentialInit` or `SequentialInitSpatial`. Initialized and restored models contain self-references into their own storage; do not copy or move them. Keep caller-owned optimizer state, checkpoint buffers, rollout arrays, normalization arrays, and PPO scratch alive and unmoved for as long as their owning objects refer to them.

Models, optimizer state, inputs, outputs, scratch, and statistics must satisfy each API's non-overlap rules. Checkpoint and training APIs reject many common overlaps, but callers must still obey documented lifetimes and avoid concurrent mutation.

## Supervised compile / fit / evaluate / predict

`example/compiled_regression.odin` shows a complete workflow: initialize a `Sequential` model in place, add layers, inspect it with `SequentialSummary`, initialize an Adam workspace, bind a loss and optimizer with `SequentialCompile`, and fit, evaluate, and predict. The compiled handle is non-owning: the model and Adam storage (if used) must outlive it. Compilation binds configuration; data and optimizer compatibility are checked when operations run.

Use `SequentialAddSpec` or `SequentialAddSpecs` to add value-only layer specifications for dense, activation, convolution, pooling, flatten, or dropout layers. Initialize the model first. `SequentialAddSpecs` reports the zero-based index of a failed addition; successful earlier layers and their RNG advances remain. Specs pass fields as-is: explicitly provide convolution/pooling stride and dropout rate. The individual `SequentialAdd*` functions remain available.

For Adam, `SequentialAdamRequirements` reports the number of parameter pointers and the number of elements needed in **each** moment array. `SequentialAdamWorkspace(parameterCapacity, elementCapacity)` groups that caller-owned storage with an optimizer; initialize it at its final address with `SequentialAdamWorkspaceInit`, then use `SequentialAdamWorkspaceOptimizer` to obtain its `^Adam`. Alternatively, `SequentialAdamInit` borrows individual caller-supplied arrays. Both initializers reset the optimizer step and moments. Keep the model and optimizer storage alive and unmoved; rebind after architecture changes or model reinitialization. `CheckpointRead` with an Adam destination already restores the optimizer binding and moments: do not initialize it again if you want to preserve that state. Recompile the handle after changing or restoring the model.

`SequentialSummary` writes one `SequentialLayerSummary` per layer to caller-provided storage, returning input/output shapes and parameter counts. Shapes omit the batch dimension; spatial shapes are HWC. The returned layer slice borrows that storage. Counts are per parameter node and do not deduplicate manually shared buffers.

`CompiledSequentialFitWithOptions` groups settings in `SequentialFitOptions`. Start with `SequentialFitOptionsDefault()` (200 epochs, shuffle enabled, batch size set by model capacity), then override the fields you need. An explicitly zero-valued options struct means **zero epochs** and evaluates without training. This allocation-free fit uses caller-owned indices, shuffle state, and optional history/validation/snapshot storage. It supports minibatches, validation, L2, early stopping, and SGD or Adam through the existing `SequentialFitBatches` implementation. A late training failure can leave partial updates.

For a simpler fit, `CompiledSequentialFitAuto` allocates and frees its own temporary index buffer using the supplied allocator (or `context.allocator`). Model, optimizer, data, and optional history/validation/snapshot storage remain caller-owned. Pass a shuffle-state pointer to continue the RNG stream across calls; with `nil`, each call starts a local deterministic shuffle stream. Allocators must support individual frees.

`CompiledSequentialEvaluate` reports data loss, not the L2 penalty. `CompiledSequentialEvaluateMetrics` returns loss plus one selected metric; `CompiledSequentialEvaluateMany` writes multiple metrics into caller-owned output in selector order, using one inference pass per minibatch. Supported metrics are MAE, MSE, RMSE, binary-logits accuracy, and categorical-logits accuracy. RMSE is the square root of dataset-wide MSE, not the mean of per-batch RMSEs. The list must be nonempty and contain distinct metrics. Binary accuracy requires 0/1 targets; categorical accuracy requires distribution targets. Logits accuracy requires raw logits, not a final sigmoid/softmax. Dataset aggregates include partial final batches.

To record metrics during fitting, use either `options.metrics` with a `SequentialFitMetricTracking` for one metric or `options.metricsMany` with a `SequentialFitMetricsTracking` for several, but not both. For `M` selected metrics and `E` epochs, the multi-metric history needs at least `E*M` `SupervisedEpochMetric` entries: `history[epoch*M+metricIndex]` corresponds to the supplied selector at `metricIndex`. Epoch indices here are zero-based; the entry's `epoch` field is one-based. Each completed epoch reports post-update, inference-mode training and optional validation metrics; evaluation is validated once before training. With early stopping and best-checkpoint restore, history describes the actual run, not just the restored epoch. Zero epochs writes no metric-history entries. Tracking adds full-dataset inference passes, and its storage/metadata must not overlap other inputs, model/optimizer storage, or fit scratch. `CompiledSequentialPredict` writes into caller-owned output.

Except for `CompiledSequentialFitAuto`'s temporary index buffer, these helpers do not allocate. They do not split data or serialize the compiled configuration. Adam setup uses stack scratch proportional to the layer capacity; see the API comments for storage, aliasing, and mutation contracts. The underlying `Sequential` APIs remain available for finer control.

## CPU SIMD

`core.MatMul`, used by dense forward passes, processes groups of columns with four-lane SIMD on supported build targets and uses a scalar path for remaining columns or targets without hardware SIMD. Selection is compile-time, not runtime dispatch; build for the CPUs on which the binary will run. To force the scalar matrix-multiplication path for testing, pass `-define:POSEIDON_MATMUL_SCALAR=true`. Output must not overlap either input.

A warm-cache microbenchmark compares the current kernel with the earlier implementation; it is not an end-to-end training benchmark:

```sh
odin test core -o:speed -define:POSEIDON_MATMUL_BENCH=true -define:ODIN_TEST_NAMES=core.MatMulBenchmark -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_FANCY=false
```

## PPO workflow

The framework supplies the policy/value updates; the adapter supplies the environment interaction:

1. Build actor and critic `Sequential` models. The actor outputs one logit per discrete action; the critic outputs one scalar value.
2. For each transition, encode an observation and legal-action mask, choose an action, and record the old log probability, value, reward, next value, and termination/truncation flags in `rl.RolloutBuffer` or `rl.BatchedRolloutBuffer`.
3. Call the single-stream or batched `ComputeGAE` / `ComputeDiscountedReturns` variant that matches the buffer. Then optionally apply `rl.RolloutNormalizeAdvantages` to the rollout's training view.
4. Run `SequentialPPOFit` or `SequentialPPOFitStateful` with caller-owned `PPOFitStorage`. Fit scratch must hold at least the effective minibatch size times the observation/action widths; `indices` must cover the rollout and `epochMetrics` must cover the requested epochs.
5. Update/reset the adapter environment as needed and collect the next rollout.

`PPOFitConfig.batchSize == 0` chooses the smaller actor/critic batch capacity. Each minibatch update applies the combined actor and critic gradients through one optimizer. Optional gradient clipping uses their joint global norm. The optional linear learning-rate schedule is scoped to one `SequentialPPOFit` call. The fit API does not allocate and does not compute GAE for you.

For stateful training, initialize a `PPOTrainingState` with a nonzero policy-sampling seed and an explicit shuffle seed. Use `SequentialPolicyAction` or `SequentialPolicyActions` with `&state.policyRandomState`, call `PPOTrainingStateRecordRollout` after a complete rollout and return calculation, and use `SequentialPPOFitStateful` to track successful minibatch updates and shuffle RNG progression.

## Multiple environments

`BatchedRolloutBuffer` stores a flat set of transitions plus an environment ID per row. Its capacity is the total transition count across environments. Append every transition in chronological order within each environment without gaps; rows from different environments can be interleaved. Use `BatchedRolloutComputeGAE` or `BatchedRolloutComputeDiscountedReturns` with caller-owned `BatchedRolloutReturnScratch` to keep returns and GAE independent across streams and episode boundaries. Keep environment-ID storage disjoint from model and PPO-fit scratch storage.

The adapter owns stepping, reset logic, observations, masks, and rewards. It can use `SequentialPolicyActions` to run one policy inference over a batch of observations, then append one transition per active environment. Set actor/critic `batchCapacity` high enough for the inference batch as well as the PPO fit minibatch. After return/advantage calculation, `BatchedRolloutBufferTrainingView` provides the flat sample view accepted by the existing PPO fit API. Do not use the single-stream `RolloutComputeGAE` on interleaved rows. The framework remains synchronous and caller-driven; this interface does not create threads or parallel environments.

## Partial observations and history lifecycle

`rl.ObservationHistory` is a fixed-size, caller-owned ring buffer for recent observations. Push each raw observation exactly once before selecting its action; `ObservationHistoryFlatten` emits rows oldest-to-newest and left-pads an unfilled window with zeros. Use one history per environment. Call `ObservationHistoryReset` before the first observation of each new episode so information cannot leak between episodes.

This is frame stacking for feed-forward policies, not learned recurrence: it does not maintain gradients through time or support backpropagation through time. Histories are adapter/environment state and are not included in PPO learner checkpoints. To resume mid-episode, persist the ring contents and cursor along with the environment; otherwise resume from an episode boundary and reset the history.

## Normalization lifecycle

`data.RunningStandardizer` tracks per-feature means and population M2 values with Welford's online algorithm. It works for row-major observations and for scalar rewards (feature width one). All mean/M2 backing arrays are caller-owned.

- Initialize with `RunningStandardizerInit`.
- Feed batches with `RunningStandardizerUpdate` while unfrozen.
- Call `RunningStandardizerFreeze` when statistics should stop changing; updates then reject until `RunningStandardizerUnfreeze` is called.
- Apply `(x - mean) / sqrt(populationVariance + epsilon)` with `RunningStandardizerTransform`.

The adapter chooses when to update and freeze. For evaluation, use frozen training statistics; do not update them from evaluation episodes. Transform input into a separate caller-owned buffer or in-place. Partial input/output overlap is unsupported. A reward normalizer is not applied automatically by PPO: the adapter must choose how normalized rewards interact with return/advantage computation.

Use `PPOCheckpointWriteNormalized` / `PPOCheckpointReadNormalized` to include optional observation and reward normalizers in resumable training checkpoints. Use `PPOPolicyExportWrite` / `PPOPolicyExportRead` for an inference-only policy plus its optional observation normalizer. The inference export intentionally omits the critic, optimizer, learner counters, rollout state, and RNG; stochastic action selection still receives an explicit caller-owned RNG.

## Evaluation

`SequentialPolicyAction` and `SequentialPolicyActions` select legal actions greedily or sample stochastically from an explicit nonzero RNG state; the batch form performs one model forward pass for multiple observations. They run inference and leave parameters, gradients, and optimizer state unchanged, but use the model's regular activation buffers; do not evaluate concurrently with training on the same model.

`rl.EvaluationAccumulator` aggregates complete episodes without allocating. The caller supplies episode return, length, its definition of success, and optional custom scalar metrics. Keep evaluation RNG separate from the `PPOTrainingState` RNG streams for repeatability.

## Ownership and mutation quick reference

| API family | Allocates? | Main mutation |
|---|---:|---|
| `core` tensor operations | No for serial operations; parallel helpers create workers | Caller-provided output, gradient, and graph storage |
| `SequentialAddSpecs` / `SequentialSummary` | No | Model architecture and initialization RNG / caller-provided summary storage |
| `SequentialAdamInit` / `SequentialAdamWorkspaceInit` | No | Adam parameter/moment storage; initialization resets optimizer state |
| Compiled fit / evaluate / predict | No, except `CompiledSequentialFitAuto` allocates temporary indices | Fit mutates model/optimizer and supplied scratch; evaluation/prediction use model scratch, and prediction writes output |
| `SequentialPredict` / `SequentialPolicyAction(s)` | No | Model input/output activation scratch; stochastic action selection also advances the supplied RNG |
| Rollout, return, and observation-history utilities | No | Caller-owned rollout arrays, environment IDs, history storage, and supplied per-environment scratch |
| `SequentialPPOFit` | No | Model parameters/gradients, optimizer, supplied shuffle RNG, PPO scratch, epoch metrics |
| `RunningStandardizerUpdate` / `Transform` | No | Moment arrays or caller-provided transform output |
| `PPOCheckpointWrite` / `PPOCheckpointWriteNormalized` | No | Checkpoint/scratch byte buffers; model and optimizer are read-only |
| `PPOCheckpointRead` / normalized read | No | Destination models and optimizer storage on success; normalized read also restores supplied normalizer arrays |
| Evaluation accumulator | No | Caller-owned accumulator and custom-mean storage |

File I/O helpers may use operating-system file handles and temporary files. Except for the explicitly allocating fit helper, in-memory tensor, rollout, training, normalization, evaluation, and byte-checkpoint procedures use caller-supplied storage.
