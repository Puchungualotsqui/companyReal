package main

import rl "vendor:raylib"

main :: proc() {
	rl.InitWindow(1280, 800, "Compania Real")
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)

	app := AppInit()
	defer AppDeinit(&app)
	if CrazyWorldRequested() {
		app.crazyWorld = true
		app.config.kingdomCount = APP_MAX_KINGDOMS
		app.config.mapSizeIndex = len(APP_MAP_SIZES)-1
		app.config.spectator = false
		_ = AppStartGame(&app)
		app.crazyWorld = false
	}

	for !rl.WindowShouldClose() && !app.quitRequested {
		deltaTime := rl.GetFrameTime()
		AppUpdate(&app, deltaTime)

		rl.BeginDrawing()
		rl.ClearBackground(rl.Color{20, 22, 28, 255})
		AppDraw(&app)
		rl.EndDrawing()
	}
}
