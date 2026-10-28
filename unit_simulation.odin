package main


// Pacific units drop their work to fight a fire burning inside their town.
UnitTryExtinguish :: proc(w: ^World, unitSlot: int, deltaTime: f32) -> bool {
	unit := &w.units[unitSlot]
	rate := UnitExtinguishRate(unit.type)
	if rate <= 0 do return false
	if w.fireCount == 0 do return false
	if !WorldTownExists(w, unit.kingdome, unit.town) do return false

	fireSlot := -1
	bestDistanceSquared: f32 = 0
	worldWidth := f32(w.maxX)
	worldHeight := f32(w.maxY)
	for slot in 0 ..< FIRE_CAPACITY {
		if !w.fireUsed[slot] do continue
		if !TownPointInArea(w, unit.kingdome, unit.town, int(w.fires.x[slot]), int(w.fires.y[slot])) {
			continue
		}
		deltaX := WorldShortestWrappedDelta(w.fires.x[slot]-unit.x, worldWidth)
		deltaY := WorldShortestWrappedDelta(w.fires.y[slot]-unit.y, worldHeight)
		distanceSquared := deltaX*deltaX+deltaY*deltaY
		if fireSlot >= 0 && distanceSquared >= bestDistanceSquared do continue
		fireSlot = slot
		bestDistanceSquared = distanceSquared
	}
	if fireSlot < 0 do return false

	// A fire is an emergency: abandon whatever task is in progress.
	if state, ok := unit.state.(StatePacific); ok && state != .Roaming {
		unit.state = StatePacific.Roaming
		unit.pathReady = false
	}

	if bestDistanceSquared <= FIRE_EXTINGUISH_RADIUS*FIRE_EXTINGUISH_RADIUS {
		w.fires.remaining[fireSlot] -= rate*deltaTime
		if w.fires.remaining[fireSlot] <= 0 do WorldFireDespawn(w, fireSlot)
		unit.pathReady = false
		return true
	}

	targetX, targetY, found := FireAccessPoint(
		w,
		int(w.fires.x[fireSlot]),
		int(w.fires.y[fireSlot]),
		unit.type,
		unit.kingdome,
	)
	if !found do return false
	if !unit.pathReady || unit.pathTargetX != targetX || unit.pathTargetY != targetY {
		unit.pathTargetX = targetX
		unit.pathTargetY = targetY
		unit.pathReady = false
	}
	UnitMoveToTarget(w, unitSlot, deltaTime)
	return true
}

UnitUpdateVillager :: proc(w: ^World, unitSlot: int, deltaTime: f32) {
	kingdomSlot := w.units[unitSlot].kingdome
	townSlot := w.units[unitSlot].town
	if !WorldTownExists(w, kingdomSlot, townSlot) do return
	w.kingdoms[kingdomSlot].towns[townSlot].villagers += 1
	if UnitUpdatePacificSleep(w, unitSlot, deltaTime) do return
	if UnitTryExtinguish(w, unitSlot, deltaTime) do return
	UnitUpdateRoaming(w, unitSlot, deltaTime)
}

EXPLORER_TRIPS_BEFORE_REST :: 3
EXPLORER_REST_MIN :: 14
EXPLORER_REST_MAX :: 24
EXPLORER_SEARCH_ATTEMPTS :: 96
EXPLORER_SEARCH_SPAN :: 140
EXPLORER_SEARCH_MIN_DISTANCE :: 14

// The explorer is a civilian. It travels toward unexplored tiles, comes back
// to rest at its town for a while, then leaves on another journey.
UnitUpdateExplorer :: proc(w: ^World, unitSlot: int, deltaTime: f32) {
	kingdomSlot := w.units[unitSlot].kingdome
	townSlot := w.units[unitSlot].town
	if !WorldTownExists(w, kingdomSlot, townSlot) do return
	if UnitUpdatePacificSleep(w, unitSlot, deltaTime) do return

	unit := &w.units[unitSlot]
	explorer := &unit.type.(Explorer)
	state := &unit.state.(StatePacific)

	switch state^ {
	case .Working:
		explorer.restTimer -= deltaTime
		if explorer.restTimer <= 0 {
			explorer.tripsLeft = EXPLORER_TRIPS_BEFORE_REST
			state^ = .Roaming
			unit.pathReady = false
		}
	case .Returning:
		if UnitMoveToTarget(w, unitSlot, deltaTime) || !unit.pathFound {
			explorer.restTimer = EXPLORER_REST_MIN+
				WorldNoiseHash(unitSlot, explorer.journey, 0xE8A1)*(EXPLORER_REST_MAX-EXPLORER_REST_MIN)
			state^ = .Working
			unit.pathReady = false
		}
	case .Roaming:
		if explorer.tripsLeft <= 0 {
			if x, y, found := UnitFindTownReturnPoint(w, kingdomSlot, townSlot); found {
				unit.pathTargetX = x
				unit.pathTargetY = y
				unit.pathReady = false
				state^ = .Returning
			} else {
				explorer.restTimer = EXPLORER_REST_MIN
				state^ = .Working
			}
			return
		}

		if x, y, found := UnitFindExplorationTarget(w, unitSlot, explorer.journey); found {
			unit.pathTargetX = x
			unit.pathTargetY = y
			unit.pathReady = false
			explorer.tripsLeft -= 1
			explorer.journey += 1
			state^ = .Traveling
		} else {
			explorer.tripsLeft = 0
		}
	case .Traveling:
		if UnitMoveToTarget(w, unitSlot, deltaTime) || !unit.pathFound {
			state^ = .Roaming
			unit.pathReady = false
		}
	case .ToConstruction, .Building, .GoingHome, .Sleeping, .Hiding, .Fleeing:
		state^ = .Roaming
		unit.pathReady = false
	}
}

// Picks a walkable target in the surrounding fog. Non-player explorers have no
// fog view model of their own, so they wander to distant random tiles instead.
UnitFindExplorationTarget :: proc(w: ^World, unitSlot, journey: int) -> (int, int, bool) {
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 do return 0, 0, false

	unitX := int(WorldWrapPosition(w.units.x[unitSlot], f32(worldWidth)))
	unitY := int(WorldWrapPosition(w.units.y[unitSlot], f32(worldHeight)))
	unitType := w.units[unitSlot].type
	isPlayer := w.observerKingdom >= 0 && w.units[unitSlot].kingdome == w.observerKingdom
	minDistanceSquared := EXPLORER_SEARCH_MIN_DISTANCE*EXPLORER_SEARCH_MIN_DISTANCE
	seed := u64(unitSlot)+u64(journey)*7919

	for attempt in 0..<EXPLORER_SEARCH_ATTEMPTS {
		deltaX := int(WorldNoiseHash(unitSlot, journey*31+attempt*2, seed+11)*f32(EXPLORER_SEARCH_SPAN))-
			EXPLORER_SEARCH_SPAN/2
		deltaY := int(WorldNoiseHash(unitSlot, journey*31+attempt*2+1, seed+23)*f32(EXPLORER_SEARCH_SPAN))-
			EXPLORER_SEARCH_SPAN/2
		if deltaX*deltaX+deltaY*deltaY < minDistanceSquared do continue

		x := WorldWrapCoordinate(unitX+deltaX, worldWidth)
		y := WorldWrapCoordinate(unitY+deltaY, worldHeight)
		if !UnitValidTileType(unitType, w.ground[x][y].type) do continue
		if WorldTileOccupied(w, x, y) do continue
		if isPlayer && FogTileExplored(w, x, y) do continue
		return x, y, true
	}
	return 0, 0, false
}

