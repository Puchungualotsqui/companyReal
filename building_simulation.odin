package main

import "base:intrinsics"
import "d32"

CANNON_RANGE :: 14
CANNON_COOLDOWN :: 3
CANNON_DAMAGE :: d32.Value(25*d32.SCALE)

WATCHTOWER_RANGE :: 9
WATCHTOWER_COOLDOWN :: 2
WATCHTOWER_DAMAGE :: d32.Value(6*d32.SCALE)

AUTO_TRAINING_BUILDINGS := [6]BuildingKind{
	.ArcheryRange,
	.MagicSchool,
	.GiantPen,
	.SiegeWorkshop,
	.TurtlePen,
	.ThievesGuild,
}

TownConstructionCount :: proc(w: ^World, kingdomSlot, townSlot: int) -> int {
	if !WorldTownExists(w, kingdomSlot, townSlot) do return 0
	count := 0
	for site in w.kingdoms[kingdomSlot].towns[townSlot].constructions {
		if site.active do count += 1
	}
	return count
}

TownConstructionKindCount :: proc(w: ^World, kingdomSlot, townSlot: int, kind: BuildingKind) -> int {
	if !WorldTownExists(w, kingdomSlot, townSlot) do return 0
	count := 0
	for site in w.kingdoms[kingdomSlot].towns[townSlot].constructions {
		if site.active && site.kind == kind do count += 1
	}
	return count
}

TownConstructionFreeSlot :: proc(w: ^World, kingdomSlot, townSlot: int) -> int {
	if !WorldTownExists(w, kingdomSlot, townSlot) do return -1
	for site, index in w.kingdoms[kingdomSlot].towns[townSlot].constructions {
		if !site.active do return index
	}
	return -1
}

WorldBuildingUpdate :: proc(w: ^World, deltaTime: f32) {
	for kingdomSlot in 0..<KINGDOM_SLOTS {
		if !w.kingdomUsed[kingdomSlot] do continue
		for townSlot in 0..<TOWN_CAPACITY {
			if !w.kingdoms[kingdomSlot].townUsed[townSlot] do continue
			town := &w.kingdoms[kingdomSlot].towns[townSlot]
			town.homes = 0
			town.farmlands = 0
			town.farmlandOutput = d32.ZERO
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
		case TownHall, Wall, Bridge, ArcheryRange, MagicSchool, GiantPen, SiegeWorkshop, TurtlePen, ThievesGuild, Path, DistrictHall, Granary:
		case Home:
			BuildingUpdateHome(w, buildingSlot, deltaTime)
		case Farmland:
			BuildingUpdateFarmland(w, buildingSlot, deltaTime)
		case Cannon:
			BuildingUpdateCannon(w, buildingSlot, deltaTime)
		case Watchtower:
			BuildingUpdateWatchtower(w, buildingSlot, deltaTime)
		case BuildingOrder:
			BuildingUpdateOrder(w, buildingSlot, deltaTime)
		}
	}
}

// Keep pathfinding queries O(1); rebuild only when orders are added or removed.
// Town construction sites deliberately stay walkable: a batch of sites must not
// seal off another site's access or a training building's only route. Overlap
// checks still prevent buildings and other sites from being placed on them.
WorldConstructionChanged :: proc(w: ^World) {
	// Only combat-site footprints are reserved, so clearing the whole map here
	// made every construction start cost a full-map pass.
	for index in w.constructionBlockedTiles do w.tileConstructionBlocked[index] = false
	clear(&w.constructionBlockedTiles)
	for slot in 0..<COMBAT_SITE_CAPACITY {
		if !w.combatSiteUsed[slot] do continue
		site := w.combatSites[slot]
		BuildingReserveFootprint(w, site.x, site.y, BuildingTypeFromKind(site.kind))
	}
	w.navigationRevision += 1
}

