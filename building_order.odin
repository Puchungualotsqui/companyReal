package main

import rl "vendor:raylib"
import "core:math"

// Order buildings are physical sources for strategic orders. The building must
// exist and be ready; the order icon never appears on its own.
ORDER_MORTAR_RADIUS :: 4.0
ORDER_MORTAR_SPREAD_RADIUS :: 3.0
ORDER_MORTAR_BLAST_RADIUS :: 1.6
ORDER_MORTAR_DURATION :: 10.0
ORDER_MORTAR_COOLDOWN :: 30.0
ORDER_MORTAR_TICK :: 0.6
ORDER_MORTAR_UNIT_DAMAGE :: 7.0
ORDER_MORTAR_BUILDING_DAMAGE :: 20.0

OrderKind :: enum {
	GiantMortar,
	Blockade,
}

ALL_ORDER_KINDS := [2]OrderKind{.GiantMortar, .Blockade}

OrderName :: proc(kind: OrderKind) -> cstring {
	switch kind {
	case .GiantMortar:
		return "Giant Mortar"
	case .Blockade:
		return "Blockade"
	}
	unreachable()
}

OrderDescription :: proc(kind: OrderKind) -> cstring {
	switch kind {
	case .GiantMortar:
		return "Bombards a chosen area for 10 seconds."
	case .Blockade:
		return "Cuts an enemy coastal town's food, water and growth."
	}
	unreachable()
}

OrderRadius :: proc(kind: OrderKind) -> f32 {
	switch kind {
	case .GiantMortar:
		return ORDER_MORTAR_RADIUS
	case .Blockade:
		return 0
	}
	unreachable()
}

OrderDuration :: proc(kind: OrderKind) -> f32 {
	switch kind {
	case .GiantMortar:
		return ORDER_MORTAR_DURATION
	case .Blockade:
		return 0
	}
	unreachable()
}

OrderCooldownSeconds :: proc(kind: OrderKind) -> f32 {
	switch kind {
	case .GiantMortar:
		return ORDER_MORTAR_COOLDOWN
	case .Blockade:
		return 180
	}
	unreachable()
}

OrderSourceKind :: proc(kind: OrderKind) -> (BuildingKind, bool) {
	switch kind {
	case .GiantMortar:
		return .GiantMortar, true
	case .Blockade:
		return .Harbor, true
	}
	return .Wall, false
}

BuildingOrderKind :: proc(kind: BuildingKind) -> (OrderKind, bool) {
	switch kind {
	case .GiantMortar:
		return .GiantMortar, true
	case .Harbor:
		return .Blockade, true
	case .TownHall, .Home, .Farmland, .Wall, .Bridge, .Cannon, .Watchtower, .ArcheryRange, .MagicSchool, .GiantPen, .SiegeWorkshop, .TurtlePen, .ThievesGuild, .Path, .DistrictHall, .Granary:
		return .GiantMortar, false
	}
	return .GiantMortar, false
}

OrderUnlocked :: proc(w: ^World, kingdom: int, kind: OrderKind) -> bool {
	switch kind {
	case .GiantMortar:
		return true
	case .Blockade:
		return KingdomHasTech(w, kingdom, .Blockade)
	}
	return false
}

BuildingOrderState :: proc(w: ^World, slot: int) -> (^BuildingOrder, bool) {
	if slot < 0 || slot >= BUILDING_CAPACITY || !w.buildingUsed[slot] do return nil, false
	if _, isOrder := BuildingOrderKind(BuildingKindOf(w.buildings.type[slot])); !isOrder {
		return nil, false
	}
	return &w.buildings.type[slot].(BuildingOrder), true
}

OrderBuildingCenter :: proc(w: ^World, slot: int) -> (x, y: f32) {
	width, height := BuildingTileSize(w.buildings[slot].type)
	return f32(w.buildings.x[slot])+f32(width)*0.5,
		f32(w.buildings.y[slot])+f32(height)*0.5
}

