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

ORDER_GLACIER_RADIUS :: 4.0
ORDER_GLACIER_COOLDOWN :: 150.0

ORDER_TREMOR_RADIUS :: 4.5
ORDER_TREMOR_DURATION :: 4.0
ORDER_TREMOR_TICK :: 0.7
ORDER_TREMOR_UNIT_DAMAGE :: 6.0
ORDER_TREMOR_BUILDING_DAMAGE :: 55.0
ORDER_TREMOR_COOLDOWN :: 120.0

ORDER_STARFALL_RADIUS :: 5.5
ORDER_STARFALL_UNIT_DAMAGE :: 120.0
ORDER_STARFALL_BUILDING_DAMAGE :: 350.0
ORDER_STARFALL_COOLDOWN :: 240.0

ORDER_FLOOD_RADIUS :: 4.0
ORDER_FLOOD_COOLDOWN :: 150.0

ORDER_MIASMA_RADIUS :: 3.5
ORDER_MIASMA_DURATION :: 18.0
ORDER_MIASMA_COOLDOWN :: 180.0

ORDER_NAPALM_RADIUS :: 5.0
ORDER_NAPALM_DURATION :: 5.0
ORDER_NAPALM_TICK :: 0.6
ORDER_NAPALM_COOLDOWN :: 180.0

ORDER_MORTAR_TELEGRAPH :: 0.8
ORDER_GLACIER_TELEGRAPH :: 1.2
ORDER_TREMOR_TELEGRAPH :: 1.2
ORDER_STARFALL_TELEGRAPH :: 2.0
ORDER_FLOOD_TELEGRAPH :: 1.2
ORDER_MIASMA_TELEGRAPH :: 1.2
ORDER_NAPALM_TELEGRAPH :: 1.5

OrderKind :: enum {
	GiantMortar,
	Blockade,
	GlacierShell,
	SiegeTremor,
	Starfall,
	WaterBomber,
	MiasmaBarrage,
	NapalmBarrage,
}

ALL_ORDER_KINDS := [8]OrderKind{
	.GiantMortar,
	.Blockade,
	.GlacierShell,
	.SiegeTremor,
	.Starfall,
	.WaterBomber,
	.MiasmaBarrage,
	.NapalmBarrage,
}

OrderName :: proc(kind: OrderKind) -> cstring {
	switch kind {
	case .GiantMortar:
		return "Giant Mortar"
	case .Blockade:
		return "Blockade"
	case .GlacierShell:
		return "Glacier Shell"
	case .SiegeTremor:
		return "Siege Tremor"
	case .Starfall:
		return "Starfall"
	case .WaterBomber:
		return "Water Bomber"
	case .MiasmaBarrage:
		return "Miasma Barrage"
	case .NapalmBarrage:
		return "Napalm Barrage"
	}
	unreachable()
}

OrderDescription :: proc(kind: OrderKind) -> cstring {
	switch kind {
	case .GiantMortar:
		return "For ten breaths the sky falls, and the chosen ground is no longer ground."
	case .Blockade:
		return "No sail, no grain, no water. A coastal town is slowly squeezed into silence."
	case .GlacierShell:
		return "The air turns to glass. For a while, everything beneath it belongs to winter."
	case .SiegeTremor:
		return "The land remembers old fractures. Walls and towers forget why they stood."
	case .Starfall:
		return "A star is asked to come down. It does not stop to choose what it strikes."
	case .WaterBomber:
		return "The river is lifted and dropped. Those who cannot swim are returned to it."
	case .MiasmaBarrage:
		return "A green breath settles and stays. It does not care whose lungs it finds."
	case .NapalmBarrage:
		return "Fire in jars, sown from above. The earth keeps the heat long after."
	}
	unreachable()
}

OrderRadius :: proc(kind: OrderKind) -> f32 {
	switch kind {
	case .GiantMortar:
		return ORDER_MORTAR_RADIUS
	case .Blockade:
		return 0
	case .GlacierShell:
		return ORDER_GLACIER_RADIUS
	case .SiegeTremor:
		return ORDER_TREMOR_RADIUS
	case .Starfall:
		return ORDER_STARFALL_RADIUS
	case .WaterBomber:
		return ORDER_FLOOD_RADIUS
	case .MiasmaBarrage:
		return ORDER_MIASMA_RADIUS
	case .NapalmBarrage:
		return ORDER_NAPALM_RADIUS
	}
	unreachable()
}

