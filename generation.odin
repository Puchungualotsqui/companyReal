package main

import "core:math"

WorldLandPlate :: struct {
	x, y: f32,
	land: bool,
}

WorldPlateElevation :: proc(x, y, width, height: f32, plates: []WorldLandPlate) -> f32 {
	land_distance := width*width+height*height
	ocean_distance := land_distance
	for plate in plates {
		dx := abs(x-plate.x)
		dy := abs(y-plate.y)
		dx = min(dx, abs(width-dx))
		dy = min(dy, abs(height-dy))
		distance := dx*dx+dy*dy
		if plate.land {
			land_distance = min(land_distance, distance)
		} else {
			ocean_distance = min(ocean_distance, distance)
		}
	}
	return (ocean_distance-land_distance)/(ocean_distance+land_distance+1)
}

WorldStampIsland :: proc(field: []f32, width, height: int, center_x, center_y, radius: f32) {
	extent := int(radius)+2
	for dx in -extent..=extent {
		for dy in -extent..=extent {
			value := 1-(f32(dx*dx+dy*dy))/(radius*radius)
			if value <= 0 do continue
			x := WorldWrapCoordinate(int(center_x)+dx, width)
			y := WorldWrapCoordinate(int(center_y)+dy, height)
			field[x*height+y] = max(field[x*height+y], value)
		}
	}
}

WorldGenerationSettings :: struct {
	seed: u64,
	landThreshold: f32,
	// Moisture below this value becomes desert on inland lowlands.
	sandThreshold: f32,
	// Approximate width in tiles of the broad inland biome patches.
	biomeSize: int,
	islandCount: int,
	beachWidth: int,
	riverCount: int,
	lakeCount: int,
	minLakeRadius: int,
	maxLakeRadius: int,
}

WorldGenerationSettingsDefault :: proc() -> WorldGenerationSettings {
	return WorldGenerationSettings{
		seed = 1,
		landThreshold = 0.08,
		sandThreshold = 0.34,
		biomeSize = 10,
		islandCount = 85,
		beachWidth = 2,
		riverCount = 28,
		lakeCount = 24,
		minLakeRadius = 3,
		maxLakeRadius = 8,
	}
}

