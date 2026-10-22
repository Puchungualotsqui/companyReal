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
	chunk_x, chunk_y: int,
	last_used: u64,
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
			tile := draw_terrain_tile(kind, variant)
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

TerrainRenderLow :: proc(renderer: ^TerrainRenderer, world_width, world_height: f32, first_copy_x, last_copy_x, first_copy_y, last_copy_y: int) {
	source := rl.Rectangle{0, 0, world_width, world_height}
	for copy_x in first_copy_x ..< last_copy_x+1 {
		for copy_y in first_copy_y ..< last_copy_y+1 {
			destination := rl.Rectangle{
				x = f32(copy_x)*world_width,
				y = f32(copy_y)*world_height,
				width = world_width,
				height = world_height,
			}
			rl.DrawTexturePro(renderer.lowTexture, source, destination, rl.Vector2{0, 0}, 0, rl.WHITE)
		}
	}
}

TerrainRenderChunks :: proc(w: ^World, renderer: ^TerrainRenderer, camera: rl.Camera2D, first_copy_x, last_copy_x, first_copy_y, last_copy_y: int) {
	world_width := f32(w.maxX)
	world_height := f32(w.maxY)
	chunk_count_x := (int(w.maxX)+TERRAIN_CHUNK_TILES-1)/TERRAIN_CHUNK_TILES
	chunk_count_y := (int(w.maxY)+TERRAIN_CHUNK_TILES-1)/TERRAIN_CHUNK_TILES
	if chunk_count_x <= 0 || chunk_count_y <= 0 do return
	renderer.generated = 0
	// Base layer: chunks that are still being generated fall back to the flat map.
	TerrainRenderLow(
		renderer,
		world_width,
		world_height,
		first_copy_x,
		last_copy_x,
		first_copy_y,
		last_copy_y,
	)

	half_view_width := f32(rl.GetScreenWidth())/(2*camera.zoom)
	half_view_height := f32(rl.GetScreenHeight())/(2*camera.zoom)
	view_min_x := camera.target.x-half_view_width
	view_max_x := camera.target.x+half_view_width
	view_min_y := camera.target.y-half_view_height
	view_max_y := camera.target.y+half_view_height
	source := rl.Rectangle{0, 0, TERRAIN_CHUNK_PIXELS, TERRAIN_CHUNK_PIXELS}

	for copy_x in first_copy_x ..< last_copy_x+1 {
		offset_x := f32(copy_x)*world_width
		first_chunk_x := WorldFloor((view_min_x-offset_x)/f32(TERRAIN_CHUNK_TILES))
		last_chunk_x := WorldFloor((view_max_x-offset_x)/f32(TERRAIN_CHUNK_TILES))
		for copy_y in first_copy_y ..< last_copy_y+1 {
			offset_y := f32(copy_y)*world_height
			first_chunk_y := WorldFloor((view_min_y-offset_y)/f32(TERRAIN_CHUNK_TILES))
			last_chunk_y := WorldFloor((view_max_y-offset_y)/f32(TERRAIN_CHUNK_TILES))
			for chunk_y in first_chunk_y ..= last_chunk_y {
				for chunk_x in first_chunk_x ..= last_chunk_x {
					texture, ready := TerrainEnsureChunk(
						w,
						renderer,
						WorldWrapCoordinate(chunk_x, chunk_count_x),
						WorldWrapCoordinate(chunk_y, chunk_count_y),
					)
					if !ready do continue
					destination := rl.Rectangle{
						x = offset_x+f32(chunk_x*TERRAIN_CHUNK_TILES),
						y = offset_y+f32(chunk_y*TERRAIN_CHUNK_TILES),
						width = TERRAIN_CHUNK_TILES,
						height = TERRAIN_CHUNK_TILES,
					}
					rl.DrawTexturePro(texture, source, destination, rl.Vector2{0, 0}, 0, rl.WHITE)
				}
			}
		}
	}
}

