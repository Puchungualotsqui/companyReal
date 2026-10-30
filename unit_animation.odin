package main

import rl "vendor:raylib"
import "core:math"

// Procedural unit animation: the sprites are single-frame pixel art, so life is
// added with walk cycles, idle breathing, action lunges and matching particles.

// Field order: idleBob, idleSpeed, walkBob, walkSway, stride,
// actionDuration, actionForce, workInterval.
UnitAnimationProfile :: struct {
	idleBob, idleSpeed: f32,
	walkBob, walkSway: f32,
	stride:            f32,
	actionDuration:    f32,
	actionForce:       f32,
	workInterval:      f32,
}

UnitAnimationPose :: struct {
	bob, swayX, swayY: f32,
	stretchX, stretchY: f32,
	moving:            bool,
	damageStage:       int,
}

UnitAnimationProfileFor :: proc(kind: UnitKind) -> UnitAnimationProfile {
	switch kind {
	case .Villager:
		return {0.014, 2.2, 0.055, 0.038, 4.0, 0.30, 0.10, 0.00}
	case .Builder:
		return {0.014, 2.2, 0.050, 0.035, 4.0, 0.35, 0.08, 0.55}
	case .CombatBuilder:
		return {0.014, 2.0, 0.055, 0.038, 4.0, 0.35, 0.12, 0.55}
	case .WaterCollector:
		return {0.014, 2.4, 0.050, 0.035, 4.0, 0.40, 0.08, 0.90}
	case .Farmer:
		return {0.014, 2.1, 0.050, 0.035, 4.0, 0.40, 0.08, 0.80}
	case .Knight:
		return {0.014, 2.3, 0.060, 0.042, 3.6, 0.32, 0.18, 0.00}
	case .Archer:
		return {0.012, 2.5, 0.055, 0.040, 3.8, 0.36, 0.10, 0.00}
	case .Mage:
		return {0.016, 1.9, 0.045, 0.032, 4.2, 0.42, 0.08, 0.00}
	case .Giant:
		return {0.028, 1.2, 0.085, 0.022, 2.4, 0.48, 0.20, 0.00}
	case .Turtle:
		return {0.020, 1.6, 0.055, 0.030, 2.8, 0.42, 0.14, 0.00}
	case .Catapult:
		return {0.010, 1.4, 0.035, 0.018, 2.6, 0.45, 0.10, 0.00}
	case .Rogue:
		return {0.012, 2.6, 0.060, 0.045, 3.6, 0.24, 0.22, 0.00}
	case .Explorer:
		return {0.014, 2.2, 0.060, 0.040, 3.8, 0.30, 0.10, 0.00}
	}
	unreachable()
}

UnitAnimationPoseFor :: proc(w: ^World, unitSlot: int, kind: UnitKind, now: f32) -> UnitAnimationPose {
	unit := &w.units[unitSlot]
	profile := UnitAnimationProfileFor(kind)
	pose := UnitAnimationPose{stretchX = 1, stretchY = 1}
	pose.damageStage = UnitDamageStage(w, unitSlot)

	idle := math.sin(now*profile.idleSpeed+f32(unitSlot)*1.7)
	pose.bob = idle*profile.idleBob
	pose.stretchY = 1+idle*0.012
	if pose.damageStage > 0 {
		pose.bob -= f32(pose.damageStage)*0.012
		pose.stretchY *= 1-f32(pose.damageStage)*0.02
	}

	if UnitAnimationMoving(w, unitSlot) {
		pose.moving = true
		step := math.sin(unit.walkPhase)
		lift := abs(step)
		pose.bob += lift*profile.walkBob
		pose.swayX += step*profile.walkSway
		pose.stretchX *= 1-step*0.035
		pose.stretchY *= 1+lift*0.04
	}

	if state, warrior := unit.state.(StateWarrior); warrior && state.activity == .Attacking {
		bounce := math.sin(now*7+f32(unitSlot)*0.9)
		pose.bob += abs(bounce)*0.022
		pose.swayX += bounce*0.012
	}

	elapsed := now-unit.actionStarted
	if elapsed >= 0 && elapsed < profile.actionDuration {
		progress := elapsed/profile.actionDuration
		swing := (1-progress)*(1-progress)
		dirX := unit.actionDirX
		dirY := unit.actionDirY
		switch kind {
		case .Archer, .Mage, .Catapult:
			pose.swayX -= dirX*swing*profile.actionForce
			pose.swayY -= dirY*swing*profile.actionForce
			pose.stretchX *= 1+swing*0.04
			pose.stretchY *= 1-swing*0.03
		case .Giant:
			pose.swayX += dirX*swing*profile.actionForce
			pose.swayY += dirY*swing*profile.actionForce
			pose.bob -= swing*0.03
			pose.stretchX *= 1+swing*0.06
			pose.stretchY *= 1-swing*0.08
		case .Turtle:
			pose.swayX += dirX*swing*profile.actionForce
			pose.swayY += dirY*swing*profile.actionForce
			pose.stretchX *= 1+swing*0.08
			pose.stretchY *= 1-swing*0.06
		case .Knight, .Rogue, .CombatBuilder:
			pose.swayX += dirX*swing*profile.actionForce
			pose.swayY += dirY*swing*profile.actionForce
			pose.stretchX *= 1+swing*0.05
			pose.stretchY *= 1-swing*0.03
		case .Villager, .Builder, .WaterCollector, .Farmer, .Explorer:
			pose.swayX += dirX*swing*0.04
			pose.swayY += dirY*swing*0.04
			pose.bob -= swing*0.012
			pose.stretchY *= 1-swing*0.04
		}
	}
	return pose
}

