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
TOWN_FOUNDING_WOOD :: 50
TOWN_FOUNDING_WOOD_PER_TOWN :: 25
TOWN_FOUNDING_MIN_CITIZENS :: 8
TOWN_FOUNDING_MIN_DISTANCE :: 20
TOWN_FOUNDING_SETTLERS :: 5
// Extra wood kept in reserve after a charter so the next house or road does not
// leave the town unable to expand again.
TOWN_FOUNDING_WOOD_BUFFER :: 12

// Growth eras. Each era gives a larger cohort with a longer interval, so the
// number of arrival events falls while total throughput keeps rising.
GrowthEra :: struct {
	threshold: int,
	batch:     int,
	interval:  f32,
}

TOWN_ERAS := [6]GrowthEra{
	{threshold = 0, batch = 1, interval = 12},
	{threshold = 18, batch = 5, interval = 30},
	{threshold = 45, batch = 20, interval = 60},
	{threshold = 100, batch = 60, interval = 105},
	{threshold = 200, batch = 150, interval = 150},
	{threshold = 380, batch = 300, interval = 180},
}

// Milestone rewards are chosen per town, one tier at a time. There are five
// reward tiers, one for every era transition.
TOWN_MILESTONE_TIER_COUNT :: 5

// Share of a town's warriors that always stays home to defend it. The rest
// is split between the town's attack and defend orders.
TOWN_GARRISON_RATIO :: 0.5

Kingdom :: struct {
	name: Name,
	culture: TownCulture,
	capitalSlot: int,
	towns: #soa [TOWN_CAPACITY]Town,
	townUsed: [TOWN_CAPACITY]bool,
	kingdomWar: [KINGDOMS_CAPACITY]bool,
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
			unlocks = {.SiegeWorkshop, .Cannon},
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
	kind:      BuildingKind,
	x, y:      int,
	paid:      f32,
	settlers:  int,
	clearWork: f32,
	buildWork: f32,
}

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
	construction: ConstructionSite,
	constructionActive: bool,
	builders, waterCollectors, farmers, villagers: int,
	homes, farmlands: int,
	farmlandOutput: f32,
	foodPotential, waterPotential: f32,
	waterAccess: f32,
	waterAccessTerrainRevision: u64,
	waterAccessCached: bool,
	foodShortage, waterShortage: f32,
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
	conversions: [MAX_CONVERSION_JOBS]ConversionJob,
	conversionCount: int,
	attackOrders: [KINGDOMS_CAPACITY][TOWN_CAPACITY]bool,
	defendOrders: [KINGDOMS_CAPACITY][TOWN_CAPACITY]bool,
	attackedBy: [KINGDOMS_CAPACITY][TOWN_CAPACITY]bool,
	defendedBy: [KINGDOMS_CAPACITY][TOWN_CAPACITY]bool,
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

// Shared town setup for the initial kingdom spawn and for founded towns.
TownInitialize :: proc(w: ^World, kingdom_slot, town_slot, hall_slot, x, y: int, starting_wood: f32) {
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	town^ = Town{
		x = x,
		y = y,
		hallSlot = hall_slot,
		wood = starting_wood,
		areaRadius = TOWN_START_AREA_RADIUS,
		unlockedBuildings = TOWN_BASE_UNLOCKED_BUILDINGS,
		unlockedUnits = TOWN_BASE_UNLOCKED_UNITS,
	}
	for &slot in town.buildingSlots do slot = -1
	town.buildingSlots[.TownHall] = hall_slot
	town.buildingCounts[.TownHall] = 1
	town.growthCooldown = TOWN_ERAS[0].interval
	town.growthInterval = TOWN_ERAS[0].interval
	town.growthBatch = TOWN_ERAS[0].batch
	town.growthRate = f32(town.growthBatch)/town.growthInterval
	town.growthSpeed = 1
	NameTownAssign(w, kingdom_slot, town_slot)
}

TownEra :: proc(w: ^World, kingdom_slot, town_slot: int) -> int {
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	return clamp(town.milestonesEarned, 0, len(TOWN_ERAS)-1)
}

TownBaseBatch :: proc(w: ^World, kingdom_slot, town_slot: int) -> int {
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	return TOWN_ERAS[TownEra(w, kingdom_slot, town_slot)].batch+town.growthBatchBonus
}

// Every live District Hall adds a share of the merged base batch. Destroying a
// hall removes its bonus immediately; the merged population and district area
// are unaffected.
TownEffectiveBatch :: proc(w: ^World, kingdom_slot, town_slot: int) -> int {
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	base := f32(TownBaseBatch(w, kingdom_slot, town_slot))
	halls := f32(town.buildingCounts[.DistrictHall])
	return max(1, int(math.round(base*(1+TOWN_DISTRICT_GROWTH_BONUS*halls))))
}

KingdomFreeTownSlot :: proc(w: ^World, kingdom_slot: int) -> int {
	if kingdom_slot < 0 || kingdom_slot >= KINGDOMS_CAPACITY || !w.kingdomUsed[kingdom_slot] {
		return -1
	}
	for town_slot in 0..<TOWN_CAPACITY {
		if !w.kingdoms[kingdom_slot].townUsed[town_slot] do return town_slot
	}
	return -1
}

KingdomTownCount :: proc(w: ^World, kingdom_slot: int) -> int {
	if kingdom_slot < 0 || kingdom_slot >= KINGDOMS_CAPACITY || !w.kingdomUsed[kingdom_slot] {
		return 0
	}
	count := 0
	for town_slot in 0..<TOWN_CAPACITY {
		if w.kingdoms[kingdom_slot].townUsed[town_slot] do count += 1
	}
	return count
}

// The first charter costs the base price; every town already owned beyond that
// adds a fixed increment, so wide expansion gets steadily more expensive.
TownFoundingWoodCost :: proc(w: ^World, kingdom_slot: int) -> f32 {
	towns := max(KingdomTownCount(w, kingdom_slot)-1, 0)
	return f32(TOWN_FOUNDING_WOOD+TOWN_FOUNDING_WOOD_PER_TOWN*towns)
}

// Builders stop chopping at a routine stockpile, but expansion needs a much
// larger reserve. While the kingdom still has room for another town, gathering
// continues until it can pay for a charter plus a small buffer.
TownWoodGatherTarget :: proc(w: ^World, kingdom_slot, town_slot: int) -> f32 {
	target: f32 = TOWN_WOOD_TARGET
	if KingdomFreeTownSlot(w, kingdom_slot) >= 0 {
		target = max(target, TownFoundingWoodCost(w, kingdom_slot)+TOWN_FOUNDING_WOOD_BUFFER)
	}

	// Era-5 towns need a real stockpile to pay the fusion sink. Builders keep
	// chopping until the next fusion is affordable plus a small buffer.
	if TownEra(w, kingdom_slot, town_slot) >= TOWN_FUSION_ERA {
		town := &w.kingdoms[kingdom_slot].towns[town_slot]
		cost := TOWN_FUSION_WOOD_BASE+TOWN_FUSION_WOOD_PER_DISTRICT*town.districtCount
		target = max(target, f32(cost+TOWN_FUSION_WOOD_BUFFER))
	}
	return target
}

