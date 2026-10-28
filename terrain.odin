package main

import rl "vendor:raylib"
import "core:mem"
import "core:math"

TERRAIN_TILE_VARIANTS :: 8
TERRAIN_CHUNK_TILES :: 16
TERRAIN_CHUNK_PIXELS :: TERRAIN_CHUNK_TILES*PIXELS_PER_TILE
TERRAIN_CHUNK_CAPACITY :: 128
TERRAIN_CHUNK_GENERATION_BUDGET :: 8
TERRAIN_CHUNK_MIN_ZOOM : f32 : 8
TERRAIN_SEED :: u64(0x5EED_7E44_A1)

// Terrain properties live in one table so a new tile is a single entry plus
// art. Passability, fire, food and water are read by the simulation.
TileDef :: struct {
	name:        cstring,
	moveCost:    f32,
	wood:        f32,
	food:        f32,
	water:       f32,
	fireRisk:    f32,
	visionCover: f32,
	buildable:   bool,
	passable:    bool,
}

TILE_DEFS := [TileType]TileDef{
	.Ocean = {"Ocean", 1.00, 0.0, 0.00, 0.0, 0.00, 0.0, false, false},
	.Lake = {"Lake", 1.00, 0.0, 0.00, 1.0, 0.00, 0.0, false, false},
	.River = {"River", 1.00, 0.0, 0.00, 0.9, 0.00, 0.0, false, true},
	.Ice = {"Ice", 1.15, 0.0, 0.00, 0.4, 0.00, 0.0, false, true},
	.Marsh = {"Marsh", 1.60, 0.3, 0.30, 0.5, 0.35, 1.2, true, true},
	.Sand = {"Sand", 1.10, 0.0, 0.10, 0.0, 0.00, 0.0, true, true},
	.Grassland = {"Grassland", 1.00, 0.1, 0.60, 0.0, 0.70, 0.1, true, true},
	.Plains = {"Plains", 1.00, 0.1, 1.00, 0.0, 0.85, 0.0, true, true},
	.Forest = {"Forest", 1.35, 1.0, 0.40, 0.0, 1.00, 1.0, true, true},
	.Taiga = {"Taiga", 1.40, 0.8, 0.20, 0.0, 0.70, 0.9, true, true},
	.Steppe = {"Steppe", 0.95, 0.0, 0.45, 0.0, 1.10, 0.0, true, true},
	.Hill = {"Hill", 1.40, 0.2, 0.20, 0.0, 0.40, 0.5, true, true},
	.Mountain = {"Mountain", 1.00, 0.0, 0.00, 0.0, 0.00, 1.4, false, false},
	.Desert = {"Desert", 1.25, 0.0, 0.05, 0.0, 0.10, 0.0, true, true},
	.Tundra = {"Tundra", 1.30, 0.0, 0.10, 0.0, 0.20, 0.0, true, true},
	.Ash = {"Ash", 1.10, 0.0, 0.30, 0.0, 0.00, 0.0, true, true},
	.Lava = {"Lava", 1.00, 0.0, 0.00, 0.0, 0.00, 0.0, false, false},
}

TileIsWater :: proc(kind: TileType) -> bool {
	return kind == .Ocean || kind == .Lake || kind == .River
}

TileIsDeepWater :: proc(kind: TileType) -> bool {
	return kind == .Ocean || kind == .Lake
}

TerrainChunk :: struct {
	texture:  rl.Texture2D,
	chunkX, chunkY: int,
	lastUsed: u64,
}

TerrainRenderer :: struct {
	lowTexture: rl.Texture2D,
	revision:   u64,
	chunks:     [dynamic]TerrainChunk,
	tiles:      [TileType][TERRAIN_TILE_VARIANTS]rl.Image,
	clock:      u64,
	generated:  int,
}

TerrainRendererInit :: proc(w: ^World) -> TerrainRenderer {
	renderer := TerrainRenderer{
		lowTexture = WorldCreateTerrainTexture(w),
		revision = w.terrainRevision,
		chunks = make([dynamic]TerrainChunk, 0, TERRAIN_CHUNK_CAPACITY),
	}
	for kind in TileType {
		for variant in 0..<TERRAIN_TILE_VARIANTS {
			tile := DrawTerrainTile(kind, variant)
			renderer.tiles[kind][variant] = tile.image
		}
	}
	return renderer
}

TerrainRendererUpdate :: proc(w: ^World, renderer: ^TerrainRenderer) {
	if renderer.revision == w.terrainRevision do return

	rl.UnloadTexture(renderer.lowTexture)
	renderer.lowTexture = WorldCreateTerrainTexture(w)
	renderer.revision = w.terrainRevision
	TerrainChunksClear(renderer)
}

