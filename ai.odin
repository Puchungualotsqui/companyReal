package main

import "core:math"

// The AI is intentionally built from the same orders a human uses. It never
// touches unit state directly, so swapping in an RL policy or a network
// controller later only means producing the same KingdomCommands.

AI_DECISION_MIN :: 2.8
AI_DECISION_MAX :: 5.4
AI_DIPLOMACY_MIN :: 22
AI_DIPLOMACY_MAX :: 46
AI_EXPAND_MIN :: 9
AI_EXPAND_MAX :: 20
AI_ATTACK_GRACE_SECONDS :: 45
AI_WAR_COMMIT_SECONDS :: 75
AI_TRUCE_SECONDS :: 90

AIBrain :: struct {
	decisionTimer:     f32,
	diplomacyTimer:    f32,
	expandTimer:       f32,
	aggression:        f32,
	expansion:         f32,
	warCommitUntil:    f32,
	truceUntil:        f32,
	truceKingdom:      int,
}

AIStateInit :: proc(w: ^World, kingdom: int) {
	seed := w.seed+u64(kingdom+1)*0x9E3779B97F4A7C15
	brain := &w.controllers[kingdom].ai
	brain.aggression = WorldNoiseHash(kingdom, 3, seed)
	brain.expansion = WorldNoiseHash(kingdom, 11, seed)
	brain.decisionTimer = 0.8+WorldNoiseHash(kingdom, 17, seed)*2
	brain.diplomacyTimer = 8+WorldNoiseHash(kingdom, 19, seed)*18
	brain.expandTimer = 5+WorldNoiseHash(kingdom, 23, seed)*10
	brain.warCommitUntil = 0
	brain.truceUntil = 0
	brain.truceKingdom = -1
}

AIRandom :: proc(w: ^World, kingdom, salt: int) -> f32 {
	value := u64(kingdom)*0x9E3779B97F4A7C15 ~
		u64(salt+int(w.simulationTime*4))*0xBF58476D1CE4E5B9 ~
		(w.seed+0xA1C0DE)
	value = (value ~ (value >> 30))*0xBF58476D1CE4E5B9
	value = (value ~ (value >> 27))*0x94D049BB133111EB
	value = value ~ (value >> 31)
	return f32(value % 1_000_000)/1_000_000.0
}

AIControllerUpdate :: proc(w: ^World, kingdom: int, delta_time: f32) {
	brain := &w.controllers[kingdom].ai

	brain.decisionTimer -= delta_time
	brain.diplomacyTimer -= delta_time
	brain.expandTimer -= delta_time

	if brain.decisionTimer <= 0 {
		brain.decisionTimer = AI_DECISION_MIN+
			AIRandom(w, kingdom, 31)*(AI_DECISION_MAX-AI_DECISION_MIN)
		AIDecide(w, kingdom)
	}
	if brain.diplomacyTimer <= 0 {
		brain.diplomacyTimer = AI_DIPLOMACY_MIN+
			AIRandom(w, kingdom, 37)*(AI_DIPLOMACY_MAX-AI_DIPLOMACY_MIN)
		AIDiplomacy(w, kingdom)
	}
	if brain.expandTimer <= 0 {
		brain.expandTimer = AI_EXPAND_MIN+
			AIRandom(w, kingdom, 41)*(AI_EXPAND_MAX-AI_EXPAND_MIN)
		AIExpand(w, kingdom)
	}
}

AIDecide :: proc(w: ^World, kingdom: int) {
	counts: [TOWN_CAPACITY][UnitKind]int
	for unit_slot in 0 ..< UNIT_CAPACITY {
		if !w.unitUsed[unit_slot] || w.units[unit_slot].type == nil do continue
		if w.units[unit_slot].kingdome != kingdom do continue
		town_slot := w.units[unit_slot].town
		if town_slot < 0 || town_slot >= TOWN_CAPACITY do continue
		counts[town_slot][UnitKindOf(w.units[unit_slot].type)] += 1
	}

	brain := &w.controllers[kingdom].ai
	for town_slot in 0 ..< TOWN_CAPACITY {
		if !w.kingdoms[kingdom].townUsed[town_slot] do continue
		town := &w.kingdoms[kingdom].towns[town_slot]

		if town.milestonePending {
			option := AIChooseMilestoneOption(w, kingdom, town_slot, brain)
			KingdomIssueCommand(
				w,
				kingdom,
				CommandChooseMilestone{town = town_slot, option = option},
			)
		}

		AITownEconomy(w, kingdom, town_slot, &counts[town_slot], brain)
		AITryCombatBuilding(w, kingdom, town_slot, &counts[town_slot])
	}
}

