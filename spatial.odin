package main

// Units live in 16x16 tile buckets so proximity queries only visit the
// neighbourhood instead of every unit in the world.
SPATIAL_CHUNK_SIZE :: 16

SpatialIndex :: struct {
	chunkSize:        int,
	chunksX, chunksY: int,
	unitHead:         []int,
	unitNext:         [UNIT_CAPACITY]int,
	unitPrev:         [UNIT_CAPACITY]int,
	unitChunk:        [UNIT_CAPACITY]int,
	buildingHead:     []int,
	buildingNext:     [BUILDING_CAPACITY]int,
	buildingChunk:    [BUILDING_CAPACITY]int,
	decorationHead:   []int,
	decorationNext:   [DECORATION_CAPACITY]int,
	decorationPrev:   [DECORATION_CAPACITY]int,
	decorationChunk:  [DECORATION_CAPACITY]int,
	fireHead:         []int,
	fireNext:         [FIRE_CAPACITY]int,
	firePrev:         [FIRE_CAPACITY]int,
	fireChunk:        [FIRE_CAPACITY]int,
	presentKingdoms:  []u8, // Kingdom bitmask with visible units per chunk
	presentStamp:     []u32, // Tick the presence bitmask was computed for
	buildingKingdoms: []u8, // Kingdom bitmask with buildings per chunk
	buildingStamp:    []u32, // Tick the building bitmask was computed for
	presentRevision:  u32,
	enemyMask:        [KINGDOMS_CAPACITY]u8,
	enemyMaskRevision: u32,
}

SpatialIndexInit :: proc(w: ^World) -> bool {
	if w.maxX == 0 || w.maxY == 0 do return false

	w.spatial.chunkSize = SPATIAL_CHUNK_SIZE
	w.spatial.chunksX = (int(w.maxX)+SPATIAL_CHUNK_SIZE-1)/SPATIAL_CHUNK_SIZE
	w.spatial.chunksY = (int(w.maxY)+SPATIAL_CHUNK_SIZE-1)/SPATIAL_CHUNK_SIZE
	chunkCount := w.spatial.chunksX*w.spatial.chunksY
	w.spatial.unitHead = make([]int, chunkCount)
	w.spatial.buildingHead = make([]int, chunkCount)
	w.spatial.decorationHead = make([]int, chunkCount)
	w.spatial.fireHead = make([]int, chunkCount)
	w.spatial.presentKingdoms = make([]u8, chunkCount)
	w.spatial.presentStamp = make([]u32, chunkCount)
	w.spatial.buildingKingdoms = make([]u8, chunkCount)
	w.spatial.buildingStamp = make([]u32, chunkCount)
	w.spatial.presentRevision = 1
	for i in 0..<chunkCount {
		w.spatial.unitHead[i] = -1
		w.spatial.buildingHead[i] = -1
		w.spatial.decorationHead[i] = -1
		w.spatial.fireHead[i] = -1
	}
	for i in 0..<UNIT_CAPACITY {
		w.spatial.unitNext[i] = -1
		w.spatial.unitPrev[i] = -1
		w.spatial.unitChunk[i] = -1
	}
	for i in 0..<BUILDING_CAPACITY {
		w.spatial.buildingNext[i] = -1
		w.spatial.buildingChunk[i] = -1
	}
	for i in 0..<DECORATION_CAPACITY {
		w.spatial.decorationNext[i] = -1
		w.spatial.decorationPrev[i] = -1
		w.spatial.decorationChunk[i] = -1
	}
	for i in 0..<FIRE_CAPACITY {
		w.spatial.fireNext[i] = -1
		w.spatial.firePrev[i] = -1
		w.spatial.fireChunk[i] = -1
	}
	return true
}

SpatialIndexDeinit :: proc(w: ^World) {
	delete(w.spatial.unitHead)
	delete(w.spatial.buildingHead)
	delete(w.spatial.decorationHead)
	delete(w.spatial.fireHead)
	delete(w.spatial.presentKingdoms)
	delete(w.spatial.presentStamp)
	delete(w.spatial.buildingKingdoms)
	delete(w.spatial.buildingStamp)
}

SpatialChunkIndex :: proc(w: ^World, x, y: int) -> int {
	if w.spatial.chunkSize <= 0 || w.spatial.chunksX <= 0 || w.spatial.chunksY <= 0 {
		return -1
	}
	wrappedX := WorldWrapCoordinate(x, int(w.maxX))
	wrappedY := WorldWrapCoordinate(y, int(w.maxY))
	chunkX := wrappedX/w.spatial.chunkSize
	chunkY := wrappedY/w.spatial.chunkSize
	return chunkX*w.spatial.chunksY+chunkY
}

SpatialUnitChunk :: proc(w: ^World, unitSlot: int) -> int {
	x := int(WorldWrapPosition(w.units.x[unitSlot], f32(w.maxX)))
	y := int(WorldWrapPosition(w.units.y[unitSlot], f32(w.maxY)))
	return SpatialChunkIndex(w, x, y)
}

