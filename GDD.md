# Game Design Document

## 1. Overview

A top-down, 2D real-time strategy game about large battles between two fictional armies.

The player commands squads, formations, buildings, and logistics priorities rather than individual soldiers. Orders are simple, battles are fast, and artillery can reshape the battlefield. Units and transport crews interpret high-level orders and act autonomously.

The game is inspired by the scale and logistics of *Foxhole* and the tactical combat of *Company of Heroes*, but uses abstract factions, pixel art, and a simpler interface.

## 2. Design Goals

- Make large battles easy to understand.
- Keep important actions within two clicks.
- Show many individual soldiers fighting.
- Support battles with up to one million simulated soldiers.
- Make artillery, explosions, bodies, and terrain damage important.
- Reward decisions more than fast clicking.
- Make logistics spatial, visible, and vulnerable without requiring transport micromanagement.
- Use three broad resources: materials, fuel, and munitions.
- Support multiple players on each of two teams.

## 3. Camera and Map

- Top-down camera.
- Pixel-art battlefield.
- Zoom levels from individual soldiers to the whole frontline.
- Maps are divided into connected sectors.
- Sectors contain cover, resource sites, structures, storage, transport routes, and strategic value.
- Resource sites and factories are connected by roads, depots, and sector routes.
- Frontlines move as sectors change ownership.
- Roads, bridges, depots, factories, and resource sites can be damaged, captured, or cut off.

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

Logistics are part of the frontline. A sector can be tactically occupied but strategically unsustainable if its routes, depots, or production network are cut. Local stockpiles allow a short period of continued operation after isolation, creating a readable delay before a force becomes ineffective.

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
- Shared logistics priorities, route warnings, and resource availability.

Each player controls assigned squads and may issue team or local logistics priorities. A server-authoritative simulation handles the world and validates commands.

Clients send high-level orders such as:

- Move squad 18 to sector 12.
- Attack an enemy position.
- Fire artillery at a target sector.
- Build a defensive structure.
- Establish a depot or supply route.
- Prioritize fuel for an armored formation.
- Stockpile munitions at a forward sector.
- Assign a factory to produce vehicles when its local inputs are available.

Individual soldier and transport movement is simulated by the server and is not sent as a separate network command.

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
- Factory + resource depot: prioritize a delivery route.
- Forward sector + resource type: create a stockpile request.

Routine transport is handled by logistics AI. Players choose objectives, priorities, routes, and depots instead of ordering every truck or cargo lot individually.

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

Useful high-level squad intents include:

- Advance toward an area.
- Defend an area or structure.
- Assault a sector.
- Probe for enemies.
- Escort or raid a convoy.
- Resupply and recover.
- Withdraw to a safe position.
- Build or repair a structure.

The player specifies the objective. The squad chooses local movement, formation, targets, cover, timing, and retreat behavior according to its role and current situation.

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

Supply is spatial rather than a single unlimited team pool. Units need access to nearby friendly depots, supply routes, or headquarters to replace ammunition, recover wounded soldiers, and maintain combat effectiveness. Fuel shortages affect vehicles and transport; munitions shortages affect weapons and artillery.

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

- Headquarters and command network.
- Resource extraction.
- Refineries and material processing.
- Infantry production.
- Vehicle and equipment production.
- Ammunition production.
- Warehouses and forward supply depots.
- Reinforcement and recovery.
- Observation and communication.
- Defensive structures.
- Artillery.
- Roads, bridges, and other route infrastructure.

Buildings can provide cover, produce or store resources, spawn units, restore supplies, improve vision, coordinate artillery, repair equipment, or control sectors. Production buildings consume inputs from their local inventory or connected logistics network; they do not draw directly from a global team resource pool.

## 11. Resources and Logistics

The game uses three broad resource categories. They are physical commodities represented by inventories, cargo lots, depots, and transport routes rather than by a single team-wide number.

### Materials

Materials represent metal, machinery, construction components, spare parts, and general industrial goods.

Materials are used for:

- Constructing buildings, roads, bridges, and fortifications.
- Producing infantry equipment.
- Producing vehicles and artillery.
- Repairing damaged infrastructure and equipment.

