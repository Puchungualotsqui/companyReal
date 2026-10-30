package main

import rl "vendor:raylib"
import "base:intrinsics"
import "core:math"
import "d32"

// Fire rules. A fire cell lives on a tile and burns whatever flammable entity
// sits there, so it can exist on empty ground too. Spread is probabilistic and
// can be disabled per fire.
// Hash time scales below assume four simulation ticks per second.
#assert(TOWN_SIMULATION_STEP == 0.25)

FIRE_CAPACITY :: 8192
FIRE_DURATION :: 30
FIRE_SPREAD_RADIUS :: d32.Value(5*d32.SCALE/2)
FIRE_SPREAD_CHUNK_RADIUS :: 1
FIRE_SPREAD_CHANCE :: d32.Value(8*d32.SCALE/100)
FIRE_DECORATION_DAMAGE :: d32.Value(6*d32.SCALE)
FIRE_BUILDING_DAMAGE :: d32.Value(5*d32.SCALE)
FIRE_UNIT_DAMAGE :: d32.Value(8*d32.SCALE)
FIRE_UNIT_IGNITE_RADIUS :: d32.Value(3*d32.SCALE/2)
FIRE_UNIT_IGNITE_CHANCE :: d32.Value(12*d32.SCALE/100)
FIRE_UNIT_BURN_SECONDS :: 5
// Wind is quantized on a coarser fixed grid so the i64 dot products stay well
// inside range at FIRE_SPREAD_RADIUS.
FIRE_WIND_SCALE :: d32.SCALE/32

// Fire-seconds removed per second by a pacific unit fighting a fire.
FIRE_EXTINGUISH_RADIUS :: d32.Value(16*d32.SCALE/10)

UnitExtinguishRate :: proc(type: UnitType) -> d32.Value {
	switch _ in type {
	case WaterCollector:
		return d32.FromInt(10)
	case Villager:
		return d32.FromInt(5)
	case Builder, CombatBuilder, Farmer:
		return d32.FromInt(4)
	case Explorer:
		return d32.ZERO
	case Knight, Archer, Mage, Giant, Turtle, Catapult, Rogue:
		return d32.ZERO
	}
	return d32.ZERO
}

Fire :: struct {
	x, y:      d32.Value,
	intensity: f32,
	spread:    f32,
	remaining: d32.Value,
	duration:  d32.Value,
}

// Fire risk is a terrain property; zero-risk tiles cannot ignite or spread.
TileTypeAntiFire :: proc(tileType: TileType) -> bool {
	return TILE_DEFS[tileType].fireRisk <= d32.ZERO
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
		if PositionTile(w.fires.x[slot], int(w.maxX)) == x &&
			PositionTile(w.fires.y[slot], int(w.maxY)) == y {
			return true
		}
	}
	return false
}

