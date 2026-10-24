package main

UNIT_CAPACITY :: 10_000
BUILDING_CAPACITY :: 5_000
KINGDOMS_CAPACITY :: 5

World :: struct {
	units: #soa [UNIT_CAPACITY]Unit,
	unitUsed: [UNIT_CAPACITY]bool,
	buildings: #soa [BUILDING_CAPACITY]Building,
	buildingUsed: [BUILDING_CAPACITY]bool,
	decorations: #soa [DECORATION_CAPACITY]Decoration,
	decorationUsed: [DECORATION_CAPACITY]bool,
	decorationCursor: int,
	decorationStumps: int,
	fires: #soa [FIRE_CAPACITY]Fire,
	fireUsed: [FIRE_CAPACITY]bool,
	fireCursor: int,
	fireCount: int,
	unitsBurning: int,
	blood: BloodField,
	particles: #soa [PARTICLE_CAPACITY]Particle,
	particleUsed: [PARTICLE_CAPACITY]bool,
	particleCursor: int,
	particleCount: int,
	particleRandom: u64,
	kingdoms: #soa [KINGDOMS_CAPACITY]Kingdom,
	kingdomUsed: [KINGDOMS_CAPACITY]bool,
	usedTownName: [len(TownCulture)][TOWN_NAME_POOL_MAX]bool,
	seed: u64,
	maxX, maxY: uint,
	navigationRevision: u64,
	simulationTime: f32,
	simulationAccumulator: f32,
	dayTime: f32,
	dayNumber: int,
	terrainRevision: u64,
	ground: [dynamic][dynamic]Tile,
	spatial: SpatialIndex,
	tileBuilding: []int,
	navigationDistance: []int,
	navigationCameFrom: []int,
	navigationOpen: []bool,
	navigationClosed: []bool,
	navigationQueue: []int,
	navigationStamp: []u32,
	navigationSearchId: u32,
	flowFields: [FLOW_FIELD_CAPACITY]FlowField,
	flowFieldStamp: u64,
	combatSites: #soa [COMBAT_SITE_CAPACITY]CombatSite,
	combatSiteUsed: [COMBAT_SITE_CAPACITY]bool,
	fog: FogOfWar,
	alerts: AlertFeed,
}

WorldInit :: proc(w: ^World, maxX, maxY, kingdoms: uint, settings: WorldGenerationSettings) -> bool {
	if maxX == 0 || maxY == 0 || kingdoms == 0 || kingdoms > uint(KINGDOMS_CAPACITY) {
		return false
	}

	w.maxX = maxX
	w.maxY = maxY
	w.seed = settings.seed
	w.dayTime = f32(WORLD_DAY_LENGTH_SECONDS)*6/24
	if !FogInit(w) do return false
	w.ground = make([dynamic][dynamic]Tile, maxX)
	for &x in w.ground {
		x = make([dynamic]Tile, maxY)
	}
	if !BloodInit(w) do return false
	w.particleRandom = settings.seed*0x9E3779B97F4A7C15+0x9E37
	if !SpatialIndexInit(w) do return false
	if !WorldNavigationInit(w) do return false
	node_count := int(maxX)*int(maxY)
	w.tileBuilding = make([]int, node_count)
	for i in 0..<node_count {
		w.tileBuilding[i] = -1
	}
	for i in 0..<FLOW_FIELD_CAPACITY {
		w.flowFields[i].targetKingdom = -1
		w.flowFields[i].targetTown = -1
		w.flowFields[i].unitKingdom = -1
	}
	WorldGenerate(w, settings)
	ok := WorldSpawnInitialKingdoms(w, int(kingdoms), settings.seed)
	if ok do FogUpdate(w)
	return ok
}

WorldDeinit :: proc(w: ^World) {
	for i in 0..<UNIT_CAPACITY {
		if w.unitUsed[i] {
			UnitDespawn(w, i)
		}
	}
	for i in 0..<DECORATION_CAPACITY {
		if w.decorationUsed[i] {
			WorldDecorationDespawn(w, i)
		}
	}
	SpatialIndexDeinit(w)
	delete(w.tileBuilding)
	WorldNavigationDeinit(w)
	for &x in w.ground {
		delete(x)
	}
	delete(w.ground)
	FogDeinit(w)
	BloodDeinit(w)
}

