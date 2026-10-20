package main

UnitUpdateVillager :: proc(w: ^World, unit_slot: int, delta_time: f32) {
	if !WorldTownExists(w, w.units[unit_slot].kingdome, w.units[unit_slot].town) do return
	if UnitUpdatePacificSleep(w, unit_slot, delta_time) do return
	UnitUpdateRoaming(w, unit_slot, delta_time)
}

UnitUpdateBuilder :: proc(w: ^World, unit_slot: int, delta_time: f32) {
	kingdom_slot := w.units[unit_slot].kingdome
	town_slot := w.units[unit_slot].town
	if !WorldTownExists(w, kingdom_slot, town_slot) do return
	if UnitUpdatePacificSleep(w, unit_slot, delta_time) do return

	builder := &w.units[unit_slot].type.(Builder)
	state := &w.units[unit_slot].state.(StatePacific)
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	if state^ == .Roaming && builder.carriedResource > 0 {
		if x, y, found := UnitFindTownReturnPoint(w, kingdom_slot, town_slot); found {
			w.units[unit_slot].pathTargetX = x
			w.units[unit_slot].pathTargetY = y
			w.units[unit_slot].pathReady = false
			state^ = .Returning
		}
	}
	if state^ == .Roaming && town.wood < TOWN_WOOD_TARGET {
		if x, y, decoration, found := UnitFindResourceTarget(w, unit_slot, builder.taskSequence); found {
			builder.targetDecoration = decoration
			w.units[unit_slot].pathTargetX = x
			w.units[unit_slot].pathTargetY = y
			w.units[unit_slot].pathReady = false
			state^ = .Traveling
		}
	}

	switch state^ {
	case .Roaming:
		town.builders += 1
		UnitUpdateRoaming(w, unit_slot, delta_time)
	case .Traveling:
		if UnitMoveToTarget(w, unit_slot, delta_time) {
			if builder.targetDecoration >= 0 && builder.targetDecoration < DECORATION_CAPACITY &&
				w.decorationUsed[builder.targetDecoration] &&
				DecorationChoppable(w.decorations.kind[builder.targetDecoration]) {
				state^ = .Working
				w.units[unit_slot].cooldown = DecorationChopSeconds(
					w.decorations.kind[builder.targetDecoration],
				)
			} else {
				builder.targetDecoration = -1
				state^ = .Roaming
				w.units[unit_slot].pathReady = false
				builder.taskSequence += 1
			}
		} else if !w.units[unit_slot].pathFound {
			state^ = .Roaming
			w.units[unit_slot].pathReady = false
			builder.targetDecoration = -1
			builder.taskSequence += 1
		}
	case .Working:
		if builder.targetDecoration < 0 || builder.targetDecoration >= DECORATION_CAPACITY ||
			!w.decorationUsed[builder.targetDecoration] {
			builder.targetDecoration = -1
			state^ = .Roaming
			w.units[unit_slot].pathReady = false
			builder.taskSequence += 1
			break
		}

		w.units[unit_slot].cooldown -= delta_time
		if w.units[unit_slot].cooldown <= 0 {
			carried := DecorationWoodYield(w.decorations.kind[builder.targetDecoration])
			DecorationFell(w, builder.targetDecoration)
			builder.targetDecoration = -1
			if carried > 0 {
				builder.carriedResource = carried
				if x, y, found := UnitFindTownReturnPoint(w, kingdom_slot, town_slot); found {
					w.units[unit_slot].pathTargetX = x
					w.units[unit_slot].pathTargetY = y
					w.units[unit_slot].pathReady = false
					state^ = .Returning
				} else {
					builder.carriedResource = 0
					state^ = .Roaming
				}
			} else {
				state^ = .Roaming
				builder.taskSequence += 1
			}
		}
	case .Returning:
		if UnitMoveToTarget(w, unit_slot, delta_time) {
			town.wood += builder.carriedResource
			builder.carriedResource = 0
			builder.targetDecoration = -1
			builder.taskSequence += 1
			state^ = .Roaming
			w.units[unit_slot].pathReady = false
		} else if !w.units[unit_slot].pathFound {
			builder.carriedResource = 0
			builder.targetDecoration = -1
			builder.taskSequence += 1
			state^ = .Roaming
			w.units[unit_slot].pathReady = false
		}
	case .GoingHome, .Sleeping:
	}
}

