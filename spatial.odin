package main

// Units live in 16x16 tile buckets so proximity queries only visit the
// neighbourhood instead of every unit in the world.
SPATIAL_CHUNK_SIZE :: 16

SpatialIndex :: struct {
	chunkSize: int,
	chunksX, chunksY: int,
	unitHead: []int,
	unitNext: [UNIT_CAPACITY]int,
	unitPrev: [UNIT_CAPACITY]int,
	unitChunk: [UNIT_CAPACITY]int,
	buildingHead: []int,
	buildingNext: [BUILDING_CAPACITY]int,
	buildingChunk: [BUILDING_CAPACITY]int,
}

SpatialIndexInit :: proc(w: ^World) -> bool {
	if w.maxX == 0 || w.maxY == 0 do return false

	w.spatial.chunkSize = SPATIAL_CHUNK_SIZE
	w.spatial.chunksX = (int(w.maxX)+SPATIAL_CHUNK_SIZE-1)/SPATIAL_CHUNK_SIZE
	w.spatial.chunksY = (int(w.maxY)+SPATIAL_CHUNK_SIZE-1)/SPATIAL_CHUNK_SIZE
	chunk_count := w.spatial.chunksX*w.spatial.chunksY
	w.spatial.unitHead = make([]int, chunk_count)
	w.spatial.buildingHead = make([]int, chunk_count)
	for i in 0..<chunk_count {
		w.spatial.unitHead[i] = -1
		w.spatial.buildingHead[i] = -1
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
	return true
}

SpatialIndexDeinit :: proc(w: ^World) {
	delete(w.spatial.unitHead)
	delete(w.spatial.buildingHead)
}

SpatialChunkIndex :: proc(w: ^World, x, y: int) -> int {
	if w.spatial.chunkSize <= 0 || w.spatial.chunksX <= 0 || w.spatial.chunksY <= 0 {
		return -1
	}
	wrapped_x := WorldWrapCoordinate(x, int(w.maxX))
	wrapped_y := WorldWrapCoordinate(y, int(w.maxY))
	chunk_x := wrapped_x/w.spatial.chunkSize
	chunk_y := wrapped_y/w.spatial.chunkSize
	return chunk_x*w.spatial.chunksY+chunk_y
}

SpatialUnitChunk :: proc(w: ^World, unit_slot: int) -> int {
	x := int(WorldWrapPosition(w.units.x[unit_slot], f32(w.maxX)))
	y := int(WorldWrapPosition(w.units.y[unit_slot], f32(w.maxY)))
	return SpatialChunkIndex(w, x, y)
}

SpatialUnitLink :: proc(w: ^World, unit_slot, chunk: int) {
	head := w.spatial.unitHead[chunk]
	w.spatial.unitNext[unit_slot] = head
	w.spatial.unitPrev[unit_slot] = -1
	if head >= 0 do w.spatial.unitPrev[head] = unit_slot
	w.spatial.unitHead[chunk] = unit_slot
	w.spatial.unitChunk[unit_slot] = chunk
}

SpatialUnitUnlink :: proc(w: ^World, unit_slot: int) {
	chunk := w.spatial.unitChunk[unit_slot]
	if chunk < 0 do return
	previous := w.spatial.unitPrev[unit_slot]
	next := w.spatial.unitNext[unit_slot]
	if previous >= 0 {
		w.spatial.unitNext[previous] = next
	} else {
		w.spatial.unitHead[chunk] = next
	}
	if next >= 0 do w.spatial.unitPrev[next] = previous
	w.spatial.unitNext[unit_slot] = -1
	w.spatial.unitPrev[unit_slot] = -1
	w.spatial.unitChunk[unit_slot] = -1
}

SpatialUnitInsert :: proc(w: ^World, unit_slot: int) {
	chunk := SpatialUnitChunk(w, unit_slot)
	if chunk < 0 do return
	SpatialUnitLink(w, unit_slot, chunk)
}

SpatialUnitRemove :: proc(w: ^World, unit_slot: int) {
	SpatialUnitUnlink(w, unit_slot)
}

SpatialUnitMove :: proc(w: ^World, unit_slot: int) {
	chunk := SpatialUnitChunk(w, unit_slot)
	if chunk < 0 || chunk == w.spatial.unitChunk[unit_slot] do return
	SpatialUnitUnlink(w, unit_slot)
	SpatialUnitLink(w, unit_slot, chunk)
}

// Buildings are linked by their top-left tile. Queries widen the chunk range
// by one, which covers every possible footprint (buildings are at most 4x4).
SpatialBuildingInsert :: proc(w: ^World, building_slot: int) {
	chunk := SpatialChunkIndex(w, w.buildings.x[building_slot], w.buildings.y[building_slot])
	if chunk < 0 do return
	w.spatial.buildingChunk[building_slot] = chunk
	w.spatial.buildingNext[building_slot] = w.spatial.buildingHead[chunk]
	w.spatial.buildingHead[chunk] = building_slot
}

SpatialBuildingRemove :: proc(w: ^World, building_slot: int) {
	chunk := w.spatial.buildingChunk[building_slot]
	if chunk < 0 do return
	head := w.spatial.buildingHead[chunk]
	if head == building_slot {
		w.spatial.buildingHead[chunk] = w.spatial.buildingNext[building_slot]
	} else {
		cursor := head
		for cursor >= 0 {
			next := w.spatial.buildingNext[cursor]
			if next == building_slot {
				w.spatial.buildingNext[cursor] = w.spatial.buildingNext[building_slot]
				break
			}
			cursor = next
		}
	}
	w.spatial.buildingNext[building_slot] = -1
	w.spatial.buildingChunk[building_slot] = -1
}

WorldUnitAtTile :: proc(w: ^World, x, y: int) -> bool {
	chunk := SpatialChunkIndex(w, x, y)
	if chunk < 0 do return false
	for unit_slot := w.spatial.unitHead[chunk]; unit_slot >= 0;
		unit_slot = w.spatial.unitNext[unit_slot] {
		unit_x := int(WorldWrapPosition(w.units.x[unit_slot], f32(w.maxX)))
		unit_y := int(WorldWrapPosition(w.units.y[unit_slot], f32(w.maxY)))
		if unit_x == x && unit_y == y do return true
	}
	return false
}
