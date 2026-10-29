package main

import "core:math"

WARRIOR_SCAN_INTERVAL :: 0.5
WARRIOR_CASCADE_UNIT_CHANCE :: 0.85
WARRIOR_CASCADE_BUILDING_CHANCE :: 0.75
WARRIOR_HOME_PATROL_RADIUS :: 8
WARRIOR_DEFEND_PATROL_RADIUS :: 12
WARRIOR_PATROL_STEP_RADIUS :: 3
WARRIOR_PATROL_SPEED_RATIO :: 0.55
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
		scanTimer = WorldNoiseHash(unitSlot, kingdomSlot+townSlot*101, u64(unitSlot)+601)*
			WARRIOR_SCAN_INTERVAL,
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

	state.scanTimer -= deltaTime
	if state.scanTimer <= 0 {
		jitter := 0.75+WorldNoiseHash(unitSlot, state.scanSequence, u64(kingdomSlot)+911)*0.5
		state.scanTimer = WARRIOR_SCAN_INTERVAL*jitter
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
	halfWidth, halfHeight := f32(width)*0.5, f32(height)*0.5
	for index in 0..<TownAreaCircleCount(w, kingdomSlot, townSlot) {
		circleX, circleY, circleRadius := TownAreaCircle(w, kingdomSlot, townSlot, index)
		dx := math.abs(WorldShortestWrappedDelta(x-f32(circleX)-halfWidth, f32(w.maxX)))
		dy := math.abs(WorldShortestWrappedDelta(y-f32(circleY)-halfHeight, f32(w.maxY)))
		dx = max(0, dx-halfWidth)
		dy = max(0, dy-halfHeight)
		radius := f32(circleRadius)*WARRIOR_DEFENSE_AREA_FACTOR
		if dx*dx+dy*dy <= radius*radius do return true
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
	if !defending || !TownPointInDefenseArea(w, kingdomSlot, townSlot, unit.x, unit.y) do return false
	if TownPointInDefenseArea(w, kingdomSlot, townSlot, target.x, target.y) do return true

	// An enemy outside the boundary may be hit, but not pursued.
	attackRange := UnitDefaultRange(unit.type)
	if UnitIsMelee(unit.type) do attackRange = max(attackRange, UnitMeleeStandoff(unit.type, target.type))
	dx := WorldShortestWrappedDelta(target.x-unit.x, f32(w.maxX))
	dy := WorldShortestWrappedDelta(target.y-unit.y, f32(w.maxY))
	return dx*dx+dy*dy <= attackRange*attackRange
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
		deltaX := WorldShortestWrappedDelta(w.units.x[target.slot]-unit.x, f32(w.maxX))
		deltaY := WorldShortestWrappedDelta(w.units.y[target.slot]-unit.y, f32(w.maxY))
		radius := max(UnitDistraction(unit.type), UnitDefaultRange(unit.type))
		return deltaX*deltaX+deltaY*deltaY <= radius*radius
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
	nearUnit, unitDistance, nearBuilding, buildingDistance :=
		WarriorFindNearbyHostiles(w, unitSlot, state, max(UnitDefaultVision(unit.type, WorldIsNight(w))*WorldWeatherVisionFactor(w), aggro, UnitDefaultRange(unit.type)))
	seed := u64(unitSlot)+u64(state.scanSequence)*7919+1307

	if nearUnit >= 0 {
		if unitDistance <= max(aggro, UnitDefaultRange(unit.type)) do return TargetUnit{slot = nearUnit}
		if isAttackOrder &&
			WorldNoiseHash(unitSlot, state.scanSequence, seed) <
				WARRIOR_CASCADE_UNIT_CHANCE {
			return TargetUnit{slot = nearUnit}
		}
	}
	if nearBuilding >= 0 && (buildingDistance <= aggro || isAttackOrder) {
		if WorldNoiseHash(unitSlot, state.scanSequence+1, seed) <
			WARRIOR_CASCADE_BUILDING_CHANCE {
			return TargetBuilding{slot = nearBuilding}
		}
	}
	return TargetNone{}
}

WarriorFindNearbyHostiles :: proc(w: ^World, unitSlot: int, state: ^StateWarrior, radius: f32) -> (nearUnit: int, unitDistance: f32, nearBuilding: int, buildingDistance: f32) {
	nearUnit = -1
	nearBuilding = -1
	unitDistance = radius
	buildingDistance = radius
	if radius <= 0 do return

	unit := &w.units[unitSlot]
	worldWidth := f32(w.maxX)
	worldHeight := f32(w.maxY)
	unitX := WorldWrapPosition(unit.x, worldWidth)
	unitY := WorldWrapPosition(unit.y, worldHeight)
	chunkSize := w.spatial.chunkSize
	if chunkSize <= 0 do return

	centerChunkX := int(unitX)/chunkSize
	centerChunkY := int(unitY)/chunkSize
	chunkRadius := int(radius)/chunkSize+1
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
					deltaX := WorldShortestWrappedDelta(w.units.x[otherSlot]-unitX, worldWidth)
					deltaY := WorldShortestWrappedDelta(w.units.y[otherSlot]-unitY, worldHeight)
					distance := math.sqrt(deltaX*deltaX+deltaY*deltaY)
					if distance < unitDistance {
						unitDistance = distance
						nearUnit = otherSlot
					}
				}
			}

			for buildingSlot := w.spatial.buildingHead[chunk]; buildingSlot >= 0;
				buildingSlot = w.spatial.buildingNext[buildingSlot] {
				if !WarriorCanTargetBuilding(w, unitSlot, state, buildingSlot) do continue
				distance, _, _ := WarriorBuildingNearestPoint(w, unitX, unitY, buildingSlot)
				if distance < buildingDistance {
					buildingDistance = distance
					nearBuilding = buildingSlot
				}
			}
		}
	}
	return
}