Tile :: struct {
	type: TileType,
}

TileType :: enum {
	Water,
	FreshWater,
	River,
	Ground,
	FertileGround,
	Sand,
	Forest,
	Hill,
	Desert,
}

WorldTileSet :: proc(w: ^World, x, y: int, tile_type: TileType) -> bool {
	world_width := int(w.maxX)
	world_height := int(w.maxY)
	if world_width <= 0 || world_height <= 0 do return false

	wrapped_x := WorldWrapCoordinate(x, world_width)
	wrapped_y := WorldWrapCoordinate(y, world_height)
	if w.ground[wrapped_x][wrapped_y].type != tile_type {
		w.ground[wrapped_x][wrapped_y].type = tile_type
		w.navigationRevision += 1
		w.terrainRevision += 1
	}
	return true
}

UnitSpawn :: proc(w: ^World, type: UnitType, x, y: f32, kingdomSlot, townSlot: int) -> (int, bool) {
	i := -1
	for slot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[slot] {
			i = slot
			break
		}
	}
	if i < 0 {
		return 0, false
	}
	w.units.x[i] = x
	w.units.y[i] = y
	w.units.previousX[i] = x
	w.units.previousY[i] = y
	w.units.kingdome[i] = kingdomSlot
	w.units.town[i] = townSlot
	// UnitTypeInit requires the slot to be marked used.
	w.unitUsed[i] = true
	UnitTypeInit(w, i, type)
	w.units[i].sleepOffsetHours = WorldNoiseHash(i, kingdomSlot+townSlot*101, u64(i)+401)-0.5
	w.units[i].burning = 0
	w.units[i].effects = [UnitEffects]bool{
		.NoHome = false,
		.NoWater = false,
		.NoFood = false,
	}

	w.units[i].path = make([dynamic]int, 0, 250)
	w.units[i].pathTargetX = 0
	w.units[i].pathTargetY = 0
	w.units[i].pathRevision = 0
	w.units[i].pathIndex = 0
	w.units[i].pathReady = false
	w.units[i].pathFound = false

	w.kingdoms[kingdomSlot].towns[townSlot].citizens += 1
	if UnitIsWarrior(type) || UnitKindOf(type) == .CombatBuilder {
		w.kingdoms[kingdomSlot].towns[townSlot].orderRevision += 1
	}

	SpatialUnitInsert(w, i)

	return i, true
}

UnitGet :: proc(w: ^World, slot: int) -> (int, bool) {
	if slot < 0 || slot >= UNIT_CAPACITY || !w.unitUsed[slot] {
		return 0, false
	}
	return slot, true
}

UnitDespawn :: proc(w: ^World, slot: int) -> bool {
	if slot < 0 || slot >= UNIT_CAPACITY || !w.unitUsed[slot] {
		return false
	}
	kingdom_slot := w.units[slot].kingdome
	town_slot := w.units[slot].town
	UnitConversionCancel(w, slot)
	if kingdom_slot >= 0 && kingdom_slot < KINGDOMS_CAPACITY &&
		town_slot >= 0 && town_slot < TOWN_CAPACITY &&
		w.kingdoms[kingdom_slot].townUsed[town_slot] &&
		w.kingdoms[kingdom_slot].towns[town_slot].citizens > 0 {
		w.kingdoms[kingdom_slot].towns[town_slot].citizens -= 1
	}
	delete(w.units[slot].path)
	if w.units[slot].burning > 0 {
		w.unitsBurning -= 1
		w.units[slot].burning = 0
	}
	SpatialUnitRemove(w, slot)
	if WorldTownExists(w, kingdom_slot, town_slot) &&
		(UnitIsWarrior(w.units[slot].type) || UnitKindOf(w.units[slot].type) == .CombatBuilder) {
		w.kingdoms[kingdom_slot].towns[town_slot].orderRevision += 1
	}
	w.unitUsed[slot] = false
	return true
}