AIKindIsWarrior :: proc(kind: UnitKind) -> bool {
	switch kind {
	case .Knight, .Archer, .Mage, .Giant, .Turtle, .Catapult, .Rogue:
		return true
	case .Villager, .Builder, .CombatBuilder, .WaterCollector, .Farmer, .Explorer:
		return false
	}
	return false
}

AIPendingTo :: proc(w: ^World, kingdom, town_slot: int, to: UnitKind) -> int {
	town := &w.kingdoms[kingdom].towns[town_slot]
	pending := 0
	for job in town.conversions {
		if job.from == .Villager && job.to == to do pending += job.remaining
	}
	return pending
}

AIPendingMilitary :: proc(w: ^World, kingdom, town_slot: int) -> int {
	town := &w.kingdoms[kingdom].towns[town_slot]
	pending := 0
	for job in town.conversions {
		if job.from == .Villager && AIKindIsWarrior(job.to) do pending += job.remaining
	}
	return pending
}

AIQueueConversion :: proc(w: ^World, kingdom, town_slot: int, kind: UnitKind) -> bool {
	if !TownUnitAvailable(w, kingdom, town_slot, kind) do return false
	return KingdomIssueCommand(
		w,
		kingdom,
		CommandQueueConversion{town = town_slot, from = .Villager, to = kind, count = 1},
	)
}

AIWaterCollectorTarget :: proc(w: ^World, kingdom, town_slot: int) -> int {
	town := &w.kingdoms[kingdom].towns[town_slot]
	collector_output := town.waterAccess*0.10
	if collector_output <= 0.001 do return 0
	need := f32(town.citizens)*0.025
	target := int(math.ceil(need/collector_output))
	return clamp(target, 1, max(1, town.citizens/4))
}

AIFarmerTarget :: proc(w: ^World, kingdom, town_slot: int) -> int {
	town := &w.kingdoms[kingdom].towns[town_slot]
	target := int(math.ceil(f32(town.citizens)*0.25))
	if town.foodShortage > 0.5 do target += 1
	return clamp(target, 1, 10)
}

AIMilitaryTarget :: proc(w: ^World, kingdom, town_slot: int, brain: ^AIBrain) -> int {
	town := &w.kingdoms[kingdom].towns[town_slot]
	economy := clamp(1+town.citizens/12, 1, 3)+
		AIFarmerTarget(w, kingdom, town_slot)+
		AIWaterCollectorTarget(w, kingdom, town_slot)
	target := max(3, town.citizens-economy)
	if brain.aggression > 0.65 do target += max(1, town.citizens/8)
	if KingdomHasWar(w, kingdom) do target += 3
	target = min(target, max(3, town.citizens*2/5))
	return clamp(target, 3, 24)
}

AIChooseWarriorKind :: proc(w: ^World, kingdom, town_slot: int) -> (UnitKind, bool) {
	candidates: [len(UnitKind)]UnitKind
	count := 0
	for kind in ALL_UNIT_KINDS {
		if !AIKindIsWarrior(kind) do continue
		if !TownUnitAvailable(w, kingdom, town_slot, kind) do continue
		candidates[count] = kind
		count += 1
	}
	if count == 0 do return .Villager, false
	roll := AIRandom(w, kingdom, 100+town_slot*7)
	return candidates[int(roll*f32(count))%count], true
}