// A new town is founded when its hall finishes construction. The hall was
// already paid for by the mother town, so it is spawned directly into the new
// town slot.
TownFound :: proc(w: ^World, kingdom_slot, x, y, settlers: int) -> bool {
	if kingdom_slot < 0 || kingdom_slot >= KINGDOMS_CAPACITY || !w.kingdomUsed[kingdom_slot] {
		return false
	}
	town_slot := KingdomFreeTownSlot(w, kingdom_slot)
	if town_slot < 0 do return false

	hall_slot, ok := BuildingSpawn(w, x, y, TownHall{}, kingdom_slot, town_slot)
	if !ok do return false

	TownInitialize(w, kingdom_slot, town_slot, hall_slot, x, y, 0)
	w.kingdoms[kingdom_slot].townUsed[town_slot] = true
	if kingdom_slot == w.observerKingdom {
		WorldAlertAdd(w, .TownFounded, kingdom_slot, town_slot, -1, f32(x), f32(y))
	}

	// The settlers were taken from the mother town when the charter was paid for.
	// The builder that raised the hall stays behind and gets the new town going.
	for _ in 0..<settlers {
		TownSpawnCitizen(w, kingdom_slot, town_slot, Villager{})
	}
	TownSpawnCitizen(w, kingdom_slot, town_slot, Builder{})
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
TownFoundingFailure :: proc(w: ^World, kingdom_slot, town_slot, x, y: int) -> PlacementFailure {
	if !WorldTownExists(w, kingdom_slot, town_slot) do return .NoTown
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	if town.constructionActive && town.construction.kind == .TownHall do return .AlreadyFounding
	if kingdom_slot == w.observerKingdom {
		width, height := BuildingTileSize(TownHall{})
		if !FogRectExplored(w, x, y, width, height) do return .Unexplored
	}
	if !WorldBuildingValid(w, x, y, TownHall{}) do return .InvalidTerrain
	if CombatSiteOverlaps(w, x, y, .TownHall) do return .CombatSiteOverlap
	if TownFoundingOverlapsOtherConstruction(w, kingdom_slot, town_slot, x, y) {
		return .ConstructionOverlap
	}
	if TownFoundingTooClose(w, x, y) do return .TooClose
	return .None
}

TownFoundingOverlapsOtherConstruction :: proc(w: ^World, source_kingdom, source_town, x, y: int) -> bool {
	width, height := BuildingTileSize(TownHall{})
	for kingdom_slot in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[kingdom_slot] do continue
		for town_slot in 0..<TOWN_CAPACITY {
			if !w.kingdoms[kingdom_slot].townUsed[town_slot] do continue
			if kingdom_slot == source_kingdom && town_slot == source_town do continue
			town := &w.kingdoms[kingdom_slot].towns[town_slot]
			if !town.constructionActive do continue
			site := town.construction
			other_width, other_height := BuildingTileSize(BuildingTypeFromKind(site.kind))
			if x < site.x+other_width && site.x < x+width &&
				y < site.y+other_height && site.y < y+height {
				return true
			}
		}
	}
	return false
}

TownFoundingTooClose :: proc(w: ^World, x, y: int) -> bool {
	hall_width, hall_height := BuildingTileSize(TownHall{})
	center_x := f32(x)+f32(hall_width)*0.5
	center_y := f32(y)+f32(hall_height)*0.5
	world_width := f32(w.maxX)
	world_height := f32(w.maxY)
	min_distance := f32(TOWN_FOUNDING_MIN_DISTANCE)

	for kingdom_slot in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[kingdom_slot] do continue
		for town_slot in 0..<TOWN_CAPACITY {
			if !w.kingdoms[kingdom_slot].townUsed[town_slot] do continue
			hall_slot := TownHallSlot(w, kingdom_slot, town_slot)
			if hall_slot < 0 do continue
			other_width, other_height := BuildingTileSize(w.buildings[hall_slot].type)
			other_x := f32(w.buildings.x[hall_slot])+f32(other_width)*0.5
			other_y := f32(w.buildings.y[hall_slot])+f32(other_height)*0.5
			delta_x := WorldShortestWrappedDelta(center_x-other_x, world_width)
			delta_y := WorldShortestWrappedDelta(center_y-other_y, world_height)
			if delta_x*delta_x+delta_y*delta_y < min_distance*min_distance do return true
		}
	}
	return false
}

TownFoundingAccessPoint :: proc(w: ^World, x, y: int, unit_type: UnitType, unit_kingdom: int) -> (int, int, bool) {
	width, height := BuildingTileSize(TownHall{})
	world_width := int(w.maxX)
	world_height := int(w.maxY)
	if world_width <= 0 || world_height <= 0 do return 0, 0, false

	for radius in 1..=6 {
		inner_min_x := x-radius+1
		inner_max_x := x+width-1+radius-1
		inner_min_y := y-radius+1
		inner_max_y := y+height-1+radius-1
		for tile_x in x-radius ..= x+width-1+radius {
			for tile_y in y-radius ..= y+height-1+radius {
				if tile_x >= inner_min_x && tile_x <= inner_max_x &&
					tile_y >= inner_min_y && tile_y <= inner_max_y {
					continue
				}
				wrapped_x := WorldWrapCoordinate(tile_x, world_width)
				wrapped_y := WorldWrapCoordinate(tile_y, world_height)
				if !WorldTileWalkable(w, wrapped_x, wrapped_y, unit_type, unit_kingdom) do continue
				return wrapped_x, wrapped_y, true
			}
		}
	}
	return 0, 0, false
}

TownFoundingReachable :: proc(w: ^World, kingdom_slot, town_slot, x, y: int) -> bool {
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	outgoing := town.construction
	preempting := town.constructionActive
	// Validate the layout after preemption, without cancelling a valid order
	// when the proposed charter fails. Construction footprints cannot overlap.
	if preempting {
		BuildingReserveFootprint(w, outgoing.x, outgoing.y, BuildingTypeFromKind(outgoing.kind), false)
	}
	defer {
		if preempting {
			BuildingReserveFootprint(w, outgoing.x, outgoing.y, BuildingTypeFromKind(outgoing.kind))
		}
	}
	if !BuildingClearUnits(w, x, y, TownHall{}, false) do return false
	start_x, start_y, start_found := UnitFindTownReturnPoint(w, kingdom_slot, town_slot)
	if !start_found do return false
	width, height := BuildingTileSize(TownHall{})
	goal_x, goal_y, goal_found := BuildingFindWorkAccessPoint(w, x, y, width, height, Builder{}, kingdom_slot, start_x, start_y)
	if !goal_found do return false

	path: [dynamic]int
	defer delete(path)
	return AStar(w, Builder{}, kingdom_slot, start_x, start_y, goal_x, goal_y, &path)
}

