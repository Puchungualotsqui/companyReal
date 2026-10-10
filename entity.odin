package main

UnitStatsGet :: proc(type: UnitType) -> UnitStats {
	switch type {
	case .Line:
		return UnitStats{100, 28, 5, 12, 0.12, 1.0, 30}
	case .Assault:
		return UnitStats{90, 32, 3, 18, 0.18, 0.8, 24}
	case .Heavy:
		return UnitStats{160, 18, 6, 24, 0.24, 1.5, 40}
	case .Scout:
		return UnitStats{70, 42, 7, 8, 0.08, 0.7, 20}
	case .Engineer:
		return UnitStats{80, 24, 4, 6, 0.10, 1.3, 25}
	case .Vehicle:
		return UnitStats{300, 20, 8, 45, 0.30, 2.0, 60}
	case .Equipment:
		return UnitStats{120, 18, 7, 30, 0.20, 1.6, 40}
	case .Artillery:
		return UnitStats{100, 16, 12, 20, 0.35, 2.5, 12}
	}
	unreachable()
}

UnitSpawn :: proc(w: ^World, squad: SquadId, team: Team, type: UnitType, pos, formation_offset: Vec2) -> UnitId {
	stats := UnitStatsGet(type)
	id := UnitId(uint(len(w.units) + 1))
	append(&w.units, Unit{id, squad, team, type, .Idle, pos, Vec2{}, formation_offset, stats.health, stats.health, 1, 0, stats.ammo, stats.ammo, 0, Order{.Idle, pos, INVALID_UNIT_ID}})
	return id
}

SquadSpawn :: proc(w: ^World, team: Team, type: UnitType, count: int, pos: Vec2, owner := INVALID_PLAYER_ID) -> SquadId {
	id := SquadId(uint(len(w.squads) + 1))
	squad := Squad{id, owner, team, type, make([dynamic]UnitId), Order{.Idle, pos, INVALID_UNIT_ID}, .Idle, .Line, INVALID_CONVOY_ID, make([dynamic]Vec2), 0, pos, 0, 0}
	append(&w.squads, squad)

	for index: int = 0; index < count; index += 1 {
		offset := SquadFormationOffset(index, squad.formation)
		unit_id := UnitSpawn(w, id, team, type, Vec2Add(pos, offset), offset)
		append(&w.squads[SquadIndex(id)].units, unit_id)
	}
	return id
}

SquadFormationOffset :: proc(index: int, formation := FormationType.Line) -> Vec2 {
	column := f32(index % 4)
	row := f32(index / 4)
	switch formation {
	case .Line:
		return Vec2{column - 1.5, row - 0.5}
	case .Column:
		return Vec2{0, f32(index) - 1.5}
	case .Wedge:
		return Vec2{column - 1.5 + row * 0.5, row - 0.5}
	}
	unreachable()
}


SquadCanControl :: proc(squad: Squad, player: PlayerId) -> bool { return squad.owner == player && player != INVALID_PLAYER_ID }

SquadSetMoveForPlayer :: proc(w: ^World, player: PlayerId, id: SquadId, target: Vec2) -> bool {
	squad := SquadGet(w, id)
	if squad == nil || !SquadCanControl(squad^, player) do return false
	SquadSetOrder(w, id, Order{.Move, target, INVALID_UNIT_ID})
	return true
}

SquadSetAttackForPlayer :: proc(w: ^World, player: PlayerId, id: SquadId, target: UnitId) -> bool {
	squad := SquadGet(w, id)
	unit := UnitGet(w, target)
	if squad == nil || unit == nil || !SquadCanControl(squad^, player) do return false
	if !UnitIsAlive(unit^) do return false
	switch squad.team {
	case .Neutral:
		return false
	case .A, .B:
		if squad.team == unit.team do return false
	}
	SquadSetOrder(w, id, Order{.Attack, Vec2{}, target})
	return true
}

