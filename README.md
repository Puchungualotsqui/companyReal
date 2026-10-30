# Things to do
- RL AI implementation
- Menu improvement, more similar to the civ VI menu
- Multiplayer
 
# Ideas

# Bugs
- Shadow of home/house is a bit lower. I think we should recheck all building shadows. Also shadows of units jumping is not excellent.
- We need to stress test defense of towns, I have seen attacking indenpendent towns that they don't defend it completly. The attacking units are in the area of the town and even atacking the townhall and the I don't know if get stuck on the back of the townhall or not even detect him. Because I have seen that they are even idle most of the time.

# Corrections

# Things to check
- Easy to see what kingdom is from the town defended or attacked in the townhall options and by arrows color when town selected

# Clarifications and reminders
- With 2 slices, AI decisions happen every 0.5 s and rendering lags the simulation by up to one slice window. If that feels sluggish, changing UNIT_UPDATE_SLICES is the single knob; 1 restores old responsiveness, 3+ scales further.

# Determinism phases (before multiplayer lockstep)

Target: every peer holds an identical `World` after the same ordered input stream.
Each phase ends with the same seed and input log producing the same state hash on two runs.

## Phase 0 - Baseline (already correct, do not regress)

- No hash-map iteration anywhere; state lives in arrays and slices.
- Gameplay randomness uses `WorldNoiseHash(x, y, seed)` (`generation.odin`), a pure integer hash.
- Fixed simulation step `TOWN_SIMULATION_STEP :: 0.25` and all state in one `World` struct.
- World generation is seed-driven (`WorldGenerationSettings.seed`).

New gameplay randomness must use `WorldNoiseHash` or per-unit state, never `PRandom`.

## Phase 1 - Tick-driven stepping and desync detection

Goal: one fixed tick per command frame, plus a way to see divergence.

- `WorldUpdate` (`simulation.odin`) advances 0..N ticks from `simulationAccumulator` fed by real frame time (`stepTime := min(deltaTime, WORLD_MAX_FRAME_DELTA)`). In a lockstep session, advance exactly one tick per command frame; keep the accumulator for solo play.
- Add `WorldStateHash(w) -> u64` folded over the deterministic subset of `World` (units, towns, buildings, kingdoms, fires, flow fields, counters; not particles, alerts or renderer state).
- Log the hash every N ticks to `profiler.log`; the first differing value names the divergent tick.

Done when: two runs with the same seed and input log produce identical hash sequences.

`WorldTick` advances one command frame; `WorldUpdate` remains the solo frame-time path. Lockstep callers must apply the frame's commands before calling `WorldTick` and update visual effects separately. There is no command scheduler or replay yet.

With profiling enabled, `profiler.log` records the post-tick gameplay hash every `WORLD_HASH_INTERVAL` ticks (currently 16). The first mismatch identifies the first sampled divergent tick, not necessarily the tick where divergence began. Set the interval to 1 to pinpoint it; hashing scans the world and has a cost. The log is overwritten at startup, so save it before a second run.

The hash excludes particles, visual random state, alerts, interpolation and observer-local fog. Contacts are included because they affect diplomacy. Observer-dependent command validation, contacts and player-specific game-end behavior still need a multiplayer design.

A 16-tick scripted command replay checks same-seed hash sequences in serial execution. Matching hashes are not proof of identical state; parallel merges can still cause divergence until later phases are implemented.

## Phase 2 - Per-unit RNG

Goal: no shared random stream for gameplay.

- `PRandom` (`particles.odin`) advances `w.particleRandom` atomically; consumption order can vary across workers and render frames. It is reserved for visual effects.
- Building orders use `WorldNoiseHash` keyed by world seed, simulation tick, source slot, event sequence and effect-specific salts for impact positions and building ignition.
- `UnitApplyDamageNow` uses `PRandom` only for visual blood direction; it does not apply knockback. No per-unit gameplay RNG is currently needed.
- The gameplay hash excludes `particleRandom`. Tests compare gameplay outcomes after different numbers of visual random draws.

Done when: no `PRandom` call influences unit or kingdom state.

## Phase 3 - Deterministic parallel merges

Goal: the unit loop may stay parallel, but every shared effect merges in a canonical order.

- Unit spatial lists are slot-ordered, with stable tie-breaking for target selection and cached insertion hints.
- Builder wood deliveries and town construction contributions merge in unit-slot order. Damage is sorted by hit contents; despawns are processed in slot order. These change the order in which simultaneous effects resolve.
- Unit updates run serially in slot order. They read and mutate shared positions, spatial links, resources, combat sites, buildings and navigation; running the old loop in parallel was nondeterministic. Restoring parallel unit updates requires a shared snapshot-and-intent model or another proven ordering scheme.
- Independent passes use the worker pool when available. Flow masks consume the same per-tick budget whether or not the pool is available.
- The construction merge scans a compact bitset before accessing per-unit records. Damage uses an inline buffer and allocates only on overflow; overflow is never dropped. Other simulation and navigation allocations remain.