// Returns the distance from a point to the building footprint, plus the
// nearest point on the footprint (used as the approach target).
WarriorBuildingNearestPoint :: proc(w: ^World, x, y: f32, buildingSlot: int) -> (distance: f32, nearestX: f32, nearestY: f32) {
	worldWidth := f32(w.maxX)
	worldHeight := f32(w.maxY)
	buildingX := f32(w.buildings.x[buildingSlot])
	buildingY := f32(w.buildings.y[buildingSlot])
	width, height := BuildingTileSize(w.buildings[buildingSlot].type)
	halfWidth := f32(width)*0.5
	halfHeight := f32(height)*0.5
	centerX := buildingX+halfWidth
	centerY := buildingY+halfHeight

	deltaX := WorldShortestWrappedDelta(x-centerX, worldWidth)
	deltaY := WorldShortestWrappedDelta(y-centerY, worldHeight)
	clampedX := clamp(deltaX, -halfWidth, halfWidth)
	clampedY := clamp(deltaY, -halfHeight, halfHeight)
	nearestX = WorldWrapPosition(centerX+clampedX, worldWidth)
	nearestY = WorldWrapPosition(centerY+clampedY, worldHeight)
	excessX := deltaX-clampedX
	excessY := deltaY-clampedY
	distance = math.sqrt(excessX*excessX+excessY*excessY)
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

	centerChunkX := int(unit.x)/chunkSize
	centerChunkY := int(unit.y)/chunkSize
	chunkRadius := int(WARRIOR_BREACH_RADIUS)/chunkSize+1
	bestWall := -1
	bestWallDistance: f32 = WARRIOR_BREACH_RADIUS
	bestBuilding := -1
	bestBuildingDistance: f32 = WARRIOR_BREACH_RADIUS
	bestHall := -1
	bestHallDistance: f32 = WARRIOR_BREACH_RADIUS

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

				distance, _, _ := WarriorBuildingNearestPoint(w, unit.x, unit.y, buildingSlot)
				if distance > WARRIOR_BREACH_RADIUS do continue
				kind := BuildingKindOf(w.buildings[buildingSlot].type)
				switch kind {
				case .Wall:
					if distance < bestWallDistance {
						bestWallDistance = distance
						bestWall = buildingSlot
					}
				case .TownHall:
					if distance < bestHallDistance {
						bestHallDistance = distance
						bestHall = buildingSlot
					}
				case .Home, .Farmland, .Bridge, .Cannon, .Watchtower, .ArcheryRange, .MagicSchool, .GiantPen, .SiegeWorkshop, .TurtlePen, .ThievesGuild, .Path, .DistrictHall, .GiantMortar, .Harbor, .Granary, .AlchemistWorkshop, .FireworksGuild, .StarfallSpire:
					if distance < bestBuildingDistance {
						bestBuildingDistance = distance
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
	distance: f32
	switch target in state.target {
	case TargetNone:
		return false
	case TargetUnit:
		if !WarriorCanTargetUnit(w, unitSlot, state, target.slot) do return false
		targetX = w.units.x[target.slot]
		targetY = w.units.y[target.slot]
		deltaX := WorldShortestWrappedDelta(targetX-unit.x, f32(w.maxX))
		deltaY := WorldShortestWrappedDelta(targetY-unit.y, f32(w.maxY))
		distance = math.sqrt(deltaX*deltaX+deltaY*deltaY)
	case TargetBuilding:
		if !WarriorCanTargetBuilding(w, unitSlot, state, target.slot) do return false
		distance, targetX, targetY =
			WarriorBuildingNearestPoint(w, unit.x, unit.y, target.slot)
	}

	attackRange := UnitDefaultRange(unit.type)
	moveX, moveY := targetX, targetY
	if unitTarget, ok := state.target.(TargetUnit); ok && UnitIsMelee(unit.type) {
		standoff := UnitMeleeStandoff(unit.type, w.units[unitTarget.slot].type)
		attackRange = max(attackRange, standoff)
		if distance > attackRange {
			dirX := WorldShortestWrappedDelta(unit.x-targetX, f32(w.maxX))
			dirY := WorldShortestWrappedDelta(unit.y-targetY, f32(w.maxY))
			length := math.sqrt(dirX*dirX+dirY*dirY)
			if length > 0.001 {
				angle := math.atan2(dirY, dirX)
				fanSlot := (unitSlot+unitTarget.slot)%MELEE_FAN_SLOTS
				angle += (f32(fanSlot)-f32(MELEE_FAN_SLOTS/2))*MELEE_FAN_STEP
				moveX = WorldWrapPosition(targetX+math.cos(angle)*standoff, f32(w.maxX))
				moveY = WorldWrapPosition(targetY+math.sin(angle)*standoff, f32(w.maxY))
				// A wall can block the chosen slot; fall back to the target rather
				// than dropping the chase, then separation pushes the bodies apart.
				if !WorldTileWalkable(w, int(moveX), int(moveY), unit.type, unit.kingdome) {
					moveX = targetX
					moveY = targetY
				}
			}
		}
	}

	if distance > attackRange {
		speed := UnitDefaultSpeed(unit.type)
		if unit.effects[.NoWater] do speed *= 0.7
		kingdomSlot, townSlot, defending := WarriorDefenseTown(w, unitSlot, state)
		if defending {
			dx := WorldShortestWrappedDelta(moveX-unit.x, f32(w.maxX))
			dy := WorldShortestWrappedDelta(moveY-unit.y, f32(w.maxY))
			length := math.sqrt(dx*dx+dy*dy)
			if length <= 0.0001 do return false
			step := min(length, speed*deltaTime)
			nextX := WorldWrapPosition(unit.x+dx/length*step, f32(w.maxX))
			nextY := WorldWrapPosition(unit.y+dy/length*step, f32(w.maxY))
			if !TownPointInDefenseArea(w, kingdomSlot, townSlot, nextX, nextY) do return false
		}
		_, blocked, _ := UnitStepTowards(w, unitSlot, moveX, moveY, speed*deltaTime)
		return !blocked
	}

	unit.cooldown -= deltaTime
	if unit.cooldown <= 0 {
		WarriorSwing(w, unitSlot, state)
		unit.cooldown = UnitDefaultCooldown(unit.type)
	}
	return true
}

// Melee attackers are pushed out of each other's bodies after movement. Each
// unit only moves itself, which keeps the pass cheap and avoids re-linking the
// spatial index while it is being walked.
WorldMeleeSeparation :: proc(w: ^World) {
	worldWidth := f32(w.maxX)
	worldHeight := f32(w.maxY)
	chunkSize := w.spatial.chunkSize
	if worldWidth <= 0 || worldHeight <= 0 || chunkSize <= 0 ||
		w.spatial.chunksX <= 0 || w.spatial.chunksY <= 0 {
		return
	}

	for slot in 0 ..< UNIT_CAPACITY {
		if !w.unitUsed[slot] do continue
		unit := &w.units[slot]
		if unit.type == nil || !UnitIsMelee(unit.type) do continue
		state, isWarrior := unit.state.(StateWarrior)
		if !isWarrior || state.activity != .Attacking do continue

		x := WorldWrapPosition(unit.x, worldWidth)
		y := WorldWrapPosition(unit.y, worldHeight)
		unitRadius := UnitBodyRadius(unit.type)
		firstX, countX := UnitNearbyChunkRange(
			x,
			MELEE_SEPARATION_RADIUS,
			worldWidth,
			chunkSize,
			w.spatial.chunksX,
		)
		firstY, countY := UnitNearbyChunkRange(
			y,
			MELEE_SEPARATION_RADIUS,
			worldHeight,
			chunkSize,
			w.spatial.chunksY,
		)
		pushX: f32
		pushY: f32
		for offsetX in 0 ..< countX {
			chunkX := WorldWrapCoordinate(firstX+offsetX, w.spatial.chunksX)
			for offsetY in 0 ..< countY {
				chunkY := WorldWrapCoordinate(firstY+offsetY, w.spatial.chunksY)
				chunk := chunkX*w.spatial.chunksY+chunkY
				for other := w.spatial.unitHead[chunk]; other >= 0;
					other = w.spatial.unitNext[other] {
					if other == slot || !w.unitUsed[other] || w.units[other].health <= 0 {
						continue
					}
					if w.units[other].type == nil do continue

					deltaX := WorldShortestWrappedDelta(x-w.units.x[other], worldWidth)
					deltaY := WorldShortestWrappedDelta(y-w.units.y[other], worldHeight)
					distanceSquared := deltaX*deltaX+deltaY*deltaY
					if distanceSquared >= MELEE_SEPARATION_RADIUS*MELEE_SEPARATION_RADIUS do continue
					if UnitHiddenInside(w, other) do continue

					minDistance :=
						unitRadius+UnitBodyRadius(w.units[other].type)+UNIT_BODY_GAP
					if distanceSquared >= minDistance*minDistance do continue

					distance := math.sqrt(distanceSquared)
					if distance < 0.0001 {
						angle := WorldNoiseHash(slot, other, 0x5E9A)*6.2831853
						deltaX = math.cos(angle)
						deltaY = math.sin(angle)
						distance = 1
					}
					overlap := minDistance-distance
					pushX += deltaX/distance*overlap*0.5
					pushY += deltaY/distance*overlap*0.5
				}
			}
		}
		if pushX == 0 && pushY == 0 do continue

		pushLength := math.sqrt(pushX*pushX+pushY*pushY)
		if pushLength > MELEE_SEPARATION_MAX_PUSH {
			pushX = pushX/pushLength*MELEE_SEPARATION_MAX_PUSH
			pushY = pushY/pushLength*MELEE_SEPARATION_MAX_PUSH
		}
		newX := WorldWrapPosition(unit.x+pushX, worldWidth)
		newY := WorldWrapPosition(unit.y+pushY, worldHeight)
		kingdomSlot, townSlot, defending := WarriorDefenseTown(w, slot, &state)
		if defending && !TownPointInDefenseArea(w, kingdomSlot, townSlot, newX, newY) do continue
		if !WorldTileWalkable(w, int(newX), int(newY), unit.type, unit.kingdome) do continue
		unit.x = newX
		unit.y = newY
		SpatialUnitMove(w, slot)
	}
}

WarriorSwing :: proc(w: ^World, unitSlot: int, state: ^StateWarrior) {
	// The swing can hit other units, buildings and decorations, all of which are
	// shared with the other workers running this tick.
	RecursiveLockGuard(&w.unitMutex)
	unit := &w.units[unitSlot]
	damage := UnitDefaultDamage(unit.type)*KingdomTechWarriorDamageMultiplier(w, unit.kingdome, UnitKindOf(unit.type))
	if unit.effects[.Poisoned] do damage *= 0.85
	areaRadius := UnitDefaultAreaRadius(unit.type)
	switch target in state.target {
	case TargetNone:
	case TargetUnit:
		if target.slot < 0 || target.slot >= UNIT_CAPACITY || !w.unitUsed[target.slot] do return
		if UnitHiddenInside(w, target.slot) do return
		impactX := w.units.x[target.slot]
		impactY := w.units.y[target.slot]
		UnitAttackBurst(w, unitSlot, impactX, impactY)
		if areaRadius > 0 {
			WarriorAreaUnitDamage(w, unitSlot, state, impactX, impactY, areaRadius, damage)
			WorldDecorationAreaDamage(w, impactX, impactY, areaRadius, damage)
		} else {
			UnitApplyDamage(w, target.slot, damage, unit.x, unit.y, .Melee)
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
		impactX, impactY, _ := WarriorBuildingNearestPoint(w, unit.x, unit.y, target.slot)
		UnitAttackBurst(w, unitSlot, impactX, impactY)
		BuildingHitBurst(w, target.slot, impactX, impactY)
		buildingDamage := damage*KingdomTechSiegeDamageMultiplier(w, unit.kingdome, UnitKindOf(unit.type))
		w.buildings[target.slot].health -= buildingDamage
		if w.buildings[target.slot].health <= 0 {
			kind := BuildingKindOf(w.buildings[target.slot].type)
			wasBurning := BuildingOnFire(w, target.slot)
			// Burning rubble can set the surroundings alight after a siege.
			if !BuildingImmuneToFire(kind) &&
				WorldNoiseHash(target.slot, int(w.simulationTime*4), 0xF12E) < 0.35 {
				WorldFireIgnite(w, impactX, impactY, 1)
			}
			BuildingSpawnDebris(w, target.slot, wasBurning)
			BuildingDestroyedBurst(w, target.slot)
			BuildingDespawn(w, target.slot, unit.kingdome)
			state.target = TargetNone{}
		}
		if areaRadius > 0 {
			WarriorAreaUnitDamage(w, unitSlot, state, impactX, impactY, areaRadius, damage)
			WorldDecorationAreaDamage(w, impactX, impactY, areaRadius, damage)
		}
	}
}

WarriorAreaUnitDamage :: proc(w: ^World, attackerSlot: int, state: ^StateWarrior, x, y, radius, damage: f32) {
	if radius <= 0 do return
	worldWidth := f32(w.maxX)
	worldHeight := f32(w.maxY)
	chunkSize := w.spatial.chunkSize
	if chunkSize <= 0 do return

	centerX := WorldWrapPosition(x, worldWidth)
	centerY := WorldWrapPosition(y, worldHeight)
	centerChunkX := int(centerX)/chunkSize
	centerChunkY := int(centerY)/chunkSize
	chunkRadius := int(radius)/chunkSize+1
	for offsetX in -chunkRadius..=chunkRadius {
		chunkX := WorldWrapCoordinate(centerChunkX+offsetX, w.spatial.chunksX)
		for offsetY in -chunkRadius..=chunkRadius {
			chunkY := WorldWrapCoordinate(centerChunkY+offsetY, w.spatial.chunksY)
			chunk := chunkX*w.spatial.chunksY+chunkY
			slot := w.spatial.unitHead[chunk]
			for slot >= 0 {
				next := w.spatial.unitNext[slot]
				if slot != attackerSlot && WarriorCanTargetUnit(w, attackerSlot, state, slot) {
					deltaX := WorldShortestWrappedDelta(w.units.x[slot]-centerX, worldWidth)
					deltaY := WorldShortestWrappedDelta(w.units.y[slot]-centerY, worldHeight)
					if deltaX*deltaX+deltaY*deltaY <= radius*radius {
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
	deltaX := WorldShortestWrappedDelta(unit.x-(f32(town.x)+2), f32(w.maxX))
	deltaY := WorldShortestWrappedDelta(unit.y-(f32(town.y)+2), f32(w.maxY))
	if deltaX*deltaX+deltaY*deltaY <=
		f32(WARRIOR_LOCAL_PATH_DISTANCE*WARRIOR_LOCAL_PATH_DISTANCE) {
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
			f32(town.x+2)+0.5,
			f32(town.y+2)+0.5,
			speed*deltaTime,
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
	deltaX := WorldShortestWrappedDelta(unit.x-(f32(town.x)+2), f32(w.maxX))
	deltaY := WorldShortestWrappedDelta(unit.y-(f32(town.y)+2), f32(w.maxY))
	maxDistance := f32(radius)
	return deltaX*deltaX+deltaY*deltaY > maxDistance*maxDistance
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
	speed := UnitDefaultSpeed(unit.type)*WARRIOR_PATROL_SPEED_RATIO
	if unit.effects[.NoWater] do speed *= 0.7
	reached, blocked, _ := UnitStepTowards(
		w,
		unitSlot,
		f32(unit.pathTargetX)+0.5,
		f32(unit.pathTargetY)+0.5,
		speed*deltaTime,
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
	townDeltaX := WorldShortestWrappedDelta(unit.x-f32(centerX), f32(worldWidth))
	townDeltaY := WorldShortestWrappedDelta(unit.y-f32(centerY), f32(worldHeight))
	townDistance := townDeltaX*townDeltaX+townDeltaY*townDeltaY
	if stepRadius > 0 {
		centerX = int(WorldWrapPosition(unit.x, f32(worldWidth)))
		centerY = int(WorldWrapPosition(unit.y, f32(worldHeight)))
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
			dx := WorldShortestWrappedDelta(f32(x)+0.5-(f32(town.x)+2), f32(worldWidth))
			dy := WorldShortestWrappedDelta(f32(y)+0.5-(f32(town.y)+2), f32(worldHeight))
			distance := dx*dx+dy*dy
			// Displaced warriors can take short steps home rather than getting stuck
			// outside the patrol area after a chase or an escort.
			if distance > f32(radius*radius) && distance >= townDistance do continue
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
	if unit.effects[.NoWater] do speed *= 0.7
	_, blocked, _ := UnitStepTowards(w, unitSlot, f32(x)+0.5, f32(y)+0.5, speed*deltaTime)
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
	if !TownPointInDefenseArea(w, unit.kingdome, unit.town, unit.x, unit.y) do return false
	if !TownPointInDefenseArea(w, unit.kingdome, unit.town, w.units.x[targetSlot], w.units.y[targetSlot]) do return false
	return !UnitIsWarrior(w.units[targetSlot].type)
}

UnitFindEscortTarget :: proc(w: ^World, warriorSlot, sequence: int) -> int {
	unit := &w.units[warriorSlot]
	kingdomSlot := unit.kingdome
	worldWidth := f32(w.maxX)
	worldHeight := f32(w.maxY)
	unitX := WorldWrapPosition(unit.x, worldWidth)
	unitY := WorldWrapPosition(unit.y, worldHeight)
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
				deltaX := WorldShortestWrappedDelta(w.units.x[candidateSlot]-unitX, worldWidth)
				deltaY := WorldShortestWrappedDelta(w.units.y[candidateSlot]-unitY, worldHeight)
				if deltaX*deltaX+deltaY*deltaY > f32(WARRIOR_ESCORT_RADIUS*WARRIOR_ESCORT_RADIUS) {
					continue
				}
				score := WorldNoiseHash(warriorSlot, candidateSlot, seed)
				if score > bestScore {
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
	targetX := int(WorldWrapPosition(w.units[targetSlot].x, f32(worldWidth)))
	targetY := int(WorldWrapPosition(w.units[targetSlot].y, f32(worldHeight)))
	offsetsX := [8]int{0, 1, 1, 1, 0, -1, -1, -1}
	offsetsY := [8]int{-1, -1, 0, 1, 1, 1, 0, -1}
	startDirection := int(WorldNoiseHash(warriorSlot, sequence, u64(targetSlot)+7919)*8)
	for offset in 0..<8 {
		direction := (startDirection+offset)%8
		x := WorldWrapCoordinate(targetX+offsetsX[direction], worldWidth)
		y := WorldWrapCoordinate(targetY+offsetsY[direction], worldHeight)
		unit := &w.units[warriorSlot]
		if !TownPointInDefenseArea(w, unit.kingdome, unit.town, f32(x)+0.5, f32(y)+0.5) do continue
		if !UnitValidTileType(unit.type, WorldTileAt(w, x, y).type) do continue
		if WorldTileOccupied(w, x, y) do continue
		return x, y, true
	}
	return 0, 0, false
}
