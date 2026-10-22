package main

// Decorations are static scenery (trees, rocks, flowers...) but they live in
// their own slots and update loop so they can grow behaviour such as fire or
// regrowth without touching the unit/building passes.
DECORATION_CAPACITY :: 100_000
DECORATION_REGROW_SECONDS :: 90

DecorationKind :: enum {
	Tree,
	Pine,
	Bush,
	Rock,
	Flowers,
	Cactus,
	Reed,
	Stump,
	Lamp,
}

ALL_DECORATION_KINDS := [9]DecorationKind {
	.Tree,
	.Pine,
	.Bush,
	.Rock,
	.Flowers,
	.Cactus,
	.Reed,
	.Stump,
	.Lamp,
}

Decoration :: struct {
	x, y:        f32,
	kind:        DecorationKind,
	variant:     u8,
	health:      f32,
	regrowTimer: f32,
}

DecorationHealth :: proc(kind: DecorationKind) -> f32 {
	switch kind {
	case .Tree:
		return 60
	case .Pine:
		return 50
	case .Bush, .Flowers, .Reed, .Lamp:
		return 12
	case .Rock:
		return 120
	case .Cactus:
		return 40
	case .Stump:
		return 30
	}
	return 10
}

DecorationIsFlammable :: proc(kind: DecorationKind) -> bool {
	switch kind {
	case .Rock:
		return false
	case .Tree, .Pine, .Bush, .Flowers, .Cactus, .Reed, .Stump, .Lamp:
		return true
	}
	unreachable()
}

DecorationChoppable :: proc(kind: DecorationKind) -> bool {
	switch kind {
	case .Tree, .Pine, .Bush:
		return true
	case .Rock, .Flowers, .Cactus, .Reed, .Stump, .Lamp:
		return false
	}
	return false
}

DecorationChopSeconds :: proc(kind: DecorationKind) -> f32 {
	switch kind {
	case .Tree:
		return 4
	case .Pine:
		return 3
	case .Bush:
		return 1.2
	case .Rock, .Flowers, .Cactus, .Reed, .Stump, .Lamp:
		return 0
	}
	return 0
}

// Time a builder needs to clear a decoration off a construction site. Unlike
// harvesting, even stones and brush take work to remove.
DecorationClearSeconds :: proc(kind: DecorationKind) -> f32 {
	switch kind {
	case .Tree:
		return 4
	case .Pine:
		return 3
	case .Rock:
		return 2.5
	case .Stump:
		return 1.5
	case .Bush:
		return 1.2
	case .Cactus:
		return 1
	case .Flowers, .Reed:
		return 0.4
	case .Lamp:
		return 0.6
	}
	return 0
}

DecorationWoodYield :: proc(kind: DecorationKind) -> f32 {
	switch kind {
	case .Tree:
		return 6
	case .Pine:
		return 4
	case .Bush:
		return 1
	case .Rock, .Flowers, .Cactus, .Reed, .Stump, .Lamp:
		return 0
	}
	return 0
}

WorldDecorationSpawn :: proc(w: ^World, x, y: f32, kind: DecorationKind, variant: u8) -> (int, bool) {
	slot := -1
	for step in 0 ..< DECORATION_CAPACITY {
		candidate := (w.decorationCursor+step)%DECORATION_CAPACITY
		if !w.decorationUsed[candidate] {
			slot = candidate
			break
		}
	}
	if slot < 0 do return 0, false

	w.decorations.x[slot] = x
	w.decorations.y[slot] = y
	w.decorations.kind[slot] = kind
	w.decorations.variant[slot] = variant
	w.decorations.health[slot] = DecorationHealth(kind)
	w.decorations.regrowTimer[slot] = 0
	w.decorationUsed[slot] = true
	if kind == .Stump do w.decorationStumps += 1
	w.decorationCursor = (slot+1)%DECORATION_CAPACITY
	SpatialDecorationInsert(w, slot)
	return slot, true
}

