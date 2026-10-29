package main

import rl "vendor:raylib"
import "base:intrinsics"
import "core:math"

// Particles are a fixed-capacity structure-of-arrays pool. They are simulated
// every rendered frame (not on the coarse town tick) so blood, gibs and smoke
// stay smooth even though the rest of the world runs at 4 Hz.
PARTICLE_CAPACITY :: 16384
PARTICLE_MIN_ZOOM :: 3
PARTICLE_MAX_FRAME_STEP :: 0.05

ParticleKind :: enum {
	Blood,
	Gib,
	Bone,
	Gore,
	Dust,
	Smoke,
	Ember,
	Spark,
	WoodChip,
	StoneChip,
	Leaf,
	Ash,
	Arrow,
	MagicMote,
	Boulder,
	Splash,
}

ALL_PARTICLE_KINDS := [16]ParticleKind {
	.Blood,
	.Gib,
	.Bone,
	.Gore,
	.Dust,
	.Smoke,
	.Ember,
	.Spark,
	.WoodChip,
	.StoneChip,
	.Leaf,
	.Ash,
	.Arrow,
	.MagicMote,
	.Boulder,
	.Splash,
}

Particle :: struct {
	x, y, z:       f32,
	vx, vy, vz:    f32,
	life, maxLife: f32,
	size:          f32,
	rotation:      f32,
	spin:          f32,
	drag:          f32,
	gravity:       f32,
	bounce:        f32,
	kind:          ParticleKind,
	variant:       u8,
	goreKind:      u8, // UnitKind that produced a .Gore chunk
	faction:       u8,
	settled:       bool,
	tint:          rl.Color,
}

// Deterministic hash stream. An atomic counter keeps it safe when unit updates
// spawn particles from several threads.
PRandom :: proc(w: ^World) -> f32 {
	x := u64(intrinsics.atomic_add(&w.particleRandom, 0x9E3779B97F4A7C15))
	x = x ~ (x >> 30)
	x = x*0xBF58476D1CE4E5B9
	x = x ~ (x >> 27)
	x = x*0x94D049BB133111EB
	x = x ~ (x >> 31)
	return f32(x & 0xFFFFFF)/f32(0x1000000)
}

PRandomRange :: proc(w: ^World, low, high: f32) -> f32 {
	return low+(high-low)*PRandom(w)
}

FishingFlotillaFx :: proc(w: ^World, kingdom, townSlot: int) {
	if !KingdomHasTech(w, kingdom, .FishingFlotillas) do return
	if !TownIsCoastal(w, kingdom, townSlot) do return
	if PRandom(w) > 0.025 do return
	town := &w.kingdoms[kingdom].towns[townSlot]
	for _ in 0..<8 {
		x := WorldWrapCoordinate(town.x+int((PRandom(w)-0.5)*28), int(w.maxX))
		y := WorldWrapCoordinate(town.y+int((PRandom(w)-0.5)*28), int(w.maxY))
		tile := WorldTileAt(w, x, y).type
		if !TileIsDeepWater(tile) do continue
		ParticleSpawn(w, Particle{
			x = f32(x)+PRandom(w),
			y = f32(y)+PRandom(w),
			z = 0.05,
			vx = (PRandom(w)-0.5)*0.5,
			vy = (PRandom(w)-0.5)*0.5,
			vz = PRandomRange(w, 0.8, 1.8),
			life = PRandomRange(w, 0.4, 0.8),
			size = PRandomRange(w, 0.12, 0.28),
			drag = 1,
			gravity = 4,
			kind = .Splash,
			tint = rl.Color{206, 232, 242, 255},
		})
		return
	}
}

UnitWaterWake :: proc(w: ^World, unitSlot: int) {
	if unitSlot < 0 || unitSlot >= UNIT_CAPACITY || !w.unitUsed[unitSlot] do return
	if UnitKindOf(w.units.type[unitSlot]) == .Turtle do return
	if !UnitOnWaterTile(w, unitSlot) do return
	if !UnitCanCrossWater(w, w.units.type[unitSlot], w.units.kingdome[unitSlot]) do return
	if PRandom(w) > 0.18 do return
	ParticleSpawn(w, Particle{
		x = w.units.previousX[unitSlot]+(PRandom(w)-0.5)*0.35,
		y = w.units.previousY[unitSlot]+(PRandom(w)-0.5)*0.35,
		z = 0.05,
		vx = (PRandom(w)-0.5)*0.9,
		vy = (PRandom(w)-0.5)*0.9,
		vz = PRandomRange(w, 0.4, 1.1),
		life = PRandomRange(w, 0.25, 0.5),
		size = PRandomRange(w, 0.12, 0.24),
		drag = 1.5,
		gravity = 4,
		kind = .Splash,
		tint = rl.Color{196, 226, 240, 255},
	})
}