UnitUpdateBuilder :: proc(w: ^World, unitSlot: int, deltaTime: f32) {
	kingdomSlot := w.units[unitSlot].kingdome
	townSlot := w.units[unitSlot].town
	if !WorldTownExists(w, kingdomSlot, townSlot) do return
	if UnitUpdatePacificSleep(w, unitSlot, deltaTime) do return
	if UnitTryExtinguish(w, unitSlot, deltaTime) do return

	builder := &w.units[unitSlot].type.(Builder)
	state := &w.units[unitSlot].state.(StatePacific)
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	// Builders gathering wood are still available to switch to a construction
	// site, so the town plans with the whole awake builder workforce.
	town.builders += 1
	if state^ == .Roaming && builder.carriedResource > 0 {
		if x, y, found := UnitFindTownReturnPoint(w, kingdomSlot, townSlot); found {
			w.units[unitSlot].pathTargetX = x
			w.units[unitSlot].pathTargetY = y
			w.units[unitSlot].pathReady = false
			state^ = .Returning
		}
	}
	if state^ == .Roaming && TownConstructionCount(w, kingdomSlot, townSlot) > 0 {
		if site, x, y, found := TownFindConstructionForBuilder(w, unitSlot, kingdomSlot, townSlot); found {
			builder.constructionSite = site
			w.units[unitSlot].pathTargetX = x
			w.units[unitSlot].pathTargetY = y
			w.units[unitSlot].pathReady = false
			state^ = .ToConstruction
		}
	}
	if state^ == .Roaming && town.wood < TownWoodGatherTarget(w, kingdomSlot, townSlot) {
		if x, y, decoration, found := UnitFindResourceTarget(w, unitSlot, builder.taskSequence); found {
			builder.targetDecoration = decoration
			w.units[unitSlot].pathTargetX = x
			w.units[unitSlot].pathTargetY = y
			w.units[unitSlot].pathReady = false
			state^ = .Traveling
		}
	}

	switch state^ {
	case .Roaming:
		UnitUpdateRoaming(w, unitSlot, deltaTime)
	case .Traveling:
		if UnitMoveToTarget(w, unitSlot, deltaTime) {
			if builder.targetDecoration >= 0 && builder.targetDecoration < DECORATION_CAPACITY &&
				w.decorationUsed[builder.targetDecoration] &&
				DecorationChoppable(w.decorations.kind[builder.targetDecoration]) {
				state^ = .Working
				w.units[unitSlot].cooldown = DecorationChopSeconds(
					w.decorations.kind[builder.targetDecoration],
				)
			} else {
				builder.targetDecoration = -1
				state^ = .Roaming
				w.units[unitSlot].pathReady = false
				builder.taskSequence += 1
			}
		} else if !w.units[unitSlot].pathFound {
			state^ = .Roaming
			w.units[unitSlot].pathReady = false
			builder.targetDecoration = -1
			builder.taskSequence += 1
		}
	case .Working:
		if builder.targetDecoration < 0 || builder.targetDecoration >= DECORATION_CAPACITY ||
			!w.decorationUsed[builder.targetDecoration] {
			builder.targetDecoration = -1
			state^ = .Roaming
			w.units[unitSlot].pathReady = false
			builder.taskSequence += 1
			break
		}

		w.units[unitSlot].cooldown -= deltaTime
		if w.units[unitSlot].cooldown <= 0 {
			carried := DecorationWoodYield(w.decorations.kind[builder.targetDecoration])
			DecorationFell(w, builder.targetDecoration)
			builder.targetDecoration = -1
			if carried > 0 {
				builder.carriedResource = carried
				if x, y, found := UnitFindTownReturnPoint(w, kingdomSlot, townSlot); found {
					w.units[unitSlot].pathTargetX = x
					w.units[unitSlot].pathTargetY = y
					w.units[unitSlot].pathReady = false
					state^ = .Returning
				} else {
					builder.carriedResource = 0
					state^ = .Roaming
				}
			} else {
				state^ = .Roaming
				builder.taskSequence += 1
			}
		}
	case .Returning:
		if UnitMoveToTarget(w, unitSlot, deltaTime) {
			town.wood += builder.carriedResource*KingdomTechWoodMultiplier(w, kingdomSlot)
			builder.carriedResource = 0
			builder.targetDecoration = -1
			builder.taskSequence += 1
			state^ = .Roaming
			w.units[unitSlot].pathReady = false
		} else if !w.units[unitSlot].pathFound {
			builder.carriedResource = 0
			builder.targetDecoration = -1
			builder.taskSequence += 1
			state^ = .Roaming
			w.units[unitSlot].pathReady = false
		}
	case .ToConstruction:
		if builder.constructionSite < 0 || builder.constructionSite >= TOWN_CONSTRUCTION_CAPACITY ||
			!town.constructions[builder.constructionSite].active {
			builder.constructionSite = -1
			state^ = .Roaming
			w.units[unitSlot].pathReady = false
			builder.taskSequence += 1
			break
		}
		if UnitMoveToTarget(w, unitSlot, deltaTime) {
			builder.failedConstruction = -1
			state^ = .Building
			w.units[unitSlot].pathReady = false
		} else if !w.units[unitSlot].pathFound {
			builder.failedConstruction = builder.constructionSite
			builder.constructionSite = -1
			state^ = .Roaming
			w.units[unitSlot].pathReady = false
			builder.taskSequence += 1
		}
	case .Building:
		if builder.constructionSite < 0 || builder.constructionSite >= TOWN_CONSTRUCTION_CAPACITY ||
			!town.constructions[builder.constructionSite].active {
			builder.constructionSite = -1
			state^ = .Roaming
			w.units[unitSlot].pathReady = false
			builder.taskSequence += 1
			break
		}
		if TownConstructionWork(w, kingdomSlot, townSlot, builder.constructionSite, deltaTime) == .Completed {
			builder.constructionSite = -1
			state^ = .Roaming
			w.units[unitSlot].pathReady = false
			builder.taskSequence += 1
		}
	case .GoingHome, .Sleeping, .Hiding, .Fleeing:
		}
	}

