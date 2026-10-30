package main

import "base:intrinsics"
import "core:testing"
import "d32"

// Bump when authoritative numeric, generation, command or hash rules change.
WORLD_STATE_VERSION :: u32(2)

// FNV-1a over fixed-width, little-endian scalar encodings.
WorldHashValue :: proc(hash: ^u64, value: $T) {
	when intrinsics.type_is_boolean(T) {
		WorldHashValue(hash, u8(value ? 1 : 0))
	} else when intrinsics.type_is_enum(T) {
		WorldHashValue(hash, i64(value))
	} else when intrinsics.type_is_bit_set(T) {
		WorldHashValue(hash, transmute(intrinsics.type_bit_set_underlying_type(T))value)
	} else when T == d32.Value {
		WorldHashValue(hash, d32.Raw(value))
	} else when intrinsics.type_is_integer(T) {
		bits := u64(value)
		for _ in 0..<8 {
			hash^ = (hash^ ~ (bits & 255))*0x100000001b3
			bits >>= 8
		}
	} else when T == f32 {
		WorldHashValue(hash, transmute(u32)value)
	} else when intrinsics.type_is_array(T) || intrinsics.type_is_enumerated_array(T) || intrinsics.type_is_slice(T) || intrinsics.type_is_dynamic_array(T) {
		WorldHashValue(hash, len(value))
		for item in value do WorldHashValue(hash, item)
	} else {
		#panic("Unsupported world hash type")
	}
}

WorldHashOrder :: proc(hash: ^u64, order: WarriorOrder) {
	switch value in order {
	case nil: WorldHashValue(hash, 0)
	case WarriorIdle: WorldHashValue(hash, 1)
	case WarriorGarrison: WorldHashValue(hash, 2)
	case WarriorAttack:
		WorldHashValue(hash, 3)
		WorldHashValue(hash, value.kingdom)
		WorldHashValue(hash, value.town)
	case WarriorDefend:
		WorldHashValue(hash, 4)
		WorldHashValue(hash, value.kingdom)
		WorldHashValue(hash, value.town)
	}
}

