package main

// Decorations are static scenery (trees, rocks, flowers...) but they live in
// their own slots and update loop so they can grow behaviour such as fire or
// regrowth without touching the unit/building passes.
DECORATION_CAPACITY :: 100_000
DECORATION_FIRE_RADIUS :: 2.5
DECORATION_FIRE_CHUNK_RADIUS :: 3
DECORATION_FIRE_SPREAD :: 0.08
DECORATION_FIRE_DAMAGE :: 0.35

DecorationKind :: enum {
	Tree,
	Pine,
	Bush,
	Rock,
	Flowers,
	Cactus,
	Reed,
	Stump,
}

ALL_DECORATION_KINDS := [8]DecorationKind {
	.Tree,
	.Pine,
	.Bush,
	.Rock,
	.Flowers,
	.Cactus,
	.Reed,
	.Stump,
}

Decoration :: struct {
	x, y:    f32,
	kind:    DecorationKind,
	variant: u8,
	health:  f32,
	fire:    f32,
}

DecorationHealth :: proc(kind: DecorationKind) -> f32 {
	switch kind {
	case .Tree:
		return 60
	case .Pine:
		return 50
	case .Bush, .Flowers, .Reed:
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
	return kind != .Rock
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
	w.decorations.fire[slot] = 0
	w.decorationUsed[slot] = true
	w.decorationCursor = (slot+1)%DECORATION_CAPACITY
	SpatialDecorationInsert(w, slot)
	return slot, true
}

WorldDecorationDespawn :: proc(w: ^World, slot: int) -> bool {
	if slot < 0 || slot >= DECORATION_CAPACITY || !w.decorationUsed[slot] do return false
	if w.decorations.fire[slot] > 0 do w.decorationBurning -= 1
	SpatialDecorationRemove(w, slot)
	w.decorationUsed[slot] = false
	return true
}

WorldDecorationIgnite :: proc(w: ^World, slot: int, intensity: f32) {
	if slot < 0 || slot >= DECORATION_CAPACITY || !w.decorationUsed[slot] do return
	if w.decorations.fire[slot] > 0 do return
	if !DecorationIsFlammable(w.decorations.kind[slot]) do return
	w.decorations.fire[slot] = clamp(intensity, 0.2, 2)
	w.decorationBurning += 1
}

WorldDecorationClearRect :: proc(w: ^World, x, y, width, height: int) {
	chunk_size := w.spatial.chunkSize
	if chunk_size <= 0 || width <= 0 || height <= 0 do return

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
					WorldDecorationDespawn(w, slot)
				}
				slot = next
			}
		}
	}
}

WorldDecorationUpdate :: proc(w: ^World, delta_time: f32) {
	if w.decorationBurning == 0 do return

	for slot in 0 ..< DECORATION_CAPACITY {
		if !w.decorationUsed[slot] do continue
		intensity := w.decorations.fire[slot]
		if intensity <= 0 do continue

		kind := w.decorations.kind[slot]
		w.decorations.health[slot] -= DECORATION_FIRE_DAMAGE*intensity*delta_time
		if w.decorations.health[slot] <= 0 {
			DecorationBurnOut(w, slot, kind)
			continue
		}
		DecorationSpreadFire(w, slot, intensity, delta_time)
	}
}

DecorationBurnOut :: proc(w: ^World, slot: int, kind: DecorationKind) {
	w.decorations.fire[slot] = 0
	w.decorationBurning -= 1
	switch kind {
	case .Tree, .Pine, .Bush:
		w.decorations.kind[slot] = .Stump
		w.decorations.variant[slot] = 0
		w.decorations.health[slot] = DecorationHealth(.Stump)
	case .Rock, .Flowers, .Cactus, .Reed, .Stump:
		WorldDecorationDespawn(w, slot)
	}
}

DecorationSpreadFire :: proc(w: ^World, slot: int, intensity: f32, delta_time: f32) {
	chunk_size := w.spatial.chunkSize
	if chunk_size <= 0 do return
	x := w.decorations.x[slot]
	y := w.decorations.y[slot]
	world_width := f32(w.maxX)
	world_height := f32(w.maxY)

	radius := DECORATION_FIRE_CHUNK_RADIUS
	first_chunk_x := (int(x)-radius)/chunk_size
	last_chunk_x := (int(x)+radius)/chunk_size
	first_chunk_y := (int(y)-radius)/chunk_size
	last_chunk_y := (int(y)+radius)/chunk_size
	chance := DECORATION_FIRE_SPREAD*intensity*delta_time

	for chunk_y in first_chunk_y ..= last_chunk_y {
		wrapped_y := WorldWrapCoordinate(chunk_y, w.spatial.chunksY)
		for chunk_x in first_chunk_x ..= last_chunk_x {
			wrapped_x := WorldWrapCoordinate(chunk_x, w.spatial.chunksX)
			chunk := wrapped_x*w.spatial.chunksY+wrapped_y
			for neighbour := w.spatial.decorationHead[chunk]; neighbour >= 0;
				neighbour = w.spatial.decorationNext[neighbour] {
				if neighbour == slot do continue
				if w.decorations.fire[neighbour] > 0 do continue
				if !DecorationIsFlammable(w.decorations.kind[neighbour]) do continue
				delta_x := WorldShortestWrappedDelta(w.decorations.x[neighbour]-x, world_width)
				delta_y := WorldShortestWrappedDelta(w.decorations.y[neighbour]-y, world_height)
				if delta_x*delta_x+delta_y*delta_y > DECORATION_FIRE_RADIUS*DECORATION_FIRE_RADIUS {
					continue
				}
				roll := WorldNoiseHash(neighbour, slot, u64(w.simulationTime*64))
				if roll > chance do continue
				WorldDecorationIgnite(w, neighbour, intensity*0.8)
			}
		}
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
			jitter_y := 0.9+WorldNoiseHash(y, x, seed+913)*0.12
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