// Player order: found a new town. The mother town pays the charter and its
// builders receive a town-hall construction site. An automatic construction is
// refunded and replaced, because a player order takes priority.
TownStartFounding :: proc(w: ^World, kingdom_slot, town_slot, x, y: int) -> bool {
	if TownFoundingFailure(w, kingdom_slot, town_slot, x, y) != .None do return false
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	cost := TownFoundingWoodCost(w, kingdom_slot)
	if town.wood < cost do return false
	if town.citizens < TOWN_FOUNDING_MIN_CITIZENS do return false
	if TownUnitCount(w, kingdom_slot, town_slot, .Villager) < TOWN_FOUNDING_SETTLERS {
		return false
	}
	if TownUnitCount(w, kingdom_slot, town_slot, .Builder) <= 0 do return false
	if KingdomFreeTownSlot(w, kingdom_slot) < 0 do return false
	if !TownFoundingReachable(w, kingdom_slot, town_slot, x, y) do return false

	if town.constructionActive do TownConstructionPreempt(w, kingdom_slot, town_slot)

	town.wood -= cost
	settlers := TownTakeVillagers(w, kingdom_slot, town_slot, TOWN_FOUNDING_SETTLERS)
	if settlers < TOWN_FOUNDING_SETTLERS {
		town.wood += cost
		for _ in 0..<settlers do TownSpawnCitizen(w, kingdom_slot, town_slot, Villager{})
		return false
	}
	town.construction = ConstructionSite{
		kind = .TownHall,
		x = x,
		y = y,
		paid = cost,
		settlers = settlers,
	}
	town.constructionActive = true
	BuildingClearUnits(w, x, y, TownHall{}, true)
	WorldConstructionChanged(w)
	return true
}

// Squared distance in tiles from a hall footprint (0 on the hall).
TownHallDistanceSquared :: proc(hall_x, hall_y, x, y: int) -> int {
	hall_width, hall_height := BuildingTileSize(TownHall{})
	delta_x := max(max(hall_x-x, 0), x-(hall_x+hall_width-1))
	delta_y := max(max(hall_y-y, 0), y-(hall_y+hall_height-1))
	return delta_x*delta_x+delta_y*delta_y
}

TownAreaCircleCount :: proc(w: ^World, kingdom_slot, town_slot: int) -> int {
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	return 1+town.districtCount
}

TownAreaCircle :: proc(w: ^World, kingdom_slot, town_slot, index: int) -> (x, y, radius: int) {
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	if index <= 0 do return town.x, town.y, town.areaRadius
	district := &town.districts[index-1]
	return district.x, district.y, district.radius
}

// Squared distance to the nearest circle of the compound town area.
TownTileAreaDistanceSquared :: proc(w: ^World, kingdom_slot, town_slot, x, y: int) -> int {
	if !WorldTownExists(w, kingdom_slot, town_slot) do return max(int)
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	best := TownHallDistanceSquared(town.x, town.y, x, y)
	for index in 0..<town.districtCount {
		distance := TownHallDistanceSquared(town.districts[index].x, town.districts[index].y, x, y)
		if distance < best do best = distance
	}
	return best
}

TownPointInArea :: proc(w: ^World, kingdom_slot, town_slot, x, y: int) -> bool {
	if !WorldTownExists(w, kingdom_slot, town_slot) do return false
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	if TownHallDistanceSquared(town.x, town.y, x, y) <= town.areaRadius*town.areaRadius do return true
	for index in 0..<town.districtCount {
		district := &town.districts[index]
		if TownHallDistanceSquared(district.x, district.y, x, y) <= district.radius*district.radius {
			return true
		}
	}
	return false
}

TownBuildingInArea :: proc(w: ^World, kingdom_slot, town_slot, x, y: int, type: BuildingType) -> bool {
	if !WorldTownExists(w, kingdom_slot, town_slot) do return false
	width, height := BuildingTileSize(type)
	if width <= 0 || height <= 0 do return false
	return TownPointInArea(w, kingdom_slot, town_slot, x, y) &&
		TownPointInArea(w, kingdom_slot, town_slot, x+width-1, y) &&
		TownPointInArea(w, kingdom_slot, town_slot, x, y+height-1) &&
		TownPointInArea(w, kingdom_slot, town_slot, x+width-1, y+height-1)
}

// Milestones grow every circle of a merged town together.
TownAreaExpand :: proc(w: ^World, kingdom_slot, town_slot, delta: int) {
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	town.areaRadius += delta
	for index in 0..<town.districtCount {
		town.districts[index].radius += delta
	}
}

TownAreaBounds :: proc(w: ^World, kingdom_slot, town_slot: int) -> (min_x, max_x, min_y, max_y: int) {
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	hall_width, hall_height := BuildingTileSize(TownHall{})
	min_x = town.x-town.areaRadius-1
	max_x = town.x+hall_width+town.areaRadius
	min_y = town.y-town.areaRadius-1
	max_y = town.y+hall_height+town.areaRadius
	for index in 0..<town.districtCount {
		district := &town.districts[index]
		min_x = min(min_x, district.x-district.radius-1)
		max_x = max(max_x, district.x+hall_width+district.radius)
		min_y = min(min_y, district.y-district.radius-1)
		max_y = max(max_y, district.y+hall_height+district.radius)
	}
	return
}

// Frontier test: any circle of either town touches or overlaps any circle of
// the other, including a one-tile tolerance for odd coastlines.
TownAreasTouch :: proc(w: ^World, kingdom_slot, town_a, town_b: int) -> bool {
	if !WorldTownExists(w, kingdom_slot, town_a) || !WorldTownExists(w, kingdom_slot, town_b) {
		return false
	}
	hall_width, _ := BuildingTileSize(TownHall{})
	for index_a in 0..<TownAreaCircleCount(w, kingdom_slot, town_a) {
		ax, ay, ar := TownAreaCircle(w, kingdom_slot, town_a, index_a)
		for index_b in 0..<TownAreaCircleCount(w, kingdom_slot, town_b) {
			bx, by, br := TownAreaCircle(w, kingdom_slot, town_b, index_b)
			dx := WorldShortestWrappedDelta(f32(ax-bx), f32(w.maxX))
			dy := WorldShortestWrappedDelta(f32(ay-by), f32(w.maxY))
			// Both circles are measured from their hall anchors, so add the two
			// half-footprints to the frontier tolerance.
			limit := f32(ar+br+hall_width+TOWN_FUSION_FRONTIER_SLACK)
			if dx*dx+dy*dy <= limit*limit do return true
		}
	}
	return false
}

