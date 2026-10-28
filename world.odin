package main

import rl "vendor:raylib"

UNIT_CAPACITY :: 10_000
BUILDING_CAPACITY :: 5_000
KINGDOMS_CAPACITY :: 5
// Playable kingdoms plus the dedicated independent-town faction. Independent
// towns live in the last slot but never get a controller, AI, diplomacy or
// victory count.
KINGDOM_SLOTS :: KINGDOMS_CAPACITY+1
NEUTRAL_KINGDOM :: KINGDOMS_CAPACITY

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
	hazardCells: #soa [HAZARD_CAPACITY]HazardCell,
	hazardUsed: [HAZARD_CAPACITY]bool,
	hazardCursor: int,
	hazardTile: []i32,
	gasClouds: #soa [GAS_CLOUD_CAPACITY]GasCloud,
	gasCloudUsed: [GAS_CLOUD_CAPACITY]bool,
	gasCloudCursor: int,
	blood: BloodField,
	particles: #soa [PARTICLE_CAPACITY]Particle,
	particleUsed: [PARTICLE_CAPACITY]bool,
	particleCursor: int,
	particleCount: int,
	particleRandom: u64,
	kingdoms: #soa [KINGDOM_SLOTS]Kingdom,
	kingdomUsed: [KINGDOM_SLOTS]bool,
	kingdomColors: [KINGDOMS_CAPACITY]rl.Color,
	controllers: [KINGDOMS_CAPACITY]KingdomController,
	playerKingdom: int,
	observerKingdom: int,
	gameOver: bool,
	winnerKingdom: int,
	usedTownName: [len(TownCulture)][TOWN_NAME_POOL_MAX]bool,
	seed: u64,
	maxX, maxY: uint,
	navigationRevision: u64,
	pathRevision: u64,
	simulationTime: f32,
	simulationAccumulator: f32,
	dayTime: f32,
	dayNumber: int,
	weather: WeatherState,
	environment: EnvironmentEvent,
	eventMinorTimer: f32,
	eventModerateTimer: f32,
	eventMajorTimer: f32,
	eventCataclysmTimer: f32,
	eventGap: f32,
	eventDebt: [KINGDOMS_CAPACITY]f32,
	eventLastMajorKingdom: int,
	eventCataclysmCount: int,
	eventSequence: u32,
	eventBag: bit_set[EnvironmentEventKind],
	terrainRevision: u64,
	scarTiles: [dynamic]i32,
	ground: [dynamic][]Tile, // Column views into groundStorage
	groundStorage: []Tile, // Flat x-major tile storage
	terrainChunkRevisions: []u64,
	terrainChunkCountX, terrainChunkCountY: int,
	spatial: SpatialIndex,
	tileBuilding: []int,
	tileConstructionBlocked: []bool,
	navigationDistance: []int,
	navigationCameFrom: []int,
	navigationOpen: []bool,
	navigationClosed: []bool,
	navigationQueue: []int,
	navigationHeapPos: []int,
	navigationStamp: []u32,
	navigationSearchId: u32,
	flowQueue: []int,
	flowFields: [FLOW_FIELD_CAPACITY]FlowField,
	flowFieldStamp: u64,
	flowBuildQueue: [FLOW_FIELD_CAPACITY]int,
	flowBuildHead: int,
	flowBuildCount: int,
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
	WorldWeatherTransition(w, .Clear)
	w.environment.phase = .None
	w.environment.kingdom = -1
	w.environment.town = -1
	w.eventLastMajorKingdom = -1
	w.eventMinorTimer = 185
	w.eventModerateTimer = 280
	w.eventMajorTimer = 450
	w.eventCataclysmTimer = 900
	if !FogInit(w) do return false
	nodeCount := int(maxX)*int(maxY)
	w.groundStorage = make([]Tile, nodeCount)
	w.ground = make([dynamic][]Tile, maxX)
	for x in 0..<int(maxX) {
		w.ground[x] = w.groundStorage[x*int(maxY):(x+1)*int(maxY)]
	}
	w.terrainChunkCountX = (int(maxX)+TERRAIN_CHUNK_TILES-1)/TERRAIN_CHUNK_TILES
	w.terrainChunkCountY = (int(maxY)+TERRAIN_CHUNK_TILES-1)/TERRAIN_CHUNK_TILES
	w.terrainChunkRevisions = make(
		[]u64,
		w.terrainChunkCountX*w.terrainChunkCountY,
	)
	w.scarTiles = make([dynamic]i32, 0, 256)
	if !BloodInit(w) do return false
	w.particleRandom = settings.seed*0x9E3779B97F4A7C15+0x9E37
	if !SpatialIndexInit(w) do return false
	if !WorldNavigationInit(w) do return false
	w.tileBuilding = make([]int, nodeCount)
	for i in 0..<nodeCount {
		w.tileBuilding[i] = -1
	}
	w.hazardTile = make([]i32, nodeCount)
	for i in 0..<nodeCount {
		w.hazardTile[i] = -1
	}
	for i in 0..<FLOW_FIELD_CAPACITY {
		w.flowFields[i].targetKingdom = -1
		w.flowFields[i].targetTown = -1
		w.flowFields[i].unitKingdom = -1
	}
	WorldGenerate(w, settings)
	ok := WorldSpawnInitialKingdoms(w, int(kingdoms), settings.seed)
	if ok {
		AssignKingdomColors(0, KINGDOM_COLOR_PALETTE[0], &w.kingdomColors)
		WorldConfigureGame(w, 0, false)
		FogUpdate(w)
	}
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
	delete(w.hazardTile)
	WorldNavigationDeinit(w)
	delete(w.scarTiles)
	delete(w.terrainChunkRevisions)
	delete(w.groundStorage)
	delete(w.ground)
	FogDeinit(w)
	BloodDeinit(w)
}

