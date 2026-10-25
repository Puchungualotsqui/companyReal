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
	wrapped_x := WorldWrapCoordinate(x, width)
	wrapped_y := WorldWrapCoordinate(y, height)
	return wrapped_x*height+wrapped_y
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
	for tile_x in x ..< x+width {
		for tile_y in y ..< y+height {
			if FogTileVisible(w, tile_x, tile_y) do return true
		}
	}
	return false
}

FogRectExplored :: proc(w: ^World, x, y, width, height: int) -> bool {
	for tile_x in x ..< x+width {
		for tile_y in y ..< y+height {
			if !FogTileExplored(w, tile_x, tile_y) do return false
		}
	}
	return true
}

FogUnitVisible :: proc(w: ^World, unit_slot: int) -> bool {
	if unit_slot < 0 || unit_slot >= UNIT_CAPACITY || !w.unitUsed[unit_slot] do return false
	if UnitHiddenInside(w, unit_slot) do return false
	if w.observerKingdom < 0 do return true
	if w.units[unit_slot].kingdome == w.observerKingdom do return true
	world_width := int(w.maxX)
	world_height := int(w.maxY)
	if world_width <= 0 || world_height <= 0 do return false
	x := int(WorldWrapPosition(w.units.x[unit_slot], f32(world_width)))
	y := int(WorldWrapPosition(w.units.y[unit_slot], f32(world_height)))
	return FogTileVisible(w, x, y)
}

FogBuildingVisible :: proc(w: ^World, building_slot: int) -> bool {
	if building_slot < 0 || building_slot >= BUILDING_CAPACITY || !w.buildingUsed[building_slot] {
		return false
	}
	if w.observerKingdom < 0 do return true
	if w.buildings[building_slot].kingdom == w.observerKingdom do return true
	width, height := BuildingTileSize(w.buildings[building_slot].type)
	return FogRectVisible(
		w,
		w.buildings[building_slot].x,
		w.buildings[building_slot].y,
		width,
		height,
	)
}

FogTownDiscovered :: proc(w: ^World, kingdom_slot, town_slot: int) -> bool {
	if !WorldTownExists(w, kingdom_slot, town_slot) do return false
	hall := TownHallSlot(w, kingdom_slot, town_slot)
	if hall < 0 do return false
	return FogTileExplored(w, w.buildings[hall].x, w.buildings[hall].y)
}

FogTownVisible :: proc(w: ^World, kingdom_slot, town_slot: int) -> bool {
	if !WorldTownExists(w, kingdom_slot, town_slot) do return false
	hall := TownHallSlot(w, kingdom_slot, town_slot)
	if hall < 0 do return false
	return FogBuildingVisible(w, hall)
}

KingdomDiscovered :: proc(w: ^World, kingdom_slot: int) -> bool {
	if kingdom_slot < 0 || kingdom_slot >= KINGDOMS_CAPACITY || !w.kingdomUsed[kingdom_slot] {
		return false
	}
	if w.observerKingdom < 0 do return true
	if kingdom_slot == w.observerKingdom do return true
	return KingdomsMet(w, w.observerKingdom, kingdom_slot)
}

FogFirstDiscoveredTown :: proc(w: ^World, kingdom_slot: int) -> (int, bool) {
	if kingdom_slot < 0 || kingdom_slot >= KINGDOMS_CAPACITY || !w.kingdomUsed[kingdom_slot] {
		return -1, false
	}
	for town_slot in 0..<TOWN_CAPACITY {
		if !w.kingdoms[kingdom_slot].townUsed[town_slot] do continue
		if FogTownDiscovered(w, kingdom_slot, town_slot) do return town_slot, true
	}
	return -1, false
}

