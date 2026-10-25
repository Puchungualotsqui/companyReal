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

// Independent-town guards stay close to their hall and only fight units, never
// buildings.
NEUTRAL_GUARD_RADIUS :: 11
NEUTRAL_GUARD_CHASE_SLACK :: 6
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

// Independent guards have no orders and no interest in buildings. They patrol
// their hall and respond to hostile units that enter the small guard radius.
UnitUpdateIndependentKnight :: proc(w: ^World, unitSlot: int, deltaTime: f32) {
	unit := &w.units[unitSlot]
	state, ok := &unit.state.(StateWarrior)
	if !ok do return

	kingdomSlot := unit.kingdome
	townSlot := unit.town
	if !WorldTownExists(w, kingdomSlot, townSlot) {
		state.target = TargetNone{}
		return
	}
	town := &w.kingdoms[kingdomSlot].towns[townSlot]

	if !IndependentKnightFocusValid(w, unitSlot, state, town.x, town.y) {
		state.target = TargetNone{}
	}

	state.scanTimer -= deltaTime
	if state.scanTimer <= 0 {
		jitter := 0.75+WorldNoiseHash(unitSlot, state.scanSequence, u64(kingdomSlot)+911)*0.5
		state.scanTimer = WARRIOR_SCAN_INTERVAL*jitter
		if _, isNone := state.target.(TargetNone); isNone {
			state.target = IndependentKnightFindFocus(w, unitSlot, town.x, town.y)
		}
	}

	if _, isNone := state.target.(TargetNone); !isNone {
		state.activity = .Attacking
		unit.pathReady = false
		if UnitWarriorEngage(w, unitSlot, state, deltaTime) do return
		state.target = TargetNone{}
	}

	state.activity = .Moving
	UnitWarriorPatrol(
		w,
		unitSlot,
		kingdomSlot,
		townSlot,
		NEUTRAL_GUARD_PATROL_RADIUS,
		deltaTime,
		state,
	)
}

IndependentKnightDistanceSquared :: proc(w: ^World, x, y: f32, townX, townY: int) -> f32 {
	deltaX := WorldShortestWrappedDelta(x-(f32(townX)+2), f32(w.maxX))
	deltaY := WorldShortestWrappedDelta(y-(f32(townY)+2), f32(w.maxY))
	return deltaX*deltaX+deltaY*deltaY
}

IndependentKnightFocusValid :: proc(
	w: ^World,
	unitSlot: int,
	state: ^StateWarrior,
	townX, townY: int,
) -> bool {
	target, ok := state.target.(TargetUnit)
	if !ok do return false
	slot := target.slot
	if slot < 0 || slot >= UNIT_CAPACITY || !w.unitUsed[slot] do return false
	if UnitHiddenInside(w, slot) do return false

	unit := &w.units[unitSlot]
	if !KingdomAtWar(w, unit.kingdome, w.units[slot].kingdome) do return false
	if IndependentKnightDistanceSquared(w, w.units[slot].x, w.units[slot].y, townX, townY) >
		f32(NEUTRAL_GUARD_RADIUS*NEUTRAL_GUARD_RADIUS) {
		return false
	}
	chaseRadius := NEUTRAL_GUARD_RADIUS+NEUTRAL_GUARD_CHASE_SLACK
	return IndependentKnightDistanceSquared(w, unit.x, unit.y, townX, townY) <=
		f32(chaseRadius*chaseRadius)
}

