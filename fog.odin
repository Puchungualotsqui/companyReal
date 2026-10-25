package main

import rl "vendor:raylib"
import "core:math"

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

FogOfWar :: struct {
	visible:  []bool,
	explored: []bool,
	revision: u64,

	// Persistent mutual contact and scratch per-tile vision bits. Contact does
	// not reveal the other kingdom's towns or share its map exploration.
	contacts: [KINGDOMS_CAPACITY][KINGDOMS_CAPACITY]bool,
	contactVision: []u8,

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
}

FogInit :: proc(w: ^World) -> bool {
	count := int(w.maxX)*int(w.maxY)
	if count <= 0 do return false

	#assert(KINGDOMS_CAPACITY <= 8)
	w.fog.contacts = {}
	w.fog.contactVision = make([]u8, count)
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

	for i in 0..<count {
		w.fog.buildingKind[i] = FOG_NONE
		w.fog.buildingKingdom[i] = FOG_NONE
		w.fog.buildingTown[i] = FOG_NONE
		w.fog.buildingAnchor[i] = -1
		w.fog.buildingGhostIndex[i] = -1
		w.fog.decorationKind[i] = FOG_NONE
	}
	w.fog.revision = 1
	return true
}

FogDeinit :: proc(w: ^World) {
	delete(w.fog.contactVision)
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
	x := int(WorldWrapPosition(w.units.x[unitSlot], f32(worldWidth)))
	y := int(WorldWrapPosition(w.units.y[unitSlot], f32(worldHeight)))
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

FogMarkVisible :: proc(w: ^World, x, y: int) {
	index := FogTileIndex(w, x, y)
	if index < 0 || index >= len(w.fog.visible) do return
	if !w.fog.visible[index] {
		w.fog.visible[index] = true
		append(&w.fog.visibleTiles, index)
	}
	w.fog.explored[index] = true
}

// A kingdom source stamps contact vision and, only for the observer, fog.
// The default remains useful for observer-only footprint revelation.
FogRevealCircle :: proc(w: ^World, centerX, centerY: int, radius: f32, kingdom: int = -1) {
	if radius <= 0 do return
	if kingdom >= 0 && (kingdom >= KINGDOMS_CAPACITY || !w.kingdomUsed[kingdom]) do return
	needsContact := false
	if kingdom >= 0 {
		for other in 0..<KINGDOMS_CAPACITY {
			if other != kingdom && w.kingdomUsed[other] && !KingdomsMet(w, kingdom, other) {
				needsContact = true
				break
			}
		}
		// Once introduced to every living kingdom, only observer fog needs
		// updating. Large AI armies need not stamp redundant contact circles.
		if !needsContact && kingdom != w.observerKingdom do return
	}
	radiusSquared := radius*radius
	extent := int(radius)+1
	for offsetY in -extent..=extent {
		distanceSquared := f32(offsetY*offsetY)
		if distanceSquared > radiusSquared do continue
		halfWidth := int(math.sqrt(radiusSquared-distanceSquared))
		for offsetX in -halfWidth..=halfWidth {
			x, y := centerX+offsetX, centerY+offsetY
			if needsContact {
				index := FogTileIndex(w, x, y)
				if index >= 0 && index < len(w.fog.contactVision) {
					w.fog.contactVision[index] |= u8(1) << u8(kingdom)
				}
			}
			if kingdom < 0 || kingdom == w.observerKingdom do FogMarkVisible(w, x, y)
		}
	}
}

FogRevealRect :: proc(w: ^World, x, y, width, height: int) {
	for tileX in x ..< x+width {
		for tileY in y ..< y+height {
			FogMarkVisible(w, tileX, tileY)
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
	index := FogTileIndex(w, int(w.decorations.x[decorationSlot]), int(w.decorations.y[decorationSlot]))
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
	tileX := int(decoration.x)
	tileY := int(decoration.y)
	if !FogTileVisible(w, tileX, tileY) do return
	index := FogTileIndex(w, tileX, tileY)
	if index < 0 do return

	fractionX := clamp(decoration.x-f32(tileX), 0, 1)
	fractionY := clamp(decoration.y-f32(tileY), 0, 1)
	w.fog.decorationKind[index] = u8(decoration.kind)
	w.fog.decorationVariant[index] = decoration.variant
	w.fog.decorationOffsetX[index] = u8(fractionX*255)
	w.fog.decorationOffsetY[index] = u8(fractionY*255)
}

// Any visible footprint tile is enough to meet a building's owner; neither
// a town hall nor the building anchor has to be visible.
FogContactRect :: proc(w: ^World, kingdom, x, y, width, height: int) {
	if kingdom < 0 || kingdom >= KINGDOMS_CAPACITY || !w.kingdomUsed[kingdom] do return
	viewers: u8
	for tileX in x..<x+width {
		for tileY in y..<y+height {
			index := FogTileIndex(w, tileX, tileY)
			if index >= 0 && index < len(w.fog.contactVision) do viewers |= w.fog.contactVision[index]
		}
	}
	for other in 0..<KINGDOMS_CAPACITY {
		if viewers & (u8(1) << u8(other)) != 0 do KingdomMeet(w, kingdom, other)
	}
}

FogUpdate :: proc(w: ^World) {
	count := int(w.maxX)*int(w.maxY)
	if count <= 0 || len(w.fog.visible) != count do return

	observer := w.observerKingdom
	for i in 0..<count {
		w.fog.visible[i] = false
		w.fog.contactVision[i] = 0
	}
	clear(&w.fog.visibleTiles)

	isNight := WorldIsNight(w)
	for unitSlot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[unitSlot] || w.units[unitSlot].type == nil || UnitHiddenInside(w, unitSlot) do continue
		kingdom := w.units[unitSlot].kingdome
		if kingdom < 0 || kingdom >= KINGDOMS_CAPACITY || !w.kingdomUsed[kingdom] do continue
		vision := UnitDefaultVision(w.units[unitSlot].type, isNight)
		x := int(WorldWrapPosition(w.units.x[unitSlot], f32(w.maxX)))
		y := int(WorldWrapPosition(w.units.y[unitSlot], f32(w.maxY)))
		FogRevealCircle(w, x, y, vision, kingdom)
	}

	for buildingSlot in 0..<BUILDING_CAPACITY {
		if !w.buildingUsed[buildingSlot] do continue
		building := &w.buildings[buildingSlot]
		if building.kingdom < 0 || building.kingdom >= KINGDOMS_CAPACITY || !w.kingdomUsed[building.kingdom] do continue
		width, height := BuildingTileSize(building.type)
		vision := BuildingVision(BuildingKindOf(building.type))
		FogRevealCircle(w, building.x+width/2, building.y+height/2, vision, building.kingdom)
	}

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
					BuildingVision(site.kind),
					kingdomSlot,
				)
			}
		}
	}

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
					f32(circleRadius)*FOG_TOWN_AREA_VISION_FACTOR,
					kingdomSlot,
				)
			}
		}
	}

	for unitSlot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[unitSlot] || w.units[unitSlot].type == nil || UnitHiddenInside(w, unitSlot) do continue
		x := int(WorldWrapPosition(w.units.x[unitSlot], f32(w.maxX)))
		y := int(WorldWrapPosition(w.units.y[unitSlot], f32(w.maxY)))
		FogContactRect(w, w.units[unitSlot].kingdome, x, y, 1, 1)
	}
	for buildingSlot in 0..<BUILDING_CAPACITY {
		if !w.buildingUsed[buildingSlot] do continue
		building := &w.buildings[buildingSlot]
		width, height := BuildingTileSize(building.type)
		FogContactRect(w, building.kingdom, building.x, building.y, width, height)
	}
	for kingdomSlot in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[kingdomSlot] do continue
		for townSlot in 0..<TOWN_CAPACITY {
			if !w.kingdoms[kingdomSlot].townUsed[townSlot] do continue
			town := &w.kingdoms[kingdomSlot].towns[townSlot]
			for site in town.constructions {
				if !site.active do continue
				width, height := BuildingTileSize(BuildingTypeFromKind(site.kind))
				FogContactRect(w, kingdomSlot, site.x, site.y, width, height)
			}
		}
	}

	if observer < 0 {
		// Spectator omniscience is not diplomatic contact.
		for i in 0..<count {
			w.fog.visible[i] = true
			w.fog.explored[i] = true
		}
		clear(&w.fog.visibleTiles)
		clear(&w.fog.ghosts)
		for i in 0..<KINGDOMS_CAPACITY do w.fog.enemyAlerted[i] = false
		w.fog.revision += 1
		return
	}

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

	visibleEnemy: [KINGDOMS_CAPACITY]bool
	for unitSlot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[unitSlot] || w.units[unitSlot].type == nil || UnitHiddenInside(w, unitSlot) do continue
		kingdomSlot := w.units[unitSlot].kingdome
		if kingdomSlot < 0 || kingdomSlot >= KINGDOMS_CAPACITY || kingdomSlot == observer {
			continue
		}
		x := int(WorldWrapPosition(w.units.x[unitSlot], f32(w.maxX)))
		y := int(WorldWrapPosition(w.units.y[unitSlot], f32(w.maxY)))
		if !FogTileVisible(w, x, y) do continue
		KingdomMeet(w, observer, kingdomSlot)
		visibleEnemy[kingdomSlot] = true
		if !w.fog.enemyAlerted[kingdomSlot] {
			w.fog.enemyAlerted[kingdomSlot] = true
			WorldAlertAdd(w, .EnemySpotted, observer, -1, kingdomSlot, w.units.x[unitSlot], w.units.y[unitSlot])
		}
	}
	for kingdomSlot in 0..<KINGDOMS_CAPACITY {
		if !visibleEnemy[kingdomSlot] do w.fog.enemyAlerted[kingdomSlot] = false
	}

	for index := 0; index < len(w.fog.ghosts); {
		anchor := w.fog.ghosts[index]
		if w.fog.buildingKind[anchor] == FOG_NONE || FogTileVisibleIndex(w, anchor) {
			FogGhostRemove(w, anchor)
			continue
		}
		index += 1
	}

	w.fog.revision += 1
}

