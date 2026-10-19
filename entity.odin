package main

Building :: struct {
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

BuildingSpawn :: proc(w: ^World, x, y: int, health: f32, type: BuildingType) -> (int, bool) {
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
	w.buildings.health[i] = health
	w.buildings.type[i] = type
	w.buildingUsed[i] = true
	return i, true
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