IndependentKnightFindFocus :: proc(w: ^World, unitSlot, townX, townY: int) -> WarriorTarget {
	enemies: [1]UnitNearbyEnemy
	if UnitCollectNearbyEnemies(w, unitSlot, NEUTRAL_GUARD_RADIUS, enemies[:]) == 0 {
		return TargetNone{}
	}
	slot := enemies[0].slot
	if IndependentKnightDistanceSquared(w, w.units[slot].x, w.units[slot].y, townX, townY) >
		f32(NEUTRAL_GUARD_RADIUS*NEUTRAL_GUARD_RADIUS) {
		return TargetNone{}
	}
	return TargetUnit{slot = slot}
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
		UnitWarriorAssignOrder(w, unitSlot, state)
	}

	if !WarriorFocusValid(w, unitSlot, state) {
		state.target = TargetNone{}
	}

	state.scanTimer -= deltaTime
	if state.scanTimer <= 0 {
		jitter := 0.75+WorldNoiseHash(unitSlot, state.scanSequence, u64(kingdomSlot)+911)*0.5
		state.scanTimer = WARRIOR_SCAN_INTERVAL*jitter
		if _, isNone := state.target.(TargetNone); isNone {
			state.target = WarriorFindFocus(w, unitSlot, state)
		}
	}

	if _, isNone := state.target.(TargetNone); !isNone {
		state.activity = .Attacking
		unit.pathReady = false
		if UnitWarriorEngage(w, unitSlot, state, deltaTime) do return
		state.target = TargetNone{}
	}

	switch order in state.order {
	case WarriorIdle:
		state.activity = .Idle
	case WarriorGarrison:
		if !UnitWarriorFarFromTown(w, unitSlot, kingdomSlot, townSlot) {
			if UnitWarriorEscort(w, unitSlot, state, deltaTime) do return
			state.activity = .Moving
			UnitWarriorPatrol(w, unitSlot, kingdomSlot, townSlot, WARRIOR_HOME_PATROL_RADIUS, deltaTime, state)
			return
		}
		state.activity = .Moving
		if UnitWarriorTravel(w, unitSlot, kingdomSlot, townSlot, deltaTime) == .Arrived {
			unit.pathReady = false
			UnitWarriorPatrol(w, unitSlot, kingdomSlot, townSlot, WARRIOR_HOME_PATROL_RADIUS, deltaTime, state)
		}
	case WarriorAttack:
		state.activity = .Moving
		result := UnitWarriorTravel(w, unitSlot, order.kingdom, order.town, deltaTime)
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
			if UnitWarriorTravel(w, unitSlot, order.kingdom, order.town, deltaTime) != .Arrived do return
			unit.pathReady = false
			state.patrolSequence = max(1, state.patrolSequence)
		}
		UnitWarriorPatrol(w, unitSlot, order.kingdom, order.town, WARRIOR_DEFEND_PATROL_RADIUS, deltaTime, state)
	}
}

