package main

import "core:math"

CANNON_RANGE :: 14
CANNON_COOLDOWN :: 3
CANNON_DAMAGE :: 25

AUTO_TRAINING_BUILDINGS := [6]BuildingKind{
	.ArcheryRange,
	.MagicSchool,
	.GiantPen,
	.SiegeWorkshop,
	.TurtlePen,
	.ThievesGuild,
}

WorldBuildingUpdate :: proc(w: ^World, delta_time: f32) {
	for kingdom_slot in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[kingdom_slot] do continue
		for town_slot in 0..<TOWN_CAPACITY {
			if !w.kingdoms[kingdom_slot].townUsed[town_slot] do continue
			town := &w.kingdoms[kingdom_slot].towns[town_slot]
			town.homes = 0
			town.farmlands = 0
			town.farmlandOutput = 0
			for &count in town.buildingCounts {
				count = 0
			}
			for &slot in town.buildingSlots {
				slot = -1
			}
		}
	}

	for building_slot in 0..<BUILDING_CAPACITY {
		if !w.buildingUsed[building_slot] do continue
		kind := BuildingKindOf(w.buildings[building_slot].type)
		kingdom_slot := w.buildings.kingdom[building_slot]
		town_slot := w.buildings.town[building_slot]
		if WorldTownExists(w, kingdom_slot, town_slot) {
			town := &w.kingdoms[kingdom_slot].towns[town_slot]
			town.buildingCounts[kind] += 1
			if town.buildingSlots[kind] < 0 do town.buildingSlots[kind] = building_slot
		}

		switch _ in w.buildings[building_slot].type {
		case TownHall, Wall, Bridge, ArcheryRange, MagicSchool, GiantPen, SiegeWorkshop, TurtlePen, ThievesGuild, Path:
		case Home:
			BuildingUpdateHome(w, building_slot, delta_time)
		case Farmland:
			BuildingUpdateFarmland(w, building_slot, delta_time)
		case Cannon:
			BuildingUpdateCannon(w, building_slot, delta_time)
		}
	}
}

BuildingUpdateHome :: proc(w: ^World, building_slot: int, delta_time: f32) {
	kingdom_slot := w.buildings.kingdom[building_slot]
	town_slot := w.buildings.town[building_slot]
	if WorldTownExists(w, kingdom_slot, town_slot) {
		w.kingdoms[kingdom_slot].towns[town_slot].homes += 1
	}
}

BuildingUpdateFarmland :: proc(w: ^World, building_slot: int, delta_time: f32) {
	kingdom_slot := w.buildings.kingdom[building_slot]
	town_slot := w.buildings.town[building_slot]
	if WorldTownExists(w, kingdom_slot, town_slot) {
		town := &w.kingdoms[kingdom_slot].towns[town_slot]
		town.farmlands += 1
		town.farmlandOutput += BuildingFarmlandOutput(w, building_slot)
	}
}

BuildingUpdateCannon :: proc(w: ^World, building_slot: int, delta_time: f32) {
	if w.buildings.cooldown[building_slot] > 0 {
		w.buildings.cooldown[building_slot] -= delta_time
		return
	}
	kingdom_slot := w.buildings.kingdom[building_slot]
	if kingdom_slot < 0 || kingdom_slot >= KINGDOMS_CAPACITY || !w.kingdomUsed[kingdom_slot] {
		return
	}

	width, height := BuildingTileSize(w.buildings[building_slot].type)
	center_x := f32(w.buildings.x[building_slot])+f32(width)*0.5
	center_y := f32(w.buildings.y[building_slot])+f32(height)*0.5
	world_width := f32(w.maxX)
	world_height := f32(w.maxY)
	chunk_size := w.spatial.chunkSize
	if chunk_size <= 0 do return

	center_chunk_x := int(center_x)/chunk_size
	center_chunk_y := int(center_y)/chunk_size
	chunk_radius := int(CANNON_RANGE)/chunk_size+1
	nearest_slot := -1
	nearest_distance: f32 = CANNON_RANGE
	for offset_x in -chunk_radius..=chunk_radius {
		chunk_x := WorldWrapCoordinate(center_chunk_x+offset_x, w.spatial.chunksX)
		for offset_y in -chunk_radius..=chunk_radius {
			chunk_y := WorldWrapCoordinate(center_chunk_y+offset_y, w.spatial.chunksY)
			chunk := chunk_x*w.spatial.chunksY+chunk_y
			for unit_slot := w.spatial.unitHead[chunk]; unit_slot >= 0;
				unit_slot = w.spatial.unitNext[unit_slot] {
				if !w.unitUsed[unit_slot] do continue
				if !KingdomAtWar(w, kingdom_slot, w.units[unit_slot].kingdome) do continue
				delta_x := WorldShortestWrappedDelta(w.units.x[unit_slot]-center_x, world_width)
				delta_y := WorldShortestWrappedDelta(w.units.y[unit_slot]-center_y, world_height)
				distance := math.sqrt(delta_x*delta_x+delta_y*delta_y)
				if distance < nearest_distance {
					nearest_distance = distance
					nearest_slot = unit_slot
				}
			}
		}
	}

	if nearest_slot < 0 do return
	w.units[nearest_slot].health -= CANNON_DAMAGE
	if w.units[nearest_slot].health <= 0 do UnitDespawn(w, nearest_slot)
	w.buildings.cooldown[building_slot] = CANNON_COOLDOWN
}