TerrainRendererDeinit :: proc(renderer: ^TerrainRenderer) {
	rl.UnloadTexture(renderer.lowTexture)
	TerrainChunksClear(renderer)
	delete(renderer.chunks)
	for kind in TileType {
		for variant in 0..<TERRAIN_TILE_VARIANTS {
			tile := renderer.tiles[kind][variant]
			if tile.data != nil do rl.UnloadImage(tile)
		}
	}
}

TerrainChunksClear :: proc(renderer: ^TerrainRenderer) {
	for &chunk in renderer.chunks {
		if chunk.texture.id != 0 do rl.UnloadTexture(chunk.texture)
	}
	clear(&renderer.chunks)
	renderer.clock = 0
}

TerrainRenderLow :: proc(renderer: ^TerrainRenderer, worldWidth, worldHeight: f32, firstCopyX, lastCopyX, firstCopyY, lastCopyY: int) {
	source := rl.Rectangle{0, 0, worldWidth, worldHeight}
	for copyX in firstCopyX ..< lastCopyX+1 {
		for copyY in firstCopyY ..< lastCopyY+1 {
			destination := rl.Rectangle{
				x = f32(copyX)*worldWidth,
				y = f32(copyY)*worldHeight,
				width = worldWidth,
				height = worldHeight,
			}
			rl.DrawTexturePro(renderer.lowTexture, source, destination, rl.Vector2{0, 0}, 0, rl.WHITE)
		}
	}
}

TerrainRenderChunks :: proc(w: ^World, renderer: ^TerrainRenderer, camera: rl.Camera2D, firstCopyX, lastCopyX, firstCopyY, lastCopyY: int) {
	worldWidth := f32(w.maxX)
	worldHeight := f32(w.maxY)
	chunkCountX := (int(w.maxX)+TERRAIN_CHUNK_TILES-1)/TERRAIN_CHUNK_TILES
	chunkCountY := (int(w.maxY)+TERRAIN_CHUNK_TILES-1)/TERRAIN_CHUNK_TILES
	if chunkCountX <= 0 || chunkCountY <= 0 do return
	renderer.generated = 0
	// Base layer: chunks that are still being generated fall back to the flat map.
	TerrainRenderLow(
		renderer,
		worldWidth,
		worldHeight,
		firstCopyX,
		lastCopyX,
		firstCopyY,
		lastCopyY,
	)

	halfViewWidth := f32(rl.GetScreenWidth())/(2*camera.zoom)
	halfViewHeight := f32(rl.GetScreenHeight())/(2*camera.zoom)
	viewMinX := camera.target.x-halfViewWidth
	viewMaxX := camera.target.x+halfViewWidth
	viewMinY := camera.target.y-halfViewHeight
	viewMaxY := camera.target.y+halfViewHeight
	source := rl.Rectangle{0, 0, TERRAIN_CHUNK_PIXELS, TERRAIN_CHUNK_PIXELS}

	for copyX in firstCopyX ..< lastCopyX+1 {
		offsetX := f32(copyX)*worldWidth
		firstChunkX := WorldFloor((viewMinX-offsetX)/f32(TERRAIN_CHUNK_TILES))
		lastChunkX := WorldFloor((viewMaxX-offsetX)/f32(TERRAIN_CHUNK_TILES))
		for copyY in firstCopyY ..< lastCopyY+1 {
			offsetY := f32(copyY)*worldHeight
			firstChunkY := WorldFloor((viewMinY-offsetY)/f32(TERRAIN_CHUNK_TILES))
			lastChunkY := WorldFloor((viewMaxY-offsetY)/f32(TERRAIN_CHUNK_TILES))
			for chunkY in firstChunkY ..= lastChunkY {
				for chunkX in firstChunkX ..= lastChunkX {
					texture, ready := TerrainEnsureChunk(
						w,
						renderer,
						WorldWrapCoordinate(chunkX, chunkCountX),
						WorldWrapCoordinate(chunkY, chunkCountY),
					)
					if !ready do continue
					destination := rl.Rectangle{
						x = offsetX+f32(chunkX*TERRAIN_CHUNK_TILES),
						y = offsetY+f32(chunkY*TERRAIN_CHUNK_TILES),
						width = TERRAIN_CHUNK_TILES,
						height = TERRAIN_CHUNK_TILES,
					}
					rl.DrawTexturePro(texture, source, destination, rl.Vector2{0, 0}, 0, rl.WHITE)
				}
			}
		}
	}
}

