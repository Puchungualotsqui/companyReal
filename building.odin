package main

BuildingStats :: struct {
	health: f32,
	build_time: f32,
}

BuildingStatsGet :: proc(type: BuildingType) -> BuildingStats {
	switch type {
	case .Headquarters:
		return BuildingStats{1000, 0}
	case .ResourceSite:
		return BuildingStats{250, 6}
	case .Refinery:
		return BuildingStats{450, 10}
	case .MunitionsFactory:
		return BuildingStats{450, 10}
	case .Warehouse:
		return BuildingStats{350, 8}
	case .RouteInfrastructure:
		return BuildingStats{300, 8}
	case .InfantryProduction:
		return BuildingStats{400, 8}
	case .SupplyDepot:
		return BuildingStats{300, 6}
	case .ReinforcementCenter:
		return BuildingStats{350, 7}
	case .ObservationPost:
		return BuildingStats{200, 5}
	case .Defense:
		return BuildingStats{500, 10}
	case .VehicleWorkshop:
		return BuildingStats{600, 12}
	case .EquipmentWorkshop:
		return BuildingStats{450, 10}
	case .ArtilleryEmplacement:
		return BuildingStats{450, 10}
	}
	unreachable()
}

BuildingGet :: proc(w: ^World, id: BuildingId) -> ^Building {
	index := BuildingIndex(id)
	if id == INVALID_BUILDING_ID || index < 0 || index >= len(w.buildings) do return nil
	return &w.buildings[index]
}


WorldSectorAtPosition :: proc(w: ^World, position: Vec2) -> SectorId {
	for sector in w.sectors {
		if position.x >= sector.bounds.x && position.x < sector.bounds.x + sector.bounds.width && position.y >= sector.bounds.y && position.y < sector.bounds.y + sector.bounds.height do return sector.id
	}
	return INVALID_SECTOR_ID
}

BuildingPlace :: proc(w: ^World, team: Team, type: BuildingType, pos: Vec2, owner := INVALID_PLAYER_ID, resource := ResourceType.Materials) -> BuildingId {
	stats := BuildingStatsGetForTeam(w, team, type)
	id := BuildingId(uint(len(w.buildings) + 1))
	building := Building{id, owner, team, type, Vec2Clamp(pos, Vec2{}, w.max_size), stats.health, stats.health, stats.build_time, stats.build_time, true, false, INVALID_SQUAD_ID, .Line, resource, 0, 0}
	append(&w.buildings, building)
	if type == .Headquarters {
		WorldAddResourcesAtPosition(w, team, building.pos, ResourceInventoryMake(500, 500, 500))
	}
	return id
}

BuildingConstructForPlayer :: proc(w: ^World, player: PlayerId, squad_id: SquadId, type: BuildingType, pos: Vec2) -> BuildingId {
	squad := SquadGet(w, squad_id)
	if squad == nil || squad.owner != player || squad.type != .Engineer || !SquadIsAlive(w, squad_id) do return INVALID_BUILDING_ID
	cost := ResourceInventoryMake(25, 0, 0)
	if WorldSectorGet(w, WorldSectorAtPosition(w, pos)) == nil do return INVALID_BUILDING_ID
	sector := WorldSectorGet(w, WorldSectorAtPosition(w, pos))
	if !ResourceInventoryCanAfford(sector.inventory, cost) do return INVALID_BUILDING_ID
	ResourceInventoryConsume(&sector.inventory, cost)
	stats := BuildingStatsGetForTeam(w, squad.team, type)
	id := BuildingId(uint(len(w.buildings) + 1))
	building := Building{id, player, squad.team, type, Vec2Clamp(pos, Vec2{}, w.max_size), stats.health, stats.health, 0, stats.build_time, false, false, squad_id, .Line, .Materials, 0, 0}
	append(&w.buildings, building)
	return id
}

BuildingCanProduce :: proc(building: BuildingType, unit: UnitType) -> bool {
	switch building {
	case .Headquarters, .ResourceSite, .Refinery, .MunitionsFactory, .Warehouse, .RouteInfrastructure, .SupplyDepot, .ReinforcementCenter, .ObservationPost, .Defense:
		return false
	case .InfantryProduction:
		switch unit {
		case .Line, .Assault, .Heavy, .Scout, .Engineer:
			return true
		case .Vehicle, .Equipment, .Artillery:
			return false
		}
	case .VehicleWorkshop:
		return unit == .Vehicle
	case .EquipmentWorkshop:
		return unit == .Equipment
	case .ArtilleryEmplacement:
		return unit == .Artillery
	}
	unreachable()
}