UnitUpdateWaterCollector :: proc(w: ^World, unit_slot: int, delta_time: f32) {
	kingdom_slot := w.units[unit_slot].kingdome
	town_slot := w.units[unit_slot].town
	if !WorldTownExists(w, kingdom_slot, town_slot) do return
	w.kingdoms[kingdom_slot].towns[town_slot].waterCollectors += 1
	if UnitUpdatePacificSleep(w, unit_slot, delta_time) do return

	collector := &w.units[unit_slot].type.(WaterCollector)
	state := &w.units[unit_slot].state.(StatePacific)

	if state^ == .Roaming {
		if collector.carriedResource > 0 {
			if x, y, found := UnitFindTownReturnPoint(w, kingdom_slot, town_slot); found {
				w.units[unit_slot].pathTargetX = x
				w.units[unit_slot].pathTargetY = y
				w.units[unit_slot].pathReady = false
				state^ = .Returning
			}
		} else if w.units[unit_slot].cooldown > 0 {
			w.units[unit_slot].cooldown -= delta_time
		} else if x, y, found := UnitFindWaterTarget(w, unit_slot, collector.taskSequence); found {
			w.units[unit_slot].pathTargetX = x
			w.units[unit_slot].pathTargetY = y
			w.units[unit_slot].pathReady = false
			state^ = .Traveling
		} else {
			w.units[unit_slot].cooldown = 5
		}
	}

	switch state^ {
	case .Roaming:
		UnitUpdateRoaming(w, unit_slot, delta_time)
	case .Traveling:
		if UnitMoveToTarget(w, unit_slot, delta_time) {
			state^ = .Working
			w.units[unit_slot].cooldown = f32(WORLD_DAY_LENGTH_SECONDS)/48
		} else if !w.units[unit_slot].pathFound {
			state^ = .Roaming
			w.units[unit_slot].pathReady = false
			collector.taskSequence += 1
		}
	case .Working:
		w.units[unit_slot].cooldown -= delta_time
		if w.units[unit_slot].cooldown <= 0 {
			collector.carriedResource = 1
			if x, y, found := UnitFindTownReturnPoint(w, kingdom_slot, town_slot); found {
				w.units[unit_slot].pathTargetX = x
				w.units[unit_slot].pathTargetY = y
				w.units[unit_slot].pathReady = false
				state^ = .Returning
			} else {
				collector.carriedResource = 0
				state^ = .Roaming
			}
		}
	case .Returning:
		if UnitMoveToTarget(w, unit_slot, delta_time) {
			collector.carriedResource = 0
			collector.taskSequence += 1
			state^ = .Roaming
			w.units[unit_slot].cooldown = 0
			w.units[unit_slot].pathReady = false
		} else if !w.units[unit_slot].pathFound {
			collector.carriedResource = 0
			collector.taskSequence += 1
			state^ = .Roaming
			w.units[unit_slot].pathReady = false
		}
	case .GoingHome, .Sleeping:
	}
}