ParticleSpawn :: proc(w: ^World, p: Particle) -> int {
	RecursiveLockGuard(&w.effectsMutex)
	slot := -1
	for step in 0 ..< PARTICLE_CAPACITY {
		candidate := (w.particleCursor+step)%PARTICLE_CAPACITY
		if !w.particleUsed[candidate] {
			slot = candidate
			break
		}
	}
	if slot < 0 {
		// Pool exhausted: recycle the slot we are about to advance past.
		slot = w.particleCursor
	} else {
		w.particleCount += 1
	}

	life := p.life
	if life <= 0 do life = 0.75
	maxLife := p.maxLife
	if maxLife <= 0 do maxLife = life
	alpha := p.tint.a
	if alpha == 0 do alpha = 255

	w.particles.x[slot] = p.x
	w.particles.y[slot] = p.y
	w.particles.z[slot] = p.z
	w.particles.vx[slot] = p.vx
	w.particles.vy[slot] = p.vy
	w.particles.vz[slot] = p.vz
	w.particles.life[slot] = life
	w.particles.maxLife[slot] = maxLife
	w.particles.size[slot] = p.size
	w.particles.rotation[slot] = p.rotation
	w.particles.spin[slot] = p.spin
	w.particles.drag[slot] = p.drag
	w.particles.gravity[slot] = p.gravity
	w.particles.bounce[slot] = p.bounce
	w.particles.kind[slot] = p.kind
	w.particles.variant[slot] = p.variant
	w.particles.goreKind[slot] = p.goreKind
	w.particles.faction[slot] = p.faction
	w.particles.settled[slot] = p.settled
	w.particles.tint[slot] = rl.Color{p.tint.r, p.tint.g, p.tint.b, alpha}

	w.particleUsed[slot] = true
	w.particleCursor = (slot+1)%PARTICLE_CAPACITY
	return slot
}

ParticleRemove :: proc(w: ^World, slot: int) {
	if slot < 0 || slot >= PARTICLE_CAPACITY || !w.particleUsed[slot] do return
	w.particleUsed[slot] = false
	w.particleCount -= 1
}

ParticleBloodTint :: proc(w: ^World, slot: int) -> u8 {
	if w.particles.kind[slot] == .Gore {
		unitKind := int(w.particles.goreKind[slot])
		if unitKind < 0 || unitKind >= len(ALL_UNIT_KINDS) do return BLOOD_TINT_RED
		tint := BloodTintForUnitType(UnitTypeFromKind(UnitKind(unitKind)))
		if tint == BLOOD_TINT_NONE do return BLOOD_TINT_RED
		return tint
	}
	return BloodTintFromParticle(w.particles.tint[slot])
}