BuildingSpawn :: proc(w: ^World, x, y: int, type: BuildingType, kingdomSlot, townSlot: int) -> (int, bool) {
	if !WorldBuildingValid(w, x, y, type) do return 0, false
	i := -1
	for slot in 0..<BUILDING_CAPACITY {
		if !w.buildingUsed[slot] {
			i = slot
			break
		}
	}
	if i < 0 do return 0, false

	w.buildings.x[i] = x
	w.buildings.y[i] = y
	w.buildings.health[i] = BuildingDefaultHealth(type)
	w.buildings.cooldown[i] = 0
	w.buildings.type[i] = type
	w.buildings.kingdom[i] = kingdomSlot
	w.buildings.town[i] = townSlot

	width, height := BuildingTileSize(type)
	cleared_wood := WorldDecorationClearRect(w, x, y, width, height)
	world_height := int(w.maxY)
	for tile_x in x ..< x+width {
		for tile_y in y ..< y+height {
			w.tileBuilding[tile_x*world_height+tile_y] = i
		}
	}

	w.buildingUsed[i] = true
	SpatialBuildingInsert(w, i)
	if WorldTownExists(w, kingdomSlot, townSlot) {
		town := &w.kingdoms[kingdomSlot].towns[townSlot]
		kind := BuildingKindOf(type)
		town.buildingCounts[kind] += 1
		if town.buildingSlots[kind] < 0 do town.buildingSlots[kind] = i
		// Trees felled to clear the site are not wasted.
		town.wood += cleared_wood
	}
	w.navigationRevision += 1
	if BuildingKindOf(type) == .Path do WorldSpawnStreetLamp(w, x, y)
	return i, true
}

BuildingGet :: proc(w: ^World, slot: int) -> (int, bool) {
	if slot < 0 || slot >= BUILDING_CAPACITY || !w.buildingUsed[slot] {
		return 0, false
	}
	return slot, true
}

BuildingDespawn :: proc(w: ^World, slot: int, destroyerKingdom: int) -> bool {
	if slot < 0 || slot >= BUILDING_CAPACITY || !w.buildingUsed[slot] {
		return false
	}

	switch _ in w.buildings[slot].type {
	case TownHall:
		kingdom_slot := w.buildings[slot].kingdom
		town_slot := w.buildings[slot].town
		if kingdom_slot < 0 || kingdom_slot >= KINGDOMS_CAPACITY ||
			town_slot < 0 || town_slot >= TOWN_CAPACITY ||
			!w.kingdomUsed[kingdom_slot] || !w.kingdoms[kingdom_slot].townUsed[town_slot] {
			return false
		}
		if kingdom_slot == PLAYER_KINGDOM {
			WorldAlertAdd(
				w,
				.TownLost,
				kingdom_slot,
				town_slot,
				-1,
				f32(w.buildings[slot].x),
				f32(w.buildings[slot].y),
			)
		}

		if w.kingdoms[kingdom_slot].capitalSlot == town_slot {
			if !KingdomAbsorb(w, kingdom_slot, destroyerKingdom, town_slot, slot) do return false
		} else {
			TownOrdersClear(w, kingdom_slot, town_slot)
			TownConversionsClear(w, kingdom_slot, town_slot)
			w.kingdoms[kingdom_slot].townUsed[town_slot] = false
			CombatSiteClear(w, kingdom_slot, town_slot)
			for unit_slot in 0..<UNIT_CAPACITY {
				if !w.unitUsed[unit_slot] || w.units[unit_slot].kingdome != kingdom_slot ||
					w.units[unit_slot].town != town_slot {
					continue
				}

				UnitResetState(w, unit_slot)
				new_town := KingdomChooseTownForUnit(w, kingdom_slot, unit_slot, slot)
				w.units[unit_slot].town = new_town
				if new_town >= 0 {
					w.kingdoms[kingdom_slot].towns[new_town].citizens += 1
				}
			}
			w.kingdoms[kingdom_slot].towns[town_slot].citizens = 0
			for building_slot in 0..<BUILDING_CAPACITY {
				if building_slot != slot && w.buildingUsed[building_slot] &&
					w.buildings[building_slot].kingdom == kingdom_slot &&
					w.buildings[building_slot].town == town_slot {
					w.buildings[building_slot].town = -1
				}
			}
		}
	case Bridge, Cannon, Watchtower, ArcheryRange, MagicSchool, GiantPen, SiegeWorkshop, TurtlePen, ThievesGuild, Wall, Home, Farmland, Path:
	}

	width, height := BuildingTileSize(w.buildings[slot].type)
	world_height := int(w.maxY)
	for tile_x in w.buildings.x[slot] ..< w.buildings.x[slot]+width {
		for tile_y in w.buildings.y[slot] ..< w.buildings.y[slot]+height {
			w.tileBuilding[tile_x*world_height+tile_y] = -1
		}
	}
	SpatialBuildingRemove(w, slot)
	FogBuildingDespawn(w, slot)
	w.buildingUsed[slot] = false
	w.navigationRevision += 1
	return true
}

