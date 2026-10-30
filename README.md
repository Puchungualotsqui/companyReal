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

- Repeat the cross-platform hash comparison for macOS and ARM once those targets are supported.

### Verifying determinism

The game binary has a headless trace mode:

```sh
companiaReal -hash_trace -hash_seed:1 -hash_size:128 -hash_ticks:64
```

Optional flags: `-hash_kingdoms:N`, `-hash_parallel` (initializes the worker pool) and `-hash_commands` (runs a deterministic external command script and then replays the command log into a fresh world, printing `REPLAY ok|failed`). It prints `HASH_TRACE` lines with the state version, initial hash and one hash per tick.

Windows x64 and Linux x64 (WSL, Odin `dev-2026-07`) produced identical traces for seeds 1-3, sizes 128 and 512, with and without the worker pool. Windows used 11 helper threads while WSL used 1, so the match also covers differing worker counts. This is same-build evidence for those scenarios, not proof for every possible state or for macOS/ARM.

Done when: authoritative gameplay and initialization follow the contract and matching inputs produce matching hashes on every supported target.

## Phase 6 - Input as commands

Goal: the world only changes through logged commands applied at a known tick.

Implemented:

- UI actions enqueue `KingdomCommand`s with `WorldQueueCommand`. `WorldApplyPendingCommands` runs at the start of `WorldTick`, before weather and unit updates, in queue order.
- AI issues the same commands through `KingdomIssueCommand` during its controller update. Both paths are validated by one function.
- Every applied command is appended to `World.commandLog` with tick, sequence, kingdom, command, acceptance and source (`Human` or `AI`). Rejected attempts are logged too.
- `WorldReplayCommands` re-applies accepted `Human` entries for a matching tick. AI entries are not replayed because each peer recomputes AI deterministically.
- `profiler.log` records `COMMAND` lines and `WORLD HASH` lines include the command-log hash.

Verification:

```sh
companiaReal -hash_trace -hash_seed:1 -hash_size:128 -hash_ticks:12 -hash_commands
```

This queues deterministic external commands, prints the per-tick hashes, then replays the human command log into a fresh world and prints `REPLAY ok` when every hash matches. The current run reports `REPLAY ok`.

Remaining: bounded retention of the command log and linking the wire format to an actual transport (phase 7).

Done when: replaying the command log rebuilds the same state hash sequence.

## Phase 7 - Session plumbing

Implemented:

- `SessionConfig` captures protocol version, seed, map size, kingdom count, local kingdom and spectator flag. `SessionLog` prints it when a game starts; peers must exchange this instead of regenerating the seed. `SessionConfigCompatible` rejects mismatched sessions.
- `SessionConfigEncode`/`SessionConfigDecode` provide a fixed-width wire format.
- External commands are scheduled with `SESSION_INPUT_DELAY_TICKS` (2). Each queued command carries a `targetTick`; `WorldApplyPendingCommands` applies entries whose tick has arrived and leaves later entries queued.
- `LoggedCommandEncode`/`LoggedCommandDecode` serialize the command log (tick, sequence, kingdom, acceptance, source, command). Command variants use explicit tags and fixed-width fields; `d32` values travel as raw `i32`.
- `SessionHash` combines the session config, authoritative state hash and command-log hash. `WORLD HASH` log lines include it for periodic desync detection.
- Replaying a received log uses `WorldReplayCommands`, which schedules accepted `Human` entries at their recorded ticks.
- Packets are transport-agnostic byte buffers. `SessionEncodeConfigPacket`, `SessionEncodeHashPacket` and `SessionEncodeCommandsPacket` produce them; `SessionDecodePacket` parses them; `WorldReceiveSessionPacket` applies them to a world. Any reliable byte-stream or datagram layer can carry them.
- `WorldCollectHumanCommands` packs the human commands accepted for the current tick into an outgoing batch.
- Command-log retention is bounded: AI entries older than 512 ticks are dropped every 64 ticks, while human entries are kept so peers can replay them.
- Periodic hashes are exchanged with the `Hash` packet. `WorldCheckPeerHash` compares the peer hash with `SessionHash` at the same tick, sets `World.desyncDetected` and logs a `DESYNC` line on mismatch.

Verification:

```sh
companiaReal -hash_trace -hash_seed:1 -hash_size:128 -hash_ticks:10 -hash_commands
```

Prints the session config, per-tick hashes, `WIRE ok=true` after encoding and decoding every logged command, and `REPLAY ok` after rebuilding the sequence from the human log. It then runs an in-process loopback session (`SessionTraceNetwork`): config handshake, a command batch round trip and a per-tick hash exchange, printing `NETWORK ok=true commands=2` when both peers stay in sync.

Done when: two worlds driven by the same session config and command stream agree on every hash. The loopback session verifies that. Same-build traces also match across Windows x64 and Linux x64.

Remaining: a real TCP/UDP transport on top of the packet API, plus reconnect and desync recovery policy (resync from a fresh replay versus dropping the peer).
