package main

import rl "vendor:raylib"
import "core:slice"
import "d32"

// Terrain memory is observer-only. Contact uses every kingdom's actual
// vision, independently of who is observing or controlling the game.
FOG_NONE :: u8(255)

FOG_FLAG_CONSTRUCTION :: u8(1 << 0)
FOG_FLAG_BURNING :: u8(1 << 1)

FOG_VISIBLE_COLOR :: rl.Color{0, 0, 0, 0}
FOG_EXPLORED_COLOR :: rl.Color{62, 68, 82, 140}
FOG_UNEXPLORED_COLOR :: rl.Color{25, 29, 40, 255}
FOG_MEMORY_TINT :: rl.Color{190, 194, 200, 255}

// Own towns always keep an extra ring of vision around their whole area so
// large attacks can be seen coming.
FOG_TOWN_AREA_VISION_FACTOR :: 1.5
FOG_RENDER_CHUNK_TILES :: 32
// Vision changes slowly; rebuilding it less often keeps reveal and contact
// latency well under a second at the simulation step.
FOG_UPDATE_INTERVAL :: 4

FogOfWar :: struct {
	visible:  []bool,
	explored: []bool,

	// Persistent mutual contact. Contact does not reveal the other kingdom's
	// towns or share its map exploration.
	contacts: [KINGDOMS_CAPACITY][KINGDOMS_CAPACITY]bool,

	// Per-tile memory of what was last seen. Building data lives at the
	// building's top-left anchor tile; every footprint tile points at it, so a
	// remembered building can still be hit-tested anywhere on its footprint.
	buildingKind:        []u8,
	buildingFlags:       []u8,
	buildingKingdom:     []u8,
	buildingTown:        []u8,
	buildingAnchor:      []int,
	buildingGhostIndex:  []int,
	ghosts:              [dynamic]int,
	decorationKind:      []u8,
	decorationVariant:   []u8,
	decorationOffsetX:   []u8,
	decorationOffsetY:   []u8,
	enemyAlerted:        [KINGDOMS_CAPACITY]bool,

	visibleTiles:        [dynamic]int,
	allVisible:          bool, // Spectator omniscience already applied
	dirtyChunks:         [dynamic]int,
	dirtyChunkFlags:     []bool,
	dirtyChunkCountY:    int,
}

FogInit :: proc(w: ^World) -> bool {
	count := int(w.maxX)*int(w.maxY)
	if count <= 0 do return false

	#assert(KINGDOMS_CAPACITY <= 8)
	w.fog.contacts = {}
	w.fog.visible = make([]bool, count)
	w.fog.explored = make([]bool, count)
	w.fog.buildingKind = make([]u8, count)
	w.fog.buildingFlags = make([]u8, count)
	w.fog.buildingKingdom = make([]u8, count)
	w.fog.buildingTown = make([]u8, count)
	w.fog.buildingAnchor = make([]int, count)
	w.fog.buildingGhostIndex = make([]int, count)
	w.fog.decorationKind = make([]u8, count)
	w.fog.decorationVariant = make([]u8, count)
	w.fog.decorationOffsetX = make([]u8, count)
	w.fog.decorationOffsetY = make([]u8, count)
	w.fog.visibleTiles = make([dynamic]int, 0, 4096)
	w.fog.ghosts = make([dynamic]int, 0, 64)
	chunksX := (int(w.maxX)+FOG_RENDER_CHUNK_TILES-1)/FOG_RENDER_CHUNK_TILES
	chunksY := (int(w.maxY)+FOG_RENDER_CHUNK_TILES-1)/FOG_RENDER_CHUNK_TILES
	w.fog.dirtyChunkCountY = chunksY
	w.fog.dirtyChunkFlags = make([]bool, chunksX*chunksY)
	w.fog.dirtyChunks = make([dynamic]int, 0, 64)

	for i in 0..<count {
		w.fog.buildingKind[i] = FOG_NONE
		w.fog.buildingKingdom[i] = FOG_NONE
		w.fog.buildingTown[i] = FOG_NONE
		w.fog.buildingAnchor[i] = -1
		w.fog.buildingGhostIndex[i] = -1
		w.fog.decorationKind[i] = FOG_NONE
	}
	return true
}

