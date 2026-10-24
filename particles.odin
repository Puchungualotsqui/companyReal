package main

import rl "vendor:raylib"
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
}

ALL_PARTICLE_KINDS := [12]ParticleKind {
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
	faction:       u8,
	settled:       bool,
	tint:          rl.Color,
}

// Deterministic xorshift so all the little gore variations replay identically.
PRandom :: proc(w: ^World) -> f32 {
	x := w.particleRandom
	if x == 0 do x = 0x9E3779B97F4A7C15
	x = x ~ (x << 13)
	x = x ~ (x >> 7)
	x = x ~ (x << 17)
	w.particleRandom = x
	return f32(x & 0xFFFFFF)/f32(0x1000000)
}

PRandomRange :: proc(w: ^World, low, high: f32) -> f32 {
	return low+(high-low)*PRandom(w)
}

ParticleSpawn :: proc(w: ^World, p: Particle) -> int {
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
	max_life := p.maxLife
	if max_life <= 0 do max_life = life
	alpha := p.tint.a
	if alpha == 0 do alpha = 255

	w.particles.x[slot] = p.x
	w.particles.y[slot] = p.y
	w.particles.z[slot] = p.z
	w.particles.vx[slot] = p.vx
	w.particles.vy[slot] = p.vy
	w.particles.vz[slot] = p.vz
	w.particles.life[slot] = life
	w.particles.maxLife[slot] = max_life
	w.particles.size[slot] = p.size
	w.particles.rotation[slot] = p.rotation
	w.particles.spin[slot] = p.spin
	w.particles.drag[slot] = p.drag
	w.particles.gravity[slot] = p.gravity
	w.particles.bounce[slot] = p.bounce
	w.particles.kind[slot] = p.kind
	w.particles.variant[slot] = p.variant
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

WorldParticleUpdate :: proc(w: ^World, delta_time: f32) {
	if w.particleCount <= 0 do return
	dt := clamp(delta_time, 0, PARTICLE_MAX_FRAME_STEP)
	if dt <= 0 do return

	world_width := f32(w.maxX)
	world_height := f32(w.maxY)
	if world_width <= 0 || world_height <= 0 do return

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
			drag_factor := 1/(1+drag*dt)
			w.particles.vx[i] *= drag_factor
			w.particles.vy[i] *= drag_factor
		}
		w.particles.vz[i] -= w.particles.gravity[i]*dt
		w.particles.rotation[i] += w.particles.spin[i]*dt

		if z <= 0 {
			switch kind {
			case .Blood:
				BloodDropLand(w, x, y, w.particles.variant[i], true)
				ParticleRemove(w, i)
				continue
			case .Ember, .Spark:
				ParticleRemove(w, i)
				continue
			case .Smoke:
				z = 0
			case .Dust, .Ash, .Leaf:
				z = 0
				w.particles.vx[i] = 0
				w.particles.vy[i] = 0
				w.particles.vz[i] = 0
				w.particles.spin[i] = 0
				w.particles.settled[i] = true
			case .Gib, .Bone, .Gore, .WoodChip, .StoneChip:
				bounce_vz := -w.particles.vz[i]*w.particles.bounce[i]
				if bounce_vz > 1.2 {
					z = 0
					w.particles.vz[i] = bounce_vz
					w.particles.vx[i] *= 0.55
					w.particles.vy[i] *= 0.55
					w.particles.spin[i] *= -0.55
					if kind == .Gib || kind == .Gore {
						BloodDropLand(w, x, y, BloodTintFromParticle(w.particles.tint[i]), false)
					}
				} else {
					z = 0
					w.particles.vx[i] = 0
					w.particles.vy[i] = 0
					w.particles.vz[i] = 0
					w.particles.spin[i] = 0
					w.particles.settled[i] = true
					if kind == .Gib || kind == .Gore {
						BloodAddAt(w, x, y, 3, 0.3, BloodTintFromParticle(w.particles.tint[i]))
					}
				}
			}
		}

		w.particles.x[i] = WorldWrapPosition(x, world_width)
		w.particles.y[i] = WorldWrapPosition(y, world_height)
		w.particles.z[i] = max(z, 0)
	}
}

