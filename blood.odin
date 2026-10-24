package main

import rl "vendor:raylib"
import "core:math"

// ---------------------------------------------------------------------------
// Blood
//
// Two cooperating layers keep battlefields cheap and gory:
//   * a per-tile u8 saturation grid that is uploaded as one low-res texture.
//     Heavy fighting fills tiles until the blood "flows" into neighbours,
//     which is what creates lakes that keep growing after a slaughter.
//   * a ring of decals drawn as procedurally generated splat sprites. The
//     decals carry the crisp, irregular shapes; the grid provides the bulk.
// ---------------------------------------------------------------------------

BLOOD_DECAL_CAPACITY :: 12288
BLOOD_DECAL_MIN_ZOOM :: 5
BLOOD_TILE_SPLAT_MIN_ZOOM :: 9
BLOOD_SPLAT_VARIANTS :: 8
BLOOD_POOL_VARIANTS :: 4
BLOOD_SPREAD_THRESHOLD :: 42
BLOOD_DIRTY_BLOCK :: 32
BLOOD_BLOCK_UPLOADS_PER_FRAME :: 64
BLOOD_TINT_RED :: u8(0)
BLOOD_TINT_DARK :: u8(1)
BLOOD_TINT_GREEN :: u8(2)
BLOOD_TINT_VIOLET :: u8(3)
BLOOD_TINT_COUNT :: 4
BLOOD_TINT_NONE :: u8(255)

BLOOD_PALETTE := [BLOOD_TINT_COUNT]rl.Color {
	rl.Color{158, 22, 26, 255},
	rl.Color{104, 12, 18, 255},
	rl.Color{76, 108, 58, 255},
	rl.Color{118, 42, 120, 255},
}

C_BONE := rl.Color{232, 222, 190, 255}
C_ENTRAIL := rl.Color{196, 92, 96, 255}
C_ENTRAIL_DARK := rl.Color{118, 34, 44, 255}

// Greyscale art is tinted with BLOOD_PALETTE, so one texture serves every
// creature that bleeds a different colour.
C_SPLAT_DEEP := rl.Color{92, 92, 100, 255}
C_SPLAT_DARK := rl.Color{138, 138, 146, 255}
C_SPLAT_MID := rl.Color{198, 198, 206, 255}
C_SPLAT_LIGHT := rl.Color{244, 244, 250, 255}

BloodField :: struct {
	amount:      []u8,
	tint:        []u8,
	wet:         []bool,
	active:      [dynamic]int,
	pending:     [dynamic]int,
	decals:      []BloodDecal,
	decalCursor: int,
	decalCount:  int,
	dirtyMarker: []bool,
	dirtyList:   [dynamic]int,
}

BloodDecal :: struct {
	x, y:       f32,
	size:       f32,
	rotation:   f32,
	life:       f32,
	maxLife:    f32,
	variant:    u8,
	tint:       u8,
	brightness: u8,
	pool:       bool,
}

GorePartKind :: enum {
	Head,
	Arm,
	Leg,
	Torso,
	Hand,
	Intestine,
}

GORE_PART_COUNT :: 6

ALL_GORE_PARTS := [GORE_PART_COUNT]GorePartKind {
	.Head,
	.Arm,
	.Leg,
	.Torso,
	.Hand,
	.Intestine,
}

DamageKind :: enum {
	Melee,
	Projectile,
	Area,
	Fire,
}

BloodInit :: proc(w: ^World) -> bool {
	count := int(w.maxX)*int(w.maxY)
	if count <= 0 do return false
	w.blood.amount = make([]u8, count)
	w.blood.tint = make([]u8, count)
	w.blood.wet = make([]bool, count)
	w.blood.active = make([dynamic]int, 0, 4096)
	w.blood.pending = make([dynamic]int, 0, 512)
	w.blood.decals = make([]BloodDecal, BLOOD_DECAL_CAPACITY)
	blocks_x := (int(w.maxX)+BLOOD_DIRTY_BLOCK-1)/BLOOD_DIRTY_BLOCK
	blocks_y := (int(w.maxY)+BLOOD_DIRTY_BLOCK-1)/BLOOD_DIRTY_BLOCK
	w.blood.dirtyMarker = make([]bool, max(blocks_x*blocks_y, 1))
	w.blood.dirtyList = make([dynamic]int, 0, 256)
	return true
}

BloodDeinit :: proc(w: ^World) {
	delete(w.blood.amount)
	delete(w.blood.tint)
	delete(w.blood.wet)
	delete(w.blood.active)
	delete(w.blood.pending)
	delete(w.blood.decals)
	delete(w.blood.dirtyMarker)
	delete(w.blood.dirtyList)
}

BloodTintForUnitType :: proc(type: UnitType) -> u8 {
	switch UnitKindOf(type) {
	case .Turtle:
		return BLOOD_TINT_GREEN
	case .Mage:
		return BLOOD_TINT_VIOLET
	case .Giant:
		return BLOOD_TINT_DARK
	case .Catapult:
		return BLOOD_TINT_NONE
	case .Villager, .Builder, .CombatBuilder, .WaterCollector, .Farmer, .Knight, .Archer, .Rogue, .Explorer:
		return BLOOD_TINT_RED
	}
	unreachable()
}

BloodTintFromParticle :: proc(color: rl.Color) -> u8 {
	if color.r > 200 && color.g > 200 && color.b > 200 do return BLOOD_TINT_RED
	best := BLOOD_TINT_RED
	best_distance := 1 << 30
	for i in 0 ..< BLOOD_TINT_COUNT {
		base := BLOOD_PALETTE[i]
		dr := int(color.r)-int(base.r)
		dg := int(color.g)-int(base.g)
		db := int(color.b)-int(base.b)
		distance := dr*dr+dg*dg+db*db
		if distance < best_distance {
			best_distance = distance
			best = u8(i)
		}
	}
	return best
}

BloodPaletteColor :: proc(tint: u8) -> rl.Color {
	index := clamp(int(tint), 0, BLOOD_TINT_COUNT-1)
	return BLOOD_PALETTE[index]
}

BloodMarkDirty :: proc(w: ^World, x, y: int) {
	blocks_y := (int(w.maxY)+BLOOD_DIRTY_BLOCK-1)/BLOOD_DIRTY_BLOCK
	if blocks_y <= 0 do return
	block := (x/BLOOD_DIRTY_BLOCK)*blocks_y+y/BLOOD_DIRTY_BLOCK
	if block < 0 || block >= len(w.blood.dirtyMarker) do return
	if w.blood.dirtyMarker[block] do return
	w.blood.dirtyMarker[block] = true
	append(&w.blood.dirtyList, block)
}

BloodAddTile :: proc(w: ^World, x, y, amount: int, tint: u8, pending: bool) {
	world_height := int(w.maxY)
	index := x*world_height+y
	if index < 0 || index >= len(w.blood.amount) do return
	current := int(w.blood.amount[index])
	next := min(255, current+amount)
	if next == current do return

	w.blood.amount[index] = u8(next)
	if current == 0 || amount >= 6 {
		w.blood.tint[index] = min(tint, u8(BLOOD_TINT_COUNT-1))
	}
	BloodMarkDirty(w, x, y)

	if next >= BLOOD_SPREAD_THRESHOLD && !w.blood.wet[index] {
		w.blood.wet[index] = true
		if pending {
			append(&w.blood.pending, index)
		} else {
			append(&w.blood.active, index)
		}
	}
}