OrderSourceNearestReady :: proc(w: ^World, kingdom: int, kind: OrderKind, targetX, targetY: f32) -> int {
	if !OrderUnlocked(w, kingdom, kind) do return -1
	best := -1
	bestDistance: f32 = 0
	for slot in 0..<BUILDING_CAPACITY {
		if !w.buildingUsed[slot] || w.buildings.kingdom[slot] != kingdom do continue
		buildingOrder, ok := BuildingOrderKind(BuildingKindOf(w.buildings.type[slot]))
		if !ok || buildingOrder != kind do continue
		order, isOrder := BuildingOrderState(w, slot)
		if !isOrder do continue
		if order.orderCooldown > 0 || order.orderActive > 0 do continue

		centerX, centerY := OrderBuildingCenter(w, slot)
		deltaX := WorldShortestWrappedDelta(centerX-targetX, f32(w.maxX))
		deltaY := WorldShortestWrappedDelta(centerY-targetY, f32(w.maxY))
		distance := deltaX*deltaX+deltaY*deltaY
		if best < 0 || distance < bestDistance {
			best = slot
			bestDistance = distance
		}
	}
	return best
}

OrderSourceCount :: proc(w: ^World, kingdom: int, kind: OrderKind) -> int {
	if !OrderUnlocked(w, kingdom, kind) do return 0
	count := 0
	for slot in 0..<BUILDING_CAPACITY {
		if !w.buildingUsed[slot] || w.buildings.kingdom[slot] != kingdom do continue
		if buildingOrder, ok := BuildingOrderKind(BuildingKindOf(w.buildings.type[slot])); ok &&
			buildingOrder == kind {
			count += 1
		}
	}
	return count
}

OrderSourceReadyCount :: proc(w: ^World, kingdom: int, kind: OrderKind) -> int {
	if !OrderUnlocked(w, kingdom, kind) do return 0
	count := 0
	for slot in 0..<BUILDING_CAPACITY {
		if !w.buildingUsed[slot] || w.buildings.kingdom[slot] != kingdom do continue
		if buildingOrder, ok := BuildingOrderKind(BuildingKindOf(w.buildings.type[slot])); !ok ||
			buildingOrder != kind {
			continue
		}
		order, isOrder := BuildingOrderState(w, slot)
		if isOrder && order.orderCooldown <= 0 && order.orderActive <= 0 {
			count += 1
		}
	}
	return count
}

OrderSourceActiveCount :: proc(w: ^World, kingdom: int, kind: OrderKind) -> int {
	if !OrderUnlocked(w, kingdom, kind) do return 0
	count := 0
	for slot in 0..<BUILDING_CAPACITY {
		if !w.buildingUsed[slot] || w.buildings.kingdom[slot] != kingdom do continue
		if buildingOrder, ok := BuildingOrderKind(BuildingKindOf(w.buildings.type[slot])); !ok ||
			buildingOrder != kind {
			continue
		}
		order, isOrder := BuildingOrderState(w, slot)
		if isOrder && order.orderActive > 0 do count += 1
	}
	return count
}

OrderActiveRemaining :: proc(w: ^World, kingdom: int, kind: OrderKind) -> f32 {
	if !OrderUnlocked(w, kingdom, kind) do return 0
	remaining: f32 = 0
	for slot in 0..<BUILDING_CAPACITY {
		if !w.buildingUsed[slot] || w.buildings.kingdom[slot] != kingdom do continue
		if buildingOrder, ok := BuildingOrderKind(BuildingKindOf(w.buildings.type[slot])); !ok ||
			buildingOrder != kind {
			continue
		}
		order, isOrder := BuildingOrderState(w, slot)
		if isOrder do remaining = max(remaining, order.orderActive)
	}
	return remaining
}

