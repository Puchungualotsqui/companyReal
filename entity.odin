package main

Building :: struct {
	x, y: int,
	health: f32,
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
