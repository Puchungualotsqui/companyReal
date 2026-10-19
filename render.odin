package main

import rl "vendor:raylib"

WorldRenderer :: struct {
	terrainTexture: rl.Texture2D,
	terrainRevision: u64,
}

WorldView :: struct {
	renderer: WorldRenderer,
	camera: rl.Camera2D,
}

WorldViewInit :: proc(w: ^World) -> WorldView {
	screen_width := f32(rl.GetScreenWidth())
	screen_height := f32(rl.GetScreenHeight())
	world_width := f32(w.maxX)
	world_height := f32(w.maxY)
	zoom := WorldCameraMinimumZoom(w, screen_width, screen_height)
	if zoom <= 0 do zoom = 1

	return WorldView{
		renderer = WorldRenderer{
			terrainTexture = WorldCreateTerrainTexture(w),
			terrainRevision = w.terrainRevision,
		},
		camera = rl.Camera2D{
			offset = rl.Vector2{screen_width*0.5, screen_height*0.5},
			target = rl.Vector2{world_width*0.5, world_height*0.5},
			rotation = 0,
			zoom = zoom,
		},
	}
}

WorldViewUpdate :: proc(w: ^World, view: ^WorldView, delta_time: f32) {
	WorldRendererUpdate(w, &view.renderer)
	WorldCameraUpdate(w, &view.camera, delta_time)
}


WorldRendererUpdate :: proc(w: ^World, renderer: ^WorldRenderer) {
	if renderer.terrainRevision == w.terrainRevision do return

	rl.UnloadTexture(renderer.terrainTexture)
	renderer.terrainTexture = WorldCreateTerrainTexture(w)
	renderer.terrainRevision = w.terrainRevision
}

WorldRendererDeinit :: proc(renderer: ^WorldRenderer) {
	rl.UnloadTexture(renderer.terrainTexture)
}

WorldCreateTerrainTexture :: proc(w: ^World) -> rl.Texture2D {
	world_width := int(w.maxX)
	world_height := int(w.maxY)
	image := rl.GenImageColor(i32(world_width), i32(world_height), rl.BLACK)
	defer rl.UnloadImage(image)

	for x in 0..<world_width {
		for y in 0..<world_height {
			rl.ImageDrawPixel(&image, i32(x), i32(y), WorldTileColor(w.ground[x][y].type))
		}
	}

	texture := rl.LoadTextureFromImage(image)
	rl.SetTextureFilter(texture, .POINT)
	return texture
}


WorldCameraUpdate :: proc(w: ^World, camera: ^rl.Camera2D, delta_time: f32) {
	screen_width := f32(rl.GetScreenWidth())
	screen_height := f32(rl.GetScreenHeight())
	camera.offset = rl.Vector2{screen_width*0.5, screen_height*0.5}

	pan_x: f32 = 0
	pan_y: f32 = 0
	if rl.IsKeyDown(.A) do pan_x -= 1
	if rl.IsKeyDown(.D) do pan_x += 1
	if rl.IsKeyDown(.W) do pan_y -= 1
	if rl.IsKeyDown(.S) do pan_y += 1
	pan_distance := 220 * delta_time / camera.zoom
	camera.target.x += pan_x * pan_distance
	camera.target.y += pan_y * pan_distance

	if rl.IsMouseButtonDown(.RIGHT) {
		mouse_delta := rl.GetMouseDelta()
		camera.target.x -= mouse_delta.x / camera.zoom
		camera.target.y -= mouse_delta.y / camera.zoom
	}

	wheel := rl.GetMouseWheelMove()
	if wheel != 0 {
		mouse_screen := rl.GetMousePosition()
		mouse_world_before := rl.Vector2{
			(mouse_screen.x-camera.offset.x)/camera.zoom + camera.target.x,
			(mouse_screen.y-camera.offset.y)/camera.zoom + camera.target.y,
		}

		if wheel > 0 {
			camera.zoom *= 1 + 0.1*wheel
		} else {
			camera.zoom /= 1 - 0.1*wheel
		}

		minimum_zoom := WorldCameraMinimumZoom(w, screen_width, screen_height)
		if camera.zoom < minimum_zoom do camera.zoom = minimum_zoom
		if camera.zoom > 32 do camera.zoom = 32

		mouse_world_after := rl.Vector2{
			(mouse_screen.x-camera.offset.x)/camera.zoom + camera.target.x,
			(mouse_screen.y-camera.offset.y)/camera.zoom + camera.target.y,
		}
		camera.target.x += mouse_world_before.x - mouse_world_after.x
		camera.target.y += mouse_world_before.y - mouse_world_after.y

	}
}

WorldCameraMinimumZoom :: proc(w: ^World, screen_width, screen_height: f32) -> f32 {
	world_width := f32(w.maxX)
	world_height := f32(w.maxY)
	return max(screen_width/world_width, screen_height/world_height)
}


WorldRender :: proc(w: ^World, renderer: WorldRenderer, camera: rl.Camera2D) {
	world_width := int(w.maxX)
	world_height := int(w.maxY)
	if world_width <= 0 || world_height <= 0 do return

	screen_width := f32(rl.GetScreenWidth())
	screen_height := f32(rl.GetScreenHeight())
	half_view_width := screen_width / (2*camera.zoom)
	half_view_height := screen_height / (2*camera.zoom)
	first_copy_x := WorldFloor((camera.target.x-half_view_width)/f32(world_width))
	last_copy_x := WorldFloor((camera.target.x+half_view_width)/f32(world_width))
	first_copy_y := WorldFloor((camera.target.y-half_view_height)/f32(world_height))
	last_copy_y := WorldFloor((camera.target.y+half_view_height)/f32(world_height))
	source := rl.Rectangle{0, 0, f32(world_width), f32(world_height)}

	rl.BeginMode2D(camera)
	for copy_x in first_copy_x ..< last_copy_x+1 {
		for copy_y in first_copy_y ..< last_copy_y+1 {
			destination := rl.Rectangle{
				x = f32(copy_x*world_width),
				y = f32(copy_y*world_height),
				width = f32(world_width),
				height = f32(world_height),
			}
			rl.DrawTexturePro(renderer.terrainTexture, source, destination, rl.Vector2{0, 0}, 0, rl.WHITE)
		}
	}
	rl.EndMode2D()
}

WorldFloor :: proc(value: f32) -> int {
	result := int(value)
	if f32(result) > value do result -= 1
	return result
}

WorldTileColor :: proc(tile_type: TileType) -> rl.Color {
	switch tile_type {
	case .Water:
		return rl.Color{48, 83, 112, 255}
	case .River:
		return rl.Color{78, 133, 155, 255}
	case .Ground:
		return rl.Color{100, 128, 88, 255}
	case .Sand:
		return rl.Color{215, 194, 140, 255}
	case .Forest:
		return rl.Color{52, 100, 66, 255}
	case .Hill:
		return rl.Color{126, 131, 110, 255}
	case .Desert:
		return rl.Color{191, 154, 95, 255}
	}
	unreachable()
}
