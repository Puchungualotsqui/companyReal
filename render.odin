package main

import rl "vendor:raylib"
import "core:math"
import "core:slice"

RenderItem :: struct {
	base_y:  f32,
	dest:    rl.Rectangle,
	texture: rl.Texture2D,
	flip_x:  bool,
}

RenderQuad :: struct {
	dest:  rl.Rectangle,
	alpha: u8,
}

RenderItemLess :: proc(a, b: RenderItem) -> bool {
	return a.base_y < b.base_y
}

WorldRenderer :: struct {
	terrain: TerrainRenderer,
	sprites: SpriteSet,
	items:   [dynamic]RenderItem,
	shadows: [dynamic]RenderQuad,
	lights:  [dynamic]RenderQuad,
}

WorldView :: struct {
	renderer: WorldRenderer,
	camera: rl.Camera2D,
}

WorldViewInit :: proc(w: ^World) -> WorldView {
	screen_width := f32(rl.GetScreenWidth())
	screen_height := f32(rl.GetScreenHeight())
	minimum_zoom := WorldCameraMinimumZoom(w, screen_width, screen_height)
	zoom := WorldCameraDefaultZoom
	if zoom < minimum_zoom do zoom = minimum_zoom
	focus_x, focus_y := WorldCameraFocus(w)

	return WorldView{
		renderer = WorldRenderer{
			terrain = TerrainRendererInit(w),
			sprites = SpriteSetInit(),
			items = make([dynamic]RenderItem, 0, 2048),
			shadows = make([dynamic]RenderQuad, 0, 512),
			lights = make([dynamic]RenderQuad, 0, 256),
		},
		camera = rl.Camera2D{
			offset = rl.Vector2{screen_width*0.5, screen_height*0.5},
			target = rl.Vector2{focus_x, focus_y},
			rotation = 0,
			zoom = zoom,
		},
	}
}

// Sprites are authored at PIXELS_PER_TILE, so this zoom shows them 1:1.
WorldCameraDefaultZoom : f32 : 16
WorldCameraMaxZoom : f32 : 64

WorldCameraFocus :: proc(w: ^World) -> (f32, f32) {
	if w.kingdomUsed[0] && w.kingdoms[0].capitalSlot >= 0 {
		town_slot := w.kingdoms[0].capitalSlot
		if town_slot < TOWN_CAPACITY && w.kingdoms[0].townUsed[town_slot] {
			town := w.kingdoms[0].towns[town_slot]
			width, height := BuildingTileSize(TownHall{})
			return f32(town.x)+f32(width)*0.5, f32(town.y)+f32(height)*0.5
		}
	}
	return f32(w.maxX)*0.5, f32(w.maxY)*0.5
}

WorldViewUpdate :: proc(w: ^World, view: ^WorldView, delta_time: f32) {
	WorldRendererUpdate(w, &view.renderer)
	WorldCameraUpdate(w, &view.camera, delta_time)
}


WorldRendererUpdate :: proc(w: ^World, renderer: ^WorldRenderer) {
	TerrainRendererUpdate(w, &renderer.terrain)
}