UnitUpdateWaterCollector :: proc(w: ^World, unitSlot: int, deltaTime: f32) {
	unit := &w.units[unitSlot]
	kingdomSlot := unit.kingdome
	townSlot := unit.town
	collector := &unit.type.(WaterCollector)
	state := &unit.state.(StatePacific)

	if !WorldTownExists(w, kingdomSlot, townSlot) do return
	w.kingdoms[kingdomSlot].towns[townSlot].waterCollectors += 1
	if UnitUpdatePacificSleep(w, unitSlot, deltaTime) do return
	if UnitTryExtinguish(w, unitSlot, deltaTime) do return

	if state^ == .Roaming {
		if collector.carriedResource > 0 {
			if w.units[unitSlot].cooldown > 0 {
				w.units[unitSlot].cooldown = max(0, w.units[unitSlot].cooldown-deltaTime)
				return
			}
			if x, y, found := UnitFindTownReturnPoint(w, kingdomSlot, townSlot, unitSlot); found {
				w.units[unitSlot].pathTargetX = x
				w.units[unitSlot].pathTargetY = y
				w.units[unitSlot].pathReady = false
				state^ = .Returning
			} else {
				// Keep the load, but do not search or start roaming paths every tick.
				w.units[unitSlot].cooldown = 5
				w.units[unitSlot].pathReady = false
				return
			}
		} else if w.units[unitSlot].cooldown > 0 {
			w.units[unitSlot].cooldown -= deltaTime
		} else {
			if x, y, found := UnitFindWaterTarget(w, unitSlot, collector.taskSequence); found {
				w.units[unitSlot].pathTargetX = x
				w.units[unitSlot].pathTargetY = y
				w.units[unitSlot].pathReady = false
				state^ = .Traveling
			} else {
				w.units[unitSlot].cooldown = 5
			}
		}
	}

	switch state^ {
	case .Roaming:
		UnitUpdateRoaming(w, unitSlot, deltaTime)
	case .Traveling:
		if UnitMove(w, unitSlot, unit.pathTargetX, unit.pathTargetY, deltaTime) {
			state^ = .Working
			unit.pathReady = false
			w.units[unitSlot].cooldown = f32(WORLD_DAY_LENGTH_SECONDS)/48
		} else if !w.units[unitSlot].pathFound {
			state^ = .Roaming
			w.units[unitSlot].pathReady = false
			collector.taskSequence += 1
		}
	case .Working:
		w.units[unitSlot].cooldown -= deltaTime
		if w.units[unitSlot].cooldown <= 0 {
			collector.carriedResource = 1
			if x, y, found := UnitFindTownReturnPoint(w, kingdomSlot, townSlot, unitSlot); found {
				w.units[unitSlot].pathTargetX = x
				w.units[unitSlot].pathTargetY = y
				w.units[unitSlot].pathReady = false
				state^ = .Returning
			} else {
				collector.carriedResource = 0
				state^ = .Roaming
			}
		}
	case .Returning:
		reached := UnitMove(w, unitSlot, unit.pathTargetX, unit.pathTargetY, deltaTime)
		if reached || !w.units[unitSlot].pathFound {
			collector.carriedResource = 0
			collector.taskSequence += 1
			state^ = .Roaming
			w.units[unitSlot].cooldown = 0
			w.units[unitSlot].pathReady = false
		}
	case .GoingHome, .Sleeping, .ToConstruction, .Building, .Hiding, .Fleeing:
	}
}

UnitUpdateFarmer :: proc(w: ^World, unitSlot: int, deltaTime: f32) {
	kingdomSlot := w.units[unitSlot].kingdome
	townSlot := w.units[unitSlot].town
	if !WorldTownExists(w, kingdomSlot, townSlot) do return

	farmer := &w.units[unitSlot].type.(Farmer)
	if farmer.workDay != w.dayNumber {
		farmer.workDay = w.dayNumber
		farmer.workedToday = false
	}
	w.kingdoms[kingdomSlot].towns[townSlot].farmers += 1
	if UnitUpdatePacificSleep(w, unitSlot, deltaTime) do return
	if UnitTryExtinguish(w, unitSlot, deltaTime) do return

	state := &w.units[unitSlot].state.(StatePacific)
	if state^ == .Roaming && !farmer.workedToday {
		if w.units[unitSlot].cooldown > 0 {
			w.units[unitSlot].cooldown -= deltaTime
		} else if x, y, found := UnitFindFarmlandTarget(w, unitSlot, farmer.workDay); found {
			w.units[unitSlot].pathTargetX = x
			w.units[unitSlot].pathTargetY = y
			w.units[unitSlot].pathReady = false
			state^ = .Traveling
		} else {
			w.units[unitSlot].cooldown = 5
		}
	}

	switch state^ {
	case .Roaming:
		UnitUpdateRoaming(w, unitSlot, deltaTime)
	case .Traveling:
		if UnitMoveToTarget(w, unitSlot, deltaTime) {
			state^ = .Working
			w.units[unitSlot].cooldown = f32(WORLD_DAY_LENGTH_SECONDS)/24
		} else if !w.units[unitSlot].pathFound {
			state^ = .Roaming
			w.units[unitSlot].pathReady = false
			w.units[unitSlot].cooldown = 5
		}
	case .Working:
		w.units[unitSlot].cooldown -= deltaTime
		if w.units[unitSlot].cooldown <= 0 {
			farmer.workedToday = true
			state^ = .Roaming
			w.units[unitSlot].pathReady = false
		}
	case .Returning:
		state^ = .Roaming
	case .GoingHome, .Sleeping, .ToConstruction, .Building, .Hiding, .Fleeing:
		}
	}

	UnitUpdateConverting :: proc(w: ^World, unitSlot: int, deltaTime: f32) {
	if unitSlot < 0 || unitSlot >= UNIT_CAPACITY || !w.unitUsed[unitSlot] do return
	if _, converting := w.units[unitSlot].state.(StateConverting); !converting do return
	state := &w.units[unitSlot].state.(StateConverting)
	unit := &w.units[unitSlot]

	if !WorldTownExists(w, unit.kingdome, unit.town) {
		UnitConversionCancel(w, unitSlot)
		return
	}
	if state.building < 0 || state.building >= BUILDING_CAPACITY ||
		!w.buildingUsed[state.building] ||
		BuildingKindOf(w.buildings[state.building].type) != UnitTrainingBuildingKind(state.to) {
		UnitConversionCancel(w, unitSlot)
		return
	}

	if state.inside {
		SpatialUnitRemove(w, unitSlot)
		state.timer -= deltaTime
		if state.timer <= 0 do UnitConvert(w, unitSlot)
		return
	}

	if !WorldTileWalkable(w, state.accessX, state.accessY, unit.type, unit.kingdome) {
		width, height := BuildingTileSize(w.buildings[state.building].type)
		x, y, found := BuildingFindWorkAccessPoint(
			w,
			w.buildings.x[state.building],
			w.buildings.y[state.building],
			width,
			height,
			unit.type,
			unit.kingdome,
			int(WorldWrapPosition(unit.x, f32(w.maxX))),
			int(WorldWrapPosition(unit.y, f32(w.maxY))),
		)
		if !found {
			UnitConversionCancel(w, unitSlot)
			return
		}
		state.accessX, state.accessY = x, y
		state.retryTimer = 0
		unit.pathReady = false
	}
	if state.retryTimer > 0 {
		state.retryTimer -= deltaTime
		return
	}

	if unit.pathTargetX != state.accessX || unit.pathTargetY != state.accessY {
		unit.pathTargetX = state.accessX
		unit.pathTargetY = state.accessY
		unit.pathReady = false
	}
	if UnitMoveToTarget(w, unitSlot, deltaTime) {
		state.inside = true
		SpatialUnitRemove(w, unitSlot)
		state.timer = UnitDefaultTrainingTime(state.to) / KingdomTechConversionSpeedMultiplier(w, unit.kingdome, state.to)
		unit.pathReady = false
	} else if !unit.pathFound {
		unit.pathReady = false
		state.retryTimer = 1
	}
}

