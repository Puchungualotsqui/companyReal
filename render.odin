package main

import rl "vendor:raylib"

WINDOW_WIDTH : i32 : 720
WINDOW_HEIGHT : i32 : 496
TARGET_FPS : i32 : 60

CELL_SIZE : i32 : 28
BOARD_COLUMNS : i32 : 24
BOARD_ROWS : i32 : 16
BOARD_X : i32 : 24
BOARD_Y : i32 : 24
BOARD_WIDTH : i32 : CELL_SIZE * BOARD_COLUMNS
BOARD_HEIGHT : i32 : CELL_SIZE * BOARD_ROWS

COLOR_BACKGROUND :: rl.Color{0, 0, 0, 255}
COLOR_GRID :: rl.Color{48, 48, 48, 255}
COLOR_BORDER :: rl.Color{200, 200, 200, 255}
COLOR_TEAM_A :: rl.Color{255, 255, 255, 255}
COLOR_TEAM_B :: rl.Color{160, 160, 160, 255}
COLOR_NEUTRAL :: rl.Color{80, 80, 80, 255}
COLOR_PLAYER_CELL :: rl.Color{20, 20, 20, 255}
COLOR_SELECTION :: rl.Color{255, 255, 255, 255}
COLOR_BUILDING :: rl.Color{190, 190, 190, 255}