UnitAnimationMoving :: proc(w: ^World, unitSlot: int) -> bool {
	deltaX := WorldShortestWrappedDelta(UnitX(w, unitSlot)-UnitPrevX(w, unitSlot), f32(w.maxX))
	deltaY := WorldShortestWrappedDelta(UnitY(w, unitSlot)-UnitPrevY(w, unitSlot), f32(w.maxY))
	return deltaX*deltaX+deltaY*deltaY > 0.0004
}

// Advances stride phase and schedules work/ambient effects on the render clock.
// Only buckets under the view are visited: animation is purely visual, and a
// skipped unit snaps its anim position instead of trailing a stale path.
WorldUnitAnimationUpdate :: proc(
	w: ^World,
	deltaTime: f32,
	minX, maxX, minY, maxY: f32,
) {
	if deltaTime <= 0 do return
	worldWidth := f32(w.maxX)
	worldHeight := f32(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 do return
	chunkSize := w.spatial.chunkSize
	chunksX := w.spatial.chunksX
	chunksY := w.spatial.chunksY
	if chunkSize <= 0 || chunksX <= 0 || chunksY <= 0 do return

	now := w.simulationTime+w.simulationAccumulator
	animTick := int(now*24)
	chunkMinX := int(math.floor(minX))/chunkSize-1
	chunkMaxX := int(math.floor(maxX))/chunkSize+1
	chunkMinY := int(math.floor(minY))/chunkSize-1
	chunkMaxY := int(math.floor(maxY))/chunkSize+1
	spanX := min(chunkMaxX-chunkMinX+1, chunksX)
	spanY := min(chunkMaxY-chunkMinY+1, chunksY)
	for chunkOffsetX in 0..<spanX {
		chunkX := WorldWrapCoordinate(chunkMinX+chunkOffsetX, chunksX)
		for chunkOffsetY in 0..<spanY {
			chunkY := WorldWrapCoordinate(chunkMinY+chunkOffsetY, chunksY)
			chunk := chunkX*chunksY+chunkY
			for unitSlot := w.spatial.unitHead[chunk]; unitSlot >= 0;
				unitSlot = w.spatial.unitNext[unitSlot] {
				if !w.unitUsed[unitSlot] do continue
				unit := &w.units[unitSlot]
				if unit.type == nil do continue

		hidden := false
		pacificState: StatePacific
		pacific := false
		switch state in unit.state {
		case StateConverting:
			hidden = state.inside
		case StatePacific:
			pacificState = state
			pacific = true
			if unit.sleepInside && (state == .Sleeping || state == .Hiding) do hidden = true
		case StateWarrior:
		}
		if hidden {
			unit.animX = UnitX(w, unitSlot)
			unit.animY = UnitY(w, unitSlot)
			continue
		}

		kind := UnitKindOf(unit.type)
		profile := UnitAnimationProfileFor(kind)
		x, y := UnitRenderPosition(w, unitSlot)

		deltaX := WorldShortestWrappedDelta(x-unit.animX, worldWidth)
		deltaY := WorldShortestWrappedDelta(y-unit.animY, worldHeight)
		moved := math.sqrt(deltaX*deltaX+deltaY*deltaY)
		unit.animX = x
		unit.animY = y

		if moved > 1.0 {
			// Teleports (conversions, re-links) must not leave a dust trail.
			unit.walkPhase = 0
		} else if moved > 0.0001 {
			previousPhase := unit.walkPhase
			unit.walkPhase += moved*profile.stride
			if int(previousPhase/(2*math.PI)) != int(unit.walkPhase/(2*math.PI)) {
				if WorldNoiseHash(unitSlot, animTick, 0xF007) < 0.8 {
					UnitFootstepDust(w, unitSlot, kind, x, y)
				}
			}
		}

		if pacific && (pacificState == .Working || pacificState == .Building) &&
			profile.workInterval > 0 {
			interval := profile.workInterval
			offset := f32(unitSlot)*0.37
			if int((now-deltaTime)/interval+offset) != int(now/interval+offset) {
				unit.actionStarted = now
				UnitWorkBurst(w, unitSlot, kind, x, y)
			}
		}

		if kind == .Mage {
			previous := int((now-deltaTime)/1.8+f32(unitSlot)*0.53)
			current := int(now/1.8+f32(unitSlot)*0.53)
			if current != previous do UnitAmbientMote(w, unitSlot, x, y, animTick)
		}
			}
		}
	}
}

UnitFootstepTint :: proc(w: ^World, x, y: f32) -> rl.Color {
	tileX := WorldWrapCoordinate(int(x), int(w.maxX))
	tileY := WorldWrapCoordinate(int(y), int(w.maxY))
	switch WorldTileAt(w, tileX, tileY).type {
	case .Ocean, .Lake, .River:
		return rl.Color{118, 184, 206, 150}
	case .Ice:
		return rl.Color{198, 228, 244, 160}
	case .Sand, .Desert:
		return rl.Color{196, 168, 112, 140}
	case .Forest, .Taiga, .Marsh, .Plains:
		return rl.Color{112, 92, 62, 130}
	case .Grassland, .Steppe, .Hill, .Tundra, .Ash:
		return rl.Color{142, 132, 114, 130}
	case .Mountain:
		return rl.Color{120, 120, 124, 130}
	case .Lava:
		return rl.Color{196, 96, 62, 150}
	}
	unreachable()
}

UnitTileIsWater :: proc(w: ^World, x, y: f32) -> bool {
	tileX := WorldWrapCoordinate(int(x), int(w.maxX))
	tileY := WorldWrapCoordinate(int(y), int(w.maxY))
	return TileIsWater(WorldTileAt(w, tileX, tileY).type)
}

UnitFootstepDust :: proc(w: ^World, unitSlot: int, kind: UnitKind, x, y: f32) {
	scale := UnitSpriteScale(kind)
	tint := UnitFootstepTint(w, x, y)
	water := kind == .Turtle && UnitTileIsWater(w, x, y)
	tick := int((w.simulationTime+w.simulationAccumulator)*24)
	count := kind == .Giant ? 2 : 1
	for i in 0..<count {
		offset := u64(i)
		ParticleSpawn(w, Particle{
			x = x+(WorldNoiseHash(unitSlot, tick, 0xF101+offset)-0.5)*0.35*scale,
			y = y+(WorldNoiseHash(unitSlot, tick, 0xF111+offset)-0.5)*0.18*scale,
			z = water ? 0.08 : 0.05,
			vx = (WorldNoiseHash(unitSlot, tick, 0xF121+offset)-0.5)*0.35,
			vy = (WorldNoiseHash(unitSlot, tick, 0xF131+offset)-0.5)*0.35,
			vz = 0.12+WorldNoiseHash(unitSlot, tick, 0xF141+offset)*0.18,
			life = 0.35+WorldNoiseHash(unitSlot, tick, 0xF151+offset)*0.45,
			size = (0.10+WorldNoiseHash(unitSlot, tick, 0xF161+offset)*0.10)*scale,
			drag = 3,
			gravity = water ? 6 : 0.5,
			kind = water ? .Splash : .Dust,
			tint = water ? rl.WHITE : tint,
		})
	}
}

UnitWorkBurst :: proc(w: ^World, unitSlot: int, kind: UnitKind, x, y: f32) {
	tick := int((w.simulationTime+w.simulationAccumulator)*24)
	switch kind {
	case .Builder, .CombatBuilder:
		for i in 0..<2 {
			offset := u64(i)
			stone := WorldNoiseHash(unitSlot, tick, 0xB001+offset) < 0.3
			ParticleSpawn(w, Particle{
				x = x+(WorldNoiseHash(unitSlot, tick, 0xB011+offset)-0.5)*0.4,
				y = y+(WorldNoiseHash(unitSlot, tick, 0xB021+offset)-0.5)*0.3,
				z = 0.35,
				vx = (WorldNoiseHash(unitSlot, tick, 0xB031+offset)-0.5)*1.6,
				vy = (WorldNoiseHash(unitSlot, tick, 0xB041+offset)-0.5)*1.6,
				vz = 1.0+WorldNoiseHash(unitSlot, tick, 0xB051+offset)*1.6,
				life = 0.45+WorldNoiseHash(unitSlot, tick, 0xB061+offset)*0.5,
				size = 0.10+WorldNoiseHash(unitSlot, tick, 0xB071+offset)*0.06,
				gravity = 18,
				bounce = 0.3,
				kind = stone ? .StoneChip : .WoodChip,
				tint = rl.WHITE,
			})
		}
	case .Farmer:
		for i in 0..<2 {
			offset := u64(i)
			ParticleSpawn(w, Particle{
				x = x+(WorldNoiseHash(unitSlot, tick, 0xB101+offset)-0.5)*0.45,
				y = y+(WorldNoiseHash(unitSlot, tick, 0xB111+offset)-0.5)*0.35,
				z = 0.12,
				vx = (WorldNoiseHash(unitSlot, tick, 0xB121+offset)-0.5)*0.8,
				vy = (WorldNoiseHash(unitSlot, tick, 0xB131+offset)-0.5)*0.8,
				vz = 0.3+WorldNoiseHash(unitSlot, tick, 0xB141+offset)*0.3,
				life = 0.4+WorldNoiseHash(unitSlot, tick, 0xB151+offset)*0.4,
				size = 0.12+WorldNoiseHash(unitSlot, tick, 0xB161+offset)*0.08,
				drag = 2,
				gravity = 1,
				kind = .Dust,
				tint = rl.Color{106, 78, 52, 150},
			})
		}
	case .WaterCollector:
		for i in 0..<2 {
			offset := u64(i)
			ParticleSpawn(w, Particle{
				x = x+(WorldNoiseHash(unitSlot, tick, 0xB201+offset)-0.5)*0.35,
				y = y+(WorldNoiseHash(unitSlot, tick, 0xB211+offset)-0.5)*0.25,
				z = 0.30,
				vx = (WorldNoiseHash(unitSlot, tick, 0xB221+offset)-0.5)*0.9,
				vy = (WorldNoiseHash(unitSlot, tick, 0xB231+offset)-0.5)*0.9,
				vz = 0.7+WorldNoiseHash(unitSlot, tick, 0xB241+offset)*0.7,
				life = 0.30+WorldNoiseHash(unitSlot, tick, 0xB251+offset)*0.25,
				size = 0.10+WorldNoiseHash(unitSlot, tick, 0xB261+offset)*0.06,
				gravity = 8,
				kind = .Splash,
				tint = rl.WHITE,
			})
		}
	case .Villager, .Knight, .Archer, .Mage, .Giant, .Turtle, .Catapult, .Rogue, .Explorer:
	}
}

UnitAmbientMote :: proc(w: ^World, unitSlot: int, x, y: f32, tick: int) {
	ParticleSpawn(w, Particle{
		x = x+(WorldNoiseHash(unitSlot, tick, 0xC101)-0.5)*0.35,
		y = y+(WorldNoiseHash(unitSlot, tick, 0xC111)-0.5)*0.25,
		z = 0.55+WorldNoiseHash(unitSlot, tick, 0xC121)*0.35,
		vx = (WorldNoiseHash(unitSlot, tick, 0xC131)-0.5)*0.25,
		vy = (WorldNoiseHash(unitSlot, tick, 0xC141)-0.5)*0.25,
		vz = 0.25+WorldNoiseHash(unitSlot, tick, 0xC151)*0.35,
		life = 0.7+WorldNoiseHash(unitSlot, tick, 0xC161)*0.6,
		size = 0.09+WorldNoiseHash(unitSlot, tick, 0xC171)*0.06,
		drag = 1.2,
		kind = .MagicMote,
		tint = rl.WHITE,
	})
}

// Sets the attack animation and emits the matching projectile or impact burst.
UnitAttackBurst :: proc(w: ^World, unitSlot: int, impactX, impactY: f32) {
	unit := &w.units[unitSlot]
	if unit.type == nil do return

	kind := UnitKindOf(unit.type)
	deltaX := WorldShortestWrappedDelta(impactX-UnitX(w, unitSlot), f32(w.maxX))
	deltaY := WorldShortestWrappedDelta(impactY-UnitY(w, unitSlot), f32(w.maxY))
	distance := math.sqrt(deltaX*deltaX+deltaY*deltaY)
	dirX: f32
	dirY: f32
	if distance > 0.001 {
		dirX = deltaX/distance
		dirY = deltaY/distance
	}

	unit.actionStarted = w.simulationTime
	unit.actionDirX = dirX
	unit.actionDirY = dirY

	switch kind {
	case .Archer:
		UnitProjectile(w, UnitX(w, unitSlot), UnitY(w, unitSlot), dirX, dirY, distance, 20, 1.2, 0.35, 0.55, 0.3, 0, .Arrow)
	case .Mage:
		UnitProjectile(w, UnitX(w, unitSlot), UnitY(w, unitSlot), dirX, dirY, distance, 11, 0, 0.28, 0.60, 0.1, 0, .MagicMote)
	case .Catapult:
		UnitProjectile(w, UnitX(w, unitSlot), UnitY(w, unitSlot), dirX, dirY, distance, 9, 0, 0.45, 0.70, 0, 4, .Boulder)
	case .Knight, .Rogue, .CombatBuilder:
		UnitClashBurst(w, unitSlot, impactX, impactY)
	case .Giant, .Turtle:
		UnitHeavyImpact(w, unitSlot, impactX, impactY)
	case .Villager, .Builder, .WaterCollector, .Farmer, .Explorer:
	}
}

UnitProjectile :: proc(
	w: ^World,
	fromX, fromY, dirX, dirY, distance: f32,
	speed, gravity, size, height, lift, spin: f32,
	kind: ParticleKind,
) {
	ParticleSpawn(w, Particle{
		x = fromX,
		y = fromY,
		z = height,
		vx = dirX*speed,
		vy = dirY*speed,
		vz = lift,
		life = distance/max(speed, 0.01),
		size = size,
		rotation = math.atan2(dirY, dirX),
		spin = spin,
		gravity = gravity,
		kind = kind,
		tint = rl.WHITE,
	})
}

WorldProjectileBurst :: proc(
	w: ^World,
	fromX, fromY, toX, toY: f32,
	speed, gravity, size, height, lift, spin: f32,
	kind: ParticleKind,
) {
	deltaX := WorldShortestWrappedDelta(toX-fromX, f32(w.maxX))
	deltaY := WorldShortestWrappedDelta(toY-fromY, f32(w.maxY))
	distance := math.sqrt(deltaX*deltaX+deltaY*deltaY)
	if distance <= 0.001 do return
	UnitProjectile(
		w,
		fromX,
		fromY,
		deltaX/distance,
		deltaY/distance,
		distance,
		speed,
		gravity,
		size,
		height,
		lift,
		spin,
		kind,
	)
}

UnitClashBurst :: proc(w: ^World, unitSlot: int, x, y: f32) {
	tick := int((w.simulationTime+w.simulationAccumulator)*24)
	for i in 0..<3 {
		offset := u64(i)
		ParticleSpawn(w, Particle{
			x = x+(WorldNoiseHash(unitSlot, tick, 0xD101+offset)-0.5)*0.25,
			y = y+(WorldNoiseHash(unitSlot, tick, 0xD111+offset)-0.5)*0.25,
			z = 0.55,
			vx = (WorldNoiseHash(unitSlot, tick, 0xD121+offset)-0.5)*2.6,
			vy = (WorldNoiseHash(unitSlot, tick, 0xD131+offset)-0.5)*2.6,
			vz = 0.5+WorldNoiseHash(unitSlot, tick, 0xD141+offset)*1.5,
			life = 0.15+WorldNoiseHash(unitSlot, tick, 0xD151+offset)*0.20,
			size = 0.10+WorldNoiseHash(unitSlot, tick, 0xD161+offset)*0.06,
			drag = 2,
			gravity = 4,
			kind = .Spark,
			tint = rl.WHITE,
		})
	}
}

UnitHeavyImpact :: proc(w: ^World, unitSlot: int, x, y: f32) {
	tint := UnitFootstepTint(w, x, y)
	tick := int((w.simulationTime+w.simulationAccumulator)*24)
	for i in 0..<4 {
		offset := u64(i)
		ParticleSpawn(w, Particle{
			x = x+(WorldNoiseHash(unitSlot, tick, 0xD201+offset)-0.5)*0.35,
			y = y+(WorldNoiseHash(unitSlot, tick, 0xD211+offset)-0.5)*0.35,
			z = 0.10,
			vx = (WorldNoiseHash(unitSlot, tick, 0xD221+offset)-0.5)*1.8,
			vy = (WorldNoiseHash(unitSlot, tick, 0xD231+offset)-0.5)*1.8,
			vz = 0.3+WorldNoiseHash(unitSlot, tick, 0xD241+offset)*0.5,
			life = 0.45+WorldNoiseHash(unitSlot, tick, 0xD251+offset)*0.55,
			size = 0.18+WorldNoiseHash(unitSlot, tick, 0xD261+offset)*0.16,
			drag = 2,
			gravity = 1.5,
			kind = .Dust,
			tint = tint,
		})
	}
}
