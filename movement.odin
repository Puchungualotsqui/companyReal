package main

import "core:math"

FLOW_FIELD_CAPACITY :: 16
FLOW_FIELD_MAX_STEPS :: 8

// Path tiles are cheap to route through and slightly faster to walk on.
PATH_SPEED_MULTIPLIER :: 1.25
PATH_STEP_COST :: 3
PLAIN_STEP_COST :: 4
PATH_HEURISTIC_COST :: 3

// Units hop over their own walls instead of being trapped by them.
WALL_JUMP_SECONDS :: 0.35
WALL_JUMP_HEIGHT :: 0.55

FlowDirection :: enum u8 {
	Blocked,
	None,
	East,
	West,
	South,
	North,
}

FlowFollowResult :: enum {
	Travelling,
	Arrived,
	Unreachable,
}

FlowField :: struct {
	targetKingdom, targetTown: int,
	unitKingdom: int,
	hallX, hallY: int,
	walkWater: bool,
	navigationRevision: u64,
	direction: []FlowDirection,
	valid: bool,
	stamp: u64,
}

WorldNavigationInit :: proc(w: ^World) -> bool {
	node_count := int(w.maxX)*int(w.maxY)
	if node_count <= 0 do return false
	w.tileConstructionBlocked = make([]bool, node_count)
	w.navigationDistance = make([]int, node_count)
	w.navigationCameFrom = make([]int, node_count)
	w.navigationOpen = make([]bool, node_count)
	w.navigationClosed = make([]bool, node_count)
	w.navigationQueue = make([]int, node_count)
	w.navigationStamp = make([]u32, node_count)
	return true
}

WorldNavigationDeinit :: proc(w: ^World) {
	delete(w.tileConstructionBlocked)
	delete(w.navigationDistance)
	delete(w.navigationCameFrom)
	delete(w.navigationOpen)
	delete(w.navigationClosed)
	delete(w.navigationQueue)
	delete(w.navigationStamp)
	for &field in w.flowFields {
		delete(field.direction)
	}
}

AStar :: proc(w: ^World, unit_type: UnitType, unit_kingdom: int, start_x, start_y, goal_x, goal_y: int, path: ^[dynamic]int) -> bool {
	clear(path)
	world_width := int(w.maxX)
	world_height := int(w.maxY)
	if world_width <= 0 || world_height <= 0 do return false

	node_count := world_width*world_height
	if node_count > len(w.navigationDistance) || node_count > len(w.navigationQueue) {
		return false
	}

	wrapped_start_x := WorldWrapCoordinate(start_x, world_width)
	wrapped_start_y := WorldWrapCoordinate(start_y, world_height)
	wrapped_goal_x := WorldWrapCoordinate(goal_x, world_width)
	wrapped_goal_y := WorldWrapCoordinate(goal_y, world_height)

	if !WorldTileWalkable(w, wrapped_goal_x, wrapped_goal_y, unit_type, unit_kingdom) do return false

	start_index := wrapped_start_x*world_height + wrapped_start_y
	goal_index := wrapped_goal_x*world_height + wrapped_goal_y
	infinity := node_count*PLAIN_STEP_COST+1

	came_from := w.navigationCameFrom
	g_score := w.navigationDistance
	is_open := w.navigationOpen
	is_closed := w.navigationClosed
	open_set := w.navigationQueue
	stamp := w.navigationStamp

	// Stamp touched nodes instead of clearing the whole world for every path.
	w.navigationSearchId += 1
	if w.navigationSearchId == 0 {
		for i in 0..<node_count {
			stamp[i] = 0
		}
		w.navigationSearchId = 1
	}
	search_id := w.navigationSearchId

	stamp[start_index] = search_id
	came_from[start_index] = -1
	g_score[start_index] = 0
	is_open[start_index] = true
	is_closed[start_index] = false
	open_count := 0
	open_set[open_count] = start_index
	open_count += 1

	found := false
	for open_count > 0 {
		best_position := 0
		best_index := open_set[0]
		best_score := g_score[best_index] + PATH_HEURISTIC_COST*WorldWrapHeuristic(
			best_index/world_height,
			best_index%world_height,
			wrapped_goal_x,
			wrapped_goal_y,
			world_width,
			world_height,
		)
		for position in 1..<open_count {
			candidate := open_set[position]
			candidate_score := g_score[candidate] + PATH_HEURISTIC_COST*WorldWrapHeuristic(
				candidate/world_height,
				candidate%world_height,
				wrapped_goal_x,
				wrapped_goal_y,
				world_width,
				world_height,
			)
			if candidate_score < best_score {
				best_position = position
				best_index = candidate
				best_score = candidate_score
			}
		}

		open_set[best_position] = open_set[open_count-1]
		open_count -= 1
		is_open[best_index] = false
		if best_index == goal_index {
			found = true
			break
		}
		if is_closed[best_index] do continue
		is_closed[best_index] = true

		current_x := best_index / world_height
		current_y := best_index % world_height
		for direction in 0..<4 {
			next_x := current_x
			next_y := current_y
			switch direction {
			case 0: next_x += 1
			case 1: next_x -= 1
			case 2: next_y += 1
			case 3: next_y -= 1
			}
			next_x = WorldWrapCoordinate(next_x, world_width)
			next_y = WorldWrapCoordinate(next_y, world_height)
			if !WorldTileWalkable(w, next_x, next_y, unit_type, unit_kingdom) do continue

			next_index := next_x*world_height + next_y
			if stamp[next_index] != search_id {
				stamp[next_index] = search_id
				came_from[next_index] = -1
				g_score[next_index] = infinity
				is_open[next_index] = false
				is_closed[next_index] = false
			}
			if is_closed[next_index] do continue
			tentative_score := g_score[best_index] + WorldStepCost(w, next_x, next_y)
			if tentative_score >= g_score[next_index] do continue

			came_from[next_index] = best_index
			g_score[next_index] = tentative_score
			if !is_open[next_index] && open_count < node_count {
				is_open[next_index] = true
				open_set[open_count] = next_index
				open_count += 1
			}
		}
	}

	if found {
		cursor := goal_index
		for {
			append(path, cursor)
			if cursor == start_index do break
			cursor = came_from[cursor]
			if cursor < 0 {
				clear(path)
				found = false
				break
			}
		}
		for i in 0..<len(path)/2 {
			opposite := len(path) - i - 1
			path[i], path[opposite] = path[opposite], path[i]
		}
	}

	return found
}

