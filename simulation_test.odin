package main

import "core:testing"

@(test)
SimulationFixedTick :: proc(t: ^testing.T) {
	world: World
	WorldInit(&world)
	defer WorldDeinit(&world)

	WorldStep(&world)
	testing.expect_value(t, world.tick, u64(1))
	testing.expect_value(t, world.time, world.step)

	WorldUpdate(&world, world.step * 2)
	testing.expect_value(t, world.tick, u64(3))
}

@(test)
SimulationMovementIsBounded :: proc(t: ^testing.T) {
	world: World
	WorldInit(&world)
	defer WorldDeinit(&world)

	squad_id := SquadSpawn(&world, .A, .Line, 1, Vec2{2, 2})
	SquadSetOrder(&world, squad_id, Order{.Move, Vec2{300, 300}, INVALID_UNIT_ID})
	for index: int = 0; index < 300; index += 1 do WorldStep(&world)

	unit := UnitGet(&world, SquadGet(&world, squad_id).units[0])
	testing.expect(t, unit.pos.x <= world.max_size.x && unit.pos.y <= world.max_size.y, "unit exceeded world bounds")
	testing.expect(t, unit.pos.x >= 250 && unit.pos.y >= 250, "unit did not reach the bounded target")
}

@(test)
SimulationCombatKillsAndStopsSquad :: proc(t: ^testing.T) {
	world: World
	WorldInit(&world)
	defer WorldDeinit(&world)

	attacker_squad := SquadSpawn(&world, .A, .Heavy, 1, Vec2{10, 10})
	target_squad := SquadSpawn(&world, .B, .Scout, 1, Vec2{10, 10})
	attacker := SquadGet(&world, attacker_squad)
	target := SquadGet(&world, target_squad)
	SquadSetOrder(&world, attacker_squad, Order{.Attack, Vec2{}, target.units[0]})
	SquadSetOrder(&world, target_squad, Order{.Attack, Vec2{}, attacker.units[0]})
	for index: int = 0; index < 100; index += 1 do WorldStep(&world)

	attacker_unit := UnitGet(&world, attacker.units[0])
	target_unit := UnitGet(&world, target.units[0])
	testing.expect(t, UnitIsAlive(attacker_unit^), "heavy unit died first")
	testing.expect(t, !UnitIsAlive(target_unit^), "target unit survived combat")
	testing.expect(t, !SquadIsAlive(&world, target_squad), "dead squad remained active")
	testing.expect_value(t, SquadGet(&world, target_squad).order.type, OrderType.Idle)
}

@(test)
SimulationSectorCaptures :: proc(t: ^testing.T) {
	world: World
	WorldInit(&world)
	defer WorldDeinit(&world)

	SquadSpawn(&world, .A, .Line, 1, Vec2{10, 10})
	for index: int = 0; index < 100; index += 1 do WorldStep(&world)

	testing.expect_value(t, world.sectors[0].team, Team.A)
}

@(test)
CommandOwnershipControlsOrders :: proc(t: ^testing.T) {
	world: World
	WorldInit(&world)
	defer WorldDeinit(&world)

	owned_squad := SquadSpawn(&world, .A, .Line, 1, Vec2{4, 4}, LOCAL_PLAYER_ID)
	other_squad := SquadSpawn(&world, .B, .Line, 1, Vec2{8, 4}, PLAYER_TWO_ID)
	target := SquadGet(&world, other_squad).units[0]

	testing.expect(t, SquadSetMoveForPlayer(&world, LOCAL_PLAYER_ID, owned_squad, Vec2{6, 6}), "owner could not move squad")
	testing.expect(t, !SquadSetMoveForPlayer(&world, PLAYER_TWO_ID, owned_squad, Vec2{10, 10}), "other player moved squad")
	testing.expect(t, SquadSetAttackForPlayer(&world, LOCAL_PLAYER_ID, owned_squad, target), "owner could not attack enemy")
	testing.expect(t, !SquadSetAttackForPlayer(&world, PLAYER_TWO_ID, owned_squad, target), "other player attacked with squad")
}

