package main

import "core:math"

TOWN_CAPACITY :: 100
TOWN_WARRIOR_ORDERS_CAPACITY :: 16
TOWN_START_AREA_RADIUS :: 12
TOWN_AREA_EXPANSION :: 6
MAX_CONVERSION_JOBS :: 16
TOWN_WOOD_TARGET :: 60

// A town's area is a union of circles: its primary hall plus one circle for
// every absorbed town. All circles expand together with town milestones.
MAX_TOWN_DISTRICTS :: 16
TOWN_DISTRICT_GROWTH_BONUS :: 0.10

// Fusion is a late-game consolidation sink. Both towns must be in this era.
TOWN_FUSION_ERA :: 5
TOWN_FUSION_WOOD_BASE :: 200
TOWN_FUSION_WOOD_PER_DISTRICT :: 100
TOWN_FUSION_WOOD_BUFFER :: 50
TOWN_FUSION_FRONTIER_SLACK :: 1

// Founding a new town is funded by the selected town. The order uses the
// town's construction queue, so regular builders travel to the site and raise
// the hall. A player order preempts automatic construction.
// Every town the kingdom already owns makes the next charter more expensive,
// and the settlers are drawn from the source town instead of being created.
TOWN_FOUNDING_WOOD :: 45
TOWN_FOUNDING_WOOD_PER_TOWN :: 20
TOWN_FOUNDING_MIN_CITIZENS :: 8
TOWN_FOUNDING_MIN_DISTANCE :: 20
TOWN_FOUNDING_SETTLERS :: 5
// Extra wood kept in reserve after a charter so the next house or road does not
// leave the town unable to expand again.
TOWN_FOUNDING_WOOD_BUFFER :: 12

// Independent towns are neutral start locations: one town hall, one to three
// knights, no growth and no construction. They all share the neutral faction
// slot, but each is a separate town.
INDEPENDENT_TOWNS_PER_KINGDOM :: 2
INDEPENDENT_TOWN_MIN_DISTANCE :: 32
INDEPENDENT_TOWN_MAX_DISTANCE :: 72
INDEPENDENT_TOWN_SEPARATION :: 20
INDEPENDENT_HOMES_MIN :: 1
INDEPENDENT_HOMES_MAX :: 3
INDEPENDENT_FARMLANDS_MIN :: 0
INDEPENDENT_FARMLANDS_MAX :: 2
INDEPENDENT_KNIGHT_MIN :: 1
INDEPENDENT_KNIGHT_MAX :: 3
INDEPENDENT_REWARD_VILLAGERS_MIN :: 1
INDEPENDENT_REWARD_VILLAGERS_MAX :: 3

// Growth eras. Each era gives a larger cohort with a longer interval, so the
// number of arrival events falls while total throughput keeps rising.
GrowthEra :: struct {
	threshold: int,
	batch:     int,
	interval:  f32,
}

TOWN_ERAS := [6]GrowthEra{
	{threshold = 0, batch = 1, interval = 24},
	{threshold = 18, batch = 5, interval = 60},
	{threshold = 45, batch = 20, interval = 120},
	{threshold = 100, batch = 60, interval = 210},
	{threshold = 200, batch = 150, interval = 300},
	{threshold = 380, batch = 300, interval = 360},
}

// Milestone rewards are chosen per town, one tier at a time. There are five
// reward tiers, one for every era transition.
TOWN_MILESTONE_TIER_COUNT :: 5

// Share of a town's warriors that stays home as a garrison while the town has
// orders. This is not a defend order against the town itself; the rest is split
// between its attack and defend orders.
TOWN_GARRISON_RATIO :: 0.10

Kingdom :: struct {
	name: Name,
	culture: TownCulture,
	capitalSlot: int,
	towns: #soa [TOWN_CAPACITY]Town,
	townUsed: [TOWN_CAPACITY]bool,
	kingdomWar: [KINGDOM_SLOTS]bool,
	techs: bit_set[CrownTech],
	insight: int,
	coastalTownCount: int,
}

TownOrder :: union {
	TownAttackOrder,
	TownDefendOrder,
}

TownAttackOrder :: struct {
	kingdom, town: int,
}

TownDefendOrder :: struct {
	kingdom, town: int,
}

// Each population milestone offers two mutually exclusive paths. Options can
// unlock unit kinds directly and buildings, including combat buildings.
// Training buildings still gate their unit kind until they are raised.
TownPath :: enum {
	Rangers,
	Mystics,
	Beasts,
	Siege,
	Tide,
	Shadows,
	Bastion,
	Logistics,
	Conquest,
	Dominion,
}

MilestoneOption :: struct {
	path:    TownPath,
	units:   bit_set[UnitKind],
	unlocks: bit_set[BuildingKind],
}

TOWN_BASE_UNLOCKED_BUILDINGS :: bit_set[BuildingKind]{.Home, .Farmland, .Path}
TOWN_BASE_UNLOCKED_UNITS :: bit_set[UnitKind]{.Villager, .Builder, .WaterCollector, .Farmer, .Explorer, .Knight}

TOWN_ERA_REWARDS := [TOWN_MILESTONE_TIER_COUNT][2]MilestoneOption{
	{
		{
			path = .Rangers,
			units = {.Archer, .CombatBuilder},
			unlocks = {.ArcheryRange, .Bridge, .Wall},
		},
		{
			path = .Mystics,
			units = {.Mage, .CombatBuilder},
			unlocks = {.MagicSchool, .Cannon, .Wall},
		},
	},
	{
		{
			path = .Beasts,
			units = {.Giant},
			unlocks = {.GiantPen, .Watchtower},
		},
		{
			path = .Siege,
			units = {.Catapult},
			unlocks = {.SiegeWorkshop, .Cannon, .GiantMortar},
		},
	},
	{
		{
			path = .Tide,
			units = {.Turtle},
			unlocks = {.TurtlePen, .Bridge},
		},
		{
			path = .Shadows,
			units = {.Rogue},
			unlocks = {.ThievesGuild, .Watchtower},
		},
	},
	{
		{
			path = .Bastion,
			units = {.CombatBuilder},
			unlocks = {.Wall, .Cannon, .Watchtower},
		},
		{
			path = .Logistics,
			units = {.Explorer},
			unlocks = {.Bridge, .Path},
		},
	},
	{
		{
			path = .Conquest,
			units = {.Knight, .Catapult},
			unlocks = {.SiegeWorkshop},
		},
		{
			path = .Dominion,
			units = {.Mage, .Giant},
			unlocks = {.MagicSchool, .Watchtower},
		},
	},
}

ConversionJob :: struct {
	from, to: UnitKind,
	remaining: int,
	assigned: int,
}

// A building ordered by the town. Builders must clear the decorations on the
// footprint before they can raise the structure.
ConstructionSite :: struct {
	active:    bool, // false marks a free slot; keeps builder site indices stable
	kind:      BuildingKind,
	x, y:      int,
	paid:      f32,
	settlers:  int,
	clearWork: f32,
	buildWork: f32,
}

TOWN_CONSTRUCTION_CAPACITY :: 10

TownDistrict :: struct {
	x, y:   int,
	radius: int,
	name:   Name,
}

Town :: struct {
	name: Name,
	x, y: int,
	hallSlot: int,
	citizens: int,
	wood: f32,
	growthCooldown, growthInterval, growthRate, growthSpeed: f32,
	growthBatch, growthBatchBonus, growthPending: int,
	constructionProgress: f32,
	constructions: [TOWN_CONSTRUCTION_CAPACITY]ConstructionSite,
	builders, waterCollectors, farmers, villagers: int,
	homes, farmlands: int,
	farmlandOutput: f32,
	foodPotential, waterPotential: f32,
	waterAccess: f32,
	waterAccessTerrainRevision: u64,
	waterAccessCached: bool,
	foodShortage, waterShortage: f32,
	coastal: bool,
	coastalCached: bool,
	coastalTerrainRevision: u64,
	coastalAreaRadius, coastalDistricts: int,
	blockadeUntil: f32,
	blockadeBy: int,
	areaRadius: int,
	districts: [MAX_TOWN_DISTRICTS]TownDistrict,
	districtCount: int,
	fusionCount: int,
	alarmActive: bool,
	unlockedBuildings: bit_set[BuildingKind],
	unlockedUnits: bit_set[UnitKind],
	buildingCounts: [BuildingKind]int,
	buildingSlots: [BuildingKind]int,
	milestonesEarned: int,
	milestonesChosen: int,
	milestonePending: bool,
	milestoneOptions: [TOWN_MILESTONE_TIER_COUNT]u8, // chosen option per earned milestone
	conversions: [MAX_CONVERSION_JOBS]ConversionJob,
	conversionCount: int,
	attackOrders: [KINGDOM_SLOTS][TOWN_CAPACITY]bool,
	defendOrders: [KINGDOM_SLOTS][TOWN_CAPACITY]bool,
	attackedBy: [KINGDOM_SLOTS][TOWN_CAPACITY]bool,
	defendedBy: [KINGDOM_SLOTS][TOWN_CAPACITY]bool,
	orders: [TOWN_WARRIOR_ORDERS_CAPACITY]TownOrder,
	orderCount: int,
	orderRevision: u64,
}

