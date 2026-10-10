package main

PATH_COST_BLOCKED :: f32(999999)

TerrainPathCost :: proc(terrain: TerrainType) -> f32 {
	switch terrain {
	case .Open, .LightCover, .HeavyCover:
		return 1
	case .Road:
		return 0.55
	case .Bridge:
		return 0.7
	case .Rough:
		return 1.5
	case .Damaged:
		return 1.8
	case .Crater:
		return 2.4
	case .Chokepoint:
		return 3.5
	case .Blocked:
		return PATH_COST_BLOCKED
	}
	unreachable()
}

TerrainPathPassable :: proc(terrain: TerrainType) -> bool {
	return terrain != .Blocked
}

WorldTerrainCellAtPosition :: proc(w: ^World, position: Vec2) -> int {
	cell_width := w.max_size.x / f32(w.terrain_width)
	cell_height := w.max_size.y / f32(w.terrain_height)
	x := clamp(int(position.x / cell_width), 0, w.terrain_width - 1)
	y := clamp(int(position.y / cell_height), 0, w.terrain_height - 1)
	return y * w.terrain_width + x
}

WorldTerrainCellCenter :: proc(w: ^World, index: int) -> Vec2 {
	x := index % w.terrain_width
	y := index / w.terrain_width
	cell_width := w.max_size.x / f32(w.terrain_width)
	cell_height := w.max_size.y / f32(w.terrain_height)
	return Vec2{(f32(x) + 0.5) * cell_width, (f32(y) + 0.5) * cell_height}
}

WorldTacticalPath :: proc(w: ^World, start, goal: Vec2) -> [dynamic]Vec2 {
	path := make([dynamic]Vec2)
	cell_count := w.terrain_width * w.terrain_height
	if cell_count <= 0 do return path

	start_cell := WorldTerrainCellAtPosition(w, start)
	goal_cell := WorldTerrainCellAtPosition(w, goal)
	g_score: [256]f32
	came_from: [256]int
	open: [256]bool
	closed: [256]bool
	for index: int = 0; index < cell_count; index += 1 {
		g_score[index] = PATH_COST_BLOCKED
		came_from[index] = -1
	}
	g_score[start_cell] = 0
	open[start_cell] = true

	for {
		current := -1
		best_score := PATH_COST_BLOCKED
		for index: int = 0; index < cell_count; index += 1 {
			if !open[index] do continue
			cell := WorldTerrainCellCenter(w, index)
			goal_distance := Vec2Length(Vec2Sub(WorldTerrainCellCenter(w, goal_cell), cell)) / max(1, f32(w.max_size.x / f32(w.terrain_width)))
			score := g_score[index] + goal_distance
			if score < best_score {
				best_score = score
				current = index
			}
		}
		if current < 0 do break
		if current == goal_cell do break
		open[current] = false
		closed[current] = true
		current_x := current % w.terrain_width
		current_y := current / w.terrain_width
		directions := [8]Vec2{Vec2{1, 0}, Vec2{-1, 0}, Vec2{0, 1}, Vec2{0, -1}, Vec2{1, 1}, Vec2{1, -1}, Vec2{-1, 1}, Vec2{-1, -1}}
		for direction in directions {
			next_x := current_x + int(direction.x)
			next_y := current_y + int(direction.y)
			if next_x < 0 || next_y < 0 || next_x >= w.terrain_width || next_y >= w.terrain_height do continue
			next := next_y * w.terrain_width + next_x
			if closed[next] || !TerrainPathPassable(w.terrain[next]) do continue
			step_cost := TerrainPathCost(w.terrain[next])
			if direction.x != 0 && direction.y != 0 do step_cost *= 1.4142
			candidate := g_score[current] + step_cost
			if candidate >= g_score[next] do continue
			came_from[next] = current
			g_score[next] = candidate
			open[next] = true
		}
	}

	if start_cell != goal_cell && came_from[goal_cell] < 0 do return path
	current := goal_cell
	for {
		append(&path, WorldTerrainCellCenter(w, current))
		if current == start_cell do break
		current = came_from[current]
	}
	for left: int = 0; left < len(path) / 2; left += 1 {
		right := len(path) - 1 - left
		temporary := path[left]
		path[left] = path[right]
		path[right] = temporary
	}
	if len(path) > 0 do path[len(path) - 1] = goal
	return path
}