WorldGenerate :: proc(w: ^World, settings: WorldGenerationSettings) {
	world_width := int(w.maxX)
	world_height := int(w.maxY)
	if world_width <= 0 || world_height <= 0 do return

	biome_size := max(settings.biomeSize, 8)
	biome_detail_size := max(biome_size/3, 4)
	biome_cells_x := max(1, world_width/biome_size)
	biome_cells_y := max(1, world_height/biome_size)
	detail_cells_x := max(1, world_width/biome_detail_size)
	detail_cells_y := max(1, world_height/biome_detail_size)

	// Competing land and ocean plates produce asymmetric continents without a
	// radial falloff. Their boundaries wrap with the world and are warped below.
	columns := max(2, world_width/85)
	rows := max(2, world_height/85)
	plates := make([dynamic]WorldLandPlate, columns*rows)
	defer delete(plates)
	for column in 0..<columns {
		for row in 0..<rows {
			index := column*rows+row
			plates[index] = WorldLandPlate{
				x = (f32(column)+0.12+WorldNoiseHash(index, 0, settings.seed+101)*0.76)*f32(world_width)/f32(columns),
				y = (f32(row)+0.12+WorldNoiseHash(index, 1, settings.seed+101)*0.76)*f32(world_height)/f32(rows),
				land = WorldNoiseHash(index, 2, settings.seed+101) < 0.29,
			}
		}
	}
	plates[0].land = true
	plates[1].land = false

	field := make([dynamic]f32, world_width*world_height)
	defer delete(field)
	for x in 0..<world_width {
		for y in 0..<world_height {
			warp_x := (WorldPeriodicNoise(x, y, world_width, world_height, 6, 6, settings.seed+11)-0.5)*70 +
				(WorldPeriodicNoise(x, y, world_width, world_height, 17, 17, settings.seed+19)-0.5)*30
			warp_y := (WorldPeriodicNoise(x, y, world_width, world_height, 6, 6, settings.seed+23)-0.5)*70 +
				(WorldPeriodicNoise(x, y, world_width, world_height, 17, 17, settings.seed+29)-0.5)*30
			field[x*world_height+y] = WorldPlateElevation(f32(x)+warp_x, f32(y)+warp_y,
				f32(world_width), f32(world_height), plates[:])
		}
	}

	// Short, tapering island chains sit on the submerged edges of plates.
	for island in 0..<max(0, settings.islandCount) {
		seed := settings.seed+u64(island)*719+401
		for attempt in 0..<48 {
			x := int(WorldNoiseHash(attempt, 0, seed)*f32(world_width))
			y := int(WorldNoiseHash(attempt, 1, seed)*f32(world_height))
			elevation := field[x*world_height+y]
			if elevation > settings.landThreshold-0.12 || elevation < -0.6 do continue
			radius := 4+WorldNoiseHash(island, 2, seed)*9
			angle := WorldNoiseHash(island, 3, seed)*6.2831853
			steps := 2+int(WorldNoiseHash(island, 4, seed)*3)
			for step in 0..<steps {
				WorldStampIsland(field[:], world_width, world_height, f32(x), f32(y), radius)
				angle += (WorldNoiseHash(step, 5, seed)-0.5)*1.2
				x += int(math.cos(angle)*radius*0.9)
				y += int(math.sin(angle)*radius*0.9)
				radius *= 0.76
			}
			break
		}
	}

	for x in 0..<world_width {
		for y in 0..<world_height {
			coast := WorldPeriodicNoise(x, y, world_width, world_height,
				max(1, world_width/19), max(1, world_height/19), settings.seed+37)
			detail := WorldPeriodicNoise(x, y, world_width, world_height,
				max(1, world_width/7), max(1, world_height/7), settings.seed+41)
			land_score := field[x*world_height+y]+(coast-0.5)*0.32+(detail-0.5)*0.13

			tile_type := TileType.Water
			if land_score > settings.landThreshold {
				moisture := WorldPeriodicNoise(x, y, world_width, world_height,
					biome_cells_x, biome_cells_y, settings.seed+53)*0.7 +
					WorldPeriodicNoise(x, y, world_width, world_height,
					detail_cells_x, detail_cells_y, settings.seed+71)*0.3
				height := WorldPeriodicNoise(x, y, world_width, world_height,
					biome_cells_x, biome_cells_y, settings.seed+83)*0.7 +
					WorldPeriodicNoise(x, y, world_width, world_height,
					detail_cells_x, detail_cells_y, settings.seed+89)*0.3
				if height > 0.65 && land_score > settings.landThreshold+0.12 {
					tile_type = .Hill
				} else if moisture < settings.sandThreshold && land_score > settings.landThreshold+0.12 {
					tile_type = .Desert
				} else if moisture > 0.57 {
					tile_type = .Forest
				} else if moisture > 0.44 {
					tile_type = .FertileGround
				} else {
					tile_type = .Ground
				}
			}
			w.ground[x][y].type = tile_type
		}
	}

	WorldGenerateLakes(w, settings)
	WorldGenerateRivers(w, settings)
	WorldGenerateBeaches(w, settings.beachWidth, settings.seed)
	WorldGenerateDecorations(w, settings.seed)
	w.navigationRevision += 1
	w.terrainRevision += 1
}

