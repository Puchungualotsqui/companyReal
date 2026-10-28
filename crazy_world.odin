package main

import "core:math"

// Debug stress world: every kingdom starts fully teched, with many towns, a
// large mixed army and a dense spread of buildings. Launched with -crazy_world.
CRAZY_WORLD_FLAG :: "-crazy_world"
CRAZY_WORLD_TOWNS_PER_KINGDOM :: 10
CRAZY_WORLD_TOWN_MIN_RADIUS :: 24
CRAZY_WORLD_TOWN_MAX_RADIUS :: 200
CRAZY_WORLD_TOWN_SITE_ATTEMPTS :: 4096
CRAZY_WORLD_FOUNDING_SETTLERS :: 8
CRAZY_WORLD_BUILDING_ATTEMPTS :: 512
CRAZY_WORLD_UNIT_ATTEMPTS :: 96
CRAZY_WORLD_INITIAL_WOOD :: 4000
CRAZY_WORLD_INITIAL_INSIGHT :: 500
CRAZY_WORLD_DAY_NUMBER :: 90

CrazyWorldBuilding :: struct {
	kind:  BuildingKind,
	count: int,
}

CRAZY_WORLD_BUILDINGS := [?]CrazyWorldBuilding{
	{.Home, 10},
	{.Farmland, 8},
	{.ArcheryRange, 1},
	{.MagicSchool, 1},
	{.GiantPen, 1},
	{.SiegeWorkshop, 1},
	{.TurtlePen, 1},
	{.ThievesGuild, 1},
	{.DistrictHall, 1},
	{.Granary, 1},
	{.Harbor, 1},
	{.GiantMortar, 1},
	{.AlchemistWorkshop, 1},
	{.FireworksGuild, 1},
	{.StarfallSpire, 1},
	{.Cannon, 2},
	{.Watchtower, 2},
	{.Wall, 8},
	{.Bridge, 1},
	{.Path, 12},
}

CrazyWorldUnits :: struct {
	kind:  UnitKind,
	count: int,
}

CRAZY_WORLD_UNITS := [?]CrazyWorldUnits{
	{.Villager, 30},
	{.Builder, 16},
	{.WaterCollector, 12},
	{.Farmer, 12},
	{.Explorer, 4},
	{.CombatBuilder, 10},
	{.Knight, 24},
	{.Archer, 18},
	{.Mage, 10},
	{.Giant, 5},
	{.Turtle, 4},
	{.Catapult, 5},
	{.Rogue, 8},
}


WorldCrazyWorldPopulate :: proc(w: ^World) {
	for kingdom in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[kingdom] do continue
		w.kingdoms[kingdom].insight = CRAZY_WORLD_INITIAL_INSIGHT
		for tech in CrownTech {
			_ = KingdomUnlockTech(w, kingdom, tech)
		}
	}

	for kingdom in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[kingdom] do continue
		for townSlot in 0..<TOWN_CAPACITY {
			if w.kingdoms[kingdom].townUsed[townSlot] {
				CrazyWorldAdvanceTown(w, kingdom, townSlot)
			}
		}
	}

	for kingdom in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[kingdom] do continue
		CrazyWorldFoundTowns(w, kingdom)
	}

	for kingdom in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[kingdom] do continue
		for townSlot in 0..<TOWN_CAPACITY {
			if !w.kingdoms[kingdom].townUsed[townSlot] do continue
			CrazyWorldPlaceBuildings(w, kingdom, townSlot)
		}
	}

	for kingdom in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[kingdom] do continue
		for townSlot in 0..<TOWN_CAPACITY {
			if !w.kingdoms[kingdom].townUsed[townSlot] do continue
			CrazyWorldSpawnUnits(w, kingdom, townSlot)
		}
	}

	w.dayNumber = CRAZY_WORLD_DAY_NUMBER
	w.simulationTime = f32(w.dayNumber)*f32(WORLD_DAY_LENGTH_SECONDS)
	WorldConstructionChanged(w)
	FogUpdate(w)
}

CrazyWorldAdvanceTown :: proc(w: ^World, kingdom, townSlot: int) {
	town := &w.kingdoms[kingdom].towns[townSlot]
	town.wood = CRAZY_WORLD_INITIAL_WOOD
	town.milestonesEarned = TOWN_MILESTONE_TIER_COUNT
	for town.milestonesChosen < TOWN_MILESTONE_TIER_COUNT {
		option := (townSlot+town.milestonesChosen)%2
		_ = TownChooseMilestone(w, kingdom, townSlot, option)
	}
	for kind in BuildingKind do town.unlockedBuildings |= {kind}
	for kind in UnitKind do town.unlockedUnits |= {kind}
	town.waterAccessCached = false
	town.coastalCached = false
}