// Roads are decorated automatically: a deterministic share of path tiles gets
// a street lamp, which also lights the town at night.
WorldSpawnStreetLamp :: proc(w: ^World, x, y: int) {
	if WorldNoiseHash(x, y, 0x1A3B) >= 0.45 do return
	if WorldTileHasLamp(w, x, y) do return
	WorldDecorationSpawn(w, f32(x)+0.5, f32(y)+0.9, .Lamp, u8(WorldNoiseHash(y, x, 0x1A3C)*4) & 3)
}

WorldTileHasLamp :: proc(w: ^World, x, y: int) -> bool {
	chunk_size := w.spatial.chunkSize
	if chunk_size <= 0 do return false
	wrapped_x := WorldWrapCoordinate(x, int(w.maxX))
	wrapped_y := WorldWrapCoordinate(y, int(w.maxY))
	chunk := (wrapped_x/chunk_size)*w.spatial.chunksY+wrapped_y/chunk_size
	for slot := w.spatial.decorationHead[chunk]; slot >= 0; slot = w.spatial.decorationNext[slot] {
		if w.decorations.kind[slot] != .Lamp do continue
		if int(w.decorations.x[slot]) == wrapped_x && int(w.decorations.y[slot]) == wrapped_y {
			return true
		}
	}
	return false
}

WorldDecorationDespawn :: proc(w: ^World, slot: int) -> bool {
	if slot < 0 || slot >= DECORATION_CAPACITY || !w.decorationUsed[slot] do return false
	if w.decorations.kind[slot] == .Stump do w.decorationStumps -= 1
	SpatialDecorationRemove(w, slot)
	w.decorationUsed[slot] = false
	return true
}

// Fells a harvested decoration: trunks keep a stump so the forest can regrow.
DecorationFell :: proc(w: ^World, slot: int) {
	switch w.decorations.kind[slot] {
	case .Tree, .Pine:
		w.decorations.kind[slot] = .Stump
		w.decorations.variant[slot] = 0
		w.decorations.health[slot] = DecorationHealth(.Stump)
		w.decorations.regrowTimer[slot] = 0
		w.decorationStumps += 1
	case .Bush, .Flowers, .Cactus, .Reed, .Stump, .Lamp:
		WorldDecorationDespawn(w, slot)
	case .Rock:
	}
}

// Regrows a stump into a tree once it has rested long enough. Roads and
// buildings keep the ground claimed, so the stump is dropped instead.
DecorationRegrowth :: proc(w: ^World, slot: int, delta_time: f32) -> bool {
	if slot < 0 || slot >= DECORATION_CAPACITY || !w.decorationUsed[slot] do return false
	if w.decorations.kind[slot] != .Stump do return false

	tile_x := int(w.decorations.x[slot])
	tile_y := int(w.decorations.y[slot])
	if WorldFireAt(w, tile_x, tile_y) do return false
	if WorldTileOccupied(w, tile_x, tile_y) {
		WorldDecorationDespawn(w, slot)
		return false
	}

	w.decorations.regrowTimer[slot] += delta_time
	if w.decorations.regrowTimer[slot] < DECORATION_REGROW_SECONDS do return false

	kind := DecorationKind.Tree
	if WorldNoiseHash(tile_x, tile_y, 0xA11CE) < 0.35 do kind = .Pine
	w.decorations.kind[slot] = kind
	w.decorations.variant[slot] = u8(int(WorldNoiseHash(tile_y, tile_x, 0xA11CF)*4) & 3)
	w.decorations.health[slot] = DecorationHealth(kind)
	w.decorations.regrowTimer[slot] = 0
	w.decorationStumps -= 1
	return true
}



