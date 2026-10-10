package main

EntityId :: distinct uint
UnitId :: distinct uint
SquadId :: distinct uint
SectorId :: distinct uint
BuildingId :: distinct uint
StrikeId :: distinct uint
CargoId :: distinct uint
ConvoyId :: distinct uint
PlayerId :: distinct uint

INVALID_ENTITY_ID : EntityId : 0
INVALID_UNIT_ID : UnitId : 0
INVALID_SQUAD_ID : SquadId : 0
INVALID_SECTOR_ID : SectorId : 0
INVALID_BUILDING_ID : BuildingId : 0
INVALID_STRIKE_ID : StrikeId : 0
INVALID_CARGO_ID : CargoId : 0
INVALID_CONVOY_ID : ConvoyId : 0
INVALID_PLAYER_ID : PlayerId : 0
LOCAL_PLAYER_ID : PlayerId : 1
PLAYER_TWO_ID : PlayerId : 2

Team :: enum u8 {
	Neutral,
	A,
	B,
}

ResourceType :: enum u8 {
	Materials,
	Fuel,
	Munitions,
}

SectorObjectiveType :: enum u8 {
	None,
	Strategic,
	Base,
	Resource,
}

MatchState :: enum u8 {
	Setup,
	Running,
	Victory,
	Defeat,
	Draw,
}

RESOURCE_TYPE_COUNT :: 3

ResourceInventory :: struct {
	amounts: [RESOURCE_TYPE_COUNT]f32,
}

ConvoyState :: enum u8 {
	Traveling,
	Blocked,
	Destroyed,
}

ResourceInventoryMake :: proc(materials, fuel, munitions: f32) -> ResourceInventory {
	return ResourceInventory{[RESOURCE_TYPE_COUNT]f32{materials, fuel, munitions}}
}

ResourceIndex :: proc(resource: ResourceType) -> int {
	switch resource {
	case .Materials:
		return 0
	case .Fuel:
		return 1
	case .Munitions:
		return 2
	}
	unreachable()
}

ResourceAmount :: proc(inventory: ResourceInventory, resource: ResourceType) -> f32 {
	return inventory.amounts[ResourceIndex(resource)]
}

UnitType :: enum u8 {
	Line,
	Assault,
	Heavy,
	Scout,
	Engineer,
	Vehicle,
	Equipment,
	Artillery,
}

UnitState :: enum u8 {
	Idle,
	Moving,
	Attacking,
	Retreating,
	Wounded,
	Dead,
}

TerrainType :: enum u8 {
	Open,
	LightCover,
	HeavyCover,
	Rough,
	Crater,
	Damaged,
	Road,
	Bridge,
	Chokepoint,
	Blocked,
}

SquadIntent :: enum u8 {
	Idle,
	Advance,
	Defend,
	Assault,
	Probe,
	Escort,
	Raid,
	Resupply,
	Withdraw,
}

FormationType :: enum u8 {
	Line,
	Column,
	Wedge,
}

RouteType :: enum u8 {
	Road,
	Bridge,
	Chokepoint,
}

SectorRoute :: struct {
	from: SectorId,
	to: SectorId,
	type: RouteType,
	damaged: bool,
	blocked: bool,
	danger: f32,
}

BuildingType :: enum u8 {
	Headquarters,
	ResourceSite,
	Refinery,
	MunitionsFactory,
	Warehouse,
	RouteInfrastructure,
	InfantryProduction,
	SupplyDepot,
	ReinforcementCenter,
	ObservationPost,
	Defense,
	VehicleWorkshop,
	EquipmentWorkshop,
	ArtilleryEmplacement,
}

OrderType :: enum u8 {
	Idle,
	Move,
	Attack,
	Retreat,
}

Order :: struct {
	type: OrderType,
	target_pos: Vec2,
	target: UnitId,
}

UnitStats :: struct {
	health: f32,
	speed: f32,
	range: f32,
	damage: f32,
	suppression: f32,
	cooldown: f32,
	ammo: f32,
}

Unit :: struct {
	id: UnitId,
	squad: SquadId,
	team: Team,
	type: UnitType,
	state: UnitState,
	pos: Vec2,
	velocity: Vec2,	
	formation_offset: Vec2,
	health: f32,
	max_health: f32,
	morale: f32,
	suppression: f32,
	ammo: f32,
	max_ammo: f32,
	cooldown: f32,
	order: Order,
}

Squad :: struct {
	id: SquadId,
	owner: PlayerId,
	team: Team,
	type: UnitType,
	units: [dynamic]UnitId,
	order: Order,
	intent: SquadIntent,
	formation: FormationType,
	convoy: ConvoyId,
	path: [dynamic]Vec2,
	path_index: int,
	path_goal: Vec2,
	path_terrain_revision: u64,
	path_route_revision: u64,
}

Sector :: struct {
	id: SectorId,
	team: Team,
	bounds: Rect,
	capture: f32,
	inventory: ResourceInventory,
	requested: ResourceInventory,
	objective: SectorObjectiveType,
	objective_team: Team,
	objective_value: int,
}