WorldHashUnit :: proc(hash: ^u64, unit: ^Unit) {
	WorldHashValue(hash, unit.x)
	WorldHashValue(hash, unit.y)
	WorldHashValue(hash, unit.health)
	WorldHashValue(hash, unit.burning)
	WorldHashValue(hash, unit.cooldown)
	WorldHashValue(hash, unit.poisonRemaining)
	WorldHashValue(hash, unit.decisionTimer)
	WorldHashValue(hash, unit.decisionReady)
	WorldHashValue(hash, unit.updateStride)

	WorldHashValue(hash, unit.kingdome)
	WorldHashValue(hash, unit.town)
	WorldHashValue(hash, unit.sleepOffsetHours)
	WorldHashValue(hash, unit.homeSlot)
	WorldHashValue(hash, unit.sleepInside)
	WorldHashValue(hash, unit.sleepNavigationRevision)
	WorldHashValue(hash, unit.roamSequence)
	WorldHashValue(hash, unit.effects)
	WorldHashValue(hash, unit.path)
	WorldHashValue(hash, unit.pathTargetX)
	WorldHashValue(hash, unit.pathTargetY)
	WorldHashValue(hash, unit.pathRevision)
	WorldHashValue(hash, unit.pathIndex)
	WorldHashValue(hash, unit.pathReady)
	WorldHashValue(hash, unit.pathFound)

	switch value in unit.type {
	case nil: WorldHashValue(hash, 0)
	case Villager: WorldHashValue(hash, 1)
	case Builder:
		WorldHashValue(hash, 2)
		WorldHashValue(hash, value.carriedResource)
		WorldHashValue(hash, value.taskSequence)
		WorldHashValue(hash, value.targetDecoration)
		WorldHashValue(hash, value.constructionSite)
		WorldHashValue(hash, value.failedConstruction)
	case CombatBuilder:
		WorldHashValue(hash, 3)
		WorldHashOrder(hash, value.order)
		WorldHashValue(hash, value.orderRevision)
		WorldHashValue(hash, value.orderKingdom)
		WorldHashValue(hash, value.orderTown)
		WorldHashValue(hash, value.patrolSequence)
		WorldHashValue(hash, value.returning)
		WorldHashValue(hash, value.onStation)
		WorldHashValue(hash, value.site)
		WorldHashValue(hash, value.siteSequence)
		WorldHashValue(hash, value.failedSite)
		WorldHashValue(hash, value.failedRevision)
		WorldHashValue(hash, value.scanTimer)
	case WaterCollector:
		WorldHashValue(hash, 4)
		WorldHashValue(hash, value.carriedResource)
		WorldHashValue(hash, value.taskSequence)
	case Farmer:
		WorldHashValue(hash, 5)
		WorldHashValue(hash, value.workedToday)
		WorldHashValue(hash, value.workDay)
	case Knight: WorldHashValue(hash, 6)
	case Archer: WorldHashValue(hash, 7)
	case Mage: WorldHashValue(hash, 8)
	case Giant: WorldHashValue(hash, 9)
	case Turtle: WorldHashValue(hash, 10)
	case Catapult: WorldHashValue(hash, 11)
	case Rogue: WorldHashValue(hash, 12)
	case Explorer:
		WorldHashValue(hash, 13)
		WorldHashValue(hash, value.restTimer)
		WorldHashValue(hash, value.tripsLeft)
		WorldHashValue(hash, value.journey)
	}

	switch value in unit.state {
	case nil: WorldHashValue(hash, 0)
	case StatePacific:
		WorldHashValue(hash, 1)
		WorldHashValue(hash, value)
	case StateWarrior:
		WorldHashValue(hash, 2)
		WorldHashValue(hash, value.activity)
		WorldHashOrder(hash, value.order)
		WorldHashValue(hash, value.orderKingdom)
		WorldHashValue(hash, value.orderTown)
		WorldHashValue(hash, value.orderRevision)
		switch target in value.target {
		case nil: WorldHashValue(hash, 0)
		case TargetNone: WorldHashValue(hash, 1)
		case TargetUnit:
			WorldHashValue(hash, 2)
			WorldHashValue(hash, target.slot)
		case TargetBuilding:
			WorldHashValue(hash, 3)
			WorldHashValue(hash, target.slot)
		}
		WorldHashValue(hash, value.scanTimer)
		WorldHashValue(hash, value.scanSequence)
		WorldHashValue(hash, value.patrolSequence)
		WorldHashValue(hash, value.escortTarget)
		WorldHashValue(hash, value.retreating)
	case StateConverting:
		WorldHashValue(hash, 3)
		WorldHashValue(hash, value.to)
		WorldHashValue(hash, value.building)
		WorldHashValue(hash, value.accessX)
		WorldHashValue(hash, value.accessY)
		WorldHashValue(hash, value.timer)
		WorldHashValue(hash, value.retryTimer)
		WorldHashValue(hash, value.inside)
	}
}

WorldHashBuilding :: proc(hash: ^u64, building: ^Building) {
	WorldHashValue(hash, building.x)
	WorldHashValue(hash, building.y)
	WorldHashValue(hash, building.health)
	WorldHashValue(hash, building.cooldown)
	WorldHashValue(hash, building.kingdom)
	WorldHashValue(hash, building.town)
	WorldHashValue(hash, building.homeResident)
	WorldHashValue(hash, building.output)
	WorldHashValue(hash, building.outputRevision)
	if building.type == nil {
		WorldHashValue(hash, -1)
		return
	}
	WorldHashValue(hash, BuildingKindOf(building.type))
	switch value in building.type {
	case BuildingOrder:
		WorldHashValue(hash, true)
		WorldHashValue(hash, value.orderCooldown)
		WorldHashValue(hash, value.orderActive)
		WorldHashValue(hash, value.orderTelegraph)
		WorldHashValue(hash, value.orderTargetX)
		WorldHashValue(hash, value.orderTargetY)
		WorldHashValue(hash, value.orderTick)
		WorldHashValue(hash, value.orderMitigation)
		WorldHashValue(hash, value.orderKind)
		WorldHashValue(hash, value.orderPending)
	case nil, TownHall, Home, Farmland, Wall, Bridge, Cannon, Watchtower, ArcheryRange, MagicSchool, GiantPen, SiegeWorkshop, TurtlePen, ThievesGuild, Path, DistrictHall, Granary:
		WorldHashValue(hash, false)
	}
}

