# Game Design Document

## 1. Overview

A top-down, 2D real-time strategy game about large battles between two fictional armies.

The player commands squads, not individual soldiers. Orders are simple, battles are fast, and artillery can reshape the battlefield.

The game is inspired by the scale and logistics of *Foxhole* and the tactical combat of *Company of Heroes*, but uses abstract factions, pixel art, and a simpler interface.

## 2. Design Goals

- Make large battles easy to understand.
- Keep important actions within two clicks.
- Show many individual soldiers fighting.
- Support battles with up to one million simulated soldiers.
- Make artillery, explosions, bodies, and terrain damage important.
- Reward decisions more than fast clicking.
- Support multiple players on each of two teams.

## 3. Camera and Map

- Top-down camera.
- Pixel-art battlefield.
- Zoom levels from individual soldiers to the whole frontline.
- Maps are divided into connected sectors.
- Sectors contain cover, supplies, structures, and strategic value.
- Frontlines move as sectors change ownership.

## 4. Main Game Mode: Sector Front

Teams fight to control a network of sectors.

A sector is controlled through:

- Presence of friendly squads.
- Enemy presence.
- Morale.
- Supply connection.
- Defensive structures.
- Time spent uncontested.

A team wins by controlling a required percentage of strategic sectors, capturing the enemy base sector, or breaking the enemy's reinforcement network.

Matches should last about 15–30 minutes.

Other possible modes:

- Breakthrough: attack through a defended line.
- Assault and Defense: one team attacks a fixed objective.
- Annihilation: destroy the enemy's command network.
- Cooperative PvE: multiple players defend against scripted attacks.

## 5. Teams and Multiplayer

There are two opposing teams. Each team can contain multiple players.

Players share:

- Sector ownership.
- Team vision.
- Enemy sightings.
- Strategic objectives.
- Artillery information.

Each player controls assigned squads. A server-authoritative simulation handles the world and validates commands.

Clients send high-level orders such as:

- Move squad 18 to sector 12.
- Attack an enemy position.
- Fire artillery at a target sector.
- Build a defensive structure.

Individual soldier movement is simulated by the server and is not sent as a separate network command.

## 6. Controls

The game avoids drag selection, nested menus, and large command panels.

Basic interaction:

1. Click a friendly squad.
2. Click a destination, enemy, building, or target location.

Examples:

- Friendly squad + ground: move.
- Friendly squad + enemy: attack.
- Artillery + map location: bombard.
- Engineer squad + location: build.
- Damaged squad + friendly base: retreat.

Clicking a squad leader selects its squad. Clicking a platoon marker can select several squads.

## 7. Squads and Soldiers

The squad is the main player-controlled unit.

A squad contains about 8–12 soldiers and has:

- A squad leader.
- A shared order.
- A formation.
- Morale.
- Supply needs.
- A combat role.

Every soldier has its own simulation state:

- Position and velocity.
- Health.
- Morale.
- Suppression.
- Target.
- Weapon cooldown.
- Current order.
- Cover state.

Squad orders provide direction, but soldiers move, fight, scatter, die, and react independently.

## 8. Combat

Core combat systems:

- Health.
- Morale.
- Suppression.
- Cover.
- Visibility.
- Range.
- Ammunition.
- Supply.
- Formation cohesion.

Combat should be readable through behavior and visuals. Suppressed squads stop advancing, low-morale squads retreat, and isolated units become easier to defeat.

## 9. Artillery and Explosions

Artillery is a major part of the game.

Artillery orders use the same two-click system. A target marker and impact delay give players time to react.

Impacts can:

- Kill or injure soldiers.
- Scatter formations.
- Suppress nearby units.
- Destroy cover.
- Damage buildings.
- Create craters.
- Start fires.
- Leave bodies and debris.

Explosions should affect individual soldiers, not only reduce a group health value.

## 10. Buildings

All factions have equivalents for common roles, but each faction uses different versions.

Common roles:

- Headquarters.
- Infantry production.
- Supply and reinforcement.
- Observation and communication.
- Defensive structures.
- Artillery.
- Vehicle or equipment production.

Buildings can provide cover, spawn units, restore supplies, improve vision, coordinate artillery, or control sectors.

## 11. Factions

### Bastion Directorate

Heavy defenses, armor, and long-range artillery.

