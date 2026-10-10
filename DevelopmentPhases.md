# Development Phases

This document tracks the implementation order. Each phase should be playable or testable before the next one starts.

## Status

- `[x]` Complete
- `[-]` In progress
- `[ ]` Planned

## Phase 0: Design Foundation

- [x] Define the top-down RTS direction.
- [x] Define two teams with multiple players per team.
- [x] Define squad-based control.
- [x] Define two-click commands.
- [x] Define sector-based victory as the main mode.
- [x] Define five faction concepts.
- [x] Define individual soldier simulation as a goal.

**Exit:** GDD is clear enough to guide implementation.

## Phase 1: Rendering Foundation

- [x] Open a Raylib window.
- [x] Render a black-and-white board.
- [x] Render a grid and unit markers.
- [x] Keep rendering separate from simulation code.

**Exit:** A board can display simulation state.

## Phase 2: Simulation Foundation

- [x] Store units and squads in packed dynamic arrays.
- [x] Add teams, unit types, and unit states.
- [x] Add individual unit positions and health.
- [x] Add squad formation offsets.
- [x] Add fixed 20 Hz simulation ticks.
- [x] Add idle, move, and attack orders.
- [x] Add individual movement and combat.
- [x] Add damage and death.
- [x] Add basic sector capture progress.
- [x] Add headless scenarios for ticks, movement, combat, death, and capture.

**Exit:** Two squads can move, fight, die, and capture sectors without rendering.

## Phase 3: Command Prototype

- [x] Select a squad with one click.
- [x] Give move and attack orders with a second click.
- [x] Show selected squads clearly.
- [x] Add squad ownership for multiple players.
- [x] Prevent invalid or unauthorized orders.
- [x] Add basic camera movement and zoom.

**Exit:** A player can control a squad without menus or drag selection.

## Phase 4: Core Combat

- [x] Add morale.
- [x] Add suppression.
- [x] Add cover.
- [x] Add ammunition and supply use.
- [x] Add target selection.
- [x] Add retreat behavior.
- [x] Add reinforcement and wounded states.
- [x] Add simple terrain effects.

**Exit:** Battles have readable tactical decisions beyond health and damage.

## Phase 5: Buildings and Logistics

- [x] Add headquarters.
- [x] Add infantry production.
- [x] Add supply and reinforcement buildings.
- [x] Add observation buildings.
- [x] Add defensive structures.
- [x] Add vehicle and equipment production.
- [x] Add construction by engineer squads.
- [x] Connect supply lines to sectors.

**Exit:** Sector control depends on buildings and supply, not only unit count.

## Phase 6: Artillery and Destruction

- [x] Add artillery squads and emplacements.
- [x] Add target markers and impact delays.
- [x] Add projectiles or shell trails.
- [x] Add area damage.
- [x] Add suppression and formation disruption.
- [x] Add craters and damaged terrain.
- [x] Add fires, smoke, debris, and wrecks.
- [x] Add persistent bodies as lightweight visual objects.

**Exit:** Artillery can change the outcome and appearance of a sector battle.

## Phase 7: Factions

- [ ] Implement the Bastion Directorate.
- [ ] Implement the Free Marches.
- [ ] Implement the Ember Syndicate.
- [ ] Implement the Meridian Combine.
- [ ] Implement the Hearth Union.
- [ ] Give each faction distinct units and buildings.
- [ ] Balance faction strengths and weaknesses.

**Exit:** Each faction has a clear play style and at least one strong counter.

## Phase 8: Main Game Mode

- [ ] Build connected sector maps.
- [ ] Add sector objectives.
- [ ] Add reinforcement limits.
- [ ] Add base sectors.
- [ ] Add victory and defeat conditions.
- [ ] Add match setup and restart.
- [ ] Target 15–30 minute matches.

**Exit:** A complete single-player match can start, progress, and end.

## Phase 9: Pixel Art and Presentation

- [ ] Generate basic sprites from code.
- [ ] Add faction palettes and silhouettes.
- [ ] Add walking, firing, and death animations.
- [ ] Add readable squad markers.
- [ ] Add explosion and artillery effects.
- [ ] Add zoom-dependent unit detail.
- [ ] Add sound for combat and orders.

**Exit:** The battlefield is readable and visually communicates combat state.

## Phase 10: Multiplayer

- [ ] Separate simulation from the client process.
- [ ] Add a server-authoritative world.
- [ ] Send high-level player commands.
- [ ] Synchronize sectors, squads, and combat events.
- [ ] Add multiple players per team.
- [ ] Add reconnection handling.
- [ ] Add basic anti-cheat validation.

**Exit:** Multiple players can complete a match on opposing teams.

## Phase 11: Scale and Optimization

- [ ] Add spatial partitioning.
- [ ] Replace expensive per-unit searches.
- [ ] Profile movement and combat updates.
- [ ] Move hot data to structure-of-arrays storage.
- [ ] Add multi-threaded simulation phases.
- [ ] Add event queues for explosions and damage.
- [ ] Test 10,000 units.
- [ ] Test 100,000 units.
- [ ] Test the one-million-unit target.

**Exit:** The simulation remains stable at the largest supported battle size.

## Current Position

Phase 6 implementation is complete. Headless tests and the native build pass through `C:\BuildTools\devcmd.ps1`.

The next milestone is **Phase 7: Factions**: implement the five faction rosters, buildings, roles, and counters.
