package main

import rl "vendor:raylib"

PIXELS_PER_TILE :: 16
SPRITE_FACTION_COUNT :: KINGDOMS_CAPACITY+1

Point :: [2]int

Art :: struct {
	image:  rl.Image,
	width:  int,
	height: int,
}

// Shared pixel-art palette.
C_CLEAR := rl.Color{0, 0, 0, 0}
C_OUTLINE := rl.Color{22, 18, 26, 255}
C_SHADOW := rl.Color{14, 12, 18, 105}

C_STONE_DARKEST := rl.Color{56, 58, 70, 255}
C_STONE_DARK := rl.Color{86, 90, 106, 255}
C_STONE := rl.Color{124, 128, 144, 255}
C_STONE_LIGHT := rl.Color{170, 174, 188, 255}

C_WOOD_DARKEST := rl.Color{56, 34, 24, 255}
C_WOOD_DARK := rl.Color{92, 58, 38, 255}
C_WOOD := rl.Color{132, 86, 52, 255}
C_WOOD_LIGHT := rl.Color{178, 124, 76, 255}

C_ROOF_DARK := rl.Color{92, 42, 44, 255}
C_ROOF := rl.Color{148, 66, 60, 255}
C_ROOF_LIGHT := rl.Color{194, 100, 78, 255}

C_IRON_DARK := rl.Color{50, 52, 62, 255}
C_IRON := rl.Color{94, 98, 110, 255}
C_IRON_LIGHT := rl.Color{154, 160, 172, 255}

C_GOLD_DARK := rl.Color{168, 114, 40, 255}
C_GOLD := rl.Color{224, 176, 70, 255}
C_GOLD_LIGHT := rl.Color{255, 226, 136, 255}

C_SKIN := rl.Color{222, 174, 136, 255}
C_SKIN_DARK := rl.Color{174, 120, 90, 255}
C_HAIR := rl.Color{78, 52, 38, 255}
C_HAIR_LIGHT := rl.Color{140, 96, 58, 255}

C_LEAF_DARKEST := rl.Color{36, 68, 42, 255}
C_LEAF_DARK := rl.Color{50, 98, 56, 255}
C_LEAF := rl.Color{80, 140, 70, 255}
C_LEAF_LIGHT := rl.Color{128, 178, 92, 255}

C_WATER_DARK := rl.Color{42, 88, 122, 255}
C_WATER := rl.Color{68, 132, 166, 255}
C_WATER_LIGHT := rl.Color{118, 184, 206, 255}

C_DIRT_DARK := rl.Color{74, 52, 36, 255}
C_DIRT := rl.Color{106, 78, 52, 255}

C_CLOTH_DARKEST := rl.Color{42, 38, 54, 255}
C_CLOTH_DARK := rl.Color{76, 68, 100, 255}
C_CLOTH := rl.Color{118, 108, 148, 255}
C_CLOTH_LIGHT := rl.Color{164, 152, 190, 255}

C_ARCANE_DARK := rl.Color{62, 40, 102, 255}
C_ARCANE := rl.Color{104, 70, 160, 255}
C_ARCANE_LIGHT := rl.Color{158, 118, 214, 255}
C_ARCANE_GLOW := rl.Color{128, 226, 255, 255}

C_WHITE := rl.Color{238, 238, 244, 255}

ALL_BUILDING_KINDS := [14]BuildingKind{
	.TownHall,
	.Home,
	.Farmland,
	.Wall,
	.Bridge,
	.Cannon,
	.Watchtower,
	.ArcheryRange,
	.MagicSchool,
	.GiantPen,
	.SiegeWorkshop,
	.TurtlePen,
	.ThievesGuild,
	.Path,
}

ALL_UNIT_KINDS := [12]UnitKind{
	.Villager,
	.Builder,
	.CombatBuilder,
	.WaterCollector,
	.Farmer,
	.Knight,
	.Archer,
	.Mage,
	.Giant,
	.Turtle,
	.Catapult,
	.Rogue,
}

KingdomColor :: proc(kingdom: int) -> rl.Color {
	switch kingdom {
	case 0:
		return rl.Color{74, 126, 204, 255}
	case 1:
		return rl.Color{198, 74, 72, 255}
	case 2:
		return rl.Color{86, 158, 96, 255}
	case 3:
		return rl.Color{150, 104, 196, 255}
	case 4:
		return rl.Color{214, 164, 72, 255}
	}
	return rl.Color{150, 150, 158, 255}
}

FactionColor :: proc(faction: int) -> rl.Color {
	if faction >= 0 && faction < KINGDOMS_CAPACITY do return KingdomColor(faction)
	return rl.Color{150, 150, 158, 255}
}

FactionSpriteIndex :: proc(kingdom: int) -> int {
	if kingdom >= 0 && kingdom < KINGDOMS_CAPACITY do return kingdom
	return KINGDOMS_CAPACITY
}

UnitSpriteScale :: proc(kind: UnitKind) -> f32 {
	switch kind {
	case .Giant:
		return 1.55
	case .Turtle:
		return 1.35
	case .Catapult:
		return 1.55
	case .Knight, .Rogue:
		return 1.1
	case .Villager, .Builder, .CombatBuilder, .WaterCollector, .Farmer, .Archer, .Mage:
		return 1
	}
	return 1
}

c_shade :: proc(color: rl.Color, factor: f32) -> rl.Color {
	return rl.Color{
		u8(clamp(f32(color[0])*factor, 0.0, 255.0)),
		u8(clamp(f32(color[1])*factor, 0.0, 255.0)),
		u8(clamp(f32(color[2])*factor, 0.0, 255.0)),
		color[3],
	}
}

art_init :: proc(width, height: int) -> Art {
	return Art{
		image = rl.GenImageColor(i32(width), i32(height), C_CLEAR),
		width = width,
		height = height,
	}
}

art_pixel :: proc(art: ^Art, x, y: int, color: rl.Color) {
	if x < 0 || y < 0 || x >= art.width || y >= art.height do return
	rl.ImageDrawPixel(&art.image, i32(x), i32(y), color)
}

art_rect :: proc(art: ^Art, x, y, width, height: int, color: rl.Color) {
	if width <= 0 || height <= 0 do return
	for py in y ..< y+height {
		for px in x ..< x+width {
			art_pixel(art, px, py, color)
		}
	}
}

art_rect_outline :: proc(art: ^Art, x, y, width, height: int, color: rl.Color) {
	if width <= 0 || height <= 0 do return
	for px in x ..< x+width {
		art_pixel(art, px, y, color)
		art_pixel(art, px, y+height-1, color)
	}
	for py in y ..< y+height {
		art_pixel(art, x, py, color)
		art_pixel(art, x+width-1, py, color)
	}
}

art_line :: proc(art: ^Art, x0, y0, x1, y1: int, color: rl.Color) {
	x := x0
	y := y0
	dx := x1-x0
	if dx < 0 do dx = -dx
	sx := 1
	if x0 > x1 do sx = -1
	dy := y1-y0
	if dy < 0 do dy = -dy
	dy = -dy
	sy := 1
	if y0 > y1 do sy = -1
	err := dx+dy
	for {
		art_pixel(art, x, y, color)
		if x == x1 && y == y1 do break
		e2 := 2*err
		if e2 >= dy {
			err += dy
			x += sx
		}
		if e2 <= dx {
			err += dx
			y += sy
		}
	}
}

art_ellipse :: proc(art: ^Art, cx, cy, rx, ry: int, color: rl.Color) {
	if rx <= 0 || ry <= 0 do return
	for y in -ry ..= ry {
		for x in -rx ..= rx {
			if x*x*ry*ry+y*y*rx*rx <= rx*rx*ry*ry {
				art_pixel(art, cx+x, cy+y, color)
			}
		}
	}
}

art_circle :: proc(art: ^Art, cx, cy, radius: int, color: rl.Color) {
	art_ellipse(art, cx, cy, radius, radius, color)
}

art_polygon :: proc(art: ^Art, points: []Point, color: rl.Color) {
	if len(points) < 3 do return
	min_y := points[0][1]
	max_y := points[0][1]
	for point in points {
		min_y = min(min_y, point[1])
		max_y = max(max_y, point[1])
	}
	intersections: [64]f32
	for y in min_y ..= max_y {
		count := 0
		for i in 0 ..< len(points) {
			a := points[i]
			b := points[(i+1)%len(points)]
			if (a[1] <= y && b[1] > y) || (b[1] <= y && a[1] > y) {
				t := f32(y-a[1])/f32(b[1]-a[1])
				if count < len(intersections) {
					intersections[count] = f32(a[0])+t*f32(b[0]-a[0])
					count += 1
				}
			}
		}
		for i in 1 ..< count {
			key := intersections[i]
			j := i-1
			for j >= 0 && intersections[j] > key {
				intersections[j+1] = intersections[j]
				j -= 1
			}
			intersections[j+1] = key
		}
		for i in 0 ..< count/2 {
			x0 := int(intersections[i*2])
			x1 := int(intersections[i*2+1])
			for x in x0 ..= x1 {
				art_pixel(art, x, y, color)
			}
		}
	}
}

art_triangle :: proc(art: ^Art, x0, y0, x1, y1, x2, y2: int, color: rl.Color) {
	points := [3]Point{{x0, y0}, {x1, y1}, {x2, y2}}
	art_polygon(art, points[:], color)
}

art_to_texture :: proc(art: Art) -> rl.Texture2D {
	texture := rl.LoadTextureFromImage(art.image)
	rl.SetTextureFilter(texture, .POINT)
	return texture
}