**Units:** Line Guard, Bulwark Squad, Breach Team, Anchor Team, Warden Tank, Siege Howitzer, Fire-Control Officer, Armored Engineer.

**Buildings:** Citadel HQ, Armored Foundry, Concrete Redoubt, Fire-Control Tower, Siege Battery, Repair Yard, Bastion Wall.

**Strengths:** Defense, armor, artillery.

**Weaknesses:** Slow movement, expensive reinforcements.

### Free Marches

Mobility, scouting, ambushes, and improvised warfare.

**Units:** March Riflemen, Pathfinder Squad, Raider Squad, Recoil Team, Sapper Riders, Mule Carrier, Mobile Mortar, Forward Observer.

**Buildings:** Mobile Command Post, Hidden Supply Cache, Camouflaged Watchpost, Waystation, Improvised Garage, Pop-Up Mortar Nest, Ambush Hideout.

**Strengths:** Speed, map control, reconnaissance.

**Weaknesses:** Light defenses and vehicles.

### Ember Syndicate

Close assaults, demolition, fire, and area denial.

**Units:** Cinder Assault Squad, Flame Team, Breachers, Demolition Crew, Ash Rocket Team, Furnace Tank, Incendiary Artillery, Smokescreen Team.

**Buildings:** Furnace HQ, Munitions Furnace, Breach Workshop, Fire Battery, Minefield Station, Smoke Projector, Fuel Depot.

**Strengths:** Breaking defenses and disrupting formations.

**Weaknesses:** Short range and dangerous infrastructure.

### Meridian Combine

Information, precision weapons, drones, and networked support.

**Units:** Vector Squad, Lens Drone Team, Null Team, Relay Engineers, Lancer Walker, Needle Tank, Precision Artillery, Combat Drone Swarm.

**Buildings:** Nexus Core, Sensor Spire, Drone Fabricator, Signal Jammer, Precision Battery, Repair Node, Relay Mesh.

**Strengths:** Vision, coordination, precision.

**Weaknesses:** Fragile units and dependence on communication.

### Hearth Union

Mass mobilization, logistics, recovery, and morale.

**Units:** Levy Squad, Volunteer Guard, Field Medic Team, Heavy Weapons Crew, Militia Breaker Team, Caravan Hauler, Hearth Tank, Rally Officer.

**Buildings:** Assembly Hall, Muster Depot, Field Hospital, Rally Beacon, Prefab Yard, Mass Mortar Park, Supply Convoy Station.

**Strengths:** Reinforcements, recovery, sustained battles.

**Weaknesses:** Lower individual quality and weak logistics when cut off.

## 12. Art Direction

- Pixel art generated from small sprite patterns.
- Clear silhouettes and readable team colors.
- Individual units use layered sprites for body, weapon, faction, direction, and status.
- Zoomed-out units become small sprites or formation markers.
- Zoomed-in units show combat, explosions, bodies, smoke, wrecks, and craters.

## 13. Simulation and Performance

Every soldier keeps an individual identity and simulation state.

To support large armies:

- Store unit data in packed arrays.
- Use spatial partitioning for movement and combat queries.
- Use simple state machines instead of expensive per-unit AI.
- Run movement and combat at a fixed simulation tick.
- Update distant systems less often.
- Use squad-level pathfinding with individual local movement.
- Render only visible units.
- Process explosions by affected map cells before resolving individual impacts.

The intended scale is:

- 1,000 soldiers: first gameplay prototype.
- 10,000 soldiers: performance milestone.
- 100,000 soldiers: large battle test.
- 1,000,000 soldiers: target scale.

## 14. First Prototype

The first playable version should contain:

- Top-down camera.
- Two factions.
- Two teams with multiple local players simulated.
- Four sectors.
- Basic infantry, recon, engineers, anti-armor, and artillery.
- Squad selection and two-click orders.
- Sector capture.
- Individual soldier movement and combat.
- Artillery impacts and explosions.
- Generated pixel-art sprites.
- Bodies, craters, and simple damaged terrain.

The first matchup should be Bastion Directorate versus Free Marches to test defensive power against mobility.

## 15. Technology

- Language: Odin.
- Rendering: Raylib.
- Simulation and rendering remain separate.
- Multiplayer uses a server-authoritative model.
