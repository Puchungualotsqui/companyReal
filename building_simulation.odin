package main

WorldBuildingUpdate :: proc(w: ^World, delta_time: f32) {
	for kingdom_slot in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[kingdom_slot] do continue
		for town_slot in 0..<TOWN_CAPACITY {
			if !w.kingdoms[kingdom_slot].townUsed[town_slot] do continue
			town := &w.kingdoms[kingdom_slot].towns[town_slot]
			town.homes = 0
			town.farmlands = 0
			town.farmlandOutput = 0
		}
	}

	for building_slot in 0..<BUILDING_CAPACITY {
		if !w.buildingUsed[building_slot] do continue
		switch _ in w.buildings[building_slot].type {
		case Wall:
			BuildingUpdateWall(w, building_slot, delta_time)
		case TownHall:
			BuildingUpdateTownHall(w, building_slot, delta_time)
		case Home:
			BuildingUpdateHome(w, building_slot, delta_time)
		case Farmland:
			BuildingUpdateFarmland(w, building_slot, delta_time)
		}
	}
}

BuildingUpdateWall :: proc(w: ^World, building_slot: int, delta_time: f32) {}

BuildingUpdateTownHall :: proc(w: ^World, building_slot: int, delta_time: f32) {}

BuildingUpdateHome :: proc(w: ^World, building_slot: int, delta_time: f32) {
	kingdom_slot := w.buildings[building_slot].kingdom
	town_slot := w.buildings[building_slot].town
	if WorldTownExists(w, kingdom_slot, town_slot) {
		w.kingdoms[kingdom_slot].towns[town_slot].homes += 1
	}
}

BuildingUpdateFarmland :: proc(w: ^World, building_slot: int, delta_time: f32) {
	kingdom_slot := w.buildings[building_slot].kingdom
	town_slot := w.buildings[building_slot].town
	if WorldTownExists(w, kingdom_slot, town_slot) {
		town := &w.kingdoms[kingdom_slot].towns[town_slot]
		town.farmlands += 1
		town.farmlandOutput += BuildingFarmlandOutput(w, building_slot)
	}
}

TownBuilderConstruct :: proc(w: ^World, kingdom_slot, town_slot: int, can_grow: bool) -> bool {
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	building_type: BuildingType
	if town.homes < town.citizens || (can_grow && town.homes == town.citizens) {
		building_type = Home{}
	} else if town.farmlands < town.farmers {
		building_type = Farmland{}
	} else {
		return false
	}
	return TownBuilderBuildByType(w, kingdom_slot, town_slot, building_type)
}

TownBuilderBuildByType :: proc(w: ^World, kingdom_slot, town_slot: int, building_type: BuildingType) -> bool {
	switch _ in building_type {
	case Home:
		return TownBuilderPlaceBuilding(w, kingdom_slot, town_slot, Home{}, 5)
	case Farmland:
		return TownBuilderPlaceBuilding(w, kingdom_slot, town_slot, Farmland{}, 8)
	case Wall, TownHall:
		return false
	}
	unreachable()
}


TownBuilderPlaceBuilding :: proc(w: ^World, kingdom_slot, town_slot: int, building_type: BuildingType, wood_cost: f32) -> bool {
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	if town.wood < wood_cost do return false
	x, y, found := TownFindBuildingSite(w, kingdom_slot, town_slot, building_type)
	if !found do return false
	if _, ok := BuildingSpawn(w, x, y, building_type, kingdom_slot, town_slot); !ok do return false
	town.wood -= wood_cost
	return true
}

TownFindBuildingSite :: proc(w: ^World, kingdom_slot, town_slot: int, building_type: BuildingType) -> (int, int, bool) {
	world_width := int(w.maxX)
	world_height := int(w.maxY)
	town_x := w.kingdoms[kingdom_slot].towns[town_slot].x
	town_y := w.kingdoms[kingdom_slot].towns[town_slot].y
	building_width, building_height := BuildingTileSize(building_type)
	for radius in 1..=20 {
		min_x := max(0, town_x-radius)
		max_x := min(world_width-building_width, town_x+3+radius)
		min_y := max(0, town_y-radius)
		max_y := min(world_height-building_height, town_y+3+radius)
		for x in min_x..=max_x {
			for y in min_y..=max_y {
				distance_x := max(max(town_x-x, 0), x-(town_x+3))
				distance_y := max(max(town_y-y, 0), y-(town_y+3))
				if max(distance_x, distance_y) != radius do continue
				if WorldBuildingValid(w, x, y, building_type) do return x, y, true
			}
		}
	}
	return 0, 0, false
}

BuildingFarmlandOutput :: proc(w: ^World, building_slot: int) -> f32 {
	x := w.buildings.x[building_slot]
	y := w.buildings.y[building_slot]
	width, height := BuildingTileSize(w.buildings[building_slot].type)
	fertile_tiles := 0
	for tile_x in x..<x+width {
		for tile_y in y..<y+height {
			if w.ground[tile_x][tile_y].type == .FertileGround do fertile_tiles += 1
		}
	}
	output: f32 = 0.10
	if fertile_tiles >= 2 do output = 0.16
	return output
}