SquadSetOrder :: proc(w: ^World, id: SquadId, order: Order) {
	squad := SquadGet(w, id)
	if squad == nil do return
	squad.order = order
	squad.path_index = 0
	resize(&squad.path, 0)
	switch order.type {
	case .Idle:
		squad.intent = .Idle
	case .Move:
		squad.intent = .Advance
	case .Attack:
		squad.intent = .Assault
	case .Retreat:
		squad.intent = .Withdraw
	}
	for unit_id in squad.units {
		unit := UnitGet(w, unit_id)
		if unit != nil do unit.order = order
	}
}

SquadSetFormationForPlayer :: proc(w: ^World, player: PlayerId, id: SquadId, formation: FormationType) -> bool {
	squad := SquadGet(w, id)
	if squad == nil || !SquadCanControl(squad^, player) do return false
	squad.formation = formation
	for unit_id, index in squad.units {
		unit := UnitGet(w, unit_id)
		if unit != nil do unit.formation_offset = SquadFormationOffset(index, formation)
	}
	return true
}

SquadSetIntentForPlayer :: proc(w: ^World, player: PlayerId, id: SquadId, intent: SquadIntent, target: Vec2) -> bool {
	squad := SquadGet(w, id)
	if squad == nil || !SquadCanControl(squad^, player) do return false
	squad.intent = intent
	switch intent {
	case .Assault:
		squad.formation = .Wedge
	case .Probe:
		squad.formation = .Column
	case .Defend, .Advance, .Escort, .Raid, .Resupply, .Withdraw, .Idle:
		squad.formation = .Line
	}
	for unit_id, index in squad.units {
		unit := UnitGet(w, unit_id)
		if unit != nil do unit.formation_offset = SquadFormationOffset(index, squad.formation)
	}
	squad.convoy = INVALID_CONVOY_ID
	order_type := OrderType.Move
	if intent == .Withdraw do order_type = .Retreat
	if intent == .Idle do order_type = .Idle
	SquadSetOrder(w, id, Order{order_type, target, INVALID_UNIT_ID})
	squad.intent = intent
	return true
}

SquadSetEscortForPlayer :: proc(w: ^World, player: PlayerId, id: SquadId, convoy_id: ConvoyId) -> bool {
	squad := SquadGet(w, id)
	convoy := WorldConvoyGet(w, convoy_id)
	if squad == nil || convoy == nil || !SquadCanControl(squad^, player) || squad.team != convoy.team do return false
	squad.intent = .Escort
	squad.convoy = convoy_id
	SquadSetOrder(w, id, Order{.Move, WorldConvoyPosition(w, convoy^), INVALID_UNIT_ID})
	squad.intent = .Escort
	squad.convoy = convoy_id
	return true
}

SquadSetRaidForPlayer :: proc(w: ^World, player: PlayerId, id: SquadId, convoy_id: ConvoyId) -> bool {
	squad := SquadGet(w, id)
	convoy := WorldConvoyGet(w, convoy_id)
	if squad == nil || convoy == nil || !SquadCanControl(squad^, player) || squad.team == convoy.team do return false
	squad.intent = .Raid
	squad.convoy = convoy_id
	SquadSetOrder(w, id, Order{.Move, WorldConvoyPosition(w, convoy^), INVALID_UNIT_ID})
	squad.intent = .Raid
	squad.convoy = convoy_id
	return true
}

WorldUpdate :: proc(w: ^World, dt: f32) {
	w.accumulator += min(dt, 0.25)
	for w.accumulator >= w.step {
		WorldStep(w)
		w.accumulator -= w.step
	}
}

WorldStep :: proc(w: ^World) {
	w.time += w.step
	w.tick += 1
	WorldUpdateSquads(w)
	for &unit in w.units do UnitUpdate(w, &unit, w.step)
	WorldUpdateSectors(w, w.step)
	WorldUpdateBuildings(w, w.step)
	WorldUpdateLogistics(w, w.step)
	WorldUpdateArtillery(w, w.step)
	WorldUpdateSupply(w, w.step)
}

