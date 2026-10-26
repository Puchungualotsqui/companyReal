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
BLOOD_SPLAT_TEXTURE_SIZE :: 32
BLOOD_POOL_TEXTURE_SIZE :: 48
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

// Greyscale art is tinted with BLOOD_PALETTE, so one texture serves every
// creature that bleeds a different colour. Bright greys keep the tinted
// result close to the palette instead of muddying it.
C_SPLAT_RIM := rl.Color{118, 118, 128, 255}
C_SPLAT_DEEP := rl.Color{168, 168, 178, 255}
C_SPLAT_DARK := rl.Color{202, 202, 212, 255}
C_SPLAT_MID := rl.Color{228, 228, 238, 255}
C_SPLAT_LIGHT := rl.Color{252, 252, 255, 255}

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
	Drowning,
	Poison,
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
	blocksX := (int(w.maxX)+BLOOD_DIRTY_BLOCK-1)/BLOOD_DIRTY_BLOCK
	blocksY := (int(w.maxY)+BLOOD_DIRTY_BLOCK-1)/BLOOD_DIRTY_BLOCK
	w.blood.dirtyMarker = make([]bool, max(blocksX*blocksY, 1))
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
	bestDistance := 1 << 30
	for i in 0 ..< BLOOD_TINT_COUNT {
		base := BLOOD_PALETTE[i]
		dr := int(color.r)-int(base.r)
		dg := int(color.g)-int(base.g)
		db := int(color.b)-int(base.b)
		distance := dr*dr+dg*dg+db*db
		if distance < bestDistance {
			bestDistance = distance
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
	blocksY := (int(w.maxY)+BLOOD_DIRTY_BLOCK-1)/BLOOD_DIRTY_BLOCK
	if blocksY <= 0 do return
	block := (x/BLOOD_DIRTY_BLOCK)*blocksY+y/BLOOD_DIRTY_BLOCK
	if block < 0 || block >= len(w.blood.dirtyMarker) do return
	if w.blood.dirtyMarker[block] do return
	w.blood.dirtyMarker[block] = true
	append(&w.blood.dirtyList, block)
}

BloodAddTile :: proc(w: ^World, x, y, amount: int, tint: u8, pending: bool) {
	worldHeight := int(w.maxY)
	index := x*worldHeight+y
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
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 || amount <= 0 || radius <= 0 do return

	firstX := int(math.floor(x-radius))
	lastX := int(math.ceil(x+radius))
	firstY := int(math.floor(y-radius))
	lastY := int(math.ceil(y+radius))
	radiusSquared := radius*radius

	for tileX in firstX ..= lastX {
		for tileY in firstY ..= lastY {
			deltaX := f32(tileX)+0.5-x
			deltaY := f32(tileY)+0.5-y
			distanceSquared := deltaX*deltaX+deltaY*deltaY
			if distanceSquared > radiusSquared do continue

			wrappedX := WorldWrapCoordinate(tileX, worldWidth)
			wrappedY := WorldWrapCoordinate(tileY, worldHeight)
			if TileTypeAntiFire(w.ground[wrappedX][wrappedY].type) do continue

			distance := math.sqrt(distanceSquared)
			falloff := 1-distance/radius
			add := int(amount*falloff+PRandom(w)*1.4)
			if add <= 0 do continue
			BloodAddTile(w, wrappedX, wrappedY, add, tint, false)
		}
	}
}

BloodDropLand :: proc(w: ^World, x, y: f32, tint: u8, strong: bool) {
	bloodTint := clamp(tint, 0, u8(BLOOD_TINT_COUNT-1))
	amount: f32 = 1.4
	if strong do amount = 2.8
	BloodAddAt(w, x, y, amount, 0.18+PRandom(w)*0.14, bloodTint)
	// A tiny fraction of drops leave a crisp little splash behind.
	if strong && PRandom(w) < 0.10 {
		BloodDecalAdd(w, x, y, 0.28+PRandom(w)*0.38, bloodTint, false)
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

BloodUpdate :: proc(w: ^World, deltaTime: f32) {
	// Decals dry out and fade, revealing the permanent stain underneath.
	if w.blood.decalCount > 0 {
		for i in 0 ..< BLOOD_DECAL_CAPACITY {
			decal := &w.blood.decals[i]
			if decal.life <= 0 do continue
			decal.life -= deltaTime
			if decal.life <= 0 {
				decal.life = 0
				w.blood.decalCount -= 1
			}
		}
	}

	if len(w.blood.active) == 0 do return

	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 do return

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
		tileX := index/worldHeight
		tileY := index%worldHeight
		transfer := clamp(amount/28, 1, 6)

		offsets := [4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
		for offset in offsets {
			neighbourX := WorldWrapCoordinate(tileX+offset[0], worldWidth)
			neighbourY := WorldWrapCoordinate(tileY+offset[1], worldHeight)
			if TileTypeAntiFire(w.ground[neighbourX][neighbourY].type) do continue
			neighbourIndex := neighbourX*worldHeight+neighbourY
			neighbourAmount := int(w.blood.amount[neighbourIndex])
			if neighbourAmount+transfer > amount-1 do continue
			if WorldNoiseHash(neighbourIndex, index, 0xB100D) > 0.70 do continue

			w.blood.amount[neighbourIndex] = u8(neighbourAmount+transfer)
			w.blood.tint[neighbourIndex] = w.blood.tint[index]
			w.blood.amount[index] = u8(amount-transfer)
			amount -= transfer
			BloodMarkDirty(w, neighbourX, neighbourY)
			if int(w.blood.amount[neighbourIndex]) >= BLOOD_SPREAD_THRESHOLD &&
				!w.blood.wet[neighbourIndex] {
				w.blood.wet[neighbourIndex] = true
				append(&w.blood.pending, neighbourIndex)
			}
			if amount < BLOOD_SPREAD_THRESHOLD do break
		}
		BloodMarkDirty(w, tileX, tileY)
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
	return CShade(base, 0.84+PRandom(w)*0.32)
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
	x, y, dirX, dirY: f32,
	severity: f32,
	tint: u8,
	count: int,
) {
	baseAngle := math.atan2(dirY, dirX)
	if dirX == 0 && dirY == 0 do baseAngle = PRandom(w)*6.2831853
	for _ in 0 ..< count {
		angle := baseAngle+(PRandom(w)-0.5)*(1.2+severity*0.9)
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
	x, y, dirX, dirY: f32,
	damage: f32,
	type: UnitType,
) {
	tint := BloodTintForUnitType(type)
	if tint == BLOOD_TINT_NONE do return

	severity := clamp(damage/13, 0.35, 2.5)
	count := int(3+severity*5)+int(PRandom(w)*3)
	BloodSpray(w, x, y, dirX, dirY, severity, tint, count)
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
	unitKind: UnitKind,
	part: GorePartKind,
) {
	partSize: f32 = 0.7
	switch part {
	case .Head:
		partSize = 0.62
	case .Arm:
		partSize = 0.80
	case .Leg:
		partSize = 0.82
	case .Torso:
		partSize = 0.98
	case .Hand:
		partSize = 0.42
	case .Intestine:
		partSize = 0.90
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
		size = partSize*scale*(0.86+PRandom(w)*0.28),
		rotation = PRandom(w)*360,
		spin = PRandomRange(w, -420, 420),
		drag = 0.5,
		gravity = 24,
		bounce = 0.34,
		kind = .Gore,
		variant = u8(int(part)%GORE_PART_COUNT),
		goreKind = u8(int(unitKind)%len(ALL_UNIT_KINDS)),
		faction = u8(clamp(faction, 0, SPRITE_FACTION_COUNT-1)),
		tint = rl.Color{255, 255, 255, 255},
	})
}

BloodDeath :: proc(
	w: ^World,
	x, y, dirX, dirY: f32,
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
	BloodSpray(w, x, y, dirX, dirY, severity, tint, int(13*scale)+int(PRandom(w)*8))

	// Flesh chunks and bone splinters accompany the main spray.
	gibCount := 2+int(PRandom(w)*4)
	for _ in 0 ..< gibCount {
		angle := PRandom(w)*6.2831853
		speed := PRandomRange(w, 1.2, 4.8)
		isBone := PRandom(w) < 0.22
		chunkColor := rl.Color{255, 255, 255, 255}
		if !isBone do chunkColor = BloodParticleColor(w, tint)
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
			kind = isBone ? .Bone : .Gib,
			tint = chunkColor,
		})
	}

	parts := 0
	switch kind {
	case .Catapult:
		// Siege engines return above.
	case .Giant:
		parts = 2+int(PRandom(w)*3)
	case .Turtle:
		parts = 1+int(PRandom(w)*2)
	case .Villager, .Builder, .CombatBuilder, .WaterCollector, .Farmer, .Knight, .Archer, .Mage, .Rogue, .Explorer:
		parts = 1+int(PRandom(w)*3)
	}
	for _ in 0 ..< parts {
		part := GorePartKind(int(PRandom(w)*GORE_PART_COUNT)%GORE_PART_COUNT)
		SpawnGorePart(w, x, y, PRandomRange(w, 0.4, 0.9), scale, faction, kind, part)
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
	victimSlot: int,
	damage: f32,
	sourceX, sourceY: f32,
	kind: DamageKind,
) -> bool {
	if victimSlot < 0 || victimSlot >= UNIT_CAPACITY || !w.unitUsed[victimSlot] do return false
	if damage <= 0 do return false

	x := w.units.x[victimSlot]
	y := w.units.y[victimSlot]
	type := w.units.type[victimSlot]
	faction := w.units.kingdome[victimSlot]

	w.units.health[victimSlot] -= damage
	dead := w.units.health[victimSlot] <= 0

	dirX := WorldShortestWrappedDelta(x-sourceX, f32(w.maxX))
	dirY := WorldShortestWrappedDelta(y-sourceY, f32(w.maxY))
	length := math.sqrt(dirX*dirX+dirY*dirY)
	if length > 0.001 {
		dirX /= length
		dirY /= length
	} else {
		angle := PRandom(w)*6.2831853
		dirX = math.cos(angle)
		dirY = math.sin(angle)
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
		BloodHit(w, x, y, dirX, dirY, damage, type)
		if dead do BloodDeath(w, x, y, dirX, dirY, damage, type, faction)
	case .Drowning:
		if PRandom(w) < 0.35 {
			ParticleSpawn(w, Particle{
				x = x+(PRandom(w)-0.5)*0.35,
				y = y+(PRandom(w)-0.5)*0.35,
				z = PRandomRange(w, 0.05, 0.35),
				vx = (PRandom(w)-0.5)*1.4,
				vy = (PRandom(w)-0.5)*1.4,
				vz = PRandomRange(w, 0.8, 2.4),
				life = PRandomRange(w, 0.25, 0.7),
				size = PRandomRange(w, 0.10, 0.22),
				drag = 1.5,
				gravity = 6,
				kind = .Splash,
				tint = rl.Color{206, 232, 242, 255},
			})
		}
	case .Poison:
		if PRandom(w) < 0.30 {
			ParticleSpawn(w, Particle{
				x = x+(PRandom(w)-0.5)*0.4,
				y = y+(PRandom(w)-0.5)*0.4,
				z = PRandomRange(w, 0.3, 0.9),
				vx = (PRandom(w)-0.5)*0.6,
				vy = (PRandom(w)-0.5)*0.6,
				vz = PRandomRange(w, 0.5, 1.4),
				life = PRandomRange(w, 0.6, 1.4),
				size = PRandomRange(w, 0.10, 0.22),
				drag = 1.2,
				gravity = -1,
				kind = .Smoke,
				tint = rl.Color{122, 194, 106, 220},
			})
		}
	}

	if dead {
		UnitDespawn(w, victimSlot)
		return true
	}
	return false
}

// Wounded units keep painting the ground as they stagger around.
BloodBleedTick :: proc(w: ^World, unitSlot: int, deltaTime: f32) {
	if unitSlot < 0 || unitSlot >= UNIT_CAPACITY || !w.unitUsed[unitSlot] do return
	type := w.units.type[unitSlot]
	kind := UnitKindOf(type)
	if kind == .Catapult do return

	tint := BloodTintForUnitType(type)
	if tint == BLOOD_TINT_NONE do return

	maxHealth := UnitMaxHealth(w, unitSlot)
	if maxHealth <= 0 do return
	ratio := w.units.health[unitSlot]/maxHealth
	if ratio > 0.55 do return

	rate := 0.12+(0.55-ratio)*1.2
	if PRandom(w) >= rate*deltaTime do return

	x := w.units.x[unitSlot]
	y := w.units.y[unitSlot]
	BloodDropSpawn(w, x, y, 0.22, PRandom(w)*6.2831853, PRandomRange(w, 0.1, 0.5), tint, PRandomRange(w, 0.12, 0.2))
	BloodAddAt(w, x, y, 1.2, 0.16, tint)
}

// --- structure and scenery debris ------------------------------------------

BuildingStoneMaterial :: proc(kind: BuildingKind) -> bool {
	switch kind {
	case .TownHall, .Wall, .Watchtower, .Cannon, .Bridge, .Path, .DistrictHall, .GiantMortar, .Harbor, .StarfallSpire:
		return true
	case .Home, .Farmland, .ArcheryRange, .MagicSchool, .GiantPen, .SiegeWorkshop, .TurtlePen, .ThievesGuild, .Granary, .AlchemistWorkshop, .FireworksGuild:
		return false
	}
	unreachable()
}

BuildingHitBurst :: proc(w: ^World, buildingSlot: int, impactX, impactY: f32) {
	if buildingSlot < 0 || buildingSlot >= BUILDING_CAPACITY || !w.buildingUsed[buildingSlot] do return
	kind := BuildingKindOf(w.buildings[buildingSlot].type)
	stone := BuildingStoneMaterial(kind)
	for _ in 0 ..< 1+int(PRandom(w)*2) {
		angle := PRandom(w)*6.2831853
		ParticleSpawn(w, Particle{
			x = impactX,
			y = impactY,
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

BuildingDestroyedBurst :: proc(w: ^World, buildingSlot: int) {
	if buildingSlot < 0 || buildingSlot >= BUILDING_CAPACITY || !w.buildingUsed[buildingSlot] do return
	kind := BuildingKindOf(w.buildings[buildingSlot].type)
	stone := BuildingStoneMaterial(kind)
	width, height := BuildingTileSize(w.buildings[buildingSlot].type)
	centerX := f32(w.buildings[buildingSlot].x)+f32(width)*0.5
	centerY := f32(w.buildings[buildingSlot].y)+f32(height)*0.5

	for _ in 0 ..< 16+int(PRandom(w)*12) {
		angle := PRandom(w)*6.2831853
		ParticleSpawn(w, Particle{
			x = centerX+(PRandom(w)-0.5)*f32(width)*0.7,
			y = centerY+(PRandom(w)-0.5)*f32(height)*0.5,
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
			x = centerX+(PRandom(w)-0.5)*f32(width)*0.8,
			y = centerY+(PRandom(w)-0.5)*f32(height)*0.7,
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
	case .Rubble:
		stone = true
		chips = 4
	case .BurntRubble:
		stone = true
		chips = 3
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

// Dust ring and shaken leaves for attacks that tear through scenery.
DecorationBlastBurst :: proc(w: ^World, x, y, radius: f32) {
	worldWidth := f32(w.maxX)
	worldHeight := f32(w.maxY)
	centerX := WorldWrapPosition(x, worldWidth)
	centerY := WorldWrapPosition(y, worldHeight)

	for _ in 0 ..< 4+int(radius*2) {
		angle := PRandom(w)*6.2831853
		distance := radius*(0.2+PRandom(w)*0.8)
		ParticleSpawn(w, Particle{
			x = WorldWrapPosition(centerX+math.cos(angle)*distance, worldWidth),
			y = WorldWrapPosition(centerY+math.sin(angle)*distance, worldHeight),
			z = PRandomRange(w, 0.05, 0.30),
			vx = math.cos(angle)*PRandomRange(w, 0.3, 1.4),
			vy = math.sin(angle)*PRandomRange(w, 0.3, 1.4),
			vz = PRandomRange(w, 0.15, 0.8),
			life = PRandomRange(w, 0.4, 1.0),
			size = PRandomRange(w, 0.16, 0.42),
			drag = 2.5,
			gravity = 0.8,
			kind = .Dust,
			tint = rl.Color{196, 180, 150, 220},
		})
	}
	for _ in 0 ..< 3+int(radius) {
		angle := PRandom(w)*6.2831853
		distance := radius*(0.3+PRandom(w)*0.7)
		ParticleSpawn(w, Particle{
			x = WorldWrapPosition(centerX+math.cos(angle)*distance, worldWidth),
			y = WorldWrapPosition(centerY+math.sin(angle)*distance, worldHeight),
			z = PRandomRange(w, 0.6, 1.8),
			vx = math.cos(angle)*PRandomRange(w, 0.2, 1.2),
			vy = math.sin(angle)*PRandomRange(w, 0.2, 1.2),
			vz = PRandomRange(w, 0.3, 1.4),
			life = PRandomRange(w, 1.2, 2.6),
			size = PRandomRange(w, 0.10, 0.20),
			rotation = PRandom(w)*360,
			spin = PRandomRange(w, -180, 180),
			drag = 1.8,
			gravity = 2.5,
			bounce = 0.1,
			kind = .Leaf,
			tint = rl.Color{255, 255, 255, 255},
		})
	}
}

// --- fire ambience ----------------------------------------------------------

FireParticleTick :: proc(w: ^World, fireSlot: int, deltaTime: f32) {
	intensity := w.fires.intensity[fireSlot]
	x := w.fires.x[fireSlot]
	y := w.fires.y[fireSlot]

	if PRandom(w) < 0.42*deltaTime*intensity {
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
	if PRandom(w) < 0.30*deltaTime*intensity {
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

	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 do return
	blocksY := (worldHeight+BLOOD_DIRTY_BLOCK-1)/BLOOD_DIRTY_BLOCK
	if blocksY <= 0 do return

	// Upload a bounded number of dirty blocks per frame. Two battles on
	// opposite sides of the map therefore cost two small uploads instead of
	// re-uploading the whole stain texture every frame.
	processCount := min(len(w.blood.dirtyList), BLOOD_BLOCK_UPLOADS_PER_FRAME)
	for blockIndex in 0 ..< processCount {
		block := w.blood.dirtyList[blockIndex]
		blockX := block/blocksY
		blockY := block%blocksY
		minX := blockX*BLOOD_DIRTY_BLOCK
		minY := blockY*BLOOD_DIRTY_BLOCK
		maxX := min(minX+BLOOD_DIRTY_BLOCK-1, worldWidth-1)
		maxY := min(minY+BLOOD_DIRTY_BLOCK-1, worldHeight-1)
		width := maxX-minX+1
		height := maxY-minY+1
		if width <= 0 || height <= 0 do continue

		needed := width*height*4
		if len(renderer.bloodPixels) < needed do resize(&renderer.bloodPixels, needed)
		pixels := renderer.bloodPixels[:needed]

		for tileY in 0 ..< height {
			for tileX in 0 ..< width {
				x := minX+tileX
				y := minY+tileY
				index := x*worldHeight+y
				pixel := (tileY*width+tileX)*4
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
					neighbourX := WorldWrapCoordinate(x+offset[0], worldWidth)
					neighbourY := WorldWrapCoordinate(y+offset[1], worldHeight)
					total += int(w.blood.amount[neighbourX*worldHeight+neighbourY])
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
				shade := (0.42+0.46*math.sqrt(tone))*(0.88+0.24*WorldNoiseHash(x, y, 0xB100D5))
				alpha := u8(clamp(smooth*1.05+20, 0, 130))
				pixels[pixel+0] = u8(clamp(f32(tint.r)*shade, 0, 255))
				pixels[pixel+1] = u8(clamp(f32(tint.g)*shade, 0, 255))
				pixels[pixel+2] = u8(clamp(f32(tint.b)*shade, 0, 255))
				pixels[pixel+3] = alpha
			}
		}

		rl.UpdateTextureRec(
			renderer.bloodTexture,
			rl.Rectangle{f32(minX), f32(minY), f32(width), f32(height)},
			raw_data(pixels),
		)
		w.blood.dirtyMarker[block] = false
	}

	remaining := len(w.blood.dirtyList)-processCount
	if remaining > 0 {
		copy(w.blood.dirtyList[:remaining], w.blood.dirtyList[processCount:])
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
	firstCopyX, lastCopyX, firstCopyY, lastCopyY: int,
) {
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 do return

	halfViewWidth := f32(rl.GetScreenWidth())/(2*camera.zoom)
	halfViewHeight := f32(rl.GetScreenHeight())/(2*camera.zoom)

	for copyX in firstCopyX ..< lastCopyX+1 {
		offsetX := f32(copyX)*f32(worldWidth)
		for copyY in firstCopyY ..< lastCopyY+1 {
			offsetY := f32(copyY)*f32(worldHeight)
			minX := camera.target.x-halfViewWidth-offsetX
			maxX := camera.target.x+halfViewWidth-offsetX
			minY := camera.target.y-halfViewHeight-offsetY
			maxY := camera.target.y+halfViewHeight-offsetY

			firstX := WorldFloor(minX)-1
			lastX := WorldFloor(maxX)+1
			firstY := WorldFloor(minY)-1
			lastY := WorldFloor(maxY)+1
			if lastX-firstX >= worldWidth {
				firstX = 0
				lastX = worldWidth-1
			}
			if lastY-firstY >= worldHeight {
				firstY = 0
				lastY = worldHeight-1
			}

			for tileY in firstY ..= lastY {
				wrappedY := WorldWrapCoordinate(tileY, worldHeight)
				for tileX in firstX ..= lastX {
					wrappedX := WorldWrapCoordinate(tileX, worldWidth)
					index := wrappedX*worldHeight+wrappedY
					amount := int(w.blood.amount[index])
					if amount < 6 do continue
					if !FogTileVisible(w, wrappedX, wrappedY) do continue

					hashA := WorldNoiseHash(wrappedX, wrappedY, 0xB100D51)
					hashB := WorldNoiseHash(wrappedY, wrappedX, 0xB100D52)
					hashC := WorldNoiseHash(wrappedX+7, wrappedY+3, 0xB100D53)
					hashD := WorldNoiseHash(wrappedX+11, wrappedY+17, 0xB100D54)
					// Dense pools overlap heavily; skipping part of them keeps the
					// draw count sane without opening holes in the stain.
					if amount > 110 && hashD < 0.42 do continue
					variant := int(hashA*BLOOD_SPLAT_VARIANTS)%BLOOD_SPLAT_VARIANTS
					texture := renderer.sprites.bloodSplat[variant]
					if texture.id == 0 do continue

					size := 1.25+hashB*1.25+clamp(f32(amount)/255, 0, 1)*0.5
					if amount > 110 do size += 0.6
					jitterX := (hashC-0.5)*0.5
					jitterY := (hashA-0.5)*0.5
					tint := CShade(BloodPaletteColor(w.blood.tint[index]), 0.72+0.34*hashB)
					tint.a = u8(clamp(f32(amount)*1.15+55, 0, 210))
					source := rl.Rectangle{0, 0, f32(texture.width), f32(texture.height)}
					rl.DrawTexturePro(
						texture,
						source,
						rl.Rectangle{
							offsetX+f32(wrappedX)+0.5+jitterX-size*0.5,
							offsetY+f32(wrappedY)+0.5+jitterY-size*0.5,
							size,
							size,
						},
						rl.Vector2{size*0.5, size*0.5},
						hashC*360,
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
	firstCopyX, lastCopyX, firstCopyY, lastCopyY: int,
) {
	worldWidth := f32(w.maxX)
	worldHeight := f32(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 do return

	if renderer.bloodTexture.id != 0 {
		source := rl.Rectangle{0, 0, worldWidth, worldHeight}
		for copyX in firstCopyX ..< lastCopyX+1 {
			for copyY in firstCopyY ..< lastCopyY+1 {
				rl.DrawTexturePro(
					renderer.bloodTexture,
					source,
					rl.Rectangle{
						f32(copyX)*worldWidth,
						f32(copyY)*worldHeight,
						worldWidth,
						worldHeight,
					},
					rl.Vector2{0, 0},
					0,
					rl.WHITE,
				)
			}
		}
	}

	if camera.zoom >= BLOOD_TILE_SPLAT_MIN_ZOOM && renderer.sprites.bloodSplat[0].id != 0 {
		BloodRenderTileSplats(w, renderer, camera, firstCopyX, lastCopyX, firstCopyY, lastCopyY)
	}

	if camera.zoom < BLOOD_DECAL_MIN_ZOOM do return
	if renderer.sprites.bloodSplat[0].id == 0 || w.blood.decalCount <= 0 do return

	halfViewWidth := f32(rl.GetScreenWidth())/(2*camera.zoom)
	halfViewHeight := f32(rl.GetScreenHeight())/(2*camera.zoom)

	for copyX in firstCopyX ..< lastCopyX+1 {
		offsetX := f32(copyX)*worldWidth
		for copyY in firstCopyY ..< lastCopyY+1 {
			offsetY := f32(copyY)*worldHeight
			minX := camera.target.x-halfViewWidth-offsetX
			maxX := camera.target.x+halfViewWidth-offsetX
			minY := camera.target.y-halfViewHeight-offsetY
			maxY := camera.target.y+halfViewHeight-offsetY

			for i in 0 ..< BLOOD_DECAL_CAPACITY {
				decal := w.blood.decals[i]
				if decal.life <= 0 do continue
				half := decal.size*0.5
				if decal.x+half < minX || decal.x-half > maxX ||
					decal.y+half < minY || decal.y-half > maxY {
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

				tint := CShade(BloodPaletteColor(decal.tint), f32(decal.brightness)/100)
				fade := clamp(decal.life/6, 0, 1)
				tint.a = u8(235*fade)
				source := rl.Rectangle{0, 0, f32(texture.width), f32(texture.height)}
				rl.DrawTexturePro(
					texture,
					source,
					rl.Rectangle{
						offsetX+decal.x-half,
						offsetY+decal.y-half,
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

// Temporary coverage mask used while building a stain. The mask lets the
// generator put a crisp dark rim around the whole silhouette instead of
// outlining every overlapping lobe separately.
BloodMask :: struct {
	pixels: []bool,
	width:  int,
	height: int,
}

BloodMaskSet :: proc(mask: ^BloodMask, x, y: int) {
	if x < 0 || y < 0 || x >= mask.width || y >= mask.height do return
	mask.pixels[y*mask.width+x] = true
}

BloodMaskClear :: proc(mask: ^BloodMask, x, y: int) {
	if x < 0 || y < 0 || x >= mask.width || y >= mask.height do return
	mask.pixels[y*mask.width+x] = false
}

BloodMaskEllipse :: proc(mask: ^BloodMask, cx, cy, rx, ry: int) {
	if rx <= 0 || ry <= 0 do return
	for y in -ry ..= ry {
		for x in -rx ..= rx {
			if x*x*ry*ry+y*y*rx*rx <= rx*rx*ry*ry {
				BloodMaskSet(mask, cx+x, cy+y)
			}
		}
	}
}

BloodMaskClearEllipse :: proc(mask: ^BloodMask, cx, cy, rx, ry: int) {
	if rx <= 0 || ry <= 0 do return
	for y in -ry ..= ry {
		for x in -rx ..= rx {
			if x*x*ry*ry+y*y*rx*rx <= rx*rx*ry*ry {
				BloodMaskClear(mask, cx+x, cy+y)
			}
		}
	}
}

BloodMaskLine :: proc(mask: ^BloodMask, x0, y0, x1, y1, radius: int) {
	dx := x1-x0
	dy := y1-y0
	steps := max(abs(dx), abs(dy))
	if steps <= 0 {
		BloodMaskEllipse(mask, x0, y0, max(radius, 1), max(radius, 1))
		return
	}
	for step in 0 ..= steps {
		t := f32(step)/f32(steps)
		x := int(f32(x0)+f32(dx)*t+0.5)
		y := int(f32(y0)+f32(dy)*t+0.5)
		if radius <= 1 {
			BloodMaskSet(mask, x, y)
		} else {
			BloodMaskEllipse(mask, x, y, radius, radius)
		}
	}
}

DrawBloodSplatArt :: proc(seed: u64, size: int, pool: bool) -> Art {
	art := ArtInit(size, size)
	maskPixels := make([]bool, size*size)
	defer delete(maskPixels)
	mask := BloodMask{pixels = maskPixels, width = size, height = size}

	center := f32(size)*0.5
	base := f32(size)*(pool ? 0.25 : 0.21)
	sprayAngle := WorldNoiseHash(int(seed), 3, 0xB30)*6.2831853

	// Main mass: overlapping, irregular lobes around the impact point.
	lobes := 7+int(WorldNoiseHash(int(seed), 1, 0xB31)*4)
	for i in 0 ..< lobes {
		angle := 6.2831853*f32(i)/f32(lobes)+WorldNoiseHash(i, int(seed), 0xB32)*0.8
		distance := base*WorldNoiseHash(i, int(seed)+3, 0xB33)*0.48
		radiusX := int(base*(0.42+0.42*WorldNoiseHash(i, int(seed)+5, 0xB34)))
		radiusY := int(base*(0.38+0.42*WorldNoiseHash(i, int(seed)+7, 0xB35)))
		px := int(center+math.cos(angle)*distance)
		py := int(center+math.sin(angle)*distance)
		BloodMaskEllipse(&mask, px, py, max(radiusX, 2), max(radiusY, 2))
	}

	// Splats carry a directional spray; pools spread evenly.
	if !pool {
		for i in 0 ..< 4 {
			distance := base*(0.25+0.22*f32(i))
			radius := max(int(base*(0.28-0.045*f32(i))), 2)
			px := int(center+math.cos(sprayAngle)*distance)
			py := int(center+math.sin(sprayAngle)*distance)
			BloodMaskEllipse(&mask, px, py, radius, radius)
		}
	}

	// Satellite droplets break up the silhouette.
	droplets := 14+int(WorldNoiseHash(int(seed), 31, 0xB36)*10)
	if pool do droplets += 6
	for i in 0 ..< droplets {
		angle := WorldNoiseHash(i, int(seed)+33, 0xB37)*6.2831853
		distance := base*(0.75+WorldNoiseHash(i, int(seed)+37, 0xB38)*(pool ? 0.80 : 0.95))
		radius := 1+int(WorldNoiseHash(i, int(seed)+41, 0xB39)*(pool ? 3.2 : 2.4))
		px := int(center+math.cos(angle)*distance)
		py := int(center+math.sin(angle)*distance)
		BloodMaskEllipse(&mask, px, py, radius, radius)
	}

	// Thin tendrils where the spray ran outward.
	streaks := 3+int(WorldNoiseHash(int(seed), 43, 0xB3A)*4)
	for i in 0 ..< streaks {
		angle := WorldNoiseHash(i, int(seed)+47, 0xB3B)*6.2831853
		startX := int(center+math.cos(angle)*base*0.55)
		startY := int(center+math.sin(angle)*base*0.55)
		endX := int(center+math.cos(angle)*base*1.55)
		endY := int(center+math.sin(angle)*base*1.55)
		BloodMaskLine(&mask, startX, startY, endX, endY, 1)
	}

	// Punch holes so the terrain shows through and the edge is not solid.
	holes := (pool ? 2 : 3)+int(WorldNoiseHash(int(seed), 53, 0xB3C)*(pool ? 3 : 4))
	for i in 0 ..< holes {
		angle := WorldNoiseHash(i, int(seed)+59, 0xB3D)*6.2831853
		distance := base*WorldNoiseHash(i, int(seed)+61, 0xB3E)*(pool ? 0.85 : 0.70)
		if pool do distance += base*0.30
		px := int(center+math.cos(angle)*distance)
		py := int(center+math.sin(angle)*distance)
		radius := 1+int(WorldNoiseHash(i, int(seed)+67, 0xB3F)*(pool ? 1.4 : 2.0))
		BloodMaskClearEllipse(&mask, px, py, radius, radius)
	}

	// Render flat layers with a dark blood rim, matching the outlined sprites.
	offsets := [4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
	for y in 0 ..< size {
		for x in 0 ..< size {
			if !mask.pixels[y*size+x] do continue
			edge := false
			for offset in offsets {
				nx := x+offset[0]
				ny := y+offset[1]
				if nx < 0 || ny < 0 || nx >= size || ny >= size || !mask.pixels[ny*size+nx] {
					edge = true
					break
				}
			}
			if edge {
				ArtPixel(&art, x, y, C_SPLAT_RIM)
				continue
			}

			dx := (f32(x)+0.5-center)/base
			dy := (f32(y)+0.5-center)/base
			distance := math.sqrt(dx*dx+dy*dy)
			grain := WorldNoiseHash(x/2, y/2, seed+0xB40)
			tone: rl.Color
			if pool {
				if distance < 0.40+grain*0.12 {
					tone = C_SPLAT_DEEP
				} else if distance < 0.72+grain*0.10 {
					tone = C_SPLAT_DARK
				} else {
					tone = C_SPLAT_MID
				}
			} else {
				if distance < 0.34+grain*0.10 {
					tone = C_SPLAT_LIGHT
				} else if distance < 0.68+grain*0.10 {
					tone = C_SPLAT_MID
				} else {
					tone = C_SPLAT_DARK
				}
			}
			ArtPixel(&art, x, y, tone)
		}
	}

	// Stray specks around the stain sell the spray direction.
	specks := 10+int(WorldNoiseHash(int(seed), 71, 0xB41)*8)
	for i in 0 ..< specks {
		angle := WorldNoiseHash(i, int(seed)+73, 0xB42)*6.2831853
		distance := base*(1.2+WorldNoiseHash(i, int(seed)+79, 0xB43)*(pool ? 0.6 : 0.7))
		px := int(center+math.cos(angle)*distance)
		py := int(center+math.sin(angle)*distance)
		radius := 1+int(WorldNoiseHash(i, int(seed)+83, 0xB44)*1.6)
		ArtCircle(&art, px, py, radius, C_SPLAT_RIM)
		if radius > 1 {
			ArtPixel(&art, px, py, C_SPLAT_DARK)
		}
	}

	return art
}

GoreHeadgear :: enum {
	Hair,
	Bald,
	Helmet,
	Cap,
	Hood,
	WideHat,
	StrawHat,
	Headwrap,
	ArcaneHat,
}

// Colours and silhouette cues borrowed from each unit sprite so a severed
// limb reads as belonging to the unit that actually died.
GoreLook :: struct {
	skin:      rl.Color, // exposed flesh
	skinDark:  rl.Color, // shadowed flesh
	hair:      rl.Color, // hair, mane or beard
	body:      rl.Color, // main garment or armour
	bodyDark:  rl.Color, // shaded garment or armour
	bodyLight: rl.Color, // trim on garment or armour
	boot:      rl.Color, // boots and belts
	hat:       rl.Color, // headgear
	hatDark:   rl.Color, // headgear shadow
	headgear:  GoreHeadgear,
	armored:   bool, // torso and limbs show plate instead of cloth
}

GoreLookForUnit :: proc(kind: UnitKind) -> GoreLook {
	look := GoreLook {
		skin      = C_SKIN,
		skinDark  = C_SKIN_DARK,
		hair      = C_HAIR,
		body      = C_CLOTH,
		bodyDark  = C_CLOTH_DARK,
		bodyLight = C_CLOTH_LIGHT,
		boot      = C_WOOD_DARKEST,
		hat       = C_CLOTH_DARK,
		hatDark    = C_CLOTH_DARKEST,
		headgear  = .Hair,
		armored   = false,
	}
	switch kind {
	case .Villager:
	case .Builder:
		look.body = C_LEAF_DARK
		look.bodyDark = C_LEAF_DARKEST
		look.bodyLight = C_LEAF
		look.hat = C_WOOD_DARK
		look.hatDark = C_WOOD_DARKEST
		look.headgear = .Cap
	case .CombatBuilder:
		look.body = C_IRON_DARK
		look.bodyDark = C_IRON_DARK
		look.bodyLight = C_IRON
		look.hat = C_IRON
		look.hatDark = C_IRON_DARK
		look.headgear = .Helmet
		look.armored = true
	case .WaterCollector:
		look.body = C_WATER_DARK
		look.bodyDark = C_WATER_DARK
		look.bodyLight = C_WATER_LIGHT
		look.hat = C_WATER_DARK
		look.hatDark = C_WATER_DARK
		look.headgear = .Headwrap
	case .Farmer:
		look.body = C_LEAF_DARK
		look.bodyDark = C_LEAF_DARKEST
		look.bodyLight = C_LEAF
		look.hat = C_GOLD
		look.hatDark = C_GOLD_DARK
		look.headgear = .StrawHat
	case .Knight:
		look.body = C_IRON_DARK
		look.bodyDark = C_IRON_DARK
		look.bodyLight = C_IRON_LIGHT
		look.hat = C_IRON
		look.hatDark = C_IRON_DARK
		look.headgear = .Helmet
		look.armored = true
	case .Archer:
		look.body = C_LEAF_DARK
		look.bodyDark = C_LEAF_DARKEST
		look.bodyLight = C_LEAF
		look.hat = C_LEAF_DARK
		look.hatDark = C_LEAF_DARKEST
		look.headgear = .Cap
	case .Mage:
		look.skin = rl.Color{214, 198, 196, 255}
		look.skinDark = rl.Color{160, 138, 150, 255}
		look.hair = C_WHITE
		look.body = C_ARCANE_DARK
		look.bodyDark = rl.Color{40, 26, 70, 255}
		look.bodyLight = C_ARCANE
		look.hat = C_ARCANE_DARK
		look.hatDark = rl.Color{40, 26, 70, 255}
		look.headgear = .ArcaneHat
	case .Rogue:
		look.body = C_CLOTH_DARKEST
		look.bodyDark = rl.Color{30, 26, 40, 255}
		look.bodyLight = C_CLOTH_DARK
		look.hat = C_CLOTH_DARKEST
		look.hatDark = rl.Color{30, 26, 40, 255}
		look.headgear = .Hood
	case .Explorer:
		look.body = C_CLOTH_LIGHT
		look.bodyDark = C_CLOTH
		look.bodyLight = C_CLOTH_LIGHT
		look.hat = C_WOOD_DARK
		look.hatDark = C_WOOD_DARKEST
		look.headgear = .WideHat
	case .Giant:
		look.body = C_WOOD_DARK
		look.bodyDark = C_WOOD_DARKEST
		look.bodyLight = C_WOOD
		look.headgear = .Bald
	case .Turtle, .Catapult:
		// Dedicated art; these never use a humanoid body.
	}
	return look
}

GoreBloodColors :: proc(tint: u8) -> (entrail, entrailDark, entrailLight: rl.Color) {
	base := BloodPaletteColor(tint)
	entrail = CShade(base, 1.32)
	entrailDark = CShade(base, 0.58)
	entrailLight = CShade(base, 1.85)
	return
}

DrawHumanoidGoreHead :: proc(
	look: GoreLook,
	accent: rl.Color,
	entrail, entrailDark: rl.Color,
) -> Art {
	art := ArtInit(12, 12)
	ArtEllipse(&art, 6, 4, 4, 4, C_OUTLINE)
	ArtEllipse(&art, 6, 4, 3, 3, look.skin)
	ArtRect(&art, 4, 6, 5, 1, look.skinDark)
	ArtPixel(&art, 4, 4, C_OUTLINE)
	ArtPixel(&art, 8, 4, C_OUTLINE)
	ArtPixel(&art, 5, 5, look.skinDark)
	ArtRect(&art, 4, 8, 5, 1, entrailDark)
	ArtRect(&art, 5, 9, 3, 1, entrail)
	ArtPixel(&art, 5, 10, C_BONE)
	ArtPixel(&art, 8, 10, C_BONE)

	switch look.headgear {
	case .Hair:
		ArtRect(&art, 3, 1, 6, 2, look.hair)
		ArtRect(&art, 2, 3, 1, 2, look.hair)
		ArtRect(&art, 9, 3, 1, 2, look.hair)
		ArtPixel(&art, 5, 1, CShade(look.hair, 1.2))
	case .Bald:
		ArtPixel(&art, 5, 0, look.skinDark)
		ArtPixel(&art, 6, 0, look.skinDark)
		ArtPixel(&art, 4, 1, look.skinDark)
		ArtRect(&art, 5, 7, 3, 1, look.hair)
	case .Helmet:
		ArtEllipse(&art, 6, 3, 4, 4, C_OUTLINE)
		ArtEllipse(&art, 6, 3, 3, 3, look.hat)
		ArtRect(&art, 3, 3, 7, 1, look.hatDark)
		ArtRect(&art, 4, 5, 5, 1, C_OUTLINE)
		ArtPixel(&art, 4, 5, look.hatDark)
		ArtPixel(&art, 8, 5, look.hatDark)
		ArtRect(&art, 5, 7, 3, 1, look.skinDark)
		ArtRect(&art, 6, 0, 2, 2, accent)
		ArtPixel(&art, 7, 0, CShade(accent, 1.25))
	case .Cap:
		ArtRect(&art, 3, 1, 6, 2, C_OUTLINE)
		ArtRect(&art, 4, 1, 5, 1, look.hat)
		ArtRect(&art, 2, 2, 8, 1, C_OUTLINE)
		ArtRect(&art, 3, 2, 6, 1, look.hatDark)
	case .Hood:
		ArtRect(&art, 2, 1, 8, 3, C_OUTLINE)
		ArtRect(&art, 3, 1, 6, 2, look.hat)
		ArtRect(&art, 2, 2, 1, 4, C_OUTLINE)
		ArtRect(&art, 9, 2, 1, 4, C_OUTLINE)
		ArtRect(&art, 3, 2, 1, 3, look.hat)
		ArtRect(&art, 8, 2, 1, 3, look.hat)
		ArtPixel(&art, 4, 4, accent)
		ArtPixel(&art, 8, 4, accent)
	case .WideHat:
		ArtRect(&art, 1, 1, 10, 1, C_OUTLINE)
		ArtRect(&art, 2, 1, 8, 1, look.hatDark)
		ArtRect(&art, 4, 0, 4, 2, C_OUTLINE)
		ArtRect(&art, 5, 0, 2, 1, look.hat)
	case .StrawHat:
		ArtRect(&art, 1, 2, 10, 1, C_OUTLINE)
		ArtRect(&art, 2, 2, 8, 1, look.hatDark)
		ArtRect(&art, 3, 1, 6, 1, look.hat)
		ArtRect(&art, 4, 0, 4, 2, C_OUTLINE)
		ArtRect(&art, 5, 0, 2, 1, look.hat)
	case .Headwrap:
		ArtRect(&art, 2, 1, 8, 2, C_OUTLINE)
		ArtRect(&art, 3, 1, 6, 1, look.hat)
		ArtRect(&art, 3, 2, 6, 1, look.hatDark)
		ArtPixel(&art, 5, 1, look.bodyLight)
	case .ArcaneHat:
		ArtRect(&art, 1, 2, 10, 1, C_OUTLINE)
		ArtRect(&art, 2, 2, 8, 1, look.hat)
		hat := [3]Point{{4, 2}, {9, 2}, {7, 0}}
		ArtPolygon(&art, hat[:], C_OUTLINE)
		innerHat := [3]Point{{5, 2}, {8, 2}, {7, 1}}
		ArtPolygon(&art, innerHat[:], look.hatDark)
		ArtPixel(&art, 7, 1, C_ARCANE_GLOW)
		ArtRect(&art, 5, 5, 4, 1, C_WHITE)
	}
	return art
}

DrawHumanoidGoreArm :: proc(
	look: GoreLook,
	accent: rl.Color,
	entrail, entrailDark: rl.Color,
) -> Art {
	art := ArtInit(15, 7)
	ArtEllipse(&art, 3, 3, 3, 2, C_OUTLINE)
	ArtEllipse(&art, 6, 3, 3, 2, C_OUTLINE)
	ArtEllipse(&art, 9, 2, 2, 2, C_OUTLINE)
	ArtEllipse(&art, 11, 2, 2, 2, C_OUTLINE)
	ArtEllipse(&art, 3, 3, 2, 1, look.body)
	ArtEllipse(&art, 6, 3, 2, 1, look.bodyDark)
	ArtEllipse(&art, 9, 2, 1, 1, look.skin)
	ArtEllipse(&art, 11, 2, 1, 1, look.skin)
	ArtRect(&art, 9, 0, 4, 4, C_OUTLINE)
	ArtRect(&art, 10, 1, 2, 2, look.armored ? look.bodyLight : accent)
	ArtPixel(&art, 11, 1, CShade(look.armored ? look.bodyLight : accent, 1.2))
	ArtEllipse(&art, 1, 3, 2, 1, entrailDark)
	ArtPixel(&art, 1, 3, C_BONE)
	ArtPixel(&art, 4, 4, entrailDark)
	ArtPixel(&art, 6, 2, entrail)
	if look.armored {
		ArtLine(&art, 4, 2, 8, 2, look.bodyLight)
	}
	return art
}

DrawHumanoidGoreLeg :: proc(look: GoreLook, entrail, entrailDark: rl.Color) -> Art {
	art := ArtInit(9, 14)
	ArtEllipse(&art, 4, 3, 3, 3, C_OUTLINE)
	ArtEllipse(&art, 4, 6, 3, 3, C_OUTLINE)
	ArtEllipse(&art, 4, 9, 2, 2, C_OUTLINE)
	ArtEllipse(&art, 4, 12, 2, 2, C_OUTLINE)
	ArtEllipse(&art, 4, 3, 2, 2, look.body)
	ArtEllipse(&art, 4, 6, 2, 2, look.bodyDark)
	ArtEllipse(&art, 4, 9, 1, 1, look.armored ? look.bodyLight : look.skin)
	ArtEllipse(&art, 4, 12, 1, 1, look.armored ? look.bodyLight : look.skin)
	ArtRect(&art, 2, 11, 4, 3, C_OUTLINE)
	ArtRect(&art, 3, 11, 3, 2, look.boot)
	ArtPixel(&art, 3, 12, CShade(look.boot, 1.2))
	ArtEllipse(&art, 4, 1, 2, 1, entrailDark)
	ArtPixel(&art, 4, 1, C_BONE)
	ArtPixel(&art, 5, 5, entrailDark)
	ArtPixel(&art, 3, 7, entrail)
	if look.armored {
		ArtLine(&art, 2, 7, 6, 7, look.bodyLight)
	}
	return art
}

DrawHumanoidGoreTorso :: proc(
	look: GoreLook,
	accent: rl.Color,
	entrail, entrailDark, entrailLight: rl.Color,
) -> Art {
	art := ArtInit(16, 14)
	spans := [12]int{4, 7, 9, 10, 11, 11, 11, 10, 9, 8, 7, 6}
	center := 8
	for y in 0 ..< len(spans) {
		width := spans[y]
		x := center-width/2
		ArtRect(&art, x, y+1, width, 1, C_OUTLINE)
	}
	for y in 1 ..< len(spans)-1 {
		width := spans[y]-2
		x := center-width/2
		ArtRect(&art, x, y+1, width, 1, look.body)
	}
	for y in 2 ..< 8 {
		width := spans[y]-4
		x := center-width/2
		ArtRect(&art, x, y+1, width, 1, look.bodyDark)
	}
	ArtRect(&art, 4, 6, 8, 1, accent)
	if look.armored {
		ArtLine(&art, 3, 5, 13, 5, look.bodyLight)
		ArtLine(&art, 4, 9, 12, 9, look.bodyLight)
		ArtPixel(&art, 8, 7, C_GOLD_LIGHT)
	} else {
		ArtRect(&art, 5, 7, 6, 1, accent)
	}
	ArtRect(&art, 5, 1, 6, 2, entrailDark)
	ArtRect(&art, 6, 1, 4, 1, entrail)
	ArtRect(&art, 4, 9, 8, 2, entrailDark)
	ArtRect(&art, 5, 10, 6, 1, entrail)
	ArtRect(&art, 6, 10, 4, 1, entrailLight)
	ArtPixel(&art, 6, 11, C_BONE)
	ArtPixel(&art, 8, 11, C_BONE)
	ArtPixel(&art, 10, 11, C_BONE)
	ArtLine(&art, 5, 4, 10, 8, entrailDark)
	ArtPixel(&art, 10, 5, entrail)
	ArtPixel(&art, 3, 7, entrailDark)
	return art
}

DrawHumanoidGoreHand :: proc(look: GoreLook, entrail, entrailDark: rl.Color) -> Art {
	art := ArtInit(7, 7)
	ArtEllipse(&art, 3, 3, 2, 2, C_OUTLINE)
	ArtEllipse(&art, 3, 3, 1, 1, look.skin)
	ArtPixel(&art, 4, 2, look.skinDark)
	ArtRect(&art, 0, 2, 2, 2, entrailDark)
	ArtPixel(&art, 0, 2, C_BONE)
	ArtPixel(&art, 1, 3, entrail)
	return art
}

DrawHumanoidGoreIntestine :: proc(entrail, entrailDark, entrailLight: rl.Color) -> Art {
	art := ArtInit(17, 10)
	for i in 0 ..< 6 {
		x := 2+i*2
		y := 5+int(math.sin(f32(i)*1.7)*2)
		ArtCircle(&art, x, y, 2, C_OUTLINE)
		ArtCircle(&art, x, y, 1, entrail)
	}
	ArtPixel(&art, 4, 3, entrailDark)
	ArtPixel(&art, 10, 5, entrailDark)
	ArtPixel(&art, 7, 7, entrailLight)
	ArtPixel(&art, 12, 4, entrailLight)
	return art
}

DrawGiantGorePart :: proc(part: GorePartKind, accent, entrail, entrailDark: rl.Color) -> Art {
	switch part {
	case .Head:
		art := ArtInit(16, 16)
		ArtEllipse(&art, 8, 6, 6, 6, C_OUTLINE)
		ArtEllipse(&art, 8, 6, 5, 5, C_SKIN)
		ArtRect(&art, 4, 9, 9, 2, C_SKIN_DARK)
		ArtRect(&art, 4, 1, 9, 3, C_HAIR)
		ArtRect(&art, 3, 4, 2, 3, C_HAIR)
		ArtRect(&art, 12, 4, 2, 3, C_HAIR)
		ArtPixel(&art, 6, 6, C_OUTLINE)
		ArtPixel(&art, 10, 6, C_OUTLINE)
		ArtRect(&art, 6, 8, 5, 1, C_HAIR)
		ArtPixel(&art, 5, 9, C_BONE)
		ArtPixel(&art, 11, 9, C_BONE)
		ArtRect(&art, 6, 11, 5, 1, entrailDark)
		ArtRect(&art, 7, 12, 3, 1, entrail)
		ArtPixel(&art, 7, 14, C_BONE)
		ArtPixel(&art, 10, 14, C_BONE)
		return art
	case .Arm:
		art := ArtInit(22, 11)
		ArtEllipse(&art, 4, 5, 4, 3, C_OUTLINE)
		ArtEllipse(&art, 9, 5, 4, 3, C_OUTLINE)
		ArtEllipse(&art, 14, 4, 3, 3, C_OUTLINE)
		ArtEllipse(&art, 18, 4, 3, 3, C_OUTLINE)
		ArtEllipse(&art, 4, 5, 3, 2, C_SKIN_DARK)
		ArtEllipse(&art, 9, 5, 3, 2, C_SKIN)
		ArtEllipse(&art, 14, 4, 2, 2, C_SKIN_DARK)
		ArtEllipse(&art, 18, 4, 2, 2, C_SKIN)
		ArtRect(&art, 15, 1, 6, 6, C_OUTLINE)
		ArtRect(&art, 16, 2, 4, 4, C_WOOD_DARK)
		ArtRect(&art, 16, 2, 4, 1, C_WOOD_LIGHT)
		ArtEllipse(&art, 1, 5, 2, 2, entrailDark)
		ArtPixel(&art, 1, 5, C_BONE)
		ArtPixel(&art, 6, 6, entrailDark)
		ArtPixel(&art, 9, 4, entrail)
		return art
	case .Leg:
		art := ArtInit(14, 20)
		ArtEllipse(&art, 7, 4, 5, 4, C_OUTLINE)
		ArtEllipse(&art, 7, 9, 4, 4, C_OUTLINE)
		ArtEllipse(&art, 7, 14, 3, 3, C_OUTLINE)
		ArtEllipse(&art, 7, 17, 3, 3, C_OUTLINE)
		ArtEllipse(&art, 7, 4, 4, 3, C_SKIN)
		ArtEllipse(&art, 7, 9, 3, 3, C_SKIN_DARK)
		ArtEllipse(&art, 7, 14, 2, 2, C_SKIN)
		ArtEllipse(&art, 7, 17, 2, 2, C_SKIN_DARK)
		ArtRect(&art, 3, 17, 8, 3, C_OUTLINE)
		ArtRect(&art, 4, 17, 6, 2, C_SKIN_DARK)
		ArtPixel(&art, 4, 17, C_SKIN)
		ArtRect(&art, 4, 6, 6, 2, accent)
		ArtRect(&art, 4, 6, 6, 1, CShade(accent, 1.3))
		ArtEllipse(&art, 7, 1, 3, 2, entrailDark)
		ArtPixel(&art, 7, 1, C_BONE)
		ArtPixel(&art, 8, 3, entrailDark)
		ArtPixel(&art, 6, 6, entrail)
		return art
	case .Torso:
		art := ArtInit(22, 18)
		spans := [15]int{6, 10, 13, 15, 16, 16, 16, 16, 15, 14, 13, 12, 11, 10, 8}
		center := 11
		for y in 0 ..< len(spans) {
			width := spans[y]
			x := center-width/2
			ArtRect(&art, x, y+1, width, 1, C_OUTLINE)
		}
		for y in 1 ..< len(spans)-1 {
			width := spans[y]-2
			x := center-width/2
			ArtRect(&art, x, y+1, width, 1, C_SKIN)
		}
		for y in 3 ..< 10 {
			width := spans[y]-6
			x := center-width/2
			ArtRect(&art, x, y+1, width, 1, C_SKIN_DARK)
		}
		ArtRect(&art, 3, 2, 16, 3, C_WOOD_DARK)
		ArtRect(&art, 3, 2, 16, 1, C_WOOD_LIGHT)
		ArtRect(&art, 4, 13, 14, 3, C_WOOD_DARKEST)
		ArtRect(&art, 4, 13, 14, 1, accent)
		ArtRect(&art, 7, 5, 8, 2, entrailDark)
		ArtRect(&art, 8, 5, 6, 1, entrail)
		ArtRect(&art, 6, 9, 10, 3, entrailDark)
		ArtRect(&art, 7, 10, 8, 2, entrail)
		ArtRect(&art, 9, 11, 5, 1, CShade(entrail, 1.4))
		ArtPixel(&art, 8, 12, C_BONE)
		ArtPixel(&art, 12, 12, C_BONE)
		ArtPixel(&art, 15, 12, C_BONE)
		return art
	case .Hand:
		art := ArtInit(10, 10)
		ArtEllipse(&art, 5, 5, 4, 4, C_OUTLINE)
		ArtEllipse(&art, 5, 5, 3, 3, C_SKIN)
		ArtPixel(&art, 4, 5, C_SKIN_DARK)
		ArtPixel(&art, 6, 5, C_SKIN_DARK)
		ArtRect(&art, 0, 3, 3, 3, entrailDark)
		ArtPixel(&art, 1, 4, C_BONE)
		ArtPixel(&art, 2, 5, entrail)
		return art
	case .Intestine:
		art := ArtInit(22, 12)
		for i in 0 ..< 8 {
			x := 2+i*2
			y := 6+int(math.sin(f32(i)*1.5)*3)
			ArtCircle(&art, x, y, 2, C_OUTLINE)
			ArtCircle(&art, x, y, 1, entrail)
		}
		ArtPixel(&art, 6, 3, entrailDark)
		ArtPixel(&art, 12, 5, entrailDark)
		ArtPixel(&art, 18, 7, CShade(entrail, 1.4))
		return art
	}
	unreachable()
}

DrawTurtleGorePart :: proc(part: GorePartKind, accent, entrail, entrailDark: rl.Color) -> Art {
	switch part {
	case .Head:
		art := ArtInit(12, 10)
		ArtEllipse(&art, 6, 4, 4, 3, C_OUTLINE)
		ArtEllipse(&art, 6, 4, 3, 2, C_LEAF_LIGHT)
		ArtRect(&art, 8, 4, 3, 2, C_OUTLINE)
		ArtRect(&art, 9, 4, 2, 1, C_GOLD_DARK)
		ArtPixel(&art, 5, 3, C_OUTLINE)
		ArtPixel(&art, 7, 3, C_OUTLINE)
		ArtPixel(&art, 5, 5, C_LEAF_DARK)
		ArtRect(&art, 3, 7, 6, 1, entrailDark)
		ArtRect(&art, 4, 8, 4, 1, entrail)
		ArtPixel(&art, 5, 9, C_BONE)
		return art
	case .Arm, .Leg:
		art := ArtInit(14, 8)
		ArtEllipse(&art, 5, 4, 5, 3, C_OUTLINE)
		ArtEllipse(&art, 5, 4, 4, 2, C_LEAF_LIGHT)
		ArtEllipse(&art, 10, 3, 3, 2, C_OUTLINE)
		ArtEllipse(&art, 10, 3, 2, 1, C_LEAF)
		ArtPixel(&art, 12, 2, C_LEAF_DARK)
		ArtPixel(&art, 12, 4, C_LEAF_DARK)
		ArtPixel(&art, 2, 4, C_LEAF_DARK)
		ArtEllipse(&art, 1, 4, 2, 1, entrailDark)
		ArtPixel(&art, 1, 4, C_BONE)
		ArtPixel(&art, 5, 5, entrailDark)
		return art
	case .Torso:
		art := ArtInit(16, 14)
		ArtEllipse(&art, 8, 7, 7, 6, C_OUTLINE)
		ArtEllipse(&art, 8, 7, 6, 5, C_LEAF_DARK)
		ArtEllipse(&art, 8, 7, 4, 3, C_LEAF)
		ArtLine(&art, 3, 7, 13, 7, C_LEAF_DARKEST)
		ArtLine(&art, 8, 3, 8, 12, C_LEAF_DARKEST)
		ArtPixel(&art, 5, 4, C_LEAF_LIGHT)
		ArtPixel(&art, 11, 10, C_LEAF)
		ArtRect(&art, 5, 6, 6, 2, accent)
		ArtRect(&art, 5, 6, 6, 1, CShade(accent, 1.3))
		ArtRect(&art, 5, 10, 6, 2, entrailDark)
		ArtRect(&art, 6, 10, 4, 1, entrail)
		ArtPixel(&art, 7, 11, C_BONE)
		ArtPixel(&art, 9, 11, C_BONE)
		return art
	case .Hand:
		art := ArtInit(7, 6)
		ArtEllipse(&art, 3, 3, 2, 2, C_OUTLINE)
		ArtEllipse(&art, 3, 3, 1, 1, C_LEAF_LIGHT)
		ArtPixel(&art, 5, 2, C_OUTLINE)
		ArtPixel(&art, 5, 4, C_OUTLINE)
		ArtRect(&art, 0, 2, 2, 2, entrailDark)
		ArtPixel(&art, 0, 2, C_BONE)
		return art
	case .Intestine:
		art := ArtInit(17, 10)
		for i in 0 ..< 6 {
			x := 2+i*2
			y := 5+int(math.sin(f32(i)*1.7)*2)
			ArtCircle(&art, x, y, 2, C_OUTLINE)
			ArtCircle(&art, x, y, 1, entrail)
		}
		ArtPixel(&art, 5, 3, entrailDark)
		ArtPixel(&art, 11, 6, entrailDark)
		ArtPixel(&art, 8, 7, CShade(entrail, 1.4))
		return art
	}
	unreachable()
}

DrawGorePart :: proc(kind: UnitKind, part: GorePartKind, accent: rl.Color) -> Art {
	tint := BloodTintForUnitType(UnitTypeFromKind(kind))
	entrail, entrailDark, entrailLight := GoreBloodColors(tint)
	switch kind {
	case .Catapult:
		return ArtInit(1, 1)
	case .Turtle:
		return DrawTurtleGorePart(part, accent, entrail, entrailDark)
	case .Giant:
		return DrawGiantGorePart(part, accent, entrail, entrailDark)
	case .Villager, .Builder, .CombatBuilder, .WaterCollector, .Farmer, .Knight, .Archer, .Mage, .Rogue, .Explorer:
		look := GoreLookForUnit(kind)
		switch part {
		case .Head:
			return DrawHumanoidGoreHead(look, accent, entrail, entrailDark)
		case .Arm:
			return DrawHumanoidGoreArm(look, accent, entrail, entrailDark)
		case .Leg:
			return DrawHumanoidGoreLeg(look, entrail, entrailDark)
		case .Torso:
			return DrawHumanoidGoreTorso(look, accent, entrail, entrailDark, entrailLight)
		case .Hand:
			return DrawHumanoidGoreHand(look, entrail, entrailDark)
		case .Intestine:
			return DrawHumanoidGoreIntestine(entrail, entrailDark, entrailLight)
		}
	}
	unreachable()
}
