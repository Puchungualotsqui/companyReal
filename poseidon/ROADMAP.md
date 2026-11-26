# Poseidon roadmap

This roadmap focuses first on making Poseidon usable for training and evaluating RL policies. The game-specific environment and action/observation mapping should remain outside Poseidon; the framework should provide reusable tensor, policy, rollout, and learner utilities.

## Current capabilities

- Caller-owned tensors, basic autograd graphs, and tensor operations in `core/`.
- Dense and Conv2D layers, pooling, flattening, common activations, and dropout.
- Full-batch and minibatch supervised training, SGD/Adam, common regression/classification losses, validation metrics, early stopping, and checkpoint save/load.
- Data standardization and seeded dataset splitting/gathering.
- Discrete categorical policy probabilities, sampling, log probabilities, entropy, legal-action masks, and policy-gradient/PPO updates.
- Bounded rollout storage for one ordered environment stream, discounted returns, GAE, advantage normalization, and reward scaling.
- PPO minibatch epochs with deterministic shuffling, joint actor-critic global gradient clipping, an optional linear learning-rate schedule, and epoch/fit diagnostics.
- A one-step bandit example and a reproducible multi-step PPO navigation example with rollout collection and greedy evaluation.

## Priority 1 — RL training foundations

1. **Trajectory and rollout storage — implemented for one ordered environment stream**
   - Caller-owned, bounded storage for observations, actions, rewards, values, old log probabilities, legal-action masks, and episode-boundary flags.
   - Full-buffer rejection, reset, and support for incomplete episodes at rollout boundaries through per-transition next-value estimates.
   - Distinguishes true termination from truncation. Multiple interleaved environments are deferred to Priority 3.

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

1. **Complete RL checkpoint state**
   - Preserve learner/update counters, optimizer state, RNG state, schedules, and any observation/reward normalization statistics.
   - Define checkpoint boundaries clearly (for example, after an update) rather than serializing arbitrary in-progress environment state by accident.
   - Keep inference-only policy export separate from resumable training checkpoints if their requirements differ.

2. **Evaluation utilities**
   - Run policies without exploration/training side effects, while allowing stochastic evaluation from an explicit seed.
   - Aggregate episode return, length, win/outcome rates, and user-supplied metrics over multiple episodes.
   - Keep training and evaluation RNG streams separate for repeatability.

3. **Policy and observation normalization**
   - Provide reusable running statistics with a defined update/freeze lifecycle if policies need normalized observations or rewards.
   - Include those statistics in inference exports and training checkpoints.

4. **API and usage documentation**
   - Add a Poseidon overview with supported features, limitations, test/build instructions, and small end-to-end examples.
   - Document buffer ownership, model in-place initialization/copy restrictions, capacities, and whether each API allocates or mutates its inputs.
   - Document that the game adapter supplies observations, legal actions, rewards, and episode boundaries; Poseidon should not depend on game types.

## Priority 3 — Scale and broader model support

1. **Batched environment integration points**
   - Support collecting from multiple independent environments through a generic caller-driven interface; do not embed a specific game or transport in Poseidon.
   - Profile rollout collection, inference, and training separately before adding parallelism.

2. **Policy distribution coverage**
   - Decide whether Poseidon needs continuous-action policies, parameterized actions, or multiple action heads. Add only the distributions required by intended users, with sampling, log-probability, entropy, and gradient tests.

3. **Partial-observation support**
   - Consider recurrent layers/stateful policy inference if experiments show that feed-forward policies cannot handle relevant hidden state. Define reset and checkpoint semantics for recurrent state first.

4. **General DL expansion (not required for the first RL milestone)**
   - Broaden differentiable tensor operations and model composition as real use cases require them.
   - Consider additional optimizers, regularizers, and layer families based on demonstrated needs.
   - Consider GPU or other compute backends only after profiling shows CPU execution is a bottleneck and the maintenance cost is justified.

## Suggested completion target

Poseidon is ready for the game's first serious RL experiment when a standalone example can collect multi-step rollouts, compute returns/GAE, train a masked discrete actor-critic with PPO minibatches, save/resume deterministically at update boundaries, and report reproducible evaluation metrics—without importing game-specific code.