UnitConvert :: proc(w: ^World, unitSlot: int) {
	if unitSlot < 0 || unitSlot >= UNIT_CAPACITY || !w.unitUsed[unitSlot] do return
	unit := &w.units[unitSlot]
	if _, converting := unit.state.(StateConverting); !converting do return
	state := unit.state.(StateConverting)
	from := UnitKindOf(unit.type)
	to := state.to

	if WorldTownExists(w, unit.kingdome, unit.town) {
		town := &w.kingdoms[unit.kingdome].towns[unit.town]
		for jobIndex in 0..<town.conversionCount {
			job := &town.conversions[jobIndex]
			if job.from != from || job.to != to do continue
			job.assigned = max(0, job.assigned-1)
			job.remaining = max(0, job.remaining-1)
			if job.remaining <= 0 {
				for i in jobIndex..<town.conversionCount-1 {
					town.conversions[i] = town.conversions[i+1]
				}
				town.conversionCount -= 1
			}
			break
		}
	}

	UnitSetType(w, unitSlot, to)
}

UnitConversionCancel :: proc(w: ^World, unitSlot: int) {
	if unitSlot < 0 || unitSlot >= UNIT_CAPACITY || !w.unitUsed[unitSlot] do return
	unit := &w.units[unitSlot]
	if _, converting := unit.state.(StateConverting); !converting do return
	state := unit.state.(StateConverting)
	from := UnitKindOf(unit.type)

	if WorldTownExists(w, unit.kingdome, unit.town) {
		town := &w.kingdoms[unit.kingdome].towns[unit.town]
		for jobIndex in 0..<town.conversionCount {
			job := &town.conversions[jobIndex]
			if job.from != from || job.to != state.to do continue
			job.assigned = max(0, job.assigned-1)
			break
		}
	}

	if state.inside do SpatialUnitMove(w, unitSlot)
	if UnitIsWarrior(unit.type) {
		unit.state = StateWarriorInit(unitSlot, unit.kingdome, unit.town)
	} else {
		unit.state = StatePacific.Roaming
	}
	unit.pathReady = false
}

UnitResetState :: proc(w: ^World, unitSlot: int) {
	if unitSlot < 0 || unitSlot >= UNIT_CAPACITY || !w.unitUsed[unitSlot] do return
	UnitSleepWake(w, unitSlot)
	switch _ in w.units[unitSlot].state {
	case StateConverting:
		UnitConversionCancel(w, unitSlot)
	case StateWarrior:
		UnitWarriorReset(w, unitSlot)
	case StatePacific:
	}
}

// The assignment reserves capacity even while its citizen is awake or travelling.
UnitHome :: proc(w: ^World, unitSlot: int) -> int {
	if unitSlot < 0 || unitSlot >= UNIT_CAPACITY || !w.unitUsed[unitSlot] do return -1
	unit := &w.units[unitSlot]
	home := unit.homeSlot
	if home < 0 || home >= BUILDING_CAPACITY || !w.buildingUsed[home] do return -1
	building := &w.buildings[home]
	if BuildingKindOf(building.type) != .Home || building.health <= 0 ||
		building.homeResident != unitSlot+1 || building.kingdom != unit.kingdome ||
		building.town != unit.town || !WorldTownExists(w, unit.kingdome, unit.town) {
		return -1
	}
	return home
}

// Indoor residents keep safe exterior coordinates, not positions inside walls.
UnitInsideHome :: proc(w: ^World, unitSlot: int) -> int {
	home := UnitHome(w, unitSlot)
	if home < 0 do return -1
	unit := &w.units[unitSlot]
	state, pacific := unit.state.(StatePacific)
	if !pacific || (state != .Sleeping && state != .Hiding) || !unit.sleepInside ||
		UnitIsWarrior(unit.type) || UnitKindOf(unit.type) == .CombatBuilder {
		return -1
	}
	x := int(WorldWrapPosition(unit.x, f32(w.maxX)))
	y := int(WorldWrapPosition(unit.y, f32(w.maxY)))
	width, height := BuildingTileSize(w.buildings[home].type)
	if BuildingAccessDistance(w, w.buildings.x[home], w.buildings.y[home], width, height, x, y) != 1 ||
		!WorldTileWalkable(w, x, y, unit.type, unit.kingdome) {
		return -1
	}
	return home
}

UnitSleepingHome :: proc(w: ^World, unitSlot: int) -> int {
	home := UnitInsideHome(w, unitSlot)
	if home < 0 do return -1
	if w.units[unitSlot].state.(StatePacific) != .Sleeping do return -1
	return home
}

// Shared rendering, targeting, selection, and fog eligibility check.
UnitHiddenInside :: proc(w: ^World, unitSlot: int) -> bool {
	if unitSlot < 0 || unitSlot >= UNIT_CAPACITY || !w.unitUsed[unitSlot] do return false
	if state, converting := w.units[unitSlot].state.(StateConverting); converting && state.inside do return true
	return UnitInsideHome(w, unitSlot) >= 0
}