SpatialUnitLink :: proc(w: ^World, unitSlot, chunk: int) {
	RecursiveLockGuard(&w.spatialMutex)
	head := w.spatial.unitHead[chunk]
	w.spatial.unitNext[unitSlot] = head
	w.spatial.unitPrev[unitSlot] = -1
	if head >= 0 do w.spatial.unitPrev[head] = unitSlot
	w.spatial.unitHead[chunk] = unitSlot
	w.spatial.unitChunk[unitSlot] = chunk
	if len(w.spatial.presentStamp) > 0 do w.spatial.presentStamp[chunk] = 0
}

SpatialUnitUnlink :: proc(w: ^World, unitSlot: int) {
	RecursiveLockGuard(&w.spatialMutex)
	chunk := w.spatial.unitChunk[unitSlot]
	if chunk < 0 do return
	previous := w.spatial.unitPrev[unitSlot]
	next := w.spatial.unitNext[unitSlot]
	if previous >= 0 {
		w.spatial.unitNext[previous] = next
	} else {
		w.spatial.unitHead[chunk] = next
	}
	if next >= 0 do w.spatial.unitPrev[next] = previous
	w.spatial.unitNext[unitSlot] = -1
	w.spatial.unitPrev[unitSlot] = -1
	w.spatial.unitChunk[unitSlot] = -1
	if len(w.spatial.presentStamp) > 0 do w.spatial.presentStamp[chunk] = 0
}

SpatialUnitInsert :: proc(w: ^World, unitSlot: int) {
	chunk := SpatialUnitChunk(w, unitSlot)
	if chunk < 0 do return
	SpatialUnitLink(w, unitSlot, chunk)
}

SpatialUnitRemove :: proc(w: ^World, unitSlot: int) {
	SpatialUnitUnlink(w, unitSlot)
}

SpatialUnitMove :: proc(w: ^World, unitSlot: int) {
	chunk := SpatialUnitChunk(w, unitSlot)
	if chunk < 0 || chunk == w.spatial.unitChunk[unitSlot] do return
	SpatialUnitUnlink(w, unitSlot)
	SpatialUnitLink(w, unitSlot, chunk)
}

// The presence bitmask is refreshed lazily once per simulation tick. Any unit
// entering or leaving a chunk invalidates only that chunk.
SpatialCacheBeginTick :: proc(w: ^World) {
	w.spatial.presentRevision += 1
	if w.spatial.presentRevision == 0 {
		for &stamp in w.spatial.presentStamp do stamp = 0
		w.spatial.presentRevision = 1
	}
	w.spatial.enemyMaskRevision = 0
}

SpatialChunkPresent :: proc(w: ^World, chunk: int) -> u8 {
	if chunk < 0 || chunk >= len(w.spatial.presentKingdoms) do return 0
	if w.spatial.presentStamp[chunk] == w.spatial.presentRevision {
		return w.spatial.presentKingdoms[chunk]
	}
	mask: u8
	for slot := w.spatial.unitHead[chunk]; slot >= 0; slot = w.spatial.unitNext[slot] {
		if !w.unitUsed[slot] || w.units.health[slot] <= 0 do continue
		if UnitHiddenInside(w, slot) do continue
		kingdom := w.units.kingdome[slot]
		if kingdom >= 0 && kingdom < KINGDOMS_CAPACITY do mask |= u8(1)<<u8(kingdom)
	}
	w.spatial.presentKingdoms[chunk] = mask
	w.spatial.presentStamp[chunk] = w.spatial.presentRevision
	return mask
}

SpatialEnemyMask :: proc(w: ^World, kingdom: int) -> u8 {
	if kingdom < 0 || kingdom >= KINGDOMS_CAPACITY do return 0
	if w.spatial.enemyMaskRevision != w.spatial.presentRevision {
		for k in 0..<KINGDOMS_CAPACITY {
			mask: u8
			if w.kingdomUsed[k] {
				for other in 0..<KINGDOMS_CAPACITY {
					if other != k && w.kingdomUsed[other] && KingdomAtWar(w, k, other) {
						mask |= u8(1)<<u8(other)
					}
				}
			}
			w.spatial.enemyMask[k] = mask
		}
		w.spatial.enemyMaskRevision = w.spatial.presentRevision
	}
	return w.spatial.enemyMask[kingdom]
}

SpatialChunkHasEnemy :: proc(w: ^World, chunk: int, kingdom: int) -> bool {
	return SpatialChunkPresent(w, chunk) & SpatialEnemyMask(w, kingdom) != 0
}

// Buildings are linked by their top-left tile. Queries widen the chunk range
// by one, which covers every possible footprint (buildings are at most 4x4).
SpatialBuildingInsert :: proc(w: ^World, buildingSlot: int) {
	chunk := SpatialChunkIndex(w, w.buildings.x[buildingSlot], w.buildings.y[buildingSlot])
	if chunk < 0 do return
	w.spatial.buildingChunk[buildingSlot] = chunk
	w.spatial.buildingNext[buildingSlot] = w.spatial.buildingHead[chunk]
	w.spatial.buildingHead[chunk] = buildingSlot
	w.spatial.buildingStamp[chunk] = 0
}