FogDeinit :: proc(w: ^World) {
	delete(w.fog.visible)
	delete(w.fog.explored)
	delete(w.fog.buildingKind)
	delete(w.fog.buildingFlags)
	delete(w.fog.buildingKingdom)
	delete(w.fog.buildingTown)
	delete(w.fog.buildingAnchor)
	delete(w.fog.buildingGhostIndex)
	delete(w.fog.ghosts)
	delete(w.fog.decorationKind)
	delete(w.fog.decorationVariant)
	delete(w.fog.decorationOffsetX)
	delete(w.fog.decorationOffsetY)
	delete(w.fog.visibleTiles)
	delete(w.fog.dirtyChunkFlags)
	delete(w.fog.dirtyChunks)
	w.fog = {}
}

FogTileIndex :: proc(w: ^World, x, y: int) -> int {
	width := int(w.maxX)
	height := int(w.maxY)
	if width <= 0 || height <= 0 do return -1
	wrappedX := WorldWrapCoordinate(x, width)
	wrappedY := WorldWrapCoordinate(y, height)
	return wrappedX*height+wrappedY
}

FogTileVisible :: proc(w: ^World, x, y: int) -> bool {
	index := FogTileIndex(w, x, y)
	if index < 0 || index >= len(w.fog.visible) do return false
	return w.fog.visible[index]
}

FogTileVisibleIndex :: proc(w: ^World, index: int) -> bool {
	return index >= 0 && index < len(w.fog.visible) && w.fog.visible[index]
}

FogTileExplored :: proc(w: ^World, x, y: int) -> bool {
	index := FogTileIndex(w, x, y)
	if index < 0 || index >= len(w.fog.explored) do return false
	return w.fog.explored[index]
}

FogRectVisible :: proc(w: ^World, x, y, width, height: int) -> bool {
	for tileX in x ..< x+width {
		for tileY in y ..< y+height {
			if FogTileVisible(w, tileX, tileY) do return true
		}
	}
	return false
}

FogRectExplored :: proc(w: ^World, x, y, width, height: int) -> bool {
	for tileX in x ..< x+width {
		for tileY in y ..< y+height {
			if !FogTileExplored(w, tileX, tileY) do return false
		}
	}
	return true
}

FogUnitVisible :: proc(w: ^World, unitSlot: int) -> bool {
	if unitSlot < 0 || unitSlot >= UNIT_CAPACITY || !w.unitUsed[unitSlot] do return false
	if UnitHiddenInside(w, unitSlot) do return false
	if w.observerKingdom < 0 do return true
	if w.units[unitSlot].kingdome == w.observerKingdom do return true
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 do return false
	x := UnitTileX(w, unitSlot)
	y := UnitTileY(w, unitSlot)
	return FogTileVisible(w, x, y)
}

FogBuildingVisible :: proc(w: ^World, buildingSlot: int) -> bool {
	if buildingSlot < 0 || buildingSlot >= BUILDING_CAPACITY || !w.buildingUsed[buildingSlot] {
		return false
	}
	if w.observerKingdom < 0 do return true
	if w.buildings[buildingSlot].kingdom == w.observerKingdom do return true
	width, height := BuildingTileSize(w.buildings[buildingSlot].type)
	return FogRectVisible(
		w,
		w.buildings[buildingSlot].x,
		w.buildings[buildingSlot].y,
		width,
		height,
	)
}

FogTownDiscovered :: proc(w: ^World, kingdomSlot, townSlot: int) -> bool {
	if !WorldTownExists(w, kingdomSlot, townSlot) do return false
	hall := TownHallSlot(w, kingdomSlot, townSlot)
	if hall < 0 do return false
	return FogTileExplored(w, w.buildings[hall].x, w.buildings[hall].y)
}

FogTownVisible :: proc(w: ^World, kingdomSlot, townSlot: int) -> bool {
	if !WorldTownExists(w, kingdomSlot, townSlot) do return false
	hall := TownHallSlot(w, kingdomSlot, townSlot)
	if hall < 0 do return false
	return FogBuildingVisible(w, hall)
}

KingdomDiscovered :: proc(w: ^World, kingdomSlot: int) -> bool {
	if kingdomSlot < 0 || kingdomSlot >= KINGDOMS_CAPACITY || !w.kingdomUsed[kingdomSlot] {
		return false
	}
	if w.observerKingdom < 0 do return true
	if kingdomSlot == w.observerKingdom do return true
	return KingdomsMet(w, w.observerKingdom, kingdomSlot)
}

