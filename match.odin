package main

MATCH_DEFAULT_TIME_LIMIT :: 20 * 60
MATCH_REINFORCEMENT_LIMIT :: 100

WorldSetupMatch :: proc(w: ^World) {
	for &squad in w.squads {
		delete(squad.units)
		delete(squad.path)
	}
	resize(&w.units, 0)
	resize(&w.squads, 0)
	resize(&w.buildings, 0)
	resize(&w.cargo, 0)
	resize(&w.convoys, 0)
	resize(&w.strikes, 0)
	resize(&w.shells, 0)
	resize(&w.effects, 0)
	resize(&w.bodies, 0)
	w.cargo_lost = 0
	w.next_cargo_id = CargoId(1)
	w.next_convoy_id = ConvoyId(1)
	w.tick = 0
	w.time = 0
	w.accumulator = 0
	w.match_state = .Setup
	w.match_time = 0
	w.match_time_limit = MATCH_DEFAULT_TIME_LIMIT
	w.winner = .Neutral
	w.reinforcements = [3]int{0, MATCH_REINFORCEMENT_LIMIT, MATCH_REINFORCEMENT_LIMIT}
	w.reinforcement_limit = [3]int{0, MATCH_REINFORCEMENT_LIMIT, MATCH_REINFORCEMENT_LIMIT}

	WorldSetTeamFaction(w, .A, .BastionDirectorate)
	WorldSetTeamFaction(w, .B, .FreeMarches)
	for &sector in w.sectors {
		sector.team = .Neutral
		sector.capture = 0
		sector.inventory = ResourceInventory{}
		sector.requested = ResourceInventory{}
		sector.objective = .None
		sector.objective_team = .Neutral
		sector.objective_value = 0
	}
	for &route in w.routes {
		route.damaged = false
		route.blocked = false
		route.danger = 0
	}
	w.route_revision += 1

	WorldSetMatchObjective(w, SectorId(1), .Base, .A, 0)
	WorldSetMatchObjective(w, SectorId(16), .Base, .B, 0)
	strategic_sectors := [4]SectorId{SectorId(6), SectorId(7), SectorId(10), SectorId(11)}
	for sector_id in strategic_sectors {
		WorldSetMatchObjective(w, sector_id, .Strategic, .Neutral, 1)
	}
	resource_sectors := [4]SectorId{SectorId(2), SectorId(5), SectorId(12), SectorId(15)}
	for sector_id in resource_sectors {
		WorldSetMatchObjective(w, sector_id, .Resource, .Neutral, 1)
	}

	WorldSetMatchSectorControl(w, SectorId(1), .A, 1)
	WorldSetMatchSectorControl(w, SectorId(16), .B, -1)

	BuildingPlace(w, .A, .Headquarters, Vec2{16, 16}, LOCAL_PLAYER_ID)
	infantry_a := BuildingPlace(w, .A, .InfantryProduction, Vec2{30, 16}, LOCAL_PLAYER_ID)
	vehicle_a := BuildingPlace(w, .A, .VehicleWorkshop, Vec2{46, 16}, LOCAL_PLAYER_ID)
	BuildingPlace(w, .A, .Warehouse, Vec2{48, 42}, LOCAL_PLAYER_ID)
	BuildingPlace(w, .A, .SupplyDepot, Vec2{30, 42}, LOCAL_PLAYER_ID)
	BuildingPlace(w, .A, .Defense, Vec2{16, 42}, LOCAL_PLAYER_ID)
	BuildingPlace(w, .A, .ResourceSite, Vec2{80, 16}, LOCAL_PLAYER_ID, .Materials)
	BuildingPlace(w, .A, .Refinery, Vec2{16, 80}, LOCAL_PLAYER_ID)
	BuildingPlace(w, .A, .MunitionsFactory, Vec2{48, 80}, LOCAL_PLAYER_ID)
	BuildingQueueForPlayer(w, LOCAL_PLAYER_ID, infantry_a, .Assault)
	BuildingQueueForPlayer(w, LOCAL_PLAYER_ID, vehicle_a, .Vehicle)
	SquadSpawn(w, .A, .Line, 8, Vec2{22, 24}, LOCAL_PLAYER_ID)
	SquadSpawn(w, .A, .Assault, 6, Vec2{32, 30}, LOCAL_PLAYER_ID)
	SquadSpawn(w, .A, .Engineer, 4, Vec2{40, 40}, LOCAL_PLAYER_ID)

	BuildingPlace(w, .B, .Headquarters, Vec2{240, 240}, PLAYER_TWO_ID)
	infantry_b := BuildingPlace(w, .B, .InfantryProduction, Vec2{226, 240}, PLAYER_TWO_ID)
	vehicle_b := BuildingPlace(w, .B, .VehicleWorkshop, Vec2{210, 240}, PLAYER_TWO_ID)
	BuildingPlace(w, .B, .Warehouse, Vec2{208, 214}, PLAYER_TWO_ID)
	BuildingPlace(w, .B, .SupplyDepot, Vec2{226, 214}, PLAYER_TWO_ID)
	BuildingPlace(w, .B, .Defense, Vec2{240, 214}, PLAYER_TWO_ID)
	BuildingPlace(w, .B, .ResourceSite, Vec2{176, 240}, PLAYER_TWO_ID, .Materials)
	BuildingPlace(w, .B, .Refinery, Vec2{240, 176}, PLAYER_TWO_ID)
	BuildingPlace(w, .B, .MunitionsFactory, Vec2{208, 208}, PLAYER_TWO_ID)
	BuildingQueueForPlayer(w, PLAYER_TWO_ID, infantry_b, .Line)
	BuildingQueueForPlayer(w, PLAYER_TWO_ID, vehicle_b, .Vehicle)
	SquadSpawn(w, .B, .Line, 8, Vec2{234, 232}, PLAYER_TWO_ID)
	SquadSpawn(w, .B, .Assault, 6, Vec2{224, 226}, PLAYER_TWO_ID)
	SquadSpawn(w, .B, .Engineer, 4, Vec2{216, 216}, PLAYER_TWO_ID)

	w.match_state = .Running
}

