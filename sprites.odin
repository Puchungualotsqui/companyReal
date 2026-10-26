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
C_EFFECT_BAD := rl.Color{214, 62, 52, 255}

ALL_BUILDING_KINDS := [18]BuildingKind{
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
	.DistrictHall,
	.GiantMortar,
	.Harbor,
	.Granary,
}

ALL_UNIT_KINDS := [13]UnitKind{
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
	.Explorer,
}

KINGDOM_COLOR_PALETTE := [8]rl.Color {
	rl.Color{74, 126, 204, 255},
	rl.Color{198, 74, 72, 255},
	rl.Color{86, 158, 96, 255},
	rl.Color{150, 104, 196, 255},
	rl.Color{214, 164, 72, 255},
	rl.Color{72, 168, 160, 255},
	rl.Color{212, 116, 64, 255},
	rl.Color{196, 104, 148, 255},
}

SameColor :: proc(a, b: rl.Color) -> bool {
	return a.r == b.r && a.g == b.g && a.b == b.b && a.a == b.a
}

// Assigns the chosen local colour and gives every other kingdom a distinct
// palette colour. Called before sprites are generated so accents match.
AssignKingdomColors :: proc(
	localKingdom: int,
	localColor: rl.Color,
	colors: ^[KINGDOMS_CAPACITY]rl.Color,
) {
	used: [len(KINGDOM_COLOR_PALETTE)]bool

	for kingdom in 0 ..< KINGDOMS_CAPACITY {
		colors[kingdom] = KINGDOM_COLOR_PALETTE[kingdom%len(KINGDOM_COLOR_PALETTE)]
	}

	if localKingdom < 0 || localKingdom >= KINGDOMS_CAPACITY {
		return
	}

	colors[localKingdom] = localColor
	for color, index in KINGDOM_COLOR_PALETTE {
		if SameColor(color, localColor) do used[index] = true
	}

	next := 0
	for kingdom in 0 ..< KINGDOMS_CAPACITY {
		if kingdom == localKingdom do continue
		for next < len(used) && used[next] do next += 1
		if next < len(used) {
			colors[kingdom] = KINGDOM_COLOR_PALETTE[next]
			used[next] = true
			next += 1
		}
	}
}

FactionColor :: proc(w: ^World, faction: int) -> rl.Color {
	if faction >= 0 && faction < KINGDOMS_CAPACITY do return w.kingdomColors[faction]
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
	case .Villager, .Builder, .CombatBuilder, .WaterCollector, .Farmer, .Archer, .Mage, .Explorer:
		return 1
	}
	return 1
}

CShade :: proc(color: rl.Color, factor: f32) -> rl.Color {
	return rl.Color{
		u8(clamp(f32(color[0])*factor, 0.0, 255.0)),
		u8(clamp(f32(color[1])*factor, 0.0, 255.0)),
		u8(clamp(f32(color[2])*factor, 0.0, 255.0)),
		color[3],
	}
}

ArtInit :: proc(width, height: int) -> Art {
	return Art{
		image = rl.GenImageColor(i32(width), i32(height), C_CLEAR),
		width = width,
		height = height,
	}
}

ArtPixel :: proc(art: ^Art, x, y: int, color: rl.Color) {
	if x < 0 || y < 0 || x >= art.width || y >= art.height do return
	rl.ImageDrawPixel(&art.image, i32(x), i32(y), color)
}

ArtCopy :: proc(base: Art) -> Art {
	result := ArtInit(base.width, base.height)
	for y in 0..<base.height {
		for x in 0..<base.width {
			color := rl.GetImageColor(base.image, i32(x), i32(y))
			if color.a != 0 do ArtPixel(&result, x, y, color)
		}
	}
	return result
}

ArtRect :: proc(art: ^Art, x, y, width, height: int, color: rl.Color) {
	if width <= 0 || height <= 0 do return
	for py in y ..< y+height {
		for px in x ..< x+width {
			ArtPixel(art, px, py, color)
		}
	}
}

ArtRectOutline :: proc(art: ^Art, x, y, width, height: int, color: rl.Color) {
	if width <= 0 || height <= 0 do return
	for px in x ..< x+width {
		ArtPixel(art, px, y, color)
		ArtPixel(art, px, y+height-1, color)
	}
	for py in y ..< y+height {
		ArtPixel(art, x, py, color)
		ArtPixel(art, x+width-1, py, color)
	}
}

ArtLine :: proc(art: ^Art, x0, y0, x1, y1: int, color: rl.Color) {
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
		ArtPixel(art, x, y, color)
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

ArtEllipse :: proc(art: ^Art, cx, cy, rx, ry: int, color: rl.Color) {
	if rx <= 0 || ry <= 0 do return
	for y in -ry ..= ry {
		for x in -rx ..= rx {
			if x*x*ry*ry+y*y*rx*rx <= rx*rx*ry*ry {
				ArtPixel(art, cx+x, cy+y, color)
			}
		}
	}
}

ArtCircle :: proc(art: ^Art, cx, cy, radius: int, color: rl.Color) {
	ArtEllipse(art, cx, cy, radius, radius, color)
}

ArtPolygon :: proc(art: ^Art, points: []Point, color: rl.Color) {
	if len(points) < 3 do return
	minY := points[0][1]
	maxY := points[0][1]
	for point in points {
		minY = min(minY, point[1])
		maxY = max(maxY, point[1])
	}
	intersections: [64]f32
	for y in minY ..= maxY {
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
				ArtPixel(art, x, y, color)
			}
		}
	}
}

ArtTriangle :: proc(art: ^Art, x0, y0, x1, y1, x2, y2: int, color: rl.Color) {
	points := [3]Point{{x0, y0}, {x1, y1}, {x2, y2}}
	ArtPolygon(art, points[:], color)
}

ArtToTexture :: proc(art: Art) -> rl.Texture2D {
	texture := rl.LoadTextureFromImage(art.image)
	rl.SetTextureFilter(texture, .POINT)
	return texture
}

// Sparse weathering so large flat surfaces (stone, timber, roof shingles) pick up
// the same grain as the ground instead of reading as clean vector shapes.
ArtGrain :: proc(art: ^Art, seed: u64) {
	for y in 0..<art.height {
		for x in 0..<art.width {
			color := rl.GetImageColor(art.image, i32(x), i32(y))
			if color[3] < 200 do continue
			value := WorldNoiseHash(x, y, seed)
			if value > 0.08 do continue
			factor: f32 = 0.9
			if WorldNoiseHash(y, x, seed+1) < 0.5 do factor = 1.1
			if y > art.height-art.height/6 && WorldNoiseHash(x, y, seed+2) < 0.35 do factor = 0.84
			ArtPixel(art, x, y, CShade(color, factor))
		}
	}
}

CreateBoatTexture :: proc() -> rl.Texture2D {
	art := ArtInit(24, 12)
	ArtRect(&art, 1, 6, 22, 4, C_OUTLINE)
	ArtRect(&art, 2, 7, 20, 2, C_WOOD)
	ArtRect(&art, 4, 3, 2, 4, C_OUTLINE)
	ArtRect(&art, 5, 3, 1, 3, C_WOOD_LIGHT)
	ArtRect(&art, 6, 4, 9, 2, C_WOOD_LIGHT)
	ArtRect(&art, 7, 5, 7, 1, C_WOOD)
	ArtRect(&art, 2, 5, 20, 1, C_WOOD_DARK)
	ArtPixel(&art, 11, 2, C_WHITE)
	texture := ArtToTexture(art)
	rl.UnloadImage(art.image)
	return texture
}

CreateShadowTexture :: proc() -> rl.Texture2D {
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

CreateGlowTexture :: proc() -> rl.Texture2D {
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
	case .TownHall, .Home, .ArcheryRange, .MagicSchool, .GiantPen, .SiegeWorkshop, .ThievesGuild, .Watchtower, .DistrictHall:
		return true
	case .Farmland, .Wall, .Bridge, .Cannon, .TurtlePen, .Path, .GiantMortar, .Harbor:
		return false
	case .Granary:
		return true
	}
	unreachable()
}

DrawShadow :: proc(art: ^Art, cx, cy, rx, ry: int) {
	ArtEllipse(art, cx, cy, rx, ry, C_SHADOW)
}

DrawStoneSeams :: proc(art: ^Art, x, y, width, height, step: int, color: rl.Color) {
	for px := x+step; px < x+width; px += step {
		ArtLine(art, px, y, px, y+height-1, color)
	}
	for py := y+step; py < y+height; py += step {
		ArtLine(art, x, py, x+width-1, py, color)
	}
}

DrawWindow :: proc(art: ^Art, x, y, width, height: int, lit: bool) {
	ArtRect(art, x, y, width, height, C_OUTLINE)
	fill := C_STONE_DARKEST
	if lit do fill = C_GOLD_LIGHT
	ArtRect(art, x+1, y+1, width-2, height-2, fill)
	if width > 3 && height > 3 {
		ArtLine(art, x+width/2, y+1, x+width/2, y+height-2, C_OUTLINE)
		ArtLine(art, x+1, y+height/2, x+width-2, y+height/2, C_OUTLINE)
	}
}

DrawBanner :: proc(art: ^Art, x, y, width, height: int, accent: rl.Color) {
	ArtRect(art, x, y, width, height, C_OUTLINE)
	ArtRect(art, x+1, y+1, width-2, height-2, CShade(accent, 0.9))
	ArtRect(art, x+1, y+1, width-2, 1, CShade(accent, 1.25))
	if width >= 4 && height >= 6 {
		ArtRect(art, x+width/2-1, y+height/2-1, 2, 2, C_GOLD_LIGHT)
	}
}

DrawFlag :: proc(art: ^Art, x, y: int, accent: rl.Color) {
	ArtLine(art, x, y, x, y+6, C_OUTLINE)
	ArtRect(art, x+1, y, 4, 3, accent)
	ArtRectOutline(art, x+1, y, 4, 3, C_OUTLINE)
	ArtPixel(art, x+2, y+1, CShade(accent, 1.3))
}

// ---------------------------------------------------------------------------
// Buildings
// ---------------------------------------------------------------------------

DrawBuildingSprite :: proc(kind: BuildingKind, accent: rl.Color) -> Art {
	width, height := BuildingTileSize(BuildingTypeFromKind(kind))
	art := ArtInit(width*PIXELS_PER_TILE, height*PIXELS_PER_TILE)
	switch kind {
	case .TownHall:
		DrawTownHall(&art, accent)
	case .Home:
		DrawHome(&art, accent)
	case .Farmland:
		DrawFarmland(&art, accent)
	case .Wall:
		DrawWall(&art, accent)
	case .Bridge:
		DrawBridge(&art, accent)
	case .Cannon:
		DrawCannon(&art, accent)
	case .Watchtower:
		DrawWatchtower(&art, accent)
	case .ArcheryRange:
		DrawArcheryRange(&art, accent)
	case .MagicSchool:
		DrawMagicSchool(&art, accent)
	case .GiantPen:
		DrawGiantPen(&art, accent)
	case .SiegeWorkshop:
		DrawSiegeWorkshop(&art, accent)
	case .TurtlePen:
		DrawTurtlePen(&art, accent)
	case .ThievesGuild:
		DrawThievesGuild(&art, accent)
	case .Path:
		DrawPath(&art, accent)
	case .DistrictHall:
		DrawDistrictHall(&art, accent)
	case .GiantMortar:
		DrawGiantMortar(&art, accent)
	case .Harbor:
		DrawHarbor(&art, accent)
	case .Granary:
		DrawGranary(&art, accent)
	}
	return art
}

