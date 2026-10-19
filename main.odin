package main

import rl "vendor:raylib"

main :: proc() {
	settings := WorldGenerationSettingsDefault()
	world := new(World)
	if !WorldInit(world, 1024, 1024, 1, settings) do return
	defer WorldDeinit(world)

	rl.InitWindow(1280, 800, "Compania Real")
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)
	view := WorldViewInit(world)
	defer WorldRendererDeinit(&view.renderer)

	for !rl.WindowShouldClose() {
		WorldViewUpdate(world, &view, rl.GetFrameTime())
		rl.BeginDrawing()
		rl.ClearBackground(rl.Color{38, 68, 91, 255})
		WorldRender(world, view.renderer, view.camera)
		rl.EndDrawing()
	}
}
