package main

import rl "vendor:raylib"
import "core:math"
import "core:slice"
import "d32"

RenderItem :: struct {
	baseY:  f32,
	dest:    rl.Rectangle,
	texture: rl.Texture2D,
	flipX:  bool,
	tint:    rl.Color,
}

RenderQuad :: struct {
	dest:  rl.Rectangle,
	alpha: u8,
}

RenderItemLess :: proc(a, b: RenderItem) -> bool {
	return a.baseY < b.baseY
}

WorldRenderer :: struct {
	terrain: TerrainRenderer,
	sprites: SpriteSet,
	items:   [dynamic]RenderItem,
	shadows: [dynamic]RenderQuad,
	lights:  [dynamic]RenderQuad,
	memoryFires: [dynamic]RenderQuad,
	fogTexture: rl.Texture2D,
	fogPixels:  []u8, // Scratch buffer for one fog chunk upload
	bloodTexture: rl.Texture2D,
	bloodPixels: [dynamic]u8,
}

MilestoneCamera :: struct {
	active:        bool,
	panning:       bool,
	elapsed:       f32,
	duration:      f32,
	start:         rl.Vector2,
	target:        rl.Vector2,
	returnTarget: rl.Vector2,
	returnZoom:   f32,
	kingdom, town: int,
}

// Fast, non-blocking camera pan started from a unit icon in the town panel.
FocusCamera :: struct {
	active:    bool,
	elapsed:   f32,
	duration:  f32,
	start:     rl.Vector2,
	target:    rl.Vector2,
	kind:      UnitKind,
	unitSlot:  int,
	hasUnit:   bool,
	kingdom:   int,
	town:      int,
}

WorldView :: struct {
	renderer:         WorldRenderer,
	camera:           rl.Camera2D,
	ui:               UIState,
	milestoneCamera: MilestoneCamera,
	focusCamera:     FocusCamera,
}

WorldViewInit :: proc(w: ^World) -> WorldView {
	screenWidth := f32(rl.GetScreenWidth())
	screenHeight := f32(rl.GetScreenHeight())
	minimumZoom := WorldCameraMinimumZoom(w, screenWidth, screenHeight)
	zoom := WorldCameraDefaultZoom
	if zoom < minimumZoom do zoom = minimumZoom
	focusX, focusY := WorldCameraFocus(w)

	view := WorldView{
		renderer = WorldRenderer{
			terrain = TerrainRendererInit(w),
			sprites = SpriteSetInit(w),
			items = make([dynamic]RenderItem, 0, 2048),
			shadows = make([dynamic]RenderQuad, 0, 512),
			lights = make([dynamic]RenderQuad, 0, 256),
			memoryFires = make([dynamic]RenderQuad, 0, 64),
		},
		camera = rl.Camera2D{
			offset = rl.Vector2{screenWidth*0.5, screenHeight*0.5},
			target = rl.Vector2{focusX, focusY},
			rotation = 0,
			zoom = zoom,
		},
	}
	FogRenderInit(w, &view.renderer)
	BloodRenderInit(w, &view.renderer)
	return view
}

// Sprites are authored at PIXELS_PER_TILE, so this zoom shows them 1:1.
WorldCameraDefaultZoom : f32 : 16
WorldCameraMaxZoom : f32 : 64

WorldCameraFocus :: proc(w: ^World) -> (f32, f32) {
	if w.kingdomUsed[0] && w.kingdoms[0].capitalSlot >= 0 {
		townSlot := w.kingdoms[0].capitalSlot
		if townSlot < TOWN_CAPACITY && w.kingdoms[0].townUsed[townSlot] {
			town := w.kingdoms[0].towns[townSlot]
			width, height := BuildingTileSize(TownHall{})
			return f32(town.x)+f32(width)*0.5, f32(town.y)+f32(height)*0.5
		}
	}
	return f32(w.maxX)*0.5, f32(w.maxY)*0.5
}

WorldViewUpdate :: proc(w: ^World, view: ^WorldView, deltaTime: f32) {
	stamp := ProfilerBegin("View:Renderer")
	WorldRendererUpdate(w, &view.renderer)
	ProfilerEnd(stamp)
	stamp = ProfilerBegin("View:Camera")
	WorldCameraUpdate(w, &view.camera, deltaTime)
	ProfilerEnd(stamp)
	stamp = ProfilerBegin("View:Animation")
	// Animation is visual, so it only advances for buckets under the view.
	halfViewWidth := f32(rl.GetScreenWidth())/(2*view.camera.zoom)
	halfViewHeight := f32(rl.GetScreenHeight())/(2*view.camera.zoom)
	WorldUnitAnimationUpdate(
		w,
		min(deltaTime, WORLD_MAX_FRAME_DELTA),
		view.camera.target.x-halfViewWidth-4,
		view.camera.target.x+halfViewWidth+4,
		view.camera.target.y-halfViewHeight-4,
		view.camera.target.y+halfViewHeight+4,
	)
	ProfilerEnd(stamp)
	stamp = ProfilerBegin("View:Focus")
	WorldFocusCameraUpdate(view, deltaTime)
	ProfilerEnd(stamp)
	stamp = ProfilerBegin("View:Milestone")
	WorldMilestoneCameraUpdate(w, view, deltaTime)
	ProfilerEnd(stamp)
	stamp = ProfilerBegin("View:UI")
	WorldUIUpdate(w, view, view.camera)
	ProfilerEnd(stamp)
}


WorldRendererUpdate :: proc(w: ^World, renderer: ^WorldRenderer) {
	stamp := ProfilerBegin("View:TerrainUpdate")
	TerrainRendererUpdate(w, &renderer.terrain)
	ProfilerEnd(stamp)
	stamp = ProfilerBegin("View:BloodUpdate")
	BloodRenderUpdate(w, renderer)
	ProfilerEnd(stamp)
	stamp = ProfilerBegin("View:FogUpdate")
	FogRenderUpdate(w, renderer)
	ProfilerEnd(stamp)
}

WorldRendererDeinit :: proc(renderer: ^WorldRenderer) {
	TerrainRendererDeinit(&renderer.terrain)
	SpriteSetDeinit(&renderer.sprites)
	delete(renderer.items)
	delete(renderer.shadows)
	delete(renderer.lights)
	delete(renderer.memoryFires)
	BloodRenderDeinit(renderer)
	FogRenderDeinit(renderer)
}


WorldCameraUpdate :: proc(w: ^World, camera: ^rl.Camera2D, deltaTime: f32) {
	screenWidth := f32(rl.GetScreenWidth())
	screenHeight := f32(rl.GetScreenHeight())
	camera.offset = rl.Vector2{screenWidth*0.5, screenHeight*0.5}

	panX: f32 = 0
	panY: f32 = 0
	if rl.IsKeyDown(.A) do panX -= 1
	if rl.IsKeyDown(.D) do panX += 1
	if rl.IsKeyDown(.W) do panY -= 1
	if rl.IsKeyDown(.S) do panY += 1
	panDistance := 220 * deltaTime / camera.zoom
	camera.target.x += panX * panDistance
	camera.target.y += panY * panDistance

	if rl.IsMouseButtonDown(.MIDDLE) {
		mouseDelta := rl.GetMouseDelta()
		camera.target.x -= mouseDelta.x / camera.zoom
		camera.target.y -= mouseDelta.y / camera.zoom
	}

	wheel := rl.GetMouseWheelMove()
	if wheel != 0 {
		mouseScreen := rl.GetMousePosition()
		mouseWorldBefore := rl.Vector2{
			(mouseScreen.x-camera.offset.x)/camera.zoom + camera.target.x,
			(mouseScreen.y-camera.offset.y)/camera.zoom + camera.target.y,
		}

		if wheel > 0 {
			camera.zoom *= 1 + 0.1*wheel
		} else {
			camera.zoom /= 1 - 0.1*wheel
		}

		minimumZoom := WorldCameraMinimumZoom(w, screenWidth, screenHeight)
		if camera.zoom < minimumZoom do camera.zoom = minimumZoom
		if camera.zoom > WorldCameraMaxZoom do camera.zoom = WorldCameraMaxZoom

		mouseWorldAfter := rl.Vector2{
			(mouseScreen.x-camera.offset.x)/camera.zoom + camera.target.x,
			(mouseScreen.y-camera.offset.y)/camera.zoom + camera.target.y,
		}
		camera.target.x += mouseWorldBefore.x - mouseWorldAfter.x
		camera.target.y += mouseWorldBefore.y - mouseWorldAfter.y

	}
}

