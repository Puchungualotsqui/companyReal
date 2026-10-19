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