TerrainEnsureChunk :: proc(w: ^World, renderer: ^TerrainRenderer, chunkX, chunkY: int) -> (rl.Texture2D, bool) {
	renderer.clock += 1
	for &chunk in renderer.chunks {
		if chunk.chunkX == chunkX && chunk.chunkY == chunkY {
			chunk.lastUsed = renderer.clock
			return chunk.texture, true
		}
	}
	if renderer.generated >= TERRAIN_CHUNK_GENERATION_BUDGET do return {}, false
	renderer.generated += 1

	texture := TerrainCreateChunkTexture(w, renderer, chunkX, chunkY)
	if len(renderer.chunks) >= TERRAIN_CHUNK_CAPACITY {
		oldest := 0
		for chunk, index in renderer.chunks {
			if chunk.lastUsed < renderer.chunks[oldest].lastUsed do oldest = index
		}
		rl.UnloadTexture(renderer.chunks[oldest].texture)
		renderer.chunks[oldest] = TerrainChunk{
			texture = texture,
			chunkX = chunkX,
			chunkY = chunkY,
			lastUsed = renderer.clock,
		}
		return texture, true
	}

	append(&renderer.chunks, TerrainChunk{
		texture = texture,
		chunkX = chunkX,
		chunkY = chunkY,
		lastUsed = renderer.clock,
	})
	return texture, true
}

TerrainCreateChunkTexture :: proc(w: ^World, renderer: ^TerrainRenderer, chunkX, chunkY: int) -> rl.Texture2D {
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	image := rl.GenImageColor(TERRAIN_CHUNK_PIXELS, TERRAIN_CHUNK_PIXELS, rl.BLACK)
	defer rl.UnloadImage(image)
	dst := cast([^]u8)image.data
	rowBytes := PIXELS_PER_TILE*4

	for tileY in 0..<TERRAIN_CHUNK_TILES {
		for tileX in 0..<TERRAIN_CHUNK_TILES {
			worldX := min(chunkX*TERRAIN_CHUNK_TILES+tileX, worldWidth-1)
			worldY := min(chunkY*TERRAIN_CHUNK_TILES+tileY, worldHeight-1)
			kind := w.ground[worldX][worldY].type
			variant := int(WorldNoiseHash(worldX, worldY, TERRAIN_SEED)*TERRAIN_TILE_VARIANTS)
			if variant >= TERRAIN_TILE_VARIANTS do variant = TERRAIN_TILE_VARIANTS-1
			tileImage := renderer.tiles[kind][variant]
			src := cast([^]u8)tileImage.data
			pixelX := tileX*PIXELS_PER_TILE
			pixelY := tileY*PIXELS_PER_TILE
			for row in 0..<PIXELS_PER_TILE {
				offset := ((pixelY+row)*TERRAIN_CHUNK_PIXELS+pixelX)*4
				mem.copy(rawptr(&dst[offset]), rawptr(&src[row*rowBytes]), rowBytes)
			}
			TerrainDitherTileEdges(dst, w, worldX, worldY, pixelX, pixelY)
		}
	}

	texture := rl.LoadTextureFromImage(image)
	rl.SetTextureFilter(texture, .POINT)
	return texture
}

// Softens the hard tile boundary by speckling the neighbour's ground colour into
// this tile, so grass/sand/water transitions read organically instead of as a
// 16-pixel staircase.
TerrainDitherTileEdges :: proc(dst: [^]u8, w: ^World, worldX, worldY, pixelX, pixelY: int) {
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	kind := w.ground[worldX][worldY].type
	neighbourOffsets := [4][2]int{{0, -1}, {1, 0}, {0, 1}, {-1, 0}}

	for offset, side in neighbourOffsets {
		neighbourX := WorldWrapCoordinate(worldX+offset[0], worldWidth)
		neighbourY := WorldWrapCoordinate(worldY+offset[1], worldHeight)
		neighbourKind := w.ground[neighbourX][neighbourY].type
		if neighbourKind == kind do continue

		color := WorldTileColor(neighbourKind)
		for along in 0..<PIXELS_PER_TILE {
			for depth in 0..<2 {
				if WorldNoiseHash(
					worldX*PIXELS_PER_TILE+along,
					worldY*PIXELS_PER_TILE+depth+side*PIXELS_PER_TILE,
					TERRAIN_SEED+7,
				) > 0.5-f32(depth)*0.25 {
					continue
				}

				px, py: int
				switch side {
				case 0:
					px = pixelX+along
					py = pixelY+depth
				case 1:
					px = pixelX+PIXELS_PER_TILE-1-depth
					py = pixelY+along
				case 2:
					px = pixelX+along
					py = pixelY+PIXELS_PER_TILE-1-depth
				case 3:
					px = pixelX+depth
					py = pixelY+along
				}
				index := (py*TERRAIN_CHUNK_PIXELS+px)*4
				dst[index+0] = color[0]
				dst[index+1] = color[1]
				dst[index+2] = color[2]
				dst[index+3] = color[3]
			}
		}
	}
}

