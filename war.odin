package main

import "core:math"

WARRIOR_SCAN_INTERVAL :: 0.5
WARRIOR_CASCADE_UNIT_CHANCE :: 0.85
WARRIOR_CASCADE_BUILDING_CHANCE :: 0.75
WARRIOR_HOME_PATROL_RADIUS :: 8
WARRIOR_DEFEND_PATROL_RADIUS :: 12
WARRIOR_ESCORT_CHANCE :: 0.35
WARRIOR_GARRISON_ESCORT_RATIO :: 0.15
WARRIOR_ESCORT_RADIUS :: 30
WARRIOR_BREACH_RADIUS :: 40

StateWarriorInit :: proc(unit_slot, kingdom_slot, town_slot: int) -> StateWarrior {
	return StateWarrior{
		activity = .Idle,
		order = WarriorIdle{},
		orderKingdom = -1,
		orderTown = -1,
		target = TargetNone{},
		scanTimer = WorldNoiseHash(unit_slot, kingdom_slot+town_slot*101, u64(unit_slot)+601)*
			WARRIOR_SCAN_INTERVAL,
		escortTarget = -1,
	}
}

UnitWarriorReset :: proc(w: ^World, unit_slot: int) {
	if !UnitIsWarrior(w.units[unit_slot].type) do return
	w.units[unit_slot].state = StateWarriorInit(
		unit_slot,
		w.units[unit_slot].kingdome,
		w.units[unit_slot].town,
	)
}

// Units react to enemies inside their distraction radius, which is usually
// wider than the radius that reveals fog for the player.
UnitUpdateWarrior :: proc(w: ^World, unit_slot: int, delta_time: f32) {
	unit := &w.units[unit_slot]
	if !UnitIsWarrior(unit.type) do return
	state := &unit.state.(StateWarrior)

	kingdom_slot := unit.kingdome
	town_slot := unit.town
	if !WorldTownExists(w, kingdom_slot, town_slot) {
		state.target = TargetNone{}
		return
	}
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	if state.orderKingdom != kingdom_slot || state.orderTown != town_slot ||
		state.orderRevision != town.orderRevision {
		UnitWarriorAssignOrder(w, unit_slot, state)
	}

	if !WarriorFocusValid(w, unit_slot, state) {
		state.target = TargetNone{}
	}

	state.scanTimer -= delta_time
	if state.scanTimer <= 0 {
		jitter := 0.75+WorldNoiseHash(unit_slot, state.scanSequence, u64(kingdom_slot)+911)*0.5
		state.scanTimer = WARRIOR_SCAN_INTERVAL*jitter
		if _, is_none := state.target.(TargetNone); is_none {
			state.target = WarriorFindFocus(w, unit_slot, state)
		}
	}

	if _, is_none := state.target.(TargetNone); !is_none {
		state.activity = .Attacking
		if UnitWarriorEngage(w, unit_slot, state, delta_time) do return
		state.target = TargetNone{}
	}

	switch order in state.order {
	case WarriorIdle:
		state.activity = .Idle
	case WarriorGarrison:
		if !UnitWarriorFarFromTown(w, unit_slot, kingdom_slot, town_slot) {
			if UnitWarriorEscort(w, unit_slot, state, delta_time) do return
			state.activity = .Moving
			UnitWarriorPatrol(w, unit_slot, kingdom_slot, town_slot, WARRIOR_HOME_PATROL_RADIUS, delta_time, state)
			return
		}
		state.activity = .Moving
		if UnitWarriorTravel(w, unit_slot, kingdom_slot, town_slot, delta_time) == .Arrived {
			unit.pathReady = false
			UnitWarriorPatrol(w, unit_slot, kingdom_slot, town_slot, WARRIOR_HOME_PATROL_RADIUS, delta_time, state)
		}
	case WarriorAttack:
		state.activity = .Moving
		result := UnitWarriorTravel(w, unit_slot, order.kingdom, order.town, delta_time)
		if result == .Arrived {
			if hall := TownHallSlot(w, order.kingdom, order.town); hall >= 0 {
				state.target = TargetBuilding{slot = hall}
				state.activity = .Attacking
			}
		} else if result == .Unreachable {
			// The town is enclosed. Break the ring: prefer its walls, then any
			// nearby building of that town. If nothing is close enough yet, walk
			// toward the hall until the wall is in breach range.
			breach := WarriorFindBreachBuilding(w, unit_slot, order.kingdom, order.town)
			if breach < 0 do breach = TownHallSlot(w, order.kingdom, order.town)
			if breach >= 0 {
				state.target = TargetBuilding{slot = breach}
				state.activity = .Attacking
			}
		}
	case WarriorDefend:
		state.activity = .Moving
		if UnitWarriorTravel(w, unit_slot, order.kingdom, order.town, delta_time) == .Arrived {
			unit.pathReady = false
			UnitWarriorPatrol(w, unit_slot, order.kingdom, order.town, WARRIOR_DEFEND_PATROL_RADIUS, delta_time, state)
		}
	}
}