UnitUpdateFarmer :: proc(w: ^World, unit_slot: int, delta_time: f32) {
	kingdom_slot := w.units[unit_slot].kingdome
	town_slot := w.units[unit_slot].town
	if !WorldTownExists(w, kingdom_slot, town_slot) do return

	farmer := &w.units[unit_slot].type.(Farmer)
	if farmer.workDay != w.dayNumber {
		farmer.workDay = w.dayNumber
		farmer.workedToday = false
	}
	w.kingdoms[kingdom_slot].towns[town_slot].farmers += 1
	if UnitUpdatePacificSleep(w, unit_slot, delta_time) do return

	state := &w.units[unit_slot].state.(StatePacific)
	if state^ == .Roaming && !farmer.workedToday {
		if w.units[unit_slot].cooldown > 0 {
			w.units[unit_slot].cooldown -= delta_time
		} else if x, y, found := UnitFindFarmlandTarget(w, unit_slot, farmer.workDay); found {
			w.units[unit_slot].pathTargetX = x
			w.units[unit_slot].pathTargetY = y
			w.units[unit_slot].pathReady = false
			state^ = .Traveling
		} else {
			w.units[unit_slot].cooldown = 5
		}
	}

	switch state^ {
	case .Roaming:
		UnitUpdateRoaming(w, unit_slot, delta_time)
	case .Traveling:
		if UnitMoveToTarget(w, unit_slot, delta_time) {
			state^ = .Working
			w.units[unit_slot].cooldown = f32(WORLD_DAY_LENGTH_SECONDS)/24
		} else if !w.units[unit_slot].pathFound {
			state^ = .Roaming
			w.units[unit_slot].pathReady = false
			w.units[unit_slot].cooldown = 5
		}
	case .Working:
		w.units[unit_slot].cooldown -= delta_time
		if w.units[unit_slot].cooldown <= 0 {
			farmer.workedToday = true
			state^ = .Roaming
			w.units[unit_slot].pathReady = false
		}
	case .Returning:
		state^ = .Roaming
	case .GoingHome, .Sleeping:
	}
}

UnitUpdateConverting :: proc(w: ^World, unit_slot: int, delta_time: f32) {
	if unit_slot < 0 || unit_slot >= UNIT_CAPACITY || !w.unitUsed[unit_slot] do return
	if _, converting := w.units[unit_slot].state.(StateConverting); !converting do return
	state := &w.units[unit_slot].state.(StateConverting)
	unit := &w.units[unit_slot]

	if !WorldTownExists(w, unit.kingdome, unit.town) {
		UnitConversionCancel(w, unit_slot)
		return
	}
	if state.building < 0 || state.building >= BUILDING_CAPACITY ||
		!w.buildingUsed[state.building] ||
		BuildingKindOf(w.buildings[state.building].type) != UnitTrainingBuildingKind(state.to) {
		UnitConversionCancel(w, unit_slot)
		return
	}

	if state.inside {
		state.timer -= delta_time
		if state.timer <= 0 do UnitConvert(w, unit_slot)
		return
	}

	if state.retryTimer > 0 {
		state.retryTimer -= delta_time
		return
	}

	if unit.pathTargetX != state.accessX || unit.pathTargetY != state.accessY {
		unit.pathTargetX = state.accessX
		unit.pathTargetY = state.accessY
		unit.pathReady = false
	}
	if UnitMoveToTarget(w, unit_slot, delta_time) {
		state.inside = true
		state.timer = UnitDefaultTrainingTime(state.to)
		unit.pathReady = false
	} else if !unit.pathFound {
		unit.pathReady = false
		state.retryTimer = 1
	}
}

UnitConvert :: proc(w: ^World, unit_slot: int) {
	if unit_slot < 0 || unit_slot >= UNIT_CAPACITY || !w.unitUsed[unit_slot] do return
	unit := &w.units[unit_slot]
	if _, converting := unit.state.(StateConverting); !converting do return
	state := unit.state.(StateConverting)
	from := UnitKindOf(unit.type)
	to := state.to

	if WorldTownExists(w, unit.kingdome, unit.town) {
		town := &w.kingdoms[unit.kingdome].towns[unit.town]
		for job_index in 0..<town.conversionCount {
			job := &town.conversions[job_index]
			if job.from != from || job.to != to do continue
			job.assigned = max(0, job.assigned-1)
			job.remaining = max(0, job.remaining-1)
			if job.remaining <= 0 {
				town.conversions[job_index] = town.conversions[town.conversionCount-1]
				town.conversionCount -= 1
			}
			break
		}
	}

	UnitSetType(w, unit_slot, to)
}

