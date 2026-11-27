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

On Linux, also run the suite with a limited stack to exercise the large-model
constructor and checkpoint regressions (their large models are heap-owned):

```sh
(ulimit -c 0; ulimit -s 8192; odin test nn -o:none -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_FANCY=false)
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

Initialize models **in their final location** with `SequentialInit` or `SequentialInitSpatial`. Alternatively, `OwnedSequentialInit` / `OwnedSequentialInitSpatial` allocate and initialize the model using an allocator; `OwnedSequentialModel` borrows it. Capacities are still compile-time parameters, and allocating the model does not remove stack scratch used by some layer, fit, and checkpoint operations. Initialized and restored models contain self-references into their own storage; do not copy or move them. Keep caller-owned optimizer state, checkpoint buffers, rollout arrays, normalization arrays, and PPO scratch alive and unmoved for as long as their owning objects refer to them.

Models, optimizer state, inputs, outputs, scratch, and statistics must satisfy each API's non-overlap rules. Checkpoint and training APIs reject many common overlaps, but callers must still obey documented lifetimes and avoid concurrent mutation.

## Supervised compile / fit / evaluate / predict

`example/compiled_regression.odin` shows a complete workflow: allocate a model with `OwnedSequentialInit`, add layers, inspect it with `SequentialDetails`, allocate Adam storage with `SequentialOwnedAdamInit`, bind a loss and optimizer with `SequentialCompile`, and fit, evaluate, and predict. The compiled handle is non-owning: the model and Adam storage (if used) must outlive it. Compilation binds configuration; data and optimizer compatibility are checked when operations run.

Use `SequentialAddSpec` or `SequentialAddSpecs` to add value-only layer specifications for dense, activation, convolution, pooling, flatten, or dropout layers. Initialize the model first. `SequentialAddSpecs` reports the zero-based index of a failed addition; successful earlier layers and their RNG advances remain. Specs pass fields as-is: explicitly provide convolution/pooling stride and dropout rate. The individual `SequentialAdd*` functions remain available.

For automatic Adam storage, initialize a zero-valued `SequentialOwnedAdam` with `SequentialOwnedAdamInit` after building the model, and borrow the `^Adam` via `SequentialOwnedAdamOptimizer`. The owner allocates parameter pointers and moment buffers sized to the model. For allocation-free use, `SequentialAdamRequirements` reports the number of parameter pointers and the number of elements needed in **each** moment array; `SequentialAdamWorkspace` or `SequentialAdamInit` can bind caller-owned storage. These initializers reset the optimizer step and moments.

Both owners capture their allocator, which must remain valid and support individual frees. Initialize owner handles at their final address and do not copy or move them while live. Stop using compiled handles and other borrows before destruction; destroy the Adam owner **before** the model owner. If an Adam free fails, its borrows are invalidated and `SequentialOwnedAdamDestroy` can be retried for the remaining allocations (provided failed frees leave storage intact). Address checks detect ordinary copies but cannot revoke an already borrowed pointer or prevent use-after-free. After external model reinitialization or architecture changes, discard compiled bindings and reinitialize/rebind Adam as appropriate: recreating a model at the same address may leave stale moments looking valid. For checkpoint restore, initialize an Adam owner with sufficient capacity, pass the slices from `SequentialOwnedAdamStorage` to `CheckpointRead`, and recompile afterward. Do not initialize Adam again after restore: that resets its moments and step. A supervised checkpoint containing Adam requires optimizer storage even when loading for inference; write a separate model-only checkpoint with `CheckpointWrite` and a nil Adam if optimizer state is not needed. `CheckpointInspect` can report an unfamiliar supervised checkpoint's encoded capacities and structural Adam storage requirements before loading, but initializing an owned Adam still requires a built model; there is no allocation-from-checkpoint shortcut.

`CheckpointInspect(bytes, limits)` validates a complete supervised checkpoint without allocating or building a model. It returns a `CheckpointInfo` and a `CheckpointError`: check `error.code == .None`, otherwise `error.offset` identifies the relevant byte. The info includes encoded model capacities, input/output widths and rank, Adam presence, parameter-pointer count, and `f32` elements required in **each** Adam moment array. These counts are structural even when Adam is absent. `CheckpointInspectLimits` can bound file bytes, capacities, pointer count, and moment elements; zero fields impose no limit, so set appropriate limits for untrusted input. Inspection does not authenticate bytes or guarantee a matching compiled model type, allocation, or successful restore; keep bytes unchanged until `CheckpointRead` revalidates them. Use `PPOCheckpointInspect` or `PPOCheckpointInspectNormalized` for the outer PPO formats.

`SequentialSummary` writes one `SequentialLayerSummary` per layer to caller-provided storage, returning input/output shapes and parameter counts. `SequentialDetails` additionally reports retained convolution/pooling/dropout configuration, model inline storage bytes, parameter-node count, and the `f32` element count for each Adam moment buffer. Shapes omit the batch dimension; spatial shapes are HWC. Returned layer slices borrow the supplied storage. Counts are structural and do not deduplicate manually shared buffers; use `SequentialAdamRequirements` for its stricter optimizer-wiring validation.

`CompiledSequentialFitWithOptions` groups settings in `SequentialFitOptions`. Start with `SequentialFitOptionsDefault()` (200 epochs, shuffle enabled, batch size set by model capacity), then override the fields you need. An explicitly zero-valued options struct means **zero epochs** and evaluates without training. This allocation-free fit uses caller-owned indices, shuffle state, and optional history/validation/snapshot storage. It supports minibatches, validation, L2, early stopping, and SGD or Adam through the existing `SequentialFitBatches` implementation. A late training failure can leave partial updates. When a best snapshot is restored, the model is reconstructed using its inline parameter buffers: externally rebound parameter data/gradients are no longer used, and prior model-internal borrows must be reacquired. Adam's supplied parameter pointers are rebound. To use external buffers again, copy the restored parameter values before rebinding.

For a simpler fit, `CompiledSequentialFitAuto` allocates and frees its own temporary index buffer using the supplied allocator (or `context.allocator`). Model, optimizer, data, and optional history/validation/snapshot storage remain caller-owned. Pass a shuffle-state pointer to continue the RNG stream across calls; with `nil`, each call starts a local deterministic shuffle stream. Its allocator must support successful individual frees; arenas that only support bulk reset are not suitable. A reported free failure makes the call return failure even if training already completed and changed model, optimizer, RNG, or history; don't blindly retry. The API cannot return or retry a possibly retained allocation, so a failing free may leak. Use caller-managed indices and `CompiledSequentialFitWithOptions` if cleanup must be controlled by the caller.

`CompiledSequentialEvaluate` reports data loss, not the L2 penalty. `CompiledSequentialEvaluateMetrics` returns loss plus one selected metric; `CompiledSequentialEvaluateMany` writes multiple metrics into caller-owned output in selector order, using one inference pass per minibatch. Supported metrics are MAE, MSE, RMSE, binary-logits accuracy, and categorical-logits accuracy. RMSE is the square root of dataset-wide MSE, not the mean of per-batch RMSEs. The list must be nonempty and contain distinct metrics. Binary accuracy requires 0/1 targets; categorical accuracy requires distribution targets. Logits accuracy requires raw logits, not a final sigmoid/softmax. Dataset aggregates include partial final batches.

To record metrics during fitting, use either `options.metrics` with a `SequentialFitMetricTracking` for one metric or `options.metricsMany` with a `SequentialFitMetricsTracking` for several, but not both. For `M` selected metrics and `E` epochs, the multi-metric history needs at least `E*M` `SupervisedEpochMetric` entries: `history[epoch*M+metricIndex]` corresponds to the supplied selector at `metricIndex`. Epoch indices here are zero-based; the entry's `epoch` field is one-based. Each completed epoch reports post-update, inference-mode training and optional validation metrics; evaluation is validated once before training. With early stopping and best-checkpoint restore, history describes the actual run, not just the restored epoch. Zero epochs writes no metric-history entries. Tracking adds full-dataset inference passes, and its storage/metadata must not overlap other inputs, model/optimizer storage, or fit scratch.

For inference, `SequentialPredict` returns a **borrowed** slice into model scratch; another prediction, fit, or reinitialization invalidates it. Copy the result before the next model operation, or prefer `SequentialPredictBatches` / `CompiledSequentialPredict` to write into caller-owned output. For a single observation and a one-output model, `SequentialPredictScalar` / `CompiledSequentialPredictScalar` return an `f32` by value, so consecutive critic predictions cannot overwrite each other. These alternatives do not allocate, but they still overwrite model scratch and must not run concurrently on the same model. They validate shapes and reject non-finite inputs or outputs.

The owning model/Adam APIs and `CompiledSequentialFitAuto` allocate through the supplied allocator; their lower-level alternatives and summary APIs remain allocation-free. They do not split data or serialize the compiled configuration. Adam setup and detailed summaries use stack scratch proportional to the layer capacity; see the API comments for storage, aliasing, failure, and mutation contracts.

## CPU SIMD

`core.MatMul`, used by dense forward passes, processes groups of columns with four-lane SIMD on supported build targets and uses a scalar path for remaining columns or targets without hardware SIMD. Selection is compile-time, not runtime dispatch; build for the CPUs on which the binary will run. To force the scalar matrix-multiplication path for testing, pass `-define:POSEIDON_MATMUL_SCALAR=true`. Output must not overlap either input.

A warm-cache microbenchmark compares the current kernel with the earlier implementation; it is not an end-to-end training benchmark:

```sh
odin test core -o:speed -define:POSEIDON_MATMUL_BENCH=true -define:ODIN_TEST_NAMES=core.MatMulBenchmark -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_FANCY=false
```

## PPO workflow

The framework supplies the policy/value updates; the adapter supplies the environment interaction:

1. Build actor and critic `Sequential` models. The actor outputs one logit per discrete action; the critic outputs one scalar value.
2. For each transition, encode an observation and legal-action mask, choose an action, and record the old log probability, value, reward, next value, and termination/truncation flags in `rl.RolloutBuffer` or `rl.BatchedRolloutBuffer`. Use `SequentialPredictScalar` for individual critic values, or `SequentialPredictBatches` into separate caller-owned arrays for batched values. Never retain a borrowed `SequentialPredict` result across another prediction on the same critic.
3. Call the single-stream or batched `ComputeGAE` / `ComputeDiscountedReturns` variant that matches the buffer. Then optionally apply `rl.RolloutNormalizeAdvantages` to the rollout's training view.
4. Fit with `PPOTrainingContextFit`, or use `SequentialPPOFit` / `SequentialPPOFitStateful` with caller-owned `PPOFitStorage`. Fit scratch must hold at least the effective minibatch size times the observation/action widths; `indices` must cover the rollout and `epochMetrics` must cover the requested epochs.
5. Update/reset the adapter environment as needed and collect the next rollout.

`PPOFitConfig.batchSize == 0` chooses the smaller actor/critic batch capacity. Each minibatch update applies the combined actor and critic gradients through one optimizer. Optional gradient clipping uses their joint global norm. The optional linear learning-rate schedule is scoped to one `SequentialPPOFit` call. The fit API does not allocate and does not compute GAE for you.

### Owned PPO training context

`example/ppo_navigation.odin` demonstrates the owning path. After building the actor and critic, initialize the context **at its final address**. It allocates a shared policy-then-value Adam optimizer and reusable minibatch/epoch scratch, and owns the learner state; it does **not** own the models or rollout:

```odin
options := nn.PPOTrainingContextOptionsDefault(ROLLOUT_CAPACITY)
options.fit.batchSize = BATCH_SIZE // zero selects the smaller model capacity
options.learningRate = 0.003
options.policySeed, options.shuffleSeed = 12345, 67890
trainer: nn.PPOTrainingContext(3, 8, 8, 3, 8, 8) // actor capacities, then critic capacities
assert(nn.PPOTrainingContextInit(&trainer, &policy, &value, options) == .None)
defer assert(nn.PPOTrainingContextDestroy(&trainer) == .None)
state := nn.PPOTrainingContextState(&trainer) // borrow for policyRandomState
```

Use `&state.policyRandomState` for `SequentialPolicyAction(s)`, collect a rollout, calculate returns/GAE, then call `PPOTrainingContextRecordRollout` and `PPOTrainingContextFit`. `PPOTrainingContextEpochMetrics` borrows the epoch buffer; only the prefix reported by the fit is current. Fit itself allocates nothing. `PPOTrainingContextError` distinguishes setup, rollout, fit, checkpoint, and cleanup failure stages; setup errors do not distinguish every underlying allocation/validation cause. A late `.FitFailed` can leave committed minibatches and advanced RNG state. Do not retry blindly.

Keep both models and their parameter storage alive and unmoved, and destroy the trainer before them. Do not copy/move a live trainer or use its borrows once destruction begins. The captured allocator must support individual frees and remain valid. A `.CleanupFailed` leaves the trainer in a destroying state: retry `PPOTrainingContextDestroy` only if a failed free retains the allocation. An internal rollback in the ordinary `PPOTrainingContextInit` can leak if its free fails; the checkpoint initializer below retains failed rollback allocations for retry. The optional `PPOOwnedAdam` and `PPOOwnedFitStorage` expose the same two ownership pieces separately for lower-level use.

### PPO checkpoint inspection and restore

`PPOCheckpointInspect(bytes, limits)` validates an entire **base** PPO checkpoint without allocating or constructing models. It reports actor/critic capacities, shapes and combined parameter/moment counts, optimizer kind, fit configuration, counters and RNG state. `PPOCheckpointInspectNormalized` additionally reports normalizer presence, width, count, epsilon and frozen state; it validates all saved moments. Both return a zero info value and a `CheckpointError` with an input-relative byte offset on failure. Limits cover input sizes, model capacities, optimizer requirements and epochs; normalized limits also cover observation width. Zero means unlimited, so set limits for untrusted data. Inspection is not authentication and does not guarantee that the application has compiled a matching `Sequential` type or can allocate it. Input must remain valid and unchanged through restore.

For a new trainer, `PPOTrainingContextCheckpointInit` allocates Adam and fit scratch from the inspected requirements and reconstructs two **zero-valued or layerless** model slots in place; no architecture needs to be built first. `example/ppo_navigation.odin` demonstrates saving, inspecting and restoring this way. The model type's compile-time capacities must exactly match those in the checkpoint; dispatch to a supported compiled type after inspection. `rolloutCapacity` is supplied by the caller because rollouts are not checkpointed. Optional `maxOwnedBytes` bounds the requested optimizer/scratch allocation, excluding caller-owned models, rollout, allocator overhead and normalizers. These context APIs support Adam checkpoints; the lower-level reader and inspector also support SGD.

For normalized checkpoints, initialize caller-owned observation/reward normalizers and their arrays using the widths reported by `PPOCheckpointInspectNormalized`, pass nil for absent normalizers, and call `PPOTrainingContextCheckpointInitNormalized`. The initializer restores their moments and metadata along with the models, optimizer, learner state and configs. The context does not own those normalizers. A valid frozen, empty normalizer now round-trips; older Poseidon readers may reject that state.

For an existing ready trainer, `PPOTrainingContextCheckpointRead` / `PPOTrainingContextCheckpointReadNormalized` reuse existing allocations and require compatible model, action/observation, optimizer and scratch capacities. The corresponding `PPOTrainingContextCheckpointWrite` / `PPOTrainingContextCheckpointWriteNormalized` use caller-owned byte/staging buffers. Save only after a successful fit. Restoring reconstructs models and invalidates their prior internal borrows; neither format saves the rollout, environment or observation history. To replace a live trainer with a larger one atomically, initialize a second trainer and separate model slots, then switch the application's pointer rather than moving either trainer.

For the allocation-free path instead, initialize a `PPOTrainingState` with a nonzero policy-sampling seed and an explicit shuffle seed. Use `SequentialPolicyAction` or `SequentialPolicyActions` with `&state.policyRandomState`, call `PPOTrainingStateRecordRollout` after a complete rollout and return calculation, and use `SequentialPPOFitStateful` with caller-provided optimizer and scratch to track committed minibatch updates and shuffle RNG progression.

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
| `SequentialAddSpecs` / `SequentialSummary` / `SequentialDetails` | No | Model architecture and initialization RNG / caller-provided summary storage |
| `OwnedSequentialInit` / `SequentialOwnedAdamInit` | Yes | Allocator-owned model or Adam buffers; destroy the owners explicitly |
| `PPOTrainingContextInit` / `PPOOwnedAdamInit` / `PPOOwnedFitStorageInit` | Yes | Shared optimizer, PPO scratch and/or learner state; destroy the owners explicitly |
| `SequentialAdamInit` / `SequentialAdamWorkspaceInit` | No | Adam parameter/moment storage; initialization resets optimizer state |
| Compiled fit / evaluate / predict | No, except `CompiledSequentialFitAuto` allocates temporary indices | Fit mutates model/optimizer and supplied scratch; evaluation/prediction use model scratch, and prediction writes output |
| `SequentialPredict` / `SequentialPredictScalar` / `SequentialPredictBatches` / `SequentialPolicyAction(s)` | No | Model input/output activation scratch; batch prediction writes caller output; stochastic action selection also advances the supplied RNG |
| Rollout, return, and observation-history utilities | No | Caller-owned rollout arrays, environment IDs, history storage, and supplied per-environment scratch |
| `SequentialPPOFit` | No | Model parameters/gradients, optimizer, supplied shuffle RNG, PPO scratch, epoch metrics |
| `RunningStandardizerUpdate` / `Transform` | No | Moment arrays or caller-provided transform output |
| `PPOCheckpointWrite` / `PPOCheckpointWriteNormalized` | No | Checkpoint/scratch byte buffers; model and optimizer are read-only |
| `PPOCheckpointRead` / normalized read | No | Destination models and optimizer storage on success; normalized read also restores supplied normalizer arrays |
| `CheckpointInspect` / `PPOCheckpointInspect` / `PPOCheckpointInspectNormalized` | No | None; returns checkpoint metadata or a structured byte error |
| `PPOTrainingContextCheckpointInit` / normalized init | Yes | Destination models, owned optimizer/scratch and optional caller-owned normalizers on success |
| Evaluation accumulator | No | Caller-owned accumulator and custom-mean storage |

File I/O helpers may use operating-system file handles and temporary files. Explicitly owning APIs and the automatic fit helper allocate; the lower-level in-memory tensor, rollout, training, normalization, evaluation, and byte-checkpoint procedures use caller-supplied storage.