WorldCameraMinimumZoom :: proc(w: ^World, screenWidth, screenHeight: f32) -> f32 {
	worldWidth := f32(w.maxX)
	worldHeight := f32(w.maxY)
	return max(screenWidth/worldWidth, screenHeight/worldHeight)
}


WorldRender :: proc(w: ^World, renderer: ^WorldRenderer, camera: rl.Camera2D) {
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 do return

	screenWidth := f32(rl.GetScreenWidth())
	screenHeight := f32(rl.GetScreenHeight())
	halfViewWidth := screenWidth / (2*camera.zoom)
	halfViewHeight := screenHeight / (2*camera.zoom)
	firstCopyX := WorldFloor((camera.target.x-halfViewWidth)/f32(worldWidth))
	lastCopyX := WorldFloor((camera.target.x+halfViewWidth)/f32(worldWidth))
	firstCopyY := WorldFloor((camera.target.y-halfViewHeight)/f32(worldHeight))
	lastCopyY := WorldFloor((camera.target.y+halfViewHeight)/f32(worldHeight))

	rl.BeginMode2D(camera)
	stamp := ProfilerBegin("Render:Terrain")
	if camera.zoom >= TERRAIN_CHUNK_MIN_ZOOM {
		TerrainRenderChunks(
			w,
			&renderer.terrain,
			camera,
			firstCopyX,
			lastCopyX,
			firstCopyY,
			lastCopyY,
		)
	} else {
		TerrainRenderLow(
			&renderer.terrain,
			f32(worldWidth),
			f32(worldHeight),
			firstCopyX,
			lastCopyX,
			firstCopyY,
			lastCopyY,
		)
	}
	ProfilerEnd(stamp)
	stamp = ProfilerBegin("Render:Blood")
	BloodRenderGround(
		w,
		renderer,
		camera,
		firstCopyX,
		lastCopyX,
		firstCopyY,
		lastCopyY,
	)
	ProfilerEnd(stamp)
	stamp = ProfilerBegin("Render:Hazards")
	WorldRenderHazards(w, renderer, camera)
	ProfilerEnd(stamp)
	stamp = ProfilerBegin("Render:Scars")
	WorldRenderTerrainScars(w, camera)
	ProfilerEnd(stamp)
	stamp = ProfilerBegin("Render:Sprites")
	WorldRenderSprites(
		w,
		renderer,
		camera,
		firstCopyX,
		lastCopyX,
		firstCopyY,
		lastCopyY,
	)
	ProfilerEnd(stamp)
	stamp = ProfilerBegin("Render:Fog")
	FogRenderDraw(w, renderer, firstCopyX, lastCopyX, firstCopyY, lastCopyY)
	ProfilerEnd(stamp)
	stamp = ProfilerBegin("Render:Environment")
	WorldRenderEnvironmentEvent(w, camera)
	ProfilerEnd(stamp)
	rl.EndMode2D()

	ambient := WorldAmbientColor(w)
	if ambient[0] < 255 || ambient[1] < 255 || ambient[2] < 255 {
		stamp = ProfilerBegin("Render:Ambient")
		rl.BeginBlendMode(.MULTIPLIED)
		rl.DrawRectangle(0, 0, rl.GetScreenWidth(), rl.GetScreenHeight(), ambient)
		rl.EndBlendMode()
		ProfilerEnd(stamp)
	}

	night := WorldNightAmount(w)
	if night > 0.02 && renderer.sprites.glow.id != 0 && len(renderer.lights) > 0 {
		stamp = ProfilerBegin("Render:Lights")
		glowSource := rl.Rectangle{0, 0, f32(renderer.sprites.glow.width), f32(renderer.sprites.glow.height)}
		rl.BeginMode2D(camera)
		rl.BeginBlendMode(.ADDITIVE)
		for light in renderer.lights {
			rl.DrawTexturePro(
				renderer.sprites.glow,
				glowSource,
				light.dest,
				rl.Vector2{0, 0},
				0,
				rl.Color{255, 255, 255, light.alpha},
			)
		}
		rl.EndBlendMode()
		rl.EndMode2D()
		ProfilerEnd(stamp)
	}

	stamp = ProfilerBegin("Render:Weather")
	WorldRenderWeather(w)
	ProfilerEnd(stamp)
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
	base := keys[0].color
	for i in 0 ..< len(keys)-1 {
		if hour >= keys[i].hour && hour <= keys[i+1].hour {
			t := (hour-keys[i].hour)/(keys[i+1].hour-keys[i].hour)
			base = WorldLerpColor(keys[i].color, keys[i+1].color, t)
			break
		}
	}

	tint := rl.Color{255, 255, 255, 255}
	switch w.weather.kind {
	case .Clear:
	case .Rain:
		tint = rl.Color{150, 166, 184, 255}
	case .Storm:
		tint = rl.Color{112, 124, 146, 255}
	case .Fog:
		tint = rl.Color{196, 198, 202, 255}
	case .Snow:
		tint = rl.Color{222, 232, 242, 255}
	case .Blizzard:
		tint = rl.Color{190, 202, 218, 255}
	case .Drought:
		tint = rl.Color{255, 232, 196, 255}
	case .Heatwave:
		tint = rl.Color{255, 206, 160, 255}
	case .Sandstorm:
		tint = rl.Color{214, 176, 128, 255}
	case .Ashfall:
		tint = rl.Color{170, 156, 148, 255}
	}
	mix := PositionToF32(w.weather.value)*(0.35+0.25*(1-WorldNightAmount(w)))
	return WorldLerpColor(base, tint, mix)
}

WorldLerpColor :: proc(a, b: rl.Color, t: f32) -> rl.Color {
	return rl.Color{
		u8(clamp(f32(a[0])+(f32(b[0])-f32(a[0]))*t, 0, 255)),
		u8(clamp(f32(a[1])+(f32(b[1])-f32(a[1]))*t, 0, 255)),
		u8(clamp(f32(a[2])+(f32(b[2])-f32(a[2]))*t, 0, 255)),
		u8(clamp(f32(a[3])+(f32(b[3])-f32(a[3]))*t, 0, 255)),
	}
}

