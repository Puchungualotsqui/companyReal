package main

import "d32"

WARRIOR_SCAN_INTERVAL :: 0.5
WARRIOR_CASCADE_UNIT_CHANCE :: 0.85
WARRIOR_CASCADE_BUILDING_CHANCE :: 0.75
WARRIOR_HOME_PATROL_RADIUS :: 8
WARRIOR_DEFEND_PATROL_RADIUS :: 12
WARRIOR_PATROL_STEP_RADIUS :: 3
WARRIOR_PATROL_SPEED_RATIO :: d32.Value(55*d32.SCALE/100)
WARRIOR_PATROL_MIN_PAUSE :: 2.0
WARRIOR_ESCORT_CHANCE :: 0.35
WARRIOR_GARRISON_ESCORT_RATIO :: 0.15
WARRIOR_ESCORT_RADIUS :: 30
WARRIOR_BREACH_RADIUS :: 40
WARRIOR_DEFENSE_AREA_FACTOR :: 1.5

// Melee units stop on a ring around their target and keep personal space, so a
// crowd does not collapse into the same few pixels.
MELEE_FAN_SLOTS :: 7
MELEE_FAN_STEP :: 0.18
// MELEE_FAN_STEP as a Q16.16 fraction of a turn.
MELEE_FAN_STEP_TURNS :: d32.Value(1877)
// Raw distance below which the fan direction is treated as zero (~0.001 world units).
MELEE_FAN_MIN_DISTANCE_RAW :: i64(65)
MELEE_SEPARATION_RADIUS :: 2.0
MELEE_SEPARATION_MAX_PUSH :: 0.30

NEUTRAL_GUARD_PATROL_RADIUS :: 5

StateWarriorInit :: proc(unitSlot, kingdomSlot, townSlot: int) -> StateWarrior {
	return StateWarrior{
		activity = .Idle,
		order = WarriorIdle{},
		orderKingdom = -1,
		orderTown = -1,
		target = TargetNone{},
		scanTimer = d32.Mul(
			PositionFromF32(WorldNoiseHash(unitSlot, kingdomSlot+townSlot*101, u64(unitSlot)+601)),
			d32.FromRatio(i32(WARRIOR_SCAN_INTERVAL*10), 10),
		),
		escortTarget = -1,
	}
}

UnitWarriorReset :: proc(w: ^World, unitSlot: int) {
	if !UnitIsWarrior(w.units[unitSlot].type) do return
	w.units[unitSlot].state = StateWarriorInit(
		unitSlot,
		w.units[unitSlot].kingdome,
		w.units[unitSlot].town,
	)
}


// Units react to enemies inside their distraction radius, which is usually
// wider than the radius that reveals fog for the player.
UnitUpdateWarrior :: proc(w: ^World, unitSlot: int, deltaTime: f32) {
	unit := &w.units[unitSlot]
	if !UnitIsWarrior(unit.type) do return
	state := &unit.state.(StateWarrior)

	kingdomSlot := unit.kingdome
	townSlot := unit.town
	if !WorldTownExists(w, kingdomSlot, townSlot) {
		state.target = TargetNone{}
		return
	}
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	if state.orderKingdom != kingdomSlot || state.orderTown != townSlot ||
		state.orderRevision != town.orderRevision {
		assignStamp := ProfilerBegin("Warrior:Assign")
		UnitWarriorAssignOrder(w, unitSlot, state)
		ProfilerEnd(assignStamp)
	}

	if state.retreating {
		state.target = TargetNone{}
		state.activity = .Moving
		travelStamp := ProfilerBegin("Warrior:Travel")
		arrived := UnitWarriorTravel(w, unitSlot, kingdomSlot, townSlot, deltaTime)
		ProfilerEnd(travelStamp)
		if arrived == .Arrived {
			state.retreating = false
			state.orderKingdom = -1
			unit.pathReady = false
		}
		return
	}

	if !WarriorFocusValid(w, unitSlot, state) {
		state.target = TargetNone{}
	}

	state.scanTimer = d32.Sub(state.scanTimer, PositionFromF32(deltaTime))
	if state.scanTimer <= d32.ZERO {
		jitter := 0.75+WorldNoiseHash(unitSlot, state.scanSequence, u64(kingdomSlot)+911)*0.5
		state.scanTimer = d32.Mul(
			d32.FromRatio(i32(WARRIOR_SCAN_INTERVAL*10), 10),
			PositionFromF32(jitter),
		)
		if _, isNone := state.target.(TargetNone); isNone {
			focusStamp := ProfilerBegin("Warrior:Focus")
			state.target = WarriorFindFocus(w, unitSlot, state)
			ProfilerEnd(focusStamp)
		}
	}

	if _, isNone := state.target.(TargetNone); !isNone {
		state.activity = .Attacking
		unit.pathReady = false
		engageStamp := ProfilerBegin("Warrior:Engage")
		engaged := UnitWarriorEngage(w, unitSlot, state, deltaTime)
		ProfilerEnd(engageStamp)
		if engaged do return
		state.target = TargetNone{}
	}

	switch order in state.order {
	case WarriorIdle:
		state.activity = .Idle
	case WarriorGarrison:
		patrolRadius := WARRIOR_HOME_PATROL_RADIUS
		if kingdomSlot == NEUTRAL_KINGDOM do patrolRadius = NEUTRAL_GUARD_PATROL_RADIUS
		// Inside the town area the warrior is already home; patrol locally instead
		// of building a world-sized flow field just to walk back to the hall.
		homeRadius := max(patrolRadius*2, town.areaRadius)
		if !UnitWarriorFarFromTown(w, unitSlot, kingdomSlot, townSlot, homeRadius) {
			if kingdomSlot != NEUTRAL_KINGDOM {
				escortStamp := ProfilerBegin("Warrior:Escort")
				escorting := UnitWarriorEscort(w, unitSlot, state, deltaTime)
				ProfilerEnd(escortStamp)
				if escorting do return
			}
			state.activity = .Moving
			patrolStamp := ProfilerBegin("Warrior:Patrol")
			UnitWarriorPatrol(w, unitSlot, kingdomSlot, townSlot, patrolRadius, deltaTime, state)
			ProfilerEnd(patrolStamp)
			return
		}
		state.activity = .Moving
		travelStamp := ProfilerBegin("Warrior:Travel")
		arrived := UnitWarriorTravel(w, unitSlot, kingdomSlot, townSlot, deltaTime)
		ProfilerEnd(travelStamp)
		if arrived == .Arrived {
			unit.pathReady = false
			patrolStamp := ProfilerBegin("Warrior:Patrol")
			UnitWarriorPatrol(w, unitSlot, kingdomSlot, townSlot, patrolRadius, deltaTime, state)
			ProfilerEnd(patrolStamp)
		}
	case WarriorAttack:
		state.activity = .Moving
		travelStamp := ProfilerBegin("Warrior:Travel")
		result := UnitWarriorTravel(w, unitSlot, order.kingdom, order.town, deltaTime)
		ProfilerEnd(travelStamp)
		if result == .Arrived {
			if hall := TownHallSlot(w, order.kingdom, order.town); hall >= 0 {
				state.target = TargetBuilding{slot = hall}
				state.activity = .Attacking
			}
		} else if result == .Unreachable {
			// The town is enclosed. Break the ring: prefer its walls, then any
			// nearby building of that town. If nothing is close enough yet, walk
			// toward the hall until the wall is in breach range.
			breach := WarriorFindBreachBuilding(w, unitSlot, order.kingdom, order.town)
			if breach < 0 do breach = TownHallSlot(w, order.kingdom, order.town)
			if breach >= 0 {
				state.target = TargetBuilding{slot = breach}
				state.activity = .Attacking
			}
		}
	case WarriorDefend:
		// A new order still travels to the hall; once stationed, keep the patrol
		// destination instead of pulling the defender back to the hall each tick.
		if state.patrolSequence == 0 || UnitWarriorFarFromTown(w, unitSlot,
			order.kingdom, order.town, WARRIOR_DEFEND_PATROL_RADIUS*2) {
			state.activity = .Moving
			travelStamp := ProfilerBegin("Warrior:Travel")
			arrived := UnitWarriorTravel(w, unitSlot, order.kingdom, order.town, deltaTime)
			ProfilerEnd(travelStamp)
			if arrived != .Arrived do return
			unit.pathReady = false
			state.patrolSequence = max(1, state.patrolSequence)
		}
		patrolStamp := ProfilerBegin("Warrior:Patrol")
		UnitWarriorPatrol(w, unitSlot, order.kingdom, order.town, WARRIOR_DEFEND_PATROL_RADIUS, deltaTime, state)
		ProfilerEnd(patrolStamp)
	}
}

