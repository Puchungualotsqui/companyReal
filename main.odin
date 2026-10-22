package main

import rl "vendor:raylib"

main :: proc() {
	settings := WorldGenerationSettingsDefault()
	world := new(World)
	// Kingdom 0 is the player; the rest are neighbouring realms.
	if !WorldInit(world, 1024, 1024, 4, settings) do return
	defer WorldDeinit(world)

	rl.InitWindow(1280, 800, "Compania Real")
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)
	view := WorldViewInit(world)
	defer WorldRendererDeinit(&view.renderer)
	defer WorldUIDeinit()

	for !rl.WindowShouldClose() {
		delta_time := rl.GetFrameTime()
		WorldUpdate(world, delta_time)
		WorldViewUpdate(world, &view, delta_time)
		rl.BeginDrawing()
		rl.ClearBackground(rl.Color{38, 68, 91, 255})
		WorldRender(world, &view.renderer, view.camera)
		WorldUIDraw(world, &view.renderer, view.camera, &view.ui)
		rl.EndDrawing()
	}
}