FLEE_SEARCH_STEPS :: 6
FLEE_SEARCH_CAPACITY :: 1+2*FLEE_SEARCH_STEPS*(FLEE_SEARCH_STEPS+1)
FLEE_THREAT_RADIUS :: 16
FLEE_THREAT_CAPACITY :: 16

UnitNearbyEnemy :: struct {
	slot: int,
	distanceSquared: f32,
}

UnitEnemyDistanceSquared :: proc(w: ^World, x, y: f32, enemy_slot: int) -> f32 {
	dx := WorldShortestWrappedDelta(w.units.x[enemy_slot]-x, f32(w.maxX))
	dy := WorldShortestWrappedDelta(w.units.y[enemy_slot]-y, f32(w.maxY))
	return dx*dx+dy*dy
}

// A wrapped coordinate interval may cross the short final spatial bucket.
UnitNearbyChunkRange :: proc(position, radius, size: f32, chunk_size, chunk_count: int) -> (int, int) {
	if radius >= size*0.5 do return 0, chunk_count
	low, high := position-radius, position+radius
	first := int(WorldWrapPosition(low, size))/chunk_size
	last := int(WorldWrapPosition(high, size))/chunk_size
	count := last-first+1
	if low < 0 || high >= size do count += chunk_count
	return first, min(count, chunk_count)
}

// Keep only the closest threats, visiting each intersecting wrapped chunk once.
UnitCollectNearbyEnemies :: proc(w: ^World, unit_slot: int, radius: f32, enemies: []UnitNearbyEnemy) -> int {
	if unit_slot < 0 || unit_slot >= UNIT_CAPACITY || !w.unitUsed[unit_slot] ||
		w.units[unit_slot].health <= 0 || !(radius >= 0) || len(enemies) == 0 {
				return 0
			}
	if w.maxX <= 0 || w.maxY <= 0 || w.spatial.chunkSize <= 0 ||
		w.spatial.chunksX <= 0 || w.spatial.chunksY <= 0 {
				return 0
			}
	unit := &w.units[unit_slot]
	x := WorldWrapPosition(unit.x, f32(w.maxX))
	y := WorldWrapPosition(unit.y, f32(w.maxY))
	first_x, count_x := UnitNearbyChunkRange(x, radius, f32(w.maxX), w.spatial.chunkSize, w.spatial.chunksX)
	first_y, count_y := UnitNearbyChunkRange(y, radius, f32(w.maxY), w.spatial.chunkSize, w.spatial.chunksY)
	count := 0
	for ox in 0..<count_x {
		cx := WorldWrapCoordinate(first_x+ox, w.spatial.chunksX)
		for oy in 0..<count_y {
			cy := WorldWrapCoordinate(first_y+oy, w.spatial.chunksY)
			chunk := cx*w.spatial.chunksY+cy
			for other := w.spatial.unitHead[chunk]; other >= 0; other = w.spatial.unitNext[other] {
				if other == unit_slot || !w.unitUsed[other] || w.units[other].health <= 0 do continue
				if !KingdomAtWar(w, unit.kingdome, w.units[other].kingdome) || UnitHiddenInside(w, other) do continue
				distance := UnitEnemyDistanceSquared(w, x, y, other)
				if distance > radius*radius do continue
				position := 0
				for position < count {
					entry := enemies[position]
					if distance < entry.distanceSquared || (distance == entry.distanceSquared && other < entry.slot) do break
					position += 1
				}
				if position >= len(enemies) do continue
				count = min(count+1, len(enemies))
				for i := count-1; i > position; i -= 1 do enemies[i] = enemies[i-1]
				enemies[position] = UnitNearbyEnemy{other, distance}
			}
		}
	}
	return count
}

