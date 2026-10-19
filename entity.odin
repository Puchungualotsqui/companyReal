package main

Building :: struct {
	entity: EntityId,
	x, y: int,
	width, height: int,
	health: f32,
	type: BuildingType,
}

BuildingType :: union {
	Wall,
	TownHall,
}

Wall :: struct {}

TownHall :: struct {}

BuildingSpawn :: proc(w: ^World, x, y: int, health: f32, type: BuildingType) -> EntityId {
	if w.building_count >= BUILDING_CAPACITY {
		return INVALID_ENTITY_ID
	}

	i := w.building_count
	id := EntityId(i + 1)
	w.buildings.entity[i] = id
	w.buildings.x[i] = x
	w.buildings.y[i] = y
	w.buildings.width[i], w.buildings.height[i] = BuildingTileSize(type)
	w.buildings.health[i] = health
	w.buildings.type[i] = type
	w.building_count += 1
	return id
}

BuildingTileSize :: proc(type: BuildingType) -> (int, int) {
	switch t in type {
	case Wall:
		return 1, 1
	case TownHall:
		return 4, 4
	}
	unreachable()
}

BuildingDefaultHealth :: proc(type: BuildingType) -> f32 {
	switch t in type {
	case Wall:
		return 300
	case TownHall:
		return 1000
	}
	unreachable()
}

Unit :: struct {
	entity: EntityId,
	x, y: f32,
	health: f32,
	speed: f32,
	cooldown: f32,
	range: f32,
	vision: f32,
	damage: f32,
	type: UnitType,
}

UnitType :: union {
	Knight,
}

Knight :: struct {}

Giant :: struct {}

UnitSpawn :: proc(w: ^World, type: UnitType, x, y: f32) -> EntityId {
	if w.unit_count >= UNIT_CAPACITY {
		return INVALID_ENTITY_ID
	}

	i := w.unit_count
	id := EntityId(i + 1)
	w.units.entity[i] = id
	w.units.x[i] = x
	w.units.y[i] = y
	w.units.health[i] = UnitDefaultHealth(type)
	w.units.speed[i] = UnitDefaultSpeed(type)
	w.units.cooldown[i] = UnitDefaultCooldown(type)
	w.units.range[i] = UnitDefaultRange(type)
	w.units.vision[i] = UnitDefaultVision(type)
	w.units.damage[i] = UnitDefaultDamage(type)
	w.units.type[i] = type
	w.unit_count += 1
	return id
}

UnitDefaultHealth :: proc(type: UnitType) -> f32 {
	switch t in type {
	case Knight:
		return 50
	}
	unreachable()
}

UnitDefaultSpeed :: proc(type: UnitType) -> f32 {
	switch t in type {
	case Knight:
		return 10
	}
	unreachable()
}

UnitDefaultCooldown :: proc(type: UnitType) -> f32 {
	switch t in type {
	case Knight:
		return 1
	}
	unreachable()
}

UnitDefaultRange :: proc(type: UnitType) -> f32 {
	switch t in type {
	case Knight:
		return 0.75
	}
	unreachable()
}

UnitDefaultVision :: proc(type: UnitType) -> f32 {
	switch t in type {
	case Knight:
		return 25
	}
	unreachable()
}

UnitDefaultDamage :: proc(type: UnitType) -> f32 {
	switch t in type {
	case Knight:
		return 15
	}
	unreachable()
}
