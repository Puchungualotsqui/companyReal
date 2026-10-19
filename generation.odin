package main

WorldGenerationSettings :: struct {
	seed: u64,
	landThreshold: f32,
	sandThreshold: f32,
	beachWidth: int,
	lakeCount: int,
	minLakeRadius: int,
	maxLakeRadius: int,
}

WorldGenerationSettingsDefault :: proc() -> WorldGenerationSettings {
	return WorldGenerationSettings{
		seed = 1,
		landThreshold = 0.47,
		sandThreshold = 0.62,
		beachWidth = 1,
		lakeCount = 4,
		minLakeRadius = 2,
		maxLakeRadius = 5,
	}
}

WorldGenerate :: proc(w: ^World, settings: WorldGenerationSettings) {
	world_width := int(w.maxX)
	world_height := int(w.maxY)
	if world_width <= 0 || world_height <= 0 do return

	for x in 0..<world_width {
		for y in 0..<world_height {
			nx := (f32(x) + 0.5) / f32(world_width) * 2.0 - 1.0
			ny := (f32(y) + 0.5) / f32(world_height) * 2.0 - 1.0

			broad_noise := WorldValueNoise(x, y, 24, settings.seed + 11)
			medium_noise := WorldValueNoise(x, y, 12, settings.seed + 23)
			small_noise := WorldValueNoise(x, y, 6, settings.seed + 37)
			land_noise := broad_noise * 0.55 + medium_noise * 0.3 + small_noise * 0.15
			edge_falloff := 1.0 - nx*nx - ny*ny
			land_score := land_noise*0.55 + edge_falloff*0.45

			tile_type := TileType.Water
			if land_score > settings.landThreshold {
				sand_noise := WorldValueNoise(x, y, 10, settings.seed + 53)*0.7 +
					WorldValueNoise(x, y, 4, settings.seed + 71)*0.3
				if sand_noise > settings.sandThreshold {
					tile_type = .Sand
				} else {
					tile_type = .Ground
				}
			}

			w.ground[x][y].type = tile_type
		}
	}

	WorldGenerateLakes(w, settings)
	WorldGenerateBeaches(w, settings.beachWidth)
	w.navigationRevision += 1
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
		center_x := int(WorldNoiseHash(lake_index, 0, lake_seed) * f32(world_width))
		center_y := int(WorldNoiseHash(lake_index, 1, lake_seed) * f32(world_height))
		radius_count := maximum_radius - minimum_radius + 1
		radius := minimum_radius + int(WorldNoiseHash(lake_index, 2, lake_seed)*f32(radius_count))
		if radius > maximum_radius do radius = maximum_radius

		start_x := max(center_x-radius, 0)
		end_x := min(center_x+radius+1, world_width)
		start_y := max(center_y-radius, 0)
		end_y := min(center_y+radius+1, world_height)
		for x in start_x..<end_x {
			for y in start_y..<end_y {
				delta_x := f32(x-center_x)
				delta_y := f32(y-center_y)
				shore_noise := WorldValueNoise(x, y, max(radius/2, 1), lake_seed + 7)
				distorted_radius := f32(radius) * (0.8 + shore_noise*0.4)
				if delta_x*delta_x + delta_y*delta_y <= distorted_radius*distorted_radius {
					w.ground[x][y].type = .Water
				}
			}
		}
	}
}

WorldGenerateBeaches :: proc(w: ^World, beach_width: int) {
	if beach_width <= 0 do return

	world_width := int(w.maxX)
	world_height := int(w.maxY)
	for x in 0..<world_width {
		for y in 0..<world_height {
			if w.ground[x][y].type == .Water do continue

			start_x := max(x-beach_width, 0)
			end_x := min(x+beach_width+1, world_width)
			start_y := max(y-beach_width, 0)
			end_y := min(y+beach_width+1, world_height)
			near_water := false
			for neighbor_x in start_x..<end_x {
				for neighbor_y in start_y..<end_y {
					delta_x := neighbor_x - x
					delta_y := neighbor_y - y
					if delta_x*delta_x + delta_y*delta_y <= beach_width*beach_width &&
						w.ground[neighbor_x][neighbor_y].type == .Water {
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

WorldValueNoise :: proc(x, y, scale: int, seed: u64) -> f32 {
	grid_x := x / scale
	grid_y := y / scale
	fraction_x := f32(x % scale) / f32(scale)
	fraction_y := f32(y % scale) / f32(scale)
	smooth_x := fraction_x * fraction_x * (3.0 - 2.0*fraction_x)
	smooth_y := fraction_y * fraction_y * (3.0 - 2.0*fraction_y)

	top_left := WorldNoiseHash(grid_x, grid_y, seed)
	top_right := WorldNoiseHash(grid_x + 1, grid_y, seed)
	bottom_left := WorldNoiseHash(grid_x, grid_y + 1, seed)
	bottom_right := WorldNoiseHash(grid_x + 1, grid_y + 1, seed)

	top := WorldLerp(top_left, top_right, smooth_x)
	bottom := WorldLerp(bottom_left, bottom_right, smooth_x)
	return WorldLerp(top, bottom, smooth_y)
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