TerrainEnsureChunk :: proc(w: ^World, renderer: ^TerrainRenderer, chunk_x, chunk_y: int) -> (rl.Texture2D, bool) {
	renderer.clock += 1
	for &chunk in renderer.chunks {
		if chunk.chunk_x == chunk_x && chunk.chunk_y == chunk_y {
			chunk.last_used = renderer.clock
			return chunk.texture, true
		}
	}
	if renderer.generated >= TERRAIN_CHUNK_GENERATION_BUDGET do return {}, false
	renderer.generated += 1

	texture := TerrainCreateChunkTexture(w, renderer, chunk_x, chunk_y)
	if len(renderer.chunks) >= TERRAIN_CHUNK_CAPACITY {
		oldest := 0
		for chunk, index in renderer.chunks {
			if chunk.last_used < renderer.chunks[oldest].last_used do oldest = index
		}
		rl.UnloadTexture(renderer.chunks[oldest].texture)
		renderer.chunks[oldest] = TerrainChunk{
			texture = texture,
			chunk_x = chunk_x,
			chunk_y = chunk_y,
			last_used = renderer.clock,
		}
		return texture, true
	}

	append(&renderer.chunks, TerrainChunk{
		texture = texture,
		chunk_x = chunk_x,
		chunk_y = chunk_y,
		last_used = renderer.clock,
	})
	return texture, true
}

TerrainCreateChunkTexture :: proc(w: ^World, renderer: ^TerrainRenderer, chunk_x, chunk_y: int) -> rl.Texture2D {
	world_width := int(w.maxX)
	world_height := int(w.maxY)
	image := rl.GenImageColor(TERRAIN_CHUNK_PIXELS, TERRAIN_CHUNK_PIXELS, rl.BLACK)
	defer rl.UnloadImage(image)
	dst := cast([^]u8)image.data
	row_bytes := PIXELS_PER_TILE*4

	for tile_y in 0..<TERRAIN_CHUNK_TILES {
		for tile_x in 0..<TERRAIN_CHUNK_TILES {
			world_x := min(chunk_x*TERRAIN_CHUNK_TILES+tile_x, world_width-1)
			world_y := min(chunk_y*TERRAIN_CHUNK_TILES+tile_y, world_height-1)
			kind := w.ground[world_x][world_y].type
			variant := int(WorldNoiseHash(world_x, world_y, TERRAIN_SEED)*TERRAIN_TILE_VARIANTS)
			if variant >= TERRAIN_TILE_VARIANTS do variant = TERRAIN_TILE_VARIANTS-1
			tile_image := renderer.tiles[kind][variant]
			src := cast([^]u8)tile_image.data
			pixel_x := tile_x*PIXELS_PER_TILE
			pixel_y := tile_y*PIXELS_PER_TILE
			for row in 0..<PIXELS_PER_TILE {
				offset := ((pixel_y+row)*TERRAIN_CHUNK_PIXELS+pixel_x)*4
				mem.copy(rawptr(&dst[offset]), rawptr(&src[row*row_bytes]), row_bytes)
			}
			TerrainDitherTileEdges(dst, w, world_x, world_y, pixel_x, pixel_y)
		}
	}

	texture := rl.LoadTextureFromImage(image)
	rl.SetTextureFilter(texture, .POINT)
	return texture
}