OrderNextCooldown :: proc(w: ^World, kingdom: int, kind: OrderKind) -> f32 {
	if !OrderUnlocked(w, kingdom, kind) do return 0
	next: f32 = -1
	for slot in 0..<BUILDING_CAPACITY {
		if !w.buildingUsed[slot] || w.buildings.kingdom[slot] != kingdom do continue
		if buildingOrder, ok := BuildingOrderKind(BuildingKindOf(w.buildings.type[slot])); !ok ||
			buildingOrder != kind {
			continue
		}
		order, isOrder := BuildingOrderState(w, slot)
		if !isOrder do continue
		remaining := max(order.orderCooldown, order.orderActive)
		if remaining <= 0 do continue
		if next < 0 || remaining < next do next = remaining
	}
	return max(next, 0)
}

TownAtPoint :: proc(w: ^World, x, y: f32) -> (kingdom, town: int, found: bool) {
	tileX := int(WorldWrapPosition(x, f32(w.maxX)))
	tileY := int(WorldWrapPosition(y, f32(w.maxY)))
	for kingdomSlot in 0..<KINGDOM_SLOTS {
		if !w.kingdomUsed[kingdomSlot] do continue
		for townSlot in 0..<TOWN_CAPACITY {
			if !w.kingdoms[kingdomSlot].townUsed[townSlot] do continue
			if TownPointInArea(w, kingdomSlot, townSlot, tileX, tileY) {
				return kingdomSlot, townSlot, true
			}
		}
	}
	return -1, -1, false
}

// Target validity only covers the map and the order rules. Whether a source
// is currently ready is checked when the strike is issued.
OrderTargetValid :: proc(w: ^World, kingdom: int, kind: OrderKind, x, y: f32) -> bool {
	if !OrderUnlocked(w, kingdom, kind) do return false
	switch kind {
	case .GiantMortar:
		if kingdom == w.observerKingdom {
			tileX := int(WorldWrapPosition(x, f32(w.maxX)))
			tileY := int(WorldWrapPosition(y, f32(w.maxY)))
			if !FogTileExplored(w, tileX, tileY) do return false
		}
		return true
	case .Blockade:
		if kingdom == w.observerKingdom {
			tileX := int(WorldWrapPosition(x, f32(w.maxX)))
			tileY := int(WorldWrapPosition(y, f32(w.maxY)))
			if !FogTileExplored(w, tileX, tileY) do return false
		}
		targetKingdom, targetTown, found := TownAtPoint(w, x, y)
		if !found || targetKingdom == kingdom do return false
		if !KingdomAtWar(w, kingdom, targetKingdom) do return false
		if !TownIsCoastal(w, targetKingdom, targetTown) do return false
		if w.kingdoms[targetKingdom].towns[targetTown].blockadeUntil > w.simulationTime {
			return false
		}
		return true
	}
	return false
}

OrderStart :: proc(w: ^World, kingdom: int, kind: OrderKind, x, y: f32) -> bool {
	if !OrderTargetValid(w, kingdom, kind, x, y) do return false
	slot := OrderSourceNearestReady(w, kingdom, kind, x, y)
	if slot < 0 do return false
	order, isOrder := BuildingOrderState(w, slot)
	if !isOrder do return false

	switch kind {
	case .GiantMortar:
		order.orderActive = OrderDuration(kind)
		order.orderCooldown = OrderDuration(kind)+OrderCooldownSeconds(kind)
		order.orderTargetX = WorldWrapPosition(x, f32(w.maxX))
		order.orderTargetY = WorldWrapPosition(y, f32(w.maxY))
		order.orderTick = 0
		return true
	case .Blockade:
		targetKingdom, targetTown, found := TownAtPoint(w, x, y)
		if !found do return false
		target := &w.kingdoms[targetKingdom].towns[targetTown]
		target.blockadeUntil = w.simulationTime+90
		target.blockadeBy = kingdom
		order.orderActive = 0
		order.orderCooldown = OrderCooldownSeconds(kind)
		order.orderTargetX = WorldWrapPosition(f32(target.x)+2, f32(w.maxX))
		order.orderTargetY = WorldWrapPosition(f32(target.y)+2, f32(w.maxY))
		order.orderTick = 0
		return true
	}
	return false
}