UnitConversionCancel :: proc(w: ^World, unit_slot: int) {
	if unit_slot < 0 || unit_slot >= UNIT_CAPACITY || !w.unitUsed[unit_slot] do return
	unit := &w.units[unit_slot]
	if _, converting := unit.state.(StateConverting); !converting do return
	state := unit.state.(StateConverting)
	from := UnitKindOf(unit.type)

	if WorldTownExists(w, unit.kingdome, unit.town) {
		town := &w.kingdoms[unit.kingdome].towns[unit.town]
		for job_index in 0..<town.conversionCount {
			job := &town.conversions[job_index]
			if job.from != from || job.to != state.to do continue
			job.assigned = max(0, job.assigned-1)
			break
		}
	}

	if UnitIsWarrior(unit.type) {
		unit.state = StateWarriorInit(unit_slot, unit.kingdome, unit.town)
	} else {
		unit.state = StatePacific.Roaming
	}
	unit.pathReady = false
}

UnitResetState :: proc(w: ^World, unit_slot: int) {
	if unit_slot < 0 || unit_slot >= UNIT_CAPACITY || !w.unitUsed[unit_slot] do return
	switch _ in w.units[unit_slot].state {
	case StateConverting:
		UnitConversionCancel(w, unit_slot)
	case StateWarrior:
		UnitWarriorReset(w, unit_slot)
	case StatePacific:
	}
}

UnitUpdatePacificSleep :: proc(w: ^World, unit_slot: int, delta_time: f32) -> bool {
	state := &w.units[unit_slot].state.(StatePacific)
	hour := WorldTimeOfDay(w)
	bedtime := 22+w.units[unit_slot].sleepOffsetHours
	wake_time: f32 = 6
	should_sleep := hour >= bedtime || hour < wake_time

	if should_sleep {
		if state^ == .Sleeping do return true
		if state^ != .GoingHome {
			if x, y, found := UnitFindHomeTarget(w, unit_slot); found {
				w.units[unit_slot].pathTargetX = x
				w.units[unit_slot].pathTargetY = y
				w.units[unit_slot].pathReady = false
				state^ = .GoingHome
			} else {
				state^ = .Sleeping
				w.units[unit_slot].pathReady = false
				return true
			}
		}

		if state^ == .GoingHome {
			if UnitMoveToTarget(w, unit_slot, delta_time) {
				state^ = .Sleeping
				w.units[unit_slot].pathReady = false
			} else if !w.units[unit_slot].pathFound {
				state^ = .Sleeping
				w.units[unit_slot].pathReady = false
			}
		}
		return true
	}

	if state^ == .GoingHome || state^ == .Sleeping {
		state^ = .Roaming
		w.units[unit_slot].pathReady = false
	}
	return false
}

UnitUpdateRoaming :: proc(w: ^World, unit_slot: int, delta_time: f32) {
	unit := &w.units[unit_slot]
	at_target := int(WorldWrapPosition(unit.x, f32(w.maxX))) == unit.pathTargetX &&
		int(WorldWrapPosition(unit.y, f32(w.maxY))) == unit.pathTargetY
	if !unit.pathReady || at_target {
		if x, y, found := UnitFindRoamingTarget(w, unit_slot, unit.roamSequence); found {
			unit.pathTargetX = x
			unit.pathTargetY = y
			unit.pathReady = false
			unit.roamSequence += 1
		} else {
			return
		}
	}

	if UnitMoveToTarget(w, unit_slot, delta_time) || !unit.pathFound {
		unit.pathReady = false
	}
}