BuildingProductionTime :: proc(unit: UnitType) -> f32 {
	switch unit {
	case .Line, .Assault, .Scout, .Engineer:
		return 4
	case .Heavy:
		return 6
	case .Vehicle:
		return 12
	case .Equipment:
		return 8
	case .Artillery:
		return 10
	}
	unreachable()
}

BuildingProductionCost :: proc(unit: UnitType) -> ResourceInventory {
	switch unit {
	case .Line, .Assault, .Scout, .Engineer:
		return ResourceInventoryMake(15, 0, 4)
	case .Heavy:
		return ResourceInventoryMake(25, 0, 8)
	case .Vehicle:
		return ResourceInventoryMake(80, 20, 10)
	case .Equipment:
		return ResourceInventoryMake(45, 5, 12)
	case .Artillery:
		return ResourceInventoryMake(60, 5, 15)
	}
	unreachable()
}

BuildingProductionCount :: proc(unit: UnitType) -> int {
	switch unit {
	case .Line, .Assault, .Scout, .Engineer:
		return 4
	case .Heavy, .Vehicle, .Equipment, .Artillery:
		return 1
	}
	unreachable()
}

BuildingQueueForPlayer :: proc(w: ^World, player: PlayerId, id: BuildingId, unit: UnitType) -> bool {
	building := BuildingGet(w, id)
	if building == nil || !building.complete || building.owner != player do return false
	if !BuildingCanProduce(building.type, unit) || building.queue >= 4 do return false
	if building.queue == 0 do building.production = unit
	if building.production != unit do return false
	building.queue += 1
	return true
}

WorldSectorHasBuilding :: proc(w: ^World, sector_id: SectorId, team: Team, type: BuildingType) -> bool {
	for building in w.buildings {
		if building.complete && !building.destroyed && building.team == team && building.type == type && WorldSectorAtPosition(w, building.pos) == sector_id do return true
	}
	return false
}

WorldSectorSupplied :: proc(w: ^World, sector_id: SectorId, team: Team) -> bool {
	if sector_id == INVALID_SECTOR_ID || team == .Neutral do return false
	visited: [64]bool
	queue := make([dynamic]SectorId)
	defer delete(queue)
	for building in w.buildings {
		if building.complete && !building.destroyed && building.team == team && building.type == .Headquarters {
			root := WorldSectorAtPosition(w, building.pos)
			if root != INVALID_SECTOR_ID && !visited[int(root) - 1] {
				visited[int(root) - 1] = true
				append(&queue, root)
			}
		}
	}
	head := 0
	for head < len(queue) {
		current := queue[head]
		head += 1
		if current == sector_id do return true
		current_index := int(current) - 1
		current_x := current_index % 4
		current_y := current_index / 4
		for neighbor in w.sectors {
			neighbor_index := int(neighbor.id) - 1
			neighbor_x := neighbor_index % 4
			neighbor_y := neighbor_index / 4
			distance := abs(current_x - neighbor_x) + abs(current_y - neighbor_y)
			if distance != 1 || neighbor.team != team || visited[neighbor_index] do continue
			visited[neighbor_index] = true
			append(&queue, neighbor.id)
		}
	}
	return false
}

WorldBuildingOperational :: proc(w: ^World, building: Building) -> bool {
	if !building.complete || building.destroyed do return false
	switch building.type {
	case .Headquarters:
		return true
	case .RouteInfrastructure:
		return true
	case .ResourceSite, .Refinery, .MunitionsFactory, .Warehouse, .InfantryProduction, .SupplyDepot, .ReinforcementCenter, .ObservationPost, .Defense, .VehicleWorkshop, .EquipmentWorkshop, .ArtilleryEmplacement:
		return WorldSectorSupplied(w, WorldSectorAtPosition(w, building.pos), building.team)
	}
	unreachable()
}

