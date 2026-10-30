package main

import "base:intrinsics"
import "d32"

Building :: struct {
	x, y: int,
	health: d32.Value,
	cooldown: d32.Value,
	type: BuildingType,
	kingdom: int,
	town: int,
	homeResident: int, 	// Zero means vacant; otherwise the assigned citizen slot plus one
	output: d32.Value, // Cached farmland fertility
	outputRevision: u64, // Terrain revision the cache was built at
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
	DistrictHall,
	GiantMortar,
	Harbor,
	Granary,
	AlchemistWorkshop,
	FireworksGuild,
	StarfallSpire,
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
	DistrictHall,
	BuildingOrder,
	Granary,
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
DistrictHall :: struct {}
BuildingOrder :: struct {
	orderCooldown: d32.Value,
	orderActive: d32.Value,
	orderTelegraph: d32.Value,
	orderTargetX, orderTargetY: d32.Value,
	orderTick: d32.Value,
	orderMitigation: d32.Value,
	orderKind: OrderKind,
	orderPending: bool,
	type: BuildingOrderType
}

BuildingOrderType :: union {
	GiantMortar,
	Harbor,
	MagicSchool,
	SiegeWorkshop,
	AlchemistWorkshop,
	FireworksGuild,
	StarfallSpire,
}

GiantMortar :: struct {}
Harbor :: struct {}
AlchemistWorkshop :: struct {}
FireworksGuild :: struct {}
StarfallSpire :: struct {}
Granary :: struct {}

BuildingKindOf :: proc(type: BuildingType) -> BuildingKind {
	switch v in type {
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
	case DistrictHall:
		return .DistrictHall
	case Granary:
		return .Granary
	case BuildingOrder:
		switch _ in v.type {
		case GiantMortar:
			return .GiantMortar
		case Harbor:
			return .Harbor
		case MagicSchool:
			return .MagicSchool
		case SiegeWorkshop:
			return .SiegeWorkshop
		case AlchemistWorkshop:
			return .AlchemistWorkshop
		case FireworksGuild:
			return .FireworksGuild
		case StarfallSpire:
			return .StarfallSpire
		}
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
		return BuildingOrder{type = MagicSchool{}, orderKind = .GlacierShell}
	case .GiantPen:
		return GiantPen{}
	case .SiegeWorkshop:
		return BuildingOrder{type = SiegeWorkshop{}, orderKind = .SiegeTremor}
	case .TurtlePen:
		return TurtlePen{}
	case .ThievesGuild:
		return ThievesGuild{}
	case .Path:
		return Path{}
	case .DistrictHall:
		return DistrictHall{}
	case .GiantMortar:
		return BuildingOrder{type = GiantMortar{}, orderKind = .GiantMortar}
	case .Harbor:
		return BuildingOrder{type = Harbor{}, orderKind = .Blockade}
	case .AlchemistWorkshop:
		return BuildingOrder{type = AlchemistWorkshop{}, orderKind = .MiasmaBarrage}
	case .FireworksGuild:
		return BuildingOrder{type = FireworksGuild{}, orderKind = .NapalmBarrage}
	case .StarfallSpire:
		return BuildingOrder{type = StarfallSpire{}, orderKind = .Starfall}
	case .Granary:
		return Granary{}
	}
	unreachable()
}

// width, height
BuildingTileSize :: proc(type: BuildingType) -> (int, int) {
	switch v in type {
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
	case DistrictHall:
		return 4, 4
	case Granary:
		return 2, 2
	case BuildingOrder:
		switch _ in v.type {
		case GiantMortar:
			return 3, 3
		case Harbor:
			return 2, 2
		case MagicSchool:
			return 3, 3
		case SiegeWorkshop:
			return 4, 3
		case AlchemistWorkshop:
			return 2, 3
		case FireworksGuild:
			return 3, 3
		case StarfallSpire:
			return 3, 4
		}
	}
	unreachable()
}

BuildingDefaultHealth :: proc(type: BuildingType) -> d32.Value {
	switch v in type {
	case TownHall:
		return d32.FromInt(1000)
	case Home, Farmland:
		return d32.FromInt(100)
	case Wall:
		return d32.FromInt(300)
	case Bridge:
		return d32.FromInt(150)
	case Cannon:
		return d32.FromInt(250)
	case Watchtower:
		return d32.FromInt(200)
	case ArcheryRange, MagicSchool, TurtlePen:
		return d32.FromInt(300)
	case GiantPen:
		return d32.FromInt(400)
	case SiegeWorkshop:
		return d32.FromInt(350)
	case ThievesGuild:
		return d32.FromInt(250)
	case Path:
		return d32.FromInt(80)
	case DistrictHall:
		return d32.FromInt(600)
	case Granary:
		return d32.FromInt(250)
	case BuildingOrder:
		switch _ in v.type {
		case GiantMortar:
			return d32.FromInt(350)
		case Harbor:
			return d32.FromInt(300)
		case MagicSchool:
			return d32.FromInt(300)
		case SiegeWorkshop:
			return d32.FromInt(350)
		case AlchemistWorkshop:
			return d32.FromInt(300)
		case FireworksGuild:
			return d32.FromInt(350)
		case StarfallSpire:
			return d32.FromInt(500)
		}
	}
	unreachable()
}

BuildingDamageStage :: proc(w: ^World, buildingSlot: int) -> int {
	if buildingSlot < 0 || buildingSlot >= BUILDING_CAPACITY || !w.buildingUsed[buildingSlot] {
		return 0
	}
	maximum := BuildingMaxHealth(w, buildingSlot)
	if maximum <= d32.ZERO do return 0
	// Raw values share one scale, so the percent ratio stays integral.
	percent := i64(d32.Raw(w.buildings.health[buildingSlot]))*100/i64(d32.Raw(maximum))
	if percent <= 33 do return 2
	if percent <= 66 do return 1
	return 0
}

// Buildings also uncover and keep watch over the surrounding area.
BuildingVision :: proc(kind: BuildingKind) -> d32.Value {
	switch kind {
	case .TownHall:
		return d32.FromInt(14)
	case .Watchtower:
		return d32.FromInt(20)
	case .Cannon:
		return d32.FromInt(9)
	case .ArcheryRange, .MagicSchool, .GiantPen, .SiegeWorkshop, .TurtlePen, .ThievesGuild:
		return d32.FromInt(8)
	case .Home:
		return d32.FromInt(5)
	case .Farmland:
		return d32.FromInt(3)
	case .Wall:
		return d32.FromInt(2)
	case .Bridge:
		return d32.FromInt(3)
	case .Path:
		return d32.FromInt(2)
	case .DistrictHall:
		return d32.FromInt(10)
	case .GiantMortar:
		return d32.FromInt(10)
	case .Harbor:
		return d32.FromInt(8)
	case .Granary:
		return d32.FromInt(4)
	case .AlchemistWorkshop, .FireworksGuild:
		return d32.FromInt(8)
	case .StarfallSpire:
		return d32.FromInt(16)
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
	case .DistrictHall:
		return 12
	case .GiantMortar:
		return 24
	case .Harbor:
		return 12
	case .Granary:
		return 6
	case .AlchemistWorkshop, .FireworksGuild:
		return 12
	case .StarfallSpire:
		return 18
	}
	unreachable()
}

BuildingWoodCost :: proc(kind: BuildingKind) -> d32.Value {
	switch kind {
	case .TownHall, .Wall, .Bridge, .Cannon, .Watchtower, .Path, .DistrictHall, .GiantMortar, .FireworksGuild, .StarfallSpire:
		// Halls, combat works and decorative paths are paid for elsewhere or free.
		return d32.ZERO
	case .Harbor:
		return d32.FromInt(25)
	case .Granary:
		return d32.FromInt(20)
	case .Home:
		return d32.FromInt(5)
	case .Farmland:
		return d32.FromInt(8)
	case .ArcheryRange:
		return d32.FromInt(25)
	case .MagicSchool:
		return d32.FromInt(30)
	case .GiantPen:
		return d32.FromInt(40)
	case .SiegeWorkshop:
		return d32.FromInt(35)
	case .TurtlePen:
		return d32.FromInt(30)
	case .ThievesGuild:
		return d32.FromInt(30)
	case .AlchemistWorkshop:
		return d32.FromInt(65)
	}
	unreachable()
}

BuildingValidTileType :: proc(bType: BuildingType, tType: TileType) -> bool {
	switch v in bType {
	case Bridge:
		return TileIsWater(tType)

	case Farmland:
		return TILE_DEFS[tType].food >= d32.HALF

	case TownHall, Home, Wall, Cannon, Watchtower, ArcheryRange, MagicSchool, GiantPen, SiegeWorkshop, TurtlePen, ThievesGuild, Path, DistrictHall, Granary:
		return TILE_DEFS[tType].buildable

	case BuildingOrder:
		switch _ in v.type {
		case GiantMortar:
			return TILE_DEFS[tType].buildable
		case Harbor:
			return tType == .Sand
		case MagicSchool, SiegeWorkshop, AlchemistWorkshop, FireworksGuild, StarfallSpire:
			return TILE_DEFS[tType].buildable
		}
	}
	unreachable()
}

BuildingWalkable :: proc(type: BuildingType) -> bool {
	switch _ in type {
	case Bridge, Path:
		return true
	case TownHall, Home, Farmland, Wall, Cannon, Watchtower, ArcheryRange, MagicSchool, GiantPen, SiegeWorkshop, TurtlePen, ThievesGuild, DistrictHall, Granary:
		return false
	case BuildingOrder:
		return false
	}
	unreachable()
}

// Combat buildings are placed by the player anywhere in the world and raised by
// combat builders without wood. Everything else is built by the town itself.
BuildingIsCombat :: proc(kind: BuildingKind) -> bool {
	switch kind {
	case .Wall, .Bridge, .Cannon, .Watchtower, .GiantMortar, .FireworksGuild, .StarfallSpire:
		return true
	case .TownHall, .Home, .Farmland, .ArcheryRange, .MagicSchool, .GiantPen, .SiegeWorkshop, .TurtlePen, .ThievesGuild, .Path, .DistrictHall, .Harbor, .Granary, .AlchemistWorkshop:
		return false
	}
	unreachable()
}

BuildingIsTraining :: proc(kind: BuildingKind) -> bool {
	switch kind {
	case .ArcheryRange, .MagicSchool, .GiantPen, .SiegeWorkshop, .TurtlePen, .ThievesGuild:
		return true
	case .TownHall, .Home, .Farmland, .Wall, .Bridge, .Cannon, .Watchtower, .Path, .DistrictHall, .GiantMortar, .Harbor, .Granary, .AlchemistWorkshop, .FireworksGuild, .StarfallSpire:
		return false
	}
	unreachable()
}

Unit :: struct {
	x, y: d32.Value,
	previousX, previousY: d32.Value,
	health: d32.Value,
	burning: d32.Value,
	cooldown: d32.Value,
	poisonRemaining: d32.Value,
	decisionTimer: d32.Value, // Seconds until the next expensive AI decision
	decisionReady: bool, // Set once per update by WorldUnitUpdate
	updateStride: u8, // Simulation slices between updates (idle LOD)
	updateTime: f32, // Simulation time of the last update
	updateInterval: f32, // Seconds the current position span covers
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
	walkPhase: f32, // Advances with rendered movement; drives the walk cycle
	animX, animY: f32, // Last interpolated position used for stride and footsteps
	actionStarted: f32, // Start time of the current attack or work swing
	actionDirX, actionDirY: f32, // Normalised direction of the current action
}

UnitEffects :: enum {
	NoHome,
	NoWater,
	NoFood,
	Poisoned,
	Wet,
	Chilled,
	HeatStressed,
}

ALL_UNIT_EFFECTS := [7]UnitEffects {
	.NoHome,
	.NoWater,
	.NoFood,
	.Poisoned,
	.Wet,
	.Chilled,
	.HeatStressed,
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
	scanTimer: d32.Value,
	scanSequence: int,
	patrolSequence: int,
	escortTarget: int,
	retreating: bool, // Ignore targets until the return home is complete.
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
	timer: d32.Value,
	retryTimer: d32.Value,
	inside: bool,
}

Villager :: struct {}
Builder :: struct {
	carriedResource:    d32.Value,
	taskSequence:       int,
	targetDecoration:   int,
	constructionSite:   int, // active town construction slot, or -1
	failedConstruction: int, // unreachable slot to avoid for one assignment
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
	scanTimer:       d32.Value,
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
	restTimer: d32.Value,
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

UnitIsMelee :: proc(type: UnitType) -> bool {
	switch _ in type {
	case Knight, Giant, Turtle, Rogue, CombatBuilder:
		return true
	case Archer, Mage, Catapult, Villager, Builder, WaterCollector, Farmer, Explorer:
		return false
	}
	unreachable()
}

// Centre-to-centre space a unit needs so its sprite does not merge with
// another unit's sprite. Based on the rendered sprite width.
UNIT_BODY_RADIUS_FACTOR :: d32.Value(45*d32.SCALE/100)
UNIT_BODY_GAP :: d32.Value(6*d32.SCALE/100)

UnitBodyRadius :: proc(type: UnitType) -> d32.Value {
	// Sprite scale stays f32 for rendering; only this gameplay radius is fixed point.
	return d32.Mul(PositionFromF32(UnitSpriteScale(UnitKindOf(type))), UNIT_BODY_RADIUS_FACTOR)
}

UnitMeleeStandoff :: proc(attacker, target: UnitType) -> d32.Value {
	return d32.Add(
		d32.Add(UnitBodyRadius(attacker), UnitBodyRadius(target)),
		UNIT_BODY_GAP,
	)
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

UnitDefaultHealth :: proc(type: UnitType) -> d32.Value {
	switch _ in type {
	case Villager, Builder, WaterCollector, Farmer:
		return d32.FromInt(15)
	case CombatBuilder:
		return d32.FromInt(10)
	case Knight:
		return d32.FromInt(50)
	case Archer:
		return d32.FromInt(30)
	case Mage:
		return d32.FromInt(25)
	case Giant:
		return d32.FromInt(100)
	case Turtle:
		return d32.FromInt(140)
	case Catapult:
		return d32.FromInt(60)
	case Rogue:
		return d32.FromInt(35)
	case Explorer:
		return d32.FromInt(18)
	}
	unreachable()
}

UnitDamageStage :: proc(w: ^World, unitSlot: int) -> int {
	if unitSlot < 0 || unitSlot >= UNIT_CAPACITY || !w.unitUsed[unitSlot] do return 0
	if w.units.type[unitSlot] == nil do return 0
	maximum := UnitMaxHealth(w, unitSlot)
	if maximum <= d32.ZERO do return 0
	// Raw values share one scale, so the percent ratio stays integral.
	percent := i64(d32.Raw(w.units.health[unitSlot]))*100/i64(d32.Raw(maximum))
	if percent <= 33 do return 2
	if percent <= 66 do return 1
	return 0
}

UnitDefaultSpeed :: proc(type: UnitType) -> d32.Value {
	switch _ in type {
	case Villager:
		return d32.FromInt(3)
	case Builder, WaterCollector, Farmer:
		return d32.FromRatio(5, 2)
	case CombatBuilder:
		return d32.FromInt(3)
	case Knight:
		return d32.FromRatio(7, 2)
	case Archer:
		return d32.FromRatio(16, 5)
	case Mage:
		return d32.FromRatio(14, 5)
	case Giant:
		return d32.FromInt(2)
	case Turtle:
		return d32.FromInt(2)
	case Catapult:
		return d32.FromRatio(3, 2)
	case Rogue:
		return d32.FromInt(4)
	case Explorer:
		return d32.FromRatio(9, 5)
	}
	unreachable()
}

UnitDefaultCooldown :: proc(type: UnitType) -> d32.Value {
	switch _ in type {
	case Villager, Builder, WaterCollector, Farmer:
		return d32.ZERO
	case CombatBuilder:
		return d32.FromInt(2)
	case Knight:
		return d32.FromInt(1)
	case Archer:
		return d32.FromRatio(12, 10)
	case Mage:
		return d32.FromInt(2)
	case Giant:
		return d32.FromRatio(7, 4)
	case Turtle:
		return d32.FromInt(2)
	case Catapult:
		return d32.FromInt(3)
	case Rogue:
		return d32.FromRatio(3, 5)
	case Explorer:
		return d32.ZERO
	}
	unreachable()
}

UnitDefaultRange :: proc(type: UnitType) -> d32.Value {
	switch _ in type {
	case Villager, Builder, WaterCollector, Farmer:
		return d32.ZERO
	case CombatBuilder:
		return d32.FromRatio(12, 10)
	case Knight:
		return d32.FromRatio(3, 4)
	case Archer:
		return d32.FromInt(8)
	case Mage:
		return d32.FromInt(7)
	case Giant:
		return d32.FromRatio(4, 5)
	case Turtle:
		return d32.FromRatio(9, 10)
	case Catapult:
		return d32.FromInt(12)
	case Rogue:
		return d32.FromRatio(3, 4)
	case Explorer:
		return d32.ZERO
	}
	unreachable()
}

// Vision lost once the world is fully dark. Enough to matter at night, but
// units still react to anything close by.
UNIT_NIGHT_VISION_FACTOR :: d32.Value(3*d32.SCALE/4)

UnitDefaultVision :: proc(type: UnitType, isNight: bool) -> d32.Value {
	vision: d32.Value = d32.ZERO
	switch _ in type {
	case Villager, Builder, WaterCollector, Farmer:
		vision = d32.FromInt(30)
	case CombatBuilder:
		vision = d32.FromInt(24)
	case Knight:
		vision = d32.FromInt(25)
	case Archer:
		vision = d32.FromInt(30)
	case Mage:
		vision = d32.FromInt(30)
	case Giant:
		vision = d32.FromInt(40)
	case Turtle:
		vision = d32.FromInt(30)
	case Catapult:
		vision = d32.FromInt(35)
	case Rogue:
		vision = d32.FromInt(30)
	case Explorer:
		vision = d32.FromInt(34)
	}
	// Night trims vision without blacking it out: a noticeable loss that still
	// leaves units aware of things close by.
	if isNight do vision = d32.Mul(vision, UNIT_NIGHT_VISION_FACTOR)
	return vision
}

// Enemy-detection radius used by combat AI. A unit may react before it can
// actually reveal the area to the player, which keeps guards proactive.
UnitDistraction :: proc(type: UnitType) -> d32.Value {
	switch _ in type {
	case Villager, Builder, WaterCollector, Farmer:
		return d32.FromInt(34)
	case CombatBuilder:
		return d32.FromInt(30)
	case Knight:
		return d32.FromInt(40)
	case Archer:
		return d32.FromInt(40)
	case Mage:
		return d32.FromInt(38)
	case Giant:
		return d32.FromInt(55)
	case Turtle:
		return d32.FromInt(45)
	case Catapult:
		return d32.FromInt(50)
	case Rogue:
		return d32.FromInt(45)
	case Explorer:
		return d32.FromInt(36)
	}
	unreachable()
}

UnitDefaultDamage :: proc(type: UnitType) -> d32.Value {
	switch _ in type {
	case Villager, Builder, WaterCollector, Farmer:
		return d32.ZERO
	case CombatBuilder:
		return d32.FromInt(3)
	case Knight:
		return d32.FromInt(15)
	case Archer:
		return d32.FromInt(10)
	case Mage:
		return d32.FromInt(12)
	case Giant:
		return d32.FromInt(30)
	case Turtle:
		return d32.FromInt(20)
	case Catapult:
		return d32.FromInt(25)
	case Rogue:
		return d32.FromInt(20)
	case Explorer:
		return d32.ZERO
	}
	unreachable()
}

UnitDefaultAreaRadius :: proc(type: UnitType) -> d32.Value {
	switch _ in type {
	case Mage:
		return d32.Value(3*d32.SCALE)
	case Giant:
		return d32.Value(2*d32.SCALE)
	case Catapult:
		return d32.Value(35*d32.SCALE/10)
	case Villager, Builder, WaterCollector, Farmer, Knight, Archer, Turtle, Rogue, Explorer:
		return d32.ZERO
	case CombatBuilder:
		return d32.ZERO
	}
	unreachable()
}

UnitDefaultTrainingTime :: proc(kind: UnitKind) -> d32.Value {
	switch kind {
	case .Villager:
		return d32.FromInt(1)
	case .Builder, .WaterCollector, .Farmer:
		return d32.FromRatio(3, 2)
	case .CombatBuilder:
		return d32.FromRatio(5, 2)
	case .Knight:
		return d32.FromInt(2)
	case .Archer:
		return d32.FromInt(3)
	case .Mage:
		return d32.FromInt(5)
	case .Giant:
		return d32.FromInt(6)
	case .Turtle:
		return d32.FromInt(6)
	case .Catapult:
		return d32.FromInt(7)
	case .Rogue:
		return d32.FromInt(4)
	case .Explorer:
		return d32.FromInt(2)
	}
	unreachable()
}

UnitValidTileType :: proc(uType: UnitType, tType: TileType) -> bool {
	switch _ in uType {
	case Turtle:
		return TILE_DEFS[tType].passable || TileIsWater(tType)
	case Villager, Builder, WaterCollector, Farmer, Knight, Archer, Mage, Giant, Catapult, Rogue, Explorer, CombatBuilder:
		return TILE_DEFS[tType].passable
	}
	return false
}

// Shared initialization for spawning and for in-place conversions.
UnitTypeInit :: proc(w: ^World, unitSlot: int, type: UnitType) {
	if unitSlot < 0 || unitSlot >= UNIT_CAPACITY || !w.unitUsed[unitSlot] do return
	UnitSleepWake(w, unitSlot)
	unit := &w.units[unitSlot]
	if state, converting := unit.state.(StateConverting); converting && state.inside {
		SpatialUnitMove(w, unitSlot)
	}
	if unit.burning > d32.ZERO {
		unit.burning = d32.ZERO
		intrinsics.atomic_sub(&w.unitsBurning, 1)
	}
	unit.type = type
	unit.health = UnitMaxHealthFor(w, unit.kingdome, type)
	unit.cooldown = UnitDefaultCooldown(type)
	unit.poisonRemaining = d32.ZERO
	switch _ in type {
	case Villager:
		unit.type = Villager{}
		unit.state = StatePacific.Roaming
	case Builder:
		unit.type = Builder{
			carriedResource = d32.ZERO,
			taskSequence = 0,
			targetDecoration = -1,
			constructionSite = -1,
			failedConstruction = -1,
		}
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
		unit.state = StateWarriorInit(unitSlot, unit.kingdome, unit.town)
	case Archer:
		unit.type = Archer{}
		unit.state = StateWarriorInit(unitSlot, unit.kingdome, unit.town)
	case Mage:
		unit.type = Mage{}
		unit.state = StateWarriorInit(unitSlot, unit.kingdome, unit.town)
	case Giant:
		unit.type = Giant{}
		unit.state = StateWarriorInit(unitSlot, unit.kingdome, unit.town)
	case Turtle:
		unit.type = Turtle{}
		unit.state = StateWarriorInit(unitSlot, unit.kingdome, unit.town)
	case Catapult:
		unit.type = Catapult{}
		unit.state = StateWarriorInit(unitSlot, unit.kingdome, unit.town)
	case Rogue:
		unit.type = Rogue{}
		unit.state = StateWarriorInit(unitSlot, unit.kingdome, unit.town)
	case Explorer:
		unit.type = Explorer{tripsLeft = 3}
		unit.state = StatePacific.Roaming
	}
	unit.pathReady = false
	unit.pathFound = false
	unit.jumpStarted = -WALL_JUMP_SECONDS
	unit.actionStarted = -1e9
	unit.actionDirX = 0
	unit.actionDirY = 0
}

UnitSetType :: proc(w: ^World, unitSlot: int, kind: UnitKind) {
	if unitSlot < 0 || unitSlot >= UNIT_CAPACITY || !w.unitUsed[unitSlot] do return
	unit := &w.units[unitSlot]
	if WorldTownExists(w, unit.kingdome, unit.town) &&
		(UnitIsWarrior(unit.type) || UnitKindOf(unit.type) == .CombatBuilder ||
		kind == .CombatBuilder || UnitIsWarrior(UnitTypeFromKind(kind))) {
		w.kingdoms[unit.kingdome].towns[unit.town].orderRevision += 1
	}
	UnitTypeInit(w, unitSlot, UnitTypeFromKind(kind))
}

UnitMove :: proc(w: ^World, unitSlot, goalX, goalY: int, deltaTime: f32, maxExpansions := 0) -> bool {
	start := ProfileSectionBegin(.UnitMove)
	defer ProfileSectionEnd(.UnitMove, start)
	unitIndex, exists := UnitGet(w, unitSlot)
	if !exists || deltaTime < 0 do return false

	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 do return false
	width := i64(worldWidth)*d32.SCALE
	height := i64(worldHeight)*d32.SCALE

	unit := &w.units[unitIndex]
	positionX, validX := d32.WrapRaw(i64(d32.Raw(unit.x)), d32.ZERO, width)
	positionY, validY := d32.WrapRaw(i64(d32.Raw(unit.y)), d32.ZERO, height)
	if !validX || !validY do return false
	targetX := WorldWrapCoordinate(goalX, worldWidth)
	targetY := WorldWrapCoordinate(goalY, worldHeight)

	needsPath := !unit.pathReady || unit.pathTargetX != targetX ||
		unit.pathTargetY != targetY
	// Global navigation revisions are deliberately not part of the cache key:
	// a hazard or building anywhere in the world used to force every unit to
	// run A* again. Validate the next waypoint instead and replan only when
	// this unit is actually affected.
	if !needsPath && unit.pathIndex < len(unit.path) {
		waypoint := unit.path[unit.pathIndex]
		if !WorldTileWalkable(
			w,
			waypoint/worldHeight,
			waypoint%worldHeight,
			unit.type,
			unit.kingdome,
		) {
			needsPath = true
		}
	}
	if needsPath {
		startX := int(d32.ToInt(positionX))
		startY := int(d32.ToInt(positionY))
		// Nearby errands skip the search entirely; A* is only for real detours.
		unit.pathFound = UnitDirectPath(
			w,
			unit.type,
			unit.kingdome,
			startX,
			startY,
			targetX,
			targetY,
			&unit.path,
		)
		if !unit.pathFound {
			unit.pathFound = AStar(
				w,
				unit.type,
				unit.kingdome,
				startX,
				startY,
				targetX,
				targetY,
				&unit.path,
				maxExpansions,
			)
		}
		unit.pathTargetX = targetX
		unit.pathTargetY = targetY
		unit.pathRevision = w.pathRevision
		unit.pathReady = true
		unit.pathIndex = 1
		if len(unit.path) == 1 do unit.pathIndex = 0
	}
	if !unit.pathFound do return false

	speed := UnitMoveSpeed(w, unitSlot, UnitDefaultSpeed(unit.type))

	remainingRaw := i64(d32.Raw(d32.Mul(speed, PositionFromF32(deltaTime))))
	if remainingRaw < 0 do remainingRaw = 0
	for unit.pathIndex < len(unit.path) {
		waypoint := unit.path[unit.pathIndex]
		destinationX := TileCenterPosition(waypoint/worldHeight)
		destinationY := TileCenterPosition(waypoint%worldHeight)
		deltaX, validDeltaX := d32.ShortestWrappedDelta(positionX, destinationX, width)
		deltaY, validDeltaY := d32.ShortestWrappedDelta(positionY, destinationY, height)
		if !validDeltaX || !validDeltaY do break
		reachedWaypoint := true

		if deltaX != 0 {
			distanceX := abs(deltaX)
			if remainingRaw >= distanceX {
				positionX, _ = d32.AddRawWrapped(i64(d32.Raw(positionX)), deltaX, d32.ZERO, width)
				remainingRaw -= distanceX
			} else if remainingRaw > 0 {
				step := remainingRaw
				if deltaX < 0 do step = -step
				positionX, _ = d32.AddRawWrapped(i64(d32.Raw(positionX)), step, d32.ZERO, width)
				remainingRaw = 0
				reachedWaypoint = false
			} else {
				reachedWaypoint = false
			}
		}

		if deltaY != 0 {
			distanceY := abs(deltaY)
			if remainingRaw >= distanceY {
				positionY, _ = d32.AddRawWrapped(i64(d32.Raw(positionY)), deltaY, d32.ZERO, height)
				remainingRaw -= distanceY
			} else if remainingRaw > 0 {
				step := remainingRaw
				if deltaY < 0 do step = -step
				positionY, _ = d32.AddRawWrapped(i64(d32.Raw(positionY)), step, d32.ZERO, height)
				remainingRaw = 0
				reachedWaypoint = false
			} else {
				reachedWaypoint = false
			}
		}

		if WorldTileFriendlyWall(
			w,
			int(d32.ToInt(positionX)),
			int(d32.ToInt(positionY)),
			unit.kingdome,
		) {
			unit.jumpStarted = w.simulationTime
		}
		if !reachedWaypoint do break
		unit.pathIndex += 1
	}

	SetUnitPosition(w, unitIndex, positionX, positionY)
	SpatialUnitMove(w, unitSlot)
	return unit.pathIndex >= len(unit.path)
}
