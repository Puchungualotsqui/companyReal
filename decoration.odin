package main

// Decorations are static scenery (trees, rocks, flowers...) but they live in
// their own slots and update loop so they can grow behaviour such as fire or
// regrowth without touching the unit/building passes.
DECORATION_CAPACITY :: 100_000
DECORATION_REGROW_SECONDS :: 90
STREET_LAMP_MIN_SPACING :: 7

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
	Rubble,
	BurntRubble,
}

ALL_DECORATION_KINDS := [11]DecorationKind {
	.Tree,
	.Pine,
	.Bush,
	.Rock,
	.Flowers,
	.Cactus,
	.Reed,
	.Stump,
	.Lamp,
	.Rubble,
	.BurntRubble,
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
	case .Rubble, .BurntRubble:
		return 10
	}
	return 10
}

DecorationIsFlammable :: proc(kind: DecorationKind) -> bool {
	switch kind {
	case .Rock, .Rubble, .BurntRubble:
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
	case .Rock, .Flowers, .Cactus, .Reed, .Stump, .Lamp, .Rubble, .BurntRubble:
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
	case .Rock, .Flowers, .Cactus, .Reed, .Stump, .Lamp, .Rubble, .BurntRubble:
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
	case .Rubble:
		return 2
	case .BurntRubble:
		return 2.5
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
	case .Rock, .Flowers, .Cactus, .Reed, .Stump, .Lamp, .Rubble, .BurntRubble:
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

BuildingOnFire :: proc(w: ^World, buildingSlot: int) -> bool {
	if buildingSlot < 0 || buildingSlot >= BUILDING_CAPACITY || !w.buildingUsed[buildingSlot] {
		return false
	}
	building := &w.buildings[buildingSlot]
	width, height := BuildingTileSize(building.type)
	for tileX in building.x ..< building.x+width {
		for tileY in building.y ..< building.y+height {
			if WorldFireAt(w, tileX, tileY) do return true
		}
	}
	return false
}

// Leaves a few rubble piles over the old footprint. Burnt buildings leave
// charred debris, while ordinary collapses leave timber and stone chunks.
BuildingSpawnDebris :: proc(w: ^World, buildingSlot: int, burnt: bool) {
	if buildingSlot < 0 || buildingSlot >= BUILDING_CAPACITY || !w.buildingUsed[buildingSlot] {
		return
	}
	building := &w.buildings[buildingSlot]
	width, height := BuildingTileSize(building.type)
	area := width*height
	count := clamp(area/2, 1, 6)
	seed := u64(buildingSlot)*0x9E3779B97F4A7C15 ~ u64(int(w.simulationTime*10))
	kind: DecorationKind = burnt ? .BurntRubble : .Rubble
	for i in 0..<count {
		tileIndex := (i*5+buildingSlot)%area
		tileX := building.x+tileIndex%width
		tileY := building.y+tileIndex/width
		x := f32(tileX)+0.15+WorldNoiseHash(buildingSlot, i, seed+0x3)*0.7
		y := f32(tileY)+0.6+WorldNoiseHash(i, buildingSlot, seed+0x4)*0.35
		variant := u8(int(WorldNoiseHash(buildingSlot, i, seed+0x5)*4) & 3)
		if _, spawned := WorldDecorationSpawn(w, x, y, kind, variant); !spawned do break
	}
}

// Sparse road lighting; established bends and junctions get more candidates.
WorldSpawnStreetLamp :: proc(w: ^World, x, y: int) {
	if w.spatial.chunkSize <= 0 || !WorldTileHasPath(w, x, y) do return
	tileX := WorldWrapCoordinate(x, int(w.maxX))
	tileY := WorldWrapCoordinate(y, int(w.maxY))
	roll := WorldNoiseHash(tileX, tileY, 0x1A3B)
	if roll >= 0.18 do return
	if roll >= 0.08 {
		horizontal := WorldTileHasPath(w, tileX-1, tileY) || WorldTileHasPath(w, tileX+1, tileY)
		vertical := WorldTileHasPath(w, tileX, tileY-1) || WorldTileHasPath(w, tileX, tileY+1)
		if !horizontal || !vertical do return
	}
	if WorldHasNearbyStreetLamp(w, tileX, tileY) do return
	WorldDecorationSpawn(w, f32(tileX)+0.5, f32(tileY)+0.9, .Lamp, u8(WorldNoiseHash(tileY, tileX, 0x1A3C)*4) & 3)
}

WorldHasNearbyStreetLamp :: proc(w: ^World, x, y: int) -> bool {
	chunkSize := w.spatial.chunkSize
	worldWidth, worldHeight := int(w.maxX), int(w.maxY)
	if chunkSize <= 0 || worldWidth <= 0 || worldHeight <= 0 do return false
	centerX := WorldWrapCoordinate(x, worldWidth)
	centerY := WorldWrapCoordinate(y, worldHeight)

	// Wrap tiles before selecting buckets: edge chunks can be shorter than chunkSize.
	for tileX := centerX-STREET_LAMP_MIN_SPACING; tileX <= centerX+STREET_LAMP_MIN_SPACING; {
		wrappedX := WorldWrapCoordinate(tileX, worldWidth)
		chunkX := wrappedX/chunkSize
		for tileY := centerY-STREET_LAMP_MIN_SPACING; tileY <= centerY+STREET_LAMP_MIN_SPACING; {
			wrappedY := WorldWrapCoordinate(tileY, worldHeight)
			chunk := chunkX*w.spatial.chunksY+wrappedY/chunkSize
			for slot := w.spatial.decorationHead[chunk]; slot >= 0; slot = w.spatial.decorationNext[slot] {
				if w.decorations.kind[slot] != .Lamp do continue
				deltaX := WorldShortestWrappedDelta(f32(int(w.decorations.x[slot])-centerX), f32(worldWidth))
				deltaY := WorldShortestWrappedDelta(f32(int(w.decorations.y[slot])-centerY), f32(worldHeight))
				if deltaX*deltaX+deltaY*deltaY < f32(STREET_LAMP_MIN_SPACING*STREET_LAMP_MIN_SPACING) {
					return true
				}
			}
			tileY += min(chunkSize-wrappedY%chunkSize, worldHeight-wrappedY)
		}
		tileX += min(chunkSize-wrappedX%chunkSize, worldWidth-wrappedX)
	}
	return false
}

WorldTileHasLamp :: proc(w: ^World, x, y: int) -> bool {
	chunkSize := w.spatial.chunkSize
	if chunkSize <= 0 do return false
	wrappedX := WorldWrapCoordinate(x, int(w.maxX))
	wrappedY := WorldWrapCoordinate(y, int(w.maxY))
	chunk := (wrappedX/chunkSize)*w.spatial.chunksY+wrappedY/chunkSize
	for slot := w.spatial.decorationHead[chunk]; slot >= 0; slot = w.spatial.decorationNext[slot] {
		if w.decorations.kind[slot] != .Lamp do continue
		if int(w.decorations.x[slot]) == wrappedX && int(w.decorations.y[slot]) == wrappedY {
			return true
		}
	}
	return false
}

WorldDecorationDespawn :: proc(w: ^World, slot: int) -> bool {
	if slot < 0 || slot >= DECORATION_CAPACITY || !w.decorationUsed[slot] do return false
	if w.decorations.kind[slot] == .Stump do w.decorationStumps -= 1
	FogDecorationDespawn(w, slot)
	SpatialDecorationRemove(w, slot)
	w.decorationUsed[slot] = false
	return true
}

// Fells a harvested decoration: trunks keep a stump so the forest can regrow.
DecorationFell :: proc(w: ^World, slot: int) {
	kind := w.decorations.kind[slot]
	DecorationDebris(w, w.decorations.x[slot], w.decorations.y[slot], kind)
	switch kind {
	case .Tree, .Pine:
		w.decorations.kind[slot] = .Stump
		w.decorations.variant[slot] = 0
		w.decorations.health[slot] = DecorationHealth(.Stump)
		w.decorations.regrowTimer[slot] = 0
		w.decorationStumps += 1
	case .Bush, .Flowers, .Cactus, .Reed, .Stump, .Lamp, .Rubble, .BurntRubble:
		WorldDecorationDespawn(w, slot)
	case .Rock:
		WorldDecorationDespawn(w, slot)
	}
}

// Regrows a stump into a tree once it has rested long enough. Roads and
// buildings keep the ground claimed, so the stump is dropped instead.
DecorationRegrowth :: proc(w: ^World, slot: int, deltaTime: f32) -> bool {
	if slot < 0 || slot >= DECORATION_CAPACITY || !w.decorationUsed[slot] do return false
	if w.decorations.kind[slot] != .Stump do return false

	tileX := int(w.decorations.x[slot])
	tileY := int(w.decorations.y[slot])
	if WorldFireAt(w, tileX, tileY) do return false
	if WorldTileOccupied(w, tileX, tileY) {
		WorldDecorationDespawn(w, slot)
		return false
	}

	w.decorations.regrowTimer[slot] += deltaTime
	if w.decorations.regrowTimer[slot] < DECORATION_REGROW_SECONDS do return false

	kind := DecorationKind.Tree
	if WorldNoiseHash(tileX, tileY, 0xA11CE) < 0.35 do kind = .Pine
	w.decorations.kind[slot] = kind
	w.decorations.variant[slot] = u8(int(WorldNoiseHash(tileY, tileX, 0xA11CF)*4) & 3)
	w.decorations.health[slot] = DecorationHealth(kind)
	w.decorations.regrowTimer[slot] = 0
	w.decorationStumps -= 1
	return true
}



WorldDecorationClearRect :: proc(w: ^World, x, y, width, height: int) -> f32 {
	chunkSize := w.spatial.chunkSize
	if chunkSize <= 0 || width <= 0 || height <= 0 do return 0

	harvested: f32 = 0
	firstChunkX := x/chunkSize
	lastChunkX := (x+width-1)/chunkSize
	firstChunkY := y/chunkSize
	lastChunkY := (y+height-1)/chunkSize
	for chunkY in firstChunkY ..= lastChunkY {
		wrappedY := WorldWrapCoordinate(chunkY, w.spatial.chunksY)
		for chunkX in firstChunkX ..= lastChunkX {
			wrappedX := WorldWrapCoordinate(chunkX, w.spatial.chunksX)
			chunk := wrappedX*w.spatial.chunksY+wrappedY
			slot := w.spatial.decorationHead[chunk]
			for slot >= 0 {
				next := w.spatial.decorationNext[slot]
				decorationX := int(w.decorations.x[slot])
				decorationY := int(w.decorations.y[slot])
				if decorationX >= x && decorationX < x+width &&
					decorationY >= y && decorationY < y+height {
					harvested += DecorationWoodYield(w.decorations.kind[slot])
					WorldDecorationDespawn(w, slot)
				}
				slot = next
			}
		}
	}
	return harvested
}

// Splash damage fells trees and brush around the impact; stone takes longer.
WorldDecorationAreaDamage :: proc(w: ^World, x, y, radius, damage: f32) {
	if radius <= 0 || damage <= 0 do return
	chunkSize := w.spatial.chunkSize
	if chunkSize <= 0 do return
	worldWidth := f32(w.maxX)
	worldHeight := f32(w.maxY)
	centerX := WorldWrapPosition(x, worldWidth)
	centerY := WorldWrapPosition(y, worldHeight)
	radiusSquared := radius*radius
	hit := 0

	centerChunkX := int(centerX)/chunkSize
	centerChunkY := int(centerY)/chunkSize
	chunkRadius := int(radius)/chunkSize+1
	for offsetX in -chunkRadius..=chunkRadius {
		chunkX := WorldWrapCoordinate(centerChunkX+offsetX, w.spatial.chunksX)
		for offsetY in -chunkRadius..=chunkRadius {
			chunkY := WorldWrapCoordinate(centerChunkY+offsetY, w.spatial.chunksY)
			chunk := chunkX*w.spatial.chunksY+chunkY
			slot := w.spatial.decorationHead[chunk]
			for slot >= 0 {
				next := w.spatial.decorationNext[slot]
				deltaX := WorldShortestWrappedDelta(w.decorations.x[slot]-centerX, worldWidth)
				deltaY := WorldShortestWrappedDelta(w.decorations.y[slot]-centerY, worldHeight)
				if deltaX*deltaX+deltaY*deltaY <= radiusSquared {
					w.decorations.health[slot] -= damage
					hit += 1
					if w.decorations.health[slot] <= 0 do DecorationFell(w, slot)
				}
				slot = next
			}
		}
	}

	if hit > 0 do DecorationBlastBurst(w, centerX, centerY, radius)
}

WorldDecorationUpdate :: proc(w: ^World, deltaTime: f32) {
	if w.decorationStumps == 0 do return

	for slot in 0 ..< DECORATION_CAPACITY {
		if !w.decorationUsed[slot] do continue
		DecorationRegrowth(w, slot, deltaTime)
	}
}

// Places scenery on top of the generated terrain. Forest tiles get actual
// trees, while the other biomes get their own sparse details.
WorldGenerateDecorations :: proc(w: ^World, seed: u64) {
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)

	for x in 0 ..< worldWidth {
		for y in 0 ..< worldHeight {
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
			case .Taiga:
				switch {
				case roll < 0.24:
					kind = .Pine
				case roll < 0.34:
					kind = .Tree
				case roll < 0.38:
					kind = .Bush
				case:
					found = false
				}
			case .Plains:
				switch {
				case roll < 0.06:
					kind = .Flowers
				case roll < 0.075:
					kind = .Bush
				case:
					found = false
				}
			case .Grassland:
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
			case .Steppe:
				switch {
				case roll < 0.018:
					kind = .Bush
				case roll < 0.026:
					kind = .Flowers
				case roll < 0.032:
					kind = .Rock
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
			case .Mountain:
				switch {
				case roll < 0.10:
					kind = .Rock
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
			case .Marsh:
				switch {
				case roll < 0.16:
					kind = .Reed
				case roll < 0.19:
					kind = .Bush
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
			case .Tundra:
				switch {
				case roll < 0.030:
					kind = .Rock
				case:
					found = false
				}
			case .Ash:
				switch {
				case roll < 0.045:
					kind = .Rock
				case:
					found = false
				}
			case .Lake, .River:
				if roll < 0.020 {
					kind = .Reed
				} else {
					found = false
				}
			case .Ocean, .Ice, .Lava:
				found = false
			}
			if !found do continue
			if kind == .Reed && !WorldTileNearWater(w, x, y) && w.ground[x][y].type == .Sand {
				continue
			}

			variant := u8(int(WorldNoiseHash(y, x, seed+907)*4) & 3)
			jitterX := 0.15+WorldNoiseHash(x, y, seed+911)*0.7
			jitterY := 0.86+WorldNoiseHash(y, x, seed+913)*0.12
			WorldDecorationSpawn(w, f32(x)+jitterX, f32(y)+jitterY, kind, variant)
		}
	}
}

WorldTileNearWater :: proc(w: ^World, x, y: int) -> bool {
	offsets := [4][2]int{{0, -1}, {1, 0}, {0, 1}, {-1, 0}}
	for offset in offsets {
		neighbourX := WorldWrapCoordinate(x+offset[0], int(w.maxX))
		neighbourY := WorldWrapCoordinate(y+offset[1], int(w.maxY))
		switch w.ground[neighbourX][neighbourY].type {
		case .Ocean, .Lake, .River:
			return true
		case .Ice, .Marsh, .Sand, .Grassland, .Plains, .Forest, .Taiga, .Steppe, .Hill, .Mountain, .Desert, .Tundra, .Ash, .Lava:
		}
	}
	return false
}
