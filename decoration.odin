package main

import "d32"

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
	x, y:        d32.Value,
	kind:        DecorationKind,
	variant:     u8,
	health:      d32.Value,
	regrowTimer: d32.Value,
}

DecorationHealth :: proc(kind: DecorationKind) -> d32.Value {
	switch kind {
	case .Tree:
		return d32.FromInt(60)
	case .Pine:
		return d32.FromInt(50)
	case .Bush, .Flowers, .Reed, .Lamp:
		return d32.FromInt(12)
	case .Rock:
		return d32.FromInt(120)
	case .Cactus:
		return d32.FromInt(40)
	case .Stump:
		return d32.FromInt(30)
	case .Rubble, .BurntRubble:
		return d32.FromInt(10)
	}
	return d32.FromInt(10)
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

DecorationChopSeconds :: proc(kind: DecorationKind) -> d32.Value {
	switch kind {
	case .Tree:
		return d32.FromInt(4)
	case .Pine:
		return d32.FromInt(3)
	case .Bush:
		return d32.FromRatio(6, 5)
	case .Rock, .Flowers, .Cactus, .Reed, .Stump, .Lamp, .Rubble, .BurntRubble:
		return d32.ZERO
	}
	return d32.ZERO
}

// Time a builder needs to clear a decoration off a construction site. Unlike
// harvesting, even stones and brush take work to remove.
DecorationClearSeconds :: proc(kind: DecorationKind) -> d32.Value {
	switch kind {
	case .Tree:
		return d32.FromInt(4)
	case .Pine:
		return d32.FromInt(3)
	case .Rock:
		return d32.FromRatio(5, 2)
	case .Stump:
		return d32.FromRatio(3, 2)
	case .Bush:
		return d32.FromRatio(6, 5)
	case .Cactus:
		return d32.ONE
	case .Flowers, .Reed:
		return d32.FromRatio(2, 5)
	case .Lamp:
		return d32.FromRatio(3, 5)
	case .Rubble:
		return d32.FromInt(2)
	case .BurntRubble:
		return d32.FromRatio(5, 2)
	}
	return d32.ZERO
}

DecorationWoodYield :: proc(kind: DecorationKind) -> d32.Value {
	switch kind {
	case .Tree:
		return d32.FromInt(6)
	case .Pine:
		return d32.FromInt(4)
	case .Bush:
		return d32.FromInt(1)
	case .Rock, .Flowers, .Cactus, .Reed, .Stump, .Lamp, .Rubble, .BurntRubble:
		return d32.ZERO
	}
	return d32.ZERO
}

WorldDecorationSpawn :: proc(w: ^World, x, y: d32.Value, kind: DecorationKind, variant: u8) -> (int, bool) {
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
	w.decorations.regrowTimer[slot] = d32.ZERO
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
		x := PositionFromF32(f32(tileX)+0.15+WorldNoiseHash(buildingSlot, i, seed+0x3)*0.7)
		y := PositionFromF32(f32(tileY)+0.6+WorldNoiseHash(i, buildingSlot, seed+0x4)*0.35)
		variant := u8(WorldNoiseHashInt(buildingSlot, i, seed+0x5)/250_000)
		if _, spawned := WorldDecorationSpawn(w, x, y, kind, variant); !spawned do break
	}
}

// Sparse road lighting; established bends and junctions get more candidates.
WorldSpawnStreetLamp :: proc(w: ^World, x, y: int) {
	if w.spatial.chunkSize <= 0 || !WorldTileHasPath(w, x, y) do return
	tileX := WorldWrapCoordinate(x, int(w.maxX))
	tileY := WorldWrapCoordinate(y, int(w.maxY))
	roll := WorldNoiseHashInt(tileX, tileY, 0x1A3B)
	if roll >= 180_000 do return
	if roll >= 80_000 {
		horizontal := WorldTileHasPath(w, tileX-1, tileY) || WorldTileHasPath(w, tileX+1, tileY)
		vertical := WorldTileHasPath(w, tileX, tileY-1) || WorldTileHasPath(w, tileX, tileY+1)
		if !horizontal || !vertical do return
	}
	if WorldHasNearbyStreetLamp(w, tileX, tileY) do return
	WorldDecorationSpawn(
		w,
		PositionFromF32(f32(tileX)+0.5),
		PositionFromF32(f32(tileY)+0.9),
		.Lamp,
		u8(WorldNoiseHashInt(tileY, tileX, 0x1A3C)/250_000),
	)
}

