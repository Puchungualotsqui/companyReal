package main

import rl "vendor:raylib"
import "core:math"

// Fire rules. A fire cell lives on a tile and burns whatever flammable entity
// sits there, so it can exist on empty ground too. Spread is probabilistic and
// can be disabled per fire.
FIRE_CAPACITY :: 8192
FIRE_DURATION :: 30
FIRE_SPREAD_RADIUS :: 2.5
FIRE_SPREAD_CHUNK_RADIUS :: 1
FIRE_SPREAD_CHANCE :: 0.08
FIRE_DECORATION_DAMAGE :: 6
FIRE_BUILDING_DAMAGE :: 5
FIRE_UNIT_DAMAGE :: 8
FIRE_UNIT_IGNITE_RADIUS :: 1.5
FIRE_UNIT_IGNITE_CHANCE :: 0.12
FIRE_UNIT_BURN_SECONDS :: 5

// Fire-seconds removed per second by a pacific unit fighting a fire.
FIRE_EXTINGUISH_RADIUS :: 1.6

UnitExtinguishRate :: proc(type: UnitType) -> f32 {
	switch _ in type {
	case WaterCollector:
		return 10
	case Villager:
		return 5
	case Builder, CombatBuilder, Farmer:
		return 4
	case Explorer:
		return 0
	case Knight, Archer, Mage, Giant, Turtle, Catapult, Rogue:
		return 0
	}
	return 0
}

Fire :: struct {
	x, y:      f32,
	intensity: f32,
	spread:    f32,
	remaining: f32,
	duration:  f32,
}

// Fire risk is a terrain property; zero-risk tiles cannot ignite or spread.
TileTypeAntiFire :: proc(tileType: TileType) -> bool {
	return TILE_DEFS[tileType].fireRisk <= 0
}

UnitImmuneToFire :: proc(type: UnitType) -> bool {
	switch _ in type {
	case Turtle, Catapult, Mage:
		return true
	case Villager, Builder, CombatBuilder, WaterCollector, Farmer, Knight, Archer, Giant, Rogue, Explorer:
		return false
	}
	unreachable()
}

BuildingImmuneToFire :: proc(kind: BuildingKind) -> bool {
	switch kind {
	case .TownHall, .Wall, .Cannon, .Watchtower, .MagicSchool, .TurtlePen, .Path, .GiantMortar, .Harbor, .StarfallSpire:
		return true
	case .Home, .Farmland, .Bridge, .ArcheryRange, .SiegeWorkshop, .GiantPen, .ThievesGuild, .DistrictHall, .Granary, .AlchemistWorkshop, .FireworksGuild:
		return false
	}
	unreachable()
}

FireAccessPoint :: proc(w: ^World, tileX, tileY: int, unitType: UnitType, unitKingdom: int) -> (int, int, bool) {
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 do return 0, 0, false
	if WorldTileWalkable(w, tileX, tileY, unitType, unitKingdom) do return tileX, tileY, true
	for radius in 1 ..= 2 {
		for x in tileX-radius ..= tileX+radius {
			for y in tileY-radius ..= tileY+radius {
				wrappedX := WorldWrapCoordinate(x, worldWidth)
				wrappedY := WorldWrapCoordinate(y, worldHeight)
				if WorldTileWalkable(w, wrappedX, wrappedY, unitType, unitKingdom) {
					return wrappedX, wrappedY, true
				}
			}
		}
	}
	return 0, 0, false
}

WorldFireAt :: proc(w: ^World, x, y: int) -> bool {
	chunk := SpatialChunkIndex(w, x, y)
	if chunk < 0 do return false
	for slot := w.spatial.fireHead[chunk]; slot >= 0; slot = w.spatial.fireNext[slot] {
		if int(w.fires.x[slot]) == x && int(w.fires.y[slot]) == y do return true
	}
	return false
}