WorldDecorationClearRect :: proc(w: ^World, x, y, width, height: int) -> f32 {
	chunk_size := w.spatial.chunkSize
	if chunk_size <= 0 || width <= 0 || height <= 0 do return 0

	harvested: f32 = 0
	first_chunk_x := x/chunk_size
	last_chunk_x := (x+width-1)/chunk_size
	first_chunk_y := y/chunk_size
	last_chunk_y := (y+height-1)/chunk_size
	for chunk_y in first_chunk_y ..= last_chunk_y {
		wrapped_y := WorldWrapCoordinate(chunk_y, w.spatial.chunksY)
		for chunk_x in first_chunk_x ..= last_chunk_x {
			wrapped_x := WorldWrapCoordinate(chunk_x, w.spatial.chunksX)
			chunk := wrapped_x*w.spatial.chunksY+wrapped_y
			slot := w.spatial.decorationHead[chunk]
			for slot >= 0 {
				next := w.spatial.decorationNext[slot]
				decoration_x := int(w.decorations.x[slot])
				decoration_y := int(w.decorations.y[slot])
				if decoration_x >= x && decoration_x < x+width &&
					decoration_y >= y && decoration_y < y+height {
					harvested += DecorationWoodYield(w.decorations.kind[slot])
					WorldDecorationDespawn(w, slot)
				}
				slot = next
			}
		}
	}
	return harvested
}

WorldDecorationUpdate :: proc(w: ^World, delta_time: f32) {
	if w.decorationStumps == 0 do return

	for slot in 0 ..< DECORATION_CAPACITY {
		if !w.decorationUsed[slot] do continue
		DecorationRegrowth(w, slot, delta_time)
	}
}

// Places scenery on top of the generated terrain. Forest tiles get actual
// trees, while the other biomes get their own sparse details.
WorldGenerateDecorations :: proc(w: ^World, seed: u64) {
	world_width := int(w.maxX)
	world_height := int(w.maxY)

	for x in 0 ..< world_width {
		for y in 0 ..< world_height {
			kind: DecorationKind
			found := true
			roll := WorldNoiseHash(x, y, seed+901)
			switch w.ground[x][y].type {
			case .Forest:
				switch {
				case roll < 0.30:
					kind = .Tree
				case roll < 0.38:
					kind = .Pine
				case roll < 0.40:
					kind = .Bush
				case:
					found = false
				}
			case .FertileGround:
				switch {
				case roll < 0.06:
					kind = .Flowers
				case roll < 0.075:
					kind = .Bush
				case:
					found = false
				}
			case .Ground:
				switch {
				case roll < 0.012:
					kind = .Flowers
				case roll < 0.020:
					kind = .Rock
				case roll < 0.026:
					kind = .Bush
				case:
					found = false
				}
			case .Hill:
				switch {
				case roll < 0.045:
					kind = .Rock
				case roll < 0.060:
					kind = .Pine
				case:
					found = false
				}
			case .Sand:
				switch {
				case roll < 0.015:
					kind = .Rock
				case roll < 0.030:
					kind = .Reed
				case:
					found = false
				}
			case .Desert:
				switch {
				case roll < 0.020:
					kind = .Cactus
				case roll < 0.028:
					kind = .Rock
				case:
					found = false
				}
			case .FreshWater, .River:
				if roll < 0.020 {
					kind = .Reed
				} else {
					found = false
				}
			case .Water:
				found = false
			}
			if !found do continue
			if kind == .Reed && !WorldTileNearWater(w, x, y) && w.ground[x][y].type == .Sand {
				continue
			}

			variant := u8(int(WorldNoiseHash(y, x, seed+907)*4) & 3)
			jitter_x := 0.15+WorldNoiseHash(x, y, seed+911)*0.7
			jitter_y := 0.86+WorldNoiseHash(y, x, seed+913)*0.12
			WorldDecorationSpawn(w, f32(x)+jitter_x, f32(y)+jitter_y, kind, variant)
		}
	}
}

WorldTileNearWater :: proc(w: ^World, x, y: int) -> bool {
	offsets := [4][2]int{{0, -1}, {1, 0}, {0, 1}, {-1, 0}}
	for offset in offsets {
		neighbour_x := WorldWrapCoordinate(x+offset[0], int(w.maxX))
		neighbour_y := WorldWrapCoordinate(y+offset[1], int(w.maxY))
		switch w.ground[neighbour_x][neighbour_y].type {
		case .Water, .FreshWater, .River:
			return true
		case .Ground, .FertileGround, .Sand, .Forest, .Hill, .Desert:
		}
	}
	return false
}