WorldGenerateLakes :: proc(w: ^World, settings: WorldGenerationSettings) {
	if settings.lakeCount <= 0 do return

	world_width := int(w.maxX)
	world_height := int(w.maxY)
	minimum_radius := settings.minLakeRadius
	maximum_radius := settings.maxLakeRadius
	if minimum_radius < 1 do minimum_radius = 1
	if maximum_radius < minimum_radius do maximum_radius = minimum_radius

	for lake_index in 0..<settings.lakeCount {
		lake_seed := settings.seed + u64(lake_index)*101 + 1009
		radius_count := maximum_radius - minimum_radius + 1
		radius := minimum_radius + int(WorldNoiseHash(lake_index, 2, lake_seed)*f32(radius_count))
		if radius > maximum_radius do radius = maximum_radius
		angle := WorldNoiseHash(lake_index, 5, lake_seed)*6.2831853
		axis_x, axis_y := math.cos(angle), math.sin(angle)
		radius_x := f32(radius)*(1.0+WorldNoiseHash(lake_index, 6, lake_seed)*0.4)
		radius_y := f32(radius)*(0.5+WorldNoiseHash(lake_index, 7, lake_seed)*0.35)
		extent := int(radius_x*1.25)+2

		center_x, center_y := -1, -1
		for attempt in 0..<64 {
			x := int(WorldNoiseHash(lake_index, attempt*2+3, lake_seed)*f32(world_width))
			y := int(WorldNoiseHash(lake_index, attempt*2+4, lake_seed)*f32(world_height))
			clearance := extent+settings.beachWidth+2
			if w.ground[x][y].type == .Water ||
				w.ground[WorldWrapCoordinate(x+clearance, world_width)][y].type == .Water ||
				w.ground[WorldWrapCoordinate(x-clearance, world_width)][y].type == .Water ||
				w.ground[x][WorldWrapCoordinate(y+clearance, world_height)].type == .Water ||
				w.ground[x][WorldWrapCoordinate(y-clearance, world_height)].type == .Water {
				continue
			}
			center_x, center_y = x, y
			break
		}
		if center_x < 0 do continue

		for delta_x in -extent..=extent {
			for delta_y in -extent..=extent {
				dist_x := f32(delta_x)
				dist_y := f32(delta_y)
				along := dist_x*axis_x+dist_y*axis_y
				across := dist_y*axis_x-dist_x*axis_y
				x := WorldWrapCoordinate(center_x+delta_x, world_width)
				y := WorldWrapCoordinate(center_y+delta_y, world_height)
				shore_noise := WorldPeriodicNoise(x, y, world_width, world_height, 40, 40, lake_seed+7)
				shore := 0.75+shore_noise*0.5
				if w.ground[x][y].type != .Water &&
					along*along/(radius_x*radius_x)+across*across/(radius_y*radius_y) <= shore*shore {
					w.ground[x][y].type = .FreshWater
				}
			}
		}
	}
}

