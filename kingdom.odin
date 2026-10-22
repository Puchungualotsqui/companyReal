package main

import "core:math"

TOWN_CAPACITY :: 100
TOWN_WARRIOR_ORDERS_CAPACITY :: 16
TOWN_START_AREA_RADIUS :: 12
TOWN_AREA_EXPANSION :: 6
TOWN_MILESTONE_COUNT :: 3
MAX_CONVERSION_JOBS :: 16
TOWN_WOOD_TARGET :: 60

// Founding a new town is funded by the selected town. The order uses the
// town's construction queue, so regular builders travel to the site and raise
// the hall. A player order preempts automatic construction.
TOWN_FOUNDING_WOOD :: 80
TOWN_FOUNDING_MIN_CITIZENS :: 10
TOWN_FOUNDING_MIN_DISTANCE :: 24
TOWN_FOUNDING_SETTLERS :: 5

TOWN_MILESTONES := [TOWN_MILESTONE_COUNT]int{12, 25, 50}

// Share of a town's warriors that always stays home to defend it. The rest
// is split between the town's attack and defend orders.
TOWN_GARRISON_RATIO :: 0.5

Kingdom :: struct {
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
}

MilestoneOption :: struct {
	path:    TownPath,
	units:   bit_set[UnitKind],
	unlocks: bit_set[BuildingKind],
}

TOWN_BASE_UNLOCKED_BUILDINGS :: bit_set[BuildingKind]{.Home, .Farmland, .Wall, .Path}
TOWN_BASE_UNLOCKED_UNITS :: bit_set[UnitKind]{.Villager, .Builder, .WaterCollector, .Farmer, .Knight}