// Visible means outdoors, not player fog-of-war or line of sight.
UnitFindNearbyEnemy :: proc(w: ^World, unit_slot: int, radius: f32) -> int {
	enemies: [1]UnitNearbyEnemy
	if UnitCollectNearbyEnemies(w, unit_slot, radius, enemies[:]) == 0 do return -1
	return enemies[0].slot
}

UnitFleeClearance :: proc(w: ^World, x, y: f32, enemies: []UnitNearbyEnemy) -> f32 {
	distance_squared: f32 = 1e30
	for enemy in enemies {
		distance_squared = min(distance_squared, UnitEnemyDistanceSquared(w, x, y, enemy.slot))
	}
	return math.sqrt(distance_squared)
}

// Builds at most 85 reachable nodes, with no full-map A*. Shared navigation
// scratch is stamped, while the resulting short route belongs to the unit.
UnitFindEscapePath :: proc(w: ^World, unit_slot: int, enemies: []UnitNearbyEnemy) -> bool {
	unit := &w.units[unit_slot]
	width, height := int(w.maxX), int(w.maxY)
	start_x := int(WorldWrapPosition(unit.x, f32(width)))
	start_y := int(WorldWrapPosition(unit.y, f32(height)))
	start := start_x*height+start_y
	clear(&unit.path)
	unit.pathFound = false
	unit.pathReady = true
	unit.pathRevision = w.navigationRevision
	unit.pathIndex = 0
	// Cache failure until the primary threat changes tile or navigation changes.
	unit.pathTargetX = int(WorldWrapPosition(w.units.x[enemies[0].slot], f32(width)))
	unit.pathTargetY = int(WorldWrapPosition(w.units.y[enemies[0].slot], f32(height)))
	if len(w.navigationStamp) < width*height || len(w.navigationQueue) < width*height ||
		len(w.navigationCameFrom) < width*height {
				return false
			}
	w.navigationSearchId += 1
	if w.navigationSearchId == 0 {
		for &stamp in w.navigationStamp do stamp = 0
		w.navigationSearchId = 1
	}
	stamp := w.navigationSearchId
	depth: [FLEE_SEARCH_CAPACITY]int
	route_clearance: [FLEE_SEARCH_CAPACITY]f32
	start_clearance := UnitFleeClearance(w, unit.x, unit.y, enemies)
	route_clearance[0] = start_clearance
	w.navigationQueue[0] = start
	w.navigationStamp[start] = stamp
	w.navigationCameFrom[start] = -1
	queue_end := 1
	best, best_score := start, start_clearance
	for cursor := 0; cursor < queue_end; cursor += 1 {
		index := w.navigationQueue[cursor]
		if depth[cursor] >= FLEE_SEARCH_STEPS do continue
		for direction in 0..<4 {
			nx, ny := index/height, index%height
			switch direction {
			case 0: nx += 1
			case 1: nx -= 1
			case 2: ny += 1
			case 3: ny -= 1
			}
			nx, ny = WorldWrapCoordinate(nx, width), WorldWrapCoordinate(ny, height)
			next := nx*height+ny
			if w.navigationStamp[next] == stamp do continue
			if !WorldTileWalkable(w, nx, ny, unit.type, unit.kingdome) do continue
			clearance := UnitFleeClearance(w, f32(nx)+0.5, f32(ny)+0.5, enemies)
			// Do not escape through an enemy's immediate melee space, unless
			// already that close; small temporary detours remain possible.
			if clearance < min(start_clearance, 1.25) do continue
			if queue_end >= FLEE_SEARCH_CAPACITY do continue
			w.navigationStamp[next] = stamp
			w.navigationCameFrom[next] = index
			depth[queue_end] = depth[cursor]+1
			route_clearance[queue_end] = min(route_clearance[cursor], clearance)
			score := clearance-0.15*f32(depth[queue_end])-
				2*max(0, start_clearance-route_clearance[queue_end])
			if score > best_score+0.001 do best, best_score = next, score
			w.navigationQueue[queue_end] = next
			queue_end += 1
		}
	}
	if best == start do return false
	unit.pathTargetX, unit.pathTargetY = best/height, best%height
	for cursor := best; cursor >= 0; cursor = w.navigationCameFrom[cursor] do append(&unit.path, cursor)
	for i in 0..<len(unit.path)/2 {
		opposite := len(unit.path)-i-1
		unit.path[i], unit.path[opposite] = unit.path[opposite], unit.path[i]
	}
	unit.pathIndex = 1
	unit.pathFound = true
	return true
}

