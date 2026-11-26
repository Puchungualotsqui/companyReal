# Poseidon roadmap

This roadmap focuses first on making Poseidon usable for training and evaluating RL policies. The game-specific environment and action/observation mapping should remain outside Poseidon; the framework should provide reusable tensor, policy, rollout, and learner utilities.

## Current capabilities

- Caller-owned tensors, basic autograd graphs, and tensor operations in `core/`.
- Dense and Conv2D layers, pooling, flattening, common activations, and dropout.
- Full-batch and minibatch supervised training, SGD/Adam, common regression/classification losses, validation metrics, early stopping, and checkpoint save/load.
- Data standardization and seeded dataset splitting/gathering.
- Discrete categorical policy probabilities, sampling, log probabilities, entropy, legal-action masks, and policy-gradient/PPO updates.
- Bounded single-stream and caller-driven interleaved multi-environment rollout storage, per-environment discounted returns/GAE, advantage normalization, and reward scaling.
- Caller-owned fixed-window observation histories for feed-forward frame stacking, with explicit zero-padding and episode-reset semantics.
- PPO minibatch epochs with deterministic shuffling, joint actor-critic global gradient clipping, an optional linear learning-rate schedule, and epoch/fit diagnostics.
- One-step bandit, single-environment PPO navigation, and multi-environment PPO profiling examples.
- Resumable paired actor-critic PPO checkpoints at successful-fit boundaries, including shared optimizer state, configs, learner counters, and separate policy/shuffle RNG streams.
- Caller-driven greedy/stochastic single and batched policy actions, plus allocation-free episode evaluation aggregation with return variability, lengths, success rates, and custom metric means.
- Welford running standardizers with explicit update/freeze/unfreeze lifecycle for observations or rewards, included in normalized PPO checkpoints and observation-normalized inference exports.
- A Poseidon overview in `README.md` documenting scope, ownership, capacities, mutation/allocation, adapter boundaries, validation commands, and examples.

## Priority 1 — RL training foundations

1. **Trajectory and rollout storage — implemented for one ordered environment stream**
   - Caller-owned, bounded storage for observations, actions, rewards, values, old log probabilities, legal-action masks, and episode-boundary flags.
   - Full-buffer rejection, reset, and support for incomplete episodes at rollout boundaries through per-transition next-value estimates.
   - Distinguishes true termination from truncation. The multi-environment extension is tracked in Priority 3 and uses a separate batched buffer/view.

2. **Return and advantage calculations — implemented**
   - Discounted returns with a configurable discount factor and correct terminal/truncation bootstrapping.
   - Generalized Advantage Estimation (GAE), including bootstrapping at rollout boundaries and stopping recursion across episode boundaries.
   - Population-standardized advantages and explicit nonnegative reward scaling utilities.

3. **Actor-critic and PPO objectives — implemented for full-batch updates**
   - Huber value loss alongside the existing categorical policy-gradient loss.
   - PPO clipped policy objective, entropy bonus, and legal-action masking.
   - A joint policy/value update using one optimizer, with component losses, entropy, approximate KL, and clip fraction.
   - Keep the existing simple policy-gradient API as a useful low-level primitive. Minibatch epochs remain in item 4.

4. **RL minibatch update loop — implemented**
   - Deterministically shuffle rollout indices using caller-owned RNG state and train over configurable minibatches and epochs.
   - Apply global gradient-norm clipping to the combined actor/critic gradients before their shared optimizer update.
   - Optionally linearly anneal the learning rate; report losses, entropy, approximate KL, clip fraction, explained variance, gradient norms, clipping counts, and update counts.

5. **RL-specific tests and examples — implemented for the current discrete PPO scope**
   - Cover return/GAE calculations, terminal versus truncated episodes, masks, PPO clipping, numerical edges, deterministic minibatch shuffling, schedule behavior, diagnostics, and gradient clipping.
   - Check differentiable PPO policy gradients numerically.
   - Provide a seeded multi-step navigation example that collects rollouts, trains PPO, and prints greedy evaluation progress alongside the bandit example.

