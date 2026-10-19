package main

EntityId :: distinct uint

INVALID_ENTITY_ID : EntityId : 0

UnitComponent :: struct {
	entity: EntityId,
	data: Unit,
}

BuildingComponent :: struct {
	entity: EntityId,
	data: Building,
}

World :: struct {
	next_entity_id: uint,
	units: [dynamic]UnitComponent,
	buildings: [dynamic]BuildingComponent,
}

WorldInit :: proc(w: ^World) {
	w.next_entity_id = 1
	w.units = make([dynamic]UnitComponent, 0, 100)
	w.buildings = make([dynamic]BuildingComponent, 0, 100)
}

WorldDeinit :: proc(w: ^World) {
	delete(w.units)
	delete(w.buildings)
}

WorldCreateEntity :: proc(w: ^World) -> EntityId {
	id := EntityId(w.next_entity_id)
	w.next_entity_id += 1
	return id
}

UnitGet :: proc(w: ^World, id: EntityId) -> (^Unit, bool) {
	for i in 0..<len(w.units) {
		if w.units[i].entity == id {
			return &w.units[i].data, true
		}
	}
	return nil, false
}

BuildingGet :: proc(w: ^World, id: EntityId) -> (^Building, bool) {
	for i in 0..<len(w.buildings) {
		if w.buildings[i].entity == id {
			return &w.buildings[i].data, true
		}
	}
	return nil, false
}