TOWN_MILESTONE_OPTIONS := [TOWN_MILESTONE_COUNT][2]MilestoneOption{
	{
		{
			path = .Rangers,
			units = {.Archer, .CombatBuilder},
			unlocks = {.ArcheryRange, .Bridge},
		},
		{
			path = .Mystics,
			units = {.Mage, .CombatBuilder},
			unlocks = {.MagicSchool, .Cannon},
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
	clearWork: f32,
	buildWork: f32,
}

Town :: struct {
	x, y: int,
	hallSlot: int,
	citizens: int,
	wood: f32,
	growthProgress, growthRate, constructionProgress: f32,
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
	unlockedBuildings: bit_set[BuildingKind],
	unlockedUnits: bit_set[UnitKind],
	buildingCounts: [BuildingKind]int,
	buildingSlots: [BuildingKind]int,
	wallCursor: int,
	milestonesReached: int,
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
TownInitialize :: proc(
	w: ^World,
	kingdom_slot, town_slot, hall_slot, x, y: int,
	starting_wood: f32,
) {
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

// A new town is founded when its hall finishes construction. The hall was
// already paid for by the mother town, so it is spawned directly into the new
// town slot.
TownFound :: proc(w: ^World, kingdom_slot, x, y: int) -> bool {
	if kingdom_slot < 0 || kingdom_slot >= KINGDOMS_CAPACITY || !w.kingdomUsed[kingdom_slot] {
		return false
	}
	town_slot := KingdomFreeTownSlot(w, kingdom_slot)
	if town_slot < 0 do return false

	hall_slot, ok := BuildingSpawn(w, x, y, TownHall{}, kingdom_slot, town_slot)
	if !ok do return false

	TownInitialize(w, kingdom_slot, town_slot, hall_slot, x, y, 0)
	w.kingdoms[kingdom_slot].townUsed[town_slot] = true

	for _ in 0..<TOWN_FOUNDING_SETTLERS {
		TownSpawnCitizen(w, kingdom_slot, town_slot, Villager{})
	}
	TownSpawnCitizen(w, kingdom_slot, town_slot, Builder{})
	return true
}

// Cheap checks for the placement preview. Reachability is validated once when
// the order is actually placed.
TownFoundingValid :: proc(w: ^World, kingdom_slot, town_slot, x, y: int) -> bool {
	if !WorldTownExists(w, kingdom_slot, town_slot) do return false
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	if town.constructionActive && town.construction.kind == .TownHall do return false
	if !WorldBuildingValid(w, x, y, TownHall{}) do return false
	if CombatSiteOverlaps(w, x, y, .TownHall) do return false
	if TownFoundingOverlapsOtherConstruction(w, kingdom_slot, town_slot, x, y) do return false
	return !TownFoundingTooClose(w, x, y)
}

TownFoundingOverlapsOtherConstruction :: proc(
	w: ^World,
	source_kingdom, source_town, x, y: int,
) -> bool {
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

TownFoundingAccessPoint :: proc(
	w: ^World,
	x, y: int,
	unit_type: UnitType,
) -> (int, int, bool) {
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
				if !WorldTileWalkable(w, wrapped_x, wrapped_y, unit_type) do continue
				return wrapped_x, wrapped_y, true
			}
		}
	}
	return 0, 0, false
}

TownFoundingReachable :: proc(w: ^World, kingdom_slot, town_slot, x, y: int) -> bool {
	start_x, start_y, start_found := UnitFindTownReturnPoint(w, kingdom_slot, town_slot)
	if !start_found do return false
	goal_x, goal_y, goal_found := TownFoundingAccessPoint(w, x, y, Builder{})
	if !goal_found do return false

	path: [dynamic]int
	defer delete(path)
	return AStar(w, Builder{}, start_x, start_y, goal_x, goal_y, &path)
}

// Player order: found a new town. The mother town pays the charter and its
// builders receive a town-hall construction site. An automatic construction is
// refunded and replaced, because a player order takes priority.
TownStartFounding :: proc(w: ^World, kingdom_slot, town_slot, x, y: int) -> bool {
	if !TownFoundingValid(w, kingdom_slot, town_slot, x, y) do return false
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	if town.wood < TOWN_FOUNDING_WOOD do return false
	if town.citizens < TOWN_FOUNDING_MIN_CITIZENS do return false
	if TownUnitCount(w, kingdom_slot, town_slot, .Builder) <= 0 do return false
	if KingdomFreeTownSlot(w, kingdom_slot) < 0 do return false
	if !TownFoundingReachable(w, kingdom_slot, town_slot, x, y) do return false

	if town.constructionActive do TownConstructionPreempt(w, kingdom_slot, town_slot)

	town.wood -= TOWN_FOUNDING_WOOD
	town.construction = ConstructionSite{
		kind = .TownHall,
		x = x,
		y = y,
		paid = TOWN_FOUNDING_WOOD,
	}
	town.constructionActive = true
	return true
}

// Squared distance in tiles from the town hall footprint (0 on the hall). The
// square is kept for cheap comparisons; callers compare against radius², which
// makes the buildable area a tile approximation of a circle.
TownTileAreaDistanceSquared :: proc(w: ^World, kingdom_slot, town_slot, x, y: int) -> int {
	if !WorldTownExists(w, kingdom_slot, town_slot) do return max(int)
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	hall_width, hall_height := BuildingTileSize(TownHall{})
	delta_x := max(max(town.x-x, 0), x-(town.x+hall_width-1))
	delta_y := max(max(town.y-y, 0), y-(town.y+hall_height-1))
	return delta_x*delta_x+delta_y*delta_y
}

TownPointInArea :: proc(w: ^World, kingdom_slot, town_slot, x, y: int) -> bool {
	if !WorldTownExists(w, kingdom_slot, town_slot) do return false
	radius := w.kingdoms[kingdom_slot].towns[town_slot].areaRadius
	return TownTileAreaDistanceSquared(w, kingdom_slot, town_slot, x, y) <= radius*radius
}

TownBuildingInArea :: proc(w: ^World, kingdom_slot, town_slot, x, y: int, type: BuildingType) -> bool {
	if !WorldTownExists(w, kingdom_slot, town_slot) do return false
	width, height := BuildingTileSize(type)
	if width <= 0 || height <= 0 do return false
	d0 := TownTileAreaDistanceSquared(w, kingdom_slot, town_slot, x, y)
	d1 := TownTileAreaDistanceSquared(w, kingdom_slot, town_slot, x+width-1, y)
	d2 := TownTileAreaDistanceSquared(w, kingdom_slot, town_slot, x, y+height-1)
	d3 := TownTileAreaDistanceSquared(w, kingdom_slot, town_slot, x+width-1, y+height-1)
	radius := w.kingdoms[kingdom_slot].towns[town_slot].areaRadius
	return max(max(d0, d1), max(d2, d3)) <= radius*radius
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

// Reduces queued conversions but lets in-flight units finish their trip.
TownRemoveConversion :: proc(w: ^World, kingdom_slot, town_slot: int, from, to: UnitKind, count: int) -> bool {
	if count <= 0 || !WorldTownExists(w, kingdom_slot, town_slot) do return false
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	for job_index in 0..<town.conversionCount {
		job := &town.conversions[job_index]
		if job.from != from || job.to != to do continue
		removable := max(0, job.remaining-job.assigned)
		job.remaining -= min(count, removable)
		if job.remaining <= 0 {
			town.conversions[job_index] = town.conversions[town.conversionCount-1]
			town.conversionCount -= 1
		}
		return true
	}
	return false
}

TownConversionsClear :: proc(w: ^World, kingdom_slot, town_slot: int) {
	if !WorldTownExists(w, kingdom_slot, town_slot) do return
	w.kingdoms[kingdom_slot].towns[town_slot].conversionCount = 0
}

TownMilestoneCheck :: proc(w: ^World, kingdom_slot, town_slot: int) {
	if !WorldTownExists(w, kingdom_slot, town_slot) do return
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	if town.milestonePending || town.milestonesReached >= TOWN_MILESTONE_COUNT do return
	if town.citizens >= TOWN_MILESTONES[town.milestonesReached] {
		town.milestonePending = true
	}
}

TownChooseMilestone :: proc(w: ^World, kingdom_slot, town_slot, option: int) -> bool {
	if !WorldTownExists(w, kingdom_slot, town_slot) do return false
	if option != 0 && option != 1 do return false
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	if !town.milestonePending || town.milestonesReached >= TOWN_MILESTONE_COUNT do return false

	choice := TOWN_MILESTONE_OPTIONS[town.milestonesReached][option]
	town.unlockedBuildings |= choice.unlocks
	town.unlockedUnits |= choice.units
	town.areaRadius += TOWN_AREA_EXPANSION
	town.milestonesReached += 1
	town.milestonePending = false
	return true
}

TownMilestoneOption :: proc(w: ^World, kingdom_slot, town_slot, option: int) -> (MilestoneOption, bool) {
	if !WorldTownExists(w, kingdom_slot, town_slot) do return {}, false
	if option != 0 && option != 1 do return {}, false
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	if !town.milestonePending || town.milestonesReached >= TOWN_MILESTONE_COUNT do return {}, false
	return TOWN_MILESTONE_OPTIONS[town.milestonesReached][option], true
}

// Player order: attacker town -> attack -> any town of another kingdom.
// Declaring the order is also the declaration of war.
TownStartAttack :: proc(w: ^World, kingdomSlotA, townSlotA, kingdomSlotB, townSlotB: int) {
	if kingdomSlotA == kingdomSlotB do return
	if !WorldTownExists(w, kingdomSlotA, townSlotA) || !WorldTownExists(w, kingdomSlotB, townSlotB) {
		return
	}
	if w.kingdoms[kingdomSlotA].towns[townSlotA].attackOrders[kingdomSlotB][townSlotB] do return

	KingdomDeclareWar(w, kingdomSlotA, kingdomSlotB)
	w.kingdoms[kingdomSlotA].towns[townSlotA].attackOrders[kingdomSlotB][townSlotB] = true
	w.kingdoms[kingdomSlotB].towns[townSlotB].attackedBy[kingdomSlotA][townSlotA] = true
	TownOrdersRebuild(w, kingdomSlotA, townSlotA)
}

// Player order: defender town -> defend -> any non-enemy town. The defending
// town sends a share of its warriors to patrol the protected town; the rest
// stay home. Declaring war on the protected kingdom breaks the order.
TownStartDefending :: proc(
	w: ^World,
	kingdomSlot, defenderTownSlot,
	protectedKingdomSlot, protectedTownSlot: int,
) {
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

TownStopDefending :: proc(
	w: ^World,
	kingdomSlot, defenderTownSlot,
	protectedKingdomSlot, protectedTownSlot: int,
) {
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

KingdomDeclareWar :: proc(w: ^World, kingdomSlotA, kingdomSlotB: int) {
	if kingdomSlotA < 0 || kingdomSlotA >= KINGDOMS_CAPACITY ||
		kingdomSlotB < 0 || kingdomSlotB >= KINGDOMS_CAPACITY || kingdomSlotA == kingdomSlotB {
		return
	}
	w.kingdoms[kingdomSlotA].kingdomWar[kingdomSlotB] = true
	w.kingdoms[kingdomSlotB].kingdomWar[kingdomSlotA] = true
	KingdomBreakDefenses(w, kingdomSlotA, kingdomSlotB)
}

KingdomAtWar :: proc(w: ^World, kingdomSlotA, kingdomSlotB: int) -> bool {
	if kingdomSlotA < 0 || kingdomSlotA >= KINGDOMS_CAPACITY ||
		kingdomSlotB < 0 || kingdomSlotB >= KINGDOMS_CAPACITY || kingdomSlotA == kingdomSlotB {
		return false
	}
	return w.kingdomUsed[kingdomSlotA] && w.kingdomUsed[kingdomSlotB] &&
		w.kingdoms[kingdomSlotA].kingdomWar[kingdomSlotB]
}

KingdomAtWarWithAny :: proc(w: ^World, kingdom_slot: int) -> bool {
	for other in 0..<KINGDOMS_CAPACITY {
		if KingdomAtWar(w, kingdom_slot, other) do return true
	}
	return false
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
	return true
}
