package main

Building :: struct {
	x, y: int,
	health: f32,
	type: BuildingType,
	kingdom: int,
	town: int,
}

BuildingType :: union {
	Wall,
	TownHall,
	Home,
	Farmland,
}

Wall :: struct {}
TownHall :: struct {}
Home :: struct {}
Farmland :: struct {}

// width, height
BuildingTileSize :: proc(type: BuildingType) -> (int, int) {
	switch t in type {
	case Wall:
		return 1, 1
	case TownHall:
		return 4, 4
	case Home:
		return 1, 1
	case Farmland:
		return 2, 2
	}
	unreachable()
}

BuildingDefaultHealth :: proc(type: BuildingType) -> f32 {
	switch t in type {
	case Wall:
		return 300
	case TownHall:
		return 1000
	case Home, Farmland:
		return 100
	}
	unreachable()
}

BuildingValidTileType :: proc(bType: BuildingType, tType: TileType) -> bool {
	switch tType {
	case .Water, .FreshWater, .River:
		return false

	case .Ground, .FertileGround:
		switch _ in bType {
		case Farmland:
			return true
		case Wall, TownHall, Home:
			return true
		}

	case .Forest, .Hill, .Desert, .Sand:
		switch _ in bType {
		case Wall, TownHall, Home:
			return true
		case Farmland:
			return false
		}
	}
	unreachable()
}

Unit :: struct {
	x, y: f32,
	health: f32,
	cooldown: f32,
	type: UnitType,
	kingdome: int,
	town: int,
	state: UnitState,
	sleepOffsetHours: f32,
	roamSequence: int,
	effects: [UnitEffects]bool,
	//
	path: [dynamic]int,
	pathTargetX, pathTargetY: int,
	pathRevision: u64,
	pathIndex: int,
	pathReady, pathFound: bool,
}

UnitEffects :: enum {
	NoHome,
	NoWater,
	NoFood,
}

UnitType :: union {
	Villager,
	Builder,
	WaterCollector,
	Farmer,
	Knight,
	Giant,
}

UnitState :: union {
	StatePacific,
	StateWarrior,
}

StatePacific :: enum {
	Roaming,
	Traveling,
	Working,
	Returning,
	GoingHome,
	Sleeping,
}

StateWarrior :: struct {
	activity: WarriorActivity,
	order: WarriorOrder,
	orderKingdom, orderTown: int,
	orderRevision: u64,
	target: WarriorTarget,
	scanTimer: f32,
	scanSequence: int,
	patrolSequence: int,
	escortTarget: int,
}

WarriorActivity :: enum {
	Idle,
	Moving,
	Escorting,
	Attacking,
}

WarriorOrder :: union {
	WarriorIdle,
	WarriorGarrison,
	WarriorAttack,
	WarriorDefend,
}

WarriorIdle :: struct {}
WarriorGarrison :: struct {}
WarriorAttack :: struct {
	kingdom, town: int,
}
WarriorDefend :: struct {
	kingdom, town: int,
}

WarriorTarget :: union {
	TargetNone,
	TargetUnit,
	TargetBuilding,
}

TargetNone :: struct {}
TargetUnit :: struct {
	slot: int,
}
TargetBuilding :: struct {
	slot: int,
}

Villager :: struct {}
Builder :: struct {
	carriedResource: f32,
	taskSequence: int,
}
WaterCollector :: struct {
	carriedResource: f32,
	taskSequence: int,
}
Farmer :: struct {
	workedToday: bool,
	workDay: int,
}
Knight :: struct {}
Giant :: struct {}

UnitDefaultHealth :: proc(type: UnitType) -> f32 {
	switch t in type {
	case Knight:
		return 50
	case Giant:
		return 100
	case Villager, Builder, WaterCollector, Farmer:
		return 15
	}
	unreachable()
}

UnitDefaultSpeed :: proc(type: UnitType) -> f32 {
	switch t in type {
	case Knight:
		return 10
	case Giant:
		return 7.5
	case Villager:
		return 12
	case Builder, WaterCollector, Farmer:
		return 5
	}
	unreachable()
}

UnitDefaultCooldown :: proc(type: UnitType) -> f32 {
	switch t in type {
	case Knight:
		return 1
	case Giant:
		return 1.75
	case Villager, Builder, WaterCollector, Farmer:
		return 0
	}
	unreachable()
}

