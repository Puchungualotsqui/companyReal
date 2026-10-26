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
	for &blocked in w.tileConstructionBlocked do blocked = false
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
	centerX := f32(w.buildings.x[buildingSlot])+f32(width)*0.5
	centerY := f32(w.buildings.y[buildingSlot])+f32(height)*0.5
	WorldProjectileBurst(
		w,
		centerX,
		centerY,
		w.units.x[nearestSlot],
		w.units.y[nearestSlot],
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
	centerX := f32(w.buildings.x[buildingSlot])+f32(width)*0.5
	centerY := f32(w.buildings.y[buildingSlot])+f32(height)*0.5
	WorldProjectileBurst(
		w,
		centerX,
		centerY,
		w.units.x[nearestSlot],
		w.units.y[nearestSlot],
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
	startedAny := false
	maxStarts := min(max(1, town.builders), TOWN_CONSTRUCTION_CAPACITY)
	for _ in 0 ..< maxStarts {
		if TownConstructionCount(w, kingdomSlot, townSlot) >= TOWN_CONSTRUCTION_CAPACITY do break

		pendingFarmlands := TownConstructionKindCount(w, kingdomSlot, townSlot, .Farmland)
		if town.farmlands+pendingFarmlands < town.farmers {
			if TownBuilderStartBuilding(w, kingdomSlot, townSlot, Farmland{}) {
				startedAny = true
				continue
			}
		}

		if TownConstructionKindCount(w, kingdomSlot, townSlot, .Path) == 0 {
			if x, y, found := TownAutoPathSite(w, kingdomSlot, townSlot); found {
				if TownStartConstruction(w, kingdomSlot, townSlot, .Path, x, y) {
					startedAny = true
					continue
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
	cost := BuildingWoodCost(kind)*KingdomTechBuildingKindCostMultiplier(w, kingdomSlot, kind)
	if town.wood < cost do return false
	x, y, found := TownFindBuildingSite(w, kingdomSlot, townSlot, buildingType)
	if !found do return false
	return TownStartConstruction(w, kingdomSlot, townSlot, kind, x, y)
}

// Orders a building: the town pays for it and gets a construction site that
// builders must clear and then raise.
TownStartConstruction :: proc(w: ^World, kingdomSlot, townSlot: int, kind: BuildingKind, x, y: int) -> bool {
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
	cost := BuildingWoodCost(kind)*KingdomTechBuildingKindCostMultiplier(w, kingdomSlot, kind)
	if town.wood < cost do return false
	if !BuildingClearUnits(w, x, y, buildingType, false) do return false
	BuildingClearUnits(w, x, y, buildingType, true)

	town.wood -= cost
	town.constructions[slot] = ConstructionSite{
		active = true,
		kind = kind,
		x = x,
		y = y,
		paid = cost,
	}
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

	town.wood += site.paid
	settlers := site.settlers
	site^ = ConstructionSite{}
	TownConstructionResetBuilders(w, kingdomSlot, townSlot, siteIndex)
	for _ in 0..<settlers do TownSpawnCitizen(w, kingdomSlot, townSlot, Villager{})
	WorldConstructionChanged(w)
}

// Frees the slot of the automatic site with the least work done.
TownConstructionCancelLeastProgress :: proc(w: ^World, kingdomSlot, townSlot: int) -> int {
	if !WorldTownExists(w, kingdomSlot, townSlot) do return -1
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	best := -1
	bestWork: f32 = 1e30
	for site, index in town.constructions {
		if !site.active || site.kind == .TownHall do continue
		work := site.clearWork+site.buildWork
		if work < bestWork {
			bestWork = work
			best = index
		}
	}
	if best < 0 do return -1
	TownConstructionCancel(w, kingdomSlot, townSlot, best)
	return best
}

// Builders remember slot indices, so clear stale assignments whenever a slot is
// completed or cancelled. Slot indices themselves stay stable.
TownConstructionResetBuilders :: proc(w: ^World, kingdomSlot, townSlot, siteIndex: int) {
	for unitSlot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[unitSlot] do continue
		unit := &w.units[unitSlot]
		if unit.kingdome != kingdomSlot || unit.town != townSlot do continue
		if unit.type == nil || UnitKindOf(unit.type) != .Builder do continue
		if _, converting := unit.state.(StateConverting); converting do continue
		builder := &unit.type.(Builder)
		if builder.failedConstruction == siteIndex do builder.failedConstruction = -1
		if builder.constructionSite != siteIndex do continue

		builder.constructionSite = -1
		if state, pacific := &unit.state.(StatePacific); pacific {
			if state^ == .ToConstruction || state^ == .Building {
				state^ = .Roaming
				unit.pathReady = false
			}
		}
	}
}

BuildingBuildSeconds :: proc(kind: BuildingKind) -> f32 {
	// Order infrastructure is deliberately slow to raise.
	if kind == .AlchemistWorkshop do return 90
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
TownConstructionAccessPoint :: proc(
	w: ^World,
	unitSlot, kingdomSlot, townSlot, siteIndex: int,
) -> (int, int, bool) {
	if !WorldTownExists(w, kingdomSlot, townSlot) do return 0, 0, false
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	if siteIndex < 0 || siteIndex >= TOWN_CONSTRUCTION_CAPACITY do return 0, 0, false
	site := town.constructions[siteIndex]
	if !site.active do return 0, 0, false

	width, height := BuildingTileSize(BuildingTypeFromKind(site.kind))
	unit := &w.units[unitSlot]
	return BuildingFindWorkAccessPoint(w, site.x, site.y, width, height, unit.type, unit.kingdome, int(unit.x), int(unit.y))
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
	worldWidth := f32(w.maxX)
	worldHeight := f32(w.maxY)

	bestScore: f32 = 1e30
	fallback := -1
	fallbackScore: f32 = 1e30
	for site, index in town.constructions {
		if !site.active do continue
		accessX, accessY, ok := TownConstructionAccessPoint(w, unitSlot, kingdomSlot, townSlot, index)
		if !ok do continue
		deltaX := WorldShortestWrappedDelta(f32(accessX)+0.5-unit.x, worldWidth)
		deltaY := WorldShortestWrappedDelta(f32(accessY)+0.5-unit.y, worldHeight)
		score := deltaX*deltaX+deltaY*deltaY
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
			x = accessX
			y = accessY
			found = true
		}
	}
	if !found && fallback >= 0 {
		x, y, found = TownConstructionAccessPoint(w, unitSlot, kingdomSlot, townSlot, fallback)
		siteIndex = fallback
	}
	return
}

ConstructionProgress :: enum {
	Working,
	Completed,
}

// Advances one builder's share of site work: clearing first, then raising.
TownConstructionWork :: proc(
	w: ^World,
	kingdomSlot, townSlot, siteIndex: int,
	deltaTime: f32,
) -> ConstructionProgress {
	if !WorldTownExists(w, kingdomSlot, townSlot) do return .Completed
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	if siteIndex < 0 || siteIndex >= TOWN_CONSTRUCTION_CAPACITY do return .Completed
	site := &town.constructions[siteIndex]
	if !site.active do return .Completed
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

	buildSpeed := KingdomTechBuildSpeedMultiplier(w, kingdomSlot)
	if site.kind == .Path && KingdomHasTech(w, kingdomSlot, .Roadworks) do buildSpeed *= 1.30
	site.buildWork += deltaTime*buildSpeed
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
	site.active = false
	site^ = ConstructionSite{}
	TownConstructionResetBuilders(w, kingdomSlot, townSlot, siteIndex)
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
	rotation := int(WorldNoiseHash(town.x, town.y, w.seed+0xBA7D)*4)
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
	for slot in 0..<BUILDING_CAPACITY {
		if !w.buildingUsed[slot] || w.buildings.kingdom[slot] != kingdomSlot || w.buildings.town[slot] != townSlot do continue
		kind := BuildingKindOf(w.buildings[slot].type)
		if kind == .Path || kind == .Bridge || kind == .Wall || kind == .TownHall || kind == .DistrictHall do continue
		width, height := BuildingTileSize(w.buildings[slot].type)
		if TownMarkPathAccess(w, kingdomSlot, townSlot, w.buildings.x[slot], w.buildings.y[slot], width, height, networkStamp, goalStamp) do hasTarget = true
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
// combat site on top of a house that is already being raised.
TownConstructionSiteOverlaps :: proc(w: ^World, x, y: int, kind: BuildingKind) -> bool {
	width, height := BuildingTileSize(BuildingTypeFromKind(kind))
	for kingdomSlot in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[kingdomSlot] do continue
		for townSlot in 0..<TOWN_CAPACITY {
			if !w.kingdoms[kingdomSlot].townUsed[townSlot] do continue
			town := &w.kingdoms[kingdomSlot].towns[townSlot]
			for site in town.constructions {
				if !site.active do continue
				otherWidth, otherHeight := BuildingTileSize(BuildingTypeFromKind(site.kind))
				if x < site.x+otherWidth && site.x < x+width &&
					y < site.y+otherHeight && site.y < y+height {
					return true
				}
			}
		}
	}
	return false
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
			if !BuildingValidTileTypeForKingdom(w, kingdom, bType, w.ground[tileX][tileY].type) {
				return false
			}
		}
	}
	return true
}

TownBuildingValid :: proc(w: ^World, kingdom, x, y: int, bType: BuildingType) -> bool {
	return !WorldBuildingCollides(w, x, y, bType) && TownBuildingOverTile(w, kingdom, x, y, bType)
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
			if !TownBuildingValid(w, kingdomSlot, x, y, buildingType) do continue
			access, accessible := TownPlacementAccess(w, field, kingdomSlot, x, y, buildingWidth, buildingHeight)
			if !accessible do continue
			score := TownPlacementScore(w, kingdomSlot, townSlot, x, y, buildingWidth, buildingHeight, kind, seed)
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

TownPlacementNeighborhood :: struct {
	touching, homes: int,
	nearestGapSquared: int,
	roadBonus: f32,
}

TownPlacementConsiderNeighbor :: proc(x, y, width, height: int, kind: BuildingKind, otherX, otherY, otherWidth, otherHeight: int, otherKind: BuildingKind, neighborhood: ^TownPlacementNeighborhood) {
	gapX := max(0, max(otherX-x-width, x-otherX-otherWidth))
	gapY := max(0, max(otherY-y-height, y-otherY-otherHeight))
	gapSquared := gapX*gapX+gapY*gapY
	if gapSquared > 18 do return
	if otherKind == .Path || otherKind == .Bridge {
		frontage := (x < otherX+otherWidth && otherX < x+width) ||
			(y < otherY+otherHeight && otherY < y+height)
		bonus: f32 = 0
		if frontage && gapSquared == 0 {
			bonus = kind == .Home ? 8 : 2.5
		} else if frontage && gapSquared <= 1 {
			bonus = kind == .Home ? 3 : 1
		} else if gapSquared <= 4 {
			bonus = 0.5
		}
		neighborhood.roadBonus = max(neighborhood.roadBonus, bonus)
		return
	}
	neighborhood.nearestGapSquared = min(neighborhood.nearestGapSquared, gapSquared)
	if gapSquared == 0 do neighborhood.touching += 1
	if otherKind == .Home && gapSquared <= 9 do neighborhood.homes += 1
}

TownPlacementScore :: proc(w: ^World, kingdomSlot, townSlot, x, y, width, height: int, kind: BuildingKind, seed: u64) -> f32 {
	centerX, centerY := f32(x)+f32(width)*0.5, f32(y)+f32(height)*0.5
	distance: f32 = 1e20
	for circle in 0..<TownAreaCircleCount(w, kingdomSlot, townSlot) {
		hallX, hallY, _ := TownAreaCircle(w, kingdomSlot, townSlot, circle)
		dx, dy := centerX-f32(hallX+2), centerY-f32(hallY+2)
		distance = min(distance, math.sqrt(dx*dx+dy*dy))
	}
	// Streets shape neighborhoods more than distance from the hall does.
	score := WorldNoiseHash(x, y, seed)*1.5-distance*0.3
	if kind == .Farmland {
		town := &w.kingdoms[kingdomSlot].towns[townSlot]
		score = WorldNoiseHash(x, y, seed)*1.5-math.abs(distance-f32(town.areaRadius)*0.65)*0.3
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
	score += neighborhood.roadBonus+max(0, 3-math.sqrt(f32(neighborhood.nearestGapSquared)))*0.5
	if kind == .Farmland {
		score -= f32(min(neighborhood.touching, 4))*0.4
	} else {
		// Spacing is preferred, not mandatory on small islands or in dense towns.
		score -= f32(min(neighborhood.touching, 4))*(kind == .Home ? 6 : 3)
		if kind == .Home {
			score += f32(min(neighborhood.homes, 3))*0.45-f32(max(0, neighborhood.homes-5))*0.6
		}
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