CrazyWorldFoundTowns :: proc(w: ^World, kingdom: int) {
	capital := w.kingdoms[kingdom].capitalSlot
	if capital < 0 do return
	town := &w.kingdoms[kingdom].towns[capital]
	anchorX := town.x+2
	anchorY := town.y+2
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)

	for _ in 1..<CRAZY_WORLD_TOWNS_PER_KINGDOM {
		newSlot := KingdomFreeTownSlot(w, kingdom)
		if newSlot < 0 do break

		for attempt in 0..<CRAZY_WORLD_TOWN_SITE_ATTEMPTS {
			angle := WorldNoiseHash(attempt, kingdom*31+1, w.seed+0x70A1)*2*math.PI
			distance := f32(CRAZY_WORLD_TOWN_MIN_RADIUS)+
				WorldNoiseHash(attempt, kingdom*31+2, w.seed+0x70A2)*
					f32(CRAZY_WORLD_TOWN_MAX_RADIUS-CRAZY_WORLD_TOWN_MIN_RADIUS)
			x := WorldWrapCoordinate(anchorX+int(math.cos(angle)*distance), worldWidth)
			y := WorldWrapCoordinate(anchorY+int(math.sin(angle)*distance), worldHeight)
			if !WorldBuildingValid(w, x, y, TownHall{}) do continue
			if !CrazyWorldTownSiteFree(w, x, y) do continue
			if !TownFound(w, kingdom, x, y, CRAZY_WORLD_FOUNDING_SETTLERS) do continue
			CrazyWorldAdvanceTown(w, kingdom, newSlot)
			break
		}
	}
}

CrazyWorldTownSiteFree :: proc(w: ^World, x, y: int) -> bool {
	minimum := f32(TOWN_FOUNDING_MIN_DISTANCE)
	minimumSquared := minimum*minimum
	for kingdom in 0..<KINGDOM_SLOTS {
		if !w.kingdomUsed[kingdom] do continue
		for townSlot in 0..<TOWN_CAPACITY {
			if !w.kingdoms[kingdom].townUsed[townSlot] do continue
			other := &w.kingdoms[kingdom].towns[townSlot]
			deltaX := WorldShortestWrappedDelta(f32(other.x+2-x), f32(w.maxX))
			deltaY := WorldShortestWrappedDelta(f32(other.y+2-y), f32(w.maxY))
			if deltaX*deltaX+deltaY*deltaY < minimumSquared do return false
		}
	}
	return true
}

CrazyWorldPlaceBuildings :: proc(w: ^World, kingdom, townSlot: int) {
	sequence := kingdom*TOWN_CAPACITY*97+townSlot*37
	for plan in CRAZY_WORLD_BUILDINGS {
		for _ in 0..<plan.count {
			CrazyWorldPlaceBuilding(w, kingdom, townSlot, plan.kind, &sequence)
		}
	}
}

CrazyWorldPlaceBuilding :: proc(
	w: ^World,
	kingdom, townSlot: int,
	kind: BuildingKind,
	sequence: ^int,
) {
	town := &w.kingdoms[kingdom].towns[townSlot]
	buildingType := BuildingTypeFromKind(kind)
	radius := f32(town.areaRadius)
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)

	for _ in 0..<CRAZY_WORLD_BUILDING_ATTEMPTS {
		seq := sequence^
		sequence^ += 1
		angle := WorldNoiseHash(seq, kingdom*97+townSlot, w.seed+0xB011)*2*math.PI
		distance := math.sqrt(
			WorldNoiseHash(seq, kingdom*97+townSlot+1, w.seed+0xB012),
		)*radius
		x := WorldWrapCoordinate(town.x+2+int(math.cos(angle)*distance), worldWidth)
		y := WorldWrapCoordinate(town.y+2+int(math.sin(angle)*distance), worldHeight)
		if !TownBuildingInArea(w, kingdom, townSlot, x, y, buildingType) do continue
		if !TownBuildingValid(w, kingdom, x, y, buildingType) do continue
		if _, ok := BuildingSpawn(w, x, y, buildingType, kingdom, townSlot); ok {
			return
		}
	}
}

CrazyWorldSpawnUnits :: proc(w: ^World, kingdom, townSlot: int) {
	for plan in CRAZY_WORLD_UNITS {
		CrazyWorldSpawnUnitKind(w, kingdom, townSlot, plan.kind, plan.count)
	}
}

CrazyWorldSpawnUnitKind :: proc(
	w: ^World,
	kingdom, townSlot: int,
	kind: UnitKind,
	count: int,
) {
	town := &w.kingdoms[kingdom].towns[townSlot]
	role := UnitTypeFromKind(kind)
	radius := f32(town.areaRadius)
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	seed := w.seed ~
		u64(kingdom*TOWN_CAPACITY+townSlot+1)*0x9E3779B97F4A7C15 ~
		(u64(kind)+1)*0xBF58476D1CE4E5B9

	for index in 0..<count {
		for attempt in 0..<CRAZY_WORLD_UNIT_ATTEMPTS {
			seq := index*CRAZY_WORLD_UNIT_ATTEMPTS+attempt
			angle := WorldNoiseHash(seq, kingdom*131+townSlot*7+1, seed+11)*2*math.PI
			distance := math.sqrt(WorldNoiseHash(seq, kingdom*131+townSlot*7+2, seed+23))*
				radius
			x := WorldWrapCoordinate(town.x+2+int(math.cos(angle)*distance), worldWidth)
			y := WorldWrapCoordinate(town.y+2+int(math.sin(angle)*distance), worldHeight)
			if !TownPointInArea(w, kingdom, townSlot, x, y) do continue
			if !UnitValidTileType(role, w.ground[x][y].type) do continue
			if WorldTileOccupied(w, x, y) do continue
			if WorldUnitAtTile(w, x, y) do continue
			if _, ok := UnitSpawn(w, role, f32(x)+0.5, f32(y)+0.5, kingdom, townSlot); ok {
				break
			}
		}
	}
}