WorldFireIgnite :: proc(w: ^World, x, y, intensity: f32, spread: f32 = 1) -> (int, bool) {
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 do return 0, false
	tileX := WorldWrapCoordinate(int(x), worldWidth)
	tileY := WorldWrapCoordinate(int(y), worldHeight)
	if TileTypeAntiFire(w.ground[tileX][tileY].type) do return 0, false
	if hazardKind, hasHazard := WorldHazardKindAt(w, tileX, tileY); hasHazard && hazardKind == .Flood {
		return 0, false
	}
	fireWeather := WorldWeatherEffects(w).fireIgnition
	if fireWeather <= 0 do return 0, false
	if fireWeather < 1 &&
		WorldNoiseHash(tileX, tileY, u64(w.simulationTime*8)) > fireWeather {
		return 0, false
	}
	if WorldFireAt(w, tileX, tileY) do return 0, false

	slot := -1
	for step in 0 ..< FIRE_CAPACITY {
		candidate := (w.fireCursor+step)%FIRE_CAPACITY
		if !w.fireUsed[candidate] {
			slot = candidate
			break
		}
	}
	if slot < 0 do return 0, false

	w.fires.x[slot] = f32(tileX)+0.5
	w.fires.y[slot] = f32(tileY)+0.5
	w.fires.intensity[slot] = clamp(intensity, 0.2, 2)
	w.fires.spread[slot] = clamp(spread, 0, 2)
	duration := FIRE_DURATION*(0.8+WorldNoiseHash(tileX, tileY, 0xF12E)*0.4)
	w.fires.remaining[slot] = duration
	w.fires.duration[slot] = duration
	w.fireUsed[slot] = true
	w.fireCursor = (slot+1)%FIRE_CAPACITY
	w.fireActivePosition[slot] = w.fireCount
	w.fireActive[w.fireCount] = slot
	w.fireCount += 1
	SpatialFireInsert(w, slot)
	FireIgniteBurst(w, f32(tileX)+0.5, f32(tileY)+0.5, w.fires.intensity[slot])
	return slot, true
}

WorldFireExtinguishAt :: proc(w: ^World, x, y: int) {
	chunk := SpatialChunkIndex(w, x, y)
	if chunk < 0 do return
	for slot := w.spatial.fireHead[chunk]; slot >= 0; slot = w.spatial.fireNext[slot] {
		if int(w.fires.x[slot]) == x && int(w.fires.y[slot]) == y {
			WorldFireDespawn(w, slot)
			return
		}
	}
}

WorldFireDespawn :: proc(w: ^World, slot: int) -> bool {
	if slot < 0 || slot >= FIRE_CAPACITY || !w.fireUsed[slot] do return false
	SpatialFireRemove(w, slot)
	w.fireUsed[slot] = false
	position := w.fireActivePosition[slot]
	last := w.fireCount-1
	moved := w.fireActive[last]
	w.fireActive[position] = moved
	w.fireActivePosition[moved] = position
	w.fireCount = last
	return true
}

WorldFireUpdate :: proc(w: ^World, deltaTime: f32) {
	FireDamageBurningUnits(w, deltaTime)
	if w.fireCount == 0 do return

	weatherEffects := WorldWeatherEffects(w)
	for slot in 0 ..< FIRE_CAPACITY {
		if !w.fireUsed[slot] do continue
		tileX := int(w.fires.x[slot])
		tileY := int(w.fires.y[slot])
		if TileTypeAntiFire(w.ground[tileX][tileY].type) {
			WorldFireDespawn(w, slot)
			continue
		}
		w.fires.remaining[slot] -= deltaTime*weatherEffects.fireExtinguish
		if w.fires.remaining[slot] <= 0 {
			WorldFireDespawn(w, slot)
			continue
		}
		FireDamageTile(w, slot, deltaTime)
		FireSpread(w, slot, deltaTime)
		FireIgniteUnits(w, slot, deltaTime)
		FireParticleTick(w, slot, deltaTime)
	}
}