UnitWarriorAssignOrder :: proc(w: ^World, unit_slot: int, state: ^StateWarrior) {
	unit := &w.units[unit_slot]
	kingdom_slot := unit.kingdome
	town_slot := unit.town
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	previous := state.order

	roll := WorldNoiseHash(
		unit_slot,
		int(town.orderRevision%1_000_000),
		u64(kingdom_slot*TOWN_CAPACITY+town_slot)+1301,
	)
	new_order: WarriorOrder
	if town.orderCount == 0 || roll < TOWN_GARRISON_RATIO {
		new_order = WarriorGarrison{}
	} else if town.orderCount > 0 {
		fraction := (roll-TOWN_GARRISON_RATIO)/(1-TOWN_GARRISON_RATIO)
		index := clamp(int(fraction*f32(town.orderCount)), 0, town.orderCount-1)
		switch ref in town.orders[index] {
		case TownAttackOrder:
			new_order = WarriorAttack{kingdom = ref.kingdom, town = ref.town}
		case TownDefendOrder:
			new_order = WarriorDefend{kingdom = ref.kingdom, town = ref.town}
		}
	} else {
		new_order = WarriorIdle{}
	}

	state.order = new_order
	state.orderKingdom = kingdom_slot
	state.orderTown = town_slot
	state.orderRevision = town.orderRevision
	if !WarriorOrderEqual(previous, new_order) {
		state.target = TargetNone{}
		state.escortTarget = -1
		unit.pathReady = false
	}
}

WarriorOrderEqual :: proc(a, b: WarriorOrder) -> bool {
	switch order_a in a {
	case WarriorIdle:
		_, ok := b.(WarriorIdle)
		return ok
	case WarriorGarrison:
		_, ok := b.(WarriorGarrison)
		return ok
	case WarriorAttack:
		order_b, ok := b.(WarriorAttack)
		return ok && order_a.kingdom == order_b.kingdom && order_a.town == order_b.town
	case WarriorDefend:
		order_b, ok := b.(WarriorDefend)
		return ok && order_a.kingdom == order_b.kingdom && order_a.town == order_b.town
	}
	return false
}

WarriorFocusValid :: proc(w: ^World, unit_slot: int, state: ^StateWarrior) -> bool {
	unit := &w.units[unit_slot]
	switch target in state.target {
	case TargetNone:
		return false
	case TargetUnit:
		if target.slot < 0 || target.slot >= UNIT_CAPACITY || !w.unitUsed[target.slot] {
			return false
		}
		if !KingdomAtWar(w, unit.kingdome, w.units[target.slot].kingdome) do return false
		delta_x := WorldShortestWrappedDelta(w.units.x[target.slot]-unit.x, f32(w.maxX))
		delta_y := WorldShortestWrappedDelta(w.units.y[target.slot]-unit.y, f32(w.maxY))
		return delta_x*delta_x+delta_y*delta_y <=
			UnitDistraction(unit.type)*UnitDistraction(unit.type)
	case TargetBuilding:
		if target.slot < 0 || target.slot >= BUILDING_CAPACITY || !w.buildingUsed[target.slot] {
			return false
		}
		return KingdomAtWar(w, unit.kingdome, w.buildings[target.slot].kingdom)
	}
	return false
}

