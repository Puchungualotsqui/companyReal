package main

Building :: struct {
	x, y: int,
	health: f32,
	cooldown: f32,
	type: BuildingType,
	kingdom: int,
	town: int,
	homeResident: int, 	// Zero means vacant; otherwise the assigned citizen slot plus one
}

BuildingKind :: enum {
	TownHall,
	Home,
	Farmland,
	Wall,
	Bridge,
	Cannon,
	Watchtower,
	ArcheryRange,
	MagicSchool,
	GiantPen,
	SiegeWorkshop,
	TurtlePen,
	ThievesGuild,
	Path,
}

BuildingType :: union {
	TownHall,
	Home,
	Farmland,
	Wall,
	Bridge,
	Cannon,
	Watchtower,
	ArcheryRange,
	MagicSchool,
	GiantPen,
	SiegeWorkshop,
	TurtlePen,
	ThievesGuild,
	Path,
}

TownHall :: struct {}
Home :: struct {}
Farmland :: struct {}
Wall :: struct {}
Bridge :: struct {}
Cannon :: struct {}
Watchtower :: struct {}
ArcheryRange :: struct {}
MagicSchool :: struct {}
GiantPen :: struct {}
SiegeWorkshop :: struct {}
TurtlePen :: struct {}
ThievesGuild :: struct {}
Path :: struct {}

BuildingKindOf :: proc(type: BuildingType) -> BuildingKind {
	switch _ in type {
	case TownHall:
		return .TownHall
	case Home:
		return .Home
	case Farmland:
		return .Farmland
	case Wall:
		return .Wall
	case Bridge:
		return .Bridge
	case Cannon:
		return .Cannon
	case Watchtower:
		return .Watchtower
	case ArcheryRange:
		return .ArcheryRange
	case MagicSchool:
		return .MagicSchool
	case GiantPen:
		return .GiantPen
	case SiegeWorkshop:
		return .SiegeWorkshop
	case TurtlePen:
		return .TurtlePen
	case ThievesGuild:
		return .ThievesGuild
	case Path:
		return .Path
	}
	unreachable()
}

BuildingTypeFromKind :: proc(kind: BuildingKind) -> BuildingType {
	switch kind {
	case .TownHall:
		return TownHall{}
	case .Home:
		return Home{}
	case .Farmland:
		return Farmland{}
	case .Wall:
		return Wall{}
	case .Bridge:
		return Bridge{}
	case .Cannon:
		return Cannon{}
	case .Watchtower:
		return Watchtower{}
	case .ArcheryRange:
		return ArcheryRange{}
	case .MagicSchool:
		return MagicSchool{}
	case .GiantPen:
		return GiantPen{}
	case .SiegeWorkshop:
		return SiegeWorkshop{}
	case .TurtlePen:
		return TurtlePen{}
	case .ThievesGuild:
		return ThievesGuild{}
	case .Path:
		return Path{}
	}
	unreachable()
}

// width, height
BuildingTileSize :: proc(type: BuildingType) -> (int, int) {
	switch _ in type {
	case TownHall:
		return 4, 4
	case Home:
		return 1, 1
	case Farmland:
		return 2, 2
	case Wall:
		return 1, 1
	case Bridge:
		return 1, 1
	case Cannon:
		return 2, 2
	case Watchtower:
		return 1, 1
	case ArcheryRange, MagicSchool, TurtlePen:
		return 3, 3
	case GiantPen:
		return 4, 4
	case SiegeWorkshop:
		return 4, 3
	case ThievesGuild:
		return 2, 3
	case Path:
		return 1, 1
	}
	unreachable()
}

BuildingDefaultHealth :: proc(type: BuildingType) -> f32 {
	switch _ in type {
	case TownHall:
		return 1000
	case Home, Farmland:
		return 100
	case Wall:
		return 300
	case Bridge:
		return 150
	case Cannon:
		return 250
	case Watchtower:
		return 200
	case ArcheryRange, MagicSchool, TurtlePen:
		return 300
	case GiantPen:
		return 400
	case SiegeWorkshop:
		return 350
	case ThievesGuild:
		return 250
	case Path:
		return 80
	}
	unreachable()
}

// Buildings also uncover and keep watch over the surrounding area.
BuildingVision :: proc(kind: BuildingKind) -> f32 {
	switch kind {
	case .TownHall:
		return 14
	case .Watchtower:
		return 20
	case .Cannon:
		return 9
	case .ArcheryRange, .MagicSchool, .GiantPen, .SiegeWorkshop, .TurtlePen, .ThievesGuild:
		return 8
	case .Home:
		return 5
	case .Farmland:
		return 3
	case .Wall:
		return 2
	case .Bridge:
		return 3
	case .Path:
		return 2
	}
	unreachable()
}