UnitUpdate :: proc(w: ^World, unit: ^Unit, dt: f32) {
	UnitCombatRecovery(unit, dt)
	switch unit.state {
	case .Dead:
		return
	case .Wounded:
		UnitWoundedUpdate(w, unit, dt)
		return
	case .Retreating:
		UnitRetreat(w, unit, dt)
		return
	case .Idle, .Moving, .Attacking:
		if UnitShouldRetreat(unit^) {
			unit.order = Order{.Retreat, UnitRetreatPosition(unit.team), INVALID_UNIT_ID}
			unit.state = .Retreating
			UnitRetreat(w, unit, dt)
			return
		}
		switch unit.order.type {
		case .Idle:
			UnitIdle(unit)
		case .Move:
			UnitMove(w, unit, dt)
		case .Attack:
			UnitAttack(w, unit, dt)
		case .Retreat:
			UnitRetreat(w, unit, dt)
		}
	}
}

UnitIdle :: proc(unit: ^Unit) { unit.state = .Idle; unit.velocity = Vec2{} }

UnitMove :: proc(w: ^World, unit: ^Unit, dt: f32) {
	squad := SquadGet(w, unit.squad)
	if squad != nil {
		SquadEnsurePath(w, squad, squad.order.target_pos)
		if len(squad.path) > 0 {
			UnitMoveTo(w, unit, SquadPathTarget(w, squad, unit^), dt)
		} else {
			UnitIdle(unit)
		}
		return
	}
	target := Vec2Add(unit.order.target_pos, unit.formation_offset)
	UnitMoveTo(w, unit, target, dt)
}

UnitAttack :: proc(w: ^World, unit: ^Unit, dt: f32) {
	stats := UnitStatsGet(unit.type)
	target := UnitGet(w, unit.order.target)
	if target == nil || !UnitCanAttack(unit^, target^) {
		unit.order.target = UnitFindTarget(w, unit^, stats.range * 4)
		target = UnitGet(w, unit.order.target)
	}
	if target == nil || !UnitCanAttack(unit^, target^) {
		UnitIdle(unit)
		return
	}
	if unit.ammo <= 0 {
		UnitIdle(unit)
		return
	}
	delta := Vec2Sub(target.pos, unit.pos)
	distance := Vec2Length(delta)
	if distance > stats.range {
		squad := SquadGet(w, unit.squad)
		if squad != nil {
			squad.order.target_pos = target.pos
			squad.intent = .Assault
			squad.formation = .Wedge
			SquadEnsurePath(w, squad, target.pos)
			if len(squad.path) > 0 {
				UnitMoveTo(w, unit, SquadPathTarget(w, squad, unit^), dt)
			} else {
				UnitIdle(unit)
			}
			return
		}
		UnitMoveTo(w, unit, target.pos, dt)
		return
	}
	unit.state = .Attacking
	unit.velocity = Vec2{}
	unit.cooldown -= dt
	if unit.cooldown > 0 do return
	damage := stats.damage * max(0.25, 1 - unit.suppression * 0.5)
	UnitDamage(w, target, damage, stats.suppression)
	unit.ammo -= 1
	unit.cooldown = stats.cooldown
}

UnitCanAttack :: proc(attacker, target: Unit) -> bool {
	if !UnitCanFight(attacker) || !UnitIsAlive(target) do return false
	switch attacker.team {
	case .Neutral:
		return false
	case .A, .B:
		return attacker.team != target.team
	}
	unreachable()
}

UnitMoveTo :: proc(w: ^World, unit: ^Unit, target: Vec2, dt: f32) {
	destination := Vec2Clamp(target, Vec2{}, w.max_size)
	delta := Vec2Sub(destination, unit.pos)
	distance := Vec2Length(delta)
	travel := UnitMoveSpeed(w, unit^) * dt
	if distance <= max(0.1, travel) {
		unit.pos = destination
		UnitIdle(unit)
		return
	}
	unit.state = .Moving
	unit.velocity = Vec2Scale(Vec2Normalize(delta), UnitMoveSpeed(w, unit^))
	unit.pos = Vec2Clamp(Vec2Add(unit.pos, Vec2Scale(unit.velocity, dt)), Vec2{}, w.max_size)
}