UnitSleepWake :: proc(w: ^World, unitSlot: int) {
	if unitSlot < 0 || unitSlot >= UNIT_CAPACITY || !w.unitUsed[unitSlot] do return
	unit := &w.units[unitSlot]
	if unit.sleepInside {
		unit.sleepInside = false
		// Move also relinks an absent unit, without duplicating an existing link.
		SpatialUnitMove(w, unitSlot)
	}
	if state, pacific := unit.state.(StatePacific); pacific &&
		(state == .Sleeping || state == .GoingHome || state == .Hiding || state == .Fleeing) {
		unit.state = StatePacific.Roaming
		unit.pathReady = false
	}
}

UnitReleaseHome :: proc(w: ^World, unitSlot: int) {
	if unitSlot < 0 || unitSlot >= UNIT_CAPACITY || !w.unitUsed[unitSlot] do return
	home := w.units.homeSlot[unitSlot]
	if home < 0 do return
	UnitSleepWake(w, unitSlot)
	if home < BUILDING_CAPACITY && w.buildings.homeResident[home] == unitSlot+1 {
		w.buildings.homeResident[home] = 0
	}
	w.units.homeSlot[unitSlot] = -1
}

UnitUpdateMilitaryAlarm :: proc(w: ^World, unitSlot: int) {
	unit := &w.units[unitSlot]
	if !WorldTownExists(w, unit.kingdome, unit.town) do return
	if !w.kingdoms[unit.kingdome].towns[unit.town].alarmActive do return
	state, pacific := unit.state.(StatePacific)
	if !pacific do return
	if UnitIsWarrior(unit.type) {
		UnitSleepWake(w, unitSlot)
		UnitWarriorReset(w, unitSlot)
	} else if UnitKindOf(unit.type) == .CombatBuilder &&
		(state == .Sleeping || state == .GoingHome || state == .Hiding) {
		UnitSleepWake(w, unitSlot)
	}
}

// Emergency shelter/fleeing takes precedence over work, fire-fighting and sleep.
UnitUpdatePacificSafety :: proc(w: ^World, unitSlot: int, deltaTime: f32) -> bool {
	unit := &w.units[unitSlot]
	if UnitIsWarrior(unit.type) || UnitKindOf(unit.type) == .CombatBuilder do return false
	if state, converting := unit.state.(StateConverting); converting && state.inside do return false
	if UnitHome(w, unitSlot) < 0 do UnitReleaseHome(w, unitSlot)
	if unit.sleepInside && UnitInsideHome(w, unitSlot) < 0 do UnitSleepWake(w, unitSlot)
	alarm := WorldTownExists(w, unit.kingdome, unit.town) &&
		w.kingdoms[unit.kingdome].towns[unit.town].alarmActive
	enemy := UnitFindNearbyEnemy(w, unitSlot, FLEE_THREAT_RADIUS)
	if !alarm && enemy < 0 {
		if state, pacific := unit.state.(StatePacific); pacific {
			if state == .Hiding {
				hour := WorldTimeOfDay(w)
				if hour < 6 || hour >= 22+unit.sleepOffsetHours {
					unit.state = StatePacific.Sleeping
				} else {
					UnitSleepWake(w, unitSlot)
				}
			} else if state == .Fleeing {
				UnitSleepWake(w, unitSlot)
			}
		}
		return false
	}
	if _, converting := unit.state.(StateConverting); converting do UnitConversionCancel(w, unitSlot)
	state := &unit.state.(StatePacific)
	if UnitInsideHome(w, unitSlot) >= 0 {
		state^ = .Hiding
		return true
	}
	home := UnitHome(w, unitSlot)
	failedHome := (state^ == .Fleeing || state^ == .Sleeping) &&
		unit.sleepNavigationRevision == w.navigationRevision
	if home >= 0 && !failedHome {
		if state^ != .GoingHome {
			unit.pathReady = false
			if x, y, found := UnitFindHomeTarget(w, unitSlot); found {
				unit.pathTargetX, unit.pathTargetY = x, y
				state^ = .GoingHome
			} else {
				unit.sleepNavigationRevision = w.navigationRevision
			}
		}
		if state^ == .GoingHome {
			if UnitMove(w, unitSlot, unit.pathTargetX, unit.pathTargetY, deltaTime) {
				state^ = .Hiding
				unit.pathReady = false
				unit.sleepInside = true
				if UnitInsideHome(w, unitSlot) >= 0 {
					SpatialUnitRemove(w, unitSlot)
					return true
				}
				UnitSleepWake(w, unitSlot)
			} else if unit.pathFound {
				return true
			}
			// Losing one entrance does not make the entire home unreachable.
			unit.pathReady = false
			if x, y, found := UnitFindHomeTarget(w, unitSlot); found {
				unit.pathTargetX, unit.pathTargetY = x, y
				state^ = .GoingHome
				return true
			}
			unit.sleepNavigationRevision = w.navigationRevision
		}
	}
	if state^ != .Fleeing {
		UnitSleepWake(w, unitSlot)
		state^ = .Fleeing
		unit.pathReady = false
	}
	if enemy >= 0 do UnitFleeEnemy(w, unitSlot, enemy, deltaTime)
	return true
}

UnitUpdatePacificSleep :: proc(w: ^World, unitSlot: int, deltaTime: f32) -> bool {
	if unitSlot < 0 || unitSlot >= UNIT_CAPACITY || !w.unitUsed[unitSlot] do return false
	unit := &w.units[unitSlot]
	_, pacific := unit.state.(StatePacific)
	if !pacific || UnitIsWarrior(unit.type) || UnitKindOf(unit.type) == .CombatBuilder do return false
	if UnitHome(w, unitSlot) < 0 do UnitReleaseHome(w, unitSlot)
	if unit.sleepInside && UnitInsideHome(w, unitSlot) < 0 do UnitSleepWake(w, unitSlot)
	if UnitUpdatePacificSafety(w, unitSlot, deltaTime) do return true
	hour := WorldTimeOfDay(w)
	if hour >= 6 && hour < 22+unit.sleepOffsetHours {
		UnitSleepWake(w, unitSlot)
		return false
	}

	state := &unit.state.(StatePacific)
	if state^ == .Sleeping {
		if unit.sleepInside || UnitHome(w, unitSlot) < 0 ||
			unit.sleepNavigationRevision == w.navigationRevision {
			return true
		}
		// An outdoor sleeper retries an inaccessible Home only after the map changes.
		state^ = .Roaming
	}
	if state^ != .GoingHome {
		if x, y, found := UnitFindHomeTarget(w, unitSlot); found {
			unit.pathTargetX, unit.pathTargetY = x, y
			unit.pathReady = false
			state^ = .GoingHome
		} else {
			state^ = .Sleeping
			unit.pathReady = false
			unit.sleepNavigationRevision = w.navigationRevision
			return true
		}
	}
	if UnitMoveToTarget(w, unitSlot, deltaTime) {
		state^ = .Sleeping
		unit.pathReady = false
		unit.sleepInside = true
		if UnitSleepingHome(w, unitSlot) >= 0 {
			SpatialUnitRemove(w, unitSlot)
		} else {
			unit.sleepInside = false
		}
	} else if !unit.pathFound {
		state^ = .Sleeping
		unit.pathReady = false
		unit.sleepNavigationRevision = w.navigationRevision
	}
	return true
}