FogFirstDiscoveredTown :: proc(w: ^World, kingdomSlot: int) -> (int, bool) {
	if kingdomSlot < 0 || kingdomSlot >= KINGDOMS_CAPACITY || !w.kingdomUsed[kingdomSlot] {
		return -1, false
	}
	for townSlot in 0..<TOWN_CAPACITY {
		if !w.kingdoms[kingdomSlot].townUsed[townSlot] do continue
		if FogTownDiscovered(w, kingdomSlot, townSlot) do return townSlot, true
	}
	return -1, false
}

// Resolves a remembered town hall under the cursor. Used by attack/defend
// orders so discovered-but-fogged towns remain valid targets.
FogFindTownAt :: proc(w: ^World, tileX, tileY: int) -> (kingdom, town: int, found: bool) {
	index := FogTileIndex(w, tileX, tileY)
	if index < 0 || index >= len(w.fog.buildingAnchor) do return -1, -1, false
	anchor := w.fog.buildingAnchor[index]
	if anchor < 0 || anchor >= len(w.fog.buildingKind) do return -1, -1, false
	if w.fog.buildingKind[anchor] == FOG_NONE do return -1, -1, false
	if w.fog.buildingFlags[anchor]&FOG_FLAG_CONSTRUCTION != 0 do return -1, -1, false

	kingdom = int(w.fog.buildingKingdom[anchor])
	town = int(w.fog.buildingTown[anchor])
	if kingdom < 0 || kingdom >= KINGDOM_SLOTS || town < 0 || town >= TOWN_CAPACITY {
		return -1, -1, false
	}
	if !WorldTownExists(w, kingdom, town) do return -1, -1, false
	return kingdom, town, true
}

FogDirtyMarkIndex :: proc(w: ^World, index: int) {
	if len(w.fog.dirtyChunkFlags) == 0 || w.fog.dirtyChunkCountY <= 0 do return
	if index < 0 || index >= len(w.fog.visible) do return
	height := int(w.maxY)
	x := index/height
	y := index%height
	chunk := (x/FOG_RENDER_CHUNK_TILES)*w.fog.dirtyChunkCountY +
		y/FOG_RENDER_CHUNK_TILES
	if w.fog.dirtyChunkFlags[chunk] do return
	w.fog.dirtyChunkFlags[chunk] = true
	append(&w.fog.dirtyChunks, chunk)
}

FogDirtyMarkAll :: proc(w: ^World) {
	for chunk in 0..<len(w.fog.dirtyChunkFlags) {
		if w.fog.dirtyChunkFlags[chunk] do continue
		w.fog.dirtyChunkFlags[chunk] = true
		append(&w.fog.dirtyChunks, chunk)
	}
}

FogDirtyClear :: proc(w: ^World) {
	for chunk in w.fog.dirtyChunks do w.fog.dirtyChunkFlags[chunk] = false
	clear(&w.fog.dirtyChunks)
}

FogMarkVisibleIndex :: proc(w: ^World, index: int) {
	if index < 0 || index >= len(w.fog.visible) do return
	changed := !w.fog.visible[index] || !w.fog.explored[index]
	if !w.fog.visible[index] {
		w.fog.visible[index] = true
		append(&w.fog.visibleTiles, index)
	}
	w.fog.explored[index] = true
	if changed do FogDirtyMarkIndex(w, index)
}

// A kingdom source reveals fog for the observer only. Kingdom contact is
// resolved separately from the spatial masks.
FogRevealCircle :: proc(
	w: ^World,
	centerX, centerY: int,
	radius: d32.Value,
	kingdom: int = -1,
) {
	if radius <= d32.ZERO do return
	if kingdom >= 0 && (kingdom >= KINGDOMS_CAPACITY || !w.kingdomUsed[kingdom]) do return
	if kingdom >= 0 && kingdom != w.observerKingdom do return

	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 do return

	radiusRaw := i64(d32.Raw(radius))
	radiusSquared := u64(radiusRaw)*u64(radiusRaw)
	extent := int(d32.ToInt(radius))+1
	// Tiles are addressed as x*worldHeight+y, so walking one column at a time
	// keeps the writes contiguous. The row-major walk used to touch a fresh
	// cache line for every tile, which dominated town-area reveals.
	for offsetX in -extent..=extent {
		offsetRaw := i64(offsetX)*d32.SCALE
		distanceSquared := u64(offsetRaw*offsetRaw)
		if distanceSquared > radiusSquared do continue
		halfHeight := int(d32.SqrtRaw(radiusSquared-distanceSquared)/d32.SCALE)
		wrappedX := WorldWrapCoordinate(centerX+offsetX, worldWidth)
		base := wrappedX*worldHeight
		for offsetY in -halfHeight..=halfHeight {
			FogMarkVisibleIndex(w, base+WorldWrapCoordinate(centerY+offsetY, worldHeight))
		}
	}
}