// Sparse weathering so large flat surfaces (stone, timber, roof shingles) pick up
// the same grain as the ground instead of reading as clean vector shapes.
art_grain :: proc(art: ^Art, seed: u64) {
	for y in 0..<art.height {
		for x in 0..<art.width {
			color := rl.GetImageColor(art.image, i32(x), i32(y))
			if color[3] < 200 do continue
			value := WorldNoiseHash(x, y, seed)
			if value > 0.08 do continue
			factor: f32 = 0.9
			if WorldNoiseHash(y, x, seed+1) < 0.5 do factor = 1.1
			if y > art.height-art.height/6 && WorldNoiseHash(x, y, seed+2) < 0.35 do factor = 0.84
			art_pixel(art, x, y, c_shade(color, factor))
		}
	}
}

create_shadow_texture :: proc() -> rl.Texture2D {
	width := 64
	height := 64
	image := rl.GenImageColor(i32(width), i32(height), C_CLEAR)
	for y in 0..<height {
		for x in 0..<width {
			nx := (f32(x)+0.5)/f32(width)*2-1
			ny := (f32(y)+0.5)/f32(height)*2-1
			// Wide plateau with soft edges, fading from the caster to the ground.
			horizontal := clamp((1-abs(nx))/0.35, 0, 1)
			horizontal = horizontal*horizontal*(3-2*horizontal)
			vertical := clamp(1-(ny+1)*0.5, 0, 1)
			vertical = vertical*vertical*(3-2*vertical)
			alpha := u8(horizontal*vertical*235)
			if alpha == 0 do continue
			rl.ImageDrawPixel(&image, i32(x), i32(y), rl.Color{18, 16, 24, alpha})
		}
	}
	texture := rl.LoadTextureFromImage(image)
	rl.UnloadImage(image)
	rl.SetTextureFilter(texture, .BILINEAR)
	rl.SetTextureWrap(texture, .CLAMP)
	return texture
}

create_glow_texture :: proc() -> rl.Texture2D {
	width := 64
	height := 64
	image := rl.GenImageColor(i32(width), i32(height), C_CLEAR)
	for y in 0..<height {
		for x in 0..<width {
			nx := (f32(x)+0.5)/f32(width)*2-1
			ny := (f32(y)+0.5)/f32(height)*2-1
			distance := nx*nx+ny*ny
			if distance >= 1 do continue
			alpha := u8((1-distance)*(1-distance)*255)
			rl.ImageDrawPixel(&image, i32(x), i32(y), rl.Color{255, 196, 120, alpha})
		}
	}
	texture := rl.LoadTextureFromImage(image)
	rl.UnloadImage(image)
	rl.SetTextureFilter(texture, .BILINEAR)
	rl.SetTextureWrap(texture, .CLAMP)
	return texture
}

// Buildings with lit interiors and windows cast a warm pool of light at night.
BuildingHasNightLight :: proc(kind: BuildingKind) -> bool {
	switch kind {
	case .TownHall, .Home, .ArcheryRange, .MagicSchool, .GiantPen, .SiegeWorkshop, .ThievesGuild, .Watchtower:
		return true
	case .Farmland, .Wall, .Bridge, .Cannon, .TurtlePen, .Path:
		return false
	}
	unreachable()
}

draw_shadow :: proc(art: ^Art, cx, cy, rx, ry: int) {
	art_ellipse(art, cx, cy, rx, ry, C_SHADOW)
}

draw_stone_seams :: proc(art: ^Art, x, y, width, height, step: int, color: rl.Color) {
	for px := x+step; px < x+width; px += step {
		art_line(art, px, y, px, y+height-1, color)
	}
	for py := y+step; py < y+height; py += step {
		art_line(art, x, py, x+width-1, py, color)
	}
}

draw_window :: proc(art: ^Art, x, y, width, height: int, lit: bool) {
	art_rect(art, x, y, width, height, C_OUTLINE)
	fill := C_STONE_DARKEST
	if lit do fill = C_GOLD_LIGHT
	art_rect(art, x+1, y+1, width-2, height-2, fill)
	if width > 3 && height > 3 {
		art_line(art, x+width/2, y+1, x+width/2, y+height-2, C_OUTLINE)
		art_line(art, x+1, y+height/2, x+width-2, y+height/2, C_OUTLINE)
	}
}

draw_banner :: proc(art: ^Art, x, y, width, height: int, accent: rl.Color) {
	art_rect(art, x, y, width, height, C_OUTLINE)
	art_rect(art, x+1, y+1, width-2, height-2, c_shade(accent, 0.9))
	art_rect(art, x+1, y+1, width-2, 1, c_shade(accent, 1.25))
	if width >= 4 && height >= 6 {
		art_rect(art, x+width/2-1, y+height/2-1, 2, 2, C_GOLD_LIGHT)
	}
}

draw_flag :: proc(art: ^Art, x, y: int, accent: rl.Color) {
	art_line(art, x, y, x, y+6, C_OUTLINE)
	art_rect(art, x+1, y, 4, 3, accent)
	art_rect_outline(art, x+1, y, 4, 3, C_OUTLINE)
	art_pixel(art, x+2, y+1, c_shade(accent, 1.3))
}

// ---------------------------------------------------------------------------
// Buildings
// ---------------------------------------------------------------------------

draw_building_sprite :: proc(kind: BuildingKind, accent: rl.Color) -> Art {
	width, height := BuildingTileSize(BuildingTypeFromKind(kind))
	art := art_init(width*PIXELS_PER_TILE, height*PIXELS_PER_TILE)
	switch kind {
	case .TownHall:
		draw_town_hall(&art, accent)
	case .Home:
		draw_home(&art, accent)
	case .Farmland:
		draw_farmland(&art, accent)
	case .Wall:
		draw_wall(&art, accent)
	case .Bridge:
		draw_bridge(&art, accent)
	case .Cannon:
		draw_cannon(&art, accent)
	case .Watchtower:
		draw_watchtower(&art, accent)
	case .ArcheryRange:
		draw_archery_range(&art, accent)
	case .MagicSchool:
		draw_magic_school(&art, accent)
	case .GiantPen:
		draw_giant_pen(&art, accent)
	case .SiegeWorkshop:
		draw_siege_workshop(&art, accent)
	case .TurtlePen:
		draw_turtle_pen(&art, accent)
	case .ThievesGuild:
		draw_thieves_guild(&art, accent)
	case .Path:
		draw_path(&art, accent)
	}
	return art
}

draw_path :: proc(art: ^Art, accent: rl.Color) {
	worn := c_shade(C_DIRT, 1.12)
	art_rect(art, 0, 0, PIXELS_PER_TILE, PIXELS_PER_TILE, C_DIRT)
	art_rect(art, 0, 5, PIXELS_PER_TILE, 6, worn)
	art_rect(art, 5, 0, 6, PIXELS_PER_TILE, worn)

	for i in 0..<30 {
		x := int(WorldNoiseHash(i, 11, 0xB01)*PIXELS_PER_TILE)
		y := int(WorldNoiseHash(11, i, 0xB02)*PIXELS_PER_TILE)
		color := C_DIRT_DARK
		if WorldNoiseHash(x, y, 0xB03) < 0.35 do color = C_WOOD_LIGHT
		art_pixel(art, x, y, color)
	}
	for i in 0..<5 {
		x := 1+int(WorldNoiseHash(i, 17, 0xB04)*13)
		y := 1+int(WorldNoiseHash(17, i, 0xB05)*13)
		art_rect(art, x, y, 2, 1, C_STONE_DARK)
		art_pixel(art, x, y, C_STONE)
	}

	// Ragged rim so the road blends into grass instead of reading as a slab.
	for i in 0..<PIXELS_PER_TILE {
		if WorldNoiseHash(i, 0, 0xB11) < 0.6 do art_pixel(art, i, 0, C_CLEAR)
		if WorldNoiseHash(i, 1, 0xB12) < 0.6 do art_pixel(art, i, PIXELS_PER_TILE-1, C_CLEAR)
		if WorldNoiseHash(2, i, 0xB13) < 0.6 do art_pixel(art, 0, i, C_CLEAR)
		if WorldNoiseHash(3, i, 0xB14) < 0.6 do art_pixel(art, PIXELS_PER_TILE-1, i, C_CLEAR)
	}
	art_pixel(art, 13, 2, accent)
}

// Scaffolding laid over the footprint while a building is under construction.
draw_construction_sprite :: proc(accent: rl.Color) -> Art {
	art := art_init(PIXELS_PER_TILE, PIXELS_PER_TILE)
	art_rect(&art, 0, 0, PIXELS_PER_TILE, PIXELS_PER_TILE, C_DIRT_DARK)

	for i in 0..<18 {
		x := int(WorldNoiseHash(i, 23, 0xC01)*PIXELS_PER_TILE)
		y := int(WorldNoiseHash(23, i, 0xC02)*PIXELS_PER_TILE)
		color := C_DIRT
		if WorldNoiseHash(x, y, 0xC03) < 0.4 do color = C_WOOD_DARKEST
		art_pixel(&art, x, y, color)
	}

	art_rect(&art, 0, 6, PIXELS_PER_TILE, 4, C_OUTLINE)
	art_rect(&art, 0, 7, PIXELS_PER_TILE, 2, C_WOOD_DARK)
	art_rect(&art, 6, 0, 4, PIXELS_PER_TILE, C_OUTLINE)
	art_rect(&art, 7, 0, 2, PIXELS_PER_TILE, C_WOOD_DARK)

	art_rect(&art, 1, 1, 3, 3, C_OUTLINE)
	art_rect(&art, 2, 2, 1, 1, C_WOOD_LIGHT)
	art_rect(&art, 12, 12, 3, 3, C_OUTLINE)
	art_rect(&art, 13, 13, 1, 1, C_WOOD_LIGHT)

	art_pixel(&art, 8, 8, accent)
	return art
}