@(test)
CombatUsesAmmoSuppressionAndTargets :: proc(t: ^testing.T) {
	world: World
	WorldInit(&world)
	defer WorldDeinit(&world)

	attacker_squad := SquadSpawn(&world, .A, .Heavy, 1, Vec2{10, 10})
	first_target_squad := SquadSpawn(&world, .B, .Line, 1, Vec2{10, 10})
	second_target_squad := SquadSpawn(&world, .B, .Scout, 1, Vec2{10, 10})
	attacker := UnitGet(&world, SquadGet(&world, attacker_squad).units[0])
	first_target := UnitGet(&world, SquadGet(&world, first_target_squad).units[0])
	second_target := UnitGet(&world, SquadGet(&world, second_target_squad).units[0])
	ammo := attacker.ammo

	SquadSetOrder(&world, attacker_squad, Order{.Attack, Vec2{}, first_target.id})
	WorldStep(&world)
	testing.expect(t, attacker.ammo < ammo, "attack did not consume ammo")
	testing.expect(t, first_target.suppression > 0, "attack did not apply suppression")

	UnitDamage(&world, first_target, 1000, 0)
	WorldStep(&world)
	testing.expect_value(t, attacker.order.target, second_target.id)
}

@(test)
CombatCoverAndTerrainChangeResults :: proc(t: ^testing.T) {
	world: World
	WorldInit(&world)
	defer WorldDeinit(&world)

	squad_id := SquadSpawn(&world, .A, .Line, 1, Vec2{40, 40})
	unit := UnitGet(&world, SquadGet(&world, squad_id).units[0])
	open_speed := UnitMoveSpeed(&world, unit^)
	WorldSetTerrainCell(&world, 2, 2, .Rough)
	rough_speed := UnitMoveSpeed(&world, unit^)
	testing.expect(t, rough_speed < open_speed, "rough terrain did not slow movement")

	target_squad := SquadSpawn(&world, .B, .Line, 1, Vec2{40, 40})
	target := UnitGet(&world, SquadGet(&world, target_squad).units[0])
	WorldSetTerrainCell(&world, 2, 2, .Open)
	UnitDamage(&world, target, 40, 0)
	open_damage := target.max_health - target.health
	target.health = target.max_health
	WorldSetTerrainCell(&world, 2, 2, .HeavyCover)
	UnitDamage(&world, target, 40, 0)
	heavy_cover_damage := target.max_health - target.health
	testing.expect(t, heavy_cover_damage < open_damage, "cover did not reduce damage")
}

@(test)
CombatRetreatsRecoversAndReinforces :: proc(t: ^testing.T) {
	world: World
	WorldInit(&world)
	defer WorldDeinit(&world)

	WorldAddResourcesAtPosition(&world, .A, Vec2{4, 4}, ResourceInventoryMake(250, 0, 100))
	squad_id := SquadSpawn(&world, .A, .Line, 1, Vec2{20, 20})
	unit := UnitGet(&world, SquadGet(&world, squad_id).units[0])
	unit.morale = 0.1
	WorldStep(&world)
	testing.expect_value(t, unit.state, UnitState.Retreating)
	testing.expect_value(t, unit.order.type, OrderType.Retreat)

	WorldSetTerrainCell(&world, 0, 0, .Open)
	unit.pos = Vec2{4, 4}
	UnitDamage(&world, unit, 75, 0)
	testing.expect_value(t, unit.state, UnitState.Wounded)
	for index: int = 0; index < 100; index += 1 do WorldStep(&world)
	testing.expect(t, unit.health > 50, "wounded unit did not recover at supply point")

	reinforced_squad := SquadSpawn(&world, .A, .Line, 1, Vec2{4, 4})
	reinforced_unit := UnitGet(&world, SquadGet(&world, reinforced_squad).units[0])
	UnitDamage(&world, reinforced_unit, 1000, 0)
	spawned := SquadReinforce(&world, reinforced_squad, 2)
	testing.expect_value(t, spawned, 2)
	testing.expect(t, SquadIsAlive(&world, reinforced_squad), "reinforcement did not restore squad")
}

