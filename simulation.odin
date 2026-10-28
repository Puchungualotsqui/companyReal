package main

import "core:math"

TOWN_SIMULATION_STEP :: 0.25
TOWN_ALARM_AREA_FACTOR :: 1.25
WORLD_DAY_LENGTH_SECONDS :: 7*60.0

// --- weather ---------------------------------------------------------------

SEASONS_PER_YEAR :: 4
WEATHER_MIN_SECONDS :: 90
WEATHER_MAX_SECONDS :: 180
WEATHER_RAMP_IN :: 25
WEATHER_RAMP_OUT :: 15
WEATHER_LIGHTNING_DECAY :: 2.5
GAS_CLOUD_WIND_DRIFT :: 0.8

Season :: enum u8 {
	Spring,
	Summer,
	Autumn,
	Winter,
}

WeatherKind :: enum u8 {
	Clear,
	Rain,
	Storm,
	Fog,
	Snow,
	Blizzard,
	Drought,
	Heatwave,
	Sandstorm,
	Ashfall,
}

WeatherState :: struct {
	kind:           WeatherKind,
	nextKind:       WeatherKind,
	value:          f32,
	duration:       f32,
	remaining:      f32,
	windX, windY:   f32,
	season:         Season,
	sequence:       u32,
	lightningTimer: f32,
	lightningFlash: f32,
}

WeatherEffects :: struct {
	food:            f32,
	water:           f32,
	growth:          f32,
	vision:          f32,
	move:            f32,
	fireSpread:      f32,
	fireIgnition:    f32,
	fireExtinguish:  f32,
	harbor:          f32,
	exposure:        f32,
}

WorldSeason :: proc(w: ^World) -> Season {
	return Season(w.dayNumber%SEASONS_PER_YEAR)
}

WorldWeatherEffects :: proc(w: ^World) -> WeatherEffects {
	full := WeatherEffects {
		food = 1,
		water = 1,
		growth = 1,
		vision = 1,
		move = 1,
		fireSpread = 1,
		fireIgnition = 1,
		fireExtinguish = 1,
		harbor = 1,
	}
	switch w.weather.kind {
	case .Clear:
	case .Rain:
		full = WeatherEffects {
			food = 1.15,
			water = 1.30,
			growth = 1.10,
			vision = 0.85,
			move = 0.92,
			fireSpread = 0.25,
			fireIgnition = 0.45,
			fireExtinguish = 2.0,
			harbor = 0.9,
		}
	case .Storm:
		full = WeatherEffects {
			food = 1.05,
			water = 1.25,
			growth = 0.95,
			vision = 0.65,
			move = 0.80,
			fireSpread = 0.10,
			fireIgnition = 0.25,
			fireExtinguish = 2.5,
			harbor = 0.5,
		}
	case .Fog:
		full = WeatherEffects {
			food = 0.95,
			growth = 0.95,
			vision = 0.50,
			move = 0.90,
			fireSpread = 0.70,
			fireIgnition = 0.90,
			fireExtinguish = 1.2,
			harbor = 0.9,
		}
	case .Snow:
		full = WeatherEffects {
			food = 0.82,
			water = 1.10,
			growth = 0.70,
			vision = 0.85,
			move = 0.78,
			fireSpread = 0.15,
			fireIgnition = 0.25,
			fireExtinguish = 2.0,
			harbor = 0.8,
			exposure = 0.0006,
		}
	case .Blizzard:
		full = WeatherEffects {
			food = 0.65,
			water = 0.90,
			growth = 0.00,
			vision = 0.45,
			move = 0.60,
			fireSpread = 0.00,
			fireIgnition = 0.00,
			fireExtinguish = 4.0,
			harbor = 0.3,
			exposure = 0.0018,
		}
	case .Drought:
		full = WeatherEffects {
			food = 0.75,
			water = 0.45,
			growth = 0.72,
			move = 0.95,
			fireSpread = 1.70,
			fireIgnition = 1.25,
			fireExtinguish = 0.7,
			harbor = 0.9,
			exposure = 0.0004,
		}
	case .Heatwave:
		full = WeatherEffects {
			food = 0.86,
			water = 0.72,
			growth = 0.85,
			vision = 0.95,
			move = 0.90,
			fireSpread = 1.40,
			fireIgnition = 1.20,
			fireExtinguish = 0.8,
			harbor = 0.9,
			exposure = 0.0012,
		}
	case .Sandstorm:
		full = WeatherEffects {
			food = 0.80,
			water = 0.90,
			growth = 0.80,
			vision = 0.45,
			move = 0.70,
			fireSpread = 0.80,
			fireIgnition = 0.70,
			fireExtinguish = 1.0,
			harbor = 0.5,
			exposure = 0.0020,
		}
	case .Ashfall:
		full = WeatherEffects {
			food = 0.80,
			water = 0.90,
			growth = 0.75,
			vision = 0.60,
			move = 0.90,
			fireSpread = 0.50,
			fireIgnition = 0.60,
			fireExtinguish = 1.2,
			harbor = 0.8,
			exposure = 0.0008,
		}
	}

	value := clamp(w.weather.value, 0, 1)
	return WeatherEffects {
		food = 1+(full.food-1)*value,
		water = 1+(full.water-1)*value,
		growth = 1+(full.growth-1)*value,
		vision = 1+(full.vision-1)*value,
		move = 1+(full.move-1)*value,
		fireSpread = 1+(full.fireSpread-1)*value,
		fireIgnition = 1+(full.fireIgnition-1)*value,
		fireExtinguish = 1+(full.fireExtinguish-1)*value,
		harbor = 1+(full.harbor-1)*value,
		exposure = full.exposure*value,
	}
}