draw_fire_sprite :: proc() -> Art {
	art := art_init(PIXELS_PER_TILE, PIXELS_PER_TILE)
	art_ellipse(&art, 8, 11, 5, 4, C_ROOF)
	art_triangle(&art, 8, 0, 5, 9, 11, 9, C_ROOF)
	art_ellipse(&art, 8, 11, 4, 3, C_GOLD_DARK)
	art_triangle(&art, 8, 3, 6, 10, 10, 10, C_GOLD_DARK)
	art_ellipse(&art, 8, 11, 2, 2, C_GOLD)
	art_triangle(&art, 8, 6, 7, 10, 9, 10, C_GOLD)
	art_pixel(&art, 8, 10, C_GOLD_LIGHT)
	art_pixel(&art, 8, 8, C_GOLD_LIGHT)
	art_pixel(&art, 3, 14, C_GOLD_DARK)
	art_pixel(&art, 12, 14, C_GOLD_DARK)
	return art
}

draw_home :: proc(art: ^Art, accent: rl.Color) {
	draw_shadow(art, 8, 14, 5, 2)
	art_rect(art, 3, 7, 10, 7, C_OUTLINE)
	art_rect(art, 4, 8, 8, 5, C_WOOD_DARK)
	art_rect(art, 4, 8, 8, 1, C_WOOD)
	art_line(art, 4, 12, 11, 12, C_WOOD_DARKEST)

	art_triangle(art, 8, 1, 0, 8, 15, 8, C_OUTLINE)
	art_triangle(art, 8, 2, 2, 8, 13, 8, C_ROOF)
	art_triangle(art, 8, 3, 4, 8, 11, 8, C_ROOF_LIGHT)

	art_rect(art, 6, 10, 3, 4, C_OUTLINE)
	art_rect(art, 7, 11, 1, 3, C_WOOD_DARKEST)
	art_rect(art, 4, 9, 2, 2, C_OUTLINE)
	art_rect(art, 5, 10, 1, 1, C_GOLD_LIGHT)

	art_rect(art, 10, 3, 2, 3, C_OUTLINE)
	art_rect(art, 10, 4, 1, 2, C_STONE_DARK)
	draw_flag(art, 12, 4, accent)
}

draw_town_hall :: proc(art: ^Art, accent: rl.Color) {
	draw_shadow(art, 32, 61, 26, 3)

	art_rect(art, 22, 56, 20, 6, C_OUTLINE)
	art_rect(art, 23, 57, 18, 5, C_STONE_DARK)
	art_rect(art, 24, 58, 16, 4, C_STONE)

	art_rect(art, 4, 38, 56, 18, C_OUTLINE)
	art_rect(art, 5, 39, 54, 16, C_STONE_DARK)
	draw_stone_seams(art, 5, 39, 54, 16, 8, C_STONE_DARKEST)

	art_rect(art, 8, 20, 48, 20, C_OUTLINE)
	art_rect(art, 9, 21, 46, 18, C_STONE)
	art_rect(art, 9, 21, 46, 2, C_STONE_LIGHT)

	roof_outline := [5]Point{{1, 22}, {62, 22}, {54, 8}, {32, 0}, {10, 8}}
	art_polygon(art, roof_outline[:], C_OUTLINE)
	roof := [5]Point{{3, 21}, {60, 21}, {52, 9}, {32, 2}, {12, 9}}
	art_polygon(art, roof[:], C_ROOF)
	roof_high := [5]Point{{6, 19}, {57, 19}, {50, 10}, {32, 4}, {15, 10}}
	art_polygon(art, roof_high[:], C_ROOF_LIGHT)
	for y := 12; y < 21; y += 3 {
		art_line(art, 9, y, 54, y, C_ROOF_DARK)
	}

	art_rect(art, 25, 8, 14, 18, C_OUTLINE)
	art_rect(art, 26, 9, 12, 16, C_STONE_LIGHT)
	draw_stone_seams(art, 26, 9, 12, 16, 4, C_STONE)
	art_triangle(art, 32, 0, 23, 10, 41, 10, C_OUTLINE)
	art_triangle(art, 32, 1, 25, 9, 39, 9, C_ROOF)

	art_rect(art, 29, 13, 6, 8, C_OUTLINE)
	art_rect(art, 30, 14, 4, 6, C_WATER_DARK)
	art_rect(art, 31, 15, 1, 2, C_GOLD_LIGHT)

	art_rect(art, 25, 44, 14, 16, C_OUTLINE)
	art_rect(art, 26, 45, 12, 15, C_WOOD_DARKEST)
	art_rect(art, 27, 47, 10, 13, C_WOOD_DARK)
	art_line(art, 32, 46, 32, 59, C_WOOD_DARKEST)
	art_pixel(art, 30, 52, C_GOLD)
	art_pixel(art, 34, 52, C_GOLD)

	draw_window(art, 12, 28, 6, 9, true)
	draw_window(art, 46, 28, 6, 9, true)
	draw_window(art, 12, 44, 5, 7, true)
	draw_window(art, 47, 44, 5, 7, true)

	draw_banner(art, 7, 26, 7, 18, accent)
	draw_banner(art, 50, 26, 7, 18, accent)
	draw_flag(art, 32, 1, accent)

	art_rect(art, 21, 52, 2, 5, C_WOOD_DARKEST)
	art_rect(art, 41, 52, 2, 5, C_WOOD_DARKEST)
	art_pixel(art, 22, 51, C_GOLD_LIGHT)
	art_pixel(art, 42, 51, C_GOLD_LIGHT)
}

draw_farmland :: proc(art: ^Art, accent: rl.Color) {
	art_rect(art, 2, 2, 28, 28, C_OUTLINE)
	art_rect(art, 3, 3, 26, 26, C_DIRT_DARK)
	art_rect(art, 4, 4, 24, 24, C_DIRT)
	for y := 7; y < 27; y += 4 {
		art_rect(art, 4, y, 24, 1, C_DIRT_DARK)
		for x := 5; x < 27; x += 3 {
			art_rect(art, x, y-1, 1, 2, C_LEAF)
			art_pixel(art, x, y-2, C_LEAF_LIGHT)
		}
	}
	for x := 2; x <= 29; x += 5 {
		art_rect(art, x, 1, 1, 4, C_WOOD_DARK)
		art_rect(art, x, 27, 1, 4, C_WOOD_DARK)
	}
	art_line(art, 2, 3, 29, 3, C_WOOD)
	art_line(art, 2, 28, 29, 28, C_WOOD)

	art_line(art, 25, 20, 25, 12, C_WOOD_DARKEST)
	art_line(art, 22, 15, 28, 15, C_WOOD_DARKEST)
	art_rect(art, 23, 12, 5, 4, accent)
	art_rect(art, 24, 10, 3, 2, C_GOLD_LIGHT)
	art_pixel(art, 24, 14, C_OUTLINE)
	art_pixel(art, 26, 14, C_OUTLINE)
	draw_flag(art, 3, 0, accent)
}

draw_wall :: proc(art: ^Art, accent: rl.Color) {
	draw_shadow(art, 8, 14, 6, 2)
	art_rect(art, 1, 5, 14, 10, C_OUTLINE)
	art_rect(art, 2, 6, 12, 8, C_STONE_DARK)
	draw_stone_seams(art, 2, 6, 12, 8, 4, C_STONE_DARKEST)

	art_rect(art, 1, 2, 4, 4, C_OUTLINE)
	art_rect(art, 2, 3, 2, 3, C_STONE)
	art_rect(art, 7, 2, 3, 4, C_OUTLINE)
	art_rect(art, 7, 3, 2, 3, C_STONE)
	art_rect(art, 12, 2, 3, 4, C_OUTLINE)
	art_rect(art, 12, 3, 2, 3, C_STONE)

	art_rect(art, 6, 8, 4, 3, C_OUTLINE)
	art_rect(art, 7, 9, 2, 1, accent)
	art_pixel(art, 3, 12, C_LEAF_DARK)
	art_pixel(art, 11, 11, C_LEAF_DARK)
}

draw_bridge :: proc(art: ^Art, accent: rl.Color) {
	art_rect(art, 1, 2, 14, 12, C_OUTLINE)
	art_rect(art, 2, 3, 12, 10, C_WOOD)
	for x := 3; x < 14; x += 3 {
		art_line(art, x, 3, x, 12, C_WOOD_DARK)
	}
	art_line(art, 2, 2, 13, 2, C_WOOD_DARKEST)
	art_line(art, 2, 13, 13, 13, C_WOOD_DARKEST)
	art_rect(art, 1, 1, 2, 3, C_WOOD_DARKEST)
	art_rect(art, 13, 1, 2, 3, C_WOOD_DARKEST)
	art_rect(art, 1, 12, 2, 3, C_WOOD_DARKEST)
	art_rect(art, 13, 12, 2, 3, C_WOOD_DARKEST)
	draw_flag(art, 2, 0, accent)
}

draw_cannon :: proc(art: ^Art, accent: rl.Color) {
	draw_shadow(art, 16, 28, 13, 3)
	art_rect(art, 4, 20, 24, 9, C_OUTLINE)
	art_rect(art, 5, 21, 22, 7, C_STONE_DARK)
	draw_stone_seams(art, 5, 21, 22, 7, 5, C_STONE_DARKEST)

	art_circle(art, 10, 27, 4, C_OUTLINE)
	art_circle(art, 10, 27, 3, C_WOOD_DARKEST)
	art_circle(art, 10, 27, 1, C_WOOD)
	art_circle(art, 22, 27, 4, C_OUTLINE)
	art_circle(art, 22, 27, 3, C_WOOD_DARKEST)
	art_circle(art, 22, 27, 1, C_WOOD)

	art_rect(art, 7, 16, 18, 7, C_OUTLINE)
	art_rect(art, 8, 17, 16, 5, C_WOOD_DARK)
	art_rect(art, 8, 10, 17, 6, C_OUTLINE)
	art_rect(art, 9, 11, 15, 4, C_IRON_DARK)
	art_rect(art, 9, 11, 15, 1, C_IRON_LIGHT)
	art_circle(art, 25, 13, 3, C_OUTLINE)
	art_circle(art, 25, 13, 2, C_IRON)
	art_circle(art, 25, 13, 1, C_OUTLINE)
	art_line(art, 14, 11, 14, 14, C_IRON_LIGHT)
	art_line(art, 20, 11, 20, 14, C_IRON_LIGHT)
	art_rect(art, 11, 12, 6, 2, accent)
	draw_flag(art, 26, 5, accent)
}