ParticleTexture :: proc(set: ^SpriteSet, w: ^World, slot: int) -> rl.Texture2D {
	kind := w.particles.kind[slot]
	if kind == .Gore {
		part := GorePartKind(int(w.particles.variant[slot])%GORE_PART_COUNT)
		faction := int(w.particles.faction[slot])
		if faction < 0 || faction >= SPRITE_FACTION_COUNT do faction = SPRITE_FACTION_COUNT-1
		return set.gore[faction][part]
	}
	return set.particle[kind]
}

ParticleDraw :: proc(
	w: ^World,
	renderer: ^WorldRenderer,
	offset_x, offset_y: f32,
	min_x, max_x, min_y, max_y: f32,
	settled_pass: bool,
) {
	if w.particleCount <= 0 do return
	if renderer.sprites.particle[.Blood].id == 0 do return

	for i in 0 ..< PARTICLE_CAPACITY {
		if !w.particleUsed[i] do continue
		if w.particles.settled[i] != settled_pass do continue

		px := offset_x+w.particles.x[i]
		py := offset_y+w.particles.y[i]-w.particles.z[i]
		size := w.particles.size[i]

		kind := w.particles.kind[i]
		if kind == .Smoke || kind == .Dust {
			age := 1-clamp(w.particles.life[i]/w.particles.maxLife[i], 0, 1)
			size *= 1+age*1.7
		}
		half := size*0.5
		if w.particles.x[i]+half < min_x || w.particles.x[i]-half > max_x ||
			w.particles.y[i]+half < min_y || w.particles.y[i]-half > max_y {
			continue
		}

		texture := ParticleTexture(&renderer.sprites, w, i)
		if texture.id == 0 do continue

		// Keep authored proportions: limbs must stay long and thin instead of
		// being squashed into a square.
		long_side := f32(max(texture.width, texture.height))
		draw_width := size*f32(texture.width)/long_side
		draw_height := size*f32(texture.height)/long_side

		fade: f32 = 1
		#partial switch kind {
		case .Smoke, .Dust:
			fade = clamp(w.particles.life[i]/w.particles.maxLife[i], 0, 1)
		case .Ember, .Spark:
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
			rl.Rectangle{px-draw_width*0.5, py-draw_height*0.5, draw_width, draw_height},
			rl.Vector2{draw_width*0.5, draw_height*0.5},
			w.particles.rotation[i]*57.29577951308232,
			tint,
		)
	}
}

// --- procedural particle sprites -------------------------------------------

create_soft_cloud_texture :: proc(size: int, color: rl.Color, seed: u64, puffs: int) -> rl.Texture2D {
	art := art_init(size, size)
	center := f32(size)*0.5
	for puff in 0 ..< puffs {
		puff_angle := WorldNoiseHash(puff, int(seed), 0xC10D)*6.2831853
		puff_distance := WorldNoiseHash(puff, int(seed)+7, 0xC10E)*f32(size)*0.18
		puff_x := center+math.cos(puff_angle)*puff_distance
		puff_y := center+math.sin(puff_angle)*puff_distance
		puff_radius := f32(size)*(0.24+WorldNoiseHash(puff, int(seed)+13, 0xC10F)*0.16)

		for y in 0 ..< size {
			for x in 0 ..< size {
				dx := (f32(x)+0.5-puff_x)/puff_radius
				dy := (f32(y)+0.5-puff_y)/puff_radius
				distance := math.sqrt(dx*dx+dy*dy)
				if distance >= 1 do continue
				wobble := 0.82+0.28*WorldNoiseHash(x/2, y/2, seed)
				strength := clamp(1-distance/wobble, 0, 1)
				strength = strength*strength
				alpha := u8(clamp(f32(color.a)*strength, 0, 255))
				if alpha == 0 do continue
				art_pixel(&art, x, y, rl.Color{color.r, color.g, color.b, alpha})
			}
		}
	}
	return art_take_texture(art)
}

// Converts generated art and frees the CPU image. SpriteSetInit mostly does
// this inline, but the procedural effect art is built in batches.
art_take_texture :: proc(art: Art) -> rl.Texture2D {
	texture := art_to_texture(art)
	rl.UnloadImage(art.image)
	return texture
}

