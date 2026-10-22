package main

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
}

// Water cannot burn; every other terrain can host a fire.
TileTypeAntiFire :: proc(tile_type: TileType) -> bool {
	switch tile_type {
	case .Water, .FreshWater, .River:
		return true
	case .Ground, .FertileGround, .Sand, .Forest, .Hill, .Desert:
		return false
	}
	unreachable()
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
	case .TownHall, .Wall, .Cannon, .Watchtower, .MagicSchool, .TurtlePen, .Path:
		return true
	case .Home, .Farmland, .Bridge, .ArcheryRange, .SiegeWorkshop, .GiantPen, .ThievesGuild:
		return false
	}
	unreachable()
}

FireAccessPoint :: proc(w: ^World, tile_x, tile_y: int, unit_type: UnitType, unit_kingdom: int) -> (int, int, bool) {
	world_width := int(w.maxX)
	world_height := int(w.maxY)
	if world_width <= 0 || world_height <= 0 do return 0, 0, false
	if WorldTileWalkable(w, tile_x, tile_y, unit_type, unit_kingdom) do return tile_x, tile_y, true
	for radius in 1 ..= 2 {
		for x in tile_x-radius ..= tile_x+radius {
			for y in tile_y-radius ..= tile_y+radius {
				wrapped_x := WorldWrapCoordinate(x, world_width)
				wrapped_y := WorldWrapCoordinate(y, world_height)
				if WorldTileWalkable(w, wrapped_x, wrapped_y, unit_type, unit_kingdom) {
					return wrapped_x, wrapped_y, true
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
	world_width := int(w.maxX)
	world_height := int(w.maxY)
	if world_width <= 0 || world_height <= 0 do return 0, false
	tile_x := WorldWrapCoordinate(int(x), world_width)
	tile_y := WorldWrapCoordinate(int(y), world_height)
	if TileTypeAntiFire(w.ground[tile_x][tile_y].type) do return 0, false
	if WorldFireAt(w, tile_x, tile_y) do return 0, false

	slot := -1
	for step in 0 ..< FIRE_CAPACITY {
		candidate := (w.fireCursor+step)%FIRE_CAPACITY
		if !w.fireUsed[candidate] {
			slot = candidate
			break
		}
	}
	if slot < 0 do return 0, false

	w.fires.x[slot] = f32(tile_x)+0.5
	w.fires.y[slot] = f32(tile_y)+0.5
	w.fires.intensity[slot] = clamp(intensity, 0.2, 2)
	w.fires.spread[slot] = clamp(spread, 0, 2)
	w.fires.remaining[slot] = FIRE_DURATION*(0.8+WorldNoiseHash(tile_x, tile_y, 0xF12E)*0.4)
	w.fireUsed[slot] = true
	w.fireCursor = (slot+1)%FIRE_CAPACITY
	w.fireCount += 1
	SpatialFireInsert(w, slot)
	return slot, true
}

WorldFireDespawn :: proc(w: ^World, slot: int) -> bool {
	if slot < 0 || slot >= FIRE_CAPACITY || !w.fireUsed[slot] do return false
	SpatialFireRemove(w, slot)
	w.fireUsed[slot] = false
	w.fireCount -= 1
	return true
}

WorldFireUpdate :: proc(w: ^World, delta_time: f32) {
	FireDamageBurningUnits(w, delta_time)
	if w.fireCount == 0 do return

	for slot in 0 ..< FIRE_CAPACITY {
		if !w.fireUsed[slot] do continue
		tile_x := int(w.fires.x[slot])
		tile_y := int(w.fires.y[slot])
		if TileTypeAntiFire(w.ground[tile_x][tile_y].type) {
			WorldFireDespawn(w, slot)
			continue
		}
		w.fires.remaining[slot] -= delta_time
		if w.fires.remaining[slot] <= 0 {
			WorldFireDespawn(w, slot)
			continue
		}
		FireDamageTile(w, slot, delta_time)
		FireSpread(w, slot, delta_time)
		FireIgniteUnits(w, slot, delta_time)
	}
}

// Damages the building and decorations sharing this fire's tile.
FireDamageTile :: proc(w: ^World, fire_slot: int, delta_time: f32) {
	tile_x := int(w.fires.x[fire_slot])
	tile_y := int(w.fires.y[fire_slot])
	intensity := w.fires.intensity[fire_slot]
	world_height := int(w.maxY)

	building_slot := w.tileBuilding[tile_x*world_height+tile_y]
	if building_slot >= 0 && building_slot < BUILDING_CAPACITY && w.buildingUsed[building_slot] {
		if !BuildingImmuneToFire(BuildingKindOf(w.buildings[building_slot].type)) {
			w.buildings[building_slot].health -= FIRE_BUILDING_DAMAGE*intensity*delta_time
			if w.buildings[building_slot].health <= 0 {
				BuildingDespawn(w, building_slot, -1)
			}
		}
	}

	chunk := SpatialChunkIndex(w, tile_x, tile_y)
	if chunk < 0 do return
	slot := w.spatial.decorationHead[chunk]
	for slot >= 0 {
		next := w.spatial.decorationNext[slot]
		if int(w.decorations.x[slot]) == tile_x && int(w.decorations.y[slot]) == tile_y &&
			DecorationIsFlammable(w.decorations.kind[slot]) {
			w.decorations.health[slot] -= FIRE_DECORATION_DAMAGE*intensity*delta_time
			if w.decorations.health[slot] <= 0 do DecorationFell(w, slot)
		}
		slot = next
	}
}

FireSpread :: proc(w: ^World, fire_slot: int, delta_time: f32) {
	chunk_size := w.spatial.chunkSize
	if chunk_size <= 0 do return
	spread := w.fires.spread[fire_slot]
	if spread <= 0 do return

	x := w.fires.x[fire_slot]
	y := w.fires.y[fire_slot]
	chance := FIRE_SPREAD_CHANCE*w.fires.intensity[fire_slot]*spread*delta_time
	if chance <= 0 do return
	world_width := f32(w.maxX)
	world_height := f32(w.maxY)
	radius_squared: f32 = FIRE_SPREAD_RADIUS*FIRE_SPREAD_RADIUS

	radius := FIRE_SPREAD_CHUNK_RADIUS
	first_chunk_x := (int(x)-radius)/chunk_size
	last_chunk_x := (int(x)+radius)/chunk_size
	first_chunk_y := (int(y)-radius)/chunk_size
	last_chunk_y := (int(y)+radius)/chunk_size

	for chunk_y in first_chunk_y ..= last_chunk_y {
		wrapped_y := WorldWrapCoordinate(chunk_y, w.spatial.chunksY)
		for chunk_x in first_chunk_x ..= last_chunk_x {
			wrapped_x := WorldWrapCoordinate(chunk_x, w.spatial.chunksX)
			chunk := wrapped_x*w.spatial.chunksY+wrapped_y

			for decoration_slot := w.spatial.decorationHead[chunk]; decoration_slot >= 0;
				decoration_slot = w.spatial.decorationNext[decoration_slot] {
				if !DecorationIsFlammable(w.decorations.kind[decoration_slot]) do continue
				delta_x := WorldShortestWrappedDelta(
					w.decorations.x[decoration_slot]-x,
					world_width,
				)
				delta_y := WorldShortestWrappedDelta(
					w.decorations.y[decoration_slot]-y,
					world_height,
				)
				if delta_x*delta_x+delta_y*delta_y > radius_squared do continue
				roll := WorldNoiseHash(decoration_slot, fire_slot, u64(w.simulationTime*64))
				if roll > chance do continue
				WorldFireIgnite(
					w,
					w.decorations.x[decoration_slot],
					w.decorations.y[decoration_slot],
					w.fires.intensity[fire_slot]*0.85,
					spread*0.9,
				)
			}

			for building_slot := w.spatial.buildingHead[chunk]; building_slot >= 0;
				building_slot = w.spatial.buildingNext[building_slot] {
				if !w.buildingUsed[building_slot] do continue
				kind := BuildingKindOf(w.buildings[building_slot].type)
				if BuildingImmuneToFire(kind) do continue
				width, height := BuildingTileSize(w.buildings[building_slot].type)
				center_x := f32(w.buildings.x[building_slot])+f32(width)*0.5
				center_y := f32(w.buildings.y[building_slot])+f32(height)*0.5
				delta_x := WorldShortestWrappedDelta(center_x-x, world_width)
				delta_y := WorldShortestWrappedDelta(center_y-y, world_height)
				if delta_x*delta_x+delta_y*delta_y > radius_squared do continue
				roll := WorldNoiseHash(building_slot, fire_slot, u64(w.simulationTime*128)+7)
				if roll > chance do continue
				WorldFireIgnite(w, center_x, center_y, w.fires.intensity[fire_slot]*0.85, spread*0.9)
			}
		}
	}
}

FireIgniteUnits :: proc(w: ^World, fire_slot: int, delta_time: f32) {
	chunk_size := w.spatial.chunkSize
	if chunk_size <= 0 do return
	x := w.fires.x[fire_slot]
	y := w.fires.y[fire_slot]
	chance := FIRE_UNIT_IGNITE_CHANCE*w.fires.intensity[fire_slot]*delta_time
	if chance <= 0 do return
	world_width := f32(w.maxX)
	world_height := f32(w.maxY)
	radius_squared: f32 = FIRE_UNIT_IGNITE_RADIUS*FIRE_UNIT_IGNITE_RADIUS

	first_chunk_x := (int(x)-1)/chunk_size
	last_chunk_x := (int(x)+1)/chunk_size
	first_chunk_y := (int(y)-1)/chunk_size
	last_chunk_y := (int(y)+1)/chunk_size
	for chunk_y in first_chunk_y ..= last_chunk_y {
		wrapped_y := WorldWrapCoordinate(chunk_y, w.spatial.chunksY)
		for chunk_x in first_chunk_x ..= last_chunk_x {
			wrapped_x := WorldWrapCoordinate(chunk_x, w.spatial.chunksX)
			chunk := wrapped_x*w.spatial.chunksY+wrapped_y
			for unit_slot := w.spatial.unitHead[chunk]; unit_slot >= 0;
				unit_slot = w.spatial.unitNext[unit_slot] {
				if !w.unitUsed[unit_slot] do continue
				if w.units.burning[unit_slot] > 0 do continue
				if UnitImmuneToFire(w.units[unit_slot].type) do continue
				delta_x := WorldShortestWrappedDelta(w.units.x[unit_slot]-x, world_width)
				delta_y := WorldShortestWrappedDelta(w.units.y[unit_slot]-y, world_height)
				if delta_x*delta_x+delta_y*delta_y > radius_squared do continue
				roll := WorldNoiseHash(unit_slot, fire_slot, u64(w.simulationTime*64)+3)
				if roll > chance do continue
				w.units.burning[unit_slot] = FIRE_UNIT_BURN_SECONDS
				w.unitsBurning += 1
			}
		}
	}
}

FireDamageBurningUnits :: proc(w: ^World, delta_time: f32) {
	if w.unitsBurning == 0 do return
	for unit_slot in 0 ..< UNIT_CAPACITY {
		if !w.unitUsed[unit_slot] do continue
		if w.units.burning[unit_slot] <= 0 do continue
		w.units.burning[unit_slot] -= delta_time
		w.units.health[unit_slot] -= FIRE_UNIT_DAMAGE*delta_time
		if w.units.health[unit_slot] <= 0 {
			UnitDespawn(w, unit_slot)
			continue
		}
		if w.units.burning[unit_slot] <= 0 do w.unitsBurning -= 1
	}
}