UnitWarriorAssignOrder :: proc(w: ^World, unitSlot: int, state: ^StateWarrior) {
	unit := &w.units[unitSlot]
	kingdomSlot := unit.kingdome
	townSlot := unit.town
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	previous := state.order

	switch order in previous {
	case WarriorAttack:
		if !WorldTownExists(w, order.kingdom, order.town) ||
			!town.attackOrders[order.kingdom][order.town] {
			state.retreating = true
		}
	case WarriorDefend:
		if !WorldTownExists(w, order.kingdom, order.town) ||
			!town.defendOrders[order.kingdom][order.town] {
			state.retreating = true
		}
	case WarriorIdle, WarriorGarrison:
	}
	newOrder := TownUnitOrder(w, unitSlot)
	if state.retreating do newOrder = WarriorGarrison{}

	state.order = newOrder
	state.orderKingdom = kingdomSlot
	state.orderTown = townSlot
	state.orderRevision = town.orderRevision
	if !WarriorOrderEqual(previous, newOrder) {
		state.target = TargetNone{}
		state.escortTarget = -1
		state.patrolSequence = 0
		unit.pathReady = false
	}
}

// Divide each unit kind independently between the home garrison and the
// town's orders. Rotating the slot order on revisions keeps the selection
// varied while keeping the mix balanced when there are enough units.
TownUnitOrder :: proc(w: ^World, unitSlot: int) -> WarriorOrder {
	unit := &w.units[unitSlot]
	town := &w.kingdoms[unit.kingdome].towns[unit.town]
	if town.orderCount == 0 do return WarriorGarrison{}

	kind := UnitKindOf(unit.type)
	rank, total := 0, 0
	for slot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[slot] do continue
		other := &w.units[slot]
		if other.kingdome != unit.kingdome || other.town != unit.town do continue
		if UnitKindOf(other.type) != kind do continue
		if slot < unitSlot do rank += 1
		total += 1
	}
	seed := u64(unit.kingdome*TOWN_CAPACITY+unit.town)+u64(kind)*101
	revision := int(town.orderRevision%1_000_000)
	rotation := int(WorldNoiseHash(revision, int(kind), seed+1301)*f32(total))
	rank = (rank+rotation)%total
	garrison := int(f32(total)*KingdomTechGarrisonRatio(w, unit.kingdome))
	if rank < garrison do return WarriorGarrison{}

	offset := int(WorldNoiseHash(revision, int(kind), seed+1703)*f32(town.orderCount))
	index := (rank-garrison+offset)%town.orderCount
	switch ref in town.orders[index] {
	case TownAttackOrder:
		return WarriorAttack{kingdom = ref.kingdom, town = ref.town}
	case TownDefendOrder:
		return WarriorDefend{kingdom = ref.kingdom, town = ref.town}
	}
	return WarriorGarrison{}
}

WarriorOrderEqual :: proc(a, b: WarriorOrder) -> bool {
	switch orderA in a {
	case WarriorIdle:
		_, ok := b.(WarriorIdle)
		return ok
	case WarriorGarrison:
		_, ok := b.(WarriorGarrison)
		return ok
	case WarriorAttack:
		orderB, ok := b.(WarriorAttack)
		return ok && orderA.kingdom == orderB.kingdom && orderA.town == orderB.town
	case WarriorDefend:
		orderB, ok := b.(WarriorDefend)
		return ok && orderA.kingdom == orderB.kingdom && orderA.town == orderB.town
	}
	return false
}

// Defense follows every district and wraps across map edges.
TownPointInDefenseArea :: proc(w: ^World, kingdomSlot, townSlot: int, x, y: f32) -> bool {
	if !WorldTownExists(w, kingdomSlot, townSlot) do return false
	width, height := BuildingTileSize(TownHall{})
	halfWidth := i64(width)*(d32.SCALE/2)
	halfHeight := i64(height)*(d32.SCALE/2)
	worldWidthRaw := i64(w.maxX)*d32.SCALE
	worldHeightRaw := i64(w.maxY)*d32.SCALE
	pointX := PositionFromF32(x)
	pointY := PositionFromF32(y)
	for index in 0..<TownAreaCircleCount(w, kingdomSlot, townSlot) {
		circleX, circleY, circleRadius := TownAreaCircle(w, kingdomSlot, townSlot, index)
		centerX := d32.FromRaw(i32(i64(circleX)*d32.SCALE+halfWidth))
		centerY := d32.FromRaw(i32(i64(circleY)*d32.SCALE+halfHeight))
		deltaX, validX := d32.ShortestWrappedDelta(pointX, centerX, worldWidthRaw)
		deltaY, validY := d32.ShortestWrappedDelta(pointY, centerY, worldHeightRaw)
		if !validX || !validY do continue
		excessX := max(0, abs(deltaX)-halfWidth)
		excessY := max(0, abs(deltaY)-halfHeight)
		radiusRaw := UnitRawDistance(f32(circleRadius)*WARRIOR_DEFENSE_AREA_FACTOR)
		if u64(excessX*excessX)+u64(excessY*excessY) <= u64(radiusRaw)*u64(radiusRaw) do return true
	}
	return false
}

WarriorDefenseTown :: proc(w: ^World, unitSlot: int, state: ^StateWarrior) -> (kingdomSlot, townSlot: int, defending: bool) {
	if state.retreating do return -1, -1, false
	switch order in state.order {
	case WarriorGarrison:
		kingdomSlot, townSlot = w.units.kingdome[unitSlot], w.units.town[unitSlot]
	case WarriorDefend:
		kingdomSlot, townSlot = order.kingdom, order.town
	case WarriorIdle, WarriorAttack:
		return -1, -1, false
	}
	return kingdomSlot, townSlot, WorldTownExists(w, kingdomSlot, townSlot)
}

