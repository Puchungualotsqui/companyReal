package main

Building :: struct {
	x, y: int,
	health: f32,
	type: BuildingType,
}

BuildingType :: union {
	Wall,
	TownHall,
}

Wall :: struct {}

TownHall :: struct {}

BuildingSpawn :: proc(w: ^World, x, y: int, health: f32) -> EntityId {
	id := WorldCreateEntity(w)
	append(&w.buildings, BuildingComponent{
		entity = id,
		data = Building{x = x, y = y, health = health},
	})
	return id
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

UnitSpawn :: proc(w: ^World, type: UnitType, x, y: f32) -> EntityId {
	id := WorldCreateEntity(w)
	unit := Unit{
		x = x,
		y = y,
		health = UnitDefaultHealth(type),
		speed = UnitDefaultSpeed(type),
		cooldown = UnitDefaultCooldown(type),
		range = UnitDefaultRange(type),
		vision = UnitDefaultVision(type),
		damage = UnitDefaultDamage(type),
		type = type,
	}
	append(&w.units, UnitComponent{entity = id, data = unit})
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
