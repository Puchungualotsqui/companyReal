package main

import rl "vendor:raylib"
import "core:math"
import "core:slice"

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
	fogPixels:  []u8,
	fogRevision: u64,
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

WorldView :: struct {
	renderer:         WorldRenderer,
	camera:           rl.Camera2D,
	ui:               UIState,
	milestoneCamera: MilestoneCamera,
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
	WorldRendererUpdate(w, &view.renderer)
	WorldCameraUpdate(w, &view.camera, deltaTime)
	WorldMilestoneCameraUpdate(w, view, deltaTime)
	WorldUIUpdate(w, view, view.camera)
}


WorldRendererUpdate :: proc(w: ^World, renderer: ^WorldRenderer) {
	TerrainRendererUpdate(w, &renderer.terrain)
	BloodRenderUpdate(w, renderer)
	FogRenderUpdate(w, renderer)
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
	BloodRenderGround(
		w,
		renderer,
		camera,
		firstCopyX,
		lastCopyX,
		firstCopyY,
		lastCopyY,
	)
	WorldRenderSprites(
		w,
		renderer,
		camera,
		firstCopyX,
		lastCopyX,
		firstCopyY,
		lastCopyY,
	)
	FogRenderDraw(w, renderer, firstCopyX, lastCopyX, firstCopyY, lastCopyY)
	rl.EndMode2D()

	ambient := WorldAmbientColor(w)
	if ambient[0] < 255 || ambient[1] < 255 || ambient[2] < 255 {
		rl.BeginBlendMode(.MULTIPLIED)
		rl.DrawRectangle(0, 0, rl.GetScreenWidth(), rl.GetScreenHeight(), ambient)
		rl.EndBlendMode()
	}

	night := WorldNightAmount(w)
	if night > 0.02 && renderer.sprites.glow.id != 0 && len(renderer.lights) > 0 {
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

// Decorations are only a pixel or two tall below this zoom, so drawing them
// would cost more than it adds.
DECORATION_MIN_ZOOM : f32 : 4

// Position used for drawing and picking, interpolated between simulation ticks.
UnitRenderPosition :: proc(w: ^World, unitSlot: int) -> (x, y: f32) {
	x = w.units.x[unitSlot]
	y = w.units.y[unitSlot]
	alpha := clamp(w.simulationAccumulator/TOWN_SIMULATION_STEP, 0, 1)
	if alpha <= 0 do return
	worldWidth := f32(w.maxX)
	worldHeight := f32(w.maxY)
	x = WorldWrapPosition(
		w.units.previousX[unitSlot]+
		WorldShortestWrappedDelta(w.units.x[unitSlot]-w.units.previousX[unitSlot], worldWidth)*
			alpha,
		worldWidth,
	)
	y = WorldWrapPosition(
		w.units.previousY[unitSlot]+
		WorldShortestWrappedDelta(w.units.y[unitSlot]-w.units.previousY[unitSlot], worldHeight)*
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
				append(&renderer.items, RenderItem{
					baseY = baseY,
					dest = rl.Rectangle{offsetX+buildingX, offsetY+buildingY, width, height},
					texture = renderer.sprites.building[faction][kind],
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
							decorationX := w.decorations.x[decorationSlot]
							decorationY := w.decorations.y[decorationSlot]
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

			for unitSlot in 0 ..< UNIT_CAPACITY {
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

				bob: f32 = 0
				switch state in w.units[unitSlot].state {
				case StatePacific:
					if state != .Sleeping && !(kind == .WaterCollector && state == .Working) {
						bob = math.sin(f32(unitSlot)*1.7+bobTime*2.4)*0.03
					}
				case StateWarrior, StateConverting:
					bob = math.sin(f32(unitSlot)*1.7+bobTime*2.4)*0.03
				}

				faction := FactionSpriteIndex(w.units[unitSlot].kingdome)
				flipX := false
				if w.units[unitSlot].pathReady {
					deltaX := WorldShortestWrappedDelta(
						f32(w.units[unitSlot].pathTargetX)+0.5-unitX,
						f32(w.maxX),
					)
					flipX = deltaX < -0.5
				}
				append(&renderer.items, RenderItem{
					baseY = unitY+0.5,
					dest = rl.Rectangle{
						x = offsetX+unitX-scale*0.5,
						y = offsetY+unitY+0.5-scale+bob-jump,
						width = scale,
						height = scale,
					},
					texture = renderer.sprites.unit[faction][kind],
					flipX = flipX,
				})
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
					for fireSlot in 0 ..< FIRE_CAPACITY {
						if !w.fireUsed[fireSlot] do continue
						fireX := w.fires.x[fireSlot]
						fireY := w.fires.y[fireSlot]
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

WorldFloor :: proc(value: f32) -> int {
	result := int(value)
	if f32(result) > value do result -= 1
	return result
}