WarriorFindFocus :: proc(w: ^World, unit_slot: int, state: ^StateWarrior) -> WarriorTarget {
	unit := &w.units[unit_slot]
	aggro := UnitDistraction(unit.type)
	is_attack_order := false
	switch _ in state.order {
	case WarriorAttack:
		is_attack_order = true
	case WarriorGarrison, WarriorDefend, WarriorIdle:
	}

	state.scanSequence += 1
	near_unit, unit_distance, near_building, building_distance :=
		WarriorFindNearbyHostiles(w, unit_slot, max(UnitDefaultVision(unit.type), aggro))
	seed := u64(unit_slot)+u64(state.scanSequence)*7919+1307

	if near_unit >= 0 {
		if unit_distance <= aggro do return TargetUnit{slot = near_unit}
		if is_attack_order &&
			WorldNoiseHash(unit_slot, state.scanSequence, seed) <
				WARRIOR_CASCADE_UNIT_CHANCE {
			return TargetUnit{slot = near_unit}
		}
	}
	if near_building >= 0 && (building_distance <= aggro || is_attack_order) {
		if WorldNoiseHash(unit_slot, state.scanSequence+1, seed) <
			WARRIOR_CASCADE_BUILDING_CHANCE {
			return TargetBuilding{slot = near_building}
		}
	}
	return TargetNone{}
}

WarriorFindNearbyHostiles :: proc(w: ^World, unit_slot: int, radius: f32) -> (near_unit: int, unit_distance: f32, near_building: int, building_distance: f32) {
	near_unit = -1
	near_building = -1
	unit_distance = radius
	building_distance = radius
	if radius <= 0 do return

	unit := &w.units[unit_slot]
	world_width := f32(w.maxX)
	world_height := f32(w.maxY)
	unit_x := WorldWrapPosition(unit.x, world_width)
	unit_y := WorldWrapPosition(unit.y, world_height)
	chunk_size := w.spatial.chunkSize
	if chunk_size <= 0 do return

	center_chunk_x := int(unit_x)/chunk_size
	center_chunk_y := int(unit_y)/chunk_size
	chunk_radius := int(radius)/chunk_size+1
	for offset_x in -chunk_radius..=chunk_radius {
		chunk_x := WorldWrapCoordinate(center_chunk_x+offset_x, w.spatial.chunksX)
		for offset_y in -chunk_radius..=chunk_radius {
			chunk_y := WorldWrapCoordinate(center_chunk_y+offset_y, w.spatial.chunksY)
			chunk := chunk_x*w.spatial.chunksY+chunk_y

			for other_slot := w.spatial.unitHead[chunk]; other_slot >= 0;
				other_slot = w.spatial.unitNext[other_slot] {
				if other_slot == unit_slot || !w.unitUsed[other_slot] do continue
				if !KingdomAtWar(w, unit.kingdome, w.units[other_slot].kingdome) do continue
				delta_x := WorldShortestWrappedDelta(w.units.x[other_slot]-unit_x, world_width)
				delta_y := WorldShortestWrappedDelta(w.units.y[other_slot]-unit_y, world_height)
				distance := math.sqrt(delta_x*delta_x+delta_y*delta_y)
				if distance < unit_distance {
					unit_distance = distance
					near_unit = other_slot
				}
			}

			for building_slot := w.spatial.buildingHead[chunk]; building_slot >= 0;
				building_slot = w.spatial.buildingNext[building_slot] {
				if !w.buildingUsed[building_slot] do continue
				building_kingdom := w.buildings.kingdom[building_slot]
				if building_kingdom < 0 || building_kingdom == unit.kingdome do continue
				if !KingdomAtWar(w, unit.kingdome, building_kingdom) do continue
				distance, _, _ := WarriorBuildingNearestPoint(w, unit_x, unit_y, building_slot)
				if distance < building_distance {
					building_distance = distance
					near_building = building_slot
				}
			}
		}
	}
	return
}

// Returns the distance from a point to the building footprint, plus the
// nearest point on the footprint (used as the approach target).
WarriorBuildingNearestPoint :: proc(w: ^World, x, y: f32, building_slot: int) -> (distance: f32, nearest_x: f32, nearest_y: f32) {
	world_width := f32(w.maxX)
	world_height := f32(w.maxY)
	building_x := f32(w.buildings.x[building_slot])
	building_y := f32(w.buildings.y[building_slot])
	width, height := BuildingTileSize(w.buildings[building_slot].type)
	half_width := f32(width)*0.5
	half_height := f32(height)*0.5
	center_x := building_x+half_width
	center_y := building_y+half_height

	delta_x := WorldShortestWrappedDelta(x-center_x, world_width)
	delta_y := WorldShortestWrappedDelta(y-center_y, world_height)
	clamped_x := clamp(delta_x, -half_width, half_width)
	clamped_y := clamp(delta_y, -half_height, half_height)
	nearest_x = WorldWrapPosition(center_x+clamped_x, world_width)
	nearest_y = WorldWrapPosition(center_y+clamped_y, world_height)
	excess_x := delta_x-clamped_x
	excess_y := delta_y-clamped_y
	distance = math.sqrt(excess_x*excess_x+excess_y*excess_y)
	return
}