// The caller owns fleeing state and clears pathReady on entry/resume. Returns
// whether a usable escape route exists (also true for a zero-time tick).
UnitFleeEnemy :: proc(w: ^World, unit_slot, enemy_slot: int, delta_time: f32) -> bool {
	if unit_slot < 0 || unit_slot >= UNIT_CAPACITY || !w.unitUsed[unit_slot] ||
		w.units[unit_slot].health <= 0 || delta_time < 0 || w.maxX <= 0 || w.maxY <= 0 {
				return false
			}
	unit := &w.units[unit_slot]
	if enemy_slot < 0 || enemy_slot >= UNIT_CAPACITY || !w.unitUsed[enemy_slot] ||
		w.units[enemy_slot].health <= 0 || UnitHiddenInside(w, enemy_slot) ||
		!KingdomAtWar(w, unit.kingdome, w.units[enemy_slot].kingdome) || UnitHiddenInside(w, unit_slot) {
		unit.pathReady, unit.pathFound = false, false
		return false
	}
	// Include the explicit threat even if outside the local radius or crowded out.
	threats: [FLEE_THREAT_CAPACITY+1]UnitNearbyEnemy
	threats[0] = UnitNearbyEnemy{enemy_slot, 0}
	count := 1+UnitCollectNearbyEnemies(w, unit_slot, FLEE_THREAT_RADIUS, threats[1:])
	enemies := threats[:count]
	clearance := UnitFleeClearance(w, unit.x, unit.y, enemies)
	replan := !unit.pathReady || unit.pathRevision != w.navigationRevision
	if !replan && !unit.pathFound {
		replan = unit.pathTargetX != int(WorldWrapPosition(w.units.x[enemy_slot], f32(w.maxX))) ||
			unit.pathTargetY != int(WorldWrapPosition(w.units.y[enemy_slot], f32(w.maxY)))
	}
	if !replan && unit.pathFound {
		replan = unit.pathIndex >= len(unit.path) || UnitFleeClearance(w,
			f32(unit.pathTargetX)+0.5, f32(unit.pathTargetY)+0.5, enemies)+0.5 < clearance
		if !replan {
			next := unit.path[unit.pathIndex]
			nx, ny := next/int(w.maxY), next%int(w.maxY)
			replan = !WorldTileWalkable(w, nx, ny, unit.type, unit.kingdome) ||
				UnitFleeClearance(w, f32(nx)+0.5, f32(ny)+0.5, enemies)+0.001 < min(clearance, 1.25)
		}
	}
	if replan && !UnitFindEscapePath(w, unit_slot, enemies) do return false
	if !unit.pathFound do return false
	remaining := UnitMoveSpeed(w, unit_slot, UnitDefaultSpeed(unit.type))*delta_time
	for _ in 0..<FLEE_SEARCH_STEPS {
		if remaining <= 0 || unit.pathIndex >= len(unit.path) do break
		next := unit.path[unit.pathIndex]
		nx, ny := next/int(w.maxY), next%int(w.maxY)
		// Check each waypoint, including when a long tick consumes several.
		if UnitFleeClearance(w, f32(nx)+0.5, f32(ny)+0.5, enemies)+0.001 < min(clearance, 1.25) {
			unit.pathReady = false
			return false
		}
		reached, blocked, left := UnitStepTowards(w, unit_slot, f32(nx)+0.5, f32(ny)+0.5, remaining)
		if blocked {
			unit.pathReady, unit.pathFound = false, false
			return false
		}
		remaining = left
		if !reached do break
		unit.pathIndex += 1
	}
	if unit.pathIndex >= len(unit.path) do unit.pathReady = false
	return true
}

