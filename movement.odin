package main

AStar :: proc(w: ^World, unit_type: UnitType, start_x, start_y, goal_x, goal_y: int, path: ^[dynamic]int) -> bool {
	clear(path)
	world_width := int(w.maxX)
	world_height := int(w.maxY)
	if world_width <= 0 || world_height <= 0 do return false

	wrapped_start_x := WorldWrapCoordinate(start_x, world_width)
	wrapped_start_y := WorldWrapCoordinate(start_y, world_height)
	wrapped_goal_x := WorldWrapCoordinate(goal_x, world_width)
	wrapped_goal_y := WorldWrapCoordinate(goal_y, world_height)

	if !WorldTileWalkable(w, wrapped_goal_x, wrapped_goal_y, unit_type) do return false

	node_count := world_width * world_height
	start_index := wrapped_start_x*world_height + wrapped_start_y
	goal_index := wrapped_goal_x*world_height + wrapped_goal_y
	infinity := node_count + 1

	came_from := make([dynamic]int, node_count)
	g_score := make([dynamic]int, node_count)
	is_open := make([dynamic]bool, node_count)
	is_closed := make([dynamic]bool, node_count)

	defer delete(came_from)
	defer delete(g_score)
	defer delete(is_open)
	defer delete(is_closed)

	for i in 0..<node_count {
		came_from[i] = -1
		g_score[i] = infinity
		is_open[i] = false
		is_closed[i] = false
	}

	open_set := make([dynamic]int)
	defer delete(open_set)

	g_score[start_index] = 0
	is_open[start_index] = true
	append(&open_set, start_index)

	found := false
	for len(open_set) > 0 {
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
		for position in 1..<len(open_set) {
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

		open_set[best_position] = open_set[len(open_set)-1]
		_ = pop(&open_set)
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
			if is_closed[next_index] do continue
			tentative_score := g_score[best_index] + 1
			if tentative_score >= g_score[next_index] do continue

			came_from[next_index] = best_index
			g_score[next_index] = tentative_score
			if !is_open[next_index] {
				is_open[next_index] = true
				append(&open_set, next_index)
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

WorldTileWalkable :: proc(w: ^World, x, y: int, unit_type: UnitType) -> bool {
	if !UnitValidTileType(unit_type, w.ground[x][y].type) do return false
	return !WorldTileOccupied(w, x, y)
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
