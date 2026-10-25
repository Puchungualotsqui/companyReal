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

WorldBuildingUpdate :: proc(w: ^World, deltaTime: f32) {
	for kingdomSlot in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[kingdomSlot] do continue
		for townSlot in 0..<TOWN_CAPACITY {
			if !w.kingdoms[kingdomSlot].townUsed[townSlot] do continue
			town := &w.kingdoms[kingdomSlot].towns[townSlot]
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

	for buildingSlot in 0..<BUILDING_CAPACITY {
		if !w.buildingUsed[buildingSlot] do continue
		kind := BuildingKindOf(w.buildings[buildingSlot].type)
		kingdomSlot := w.buildings.kingdom[buildingSlot]
		townSlot := w.buildings.town[buildingSlot]
		if WorldTownExists(w, kingdomSlot, townSlot) {
			town := &w.kingdoms[kingdomSlot].towns[townSlot]
			town.buildingCounts[kind] += 1
			if town.buildingSlots[kind] < 0 do town.buildingSlots[kind] = buildingSlot
		}

		switch _ in w.buildings[buildingSlot].type {
		case TownHall, Wall, Bridge, ArcheryRange, MagicSchool, GiantPen, SiegeWorkshop, TurtlePen, ThievesGuild, Path, DistrictHall:
		case Home:
			BuildingUpdateHome(w, buildingSlot, deltaTime)
		case Farmland:
			BuildingUpdateFarmland(w, buildingSlot, deltaTime)
		case Cannon:
			BuildingUpdateCannon(w, buildingSlot, deltaTime)
		case Watchtower:
			BuildingUpdateWatchtower(w, buildingSlot, deltaTime)
		}
	}
}

// Keep pathfinding queries O(1); rebuild only when orders are added or removed.
WorldConstructionChanged :: proc(w: ^World) {
	for &blocked in w.tileConstructionBlocked do blocked = false
	for kingdom in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[kingdom] do continue
		for townSlot in 0..<TOWN_CAPACITY {
			if !w.kingdoms[kingdom].townUsed[townSlot] do continue
			town := &w.kingdoms[kingdom].towns[townSlot]
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

BuildingReserveFootprint :: proc(w: ^World, x, y: int, buildingType: BuildingType, blocked := true) {
	if BuildingWalkable(buildingType) do return
	width, height := BuildingTileSize(buildingType)
	for tileX in x..<x+width {
		for tileY in y..<y+height {
			w.tileConstructionBlocked[tileX*int(w.maxY)+tileY] = blocked
		}
	}
}

BuildingUpdateHome :: proc(w: ^World, buildingSlot: int, deltaTime: f32) {
	kingdomSlot := w.buildings.kingdom[buildingSlot]
	townSlot := w.buildings.town[buildingSlot]
	if WorldTownExists(w, kingdomSlot, townSlot) {
		w.kingdoms[kingdomSlot].towns[townSlot].homes += 1
	}
}

BuildingUpdateFarmland :: proc(w: ^World, buildingSlot: int, deltaTime: f32) {
	kingdomSlot := w.buildings.kingdom[buildingSlot]
	townSlot := w.buildings.town[buildingSlot]
	if WorldTownExists(w, kingdomSlot, townSlot) {
		town := &w.kingdoms[kingdomSlot].towns[townSlot]
		town.farmlands += 1
		town.farmlandOutput += BuildingFarmlandOutput(w, buildingSlot)
	}
}

BuildingUpdateCannon :: proc(w: ^World, buildingSlot: int, deltaTime: f32) {
	if w.buildings.cooldown[buildingSlot] > 0 {
		w.buildings.cooldown[buildingSlot] -= deltaTime
		return
	}

	nearestSlot := BuildingFindNearestHostileUnit(w, buildingSlot, CANNON_RANGE)
	if nearestSlot < 0 do return
	width, height := BuildingTileSize(w.buildings[buildingSlot].type)
	UnitApplyDamage(
		w,
		nearestSlot,
		CANNON_DAMAGE,
		f32(w.buildings.x[buildingSlot])+f32(width)*0.5,
		f32(w.buildings.y[buildingSlot])+f32(height)*0.5,
		.Projectile,
	)
	w.buildings.cooldown[buildingSlot] = CANNON_COOLDOWN
}

BuildingUpdateWatchtower :: proc(w: ^World, buildingSlot: int, deltaTime: f32) {
	if w.buildings.cooldown[buildingSlot] > 0 {
		w.buildings.cooldown[buildingSlot] -= deltaTime
		return
	}

	nearestSlot := BuildingFindNearestHostileUnit(w, buildingSlot, WATCHTOWER_RANGE)
	if nearestSlot < 0 do return
	width, height := BuildingTileSize(w.buildings[buildingSlot].type)
	UnitApplyDamage(
		w,
		nearestSlot,
		WATCHTOWER_DAMAGE,
		f32(w.buildings.x[buildingSlot])+f32(width)*0.5,
		f32(w.buildings.y[buildingSlot])+f32(height)*0.5,
		.Projectile,
	)
	w.buildings.cooldown[buildingSlot] = WATCHTOWER_COOLDOWN
}

BuildingFindNearestHostileUnit :: proc(w: ^World, buildingSlot: int, attackRange: f32) -> int {
	kingdomSlot := w.buildings.kingdom[buildingSlot]
	if kingdomSlot < 0 || kingdomSlot >= KINGDOMS_CAPACITY || !w.kingdomUsed[kingdomSlot] {
		return -1
	}

	width, height := BuildingTileSize(w.buildings[buildingSlot].type)
	centerX := f32(w.buildings.x[buildingSlot])+f32(width)*0.5
	centerY := f32(w.buildings.y[buildingSlot])+f32(height)*0.5
	worldWidth := f32(w.maxX)
	worldHeight := f32(w.maxY)
	chunkSize := w.spatial.chunkSize
	if chunkSize <= 0 do return -1

	centerChunkX := int(centerX)/chunkSize
	centerChunkY := int(centerY)/chunkSize
	chunkRadius := int(attackRange)/chunkSize+1
	nearestSlot := -1
	nearestDistance: f32 = attackRange
	for offsetX in -chunkRadius..=chunkRadius {
		chunkX := WorldWrapCoordinate(centerChunkX+offsetX, w.spatial.chunksX)
		for offsetY in -chunkRadius..=chunkRadius {
			chunkY := WorldWrapCoordinate(centerChunkY+offsetY, w.spatial.chunksY)
			chunk := chunkX*w.spatial.chunksY+chunkY
			for unitSlot := w.spatial.unitHead[chunk]; unitSlot >= 0;
				unitSlot = w.spatial.unitNext[unitSlot] {
				if !w.unitUsed[unitSlot] do continue
				if !KingdomAtWar(w, kingdomSlot, w.units[unitSlot].kingdome) do continue
				deltaX := WorldShortestWrappedDelta(w.units.x[unitSlot]-centerX, worldWidth)
				deltaY := WorldShortestWrappedDelta(w.units.y[unitSlot]-centerY, worldHeight)
				distance := math.sqrt(deltaX*deltaX+deltaY*deltaY)
				if distance < nearestDistance {
					nearestDistance = distance
					nearestSlot = unitSlot
				}
			}
		}
	}
	return nearestSlot
}

BuildingAccessDistance :: proc(w: ^World, x, y, width, height, tileX, tileY: int) -> int {
	distanceX, distanceY := 0, 0
	if tileX < x || tileX >= x+width {
		distanceX = min(WorldWrapCoordinate(x-tileX, int(w.maxX)), WorldWrapCoordinate(tileX-(x+width-1), int(w.maxX)))
	}
	if tileY < y || tileY >= y+height {
		distanceY = min(WorldWrapCoordinate(y-tileY, int(w.maxY)), WorldWrapCoordinate(tileY-(y+height-1), int(w.maxY)))
	}
	return max(distanceX, distanceY)
}

// Preflight before paying for an order, then move existing occupants to the
// closest reachable edge. Completion repeats this as a safety net for spawns or
// other position changes during construction. If no exit exists, do not build.
BuildingClearUnits :: proc(w: ^World, x, y: int, buildingType: BuildingType, relocate: bool) -> bool {
	if BuildingWalkable(buildingType) do return true
	width, height := BuildingTileSize(buildingType)
	for slot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[slot] do continue
		unit := &w.units[slot]
		if int(unit.x) < x || int(unit.x) >= x+width || int(unit.y) < y || int(unit.y) >= y+height do continue
		exitX, exitY, found := UnitFindBuildingExit(w, slot, x, y, width, height)
		if !found do return false
		if !relocate do continue
		// A displaced trainee must release its old entrance and job assignment.
		if _, converting := unit.state.(StateConverting); converting do UnitConversionCancel(w, slot)
		unit.x, unit.y = f32(exitX)+0.5, f32(exitY)+0.5
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

TownBuilderConstruct :: proc(w: ^World, kingdomSlot, townSlot: int, canGrow: bool) -> bool {
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	if town.constructionActive do return false
	if town.farmlands < town.farmers {
		if TownBuilderStartBuilding(w, kingdomSlot, townSlot, Farmland{}) do return true
	}
	if town.homes < town.citizens || (canGrow && town.homes == town.citizens) {
		if TownBuilderStartBuilding(w, kingdomSlot, townSlot, Home{}) do return true
	}
	for kind in AUTO_TRAINING_BUILDINGS {
		if kind in town.unlockedBuildings && town.buildingCounts[kind] == 0 {
			if TownBuilderStartBuilding(w, kingdomSlot, townSlot, BuildingTypeFromKind(kind)) {
				return true
			}
		}
	}
	if town.wood >= 15 {
		if x, y, found := TownAutoPathSite(w, kingdomSlot, townSlot); found {
			if TownStartConstruction(w, kingdomSlot, townSlot, .Path, x, y) do return true
		}
	}
	return false
}

TownBuilderStartBuilding :: proc(w: ^World, kingdomSlot, townSlot: int, buildingType: BuildingType) -> bool {
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	if town.constructionActive do return false
	kind := BuildingKindOf(buildingType)
	if !(kind in town.unlockedBuildings) do return false
	if town.wood < BuildingWoodCost(kind) do return false
	x, y, found := TownFindBuildingSite(w, kingdomSlot, townSlot, buildingType)
	if !found do return false
	return TownStartConstruction(w, kingdomSlot, townSlot, kind, x, y)
}

// Orders a building: the town pays for it and gets a construction site that
// builders must clear and then raise.
TownStartConstruction :: proc(w: ^World, kingdomSlot, townSlot: int, kind: BuildingKind, x, y: int) -> bool {
	if !WorldTownExists(w, kingdomSlot, townSlot) do return false
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	if town.constructionActive do return false
	if !(kind in town.unlockedBuildings) do return false
	if BuildingIsCombat(kind) do return false
	if CombatSiteOverlaps(w, x, y, kind) do return false
	if TownConstructionSiteOverlaps(w, x, y, kind) do return false

	buildingType := BuildingTypeFromKind(kind)
	if !WorldBuildingValid(w, x, y, buildingType) do return false
	cost := BuildingWoodCost(kind)
	if town.wood < cost do return false
	if !BuildingClearUnits(w, x, y, buildingType, false) do return false
	BuildingClearUnits(w, x, y, buildingType, true)

	town.wood -= cost
	town.construction = ConstructionSite{kind = kind, x = x, y = y, paid = cost}
	town.constructionActive = true
	WorldConstructionChanged(w)
	return true
}

// Cancels the current town construction and makes its builders re-path to the
// next site. Used when a player order preempts automatic construction.
TownConstructionPreempt :: proc(w: ^World, kingdomSlot, townSlot: int) {
	if !WorldTownExists(w, kingdomSlot, townSlot) do return
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	if !town.constructionActive do return

	town.wood += town.construction.paid
	settlers := town.construction.settlers
	town.constructionActive = false
	town.construction = {}
	WorldConstructionChanged(w)

	// A cancelled town hall returns the settlers that were waiting at home.
	for _ in 0..<settlers do TownSpawnCitizen(w, kingdomSlot, townSlot, Villager{})

	for unitSlot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[unitSlot] do continue
		unit := &w.units[unitSlot]
		if unit.kingdome != kingdomSlot || unit.town != townSlot do continue
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
	chunkSize := w.spatial.chunkSize
	if chunkSize <= 0 do return -1
	width, height := BuildingTileSize(BuildingTypeFromKind(site.kind))
	firstChunkX := site.x/chunkSize
	lastChunkX := (site.x+width-1)/chunkSize
	firstChunkY := site.y/chunkSize
	lastChunkY := (site.y+height-1)/chunkSize
	for chunkY in firstChunkY ..= lastChunkY {
		wrappedY := WorldWrapCoordinate(chunkY, w.spatial.chunksY)
		for chunkX in firstChunkX ..= lastChunkX {
			wrappedX := WorldWrapCoordinate(chunkX, w.spatial.chunksX)
			chunk := wrappedX*w.spatial.chunksY+wrappedY
			for slot := w.spatial.decorationHead[chunk]; slot >= 0;
				slot = w.spatial.decorationNext[slot] {
				decorationX := int(w.decorations.x[slot])
				decorationY := int(w.decorations.y[slot])
				if decorationX >= site.x && decorationX < site.x+width &&
					decorationY >= site.y && decorationY < site.y+height {
					return slot
				}
			}
		}
	}
	return -1
}

// Builders work the site from a walkable tile on the ring around the footprint.
TownConstructionAccessPoint :: proc(w: ^World, unitSlot, kingdomSlot, townSlot: int) -> (int, int, bool) {
	if !WorldTownExists(w, kingdomSlot, townSlot) do return 0, 0, false
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	if !town.constructionActive do return 0, 0, false

	site := town.construction
	width, height := BuildingTileSize(BuildingTypeFromKind(site.kind))
	unit := &w.units[unitSlot]
	return BuildingFindWorkAccessPoint(w, site.x, site.y, width, height, unit.type, unit.kingdome, int(unit.x), int(unit.y))
}

ConstructionProgress :: enum {
	Working,
	Completed,
}

// Advances one builder's share of site work: clearing first, then raising.
TownConstructionWork :: proc(w: ^World, kingdomSlot, townSlot: int, deltaTime: f32) -> ConstructionProgress {
	if !WorldTownExists(w, kingdomSlot, townSlot) do return .Completed
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	if !town.constructionActive do return .Completed

	site := &town.construction
	slot := TownConstructionPendingDecoration(w, site^)
	if slot >= 0 {
		kind := w.decorations.kind[slot]
		site.clearWork += deltaTime
		if site.clearWork >= DecorationClearSeconds(kind) {
			town.wood += DecorationWoodYield(kind)
			WorldDecorationDespawn(w, slot)
			site.clearWork = 0
		}
		return .Working
	}

	site.buildWork += deltaTime
	if site.buildWork < BuildingBuildSeconds(site.kind) do return .Working
	if !BuildingClearUnits(w, site.x, site.y, BuildingTypeFromKind(site.kind), false) do return .Working

	if site.kind == .TownHall {
		if !TownFound(w, kingdomSlot, site.x, site.y, site.settlers) {
			town.wood += site.paid
			for _ in 0..<site.settlers do TownSpawnCitizen(w, kingdomSlot, townSlot, Villager{})
		}
	} else if _, ok := BuildingSpawn(
		w,
		site.x,
		site.y,
		BuildingTypeFromKind(site.kind),
		kingdomSlot,
		townSlot,
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

TownAutoPathSite :: proc(w: ^World, kingdomSlot, townSlot: int) -> (int, int, bool) {
	targetX, targetY, found := TownPathTarget(w, kingdomSlot, townSlot)
	if !found do return 0, 0, false

	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	candidate := TownPathCandidate{distance = max(int), score = -1}
	seed := u64(kingdomSlot*TOWN_CAPACITY+townSlot)+0xBA7D

	for x in town.x-1 ..= town.x+4 {
		for y in town.y-1 ..= town.y+4 {
			if x >= town.x && x < town.x+4 && y >= town.y && y < town.y+4 do continue
			TownConsiderPathSite(
				w,
				kingdomSlot,
				townSlot,
				x,
				y,
				targetX,
				targetY,
				seed,
				&candidate,
			)
		}
	}

	for buildingSlot in 0..<BUILDING_CAPACITY {
		if !w.buildingUsed[buildingSlot] do continue
		if w.buildings.kingdom[buildingSlot] != kingdomSlot ||
			w.buildings.town[buildingSlot] != townSlot {
			continue
		}
		if BuildingKindOf(w.buildings[buildingSlot].type) != .Path do continue
		offsets := [4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
		for offset in offsets {
			TownConsiderPathSite(
				w,
				kingdomSlot,
				townSlot,
				WorldWrapCoordinate(w.buildings.x[buildingSlot]+offset[0], int(w.maxX)),
				WorldWrapCoordinate(w.buildings.y[buildingSlot]+offset[1], int(w.maxY)),
				targetX,
				targetY,
				seed,
				&candidate,
			)
		}
	}
	return candidate.x, candidate.y, candidate.found
}

TownConsiderPathSite :: proc(w: ^World, kingdomSlot, townSlot, x, y, targetX, targetY: int, seed: u64, candidate: ^TownPathCandidate) {
	if !TownPointInArea(w, kingdomSlot, townSlot, x, y) do return
	wrappedX := WorldWrapCoordinate(x, int(w.maxX))
	wrappedY := WorldWrapCoordinate(y, int(w.maxY))
	if !WorldBuildingValid(w, wrappedX, wrappedY, Path{}) do return
	if CombatSiteOverlaps(w, wrappedX, wrappedY, .Path) do return

	deltaX := targetX-x
	deltaY := targetY-y
	distance := deltaX*deltaX+deltaY*deltaY
	score := WorldNoiseHash(x, y, seed)
	if candidate.found && (distance > candidate.distance ||
		(distance == candidate.distance && score <= candidate.score)) {
		return
	}
	candidate.x = wrappedX
	candidate.y = wrappedY
	candidate.distance = distance
	candidate.score = score
	candidate.found = true
}

TownPathTarget :: proc(w: ^World, kingdomSlot, townSlot: int) -> (int, int, bool) {
	for buildingSlot in 0..<BUILDING_CAPACITY {
		if !w.buildingUsed[buildingSlot] do continue
		if w.buildings.kingdom[buildingSlot] != kingdomSlot ||
			w.buildings.town[buildingSlot] != townSlot {
			continue
		}
		kind := BuildingKindOf(w.buildings[buildingSlot].type)
		if kind == .Path || kind == .Wall || kind == .TownHall do continue

		width, height := BuildingTileSize(w.buildings[buildingSlot].type)
		hasPath := false
		for x in w.buildings.x[buildingSlot]-1 ..= w.buildings.x[buildingSlot]+width {
			for y in w.buildings.y[buildingSlot]-1 ..= w.buildings.y[buildingSlot]+height {
				if WorldTileHasPath(w, x, y) do hasPath = true
			}
		}
		if hasPath do continue
		return w.buildings.x[buildingSlot]+width/2, w.buildings.y[buildingSlot]+height/2, true
	}
	return 0, 0, false
}

// Automatic construction also reserves its footprint, so a player cannot drop a
// combat site on top of a house that is already being raised.
TownConstructionSiteOverlaps :: proc(w: ^World, x, y: int, kind: BuildingKind) -> bool {
	width, height := BuildingTileSize(BuildingTypeFromKind(kind))
	for kingdomSlot in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[kingdomSlot] do continue
		for townSlot in 0..<TOWN_CAPACITY {
			if !w.kingdoms[kingdomSlot].townUsed[townSlot] do continue
			town := &w.kingdoms[kingdomSlot].towns[townSlot]
			if !town.constructionActive do continue
			site := town.construction
			otherWidth, otherHeight := BuildingTileSize(BuildingTypeFromKind(site.kind))
			if x < site.x+otherWidth && site.x < x+width &&
				y < site.y+otherHeight && site.y < y+height {
				return true
			}
		}
	}
	return false
}

TownFindBuildingSite :: proc(w: ^World, kingdomSlot, townSlot: int, buildingType: BuildingType) -> (int, int, bool) {
	if !WorldTownExists(w, kingdomSlot, townSlot) do return 0, 0, false
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	buildingWidth, buildingHeight := BuildingTileSize(buildingType)
	if buildingWidth <= 0 || buildingHeight <= 0 do return 0, 0, false
	field, reachable := FlowFieldGet(w, kingdomSlot, townSlot, Builder{}, kingdomSlot)
	if !reachable do return 0, 0, false

	kind := BuildingKindOf(buildingType)
	// Stable per town and building kind, without consuming the effects RNG.
	seed := w.seed ~ (u64(kingdomSlot*TOWN_CAPACITY+townSlot+1)*0x9E3779B97F4A7C15) ~
		(u64(kind)+1)*0xBF58476D1CE4E5B9
	areaMinX, areaMaxX, areaMinY, areaMaxY := TownAreaBounds(w, kingdomSlot, townSlot)
	minX := max(0, areaMinX)
	maxX := min(worldWidth-buildingWidth, areaMaxX)
	minY := max(0, areaMinY)
	maxY := min(worldHeight-buildingHeight, areaMaxY)
	bestX, bestY := 0, 0
	bestScore: f32 = -1e30
	found := false
	for x in minX..=maxX {
		for y in minY..=maxY {
			distanceX := max(max(town.x-x, 0), x-(town.x+3))
			distanceY := max(max(town.y-y, 0), y-(town.y+3))
			if max(distanceX, distanceY) < 2 do continue
			if !TownBuildingInArea(w, kingdomSlot, townSlot, x, y, buildingType) do continue
			if CombatSiteOverlaps(w, x, y, kind) do continue
			if TownConstructionSiteOverlaps(w, x, y, kind) do continue
			if !WorldBuildingValid(w, x, y, buildingType) do continue
			access, accessible := TownPlacementAccess(w, field, kingdomSlot, x, y, buildingWidth, buildingHeight)
			if !accessible do continue
			score := TownPlacementScore(w, x, y, buildingWidth, buildingHeight, town.x, town.y, kind, seed)
			score += f32(min(access, 12))*0.12
			if !found || score > bestScore {
				bestX, bestY, bestScore, found = x, y, score, true
			}
		}
	}
	return bestX, bestY, found
}

// Reject isolated sites, but allow any reachable work point around the footprint.
TownPlacementAccess :: proc(w: ^World, field: ^FlowField, kingdom, x, y, width, height: int) -> (int, bool) {
	worldWidth, worldHeight := int(w.maxX), int(w.maxY)
	for radius in 1..=6 {
		access, walkable := 0, 0
		for tileX in x-radius ..= x+width-1+radius {
			for tileY in y-radius ..= y+height-1+radius {
				if tileX >= x-radius+1 && tileX <= x+width+radius-2 &&
					tileY >= y-radius+1 && tileY <= y+height+radius-2 {
					continue
				}
				wrappedX := WorldWrapCoordinate(tileX, worldWidth)
				wrappedY := WorldWrapCoordinate(tileY, worldHeight)
				if !WorldTileWalkable(w, wrappedX, wrappedY, Builder{}, kingdom) do continue
				walkable += 1
				reachable := field.direction[wrappedX*worldHeight+wrappedY] != .Blocked
				if reachable do access += 1
			}
		}
		if walkable > 0 do return access, access > 0
	}
	return 0, false
}

TownPlacementScore :: proc(w: ^World, x, y, width, height, hallX, hallY: int, kind: BuildingKind, seed: u64) -> f32 {
	centerX, centerY := f32(x)+f32(width)*0.5, f32(y)+f32(height)*0.5
	deltaX, deltaY := centerX-f32(hallX+2), centerY-f32(hallY+2)
	// Jitter can outweigh a few tiles of distance, but not pull buildings to
	// random outskirts. Nearby buildings then shape small, loosely spaced groups.
	score := WorldNoiseHash(x, y, seed)*3.5-math.sqrt(deltaX*deltaX+deltaY*deltaY)*0.7
	minX, maxX := max(0, x-3), min(int(w.maxX)-1, x+width+2)
	minY, maxY := max(0, y-3), min(int(w.maxY)-1, y+height+2)
	touching, aligned := 0, 0
	nearestGapSquared := 18
	roadBonus: f32 = 0
	for tileX in minX..=maxX {
		for tileY in minY..=maxY {
			slot := w.tileBuilding[tileX*int(w.maxY)+tileY]
			if slot < 0 do continue
			otherX, otherY := w.buildings.x[slot], w.buildings.y[slot]
			// Count each neighboring footprint once, even if its anchor is
			// outside this small tile-index query.
			if tileX != max(minX, otherX) || tileY != max(minY, otherY) do continue
			otherWidth, otherHeight := BuildingTileSize(w.buildings[slot].type)
			gapX := max(0, max(otherX-x-width, x-otherX-otherWidth))
			gapY := max(0, max(otherY-y-height, y-otherY-otherHeight))
			gapSquared := gapX*gapX+gapY*gapY
			otherKind := BuildingKindOf(w.buildings[slot].type)
			if otherKind == .Path || otherKind == .Bridge {
				if gapSquared == 0 do roadBonus = 1.5
				if gapSquared <= 4 do roadBonus = max(roadBonus, 0.5)
				continue
			}
			nearestGapSquared = min(nearestGapSquared, gapSquared)
			if gapSquared == 0 do touching += 1
			if otherKind == kind && (x*2+width == otherX*2+otherWidth ||
				y*2+height == otherY*2+otherHeight) {
				aligned += 1
			}
		}
	}
	score += roadBonus+max(0, 3-math.sqrt(f32(nearestGapSquared)))*0.5
	if kind == .Farmland {
		// Fields may adjoin; retain legal soil rules and favor the existing
		// two-fertile-tile yield threshold rather than decorative spacing.
		score -= f32(min(touching, 4))*0.4
	} else {
		// Soft penalties allow dense/constrained towns to keep building.
		score -= f32(min(touching, 4))*2.5+f32(min(aligned, 3))*1.3
	}
	fertileTiles := 0
	for tileX in x..<x+width {
		for tileY in y..<y+height {
			if w.ground[tileX][tileY].type == .FertileGround do fertileTiles += 1
		}
	}
	if kind == .Farmland {
		if fertileTiles >= 2 do score += 3
	} else {
		score -= f32(fertileTiles)*0.2
	}
	return score
}

BuildingFarmlandOutput :: proc(w: ^World, buildingSlot: int) -> f32 {
	x := w.buildings.x[buildingSlot]
	y := w.buildings.y[buildingSlot]
	width, height := BuildingTileSize(w.buildings[buildingSlot].type)
	fertileTiles := 0
	for tileX in x..<x+width {
		for tileY in y..<y+height {
			if w.ground[tileX][tileY].type == .FertileGround do fertileTiles += 1
		}
	}
	output: f32 = 0.10
	if fertileTiles >= 2 do output = 0.16
	return output
}
