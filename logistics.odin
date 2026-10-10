package main

CARGO_BLOCKED_LOSS_TIME :: 8.0
CARGO_BASE_TRAVEL_TIME :: 1.0
CONVOY_CARGO_CAPACITY :: 100.0
CONVOY_VEHICLE_CAPACITY :: 100.0
CONVOY_STARTING_FUEL :: 100.0
CONVOY_HEALTH :: 100.0
SECTOR_BASE_STORAGE :: 500.0
HQ_STORAGE_BONUS :: 1000.0
WAREHOUSE_STORAGE_BONUS :: 2000.0
DEPOT_STORAGE_BONUS :: 1000.0

ResourceInventoryAdd :: proc(inventory: ^ResourceInventory, resource: ResourceType, amount: f32) {
	if amount <= 0 do return
	index := ResourceIndex(resource)
	inventory.amounts[index] += amount
}

ResourceInventoryCanAfford :: proc(inventory: ResourceInventory, cost: ResourceInventory) -> bool {
	for index: int = 0; index < RESOURCE_TYPE_COUNT; index += 1 {
		if inventory.amounts[index] < cost.amounts[index] do return false
	}
	return true
}

ResourceInventoryConsume :: proc(inventory: ^ResourceInventory, cost: ResourceInventory) -> bool {
	if !ResourceInventoryCanAfford(inventory^, cost) do return false
	for index: int = 0; index < RESOURCE_TYPE_COUNT; index += 1 {
		inventory.amounts[index] -= cost.amounts[index]
	}
	return true
}

WorldSectorGet :: proc(w: ^World, id: SectorId) -> ^Sector {
	index := int(id) - 1
	if id == INVALID_SECTOR_ID || index < 0 || index >= len(w.sectors) do return nil
	return &w.sectors[index]
}

WorldSectorCenter :: proc(w: ^World, id: SectorId) -> Vec2 {
	sector := WorldSectorGet(w, id)
	if sector == nil do return Vec2{}
	return Vec2{sector.bounds.x + sector.bounds.width * 0.5, sector.bounds.y + sector.bounds.height * 0.5}
}

WorldSectorResourceCapacity :: proc(w: ^World, sector_id: SectorId, resource: ResourceType) -> f32 {
	if WorldSectorGet(w, sector_id) == nil do return 0
	capacity: f32 = SECTOR_BASE_STORAGE
	for building in w.buildings {
		if building.destroyed || !building.complete || WorldSectorAtPosition(w, building.pos) != sector_id do continue
		switch building.type {
		case .Headquarters:
			capacity += HQ_STORAGE_BONUS
		case .Warehouse:
			capacity += WAREHOUSE_STORAGE_BONUS
		case .SupplyDepot:
			capacity += DEPOT_STORAGE_BONUS
		case .ResourceSite, .Refinery, .MunitionsFactory, .RouteInfrastructure, .InfantryProduction, .ReinforcementCenter, .ObservationPost, .Defense, .VehicleWorkshop, .EquipmentWorkshop, .ArtilleryEmplacement:
			continue
		}
	}
	return capacity
}

WorldSectorResourceAmount :: proc(w: ^World, sector_id: SectorId, resource: ResourceType) -> f32 {
	sector := WorldSectorGet(w, sector_id)
	if sector == nil do return 0
	return ResourceAmount(sector.inventory, resource)
}

WorldAddSectorResource :: proc(w: ^World, sector_id: SectorId, resource: ResourceType, amount: f32) -> f32 {
	sector := WorldSectorGet(w, sector_id)
	if sector == nil || amount <= 0 do return 0
	current := ResourceAmount(sector.inventory, resource)
	accepted := min(amount, max(0, WorldSectorResourceCapacity(w, sector_id, resource) - current))
	ResourceInventoryAdd(&sector.inventory, resource, accepted)
	return accepted
}

WorldAddResourcesAtPosition :: proc(w: ^World, team: Team, position: Vec2, inventory: ResourceInventory) -> bool {
	sector_id := WorldSectorAtPosition(w, position)
	sector := WorldSectorGet(w, sector_id)
	if sector == nil do return false
	for resource_index: int = 0; resource_index < RESOURCE_TYPE_COUNT; resource_index += 1 {
		resource := ResourceType(resource_index)
		amount := inventory.amounts[resource_index]
		WorldAddSectorResource(w, sector_id, resource, amount)
	}
	return true
}

WorldConsumeResource :: proc(w: ^World, team: Team, sector_id: SectorId, resource: ResourceType, amount: f32) -> f32 {
	if team == .Neutral || amount <= 0 do return 0
	sector := WorldSectorGet(w, sector_id)
	if sector == nil do return 0
	available := ResourceAmount(sector.inventory, resource)
	provided := min(available, amount)
	sector.inventory.amounts[ResourceIndex(resource)] -= provided
	return provided
}