DrawBoard :: proc(world: ^World, camera: ViewCamera, selected: SquadId) {
	rl.DrawRectangleLines(BOARD_X, BOARD_Y, BOARD_WIDTH, BOARD_HEIGHT, COLOR_BORDER)
	for column: i32 = 0; column <= i32(world.max_size.x); column += 1 {
		world_pos := Vec2{f32(column), 0}
		screen_pos := ViewCameraWorldToScreen(camera, world_pos)
		x := i32(screen_pos.x)
		rl.DrawLine(x, BOARD_Y, x, BOARD_Y + BOARD_HEIGHT, COLOR_GRID)
	}
	for row: i32 = 0; row <= i32(world.max_size.y); row += 1 {
		world_pos := Vec2{0, f32(row)}
		screen_pos := ViewCameraWorldToScreen(camera, world_pos)
		y := i32(screen_pos.y)
		rl.DrawLine(BOARD_X, y, BOARD_X + BOARD_WIDTH, y, COLOR_GRID)
	}
	for sector in world.sectors {
		top_left := ViewCameraWorldToScreen(camera, Vec2{sector.bounds.x, sector.bounds.y})
		width := i32(sector.bounds.width * f32(CELL_SIZE) * camera.zoom)
		height := i32(sector.bounds.height * f32(CELL_SIZE) * camera.zoom)
		rl.DrawRectangleLines(i32(top_left.x), i32(top_left.y), width, height, UnitTeamColor(sector.team))
	}
	for strike in world.strikes {
		target := ViewCameraWorldToScreen(camera, strike.target)
		origin := ViewCameraWorldToScreen(camera, strike.origin)
		size := max(4, i32(5 * camera.zoom))
		color := UnitTeamColor(strike.team)
		rl.DrawLine(i32(origin.x), i32(origin.y), i32(target.x), i32(target.y), COLOR_GRID)
		rl.DrawLine(i32(target.x) - size, i32(target.y), i32(target.x) + size, i32(target.y), color)
		rl.DrawLine(i32(target.x), i32(target.y) - size, i32(target.x), i32(target.y) + size, color)
	}
	for shell in world.shells {
		position := ViewCameraWorldToScreen(camera, shell.pos)
		origin := ViewCameraWorldToScreen(camera, shell.origin)
		rl.DrawLine(i32(origin.x), i32(origin.y), i32(position.x), i32(position.y), UnitTeamColor(shell.team))
		rl.DrawRectangle(i32(position.x) - 2, i32(position.y) - 2, 4, 4, COLOR_SELECTION)
	}
	for convoy in world.convoys {
		position := ViewCameraWorldToScreen(camera, WorldConvoyPosition(world, convoy))
		size := max(4, i32(4 * camera.zoom))
		color := ResourceColor(convoy.resource)
		if convoy.state == .Blocked do color = COLOR_SELECTION
		visible_vehicles := min(convoy.vehicle_count, 4)
		for vehicle_index: int = 0; vehicle_index < visible_vehicles; vehicle_index += 1 {
			offset := i32(vehicle_index - visible_vehicles / 2) * max(2, size / 2)
			rl.DrawRectangle(i32(position.x) - size / 2 + offset, i32(position.y) - size / 2, size, size, color)
		}
	}
	for effect in world.effects {
		position := ViewCameraWorldToScreen(camera, effect.pos)
		size := max(4, i32(effect.size * camera.zoom))
		color := COLOR_NEUTRAL
		switch effect.type {
		case .Crater:
			color = COLOR_GRID
			rl.DrawRectangleLines(i32(position.x) - size, i32(position.y) - size, size * 2, size * 2, color)
		case .Fire:
			color = COLOR_BORDER
			rl.DrawRectangle(i32(position.x) - size / 2, i32(position.y) - size / 2, size, size, color)
		case .Smoke:
			color = COLOR_NEUTRAL
			rl.DrawRectangleLines(i32(position.x) - size, i32(position.y) - size, size * 2, size * 2, color)
		case .Debris:
			color = COLOR_TEAM_B
			rl.DrawLine(i32(position.x) - size, i32(position.y) - size, i32(position.x) + size, i32(position.y) + size, color)
			rl.DrawLine(i32(position.x) + size, i32(position.y) - size, i32(position.x) - size, i32(position.y) + size, color)
		case .Wreck:
			color = COLOR_TEAM_B
			rl.DrawTextCodepoint(rl.GetFontDefault(), 'x', rl.Vector2{position.x - f32(size) * 0.25, position.y - f32(size) * 0.5}, f32(max(8, size)), color)
		}
	}
	for body in world.bodies {
		position := ViewCameraWorldToScreen(camera, body.pos)
		rl.DrawTextCodepoint(rl.GetFontDefault(), 'x', rl.Vector2{position.x - 3, position.y - 6}, 12, COLOR_NEUTRAL)
	}
	for building in world.buildings {
		if building.destroyed do continue
		screen_pos := ViewCameraWorldToScreen(camera, building.pos)
		size := max(8, i32(14 * camera.zoom))
		color := COLOR_BUILDING
		if building.complete do color = UnitTeamColor(building.team)
		rl.DrawRectangleLines(i32(screen_pos.x) - size / 2, i32(screen_pos.y) - size / 2, size, size, color)
		rl.DrawTextCodepoint(rl.GetFontDefault(), BuildingDefaultChar(building.type), rl.Vector2{screen_pos.x - f32(size) * 0.25, screen_pos.y - f32(size) * 0.5}, f32(max(8, i32(14 * camera.zoom))), color)
	}

	cell_size := max(4, i32(f32(CELL_SIZE) * camera.zoom))
	font_size := max(8, i32(24 * camera.zoom))
	for unit in world.units {
		if !UnitIsAlive(unit) do continue
		screen_pos := ViewCameraWorldToScreen(camera, unit.pos)
		cell_x := i32(screen_pos.x - f32(cell_size) * 0.5)
		cell_y := i32(screen_pos.y - f32(cell_size) * 0.5)
		color := UnitTeamColor(unit.team)
		if unit.squad == selected {
			rl.DrawRectangleLines(cell_x - 2, cell_y - 2, cell_size + 4, cell_size + 4, COLOR_SELECTION)
		}
		if unit.squad == selected do rl.DrawRectangle(cell_x, cell_y, cell_size, cell_size, COLOR_PLAYER_CELL)
		rl.DrawTextCodepoint(rl.GetFontDefault(), UnitDefaultChar(unit.type), rl.Vector2{f32(cell_x) + f32(cell_size) * 0.25, f32(cell_y) - f32(font_size) * 0.1}, f32(font_size), color)
	}
}

ResourceColor :: proc(resource: ResourceType) -> rl.Color {
	switch resource {
	case .Materials:
		return rl.Color{180, 180, 180, 255}
	case .Fuel:
		return rl.Color{220, 150, 40, 255}
	case .Munitions:
		return rl.Color{220, 60, 60, 255}
	}
	unreachable()
}

UnitTeamColor :: proc(team: Team) -> rl.Color {
	switch team {
	case .Neutral:
		return COLOR_NEUTRAL
	case .A:
		return COLOR_TEAM_A
	case .B:
		return COLOR_TEAM_B
	}
	unreachable()
}