WorldHashTown :: proc(hash: ^u64, town: ^Town) {
	WorldHashValue(hash, town.name)
	WorldHashValue(hash, town.x)
	WorldHashValue(hash, town.y)
	WorldHashValue(hash, town.hallSlot)
	WorldHashValue(hash, town.citizens)
	WorldHashValue(hash, town.wood)
	WorldHashValue(hash, town.growthCooldown)
	WorldHashValue(hash, town.growthInterval)
	WorldHashValue(hash, town.growthRate)
	WorldHashValue(hash, town.growthSpeed)
	WorldHashValue(hash, town.growthBatch)
	WorldHashValue(hash, town.growthBatchBonus)
	WorldHashValue(hash, town.growthPending)
	WorldHashValue(hash, town.constructionProgress)
	WorldHashValue(hash, town.constructionFailUntilTick)
	WorldHashValue(hash, town.siteFailUntilTick)
	WorldHashValue(hash, town.pathSearchFailUntilTick)
	WorldHashValue(hash, town.woodSearchFailUntilTick)
	WorldHashValue(hash, town.waterSourceX)
	WorldHashValue(hash, town.waterSourceY)
	WorldHashValue(hash, town.waterSourceRevision)
	WorldHashValue(hash, town.waterSourceReady)
	WorldHashValue(hash, town.waterSearchFailUntilTick)
	WorldHashValue(hash, town.returnPointX)
	WorldHashValue(hash, town.returnPointY)
	WorldHashValue(hash, town.returnPointRevision)
	WorldHashValue(hash, town.returnPointReady)
	WorldHashValue(hash, town.sitePoolCount)
	for i in 0..<town.sitePoolCount {
		site := town.sitePool[i]
		WorldHashValue(hash, site.kind)
		WorldHashValue(hash, site.x)
		WorldHashValue(hash, site.y)
	}
	for site in town.constructions {
		WorldHashValue(hash, site.active)
		if !site.active do continue
		WorldHashValue(hash, site.kind)
		WorldHashValue(hash, site.x)
		WorldHashValue(hash, site.y)
		WorldHashValue(hash, site.paid)
		WorldHashValue(hash, site.settlers)
		WorldHashValue(hash, site.clearWork)
		WorldHashValue(hash, site.buildWork)
		WorldHashValue(hash, site.accessReady)
		WorldHashValue(hash, site.accessX)
		WorldHashValue(hash, site.accessY)
	}
	WorldHashValue(hash, town.builders)
	WorldHashValue(hash, town.waterCollectors)
	WorldHashValue(hash, town.farmers)
	WorldHashValue(hash, town.villagers)
	WorldHashValue(hash, town.buildersBySlice)
	WorldHashValue(hash, town.waterCollectorsBySlice)
	WorldHashValue(hash, town.farmersBySlice)
	WorldHashValue(hash, town.villagersBySlice)
	WorldHashValue(hash, town.homes)
	WorldHashValue(hash, town.farmlands)
	WorldHashValue(hash, town.farmlandOutput)
	WorldHashValue(hash, town.foodPotential)
	WorldHashValue(hash, town.waterPotential)
	WorldHashValue(hash, town.waterAccess)
	WorldHashValue(hash, town.waterAccessTerrainRevision)
	WorldHashValue(hash, town.waterAccessCached)
	WorldHashValue(hash, town.foodShortage)
	WorldHashValue(hash, town.waterShortage)
	WorldHashValue(hash, town.coastal)
	WorldHashValue(hash, town.coastalCached)
	WorldHashValue(hash, town.coastalTerrainRevision)
	WorldHashValue(hash, town.coastalAreaRadius)
	WorldHashValue(hash, town.coastalDistricts)
	WorldHashValue(hash, town.blockadeUntilTick)
	WorldHashValue(hash, town.blockadeBy)
	WorldHashValue(hash, town.orderWard)
	WorldHashValue(hash, town.orderWardRegenDelay)
	WorldHashValue(hash, town.areaRadius)
	WorldHashValue(hash, town.districtCount)
	for i in 0..<town.districtCount {
		district := town.districts[i]
		WorldHashValue(hash, district.x)
		WorldHashValue(hash, district.y)
		WorldHashValue(hash, district.radius)
		WorldHashValue(hash, district.name)
	}
	WorldHashValue(hash, town.fusionCount)
	WorldHashValue(hash, town.alarmActive)
	WorldHashValue(hash, town.threatX)
	WorldHashValue(hash, town.threatY)
	WorldHashValue(hash, town.unlockedBuildings)
	WorldHashValue(hash, town.unlockedUnits)
	WorldHashValue(hash, town.buildingCounts)
	WorldHashValue(hash, town.buildingSlots)
	WorldHashValue(hash, town.milestonesEarned)
	WorldHashValue(hash, town.milestonesChosen)
	WorldHashValue(hash, town.milestonePending)
	WorldHashValue(hash, town.milestoneOptions)
	WorldHashValue(hash, town.conversionCount)
	for i in 0..<town.conversionCount {
		job := town.conversions[i]
		WorldHashValue(hash, job.from)
		WorldHashValue(hash, job.to)
		WorldHashValue(hash, job.remaining)
		WorldHashValue(hash, job.assigned)
	}
	WorldHashValue(hash, town.attackOrders)
	WorldHashValue(hash, town.defendOrders)
	WorldHashValue(hash, town.attackedBy)
	WorldHashValue(hash, town.defendedBy)
	WorldHashValue(hash, town.orderCount)
	for i in 0..<town.orderCount {
		switch order in town.orders[i] {
		case nil: WorldHashValue(hash, 0)
		case TownAttackOrder:
			WorldHashValue(hash, 1)
			WorldHashValue(hash, order.kingdom)
			WorldHashValue(hash, order.town)
		case TownDefendOrder:
			WorldHashValue(hash, 2)
			WorldHashValue(hash, order.kingdom)
			WorldHashValue(hash, order.town)
		}
	}
	WorldHashValue(hash, town.orderRevision)
}

