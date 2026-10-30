package main

import "base:intrinsics"
import "d32"


// Pacific units drop their work to fight a fire burning inside their town.
UnitTryExtinguish :: proc(w: ^World, unitSlot: int, deltaTime: f32) -> bool {
	start := ProfileSectionBegin(.UnitExtinguish)
	defer ProfileSectionEnd(.UnitExtinguish, start)
	unit := &w.units[unitSlot]
	rate := UnitExtinguishRate(unit.type)
	if rate <= 0 do return false
	if w.fireCount == 0 do return false
	if !WorldTownExists(w, unit.kingdome, unit.town) do return false

	fireSlot := -1
	bestDistanceSquared: u64 = 0
	extinguishRadiusRaw := UnitRawDistance(FIRE_EXTINGUISH_RADIUS)
	extinguishRadiusSquaredRaw := u64(extinguishRadiusRaw)*u64(extinguishRadiusRaw)
	worldWidthRaw := i64(w.maxX)*d32.SCALE
	worldHeightRaw := i64(w.maxY)*d32.SCALE
	RecursiveLockAcquire(&w.fireMutex)
	for activeIndex in 0..<w.fireCount {
		slot := w.fireActive[activeIndex]
		if !TownPointInArea(w, unit.kingdome, unit.town, int(w.fires.x[slot]), int(w.fires.y[slot])) {
			continue
		}
		distanceSquared, validDistance := d32.WrappedDistanceSquared(
			unit.x,
			unit.y,
			PositionFromF32(w.fires.x[slot]),
			PositionFromF32(w.fires.y[slot]),
			worldWidthRaw,
			worldHeightRaw,
		)
		if !validDistance do continue
		if fireSlot >= 0 && distanceSquared >= bestDistanceSquared do continue
		fireSlot = slot
		bestDistanceSquared = distanceSquared
	}
	if fireSlot < 0 {
		RecursiveLockRelease(&w.fireMutex)
		return false
	}

	// A fire is an emergency: abandon whatever task is in progress.
	if state, ok := unit.state.(StatePacific); ok && state != .Roaming {
		unit.state = StatePacific.Roaming
		unit.pathReady = false
	}

	if bestDistanceSquared <= extinguishRadiusSquaredRaw {
		w.fires.remaining[fireSlot] = max(
			d32.Sub(w.fires.remaining[fireSlot], PositionFromF32(rate*deltaTime)),
			d32.ZERO,
		)
		if w.fires.remaining[fireSlot] <= d32.ZERO do WorldFireDespawn(w, fireSlot)
		unit.pathReady = false
		RecursiveLockRelease(&w.fireMutex)
		return true
	}
	fireX := int(w.fires.x[fireSlot])
	fireY := int(w.fires.y[fireSlot])
	RecursiveLockRelease(&w.fireMutex)

	targetX, targetY, found := FireAccessPoint(
		w,
		fireX,
		fireY,
		unit.type,
		unit.kingdome,
	)
	if !found do return false
	if !unit.pathReady || unit.pathTargetX != targetX || unit.pathTargetY != targetY {
		unit.pathTargetX = targetX
		unit.pathTargetY = targetY
		unit.pathReady = false
	}
	UnitMoveToTarget(w, unitSlot, deltaTime, CIVILIAN_PATH_EXPANSIONS)
	return true
}