UnitDefaultRange :: proc(type: UnitType) -> f32 {
	switch t in type {
	case Knight:
		return 0.75
	case Giant:
		return 0.80
	case Villager, Builder, WaterCollector, Farmer:
		return 0
	}
	unreachable()
}

UnitDefaultVision :: proc(type: UnitType) -> f32 {
	switch t in type {
	case Knight:
		return 25
	case Giant:
		return 40
	case Villager, Builder, WaterCollector, Farmer:
		return 30
	}
	unreachable()
}

UnitDefaultDamage :: proc(type: UnitType) -> f32 {
	switch t in type {
	case Knight:
		return 15
	case Giant:
		return 30
	case Villager, Builder, WaterCollector, Farmer:
		return 0
	}
	unreachable()
}

UnitValidTileType :: proc(uType: UnitType, tType: TileType) -> bool {
	switch tType {
	case .Water, .FreshWater:
		return false

	case .Ground, .FertileGround, .Forest, .Hill, .Desert, .River, .Sand:
		switch _ in uType {
		case Knight, Giant, Villager, Builder, WaterCollector, Farmer:
			return true
		}
	}

	unreachable()
}

UnitMove :: proc(w: ^World, unit_slot, goal_x, goal_y: int, delta_time: f32) -> bool {
	unit_index, exists := UnitGet(w, unit_slot)
	if !exists || delta_time < 0 do return false

	world_width := int(w.maxX)
	world_height := int(w.maxY)
	if world_width <= 0 || world_height <= 0 do return false

	unit := &w.units[unit_index]
	unit_x := WorldWrapPosition(unit.x, f32(world_width))
	unit_y := WorldWrapPosition(unit.y, f32(world_height))
	target_x := WorldWrapCoordinate(goal_x, world_width)
	target_y := WorldWrapCoordinate(goal_y, world_height)

	needs_path := !unit.pathReady || unit.pathTargetX != target_x ||
		unit.pathTargetY != target_y || unit.pathRevision != w.navigationRevision
	if needs_path {
		start_x := WorldWrapCoordinate(int(unit_x), world_width)
		start_y := WorldWrapCoordinate(int(unit_y), world_height)
		unit.pathFound = AStar(w, unit.type, start_x, start_y, target_x, target_y, &unit.path)
		unit.pathTargetX = target_x
		unit.pathTargetY = target_y
		unit.pathRevision = w.navigationRevision
		unit.pathReady = true
		unit.pathIndex = 1
		if len(unit.path) == 1 do unit.pathIndex = 0
	}
	if !unit.pathFound do return false

	speed := UnitDefaultSpeed(unit.type)
	if unit.effects[.NoWater] do speed *= 0.7

	remaining := speed * delta_time
	if remaining < 0 do remaining = 0
	for unit.pathIndex < len(unit.path) {
		waypoint := unit.path[unit.pathIndex]
		destination_x := f32(waypoint/world_height) + 0.5
		destination_y := f32(waypoint%world_height) + 0.5
		delta_x := WorldShortestWrappedDelta(destination_x-unit_x, f32(world_width))
		delta_y := WorldShortestWrappedDelta(destination_y-unit_y, f32(world_height))
		reached_waypoint := true

		if delta_x != 0 {
			distance_x := delta_x
			if distance_x < 0 do distance_x = -distance_x
			if remaining >= distance_x {
				unit_x = WorldWrapPosition(unit_x+delta_x, f32(world_width))
				remaining -= distance_x
			} else if remaining > 0 {
				step := remaining
				if delta_x < 0 do step = -step
				unit_x = WorldWrapPosition(unit_x+step, f32(world_width))
				remaining = 0
				reached_waypoint = false
			} else {
				reached_waypoint = false
			}
		}

		if delta_y != 0 {
			distance_y := delta_y
			if distance_y < 0 do distance_y = -distance_y
			if remaining >= distance_y {
				unit_y = WorldWrapPosition(unit_y+delta_y, f32(world_height))
				remaining -= distance_y
			} else if remaining > 0 {
				step := remaining
				if delta_y < 0 do step = -step
				unit_y = WorldWrapPosition(unit_y+step, f32(world_height))
				remaining = 0
				reached_waypoint = false
			} else {
				reached_waypoint = false
			}
		}

		if !reached_waypoint do break
		unit.pathIndex += 1
	}

	unit.x = unit_x
	unit.y = unit_y
	SpatialUnitMove(w, unit_slot)
	return unit.pathIndex >= len(unit.path)
}
