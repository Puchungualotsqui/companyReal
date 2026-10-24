package main

import rl "vendor:raylib"

main :: proc() {
	rl.InitWindow(1280, 800, "Compania Real")
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)

	app := AppInit()
	defer AppDeinit(&app)

	for !rl.WindowShouldClose() && !app.quitRequested {
		delta_time := rl.GetFrameTime()
		AppUpdate(&app, delta_time)

		rl.BeginDrawing()
		rl.ClearBackground(rl.Color{20, 22, 28, 255})
		AppDraw(&app)
		rl.EndDrawing()
	}
}