WorldParticleUpdate :: proc(w: ^World, deltaTime: f32) {
	if w.particleCount <= 0 do return
	dt := clamp(deltaTime, 0, PARTICLE_MAX_FRAME_STEP)
	if dt <= 0 do return

	worldWidth := f32(w.maxX)
	worldHeight := f32(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 do return

	for i in 0 ..< PARTICLE_CAPACITY {
		if !w.particleUsed[i] do continue

		life := w.particles.life[i]-dt
		if life <= 0 {
			// Blood that vanishes mid-air still stains the ground below it.
			if w.particles.kind[i] == .Blood && w.particles.z[i] > 0.02 {
				BloodDropLand(w, w.particles.x[i], w.particles.y[i], w.particles.variant[i], false)
			}
			ParticleRemove(w, i)
			continue
		}
		w.particles.life[i] = life
		if w.particles.settled[i] do continue

		kind := w.particles.kind[i]
		x := w.particles.x[i]+w.particles.vx[i]*dt
		y := w.particles.y[i]+w.particles.vy[i]*dt
		z := w.particles.z[i]+w.particles.vz[i]*dt

		if kind == .Smoke {
			// Smoke drifts lazily instead of falling straight down.
			drift := math.sin(w.simulationTime*1.6+f32(i)*0.37)*0.55
			x += drift*dt
			y += math.cos(w.simulationTime*1.1+f32(i)*0.71)*0.35*dt
		} else if kind == .Leaf {
			x += math.sin(w.simulationTime*4.2+f32(i)*0.9)*0.9*dt
		}

		drag := w.particles.drag[i]
		if drag > 0 {
			dragFactor := 1/(1+drag*dt)
			w.particles.vx[i] *= dragFactor
			w.particles.vy[i] *= dragFactor
		}
		w.particles.vz[i] -= w.particles.gravity[i]*dt
		w.particles.rotation[i] += w.particles.spin[i]*dt

		if z <= 0 {
			switch kind {
			case .Blood:
				BloodDropLand(w, x, y, w.particles.variant[i], true)
				ParticleRemove(w, i)
				continue
			case .Ember, .Spark, .MagicMote, .Splash:
				ParticleRemove(w, i)
				continue
			case .Smoke:
				z = 0
			case .Dust, .Ash, .Leaf, .Arrow:
				z = 0
				w.particles.vx[i] = 0
				w.particles.vy[i] = 0
				w.particles.vz[i] = 0
				w.particles.spin[i] = 0
				w.particles.settled[i] = true
			case .Gib, .Bone, .Gore, .WoodChip, .StoneChip, .Boulder:
				bounceVz := -w.particles.vz[i]*w.particles.bounce[i]
				if bounceVz > 1.2 {
					z = 0
					w.particles.vz[i] = bounceVz
					w.particles.vx[i] *= 0.55
					w.particles.vy[i] *= 0.55
					w.particles.spin[i] *= -0.55
					if kind == .Gib || kind == .Gore {
						BloodDropLand(w, x, y, ParticleBloodTint(w, i), false)
					}
				} else {
					z = 0
					w.particles.vx[i] = 0
					w.particles.vy[i] = 0
					w.particles.vz[i] = 0
					w.particles.spin[i] = 0
					w.particles.settled[i] = true
					if kind == .Gib || kind == .Gore {
						BloodAddAt(w, x, y, 3, 0.3, ParticleBloodTint(w, i))
					}
				}
			}
		}

		w.particles.x[i] = WorldWrapPosition(x, worldWidth)
		w.particles.y[i] = WorldWrapPosition(y, worldHeight)
		w.particles.z[i] = max(z, 0)
	}
}

ParticleTexture :: proc(set: ^SpriteSet, w: ^World, slot: int) -> rl.Texture2D {
	kind := w.particles.kind[slot]
	if kind == .Gore {
		part := GorePartKind(int(w.particles.variant[slot])%GORE_PART_COUNT)
		unitKind := int(w.particles.goreKind[slot])
		if unitKind < 0 || unitKind >= len(ALL_UNIT_KINDS) do unitKind = int(UnitKind.Villager)
		faction := int(w.particles.faction[slot])
		if faction < 0 || faction >= SPRITE_FACTION_COUNT do faction = SPRITE_FACTION_COUNT-1
		return set.gore[faction][UnitKind(unitKind)][part]
	}
	return set.particle[kind]
}

ParticleDraw :: proc(
	w: ^World,
	renderer: ^WorldRenderer,
	offsetX, offsetY: f32,
	minX, maxX, minY, maxY: f32,
	settledPass: bool,
) {
	if w.particleCount <= 0 do return
	if renderer.sprites.particle[.Blood].id == 0 do return

	for i in 0 ..< PARTICLE_CAPACITY {
		if !w.particleUsed[i] do continue
		if w.particles.settled[i] != settledPass do continue

		px := offsetX+w.particles.x[i]
		py := offsetY+w.particles.y[i]-w.particles.z[i]
		size := w.particles.size[i]

		kind := w.particles.kind[i]
		if kind == .Smoke || kind == .Dust {
			age := 1-clamp(w.particles.life[i]/w.particles.maxLife[i], 0, 1)
			size *= 1+age*1.7
		}
		half := size*0.5
		if w.particles.x[i]+half < minX || w.particles.x[i]-half > maxX ||
			w.particles.y[i]+half < minY || w.particles.y[i]-half > maxY {
			continue
		}

		texture := ParticleTexture(&renderer.sprites, w, i)
		if texture.id == 0 do continue

		// Keep authored proportions: limbs must stay long and thin instead of
		// being squashed into a square.
		longSide := f32(max(texture.width, texture.height))
		drawWidth := size*f32(texture.width)/longSide
		drawHeight := size*f32(texture.height)/longSide

		fade: f32 = 1
		#partial switch kind {
		case .Smoke, .Dust:
			fade = clamp(w.particles.life[i]/w.particles.maxLife[i], 0, 1)
		case .Ember, .Spark, .MagicMote, .Splash, .Arrow, .Boulder:
			fade = clamp(w.particles.life[i]/0.3, 0, 1)
		case:
			fade = clamp(w.particles.life[i]/1.5, 0, 1)
		}

		tint := w.particles.tint[i]
		tint.a = u8(f32(tint.a)*fade)
		if tint.a == 0 do continue

		source := rl.Rectangle{0, 0, f32(texture.width), f32(texture.height)}
		rl.DrawTexturePro(
			texture,
			source,
			rl.Rectangle{px-drawWidth*0.5, py-drawHeight*0.5, drawWidth, drawHeight},
			rl.Vector2{drawWidth*0.5, drawHeight*0.5},
			w.particles.rotation[i]*57.29577951308232,
			tint,
		)
	}
}