// Damages the building and decorations sharing this fire's tile.
FireDamageTile :: proc(w: ^World, fireSlot: int, deltaTime: f32) {
	tileX := int(w.fires.x[fireSlot])
	tileY := int(w.fires.y[fireSlot])
	intensity := w.fires.intensity[fireSlot]
	worldHeight := int(w.maxY)

	// Once a blaze has taken hold it leaves a scar. Only the woody biomes turn
	// to ash; grass fires recover without a lasting mark.
	if w.fires.remaining[fireSlot] < w.fires.duration[fireSlot]*0.55 {
		switch w.ground[tileX][tileY].type {
		case .Forest, .Taiga:
			seconds := SCORCHED_MIN_SECONDS+
				WorldNoiseHash(tileX, tileY, 0xF1A5)*(SCORCHED_MAX_SECONDS-SCORCHED_MIN_SECONDS)
			WorldTerrainTransform(w, tileX, tileY, .Ash, .Scorched, seconds)
		case .Ocean, .Lake, .River, .Ice, .Marsh, .Sand, .Grassland, .Plains, .Steppe, .Hill, .Mountain, .Desert, .Tundra, .Ash, .Lava:
		}
	}

	buildingSlot := w.tileBuilding[tileX*worldHeight+tileY]
	if buildingSlot >= 0 && buildingSlot < BUILDING_CAPACITY && w.buildingUsed[buildingSlot] {
		if !BuildingImmuneToFire(BuildingKindOf(w.buildings[buildingSlot].type)) {
			w.buildings[buildingSlot].health -= FIRE_BUILDING_DAMAGE*intensity*deltaTime
			if w.buildings[buildingSlot].health <= 0 {
				BuildingSpawnDebris(w, buildingSlot, true)
				BuildingDestroyedBurst(w, buildingSlot)
				BuildingDespawn(w, buildingSlot, -1)
			}
		}
	}

	chunk := SpatialChunkIndex(w, tileX, tileY)
	if chunk < 0 do return
	slot := w.spatial.decorationHead[chunk]
	for slot >= 0 {
		next := w.spatial.decorationNext[slot]
		if int(w.decorations.x[slot]) == tileX && int(w.decorations.y[slot]) == tileY &&
			DecorationIsFlammable(w.decorations.kind[slot]) {
			w.decorations.health[slot] -= FIRE_DECORATION_DAMAGE*intensity*deltaTime
			if w.decorations.health[slot] <= 0 do DecorationFell(w, slot)
		}
		slot = next
	}
}

FireSpread :: proc(w: ^World, fireSlot: int, deltaTime: f32) {
	chunkSize := w.spatial.chunkSize
	if chunkSize <= 0 do return
	spread := w.fires.spread[fireSlot]
	if spread <= 0 do return
	weatherEffects := WorldWeatherEffects(w)
	if weatherEffects.fireSpread <= 0 do return

	x := w.fires.x[fireSlot]
	y := w.fires.y[fireSlot]
	chance := FIRE_SPREAD_CHANCE*w.fires.intensity[fireSlot]*spread*deltaTime*
		weatherEffects.fireSpread
	if chance <= 0 do return
	worldWidth := f32(w.maxX)
	worldHeight := f32(w.maxY)
	radiusSquared: f32 = FIRE_SPREAD_RADIUS*FIRE_SPREAD_RADIUS
	windLength := math.sqrt(w.weather.windX*w.weather.windX+w.weather.windY*w.weather.windY)

	radius := FIRE_SPREAD_CHUNK_RADIUS
	firstChunkX := (int(x)-radius)/chunkSize
	lastChunkX := (int(x)+radius)/chunkSize
	firstChunkY := (int(y)-radius)/chunkSize
	lastChunkY := (int(y)+radius)/chunkSize

	for chunkY in firstChunkY ..= lastChunkY {
		wrappedY := WorldWrapCoordinate(chunkY, w.spatial.chunksY)
		for chunkX in firstChunkX ..= lastChunkX {
			wrappedX := WorldWrapCoordinate(chunkX, w.spatial.chunksX)
			chunk := wrappedX*w.spatial.chunksY+wrappedY

			for decorationSlot := w.spatial.decorationHead[chunk]; decorationSlot >= 0;
				decorationSlot = w.spatial.decorationNext[decorationSlot] {
				if !DecorationIsFlammable(w.decorations.kind[decorationSlot]) do continue
				deltaX := WorldShortestWrappedDelta(
					w.decorations.x[decorationSlot]-x,
					worldWidth,
				)
				deltaY := WorldShortestWrappedDelta(
					w.decorations.y[decorationSlot]-y,
					worldHeight,
				)
				if deltaX*deltaX+deltaY*deltaY > radiusSquared do continue
				if windLength > 0.05 {
					distance := math.sqrt(deltaX*deltaX+deltaY*deltaY)
					if distance > 0.01 &&
						(deltaX*w.weather.windX+deltaY*w.weather.windY)/
							(distance*windLength) < -0.2 {
						continue
					}
				}
				roll := WorldNoiseHash(decorationSlot, fireSlot, u64(w.simulationTime*64))
				if roll > chance do continue
				WorldFireIgnite(
					w,
					w.decorations.x[decorationSlot],
					w.decorations.y[decorationSlot],
					w.fires.intensity[fireSlot]*0.85,
					spread*0.9,
				)
			}

			for buildingSlot := w.spatial.buildingHead[chunk]; buildingSlot >= 0;
				buildingSlot = w.spatial.buildingNext[buildingSlot] {
				if !w.buildingUsed[buildingSlot] do continue
				kind := BuildingKindOf(w.buildings[buildingSlot].type)
				if BuildingImmuneToFire(kind) do continue
				width, height := BuildingTileSize(w.buildings[buildingSlot].type)
				centerX := f32(w.buildings.x[buildingSlot])+f32(width)*0.5
				centerY := f32(w.buildings.y[buildingSlot])+f32(height)*0.5
				deltaX := WorldShortestWrappedDelta(centerX-x, worldWidth)
				deltaY := WorldShortestWrappedDelta(centerY-y, worldHeight)
				if deltaX*deltaX+deltaY*deltaY > radiusSquared do continue
				if windLength > 0.05 {
					distance := math.sqrt(deltaX*deltaX+deltaY*deltaY)
					if distance > 0.01 &&
						(deltaX*w.weather.windX+deltaY*w.weather.windY)/
							(distance*windLength) < -0.2 {
						continue
					}
				}
				roll := WorldNoiseHash(buildingSlot, fireSlot, u64(w.simulationTime*128)+7)
				if roll > chance do continue
				WorldFireIgnite(w, centerX, centerY, w.fires.intensity[fireSlot]*0.85, spread*0.9)
			}
		}
	}
}