BuildingUpdateOrder :: proc(w: ^World, slot: int, deltaTime: f32) {
	order, isOrder := BuildingOrderState(w, slot)
	if !isOrder do return
	if order.orderCooldown > 0 do order.orderCooldown = max(order.orderCooldown-deltaTime, 0)
	switch _ in order.type {
	case GiantMortar:
		BuildingUpdateGiantMortar(w, slot, deltaTime)
	case Harbor:
	}
}

BuildingUpdateGiantMortar :: proc(w: ^World, slot: int, deltaTime: f32) {
	order, isOrder := BuildingOrderState(w, slot)
	if !isOrder do return
	if order.orderActive <= 0 do return

	order.orderActive = max(order.orderActive-deltaTime, 0)
	order.orderTick -= deltaTime
	for order.orderTick <= 0 {
		OrderMortarFireShell(w, slot)
		order.orderTick += ORDER_MORTAR_TICK
		if _, stillUsed := BuildingOrderState(w, slot); !stillUsed do return
	}
	if order.orderActive <= 0 {
		order.orderActive = 0
		order.orderTick = 0
	}
}

@(private = "file")
OrderMortarFireShell :: proc(w: ^World, slot: int) {
	order, isOrder := BuildingOrderState(w, slot)
	if !isOrder do return
	centerX, centerY := OrderBuildingCenter(w, slot)
	targetX := order.orderTargetX
	targetY := order.orderTargetY
	angle := PRandom(w)*6.2831853
	distance := math.sqrt(PRandom(w))*ORDER_MORTAR_SPREAD_RADIUS
	impactX := WorldWrapPosition(targetX+math.cos(angle)*distance, f32(w.maxX))
	impactY := WorldWrapPosition(targetY+math.sin(angle)*distance, f32(w.maxY))

	WorldProjectileBurst(w, centerX, centerY, impactX, impactY, 55, 1.4, 0.55, 1.2, 0, 0, .Boulder)
	OrderImpactBurst(w, impactX, impactY)
	OrderAreaDamage(
		w,
		w.buildings.kingdom[slot],
		impactX,
		impactY,
		ORDER_MORTAR_BLAST_RADIUS,
		ORDER_MORTAR_UNIT_DAMAGE,
		ORDER_MORTAR_BUILDING_DAMAGE,
	)
}

@(private = "file")
OrderImpactBurst :: proc(w: ^World, x, y: f32) {
	for _ in 0..<2 {
		ParticleSpawn(w, Particle{
			x = x+(PRandom(w)-0.5)*0.5,
			y = y+(PRandom(w)-0.5)*0.5,
			z = PRandomRange(w, 0.15, 0.5),
			vx = (PRandom(w)-0.5)*1.2,
			vy = (PRandom(w)-0.5)*1.2,
			vz = PRandomRange(w, 0.8, 2.0),
			life = PRandomRange(w, 0.45, 0.9),
			size = PRandomRange(w, 0.35, 0.65),
			drag = 2,
			gravity = 3,
			kind = .Dust,
			tint = rl.Color{188, 172, 146, 255},
		})
	}
	ParticleSpawn(w, Particle{
		x = x,
		y = y,
		z = 0.4,
		vx = (PRandom(w)-0.5)*0.4,
		vy = (PRandom(w)-0.5)*0.4,
		vz = 1.4,
		life = PRandomRange(w, 0.7, 1.2),
		size = PRandomRange(w, 0.8, 1.2),
		drag = 1.5,
		gravity = -1,
		kind = .Smoke,
		tint = rl.Color{82, 76, 74, 220},
	})
}