WorldSectorHasResource :: proc(w: ^World, sector_id: SectorId, resource: ResourceType, amount: f32) -> bool {
	return WorldSectorResourceAmount(w, sector_id, resource) >= amount
}

WorldSectorCoordinates :: proc(id: SectorId) -> Vec2 {
	index := int(id) - 1
	return Vec2{f32(index % 4), f32(index / 4)}
}

WorldSectorIdAtCoordinates :: proc(x, y: int) -> SectorId {
	if x < 0 || y < 0 || x >= 4 || y >= 4 do return INVALID_SECTOR_ID
	return SectorId(uint(y * 4 + x + 1))
}

WorldSectorRouteOperational :: proc(w: ^World, sector_id: SectorId, team: Team) -> bool {
	sector := WorldSectorGet(w, sector_id)
	if sector == nil || sector.team != team do return false

	has_infrastructure := false
	for building in w.buildings {
		if building.team != team || building.type != .RouteInfrastructure || WorldSectorAtPosition(w, building.pos) != sector_id do continue
		has_infrastructure = true
		if building.complete && !building.destroyed do return true
	}
	return !has_infrastructure
}

WorldCargoRouteOperational :: proc(w: ^World, cargo: CargoLot) -> bool {
	origin := WorldSectorGet(w, cargo.origin)
	destination := WorldSectorGet(w, cargo.destination)
	if origin == nil || destination == nil do return false
	if !WorldSectorRouteOperational(w, cargo.origin, cargo.team) || !WorldSectorRouteOperational(w, cargo.destination, cargo.team) do return false

	current := WorldSectorCoordinates(cargo.origin)
	target := WorldSectorCoordinates(cargo.destination)
	for current.x != target.x {
		if current.x < target.x {
			current.x += 1
		} else {
			current.x -= 1
		}
		sector_id := WorldSectorIdAtCoordinates(int(current.x), int(current.y))
		if !WorldSectorRouteOperational(w, sector_id, cargo.team) do return false
	}
	for current.y != target.y {
		if current.y < target.y {
			current.y += 1
		} else {
			current.y -= 1
		}
		sector_id := WorldSectorIdAtCoordinates(int(current.x), int(current.y))
		if !WorldSectorRouteOperational(w, sector_id, cargo.team) do return false
	}
	sector_path := WorldFindStrategicSectorPath(w, cargo.origin, cargo.destination, cargo.team, FactionAvoidsRouteDanger(w, cargo.team))
	defer delete(sector_path)
	return len(sector_path) > 0
}

WorldCargoGet :: proc(w: ^World, id: CargoId) -> ^CargoLot {
	for &cargo in w.cargo {
		if cargo.id == id do return &cargo
	}
	return nil
}

WorldConvoyPosition :: proc(w: ^World, convoy: Convoy) -> Vec2 {
	sector_path := WorldFindStrategicSectorPath(w, convoy.origin, convoy.destination, convoy.team, FactionAvoidsRouteDanger(w, convoy.team))
	defer delete(sector_path)
	amount := clamp(convoy.progress / max(0.1, convoy.travel_time), 0, 1)
	if len(sector_path) < 2 {
		origin := WorldSectorCenter(w, convoy.origin)
		destination := WorldSectorCenter(w, convoy.destination)
		return Vec2Lerp(origin, destination, amount)
	}
	scaled := amount * f32(len(sector_path) - 1)
	segment := min(int(scaled), len(sector_path) - 2)
	segment_amount := scaled - f32(segment)
	origin := WorldSectorCenter(w, sector_path[segment])
	destination := WorldSectorCenter(w, sector_path[segment + 1])
	return Vec2Lerp(origin, destination, segment_amount)
}

WorldQueueCargo :: proc(w: ^World, team: Team, resource: ResourceType, amount: f32, origin, destination: SectorId) -> CargoId {
	if team == .Neutral || amount <= 0 || origin == destination do return INVALID_CARGO_ID
	if WorldSectorGet(w, origin) == nil || WorldSectorGet(w, destination) == nil do return INVALID_CARGO_ID
	cargo := CargoLot{INVALID_CARGO_ID, INVALID_CONVOY_ID, team, resource, amount, origin, destination}
	if !WorldCargoRouteOperational(w, cargo) do return INVALID_CARGO_ID
	provided := WorldConsumeResource(w, team, origin, resource, amount)
	if provided <= 0 do return INVALID_CARGO_ID
	sector_path := WorldFindStrategicSectorPath(w, origin, destination, team, FactionAvoidsRouteDanger(w, team))
	defer delete(sector_path)
	if len(sector_path) < 2 do return INVALID_CARGO_ID
	distance := len(sector_path) - 1
	cargo.id = w.next_cargo_id
	w.next_cargo_id += 1
	cargo.quantity = provided
	convoy_id := w.next_convoy_id
	w.next_convoy_id += 1
	cargo.convoy = convoy_id
	vehicle_capacity := FactionConvoyCapacity(w, team)
	vehicle_count := max(1, int((provided + vehicle_capacity - 1) / vehicle_capacity))
	convoy := Convoy{convoy_id, team, resource, cargo.id, origin, destination, 0, max(0.5, f32(distance) * CARGO_BASE_TRAVEL_TIME), 0, vehicle_count, f32(vehicle_count) * vehicle_capacity, FactionConvoySpeed(w, team), FactionConvoyFuel(w, team), FactionConvoyHealth(w, team), .Traveling}
	append(&w.cargo, cargo)
	append(&w.convoys, convoy)
	return cargo.id
}