WarriorCanTargetUnit :: proc(w: ^World, unitSlot: int, state: ^StateWarrior, targetSlot: int) -> bool {
	if state.retreating || targetSlot < 0 || targetSlot >= UNIT_CAPACITY || !w.unitUsed[targetSlot] {
		return false
	}
	if UnitHiddenInside(w, targetSlot) do return false
	unit := &w.units[unitSlot]
	target := &w.units[targetSlot]
	if !KingdomAtWar(w, unit.kingdome, target.kingdome) do return false
	if order, attacking := state.order.(WarriorAttack); attacking {
		if !WorldTownExists(w, order.kingdom, order.town) do return false
		return target.kingdome != NEUTRAL_KINGDOM ||
			(order.kingdom == NEUTRAL_KINGDOM && target.town == order.town)
	}
	kingdomSlot, townSlot, defending := WarriorDefenseTown(w, unitSlot, state)
	if !defending ||
		!TownPointInDefenseArea(w, kingdomSlot, townSlot, UnitX(w, unitSlot), UnitY(w, unitSlot)) {
		return false
	}
	if TownPointInDefenseArea(
		w,
		kingdomSlot,
		townSlot,
		UnitX(w, targetSlot),
		UnitY(w, targetSlot),
	) {
		return true
	}

	// An enemy outside the boundary may be hit, but not pursued.
	attackRange := UnitDefaultRange(unit.type)
	if UnitIsMelee(unit.type) do attackRange = max(attackRange, UnitMeleeStandoff(unit.type, target.type))
	attackRangeRaw := UnitRawDistance(attackRange)
	distanceSquared, valid := d32.WrappedDistanceSquared(
		unit.x,
		unit.y,
		target.x,
		target.y,
		i64(w.maxX)*d32.SCALE,
		i64(w.maxY)*d32.SCALE,
	)
	if !valid do return false
	return distanceSquared <= u64(attackRangeRaw)*u64(attackRangeRaw)
}

WarriorCanTargetBuilding :: proc(w: ^World, unitSlot: int, state: ^StateWarrior, buildingSlot: int) -> bool {
	if state.retreating || buildingSlot < 0 || buildingSlot >= BUILDING_CAPACITY || !w.buildingUsed[buildingSlot] {
		return false
	}
	order, attacking := state.order.(WarriorAttack)
	if !attacking || !WorldTownExists(w, order.kingdom, order.town) do return false
	return w.buildings.kingdom[buildingSlot] == order.kingdom &&
		w.buildings.town[buildingSlot] == order.town &&
		KingdomAtWar(w, w.units.kingdome[unitSlot], order.kingdom)
}

WarriorFocusValid :: proc(w: ^World, unitSlot: int, state: ^StateWarrior) -> bool {
	unit := &w.units[unitSlot]
	switch target in state.target {
	case TargetNone:
		return false
	case TargetUnit:
		if !WarriorCanTargetUnit(w, unitSlot, state, target.slot) do return false
		radiusRaw := UnitRawDistance(max(UnitDistraction(unit.type), UnitDefaultRange(unit.type)))
		distanceSquared, valid := d32.WrappedDistanceSquared(
			unit.x,
			unit.y,
			w.units.x[target.slot],
			w.units.y[target.slot],
			i64(w.maxX)*d32.SCALE,
			i64(w.maxY)*d32.SCALE,
		)
		if !valid do return false
		return distanceSquared <= u64(radiusRaw)*u64(radiusRaw)
	case TargetBuilding:
		return WarriorCanTargetBuilding(w, unitSlot, state, target.slot)
	}
	return false
}

WarriorFindFocus :: proc(w: ^World, unitSlot: int, state: ^StateWarrior) -> WarriorTarget {
	unit := &w.units[unitSlot]
	aggro := UnitDistraction(unit.type)
	isAttackOrder := false
	switch _ in state.order {
	case WarriorAttack:
		isAttackOrder = true
	case WarriorGarrison, WarriorDefend, WarriorIdle:
	}

	state.scanSequence += 1
	vision := d32.Mul(
		PositionFromF32(UnitDefaultVision(unit.type, WorldIsNight(w))),
		WorldWeatherVisionFactor(w),
	)
	scanRadius := max(vision, PositionFromF32(aggro), PositionFromF32(UnitDefaultRange(unit.type)))
	nearUnit, unitDistanceSquared, nearBuilding, buildingDistanceSquared :=
		WarriorFindNearbyHostiles(w, unitSlot, state, scanRadius)
	seed := u64(unitSlot)+u64(state.scanSequence)*7919+1307

	if nearUnit >= 0 {
		engageRadiusRaw := UnitRawDistance(max(aggro, UnitDefaultRange(unit.type)))
		if unitDistanceSquared <= u64(engageRadiusRaw)*u64(engageRadiusRaw) do return TargetUnit{slot = nearUnit}
		if isAttackOrder &&
			WorldNoiseHash(unitSlot, state.scanSequence, seed) <
				WARRIOR_CASCADE_UNIT_CHANCE {
			return TargetUnit{slot = nearUnit}
		}
	}
	aggroRaw := UnitRawDistance(aggro)
	if nearBuilding >= 0 && (buildingDistanceSquared <= u64(aggroRaw)*u64(aggroRaw) || isAttackOrder) {
		if WorldNoiseHash(unitSlot, state.scanSequence+1, seed) <
			WARRIOR_CASCADE_BUILDING_CHANCE {
			return TargetBuilding{slot = nearBuilding}
		}
	}
	return TargetNone{}
}

WarriorFindNearbyHostiles :: proc(w: ^World, unitSlot: int, state: ^StateWarrior, radius: d32.Value) -> (nearUnit: int, unitDistanceSquared: u64, nearBuilding: int, buildingDistanceSquared: u64) {
	nearUnit = -1
	nearBuilding = -1
	if radius <= d32.ZERO do return
	radiusRaw := i64(d32.Raw(radius))
	radiusSquared := u64(radiusRaw)*u64(radiusRaw)
	unitDistanceSquared = radiusSquared
	buildingDistanceSquared = radiusSquared

	unit := &w.units[unitSlot]
	worldWidth := f32(w.maxX)
	worldHeight := f32(w.maxY)
	worldWidthRaw := i64(w.maxX)*d32.SCALE
	worldHeightRaw := i64(w.maxY)*d32.SCALE
	unitX := WorldWrapPosition(UnitX(w, unitSlot), worldWidth)
	unitY := WorldWrapPosition(UnitY(w, unitSlot), worldHeight)
	chunkSize := w.spatial.chunkSize
	if chunkSize <= 0 do return

	centerChunkX := int(unitX)/chunkSize
	centerChunkY := int(unitY)/chunkSize
	chunkRadius := int(d32.ToInt(radius))/chunkSize+1
	for offsetX in -chunkRadius..=chunkRadius {
		chunkX := WorldWrapCoordinate(centerChunkX+offsetX, w.spatial.chunksX)
		for offsetY in -chunkRadius..=chunkRadius {
			chunkY := WorldWrapCoordinate(centerChunkY+offsetY, w.spatial.chunksY)
			chunk := chunkX*w.spatial.chunksY+chunkY

			if SpatialChunkHasEnemy(w, chunk, unit.kingdome) {
				for otherSlot := w.spatial.unitHead[chunk]; otherSlot >= 0;
					otherSlot = w.spatial.unitNext[otherSlot] {
					if otherSlot == unitSlot do continue
					if !WarriorCanTargetUnit(w, unitSlot, state, otherSlot) do continue
					distanceSquared, valid := d32.WrappedDistanceSquared(
						unit.x,
						unit.y,
						w.units.x[otherSlot],
						w.units.y[otherSlot],
						worldWidthRaw,
						worldHeightRaw,
					)
					if !valid do continue
					if distanceSquared < unitDistanceSquared || (distanceSquared == unitDistanceSquared && nearUnit >= 0 && otherSlot < nearUnit) {
						unitDistanceSquared = distanceSquared
						nearUnit = otherSlot
					}
				}
			}

			// Chunks that only hold this kingdom's own buildings cannot contain a
			// target, and most warriors stand in their own town.
			ownBit := u8(1)<<u8(clamp(unit.kingdome, 0, KINGDOMS_CAPACITY-1))
			if SpatialChunkBuildingPresent(w, chunk) &~ ownBit == 0 do continue
			for buildingSlot := w.spatial.buildingHead[chunk]; buildingSlot >= 0;
				buildingSlot = w.spatial.buildingNext[buildingSlot] {
				if !WarriorCanTargetBuilding(w, unitSlot, state, buildingSlot) do continue
				distanceSquared, _, _ := WarriorBuildingNearestPointSquared(w, unitX, unitY, buildingSlot)
				if distanceSquared < buildingDistanceSquared || (distanceSquared == buildingDistanceSquared && nearBuilding >= 0 && buildingSlot < nearBuilding) {
					buildingDistanceSquared = distanceSquared
					nearBuilding = buildingSlot
				}
			}
		}
	}
	return
}