AITownEconomy :: proc(
	w: ^World,
	kingdom, town_slot: int,
	counts: ^[UnitKind]int,
	brain: ^AIBrain,
) {
	town := &w.kingdoms[kingdom].towns[town_slot]
	if town.citizens <= 0 do return

	committed := 0
	for job in town.conversions {
		if job.from == .Villager do committed += job.remaining
	}
	available := counts[.Villager]-committed
	// Villagers drive growth, so the economy only spends the part above a
	// half-population reserve. The military is allowed to draw deeper when the
	// kingdom is at war or its army target is far behind.
	economy_reserve := max(2, town.citizens/2)
	military_reserve := max(2, town.citizens/4)
	economy_allowed := available > economy_reserve
	military_allowed := available > military_reserve
	if !economy_allowed && !military_allowed do return

	builders_target := clamp(1+town.citizens/12, 1, 3)
	farmer_target := AIFarmerTarget(w, kingdom, town_slot)
	water_target := AIWaterCollectorTarget(w, kingdom, town_slot)
	military := 0
	for kind in ALL_UNIT_KINDS {
		if AIKindIsWarrior(kind) do military += counts[kind]
	}
	military_target := AIMilitaryTarget(w, kingdom, town_slot, brain)

	// Early essentials first, then a small army, then the rest of the economy.
	builder_count := counts[.Builder]+AIPendingTo(w, kingdom, town_slot, .Builder)
	if economy_allowed && builder_count < 1 {
		if AIQueueConversion(w, kingdom, town_slot, .Builder) do return
	}
	farmer_count := counts[.Farmer]+AIPendingTo(w, kingdom, town_slot, .Farmer)
	if economy_allowed && farmer_count < 1 {
		if AIQueueConversion(w, kingdom, town_slot, .Farmer) do return
	}
	water_count := counts[.WaterCollector]+AIPendingTo(w, kingdom, town_slot, .WaterCollector)
	if economy_allowed && water_target > 0 && water_count < 1 {
		if AIQueueConversion(w, kingdom, town_slot, .WaterCollector) do return
	}

	early_military := 2
	if brain.aggression > 0.65 do early_military = 3
	if military_allowed && military+AIPendingMilitary(w, kingdom, town_slot) < early_military {
		if kind, ok := AIChooseWarriorKind(w, kingdom, town_slot); ok {
			if AIQueueConversion(w, kingdom, town_slot, kind) do return
		}
	}

	if economy_allowed && builder_count < builders_target {
		if AIQueueConversion(w, kingdom, town_slot, .Builder) do return
	}
	if economy_allowed && farmer_count < farmer_target {
		if AIQueueConversion(w, kingdom, town_slot, .Farmer) do return
	}
	if economy_allowed && water_target > 0 && water_count < water_target {
		if AIQueueConversion(w, kingdom, town_slot, .WaterCollector) do return
	}

	// Fill whichever role is furthest behind its target. This keeps a growing
	// army from being starved by the constantly growing economy targets.
	best_priority: f32 = 0
	best_role: UnitKind = .Villager
	best_military := false

	if builders_target > 0 && builder_count < builders_target && economy_allowed {
		priority := f32(builders_target-builder_count)/f32(builders_target)
		if priority > best_priority {
			best_priority = priority
			best_role = .Builder
		}
	}
	if farmer_target > 0 && farmer_count < farmer_target && economy_allowed {
		priority := f32(farmer_target-farmer_count)/f32(farmer_target)
		if priority > best_priority {
			best_priority = priority
			best_role = .Farmer
		}
	}
	if water_target > 0 && water_count < water_target && economy_allowed {
		priority := f32(water_target-water_count)/f32(water_target)
		if priority > best_priority {
			best_priority = priority
			best_role = .WaterCollector
		}
	}
	military_count := military+AIPendingMilitary(w, kingdom, town_slot)
	if military_allowed && military_count < military_target {
		priority := f32(military_target-military_count)/f32(military_target)
		if priority > best_priority {
			best_priority = priority
			best_military = true
		}
	}

	if best_military {
		if kind, ok := AIChooseWarriorKind(w, kingdom, town_slot); ok {
			if AIQueueConversion(w, kingdom, town_slot, kind) do return
		}
	} else if best_role != .Villager {
		if AIQueueConversion(w, kingdom, town_slot, best_role) do return
	}

	if _, wanted := AICombatBuildingChoice(w, kingdom, town_slot); wanted {
		if counts[.CombatBuilder]+AIPendingTo(w, kingdom, town_slot, .CombatBuilder) < 1 {
			_ = AIQueueConversion(w, kingdom, town_slot, .CombatBuilder)
		}
	}
}