// --- procedural particle sprites -------------------------------------------

CreateSoftCloudTexture :: proc(size: int, color: rl.Color, seed: u64, puffs: int) -> rl.Texture2D {
	art := ArtInit(size, size)
	center := f32(size)*0.5
	for puff in 0 ..< puffs {
		puffAngle := WorldNoiseHash(puff, int(seed), 0xC10D)*6.2831853
		puffDistance := WorldNoiseHash(puff, int(seed)+7, 0xC10E)*f32(size)*0.18
		puffX := center+math.cos(puffAngle)*puffDistance
		puffY := center+math.sin(puffAngle)*puffDistance
		puffRadius := f32(size)*(0.24+WorldNoiseHash(puff, int(seed)+13, 0xC10F)*0.16)

		for y in 0 ..< size {
			for x in 0 ..< size {
				dx := (f32(x)+0.5-puffX)/puffRadius
				dy := (f32(y)+0.5-puffY)/puffRadius
				distance := math.sqrt(dx*dx+dy*dy)
				if distance >= 1 do continue
				wobble := 0.82+0.28*WorldNoiseHash(x/2, y/2, seed)
				strength := clamp(1-distance/wobble, 0, 1)
				strength = strength*strength
				alpha := u8(clamp(f32(color.a)*strength, 0, 255))
				if alpha == 0 do continue
				ArtPixel(&art, x, y, rl.Color{color.r, color.g, color.b, alpha})
			}
		}
	}
	return ArtTakeTexture(art)
}

// Converts generated art and frees the CPU image. SpriteSetInit mostly does
// this inline, but the procedural effect art is built in batches.
ArtTakeTexture :: proc(art: Art) -> rl.Texture2D {
	texture := ArtToTexture(art)
	rl.UnloadImage(art.image)
	return texture
}

