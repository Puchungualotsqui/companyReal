package main

Building :: struct {
	x, y: int,
	health: f32,
	type: BuildingType,
	town: Town,
}

BuildingType :: union {
	Wall,
	TownHall,
}

Wall :: struct {}

TownHall :: struct {}

// width, height
BuildingTileSize :: proc(type: BuildingType) -> (int, int) {
	switch t in type {
	case Wall:
		return 1, 1
	case TownHall:
		return 4, 4
	}
	unreachable()
}

BuildingDefaultHealth :: proc(type: BuildingType) -> f32 {
	switch t in type {
	case Wall:
		return 300
	case TownHall:
		return 1000
	}
	unreachable()
}

BuildingValidTileType :: proc(bType: BuildingType, tType: TileType) -> bool {
	switch tType {
	case .Water:
		switch _ in bType {
		case Wall, TownHall:
			return false
		}

	case .Ground:
		switch _ in bType {
		case Wall, TownHall:
			return true
		}

	case .Sand:
		switch _ in bType {
		case Wall, TownHall:
			return true
		}
	}
	unreachable()
}

Unit :: struct {
	x, y: f32,
	health: f32,
	speed: f32,
	cooldown: f32,
	damage: f32,
	type: UnitType,
	town: Town,
	path: [dynamic]int,
}

UnitType :: union {
	Knight,
	Giant,
}

Knight :: struct {}

Giant :: struct {}

UnitDefaultHealth :: proc(type: UnitType) -> f32 {
	switch t in type {
	case Knight:
		return 50
	case Giant:
		return 100
	}
	unreachable()
}

UnitDefaultSpeed :: proc(type: UnitType) -> f32 {
	switch t in type {
	case Knight:
		return 10
	case Giant:
		return 7.5
	}
	unreachable()
}

UnitDefaultCooldown :: proc(type: UnitType) -> f32 {
	switch t in type {
	case Knight:
		return 1
	case Giant:
		return 1.75
	}
	unreachable()
}

UnitDefaultRange :: proc(type: UnitType) -> f32 {
	switch t in type {
	case Knight:
		return 0.75
	case Giant:
		return 0.80
	}
	unreachable()
}

UnitDefaultVision :: proc(type: UnitType) -> f32 {
	switch t in type {
	case Knight:
		return 25
	case Giant:
		return 40
	}
	unreachable()
}

UnitDefaultDamage :: proc(type: UnitType) -> f32 {
	switch t in type {
	case Knight:
		return 15
	case Giant:
		return 30
	}
	unreachable()
}

UnitValidTileType :: proc(uType: UnitType, tType: TileType) -> bool {
	switch tType {
	case .Water:
		switch _ in uType {
		case Knight, Giant:
			return false
		}

	case .Ground:
		switch _ in uType {
		case Knight, Giant:
			return true
		}

	case .Sand:
		switch _ in uType {
		case Knight, Giant:
			return true
		}
	}

	unreachable()
}

UnitMove :: proc(w: ^World, unit_slot, goal_x, goal_y: int, delta_time: f32) -> bool {
	unit_index, exists := UnitGet(w, unit_slot)
	if !exists || delta_time < 0 do return false

	world_width := int(w.maxX)
	world_height := int(w.maxY)
	if world_width <= 0 || world_height <= 0 do return false

	unit_type := w.units.type[unit_index]
	unit_x := WorldWrapPosition(w.units.x[unit_index], f32(world_width))
	unit_y := WorldWrapPosition(w.units.y[unit_index], f32(world_height))
	start_x := WorldWrapCoordinate(int(unit_x), world_width)
	start_y := WorldWrapCoordinate(int(unit_y), world_height)
	target_x := WorldWrapCoordinate(goal_x, world_width)
	target_y := WorldWrapCoordinate(goal_y, world_height)

	path := &w.units[unit_slot].path
	found := AStar(w, unit_type, start_x, start_y, target_x, target_y, path)
	if !found do return false

	remaining := w.units.speed[unit_index] * delta_time
	first_waypoint := 1

	if len(path) == 1 do first_waypoint = 0
	for waypoint_index in first_waypoint..<len(path) {
		waypoint := path[waypoint_index]
		destination_x := f32(waypoint/world_height) + 0.5
		destination_y := f32(waypoint%world_height) + 0.5
		delta_x := WorldShortestWrappedDelta(destination_x-unit_x, f32(world_width))
		delta_y := WorldShortestWrappedDelta(destination_y-unit_y, f32(world_height))

		if delta_x != 0 {
			distance_x := delta_x
			if distance_x < 0 do distance_x = -distance_x
			if remaining >= distance_x {
				unit_x = WorldWrapPosition(unit_x+delta_x, f32(world_width))
				remaining -= distance_x
			} else if remaining > 0 {
				step := remaining
				if delta_x < 0 do step = -step
				unit_x = WorldWrapPosition(unit_x+step, f32(world_width))
				remaining = 0
			}
		}
		if remaining <= 0 && delta_y == 0 { break }

		if delta_y != 0 {
			distance_y := delta_y
			if distance_y < 0 do distance_y = -distance_y
			if remaining >= distance_y {
				unit_y = WorldWrapPosition(unit_y+delta_y, f32(world_height))
				remaining -= distance_y
			} else if remaining > 0 {
				step := remaining
				if delta_y < 0 do step = -step
				unit_y = WorldWrapPosition(unit_y+step, f32(world_height))
				remaining = 0
			}
		}
		if remaining <= 0 { break }
	}

	w.units.x[unit_index] = unit_x
	w.units.y[unit_index] = unit_y

	target_position_x := f32(target_x) + 0.5
	target_position_y := f32(target_y) + 0.5
	return WorldShortestWrappedDelta(target_position_x-unit_x, f32(world_width)) == 0 &&
		WorldShortestWrappedDelta(target_position_y-unit_y, f32(world_height)) == 0
}