WorldWeatherVisionFactor :: proc(w: ^World) -> f32 {
	return WorldWeatherEffects(w).vision
}

WorldWeatherMoveFactor :: proc(w: ^World) -> f32 {
	return WorldWeatherEffects(w).move
}

WorldWeatherPick :: proc(w: ^World, season: Season, current: WeatherKind) -> WeatherKind {
	weights: [WeatherKind]f32
	switch season {
	case .Spring:
		weights[.Clear] = 30
		weights[.Rain] = 40
		weights[.Storm] = 10
		weights[.Fog] = 20
	case .Summer:
		weights[.Clear] = 26
		weights[.Rain] = 14
		weights[.Storm] = 16
		weights[.Fog] = 6
		weights[.Heatwave] = 20
		weights[.Drought] = 18
	case .Autumn:
		weights[.Clear] = 24
		weights[.Rain] = 32
		weights[.Storm] = 20
		weights[.Fog] = 24
	case .Winter:
		weights[.Clear] = 18
		weights[.Rain] = 6
		weights[.Snow] = 42
		weights[.Blizzard] = 14
		weights[.Fog] = 20
	}
	if current != .Clear do weights[current] *= 0.12

	total: f32 = 0
	for kind in WeatherKind do total += weights[kind]
	if total <= 0 do return .Clear
	roll := WorldNoiseHash(int(w.weather.sequence), int(season)+13, w.seed+0x7EA5E)*total
	for kind in WeatherKind {
		roll -= weights[kind]
		if roll <= 0 do return kind
	}
	return .Clear
}

WorldWeatherTransition :: proc(w: ^World, kind: WeatherKind) {
	w.weather.kind = kind
	w.weather.sequence += 1
	w.weather.season = WorldSeason(w)

	duration := WEATHER_MIN_SECONDS+
		WorldNoiseHash(int(w.weather.sequence), 5, w.seed+0x71EA)*f32(WEATHER_MAX_SECONDS-WEATHER_MIN_SECONDS)
	switch kind {
	case .Clear:
		duration *= 1.25
	case .Storm, .Blizzard:
		duration *= 0.8
	case .Drought:
		duration *= 1.15
	case .Rain, .Fog, .Snow, .Heatwave, .Sandstorm, .Ashfall:
	}
	w.weather.duration = duration
	w.weather.remaining = duration
	w.weather.nextKind = WorldWeatherPick(w, w.weather.season, kind)

	speed: f32 = 0.03
	switch kind {
	case .Clear:
		speed = 0.03
	case .Rain:
		speed = 0.16
	case .Storm:
		speed = 0.50
	case .Fog:
		speed = 0.02
	case .Snow:
		speed = 0.14
	case .Blizzard:
		speed = 0.55
	case .Drought:
		speed = 0.10
	case .Heatwave:
		speed = 0.06
	case .Sandstorm:
		speed = 0.60
	case .Ashfall:
		speed = 0.15
	}
	angle := WorldNoiseHash(int(w.weather.sequence), 7, w.seed+0x31D)*6.2831853
	w.weather.windX = math.cos(angle)*speed
	w.weather.windY = math.sin(angle)*speed
	w.weather.lightningTimer = 1.5+WorldNoiseHash(int(w.weather.sequence), 9, w.seed+0x4A1)*3
}

