package main

import "core:math"

TOWN_SIMULATION_STEP :: 0.25
TOWN_ALARM_AREA_FACTOR :: 1.25
WORLD_DAY_LENGTH_SECONDS :: 7*60.0

// Population growth is cohort-based: an era defines how many villagers arrive
// together and how long the next cohort takes. Supply and unconverted villagers
// speed up the countdown rather than changing the cohort size.
GROWTH_FOOD_PER_CITIZEN :: 0.025
GROWTH_MIN_SPEED :: 0.25
GROWTH_MAX_SPEED :: 1.25
GROWTH_VILLAGER_SPEED_BONUS :: 0.005
GROWTH_VILLAGER_SPEED_CAP :: 0.5
GROWTH_MAX_SPAWN_PER_TICK :: 32

WorldUpdate :: proc(w: ^World, deltaTime: f32) {
	if deltaTime <= 0 do return
	// Particles and gore run on the render clock so they stay smooth between
	// the coarse town simulation ticks.
	WorldParticleUpdate(w, deltaTime)
	w.simulationAccumulator += deltaTime
	for w.simulationAccumulator >= TOWN_SIMULATION_STEP {
		w.simulationTime += TOWN_SIMULATION_STEP
		w.dayTime += TOWN_SIMULATION_STEP
		if w.dayTime >= f32(WORLD_DAY_LENGTH_SECONDS) {
			w.dayTime -= f32(WORLD_DAY_LENGTH_SECONDS)
			w.dayNumber += 1
		}
		WorldUnitUpdate(w, TOWN_SIMULATION_STEP)
		WorldBuildingUpdate(w, TOWN_SIMULATION_STEP)
		WorldFireUpdate(w, TOWN_SIMULATION_STEP)
		WorldDecorationUpdate(w, TOWN_SIMULATION_STEP)
		BloodUpdate(w, TOWN_SIMULATION_STEP)
		WorldControllersUpdate(w, TOWN_SIMULATION_STEP)
		WorldKingdomUpdate(w, TOWN_SIMULATION_STEP)
		FogUpdate(w)
		w.simulationAccumulator -= TOWN_SIMULATION_STEP
	}
	WorldCheckGameEnd(w)
}

WorldTimeOfDay :: proc(w: ^World) -> f32 {
	return w.dayTime*24/f32(WORLD_DAY_LENGTH_SECONDS)
}

WorldNightAmount :: proc(w: ^World) -> f32 {
	hour := WorldTimeOfDay(w)
	if hour < 4.5 || hour >= 22 do return 1
	if hour < 6.5 do return 1-(hour-4.5)/2
	if hour < 18.5 do return 0
	return (hour-18.5)/3.5
}

// Deep night is where the world is dark enough to shorten unit vision. Dusk
// and dawn ramp in and out, so the threshold keeps the change from flickering.
WorldIsNight :: proc(w: ^World) -> bool {
	return WorldNightAmount(w) >= 0.5
}

WorldTownExists :: proc(w: ^World, kingdomSlot, townSlot: int) -> bool {
	return kingdomSlot >= 0 && kingdomSlot < KINGDOM_SLOTS &&
		townSlot >= 0 && townSlot < TOWN_CAPACITY &&
		w.kingdomUsed[kingdomSlot] && w.kingdoms[kingdomSlot].townUsed[townSlot]
}

// Scan each town once, rather than repeating the proximity query per sleeper.
WorldTownAlarmUpdate :: proc(w: ^World) {
	for kingdom in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[kingdom] do continue
		for townSlot in 0..<TOWN_CAPACITY {
			if !w.kingdoms[kingdom].townUsed[townSlot] do continue
			town := &w.kingdoms[kingdom].towns[townSlot]
			town.alarmActive = TownHasNearbyEnemy(w, kingdom, townSlot)
		}
	}
}

