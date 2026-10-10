package main

ArtilleryFireForPlayer :: proc(w: ^World, player: PlayerId, building_id: BuildingId, target: Vec2) -> bool {
	building := BuildingGet(w, building_id)
	if building == nil || building.owner != player || building.type != .ArtilleryEmplacement || !WorldBuildingOperational(w, building^) do return false
	return ArtilleryLaunch(w, building.team, building.pos, target) != INVALID_STRIKE_ID
}

ArtilleryFireSquadForPlayer :: proc(w: ^World, player: PlayerId, squad_id: SquadId, target: Vec2) -> bool {
	squad := SquadGet(w, squad_id)
	if squad == nil || squad.owner != player || squad.type != .Artillery || !SquadIsAlive(w, squad_id) do return false
	for unit_id in squad.units {
		unit := UnitGet(w, unit_id)
		if unit != nil && UnitCanFight(unit^) && unit.ammo > 0 {
			unit.ammo -= 1
			return ArtilleryLaunch(w, squad.team, unit.pos, target) != INVALID_STRIKE_ID
		}
	}
	return false
}

ArtilleryLaunch :: proc(w: ^World, team: Team, origin, target: Vec2) -> StrikeId {
	cost := 20
	if team == .Neutral || w.team_supply[TeamIndex(team)] < f32(cost) do return INVALID_STRIKE_ID
	w.team_supply[TeamIndex(team)] -= f32(cost)
	id := StrikeId(uint(len(w.strikes) + 1))
	strike := ArtilleryStrike{id, team, origin, WorldClampPosition(w, target), 0, 0.75, 120, 6, 0.8}
	append(&w.strikes, strike)
	return id
}

WorldUpdateArtillery :: proc(w: ^World, dt: f32) {
	index := 0
	for index < len(w.strikes) {
		strike := &w.strikes[index]
		strike.elapsed += dt
		if strike.elapsed < strike.delay {
			index += 1
			continue
		}
		flight_time := max(0.5, Vec2Length(Vec2Sub(strike.target, strike.origin)) / 40)
		shell := ArtilleryShell{strike.team, strike.origin, strike.origin, strike.target, 0, flight_time, strike.damage, strike.radius, strike.suppression}
		append(&w.shells, shell)
		last := len(w.strikes) - 1
		w.strikes[index] = w.strikes[last]
		resize(&w.strikes, last)
	}

	index = 0
	for index < len(w.shells) {
		shell := &w.shells[index]
		shell.elapsed += dt
		amount := clamp(shell.elapsed / shell.flight_time, 0, 1)
		shell.pos = Vec2Lerp(shell.origin, shell.target, amount)
		if amount < 1 {
			index += 1
			continue
		}
		ArtilleryImpact(w, shell^)
		last := len(w.shells) - 1
		w.shells[index] = w.shells[last]
		resize(&w.shells, last)
	}
	WorldUpdateEffects(w, dt)
}

ArtilleryImpact :: proc(w: ^World, shell: ArtilleryShell) {
	WorldSetTerrainAtPosition(w, shell.target, .Crater)
	WorldSetTerrainAtPosition(w, Vec2Add(shell.target, Vec2{16, 0}), .Damaged)
	ArtilleryAddEffect(w, .Crater, shell.target, 99999, shell.radius)
	ArtilleryAddEffect(w, .Fire, shell.target, 8, shell.radius * 0.6)
	ArtilleryAddEffect(w, .Smoke, shell.target, 12, shell.radius * 0.8)
	ArtilleryAddEffect(w, .Debris, shell.target, 4, shell.radius)

	for &unit in w.units {
		if !UnitIsAlive(unit) do continue
		distance := Vec2Length(Vec2Sub(unit.pos, shell.target))
		if distance > shell.radius do continue
		falloff := max(0.15, 1 - distance / shell.radius)
		was_alive := UnitIsAlive(unit)
		UnitDamage(w, &unit, shell.damage * falloff, shell.suppression * falloff)
		if was_alive && !UnitIsAlive(unit) {
			append(&w.bodies, Body{unit.pos, 0})
			continue
		}
		if UnitIsAlive(unit) && unit.state != .Wounded {
			push := Vec2Scale(Vec2Normalize(Vec2Sub(unit.pos, shell.target)), 2 * falloff)
			unit.pos = WorldClampPosition(w, Vec2Add(unit.pos, push))
			unit.velocity = push
		}
	}

	for &building in w.buildings {
		if building.destroyed || !building.complete do continue
		distance := Vec2Length(Vec2Sub(building.pos, shell.target))
		if distance > shell.radius do continue
		falloff := max(0.15, 1 - distance / shell.radius)
		building.health -= shell.damage * falloff * 0.5
		if building.health > 0 do continue
		building.health = 0
		building.complete = false
		building.destroyed = true
		ArtilleryAddEffect(w, .Wreck, building.pos, 99999, 3)
	}
}

WorldSetTerrainAtPosition :: proc(w: ^World, position: Vec2, terrain: TerrainType) -> bool {
	cell_width := w.max_size.x / f32(w.terrain_width)
	cell_height := w.max_size.y / f32(w.terrain_height)
	x := int(position.x / cell_width)
	y := int(position.y / cell_height)
	return WorldSetTerrainCell(w, x, y, terrain)
}

ArtilleryAddEffect :: proc(w: ^World, type: EffectType, pos: Vec2, lifetime, size: f32) {
	append(&w.effects, Effect{type, pos, 0, lifetime, size})
}

WorldUpdateEffects :: proc(w: ^World, dt: f32) {
	index := 0
	for index < len(w.effects) {
		w.effects[index].age += dt
		if w.effects[index].age < w.effects[index].lifetime {
			index += 1
			continue
		}
		last := len(w.effects) - 1
		w.effects[index] = w.effects[last]
		resize(&w.effects, last)
	}
}