// When a town is fully enclosed, the flow field cannot reach it. This finds the
// nearest piece of the ring to break: first a wall, then any other building of
// the target town, and only last the hall itself.
WarriorFindBreachBuilding :: proc(w: ^World, unit_slot, target_kingdom, target_town: int) -> int {
	unit := &w.units[unit_slot]
	chunk_size := w.spatial.chunkSize
	if chunk_size <= 0 do return -1
	if !KingdomAtWar(w, unit.kingdome, target_kingdom) do return -1

	center_chunk_x := int(unit.x)/chunk_size
	center_chunk_y := int(unit.y)/chunk_size
	chunk_radius := int(WARRIOR_BREACH_RADIUS)/chunk_size+1
	best_wall := -1
	best_wall_distance: f32 = WARRIOR_BREACH_RADIUS
	best_building := -1
	best_building_distance: f32 = WARRIOR_BREACH_RADIUS
	best_hall := -1
	best_hall_distance: f32 = WARRIOR_BREACH_RADIUS

	for offset_x in -chunk_radius..=chunk_radius {
		chunk_x := WorldWrapCoordinate(center_chunk_x+offset_x, w.spatial.chunksX)
		for offset_y in -chunk_radius..=chunk_radius {
			chunk_y := WorldWrapCoordinate(center_chunk_y+offset_y, w.spatial.chunksY)
			chunk := chunk_x*w.spatial.chunksY+chunk_y
			for building_slot := w.spatial.buildingHead[chunk]; building_slot >= 0;
				building_slot = w.spatial.buildingNext[building_slot] {
				if !w.buildingUsed[building_slot] do continue
				if w.buildings.kingdom[building_slot] != target_kingdom do continue
				same_town := w.buildings.town[building_slot] == target_town

				distance, _, _ := WarriorBuildingNearestPoint(w, unit.x, unit.y, building_slot)
				if distance > WARRIOR_BREACH_RADIUS do continue
				kind := BuildingKindOf(w.buildings[building_slot].type)
				switch kind {
				case .Wall:
					if distance < best_wall_distance {
						best_wall_distance = distance
						best_wall = building_slot
					}
				case .TownHall:
					if same_town && distance < best_hall_distance {
						best_hall_distance = distance
						best_hall = building_slot
					}
				case .Home, .Farmland, .Bridge, .Cannon, .Watchtower, .ArcheryRange, .MagicSchool, .GiantPen, .SiegeWorkshop, .TurtlePen, .ThievesGuild, .Path:
					if same_town && distance < best_building_distance {
						best_building_distance = distance
						best_building = building_slot
					}
				}
			}
		}
	}

	if best_wall >= 0 do return best_wall
	if best_building >= 0 do return best_building
	return best_hall
}

UnitWarriorEngage :: proc(w: ^World, unit_slot: int, state: ^StateWarrior, delta_time: f32) -> bool {
	unit := &w.units[unit_slot]
	target_x, target_y: f32
	distance: f32
	switch target in state.target {
	case TargetNone:
		return false
	case TargetUnit:
		if target.slot < 0 || target.slot >= UNIT_CAPACITY || !w.unitUsed[target.slot] {
			return false
		}
		target_x = w.units.x[target.slot]
		target_y = w.units.y[target.slot]
		delta_x := WorldShortestWrappedDelta(target_x-unit.x, f32(w.maxX))
		delta_y := WorldShortestWrappedDelta(target_y-unit.y, f32(w.maxY))
		distance = math.sqrt(delta_x*delta_x+delta_y*delta_y)
	case TargetBuilding:
		if target.slot < 0 || target.slot >= BUILDING_CAPACITY || !w.buildingUsed[target.slot] {
			return false
		}
		distance, target_x, target_y =
			WarriorBuildingNearestPoint(w, unit.x, unit.y, target.slot)
	}

	if distance > UnitDefaultRange(unit.type) {
		speed := UnitDefaultSpeed(unit.type)
		if unit.effects[.NoWater] do speed *= 0.7
		_, blocked, _ := UnitStepTowards(w, unit_slot, target_x, target_y, speed*delta_time)
		return !blocked
	}

	unit.cooldown -= delta_time
	if unit.cooldown <= 0 {
		WarriorSwing(w, unit_slot, state)
		unit.cooldown = UnitDefaultCooldown(unit.type)
	}
	return true
}