BloodAddAt :: proc(w: ^World, x, y: f32, amount: f32, radius: f32, tint: u8) {
	world_width := int(w.maxX)
	world_height := int(w.maxY)
	if world_width <= 0 || world_height <= 0 || amount <= 0 || radius <= 0 do return

	first_x := int(math.floor(x-radius))
	last_x := int(math.ceil(x+radius))
	first_y := int(math.floor(y-radius))
	last_y := int(math.ceil(y+radius))
	radius_squared := radius*radius

	for tile_x in first_x ..= last_x {
		for tile_y in first_y ..= last_y {
			delta_x := f32(tile_x)+0.5-x
			delta_y := f32(tile_y)+0.5-y
			distance_squared := delta_x*delta_x+delta_y*delta_y
			if distance_squared > radius_squared do continue

			wrapped_x := WorldWrapCoordinate(tile_x, world_width)
			wrapped_y := WorldWrapCoordinate(tile_y, world_height)
			if TileTypeAntiFire(w.ground[wrapped_x][wrapped_y].type) do continue

			distance := math.sqrt(distance_squared)
			falloff := 1-distance/radius
			add := int(amount*falloff+PRandom(w)*1.4)
			if add <= 0 do continue
			BloodAddTile(w, wrapped_x, wrapped_y, add, tint, false)
		}
	}
}

BloodDropLand :: proc(w: ^World, x, y: f32, tint: u8, strong: bool) {
	blood_tint := clamp(tint, 0, u8(BLOOD_TINT_COUNT-1))
	amount: f32 = 1.4
	if strong do amount = 2.8
	BloodAddAt(w, x, y, amount, 0.18+PRandom(w)*0.14, blood_tint)
	// A tiny fraction of drops leave a crisp little splash behind.
	if strong && PRandom(w) < 0.10 {
		BloodDecalAdd(w, x, y, 0.28+PRandom(w)*0.38, blood_tint, false)
	}
}

BloodDecalAdd :: proc(w: ^World, x, y, size: f32, tint: u8, pool: bool) {
	if len(w.blood.decals) == 0 do return
	slot := w.blood.decalCursor
	decal := &w.blood.decals[slot]
	if decal.life <= 0 do w.blood.decalCount += 1

	decal.x = WorldWrapPosition(x, f32(w.maxX))
	decal.y = WorldWrapPosition(y, f32(w.maxY))
	decal.size = max(size, 0.25)
	decal.rotation = PRandom(w)*360
	decal.maxLife = PRandomRange(w, 150, 320)
	if pool do decal.maxLife = PRandomRange(w, 300, 560)
	decal.life = decal.maxLife
	decal.tint = clamp(tint, 0, u8(BLOOD_TINT_COUNT-1))
	decal.brightness = u8(94+int(PRandom(w)*34))
	decal.pool = pool
	if pool {
		decal.variant = u8(int(PRandom(w)*BLOOD_POOL_VARIANTS)%BLOOD_POOL_VARIANTS)
	} else {
		decal.variant = u8(int(PRandom(w)*BLOOD_SPLAT_VARIANTS)%BLOOD_SPLAT_VARIANTS)
	}

	w.blood.decalCursor = (slot+1)%BLOOD_DECAL_CAPACITY
}