UnitApplyTownEffects :: proc(w: ^World, unit_slot: int, housed: bool, shortage_epoch: int, delta_time: f32) {
	kingdom_slot := w.units[unit_slot].kingdome
	town_slot := w.units[unit_slot].town
	unit_type := w.units[unit_slot].type
	w.units[unit_slot].effects[.NoHome] = !housed
	w.units[unit_slot].effects[.NoFood] = false
	w.units[unit_slot].effects[.NoWater] = false
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	seed := u64(kingdom_slot*TOWN_CAPACITY+town_slot)
	food_roll := WorldNoiseHash(unit_slot, shortage_epoch, seed+301)
	water_roll := WorldNoiseHash(unit_slot, shortage_epoch, seed+607)
	w.units[unit_slot].effects[.NoFood] = food_roll < town.foodShortage
	w.units[unit_slot].effects[.NoWater] = water_roll < town.waterShortage

	regen: f32 = 0.25
	if !w.units[unit_slot].effects[.NoHome] do regen = 1
	w.units[unit_slot].health = min(UnitDefaultHealth(unit_type), w.units[unit_slot].health+regen*delta_time)
}

UnitClearTownEffects :: proc(w: ^World, unit_slot: int) {
	w.units[unit_slot].effects[.NoHome] = true
	w.units[unit_slot].effects[.NoWater] = false
	w.units[unit_slot].effects[.NoFood] = false
}

UnitFindRoamingTarget :: proc(w: ^World, unit_slot, sequence: int) -> (int, int, bool) {
	world_width := int(w.maxX)
	world_height := int(w.maxY)
	if world_width <= 0 || world_height <= 0 do return 0, 0, false
	unit_x := int(WorldWrapPosition(w.units[unit_slot].x, f32(world_width)))
	unit_y := int(WorldWrapPosition(w.units[unit_slot].y, f32(world_height)))
	seed := u64(unit_slot)+u64(sequence)*101
	for attempt in 0..<12 {
		delta_x := int(WorldNoiseHash(unit_slot, sequence*31+attempt*2, seed+11)*17)-8
		delta_y := int(WorldNoiseHash(unit_slot, sequence*31+attempt*2+1, seed+23)*17)-8
		if delta_x == 0 && delta_y == 0 do continue
		x := WorldWrapCoordinate(unit_x+delta_x, world_width)
		y := WorldWrapCoordinate(unit_y+delta_y, world_height)
		if !UnitValidTileType(w.units[unit_slot].type, w.ground[x][y].type) do continue
		if WorldTileOccupied(w, x, y) do continue
		return x, y, true
	}
	return 0, 0, false
}

