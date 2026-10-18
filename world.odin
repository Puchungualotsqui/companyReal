package main

EntityId :: distinct uint
BuildingId :: distinct uint

INVALID_ENTITY_ID : EntityId : 0
INVALID_BUILDING_ID : BuildingId : 0

World :: struct {
	buildings: [dynamic]Building,
	units: [dynamic]Unit,
}

WorldInit :: proc(w: ^World) {
	w.buildings = make([dynamic]Building, 0, 100)
	w.units = make([dynamic]Unit, 0, 100)
}

WorldDeinit :: proc(w: ^World) {
	delete(w.buildings)
	delete(w.units)
}