FogRevealRect :: proc(w: ^World, x, y, width, height: int) {
	for tileX in x ..< x+width {
		for tileY in y ..< y+height {
			FogMarkVisibleIndex(w, FogTileIndex(w, tileX, tileY))
		}
	}
}

FogClearTileMemory :: proc(w: ^World, index: int) {
	if index < 0 || index >= len(w.fog.buildingAnchor) do return
	anchor := w.fog.buildingAnchor[index]
	w.fog.buildingAnchor[index] = -1
	if anchor == index {
		w.fog.buildingKind[index] = FOG_NONE
		w.fog.buildingFlags[index] = 0
		w.fog.buildingKingdom[index] = FOG_NONE
		w.fog.buildingTown[index] = FOG_NONE
	}
	w.fog.decorationKind[index] = FOG_NONE
	w.fog.decorationVariant[index] = 0
	w.fog.decorationOffsetX[index] = 0
	w.fog.decorationOffsetY[index] = 0
}

FogGhostAdd :: proc(w: ^World, anchor: int) {
	if anchor < 0 || anchor >= len(w.fog.buildingGhostIndex) do return
	if w.fog.buildingGhostIndex[anchor] >= 0 do return
	append(&w.fog.ghosts, anchor)
	w.fog.buildingGhostIndex[anchor] = len(w.fog.ghosts)-1
}

FogGhostRemove :: proc(w: ^World, anchor: int) {
	if anchor < 0 || anchor >= len(w.fog.buildingGhostIndex) do return
	index := w.fog.buildingGhostIndex[anchor]
	if index < 0 || index >= len(w.fog.ghosts) do return
	last := len(w.fog.ghosts)-1
	if index != last {
		moved := w.fog.ghosts[last]
		w.fog.ghosts[index] = moved
		w.fog.buildingGhostIndex[moved] = index
	}
	pop(&w.fog.ghosts)
	w.fog.buildingGhostIndex[anchor] = -1
}

FogBuildingDespawn :: proc(w: ^World, buildingSlot: int) {
	if buildingSlot < 0 || buildingSlot >= BUILDING_CAPACITY || !w.buildingUsed[buildingSlot] {
		return
	}
	building := &w.buildings[buildingSlot]
	width, height := BuildingTileSize(building.type)
	anchor := FogTileIndex(w, building.x, building.y)
	if anchor < 0 do return

	if FogRectVisible(w, building.x, building.y, width, height) ||
		building.kingdom == w.observerKingdom {
		for tileX in building.x ..< building.x+width {
			for tileY in building.y ..< building.y+height {
				index := FogTileIndex(w, tileX, tileY)
				if index >= 0 do w.fog.buildingAnchor[index] = -1
			}
		}
		FogClearTileMemory(w, anchor)
		FogGhostRemove(w, anchor)
	} else if w.fog.buildingKind[anchor] != FOG_NONE {
		FogGhostAdd(w, anchor)
	}
}

FogDecorationDespawn :: proc(w: ^World, decorationSlot: int) {
	if decorationSlot < 0 || decorationSlot >= DECORATION_CAPACITY ||
		!w.decorationUsed[decorationSlot] {
		return
	}
	index := FogTileIndex(
		w,
		int(d32.ToInt(w.decorations.x[decorationSlot])),
		int(d32.ToInt(w.decorations.y[decorationSlot])),
	)
	if index < 0 || index >= len(w.fog.decorationKind) do return
	if w.fog.visible[index] {
		w.fog.decorationKind[index] = FOG_NONE
		w.fog.decorationVariant[index] = 0
	}
}

FogBuildingBurning :: proc(w: ^World, buildingSlot: int) -> bool {
	building := &w.buildings[buildingSlot]
	width, height := BuildingTileSize(building.type)
	for tileX in building.x ..< building.x+width {
		for tileY in building.y ..< building.y+height {
			if WorldFireAt(w, tileX, tileY) do return true
		}
	}
	return false
}