TownHasNearbyEnemy :: proc(w: ^World, kingdom, townSlot: int) -> bool {
	if !WorldTownExists(w, kingdom, townSlot) do return false
	chunkSize := w.spatial.chunkSize
	if chunkSize <= 0 || w.spatial.chunksX <= 0 || w.spatial.chunksY <= 0 do return false
	width, height := BuildingTileSize(TownHall{})

	for circleIndex in 0..<TownAreaCircleCount(w, kingdom, townSlot) {
		circleX, circleY, circleRadius := TownAreaCircle(w, kingdom, townSlot, circleIndex)
		centerX := f32(circleX)+f32(width-1)*0.5
		centerY := f32(circleY)+f32(height-1)*0.5
		radius := f32(circleRadius)*TOWN_ALARM_AREA_FACTOR
		chunkRadius := int((radius+f32(max(width, height)))/f32(chunkSize))+1
		centerChunkX, centerChunkY := int(centerX)/chunkSize, int(centerY)/chunkSize
		for offsetX in 0..<min(chunkRadius*2+1, w.spatial.chunksX) {
			chunkX := WorldWrapCoordinate(centerChunkX-chunkRadius+offsetX, w.spatial.chunksX)
			for offsetY in 0..<min(chunkRadius*2+1, w.spatial.chunksY) {
				chunkY := WorldWrapCoordinate(centerChunkY-chunkRadius+offsetY, w.spatial.chunksY)
				chunk := chunkX*w.spatial.chunksY+chunkY
				for unit := w.spatial.unitHead[chunk]; unit >= 0; unit = w.spatial.unitNext[unit] {
					if !w.unitUsed[unit] || UnitHiddenInside(w, unit) do continue
					if !KingdomAtWar(w, kingdom, w.units[unit].kingdome) do continue
					dx := math.abs(WorldShortestWrappedDelta(f32(int(w.units.x[unit]))-centerX, f32(w.maxX)))
					dy := math.abs(WorldShortestWrappedDelta(f32(int(w.units.y[unit]))-centerY, f32(w.maxY)))
					dx = max(0, dx-f32(width-1)*0.5)
					dy = max(0, dy-f32(height-1)*0.5)
					if dx*dx+dy*dy <= radius*radius do return true
				}
			}
		}
	}
	return false
}

WorldUnitUpdate :: proc(w: ^World, deltaTime: f32) {
	WorldHousingUpdate(w)
	WorldTownAlarmUpdate(w)
	for unitSlot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[unitSlot] do continue
		w.units.previousX[unitSlot] = w.units.x[unitSlot]
		w.units.previousY[unitSlot] = w.units.y[unitSlot]
	}

	for kingdomSlot in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[kingdomSlot] do continue
		for townSlot in 0..<TOWN_CAPACITY {
			if !w.kingdoms[kingdomSlot].townUsed[townSlot] do continue
			town := &w.kingdoms[kingdomSlot].towns[townSlot]
			town.builders = 0
			town.waterCollectors = 0
			town.farmers = 0
			town.villagers = 0
		}
	}

	for unitSlot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[unitSlot] do continue
		UnitUpdateMilitaryAlarm(w, unitSlot)
		if _, converting := w.units[unitSlot].state.(StateConverting); converting {
			if UnitUpdatePacificSafety(w, unitSlot, deltaTime) do continue
			UnitUpdateConverting(w, unitSlot, deltaTime)
			continue
		}
		switch _ in w.units[unitSlot].type {
		case Villager:
			UnitUpdateVillager(w, unitSlot, deltaTime)
		case Builder:
			UnitUpdateBuilder(w, unitSlot, deltaTime)
		case CombatBuilder:
			CombatBuilderUpdate(w, unitSlot, deltaTime)
		case WaterCollector:
			UnitUpdateWaterCollector(w, unitSlot, deltaTime)
		case Farmer:
			UnitUpdateFarmer(w, unitSlot, deltaTime)
		case Explorer:
			UnitUpdateExplorer(w, unitSlot, deltaTime)
		case Knight, Archer, Mage, Giant, Turtle, Catapult, Rogue:
			if w.units[unitSlot].kingdome == NEUTRAL_KINGDOM {
				UnitUpdateIndependentKnight(w, unitSlot, deltaTime)
			} else {
				UnitUpdateWarrior(w, unitSlot, deltaTime)
			}
		}
		if w.unitUsed[unitSlot] do BloodBleedTick(w, unitSlot, deltaTime)
	}
}

WorldKingdomUpdate :: proc(w: ^World, deltaTime: f32) {
	for kingdomSlot in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[kingdomSlot] do continue
		for townSlot in 0..<TOWN_CAPACITY {
			if !w.kingdoms[kingdomSlot].townUsed[townSlot] do continue
			KingdomTownUpdate(w, kingdomSlot, townSlot, deltaTime)
		}
	}

	WorldHousingUpdate(w)
	shortageEpoch := int(w.simulationTime / 5)
	for unitSlot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[unitSlot] do continue
		kingdomSlot := w.units[unitSlot].kingdome
		townSlot := w.units[unitSlot].town
		if !WorldTownExists(w, kingdomSlot, townSlot) {
			UnitClearTownEffects(w, unitSlot)
			continue
		}

		isHoused := UnitHome(w, unitSlot) >= 0
		UnitApplyTownEffects(w, unitSlot, isHoused, shortageEpoch, deltaTime)
	}

	WorldConversionAssign(w)
}