TownStart :: proc(w: ^World, x, y: int, kingdomSlot: int) -> (int, bool) {
	i := -1
	for slot in 0..<TOWN_CAPACITY {
		if !w.kingdoms[kingdomSlot].townUsed[slot] {
			i = slot
			break
		}
	}
	if i < 0 do return 0, false

	bId, ok := BuildingSpawn(w, x, y, TownHall{}, kingdomSlot, i)
	if !ok do return 0, false

	TownInitialize(w, kingdomSlot, i, bId, x, y, 35)
	w.kingdoms[kingdomSlot].townUsed[i] = true
	return i, true
}

// Places a small outbuilding on the first valid ring position around the hall.
// The hashed starting direction keeps each town's cluster varied.
IndependentTownPlaceBuilding :: proc(
	w: ^World,
	townSlot, townX, townY: int,
	bType: BuildingType,
	sequence: int,
) -> bool {
	hallWidth, hallHeight := BuildingTileSize(TownHall{})
	centerX := townX+hallWidth/2
	centerY := townY+hallHeight/2
	offsets := [8][2]int{{1, 0}, {1, 1}, {0, 1}, {-1, 1}, {-1, 0}, {-1, -1}, {0, -1}, {1, -1}}
	for radius in 2..=8 {
		start := int(WorldNoiseHash(townX+sequence*37, townY+radius, w.seed+0x51D)*8)
		for step in 0..<8 {
			direction := (start+step)%8
			x := WorldWrapCoordinate(centerX+offsets[direction][0]*radius, int(w.maxX))
			y := WorldWrapCoordinate(centerY+offsets[direction][1]*radius, int(w.maxY))
			if !WorldBuildingValid(w, x, y, bType) do continue
			if _, ok := BuildingSpawn(w, x, y, bType, NEUTRAL_KINGDOM, townSlot); ok {
				return true
			}
		}
	}
	return false
}

// Spawns a neutral town hall, a few homes and fields, plus its knight guard.
// Used only during world generation.
IndependentTownSpawn :: proc(w: ^World, x, y: int) -> (int, bool) {
	if !WorldBuildingValid(w, x, y, TownHall{}) do return 0, false
	townSlot := KingdomFreeTownSlot(w, NEUTRAL_KINGDOM)
	if townSlot < 0 do return 0, false

	hallSlot, ok := BuildingSpawn(w, x, y, TownHall{}, NEUTRAL_KINGDOM, townSlot)
	if !ok do return 0, false

	TownInitialize(w, NEUTRAL_KINGDOM, townSlot, hallSlot, x, y, 0)
	w.kingdoms[NEUTRAL_KINGDOM].townUsed[townSlot] = true

	homeRoll := WorldNoiseHash(x, y, w.seed+0x1D5)
	homes := INDEPENDENT_HOMES_MIN+
		int(homeRoll*f32(INDEPENDENT_HOMES_MAX-INDEPENDENT_HOMES_MIN+1))
	homes = clamp(homes, INDEPENDENT_HOMES_MIN, INDEPENDENT_HOMES_MAX)
	for index in 0..<homes {
		IndependentTownPlaceBuilding(w, townSlot, x, y, Home{}, index)
	}

	farmRoll := WorldNoiseHash(x, y, w.seed+0x1D7)
	farmlands := INDEPENDENT_FARMLANDS_MIN+
		int(farmRoll*f32(INDEPENDENT_FARMLANDS_MAX-INDEPENDENT_FARMLANDS_MIN+1))
	farmlands = clamp(farmlands, INDEPENDENT_FARMLANDS_MIN, INDEPENDENT_FARMLANDS_MAX)
	for index in 0..<farmlands {
		IndependentTownPlaceBuilding(w, townSlot, x, y, Farmland{}, 16+index)
	}

	roll := WorldNoiseHash(x, y, w.seed+0x1D3)
	guardCount := INDEPENDENT_KNIGHT_MIN+
		int(roll*f32(INDEPENDENT_KNIGHT_MAX-INDEPENDENT_KNIGHT_MIN+1))
	guardCount = clamp(guardCount, INDEPENDENT_KNIGHT_MIN, INDEPENDENT_KNIGHT_MAX)
	for _ in 0..<guardCount {
		if TownSpawnCitizen(w, NEUTRAL_KINGDOM, townSlot, Knight{}) < 0 do break
	}
	return townSlot, true
}

// The independent town is gone: its guards die with it and the destroyer
// receives one to three villagers in its nearest town.
IndependentTownDefeat :: proc(w: ^World, townSlot, destroyer: int) {
	if townSlot < 0 || townSlot >= TOWN_CAPACITY ||
		!w.kingdomUsed[NEUTRAL_KINGDOM] || !w.kingdoms[NEUTRAL_KINGDOM].townUsed[townSlot] {
		return
	}
	town := &w.kingdoms[NEUTRAL_KINGDOM].towns[townSlot]
	townX, townY := town.x, town.y

	for unitSlot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[unitSlot] do continue
		if w.units[unitSlot].kingdome != NEUTRAL_KINGDOM ||
			w.units[unitSlot].town != townSlot {
			continue
		}
		UnitDespawn(w, unitSlot)
	}

	for buildingSlot in 0..<BUILDING_CAPACITY {
		if !w.buildingUsed[buildingSlot] do continue
		if w.buildings[buildingSlot].kingdom != NEUTRAL_KINGDOM ||
			w.buildings[buildingSlot].town != townSlot {
			continue
		}
		if BuildingKindOf(w.buildings[buildingSlot].type) == .TownHall do continue
		BuildingSpawnDebris(w, buildingSlot, BuildingOnFire(w, buildingSlot))
		BuildingDespawn(w, buildingSlot, destroyer)
	}

	if destroyer >= 0 && destroyer < KINGDOMS_CAPACITY && w.kingdomUsed[destroyer] {
		rewardTown := IndependentTownRewardTown(w, destroyer, townX, townY)
		if rewardTown >= 0 {
			roll := WorldNoiseHash(townX, townY, w.seed+u64(destroyer)*7919+0x5EED)
			reward := INDEPENDENT_REWARD_VILLAGERS_MIN+
				int(roll*f32(INDEPENDENT_REWARD_VILLAGERS_MAX-INDEPENDENT_REWARD_VILLAGERS_MIN+1))
			reward = clamp(
				reward,
				INDEPENDENT_REWARD_VILLAGERS_MIN,
				INDEPENDENT_REWARD_VILLAGERS_MAX,
			)
			for _ in 0..<reward {
				if TownSpawnCitizen(w, destroyer, rewardTown, Villager{}) < 0 do break
			}
		}
	}

	TownOrdersClear(w, NEUTRAL_KINGDOM, townSlot)
	w.kingdoms[NEUTRAL_KINGDOM].townUsed[townSlot] = false

	if KingdomTownCount(w, NEUTRAL_KINGDOM) == 0 {
		for kingdom in 0..<KINGDOMS_CAPACITY {
			w.kingdoms[kingdom].kingdomWar[NEUTRAL_KINGDOM] = false
		}
		w.kingdoms[NEUTRAL_KINGDOM].kingdomWar = {}
		w.kingdomUsed[NEUTRAL_KINGDOM] = false
	}
}

IndependentTownRewardTown :: proc(w: ^World, kingdomSlot, x, y: int) -> int {
	best := -1
	bestDistance: f32 = 0
	for townSlot in 0..<TOWN_CAPACITY {
		if !w.kingdoms[kingdomSlot].townUsed[townSlot] do continue
		town := &w.kingdoms[kingdomSlot].towns[townSlot]
		deltaX := WorldShortestWrappedDelta(f32(town.x)-f32(x), f32(w.maxX))
		deltaY := WorldShortestWrappedDelta(f32(town.y)-f32(y), f32(w.maxY))
		distance := deltaX*deltaX+deltaY*deltaY
		if best < 0 || distance < bestDistance {
			best = townSlot
			bestDistance = distance
		}
	}
	return best
}

// Shared town setup for the initial kingdom spawn and for founded towns.
TownInitialize :: proc(w: ^World, kingdomSlot, townSlot, hallSlot, x, y: int, startingWood: f32) {
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	town^ = Town{
		x = x,
		y = y,
		hallSlot = hallSlot,
		wood = startingWood,
		areaRadius = TOWN_START_AREA_RADIUS,
		unlockedBuildings = TOWN_BASE_UNLOCKED_BUILDINGS,
		unlockedUnits = TOWN_BASE_UNLOCKED_UNITS,
	}
	for &slot in town.buildingSlots do slot = -1
	TownApplyTechUnlocks(w, kingdomSlot, townSlot)
	if KingdomHasTech(w, kingdomSlot, .Metropolis) do town.areaRadius += 1
	town.buildingSlots[.TownHall] = hallSlot
	town.buildingCounts[.TownHall] = 1
	town.growthCooldown = TOWN_ERAS[0].interval
	town.growthInterval = TOWN_ERAS[0].interval
	town.growthBatch = TOWN_ERAS[0].batch
	town.growthRate = f32(town.growthBatch)/town.growthInterval
	town.growthSpeed = 1
	NameTownAssign(w, kingdomSlot, townSlot)
}

TownEra :: proc(w: ^World, kingdomSlot, townSlot: int) -> int {
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	return clamp(town.milestonesEarned, 0, len(TOWN_ERAS)-1)
}

TownBaseBatch :: proc(w: ^World, kingdomSlot, townSlot: int) -> int {
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	return TOWN_ERAS[TownEra(w, kingdomSlot, townSlot)].batch+town.growthBatchBonus
}