AIChooseMilestoneOption :: proc(
	w: ^World,
	kingdom, town_slot: int,
	brain: ^AIBrain,
) -> int {
	town := &w.kingdoms[kingdom].towns[town_slot]
	prefer := 1
	if brain.aggression > 0.55 {
		switch town.milestonesReached {
		case 0:
			prefer = 0
		case 1:
			prefer = 1
		case 2:
			prefer = 1
		case:
		}
	} else {
		switch town.milestonesReached {
		case 0:
			prefer = 1
		case 1:
			prefer = 0
		case 2:
			prefer = 0
		case:
		}
	}
	if AIRandom(w, kingdom, 211+town_slot*13) < 0.18 do prefer = 1-prefer
	return prefer
}

AICombatBuildingChoice :: proc(w: ^World, kingdom, town_slot: int) -> (BuildingKind, bool) {
	town := &w.kingdoms[kingdom].towns[town_slot]
	kinds := [2]BuildingKind{.Watchtower, .Cannon}
	for kind in kinds {
		if !(kind in town.unlockedBuildings) do continue
		if town.buildingCounts[kind] > 0 do continue
		if AICombatSitePending(w, kingdom, town_slot, kind) do continue
		return kind, true
	}
	return .Wall, false
}

AICombatSitePending :: proc(w: ^World, kingdom, town_slot: int, kind: BuildingKind) -> bool {
	for slot in 0 ..< COMBAT_SITE_CAPACITY {
		if !w.combatSiteUsed[slot] do continue
		if w.combatSites.kingdom[slot] != kingdom || w.combatSites.town[slot] != town_slot {
			continue
		}
		if w.combatSites.kind[slot] == kind do return true
	}
	return false
}

AITryCombatBuilding :: proc(
	w: ^World,
	kingdom, town_slot: int,
	counts: ^[UnitKind]int,
) {
	if counts[.CombatBuilder] <= 0 do return
	kind, wanted := AICombatBuildingChoice(w, kingdom, town_slot)
	if !wanted do return

	town := &w.kingdoms[kingdom].towns[town_slot]

	width, height := BuildingTileSize(BuildingTypeFromKind(kind))
	center_x := f32(town.x)+2
	center_y := f32(town.y)+2
	for attempt in 0 ..< 12 {
		angle := WorldNoiseHash(kingdom*17+town_slot, attempt, w.seed+0xC0B1)*6.2831853
		distance := 6+WorldNoiseHash(attempt, kingdom, w.seed+0xC0B2)*7
		x := WorldWrapCoordinate(int(center_x+math.cos(angle)*distance)-width/2, int(w.maxX))
		y := WorldWrapCoordinate(int(center_y+math.sin(angle)*distance)-height/2, int(w.maxY))
		if TownCombatConstructionFailure(w, kingdom, town_slot, kind, x, y) != .None do continue
		if KingdomIssueCommand(
			w,
			kingdom,
			CommandBuildCombat{town = town_slot, kind = kind, x = x, y = y},
		) {
			return
		}
	}
}

AITownCount :: proc(w: ^World, kingdom: int) -> int {
	count := 0
	for town_slot in 0 ..< TOWN_CAPACITY {
		if w.kingdoms[kingdom].townUsed[town_slot] do count += 1
	}
	return count
}

AIMilitaryCount :: proc(w: ^World, kingdom: int) -> int {
	count := 0
	for unit_slot in 0 ..< UNIT_CAPACITY {
		if !w.unitUsed[unit_slot] || w.units[unit_slot].type == nil do continue
		if w.units[unit_slot].kingdome != kingdom do continue
		if AIKindIsWarrior(UnitKindOf(w.units[unit_slot].type)) do count += 1
	}
	return count
}