// Radius at which an armed building notices a hostile and reacts. It is wider
// than its vision, like a unit's distraction radius.
BuildingDistraction :: proc(kind: BuildingKind) -> f32 {
	switch kind {
	case .TownHall:
		return 20
	case .Watchtower:
		return 28
	case .Cannon:
		return 16
	case .ArcheryRange, .MagicSchool, .GiantPen, .SiegeWorkshop, .TurtlePen, .ThievesGuild:
		return 12
	case .Home:
		return 8
	case .Farmland:
		return 5
	case .Wall, .Bridge, .Path:
		return 4
	}
	unreachable()
}

BuildingWoodCost :: proc(kind: BuildingKind) -> f32 {
	switch kind {
	case .TownHall:
		return 0
	case .Home:
		return 5
	case .Farmland:
		return 8
	case .Wall:
		return 0
	case .Bridge, .Cannon, .Watchtower:
		return 0
	case .ArcheryRange:
		return 25
	case .MagicSchool:
		return 30
	case .GiantPen:
		return 40
	case .SiegeWorkshop:
		return 35
	case .TurtlePen:
		return 30
	case .ThievesGuild:
		return 30
	case .Path:
		return 1
	}
	unreachable()
}

BuildingValidTileType :: proc(bType: BuildingType, tType: TileType) -> bool {
	switch _ in bType {
	case Bridge:
		switch tType {
		case .Water, .FreshWater, .River:
			return true
		case .Ground, .FertileGround, .Forest, .Hill, .Desert, .Sand:
			return false
		}

	case Farmland:
		switch tType {
		case .Ground, .FertileGround:
			return true
		case .Water, .FreshWater, .River, .Forest, .Hill, .Desert, .Sand:
			return false
		}

	case TownHall, Home, Wall, Cannon, Watchtower, ArcheryRange, MagicSchool, GiantPen, SiegeWorkshop, TurtlePen, ThievesGuild, Path:
		switch tType {
		case .Ground, .FertileGround, .Forest, .Hill, .Desert, .Sand:
			return true
		case .Water, .FreshWater, .River:
			return false
		}
	}
	unreachable()
}

BuildingWalkable :: proc(type: BuildingType) -> bool {
	switch _ in type {
	case Bridge, Path:
		return true
	case TownHall, Home, Farmland, Wall, Cannon, Watchtower, ArcheryRange, MagicSchool, GiantPen, SiegeWorkshop, TurtlePen, ThievesGuild:
		return false
	}
	unreachable()
}

// Combat buildings are placed by the player anywhere in the world and raised by
// combat builders without wood. Everything else is built by the town itself.
BuildingIsCombat :: proc(kind: BuildingKind) -> bool {
	switch kind {
	case .Wall, .Bridge, .Cannon, .Watchtower:
		return true
	case .TownHall, .Home, .Farmland, .ArcheryRange, .MagicSchool, .GiantPen, .SiegeWorkshop, .TurtlePen, .ThievesGuild, .Path:
		return false
	}
	unreachable()
}

BuildingIsTraining :: proc(kind: BuildingKind) -> bool {
	switch kind {
	case .ArcheryRange, .MagicSchool, .GiantPen, .SiegeWorkshop, .TurtlePen, .ThievesGuild:
		return true
	case .TownHall, .Home, .Farmland, .Wall, .Bridge, .Cannon, .Watchtower, .Path:
		return false
	}
	unreachable()
}

Unit :: struct {
	x, y: f32,
	previousX, previousY: f32,
	health: f32,
	burning: f32,
	cooldown: f32,
	type: UnitType,
	kingdome: int,
	town: int,
	state: UnitState,
	sleepOffsetHours: f32,
	homeSlot: int,
	sleepInside: bool,
	sleepNavigationRevision: u64,
	roamSequence: int,
	effects: [UnitEffects]bool,
	//
	path: [dynamic]int,
	pathTargetX, pathTargetY: int,
	pathRevision: u64,
	pathIndex: int,
	pathReady, pathFound: bool,
	jumpStarted: f32,
}

UnitEffects :: enum {
	NoHome,
	NoWater,
	NoFood,
}

ALL_UNIT_EFFECTS := [3]UnitEffects {
	.NoHome,
	.NoWater,
	.NoFood,
}

