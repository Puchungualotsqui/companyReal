package main

Faction :: enum u8 {
	BastionDirectorate,
	FreeMarches,
	EmberSyndicate,
	MeridianCombine,
	HearthUnion,
}

FactionProfile :: struct {
	name: cstring,
	unit_health: f32,
	unit_speed: f32,
	unit_range: f32,
	unit_damage: f32,
	unit_cooldown: f32,
	unit_ammo: f32,
	building_health: f32,
	building_time: f32,
	production_time: f32,
	cost_materials: f32,
	cost_fuel: f32,
	cost_munitions: f32,
	infantry_count_bonus: int,
	convoy_capacity: f32,
	convoy_speed: f32,
	convoy_fuel: f32,
	convoy_health: f32,
	avoid_route_danger: bool,
	observation_range: f32,
	defense_cover: f32,
	refinery_output: f32,
	munitions_output: f32,
}

FactionProfileGet :: proc(faction: Faction) -> FactionProfile {
	switch faction {
	case .BastionDirectorate:
		return FactionProfile{
			name = "BASTION DIRECTORATE",
			unit_health = 1.15,
			unit_speed = 0.88,
			unit_range = 1.10,
			unit_damage = 1.10,
			unit_cooldown = 1.0,
			unit_ammo = 1.0,
			building_health = 1.25,
			building_time = 1.10,
			production_time = 1.0,
			cost_materials = 1.0,
			cost_fuel = 1.0,
			cost_munitions = 1.0,
			infantry_count_bonus = 0,
			convoy_capacity = 1.0,
			convoy_speed = 1.0,
			convoy_fuel = 1.0,
			convoy_health = 1.0,
			avoid_route_danger = true,
			observation_range = 1.0,
			defense_cover = 0.35,
			refinery_output = 1.0,
			munitions_output = 1.10,
		}
	case .FreeMarches:
		return FactionProfile{
			name = "FREE MARCHES",
			unit_health = 0.90,
			unit_speed = 1.18,
			unit_range = 1.10,
			unit_damage = 0.95,
			unit_cooldown = 0.95,
			unit_ammo = 1.0,
			building_health = 0.85,
			building_time = 0.80,
			production_time = 0.90,
			cost_materials = 0.90,
			cost_fuel = 0.95,
			cost_munitions = 1.0,
			infantry_count_bonus = 0,
			convoy_capacity = 0.85,
			convoy_speed = 1.30,
			convoy_fuel = 1.20,
			convoy_health = 0.80,
			avoid_route_danger = false,
			observation_range = 1.15,
			defense_cover = 0.25,
			refinery_output = 1.0,
			munitions_output = 1.0,
		}
	case .EmberSyndicate:
		return FactionProfile{
			name = "EMBER SYNDICATE",
			unit_health = 0.95,
			unit_speed = 1.0,
			unit_range = 0.95,
			unit_damage = 1.20,
			unit_cooldown = 0.95,
			unit_ammo = 1.10,
			building_health = 0.90,
			building_time = 0.90,
			production_time = 0.95,
			cost_materials = 1.0,
			cost_fuel = 0.90,
			cost_munitions = 1.15,
			infantry_count_bonus = 0,
			convoy_capacity = 1.0,
			convoy_speed = 0.95,
			convoy_fuel = 0.85,
			convoy_health = 0.90,
			avoid_route_danger = true,
			observation_range = 0.90,
			defense_cover = 0.30,
			refinery_output = 1.0,
			munitions_output = 1.30,
		}
	case .MeridianCombine:
		return FactionProfile{
			name = "MERIDIAN COMBINE",
			unit_health = 0.88,
			unit_speed = 1.05,
			unit_range = 1.30,
			unit_damage = 1.12,
			unit_cooldown = 0.90,
			unit_ammo = 0.90,
			building_health = 0.90,
			building_time = 1.05,
			production_time = 1.0,
			cost_materials = 1.10,
			cost_fuel = 1.05,
			cost_munitions = 0.90,
			infantry_count_bonus = 0,
			convoy_capacity = 1.05,
			convoy_speed = 1.0,
			convoy_fuel = 1.0,
			convoy_health = 0.90,
			avoid_route_danger = true,
			observation_range = 1.50,
			defense_cover = 0.30,
			refinery_output = 1.0,
			munitions_output = 1.10,
		}
	case .HearthUnion:
		return FactionProfile{
			name = "HEARTH UNION",
			unit_health = 1.10,
			unit_speed = 0.95,
			unit_range = 1.0,
			unit_damage = 0.98,
			unit_cooldown = 1.05,
			unit_ammo = 1.10,
			building_health = 1.05,
			building_time = 1.0,
			production_time = 0.95,
			cost_materials = 0.90,
			cost_fuel = 0.90,
			cost_munitions = 0.90,
			infantry_count_bonus = 1,
			convoy_capacity = 1.30,
			convoy_speed = 0.90,
			convoy_fuel = 1.0,
			convoy_health = 1.10,
			avoid_route_danger = true,
			observation_range = 1.0,
			defense_cover = 0.40,
			refinery_output = 1.15,
			munitions_output = 1.05,
		}
	}
	unreachable()
}

FactionName :: proc(faction: Faction) -> cstring {
	return FactionProfileGet(faction).name
}