TownBuilderConstruct :: proc(w: ^World, kingdom_slot, town_slot: int, can_grow: bool) -> bool {
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	if town.constructionActive do return false
	if town.homes < town.citizens || (can_grow && town.homes == town.citizens) {
		if TownBuilderStartBuilding(w, kingdom_slot, town_slot, Home{}) do return true
	}
	for kind in AUTO_TRAINING_BUILDINGS {
		if kind in town.unlockedBuildings && town.buildingCounts[kind] == 0 {
			if TownBuilderStartBuilding(w, kingdom_slot, town_slot, BuildingTypeFromKind(kind)) {
				return true
			}
		}
	}
	if town.farmlands < town.farmers {
		if TownBuilderStartBuilding(w, kingdom_slot, town_slot, Farmland{}) do return true
	}
	return false
}

TownBuilderStartBuilding :: proc(w: ^World, kingdom_slot, town_slot: int, building_type: BuildingType) -> bool {
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	if town.constructionActive do return false
	kind := BuildingKindOf(building_type)
	if !(kind in town.unlockedBuildings) do return false
	if town.wood < BuildingWoodCost(kind) do return false
	x, y, found := TownFindBuildingSite(w, kingdom_slot, town_slot, building_type)
	if !found do return false
	return TownStartConstruction(w, kingdom_slot, town_slot, kind, x, y)
}

// Orders a building: the town pays for it and gets a construction site that
// builders must clear and then raise.
TownStartConstruction :: proc(
	w: ^World,
	kingdom_slot, town_slot: int,
	kind: BuildingKind,
	x, y: int,
) -> bool {
	if !WorldTownExists(w, kingdom_slot, town_slot) do return false
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	if town.constructionActive do return false
	if !(kind in town.unlockedBuildings) do return false

	building_type := BuildingTypeFromKind(kind)
	if !WorldBuildingValid(w, x, y, building_type) do return false
	cost := BuildingWoodCost(kind)
	if town.wood < cost do return false

	town.wood -= cost
	town.construction = ConstructionSite{kind = kind, x = x, y = y, paid = cost}
	town.constructionActive = true
	return true
}

BuildingBuildSeconds :: proc(kind: BuildingKind) -> f32 {
	width, height := BuildingTileSize(BuildingTypeFromKind(kind))
	return 4+f32(width*height)*1.5+BuildingWoodCost(kind)*0.25
}

// First decoration whose base tile sits on the site footprint.
ConstructionPendingDecoration :: proc(w: ^World, site: ConstructionSite) -> int {
	chunk_size := w.spatial.chunkSize
	if chunk_size <= 0 do return -1
	width, height := BuildingTileSize(BuildingTypeFromKind(site.kind))
	first_chunk_x := site.x/chunk_size
	last_chunk_x := (site.x+width-1)/chunk_size
	first_chunk_y := site.y/chunk_size
	last_chunk_y := (site.y+height-1)/chunk_size
	for chunk_y in first_chunk_y ..= last_chunk_y {
		wrapped_y := WorldWrapCoordinate(chunk_y, w.spatial.chunksY)
		for chunk_x in first_chunk_x ..= last_chunk_x {
			wrapped_x := WorldWrapCoordinate(chunk_x, w.spatial.chunksX)
			chunk := wrapped_x*w.spatial.chunksY+wrapped_y
			for slot := w.spatial.decorationHead[chunk]; slot >= 0;
				slot = w.spatial.decorationNext[slot] {
				decoration_x := int(w.decorations.x[slot])
				decoration_y := int(w.decorations.y[slot])
				if decoration_x >= site.x && decoration_x < site.x+width &&
					decoration_y >= site.y && decoration_y < site.y+height {
					return slot
				}
			}
		}
	}
	return -1
}