// A distance field guarantees that every river reaches existing water even on
// flat ground, while local elevation and noise choose between downhill routes.
WorldGenerateRivers :: proc(w: ^World, settings: WorldGenerationSettings) {
	if settings.riverCount <= 0 do return
	world_width := int(w.maxX)
	world_height := int(w.maxY)
	node_count := world_width*world_height
	distance := make([dynamic]int, node_count)
	defer delete(distance)
	queue := make([dynamic]int, node_count)
	defer delete(queue)
	head, tail := 0, 0
	for x in 0..<world_width {
		for y in 0..<world_height {
			index := x*world_height+y
			distance[index] = -1
			if w.ground[x][y].type == .Water || w.ground[x][y].type == .FreshWater {
				distance[index] = 0
				queue[tail] = index
				tail += 1
			}
		}
	}
	if tail == 0 do return

	for head < tail {
		index := queue[head]
		head += 1
		x, y := index/world_height, index%world_height
		for direction in 0..<4 {
			nx, ny := x, y
			switch direction {
			case 0: nx += 1
			case 1: nx -= 1
			case 2: ny += 1
			case 3: ny -= 1
			}
			nx = WorldWrapCoordinate(nx, world_width)
			ny = WorldWrapCoordinate(ny, world_height)
			next := nx*world_height+ny
			if distance[next] >= 0 do continue
			distance[next] = distance[index]+1
			queue[tail] = next
			tail += 1
		}
	}

	for river in 0..<settings.riverCount {
		start := -1
		for attempt in 0..<96 {
			seed := settings.seed+u64(river)*139+1901
			x := int(WorldNoiseHash(attempt, 0, seed)*f32(world_width))
			y := int(WorldNoiseHash(attempt, 1, seed)*f32(world_height))
			index := x*world_height+y
			if distance[index] < 10 || w.ground[x][y].type != .Hill do continue
			start = index
			break
		}
		if start < 0 do continue

		current := start
		for distance[current] > 0 {
			x, y := current/world_height, current%world_height
			if w.ground[x][y].type == .River do break
			best := -1
			best_score := f32(2)
			for direction in 0..<4 {
				nx, ny := x, y
				switch direction {
				case 0: nx += 1
				case 1: nx -= 1
				case 2: ny += 1
				case 3: ny -= 1
				}
				nx = WorldWrapCoordinate(nx, world_width)
				ny = WorldWrapCoordinate(ny, world_height)
				next := nx*world_height+ny
				if distance[next] >= distance[current] do continue
				score := WorldPeriodicNoise(nx, ny, world_width, world_height,
					max(1, world_width/24), max(1, world_height/24), settings.seed+u64(river)*19+2017)*0.75 +
					WorldNoiseHash(nx, ny, settings.seed+2019)*0.25
				if w.ground[nx][ny].type == .Hill do score += 0.15
				if w.ground[nx][ny].type == .River do score -= 0.3
				if score < best_score {
					best_score = score
					best = next
				}
			}
			if best < 0 do break
			w.ground[x][y].type = .River
			current = best
		}
	}
}

WorldGenerateBeaches :: proc(w: ^World, beach_width: int, seed: u64) {
	if beach_width <= 0 do return

	world_width := int(w.maxX)
	world_height := int(w.maxY)
	shore_cells_x := max(1, world_width/55)
	shore_cells_y := max(1, world_height/55)
	for x in 0..<world_width {
		for y in 0..<world_height {
			tile_type := w.ground[x][y].type
			if tile_type == .Water || tile_type == .FreshWater || tile_type == .River do continue

			// Broad noise makes continuous sandy bays and rocky or vegetated shores.
			shore := WorldPeriodicNoise(x, y, world_width, world_height,
				shore_cells_x, shore_cells_y, seed+149)*0.8 +
				WorldPeriodicNoise(x, y, world_width, world_height,
					max(1, world_width/18), max(1, world_height/18), seed+157)*0.2
			threshold: f32 = 0.51
			if tile_type == .Hill do threshold = 0.70
			if tile_type == .Forest do threshold = 0.60
			if tile_type == .Desert do threshold = 0.40
			if shore < threshold do continue

			near_water := false
			for delta_x in -beach_width..=beach_width {
				for delta_y in -beach_width..=beach_width {
					if delta_x*delta_x + delta_y*delta_y > beach_width*beach_width do continue
					neighbor_x := WorldWrapCoordinate(x+delta_x, world_width)
					neighbor_y := WorldWrapCoordinate(y+delta_y, world_height)
					if w.ground[neighbor_x][neighbor_y].type == .Water {
						near_water = true
						break
					}
				}
				if near_water do break
			}
			if near_water do w.ground[x][y].type = .Sand
		}
	}
}