// Every live District Hall adds a share of the merged base batch. Destroying a
// hall removes its bonus immediately; the merged population and district area
// are unaffected.
TownEffectiveBatch :: proc(w: ^World, kingdomSlot, townSlot: int) -> int {
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	base := f32(TownBaseBatch(w, kingdomSlot, townSlot))
	halls := f32(town.buildingCounts[.DistrictHall])
	growth := KingdomTechGrowthMultiplier(w, kingdomSlot, townSlot)
	return max(1, int(math.round(base*(1+TOWN_DISTRICT_GROWTH_BONUS*halls)*growth)))
}

KingdomFreeTownSlot :: proc(w: ^World, kingdomSlot: int) -> int {
	if kingdomSlot < 0 || kingdomSlot >= KINGDOM_SLOTS || !w.kingdomUsed[kingdomSlot] {
		return -1
	}
	for townSlot in 0..<TOWN_CAPACITY {
		if !w.kingdoms[kingdomSlot].townUsed[townSlot] do return townSlot
	}
	return -1
}

KingdomTownCount :: proc(w: ^World, kingdomSlot: int) -> int {
	if kingdomSlot < 0 || kingdomSlot >= KINGDOM_SLOTS || !w.kingdomUsed[kingdomSlot] {
		return 0
	}
	count := 0
	for townSlot in 0..<TOWN_CAPACITY {
		if w.kingdoms[kingdomSlot].townUsed[townSlot] do count += 1
	}
	return count
}

// The first charter costs the base price; every town already owned beyond that
// adds a fixed increment, so wide expansion gets steadily more expensive.
TownFoundingWoodCost :: proc(w: ^World, kingdomSlot: int) -> f32 {
	towns := max(KingdomTownCount(w, kingdomSlot)-1, 0)
	base := f32(TOWN_FOUNDING_WOOD+TOWN_FOUNDING_WOOD_PER_TOWN*towns)
	base *= KingdomTechFoundingCostMultiplier(w, kingdomSlot)
	if KingdomHasHarbor(w, kingdomSlot) do base *= 0.80
	return base
}

TownFoundingSettlers :: proc(w: ^World, kingdomSlot: int) -> int {
	return max(1, TOWN_FOUNDING_SETTLERS-KingdomTechFoundingSettlerReduction(w, kingdomSlot))
}

// Builders stop chopping at a routine stockpile, but expansion needs a much
// larger reserve. While the kingdom still has room for another town, gathering
// continues until it can pay for a charter plus a small buffer.
TownWoodGatherTarget :: proc(w: ^World, kingdomSlot, townSlot: int) -> f32 {
	target: f32 = TOWN_WOOD_TARGET
	if KingdomFreeTownSlot(w, kingdomSlot) >= 0 {
		target = max(target, TownFoundingWoodCost(w, kingdomSlot)+TOWN_FOUNDING_WOOD_BUFFER)
	}

	// Era-5 towns need a real stockpile to pay the fusion sink. Builders keep
	// chopping until the next fusion is affordable plus a small buffer.
	if TownEra(w, kingdomSlot, townSlot) >= TOWN_FUSION_ERA {
		town := &w.kingdoms[kingdomSlot].towns[townSlot]
		cost := TOWN_FUSION_WOOD_BASE+TOWN_FUSION_WOOD_PER_DISTRICT*town.districtCount
		target = max(target, f32(cost+TOWN_FUSION_WOOD_BUFFER))
	}
	return target
}

// A new town is founded when its hall finishes construction. The hall was
// already paid for by the mother town, so it is spawned directly into the new
// town slot.
TownFound :: proc(w: ^World, kingdomSlot, x, y, settlers: int) -> bool {
	if kingdomSlot < 0 || kingdomSlot >= KINGDOMS_CAPACITY || !w.kingdomUsed[kingdomSlot] {
		return false
	}
	townSlot := KingdomFreeTownSlot(w, kingdomSlot)
	if townSlot < 0 do return false

	hallSlot, ok := BuildingSpawn(w, x, y, TownHall{}, kingdomSlot, townSlot)
	if !ok do return false

	TownInitialize(w, kingdomSlot, townSlot, hallSlot, x, y, 0)
	w.kingdoms[kingdomSlot].townUsed[townSlot] = true
	if kingdomSlot == w.observerKingdom {
		WorldAlertAdd(w, .TownFounded, kingdomSlot, townSlot, -1, f32(x), f32(y))
	}

	// The settlers were taken from the mother town when the charter was paid for.
	// The builder that raised the hall stays behind and gets the new town going.
	for _ in 0..<settlers {
		TownSpawnCitizen(w, kingdomSlot, townSlot, Villager{})
	}
	TownSpawnCitizen(w, kingdomSlot, townSlot, Builder{})
	KingdomAddInsight(w, kingdomSlot, CROWN_INSIGHT_PER_TOWN)
	return true
}

PlacementFailure :: enum {
	None,
	NoTown,
	AlreadyFounding,
	Unexplored,
	InvalidTerrain,
	CombatSiteOverlap,
	ConstructionOverlap,
	TooClose,
	NotCombat,
	NotUnlocked,
}

// Cheap checks for the placement preview. Reachability is validated once when
// the order is actually placed.
TownFoundingFailure :: proc(w: ^World, kingdomSlot, townSlot, x, y: int) -> PlacementFailure {
	if !WorldTownExists(w, kingdomSlot, townSlot) do return .NoTown
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	if TownConstructionKindCount(w, kingdomSlot, townSlot, .TownHall) > 0 do return .AlreadyFounding
	if kingdomSlot == w.observerKingdom {
		width, height := BuildingTileSize(TownHall{})
		if !FogRectExplored(w, x, y, width, height) do return .Unexplored
	}
	if !WorldBuildingValid(w, x, y, TownHall{}) do return .InvalidTerrain
	if CombatSiteOverlaps(w, x, y, .TownHall) do return .CombatSiteOverlap
	if TownFoundingOverlapsOtherConstruction(w, x, y) {
		return .ConstructionOverlap
	}
	if TownFoundingTooClose(w, x, y) do return .TooClose
	return .None
}

TownFoundingOverlapsOtherConstruction :: proc(w: ^World, x, y: int) -> bool {
	width, height := BuildingTileSize(TownHall{})
	for kingdomSlot in 0..<KINGDOM_SLOTS {
		if !w.kingdomUsed[kingdomSlot] do continue
		for townSlot in 0..<TOWN_CAPACITY {
			if !w.kingdoms[kingdomSlot].townUsed[townSlot] do continue
			town := &w.kingdoms[kingdomSlot].towns[townSlot]
			for site in town.constructions {
				if !site.active do continue
				otherWidth, otherHeight := BuildingTileSize(BuildingTypeFromKind(site.kind))
				if x < site.x+otherWidth && site.x < x+width &&
					y < site.y+otherHeight && site.y < y+height {
					return true
				}
			}
		}
	}
	return false
}

TownFoundingTooClose :: proc(w: ^World, x, y: int) -> bool {
	hallWidth, hallHeight := BuildingTileSize(TownHall{})
	centerX := f32(x)+f32(hallWidth)*0.5
	centerY := f32(y)+f32(hallHeight)*0.5
	worldWidth := f32(w.maxX)
	worldHeight := f32(w.maxY)
	minDistance := f32(TOWN_FOUNDING_MIN_DISTANCE)

	for kingdomSlot in 0..<KINGDOM_SLOTS {
		if !w.kingdomUsed[kingdomSlot] do continue
		for townSlot in 0..<TOWN_CAPACITY {
			if !w.kingdoms[kingdomSlot].townUsed[townSlot] do continue
			hallSlot := TownHallSlot(w, kingdomSlot, townSlot)
			if hallSlot < 0 do continue
			otherWidth, otherHeight := BuildingTileSize(w.buildings[hallSlot].type)
			otherX := f32(w.buildings.x[hallSlot])+f32(otherWidth)*0.5
			otherY := f32(w.buildings.y[hallSlot])+f32(otherHeight)*0.5
			deltaX := WorldShortestWrappedDelta(centerX-otherX, worldWidth)
			deltaY := WorldShortestWrappedDelta(centerY-otherY, worldHeight)
			if deltaX*deltaX+deltaY*deltaY < minDistance*minDistance do return true
		}
	}
	return false
}

TownFoundingAccessPoint :: proc(w: ^World, x, y: int, unitType: UnitType, unitKingdom: int) -> (int, int, bool) {
	width, height := BuildingTileSize(TownHall{})
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 do return 0, 0, false

	for radius in 1..=6 {
		innerMinX := x-radius+1
		innerMaxX := x+width-1+radius-1
		innerMinY := y-radius+1
		innerMaxY := y+height-1+radius-1
		for tileX in x-radius ..= x+width-1+radius {
			for tileY in y-radius ..= y+height-1+radius {
				if tileX >= innerMinX && tileX <= innerMaxX &&
					tileY >= innerMinY && tileY <= innerMaxY {
					continue
				}
				wrappedX := WorldWrapCoordinate(tileX, worldWidth)
				wrappedY := WorldWrapCoordinate(tileY, worldHeight)
				if !WorldTileWalkable(w, wrappedX, wrappedY, unitType, unitKingdom) do continue
				return wrappedX, wrappedY, true
			}
		}
	}
	return 0, 0, false
}

TownFoundingReachable :: proc(w: ^World, kingdomSlot, townSlot, x, y: int) -> bool {
	if !BuildingClearUnits(w, x, y, TownHall{}, false) do return false
	startX, startY, startFound := UnitFindTownReturnPoint(w, kingdomSlot, townSlot)
	if !startFound do return false
	width, height := BuildingTileSize(TownHall{})
	goalX, goalY, goalFound := BuildingFindWorkAccessPoint(w, x, y, width, height, Builder{}, kingdomSlot, startX, startY)
	if !goalFound do return false

	path: [dynamic]int
	defer delete(path)
	return AStar(w, Builder{}, kingdomSlot, startX, startY, goalX, goalY, &path)
}