WorldRequestResourceStockpile :: proc(w: ^World, team: Team, sector_id: SectorId, resource: ResourceType, amount: f32) -> bool {
	sector := WorldSectorGet(w, sector_id)
	if team == .Neutral || sector == nil || amount <= 0 do return false
	sector.requested.amounts[ResourceIndex(resource)] = max(sector.requested.amounts[ResourceIndex(resource)], amount)
	return true
}

WorldResourceInTransit :: proc(w: ^World, team: Team, sector_id: SectorId, resource: ResourceType) -> f32 {
	amount: f32
	for cargo in w.cargo {
		if cargo.team == team && cargo.destination == sector_id && cargo.resource == resource do amount += cargo.quantity
	}
	return amount
}

WorldSectorLogisticsDemand :: proc(w: ^World, sector_id: SectorId, resource: ResourceType) -> f32 {
	sector := WorldSectorGet(w, sector_id)
	if sector == nil do return 0
	demand := ResourceAmount(sector.requested, resource)
	for building in w.buildings {
		if building.destroyed || !building.complete || building.queue <= 0 || building.team != sector.team do continue
		if WorldSectorAtPosition(w, building.pos) != sector_id do continue
		cost := BuildingProductionCostForTeam(w, building.team, building.production)
		demand += cost.amounts[ResourceIndex(resource)] * f32(building.queue)
	}
	return demand
}

WorldFindCargoSource :: proc(w: ^World, team: Team, resource: ResourceType, destination: SectorId) -> SectorId {
	best := INVALID_SECTOR_ID
	best_distance := 999999
	destination_pos := WorldSectorCoordinates(destination)
	for sector in w.sectors {
		if sector.id == destination || sector.team != team do continue
		available := ResourceAmount(sector.inventory, resource) - 100
		if available <= 0 do continue
		candidate := CargoLot{INVALID_CARGO_ID, INVALID_CONVOY_ID, team, resource, available, sector.id, destination}
		if !WorldCargoRouteOperational(w, candidate) do continue
		position := WorldSectorCoordinates(sector.id)
		distance := abs(int(position.x - destination_pos.x)) + abs(int(position.y - destination_pos.y))
		if distance < best_distance {
			best = sector.id
			best_distance = distance
		}
	}
	return best
}

WorldAssignCargo :: proc(w: ^World) {
	for &destination in w.sectors {
		if destination.team == .Neutral do continue
		for resource_index: int = 0; resource_index < RESOURCE_TYPE_COUNT; resource_index += 1 {
			resource := ResourceType(resource_index)
			demand := WorldSectorLogisticsDemand(w, destination.id, resource)
			current := ResourceAmount(destination.inventory, resource) + WorldResourceInTransit(w, destination.team, destination.id, resource)
			deficit := demand - current
			if deficit <= 1 do continue
			origin := WorldFindCargoSource(w, destination.team, resource, destination.id)
			if origin == INVALID_SECTOR_ID do continue
			WorldQueueCargo(w, destination.team, resource, min(deficit, 100), origin, destination.id)
		}
	}
}

WorldConvoyGet :: proc(w: ^World, id: ConvoyId) -> ^Convoy {
	for &convoy in w.convoys {
		if convoy.id == id do return &convoy
	}
	return nil
}

WorldConvoyIsEscorted :: proc(w: ^World, convoy: Convoy) -> bool {
	for squad in w.squads {
		if squad.intent != .Escort || squad.convoy != convoy.id || !SquadIsAlive(w, squad.id) do continue
		if Vec2Length(Vec2Sub(WorldSquadLeaderPosition(w, squad), WorldConvoyPosition(w, convoy))) <= 12 do return true
	}
	return false
}