WorldWeatherUpdate :: proc(w: ^World, deltaTime: f32) {
	if deltaTime <= 0 do return

	season := WorldSeason(w)
	if season != w.weather.season {
		newKind := WorldWeatherPick(w, season, w.weather.kind)
		WorldWeatherTransition(w, newKind)
	}
	w.weather.remaining = max(w.weather.remaining-deltaTime, 0)
	if w.weather.remaining <= 0 do WorldWeatherTransition(w, w.weather.nextKind)

	age := w.weather.duration-w.weather.remaining
	fadeIn := clamp(age/WEATHER_RAMP_IN, 0, 1)
	fadeOut := clamp(w.weather.remaining/WEATHER_RAMP_OUT, 0, 1)
	w.weather.value = min(fadeIn, fadeOut)

	if w.weather.kind == .Storm && w.weather.value > 0.3 {
		w.weather.lightningTimer -= deltaTime
		if w.weather.lightningTimer <= 0 {
			w.weather.lightningTimer = 1.5+
				WorldNoiseHash(int(w.simulationTime*4), int(w.weather.sequence), w.seed+0x11)*4
			w.weather.lightningFlash = 1
		}
	}
	w.weather.lightningFlash = max(w.weather.lightningFlash-deltaTime*WEATHER_LIGHTNING_DECAY, 0)

	weatherEffects := WorldWeatherEffects(w)
	active := w.weather.value > 0.2
	wet := active && (w.weather.kind == .Rain || w.weather.kind == .Storm)
	cold := active && (w.weather.kind == .Snow || w.weather.kind == .Blizzard)
	heat := active && (w.weather.kind == .Heatwave || w.weather.kind == .Drought ||
		w.weather.kind == .Sandstorm)

	for unitSlot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[unitSlot] || w.units.type[unitSlot] == nil do continue
		hidden := UnitHiddenInside(w, unitSlot)
		w.units.effects[unitSlot][.Wet] = wet && !hidden
		w.units.effects[unitSlot][.Chilled] = cold && !hidden
		w.units.effects[unitSlot][.HeatStressed] = heat && !hidden
		if hidden || weatherEffects.exposure <= 0 do continue

		tileX := int(WorldWrapPosition(w.units.x[unitSlot], f32(w.maxX)))
		tileY := int(WorldWrapPosition(w.units.y[unitSlot], f32(w.maxY)))
		climate := w.ground[tileX][tileY].climate
		tile := w.ground[tileX][tileY].type
		coldTile := climate == .Boreal || tile == .Tundra || tile == .Ice
		hotTile := climate == .Arid || climate == .Volcanic || tile == .Desert || tile == .Ash

		exposure := weatherEffects.exposure
		switch w.weather.kind {
		case .Snow:
			exposure = coldTile ? exposure*1.5 : 0
		case .Blizzard:
			exposure *= coldTile ? 1.5 : 0.7
		case .Drought:
			exposure = hotTile ? exposure : 0
		case .Heatwave:
			exposure *= hotTile ? 1.5 : 0.6
		case .Sandstorm:
			exposure *= hotTile ? 1.5 : 0.5
		case .Ashfall:
		case .Clear, .Rain, .Storm, .Fog:
			exposure = 0
		}
		if exposure <= 0 do continue
		damage := UnitMaxHealth(w, unitSlot)*exposure*deltaTime
		UnitApplyDamage(
			w,
			unitSlot,
			damage,
			w.units.x[unitSlot],
			w.units.y[unitSlot],
			.Weather,
		)
	}
}

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
		WorldWeatherUpdate(w, TOWN_SIMULATION_STEP)
		WorldUnitUpdate(w, TOWN_SIMULATION_STEP)
		WorldBuildingUpdate(w, TOWN_SIMULATION_STEP)
		WorldAegisUpdate(w, TOWN_SIMULATION_STEP)
		WorldFireUpdate(w, TOWN_SIMULATION_STEP)
		WorldDecorationUpdate(w, TOWN_SIMULATION_STEP)
		BloodUpdate(w, TOWN_SIMULATION_STEP)
		WorldControllersUpdate(w, TOWN_SIMULATION_STEP)
		WorldKingdomUpdate(w, TOWN_SIMULATION_STEP)
		WorldHazardUpdate(w, TOWN_SIMULATION_STEP)
		WorldGasCloudUpdate(w, TOWN_SIMULATION_STEP)
		FogUpdate(w)
		w.simulationAccumulator -= TOWN_SIMULATION_STEP
	}
	WorldUnitAnimationUpdate(w, deltaTime)
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
			UnitUpdateWarrior(w, unitSlot, deltaTime)
		}
		if w.unitUsed[unitSlot] {
			BloodBleedTick(w, unitSlot, deltaTime)
			if w.units.previousX[unitSlot] != w.units.x[unitSlot] ||
				w.units.previousY[unitSlot] != w.units.y[unitSlot] {
				UnitWaterWake(w, unitSlot)
			}
		}
	}
	WorldMeleeSeparation(w)
}

