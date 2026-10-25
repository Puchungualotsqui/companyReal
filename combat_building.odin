package main

COMBAT_SITE_CAPACITY :: 256

// Combat builders are almost harmless: they only lash out when something
// hostile happens to stand on top of them.
COMBAT_BUILDER_DEFEND_RADIUS :: 1.8
COMBAT_BUILDER_DEFEND_CHANCE :: 0.5
COMBAT_BUILDER_RESCAN_SECONDS :: 1.5

// A player-placed combat building. It costs no wood and can sit anywhere,
// including unreachable water. Builders re-evaluate it whenever navigation
// changes, so a bridge chain can creep across a lake one tile at a time.
CombatSite :: struct {
	kind: BuildingKind,
	x, y: int,
	work: f32,
	kingdom, town: int,
}

CombatBuildingSeconds :: proc(kind: BuildingKind) -> f32 {
	switch kind {
	case .Wall:
		return 2
	case .Bridge:
		return 5
	case .Watchtower:
		return 8
	case .Cannon:
		return 12
	case .TownHall, .Home, .Farmland, .ArcheryRange, .MagicSchool, .GiantPen, .SiegeWorkshop, .TurtlePen, .ThievesGuild, .Path, .DistrictHall:
		return 6
	}
	unreachable()
}

// Player order: place a combat building anywhere in the world. No wood is
// paid and no town area is required.
TownStartCombatConstruction :: proc(w: ^World, kingdomSlot, townSlot: int, kind: BuildingKind, x, y: int) -> bool {
	if TownCombatConstructionFailure(w, kingdomSlot, townSlot, kind, x, y) != .None do return false

	slot := -1
	for index in 0..<COMBAT_SITE_CAPACITY {
		if !w.combatSiteUsed[index] {
			slot = index
			break
		}
	}
	if slot < 0 do return false
	buildingType := BuildingTypeFromKind(kind)
	if !BuildingClearUnits(w, x, y, buildingType, false) do return false
	BuildingClearUnits(w, x, y, buildingType, true)

	w.combatSites[slot] = CombatSite{kind = kind, x = x, y = y, kingdom = kingdomSlot, town = townSlot}
	w.combatSiteUsed[slot] = true
	// Combat builders rescan on navigation changes; a new order is one.
	WorldConstructionChanged(w)
	return true
}

TownCombatConstructionFailure :: proc(w: ^World, kingdomSlot, townSlot: int, kind: BuildingKind, x, y: int) -> PlacementFailure {
	if !WorldTownExists(w, kingdomSlot, townSlot) do return .NoTown
	if !BuildingIsCombat(kind) do return .NotCombat
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	if !(kind in town.unlockedBuildings) do return .NotUnlocked
	if kingdomSlot == w.observerKingdom {
		width, height := BuildingTileSize(BuildingTypeFromKind(kind))
		if !FogRectExplored(w, x, y, width, height) do return .Unexplored
	}
	if !WorldBuildingValid(w, x, y, BuildingTypeFromKind(kind)) do return .InvalidTerrain
	if CombatSiteOverlaps(w, x, y, kind) do return .CombatSiteOverlap
	if TownConstructionSiteOverlaps(w, x, y, kind) do return .ConstructionOverlap
	return .None
}

CombatSiteOverlaps :: proc(w: ^World, x, y: int, kind: BuildingKind) -> bool {
	width, height := BuildingTileSize(BuildingTypeFromKind(kind))
	for slot in 0..<COMBAT_SITE_CAPACITY {
		if !w.combatSiteUsed[slot] do continue
		otherWidth, otherHeight := BuildingTileSize(BuildingTypeFromKind(w.combatSites.kind[slot]))
		if x < w.combatSites.x[slot]+otherWidth &&
			w.combatSites.x[slot] < x+width &&
			y < w.combatSites.y[slot]+otherHeight &&
			w.combatSites.y[slot] < y+height {
			return true
		}
	}
	return false
}

CombatSiteClear :: proc(w: ^World, kingdomSlot, townSlot: int) {
	changed := false
	for slot in 0..<COMBAT_SITE_CAPACITY {
		if !w.combatSiteUsed[slot] do continue
		if w.combatSites.kingdom[slot] != kingdomSlot || w.combatSites.town[slot] != townSlot {
			continue
		}
		w.combatSiteUsed[slot] = false
		changed = true
	}
	if changed do WorldConstructionChanged(w)
}