// Player order: found a new town. The mother town pays the charter and its
// builders receive a town-hall construction site. If every site slot is busy,
// the least-progressed automatic site is refunded to make room.
TownStartFounding :: proc(w: ^World, kingdomSlot, townSlot, x, y: int) -> bool {
	if TownFoundingFailure(w, kingdomSlot, townSlot, x, y) != .None do return false
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	cost := TownFoundingWoodCost(w, kingdomSlot)
	if town.wood < cost do return false
	if town.citizens < TOWN_FOUNDING_MIN_CITIZENS do return false
	requiredSettlers := TownFoundingSettlers(w, kingdomSlot)
	if TownUnitCount(w, kingdomSlot, townSlot, .Villager) < requiredSettlers {
		return false
	}
	if TownUnitCount(w, kingdomSlot, townSlot, .Builder) <= 0 do return false
	if KingdomFreeTownSlot(w, kingdomSlot) < 0 do return false
	if !TownFoundingReachable(w, kingdomSlot, townSlot, x, y) do return false

	slot := TownConstructionFreeSlot(w, kingdomSlot, townSlot)
	if slot < 0 {
		slot = TownConstructionCancelLeastProgress(w, kingdomSlot, townSlot)
		if slot < 0 do return false
	}

	town.wood -= cost
	settlers := TownTakeVillagers(w, kingdomSlot, townSlot, requiredSettlers)
	if settlers < requiredSettlers {
		town.wood += cost
		for _ in 0..<settlers do TownSpawnCitizen(w, kingdomSlot, townSlot, Villager{})
		return false
	}
	town.constructions[slot] = ConstructionSite{
		active = true,
		kind = .TownHall,
		x = x,
		y = y,
		paid = cost,
		settlers = settlers,
	}
	BuildingClearUnits(w, x, y, TownHall{}, true)
	WorldConstructionChanged(w)
	return true
}

// Squared distance in tiles from a hall footprint (0 on the hall).
TownHallDistanceSquared :: proc(hallX, hallY, x, y: int) -> int {
	hallWidth, hallHeight := BuildingTileSize(TownHall{})
	deltaX := max(max(hallX-x, 0), x-(hallX+hallWidth-1))
	deltaY := max(max(hallY-y, 0), y-(hallY+hallHeight-1))
	return deltaX*deltaX+deltaY*deltaY
}

TownAreaCircleCount :: proc(w: ^World, kingdomSlot, townSlot: int) -> int {
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	return 1+town.districtCount
}

TownAreaCircle :: proc(w: ^World, kingdomSlot, townSlot, index: int) -> (x, y, radius: int) {
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	if index <= 0 do return town.x, town.y, town.areaRadius
	district := &town.districts[index-1]
	return district.x, district.y, district.radius
}

// Squared distance to the nearest circle of the compound town area.
TownTileAreaDistanceSquared :: proc(w: ^World, kingdomSlot, townSlot, x, y: int) -> int {
	if !WorldTownExists(w, kingdomSlot, townSlot) do return max(int)
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	best := TownHallDistanceSquared(town.x, town.y, x, y)
	for index in 0..<town.districtCount {
		distance := TownHallDistanceSquared(town.districts[index].x, town.districts[index].y, x, y)
		if distance < best do best = distance
	}
	return best
}

TownPointInArea :: proc(w: ^World, kingdomSlot, townSlot, x, y: int) -> bool {
	if !WorldTownExists(w, kingdomSlot, townSlot) do return false
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	if TownHallDistanceSquared(town.x, town.y, x, y) <= town.areaRadius*town.areaRadius do return true
	for index in 0..<town.districtCount {
		district := &town.districts[index]
		if TownHallDistanceSquared(district.x, district.y, x, y) <= district.radius*district.radius {
			return true
		}
	}
	return false
}

TownBuildingInArea :: proc(w: ^World, kingdomSlot, townSlot, x, y: int, type: BuildingType) -> bool {
	if !WorldTownExists(w, kingdomSlot, townSlot) do return false
	width, height := BuildingTileSize(type)
	if width <= 0 || height <= 0 do return false
	return TownPointInArea(w, kingdomSlot, townSlot, x, y) &&
		TownPointInArea(w, kingdomSlot, townSlot, x+width-1, y) &&
		TownPointInArea(w, kingdomSlot, townSlot, x, y+height-1) &&
		TownPointInArea(w, kingdomSlot, townSlot, x+width-1, y+height-1)
}

// Milestones grow every circle of a merged town together.
TownAreaExpand :: proc(w: ^World, kingdomSlot, townSlot, delta: int) {
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	town.areaRadius += delta
	for index in 0..<town.districtCount {
		town.districts[index].radius += delta
	}
}

TownAreaBounds :: proc(w: ^World, kingdomSlot, townSlot: int) -> (minX, maxX, minY, maxY: int) {
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	hallWidth, hallHeight := BuildingTileSize(TownHall{})
	minX = town.x-town.areaRadius-1
	maxX = town.x+hallWidth+town.areaRadius
	minY = town.y-town.areaRadius-1
	maxY = town.y+hallHeight+town.areaRadius
	for index in 0..<town.districtCount {
		district := &town.districts[index]
		minX = min(minX, district.x-district.radius-1)
		maxX = max(maxX, district.x+hallWidth+district.radius)
		minY = min(minY, district.y-district.radius-1)
		maxY = max(maxY, district.y+hallHeight+district.radius)
	}
	return
}

// Frontier test: any circle of either town touches or overlaps any circle of
// the other, including a one-tile tolerance for odd coastlines.
TownAreasTouch :: proc(w: ^World, kingdomSlot, townA, townB: int) -> bool {
	if !WorldTownExists(w, kingdomSlot, townA) || !WorldTownExists(w, kingdomSlot, townB) {
		return false
	}
	hallWidth, _ := BuildingTileSize(TownHall{})
	for indexA in 0..<TownAreaCircleCount(w, kingdomSlot, townA) {
		ax, ay, ar := TownAreaCircle(w, kingdomSlot, townA, indexA)
		for indexB in 0..<TownAreaCircleCount(w, kingdomSlot, townB) {
			bx, by, br := TownAreaCircle(w, kingdomSlot, townB, indexB)
			dx := WorldShortestWrappedDelta(f32(ax-bx), f32(w.maxX))
			dy := WorldShortestWrappedDelta(f32(ay-by), f32(w.maxY))
			// Both circles are measured from their hall anchors, so add the two
			// half-footprints to the frontier tolerance.
			limit := f32(ar+br+hallWidth+TOWN_FUSION_FRONTIER_SLACK)
			if dx*dx+dy*dy <= limit*limit do return true
		}
	}
	return false
}

TownFindBuilding :: proc(w: ^World, kingdomSlot, townSlot: int, kind: BuildingKind) -> int {
	if !WorldTownExists(w, kingdomSlot, townSlot) do return -1
	slot := w.kingdoms[kingdomSlot].towns[townSlot].buildingSlots[kind]
	if slot < 0 || slot >= BUILDING_CAPACITY || !w.buildingUsed[slot] do return -1
	if BuildingKindOf(w.buildings[slot].type) != kind do return -1
	if w.buildings[slot].kingdom != kingdomSlot || w.buildings[slot].town != townSlot {
		return -1
	}
	return slot
}

TownUnitAvailable :: proc(w: ^World, kingdomSlot, townSlot: int, kind: UnitKind) -> bool {
	if !TownUnitUnlocked(w, kingdomSlot, townSlot, kind) do return false
	return TownFindBuilding(w, kingdomSlot, townSlot, UnitTrainingBuildingKind(kind)) >= 0
}

TownUnitUnlocked :: proc(w: ^World, kingdomSlot, townSlot: int, kind: UnitKind) -> bool {
	if !WorldTownExists(w, kingdomSlot, townSlot) do return false
	return kind in w.kingdoms[kingdomSlot].towns[townSlot].unlockedUnits
}

TownUnitCount :: proc(w: ^World, kingdomSlot, townSlot: int, kind: UnitKind) -> int {
	if !WorldTownExists(w, kingdomSlot, townSlot) do return 0
	count := 0
	for unitSlot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[unitSlot] do continue
		if w.units[unitSlot].kingdome != kingdomSlot || w.units[unitSlot].town != townSlot {
			continue
		}
		if UnitKindOf(w.units[unitSlot].type) == kind do count += 1
	}
	return count
}

// Moves up to count villagers out of a town. Villagers that are not already
// retraining are taken first, so queued jobs keep their workers when possible.
TownTakeVillagers :: proc(w: ^World, kingdomSlot, townSlot, count: int) -> int {
	taken := 0
	for pass in 0..<2 {
		for unitSlot in 0..<UNIT_CAPACITY {
			if taken >= count do return taken
			if !w.unitUsed[unitSlot] do continue
			unit := &w.units[unitSlot]
			if unit.kingdome != kingdomSlot || unit.town != townSlot do continue
			if UnitKindOf(unit.type) != .Villager do continue
			_, converting := unit.state.(StateConverting)
			if (pass == 0) == converting do continue
			if UnitDespawn(w, unitSlot) do taken += 1
		}
	}
	return taken
}

