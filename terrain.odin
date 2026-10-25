package main

import rl "vendor:raylib"
import "core:mem"

TERRAIN_TILE_VARIANTS :: 8
TERRAIN_CHUNK_TILES :: 16
TERRAIN_CHUNK_PIXELS :: TERRAIN_CHUNK_TILES*PIXELS_PER_TILE
TERRAIN_CHUNK_CAPACITY :: 128
TERRAIN_CHUNK_GENERATION_BUDGET :: 8
TERRAIN_CHUNK_MIN_ZOOM : f32 : 8
TERRAIN_SEED :: u64(0x5EED_7E44_A1)

ALL_TILE_TYPES := [9]TileType{
	.Water,
	.FreshWater,
	.River,
	.Ground,
	.FertileGround,
	.Sand,
	.Forest,
	.Hill,
	.Desert,
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
	for kind in ALL_TILE_TYPES {
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
	for kind in ALL_TILE_TYPES {
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
	case .Water:
		return rl.Color{48, 83, 112, 255}
	case .FreshWater:
		return rl.Color{69, 130, 153, 255}
	case .River:
		return rl.Color{78, 133, 155, 255}
	case .Ground:
		return rl.Color{100, 128, 88, 255}
	case .FertileGround:
		return rl.Color{126, 151, 88, 255}
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
	case .Water, .FreshWater, .River:
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

	case .Ground:
		TerrainSpeckles(&art, variant, seed, light, dark)
		for i in 0..<3 {
			x := int(WorldNoiseHash(i+31, variant, seed)*15)
			y := int(WorldNoiseHash(variant, i+31, seed+1)*14)
			ArtRect(&art, x, y, 1, 2, light)
		}

	case .FertileGround:
		TerrainSpeckles(&art, variant, seed, light, dark)
		for i in 0..<4 {
			x := 1+int(WorldNoiseHash(i+41, variant, seed)*13)
			y := 1+int(WorldNoiseHash(variant, i+41, seed+1)*13)
			ArtRect(&art, x, y, 1, 2, highlight)
		}

	case .Sand:
		TerrainSpeckles(&art, variant, seed, light, soft)
		for i in 0..<2 {
			x := int(WorldNoiseHash(i+51, variant, seed)*13)
			y := int(WorldNoiseHash(variant, i+51, seed+1)*15)
			ArtRect(&art, x, y, 2, 1, soft)
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

	case .Hill:
		TerrainSpeckles(&art, variant, seed, light, dark)
		for i in 0..<2 {
			x := 1+int(WorldNoiseHash(i+71, variant, seed)*12)
			y := 1+int(WorldNoiseHash(variant, i+71, seed+1)*13)
			ArtRect(&art, x, y, 3, 2, light)
			ArtRect(&art, x, y+2, 3, 1, dark)
			ArtPixel(&art, x+1, y, highlight)
		}

	case .Desert:
		TerrainSpeckles(&art, variant, seed, light, soft)
		for i in 0..<2 {
			x := int(WorldNoiseHash(i+81, variant, seed)*13)
			y := 2+int(WorldNoiseHash(variant, i+81, seed+1)*12)
			ArtPixel(&art, x, y, light)
			ArtPixel(&art, x+2, y+1, soft)
		}
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