WorldResetMatch :: proc(w: ^World) {
	WorldDeinit(w)
	WorldInit(w)
	WorldSetupMatch(w)
}

WorldSetMatchObjective :: proc(w: ^World, sector_id: SectorId, objective: SectorObjectiveType, objective_team: Team, value: int) -> bool {
	sector := WorldSectorGet(w, sector_id)
	if sector == nil do return false
	sector.objective = objective
	sector.objective_team = objective_team
	sector.objective_value = max(0, value)
	return true
}

WorldSetMatchSectorControl :: proc(w: ^World, sector_id: SectorId, team: Team, capture: f32) -> bool {
	sector := WorldSectorGet(w, sector_id)
	if sector == nil do return false
	sector.team = team
	sector.capture = clamp(capture, -1, 1)
	return true
}

WorldBaseSector :: proc(w: ^World, team: Team) -> SectorId {
	if team == .Neutral do return INVALID_SECTOR_ID
	for sector in w.sectors {
		if sector.objective == .Base && sector.objective_team == team do return sector.id
	}
	return INVALID_SECTOR_ID
}

WorldIsBaseSector :: proc(w: ^World, sector_id: SectorId) -> bool {
	sector := WorldSectorGet(w, sector_id)
	return sector != nil && sector.objective == .Base
}

WorldTeamControlsBase :: proc(w: ^World, team: Team) -> bool {
	base_id := WorldBaseSector(w, team)
	base := WorldSectorGet(w, base_id)
	return base != nil && base.team == team
}

WorldTeamAliveSquadCount :: proc(w: ^World, team: Team) -> int {
	count := 0
	for squad in w.squads {
		if squad.team == team && SquadIsAlive(w, squad.id) do count += 1
	}
	return count
}

WorldTeamReinforcements :: proc(w: ^World, team: Team) -> int {
	if team == .Neutral do return 0
	return w.reinforcements[TeamIndex(team)]
}

WorldConsumeReinforcement :: proc(w: ^World, team: Team, amount: int) -> int {
	if team == .Neutral || amount <= 0 do return 0
	index := TeamIndex(team)
	consumed := min(amount, max(0, w.reinforcements[index]))
	w.reinforcements[index] -= consumed
	return consumed
}

WorldEvaluateMatch :: proc(w: ^World) {
	if w.match_state != .Running do return
	base_a := WorldBaseSector(w, .A)
	base_b := WorldBaseSector(w, .B)
	base_a_sector := WorldSectorGet(w, base_a)
	base_b_sector := WorldSectorGet(w, base_b)
	if base_a_sector != nil && base_b_sector != nil {
		if base_a_sector.team == .B && base_b_sector.team == .A {
			w.match_state = .Draw
			w.winner = .Neutral
			return
		}
		if base_b_sector.team == .A {
			w.match_state = .Victory
			w.winner = .A
			return
		}
		if base_a_sector.team == .B {
			w.match_state = .Defeat
			w.winner = .B
			return
		}
	}

	strategic_count := 0
	strategic_a := 0
	strategic_b := 0
	for sector in w.sectors {
		if sector.objective != .Strategic do continue
		strategic_count += 1
		if sector.team == .A do strategic_a += 1
		if sector.team == .B do strategic_b += 1
	}
	if strategic_count > 0 && strategic_a == strategic_count {
		w.match_state = .Victory
		w.winner = .A
		return
	}
	if strategic_count > 0 && strategic_b == strategic_count {
		w.match_state = .Defeat
		w.winner = .B
		return
	}
	if WorldTeamReinforcements(w, .A) <= 0 && WorldTeamAliveSquadCount(w, .A) == 0 {
		w.match_state = .Defeat
		w.winner = .B
		return
	}
	if WorldTeamReinforcements(w, .B) <= 0 && WorldTeamAliveSquadCount(w, .B) == 0 {
		w.match_state = .Victory
		w.winner = .A
		return
	}
	if w.match_time_limit > 0 && w.match_time >= w.match_time_limit {
		w.match_state = .Draw
		w.winner = .Neutral
	}
}

WorldUpdateMatch :: proc(w: ^World, dt: f32) {
	if w.match_state != .Running do return
	w.match_time += max(0, dt)
	WorldEvaluateMatch(w)
}