Materials come from mines, extraction sites, salvage, and captured industrial facilities.

### Fuel

Fuel represents gasoline, diesel, refined oil products, and industrial energy.

Fuel is used for:

- Vehicles and transport.
- Vehicle production.
- Industrial buildings.
- Some artillery and advanced equipment.

Fuel comes from oil fields and refineries. Refineries convert local inputs into usable fuel and may be placed near factories, depots, or vulnerable infrastructure.

### Munitions

Munitions represent ammunition, shells, rockets, explosives, mines, and weapon components.

Munitions are used for:

- Infantry and vehicle ammunition.
- Artillery bombardments.
- Demolition and mines.
- Other specialized weapons.

Munitions come from ammunition plants, military factories, and captured stockpiles.

### Logistics model

The basic logistics chain is:

```text
Resource site → Processor → Storage depot → Transport route → Factory or forward depot → Units
```

A shipment is an aggregated cargo lot or convoy with a resource type, quantity, origin, destination, route, and status. The simulation does not create one entity for every crate, shell, or fuel can.

Factories and forward positions have local inventories and storage limits. Distance affects travel time, transport capacity, fuel use, and route vulnerability. A factory does not need to be immediately adjacent to a refinery, but a longer or unsafe route costs more and is easier to disrupt.

Players control logistics through high-level policies:

- Request a resource at a sector or building.
- Prioritize a factory, front, or unit group.
- Establish or reroute a supply route.
- Build a depot, road, bridge, or warehouse.
- Set stockpile targets.
- Assign escorts or raid enemy routes.

Logistics AI handles routine transport. Convoys can be delayed, intercepted, destroyed, rerouted, or captured. Distant logistics may be simulated at sector level; nearby logistics can be shown as visible trucks, tankers, supply teams, cargo, and wrecks.

Manpower is not a physical resource in the first version. Reinforcements are limited by headquarters capacity, production buildings, faction rules, and time.

## 12. Factions

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

## 13. Art Direction

- Pixel art generated from small sprite patterns.
- Clear silhouettes and readable team colors.
- Individual units use layered sprites for body, weapon, faction, direction, and status.
- Zoomed-out units become small sprites or formation markers.
- Zoomed-in units show combat, explosions, bodies, smoke, wrecks, and craters.

## 14. Simulation and Performance

Every nearby soldier keeps an individual identity and simulation state. The game uses levels of simulation detail so the largest battles remain possible:

- Store hot unit data in packed or structure-of-arrays storage.
- Use spatial partitioning for movement, visibility, combat, and explosion queries.
- Use simple state machines instead of expensive per-unit AI.
- Run authoritative gameplay at a fixed simulation tick.
- Update distant units, sectors, buildings, and logistics less often.
- Use squad-level pathfinding with individual local movement.
- Simulate distant logistics as sector flows or aggregated cargo lots.
- Render only visible units, cargo, effects, and terrain changes.
- Process explosions by affected map cells before resolving individual impacts.
- Use event queues for damage, destruction, cargo loss, and terrain changes.
- Aggregate distant squads or fronts when individual simulation is not relevant to the player.

A spatial route graph connects sectors, roads, bridges, depots, and production sites. Tactical pathfinding operates within a sector while strategic pathfinding chooses the sector route.

The intended scale is:

- 1,000 soldiers: first gameplay prototype.
- 10,000 soldiers: performance milestone.
- 100,000 soldiers: large battle test.
- 1,000,000 soldiers: target scale.

## 15. First Prototype

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
- Three resources: materials, fuel, and munitions.
- One extraction or resource site for each resource chain.
- A refinery, warehouse, forward depot, and one infantry or vehicle factory.
- Aggregated cargo shipments between sectors.
- Production that pauses when local inputs are unavailable.
- A route that can be cut by enemy presence or destroyed infrastructure.
- High-level logistics priorities instead of manual truck commands.

The first matchup should be Bastion Directorate versus Free Marches to test defensive power against mobility and logistics disruption.

## 16. Technology

- Language: Odin.
- Rendering: Raylib.
- Simulation and rendering remain separate.
- Multiplayer uses a server-authoritative model.