WorldTeamFaction :: proc(w: ^World, team: Team) -> Faction {
	return w.factions[TeamIndex(team)]
}

WorldSetTeamFaction :: proc(w: ^World, team: Team, faction: Faction) -> bool {
	if team == .Neutral do return false
	w.factions[TeamIndex(team)] = faction
	return true
}

UnitStatsGetForTeam :: proc(w: ^World, team: Team, type: UnitType) -> UnitStats {
	profile := FactionProfileGet(WorldTeamFaction(w, team))
	stats := UnitStatsGet(type)
	stats.health *= profile.unit_health
	stats.speed *= profile.unit_speed
	stats.range *= profile.unit_range
	stats.damage *= profile.unit_damage
	stats.cooldown *= profile.unit_cooldown
	stats.ammo *= profile.unit_ammo
	return stats
}

BuildingStatsGetForTeam :: proc(w: ^World, team: Team, type: BuildingType) -> BuildingStats {
	profile := FactionProfileGet(WorldTeamFaction(w, team))
	stats := BuildingStatsGet(type)
	stats.health *= profile.building_health
	stats.build_time *= profile.building_time
	return stats
}

BuildingProductionTimeForTeam :: proc(w: ^World, team: Team, unit: UnitType) -> f32 {
	return BuildingProductionTime(unit) * FactionProfileGet(WorldTeamFaction(w, team)).production_time
}

BuildingProductionCostForTeam :: proc(w: ^World, team: Team, unit: UnitType) -> ResourceInventory {
	profile := FactionProfileGet(WorldTeamFaction(w, team))
	cost := BuildingProductionCost(unit)
	cost.amounts[ResourceIndex(.Materials)] *= profile.cost_materials
	cost.amounts[ResourceIndex(.Fuel)] *= profile.cost_fuel
	cost.amounts[ResourceIndex(.Munitions)] *= profile.cost_munitions
	return cost
}

BuildingProductionCountForTeam :: proc(w: ^World, team: Team, unit: UnitType) -> int {
	count := BuildingProductionCount(unit)
	profile := FactionProfileGet(WorldTeamFaction(w, team))
	if unit == .Line || unit == .Assault || unit == .Scout || unit == .Engineer do count += profile.infantry_count_bonus
	return count
}

FactionResourceOutputRate :: proc(w: ^World, team: Team, type: BuildingType) -> f32 {
	profile := FactionProfileGet(WorldTeamFaction(w, team))
	switch type {
	case .Refinery:
		return profile.refinery_output
	case .MunitionsFactory:
		return profile.munitions_output
	case .ResourceSite:
		return 1
	case .Headquarters, .Warehouse, .RouteInfrastructure, .InfantryProduction, .SupplyDepot, .ReinforcementCenter, .ObservationPost, .Defense, .VehicleWorkshop, .EquipmentWorkshop, .ArtilleryEmplacement:
		return 1
	}
	unreachable()
}

FactionCounterMultiplier :: proc(w: ^World, attacker, target: Unit) -> f32 {
	faction := WorldTeamFaction(w, attacker.team)
	switch faction {
	case .BastionDirectorate:
		if (attacker.type == .Heavy || attacker.type == .Vehicle) && (target.type == .Vehicle || target.type == .Heavy) do return 1.35
	case .FreeMarches:
		if (attacker.type == .Scout || attacker.type == .Assault) && (target.type == .Artillery || target.type == .Equipment) do return 1.35
	case .EmberSyndicate:
		if attacker.type == .Assault && (target.type == .Vehicle || target.type == .Heavy) do return 1.30
	case .MeridianCombine:
		if (attacker.type == .Equipment || attacker.type == .Artillery) && (target.type == .Vehicle || target.type == .Artillery) do return 1.40
	case .HearthUnion:
		if (attacker.type == .Line || attacker.type == .Heavy) && target.type == .Assault do return 1.25
	}
	return 1
}

FactionConvoyCapacity :: proc(w: ^World, team: Team) -> f32 {
	return CONVOY_VEHICLE_CAPACITY * FactionProfileGet(WorldTeamFaction(w, team)).convoy_capacity
}

FactionConvoySpeed :: proc(w: ^World, team: Team) -> f32 {
	return FactionProfileGet(WorldTeamFaction(w, team)).convoy_speed
}

FactionConvoyFuel :: proc(w: ^World, team: Team) -> f32 {
	return CONVOY_STARTING_FUEL * FactionProfileGet(WorldTeamFaction(w, team)).convoy_fuel
}

FactionConvoyHealth :: proc(w: ^World, team: Team) -> f32 {
	return CONVOY_HEALTH * FactionProfileGet(WorldTeamFaction(w, team)).convoy_health
}

FactionAvoidsRouteDanger :: proc(w: ^World, team: Team) -> bool {
	return FactionProfileGet(WorldTeamFaction(w, team)).avoid_route_danger
}

FactionObservationRange :: proc(w: ^World, team: Team, base: f32) -> f32 {
	return base * FactionProfileGet(WorldTeamFaction(w, team)).observation_range
}

FactionDefenseCover :: proc(w: ^World, team: Team) -> f32 {
	return FactionProfileGet(WorldTeamFaction(w, team)).defense_cover
}
