# Poseidon

Poseidon is a caller-owned-storage ML/RL toolkit for the game repository. It provides tensors and layers, supervised training utilities, categorical policies, one-stream rollouts, return/advantage calculations, PPO actor-critic updates, evaluation primitives, running normalization, and resumable checkpoints.

Poseidon deliberately does **not** depend on game, controller, multiplayer, or rendering types. The game adapter owns the environment loop and translates between game state and observations, legal-action masks, rewards, termination/truncation flags, and policy actions. A controller can call the same policy API in single-player, evaluation, or multiplayer code.

## Current RL scope and limitations

- Discrete categorical actions with per-row legal-action masks; continuous and parameterized policies are not implemented.
- A bounded rollout represents one ordered environment stream. Multi-environment interleaving is deferred.
- PPO uses feed-forward `Sequential` actor and critic models, one shared optimizer, caller-owned minibatch scratch, and precomputed returns/advantages.
- Recurrent/stateful policies and automatic environment stepping are outside the current API.
- Checkpoints capture learner state at successful PPO fit boundaries. They do not serialize a pending rollout or game environment state.

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
odin run example/ppo_navigation.odin -file
odin run example/policy_gradient.odin -file
odin run example/running_normalization.odin -file
```

`ppo_navigation.odin` is a seeded multi-step navigation task. It collects a rollout in game-adapter style, computes GAE, trains minibatch PPO, and prints greedy evaluation results. The policy-gradient example is a smaller one-step bandit. `running_normalization.odin` demonstrates updating and freezing observation/reward statistics and transforming evaluation inputs.

## Model capacities and lifetime

`Sequential(maxLayers, maxWidth, batchCapacity)` owns its tensor, layer, parameter, and forward/backward scratch inline:

- `maxLayers` is the number of layer slots, including activations, dropout, flattening, and other non-trainable layers.
- `maxWidth` bounds the per-sample input and intermediate feature width. For spatial models it also bounds the framework's documented intermediate storage.
- `batchCapacity` is the maximum number of rows a model can process in one forward or training call.

Initialize models **in their final location** with `SequentialInit` or `SequentialInitSpatial`. Initialized and restored models contain self-references into their own storage; do not copy or move them. Keep caller-owned optimizer state, checkpoint buffers, rollout arrays, normalization arrays, and PPO scratch alive and unmoved for as long as their owning objects refer to them.

Models, optimizer state, inputs, outputs, scratch, and statistics must satisfy each API's non-overlap rules. Checkpoint and training APIs reject many common overlaps, but callers must still obey documented lifetimes and avoid concurrent mutation.

## PPO workflow

The framework supplies the policy/value updates; the adapter supplies the environment interaction:

1. Build actor and critic `Sequential` models. The actor outputs one logit per discrete action; the critic outputs one scalar value.
2. For each transition, encode an observation and legal-action mask, choose an action, and record the old log probability, value, reward, next value, and termination/truncation flags in `rl.RolloutBuffer`.
3. Call `rl.RolloutComputeGAE` or `rl.RolloutComputeDiscountedReturns`, then optionally `rl.RolloutNormalizeAdvantages`.
4. Run `SequentialPPOFit` or `SequentialPPOFitStateful` with caller-owned `PPOFitStorage`. Fit scratch must hold at least the effective minibatch size times the observation/action widths; `indices` must cover the rollout and `epochMetrics` must cover the requested epochs.
5. Update/reset the adapter environment as needed and collect the next rollout.

`PPOFitConfig.batchSize == 0` chooses the smaller actor/critic batch capacity. Each minibatch update applies the combined actor and critic gradients through one optimizer. Optional gradient clipping uses their joint global norm. The optional linear learning-rate schedule is scoped to one `SequentialPPOFit` call. The fit API does not allocate and does not compute GAE for you.

For stateful training, initialize a `PPOTrainingState` with a nonzero policy-sampling seed and an explicit shuffle seed. Use `SequentialPolicyAction` with `&state.policyRandomState`, call `PPOTrainingStateRecordRollout` after a complete rollout and return calculation, and use `SequentialPPOFitStateful` to track successful minibatch updates and shuffle RNG progression.

## Normalization lifecycle

`data.RunningStandardizer` tracks per-feature means and population M2 values with Welford's online algorithm. It works for row-major observations and for scalar rewards (feature width one). All mean/M2 backing arrays are caller-owned.

- Initialize with `RunningStandardizerInit`.
- Feed batches with `RunningStandardizerUpdate` while unfrozen.
- Call `RunningStandardizerFreeze` when statistics should stop changing; updates then reject until `RunningStandardizerUnfreeze` is called.
- Apply `(x - mean) / sqrt(populationVariance + epsilon)` with `RunningStandardizerTransform`.

The adapter chooses when to update and freeze. For evaluation, use frozen training statistics; do not update them from evaluation episodes. Transform input into a separate caller-owned buffer or in-place. Partial input/output overlap is unsupported. A reward normalizer is not applied automatically by PPO: the adapter must choose how normalized rewards interact with return/advantage computation.

Use `PPOCheckpointWriteNormalized` / `PPOCheckpointReadNormalized` to include optional observation and reward normalizers in resumable training checkpoints. Use `PPOPolicyExportWrite` / `PPOPolicyExportRead` for an inference-only policy plus its optional observation normalizer. The inference export intentionally omits the critic, optimizer, learner counters, rollout state, and RNG; stochastic action selection still receives an explicit caller-owned RNG.

## Evaluation

`SequentialPolicyAction` selects a legal action greedily or samples stochastically from an explicit nonzero RNG state. It runs inference and leaves parameters, gradients, and optimizer state unchanged, but uses the model's regular activation buffers; do not evaluate concurrently with training on the same model.

`rl.EvaluationAccumulator` aggregates complete episodes without allocating. The caller supplies episode return, length, its definition of success, and optional custom scalar metrics. Keep evaluation RNG separate from the `PPOTrainingState` RNG streams for repeatability.

## Ownership and mutation quick reference

| API family | Allocates? | Main mutation |
|---|---:|---|
| `core` tensor/layer operations | No | Caller-provided output, gradient, and graph storage |
| `SequentialPredict` / `SequentialPolicyAction` | No | Model input/output activation scratch; stochastic action selection also advances the supplied RNG |
| Rollout and return utilities | No | Caller-owned rollout arrays |
| `SequentialPPOFit` | No | Model parameters/gradients, optimizer, supplied shuffle RNG, PPO scratch, epoch metrics |
| `RunningStandardizerUpdate` / `Transform` | No | Moment arrays or caller-provided transform output |
| `PPOCheckpointWrite` / `PPOCheckpointWriteNormalized` | No | Checkpoint/scratch byte buffers; model and optimizer are read-only |
| `PPOCheckpointRead` / normalized read | No | Destination models and optimizer storage on success; normalized read also restores supplied normalizer arrays |
| Evaluation accumulator | No | Caller-owned accumulator and custom-mean storage |

File I/O helpers may use operating-system file handles and temporary files; the in-memory tensor, rollout, training, normalization, evaluation, and byte-checkpoint procedures use caller-supplied storage.