FireIgniteUnits :: proc(w: ^World, fireSlot: int, deltaTime: f32) {
	chunkSize := w.spatial.chunkSize
	if chunkSize <= 0 do return
	x := w.fires.x[fireSlot]
	y := w.fires.y[fireSlot]
	chance := FIRE_UNIT_IGNITE_CHANCE*w.fires.intensity[fireSlot]*deltaTime
	if chance <= 0 do return
	worldWidth := f32(w.maxX)
	worldHeight := f32(w.maxY)
	radiusSquared: f32 = FIRE_UNIT_IGNITE_RADIUS*FIRE_UNIT_IGNITE_RADIUS

	firstChunkX := (int(x)-1)/chunkSize
	lastChunkX := (int(x)+1)/chunkSize
	firstChunkY := (int(y)-1)/chunkSize
	lastChunkY := (int(y)+1)/chunkSize
	for chunkY in firstChunkY ..= lastChunkY {
		wrappedY := WorldWrapCoordinate(chunkY, w.spatial.chunksY)
		for chunkX in firstChunkX ..= lastChunkX {
			wrappedX := WorldWrapCoordinate(chunkX, w.spatial.chunksX)
			chunk := wrappedX*w.spatial.chunksY+wrappedY
			for unitSlot := w.spatial.unitHead[chunk]; unitSlot >= 0;
				unitSlot = w.spatial.unitNext[unitSlot] {
				if !w.unitUsed[unitSlot] do continue
				if w.units.burning[unitSlot] > 0 do continue
				if UnitImmuneToFire(w.units[unitSlot].type) do continue
				deltaX := WorldShortestWrappedDelta(w.units.x[unitSlot]-x, worldWidth)
				deltaY := WorldShortestWrappedDelta(w.units.y[unitSlot]-y, worldHeight)
				if deltaX*deltaX+deltaY*deltaY > radiusSquared do continue
				roll := WorldNoiseHash(unitSlot, fireSlot, u64(w.simulationTime*64)+3)
				if roll > chance do continue
				w.units.burning[unitSlot] = FIRE_UNIT_BURN_SECONDS
				w.unitsBurning += 1
			}
		}
	}
}

FireDamageBurningUnits :: proc(w: ^World, deltaTime: f32) {
	if w.unitsBurning == 0 do return
	for unitSlot in 0 ..< UNIT_CAPACITY {
		if !w.unitUsed[unitSlot] do continue
		if w.units.burning[unitSlot] <= 0 do continue
		w.units.burning[unitSlot] -= deltaTime
		if UnitApplyDamage(
			w,
			unitSlot,
			FIRE_UNIT_DAMAGE*deltaTime,
			w.units.x[unitSlot],
			w.units.y[unitSlot],
			.Fire,
		) {
			continue
		}
		if w.units.burning[unitSlot] <= 0 do w.unitsBurning -= 1
	}
}

// --- poison clouds --------------------------------------------------------

GAS_CLOUD_CAPACITY :: 256
POISON_CLOUD_REFRESH :: 3.0
POISON_DAMAGE_RATIO_PER_SECOND :: 0.025