WorldTileColor :: proc(tileType: TileType) -> rl.Color {
	switch tileType {
	case .Ocean:
		return rl.Color{38, 72, 104, 255}
	case .Lake:
		return rl.Color{64, 124, 148, 255}
	case .River:
		return rl.Color{78, 133, 155, 255}
	case .Ice:
		return rl.Color{196, 224, 238, 255}
	case .Marsh:
		return rl.Color{74, 104, 76, 255}
	case .Sand:
		return rl.Color{215, 194, 140, 255}
	case .Grassland:
		return rl.Color{100, 128, 88, 255}
	case .Plains:
		return rl.Color{126, 151, 88, 255}
	case .Forest:
		return rl.Color{52, 100, 66, 255}
	case .Taiga:
		return rl.Color{42, 76, 64, 255}
	case .Steppe:
		return rl.Color{146, 152, 92, 255}
	case .Hill:
		return rl.Color{126, 131, 110, 255}
	case .Mountain:
		return rl.Color{104, 106, 110, 255}
	case .Desert:
		return rl.Color{191, 154, 95, 255}
	case .Tundra:
		return rl.Color{142, 150, 142, 255}
	case .Ash:
		return rl.Color{86, 80, 78, 255}
	case .Lava:
		return rl.Color{196, 78, 48, 255}
	}
	unreachable()
}

WorldCreateTerrainTexture :: proc(w: ^World) -> rl.Texture2D {
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	image := rl.GenImageColor(i32(worldWidth), i32(worldHeight), rl.BLACK)
	defer rl.UnloadImage(image)

	for x in 0..<worldWidth {
		for y in 0..<worldHeight {
			rl.ImageDrawPixel(&image, i32(x), i32(y), WorldTileColor(w.ground[x][y].type))
		}
	}

	texture := rl.LoadTextureFromImage(image)
	rl.SetTextureFilter(texture, .POINT)
	return texture
}