WorldPeriodicNoise :: proc(x, y, world_width, world_height, cells_x, cells_y: int, seed: u64) -> f32 {
	if world_width <= 0 || world_height <= 0 || cells_x <= 0 || cells_y <= 0 do return 0.5

	position_x := (f32(x)+0.5) / f32(world_width) * f32(cells_x)
	position_y := (f32(y)+0.5) / f32(world_height) * f32(cells_y)
	grid_x := int(position_x)
	grid_y := int(position_y)
	fraction_x := position_x - f32(grid_x)
	fraction_y := position_y - f32(grid_y)
	smooth_x := fraction_x*fraction_x*(3.0-2.0*fraction_x)
	smooth_y := fraction_y*fraction_y*(3.0-2.0*fraction_y)

	x0 := grid_x % cells_x
	y0 := grid_y % cells_y
	x1 := (x0+1) % cells_x
	y1 := (y0+1) % cells_y
	top_left := WorldNoiseHash(x0, y0, seed)
	top_right := WorldNoiseHash(x1, y0, seed)
	bottom_left := WorldNoiseHash(x0, y1, seed)
	bottom_right := WorldNoiseHash(x1, y1, seed)
	return WorldLerp(
		WorldLerp(top_left, top_right, smooth_x),
		WorldLerp(bottom_left, bottom_right, smooth_x),
		smooth_y,
	)
}


WorldNoiseHash :: proc(x, y: int, seed: u64) -> f32 {
	value := u64(x)*0x9E3779B97F4A7C15 ~ u64(y)*0xBF58476D1CE4E5B9 ~ seed
	value = (value ~ (value >> 30)) * 0xBF58476D1CE4E5B9
	value = (value ~ (value >> 27)) * 0x94D049BB133111EB
	value = value ~ (value >> 31)
	return f32(value % 1_000_000) / 1_000_000.0
}

WorldLerp :: proc(a, b, t: f32) -> f32 {
	return a + (b-a)*t
}