// One breadth-first pass per target town builds a shared direction field.
// Every warrior heading to that town follows the same field instead of
// running its own A* search, so pathing cost is independent of unit count.
// Knights and giants share walkability, so one field serves both.
FlowFieldGet :: proc(w: ^World, kingdom, town: int, unit_type: UnitType, unit_kingdom: int) -> (^FlowField, bool) {
	if !WorldTownExists(w, kingdom, town) do return nil, false
	if TownHallSlot(w, kingdom, town) < 0 do return nil, false
	hall_x := w.kingdoms[kingdom].towns[town].x
	hall_y := w.kingdoms[kingdom].towns[town].y
	walk_water := UnitValidTileType(unit_type, .Water)

	slot := -1
	for i in 0..<FLOW_FIELD_CAPACITY {
		field := &w.flowFields[i]
		if field.targetKingdom == kingdom && field.targetTown == town &&
			field.hallX == hall_x && field.hallY == hall_y &&
			field.walkWater == walk_water && field.unitKingdom == unit_kingdom {
			slot = i
			break
		}
	}
	if slot < 0 {
		for i in 0..<FLOW_FIELD_CAPACITY {
			if w.flowFields[i].targetKingdom < 0 {
				slot = i
				break
			}
		}
	}
	if slot < 0 {
		oldest_stamp := max(u64)
		for i in 0..<FLOW_FIELD_CAPACITY {
			if w.flowFields[i].stamp < oldest_stamp {
				oldest_stamp = w.flowFields[i].stamp
				slot = i
			}
		}
	}

	field := &w.flowFields[slot]
	w.flowFieldStamp += 1
	field.stamp = w.flowFieldStamp
	if field.targetKingdom == kingdom && field.targetTown == town &&
		field.hallX == hall_x && field.hallY == hall_y &&
		field.walkWater == walk_water && field.unitKingdom == unit_kingdom &&
		field.navigationRevision == w.navigationRevision {
		return field, field.valid
	}

	field.targetKingdom = kingdom
	field.targetTown = town
	field.unitKingdom = unit_kingdom
	field.hallX = hall_x
	field.hallY = hall_y
	field.walkWater = walk_water
	field.navigationRevision = w.navigationRevision
	field.valid = FlowFieldCompute(w, field)
	return field, field.valid
}

FlowFieldCompute :: proc(w: ^World, field: ^FlowField) -> bool {
	world_width := int(w.maxX)
	world_height := int(w.maxY)
	if world_width <= 0 || world_height <= 0 do return false

	node_count := world_width*world_height
	if node_count > len(w.navigationDistance) || node_count > len(w.navigationQueue) {
		return false
	}
	if len(field.direction) != node_count {
		if field.direction != nil do delete(field.direction)
		field.direction = make([]FlowDirection, node_count)
	}
	for i in 0..<node_count {
		field.direction[i] = .Blocked
	}

	distance := w.navigationDistance
	for i in 0..<node_count {
		distance[i] = -1
	}
	queue := w.navigationQueue
	head, tail := 0, 0

	walk_type: UnitType = Knight{}
	if field.walkWater do walk_type = Turtle{}

	hall_width, hall_height := BuildingTileSize(TownHall{})
	found_source := false
	for radius in 1..=4 {
		ring_min_x := field.hallX-radius+1
		ring_max_x := field.hallX+hall_width-1+radius-1
		ring_min_y := field.hallY-radius+1
		ring_max_y := field.hallY+hall_height-1+radius-1
		for x in field.hallX-radius ..= field.hallX+hall_width-1+radius {
			for y in field.hallY-radius ..= field.hallY+hall_height-1+radius {
				if x >= ring_min_x && x <= ring_max_x && y >= ring_min_y && y <= ring_max_y {
					continue
				}
				wrapped_x := WorldWrapCoordinate(x, world_width)
				wrapped_y := WorldWrapCoordinate(y, world_height)
				if !WorldTileWalkable(w, wrapped_x, wrapped_y, walk_type, field.unitKingdom) do continue
				index := wrapped_x*world_height+wrapped_y
				if distance[index] == 0 do continue
				distance[index] = 0
				field.direction[index] = .None
				queue[tail] = index
				tail += 1
				found_source = true
			}
		}
		if found_source do break
	}
	if !found_source do return false

	for head < tail {
		index := queue[head]
		head += 1
		current_x := index/world_height
		current_y := index%world_height
		for direction in 0..<4 {
			next_x := current_x
			next_y := current_y
			switch direction {
			case 0: next_x = WorldWrapCoordinate(current_x+1, world_width)
			case 1: next_x = WorldWrapCoordinate(current_x-1, world_width)
			case 2: next_y = WorldWrapCoordinate(current_y+1, world_height)
			case 3: next_y = WorldWrapCoordinate(current_y-1, world_height)
			}
			if !WorldTileWalkable(w, next_x, next_y, walk_type, field.unitKingdom) do continue

			next_index := next_x*world_height+next_y
			if distance[next_index] != -1 do continue
			distance[next_index] = distance[index]+1
			switch direction {
			case 0: field.direction[next_index] = .West
			case 1: field.direction[next_index] = .East
			case 2: field.direction[next_index] = .North
			case 3: field.direction[next_index] = .South
			}
			queue[tail] = next_index
			tail += 1
		}
	}
	return true
}