Tile :: struct {
	type:      TileType,
	climate:   ClimateKind,
	scar:      TerrainScar,
	scarFrom:  TileType,
	scarTimer: f32,
}

TileType :: enum u8 {
	Ocean,
	Lake,
	River,
	Ice,
	Marsh,
	Sand,
	Grassland,
	Plains,
	Forest,
	Taiga,
	Steppe,
	Hill,
	Mountain,
	Desert,
	Tundra,
	Ash,
	Lava,
}

ClimateKind :: enum u8 {
	Temperate,
	Coastal,
	Arid,
	Boreal,
	Tropical,
	Steppe,
	Volcanic,
}

WorldTileAt :: #force_inline proc(w: ^World, x, y: int) -> ^Tile {
	return &w.groundStorage[x*int(w.maxY)+y]
}

WorldTileSet :: proc(w: ^World, x, y: int, tileType: TileType) -> bool {
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 do return false

	wrappedX := WorldWrapCoordinate(x, worldWidth)
	wrappedY := WorldWrapCoordinate(y, worldHeight)
	tile := WorldTileAt(w, wrappedX, wrappedY)
	if tile.type != tileType {
		tile.type = tileType
		w.navigationRevision += 1
		w.pathRevision += 1
		w.terrainRevision += 1
		if len(w.terrainChunkRevisions) > 0 {
			chunkIndex := (wrappedX/TERRAIN_CHUNK_TILES)*w.terrainChunkCountY+
				wrappedY/TERRAIN_CHUNK_TILES
			if chunkIndex >= 0 && chunkIndex < len(w.terrainChunkRevisions) {
				w.terrainChunkRevisions[chunkIndex] += 1
			}
		}
	}
	return true
}