FogSnapshotBuilding :: proc(w: ^World, buildingSlot: int) {
	building := &w.buildings[buildingSlot]
	width, height := BuildingTileSize(building.type)
	anchor := FogTileIndex(w, building.x, building.y)
	if anchor < 0 do return

	w.fog.buildingKind[anchor] = u8(BuildingKindOf(building.type))
	w.fog.buildingFlags[anchor] = 0
	if FogBuildingBurning(w, buildingSlot) do w.fog.buildingFlags[anchor] |= FOG_FLAG_BURNING
	if building.kingdom >= 0 && building.kingdom < KINGDOM_SLOTS {
		w.fog.buildingKingdom[anchor] = u8(building.kingdom)
	} else {
		w.fog.buildingKingdom[anchor] = FOG_NONE
	}
	if building.town >= 0 && building.town < TOWN_CAPACITY {
		w.fog.buildingTown[anchor] = u8(building.town)
	} else {
		w.fog.buildingTown[anchor] = FOG_NONE
	}
	for tileX in building.x ..< building.x+width {
		for tileY in building.y ..< building.y+height {
			index := FogTileIndex(w, tileX, tileY)
			if index >= 0 do w.fog.buildingAnchor[index] = anchor
		}
	}
	FogGhostRemove(w, anchor)
}

FogSnapshotConstruction :: proc(
	w: ^World,
	kingdomSlot, townSlot: int,
	site: ConstructionSite,
) {
	width, height := BuildingTileSize(BuildingTypeFromKind(site.kind))
	anchor := FogTileIndex(w, site.x, site.y)
	if anchor < 0 do return

	w.fog.buildingKind[anchor] = u8(site.kind)
	w.fog.buildingFlags[anchor] = FOG_FLAG_CONSTRUCTION
	w.fog.buildingKingdom[anchor] = u8(clamp(kingdomSlot, 0, 254))
	w.fog.buildingTown[anchor] = u8(clamp(townSlot, 0, 254))
	for tileX in site.x ..< site.x+width {
		for tileY in site.y ..< site.y+height {
			index := FogTileIndex(w, tileX, tileY)
			if index >= 0 do w.fog.buildingAnchor[index] = anchor
		}
	}
	FogGhostRemove(w, anchor)
}

FogSnapshotDecoration :: proc(w: ^World, decorationSlot: int) {
	decoration := &w.decorations[decorationSlot]
	tileX := int(d32.ToInt(decoration.x))
	tileY := int(d32.ToInt(decoration.y))
	if !FogTileVisible(w, tileX, tileY) do return
	index := FogTileIndex(w, tileX, tileY)
	if index < 0 do return

	fractionX := u8((i64(d32.Raw(decoration.x))%d32.SCALE)*255/d32.SCALE)
	fractionY := u8((i64(d32.Raw(decoration.y))%d32.SCALE)*255/d32.SCALE)
	w.fog.decorationKind[index] = u8(decoration.kind)
	w.fog.decorationVariant[index] = decoration.variant
	w.fog.decorationOffsetX[index] = fractionX
	w.fog.decorationOffsetY[index] = fractionY
}

// Any visible footprint tile is enough to meet a building's owner; neither
// a town hall nor the building anchor has to be visible.
// Kingdoms meet once their holdings share a spatial bucket. This replaces the
// per-tile contact bitmap: only unresolved pairs are considered, and empty
// buckets are skipped by the cached kingdom masks.
FogUpdateContact :: proc(w: ^World) {
	pending := false
	for a in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[a] do continue
		for b in a+1..<KINGDOMS_CAPACITY {
			if !w.kingdomUsed[b] || KingdomsMet(w, a, b) do continue
			pending = true
			break
		}
		if pending do break
	}
	if !pending do return

	chunkCount := min(len(w.spatial.presentKingdoms), len(w.spatial.buildingKingdoms))
	for chunk in 0..<chunkCount {
		mask := SpatialChunkPresent(w, chunk) | SpatialChunkBuildingPresent(w, chunk)
		if mask == 0 do continue
		for a in 0..<KINGDOMS_CAPACITY {
			if mask & (u8(1)<<u8(a)) == 0 do continue
			for b in a+1..<KINGDOMS_CAPACITY {
				if mask & (u8(1)<<u8(b)) == 0 do continue
				if !KingdomsMet(w, a, b) do KingdomMeet(w, a, b)
			}
		}
	}
}