UnitDamage :: proc(w: ^World, unit: ^Unit, damage, suppression: f32) {
	if !UnitIsAlive(unit^) do return
	cover := max(TerrainCover(WorldTerrainAt(w, unit.pos)), WorldDefenseCover(w, unit.pos, unit.team))
	unit.health -= max(1, damage * (1 - cover))
	UnitSuppress(unit, suppression)
	if unit.health <= 0 {
		unit.health = 0
		unit.state = .Dead
		unit.velocity = Vec2{}
		unit.order = Order{.Idle, unit.pos, INVALID_UNIT_ID}
		return
	}
	if unit.health <= unit.max_health * 0.35 do unit.state = .Wounded
}

UnitMoveSpeed :: proc(w: ^World, unit: Unit) -> f32 {
	stats := UnitStatsGet(unit.type)
	terrain_speed := TerrainSpeed(WorldTerrainAt(w, unit.pos))
	suppression_speed := max(0.25, 1 - unit.suppression * 0.5)
	return stats.speed * terrain_speed * suppression_speed
}

UnitSuppress :: proc(unit: ^Unit, amount: f32) {
	unit.suppression = clamp(unit.suppression + amount, 0, 1)
	unit.morale = clamp(unit.morale - amount * 0.4, 0, 1)
}

UnitCombatRecovery :: proc(unit: ^Unit, dt: f32) {
	if !UnitIsAlive(unit^) do return
	unit.suppression = max(0, unit.suppression - dt * 0.3)
	morale_change := dt * 0.02
	if unit.suppression > 0.5 do morale_change = -dt * 0.04
	if unit.health < unit.max_health * 0.5 do morale_change -= dt * 0.02
	unit.morale = clamp(unit.morale + morale_change, 0, 1)
}

UnitShouldRetreat :: proc(unit: Unit) -> bool {
	return UnitCanFight(unit) && (unit.morale <= 0.2 || unit.health <= unit.max_health * 0.15)
}

UnitRetreatPosition :: proc(team: Team) -> Vec2 {
	switch team {
	case .Neutral:
		return Vec2{128, 128}
	case .A:
		return Vec2{4, 4}
	case .B:
		return Vec2{252, 252}
	}
	unreachable()
}

UnitRetreat :: proc(w: ^World, unit: ^Unit, dt: f32) {
	destination := UnitRetreatPosition(unit.team)
	squad := SquadGet(w, unit.squad)
	if squad != nil {
		squad.intent = .Withdraw
		squad.order = Order{.Retreat, destination, INVALID_UNIT_ID}
		SquadEnsurePath(w, squad, destination)
		if len(squad.path) > 0 {
			unit.state = .Retreating
			UnitMoveTo(w, unit, SquadPathTarget(w, squad, unit^), dt)
			if Vec2Length(Vec2Sub(destination, unit.pos)) > 1 do unit.state = .Retreating
			if Vec2Length(Vec2Sub(destination, unit.pos)) <= 1 do unit.morale = max(unit.morale, 0.45)
			if Vec2Length(Vec2Sub(destination, unit.pos)) <= 1 {
				unit.suppression = 0
				unit.order = Order{.Idle, unit.pos, INVALID_UNIT_ID}
				UnitIdle(unit)
			}
			unit.velocity = Vec2{}
			unit.state = .Retreating
			return
		}
	}
	delta := Vec2Sub(destination, unit.pos)
	distance := Vec2Length(delta)
	travel := UnitMoveSpeed(w, unit^) * 1.25 * dt
	if distance <= max(0.1, travel) {
		unit.pos = destination
		unit.morale = max(unit.morale, 0.45)
		unit.suppression = 0
		unit.order = Order{.Idle, unit.pos, INVALID_UNIT_ID}
		UnitIdle(unit)
		return
	}
	unit.state = .Retreating
	unit.velocity = Vec2Scale(Vec2Normalize(delta), UnitMoveSpeed(w, unit^) * 1.25)
	unit.pos = Vec2Clamp(Vec2Add(unit.pos, Vec2Scale(unit.velocity, dt)), Vec2{}, w.max_size)
}