@(test)
BuildingsProduceAndSupportCombat :: proc(t: ^testing.T) {
	world: World
	WorldInit(&world)
	defer WorldDeinit(&world)

	BuildingPlace(&world, .A, .Headquarters, Vec2{4, 4}, LOCAL_PLAYER_ID)
	infantry := BuildingPlace(&world, .A, .InfantryProduction, Vec2{8, 4}, LOCAL_PLAYER_ID)
	vehicle := BuildingPlace(&world, .A, .VehicleWorkshop, Vec2{12, 4}, LOCAL_PLAYER_ID)
	equipment := BuildingPlace(&world, .A, .EquipmentWorkshop, Vec2{16, 4}, LOCAL_PLAYER_ID)
	observation := BuildingPlace(&world, .A, .ObservationPost, Vec2{20, 4}, LOCAL_PLAYER_ID)
	defense := BuildingPlace(&world, .A, .Defense, Vec2{24, 4}, LOCAL_PLAYER_ID)

	testing.expect(t, BuildingQueueForPlayer(&world, LOCAL_PLAYER_ID, infantry, .Assault), "infantry production was rejected")
	testing.expect(t, BuildingQueueForPlayer(&world, LOCAL_PLAYER_ID, vehicle, .Vehicle), "vehicle production was rejected")
	testing.expect(t, BuildingQueueForPlayer(&world, LOCAL_PLAYER_ID, equipment, .Equipment), "equipment production was rejected")
	for index: int = 0; index < 260; index += 1 do WorldStep(&world)
	testing.expect_value(t, len(world.squads), 3)
	testing.expect(t, WorldCanObserve(&world, .A, Vec2{60, 4}), "observation building did not extend vision")
	testing.expect_value(t, WorldDefenseCover(&world, Vec2{24, 4}, .A), 0.35)
	testing.expect(t, WorldBuildingOperational(&world, BuildingGet(&world, observation)^), "observation building is not operational")
	testing.expect(t, WorldBuildingOperational(&world, BuildingGet(&world, defense)^), "defense is not operational")
}

@(test)
EngineerConstructionConnectsSupply :: proc(t: ^testing.T) {
	world: World
	WorldInit(&world)
	defer WorldDeinit(&world)

	BuildingPlace(&world, .A, .Headquarters, Vec2{4, 4}, LOCAL_PLAYER_ID)
	world.sectors[1].team = .A
	world.sectors[2].team = .A
	testing.expect(t, WorldSectorSupplied(&world, SectorId(2), .A), "owned sector was not connected to headquarters")
	world.sectors[1].team = .B
	testing.expect(t, !WorldSectorSupplied(&world, SectorId(2), .A), "enemy sector did not cut supply line")

	engineer_squad := SquadSpawn(&world, .A, .Engineer, 1, Vec2{20, 20}, LOCAL_PLAYER_ID)
	before := WorldSectorResourceCapacity(&world, SectorId(1), .Materials)
	building := BuildingConstructForPlayer(&world, LOCAL_PLAYER_ID, engineer_squad, .SupplyDepot, Vec2{20, 20})
	testing.expect(t, building != INVALID_BUILDING_ID, "engineer could not start construction")
	for index: int = 0; index < 140; index += 1 do WorldStep(&world)
	constructed := BuildingGet(&world, building)
	testing.expect(t, constructed.complete, "engineer construction did not finish")
	WorldStep(&world)
	after := WorldSectorResourceCapacity(&world, SectorId(1), .Materials)
	testing.expect(t, after > before, "supply depot did not increase local storage capacity")
}

@(test)
ArtilleryDelaysImpactsAndLeavesEffects :: proc(t: ^testing.T) {
	world: World
	WorldInit(&world)
	defer WorldDeinit(&world)

	BuildingPlace(&world, .A, .Headquarters, Vec2{4, 4}, LOCAL_PLAYER_ID)
	artillery := BuildingPlace(&world, .A, .ArtilleryEmplacement, Vec2{4, 4}, LOCAL_PLAYER_ID)
	target_squad := SquadSpawn(&world, .B, .Line, 3, Vec2{14, 10})
	target := UnitGet(&world, SquadGet(&world, target_squad).units[0])
	strike_target := target.pos

	testing.expect(t, ArtilleryFireForPlayer(&world, LOCAL_PLAYER_ID, artillery, strike_target), "artillery emplacement could not fire")
	testing.expect_value(t, len(world.strikes), 1)
	WorldStep(&world)
	testing.expect_value(t, len(world.strikes), 1)
	testing.expect_value(t, len(world.shells), 0)
	for index: int = 0; index < 15; index += 1 do WorldStep(&world)
	testing.expect(t, len(world.shells) > 0, "delayed strike did not create shell")
	for index: int = 0; index < 20; index += 1 do WorldStep(&world)
	testing.expect_value(t, len(world.strikes), 0)
	testing.expect_value(t, len(world.shells), 0)
	testing.expect(t, target.health < target.max_health, "artillery did not damage target area")
	testing.expect(t, len(world.effects) >= 4, "impact did not create battlefield effects")
	testing.expect(t, len(world.bodies) > 0, "impact did not leave a body")
	testing.expect_value(t, WorldTerrainAt(&world, strike_target), TerrainType.Crater)
	testing.expect_value(t, WorldTerrainAt(&world, Vec2Add(strike_target, Vec2{16, 0})), TerrainType.Damaged)
}

