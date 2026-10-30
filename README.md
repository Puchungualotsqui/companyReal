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
- Gameplay randomness already uses `WorldNoiseHash(x, y, seed)` (`generation.odin`), a pure integer hash.
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

The hash excludes particles, alerts, interpolation and observer-local fog. Contacts are included because they affect diplomacy. The shared particle random state is also included for now because it affects damage knockback, so visual effects can change the hash until phase 2 separates the streams. Observer-dependent command validation, contacts and player-specific game-end behavior still need a multiplayer design.

A 16-tick scripted command replay checks same-seed hash sequences in serial execution. Matching hashes are not proof of identical state; shared randomness and parallel merges can still cause divergence until later phases are implemented.

## Phase 2 - Per-unit RNG

Goal: no shared random stream.

- `PRandom` (`parallel.odin`) is `atomic_add(&w.particleRandom, ...)`, so values depend on global consumption order across the 11 workers.
- Gameplay use: `UnitApplyDamageNow` (`blood.odin`) picks the knockback direction with it, which moves units.
- Replace with `WorldNoiseHash(unitSlot, tick, salt)` or per-unit PRNG state in `Unit`. Particles and blood may keep a visual-only stream, but it must never feed `World`.

Done when: no `PRandom` call influences unit or kingdom state.

## Phase 3 - Deterministic parallel merges

Goal: the unit loop may stay parallel, but every shared effect merges in a canonical order.

Order-sensitive today:

- Spatial linking (`SpatialUnitMove`, `SpatialUnitLink`) inserts from workers, so per-chunk list order varies. Target selection walks those lists (`UnitFindResourceTarget`, `WarriorFindNearbyHostiles`, `CombatBuilderFindEnemy`, `BuildingFindNearestHostileUnit`). Fix with deterministic insertion or order-independent selection (lowest slot wins).
- `town.wood +=` under `unitMutex` (`UnitUpdateBuilder`) and inside `TownConstructionWork`: f32 addition order changes totals. Accumulate per unit and apply in slot order in the serial pass.
- `pendingDamage` is per thread with `PARALLEL_PENDING_DAMAGE :: 512` and silently drops hits on overflow (`UnitApplyDamage`). Make overflow impossible or deterministic.
- `pendingConstruction` merges by `parallelThreadSlot`, which is assigned by thread startup order (`parallelThreadInit`). Sort entries before applying.
- `w.pendingDespawns` is appended from workers; confirm it is locked, then sort it before the despawn pass.

Interim step: add `DETERMINISTIC_SIM :: true` that runs the unit loop on the calling thread and use it as the reference while fixing the merges.

Done when: toggling `DETERMINISTIC_SIM` produces the same state hash.

## Phase 4 - Remove wall-clock time from world state

Goal: no `rl.GetTime()` in anything hashed or mutated by the sim/render split.

- `alert.odin`: `WorldAlertPush`, `WorldAlertAddGrowth` and `WorldAlertPrune` stamp and compare `rl.GetTime()`, and `WorldAlertPrune` is called from `WorldUIDraw`, so drawing mutates `World`.
- Move alerts out of `World`, or drive them from `simulationTime`, and stop mutating them from the draw path.

Done when: no `rl.GetTime()` outside `profiler.odin`, the `crazy_world.odin` logging and the `AStar` timer.

## Phase 5 - Float and trig portability

Goal: decide the precision contract before networking exists.

- Sim math is all f32. Same binary on the same platform is deterministic; a different OS, arch or libm is not.
- `math.sqrt`, `math.atan2` and `math.sin`/`math.cos` appear in movement and combat (`UnitWarriorEngage` melee fan, `UnitMove`, separation).
- Either restrict lockstep to identical builds, or replace the sim's trig with deterministic approximations.

Done when: the chosen contract is written here and enforced by the build.

## Phase 6 - Input as commands

Goal: the world only changes through logged commands applied at a known tick.

- UI handlers mutate `World` immediately (`UIBuildPalettePress`, `UICommandBarPress`, conversion clicks, `UIMilestoneClick`, `TownStartFounding`).
- Wrap each in a `Command`, apply commands in the tick loop before unit updates, and ship them to peers.

Done when: replaying the command log rebuilds the same state hash sequence.

## Phase 7 - Session plumbing

- Seed exchange: `AppNewSeed` uses `rl.GetTime()` and `rl.GetRandomValue`, so the resulting seed must be sent to peers, not regenerated.
- Tick scheduling: agree that "tick N consumes every player's commands for tick N", with a small input delay.
- Optional: periodic state-hash exchange for desync detection and command-log replay for recovery.