WorldCanObserve :: proc(w: ^World, team: Team, position: Vec2) -> bool {
	for building in w.buildings {
		if !building.complete || building.destroyed || building.team != team do continue
		range := f32(0)
		switch building.type {
		case .Headquarters:
			range = FactionObservationRange(w, team, 24)
		case .ObservationPost:
			range = FactionObservationRange(w, team, 48)
		case .ResourceSite, .Refinery, .MunitionsFactory, .Warehouse, .RouteInfrastructure, .InfantryProduction, .SupplyDepot, .ReinforcementCenter, .Defense, .VehicleWorkshop, .EquipmentWorkshop, .ArtilleryEmplacement:
			continue
		}
		if Vec2Length(Vec2Sub(position, building.pos)) <= range do return true
	}
	return false
}

WorldDefenseCover :: proc(w: ^World, position: Vec2, team: Team) -> f32 {
	for building in w.buildings {
		if building.complete && building.team == team && building.type == .Defense && Vec2Length(Vec2Sub(position, building.pos)) <= 10 do return FactionDefenseCover(w, team)
	}
	return 0
}

WorldUpdateBuildings :: proc(w: ^World, dt: f32) {
	for &building in w.buildings {
		if building.destroyed do continue
		if !building.complete {
			builders := 0
			squad := SquadGet(w, building.builder)
			if squad != nil {
				for unit_id in squad.units {
					unit := UnitGet(w, unit_id)
					if unit != nil && UnitIsAlive(unit^) && unit.type == .Engineer && Vec2Length(Vec2Sub(unit.pos, building.pos)) <= 8 do builders += 1
				}
			}
			building.build_progress += dt * f32(builders)
			if building.build_progress >= building.build_time {
				building.build_progress = building.build_time
				building.complete = true
			}
			continue
		}
		sector_id := WorldSectorAtPosition(w, building.pos)
		if !WorldBuildingOperational(w, building) do continue
		sector := WorldSectorGet(w, sector_id)
		if sector == nil do continue

		switch building.type {
		case .ResourceSite:
			WorldAddSectorResource(w, sector_id, building.resource, dt * 4 * FactionResourceOutputRate(w, building.team, building.type))
		case .Refinery:
			input := ResourceInventoryMake(dt * 0.5, 0, 0)
			if ResourceInventoryConsume(&sector.inventory, input) do WorldAddSectorResource(w, sector_id, .Fuel, dt * FactionResourceOutputRate(w, building.team, building.type))
		case .MunitionsFactory:
			input := ResourceInventoryMake(dt * 0.75, dt * 0.25, 0)
			if ResourceInventoryConsume(&sector.inventory, input) do WorldAddSectorResource(w, sector_id, .Munitions, dt * FactionResourceOutputRate(w, building.team, building.type))
		case .Headquarters, .Warehouse, .RouteInfrastructure, .InfantryProduction, .SupplyDepot, .ReinforcementCenter, .ObservationPost, .Defense, .VehicleWorkshop, .EquipmentWorkshop, .ArtilleryEmplacement:
			building.production_timer += 0
		}

		if building.queue <= 0 do continue
		building.production_timer += dt
		if building.production_timer < BuildingProductionTimeForTeam(w, building.team, building.production) do continue
		cost := BuildingProductionCostForTeam(w, building.team, building.production)
		if !ResourceInventoryConsume(&sector.inventory, cost) do continue
		count := BuildingProductionCountForTeam(w, building.team, building.production)
		SquadSpawn(w, building.team, building.production, count, building.pos, building.owner)
		building.queue -= 1
		building.production_timer = 0
	}
}

BuildingDefaultChar :: proc(type: BuildingType) -> rune {
	switch type {
	case .Headquarters:
		return 'H'
	case .ResourceSite:
		return 'M'
	case .Refinery:
		return 'F'
	case .MunitionsFactory:
		return 'A'
	case .Warehouse:
		return 'W'
	case .RouteInfrastructure:
		return 'T'
	case .InfantryProduction:
		return 'I'
	case .SupplyDepot:
		return 'S'
	case .ReinforcementCenter:
		return 'R'
	case .ObservationPost:
		return 'O'
	case .Defense:
		return 'D'
	case .VehicleWorkshop:
		return 'V'
	case .EquipmentWorkshop:
		return 'E'
	case .ArtilleryEmplacement:
		return 'A'
	}
	unreachable()
}