OrderDuration :: proc(kind: OrderKind) -> f32 {
	switch kind {
	case .GiantMortar:
		return ORDER_MORTAR_DURATION
	case .Blockade, .GlacierShell, .WaterBomber, .MiasmaBarrage:
		return 0
	case .SiegeTremor:
		return ORDER_TREMOR_DURATION
	case .Starfall:
		return 0
	case .NapalmBarrage:
		return ORDER_NAPALM_DURATION
	}
	unreachable()
}

OrderTelegraph :: proc(kind: OrderKind) -> f32 {
	switch kind {
	case .GiantMortar:
		return ORDER_MORTAR_TELEGRAPH
	case .Blockade:
		return 0
	case .GlacierShell:
		return ORDER_GLACIER_TELEGRAPH
	case .SiegeTremor:
		return ORDER_TREMOR_TELEGRAPH
	case .Starfall:
		return ORDER_STARFALL_TELEGRAPH
	case .WaterBomber:
		return ORDER_FLOOD_TELEGRAPH
	case .MiasmaBarrage:
		return ORDER_MIASMA_TELEGRAPH
	case .NapalmBarrage:
		return ORDER_NAPALM_TELEGRAPH
	}
	unreachable()
}

OrderWardCost :: proc(kind: OrderKind) -> f32 {
	switch kind {
	case .GiantMortar:
		return 12
	case .Blockade:
		return 0
	case .GlacierShell:
		return 18
	case .SiegeTremor:
		return 25
	case .Starfall:
		return 60
	case .WaterBomber:
		return 24
	case .MiasmaBarrage:
		return 20
	case .NapalmBarrage:
		return 30
	}
	return 0
}

OrderCooldownSeconds :: proc(kind: OrderKind) -> f32 {
	switch kind {
	case .GiantMortar:
		return ORDER_MORTAR_COOLDOWN
	case .Blockade:
		return 180
	case .GlacierShell:
		return ORDER_GLACIER_COOLDOWN
	case .SiegeTremor:
		return ORDER_TREMOR_COOLDOWN
	case .Starfall:
		return ORDER_STARFALL_COOLDOWN
	case .WaterBomber:
		return ORDER_FLOOD_COOLDOWN
	case .MiasmaBarrage:
		return ORDER_MIASMA_COOLDOWN
	case .NapalmBarrage:
		return ORDER_NAPALM_COOLDOWN
	}
	unreachable()
}

OrderSourceKind :: proc(kind: OrderKind) -> (BuildingKind, bool) {
	switch kind {
	case .GiantMortar:
		return .GiantMortar, true
	case .Blockade, .WaterBomber:
		return .Harbor, true
	case .GlacierShell:
		return .MagicSchool, true
	case .SiegeTremor:
		return .SiegeWorkshop, true
	case .Starfall:
		return .StarfallSpire, true
	case .MiasmaBarrage:
		return .AlchemistWorkshop, true
	case .NapalmBarrage:
		return .FireworksGuild, true
	}
	return .Wall, false
}

BuildingOrderKind :: proc(kind: BuildingKind) -> (OrderKind, bool) {
	switch kind {
	case .GiantMortar:
		return .GiantMortar, true
	case .Harbor:
		return .Blockade, true
	case .MagicSchool:
		return .GlacierShell, true
	case .SiegeWorkshop:
		return .SiegeTremor, true
	case .AlchemistWorkshop:
		return .MiasmaBarrage, true
	case .FireworksGuild:
		return .NapalmBarrage, true
	case .StarfallSpire:
		return .Starfall, true
	case .TownHall, .Home, .Farmland, .Wall, .Bridge, .Cannon, .Watchtower, .ArcheryRange, .GiantPen, .TurtlePen, .ThievesGuild, .Path, .DistrictHall, .Granary:
		return .GiantMortar, false
	}
	return .GiantMortar, false
}