draw_watchtower :: proc(art: ^Art, accent: rl.Color) {
	draw_shadow(art, 8, 14, 6, 2)

	art_rect(art, 2, 4, 12, 11, C_OUTLINE)
	art_rect(art, 3, 5, 10, 9, C_STONE_DARK)
	draw_stone_seams(art, 3, 5, 10, 9, 3, C_STONE_DARKEST)

	art_rect(art, 1, 1, 14, 4, C_OUTLINE)
	art_rect(art, 2, 2, 12, 2, C_STONE)
	for x in 2..<14 {
		if x%4 == 0 do art_rect(art, x, 0, 2, 3, C_OUTLINE)
	}

	art_rect(art, 6, 6, 4, 5, C_OUTLINE)
	art_rect(art, 7, 7, 2, 3, C_GOLD_LIGHT)
	art_rect(art, 4, 9, 2, 2, C_OUTLINE)
	art_rect(art, 5, 10, 1, 1, C_STONE_LIGHT)

	art_line(art, 12, 15, 12, 5, C_OUTLINE)
	art_rect(art, 12, 3, 3, 4, accent)
	art_rect_outline(art, 12, 3, 3, 4, C_OUTLINE)
	art_pixel(art, 13, 4, C_GOLD_LIGHT)
}

draw_archery_range :: proc(art: ^Art, accent: rl.Color) {
	draw_shadow(art, 24, 45, 20, 3)
	art_rect(art, 4, 18, 26, 22, C_OUTLINE)
	art_rect(art, 5, 19, 24, 20, C_WOOD_DARK)
	for y := 22; y < 39; y += 4 {
		art_line(art, 5, y, 28, y, C_WOOD_DARKEST)
	}
	roof_outline := [4]Point{{1, 19}, {33, 19}, {28, 7}, {6, 7}}
	art_polygon(art, roof_outline[:], C_OUTLINE)
	roof := [4]Point{{3, 18}, {31, 18}, {27, 8}, {7, 8}}
	art_polygon(art, roof[:], C_ROOF_DARK)
	roof_high := [4]Point{{5, 16}, {29, 16}, {26, 9}, {8, 9}}
	art_polygon(art, roof_high[:], C_ROOF)
	art_rect(art, 12, 26, 8, 14, C_OUTLINE)
	art_rect(art, 13, 27, 6, 13, C_WOOD_DARKEST)
	art_pixel(art, 17, 33, C_GOLD)
	draw_window(art, 22, 24, 4, 5, true)

	for y := 20; y <= 44; y += 6 {
		art_rect(art, 33, y, 1, 4, C_WOOD_DARK)
	}
	art_line(art, 33, 21, 33, 44, C_WOOD)
	art_line(art, 33, 22, 47, 22, C_WOOD)

	art_circle(art, 41, 28, 5, C_OUTLINE)
	art_circle(art, 41, 28, 4, C_GOLD_LIGHT)
	art_circle(art, 41, 28, 3, C_ROOF)
	art_circle(art, 41, 28, 2, C_WHITE)
	art_circle(art, 41, 28, 1, C_ROOF_DARK)
	art_circle(art, 39, 39, 4, C_OUTLINE)
	art_circle(art, 39, 39, 3, C_GOLD_LIGHT)
	art_circle(art, 39, 39, 2, C_ROOF)
	art_circle(art, 39, 39, 1, C_WHITE)
	art_line(art, 38, 30, 37, 27, C_WOOD_LIGHT)
	art_line(art, 43, 31, 44, 28, C_WOOD_LIGHT)
	draw_flag(art, 27, 1, accent)
}

draw_magic_school :: proc(art: ^Art, accent: rl.Color) {
	draw_shadow(art, 24, 45, 18, 3)
	art_rect(art, 10, 16, 28, 28, C_OUTLINE)
	art_rect(art, 11, 17, 26, 26, C_STONE_DARK)
	draw_stone_seams(art, 11, 17, 26, 26, 6, C_STONE_DARKEST)

	roof_outline := [5]Point{{6, 18}, {42, 18}, {36, 6}, {24, 0}, {12, 6}}
	art_polygon(art, roof_outline[:], C_OUTLINE)
	roof := [5]Point{{8, 17}, {40, 17}, {35, 7}, {24, 2}, {13, 7}}
	art_polygon(art, roof[:], C_ARCANE_DARK)
	roof_high := [5]Point{{11, 15}, {37, 15}, {33, 9}, {24, 4}, {15, 9}}
	art_polygon(art, roof_high[:], C_ARCANE)
	art_pixel(art, 20, 10, C_ARCANE_GLOW)
	art_pixel(art, 28, 8, C_GOLD_LIGHT)
	art_pixel(art, 24, 13, C_WHITE)

	art_rect(art, 20, 32, 8, 12, C_OUTLINE)
	art_rect(art, 21, 33, 6, 11, C_WOOD_DARKEST)
	art_circle(art, 24, 32, 3, C_OUTLINE)
	art_circle(art, 24, 32, 2, C_WOOD_DARKEST)

	draw_window(art, 14, 22, 4, 6, true)
	draw_window(art, 30, 22, 4, 6, true)
	art_rect(art, 15, 23, 2, 4, C_ARCANE_GLOW)
	art_rect(art, 31, 23, 2, 4, C_ARCANE_GLOW)

	art_circle(art, 38, 12, 3, C_OUTLINE)
	art_circle(art, 38, 12, 2, C_ARCANE_GLOW)
	art_pixel(art, 37, 11, C_WHITE)

	draw_banner(art, 6, 26, 6, 14, accent)
	draw_flag(art, 36, 2, accent)
}

draw_giant_pen :: proc(art: ^Art, accent: rl.Color) {
	draw_shadow(art, 32, 60, 26, 3)
	art_rect(art, 4, 16, 56, 44, C_OUTLINE)
	art_rect(art, 5, 17, 54, 42, C_DIRT_DARK)
	art_rect(art, 7, 19, 50, 38, C_DIRT)

	for x := 5; x <= 58; x += 8 {
		art_rect(art, x, 14, 2, 46, C_WOOD_DARKEST)
	}
	art_line(art, 5, 16, 59, 16, C_WOOD)
	art_line(art, 5, 58, 59, 58, C_WOOD)
	art_line(art, 5, 30, 59, 30, C_WOOD)

	art_rect(art, 8, 30, 26, 22, C_OUTLINE)
	art_rect(art, 9, 31, 24, 20, C_WOOD_DARK)
	roof := [4]Point{{5, 31}, {37, 31}, {32, 20}, {10, 20}}
	art_polygon(art, roof[:], C_OUTLINE)
	roof_inner := [4]Point{{8, 30}, {34, 30}, {30, 22}, {12, 22}}
	art_polygon(art, roof_inner[:], C_ROOF_DARK)
	art_rect(art, 13, 38, 12, 13, C_WOOD_DARKEST)

	art_rect(art, 40, 42, 14, 8, C_GOLD_DARK)
	art_rect(art, 41, 41, 12, 2, C_GOLD)
	art_line(art, 42, 43, 52, 47, C_GOLD_LIGHT)
	art_line(art, 44, 41, 50, 48, C_GOLD_LIGHT)

	art_rect(art, 40, 32, 14, 5, C_OUTLINE)
	art_rect(art, 41, 33, 12, 3, C_WOOD_DARKEST)
	art_rect(art, 42, 33, 10, 1, C_WATER)

	art_line(art, 54, 54, 44, 30, C_OUTLINE)
	art_line(art, 54, 53, 45, 30, C_WOOD_DARK)
	art_circle(art, 44, 29, 3, C_OUTLINE)
	art_circle(art, 44, 29, 2, C_WOOD)

	art_line(art, 12, 55, 18, 57, C_WHITE)
	art_line(art, 17, 54, 13, 58, C_WHITE)
	draw_flag(art, 58, 1, accent)
}