UnitWarriorAssignOrder :: proc(w: ^World, unitSlot: int, state: ^StateWarrior) {
	unit := &w.units[unitSlot]
	kingdomSlot := unit.kingdome
	townSlot := unit.town
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	previous := state.order

	newOrder := TownUnitOrder(w, unitSlot)

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
	garrison := int(f32(total)*TOWN_GARRISON_RATIO)
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

WarriorFocusValid :: proc(w: ^World, unitSlot: int, state: ^StateWarrior) -> bool {
	unit := &w.units[unitSlot]
	switch target in state.target {
	case TargetNone:
		return false
	case TargetUnit:
		if target.slot < 0 || target.slot >= UNIT_CAPACITY || !w.unitUsed[target.slot] {
			return false
		}
		if UnitHiddenInside(w, target.slot) do return false
		if !KingdomAtWar(w, unit.kingdome, w.units[target.slot].kingdome) do return false
		deltaX := WorldShortestWrappedDelta(w.units.x[target.slot]-unit.x, f32(w.maxX))
		deltaY := WorldShortestWrappedDelta(w.units.y[target.slot]-unit.y, f32(w.maxY))
		return deltaX*deltaX+deltaY*deltaY <=
			UnitDistraction(unit.type)*UnitDistraction(unit.type)
	case TargetBuilding:
		if target.slot < 0 || target.slot >= BUILDING_CAPACITY || !w.buildingUsed[target.slot] {
			return false
		}
		return KingdomAtWar(w, unit.kingdome, w.buildings[target.slot].kingdom)
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
		WarriorFindNearbyHostiles(w, unitSlot, max(UnitDefaultVision(unit.type, WorldIsNight(w)), aggro))
	seed := u64(unitSlot)+u64(state.scanSequence)*7919+1307

	if nearUnit >= 0 {
		if unitDistance <= aggro do return TargetUnit{slot = nearUnit}
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

WarriorFindNearbyHostiles :: proc(w: ^World, unitSlot: int, radius: f32) -> (nearUnit: int, unitDistance: f32, nearBuilding: int, buildingDistance: f32) {
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

			for otherSlot := w.spatial.unitHead[chunk]; otherSlot >= 0;
				otherSlot = w.spatial.unitNext[otherSlot] {
				if otherSlot == unitSlot || !w.unitUsed[otherSlot] do continue
				if UnitHiddenInside(w, otherSlot) do continue
				if !KingdomAtWar(w, unit.kingdome, w.units[otherSlot].kingdome) do continue
				deltaX := WorldShortestWrappedDelta(w.units.x[otherSlot]-unitX, worldWidth)
				deltaY := WorldShortestWrappedDelta(w.units.y[otherSlot]-unitY, worldHeight)
				distance := math.sqrt(deltaX*deltaX+deltaY*deltaY)
				if distance < unitDistance {
					unitDistance = distance
					nearUnit = otherSlot
				}
			}

			for buildingSlot := w.spatial.buildingHead[chunk]; buildingSlot >= 0;
				buildingSlot = w.spatial.buildingNext[buildingSlot] {
				if !w.buildingUsed[buildingSlot] do continue
				buildingKingdom := w.buildings.kingdom[buildingSlot]
				if buildingKingdom < 0 || buildingKingdom == unit.kingdome do continue
				if !KingdomAtWar(w, unit.kingdome, buildingKingdom) do continue
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
				sameTown := w.buildings.town[buildingSlot] == targetTown

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
					if sameTown && distance < bestHallDistance {
						bestHallDistance = distance
						bestHall = buildingSlot
					}
				case .Home, .Farmland, .Bridge, .Cannon, .Watchtower, .ArcheryRange, .MagicSchool, .GiantPen, .SiegeWorkshop, .TurtlePen, .ThievesGuild, .Path, .DistrictHall:
					if sameTown && distance < bestBuildingDistance {
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
		if target.slot < 0 || target.slot >= UNIT_CAPACITY || !w.unitUsed[target.slot] {
			return false
		}
		if UnitHiddenInside(w, target.slot) do return false
		targetX = w.units.x[target.slot]
		targetY = w.units.y[target.slot]
		deltaX := WorldShortestWrappedDelta(targetX-unit.x, f32(w.maxX))
		deltaY := WorldShortestWrappedDelta(targetY-unit.y, f32(w.maxY))
		distance = math.sqrt(deltaX*deltaX+deltaY*deltaY)
	case TargetBuilding:
		if target.slot < 0 || target.slot >= BUILDING_CAPACITY || !w.buildingUsed[target.slot] {
			return false
		}
		distance, targetX, targetY =
			WarriorBuildingNearestPoint(w, unit.x, unit.y, target.slot)
	}

	if distance > UnitDefaultRange(unit.type) {
		speed := UnitDefaultSpeed(unit.type)
		if unit.effects[.NoWater] do speed *= 0.7
		_, blocked, _ := UnitStepTowards(w, unitSlot, targetX, targetY, speed*deltaTime)
		return !blocked
	}

	unit.cooldown -= deltaTime
	if unit.cooldown <= 0 {
		WarriorSwing(w, unitSlot, state)
		unit.cooldown = UnitDefaultCooldown(unit.type)
	}
	return true
}

WarriorSwing :: proc(w: ^World, unitSlot: int, state: ^StateWarrior) {
	unit := &w.units[unitSlot]
	damage := UnitDefaultDamage(unit.type)
	areaRadius := UnitDefaultAreaRadius(unit.type)
	switch target in state.target {
	case TargetNone:
	case TargetUnit:
		if target.slot < 0 || target.slot >= UNIT_CAPACITY || !w.unitUsed[target.slot] do return
		if UnitHiddenInside(w, target.slot) do return
		impactX := w.units.x[target.slot]
		impactY := w.units.y[target.slot]
		if areaRadius > 0 {
			WarriorAreaUnitDamage(w, unitSlot, impactX, impactY, areaRadius, damage)
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
		BuildingHitBurst(w, target.slot, impactX, impactY)
		w.buildings[target.slot].health -= damage
		if w.buildings[target.slot].health <= 0 {
			kind := BuildingKindOf(w.buildings[target.slot].type)
			// Burning rubble can set the surroundings alight after a siege.
			if !BuildingImmuneToFire(kind) &&
				WorldNoiseHash(target.slot, int(w.simulationTime*4), 0xF12E) < 0.35 {
				WorldFireIgnite(w, impactX, impactY, 1)
			}
			BuildingDestroyedBurst(w, target.slot)
			BuildingDespawn(w, target.slot, unit.kingdome)
			state.target = TargetNone{}
		}
		if areaRadius > 0 {
			WarriorAreaUnitDamage(w, unitSlot, impactX, impactY, areaRadius, damage)
		}
	}
}

WarriorAreaUnitDamage :: proc(w: ^World, attackerSlot: int, x, y, radius, damage: f32) {
	if radius <= 0 do return
	attacker := &w.units[attackerSlot]
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
				if slot != attackerSlot && w.unitUsed[slot] && !UnitHiddenInside(w, slot) &&
					KingdomAtWar(w, attacker.kingdome, w.units[slot].kingdome) {
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

UnitWarriorTravel :: proc(w: ^World, unitSlot, kingdomSlot, townSlot: int, deltaTime: f32) -> FlowFollowResult {
	field, ok := FlowFieldGet(
		w,
		kingdomSlot,
		townSlot,
		w.units[unitSlot].type,
		w.units[unitSlot].kingdome,
	)
	if !ok do return .Unreachable
	return UnitFollowFlowField(w, unitSlot, field, deltaTime)
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
		if !UnitValidTileType(w.units[unitSlot].type, w.ground[x][y].type) do continue
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
				if candidateSlot == warriorSlot || !w.unitUsed[candidateSlot] do continue
				if UnitHiddenInside(w, candidateSlot) do continue
				if w.units[candidateSlot].kingdome != kingdomSlot do continue
				if UnitIsWarrior(w.units[candidateSlot].type) do continue
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
		if !UnitValidTileType(w.units[warriorSlot].type, w.ground[x][y].type) do continue
		if WorldTileOccupied(w, x, y) do continue
		return x, y, true
	}
	return 0, 0, false
}