WorldFireIgnite :: proc(
	w: ^World,
	x, y: d32.Value,
	intensity: f32,
	spread: f32 = 1,
) -> (int, bool) {
	RecursiveLockGuard(&w.fireMutex)
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 do return 0, false
	tileX := PositionTile(x, worldWidth)
	tileY := PositionTile(y, worldHeight)
	if TileTypeAntiFire(w.ground[tileX][tileY].type) do return 0, false
	if hazardKind, hasHazard := WorldHazardKindAt(w, tileX, tileY); hasHazard && hazardKind == .Flood {
		return 0, false
	}
	fireWeather := WorldWeatherEffects(w).fireIgnition
	if fireWeather <= d32.ZERO do return 0, false
	if fireWeather < d32.ONE &&
		WorldNoiseHash(tileX, tileY, WorldCurrentTick(w)*2) > PositionToF32(fireWeather) {
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

	w.fires.x[slot] = TileCenterPosition(tileX)
	w.fires.y[slot] = TileCenterPosition(tileY)
	w.fires.intensity[slot] = clamp(intensity, 0.2, 2)
	w.fires.spread[slot] = clamp(spread, 0, 2)
	duration := PositionFromF32(FIRE_DURATION*(0.8+WorldNoiseHash(tileX, tileY, 0xF12E)*0.4))
	w.fires.remaining[slot] = duration
	w.fires.duration[slot] = duration
	w.fireUsed[slot] = true
	w.fireCursor = (slot+1)%FIRE_CAPACITY
	w.fireActivePosition[slot] = w.fireCount
	w.fireActive[w.fireCount] = slot
	w.fireCount += 1
	SpatialFireInsert(w, slot)
	FireIgniteBurst(
		w,
		PositionToF32(w.fires.x[slot]),
		PositionToF32(w.fires.y[slot]),
		w.fires.intensity[slot],
	)
	return slot, true
}

WorldFireExtinguishAt :: proc(w: ^World, x, y: int) {
	chunk := SpatialChunkIndex(w, x, y)
	if chunk < 0 do return
	for slot := w.spatial.fireHead[chunk]; slot >= 0; slot = w.spatial.fireNext[slot] {
		if PositionTile(w.fires.x[slot], int(w.maxX)) == x &&
			PositionTile(w.fires.y[slot], int(w.maxY)) == y {
			WorldFireDespawn(w, slot)
			return
		}
	}
}

WorldFireDespawn :: proc(w: ^World, slot: int) -> bool {
	if slot < 0 || slot >= FIRE_CAPACITY || !w.fireUsed[slot] do return false
	RecursiveLockGuard(&w.fireMutex)
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
		tileX := PositionTile(w.fires.x[slot], int(w.maxX))
		tileY := PositionTile(w.fires.y[slot], int(w.maxY))
		if TileTypeAntiFire(w.ground[tileX][tileY].type) {
			WorldFireDespawn(w, slot)
			continue
		}
		step := d32.Mul(PositionFromF32(deltaTime), weatherEffects.fireExtinguish)
		w.fires.remaining[slot] = max(d32.Sub(w.fires.remaining[slot], step), d32.ZERO)
		if w.fires.remaining[slot] <= d32.ZERO {
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
	tileX := PositionTile(w.fires.x[fireSlot], int(w.maxX))
	tileY := PositionTile(w.fires.y[fireSlot], int(w.maxY))
	intensityValue := PositionFromF32(w.fires.intensity[fireSlot])
	step := PositionFromF32(deltaTime)
	worldHeight := int(w.maxY)

	// Once a blaze has taken hold it leaves a scar. Only the woody biomes turn
	// to ash; grass fires recover without a lasting mark.
	if w.fires.remaining[fireSlot] < d32.Mul(w.fires.duration[fireSlot], d32.FromRatio(55, 100)) {
		switch w.ground[tileX][tileY].type {
		case .Forest, .Taiga:
			roll := d32.FromRatio(i32(WorldNoiseHashInt(tileX, tileY, 0xF1A5)), 1_000_000)
			seconds := d32.Add(
				d32.FromInt(SCORCHED_MIN_SECONDS),
				d32.Mul(roll, d32.FromInt(SCORCHED_MAX_SECONDS-SCORCHED_MIN_SECONDS)),
			)
			WorldTerrainTransform(w, tileX, tileY, .Ash, .Scorched, seconds)
		case .Ocean, .Lake, .River, .Ice, .Marsh, .Sand, .Grassland, .Plains, .Steppe, .Hill, .Mountain, .Desert, .Tundra, .Ash, .Lava:
		}
	}

	buildingSlot := w.tileBuilding[tileX*worldHeight+tileY]
	if buildingSlot >= 0 && buildingSlot < BUILDING_CAPACITY && w.buildingUsed[buildingSlot] {
		if !BuildingImmuneToFire(BuildingKindOf(w.buildings[buildingSlot].type)) {
			damage := d32.Mul(d32.Mul(FIRE_BUILDING_DAMAGE, intensityValue), step)
			w.buildings[buildingSlot].health = d32.Sub(w.buildings[buildingSlot].health, damage)
			if w.buildings[buildingSlot].health <= d32.ZERO {
				BuildingSpawnDebris(w, buildingSlot, true)
				BuildingDestroyedBurst(w, buildingSlot)
				BuildingDespawn(w, buildingSlot, -1)
			}
		}
	}

	chunk := SpatialChunkIndex(w, tileX, tileY)
	if chunk < 0 do return
	decorationDamage := d32.Mul(d32.Mul(FIRE_DECORATION_DAMAGE, intensityValue), step)
	slot := w.spatial.decorationHead[chunk]
	for slot >= 0 {
		next := w.spatial.decorationNext[slot]
		if int(d32.ToInt(w.decorations.x[slot])) == tileX &&
			int(d32.ToInt(w.decorations.y[slot])) == tileY &&
			DecorationIsFlammable(w.decorations.kind[slot]) {
			w.decorations.health[slot] = d32.Sub(w.decorations.health[slot], decorationDamage)
			if w.decorations.health[slot] <= d32.ZERO do DecorationFell(w, slot)
		}
		slot = next
	}
}

// True when the offset points against the wind by more than a 0.2 cosine.
// Squaring the negative dot product avoids sqrt and keeps the test exact.
@(private = "file")
FireWindOpposes :: proc(deltaX, deltaY, distanceSquared, windX, windY, windSquared: i64) -> bool {
	if distanceSquared*10000 <= d32.SCALE*d32.SCALE do return false
	dot := deltaX*windX+deltaY*windY
	if dot >= 0 do return false
	return 25*dot*dot > distanceSquared*windSquared
}

// Quantizes one wind component to the coarse fixed grid, rounding once in
// Q16.16. The arithmetic shift rounds halves toward positive infinity.
@(private = "file")
FireWindQuantize :: proc(wind: d32.Value) -> i64 {
	raw := i64(d32.Raw(wind))*FIRE_WIND_SCALE
	return (raw+d32.SCALE/2) >> d32.FRACTION_BITS
}

FireSpread :: proc(w: ^World, fireSlot: int, deltaTime: f32) {
	chunkSize := w.spatial.chunkSize
	if chunkSize <= 0 do return
	spread := w.fires.spread[fireSlot]
	if spread <= 0 do return
	weatherEffects := WorldWeatherEffects(w)
	if weatherEffects.fireSpread <= d32.ZERO do return

	x := w.fires.x[fireSlot]
	y := w.fires.y[fireSlot]
	chance := d32.Mul(FIRE_SPREAD_CHANCE, PositionFromF32(w.fires.intensity[fireSlot]))
	chance = d32.Mul(chance, PositionFromF32(spread))
	chance = d32.Mul(chance, PositionFromF32(deltaTime))
	chance = d32.Mul(chance, weatherEffects.fireSpread)
	if chance <= d32.ZERO do return
	worldWidthRaw := i64(w.maxX)*d32.SCALE
	worldHeightRaw := i64(w.maxY)*d32.SCALE
	radiusRaw := i64(d32.Raw(FIRE_SPREAD_RADIUS))
	radiusSquared := radiusRaw*radiusRaw
	fireX := x
	fireY := y
	windX := FireWindQuantize(w.weather.windX)
	windY := FireWindQuantize(w.weather.windY)
	windSquared := windX*windX+windY*windY
	filterWind := windSquared*400 > FIRE_WIND_SCALE*FIRE_WIND_SCALE

	radius := FIRE_SPREAD_CHUNK_RADIUS
	tileX := PositionTile(x, int(w.maxX))
	tileY := PositionTile(y, int(w.maxY))
	firstChunkX := (tileX-radius)/chunkSize
	lastChunkX := (tileX+radius)/chunkSize
	firstChunkY := (tileY-radius)/chunkSize
	lastChunkY := (tileY+radius)/chunkSize

	for chunkY in firstChunkY ..= lastChunkY {
		wrappedY := WorldWrapCoordinate(chunkY, w.spatial.chunksY)
		for chunkX in firstChunkX ..= lastChunkX {
			wrappedX := WorldWrapCoordinate(chunkX, w.spatial.chunksX)
			chunk := wrappedX*w.spatial.chunksY+wrappedY

			for decorationSlot := w.spatial.decorationHead[chunk]; decorationSlot >= 0;
				decorationSlot = w.spatial.decorationNext[decorationSlot] {
				if !DecorationIsFlammable(w.decorations.kind[decorationSlot]) do continue
				decorationX := w.decorations.x[decorationSlot]
				decorationY := w.decorations.y[decorationSlot]
				deltaX, validX := d32.ShortestWrappedDelta(fireX, decorationX, worldWidthRaw)
				deltaY, validY := d32.ShortestWrappedDelta(fireY, decorationY, worldHeightRaw)
				if !validX || !validY do continue
				distanceSquared := deltaX*deltaX+deltaY*deltaY
				if distanceSquared > radiusSquared do continue
				if filterWind &&
					FireWindOpposes(deltaX, deltaY, distanceSquared, windX, windY, windSquared) {
					continue
				}
				roll := d32.FromRatio(
					i32(WorldNoiseHashInt(decorationSlot, fireSlot, WorldCurrentTick(w)*16)),
					1_000_000,
				)
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
				buildingX := d32.FromRaw(
					i32(i64(w.buildings.x[buildingSlot])*d32.SCALE+i64(width)*(d32.SCALE/2)),
				)
				buildingY := d32.FromRaw(
					i32(i64(w.buildings.y[buildingSlot])*d32.SCALE+i64(height)*(d32.SCALE/2)),
				)
				deltaX, validX := d32.ShortestWrappedDelta(fireX, buildingX, worldWidthRaw)
				deltaY, validY := d32.ShortestWrappedDelta(fireY, buildingY, worldHeightRaw)
				if !validX || !validY do continue
				distanceSquared := deltaX*deltaX+deltaY*deltaY
				if distanceSquared > radiusSquared do continue
				if filterWind &&
					FireWindOpposes(deltaX, deltaY, distanceSquared, windX, windY, windSquared) {
					continue
				}
				roll := d32.FromRatio(
					i32(WorldNoiseHashInt(buildingSlot, fireSlot, WorldCurrentTick(w)*32+7)),
					1_000_000,
				)
				if roll > chance do continue
				WorldFireIgnite(w, buildingX, buildingY, w.fires.intensity[fireSlot]*0.85, spread*0.9)
			}
		}
	}
}

FireIgniteUnits :: proc(w: ^World, fireSlot: int, deltaTime: f32) {
	chunkSize := w.spatial.chunkSize
	if chunkSize <= 0 do return
	x := w.fires.x[fireSlot]
	y := w.fires.y[fireSlot]
	chance := d32.Mul(FIRE_UNIT_IGNITE_CHANCE, PositionFromF32(w.fires.intensity[fireSlot]))
	chance = d32.Mul(chance, PositionFromF32(deltaTime))
	if chance <= d32.ZERO do return
	worldWidthRaw := i64(w.maxX)*d32.SCALE
	worldHeightRaw := i64(w.maxY)*d32.SCALE
	radiusRaw := i64(d32.Raw(FIRE_UNIT_IGNITE_RADIUS))
	radiusSquared := u64(radiusRaw*radiusRaw)
	fireX := x
	fireY := y

	tileX := PositionTile(x, int(w.maxX))
	tileY := PositionTile(y, int(w.maxY))
	firstChunkX := (tileX-1)/chunkSize
	lastChunkX := (tileX+1)/chunkSize
	firstChunkY := (tileY-1)/chunkSize
	lastChunkY := (tileY+1)/chunkSize
	for chunkY in firstChunkY ..= lastChunkY {
		wrappedY := WorldWrapCoordinate(chunkY, w.spatial.chunksY)
		for chunkX in firstChunkX ..= lastChunkX {
			wrappedX := WorldWrapCoordinate(chunkX, w.spatial.chunksX)
			chunk := wrappedX*w.spatial.chunksY+wrappedY
			for unitSlot := w.spatial.unitHead[chunk]; unitSlot >= 0;
				unitSlot = w.spatial.unitNext[unitSlot] {
				if !w.unitUsed[unitSlot] do continue
				if w.units.burning[unitSlot] > d32.ZERO do continue
				if UnitImmuneToFire(w.units[unitSlot].type) do continue
				distanceSquared, valid := d32.WrappedDistanceSquared(
					fireX,
					fireY,
					w.units.x[unitSlot],
					w.units.y[unitSlot],
					worldWidthRaw,
					worldHeightRaw,
				)
				if !valid do continue
				if distanceSquared > radiusSquared do continue
				roll := d32.FromRatio(
					i32(WorldNoiseHashInt(unitSlot, fireSlot, WorldCurrentTick(w)*16+3)),
					1_000_000,
				)
				if roll > chance do continue
				w.units.burning[unitSlot] = d32.FromInt(FIRE_UNIT_BURN_SECONDS)
				intrinsics.atomic_add(&w.unitsBurning, 1)
			}
		}
	}
}

FireDamageBurningUnits :: proc(w: ^World, deltaTime: f32) {
	if w.unitsBurning == 0 do return
	step := PositionFromF32(deltaTime)
	for unitSlot in 0 ..< UNIT_CAPACITY {
		if !w.unitUsed[unitSlot] do continue
		if w.units.burning[unitSlot] <= d32.ZERO do continue
		w.units.burning[unitSlot] = max(d32.Sub(w.units.burning[unitSlot], step), d32.ZERO)
		if UnitApplyDamage(
			w,
			unitSlot,
			d32.Mul(FIRE_UNIT_DAMAGE, step),
			w.units.x[unitSlot],
			w.units.y[unitSlot],
			.Fire,
		) {
			continue
		}
		if w.units.burning[unitSlot] <= d32.ZERO do intrinsics.atomic_sub(&w.unitsBurning, 1)
	}
}

// --- poison clouds --------------------------------------------------------

GAS_CLOUD_CAPACITY :: 256
POISON_CLOUD_REFRESH :: 3
POISON_DAMAGE_RATIO_PER_SECOND :: d32.Value(25*d32.SCALE/1000)

GasCloud :: struct {
	x, y:      d32.Value,
	radius:    d32.Value,
	remaining: d32.Value,
	duration:  d32.Value,
	seed:      u64,
}

WorldGasCloudSpawn :: proc(w: ^World, x, y, radius, duration: d32.Value) {
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
	worldWidthRaw := i64(w.maxX)*d32.SCALE
	worldHeightRaw := i64(w.maxY)*d32.SCALE
	step := PositionFromF32(deltaTime)
	windX := d32.Mul(d32.Mul(w.weather.windX, step), GAS_CLOUD_WIND_DRIFT)
	windY := d32.Mul(d32.Mul(w.weather.windY, step), GAS_CLOUD_WIND_DRIFT)

	for cloud in 0..<GAS_CLOUD_CAPACITY {
		if !w.gasCloudUsed[cloud] do continue
		w.gasClouds.remaining[cloud] = max(
			d32.Sub(w.gasClouds.remaining[cloud], step),
			d32.ZERO,
		)
		if w.gasClouds.remaining[cloud] <= d32.ZERO {
			w.gasCloudUsed[cloud] = false
			continue
		}
		cloudX, _ := d32.AddRawWrapped(
			i64(d32.Raw(w.gasClouds.x[cloud])),
			i64(d32.Raw(windX)),
			d32.ZERO,
			worldWidthRaw,
		)
		cloudY, _ := d32.AddRawWrapped(
			i64(d32.Raw(w.gasClouds.y[cloud])),
			i64(d32.Raw(windY)),
			d32.ZERO,
			worldHeightRaw,
		)
		w.gasClouds.x[cloud] = cloudX
		w.gasClouds.y[cloud] = cloudY
		radius := w.gasClouds.radius[cloud]
		radiusRaw := i64(d32.Raw(radius))
		radiusSquared := u64(radiusRaw*radiusRaw)

		for unitSlot in 0..<UNIT_CAPACITY {
			if !w.unitUsed[unitSlot] || w.units.type[unitSlot] == nil do continue
			if UnitHiddenInside(w, unitSlot) do continue
			distanceSquared, valid := d32.WrappedDistanceSquared(
				cloudX,
				cloudY,
				w.units.x[unitSlot],
				w.units.y[unitSlot],
				worldWidthRaw,
				worldHeightRaw,
			)
			if !valid do continue
			if distanceSquared > radiusSquared do continue
			w.units.poisonRemaining[unitSlot] = max(
				w.units.poisonRemaining[unitSlot],
				d32.FromInt(POISON_CLOUD_REFRESH),
			)
		}

		radiusF32 := PositionToF32(radius)
		cloudF32X := PositionToF32(cloudX)
		cloudF32Y := PositionToF32(cloudY)
		for _ in 0..<2 {
			angle := PRandom(w)*6.2831853
			distance := radiusF32*math.sqrt(PRandom(w))
			ParticleSpawn(w, Particle{
				x = WorldWrapPosition(cloudF32X+math.cos(angle)*distance, worldWidth),
				y = WorldWrapPosition(cloudF32Y+math.sin(angle)*distance, worldHeight),
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
		if w.units.poisonRemaining[unitSlot] <= d32.ZERO {
			w.units.effects[unitSlot][.Poisoned] = false
			continue
		}
		w.units.poisonRemaining[unitSlot] = max(
			d32.Sub(w.units.poisonRemaining[unitSlot], PositionFromF32(deltaTime)),
			d32.ZERO,
		)
		w.units.effects[unitSlot][.Poisoned] = true
		damage := d32.Mul(UnitMaxHealth(w, unitSlot), d32.Mul(POISON_DAMAGE_RATIO_PER_SECOND, step))
		UnitApplyDamage(w, unitSlot, damage, w.units.x[unitSlot], w.units.y[unitSlot], .Poison)
	}
}