draw_siege_workshop :: proc(art: ^Art, accent: rl.Color) {
	draw_shadow(art, 32, 45, 28, 3)

	// Main hall, spanning the full 4-tile footprint.
	art_rect(art, 7, 18, 50, 24, C_OUTLINE)
	art_rect(art, 8, 19, 48, 22, C_WOOD_DARK)
	for y := 23; y < 41; y += 5 {
		art_line(art, 8, y, 55, y, C_WOOD_DARKEST)
	}
	art_line(art, 8, 20, 8, 40, C_WOOD_LIGHT)

	roof := [4]Point{{3, 20}, {60, 20}, {51, 6}, {7, 6}}
	art_polygon(art, roof[:], C_OUTLINE)
	roof_inner := [4]Point{{6, 19}, {57, 19}, {49, 8}, {9, 8}}
	art_polygon(art, roof_inner[:], C_ROOF_DARK)
	roof_high := [4]Point{{9, 17}, {54, 17}, {47, 10}, {11, 10}}
	art_polygon(art, roof_high[:], C_ROOF)

	// Open assembly bay with a catapult frame under construction.
	art_rect(art, 12, 26, 30, 15, C_WOOD_DARKEST)
	art_rect(art, 13, 27, 28, 13, C_DIRT_DARK)
	art_rect(art, 16, 36, 18, 3, C_WOOD_DARKEST)
	art_circle(art, 19, 38, 3, C_OUTLINE)
	art_circle(art, 19, 38, 2, C_WOOD_DARKEST)
	art_circle(art, 31, 38, 3, C_OUTLINE)
	art_circle(art, 31, 38, 2, C_WOOD_DARKEST)
	art_line(art, 20, 35, 33, 27, C_OUTLINE)
	art_line(art, 20, 34, 33, 26, C_WOOD)
	art_circle(art, 33, 26, 2, C_IRON_DARK)

	// Stone forge with a glowing furnace mouth.
	art_rect(art, 44, 26, 12, 16, C_OUTLINE)
	art_rect(art, 45, 27, 10, 14, C_STONE_DARK)
	art_rect(art, 46, 30, 8, 7, C_GOLD_DARK)
	art_rect(art, 47, 31, 6, 5, C_GOLD)
	art_rect(art, 48, 32, 4, 3, C_GOLD_LIGHT)
	art_pixel(art, 49, 29, C_GOLD_LIGHT)

	// Chimney and tool rack.
	art_rect(art, 47, 0, 5, 7, C_OUTLINE)
	art_rect(art, 48, 1, 3, 6, C_STONE_DARK)
	art_pixel(art, 48, 2, C_STONE_LIGHT)
	art_line(art, 11, 22, 11, 34, C_WOOD_LIGHT)
	art_rect(art, 9, 22, 5, 2, C_IRON)

	draw_flag(art, 30, 0, accent)
}

draw_turtle_pen :: proc(art: ^Art, accent: rl.Color) {
	draw_shadow(art, 24, 42, 18, 3)
	art_ellipse(art, 24, 28, 19, 13, C_OUTLINE)
	art_ellipse(art, 24, 28, 18, 12, C_WATER_DARK)
	art_ellipse(art, 24, 28, 15, 9, C_WATER)
	art_ellipse(art, 20, 25, 5, 2, C_WATER_LIGHT)
	art_ellipse(art, 30, 32, 6, 2, C_WATER_LIGHT)

	art_ellipse(art, 8, 36, 6, 4, C_OUTLINE)
	art_ellipse(art, 8, 36, 5, 3, C_STONE_DARK)
	art_ellipse(art, 40, 18, 5, 3, C_OUTLINE)
	art_ellipse(art, 40, 18, 4, 2, C_STONE)

	art_ellipse(art, 26, 30, 7, 5, C_OUTLINE)
	art_ellipse(art, 26, 30, 6, 4, C_LEAF_DARK)
	art_ellipse(art, 26, 30, 4, 3, C_LEAF)
	art_line(art, 22, 29, 30, 31, C_LEAF_LIGHT)
	art_line(art, 24, 27, 28, 33, C_LEAF_LIGHT)
	art_circle(art, 34, 32, 2, C_OUTLINE)
	art_circle(art, 34, 32, 1, C_LEAF_LIGHT)
	art_pixel(art, 34, 31, C_OUTLINE)
	art_rect(art, 20, 34, 2, 2, C_LEAF_DARK)
	art_rect(art, 30, 34, 2, 2, C_LEAF_DARK)
	art_rect(art, 24, 27, 4, 2, accent)

	for x := 4; x <= 44; x += 8 {
		art_rect(art, x, 4, 1, 8, C_WOOD_DARK)
	}
	art_line(art, 4, 6, 44, 6, C_WOOD)
	art_line(art, 4, 10, 44, 10, C_WOOD)
	art_circle(art, 12, 22, 3, C_LEAF_DARK)
	art_pixel(art, 12, 22, C_WATER_DARK)
	art_circle(art, 38, 38, 2, C_LEAF)
	draw_flag(art, 44, 0, accent)
}

draw_thieves_guild :: proc(art: ^Art, accent: rl.Color) {
	draw_shadow(art, 16, 45, 13, 3)
	art_rect(art, 6, 16, 20, 28, C_OUTLINE)
	art_rect(art, 7, 17, 18, 26, C_WOOD_DARKEST)
	for y := 21; y < 42; y += 5 {
		art_line(art, 7, y, 24, y, C_OUTLINE)
	}
	roof := [4]Point{{3, 18}, {29, 18}, {25, 5}, {7, 5}}
	art_polygon(art, roof[:], C_OUTLINE)
	roof_inner := [4]Point{{5, 17}, {27, 17}, {24, 6}, {8, 6}}
	art_polygon(art, roof_inner[:], C_CLOTH_DARK)
	roof_high := [4]Point{{8, 15}, {24, 15}, {21, 8}, {11, 8}}
	art_polygon(art, roof_high[:], C_CLOTH)

	art_rect(art, 12, 32, 8, 12, C_OUTLINE)
	art_rect(art, 13, 33, 6, 11, C_WOOD_DARKEST)
	art_rect(art, 14, 35, 4, 1, C_GOLD_DARK)
	draw_window(art, 9, 22, 2, 5, false)
	draw_window(art, 21, 22, 2, 5, false)

	art_line(art, 26, 26, 26, 35, C_OUTLINE)
	art_rect(art, 24, 24, 5, 5, C_OUTLINE)
	art_rect(art, 25, 25, 3, 3, C_GOLD)
	art_rect(art, 26, 26, 1, 1, C_GOLD_LIGHT)

	art_circle(art, 16, 27, 3, C_OUTLINE)
	art_circle(art, 16, 27, 2, C_CLOTH_DARK)
	art_pixel(art, 15, 27, accent)
	art_pixel(art, 17, 27, accent)
	draw_banner(art, 3, 24, 4, 10, accent)
	draw_flag(art, 25, 0, accent)
}

// ---------------------------------------------------------------------------
// Units
// ---------------------------------------------------------------------------

draw_unit_sprite :: proc(kind: UnitKind, accent: rl.Color) -> Art {
	art := art_init(16, 16)
	switch kind {
	case .Villager:
		draw_unit_villager(&art, accent)
	case .Builder:
		draw_unit_builder(&art, accent)
	case .CombatBuilder:
		draw_unit_combat_builder(&art, accent)
	case .WaterCollector:
		draw_unit_water_collector(&art, accent)
	case .Farmer:
		draw_unit_farmer(&art, accent)
	case .Knight:
		draw_unit_knight(&art, accent)
	case .Archer:
		draw_unit_archer(&art, accent)
	case .Mage:
		draw_unit_mage(&art, accent)
	case .Giant:
		draw_unit_giant(&art, accent)
	case .Turtle:
		draw_unit_turtle(&art, accent)
	case .Catapult:
		draw_unit_catapult(&art, accent)
	case .Rogue:
		draw_unit_rogue(&art, accent)
	}
	return art
}

unit_shadow :: proc(art: ^Art) {
	art_ellipse(art, 8, 14, 4, 2, C_SHADOW)
}

draw_unit_villager :: proc(art: ^Art, accent: rl.Color) {
	unit_shadow(art)
	art_rect(art, 5, 11, 6, 4, C_OUTLINE)
	art_rect(art, 6, 11, 1, 3, C_WOOD_DARKEST)
	art_rect(art, 9, 11, 1, 3, C_WOOD_DARKEST)
	art_rect(art, 4, 6, 8, 6, C_OUTLINE)
	art_rect(art, 5, 7, 6, 5, C_CLOTH)
	art_rect(art, 5, 10, 6, 1, C_WOOD_DARKEST)
	art_rect(art, 5, 7, 6, 1, accent)
	art_rect(art, 3, 7, 1, 4, C_OUTLINE)
	art_rect(art, 12, 7, 1, 4, C_OUTLINE)
	art_circle(art, 8, 4, 3, C_OUTLINE)
	art_circle(art, 8, 4, 2, C_SKIN)
	art_rect(art, 6, 2, 4, 2, C_HAIR)
	art_pixel(art, 7, 4, C_OUTLINE)
	art_pixel(art, 9, 4, C_OUTLINE)
	art_rect(art, 11, 8, 2, 3, C_WOOD_DARK)
	art_rect_outline(art, 11, 8, 2, 3, C_OUTLINE)
}

draw_unit_builder :: proc(art: ^Art, accent: rl.Color) {
	unit_shadow(art)
	art_rect(art, 5, 11, 6, 4, C_OUTLINE)
	art_rect(art, 6, 11, 1, 3, C_WOOD_DARKEST)
	art_rect(art, 9, 11, 1, 3, C_WOOD_DARKEST)
	art_rect(art, 4, 6, 8, 6, C_OUTLINE)
	art_rect(art, 5, 7, 6, 5, C_LEAF_DARK)
	art_rect(art, 5, 10, 6, 1, C_WOOD_DARKEST)
	art_rect(art, 5, 7, 6, 1, accent)
	art_rect(art, 3, 7, 1, 4, C_OUTLINE)
	art_rect(art, 12, 7, 1, 4, C_OUTLINE)
	art_circle(art, 8, 4, 3, C_OUTLINE)
	art_circle(art, 8, 4, 2, C_SKIN)
	art_pixel(art, 7, 4, C_OUTLINE)
	art_pixel(art, 9, 4, C_OUTLINE)
	art_rect(art, 5, 2, 6, 2, C_WOOD_DARKEST)
	art_rect(art, 4, 3, 8, 1, C_WOOD_DARK)
	art_line(art, 12, 11, 14, 5, C_OUTLINE)
	art_line(art, 12, 10, 13, 5, C_WOOD_LIGHT)
	art_rect(art, 12, 4, 3, 2, C_OUTLINE)
	art_rect(art, 13, 5, 1, 1, C_IRON)
	art_rect(art, 10, 10, 2, 2, C_WOOD_DARK)
}