SpatialBuildingRemove :: proc(w: ^World, buildingSlot: int) {
	chunk := w.spatial.buildingChunk[buildingSlot]
	if chunk < 0 do return
	head := w.spatial.buildingHead[chunk]
	if head == buildingSlot {
		w.spatial.buildingHead[chunk] = w.spatial.buildingNext[buildingSlot]
	} else {
		cursor := head
		for cursor >= 0 {
			next := w.spatial.buildingNext[cursor]
			if next == buildingSlot {
				w.spatial.buildingNext[cursor] = w.spatial.buildingNext[buildingSlot]
				break
			}
			cursor = next
		}
	}
	w.spatial.buildingNext[buildingSlot] = -1
	w.spatial.buildingChunk[buildingSlot] = -1
	w.spatial.buildingStamp[chunk] = 0
}

// Kingdom bitmask of the buildings in one chunk, refreshed once per tick.
SpatialChunkBuildingPresent :: proc(w: ^World, chunk: int) -> u8 {
	if chunk < 0 || chunk >= len(w.spatial.buildingKingdoms) do return 0
	if w.spatial.buildingStamp[chunk] == w.spatial.presentRevision {
		return w.spatial.buildingKingdoms[chunk]
	}
	mask: u8
	for slot := w.spatial.buildingHead[chunk]; slot >= 0; slot = w.spatial.buildingNext[slot] {
		if !w.buildingUsed[slot] do continue
		kingdom := w.buildings.kingdom[slot]
		if kingdom >= 0 && kingdom < KINGDOMS_CAPACITY do mask |= u8(1)<<u8(kingdom)
	}
	w.spatial.buildingKingdoms[chunk] = mask
	w.spatial.buildingStamp[chunk] = w.spatial.presentRevision
	return mask
}

// Decorations are static, so they are linked by their base tile and are never
// moved between chunks.
SpatialDecorationInsert :: proc(w: ^World, decorationSlot: int) {
	chunk := SpatialChunkIndex(
		w,
		int(w.decorations.x[decorationSlot]),
		int(w.decorations.y[decorationSlot]),
	)
	if chunk < 0 do return
	head := w.spatial.decorationHead[chunk]
	w.spatial.decorationNext[decorationSlot] = head
	w.spatial.decorationPrev[decorationSlot] = -1
	if head >= 0 do w.spatial.decorationPrev[head] = decorationSlot
	w.spatial.decorationHead[chunk] = decorationSlot
	w.spatial.decorationChunk[decorationSlot] = chunk
}

SpatialDecorationRemove :: proc(w: ^World, decorationSlot: int) {
	chunk := w.spatial.decorationChunk[decorationSlot]
	if chunk < 0 do return
	previous := w.spatial.decorationPrev[decorationSlot]
	next := w.spatial.decorationNext[decorationSlot]
	if previous >= 0 {
		w.spatial.decorationNext[previous] = next
	} else {
		w.spatial.decorationHead[chunk] = next
	}
	if next >= 0 do w.spatial.decorationPrev[next] = previous
	w.spatial.decorationNext[decorationSlot] = -1
	w.spatial.decorationPrev[decorationSlot] = -1
	w.spatial.decorationChunk[decorationSlot] = -1
}

SpatialFireInsert :: proc(w: ^World, fireSlot: int) {
	chunk := SpatialChunkIndex(w, int(w.fires.x[fireSlot]), int(w.fires.y[fireSlot]))
	if chunk < 0 do return
	head := w.spatial.fireHead[chunk]
	w.spatial.fireNext[fireSlot] = head
	w.spatial.firePrev[fireSlot] = -1
	if head >= 0 do w.spatial.firePrev[head] = fireSlot
	w.spatial.fireHead[chunk] = fireSlot
	w.spatial.fireChunk[fireSlot] = chunk
}

SpatialFireRemove :: proc(w: ^World, fireSlot: int) {
	chunk := w.spatial.fireChunk[fireSlot]
	if chunk < 0 do return
	previous := w.spatial.firePrev[fireSlot]
	next := w.spatial.fireNext[fireSlot]
	if previous >= 0 {
		w.spatial.fireNext[previous] = next
	} else {
		w.spatial.fireHead[chunk] = next
	}
	if next >= 0 do w.spatial.firePrev[next] = previous
	w.spatial.fireNext[fireSlot] = -1
	w.spatial.firePrev[fireSlot] = -1
	w.spatial.fireChunk[fireSlot] = -1
}

WorldUnitAtTile :: proc(w: ^World, x, y: int) -> bool {
	chunk := SpatialChunkIndex(w, x, y)
	if chunk < 0 do return false
	for unitSlot := w.spatial.unitHead[chunk]; unitSlot >= 0;
		unitSlot = w.spatial.unitNext[unitSlot] {
		unitX := int(WorldWrapPosition(w.units.x[unitSlot], f32(w.maxX)))
		unitY := int(WorldWrapPosition(w.units.y[unitSlot], f32(w.maxY)))
		if unitX == x && unitY == y do return true
	}
	return false
}
