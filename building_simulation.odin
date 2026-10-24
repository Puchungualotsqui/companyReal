package main

import "core:math"

CANNON_RANGE :: 14
CANNON_COOLDOWN :: 3
CANNON_DAMAGE :: 25

WATCHTOWER_RANGE :: 9
WATCHTOWER_COOLDOWN :: 2
WATCHTOWER_DAMAGE :: 6

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
		case Watchtower:
			BuildingUpdateWatchtower(w, building_slot, delta_time)
		}
	}
}

// Keep pathfinding queries O(1); rebuild only when orders are added or removed.
WorldConstructionChanged :: proc(w: ^World) {
	for &blocked in w.tileConstructionBlocked do blocked = false
	for kingdom in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[kingdom] do continue
		for town_slot in 0..<TOWN_CAPACITY {
			if !w.kingdoms[kingdom].townUsed[town_slot] do continue
			town := &w.kingdoms[kingdom].towns[town_slot]
			if !town.constructionActive do continue
			site := town.construction
			BuildingReserveFootprint(w, site.x, site.y, BuildingTypeFromKind(site.kind))
		}
	}
	for slot in 0..<COMBAT_SITE_CAPACITY {
		if !w.combatSiteUsed[slot] do continue
		site := w.combatSites[slot]
		BuildingReserveFootprint(w, site.x, site.y, BuildingTypeFromKind(site.kind))
	}
	w.navigationRevision += 1
}