// Returns the squared raw distance from a point to the building footprint, plus
// the nearest point on the footprint (used as the approach target).
WarriorBuildingNearestPointSquared :: proc(w: ^World, x, y: f32, buildingSlot: int) -> (distanceSquared: u64, nearestX: f32, nearestY: f32) {
	worldWidthRaw := i64(w.maxX)*d32.SCALE
	worldHeightRaw := i64(w.maxY)*d32.SCALE
	width, height := BuildingTileSize(w.buildings[buildingSlot].type)
	halfWidth := i64(width)*(d32.SCALE/2)
	halfHeight := i64(height)*(d32.SCALE/2)
	centerX := i64(w.buildings.x[buildingSlot])*d32.SCALE+halfWidth
	centerY := i64(w.buildings.y[buildingSlot])*d32.SCALE+halfHeight

	deltaX, _ := d32.ShortestWrappedDelta(d32.FromRaw(i32(centerX)), PositionFromF32(x), worldWidthRaw)
	deltaY, _ := d32.ShortestWrappedDelta(d32.FromRaw(i32(centerY)), PositionFromF32(y), worldHeightRaw)
	clampedX := clamp(deltaX, -halfWidth, halfWidth)
	clampedY := clamp(deltaY, -halfHeight, halfHeight)
	nearestRawX, _ := d32.WrapRaw(centerX+clampedX, d32.ZERO, worldWidthRaw)
	nearestRawY, _ := d32.WrapRaw(centerY+clampedY, d32.ZERO, worldHeightRaw)
	nearestX = PositionToF32(nearestRawX)
	nearestY = PositionToF32(nearestRawY)
	excessX := deltaX-clampedX
	excessY := deltaY-clampedY
	distanceSquared = u64(excessX*excessX)+u64(excessY*excessY)
	return
}

// When a town is fully enclosed, the flow field cannot reach it. This finds the
// nearest piece of the ring to break: first a wall, then any other building of
// the target town, and only last the hall itself.
WarriorFindBreachBuilding :: proc(w: ^World, unitSlot, targetKingdom, targetTown: int) -> int {
	unit := &w.units[unitSlot]
	chunkSize := w.spatial.chunkSize
	if chunkSize <= 0 do return -1
	if !KingdomAtWar(w, unit.kingdome, targetKingdom) do return -1

	centerChunkX := UnitTileX(w, unitSlot)/chunkSize
	centerChunkY := UnitTileY(w, unitSlot)/chunkSize
	chunkRadius := int(WARRIOR_BREACH_RADIUS)/chunkSize+1
	bestWall := -1
	breachRadiusRaw := UnitRawDistance(WARRIOR_BREACH_RADIUS)
	breachRadiusSquared := u64(breachRadiusRaw)*u64(breachRadiusRaw)
	bestWallDistanceSquared := breachRadiusSquared
	bestBuilding := -1
	bestBuildingDistanceSquared := breachRadiusSquared
	bestHall := -1
	bestHallDistanceSquared := breachRadiusSquared

	for offsetX in -chunkRadius..=chunkRadius {
		chunkX := WorldWrapCoordinate(centerChunkX+offsetX, w.spatial.chunksX)
		for offsetY in -chunkRadius..=chunkRadius {
			chunkY := WorldWrapCoordinate(centerChunkY+offsetY, w.spatial.chunksY)
			chunk := chunkX*w.spatial.chunksY+chunkY
			for buildingSlot := w.spatial.buildingHead[chunk]; buildingSlot >= 0;
				buildingSlot = w.spatial.buildingNext[buildingSlot] {
				if !w.buildingUsed[buildingSlot] do continue
				if w.buildings.kingdom[buildingSlot] != targetKingdom do continue
				if w.buildings.town[buildingSlot] != targetTown do continue

				distanceSquared, _, _ := WarriorBuildingNearestPointSquared(
					w,
					UnitX(w, unitSlot),
					UnitY(w, unitSlot),
					buildingSlot,
				)
				if distanceSquared > breachRadiusSquared do continue
				kind := BuildingKindOf(w.buildings[buildingSlot].type)
				switch kind {
				case .Wall:
					if distanceSquared < bestWallDistanceSquared {
						bestWallDistanceSquared = distanceSquared
						bestWall = buildingSlot
					}
				case .TownHall:
					if distanceSquared < bestHallDistanceSquared {
						bestHallDistanceSquared = distanceSquared
						bestHall = buildingSlot
					}
				case .Home, .Farmland, .Bridge, .Cannon, .Watchtower, .ArcheryRange, .MagicSchool, .GiantPen, .SiegeWorkshop, .TurtlePen, .ThievesGuild, .Path, .DistrictHall, .GiantMortar, .Harbor, .Granary, .AlchemistWorkshop, .FireworksGuild, .StarfallSpire:
					if distanceSquared < bestBuildingDistanceSquared {
						bestBuildingDistanceSquared = distanceSquared
						bestBuilding = buildingSlot
					}
				}
			}
		}
	}

	if bestWall >= 0 do return bestWall
	if bestBuilding >= 0 do return bestBuilding
	return bestHall
}

