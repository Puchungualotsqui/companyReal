package main

import "core:math"

TOWN_SIMULATION_STEP :: 0.25
WORLD_DAY_LENGTH_SECONDS :: 7*60.0

// Population growth always ticks. Food/water supply and unconverted villagers
// speed it up; these are fractions of the growth bar per second.
GROWTH_BASE_PER_SECOND :: 1.0/150
GROWTH_SUPPLY_PER_SECOND :: 1.0/45
GROWTH_VILLAGER_PER_SECOND :: 1.0/300

WorldUpdate :: proc(w: ^World, delta_time: f32) {
	if delta_time <= 0 do return
	// Particles and gore run on the render clock so they stay smooth between
	// the coarse town simulation ticks.
	WorldParticleUpdate(w, delta_time)
	w.simulationAccumulator += delta_time
	for w.simulationAccumulator >= TOWN_SIMULATION_STEP {
		w.simulationTime += TOWN_SIMULATION_STEP
		w.dayTime += TOWN_SIMULATION_STEP
		if w.dayTime >= f32(WORLD_DAY_LENGTH_SECONDS) {
			w.dayTime -= f32(WORLD_DAY_LENGTH_SECONDS)
			w.dayNumber += 1
		}
		WorldUnitUpdate(w, TOWN_SIMULATION_STEP)
		WorldBuildingUpdate(w, TOWN_SIMULATION_STEP)
		WorldFireUpdate(w, TOWN_SIMULATION_STEP)
		WorldDecorationUpdate(w, TOWN_SIMULATION_STEP)
		BloodUpdate(w, TOWN_SIMULATION_STEP)
		WorldKingdomUpdate(w, TOWN_SIMULATION_STEP)
		FogUpdate(w)
		w.simulationAccumulator -= TOWN_SIMULATION_STEP
	}
}

WorldTimeOfDay :: proc(w: ^World) -> f32 {
	return w.dayTime*24/f32(WORLD_DAY_LENGTH_SECONDS)
}

WorldNightAmount :: proc(w: ^World) -> f32 {
	hour := WorldTimeOfDay(w)
	if hour < 4.5 || hour >= 22 do return 1
	if hour < 6.5 do return 1-(hour-4.5)/2
	if hour < 18.5 do return 0
	return (hour-18.5)/3.5
}

WorldTownExists :: proc(w: ^World, kingdom_slot, town_slot: int) -> bool {
	return kingdom_slot >= 0 && kingdom_slot < KINGDOMS_CAPACITY &&
		town_slot >= 0 && town_slot < TOWN_CAPACITY &&
		w.kingdomUsed[kingdom_slot] && w.kingdoms[kingdom_slot].townUsed[town_slot]
}

WorldUnitUpdate :: proc(w: ^World, delta_time: f32) {
	for unit_slot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[unit_slot] do continue
		w.units.previousX[unit_slot] = w.units.x[unit_slot]
		w.units.previousY[unit_slot] = w.units.y[unit_slot]
	}

	for kingdom_slot in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[kingdom_slot] do continue
		for town_slot in 0..<TOWN_CAPACITY {
			if !w.kingdoms[kingdom_slot].townUsed[town_slot] do continue
			town := &w.kingdoms[kingdom_slot].towns[town_slot]
			town.builders = 0
			town.waterCollectors = 0
			town.farmers = 0
			town.villagers = 0
		}
	}

	for unit_slot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[unit_slot] do continue
		if _, converting := w.units[unit_slot].state.(StateConverting); converting {
			UnitUpdateConverting(w, unit_slot, delta_time)
			continue
		}
		switch _ in w.units[unit_slot].type {
		case Villager:
			UnitUpdateVillager(w, unit_slot, delta_time)
		case Builder:
			UnitUpdateBuilder(w, unit_slot, delta_time)
		case CombatBuilder:
			CombatBuilderUpdate(w, unit_slot, delta_time)
		case WaterCollector:
			UnitUpdateWaterCollector(w, unit_slot, delta_time)
		case Farmer:
			UnitUpdateFarmer(w, unit_slot, delta_time)
		case Explorer:
			UnitUpdateExplorer(w, unit_slot, delta_time)
		case Knight, Archer, Mage, Giant, Turtle, Catapult, Rogue:
			UnitUpdateWarrior(w, unit_slot, delta_time)
		}
		if w.unitUsed[unit_slot] do BloodBleedTick(w, unit_slot, delta_time)
	}
}