WarriorSwing :: proc(w: ^World, unit_slot: int, state: ^StateWarrior) {
	unit := &w.units[unit_slot]
	damage := UnitDefaultDamage(unit.type)
	area_radius := UnitDefaultAreaRadius(unit.type)
	switch target in state.target {
	case TargetNone:
	case TargetUnit:
		if target.slot < 0 || target.slot >= UNIT_CAPACITY || !w.unitUsed[target.slot] do return
		impact_x := w.units.x[target.slot]
		impact_y := w.units.y[target.slot]
		if area_radius > 0 {
			WarriorAreaUnitDamage(w, unit_slot, impact_x, impact_y, area_radius, damage)
		} else {
			w.units[target.slot].health -= damage
			if w.units[target.slot].health <= 0 do UnitDespawn(w, target.slot)
		}
	case TargetBuilding:
		if target.slot < 0 || target.slot >= BUILDING_CAPACITY || !w.buildingUsed[target.slot] {
			return
		}
		impact_x, impact_y, _ := WarriorBuildingNearestPoint(w, unit.x, unit.y, target.slot)
		w.buildings[target.slot].health -= damage
		if w.buildings[target.slot].health <= 0 {
			kind := BuildingKindOf(w.buildings[target.slot].type)
			// Burning rubble can set the surroundings alight after a siege.
			if !BuildingImmuneToFire(kind) &&
				WorldNoiseHash(target.slot, int(w.simulationTime*4), 0xF12E) < 0.35 {
				WorldFireIgnite(w, impact_x, impact_y, 1)
			}
			BuildingDespawn(w, target.slot, unit.kingdome)
			state.target = TargetNone{}
		}
		if area_radius > 0 {
			WarriorAreaUnitDamage(w, unit_slot, impact_x, impact_y, area_radius, damage)
		}
	}
}

WarriorAreaUnitDamage :: proc(w: ^World, attacker_slot: int, x, y, radius, damage: f32) {
	if radius <= 0 do return
	attacker := &w.units[attacker_slot]
	world_width := f32(w.maxX)
	world_height := f32(w.maxY)
	chunk_size := w.spatial.chunkSize
	if chunk_size <= 0 do return

	center_x := WorldWrapPosition(x, world_width)
	center_y := WorldWrapPosition(y, world_height)
	center_chunk_x := int(center_x)/chunk_size
	center_chunk_y := int(center_y)/chunk_size
	chunk_radius := int(radius)/chunk_size+1
	for offset_x in -chunk_radius..=chunk_radius {
		chunk_x := WorldWrapCoordinate(center_chunk_x+offset_x, w.spatial.chunksX)
		for offset_y in -chunk_radius..=chunk_radius {
			chunk_y := WorldWrapCoordinate(center_chunk_y+offset_y, w.spatial.chunksY)
			chunk := chunk_x*w.spatial.chunksY+chunk_y
			slot := w.spatial.unitHead[chunk]
			for slot >= 0 {
				next := w.spatial.unitNext[slot]
				if slot != attacker_slot && w.unitUsed[slot] &&
					KingdomAtWar(w, attacker.kingdome, w.units[slot].kingdome) {
					delta_x := WorldShortestWrappedDelta(w.units.x[slot]-center_x, world_width)
					delta_y := WorldShortestWrappedDelta(w.units.y[slot]-center_y, world_height)
					if delta_x*delta_x+delta_y*delta_y <= radius*radius {
						w.units[slot].health -= damage
						if w.units[slot].health <= 0 do UnitDespawn(w, slot)
					}
				}
				slot = next
			}
		}
	}
}

UnitWarriorTravel :: proc(w: ^World, unit_slot, kingdom_slot, town_slot: int, delta_time: f32) -> FlowFollowResult {
	field, ok := FlowFieldGet(
		w,
		kingdom_slot,
		town_slot,
		w.units[unit_slot].type,
		w.units[unit_slot].kingdome,
	)
	if !ok do return .Unreachable
	return UnitFollowFlowField(w, unit_slot, field, delta_time)
}

