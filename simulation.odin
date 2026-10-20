package main

import "core:math"

TOWN_SIMULATION_STEP :: 0.25
WORLD_DAY_LENGTH_SECONDS :: 7*60.0

WorldUpdate :: proc(w: ^World, delta_time: f32) {
	if delta_time <= 0 do return
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
		WorldKingdomUpdate(w, TOWN_SIMULATION_STEP)
		w.simulationAccumulator -= TOWN_SIMULATION_STEP
	}
}

WorldTimeOfDay :: proc(w: ^World) -> f32 {
	return w.dayTime*24/f32(WORLD_DAY_LENGTH_SECONDS)
}

WorldNightAmount :: proc(w: ^World) -> f32 {
	hour := WorldTimeOfDay(w)
	if hour >= 22 do return 0.55
	if hour >= 20 do return 0.55*(hour-20)/2
	if hour < 5 do return 0.55
	if hour < 7 do return 0.55*(7-hour)/2
	return 0
}

WorldTownExists :: proc(w: ^World, kingdom_slot, town_slot: int) -> bool {
	return kingdom_slot >= 0 && kingdom_slot < KINGDOMS_CAPACITY &&
		town_slot >= 0 && town_slot < TOWN_CAPACITY &&
		w.kingdomUsed[kingdom_slot] && w.kingdoms[kingdom_slot].townUsed[town_slot]
}

WorldUnitUpdate :: proc(w: ^World, delta_time: f32) {
	for kingdom_slot in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[kingdom_slot] do continue
		for town_slot in 0..<TOWN_CAPACITY {
			if !w.kingdoms[kingdom_slot].townUsed[town_slot] do continue
			town := &w.kingdoms[kingdom_slot].towns[town_slot]
			town.builders = 0
			town.waterCollectors = 0
			town.farmers = 0
		}
	}

	for unit_slot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[unit_slot] do continue
		switch _ in w.units[unit_slot].type {
		case Villager:
			UnitUpdateVillager(w, unit_slot, delta_time)
		case Builder:
			UnitUpdateBuilder(w, unit_slot, delta_time)
		case WaterCollector:
			UnitUpdateWaterCollector(w, unit_slot, delta_time)
		case Farmer:
			UnitUpdateFarmer(w, unit_slot, delta_time)
		case Knight, Giant:
			UnitUpdateWarrior(w, unit_slot, delta_time)
		}
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
	if can_grow {
		limiting_supply := min(town.foodPotential, town.waterPotential)
		growth_time := 30*population_need/limiting_supply
		town.growthTimer += delta_time
		if town.growthTimer >= growth_time {
			if TownSpawnCitizen(w, kingdom_slot, town_slot, Villager{}) >= 0 {
				town.growthTimer = 0
			}
		}
	} else {
		town.growthTimer = 0
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