draw_unit_combat_builder :: proc(art: ^Art, accent: rl.Color) {
	unit_shadow(art)
	art_rect(art, 5, 11, 6, 4, C_OUTLINE)
	art_rect(art, 6, 11, 1, 3, C_WOOD_DARKEST)
	art_rect(art, 9, 11, 1, 3, C_WOOD_DARKEST)
	art_rect(art, 4, 6, 8, 6, C_OUTLINE)
	art_rect(art, 5, 7, 6, 5, C_IRON_DARK)
	art_rect(art, 5, 10, 6, 1, C_WOOD_DARKEST)
	art_rect(art, 5, 7, 6, 1, accent)
	art_rect(art, 3, 7, 1, 4, C_OUTLINE)
	art_rect(art, 12, 7, 1, 4, C_OUTLINE)

	art_circle(art, 8, 4, 3, C_OUTLINE)
	art_circle(art, 8, 4, 2, C_SKIN)
	art_rect(art, 5, 1, 7, 3, C_OUTLINE)
	art_rect(art, 6, 2, 5, 2, C_IRON)
	art_rect(art, 7, 2, 3, 1, C_IRON_LIGHT)
	art_pixel(art, 7, 4, C_OUTLINE)
	art_pixel(art, 9, 4, C_OUTLINE)

	art_line(art, 12, 12, 14, 4, C_OUTLINE)
	art_line(art, 12, 11, 13, 4, C_WOOD_LIGHT)
	art_rect(art, 12, 3, 4, 4, C_OUTLINE)
	art_rect(art, 13, 4, 2, 2, C_STONE)
	art_rect(art, 10, 10, 2, 2, C_IRON_DARK)
}

draw_unit_water_collector :: proc(art: ^Art, accent: rl.Color) {
	unit_shadow(art)
	art_rect(art, 5, 11, 6, 4, C_OUTLINE)
	art_rect(art, 6, 11, 1, 3, C_WOOD_DARKEST)
	art_rect(art, 9, 11, 1, 3, C_WOOD_DARKEST)
	art_rect(art, 4, 6, 8, 6, C_OUTLINE)
	art_rect(art, 5, 7, 6, 5, C_WATER_DARK)
	art_rect(art, 5, 7, 6, 1, C_WATER_LIGHT)
	art_rect(art, 5, 10, 6, 1, accent)
	art_rect(art, 3, 7, 1, 4, C_OUTLINE)
	art_rect(art, 12, 7, 1, 4, C_OUTLINE)
	art_circle(art, 8, 4, 3, C_OUTLINE)
	art_circle(art, 8, 4, 2, C_SKIN)
	art_rect(art, 5, 2, 6, 2, C_WATER_DARK)
	art_rect(art, 4, 3, 8, 1, C_WATER_LIGHT)
	art_pixel(art, 7, 4, C_OUTLINE)
	art_pixel(art, 9, 4, C_OUTLINE)
	art_rect(art, 11, 10, 3, 4, C_OUTLINE)
	art_rect(art, 12, 11, 1, 2, C_IRON)
	art_line(art, 11, 10, 13, 9, C_IRON_LIGHT)
	art_pixel(art, 13, 9, C_WATER_LIGHT)
}

draw_unit_farmer :: proc(art: ^Art, accent: rl.Color) {
	unit_shadow(art)
	art_rect(art, 5, 11, 6, 4, C_OUTLINE)
	art_rect(art, 6, 11, 1, 3, C_WOOD_DARKEST)
	art_rect(art, 9, 11, 1, 3, C_WOOD_DARKEST)
	art_rect(art, 4, 6, 8, 6, C_OUTLINE)
	art_rect(art, 5, 7, 6, 5, C_LEAF_DARK)
	art_rect(art, 5, 10, 6, 1, C_WOOD_DARKEST)
	art_rect(art, 5, 7, 6, 1, accent)
	art_rect(art, 3, 7, 1, 4, C_OUTLINE)
	art_rect(art, 12, 7, 1, 4, C_OUTLINE)
	art_circle(art, 8, 4, 3, C_OUTLINE)
	art_circle(art, 8, 4, 2, C_SKIN)
	art_pixel(art, 7, 4, C_OUTLINE)
	art_pixel(art, 9, 4, C_OUTLINE)
	art_rect(art, 4, 2, 9, 2, C_OUTLINE)
	art_rect(art, 5, 2, 7, 1, C_GOLD)
	art_rect(art, 6, 0, 5, 2, C_OUTLINE)
	art_rect(art, 7, 0, 3, 1, C_GOLD_LIGHT)
	art_line(art, 12, 12, 14, 4, C_OUTLINE)
	art_line(art, 12, 11, 13, 5, C_WOOD_LIGHT)
	art_rect(art, 13, 4, 2, 1, C_IRON_LIGHT)
	art_line(art, 2, 12, 3, 8, C_GOLD_DARK)
	art_line(art, 3, 12, 4, 8, C_GOLD)
	art_line(art, 4, 12, 5, 8, C_GOLD_LIGHT)
}

draw_unit_knight :: proc(art: ^Art, accent: rl.Color) {
	unit_shadow(art)
	art_rect(art, 5, 11, 6, 4, C_OUTLINE)
	art_rect(art, 6, 11, 1, 3, C_IRON_DARK)
	art_rect(art, 9, 11, 1, 3, C_IRON_DARK)
	art_rect(art, 4, 6, 8, 6, C_OUTLINE)
	art_rect(art, 5, 7, 6, 5, C_IRON_DARK)
	art_rect(art, 5, 7, 6, 1, C_IRON)
	art_rect(art, 5, 10, 6, 1, accent)
	art_rect(art, 3, 7, 1, 4, C_OUTLINE)
	art_rect(art, 12, 7, 1, 4, C_OUTLINE)
	art_circle(art, 8, 4, 3, C_OUTLINE)
	art_circle(art, 8, 4, 2, C_IRON)
	art_rect(art, 6, 4, 4, 1, C_OUTLINE)
	art_pixel(art, 8, 2, C_IRON_LIGHT)
	art_rect(art, 8, 0, 2, 2, accent)
	art_pixel(art, 7, 1, accent)
	art_rect(art, 1, 7, 4, 6, C_OUTLINE)
	art_rect(art, 2, 8, 2, 4, accent)
	art_rect(art, 2, 9, 2, 1, C_GOLD_LIGHT)
	art_line(art, 12, 11, 14, 3, C_OUTLINE)
	art_line(art, 12, 10, 13, 3, C_IRON_LIGHT)
	art_line(art, 11, 11, 13, 11, C_GOLD)
}

draw_unit_archer :: proc(art: ^Art, accent: rl.Color) {
	unit_shadow(art)
	art_rect(art, 5, 11, 6, 4, C_OUTLINE)
	art_rect(art, 6, 11, 1, 3, C_WOOD_DARKEST)
	art_rect(art, 9, 11, 1, 3, C_WOOD_DARKEST)
	art_rect(art, 4, 6, 8, 6, C_OUTLINE)
	art_rect(art, 5, 7, 6, 5, C_LEAF_DARK)
	art_rect(art, 5, 10, 6, 1, C_WOOD_DARKEST)
	art_rect(art, 5, 7, 6, 1, accent)
	art_rect(art, 3, 7, 1, 4, C_OUTLINE)
	art_rect(art, 12, 7, 1, 4, C_OUTLINE)
	art_circle(art, 8, 4, 3, C_OUTLINE)
	art_circle(art, 8, 4, 2, C_SKIN)
	art_rect(art, 5, 2, 6, 2, C_LEAF_DARK)
	art_rect(art, 4, 3, 2, 2, C_LEAF_DARK)
	art_pixel(art, 7, 4, C_OUTLINE)
	art_pixel(art, 9, 4, C_OUTLINE)
	art_rect(art, 10, 6, 2, 5, C_WOOD_DARK)
	art_line(art, 11, 6, 11, 3, C_WOOD_LIGHT)
	art_pixel(art, 10, 3, C_IRON_LIGHT)
	art_pixel(art, 12, 3, C_IRON_LIGHT)
	art_line(art, 12, 3, 14, 5, C_OUTLINE)
	art_line(art, 14, 5, 14, 9, C_OUTLINE)
	art_line(art, 14, 9, 12, 12, C_OUTLINE)
	art_line(art, 13, 4, 13, 10, C_IRON_LIGHT)
	art_line(art, 12, 8, 15, 8, C_WOOD_LIGHT)
	art_pixel(art, 15, 8, C_IRON_LIGHT)
}

draw_unit_mage :: proc(art: ^Art, accent: rl.Color) {
	unit_shadow(art)
	robe_outline := [4]Point{{5, 6}, {11, 6}, {13, 14}, {3, 14}}
	art_polygon(art, robe_outline[:], C_OUTLINE)
	robe := [4]Point{{6, 7}, {10, 7}, {12, 13}, {4, 13}}
	art_polygon(art, robe[:], C_ARCANE_DARK)
	robe_high := [4]Point{{7, 7}, {9, 7}, {10, 12}, {6, 12}}
	art_polygon(art, robe_high[:], C_ARCANE)
	art_line(art, 5, 12, 11, 12, accent)
	art_rect(art, 3, 8, 1, 4, C_OUTLINE)
	art_rect(art, 12, 8, 1, 4, C_OUTLINE)
	art_circle(art, 8, 4, 3, C_OUTLINE)
	art_circle(art, 8, 4, 2, C_SKIN)
	art_rect(art, 6, 5, 4, 2, C_WHITE)
	art_pixel(art, 7, 4, C_OUTLINE)
	art_pixel(art, 9, 4, C_OUTLINE)
	art_rect(art, 4, 2, 9, 2, C_OUTLINE)
	art_rect(art, 5, 2, 7, 1, C_ARCANE_DARK)
	hat := [3]Point{{6, 2}, {10, 2}, {8, 0}}
	art_polygon(art, hat[:], C_ARCANE_DARK)
	art_pixel(art, 8, 1, C_ARCANE_GLOW)
	art_line(art, 13, 13, 13, 4, C_OUTLINE)
	art_line(art, 12, 12, 12, 4, C_WOOD_LIGHT)
	art_circle(art, 13, 3, 2, C_OUTLINE)
	art_circle(art, 13, 3, 1, C_ARCANE_GLOW)
	art_pixel(art, 11, 2, C_ARCANE_GLOW)
}

