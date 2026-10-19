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
	if state^ == .Roaming && town.wood < 15 {
		if x, y, found := UnitFindResourceTarget(w, unit_slot, builder.taskSequence); found {
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
			state^ = .Working
			w.units[unit_slot].cooldown = 1
		} else if !w.units[unit_slot].pathFound {
			state^ = .Roaming
			w.units[unit_slot].pathReady = false
			builder.taskSequence += 1
		}
	case .Working:
		w.units[unit_slot].cooldown -= delta_time
		if w.units[unit_slot].cooldown <= 0 {
			builder.carriedResource = 5
			if x, y, found := UnitFindTownReturnPoint(w, kingdom_slot, town_slot); found {
				w.units[unit_slot].pathTargetX = x
				w.units[unit_slot].pathTargetY = y
				w.units[unit_slot].pathReady = false
				state^ = .Returning
			} else {
				builder.carriedResource = 0
				state^ = .Roaming
			}
		}
	case .Returning:
		if UnitMoveToTarget(w, unit_slot, delta_time) {
			town.wood += builder.carriedResource
			builder.carriedResource = 0
			builder.taskSequence += 1
			state^ = .Roaming
			w.units[unit_slot].pathReady = false
		} else if !w.units[unit_slot].pathFound {
			builder.carriedResource = 0
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

UnitUpdateKnight :: proc(w: ^World, unit_slot: int, delta_time: f32) {}

UnitUpdateGiant :: proc(w: ^World, unit_slot: int, delta_time: f32) {}

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

UnitFindResourceTarget :: proc(w: ^World, unit_slot, task_sequence: int) -> (int, int, bool) {
	world_width := int(w.maxX)
	world_height := int(w.maxY)
	if world_width <= 0 || world_height <= 0 do return 0, 0, false
	unit_x := WorldWrapPosition(w.units[unit_slot].x, f32(world_width))
	unit_y := WorldWrapPosition(w.units[unit_slot].y, f32(world_height))
	best_x, best_y := 0, 0
	best_distance_squared: f32 = 0
	best_score: f32 = -1
	found_forest := false
	seed := u64(unit_slot+task_sequence*1009)
	for source_x in 0..<world_width {
		for source_y in 0..<world_height {
			if w.ground[source_x][source_y].type != .Forest do continue
			delta_x := WorldShortestWrappedDelta(f32(source_x)-unit_x, f32(world_width))
			delta_y := WorldShortestWrappedDelta(f32(source_y)-unit_y, f32(world_height))
			distance_squared := delta_x*delta_x + delta_y*delta_y
			score := WorldNoiseHash(source_x, source_y, seed)
			if found_forest && (distance_squared > best_distance_squared ||
				(distance_squared == best_distance_squared && score <= best_score)) {
				continue
			}
			if WorldTileOccupied(w, source_x, source_y) do continue
			if !UnitValidTileType(w.units[unit_slot].type, w.ground[source_x][source_y].type) do continue
			best_x, best_y = source_x, source_y
			best_distance_squared = distance_squared
			best_score = score
			found_forest = true
		}
	}
	return best_x, best_y, found_forest
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
		is_farmland := false
		switch _ in w.buildings[building_slot].type {
		case Farmland:
			is_farmland = true
		case Wall, TownHall, Home:
		}
		if !is_farmland do continue

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
		is_home := false
		switch _ in w.buildings[building_slot].type {
		case Home:
			is_home = true
		case Wall, TownHall, Farmland:
		}
		if !is_home do continue

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

UnitMoveToTarget :: proc(w: ^World, unit_slot: int, delta_time: f32) -> bool {
	if int(WorldWrapPosition(w.units.x[unit_slot], f32(w.maxX))) == w.units[unit_slot].pathTargetX &&
		int(WorldWrapPosition(w.units.y[unit_slot], f32(w.maxY))) == w.units[unit_slot].pathTargetY {
		return true
	}
	reached := UnitMove(w, unit_slot, w.units[unit_slot].pathTargetX, w.units[unit_slot].pathTargetY, delta_time)
	if !w.units[unit_slot].pathFound do return false
	return reached
}