WorldSectorRouteBetween :: proc(w: ^World, from, to: SectorId) -> ^SectorRoute {
	for &route in w.routes {
		if (route.from == from && route.to == to) || (route.from == to && route.to == from) do return &route
	}
	return nil
}

WorldSectorRouteCost :: proc(route: SectorRoute, avoid_danger: bool) -> f32 {
	cost: f32 = 1
	switch route.type {
	case .Road:
		cost = 1
	case .Bridge:
		cost = 1.2
	case .Chokepoint:
		cost = 1.8
	}
	if route.damaged do cost += 2
	if avoid_danger do cost += route.danger * 8
	return cost
}

WorldSetSectorRouteDamaged :: proc(w: ^World, from, to: SectorId, damaged: bool) -> bool {
	route := WorldSectorRouteBetween(w, from, to)
	if route == nil do return false
	route.damaged = damaged
	w.route_revision += 1
	return true
}

WorldSetSectorRouteBlocked :: proc(w: ^World, from, to: SectorId, blocked: bool) -> bool {
	route := WorldSectorRouteBetween(w, from, to)
	if route == nil do return false
	route.blocked = blocked
	w.route_revision += 1
	return true
}

WorldSetSectorRouteDanger :: proc(w: ^World, from, to: SectorId, danger: f32) -> bool {
	route := WorldSectorRouteBetween(w, from, to)
	if route == nil do return false
	route.danger = clamp(danger, 0, 1)
	w.route_revision += 1
	return true
}

WorldFindStrategicSectorPath :: proc(w: ^World, origin, destination: SectorId, team: Team, avoid_danger: bool) -> [dynamic]SectorId {
	path := make([dynamic]SectorId)
	origin_index := int(origin) - 1
	destination_index := int(destination) - 1
	if origin == INVALID_SECTOR_ID || destination == INVALID_SECTOR_ID || origin_index < 0 || destination_index < 0 || origin_index >= len(w.sectors) || destination_index >= len(w.sectors) do return path
	if team != .Neutral && (w.sectors[origin_index].team != team || w.sectors[destination_index].team != team) do return path

	g_score: [16]f32
	came_from: [16]int
	open: [16]bool
	closed: [16]bool
	for index: int = 0; index < 16; index += 1 {
		g_score[index] = PATH_COST_BLOCKED
		came_from[index] = -1
	}
	g_score[origin_index] = 0
	open[origin_index] = true
	for {
		current := -1
		best_score := PATH_COST_BLOCKED
		for index: int = 0; index < 16; index += 1 {
			if !open[index] do continue
			current_pos := WorldSectorCoordinates(SectorId(uint(index + 1)))
			goal_pos := WorldSectorCoordinates(destination)
			score := g_score[index] + abs(current_pos.x - goal_pos.x) + abs(current_pos.y - goal_pos.y)
			if score < best_score {
				best_score = score
				current = index
			}
		}
		if current < 0 do break
		if current == destination_index do break
		open[current] = false
		closed[current] = true
		current_x := current % 4
		current_y := current / 4
		directions := [4]Vec2{Vec2{1, 0}, Vec2{-1, 0}, Vec2{0, 1}, Vec2{0, -1}}
		for direction in directions {
			next_x := current_x + int(direction.x)
			next_y := current_y + int(direction.y)
			if next_x < 0 || next_y < 0 || next_x >= 4 || next_y >= 4 do continue
			next_index := next_y * 4 + next_x
			if closed[next_index] do continue
			next_sector := SectorId(uint(next_index + 1))
			if team != .Neutral && w.sectors[next_index].team != team do continue
			route := WorldSectorRouteBetween(w, SectorId(uint(current + 1)), next_sector)
			if route == nil || route.blocked do continue
			candidate := g_score[current] + WorldSectorRouteCost(route^, avoid_danger)
			if candidate >= g_score[next_index] do continue
			came_from[next_index] = current
			g_score[next_index] = candidate
			open[next_index] = true
		}
	}

	if origin_index != destination_index && came_from[destination_index] < 0 do return path
	current := destination_index
	for {
		append(&path, SectorId(uint(current + 1)))
		if current == origin_index do break
		current = came_from[current]
	}
	for left: int = 0; left < len(path) / 2; left += 1 {
		right := len(path) - 1 - left
		temporary := path[left]
		path[left] = path[right]
		path[right] = temporary
	}
	return path
}

