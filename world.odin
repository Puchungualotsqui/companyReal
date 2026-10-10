package main

EntityId :: distinct uint
UnitId :: distinct uint
SquadId :: distinct uint
SectorId :: distinct uint
BuildingId :: distinct uint
StrikeId :: distinct uint
PlayerId :: distinct uint

INVALID_ENTITY_ID : EntityId : 0
INVALID_UNIT_ID : UnitId : 0
INVALID_SQUAD_ID : SquadId : 0
INVALID_SECTOR_ID : SectorId : 0
INVALID_BUILDING_ID : BuildingId : 0
INVALID_STRIKE_ID : StrikeId : 0
INVALID_PLAYER_ID : PlayerId : 0
LOCAL_PLAYER_ID : PlayerId : 1
PLAYER_TWO_ID : PlayerId : 2

Team :: enum u8 {
	Neutral,
	A,
	B,
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
}

BuildingType :: enum u8 {
	Headquarters,
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
}

Sector :: struct {
	id: SectorId,
	team: Team,
	bounds: Rect,
	capture: f32,
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
	buildings: [dynamic]Building,
	strikes: [dynamic]ArtilleryStrike,
	shells: [dynamic]ArtilleryShell,
	effects: [dynamic]Effect,
	bodies: [dynamic]Body,
	terrain: [dynamic]TerrainType,
	terrain_width: int,
	terrain_height: int,
	team_supply: [3]f32,
	tick: u64,
	time: f32,
	accumulator: f32,
	step: f32,
	max_size: Vec2,
}

WorldInit :: proc(w: ^World) {
	w.units = make([dynamic]Unit)
	w.squads = make([dynamic]Squad)
	w.sectors = make([dynamic]Sector)
	w.buildings = make([dynamic]Building)
	w.strikes = make([dynamic]ArtilleryStrike)
	w.shells = make([dynamic]ArtilleryShell)
	w.effects = make([dynamic]Effect)
	w.bodies = make([dynamic]Body)
	w.terrain_width = 16
	w.terrain_height = 16
	w.terrain = make([dynamic]TerrainType)
	for index: int = 0; index < w.terrain_width * w.terrain_height; index += 1 do append(&w.terrain, TerrainType.Open)
	WorldCreateTerrain(w)
	w.team_supply = [3]f32{0, 1000, 1000}
	w.tick = 0
	w.time = 0
	w.accumulator = 0
	w.step = 1.0 / 20.0
	w.max_size = Vec2{256, 256}
	WorldCreateSectors(w)
}

WorldDeinit :: proc(w: ^World) {
	for &squad in w.squads do delete(squad.units)
	delete(w.units)
	delete(w.squads)
	delete(w.sectors)
	delete(w.buildings)
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
}

WorldCreateSectors :: proc(w: ^World) {
	sector_size := Vec2{64, 64}
	for y: i32 = 0; y < 4; y += 1 {
		for x: i32 = 0; x < 4; x += 1 {
			id := SectorId(uint(len(w.sectors) + 1))
			bounds := Rect{f32(x) * sector_size.x, f32(y) * sector_size.y, sector_size.x, sector_size.y}
			append(&w.sectors, Sector{id, .Neutral, bounds, 0})
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
	w.terrain[TerrainIndex(w, x, y)] = terrain
	return true
}

TerrainCover :: proc(terrain: TerrainType) -> f32 {
	switch terrain {
	case .Open:
		return 0
	case .LightCover:
		return 0.25
	case .HeavyCover:
		return 0.5
	case .Rough, .Damaged:
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
	case .Rough:
		return 0.65
	case .Crater:
		return 0.45
	case .Damaged:
		return 0.8
	}
	unreachable()
}

UnitInRect :: proc(unit: Unit, rect: Rect) -> bool { return unit.pos.x >= rect.x && unit.pos.x < rect.x + rect.width && unit.pos.y >= rect.y && unit.pos.y < rect.y + rect.height }