// Finds the nearest harvestable tree decoration around the unit. Nearby
// spatial buckets are searched first; the linear scan is only a fallback for
// towns that have already cleared everything close to them.
UnitFindResourceTarget :: proc(w: ^World, unit_slot, task_sequence: int) -> (int, int, int, bool) {
	world_width := int(w.maxX)
	world_height := int(w.maxY)
	chunk_size := w.spatial.chunkSize
	if world_width <= 0 || world_height <= 0 || chunk_size <= 0 do return 0, 0, -1, false

	unit_x := int(WorldWrapPosition(w.units.x[unit_slot], f32(world_width)))
	unit_y := int(WorldWrapPosition(w.units.y[unit_slot], f32(world_height)))
	seed := u64(unit_slot+task_sequence*1009)
	best_slot := -1
	best_distance_squared: f32 = 0
	best_score: f32 = -1

	center_chunk_x := unit_x/chunk_size
	center_chunk_y := unit_y/chunk_size
	for radius in 1..=4 {
		for chunk_y in center_chunk_y-radius ..= center_chunk_y+radius {
			wrapped_y := WorldWrapCoordinate(chunk_y, w.spatial.chunksY)
			for chunk_x in center_chunk_x-radius ..= center_chunk_x+radius {
				wrapped_x := WorldWrapCoordinate(chunk_x, w.spatial.chunksX)
				chunk := wrapped_x*w.spatial.chunksY+wrapped_y
				for slot := w.spatial.decorationHead[chunk]; slot >= 0;
					slot = w.spatial.decorationNext[slot] {
					if !DecorationChoppable(w.decorations.kind[slot]) do continue
					source_x := int(w.decorations.x[slot])
					source_y := int(w.decorations.y[slot])
					if WorldTileOccupied(w, source_x, source_y) do continue
					if !WorldTileWalkable(w, source_x, source_y, w.units[unit_slot].type) do continue

					delta_x := WorldShortestWrappedDelta(f32(source_x)-f32(unit_x), f32(world_width))
					delta_y := WorldShortestWrappedDelta(f32(source_y)-f32(unit_y), f32(world_height))
					distance_squared := delta_x*delta_x+delta_y*delta_y
					score := WorldNoiseHash(source_x, source_y, seed)
					if best_slot >= 0 && (distance_squared > best_distance_squared ||
						(distance_squared == best_distance_squared && score <= best_score)) {
						continue
					}
					best_slot = slot
					best_distance_squared = distance_squared
					best_score = score
				}
			}
		}
	}

	if best_slot < 0 {
		for slot in 0..<DECORATION_CAPACITY {
			if !w.decorationUsed[slot] do continue
			if !DecorationChoppable(w.decorations.kind[slot]) do continue
			source_x := int(w.decorations.x[slot])
			source_y := int(w.decorations.y[slot])
			if WorldTileOccupied(w, source_x, source_y) do continue
			if !WorldTileWalkable(w, source_x, source_y, w.units[unit_slot].type) do continue

			delta_x := WorldShortestWrappedDelta(f32(source_x)-f32(unit_x), f32(world_width))
			delta_y := WorldShortestWrappedDelta(f32(source_y)-f32(unit_y), f32(world_height))
			distance_squared := delta_x*delta_x+delta_y*delta_y
			score := WorldNoiseHash(source_x, source_y, seed)
			if best_slot >= 0 && (distance_squared > best_distance_squared ||
				(distance_squared == best_distance_squared && score <= best_score)) {
				continue
			}
			best_slot = slot
			best_distance_squared = distance_squared
			best_score = score
		}
	}

	if best_slot < 0 do return 0, 0, -1, false
	return int(w.decorations.x[best_slot]), int(w.decorations.y[best_slot]), best_slot, true
}

UnitFindWaterTarget :: proc(w: ^World, unit_slot, task_sequence: int) -> (int, int, bool) {
	world_width := int(w.maxX)
	world_height := int(w.maxY)
	if world_width <= 0 || world_height <= 0 do return 0, 0, false
	unit_x := WorldWrapPosition(w.units[unit_slot].x, f32(world_width))
	unit_y := WorldWrapPosition(w.units[unit_slot].y, f32(world_height))
	best_x, best_y := 0, 0
	best_distance_squared: f32 = 0
	best_score: f32 = -1
	found_target := false
	seed := u64(unit_slot+task_sequence*1013)
	for source_x in 0..<world_width {
		for source_y in 0..<world_height {
			tile_type := w.ground[source_x][source_y].type
			if tile_type != .FreshWater && tile_type != .River do continue
			candidate_count := 1
			if tile_type == .FreshWater do candidate_count = 4
			for direction in 0..<candidate_count {
				candidate_x, candidate_y := source_x, source_y
				if tile_type == .FreshWater {
					switch direction {
					case 0: candidate_x += 1
					case 1: candidate_x -= 1
					case 2: candidate_y += 1
				case 3: candidate_y -= 1
				}
					candidate_x = WorldWrapCoordinate(candidate_x, world_width)
					candidate_y = WorldWrapCoordinate(candidate_y, world_height)
				}
				if !UnitValidTileType(w.units[unit_slot].type, w.ground[candidate_x][candidate_y].type) do continue
				delta_x := WorldShortestWrappedDelta(f32(candidate_x)-unit_x, f32(world_width))
				delta_y := WorldShortestWrappedDelta(f32(candidate_y)-unit_y, f32(world_height))
				distance_squared := delta_x*delta_x + delta_y*delta_y
				score := WorldNoiseHash(candidate_x, candidate_y, seed)
				if found_target && (distance_squared > best_distance_squared ||
					(distance_squared == best_distance_squared && score <= best_score)) {
					continue
				}
				if WorldTileOccupied(w, candidate_x, candidate_y) do continue
				best_x, best_y = candidate_x, candidate_y
				best_distance_squared = distance_squared
				best_score = score
				found_target = true
			}
		}
	}
	return best_x, best_y, found_target
}