BloodUpdate :: proc(w: ^World, delta_time: f32) {
	// Decals dry out and fade, revealing the permanent stain underneath.
	if w.blood.decalCount > 0 {
		for i in 0 ..< BLOOD_DECAL_CAPACITY {
			decal := &w.blood.decals[i]
			if decal.life <= 0 do continue
			decal.life -= delta_time
			if decal.life <= 0 {
				decal.life = 0
				w.blood.decalCount -= 1
			}
		}
	}

	if len(w.blood.active) == 0 do return

	world_width := int(w.maxX)
	world_height := int(w.maxY)
	if world_width <= 0 || world_height <= 0 do return

	// Blood creeps towards dry neighbours, which turns dense slaughter sites
	// into spreading pools instead of evenly stamped circles.
	write := 0
	for read in 0 ..< len(w.blood.active) {
		index := w.blood.active[read]
		if index < 0 || index >= len(w.blood.amount) do continue
		amount := int(w.blood.amount[index])
		if amount <= 14 {
			w.blood.wet[index] = false
			continue
		}

		w.blood.active[write] = index
		write += 1

		if amount < BLOOD_SPREAD_THRESHOLD do continue
		tile_x := index/world_height
		tile_y := index%world_height
		transfer := clamp(amount/28, 1, 6)

		offsets := [4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
		for offset in offsets {
			neighbour_x := WorldWrapCoordinate(tile_x+offset[0], world_width)
			neighbour_y := WorldWrapCoordinate(tile_y+offset[1], world_height)
			if TileTypeAntiFire(w.ground[neighbour_x][neighbour_y].type) do continue
			neighbour_index := neighbour_x*world_height+neighbour_y
			neighbour_amount := int(w.blood.amount[neighbour_index])
			if neighbour_amount+transfer > amount-1 do continue
			if WorldNoiseHash(neighbour_index, index, 0xB100D) > 0.70 do continue

			w.blood.amount[neighbour_index] = u8(neighbour_amount+transfer)
			w.blood.tint[neighbour_index] = w.blood.tint[index]
			w.blood.amount[index] = u8(amount-transfer)
			amount -= transfer
			BloodMarkDirty(w, neighbour_x, neighbour_y)
			if int(w.blood.amount[neighbour_index]) >= BLOOD_SPREAD_THRESHOLD &&
				!w.blood.wet[neighbour_index] {
				w.blood.wet[neighbour_index] = true
				append(&w.blood.pending, neighbour_index)
			}
			if amount < BLOOD_SPREAD_THRESHOLD do break
		}
		BloodMarkDirty(w, tile_x, tile_y)
	}
	resize(&w.blood.active, write)
	for index in w.blood.pending {
		append(&w.blood.active, index)
	}
	clear(&w.blood.pending)
}

// --- damage and gore hooks --------------------------------------------------

BloodParticleColor :: proc(w: ^World, tint: u8) -> rl.Color {
	base := BloodPaletteColor(tint)
	return c_shade(base, 0.84+PRandom(w)*0.32)
}

BloodDropSpawn :: proc(w: ^World, x, y, z, angle, speed: f32, tint: u8, size: f32) {
	ParticleSpawn(w, Particle{
		x = x,
		y = y,
		z = z,
		vx = math.cos(angle)*speed,
		vy = math.sin(angle)*speed,
		vz = PRandomRange(w, 2.2, 7.5),
		life = PRandomRange(w, 0.35, 0.9),
		size = size,
		drag = 1.6,
		gravity = 26,
		kind = .Blood,
		variant = tint,
		tint = BloodParticleColor(w, tint),
	})
}

BloodSpray :: proc(
	w: ^World,
	x, y, dir_x, dir_y: f32,
	severity: f32,
	tint: u8,
	count: int,
) {
	base_angle := math.atan2(dir_y, dir_x)
	if dir_x == 0 && dir_y == 0 do base_angle = PRandom(w)*6.2831853
	for _ in 0 ..< count {
		angle := base_angle+(PRandom(w)-0.5)*(1.2+severity*0.9)
		speed := PRandomRange(w, 1.4, 2.6+severity*3.2)
		BloodDropSpawn(
			w,
			x+(PRandom(w)-0.5)*0.3,
			y+(PRandom(w)-0.5)*0.3,
			PRandomRange(w, 0.35, 0.95),
			angle,
			speed,
			tint,
			PRandomRange(w, 0.16, 0.30),
		)
	}
}

BloodHit :: proc(
	w: ^World,
	x, y, dir_x, dir_y: f32,
	damage: f32,
	type: UnitType,
) {
	tint := BloodTintForUnitType(type)
	if tint == BLOOD_TINT_NONE do return

	severity := clamp(damage/13, 0.35, 2.5)
	count := int(3+severity*5)+int(PRandom(w)*3)
	BloodSpray(w, x, y, dir_x, dir_y, severity, tint, count)
	BloodAddAt(w, x, y, 2+damage*0.45, 0.30+severity*0.18, tint)

	if PRandom(w) < 0.22 {
		BloodDecalAdd(
			w,
			x+(PRandom(w)-0.5)*0.5,
			y+(PRandom(w)-0.5)*0.5,
			0.45+severity*0.45,
			tint,
			false,
		)
	}
}

SpawnGorePart :: proc(
	w: ^World,
	x, y, z, scale: f32,
	faction: int,
	part: GorePartKind,
) {
	part_size: f32 = 0.7
	switch part {
	case .Head:
		part_size = 0.62
	case .Arm:
		part_size = 0.80
	case .Leg:
		part_size = 0.82
	case .Torso:
		part_size = 0.98
	case .Hand:
		part_size = 0.42
	case .Intestine:
		part_size = 0.90
	}

	angle := PRandom(w)*6.2831853
	speed := PRandomRange(w, 1.3, 4.6)
	ParticleSpawn(w, Particle{
		x = x,
		y = y,
		z = z,
		vx = math.cos(angle)*speed,
		vy = math.sin(angle)*speed,
		vz = PRandomRange(w, 2.4, 6.6),
		life = PRandomRange(w, 45, 150),
		size = part_size*scale*(0.86+PRandom(w)*0.28),
		rotation = PRandom(w)*360,
		spin = PRandomRange(w, -420, 420),
		drag = 0.5,
		gravity = 24,
		bounce = 0.34,
		kind = .Gore,
		variant = u8(int(part)%GORE_PART_COUNT),
		faction = u8(clamp(faction, 0, SPRITE_FACTION_COUNT-1)),
		tint = rl.Color{255, 255, 255, 255},
	})
}

BloodDeath :: proc(
	w: ^World,
	x, y, dir_x, dir_y: f32,
	damage: f32,
	type: UnitType,
	faction: int,
) {
	kind := UnitKindOf(type)
	tint := BloodTintForUnitType(type)
	if tint == BLOOD_TINT_NONE {
		// Siege engines spill splinters rather than blood.
		MachineDebrisBurst(w, x, y)
		return
	}

	scale := UnitSpriteScale(kind)
	amount := (45+damage*1.1)*(0.75+scale*0.6)
	BloodAddAt(w, x, y, amount, 0.78+scale*0.55, tint)
	BloodDecalAdd(w, x, y, 1.15+scale*0.9, tint, true)
	BloodDecalAdd(
		w,
		x+(PRandom(w)-0.5)*0.9,
		y+(PRandom(w)-0.5)*0.9,
		0.65+scale*0.7,
		tint,
		false,
	)

	severity := 1.5+scale*0.9
	BloodSpray(w, x, y, dir_x, dir_y, severity, tint, int(13*scale)+int(PRandom(w)*8))

	// Flesh chunks and bone splinters accompany the main spray.
	gib_count := 2+int(PRandom(w)*4)
	for _ in 0 ..< gib_count {
		angle := PRandom(w)*6.2831853
		speed := PRandomRange(w, 1.2, 4.8)
		is_bone := PRandom(w) < 0.22
		ParticleSpawn(w, Particle{
			x = x,
			y = y,
			z = PRandomRange(w, 0.25, 0.8),
			vx = math.cos(angle)*speed,
			vy = math.sin(angle)*speed,
			vz = PRandomRange(w, 2.2, 5.8),
			life = PRandomRange(w, 25, 90),
			size = PRandomRange(w, 0.20, 0.38)*scale,
			rotation = PRandom(w)*360,
			spin = PRandomRange(w, -520, 520),
			drag = 0.6,
			gravity = 25,
			bounce = 0.3,
			kind = is_bone ? .Bone : .Gib,
			tint = rl.Color{255, 255, 255, 255},
		})
	}

	if kind != .Turtle {
		parts := 1+int(PRandom(w)*3)
		if scale > 1.3 do parts += 1
		for _ in 0 ..< parts {
			part := GorePartKind(int(PRandom(w)*GORE_PART_COUNT)%GORE_PART_COUNT)
			SpawnGorePart(w, x, y, PRandomRange(w, 0.4, 0.9), scale, faction, part)
		}
	}

	if kind == .Mage {
		for _ in 0 ..< 5 {
			angle := PRandom(w)*6.2831853
			ParticleSpawn(w, Particle{
				x = x,
				y = y,
				z = PRandomRange(w, 0.3, 0.9),
				vx = math.cos(angle)*PRandomRange(w, 0.5, 2.5),
				vy = math.sin(angle)*PRandomRange(w, 0.5, 2.5),
				vz = PRandomRange(w, 1, 3),
				life = PRandomRange(w, 0.5, 1.4),
				size = PRandomRange(w, 0.10, 0.18),
				drag = 2,
				gravity = 2,
				kind = .Spark,
				tint = rl.Color{196, 156, 255, 255},
			})
		}
	}
}

BloodCharredDeath :: proc(w: ^World, x, y: f32, type: UnitType) {
	scale := UnitSpriteScale(UnitKindOf(type))
	for _ in 0 ..< 6+int(PRandom(w)*5) {
		ParticleSpawn(w, Particle{
			x = x+(PRandom(w)-0.5)*0.4,
			y = y+(PRandom(w)-0.5)*0.4,
			z = PRandomRange(w, 0.2, 0.8),
			vx = (PRandom(w)-0.5)*1.5,
			vy = (PRandom(w)-0.5)*1.5,
			vz = PRandomRange(w, 0.6, 2.6),
			life = PRandomRange(w, 0.8, 2.2),
			size = PRandomRange(w, 0.16, 0.32)*scale,
			rotation = PRandom(w)*360,
			spin = PRandomRange(w, -180, 180),
			drag = 0.8,
			gravity = 7,
			bounce = 0.2,
			kind = .Ash,
			tint = rl.Color{255, 255, 255, 255},
		})
	}
	for _ in 0 ..< 3+int(PRandom(w)*3) {
		ParticleSpawn(w, Particle{
			x = x+(PRandom(w)-0.5)*0.5,
			y = y+(PRandom(w)-0.5)*0.5,
			z = PRandomRange(w, 0.3, 0.9),
			vx = (PRandom(w)-0.5)*0.4,
			vy = (PRandom(w)-0.5)*0.4,
			vz = PRandomRange(w, 0.8, 1.8),
			life = PRandomRange(w, 1.5, 3.2),
			size = PRandomRange(w, 0.5, 1.1),
			drag = 0.5,
			gravity = -0.35,
			kind = .Smoke,
			tint = rl.Color{96, 90, 88, 200},
		})
	}
}

UnitApplyDamage :: proc(
	w: ^World,
	victim_slot: int,
	damage: f32,
	source_x, source_y: f32,
	kind: DamageKind,
) -> bool {
	if victim_slot < 0 || victim_slot >= UNIT_CAPACITY || !w.unitUsed[victim_slot] do return false
	if damage <= 0 do return false

	x := w.units.x[victim_slot]
	y := w.units.y[victim_slot]
	type := w.units.type[victim_slot]
	faction := w.units.kingdome[victim_slot]

	w.units.health[victim_slot] -= damage
	dead := w.units.health[victim_slot] <= 0

	dir_x := WorldShortestWrappedDelta(x-source_x, f32(w.maxX))
	dir_y := WorldShortestWrappedDelta(y-source_y, f32(w.maxY))
	length := math.sqrt(dir_x*dir_x+dir_y*dir_y)
	if length > 0.001 {
		dir_x /= length
		dir_y /= length
	} else {
		angle := PRandom(w)*6.2831853
		dir_x = math.cos(angle)
		dir_y = math.sin(angle)
	}

	switch kind {
	case .Fire:
		if dead {
			BloodCharredDeath(w, x, y, type)
		} else if PRandom(w) < 0.18 {
			ParticleSpawn(w, Particle{
				x = x+(PRandom(w)-0.5)*0.3,
				y = y+(PRandom(w)-0.5)*0.3,
				z = PRandomRange(w, 0.5, 1.0),
				vx = (PRandom(w)-0.5)*0.6,
				vy = (PRandom(w)-0.5)*0.6,
				vz = PRandomRange(w, 1.2, 2.6),
				life = PRandomRange(w, 0.5, 1.2),
				size = PRandomRange(w, 0.08, 0.16),
				drag = 1,
				gravity = 5,
				kind = .Ember,
				tint = rl.Color{255, 255, 255, 255},
			})
		}
	case .Melee, .Projectile, .Area:
		BloodHit(w, x, y, dir_x, dir_y, damage, type)
		if dead do BloodDeath(w, x, y, dir_x, dir_y, damage, type, faction)
	}

	if dead {
		UnitDespawn(w, victim_slot)
		return true
	}
	return false
}

// Wounded units keep painting the ground as they stagger around.
BloodBleedTick :: proc(w: ^World, unit_slot: int, delta_time: f32) {
	if unit_slot < 0 || unit_slot >= UNIT_CAPACITY || !w.unitUsed[unit_slot] do return
	type := w.units.type[unit_slot]
	kind := UnitKindOf(type)
	if kind == .Catapult do return

	tint := BloodTintForUnitType(type)
	if tint == BLOOD_TINT_NONE do return

	max_health := UnitDefaultHealth(type)
	if max_health <= 0 do return
	ratio := w.units.health[unit_slot]/max_health
	if ratio > 0.55 do return

	rate := 0.12+(0.55-ratio)*1.2
	if PRandom(w) >= rate*delta_time do return

	x := w.units.x[unit_slot]
	y := w.units.y[unit_slot]
	BloodDropSpawn(w, x, y, 0.22, PRandom(w)*6.2831853, PRandomRange(w, 0.1, 0.5), tint, PRandomRange(w, 0.12, 0.2))
	BloodAddAt(w, x, y, 1.2, 0.16, tint)
}

// --- structure and scenery debris ------------------------------------------

BuildingStoneMaterial :: proc(kind: BuildingKind) -> bool {
	switch kind {
	case .TownHall, .Wall, .Watchtower, .Cannon, .Bridge, .Path:
		return true
	case .Home, .Farmland, .ArcheryRange, .MagicSchool, .GiantPen, .SiegeWorkshop, .TurtlePen, .ThievesGuild:
		return false
	}
	unreachable()
}

BuildingHitBurst :: proc(w: ^World, building_slot: int, impact_x, impact_y: f32) {
	if building_slot < 0 || building_slot >= BUILDING_CAPACITY || !w.buildingUsed[building_slot] do return
	kind := BuildingKindOf(w.buildings[building_slot].type)
	stone := BuildingStoneMaterial(kind)
	for _ in 0 ..< 1+int(PRandom(w)*2) {
		angle := PRandom(w)*6.2831853
		ParticleSpawn(w, Particle{
			x = impact_x,
			y = impact_y,
			z = PRandomRange(w, 0.3, 0.9),
			vx = math.cos(angle)*PRandomRange(w, 0.6, 2.4),
			vy = math.sin(angle)*PRandomRange(w, 0.6, 2.4),
			vz = PRandomRange(w, 1.2, 3.4),
			life = PRandomRange(w, 2.5, 6),
			size = PRandomRange(w, 0.16, 0.30),
			rotation = PRandom(w)*360,
			spin = PRandomRange(w, -400, 400),
			drag = 0.8,
			gravity = 22,
			bounce = 0.3,
			kind = stone ? ParticleKind.StoneChip : ParticleKind.WoodChip,
			tint = rl.Color{255, 255, 255, 255},
		})
	}
}

BuildingDestroyedBurst :: proc(w: ^World, building_slot: int) {
	if building_slot < 0 || building_slot >= BUILDING_CAPACITY || !w.buildingUsed[building_slot] do return
	kind := BuildingKindOf(w.buildings[building_slot].type)
	stone := BuildingStoneMaterial(kind)
	width, height := BuildingTileSize(w.buildings[building_slot].type)
	center_x := f32(w.buildings[building_slot].x)+f32(width)*0.5
	center_y := f32(w.buildings[building_slot].y)+f32(height)*0.5

	for _ in 0 ..< 16+int(PRandom(w)*12) {
		angle := PRandom(w)*6.2831853
		ParticleSpawn(w, Particle{
			x = center_x+(PRandom(w)-0.5)*f32(width)*0.7,
			y = center_y+(PRandom(w)-0.5)*f32(height)*0.5,
			z = PRandomRange(w, 0.3, 1.8),
			vx = math.cos(angle)*PRandomRange(w, 1.2, 5.5),
			vy = math.sin(angle)*PRandomRange(w, 1.2, 5.5),
			vz = PRandomRange(w, 2.0, 6.5),
			life = PRandomRange(w, 4, 11),
			size = PRandomRange(w, 0.18, 0.42),
			rotation = PRandom(w)*360,
			spin = PRandomRange(w, -500, 500),
			drag = 0.55,
			gravity = 24,
			bounce = 0.36,
			kind = stone ? ParticleKind.StoneChip : ParticleKind.WoodChip,
			tint = rl.Color{255, 255, 255, 255},
		})
	}
	for _ in 0 ..< 8+int(PRandom(w)*8) {
		ParticleSpawn(w, Particle{
			x = center_x+(PRandom(w)-0.5)*f32(width)*0.8,
			y = center_y+(PRandom(w)-0.5)*f32(height)*0.7,
			z = PRandomRange(w, 0.2, 1.2),
			vx = (PRandom(w)-0.5)*1.4,
			vy = (PRandom(w)-0.5)*1.4,
			vz = PRandomRange(w, 0.2, 1.2),
			life = PRandomRange(w, 1.4, 3.4),
			size = PRandomRange(w, 0.8, 1.9),
			drag = 0.9,
			gravity = -0.1,
			kind = .Dust,
			tint = rl.Color{218, 202, 176, 210},
		})
	}
}

MachineDebrisBurst :: proc(w: ^World, x, y: f32) {
	for _ in 0 ..< 12+int(PRandom(w)*10) {
		angle := PRandom(w)*6.2831853
		ParticleSpawn(w, Particle{
			x = x,
			y = y,
			z = PRandomRange(w, 0.3, 1.2),
			vx = math.cos(angle)*PRandomRange(w, 1.0, 4.8),
			vy = math.sin(angle)*PRandomRange(w, 1.0, 4.8),
			vz = PRandomRange(w, 2.0, 5.6),
			life = PRandomRange(w, 3, 9),
			size = PRandomRange(w, 0.18, 0.38),
			rotation = PRandom(w)*360,
			spin = PRandomRange(w, -480, 480),
			drag = 0.6,
			gravity = 24,
			bounce = 0.35,
			kind = .WoodChip,
			tint = rl.Color{255, 255, 255, 255},
		})
	}
}

DecorationDebris :: proc(w: ^World, x, y: f32, kind: DecorationKind) {
	chips := 0
	leaves := 0
	stone := false
	sparks := false
	switch kind {
	case .Tree:
		chips = 7
		leaves = 14
	case .Pine:
		chips = 6
		leaves = 16
	case .Bush:
		chips = 2
		leaves = 9
	case .Flowers:
		leaves = 7
	case .Cactus:
		leaves = 7
	case .Reed:
		leaves = 6
	case .Stump:
		chips = 4
	case .Rock:
		stone = true
		chips = 7
	case .Lamp:
		stone = true
		chips = 3
		sparks = true
	}

	for _ in 0 ..< chips+int(PRandom(w)*3) {
		angle := PRandom(w)*6.2831853
		ParticleSpawn(w, Particle{
			x = x,
			y = y,
			z = PRandomRange(w, 0.2, 0.8),
			vx = math.cos(angle)*PRandomRange(w, 0.6, 2.6),
			vy = math.sin(angle)*PRandomRange(w, 0.6, 2.6),
			vz = PRandomRange(w, 1.2, 3.6),
			life = PRandomRange(w, 2.5, 6),
			size = PRandomRange(w, 0.14, 0.28),
			rotation = PRandom(w)*360,
			spin = PRandomRange(w, -460, 460),
			drag = 0.7,
			gravity = 22,
			bounce = 0.32,
			kind = stone ? ParticleKind.StoneChip : ParticleKind.WoodChip,
			tint = rl.Color{255, 255, 255, 255},
		})
	}
	for _ in 0 ..< leaves+int(PRandom(w)*4) {
		angle := PRandom(w)*6.2831853
		ParticleSpawn(w, Particle{
			x = x,
			y = y,
			z = PRandomRange(w, 0.3, 1.4),
			vx = math.cos(angle)*PRandomRange(w, 0.3, 1.8),
			vy = math.sin(angle)*PRandomRange(w, 0.3, 1.8),
			vz = PRandomRange(w, 0.4, 1.8),
			life = PRandomRange(w, 3, 7),
			size = PRandomRange(w, 0.12, 0.24),
			rotation = PRandom(w)*360,
			spin = PRandomRange(w, -200, 200),
			drag = 1.4,
			gravity = 3.5,
			bounce = 0.1,
			kind = .Leaf,
			tint = rl.Color{255, 255, 255, 255},
		})
	}
	if sparks {
		for _ in 0 ..< 4 {
			ParticleSpawn(w, Particle{
				x = x,
				y = y,
				z = PRandomRange(w, 0.3, 0.9),
				vx = (PRandom(w)-0.5)*2.5,
				vy = (PRandom(w)-0.5)*2.5,
				vz = PRandomRange(w, 0.8, 2.4),
				life = PRandomRange(w, 0.3, 0.9),
				size = PRandomRange(w, 0.08, 0.14),
				drag = 2,
				gravity = 8,
				kind = .Spark,
				tint = rl.Color{255, 226, 150, 255},
			})
		}
	}
}

// --- fire ambience ----------------------------------------------------------

FireParticleTick :: proc(w: ^World, fire_slot: int, delta_time: f32) {
	intensity := w.fires.intensity[fire_slot]
	x := w.fires.x[fire_slot]
	y := w.fires.y[fire_slot]

	if PRandom(w) < 0.42*delta_time*intensity {
		ParticleSpawn(w, Particle{
			x = x+(PRandom(w)-0.5)*0.4,
			y = y+(PRandom(w)-0.5)*0.4,
			z = PRandomRange(w, 0.4, 1.2),
			vx = (PRandom(w)-0.5)*0.4,
			vy = (PRandom(w)-0.5)*0.4,
			vz = PRandomRange(w, 0.7, 1.8),
			life = PRandomRange(w, 1.4, 3.2),
			size = PRandomRange(w, 0.5, 1.3),
			drag = 0.45,
			gravity = -0.3,
			kind = .Smoke,
			tint = rl.Color{86, 82, 84, 190},
		})
	}
	if PRandom(w) < 0.30*delta_time*intensity {
		ParticleSpawn(w, Particle{
			x = x+(PRandom(w)-0.5)*0.35,
			y = y+(PRandom(w)-0.5)*0.35,
			z = PRandomRange(w, 0.3, 1.1),
			vx = (PRandom(w)-0.5)*0.9,
			vy = (PRandom(w)-0.5)*0.9,
			vz = PRandomRange(w, 1.2, 3.2),
			life = PRandomRange(w, 0.4, 1.3),
			size = PRandomRange(w, 0.10, 0.20),
			drag = 0.7,
			gravity = 5,
			kind = .Ember,
			tint = rl.Color{255, 255, 255, 255},
		})
	}
}

FireIgniteBurst :: proc(w: ^World, x, y: f32, intensity: f32) {
	for _ in 0 ..< 2+int(PRandom(w)*3) {
		ParticleSpawn(w, Particle{
			x = x,
			y = y,
			z = PRandomRange(w, 0.3, 0.9),
			vx = (PRandom(w)-0.5)*1.8,
			vy = (PRandom(w)-0.5)*1.8,
			vz = PRandomRange(w, 1.0, 3.4),
			life = PRandomRange(w, 0.4, 1.4),
			size = PRandomRange(w, 0.10, 0.20),
			drag = 1,
			gravity = 4,
			kind = .Ember,
			tint = rl.Color{255, 244, 220, 255},
		})
	}
	if intensity > 0.6 {
		ParticleSpawn(w, Particle{
			x = x,
			y = y,
			z = 0.6,
			vx = 0,
			vy = 0,
			vz = PRandomRange(w, 0.8, 1.6),
			life = PRandomRange(w, 1.2, 2.4),
			size = PRandomRange(w, 0.6, 1.2),
			drag = 0.4,
			gravity = -0.25,
			kind = .Smoke,
			tint = rl.Color{74, 70, 72, 180},
		})
	}
}

// --- rendering --------------------------------------------------------------

BloodRenderInit :: proc(w: ^World, renderer: ^WorldRenderer) -> bool {
	count := int(w.maxX)*int(w.maxY)
	if count <= 0 || len(w.blood.amount) < count do return false
	image := rl.GenImageColor(i32(w.maxX), i32(w.maxY), C_CLEAR)
	renderer.bloodTexture = rl.LoadTextureFromImage(image)
	rl.UnloadImage(image)
	rl.SetTextureFilter(renderer.bloodTexture, .BILINEAR)
	renderer.bloodPixels = make([dynamic]u8, 0, 4096)
	return true
}

BloodRenderDeinit :: proc(renderer: ^WorldRenderer) {
	if renderer.bloodTexture.id != 0 do rl.UnloadTexture(renderer.bloodTexture)
	renderer.bloodTexture = {}
	delete(renderer.bloodPixels)
	renderer.bloodPixels = nil
}

BloodRenderUpdate :: proc(w: ^World, renderer: ^WorldRenderer) {
	if renderer.bloodTexture.id == 0 || len(w.blood.dirtyList) == 0 do return

	world_width := int(w.maxX)
	world_height := int(w.maxY)
	if world_width <= 0 || world_height <= 0 do return
	blocks_y := (world_height+BLOOD_DIRTY_BLOCK-1)/BLOOD_DIRTY_BLOCK
	if blocks_y <= 0 do return

	// Upload a bounded number of dirty blocks per frame. Two battles on
	// opposite sides of the map therefore cost two small uploads instead of
	// re-uploading the whole stain texture every frame.
	process_count := min(len(w.blood.dirtyList), BLOOD_BLOCK_UPLOADS_PER_FRAME)
	for block_index in 0 ..< process_count {
		block := w.blood.dirtyList[block_index]
		block_x := block/blocks_y
		block_y := block%blocks_y
		min_x := block_x*BLOOD_DIRTY_BLOCK
		min_y := block_y*BLOOD_DIRTY_BLOCK
		max_x := min(min_x+BLOOD_DIRTY_BLOCK-1, world_width-1)
		max_y := min(min_y+BLOOD_DIRTY_BLOCK-1, world_height-1)
		width := max_x-min_x+1
		height := max_y-min_y+1
		if width <= 0 || height <= 0 do continue

		needed := width*height*4
		if len(renderer.bloodPixels) < needed do resize(&renderer.bloodPixels, needed)
		pixels := renderer.bloodPixels[:needed]

		for tile_y in 0 ..< height {
			for tile_x in 0 ..< width {
				x := min_x+tile_x
				y := min_y+tile_y
				index := x*world_height+y
				pixel := (tile_y*width+tile_x)*4
				amount := int(w.blood.amount[index])

				if amount == 0 {
					pixels[pixel+0] = 0
					pixels[pixel+1] = 0
					pixels[pixel+2] = 0
					pixels[pixel+3] = 0
					continue
				}

				// Blending with the neighbours rounds off the tile grid so pools
				// read as liquid instead of a checkerboard.
				total := amount*3
				samples := 3
				offsets := [4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
				for offset in offsets {
					neighbour_x := WorldWrapCoordinate(x+offset[0], world_width)
					neighbour_y := WorldWrapCoordinate(y+offset[1], world_height)
					total += int(w.blood.amount[neighbour_x*world_height+neighbour_y])
					samples += 1
				}
				smooth := f32(total)/f32(samples)
				if smooth < 0.8 {
					pixels[pixel+0] = 0
					pixels[pixel+1] = 0
					pixels[pixel+2] = 0
					pixels[pixel+3] = 0
					continue
				}

				tint := BloodPaletteColor(w.blood.tint[index])
				tone := clamp(smooth/210, 0, 1)
				shade := (0.34+0.46*math.sqrt(tone))*(0.86+0.28*WorldNoiseHash(x, y, 0xB100D5))
				alpha := u8(clamp(smooth*0.9, 0, 112))
				pixels[pixel+0] = u8(clamp(f32(tint.r)*shade, 0, 255))
				pixels[pixel+1] = u8(clamp(f32(tint.g)*shade, 0, 255))
				pixels[pixel+2] = u8(clamp(f32(tint.b)*shade, 0, 255))
				pixels[pixel+3] = alpha
			}
		}

		rl.UpdateTextureRec(
			renderer.bloodTexture,
			rl.Rectangle{f32(min_x), f32(min_y), f32(width), f32(height)},
			raw_data(pixels),
		)
		w.blood.dirtyMarker[block] = false
	}

	remaining := len(w.blood.dirtyList)-process_count
	if remaining > 0 {
		copy(w.blood.dirtyList[:remaining], w.blood.dirtyList[process_count:])
	}
	resize(&w.blood.dirtyList, remaining)
}

// At close zoom the 1-pixel-per-tile stain map would read as a grid of
// squares. This pass scatters rotated procedural splats over every bloody
// tile, which is what turns the map into a convincingly messy pool.
BloodRenderTileSplats :: proc(
	w: ^World,
	renderer: ^WorldRenderer,
	camera: rl.Camera2D,
	first_copy_x, last_copy_x, first_copy_y, last_copy_y: int,
) {
	world_width := int(w.maxX)
	world_height := int(w.maxY)
	if world_width <= 0 || world_height <= 0 do return

	half_view_width := f32(rl.GetScreenWidth())/(2*camera.zoom)
	half_view_height := f32(rl.GetScreenHeight())/(2*camera.zoom)

	for copy_x in first_copy_x ..< last_copy_x+1 {
		offset_x := f32(copy_x)*f32(world_width)
		for copy_y in first_copy_y ..< last_copy_y+1 {
			offset_y := f32(copy_y)*f32(world_height)
			min_x := camera.target.x-half_view_width-offset_x
			max_x := camera.target.x+half_view_width-offset_x
			min_y := camera.target.y-half_view_height-offset_y
			max_y := camera.target.y+half_view_height-offset_y

			first_x := WorldFloor(min_x)-1
			last_x := WorldFloor(max_x)+1
			first_y := WorldFloor(min_y)-1
			last_y := WorldFloor(max_y)+1
			if last_x-first_x >= world_width {
				first_x = 0
				last_x = world_width-1
			}
			if last_y-first_y >= world_height {
				first_y = 0
				last_y = world_height-1
			}

			for tile_y in first_y ..= last_y {
				wrapped_y := WorldWrapCoordinate(tile_y, world_height)
				for tile_x in first_x ..= last_x {
					wrapped_x := WorldWrapCoordinate(tile_x, world_width)
					index := wrapped_x*world_height+wrapped_y
					amount := int(w.blood.amount[index])
					if amount < 6 do continue
					if !FogTileVisible(w, wrapped_x, wrapped_y) do continue

					hash_a := WorldNoiseHash(wrapped_x, wrapped_y, 0xB100D51)
					hash_b := WorldNoiseHash(wrapped_y, wrapped_x, 0xB100D52)
					hash_c := WorldNoiseHash(wrapped_x+7, wrapped_y+3, 0xB100D53)
					hash_d := WorldNoiseHash(wrapped_x+11, wrapped_y+17, 0xB100D54)
					// Dense pools overlap heavily; skipping part of them keeps the
					// draw count sane without opening holes in the stain.
					if amount > 110 && hash_d < 0.42 do continue
					variant := int(hash_a*BLOOD_SPLAT_VARIANTS)%BLOOD_SPLAT_VARIANTS
					texture := renderer.sprites.bloodSplat[variant]
					if texture.id == 0 do continue

					size := 1.25+hash_b*1.25+clamp(f32(amount)/255, 0, 1)*0.5
					if amount > 110 do size += 0.6
					jitter_x := (hash_c-0.5)*0.5
					jitter_y := (hash_a-0.5)*0.5
					tint := c_shade(BloodPaletteColor(w.blood.tint[index]), 0.72+0.34*hash_b)
					tint.a = u8(clamp(f32(amount)*1.15+55, 0, 210))
					source := rl.Rectangle{0, 0, f32(texture.width), f32(texture.height)}
					rl.DrawTexturePro(
						texture,
						source,
						rl.Rectangle{
							offset_x+f32(wrapped_x)+0.5+jitter_x-size*0.5,
							offset_y+f32(wrapped_y)+0.5+jitter_y-size*0.5,
							size,
							size,
						},
						rl.Vector2{size*0.5, size*0.5},
						hash_c*360,
						tint,
					)
				}
			}
		}
	}
}

BloodRenderGround :: proc(
	w: ^World,
	renderer: ^WorldRenderer,
	camera: rl.Camera2D,
	first_copy_x, last_copy_x, first_copy_y, last_copy_y: int,
) {
	world_width := f32(w.maxX)
	world_height := f32(w.maxY)
	if world_width <= 0 || world_height <= 0 do return

	if renderer.bloodTexture.id != 0 {
		source := rl.Rectangle{0, 0, world_width, world_height}
		for copy_x in first_copy_x ..< last_copy_x+1 {
			for copy_y in first_copy_y ..< last_copy_y+1 {
				rl.DrawTexturePro(
					renderer.bloodTexture,
					source,
					rl.Rectangle{
						f32(copy_x)*world_width,
						f32(copy_y)*world_height,
						world_width,
						world_height,
					},
					rl.Vector2{0, 0},
					0,
					rl.WHITE,
				)
			}
		}
	}

	if camera.zoom >= BLOOD_TILE_SPLAT_MIN_ZOOM && renderer.sprites.bloodSplat[0].id != 0 {
		BloodRenderTileSplats(w, renderer, camera, first_copy_x, last_copy_x, first_copy_y, last_copy_y)
	}

	if camera.zoom < BLOOD_DECAL_MIN_ZOOM do return
	if renderer.sprites.bloodSplat[0].id == 0 || w.blood.decalCount <= 0 do return

	half_view_width := f32(rl.GetScreenWidth())/(2*camera.zoom)
	half_view_height := f32(rl.GetScreenHeight())/(2*camera.zoom)

	for copy_x in first_copy_x ..< last_copy_x+1 {
		offset_x := f32(copy_x)*world_width
		for copy_y in first_copy_y ..< last_copy_y+1 {
			offset_y := f32(copy_y)*world_height
			min_x := camera.target.x-half_view_width-offset_x
			max_x := camera.target.x+half_view_width-offset_x
			min_y := camera.target.y-half_view_height-offset_y
			max_y := camera.target.y+half_view_height-offset_y

			for i in 0 ..< BLOOD_DECAL_CAPACITY {
				decal := w.blood.decals[i]
				if decal.life <= 0 do continue
				half := decal.size*0.5
				if decal.x+half < min_x || decal.x-half > max_x ||
					decal.y+half < min_y || decal.y-half > max_y {
					continue
				}
				if !FogTileVisible(w, int(decal.x), int(decal.y)) do continue

				texture: rl.Texture2D
				if decal.pool {
					texture = renderer.sprites.bloodPool[int(decal.variant)%BLOOD_POOL_VARIANTS]
				} else {
					texture = renderer.sprites.bloodSplat[int(decal.variant)%BLOOD_SPLAT_VARIANTS]
				}
				if texture.id == 0 do continue

				tint := c_shade(BloodPaletteColor(decal.tint), f32(decal.brightness)/100)
				fade := clamp(decal.life/6, 0, 1)
				tint.a = u8(235*fade)
				source := rl.Rectangle{0, 0, f32(texture.width), f32(texture.height)}
				rl.DrawTexturePro(
					texture,
					source,
					rl.Rectangle{
						offset_x+decal.x-half,
						offset_y+decal.y-half,
						decal.size,
						decal.size,
					},
					rl.Vector2{half, half},
					decal.rotation,
					tint,
				)
			}
		}
	}
}

// --- procedural blood art ---------------------------------------------------

create_blood_splat_texture :: proc(seed: u64, size: int, pool: bool) -> rl.Texture2D {
	art := art_init(size, size)
	center_x := f32(size)*0.5
	center_y := f32(size)*0.5
	base := f32(size)*(pool ? 0.255 : 0.215)
	core_color := C_SPLAT_DARK
	mid_color := C_SPLAT_MID
	if pool {
		core_color = C_SPLAT_DEEP
		mid_color = C_SPLAT_DARK
	}

	lobes := 6+int(WorldNoiseHash(int(seed), 1, 0xB10)*3)
	for i in 0 ..< lobes {
		angle := 6.2831853*f32(i)/f32(lobes)+WorldNoiseHash(i, int(seed), 0xB11)*0.9
		distance := base*WorldNoiseHash(i, int(seed)+3, 0xB12)*0.55
		radius_x := int(base*(0.52+0.46*WorldNoiseHash(i, int(seed)+5, 0xB13)))
		radius_y := int(base*(0.46+0.46*WorldNoiseHash(i, int(seed)+7, 0xB14)))
		px := int(center_x+math.cos(angle)*distance)
		py := int(center_y+math.sin(angle)*distance)
		art_ellipse(&art, px, py, max(radius_x, 1), max(radius_y, 1), core_color)
	}

	for i in 0 ..< lobes {
		angle := 6.2831853*f32(i)/f32(lobes)+WorldNoiseHash(i, int(seed)+11, 0xB15)*1.2
		distance := base*WorldNoiseHash(i, int(seed)+13, 0xB16)*0.42
		radius_x := int(base*(0.26+0.30*WorldNoiseHash(i, int(seed)+17, 0xB17)))
		radius_y := int(base*(0.24+0.30*WorldNoiseHash(i, int(seed)+19, 0xB18)))
		px := int(center_x+math.cos(angle)*distance)
		py := int(center_y+math.sin(angle)*distance)
		art_ellipse(&art, px, py, max(radius_x, 1), max(radius_y, 1), mid_color)
	}

	if !pool {
		for i in 0 ..< 3 {
			angle := WorldNoiseHash(i, int(seed)+23, 0xB19)*6.2831853
			distance := base*WorldNoiseHash(i, int(seed)+29, 0xB1A)*0.30
			px := int(center_x+math.cos(angle)*distance)
			py := int(center_y+math.sin(angle)*distance)
			art_ellipse(&art, px, py, 1+int(base*0.12), 1+int(base*0.10), C_SPLAT_LIGHT)
		}
	}

	// Satellite droplets give every splat an organic, directional silhouette.
	droplets := 14+int(WorldNoiseHash(int(seed), 31, 0xB1B)*10)
	if pool do droplets += 8
	for i in 0 ..< droplets {
		angle := WorldNoiseHash(i, int(seed)+33, 0xB1C)*6.2831853
		distance := base*(0.82+WorldNoiseHash(i, int(seed)+37, 0xB1D)*1.35)
		radius := 1+int(WorldNoiseHash(i, int(seed)+41, 0xB1E)*(pool ? 3.4 : 2.4))
		px := int(center_x+math.cos(angle)*distance)
		py := int(center_y+math.sin(angle)*distance)
		art_circle(&art, px, py, radius, core_color)
		if radius > 2 {
			art_pixel(&art, px-1, py-1, mid_color)
		}
	}

	// A few thin tendrils where the spray ran outwards.
	streaks := 3+int(WorldNoiseHash(int(seed), 43, 0xB1F)*4)
	for i in 0 ..< streaks {
		angle := WorldNoiseHash(i, int(seed)+47, 0xB20)*6.2831853
		start_x := int(center_x+math.cos(angle)*base*0.65)
		start_y := int(center_y+math.sin(angle)*base*0.65)
		end_x := int(center_x+math.cos(angle)*base*1.45)
		end_y := int(center_y+math.sin(angle)*base*1.45)
		art_line(&art, start_x, start_y, end_x, end_y, core_color)
	}

	// Punch small holes so the terrain shows through and the edge is not solid.
	holes := 4+int(WorldNoiseHash(int(seed), 53, 0xB21)*5)
	for i in 0 ..< holes {
		angle := WorldNoiseHash(i, int(seed)+59, 0xB22)*6.2831853
		distance := base*WorldNoiseHash(i, int(seed)+61, 0xB23)*0.75
		px := int(center_x+math.cos(angle)*distance)
		py := int(center_y+math.sin(angle)*distance)
		radius := 1+int(WorldNoiseHash(i, int(seed)+67, 0xB24)*2.2)
		art_circle(&art, px, py, radius, C_CLEAR)
	}

	return art_take_texture(art)
}

draw_gore_part :: proc(part: GorePartKind, accent: rl.Color) -> Art {
	switch part {
	case .Head:
		art := art_init(10, 10)
		art_ellipse(&art, 5, 4, 4, 4, C_OUTLINE)
		art_ellipse(&art, 5, 4, 3, 3, C_SKIN)
		art_rect(&art, 3, 1, 5, 2, C_HAIR)
		art_pixel(&art, 3, 4, C_OUTLINE)
		art_pixel(&art, 6, 4, C_OUTLINE)
		art_pixel(&art, 4, 5, C_SKIN_DARK)
		art_rect(&art, 4, 6, 3, 1, C_ENTRAIL_DARK)
		art_line(&art, 2, 5, 3, 8, C_ENTRAIL)
		art_rect(&art, 4, 8, 3, 1, C_ENTRAIL_DARK)
		art_pixel(&art, 5, 9, C_BONE)
		return art
	case .Arm:
		art := art_init(13, 6)
		art_ellipse(&art, 3, 3, 3, 2, C_OUTLINE)
		art_ellipse(&art, 6, 3, 3, 2, C_OUTLINE)
		art_ellipse(&art, 9, 2, 2, 2, C_OUTLINE)
		art_ellipse(&art, 11, 2, 2, 2, C_OUTLINE)
		art_ellipse(&art, 3, 3, 2, 1, C_SKIN)
		art_ellipse(&art, 6, 3, 2, 1, C_SKIN)
		art_ellipse(&art, 9, 2, 1, 1, C_SKIN)
		art_ellipse(&art, 11, 2, 1, 1, C_SKIN)
		art_rect(&art, 9, 0, 4, 4, C_OUTLINE)
		art_rect(&art, 10, 1, 2, 2, accent)
		art_ellipse(&art, 1, 3, 2, 1, C_ENTRAIL_DARK)
		art_pixel(&art, 1, 3, C_BONE)
		art_pixel(&art, 4, 4, C_ENTRAIL_DARK)
		art_pixel(&art, 6, 2, C_ENTRAIL)
		return art
	case .Leg:
		art := art_init(8, 13)
		art_ellipse(&art, 4, 3, 3, 3, C_OUTLINE)
		art_ellipse(&art, 4, 6, 3, 3, C_OUTLINE)
		art_ellipse(&art, 4, 9, 2, 2, C_OUTLINE)
		art_ellipse(&art, 4, 11, 2, 2, C_OUTLINE)
		art_ellipse(&art, 4, 3, 2, 2, C_SKIN)
		art_ellipse(&art, 4, 6, 2, 2, C_SKIN)
		art_ellipse(&art, 4, 9, 1, 1, C_SKIN)
		art_rect(&art, 2, 10, 4, 3, C_OUTLINE)
		art_rect(&art, 2, 10, 4, 2, C_WOOD_DARKEST)
		art_pixel(&art, 3, 10, C_WOOD)
		art_ellipse(&art, 4, 1, 2, 1, C_ENTRAIL_DARK)
		art_pixel(&art, 4, 1, C_BONE)
		art_pixel(&art, 5, 5, C_ENTRAIL_DARK)
		return art
	case .Torso:
		art := art_init(15, 13)
		spans := [12]int{4, 7, 9, 10, 11, 11, 11, 10, 9, 8, 7, 6}
		for y in 0 ..< len(spans) {
			width := spans[y]
			x := 7-width/2
			art_rect(&art, x, y, width, 1, C_OUTLINE)
		}
		for y in 1 ..< len(spans)-1 {
			width := spans[y]-2
			x := 7-width/2
			art_rect(&art, x, y, width, 1, C_SKIN)
		}
		for y in 2 ..< 7 {
			width := spans[y]-4
			x := 7-width/2
			art_rect(&art, x, y, width, 1, accent)
		}
		art_rect(&art, 5, 0, 3, 2, C_ENTRAIL_DARK)
		art_rect(&art, 4, 8, 6, 2, C_ENTRAIL_DARK)
		art_rect(&art, 5, 9, 4, 1, C_ENTRAIL)
		art_pixel(&art, 5, 10, C_BONE)
		art_pixel(&art, 7, 10, C_BONE)
		art_pixel(&art, 9, 10, C_BONE)
		art_line(&art, 5, 3, 9, 7, C_ENTRAIL_DARK)
		art_pixel(&art, 9, 4, C_ENTRAIL)
		art_pixel(&art, 4, 6, C_ENTRAIL_DARK)
		art_pixel(&art, 10, 7, C_ENTRAIL)
		art_pixel(&art, 2, 4, C_ENTRAIL_DARK)
		return art
	case .Hand:
		art := art_init(6, 6)
		art_ellipse(&art, 3, 3, 2, 2, C_OUTLINE)
		art_ellipse(&art, 3, 3, 1, 1, C_SKIN)
		art_rect(&art, 0, 2, 2, 2, C_ENTRAIL_DARK)
		art_pixel(&art, 0, 2, C_BONE)
		return art
	case .Intestine:
		art := art_init(15, 9)
		for i in 0 ..< 5 {
			x := 2+i*2
			y := 4+int(math.sin(f32(i)*1.7)*2)
			art_circle(&art, x, y, 2, C_OUTLINE)
			art_circle(&art, x, y, 1, C_ENTRAIL)
		}
		art_pixel(&art, 4, 3, C_ENTRAIL_DARK)
		art_pixel(&art, 10, 5, C_ENTRAIL_DARK)
		art_pixel(&art, 7, 6, C_SPLAT_LIGHT)
		return art
	}
	return art_init(4, 4)
}