WorldKingdomUpdate :: proc(w: ^World, delta_time: f32) {
	housing_remaining: [KINGDOMS_CAPACITY][TOWN_CAPACITY]int
	for kingdom_slot in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[kingdom_slot] do continue
		for town_slot in 0..<TOWN_CAPACITY {
			if !w.kingdoms[kingdom_slot].townUsed[town_slot] do continue
			KingdomTownUpdate(w, kingdom_slot, town_slot, delta_time)
			housing_remaining[kingdom_slot][town_slot] = w.kingdoms[kingdom_slot].towns[town_slot].homes
		}
	}

	shortage_epoch := int(w.simulationTime / 5)
	for unit_slot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[unit_slot] do continue
		kingdom_slot := w.units[unit_slot].kingdome
		town_slot := w.units[unit_slot].town
		if !WorldTownExists(w, kingdom_slot, town_slot) {
			UnitClearTownEffects(w, unit_slot)
			continue
		}

		is_housed := housing_remaining[kingdom_slot][town_slot] > 0
		if is_housed do housing_remaining[kingdom_slot][town_slot] -= 1
		UnitApplyTownEffects(w, unit_slot, is_housed, shortage_epoch, delta_time)
	}

	WorldConversionAssign(w)
}

// Assigns idle units to queued conversions. Runs once per simulation step over
// all units, so the cost stays linear in the number of units rather than towns.
WorldConversionAssign :: proc(w: ^World) {
	for unit_slot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[unit_slot] do continue
		unit := &w.units[unit_slot]
		if _, converting := unit.state.(StateConverting); converting do continue
		if !WorldTownExists(w, unit.kingdome, unit.town) do continue

		town := &w.kingdoms[unit.kingdome].towns[unit.town]
		if town.conversionCount == 0 do continue

		from := UnitKindOf(unit.type)
		for job_index in 0..<town.conversionCount {
			job := &town.conversions[job_index]
			if job.from != from || job.assigned >= job.remaining do continue

			building := TownFindBuilding(
				w,
				unit.kingdome,
				unit.town,
				UnitTrainingBuildingKind(job.to),
			)
			if building < 0 do continue
			access_x, access_y, found := UnitFindBuildingAccessPoint(
				w,
				unit_slot,
				building,
				UnitTypeFromKind(job.to),
			)
			if !found do continue

			job.assigned += 1
			unit.state = StateConverting{
				to = job.to,
				building = building,
				accessX = access_x,
				accessY = access_y,
			}
			unit.pathReady = false
			break
		}
	}
}

KingdomTownUpdate :: proc(w: ^World, kingdom_slot, town_slot: int, delta_time: f32) {
	town := &w.kingdoms[kingdom_slot].towns[town_slot]

	working_farmlands := min(town.farmlands, town.farmers)
	town.foodPotential = 0
	if town.farmlands > 0 {
		town.foodPotential = town.farmlandOutput*f32(working_farmlands)/f32(town.farmlands)
	}
	town.waterPotential = TownWaterAccess(w, kingdom_slot, town_slot)*f32(town.waterCollectors)*0.10
	town.foodShortage = TownResourceShortage(town.foodPotential, town.citizens)
	town.waterShortage = TownResourceShortage(town.waterPotential, town.citizens)

	population_need := f32(town.citizens+1)*0.025
	can_grow := town.foodPotential >= population_need && town.waterPotential >= population_need
	limiting_supply := min(town.foodPotential, town.waterPotential)
	supply_ratio: f32 = 0
	if population_need > 0 {
		supply_ratio = clamp(limiting_supply/population_need, 0, 2)
	}
	town.growthRate =
		GROWTH_BASE_PER_SECOND+
		GROWTH_SUPPLY_PER_SECOND*supply_ratio+
		GROWTH_VILLAGER_PER_SECOND*f32(town.villagers)
	town.growthProgress += town.growthRate*delta_time
	if town.growthProgress >= 1 {
		if TownSpawnCitizen(w, kingdom_slot, town_slot, Villager{}) >= 0 {
			town.growthProgress -= 1
		} else {
			town.growthProgress = 1
		}
	}

	if town.builders > 0 {
		town.constructionProgress += f32(town.builders)*delta_time
		if town.constructionProgress >= 3 {
			if TownBuilderConstruct(w, kingdom_slot, town_slot, can_grow) {
				town.constructionProgress -= 3
			} else {
				town.constructionProgress = min(town.constructionProgress, 3)
			}
		}
	}

	TownMilestoneCheck(w, kingdom_slot, town_slot)
}