UnitFollowFlowField :: proc(w: ^World, unit_slot: int, field: ^FlowField, delta_time: f32) -> FlowFollowResult {
	unit := &w.units[unit_slot]
	speed := UnitMoveSpeed(w, unit_slot, UnitDefaultSpeed(unit.type))

	remaining := speed*delta_time
	world_width := int(w.maxX)
	world_height := int(w.maxY)
	if world_width <= 0 || world_height <= 0 do return .Unreachable

	for _ in 0..<FLOW_FIELD_MAX_STEPS {
		tile_x := int(WorldWrapPosition(unit.x, f32(world_width)))
		tile_y := int(WorldWrapPosition(unit.y, f32(world_height)))
		direction := field.direction[tile_x*world_height+tile_y]
		next_x, next_y := tile_x, tile_y
		switch direction {
		case .Blocked:
			return .Unreachable
		case .None:
			return .Arrived
		case .East:
			next_x = WorldWrapCoordinate(tile_x+1, world_width)
		case .West:
			next_x = WorldWrapCoordinate(tile_x-1, world_width)
		case .South:
			next_y = WorldWrapCoordinate(tile_y+1, world_height)
		case .North:
			next_y = WorldWrapCoordinate(tile_y-1, world_height)
		}

		reached, blocked, left := UnitStepTowards(
			w,
			unit_slot,
			f32(next_x)+0.5,
			f32(next_y)+0.5,
			remaining,
		)
		if blocked do return .Unreachable
		remaining = left
		if !reached do return .Travelling
		if remaining <= 0 do return .Travelling
	}
	return .Travelling
}

// Choose a reachable work point without routing through the proposed footprint.
// This also works before the site is reserved (for founding-order validation).
BuildingFindWorkAccessPoint :: proc(w: ^World, x, y, width, height: int, unit_type: UnitType, kingdom, start_x, start_y: int) -> (int, int, bool) {
	world_width, world_height := int(w.maxX), int(w.maxY)
	if world_width <= 0 || world_height <= 0 do return 0, 0, false
	work_radius := 0
	for radius in 1..=6 {
		for tile_x in x-radius..=x+width-1+radius {
			for tile_y in y-radius..=y+height-1+radius {
				wrapped_x := WorldWrapCoordinate(tile_x, world_width)
				wrapped_y := WorldWrapCoordinate(tile_y, world_height)
				if BuildingAccessDistance(w, x, y, width, height, wrapped_x, wrapped_y) != radius do continue
				if WorldTileWalkable(w, wrapped_x, wrapped_y, unit_type, kingdom) do work_radius = radius
			}
		}
		if work_radius > 0 do break
	}
	if work_radius == 0 do return 0, 0, false
	w.navigationSearchId += 1
	if w.navigationSearchId == 0 {
		for &stamp in w.navigationStamp do stamp = 0
		w.navigationSearchId = 1
	}
	stamp := w.navigationSearchId
	start := WorldWrapCoordinate(start_x, world_width)*world_height+WorldWrapCoordinate(start_y, world_height)
	w.navigationQueue[0] = start
	w.navigationStamp[start] = stamp
	queue_end := 1
	for cursor := 0; cursor < queue_end; cursor += 1 {
		index := w.navigationQueue[cursor]
		current_x, current_y := index/world_height, index%world_height
		if BuildingAccessDistance(w, x, y, width, height, current_x, current_y) == work_radius &&
			WorldTileWalkable(w, current_x, current_y, unit_type, kingdom) {
			return current_x, current_y, true
		}
		for direction in 0..<4 {
			next_x, next_y := current_x, current_y
			switch direction {
			case 0: next_x += 1
			case 1: next_x -= 1
			case 2: next_y += 1
			case 3: next_y -= 1
			}
			next_x = WorldWrapCoordinate(next_x, world_width)
			next_y = WorldWrapCoordinate(next_y, world_height)
			next_index := next_x*world_height+next_y
			if w.navigationStamp[next_index] == stamp do continue
			if next_x >= x && next_x < x+width && next_y >= y && next_y < y+height do continue
			if !WorldTileWalkable(w, next_x, next_y, unit_type, kingdom) do continue
			w.navigationStamp[next_index] = stamp
			w.navigationQueue[queue_end] = next_index
			queue_end += 1
		}
	}
	return 0, 0, false
}