UnitWarriorEngage :: proc(w: ^World, unitSlot: int, state: ^StateWarrior, deltaTime: f32) -> bool {
	unit := &w.units[unitSlot]
	targetX, targetY: f32
	distanceSquared: u64
	switch target in state.target {
	case TargetNone:
		return false
	case TargetUnit:
		if !WarriorCanTargetUnit(w, unitSlot, state, target.slot) do return false
		targetX = UnitX(w, target.slot)
		targetY = UnitY(w, target.slot)
		distanceSquared, _ = d32.WrappedDistanceSquared(
			w.units.x[unitSlot],
			w.units.y[unitSlot],
			w.units.x[target.slot],
			w.units.y[target.slot],
			i64(w.maxX)*d32.SCALE,
			i64(w.maxY)*d32.SCALE,
		)
	case TargetBuilding:
		if !WarriorCanTargetBuilding(w, unitSlot, state, target.slot) do return false
		distanceSquared, targetX, targetY =
			WarriorBuildingNearestPointSquared(w, UnitX(w, unitSlot), UnitY(w, unitSlot), target.slot)
	}

	attackRange := UnitDefaultRange(unit.type)
	moveX, moveY := targetX, targetY
	if unitTarget, ok := state.target.(TargetUnit); ok && UnitIsMelee(unit.type) {
		standoff := UnitMeleeStandoff(unit.type, w.units[unitTarget.slot].type)
		attackRange = max(attackRange, standoff)
		meleeRangeRaw := UnitRawDistance(attackRange)
		if distanceSquared > u64(meleeRangeRaw)*u64(meleeRangeRaw) {
			worldWidthRaw := i64(w.maxX)*d32.SCALE
			worldHeightRaw := i64(w.maxY)*d32.SCALE
			targetPositionX := w.units.x[unitTarget.slot]
			targetPositionY := w.units.y[unitTarget.slot]
			dirX, validX := d32.ShortestWrappedDelta(
				targetPositionX,
				w.units.x[unitSlot],
				worldWidthRaw,
			)
			dirY, validY := d32.ShortestWrappedDelta(
				targetPositionY,
				w.units.y[unitSlot],
				worldHeightRaw,
			)
			length := d32.SqrtRaw(u64(dirX*dirX+dirY*dirY))
			if validX && validY && length > MELEE_FAN_MIN_DISTANCE_RAW {
				directionX := d32.Div(d32.FromRaw(i32(dirX)), d32.FromRaw(i32(length)))
				directionY := d32.Div(d32.FromRaw(i32(dirY)), d32.FromRaw(i32(length)))
				fanSlot := (unitSlot+unitTarget.slot)%MELEE_FAN_SLOTS
				fanTurns := d32.Mul(d32.FromInt(i32(fanSlot-MELEE_FAN_SLOTS/2)), MELEE_FAN_STEP_TURNS)
				sine, cosine := d32.SinCos(fanTurns)
				rotatedX := d32.Sub(d32.Mul(directionX, cosine), d32.Mul(directionY, sine))
				rotatedY := d32.Add(d32.Mul(directionX, sine), d32.Mul(directionY, cosine))
				standoffValue := PositionFromF32(standoff)
				offsetX := d32.Mul(rotatedX, standoffValue)
				offsetY := d32.Mul(rotatedY, standoffValue)
				movePositionX, movedX := d32.AddRawWrapped(
					i64(d32.Raw(targetPositionX)),
					i64(d32.Raw(offsetX)),
					d32.ZERO,
					worldWidthRaw,
				)
				movePositionY, movedY := d32.AddRawWrapped(
					i64(d32.Raw(targetPositionY)),
					i64(d32.Raw(offsetY)),
					d32.ZERO,
					worldHeightRaw,
				)
				if movedX && movedY {
					moveX = PositionToF32(movePositionX)
					moveY = PositionToF32(movePositionY)
				}
				// A wall can block the chosen slot; fall back to the target rather
				// than dropping the chase, then separation pushes the bodies apart.
				if !WorldTileWalkable(w, int(moveX), int(moveY), unit.type, unit.kingdome) {
					moveX = targetX
					moveY = targetY
				}
			}
		}
	}

	rangeRaw := UnitRawDistance(attackRange)
	if distanceSquared > u64(rangeRaw)*u64(rangeRaw) {
		speed := UnitDefaultSpeed(unit.type)
		if unit.effects[.NoWater] do speed = d32.Mul(speed, d32.FromRatio(7, 10))
		kingdomSlot, townSlot, defending := WarriorDefenseTown(w, unitSlot, state)
		if defending {
			worldWidthRaw := i64(w.maxX)*d32.SCALE
			worldHeightRaw := i64(w.maxY)*d32.SCALE
			dx, validX := d32.ShortestWrappedDelta(
				w.units.x[unitSlot],
				PositionFromF32(moveX),
				worldWidthRaw,
			)
			dy, validY := d32.ShortestWrappedDelta(
				w.units.y[unitSlot],
				PositionFromF32(moveY),
				worldHeightRaw,
			)
			if !validX || !validY do return false
			length := d32.SqrtRaw(u64(dx*dx+dy*dy))
			if length <= UNIT_POSITION_EPSILON_RAW do return false
			step := min(length, i64(d32.Raw(d32.Mul(speed, PositionFromF32(deltaTime)))))
			nextX, _ := d32.AddRawWrapped(
				i64(d32.Raw(w.units.x[unitSlot])),
				dx*step/length,
				d32.ZERO,
				worldWidthRaw,
			)
			nextY, _ := d32.AddRawWrapped(
				i64(d32.Raw(w.units.y[unitSlot])),
				dy*step/length,
				d32.ZERO,
				worldHeightRaw,
			)
			if !TownPointInDefenseArea(w, kingdomSlot, townSlot, PositionToF32(nextX), PositionToF32(nextY)) {
				return false
			}
		}
		_, blocked, _ := UnitStepTowards(w, unitSlot, moveX, moveY, d32.Mul(speed, PositionFromF32(deltaTime)))
		return !blocked
	}

	unit.cooldown = max(d32.Sub(unit.cooldown, PositionFromF32(deltaTime)), d32.ZERO)
	if unit.cooldown <= d32.ZERO {
		WarriorSwing(w, unitSlot, state)
		unit.cooldown = UnitDefaultCooldown(unit.type)
	}
	return true
}

// Melee attackers are pushed out of each other's bodies after movement. Each
// unit only moves itself, which keeps the pass cheap and avoids re-linking the
// spatial index while it is being walked.
WorldMeleeSeparation :: proc(w: ^World) {
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	chunkSize := w.spatial.chunkSize
	if worldWidth <= 0 || worldHeight <= 0 || chunkSize <= 0 ||
		w.spatial.chunksX <= 0 || w.spatial.chunksY <= 0 {
		return
	}
	width := i64(worldWidth)*d32.SCALE
	height := i64(worldHeight)*d32.SCALE
	worldWidthF := f32(worldWidth)
	worldHeightF := f32(worldHeight)
	separationRadius := i64(d32.Raw(PositionFromF32(MELEE_SEPARATION_RADIUS)))
	separationSquared := u64(separationRadius)*u64(separationRadius)
	maxPush := i64(d32.Raw(PositionFromF32(MELEE_SEPARATION_MAX_PUSH)))
	bodyGap := i64(d32.Raw(PositionFromF32(UNIT_BODY_GAP)))

	for slot in 0 ..< UNIT_CAPACITY {
		if !w.unitUsed[slot] do continue
		unit := &w.units[slot]
		if unit.type == nil || !UnitIsMelee(unit.type) do continue
		state, isWarrior := unit.state.(StateWarrior)
		if !isWarrior || state.activity != .Attacking do continue

		x, validX := d32.WrapRaw(i64(d32.Raw(unit.x)), d32.ZERO, width)
		y, validY := d32.WrapRaw(i64(d32.Raw(unit.y)), d32.ZERO, height)
		if !validX || !validY do continue
		unitRadius := i64(d32.Raw(PositionFromF32(UnitBodyRadius(unit.type))))
		firstX, countX := UnitNearbyChunkRange(
			PositionToF32(x),
			MELEE_SEPARATION_RADIUS,
			worldWidthF,
			chunkSize,
			w.spatial.chunksX,
		)
		firstY, countY := UnitNearbyChunkRange(
			PositionToF32(y),
			MELEE_SEPARATION_RADIUS,
			worldHeightF,
			chunkSize,
			w.spatial.chunksY,
		)
		pushX: i64
		pushY: i64
		for offsetX in 0 ..< countX {
			chunkX := WorldWrapCoordinate(firstX+offsetX, w.spatial.chunksX)
			for offsetY in 0 ..< countY {
				chunkY := WorldWrapCoordinate(firstY+offsetY, w.spatial.chunksY)
				chunk := chunkX*w.spatial.chunksY+chunkY
				for other := w.spatial.unitHead[chunk]; other >= 0;
					other = w.spatial.unitNext[other] {
					if other == slot || !w.unitUsed[other] || w.units[other].health <= d32.ZERO {
						continue
					}
					otherUnit := &w.units[other]
					if otherUnit.type == nil do continue

					deltaX, validDeltaX := d32.ShortestWrappedDelta(x, otherUnit.x, width)
					deltaY, validDeltaY := d32.ShortestWrappedDelta(y, otherUnit.y, height)
					if !validDeltaX || !validDeltaY do continue
					distanceSquared := u64(deltaX*deltaX)+u64(deltaY*deltaY)
					if distanceSquared >= separationSquared do continue
					if UnitHiddenInside(w, other) do continue

					minDistance := unitRadius+bodyGap+
						i64(d32.Raw(PositionFromF32(UnitBodyRadius(otherUnit.type))))
					if distanceSquared >= u64(minDistance*minDistance) do continue

					distance := d32.SqrtRaw(distanceSquared)
					if distance <= UNIT_POSITION_EPSILON_RAW {
						turns := d32.FromRatio(
							i32(WorldNoiseHashInt(slot, other, 0x5E9A)),
							1_000_000,
						)
						sine, cosine := d32.SinCos(turns)
						deltaX = i64(d32.Raw(cosine))
						deltaY = i64(d32.Raw(sine))
						distance = d32.SCALE
					}
					overlap := minDistance-distance
					pushX += deltaX*overlap/(2*distance)
					pushY += deltaY*overlap/(2*distance)
				}
			}
		}
		if pushX == 0 && pushY == 0 do continue

		pushLength := d32.SqrtRaw(u64(pushX*pushX)+u64(pushY*pushY))
		if pushLength > maxPush {
			pushX = pushX*maxPush/pushLength
			pushY = pushY*maxPush/pushLength
		}
		newX, validNewX := d32.AddRawWrapped(i64(d32.Raw(x)), pushX, d32.ZERO, width)
		newY, validNewY := d32.AddRawWrapped(i64(d32.Raw(y)), pushY, d32.ZERO, height)
		if !validNewX || !validNewY do continue
		kingdomSlot, townSlot, defending := WarriorDefenseTown(w, slot, &state)
		if defending && !TownPointInDefenseArea(
			w,
			kingdomSlot,
			townSlot,
			PositionToF32(newX),
			PositionToF32(newY),
		) {
			continue
		}
		if !WorldTileWalkable(
			w,
			int(d32.ToInt(newX)),
			int(d32.ToInt(newY)),
			unit.type,
			unit.kingdome,
		) {
			continue
		}
		SetUnitPosition(w, slot, newX, newY)
		SpatialUnitMove(w, slot)
	}
}