draw_unit_giant :: proc(art: ^Art, accent: rl.Color) {
	unit_shadow(art)

	art_rect(art, 3, 11, 4, 4, C_OUTLINE)
	art_rect(art, 9, 11, 4, 4, C_OUTLINE)
	art_rect(art, 4, 12, 2, 2, C_SKIN_DARK)
	art_rect(art, 10, 12, 2, 2, C_SKIN_DARK)

	// Bare torso with a fur collar and a faction-coloured loincloth.
	art_rect(art, 3, 4, 10, 8, C_OUTLINE)
	art_rect(art, 4, 4, 8, 7, C_SKIN)
	art_rect(art, 4, 7, 8, 4, C_SKIN_DARK)
	art_rect(art, 3, 4, 10, 2, C_WOOD_DARK)
	art_rect(art, 3, 4, 10, 1, C_WOOD_LIGHT)
	art_rect(art, 4, 9, 8, 2, C_WOOD_DARKEST)
	art_rect(art, 4, 9, 8, 1, accent)

	art_rect(art, 1, 5, 2, 5, C_OUTLINE)
	art_rect(art, 2, 6, 1, 3, C_SKIN)
	art_rect(art, 12, 4, 2, 5, C_OUTLINE)
	art_rect(art, 13, 5, 1, 3, C_SKIN)

	// Club held overhead.
	art_rect(art, 13, 3, 1, 2, C_WOOD_DARK)
	art_circle(art, 13, 2, 2, C_OUTLINE)
	art_circle(art, 13, 2, 1, C_WOOD_LIGHT)

	art_circle(art, 8, 3, 3, C_OUTLINE)
	art_circle(art, 8, 3, 2, C_SKIN)
	art_rect(art, 6, 0, 5, 2, C_HAIR)
	art_pixel(art, 6, 2, C_SKIN_DARK)
	art_pixel(art, 7, 3, C_OUTLINE)
	art_pixel(art, 9, 3, C_OUTLINE)
	art_rect(art, 7, 5, 3, 1, C_HAIR)
}

draw_unit_turtle :: proc(art: ^Art, accent: rl.Color) {
	unit_shadow(art)

	// Flippers and tail.
	art_rect(art, 2, 11, 3, 2, C_OUTLINE)
	art_rect(art, 10, 11, 3, 2, C_OUTLINE)
	art_pixel(art, 2, 12, C_LEAF_LIGHT)
	art_pixel(art, 12, 12, C_LEAF_LIGHT)
	art_rect(art, 3, 5, 2, 2, C_OUTLINE)
	art_pixel(art, 3, 5, C_LEAF)
	art_pixel(art, 0, 9, C_LEAF_DARK)

	// Shell.
	art_ellipse(art, 7, 8, 6, 5, C_OUTLINE)
	art_ellipse(art, 7, 8, 5, 4, C_LEAF_DARK)
	art_ellipse(art, 7, 8, 3, 2, C_LEAF)
	art_line(art, 4, 8, 10, 8, C_LEAF_DARKEST)
	art_line(art, 7, 5, 7, 11, C_LEAF_DARKEST)
	art_pixel(art, 5, 6, C_LEAF_LIGHT)
	art_pixel(art, 9, 10, C_LEAF)

	// Harness in the faction colour.
	art_rect(art, 5, 7, 4, 2, accent)

	// Neck and head.
	art_rect(art, 11, 6, 3, 3, C_OUTLINE)
	art_rect(art, 12, 6, 2, 2, C_LEAF_LIGHT)
	art_pixel(art, 13, 6, C_OUTLINE)
	art_pixel(art, 11, 9, C_LEAF_DARK)
}

draw_unit_catapult :: proc(art: ^Art, accent: rl.Color) {
	unit_shadow(art)
	art_rect(art, 2, 11, 12, 3, C_OUTLINE)
	art_rect(art, 3, 12, 10, 2, C_WOOD_DARK)
	art_circle(art, 4, 13, 2, C_OUTLINE)
	art_circle(art, 4, 13, 1, C_WOOD_DARKEST)
	art_circle(art, 12, 13, 2, C_OUTLINE)
	art_circle(art, 12, 13, 1, C_WOOD_DARKEST)
	art_line(art, 5, 11, 7, 6, C_OUTLINE)
	art_line(art, 11, 11, 9, 6, C_OUTLINE)
	art_line(art, 6, 10, 8, 6, C_WOOD_LIGHT)
	art_line(art, 10, 10, 9, 6, C_WOOD_LIGHT)
	art_line(art, 8, 9, 13, 3, C_OUTLINE)
	art_line(art, 8, 8, 12, 3, C_WOOD)
	art_rect(art, 11, 2, 3, 2, C_OUTLINE)
	art_rect(art, 12, 3, 1, 1, C_IRON_DARK)
	art_circle(art, 13, 2, 1, C_STONE)
	art_line(art, 8, 5, 8, 2, C_OUTLINE)
	art_rect(art, 9, 2, 3, 2, accent)
	art_rect_outline(art, 9, 2, 3, 2, C_OUTLINE)
}

draw_unit_rogue :: proc(art: ^Art, accent: rl.Color) {
	unit_shadow(art)
	art_rect(art, 5, 11, 6, 4, C_OUTLINE)
	art_rect(art, 6, 11, 1, 3, C_CLOTH_DARKEST)
	art_rect(art, 9, 11, 1, 3, C_CLOTH_DARKEST)
	cloak := [4]Point{{4, 6}, {12, 6}, {13, 14}, {3, 14}}
	art_polygon(art, cloak[:], C_OUTLINE)
	cloak_inner := [4]Point{{5, 7}, {11, 7}, {12, 13}, {4, 13}}
	art_polygon(art, cloak_inner[:], C_CLOTH_DARKEST)
	art_line(art, 5, 10, 11, 10, accent)
	art_circle(art, 8, 4, 3, C_OUTLINE)
	art_circle(art, 8, 4, 2, C_CLOTH_DARKEST)
	art_rect(art, 6, 4, 4, 2, C_OUTLINE)
	art_pixel(art, 7, 4, accent)
	art_pixel(art, 9, 4, accent)
	art_line(art, 3, 10, 1, 6, C_OUTLINE)
	art_line(art, 3, 9, 2, 6, C_IRON_LIGHT)
	art_line(art, 13, 10, 15, 6, C_OUTLINE)
	art_line(art, 13, 9, 14, 6, C_IRON_LIGHT)
	art_rect(art, 6, 6, 4, 1, accent)
}

// ---------------------------------------------------------------------------
// Sprite set
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Decorations
// ---------------------------------------------------------------------------

draw_decoration_sprite :: proc(kind: DecorationKind) -> Art {
	switch kind {
	case .Tree:
		art := art_init(20, 30)
		draw_decoration_tree(&art)
		return art
	case .Pine:
		art := art_init(20, 34)
		draw_decoration_pine(&art)
		return art
	case .Bush:
		art := art_init(16, 12)
		draw_decoration_bush(&art)
		return art
	case .Rock:
		art := art_init(16, 10)
		draw_decoration_rock(&art)
		return art
	case .Flowers:
		art := art_init(16, 8)
		draw_decoration_flowers(&art)
		return art
	case .Cactus:
		art := art_init(16, 20)
		draw_decoration_cactus(&art)
		return art
	case .Reed:
		art := art_init(16, 14)
		draw_decoration_reed(&art)
		return art
	case .Stump:
		art := art_init(16, 10)
		draw_decoration_stump(&art)
		return art
	case .Lamp:
		art := art_init(16, 28)
		draw_decoration_lamp(&art)
		return art
	}
	return art_init(1, 1)
}

draw_decoration_tree :: proc(art: ^Art) {
	draw_shadow(art, 10, 28, 6, 2)

	art_rect(art, 9, 18, 3, 12, C_OUTLINE)
	art_rect(art, 10, 19, 1, 10, C_WOOD_DARK)
	art_pixel(art, 11, 20, C_WOOD)

	art_circle(art, 10, 10, 8, C_OUTLINE)
	art_circle(art, 5, 15, 5, C_OUTLINE)
	art_circle(art, 15, 15, 5, C_OUTLINE)

	art_circle(art, 10, 10, 7, C_LEAF_DARKEST)
	art_circle(art, 5, 15, 4, C_LEAF_DARKEST)
	art_circle(art, 15, 15, 4, C_LEAF_DARKEST)

	art_circle(art, 8, 9, 6, C_LEAF_DARK)
	art_circle(art, 13, 10, 5, C_LEAF_DARK)
	art_circle(art, 6, 15, 3, C_LEAF_DARK)

	art_circle(art, 8, 8, 4, C_LEAF)
	art_circle(art, 12, 7, 3, C_LEAF)
	art_pixel(art, 6, 5, C_LEAF_LIGHT)
	art_pixel(art, 7, 4, C_LEAF_LIGHT)
	art_pixel(art, 11, 6, C_LEAF_LIGHT)
	art_pixel(art, 15, 13, C_LEAF_LIGHT)
	art_pixel(art, 4, 14, C_LEAF_LIGHT)
}