@(test)
ArtillerySquadsDestroyBuildings :: proc(t: ^testing.T) {
	world: World
	WorldInit(&world)
	defer WorldDeinit(&world)

	WorldAddResourcesAtPosition(&world, .A, Vec2{8, 8}, ResourceInventoryMake(0, 0, 100))
	artillery_squad := SquadSpawn(&world, .A, .Artillery, 1, Vec2{8, 8}, LOCAL_PLAYER_ID)
	ammo := UnitGet(&world, SquadGet(&world, artillery_squad).units[0]).ammo
	testing.expect(t, ArtilleryFireSquadForPlayer(&world, LOCAL_PLAYER_ID, artillery_squad, Vec2{16, 8}), "artillery squad could not fire")
	testing.expect(t, UnitGet(&world, SquadGet(&world, artillery_squad).units[0]).ammo < ammo, "artillery squad did not consume ammunition")

	building_id := BuildingPlace(&world, .B, .Defense, Vec2{40, 40})
	shell := ArtilleryShell{.A, Vec2{40, 40}, Vec2{40, 40}, Vec2{40, 40}, 0, 1, 1000, 6, 1}
	ArtilleryImpact(&world, shell)
	building := BuildingGet(&world, building_id)
	testing.expect(t, building.destroyed, "artillery did not destroy building")
	testing.expect(t, len(world.effects) > 0, "building destruction did not create wreck")
}

@(test)
LogisticsProductionRequiresLocalInputs :: proc(t: ^testing.T) {
	world: World
	WorldInit(&world)
	defer WorldDeinit(&world)

	BuildingPlace(&world, .A, .Headquarters, Vec2{4, 4}, LOCAL_PLAYER_ID)
	infantry := BuildingPlace(&world, .A, .InfantryProduction, Vec2{8, 4}, LOCAL_PLAYER_ID)
	WorldConsumeResource(&world, .A, SectorId(1), .Materials, 500)
	WorldConsumeResource(&world, .A, SectorId(1), .Munitions, 500)

	testing.expect(t, BuildingQueueForPlayer(&world, LOCAL_PLAYER_ID, infantry, .Assault), "production queue rejected local order")
	for index: int = 0; index < 120; index += 1 do WorldStep(&world)
	testing.expect_value(t, len(world.squads), 0)

	WorldAddSectorResource(&world, SectorId(1), .Materials, 15)
	WorldAddSectorResource(&world, SectorId(1), .Munitions, 4)
	for index: int = 0; index < 100; index += 1 do WorldStep(&world)
	testing.expect_value(t, len(world.squads), 1)
}

@(test)
LogisticsCargoMovesBetweenOwnedSectors :: proc(t: ^testing.T) {
	world: World
	WorldInit(&world)
	defer WorldDeinit(&world)

	world.sectors[0].team = .A
	world.sectors[1].team = .A
	WorldAddSectorResource(&world, SectorId(1), .Materials, 200)
	cargo := WorldQueueCargo(&world, .A, .Materials, 50, SectorId(1), SectorId(2))
	testing.expect(t, cargo != INVALID_CARGO_ID, "cargo shipment was not created")
	testing.expect_value(t, len(world.squads), 0)
	testing.expect_value(t, world.convoys[0].vehicle_count, 1)
	testing.expect_value(t, world.convoys[0].capacity, f32(100))
	testing.expect_value(t, world.convoys[0].cargo, cargo)
	testing.expect_value(t, WorldSectorResourceAmount(&world, SectorId(1), .Materials), f32(150))

	WorldUpdateConvoys(&world, 0.5)
	testing.expect_value(t, len(world.cargo), 1)
	testing.expect_value(t, len(world.convoys), 1)
	WorldUpdateConvoys(&world, 0.6)
	testing.expect_value(t, len(world.cargo), 0)
	testing.expect_value(t, len(world.convoys), 0)
	testing.expect_value(t, WorldSectorResourceAmount(&world, SectorId(2), .Materials), f32(50))
}