FogUpdate :: proc(w: ^World) {
	count := int(w.maxX)*int(w.maxY)
	if count <= 0 || len(w.fog.visible) != count do return

	observer := w.observerKingdom
	// Tiles that were visible last tick may become explored or fogged again.
	for index in w.fog.visibleTiles do FogDirtyMarkIndex(w, index)
	slice.zero(w.fog.visible)
	clear(&w.fog.visibleTiles)

	isNight := WorldIsNight(w)

	fogStamp := ProfilerBegin("Fog:Units")
	for unitSlot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[unitSlot] || w.units[unitSlot].type == nil || UnitHiddenInside(w, unitSlot) do continue
		kingdom := w.units[unitSlot].kingdome
		if kingdom < 0 || kingdom >= KINGDOMS_CAPACITY || !w.kingdomUsed[kingdom] do continue
		// Only the observer's own units reveal tiles.
		if kingdom != w.observerKingdom do continue
		x := UnitTileX(w, unitSlot)
		y := UnitTileY(w, unitSlot)
		// Town area circles already cover every tile inside the town.
		townSlot := w.units[unitSlot].town
		if WorldTownExists(w, kingdom, townSlot) &&
			TownPointInArea(w, kingdom, townSlot, x, y) {
			continue
		}
		vision := d32.Mul(
			PositionFromF32(UnitDefaultVision(w.units[unitSlot].type, isNight)),
			WorldWeatherVisionFactor(w),
		)
		FogRevealCircle(w, x, y, vision, kingdom)
	}
	ProfilerEnd(fogStamp)

	fogStamp = ProfilerBegin("Fog:Buildings")
	for buildingSlot in 0..<BUILDING_CAPACITY {
		if !w.buildingUsed[buildingSlot] do continue
		building := &w.buildings[buildingSlot]
		if building.kingdom < 0 || building.kingdom >= KINGDOMS_CAPACITY || !w.kingdomUsed[building.kingdom] do continue
		width, height := BuildingTileSize(building.type)
		centerX := building.x+width/2
		centerY := building.y+height/2
		if WorldTownExists(w, building.kingdom, building.town) &&
			TownPointInArea(w, building.kingdom, building.town, centerX, centerY) {
			continue
		}
		vision := PositionFromF32(BuildingVision(BuildingKindOf(building.type)))
		FogRevealCircle(
			w,
			centerX,
			centerY,
			vision,
			building.kingdom,
		)
	}
	ProfilerEnd(fogStamp)

	fogStamp = ProfilerBegin("Fog:Constructions")
	for kingdomSlot in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[kingdomSlot] do continue
		for townSlot in 0..<TOWN_CAPACITY {
			if !w.kingdoms[kingdomSlot].townUsed[townSlot] do continue
			town := &w.kingdoms[kingdomSlot].towns[townSlot]
			for site in town.constructions {
				if !site.active do continue
				width, height := BuildingTileSize(BuildingTypeFromKind(site.kind))
				FogRevealCircle(
					w,
					site.x+width/2,
					site.y+height/2,
					PositionFromF32(BuildingVision(site.kind)),
					kingdomSlot,
				)
			}
		}
	}
	ProfilerEnd(fogStamp)

	fogStamp = ProfilerBegin("Fog:Towns")
	for kingdomSlot in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[kingdomSlot] do continue
		width, height := BuildingTileSize(TownHall{})
		for townSlot in 0..<TOWN_CAPACITY {
			if !w.kingdoms[kingdomSlot].townUsed[townSlot] do continue
			for circleIndex in 0..<TownAreaCircleCount(w, kingdomSlot, townSlot) {
				circleX, circleY, circleRadius := TownAreaCircle(w, kingdomSlot, townSlot, circleIndex)
				FogRevealCircle(
					w,
					circleX+width/2,
					circleY+height/2,
					PositionFromF32(f32(circleRadius)*FOG_TOWN_AREA_VISION_FACTOR),
					kingdomSlot,
				)
			}
		}
	}
	ProfilerEnd(fogStamp)

	// Kingdom contact no longer rides on the per-tile reveal.
	FogUpdateContact(w)

	if observer < 0 {
		// Spectator omniscience is not diplomatic contact. Only touch the tiles
		// once, otherwise every tick would re-upload the whole fog texture.
		if !w.fog.allVisible {
			for i in 0..<count {
				w.fog.visible[i] = true
				w.fog.explored[i] = true
			}
			FogDirtyMarkAll(w)
			w.fog.allVisible = true
		}
		clear(&w.fog.visibleTiles)
		clear(&w.fog.ghosts)
		for i in 0..<KINGDOMS_CAPACITY do w.fog.enemyAlerted[i] = false
		return
	}
	w.fog.allVisible = false

	fogStamp = ProfilerBegin("Fog:Snapshot")
	// A building seen at all reveals its whole footprint. This keeps sprites
	// and memory snapshots all-or-nothing instead of half fogged.
	for buildingSlot in 0..<BUILDING_CAPACITY {
		if !w.buildingUsed[buildingSlot] do continue
		building := &w.buildings[buildingSlot]
		width, height := BuildingTileSize(building.type)
		if FogRectVisible(w, building.x, building.y, width, height) {
			FogRevealRect(w, building.x, building.y, width, height)
		}
	}
	for kingdomSlot in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[kingdomSlot] do continue
		for townSlot in 0..<TOWN_CAPACITY {
			if !w.kingdoms[kingdomSlot].townUsed[townSlot] do continue
			town := &w.kingdoms[kingdomSlot].towns[townSlot]
			for site in town.constructions {
				if !site.active do continue
				width, height := BuildingTileSize(BuildingTypeFromKind(site.kind))
				if FogRectVisible(w, site.x, site.y, width, height) {
					FogRevealRect(w, site.x, site.y, width, height)
				}
			}
		}
	}

	for index in w.fog.visibleTiles {
		FogClearTileMemory(w, index)
	}

	for buildingSlot in 0..<BUILDING_CAPACITY {
		if !w.buildingUsed[buildingSlot] do continue
		building := &w.buildings[buildingSlot]
		width, height := BuildingTileSize(building.type)
		if FogRectVisible(w, building.x, building.y, width, height) {
			KingdomMeet(w, observer, building.kingdom)
			FogSnapshotBuilding(w, buildingSlot)
		}
	}
	for kingdomSlot in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[kingdomSlot] do continue
		for townSlot in 0..<TOWN_CAPACITY {
			if !w.kingdoms[kingdomSlot].townUsed[townSlot] do continue
			town := &w.kingdoms[kingdomSlot].towns[townSlot]
			for site in town.constructions {
				if !site.active do continue
				width, height := BuildingTileSize(BuildingTypeFromKind(site.kind))
				if !FogRectVisible(w, site.x, site.y, width, height) do continue
				KingdomMeet(w, observer, kingdomSlot)
				FogSnapshotConstruction(w, kingdomSlot, townSlot, site)
			}
		}
	}

	for decorationSlot in 0..<DECORATION_CAPACITY {
		if !w.decorationUsed[decorationSlot] do continue
		FogSnapshotDecoration(w, decorationSlot)
	}
	ProfilerEnd(fogStamp)

	fogStamp = ProfilerBegin("Fog:Enemies")
	visibleEnemy: [KINGDOMS_CAPACITY]bool
	for unitSlot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[unitSlot] || w.units[unitSlot].type == nil || UnitHiddenInside(w, unitSlot) do continue
		kingdomSlot := w.units[unitSlot].kingdome
		if kingdomSlot < 0 || kingdomSlot >= KINGDOMS_CAPACITY || kingdomSlot == observer {
			continue
		}
		x := UnitTileX(w, unitSlot)
		y := UnitTileY(w, unitSlot)
		if !FogTileVisible(w, x, y) do continue
		KingdomMeet(w, observer, kingdomSlot)
		visibleEnemy[kingdomSlot] = true
		if !w.fog.enemyAlerted[kingdomSlot] {
			w.fog.enemyAlerted[kingdomSlot] = true
			WorldAlertAdd(w, .EnemySpotted, observer, -1, kingdomSlot, UnitX(w, unitSlot), UnitY(w, unitSlot))
		}
	}
	for kingdomSlot in 0..<KINGDOMS_CAPACITY {
		if !visibleEnemy[kingdomSlot] do w.fog.enemyAlerted[kingdomSlot] = false
	}
	ProfilerEnd(fogStamp)

	for index := 0; index < len(w.fog.ghosts); {
		anchor := w.fog.ghosts[index]
		if w.fog.buildingKind[anchor] == FOG_NONE || FogTileVisibleIndex(w, anchor) {
			FogGhostRemove(w, anchor)
			continue
		}
		index += 1
	}
}