WarriorSwing :: proc(w: ^World, unitSlot: int, state: ^StateWarrior) {
	#assert(TOWN_SIMULATION_STEP*4 == 1)
	// The swing can hit other units, buildings and decorations, all of which are
	// shared with the other workers running this tick.
	RecursiveLockGuard(&w.unitMutex)
	unit := &w.units[unitSlot]
	damage := d32.Mul(
		UnitDefaultDamage(unit.type),
		KingdomTechWarriorDamageMultiplier(w, unit.kingdome, UnitKindOf(unit.type)),
	)
	if unit.effects[.Poisoned] do damage = d32.Mul(damage, d32.FromRatio(85, 100))
	areaRadius := UnitDefaultAreaRadius(unit.type)
	switch target in state.target {
	case TargetNone:
	case TargetUnit:
		if target.slot < 0 || target.slot >= UNIT_CAPACITY || !w.unitUsed[target.slot] do return
		if UnitHiddenInside(w, target.slot) do return
			impactX := UnitX(w, target.slot)
			impactY := UnitY(w, target.slot)
		UnitAttackBurst(w, unitSlot, impactX, impactY)
		if areaRadius > d32.ZERO {
			WarriorAreaUnitDamage(w, unitSlot, state, impactX, impactY, areaRadius, damage)
			WorldDecorationAreaDamage(w, impactX, impactY, areaRadius, damage)
		} else {
			UnitApplyDamage(w, target.slot, damage, UnitX(w, unitSlot), UnitY(w, unitSlot), .Melee)
		}
	case TargetBuilding:
		if target.slot < 0 || target.slot >= BUILDING_CAPACITY || !w.buildingUsed[target.slot] {
			return
		}
		building := &w.buildings[target.slot]
		if building.kingdom == w.observerKingdom && building.town >= 0 && building.town < TOWN_CAPACITY {
			width, height := BuildingTileSize(building.type)
			WorldAlertAdd(
				w,
				.UnderAttack,
				building.kingdom,
				building.town,
				unit.kingdome,
				f32(building.x)+f32(width)*0.5,
				f32(building.y)+f32(height)*0.5,
			)
		}
		_, impactX, impactY := WarriorBuildingNearestPointSquared(
			w,
			UnitX(w, unitSlot),
			UnitY(w, unitSlot),
			target.slot,
		)
		UnitAttackBurst(w, unitSlot, impactX, impactY)
		BuildingHitBurst(w, target.slot, impactX, impactY)
		buildingDamage := d32.Mul(
			damage,
			KingdomTechSiegeDamageMultiplier(w, unit.kingdome, UnitKindOf(unit.type)),
		)
		w.buildings[target.slot].health = d32.Sub(w.buildings[target.slot].health, buildingDamage)
		if w.buildings[target.slot].health <= d32.ZERO {
			kind := BuildingKindOf(w.buildings[target.slot].type)
			wasBurning := BuildingOnFire(w, target.slot)
			// Burning rubble can set the surroundings alight after a siege.
			if !BuildingImmuneToFire(kind) &&
				WorldNoiseHash(target.slot, int(WorldCurrentTick(w)), 0xF12E) < 0.35 {
				WorldFireIgnite(w, impactX, impactY, 1)
			}
			BuildingSpawnDebris(w, target.slot, wasBurning)
			BuildingDestroyedBurst(w, target.slot)
			BuildingDespawn(w, target.slot, unit.kingdome)
			state.target = TargetNone{}
		}
		if areaRadius > d32.ZERO {
			WarriorAreaUnitDamage(w, unitSlot, state, impactX, impactY, areaRadius, damage)
			WorldDecorationAreaDamage(w, impactX, impactY, areaRadius, damage)
		}
	}
}

WarriorAreaUnitDamage :: proc(w: ^World, attackerSlot: int, state: ^StateWarrior, x, y: f32, radius: d32.Value, damage: d32.Value) {
	if radius <= d32.ZERO do return
	worldWidth := f32(w.maxX)
	worldHeight := f32(w.maxY)
	chunkSize := w.spatial.chunkSize
	if chunkSize <= 0 do return

	centerX := WorldWrapPosition(x, worldWidth)
	centerY := WorldWrapPosition(y, worldHeight)
	centerPositionX := PositionFromF32(centerX)
	centerPositionY := PositionFromF32(centerY)
	radiusRaw := i64(d32.Raw(radius))
	radiusSquared := u64(radiusRaw)*u64(radiusRaw)
	worldWidthRaw := i64(w.maxX)*d32.SCALE
	worldHeightRaw := i64(w.maxY)*d32.SCALE
	centerChunkX := int(centerX)/chunkSize
	centerChunkY := int(centerY)/chunkSize
	chunkRadius := int(d32.ToInt(radius))/chunkSize+1
	for offsetX in -chunkRadius..=chunkRadius {
		chunkX := WorldWrapCoordinate(centerChunkX+offsetX, w.spatial.chunksX)
		for offsetY in -chunkRadius..=chunkRadius {
			chunkY := WorldWrapCoordinate(centerChunkY+offsetY, w.spatial.chunksY)
			chunk := chunkX*w.spatial.chunksY+chunkY
			slot := w.spatial.unitHead[chunk]
			for slot >= 0 {
				next := w.spatial.unitNext[slot]
				if slot != attackerSlot && WarriorCanTargetUnit(w, attackerSlot, state, slot) {
					distanceSquared, valid := d32.WrappedDistanceSquared(
						w.units.x[slot],
						w.units.y[slot],
						centerPositionX,
						centerPositionY,
						worldWidthRaw,
						worldHeightRaw,
					)
					if valid && distanceSquared <= radiusSquared {
						UnitApplyDamage(w, slot, damage, centerX, centerY, .Area)
					}
				}
				slot = next
			}
		}
	}
}