The serial unit loop may be slower than the former parallel loop, and flow-field builds on large maps may take more ticks than the former parallel full-mask build. No performance benchmark has been established yet.

Matching hashes across runs with and without the worker pool provide evidence for the scenarios exercised, not every possible game state.

Done when: the same inputs produce the same state hash with and without the worker pool.

## Phase 4 - Remove wall-clock time from world state

Goal: no `rl.GetTime()` in anything hashed or mutated by the sim/render split.

- Alerts use `simulationTime` for timestamps, throttling, growth refresh and expiry. Expired alerts are pruned at the start of each simulation tick, not by UI update or drawing.
- Alerts are observer-local presentation state and remain outside the gameplay hash. They no longer expire while the simulation is paused.
- Profiling clock reads are confined to `profiler.odin`, crazy-world logging and the `AStar` timer. New-game seed generation still uses the system clock before world creation; the selected seed must be shared with peers.

Done when: no `rl.GetTime()` outside `profiler.odin`, the `crazy_world.odin` logging and the `AStar` timer.

## Phase 5 - Float and trig portability

Goal: cross-platform gameplay using fixed-width integer and fixed-point math.

Numeric contract:

- `d32` provides signed Q16.16 arithmetic, wide wrapped geometry, integer square roots and integer-only trigonometry. See `d32/README.md`.
- Unit positions and previous positions are `d32`. All authoritative position updates, wrapped deltas, squared distances and range tests use integer raw units.
- Unit, building and decoration health are `d32`. Town wood and food/water/growth state are `d32`. Damage, costs and production are quantized once at their boundary and accumulated with fixed-point arithmetic.
- Unit, building and order cooldowns and timers, construction/combat progress, hazard/fire/gas lifetimes, town order wards, weather and environment state are `d32`. `deltaTime` is quantized once per update.
- `CommandUseOrder` and `BuildingOrder` targets are `d32`. UI mouse positions are quantized once at command creation; AI emits fixed-point town centers.
- Gameplay placement, target selection, AI scoring, hazard areas, fire spread, order impacts and generation choices no longer use `math.sqrt`, `math.atan2`, `math.sin` or `math.cos`; presentation-only effects still may.
- Randomness uses integer hashes (`WorldNoiseHashInt`) and fixed-point conversion. Long-lived scheduling uses integer ticks; presentation interpolation still uses `simulationTime`.
- `WORLD_STATE_VERSION` is mixed into every state hash. Bump it whenever numeric, generation, command or hash rules change so incompatible builds cannot silently compare hashes.
- Worlds are limited to 32,768 tiles per dimension and 2^28 total tiles so Q16.16 coordinates and path costs stay in range.
- Authoritative units, buildings, decorations, towns, fires, gas, hazards, weather, commands and AI state are fixed point. Effect coordinates and radii are `d32`; particle, animation and render code converts once with `PositionToF32`.
- The only remaining binary32 boundary in gameplay is the frame delta passed to `WorldUpdate`. Simulation ticks always advance by the constant `TOWN_SIMULATION_STEP` (0.25 s), which converts exactly to Q16.16, so authoritative state does not depend on frame-time values.

Behavior changes: fixed-point quantization and integer comparisons can select different targets, impacts, growth batches, AI decisions and generation layouts than earlier float builds, including for existing seeds.

Remaining before cross-platform lockstep:

- Compare initial-state and per-tick hashes across Windows and Linux builds, then macOS and ARM, with and without the worker pool. The numeric migration is complete but this evidence does not exist yet.

Done when: authoritative gameplay and initialization follow the contract and matching inputs produce matching hashes on every supported target.

## Phase 6 - Input as commands

Goal: the world only changes through logged commands applied at a known tick.

- UI handlers mutate `World` immediately (`UIBuildPalettePress`, `UICommandBarPress`, conversion clicks, `UIMilestoneClick`, `TownStartFounding`).
- Wrap each in a `Command`, apply commands in the tick loop before unit updates, and ship them to peers.

Done when: replaying the command log rebuilds the same state hash sequence.

## Phase 7 - Session plumbing

- Seed exchange: `AppNewSeed` uses the system clock and `rl.GetRandomValue`, so the resulting seed must be sent to peers, not regenerated.
- Tick scheduling: agree that "tick N consumes every player's commands for tick N", with a small input delay.
- Optional: periodic state-hash exchange for desync detection and command-log replay for recovery.