// Conversions always pass through villagers: A -> Villager -> B.
TownAddConversion :: proc(w: ^World, kingdomSlot, townSlot: int, from, to: UnitKind, count: int) -> bool {
	if count <= 0 || from == to do return false
	if !WorldTownExists(w, kingdomSlot, townSlot) do return false
	if from != .Villager && to != .Villager do return false
	if !TownUnitAvailable(w, kingdomSlot, townSlot, to) do return false

	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	for jobIndex in 0..<town.conversionCount {
		job := &town.conversions[jobIndex]
		if job.from == from && job.to == to {
			job.remaining += count
			return true
		}
	}
	if town.conversionCount >= MAX_CONVERSION_JOBS do return false

	town.conversions[town.conversionCount] = ConversionJob{from = from, to = to, remaining = count}
	town.conversionCount += 1
	return true
}

// Cancels queued work first, then recalls units already travelling or training.
TownRemoveConversion :: proc(w: ^World, kingdomSlot, townSlot: int, from, to: UnitKind, count: int) -> bool {
	if count <= 0 || !WorldTownExists(w, kingdomSlot, townSlot) do return false
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	for jobIndex in 0..<town.conversionCount {
		job := &town.conversions[jobIndex]
		if job.from != from || job.to != to do continue
		removed := min(count, max(0, job.remaining-job.assigned))
		job.remaining -= removed
		for unitSlot in 0..<UNIT_CAPACITY {
			if removed >= count do break
			if !w.unitUsed[unitSlot] do continue
			unit := &w.units[unitSlot]
			if unit.kingdome != kingdomSlot || unit.town != townSlot do continue
			if UnitKindOf(unit.type) != from do continue
			state, converting := unit.state.(StateConverting)
			if !converting || state.to != to do continue
			UnitConversionCancel(w, unitSlot)
			job.remaining -= 1
			removed += 1
		}
		if job.remaining <= 0 {
			for i in jobIndex..<town.conversionCount-1 {
				town.conversions[i] = town.conversions[i+1]
			}
			town.conversionCount -= 1
		}
		return removed > 0
	}
	return false
}

TownConversionsClear :: proc(w: ^World, kingdomSlot, townSlot: int) {
	if !WorldTownExists(w, kingdomSlot, townSlot) do return
	w.kingdoms[kingdomSlot].towns[townSlot].conversionCount = 0
}

// Eras advance automatically from population. Rewards are banked: a town can
// cross several thresholds and choose them later without slowing its growth.
TownMilestoneCheck :: proc(w: ^World, kingdomSlot, townSlot: int) {
	if !WorldTownExists(w, kingdomSlot, townSlot) do return
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	for town.milestonesEarned < TOWN_MILESTONE_TIER_COUNT {
		next := TOWN_ERAS[town.milestonesEarned+1].threshold
		if town.citizens < next do break
		town.milestonesEarned += 1
		insight := CROWN_INSIGHT_PER_MILESTONE
		if KingdomHasTech(w, kingdomSlot, .HighCouncil) do insight *= 2
		KingdomAddInsight(w, kingdomSlot, insight)
		if kingdomSlot == w.observerKingdom {
			WorldAlertAdd(w, .Milestone, kingdomSlot, townSlot, -1, f32(town.x), f32(town.y))
		}
	}
	town.milestonePending = town.milestonesEarned > town.milestonesChosen
}

TownChooseMilestone :: proc(w: ^World, kingdomSlot, townSlot, option: int) -> bool {
	if !WorldTownExists(w, kingdomSlot, townSlot) do return false
	if option != 0 && option != 1 do return false
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	if town.milestonesChosen >= TOWN_MILESTONE_TIER_COUNT ||
		town.milestonesChosen >= town.milestonesEarned {
		return false
	}

	choice := TOWN_ERA_REWARDS[town.milestonesChosen][option]
	town.unlockedBuildings |= choice.unlocks
	town.unlockedUnits |= choice.units
	TownAreaExpand(w, kingdomSlot, townSlot, TOWN_AREA_EXPANSION)
	town.milestoneOptions[town.milestonesChosen] = u8(option)
	town.milestonesChosen += 1
	town.milestonePending = town.milestonesEarned > town.milestonesChosen
	return true
}

TownMilestoneOption :: proc(w: ^World, kingdomSlot, townSlot, option: int) -> (MilestoneOption, bool) {
	if !WorldTownExists(w, kingdomSlot, townSlot) do return {}, false
	if option != 0 && option != 1 do return {}, false
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	if town.milestonesChosen >= TOWN_MILESTONE_TIER_COUNT ||
		town.milestonesChosen >= town.milestonesEarned {
		return {}, false
	}
	return TOWN_ERA_REWARDS[town.milestonesChosen][option], true
}

FusionFailure :: enum {
	None,
	NoTown,
	DifferentKingdom,
	SameTown,
	NotEraFive,
	NoHall,
	NoFrontier,
	PendingMilestone,
	NoWood,
	DistrictLimit,
	ConstructionConflict,
	ConversionLimit,
}

TownFusionCost :: proc(w: ^World, kingdomSlot, hostSlot: int) -> f32 {
	host := &w.kingdoms[kingdomSlot].towns[hostSlot]
	return f32(TOWN_FUSION_WOOD_BASE+TOWN_FUSION_WOOD_PER_DISTRICT*host.districtCount)
}

TownFusionNewConversionSlots :: proc(w: ^World, kingdomSlot, hostSlot, guestSlot: int) -> int {
	host := &w.kingdoms[kingdomSlot].towns[hostSlot]
	guest := &w.kingdoms[kingdomSlot].towns[guestSlot]
	needed := 0
	for guestIndex in 0..<guest.conversionCount {
		guestJob := guest.conversions[guestIndex]
		found := false
		for hostIndex in 0..<host.conversionCount {
			hostJob := host.conversions[hostIndex]
			if hostJob.from == guestJob.from && hostJob.to == guestJob.to {
				found = true
				break
			}
		}
		if !found do needed += 1
	}
	return needed
}

TownFusionFailure :: proc(
	w: ^World,
	kingdomSlot, hostSlot, targetKingdom, guestSlot: int,
) -> FusionFailure {
	if !WorldTownExists(w, kingdomSlot, hostSlot) do return .NoTown
	if targetKingdom != kingdomSlot do return .DifferentKingdom
	if !WorldTownExists(w, targetKingdom, guestSlot) do return .NoTown
	if hostSlot == guestSlot do return .SameTown

	host := &w.kingdoms[kingdomSlot].towns[hostSlot]
	guest := &w.kingdoms[kingdomSlot].towns[guestSlot]
	if TownEra(w, kingdomSlot, hostSlot) < TOWN_FUSION_ERA ||
		TownEra(w, kingdomSlot, guestSlot) < TOWN_FUSION_ERA {
		return .NotEraFive
	}
	if TownHallSlot(w, kingdomSlot, hostSlot) < 0 ||
		TownHallSlot(w, kingdomSlot, guestSlot) < 0 {
		return .NoHall
	}
	if !TownAreasTouch(w, kingdomSlot, hostSlot, guestSlot) do return .NoFrontier
	if host.milestonesEarned != host.milestonesChosen ||
		guest.milestonesEarned != guest.milestonesChosen {
		return .PendingMilestone
	}
	if host.districtCount+1+guest.districtCount > MAX_TOWN_DISTRICTS do return .DistrictLimit
	if TownConstructionCount(w, kingdomSlot, hostSlot) > 0 ||
		TownConstructionCount(w, kingdomSlot, guestSlot) > 0 {
		return .ConstructionConflict
	}
	if host.conversionCount+TownFusionNewConversionSlots(w, kingdomSlot, hostSlot, guestSlot) >
		MAX_CONVERSION_JOBS {
		return .ConversionLimit
	}
	if host.wood < TownFusionCost(w, kingdomSlot, hostSlot) do return .NoWood
	return .None
}

