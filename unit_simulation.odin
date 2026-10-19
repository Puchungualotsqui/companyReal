package main

UnitUpdateVillager :: proc(w: ^World, unit_slot: int, delta_time: f32) {}

UnitUpdateBuilder :: proc(w: ^World, unit_slot: int, delta_time: f32) {
	kingdom_slot := w.units[unit_slot].kingdome
	town_slot := w.units[unit_slot].town
	if !WorldTownExists(w, kingdom_slot, town_slot) do return

	builder := &w.units[unit_slot].type.(Builder)

	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	if builder.taskState == .Idle && town.wood < 15 {
		if target_x, target_y, found := UnitFindResourceTarget(w, unit_slot, builder.taskSequence); found {
			w.units[unit_slot].pathTargetX = target_x
			w.units[unit_slot].pathTargetY = target_y
			w.units[unit_slot].pathReady = false
			builder.taskState = .TravelingToSource
		}
	}

	switch builder.taskState {
	case .Idle:
	case .TravelingToSource:
		if UnitMoveWorker(w, unit_slot, delta_time) {
			builder.taskState = .Gathering
			w.units[unit_slot].cooldown = 1
		} else if !w.units[unit_slot].pathFound {
			builder.taskState = .Idle
			w.units[unit_slot].pathReady = false
			builder.taskSequence += 1
		}
	case .Gathering:
		w.units[unit_slot].cooldown -= delta_time
		if w.units[unit_slot].cooldown <= 0 {
			builder.carriedResource = 5
			if x, y, found := UnitFindTownReturnPoint(w, kingdom_slot, town_slot); found {
				w.units[unit_slot].pathTargetX = x
				w.units[unit_slot].pathTargetY = y
				w.units[unit_slot].pathReady = false
				builder.taskState = .ReturningToTown
			} else {
				builder.taskState = .Idle
				builder.carriedResource = 0
			}
		}
	case .ReturningToTown:
		if UnitMoveWorker(w, unit_slot, delta_time) {
			town.wood += builder.carriedResource
			builder.taskState = .Idle
			builder.carriedResource = 0
			w.units[unit_slot].pathReady = false
			builder.taskSequence += 1
		} else if !w.units[unit_slot].pathFound {
			builder.taskState = .Idle
			builder.carriedResource = 0
			w.units[unit_slot].pathReady = false
			builder.taskSequence += 1
		}
	}

	if builder.taskState == .Idle do town.builders += 1
}

UnitUpdateWaterCollector :: proc(w: ^World, unit_slot: int, delta_time: f32) {
	kingdom_slot := w.units[unit_slot].kingdome
	town_slot := w.units[unit_slot].town
	if WorldTownExists(w, kingdom_slot, town_slot) {
		w.kingdoms[kingdom_slot].towns[town_slot].waterCollectors += 1
	}
}

UnitUpdateFarmer :: proc(w: ^World, unit_slot: int, delta_time: f32) {
	kingdom_slot := w.units[unit_slot].kingdome
	town_slot := w.units[unit_slot].town
	if WorldTownExists(w, kingdom_slot, town_slot) {
		w.kingdoms[kingdom_slot].towns[town_slot].farmers += 1
	}
}

UnitUpdateKnight :: proc(w: ^World, unit_slot: int, delta_time: f32) {}

UnitUpdateGiant :: proc(w: ^World, unit_slot: int, delta_time: f32) {}

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

UnitFindResourceTarget :: proc(w: ^World, unit_slot, task_sequence: int) -> (int, int, bool) {
	world_width := int(w.maxX)
	world_height := int(w.maxY)
	if world_width <= 0 || world_height <= 0 do return 0, 0, false
	unit_x := WorldWrapPosition(w.units.x[unit_slot], f32(world_width))
	unit_y := WorldWrapPosition(w.units.y[unit_slot], f32(world_height))
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

UnitMoveWorker :: proc(w: ^World, unit_slot: int, delta_time: f32) -> bool {
	if int(WorldWrapPosition(w.units.x[unit_slot], f32(w.maxX))) == w.units[unit_slot].pathTargetX &&
		int(WorldWrapPosition(w.units.y[unit_slot], f32(w.maxY))) == w.units[unit_slot].pathTargetY {
		return true
	}
	reached := UnitMove(w, unit_slot, w.units[unit_slot].pathTargetX, w.units[unit_slot].pathTargetY, delta_time)
	if !w.units[unit_slot].pathFound do return false
	return reached
}