@(test)
LogisticsRouteInterruptionCanRecoverOrLoseCargo :: proc(t: ^testing.T) {
	world: World
	WorldInit(&world)
	defer WorldDeinit(&world)

	world.sectors[0].team = .A
	world.sectors[1].team = .A
	WorldAddSectorResource(&world, SectorId(1), .Fuel, 300)
	cargo := WorldQueueCargo(&world, .A, .Fuel, 50, SectorId(1), SectorId(2))
	testing.expect(t, cargo != INVALID_CARGO_ID, "recoverable cargo shipment was not created")

	world.sectors[1].team = .B
	WorldUpdateConvoys(&world, 2.0)
	testing.expect_value(t, len(world.cargo), 1)
	testing.expect_value(t, len(world.convoys), 1)
	world.sectors[1].team = .A
	WorldUpdateConvoys(&world, 2.0)
	testing.expect_value(t, len(world.cargo), 0)
	testing.expect_value(t, len(world.convoys), 0)
	testing.expect_value(t, WorldSectorResourceAmount(&world, SectorId(2), .Fuel), f32(50))

	cargo = WorldQueueCargo(&world, .A, .Fuel, 50, SectorId(1), SectorId(2))
	testing.expect(t, cargo != INVALID_CARGO_ID, "loss-test cargo shipment was not created")
	world.sectors[1].team = .B
	WorldUpdateConvoys(&world, 9.0)
	testing.expect_value(t, len(world.cargo), 0)
	testing.expect_value(t, len(world.convoys), 0)
	testing.expect(t, world.cargo_lost >= 50, "blocked cargo was not lost")
}

@(test)
LogisticsRequestsAssignAutomaticCargo :: proc(t: ^testing.T) {
	world: World
	WorldInit(&world)
	defer WorldDeinit(&world)

	world.sectors[0].team = .A
	world.sectors[1].team = .A
	WorldAddSectorResource(&world, SectorId(1), .Munitions, 300)
	testing.expect(t, WorldRequestResourceStockpile(&world, .A, SectorId(2), .Munitions, 100), "stockpile request was rejected")
	WorldUpdateLogistics(&world, 0)
	testing.expect(t, len(world.cargo) == 1, "logistics did not assign a cargo shipment")
	WorldUpdateConvoys(&world, 1.1)
	testing.expect_value(t, WorldSectorResourceAmount(&world, SectorId(2), .Munitions), f32(100))
}

@(test)
LogisticsDestroyedInfrastructureBlocksAndRecovers :: proc(t: ^testing.T) {
	world: World
	WorldInit(&world)
	defer WorldDeinit(&world)

	world.sectors[0].team = .A
	world.sectors[1].team = .A
	world.sectors[2].team = .A
	infrastructure := BuildingPlace(&world, .A, .RouteInfrastructure, Vec2{96, 32})
	WorldAddSectorResource(&world, SectorId(1), .Materials, 200)
	cargo := WorldQueueCargo(&world, .A, .Materials, 50, SectorId(1), SectorId(3))
	testing.expect(t, cargo != INVALID_CARGO_ID, "infrastructure route shipment was not created")

	BuildingGet(&world, infrastructure).destroyed = true
	WorldUpdateConvoys(&world, 1.0)
	testing.expect_value(t, world.convoys[0].state, ConvoyState.Blocked)
	testing.expect(t, WorldHasBlockedConvoy(&world), "blocked convoy warning was not raised")

	BuildingGet(&world, infrastructure).destroyed = false
	WorldUpdateConvoys(&world, 2.0)
	testing.expect_value(t, len(world.cargo), 0)
	testing.expect_value(t, len(world.convoys), 0)
	testing.expect(t, !WorldHasBlockedConvoy(&world), "blocked convoy warning remained after recovery")
	testing.expect_value(t, WorldSectorResourceAmount(&world, SectorId(3), .Materials), f32(50))
}

