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
	building := BuildingConstructForPlayer(&world, LOCAL_PLAYER_ID, engineer_squad, .SupplyDepot, Vec2{20, 20})
	testing.expect(t, building != INVALID_BUILDING_ID, "engineer could not start construction")
	for index: int = 0; index < 140; index += 1 do WorldStep(&world)
	constructed := BuildingGet(&world, building)
	testing.expect(t, constructed.complete, "engineer construction did not finish")
	before := WorldSectorResourceCapacity(&world, SectorId(1), .Materials)
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
	testing.expect_value(t, WorldSectorResourceAmount(&world, SectorId(1), .Materials), f32(150))

	WorldUpdateCargo(&world, 0.5)
	testing.expect_value(t, len(world.cargo), 1)
	WorldUpdateCargo(&world, 0.6)
	testing.expect_value(t, len(world.cargo), 0)
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
	WorldUpdateCargo(&world, 2.0)
	testing.expect_value(t, len(world.cargo), 1)
	world.sectors[1].team = .A
	WorldUpdateCargo(&world, 2.0)
	testing.expect_value(t, len(world.cargo), 0)
	testing.expect_value(t, WorldSectorResourceAmount(&world, SectorId(2), .Fuel), f32(50))

	cargo = WorldQueueCargo(&world, .A, .Fuel, 50, SectorId(1), SectorId(2))
	testing.expect(t, cargo != INVALID_CARGO_ID, "loss-test cargo shipment was not created")
	world.sectors[1].team = .B
	WorldUpdateCargo(&world, 9.0)
	testing.expect_value(t, len(world.cargo), 0)
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
	WorldUpdateCargo(&world, 1.1)
	testing.expect_value(t, WorldSectorResourceAmount(&world, SectorId(2), .Munitions), f32(100))
}