BuildingOrderSupports :: proc(kind: BuildingKind, orderKind: OrderKind) -> bool {
	switch orderKind {
	case .GiantMortar:
		return kind == .GiantMortar
	case .Blockade, .WaterBomber:
		return kind == .Harbor
	case .GlacierShell:
		return kind == .MagicSchool
	case .SiegeTremor:
		return kind == .SiegeWorkshop
	case .Starfall:
		return kind == .StarfallSpire
	case .MiasmaBarrage:
		return kind == .AlchemistWorkshop
	case .NapalmBarrage:
		return kind == .FireworksGuild
	}
	return false
}

OrderUnlocked :: proc(w: ^World, kingdom: int, kind: OrderKind) -> bool {
	switch kind {
	case .GiantMortar, .GlacierShell, .SiegeTremor, .Starfall, .WaterBomber, .MiasmaBarrage, .NapalmBarrage:
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
		if !BuildingOrderSupports(BuildingKindOf(w.buildings.type[slot]), kind) do continue
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
		if BuildingOrderSupports(BuildingKindOf(w.buildings.type[slot]), kind) {
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
		if !BuildingOrderSupports(BuildingKindOf(w.buildings.type[slot]), kind) do continue
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
		if !BuildingOrderSupports(BuildingKindOf(w.buildings.type[slot]), kind) do continue
		order, isOrder := BuildingOrderState(w, slot)
		if isOrder && (order.orderActive > 0 || order.orderTelegraph > 0) do count += 1
	}
	return count
}

OrderWarningRemaining :: proc(w: ^World, kingdom: int, kind: OrderKind) -> f32 {
	if !OrderUnlocked(w, kingdom, kind) do return 0
	remaining: f32 = 0
	for slot in 0..<BUILDING_CAPACITY {
		if !w.buildingUsed[slot] || w.buildings.kingdom[slot] != kingdom do continue
		if !BuildingOrderSupports(BuildingKindOf(w.buildings.type[slot]), kind) do continue
		order, isOrder := BuildingOrderState(w, slot)
		if !isOrder || !order.orderPending do continue
		remaining = max(remaining, order.orderTelegraph)
	}
	return remaining
}

OrderActiveRemaining :: proc(w: ^World, kingdom: int, kind: OrderKind) -> f32 {
	if !OrderUnlocked(w, kingdom, kind) do return 0
	remaining: f32 = 0
	for slot in 0..<BUILDING_CAPACITY {
		if !w.buildingUsed[slot] || w.buildings.kingdom[slot] != kingdom do continue
		if !BuildingOrderSupports(BuildingKindOf(w.buildings.type[slot]), kind) do continue
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
		if !BuildingOrderSupports(BuildingKindOf(w.buildings.type[slot]), kind) do continue
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
	case .GiantMortar, .GlacierShell, .SiegeTremor, .Starfall, .WaterBomber, .MiasmaBarrage, .NapalmBarrage:
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

	order.orderKind = kind
	order.orderTargetX = WorldWrapPosition(x, f32(w.maxX))
	order.orderTargetY = WorldWrapPosition(y, f32(w.maxY))
	order.orderActive = 0
	order.orderTick = 0
	order.orderMitigation = 0
	order.orderTelegraph = 0
	order.orderPending = false

	if kind == .Blockade {
		targetKingdom, targetTown, found := TownAtPoint(w, x, y)
		if !found do return false
		target := &w.kingdoms[targetKingdom].towns[targetTown]
		target.blockadeUntil = w.simulationTime+90
		target.blockadeBy = kingdom
		order.orderCooldown = OrderCooldownSeconds(kind)
		order.orderTargetX = WorldWrapPosition(f32(target.x)+2, f32(w.maxX))
		order.orderTargetY = WorldWrapPosition(f32(target.y)+2, f32(w.maxY))
		return true
	}

	order.orderTelegraph = OrderTelegraph(kind)
	order.orderPending = order.orderTelegraph > 0
	order.orderCooldown = order.orderTelegraph+OrderDuration(kind)+OrderCooldownSeconds(kind)
	if kind == .Starfall {
		ParticleSpawn(w, Particle{
			x = order.orderTargetX,
			y = order.orderTargetY,
			z = 18,
			vx = 0,
			vy = 0,
			vz = -9.5,
			life = order.orderTelegraph,
			size = 2.2,
			drag = 0,
			gravity = 0,
			rotation = 0.4,
			spin = 180,
			kind = .Boulder,
			tint = rl.Color{255, 176, 108, 255},
		})
	}
	if !order.orderPending do OrderBeginEffect(w, slot)
	return true
}

@(private = "file")
OrderBeginEffect :: proc(w: ^World, slot: int) {
	order, isOrder := BuildingOrderState(w, slot)
	if !isOrder do return
	order.orderPending = false

	targetKingdom, targetTown, found := TownAtPoint(
		w,
		order.orderTargetX,
		order.orderTargetY,
	)
	if found && targetKingdom >= 0 {
		order.orderMitigation = TownAegisAbsorb(
			w,
			targetKingdom,
			targetTown,
			OrderWardCost(order.orderKind),
			order.orderTargetX,
			order.orderTargetY,
		)
	}

	switch order.orderKind {
	case .GiantMortar:
		order.orderActive = ORDER_MORTAR_DURATION
		order.orderTick = 0
	case .GlacierShell:
		scale := 1-order.orderMitigation*0.6
		WorldHazardSpawnCircle(
			w,
			order.orderTargetX,
			order.orderTargetY,
			ORDER_GLACIER_RADIUS*scale,
			.Ice,
			14*scale,
			24*scale,
			0x1CE,
		)
	case .SiegeTremor:
		order.orderActive = ORDER_TREMOR_DURATION
		order.orderTick = 0
	case .Starfall:
		OrderStarfallImpact(w, slot)
	case .WaterBomber:
		scale := 1-order.orderMitigation*0.6
		WorldHazardSpawnCircle(
			w,
			order.orderTargetX,
			order.orderTargetY,
			ORDER_FLOOD_RADIUS*scale,
			.Flood,
			9*scale,
			17*scale,
			0xF100,
		)
	case .MiasmaBarrage:
		scale := 1-order.orderMitigation*0.6
		WorldGasCloudSpawn(
			w,
			order.orderTargetX,
			order.orderTargetY,
			ORDER_MIASMA_RADIUS*scale,
			ORDER_MIASMA_DURATION*scale,
		)
	case .NapalmBarrage:
		order.orderActive = ORDER_NAPALM_DURATION*(1-order.orderMitigation*0.6)
		order.orderTick = 0
	case .Blockade:
	}
}

BuildingUpdateOrder :: proc(w: ^World, slot: int, deltaTime: f32) {
	order, isOrder := BuildingOrderState(w, slot)
	if !isOrder do return
	if order.orderCooldown > 0 do order.orderCooldown = max(order.orderCooldown-deltaTime, 0)
	if order.orderPending {
		order.orderTelegraph = max(order.orderTelegraph-deltaTime, 0)
		if order.orderTelegraph > 0 do return
		OrderBeginEffect(w, slot)
		return
	}
	switch order.orderKind {
	case .GiantMortar:
		BuildingUpdateGiantMortar(w, slot, deltaTime)
	case .SiegeTremor:
		BuildingUpdateSiegeTremor(w, slot, deltaTime)
	case .Starfall:
		BuildingUpdateStarfall(w, slot, deltaTime)
	case .NapalmBarrage:
		BuildingUpdateNapalm(w, slot, deltaTime)
	case .Blockade, .GlacierShell, .WaterBomber, .MiasmaBarrage:
	}
}

BuildingUpdateGiantMortar :: proc(w: ^World, slot: int, deltaTime: f32) {
	order, isOrder := BuildingOrderState(w, slot)
	if !isOrder do return
	if order.orderActive <= 0 do return

	order.orderActive = max(order.orderActive-deltaTime, 0)
	order.orderTick -= deltaTime
	sequence := 0
	for order.orderTick <= 0 {
		OrderMortarFireShell(w, slot, sequence)
		sequence += 1
		order.orderTick += ORDER_MORTAR_TICK
		if _, stillUsed := BuildingOrderState(w, slot); !stillUsed do return
	}
	if order.orderActive <= 0 {
		order.orderActive = 0
		order.orderTick = 0
	}
}

BuildingUpdateSiegeTremor :: proc(w: ^World, slot: int, deltaTime: f32) {
	order, isOrder := BuildingOrderState(w, slot)
	if !isOrder do return
	if order.orderActive <= 0 do return

	order.orderActive = max(order.orderActive-deltaTime, 0)
	order.orderTick -= deltaTime
	sequence := 0
	for order.orderTick <= 0 {
		OrderTremorPulse(w, slot, sequence)
		sequence += 1
		order.orderTick += ORDER_TREMOR_TICK
		if _, stillUsed := BuildingOrderState(w, slot); !stillUsed do return
	}
	if order.orderActive <= 0 {
		order.orderActive = 0
		order.orderTick = 0
	}
}

BuildingUpdateNapalm :: proc(w: ^World, slot: int, deltaTime: f32) {
	order, isOrder := BuildingOrderState(w, slot)
	if !isOrder do return
	if order.orderActive <= 0 do return

	order.orderActive = max(order.orderActive-deltaTime, 0)
	order.orderTick -= deltaTime
	sequence := 0
	for order.orderTick <= 0 {
		OrderNapalmFireShell(w, slot, sequence)
		sequence += 1
		order.orderTick += ORDER_NAPALM_TICK
		if _, stillUsed := BuildingOrderState(w, slot); !stillUsed do return
	}
	if order.orderActive <= 0 {
		order.orderActive = 0
		order.orderTick = 0
	}
}

BuildingUpdateStarfall :: proc(w: ^World, slot: int, deltaTime: f32) {
	order, isOrder := BuildingOrderState(w, slot)
	if !isOrder do return
	if order.orderActive <= 0 do return

	order.orderActive = max(order.orderActive-deltaTime, 0)
	order.orderTick -= deltaTime
	if order.orderTick > 0 do return

	OrderStarfallImpact(w, slot)
	order.orderActive = 0
	order.orderTick = 0
}

// Sequence distinguishes catch-up events emitted by one source in the same tick.
@(private = "file")
OrderEventSeed :: proc(w: ^World, slot, sequence: int, domain: u64) -> u64 {
	return w.seed ~ w.simulationTick*0x9E3779B97F4A7C15 ~
		u64(slot+1)*0xBF58476D1CE4E5B9 ~ u64(sequence+1)*0x94D049BB133111EB ~ domain
}

@(private = "file")
OrderTremorPulse :: proc(w: ^World, slot, sequence: int) {
	order, isOrder := BuildingOrderState(w, slot)
	if !isOrder do return
	kingdom := w.buildings.kingdom[slot]
	x := order.orderTargetX
	y := order.orderTargetY
	scale := 1-order.orderMitigation
	OrderAreaDamage(
		w,
		kingdom,
		x,
		y,
		ORDER_TREMOR_RADIUS,
		ORDER_TREMOR_UNIT_DAMAGE*scale,
		ORDER_TREMOR_BUILDING_DAMAGE*scale,
		OrderEventSeed(w, slot, sequence, 0x7E00),
	)
	OrderImpactBurst(w, x, y)
	for _ in 0..<3 {
		angle := PRandom(w)*6.2831853
		distance := ORDER_TREMOR_RADIUS*math.sqrt(PRandom(w))*0.8
		OrderImpactBurst(
			w,
			WorldWrapPosition(x+math.cos(angle)*distance, f32(w.maxX)),
			WorldWrapPosition(y+math.sin(angle)*distance, f32(w.maxY)),
		)
	}
}

@(private = "file")
OrderNapalmFireShell :: proc(w: ^World, slot, sequence: int) {
	order, isOrder := BuildingOrderState(w, slot)
	if !isOrder do return
	centerX, centerY := OrderBuildingCenter(w, slot)
	seed := OrderEventSeed(w, slot, sequence, 0xA001)
	angle := WorldNoiseHash(slot, 0, seed)*6.2831853
	distance := math.sqrt(WorldNoiseHash(slot, 1, seed))*ORDER_NAPALM_RADIUS
	impactX := WorldWrapPosition(order.orderTargetX+math.cos(angle)*distance, f32(w.maxX))
	impactY := WorldWrapPosition(order.orderTargetY+math.sin(angle)*distance, f32(w.maxY))

	WorldProjectileBurst(w, centerX, centerY, impactX, impactY, 60, 1.6, 0.5, 1.2, 0, 0, .Boulder)
	OrderImpactBurst(w, impactX, impactY)
	WorldFireIgnite(w, impactX, impactY, 1.5, 1.15)
	for i in 0..<2 {
		jitterX := impactX+(WorldNoiseHash(slot, 2+i*2, seed)-0.5)*1.4
		jitterY := impactY+(WorldNoiseHash(slot, 3+i*2, seed)-0.5)*1.4
		WorldFireIgnite(w, jitterX, jitterY, 1.2, 1.0)
	}
}

@(private = "file")
OrderStarfallImpact :: proc(w: ^World, slot: int) {
	order, isOrder := BuildingOrderState(w, slot)
	if !isOrder do return
	kingdom := w.buildings.kingdom[slot]
	x := order.orderTargetX
	y := order.orderTargetY
	scale := 1-order.orderMitigation
	OrderAreaDamage(
		w,
		kingdom,
		x,
		y,
		ORDER_STARFALL_RADIUS,
		ORDER_STARFALL_UNIT_DAMAGE*scale,
		ORDER_STARFALL_BUILDING_DAMAGE*scale,
		OrderEventSeed(w, slot, 0, 0x57A2),
	)
	for _ in 0..<6 {
		OrderImpactBurst(w, x, y)
	}
	DecorationBlastBurst(w, x, y, ORDER_STARFALL_RADIUS*0.7)
	seed := OrderEventSeed(w, slot, 0, 0x57A2)
	for i in 0..<10 {
		angle := WorldNoiseHash(slot, i*2, seed)*6.2831853
		distance := ORDER_STARFALL_RADIUS*math.sqrt(WorldNoiseHash(slot, i*2+1, seed))*0.75
		WorldFireIgnite(
			w,
			WorldWrapPosition(x+math.cos(angle)*distance, f32(w.maxX)),
			WorldWrapPosition(y+math.sin(angle)*distance, f32(w.maxY)),
			1.6,
			1.2,
		)
	}
}

@(private = "file")
OrderMortarFireShell :: proc(w: ^World, slot, sequence: int) {
	order, isOrder := BuildingOrderState(w, slot)
	if !isOrder do return
	centerX, centerY := OrderBuildingCenter(w, slot)
	targetX := order.orderTargetX
	targetY := order.orderTargetY
	seed := OrderEventSeed(w, slot, sequence, 0xB047)
	angle := WorldNoiseHash(slot, 0, seed)*6.2831853
	distance := math.sqrt(WorldNoiseHash(slot, 1, seed))*ORDER_MORTAR_SPREAD_RADIUS
	impactX := WorldWrapPosition(targetX+math.cos(angle)*distance, f32(w.maxX))
	impactY := WorldWrapPosition(targetY+math.sin(angle)*distance, f32(w.maxY))

	WorldProjectileBurst(w, centerX, centerY, impactX, impactY, 55, 1.4, 0.55, 1.2, 0, 0, .Boulder)
	OrderImpactBurst(w, impactX, impactY)
	scale := 1-order.orderMitigation
	OrderAreaDamage(
		w,
		w.buildings.kingdom[slot],
		impactX,
		impactY,
		ORDER_MORTAR_BLAST_RADIUS,
		ORDER_MORTAR_UNIT_DAMAGE*scale,
		ORDER_MORTAR_BUILDING_DAMAGE*scale,
		seed,
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
	eventSeed: u64,
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
						OrderDamageBuilding(w, slot, buildingDamage, impactX, impactY, attackerKingdom, eventSeed)
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
	eventSeed: u64,
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
	ignitionSeed := eventSeed ~ 0xD357A0 ~ u64(building.y)*0x9E3779B97F4A7C15
	if !BuildingImmuneToFire(kind) && WorldNoiseHash(slot, building.x, ignitionSeed) < 0.15 {
		WorldFireIgnite(w, impactX, impactY, 1)
	}
	BuildingSpawnDebris(w, slot, wasBurning)
	BuildingDestroyedBurst(w, slot)
	BuildingDespawn(w, slot, attackerKingdom)
}