CargoLot :: struct {
	id: CargoId,
	convoy: ConvoyId,
	team: Team,
	resource: ResourceType,
	quantity: f32,
	origin: SectorId,
	destination: SectorId,
}

Convoy :: struct {
	id: ConvoyId,
	team: Team,
	resource: ResourceType,
	cargo: CargoId,
	origin: SectorId,
	destination: SectorId,
	progress: f32,
	travel_time: f32,
	blocked_time: f32,
	vehicle_count: int,
	capacity: f32,
	speed: f32,
	fuel: f32,
	health: f32,
	state: ConvoyState,
}

Building :: struct {
	id: BuildingId,
	owner: PlayerId,
	team: Team,
	type: BuildingType,
	pos: Vec2,
	health: f32,
	max_health: f32,
	build_progress: f32,
	build_time: f32,
	complete: bool,
	destroyed: bool,
	builder: SquadId,
	production: UnitType,
	resource: ResourceType,
	queue: int,
	production_timer: f32,
}

ArtilleryStrike :: struct {
	id: StrikeId,
	team: Team,
	origin: Vec2,
	target: Vec2,
	elapsed: f32,
	delay: f32,
	damage: f32,
	radius: f32,
	suppression: f32,
}

ArtilleryShell :: struct {
	team: Team,
	origin: Vec2,
	pos: Vec2,
	target: Vec2,
	elapsed: f32,
	flight_time: f32,
	damage: f32,
	radius: f32,
	suppression: f32,
}

EffectType :: enum u8 {
	Crater,
	Fire,
	Smoke,
	Debris,
	Wreck,
}

Effect :: struct {
	type: EffectType,
	pos: Vec2,
	age: f32,
	lifetime: f32,
	size: f32,
}

Body :: struct {
	pos: Vec2,
	age: f32,
}

World :: struct {
	units: [dynamic]Unit,
	squads: [dynamic]Squad,
	sectors: [dynamic]Sector,
	routes: [dynamic]SectorRoute,
	factions: [3]Faction,
	buildings: [dynamic]Building,
	cargo: [dynamic]CargoLot,
	convoys: [dynamic]Convoy,
	strikes: [dynamic]ArtilleryStrike,
	shells: [dynamic]ArtilleryShell,
	effects: [dynamic]Effect,
	bodies: [dynamic]Body,
	terrain: [dynamic]TerrainType,
	terrain_width: int,
	terrain_height: int,
	cargo_lost: f32,
	next_cargo_id: CargoId,
	next_convoy_id: ConvoyId,
	tick: u64,
	time: f32,
	accumulator: f32,
	step: f32,
	max_size: Vec2,
	terrain_revision: u64,
	route_revision: u64,
	match_state: MatchState,
	match_time: f32,
	match_time_limit: f32,
	winner: Team,
	reinforcements: [3]int,
	reinforcement_limit: [3]int,
}

WorldInit :: proc(w: ^World) {
	w.units = make([dynamic]Unit)
	w.squads = make([dynamic]Squad)
	w.sectors = make([dynamic]Sector)
	w.routes = make([dynamic]SectorRoute)
	w.factions = [3]Faction{.HearthUnion, .BastionDirectorate, .FreeMarches}
	w.buildings = make([dynamic]Building)
	w.cargo = make([dynamic]CargoLot)
	w.convoys = make([dynamic]Convoy)
	w.strikes = make([dynamic]ArtilleryStrike)
	w.shells = make([dynamic]ArtilleryShell)
	w.effects = make([dynamic]Effect)
	w.bodies = make([dynamic]Body)
	w.terrain_width = 16
	w.terrain_height = 16
	w.terrain = make([dynamic]TerrainType)
	for index: int = 0; index < w.terrain_width * w.terrain_height; index += 1 do append(&w.terrain, TerrainType.Open)
	w.terrain_revision = 0
	w.route_revision = 0
	w.match_state = .Setup
	w.match_time = 0
	w.match_time_limit = 20 * 60
	w.winner = .Neutral
	w.reinforcements = [3]int{0, 100, 100}
	w.reinforcement_limit = [3]int{0, 100, 100}
	WorldCreateTerrain(w)
	w.cargo_lost = 0
	w.next_cargo_id = CargoId(1)
	w.next_convoy_id = ConvoyId(1)
	w.tick = 0
	w.time = 0
	w.accumulator = 0
	w.step = 1.0 / 20.0
	w.max_size = Vec2{256, 256}
	WorldCreateSectors(w)
	WorldCreateRoutes(w)
}

WorldDeinit :: proc(w: ^World) {
	for &squad in w.squads {
		delete(squad.units)
		delete(squad.path)
	}
	delete(w.units)
	delete(w.squads)
	delete(w.sectors)
	delete(w.routes)
	delete(w.buildings)
	delete(w.cargo)
	delete(w.convoys)
	delete(w.strikes)
	delete(w.shells)
	delete(w.effects)
	delete(w.bodies)
	delete(w.terrain)
}

WorldCreateTerrain :: proc(w: ^World) {
	WorldSetTerrainCell(w, 2, 2, .LightCover)
	WorldSetTerrainCell(w, 5, 4, .HeavyCover)
	WorldSetTerrainCell(w, 9, 8, .Rough)
	WorldSetTerrainCell(w, 12, 11, .LightCover)
	WorldSetTerrainCell(w, 1, 1, .Road)
	WorldSetTerrainCell(w, 8, 8, .Chokepoint)
}