// Call only at a quiescent simulation boundary, not during parallel updates.
WorldStateHash :: proc(w: ^World) -> u64 {
	hash: u64 = 0xcbf29ce484222325
	WorldHashValue(&hash, WORLD_STATE_VERSION)
	WorldHashValue(&hash, w.seed)
	WorldHashValue(&hash, w.maxX)
	WorldHashValue(&hash, w.maxY)
	WorldHashValue(&hash, w.unitCount)
	WorldHashValue(&hash, w.unitFreeHint)
	WorldHashValue(&hash, w.buildingFreeHint)
	WorldHashValue(&hash, w.fireCursor)
	WorldHashValue(&hash, w.fireCount)
	WorldHashValue(&hash, w.unitsBurning)

	WorldHashValue(&hash, w.navigationRevision)
	WorldHashValue(&hash, w.pathRevision)
	WorldHashValue(&hash, w.terrainRevision)
	WorldHashValue(&hash, w.simulationTime)
	WorldHashValue(&hash, w.simulationTick)
	WorldHashValue(&hash, w.dayTime)
	WorldHashValue(&hash, w.dayNumber)
	WorldHashValue(&hash, w.gameOver)
	WorldHashValue(&hash, w.winnerKingdom)
	WorldHashValue(&hash, w.usedTownName)
	// Contact affects diplomacy; observer fog is peer-local.
	WorldHashValue(&hash, w.fog.contacts)
	WorldHashValue(&hash, w.weather.kind)
	WorldHashValue(&hash, w.weather.nextKind)
	WorldHashValue(&hash, w.weather.value)
	WorldHashValue(&hash, w.weather.duration)
	WorldHashValue(&hash, w.weather.remaining)
	WorldHashValue(&hash, w.weather.windX)
	WorldHashValue(&hash, w.weather.windY)
	WorldHashValue(&hash, w.weather.season)
	WorldHashValue(&hash, w.weather.sequence)
	WorldHashValue(&hash, w.weather.lightningTimer)
	WorldHashValue(&hash, w.environment.kind)
	WorldHashValue(&hash, w.environment.severity)
	WorldHashValue(&hash, w.environment.phase)
	WorldHashValue(&hash, w.environment.remaining)
	WorldHashValue(&hash, w.environment.telegraph)
	WorldHashValue(&hash, w.environment.duration)
	WorldHashValue(&hash, w.environment.centerX)
	WorldHashValue(&hash, w.environment.centerY)
	WorldHashValue(&hash, w.environment.radius)
	WorldHashValue(&hash, w.environment.kingdom)
	WorldHashValue(&hash, w.environment.town)
	WorldHashValue(&hash, w.environment.tick)
	WorldHashValue(&hash, w.environment.sequence)
	WorldHashValue(&hash, w.eventMinorTimer)
	WorldHashValue(&hash, w.eventModerateTimer)
	WorldHashValue(&hash, w.eventMajorTimer)
	WorldHashValue(&hash, w.eventCataclysmTimer)
	WorldHashValue(&hash, w.eventGap)
	WorldHashValue(&hash, w.eventDebt)
	WorldHashValue(&hash, w.eventLastMajorKingdom)
	WorldHashValue(&hash, w.eventCataclysmCount)
	WorldHashValue(&hash, w.eventSequence)
	WorldHashValue(&hash, w.eventBag)
	WorldHashValue(&hash, len(w.groundStorage))
	for tile in w.groundStorage {
		WorldHashValue(&hash, tile.type)
		WorldHashValue(&hash, tile.climate)
		WorldHashValue(&hash, tile.scar)
		WorldHashValue(&hash, tile.scarFrom)
		WorldHashValue(&hash, tile.scarTimer)
	}
	WorldHashValue(&hash, w.scarTiles)
	WorldHashValue(&hash, w.terrainChunkRevisions)
	for slot in 0..<KINGDOMS_CAPACITY {
		controller := w.controllers[slot]
		WorldHashValue(&hash, controller.kind)
		if controller.kind == .AI {
			brain := controller.ai
			WorldHashValue(&hash, brain.decisionTimer)
			WorldHashValue(&hash, brain.orderTimer)
			WorldHashValue(&hash, brain.diplomacyTimer)
			WorldHashValue(&hash, brain.expandTimer)
			WorldHashValue(&hash, brain.aggression)
			WorldHashValue(&hash, brain.expansion)
			WorldHashValue(&hash, brain.warCommitUntilTick)
			WorldHashValue(&hash, brain.truceUntilTick)
			WorldHashValue(&hash, brain.truceKingdom)
		}
	}
	for slot in 0..<UNIT_CAPACITY {
		WorldHashValue(&hash, w.unitUsed[slot])
		if w.unitUsed[slot] {
			unit := w.units[slot]
			WorldHashUnit(&hash, &unit)
		}
	}
	for slot in 0..<BUILDING_CAPACITY {
		WorldHashValue(&hash, w.buildingUsed[slot])
		if w.buildingUsed[slot] {
			building := w.buildings[slot]
			WorldHashBuilding(&hash, &building)
		}
	}
	WorldHashValue(&hash, w.decorationCursor)
	WorldHashValue(&hash, w.decorationStumps)
	for slot in 0..<DECORATION_CAPACITY {
		WorldHashValue(&hash, w.decorationUsed[slot])
		if !w.decorationUsed[slot] do continue
		decoration := w.decorations[slot]
		WorldHashValue(&hash, decoration.x)
		WorldHashValue(&hash, decoration.y)
		WorldHashValue(&hash, decoration.kind)
		WorldHashValue(&hash, decoration.health)
		WorldHashValue(&hash, decoration.regrowTimer)
	}
	for i in 0..<w.fireCount do WorldHashValue(&hash, w.fireActive[i])
	for slot in 0..<FIRE_CAPACITY {
		WorldHashValue(&hash, w.fireUsed[slot])
		if !w.fireUsed[slot] do continue
		fire := w.fires[slot]
		WorldHashValue(&hash, fire.x)
		WorldHashValue(&hash, fire.y)
		WorldHashValue(&hash, fire.intensity)
		WorldHashValue(&hash, fire.spread)
		WorldHashValue(&hash, fire.remaining)
		WorldHashValue(&hash, fire.duration)
	}
	WorldHashValue(&hash, w.hazardCursor)
	for slot in 0..<HAZARD_CAPACITY {
		WorldHashValue(&hash, w.hazardUsed[slot])
		if !w.hazardUsed[slot] do continue
		hazard := w.hazardCells[slot]
		WorldHashValue(&hash, hazard.x)
		WorldHashValue(&hash, hazard.y)
		WorldHashValue(&hash, hazard.kind)
		WorldHashValue(&hash, hazard.remaining)
		WorldHashValue(&hash, hazard.duration)
		WorldHashValue(&hash, hazard.seed)
		WorldHashValue(&hash, hazard.stage)
	}
	WorldHashValue(&hash, w.gasCloudCursor)
	for slot in 0..<GAS_CLOUD_CAPACITY {
		WorldHashValue(&hash, w.gasCloudUsed[slot])
		if !w.gasCloudUsed[slot] do continue
		cloud := w.gasClouds[slot]
		WorldHashValue(&hash, cloud.x)
		WorldHashValue(&hash, cloud.y)
		WorldHashValue(&hash, cloud.radius)
		WorldHashValue(&hash, cloud.remaining)
		WorldHashValue(&hash, cloud.duration)
		WorldHashValue(&hash, cloud.seed)
	}
	for slot in 0..<COMBAT_SITE_CAPACITY {
		WorldHashValue(&hash, w.combatSiteUsed[slot])
		if !w.combatSiteUsed[slot] do continue
		site := w.combatSites[slot]
		WorldHashValue(&hash, site.kind)
		WorldHashValue(&hash, site.x)
		WorldHashValue(&hash, site.y)
		WorldHashValue(&hash, site.work)
		WorldHashValue(&hash, site.kingdom)
		WorldHashValue(&hash, site.town)
	}
	for slot in 0..<KINGDOM_SLOTS {
		WorldHashValue(&hash, w.kingdomUsed[slot])
		if !w.kingdomUsed[slot] do continue
		kingdom := &w.kingdoms[slot]
		WorldHashValue(&hash, kingdom.name)
		WorldHashValue(&hash, kingdom.culture)
		WorldHashValue(&hash, kingdom.capitalSlot)
		WorldHashValue(&hash, kingdom.kingdomWar)
		WorldHashValue(&hash, kingdom.techs)
		WorldHashValue(&hash, kingdom.insight)
		WorldHashValue(&hash, kingdom.coastalTownCount)
		for townSlot in 0..<TOWN_CAPACITY {
			WorldHashValue(&hash, kingdom.townUsed[townSlot])
			if kingdom.townUsed[townSlot] {
				town := kingdom.towns[townSlot]
				WorldHashTown(&hash, &town)
			}
		}
	}
	WorldHashValue(&hash, w.flowFieldStamp)
	WorldHashValue(&hash, w.flowBuildCount)
	for i in 0..<w.flowBuildCount {
		WorldHashValue(&hash, w.flowBuildQueue[(w.flowBuildHead+i)%FLOW_FIELD_CAPACITY])
	}
	for &field in w.flowFields {
		WorldHashValue(&hash, field.targetKingdom)
		WorldHashValue(&hash, field.targetTown)
		WorldHashValue(&hash, field.unitKingdom)
		WorldHashValue(&hash, field.hallX)
		WorldHashValue(&hash, field.hallY)
		WorldHashValue(&hash, field.walkWater)
		WorldHashValue(&hash, field.valid)
		WorldHashValue(&hash, field.stamp)
		WorldHashValue(&hash, field.builtAtTick)
		WorldHashValue(&hash, field.building)
		WorldHashValue(&hash, field.queued)
		WorldHashValue(&hash, field.buildMask)
		WorldHashValue(&hash, field.maskIndex)
		WorldHashValue(&hash, field.maskX)
		WorldHashValue(&hash, field.maskY)
		WorldHashValue(&hash, field.buildHead)
		WorldHashValue(&hash, field.buildTail)
		WorldHashValue(&hash, field.seeded)
		WorldHashValue(&hash, field.maskKingdom)
		WorldHashValue(&hash, field.maskWater)
		WorldHashValue(&hash, field.maskRevision)
		if field.valid || field.building do WorldHashValue(&hash, field.direction)
		if field.building && field.buildMask {
			WorldHashValue(&hash, field.walkMask[:field.maskIndex])
		} else {
			WorldHashValue(&hash, field.walkMask)
		}
	}
	if w.flowBuildCount > 0 {
		field := &w.flowFields[w.flowBuildQueue[w.flowBuildHead]]
		if field.building && field.seeded {
			for i in field.buildHead..<field.buildTail do WorldHashValue(&hash, w.flowQueue[i])
		}
	}
	return hash
}