// Softens the hard tile boundary by speckling the neighbour's ground colour into
// this tile, so grass/sand/water transitions read organically instead of as a
// 16-pixel staircase.
TerrainDitherTileEdges :: proc(dst: [^]u8, w: ^World, world_x, world_y, pixel_x, pixel_y: int) {
	world_width := int(w.maxX)
	world_height := int(w.maxY)
	kind := w.ground[world_x][world_y].type
	neighbour_offsets := [4][2]int{{0, -1}, {1, 0}, {0, 1}, {-1, 0}}

	for offset, side in neighbour_offsets {
		neighbour_x := WorldWrapCoordinate(world_x+offset[0], world_width)
		neighbour_y := WorldWrapCoordinate(world_y+offset[1], world_height)
		neighbour_kind := w.ground[neighbour_x][neighbour_y].type
		if neighbour_kind == kind do continue

		color := WorldTileColor(neighbour_kind)
		for along in 0..<PIXELS_PER_TILE {
			for depth in 0..<2 {
				if WorldNoiseHash(
					world_x*PIXELS_PER_TILE+along,
					world_y*PIXELS_PER_TILE+depth+side*PIXELS_PER_TILE,
					TERRAIN_SEED+7,
				) > 0.5-f32(depth)*0.25 {
					continue
				}

				px, py: int
				switch side {
				case 0:
					px = pixel_x+along
					py = pixel_y+depth
				case 1:
					px = pixel_x+PIXELS_PER_TILE-1-depth
					py = pixel_y+along
				case 2:
					px = pixel_x+along
					py = pixel_y+PIXELS_PER_TILE-1-depth
				case 3:
					px = pixel_x+depth
					py = pixel_y+along
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

WorldTileColor :: proc(tile_type: TileType) -> rl.Color {
	switch tile_type {
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

draw_terrain_tile :: proc(kind: TileType, variant: int) -> Art {
	art := art_init(PIXELS_PER_TILE, PIXELS_PER_TILE)
	base := WorldTileColor(kind)
	light := c_shade(base, 1.06)
	highlight := c_shade(base, 1.11)
	soft := c_shade(base, 0.96)
	dark := c_shade(base, 0.9)
	art_rect(&art, 0, 0, PIXELS_PER_TILE, PIXELS_PER_TILE, base)
	seed := TERRAIN_SEED+u64(variant)*7919+u64(kind)*1319

	switch kind {
	case .Water, .FreshWater, .River:
		wave := c_shade(base, 1.11)
		for i in 0..<2 {
			x := int(WorldNoiseHash(i, variant, seed)*13)
			y := int(WorldNoiseHash(variant, i, seed+1)*15)
			length := 2+int(WorldNoiseHash(i, variant, seed+2)*3)
			art_rect(&art, x, y, length, 1, wave)
			art_pixel(&art, x+1, y+1, soft)
		}
		art_pixel(
			&art,
			int(WorldNoiseHash(variant, 3, seed)*PIXELS_PER_TILE),
			int(WorldNoiseHash(3, variant, seed+1)*PIXELS_PER_TILE),
			soft,
		)

	case .Ground:
		terrain_speckles(&art, variant, seed, light, dark)
		for i in 0..<3 {
			x := int(WorldNoiseHash(i+31, variant, seed)*15)
			y := int(WorldNoiseHash(variant, i+31, seed+1)*14)
			art_rect(&art, x, y, 1, 2, light)
		}

	case .FertileGround:
		terrain_speckles(&art, variant, seed, light, dark)
		for i in 0..<4 {
			x := 1+int(WorldNoiseHash(i+41, variant, seed)*13)
			y := 1+int(WorldNoiseHash(variant, i+41, seed+1)*13)
			art_rect(&art, x, y, 1, 2, highlight)
		}

	case .Sand:
		terrain_speckles(&art, variant, seed, light, soft)
		for i in 0..<2 {
			x := int(WorldNoiseHash(i+51, variant, seed)*13)
			y := int(WorldNoiseHash(variant, i+51, seed+1)*15)
			art_rect(&art, x, y, 2, 1, soft)
		}

	case .Forest:
		for i in 0..<4 {
			cx := 2+int(WorldNoiseHash(i+61, variant, seed)*12)
			cy := 2+int(WorldNoiseHash(variant, i+61, seed+1)*12)
			radius := 1+int(WorldNoiseHash(i, i+variant, seed+2)*3)
			art_circle(&art, cx, cy, radius, light)
			art_pixel(&art, cx, cy, highlight)
			art_pixel(&art, cx+radius, cy+1, dark)
		}
		terrain_speckles(&art, variant, seed, light, dark)

	case .Hill:
		terrain_speckles(&art, variant, seed, light, dark)
		for i in 0..<2 {
			x := 1+int(WorldNoiseHash(i+71, variant, seed)*12)
			y := 1+int(WorldNoiseHash(variant, i+71, seed+1)*13)
			art_rect(&art, x, y, 3, 2, light)
			art_rect(&art, x, y+2, 3, 1, dark)
			art_pixel(&art, x+1, y, highlight)
		}

	case .Desert:
		terrain_speckles(&art, variant, seed, light, soft)
		for i in 0..<2 {
			x := int(WorldNoiseHash(i+81, variant, seed)*13)
			y := 2+int(WorldNoiseHash(variant, i+81, seed+1)*12)
			art_pixel(&art, x, y, light)
			art_pixel(&art, x+2, y+1, soft)
		}
	}
	return art
}

terrain_speckles :: proc(art: ^Art, variant: int, seed: u64, light, dark: rl.Color) {
	for i in 0..<9 {
		x := int(WorldNoiseHash(i, variant, seed)*PIXELS_PER_TILE)
		y := int(WorldNoiseHash(variant, i, seed+1)*PIXELS_PER_TILE)
		color := light
		if WorldNoiseHash(x, y, seed+2) < 0.55 do color = dark
		art_pixel(art, x, y, color)
	}
}