// Screen-space weather: cheap, camera-independent and deterministic.
WorldRenderWeather :: proc(w: ^World) {
	value := PositionToF32(w.weather.value)
	flash := w.weather.lightningFlash
	if value <= 0.01 && flash <= 0.01 do return

	screenWidth := f32(rl.GetScreenWidth())
	screenHeight := f32(rl.GetScreenHeight())
	time := w.simulationTime+w.simulationAccumulator
	seed := w.seed+u64(w.weather.sequence)*7919
	windX := PositionToF32(w.weather.windX)

	overlay := rl.Color{0, 0, 0, 0}
	switch w.weather.kind {
	case .Clear:
	case .Rain:
		overlay = rl.Color{40, 60, 86, u8(22*value)}
	case .Storm:
		overlay = rl.Color{28, 36, 54, u8(40*value)}
	case .Fog:
		overlay = rl.Color{190, 196, 200, u8(34*value)}
	case .Snow:
		overlay = rl.Color{220, 232, 244, u8(28*value)}
	case .Blizzard:
		overlay = rl.Color{205, 220, 236, u8(48*value)}
	case .Drought:
		overlay = rl.Color{120, 90, 40, u8(18*value)}
	case .Heatwave:
		overlay = rl.Color{160, 90, 30, u8(22*value)}
	case .Sandstorm:
		overlay = rl.Color{150, 110, 60, u8(40*value)}
	case .Ashfall:
		overlay = rl.Color{80, 70, 66, u8(30*value)}
	}
	if overlay.a > 0 {
		rl.DrawRectangle(0, 0, rl.GetScreenWidth(), rl.GetScreenHeight(), overlay)
	}

	if flash > 0 {
		rl.DrawRectangle(
			0,
			0,
			rl.GetScreenWidth(),
			rl.GetScreenHeight(),
			rl.Color{224, 236, 255, u8(58*flash)},
		)
		boltX := screenWidth*(0.2+WorldNoiseHash(int(w.weather.sequence), 3, w.seed)*0.6)
		x := boltX
		y: f32 = 0
		for segment in 0..<8 {
			nextX := x+(WorldNoiseHash(segment, int(w.weather.sequence), 0xB017)-0.5)*50
			nextY := y+screenHeight/8
			rl.DrawLineEx(
				rl.Vector2{x, y},
				rl.Vector2{nextX, nextY},
				2,
				rl.Color{224, 238, 255, u8(220*flash)},
			)
			x = nextX
			y = nextY
		}
	}

	switch w.weather.kind {
	case .Rain, .Storm:
		count := int(260*value)
		for i in 0..<count {
			h1 := WorldNoiseHash(i, 0, seed)
			h2 := WorldNoiseHash(i, 1, seed)
			speed := 700+h2*500
			y := WorldWrapPosition(h2*screenHeight+time*speed, screenHeight+40)-20
			x := WorldWrapPosition(h1*screenWidth+time*windX*220, screenWidth+80)-40
			slant := windX*160
			rl.DrawLineEx(
				rl.Vector2{x, y},
				rl.Vector2{x+slant, y+12+h1*16},
				1.2,
				rl.Color{190, 214, 236, u8(110+70*h2)},
			)
		}
	case .Snow, .Blizzard:
		baseCount := 180
		if w.weather.kind == .Blizzard do baseCount = 260
		count := int(f32(baseCount)*value)
		for i in 0..<count {
			h1 := WorldNoiseHash(i, 2, seed)
			h2 := WorldNoiseHash(i, 3, seed)
			fall := 30+h1*70
			y := WorldWrapPosition(h2*screenHeight+time*fall, screenHeight+20)-10
			x := WorldWrapPosition(
				h1*screenWidth+time*windX*120+math.sin(time*0.8+f32(i))*16,
				screenWidth+20,
			)-10
			rl.DrawCircleV(rl.Vector2{x, y}, 1+h1*1.6, rl.Color{240, 245, 252, u8(120+90*h2)})
		}
	case .Fog:
		for i in 0..<6 {
			h1 := WorldNoiseHash(i, 4, seed)
			h2 := WorldNoiseHash(i, 5, seed)
			x := WorldWrapPosition(h1*screenWidth+time*(8+h2*12), screenWidth+400)-200
			y := h2*screenHeight
			rl.DrawEllipse(i32(x), i32(y), 220, 70, rl.Color{210, 214, 218, u8(12*value)})
		}
	case .Drought, .Heatwave, .Sandstorm:
		count := int(140*value)
		for i in 0..<count {
			h1 := WorldNoiseHash(i, 6, seed)
			h2 := WorldNoiseHash(i, 7, seed)
			y := WorldWrapPosition(h2*screenHeight+time*(20+h1*40), screenHeight+20)-10
			x := WorldWrapPosition(
				h1*screenWidth+time*(60+windX*140),
				screenWidth+60,
			)-30
			rl.DrawCircleV(rl.Vector2{x, y}, 1+h1*2, rl.Color{196, 168, 120, u8(70+60*h2)})
		}
	case .Ashfall:
		count := int(120*value)
		for i in 0..<count {
			h1 := WorldNoiseHash(i, 8, seed)
			h2 := WorldNoiseHash(i, 9, seed)
			y := WorldWrapPosition(h2*screenHeight+time*(18+h1*30), screenHeight+20)-10
			x := WorldWrapPosition(
				h1*screenWidth+time*windX*100,
				screenWidth+40,
			)-20
			rl.DrawCircleV(rl.Vector2{x, y}, 0.8+h1*1.6, rl.Color{188, 166, 154, u8(80+60*h2)})
		}
	case .Clear:
	}
}

WorldRenderEnvironmentEvent :: proc(w: ^World, camera: rl.Camera2D) {
	e := &w.environment
	if e.phase == .None || !EnvironmentEventRevealed(w) do return

	color := EnvironmentEventColor(e.kind)
	time := w.simulationTime+w.simulationAccumulator
	pulse := 0.5+0.5*math.sin(time*6)
	outline := color
	outline.a = u8(140+90*pulse)
	fill := color
	fill.a = e.phase == .Telegraph ? 18 : 30
	centerX := PositionToF32(e.centerX)
	centerY := PositionToF32(e.centerY)
	radius := PositionToF32(e.radius)
	center := rl.Vector2{centerX, centerY}

	rl.BeginMode2D(camera)
	rl.DrawCircleV(center, radius, fill)
	rl.DrawCircleLines(i32(centerX), i32(centerY), radius, outline)

	for tick in 0..<6 {
		angle := time*0.8+f32(tick)*6.2831853/6
		rl.DrawLineEx(
			rl.Vector2{
				centerX+math.cos(angle)*radius*0.86,
				centerY+math.sin(angle)*radius*0.86,
			},
			rl.Vector2{
				centerX+math.cos(angle)*radius*0.96,
				centerY+math.sin(angle)*radius*0.96,
			},
			2,
			outline,
		)
	}

	switch e.kind {
	case .Wildfire, .Eruption, .MeteorShower:
		for i in 0..<26 {
			h1 := WorldNoiseHash(i, int(e.sequence), w.seed+0x6A1)
			h2 := WorldNoiseHash(i, int(e.sequence)+3, w.seed+0x6A3)
			angle := h1*6.2831853
			distance := radius*math.sqrt(h2)
			x := centerX+math.cos(angle)*distance
			y := centerY+math.sin(angle)*distance
			rl.DrawCircleV(rl.Vector2{x, y}, 0.12+h1*0.18, outline)
		}
	case .Flood:
		for line in 0..<5 {
			yy := centerY-radius*0.6+f32(line)*radius*0.3
			rl.DrawLineEx(
				rl.Vector2{centerX-radius*0.9, yy},
				rl.Vector2{centerX+radius*0.9, yy},
				2,
				outline,
			)
		}
	case .Blizzard:
		for i in 0..<20 {
			h1 := WorldNoiseHash(i, int(e.sequence), w.seed+0x6B1)
			h2 := WorldNoiseHash(i, int(e.sequence)+5, w.seed+0x6B3)
			x := centerX+(h1-0.5)*radius*1.8
			y := centerY+(h2-0.5)*radius*1.8
			rl.DrawLineEx(
				rl.Vector2{x, y},
				rl.Vector2{x-0.25, y+0.45},
				1.2,
				outline,
			)
		}
	case .Drought:
		for line in 0..<4 {
			yy := centerY-radius*0.5+f32(line)*radius*0.34
			rl.DrawLineEx(
				rl.Vector2{centerX-radius*0.8, yy},
				rl.Vector2{centerX+radius*0.8, yy},
				1.5,
				outline,
			)
		}
	case .Earthquake:
		for ring in 0..<3 {
			r := radius*(0.3+f32(ring)*0.22)+pulse*0.3
			rl.DrawCircleLines(i32(centerX), i32(centerY), r, outline)
		}
	case .Locusts:
		for i in 0..<34 {
			h1 := WorldNoiseHash(i, int(e.sequence), w.seed+0x6C1)
			h2 := WorldNoiseHash(i, int(e.sequence)+7, w.seed+0x6C3)
			x := centerX+(h1-0.5)*radius*1.6
			y := centerY+(h2-0.5)*radius*1.6
			rl.DrawCircleV(rl.Vector2{x, y}, 0.11+h1*0.1, outline)
		}
	case .Hurricane:
		for ring in 0..<4 {
			offset := math.sin(time*1.4+f32(ring))*radius*0.15
			rl.DrawCircleLines(
				i32(centerX+offset),
				i32(centerY-offset*0.6),
				radius*(0.35+f32(ring)*0.2),
				outline,
			)
		}
		for ray in 0..<8 {
			angle := time*0.7+f32(ray)*6.2831853/8
			rl.DrawLineEx(
				rl.Vector2{
					centerX+math.cos(angle)*radius*0.5,
					centerY+math.sin(angle)*radius*0.5,
				},
				rl.Vector2{
					centerX+math.cos(angle+0.5)*radius*0.95,
					centerY+math.sin(angle+0.5)*radius*0.95,
				},
				1.5,
				outline,
			)
		}
	}

	if e.phase == .Telegraph {
		progress := 1-clamp(
			PositionToF32(e.remaining)/max(PositionToF32(e.telegraph), 0.01),
			0,
			1,
		)
		rl.DrawCircleLines(
			i32(centerX),
			i32(centerY),
			radius*(1-progress*0.45),
			outline,
		)
	}
	rl.EndMode2D()
}