// Resolves a remembered town hall under the cursor. Used by attack/defend
// orders so discovered-but-fogged towns remain valid targets.
FogFindTownAt :: proc(w: ^World, tile_x, tile_y: int) -> (kingdom, town: int, found: bool) {
	index := FogTileIndex(w, tile_x, tile_y)
	if index < 0 || index >= len(w.fog.buildingAnchor) do return -1, -1, false
	anchor := w.fog.buildingAnchor[index]
	if anchor < 0 || anchor >= len(w.fog.buildingKind) do return -1, -1, false
	if w.fog.buildingKind[anchor] == FOG_NONE do return -1, -1, false
	if w.fog.buildingFlags[anchor]&FOG_FLAG_CONSTRUCTION != 0 do return -1, -1, false

	kingdom = int(w.fog.buildingKingdom[anchor])
	town = int(w.fog.buildingTown[anchor])
	if kingdom < 0 || kingdom >= KINGDOMS_CAPACITY || town < 0 || town >= TOWN_CAPACITY {
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
FogRevealCircle :: proc(w: ^World, center_x, center_y: int, radius: f32, kingdom: int = -1) {
	if radius <= 0 do return
	if kingdom >= 0 && (kingdom >= KINGDOMS_CAPACITY || !w.kingdomUsed[kingdom]) do return
	needs_contact := false
	if kingdom >= 0 {
		for other in 0..<KINGDOMS_CAPACITY {
			if other != kingdom && w.kingdomUsed[other] && !KingdomsMet(w, kingdom, other) {
				needs_contact = true
				break
			}
		}
		// Once introduced to every living kingdom, only observer fog needs
		// updating. Large AI armies need not stamp redundant contact circles.
		if !needs_contact && kingdom != w.observerKingdom do return
	}
	radius_squared := radius*radius
	extent := int(radius)+1
	for offset_y in -extent..=extent {
		distance_squared := f32(offset_y*offset_y)
		if distance_squared > radius_squared do continue
		half_width := int(math.sqrt(radius_squared-distance_squared))
		for offset_x in -half_width..=half_width {
			x, y := center_x+offset_x, center_y+offset_y
			if needs_contact {
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
	for tile_x in x ..< x+width {
		for tile_y in y ..< y+height {
			FogMarkVisible(w, tile_x, tile_y)
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

FogBuildingDespawn :: proc(w: ^World, building_slot: int) {
	if building_slot < 0 || building_slot >= BUILDING_CAPACITY || !w.buildingUsed[building_slot] {
		return
	}
	building := &w.buildings[building_slot]
	width, height := BuildingTileSize(building.type)
	anchor := FogTileIndex(w, building.x, building.y)
	if anchor < 0 do return

	if FogRectVisible(w, building.x, building.y, width, height) ||
		building.kingdom == w.observerKingdom {
		for tile_x in building.x ..< building.x+width {
			for tile_y in building.y ..< building.y+height {
				index := FogTileIndex(w, tile_x, tile_y)
				if index >= 0 do w.fog.buildingAnchor[index] = -1
			}
		}
		FogClearTileMemory(w, anchor)
		FogGhostRemove(w, anchor)
	} else if w.fog.buildingKind[anchor] != FOG_NONE {
		FogGhostAdd(w, anchor)
	}
}

FogDecorationDespawn :: proc(w: ^World, decoration_slot: int) {
	if decoration_slot < 0 || decoration_slot >= DECORATION_CAPACITY ||
		!w.decorationUsed[decoration_slot] {
		return
	}
	index := FogTileIndex(w, int(w.decorations.x[decoration_slot]), int(w.decorations.y[decoration_slot]))
	if index < 0 || index >= len(w.fog.decorationKind) do return
	if w.fog.visible[index] {
		w.fog.decorationKind[index] = FOG_NONE
		w.fog.decorationVariant[index] = 0
	}
}

FogBuildingBurning :: proc(w: ^World, building_slot: int) -> bool {
	building := &w.buildings[building_slot]
	width, height := BuildingTileSize(building.type)
	for tile_x in building.x ..< building.x+width {
		for tile_y in building.y ..< building.y+height {
			if WorldFireAt(w, tile_x, tile_y) do return true
		}
	}
	return false
}

FogSnapshotBuilding :: proc(w: ^World, building_slot: int) {
	building := &w.buildings[building_slot]
	width, height := BuildingTileSize(building.type)
	anchor := FogTileIndex(w, building.x, building.y)
	if anchor < 0 do return

	w.fog.buildingKind[anchor] = u8(BuildingKindOf(building.type))
	w.fog.buildingFlags[anchor] = 0
	if FogBuildingBurning(w, building_slot) do w.fog.buildingFlags[anchor] |= FOG_FLAG_BURNING
	if building.kingdom >= 0 && building.kingdom < KINGDOMS_CAPACITY {
		w.fog.buildingKingdom[anchor] = u8(building.kingdom)
	} else {
		w.fog.buildingKingdom[anchor] = FOG_NONE
	}
	if building.town >= 0 && building.town < TOWN_CAPACITY {
		w.fog.buildingTown[anchor] = u8(building.town)
	} else {
		w.fog.buildingTown[anchor] = FOG_NONE
	}
	for tile_x in building.x ..< building.x+width {
		for tile_y in building.y ..< building.y+height {
			index := FogTileIndex(w, tile_x, tile_y)
			if index >= 0 do w.fog.buildingAnchor[index] = anchor
		}
	}
	FogGhostRemove(w, anchor)
}

FogSnapshotConstruction :: proc(w: ^World, kingdom_slot, town_slot: int) {
	if !WorldTownExists(w, kingdom_slot, town_slot) do return
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	if !town.constructionActive do return
	site := town.construction
	width, height := BuildingTileSize(BuildingTypeFromKind(site.kind))
	anchor := FogTileIndex(w, site.x, site.y)
	if anchor < 0 do return

	w.fog.buildingKind[anchor] = u8(site.kind)
	w.fog.buildingFlags[anchor] = FOG_FLAG_CONSTRUCTION
	w.fog.buildingKingdom[anchor] = u8(clamp(kingdom_slot, 0, 254))
	w.fog.buildingTown[anchor] = u8(clamp(town_slot, 0, 254))
	for tile_x in site.x ..< site.x+width {
		for tile_y in site.y ..< site.y+height {
			index := FogTileIndex(w, tile_x, tile_y)
			if index >= 0 do w.fog.buildingAnchor[index] = anchor
		}
	}
	FogGhostRemove(w, anchor)
}

FogSnapshotDecoration :: proc(w: ^World, decoration_slot: int) {
	decoration := &w.decorations[decoration_slot]
	tile_x := int(decoration.x)
	tile_y := int(decoration.y)
	if !FogTileVisible(w, tile_x, tile_y) do return
	index := FogTileIndex(w, tile_x, tile_y)
	if index < 0 do return

	fraction_x := clamp(decoration.x-f32(tile_x), 0, 1)
	fraction_y := clamp(decoration.y-f32(tile_y), 0, 1)
	w.fog.decorationKind[index] = u8(decoration.kind)
	w.fog.decorationVariant[index] = decoration.variant
	w.fog.decorationOffsetX[index] = u8(fraction_x*255)
	w.fog.decorationOffsetY[index] = u8(fraction_y*255)
}

// Any visible footprint tile is enough to meet a building's owner; neither
// a town hall nor the building anchor has to be visible.
FogContactRect :: proc(w: ^World, kingdom, x, y, width, height: int) {
	if kingdom < 0 || kingdom >= KINGDOMS_CAPACITY || !w.kingdomUsed[kingdom] do return
	viewers: u8
	for tile_x in x..<x+width {
		for tile_y in y..<y+height {
			index := FogTileIndex(w, tile_x, tile_y)
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

	for unit_slot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[unit_slot] || w.units[unit_slot].type == nil || UnitHiddenInside(w, unit_slot) do continue
		kingdom := w.units[unit_slot].kingdome
		if kingdom < 0 || kingdom >= KINGDOMS_CAPACITY || !w.kingdomUsed[kingdom] do continue
		vision := UnitDefaultVision(w.units[unit_slot].type)
		x := int(WorldWrapPosition(w.units.x[unit_slot], f32(w.maxX)))
		y := int(WorldWrapPosition(w.units.y[unit_slot], f32(w.maxY)))
		FogRevealCircle(w, x, y, vision, kingdom)
	}

	for building_slot in 0..<BUILDING_CAPACITY {
		if !w.buildingUsed[building_slot] do continue
		building := &w.buildings[building_slot]
		if building.kingdom < 0 || building.kingdom >= KINGDOMS_CAPACITY || !w.kingdomUsed[building.kingdom] do continue
		width, height := BuildingTileSize(building.type)
		vision := BuildingVision(BuildingKindOf(building.type))
		FogRevealCircle(w, building.x+width/2, building.y+height/2, vision, building.kingdom)
	}

	for kingdom_slot in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[kingdom_slot] do continue
		for town_slot in 0..<TOWN_CAPACITY {
			if !w.kingdoms[kingdom_slot].townUsed[town_slot] do continue
			site := &w.kingdoms[kingdom_slot].towns[town_slot]
			if !site.constructionActive do continue
			width, height := BuildingTileSize(BuildingTypeFromKind(site.construction.kind))
			FogRevealCircle(
				w,
				site.construction.x+width/2,
				site.construction.y+height/2,
				BuildingVision(site.construction.kind),
				kingdom_slot,
			)
		}
	}

	for kingdom_slot in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[kingdom_slot] do continue
		width, height := BuildingTileSize(TownHall{})
		for town_slot in 0..<TOWN_CAPACITY {
			if !w.kingdoms[kingdom_slot].townUsed[town_slot] do continue
			for circle_index in 0..<TownAreaCircleCount(w, kingdom_slot, town_slot) {
				circle_x, circle_y, circle_radius := TownAreaCircle(w, kingdom_slot, town_slot, circle_index)
				FogRevealCircle(
					w,
					circle_x+width/2,
					circle_y+height/2,
					f32(circle_radius)*FOG_TOWN_AREA_VISION_FACTOR,
					kingdom_slot,
				)
			}
		}
	}

	for unit_slot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[unit_slot] || w.units[unit_slot].type == nil || UnitHiddenInside(w, unit_slot) do continue
		x := int(WorldWrapPosition(w.units.x[unit_slot], f32(w.maxX)))
		y := int(WorldWrapPosition(w.units.y[unit_slot], f32(w.maxY)))
		FogContactRect(w, w.units[unit_slot].kingdome, x, y, 1, 1)
	}
	for building_slot in 0..<BUILDING_CAPACITY {
		if !w.buildingUsed[building_slot] do continue
		building := &w.buildings[building_slot]
		width, height := BuildingTileSize(building.type)
		FogContactRect(w, building.kingdom, building.x, building.y, width, height)
	}
	for kingdom_slot in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[kingdom_slot] do continue
		for town_slot in 0..<TOWN_CAPACITY {
			if !w.kingdoms[kingdom_slot].townUsed[town_slot] do continue
			town := &w.kingdoms[kingdom_slot].towns[town_slot]
			if !town.constructionActive do continue
			width, height := BuildingTileSize(BuildingTypeFromKind(town.construction.kind))
			FogContactRect(w, kingdom_slot, town.construction.x, town.construction.y, width, height)
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
	for building_slot in 0..<BUILDING_CAPACITY {
		if !w.buildingUsed[building_slot] do continue
		building := &w.buildings[building_slot]
		width, height := BuildingTileSize(building.type)
		if FogRectVisible(w, building.x, building.y, width, height) {
			FogRevealRect(w, building.x, building.y, width, height)
		}
	}
	for kingdom_slot in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[kingdom_slot] do continue
		for town_slot in 0..<TOWN_CAPACITY {
			if !w.kingdoms[kingdom_slot].townUsed[town_slot] do continue
			town := &w.kingdoms[kingdom_slot].towns[town_slot]
			if !town.constructionActive do continue
			width, height := BuildingTileSize(BuildingTypeFromKind(town.construction.kind))
			if FogRectVisible(w, town.construction.x, town.construction.y, width, height) {
				FogRevealRect(w, town.construction.x, town.construction.y, width, height)
			}
		}
	}

	for index in w.fog.visibleTiles {
		FogClearTileMemory(w, index)
	}

	for building_slot in 0..<BUILDING_CAPACITY {
		if !w.buildingUsed[building_slot] do continue
		building := &w.buildings[building_slot]
		width, height := BuildingTileSize(building.type)
		if FogRectVisible(w, building.x, building.y, width, height) {
			KingdomMeet(w, observer, building.kingdom)
			FogSnapshotBuilding(w, building_slot)
		}
	}
	for kingdom_slot in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[kingdom_slot] do continue
		for town_slot in 0..<TOWN_CAPACITY {
			if !w.kingdoms[kingdom_slot].townUsed[town_slot] do continue
			town := &w.kingdoms[kingdom_slot].towns[town_slot]
			if !town.constructionActive do continue
			width, height := BuildingTileSize(BuildingTypeFromKind(town.construction.kind))
			if !FogRectVisible(w, town.construction.x, town.construction.y, width, height) do continue
			KingdomMeet(w, observer, kingdom_slot)
			FogSnapshotConstruction(w, kingdom_slot, town_slot)
		}
	}

	for decoration_slot in 0..<DECORATION_CAPACITY {
		if !w.decorationUsed[decoration_slot] do continue
		FogSnapshotDecoration(w, decoration_slot)
	}

	visible_enemy: [KINGDOMS_CAPACITY]bool
	for unit_slot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[unit_slot] || w.units[unit_slot].type == nil || UnitHiddenInside(w, unit_slot) do continue
		kingdom_slot := w.units[unit_slot].kingdome
		if kingdom_slot < 0 || kingdom_slot >= KINGDOMS_CAPACITY || kingdom_slot == observer {
			continue
		}
		x := int(WorldWrapPosition(w.units.x[unit_slot], f32(w.maxX)))
		y := int(WorldWrapPosition(w.units.y[unit_slot], f32(w.maxY)))
		if !FogTileVisible(w, x, y) do continue
		KingdomMeet(w, observer, kingdom_slot)
		visible_enemy[kingdom_slot] = true
		if !w.fog.enemyAlerted[kingdom_slot] {
			w.fog.enemyAlerted[kingdom_slot] = true
			WorldAlertAdd(w, .EnemySpotted, observer, -1, kingdom_slot, w.units.x[unit_slot], w.units.y[unit_slot])
		}
	}
	for kingdom_slot in 0..<KINGDOMS_CAPACITY {
		if !visible_enemy[kingdom_slot] do w.fog.enemyAlerted[kingdom_slot] = false
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

FogRenderDraw :: proc(w: ^World, renderer: ^WorldRenderer, first_copy_x, last_copy_x, first_copy_y, last_copy_y: int) {
	if renderer.fogTexture.id == 0 do return
	world_width := f32(w.maxX)
	world_height := f32(w.maxY)
	source := rl.Rectangle{0, 0, world_width, world_height}
	for copy_x in first_copy_x ..< last_copy_x+1 {
		for copy_y in first_copy_y ..< last_copy_y+1 {
			rl.DrawTexturePro(
				renderer.fogTexture,
				source,
				rl.Rectangle{
					f32(copy_x)*world_width,
					f32(copy_y)*world_height,
					world_width,
					world_height,
				},
				rl.Vector2{0, 0},
				0,
				rl.WHITE,
			)
		}
	}
}