// Keep the existing slot-order housing entitlement, but give each housed citizen
// a persistent Home identity. Awake citizens (including soldiers) reserve capacity
// too, so sleep and the NoHome/regeneration effects cannot disagree.
WorldHousingUpdate :: proc(w: ^World) {
	remaining: [KINGDOM_SLOTS][TOWN_CAPACITY]int
	for home in 0..<BUILDING_CAPACITY {
		if !w.buildingUsed[home] do continue
		building := &w.buildings[home]
		if BuildingKindOf(building.type) != .Home || building.health <= 0 ||
			!WorldTownExists(w, building.kingdom, building.town) {
			continue
		}
		remaining[building.kingdom][building.town] += 1
	}

	for slot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[slot] do continue
		unit := &w.units[slot]
		eligible := false
		if WorldTownExists(w, unit.kingdome, unit.town) {
			eligible = remaining[unit.kingdome][unit.town] > 0
			if eligible do remaining[unit.kingdome][unit.town] -= 1
		}
		if !eligible || UnitHome(w, slot) < 0 do UnitReleaseHome(w, slot)
		if unit.sleepInside && UnitInsideHome(w, slot) < 0 do UnitSleepWake(w, slot)
	}

	freeHome: [KINGDOM_SLOTS][TOWN_CAPACITY]int
	for &kingdom in freeHome do for &town in kingdom do town = -1
	nextHome: [BUILDING_CAPACITY]int
	for home in 0..<BUILDING_CAPACITY {
		if !w.buildingUsed[home] do continue
		building := &w.buildings[home]
		resident := building.homeResident-1
		if resident >= 0 && resident < UNIT_CAPACITY && UnitHome(w, resident) == home do continue
		building.homeResident = 0
		if BuildingKindOf(building.type) != .Home || building.health <= 0 ||
			!WorldTownExists(w, building.kingdom, building.town) {
			continue
		}
		nextHome[home] = freeHome[building.kingdom][building.town]
		freeHome[building.kingdom][building.town] = home
	}
	for slot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[slot] || UnitHome(w, slot) >= 0 do continue
		unit := &w.units[slot]
		if !WorldTownExists(w, unit.kingdome, unit.town) do continue
		head := &freeHome[unit.kingdome][unit.town]
		// Only newly assigned citizens search; existing reservations never shuffle.
		best, previous, bestPrevious := -1, -1, -1
		bestDistance: f32 = 0
		for home := head^; home >= 0; home = nextHome[home] {
			dx := WorldShortestWrappedDelta(f32(w.buildings.x[home])+0.5-unit.x, f32(w.maxX))
			dy := WorldShortestWrappedDelta(f32(w.buildings.y[home])+0.5-unit.y, f32(w.maxY))
			distance := dx*dx+dy*dy
			if best < 0 || distance < bestDistance {
				best, bestPrevious, bestDistance = home, previous, distance
			}
			previous = home
		}
		if best < 0 do continue
		if bestPrevious < 0 {
			head^ = nextHome[best]
		} else {
			nextHome[bestPrevious] = nextHome[best]
		}
		UnitSleepWake(w, slot)
		unit.homeSlot = best
		w.buildings.homeResident[best] = slot+1
	}
}

// Assigns idle units to queued conversions. Runs once per simulation step over
// all units, so the cost stays linear in the number of units rather than towns.
WorldConversionAssign :: proc(w: ^World) {
	for unitSlot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[unitSlot] do continue
		unit := &w.units[unitSlot]
		if _, converting := unit.state.(StateConverting); converting do continue
		if !WorldTownExists(w, unit.kingdome, unit.town) do continue

		town := &w.kingdoms[unit.kingdome].towns[unit.town]
		if town.conversionCount == 0 do continue
		if !UnitIsWarrior(unit.type) && UnitKindOf(unit.type) != .CombatBuilder {
			if town.alarmActive || UnitFindNearbyEnemy(w, unitSlot, FLEE_THREAT_RADIUS) >= 0 do continue
			if state, pacific := unit.state.(StatePacific); pacific && (state == .Hiding || state == .Fleeing) do continue
		}

		from := UnitKindOf(unit.type)
		for jobIndex in 0..<town.conversionCount {
			job := &town.conversions[jobIndex]
			if job.from != from || job.assigned >= job.remaining do continue

			building := TownFindBuilding(
				w,
				unit.kingdome,
				unit.town,
				UnitTrainingBuildingKind(job.to),
			)
			if building < 0 do continue
			accessX, accessY, found := UnitFindBuildingAccessPoint(
				w,
				unitSlot,
				building,
				UnitTypeFromKind(job.to),
			)
			if !found do continue

			job.assigned += 1
			UnitSleepWake(w, unitSlot)
			unit.state = StateConverting{
				to = job.to,
				building = building,
				accessX = accessX,
				accessY = accessY,
			}
			unit.pathReady = false
			break
		}
	}
}