// Decorations are only a pixel or two tall below this zoom, so drawing them
// would cost more than it adds.
DECORATION_MIN_ZOOM : f32 : 4

// Position used for drawing and picking, interpolated between simulation ticks.
// Every unit carries the time of its last update, so skipped (LOD) updates
// stretch the interpolation window instead of snapping.
UnitRenderPosition :: proc(w: ^World, unitSlot: int) -> (x, y: f32) {
	x = UnitX(w, unitSlot)
	y = UnitY(w, unitSlot)
	now := w.simulationTime+w.simulationAccumulator
	interval := w.units.updateInterval[unitSlot]
	alpha: f32 = 1
	if interval > 0 {
		alpha = clamp((now-w.units.updateTime[unitSlot])/interval, 0, 1)
	}
	worldWidth := f32(w.maxX)
	worldHeight := f32(w.maxY)
	x = WorldWrapPosition(
		UnitPrevX(w, unitSlot)+
		WorldShortestWrappedDelta(UnitX(w, unitSlot)-UnitPrevX(w, unitSlot), worldWidth)*
			alpha,
		worldWidth,
	)
	y = WorldWrapPosition(
		UnitPrevY(w, unitSlot)+
		WorldShortestWrappedDelta(UnitY(w, unitSlot)-UnitPrevY(w, unitSlot), worldHeight)*
			alpha,
		worldHeight,
	)
	return
}

FogLiveBuildingAtAnchor :: proc(w: ^World, anchor: int) -> bool {
	if anchor < 0 || anchor >= len(w.tileBuilding) do return false
	slot := w.tileBuilding[anchor]
	return slot >= 0 && slot < BUILDING_CAPACITY && w.buildingUsed[slot]
}

FogAppendMemoryBuilding :: proc(
	w: ^World,
	renderer: ^WorldRenderer,
	offsetX, offsetY: f32,
	anchor: int,
	minX, maxX, minY, maxY: f32,
) {
	if anchor < 0 || anchor >= len(w.fog.buildingKind) do return
	kindByte := w.fog.buildingKind[anchor]
	if kindByte == FOG_NONE do return

	kind := BuildingKind(kindByte)
	flags := w.fog.buildingFlags[anchor]
	kingdom := int(w.fog.buildingKingdom[anchor])
	if kingdom < 0 || kingdom >= KINGDOM_SLOTS do return

	width, height := BuildingTileSize(BuildingTypeFromKind(kind))
	heightMap := int(w.maxY)
	tileY := anchor%heightMap
	tileX := anchor/heightMap
	x := f32(tileX)
	y := f32(tileY)
	if x+f32(width) < minX || x > maxX || y+f32(height) < minY || y > maxY {
		return
	}

	faction := FactionSpriteIndex(kingdom)
	if (flags & FOG_FLAG_CONSTRUCTION) != 0 {
		texture := renderer.sprites.construction[faction]
		if texture.id == 0 do return
		for siteX in tileX ..< tileX+width {
			for siteY in tileY ..< tileY+height {
				if f32(siteX)+1 < minX || f32(siteX) > maxX ||
					f32(siteY)+1 < minY || f32(siteY) > maxY {
					continue
				}
				append(&renderer.items, RenderItem{
					baseY = -1e9,
					dest = rl.Rectangle{offsetX+f32(siteX), offsetY+f32(siteY), 1, 1},
					texture = texture,
					tint = FOG_MEMORY_TINT,
				})
			}
		}
		return
	}

	texture := renderer.sprites.building[faction][kind]
	if texture.id == 0 do return
	append(&renderer.items, RenderItem{
		baseY = y+f32(height),
		dest = rl.Rectangle{offsetX+x, offsetY+y, f32(width), f32(height)},
		texture = texture,
		tint = FOG_MEMORY_TINT,
	})

	if (flags & FOG_FLAG_BURNING) != 0 {
		fireWidth := f32(width)*0.8
		fireHeight := f32(height)*0.9
		append(&renderer.memoryFires, RenderQuad{
			dest = rl.Rectangle{
				offsetX+x+(f32(width)-fireWidth)*0.5,
				offsetY+y+f32(height)-fireHeight,
				fireWidth,
				fireHeight,
			},
			alpha = 165,
		})
	}
}

FogAppendMemoryDecorations :: proc(
	w: ^World,
	renderer: ^WorldRenderer,
	offsetX, offsetY: f32,
	minX, maxX, minY, maxY: f32,
) {
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 do return

	firstX := WorldFloor(minX)-1
	lastX := WorldFloor(maxX)+1
	firstY := WorldFloor(minY)-1
	lastY := WorldFloor(maxY)+1
	if lastX-firstX >= worldWidth {
		firstX = 0
		lastX = worldWidth-1
	}
	if lastY-firstY >= worldHeight {
		firstY = 0
		lastY = worldHeight-1
	}

	for y in firstY ..= lastY {
		wrappedY := WorldWrapCoordinate(y, worldHeight)
		for x in firstX ..= lastX {
			wrappedX := WorldWrapCoordinate(x, worldWidth)
			index := wrappedX*worldHeight+wrappedY
			if !w.fog.explored[index] || w.fog.visible[index] do continue
			kindByte := w.fog.decorationKind[index]
			if kindByte == FOG_NONE do continue

			kind := DecorationKind(kindByte)
			texture := renderer.sprites.decoration[kind]
			if texture.id == 0 do continue
			variant := w.fog.decorationVariant[index]
			variantScale := 0.94+f32((variant>>1)&3)*0.04
			width := f32(texture.width)/PIXELS_PER_TILE*variantScale
			height := f32(texture.height)/PIXELS_PER_TILE*variantScale
			decorationX := f32(x)+f32(w.fog.decorationOffsetX[index])/255
			decorationY := f32(y)+f32(w.fog.decorationOffsetY[index])/255
			append(&renderer.items, RenderItem{
				baseY = decorationY,
				dest = rl.Rectangle{
					offsetX+decorationX-width*0.5,
					offsetY+decorationY-height,
					width,
					height,
				},
				texture = texture,
				flipX = (variant & 1) == 1,
				tint = FOG_MEMORY_TINT,
			})
		}
	}
}