CombatSiteKingdomClear :: proc(w: ^World, kingdomSlot: int) {
	changed := false
	for slot in 0..<COMBAT_SITE_CAPACITY {
		if !w.combatSiteUsed[slot] || w.combatSites.kingdom[slot] != kingdomSlot do continue
		w.combatSiteUsed[slot] = false
		changed = true
	}
	if changed do WorldConstructionChanged(w)
}

// Builders work from any walkable tile on the ring around the footprint. An
// isolated bridge has no such tile until another bridge reaches it.
CombatSiteAccessPoint :: proc(w: ^World, siteSlot, unitSlot: int) -> (int, int, bool) {
	if siteSlot < 0 || siteSlot >= COMBAT_SITE_CAPACITY || !w.combatSiteUsed[siteSlot] {
		return 0, 0, false
	}

	site := &w.combatSites[siteSlot]
	width, height := BuildingTileSize(BuildingTypeFromKind(site.kind))
	unit := &w.units[unitSlot]
	return BuildingFindWorkAccessPoint(w, site.x, site.y, width, height, unit.type, unit.kingdome, int(unit.x), int(unit.y))
}

// Nearest reachable-looking site of the builder's town. The previous failure is
// skipped until navigation changes, which is when a new bridge may have made it
// reachable.
CombatSiteFindNearest :: proc(w: ^World, unitSlot: int, sequence: int, skipSlot: int, skipRevision: u64) -> (siteSlot, accessX, accessY: int, found: bool) {
	unit := &w.units[unitSlot]
	worldWidth := f32(w.maxX)
	worldHeight := f32(w.maxY)
	unitX := WorldWrapPosition(unit.x, worldWidth)
	unitY := WorldWrapPosition(unit.y, worldHeight)
	seed := u64(unitSlot+sequence*1013)

	bestDistance: f32 = 0
	bestScore: f32 = -1
	for slot in 0..<COMBAT_SITE_CAPACITY {
		if !w.combatSiteUsed[slot] do continue
		if w.combatSites.kingdom[slot] != unit.kingdome || w.combatSites.town[slot] != unit.town {
			continue
		}
		if slot == skipSlot && skipRevision == w.navigationRevision do continue

		x, y, ok := CombatSiteAccessPoint(w, slot, unitSlot)
		if !ok do continue

		siteWidth, siteHeight := BuildingTileSize(
			BuildingTypeFromKind(w.combatSites.kind[slot]),
		)
		centerX := f32(w.combatSites.x[slot])+f32(siteWidth)*0.5
		centerY := f32(w.combatSites.y[slot])+f32(siteHeight)*0.5
		deltaX := WorldShortestWrappedDelta(centerX-unitX, worldWidth)
		deltaY := WorldShortestWrappedDelta(centerY-unitY, worldHeight)
		distanceSquared := deltaX*deltaX+deltaY*deltaY
		score := WorldNoiseHash(slot, sequence, seed)
		if found && (distanceSquared > bestDistance ||
			(distanceSquared == bestDistance && score <= bestScore)) {
			continue
		}

		siteSlot = slot
		accessX = x
		accessY = y
		bestDistance = distanceSquared
		bestScore = score
		found = true
	}
	return
}

// Advances one builder's share of the site. Returns true when the structure is
// finished and the site can be released.
CombatSiteAdvance :: proc(w: ^World, siteSlot: int, deltaTime: f32) -> bool {
	if siteSlot < 0 || siteSlot >= COMBAT_SITE_CAPACITY || !w.combatSiteUsed[siteSlot] {
		return true
	}

	site := &w.combatSites[siteSlot]
	site.work += deltaTime
	if site.work < CombatBuildingSeconds(site.kind) do return false

	if _, ok := BuildingSpawn(
		w,
		site.x,
		site.y,
		BuildingTypeFromKind(site.kind),
		site.kingdom,
		site.town,
	); !ok {
		// Keep the order alive; another builder may finish it later.
		return false
	}
	w.combatSiteUsed[siteSlot] = false
	WorldConstructionChanged(w)
	return true
}