DrawTerrainTile :: proc(kind: TileType, variant: int) -> Art {
	art := ArtInit(PIXELS_PER_TILE, PIXELS_PER_TILE)
	base := WorldTileColor(kind)
	light := CShade(base, 1.06)
	highlight := CShade(base, 1.11)
	soft := CShade(base, 0.96)
	dark := CShade(base, 0.9)
	ArtRect(&art, 0, 0, PIXELS_PER_TILE, PIXELS_PER_TILE, base)
	seed := TERRAIN_SEED+u64(variant)*7919+u64(kind)*1319

	switch kind {
	case .Ocean, .Lake, .River:
		wave := CShade(base, 1.11)
		for i in 0..<2 {
			x := int(WorldNoiseHash(i, variant, seed)*13)
			y := int(WorldNoiseHash(variant, i, seed+1)*15)
			length := 2+int(WorldNoiseHash(i, variant, seed+2)*3)
			ArtRect(&art, x, y, length, 1, wave)
			ArtPixel(&art, x+1, y+1, soft)
		}
		ArtPixel(
			&art,
			int(WorldNoiseHash(variant, 3, seed)*PIXELS_PER_TILE),
			int(WorldNoiseHash(3, variant, seed+1)*PIXELS_PER_TILE),
			soft,
		)

	case .Ice:
		crack := CShade(base, 1.18)
		ArtLine(&art, 2, 3, 7, 8, crack)
		ArtLine(&art, 7, 8, 12, 6, crack)
		ArtLine(&art, 9, 1, 12, 5, highlight)
		ArtPixel(&art, 4, 12, crack)
		ArtPixel(&art, 11, 11, highlight)

	case .Marsh:
		TerrainSpeckles(&art, variant, seed, light, dark)
		for i in 0..<3 {
			x := int(WorldNoiseHash(i+21, variant, seed)*12)
			y := 2+int(WorldNoiseHash(variant, i+21, seed+1)*12)
			ArtRect(&art, x, y, 3, 1, highlight)
			ArtPixel(&art, x, y+1, dark)
		}

	case .Sand:
		TerrainSpeckles(&art, variant, seed, light, soft)
		for i in 0..<2 {
			x := int(WorldNoiseHash(i+51, variant, seed)*13)
			y := int(WorldNoiseHash(variant, i+51, seed+1)*15)
			ArtRect(&art, x, y, 2, 1, soft)
		}

	case .Grassland:
		TerrainSpeckles(&art, variant, seed, light, dark)
		for i in 0..<3 {
			x := int(WorldNoiseHash(i+31, variant, seed)*15)
			y := int(WorldNoiseHash(variant, i+31, seed+1)*14)
			ArtRect(&art, x, y, 1, 2, light)
		}

	case .Plains:
		TerrainSpeckles(&art, variant, seed, light, dark)
		for i in 0..<4 {
			x := 1+int(WorldNoiseHash(i+41, variant, seed)*13)
			y := 1+int(WorldNoiseHash(variant, i+41, seed+1)*13)
			ArtRect(&art, x, y, 1, 2, highlight)
		}

	case .Forest:
		for i in 0..<4 {
			cx := 2+int(WorldNoiseHash(i+61, variant, seed)*12)
			cy := 2+int(WorldNoiseHash(variant, i+61, seed+1)*12)
			radius := 1+int(WorldNoiseHash(i, i+variant, seed+2)*3)
			ArtCircle(&art, cx, cy, radius, light)
			ArtPixel(&art, cx, cy, highlight)
			ArtPixel(&art, cx+radius, cy+1, dark)
		}
		TerrainSpeckles(&art, variant, seed, light, dark)

	case .Taiga:
		for i in 0..<5 {
			cx := 2+int(WorldNoiseHash(i+63, variant, seed)*12)
			cy := 3+int(WorldNoiseHash(variant, i+63, seed+1)*10)
			ArtRect(&art, cx, cy, 1, 3, dark)
			ArtRect(&art, cx-1, cy, 3, 1, light)
			ArtRect(&art, cx-2, cy+1, 5, 1, light)
			ArtPixel(&art, cx, cy-1, highlight)
		}
		TerrainSpeckles(&art, variant, seed, light, dark)

	case .Steppe:
		TerrainSpeckles(&art, variant, seed, light, soft)
		for i in 0..<3 {
			x := int(WorldNoiseHash(i+83, variant, seed)*10)
			y := 2+int(WorldNoiseHash(variant, i+83, seed+1)*12)
			ArtRect(&art, x, y, 3, 1, light)
			ArtPixel(&art, x+3, y-1, soft)
		}

	case .Hill:
		TerrainSpeckles(&art, variant, seed, light, dark)
		for i in 0..<2 {
			x := 1+int(WorldNoiseHash(i+71, variant, seed)*12)
			y := 1+int(WorldNoiseHash(variant, i+71, seed+1)*13)
			ArtRect(&art, x, y, 3, 2, light)
			ArtRect(&art, x, y+2, 3, 1, dark)
			ArtPixel(&art, x+1, y, highlight)
		}

	case .Mountain:
		TerrainSpeckles(&art, variant, seed, light, dark)
		for i in 0..<2 {
			x := 1+int(WorldNoiseHash(i+91, variant, seed)*10)
			y := 2+int(WorldNoiseHash(variant, i+91, seed+1)*9)
			ArtRect(&art, x, y, 4, 4, light)
			ArtRect(&art, x+1, y+4, 3, 1, dark)
			ArtPixel(&art, x+1, y, highlight)
			ArtPixel(&art, x+2, y, highlight)
			ArtPixel(&art, x+1, y+3, soft)
		}

	case .Desert:
		TerrainSpeckles(&art, variant, seed, light, soft)
		for i in 0..<2 {
			x := int(WorldNoiseHash(i+81, variant, seed)*13)
			y := 2+int(WorldNoiseHash(variant, i+81, seed+1)*12)
			ArtPixel(&art, x, y, light)
			ArtPixel(&art, x+2, y+1, soft)
		}

	case .Tundra:
		TerrainSpeckles(&art, variant, seed, light, dark)
		for i in 0..<3 {
			x := int(WorldNoiseHash(i+93, variant, seed)*13)
			y := int(WorldNoiseHash(variant, i+93, seed+1)*13)
			ArtPixel(&art, x, y, highlight)
			ArtPixel(&art, x+1, y+1, dark)
		}

	case .Ash:
		TerrainSpeckles(&art, variant, seed, light, dark)
		for i in 0..<2 {
			x := int(WorldNoiseHash(i+95, variant, seed)*13)
			y := int(WorldNoiseHash(variant, i+95, seed+1)*13)
			ArtPixel(&art, x, y, rl.Color{196, 112, 58, 170})
		}
		ArtRect(&art, 3, 11, 4, 1, dark)

	case .Lava:
		vein := CShade(base, 1.55)
		ArtLine(&art, 0, 5, 7, 8, vein)
		ArtLine(&art, 7, 8, 13, 4, vein)
		ArtLine(&art, 4, 0, 8, 7, highlight)
		ArtPixel(&art, 10, 12, vein)
		ArtPixel(&art, 2, 13, highlight)
	}
	return art
}