@(private = "file")
OrderAreaDamage :: proc(
	w: ^World,
	attackerKingdom: int,
	x, y, radius, unitDamage, buildingDamage: f32,
) {
	chunkSize := w.spatial.chunkSize
	if chunkSize <= 0 do return
	worldWidth := f32(w.maxX)
	worldHeight := f32(w.maxY)
	centerX := WorldWrapPosition(x, worldWidth)
	centerY := WorldWrapPosition(y, worldHeight)
	radiusSquared := radius*radius

	centerChunkX := int(centerX)/chunkSize
	centerChunkY := int(centerY)/chunkSize
	chunkRadius := int(radius)/chunkSize+1
	for offsetX in -chunkRadius..=chunkRadius {
		chunkX := WorldWrapCoordinate(centerChunkX+offsetX, w.spatial.chunksX)
		for offsetY in -chunkRadius..=chunkRadius {
			chunkY := WorldWrapCoordinate(centerChunkY+offsetY, w.spatial.chunksY)
			chunk := chunkX*w.spatial.chunksY+chunkY

			slot := w.spatial.unitHead[chunk]
			for slot >= 0 {
				next := w.spatial.unitNext[slot]
				if w.unitUsed[slot] && w.units.type[slot] != nil && !UnitHiddenInside(w, slot) &&
					w.units.kingdome[slot] != attackerKingdom &&
					KingdomAtWar(w, attackerKingdom, w.units.kingdome[slot]) {
					deltaX := WorldShortestWrappedDelta(w.units.x[slot]-centerX, worldWidth)
					deltaY := WorldShortestWrappedDelta(w.units.y[slot]-centerY, worldHeight)
					if deltaX*deltaX+deltaY*deltaY <= radiusSquared {
						UnitApplyDamage(w, slot, unitDamage, centerX, centerY, .Area)
					}
				}
				slot = next
			}

			slot = w.spatial.buildingHead[chunk]
			for slot >= 0 {
				next := w.spatial.buildingNext[slot]
				if w.buildingUsed[slot] && w.buildings.kingdom[slot] != attackerKingdom &&
					KingdomAtWar(w, attackerKingdom, w.buildings.kingdom[slot]) {
					distance, impactX, impactY := WarriorBuildingNearestPoint(w, centerX, centerY, slot)
					if distance <= radius {
						OrderDamageBuilding(w, slot, buildingDamage, impactX, impactY, attackerKingdom)
					}
				}
				slot = next
			}
		}
	}

	WorldDecorationAreaDamage(w, centerX, centerY, radius, buildingDamage)
}

@(private = "file")
OrderDamageBuilding :: proc(
	w: ^World,
	slot: int,
	damage: f32,
	impactX, impactY: f32,
	attackerKingdom: int,
) {
	if slot < 0 || slot >= BUILDING_CAPACITY || !w.buildingUsed[slot] do return
	building := &w.buildings[slot]
	if building.kingdom == attackerKingdom do return

	if building.kingdom == w.observerKingdom && building.town >= 0 && building.town < TOWN_CAPACITY {
		width, height := BuildingTileSize(building.type)
		WorldAlertAdd(
			w,
			.UnderAttack,
			building.kingdom,
			building.town,
			attackerKingdom,
			f32(building.x)+f32(width)*0.5,
			f32(building.y)+f32(height)*0.5,
		)
	}

	BuildingHitBurst(w, slot, impactX, impactY)
	building.health -= damage
	if building.health > 0 do return

	wasBurning := BuildingOnFire(w, slot)
	kind := BuildingKindOf(building.type)
	if !BuildingImmuneToFire(kind) && PRandom(w) < 0.15 {
		WorldFireIgnite(w, impactX, impactY, 1)
	}
	BuildingSpawnDebris(w, slot, wasBurning)
	BuildingDestroyedBurst(w, slot)
	BuildingDespawn(w, slot, attackerKingdom)
}