@(test)
WorldStateHashCoverage :: proc(t: ^testing.T) {
	w := new(World)
	defer free(w)

	baseline := WorldStateHash(w)
	testing.expect(t, baseline == WorldStateHash(w))
	w.units.health[7] = d32.FromInt(10)
	w.particleCount = 1
	w.simulationAccumulator = 0.5
	visible := [2]bool{true, false}
	explored := [2]bool{false, true}
	w.fog.visible = visible[:]
	w.fog.explored = explored[:]
	w.observerKingdom = 1
	w.playerKingdom = 1
	testing.expect(t, baseline == WorldStateHash(w))
	visible[1] = true
	explored[0] = true
	w.observerKingdom = -1
	w.playerKingdom = -1
	testing.expect(t, baseline == WorldStateHash(w))
	w.fog.contacts[0][1] = true
	testing.expect(t, baseline != WorldStateHash(w))
	w.fog.contacts[0][1] = false
	testing.expect(t, baseline == WorldStateHash(w))
	w.particleRandom = 1
	testing.expect(t, baseline == WorldStateHash(w))

	w.unitUsed[7] = true
	w.units.type[7] = Builder{carriedResource = d32.FromInt(2)}
	unitHash := WorldStateHash(w)
	testing.expect(t, unitHash != baseline)
	w.units.type[7] = Builder{carriedResource = d32.FromInt(3)}
	testing.expect(t, unitHash != WorldStateHash(w))
	w.units.type[7] = Builder{carriedResource = d32.FromInt(2)}
	testing.expect(t, unitHash == WorldStateHash(w))

	w.kingdomUsed[0] = true
	w.kingdoms[0].townUsed[0] = true
	w.kingdoms[0].towns[0].wood = d32.FromInt(12)
	townHash := WorldStateHash(w)
	w.kingdoms[0].towns[0].wood = d32.FromInt(13)
	testing.expect(t, townHash != WorldStateHash(w))

	directionsA := [2]FlowDirection{.East, .West}
	directionsB := directionsA
	w.flowFields[0].valid = true
	w.flowFields[0].direction = directionsA[:]
	flowHash := WorldStateHash(w)
	w.flowFields[0].direction = directionsB[:]
	testing.expect(t, flowHash == WorldStateHash(w))
	directionsB[1] = .North
	testing.expect(t, flowHash != WorldStateHash(w))
}