// Builders work the site from a walkable tile on the ring around the footprint.
TownConstructionAccessPoint :: proc(
	w: ^World,
	unit_slot, kingdom_slot, town_slot: int,
) -> (int, int, bool) {
	if !WorldTownExists(w, kingdom_slot, town_slot) do return 0, 0, false
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	if !town.constructionActive do return 0, 0, false

	site := town.construction
	width, height := BuildingTileSize(BuildingTypeFromKind(site.kind))
	world_width := int(w.maxX)
	world_height := int(w.maxY)
	if world_width <= 0 || world_height <= 0 do return 0, 0, false

	for radius in 1 ..= 6 {
		inner_min_x := site.x-radius+1
		inner_max_x := site.x+width-1+radius-1
		inner_min_y := site.y-radius+1
		inner_max_y := site.y+height-1+radius-1
		for x in site.x-radius ..= site.x+width-1+radius {
			for y in site.y-radius ..= site.y+height-1+radius {
				if x >= inner_min_x && x <= inner_max_x && y >= inner_min_y && y <= inner_max_y {
					continue
				}
				wrapped_x := WorldWrapCoordinate(x, world_width)
				wrapped_y := WorldWrapCoordinate(y, world_height)
				if !WorldTileWalkable(w, wrapped_x, wrapped_y, w.units[unit_slot].type) do continue
				return wrapped_x, wrapped_y, true
			}
		}
	}
	return 0, 0, false
}

ConstructionProgress :: enum {
	Working,
	Completed,
}

// Advances one builder's share of site work: clearing first, then raising.
TownConstructionWork :: proc(
	w: ^World,
	kingdom_slot, town_slot: int,
	delta_time: f32,
) -> ConstructionProgress {
	if !WorldTownExists(w, kingdom_slot, town_slot) do return .Completed
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	if !town.constructionActive do return .Completed

	site := &town.construction
	slot := ConstructionPendingDecoration(w, site^)
	if slot >= 0 {
		kind := w.decorations.kind[slot]
		site.clearWork += delta_time
		if site.clearWork >= DecorationClearSeconds(kind) {
			town.wood += DecorationWoodYield(kind)
			WorldDecorationDespawn(w, slot)
			site.clearWork = 0
		}
		return .Working
	}

	site.buildWork += delta_time
	if site.buildWork < BuildingBuildSeconds(site.kind) do return .Working

	if _, ok := BuildingSpawn(
		w,
		site.x,
		site.y,
		BuildingTypeFromKind(site.kind),
		kingdom_slot,
		town_slot,
	); !ok {
		town.wood += site.paid
	}
	town.constructionActive = false
	town.construction = {}
	return .Completed
}

TownBuildManual :: proc(w: ^World, kingdom_slot, town_slot: int, kind: BuildingKind, x, y: int) -> bool {
	if !WorldTownExists(w, kingdom_slot, town_slot) do return false
	if !BuildingIsManual(kind) do return false
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	if !(kind in town.unlockedBuildings) do return false
	if TownUnitCount(w, kingdom_slot, town_slot, .Builder) <= 0 do return false

	building_type := BuildingTypeFromKind(kind)
	if !TownBuildingInArea(w, kingdom_slot, town_slot, x, y, building_type) do return false
	return TownStartConstruction(w, kingdom_slot, town_slot, kind, x, y)
}

TownFindBuildingSite :: proc(w: ^World, kingdom_slot, town_slot: int, building_type: BuildingType) -> (int, int, bool) {
	if !WorldTownExists(w, kingdom_slot, town_slot) do return 0, 0, false
	world_width := int(w.maxX)
	world_height := int(w.maxY)
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	town_x := town.x
	town_y := town.y
	building_width, building_height := BuildingTileSize(building_type)
	if building_width <= 0 || building_height <= 0 do return 0, 0, false
	max_radius := max(town.areaRadius, 2)
	for radius in 2..=max_radius {
		min_x := max(0, town_x-radius)
		max_x := min(world_width-building_width, town_x+3+radius)
		min_y := max(0, town_y-radius)
		max_y := min(world_height-building_height, town_y+3+radius)
		for x in min_x..=max_x {
			for y in min_y..=max_y {
				distance_x := max(max(town_x-x, 0), x-(town_x+3))
				distance_y := max(max(town_y-y, 0), y-(town_y+3))
				if max(distance_x, distance_y) != radius do continue
				if !TownBuildingInArea(w, kingdom_slot, town_slot, x, y, building_type) {
					continue
				}
				if WorldBuildingValid(w, x, y, building_type) do return x, y, true
			}
		}
	}
	return 0, 0, false
}

BuildingFarmlandOutput :: proc(w: ^World, building_slot: int) -> f32 {
	x := w.buildings.x[building_slot]
	y := w.buildings.y[building_slot]
	width, height := BuildingTileSize(w.buildings[building_slot].type)
	fertile_tiles := 0
	for tile_x in x..<x+width {
		for tile_y in y..<y+height {
			if w.ground[tile_x][tile_y].type == .FertileGround do fertile_tiles += 1
		}
	}
	output: f32 = 0.10
	if fertile_tiles >= 2 do output = 0.16
	return output
}