BuildingArtEdgePixel :: proc(art: Art, x, y: int) -> bool {
	if x < 0 || y < 0 || x >= art.width || y >= art.height do return false
	if rl.GetImageColor(art.image, i32(x), i32(y)).a < 200 do return false
	neighbours := [4]Point{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
	for offset in neighbours {
		nx := x+offset[0]
		ny := y+offset[1]
		if nx < 0 || ny < 0 || nx >= art.width || ny >= art.height do return true
		if rl.GetImageColor(art.image, i32(nx), i32(ny)).a == 0 do return true
	}
	return false
}

// Battle damage is layered on the base art: cracks first, then scorch marks,
// dark holes and chipped edges as severity grows.
DamageBuildingArt :: proc(base: Art, severity: int, seed: u64) -> Art {
	art := ArtCopy(base)
	size := max(base.width, base.height)
	stageSeed := seed+u64(severity)*0x9E3779B97F4A7C15

	crackCount := 1+severity+size/32
	for crack in 0..<crackCount {
		x: int
		y: int
		solid := false
		for attempt in 0..<6 {
			x = int(WorldNoiseHash(crack, attempt, stageSeed+0xB001)*f32(base.width))
			y = int(WorldNoiseHash(attempt, crack, stageSeed+0xB002)*f32(base.height))
			if x < 0 || y < 0 || x >= base.width || y >= base.height do continue
			if rl.GetImageColor(art.image, i32(x), i32(y)).a < 200 do continue
			solid = true
			break
		}
		if !solid do continue
		length := 3+severity*2+size/16
		lean := 1
		if WorldNoiseHash(crack, size, stageSeed+0xB003) < 0.5 do lean = -1
		for step in 0..<length {
			if x < 0 || y < 0 || x >= base.width || y >= base.height do break
			color := rl.GetImageColor(art.image, i32(x), i32(y))
			if color.a < 200 do break
			ArtPixel(&art, x, y, CShade(color, 0.32))
			roll := WorldNoiseHash(step, crack, stageSeed+0xB004)
			if roll < 0.45 do x += lean
			else if roll < 0.7 do x -= lean
			y += 1
		}
	}

	scorchCount := 1+severity+size/32
	scorchRadius := 1+severity/2+size/32
	for scorch in 0..<scorchCount {
		centerX: int
		centerY: int
		solid := false
		for attempt in 0..<6 {
			centerX = int(WorldNoiseHash(scorch, attempt, stageSeed+0xB101)*f32(base.width))
			centerY = int(WorldNoiseHash(attempt, scorch, stageSeed+0xB102)*f32(base.height))
			if centerX < 0 || centerY < 0 || centerX >= base.width || centerY >= base.height {
				continue
			}
			if rl.GetImageColor(art.image, i32(centerX), i32(centerY)).a < 200 do continue
			solid = true
			break
		}
		if !solid do continue
		for dy := -scorchRadius; dy <= scorchRadius; dy += 1 {
			for dx := -scorchRadius; dx <= scorchRadius; dx += 1 {
				if dx*dx+dy*dy > scorchRadius*scorchRadius do continue
				px := centerX+dx
				py := centerY+dy
				if px < 0 || py < 0 || px >= base.width || py >= base.height do continue
				color := rl.GetImageColor(art.image, i32(px), i32(py))
				if color.a < 200 do continue
				if WorldNoiseHash(px, py, stageSeed+0xB103) < 0.22 do continue
				ArtPixel(&art, px, py, CShade(color, 0.60))
			}
		}
	}

	if severity >= 2 {
		holeCount := 1+size/32
		holeRadius := 1+size/48
		for hole in 0..<holeCount {
			centerX: int
			centerY: int
			solid := false
			for attempt in 0..<6 {
				centerX = int(WorldNoiseHash(hole, attempt, stageSeed+0xB201)*f32(base.width))
				centerY = int(WorldNoiseHash(attempt, hole, stageSeed+0xB202)*f32(base.height))
				if centerX < 0 || centerY < 0 || centerX >= base.width ||
					centerY >= base.height {
					continue
				}
				if rl.GetImageColor(art.image, i32(centerX), i32(centerY)).a < 200 {
					continue
				}
				solid = true
				break
			}
			if !solid do continue
			for dy := -holeRadius; dy <= holeRadius; dy += 1 {
				for dx := -holeRadius; dx <= holeRadius; dx += 1 {
					if dx*dx+dy*dy > holeRadius*holeRadius do continue
					if WorldNoiseHash(centerX+dx, centerY+dy, stageSeed+0xB203) < 0.25 {
						continue
					}
					px := centerX+dx
					py := centerY+dy
					if px < 0 || py < 0 || px >= base.width || py >= base.height {
						continue
					}
					color := rl.GetImageColor(art.image, i32(px), i32(py))
					if color.a < 200 do continue
					ArtPixel(&art, px, py, C_OUTLINE)
				}
			}
		}
	}

	chipCount := severity*(1+size/48)
	for chip in 0..<chipCount {
		px := int(WorldNoiseHash(chip, 7, stageSeed+0xB301)*f32(base.width))
		py := int(WorldNoiseHash(chip, 8, stageSeed+0xB302)*f32(base.height))
		if !BuildingArtEdgePixel(art, px, py) do continue
		ArtPixel(&art, px, py, C_CLEAR)
		if WorldNoiseHash(chip, 9, stageSeed+0xB303) < 0.5 do ArtPixel(&art, px+1, py, C_CLEAR)
	}
	return art
}

DrawPath :: proc(art: ^Art, accent: rl.Color) {
	worn := CShade(C_DIRT, 1.12)
	ArtRect(art, 0, 0, PIXELS_PER_TILE, PIXELS_PER_TILE, C_DIRT)
	ArtRect(art, 0, 5, PIXELS_PER_TILE, 6, worn)
	ArtRect(art, 5, 0, 6, PIXELS_PER_TILE, worn)

	for i in 0..<30 {
		x := int(WorldNoiseHash(i, 11, 0xB01)*PIXELS_PER_TILE)
		y := int(WorldNoiseHash(11, i, 0xB02)*PIXELS_PER_TILE)
		color := C_DIRT_DARK
		if WorldNoiseHash(x, y, 0xB03) < 0.35 do color = C_WOOD_LIGHT
		ArtPixel(art, x, y, color)
	}
	for i in 0..<5 {
		x := 1+int(WorldNoiseHash(i, 17, 0xB04)*13)
		y := 1+int(WorldNoiseHash(17, i, 0xB05)*13)
		ArtRect(art, x, y, 2, 1, C_STONE_DARK)
		ArtPixel(art, x, y, C_STONE)
	}

	// Ragged rim so the road blends into grass instead of reading as a slab.
	for i in 0..<PIXELS_PER_TILE {
		if WorldNoiseHash(i, 0, 0xB11) < 0.6 do ArtPixel(art, i, 0, C_CLEAR)
		if WorldNoiseHash(i, 1, 0xB12) < 0.6 do ArtPixel(art, i, PIXELS_PER_TILE-1, C_CLEAR)
		if WorldNoiseHash(2, i, 0xB13) < 0.6 do ArtPixel(art, 0, i, C_CLEAR)
		if WorldNoiseHash(3, i, 0xB14) < 0.6 do ArtPixel(art, PIXELS_PER_TILE-1, i, C_CLEAR)
	}
	ArtPixel(art, 13, 2, accent)
}

// Scaffolding laid over the footprint while a building is under construction.
DrawConstructionSprite :: proc(accent: rl.Color) -> Art {
	art := ArtInit(PIXELS_PER_TILE, PIXELS_PER_TILE)
	ArtRect(&art, 0, 0, PIXELS_PER_TILE, PIXELS_PER_TILE, C_DIRT_DARK)

	for i in 0..<18 {
		x := int(WorldNoiseHash(i, 23, 0xC01)*PIXELS_PER_TILE)
		y := int(WorldNoiseHash(23, i, 0xC02)*PIXELS_PER_TILE)
		color := C_DIRT
		if WorldNoiseHash(x, y, 0xC03) < 0.4 do color = C_WOOD_DARKEST
		ArtPixel(&art, x, y, color)
	}

	ArtRect(&art, 0, 6, PIXELS_PER_TILE, 4, C_OUTLINE)
	ArtRect(&art, 0, 7, PIXELS_PER_TILE, 2, C_WOOD_DARK)
	ArtRect(&art, 6, 0, 4, PIXELS_PER_TILE, C_OUTLINE)
	ArtRect(&art, 7, 0, 2, PIXELS_PER_TILE, C_WOOD_DARK)

	ArtRect(&art, 1, 1, 3, 3, C_OUTLINE)
	ArtRect(&art, 2, 2, 1, 1, C_WOOD_LIGHT)
	ArtRect(&art, 12, 12, 3, 3, C_OUTLINE)
	ArtRect(&art, 13, 13, 1, 1, C_WOOD_LIGHT)

	ArtPixel(&art, 8, 8, accent)
	return art
}

DrawFireSprite :: proc() -> Art {
	art := ArtInit(PIXELS_PER_TILE, PIXELS_PER_TILE)
	ArtEllipse(&art, 8, 11, 5, 4, C_ROOF)
	ArtTriangle(&art, 8, 0, 5, 9, 11, 9, C_ROOF)
	ArtEllipse(&art, 8, 11, 4, 3, C_GOLD_DARK)
	ArtTriangle(&art, 8, 3, 6, 10, 10, 10, C_GOLD_DARK)
	ArtEllipse(&art, 8, 11, 2, 2, C_GOLD)
	ArtTriangle(&art, 8, 6, 7, 10, 9, 10, C_GOLD)
	ArtPixel(&art, 8, 10, C_GOLD_LIGHT)
	ArtPixel(&art, 8, 8, C_GOLD_LIGHT)
	ArtPixel(&art, 3, 14, C_GOLD_DARK)
	ArtPixel(&art, 12, 14, C_GOLD_DARK)
	return art
}

DrawHome :: proc(art: ^Art, accent: rl.Color) {
	DrawShadow(art, 8, 14, 5, 2)
	ArtRect(art, 3, 7, 10, 7, C_OUTLINE)
	ArtRect(art, 4, 8, 8, 5, C_WOOD_DARK)
	ArtRect(art, 4, 8, 8, 1, C_WOOD)
	ArtLine(art, 4, 12, 11, 12, C_WOOD_DARKEST)

	ArtTriangle(art, 8, 1, 0, 8, 15, 8, C_OUTLINE)
	ArtTriangle(art, 8, 2, 2, 8, 13, 8, C_ROOF)
	ArtTriangle(art, 8, 3, 4, 8, 11, 8, C_ROOF_LIGHT)

	ArtRect(art, 6, 10, 3, 4, C_OUTLINE)
	ArtRect(art, 7, 11, 1, 3, C_WOOD_DARKEST)
	ArtRect(art, 4, 9, 2, 2, C_OUTLINE)
	ArtRect(art, 5, 10, 1, 1, C_GOLD_LIGHT)

	ArtRect(art, 10, 3, 2, 3, C_OUTLINE)
	ArtRect(art, 10, 4, 1, 2, C_STONE_DARK)
	DrawFlag(art, 12, 4, accent)
}

DrawTownHall :: proc(art: ^Art, accent: rl.Color) {
	DrawShadow(art, 32, 61, 26, 3)

	ArtRect(art, 22, 56, 20, 6, C_OUTLINE)
	ArtRect(art, 23, 57, 18, 5, C_STONE_DARK)
	ArtRect(art, 24, 58, 16, 4, C_STONE)

	ArtRect(art, 4, 38, 56, 18, C_OUTLINE)
	ArtRect(art, 5, 39, 54, 16, C_STONE_DARK)
	DrawStoneSeams(art, 5, 39, 54, 16, 8, C_STONE_DARKEST)

	ArtRect(art, 8, 20, 48, 20, C_OUTLINE)
	ArtRect(art, 9, 21, 46, 18, C_STONE)
	ArtRect(art, 9, 21, 46, 2, C_STONE_LIGHT)

	roofOutline := [5]Point{{1, 22}, {62, 22}, {54, 8}, {32, 0}, {10, 8}}
	ArtPolygon(art, roofOutline[:], C_OUTLINE)
	roof := [5]Point{{3, 21}, {60, 21}, {52, 9}, {32, 2}, {12, 9}}
	ArtPolygon(art, roof[:], C_ROOF)
	roofHigh := [5]Point{{6, 19}, {57, 19}, {50, 10}, {32, 4}, {15, 10}}
	ArtPolygon(art, roofHigh[:], C_ROOF_LIGHT)
	for y := 12; y < 21; y += 3 {
		ArtLine(art, 9, y, 54, y, C_ROOF_DARK)
	}

	ArtRect(art, 25, 8, 14, 18, C_OUTLINE)
	ArtRect(art, 26, 9, 12, 16, C_STONE_LIGHT)
	DrawStoneSeams(art, 26, 9, 12, 16, 4, C_STONE)
	ArtTriangle(art, 32, 0, 23, 10, 41, 10, C_OUTLINE)
	ArtTriangle(art, 32, 1, 25, 9, 39, 9, C_ROOF)

	ArtRect(art, 29, 13, 6, 8, C_OUTLINE)
	ArtRect(art, 30, 14, 4, 6, C_WATER_DARK)
	ArtRect(art, 31, 15, 1, 2, C_GOLD_LIGHT)

	ArtRect(art, 25, 44, 14, 16, C_OUTLINE)
	ArtRect(art, 26, 45, 12, 15, C_WOOD_DARKEST)
	ArtRect(art, 27, 47, 10, 13, C_WOOD_DARK)
	ArtLine(art, 32, 46, 32, 59, C_WOOD_DARKEST)
	ArtPixel(art, 30, 52, C_GOLD)
	ArtPixel(art, 34, 52, C_GOLD)

	DrawWindow(art, 12, 28, 6, 9, true)
	DrawWindow(art, 46, 28, 6, 9, true)
	DrawWindow(art, 12, 44, 5, 7, true)
	DrawWindow(art, 47, 44, 5, 7, true)

	DrawBanner(art, 7, 26, 7, 18, accent)
	DrawBanner(art, 50, 26, 7, 18, accent)
	DrawFlag(art, 32, 1, accent)

	ArtRect(art, 21, 52, 2, 5, C_WOOD_DARKEST)
	ArtRect(art, 41, 52, 2, 5, C_WOOD_DARKEST)
	ArtPixel(art, 22, 51, C_GOLD_LIGHT)
	ArtPixel(art, 42, 51, C_GOLD_LIGHT)
}

// Independent towns use a humbler timber longhouse with a thatched roof and a
// market front, so they read as settlements rather than royal halls.
DrawIndependentTownHall :: proc(art: ^Art, accent: rl.Color) {
	DrawShadow(art, 32, 61, 27, 3)

	ArtRect(art, 9, 54, 46, 7, C_OUTLINE)
	ArtRect(art, 10, 55, 44, 5, C_STONE_DARK)
	ArtRect(art, 11, 56, 42, 3, C_STONE)

	ArtRect(art, 9, 30, 46, 25, C_OUTLINE)
	ArtRect(art, 10, 31, 44, 23, C_WOOD_DARK)
	ArtRect(art, 10, 31, 44, 2, C_WOOD)
	for y := 36; y < 54; y += 5 {
		ArtLine(art, 11, y, 53, y, C_WOOD_DARKEST)
	}
	for x in ([5]int{13, 24, 37, 48, 52}) {
		ArtRect(art, x, 31, 2, 23, C_WOOD_DARKEST)
	}

	roofOutline := [5]Point{{4, 32}, {60, 32}, {52, 15}, {32, 2}, {12, 15}}
	ArtPolygon(art, roofOutline[:], C_OUTLINE)
	roof := [5]Point{{6, 31}, {58, 31}, {50, 16}, {32, 4}, {14, 16}}
	ArtPolygon(art, roof[:], C_GOLD_DARK)
	roofHigh := [5]Point{{9, 29}, {55, 29}, {48, 17}, {32, 7}, {17, 17}}
	ArtPolygon(art, roofHigh[:], C_GOLD)
	for y := 12; y < 30; y += 4 {
		ArtLine(art, 10, y, 54, y, C_WOOD_DARKEST)
	}
	ArtLine(art, 18, 15, 46, 15, C_WOOD_DARKEST)

	ArtRect(art, 44, 9, 8, 15, C_OUTLINE)
	ArtRect(art, 45, 10, 6, 13, C_STONE_DARK)
	ArtRect(art, 45, 10, 6, 2, C_STONE_LIGHT)
	ArtPixel(art, 48, 7, C_STONE_LIGHT)
	ArtPixel(art, 50, 5, C_STONE)
	ArtPixel(art, 47, 4, C_STONE_DARK)

	ArtRect(art, 27, 39, 10, 16, C_OUTLINE)
	ArtRect(art, 28, 40, 8, 15, C_WOOD_DARKEST)
	ArtRect(art, 29, 41, 6, 14, C_WOOD)
	ArtLine(art, 32, 41, 32, 54, C_WOOD_DARKEST)
	ArtPixel(art, 30, 48, C_GOLD)
	ArtPixel(art, 34, 48, C_GOLD)

	DrawWindow(art, 14, 38, 6, 7, true)
	DrawWindow(art, 43, 38, 6, 7, true)

	ArtRect(art, 4, 38, 2, 19, C_OUTLINE)
	ArtRect(art, 5, 39, 1, 17, C_WOOD_DARK)
	ArtRect(art, 1, 40, 12, 8, C_OUTLINE)
	ArtRect(art, 2, 41, 10, 6, accent)
	ArtRect(art, 4, 43, 6, 1, C_WOOD_DARKEST)
	ArtRect(art, 4, 45, 4, 1, C_WOOD_DARKEST)

	ArtRect(art, 45, 50, 11, 5, C_OUTLINE)
	ArtRect(art, 46, 51, 9, 3, C_WOOD_DARK)
	ArtRect(art, 46, 49, 9, 2, accent)
	ArtRect(art, 48, 51, 2, 3, C_WOOD_LIGHT)
	ArtRect(art, 51, 51, 2, 3, C_GOLD_DARK)

	ArtRect(art, 18, 50, 5, 5, C_OUTLINE)
	ArtRect(art, 19, 51, 3, 3, C_WOOD)
	ArtRect(art, 21, 51, 1, 3, C_WOOD_LIGHT)
	ArtRect(art, 38, 49, 4, 4, C_OUTLINE)
	ArtRect(art, 39, 50, 2, 2, C_WOOD_LIGHT)
}

// A smaller twin-towered hall raised where an absorbed town's hall stood.
// It marks a district of the merged town without competing with the main hall.
DrawDistrictHall :: proc(art: ^Art, accent: rl.Color) {
	DrawShadow(art, 32, 61, 28, 3)

	ArtRect(art, 5, 54, 54, 7, C_OUTLINE)
	ArtRect(art, 6, 55, 52, 6, C_STONE_DARK)
	ArtRect(art, 7, 56, 50, 4, C_STONE)

	// Twin towers.
	for towerX in ([2]int{11, 43}) {
		ArtRect(art, towerX, 30, 10, 26, C_OUTLINE)
		ArtRect(art, towerX+1, 31, 8, 24, C_STONE)
		ArtRect(art, towerX+1, 31, 8, 2, C_STONE_LIGHT)
		ArtTriangle(art, towerX+5, 19, towerX, 31, towerX+10, 31, C_OUTLINE)
		ArtTriangle(art, towerX+5, 21, towerX+1, 30, towerX+9, 30, C_ROOF)
		DrawWindow(art, towerX+3, 37, 4, 6, true)
		ArtRect(art, towerX+3, 47, 4, 9, C_WOOD_DARKEST)
	}

	// Central connecting hall.
	ArtRect(art, 20, 38, 24, 18, C_OUTLINE)
	ArtRect(art, 21, 39, 22, 16, C_STONE_LIGHT)
	DrawStoneSeams(art, 21, 39, 22, 16, 5, C_STONE)
	ArtRect(art, 18, 35, 28, 4, C_OUTLINE)
	ArtRect(art, 19, 36, 26, 2, C_ROOF_DARK)

	// Arched gate.
	ArtRect(art, 28, 43, 8, 13, C_OUTLINE)
	ArtRect(art, 29, 44, 6, 12, C_WOOD_DARKEST)
	ArtRect(art, 30, 46, 4, 10, C_WOOD_DARK)
	ArtPixel(art, 33, 51, C_GOLD)

	// District banners and a small flag between the towers.
	DrawBanner(art, 4, 34, 6, 14, accent)
	DrawBanner(art, 54, 34, 6, 14, accent)
	ArtRect(art, 31, 24, 2, 11, C_WOOD_DARKEST)
	DrawFlag(art, 33, 24, accent)

	ArtRect(art, 24, 52, 2, 5, C_WOOD_DARKEST)
	ArtRect(art, 38, 52, 2, 5, C_WOOD_DARKEST)
	ArtPixel(art, 25, 51, C_GOLD_LIGHT)
	ArtPixel(art, 39, 51, C_GOLD_LIGHT)
}

DrawFarmland :: proc(art: ^Art, accent: rl.Color) {
	ArtRect(art, 2, 2, 28, 28, C_OUTLINE)
	ArtRect(art, 3, 3, 26, 26, C_DIRT_DARK)
	ArtRect(art, 4, 4, 24, 24, C_DIRT)
	for y := 7; y < 27; y += 4 {
		ArtRect(art, 4, y, 24, 1, C_DIRT_DARK)
		for x := 5; x < 27; x += 3 {
			ArtRect(art, x, y-1, 1, 2, C_LEAF)
			ArtPixel(art, x, y-2, C_LEAF_LIGHT)
		}
	}
	for x := 2; x <= 29; x += 5 {
		ArtRect(art, x, 1, 1, 4, C_WOOD_DARK)
		ArtRect(art, x, 27, 1, 4, C_WOOD_DARK)
	}
	ArtLine(art, 2, 3, 29, 3, C_WOOD)
	ArtLine(art, 2, 28, 29, 28, C_WOOD)

	ArtLine(art, 25, 20, 25, 12, C_WOOD_DARKEST)
	ArtLine(art, 22, 15, 28, 15, C_WOOD_DARKEST)
	ArtRect(art, 23, 12, 5, 4, accent)
	ArtRect(art, 24, 10, 3, 2, C_GOLD_LIGHT)
	ArtPixel(art, 24, 14, C_OUTLINE)
	ArtPixel(art, 26, 14, C_OUTLINE)
	DrawFlag(art, 3, 0, accent)
}

DrawWall :: proc(art: ^Art, accent: rl.Color) {
	DrawShadow(art, 8, 14, 6, 2)
	ArtRect(art, 1, 5, 14, 10, C_OUTLINE)
	ArtRect(art, 2, 6, 12, 8, C_STONE_DARK)
	DrawStoneSeams(art, 2, 6, 12, 8, 4, C_STONE_DARKEST)

	ArtRect(art, 1, 2, 4, 4, C_OUTLINE)
	ArtRect(art, 2, 3, 2, 3, C_STONE)
	ArtRect(art, 7, 2, 3, 4, C_OUTLINE)
	ArtRect(art, 7, 3, 2, 3, C_STONE)
	ArtRect(art, 12, 2, 3, 4, C_OUTLINE)
	ArtRect(art, 12, 3, 2, 3, C_STONE)

	ArtRect(art, 6, 8, 4, 3, C_OUTLINE)
	ArtRect(art, 7, 9, 2, 1, accent)
	ArtPixel(art, 3, 12, C_LEAF_DARK)
	ArtPixel(art, 11, 11, C_LEAF_DARK)
}

DrawBridge :: proc(art: ^Art, accent: rl.Color) {
	ArtRect(art, 1, 2, 14, 12, C_OUTLINE)
	ArtRect(art, 2, 3, 12, 10, C_WOOD)
	for x := 3; x < 14; x += 3 {
		ArtLine(art, x, 3, x, 12, C_WOOD_DARK)
	}
	ArtLine(art, 2, 2, 13, 2, C_WOOD_DARKEST)
	ArtLine(art, 2, 13, 13, 13, C_WOOD_DARKEST)
	ArtRect(art, 1, 1, 2, 3, C_WOOD_DARKEST)
	ArtRect(art, 13, 1, 2, 3, C_WOOD_DARKEST)
	ArtRect(art, 1, 12, 2, 3, C_WOOD_DARKEST)
	ArtRect(art, 13, 12, 2, 3, C_WOOD_DARKEST)
	DrawFlag(art, 2, 0, accent)
}

DrawCannon :: proc(art: ^Art, accent: rl.Color) {
	DrawShadow(art, 16, 28, 13, 3)
	ArtRect(art, 4, 20, 24, 9, C_OUTLINE)
	ArtRect(art, 5, 21, 22, 7, C_STONE_DARK)
	DrawStoneSeams(art, 5, 21, 22, 7, 5, C_STONE_DARKEST)

	ArtCircle(art, 10, 27, 4, C_OUTLINE)
	ArtCircle(art, 10, 27, 3, C_WOOD_DARKEST)
	ArtCircle(art, 10, 27, 1, C_WOOD)
	ArtCircle(art, 22, 27, 4, C_OUTLINE)
	ArtCircle(art, 22, 27, 3, C_WOOD_DARKEST)
	ArtCircle(art, 22, 27, 1, C_WOOD)

	ArtRect(art, 7, 16, 18, 7, C_OUTLINE)
	ArtRect(art, 8, 17, 16, 5, C_WOOD_DARK)
	ArtRect(art, 8, 10, 17, 6, C_OUTLINE)
	ArtRect(art, 9, 11, 15, 4, C_IRON_DARK)
	ArtRect(art, 9, 11, 15, 1, C_IRON_LIGHT)
	ArtCircle(art, 25, 13, 3, C_OUTLINE)
	ArtCircle(art, 25, 13, 2, C_IRON)
	ArtCircle(art, 25, 13, 1, C_OUTLINE)
	ArtLine(art, 14, 11, 14, 14, C_IRON_LIGHT)
	ArtLine(art, 20, 11, 20, 14, C_IRON_LIGHT)
	ArtRect(art, 11, 12, 6, 2, accent)
	DrawFlag(art, 26, 5, accent)
}

DrawHarbor :: proc(art: ^Art, accent: rl.Color) {
	DrawShadow(art, 16, 28, 14, 3)
	ArtRect(art, 2, 22, 28, 7, C_OUTLINE)
	ArtRect(art, 3, 23, 26, 5, C_WOOD_DARK)
	ArtRect(art, 4, 24, 24, 1, C_WOOD_LIGHT)
	for x in 5..<27 {
		ArtPixel(art, x, 26, accent)
	}
	ArtRect(art, 6, 12, 12, 11, C_OUTLINE)
	ArtRect(art, 7, 13, 10, 9, C_STONE_DARK)
	ArtRect(art, 8, 14, 8, 2, C_STONE)
	ArtRect(art, 20, 8, 3, 15, C_OUTLINE)
	ArtRect(art, 21, 9, 1, 13, C_WOOD_LIGHT)
	ArtRect(art, 24, 10, 4, 5, accent)
	ArtRect(art, 23, 15, 6, 2, C_OUTLINE)
	ArtPixel(art, 25, 12, C_WHITE)
}

DrawGranary :: proc(art: ^Art, accent: rl.Color) {
	DrawShadow(art, 16, 28, 14, 3)
	ArtRect(art, 3, 16, 26, 12, C_OUTLINE)
	ArtRect(art, 4, 17, 24, 10, C_WOOD_DARK)
	ArtRect(art, 5, 18, 22, 2, C_WOOD_LIGHT)
	for y in 20..<27 {
		for x in 5..<27 {
			if (x+y)%4 == 0 do ArtPixel(art, x, y, C_WOOD_DARKEST)
		}
	}
	ArtRect(art, 4, 12, 24, 5, C_OUTLINE)
	ArtRect(art, 5, 13, 22, 3, C_ROOF)
	ArtRect(art, 6, 13, 20, 1, C_ROOF_LIGHT)
	ArtRect(art, 13, 21, 6, 7, C_OUTLINE)
	ArtRect(art, 14, 22, 4, 6, C_WOOD)
	ArtRect(art, 10, 9, 2, 3, C_GOLD)
	ArtRect(art, 20, 9, 2, 3, C_GOLD)
	ArtRect(art, 10, 12, 2, 1, accent)
	ArtRect(art, 20, 12, 2, 1, accent)
}

DrawGiantMortar :: proc(art: ^Art, accent: rl.Color) {
	DrawShadow(art, 24, 42, 20, 4)

	// Stone platform.
	ArtRect(art, 4, 32, 40, 11, C_OUTLINE)
	ArtRect(art, 5, 33, 38, 9, C_STONE_DARK)
	DrawStoneSeams(art, 5, 33, 38, 9, 7, C_STONE_DARKEST)

	// Wheels and iron carriage.
	ArtCircle(art, 13, 40, 6, C_OUTLINE)
	ArtCircle(art, 13, 40, 4, C_WOOD_DARKEST)
	ArtCircle(art, 13, 40, 1, C_WOOD)
	ArtCircle(art, 35, 40, 6, C_OUTLINE)
	ArtCircle(art, 35, 40, 4, C_WOOD_DARKEST)
	ArtCircle(art, 35, 40, 1, C_WOOD)
	ArtRect(art, 10, 26, 28, 9, C_OUTLINE)
	ArtRect(art, 11, 27, 26, 7, C_IRON_DARK)
	ArtRect(art, 12, 27, 24, 2, C_IRON)

	// Barrel aimed up and to the right.
	ArtLine(art, 20, 29, 35, 10, C_OUTLINE)
	ArtLine(art, 21, 29, 36, 10, C_OUTLINE)
	ArtLine(art, 22, 29, 37, 10, C_OUTLINE)
	ArtLine(art, 23, 29, 38, 10, C_OUTLINE)
	ArtLine(art, 21, 28, 36, 9, C_IRON_DARK)
	ArtLine(art, 22, 28, 37, 9, C_IRON)
	ArtLine(art, 23, 28, 38, 9, C_IRON_LIGHT)
	ArtLine(art, 24, 28, 39, 9, C_IRON_DARK)

	// Muzzle and faction band.
	ArtCircle(art, 39, 9, 4, C_OUTLINE)
	ArtCircle(art, 39, 9, 3, C_IRON_DARK)
	ArtCircle(art, 39, 9, 1, C_OUTLINE)
	ArtRect(art, 27, 19, 7, 3, accent)
	ArtPixel(art, 24, 13, C_IRON_LIGHT)
	ArtPixel(art, 31, 20, C_IRON_LIGHT)

	// Rivets and sight.
	ArtPixel(art, 17, 30, C_IRON_LIGHT)
	ArtPixel(art, 31, 30, C_IRON_LIGHT)
	ArtLine(art, 19, 24, 22, 20, C_IRON_LIGHT)
	ArtRect(art, 20, 18, 3, 2, accent)
}

DrawWatchtower :: proc(art: ^Art, accent: rl.Color) {
	DrawShadow(art, 8, 14, 6, 2)

	ArtRect(art, 2, 4, 12, 11, C_OUTLINE)
	ArtRect(art, 3, 5, 10, 9, C_STONE_DARK)
	DrawStoneSeams(art, 3, 5, 10, 9, 3, C_STONE_DARKEST)

	ArtRect(art, 1, 1, 14, 4, C_OUTLINE)
	ArtRect(art, 2, 2, 12, 2, C_STONE)
	for x in 2..<14 {
		if x%4 == 0 do ArtRect(art, x, 0, 2, 3, C_OUTLINE)
	}

	ArtRect(art, 6, 6, 4, 5, C_OUTLINE)
	ArtRect(art, 7, 7, 2, 3, C_GOLD_LIGHT)
	ArtRect(art, 4, 9, 2, 2, C_OUTLINE)
	ArtRect(art, 5, 10, 1, 1, C_STONE_LIGHT)

	ArtLine(art, 12, 15, 12, 5, C_OUTLINE)
	ArtRect(art, 12, 3, 3, 4, accent)
	ArtRectOutline(art, 12, 3, 3, 4, C_OUTLINE)
	ArtPixel(art, 13, 4, C_GOLD_LIGHT)
}

DrawArcheryRange :: proc(art: ^Art, accent: rl.Color) {
	DrawShadow(art, 24, 45, 20, 3)
	ArtRect(art, 4, 18, 26, 22, C_OUTLINE)
	ArtRect(art, 5, 19, 24, 20, C_WOOD_DARK)
	for y := 22; y < 39; y += 4 {
		ArtLine(art, 5, y, 28, y, C_WOOD_DARKEST)
	}
	roofOutline := [4]Point{{1, 19}, {33, 19}, {28, 7}, {6, 7}}
	ArtPolygon(art, roofOutline[:], C_OUTLINE)
	roof := [4]Point{{3, 18}, {31, 18}, {27, 8}, {7, 8}}
	ArtPolygon(art, roof[:], C_ROOF_DARK)
	roofHigh := [4]Point{{5, 16}, {29, 16}, {26, 9}, {8, 9}}
	ArtPolygon(art, roofHigh[:], C_ROOF)
	ArtRect(art, 12, 26, 8, 14, C_OUTLINE)
	ArtRect(art, 13, 27, 6, 13, C_WOOD_DARKEST)
	ArtPixel(art, 17, 33, C_GOLD)
	DrawWindow(art, 22, 24, 4, 5, true)

	for y := 20; y <= 44; y += 6 {
		ArtRect(art, 33, y, 1, 4, C_WOOD_DARK)
	}
	ArtLine(art, 33, 21, 33, 44, C_WOOD)
	ArtLine(art, 33, 22, 47, 22, C_WOOD)

	ArtCircle(art, 41, 28, 5, C_OUTLINE)
	ArtCircle(art, 41, 28, 4, C_GOLD_LIGHT)
	ArtCircle(art, 41, 28, 3, C_ROOF)
	ArtCircle(art, 41, 28, 2, C_WHITE)
	ArtCircle(art, 41, 28, 1, C_ROOF_DARK)
	ArtCircle(art, 39, 39, 4, C_OUTLINE)
	ArtCircle(art, 39, 39, 3, C_GOLD_LIGHT)
	ArtCircle(art, 39, 39, 2, C_ROOF)
	ArtCircle(art, 39, 39, 1, C_WHITE)
	ArtLine(art, 38, 30, 37, 27, C_WOOD_LIGHT)
	ArtLine(art, 43, 31, 44, 28, C_WOOD_LIGHT)
	DrawFlag(art, 27, 1, accent)
}

DrawMagicSchool :: proc(art: ^Art, accent: rl.Color) {
	DrawShadow(art, 24, 45, 18, 3)
	ArtRect(art, 10, 16, 28, 28, C_OUTLINE)
	ArtRect(art, 11, 17, 26, 26, C_STONE_DARK)
	DrawStoneSeams(art, 11, 17, 26, 26, 6, C_STONE_DARKEST)

	roofOutline := [5]Point{{6, 18}, {42, 18}, {36, 6}, {24, 0}, {12, 6}}
	ArtPolygon(art, roofOutline[:], C_OUTLINE)
	roof := [5]Point{{8, 17}, {40, 17}, {35, 7}, {24, 2}, {13, 7}}
	ArtPolygon(art, roof[:], C_ARCANE_DARK)
	roofHigh := [5]Point{{11, 15}, {37, 15}, {33, 9}, {24, 4}, {15, 9}}
	ArtPolygon(art, roofHigh[:], C_ARCANE)
	ArtPixel(art, 20, 10, C_ARCANE_GLOW)
	ArtPixel(art, 28, 8, C_GOLD_LIGHT)
	ArtPixel(art, 24, 13, C_WHITE)

	ArtRect(art, 20, 32, 8, 12, C_OUTLINE)
	ArtRect(art, 21, 33, 6, 11, C_WOOD_DARKEST)
	ArtCircle(art, 24, 32, 3, C_OUTLINE)
	ArtCircle(art, 24, 32, 2, C_WOOD_DARKEST)

	DrawWindow(art, 14, 22, 4, 6, true)
	DrawWindow(art, 30, 22, 4, 6, true)
	ArtRect(art, 15, 23, 2, 4, C_ARCANE_GLOW)
	ArtRect(art, 31, 23, 2, 4, C_ARCANE_GLOW)

	ArtCircle(art, 38, 12, 3, C_OUTLINE)
	ArtCircle(art, 38, 12, 2, C_ARCANE_GLOW)
	ArtPixel(art, 37, 11, C_WHITE)

	DrawBanner(art, 6, 26, 6, 14, accent)
	DrawFlag(art, 36, 2, accent)
}

DrawGiantPen :: proc(art: ^Art, accent: rl.Color) {
	DrawShadow(art, 32, 60, 26, 3)
	ArtRect(art, 4, 16, 56, 44, C_OUTLINE)
	ArtRect(art, 5, 17, 54, 42, C_DIRT_DARK)
	ArtRect(art, 7, 19, 50, 38, C_DIRT)

	for x := 5; x <= 58; x += 8 {
		ArtRect(art, x, 14, 2, 46, C_WOOD_DARKEST)
	}
	ArtLine(art, 5, 16, 59, 16, C_WOOD)
	ArtLine(art, 5, 58, 59, 58, C_WOOD)
	ArtLine(art, 5, 30, 59, 30, C_WOOD)

	ArtRect(art, 8, 30, 26, 22, C_OUTLINE)
	ArtRect(art, 9, 31, 24, 20, C_WOOD_DARK)
	roof := [4]Point{{5, 31}, {37, 31}, {32, 20}, {10, 20}}
	ArtPolygon(art, roof[:], C_OUTLINE)
	roofInner := [4]Point{{8, 30}, {34, 30}, {30, 22}, {12, 22}}
	ArtPolygon(art, roofInner[:], C_ROOF_DARK)
	ArtRect(art, 13, 38, 12, 13, C_WOOD_DARKEST)

	ArtRect(art, 40, 42, 14, 8, C_GOLD_DARK)
	ArtRect(art, 41, 41, 12, 2, C_GOLD)
	ArtLine(art, 42, 43, 52, 47, C_GOLD_LIGHT)
	ArtLine(art, 44, 41, 50, 48, C_GOLD_LIGHT)

	ArtRect(art, 40, 32, 14, 5, C_OUTLINE)
	ArtRect(art, 41, 33, 12, 3, C_WOOD_DARKEST)
	ArtRect(art, 42, 33, 10, 1, C_WATER)

	ArtLine(art, 54, 54, 44, 30, C_OUTLINE)
	ArtLine(art, 54, 53, 45, 30, C_WOOD_DARK)
	ArtCircle(art, 44, 29, 3, C_OUTLINE)
	ArtCircle(art, 44, 29, 2, C_WOOD)

	ArtLine(art, 12, 55, 18, 57, C_WHITE)
	ArtLine(art, 17, 54, 13, 58, C_WHITE)
	DrawFlag(art, 58, 1, accent)
}

DrawSiegeWorkshop :: proc(art: ^Art, accent: rl.Color) {
	DrawShadow(art, 32, 45, 28, 3)

	// Main hall, spanning the full 4-tile footprint.
	ArtRect(art, 7, 18, 50, 24, C_OUTLINE)
	ArtRect(art, 8, 19, 48, 22, C_WOOD_DARK)
	for y := 23; y < 41; y += 5 {
		ArtLine(art, 8, y, 55, y, C_WOOD_DARKEST)
	}
	ArtLine(art, 8, 20, 8, 40, C_WOOD_LIGHT)

	roof := [4]Point{{3, 20}, {60, 20}, {51, 6}, {7, 6}}
	ArtPolygon(art, roof[:], C_OUTLINE)
	roofInner := [4]Point{{6, 19}, {57, 19}, {49, 8}, {9, 8}}
	ArtPolygon(art, roofInner[:], C_ROOF_DARK)
	roofHigh := [4]Point{{9, 17}, {54, 17}, {47, 10}, {11, 10}}
	ArtPolygon(art, roofHigh[:], C_ROOF)

	// Open assembly bay with a catapult frame under construction.
	ArtRect(art, 12, 26, 30, 15, C_WOOD_DARKEST)
	ArtRect(art, 13, 27, 28, 13, C_DIRT_DARK)
	ArtRect(art, 16, 36, 18, 3, C_WOOD_DARKEST)
	ArtCircle(art, 19, 38, 3, C_OUTLINE)
	ArtCircle(art, 19, 38, 2, C_WOOD_DARKEST)
	ArtCircle(art, 31, 38, 3, C_OUTLINE)
	ArtCircle(art, 31, 38, 2, C_WOOD_DARKEST)
	ArtLine(art, 20, 35, 33, 27, C_OUTLINE)
	ArtLine(art, 20, 34, 33, 26, C_WOOD)
	ArtCircle(art, 33, 26, 2, C_IRON_DARK)

	// Stone forge with a glowing furnace mouth.
	ArtRect(art, 44, 26, 12, 16, C_OUTLINE)
	ArtRect(art, 45, 27, 10, 14, C_STONE_DARK)
	ArtRect(art, 46, 30, 8, 7, C_GOLD_DARK)
	ArtRect(art, 47, 31, 6, 5, C_GOLD)
	ArtRect(art, 48, 32, 4, 3, C_GOLD_LIGHT)
	ArtPixel(art, 49, 29, C_GOLD_LIGHT)

	// Chimney and tool rack.
	ArtRect(art, 47, 0, 5, 7, C_OUTLINE)
	ArtRect(art, 48, 1, 3, 6, C_STONE_DARK)
	ArtPixel(art, 48, 2, C_STONE_LIGHT)
	ArtLine(art, 11, 22, 11, 34, C_WOOD_LIGHT)
	ArtRect(art, 9, 22, 5, 2, C_IRON)

	DrawFlag(art, 30, 0, accent)
}

DrawTurtlePen :: proc(art: ^Art, accent: rl.Color) {
	DrawShadow(art, 24, 42, 18, 3)
	ArtEllipse(art, 24, 28, 19, 13, C_OUTLINE)
	ArtEllipse(art, 24, 28, 18, 12, C_WATER_DARK)
	ArtEllipse(art, 24, 28, 15, 9, C_WATER)
	ArtEllipse(art, 20, 25, 5, 2, C_WATER_LIGHT)
	ArtEllipse(art, 30, 32, 6, 2, C_WATER_LIGHT)

	ArtEllipse(art, 8, 36, 6, 4, C_OUTLINE)
	ArtEllipse(art, 8, 36, 5, 3, C_STONE_DARK)
	ArtEllipse(art, 40, 18, 5, 3, C_OUTLINE)
	ArtEllipse(art, 40, 18, 4, 2, C_STONE)

	ArtEllipse(art, 26, 30, 7, 5, C_OUTLINE)
	ArtEllipse(art, 26, 30, 6, 4, C_LEAF_DARK)
	ArtEllipse(art, 26, 30, 4, 3, C_LEAF)
	ArtLine(art, 22, 29, 30, 31, C_LEAF_LIGHT)
	ArtLine(art, 24, 27, 28, 33, C_LEAF_LIGHT)
	ArtCircle(art, 34, 32, 2, C_OUTLINE)
	ArtCircle(art, 34, 32, 1, C_LEAF_LIGHT)
	ArtPixel(art, 34, 31, C_OUTLINE)
	ArtRect(art, 20, 34, 2, 2, C_LEAF_DARK)
	ArtRect(art, 30, 34, 2, 2, C_LEAF_DARK)
	ArtRect(art, 24, 27, 4, 2, accent)

	for x := 4; x <= 44; x += 8 {
		ArtRect(art, x, 4, 1, 8, C_WOOD_DARK)
	}
	ArtLine(art, 4, 6, 44, 6, C_WOOD)
	ArtLine(art, 4, 10, 44, 10, C_WOOD)
	ArtCircle(art, 12, 22, 3, C_LEAF_DARK)
	ArtPixel(art, 12, 22, C_WATER_DARK)
	ArtCircle(art, 38, 38, 2, C_LEAF)
	DrawFlag(art, 44, 0, accent)
}

DrawThievesGuild :: proc(art: ^Art, accent: rl.Color) {
	DrawShadow(art, 16, 45, 13, 3)
	ArtRect(art, 6, 16, 20, 28, C_OUTLINE)
	ArtRect(art, 7, 17, 18, 26, C_WOOD_DARKEST)
	for y := 21; y < 42; y += 5 {
		ArtLine(art, 7, y, 24, y, C_OUTLINE)
	}
	roof := [4]Point{{3, 18}, {29, 18}, {25, 5}, {7, 5}}
	ArtPolygon(art, roof[:], C_OUTLINE)
	roofInner := [4]Point{{5, 17}, {27, 17}, {24, 6}, {8, 6}}
	ArtPolygon(art, roofInner[:], C_CLOTH_DARK)
	roofHigh := [4]Point{{8, 15}, {24, 15}, {21, 8}, {11, 8}}
	ArtPolygon(art, roofHigh[:], C_CLOTH)

	ArtRect(art, 12, 32, 8, 12, C_OUTLINE)
	ArtRect(art, 13, 33, 6, 11, C_WOOD_DARKEST)
	ArtRect(art, 14, 35, 4, 1, C_GOLD_DARK)
	DrawWindow(art, 9, 22, 2, 5, false)
	DrawWindow(art, 21, 22, 2, 5, false)

	ArtLine(art, 26, 26, 26, 35, C_OUTLINE)
	ArtRect(art, 24, 24, 5, 5, C_OUTLINE)
	ArtRect(art, 25, 25, 3, 3, C_GOLD)
	ArtRect(art, 26, 26, 1, 1, C_GOLD_LIGHT)

	ArtCircle(art, 16, 27, 3, C_OUTLINE)
	ArtCircle(art, 16, 27, 2, C_CLOTH_DARK)
	ArtPixel(art, 15, 27, accent)
	ArtPixel(art, 17, 27, accent)
	DrawBanner(art, 3, 24, 4, 10, accent)
	DrawFlag(art, 25, 0, accent)
}

// ---------------------------------------------------------------------------
// Units
// ---------------------------------------------------------------------------

DrawUnitSprite :: proc(kind: UnitKind, accent: rl.Color) -> Art {
	art := ArtInit(16, 16)
	switch kind {
	case .Villager:
		DrawUnitVillager(&art, accent)
	case .Builder:
		DrawUnitBuilder(&art, accent)
	case .CombatBuilder:
		DrawUnitCombatBuilder(&art, accent)
	case .WaterCollector:
		DrawUnitWaterCollector(&art, accent)
	case .Farmer:
		DrawUnitFarmer(&art, accent)
	case .Knight:
		DrawUnitKnight(&art, accent)
	case .Archer:
		DrawUnitArcher(&art, accent)
	case .Mage:
		DrawUnitMage(&art, accent)
	case .Giant:
		DrawUnitGiant(&art, accent)
	case .Turtle:
		DrawUnitTurtle(&art, accent)
	case .Catapult:
		DrawUnitCatapult(&art, accent)
	case .Rogue:
		DrawUnitRogue(&art, accent)
	case .Explorer:
		DrawUnitExplorer(&art, accent)
	}
	return art
}

// Two-frame leg shift keeps the walk cycle readable at pixel scale without a
// full sprite sheet. Robed and wheeled units rely on the procedural bob alone.
UnitKindHasWalkFrames :: proc(kind: UnitKind) -> bool {
	switch kind {
	case .Catapult, .Turtle:
		return false
	case .Villager, .Builder, .CombatBuilder, .WaterCollector, .Farmer, .Knight, .Archer, .Mage, .Giant, .Rogue, .Explorer:
		return true
	}
	unreachable()
}

UnitWalkFrame :: proc(base: Art, shift: int) -> Art {
	frame := ArtInit(base.width, base.height)
	for y in 0..<base.height {
		for x in 0..<base.width {
			color := rl.GetImageColor(base.image, i32(x), i32(y))
			if color.a == 0 do continue
			pixelX := x
			if y >= 12 && y <= 14 && !SameColor(color, C_SHADOW) do pixelX = x+shift
			ArtPixel(&frame, pixelX, y, color)
		}
	}
	return frame
}

// Wounds are painted over the unit body using its blood colour. Siege engines
// have no blood, so they collect dark splinters and cracks instead.
DamageUnitArt :: proc(base: Art, kind: UnitKind, severity: int, seed: u64) -> Art {
	art := ArtCopy(base)
	stageSeed := seed+u64(severity)*0x85EBCA6B
	tint := BloodTintForUnitType(UnitTypeFromKind(kind))
	if tint == BLOOD_TINT_NONE {
		count := 1+severity*2
		for splinter in 0..<count {
			px := 2+int(WorldNoiseHash(splinter, 1, stageSeed+0xE001)*f32(base.width-4))
			py := 6+int(WorldNoiseHash(splinter, 2, stageSeed+0xE002)*f32(base.height-9))
			if px < 0 || py < 0 || px >= base.width || py >= base.height do continue
			color := rl.GetImageColor(art.image, i32(px), i32(py))
			if color.a == 0 || SameColor(color, C_OUTLINE) || SameColor(color, C_SHADOW) {
				continue
			}
			ArtPixel(&art, px, py, C_WOOD_DARKEST)
			ArtPixel(&art, px+1, py, CShade(color, 0.5))
			if severity >= 2 do ArtPixel(&art, px, py+1, C_STONE_DARK)
		}
		return art
	}

	blood := CShade(BLOOD_PALETTE[int(tint)], 1.25)
	bloodDark := CShade(blood, 0.6)
	stainCount := 1+severity*2
	for stain in 0..<stainCount {
		for attempt in 0..<8 {
			px := 3+int(WorldNoiseHash(stain, attempt, stageSeed+0xE101)*f32(base.width-6))
			py := 6+int(WorldNoiseHash(attempt, stain, stageSeed+0xE102)*f32(base.height-9))
			if px < 0 || py < 0 || px >= base.width || py >= base.height do continue
			color := rl.GetImageColor(art.image, i32(px), i32(py))
			if color.a == 0 || SameColor(color, C_OUTLINE) || SameColor(color, C_SHADOW) {
				continue
			}
			ArtPixel(&art, px, py, blood)
			if WorldNoiseHash(stain, attempt, stageSeed+0xE103) < 0.6 {
				ArtPixel(&art, px+1, py, bloodDark)
			}
			if severity >= 2 {
				if WorldNoiseHash(attempt, stain, stageSeed+0xE104) < 0.6 {
					ArtPixel(&art, px, py+1, blood)
				}
				if WorldNoiseHash(stain, attempt, stageSeed+0xE105) < 0.5 {
					ArtPixel(&art, px-1, py+1, bloodDark)
				}
			}
			break
		}
	}
	return art
}

UnitShadow :: proc(art: ^Art) {
	ArtEllipse(art, 8, 14, 4, 2, C_SHADOW)
}

DrawUnitVillager :: proc(art: ^Art, accent: rl.Color) {
	UnitShadow(art)
	ArtRect(art, 5, 11, 6, 4, C_OUTLINE)
	ArtRect(art, 6, 11, 1, 3, C_WOOD_DARKEST)
	ArtRect(art, 9, 11, 1, 3, C_WOOD_DARKEST)
	ArtRect(art, 4, 6, 8, 6, C_OUTLINE)
	ArtRect(art, 5, 7, 6, 5, C_CLOTH)
	ArtRect(art, 5, 10, 6, 1, C_WOOD_DARKEST)
	ArtRect(art, 5, 7, 6, 1, accent)
	ArtRect(art, 3, 7, 1, 4, C_OUTLINE)
	ArtRect(art, 12, 7, 1, 4, C_OUTLINE)
	ArtCircle(art, 8, 4, 3, C_OUTLINE)
	ArtCircle(art, 8, 4, 2, C_SKIN)
	ArtRect(art, 6, 2, 4, 2, C_HAIR)
	ArtPixel(art, 7, 4, C_OUTLINE)
	ArtPixel(art, 9, 4, C_OUTLINE)
	ArtRect(art, 11, 8, 2, 3, C_WOOD_DARK)
	ArtRectOutline(art, 11, 8, 2, 3, C_OUTLINE)
}

DrawUnitBuilder :: proc(art: ^Art, accent: rl.Color) {
	UnitShadow(art)
	ArtRect(art, 5, 11, 6, 4, C_OUTLINE)
	ArtRect(art, 6, 11, 1, 3, C_WOOD_DARKEST)
	ArtRect(art, 9, 11, 1, 3, C_WOOD_DARKEST)
	ArtRect(art, 4, 6, 8, 6, C_OUTLINE)
	ArtRect(art, 5, 7, 6, 5, C_LEAF_DARK)
	ArtRect(art, 5, 10, 6, 1, C_WOOD_DARKEST)
	ArtRect(art, 5, 7, 6, 1, accent)
	ArtRect(art, 3, 7, 1, 4, C_OUTLINE)
	ArtRect(art, 12, 7, 1, 4, C_OUTLINE)
	ArtCircle(art, 8, 4, 3, C_OUTLINE)
	ArtCircle(art, 8, 4, 2, C_SKIN)
	ArtPixel(art, 7, 4, C_OUTLINE)
	ArtPixel(art, 9, 4, C_OUTLINE)
	ArtRect(art, 5, 2, 6, 2, C_WOOD_DARKEST)
	ArtRect(art, 4, 3, 8, 1, C_WOOD_DARK)
	ArtLine(art, 12, 11, 14, 5, C_OUTLINE)
	ArtLine(art, 12, 10, 13, 5, C_WOOD_LIGHT)
	ArtRect(art, 12, 4, 3, 2, C_OUTLINE)
	ArtRect(art, 13, 5, 1, 1, C_IRON)
	ArtRect(art, 10, 10, 2, 2, C_WOOD_DARK)
}

DrawUnitExplorer :: proc(art: ^Art, accent: rl.Color) {
	UnitShadow(art)
	ArtRect(art, 5, 11, 6, 4, C_OUTLINE)
	ArtRect(art, 6, 11, 1, 3, C_WOOD_DARKEST)
	ArtRect(art, 9, 11, 1, 3, C_WOOD_DARKEST)
	ArtRect(art, 4, 6, 8, 6, C_OUTLINE)
	ArtRect(art, 5, 7, 6, 5, C_CLOTH_LIGHT)
	ArtRect(art, 5, 10, 6, 1, C_WOOD_DARKEST)
	ArtRect(art, 5, 7, 6, 1, accent)
	ArtRect(art, 3, 7, 1, 4, C_OUTLINE)
	ArtRect(art, 12, 7, 1, 4, C_OUTLINE)
	ArtCircle(art, 8, 4, 3, C_OUTLINE)
	ArtCircle(art, 8, 4, 2, C_SKIN)
	ArtPixel(art, 7, 4, C_OUTLINE)
	ArtPixel(art, 9, 4, C_OUTLINE)
	// Wide travelling hat.
	ArtRect(art, 4, 2, 8, 1, C_WOOD_DARKEST)
	ArtRect(art, 6, 0, 4, 2, C_WOOD_DARK)
	ArtRect(art, 7, 0, 2, 1, C_WOOD_LIGHT)
	// Backpack and walking staff.
	ArtRect(art, 11, 7, 2, 4, C_WOOD_DARKEST)
	ArtRect(art, 11, 8, 2, 1, C_WOOD)
	ArtLine(art, 13, 12, 13, 4, C_OUTLINE)
	ArtLine(art, 14, 11, 14, 5, C_WOOD_LIGHT)
}

DrawUnitCombatBuilder :: proc(art: ^Art, accent: rl.Color) {
	UnitShadow(art)
	ArtRect(art, 5, 11, 6, 4, C_OUTLINE)
	ArtRect(art, 6, 11, 1, 3, C_WOOD_DARKEST)
	ArtRect(art, 9, 11, 1, 3, C_WOOD_DARKEST)
	ArtRect(art, 4, 6, 8, 6, C_OUTLINE)
	ArtRect(art, 5, 7, 6, 5, C_IRON_DARK)
	ArtRect(art, 5, 10, 6, 1, C_WOOD_DARKEST)
	ArtRect(art, 5, 7, 6, 1, accent)
	ArtRect(art, 3, 7, 1, 4, C_OUTLINE)
	ArtRect(art, 12, 7, 1, 4, C_OUTLINE)

	ArtCircle(art, 8, 4, 3, C_OUTLINE)
	ArtCircle(art, 8, 4, 2, C_SKIN)
	ArtRect(art, 5, 1, 7, 3, C_OUTLINE)
	ArtRect(art, 6, 2, 5, 2, C_IRON)
	ArtRect(art, 7, 2, 3, 1, C_IRON_LIGHT)
	ArtPixel(art, 7, 4, C_OUTLINE)
	ArtPixel(art, 9, 4, C_OUTLINE)

	ArtLine(art, 12, 12, 14, 4, C_OUTLINE)
	ArtLine(art, 12, 11, 13, 4, C_WOOD_LIGHT)
	ArtRect(art, 12, 3, 4, 4, C_OUTLINE)
	ArtRect(art, 13, 4, 2, 2, C_STONE)
	ArtRect(art, 10, 10, 2, 2, C_IRON_DARK)
}

DrawUnitWaterCollector :: proc(art: ^Art, accent: rl.Color) {
	UnitShadow(art)
	ArtRect(art, 5, 11, 6, 4, C_OUTLINE)
	ArtRect(art, 6, 11, 1, 3, C_WOOD_DARKEST)
	ArtRect(art, 9, 11, 1, 3, C_WOOD_DARKEST)
	ArtRect(art, 4, 6, 8, 6, C_OUTLINE)
	ArtRect(art, 5, 7, 6, 5, C_WATER_DARK)
	ArtRect(art, 5, 7, 6, 1, C_WATER_LIGHT)
	ArtRect(art, 5, 10, 6, 1, accent)
	ArtRect(art, 3, 7, 1, 4, C_OUTLINE)
	ArtRect(art, 12, 7, 1, 4, C_OUTLINE)
	ArtCircle(art, 8, 4, 3, C_OUTLINE)
	ArtCircle(art, 8, 4, 2, C_SKIN)
	ArtRect(art, 5, 2, 6, 2, C_WATER_DARK)
	ArtRect(art, 4, 3, 8, 1, C_WATER_LIGHT)
	ArtPixel(art, 7, 4, C_OUTLINE)
	ArtPixel(art, 9, 4, C_OUTLINE)
	ArtRect(art, 11, 10, 3, 4, C_OUTLINE)
	ArtRect(art, 12, 11, 1, 2, C_IRON)
	ArtLine(art, 11, 10, 13, 9, C_IRON_LIGHT)
	ArtPixel(art, 13, 9, C_WATER_LIGHT)
}

DrawUnitFarmer :: proc(art: ^Art, accent: rl.Color) {
	UnitShadow(art)
	ArtRect(art, 5, 11, 6, 4, C_OUTLINE)
	ArtRect(art, 6, 11, 1, 3, C_WOOD_DARKEST)
	ArtRect(art, 9, 11, 1, 3, C_WOOD_DARKEST)
	ArtRect(art, 4, 6, 8, 6, C_OUTLINE)
	ArtRect(art, 5, 7, 6, 5, C_LEAF_DARK)
	ArtRect(art, 5, 10, 6, 1, C_WOOD_DARKEST)
	ArtRect(art, 5, 7, 6, 1, accent)
	ArtRect(art, 3, 7, 1, 4, C_OUTLINE)
	ArtRect(art, 12, 7, 1, 4, C_OUTLINE)
	ArtCircle(art, 8, 4, 3, C_OUTLINE)
	ArtCircle(art, 8, 4, 2, C_SKIN)
	ArtPixel(art, 7, 4, C_OUTLINE)
	ArtPixel(art, 9, 4, C_OUTLINE)
	ArtRect(art, 4, 2, 9, 2, C_OUTLINE)
	ArtRect(art, 5, 2, 7, 1, C_GOLD)
	ArtRect(art, 6, 0, 5, 2, C_OUTLINE)
	ArtRect(art, 7, 0, 3, 1, C_GOLD_LIGHT)
	ArtLine(art, 12, 12, 14, 4, C_OUTLINE)
	ArtLine(art, 12, 11, 13, 5, C_WOOD_LIGHT)
	ArtRect(art, 13, 4, 2, 1, C_IRON_LIGHT)
	ArtLine(art, 2, 12, 3, 8, C_GOLD_DARK)
	ArtLine(art, 3, 12, 4, 8, C_GOLD)
	ArtLine(art, 4, 12, 5, 8, C_GOLD_LIGHT)
}

DrawUnitKnight :: proc(art: ^Art, accent: rl.Color) {
	UnitShadow(art)
	ArtRect(art, 5, 11, 6, 4, C_OUTLINE)
	ArtRect(art, 6, 11, 1, 3, C_IRON_DARK)
	ArtRect(art, 9, 11, 1, 3, C_IRON_DARK)
	ArtRect(art, 4, 6, 8, 6, C_OUTLINE)
	ArtRect(art, 5, 7, 6, 5, C_IRON_DARK)
	ArtRect(art, 5, 7, 6, 1, C_IRON)
	ArtRect(art, 5, 10, 6, 1, accent)
	ArtRect(art, 3, 7, 1, 4, C_OUTLINE)
	ArtRect(art, 12, 7, 1, 4, C_OUTLINE)
	ArtCircle(art, 8, 4, 3, C_OUTLINE)
	ArtCircle(art, 8, 4, 2, C_IRON)
	ArtRect(art, 6, 4, 4, 1, C_OUTLINE)
	ArtPixel(art, 8, 2, C_IRON_LIGHT)
	ArtRect(art, 8, 0, 2, 2, accent)
	ArtPixel(art, 7, 1, accent)
	ArtRect(art, 1, 7, 4, 6, C_OUTLINE)
	ArtRect(art, 2, 8, 2, 4, accent)
	ArtRect(art, 2, 9, 2, 1, C_GOLD_LIGHT)
	ArtLine(art, 12, 11, 14, 3, C_OUTLINE)
	ArtLine(art, 12, 10, 13, 3, C_IRON_LIGHT)
	ArtLine(art, 11, 11, 13, 11, C_GOLD)
}

DrawUnitArcher :: proc(art: ^Art, accent: rl.Color) {
	UnitShadow(art)
	ArtRect(art, 5, 11, 6, 4, C_OUTLINE)
	ArtRect(art, 6, 11, 1, 3, C_WOOD_DARKEST)
	ArtRect(art, 9, 11, 1, 3, C_WOOD_DARKEST)
	ArtRect(art, 4, 6, 8, 6, C_OUTLINE)
	ArtRect(art, 5, 7, 6, 5, C_LEAF_DARK)
	ArtRect(art, 5, 10, 6, 1, C_WOOD_DARKEST)
	ArtRect(art, 5, 7, 6, 1, accent)
	ArtRect(art, 3, 7, 1, 4, C_OUTLINE)
	ArtRect(art, 12, 7, 1, 4, C_OUTLINE)
	ArtCircle(art, 8, 4, 3, C_OUTLINE)
	ArtCircle(art, 8, 4, 2, C_SKIN)
	ArtRect(art, 5, 2, 6, 2, C_LEAF_DARK)
	ArtRect(art, 4, 3, 2, 2, C_LEAF_DARK)
	ArtPixel(art, 7, 4, C_OUTLINE)
	ArtPixel(art, 9, 4, C_OUTLINE)
	ArtRect(art, 10, 6, 2, 5, C_WOOD_DARK)
	ArtLine(art, 11, 6, 11, 3, C_WOOD_LIGHT)
	ArtPixel(art, 10, 3, C_IRON_LIGHT)
	ArtPixel(art, 12, 3, C_IRON_LIGHT)
	ArtLine(art, 12, 3, 14, 5, C_OUTLINE)
	ArtLine(art, 14, 5, 14, 9, C_OUTLINE)
	ArtLine(art, 14, 9, 12, 12, C_OUTLINE)
	ArtLine(art, 13, 4, 13, 10, C_IRON_LIGHT)
	ArtLine(art, 12, 8, 15, 8, C_WOOD_LIGHT)
	ArtPixel(art, 15, 8, C_IRON_LIGHT)
}

DrawUnitMage :: proc(art: ^Art, accent: rl.Color) {
	UnitShadow(art)
	robeOutline := [4]Point{{5, 6}, {11, 6}, {13, 14}, {3, 14}}
	ArtPolygon(art, robeOutline[:], C_OUTLINE)
	robe := [4]Point{{6, 7}, {10, 7}, {12, 13}, {4, 13}}
	ArtPolygon(art, robe[:], C_ARCANE_DARK)
	robeHigh := [4]Point{{7, 7}, {9, 7}, {10, 12}, {6, 12}}
	ArtPolygon(art, robeHigh[:], C_ARCANE)
	ArtLine(art, 5, 12, 11, 12, accent)
	ArtRect(art, 3, 8, 1, 4, C_OUTLINE)
	ArtRect(art, 12, 8, 1, 4, C_OUTLINE)
	ArtCircle(art, 8, 4, 3, C_OUTLINE)
	ArtCircle(art, 8, 4, 2, C_SKIN)
	ArtRect(art, 6, 5, 4, 2, C_WHITE)
	ArtPixel(art, 7, 4, C_OUTLINE)
	ArtPixel(art, 9, 4, C_OUTLINE)
	ArtRect(art, 4, 2, 9, 2, C_OUTLINE)
	ArtRect(art, 5, 2, 7, 1, C_ARCANE_DARK)
	hat := [3]Point{{6, 2}, {10, 2}, {8, 0}}
	ArtPolygon(art, hat[:], C_ARCANE_DARK)
	ArtPixel(art, 8, 1, C_ARCANE_GLOW)
	ArtLine(art, 13, 13, 13, 4, C_OUTLINE)
	ArtLine(art, 12, 12, 12, 4, C_WOOD_LIGHT)
	ArtCircle(art, 13, 3, 2, C_OUTLINE)
	ArtCircle(art, 13, 3, 1, C_ARCANE_GLOW)
	ArtPixel(art, 11, 2, C_ARCANE_GLOW)
}

DrawUnitGiant :: proc(art: ^Art, accent: rl.Color) {
	UnitShadow(art)

	ArtRect(art, 3, 11, 4, 4, C_OUTLINE)
	ArtRect(art, 9, 11, 4, 4, C_OUTLINE)
	ArtRect(art, 4, 12, 2, 2, C_SKIN_DARK)
	ArtRect(art, 10, 12, 2, 2, C_SKIN_DARK)

	// Bare torso with a fur collar and a faction-coloured loincloth.
	ArtRect(art, 3, 4, 10, 8, C_OUTLINE)
	ArtRect(art, 4, 4, 8, 7, C_SKIN)
	ArtRect(art, 4, 7, 8, 4, C_SKIN_DARK)
	ArtRect(art, 3, 4, 10, 2, C_WOOD_DARK)
	ArtRect(art, 3, 4, 10, 1, C_WOOD_LIGHT)
	ArtRect(art, 4, 9, 8, 2, C_WOOD_DARKEST)
	ArtRect(art, 4, 9, 8, 1, accent)

	ArtRect(art, 1, 5, 2, 5, C_OUTLINE)
	ArtRect(art, 2, 6, 1, 3, C_SKIN)
	ArtRect(art, 12, 4, 2, 5, C_OUTLINE)
	ArtRect(art, 13, 5, 1, 3, C_SKIN)

	// Club held overhead.
	ArtRect(art, 13, 3, 1, 2, C_WOOD_DARK)
	ArtCircle(art, 13, 2, 2, C_OUTLINE)
	ArtCircle(art, 13, 2, 1, C_WOOD_LIGHT)

	ArtCircle(art, 8, 3, 3, C_OUTLINE)
	ArtCircle(art, 8, 3, 2, C_SKIN)
	ArtRect(art, 6, 0, 5, 2, C_HAIR)
	ArtPixel(art, 6, 2, C_SKIN_DARK)
	ArtPixel(art, 7, 3, C_OUTLINE)
	ArtPixel(art, 9, 3, C_OUTLINE)
	ArtRect(art, 7, 5, 3, 1, C_HAIR)
}

DrawUnitTurtle :: proc(art: ^Art, accent: rl.Color) {
	UnitShadow(art)

	// Flippers and tail.
	ArtRect(art, 2, 11, 3, 2, C_OUTLINE)
	ArtRect(art, 10, 11, 3, 2, C_OUTLINE)
	ArtPixel(art, 2, 12, C_LEAF_LIGHT)
	ArtPixel(art, 12, 12, C_LEAF_LIGHT)
	ArtRect(art, 3, 5, 2, 2, C_OUTLINE)
	ArtPixel(art, 3, 5, C_LEAF)
	ArtPixel(art, 0, 9, C_LEAF_DARK)

	// Shell.
	ArtEllipse(art, 7, 8, 6, 5, C_OUTLINE)
	ArtEllipse(art, 7, 8, 5, 4, C_LEAF_DARK)
	ArtEllipse(art, 7, 8, 3, 2, C_LEAF)
	ArtLine(art, 4, 8, 10, 8, C_LEAF_DARKEST)
	ArtLine(art, 7, 5, 7, 11, C_LEAF_DARKEST)
	ArtPixel(art, 5, 6, C_LEAF_LIGHT)
	ArtPixel(art, 9, 10, C_LEAF)

	// Harness in the faction colour.
	ArtRect(art, 5, 7, 4, 2, accent)

	// Neck and head.
	ArtRect(art, 11, 6, 3, 3, C_OUTLINE)
	ArtRect(art, 12, 6, 2, 2, C_LEAF_LIGHT)
	ArtPixel(art, 13, 6, C_OUTLINE)
	ArtPixel(art, 11, 9, C_LEAF_DARK)
}

DrawUnitCatapult :: proc(art: ^Art, accent: rl.Color) {
	UnitShadow(art)
	ArtRect(art, 2, 11, 12, 3, C_OUTLINE)
	ArtRect(art, 3, 12, 10, 2, C_WOOD_DARK)
	ArtCircle(art, 4, 13, 2, C_OUTLINE)
	ArtCircle(art, 4, 13, 1, C_WOOD_DARKEST)
	ArtCircle(art, 12, 13, 2, C_OUTLINE)
	ArtCircle(art, 12, 13, 1, C_WOOD_DARKEST)
	ArtLine(art, 5, 11, 7, 6, C_OUTLINE)
	ArtLine(art, 11, 11, 9, 6, C_OUTLINE)
	ArtLine(art, 6, 10, 8, 6, C_WOOD_LIGHT)
	ArtLine(art, 10, 10, 9, 6, C_WOOD_LIGHT)
	ArtLine(art, 8, 9, 13, 3, C_OUTLINE)
	ArtLine(art, 8, 8, 12, 3, C_WOOD)
	ArtRect(art, 11, 2, 3, 2, C_OUTLINE)
	ArtRect(art, 12, 3, 1, 1, C_IRON_DARK)
	ArtCircle(art, 13, 2, 1, C_STONE)
	ArtLine(art, 8, 5, 8, 2, C_OUTLINE)
	ArtRect(art, 9, 2, 3, 2, accent)
	ArtRectOutline(art, 9, 2, 3, 2, C_OUTLINE)
}

DrawUnitRogue :: proc(art: ^Art, accent: rl.Color) {
	UnitShadow(art)
	ArtRect(art, 5, 11, 6, 4, C_OUTLINE)
	ArtRect(art, 6, 11, 1, 3, C_CLOTH_DARKEST)
	ArtRect(art, 9, 11, 1, 3, C_CLOTH_DARKEST)
	cloak := [4]Point{{4, 6}, {12, 6}, {13, 14}, {3, 14}}
	ArtPolygon(art, cloak[:], C_OUTLINE)
	cloakInner := [4]Point{{5, 7}, {11, 7}, {12, 13}, {4, 13}}
	ArtPolygon(art, cloakInner[:], C_CLOTH_DARKEST)
	ArtLine(art, 5, 10, 11, 10, accent)
	ArtCircle(art, 8, 4, 3, C_OUTLINE)
	ArtCircle(art, 8, 4, 2, C_CLOTH_DARKEST)
	ArtRect(art, 6, 4, 4, 2, C_OUTLINE)
	ArtPixel(art, 7, 4, accent)
	ArtPixel(art, 9, 4, accent)
	ArtLine(art, 3, 10, 1, 6, C_OUTLINE)
	ArtLine(art, 3, 9, 2, 6, C_IRON_LIGHT)
	ArtLine(art, 13, 10, 15, 6, C_OUTLINE)
	ArtLine(art, 13, 9, 14, 6, C_IRON_LIGHT)
	ArtRect(art, 6, 6, 4, 1, accent)
}

// ---------------------------------------------------------------------------
// Sprite set
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Decorations
// ---------------------------------------------------------------------------

DrawDecorationSprite :: proc(kind: DecorationKind) -> Art {
	switch kind {
	case .Tree:
		art := ArtInit(20, 30)
		DrawDecorationTree(&art)
		return art
	case .Pine:
		art := ArtInit(20, 34)
		DrawDecorationPine(&art)
		return art
	case .Bush:
		art := ArtInit(16, 12)
		DrawDecorationBush(&art)
		return art
	case .Rock:
		art := ArtInit(16, 10)
		DrawDecorationRock(&art)
		return art
	case .Flowers:
		art := ArtInit(16, 8)
		DrawDecorationFlowers(&art)
		return art
	case .Cactus:
		art := ArtInit(16, 20)
		DrawDecorationCactus(&art)
		return art
	case .Reed:
		art := ArtInit(16, 14)
		DrawDecorationReed(&art)
		return art
	case .Stump:
		art := ArtInit(16, 10)
		DrawDecorationStump(&art)
		return art
	case .Lamp:
		art := ArtInit(16, 28)
		DrawDecorationLamp(&art)
		return art
	case .Rubble:
		art := ArtInit(18, 12)
		DrawDecorationRubble(&art, false)
		return art
	case .BurntRubble:
		art := ArtInit(18, 12)
		DrawDecorationRubble(&art, true)
		return art
	}
	return ArtInit(1, 1)
}

DrawDecorationTree :: proc(art: ^Art) {
	DrawShadow(art, 10, 28, 6, 2)

	ArtRect(art, 9, 18, 3, 12, C_OUTLINE)
	ArtRect(art, 10, 19, 1, 10, C_WOOD_DARK)
	ArtPixel(art, 11, 20, C_WOOD)

	ArtCircle(art, 10, 10, 8, C_OUTLINE)
	ArtCircle(art, 5, 15, 5, C_OUTLINE)
	ArtCircle(art, 15, 15, 5, C_OUTLINE)

	ArtCircle(art, 10, 10, 7, C_LEAF_DARKEST)
	ArtCircle(art, 5, 15, 4, C_LEAF_DARKEST)
	ArtCircle(art, 15, 15, 4, C_LEAF_DARKEST)

	ArtCircle(art, 8, 9, 6, C_LEAF_DARK)
	ArtCircle(art, 13, 10, 5, C_LEAF_DARK)
	ArtCircle(art, 6, 15, 3, C_LEAF_DARK)

	ArtCircle(art, 8, 8, 4, C_LEAF)
	ArtCircle(art, 12, 7, 3, C_LEAF)
	ArtPixel(art, 6, 5, C_LEAF_LIGHT)
	ArtPixel(art, 7, 4, C_LEAF_LIGHT)
	ArtPixel(art, 11, 6, C_LEAF_LIGHT)
	ArtPixel(art, 15, 13, C_LEAF_LIGHT)
	ArtPixel(art, 4, 14, C_LEAF_LIGHT)
}

DrawDecorationPine :: proc(art: ^Art) {
	DrawShadow(art, 10, 32, 6, 2)

	ArtRect(art, 9, 25, 3, 9, C_OUTLINE)
	ArtRect(art, 10, 26, 1, 8, C_WOOD_DARK)

	ArtTriangle(art, 10, 13, 0, 27, 20, 27, C_OUTLINE)
	ArtTriangle(art, 10, 15, 2, 27, 18, 27, C_LEAF_DARKEST)
	ArtTriangle(art, 10, 7, 1, 21, 19, 21, C_OUTLINE)
	ArtTriangle(art, 10, 9, 3, 21, 17, 21, C_LEAF_DARKEST)
	ArtTriangle(art, 10, 1, 4, 13, 16, 13, C_OUTLINE)
	ArtTriangle(art, 10, 3, 5, 13, 15, 13, C_LEAF_DARK)

	ArtLine(art, 10, 4, 10, 12, C_LEAF)
	ArtLine(art, 10, 10, 10, 20, C_LEAF_DARK)
	ArtPixel(art, 9, 7, C_LEAF_LIGHT)
	ArtPixel(art, 9, 14, C_LEAF)
	ArtPixel(art, 13, 19, C_LEAF_DARKEST)
	ArtPixel(art, 9, 22, C_LEAF_DARKEST)
}

DrawDecorationBush :: proc(art: ^Art) {
	DrawShadow(art, 8, 10, 4, 1)

	ArtCircle(art, 4, 8, 4, C_OUTLINE)
	ArtCircle(art, 11, 8, 4, C_OUTLINE)
	ArtCircle(art, 8, 5, 4, C_OUTLINE)
	ArtCircle(art, 4, 8, 3, C_LEAF_DARKEST)
	ArtCircle(art, 11, 8, 3, C_LEAF_DARKEST)
	ArtCircle(art, 8, 5, 3, C_LEAF_DARKEST)
	ArtCircle(art, 5, 7, 2, C_LEAF_DARK)
	ArtCircle(art, 10, 7, 2, C_LEAF_DARK)
	ArtCircle(art, 8, 5, 2, C_LEAF)
	ArtPixel(art, 7, 4, C_LEAF_LIGHT)
}

DrawDecorationRock :: proc(art: ^Art) {
	DrawShadow(art, 8, 8, 5, 1)

	outline := [6]Point{{2, 8}, {4, 3}, {11, 2}, {14, 6}, {12, 8}, {3, 8}}
	ArtPolygon(art, outline[:], C_OUTLINE)
	fill := [5]Point{{3, 7}, {5, 4}, {10, 3}, {13, 6}, {11, 7}}
	ArtPolygon(art, fill[:], C_STONE_DARK)
	ArtRect(art, 5, 4, 5, 1, C_STONE)
	ArtPixel(art, 11, 4, C_STONE_LIGHT)
	ArtPixel(art, 4, 7, C_STONE_DARKEST)
}

DrawDecorationFlowers :: proc(art: ^Art) {
	positions := [6][2]int{{2, 5}, {5, 3}, {8, 6}, {11, 3}, {13, 5}, {14, 6}}
	colors := [6]rl.Color{C_WHITE, C_GOLD_LIGHT, C_ROOF_LIGHT, C_ARCANE_LIGHT, C_WHITE, C_GOLD_LIGHT}
	for position, index in positions {
		x := position[0]
		y := position[1]
		DrawFlower(art, x, y, colors[index])
	}
}

DrawFlower :: proc(art: ^Art, x, y: int, color: rl.Color) {
	ArtRect(art, x, y+1, 1, 2, C_LEAF_DARK)
	ArtPixel(art, x-1, y, color)
	ArtPixel(art, x+1, y, color)
	ArtPixel(art, x, y-1, color)
	ArtPixel(art, x, y+1, color)
	ArtPixel(art, x, y, C_GOLD_LIGHT)
}

DrawDecorationCactus :: proc(art: ^Art) {
	DrawShadow(art, 8, 18, 4, 2)

	ArtRect(art, 1, 9, 5, 3, C_OUTLINE)
	ArtRect(art, 2, 10, 4, 1, C_LEAF_DARK)
	ArtRect(art, 1, 6, 3, 4, C_OUTLINE)
	ArtRect(art, 2, 7, 1, 3, C_LEAF_DARK)

	ArtRect(art, 10, 6, 5, 3, C_OUTLINE)
	ArtRect(art, 10, 7, 4, 1, C_LEAF_DARK)
	ArtRect(art, 12, 3, 3, 4, C_OUTLINE)
	ArtRect(art, 13, 4, 1, 3, C_LEAF_DARK)

	ArtRect(art, 6, 2, 5, 17, C_OUTLINE)
	ArtRect(art, 7, 3, 3, 15, C_LEAF_DARK)
	ArtRect(art, 8, 4, 1, 13, C_LEAF)
	ArtPixel(art, 7, 5, C_LEAF_LIGHT)
	ArtPixel(art, 7, 11, C_LEAF_LIGHT)
	ArtPixel(art, 9, 8, C_LEAF_LIGHT)
}

DrawDecorationReed :: proc(art: ^Art) {
	DrawShadow(art, 8, 12, 4, 1)

	ArtLine(art, 3, 12, 2, 5, C_LEAF_DARK)
	ArtRect(art, 2, 3, 1, 2, C_WOOD_DARK)
	ArtLine(art, 6, 12, 6, 4, C_LEAF_DARK)
	ArtRect(art, 6, 2, 1, 2, C_WOOD)
	ArtLine(art, 9, 12, 10, 6, C_LEAF_DARK)
	ArtRect(art, 10, 4, 1, 2, C_WOOD_DARK)
	ArtLine(art, 12, 12, 13, 7, C_LEAF_DARK)
	ArtRect(art, 13, 5, 1, 2, C_WOOD)
	ArtPixel(art, 6, 6, C_LEAF_LIGHT)
}

DrawDecorationStump :: proc(art: ^Art) {
	DrawShadow(art, 8, 8, 5, 1)

	ArtEllipse(art, 8, 6, 5, 3, C_OUTLINE)
	ArtEllipse(art, 8, 6, 4, 2, C_WOOD_DARK)
	ArtEllipse(art, 8, 6, 2, 1, C_WOOD)
	ArtPixel(art, 7, 6, C_WOOD_LIGHT)
	ArtRect(art, 4, 8, 2, 1, C_WOOD_DARKEST)
	ArtRect(art, 11, 8, 2, 1, C_WOOD_DARKEST)
}

DrawDecorationLamp :: proc(art: ^Art) {
	DrawShadow(art, 8, 26, 4, 1)

	ArtRect(art, 7, 10, 3, 16, C_OUTLINE)
	ArtRect(art, 8, 11, 1, 14, C_IRON_DARK)
	ArtRect(art, 6, 24, 5, 2, C_OUTLINE)
	ArtRect(art, 7, 25, 3, 1, C_IRON)

	ArtRect(art, 5, 4, 7, 7, C_OUTLINE)
	ArtRect(art, 6, 5, 5, 5, C_GOLD_DARK)
	ArtRect(art, 7, 6, 3, 3, C_GOLD_LIGHT)
	ArtPixel(art, 8, 7, C_WHITE)

	ArtRect(art, 4, 2, 9, 2, C_OUTLINE)
	ArtRect(art, 5, 3, 7, 1, C_IRON)
	ArtPixel(art, 8, 0, C_IRON_LIGHT)
	ArtPixel(art, 8, 1, C_IRON)
}

DrawDecorationRubble :: proc(art: ^Art, burnt: bool) {
	DrawShadow(art, 9, 10, 6, 2)

	stoneDark := C_STONE_DARK
	stone := C_STONE
	stoneLight := C_STONE_LIGHT
	woodDark := C_WOOD_DARK
	woodLight := C_WOOD_LIGHT
	if burnt {
		stoneDark = C_STONE_DARKEST
		stone = C_STONE_DARK
		stoneLight = C_STONE
		woodDark = C_WOOD_DARKEST
		woodLight = C_WOOD_DARK
	}

	// Broken timber over the stones.
	ArtLine(art, 2, 8, 10, 3, C_OUTLINE)
	ArtLine(art, 2, 7, 9, 3, woodDark)
	ArtPixel(art, 5, 5, woodLight)
	ArtRect(art, 11, 3, 3, 2, C_OUTLINE)
	ArtRect(art, 12, 4, 2, 1, woodDark)

	ArtEllipse(art, 5, 8, 4, 3, C_OUTLINE)
	ArtEllipse(art, 5, 8, 3, 2, stoneDark)
	ArtPixel(art, 4, 7, stone)
	ArtPixel(art, 5, 6, stoneLight)
	ArtEllipse(art, 12, 8, 4, 2, C_OUTLINE)
	ArtEllipse(art, 12, 8, 3, 1, stoneDark)
	ArtPixel(art, 11, 8, stone)
	ArtPixel(art, 13, 8, stoneLight)

	ArtRect(art, 8, 9, 3, 2, C_OUTLINE)
	ArtRect(art, 9, 9, 2, 1, stone)
	ArtPixel(art, 15, 9, stoneLight)
	ArtPixel(art, 2, 9, stone)
	ArtPixel(art, 8, 6, stoneLight)
	if burnt {
		ArtPixel(art, 10, 5, woodDark)
		ArtPixel(art, 6, 10, stoneDark)
		ArtPixel(art, 14, 7, stone)
	}
}

// Small inspection icons for unit conditions. The red slash is shared so the
// three effects read as warnings at a glance.
DrawEffectIcon :: proc(effect: UnitEffects) -> Art {
	art := ArtInit(20, 20)
	switch effect {
	case .NoHome:
		ArtTriangle(&art, 10, 2, 2, 10, 18, 10, C_OUTLINE)
		ArtTriangle(&art, 10, 4, 4, 10, 16, 10, C_ROOF)
		ArtRect(&art, 5, 10, 10, 8, C_OUTLINE)
		ArtRect(&art, 6, 11, 8, 6, C_STONE_DARK)
		ArtRect(&art, 9, 13, 2, 4, C_WOOD_DARKEST)
		ArtLine(&art, 3, 17, 17, 3, C_OUTLINE)
		ArtLine(&art, 4, 17, 18, 3, C_EFFECT_BAD)
		ArtLine(&art, 3, 16, 17, 2, C_EFFECT_BAD)
	case .NoWater:
		ArtTriangle(&art, 10, 2, 5, 11, 15, 11, C_OUTLINE)
		ArtCircle(&art, 10, 12, 6, C_OUTLINE)
		ArtTriangle(&art, 10, 3, 6, 11, 14, 11, C_WATER_DARK)
		ArtCircle(&art, 10, 12, 5, C_WATER)
		ArtCircle(&art, 8, 11, 2, C_WATER_LIGHT)
		ArtLine(&art, 3, 17, 17, 3, C_OUTLINE)
		ArtLine(&art, 4, 17, 18, 3, C_EFFECT_BAD)
		ArtLine(&art, 3, 16, 17, 2, C_EFFECT_BAD)
	case .NoFood:
		ArtRect(&art, 4, 9, 12, 8, C_OUTLINE)
		ArtRect(&art, 5, 10, 10, 6, C_GOLD_DARK)
		ArtRect(&art, 5, 10, 10, 1, C_GOLD_LIGHT)
		ArtRect(&art, 6, 12, 3, 1, C_GOLD)
		ArtRect(&art, 11, 14, 3, 1, C_GOLD)
		ArtLine(&art, 3, 17, 17, 3, C_OUTLINE)
		ArtLine(&art, 4, 17, 18, 3, C_EFFECT_BAD)
		ArtLine(&art, 3, 16, 17, 2, C_EFFECT_BAD)
	}
	return art
}

// A bundle of cut logs, used wherever wood is shown in the UI.
DrawWoodIcon :: proc() -> Art {
	art := ArtInit(16, 16)
	DrawWoodLogIcon(&art, 1, 2)
	DrawWoodLogIcon(&art, 2, 9)
	return art
}

DrawCrownIcon :: proc() -> Art {
	art := ArtInit(16, 16)
	ArtRect(&art, 2, 10, 12, 4, C_OUTLINE)
	ArtRect(&art, 3, 11, 10, 2, C_GOLD_DARK)
	ArtRect(&art, 3, 11, 10, 1, C_GOLD)
	ArtTriangle(&art, 2, 11, 1, 4, 6, 11, C_OUTLINE)
	ArtTriangle(&art, 3, 11, 2, 6, 5, 11, C_GOLD_DARK)
	ArtTriangle(&art, 3, 10, 2, 6, 4, 10, C_GOLD)
	ArtTriangle(&art, 5, 11, 8, 1, 11, 11, C_OUTLINE)
	ArtTriangle(&art, 6, 11, 8, 3, 10, 11, C_GOLD)
	ArtPixel(&art, 8, 2, C_GOLD_LIGHT)
	ArtTriangle(&art, 10, 11, 15, 4, 14, 11, C_OUTLINE)
	ArtTriangle(&art, 11, 11, 14, 6, 13, 11, C_GOLD_DARK)
	ArtTriangle(&art, 11, 10, 14, 6, 13, 10, C_GOLD)
	ArtPixel(&art, 5, 12, C_WATER_LIGHT)
	ArtPixel(&art, 8, 12, C_EFFECT_BAD)
	ArtPixel(&art, 11, 12, C_LEAF_LIGHT)
	return art
}

// One 16x16 symbol per technology. The art is scaled up in the Crown panel so
// every node reads at a glance without a status sentence.
DrawCrownTechIcon :: proc(tech: CrownTech) -> Art {
	art := ArtInit(16, 16)
	switch tech {
	case .CoastalBoats:
		ArtRect(&art, 1, 14, 14, 1, C_WATER_DARK)
		ArtPixel(&art, 3, 13, C_WATER)
		ArtPixel(&art, 12, 13, C_WATER)
		ArtPolygon(&art, []Point{{2, 9}, {14, 9}, {12, 12}, {4, 12}}, C_OUTLINE)
		ArtPolygon(&art, []Point{{3, 10}, {13, 10}, {11, 11}, {5, 11}}, C_WOOD)
		ArtRect(&art, 7, 2, 2, 8, C_OUTLINE)
		ArtRect(&art, 8, 3, 1, 6, C_WOOD_LIGHT)
		ArtTriangle(&art, 9, 3, 13, 8, 9, 8, C_OUTLINE)
		ArtTriangle(&art, 10, 4, 12, 8, 10, 8, C_CLOTH_LIGHT)
	case .FishingFlotillas:
		ArtRect(&art, 1, 11, 7, 1, C_OUTLINE)
		ArtRect(&art, 2, 10, 5, 1, C_WOOD)
		ArtEllipse(&art, 9, 7, 4, 2, C_OUTLINE)
		ArtEllipse(&art, 9, 7, 3, 1, C_WATER_LIGHT)
		ArtTriangle(&art, 4, 7, 2, 4, 2, 10, C_OUTLINE)
		ArtTriangle(&art, 4, 7, 3, 5, 3, 9, C_WATER)
		ArtPixel(&art, 11, 6, C_OUTLINE)
		ArtEllipse(&art, 11, 13, 2, 1, C_OUTLINE)
		ArtPixel(&art, 13, 12, C_WATER)
	case .Harbor:
		ArtCircle(&art, 8, 3, 2, C_OUTLINE)
		ArtCircle(&art, 8, 3, 1, C_GOLD)
		ArtRect(&art, 7, 4, 2, 9, C_OUTLINE)
		ArtRect(&art, 8, 5, 1, 7, C_GOLD)
		ArtRect(&art, 4, 7, 8, 1, C_OUTLINE)
		ArtLine(&art, 4, 10, 6, 13, C_OUTLINE)
		ArtLine(&art, 6, 13, 8, 11, C_OUTLINE)
		ArtLine(&art, 12, 10, 10, 13, C_OUTLINE)
		ArtLine(&art, 10, 13, 8, 11, C_OUTLINE)
		ArtLine(&art, 4, 9, 6, 12, C_GOLD)
		ArtLine(&art, 6, 12, 8, 10, C_GOLD)
		ArtLine(&art, 12, 9, 10, 12, C_GOLD)
		ArtLine(&art, 10, 12, 8, 10, C_GOLD)
	case .SeaPower:
		ArtRect(&art, 7, 4, 2, 10, C_OUTLINE)
		ArtRect(&art, 8, 5, 1, 8, C_STONE_LIGHT)
		ArtRect(&art, 2, 7, 12, 2, C_OUTLINE)
		ArtRect(&art, 3, 8, 10, 1, C_STONE)
		ArtRect(&art, 3, 4, 2, 4, C_OUTLINE)
		ArtRect(&art, 4, 5, 1, 2, C_STONE_LIGHT)
		ArtRect(&art, 11, 4, 2, 4, C_OUTLINE)
		ArtRect(&art, 12, 5, 1, 2, C_STONE_LIGHT)
		ArtTriangle(&art, 2, 4, 4, 2, 5, 5, C_OUTLINE)
		ArtTriangle(&art, 3, 4, 4, 3, 4, 5, C_WHITE)
		ArtTriangle(&art, 10, 5, 12, 2, 13, 4, C_OUTLINE)
		ArtTriangle(&art, 11, 4, 12, 3, 12, 5, C_WHITE)
		ArtTriangle(&art, 7, 4, 8, 1, 9, 4, C_OUTLINE)
		ArtPixel(&art, 8, 2, C_WHITE)
		ArtRect(&art, 1, 14, 14, 1, C_WATER_DARK)
		ArtPixel(&art, 4, 13, C_WATER_LIGHT)
		ArtPixel(&art, 11, 13, C_WATER_LIGHT)
	case .Blockade:
		ArtCircle(&art, 5, 6, 3, C_OUTLINE)
		ArtCircle(&art, 5, 6, 2, C_IRON_LIGHT)
		ArtCircle(&art, 5, 6, 1, C_CLEAR)
		ArtCircle(&art, 10, 10, 3, C_OUTLINE)
		ArtCircle(&art, 10, 10, 2, C_IRON)
		ArtCircle(&art, 10, 10, 1, C_CLEAR)
		ArtLine(&art, 2, 13, 14, 3, C_OUTLINE)
		ArtLine(&art, 3, 13, 14, 4, C_EFFECT_BAD)
	case .CropRotation:
		ArtRect(&art, 7, 3, 2, 11, C_OUTLINE)
		ArtRect(&art, 8, 4, 1, 9, C_GOLD)
		for row in 0..<3 {
			y := 4+row*3
			ArtRect(&art, 4, y, 3, 2, C_OUTLINE)
			ArtRect(&art, 4, y, 2, 1, C_GOLD_LIGHT)
			ArtRect(&art, 9, y, 3, 2, C_OUTLINE)
			ArtRect(&art, 10, y, 2, 1, C_GOLD_LIGHT)
		}
		ArtLine(&art, 3, 8, 3, 11, C_LEAF)
		ArtLine(&art, 3, 11, 5, 11, C_LEAF)
		ArtTriangle(&art, 6, 11, 4, 9, 4, 13, C_LEAF_LIGHT)
		ArtLine(&art, 13, 8, 13, 5, C_LEAF)
		ArtLine(&art, 13, 5, 11, 5, C_LEAF)
		ArtTriangle(&art, 10, 5, 12, 3, 12, 7, C_LEAF_LIGHT)
	case .Irrigation:
		ArtTriangle(&art, 8, 1, 3, 8, 13, 8, C_OUTLINE)
		ArtCircle(&art, 8, 9, 5, C_OUTLINE)
		ArtTriangle(&art, 8, 2, 4, 8, 12, 8, C_WATER)
		ArtCircle(&art, 8, 9, 4, C_WATER)
		ArtEllipse(&art, 6, 8, 1, 2, C_WATER_LIGHT)
		ArtLine(&art, 1, 13, 5, 13, C_LEAF_DARK)
		ArtLine(&art, 11, 13, 15, 13, C_LEAF_DARK)
		ArtLine(&art, 2, 15, 6, 15, C_LEAF)
		ArtLine(&art, 10, 15, 14, 15, C_LEAF)
	case .Granary:
		ArtEllipse(&art, 8, 10, 5, 4, C_OUTLINE)
		ArtEllipse(&art, 8, 10, 4, 3, C_WOOD_LIGHT)
		ArtRect(&art, 6, 3, 4, 3, C_OUTLINE)
		ArtRect(&art, 7, 4, 2, 1, C_WOOD_DARK)
		ArtRect(&art, 6, 6, 4, 1, C_GOLD_DARK)
		ArtRect(&art, 8, 8, 1, 4, C_GOLD)
		ArtPixel(&art, 7, 9, C_GOLD)
		ArtPixel(&art, 9, 9, C_GOLD)
		ArtPixel(&art, 7, 11, C_GOLD)
		ArtPixel(&art, 9, 11, C_GOLD)
	case .LandReclamation:
		ArtRect(&art, 1, 13, 14, 2, C_DIRT_DARK)
		ArtRect(&art, 1, 13, 14, 1, C_LEAF_DARK)
		ArtLine(&art, 3, 12, 10, 4, C_OUTLINE)
		ArtLine(&art, 4, 12, 11, 4, C_OUTLINE)
		ArtLine(&art, 4, 12, 11, 4, C_WOOD_LIGHT)
		ArtPolygon(&art, []Point{{10, 1}, {15, 1}, {15, 6}, {10, 5}}, C_OUTLINE)
		ArtPolygon(&art, []Point{{11, 2}, {14, 2}, {14, 5}, {11, 4}}, C_STONE_LIGHT)
		ArtRect(&art, 1, 10, 3, 3, C_OUTLINE)
		ArtRect(&art, 2, 11, 1, 1, C_WOOD)
	case .Metropolis:
		ArtRect(&art, 1, 13, 14, 2, C_OUTLINE)
		ArtRect(&art, 2, 13, 12, 1, C_STONE_DARK)
		ArtRect(&art, 2, 8, 3, 5, C_OUTLINE)
		ArtRect(&art, 3, 9, 1, 4, C_STONE)
		ArtRect(&art, 11, 7, 3, 6, C_OUTLINE)
		ArtRect(&art, 12, 8, 1, 5, C_STONE)
		ArtRect(&art, 6, 4, 4, 9, C_OUTLINE)
		ArtRect(&art, 7, 5, 2, 8, C_STONE_LIGHT)
		ArtTriangle(&art, 2, 8, 3, 5, 5, 8, C_OUTLINE)
		ArtTriangle(&art, 3, 8, 4, 6, 4, 8, C_ROOF)
		ArtTriangle(&art, 6, 4, 8, 1, 10, 4, C_OUTLINE)
		ArtTriangle(&art, 7, 4, 8, 2, 9, 4, C_ROOF)
		ArtTriangle(&art, 11, 7, 12, 4, 14, 7, C_OUTLINE)
		ArtTriangle(&art, 12, 7, 13, 5, 13, 7, C_ROOF)
		ArtPixel(&art, 8, 6, C_GOLD)
		ArtPixel(&art, 8, 9, C_GOLD)
		ArtPixel(&art, 3, 10, C_GOLD)
		ArtPixel(&art, 12, 9, C_GOLD)
	case .Carpentry:
		ArtRect(&art, 1, 11, 14, 3, C_OUTLINE)
		ArtRect(&art, 2, 12, 12, 1, C_WOOD)
		ArtLine(&art, 4, 10, 9, 4, C_OUTLINE)
		ArtLine(&art, 5, 10, 10, 4, C_OUTLINE)
		ArtLine(&art, 5, 10, 10, 4, C_WOOD_LIGHT)
		ArtRect(&art, 8, 1, 5, 4, C_OUTLINE)
		ArtRect(&art, 9, 2, 3, 2, C_IRON_LIGHT)
		ArtPixel(&art, 10, 2, C_STONE_LIGHT)
	case .Masonry:
		ArtRect(&art, 1, 3, 14, 11, C_OUTLINE)
		for row in 0..<3 {
			y := 4+row*3
			ArtRect(&art, 2, y, 12, 2, C_STONE)
			ArtRect(&art, 2, y, 12, 1, C_STONE_LIGHT)
			offset := row%2 == 0 ? 0 : 2
			for gap in 0..<3 {
				x := 3+offset+gap*4
				ArtRect(&art, x, y, 1, 2, C_STONE_DARK)
			}
			ArtRect(&art, 2, y+2, 12, 1, C_OUTLINE)
		}
	case .Roadworks:
		ArtPolygon(&art, []Point{{3, 14}, {13, 14}, {9, 3}, {7, 3}}, C_OUTLINE)
		ArtPolygon(&art, []Point{{4, 14}, {12, 14}, {9, 4}, {8, 4}}, C_DIRT)
		ArtRect(&art, 8, 11, 1, 2, C_GOLD)
		ArtRect(&art, 8, 8, 1, 2, C_GOLD)
		ArtRect(&art, 8, 5, 1, 1, C_GOLD)
		ArtPixel(&art, 6, 12, C_DIRT_DARK)
		ArtPixel(&art, 10, 11, C_DIRT_DARK)
		ArtPixel(&art, 9, 7, C_DIRT_DARK)
	case .Bridgeworks:
		ArtRect(&art, 1, 14, 14, 1, C_WATER_DARK)
		ArtRect(&art, 1, 6, 14, 2, C_OUTLINE)
		ArtRect(&art, 2, 6, 12, 1, C_STONE_LIGHT)
		ArtRect(&art, 2, 8, 2, 6, C_OUTLINE)
		ArtRect(&art, 3, 9, 1, 5, C_STONE)
		ArtRect(&art, 12, 8, 2, 6, C_OUTLINE)
		ArtRect(&art, 12, 9, 1, 5, C_STONE)
		ArtLine(&art, 4, 13, 5, 9, C_OUTLINE)
		ArtLine(&art, 5, 9, 11, 9, C_OUTLINE)
		ArtLine(&art, 11, 9, 12, 13, C_OUTLINE)
		ArtLine(&art, 5, 12, 6, 10, C_STONE)
		ArtLine(&art, 6, 10, 10, 10, C_STONE)
		ArtLine(&art, 10, 10, 11, 12, C_STONE)
		ArtPixel(&art, 8, 9, C_GOLD)
	case .BridgeProject:
		ArtRect(&art, 1, 14, 14, 1, C_WATER_DARK)
		ArtRect(&art, 0, 6, 16, 2, C_OUTLINE)
		ArtRect(&art, 1, 6, 14, 1, C_STONE_LIGHT)
		ArtRect(&art, 1, 8, 2, 6, C_OUTLINE)
		ArtRect(&art, 13, 8, 2, 6, C_OUTLINE)
		ArtRect(&art, 7, 8, 2, 6, C_OUTLINE)
		ArtRect(&art, 2, 9, 1, 5, C_STONE)
		ArtRect(&art, 8, 9, 1, 5, C_STONE)
		ArtRect(&art, 13, 9, 1, 5, C_STONE)
		ArtLine(&art, 3, 13, 4, 9, C_OUTLINE)
		ArtLine(&art, 4, 9, 6, 9, C_OUTLINE)
		ArtLine(&art, 6, 9, 7, 13, C_OUTLINE)
		ArtLine(&art, 9, 13, 10, 9, C_OUTLINE)
		ArtLine(&art, 10, 9, 12, 9, C_OUTLINE)
		ArtLine(&art, 12, 9, 13, 13, C_OUTLINE)
		ArtRect(&art, 8, 1, 1, 5, C_OUTLINE)
		ArtPolygon(&art, []Point{{9, 1}, {14, 2}, {9, 5}}, C_ROOF)
		ArtPixel(&art, 10, 2, C_GOLD)
	case .Charters:
		ArtRect(&art, 3, 2, 10, 12, C_OUTLINE)
		ArtRect(&art, 4, 3, 8, 10, C_STONE_LIGHT)
		ArtRect(&art, 2, 2, 2, 12, C_OUTLINE)
		ArtRect(&art, 12, 2, 2, 12, C_OUTLINE)
		ArtRect(&art, 3, 3, 1, 10, C_WOOD_LIGHT)
		ArtRect(&art, 12, 3, 1, 10, C_WOOD_LIGHT)
		ArtRect(&art, 5, 5, 5, 1, C_STONE_DARK)
		ArtRect(&art, 5, 7, 5, 1, C_STONE_DARK)
		ArtCircle(&art, 8, 11, 2, C_OUTLINE)
		ArtCircle(&art, 8, 11, 1, C_EFFECT_BAD)
	case .Census:
		ArtRect(&art, 1, 3, 10, 11, C_OUTLINE)
		ArtRect(&art, 2, 4, 8, 9, C_STONE_LIGHT)
		ArtRect(&art, 5, 4, 1, 9, C_STONE_DARK)
		for row in 0..<3 {
			y := 6+row*2
			ArtRect(&art, 3, y, 2, 1, C_STONE_DARK)
			ArtRect(&art, 6, y, 3, 1, C_STONE_DARK)
		}
		ArtLine(&art, 9, 13, 14, 2, C_OUTLINE)
		ArtLine(&art, 10, 13, 15, 3, C_WHITE)
		ArtLine(&art, 11, 9, 13, 5, C_STONE_LIGHT)
	case .Bureaucracy:
		ArtRect(&art, 6, 1, 4, 3, C_OUTLINE)
		ArtRect(&art, 7, 2, 2, 1, C_WOOD)
		ArtRect(&art, 6, 4, 4, 4, C_OUTLINE)
		ArtRect(&art, 7, 5, 2, 2, C_STONE_LIGHT)
		ArtRect(&art, 3, 8, 10, 4, C_OUTLINE)
		ArtRect(&art, 4, 9, 8, 2, C_IRON_LIGHT)
		ArtRect(&art, 4, 12, 8, 2, C_EFFECT_BAD)
		ArtPixel(&art, 6, 13, C_OUTLINE)
		ArtPixel(&art, 10, 13, C_OUTLINE)
	case .Surveyors:
		ArtCircle(&art, 8, 8, 6, C_OUTLINE)
		ArtCircle(&art, 8, 8, 5, C_STONE_LIGHT)
		ArtTriangle(&art, 8, 8, 5, 4, 9, 9, C_EFFECT_BAD)
		ArtTriangle(&art, 8, 8, 11, 12, 7, 7, C_WHITE)
		ArtPixel(&art, 8, 8, C_GOLD)
		ArtPixel(&art, 8, 2, C_STONE_DARK)
		ArtPixel(&art, 8, 14, C_STONE_DARK)
		ArtPixel(&art, 2, 8, C_STONE_DARK)
		ArtPixel(&art, 14, 8, C_STONE_DARK)
	case .HighCouncil:
		ArtEllipse(&art, 8, 12, 7, 3, C_OUTLINE)
		ArtEllipse(&art, 8, 12, 6, 2, C_WOOD_LIGHT)
		ArtCircle(&art, 3, 6, 2, C_OUTLINE)
		ArtCircle(&art, 3, 6, 1, C_CLOTH_LIGHT)
		ArtCircle(&art, 13, 6, 2, C_OUTLINE)
		ArtCircle(&art, 13, 6, 1, C_CLOTH_LIGHT)
		ArtCircle(&art, 8, 5, 2, C_OUTLINE)
		ArtCircle(&art, 8, 5, 1, C_GOLD)
		ArtRect(&art, 6, 2, 5, 1, C_OUTLINE)
		ArtPixel(&art, 6, 2, C_GOLD_LIGHT)
		ArtPixel(&art, 8, 1, C_GOLD_LIGHT)
		ArtPixel(&art, 10, 2, C_GOLD_LIGHT)
	case .Drill:
		ArtLine(&art, 2, 13, 12, 4, C_OUTLINE)
		ArtLine(&art, 3, 13, 13, 4, C_STONE_LIGHT)
		ArtLine(&art, 13, 13, 4, 4, C_OUTLINE)
		ArtLine(&art, 12, 13, 3, 4, C_STONE_LIGHT)
		ArtRect(&art, 1, 11, 3, 2, C_OUTLINE)
		ArtRect(&art, 1, 11, 2, 1, C_GOLD)
		ArtRect(&art, 12, 11, 3, 2, C_OUTLINE)
		ArtRect(&art, 13, 11, 2, 1, C_GOLD)
		ArtPixel(&art, 1, 13, C_GOLD_LIGHT)
		ArtPixel(&art, 14, 13, C_GOLD_LIGHT)
	case .Armory:
		ArtPolygon(&art, []Point{{8, 1}, {14, 3}, {13, 10}, {8, 14}, {3, 10}, {2, 3}}, C_OUTLINE)
		ArtPolygon(&art, []Point{{8, 2}, {13, 4}, {12, 9}, {8, 12}, {4, 9}, {3, 4}}, C_IRON)
		ArtRect(&art, 7, 4, 2, 7, C_STONE_LIGHT)
		ArtRect(&art, 5, 6, 6, 1, C_GOLD)
		ArtPixel(&art, 8, 2, C_WHITE)
		ArtPixel(&art, 8, 12, C_GOLD_DARK)
	case .Fortification:
		ArtRect(&art, 1, 6, 14, 8, C_OUTLINE)
		ArtRect(&art, 2, 7, 12, 6, C_STONE)
		ArtRect(&art, 2, 7, 12, 1, C_STONE_LIGHT)
		ArtRect(&art, 2, 3, 3, 3, C_OUTLINE)
		ArtRect(&art, 3, 3, 1, 2, C_STONE_LIGHT)
		ArtRect(&art, 7, 3, 2, 3, C_OUTLINE)
		ArtRect(&art, 8, 3, 1, 2, C_STONE_LIGHT)
		ArtRect(&art, 11, 3, 3, 3, C_OUTLINE)
		ArtRect(&art, 12, 3, 1, 2, C_STONE_LIGHT)
		ArtRect(&art, 6, 9, 4, 4, C_OUTLINE)
		ArtRect(&art, 7, 10, 2, 3, C_WOOD_DARK)
	case .Siegecraft:
		ArtRect(&art, 1, 10, 14, 3, C_OUTLINE)
		ArtRect(&art, 2, 11, 12, 1, C_WOOD)
		ArtCircle(&art, 4, 13, 2, C_OUTLINE)
		ArtCircle(&art, 4, 13, 1, C_STONE_DARK)
		ArtCircle(&art, 12, 13, 2, C_OUTLINE)
		ArtCircle(&art, 12, 13, 1, C_STONE_DARK)
		ArtLine(&art, 5, 10, 11, 3, C_OUTLINE)
		ArtLine(&art, 6, 10, 12, 3, C_WOOD_LIGHT)
		ArtRect(&art, 10, 1, 4, 3, C_OUTLINE)
		ArtRect(&art, 11, 2, 2, 1, C_STONE_LIGHT)
		ArtRect(&art, 2, 7, 3, 3, C_OUTLINE)
		ArtRect(&art, 3, 8, 1, 1, C_IRON)
	case .Muster:
		ArtRect(&art, 3, 1, 2, 14, C_OUTLINE)
		ArtRect(&art, 4, 2, 1, 12, C_WOOD_LIGHT)
		ArtPolygon(&art, []Point{{4, 2}, {4, 9}, {15, 4}}, C_OUTLINE)
		ArtPolygon(&art, []Point{{5, 3}, {5, 8}, {13, 5}}, C_ROOF)
		ArtLine(&art, 7, 4, 10, 7, C_GOLD)
		ArtLine(&art, 10, 4, 7, 7, C_GOLD)
		ArtRect(&art, 1, 14, 6, 1, C_STONE_DARK)
	}
	return art
}

@(private = "file")
DrawWoodLogIcon :: proc(art: ^Art, x, y: int) {
	ArtRect(art, x, y, 13, 5, C_OUTLINE)
	ArtRect(art, x+1, y+1, 11, 3, C_WOOD)
	ArtRect(art, x+1, y+1, 11, 1, C_WOOD_LIGHT)
	ArtRect(art, x+3, y+3, 6, 1, C_WOOD_DARK)
	// Light cut face on the right end.
	ArtRect(art, x+10, y+1, 2, 3, C_WOOD_LIGHT)
	ArtRect(art, x+10, y+2, 2, 1, C_WOOD_DARK)
}

SpriteSet :: struct {
	building:        [SPRITE_FACTION_COUNT][BuildingKind]rl.Texture2D,
	buildingDamaged: [SPRITE_FACTION_COUNT][BuildingKind][2]rl.Texture2D,
	unit:            [SPRITE_FACTION_COUNT][UnitKind]rl.Texture2D,
	unitWalk:        [SPRITE_FACTION_COUNT][UnitKind][2]rl.Texture2D,
	unitHurt:        [SPRITE_FACTION_COUNT][UnitKind][2]rl.Texture2D,
	unitHurtWalk:    [SPRITE_FACTION_COUNT][UnitKind][2][2]rl.Texture2D,
	decoration:      [DecorationKind]rl.Texture2D,
	construction:    [SPRITE_FACTION_COUNT]rl.Texture2D,
	bloodSplat:      [BLOOD_SPLAT_VARIANTS]rl.Texture2D,
	bloodPool:       [BLOOD_POOL_VARIANTS]rl.Texture2D,
	gore:            [SPRITE_FACTION_COUNT][UnitKind][GorePartKind]rl.Texture2D,
	particle:        [ParticleKind]rl.Texture2D,
	effect:          [UnitEffects]rl.Texture2D,
	fire:            rl.Texture2D,
	shadow:          rl.Texture2D,
	glow:            rl.Texture2D,
	woodIcon:        rl.Texture2D,
	crownIcon:       rl.Texture2D,
	techIcon:        [CrownTech]rl.Texture2D,
	boat:            rl.Texture2D,
}

SpriteSetInit :: proc(w: ^World) -> SpriteSet {
	set: SpriteSet
	set.shadow = CreateShadowTexture()
	set.glow = CreateGlowTexture()
	set.boat = CreateBoatTexture()
	for faction in 0 ..< SPRITE_FACTION_COUNT {
		accent := FactionColor(w, faction)
		for kind in ALL_BUILDING_KINDS {
			art: Art
			if faction == NEUTRAL_KINGDOM && kind == .TownHall {
				width, height := BuildingTileSize(TownHall{})
				art = ArtInit(width*PIXELS_PER_TILE, height*PIXELS_PER_TILE)
				DrawIndependentTownHall(&art, accent)
			} else {
				art = DrawBuildingSprite(kind, accent)
			}
			ArtGrain(&art, u64(kind)+1)
			set.building[faction][kind] = ArtToTexture(art)
			damageSeed := u64(faction)*0x9E3779B97F4A7C15 ~ u64(kind)*0x85EBCA6B ~ 0xB0DE
			damage1 := DamageBuildingArt(art, 1, damageSeed)
			set.buildingDamaged[faction][kind][0] = ArtToTexture(damage1)
			damage2 := DamageBuildingArt(damage1, 2, damageSeed)
			set.buildingDamaged[faction][kind][1] = ArtToTexture(damage2)
			rl.UnloadImage(damage2.image)
			rl.UnloadImage(damage1.image)
			rl.UnloadImage(art.image)
		}
		for kind in ALL_UNIT_KINDS {
			art := DrawUnitSprite(kind, accent)
			set.unit[faction][kind] = ArtToTexture(art)
			hasWalk := UnitKindHasWalkFrames(kind)
			if hasWalk {
				for frame in 0..<2 {
					shift := frame == 0 ? -1 : 1
					walkArt := UnitWalkFrame(art, shift)
					set.unitWalk[faction][kind][frame] = ArtToTexture(walkArt)
					rl.UnloadImage(walkArt.image)
				}
			}
			hurtSeed := u64(faction)*0x9E3779B97F4A7C15 ~ u64(kind)*0x85EBCA6B ~ 0xE0DE
			hurt1 := DamageUnitArt(art, kind, 1, hurtSeed)
			set.unitHurt[faction][kind][0] = ArtToTexture(hurt1)
			if hasWalk {
				for frame in 0..<2 {
					shift := frame == 0 ? -1 : 1
					hurtWalk := UnitWalkFrame(hurt1, shift)
					set.unitHurtWalk[faction][kind][0][frame] = ArtToTexture(hurtWalk)
					rl.UnloadImage(hurtWalk.image)
				}
			}
			hurt2 := DamageUnitArt(hurt1, kind, 2, hurtSeed)
			set.unitHurt[faction][kind][1] = ArtToTexture(hurt2)
			if hasWalk {
				for frame in 0..<2 {
					shift := frame == 0 ? -1 : 1
					hurtWalk := UnitWalkFrame(hurt2, shift)
					set.unitHurtWalk[faction][kind][1][frame] = ArtToTexture(hurtWalk)
					rl.UnloadImage(hurtWalk.image)
				}
			}
			rl.UnloadImage(hurt2.image)
			rl.UnloadImage(hurt1.image)
			rl.UnloadImage(art.image)
		}
		art := DrawConstructionSprite(accent)
		ArtGrain(&art, u64(faction)+701)
		set.construction[faction] = ArtToTexture(art)
		rl.UnloadImage(art.image)

		for kind in ALL_UNIT_KINDS {
			if kind == .Catapult do continue
			for part in ALL_GORE_PARTS {
				goreArt := DrawGorePart(kind, part, accent)
				set.gore[faction][kind][part] = ArtToTexture(goreArt)
				rl.UnloadImage(goreArt.image)
			}
		}
	}
	for kind in ALL_DECORATION_KINDS {
		art := DrawDecorationSprite(kind)
		ArtGrain(&art, u64(kind)+301)
		set.decoration[kind] = ArtToTexture(art)
		rl.UnloadImage(art.image)
	}
	for kind in ALL_PARTICLE_KINDS {
		set.particle[kind] = CreateParticleKindTexture(kind)
	}
	for effect in ALL_UNIT_EFFECTS {
		art := DrawEffectIcon(effect)
		set.effect[effect] = ArtToTexture(art)
		rl.UnloadImage(art.image)
	}
	for variant in 0 ..< BLOOD_SPLAT_VARIANTS {
		set.bloodSplat[variant] = ArtTakeTexture(
			DrawBloodSplatArt(u64(variant)+1, BLOOD_SPLAT_TEXTURE_SIZE, false),
		)
	}
	for variant in 0 ..< BLOOD_POOL_VARIANTS {
		set.bloodPool[variant] = ArtTakeTexture(
			DrawBloodSplatArt(u64(variant)+101, BLOOD_POOL_TEXTURE_SIZE, true),
		)
	}
	set.fire = ArtToTexture(DrawFireSprite())
	set.woodIcon = ArtTakeTexture(DrawWoodIcon())
	set.crownIcon = ArtTakeTexture(DrawCrownIcon())
	for tech in CrownTech {
		set.techIcon[tech] = ArtTakeTexture(DrawCrownTechIcon(tech))
	}
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
			for stage in 0..<2 {
				if set.buildingDamaged[faction][kind][stage].id != 0 {
					rl.UnloadTexture(set.buildingDamaged[faction][kind][stage])
				}
			}
		}
		for kind in ALL_UNIT_KINDS {
			if set.unit[faction][kind].id != 0 {
				rl.UnloadTexture(set.unit[faction][kind])
			}
			for frame in 0..<2 {
				if set.unitWalk[faction][kind][frame].id != 0 {
					rl.UnloadTexture(set.unitWalk[faction][kind][frame])
				}
			}
			for stage in 0..<2 {
				if set.unitHurt[faction][kind][stage].id != 0 {
					rl.UnloadTexture(set.unitHurt[faction][kind][stage])
				}
				for frame in 0..<2 {
					if set.unitHurtWalk[faction][kind][stage][frame].id != 0 {
						rl.UnloadTexture(set.unitHurtWalk[faction][kind][stage][frame])
					}
				}
			}
		}
		if set.construction[faction].id != 0 {
			rl.UnloadTexture(set.construction[faction])
		}
		for kind in ALL_UNIT_KINDS {
			if kind == .Catapult do continue
			for part in ALL_GORE_PARTS {
				if set.gore[faction][kind][part].id != 0 {
					rl.UnloadTexture(set.gore[faction][kind][part])
				}
			}
		}
	}
	for kind in ALL_DECORATION_KINDS {
		if set.decoration[kind].id != 0 {
			rl.UnloadTexture(set.decoration[kind])
		}
	}
	for kind in ALL_PARTICLE_KINDS {
		if set.particle[kind].id != 0 {
			rl.UnloadTexture(set.particle[kind])
		}
	}
	for effect in ALL_UNIT_EFFECTS {
		if set.effect[effect].id != 0 {
			rl.UnloadTexture(set.effect[effect])
		}
	}
	for variant in 0 ..< BLOOD_SPLAT_VARIANTS {
		if set.bloodSplat[variant].id != 0 {
			rl.UnloadTexture(set.bloodSplat[variant])
		}
	}
	for variant in 0 ..< BLOOD_POOL_VARIANTS {
		if set.bloodPool[variant].id != 0 {
			rl.UnloadTexture(set.bloodPool[variant])
		}
	}
	if set.fire.id != 0 do rl.UnloadTexture(set.fire)
	if set.woodIcon.id != 0 do rl.UnloadTexture(set.woodIcon)
	if set.crownIcon.id != 0 do rl.UnloadTexture(set.crownIcon)
	for tech in CrownTech {
		if set.techIcon[tech].id != 0 do rl.UnloadTexture(set.techIcon[tech])
	}
	if set.boat.id != 0 do rl.UnloadTexture(set.boat)
}