// Search through the footprint only, stopping at its first walkable exit. This
// avoids moving an occupant across water, other buildings or neighboring sites.
UnitFindBuildingExit :: proc(w: ^World, unit_slot, x, y, width, height: int) -> (int, int, bool) {
	unit := &w.units[unit_slot]
	world_width, world_height := int(w.maxX), int(w.maxY)
	w.navigationSearchId += 1
	if w.navigationSearchId == 0 {
		for &stamp in w.navigationStamp do stamp = 0
		w.navigationSearchId = 1
	}
	stamp := w.navigationSearchId
	start := int(unit.x)*world_height+int(unit.y)
	w.navigationQueue[0] = start
	w.navigationStamp[start] = stamp
	queue_end := 1
	for cursor := 0; cursor < queue_end; cursor += 1 {
		index := w.navigationQueue[cursor]
		current_x, current_y := index/world_height, index%world_height
		for direction in 0..<4 {
			next_x, next_y := current_x, current_y
			switch direction {
			case 0: next_x += 1
			case 1: next_x -= 1
			case 2: next_y += 1
			case 3: next_y -= 1
			}
			next_x = WorldWrapCoordinate(next_x, world_width)
			next_y = WorldWrapCoordinate(next_y, world_height)
			next_index := next_x*world_height+next_y
			if w.navigationStamp[next_index] == stamp do continue
			w.navigationStamp[next_index] = stamp
			inside := next_x >= x && next_x < x+width && next_y >= y && next_y < y+height
			if !inside {
				if WorldTileWalkable(w, next_x, next_y, unit.type, unit.kingdome) {
					return next_x, next_y, true
				}
				continue
			}
			if !WorldTileWalkableBase(w, next_x, next_y, unit.type, unit.kingdome) do continue
			w.navigationQueue[queue_end] = next_index
			queue_end += 1
		}
	}
	return 0, 0, false
}

UnitStepTowards :: proc(w: ^World, unit_slot: int, target_x, target_y, distance: f32) -> (reached: bool, blocked: bool, remaining: f32) {
	remaining = distance
	if unit_slot < 0 || unit_slot >= UNIT_CAPACITY || !w.unitUsed[unit_slot] {
		return false, true, remaining
	}
	world_width := f32(w.maxX)
	world_height := f32(w.maxY)
	if world_width <= 0 || world_height <= 0 do return false, true, remaining

	unit := &w.units[unit_slot]
	defer SpatialUnitMove(w, unit_slot)
	for remaining > 0.0001 {
		delta_x := WorldShortestWrappedDelta(target_x-unit.x, world_width)
		delta_y := WorldShortestWrappedDelta(target_y-unit.y, world_height)
		distance_to_target := math.sqrt(delta_x*delta_x+delta_y*delta_y)
		if distance_to_target <= 0.0001 {
			unit.x = WorldWrapPosition(target_x, world_width)
			unit.y = WorldWrapPosition(target_y, world_height)
			return true, false, remaining
		}

		step := min(distance_to_target, remaining, 1)
		next_x := WorldWrapPosition(unit.x+delta_x/distance_to_target*step, world_width)
		next_y := WorldWrapPosition(unit.y+delta_y/distance_to_target*step, world_height)
		tile_x := int(next_x)
		tile_y := int(next_y)
		current_tile_x := int(WorldWrapPosition(unit.x, world_width))
		current_tile_y := int(WorldWrapPosition(unit.y, world_height))
		if (tile_x != current_tile_x || tile_y != current_tile_y) &&
			!WorldTileWalkable(w, tile_x, tile_y, unit.type, unit.kingdome) {
			return false, true, remaining
		}
		if (tile_x != current_tile_x || tile_y != current_tile_y) &&
			WorldTileFriendlyWall(w, tile_x, tile_y, unit.kingdome) {
			unit.jumpStarted = w.simulationTime
		}

		unit.x = next_x
		unit.y = next_y
		remaining -= step
		if step >= distance_to_target {
			unit.x = WorldWrapPosition(target_x, world_width)
			unit.y = WorldWrapPosition(target_y, world_height)
			return true, false, remaining
		}
	}
	return false, false, remaining
}

