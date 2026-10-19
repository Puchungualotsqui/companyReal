package main

UNIT_CAPACITY :: 10_000
BUILDING_CAPACITY :: 5_000

World :: struct {
	units: #soa [UNIT_CAPACITY]Unit,
	unitUsed: [UNIT_CAPACITY]bool,
	buildings: #soa [BUILDING_CAPACITY]Building,
	buildingUsed: [BUILDING_CAPACITY]bool,
	maxX, maxY: uint,
}

WorldInit :: proc(w: ^World, maxX, maxY: uint) {

	for i in 0..<UNIT_CAPACITY {
		w.unitUsed[i] = false
	}
	for i in 0..<BUILDING_CAPACITY {
		w.buildingUsed[i] = false
	}

	w.maxX = maxX
	w.maxY = maxY
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

WorldBuildingCollides :: proc(w: ^World, x, y, width, height: int) -> bool {
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