UnitWarriorFarFromTown :: proc(w: ^World, unit_slot, kingdom_slot, town_slot: int) -> bool {
	if !WorldTownExists(w, kingdom_slot, town_slot) do return false
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	unit := &w.units[unit_slot]
	delta_x := WorldShortestWrappedDelta(unit.x-(f32(town.x)+2), f32(w.maxX))
	delta_y := WorldShortestWrappedDelta(unit.y-(f32(town.y)+2), f32(w.maxY))
	max_distance := f32(WARRIOR_HOME_PATROL_RADIUS*2)
	return delta_x*delta_x+delta_y*delta_y > max_distance*max_distance
}

UnitWarriorPatrol :: proc(w: ^World, unit_slot, kingdom_slot, town_slot, radius: int, delta_time: f32, state: ^StateWarrior) {
	unit := &w.units[unit_slot]
	at_target := int(WorldWrapPosition(unit.x, f32(w.maxX))) == unit.pathTargetX &&
		int(WorldWrapPosition(unit.y, f32(w.maxY))) == unit.pathTargetY
	if !unit.pathReady || at_target {
		x, y, found := UnitFindPatrolTarget(
			w,
			unit_slot,
			kingdom_slot,
			town_slot,
			radius,
			state.patrolSequence,
		)
		if !found do return
		unit.pathTargetX = x
		unit.pathTargetY = y
		unit.pathReady = true
		state.patrolSequence += 1
	}

	speed := UnitDefaultSpeed(unit.type)
	if unit.effects[.NoWater] do speed *= 0.7
	reached, blocked, _ := UnitStepTowards(
		w,
		unit_slot,
		f32(unit.pathTargetX)+0.5,
		f32(unit.pathTargetY)+0.5,
		speed*delta_time,
	)
	if reached || blocked do unit.pathReady = false
}

UnitFindPatrolTarget :: proc(w: ^World, unit_slot, kingdom_slot, town_slot, radius, sequence: int) -> (int, int, bool) {
	if !WorldTownExists(w, kingdom_slot, town_slot) do return 0, 0, false
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	center_x := town.x+2
	center_y := town.y+2
	world_width := int(w.maxX)
	world_height := int(w.maxY)
	seed := u64(unit_slot)+u64(sequence)*1031+1709
	for attempt in 0..<16 {
		delta_x := int(WorldNoiseHash(unit_slot, sequence*37+attempt*2, seed+11)*f32(radius*2+1))-radius
		delta_y := int(WorldNoiseHash(unit_slot, sequence*37+attempt*2+1, seed+23)*f32(radius*2+1))-radius
		if delta_x == 0 && delta_y == 0 do continue
		x := WorldWrapCoordinate(center_x+delta_x, world_width)
		y := WorldWrapCoordinate(center_y+delta_y, world_height)
		if !UnitValidTileType(w.units[unit_slot].type, w.ground[x][y].type) do continue
		if WorldTileOccupied(w, x, y) do continue
		return x, y, true
	}
	return 0, 0, false
}

// Garrison warriors occasionally escort civilians; the moment they receive an
// attack or defend order the escort is dropped.
UnitWarriorEscort :: proc(w: ^World, unit_slot: int, state: ^StateWarrior, delta_time: f32) -> bool {
	unit := &w.units[unit_slot]
	kingdom_slot := unit.kingdome
	town_slot := unit.town
	if !WorldTownExists(w, kingdom_slot, town_slot) do return false
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	escort_duty := WorldNoiseHash(
		unit_slot,
		int(town.orderRevision%1_000_000),
		u64(kingdom_slot*TOWN_CAPACITY+town_slot)+2203,
	)
	if escort_duty >= WARRIOR_GARRISON_ESCORT_RATIO {
		state.escortTarget = -1
		return false
	}

	target := state.escortTarget
	if target >= 0 && !WarriorEscortValid(w, unit_slot, target) {
		state.escortTarget = -1
		unit.pathReady = false
		target = -1
	}
	if target < 0 {
		state.scanSequence += 1
		seed := u64(unit_slot)+u64(state.scanSequence)*1319+1901
		if WorldNoiseHash(unit_slot, state.scanSequence, seed) < WARRIOR_ESCORT_CHANCE {
			state.escortTarget = UnitFindEscortTarget(w, unit_slot, state.scanSequence)
			target = state.escortTarget
		}
	}
	if target < 0 do return false

	state.activity = .Escorting
	x, y, found := UnitFindEscortPosition(w, unit_slot, target, state.patrolSequence)
	if !found do return true
	speed := UnitDefaultSpeed(unit.type)
	if unit.effects[.NoWater] do speed *= 0.7
	_, blocked, _ := UnitStepTowards(w, unit_slot, f32(x)+0.5, f32(y)+0.5, speed*delta_time)
	if blocked do state.patrolSequence += 1
	return true
}