TerrainSpeckles :: proc(art: ^Art, variant: int, seed: u64, light, dark: rl.Color) {
	for i in 0..<9 {
		x := int(WorldNoiseHash(i, variant, seed)*PIXELS_PER_TILE)
		y := int(WorldNoiseHash(variant, i, seed+1)*PIXELS_PER_TILE)
		color := light
		if WorldNoiseHash(x, y, seed+2) < 0.55 do color = dark
		ArtPixel(art, x, y, color)
	}
}

// --- temporary terrain ----------------------------------------------------

// Ice and flood live outside the ground grid so the original biome is restored
// when the effect ends. hazardTile maps a tile to its cell for O(1) lookups.
HAZARD_CAPACITY :: 4096
FLOOD_DROWN_DAMAGE_PER_SECOND :: 8.0

IceStage :: enum {
	Solid,
	Cracked,
	Patchy,
	Slush,
}

HazardKind :: enum {
	None,
	Ice,
	Flood,
}

HazardCell :: struct {
	x, y:      int,
	kind:      HazardKind,
	remaining: f32,
	duration:  f32,
	seed:      u64,
	stage:     IceStage,
}

HazardIceStage :: proc(x, y: int, remaining, duration: f32) -> IceStage {
	ratio: f32 = 1
	if duration > 0 do ratio = remaining/duration
	adjusted := ratio+(WorldNoiseHash(x, y, 0x1CE5)-0.5)*0.18
	stage := IceStage.Solid
	if adjusted < 0.65 do stage = .Cracked
	if adjusted < 0.4 do stage = .Patchy
	if adjusted < 0.18 do stage = .Slush
	return stage
}

WorldHazardSlotAt :: proc(w: ^World, x, y: int) -> int {
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 || len(w.hazardTile) == 0 do return -1
	wrappedX := WorldWrapCoordinate(x, worldWidth)
	wrappedY := WorldWrapCoordinate(y, worldHeight)
	return int(w.hazardTile[wrappedX*worldHeight+wrappedY])
}

WorldHazardKindAt :: proc(w: ^World, x, y: int) -> (HazardKind, bool) {
	slot := WorldHazardSlotAt(w, x, y)
	if slot < 0 || slot >= HAZARD_CAPACITY || !w.hazardUsed[slot] do return .None, false
	return w.hazardCells.kind[slot], true
}

@(private = "file")
WorldHazardSpawnCell :: proc(
	w: ^World,
	tileX, tileY: int,
	kind: HazardKind,
	duration: f32,
	seed: u64,
) -> int {
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 || len(w.hazardTile) == 0 do return -1
	wrappedX := WorldWrapCoordinate(tileX, worldWidth)
	wrappedY := WorldWrapCoordinate(tileY, worldHeight)
	index := wrappedX*worldHeight+wrappedY
	if w.hazardTile[index] >= 0 do return -1

	slot := -1
	for step in 0..<HAZARD_CAPACITY {
		candidate := (w.hazardCursor+step)%HAZARD_CAPACITY
		if !w.hazardUsed[candidate] {
			slot = candidate
			break
		}
	}
	if slot < 0 do return -1

	w.hazardCells.x[slot] = wrappedX
	w.hazardCells.y[slot] = wrappedY
	w.hazardCells.kind[slot] = kind
	w.hazardCells.remaining[slot] = duration
	w.hazardCells.duration[slot] = duration
	w.hazardCells.seed[slot] = seed
	w.hazardCells.stage[slot] = .Solid
	w.hazardUsed[slot] = true
	w.hazardCursor = (slot+1)%HAZARD_CAPACITY
	w.hazardTile[index] = i32(slot)
	return slot
}