BuildingReserveFootprint :: proc(w: ^World, x, y: int, building_type: BuildingType, blocked := true) {
	if BuildingWalkable(building_type) do return
	width, height := BuildingTileSize(building_type)
	for tile_x in x..<x+width {
		for tile_y in y..<y+height {
			w.tileConstructionBlocked[tile_x*int(w.maxY)+tile_y] = blocked
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

	nearest_slot := BuildingFindNearestHostileUnit(w, building_slot, CANNON_RANGE)
	if nearest_slot < 0 do return
	width, height := BuildingTileSize(w.buildings[building_slot].type)
	UnitApplyDamage(
		w,
		nearest_slot,
		CANNON_DAMAGE,
		f32(w.buildings.x[building_slot])+f32(width)*0.5,
		f32(w.buildings.y[building_slot])+f32(height)*0.5,
		.Projectile,
	)
	w.buildings.cooldown[building_slot] = CANNON_COOLDOWN
}

BuildingUpdateWatchtower :: proc(w: ^World, building_slot: int, delta_time: f32) {
	if w.buildings.cooldown[building_slot] > 0 {
		w.buildings.cooldown[building_slot] -= delta_time
		return
	}

	nearest_slot := BuildingFindNearestHostileUnit(w, building_slot, WATCHTOWER_RANGE)
	if nearest_slot < 0 do return
	width, height := BuildingTileSize(w.buildings[building_slot].type)
	UnitApplyDamage(
		w,
		nearest_slot,
		WATCHTOWER_DAMAGE,
		f32(w.buildings.x[building_slot])+f32(width)*0.5,
		f32(w.buildings.y[building_slot])+f32(height)*0.5,
		.Projectile,
	)
	w.buildings.cooldown[building_slot] = WATCHTOWER_COOLDOWN
}

BuildingFindNearestHostileUnit :: proc(w: ^World, building_slot: int, attack_range: f32) -> int {
	kingdom_slot := w.buildings.kingdom[building_slot]
	if kingdom_slot < 0 || kingdom_slot >= KINGDOMS_CAPACITY || !w.kingdomUsed[kingdom_slot] {
		return -1
	}

	width, height := BuildingTileSize(w.buildings[building_slot].type)
	center_x := f32(w.buildings.x[building_slot])+f32(width)*0.5
	center_y := f32(w.buildings.y[building_slot])+f32(height)*0.5
	world_width := f32(w.maxX)
	world_height := f32(w.maxY)
	chunk_size := w.spatial.chunkSize
	if chunk_size <= 0 do return -1

	center_chunk_x := int(center_x)/chunk_size
	center_chunk_y := int(center_y)/chunk_size
	chunk_radius := int(attack_range)/chunk_size+1
	nearest_slot := -1
	nearest_distance: f32 = attack_range
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
	return nearest_slot
}

BuildingAccessDistance :: proc(w: ^World, x, y, width, height, tile_x, tile_y: int) -> int {
	distance_x, distance_y := 0, 0
	if tile_x < x || tile_x >= x+width {
		distance_x = min(WorldWrapCoordinate(x-tile_x, int(w.maxX)), WorldWrapCoordinate(tile_x-(x+width-1), int(w.maxX)))
	}
	if tile_y < y || tile_y >= y+height {
		distance_y = min(WorldWrapCoordinate(y-tile_y, int(w.maxY)), WorldWrapCoordinate(tile_y-(y+height-1), int(w.maxY)))
	}
	return max(distance_x, distance_y)
}

// Preflight before paying for an order, then move existing occupants to the
// closest reachable edge. Completion repeats this as a safety net for spawns or
// other position changes during construction. If no exit exists, do not build.
BuildingClearUnits :: proc(w: ^World, x, y: int, building_type: BuildingType, relocate: bool) -> bool {
	if BuildingWalkable(building_type) do return true
	width, height := BuildingTileSize(building_type)
	for slot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[slot] do continue
		unit := &w.units[slot]
		if int(unit.x) < x || int(unit.x) >= x+width || int(unit.y) < y || int(unit.y) >= y+height do continue
		exit_x, exit_y, found := UnitFindBuildingExit(w, slot, x, y, width, height)
		if !found do return false
		if !relocate do continue
		// A displaced trainee must release its old entrance and job assignment.
		if _, converting := unit.state.(StateConverting); converting do UnitConversionCancel(w, slot)
		unit.x, unit.y = f32(exit_x)+0.5, f32(exit_y)+0.5
		unit.previousX, unit.previousY = unit.x, unit.y
		unit.pathReady = false
		if _, pacific := unit.state.(StatePacific); pacific {
			unit.state = StatePacific.Roaming
			unit.cooldown = 0
		}
		SpatialUnitMove(w, slot)
	}
	return true
}

TownBuilderConstruct :: proc(w: ^World, kingdom_slot, town_slot: int, can_grow: bool) -> bool {
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	if town.constructionActive do return false
	if town.farmlands < town.farmers {
		if TownBuilderStartBuilding(w, kingdom_slot, town_slot, Farmland{}) do return true
	}
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
	if town.wood >= 15 {
		if x, y, found := TownAutoPathSite(w, kingdom_slot, town_slot); found {
			if TownStartConstruction(w, kingdom_slot, town_slot, .Path, x, y) do return true
		}
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
TownStartConstruction :: proc(w: ^World, kingdom_slot, town_slot: int, kind: BuildingKind, x, y: int) -> bool {
	if !WorldTownExists(w, kingdom_slot, town_slot) do return false
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	if town.constructionActive do return false
	if !(kind in town.unlockedBuildings) do return false
	if BuildingIsCombat(kind) do return false
	if CombatSiteOverlaps(w, x, y, kind) do return false
	if TownConstructionSiteOverlaps(w, x, y, kind) do return false

	building_type := BuildingTypeFromKind(kind)
	if !WorldBuildingValid(w, x, y, building_type) do return false
	cost := BuildingWoodCost(kind)
	if town.wood < cost do return false
	if !BuildingClearUnits(w, x, y, building_type, false) do return false
	BuildingClearUnits(w, x, y, building_type, true)

	town.wood -= cost
	town.construction = ConstructionSite{kind = kind, x = x, y = y, paid = cost}
	town.constructionActive = true
	WorldConstructionChanged(w)
	return true
}

// Cancels the current town construction and makes its builders re-path to the
// next site. Used when a player order preempts automatic construction.
TownConstructionPreempt :: proc(w: ^World, kingdom_slot, town_slot: int) {
	if !WorldTownExists(w, kingdom_slot, town_slot) do return
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	if !town.constructionActive do return

	town.wood += town.construction.paid
	town.constructionActive = false
	town.construction = {}
	WorldConstructionChanged(w)

	for unit_slot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[unit_slot] do continue
		unit := &w.units[unit_slot]
		if unit.kingdome != kingdom_slot || unit.town != town_slot do continue
		if UnitKindOf(unit.type) != .Builder do continue
		if _, converting := unit.state.(StateConverting); converting do continue
		state := &unit.state.(StatePacific)
		if state^ != .ToConstruction && state^ != .Building do continue
		state^ = .Roaming
		unit.pathReady = false
	}
}

BuildingBuildSeconds :: proc(kind: BuildingKind) -> f32 {
	width, height := BuildingTileSize(BuildingTypeFromKind(kind))
	seconds := 4+f32(width*height)*1.5+BuildingWoodCost(kind)*0.25
	// Town halls are ordered by the player/AI; every other town building is
	// automatic infrastructure, so it comes up faster to keep the opening from
	// dragging.
	if kind != .TownHall do seconds *= 0.6
	return seconds
}

// First decoration whose base tile sits on the site footprint.
TownConstructionPendingDecoration :: proc(w: ^World, site: ConstructionSite) -> int {
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
TownConstructionAccessPoint :: proc(w: ^World, unit_slot, kingdom_slot, town_slot: int) -> (int, int, bool) {
	if !WorldTownExists(w, kingdom_slot, town_slot) do return 0, 0, false
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	if !town.constructionActive do return 0, 0, false

	site := town.construction
	width, height := BuildingTileSize(BuildingTypeFromKind(site.kind))
	unit := &w.units[unit_slot]
	return BuildingFindWorkAccessPoint(w, site.x, site.y, width, height, unit.type, unit.kingdome, int(unit.x), int(unit.y))
}

ConstructionProgress :: enum {
	Working,
	Completed,
}

// Advances one builder's share of site work: clearing first, then raising.
TownConstructionWork :: proc(w: ^World, kingdom_slot, town_slot: int, delta_time: f32) -> ConstructionProgress {
	if !WorldTownExists(w, kingdom_slot, town_slot) do return .Completed
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	if !town.constructionActive do return .Completed

	site := &town.construction
	slot := TownConstructionPendingDecoration(w, site^)
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
	if !BuildingClearUnits(w, site.x, site.y, BuildingTypeFromKind(site.kind), false) do return .Working

	if site.kind == .TownHall {
		if !TownFound(w, kingdom_slot, site.x, site.y) {
			town.wood += site.paid
		}
	} else if _, ok := BuildingSpawn(
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
	WorldConstructionChanged(w)
	return .Completed
}

// Roads grow automatically: first a stub from the hall, then one tile at a time
// from the edge of the existing road network toward a building without access.
TownPathCandidate :: struct {
	x, y: int,
	distance: int,
	score: f32,
	found: bool,
}

TownAutoPathSite :: proc(w: ^World, kingdom_slot, town_slot: int) -> (int, int, bool) {
	target_x, target_y, found := TownPathTarget(w, kingdom_slot, town_slot)
	if !found do return 0, 0, false

	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	candidate := TownPathCandidate{distance = max(int), score = -1}
	seed := u64(kingdom_slot*TOWN_CAPACITY+town_slot)+0xBA7D

	for x in town.x-1 ..= town.x+4 {
		for y in town.y-1 ..= town.y+4 {
			if x >= town.x && x < town.x+4 && y >= town.y && y < town.y+4 do continue
			TownConsiderPathSite(
				w,
				kingdom_slot,
				town_slot,
				x,
				y,
				target_x,
				target_y,
				seed,
				&candidate,
			)
		}
	}

	for building_slot in 0..<BUILDING_CAPACITY {
		if !w.buildingUsed[building_slot] do continue
		if w.buildings.kingdom[building_slot] != kingdom_slot ||
			w.buildings.town[building_slot] != town_slot {
			continue
		}
		if BuildingKindOf(w.buildings[building_slot].type) != .Path do continue
		offsets := [4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
		for offset in offsets {
			TownConsiderPathSite(
				w,
				kingdom_slot,
				town_slot,
				WorldWrapCoordinate(w.buildings.x[building_slot]+offset[0], int(w.maxX)),
				WorldWrapCoordinate(w.buildings.y[building_slot]+offset[1], int(w.maxY)),
				target_x,
				target_y,
				seed,
				&candidate,
			)
		}
	}
	return candidate.x, candidate.y, candidate.found
}

TownConsiderPathSite :: proc(w: ^World, kingdom_slot, town_slot, x, y, target_x, target_y: int, seed: u64, candidate: ^TownPathCandidate) {
	if !TownPointInArea(w, kingdom_slot, town_slot, x, y) do return
	wrapped_x := WorldWrapCoordinate(x, int(w.maxX))
	wrapped_y := WorldWrapCoordinate(y, int(w.maxY))
	if !WorldBuildingValid(w, wrapped_x, wrapped_y, Path{}) do return
	if CombatSiteOverlaps(w, wrapped_x, wrapped_y, .Path) do return

	delta_x := target_x-x
	delta_y := target_y-y
	distance := delta_x*delta_x+delta_y*delta_y
	score := WorldNoiseHash(x, y, seed)
	if candidate.found && (distance > candidate.distance ||
		(distance == candidate.distance && score <= candidate.score)) {
		return
	}
	candidate.x = wrapped_x
	candidate.y = wrapped_y
	candidate.distance = distance
	candidate.score = score
	candidate.found = true
}

TownPathTarget :: proc(w: ^World, kingdom_slot, town_slot: int) -> (int, int, bool) {
	for building_slot in 0..<BUILDING_CAPACITY {
		if !w.buildingUsed[building_slot] do continue
		if w.buildings.kingdom[building_slot] != kingdom_slot ||
			w.buildings.town[building_slot] != town_slot {
			continue
		}
		kind := BuildingKindOf(w.buildings[building_slot].type)
		if kind == .Path || kind == .Wall || kind == .TownHall do continue

		width, height := BuildingTileSize(w.buildings[building_slot].type)
		has_path := false
		for x in w.buildings.x[building_slot]-1 ..= w.buildings.x[building_slot]+width {
			for y in w.buildings.y[building_slot]-1 ..= w.buildings.y[building_slot]+height {
				if WorldTileHasPath(w, x, y) do has_path = true
			}
		}
		if has_path do continue
		return w.buildings.x[building_slot]+width/2, w.buildings.y[building_slot]+height/2, true
	}
	return 0, 0, false
}

// Automatic construction also reserves its footprint, so a player cannot drop a
// combat site on top of a house that is already being raised.
TownConstructionSiteOverlaps :: proc(w: ^World, x, y: int, kind: BuildingKind) -> bool {
	width, height := BuildingTileSize(BuildingTypeFromKind(kind))
	for kingdom_slot in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[kingdom_slot] do continue
		for town_slot in 0..<TOWN_CAPACITY {
			if !w.kingdoms[kingdom_slot].townUsed[town_slot] do continue
			town := &w.kingdoms[kingdom_slot].towns[town_slot]
			if !town.constructionActive do continue
			site := town.construction
			other_width, other_height := BuildingTileSize(BuildingTypeFromKind(site.kind))
			if x < site.x+other_width && site.x < x+width &&
				y < site.y+other_height && site.y < y+height {
				return true
			}
		}
	}
	return false
}

TownFindBuildingSite :: proc(w: ^World, kingdom_slot, town_slot: int, building_type: BuildingType) -> (int, int, bool) {
	if !WorldTownExists(w, kingdom_slot, town_slot) do return 0, 0, false
	world_width := int(w.maxX)
	world_height := int(w.maxY)
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	building_width, building_height := BuildingTileSize(building_type)
	if building_width <= 0 || building_height <= 0 do return 0, 0, false
	field, reachable := FlowFieldGet(w, kingdom_slot, town_slot, Builder{}, kingdom_slot)
	if !reachable do return 0, 0, false

	kind := BuildingKindOf(building_type)
	// Stable per town and building kind, without consuming the effects RNG.
	seed := w.seed ~ (u64(kingdom_slot*TOWN_CAPACITY+town_slot+1)*0x9E3779B97F4A7C15) ~
		(u64(kind)+1)*0xBF58476D1CE4E5B9
	max_radius := max(town.areaRadius, 2)
	min_x := max(0, town.x-max_radius)
	max_x := min(world_width-building_width, town.x+3+max_radius)
	min_y := max(0, town.y-max_radius)
	max_y := min(world_height-building_height, town.y+3+max_radius)
	best_x, best_y := 0, 0
	best_score: f32 = -1e30
	found := false
	for x in min_x..=max_x {
		for y in min_y..=max_y {
			distance_x := max(max(town.x-x, 0), x-(town.x+3))
			distance_y := max(max(town.y-y, 0), y-(town.y+3))
			if max(distance_x, distance_y) < 2 do continue
			if !TownBuildingInArea(w, kingdom_slot, town_slot, x, y, building_type) do continue
			if CombatSiteOverlaps(w, x, y, kind) do continue
			if TownConstructionSiteOverlaps(w, x, y, kind) do continue
			if !WorldBuildingValid(w, x, y, building_type) do continue
			access, accessible := TownPlacementAccess(w, field, kingdom_slot, x, y, building_width, building_height)
			if !accessible do continue
			score := TownPlacementScore(w, x, y, building_width, building_height, town.x, town.y, kind, seed)
			score += f32(min(access, 12))*0.12
			if !found || score > best_score {
				best_x, best_y, best_score, found = x, y, score, true
			}
		}
	}
	return best_x, best_y, found
}

// Reject isolated sites, but allow any reachable work point around the footprint.
TownPlacementAccess :: proc(w: ^World, field: ^FlowField, kingdom, x, y, width, height: int) -> (int, bool) {
	world_width, world_height := int(w.maxX), int(w.maxY)
	for radius in 1..=6 {
		access, walkable := 0, 0
		for tile_x in x-radius ..= x+width-1+radius {
			for tile_y in y-radius ..= y+height-1+radius {
				if tile_x >= x-radius+1 && tile_x <= x+width+radius-2 &&
					tile_y >= y-radius+1 && tile_y <= y+height+radius-2 {
					continue
				}
				wrapped_x := WorldWrapCoordinate(tile_x, world_width)
				wrapped_y := WorldWrapCoordinate(tile_y, world_height)
				if !WorldTileWalkable(w, wrapped_x, wrapped_y, Builder{}, kingdom) do continue
				walkable += 1
				reachable := field.direction[wrapped_x*world_height+wrapped_y] != .Blocked
				if reachable do access += 1
			}
		}
		if walkable > 0 do return access, access > 0
	}
	return 0, false
}

TownPlacementScore :: proc(w: ^World, x, y, width, height, hall_x, hall_y: int, kind: BuildingKind, seed: u64) -> f32 {
	center_x, center_y := f32(x)+f32(width)*0.5, f32(y)+f32(height)*0.5
	delta_x, delta_y := center_x-f32(hall_x+2), center_y-f32(hall_y+2)
	// Jitter can outweigh a few tiles of distance, but not pull buildings to
	// random outskirts. Nearby buildings then shape small, loosely spaced groups.
	score := WorldNoiseHash(x, y, seed)*3.5-math.sqrt(delta_x*delta_x+delta_y*delta_y)*0.7
	min_x, max_x := max(0, x-3), min(int(w.maxX)-1, x+width+2)
	min_y, max_y := max(0, y-3), min(int(w.maxY)-1, y+height+2)
	touching, aligned := 0, 0
	nearest_gap_squared := 18
	road_bonus: f32 = 0
	for tile_x in min_x..=max_x {
		for tile_y in min_y..=max_y {
			slot := w.tileBuilding[tile_x*int(w.maxY)+tile_y]
			if slot < 0 do continue
			other_x, other_y := w.buildings.x[slot], w.buildings.y[slot]
			// Count each neighboring footprint once, even if its anchor is
			// outside this small tile-index query.
			if tile_x != max(min_x, other_x) || tile_y != max(min_y, other_y) do continue
			other_width, other_height := BuildingTileSize(w.buildings[slot].type)
			gap_x := max(0, max(other_x-x-width, x-other_x-other_width))
			gap_y := max(0, max(other_y-y-height, y-other_y-other_height))
			gap_squared := gap_x*gap_x+gap_y*gap_y
			other_kind := BuildingKindOf(w.buildings[slot].type)
			if other_kind == .Path || other_kind == .Bridge {
				if gap_squared == 0 do road_bonus = 1.5
				if gap_squared <= 4 do road_bonus = max(road_bonus, 0.5)
				continue
			}
			nearest_gap_squared = min(nearest_gap_squared, gap_squared)
			if gap_squared == 0 do touching += 1
			if other_kind == kind && (x*2+width == other_x*2+other_width ||
				y*2+height == other_y*2+other_height) {
				aligned += 1
			}
		}
	}
	score += road_bonus+max(0, 3-math.sqrt(f32(nearest_gap_squared)))*0.5
	if kind == .Farmland {
		// Fields may adjoin; retain legal soil rules and favor the existing
		// two-fertile-tile yield threshold rather than decorative spacing.
		score -= f32(min(touching, 4))*0.4
	} else {
		// Soft penalties allow dense/constrained towns to keep building.
		score -= f32(min(touching, 4))*2.5+f32(min(aligned, 3))*1.3
	}
	fertile_tiles := 0
	for tile_x in x..<x+width {
		for tile_y in y..<y+height {
			if w.ground[tile_x][tile_y].type == .FertileGround do fertile_tiles += 1
		}
	}
	if kind == .Farmland {
		if fertile_tiles >= 2 do score += 3
	} else {
		score -= f32(fertile_tiles)*0.2
	}
	return score
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