KingdomSpawn :: proc(w: ^World, x, y: int) -> (int, bool) {
	i := -1
	for slot in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[slot] {
			i = slot
			break
		}
	}
	if i < 0 do return 0, false

	w.kingdoms[i].culture = NameKingdomCulture(w, i)
	NameKingdomAssign(w, i)

	if capital, ok := TownStart(w, x, y, i); ok {
		w.kingdoms[i].capitalSlot = capital
		w.kingdomUsed[i] = true
		return i, true
	}

	return 0, false
}

KingdomGet :: proc(w: ^World, slot: int) -> (int, bool) {
	if slot < 0 || slot >= KINGDOMS_CAPACITY || !w.kingdomUsed[slot] {
		return 0, false
	}
	return slot, true
}

KingdomDespawn :: proc(w: ^World, slot: int) -> bool {
	if slot < 0 || slot >= KINGDOMS_CAPACITY || !w.kingdomUsed[slot] {
		return false
	}
	KingdomEndWar(w, slot)
	CombatSiteKingdomClear(w, slot)
	w.kingdomUsed[slot] = false
	return true
}

WorldTileOccupied :: proc(w: ^World, x, y: int) -> bool {
	world_width := int(w.maxX)
	world_height := int(w.maxY)
	if world_width <= 0 || world_height <= 0 do return false
	wrapped_x := WorldWrapCoordinate(x, world_width)
	wrapped_y := WorldWrapCoordinate(y, world_height)
	return w.tileBuilding[wrapped_x*world_height+wrapped_y] >= 0
}

WorldBuildingOverTile :: proc(w: ^World, x, y: int, bType: BuildingType) -> bool {
	width, height := BuildingTileSize(bType)
	if x < 0 || y < 0 || width <= 0 || height <= 0 ||
		x + width > int(w.maxX) || y + height > int(w.maxY) {
		return false
	}

	for tile_x in x ..< x + width {
		for tile_y in y ..< y + height {
			if !BuildingValidTileType(bType, w.ground[tile_x][tile_y].type) {
				return false
			}
		}
	}
	return true
}

WorldBuildingCollides :: proc(w: ^World, x, y: int, type: BuildingType) -> bool {
	width, height := BuildingTileSize(type)
	if x < 0 || y < 0 || width <= 0 || height <= 0 ||
		x + width > int(w.maxX) || y + height > int(w.maxY) {
		return true
	}

	world_height := int(w.maxY)
	for tile_x in x ..< x+width {
		for tile_y in y ..< y+height {
			if w.tileBuilding[tile_x*world_height+tile_y] >= 0 do return true
		}
	}
	return false
}

WorldBuildingValid :: proc(w: ^World, x, y: int, type: BuildingType) -> bool {
	return !WorldBuildingCollides(w, x, y, type) && WorldBuildingOverTile(w, x, y, type)
}