@(private = "file")
WorldHazardDespawn :: proc(w: ^World, slot: int) {
	if slot < 0 || slot >= HAZARD_CAPACITY || !w.hazardUsed[slot] do return
	x := w.hazardCells.x[slot]
	y := w.hazardCells.y[slot]
	worldHeight := int(w.maxY)
	index := x*worldHeight+y
	if index >= 0 && index < len(w.hazardTile) && int(w.hazardTile[index]) == slot {
		w.hazardTile[index] = -1
	}

	if w.hazardCells.kind[slot] == .Ice {
		for _ in 0..<2 {
			ParticleSpawn(w, Particle{
				x = f32(x)+PRandom(w),
				y = f32(y)+PRandom(w),
				z = 0.1,
				vx = (PRandom(w)-0.5)*0.5,
				vy = (PRandom(w)-0.5)*0.5,
				vz = PRandomRange(w, 0.4, 1.1),
				life = PRandomRange(w, 0.3, 0.7),
				size = PRandomRange(w, 0.08, 0.16),
				drag = 2,
				gravity = 3,
				kind = .Spark,
				tint = rl.Color{208, 242, 255, 255},
			})
		}
	} else if w.hazardCells.kind[slot] == .Flood {
		ParticleSpawn(w, Particle{
			x = f32(x)+PRandom(w),
			y = f32(y)+PRandom(w),
			z = 0.1,
			vx = (PRandom(w)-0.5)*0.6,
			vy = (PRandom(w)-0.5)*0.6,
			vz = PRandomRange(w, 0.4, 1.4),
			life = PRandomRange(w, 0.3, 0.8),
			size = PRandomRange(w, 0.10, 0.22),
			drag = 1.5,
			gravity = 5,
			kind = .Splash,
			tint = rl.Color{196, 226, 240, 255},
		})
	}
	w.hazardUsed[slot] = false
}

WorldHazardSpawnCircle :: proc(
	w: ^World,
	centerX, centerY, radius: f32,
	kind: HazardKind,
	minDuration, maxDuration: f32,
	salt: u64,
) {
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 || radius <= 0 do return
	tileCenterX := int(WorldWrapPosition(centerX, f32(worldWidth)))
	tileCenterY := int(WorldWrapPosition(centerY, f32(worldHeight)))
	reach := int(math.ceil(radius))
	spawned := 0
	for offsetX in -reach..=reach {
		for offsetY in -reach..=reach {
			if f32(offsetX*offsetX+offsetY*offsetY) > radius*radius do continue
			tileX := WorldWrapCoordinate(tileCenterX+offsetX, worldWidth)
			tileY := WorldWrapCoordinate(tileCenterY+offsetY, worldHeight)
			index := tileX*worldHeight+tileY

			if slot := w.tileBuilding[index]; slot >= 0 && slot < BUILDING_CAPACITY && w.buildingUsed[slot] {
				continue
			}
			if kind == .Flood {
				tile := w.ground[tileX][tileY].type
				if TileIsWater(tile) || tile == .Ice do continue
				WorldFireExtinguishAt(w, tileX, tileY)
			}

			roll := WorldNoiseHash(tileX, tileY, salt)
			duration := minDuration+roll*(maxDuration-minDuration)
			if WorldHazardSpawnCell(w, tileX, tileY, kind, duration, salt+u64(tileX*31+tileY)) >= 0 {
				spawned += 1
			}
		}
	}
	if spawned == 0 do return

	w.navigationRevision += 1
	for _ in 0..<10 {
		angle := PRandom(w)*6.2831853
		distance := radius*math.sqrt(PRandom(w))*0.8
		x := centerX+math.cos(angle)*distance
		y := centerY+math.sin(angle)*distance
		if kind == .Flood {
			ParticleSpawn(w, Particle{
				x = x,
				y = y,
				z = 0.15,
				vx = math.cos(angle)*PRandomRange(w, 0.4, 1.4),
				vy = math.sin(angle)*PRandomRange(w, 0.4, 1.4),
				vz = PRandomRange(w, 0.6, 2.0),
				life = PRandomRange(w, 0.4, 0.9),
				size = PRandomRange(w, 0.10, 0.24),
				drag = 1.6,
				gravity = 6,
				kind = .Splash,
				tint = rl.Color{196, 226, 240, 255},
			})
		} else {
			ParticleSpawn(w, Particle{
				x = x,
				y = y,
				z = PRandomRange(w, 0.2, 0.8),
				vx = math.cos(angle)*PRandomRange(w, 0.2, 1.0),
				vy = math.sin(angle)*PRandomRange(w, 0.2, 1.0),
				vz = PRandomRange(w, 0.3, 1.3),
				life = PRandomRange(w, 0.4, 1.1),
				size = PRandomRange(w, 0.08, 0.18),
				drag = 1.5,
				gravity = 1.5,
				kind = .Spark,
				tint = rl.Color{208, 242, 255, 255},
			})
			if WorldNoiseHash(int(x), int(y), salt+9) < 0.5 {
				ParticleSpawn(w, Particle{
					x = x,
					y = y,
					z = PRandomRange(w, 0.2, 0.8),
					vx = (PRandom(w)-0.5)*0.3,
					vy = (PRandom(w)-0.5)*0.3,
					vz = PRandomRange(w, 0.2, 0.7),
					life = PRandomRange(w, 0.7, 1.4),
					size = PRandomRange(w, 0.28, 0.5),
					drag = 1.4,
					gravity = -0.2,
					kind = .Dust,
					tint = rl.Color{188, 230, 248, 175},
				})
			}
		}
	}
}