GasCloud :: struct {
	x, y:      f32,
	radius:    f32,
	remaining: f32,
	duration:  f32,
	seed:      u64,
}

WorldGasCloudSpawn :: proc(w: ^World, x, y, radius, duration: f32) {
	slot := -1
	for step in 0..<GAS_CLOUD_CAPACITY {
		candidate := (w.gasCloudCursor+step)%GAS_CLOUD_CAPACITY
		if !w.gasCloudUsed[candidate] {
			slot = candidate
			break
		}
	}
	if slot < 0 do return
	w.gasClouds.x[slot] = x
	w.gasClouds.y[slot] = y
	w.gasClouds.radius[slot] = radius
	w.gasClouds.remaining[slot] = duration
	w.gasClouds.duration[slot] = duration
	w.gasClouds.seed[slot] = u64(slot)*0x9E3779B97F4A7C15
	w.gasCloudUsed[slot] = true
	w.gasCloudCursor = (slot+1)%GAS_CLOUD_CAPACITY
}

WorldGasCloudUpdate :: proc(w: ^World, deltaTime: f32) {
	worldWidth := f32(w.maxX)
	worldHeight := f32(w.maxY)

	for cloud in 0..<GAS_CLOUD_CAPACITY {
		if !w.gasCloudUsed[cloud] do continue
		w.gasClouds.remaining[cloud] -= deltaTime
		if w.gasClouds.remaining[cloud] <= 0 {
			w.gasCloudUsed[cloud] = false
			continue
		}
		cloudX := w.gasClouds.x[cloud]
		cloudY := w.gasClouds.y[cloud]
		cloudX = WorldWrapPosition(
			cloudX+w.weather.windX*deltaTime*GAS_CLOUD_WIND_DRIFT,
			worldWidth,
		)
		cloudY = WorldWrapPosition(
			cloudY+w.weather.windY*deltaTime*GAS_CLOUD_WIND_DRIFT,
			worldHeight,
		)
		w.gasClouds.x[cloud] = cloudX
		w.gasClouds.y[cloud] = cloudY
		radius := w.gasClouds.radius[cloud]
		radiusSquared := radius*radius

		for unitSlot in 0..<UNIT_CAPACITY {
			if !w.unitUsed[unitSlot] || w.units.type[unitSlot] == nil do continue
			if UnitHiddenInside(w, unitSlot) do continue
			deltaX := WorldShortestWrappedDelta(w.units.x[unitSlot]-cloudX, worldWidth)
			deltaY := WorldShortestWrappedDelta(w.units.y[unitSlot]-cloudY, worldHeight)
			if deltaX*deltaX+deltaY*deltaY > radiusSquared do continue
			w.units.poisonRemaining[unitSlot] = max(
				w.units.poisonRemaining[unitSlot],
				POISON_CLOUD_REFRESH,
			)
		}

		for _ in 0..<2 {
			angle := PRandom(w)*6.2831853
			distance := radius*math.sqrt(PRandom(w))
			ParticleSpawn(w, Particle{
				x = WorldWrapPosition(cloudX+math.cos(angle)*distance, worldWidth),
				y = WorldWrapPosition(cloudY+math.sin(angle)*distance, worldHeight),
				z = PRandomRange(w, 0.2, 0.9),
				vx = (PRandom(w)-0.5)*0.4,
				vy = (PRandom(w)-0.5)*0.4,
				vz = PRandomRange(w, 0.1, 0.5),
				life = PRandomRange(w, 1.2, 2.4),
				size = PRandomRange(w, 0.28, 0.55),
				drag = 1.2,
				gravity = -0.4,
				kind = .Dust,
				tint = rl.Color{104, 180, 88, 205},
			})
		}
	}

	for unitSlot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[unitSlot] || w.units.type[unitSlot] == nil do continue
		if w.units.poisonRemaining[unitSlot] <= 0 {
			w.units.effects[unitSlot][.Poisoned] = false
			continue
		}
		w.units.poisonRemaining[unitSlot] = max(w.units.poisonRemaining[unitSlot]-deltaTime, 0)
		w.units.effects[unitSlot][.Poisoned] = true
		damage := UnitMaxHealth(w, unitSlot)*POISON_DAMAGE_RATIO_PER_SECOND*deltaTime
		UnitApplyDamage(w, unitSlot, damage, w.units.x[unitSlot], w.units.y[unitSlot], .Poison)
	}
}
