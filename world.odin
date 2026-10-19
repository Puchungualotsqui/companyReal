package main

UNIT_CAPACITY :: 10_000
BUILDING_CAPACITY :: 5_000
KINGDOMS_CAPACITY :: 5

World :: struct {
	units: #soa [UNIT_CAPACITY]Unit,
	unitUsed: [UNIT_CAPACITY]bool,
	buildings: #soa [BUILDING_CAPACITY]Building,
	buildingUsed: [BUILDING_CAPACITY]bool,
	kingdoms: #soa [KINGDOMS_CAPACITY]Kingdom,
	kingdomUsed: [KINGDOMS_CAPACITY]bool,
	maxX, maxY: uint,
	ground: [dynamic][dynamic]Tile,
}

WorldInit :: proc(w: ^World, maxX, maxY: uint) {
	w.maxX = maxX
	w.maxY = maxY
	w.ground = make([dynamic][dynamic]Tile, maxX)
	for &x in w.ground {
		x = make([dynamic]Tile, maxY)
	}
}

WorldDeinit :: proc(w: ^World) {
	for &x in w.ground {
		delete(x)
	}
	delete(w.ground)
}

Tile :: struct {
	type: TileType,
}

TileType :: enum {
	Water,
	Ground,
	Desert,
}

UnitSpawn :: proc(w: ^World, type: UnitType, x, y: f32) -> (int, bool) {
	i := -1
	for slot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[slot] {
			i = slot
			break
		}
	}
	if i < 0 {
		return 0, false
	}
	w.units.x[i] = x
	w.units.y[i] = y
	w.units.health[i] = UnitDefaultHealth(type)
	w.units.speed[i] = UnitDefaultSpeed(type)
	w.units.cooldown[i] = UnitDefaultCooldown(type)
	w.units.range[i] = UnitDefaultRange(type)
	w.units.vision[i] = UnitDefaultVision(type)
	w.units.damage[i] = UnitDefaultDamage(type)
	w.units.type[i] = type
	w.unitUsed[i] = true
	return i, true
}

UnitGet :: proc(w: ^World, slot: int) -> (int, bool) {
	if slot < 0 || slot >= UNIT_CAPACITY || !w.unitUsed[slot] {
		return 0, false
	}
	return slot, true
}

UnitDelete :: proc(w: ^World, slot: int) -> bool {
	if slot < 0 || slot >= UNIT_CAPACITY || !w.unitUsed[slot] {
		return false
	}
	w.unitUsed[slot] = false
	return true
}

BuildingSpawn :: proc(w: ^World, x, y: int, type: BuildingType) -> (int, bool) {
	if !WorldBuildingValid(w, x, y, type) do return 0, false
	i := -1
	for slot in 0..<BUILDING_CAPACITY {
		if !w.buildingUsed[slot] {
			i = slot
			break
		}
	}
	if i < 0 {
		return 0, false
	}

	w.buildings.x[i] = x
	w.buildings.y[i] = y
	w.buildings.width[i], w.buildings.height[i] = BuildingTileSize(type)
	w.buildings.health[i] = BuildingDefaultHealth(type)
	w.buildings.type[i] = type
	w.buildingUsed[i] = true
	return i, true
}

BuildingGet :: proc(w: ^World, slot: int) -> (int, bool) {
	if slot < 0 || slot >= BUILDING_CAPACITY || !w.buildingUsed[slot] {
		return 0, false
	}
	return slot, true
}

BuildingDelete :: proc(w: ^World, slot: int) -> bool {
	if slot < 0 || slot >= BUILDING_CAPACITY || !w.buildingUsed[slot] {
		return false
	}
	w.buildingUsed[slot] = false
	return true
}

KingdomSpawn :: proc(w: ^World, x, y: int) -> (int, bool) {
	i := -1
	for slot in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[slot] {
			i = slot
			break
		}
	}
	if i < 0 do return 0, false

	if capital, ok := TownStart(w, x, y, i); ok {
		w.kingdoms[i].capitalSlot = capital
		w.kingdomUsed[i] = true
		return i, true
	}

	return 0, false
}

KingdomGet :: proc(w: ^World, slot: int) -> (int, bool) {
	if slot < 0 || slot >= KINGDOMS_CAPACITY || !w.kingdomUsed[slot] {
		return 0, false
	}
	return slot, true
}

KingdomDelete :: proc(w: ^World, slot: int) -> bool {
	if slot < 0 || slot >= KINGDOMS_CAPACITY || !w.kingdomUsed[slot] {
		return false
	}
	w.kingdomUsed[slot] = false
	return true
}

WorldTileOccupied :: proc(w: ^World, x, y: int) -> bool {
	for i in 0..<BUILDING_CAPACITY {
		if !w.buildingUsed[i] {
			continue
		}
		building_x := w.buildings.x[i]
		building_y := w.buildings.y[i]
		if x >= building_x && x < building_x + w.buildings.width[i] &&
			y >= building_y && y < building_y + w.buildings.height[i] {
			return true
		}
	}
	return false
}

WorldBuildingOverTile :: proc(w: ^World, x, y: int, bType: BuildingType) -> bool {
	width, height := BuildingTileSize(bType)
	if x < 0 || y < 0 || width <= 0 || height <= 0 ||
		x + width > int(w.maxX) || y + height > int(w.maxY) {
		return false
	}

	for tile_x in x ..< x + width {
		for tile_y in y ..< y + height {
			if !BuildingValidTileType(bType, w.ground[tile_x][tile_y].type) {
				return false
			}
		}
	}
	return true
}

WorldBuildingCollides :: proc(w: ^World, x, y: int, type: BuildingType) -> bool {
	width, height := BuildingTileSize(type)
	if x < 0 || y < 0 || width <= 0 || height <= 0 ||
		x + width > int(w.maxX) || y + height > int(w.maxY) {
		return true
	}

	for i in 0..<BUILDING_CAPACITY {
		if !w.buildingUsed[i] {
			continue
		}
		building_x := w.buildings.x[i]
		building_y := w.buildings.y[i]
		building_width := w.buildings.width[i]
		building_height := w.buildings.height[i]

		if x < building_x + building_width && x + width > building_x &&
			y < building_y + building_height && y + height > building_y {
			return true
		}
	}
	return false
}

WorldBuildingValid :: proc(w: ^World, x, y: int, type: BuildingType) -> bool {
	return !WorldBuildingCollides(w, x, y, type) && WorldBuildingOverTile(w, x, y, type)
}