UnitFindFarmlandTarget :: proc(w: ^World, unit_slot, sequence: int) -> (int, int, bool) {
	world_width := int(w.maxX)
	world_height := int(w.maxY)
	unit_x := WorldWrapPosition(w.units[unit_slot].x, f32(world_width))
	unit_y := WorldWrapPosition(w.units[unit_slot].y, f32(world_height))
	best_x, best_y := 0, 0
	best_distance_squared: f32 = 0
	best_score: f32 = -1
	found_target := false
	seed := u64(unit_slot+sequence*1031)
	for building_slot in 0..<BUILDING_CAPACITY {
		if !w.buildingUsed[building_slot] ||
			w.buildings[building_slot].kingdom != w.units[unit_slot].kingdome ||
			w.buildings[building_slot].town != w.units[unit_slot].town {
			continue
		}
		if BuildingKindOf(w.buildings[building_slot].type) != .Farmland do continue

		farm_x := w.buildings.x[building_slot]
		farm_y := w.buildings.y[building_slot]
		farm_width, farm_height := BuildingTileSize(w.buildings[building_slot].type)
		for offset_x in -1..=farm_width {
			for offset_y in -1..=farm_height {
				if offset_x >= 0 && offset_x < farm_width && offset_y >= 0 && offset_y < farm_height do continue
				x := WorldWrapCoordinate(farm_x+offset_x, world_width)
				y := WorldWrapCoordinate(farm_y+offset_y, world_height)
				if !UnitValidTileType(w.units[unit_slot].type, w.ground[x][y].type) do continue
				delta_x := WorldShortestWrappedDelta(f32(x)-unit_x, f32(world_width))
				delta_y := WorldShortestWrappedDelta(f32(y)-unit_y, f32(world_height))
				distance_squared := delta_x*delta_x + delta_y*delta_y
				score := WorldNoiseHash(x, y, seed)
				if found_target && (distance_squared > best_distance_squared ||
					(distance_squared == best_distance_squared && score <= best_score)) {
					continue
				}
				if WorldTileOccupied(w, x, y) do continue
				best_x, best_y = x, y
				best_distance_squared = distance_squared
				best_score = score
				found_target = true
			}
		}
	}
	return best_x, best_y, found_target
}

UnitFindHomeTarget :: proc(w: ^World, unit_slot: int) -> (int, int, bool) {
	world_width := int(w.maxX)
	world_height := int(w.maxY)
	unit_x := WorldWrapPosition(w.units[unit_slot].x, f32(world_width))
	unit_y := WorldWrapPosition(w.units[unit_slot].y, f32(world_height))
	best_x, best_y := 0, 0
	best_distance_squared: f32 = 0
	found_target := false
	for building_slot in 0..<BUILDING_CAPACITY {
		if !w.buildingUsed[building_slot] ||
			w.buildings[building_slot].kingdom != w.units[unit_slot].kingdome ||
			w.buildings[building_slot].town != w.units[unit_slot].town {
			continue
		}
		if BuildingKindOf(w.buildings[building_slot].type) != .Home do continue

		home_x := w.buildings.x[building_slot]
		home_y := w.buildings.y[building_slot]
		for offset_x in -1..=1 {
			for offset_y in -1..=1 {
				if offset_x == 0 && offset_y == 0 do continue
				x := WorldWrapCoordinate(home_x+offset_x, world_width)
				y := WorldWrapCoordinate(home_y+offset_y, world_height)
				if !UnitValidTileType(w.units[unit_slot].type, w.ground[x][y].type) do continue
				if WorldTileOccupied(w, x, y) do continue
				delta_x := WorldShortestWrappedDelta(f32(x)-unit_x, f32(world_width))
				delta_y := WorldShortestWrappedDelta(f32(y)-unit_y, f32(world_height))
				distance_squared := delta_x*delta_x + delta_y*delta_y
				if !found_target || distance_squared < best_distance_squared {
					best_x, best_y = x, y
					best_distance_squared = distance_squared
					found_target = true
				}
			}
		}
	}
	return best_x, best_y, found_target
}

