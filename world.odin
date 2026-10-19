package main

EntityId :: distinct uint

INVALID_ENTITY_ID : EntityId : 0

UNIT_CAPACITY :: 10_000
BUILDING_CAPACITY :: 5_000

World :: struct {
	unit_count: int,
	building_count: int,
	units: #soa [UNIT_CAPACITY]Unit,
	buildings: #soa [BUILDING_CAPACITY]Building,
	maxX, maxY: uint,
}

WorldInit :: proc(w: ^World, maxX, maxY: uint) {
	w.unit_count = 0
	w.building_count = 0

	w.maxX = maxX
	w.maxY = maxY
}

UnitGet :: proc(w: ^World, id: EntityId) -> (int, bool) {
	for i in 0..<w.unit_count {
		if w.units.entity[i] == id {
			return i, true
		}
	}
	return 0, false
}

BuildingGet :: proc(w: ^World, id: EntityId) -> (int, bool) {
	for i in 0..<w.building_count {
		if w.buildings.entity[i] == id {
			return i, true
		}
	}
	return 0, false
}

WorldTileOccupied :: proc(w: ^World, x, y: int) -> bool {
	for i in 0..<w.building_count {
		building_x := w.buildings.x[i]
		building_y := w.buildings.y[i]
		if x >= building_x && x < building_x + w.buildings.width[i] &&
			y >= building_y && y < building_y + w.buildings.height[i] {
			return true
		}
	}
	return false
}

WorldBuildingCollides :: proc(w: ^World, x, y, width, height: int) -> bool {
	if x < 0 || y < 0 || width <= 0 || height <= 0 ||
		x + width > int(w.maxX) || y + height > int(w.maxY) {
		return true
	}

	for i in 0..<w.building_count {
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