WorldKingdomUpdate :: proc(w: ^World, deltaTime: f32) {
	for kingdomSlot in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[kingdomSlot] do continue
		w.kingdoms[kingdomSlot].coastalTownCount = 0
		for townSlot in 0..<TOWN_CAPACITY {
			if !w.kingdoms[kingdomSlot].townUsed[townSlot] do continue
			if TownIsCoastal(w, kingdomSlot, townSlot) {
				w.kingdoms[kingdomSlot].coastalTownCount += 1
			}
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
		assignedOrder: WarriorOrder = WarriorIdle{}
		if state, warrior := unit.state.(StateWarrior); warrior {
			if state.retreating do continue
			assignedOrder = state.order
		}
		if builder, combatBuilder := unit.type.(CombatBuilder); combatBuilder {
			if builder.returning do continue
			assignedOrder = builder.order
		}
		// Controllers can remove an order after this tick's unit updates.
		switch order in assignedOrder {
		case WarriorAttack:
			if !WorldTownExists(w, order.kingdom, order.town) ||
				!town.attackOrders[order.kingdom][order.town] {
				continue
			}
		case WarriorDefend:
			if !WorldTownExists(w, order.kingdom, order.town) ||
				!town.defendOrders[order.kingdom][order.town] {
				continue
			}
		case WarriorIdle, WarriorGarrison:
		}
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
			buildingX := w.buildings.x[building]
			buildingY := w.buildings.y[building]
			width, height := BuildingTileSize(w.buildings[building].type)
			// Choose an access point reachable from the unit, not merely the
			// nearest walkable ring tile.
			accessX, accessY, found := BuildingFindWorkAccessPoint(
				w,
				buildingX,
				buildingY,
				width,
				height,
				unit.type,
				unit.kingdome,
				int(WorldWrapPosition(unit.x, f32(w.maxX))),
				int(WorldWrapPosition(unit.y, f32(w.maxY))),
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
	weather := WorldWeatherEffects(w)

	workingFarmlands := min(town.farmlands, town.farmers)

	// Blockade is a visible town-level condition with a fixed multiplier.
	blockadeFactor: f32 = 1
	if town.blockadeUntil > w.simulationTime do blockadeFactor = 0.5

	town.foodPotential = 0
	if town.farmlands > 0 {
		town.foodPotential = town.farmlandOutput*f32(workingFarmlands)/f32(town.farmlands)
	}
	town.foodPotential *= KingdomTechFoodMultiplier(w, kingdomSlot, townSlot)*blockadeFactor*weather.food
	town.waterPotential =
		TownWaterCollectorOutput(TownWaterAccess(w, kingdomSlot, townSlot))*
		f32(town.waterCollectors)*KingdomTechWaterMultiplier(w, kingdomSlot, townSlot)*
		blockadeFactor*weather.water

	if TownFindBuilding(w, kingdomSlot, townSlot, .Harbor) >= 0 {
		town.wood += 0.05*deltaTime*weather.harbor
	}
	FishingFlotillaFx(w, kingdomSlot, townSlot)
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
	if town.blockadeUntil > w.simulationTime do speed *= 0.75
	speed *= weather.growth
	isNight := WorldIsNight(w)
	if isNight do speed = 0
	town.growthSpeed = speed

	town.growthCooldown -= deltaTime*speed
	if !isNight && weather.growth > 0.01 && town.growthCooldown <= 0 {
		if town.growthPending <= 0 do town.growthPending = town.growthBatch
		spawnNow := min(town.growthPending, GROWTH_MAX_SPAWN_PER_TICK)
		spawned := TownSpawnCitizens(w, kingdomSlot, townSlot, spawnNow)
		if spawned > 0 {
			town.growthPending -= spawned
			if kingdomSlot == w.observerKingdom {
				WorldAlertAddGrowth(w, kingdomSlot, townSlot, spawned)
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
			if TILE_DEFS[tileType].water <= 0 do continue
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