BuildingReserveFootprint :: proc(w: ^World, x, y: int, buildingType: BuildingType) {
	if BuildingWalkable(buildingType) do return
	width, height := BuildingTileSize(buildingType)
	worldHeight := int(w.maxY)
	for tileX in x..<x+width {
		for tileY in y..<y+height {
			index := tileX*worldHeight+tileY
			if w.tileConstructionBlocked[index] do continue
			w.tileConstructionBlocked[index] = true
			append(&w.constructionBlockedTiles, index)
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
		// Fertility only changes with the terrain, so the footprint scan is cached.
		if w.buildings.outputRevision[buildingSlot] != w.terrainRevision {
			w.buildings.output[buildingSlot] = BuildingFarmlandOutput(w, buildingSlot)
			w.buildings.outputRevision[buildingSlot] = w.terrainRevision
		}
		town.farmlandOutput = d32.Add(town.farmlandOutput, w.buildings.output[buildingSlot])
	}
}

BuildingUpdateCannon :: proc(w: ^World, buildingSlot: int, deltaTime: f32) {
	if w.buildings.cooldown[buildingSlot] > d32.ZERO {
		w.buildings.cooldown[buildingSlot] = max(
			d32.Sub(w.buildings.cooldown[buildingSlot], PositionFromF32(deltaTime)),
			d32.ZERO,
		)
		return
	}

	nearestSlot := BuildingFindNearestHostileUnit(w, buildingSlot, CANNON_RANGE)
	if nearestSlot < 0 do return
	centerX, centerY := OrderBuildingCenterRaw(w, buildingSlot)
	WorldProjectileBurst(
		w,
		PositionToF32(centerX),
		PositionToF32(centerY),
		UnitX(w, nearestSlot),
		UnitY(w, nearestSlot),
		18,
		0,
		0.20,
		0.75,
		0,
		0,
		.Boulder,
	)
	UnitApplyDamage(
		w,
		nearestSlot,
		CANNON_DAMAGE,
		centerX,
		centerY,
		.Projectile,
	)
	w.buildings.cooldown[buildingSlot] = d32.FromInt(CANNON_COOLDOWN)
}

BuildingUpdateWatchtower :: proc(w: ^World, buildingSlot: int, deltaTime: f32) {
	if w.buildings.cooldown[buildingSlot] > d32.ZERO {
		w.buildings.cooldown[buildingSlot] = max(
			d32.Sub(w.buildings.cooldown[buildingSlot], PositionFromF32(deltaTime)),
			d32.ZERO,
		)
		return
	}

	nearestSlot := BuildingFindNearestHostileUnit(w, buildingSlot, WATCHTOWER_RANGE)
	if nearestSlot < 0 do return
	centerX, centerY := OrderBuildingCenterRaw(w, buildingSlot)
	WorldProjectileBurst(
		w,
		PositionToF32(centerX),
		PositionToF32(centerY),
		UnitX(w, nearestSlot),
		UnitY(w, nearestSlot),
		22,
		0,
		0.35,
		0.60,
		0,
		0,
		.Arrow,
	)
	UnitApplyDamage(
		w,
		nearestSlot,
		WATCHTOWER_DAMAGE,
		centerX,
		centerY,
		.Projectile,
	)
	w.buildings.cooldown[buildingSlot] = d32.FromInt(WATCHTOWER_COOLDOWN)
}

BuildingFindNearestHostileUnit :: proc(w: ^World, buildingSlot: int, attackRange: int) -> int {
	kingdomSlot := w.buildings.kingdom[buildingSlot]
	if kingdomSlot < 0 || kingdomSlot >= KINGDOMS_CAPACITY || !w.kingdomUsed[kingdomSlot] {
		return -1
	}

	width, height := BuildingTileSize(w.buildings[buildingSlot].type)
	centerX := d32.FromRaw(i32(i64(w.buildings.x[buildingSlot])*d32.SCALE+i64(width)*(d32.SCALE/2)))
	centerY := d32.FromRaw(i32(i64(w.buildings.y[buildingSlot])*d32.SCALE+i64(height)*(d32.SCALE/2)))
	worldWidthRaw := i64(w.maxX)*d32.SCALE
	worldHeightRaw := i64(w.maxY)*d32.SCALE
	chunkSize := w.spatial.chunkSize
	if chunkSize <= 0 do return -1

	centerChunkX := int(d32.ToInt(centerX))/chunkSize
	centerChunkY := int(d32.ToInt(centerY))/chunkSize
	chunkRadius := attackRange/chunkSize+1
	nearestSlot := -1
	attackRangeRaw := i64(attackRange)*d32.SCALE
	nearestDistanceSquared := u64(attackRangeRaw)*u64(attackRangeRaw)
	for offsetX in -chunkRadius..=chunkRadius {
		chunkX := WorldWrapCoordinate(centerChunkX+offsetX, w.spatial.chunksX)
		for offsetY in -chunkRadius..=chunkRadius {
			chunkY := WorldWrapCoordinate(centerChunkY+offsetY, w.spatial.chunksY)
			chunk := chunkX*w.spatial.chunksY+chunkY
			if !SpatialChunkHasEnemy(w, chunk, kingdomSlot) do continue
			for unitSlot := w.spatial.unitHead[chunk]; unitSlot >= 0;
				unitSlot = w.spatial.unitNext[unitSlot] {
				if !w.unitUsed[unitSlot] do continue
				if !KingdomAtWar(w, kingdomSlot, w.units[unitSlot].kingdome) do continue
				distanceSquared, valid := d32.WrappedDistanceSquared(
					w.units[unitSlot].x,
					w.units[unitSlot].y,
					centerX,
					centerY,
					worldWidthRaw,
					worldHeightRaw,
				)
				if !valid do continue
				if distanceSquared < nearestDistanceSquared ||
					(distanceSquared == nearestDistanceSquared && nearestSlot >= 0 && unitSlot < nearestSlot) {
					nearestDistanceSquared = distanceSquared
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
	if width <= 0 || height <= 0 do return true
	chunkSize := w.spatial.chunkSize
	chunksX := w.spatial.chunksX
	chunksY := w.spatial.chunksY
	if chunkSize <= 0 || chunksX <= 0 || chunksY <= 0 do return true
	// Buildings never wrap, so only the buckets the footprint touches can hold
	// an occupant. Scanning every unit slot here made each placement O(units).
	startChunkX := x/chunkSize
	startChunkY := y/chunkSize
	spanChunksX := (x+width-1)/chunkSize-startChunkX+1
	spanChunksY := (y+height-1)/chunkSize-startChunkY+1
	for offsetX in 0..<min(spanChunksX, chunksX) {
		chunkX := WorldWrapCoordinate(startChunkX+offsetX, chunksX)
		for offsetY in 0..<min(spanChunksY, chunksY) {
			chunkY := WorldWrapCoordinate(startChunkY+offsetY, chunksY)
			chunk := chunkX*chunksY+chunkY
			slot := w.spatial.unitHead[chunk]
			for slot >= 0 {
				next := w.spatial.unitNext[slot]
				unitSlot := slot
				slot = next
				if !w.unitUsed[unitSlot] do continue
				unitX := UnitTileX(w, unitSlot)
				unitY := UnitTileY(w, unitSlot)
				if unitX < x || unitX >= x+width || unitY < y || unitY >= y+height do continue
				exitX, exitY, found := UnitFindBuildingExit(w, unitSlot, x, y, width, height)
				if !found do return false
				if !relocate do continue
				unit := &w.units[unitSlot]
				// A displaced trainee must release its old entrance and job assignment.
				if _, converting := unit.state.(StateConverting); converting {
					UnitConversionCancel(w, unitSlot)
				}
				positionX, positionY := TileCenterPosition(exitX), TileCenterPosition(exitY)
				SetUnitPosition(w, unitSlot, positionX, positionY)
				unit.previousX, unit.previousY = positionX, positionY
				unit.pathReady = false
				if _, pacific := unit.state.(StatePacific); pacific {
					unit.state = StatePacific.Roaming
					unit.cooldown = d32.ZERO
				}
				SpatialUnitMove(w, unitSlot)
			}
		}
	}
	return true
}

TownBuilderConstruct :: proc(w: ^World, kingdomSlot, townSlot: int, canGrow: bool) -> bool {
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	startedAny := false
	// The street search walks the town twice, so run it at most once per call.
	pathChecked := false
	maxStarts := min(max(1, town.builders), TOWN_CONSTRUCTION_STARTS_PER_TICK)
	for _ in 0 ..< maxStarts {
		if TownConstructionCount(w, kingdomSlot, townSlot) >= TOWN_CONSTRUCTION_CAPACITY do break

		pendingFarmlands := TownConstructionKindCount(w, kingdomSlot, townSlot, .Farmland)
		if town.farmlands+pendingFarmlands < town.farmers {
			if TownBuilderStartBuilding(w, kingdomSlot, townSlot, Farmland{}) {
				startedAny = true
				continue
			}
		}

		if !pathChecked && TownConstructionKindCount(w, kingdomSlot, townSlot, .Path) == 0 {
			pathChecked = true
			if WorldCurrentTick(w) >= town.pathSearchFailUntilTick {
				if x, y, found := TownAutoPathSite(w, kingdomSlot, townSlot); found {
					if TownStartConstruction(w, kingdomSlot, townSlot, .Path, x, y) {
						startedAny = true
						continue
					}
				} else {
					town.pathSearchFailUntilTick = WorldCurrentTick(w)+TOWN_SITE_FAIL_TICKS
				}
			}
		}

		pendingHomes := TownConstructionKindCount(w, kingdomSlot, townSlot, .Home)
		if town.homes+pendingHomes < town.citizens ||
			(canGrow && town.homes+pendingHomes == town.citizens) {
			if TownBuilderStartBuilding(w, kingdomSlot, townSlot, Home{}) {
				startedAny = true
				continue
			}
		}

		if KingdomHasTech(w, kingdomSlot, .Harbor) && TownIsCoastal(w, kingdomSlot, townSlot) &&
			town.buildingCounts[.Harbor] == 0 &&
			TownConstructionKindCount(w, kingdomSlot, townSlot, .Harbor) == 0 {
			if TownBuilderStartBuilding(w, kingdomSlot, townSlot, BuildingTypeFromKind(.Harbor)) {
				startedAny = true
				continue
			}
		}
		if KingdomHasTech(w, kingdomSlot, .Granary) && town.buildingCounts[.Granary] == 0 &&
			TownConstructionKindCount(w, kingdomSlot, townSlot, .Granary) == 0 {
			if TownBuilderStartBuilding(w, kingdomSlot, townSlot, BuildingTypeFromKind(.Granary)) {
				startedAny = true
				continue
			}
		}

		startedTraining := false
		for kind in AUTO_TRAINING_BUILDINGS {
			if !(kind in town.unlockedBuildings) do continue
			if town.buildingCounts[kind] > 0 do continue
			if TownConstructionKindCount(w, kingdomSlot, townSlot, kind) > 0 do continue
			if TownBuilderStartBuilding(w, kingdomSlot, townSlot, BuildingTypeFromKind(kind)) {
				startedAny = true
				startedTraining = true
				break
			}
		}
		if startedTraining do continue

		if town.buildingCounts[.MagicSchool] > 0 &&
			town.buildingCounts[.AlchemistWorkshop] == 0 &&
			TownConstructionKindCount(w, kingdomSlot, townSlot, .AlchemistWorkshop) == 0 {
			if TownBuilderStartBuilding(w, kingdomSlot, townSlot, BuildingTypeFromKind(.AlchemistWorkshop)) {
				startedAny = true
				continue
			}
		}

		break
	}
	return startedAny
}

TownBuilderStartBuilding :: proc(w: ^World, kingdomSlot, townSlot: int, buildingType: BuildingType) -> bool {
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	kind := BuildingKindOf(buildingType)
	if !(kind in town.unlockedBuildings) do return false
	cost := d32.Mul(BuildingWoodCost(kind), KingdomTechBuildingKindCostMultiplier(w, kingdomSlot, kind))
	if town.wood < cost do return false

	if x, y, ok := TownTakePooledSite(w, kingdomSlot, townSlot, buildingType); ok {
		town.siteFailUntilTick[kind] = 0
		return TownStartConstruction(w, kingdomSlot, townSlot, kind, x, y)
	}
	if town.siteFailUntilTick[kind] > WorldCurrentTick(w) do return false

	x, y, found := TownFindBuildingSite(w, kingdomSlot, townSlot, buildingType)
	if !found {
		town.siteFailUntilTick[kind] = WorldCurrentTick(w)+TOWN_SITE_FAIL_TICKS
		return false
	}
	town.siteFailUntilTick[kind] = 0
	return TownStartConstruction(w, kingdomSlot, townSlot, kind, x, y)
}

TownSiteUsable :: proc(
	w: ^World,
	kingdomSlot, townSlot, x, y: int,
	buildingType: BuildingType,
) -> bool {
	width, height := BuildingTileSize(buildingType)
	if width <= 0 || height <= 0 do return false
	if !TownBuildingInArea(w, kingdomSlot, townSlot, x, y, buildingType) do return false
	if !TownBuildingValid(w, kingdomSlot, x, y, buildingType) do return false
	_, accessible := TownPlacementAccess(w, kingdomSlot, x, y, width, height)
	if !accessible do return false
	kind := BuildingKindOf(buildingType)
	if CombatSiteOverlaps(w, x, y, kind) do return false
	if TownConstructionSiteOverlaps(w, x, y, kind) do return false
	return true
}

TownTakePooledSite :: proc(
	w: ^World,
	kingdomSlot, townSlot: int,
	buildingType: BuildingType,
) -> (int, int, bool) {
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	kind := BuildingKindOf(buildingType)
	for index := 0; index < town.sitePoolCount; {
		candidate := town.sitePool[index]
		if candidate.kind != kind {
			index += 1
			continue
		}
		// Drop the entry before validating; it is stale if it no longer fits.
		town.sitePoolCount -= 1
		town.sitePool[index] = town.sitePool[town.sitePoolCount]
		if TownSiteUsable(w, kingdomSlot, townSlot, candidate.x, candidate.y, buildingType) {
			return candidate.x, candidate.y, true
		}
	}
	return 0, 0, false
}

// Orders a building: the town pays for it and gets a construction site that
// builders must clear and then raise.
TownStartConstruction :: proc(w: ^World, kingdomSlot, townSlot: int, kind: BuildingKind, x, y: int) -> bool {
	start := ProfileSectionBegin(.TownSiteStart)
	defer ProfileSectionEnd(.TownSiteStart, start)
	if !WorldTownExists(w, kingdomSlot, townSlot) do return false
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	slot := TownConstructionFreeSlot(w, kingdomSlot, townSlot)
	if slot < 0 do return false
	if !(kind in town.unlockedBuildings) do return false
	if BuildingIsCombat(kind) do return false
	if CombatSiteOverlaps(w, x, y, kind) do return false
	if TownConstructionSiteOverlaps(w, x, y, kind) do return false

	buildingType := BuildingTypeFromKind(kind)
	if !TownBuildingValid(w, kingdomSlot, x, y, buildingType) do return false
	cost := d32.Mul(BuildingWoodCost(kind), KingdomTechBuildingKindCostMultiplier(w, kingdomSlot, kind))
	if town.wood < cost do return false
	if !BuildingClearUnits(w, x, y, buildingType, false) do return false
	BuildingClearUnits(w, x, y, buildingType, true)

	town.wood = d32.Sub(town.wood, cost)
	town.constructions[slot] = ConstructionSite{
		active = true,
		kind = kind,
		x = x,
		y = y,
		paid = cost,
	}
	ConstructionBlockerTrack(w, kingdomSlot, townSlot, slot)
	WorldConstructionChanged(w)
	return true
}

// Cancels one active site, refunding its cost and releasing its builders.
TownConstructionCancel :: proc(w: ^World, kingdomSlot, townSlot, siteIndex: int) {
	if !WorldTownExists(w, kingdomSlot, townSlot) do return
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	if siteIndex < 0 || siteIndex >= TOWN_CONSTRUCTION_CAPACITY do return
	site := &town.constructions[siteIndex]
	if !site.active do return

	town.wood = d32.Add(town.wood, site.paid)
	settlers := site.settlers
	site^ = ConstructionSite{}
	ConstructionBlockerUntrack(w, kingdomSlot, townSlot, siteIndex)
	for _ in 0..<settlers do TownSpawnCitizen(w, kingdomSlot, townSlot, Villager{})
	WorldConstructionChanged(w)
}

// Frees the slot of the automatic site with the least work done.
TownConstructionCancelLeastProgress :: proc(w: ^World, kingdomSlot, townSlot: int) -> int {
	if !WorldTownExists(w, kingdomSlot, townSlot) do return -1
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	best := -1
	bestWork := d32.MAX
	for site, index in town.constructions {
		if !site.active || site.kind == .TownHall do continue
		work := d32.Add(site.clearWork, site.buildWork)
		if work < bestWork {
			bestWork = work
			best = index
		}
	}
	if best < 0 do return -1
	TownConstructionCancel(w, kingdomSlot, townSlot, best)
	return best
}

BuildingBuildSeconds :: proc(kind: BuildingKind) -> d32.Value {
	// Order infrastructure is deliberately slow to raise.
	if kind == .AlchemistWorkshop do return d32.FromInt(90)
	width, height := BuildingTileSize(BuildingTypeFromKind(kind))
	seconds := d32.Add(
		d32.FromInt(4),
		d32.Mul(d32.FromInt(i32(width*height)), d32.FromRatio(3, 2)),
	)
	seconds = d32.Add(seconds, d32.Mul(BuildingWoodCost(kind), d32.FromRatio(1, 4)))
	// Town halls are ordered by the player/AI; every other town building is
	// automatic infrastructure, so it comes up faster to keep the opening from
	// dragging.
	if kind != .TownHall do seconds = d32.Mul(seconds, d32.FromRatio(6, 10))
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
				decorationX := int(d32.ToInt(w.decorations.x[slot]))
				decorationY := int(d32.ToInt(w.decorations.y[slot]))
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
TownConstructionAccessPoint :: proc(
	w: ^World,
	unitSlot, kingdomSlot, townSlot, siteIndex: int,
) -> (int, int, bool) {
	if !WorldTownExists(w, kingdomSlot, townSlot) do return 0, 0, false
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	if siteIndex < 0 || siteIndex >= TOWN_CONSTRUCTION_CAPACITY do return 0, 0, false
	site := &town.constructions[siteIndex]
	if !site.active do return 0, 0, false

	unit := &w.units[unitSlot]
	if site.accessReady &&
		WorldTileWalkable(w, site.accessX, site.accessY, unit.type, unit.kingdome) {
		return site.accessX, site.accessY, true
	}

	width, height := BuildingTileSize(BuildingTypeFromKind(site.kind))
	x, y, found := BuildingFindWorkAccessPoint(
		w,
		site.x,
		site.y,
		width,
		height,
		unit.type,
		unit.kingdome,
		UnitTileX(w, unitSlot),
		UnitTileY(w, unitSlot),
	)
	if found {
		site.accessX, site.accessY, site.accessReady = x, y, true
	}
	return x, y, found
}

// Idle builders pick the site whose access point is closest to them. The failed
// slot is avoided once, so an unreachable site cannot trap a builder in a loop.
TownFindConstructionForBuilder :: proc(
	w: ^World,
	unitSlot, kingdomSlot, townSlot: int,
) -> (siteIndex: int, x, y: int, found: bool) {
	if !WorldTownExists(w, kingdomSlot, townSlot) do return
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	if unitSlot < 0 || unitSlot >= UNIT_CAPACITY || !w.unitUsed[unitSlot] do return
	unit := &w.units[unitSlot]
	if unit.type == nil || UnitKindOf(unit.type) != .Builder do return
	builder := &unit.type.(Builder)
	worldWidthRaw := i64(w.maxX)*d32.SCALE
	worldHeightRaw := i64(w.maxY)*d32.SCALE

	bestScore := ~u64(0)
	fallback := -1
	fallbackScore := ~u64(0)
	for site, index in town.constructions {
		if !site.active do continue
		width, height := BuildingTileSize(BuildingTypeFromKind(site.kind))
		centerX := d32.FromRaw(i32(i64(site.x)*d32.SCALE+i64(width)*(d32.SCALE/2)))
		centerY := d32.FromRaw(i32(i64(site.y)*d32.SCALE+i64(height)*(d32.SCALE/2)))
		score, valid := d32.WrappedDistanceSquared(
			unit.x,
			unit.y,
			centerX,
			centerY,
			worldWidthRaw,
			worldHeightRaw,
		)
		if !valid do continue
		if index == builder.failedConstruction {
			if score < fallbackScore {
				fallbackScore = score
				fallback = index
			}
			continue
		}
		if score < bestScore {
			bestScore = score
			siteIndex = index
			found = true
		}
	}
	if !found && fallback >= 0 {
		siteIndex = fallback
		found = true
	}
	if !found do return
	x, y, found = TownConstructionAccessPoint(w, unitSlot, kingdomSlot, townSlot, siteIndex)
	return
}

ConstructionProgress :: enum {
	Working,
	Completed,
}

TownConstructionMerge :: proc(w: ^World) {
	for wordIndex in 0..<len(pendingConstructionMask) {
		bits := pendingConstructionMask[wordIndex]
		pendingConstructionMask[wordIndex] = 0
		for bits != 0 {
			unitSlot := wordIndex*CONSTRUCTION_MASK_BITS+int(intrinsics.count_trailing_zeros(bits))
			bits &= bits-1
			entry := pendingConstruction[unitSlot]
			pendingConstruction[unitSlot] = {}
			switch entry.kind {
			case .None:
			case .Work:
				TownConstructionWork(w, entry.kingdom, entry.town, entry.site, entry.amount)
			case .Wood:
				if WorldTownExists(w, entry.kingdom, entry.town) {
					town := &w.kingdoms[entry.kingdom].towns[entry.town]
					town.wood = d32.Add(town.wood, entry.wood)
				}
			}
		}
	}
}

// Applies one builder's share of site work: clearing first, then raising.
// Called from the serial post-unit pass, never from workers.
TownConstructionWork :: proc(
	w: ^World,
	kingdomSlot, townSlot, siteIndex: int,
	work: d32.Value,
) -> ConstructionProgress {
	if !WorldTownExists(w, kingdomSlot, townSlot) do return .Completed
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	if siteIndex < 0 || siteIndex >= TOWN_CONSTRUCTION_CAPACITY do return .Completed
	site := &town.constructions[siteIndex]
	if !site.active do return .Completed
	slot := TownConstructionPendingDecoration(w, site^)
	if slot >= 0 {
		kind := w.decorations.kind[slot]
		site.clearWork = d32.Add(site.clearWork, work)
		if site.clearWork >= DecorationClearSeconds(kind) {
			town.wood = d32.Add(town.wood, DecorationWoodYield(kind))
			WorldDecorationDespawn(w, slot)
			site.clearWork = d32.ZERO
		}
		return .Working
	}

	buildSpeed := KingdomTechBuildSpeedMultiplier(w, kingdomSlot)
	if site.kind == .Path && KingdomHasTech(w, kingdomSlot, .Roadworks) {
		buildSpeed = d32.Mul(buildSpeed, d32.FromRatio(130, 100))
	}
	site.buildWork = d32.Add(site.buildWork, d32.Mul(work, buildSpeed))
	if site.buildWork < BuildingBuildSeconds(site.kind) do return .Working
	if !BuildingClearUnits(w, site.x, site.y, BuildingTypeFromKind(site.kind), false) do return .Working

	if site.kind == .TownHall {
		if !TownFound(w, kingdomSlot, site.x, site.y, site.settlers) {
			town.wood = d32.Add(town.wood, site.paid)
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
		town.wood = d32.Add(town.wood, site.paid)
	}
	site.active = false
	site^ = ConstructionSite{}
	ConstructionBlockerUntrack(w, kingdomSlot, townSlot, siteIndex)
	// Assigned builders notice the inactive slot on their next update.
	WorldConstructionChanged(w)
	return .Completed
}

TownPathTileKind :: enum {
	Blocked,
	Buildable,
	Road,
}

TownPathTile :: proc(w: ^World, kingdomSlot, townSlot, x, y: int) -> TownPathTileKind {
	if x < 0 || y < 0 || x >= int(w.maxX) || y >= int(w.maxY) do return .Blocked
	if !TownPointInArea(w, kingdomSlot, townSlot, x, y) do return .Blocked
	slot := w.tileBuilding[x*int(w.maxY)+y]
	if slot >= 0 {
		kind := BuildingKindOf(w.buildings[slot].type)
		if w.buildings.kingdom[slot] == kingdomSlot && w.buildings.town[slot] == townSlot &&
			(kind == .Path || kind == .Bridge) {
			return .Road
		}
		return .Blocked
	}
	for site in w.kingdoms[kingdomSlot].towns[townSlot].constructions {
		if site.active && site.kind == .Path && site.x == x && site.y == y do return .Road
	}
	if !WorldBuildingValid(w, x, y, Path{}) do return .Blocked
	if CombatSiteOverlaps(w, x, y, .Path) || TownConstructionSiteOverlaps(w, x, y, .Path) do return .Blocked
	return .Buildable
}

// Mark cardinal entrances only; a diagonal road does not provide street access.
TownMarkPathAccess :: proc(w: ^World, kingdomSlot, townSlot, x, y, width, height: int, networkStamp, goalStamp: u32) -> bool {
	worldWidth, worldHeight := int(w.maxX), int(w.maxY)
	marked := false
	for pass in 0..<2 {
		for tileX in x-1 ..= x+width {
			for tileY in y-1 ..= y+height {
				outsideX := tileX < x || tileX >= x+width
				outsideY := tileY < y || tileY >= y+height
				if outsideX == outsideY do continue
				wrappedX := WorldWrapCoordinate(tileX, worldWidth)
				wrappedY := WorldWrapCoordinate(tileY, worldHeight)
				index := wrappedX*worldHeight+wrappedY
				if pass == 0 {
					if w.navigationStamp[index] == networkStamp do return false
				} else if TownPathTile(w, kingdomSlot, townSlot, wrappedX, wrappedY) != .Blocked {
					w.navigationStamp[index] = goalStamp
					marked = true
				}
			}
		}
	}
	return marked
}

// Reuse connected streets, then find the shortest new branch to an entrance.
TownAutoPathSite :: proc(w: ^World, kingdomSlot, townSlot: int) -> (int, int, bool) {
	start := ProfileSectionBegin(.TownPathSite)
	defer ProfileSectionEnd(.TownPathSite, start)
	if !WorldTownExists(w, kingdomSlot, townSlot) do return 0, 0, false
	worldWidth, worldHeight := int(w.maxX), int(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 do return 0, 0, false
	if len(w.navigationQueue) < worldWidth*worldHeight do return 0, 0, false
	if w.navigationSearchId >= max(u32)-1 {
		for &stamp in w.navigationStamp do stamp = 0
		w.navigationSearchId = 0
	}
	w.navigationSearchId += 2
	networkStamp, goalStamp := w.navigationSearchId-1, w.navigationSearchId
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	hallWidth, hallHeight := BuildingTileSize(TownHall{})
	offsets := [4][2]int{{1, 0}, {0, 1}, {-1, 0}, {0, -1}}
	rotation := int(WorldNoiseHashInt(town.x, town.y, w.seed+0xBA7D))/250_000
	queueEnd := 0

	// Each district has a local street network rooted at its hall.
	for circle in 0..<TownAreaCircleCount(w, kingdomSlot, townSlot) {
		hallX, hallY, _ := TownAreaCircle(w, kingdomSlot, townSlot, circle)
		for x in hallX-1 ..= hallX+hallWidth {
			for y in hallY-1 ..= hallY+hallHeight {
				outsideX := x < hallX || x >= hallX+hallWidth
				outsideY := y < hallY || y >= hallY+hallHeight
				if outsideX == outsideY do continue
				wrappedX, wrappedY := WorldWrapCoordinate(x, worldWidth), WorldWrapCoordinate(y, worldHeight)
				index := wrappedX*worldHeight+wrappedY
				if w.navigationStamp[index] == networkStamp do continue
				if TownPathTile(w, kingdomSlot, townSlot, wrappedX, wrappedY) != .Road do continue
				w.navigationStamp[index] = networkStamp
				w.navigationCameFrom[index] = -1
				w.navigationQueue[queueEnd] = index
				queueEnd += 1
			}
		}
	}
	for cursor := 0; cursor < queueEnd; cursor += 1 {
		index := w.navigationQueue[cursor]
		for offset in offsets {
			x := WorldWrapCoordinate(index/worldHeight+offset[0], worldWidth)
			y := WorldWrapCoordinate(index%worldHeight+offset[1], worldHeight)
			next := x*worldHeight+y
			if w.navigationStamp[next] == networkStamp do continue
			if TownPathTile(w, kingdomSlot, townSlot, x, y) != .Road do continue
			w.navigationStamp[next] = networkStamp
			w.navigationCameFrom[next] = -1
			w.navigationQueue[queueEnd] = next
			queueEnd += 1
		}
	}

	hasTarget := false
	// Only the town's own buckets can hold its buildings.
	boundsMinX, boundsMaxX, boundsMinY, boundsMaxY := TownAreaBounds(w, kingdomSlot, townSlot)
	chunkSize := w.spatial.chunkSize
	chunksY := w.spatial.chunksY
	startChunkX := max(0, boundsMinX)/chunkSize
	endChunkX := min(max(boundsMaxX, 0), worldWidth-1)/chunkSize
	startChunkY := max(0, boundsMinY)/chunkSize
	endChunkY := min(max(boundsMaxY, 0), worldHeight-1)/chunkSize
	for chunkX in startChunkX..=endChunkX {
		for chunkY in startChunkY..=endChunkY {
			chunk := chunkX*chunksY+chunkY
			for slot := w.spatial.buildingHead[chunk]; slot >= 0;
				slot = w.spatial.buildingNext[slot] {
				if !w.buildingUsed[slot] || w.buildings.kingdom[slot] != kingdomSlot ||
					w.buildings.town[slot] != townSlot {
					continue
				}
				kind := BuildingKindOf(w.buildings.type[slot])
				if kind == .Path || kind == .Bridge || kind == .Wall || kind == .TownHall || kind == .DistrictHall {
					continue
				}
				width, height := BuildingTileSize(w.buildings.type[slot])
				if TownMarkPathAccess(
					w,
					kingdomSlot,
					townSlot,
					w.buildings.x[slot],
					w.buildings.y[slot],
					width,
					height,
					networkStamp,
					goalStamp,
				) {
					hasTarget = true
				}
			}
		}
	}
	for site in town.constructions {
		if !site.active || site.kind == .Path || site.kind == .TownHall do continue
		width, height := BuildingTileSize(BuildingTypeFromKind(site.kind))
		if TownMarkPathAccess(w, kingdomSlot, townSlot, site.x, site.y, width, height, networkStamp, goalStamp) do hasTarget = true
	}
	if !hasTarget do return 0, 0, false

	// Empty hall-side tiles become the first segment of a new street.
	for circle in 0..<TownAreaCircleCount(w, kingdomSlot, townSlot) {
		hallX, hallY, _ := TownAreaCircle(w, kingdomSlot, townSlot, circle)
		for x in hallX-1 ..= hallX+hallWidth {
			for y in hallY-1 ..= hallY+hallHeight {
				outsideX := x < hallX || x >= hallX+hallWidth
				outsideY := y < hallY || y >= hallY+hallHeight
				if outsideX == outsideY do continue
				wrappedX, wrappedY := WorldWrapCoordinate(x, worldWidth), WorldWrapCoordinate(y, worldHeight)
				index := wrappedX*worldHeight+wrappedY
				if w.navigationStamp[index] == networkStamp do continue
				if TownPathTile(w, kingdomSlot, townSlot, wrappedX, wrappedY) != .Buildable do continue
				if w.navigationStamp[index] == goalStamp do return wrappedX, wrappedY, true
				w.navigationStamp[index] = networkStamp
				w.navigationCameFrom[index] = index
				w.navigationQueue[queueEnd] = index
				queueEnd += 1
			}
		}
	}
	for cursor := 0; cursor < queueEnd; cursor += 1 {
		index := w.navigationQueue[cursor]
		for direction in 0..<4 {
			offset := offsets[(direction+rotation)%4]
			x := WorldWrapCoordinate(index/worldHeight+offset[0], worldWidth)
			y := WorldWrapCoordinate(index%worldHeight+offset[1], worldHeight)
			next := x*worldHeight+y
			if w.navigationStamp[next] == networkStamp do continue
			kind := TownPathTile(w, kingdomSlot, townSlot, x, y)
			if kind == .Blocked do continue
			firstMissing := w.navigationCameFrom[index]
			if firstMissing < 0 && kind == .Buildable do firstMissing = next
			if w.navigationStamp[next] == goalStamp && firstMissing >= 0 {
				return firstMissing/worldHeight, firstMissing%worldHeight, true
			}
			w.navigationStamp[next] = networkStamp
			w.navigationCameFrom[next] = firstMissing
			w.navigationQueue[queueEnd] = next
			queueEnd += 1
		}
	}
	return 0, 0, false
}

// Automatic construction also reserves its footprint, so a player cannot drop a
// combat site on top of a house that is already being raised. The compact list
// keeps this cheap: the old query walked every town's site array per tile.
ConstructionBlocker :: struct {
	x, y,          width, height: int,
}

ConstructionBlockerId :: #force_inline proc(kingdomSlot, townSlot, siteIndex: int) -> int {
	return (kingdomSlot*TOWN_CAPACITY+townSlot)*TOWN_CONSTRUCTION_CAPACITY+siteIndex
}

ConstructionBlockerTrack :: proc(w: ^World, kingdomSlot, townSlot, siteIndex: int) {
	if kingdomSlot < 0 || kingdomSlot >= KINGDOMS_CAPACITY do return
	if townSlot < 0 || townSlot >= TOWN_CAPACITY do return
	if siteIndex < 0 || siteIndex >= TOWN_CONSTRUCTION_CAPACITY do return
	site := w.kingdoms[kingdomSlot].towns[townSlot].constructions[siteIndex]
	width, height := BuildingTileSize(BuildingTypeFromKind(site.kind))

	id := ConstructionBlockerId(kingdomSlot, townSlot, siteIndex)
	w.constructionBlockers[id] = ConstructionBlocker {
		x      = site.x,
		y      = site.y,
		width  = width,
		height = height,
	}
	w.constructionBlockerPosition[id] = w.constructionBlockerCount
	w.constructionBlockerOrder[w.constructionBlockerCount] = id
	w.constructionBlockerCount += 1
	// Per-tile reservations keep overlap queries O(footprint) instead of O(sites).
	worldHeight := int(w.maxY)
	for tileX in site.x..<site.x+width {
		for tileY in site.y..<site.y+height {
			w.tileSiteBlocked[tileX*worldHeight+tileY] += 1
		}
	}
}

ConstructionBlockerUntrack :: proc(w: ^World, kingdomSlot, townSlot, siteIndex: int) {
	if kingdomSlot < 0 || kingdomSlot >= KINGDOMS_CAPACITY do return
	if townSlot < 0 || townSlot >= TOWN_CAPACITY do return
	if siteIndex < 0 || siteIndex >= TOWN_CONSTRUCTION_CAPACITY do return

	id := ConstructionBlockerId(kingdomSlot, townSlot, siteIndex)
	position := w.constructionBlockerPosition[id]
	if position < 0 || position >= w.constructionBlockerCount do return
	blocker := w.constructionBlockers[id]
	worldHeight := int(w.maxY)
	for tileX in blocker.x..<blocker.x+blocker.width {
		for tileY in blocker.y..<blocker.y+blocker.height {
			index := tileX*worldHeight+tileY
			if w.tileSiteBlocked[index] > 0 do w.tileSiteBlocked[index] -= 1
		}
	}
	last := w.constructionBlockerCount-1
	moved := w.constructionBlockerOrder[last]
	w.constructionBlockerOrder[position] = moved
	w.constructionBlockerPosition[moved] = position
	w.constructionBlockerPosition[id] = -1
	w.constructionBlockerCount = last
}

TownConstructionSiteOverlaps :: proc(w: ^World, x, y: int, kind: BuildingKind) -> bool {
	width, height := BuildingTileSize(BuildingTypeFromKind(kind))
	worldWidth, worldHeight := int(w.maxX), int(w.maxY)
	if x < 0 || y < 0 || x+width > worldWidth || y+height > worldHeight do return false
	for tileX in x..<x+width {
		for tileY in y..<y+height {
			if w.tileSiteBlocked[tileX*worldHeight+tileY] > 0 do return true
		}
	}
	return false
}

// Removing a town drops its sites without completing them, so the compact list
// has to forget their footprints too.
TownConstructionBlockersClear :: proc(w: ^World, kingdomSlot, townSlot: int) {
	for siteIndex in 0..<TOWN_CONSTRUCTION_CAPACITY {
		ConstructionBlockerUntrack(w, kingdomSlot, townSlot, siteIndex)
	}
}

BuildingValidTileTypeForKingdom :: proc(w: ^World, kingdom: int, bType: BuildingType, tType: TileType) -> bool {
	if KingdomHasTech(w, kingdom, .LandReclamation) {
		switch _ in bType {
		case Farmland:
			if tType == .Hill || tType == .Desert do return true
		case TownHall, Home, Wall, Bridge, Cannon, Watchtower, ArcheryRange, MagicSchool, GiantPen, SiegeWorkshop, TurtlePen, ThievesGuild, Path, DistrictHall, BuildingOrder, Granary:
		}
	}
	return BuildingValidTileType(bType, tType)
}

TownBuildingOverTile :: proc(w: ^World, kingdom, x, y: int, bType: BuildingType) -> bool {
	width, height := BuildingTileSize(bType)
	if x < 0 || y < 0 || width <= 0 || height <= 0 ||
		x+width > int(w.maxX) || y+height > int(w.maxY) {
		return false
	}
	for tileX in x..<x+width {
		for tileY in y..<y+height {
			if !BuildingValidTileTypeForKingdom(w, kingdom, bType, WorldTileAt(w, tileX, tileY).type) {
				return false
			}
		}
	}
	return true
}

TownBuildingValid :: proc(w: ^World, kingdom, x, y: int, bType: BuildingType) -> bool {
	return !WorldBuildingCollides(w, x, y, bType) && TownBuildingOverTile(w, kingdom, x, y, bType)
}

// A full scan evaluates thousands of tiles and checks every construction/
// combat site for each one. Sampling a few dozen candidates keeps placement
// varied while making the search orders of magnitude cheaper.
TOWN_BUILDING_SITE_SAMPLES :: 48
// The best of a few valid candidates is enough for a town layout; scoring all
// of them mostly repeats placement checks in dense areas.
TOWN_BUILDING_SITE_CANDIDATES :: 8

// Sample validation only reads the world, so the samples split cleanly across
// cores. The caller merges them in sample order, which keeps the result
// identical to a sequential scan.
TownSiteSample :: struct {
	x, y:  int,
	score: d32.Value,
	valid: bool,
}

TownSiteSearchJob :: struct {
	w:                ^World,
	kingdomSlot, townSlot: int,
	buildingType:     BuildingType,
	kind:             BuildingKind,
	seed:             u64,
	minX, minY:       int,
	spanX, spanY:     int,
	width, height:    int,
	samples:          []TownSiteSample,
}

TownSiteSampleRange :: proc(ctx: rawptr, start, end: int, worker: int) {
	job := cast(^TownSiteSearchJob)ctx
	town := &job.w.kingdoms[job.kingdomSlot].towns[job.townSlot]
	for index in start..<end {
		x := job.minX+WorldNoiseIndex(index, int(job.kind)+1, job.seed+0x51D, job.spanX)
		y := job.minY+WorldNoiseIndex(index, int(job.kind)+2, job.seed+0x51E, job.spanY)

		distanceX := max(max(town.x-x, 0), x-(town.x+3))
		distanceY := max(max(town.y-y, 0), y-(town.y+3))
		if max(distanceX, distanceY) < 2 do continue
		if !TownBuildingInArea(job.w, job.kingdomSlot, job.townSlot, x, y, job.buildingType) {
			continue
		}
		if !TownBuildingValid(job.w, job.kingdomSlot, x, y, job.buildingType) do continue
		access, accessible := TownPlacementAccess(job.w, job.kingdomSlot, x, y, job.width, job.height)
		if !accessible do continue
		if CombatSiteOverlaps(job.w, x, y, job.kind) do continue
		if TownConstructionSiteOverlaps(job.w, x, y, job.kind) do continue
		score := TownPlacementScore(
			job.w,
			job.kingdomSlot,
			job.townSlot,
			x,
			y,
			job.width,
			job.height,
			job.kind,
			job.seed,
		)
		job.samples[index] = TownSiteSample {
			x     = x,
			y     = y,
			score = d32.Add(
				score,
				d32.Mul(d32.FromInt(i32(min(access, 12))), d32.FromRatio(12, 100)),
			),
			valid = true,
		}
	}
}

TownFindBuildingSite :: proc(w: ^World, kingdomSlot, townSlot: int, buildingType: BuildingType) -> (int, int, bool) {
	start := ProfileSectionBegin(.TownSiteSearch)
	defer ProfileSectionEnd(.TownSiteSearch, start)
	if !WorldTownExists(w, kingdomSlot, townSlot) do return 0, 0, false
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	buildingWidth, buildingHeight := BuildingTileSize(buildingType)
	if buildingWidth <= 0 || buildingHeight <= 0 do return 0, 0, false

	kind := BuildingKindOf(buildingType)
	// Stable per town and building kind, without consuming the effects RNG.
	seed := w.seed ~ (u64(kingdomSlot*TOWN_CAPACITY+townSlot+1)*0x9E3779B97F4A7C15) ~
		(u64(kind)+1)*0xBF58476D1CE4E5B9
	areaMinX, areaMaxX, areaMinY, areaMaxY := TownAreaBounds(w, kingdomSlot, townSlot)
	minX := max(0, areaMinX)
	maxX := min(worldWidth-buildingWidth, areaMaxX)
	minY := max(0, areaMinY)
	maxY := min(worldHeight-buildingHeight, areaMaxY)
	if maxX < minX || maxY < minY do return 0, 0, false
	spanX := maxX-minX+1
	spanY := maxY-minY+1

	samples: [TOWN_BUILDING_SITE_SAMPLES]TownSiteSample
	job := TownSiteSearchJob {
		w             = w,
		kingdomSlot   = kingdomSlot,
		townSlot      = townSlot,
		buildingType  = buildingType,
		kind          = kind,
		seed          = seed,
		minX          = minX,
		minY          = minY,
		spanX         = spanX,
		spanY         = spanY,
		width         = buildingWidth,
		height        = buildingHeight,
		samples       = samples[:],
	}
	ParallelFor(TOWN_BUILDING_SITE_SAMPLES, &job, TownSiteSampleRange)

	bestX, bestY := 0, 0
	bestScore := d32.MIN
	found := false
	considered := 0
	for sample in samples {
		if !sample.valid do continue
		if !found || sample.score > bestScore {
			bestX, bestY, bestScore, found = sample.x, sample.y, sample.score, true
		}
		if town.sitePoolCount < TOWN_SITE_POOL_CAPACITY {
			town.sitePool[town.sitePoolCount] = TownSiteCandidate {
				kind = kind,
				x    = sample.x,
				y    = sample.y,
			}
			town.sitePoolCount += 1
		}
		considered += 1
		if considered >= TOWN_BUILDING_SITE_CANDIDATES do break
	}
	return bestX, bestY, found
}

// Reject isolated sites, but allow any walkable work point around the footprint.
TownPlacementAccess :: proc(w: ^World, kingdom, x, y, width, height: int) -> (int, bool) {
	worldWidth, worldHeight := int(w.maxX), int(w.maxY)
	for radius in 1..=6 {
		access := 0
		for tileX in x-radius ..= x+width-1+radius {
			for tileY in y-radius ..= y+height-1+radius {
				if tileX >= x-radius+1 && tileX <= x+width+radius-2 &&
					tileY >= y-radius+1 && tileY <= y+height+radius-2 {
					continue
				}
				wrappedX := WorldWrapCoordinate(tileX, worldWidth)
				wrappedY := WorldWrapCoordinate(tileY, worldHeight)
				if !WorldTileWalkableAt(w, wrappedX*worldHeight+wrappedY, Builder{}, kingdom, true) {
					continue
				}
				access += 1
			}
		}
		if access > 0 do return access, true
	}
	return 0, false
}

TownPlacementNeighborhood :: struct {
	touching, homes: int,
	nearestGapSquared: int,
	roadBonus: d32.Value,
}

TownPlacementConsiderNeighbor :: proc(x, y, width, height: int, kind: BuildingKind, otherX, otherY, otherWidth, otherHeight: int, otherKind: BuildingKind, neighborhood: ^TownPlacementNeighborhood) {
	gapX := max(0, max(otherX-x-width, x-otherX-otherWidth))
	gapY := max(0, max(otherY-y-height, y-otherY-otherHeight))
	gapSquared := gapX*gapX+gapY*gapY
	if gapSquared > 18 do return
	if otherKind == .Path || otherKind == .Bridge {
		frontage := (x < otherX+otherWidth && otherX < x+width) ||
			(y < otherY+otherHeight && otherY < y+height)
		bonus := d32.ZERO
		if frontage && gapSquared == 0 {
			bonus = kind == .Home ? d32.FromInt(8) : d32.FromRatio(25, 10)
		} else if frontage && gapSquared <= 1 {
			bonus = kind == .Home ? d32.FromInt(3) : d32.ONE
		} else if gapSquared <= 4 {
			bonus = d32.HALF
		}
		neighborhood.roadBonus = max(neighborhood.roadBonus, bonus)
		return
	}
	neighborhood.nearestGapSquared = min(neighborhood.nearestGapSquared, gapSquared)
	if gapSquared == 0 do neighborhood.touching += 1
	if otherKind == .Home && gapSquared <= 9 do neighborhood.homes += 1
}

TownPlacementScore :: proc(w: ^World, kingdomSlot, townSlot, x, y, width, height: int, kind: BuildingKind, seed: u64) -> d32.Value {
	centerX := d32.FromRaw(i32((i64(x)*2+i64(width))*d32.SCALE/2))
	centerY := d32.FromRaw(i32((i64(y)*2+i64(height))*d32.SCALE/2))
	worldWidthRaw := i64(w.maxX)*d32.SCALE
	worldHeightRaw := i64(w.maxY)*d32.SCALE
	nearestSquared := ~u64(0)
	for circle in 0..<TownAreaCircleCount(w, kingdomSlot, townSlot) {
		hallX, hallY, _ := TownAreaCircle(w, kingdomSlot, townSlot, circle)
		hallRawX := d32.FromInt(i32(hallX+2))
		hallRawY := d32.FromInt(i32(hallY+2))
		squared, valid := d32.WrappedDistanceSquared(
			centerX,
			centerY,
			hallRawX,
			hallRawY,
			worldWidthRaw,
			worldHeightRaw,
		)
		if valid && squared < nearestSquared do nearestSquared = squared
	}
	distance := d32.MAX
	if nearestSquared != ~u64(0) do distance = d32.FromRaw(i32(d32.SqrtRaw(nearestSquared)))
	hash := d32.FromRatio(i32(WorldNoiseHashInt(x, y, seed)), 1_000_000)
	// Streets shape neighborhoods more than distance from the hall does.
	score := d32.Sub(d32.Mul(hash, d32.FromRatio(3, 2)), d32.Mul(distance, d32.FromRatio(3, 10)))
	if kind == .Farmland {
		town := &w.kingdoms[kingdomSlot].towns[townSlot]
		radius := d32.Mul(d32.FromInt(i32(town.areaRadius)), d32.FromRatio(65, 100))
		deviation := d32.Abs(d32.Sub(distance, radius))
		score = d32.Sub(d32.Mul(hash, d32.FromRatio(3, 2)), d32.Mul(deviation, d32.FromRatio(3, 10)))
	}
	minX, maxX := max(0, x-3), min(int(w.maxX)-1, x+width+2)
	minY, maxY := max(0, y-3), min(int(w.maxY)-1, y+height+2)
	neighborhood := TownPlacementNeighborhood{nearestGapSquared = 18}
	for tileX in minX..=maxX {
		for tileY in minY..=maxY {
			slot := w.tileBuilding[tileX*int(w.maxY)+tileY]
			if slot < 0 do continue
			otherX, otherY := w.buildings.x[slot], w.buildings.y[slot]
			if tileX != max(minX, otherX) || tileY != max(minY, otherY) do continue
			otherWidth, otherHeight := BuildingTileSize(w.buildings[slot].type)
			TownPlacementConsiderNeighbor(x, y, width, height, kind, otherX, otherY, otherWidth, otherHeight,
				BuildingKindOf(w.buildings[slot].type), &neighborhood)
		}
	}
	for site in w.kingdoms[kingdomSlot].towns[townSlot].constructions {
		if !site.active do continue
		otherWidth, otherHeight := BuildingTileSize(BuildingTypeFromKind(site.kind))
		TownPlacementConsiderNeighbor(x, y, width, height, kind, site.x, site.y, otherWidth, otherHeight,
			site.kind, &neighborhood)
	}
	gapDistance := d32.FromRaw(i32(d32.SqrtRaw(u64(neighborhood.nearestGapSquared) << 32)))
	score = d32.Add(score, neighborhood.roadBonus)
	score = d32.Add(
		score,
		d32.Mul(max(d32.ZERO, d32.Sub(d32.FromInt(3), gapDistance)), d32.HALF),
	)
	if kind == .Farmland {
		score = d32.Sub(
			score,
			d32.Mul(d32.FromInt(i32(min(neighborhood.touching, 4))), d32.FromRatio(4, 10)),
		)
	} else {
		// Spacing is preferred, not mandatory on small islands or in dense towns.
		score = d32.Sub(
			score,
			d32.Mul(
				d32.FromInt(i32(min(neighborhood.touching, 4))),
				d32.FromInt(i32(kind == .Home ? 6 : 3)),
			),
		)
		if kind == .Home {
			bonus := d32.Mul(
				d32.FromInt(i32(min(neighborhood.homes, 3))),
				d32.FromRatio(45, 100),
			)
			crowding := d32.Mul(
				d32.FromInt(i32(max(0, neighborhood.homes-5))),
				d32.FromRatio(6, 10),
			)
			score = d32.Add(score, d32.Sub(bonus, crowding))
		}
	}
	fertility := d32.ZERO
	for tileX in x..<x+width {
		for tileY in y..<y+height {
			fertility = d32.Add(
				fertility,
				TILE_DEFS[WorldTileAt(w, tileX, tileY).type].food,
			)
		}
	}
	fertility = d32.Div(fertility, d32.FromInt(i32(max(width*height, 1))))
	if kind == .Farmland {
		score = d32.Add(score, d32.Mul(fertility, d32.FromInt(3)))
	} else {
		score = d32.Sub(score, d32.Mul(fertility, d32.FromRatio(8, 10)))
	}
	return score
}

BuildingFarmlandOutput :: proc(w: ^World, buildingSlot: int) -> d32.Value {
	x := w.buildings.x[buildingSlot]
	y := w.buildings.y[buildingSlot]
	width, height := BuildingTileSize(w.buildings[buildingSlot].type)
	fertility := d32.ZERO
	for tileX in x..<x+width {
		for tileY in y..<y+height {
			fertility = d32.Add(
				fertility,
				TILE_DEFS[WorldTileAt(w, tileX, tileY).type].food,
			)
		}
	}
	fertility = d32.Div(fertility, d32.FromInt(i32(max(width*height, 1))))
	minimum := d32.FromRatio(8, 100)
	output := d32.Add(minimum, d32.Mul(fertility, d32.FromRatio(8, 100)))
	// Cached once per terrain change.
	return clamp(output, minimum, d32.FromRatio(16, 100))
}