// Civilian roaming stays a little beyond the town's buildable area instead of
// drifting across the map.
TOWN_ROAM_AREA_FACTOR :: 1.25

UnitUpdateRoaming :: proc(w: ^World, unitSlot: int, deltaTime: f32) {
	unit := &w.units[unitSlot]
	atTarget := int(WorldWrapPosition(unit.x, f32(w.maxX))) == unit.pathTargetX &&
		int(WorldWrapPosition(unit.y, f32(w.maxY))) == unit.pathTargetY
	if !unit.pathReady || atTarget {
		if x, y, found := UnitFindRoamingTarget(w, unitSlot, unit.roamSequence); found {
			unit.pathTargetX = x
			unit.pathTargetY = y
			unit.pathReady = false
			unit.roamSequence += 1
		} else {
			return
		}
	}

	if UnitMoveToTarget(w, unitSlot, deltaTime) || !unit.pathFound {
		unit.pathReady = false
	}
}

UnitApplyTownEffects :: proc(w: ^World, unitSlot: int, housed: bool, shortageEpoch: int, deltaTime: f32) {
	kingdomSlot := w.units[unitSlot].kingdome
	townSlot := w.units[unitSlot].town
	unitType := w.units[unitSlot].type
	w.units[unitSlot].effects[.NoHome] = !housed
	w.units[unitSlot].effects[.NoFood] = false
	w.units[unitSlot].effects[.NoWater] = false
	w.units[unitSlot].effects[.Poisoned] = false
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	seed := u64(kingdomSlot*TOWN_CAPACITY+townSlot)
	foodRoll := WorldNoiseHash(unitSlot, shortageEpoch, seed+301)
	waterRoll := WorldNoiseHash(unitSlot, shortageEpoch, seed+607)
	w.units[unitSlot].effects[.NoFood] = foodRoll < town.foodShortage
	w.units[unitSlot].effects[.NoWater] = waterRoll < town.waterShortage

	regen: f32 = 0.25
	if !w.units[unitSlot].effects[.NoHome] do regen = 1
	if w.units[unitSlot].poisonRemaining > 0 do regen = 0
	w.units[unitSlot].health = min(UnitMaxHealth(w, unitSlot), w.units[unitSlot].health+regen*deltaTime)
}

UnitClearTownEffects :: proc(w: ^World, unitSlot: int) {
	w.units[unitSlot].effects[.NoHome] = true
	w.units[unitSlot].effects[.NoWater] = false
	w.units[unitSlot].effects[.NoFood] = false
	w.units[unitSlot].effects[.Poisoned] = false
}

UnitFindRoamingTarget :: proc(w: ^World, unitSlot, sequence: int) -> (int, int, bool) {
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 do return 0, 0, false
	unit := &w.units[unitSlot]
	if !WorldTownExists(w, unit.kingdome, unit.town) do return 0, 0, false

	circleCount := TownAreaCircleCount(w, unit.kingdome, unit.town)
	if circleCount <= 0 do return 0, 0, false
	seed := u64(unitSlot)+u64(sequence)*101
	circleIndex := int(WorldNoiseHash(unitSlot, sequence*31+7, seed+5)*f32(circleCount))
	circleIndex = clamp(circleIndex, 0, circleCount-1)
	circleX, circleY, circleRadius := TownAreaCircle(
		w,
		unit.kingdome,
		unit.town,
		circleIndex,
	)
	radius := int(f32(circleRadius)*TOWN_ROAM_AREA_FACTOR)
	if radius <= 0 do return 0, 0, false

	hallWidth, hallHeight := BuildingTileSize(TownHall{})
	centerX := circleX+hallWidth/2
	centerY := circleY+hallHeight/2
	radiusSquared := radius*radius
	for attempt in 0..<16 {
		deltaX := int(WorldNoiseHash(unitSlot, sequence*31+attempt*2, seed+11)*f32(radius*2+1))-radius
		deltaY := int(WorldNoiseHash(unitSlot, sequence*31+attempt*2+1, seed+23)*f32(radius*2+1))-radius
		if deltaX == 0 && deltaY == 0 do continue
		if deltaX*deltaX+deltaY*deltaY > radiusSquared do continue
		x := WorldWrapCoordinate(centerX+deltaX, worldWidth)
		y := WorldWrapCoordinate(centerY+deltaY, worldHeight)
		if !UnitValidTileType(unit.type, w.ground[x][y].type) do continue
		if WorldTileOccupied(w, x, y) do continue
		return x, y, true
	}
	return 0, 0, false
}