create_particle_kind_texture :: proc(kind: ParticleKind) -> rl.Texture2D {
	switch kind {
	case .Blood:
		// Greyscale so the same droplet can be tinted with any blood colour.
		art := art_init(5, 5)
		art_ellipse(&art, 2, 2, 2, 2, rl.Color{210, 210, 218, 255})
		art_ellipse(&art, 2, 2, 1, 1, rl.Color{246, 246, 250, 255})
		art_pixel(&art, 1, 1, rl.Color{255, 255, 255, 255})
		return art_take_texture(art)
	case .Gib:
		art := art_init(7, 6)
		art_ellipse(&art, 3, 3, 3, 2, C_OUTLINE)
		art_ellipse(&art, 3, 3, 2, 2, rl.Color{168, 52, 52, 255})
		art_ellipse(&art, 2, 2, 1, 1, rl.Color{214, 96, 88, 255})
		art_pixel(&art, 5, 2, C_BONE)
		return art_take_texture(art)
	case .Bone:
		art := art_init(6, 5)
		art_line(&art, 1, 3, 4, 1, C_OUTLINE)
		art_line(&art, 1, 2, 4, 0, C_BONE)
		art_circle(&art, 1, 3, 1, C_OUTLINE)
		art_circle(&art, 4, 1, 1, C_OUTLINE)
		art_pixel(&art, 1, 3, C_BONE)
		art_pixel(&art, 4, 1, C_BONE)
		return art_take_texture(art)
	case .Gore:
		return {}
	case .Dust:
		return create_soft_cloud_texture(16, rl.Color{148, 138, 120, 210}, 0xD057, 3)
	case .Smoke:
		return create_soft_cloud_texture(20, rl.Color{64, 62, 68, 210}, 0x5A0C, 4)
	case .Ember:
		art := art_init(4, 4)
		art_ellipse(&art, 1, 1, 2, 2, rl.Color{232, 92, 36, 255})
		art_ellipse(&art, 1, 1, 1, 1, rl.Color{255, 206, 118, 255})
		art_pixel(&art, 0, 0, rl.Color{255, 246, 196, 255})
		return art_take_texture(art)
	case .Spark:
		art := art_init(4, 4)
		art_pixel(&art, 1, 1, rl.Color{255, 246, 198, 255})
		art_pixel(&art, 2, 1, rl.Color{255, 214, 120, 255})
		art_pixel(&art, 1, 2, rl.Color{255, 214, 120, 255})
		art_pixel(&art, 2, 2, rl.Color{255, 168, 78, 255})
		return art_take_texture(art)
	case .WoodChip:
		art := art_init(6, 4)
		art_rect(&art, 1, 1, 4, 2, C_OUTLINE)
		art_rect(&art, 2, 1, 3, 1, C_WOOD)
		art_pixel(&art, 1, 2, C_WOOD_LIGHT)
		return art_take_texture(art)
	case .StoneChip:
		art := art_init(6, 6)
		art_triangle(&art, 1, 3, 3, 0, 5, 3, C_OUTLINE)
		art_triangle(&art, 2, 3, 3, 1, 4, 3, C_STONE)
		art_pixel(&art, 3, 2, C_STONE_LIGHT)
		return art_take_texture(art)
	case .Leaf:
		art := art_init(5, 5)
		art_ellipse(&art, 2, 2, 2, 1, C_LEAF_DARK)
		art_pixel(&art, 1, 2, C_LEAF)
		art_pixel(&art, 2, 1, C_LEAF_LIGHT)
		art_pixel(&art, 3, 3, C_LEAF_DARKEST)
		return art_take_texture(art)
	case .Ash:
		art := art_init(4, 4)
		art_rect(&art, 1, 1, 2, 2, rl.Color{54, 52, 52, 255})
		art_pixel(&art, 1, 1, rl.Color{94, 90, 88, 255})
		art_pixel(&art, 2, 2, rl.Color{32, 30, 30, 255})
		return art_take_texture(art)
	}
	return {}
}
