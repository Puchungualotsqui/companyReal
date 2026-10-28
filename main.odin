package main

import rl "vendor:raylib"
import "core:os"

CommandLineFlagPresent :: proc(flag: string) -> bool {
	if len(os.args) <= 1 do return false
	for arg in os.args[1:] {
		if arg == flag do return true
	}
	return false
}

main :: proc() {
	rl.InitWindow(1280, 800, "Compania Real")
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)

	app := AppInit()
	defer AppDeinit(&app)
	crazyWorld := CommandLineFlagPresent(CRAZY_WORLD_FLAG)
	if crazyWorld {
		app.crazyWorld = true
		app.config.seed = CRAZY_WORLD_SEED
		app.config.kingdomCount = APP_MAX_KINGDOMS
		app.config.mapSizeIndex = len(APP_MAP_SIZES)-1
		app.config.spectator = false
		_ = AppStartGame(&app)
		app.crazyWorld = false
	}
	ProfilerInit()
	defer ProfilerDeinit()

	for !rl.WindowShouldClose() && !app.quitRequested {
		updateStamp := ProfilerBegin("Update")
		deltaTime := rl.GetFrameTime()
		AppUpdate(&app, deltaTime)
		ProfilerEnd(updateStamp)

		drawStamp := ProfilerBegin("Draw")
		rl.BeginDrawing()
		rl.ClearBackground(rl.Color{20, 22, 28, 255})
		AppDraw(&app)
		ProfilerEnd(drawStamp)

		presentStamp := ProfilerBegin("Present")
		rl.EndDrawing()
		ProfilerEnd(presentStamp)
		ProfilerFrameEnd(app.world)
	}
}
