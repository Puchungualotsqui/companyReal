package main

import rl "vendor:raylib"

main :: proc() {
	rl.InitWindow(WINDOW_WIDTH, WINDOW_HEIGHT, "COMPANIA REAL")
	defer rl.CloseWindow()
	rl.SetTargetFPS(TARGET_FPS)

	world: World
	WorldInit(&world)
	WorldSetupMatch(&world)
	defer WorldDeinit(&world)
	commands := CommandStateInit(LOCAL_PLAYER_ID)

	for !rl.WindowShouldClose() {
		dt := rl.GetFrameTime()
		if rl.IsKeyPressed(.N) {
			WorldResetMatch(&world)
			commands = CommandStateInit(LOCAL_PLAYER_ID)
		} else if world.match_state == .Running {
			CommandUpdate(&world, &commands, dt)
		}
		WorldUpdate(&world, dt)
		rl.BeginDrawing()
		rl.ClearBackground(COLOR_BACKGROUND)
		DrawBoard(&world, commands.camera, commands.selected)
		rl.EndDrawing()
	}
}