KingdomHasWar :: proc(w: ^World, kingdom: int) -> bool {
	for other in 0 ..< KINGDOMS_CAPACITY {
		if KingdomAtWar(w, kingdom, other) do return true
	}
	return false
}

AINearestTownOf :: proc(w: ^World, kingdom, from_kingdom: int) -> int {
	if !w.kingdomUsed[from_kingdom] do return -1
	center_town := w.kingdoms[from_kingdom].capitalSlot
	if center_town < 0 || !w.kingdoms[from_kingdom].townUsed[center_town] {
		center_town = -1
		for town_slot in 0 ..< TOWN_CAPACITY {
			if w.kingdoms[from_kingdom].townUsed[town_slot] {
				center_town = town_slot
				break
			}
		}
	}
	if center_town < 0 do return -1
	center := &w.kingdoms[from_kingdom].towns[center_town]
	center_x := f32(center.x)+2
	center_y := f32(center.y)+2
	best := -1
	best_distance: f32 = 0
	for town_slot in 0 ..< TOWN_CAPACITY {
		if !w.kingdoms[kingdom].townUsed[town_slot] do continue
		town := &w.kingdoms[kingdom].towns[town_slot]
		delta_x := WorldShortestWrappedDelta(f32(town.x)+2-center_x, f32(w.maxX))
		delta_y := WorldShortestWrappedDelta(f32(town.y)+2-center_y, f32(w.maxY))
		distance := delta_x*delta_x+delta_y*delta_y
		if best < 0 || distance < best_distance {
			best = town_slot
			best_distance = distance
		}
	}
	return best
}

AIPickWarTarget :: proc(
	w: ^World,
	kingdom, own_military: int,
	own_capital_x, own_capital_y: f32,
	brain: ^AIBrain,
) -> int {
	best := -1
	best_score: f32 = -1e9
	for other in 0 ..< KINGDOMS_CAPACITY {
		if other == kingdom || !w.kingdomUsed[other] do continue
		if KingdomAtWar(w, kingdom, other) do continue
		if other == brain.truceKingdom && w.simulationTime < brain.truceUntil do continue
		target_town := AINearestTownOf(w, other, kingdom)
		if target_town < 0 do continue

		town := &w.kingdoms[other].towns[target_town]
		delta_x := WorldShortestWrappedDelta(f32(town.x)+2-own_capital_x, f32(w.maxX))
		delta_y := WorldShortestWrappedDelta(f32(town.y)+2-own_capital_y, f32(w.maxY))
		distance := math.sqrt(delta_x*delta_x+delta_y*delta_y)
		score := f32(own_military)-f32(AIMilitaryCount(w, other))*1.1-
			f32(AITownCount(w, other))*4-distance*0.18+WorldNoiseHash(kingdom, other, w.seed+0xA17)*4
		if score > best_score {
			best_score = score
			best = other
		}
	}
	return best
}