UnitKind :: enum {
	Villager,
	Builder,
	CombatBuilder,
	WaterCollector,
	Farmer,
	Knight,
	Archer,
	Mage,
	Giant,
	Turtle,
	Catapult,
	Rogue,
	Explorer,
}

UnitType :: union {
	Villager,
	Builder,
	CombatBuilder,
	WaterCollector,
	Farmer,
	Knight,
	Archer,
	Mage,
	Giant,
	Turtle,
	Catapult,
	Rogue,
	Explorer,
}

UnitState :: union {
	StatePacific,
	StateWarrior,
	StateConverting,
}

StatePacific :: enum {
	Roaming,
	Traveling,
	Working,
	Returning,
	ToConstruction,
	Building,
	GoingHome,
	Sleeping,
	Hiding,
	Fleeing,
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

// Active conversion: the unit walks to a training building, waits, then
// changes type in place.
StateConverting :: struct {
	to: UnitKind,
	building: int,
	accessX, accessY: int,
	timer: f32,
	retryTimer: f32,
	inside: bool,
}

Villager :: struct {}
Builder :: struct {
	carriedResource:  f32,
	taskSequence:     int,
	targetDecoration: int,
}
CombatBuilder :: struct {
	order:           WarriorOrder,
	orderRevision:   u64,
	orderKingdom, orderTown: int,
	patrolSequence:  int,
	returning:        bool,
	onStation:        bool,
	site:            int,
	siteSequence:    int,
	failedSite:      int,
	failedRevision:  u64,
	scanTimer:       f32,
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
Archer :: struct {}
Mage :: struct {}
Giant :: struct {}
Turtle :: struct {}
Catapult :: struct {}
Rogue :: struct {}
Explorer :: struct {
	restTimer: f32,
	tripsLeft: int,
	journey: int,
}

UnitKindOf :: proc(type: UnitType) -> UnitKind {
	switch _ in type {
	case Villager:
		return .Villager
	case Builder:
		return .Builder
	case CombatBuilder:
		return .CombatBuilder
	case WaterCollector:
		return .WaterCollector
	case Farmer:
		return .Farmer
	case Knight:
		return .Knight
	case Archer:
		return .Archer
	case Mage:
		return .Mage
	case Giant:
		return .Giant
	case Turtle:
		return .Turtle
	case Catapult:
		return .Catapult
	case Rogue:
		return .Rogue
	case Explorer:
		return .Explorer
	}
	unreachable()
}

UnitTypeFromKind :: proc(kind: UnitKind) -> UnitType {
	switch kind {
	case .Villager:
		return Villager{}
	case .Builder:
		return Builder{}
	case .CombatBuilder:
		return CombatBuilder{}
	case .WaterCollector:
		return WaterCollector{}
	case .Farmer:
		return Farmer{}
	case .Knight:
		return Knight{}
	case .Archer:
		return Archer{}
	case .Mage:
		return Mage{}
	case .Giant:
		return Giant{}
	case .Turtle:
		return Turtle{}
	case .Catapult:
		return Catapult{}
	case .Rogue:
		return Rogue{}
	case .Explorer:
		return Explorer{}
	}
	unreachable()
}

UnitIsWarrior :: proc(type: UnitType) -> bool {
	switch _ in type {
	case Knight, Archer, Mage, Giant, Turtle, Catapult, Rogue:
		return true
	case Villager, Builder, CombatBuilder, WaterCollector, Farmer, Explorer:
		return false
	}
	unreachable()
}

UnitTrainingBuildingKind :: proc(kind: UnitKind) -> BuildingKind {
	switch kind {
	case .Villager, .Builder, .CombatBuilder, .WaterCollector, .Farmer, .Knight, .Explorer:
		return .TownHall
	case .Archer:
		return .ArcheryRange
	case .Mage:
		return .MagicSchool
	case .Giant:
		return .GiantPen
	case .Turtle:
		return .TurtlePen
	case .Catapult:
		return .SiegeWorkshop
	case .Rogue:
		return .ThievesGuild
	}
	unreachable()
}

UnitDefaultHealth :: proc(type: UnitType) -> f32 {
	switch _ in type {
	case Villager, Builder, WaterCollector, Farmer:
		return 15
	case CombatBuilder:
		return 10
	case Knight:
		return 50
	case Archer:
		return 30
	case Mage:
		return 25
	case Giant:
		return 100
	case Turtle:
		return 140
	case Catapult:
		return 60
	case Rogue:
		return 35
	case Explorer:
		return 18
	}
	unreachable()
}

UnitDefaultSpeed :: proc(type: UnitType) -> f32 {
	switch _ in type {
	case Villager:
		return 3
	case Builder, WaterCollector, Farmer:
		return 2.5
	case CombatBuilder:
		return 3
	case Knight:
		return 3.5
	case Archer:
		return 3.2
	case Mage:
		return 2.8
	case Giant:
		return 2
	case Turtle:
		return 2
	case Catapult:
		return 1.5
	case Rogue:
		return 4
	case Explorer:
		return 1.8
	}
	unreachable()
}

UnitDefaultCooldown :: proc(type: UnitType) -> f32 {
	switch _ in type {
	case Villager, Builder, WaterCollector, Farmer:
		return 0
	case CombatBuilder:
		return 2
	case Knight:
		return 1
	case Archer:
		return 1.2
	case Mage:
		return 2
	case Giant:
		return 1.75
	case Turtle:
		return 2
	case Catapult:
		return 3
	case Rogue:
		return 0.6
	case Explorer:
		return 0
	}
	unreachable()
}

UnitDefaultRange :: proc(type: UnitType) -> f32 {
	switch _ in type {
	case Villager, Builder, WaterCollector, Farmer:
		return 0
	case CombatBuilder:
		return 1.2
	case Knight:
		return 0.75
	case Archer:
		return 8
	case Mage:
		return 7
	case Giant:
		return 0.8
	case Turtle:
		return 0.9
	case Catapult:
		return 12
	case Rogue:
		return 0.75
	case Explorer:
		return 0
	}
	unreachable()
}

UnitDefaultVision :: proc(type: UnitType) -> f32 {
	switch _ in type {
	case Villager, Builder, WaterCollector, Farmer:
		return 30
	case CombatBuilder:
		return 24
	case Knight:
		return 25
	case Archer:
		return 30
	case Mage:
		return 30
	case Giant:
		return 40
	case Turtle:
		return 30
	case Catapult:
		return 35
	case Rogue:
		return 30
	case Explorer:
		return 34
	}
	unreachable()
}

// Enemy-detection radius used by combat AI. A unit may react before it can
// actually reveal the area to the player, which keeps guards proactive.
UnitDistraction :: proc(type: UnitType) -> f32 {
	switch _ in type {
	case Villager, Builder, WaterCollector, Farmer:
		return 34
	case CombatBuilder:
		return 30
	case Knight:
		return 40
	case Archer:
		return 40
	case Mage:
		return 38
	case Giant:
		return 55
	case Turtle:
		return 45
	case Catapult:
		return 50
	case Rogue:
		return 45
	case Explorer:
		return 36
	}
	unreachable()
}

UnitDefaultDamage :: proc(type: UnitType) -> f32 {
	switch _ in type {
	case Villager, Builder, WaterCollector, Farmer:
		return 0
	case CombatBuilder:
		return 3
	case Knight:
		return 15
	case Archer:
		return 10
	case Mage:
		return 12
	case Giant:
		return 30
	case Turtle:
		return 20
	case Catapult:
		return 25
	case Rogue:
		return 20
	case Explorer:
		return 0
	}
	unreachable()
}

UnitDefaultAreaRadius :: proc(type: UnitType) -> f32 {
	switch _ in type {
	case Mage:
		return 3
	case Giant:
		return 2
	case Catapult:
		return 3.5
	case Villager, Builder, WaterCollector, Farmer, Knight, Archer, Turtle, Rogue, Explorer:
		return 0
	case CombatBuilder:
		return 0
	}
	unreachable()
}

UnitDefaultTrainingTime :: proc(kind: UnitKind) -> f32 {
	switch kind {
	case .Villager:
		return 1
	case .Builder, .WaterCollector, .Farmer:
		return 1.5
	case .CombatBuilder:
		return 2.5
	case .Knight:
		return 2
	case .Archer:
		return 3
	case .Mage:
		return 5
	case .Giant:
		return 6
	case .Turtle:
		return 6
	case .Catapult:
		return 7
	case .Rogue:
		return 4
	case .Explorer:
		return 2
	}
	unreachable()
}

UnitValidTileType :: proc(uType: UnitType, tType: TileType) -> bool {
	switch tType {
	case .Water, .FreshWater:
		switch _ in uType {
		case Turtle:
			return true
		case Villager, Builder, WaterCollector, Farmer, Knight, Archer, Mage, Giant, Catapult, Rogue, Explorer:
			return false
		case CombatBuilder:
			return false
		}

	case .Ground, .FertileGround, .Forest, .Hill, .Desert, .River, .Sand:
		return true
	}
	unreachable()
}

// Shared initialization for spawning and for in-place conversions.
UnitTypeInit :: proc(w: ^World, unit_slot: int, type: UnitType) {
	if unit_slot < 0 || unit_slot >= UNIT_CAPACITY || !w.unitUsed[unit_slot] do return
	UnitSleepWake(w, unit_slot)
	unit := &w.units[unit_slot]
	if state, converting := unit.state.(StateConverting); converting && state.inside {
		SpatialUnitMove(w, unit_slot)
	}
	if unit.burning > 0 {
		unit.burning = 0
		w.unitsBurning -= 1
	}
	unit.type = type
	unit.health = UnitDefaultHealth(type)
	unit.cooldown = UnitDefaultCooldown(type)
	switch _ in type {
	case Villager:
		unit.type = Villager{}
		unit.state = StatePacific.Roaming
	case Builder:
		unit.type = Builder{carriedResource = 0, taskSequence = 0, targetDecoration = -1}
		unit.state = StatePacific.Roaming
	case CombatBuilder:
		unit.type = CombatBuilder{site = -1, failedSite = -1, orderKingdom = -1}
		unit.state = StatePacific.Roaming
	case WaterCollector:
		unit.type = WaterCollector{carriedResource = 0, taskSequence = 0}
		unit.state = StatePacific.Roaming
	case Farmer:
		unit.type = Farmer{workedToday = false, workDay = -1}
		unit.state = StatePacific.Roaming
	case Knight:
		unit.type = Knight{}
		unit.state = StateWarriorInit(unit_slot, unit.kingdome, unit.town)
	case Archer:
		unit.type = Archer{}
		unit.state = StateWarriorInit(unit_slot, unit.kingdome, unit.town)
	case Mage:
		unit.type = Mage{}
		unit.state = StateWarriorInit(unit_slot, unit.kingdome, unit.town)
	case Giant:
		unit.type = Giant{}
		unit.state = StateWarriorInit(unit_slot, unit.kingdome, unit.town)
	case Turtle:
		unit.type = Turtle{}
		unit.state = StateWarriorInit(unit_slot, unit.kingdome, unit.town)
	case Catapult:
		unit.type = Catapult{}
		unit.state = StateWarriorInit(unit_slot, unit.kingdome, unit.town)
	case Rogue:
		unit.type = Rogue{}
		unit.state = StateWarriorInit(unit_slot, unit.kingdome, unit.town)
	case Explorer:
		unit.type = Explorer{tripsLeft = 3}
		unit.state = StatePacific.Roaming
	}
	unit.pathReady = false
	unit.pathFound = false
	unit.jumpStarted = -WALL_JUMP_SECONDS
}

UnitSetType :: proc(w: ^World, unit_slot: int, kind: UnitKind) {
	if unit_slot < 0 || unit_slot >= UNIT_CAPACITY || !w.unitUsed[unit_slot] do return
	unit := &w.units[unit_slot]
	if WorldTownExists(w, unit.kingdome, unit.town) &&
		(UnitIsWarrior(unit.type) || UnitKindOf(unit.type) == .CombatBuilder ||
		kind == .CombatBuilder || UnitIsWarrior(UnitTypeFromKind(kind))) {
		w.kingdoms[unit.kingdome].towns[unit.town].orderRevision += 1
	}
	UnitTypeInit(w, unit_slot, UnitTypeFromKind(kind))
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
		unit.pathFound = AStar(w, unit.type, unit.kingdome, start_x, start_y, target_x, target_y, &unit.path)
		unit.pathTargetX = target_x
		unit.pathTargetY = target_y
		unit.pathRevision = w.navigationRevision
		unit.pathReady = true
		unit.pathIndex = 1
		if len(unit.path) == 1 do unit.pathIndex = 0
	}
	if !unit.pathFound do return false

	speed := UnitMoveSpeed(w, unit_slot, UnitDefaultSpeed(unit.type))

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

		if WorldTileFriendlyWall(w, int(unit_x), int(unit_y), unit.kingdome) {
			unit.jumpStarted = w.simulationTime
		}
		if !reached_waypoint do break
		unit.pathIndex += 1
	}

	unit.x = unit_x
	unit.y = unit_y
	SpatialUnitMove(w, unit_slot)
	return unit.pathIndex >= len(unit.path)
}
