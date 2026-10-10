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
- [x] Define three resources: materials, fuel, and munitions.
- [x] Define physical logistics through depots, cargo lots, and transport routes.
- [x] Define high-level logistics orders instead of transport micromanagement.
- [x] Define levels of simulation detail for very large battles.

**Exit:** GDD is clear enough to guide implementation, including the resource, logistics, autonomy, and scale direction.

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

## Phase 5: Buildings and Abstract Supply

- [x] Add headquarters.
- [x] Add infantry production.
- [x] Add supply and reinforcement buildings.
- [x] Add observation buildings.
- [x] Add defensive structures.
- [x] Add vehicle and equipment production.
- [x] Add construction by engineer squads.
- [x] Connect supply lines to sectors.
- [x] Use a temporary abstract team supply pool for the prototype.

**Exit:** Sector control depends on buildings and abstract supply, not only unit count. This phase is the foundation for physical logistics, not the final resource model.

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

## Phase 7: Physical Logistics Vertical Slice

- [x] Replace the global team supply pool with local sector inventories.
- [x] Add materials, fuel, and munitions as resource categories.
- [x] Add resource sites, refineries, factories, warehouses, and forward depots.
- [x] Add production inputs and outputs for buildings.
- [x] Add aggregated cargo lots with quantities and destinations.
- [x] Add physical convoy entities with vehicle counts, capacity, fuel, health, and route progress.
- [x] Add sector-based logistics routes and storage capacity.
- [x] Add route travel time, local storage limits, and production buffering through queues.
- [x] Allow enemy presence and destroyed infrastructure to interrupt routes.
- [x] Add cargo loss, convoy destruction, and player-facing route warnings.
- [x] Add automatic transport assignment and high-level logistics priorities.
- [x] Add resource stockpile requests for sectors and production demand.
- [x] Show nearby convoy vehicles and convoy wreck effects.
- [x] Add headless tests for production starvation, route interruption, cargo loss, and recovery.

**Exit:** A two-faction scenario can produce units, move resources between sectors, suffer a logistics disruption, and recover without the player ordering every transport individually.

## Phase 8: High-Level Autonomy and Pathfinding

- [x] Replace direct destination movement with squad-level pathfinding.
- [x] Add a strategic sector route graph.
- [x] Add tactical terrain pathfinding within sectors.
- [x] Add roads, bridges, chokepoints, and route damage.
- [x] Add squad intents: advance, defend, assault, probe, escort, raid, resupply, and withdraw.
- [x] Let squads choose local targets, formations, cover, and retreat behavior.
- [x] Add convoy escort and convoy raid orders.
- [x] Add logistics AI rerouting around blocked or dangerous routes.
- [x] Add readable warnings for isolated squads, factories, and depots.
- [x] Add tests for path selection, blocked routes, and autonomous resupply.

**Exit:** Players can issue objectives and priorities while squads and transport units choose practical local actions on their own.

## Phase 9: Factions

- [x] Implement the Bastion Directorate.
- [x] Implement the Free Marches.
- [x] Implement the Ember Syndicate.
- [x] Implement the Meridian Combine.
- [x] Implement the Hearth Union.
- [x] Give each faction distinct units, buildings, and logistics behavior.
- [x] Give each faction distinct resource costs, production strengths, and counters.
- [x] Balance faction strengths and weaknesses.

**Exit:** Each faction has a clear play style, a distinct relationship with logistics, and at least one strong counter.

## Phase 10: Main Game Mode

- [ ] Build connected sector maps.
- [ ] Add sector objectives.
- [ ] Add reinforcement limits.
- [ ] Add base sectors.
- [ ] Add victory and defeat conditions.
- [ ] Add match setup and restart.
- [ ] Target 15–30 minute matches.

**Exit:** A complete single-player match can start, progress, and end.

## Phase 11: Pixel Art and Presentation

- [ ] Generate basic sprites from code.
- [ ] Add faction palettes and silhouettes.
- [ ] Add walking, firing, and death animations.
- [ ] Add readable squad markers.
- [ ] Add explosion and artillery effects.
- [ ] Add zoom-dependent unit detail.
- [ ] Add sound for combat and orders.

**Exit:** The battlefield is readable and visually communicates combat state.

## Phase 12: Multiplayer

- [ ] Separate simulation from the client process.
- [ ] Add a server-authoritative world.
- [ ] Send high-level player commands.
- [ ] Synchronize sectors, squads, and combat events.
- [ ] Add multiple players per team.
- [ ] Add reconnection handling.
- [ ] Add basic anti-cheat validation.

**Exit:** Multiple players can complete a match on opposing teams.

## Phase 13: Scale and Optimization

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