// Finds the nearest harvestable tree decoration around the unit. Nearby
// spatial buckets are searched first; the linear scan is only a fallback for
// towns that have already cleared everything close to them.
UnitFindResourceTarget :: proc(w: ^World, unitSlot, taskSequence: int) -> (int, int, int, bool) {
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	chunkSize := w.spatial.chunkSize
	if worldWidth <= 0 || worldHeight <= 0 || chunkSize <= 0 do return 0, 0, -1, false

	unitX := int(WorldWrapPosition(w.units.x[unitSlot], f32(worldWidth)))
	unitY := int(WorldWrapPosition(w.units.y[unitSlot], f32(worldHeight)))
	seed := u64(unitSlot+taskSequence*1009)
	bestSlot := -1
	bestDistanceSquared: f32 = 0
	bestScore: f32 = -1

	centerChunkX := unitX/chunkSize
	centerChunkY := unitY/chunkSize
	for radius in 1..=4 {
		for chunkY in centerChunkY-radius ..= centerChunkY+radius {
			wrappedY := WorldWrapCoordinate(chunkY, w.spatial.chunksY)
			for chunkX in centerChunkX-radius ..= centerChunkX+radius {
				wrappedX := WorldWrapCoordinate(chunkX, w.spatial.chunksX)
				chunk := wrappedX*w.spatial.chunksY+wrappedY
				for slot := w.spatial.decorationHead[chunk]; slot >= 0;
					slot = w.spatial.decorationNext[slot] {
					if !DecorationChoppable(w.decorations.kind[slot]) do continue
					sourceX := int(w.decorations.x[slot])
					sourceY := int(w.decorations.y[slot])
					if WorldTileOccupied(w, sourceX, sourceY) do continue
					if !WorldTileWalkable(w, sourceX, sourceY, w.units[unitSlot].type, w.units[unitSlot].kingdome) do continue

					deltaX := WorldShortestWrappedDelta(f32(sourceX)-f32(unitX), f32(worldWidth))
					deltaY := WorldShortestWrappedDelta(f32(sourceY)-f32(unitY), f32(worldHeight))
					distanceSquared := deltaX*deltaX+deltaY*deltaY
					score := WorldNoiseHash(sourceX, sourceY, seed)
					if bestSlot >= 0 && (distanceSquared > bestDistanceSquared ||
						(distanceSquared == bestDistanceSquared && score <= bestScore)) {
						continue
					}
					bestSlot = slot
					bestDistanceSquared = distanceSquared
					bestScore = score
				}
			}
		}
	}

	if bestSlot < 0 {
		for slot in 0..<DECORATION_CAPACITY {
			if !w.decorationUsed[slot] do continue
			if !DecorationChoppable(w.decorations.kind[slot]) do continue
			sourceX := int(w.decorations.x[slot])
			sourceY := int(w.decorations.y[slot])
			if WorldTileOccupied(w, sourceX, sourceY) do continue
			if !WorldTileWalkable(w, sourceX, sourceY, w.units[unitSlot].type, w.units[unitSlot].kingdome) do continue

			deltaX := WorldShortestWrappedDelta(f32(sourceX)-f32(unitX), f32(worldWidth))
			deltaY := WorldShortestWrappedDelta(f32(sourceY)-f32(unitY), f32(worldHeight))
			distanceSquared := deltaX*deltaX+deltaY*deltaY
			score := WorldNoiseHash(sourceX, sourceY, seed)
			if bestSlot >= 0 && (distanceSquared > bestDistanceSquared ||
				(distanceSquared == bestDistanceSquared && score <= bestScore)) {
				continue
			}
			bestSlot = slot
			bestDistanceSquared = distanceSquared
			bestScore = score
		}
	}

	if bestSlot < 0 do return 0, 0, -1, false
	return int(w.decorations.x[bestSlot]), int(w.decorations.y[bestSlot]), bestSlot, true
}

// Stops at the nearest reachable water tile or hall entrance. If the entrance
// is unavailable, use the closest available hall ring. The return search area
// is not itself a delivery zone: accepting it lets collectors stay at the shore.
// An absent target can require O(world tiles) work; callers must delay retries.
// Stamps and the queue are shared with A*, with no new allocation.
UnitFindCollectorTarget :: proc(w: ^World, unitSlot, taskSequence: int, kingdomSlot := -1, townSlot := -1) -> (int, int, bool) {
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	nodeCount := worldWidth*worldHeight
	if worldWidth <= 0 || worldHeight <= 0 ||
		nodeCount > len(w.navigationStamp) || nodeCount > len(w.navigationQueue) {
		return 0, 0, false
	}

	unit := &w.units[unitSlot]
	returnRadius := 9
	preferEntrance := false
	fallbackX, fallbackY, fallbackFound := 0, 0, false
	if kingdomSlot >= 0 {
		// At most 20x20 tiles: choose the innermost usable ring before routing.
		town := &w.kingdoms[kingdomSlot].towns[townSlot]
		for x in max(0, town.x-8)..=min(worldWidth-1, town.x+11) {
			for y in max(0, town.y-8)..=min(worldHeight-1, town.y+11) {
				if x >= town.x && x < town.x+4 && y >= town.y && y < town.y+4 do continue
				if WorldTileOccupied(w, x, y) || !WorldTileWalkable(w, x, y, unit.type, unit.kingdome) do continue
				radius := max(max(town.x-x, x-(town.x+3)), max(town.y-y, y-(town.y+3)))
				returnRadius = min(returnRadius, radius)
				if y == town.y+4 && (x == town.x+1 || x == town.x+2) do preferEntrance = true
			}
		}
		if returnRadius > 8 do return 0, 0, false
	}

	w.navigationSearchId += 1
	if w.navigationSearchId == 0 {
		for &stamp in w.navigationStamp do stamp = 0
		w.navigationSearchId = 1
	}
	searchId := w.navigationSearchId
	startX := int(WorldWrapPosition(unit.x, f32(worldWidth)))
	startY := int(WorldWrapPosition(unit.y, f32(worldHeight)))
	start := startX*worldHeight+startY
	w.navigationStamp[start] = searchId
	w.navigationQueue[0] = start
	head, tail := 0, 1
	directionOffset := WorldWrapCoordinate(unitSlot+taskSequence, 4)
	for head < tail {
		index := w.navigationQueue[head]
		head += 1
		x, y := index/worldHeight, index%worldHeight
		if UnitValidTileType(unit.type, w.ground[x][y].type) &&
			WorldTileWalkable(w, x, y, unit.type, unit.kingdome) && !WorldTileOccupied(w, x, y) {
			if kingdomSlot >= 0 {
				town := &w.kingdoms[kingdomSlot].towns[townSlot]
				radius := max(max(town.x-x, x-(town.x+3)), max(town.y-y, y-(town.y+3)))
				if radius == returnRadius {
					if !preferEntrance || (y == town.y+4 && (x == town.x+1 || x == town.x+2)) {
						return x, y, true
					}
					if !fallbackFound do fallbackX, fallbackY, fallbackFound = x, y, true
				}
			} else {
				if w.ground[x][y].type == .River do return x, y, true
				for direction in 0..<4 {
					sourceX, sourceY := x, y
					switch direction {
					case 0: sourceX += 1
					case 1: sourceX -= 1
					case 2: sourceY += 1
					case 3: sourceY -= 1
					}
					sourceX = WorldWrapCoordinate(sourceX, worldWidth)
					sourceY = WorldWrapCoordinate(sourceY, worldHeight)
					tileType := w.ground[sourceX][sourceY].type
					if TileIsWater(tileType) || tileType == .Marsh do return x, y, true
				}
			}
		}
		for direction in 0..<4 {
			x, y := index/worldHeight, index%worldHeight
			switch (direction+directionOffset)%4 {
			case 0: x += 1
			case 1: x -= 1
			case 2: y += 1
			case 3: y -= 1
			}
			x = WorldWrapCoordinate(x, worldWidth)
			y = WorldWrapCoordinate(y, worldHeight)
			next := x*worldHeight+y
			if w.navigationStamp[next] == searchId do continue
			if !WorldTileWalkable(w, x, y, unit.type, unit.kingdome) do continue
			w.navigationStamp[next] = searchId
			w.navigationQueue[tail] = next
			tail += 1
		}
	}
	// Walkable entrances may belong to a disconnected pocket. In that case,
	// retain a reachable perimeter point instead of stranding the return trip.
	return fallbackX, fallbackY, fallbackFound
}