KingdomTownUpdate :: proc(w: ^World, kingdomSlot, townSlot: int, deltaTime: f32) {
	town := &w.kingdoms[kingdomSlot].towns[townSlot]

	workingFarmlands := min(town.farmlands, town.farmers)
	town.foodPotential = 0
	if town.farmlands > 0 {
		town.foodPotential = town.farmlandOutput*f32(workingFarmlands)/f32(town.farmlands)
	}
	town.waterPotential =
		TownWaterCollectorOutput(TownWaterAccess(w, kingdomSlot, townSlot))*
		f32(town.waterCollectors)
	town.foodShortage = TownResourceShortage(town.foodPotential, town.citizens)
	town.waterShortage = TownResourceShortage(town.waterPotential, town.citizens)

	era := TownEra(w, kingdomSlot, townSlot)
	town.growthInterval = TOWN_ERAS[era].interval
	town.growthBatch = TownEffectiveBatch(w, kingdomSlot, townSlot)
	town.growthRate = f32(town.growthBatch)/town.growthInterval

	populationNeed := f32(town.citizens+town.growthBatch)*GROWTH_FOOD_PER_CITIZEN
	canGrow := town.foodPotential >= populationNeed && town.waterPotential >= populationNeed
	limitingSupply := min(town.foodPotential, town.waterPotential)
	coverage: f32 = 1
	if populationNeed > 0 {
		coverage = clamp(limitingSupply/populationNeed, 0, 1.5)
	}
	// A town always grows at least at the minimum speed, even with no food or
	// water at all, so a bad start cannot permanently strand it.
	speed := clamp(coverage, GROWTH_MIN_SPEED, GROWTH_MAX_SPEED)
	speed *= 1+min(GROWTH_VILLAGER_SPEED_CAP, f32(town.villagers)*GROWTH_VILLAGER_SPEED_BONUS)
	town.growthSpeed = speed

	town.growthCooldown -= deltaTime*speed
	if town.growthCooldown <= 0 {
		if town.growthPending <= 0 do town.growthPending = town.growthBatch
		spawnNow := min(town.growthPending, GROWTH_MAX_SPAWN_PER_TICK)
		spawned := TownSpawnCitizens(w, kingdomSlot, townSlot, spawnNow)
		if spawned > 0 {
			town.growthPending -= spawned
			if kingdomSlot == w.observerKingdom {
				WorldAlertAddGrowth(w, kingdomSlot, townSlot, spawned, town.citizens)
			}
		}
		if town.growthPending <= 0 {
			town.growthPending = 0
			town.growthCooldown = town.growthInterval
		} else {
			town.growthCooldown = 0
		}
	}

	if town.builders > 0 {
		town.constructionProgress += f32(town.builders)*deltaTime
		if town.constructionProgress >= 3 {
			if TownBuilderConstruct(w, kingdomSlot, townSlot, canGrow) {
				town.constructionProgress -= 3
			} else {
				town.constructionProgress = min(town.constructionProgress, 3)
			}
		}
	}

	TownMilestoneCheck(w, kingdomSlot, townSlot)
}


TownResourceShortage :: proc(potential: f32, citizens: int) -> f32 {
	need := f32(citizens)*0.025
	if need <= 0 do return 0
	return clamp(1-potential/need, 0, 1)
}

// Each collector produces a baseline even with no fresh water in reach; nearby
// lakes and rivers add the rest. Island towns therefore keep growing, just on a
// smaller and more expensive water supply.
WATER_COLLECTOR_MAX_OUTPUT :: 0.20
WATER_COLLECTOR_DRY_OUTPUT :: 0.10

TownWaterCollectorOutput :: proc(waterAccess: f32) -> f32 {
	access := clamp(waterAccess, 0, 1)
	return WATER_COLLECTOR_DRY_OUTPUT+
		(WATER_COLLECTOR_MAX_OUTPUT-WATER_COLLECTOR_DRY_OUTPUT)*access
}