WorldCreateSectors :: proc(w: ^World) {
	sector_size := Vec2{64, 64}
	for y: i32 = 0; y < 4; y += 1 {
		for x: i32 = 0; x < 4; x += 1 {
			id := SectorId(uint(len(w.sectors) + 1))
			bounds := Rect{f32(x) * sector_size.x, f32(y) * sector_size.y, sector_size.x, sector_size.y}
			append(&w.sectors, Sector{id, .Neutral, bounds, 0, ResourceInventory{}, ResourceInventory{}, .None, .Neutral, 0})
		}
	}
}

WorldCreateRoutes :: proc(w: ^World) {
	for y: int = 0; y < 4; y += 1 {
		for x: int = 0; x < 4; x += 1 {
			from := WorldSectorIdAtCoordinates(x, y)
			if x < 3 {
				to := WorldSectorIdAtCoordinates(x + 1, y)
				type := RouteType.Road
				if x == 1 && y == 1 do type = .Chokepoint
				append(&w.routes, SectorRoute{from, to, type, false, false, 0})
			}
			if y < 3 {
				to := WorldSectorIdAtCoordinates(x, y + 1)
				type := RouteType.Road
				if x == 1 do type = .Bridge
				append(&w.routes, SectorRoute{from, to, type, false, false, 0})
			}
		}
	}
}

UnitIndex :: proc(id: UnitId) -> int { return int(id) - 1 }
SquadIndex :: proc(id: SquadId) -> int { return int(id) - 1 }
BuildingIndex :: proc(id: BuildingId) -> int { return int(id) - 1 }

UnitGet :: proc(w: ^World, id: UnitId) -> ^Unit {
	index := UnitIndex(id)
	if id == INVALID_UNIT_ID || index < 0 || index >= len(w.units) do return nil
	return &w.units[index]
}

SquadGet :: proc(w: ^World, id: SquadId) -> ^Squad {
	index := SquadIndex(id)
	if id == INVALID_SQUAD_ID || index < 0 || index >= len(w.squads) do return nil
	return &w.squads[index]
}

TeamIndex :: proc(team: Team) -> int {
	switch team {
	case .Neutral:
		return 0
	case .A:
		return 1
	case .B:
		return 2
	}
	unreachable()
}

TeamEnemy :: proc(team: Team) -> Team {
	switch team {
	case .Neutral:
		return .Neutral
	case .A:
		return .B
	case .B:
		return .A
	}
	unreachable()
}

UnitIsAlive :: proc(unit: Unit) -> bool {
	switch unit.state {
	case .Idle, .Moving, .Attacking, .Retreating, .Wounded:
		return true
	case .Dead:
		return false
	}
	unreachable()
}

UnitCanFight :: proc(unit: Unit) -> bool {
	switch unit.state {
	case .Idle, .Moving, .Attacking:
		return true
	case .Retreating, .Wounded, .Dead:
		return false
	}
	unreachable()
}

TerrainIndex :: proc(w: ^World, x, y: int) -> int { return y * w.terrain_width + x }

WorldTerrainAt :: proc(w: ^World, position: Vec2) -> TerrainType {
	x := int(position.x / (w.max_size.x / f32(w.terrain_width)))
	y := int(position.y / (w.max_size.y / f32(w.terrain_height)))
	if x < 0 || y < 0 || x >= w.terrain_width || y >= w.terrain_height do return .Open
	return w.terrain[TerrainIndex(w, x, y)]
}

WorldSetTerrainCell :: proc(w: ^World, x, y: int, terrain: TerrainType) -> bool {
	if x < 0 || y < 0 || x >= w.terrain_width || y >= w.terrain_height do return false
	index := TerrainIndex(w, x, y)
	if w.terrain[index] != terrain {
		w.terrain[index] = terrain
		w.terrain_revision += 1
	}
	return true
}

TerrainCover :: proc(terrain: TerrainType) -> f32 {
	switch terrain {
	case .Open, .Road, .Bridge:
		return 0
	case .LightCover:
		return 0.25
	case .HeavyCover:
		return 0.5
	case .Rough, .Damaged, .Chokepoint, .Blocked:
		return 0
	case .Crater:
		return 0.1
	}
	unreachable()
}

TerrainSpeed :: proc(terrain: TerrainType) -> f32 {
	switch terrain {
	case .Open, .LightCover, .HeavyCover:
		return 1
	case .Road:
		return 1.35
	case .Bridge:
		return 1.15
	case .Rough:
		return 0.65
	case .Crater:
		return 0.45
	case .Damaged:
		return 0.8
	case .Chokepoint:
		return 0.55
	case .Blocked:
		return 0
	}
	unreachable()
}

UnitInRect :: proc(unit: Unit, rect: Rect) -> bool { return unit.pos.x >= rect.x && unit.pos.x < rect.x + rect.width && unit.pos.y >= rect.y && unit.pos.y < rect.y + rect.height }