TownFindBuilding :: proc(w: ^World, kingdom_slot, town_slot: int, kind: BuildingKind) -> int {
	if !WorldTownExists(w, kingdom_slot, town_slot) do return -1
	slot := w.kingdoms[kingdom_slot].towns[town_slot].buildingSlots[kind]
	if slot < 0 || slot >= BUILDING_CAPACITY || !w.buildingUsed[slot] do return -1
	if BuildingKindOf(w.buildings[slot].type) != kind do return -1
	if w.buildings[slot].kingdom != kingdom_slot || w.buildings[slot].town != town_slot {
		return -1
	}
	return slot
}

TownUnitAvailable :: proc(w: ^World, kingdom_slot, town_slot: int, kind: UnitKind) -> bool {
	if !TownUnitUnlocked(w, kingdom_slot, town_slot, kind) do return false
	return TownFindBuilding(w, kingdom_slot, town_slot, UnitTrainingBuildingKind(kind)) >= 0
}

TownUnitUnlocked :: proc(w: ^World, kingdom_slot, town_slot: int, kind: UnitKind) -> bool {
	if !WorldTownExists(w, kingdom_slot, town_slot) do return false
	return kind in w.kingdoms[kingdom_slot].towns[town_slot].unlockedUnits
}

TownUnitCount :: proc(w: ^World, kingdom_slot, town_slot: int, kind: UnitKind) -> int {
	if !WorldTownExists(w, kingdom_slot, town_slot) do return 0
	count := 0
	for unit_slot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[unit_slot] do continue
		if w.units[unit_slot].kingdome != kingdom_slot || w.units[unit_slot].town != town_slot {
			continue
		}
		if UnitKindOf(w.units[unit_slot].type) == kind do count += 1
	}
	return count
}

// Moves up to count villagers out of a town. Villagers that are not already
// retraining are taken first, so queued jobs keep their workers when possible.
TownTakeVillagers :: proc(w: ^World, kingdom_slot, town_slot, count: int) -> int {
	taken := 0
	for pass in 0..<2 {
		for unit_slot in 0..<UNIT_CAPACITY {
			if taken >= count do return taken
			if !w.unitUsed[unit_slot] do continue
			unit := &w.units[unit_slot]
			if unit.kingdome != kingdom_slot || unit.town != town_slot do continue
			if UnitKindOf(unit.type) != .Villager do continue
			_, converting := unit.state.(StateConverting)
			if (pass == 0) == converting do continue
			if UnitDespawn(w, unit_slot) do taken += 1
		}
	}
	return taken
}