// Full-world flow fields are excellent for large shared marches, but they are
// far too expensive for a single unit walking back to a nearby town.
WARRIOR_LOCAL_PATH_DISTANCE :: 64
WARRIOR_LOCAL_PATH_EXPANSIONS :: 1024

UnitWarriorTravel :: proc(w: ^World, unitSlot, kingdomSlot, townSlot: int, deltaTime: f32) -> FlowFollowResult {
	if !WorldTownExists(w, kingdomSlot, townSlot) do return .Unreachable
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	unit := &w.units[unitSlot]
	townCenterX := d32.FromInt(i32(town.x+2))
	townCenterY := d32.FromInt(i32(town.y+2))
	distanceSquared, valid := d32.WrappedDistanceSquared(
		unit.x,
		unit.y,
		townCenterX,
		townCenterY,
		i64(w.maxX)*d32.SCALE,
		i64(w.maxY)*d32.SCALE,
	)
	localDistanceRaw := i64(WARRIOR_LOCAL_PATH_DISTANCE)*d32.SCALE
	if valid && distanceSquared <= u64(localDistanceRaw)*u64(localDistanceRaw) {
		localStamp := ProfilerBegin("Warrior:TravelLocal")
		reached := UnitMoveToTarget(
			w,
			unitSlot,
			deltaTime,
			WARRIOR_LOCAL_PATH_EXPANSIONS,
		)
		ProfilerEnd(localStamp)
		if reached do return .Arrived
		if !unit.pathFound do return .Unreachable
		return .Travelling
	}

	fieldStamp := ProfilerBegin("Warrior:TravelField")
	defer ProfilerEnd(fieldStamp)
	field, ready := FlowFieldGet(
		w,
		kingdomSlot,
		townSlot,
		unit.type,
		unit.kingdome,
	)
	if ready do return UnitFollowFlowField(w, unitSlot, field, deltaTime)
	if field != nil && field.building {
		// The shared field is built a little each tick. Walk straight toward the
		// hall meanwhile instead of running an A* burst for every warrior.
		speed := UnitMoveSpeed(w, unitSlot, UnitDefaultSpeed(unit.type))
		reached, _, _ := UnitStepTowards(
			w,
			unitSlot,
			TileCenterRaw(town.x+2),
			TileCenterRaw(town.y+2),
			d32.Mul(speed, PositionFromF32(deltaTime)),
		)
		if reached do return .Arrived
		return .Travelling
	}
	return .Unreachable
}

UnitWarriorFarFromTown :: proc(w: ^World, unitSlot, kingdomSlot, townSlot: int, radius: int = WARRIOR_HOME_PATROL_RADIUS*2) -> bool {
	if !WorldTownExists(w, kingdomSlot, townSlot) do return false
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	unit := &w.units[unitSlot]
	distanceSquared, valid := d32.WrappedDistanceSquared(
		unit.x,
		unit.y,
		d32.FromInt(i32(town.x+2)),
		d32.FromInt(i32(town.y+2)),
		i64(w.maxX)*d32.SCALE,
		i64(w.maxY)*d32.SCALE,
	)
	if !valid do return false
	maxDistanceRaw := i64(radius)*d32.SCALE
	return distanceSquared > u64(maxDistanceRaw)*u64(maxDistanceRaw)
}

// Each warrior has a staggered 6-9 second patrol cycle. patrolSequence records
// the next eligible cycle, leaving scanTimer and the combat cooldown independent.
// Reserving the first two seconds of every cycle guarantees a pause after arrival,
// blockage or a failed target search, even when a walk crosses a cycle boundary.
WarriorPatrolCycle :: proc(w: ^World, unitSlot: int) -> (cycle: int, mayStart: bool) {
	period := 6+WorldNoiseHash(unitSlot, 0, 0x1D1E)*3
	phase := WorldNoiseHash(unitSlot, 1, 0x1D1E)*period
	clock := w.simulationTime+phase
	cycle = int(clock/period)
	mayStart = clock-f32(cycle)*period >= WARRIOR_PATROL_MIN_PAUSE
	return
}

UnitWarriorPatrol :: proc(w: ^World, unitSlot, kingdomSlot, townSlot, radius: int, deltaTime: f32, state: ^StateWarrior) {
	unit := &w.units[unitSlot]
	cycle, mayStart := WarriorPatrolCycle(w, unitSlot)
	state.activity = .Idle
	if !unit.pathReady {
		if !mayStart || state.patrolSequence > cycle do return
		state.patrolSequence = cycle+1
		x, y, found := UnitFindPatrolTarget(
			w,
			unitSlot,
			kingdomSlot,
			townSlot,
			radius,
			state.patrolSequence,
			WARRIOR_PATROL_STEP_RADIUS,
		)
		if !found do return
		unit.pathTargetX = x
		unit.pathTargetY = y
		unit.pathReady = true
	}

	state.activity = .Moving
	speed := d32.Mul(UnitDefaultSpeed(unit.type), WARRIOR_PATROL_SPEED_RATIO)
	if unit.effects[.NoWater] do speed = d32.Mul(speed, d32.FromRatio(7, 10))
		reached, blocked, _ := UnitStepTowards(
		w,
		unitSlot,
		TileCenterRaw(unit.pathTargetX),
		TileCenterRaw(unit.pathTargetY),
		d32.Mul(speed, PositionFromF32(deltaTime)),
	)
	if reached || blocked {
		unit.pathReady = false
		state.patrolSequence = cycle+1
		state.activity = .Idle
	}
}

UnitFindPatrolTarget :: proc(w: ^World, unitSlot, kingdomSlot, townSlot, radius, sequence: int, stepRadius: int = 0) -> (int, int, bool) {
	if !WorldTownExists(w, kingdomSlot, townSlot) do return 0, 0, false
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	centerX := town.x+2
	centerY := town.y+2
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	unit := &w.units[unitSlot]
	sampleRadius := radius
	worldWidthRaw := i64(worldWidth)*d32.SCALE
	worldHeightRaw := i64(worldHeight)*d32.SCALE
	townRawX := d32.FromInt(i32(town.x+2))
	townRawY := d32.FromInt(i32(town.y+2))
	townDistance, townValid := d32.WrappedDistanceSquared(
		unit.x,
		unit.y,
		townRawX,
		townRawY,
		worldWidthRaw,
		worldHeightRaw,
	)
	if !townValid do townDistance = 0
	radiusRaw := i64(radius)*d32.SCALE
	radiusSquared := u64(radiusRaw)*u64(radiusRaw)
	if stepRadius > 0 {
		centerX = UnitTileX(w, unitSlot)
		centerY = UnitTileY(w, unitSlot)
		sampleRadius = min(radius, stepRadius)
	}
	seed := u64(unitSlot)+u64(sequence)*1031+1709
	for attempt in 0..<16 {
		deltaX := int(WorldNoiseHash(unitSlot, sequence*37+attempt*2, seed+11)*f32(sampleRadius*2+1))-sampleRadius
		deltaY := int(WorldNoiseHash(unitSlot, sequence*37+attempt*2+1, seed+23)*f32(sampleRadius*2+1))-sampleRadius
		if deltaX == 0 && deltaY == 0 do continue
		x := WorldWrapCoordinate(centerX+deltaX, worldWidth)
		y := WorldWrapCoordinate(centerY+deltaY, worldHeight)
		if stepRadius > 0 {
			if deltaX*deltaX+deltaY*deltaY > sampleRadius*sampleRadius do continue
			distance, valid := d32.WrappedDistanceSquared(
				TileCenterPosition(x),
				TileCenterPosition(y),
				townRawX,
				townRawY,
				worldWidthRaw,
				worldHeightRaw,
			)
			if !valid do continue
			// Displaced warriors can take short steps home rather than getting stuck
			// outside the patrol area after a chase or an escort.
			if distance > radiusSquared && distance >= townDistance do continue
		}
		if !UnitValidTileType(w.units[unitSlot].type, WorldTileAt(w, x, y).type) do continue
		if WorldTileOccupied(w, x, y) do continue
		return x, y, true
	}
	return 0, 0, false
}

