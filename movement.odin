package main

import "core:math"

FLOW_FIELD_CAPACITY :: 16
FLOW_FIELD_MAX_STEPS :: 8

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
	w.navigationDistance = make([]int, node_count)
	w.navigationCameFrom = make([]int, node_count)
	w.navigationOpen = make([]bool, node_count)
	w.navigationClosed = make([]bool, node_count)
	w.navigationQueue = make([]int, node_count)
	w.navigationStamp = make([]u32, node_count)
	return true
}

WorldNavigationDeinit :: proc(w: ^World) {
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

AStar :: proc(w: ^World, unit_type: UnitType, start_x, start_y, goal_x, goal_y: int, path: ^[dynamic]int) -> bool {
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

	if !WorldTileWalkable(w, wrapped_goal_x, wrapped_goal_y, unit_type) do return false

	start_index := wrapped_start_x*world_height + wrapped_start_y
	goal_index := wrapped_goal_x*world_height + wrapped_goal_y
	infinity := node_count + 1

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
		best_score := g_score[best_index] + WorldWrapHeuristic(
			best_index/world_height,
			best_index%world_height,
			wrapped_goal_x,
			wrapped_goal_y,
			world_width,
			world_height,
		)
		for position in 1..<open_count {
			candidate := open_set[position]
			candidate_score := g_score[candidate] + WorldWrapHeuristic(
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
			if !WorldTileWalkable(w, next_x, next_y, unit_type) do continue

			next_index := next_x*world_height + next_y
			if stamp[next_index] != search_id {
				stamp[next_index] = search_id
				came_from[next_index] = -1
				g_score[next_index] = infinity
				is_open[next_index] = false
				is_closed[next_index] = false
			}
			if is_closed[next_index] do continue
			tentative_score := g_score[best_index] + 1
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

// One breadth-first pass per target town builds a shared direction field.
// Every warrior heading to that town follows the same field instead of
// running its own A* search, so pathing cost is independent of unit count.
// Knights and giants share walkability, so one field serves both.
FlowFieldGet :: proc(w: ^World, kingdom, town: int, unit_type: UnitType) -> (^FlowField, bool) {
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
			field.walkWater == walk_water {
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
		field.walkWater == walk_water &&
		field.navigationRevision == w.navigationRevision {
		return field, field.valid
	}

	field.targetKingdom = kingdom
	field.targetTown = town
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
				if !WorldTileWalkable(w, wrapped_x, wrapped_y, walk_type) do continue
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
			if !WorldTileWalkable(w, next_x, next_y, walk_type) do continue

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
	speed := UnitDefaultSpeed(unit.type)
	if unit.effects[.NoWater] do speed *= 0.7

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
			!WorldTileWalkable(w, tile_x, tile_y, unit.type) {
			return false, true, remaining
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

WorldTileWalkable :: proc(w: ^World, x, y: int, unit_type: UnitType) -> bool {
	world_width := int(w.maxX)
	world_height := int(w.maxY)
	if world_width <= 0 || world_height <= 0 do return false
	wrapped_x := WorldWrapCoordinate(x, world_width)
	wrapped_y := WorldWrapCoordinate(y, world_height)
	index := wrapped_x*world_height+wrapped_y
	if building_slot := w.tileBuilding[index]; building_slot >= 0 {
		return BuildingWalkable(w.buildings[building_slot].type)
	}
	return UnitValidTileType(unit_type, w.ground[wrapped_x][wrapped_y].type)
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