draw_decoration_pine :: proc(art: ^Art) {
	draw_shadow(art, 10, 32, 6, 2)

	art_rect(art, 9, 25, 3, 9, C_OUTLINE)
	art_rect(art, 10, 26, 1, 8, C_WOOD_DARK)

	art_triangle(art, 10, 13, 0, 27, 20, 27, C_OUTLINE)
	art_triangle(art, 10, 15, 2, 27, 18, 27, C_LEAF_DARKEST)
	art_triangle(art, 10, 7, 1, 21, 19, 21, C_OUTLINE)
	art_triangle(art, 10, 9, 3, 21, 17, 21, C_LEAF_DARKEST)
	art_triangle(art, 10, 1, 4, 13, 16, 13, C_OUTLINE)
	art_triangle(art, 10, 3, 5, 13, 15, 13, C_LEAF_DARK)

	art_line(art, 10, 4, 10, 12, C_LEAF)
	art_line(art, 10, 10, 10, 20, C_LEAF_DARK)
	art_pixel(art, 9, 7, C_LEAF_LIGHT)
	art_pixel(art, 9, 14, C_LEAF)
	art_pixel(art, 13, 19, C_LEAF_DARKEST)
	art_pixel(art, 9, 22, C_LEAF_DARKEST)
}

draw_decoration_bush :: proc(art: ^Art) {
	draw_shadow(art, 8, 10, 4, 1)

	art_circle(art, 4, 8, 4, C_OUTLINE)
	art_circle(art, 11, 8, 4, C_OUTLINE)
	art_circle(art, 8, 5, 4, C_OUTLINE)
	art_circle(art, 4, 8, 3, C_LEAF_DARKEST)
	art_circle(art, 11, 8, 3, C_LEAF_DARKEST)
	art_circle(art, 8, 5, 3, C_LEAF_DARKEST)
	art_circle(art, 5, 7, 2, C_LEAF_DARK)
	art_circle(art, 10, 7, 2, C_LEAF_DARK)
	art_circle(art, 8, 5, 2, C_LEAF)
	art_pixel(art, 7, 4, C_LEAF_LIGHT)
}

draw_decoration_rock :: proc(art: ^Art) {
	draw_shadow(art, 8, 8, 5, 1)

	outline := [6]Point{{2, 8}, {4, 3}, {11, 2}, {14, 6}, {12, 8}, {3, 8}}
	art_polygon(art, outline[:], C_OUTLINE)
	fill := [5]Point{{3, 7}, {5, 4}, {10, 3}, {13, 6}, {11, 7}}
	art_polygon(art, fill[:], C_STONE_DARK)
	art_rect(art, 5, 4, 5, 1, C_STONE)
	art_pixel(art, 11, 4, C_STONE_LIGHT)
	art_pixel(art, 4, 7, C_STONE_DARKEST)
}

draw_decoration_flowers :: proc(art: ^Art) {
	positions := [6][2]int{{2, 5}, {5, 3}, {8, 6}, {11, 3}, {13, 5}, {14, 6}}
	colors := [6]rl.Color{C_WHITE, C_GOLD_LIGHT, C_ROOF_LIGHT, C_ARCANE_LIGHT, C_WHITE, C_GOLD_LIGHT}
	for position, index in positions {
		x := position[0]
		y := position[1]
		draw_flower(art, x, y, colors[index])
	}
}

draw_flower :: proc(art: ^Art, x, y: int, color: rl.Color) {
	art_rect(art, x, y+1, 1, 2, C_LEAF_DARK)
	art_pixel(art, x-1, y, color)
	art_pixel(art, x+1, y, color)
	art_pixel(art, x, y-1, color)
	art_pixel(art, x, y+1, color)
	art_pixel(art, x, y, C_GOLD_LIGHT)
}

draw_decoration_cactus :: proc(art: ^Art) {
	draw_shadow(art, 8, 18, 4, 2)

	art_rect(art, 1, 9, 5, 3, C_OUTLINE)
	art_rect(art, 2, 10, 4, 1, C_LEAF_DARK)
	art_rect(art, 1, 6, 3, 4, C_OUTLINE)
	art_rect(art, 2, 7, 1, 3, C_LEAF_DARK)

	art_rect(art, 10, 6, 5, 3, C_OUTLINE)
	art_rect(art, 10, 7, 4, 1, C_LEAF_DARK)
	art_rect(art, 12, 3, 3, 4, C_OUTLINE)
	art_rect(art, 13, 4, 1, 3, C_LEAF_DARK)

	art_rect(art, 6, 2, 5, 17, C_OUTLINE)
	art_rect(art, 7, 3, 3, 15, C_LEAF_DARK)
	art_rect(art, 8, 4, 1, 13, C_LEAF)
	art_pixel(art, 7, 5, C_LEAF_LIGHT)
	art_pixel(art, 7, 11, C_LEAF_LIGHT)
	art_pixel(art, 9, 8, C_LEAF_LIGHT)
}

draw_decoration_reed :: proc(art: ^Art) {
	draw_shadow(art, 8, 12, 4, 1)

	art_line(art, 3, 12, 2, 5, C_LEAF_DARK)
	art_rect(art, 2, 3, 1, 2, C_WOOD_DARK)
	art_line(art, 6, 12, 6, 4, C_LEAF_DARK)
	art_rect(art, 6, 2, 1, 2, C_WOOD)
	art_line(art, 9, 12, 10, 6, C_LEAF_DARK)
	art_rect(art, 10, 4, 1, 2, C_WOOD_DARK)
	art_line(art, 12, 12, 13, 7, C_LEAF_DARK)
	art_rect(art, 13, 5, 1, 2, C_WOOD)
	art_pixel(art, 6, 6, C_LEAF_LIGHT)
}

draw_decoration_stump :: proc(art: ^Art) {
	draw_shadow(art, 8, 8, 5, 1)

	art_ellipse(art, 8, 6, 5, 3, C_OUTLINE)
	art_ellipse(art, 8, 6, 4, 2, C_WOOD_DARK)
	art_ellipse(art, 8, 6, 2, 1, C_WOOD)
	art_pixel(art, 7, 6, C_WOOD_LIGHT)
	art_rect(art, 4, 8, 2, 1, C_WOOD_DARKEST)
	art_rect(art, 11, 8, 2, 1, C_WOOD_DARKEST)
}

draw_decoration_lamp :: proc(art: ^Art) {
	draw_shadow(art, 8, 26, 4, 1)

	art_rect(art, 7, 10, 3, 16, C_OUTLINE)
	art_rect(art, 8, 11, 1, 14, C_IRON_DARK)
	art_rect(art, 6, 24, 5, 2, C_OUTLINE)
	art_rect(art, 7, 25, 3, 1, C_IRON)

	art_rect(art, 5, 4, 7, 7, C_OUTLINE)
	art_rect(art, 6, 5, 5, 5, C_GOLD_DARK)
	art_rect(art, 7, 6, 3, 3, C_GOLD_LIGHT)
	art_pixel(art, 8, 7, C_WHITE)

	art_rect(art, 4, 2, 9, 2, C_OUTLINE)
	art_rect(art, 5, 3, 7, 1, C_IRON)
	art_pixel(art, 8, 0, C_IRON_LIGHT)
	art_pixel(art, 8, 1, C_IRON)
}

SpriteSet :: struct {
	building:     [SPRITE_FACTION_COUNT][BuildingKind]rl.Texture2D,
	unit:         [SPRITE_FACTION_COUNT][UnitKind]rl.Texture2D,
	decoration:   [DecorationKind]rl.Texture2D,
	construction: [SPRITE_FACTION_COUNT]rl.Texture2D,
	fire:         rl.Texture2D,
	shadow:       rl.Texture2D,
	glow:         rl.Texture2D,
}

SpriteSetInit :: proc() -> SpriteSet {
	set: SpriteSet
	set.shadow = create_shadow_texture()
	set.glow = create_glow_texture()
	for faction in 0 ..< SPRITE_FACTION_COUNT {
		accent := FactionColor(faction)
		for kind in ALL_BUILDING_KINDS {
			art := draw_building_sprite(kind, accent)
			art_grain(&art, u64(kind)+1)
			set.building[faction][kind] = art_to_texture(art)
			rl.UnloadImage(art.image)
		}
		for kind in ALL_UNIT_KINDS {
			art := draw_unit_sprite(kind, accent)
			set.unit[faction][kind] = art_to_texture(art)
			rl.UnloadImage(art.image)
		}
		art := draw_construction_sprite(accent)
		art_grain(&art, u64(faction)+701)
		set.construction[faction] = art_to_texture(art)
		rl.UnloadImage(art.image)
	}
	for kind in ALL_DECORATION_KINDS {
		art := draw_decoration_sprite(kind)
		art_grain(&art, u64(kind)+301)
		set.decoration[kind] = art_to_texture(art)
		rl.UnloadImage(art.image)
	}
	set.fire = art_to_texture(draw_fire_sprite())
	return set
}

SpriteSetDeinit :: proc(set: ^SpriteSet) {
	if set.shadow.id != 0 do rl.UnloadTexture(set.shadow)
	if set.glow.id != 0 do rl.UnloadTexture(set.glow)
	for faction in 0 ..< SPRITE_FACTION_COUNT {
		for kind in ALL_BUILDING_KINDS {
			if set.building[faction][kind].id != 0 {
				rl.UnloadTexture(set.building[faction][kind])
			}
		}
		for kind in ALL_UNIT_KINDS {
			if set.unit[faction][kind].id != 0 {
				rl.UnloadTexture(set.unit[faction][kind])
			}
		}
		if set.construction[faction].id != 0 {
			rl.UnloadTexture(set.construction[faction])
		}
	}
	for kind in ALL_DECORATION_KINDS {
		if set.decoration[kind].id != 0 {
			rl.UnloadTexture(set.decoration[kind])
		}
	}
	if set.fire.id != 0 do rl.UnloadTexture(set.fire)
}
