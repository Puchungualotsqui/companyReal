package main

import rl "vendor:raylib"

CommandState :: struct {
	player: PlayerId,
	selected: SquadId,
	camera: ViewCamera,
}

CommandStateInit :: proc(player: PlayerId) -> CommandState {
	return CommandState{player, INVALID_SQUAD_ID, ViewCamera{Vec2{}, 1}}
}

CommandUpdate :: proc(w: ^World, state: ^CommandState, dt: f32) {
	CameraUpdate(w, &state.camera, dt)
	selected := SquadGet(w, state.selected)
	if selected == nil || !SquadIsAlive(w, state.selected) do state.selected = INVALID_SQUAD_ID

	if rl.IsMouseButtonPressed(.RIGHT) {
		state.selected = INVALID_SQUAD_ID
		return
	}
	if !rl.IsMouseButtonPressed(.LEFT) do return

	mouse := rl.GetMousePosition()
	screen := Vec2{mouse.x, mouse.y}
	if !ScreenInBoard(screen) do return
	world_pos := ViewCameraScreenToWorld(state.camera, screen)
	selection_radius := max(0.45, 0.75 / state.camera.zoom)
	clicked_unit := WorldUnitAtPosition(w, world_pos, selection_radius)
	clicked_squad := INVALID_SQUAD_ID
	if clicked_unit != INVALID_UNIT_ID {
		unit := UnitGet(w, clicked_unit)
		if unit != nil do clicked_squad = unit.squad
	}

	if clicked_squad != INVALID_SQUAD_ID {
		squad := SquadGet(w, clicked_squad)
		if squad != nil && SquadCanControl(squad^, state.player) {
			state.selected = clicked_squad
			return
		}
	}
	if state.selected == INVALID_SQUAD_ID do return
	if clicked_unit != INVALID_UNIT_ID && SquadSetAttackForPlayer(w, state.player, state.selected, clicked_unit) do return
	SquadSetMoveForPlayer(w, state.player, state.selected, world_pos)
}

CameraUpdate :: proc(w: ^World, camera: ^ViewCamera, dt: f32) {
	direction: Vec2
	if rl.IsKeyDown(.W) do direction.y -= 1
	if rl.IsKeyDown(.A) do direction.x -= 1
	if rl.IsKeyDown(.S) do direction.y += 1
	if rl.IsKeyDown(.D) do direction.x += 1
	if Vec2Length(direction) > 0 {
		speed := 20 / camera.zoom
		camera.position = Vec2Add(camera.position, Vec2Scale(Vec2Normalize(direction), speed * dt))
	}

	wheel := rl.GetMouseWheelMove()
	if wheel != 0 {
		mouse := rl.GetMousePosition()
		screen := Vec2{mouse.x, mouse.y}
		before := ViewCameraScreenToWorld(camera^, screen)
		camera.zoom = clamp(camera.zoom + wheel * 0.15, 0.5, 3.0)
		cell_size := f32(CELL_SIZE) * camera.zoom
		camera.position = Vec2{before.x - (screen.x - f32(BOARD_X)) / cell_size, before.y - (screen.y - f32(BOARD_Y)) / cell_size}
	}
	ViewCameraClamp(camera, w.max_size)
}

ScreenInBoard :: proc(screen: Vec2) -> bool {
	return screen.x >= f32(BOARD_X) && screen.x < f32(BOARD_X + BOARD_WIDTH) && screen.y >= f32(BOARD_Y) && screen.y < f32(BOARD_Y + BOARD_HEIGHT)
}

WorldUnitAtPosition :: proc(w: ^World, position: Vec2, radius: f32) -> UnitId {
	found := INVALID_UNIT_ID
	closest := radius
	for unit in w.units {
		if !UnitIsAlive(unit) do continue
		distance := Vec2Length(Vec2Sub(unit.pos, position))
		if distance <= closest {
			found = unit.id
			closest = distance
		}
	}
	return found
}
