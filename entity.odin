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
		orderCooldown: f32,
		orderActive: f32,
		orderTargetX, orderTargetY: f32,
		orderTick: f32,
		orderKind: OrderKind,
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

BuildingDefaultHealth :: proc(type: BuildingType) -> f32 {
	switch v in type {
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
	case DistrictHall:
		return 600
	case Granary:
		return 250
	case BuildingOrder:
		switch _ in v.type {
		case GiantMortar:
			return 350
		case Harbor:
			return 300
		case MagicSchool:
			return 300
		case SiegeWorkshop:
			return 350
		case AlchemistWorkshop:
			return 300
		case FireworksGuild:
			return 350
		case StarfallSpire:
			return 500
		}
	}
	unreachable()
}

BuildingDamageStage :: proc(w: ^World, buildingSlot: int) -> int {
	if buildingSlot < 0 || buildingSlot >= BUILDING_CAPACITY || !w.buildingUsed[buildingSlot] {
		return 0
	}
	maximum := BuildingMaxHealth(w, buildingSlot)
	if maximum <= 0 do return 0
	ratio := clamp(w.buildings.health[buildingSlot]/maximum, 0, 1)
	if ratio <= 0.33 do return 2
	if ratio <= 0.66 do return 1
	return 0
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
	case .DistrictHall:
		return 10
	case .GiantMortar:
		return 10
	case .Harbor:
		return 8
	case .Granary:
		return 4
	case .AlchemistWorkshop, .FireworksGuild:
		return 8
	case .StarfallSpire:
		return 16
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

BuildingWoodCost :: proc(kind: BuildingKind) -> f32 {
	switch kind {
	case .TownHall, .Wall, .Bridge, .Cannon, .Watchtower, .Path, .DistrictHall, .GiantMortar, .FireworksGuild, .StarfallSpire:
		// Halls, combat works and decorative paths are paid for elsewhere or free.
		return 0
	case .Harbor:
		return 25
	case .Granary:
		return 20
	case .Home:
		return 5
	case .Farmland:
		return 8
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
	case .AlchemistWorkshop:
		return 65
	}
	unreachable()
}

BuildingValidTileType :: proc(bType: BuildingType, tType: TileType) -> bool {
	switch v in bType {
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

	case TownHall, Home, Wall, Cannon, Watchtower, ArcheryRange, MagicSchool, GiantPen, SiegeWorkshop, TurtlePen, ThievesGuild, Path, DistrictHall, Granary:
		switch tType {
		case .Ground, .FertileGround, .Forest, .Hill, .Desert, .Sand:
			return true
		case .Water, .FreshWater, .River:
			return false
		}

	case BuildingOrder:
		switch _ in v.type {
		case GiantMortar:
			switch tType {
			case .Ground, .FertileGround, .Forest, .Hill, .Desert, .Sand:
				return true
			case .Water, .FreshWater, .River:
				return false
			}
		case Harbor:
			return tType == .Sand
		case MagicSchool, SiegeWorkshop, AlchemistWorkshop, FireworksGuild, StarfallSpire:
			switch tType {
			case .Ground, .FertileGround, .Forest, .Hill, .Desert, .Sand:
				return true
			case .Water, .FreshWater, .River:
				return false
			}
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
	x, y: f32,
	previousX, previousY: f32,
	health: f32,
	burning: f32,
	cooldown: f32,
	poisonRemaining: f32,
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
}

ALL_UNIT_EFFECTS := [4]UnitEffects {
	.NoHome,
	.NoWater,
	.NoFood,
	.Poisoned,
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
	timer: f32,
	retryTimer: f32,
	inside: bool,
}

Villager :: struct {}
Builder :: struct {
	carriedResource:    f32,
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
UNIT_BODY_RADIUS_FACTOR :: 0.45
UNIT_BODY_GAP :: 0.06

UnitBodyRadius :: proc(type: UnitType) -> f32 {
	return UnitSpriteScale(UnitKindOf(type))*UNIT_BODY_RADIUS_FACTOR
}

UnitMeleeStandoff :: proc(attacker, target: UnitType) -> f32 {
	return UnitBodyRadius(attacker)+UnitBodyRadius(target)+UNIT_BODY_GAP
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

UnitDamageStage :: proc(w: ^World, unitSlot: int) -> int {
	if unitSlot < 0 || unitSlot >= UNIT_CAPACITY || !w.unitUsed[unitSlot] do return 0
	if w.units.type[unitSlot] == nil do return 0
	maximum := UnitMaxHealth(w, unitSlot)
	if maximum <= 0 do return 0
	ratio := clamp(w.units.health[unitSlot]/maximum, 0, 1)
	if ratio <= 0.33 do return 2
	if ratio <= 0.66 do return 1
	return 0
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

// Vision lost once the world is fully dark. Enough to matter at night, but
// units still react to anything close by.
UNIT_NIGHT_VISION_FACTOR :: 0.75

UnitDefaultVision :: proc(type: UnitType, isNight: bool) -> f32 {
	vision: f32 = 0
	switch _ in type {
	case Villager, Builder, WaterCollector, Farmer:
		vision = 30
	case CombatBuilder:
		vision = 24
	case Knight:
		vision = 25
	case Archer:
		vision = 30
	case Mage:
		vision = 30
	case Giant:
		vision = 40
	case Turtle:
		vision = 30
	case Catapult:
		vision = 35
	case Rogue:
		vision = 30
	case Explorer:
		vision = 34
	}
	// Night trims vision without blacking it out: a noticeable loss that still
	// leaves units aware of things close by.
	if isNight do vision *= UNIT_NIGHT_VISION_FACTOR
	return vision
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
UnitTypeInit :: proc(w: ^World, unitSlot: int, type: UnitType) {
	if unitSlot < 0 || unitSlot >= UNIT_CAPACITY || !w.unitUsed[unitSlot] do return
	UnitSleepWake(w, unitSlot)
	unit := &w.units[unitSlot]
	if state, converting := unit.state.(StateConverting); converting && state.inside {
		SpatialUnitMove(w, unitSlot)
	}
	if unit.burning > 0 {
		unit.burning = 0
		w.unitsBurning -= 1
	}
	unit.type = type
	unit.health = UnitMaxHealthFor(w, unit.kingdome, type)
	unit.cooldown = UnitDefaultCooldown(type)
	unit.poisonRemaining = 0
	switch _ in type {
	case Villager:
		unit.type = Villager{}
		unit.state = StatePacific.Roaming
	case Builder:
		unit.type = Builder{
			carriedResource = 0,
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

UnitMove :: proc(w: ^World, unitSlot, goalX, goalY: int, deltaTime: f32) -> bool {
	unitIndex, exists := UnitGet(w, unitSlot)
	if !exists || deltaTime < 0 do return false

	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 do return false

	unit := &w.units[unitIndex]
	unitX := WorldWrapPosition(unit.x, f32(worldWidth))
	unitY := WorldWrapPosition(unit.y, f32(worldHeight))
	targetX := WorldWrapCoordinate(goalX, worldWidth)
	targetY := WorldWrapCoordinate(goalY, worldHeight)

	needsPath := !unit.pathReady || unit.pathTargetX != targetX ||
		unit.pathTargetY != targetY || unit.pathRevision != w.navigationRevision
	if needsPath {
		startX := WorldWrapCoordinate(int(unitX), worldWidth)
		startY := WorldWrapCoordinate(int(unitY), worldHeight)
		unit.pathFound = AStar(w, unit.type, unit.kingdome, startX, startY, targetX, targetY, &unit.path)
		unit.pathTargetX = targetX
		unit.pathTargetY = targetY
		unit.pathRevision = w.navigationRevision
		unit.pathReady = true
		unit.pathIndex = 1
		if len(unit.path) == 1 do unit.pathIndex = 0
	}
	if !unit.pathFound do return false

	speed := UnitMoveSpeed(w, unitSlot, UnitDefaultSpeed(unit.type))

	remaining := speed * deltaTime
	if remaining < 0 do remaining = 0
	for unit.pathIndex < len(unit.path) {
		waypoint := unit.path[unit.pathIndex]
		destinationX := f32(waypoint/worldHeight) + 0.5
		destinationY := f32(waypoint%worldHeight) + 0.5
		deltaX := WorldShortestWrappedDelta(destinationX-unitX, f32(worldWidth))
		deltaY := WorldShortestWrappedDelta(destinationY-unitY, f32(worldHeight))
		reachedWaypoint := true

		if deltaX != 0 {
			distanceX := deltaX
			if distanceX < 0 do distanceX = -distanceX
			if remaining >= distanceX {
				unitX = WorldWrapPosition(unitX+deltaX, f32(worldWidth))
				remaining -= distanceX
			} else if remaining > 0 {
				step := remaining
				if deltaX < 0 do step = -step
				unitX = WorldWrapPosition(unitX+step, f32(worldWidth))
				remaining = 0
				reachedWaypoint = false
			} else {
				reachedWaypoint = false
			}
		}

		if deltaY != 0 {
			distanceY := deltaY
			if distanceY < 0 do distanceY = -distanceY
			if remaining >= distanceY {
				unitY = WorldWrapPosition(unitY+deltaY, f32(worldHeight))
				remaining -= distanceY
			} else if remaining > 0 {
				step := remaining
				if deltaY < 0 do step = -step
				unitY = WorldWrapPosition(unitY+step, f32(worldHeight))
				remaining = 0
				reachedWaypoint = false
			} else {
				reachedWaypoint = false
			}
		}

		if WorldTileFriendlyWall(w, int(unitX), int(unitY), unit.kingdome) {
			unit.jumpStarted = w.simulationTime
		}
		if !reachedWaypoint do break
		unit.pathIndex += 1
	}

	unit.x = unitX
	unit.y = unitY
	SpatialUnitMove(w, unitSlot)
	return unit.pathIndex >= len(unit.path)
}