CreateParticleKindTexture :: proc(kind: ParticleKind) -> rl.Texture2D {
	switch kind {
	case .Blood:
		// Greyscale so the same droplet can be tinted with any blood colour.
		art := ArtInit(5, 5)
		ArtEllipse(&art, 2, 2, 2, 2, rl.Color{210, 210, 218, 255})
		ArtEllipse(&art, 2, 2, 1, 1, rl.Color{246, 246, 250, 255})
		ArtPixel(&art, 1, 1, rl.Color{255, 255, 255, 255})
		return ArtTakeTexture(art)
	case .Gib:
		// Greyscale so the chunk can be tinted with the victim's blood colour.
		art := ArtInit(7, 6)
		ArtEllipse(&art, 3, 3, 3, 2, C_OUTLINE)
		ArtEllipse(&art, 3, 3, 2, 2, C_SPLAT_MID)
		ArtEllipse(&art, 2, 2, 1, 1, C_SPLAT_LIGHT)
		ArtPixel(&art, 5, 2, C_SPLAT_DARK)
		return ArtTakeTexture(art)
	case .Bone:
		art := ArtInit(6, 5)
		ArtLine(&art, 1, 3, 4, 1, C_OUTLINE)
		ArtLine(&art, 1, 2, 4, 0, C_BONE)
		ArtCircle(&art, 1, 3, 1, C_OUTLINE)
		ArtCircle(&art, 4, 1, 1, C_OUTLINE)
		ArtPixel(&art, 1, 3, C_BONE)
		ArtPixel(&art, 4, 1, C_BONE)
		return ArtTakeTexture(art)
	case .Gore:
		return {}
	case .Dust:
		return CreateSoftCloudTexture(16, rl.Color{148, 138, 120, 210}, 0xD057, 3)
	case .Smoke:
		return CreateSoftCloudTexture(20, rl.Color{64, 62, 68, 210}, 0x5A0C, 4)
	case .Ember:
		art := ArtInit(4, 4)
		ArtEllipse(&art, 1, 1, 2, 2, rl.Color{232, 92, 36, 255})
		ArtEllipse(&art, 1, 1, 1, 1, rl.Color{255, 206, 118, 255})
		ArtPixel(&art, 0, 0, rl.Color{255, 246, 196, 255})
		return ArtTakeTexture(art)
	case .Spark:
		art := ArtInit(4, 4)
		ArtPixel(&art, 1, 1, rl.Color{255, 246, 198, 255})
		ArtPixel(&art, 2, 1, rl.Color{255, 214, 120, 255})
		ArtPixel(&art, 1, 2, rl.Color{255, 214, 120, 255})
		ArtPixel(&art, 2, 2, rl.Color{255, 168, 78, 255})
		return ArtTakeTexture(art)
	case .WoodChip:
		art := ArtInit(6, 4)
		ArtRect(&art, 1, 1, 4, 2, C_OUTLINE)
		ArtRect(&art, 2, 1, 3, 1, C_WOOD)
		ArtPixel(&art, 1, 2, C_WOOD_LIGHT)
		return ArtTakeTexture(art)
	case .StoneChip:
		art := ArtInit(6, 6)
		ArtTriangle(&art, 1, 3, 3, 0, 5, 3, C_OUTLINE)
		ArtTriangle(&art, 2, 3, 3, 1, 4, 3, C_STONE)
		ArtPixel(&art, 3, 2, C_STONE_LIGHT)
		return ArtTakeTexture(art)
	case .Leaf:
		art := ArtInit(5, 5)
		ArtEllipse(&art, 2, 2, 2, 1, C_LEAF_DARK)
		ArtPixel(&art, 1, 2, C_LEAF)
		ArtPixel(&art, 2, 1, C_LEAF_LIGHT)
		ArtPixel(&art, 3, 3, C_LEAF_DARKEST)
		return ArtTakeTexture(art)
	case .Ash:
		art := ArtInit(4, 4)
		ArtRect(&art, 1, 1, 2, 2, rl.Color{54, 52, 52, 255})
		ArtPixel(&art, 1, 1, rl.Color{94, 90, 88, 255})
		ArtPixel(&art, 2, 2, rl.Color{32, 30, 30, 255})
		return ArtTakeTexture(art)
	case .Arrow:
		art := ArtInit(8, 4)
		ArtRect(&art, 1, 1, 5, 2, C_OUTLINE)
		ArtRect(&art, 1, 1, 5, 1, C_WOOD_LIGHT)
		ArtRect(&art, 6, 1, 2, 1, C_IRON)
		ArtPixel(&art, 7, 1, C_IRON_LIGHT)
		ArtPixel(&art, 0, 0, C_WHITE)
		ArtPixel(&art, 0, 3, C_WHITE)
		ArtPixel(&art, 1, 0, C_WOOD_LIGHT)
		ArtPixel(&art, 1, 3, C_WOOD_LIGHT)
		return ArtTakeTexture(art)
	case .MagicMote:
		art := ArtInit(6, 6)
		ArtEllipse(&art, 3, 3, 3, 3, C_ARCANE_DARK)
		ArtEllipse(&art, 3, 3, 2, 2, C_ARCANE)
		ArtEllipse(&art, 2, 2, 1, 1, C_ARCANE_GLOW)
		ArtPixel(&art, 1, 1, C_WHITE)
		return ArtTakeTexture(art)
	case .Boulder:
		art := ArtInit(7, 7)
		ArtEllipse(&art, 3, 3, 3, 3, C_OUTLINE)
		ArtEllipse(&art, 3, 3, 2, 2, C_STONE_DARK)
		ArtEllipse(&art, 2, 2, 1, 1, C_STONE)
		ArtPixel(&art, 4, 4, C_STONE_LIGHT)
		ArtPixel(&art, 1, 4, C_STONE_DARKEST)
		return ArtTakeTexture(art)
	case .Splash:
		art := ArtInit(5, 5)
		ArtEllipse(&art, 2, 3, 2, 1, C_WATER_LIGHT)
		ArtPixel(&art, 1, 1, C_WATER_LIGHT)
		ArtPixel(&art, 3, 1, C_WATER_LIGHT)
		ArtPixel(&art, 2, 0, C_WATER)
		return ArtTakeTexture(art)
	}
	return {}
}