WorldRendererDeinit :: proc(renderer: ^WorldRenderer) {
	TerrainRendererDeinit(&renderer.terrain)
	SpriteSetDeinit(&renderer.sprites)
	delete(renderer.items)
	delete(renderer.shadows)
	delete(renderer.lights)
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
		if camera.zoom > WorldCameraMaxZoom do camera.zoom = WorldCameraMaxZoom

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


WorldRender :: proc(w: ^World, renderer: ^WorldRenderer, camera: rl.Camera2D) {
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

	rl.BeginMode2D(camera)
	if camera.zoom >= TERRAIN_CHUNK_MIN_ZOOM {
		TerrainRenderChunks(
			w,
			&renderer.terrain,
			camera,
			first_copy_x,
			last_copy_x,
			first_copy_y,
			last_copy_y,
		)
	} else {
		TerrainRenderLow(
			&renderer.terrain,
			f32(world_width),
			f32(world_height),
			first_copy_x,
			last_copy_x,
			first_copy_y,
			last_copy_y,
		)
	}
	WorldRenderSprites(
		w,
		renderer,
		camera,
		first_copy_x,
		last_copy_x,
		first_copy_y,
		last_copy_y,
	)
	rl.EndMode2D()

	ambient := WorldAmbientColor(w)
	if ambient[0] < 255 || ambient[1] < 255 || ambient[2] < 255 {
		rl.BeginBlendMode(.MULTIPLIED)
		rl.DrawRectangle(0, 0, rl.GetScreenWidth(), rl.GetScreenHeight(), ambient)
		rl.EndBlendMode()
	}

	night := WorldNightAmount(w)
	if night > 0.02 && renderer.sprites.glow.id != 0 && len(renderer.lights) > 0 {
		glow_source := rl.Rectangle{0, 0, f32(renderer.sprites.glow.width), f32(renderer.sprites.glow.height)}
		rl.BeginMode2D(camera)
		rl.BeginBlendMode(.ADDITIVE)
		for light in renderer.lights {
			rl.DrawTexturePro(
				renderer.sprites.glow,
				glow_source,
				light.dest,
				rl.Vector2{0, 0},
				0,
				rl.Color{255, 255, 255, light.alpha},
			)
		}
		rl.EndBlendMode()
		rl.EndMode2D()
	}
}

// Multiplied over the frame: white at noon, warm at dawn/dusk, deep blue at night.
WorldAmbientColor :: proc(w: ^World) -> rl.Color {
	hour := WorldTimeOfDay(w)
	Key :: struct{ hour: f32, color: rl.Color }
	keys := [9]Key{
		{0, rl.Color{112, 126, 182, 255}},
		{4.5, rl.Color{112, 126, 182, 255}},
		{6.5, rl.Color{255, 208, 190, 255}},
		{8, rl.Color{255, 246, 236, 255}},
		{12, rl.Color{255, 255, 255, 255}},
		{17, rl.Color{255, 246, 236, 255}},
		{19, rl.Color{255, 200, 164, 255}},
		{21.5, rl.Color{142, 142, 192, 255}},
		{24, rl.Color{112, 126, 182, 255}},
	}
	for i in 0 ..< len(keys)-1 {
		if hour >= keys[i].hour && hour <= keys[i+1].hour {
			t := (hour-keys[i].hour)/(keys[i+1].hour-keys[i].hour)
			return WorldLerpColor(keys[i].color, keys[i+1].color, t)
		}
	}
	return keys[0].color
}

WorldLerpColor :: proc(a, b: rl.Color, t: f32) -> rl.Color {
	return rl.Color{
		u8(clamp(f32(a[0])+(f32(b[0])-f32(a[0]))*t, 0, 255)),
		u8(clamp(f32(a[1])+(f32(b[1])-f32(a[1]))*t, 0, 255)),
		u8(clamp(f32(a[2])+(f32(b[2])-f32(a[2]))*t, 0, 255)),
		u8(clamp(f32(a[3])+(f32(b[3])-f32(a[3]))*t, 0, 255)),
	}
}

WorldRenderSprites :: proc(
	w: ^World,
	renderer: ^WorldRenderer,
	camera: rl.Camera2D,
	first_copy_x, last_copy_x, first_copy_y, last_copy_y: int,
) {
	world_width := f32(w.maxX)
	world_height := f32(w.maxY)
	screen_width := f32(rl.GetScreenWidth())
	screen_height := f32(rl.GetScreenHeight())
	half_view_width := screen_width / (2*camera.zoom)
	half_view_height := screen_height / (2*camera.zoom)
	view_min_x := camera.target.x-half_view_width
	view_max_x := camera.target.x+half_view_width
	view_min_y := camera.target.y-half_view_height
	view_max_y := camera.target.y+half_view_height
	interpolation := clamp(w.simulationAccumulator/TOWN_SIMULATION_STEP, 0, 1)
	bob_time := w.simulationTime+w.simulationAccumulator
	shadow_source := rl.Rectangle{0, 0, f32(renderer.sprites.shadow.width), f32(renderer.sprites.shadow.height)}
	night := WorldNightAmount(w)
	clear(&renderer.lights)

	for copy_x in first_copy_x ..< last_copy_x+1 {
		offset_x := f32(copy_x)*world_width
		for copy_y in first_copy_y ..< last_copy_y+1 {
			offset_y := f32(copy_y)*world_height
			min_x := view_min_x-offset_x
			max_x := view_max_x-offset_x
			min_y := view_min_y-offset_y
			max_y := view_max_y-offset_y

			clear(&renderer.items)
			clear(&renderer.shadows)

			for building_slot in 0 ..< BUILDING_CAPACITY {
				if !w.buildingUsed[building_slot] do continue
				building_width, building_height := BuildingTileSize(w.buildings[building_slot].type)
				building_x := f32(w.buildings.x[building_slot])
				building_y := f32(w.buildings.y[building_slot])
				width := f32(building_width)
				height := f32(building_height)
				kind := BuildingKindOf(w.buildings[building_slot].type)
				if building_x+width < min_x || building_x > max_x ||
					building_y+height < min_y || building_y > max_y {
					continue
				}

				faction := FactionSpriteIndex(w.buildings[building_slot].kingdom)
				base_y := building_y+height
				if BuildingWalkable(w.buildings[building_slot].type) {
					base_y = -1e9
				} else {
					shadow_height := clamp(height*0.8, 0.6, 4)
					append(&renderer.shadows, RenderQuad{
						dest = rl.Rectangle{
							x = offset_x+building_x-0.7,
							y = offset_y+building_y+height-shadow_height*0.2,
							width = width+1.4,
							height = shadow_height,
						},
						alpha = 220,
					})
				}
				if night > 0.02 && BuildingHasNightLight(kind) {
					light_width := width*0.95
					light_height := height*0.7
					flicker := 78+10*math.sin(w.simulationTime*2.4+f32(building_slot)*1.7)
					append(&renderer.lights, RenderQuad{
						dest = rl.Rectangle{
							x = offset_x+building_x+(width-light_width)*0.5,
							y = offset_y+building_y+height*0.45-light_height*0.5,
							width = light_width,
							height = light_height,
						},
						alpha = u8(night*flicker),
					})
				}
				append(&renderer.items, RenderItem{
					base_y = base_y,
					dest = rl.Rectangle{offset_x+building_x, offset_y+building_y, width, height},
					texture = renderer.sprites.building[faction][kind],
				})
			}

			for unit_slot in 0 ..< UNIT_CAPACITY {
				if !w.unitUsed[unit_slot] do continue
				if w.units[unit_slot].type == nil do continue
				if state, ok := w.units[unit_slot].state.(StateConverting); ok && state.inside {
					continue
				}

				kind := UnitKindOf(w.units[unit_slot].type)
				scale := UnitSpriteScale(kind)
				unit_x := w.units[unit_slot].x
				unit_y := w.units[unit_slot].y
				if interpolation > 0 {
					unit_x = WorldWrapPosition(
						w.units[unit_slot].previousX+
						WorldShortestWrappedDelta(
							w.units[unit_slot].x-w.units[unit_slot].previousX,
							world_width,
						)*
							interpolation,
						world_width,
					)
					unit_y = WorldWrapPosition(
						w.units[unit_slot].previousY+
						WorldShortestWrappedDelta(
							w.units[unit_slot].y-w.units[unit_slot].previousY,
							world_height,
						)*
							interpolation,
						world_height,
					)
				}
				if unit_x+scale+1 < min_x || unit_x-1 > max_x ||
					unit_y+1 < min_y || unit_y-scale-1 > max_y {
					continue
				}

				bob: f32 = 0
				switch state in w.units[unit_slot].state {
				case StatePacific:
					if state != .Sleeping {
						bob = math.sin(f32(unit_slot)*1.7+bob_time*2.4)*0.03
					}
				case StateWarrior, StateConverting:
					bob = math.sin(f32(unit_slot)*1.7+bob_time*2.4)*0.03
				}

				faction := FactionSpriteIndex(w.units[unit_slot].kingdome)
				flip_x := false
				if w.units[unit_slot].pathReady {
					delta_x := WorldShortestWrappedDelta(
						f32(w.units[unit_slot].pathTargetX)+0.5-unit_x,
						f32(w.maxX),
					)
					flip_x = delta_x < -0.5
				}
				append(&renderer.items, RenderItem{
					base_y = unit_y+0.5,
					dest = rl.Rectangle{
						x = offset_x+unit_x-scale*0.5,
						y = offset_y+unit_y+0.5-scale+bob,
						width = scale,
						height = scale,
					},
					texture = renderer.sprites.unit[faction][kind],
					flip_x = flip_x,
				})
			}

			slice.sort_by(renderer.items[:], RenderItemLess)
			if renderer.sprites.shadow.id != 0 {
				for shadow in renderer.shadows {
					rl.DrawTexturePro(
						renderer.sprites.shadow,
						shadow_source,
						shadow.dest,
						rl.Vector2{0, 0},
						0,
						rl.Color{255, 255, 255, shadow.alpha},
					)
				}
			}
			for item in renderer.items {
				if item.texture.id == 0 do continue
				source := rl.Rectangle{0, 0, f32(item.texture.width), f32(item.texture.height)}
				if item.flip_x do source.width = -source.width
				rl.DrawTexturePro(item.texture, source, item.dest, rl.Vector2{0, 0}, 0, rl.WHITE)
			}
		}
	}
}

WorldFloor :: proc(value: f32) -> int {
	result := int(value)
	if f32(result) > value do result -= 1
	return result
}