// --- fog render texture ----------------------------------------------------

FogRenderInit :: proc(w: ^World, renderer: ^WorldRenderer) -> bool {
	count := int(w.maxX)*int(w.maxY)
	if count <= 0 do return false

	// One chunk is rebuilt into this scratch buffer and uploaded at a time.
	renderer.fogPixels = make([]u8, FOG_RENDER_CHUNK_TILES*FOG_RENDER_CHUNK_TILES*4)
	image := rl.GenImageColor(i32(w.maxX), i32(w.maxY), rl.BLACK)
	renderer.fogTexture = rl.LoadTextureFromImage(image)
	rl.UnloadImage(image)
	rl.SetTextureFilter(renderer.fogTexture, .POINT)
	FogDirtyMarkAll(w)
	return true
}

FogRenderDeinit :: proc(renderer: ^WorldRenderer) {
	if renderer.fogTexture.id != 0 do rl.UnloadTexture(renderer.fogTexture)
	delete(renderer.fogPixels)
	renderer.fogTexture = {}
	renderer.fogPixels = nil
}

FogRenderChunk :: proc(w: ^World, renderer: ^WorldRenderer, chunk, worldWidth, worldHeight: int) {
	chunksY := w.fog.dirtyChunkCountY
	if chunksY <= 0 do return
	chunkX := chunk/chunksY
	chunkY := chunk%chunksY
	minX := chunkX*FOG_RENDER_CHUNK_TILES
	minY := chunkY*FOG_RENDER_CHUNK_TILES
	maxX := min(minX+FOG_RENDER_CHUNK_TILES, worldWidth)
	maxY := min(minY+FOG_RENDER_CHUNK_TILES, worldHeight)
	width := maxX-minX
	height := maxY-minY
	if width <= 0 || height <= 0 do return

	needed := width*height*4
	if len(renderer.fogPixels) < needed do return
	pixels := renderer.fogPixels[:needed]
	for tileY in 0..<height {
		y := minY+tileY
		for tileX in 0..<width {
			x := minX+tileX
			tile := x*worldHeight+y
			pixel := (tileY*width+tileX)*4
			switch {
			case w.fog.visible[tile]:
				pixels[pixel+0] = 0
				pixels[pixel+1] = 0
				pixels[pixel+2] = 0
				pixels[pixel+3] = 0
			case w.fog.explored[tile]:
				pixels[pixel+0] = FOG_EXPLORED_COLOR[0]
				pixels[pixel+1] = FOG_EXPLORED_COLOR[1]
				pixels[pixel+2] = FOG_EXPLORED_COLOR[2]
				pixels[pixel+3] = FOG_EXPLORED_COLOR[3]
			case:
				noise := WorldNoiseHash(x, y, 0xF06C10D)
				shade := u8(22+int(noise*10))
				pixels[pixel+0] = shade
				pixels[pixel+1] = shade+4
				pixels[pixel+2] = shade+11
				pixels[pixel+3] = FOG_UNEXPLORED_COLOR[3]
			}
		}
	}

	rl.UpdateTextureRec(
		renderer.fogTexture,
		rl.Rectangle{f32(minX), f32(minY), f32(width), f32(height)},
		raw_data(pixels),
	)
}

FogRenderUpdate :: proc(w: ^World, renderer: ^WorldRenderer) {
	if renderer.fogTexture.id == 0 || len(renderer.fogPixels) == 0 do return
	if len(w.fog.dirtyChunks) == 0 do return

	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 do return
	for chunk in w.fog.dirtyChunks {
		FogRenderChunk(w, renderer, chunk, worldWidth, worldHeight)
	}
	FogDirtyClear(w)
}

FogRenderDraw :: proc(w: ^World, renderer: ^WorldRenderer, firstCopyX, lastCopyX, firstCopyY, lastCopyY: int) {
	if renderer.fogTexture.id == 0 do return
	worldWidth := f32(w.maxX)
	worldHeight := f32(w.maxY)
	source := rl.Rectangle{0, 0, worldWidth, worldHeight}
	for copyX in firstCopyX ..< lastCopyX+1 {
		for copyY in firstCopyY ..< lastCopyY+1 {
			rl.DrawTexturePro(
				renderer.fogTexture,
				source,
				rl.Rectangle{
					f32(copyX)*worldWidth,
					f32(copyY)*worldHeight,
					worldWidth,
					worldHeight,
				},
				rl.Vector2{0, 0},
				0,
				rl.WHITE,
			)
		}
	}
}