AIDiplomacy :: proc(w: ^World, kingdom: int) {
	if w.simulationTime < AI_ATTACK_GRACE_SECONDS do return

	brain := &w.controllers[kingdom].ai
	own_military := AIMilitaryCount(w, kingdom)
	own_towns := AITownCount(w, kingdom)
	if own_towns <= 0 do return

	war_count := 0
	best_war_enemy := -1
	for other in 0 ..< KINGDOMS_CAPACITY {
		if !KingdomAtWar(w, kingdom, other) do continue
		war_count += 1
		if best_war_enemy < 0 do best_war_enemy = other
	}

	// Keep pressure on current enemies: each town sends its share of warriors
	// toward the nearest surviving enemy town.
	for other in 0 ..< KINGDOMS_CAPACITY {
		if !KingdomAtWar(w, kingdom, other) do continue
		target_town := AINearestTownOf(w, other, kingdom)
		if target_town < 0 do continue
		for town_slot in 0 ..< TOWN_CAPACITY {
			if !w.kingdoms[kingdom].townUsed[town_slot] do continue
			town := &w.kingdoms[kingdom].towns[town_slot]
			if town.orderCount >= 3 do continue
			KingdomIssueCommand(
				w,
				kingdom,
				CommandAttackTown{
					town = town_slot,
					target_kingdom = other,
					target_town = target_town,
				},
			)
		}
	}

	// A losing or cautious kingdom sues for peace.
	if war_count > 0 && best_war_enemy >= 0 && w.simulationTime > brain.warCommitUntil &&
		(brain.aggression < 0.55 || own_military*2 < AIMilitaryCount(w, best_war_enemy)) {
		roll := AIRandom(w, kingdom, 307)
		if roll < 0.35 {
			KingdomIssueCommand(w, kingdom, CommandMakePeace{other = best_war_enemy})
			brain.truceKingdom = best_war_enemy
			brain.truceUntil = w.simulationTime+AI_TRUCE_SECONDS
			return
		}
	}

	max_wars := 1
	if brain.aggression > 0.65 do max_wars = 2
	if war_count >= max_wars do return
	if w.simulationTime < brain.truceUntil do return

	capital_town := w.kingdoms[kingdom].capitalSlot
	if capital_town < 0 || !w.kingdoms[kingdom].townUsed[capital_town] do return
	capital := &w.kingdoms[kingdom].towns[capital_town]
	target := AIPickWarTarget(w, kingdom, own_military, f32(capital.x)+2, f32(capital.y)+2, brain)
	if target < 0 do return
	min_attack := 3+own_towns
	if brain.aggression > 0.65 do min_attack = 2+own_towns
	if own_military < min_attack do return
	roll := AIRandom(w, kingdom, 311)
	if roll > 0.30+brain.aggression*0.55 do return

	target_town := AINearestTownOf(w, target, kingdom)
	if target_town < 0 do return
	for town_slot in 0 ..< TOWN_CAPACITY {
		if !w.kingdoms[kingdom].townUsed[town_slot] do continue
		if w.kingdoms[kingdom].towns[town_slot].orderCount >= 1 do continue
		KingdomIssueCommand(
			w,
			kingdom,
			CommandAttackTown{town = town_slot, target_kingdom = target, target_town = target_town},
		)
	}
	brain.warCommitUntil = w.simulationTime+AI_WAR_COMMIT_SECONDS
}

AIExpand :: proc(w: ^World, kingdom: int) {
	brain := &w.controllers[kingdom].ai
	max_towns := 6+int(brain.expansion*6)
	if AITownCount(w, kingdom) >= max_towns do return

	for town_slot in 0 ..< TOWN_CAPACITY {
		if !w.kingdoms[kingdom].townUsed[town_slot] do continue
		town := &w.kingdoms[kingdom].towns[town_slot]
		if town.citizens < TOWN_FOUNDING_MIN_CITIZENS do continue
		if town.wood < TOWN_FOUNDING_WOOD do continue
		if town.constructionActive && town.construction.kind == .TownHall do continue
		if TownUnitCount(w, kingdom, town_slot, .Builder) <= 0 do continue
		if KingdomFreeTownSlot(w, kingdom) < 0 do continue
		if AIFoundTownAt(w, kingdom, town_slot) do return
	}
}

AIFoundTownAt :: proc(w: ^World, kingdom, town_slot: int) -> bool {
	town := &w.kingdoms[kingdom].towns[town_slot]
	for attempt in 0 ..< 32 {
		angle := WorldNoiseHash(kingdom*31+town_slot, attempt, w.seed+0xF0D)*6.2831853
		distance := f32(TOWN_FOUNDING_MIN_DISTANCE)+2+
			WorldNoiseHash(attempt, kingdom, w.seed+0xF0E)*28
		center_x := f32(town.x)+2+math.cos(angle)*distance
		center_y := f32(town.y)+2+math.sin(angle)*distance
		x := WorldWrapCoordinate(int(center_x)-2, int(w.maxX))
		y := WorldWrapCoordinate(int(center_y)-2, int(w.maxY))
		if TownFoundingFailure(w, kingdom, town_slot, x, y) != .None do continue
		if KingdomIssueCommand(w, kingdom, CommandFoundTown{town = town_slot, x = x, y = y}) {
			return true
		}
	}
	return false
}