WorldTerrainChunkRevision :: proc(w: ^World, chunkX, chunkY: int) -> u64 {
	if chunkX < 0 || chunkY < 0 || chunkX >= w.terrainChunkCountX ||
		chunkY >= w.terrainChunkCountY {
		return 0
	}
	return w.terrainChunkRevisions[chunkX*w.terrainChunkCountY+chunkY]
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
	w.units.homeSlot[i] = -1
	w.units.sleepInside[i] = false
	w.units.walkPhase = 0
	w.units.animX = x
	w.units.animY = y
	w.units.actionStarted = -1e9
	w.units.actionDirX = 0
	w.units.actionDirY = 0
	// UnitTypeInit requires the slot to be marked used.
	w.unitUsed[i] = true
	UnitTypeInit(w, i, type)
	w.units[i].sleepOffsetHours = WorldNoiseHash(i, kingdomSlot+townSlot*101, u64(i)+401)-0.5
	w.units[i].decisionTimer =
		WorldNoiseHash(i, 7, 0xD3C1)*CIVILIAN_DECISION_INTERVAL
	w.units[i].decisionReady = false
	w.units[i].burning = 0
	w.units[i].effects = [UnitEffects]bool{
		.NoHome = false,
		.NoWater = false,
		.NoFood = false,
		.Poisoned = false,
		.Wet = false,
		.Chilled = false,
		.HeatStressed = false,
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
	kingdomSlot := w.units[slot].kingdome
	townSlot := w.units[slot].town
	UnitConversionCancel(w, slot)
	UnitReleaseHome(w, slot)
	if WorldTownExists(w, kingdomSlot, townSlot) &&
		w.kingdoms[kingdomSlot].towns[townSlot].citizens > 0 {
		w.kingdoms[kingdomSlot].towns[townSlot].citizens -= 1
	}
	delete(w.units[slot].path)
	if w.units[slot].burning > 0 {
		w.unitsBurning -= 1
		w.units[slot].burning = 0
	}
	SpatialUnitRemove(w, slot)
	if WorldTownExists(w, kingdomSlot, townSlot) &&
		(UnitIsWarrior(w.units[slot].type) || UnitKindOf(w.units[slot].type) == .CombatBuilder) {
		w.kingdoms[kingdomSlot].towns[townSlot].orderRevision += 1
	}
	w.unitUsed[slot] = false
	return true
}

BuildingSpawn :: proc(w: ^World, x, y: int, type: BuildingType, kingdomSlot, townSlot: int) -> (int, bool) {
	if !WorldBuildingValid(w, x, y, type) do return 0, false
	if !BuildingClearUnits(w, x, y, type, false) do return 0, false
	i := -1
	for slot in 0..<BUILDING_CAPACITY {
		if !w.buildingUsed[slot] {
			i = slot
			break
		}
	}
	if i < 0 do return 0, false
	BuildingClearUnits(w, x, y, type, true)

	w.buildings.x[i] = x
	w.buildings.y[i] = y
	w.buildings.health[i] = BuildingMaxHealthFor(w, kingdomSlot, type)
	w.buildings.cooldown[i] = 0
	w.buildings.type[i] = type
	w.buildings.kingdom[i] = kingdomSlot
	w.buildings.town[i] = townSlot
	w.buildings.homeResident[i] = 0

	width, height := BuildingTileSize(type)
	clearedWood := WorldDecorationClearRect(w, x, y, width, height)
	worldHeight := int(w.maxY)
	for tileX in x ..< x+width {
		for tileY in y ..< y+height {
			w.tileBuilding[tileX*worldHeight+tileY] = i
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
		town.wood += clearedWood
	}
	// A finished building stands where construction already reserved the
	// footprint, so existing paths were planned around it. Bumping pathRevision
	// here would invalidate every unit path in the world on each completion;
	// UnitMove validates its next waypoint instead and replans locally.
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
		kingdomSlot := w.buildings[slot].kingdom
		townSlot := w.buildings[slot].town
		if kingdomSlot < 0 || kingdomSlot >= KINGDOM_SLOTS ||
			townSlot < 0 || townSlot >= TOWN_CAPACITY ||
			!w.kingdomUsed[kingdomSlot] || !w.kingdoms[kingdomSlot].townUsed[townSlot] {
			return false
		}
		if kingdomSlot == NEUTRAL_KINGDOM {
			IndependentTownDefeat(w, townSlot, destroyerKingdom)
			break
		}
		if kingdomSlot == w.observerKingdom {
			WorldAlertAdd(
				w,
				.TownLost,
				kingdomSlot,
				townSlot,
				-1,
				f32(w.buildings[slot].x),
				f32(w.buildings[slot].y),
			)
		}

		if w.kingdoms[kingdomSlot].capitalSlot == townSlot {
			if !KingdomAbsorb(w, kingdomSlot, destroyerKingdom, townSlot, slot) do return false
		} else {
			TownOrdersClear(w, kingdomSlot, townSlot)
			TownConversionsClear(w, kingdomSlot, townSlot)
			w.kingdoms[kingdomSlot].townUsed[townSlot] = false
			WorldConstructionChanged(w)
			CombatSiteClear(w, kingdomSlot, townSlot)
			for unitSlot in 0..<UNIT_CAPACITY {
				if !w.unitUsed[unitSlot] || w.units[unitSlot].kingdome != kingdomSlot ||
					w.units[unitSlot].town != townSlot {
					continue
				}

				UnitResetState(w, unitSlot)
				newTown := KingdomChooseTownForUnit(w, kingdomSlot, unitSlot, slot)
				w.units[unitSlot].town = newTown
				if newTown >= 0 {
					w.kingdoms[kingdomSlot].towns[newTown].citizens += 1
				}
			}
			w.kingdoms[kingdomSlot].towns[townSlot].citizens = 0
			for buildingSlot in 0..<BUILDING_CAPACITY {
				if buildingSlot != slot && w.buildingUsed[buildingSlot] &&
					w.buildings[buildingSlot].kingdom == kingdomSlot &&
					w.buildings[buildingSlot].town == townSlot {
					w.buildings[buildingSlot].town = -1
				}
			}
		}
	case Bridge, Cannon, Watchtower, ArcheryRange, MagicSchool, GiantPen, SiegeWorkshop, TurtlePen, ThievesGuild, Wall, Home, Farmland, Path, DistrictHall, Granary, BuildingOrder:
	}

	resident := w.buildings.homeResident[slot]-1
	if resident >= 0 && resident < UNIT_CAPACITY && w.unitUsed[resident] &&
		w.units.homeSlot[resident] == slot {
		UnitReleaseHome(w, resident)
	}
	w.buildings.homeResident[slot] = 0

	width, height := BuildingTileSize(w.buildings[slot].type)
	worldHeight := int(w.maxY)
	for tileX in w.buildings.x[slot] ..< w.buildings.x[slot]+width {
		for tileY in w.buildings.y[slot] ..< w.buildings.y[slot]+height {
			w.tileBuilding[tileX*worldHeight+tileY] = -1
		}
	}
	SpatialBuildingRemove(w, slot)
	FogBuildingDespawn(w, slot)
	w.buildingUsed[slot] = false
	w.navigationRevision += 1
	w.pathRevision += 1
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
	WorldConstructionChanged(w)
	return true
}

WorldTileOccupied :: proc(w: ^World, x, y: int) -> bool {
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 do return false
	wrappedX := WorldWrapCoordinate(x, worldWidth)
	wrappedY := WorldWrapCoordinate(y, worldHeight)
	index := wrappedX*worldHeight+wrappedY
	return w.tileBuilding[index] >= 0 || w.tileConstructionBlocked[index]
}

WorldBuildingOverTile :: proc(w: ^World, x, y: int, bType: BuildingType) -> bool {
	width, height := BuildingTileSize(bType)
	if x < 0 || y < 0 || width <= 0 || height <= 0 ||
		x + width > int(w.maxX) || y + height > int(w.maxY) {
		return false
	}

	for tileX in x ..< x + width {
		for tileY in y ..< y + height {
			if !BuildingValidTileType(bType, w.ground[tileX][tileY].type) {
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

	worldHeight := int(w.maxY)
	for tileX in x ..< x+width {
		for tileY in y ..< y+height {
			if w.tileBuilding[tileX*worldHeight+tileY] >= 0 do return true
		}
	}
	return false
}

WorldBuildingValid :: proc(w: ^World, x, y: int, type: BuildingType) -> bool {
	return !WorldBuildingCollides(w, x, y, type) && WorldBuildingOverTile(w, x, y, type)
}