@(test)
LogisticsConvoyDamageDestroysCargo :: proc(t: ^testing.T) {
	world: World
	WorldInit(&world)
	defer WorldDeinit(&world)

	world.sectors[0].team = .A
	world.sectors[1].team = .A
	WorldAddSectorResource(&world, SectorId(1), .Fuel, 200)
	cargo := WorldQueueCargo(&world, .A, .Fuel, 50, SectorId(1), SectorId(2))
	testing.expect(t, cargo != INVALID_CARGO_ID, "damage-test shipment was not created")
	ConvoyDamage(&world.convoys[0], CONVOY_HEALTH + 1)
	testing.expect_value(t, world.convoys[0].state, ConvoyState.Destroyed)

	WorldUpdateConvoys(&world, 0)
	testing.expect_value(t, len(world.cargo), 0)
	testing.expect_value(t, len(world.convoys), 0)
	testing.expect(t, world.cargo_lost >= 50, "destroyed convoy did not lose cargo")
	testing.expect(t, len(world.effects) > 0, "destroyed convoy did not leave a wreck")
}

@(test)
PathfindingAvoidsBlockedTerrain :: proc(t: ^testing.T) {
	world: World
	WorldInit(&world)
	defer WorldDeinit(&world)

	for x: int = 1; x < 7; x += 1 do WorldSetTerrainCell(&world, x, 0, .Blocked)
	path := WorldTacticalPath(&world, Vec2{8, 8}, Vec2{120, 8})
	defer delete(path)
	testing.expect(t, len(path) > 0, "tactical path was not found around blocked terrain")
	for position in path do testing.expect(t, WorldTerrainAt(&world, position) != .Blocked, "tactical path entered blocked terrain")
}

@(test)
StrategicRoutesRerouteConvoys :: proc(t: ^testing.T) {
	world: World
	WorldInit(&world)
	defer WorldDeinit(&world)

	world.sectors[0].team = .A
	world.sectors[1].team = .A
	world.sectors[4].team = .A
	world.sectors[5].team = .A
	testing.expect(t, WorldSetSectorRouteDanger(&world, SectorId(1), SectorId(2), 1), "could not mark strategic route dangerous")
	danger_path := WorldFindStrategicSectorPath(&world, SectorId(1), SectorId(2), .A, true)
	defer delete(danger_path)
	testing.expect(t, len(danger_path) > 2, "strategic path did not avoid a dangerous route")
	testing.expect(t, WorldSetSectorRouteBlocked(&world, SectorId(1), SectorId(2), true), "could not block strategic route")
	WorldAddSectorResource(&world, SectorId(1), .Fuel, 200)
	cargo := WorldQueueCargo(&world, .A, .Fuel, 50, SectorId(1), SectorId(2))
	testing.expect(t, cargo != INVALID_CARGO_ID, "logistics did not find an alternate strategic route")
	testing.expect(t, world.convoys[0].travel_time > CARGO_BASE_TRAVEL_TIME, "rerouted convoy did not receive a longer route")
	WorldUpdateConvoys(&world, 3.1)
	testing.expect_value(t, len(world.cargo), 0)
	testing.expect_value(t, WorldSectorResourceAmount(&world, SectorId(2), .Fuel), f32(50))
}

@(test)
WoundedSquadAutonomouslyResupplies :: proc(t: ^testing.T) {
	world: World
	WorldInit(&world)
	defer WorldDeinit(&world)

	BuildingPlace(&world, .A, .Headquarters, Vec2{4, 4}, LOCAL_PLAYER_ID)
	world.sectors[1].team = .A
	squad_id := SquadSpawn(&world, .A, .Line, 1, Vec2{100, 32}, LOCAL_PLAYER_ID)
	unit := UnitGet(&world, SquadGet(&world, squad_id).units[0])
	UnitDamage(&world, unit, 75, 0)
	for index: int = 0; index < 100; index += 1 do WorldStep(&world)
	testing.expect_value(t, SquadGet(&world, squad_id).intent, SquadIntent.Resupply)
	testing.expect(t, WorldCanResupply(&world, unit^), "wounded squad did not reach a resupply point")
	testing.expect(t, unit.health > 25, "wounded squad did not recover at the resupply point")
}

