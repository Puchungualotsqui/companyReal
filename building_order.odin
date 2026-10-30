package main

import rl "vendor:raylib"
import "core:math"
import "d32"

// Order buildings are physical sources for strategic orders. The building must
// exist and be ready; the order icon never appears on its own.
ORDER_BLOCKADE_DURATION_SECONDS :: 90
ORDER_BLOCKADE_DURATION_TICKS :: u64(ORDER_BLOCKADE_DURATION_SECONDS/TOWN_SIMULATION_STEP)
#assert(f64(ORDER_BLOCKADE_DURATION_TICKS) == ORDER_BLOCKADE_DURATION_SECONDS/TOWN_SIMULATION_STEP)

ORDER_MORTAR_RADIUS :: d32.Value(4*d32.SCALE)
ORDER_MORTAR_SPREAD_RADIUS :: d32.Value(3*d32.SCALE)
ORDER_MORTAR_BLAST_RADIUS :: d32.Value(16*d32.SCALE/10)
ORDER_MORTAR_DURATION :: 10.0
ORDER_MORTAR_COOLDOWN :: 30.0
ORDER_MORTAR_TICK :: 0.6
ORDER_MORTAR_UNIT_DAMAGE :: d32.Value(7*d32.SCALE)
ORDER_MORTAR_BUILDING_DAMAGE :: d32.Value(20*d32.SCALE)

ORDER_GLACIER_RADIUS :: d32.Value(4*d32.SCALE)
ORDER_GLACIER_COOLDOWN :: 150.0

ORDER_TREMOR_RADIUS :: d32.Value(45*d32.SCALE/10)
ORDER_TREMOR_DURATION :: 4.0
ORDER_TREMOR_TICK :: 0.7
ORDER_TREMOR_UNIT_DAMAGE :: d32.Value(6*d32.SCALE)
ORDER_TREMOR_BUILDING_DAMAGE :: d32.Value(55*d32.SCALE)
ORDER_TREMOR_COOLDOWN :: 120.0

ORDER_STARFALL_RADIUS :: d32.Value(55*d32.SCALE/10)
ORDER_STARFALL_UNIT_DAMAGE :: d32.Value(120*d32.SCALE)
ORDER_STARFALL_BUILDING_DAMAGE :: d32.Value(350*d32.SCALE)
ORDER_STARFALL_COOLDOWN :: 240.0

ORDER_FLOOD_RADIUS :: d32.Value(4*d32.SCALE)
ORDER_FLOOD_COOLDOWN :: 150.0

ORDER_MIASMA_RADIUS :: d32.Value(35*d32.SCALE/10)
ORDER_MIASMA_DURATION :: 18.0
ORDER_MIASMA_COOLDOWN :: 180.0

ORDER_NAPALM_RADIUS :: d32.Value(5*d32.SCALE)
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