WorldTileWalkable :: proc(w: ^World, x, y: int, unit_type: UnitType, unit_kingdom: int) -> bool {
	world_width, world_height := int(w.maxX), int(w.maxY)
	if world_width <= 0 || world_height <= 0 do return false
	index := WorldWrapCoordinate(x, world_width)*world_height+WorldWrapCoordinate(y, world_height)
	if w.tileConstructionBlocked[index] do return false
	return WorldTileWalkableBase(w, x, y, unit_type, unit_kingdom)
}

// Used only when clearing an occupied footprint before reserving or completing it.
WorldTileWalkableBase :: proc(w: ^World, x, y: int, unit_type: UnitType, unit_kingdom: int) -> bool {
	world_width := int(w.maxX)
	world_height := int(w.maxY)
	if world_width <= 0 || world_height <= 0 do return false
	wrapped_x := WorldWrapCoordinate(x, world_width)
	wrapped_y := WorldWrapCoordinate(y, world_height)
	index := wrapped_x*world_height+wrapped_y
	if building_slot := w.tileBuilding[index]; building_slot >= 0 {
		if BuildingKindOf(w.buildings[building_slot].type) == .Wall &&
			w.buildings[building_slot].kingdom == unit_kingdom {
			return true
		}
		return BuildingWalkable(w.buildings[building_slot].type)
	}
	return UnitValidTileType(unit_type, w.ground[wrapped_x][wrapped_y].type)
}

WorldTileFriendlyWall :: proc(w: ^World, x, y: int, kingdom: int) -> bool {
	world_width := int(w.maxX)
	world_height := int(w.maxY)
	if world_width <= 0 || world_height <= 0 do return false
	wrapped_x := WorldWrapCoordinate(x, world_width)
	wrapped_y := WorldWrapCoordinate(y, world_height)
	slot := w.tileBuilding[wrapped_x*world_height+wrapped_y]
	if slot < 0 || slot >= BUILDING_CAPACITY || !w.buildingUsed[slot] do return false
	if BuildingKindOf(w.buildings[slot].type) != .Wall do return false
	return w.buildings[slot].kingdom == kingdom
}

WorldTileHasPath :: proc(w: ^World, x, y: int) -> bool {
	world_width := int(w.maxX)
	world_height := int(w.maxY)
	if world_width <= 0 || world_height <= 0 do return false
	wrapped_x := WorldWrapCoordinate(x, world_width)
	wrapped_y := WorldWrapCoordinate(y, world_height)
	slot := w.tileBuilding[wrapped_x*world_height+wrapped_y]
	if slot < 0 || slot >= BUILDING_CAPACITY || !w.buildingUsed[slot] do return false
	return BuildingKindOf(w.buildings[slot].type) == .Path
}

WorldStepCost :: proc(w: ^World, x, y: int) -> int {
	if WorldTileHasPath(w, x, y) do return PATH_STEP_COST
	return PLAIN_STEP_COST
}

// Base speed adjusted by the tile the unit is standing on.
UnitMoveSpeed :: proc(w: ^World, unit_slot: int, base_speed: f32) -> f32 {
	speed := base_speed
	if w.units[unit_slot].effects[.NoWater] do speed *= 0.7
	tile_x := int(WorldWrapPosition(w.units.x[unit_slot], f32(w.maxX)))
	tile_y := int(WorldWrapPosition(w.units.y[unit_slot], f32(w.maxY)))
	if WorldTileHasPath(w, tile_x, tile_y) do speed *= PATH_SPEED_MULTIPLIER
	return speed
}

WorldWrapCoordinate :: proc(coordinate, size: int) -> int {
	if size <= 0 do return 0
	wrapped := coordinate % size
	if wrapped < 0 do wrapped += size
	return wrapped
}

WorldWrapPosition :: proc(position, size: f32) -> f32 {
	if size <= 0 do return 0
	wrapped := position
	for wrapped < 0 { wrapped += size }
	for wrapped >= size { wrapped -= size }
	return wrapped
}

WorldShortestWrappedDelta :: proc(delta, size: f32) -> f32 {
	half_size := size * 0.5
	if delta > half_size do return delta - size
	if delta < -half_size do return delta + size
	return delta
}

WorldWrapHeuristic :: proc(x, y, goal_x, goal_y, world_width, world_height: int) -> int {
	delta_x := x - goal_x
	delta_y := y - goal_y
	if delta_x < 0 do delta_x = -delta_x
	if delta_y < 0 do delta_y = -delta_y
	delta_x = min(delta_x, world_width-delta_x)
	delta_y = min(delta_y, world_height-delta_y)
	return delta_x + delta_y
}
