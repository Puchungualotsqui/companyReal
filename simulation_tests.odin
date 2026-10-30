package main

import "core:math"
import "core:sync"
import "core:testing"

simulationTestMutex: sync.Mutex

WorldSoloTimingAndSingleTick :: proc(t: ^testing.T) {
	w := new(World)
	defer free(w)
	defer WorldDeinit(w)
	defer AStarScratchDeinit()

	settings := WorldGenerationSettingsDefault()
	settings.seed = 1
	ok := WorldInit(w, 128, 128, 1, settings)
	testing.expect(t, ok, "seeded world initialization failed")
	if !ok do return

	initialDayTime := w.dayTime
	w.particleUsed[0] = true
	w.particleCount = 1
	w.particles[0] = Particle{life = 10, maxLife = 10, settled = true}

	WorldUpdate(w, 0)
	WorldUpdate(w, -1)
	testing.expect(t, w.simulationTick == 0)
	testing.expect(t, w.simulationTime == 0 && w.simulationAccumulator == 0)
	testing.expect(t, w.dayTime == initialDayTime && w.particles.life[0] == 10)

	WorldUpdate(w, TOWN_SIMULATION_STEP/4)
	testing.expect(t, w.simulationTick == 0 && w.simulationTime == 0)
	testing.expect(t, w.simulationAccumulator == TOWN_SIMULATION_STEP/4)
	testing.expect(t, w.dayTime == initialDayTime)
	testing.expect(t, math.abs(w.particles.life[0]-(10-PARTICLE_MAX_FRAME_STEP)) < 0.00001)

	WorldUpdate(w, TOWN_SIMULATION_STEP*3/4)
	testing.expect(t, w.simulationTick == 1)
	testing.expect(t, w.simulationTime == TOWN_SIMULATION_STEP)
	testing.expect(t, w.simulationAccumulator == 0)
	testing.expect(t, w.dayTime == initialDayTime+TOWN_SIMULATION_STEP)

	WorldUpdate(w, TOWN_SIMULATION_STEP/4)
	WorldUpdate(w, WORLD_MAX_FRAME_DELTA*100)
	testing.expect(t, w.simulationTick == 2)
	testing.expect(t, w.simulationTime == TOWN_SIMULATION_STEP*2)
	testing.expect(t, w.simulationAccumulator == TOWN_SIMULATION_STEP/4)
	testing.expect(t, w.dayTime == initialDayTime+TOWN_SIMULATION_STEP*2)

	w.dayTime = f32(WORLD_DAY_LENGTH_SECONDS)-TOWN_SIMULATION_STEP
	w.dayNumber = 7
	minorTimer := w.eventMinorTimer
	particleLife := w.particles.life[0]
	WorldTick(w)
	testing.expect(t, w.simulationTick == 3)
	testing.expect(t, w.simulationTime == TOWN_SIMULATION_STEP*3)
	testing.expect(t, w.simulationAccumulator == TOWN_SIMULATION_STEP/4)
	testing.expect(t, w.dayTime == 0 && w.dayNumber == 8)
	testing.expect(t, w.eventMinorTimer == minorTimer-TOWN_SIMULATION_STEP)
	testing.expect(t, w.particles.life[0] == particleLife)
}

ScriptedKingdomCommand :: struct {
	kingdom: int,
	command: KingdomCommand,
}

WorldSeededHashSequence :: proc(t: ^testing.T) -> (hashes: [17]u64, ok: bool) {
	w := new(World)
	defer free(w)
	defer WorldDeinit(w)
	defer AStarScratchDeinit()

	settings := WorldGenerationSettingsDefault()
	settings.seed = 1
	if !WorldInit(w, 128, 128, 2, settings) do return {}, false
	if !WorldTownExists(w, 0, 0) || !WorldTownExists(w, 1, 0) do return {}, false
	w.controllers[0].kind = .Human
	w.controllers[1].kind = .Human
	KingdomMeet(w, 0, 1)

	// Each entry is issued immediately before the tick at the same index.
	commands := [16][]ScriptedKingdomCommand {
		0 = {{0, CommandDefendTown{town = 0, targetKingdom = 1, targetTown = 0}}},
		2 = {{1, CommandDeclareWar{other = 0}}},
		3 = {{0, CommandAttackTown{town = 0, targetKingdom = 1, targetTown = 0}}},
		5 = {{1, CommandAttackTown{town = 0, targetKingdom = 0, targetTown = 0}}},
		8 = {{0, CommandStopAttack{town = 0, targetKingdom = 1, targetTown = 0}}},
		10 = {{1, CommandMakePeace{other = 0}}},
		12 = {{1, CommandDefendTown{town = 0, targetKingdom = 0, targetTown = 0}}},
		14 = {{1, CommandStopDefend{town = 0, targetKingdom = 0, targetTown = 0}}},
	}
	hashes[0] = WorldStateHash(w)
	for tick in 0..<len(commands) {
		for entry in commands[tick] {
			if !KingdomIssueCommand(w, entry.kingdom, entry.command) {
				testing.expectf(t, false, "command failed at tick %d for kingdom %d", tick, entry.kingdom)
				return {}, false
			}
		}
		switch tick {
		case 0: testing.expect(t, w.kingdoms[0].towns[0].defendOrders[1][0])
		case 2: testing.expect(t, KingdomAtWar(w, 0, 1) && !w.kingdoms[0].towns[0].defendOrders[1][0])
		case 3: testing.expect(t, w.kingdoms[0].towns[0].attackOrders[1][0])
		case 5: testing.expect(t, w.kingdoms[1].towns[0].attackOrders[0][0])
		case 8: testing.expect(t, !w.kingdoms[0].towns[0].attackOrders[1][0])
		case 10: testing.expect(t, !KingdomAtWar(w, 0, 1))
		case 12: testing.expect(t, w.kingdoms[1].towns[0].defendOrders[0][0])
		case 14: testing.expect(t, !w.kingdoms[1].towns[0].defendOrders[0][0])
		}
		WorldTick(w)
		hashes[tick+1] = WorldStateHash(w)
	}
	return hashes, true
}

@(test)
WorldSimulationTimingAndHashSequence :: proc(t: ^testing.T) {
	sync.guard(&simulationTestMutex)
	if !testing.expect(t, !ParallelAvailable(), "simulation test requires serial execution without ParallelInit") do return
	WorldSoloTimingAndSingleTick(t)

	first, firstOk := WorldSeededHashSequence(t)
	testing.expect(t, firstOk, "first seeded world initialization failed")
	if !firstOk do return
	second, secondOk := WorldSeededHashSequence(t)
	testing.expect(t, secondOk, "second seeded world initialization failed")
	if !secondOk do return

	for index in 0..<len(first) {
		testing.expect(t, first[index] == second[index], "same-seed hash sequence differs")
		if index > 0 do testing.expect(t, first[index] != first[index-1])
	}
}