UnitFindTownReturnPoint :: proc(w: ^World, kingdom_slot, town_slot: int) -> (int, int, bool) {
	world_width := int(w.maxX)
	world_height := int(w.maxY)
	town_x := w.kingdoms[kingdom_slot].towns[town_slot].x
	town_y := w.kingdoms[kingdom_slot].towns[town_slot].y
	for radius in 1..=8 {
		min_x := max(0, town_x-radius)
		max_x := min(world_width-1, town_x+4+radius)
		min_y := max(0, town_y-radius)
		max_y := min(world_height-1, town_y+4+radius)
		for x in min_x..=max_x {
			for y in min_y..=max_y {
				if x >= town_x && x < town_x+4 && y >= town_y && y < town_y+4 do continue
				if max(max(town_x-x, 0), x-(town_x+3)) > radius ||
					max(max(town_y-y, 0), y-(town_y+3)) > radius {
					continue
				}
				if !UnitValidTileType(Villager{}, w.ground[x][y].type) || WorldTileOccupied(w, x, y) do continue
				return x, y, true
			}
		}
	}
	return 0, 0, false
}

// Finds a walkable tile on the ring around a building footprint.
UnitFindBuildingAccessPoint :: proc(w: ^World, unit_slot, building_slot: int, target_type: UnitType) -> (int, int, bool) {
	if unit_slot < 0 || unit_slot >= UNIT_CAPACITY || !w.unitUsed[unit_slot] do return 0, 0, false
	if building_slot < 0 || building_slot >= BUILDING_CAPACITY || !w.buildingUsed[building_slot] {
		return 0, 0, false
	}

	unit := &w.units[unit_slot]
	building_x := w.buildings.x[building_slot]
	building_y := w.buildings.y[building_slot]
	width, height := BuildingTileSize(w.buildings[building_slot].type)
	world_width := int(w.maxX)
	world_height := int(w.maxY)
	if world_width <= 0 || world_height <= 0 do return 0, 0, false

	for radius in 1..=6 {
		inner_min_x := building_x-radius+1
		inner_max_x := building_x+width-1+radius-1
		inner_min_y := building_y-radius+1
		inner_max_y := building_y+height-1+radius-1
		for x in building_x-radius ..= building_x+width-1+radius {
			for y in building_y-radius ..= building_y+height-1+radius {
				if x >= inner_min_x && x <= inner_max_x && y >= inner_min_y && y <= inner_max_y {
					continue
				}
				wrapped_x := WorldWrapCoordinate(x, world_width)
				wrapped_y := WorldWrapCoordinate(y, world_height)
				if !WorldTileWalkable(w, wrapped_x, wrapped_y, unit.type) do continue
				if !WorldTileWalkable(w, wrapped_x, wrapped_y, target_type) do continue
				return wrapped_x, wrapped_y, true
			}
		}
	}
	return 0, 0, false
}

UnitMoveToTarget :: proc(w: ^World, unit_slot: int, delta_time: f32) -> bool {
	if int(WorldWrapPosition(w.units.x[unit_slot], f32(w.maxX))) == w.units[unit_slot].pathTargetX &&
		int(WorldWrapPosition(w.units.y[unit_slot], f32(w.maxY))) == w.units[unit_slot].pathTargetY {
		return true
	}
	reached := UnitMove(w, unit_slot, w.units[unit_slot].pathTargetX, w.units[unit_slot].pathTargetY, delta_time)
	if !w.units[unit_slot].pathFound do return false
	return reached
}