## Priority 2 — Reproducible training and evaluation

1. **Complete RL checkpoint state — implemented for discrete PPO at fit boundaries**
   - Serialize policy and value models, shared Adam or SGD state, PPO/fit configs, cumulative update and rollout counters, and separate action-sampling/minibatch-shuffle RNG streams.
   - Checkpoint only after a successful fit. Rollout and game-environment state are not serialized; the game adapter must save its environment state or reset it after resume.
   - Optional observation/reward running moments are saved by the normalized checkpoint API. Inference-only policy export remains separate from resumable learner checkpoints.

2. **Evaluation utilities — implemented as caller-driven primitives**
   - Select greedy or explicitly seeded stochastic actions in inference mode without changing parameters, gradients, or optimizer state.
   - Aggregate episode return and population variability, length, caller-defined success rate, and caller-defined custom metric means without allocation.
   - Evaluation RNG is supplied independently, so callers can keep it separate from training RNG state.

3. **Policy and observation normalization — implemented**
   - `data.RunningStandardizer` provides caller-owned Welford moments with explicit update, freeze, and unfreeze operations; it can normalize observations or scalar rewards.
   - Normalized PPO checkpoints preserve observation and reward statistics. Inference-only policy exports can include observation statistics without optimizer or learner state.

4. **API and usage documentation — implemented**
   - `README.md` documents supported features, limitations, package tests, and end-to-end examples.
   - Documents model capacities and in-place initialization/copy restrictions, caller-owned storage/lifetimes, mutation/allocation expectations, and the adapter's responsibility for environment observations/actions/rewards/boundaries.

## Priority 3 — Scale and broader model support

1. **Batched environment integration points — implemented (synchronous and caller-driven)**
   - `BatchedRolloutBuffer` stores interleaved transitions with environment IDs; batched return/GAE routines keep each independent stream and episode boundary separate.
   - `SequentialPolicyActions` batches inference/action selection, and `ppo_batched_navigation.odin` profiles collection, inference, and GAE/PPO training separately. Poseidon does not step environments or add parallel execution.

2. **Policy distribution coverage — initial scope decision recorded**
   - Keep the masked categorical distribution as the only supported policy for the first game experiment. The game adapter can enumerate legal command candidates, mask unavailable candidates, and map a selected index to a command and its parameters.
   - Defer continuous, parameterized, and multiple-head policies until the adapter demonstrates that candidate enumeration or categorical precision is a real limitation. This avoids adding unused distribution/training APIs or allowing invalid combinations between independent heads. Existing categorical tests cover sampling, log probabilities, entropy, and policy/PPO gradients.

3. **Partial-observation support — fixed-window baseline implemented; recurrent training deferred**
   - `rl.ObservationHistory` provides caller-owned, zero-padded frame stacking for feed-forward policies. Reset it at episode boundaries and keep a separate history per environment.
   - Observation histories are adapter/environment state, not part of PPO learner checkpoints. Mid-episode resume requires the adapter to persist history contents and cursor with its environment; otherwise reset at an episode boundary.
   - Fog of War motivates an initial partial-observation experiment. Compare feed-forward policies over several history depths first; add recurrent layers and backpropagation through time only if a finite history window demonstrably fails.

4. **General DL expansion (not required for the first RL milestone)**
   - Broaden differentiable tensor operations and model composition as real use cases require them.
   - Consider additional optimizers, regularizers, and layer families based on demonstrated needs.
   - Consider GPU or other compute backends only after profiling shows CPU execution is a bottleneck and the maintenance cost is justified.

## Suggested completion target

Poseidon is ready for the game's first serious RL experiment when a standalone example can collect multi-step rollouts, compute returns/GAE, train a masked discrete actor-critic with PPO minibatches, save/resume deterministically at update boundaries, and report reproducible evaluation metrics—without importing game-specific code.