// Garrison warriors occasionally escort civilians; the moment they receive an
// attack or defend order the escort is dropped.
UnitWarriorEscort :: proc(w: ^World, unitSlot: int, state: ^StateWarrior, deltaTime: f32) -> bool {
	unit := &w.units[unitSlot]
	kingdomSlot := unit.kingdome
	townSlot := unit.town
	if !WorldTownExists(w, kingdomSlot, townSlot) do return false
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	escortDuty := WorldNoiseHash(
		unitSlot,
		int(town.orderRevision%1_000_000),
		u64(kingdomSlot*TOWN_CAPACITY+townSlot)+2203,
	)
	if escortDuty >= WARRIOR_GARRISON_ESCORT_RATIO {
		state.escortTarget = -1
		return false
	}

	target := state.escortTarget
	if target >= 0 && !WarriorEscortValid(w, unitSlot, target) {
		state.escortTarget = -1
		unit.pathReady = false
		target = -1
	}
	if target < 0 {
		state.scanSequence += 1
		seed := u64(unitSlot)+u64(state.scanSequence)*1319+1901
		if WorldNoiseHash(unitSlot, state.scanSequence, seed) < WARRIOR_ESCORT_CHANCE {
			state.escortTarget = UnitFindEscortTarget(w, unitSlot, state.scanSequence)
			target = state.escortTarget
		}
	}
	if target < 0 do return false

	state.activity = .Escorting
	unit.pathReady = false
	x, y, found := UnitFindEscortPosition(w, unitSlot, target, unit.roamSequence)
	if !found do return true
	speed := UnitDefaultSpeed(unit.type)
	if unit.effects[.NoWater] do speed = d32.Mul(speed, d32.FromRatio(7, 10))
	_, blocked, _ := UnitStepTowards(w, unitSlot, TileCenterRaw(x), TileCenterRaw(y), d32.Mul(speed, PositionFromF32(deltaTime)))
	if blocked do unit.roamSequence += 1
	return true
}

WarriorEscortValid :: proc(w: ^World, warriorSlot, targetSlot: int) -> bool {
	if targetSlot < 0 || targetSlot >= UNIT_CAPACITY || !w.unitUsed[targetSlot] {
		return false
	}
	if UnitHiddenInside(w, targetSlot) do return false
	if w.units[targetSlot].kingdome != w.units[warriorSlot].kingdome do return false
	if _, combatBuilder := w.units[targetSlot].type.(CombatBuilder); combatBuilder do return false
	unit := &w.units[warriorSlot]
	if !TownPointInDefenseArea(w, unit.kingdome, unit.town, UnitX(w, warriorSlot), UnitY(w, warriorSlot)) {
		return false
	}
	if !TownPointInDefenseArea(
		w,
		unit.kingdome,
		unit.town,
		UnitX(w, targetSlot),
		UnitY(w, targetSlot),
	) {
		return false
	}
	return !UnitIsWarrior(w.units[targetSlot].type)
}

UnitFindEscortTarget :: proc(w: ^World, warriorSlot, sequence: int) -> int {
	unit := &w.units[warriorSlot]
	kingdomSlot := unit.kingdome
	worldWidth := f32(w.maxX)
	worldHeight := f32(w.maxY)
	worldWidthRaw := i64(w.maxX)*d32.SCALE
	worldHeightRaw := i64(w.maxY)*d32.SCALE
	escortRadiusRaw := i64(WARRIOR_ESCORT_RADIUS)*d32.SCALE
	escortRadiusSquared := u64(escortRadiusRaw)*u64(escortRadiusRaw)
	unitX := WorldWrapPosition(UnitX(w, warriorSlot), worldWidth)
	unitY := WorldWrapPosition(UnitY(w, warriorSlot), worldHeight)
	chunkSize := w.spatial.chunkSize
	if chunkSize <= 0 do return -1

	centerChunkX := int(unitX)/chunkSize
	centerChunkY := int(unitY)/chunkSize
	chunkRadius := WARRIOR_ESCORT_RADIUS/chunkSize+1
	seed := u64(kingdomSlot)+u64(warriorSlot)*101+u64(sequence)*7919
	selectedTarget := -1
	bestScore: f32 = -1
	for offsetX in -chunkRadius..=chunkRadius {
		chunkX := WorldWrapCoordinate(centerChunkX+offsetX, w.spatial.chunksX)
		for offsetY in -chunkRadius..=chunkRadius {
			chunkY := WorldWrapCoordinate(centerChunkY+offsetY, w.spatial.chunksY)
			chunk := chunkX*w.spatial.chunksY+chunkY
			for candidateSlot := w.spatial.unitHead[chunk]; candidateSlot >= 0;
				candidateSlot = w.spatial.unitNext[candidateSlot] {
				if candidateSlot == warriorSlot do continue
				if !WarriorEscortValid(w, warriorSlot, candidateSlot) do continue
				distanceSquared, valid := d32.WrappedDistanceSquared(
					unit.x,
					unit.y,
					w.units.x[candidateSlot],
					w.units.y[candidateSlot],
					worldWidthRaw,
					worldHeightRaw,
				)
				if !valid || distanceSquared > escortRadiusSquared do continue
				score := WorldNoiseHash(warriorSlot, candidateSlot, seed)
				if score > bestScore || (score == bestScore && candidateSlot < selectedTarget) {
					bestScore = score
					selectedTarget = candidateSlot
				}
			}
		}
	}
	return selectedTarget
}

UnitFindEscortPosition :: proc(w: ^World, warriorSlot, targetSlot, sequence: int) -> (int, int, bool) {
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 do return 0, 0, false
	targetX := UnitTileX(w, targetSlot)
	targetY := UnitTileY(w, targetSlot)
	offsetsX := [8]int{0, 1, 1, 1, 0, -1, -1, -1}
	offsetsY := [8]int{-1, -1, 0, 1, 1, 1, 0, -1}
	startDirection := int(WorldNoiseHash(warriorSlot, sequence, u64(targetSlot)+7919)*8)
	for offset in 0..<8 {
		direction := (startDirection+offset)%8
		x := WorldWrapCoordinate(targetX+offsetsX[direction], worldWidth)
		y := WorldWrapCoordinate(targetY+offsetsY[direction], worldHeight)
		unit := &w.units[warriorSlot]
		if !TownPointInDefenseArea(w, unit.kingdome, unit.town, TileCenterRaw(x), TileCenterRaw(y)) do continue
		if !UnitValidTileType(unit.type, WorldTileAt(w, x, y).type) do continue
		if WorldTileOccupied(w, x, y) do continue
		return x, y, true
	}
	return 0, 0, false
}