WorldHasNearbyStreetLamp :: proc(w: ^World, x, y: int) -> bool {
	chunkSize := w.spatial.chunkSize
	worldWidth, worldHeight := int(w.maxX), int(w.maxY)
	if chunkSize <= 0 || worldWidth <= 0 || worldHeight <= 0 do return false
	centerX := WorldWrapCoordinate(x, worldWidth)
	centerY := WorldWrapCoordinate(y, worldHeight)
	centerPositionX := d32.FromInt(i32(centerX))
	centerPositionY := d32.FromInt(i32(centerY))
	worldWidthRaw := i64(worldWidth)*d32.SCALE
	worldHeightRaw := i64(worldHeight)*d32.SCALE
	spacingRaw := i64(STREET_LAMP_MIN_SPACING)*d32.SCALE
	spacingSquaredRaw := u64(spacingRaw)*u64(spacingRaw)

	// Wrap tiles before selecting buckets: edge chunks can be shorter than chunkSize.
	for tileX := centerX-STREET_LAMP_MIN_SPACING; tileX <= centerX+STREET_LAMP_MIN_SPACING; {
		wrappedX := WorldWrapCoordinate(tileX, worldWidth)
		chunkX := wrappedX/chunkSize
		for tileY := centerY-STREET_LAMP_MIN_SPACING; tileY <= centerY+STREET_LAMP_MIN_SPACING; {
			wrappedY := WorldWrapCoordinate(tileY, worldHeight)
			chunk := chunkX*w.spatial.chunksY+wrappedY/chunkSize
			for slot := w.spatial.decorationHead[chunk]; slot >= 0; slot = w.spatial.decorationNext[slot] {
				if w.decorations.kind[slot] != .Lamp do continue
				distanceSquared, validDistance := d32.WrappedDistanceSquared(
					w.decorations.x[slot],
					w.decorations.y[slot],
					centerPositionX,
					centerPositionY,
					worldWidthRaw,
					worldHeightRaw,
				)
				if validDistance && distanceSquared < spacingSquaredRaw {
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
		if int(d32.ToInt(w.decorations.x[slot])) == wrappedX &&
			int(d32.ToInt(w.decorations.y[slot])) == wrappedY {
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
	RecursiveLockGuard(&w.unitMutex)
	kind := w.decorations.kind[slot]
	DecorationDebris(
		w,
		PositionToF32(w.decorations.x[slot]),
		PositionToF32(w.decorations.y[slot]),
		kind,
	)
	switch kind {
	case .Tree, .Pine:
		w.decorations.kind[slot] = .Stump
		w.decorations.variant[slot] = 0
		w.decorations.health[slot] = DecorationHealth(.Stump)
		w.decorations.regrowTimer[slot] = d32.ZERO
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

	tileX := int(d32.ToInt(w.decorations.x[slot]))
	tileY := int(d32.ToInt(w.decorations.y[slot]))
	if WorldFireAt(w, tileX, tileY) do return false
	if WorldTileOccupied(w, tileX, tileY) {
		WorldDecorationDespawn(w, slot)
		return false
	}

	w.decorations.regrowTimer[slot] = d32.Add(
		w.decorations.regrowTimer[slot],
		PositionFromF32(deltaTime),
	)
	if w.decorations.regrowTimer[slot] < d32.FromInt(DECORATION_REGROW_SECONDS) do return false

	kind := DecorationKind.Tree
	if WorldNoiseHashInt(tileX, tileY, 0xA11CE) < 350_000 do kind = .Pine
	w.decorations.kind[slot] = kind
	w.decorations.variant[slot] = u8(WorldNoiseHashInt(tileY, tileX, 0xA11CF)/250_000)
	w.decorations.health[slot] = DecorationHealth(kind)
	w.decorations.regrowTimer[slot] = d32.ZERO
	w.decorationStumps -= 1
	return true
}



WorldDecorationClearRect :: proc(w: ^World, x, y, width, height: int) -> d32.Value {
	chunkSize := w.spatial.chunkSize
	if chunkSize <= 0 || width <= 0 || height <= 0 do return d32.ZERO

	harvested := d32.ZERO
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
				decorationX := int(d32.ToInt(w.decorations.x[slot]))
				decorationY := int(d32.ToInt(w.decorations.y[slot]))
				if decorationX >= x && decorationX < x+width &&
					decorationY >= y && decorationY < y+height {
					harvested = d32.Add(harvested, DecorationWoodYield(w.decorations.kind[slot]))
					WorldDecorationDespawn(w, slot)
				}
				slot = next
			}
		}
	}
	return harvested
}

// Splash damage fells trees and brush around the impact; stone takes longer.
WorldDecorationAreaDamage :: proc(w: ^World, x, y: d32.Value, radius: d32.Value, damage: d32.Value) {
	if radius <= d32.ZERO || damage <= d32.ZERO do return
	RecursiveLockGuard(&w.unitMutex)
	chunkSize := w.spatial.chunkSize
	if chunkSize <= 0 do return
	worldWidthRaw := i64(w.maxX)*d32.SCALE
	worldHeightRaw := i64(w.maxY)*d32.SCALE
	centerPositionX, validX := d32.WrapRaw(i64(d32.Raw(x)), d32.ZERO, worldWidthRaw)
	centerPositionY, validY := d32.WrapRaw(i64(d32.Raw(y)), d32.ZERO, worldHeightRaw)
	if !validX || !validY do return
	radiusRaw := i64(d32.Raw(radius))
	radiusSquaredRaw := u64(radiusRaw)*u64(radiusRaw)
	hit := 0

	centerChunkX := int(d32.ToInt(centerPositionX))/chunkSize
	centerChunkY := int(d32.ToInt(centerPositionY))/chunkSize
	chunkRadius := int(d32.ToInt(radius))/chunkSize+1
	for offsetX in -chunkRadius..=chunkRadius {
		chunkX := WorldWrapCoordinate(centerChunkX+offsetX, w.spatial.chunksX)
		for offsetY in -chunkRadius..=chunkRadius {
			chunkY := WorldWrapCoordinate(centerChunkY+offsetY, w.spatial.chunksY)
			chunk := chunkX*w.spatial.chunksY+chunkY
			slot := w.spatial.decorationHead[chunk]
			for slot >= 0 {
				next := w.spatial.decorationNext[slot]
				distanceSquared, validDistance := d32.WrappedDistanceSquared(
					w.decorations.x[slot],
					w.decorations.y[slot],
					centerPositionX,
					centerPositionY,
					worldWidthRaw,
					worldHeightRaw,
				)
				if validDistance && distanceSquared <= radiusSquaredRaw {
					w.decorations.health[slot] = d32.Sub(w.decorations.health[slot], damage)
					hit += 1
					if w.decorations.health[slot] <= d32.ZERO do DecorationFell(w, slot)
				}
				slot = next
			}
		}
	}

	if hit > 0 {
		DecorationBlastBurst(w, PositionToF32(centerPositionX), PositionToF32(centerPositionY), PositionToF32(radius))
	}
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
			roll := WorldNoiseHashInt(x, y, seed+901)
			switch w.ground[x][y].type {
			case .Forest:
				switch {
				case roll < 300_000:
					kind = .Tree
				case roll < 380_000:
					kind = .Pine
				case roll < 400_000:
					kind = .Bush
				case:
					found = false
				}
			case .Taiga:
				switch {
				case roll < 240_000:
					kind = .Pine
				case roll < 340_000:
					kind = .Tree
				case roll < 380_000:
					kind = .Bush
				case:
					found = false
				}
			case .Plains:
				switch {
				case roll < 60_000:
					kind = .Flowers
				case roll < 75_000:
					kind = .Bush
				case:
					found = false
				}
			case .Grassland:
				switch {
				case roll < 12_000:
					kind = .Flowers
				case roll < 20_000:
					kind = .Rock
				case roll < 26_000:
					kind = .Bush
				case:
					found = false
				}
			case .Steppe:
				switch {
				case roll < 18_000:
					kind = .Bush
				case roll < 26_000:
					kind = .Flowers
				case roll < 32_000:
					kind = .Rock
				case:
					found = false
				}
			case .Hill:
				switch {
				case roll < 45_000:
					kind = .Rock
				case roll < 60_000:
					kind = .Pine
				case:
					found = false
				}
			case .Mountain:
				switch {
				case roll < 100_000:
					kind = .Rock
				case:
					found = false
				}
			case .Sand:
				switch {
				case roll < 15_000:
					kind = .Rock
				case roll < 30_000:
					kind = .Reed
				case:
					found = false
				}
			case .Marsh:
				switch {
				case roll < 160_000:
					kind = .Reed
				case roll < 190_000:
					kind = .Bush
				case:
					found = false
				}
			case .Desert:
				switch {
				case roll < 20_000:
					kind = .Cactus
				case roll < 28_000:
					kind = .Rock
				case:
					found = false
				}
			case .Tundra:
				switch {
				case roll < 30_000:
					kind = .Rock
				case:
					found = false
				}
			case .Ash:
				switch {
				case roll < 45_000:
					kind = .Rock
				case:
					found = false
				}
			case .Lake, .River:
				if roll < 20_000 {
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

			variant := u8(WorldNoiseHashInt(y, x, seed+907)/250_000)
			jitterX := 0.15+WorldNoiseHash(x, y, seed+911)*0.7
			jitterY := 0.86+WorldNoiseHash(y, x, seed+913)*0.12
			WorldDecorationSpawn(
				w,
				PositionFromF32(f32(x)+jitterX),
				PositionFromF32(f32(y)+jitterY),
				kind,
				variant,
			)
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