WorldSpawnInitialKingdoms :: proc(w: ^World, kingdom_count: int, seed: u64) -> bool {
	world_width := int(w.maxX)
	world_height := int(w.maxY)
	if world_width <= 0 || world_height <= 0 || kingdom_count <= 0 ||
		kingdom_count > KINGDOMS_CAPACITY {
		return false
	}

	building_width, building_height := BuildingTileSize(TownHall{})
	node_count := world_width * world_height
	occupied := make([dynamic]bool, node_count)
	defer delete(occupied)
	for tile in 0..<node_count {
		occupied[tile] = false
	}

	for building_slot in 0..<BUILDING_CAPACITY {
		if !w.buildingUsed[building_slot] do continue
		building_x := w.buildings.x[building_slot]
		building_y := w.buildings.y[building_slot]
		width, height := BuildingTileSize(w.buildings[building_slot].type)
		for x in max(building_x, 0)..<min(building_x+width, world_width) {
			for y in max(building_y, 0)..<min(building_y+height, world_height) {
				occupied[x*world_height+y] = true
			}
		}
	}

	chosen_x: [KINGDOMS_CAPACITY]int
	chosen_y: [KINGDOMS_CAPACITY]int

	// Capitals sit on evenly spaced rings around the map centre. Land is
	// irregular, so several ring radii and rotations are sampled; every capital
	// snaps to the nearest valid shore and the layout whose resulting pair
	// distances are the most uniform wins. That keeps starting kingdoms about
	// the same distance apart instead of collapsing onto one coastline.
	center_x := f32(world_width)*0.5
	center_y := f32(world_height)*0.5
	base_radius := f32(min(world_width, world_height))*0.33
	rotation := WorldNoiseHash(0, 0, seed+0xCA917A1)*6.2831853
	minimum_spacing := f32(TOWN_FOUNDING_MIN_DISTANCE)
	minimum_spacing_squared := minimum_spacing*minimum_spacing
	half_width := f32(building_width)*0.5
	half_height := f32(building_height)*0.5

	// Capitals need a landmass large enough to support more than a single town;
	// otherwise a kingdom is stranded on a tiny island and can never expand or
	// fight. Label connected land once, then keep the landmass area on each
	// candidate site.
	component := make([]i32, node_count)
	defer delete(component)
	for &value in component do value = -1
	component_area := make([dynamic]int, 0, 64)
	defer delete(component_area)
	stack := make([dynamic]int, 0, 1024)
	defer delete(stack)
	neighbour_offsets := [4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
	for start in 0..<node_count {
		if component[start] >= 0 do continue
		start_x := start/world_height
		start_y := start%world_height
		if !WorldTileWalkable(w, start_x, start_y, Builder{}, -1) do continue

		id := i32(len(component_area))
		area := 0
		clear(&stack)
		append(&stack, start)
		component[start] = id
		for len(stack) > 0 {
			index := pop(&stack)
			x := index/world_height
			y := index%world_height
			area += 1
			for offset in neighbour_offsets {
				neighbour_x := WorldWrapCoordinate(x+offset[0], world_width)
				neighbour_y := WorldWrapCoordinate(y+offset[1], world_height)
				neighbour := neighbour_x*world_height+neighbour_y
				if component[neighbour] >= 0 do continue
				if !WorldTileWalkable(w, neighbour_x, neighbour_y, Builder{}, -1) {
					continue
				}
				component[neighbour] = id
				append(&stack, neighbour)
			}
		}
		append(&component_area, area)
	}

	// One candidate per coarse block is plenty: the chosen site only needs to
	// be on the right side of the map, and thinning the list keeps the ring
	// search cheap even on the biggest maps.
	SITE_BLOCK :: 4
	block_width := (world_width+SITE_BLOCK-1)/SITE_BLOCK
	block_height := (world_height+SITE_BLOCK-1)/SITE_BLOCK
	site_x := make([dynamic]int, 0, block_width*block_height/2)
	site_y := make([dynamic]int, 0, block_width*block_height/2)
	site_area := make([dynamic]int, 0, block_width*block_height/2)
	defer delete(site_x)
	defer delete(site_y)
	defer delete(site_area)

	for block_x in 0..<block_width {
		for block_y in 0..<block_height {
			block_site := -1
			for offset_x in 0..<SITE_BLOCK {
				if block_site >= 0 do break
				x := block_x*SITE_BLOCK+offset_x
				if x >= world_width do break
				for offset_y in 0..<SITE_BLOCK {
					y := block_y*SITE_BLOCK+offset_y
					if y >= world_height do break
					if !WorldBuildingOverTile(w, x, y, TownHall{}) do continue

					is_occupied := false
					for tile_x in x ..< (x + building_width) {
						for tile_y in y ..< (y + building_height) {
							if occupied[tile_x*world_height+tile_y] {
								is_occupied = true
								break
							}
						}
						if is_occupied do break
					}
					if is_occupied do continue

					component_id := component[x*world_height+y]
					if component_id < 0 do continue
					block_site = len(site_x)
					append(&site_x, x)
					append(&site_y, y)
					append(&site_area, component_area[component_id])
					break
				}
			}
		}
	}
	if len(site_x) < kingdom_count do return false

	// Prefer large landmasses. The threshold relaxes only as far as needed to
	// still offer one site per kingdom, so archipelago maps keep working while
	// ordinary maps keep every capital on connected, expandable ground.
	MIN_CAPITAL_LAND_AREA :: 3000
	area_threshold := MIN_CAPITAL_LAND_AREA
	for area_threshold > 0 {
		enough := 0
		for area in site_area {
			if area >= area_threshold do enough += 1
		}
		if enough >= kingdom_count do break
		area_threshold /= 2
	}
	if area_threshold > 0 {
		write := 0
		for site in 0..<len(site_area) {
			if site_area[site] < area_threshold do continue
			site_x[write] = site_x[site]
			site_y[write] = site_y[site]
			site_area[write] = site_area[site]
			write += 1
		}
		resize(&site_x, write)
		resize(&site_y, write)
		resize(&site_area, write)
	}
	if len(site_x) < kingdom_count do return false

	LAYOUT_RADII :: 3
	LAYOUT_ROTATIONS :: 4
	LAYOUT_COUNT :: LAYOUT_RADII*LAYOUT_ROTATIONS

	layout_x: [LAYOUT_COUNT][KINGDOMS_CAPACITY]int
	layout_y: [LAYOUT_COUNT][KINGDOMS_CAPACITY]int
	best_layout := -1
	best_layout_score := f32(1e30)

	for variant in 0..<LAYOUT_COUNT {
		radius_scale := 0.82+0.36*f32(variant%LAYOUT_RADII)/f32(LAYOUT_RADII-1)
		phase := rotation+6.2831853*f32(variant/LAYOUT_RADII) /
			f32(kingdom_count*LAYOUT_ROTATIONS)
		radius := base_radius*radius_scale

		variant_ok := true
		for kingdom_index in 0..<kingdom_count {
			angle := phase+6.2831853*f32(kingdom_index)/f32(kingdom_count)
			target_x := center_x+math.cos(angle)*radius
			target_y := center_y+math.sin(angle)*radius

			best_site := -1
			best_score := f32(1e30)
			best_tie_break := f32(-1.0)
			for site in 0..<len(site_x) {
				candidate_x := f32(site_x[site])+half_width
				candidate_y := f32(site_y[site])+half_height
				delta_x := WorldShortestWrappedDelta(candidate_x-target_x, f32(world_width))
				delta_y := WorldShortestWrappedDelta(candidate_y-target_y, f32(world_height))
				score := (delta_x*delta_x+delta_y*delta_y)/(radius*radius)

				for previous in 0..<kingdom_index {
					previous_x := f32(layout_x[variant][previous])+half_width
					previous_y := f32(layout_y[variant][previous])+half_height
					spacing_x := WorldShortestWrappedDelta(candidate_x-previous_x, f32(world_width))
					spacing_y := WorldShortestWrappedDelta(candidate_y-previous_y, f32(world_height))
					spacing_squared := spacing_x*spacing_x+spacing_y*spacing_y
					if spacing_squared < minimum_spacing_squared {
						score += 1000*(1-spacing_squared/minimum_spacing_squared)
						if spacing_squared < f32(building_width*building_width) do score += 1_000_000
					}
				}

				tie_break := WorldNoiseHash(
					site_x[site],
					site_y[site],
					seed+u64(kingdom_index)*7919+313,
				)
				if score < best_score || (score == best_score && tie_break > best_tie_break) {
					best_site = site
					best_score = score
					best_tie_break = tie_break
				}
			}

			if best_site < 0 {
				variant_ok = false
				break
			}
			layout_x[variant][kingdom_index] = site_x[best_site]
			layout_y[variant][kingdom_index] = site_y[best_site]
		}
		if !variant_ok do continue

		// Prefer the layout with the smallest spread between its shortest and
		// longest capital-to-capital distance, with an extra push if any pair
		// ended up closer than the minimum founding distance.
		layout_score := f32(0)
		if kingdom_count > 1 {
			minimum_pair := f32(1e30)
			maximum_pair := f32(0)
			for a in 0..<kingdom_count {
				for b in a+1..<kingdom_count {
					delta_x := WorldShortestWrappedDelta(
						f32(layout_x[variant][a])-f32(layout_x[variant][b]),
						f32(world_width),
					)
					delta_y := WorldShortestWrappedDelta(
						f32(layout_y[variant][a])-f32(layout_y[variant][b]),
						f32(world_height),
					)
					distance := math.sqrt(delta_x*delta_x+delta_y*delta_y)
					minimum_pair = min(minimum_pair, distance)
					maximum_pair = max(maximum_pair, distance)
				}
			}
			layout_score = maximum_pair-minimum_pair
			if minimum_pair < minimum_spacing {
				layout_score += (minimum_spacing-minimum_pair)*8
			}
		}

		if best_layout < 0 || layout_score < best_layout_score {
			best_layout = variant
			best_layout_score = layout_score
		}
	}

	if best_layout < 0 do return false

	// Relaxation: greedy nearest-land snapping can leave one capital much
	// closer to its neighbour than the rest. A few passes re-pick each capital
	// while directly minimising the spread between the shortest and longest
	// pair distance, anchored to its ring position so the capitals stay evenly
	// distributed around the map.
	best_phase := rotation+6.2831853*f32(best_layout/LAYOUT_RADII) /
		f32(kingdom_count*LAYOUT_ROTATIONS)
	best_radius_scale := 0.82+0.36*f32(best_layout%LAYOUT_RADII)/f32(LAYOUT_RADII-1)
	best_radius := base_radius*best_radius_scale

	if kingdom_count > 2 {
		for _ in 0..<3 {
			for kingdom_index in 0..<kingdom_count {
				other_min := f32(1e30)
				other_max := f32(0)
				for a in 0..<kingdom_count {
					if a == kingdom_index do continue
					for b in a+1..<kingdom_count {
						if b == kingdom_index do continue
						delta_x := WorldShortestWrappedDelta(
							f32(layout_x[best_layout][a])-f32(layout_x[best_layout][b]),
							f32(world_width),
						)
						delta_y := WorldShortestWrappedDelta(
							f32(layout_y[best_layout][a])-f32(layout_y[best_layout][b]),
							f32(world_height),
						)
						distance := math.sqrt(delta_x*delta_x+delta_y*delta_y)
						other_min = min(other_min, distance)
						other_max = max(other_max, distance)
					}
				}

				angle := best_phase+6.2831853*f32(kingdom_index)/f32(kingdom_count)
				anchor_x := center_x+math.cos(angle)*best_radius
				anchor_y := center_y+math.sin(angle)*best_radius

				best_site := -1
				best_score := f32(1e30)
				best_tie_break := f32(-1.0)
				for site in 0..<len(site_x) {
					candidate_x := f32(site_x[site])+half_width
					candidate_y := f32(site_y[site])+half_height

					too_close := false
					nearest := f32(1e30)
					farthest := f32(0)
					for other in 0..<kingdom_count {
						if other == kingdom_index do continue
						delta_x := WorldShortestWrappedDelta(
							candidate_x-(f32(layout_x[best_layout][other])+half_width),
							f32(world_width),
						)
						delta_y := WorldShortestWrappedDelta(
							candidate_y-(f32(layout_y[best_layout][other])+half_height),
							f32(world_height),
						)
						distance := math.sqrt(delta_x*delta_x+delta_y*delta_y)
						if distance < f32(building_width) {
							too_close = true
							break
						}
						nearest = min(nearest, distance)
						farthest = max(farthest, distance)
					}
					if too_close do continue

					spread := max(farthest, other_max)-min(nearest, other_min)
					delta_target_x := WorldShortestWrappedDelta(
						candidate_x-anchor_x,
						f32(world_width),
					)
					delta_target_y := WorldShortestWrappedDelta(
						candidate_y-anchor_y,
						f32(world_height),
					)
					anchor_cost :=
						(delta_target_x*delta_target_x+delta_target_y*delta_target_y) /
						(best_radius*best_radius)*200
					score := spread+anchor_cost

					tie_break := WorldNoiseHash(
						site_x[site],
						site_y[site],
						seed+u64(kingdom_index)*7919+313,
					)
					if score < best_score ||
					   (score == best_score && tie_break > best_tie_break) {
						best_site = site
						best_score = score
						best_tie_break = tie_break
					}
				}

				if best_site >= 0 {
					layout_x[best_layout][kingdom_index] = site_x[best_site]
					layout_y[best_layout][kingdom_index] = site_y[best_site]
				}
			}
		}
	}

	for kingdom_index in 0..<kingdom_count {
		chosen_x[kingdom_index] = layout_x[best_layout][kingdom_index]
		chosen_y[kingdom_index] = layout_y[best_layout][kingdom_index]
	}

	for kingdom_index in 0..<kingdom_count {
		if _, ok := KingdomSpawn(w, chosen_x[kingdom_index], chosen_y[kingdom_index]); !ok {
			return false
		}
		if !TownSpawnInitialPopulation(w, kingdom_index, w.kingdoms[kingdom_index].capitalSlot) {
			return false
		}
	}
	return true
}