// Absorbs a frontier era-5 town into the initiating town. Buildings and units
// never move; only their town ownership and the compound area change.
TownFuse :: proc(
	w: ^World,
	kingdomSlot, hostSlot, targetKingdom, guestSlot: int,
) -> bool {
	if TownFusionFailure(w, kingdomSlot, hostSlot, targetKingdom, guestSlot) != .None {
		return false
	}

	host := &w.kingdoms[kingdomSlot].towns[hostSlot]
	guest := &w.kingdoms[kingdomSlot].towns[guestSlot]
	cost := TownFusionCost(w, kingdomSlot, hostSlot)

	guestName := guest.name
	guestX, guestY := guest.x, guest.y
	guestRadius := guest.areaRadius
	guestDistricts := guest.districts
	guestDistrictCount := guest.districtCount
	guestHall := guest.hallSlot

	// Reassign every guest building. The old hall becomes the district hall in
	// place, so its footprint and tile indices stay valid.
	for buildingSlot in 0..<BUILDING_CAPACITY {
		if !w.buildingUsed[buildingSlot] do continue
		if w.buildings[buildingSlot].kingdom != kingdomSlot ||
			w.buildings[buildingSlot].town != guestSlot {
			continue
		}
		w.buildings[buildingSlot].town = hostSlot
		if buildingSlot == guestHall {
			w.buildings[buildingSlot].type = DistrictHall{}
			w.buildings[buildingSlot].health = BuildingDefaultHealth(DistrictHall{})
			w.buildings[buildingSlot].cooldown = 0
			w.buildings[buildingSlot].homeResident = 0
		}
	}

	for unitSlot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[unitSlot] do continue
		if w.units[unitSlot].kingdome != kingdomSlot || w.units[unitSlot].town != guestSlot {
			continue
		}
		w.units[unitSlot].town = hostSlot
		// Paths were built against the old town's flow field; recompute them
		// against the merged town on the next update.
		w.units[unitSlot].pathReady = false
	}
	host.citizens += guest.citizens
	guest.citizens = 0

	for guestIndex in 0..<guest.conversionCount {
		job := guest.conversions[guestIndex]
		merged := false
		for hostIndex in 0..<host.conversionCount {
			hostJob := &host.conversions[hostIndex]
			if hostJob.from != job.from || hostJob.to != job.to do continue
			hostJob.remaining += job.remaining
			hostJob.assigned += job.assigned
			merged = true
			break
		}
		if !merged {
			host.conversions[host.conversionCount] = job
			host.conversionCount += 1
		}
	}

	host.wood += guest.wood
	host.wood -= cost
	host.unlockedBuildings |= guest.unlockedBuildings
	host.unlockedUnits |= guest.unlockedUnits

	// Merged population keeps the combined base batch; each transferred District
	// Hall adds its 10% share on top.
	host.growthBatchBonus += TownBaseBatch(w, kingdomSlot, guestSlot)
	host.growthCooldown = min(host.growthCooldown, guest.growthCooldown)
	host.growthPending += guest.growthPending
	host.growthInterval = TOWN_ERAS[TOWN_FUSION_ERA].interval
	host.growthBatch = TownEffectiveBatch(w, kingdomSlot, hostSlot)
	host.growthRate = f32(host.growthBatch)/host.growthInterval

	district := TownDistrict{x = guestX, y = guestY, radius = guestRadius}
	NameDistrictAssign(&district.name, &guestName)
	host.districts[host.districtCount] = district
	host.districtCount += 1
	for districtIndex in 0..<guestDistrictCount {
		host.districts[host.districtCount] = guestDistricts[districtIndex]
		host.districtCount += 1
	}
	host.fusionCount += 1
	host.alarmActive = host.alarmActive || guest.alarmActive

	if w.kingdoms[kingdomSlot].capitalSlot == guestSlot ||
		w.kingdoms[kingdomSlot].capitalSlot == hostSlot {
		w.kingdoms[kingdomSlot].capitalSlot = hostSlot
	}

	if kingdomSlot == w.observerKingdom {
		WorldAlertAdd(w, .TownFused, kingdomSlot, hostSlot, guestSlot, f32(guestX), f32(guestY))
	}

	TownFusionRedirectOrders(w, kingdomSlot, hostSlot, guestSlot)
	w.kingdoms[kingdomSlot].townUsed[guestSlot] = false

	for otherKingdom in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[otherKingdom] do continue
		for otherTown in 0..<TOWN_CAPACITY {
			if !w.kingdoms[otherKingdom].townUsed[otherTown] do continue
			TownOrdersRebuild(w, otherKingdom, otherTown)
		}
	}

	w.kingdoms[kingdomSlot].towns[guestSlot] = Town{}
	WorldConstructionChanged(w)
	w.navigationRevision += 1
	KingdomAddInsight(w, kingdomSlot, CROWN_INSIGHT_PER_FUSION)
	return true
}

TownFusionRedirectOrders :: proc(w: ^World, kingdomSlot, hostSlot, guestSlot: int) {
	host := &w.kingdoms[kingdomSlot].towns[hostSlot]
	guest := &w.kingdoms[kingdomSlot].towns[guestSlot]

	// Redirect every order that targeted the guest to the host.
	for otherKingdom in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[otherKingdom] do continue
		for otherTown in 0..<TOWN_CAPACITY {
			if !w.kingdoms[otherKingdom].townUsed[otherTown] do continue
			// The guest's own orders are merged below; the host never needs an
			// order pointing at itself.
			if otherKingdom == kingdomSlot && (otherTown == hostSlot || otherTown == guestSlot) {
				continue
			}
			other := &w.kingdoms[otherKingdom].towns[otherTown]
			if other.attackOrders[kingdomSlot][guestSlot] {
				other.attackOrders[kingdomSlot][guestSlot] = false
				other.attackOrders[kingdomSlot][hostSlot] = true
				host.attackedBy[otherKingdom][otherTown] = true
			}
			if other.defendOrders[kingdomSlot][guestSlot] {
				other.defendOrders[kingdomSlot][guestSlot] = false
				other.defendOrders[kingdomSlot][hostSlot] = true
				host.defendedBy[otherKingdom][otherTown] = true
			}
		}
	}

	// The guest's own outgoing orders become the host's.
	for otherKingdom in 0..<KINGDOMS_CAPACITY {
		for otherTown in 0..<TOWN_CAPACITY {
			if guest.attackOrders[otherKingdom][otherTown] {
				host.attackOrders[otherKingdom][otherTown] = true
				if WorldTownExists(w, otherKingdom, otherTown) {
					w.kingdoms[otherKingdom].towns[otherTown].attackedBy[kingdomSlot][hostSlot] = true
				}
			}
			if guest.defendOrders[otherKingdom][otherTown] {
				host.defendOrders[otherKingdom][otherTown] = true
				if WorldTownExists(w, otherKingdom, otherTown) {
					w.kingdoms[otherKingdom].towns[otherTown].defendedBy[kingdomSlot][hostSlot] = true
				}
			}
		}
	}

	for otherKingdom in 0..<KINGDOMS_CAPACITY {
		for otherTown in 0..<TOWN_CAPACITY {
			if guest.attackedBy[otherKingdom][otherTown] {
				host.attackedBy[otherKingdom][otherTown] = true
			}
			if guest.defendedBy[otherKingdom][otherTown] {
				host.defendedBy[otherKingdom][otherTown] = true
			}
		}
	}

	guest.attackOrders = {}
	guest.defendOrders = {}
	guest.attackedBy = {}
	guest.defendedBy = {}
	guest.orderCount = 0
	guest.orderRevision += 1
}

// Player order: attacker town -> attack -> any town of another kingdom.
// Declaring the order is also the declaration of war.
TownStartAttack :: proc(w: ^World, kingdomSlotA, townSlotA, kingdomSlotB, townSlotB: int) -> bool {
	if !WorldTownExists(w, kingdomSlotA, townSlotA) || !WorldTownExists(w, kingdomSlotB, townSlotB) {
		return false
	}
	if w.kingdoms[kingdomSlotA].towns[townSlotA].attackOrders[kingdomSlotB][townSlotB] do return false

	// Independent towns are not diplomatic kingdoms: attacking one does not
	// require contact, and the neutral faction simply becomes hostile.
	if kingdomSlotB == NEUTRAL_KINGDOM {
		if kingdomSlotA == NEUTRAL_KINGDOM do return false
		w.kingdoms[kingdomSlotA].kingdomWar[NEUTRAL_KINGDOM] = true
		w.kingdoms[NEUTRAL_KINGDOM].kingdomWar[kingdomSlotA] = true
		w.kingdoms[kingdomSlotA].towns[townSlotA].attackOrders[NEUTRAL_KINGDOM][townSlotB] = true
		w.kingdoms[NEUTRAL_KINGDOM].towns[townSlotB].attackedBy[kingdomSlotA][townSlotA] = true
		TownOrdersRebuild(w, kingdomSlotA, townSlotA)
		return true
	}

	if !KingdomsMet(w, kingdomSlotA, kingdomSlotB) do return false
	if !KingdomAtWar(w, kingdomSlotA, kingdomSlotB) &&
		!KingdomDeclareWar(w, kingdomSlotA, kingdomSlotB) {
		return false
	}
	w.kingdoms[kingdomSlotA].towns[townSlotA].attackOrders[kingdomSlotB][townSlotB] = true
	w.kingdoms[kingdomSlotB].towns[townSlotB].attackedBy[kingdomSlotA][townSlotA] = true
	TownOrdersRebuild(w, kingdomSlotA, townSlotA)
	return true
}

// Player order: defender town -> defend -> any non-enemy town. The defending
// town sends a share of its warriors to patrol the protected town; the rest
// stay home. Declaring war on the protected kingdom breaks the order.
TownStartDefending :: proc(w: ^World, kingdomSlot, defenderTownSlot, protectedKingdomSlot, protectedTownSlot: int) {
	if !WorldTownExists(w, kingdomSlot, defenderTownSlot) ||
		!WorldTownExists(w, protectedKingdomSlot, protectedTownSlot) {
		return
	}
	if protectedKingdomSlot == NEUTRAL_KINGDOM do return
	if kingdomSlot == protectedKingdomSlot && defenderTownSlot == protectedTownSlot do return
	if KingdomAtWar(w, kingdomSlot, protectedKingdomSlot) do return
	if w.kingdoms[kingdomSlot].towns[defenderTownSlot].defendOrders[protectedKingdomSlot][protectedTownSlot] {
		return
	}

	w.kingdoms[kingdomSlot].towns[defenderTownSlot].defendOrders[protectedKingdomSlot][protectedTownSlot] = true
	w.kingdoms[protectedKingdomSlot].towns[protectedTownSlot].defendedBy[kingdomSlot][defenderTownSlot] = true
	TownOrdersRebuild(w, kingdomSlot, defenderTownSlot)
}