CombatBuilderUpdate :: proc(w: ^World, unitSlot: int, deltaTime: f32) {
	kingdomSlot := w.units[unitSlot].kingdome
	townSlot := w.units[unitSlot].town
	if !WorldTownExists(w, kingdomSlot, townSlot) do return

	builder := &w.units[unitSlot].type.(CombatBuilder)
	state := &w.units[unitSlot].state.(StatePacific)
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	if builder.orderKingdom != kingdomSlot || builder.orderTown != townSlot ||
		builder.orderRevision != town.orderRevision {
		switch previous in builder.order {
		case WarriorAttack:
			if !WorldTownExists(w, previous.kingdom, previous.town) ||
				!town.attackOrders[previous.kingdom][previous.town] {
				builder.returning = true
			}
		case WarriorDefend:
			if !WorldTownExists(w, previous.kingdom, previous.town) ||
				!town.defendOrders[previous.kingdom][previous.town] {
				builder.returning = true
			}
		case WarriorGarrison, WarriorIdle:
		}
		order := TownUnitOrder(w, unitSlot)
		if builder.returning do order = WarriorGarrison{}
		if !WarriorOrderEqual(builder.order, order) {
			builder.onStation = false
			builder.site = -1
			state^ = .Roaming
			w.units[unitSlot].pathReady = false
		}
		builder.order = order
		builder.orderKingdom = kingdomSlot
		builder.orderTown = townSlot
		builder.orderRevision = town.orderRevision
	}

	if builder.returning {
		if UnitWarriorTravel(w, unitSlot, kingdomSlot, townSlot, deltaTime) == .Arrived {
			builder.returning = false
			builder.orderKingdom = -1
			w.units[unitSlot].pathReady = false
		}
		return
	}
	if CombatBuilderDefend(w, unitSlot, deltaTime) do return

	switch order in builder.order {
	case WarriorAttack:
		if !builder.onStation {
			if UnitWarriorTravel(w, unitSlot, order.kingdom, order.town, deltaTime) != .Arrived do return
			builder.onStation = true
		}
		CombatBuilderPatrol(w, unitSlot, order.kingdom, order.town, deltaTime)
		return
	case WarriorDefend:
		if !builder.onStation {
			if UnitWarriorTravel(w, unitSlot, order.kingdom, order.town, deltaTime) != .Arrived do return
			builder.onStation = true
		}
		CombatBuilderPatrol(w, unitSlot, order.kingdom, order.town, deltaTime)
		return
	case WarriorGarrison, WarriorIdle:
	}

	if builder.site >= 0 && (builder.site >= COMBAT_SITE_CAPACITY || !w.combatSiteUsed[builder.site]) {
		builder.site = -1
		if state^ != .Roaming {
			state^ = .Roaming
			w.units[unitSlot].pathReady = false
		}
	}

	switch state^ {
	case .Roaming:
		if builder.scanTimer > 0 {
			builder.scanTimer -= deltaTime
			UnitUpdateRoaming(w, unitSlot, deltaTime)
			return
		}
		slot, accessX, accessY, found := CombatSiteFindNearest(
			w,
			unitSlot,
			builder.siteSequence,
			builder.failedSite,
			builder.failedRevision,
		)
		if !found {
			builder.scanTimer = COMBAT_BUILDER_RESCAN_SECONDS
			UnitUpdateRoaming(w, unitSlot, deltaTime)
			return
		}
		builder.site = slot
		w.units[unitSlot].pathTargetX = accessX
		w.units[unitSlot].pathTargetY = accessY
		w.units[unitSlot].pathReady = false
		state^ = .ToConstruction
	case .ToConstruction:
		if builder.site < 0 {
			state^ = .Roaming
			w.units[unitSlot].pathReady = false
			break
		}
		if UnitMoveToTarget(w, unitSlot, deltaTime) {
			state^ = .Building
			w.units[unitSlot].pathReady = false
		} else if !w.units[unitSlot].pathFound {
			// Unreachable for now: remember it until navigation changes.
			builder.failedSite = builder.site
			builder.failedRevision = w.navigationRevision
			builder.site = -1
			builder.siteSequence += 1
			state^ = .Roaming
			w.units[unitSlot].pathReady = false
		}
	case .Building:
		if builder.site < 0 {
			state^ = .Roaming
			w.units[unitSlot].pathReady = false
			break
		}
		if CombatSiteAdvance(w, builder.site, deltaTime) {
			builder.site = -1
			builder.failedSite = -1
			builder.scanTimer = 0
			state^ = .Roaming
			w.units[unitSlot].pathReady = false
		}
	case .GoingHome, .Sleeping, .Traveling, .Working, .Returning, .Hiding, .Fleeing:
		state^ = .Roaming
	}
}