TownWaterAccess :: proc(w: ^World, kingdomSlot, townSlot: int) -> f32 {
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	if town.waterAccessCached && town.waterAccessTerrainRevision == w.terrainRevision {
		return town.waterAccess
	}

	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 do return 0

	centerX := town.x+2
	centerY := town.y+2
	nearestDistanceSquared: f32 = 0
	foundWater := false
	for x in 0..<worldWidth {
		for y in 0..<worldHeight {
			tileType := w.ground[x][y].type
			if tileType != .FreshWater && tileType != .River do continue
			deltaX := WorldShortestWrappedDelta(f32(x-centerX), f32(worldWidth))
			deltaY := WorldShortestWrappedDelta(f32(y-centerY), f32(worldHeight))
			distanceSquared := deltaX*deltaX + deltaY*deltaY
			if !foundWater || distanceSquared < nearestDistanceSquared {
				nearestDistanceSquared = distanceSquared
				foundWater = true
			}
		}
	}

	town.waterAccess = 0
	if foundWater do town.waterAccess = 1/(1+math.sqrt(nearestDistanceSquared))
	town.waterAccessTerrainRevision = w.terrainRevision
	town.waterAccessCached = true
	return town.waterAccess
}

TownSpawnCitizen :: proc(w: ^World, kingdomSlot, townSlot: int, role: UnitType) -> int {
	if !WorldTownExists(w, kingdomSlot, townSlot) do return -1
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)

	// New villagers step out of the town hall door first.
	for offsetX in 0 ..= 1 {
		x := town.x+1+offsetX
		y := town.y+4
		if x < 0 || y < 0 || x >= worldWidth || y >= worldHeight do continue
		if !UnitValidTileType(role, w.ground[x][y].type) || WorldTileOccupied(w, x, y) do continue
		if WorldUnitAtTile(w, x, y) do continue
		if unitSlot, ok := UnitSpawn(w, role, f32(x)+0.5, f32(y)+0.5, kingdomSlot, townSlot); ok {
			return unitSlot
		}
	}

	for radius in 1..=8 {
		minX := max(0, town.x-radius)
		maxX := min(worldWidth-1, town.x+4+radius)
		minY := max(0, town.y-radius)
		maxY := min(worldHeight-1, town.y+4+radius)
		for x in minX..=maxX {
			for y in minY..=maxY {
				if x >= town.x && x < town.x+4 && y >= town.y && y < town.y+4 do continue
				if !UnitValidTileType(role, w.ground[x][y].type) || WorldTileOccupied(w, x, y) do continue
				if WorldUnitAtTile(w, x, y) do continue
				if unitSlot, ok := UnitSpawn(w, role, f32(x)+0.5, f32(y)+0.5, kingdomSlot, townSlot); ok {
					return unitSlot
				}
			}
		}
	}

	// A merged town can be much larger than the eight-tile ring above. Sweep the
	// whole compound area so cohorts are not lost when the old hall is crowded.
	areaMinX, areaMaxX, areaMinY, areaMaxY := TownAreaBounds(w, kingdomSlot, townSlot)
	minX := max(0, areaMinX)
	maxX := min(worldWidth-1, areaMaxX)
	minY := max(0, areaMinY)
	maxY := min(worldHeight-1, areaMaxY)
	for x in minX..=maxX {
		for y in minY..=maxY {
			if !TownPointInArea(w, kingdomSlot, townSlot, x, y) do continue
			if !UnitValidTileType(role, w.ground[x][y].type) || WorldTileOccupied(w, x, y) do continue
			if WorldUnitAtTile(w, x, y) do continue
			if unitSlot, ok := UnitSpawn(w, role, f32(x)+0.5, f32(y)+0.5, kingdomSlot, townSlot); ok {
				return unitSlot
			}
		}
	}
	return -1
}

// Spawns as many villagers as there is room for, returning the number created.
// A partial batch is carried over by the caller instead of being lost.
TownSpawnCitizens :: proc(w: ^World, kingdomSlot, townSlot, count: int) -> int {
	spawned := 0
	for _ in 0..<count {
		if TownSpawnCitizen(w, kingdomSlot, townSlot, Villager{}) < 0 do break
		spawned += 1
	}
	return spawned
}

TOWN_INITIAL_VILLAGERS :: 8

TownSpawnInitialPopulation :: proc(w: ^World, kingdomSlot, townSlot: int) -> bool {
	for _ in 0..<TOWN_INITIAL_VILLAGERS {
		if TownSpawnCitizen(w, kingdomSlot, townSlot, Villager{}) < 0 do return false
	}
	return true
}