WorldHazardUpdate :: proc(w: ^World, deltaTime: f32) {
	changed := false
	for slot in 0..<HAZARD_CAPACITY {
		if !w.hazardUsed[slot] do continue
		w.hazardCells.remaining[slot] -= deltaTime
		if w.hazardCells.remaining[slot] <= 0 {
			WorldHazardDespawn(w, slot)
			changed = true
			continue
		}

		tileX := w.hazardCells.x[slot]
		tileY := w.hazardCells.y[slot]
		if w.hazardCells.kind[slot] == .Ice {
			stage := HazardIceStage(
				tileX,
				tileY,
				w.hazardCells.remaining[slot],
				w.hazardCells.duration[slot],
			)
			if stage != w.hazardCells.stage[slot] {
				w.hazardCells.stage[slot] = stage
				ParticleSpawn(w, Particle{
					x = f32(tileX)+PRandom(w),
					y = f32(tileY)+PRandom(w),
					z = 0.2,
					vx = (PRandom(w)-0.5)*0.8,
					vy = (PRandom(w)-0.5)*0.8,
					vz = PRandomRange(w, 0.6, 1.6),
					life = PRandomRange(w, 0.4, 0.9),
					size = PRandomRange(w, 0.07, 0.13),
					drag = 0.8,
					gravity = 18,
					bounce = 0.2,
					kind = .StoneChip,
					tint = rl.Color{214, 244, 255, 255},
				})
				for _ in 0..<2 {
					ParticleSpawn(w, Particle{
						x = f32(tileX)+PRandom(w),
						y = f32(tileY)+PRandom(w),
						z = 0.15,
						vx = (PRandom(w)-0.5)*0.7,
						vy = (PRandom(w)-0.5)*0.7,
						vz = PRandomRange(w, 0.4, 1.2),
						life = PRandomRange(w, 0.3, 0.7),
						size = PRandomRange(w, 0.07, 0.15),
						drag = 2,
						gravity = 4,
						kind = .Spark,
						tint = rl.Color{202, 238, 255, 255},
					})
				}
			}
		} else if WorldNoiseHash(slot, int(w.simulationTime*6), 0xA31D) < 0.05 {
			ParticleSpawn(w, Particle{
				x = f32(tileX)+PRandom(w),
				y = f32(tileY)+PRandom(w),
				z = 0.05,
				vx = 0,
				vy = 0,
				vz = PRandomRange(w, 0.2, 0.5),
				life = PRandomRange(w, 0.25, 0.5),
				size = PRandomRange(w, 0.08, 0.16),
				drag = 1,
				gravity = 3,
				kind = .Splash,
				tint = rl.Color{196, 226, 240, 255},
			})
		}
	}
	if changed do w.navigationRevision += 1

	for unitSlot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[unitSlot] || w.units.type[unitSlot] == nil do continue
		if UnitHiddenInside(w, unitSlot) do continue
		unitType := w.units.type[unitSlot]
		kingdom := w.units.kingdome[unitSlot]
		if UnitCanCrossWater(w, unitType, kingdom) do continue
		tileX := int(WorldWrapPosition(w.units.x[unitSlot], f32(w.maxX)))
		tileY := int(WorldWrapPosition(w.units.y[unitSlot], f32(w.maxY)))
		tileIndex := tileX*int(w.maxY)+tileY
		if slot := w.tileBuilding[tileIndex]; slot >= 0 && w.buildingUsed[slot] do continue
		hazardKind, hasHazard := WorldHazardKindAt(w, tileX, tileY)
		if hasHazard && hazardKind == .Ice do continue
		drowning := hasHazard && hazardKind == .Flood
		if !hasHazard {
			tile := w.ground[tileX][tileY].type
			drowning = TileIsDeepWater(tile)
		}
		if drowning {
			UnitApplyDamage(
				w,
				unitSlot,
				FLOOD_DROWN_DAMAGE_PER_SECOND*deltaTime,
				w.units.x[unitSlot],
				w.units.y[unitSlot],
				.Drowning,
			)
		}
	}
}