UnitWoundedUpdate :: proc(w: ^World, unit: ^Unit, dt: f32) {
	unit.velocity = Vec2{}
	if unit.order.type == .Attack do return
	if !WorldCanResupply(w, unit^) {
		destination := WorldFindResupplyPosition(w, unit.team, unit.pos)
		squad := SquadGet(w, unit.squad)
		if squad != nil {
			squad.intent = .Resupply
			squad.order = Order{.Move, destination, INVALID_UNIT_ID}
			SquadEnsurePath(w, squad, destination)
			if len(squad.path) > 0 {
				UnitMoveTo(w, unit, SquadPathTarget(w, squad, unit^), dt)
				unit.state = .Wounded
			}
		}
		return
	}
	heal := WorldConsumeResource(w, unit.team, WorldSectorAtPosition(w, unit.pos), .Materials, 6 * dt)
	unit.health = min(unit.max_health, unit.health + heal)
	if unit.health >= unit.max_health * 0.5 {
		unit.morale = max(unit.morale, 0.5)
		unit.state = .Idle
	}
}

UnitFindTarget :: proc(w: ^World, attacker: Unit, max_distance: f32) -> UnitId {
	found := INVALID_UNIT_ID
	closest := max_distance
	stats := UnitStatsGet(attacker.type)
	for target in w.units {
		if target.id == attacker.id || !UnitCanAttack(attacker, target) do continue
		distance := Vec2Length(Vec2Sub(target.pos, attacker.pos))
		if distance > stats.range * 1.5 && !WorldCanObserve(w, attacker.team, target.pos) do continue
		if distance <= closest {
			found = target.id
			closest = distance
		}
	}
	return found
}

WorldCanResupply :: proc(w: ^World, unit: Unit) -> bool {
	base := UnitRetreatPosition(unit.team)
	if Vec2Length(Vec2Sub(unit.pos, base)) <= 8 do return true
	sector_id := WorldSectorAtPosition(w, unit.pos)
	if sector_id == INVALID_SECTOR_ID do return false
	if WorldSectorHasBuilding(w, sector_id, unit.team, .SupplyDepot) || WorldSectorHasBuilding(w, sector_id, unit.team, .ReinforcementCenter) do return true
	for building in w.buildings {
		if building.complete && !building.destroyed && building.team == unit.team && building.type == .Headquarters && Vec2Length(Vec2Sub(building.pos, unit.pos)) <= 8 do return true
	}
	return false
}


WorldUpdateSupply :: proc(w: ^World, dt: f32) {
	for &unit in w.units {
		if !UnitIsAlive(unit) || unit.state == .Attacking || !WorldCanResupply(w, unit) do continue
		amount := min(unit.max_ammo - unit.ammo, 5 * dt)
		unit.ammo += WorldConsumeResource(w, unit.team, WorldSectorAtPosition(w, unit.pos), .Munitions, amount)
	}
}

SquadReinforce :: proc(w: ^World, id: SquadId, count: int) -> int {
	squad := SquadGet(w, id)
	if squad == nil || count <= 0 do return 0
	position := squad.order.target_pos
	for unit_id in squad.units {
		unit := UnitGet(w, unit_id)
		if unit != nil && UnitIsAlive(unit^) {
			position = unit.pos
			break
		}
	}
	stats := UnitStatsGet(squad.type)
	cost := stats.health * 0.1
	spawned := 0
	for index: int = 0; index < count; index += 1 {
		if WorldConsumeResource(w, squad.team, WorldSectorAtPosition(w, position), .Materials, cost) < cost do break
		offset := SquadFormationOffset(len(squad.units))
		unit_id := UnitSpawn(w, id, squad.team, squad.type, Vec2Add(position, offset), offset)
		append(&squad.units, unit_id)
		spawned += 1
	}
	return spawned
}


SquadIsAlive :: proc(w: ^World, id: SquadId) -> bool {
	squad := SquadGet(w, id)
	if squad == nil do return false
	for unit_id in squad.units {
		unit := UnitGet(w, unit_id)
		if unit != nil && UnitIsAlive(unit^) do return true
	}
	return false
}