TownStopAttack :: proc(w: ^World, kingdomSlotA, townSlotA, kingdomSlotB, townSlotB: int) {
	if !WorldTownExists(w, kingdomSlotA, townSlotA) do return
	if !w.kingdoms[kingdomSlotA].towns[townSlotA].attackOrders[kingdomSlotB][townSlotB] do return

	w.kingdoms[kingdomSlotA].towns[townSlotA].attackOrders[kingdomSlotB][townSlotB] = false
	if WorldTownExists(w, kingdomSlotB, townSlotB) {
		w.kingdoms[kingdomSlotB].towns[townSlotB].attackedBy[kingdomSlotA][townSlotA] = false
	}
	TownOrdersRebuild(w, kingdomSlotA, townSlotA)
}

TownStopDefending :: proc(w: ^World, kingdomSlot, defenderTownSlot, protectedKingdomSlot, protectedTownSlot: int) {
	if !WorldTownExists(w, kingdomSlot, defenderTownSlot) do return
	if !w.kingdoms[kingdomSlot].towns[defenderTownSlot].defendOrders[protectedKingdomSlot][protectedTownSlot] {
		return
	}

	w.kingdoms[kingdomSlot].towns[defenderTownSlot].defendOrders[protectedKingdomSlot][protectedTownSlot] = false
	if WorldTownExists(w, protectedKingdomSlot, protectedTownSlot) {
		w.kingdoms[protectedKingdomSlot].towns[protectedTownSlot].defendedBy[kingdomSlot][defenderTownSlot] = false
	}
	TownOrdersRebuild(w, kingdomSlot, defenderTownSlot)
}

// A war invalidates defense orders between the two kingdoms, in both
// directions. Other kingdoms defending either side are unaffected.
KingdomBreakDefenses :: proc(w: ^World, kingdomA, kingdomB: int) {
	for defenderKingdom in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[defenderKingdom] do continue
		protectedKingdom := -1
		if defenderKingdom == kingdomA {
			protectedKingdom = kingdomB
		} else if defenderKingdom == kingdomB {
			protectedKingdom = kingdomA
		} else {
			continue
		}
		for defenderTown in 0..<TOWN_CAPACITY {
			if !w.kingdoms[defenderKingdom].townUsed[defenderTown] do continue
			town := &w.kingdoms[defenderKingdom].towns[defenderTown]
			changed := false
			for protectedTown in 0..<TOWN_CAPACITY {
				if !town.defendOrders[protectedKingdom][protectedTown] do continue
				town.defendOrders[protectedKingdom][protectedTown] = false
				if WorldTownExists(w, protectedKingdom, protectedTown) {
					w.kingdoms[protectedKingdom].towns[protectedTown].defendedBy[defenderKingdom][defenderTown] = false
				}
				changed = true
			}
			if changed do TownOrdersRebuild(w, defenderKingdom, defenderTown)
		}
	}
}

// Contact is mutual and persistent, unlike the observer's terrain memory.
// Neither declaring war nor spectator visibility may manufacture contact.
KingdomsMet :: proc(w: ^World, kingdomA, kingdomB: int) -> bool {
	if kingdomA < 0 || kingdomA >= KINGDOMS_CAPACITY ||
		kingdomB < 0 || kingdomB >= KINGDOMS_CAPACITY || kingdomA == kingdomB {
		return false
	}
	return w.kingdomUsed[kingdomA] && w.kingdomUsed[kingdomB] &&
		w.fog.contacts[kingdomA][kingdomB] && w.fog.contacts[kingdomB][kingdomA]
}

KingdomMeet :: proc(w: ^World, kingdomA, kingdomB: int) {
	if kingdomA < 0 || kingdomA >= KINGDOMS_CAPACITY ||
		kingdomB < 0 || kingdomB >= KINGDOMS_CAPACITY || kingdomA == kingdomB {
		return
	}
	if !w.kingdomUsed[kingdomA] || !w.kingdomUsed[kingdomB] do return
	w.fog.contacts[kingdomA][kingdomB] = true
	w.fog.contacts[kingdomB][kingdomA] = true
}

KingdomCanDeclareWar :: proc(w: ^World, kingdomA, kingdomB: int) -> bool {
	return KingdomsMet(w, kingdomA, kingdomB) && !KingdomAtWar(w, kingdomA, kingdomB)
}

KingdomDeclareWar :: proc(w: ^World, kingdomSlotA, kingdomSlotB: int) -> bool {
	if !KingdomCanDeclareWar(w, kingdomSlotA, kingdomSlotB) do return false
	w.kingdoms[kingdomSlotA].kingdomWar[kingdomSlotB] = true
	w.kingdoms[kingdomSlotB].kingdomWar[kingdomSlotA] = true
	KingdomBreakDefenses(w, kingdomSlotA, kingdomSlotB)
	if kingdomSlotA == w.observerKingdom {
		WorldAlertAdd(w, .WarDeclared, kingdomSlotA, -1, kingdomSlotB, 0, 0)
	} else if kingdomSlotB == w.observerKingdom {
		WorldAlertAdd(w, .WarDeclared, kingdomSlotB, -1, kingdomSlotA, 0, 0)
	}
	return true
}

// Ends only the war between two kingdoms and removes their standing attack
// orders in both directions. Other wars are untouched.
KingdomMakePeace :: proc(w: ^World, kingdomA, kingdomB: int) {
	if kingdomA < 0 || kingdomA >= KINGDOMS_CAPACITY ||
		kingdomB < 0 || kingdomB >= KINGDOMS_CAPACITY || kingdomA == kingdomB {
		return
	}
	// The neutral faction never negotiates.
	if kingdomA == NEUTRAL_KINGDOM || kingdomB == NEUTRAL_KINGDOM do return
	if !w.kingdomUsed[kingdomA] || !w.kingdomUsed[kingdomB] do return
	if !KingdomAtWar(w, kingdomA, kingdomB) do return

	w.kingdoms[kingdomA].kingdomWar[kingdomB] = false
	w.kingdoms[kingdomB].kingdomWar[kingdomA] = false

	for pair in 0..<2 {
		attacker := kingdomA
		defender := kingdomB
		if pair == 1 {
			attacker = kingdomB
			defender = kingdomA
		}
		for townSlot in 0..<TOWN_CAPACITY {
			if !w.kingdoms[attacker].townUsed[townSlot] do continue
			town := &w.kingdoms[attacker].towns[townSlot]
			changed := false
			for targetTown in 0..<TOWN_CAPACITY {
				if !town.attackOrders[defender][targetTown] do continue
				town.attackOrders[defender][targetTown] = false
				if WorldTownExists(w, defender, targetTown) {
					w.kingdoms[defender].towns[targetTown].attackedBy[attacker][townSlot] = false
				}
				changed = true
			}
			if changed do TownOrdersRebuild(w, attacker, townSlot)
		}
	}

	if kingdomA == w.observerKingdom {
		WorldAlertAdd(w, .PeaceMade, kingdomA, -1, kingdomB, 0, 0)
	} else if kingdomB == w.observerKingdom {
		WorldAlertAdd(w, .PeaceMade, kingdomB, -1, kingdomA, 0, 0)
	}
}

KingdomAtWar :: proc(w: ^World, kingdomSlotA, kingdomSlotB: int) -> bool {
	if kingdomSlotA < 0 || kingdomSlotA >= KINGDOM_SLOTS ||
		kingdomSlotB < 0 || kingdomSlotB >= KINGDOM_SLOTS || kingdomSlotA == kingdomSlotB {
		return false
	}
	return w.kingdomUsed[kingdomSlotA] && w.kingdomUsed[kingdomSlotB] &&
		w.kingdoms[kingdomSlotA].kingdomWar[kingdomSlotB]
}


// Turns the sparse order matrices into a compact list the warrior update can
// index in constant time. Called only when orders change, never per tick.
TownOrdersRebuild :: proc(w: ^World, kingdomSlot, townSlot: int) {
	if !WorldTownExists(w, kingdomSlot, townSlot) do return
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	count := 0
	for kingdomB in 0..<KINGDOM_SLOTS {
		for townB in 0..<TOWN_CAPACITY {
			if !town.attackOrders[kingdomB][townB] do continue
			if !WorldTownExists(w, kingdomB, townB) || !KingdomAtWar(w, kingdomSlot, kingdomB) {
				if WorldTownExists(w, kingdomB, townB) {
					w.kingdoms[kingdomB].towns[townB].attackedBy[kingdomSlot][townSlot] = false
				}
				town.attackOrders[kingdomB][townB] = false
				continue
			}
			if count >= TOWN_WARRIOR_ORDERS_CAPACITY {
				w.kingdoms[kingdomB].towns[townB].attackedBy[kingdomSlot][townSlot] = false
				town.attackOrders[kingdomB][townB] = false
				continue
			}
			town.orders[count] = TownAttackOrder{kingdom = kingdomB, town = townB}
			count += 1
		}
	}
	for protectedKingdom in 0..<KINGDOMS_CAPACITY {
		for protectedTown in 0..<TOWN_CAPACITY {
			if !town.defendOrders[protectedKingdom][protectedTown] do continue
			valid := WorldTownExists(w, protectedKingdom, protectedTown) &&
				!(protectedKingdom == kingdomSlot && protectedTown == townSlot) &&
				!KingdomAtWar(w, kingdomSlot, protectedKingdom)
			if !valid {
				if WorldTownExists(w, protectedKingdom, protectedTown) {
					w.kingdoms[protectedKingdom].towns[protectedTown].defendedBy[kingdomSlot][townSlot] = false
				}
				town.defendOrders[protectedKingdom][protectedTown] = false
				continue
			}
			if count >= TOWN_WARRIOR_ORDERS_CAPACITY {
				w.kingdoms[protectedKingdom].towns[protectedTown].defendedBy[kingdomSlot][townSlot] = false
				town.defendOrders[protectedKingdom][protectedTown] = false
				continue
			}
			town.orders[count] = TownDefendOrder{kingdom = protectedKingdom, town = protectedTown}
			count += 1
		}
	}
	town.orderCount = count
	town.orderRevision += 1
}