@(test)
SquadsCanEscortAndRaidConvoys :: proc(t: ^testing.T) {
	world: World
	WorldInit(&world)
	defer WorldDeinit(&world)

	world.sectors[0].team = .A
	world.sectors[1].team = .A
	WorldAddSectorResource(&world, SectorId(1), .Materials, 200)
	cargo := WorldQueueCargo(&world, .A, .Materials, 50, SectorId(1), SectorId(2))
	testing.expect(t, cargo != INVALID_CARGO_ID, "escort-test convoy was not created")
	convoy := &world.convoys[0]
	escort := SquadSpawn(&world, .A, .Line, 1, WorldConvoyPosition(&world, convoy^), LOCAL_PLAYER_ID)
	raider := SquadSpawn(&world, .B, .Scout, 1, WorldConvoyPosition(&world, convoy^), PLAYER_TWO_ID)
	testing.expect(t, SquadSetEscortForPlayer(&world, LOCAL_PLAYER_ID, escort, convoy.id), "escort order was rejected")
	testing.expect(t, SquadSetRaidForPlayer(&world, PLAYER_TWO_ID, raider, convoy.id), "raid order was rejected")
	health := convoy.health
	WorldUpdateLogistics(&world, 1.0)
	testing.expect(t, convoy.health < health, "raid order did not damage convoy")
}

@(test)
FactionProfilesChangeCombatAndBuildings :: proc(t: ^testing.T) {
	world: World
	WorldInit(&world)
	defer WorldDeinit(&world)

	testing.expect_value(t, WorldTeamFaction(&world, .A), Faction.BastionDirectorate)
	testing.expect_value(t, WorldTeamFaction(&world, .B), Faction.FreeMarches)
	testing.expect(t, WorldSetTeamFaction(&world, .A, .MeridianCombine), "could not assign Meridian faction")
	WorldSetTeamFaction(&world, .B, .BastionDirectorate)

	meridian_scout := UnitStatsGetForTeam(&world, .A, .Scout)
	bastion_heavy := UnitStatsGetForTeam(&world, .B, .Heavy)
	base_scout := UnitStatsGet(.Scout)
	base_heavy := UnitStatsGet(.Heavy)
	testing.expect(t, meridian_scout.range > base_scout.range, "Meridian did not improve reconnaissance range")
	testing.expect(t, bastion_heavy.health > base_heavy.health, "Bastion did not improve armored durability")

	meridian_defense := BuildingStatsGetForTeam(&world, .A, .Defense)
	WorldSetTeamFaction(&world, .B, .FreeMarches)
	free_defense := BuildingStatsGetForTeam(&world, .B, .Defense)
	testing.expect(t, meridian_defense.health > free_defense.health, "factions did not differentiate building durability")
}

@(test)
FactionProductionAndLogisticsDoctrinesDiffer :: proc(t: ^testing.T) {
	world: World
	WorldInit(&world)
	defer WorldDeinit(&world)

	WorldSetTeamFaction(&world, .A, .HearthUnion)
	hearth_cost := BuildingProductionCostForTeam(&world, .A, .Line)
	base_cost := BuildingProductionCost(.Line)
	hearth_count := BuildingProductionCountForTeam(&world, .A, .Line)
	testing.expect(t, hearth_cost.amounts[ResourceIndex(.Materials)] < base_cost.amounts[ResourceIndex(.Materials)], "Hearth did not reduce infantry material cost")
	testing.expect(t, hearth_count > BuildingProductionCount(.Line), "Hearth did not improve infantry mass production")

	WorldSetTeamFaction(&world, .A, .FreeMarches)
	world.sectors[0].team = .A
	world.sectors[1].team = .A
	WorldAddSectorResource(&world, SectorId(1), .Materials, 200)
	cargo := WorldQueueCargo(&world, .A, .Materials, 50, SectorId(1), SectorId(2))
	testing.expect(t, cargo != INVALID_CARGO_ID, "Free Marches logistics shipment was not created")
	testing.expect(t, world.convoys[0].speed > 1, "Free Marches did not improve convoy mobility")
	testing.expect(t, world.convoys[0].capacity < CONVOY_VEHICLE_CAPACITY, "Free Marches convoy capacity was not differentiated")
}