UnitUpdateVillager :: proc(w: ^World, unitSlot: int, deltaTime: f32) {
	kingdomSlot := w.units[unitSlot].kingdome
	townSlot := w.units[unitSlot].town
	if !WorldTownExists(w, kingdomSlot, townSlot) do return
	intrinsics.atomic_add(
		&w.kingdoms[kingdomSlot].towns[townSlot].villagersBySlice[UnitUpdateSlice(w)],
		1,
	)
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
// Exploration targets can be far away; cap the search so one unlucky
// explorer cannot run a full-world A* every tick.
EXPLORER_PATH_EXPANSIONS :: 2048

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
		explorer.restTimer = d32.Sub(explorer.restTimer, PositionFromF32(deltaTime))
		if explorer.restTimer <= d32.ZERO {
			explorer.tripsLeft = EXPLORER_TRIPS_BEFORE_REST
			state^ = .Roaming
			unit.pathReady = false
		}
	case .Returning:
		reached := UnitMoveToTarget(w, unitSlot, deltaTime, EXPLORER_PATH_EXPANSIONS)
		if reached || !unit.pathFound {
			explorer.restTimer = d32.Add(
				d32.FromInt(i32(EXPLORER_REST_MIN)),
				d32.Mul(
					PositionFromF32(WorldNoiseHash(unitSlot, explorer.journey, 0xE8A1)),
					d32.FromInt(i32(EXPLORER_REST_MAX-EXPLORER_REST_MIN)),
				),
			)
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
				explorer.restTimer = d32.FromInt(i32(EXPLORER_REST_MIN))
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
		reached := UnitMoveToTarget(w, unitSlot, deltaTime, EXPLORER_PATH_EXPANSIONS)
		if reached {
			state^ = .Roaming
		} else if !unit.pathFound {
			// Do not retry a capped search every tick.
			explorer.restTimer = d32.FromInt(i32(EXPLORER_REST_MIN))
			state^ = .Working
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

	unitX := UnitTileX(w, unitSlot)
	unitY := UnitTileY(w, unitSlot)
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
		if !UnitValidTileType(unitType, WorldTileAt(w, x, y).type) do continue
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
	intrinsics.atomic_add(&town.buildersBySlice[UnitUpdateSlice(w)], 1)
	if state^ == .Roaming && builder.carriedResource > d32.ZERO {
		if x, y, found := UnitFindTownReturnPoint(w, kingdomSlot, townSlot); found {
			w.units[unitSlot].pathTargetX = x
			w.units[unitSlot].pathTargetY = y
			w.units[unitSlot].pathReady = false
			state^ = .Returning
		}
	}
	if state^ == .Roaming && w.units[unitSlot].decisionReady &&
		TownConstructionCount(w, kingdomSlot, townSlot) > 0 {
		if site, x, y, found := TownFindConstructionForBuilder(
			w,
			unitSlot,
			kingdomSlot,
			townSlot,
		); found {
			builder.constructionSite = site
			w.units[unitSlot].pathTargetX = x
			w.units[unitSlot].pathTargetY = y
			w.units[unitSlot].pathReady = false
			state^ = .ToConstruction
		}
	}
	if state^ == .Roaming && w.units[unitSlot].decisionReady &&
		town.wood < TownWoodGatherTarget(w, kingdomSlot, townSlot) &&
		WorldCurrentTick(w) >= town.woodSearchFailUntilTick {
		if x, y, decoration, found := UnitFindResourceTarget(w, unitSlot, builder.taskSequence); found {
			builder.targetDecoration = decoration
			w.units[unitSlot].pathTargetX = x
			w.units[unitSlot].pathTargetY = y
			w.units[unitSlot].pathReady = false
			state^ = .Traveling
		} else {
			town.woodSearchFailUntilTick = WorldCurrentTick(w)+WOOD_SEARCH_RETRY_TICKS
		}
	}

	speed := UnitMoveSpeed(w, unitSlot, UnitDefaultSpeed(w.units[unitSlot].type))
	step := PositionFromF32(deltaTime)
	switch state^ {
	case .Roaming:
		UnitUpdateRoaming(w, unitSlot, deltaTime)
	case .Traveling:
		reached, blocked, _ := UnitStepTowards(
			w,
			unitSlot,
			TileCenterRaw(w.units[unitSlot].pathTargetX),
			TileCenterRaw(w.units[unitSlot].pathTargetY),
			d32.Mul(speed, step),
		)
		if reached {
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
		} else if blocked {
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

		w.units[unitSlot].cooldown = max(
			d32.Sub(w.units[unitSlot].cooldown, step),
			d32.ZERO,
		)
		if w.units[unitSlot].cooldown <= d32.ZERO {
			carried := DecorationWoodYield(w.decorations.kind[builder.targetDecoration])
			DecorationFell(w, builder.targetDecoration)
			builder.targetDecoration = -1
			if carried > d32.ZERO {
				builder.carriedResource = carried
				if x, y, found := UnitFindTownReturnPoint(w, kingdomSlot, townSlot); found {
					w.units[unitSlot].pathTargetX = x
					w.units[unitSlot].pathTargetY = y
					w.units[unitSlot].pathReady = false
					state^ = .Returning
				} else {
					builder.carriedResource = d32.ZERO
					state^ = .Roaming
				}
			} else {
				state^ = .Roaming
				builder.taskSequence += 1
			}
		}
	case .Returning:
		reached, blocked, _ := UnitStepTowards(
			w,
			unitSlot,
			TileCenterRaw(w.units[unitSlot].pathTargetX),
			TileCenterRaw(w.units[unitSlot].pathTargetY),
			d32.Mul(speed, step),
		)
		if reached {
			ParallelQueueConstruction(
				unitSlot, kingdomSlot, townSlot, -1,
				0, .Wood,
				d32.Mul(builder.carriedResource, KingdomTechWoodMultiplier(w, kingdomSlot)),
			)
			builder.carriedResource = d32.ZERO
			builder.targetDecoration = -1
			builder.taskSequence += 1
			state^ = .Roaming
			w.units[unitSlot].pathReady = false
		} else if blocked {
			builder.carriedResource = d32.ZERO
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
		reached, blocked, _ := UnitStepTowards(
			w,
			unitSlot,
			TileCenterRaw(w.units[unitSlot].pathTargetX),
			TileCenterRaw(w.units[unitSlot].pathTargetY),
			d32.Mul(speed, PositionFromF32(deltaTime)),
		)
		if reached {
			builder.failedConstruction = -1
			state^ = .Building
			w.units[unitSlot].pathReady = false
		} else if blocked {
			// The cached access point is on the wrong side of the site for this
			// builder. Drop it so the next attempt searches from the new position.
			if builder.constructionSite >= 0 &&
				builder.constructionSite < TOWN_CONSTRUCTION_CAPACITY {
				town.constructions[builder.constructionSite].accessReady = false
			}
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
		// Work is applied after the unit loop; a finished site is noticed on the
		// builder's next update.
		ParallelQueueConstruction(unitSlot, kingdomSlot, townSlot, builder.constructionSite, step, .Work)
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
	intrinsics.atomic_add(
		&w.kingdoms[kingdomSlot].towns[townSlot].waterCollectorsBySlice[UnitUpdateSlice(w)],
		1,
	)
	if UnitUpdatePacificSleep(w, unitSlot, deltaTime) do return
	if UnitTryExtinguish(w, unitSlot, deltaTime) do return

	if state^ == .Roaming {
		if collector.carriedResource > 0 {
			if w.units[unitSlot].cooldown > d32.ZERO {
				w.units[unitSlot].cooldown = max(
					d32.Sub(w.units[unitSlot].cooldown, PositionFromF32(deltaTime)),
					d32.ZERO,
				)
				return
			}
			if x, y, found := TownCollectorReturnPoint(w, kingdomSlot, townSlot); found {
				w.units[unitSlot].pathTargetX = x
				w.units[unitSlot].pathTargetY = y
				w.units[unitSlot].pathReady = false
				state^ = .Returning
			} else {
				// Keep the load, but do not search or start roaming paths every tick.
				w.units[unitSlot].cooldown = d32.FromInt(5)
				w.units[unitSlot].pathReady = false
				return
			}
		} else if w.units[unitSlot].cooldown > d32.ZERO {
			w.units[unitSlot].cooldown = max(
				d32.Sub(w.units[unitSlot].cooldown, PositionFromF32(deltaTime)),
				d32.ZERO,
			)
		} else if w.units[unitSlot].decisionReady {
			if x, y, found := TownCollectorWaterPoint(
				w,
				kingdomSlot,
				townSlot,
				unitSlot,
				collector.taskSequence,
			); found {
				w.units[unitSlot].pathTargetX = x
				w.units[unitSlot].pathTargetY = y
				w.units[unitSlot].pathReady = false
				state^ = .Traveling
			} else {
				w.units[unitSlot].cooldown = d32.FromInt(5)
			}
		}
	}

	switch state^ {
	case .Roaming:
		UnitUpdateRoaming(w, unitSlot, deltaTime)
	case .Traveling:
		if UnitMove(
			w,
			unitSlot,
			unit.pathTargetX,
			unit.pathTargetY,
			deltaTime,
			CIVILIAN_PATH_EXPANSIONS,
		) {
			state^ = .Working
			unit.pathReady = false
			w.units[unitSlot].cooldown = d32.FromRatio(i32(WORLD_DAY_LENGTH_SECONDS), 48)
		} else if !w.units[unitSlot].pathFound {
			state^ = .Roaming
			w.units[unitSlot].pathReady = false
			collector.taskSequence += 1
		}
	case .Working:
		w.units[unitSlot].cooldown = max(
			d32.Sub(w.units[unitSlot].cooldown, PositionFromF32(deltaTime)),
			d32.ZERO,
		)
		if w.units[unitSlot].cooldown <= d32.ZERO {
			collector.carriedResource = 1
			if x, y, found := TownCollectorReturnPoint(w, kingdomSlot, townSlot); found {
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
		reached := UnitMove(
			w,
			unitSlot,
			unit.pathTargetX,
			unit.pathTargetY,
			deltaTime,
			CIVILIAN_PATH_EXPANSIONS,
		)
		if reached || !w.units[unitSlot].pathFound {
			collector.carriedResource = 0
			collector.taskSequence += 1
			state^ = .Roaming
			w.units[unitSlot].cooldown = d32.ZERO
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
	intrinsics.atomic_add(
		&w.kingdoms[kingdomSlot].towns[townSlot].farmersBySlice[UnitUpdateSlice(w)],
		1,
	)
	if UnitUpdatePacificSleep(w, unitSlot, deltaTime) do return
	if UnitTryExtinguish(w, unitSlot, deltaTime) do return

	state := &w.units[unitSlot].state.(StatePacific)
	if state^ == .Roaming && !farmer.workedToday {
		if w.units[unitSlot].cooldown > d32.ZERO {
			w.units[unitSlot].cooldown = max(
				d32.Sub(w.units[unitSlot].cooldown, PositionFromF32(deltaTime)),
				d32.ZERO,
			)
		} else if w.units[unitSlot].decisionReady {
			if x, y, found := UnitFindFarmlandTarget(w, unitSlot, farmer.workDay); found {
				w.units[unitSlot].pathTargetX = x
				w.units[unitSlot].pathTargetY = y
				w.units[unitSlot].pathReady = false
				state^ = .Traveling
			} else {
				w.units[unitSlot].cooldown = d32.FromInt(5)
			}
		}
	}

	switch state^ {
	case .Roaming:
		UnitUpdateRoaming(w, unitSlot, deltaTime)
	case .Traveling:
		speed := UnitMoveSpeed(w, unitSlot, UnitDefaultSpeed(w.units[unitSlot].type))
		reached, blocked, _ := UnitStepTowards(
			w,
			unitSlot,
			TileCenterRaw(w.units[unitSlot].pathTargetX),
			TileCenterRaw(w.units[unitSlot].pathTargetY),
			d32.Mul(speed, PositionFromF32(deltaTime)),
		)
		if reached {
			state^ = .Working
			w.units[unitSlot].cooldown = d32.FromRatio(i32(WORLD_DAY_LENGTH_SECONDS), 24)
		} else if blocked {
			state^ = .Roaming
			w.units[unitSlot].pathReady = false
			w.units[unitSlot].cooldown = d32.FromInt(5)
		}
	case .Working:
		w.units[unitSlot].cooldown = max(
			d32.Sub(w.units[unitSlot].cooldown, PositionFromF32(deltaTime)),
			d32.ZERO,
		)
		if w.units[unitSlot].cooldown <= d32.ZERO {
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
		state.timer = d32.Sub(state.timer, PositionFromF32(deltaTime))
		if state.timer <= d32.ZERO do UnitConvert(w, unitSlot)
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
			UnitTileX(w, unitSlot),
			UnitTileY(w, unitSlot),
		)
		if !found {
			UnitConversionCancel(w, unitSlot)
			return
		}
		state.accessX, state.accessY = x, y
		state.retryTimer = d32.ZERO
		unit.pathReady = false
	}
	if state.retryTimer > d32.ZERO {
		state.retryTimer = d32.Sub(state.retryTimer, PositionFromF32(deltaTime))
		return
	}

	if unit.pathTargetX != state.accessX || unit.pathTargetY != state.accessY {
		unit.pathTargetX = state.accessX
		unit.pathTargetY = state.accessY
		unit.pathReady = false
	}
	if UnitMoveToTarget(w, unitSlot, deltaTime, CIVILIAN_PATH_EXPANSIONS) {
		state.inside = true
		SpatialUnitRemove(w, unitSlot)
		state.timer = d32.Div(
			UnitDefaultTrainingTime(state.to),
			PositionFromF32(KingdomTechConversionSpeedMultiplier(w, unit.kingdome, state.to)),
		)
		unit.pathReady = false
	} else if !unit.pathFound {
		unit.pathReady = false
		state.retryTimer = d32.FromInt(1)
	}
}

UnitConvert :: proc(w: ^World, unitSlot: int) {
	if unitSlot < 0 || unitSlot >= UNIT_CAPACITY || !w.unitUsed[unitSlot] do return
	// Conversion jobs are shared by every unit of the town.
	RecursiveLockGuard(&w.unitMutex)
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
	RecursiveLockGuard(&w.unitMutex)
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
	UnitWake(w, unitSlot)
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
	if BuildingKindOf(building.type) != .Home || building.health <= d32.ZERO ||
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
	x := UnitTileX(w, unitSlot)
	y := UnitTileY(w, unitSlot)
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
	// UnitInsideHome cannot succeed unless the unit is marked as inside.
	if !w.units[unitSlot].sleepInside do return false
	return UnitInsideHome(w, unitSlot) >= 0
}

UnitWake :: proc(w: ^World, unitSlot: int) {
	if unitSlot < 0 || unitSlot >= UNIT_CAPACITY || !w.unitUsed[unitSlot] do return
	w.units.updateStride[unitSlot] = 1
	w.units.decisionTimer[unitSlot] = d32.ZERO
}

// Idle villagers in peaceful towns are the only units allowed to sleep through
// simulation slices. Everything else stays at the normal cadence.
UnitDesiredUpdateStride :: proc(w: ^World, unitSlot: int) -> u8 {
	unit := &w.units[unitSlot]
	if UnitKindOf(unit.type) != .Villager do return 1
	state, pacific := unit.state.(StatePacific)
	if !pacific || state != .Roaming do return 1
	if !WorldTownExists(w, unit.kingdome, unit.town) do return 1
	if w.kingdoms[unit.kingdome].towns[unit.town].alarmActive do return 1
	return UNIT_LOD_DORMANT_STRIDE
}

UnitSleepWake :: proc(w: ^World, unitSlot: int) {
	if unitSlot < 0 || unitSlot >= UNIT_CAPACITY || !w.unitUsed[unitSlot] do return
	unit := &w.units[unitSlot]
	w.units.updateStride[unitSlot] = 1
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
	start := ProfileSectionBegin(.UnitSafety)
	defer ProfileSectionEnd(.UnitSafety, start)
	unit := &w.units[unitSlot]
	if UnitIsWarrior(unit.type) || UnitKindOf(unit.type) == .CombatBuilder do return false
	if state, converting := unit.state.(StateConverting); converting && state.inside do return false
	if UnitHome(w, unitSlot) < 0 do UnitReleaseHome(w, unitSlot)
	if unit.sleepInside && UnitInsideHome(w, unitSlot) < 0 do UnitSleepWake(w, unitSlot)
	alarm := false
	threatX, threatY := 0, 0
	if WorldTownExists(w, unit.kingdome, unit.town) {
		town := &w.kingdoms[unit.kingdome].towns[unit.town]
		alarm = town.alarmActive
		threatX, threatY = town.threatX, town.threatY
	}
	// Only civilians close to the reported threat need their own scan. The
	// rest of an alarmed town keeps working instead of scanning every update.
	threatened := false
	if alarm {
		threatRadiusRaw := UnitRawDistance(f32(FLEE_THREAT_RADIUS*2))
		threatRadiusSquaredRaw := u64(threatRadiusRaw)*u64(threatRadiusRaw)
		distanceSquared, validDistance := d32.WrappedDistanceSquared(
			unit.x,
			unit.y,
			TileCenterPosition(threatX),
			TileCenterPosition(threatY),
			i64(w.maxX)*d32.SCALE,
			i64(w.maxY)*d32.SCALE,
		)
		threatened = validDistance && distanceSquared <= threatRadiusSquaredRaw
	}
	fleeing := false
	if pacificState, pacific := unit.state.(StatePacific); pacific {
		fleeing = pacificState == .Fleeing
	}
	if fleeing && !unit.decisionReady {
		// Keep moving along the planned route; the next decision tick refreshes
		// threats and clearance.
		if !UnitFollowEscapePath(w, unitSlot, deltaTime) do return true
		UnitSleepWake(w, unitSlot)
		return false
	}
	enemy := -1
	if threatened && unit.decisionReady {
		enemy = UnitFindNearbyEnemy(w, unitSlot, FLEE_THREAT_RADIUS)
	}
	if !threatened {
		if pacificState, pacific := unit.state.(StatePacific); pacific {
			if pacificState == .Hiding {
				hour := WorldTimeOfDay(w)
				if hour < 6 || hour >= 22+unit.sleepOffsetHours {
					unit.state = StatePacific.Sleeping
				} else {
					UnitSleepWake(w, unitSlot)
				}
			} else if pacificState == .Fleeing {
				UnitSleepWake(w, unitSlot)
			}
		}
		return false
	}
	if !unit.decisionReady {
		// Defer the alarm reaction to the next decision tick.
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
		unit.sleepNavigationRevision == w.pathRevision
	if home >= 0 && !failedHome {
		if state^ != .GoingHome {
			unit.pathReady = false
			if x, y, found := UnitFindHomeTarget(w, unitSlot); found {
				unit.pathTargetX, unit.pathTargetY = x, y
				state^ = .GoingHome
			} else {
				unit.sleepNavigationRevision = w.pathRevision
			}
		}
		if state^ == .GoingHome {
			if UnitMove(
				w,
				unitSlot,
				unit.pathTargetX,
				unit.pathTargetY,
				deltaTime,
				CIVILIAN_PATH_EXPANSIONS,
			) {
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
			unit.sleepNavigationRevision = w.pathRevision
		}
	}
	if state^ != .Fleeing {
		UnitSleepWake(w, unitSlot)
		state^ = .Fleeing
		unit.pathReady = false
	}
	if enemy >= 0 {
		UnitFleeEnemy(w, unitSlot, enemy, deltaTime)
	} else if state^ == .Fleeing {
		UnitFollowEscapePath(w, unitSlot, deltaTime)
	}
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
			unit.sleepNavigationRevision == w.pathRevision {
			return true
		}
		// An outdoor sleeper retries an inaccessible Home only after the map changes.
		state^ = .Roaming
	}
	if state^ != .GoingHome {
		if x, y, found := UnitFindHomeTarget(w, unitSlot); found {
			unit.pathTargetX, unit.pathTargetY = x, y
			state^ = .GoingHome
		} else {
			state^ = .Sleeping
			unit.pathReady = false
			unit.sleepNavigationRevision = w.pathRevision
			return true
		}
	}
	if UnitMoveToTarget(w, unitSlot, deltaTime, CIVILIAN_PATH_EXPANSIONS) {
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
		unit.sleepNavigationRevision = w.pathRevision
	}
	return true
}

// Civilian roaming stays a little beyond the town's buildable area instead of
// drifting across the map.
TOWN_ROAM_AREA_FACTOR :: 1.25

UnitUpdateRoaming :: proc(w: ^World, unitSlot: int, deltaTime: f32) {
	unit := &w.units[unitSlot]
	atTarget := UnitTileX(w, unitSlot) == unit.pathTargetX &&
		UnitTileY(w, unitSlot) == unit.pathTargetY
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

	// Roam targets are short local hops. Direct stepping avoids running A*
	// for every ambient villager; a blocked step just picks a new target.
	speed := UnitMoveSpeed(w, unitSlot, UnitDefaultSpeed(unit.type))
	reached, blocked, _ := UnitStepTowards(
		w,
		unitSlot,
		TileCenterRaw(unit.pathTargetX),
		TileCenterRaw(unit.pathTargetY),
		d32.Mul(speed, PositionFromF32(deltaTime)),
	)
	if reached || blocked {
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
	// Rolls stay f32; quantize each once at the shortage boundary.
	w.units[unitSlot].effects[.NoFood] = PositionFromF32(foodRoll) < town.foodShortage
	w.units[unitSlot].effects[.NoWater] = PositionFromF32(waterRoll) < town.waterShortage

	regen: f32 = 0.25
	if !w.units[unitSlot].effects[.NoHome] do regen = 1
	if w.units[unitSlot].poisonRemaining > 0 do regen = 0
	maximum := UnitMaxHealth(w, unitSlot)
	health := d32.Add(w.units[unitSlot].health, PositionFromF32(regen*deltaTime))
	if health > maximum do health = maximum
	w.units[unitSlot].health = health
}

// Applies town shortage effects and passive regeneration for one unit. Runs
// with the unit's own slice, so it never needs a separate world pass.
UnitUpdateTownUpkeep :: proc(w: ^World, unitSlot: int, shortageEpoch: int, deltaTime: f32) {
	kingdomSlot := w.units.kingdome[unitSlot]
	townSlot := w.units.town[unitSlot]
	if !WorldTownExists(w, kingdomSlot, townSlot) {
		UnitClearTownEffects(w, unitSlot)
		return
	}
	isHoused := UnitHome(w, unitSlot) >= 0
	UnitApplyTownEffects(w, unitSlot, isHoused, shortageEpoch, deltaTime)
}

UnitClearTownEffects :: proc(w: ^World, unitSlot: int) {
	w.units[unitSlot].effects[.NoHome] = true
	w.units[unitSlot].effects[.NoWater] = false
	w.units[unitSlot].effects[.NoFood] = false
	w.units[unitSlot].effects[.Poisoned] = false
}

UnitFindRoamingTarget :: proc(w: ^World, unitSlot, sequence: int) -> (int, int, bool) {
	start := ProfileSectionBegin(.UnitSeek)
	defer ProfileSectionEnd(.UnitSeek, start)
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
		if !UnitValidTileType(unit.type, WorldTileAt(w, x, y).type) do continue
		if WorldTileOccupied(w, x, y) do continue
		return x, y, true
	}
	return 0, 0, false
}

// Finds the nearest harvestable tree decoration around the unit. Nearby
// spatial buckets are searched first; the linear scan is only a fallback for
// towns that have already cleared everything close to them.
UnitFindResourceTarget :: proc(w: ^World, unitSlot, taskSequence: int) -> (int, int, int, bool) {
	start := ProfileSectionBegin(.UnitSeek)
	defer ProfileSectionEnd(.UnitSeek, start)
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	chunkSize := w.spatial.chunkSize
	if worldWidth <= 0 || worldHeight <= 0 || chunkSize <= 0 do return 0, 0, -1, false

	unitX := UnitTileX(w, unitSlot)
	unitY := UnitTileY(w, unitSlot)
	unitPositionX := w.units.x[unitSlot]
	unitPositionY := w.units.y[unitSlot]
	worldWidthRaw := i64(w.maxX)*d32.SCALE
	worldHeightRaw := i64(w.maxY)*d32.SCALE
	seed := u64(unitSlot+taskSequence*1009)
	bestSlot := -1
	bestDistanceSquared: u64 = 0
	bestScore: f32 = -1

	centerChunkX := unitX/chunkSize
	centerChunkY := unitY/chunkSize
	// Rings expand from the unit and stop at the first one with a hit, so a
	// builder standing next to trees no longer walks a 17x17 chunk square.
	RESOURCE_SEARCH_CHUNK_RINGS :: 3
	for ring in 0..=RESOURCE_SEARCH_CHUNK_RINGS {
		for offsetY in -ring..=ring {
			for offsetX in -ring..=ring {
				if max(abs(offsetX), abs(offsetY)) != ring do continue
				wrappedX := WorldWrapCoordinate(centerChunkX+offsetX, w.spatial.chunksX)
				wrappedY := WorldWrapCoordinate(centerChunkY+offsetY, w.spatial.chunksY)
				chunk := wrappedX*w.spatial.chunksY+wrappedY
				for slot := w.spatial.decorationHead[chunk]; slot >= 0;
					slot = w.spatial.decorationNext[slot] {
					if !DecorationChoppable(w.decorations.kind[slot]) do continue
					sourceX := int(d32.ToInt(w.decorations.x[slot]))
					sourceY := int(d32.ToInt(w.decorations.y[slot]))
					if WorldTileOccupied(w, sourceX, sourceY) do continue
					if !WorldTileWalkable(w, sourceX, sourceY, w.units[unitSlot].type, w.units[unitSlot].kingdome) {
						continue
					}

					distanceSquared, validDistance := d32.WrappedDistanceSquared(
						unitPositionX,
						unitPositionY,
						w.decorations.x[slot],
						w.decorations.y[slot],
						worldWidthRaw,
						worldHeightRaw,
					)
					if !validDistance do continue
					score := WorldNoiseHash(sourceX, sourceY, seed)
					if bestSlot >= 0 && (distanceSquared > bestDistanceSquared ||
						(distanceSquared == bestDistanceSquared && (score < bestScore ||
							(score == bestScore && slot >= bestSlot)))) {
						continue
					}
					bestSlot = slot
					bestDistanceSquared = distanceSquared
					bestScore = score
				}
			}
		}
		if bestSlot >= 0 do break
	}

	if bestSlot < 0 do return 0, 0, -1, false
	return int(d32.ToInt(w.decorations.x[bestSlot])),
		int(d32.ToInt(w.decorations.y[bestSlot])),
		bestSlot,
		true
}

// Stops at the nearest reachable water tile or hall entrance. If the entrance
// is unavailable, use the closest available hall ring. The return search area
// is not itself a delivery zone: accepting it lets collectors stay at the shore.
// An absent target can require O(world tiles) work; callers must delay retries.
// Stamps and the queue are shared with A*, with no new allocation.
// The search fans out from the unit, so an unlucky collector far from water
// can otherwise walk the whole landmass before giving up. Retry later instead.
COLLECTOR_SEARCH_MAX_EXPANSIONS :: 4096
// Civilian errands are local. A capped search keeps one trapped unit from
// running a world-sized A* while still covering any normal town approach.
CIVILIAN_PATH_EXPANSIONS :: 4096
// Civilians share one staggered decision clock for threat scans, construction
// assignment and work targeting. Movement still runs every update.
CIVILIAN_DECISION_INTERVAL :: d32.ONE
// Idle villagers in peaceful towns update every second instead of every half
// second. Alarms, damage, sleep and conversions wake them immediately.
UNIT_LOD_DORMANT_STRIDE :: 2
// A town with no choppable tree around it shares one retry timer instead of
// every builder rescanning the neighbourhood every decision.
WOOD_SEARCH_RETRY_SECONDS :: 5
WOOD_SEARCH_RETRY_TICKS :: u64(WOOD_SEARCH_RETRY_SECONDS/TOWN_SIMULATION_STEP)
#assert(f64(WOOD_SEARCH_RETRY_TICKS) == WOOD_SEARCH_RETRY_SECONDS/TOWN_SIMULATION_STEP)

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

	scratch := NavBfsReset()
	queue := scratch.queue[:]
	startX := UnitTileX(w, unitSlot)
	startY := UnitTileY(w, unitSlot)
	start := startX*worldHeight+startY
	NavBfsVisit(scratch, start)
	queue[0] = start
	head, tail := 0, 1
	directionOffset := WorldWrapCoordinate(unitSlot+taskSequence, 4)
	expansions := 0
	for head < tail && expansions < COLLECTOR_SEARCH_MAX_EXPANSIONS {
		expansions += 1
		index := queue[head]
		head += 1
		x, y := index/worldHeight, index%worldHeight
		if UnitValidTileType(unit.type, w.groundStorage[index].type) &&
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
				if w.groundStorage[index].type == .River do return x, y, true
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
					tileType := w.groundStorage[sourceX*worldHeight+sourceY].type
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
			if _, fresh := NavBfsVisit(scratch, next); !fresh do continue
			if !WorldTileWalkable(w, x, y, unit.type, unit.kingdome) do continue
			queue[tail] = next
			tail += 1
		}
	}
	// Walkable entrances may belong to a disconnected pocket. In that case,
	// retain a reachable perimeter point instead of stranding the return trip.
	return fallbackX, fallbackY, fallbackFound
}

WATER_SEARCH_RETRY_SECONDS :: 5
WATER_SEARCH_RETRY_TICKS :: u64(WATER_SEARCH_RETRY_SECONDS/TOWN_SIMULATION_STEP)
#assert(f64(WATER_SEARCH_RETRY_TICKS) == WATER_SEARCH_RETRY_SECONDS/TOWN_SIMULATION_STEP)

// Every collector in a town walks to the same shore until the terrain changes,
// so the expensive breadth-first search runs once per town instead of once per
// collector decision.
TownCollectorWaterPoint :: proc(
	w: ^World,
	kingdomSlot, townSlot, unitSlot, taskSequence: int,
) -> (int, int, bool) {
	if !WorldTownExists(w, kingdomSlot, townSlot) do return 0, 0, false
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	if town.waterSourceReady && town.waterSourceRevision == w.terrainRevision {
		return town.waterSourceX, town.waterSourceY, true
	}
	if WorldCurrentTick(w) < town.waterSearchFailUntilTick do return 0, 0, false
	if x, y, found := UnitFindCollectorTarget(w, unitSlot, taskSequence); found {
		town.waterSourceX, town.waterSourceY = x, y
		town.waterSourceReady = true
		town.waterSourceRevision = w.terrainRevision
		return x, y, true
	}
	town.waterSearchFailUntilTick = WorldCurrentTick(w)+WATER_SEARCH_RETRY_TICKS
	return 0, 0, false
}

// Nearest usable ring around the town hall, entrance first. Position-independent,
// so it is cached per town instead of searched from every unit.
TownCollectorReturnPoint :: proc(w: ^World, kingdomSlot, townSlot: int) -> (int, int, bool) {
	if !WorldTownExists(w, kingdomSlot, townSlot) do return 0, 0, false
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	if town.returnPointReady && town.returnPointRevision == w.terrainRevision {
		return town.returnPointX, town.returnPointY, true
	}
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	bestRadius := 9
	bestX, bestY := 0, 0
	entranceX, entranceY := 0, 0
	entranceFound := false
	found := false
	for x in max(0, town.x-8)..=min(worldWidth-1, town.x+11) {
		for y in max(0, town.y-8)..=min(worldHeight-1, town.y+11) {
			if x >= town.x && x < town.x+4 && y >= town.y && y < town.y+4 do continue
			if WorldTileOccupied(w, x, y) do continue
			if !WorldTileWalkable(w, x, y, WaterCollector{}, kingdomSlot) do continue
			if y == town.y+4 && (x == town.x+1 || x == town.x+2) && !entranceFound {
				entranceX, entranceY = x, y
				entranceFound = true
			}
			radius := max(max(town.x-x, x-(town.x+3)), max(town.y-y, y-(town.y+3)))
			if radius > bestRadius do continue
			if radius < bestRadius || !found {
				bestRadius = radius
				bestX, bestY = x, y
				found = true
			}
		}
	}
	if entranceFound {
		bestX, bestY = entranceX, entranceY
	}
	if !found do return 0, 0, false
	town.returnPointX, town.returnPointY = bestX, bestY
	town.returnPointReady = true
	town.returnPointRevision = w.terrainRevision
	return bestX, bestY, true
}

UnitFindFarmlandTarget :: proc(w: ^World, unitSlot, sequence: int) -> (int, int, bool) {
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	kingdomSlot := w.units[unitSlot].kingdome
	townSlot := w.units[unitSlot].town
	if !WorldTownExists(w, kingdomSlot, townSlot) do return 0, 0, false
	unit := &w.units[unitSlot]
	unitPositionX := unit.x
	unitPositionY := unit.y
	worldWidthRaw := i64(w.maxX)*d32.SCALE
	worldHeightRaw := i64(w.maxY)*d32.SCALE
	bestX, bestY := 0, 0
	bestDistanceSquared: u64 = 0
	bestScore: f32 = -1
	foundTarget := false
	seed := u64(unitSlot+sequence*1031)
	// Farmlands always sit inside their town, so only the town's own buckets can
	// hold one. Scanning every building slot here was O(world buildings) per
	// farmer decision.
	minX, maxX, minY, maxY := TownAreaBounds(w, kingdomSlot, townSlot)
	chunkSize := w.spatial.chunkSize
	chunksY := w.spatial.chunksY
	startChunkX := max(0, minX)/chunkSize
	endChunkX := min(max(maxX, 0), worldWidth-1)/chunkSize
	startChunkY := max(0, minY)/chunkSize
	endChunkY := min(max(maxY, 0), worldHeight-1)/chunkSize
	for chunkX in startChunkX..=endChunkX {
		for chunkY in startChunkY..=endChunkY {
			chunk := chunkX*chunksY+chunkY
			for buildingSlot := w.spatial.buildingHead[chunk]; buildingSlot >= 0;
				buildingSlot = w.spatial.buildingNext[buildingSlot] {
				if !w.buildingUsed[buildingSlot] ||
				   w.buildings.kingdom[buildingSlot] != kingdomSlot ||
				   w.buildings.town[buildingSlot] != townSlot {
					continue
				}
				if BuildingKindOf(w.buildings.type[buildingSlot]) != .Farmland do continue

				farmX := w.buildings.x[buildingSlot]
				farmY := w.buildings.y[buildingSlot]
				farmWidth, farmHeight := BuildingTileSize(w.buildings.type[buildingSlot])
				for offsetX in -1..=farmWidth {
					for offsetY in -1..=farmHeight {
						if offsetX >= 0 && offsetX < farmWidth && offsetY >= 0 && offsetY < farmHeight {
							continue
						}
						x := WorldWrapCoordinate(farmX+offsetX, worldWidth)
						y := WorldWrapCoordinate(farmY+offsetY, worldHeight)
						if !UnitValidTileType(unit.type, WorldTileAt(w, x, y).type) do continue
						distanceSquared, validDistance := d32.WrappedDistanceSquared(
							unitPositionX,
							unitPositionY,
							d32.FromInt(i32(x)),
							d32.FromInt(i32(y)),
							worldWidthRaw,
							worldHeightRaw,
						)
						if !validDistance do continue
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
		}
	}
	return bestX, bestY, foundTarget
}

UnitFindHomeTarget :: proc(w: ^World, unitSlot: int) -> (int, int, bool) {
	start := ProfileSectionBegin(.UnitSeek)
	defer ProfileSectionEnd(.UnitSeek, start)
	home := UnitHome(w, unitSlot)
	if home < 0 do return 0, 0, false
	unit := &w.units[unitSlot]
	worldWidth, worldHeight := int(w.maxX), int(w.maxY)
	unitPositionX := unit.x
	unitPositionY := unit.y
	worldWidthRaw := i64(w.maxX)*d32.SCALE
	worldHeightRaw := i64(w.maxY)*d32.SCALE
	tried: [3][3]bool
	// Prefer the nearest ring tile, but try the other entrances if it belongs
	// to a disconnected pocket. Never hide a citizen after a failed path.
	for _ in 0..<8 {
		bestX, bestY, bestOx, bestOy := 0, 0, 0, 0
		bestDistance: u64 = 0
		found := false
		for ox in -1..=1 {
			for oy in -1..=1 {
				if (ox == 0 && oy == 0) || tried[ox+1][oy+1] do continue
				x := WorldWrapCoordinate(w.buildings.x[home]+ox, worldWidth)
				y := WorldWrapCoordinate(w.buildings.y[home]+oy, worldHeight)
				if WorldTileOccupied(w, x, y) || !WorldTileWalkable(w, x, y, unit.type, unit.kingdome) do continue
				distance, validDistance := d32.WrappedDistanceSquared(
					unitPositionX,
					unitPositionY,
					TileCenterPosition(x),
					TileCenterPosition(y),
					worldWidthRaw,
					worldHeightRaw,
				)
				if !validDistance do continue
				if !found || distance < bestDistance {
					bestX, bestY, bestOx, bestOy = x, y, ox, oy
					bestDistance, found = distance, true
				}
			}
		}
		if !found do break
		tried[bestOx+1][bestOy+1] = true
		if AStar(
			w,
			unit.type,
			unit.kingdome,
			UnitTileX(w, unitSlot),
			UnitTileY(w, unitSlot),
			bestX,
			bestY,
			&unit.path,
			CIVILIAN_PATH_EXPANSIONS,
		) {
			// Keep the search: the caller is about to move to this target.
			unit.pathTargetX, unit.pathTargetY = bestX, bestY
			unit.pathRevision = w.pathRevision
			unit.pathReady = true
			unit.pathFound = true
			unit.pathIndex = 1
			if len(unit.path) == 1 do unit.pathIndex = 0
			return bestX, bestY, true
		}
	}
	return 0, 0, false
}

UnitFindTownReturnPoint :: proc(w: ^World, kingdomSlot, townSlot: int, unitSlot := -1) -> (int, int, bool) {
	start := ProfileSectionBegin(.UnitSeek)
	defer ProfileSectionEnd(.UnitSeek, start)
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
				if !UnitValidTileType(Villager{}, WorldTileAt(w, x, y).type) || WorldTileOccupied(w, x, y) do continue
				return x, y, true
			}
		}
	}
	return 0, 0, false
}

UnitMoveToTarget :: proc(w: ^World, unitSlot: int, deltaTime: f32, maxExpansions := 0) -> bool {
	if UnitTileX(w, unitSlot) == w.units[unitSlot].pathTargetX &&
		UnitTileY(w, unitSlot) == w.units[unitSlot].pathTargetY {
		return true
	}
	reached := UnitMove(
		w,
		unitSlot,
		w.units[unitSlot].pathTargetX,
		w.units[unitSlot].pathTargetY,
		deltaTime,
		maxExpansions,
	)
	if !w.units[unitSlot].pathFound do return false
	return reached
}