WorldUpdateSquads :: proc(w: ^World) {
	for &squad in w.squads {
		if !SquadIsAlive(w, squad.id) {
			squad.order = Order{.Idle, Vec2{}, INVALID_UNIT_ID}
			squad.intent = .Idle
			continue
		}
		switch squad.intent {
		case .Escort, .Raid:
			convoy := WorldConvoyGet(w, squad.convoy)
			if convoy == nil {
				squad.intent = .Idle
				squad.convoy = INVALID_CONVOY_ID
				SquadSetOrder(w, squad.id, Order{.Idle, WorldSquadLeaderPosition(w, squad), INVALID_UNIT_ID})
				continue
			}
			squad.order = Order{.Move, WorldConvoyPosition(w, convoy^), INVALID_UNIT_ID}
		case .Withdraw:
			squad.order = Order{.Retreat, UnitRetreatPosition(squad.team), INVALID_UNIT_ID}
		case .Resupply:
			squad.order = Order{.Move, WorldFindResupplyPosition(w, squad.team, WorldSquadLeaderPosition(w, squad)), INVALID_UNIT_ID}
		case .Defend:
			squad.order.target_pos = WorldFindLocalCoverPosition(w, squad.team, squad.order.target_pos)
			squad.order.type = .Move
		case .Advance, .Probe, .Assault, .Idle:
			if squad.intent == .Assault && squad.order.target != INVALID_UNIT_ID {
				target := UnitGet(w, squad.order.target)
				if target != nil && UnitIsAlive(target^) do squad.order.target_pos = target.pos
			}
		}
		if squad.order.type == .Move || squad.order.type == .Retreat || squad.intent == .Defend || squad.intent == .Resupply || squad.intent == .Escort || squad.intent == .Raid {
			SquadEnsurePath(w, &squad, squad.order.target_pos)
		}
		for unit_id in squad.units {
			unit := UnitGet(w, unit_id)
			if unit != nil && UnitIsAlive(unit^) do unit.order = squad.order
		}
	}
}

UnitDefaultChar :: proc(type: UnitType) -> rune {
	switch type {
	case .Line:
		return 'o'
	case .Assault:
		return 'a'
	case .Heavy:
		return 'H'
	case .Scout:
		return 's'
	case .Engineer:
		return 'e'
	case .Vehicle:
		return 'V'
	case .Equipment:
		return 'E'
	case .Artillery:
		return 'A'
	}
	unreachable()
}

WorldUpdateSectors :: proc(w: ^World, dt: f32) {
	for &sector in w.sectors {
		presence: [3]int
		for unit in w.units {
			if UnitIsAlive(unit) && UnitInRect(unit, sector.bounds) do presence[TeamIndex(unit.team)] += 1
		}
		for building in w.buildings {
			if building.complete && building.type == .Defense && WorldSectorAtPosition(w, building.pos) == sector.id do presence[TeamIndex(building.team)] += 2
		}
		leader := WorldSectorLeader(presence)
		switch leader {
		case .Neutral:
			sector.capture = MoveTowards(sector.capture, 0, dt * 0.25)
		case .A:
			sector.capture = MoveTowards(sector.capture, 1, dt * 0.25)
		case .B:
			sector.capture = MoveTowards(sector.capture, -1, dt * 0.25)
		}
		switch {
		case sector.capture >= 1:
			sector.team = .A
		case sector.capture <= -1:
			sector.team = .B
		case sector.capture > -1 && sector.capture < 1:
			sector.team = .Neutral
		}
	}
}

WorldSectorLeader :: proc(presence: [3]int) -> Team {
	switch {
	case presence[1] == 0 && presence[2] == 0:
		return .Neutral
	case presence[1] > presence[2]:
		return .A
	case presence[2] > presence[1]:
		return .B
	case presence[1] == presence[2]:
		return .Neutral
	}
	unreachable()
}

MoveTowards :: proc(value, target, amount: f32) -> f32 {
	if value < target do return min(value + amount, target)
	if value > target do return max(value - amount, target)
	return value
}