@(test)
FactionCountersCreateAsymmetricMatchups :: proc(t: ^testing.T) {
	world: World
	WorldInit(&world)
	defer WorldDeinit(&world)

	WorldSetTeamFaction(&world, .A, .MeridianCombine)
	attacker_squad := SquadSpawn(&world, .A, .Equipment, 1, Vec2{20, 20})
	target_squad := SquadSpawn(&world, .B, .Vehicle, 1, Vec2{20, 20})
	attacker := UnitGet(&world, SquadGet(&world, attacker_squad).units[0])
	target := UnitGet(&world, SquadGet(&world, target_squad).units[0])
	testing.expect(t, FactionCounterMultiplier(&world, attacker^, target^) > 1, "Meridian precision units lacked a vehicle counter")
}

@(test)
MainMatchSetupBuildsObjectivesAndBases :: proc(t: ^testing.T) {
	world: World
	WorldInit(&world)
	defer WorldDeinit(&world)

	WorldSetupMatch(&world)
	testing.expect_value(t, world.match_state, MatchState.Running)
	testing.expect_value(t, len(world.sectors), 16)
	testing.expect_value(t, len(world.routes), 24)
	testing.expect_value(t, WorldBaseSector(&world, .A), SectorId(1))
	testing.expect_value(t, WorldBaseSector(&world, .B), SectorId(16))
	testing.expect(t, WorldIsBaseSector(&world, SectorId(1)), "Team A base objective was not assigned")
	testing.expect(t, WorldTeamControlsBase(&world, .A), "Team A did not control its starting base")
	testing.expect(t, WorldTeamControlsBase(&world, .B), "Team B did not control its starting base")
	strategic_count := 0
	for sector in world.sectors {
		if sector.objective == .Strategic do strategic_count += 1
	}
	testing.expect_value(t, strategic_count, 4)
}

@(test)
MainMatchReinforcementsAreConsumedOncePerDeath :: proc(t: ^testing.T) {
	world: World
	WorldInit(&world)
	defer WorldDeinit(&world)
	WorldSetupMatch(&world)

	squad := SquadGet(&world, SquadId(1))
	unit := UnitGet(&world, squad.units[0])
	before := WorldTeamReinforcements(&world, .A)
	UnitDamage(&world, unit, 10000, 0)
	testing.expect_value(t, WorldTeamReinforcements(&world, .A), before - 1)
	UnitDamage(&world, unit, 10000, 0)
	testing.expect_value(t, WorldTeamReinforcements(&world, .A), before - 1)
}

@(test)
MainMatchEndsOnBaseCaptureAndStopsTicks :: proc(t: ^testing.T) {
	world: World
	WorldInit(&world)
	defer WorldDeinit(&world)
	WorldSetupMatch(&world)

	base_b := WorldBaseSector(&world, .B)
	for &unit in world.units {
		if unit.team == .A {
			unit.pos = WorldSectorCenter(&world, base_b)
		} else if unit.team == .B {
			unit.state = .Dead
		}
	}
	WorldSetMatchSectorControl(&world, base_b, .A, 1)
	WorldStep(&world)
	testing.expect_value(t, world.match_state, MatchState.Victory)
	testing.expect_value(t, world.winner, Team.A)
	tick := world.tick
	WorldStep(&world)
	testing.expect_value(t, world.tick, tick)
}

@(test)
MainMatchDrawsAtTimeLimitAndCanRestart :: proc(t: ^testing.T) {
	world: World
	WorldInit(&world)
	defer WorldDeinit(&world)
	WorldSetupMatch(&world)
	world.match_time_limit = world.step
	WorldStep(&world)
	testing.expect_value(t, world.match_state, MatchState.Draw)

	WorldResetMatch(&world)
	testing.expect_value(t, world.match_state, MatchState.Running)
	testing.expect_value(t, world.match_time, f32(0))
	testing.expect_value(t, len(world.squads), 6)
}