WorldStrategicPathTravelTime :: proc(path: []SectorId) -> f32 {
	return max(0.5, f32(max(0, len(path) - 1)) * CARGO_BASE_TRAVEL_TIME)
}

WorldSquadLeaderPosition :: proc(w: ^World, squad: Squad) -> Vec2 {
	for unit_id in squad.units {
		unit := UnitGet(w, unit_id)
		if unit != nil && UnitIsAlive(unit^) do return unit.pos
	}
	return squad.order.target_pos
}

SquadPathAppendSegment :: proc(path: ^[dynamic]Vec2, segment: []Vec2) {
	start_index := 0
	if len(path) > 0 && len(segment) > 0 do start_index = 1
	for index := start_index; index < len(segment); index += 1 do append(path, segment[index])
}

SquadEnsurePath :: proc(w: ^World, squad: ^Squad, target: Vec2) {
	goal := Vec2Clamp(target, Vec2{}, Vec2Sub(w.max_size, Vec2{0.1, 0.1}))
	if len(squad.path) > 0 && squad.path_goal == goal && squad.path_terrain_revision == w.terrain_revision && squad.path_route_revision == w.route_revision do return
	resize(&squad.path, 0)
	squad.path_index = 0
	squad.path_goal = goal
	squad.path_terrain_revision = w.terrain_revision
	squad.path_route_revision = w.route_revision
	start := WorldSquadLeaderPosition(w, squad^)
	start_sector := WorldSectorAtPosition(w, start)
	goal_sector := WorldSectorAtPosition(w, goal)
	if start_sector == INVALID_SECTOR_ID || goal_sector == INVALID_SECTOR_ID do return

	sector_path := WorldFindStrategicSectorPath(w, start_sector, goal_sector, .Neutral, true)
	defer delete(sector_path)
	if len(sector_path) == 0 do return
	segment := WorldTacticalPath(w, start, goal)
	SquadPathAppendSegment(&squad.path, segment[:])
	delete(segment)
}

SquadAdvancePath :: proc(w: ^World, squad: ^Squad) {
	if len(squad.path) == 0 || squad.path_index >= len(squad.path) do return
	leader := WorldSquadLeaderPosition(w, squad^)
	for squad.path_index < len(squad.path) - 1 {
		if Vec2Length(Vec2Sub(squad.path[squad.path_index], leader)) > 3 do break
		squad.path_index += 1
	}
}

SquadPathTarget :: proc(w: ^World, squad: ^Squad, unit: Unit) -> Vec2 {
	if len(squad.path) == 0 do return Vec2Add(squad.order.target_pos, unit.formation_offset)
	if unit.id == squad.units[0] do SquadAdvancePath(w, squad)
	index := min(squad.path_index, len(squad.path) - 1)
	return Vec2Add(squad.path[index], unit.formation_offset)
}

WorldFindLocalCoverPosition :: proc(w: ^World, team: Team, objective: Vec2) -> Vec2 {
	best := Vec2Clamp(objective, Vec2{}, w.max_size)
	best_cover := TerrainCover(WorldTerrainAt(w, best))
	for y: int = -2; y <= 2; y += 1 {
		for x: int = -2; x <= 2; x += 1 {
			candidate := Vec2Add(objective, Vec2{f32(x) * 8, f32(y) * 8})
			candidate = Vec2Clamp(candidate, Vec2{}, w.max_size)
			cover := TerrainCover(WorldTerrainAt(w, candidate))
			if cover > best_cover && WorldCanObserve(w, team, candidate) {
				best = candidate
				best_cover = cover
			}
		}
	}
	return best
}

WorldFindResupplyPosition :: proc(w: ^World, team: Team, position: Vec2) -> Vec2 {
	best := UnitRetreatPosition(team)
	best_distance := Vec2Length(Vec2Sub(best, position))
	for building in w.buildings {
		if building.destroyed || !building.complete || building.team != team do continue
		if building.type != .Headquarters && building.type != .SupplyDepot && building.type != .ReinforcementCenter do continue
		distance := Vec2Length(Vec2Sub(building.pos, position))
		if distance < best_distance {
			best = building.pos
			best_distance = distance
		}
	}
	return best
}