CombatBuilderPatrol :: proc(w: ^World, unitSlot, kingdomSlot, townSlot: int, deltaTime: f32) {
	unit := &w.units[unitSlot]
	builder := &unit.type.(CombatBuilder)
	atTarget := int(WorldWrapPosition(unit.x, f32(w.maxX))) == unit.pathTargetX &&
		int(WorldWrapPosition(unit.y, f32(w.maxY))) == unit.pathTargetY
	if !unit.pathReady || atTarget {
		x, y, found := UnitFindPatrolTarget(w, unitSlot, kingdomSlot, townSlot,
			WARRIOR_DEFEND_PATROL_RADIUS, builder.patrolSequence)
		if !found do return
		unit.pathTargetX = x
		unit.pathTargetY = y
		unit.pathReady = true
		builder.patrolSequence += 1
	}
	speed := UnitDefaultSpeed(unit.type)
	if unit.effects[.NoWater] do speed *= 0.7
	reached, blocked, _ := UnitStepTowards(w, unitSlot,
		f32(unit.pathTargetX)+0.5, f32(unit.pathTargetY)+0.5, speed*deltaTime)
	if reached || blocked do unit.pathReady = false
}

// Combat builders never chase. If an enemy happens to be in reach they may
// swing once, then get back to work.
CombatBuilderDefend :: proc(w: ^World, unitSlot: int, deltaTime: f32) -> bool {
	unit := &w.units[unitSlot]
	if unit.cooldown > 0 {
		unit.cooldown -= deltaTime
		return false
	}

	roll := WorldNoiseHash(unitSlot, int(w.simulationTime*4), 0xC0B1)
	if roll >= COMBAT_BUILDER_DEFEND_CHANCE do return false

	target := CombatBuilderFindEnemy(w, unitSlot, COMBAT_BUILDER_DEFEND_RADIUS)
	if target < 0 do return false

	unit.cooldown = UnitDefaultCooldown(unit.type)
	UnitApplyDamage(w, target, UnitDefaultDamage(unit.type), unit.x, unit.y, .Melee)
	return true
}

CombatBuilderFindEnemy :: proc(w: ^World, unitSlot: int, radius: f32) -> int {
	unit := &w.units[unitSlot]
	builder := &unit.type.(CombatBuilder)
	combatState := StateWarrior{order = builder.order, retreating = builder.returning}
	worldWidth := f32(w.maxX)
	worldHeight := f32(w.maxY)
	chunkSize := w.spatial.chunkSize
	if chunkSize <= 0 || radius <= 0 do return -1

	centerChunkX := int(unit.x)/chunkSize
	centerChunkY := int(unit.y)/chunkSize
	chunkRadius := int(radius)/chunkSize+1
	bestSlot := -1
	bestDistance := radius*radius
	for offsetX in -chunkRadius..=chunkRadius {
		chunkX := WorldWrapCoordinate(centerChunkX+offsetX, w.spatial.chunksX)
		for offsetY in -chunkRadius..=chunkRadius {
			chunkY := WorldWrapCoordinate(centerChunkY+offsetY, w.spatial.chunksY)
			chunk := chunkX*w.spatial.chunksY+chunkY
			for otherSlot := w.spatial.unitHead[chunk]; otherSlot >= 0;
				otherSlot = w.spatial.unitNext[otherSlot] {
				if otherSlot == unitSlot do continue
				if !WarriorCanTargetUnit(w, unitSlot, &combatState, otherSlot) do continue
				deltaX := WorldShortestWrappedDelta(w.units.x[otherSlot]-unit.x, worldWidth)
				deltaY := WorldShortestWrappedDelta(w.units.y[otherSlot]-unit.y, worldHeight)
				distanceSquared := deltaX*deltaX+deltaY*deltaY
				if distanceSquared > bestDistance do continue
				bestDistance = distanceSquared
				bestSlot = otherSlot
			}
		}
	}
	return bestSlot
}