WorldRenderSprites :: proc(w: ^World, renderer: ^WorldRenderer, camera: rl.Camera2D, firstCopyX, lastCopyX, firstCopyY, lastCopyY: int) {
	worldWidth := f32(w.maxX)
	worldHeight := f32(w.maxY)
	screenWidth := f32(rl.GetScreenWidth())
	screenHeight := f32(rl.GetScreenHeight())
	halfViewWidth := screenWidth / (2*camera.zoom)
	halfViewHeight := screenHeight / (2*camera.zoom)
	viewMinX := camera.target.x-halfViewWidth
	viewMaxX := camera.target.x+halfViewWidth
	viewMinY := camera.target.y-halfViewHeight
	viewMaxY := camera.target.y+halfViewHeight
	bobTime := w.simulationTime+w.simulationAccumulator
	shadowSource := rl.Rectangle{0, 0, f32(renderer.sprites.shadow.width), f32(renderer.sprites.shadow.height)}
	night := WorldNightAmount(w)
	clear(&renderer.lights)

	for copyX in firstCopyX ..< lastCopyX+1 {
		offsetX := f32(copyX)*worldWidth
		for copyY in firstCopyY ..< lastCopyY+1 {
			offsetY := f32(copyY)*worldHeight
			minX := viewMinX-offsetX
			maxX := viewMaxX-offsetX
			minY := viewMinY-offsetY
			maxY := viewMaxY-offsetY

			clear(&renderer.items)
			clear(&renderer.shadows)
			clear(&renderer.memoryFires)

			if camera.zoom >= PARTICLE_MIN_ZOOM {
				ParticleDraw(w, renderer, offsetX, offsetY, minX, maxX, minY, maxY, true)
			}

			for buildingSlot in 0 ..< BUILDING_CAPACITY {
				if !w.buildingUsed[buildingSlot] do continue
				buildingWidth, buildingHeight := BuildingTileSize(w.buildings[buildingSlot].type)
				buildingX := f32(w.buildings.x[buildingSlot])
				buildingY := f32(w.buildings.y[buildingSlot])
				width := f32(buildingWidth)
				height := f32(buildingHeight)
				kind := BuildingKindOf(w.buildings[buildingSlot].type)
				if buildingX+width < minX || buildingX > maxX ||
					buildingY+height < minY || buildingY > maxY {
					continue
				}

				if !FogBuildingVisible(w, buildingSlot) {
					FogAppendMemoryBuilding(
						w,
						renderer,
						offsetX,
						offsetY,
						FogTileIndex(w, w.buildings.x[buildingSlot], w.buildings.y[buildingSlot]),
						minX,
						maxX,
						minY,
						maxY,
					)
					continue
				}

				faction := FactionSpriteIndex(w.buildings[buildingSlot].kingdom)
				baseY := buildingY+height
				if BuildingWalkable(w.buildings[buildingSlot].type) {
					baseY = -1e9
				} else {
					shadowWidth := width*1.2
					// Contact shadow for small buildings, longer cast shadow for big ones.
					lip := 0.35*math.pow(height, 1.44)
					shadowHeight := lip/0.8
					append(&renderer.shadows, RenderQuad{
						dest = rl.Rectangle{
							x = offsetX+buildingX-(shadowWidth-width)*0.5,
							y = offsetY+buildingY+height-shadowHeight*0.2,
							width = shadowWidth,
							height = shadowHeight,
						},
						alpha = 220,
					})
				}
				if night > 0.02 && BuildingHasNightLight(kind) {
					lightWidth := width*0.95
					lightHeight := height*0.7
					flicker := 78+10*math.sin(w.simulationTime*2.4+f32(buildingSlot)*1.7)
					append(&renderer.lights, RenderQuad{
						dest = rl.Rectangle{
							x = offsetX+buildingX+(width-lightWidth)*0.5,
							y = offsetY+buildingY+height*0.45-lightHeight*0.5,
							width = lightWidth,
							height = lightHeight,
						},
						alpha = u8(night*flicker),
					})
				}
				texture := renderer.sprites.building[faction][kind]
				damageStage := BuildingDamageStage(w, buildingSlot)
				if damageStage > 0 {
					damaged := renderer.sprites.buildingDamaged[faction][kind][damageStage-1]
					if damaged.id != 0 do texture = damaged
				}
				append(&renderer.items, RenderItem{
					baseY = baseY,
					dest = rl.Rectangle{offsetX+buildingX, offsetY+buildingY, width, height},
					texture = texture,
				})
			}

			for anchor in w.fog.ghosts {
				if FogTileVisibleIndex(w, anchor) do continue
				if FogLiveBuildingAtAnchor(w, anchor) do continue
				FogAppendMemoryBuilding(
					w,
					renderer,
					offsetX,
					offsetY,
					anchor,
					minX,
					maxX,
					minY,
					maxY,
				)
			}

			for kingdomSlot in 0 ..< KINGDOMS_CAPACITY {
				if !w.kingdomUsed[kingdomSlot] do continue
				texture := renderer.sprites.construction[FactionSpriteIndex(kingdomSlot)]
				if texture.id == 0 do continue
				for townSlot in 0 ..< TOWN_CAPACITY {
					if !w.kingdoms[kingdomSlot].townUsed[townSlot] do continue
					town := &w.kingdoms[kingdomSlot].towns[townSlot]
					for site in town.constructions {
						if !site.active do continue
						width, height := BuildingTileSize(BuildingTypeFromKind(site.kind))
						if !FogRectVisible(w, site.x, site.y, width, height) {
							FogAppendMemoryBuilding(
								w,
								renderer,
								offsetX,
								offsetY,
								FogTileIndex(w, site.x, site.y),
								minX,
								maxX,
								minY,
								maxY,
							)
							continue
						}
						for tileX in site.x ..< site.x+width {
							for tileY in site.y ..< site.y+height {
								if f32(tileX)+1 < minX || f32(tileX) > maxX ||
									f32(tileY)+1 < minY || f32(tileY) > maxY {
									continue
								}
								append(&renderer.items, RenderItem{
									baseY = -1e9,
									dest = rl.Rectangle{
										offsetX+f32(tileX),
										offsetY+f32(tileY),
										1,
										1,
									},
									texture = texture,
								})
							}
						}
					}
				}
			}

			for siteSlot in 0 ..< COMBAT_SITE_CAPACITY {
				if !w.combatSiteUsed[siteSlot] do continue
				texture := renderer.sprites.construction[FactionSpriteIndex(w.combatSites.kingdom[siteSlot])]
				if texture.id == 0 do continue
				siteX := w.combatSites.x[siteSlot]
				siteY := w.combatSites.y[siteSlot]
				width, height := BuildingTileSize(BuildingTypeFromKind(w.combatSites.kind[siteSlot]))
				if !FogRectVisible(w, siteX, siteY, width, height) do continue
				for tileX in siteX ..< siteX+width {
					for tileY in siteY ..< siteY+height {
						if f32(tileX)+1 < minX || f32(tileX) > maxX ||
							f32(tileY)+1 < minY || f32(tileY) > maxY {
							continue
						}
						append(&renderer.items, RenderItem{
							baseY = -1e9,
							dest = rl.Rectangle{
								offsetX+f32(tileX),
								offsetY+f32(tileY),
								1,
								1,
							},
							texture = texture,
						})
					}
				}
			}

			if camera.zoom >= DECORATION_MIN_ZOOM && w.spatial.chunkSize > 0 {
				chunksX := w.spatial.chunksX
				chunksY := w.spatial.chunksY
				firstChunkX := WorldFloor(minX/f32(w.spatial.chunkSize))-1
				lastChunkX := WorldFloor(maxX/f32(w.spatial.chunkSize))+1
				firstChunkY := WorldFloor(minY/f32(w.spatial.chunkSize))-1
				lastChunkY := WorldFloor(maxY/f32(w.spatial.chunkSize))+1
				if lastChunkX-firstChunkX >= chunksX {
					firstChunkX = 0
					lastChunkX = chunksX-1
				}
				if lastChunkY-firstChunkY >= chunksY {
					firstChunkY = 0
					lastChunkY = chunksY-1
				}

				for chunkY in firstChunkY ..= lastChunkY {
					wrappedY := WorldWrapCoordinate(chunkY, chunksY)
					for chunkX in firstChunkX ..= lastChunkX {
						wrappedX := WorldWrapCoordinate(chunkX, chunksX)
						chunk := wrappedX*chunksY+wrappedY
						for decorationSlot := w.spatial.decorationHead[chunk]; decorationSlot >= 0;
							decorationSlot = w.spatial.decorationNext[decorationSlot] {
							texture := renderer.sprites.decoration[w.decorations.kind[decorationSlot]]
							if texture.id == 0 do continue

							variant := w.decorations.variant[decorationSlot]
							variantScale := 0.94+f32((variant>>1)&3)*0.04
							width := f32(texture.width)/PIXELS_PER_TILE*variantScale
							height := f32(texture.height)/PIXELS_PER_TILE*variantScale
							decorationX := PositionToF32(w.decorations.x[decorationSlot])
							decorationY := PositionToF32(w.decorations.y[decorationSlot])
							if !FogTileVisible(w, int(decorationX), int(decorationY)) do continue
							if decorationX+width*0.5 < minX || decorationX-width*0.5 > maxX ||
								decorationY < minY || decorationY-height > maxY {
								continue
							}

							append(&renderer.items, RenderItem{
								baseY = decorationY,
								dest = rl.Rectangle{
									offsetX+decorationX-width*0.5,
									offsetY+decorationY-height,
									width,
									height,
								},
								texture = texture,
								flipX = (variant & 1) == 1,
							})

							if night > 0.02 && w.decorations.kind[decorationSlot] == .Lamp {
								lightWidth: f32 = 2.2
								lightHeight: f32 = 1.9
								flicker := 90+8*math.sin(w.simulationTime*3.1+f32(decorationSlot)*1.3)
								append(&renderer.lights, RenderQuad{
									dest = rl.Rectangle{
										offsetX+decorationX-lightWidth*0.5,
										offsetY+decorationY-1.15-lightHeight*0.5,
										lightWidth,
										lightHeight,
									},
									alpha = u8(night*flicker),
								})
							}
						}
					}
				}
				FogAppendMemoryDecorations(w, renderer, offsetX, offsetY, minX, maxX, minY, maxY)
			}

			// Only buckets under the view can contain a visible unit. The old loop
			// walked all UNIT_CAPACITY slots for every map copy.
			chunkSize := w.spatial.chunkSize
			chunksX := w.spatial.chunksX
			chunksY := w.spatial.chunksY
			chunkMinX := int(math.floor(minX))/chunkSize-1
			chunkMaxX := int(math.floor(maxX))/chunkSize+1
			chunkMinY := int(math.floor(minY))/chunkSize-1
			chunkMaxY := int(math.floor(maxY))/chunkSize+1
			spanX := min(chunkMaxX-chunkMinX+1, chunksX)
			spanY := min(chunkMaxY-chunkMinY+1, chunksY)
			for chunkOffsetX in 0..<spanX {
				chunkX := WorldWrapCoordinate(chunkMinX+chunkOffsetX, chunksX)
				for chunkOffsetY in 0..<spanY {
					chunkY := WorldWrapCoordinate(chunkMinY+chunkOffsetY, chunksY)
					chunk := chunkX*chunksY+chunkY
					for unitSlot := w.spatial.unitHead[chunk]; unitSlot >= 0;
						unitSlot = w.spatial.unitNext[unitSlot] {
						if !w.unitUsed[unitSlot] do continue
						if w.units[unitSlot].type == nil do continue
						if UnitHiddenInside(w, unitSlot) do continue

				kind := UnitKindOf(w.units[unitSlot].type)
				scale := UnitSpriteScale(kind)
				unitX, unitY := UnitRenderPosition(w, unitSlot)
				jump: f32 = 0
				jumpElapsed := w.simulationTime+w.simulationAccumulator-w.units.jumpStarted[unitSlot]
				if jumpElapsed >= 0 && jumpElapsed < WALL_JUMP_SECONDS {
					jump = math.sin(jumpElapsed/WALL_JUMP_SECONDS*math.PI)*WALL_JUMP_HEIGHT
				}
				if unitX+scale+1 < minX || unitX-1 > maxX ||
					unitY+1 < minY || unitY-scale-1 > maxY {
					continue
				}
				if w.units[unitSlot].kingdome != w.observerKingdom &&
					!FogTileVisible(w, int(unitX), int(unitY)) {
					continue
				}

				pose := UnitAnimationPoseFor(w, unitSlot, kind, bobTime)

				faction := FactionSpriteIndex(w.units[unitSlot].kingdome)
				texture := renderer.sprites.unit[faction][kind]
				if pose.damageStage > 0 {
					hurt := renderer.sprites.unitHurt[faction][kind][pose.damageStage-1]
					if hurt.id != 0 do texture = hurt
				}
				if pose.moving {
					frame := math.sin(w.units[unitSlot].walkPhase) < 0 ? 1 : 0
					if pose.damageStage > 0 {
						hurtWalk := renderer.sprites.unitHurtWalk[faction][kind][pose.damageStage-1][frame]
						if hurtWalk.id != 0 do texture = hurtWalk
					} else {
						walk := renderer.sprites.unitWalk[faction][kind][frame]
						if walk.id != 0 do texture = walk
					}
				}
				flipX := false
				if w.units[unitSlot].pathReady {
					deltaX := WorldShortestWrappedDelta(
						TileCenterRaw(w.units[unitSlot].pathTargetX)-unitX,
						f32(w.maxX),
					)
					flipX = deltaX < -0.5
				}
				width := scale*pose.stretchX
				height := scale*pose.stretchY
				if kind != .Turtle && UnitOnWaterTile(w, unitSlot) &&
					UnitCanCrossWater(w, w.units[unitSlot].type, w.units[unitSlot].kingdome) {
					append(&renderer.items, RenderItem{
						baseY = unitY+0.42,
						dest = rl.Rectangle{
							offsetX+unitX-0.85,
							offsetY+unitY-0.48,
							1.7,
							0.9,
						},
						texture = renderer.sprites.boat,
						tint = UnitIsWarrior(w.units[unitSlot].type) ? FactionColor(w, w.units[unitSlot].kingdome) : rl.WHITE,
					})
				}
				append(&renderer.items, RenderItem{
					baseY = unitY+pose.swayY+0.5,
					dest = rl.Rectangle{
						x = offsetX+unitX-width*0.5+pose.swayX,
						y = offsetY+unitY+0.5-height+pose.bob+pose.swayY-jump,
						width = width,
						height = height,
					},
					texture = texture,
					flipX = flipX,
				})
					}
				}
			}

			slice.sort_by(renderer.items[:], RenderItemLess)
			if renderer.sprites.shadow.id != 0 {
				for shadow in renderer.shadows {
					rl.DrawTexturePro(
						renderer.sprites.shadow,
						shadowSource,
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
				if item.flipX do source.width = -source.width
				color := item.tint
				if color.a == 0 do color = rl.WHITE
				rl.DrawTexturePro(item.texture, source, item.dest, rl.Vector2{0, 0}, 0, color)
			}
			if camera.zoom >= 4 {
				WorldRenderTechOverlays(
					w,
					offsetX,
					offsetY,
					minX,
					maxX,
					minY,
					maxY,
					camera.zoom,
				)
			}

			if renderer.sprites.fire.id != 0 {
				fireSource := rl.Rectangle{
					0,
					0,
					f32(renderer.sprites.fire.width),
					f32(renderer.sprites.fire.height),
				}
				for fire in renderer.memoryFires {
					rl.DrawTexturePro(
						renderer.sprites.fire,
						fireSource,
						fire.dest,
						rl.Vector2{0, 0},
						0,
						rl.Color{176, 176, 176, fire.alpha},
					)
				}
				if w.fireCount > 0 {
					for activeIndex in 0..<w.fireCount {
						fireSlot := w.fireActive[activeIndex]
						fireX := PositionToF32(w.fires.x[fireSlot])
						fireY := PositionToF32(w.fires.y[fireSlot])
						if fireX+1 < minX || fireX-1 > maxX ||
							fireY+1 < minY || fireY-1 > maxY {
							continue
						}
						if !FogTileVisible(w, int(fireX), int(fireY)) do continue

						flicker := 0.9+0.12*math.sin(w.simulationTime*9+f32(fireSlot)*1.7)
						intensity := w.fires.intensity[fireSlot]
						width := (0.72+0.18*intensity)*flicker
						height := (1.15+0.4*intensity)*flicker
						jitterX := (WorldNoiseHash(fireSlot, 1, 0xF12)-0.5)*0.3
						rl.DrawTexturePro(
							renderer.sprites.fire,
							fireSource,
							rl.Rectangle{
								offsetX+fireX+jitterX-width*0.5,
								offsetY+fireY+0.35-height,
								width,
								height,
							},
							rl.Vector2{0, 0},
							0,
							rl.Color{255, 255, 255, 235},
						)
					}
				}
			}

			if camera.zoom >= PARTICLE_MIN_ZOOM {
				ParticleDraw(w, renderer, offsetX, offsetY, minX, maxX, minY, maxY, false)
			}
		}
	}
}

WorldRenderTechOverlays :: proc(
	w: ^World,
	offsetX, offsetY, minX, maxX, minY, maxY, zoom: f32,
) {
	lineWidth := 1/zoom
	for slot in 0..<BUILDING_CAPACITY {
		if !w.buildingUsed[slot] || !FogBuildingVisible(w, slot) do continue
		kind := BuildingKindOf(w.buildings.type[slot])
		kingdom := w.buildings.kingdom[slot]
		x := offsetX+f32(w.buildings.x[slot])
		y := offsetY+f32(w.buildings.y[slot])
		width, height := BuildingTileSize(w.buildings.type[slot])
		if x+f32(width) < minX || x > maxX || y+f32(height) < minY || y > maxY {
			continue
		}

		if KingdomHasTech(w, kingdom, .Masonry) && kind != .Path && kind != .Bridge {
			rl.DrawRectangleRec(
				rl.Rectangle{x+f32(width)-0.32, y+0.1, 0.22, 0.2},
				rl.Color{154, 160, 172, 190},
			)
		}

		switch kind {
		case .Farmland:
			if KingdomHasTech(w, kingdom, .CropRotation) {
				for index in 0..<4 {
					px := x+0.35+f32(index%2)*0.75
					py := y+0.45+f32(index/2)*0.7
					rl.DrawRectangleRec(rl.Rectangle{px, py, 0.18, 0.32}, rl.Color{214, 178, 76, 220})
				}
			}
			if KingdomHasTech(w, kingdom, .Irrigation) {
				rl.DrawRectangleRec(
					rl.Rectangle{x+0.2, y+f32(height)*0.5, f32(width)-0.4, lineWidth*2},
					rl.Color{96, 178, 214, 200},
				)
			}
		case .Path:
			if KingdomHasTech(w, kingdom, .Roadworks) || KingdomHasTech(w, kingdom, .BridgeProject) {
				rl.DrawRectangleRec(
					rl.Rectangle{x+0.18, y+0.42, 0.64, lineWidth*1.5},
					rl.Color{198, 168, 112, 150},
				)
			}
		case .Bridge:
			if KingdomHasTech(w, kingdom, .Bridgeworks) || KingdomHasTech(w, kingdom, .BridgeProject) {
				for rail in 0..<2 {
					rl.DrawRectangleRec(
						rl.Rectangle{x+0.12, y+0.25+f32(rail)*0.45, 0.76, lineWidth},
						rl.Color{132, 138, 150, 210},
					)
				}
			}
		case .Wall, .Watchtower, .Cannon:
			if KingdomHasTech(w, kingdom, .Fortification) {
				rl.DrawRectangleRec(
					rl.Rectangle{x+0.2, y+0.08, 0.18, 0.22},
					rl.Color{214, 178, 92, 220},
				)
				rl.DrawRectangleRec(
					rl.Rectangle{x+0.62, y+0.08, 0.18, 0.22},
					rl.Color{214, 178, 92, 220},
				)
			}
		case .TownHall:
			if KingdomHasTech(w, kingdom, .Metropolis) {
				rl.DrawLineEx(
					rl.Vector2{x+0.5, y-0.2},
					rl.Vector2{x+0.5, y-0.9},
					lineWidth*2,
					rl.Color{224, 176, 70, 220},
				)
				rl.DrawRectangleRec(
					rl.Rectangle{x+0.52, y-0.9, 0.55, 0.3},
					rl.Color{176, 68, 64, 230},
				)
			}
		case .Home, .ArcheryRange, .MagicSchool, .GiantPen, .SiegeWorkshop, .TurtlePen, .ThievesGuild, .DistrictHall, .GiantMortar, .Harbor, .Granary, .AlchemistWorkshop, .FireworksGuild, .StarfallSpire:
		}
	}

	for slot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[slot] || w.units.type[slot] == nil || UnitHiddenInside(w, slot) do continue
		x, y := UnitRenderPosition(w, slot)
		if x < minX || x > maxX || y < minY || y > maxY do continue
		if !FogTileVisible(w, int(x), int(y)) do continue
		kind := UnitKindOf(w.units.type[slot])
		kingdom := w.units.kingdome[slot]
		switch kind {
		case .Builder:
			if KingdomHasTech(w, kingdom, .Carpentry) {
				rl.DrawRectangleRec(
					rl.Rectangle{offsetX+x-0.55, offsetY+y-0.45, 0.45, 0.18},
					rl.Color{132, 86, 52, 240},
				)
			}
		case .WaterCollector:
			if KingdomHasTech(w, kingdom, .Irrigation) {
				rl.DrawRectangleRec(
					rl.Rectangle{offsetX+x-0.08, offsetY+y-0.95, 0.16, 0.24},
					rl.Color{96, 178, 214, 220},
				)
			}
		case .CombatBuilder:
			if KingdomHasTech(w, kingdom, .Muster) {
				rl.DrawRectangleRec(
					rl.Rectangle{offsetX+x-0.05, offsetY+y-1.12, 0.1, 0.25},
					rl.Color{226, 96, 76, 230},
				)
			}
		case .Knight, .Archer, .Rogue:
			if KingdomHasTech(w, kingdom, .Armory) {
				rl.DrawRectangleRec(
					rl.Rectangle{offsetX+x-0.2, offsetY+y-0.9, 0.4, 0.28},
					rl.Color{154, 160, 172, 230},
				)
			}
			if KingdomHasTech(w, kingdom, .Drill) {
				rl.DrawRectangleRec(
					rl.Rectangle{offsetX+x-0.04, offsetY+y-1.12, 0.08, 0.24},
					rl.Color{224, 176, 70, 230},
				)
			}
		case .Catapult, .Giant, .Mage:
			if KingdomHasTech(w, kingdom, .Siegecraft) {
				rl.DrawCircleLines(
					i32(offsetX+x),
					i32(offsetY+y-1.0),
					0.26,
					rl.Color{226, 96, 76, 220},
				)
			}
		case .Villager, .Farmer, .Turtle, .Explorer:
		}
	}
}

WorldFloor :: proc(value: f32) -> int {
	result := int(value)
	if f32(result) > value do result -= 1
	return result
}

// Temporary terrain and poison clouds are drawn over the ground but under
// sprites so units stand in the water and beneath the gas.
WorldRenderHazards :: proc(w: ^World, renderer: ^WorldRenderer, camera: rl.Camera2D) {
	if renderer.sprites.iceTile[.Solid].id == 0 || renderer.sprites.floodTile[.Calm].id == 0 {
		return
	}
	halfWidth := f32(rl.GetScreenWidth())/(2*camera.zoom)
	halfHeight := f32(rl.GetScreenHeight())/(2*camera.zoom)
	worldWidth := f32(w.maxX)
	worldHeight := f32(w.maxY)

	for slot in 0..<HAZARD_CAPACITY {
		if !w.hazardUsed[slot] do continue
		x := w.hazardCells.x[slot]
		y := w.hazardCells.y[slot]
		if !FogTileExplored(w, x, y) do continue
		tileX := TileCenterRaw(x)
		tileY := TileCenterRaw(y)
		if abs(WorldShortestWrappedDelta(tileX-camera.target.x, worldWidth)) > halfWidth+1 ||
			abs(WorldShortestWrappedDelta(tileY-camera.target.y, worldHeight)) > halfHeight+1 {
			continue
		}

		texture: rl.Texture2D
		switch w.hazardCells.kind[slot] {
		case .Ice:
			stage := HazardIceStage(
				x,
				y,
				w.hazardCells.remaining[slot],
				w.hazardCells.duration[slot],
			)
			texture = renderer.sprites.iceTile[stage]
		case .Flood:
			frame := FloodFrame(int(w.simulationTime*2+f32(w.hazardCells.seed[slot]%3))%3)
			texture = renderer.sprites.floodTile[frame]
		case .None:
			continue
		}
		if texture.id == 0 do continue
		source := rl.Rectangle{0, 0, f32(texture.width), f32(texture.height)}
		rl.DrawTexturePro(
			texture,
			source,
			rl.Rectangle{f32(x), f32(y), 1, 1},
			rl.Vector2{0, 0},
			0,
			rl.WHITE,
		)
	}

	for cloud in 0..<GAS_CLOUD_CAPACITY {
		if !w.gasCloudUsed[cloud] do continue
		x := PositionToF32(w.gasClouds.x[cloud])
		y := PositionToF32(w.gasClouds.y[cloud])
		radius := PositionToF32(w.gasClouds.radius[cloud])
		if abs(WorldShortestWrappedDelta(x-camera.target.x, worldWidth)) > halfWidth+radius ||
			abs(WorldShortestWrappedDelta(y-camera.target.y, worldHeight)) > halfHeight+radius {
			continue
		}
		if !FogTileExplored(w, int(x), int(y)) do continue
		lifeRatio: f32 = 1
		if w.gasClouds.duration[cloud] > d32.ZERO {
			lifeRatio = clamp(
				PositionToF32(d32.Div(w.gasClouds.remaining[cloud], w.gasClouds.duration[cloud])),
				0,
				1,
			)
		}
		pulse := 0.75+0.25*math.sin(w.simulationTime*2.5+f32(cloud))
		rl.DrawCircleV(rl.Vector2{x, y}, radius, rl.Color{82, 166, 74, u8(10+16*lifeRatio)})
		rl.DrawCircleLines(
			i32(x),
			i32(y),
			radius,
			rl.Color{110, 194, 92, u8((24+36*lifeRatio)*pulse)},
		)
	}
}

// Aftermath scars tint and pulse the tiles that environmental events left
// behind, so regrowth and cooling read at a glance.
WorldRenderTerrainScars :: proc(w: ^World, camera: rl.Camera2D) {
	if len(w.scarTiles) == 0 do return
	worldHeight := int(w.maxY)
	if worldHeight <= 0 do return
	worldWidth := f32(w.maxX)
	worldHeightF := f32(w.maxY)
	halfWidth := f32(rl.GetScreenWidth())/(2*camera.zoom)
	halfHeight := f32(rl.GetScreenHeight())/(2*camera.zoom)
	time := w.simulationTime+w.simulationAccumulator

	for index in w.scarTiles {
		tileIndex := int(index)
		if tileIndex < 0 do continue
		x := tileIndex/worldHeight
		y := tileIndex%worldHeight
		if x < 0 || x >= int(w.maxX) do continue
		tile := w.ground[x][y]
		if tile.scar == .None do continue
		if !FogTileExplored(w, x, y) do continue
		tileX := TileCenterRaw(x)
		tileY := TileCenterRaw(y)
		if abs(WorldShortestWrappedDelta(tileX-camera.target.x, worldWidth)) > halfWidth+1 ||
			abs(WorldShortestWrappedDelta(tileY-camera.target.y, worldHeightF)) > halfHeight+1 {
			continue
		}

		color := TerrainScarOverlayColor(tile.scar)
		alpha: f32
		switch tile.scar {
		case .Scorched:
			alpha = 34
		case .Enriched:
			alpha = 16
		case .Parched:
			alpha = 26
		case .Frozen:
			alpha = 24
		case .Volcanic:
			alpha = 72
		case .Cleft:
			alpha = 22
		case .None:
			continue
		}
		fade := clamp(PositionToF32(tile.scarTimer)/18, 0, 1)
		pulse := 0.5+0.5*math.sin(time*4.5+f32(tileIndex%23))
		if tile.scar == .Volcanic {
			alpha += 38*pulse
		} else {
			alpha *= 0.35+0.65*fade
		}
		color.a = u8(clamp(alpha, 0, 255))
		rl.DrawRectangleRec(rl.Rectangle{f32(x), f32(y), 1, 1}, color)

		if tile.scar == .Volcanic {
			glow := rl.Color{255, 150, 70, u8(30+50*pulse)}
			rl.DrawRectangleLinesEx(rl.Rectangle{f32(x), f32(y), 1, 1}, 0.08, glow)
		}
	}
}
