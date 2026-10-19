package main

Building :: struct {
	x, y: int,
	width, height: int,
	health: f32,
	type: BuildingType,
	town: Town,
}

BuildingType :: union {
	Wall,
	TownHall,
}

Wall :: struct {}

TownHall :: struct {}

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

BuildingValidTileType :: proc(bType: BuildingType, tType: TileType) -> bool {
	switch tType {
	case .Water:
		switch _ in bType {
		case Wall, TownHall:
			return false
		}

	case .Ground:
		switch _ in bType {
		case Wall, TownHall:
			return true
		}

	case .Desert:
		switch _ in bType {
		case Wall, TownHall:
			return true
		}
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
	town: Town,
}

UnitType :: union {
	Knight,
}

Knight :: struct {}

Giant :: struct {}

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