// --- fog render texture ----------------------------------------------------

FogRenderInit :: proc(w: ^World, renderer: ^WorldRenderer) -> bool {
	count := int(w.maxX)*int(w.maxY)
	if count <= 0 do return false
	renderer.fogPixels = make([]u8, count*4)
	image := rl.GenImageColor(i32(w.maxX), i32(w.maxY), rl.BLACK)
	renderer.fogTexture = rl.LoadTextureFromImage(image)
	rl.UnloadImage(image)
	rl.SetTextureFilter(renderer.fogTexture, .POINT)
	renderer.fogRevision = ~u64(0)
	return true
}

FogRenderDeinit :: proc(renderer: ^WorldRenderer) {
	if renderer.fogTexture.id != 0 do rl.UnloadTexture(renderer.fogTexture)
	delete(renderer.fogPixels)
	renderer.fogTexture = {}
	renderer.fogPixels = nil
}

FogRenderUpdate :: proc(w: ^World, renderer: ^WorldRenderer) {
	if renderer.fogTexture.id == 0 || len(renderer.fogPixels) == 0 do return
	if renderer.fogRevision == w.fog.revision do return

	width := int(w.maxX)
	height := int(w.maxY)
	for y in 0..<height {
		for x in 0..<width {
			tile := x*height+y
			pixel := (y*width+x)*4
			switch {
			case w.fog.visible[tile]:
				renderer.fogPixels[pixel+0] = 0
				renderer.fogPixels[pixel+1] = 0
				renderer.fogPixels[pixel+2] = 0
				renderer.fogPixels[pixel+3] = 0
			case w.fog.explored[tile]:
				renderer.fogPixels[pixel+0] = FOG_EXPLORED_COLOR[0]
				renderer.fogPixels[pixel+1] = FOG_EXPLORED_COLOR[1]
				renderer.fogPixels[pixel+2] = FOG_EXPLORED_COLOR[2]
				renderer.fogPixels[pixel+3] = FOG_EXPLORED_COLOR[3]
			case:
				noise := WorldNoiseHash(x, y, 0xF06C10D)
				shade := u8(22+int(noise*10))
				renderer.fogPixels[pixel+0] = shade
				renderer.fogPixels[pixel+1] = shade+4
				renderer.fogPixels[pixel+2] = shade+11
				renderer.fogPixels[pixel+3] = FOG_UNEXPLORED_COLOR[3]
			}
		}
	}
	rl.UpdateTexture(renderer.fogTexture, raw_data(renderer.fogPixels))
	rl.SetTextureFilter(renderer.fogTexture, .POINT)
	renderer.fogRevision = w.fog.revision
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