// Conversions always pass through villagers: A -> Villager -> B.
TownAddConversion :: proc(w: ^World, kingdom_slot, town_slot: int, from, to: UnitKind, count: int) -> bool {
	if count <= 0 || from == to do return false
	if !WorldTownExists(w, kingdom_slot, town_slot) do return false
	if from != .Villager && to != .Villager do return false
	if !TownUnitAvailable(w, kingdom_slot, town_slot, to) do return false

	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	for job_index in 0..<town.conversionCount {
		job := &town.conversions[job_index]
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
TownRemoveConversion :: proc(w: ^World, kingdom_slot, town_slot: int, from, to: UnitKind, count: int) -> bool {
	if count <= 0 || !WorldTownExists(w, kingdom_slot, town_slot) do return false
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	for job_index in 0..<town.conversionCount {
		job := &town.conversions[job_index]
		if job.from != from || job.to != to do continue
		removed := min(count, max(0, job.remaining-job.assigned))
		job.remaining -= removed
		for unit_slot in 0..<UNIT_CAPACITY {
			if removed >= count do break
			if !w.unitUsed[unit_slot] do continue
			unit := &w.units[unit_slot]
			if unit.kingdome != kingdom_slot || unit.town != town_slot do continue
			if UnitKindOf(unit.type) != from do continue
			state, converting := unit.state.(StateConverting)
			if !converting || state.to != to do continue
			UnitConversionCancel(w, unit_slot)
			job.remaining -= 1
			removed += 1
		}
		if job.remaining <= 0 {
			for i in job_index..<town.conversionCount-1 {
				town.conversions[i] = town.conversions[i+1]
			}
			town.conversionCount -= 1
		}
		return removed > 0
	}
	return false
}

TownConversionsClear :: proc(w: ^World, kingdom_slot, town_slot: int) {
	if !WorldTownExists(w, kingdom_slot, town_slot) do return
	w.kingdoms[kingdom_slot].towns[town_slot].conversionCount = 0
}

// Eras advance automatically from population. Rewards are banked: a town can
// cross several thresholds and choose them later without slowing its growth.
TownMilestoneCheck :: proc(w: ^World, kingdom_slot, town_slot: int) {
	if !WorldTownExists(w, kingdom_slot, town_slot) do return
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	for town.milestonesEarned < TOWN_MILESTONE_TIER_COUNT {
		next := TOWN_ERAS[town.milestonesEarned+1].threshold
		if town.citizens < next do break
		town.milestonesEarned += 1
		if kingdom_slot == w.observerKingdom {
			WorldAlertAdd(w, .Milestone, kingdom_slot, town_slot, -1, f32(town.x), f32(town.y))
		}
	}
	town.milestonePending = town.milestonesEarned > town.milestonesChosen
}

TownChooseMilestone :: proc(w: ^World, kingdom_slot, town_slot, option: int) -> bool {
	if !WorldTownExists(w, kingdom_slot, town_slot) do return false
	if option != 0 && option != 1 do return false
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	if town.milestonesChosen >= TOWN_MILESTONE_TIER_COUNT ||
		town.milestonesChosen >= town.milestonesEarned {
		return false
	}

	choice := TOWN_ERA_REWARDS[town.milestonesChosen][option]
	town.unlockedBuildings |= choice.unlocks
	town.unlockedUnits |= choice.units
	TownAreaExpand(w, kingdom_slot, town_slot, TOWN_AREA_EXPANSION)
	town.milestonesChosen += 1
	town.milestonePending = town.milestonesEarned > town.milestonesChosen
	return true
}

TownMilestoneOption :: proc(w: ^World, kingdom_slot, town_slot, option: int) -> (MilestoneOption, bool) {
	if !WorldTownExists(w, kingdom_slot, town_slot) do return {}, false
	if option != 0 && option != 1 do return {}, false
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
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

TownFusionCost :: proc(w: ^World, kingdom_slot, host_slot: int) -> f32 {
	host := &w.kingdoms[kingdom_slot].towns[host_slot]
	return f32(TOWN_FUSION_WOOD_BASE+TOWN_FUSION_WOOD_PER_DISTRICT*host.districtCount)
}

TownFusionNewConversionSlots :: proc(w: ^World, kingdom_slot, host_slot, guest_slot: int) -> int {
	host := &w.kingdoms[kingdom_slot].towns[host_slot]
	guest := &w.kingdoms[kingdom_slot].towns[guest_slot]
	needed := 0
	for guest_index in 0..<guest.conversionCount {
		guest_job := guest.conversions[guest_index]
		found := false
		for host_index in 0..<host.conversionCount {
			host_job := host.conversions[host_index]
			if host_job.from == guest_job.from && host_job.to == guest_job.to {
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
	kingdom_slot, host_slot, target_kingdom, guest_slot: int,
) -> FusionFailure {
	if !WorldTownExists(w, kingdom_slot, host_slot) do return .NoTown
	if target_kingdom != kingdom_slot do return .DifferentKingdom
	if !WorldTownExists(w, target_kingdom, guest_slot) do return .NoTown
	if host_slot == guest_slot do return .SameTown

	host := &w.kingdoms[kingdom_slot].towns[host_slot]
	guest := &w.kingdoms[kingdom_slot].towns[guest_slot]
	if TownEra(w, kingdom_slot, host_slot) < TOWN_FUSION_ERA ||
		TownEra(w, kingdom_slot, guest_slot) < TOWN_FUSION_ERA {
		return .NotEraFive
	}
	if TownHallSlot(w, kingdom_slot, host_slot) < 0 ||
		TownHallSlot(w, kingdom_slot, guest_slot) < 0 {
		return .NoHall
	}
	if !TownAreasTouch(w, kingdom_slot, host_slot, guest_slot) do return .NoFrontier
	if host.milestonesEarned != host.milestonesChosen ||
		guest.milestonesEarned != guest.milestonesChosen {
		return .PendingMilestone
	}
	if host.districtCount+1+guest.districtCount > MAX_TOWN_DISTRICTS do return .DistrictLimit
	if host.constructionActive && guest.constructionActive do return .ConstructionConflict
	if host.conversionCount+TownFusionNewConversionSlots(w, kingdom_slot, host_slot, guest_slot) >
		MAX_CONVERSION_JOBS {
		return .ConversionLimit
	}
	if host.wood < TownFusionCost(w, kingdom_slot, host_slot) do return .NoWood
	return .None
}

// Absorbs a frontier era-5 town into the initiating town. Buildings and units
// never move; only their town ownership and the compound area change.
TownFuse :: proc(
	w: ^World,
	kingdom_slot, host_slot, target_kingdom, guest_slot: int,
) -> bool {
	if TownFusionFailure(w, kingdom_slot, host_slot, target_kingdom, guest_slot) != .None {
		return false
	}

	host := &w.kingdoms[kingdom_slot].towns[host_slot]
	guest := &w.kingdoms[kingdom_slot].towns[guest_slot]
	cost := TownFusionCost(w, kingdom_slot, host_slot)

	guest_name := guest.name
	guest_x, guest_y := guest.x, guest.y
	guest_radius := guest.areaRadius
	guest_districts := guest.districts
	guest_district_count := guest.districtCount
	guest_hall := guest.hallSlot

	// Reassign every guest building. The old hall becomes the district hall in
	// place, so its footprint and tile indices stay valid.
	for building_slot in 0..<BUILDING_CAPACITY {
		if !w.buildingUsed[building_slot] do continue
		if w.buildings[building_slot].kingdom != kingdom_slot ||
			w.buildings[building_slot].town != guest_slot {
			continue
		}
		w.buildings[building_slot].town = host_slot
		if building_slot == guest_hall {
			w.buildings[building_slot].type = DistrictHall{}
			w.buildings[building_slot].health = BuildingDefaultHealth(DistrictHall{})
			w.buildings[building_slot].cooldown = 0
			w.buildings[building_slot].homeResident = 0
		}
	}

	for unit_slot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[unit_slot] do continue
		if w.units[unit_slot].kingdome != kingdom_slot || w.units[unit_slot].town != guest_slot {
			continue
		}
		w.units[unit_slot].town = host_slot
		// Paths were built against the old town's flow field; recompute them
		// against the merged town on the next update.
		w.units[unit_slot].pathReady = false
	}
	host.citizens += guest.citizens
	guest.citizens = 0

	for guest_index in 0..<guest.conversionCount {
		job := guest.conversions[guest_index]
		merged := false
		for host_index in 0..<host.conversionCount {
			host_job := &host.conversions[host_index]
			if host_job.from != job.from || host_job.to != job.to do continue
			host_job.remaining += job.remaining
			host_job.assigned += job.assigned
			merged = true
			break
		}
		if !merged {
			host.conversions[host.conversionCount] = job
			host.conversionCount += 1
		}
	}

	if guest.constructionActive {
		host.construction = guest.construction
		host.constructionActive = true
		host.constructionProgress = guest.constructionProgress
	}

	host.wood += guest.wood
	host.wood -= cost
	host.unlockedBuildings |= guest.unlockedBuildings
	host.unlockedUnits |= guest.unlockedUnits

	// Merged population keeps the combined base batch; each transferred District
	// Hall adds its 10% share on top.
	host.growthBatchBonus += TownBaseBatch(w, kingdom_slot, guest_slot)
	host.growthCooldown = min(host.growthCooldown, guest.growthCooldown)
	host.growthPending += guest.growthPending
	host.growthInterval = TOWN_ERAS[TOWN_FUSION_ERA].interval
	host.growthBatch = TownEffectiveBatch(w, kingdom_slot, host_slot)
	host.growthRate = f32(host.growthBatch)/host.growthInterval

	district := TownDistrict{x = guest_x, y = guest_y, radius = guest_radius}
	NameDistrictAssign(&district.name, &guest_name)
	host.districts[host.districtCount] = district
	host.districtCount += 1
	for district_index in 0..<guest_district_count {
		host.districts[host.districtCount] = guest_districts[district_index]
		host.districtCount += 1
	}
	host.fusionCount += 1
	host.alarmActive = host.alarmActive || guest.alarmActive

	if w.kingdoms[kingdom_slot].capitalSlot == guest_slot ||
		w.kingdoms[kingdom_slot].capitalSlot == host_slot {
		w.kingdoms[kingdom_slot].capitalSlot = host_slot
	}

	if kingdom_slot == w.observerKingdom {
		WorldAlertAdd(w, .TownFused, kingdom_slot, host_slot, guest_slot, f32(guest_x), f32(guest_y))
	}

	TownFusionRedirectOrders(w, kingdom_slot, host_slot, guest_slot)
	w.kingdoms[kingdom_slot].townUsed[guest_slot] = false

	for other_kingdom in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[other_kingdom] do continue
		for other_town in 0..<TOWN_CAPACITY {
			if !w.kingdoms[other_kingdom].townUsed[other_town] do continue
			TownOrdersRebuild(w, other_kingdom, other_town)
		}
	}

	w.kingdoms[kingdom_slot].towns[guest_slot] = Town{}
	WorldConstructionChanged(w)
	w.navigationRevision += 1
	return true
}

TownFusionRedirectOrders :: proc(w: ^World, kingdom_slot, host_slot, guest_slot: int) {
	host := &w.kingdoms[kingdom_slot].towns[host_slot]
	guest := &w.kingdoms[kingdom_slot].towns[guest_slot]

	// Redirect every order that targeted the guest to the host.
	for other_kingdom in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[other_kingdom] do continue
		for other_town in 0..<TOWN_CAPACITY {
			if !w.kingdoms[other_kingdom].townUsed[other_town] do continue
			// The guest's own orders are merged below; the host never needs an
			// order pointing at itself.
			if other_kingdom == kingdom_slot && (other_town == host_slot || other_town == guest_slot) {
				continue
			}
			other := &w.kingdoms[other_kingdom].towns[other_town]
			if other.attackOrders[kingdom_slot][guest_slot] {
				other.attackOrders[kingdom_slot][guest_slot] = false
				other.attackOrders[kingdom_slot][host_slot] = true
				host.attackedBy[other_kingdom][other_town] = true
			}
			if other.defendOrders[kingdom_slot][guest_slot] {
				other.defendOrders[kingdom_slot][guest_slot] = false
				other.defendOrders[kingdom_slot][host_slot] = true
				host.defendedBy[other_kingdom][other_town] = true
			}
		}
	}

	// The guest's own outgoing orders become the host's.
	for other_kingdom in 0..<KINGDOMS_CAPACITY {
		for other_town in 0..<TOWN_CAPACITY {
			if guest.attackOrders[other_kingdom][other_town] {
				host.attackOrders[other_kingdom][other_town] = true
				if WorldTownExists(w, other_kingdom, other_town) {
					w.kingdoms[other_kingdom].towns[other_town].attackedBy[kingdom_slot][host_slot] = true
				}
			}
			if guest.defendOrders[other_kingdom][other_town] {
				host.defendOrders[other_kingdom][other_town] = true
				if WorldTownExists(w, other_kingdom, other_town) {
					w.kingdoms[other_kingdom].towns[other_town].defendedBy[kingdom_slot][host_slot] = true
				}
			}
		}
	}

	for other_kingdom in 0..<KINGDOMS_CAPACITY {
		for other_town in 0..<TOWN_CAPACITY {
			if guest.attackedBy[other_kingdom][other_town] {
				host.attackedBy[other_kingdom][other_town] = true
			}
			if guest.defendedBy[other_kingdom][other_town] {
				host.defendedBy[other_kingdom][other_town] = true
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
	if !KingdomsMet(w, kingdomSlotA, kingdomSlotB) do return false
	if !WorldTownExists(w, kingdomSlotA, townSlotA) || !WorldTownExists(w, kingdomSlotB, townSlotB) {
		return false
	}
	if w.kingdoms[kingdomSlotA].towns[townSlotA].attackOrders[kingdomSlotB][townSlotB] do return false

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
KingdomBreakDefenses :: proc(w: ^World, kingdom_a, kingdom_b: int) {
	for defender_kingdom in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[defender_kingdom] do continue
		protected_kingdom := -1
		if defender_kingdom == kingdom_a {
			protected_kingdom = kingdom_b
		} else if defender_kingdom == kingdom_b {
			protected_kingdom = kingdom_a
		} else {
			continue
		}
		for defender_town in 0..<TOWN_CAPACITY {
			if !w.kingdoms[defender_kingdom].townUsed[defender_town] do continue
			town := &w.kingdoms[defender_kingdom].towns[defender_town]
			changed := false
			for protected_town in 0..<TOWN_CAPACITY {
				if !town.defendOrders[protected_kingdom][protected_town] do continue
				town.defendOrders[protected_kingdom][protected_town] = false
				if WorldTownExists(w, protected_kingdom, protected_town) {
					w.kingdoms[protected_kingdom].towns[protected_town].defendedBy[defender_kingdom][defender_town] = false
				}
				changed = true
			}
			if changed do TownOrdersRebuild(w, defender_kingdom, defender_town)
		}
	}
}

// Contact is mutual and persistent, unlike the observer's terrain memory.
// Neither declaring war nor spectator visibility may manufacture contact.
KingdomsMet :: proc(w: ^World, kingdom_a, kingdom_b: int) -> bool {
	if kingdom_a < 0 || kingdom_a >= KINGDOMS_CAPACITY ||
		kingdom_b < 0 || kingdom_b >= KINGDOMS_CAPACITY || kingdom_a == kingdom_b {
		return false
	}
	return w.kingdomUsed[kingdom_a] && w.kingdomUsed[kingdom_b] &&
		w.fog.contacts[kingdom_a][kingdom_b] && w.fog.contacts[kingdom_b][kingdom_a]
}

KingdomMeet :: proc(w: ^World, kingdom_a, kingdom_b: int) {
	if kingdom_a < 0 || kingdom_a >= KINGDOMS_CAPACITY ||
		kingdom_b < 0 || kingdom_b >= KINGDOMS_CAPACITY || kingdom_a == kingdom_b {
		return
	}
	if !w.kingdomUsed[kingdom_a] || !w.kingdomUsed[kingdom_b] do return
	w.fog.contacts[kingdom_a][kingdom_b] = true
	w.fog.contacts[kingdom_b][kingdom_a] = true
}

KingdomCanDeclareWar :: proc(w: ^World, kingdom_a, kingdom_b: int) -> bool {
	return KingdomsMet(w, kingdom_a, kingdom_b) && !KingdomAtWar(w, kingdom_a, kingdom_b)
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
KingdomMakePeace :: proc(w: ^World, kingdom_a, kingdom_b: int) {
	if kingdom_a < 0 || kingdom_a >= KINGDOMS_CAPACITY ||
		kingdom_b < 0 || kingdom_b >= KINGDOMS_CAPACITY || kingdom_a == kingdom_b {
		return
	}
	if !w.kingdomUsed[kingdom_a] || !w.kingdomUsed[kingdom_b] do return
	if !KingdomAtWar(w, kingdom_a, kingdom_b) do return

	w.kingdoms[kingdom_a].kingdomWar[kingdom_b] = false
	w.kingdoms[kingdom_b].kingdomWar[kingdom_a] = false

	for pair in 0..<2 {
		attacker := kingdom_a
		defender := kingdom_b
		if pair == 1 {
			attacker = kingdom_b
			defender = kingdom_a
		}
		for town_slot in 0..<TOWN_CAPACITY {
			if !w.kingdoms[attacker].townUsed[town_slot] do continue
			town := &w.kingdoms[attacker].towns[town_slot]
			changed := false
			for target_town in 0..<TOWN_CAPACITY {
				if !town.attackOrders[defender][target_town] do continue
				town.attackOrders[defender][target_town] = false
				if WorldTownExists(w, defender, target_town) {
					w.kingdoms[defender].towns[target_town].attackedBy[attacker][town_slot] = false
				}
				changed = true
			}
			if changed do TownOrdersRebuild(w, attacker, town_slot)
		}
	}

	if kingdom_a == w.observerKingdom {
		WorldAlertAdd(w, .PeaceMade, kingdom_a, -1, kingdom_b, 0, 0)
	} else if kingdom_b == w.observerKingdom {
		WorldAlertAdd(w, .PeaceMade, kingdom_b, -1, kingdom_a, 0, 0)
	}
}

KingdomAtWar :: proc(w: ^World, kingdomSlotA, kingdomSlotB: int) -> bool {
	if kingdomSlotA < 0 || kingdomSlotA >= KINGDOMS_CAPACITY ||
		kingdomSlotB < 0 || kingdomSlotB >= KINGDOMS_CAPACITY || kingdomSlotA == kingdomSlotB {
		return false
	}
	return w.kingdomUsed[kingdomSlotA] && w.kingdomUsed[kingdomSlotB] &&
		w.kingdoms[kingdomSlotA].kingdomWar[kingdomSlotB]
}


// Turns the sparse order matrices into a compact list the warrior update can
// index in constant time. Called only when orders change, never per tick.
TownOrdersRebuild :: proc(w: ^World, kingdom_slot, town_slot: int) {
	if !WorldTownExists(w, kingdom_slot, town_slot) do return
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	count := 0
	for kingdom_b in 0..<KINGDOMS_CAPACITY {
		for town_b in 0..<TOWN_CAPACITY {
			if !town.attackOrders[kingdom_b][town_b] do continue
			if !WorldTownExists(w, kingdom_b, town_b) || !KingdomAtWar(w, kingdom_slot, kingdom_b) {
				if WorldTownExists(w, kingdom_b, town_b) {
					w.kingdoms[kingdom_b].towns[town_b].attackedBy[kingdom_slot][town_slot] = false
				}
				town.attackOrders[kingdom_b][town_b] = false
				continue
			}
			if count >= TOWN_WARRIOR_ORDERS_CAPACITY {
				w.kingdoms[kingdom_b].towns[town_b].attackedBy[kingdom_slot][town_slot] = false
				town.attackOrders[kingdom_b][town_b] = false
				continue
			}
			town.orders[count] = TownAttackOrder{kingdom = kingdom_b, town = town_b}
			count += 1
		}
	}
	for protected_kingdom in 0..<KINGDOMS_CAPACITY {
		for protected_town in 0..<TOWN_CAPACITY {
			if !town.defendOrders[protected_kingdom][protected_town] do continue
			valid := WorldTownExists(w, protected_kingdom, protected_town) &&
				!(protected_kingdom == kingdom_slot && protected_town == town_slot) &&
				!KingdomAtWar(w, kingdom_slot, protected_kingdom)
			if !valid {
				if WorldTownExists(w, protected_kingdom, protected_town) {
					w.kingdoms[protected_kingdom].towns[protected_town].defendedBy[kingdom_slot][town_slot] = false
				}
				town.defendOrders[protected_kingdom][protected_town] = false
				continue
			}
			if count >= TOWN_WARRIOR_ORDERS_CAPACITY {
				w.kingdoms[protected_kingdom].towns[protected_town].defendedBy[kingdom_slot][town_slot] = false
				town.defendOrders[protected_kingdom][protected_town] = false
				continue
			}
			town.orders[count] = TownDefendOrder{kingdom = protected_kingdom, town = protected_town}
			count += 1
		}
	}
	town.orderCount = count
	town.orderRevision += 1
}

// Removes every order that mentions a town that no longer exists and clears
// the mirrors on both sides so no stale target survives.
TownOrdersClear :: proc(w: ^World, kingdom_slot, town_slot: int) {
	if !WorldTownExists(w, kingdom_slot, town_slot) do return
	town := &w.kingdoms[kingdom_slot].towns[town_slot]

	for kingdom_b in 0..<KINGDOMS_CAPACITY {
		for town_b in 0..<TOWN_CAPACITY {
			if !town.attackOrders[kingdom_b][town_b] do continue
			town.attackOrders[kingdom_b][town_b] = false
			if WorldTownExists(w, kingdom_b, town_b) {
				w.kingdoms[kingdom_b].towns[town_b].attackedBy[kingdom_slot][town_slot] = false
			}
		}
	}
	for kingdom_a in 0..<KINGDOMS_CAPACITY {
		for town_a in 0..<TOWN_CAPACITY {
			if !town.attackedBy[kingdom_a][town_a] do continue
			town.attackedBy[kingdom_a][town_a] = false
			if WorldTownExists(w, kingdom_a, town_a) {
				w.kingdoms[kingdom_a].towns[town_a].attackOrders[kingdom_slot][town_slot] = false
				TownOrdersRebuild(w, kingdom_a, town_a)
			}
		}
	}

	for protected_kingdom in 0..<KINGDOMS_CAPACITY {
		for protected_town in 0..<TOWN_CAPACITY {
			if !town.defendOrders[protected_kingdom][protected_town] do continue
			town.defendOrders[protected_kingdom][protected_town] = false
			if WorldTownExists(w, protected_kingdom, protected_town) {
				w.kingdoms[protected_kingdom].towns[protected_town].defendedBy[kingdom_slot][town_slot] = false
			}
		}
	}
	for defender_kingdom in 0..<KINGDOMS_CAPACITY {
		for defender_town in 0..<TOWN_CAPACITY {
			if !town.defendedBy[defender_kingdom][defender_town] do continue
			town.defendedBy[defender_kingdom][defender_town] = false
			if WorldTownExists(w, defender_kingdom, defender_town) {
				w.kingdoms[defender_kingdom].towns[defender_town].defendOrders[kingdom_slot][town_slot] = false
				TownOrdersRebuild(w, defender_kingdom, defender_town)
			}
		}
	}

	town.orderCount = 0
	town.orderRevision += 1
}

KingdomEndWar :: proc(w: ^World, kingdom_slot: int) {
	if kingdom_slot < 0 || kingdom_slot >= KINGDOMS_CAPACITY || !w.kingdomUsed[kingdom_slot] {
		return
	}

	for town_slot in 0..<TOWN_CAPACITY {
		if !w.kingdoms[kingdom_slot].townUsed[town_slot] do continue
		TownOrdersClear(w, kingdom_slot, town_slot)
		TownConversionsClear(w, kingdom_slot, town_slot)
	}

	for other in 0..<KINGDOMS_CAPACITY {
		w.kingdoms[kingdom_slot].kingdomWar[other] = false
		if other == kingdom_slot do continue
		w.kingdoms[other].kingdomWar[kingdom_slot] = false
		if !w.kingdomUsed[other] do continue
		for town_slot in 0..<TOWN_CAPACITY {
			if !w.kingdoms[other].townUsed[town_slot] do continue
			town := &w.kingdoms[other].towns[town_slot]
			changed := false
			for town_b in 0..<TOWN_CAPACITY {
				if town.attackOrders[kingdom_slot][town_b] {
					town.attackOrders[kingdom_slot][town_b] = false
					changed = true
				}
				if town.attackedBy[kingdom_slot][town_b] {
					town.attackedBy[kingdom_slot][town_b] = false
				}
			}
			if changed do TownOrdersRebuild(w, other, town_slot)
		}
	}
	w.kingdoms[kingdom_slot].kingdomWar[kingdom_slot] = false
}

TownHallSlot :: proc(w: ^World, kingdom_slot, town_slot: int) -> int {
	if !WorldTownExists(w, kingdom_slot, town_slot) do return -1
	slot := w.kingdoms[kingdom_slot].towns[town_slot].hallSlot
	if slot < 0 || slot >= BUILDING_CAPACITY || !w.buildingUsed[slot] do return -1
	if BuildingKindOf(w.buildings[slot].type) != .TownHall do return -1
	return slot
}

KingdomChooseTownForUnit :: proc(w: ^World, kingdom_slot, unit_slot, destroyed_building_slot: int) -> int {
	world_width := f32(w.maxX)
	world_height := f32(w.maxY)
	unit_x := WorldWrapPosition(w.units[unit_slot].x, world_width)
	unit_y := WorldWrapPosition(w.units[unit_slot].y, world_height)
	building_width, building_height := BuildingTileSize(TownHall{})

	weights: [TOWN_CAPACITY]f32
	total_weight: f32 = 0
	for town_slot in 0..<TOWN_CAPACITY {
		if !w.kingdoms[kingdom_slot].townUsed[town_slot] do continue
		town := w.kingdoms[kingdom_slot].towns[town_slot]
		town_x := f32(town.x) + f32(building_width)*0.5
		town_y := f32(town.y) + f32(building_height)*0.5
		dx := WorldShortestWrappedDelta(town_x-unit_x, world_width)
		dy := WorldShortestWrappedDelta(town_y-unit_y, world_height)
		distance := math.sqrt(dx*dx + dy*dy)
		weights[town_slot] = 1.0 / (1.0 + distance)
		total_weight += weights[town_slot]
	}
	if total_weight == 0 do return -1

	roll := WorldNoiseHash(unit_slot, destroyed_building_slot, w.navigationRevision+u64(kingdom_slot)*101)*total_weight
	last_town := -1
	for town_slot in 0..<TOWN_CAPACITY {
		if !w.kingdoms[kingdom_slot].townUsed[town_slot] do continue
		last_town = town_slot
		if roll < weights[town_slot] do return town_slot
		roll -= weights[town_slot]
	}
	return last_town
}

KingdomAbsorb :: proc(w: ^World, defeated, destroyer, capital_town, capital_building: int) -> bool {
	if defeated < 0 || defeated >= KINGDOMS_CAPACITY || !w.kingdomUsed[defeated] ||
		destroyer < 0 || destroyer >= KINGDOMS_CAPACITY || !w.kingdomUsed[destroyer] ||
		defeated == destroyer {
		return false
	}

	KingdomEndWar(w, defeated)
	CombatSiteKingdomClear(w, defeated)

	town_mapping: [TOWN_CAPACITY]int
	reserved: [TOWN_CAPACITY]bool
	for town_slot in 0..<TOWN_CAPACITY {
		town_mapping[town_slot] = -1
	}

	for town_slot in 0..<TOWN_CAPACITY {
		if !w.kingdoms[defeated].townUsed[town_slot] || town_slot == capital_town do continue
		new_slot := -1
		for candidate in 0..<TOWN_CAPACITY {
			if !w.kingdoms[destroyer].townUsed[candidate] && !reserved[candidate] {
				new_slot = candidate
				break
			}
		}
		if new_slot < 0 do return false
		town_mapping[town_slot] = new_slot
		reserved[new_slot] = true
	}

	for old_slot in 0..<TOWN_CAPACITY {
		new_slot := town_mapping[old_slot]
		if new_slot < 0 do continue
		w.kingdoms[destroyer].towns[new_slot] = w.kingdoms[defeated].towns[old_slot]
		w.kingdoms[destroyer].townUsed[new_slot] = true
	}

	for unit_slot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[unit_slot] || w.units[unit_slot].kingdome != defeated do continue
		old_town := w.units[unit_slot].town
		UnitResetState(w, unit_slot)
		w.units[unit_slot].kingdome = destroyer
		if old_town == capital_town {
			new_town := KingdomChooseTownForUnit(w, destroyer, unit_slot, capital_building)
			w.units[unit_slot].town = new_town
			if new_town >= 0 {
				w.kingdoms[destroyer].towns[new_town].citizens += 1
			}
		} else if old_town >= 0 && old_town < TOWN_CAPACITY {
			w.units[unit_slot].town = town_mapping[old_town]
		} else {
			w.units[unit_slot].town = -1
		}
	}

	for building_slot in 0..<BUILDING_CAPACITY {
		if building_slot == capital_building || !w.buildingUsed[building_slot] ||
			w.buildings[building_slot].kingdom != defeated {
			continue
		}
		old_town := w.buildings[building_slot].town
		w.buildings[building_slot].kingdom = destroyer
		if old_town >= 0 && old_town < TOWN_CAPACITY {
			w.buildings[building_slot].town = town_mapping[old_town]
		} else {
			w.buildings[building_slot].town = -1
		}
	}

	for town_slot in 0..<TOWN_CAPACITY {
		w.kingdoms[defeated].townUsed[town_slot] = false
		w.kingdoms[defeated].towns[town_slot].citizens = 0
	}
	w.kingdoms[defeated].capitalSlot = -1
	w.kingdomUsed[defeated] = false
	WorldConstructionChanged(w)
	return true
}