WarriorEscortValid :: proc(w: ^World, warrior_slot, target_slot: int) -> bool {
	if target_slot < 0 || target_slot >= UNIT_CAPACITY || !w.unitUsed[target_slot] {
		return false
	}
	if w.units[target_slot].kingdome != w.units[warrior_slot].kingdome do return false
	return !UnitIsWarrior(w.units[target_slot].type)
}

UnitFindEscortTarget :: proc(w: ^World, warrior_slot, sequence: int) -> int {
	unit := &w.units[warrior_slot]
	kingdom_slot := unit.kingdome
	world_width := f32(w.maxX)
	world_height := f32(w.maxY)
	unit_x := WorldWrapPosition(unit.x, world_width)
	unit_y := WorldWrapPosition(unit.y, world_height)
	chunk_size := w.spatial.chunkSize
	if chunk_size <= 0 do return -1

	center_chunk_x := int(unit_x)/chunk_size
	center_chunk_y := int(unit_y)/chunk_size
	chunk_radius := WARRIOR_ESCORT_RADIUS/chunk_size+1
	seed := u64(kingdom_slot)+u64(warrior_slot)*101+u64(sequence)*7919
	selected_target := -1
	best_score: f32 = -1
	for offset_x in -chunk_radius..=chunk_radius {
		chunk_x := WorldWrapCoordinate(center_chunk_x+offset_x, w.spatial.chunksX)
		for offset_y in -chunk_radius..=chunk_radius {
			chunk_y := WorldWrapCoordinate(center_chunk_y+offset_y, w.spatial.chunksY)
			chunk := chunk_x*w.spatial.chunksY+chunk_y
			for candidate_slot := w.spatial.unitHead[chunk]; candidate_slot >= 0;
				candidate_slot = w.spatial.unitNext[candidate_slot] {
				if candidate_slot == warrior_slot || !w.unitUsed[candidate_slot] do continue
				if w.units[candidate_slot].kingdome != kingdom_slot do continue
				if UnitIsWarrior(w.units[candidate_slot].type) do continue
				delta_x := WorldShortestWrappedDelta(w.units.x[candidate_slot]-unit_x, world_width)
				delta_y := WorldShortestWrappedDelta(w.units.y[candidate_slot]-unit_y, world_height)
				if delta_x*delta_x+delta_y*delta_y > f32(WARRIOR_ESCORT_RADIUS*WARRIOR_ESCORT_RADIUS) {
					continue
				}
				score := WorldNoiseHash(warrior_slot, candidate_slot, seed)
				if score > best_score {
					best_score = score
					selected_target = candidate_slot
				}
			}
		}
	}
	return selected_target
}

UnitFindEscortPosition :: proc(w: ^World, warrior_slot, target_slot, sequence: int) -> (int, int, bool) {
	world_width := int(w.maxX)
	world_height := int(w.maxY)
	if world_width <= 0 || world_height <= 0 do return 0, 0, false
	target_x := int(WorldWrapPosition(w.units[target_slot].x, f32(world_width)))
	target_y := int(WorldWrapPosition(w.units[target_slot].y, f32(world_height)))
	offsets_x := [8]int{0, 1, 1, 1, 0, -1, -1, -1}
	offsets_y := [8]int{-1, -1, 0, 1, 1, 1, 0, -1}
	start_direction := int(WorldNoiseHash(warrior_slot, sequence, u64(target_slot)+7919)*8)
	for offset in 0..<8 {
		direction := (start_direction+offset)%8
		x := WorldWrapCoordinate(target_x+offsets_x[direction], world_width)
		y := WorldWrapCoordinate(target_y+offsets_y[direction], world_height)
		if !UnitValidTileType(w.units[warrior_slot].type, w.ground[x][y].type) do continue
		if WorldTileOccupied(w, x, y) do continue
		return x, y, true
	}
	return 0, 0, false
}