// Removes every order that mentions a town that no longer exists and clears
// the mirrors on both sides so no stale target survives.
TownOrdersClear :: proc(w: ^World, kingdomSlot, townSlot: int) {
	if !WorldTownExists(w, kingdomSlot, townSlot) do return
	town := &w.kingdoms[kingdomSlot].towns[townSlot]

	for kingdomB in 0..<KINGDOM_SLOTS {
		for townB in 0..<TOWN_CAPACITY {
			if !town.attackOrders[kingdomB][townB] do continue
			town.attackOrders[kingdomB][townB] = false
			if WorldTownExists(w, kingdomB, townB) {
				w.kingdoms[kingdomB].towns[townB].attackedBy[kingdomSlot][townSlot] = false
			}
		}
	}
	for kingdomA in 0..<KINGDOM_SLOTS {
		for townA in 0..<TOWN_CAPACITY {
			if !town.attackedBy[kingdomA][townA] do continue
			town.attackedBy[kingdomA][townA] = false
			if WorldTownExists(w, kingdomA, townA) {
				w.kingdoms[kingdomA].towns[townA].attackOrders[kingdomSlot][townSlot] = false
				TownOrdersRebuild(w, kingdomA, townA)
			}
		}
	}

	for protectedKingdom in 0..<KINGDOMS_CAPACITY {
		for protectedTown in 0..<TOWN_CAPACITY {
			if !town.defendOrders[protectedKingdom][protectedTown] do continue
			town.defendOrders[protectedKingdom][protectedTown] = false
			if WorldTownExists(w, protectedKingdom, protectedTown) {
				w.kingdoms[protectedKingdom].towns[protectedTown].defendedBy[kingdomSlot][townSlot] = false
			}
		}
	}
	for defenderKingdom in 0..<KINGDOMS_CAPACITY {
		for defenderTown in 0..<TOWN_CAPACITY {
			if !town.defendedBy[defenderKingdom][defenderTown] do continue
			town.defendedBy[defenderKingdom][defenderTown] = false
			if WorldTownExists(w, defenderKingdom, defenderTown) {
				w.kingdoms[defenderKingdom].towns[defenderTown].defendOrders[kingdomSlot][townSlot] = false
				TownOrdersRebuild(w, defenderKingdom, defenderTown)
			}
		}
	}

	town.orderCount = 0
	town.orderRevision += 1
}

KingdomEndWar :: proc(w: ^World, kingdomSlot: int) {
	if kingdomSlot < 0 || kingdomSlot >= KINGDOMS_CAPACITY || !w.kingdomUsed[kingdomSlot] {
		return
	}

	for townSlot in 0..<TOWN_CAPACITY {
		if !w.kingdoms[kingdomSlot].townUsed[townSlot] do continue
		TownOrdersClear(w, kingdomSlot, townSlot)
		TownConversionsClear(w, kingdomSlot, townSlot)
	}

	for other in 0..<KINGDOM_SLOTS {
		w.kingdoms[kingdomSlot].kingdomWar[other] = false
		if other == kingdomSlot do continue
		w.kingdoms[other].kingdomWar[kingdomSlot] = false
		if !w.kingdomUsed[other] do continue
		for townSlot in 0..<TOWN_CAPACITY {
			if !w.kingdoms[other].townUsed[townSlot] do continue
			town := &w.kingdoms[other].towns[townSlot]
			changed := false
			for townB in 0..<TOWN_CAPACITY {
				if town.attackOrders[kingdomSlot][townB] {
					town.attackOrders[kingdomSlot][townB] = false
					changed = true
				}
				if town.attackedBy[kingdomSlot][townB] {
					town.attackedBy[kingdomSlot][townB] = false
				}
			}
			if changed do TownOrdersRebuild(w, other, townSlot)
		}
	}
	w.kingdoms[kingdomSlot].kingdomWar[kingdomSlot] = false
}

TownHallSlot :: proc(w: ^World, kingdomSlot, townSlot: int) -> int {
	if !WorldTownExists(w, kingdomSlot, townSlot) do return -1
	slot := w.kingdoms[kingdomSlot].towns[townSlot].hallSlot
	if slot < 0 || slot >= BUILDING_CAPACITY || !w.buildingUsed[slot] do return -1
	if BuildingKindOf(w.buildings[slot].type) != .TownHall do return -1
	return slot
}

KingdomChooseTownForUnit :: proc(w: ^World, kingdomSlot, unitSlot, destroyedBuildingSlot: int) -> int {
	worldWidth := f32(w.maxX)
	worldHeight := f32(w.maxY)
	unitX := WorldWrapPosition(w.units[unitSlot].x, worldWidth)
	unitY := WorldWrapPosition(w.units[unitSlot].y, worldHeight)
	buildingWidth, buildingHeight := BuildingTileSize(TownHall{})

	weights: [TOWN_CAPACITY]f32
	totalWeight: f32 = 0
	for townSlot in 0..<TOWN_CAPACITY {
		if !w.kingdoms[kingdomSlot].townUsed[townSlot] do continue
		town := w.kingdoms[kingdomSlot].towns[townSlot]
		townX := f32(town.x) + f32(buildingWidth)*0.5
		townY := f32(town.y) + f32(buildingHeight)*0.5
		dx := WorldShortestWrappedDelta(townX-unitX, worldWidth)
		dy := WorldShortestWrappedDelta(townY-unitY, worldHeight)
		distance := math.sqrt(dx*dx + dy*dy)
		weights[townSlot] = 1.0 / (1.0 + distance)
		totalWeight += weights[townSlot]
	}
	if totalWeight == 0 do return -1

	roll := WorldNoiseHash(unitSlot, destroyedBuildingSlot, w.navigationRevision+u64(kingdomSlot)*101)*totalWeight
	lastTown := -1
	for townSlot in 0..<TOWN_CAPACITY {
		if !w.kingdoms[kingdomSlot].townUsed[townSlot] do continue
		lastTown = townSlot
		if roll < weights[townSlot] do return townSlot
		roll -= weights[townSlot]
	}
	return lastTown
}

KingdomAbsorb :: proc(w: ^World, defeated, destroyer, capitalTown, capitalBuilding: int) -> bool {
	if defeated < 0 || defeated >= KINGDOMS_CAPACITY || !w.kingdomUsed[defeated] ||
		destroyer < 0 || destroyer >= KINGDOMS_CAPACITY || !w.kingdomUsed[destroyer] ||
		defeated == destroyer {
		return false
	}

	KingdomEndWar(w, defeated)
	CombatSiteKingdomClear(w, defeated)

	townMapping: [TOWN_CAPACITY]int
	reserved: [TOWN_CAPACITY]bool
	for townSlot in 0..<TOWN_CAPACITY {
		townMapping[townSlot] = -1
	}

	for townSlot in 0..<TOWN_CAPACITY {
		if !w.kingdoms[defeated].townUsed[townSlot] || townSlot == capitalTown do continue
		newSlot := -1
		for candidate in 0..<TOWN_CAPACITY {
			if !w.kingdoms[destroyer].townUsed[candidate] && !reserved[candidate] {
				newSlot = candidate
				break
			}
		}
		if newSlot < 0 do return false
		townMapping[townSlot] = newSlot
		reserved[newSlot] = true
	}

	for oldSlot in 0..<TOWN_CAPACITY {
		newSlot := townMapping[oldSlot]
		if newSlot < 0 do continue
		w.kingdoms[destroyer].towns[newSlot] = w.kingdoms[defeated].towns[oldSlot]
		w.kingdoms[destroyer].townUsed[newSlot] = true
	}

	for unitSlot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[unitSlot] || w.units[unitSlot].kingdome != defeated do continue
		oldTown := w.units[unitSlot].town
		UnitResetState(w, unitSlot)
		w.units[unitSlot].kingdome = destroyer
		if oldTown == capitalTown {
			newTown := KingdomChooseTownForUnit(w, destroyer, unitSlot, capitalBuilding)
			w.units[unitSlot].town = newTown
			if newTown >= 0 {
				w.kingdoms[destroyer].towns[newTown].citizens += 1
			}
		} else if oldTown >= 0 && oldTown < TOWN_CAPACITY {
			w.units[unitSlot].town = townMapping[oldTown]
		} else {
			w.units[unitSlot].town = -1
		}
	}

	for buildingSlot in 0..<BUILDING_CAPACITY {
		if buildingSlot == capitalBuilding || !w.buildingUsed[buildingSlot] ||
			w.buildings[buildingSlot].kingdom != defeated {
			continue
		}
		oldTown := w.buildings[buildingSlot].town
		w.buildings[buildingSlot].kingdom = destroyer
		if oldTown >= 0 && oldTown < TOWN_CAPACITY {
			w.buildings[buildingSlot].town = townMapping[oldTown]
		} else {
			w.buildings[buildingSlot].town = -1
		}
	}

	for townSlot in 0..<TOWN_CAPACITY {
		w.kingdoms[defeated].townUsed[townSlot] = false
		w.kingdoms[defeated].towns[townSlot].citizens = 0
	}
	w.kingdoms[defeated].capitalSlot = -1
	w.kingdomUsed[defeated] = false
	WorldConstructionChanged(w)
	return true
}