WorldUpdateConvoyRaids :: proc(w: ^World, dt: f32) {
	for &convoy in w.convoys {
		if convoy.state == .Destroyed do continue
		escorted := WorldConvoyIsEscorted(w, convoy)
		for squad in w.squads {
			if squad.intent != .Raid || squad.convoy != convoy.id || squad.team == convoy.team || !SquadIsAlive(w, squad.id) do continue
			if Vec2Length(Vec2Sub(WorldSquadLeaderPosition(w, squad), WorldConvoyPosition(w, convoy))) > 12 do continue
			damage := f32(18) * dt
			if escorted do damage *= 0.35
			ConvoyDamage(&convoy, damage)
		}
	}
}

WorldHasIsolatedSquad :: proc(w: ^World) -> bool {
	for squad in w.squads {
		if !SquadIsAlive(w, squad.id) do continue
		for unit_id in squad.units {
			unit := UnitGet(w, unit_id)
			if unit != nil && UnitIsAlive(unit^) && !WorldCanResupply(w, unit^) do return true
		}
	}
	return false
}

WorldHasIsolatedBuilding :: proc(w: ^World) -> bool {
	for building in w.buildings {
		if building.destroyed || !building.complete || building.type == .Headquarters || building.type == .RouteInfrastructure do continue
		if !WorldSectorSupplied(w, WorldSectorAtPosition(w, building.pos), building.team) do return true
	}
	return false
}

WorldCargoIndex :: proc(w: ^World, id: CargoId) -> int {
	for cargo, index in w.cargo {
		if cargo.id == id do return index
	}
	return -1
}

WorldRemoveCargo :: proc(w: ^World, index: int) {
	last := len(w.cargo) - 1
	w.cargo[index] = w.cargo[last]
	resize(&w.cargo, last)
}

WorldRemoveConvoy :: proc(w: ^World, index: int) {
	last := len(w.convoys) - 1
	w.convoys[index] = w.convoys[last]
	resize(&w.convoys, last)
}

ConvoyDamage :: proc(convoy: ^Convoy, damage: f32) {
	if damage <= 0 || convoy.state == .Destroyed do return
	convoy.health = max(f32(0), convoy.health - damage)
	if convoy.health <= 0 {
		convoy.state = .Destroyed
	}
}

WorldHasBlockedConvoy :: proc(w: ^World) -> bool {
	for convoy in w.convoys {
		if convoy.state == .Blocked do return true
	}
	return false
}

WorldUpdateConvoys :: proc(w: ^World, dt: f32) {
	index := 0
	for index < len(w.convoys) {
		convoy := &w.convoys[index]
		cargo_index := WorldCargoIndex(w, convoy.cargo)
		if cargo_index < 0 {
			WorldRemoveConvoy(w, index)
			continue
		}
		cargo := &w.cargo[cargo_index]
		if convoy.state == .Destroyed {
			w.cargo_lost += cargo.quantity
			ArtilleryAddEffect(w, .Wreck, WorldConvoyPosition(w, convoy^), 20, 2 + f32(convoy.vehicle_count))
			WorldRemoveCargo(w, cargo_index)
			WorldRemoveConvoy(w, index)
			continue
		}
		if !WorldCargoRouteOperational(w, cargo^) {
			convoy.state = .Blocked
			convoy.blocked_time += dt
			if convoy.blocked_time < CARGO_BLOCKED_LOSS_TIME {
				index += 1
				continue
			}
			w.cargo_lost += cargo.quantity
			ArtilleryAddEffect(w, .Wreck, WorldConvoyPosition(w, convoy^), 20, 2 + f32(convoy.vehicle_count))
			WorldRemoveCargo(w, cargo_index)
			WorldRemoveConvoy(w, index)
			continue
		}
		convoy.state = .Traveling
		sector_path := WorldFindStrategicSectorPath(w, convoy.origin, convoy.destination, convoy.team, FactionAvoidsRouteDanger(w, convoy.team))
		if len(sector_path) > 1 do convoy.travel_time = max(convoy.progress, WorldStrategicPathTravelTime(sector_path[:]))
		delete(sector_path)
		convoy.progress += dt * convoy.speed
		convoy.fuel = max(0, convoy.fuel - dt * f32(convoy.vehicle_count) * 0.1)
		if convoy.progress < convoy.travel_time {
			index += 1
			continue
		}
		accepted := WorldAddSectorResource(w, cargo.destination, cargo.resource, cargo.quantity)
		cargo.quantity -= accepted
		if cargo.quantity > 0 {
			convoy.progress = convoy.travel_time
			index += 1
			continue
		}
		WorldRemoveCargo(w, cargo_index)
		WorldRemoveConvoy(w, index)
	}
}

WorldUpdateLogistics :: proc(w: ^World, dt: f32) {
	WorldUpdateConvoyRaids(w, dt)
	WorldUpdateConvoys(w, dt)
	WorldAssignCargo(w)
}
