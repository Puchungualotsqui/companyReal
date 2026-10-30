package main

import "core:math"
import "core:sync"
import "core:testing"


OrderTestSpawn :: proc(w: ^World, kind: BuildingType, kingdom: int) -> (int, bool) {
	for x in 0..<int(w.maxX)-8 {
		for y in 0..<int(w.maxY)-8 {
			if slot, ok := BuildingSpawn(w, x, y, kind, kingdom, 0); ok do return slot, true
		}
	}
	return 0, false
}

OrderTestSeed :: proc(w: ^World, slot, sequence: int, domain: u64) -> u64 {
	return w.seed ~ w.simulationTick*0x9E3779B97F4A7C15 ~
		u64(slot+1)*0xBF58476D1CE4E5B9 ~ u64(sequence+1)*0x94D049BB133111EB ~ domain
}

OrderTestRun :: proc(t: ^testing.T, kind: OrderKind, visualDraws: int, tick: u64, catchUp: bool) -> (u64, int, u64, bool) {
	w := new(World)
	defer free(w)
	defer WorldDeinit(w)
	defer AStarScratchDeinit()
	settings := WorldGenerationSettingsDefault()
	settings.seed = 1
	if !WorldInit(w, 128, 128, 2, settings) do return 0, 0, 0, false
	w.simulationTick = tick
	w.kingdoms[0].kingdomWar[1] = true
	w.kingdoms[1].kingdomWar[0] = true

	sourceType: BuildingOrderType
	switch kind {
	case .GiantMortar: sourceType = GiantMortar{}
	case .NapalmBarrage: sourceType = FireworksGuild{}
	case .Starfall: sourceType = StarfallSpire{}
	case .Blockade, .GlacierShell, .SiegeTremor, .WaterBomber, .MiasmaBarrage:
		return 0, 0, 0, false
	}
	source, sourceOk := OrderTestSpawn(w, BuildingOrder{type = sourceType, orderKind = kind}, 0)
	victim, victimOk := OrderTestSpawn(w, Home{}, 1)
	if !sourceOk || !victimOk do return 0, 0, 0, false
	order, ok := BuildingOrderState(w, source)
	if !ok do return 0, 0, 0, false
	x := f32(w.buildings.x[victim])+0.5
	y := f32(w.buildings.y[victim])+0.5
	order.orderTargetX = x
	order.orderTargetY = y
	if kind == .GiantMortar {
		seed := OrderTestSeed(w, source, 0, 0xB047)
		angle := WorldNoiseHash(source, 0, seed)*6.2831853
		distance := math.sqrt(WorldNoiseHash(source, 1, seed))*ORDER_MORTAR_SPREAD_RADIUS
		order.orderTargetX = WorldWrapPosition(x-math.cos(angle)*distance, f32(w.maxX))
		order.orderTargetY = WorldWrapPosition(y-math.sin(angle)*distance, f32(w.maxY))
	}
	// Make ignition deterministic and possible throughout the target area.
	for tx in 0..<int(w.maxX) {
		for ty in 0..<int(w.maxY) do w.ground[tx][ty].type = .Grassland
	}
	w.buildings.health[victim] = 1
	for _ in 0..<visualDraws do _ = PRandom(w)
	initialVisual := w.particleRandom
	switch kind {
	case .GiantMortar:
		order.orderActive = ORDER_MORTAR_DURATION
		BuildingUpdateGiantMortar(w, source, 0)
		testing.expect(t, !w.buildingUsed[victim], "mortar must destroy its target")
	case .NapalmBarrage:
		order.orderActive = ORDER_NAPALM_DURATION
		dt: f32 = 0
		if catchUp do dt = ORDER_NAPALM_TICK
		BuildingUpdateNapalm(w, source, dt)
		testing.expect(t, w.fireCount > 0, "napalm must ignite fire")
	case .Starfall:
		order.orderPending = true
		BuildingUpdateOrder(w, source, 0)
		testing.expect(t, !w.buildingUsed[victim], "starfall must destroy its target")
		testing.expect(t, w.fireCount > 0, "starfall must ignite fire")
	case .Blockade, .GlacierShell, .SiegeTremor, .WaterBomber, .MiasmaBarrage:
	}
	testing.expect(t, w.particleRandom != initialVisual, "order should consume visual randomness")
	layout: u64
	for slot in 0..<FIRE_CAPACITY {
		if w.fireUsed[slot] {
			layout = layout*0x100000001b3 ~ u64(int(w.fires.x[slot])*int(w.maxY)+int(w.fires.y[slot])+1)
		}
	}
	return WorldStateHash(w), w.fireCount, layout, true
}

@(test)
OrderRandomVisualIndependence :: proc(t: ^testing.T) {
	sync.guard(&simulationTestMutex)
	if !testing.expect(t, !ParallelAvailable(), "requires serial execution without ParallelInit") do return
	kinds := [3]OrderKind{.GiantMortar, .NapalmBarrage, .Starfall}
	for kind in kinds {
		first, firstFires, firstLayout, ok1 := OrderTestRun(t, kind, 0, 23, true)
		second, secondFires, secondLayout, ok2 := OrderTestRun(t, kind, 137, 23, true)
		testing.expectf(t, ok1 && ok2, "fixture failed for %v", kind)
		if ok1 && ok2 {
			testing.expectf(t, first == second, "gameplay hash differs for %v", kind)
			testing.expectf(t, firstFires == secondFires && firstLayout == secondLayout, "fire layout differs for %v", kind)
		}
	}
}

@(test)
OrderRandomEventIndexAndTick :: proc(t: ^testing.T) {
	sync.guard(&simulationTestMutex)
	if !testing.expect(t, !ParallelAvailable(), "requires serial execution without ParallelInit") do return
	one, oneFires, oneLayout, ok1 := OrderTestRun(t, .NapalmBarrage, 0, 23, false)
	two, twoFires, _, ok2 := OrderTestRun(t, .NapalmBarrage, 0, 23, true)
	later, _, laterLayout, ok3 := OrderTestRun(t, .NapalmBarrage, 0, 24, false)
	testing.expect(t, ok1 && ok2 && ok3, "napalm fixtures failed")
	if ok1 && ok2 && ok3 {
		testing.expect(t, twoFires > oneFires, "catch-up event should ignite distinct tiles")
		testing.expect(t, one != two && one != later, "event index and tick should change gameplay state")
		testing.expect(t, oneLayout != laterLayout, "different ticks should ignite different tiles")
	}
}