UnitFindWaterTarget :: proc(w: ^World, unitSlot, taskSequence: int) -> (int, int, bool) {
	return UnitFindCollectorTarget(w, unitSlot, taskSequence)
}

UnitFindFarmlandTarget :: proc(w: ^World, unitSlot, sequence: int) -> (int, int, bool) {
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	unitX := WorldWrapPosition(w.units[unitSlot].x, f32(worldWidth))
	unitY := WorldWrapPosition(w.units[unitSlot].y, f32(worldHeight))
	bestX, bestY := 0, 0
	bestDistanceSquared: f32 = 0
	bestScore: f32 = -1
	foundTarget := false
	seed := u64(unitSlot+sequence*1031)
	for buildingSlot in 0..<BUILDING_CAPACITY {
		if !w.buildingUsed[buildingSlot] ||
			w.buildings[buildingSlot].kingdom != w.units[unitSlot].kingdome ||
			w.buildings[buildingSlot].town != w.units[unitSlot].town {
			continue
		}
		if BuildingKindOf(w.buildings[buildingSlot].type) != .Farmland do continue

		farmX := w.buildings.x[buildingSlot]
		farmY := w.buildings.y[buildingSlot]
		farmWidth, farmHeight := BuildingTileSize(w.buildings[buildingSlot].type)
		for offsetX in -1..=farmWidth {
			for offsetY in -1..=farmHeight {
				if offsetX >= 0 && offsetX < farmWidth && offsetY >= 0 && offsetY < farmHeight do continue
				x := WorldWrapCoordinate(farmX+offsetX, worldWidth)
				y := WorldWrapCoordinate(farmY+offsetY, worldHeight)
				if !UnitValidTileType(w.units[unitSlot].type, w.ground[x][y].type) do continue
				deltaX := WorldShortestWrappedDelta(f32(x)-unitX, f32(worldWidth))
				deltaY := WorldShortestWrappedDelta(f32(y)-unitY, f32(worldHeight))
				distanceSquared := deltaX*deltaX + deltaY*deltaY
				score := WorldNoiseHash(x, y, seed)
				if foundTarget && (distanceSquared > bestDistanceSquared ||
					(distanceSquared == bestDistanceSquared && score <= bestScore)) {
					continue
				}
				if WorldTileOccupied(w, x, y) do continue
				bestX, bestY = x, y
				bestDistanceSquared = distanceSquared
				bestScore = score
				foundTarget = true
			}
		}
	}
	return bestX, bestY, foundTarget
}

UnitFindHomeTarget :: proc(w: ^World, unitSlot: int) -> (int, int, bool) {
	home := UnitHome(w, unitSlot)
	if home < 0 do return 0, 0, false
	unit := &w.units[unitSlot]
	worldWidth, worldHeight := int(w.maxX), int(w.maxY)
	unitX := WorldWrapPosition(unit.x, f32(worldWidth))
	unitY := WorldWrapPosition(unit.y, f32(worldHeight))
	tried: [3][3]bool
	// Prefer the nearest ring tile, but try the other entrances if it belongs
	// to a disconnected pocket. Never hide a citizen after a failed path.
	for _ in 0..<8 {
		bestX, bestY, bestOx, bestOy := 0, 0, 0, 0
		bestDistance: f32 = 0
		found := false
		for ox in -1..=1 {
			for oy in -1..=1 {
				if (ox == 0 && oy == 0) || tried[ox+1][oy+1] do continue
				x := WorldWrapCoordinate(w.buildings.x[home]+ox, worldWidth)
				y := WorldWrapCoordinate(w.buildings.y[home]+oy, worldHeight)
				if WorldTileOccupied(w, x, y) || !WorldTileWalkable(w, x, y, unit.type, unit.kingdome) do continue
				dx := WorldShortestWrappedDelta(f32(x)+0.5-unitX, f32(worldWidth))
				dy := WorldShortestWrappedDelta(f32(y)+0.5-unitY, f32(worldHeight))
				distance := dx*dx+dy*dy
				if !found || distance < bestDistance {
					bestX, bestY, bestOx, bestOy = x, y, ox, oy
					bestDistance, found = distance, true
				}
			}
		}
		if !found do break
		tried[bestOx+1][bestOy+1] = true
		if AStar(w, unit.type, unit.kingdome, int(unitX), int(unitY), bestX, bestY, &unit.path) {
			return bestX, bestY, true
		}
	}
	return 0, 0, false
}

UnitFindTownReturnPoint :: proc(w: ^World, kingdomSlot, townSlot: int, unitSlot := -1) -> (int, int, bool) {
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	// Collectors prefer the hall entrance, with a reachable perimeter fallback;
	// other callers retain the original town-centered ring search.
	if unitSlot >= 0 {
		return UnitFindCollectorTarget(w, unitSlot, 0, kingdomSlot, townSlot)
	}
	townX := w.kingdoms[kingdomSlot].towns[townSlot].x
	townY := w.kingdoms[kingdomSlot].towns[townSlot].y
	for radius in 1..=8 {
		minX := max(0, townX-radius)
		maxX := min(worldWidth-1, townX+4+radius)
		minY := max(0, townY-radius)
		maxY := min(worldHeight-1, townY+4+radius)
		for x in minX..=maxX {
			for y in minY..=maxY {
				if x >= townX && x < townX+4 && y >= townY && y < townY+4 do continue
				if max(max(townX-x, 0), x-(townX+3)) > radius ||
					max(max(townY-y, 0), y-(townY+3)) > radius {
					continue
				}
				if !UnitValidTileType(Villager{}, w.ground[x][y].type) || WorldTileOccupied(w, x, y) do continue
				return x, y, true
			}
		}
	}
	return 0, 0, false
}

UnitMoveToTarget :: proc(w: ^World, unitSlot: int, deltaTime: f32) -> bool {
	if int(WorldWrapPosition(w.units.x[unitSlot], f32(w.maxX))) == w.units[unitSlot].pathTargetX &&
		int(WorldWrapPosition(w.units.y[unitSlot], f32(w.maxY))) == w.units[unitSlot].pathTargetY {
		return true
	}
	reached := UnitMove(w, unitSlot, w.units[unitSlot].pathTargetX, w.units[unitSlot].pathTargetY, deltaTime)
	if !w.units[unitSlot].pathFound do return false
	return reached
}