TownResourceShortage :: proc(potential: f32, citizens: int) -> f32 {
	need := f32(citizens)*0.025
	if need <= 0 do return 0
	return clamp(1-potential/need, 0, 1)
}

TownWaterAccess :: proc(w: ^World, kingdom_slot, town_slot: int) -> f32 {
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	if town.waterAccessCached && town.waterAccessTerrainRevision == w.terrainRevision {
		return town.waterAccess
	}

	world_width := int(w.maxX)
	world_height := int(w.maxY)
	if world_width <= 0 || world_height <= 0 do return 0

	center_x := town.x+2
	center_y := town.y+2
	nearest_distance_squared: f32 = 0
	found_water := false
	for x in 0..<world_width {
		for y in 0..<world_height {
			tile_type := w.ground[x][y].type
			if tile_type != .FreshWater && tile_type != .River do continue
			delta_x := WorldShortestWrappedDelta(f32(x-center_x), f32(world_width))
			delta_y := WorldShortestWrappedDelta(f32(y-center_y), f32(world_height))
			distance_squared := delta_x*delta_x + delta_y*delta_y
			if !found_water || distance_squared < nearest_distance_squared {
				nearest_distance_squared = distance_squared
				found_water = true
			}
		}
	}

	town.waterAccess = 0
	if found_water do town.waterAccess = 1/(1+math.sqrt(nearest_distance_squared))
	town.waterAccessTerrainRevision = w.terrainRevision
	town.waterAccessCached = true
	return town.waterAccess
}

TownSpawnCitizen :: proc(w: ^World, kingdom_slot, town_slot: int, role: UnitType) -> int {
	if !WorldTownExists(w, kingdom_slot, town_slot) do return -1
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	world_width := int(w.maxX)
	world_height := int(w.maxY)

	// New villagers step out of the town hall door first.
	for offset_x in 0 ..= 1 {
		x := town.x+1+offset_x
		y := town.y+4
		if x < 0 || y < 0 || x >= world_width || y >= world_height do continue
		if !UnitValidTileType(role, w.ground[x][y].type) || WorldTileOccupied(w, x, y) do continue
		if WorldUnitAtTile(w, x, y) do continue
		if unit_slot, ok := UnitSpawn(w, role, f32(x)+0.5, f32(y)+0.5, kingdom_slot, town_slot); ok {
			return unit_slot
		}
	}

	for radius in 1..=8 {
		min_x := max(0, town.x-radius)
		max_x := min(world_width-1, town.x+4+radius)
		min_y := max(0, town.y-radius)
		max_y := min(world_height-1, town.y+4+radius)
		for x in min_x..=max_x {
			for y in min_y..=max_y {
				if x >= town.x && x < town.x+4 && y >= town.y && y < town.y+4 do continue
				if !UnitValidTileType(role, w.ground[x][y].type) || WorldTileOccupied(w, x, y) do continue
				if WorldUnitAtTile(w, x, y) do continue
				if unit_slot, ok := UnitSpawn(w, role, f32(x)+0.5, f32(y)+0.5, kingdom_slot, town_slot); ok {
					return unit_slot
				}
				return -1
			}
		}
	}
	return -1
}

TOWN_INITIAL_VILLAGERS :: 5

TownSpawnInitialVillagers :: proc(w: ^World, kingdom_slot, town_slot: int) -> bool {
	for _ in 0..<TOWN_INITIAL_VILLAGERS {
		if TownSpawnCitizen(w, kingdom_slot, town_slot, Villager{}) < 0 do return false
	}
	return true
}