OrderRadius :: proc(kind: OrderKind) -> d32.Value {
	switch kind {
	case .GiantMortar:
		return ORDER_MORTAR_RADIUS
	case .Blockade:
		return d32.ZERO
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

OrderDuration :: proc(kind: OrderKind) -> d32.Value {
	switch kind {
	case .GiantMortar:
		return d32.FromInt(i32(ORDER_MORTAR_DURATION))
	case .Blockade, .GlacierShell, .WaterBomber, .MiasmaBarrage:
		return d32.ZERO
	case .SiegeTremor:
		return d32.FromInt(i32(ORDER_TREMOR_DURATION))
	case .Starfall:
		return d32.ZERO
	case .NapalmBarrage:
		return d32.FromInt(i32(ORDER_NAPALM_DURATION))
	}
	unreachable()
}

OrderTelegraph :: proc(kind: OrderKind) -> d32.Value {
	switch kind {
	case .GiantMortar:
		return d32.FromRatio(i32(ORDER_MORTAR_TELEGRAPH*10), 10)
	case .Blockade:
		return d32.ZERO
	case .GlacierShell:
		return d32.FromRatio(i32(ORDER_GLACIER_TELEGRAPH*10), 10)
	case .SiegeTremor:
		return d32.FromRatio(i32(ORDER_TREMOR_TELEGRAPH*10), 10)
	case .Starfall:
		return d32.FromRatio(i32(ORDER_STARFALL_TELEGRAPH*10), 10)
	case .WaterBomber:
		return d32.FromRatio(i32(ORDER_FLOOD_TELEGRAPH*10), 10)
	case .MiasmaBarrage:
		return d32.FromRatio(i32(ORDER_MIASMA_TELEGRAPH*10), 10)
	case .NapalmBarrage:
		return d32.FromRatio(i32(ORDER_NAPALM_TELEGRAPH*10), 10)
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

OrderCooldownSeconds :: proc(kind: OrderKind) -> d32.Value {
	switch kind {
	case .GiantMortar:
		return d32.FromInt(i32(ORDER_MORTAR_COOLDOWN))
	case .Blockade:
		return d32.FromInt(180)
	case .GlacierShell:
		return d32.FromInt(i32(ORDER_GLACIER_COOLDOWN))
	case .SiegeTremor:
		return d32.FromInt(i32(ORDER_TREMOR_COOLDOWN))
	case .Starfall:
		return d32.FromInt(i32(ORDER_STARFALL_COOLDOWN))
	case .WaterBomber:
		return d32.FromInt(i32(ORDER_FLOOD_COOLDOWN))
	case .MiasmaBarrage:
		return d32.FromInt(i32(ORDER_MIASMA_COOLDOWN))
	case .NapalmBarrage:
		return d32.FromInt(i32(ORDER_NAPALM_COOLDOWN))
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

// Building center in Q16.16 raw units.
OrderBuildingCenterRaw :: proc(w: ^World, slot: int) -> (x, y: d32.Value) {
	width, height := BuildingTileSize(w.buildings[slot].type)
	return d32.FromRaw(i32(i64(w.buildings.x[slot])*d32.SCALE+i64(width)*(d32.SCALE/2))),
		d32.FromRaw(i32(i64(w.buildings.y[slot])*d32.SCALE+i64(height)*(d32.SCALE/2)))
}

OrderSourceNearestReady :: proc(w: ^World, kingdom: int, kind: OrderKind, targetX, targetY: d32.Value) -> int {
	if !OrderUnlocked(w, kingdom, kind) do return -1
	worldWidthRaw := i64(w.maxX)*d32.SCALE
	worldHeightRaw := i64(w.maxY)*d32.SCALE
	best := -1
	bestDistance: u64 = 0
	for slot in 0..<BUILDING_CAPACITY {
		if !w.buildingUsed[slot] || w.buildings.kingdom[slot] != kingdom do continue
		if !BuildingOrderSupports(BuildingKindOf(w.buildings.type[slot]), kind) do continue
		order, isOrder := BuildingOrderState(w, slot)
		if !isOrder do continue
		if order.orderCooldown > d32.ZERO || order.orderActive > d32.ZERO do continue

		centerX, centerY := OrderBuildingCenterRaw(w, slot)
		distance, validDistance := d32.WrappedDistanceSquared(
			centerX,
			centerY,
			targetX,
			targetY,
			worldWidthRaw,
			worldHeightRaw,
		)
		assert(validDistance)
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
		if isOrder && order.orderCooldown <= d32.ZERO && order.orderActive <= d32.ZERO {
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
		if isOrder && (order.orderActive > d32.ZERO || order.orderTelegraph > d32.ZERO) do count += 1
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
		remaining = max(remaining, PositionToF32(order.orderTelegraph))
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
		if isOrder do remaining = max(remaining, PositionToF32(order.orderActive))
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
		if remaining <= d32.ZERO do continue
		value := PositionToF32(remaining)
		if next < 0 || value < next do next = value
	}
	return max(next, 0)
}

TownAtPoint :: proc(w: ^World, x, y: d32.Value) -> (kingdom, town: int, found: bool) {
	tileX := PositionTile(x, int(w.maxX))
	tileY := PositionTile(y, int(w.maxY))
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
OrderTargetValid :: proc(w: ^World, kingdom: int, kind: OrderKind, x, y: d32.Value) -> bool {
	if !OrderUnlocked(w, kingdom, kind) do return false
	switch kind {
	case .GiantMortar, .GlacierShell, .SiegeTremor, .Starfall, .WaterBomber, .MiasmaBarrage, .NapalmBarrage:
		if kingdom == w.observerKingdom {
			tileX := PositionTile(x, int(w.maxX))
			tileY := PositionTile(y, int(w.maxY))
			if !FogTileExplored(w, tileX, tileY) do return false
		}
		return true
	case .Blockade:
		if kingdom == w.observerKingdom {
			tileX := PositionTile(x, int(w.maxX))
			tileY := PositionTile(y, int(w.maxY))
			if !FogTileExplored(w, tileX, tileY) do return false
		}
		targetKingdom, targetTown, found := TownAtPoint(w, x, y)
		if !found || targetKingdom == kingdom do return false
		if !KingdomAtWar(w, kingdom, targetKingdom) do return false
		if !TownIsCoastal(w, targetKingdom, targetTown) do return false
		if w.kingdoms[targetKingdom].towns[targetTown].blockadeUntilTick > WorldCurrentTick(w) {
			return false
		}
		return true
	}
	return false
}

OrderStart :: proc(w: ^World, kingdom: int, kind: OrderKind, x, y: d32.Value) -> bool {
	if !OrderTargetValid(w, kingdom, kind, x, y) do return false
	slot := OrderSourceNearestReady(w, kingdom, kind, x, y)
	if slot < 0 do return false
	order, isOrder := BuildingOrderState(w, slot)
	if !isOrder do return false

	targetX, _ := d32.WrapRaw(i64(d32.Raw(x)), d32.ZERO, i64(w.maxX)*d32.SCALE)
	targetY, _ := d32.WrapRaw(i64(d32.Raw(y)), d32.ZERO, i64(w.maxY)*d32.SCALE)
	order.orderKind = kind
	order.orderTargetX = targetX
	order.orderTargetY = targetY
	order.orderActive = d32.ZERO
	order.orderTick = d32.ZERO
	order.orderMitigation = d32.ZERO
	order.orderTelegraph = d32.ZERO
	order.orderPending = false

	if kind == .Blockade {
		targetKingdom, targetTown, found := TownAtPoint(w, x, y)
		if !found do return false
		target := &w.kingdoms[targetKingdom].towns[targetTown]
		target.blockadeUntilTick = WorldCurrentTick(w)+ORDER_BLOCKADE_DURATION_TICKS
		target.blockadeBy = kingdom
		order.orderCooldown = OrderCooldownSeconds(kind)
		order.orderTargetX, _ = d32.WrapRaw(
			i64(target.x+2)*d32.SCALE,
			d32.ZERO,
			i64(w.maxX)*d32.SCALE,
		)
		order.orderTargetY, _ = d32.WrapRaw(
			i64(target.y+2)*d32.SCALE,
			d32.ZERO,
			i64(w.maxY)*d32.SCALE,
		)
		return true
	}

	order.orderTelegraph = OrderTelegraph(kind)
	order.orderPending = order.orderTelegraph > d32.ZERO
	order.orderCooldown = d32.Add(
		d32.Add(order.orderTelegraph, OrderDuration(kind)),
		OrderCooldownSeconds(kind),
	)
	if kind == .Starfall {
		ParticleSpawn(w, Particle{
			x = PositionToF32(order.orderTargetX),
			y = PositionToF32(order.orderTargetY),
			z = 18,
			vx = 0,
			vy = 0,
			vz = -9.5,
			life = PositionToF32(order.orderTelegraph),
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
		order.orderMitigation = PositionFromF32(TownAegisAbsorb(
			w,
			targetKingdom,
			targetTown,
			OrderWardCost(order.orderKind),
			PositionToF32(order.orderTargetX),
			PositionToF32(order.orderTargetY),
		))
	}

	switch order.orderKind {
	case .GiantMortar:
		order.orderActive = d32.FromInt(i32(ORDER_MORTAR_DURATION))
		order.orderTick = d32.ZERO
	case .GlacierShell:
		scale := 1-PositionToF32(order.orderMitigation)*0.6
		WorldHazardSpawnCircle(
			w,
			PositionToF32(order.orderTargetX),
			PositionToF32(order.orderTargetY),
			PositionToF32(ORDER_GLACIER_RADIUS)*scale,
			.Ice,
			14*scale,
			24*scale,
			0x1CE,
		)
	case .SiegeTremor:
		order.orderActive = d32.FromInt(i32(ORDER_TREMOR_DURATION))
		order.orderTick = d32.ZERO
	case .Starfall:
		OrderStarfallImpact(w, slot)
	case .WaterBomber:
		scale := 1-PositionToF32(order.orderMitigation)*0.6
		WorldHazardSpawnCircle(
			w,
			PositionToF32(order.orderTargetX),
			PositionToF32(order.orderTargetY),
			PositionToF32(ORDER_FLOOD_RADIUS)*scale,
			.Flood,
			9*scale,
			17*scale,
			0xF100,
		)
	case .MiasmaBarrage:
		scale := 1-PositionToF32(order.orderMitigation)*0.6
		WorldGasCloudSpawn(
			w,
			PositionToF32(order.orderTargetX),
			PositionToF32(order.orderTargetY),
			PositionToF32(ORDER_MIASMA_RADIUS)*scale,
			ORDER_MIASMA_DURATION*scale,
		)
	case .NapalmBarrage:
		scale := d32.Sub(d32.ONE, d32.Mul(order.orderMitigation, d32.FromRatio(3, 5)))
		order.orderActive = d32.Mul(d32.FromInt(i32(ORDER_NAPALM_DURATION)), scale)
		order.orderTick = d32.ZERO
	case .Blockade:
	}
}

BuildingUpdateOrder :: proc(w: ^World, slot: int, deltaTime: f32) {
	order, isOrder := BuildingOrderState(w, slot)
	if !isOrder do return
	step := PositionFromF32(deltaTime)
	if order.orderCooldown > d32.ZERO {
		order.orderCooldown = max(d32.Sub(order.orderCooldown, step), d32.ZERO)
	}
	if order.orderPending {
		order.orderTelegraph = max(d32.Sub(order.orderTelegraph, step), d32.ZERO)
		if order.orderTelegraph > d32.ZERO do return
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
	if order.orderActive <= d32.ZERO do return

	step := PositionFromF32(deltaTime)
	order.orderActive = max(d32.Sub(order.orderActive, step), d32.ZERO)
	order.orderTick = d32.Sub(order.orderTick, step)
	sequence := 0
	for order.orderTick <= d32.ZERO {
		OrderMortarFireShell(w, slot, sequence)
		sequence += 1
		order.orderTick = d32.Add(
			order.orderTick,
			d32.FromRatio(i32(ORDER_MORTAR_TICK*10), 10),
		)
		if _, stillUsed := BuildingOrderState(w, slot); !stillUsed do return
	}
	if order.orderActive <= d32.ZERO {
		order.orderActive = d32.ZERO
		order.orderTick = d32.ZERO
	}
}

BuildingUpdateSiegeTremor :: proc(w: ^World, slot: int, deltaTime: f32) {
	order, isOrder := BuildingOrderState(w, slot)
	if !isOrder do return
	if order.orderActive <= d32.ZERO do return

	step := PositionFromF32(deltaTime)
	order.orderActive = max(d32.Sub(order.orderActive, step), d32.ZERO)
	order.orderTick = d32.Sub(order.orderTick, step)
	sequence := 0
	for order.orderTick <= d32.ZERO {
		OrderTremorPulse(w, slot, sequence)
		sequence += 1
		order.orderTick = d32.Add(
			order.orderTick,
			d32.FromRatio(i32(ORDER_TREMOR_TICK*10), 10),
		)
		if _, stillUsed := BuildingOrderState(w, slot); !stillUsed do return
	}
	if order.orderActive <= d32.ZERO {
		order.orderActive = d32.ZERO
		order.orderTick = d32.ZERO
	}
}

BuildingUpdateNapalm :: proc(w: ^World, slot: int, deltaTime: f32) {
	order, isOrder := BuildingOrderState(w, slot)
	if !isOrder do return
	if order.orderActive <= d32.ZERO do return

	step := PositionFromF32(deltaTime)
	order.orderActive = max(d32.Sub(order.orderActive, step), d32.ZERO)
	order.orderTick = d32.Sub(order.orderTick, step)
	sequence := 0
	for order.orderTick <= d32.ZERO {
		OrderNapalmFireShell(w, slot, sequence)
		sequence += 1
		order.orderTick = d32.Add(
			order.orderTick,
			d32.FromRatio(i32(ORDER_NAPALM_TICK*10), 10),
		)
		if _, stillUsed := BuildingOrderState(w, slot); !stillUsed do return
	}
	if order.orderActive <= d32.ZERO {
		order.orderActive = d32.ZERO
		order.orderTick = d32.ZERO
	}
}

BuildingUpdateStarfall :: proc(w: ^World, slot: int, deltaTime: f32) {
	order, isOrder := BuildingOrderState(w, slot)
	if !isOrder do return
	if order.orderActive <= d32.ZERO do return

	step := PositionFromF32(deltaTime)
	order.orderActive = max(d32.Sub(order.orderActive, step), d32.ZERO)
	order.orderTick = d32.Sub(order.orderTick, step)
	if order.orderTick > d32.ZERO do return

	OrderStarfallImpact(w, slot)
	order.orderActive = d32.ZERO
	order.orderTick = d32.ZERO
}

@(private = "file")
OrderRandomOffset :: proc(slot, index: int, seed: u64, radius: d32.Value) -> (d32.Value, d32.Value) {
	turns := d32.FromRatio(i32(WorldNoiseHashInt(slot, index, seed)), 1_000_000)
	radiusFraction := d32.FromRatio(i32(WorldNoiseHashInt(slot, index+1, seed)), 1_000_000)
	sine, cosine := d32.SinCos(turns)
	distance := d32.Mul(d32.Sqrt(radiusFraction), radius)
	return d32.Mul(cosine, distance), d32.Mul(sine, distance)
}

// Sequence distinguishes catch-up events emitted by one source in the same tick.
@(private = "file")
OrderEventSeed :: proc(w: ^World, slot, sequence: int, domain: u64) -> u64 {
	return w.seed ~ w.simulationTick*0x9E3779B97F4A7C15 ~
		u64(slot+1)*0xBF58476D1CE4E5B9 ~ u64(sequence+1)*0x94D049BB133111EB ~ domain
}

@(private = "file")
OrderWrappedAdd :: proc(position, offset: d32.Value, size: i64) -> d32.Value {
	wrapped, _ := d32.WrapRaw(i64(d32.Raw(d32.Add(position, offset))), d32.ZERO, size)
	return wrapped
}

@(private = "file")
OrderTremorPulse :: proc(w: ^World, slot, sequence: int) {
	order, isOrder := BuildingOrderState(w, slot)
	if !isOrder do return
	kingdom := w.buildings.kingdom[slot]
	x := order.orderTargetX
	y := order.orderTargetY
	scale := d32.Sub(d32.ONE, order.orderMitigation)
	OrderAreaDamage(
		w,
		kingdom,
		x,
		y,
		ORDER_TREMOR_RADIUS,
		d32.Mul(ORDER_TREMOR_UNIT_DAMAGE, scale),
		d32.Mul(ORDER_TREMOR_BUILDING_DAMAGE, scale),
		OrderEventSeed(w, slot, sequence, 0x7E00),
	)
	effectX := PositionToF32(x)
	effectY := PositionToF32(y)
	OrderImpactBurst(w, effectX, effectY)
	for _ in 0..<3 {
		angle := PRandom(w)*6.2831853
		distance := PositionToF32(ORDER_TREMOR_RADIUS)*math.sqrt(PRandom(w))*0.8
		OrderImpactBurst(
			w,
			WorldWrapPosition(effectX+math.cos(angle)*distance, f32(w.maxX)),
			WorldWrapPosition(effectY+math.sin(angle)*distance, f32(w.maxY)),
		)
	}
}

@(private = "file")
OrderNapalmFireShell :: proc(w: ^World, slot, sequence: int) {
	order, isOrder := BuildingOrderState(w, slot)
	if !isOrder do return
	centerX, centerY := OrderBuildingCenter(w, slot)
	seed := OrderEventSeed(w, slot, sequence, 0xA001)
	offsetX, offsetY := OrderRandomOffset(slot, 0, seed, ORDER_NAPALM_RADIUS)
	impactX := OrderWrappedAdd(order.orderTargetX, offsetX, i64(w.maxX)*d32.SCALE)
	impactY := OrderWrappedAdd(order.orderTargetY, offsetY, i64(w.maxY)*d32.SCALE)
	effectX := PositionToF32(impactX)
	effectY := PositionToF32(impactY)

	WorldProjectileBurst(w, centerX, centerY, effectX, effectY, 60, 1.6, 0.5, 1.2, 0, 0, .Boulder)
	OrderImpactBurst(w, effectX, effectY)
	WorldFireIgnite(w, effectX, effectY, 1.5, 1.15)
	for i in 0..<2 {
		jitterOffsetX := d32.FromRatio((i32(WorldNoiseHashInt(slot, 2+i*2, seed))-500_000)*7, 5_000_000)
		jitterOffsetY := d32.FromRatio((i32(WorldNoiseHashInt(slot, 3+i*2, seed))-500_000)*7, 5_000_000)
		jitterX := PositionToF32(d32.Add(impactX, jitterOffsetX))
		jitterY := PositionToF32(d32.Add(impactY, jitterOffsetY))
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
	scale := d32.Sub(d32.ONE, order.orderMitigation)
	OrderAreaDamage(
		w,
		kingdom,
		x,
		y,
		ORDER_STARFALL_RADIUS,
		d32.Mul(ORDER_STARFALL_UNIT_DAMAGE, scale),
		d32.Mul(ORDER_STARFALL_BUILDING_DAMAGE, scale),
		OrderEventSeed(w, slot, 0, 0x57A2),
	)
	effectX := PositionToF32(x)
	effectY := PositionToF32(y)
	for _ in 0..<6 {
		OrderImpactBurst(w, effectX, effectY)
	}
	DecorationBlastBurst(w, effectX, effectY, PositionToF32(ORDER_STARFALL_RADIUS)*0.7)
	seed := OrderEventSeed(w, slot, 0, 0x57A2)
	for i in 0..<10 {
		offsetX, offsetY := OrderRandomOffset(
			slot,
			i*2,
			seed,
			d32.Mul(ORDER_STARFALL_RADIUS, d32.FromRatio(6, 8)),
		)
		WorldFireIgnite(
			w,
			PositionToF32(OrderWrappedAdd(x, offsetX, i64(w.maxX)*d32.SCALE)),
			PositionToF32(OrderWrappedAdd(y, offsetY, i64(w.maxY)*d32.SCALE)),
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
	offsetX, offsetY := OrderRandomOffset(slot, 0, seed, ORDER_MORTAR_SPREAD_RADIUS)
	impactX := OrderWrappedAdd(targetX, offsetX, i64(w.maxX)*d32.SCALE)
	impactY := OrderWrappedAdd(targetY, offsetY, i64(w.maxY)*d32.SCALE)
	effectX := PositionToF32(impactX)
	effectY := PositionToF32(impactY)

	WorldProjectileBurst(w, centerX, centerY, effectX, effectY, 55, 1.4, 0.55, 1.2, 0, 0, .Boulder)
	OrderImpactBurst(w, effectX, effectY)
	scale := d32.Sub(d32.ONE, order.orderMitigation)
	OrderAreaDamage(
		w,
		w.buildings.kingdom[slot],
		impactX,
		impactY,
		ORDER_MORTAR_BLAST_RADIUS,
		d32.Mul(ORDER_MORTAR_UNIT_DAMAGE, scale),
		d32.Mul(ORDER_MORTAR_BUILDING_DAMAGE, scale),
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
	x, y: d32.Value,
	radius: d32.Value,
	unitDamage, buildingDamage: d32.Value,
	eventSeed: u64,
) {
	chunkSize := w.spatial.chunkSize
	if chunkSize <= 0 do return
	worldWidthRaw := i64(w.maxX)*d32.SCALE
	worldHeightRaw := i64(w.maxY)*d32.SCALE
	centerPositionX, validX := d32.WrapRaw(i64(d32.Raw(x)), d32.ZERO, worldWidthRaw)
	centerPositionY, validY := d32.WrapRaw(i64(d32.Raw(y)), d32.ZERO, worldHeightRaw)
	if !validX || !validY do return
	// Raw distance tests; f32 only crosses the effect and building-query bounds.
	centerX := PositionToF32(centerPositionX)
	centerY := PositionToF32(centerPositionY)
	radiusRaw := i64(d32.Raw(radius))
	radiusSquaredRaw := u64(radiusRaw)*u64(radiusRaw)

	centerChunkX := int(d32.ToInt(centerPositionX))/chunkSize
	centerChunkY := int(d32.ToInt(centerPositionY))/chunkSize
	chunkRadius := int(d32.ToInt(radius))/chunkSize+1
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
					distanceSquared, validDistance := d32.WrappedDistanceSquared(
						w.units.x[slot],
						w.units.y[slot],
						centerPositionX,
						centerPositionY,
						worldWidthRaw,
						worldHeightRaw,
					)
					if validDistance && distanceSquared <= radiusSquaredRaw {
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
					distanceSquared, impactX, impactY := WarriorBuildingNearestPointSquared(w, centerX, centerY, slot)
					if distanceSquared <= radiusSquaredRaw {
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
	damage: d32.Value,
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
	building.health = d32.Sub(building.health, damage)
	if building.health > d32.ZERO do return

	wasBurning := BuildingOnFire(w, slot)
	kind := BuildingKindOf(building.type)
	ignitionSeed := eventSeed ~ 0xD357A0 ~ u64(building.y)*0x9E3779B97F4A7C15
	if !BuildingImmuneToFire(kind) && WorldNoiseHashInt(slot, building.x, ignitionSeed) < 150_000 {
		WorldFireIgnite(w, impactX, impactY, 1)
	}
	BuildingSpawnDebris(w, slot, wasBurning)
	BuildingDestroyedBurst(w, slot)
	BuildingDespawn(w, slot, attackerKingdom)
}
