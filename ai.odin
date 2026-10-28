package main

import "core:math"

// The AI is intentionally built from the same orders a human uses. It never
// touches unit state directly, so swapping in an RL policy or a network
// controller later only means producing the same KingdomCommands.

AI_DECISION_MIN :: 2.8
AI_DECISION_MAX :: 5.4
AI_ORDER_MIN :: 12
AI_ORDER_MAX :: 22
AI_DIPLOMACY_MIN :: 22
AI_DIPLOMACY_MAX :: 46
AI_EXPAND_MIN :: 9
AI_EXPAND_MAX :: 20
AI_ATTACK_GRACE_SECONDS :: 45
AI_WAR_COMMIT_SECONDS :: 75
AI_TRUCE_SECONDS :: 90

AIBrain :: struct {
	decisionTimer:     f32,
	orderTimer:        f32,
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
	brain.orderTimer = 6+WorldNoiseHash(kingdom, 29, seed)*8
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

AIControllerUpdate :: proc(w: ^World, kingdom: int, deltaTime: f32) {
	brain := &w.controllers[kingdom].ai

	brain.decisionTimer -= deltaTime
	brain.orderTimer -= deltaTime
	brain.diplomacyTimer -= deltaTime
	brain.expandTimer -= deltaTime

	if brain.decisionTimer <= 0 {
		brain.decisionTimer = AI_DECISION_MIN+
			AIRandom(w, kingdom, 31)*(AI_DECISION_MAX-AI_DECISION_MIN)
		AIDecide(w, kingdom)
	}
	if brain.orderTimer <= 0 {
		brain.orderTimer = AI_ORDER_MIN+AIRandom(w, kingdom, 43)*(AI_ORDER_MAX-AI_ORDER_MIN)
		AIUseOrders(w, kingdom)
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
	for unitSlot in 0 ..< UNIT_CAPACITY {
		if !w.unitUsed[unitSlot] || w.units[unitSlot].type == nil do continue
		if w.units[unitSlot].kingdome != kingdom do continue
		townSlot := w.units[unitSlot].town
		if townSlot < 0 || townSlot >= TOWN_CAPACITY do continue
		counts[townSlot][UnitKindOf(w.units[unitSlot].type)] += 1
	}

	brain := &w.controllers[kingdom].ai
	for townSlot in 0 ..< TOWN_CAPACITY {
		if !w.kingdoms[kingdom].townUsed[townSlot] do continue
		town := &w.kingdoms[kingdom].towns[townSlot]

		if town.milestonePending {
			option := AIChooseMilestoneOption(w, kingdom, townSlot, brain)
			KingdomIssueCommand(
				w,
				kingdom,
				CommandChooseMilestone{town = townSlot, option = option},
			)
		}

		AITownEconomy(w, kingdom, townSlot, &counts[townSlot], brain)
		AITryCombatBuilding(w, kingdom, townSlot, &counts[townSlot])
	}
	AITechUpdate(w, kingdom)
}

AITechUpdate :: proc(w: ^World, kingdom: int) {
	if KingdomInsight(w, kingdom) <= 0 do return
	priorities: [5]CrownBranch = {.Warfare, .Provisioning, .Industry, .Statecraft, .Seafaring}
	if KingdomHasWar(w, kingdom) {
		priorities = {.Warfare, .Industry, .Statecraft, .Provisioning, .Seafaring}
	}
	if w.kingdoms[kingdom].coastalTownCount > 0 {
		priorities = {.Seafaring, .Warfare, .Provisioning, .Industry, .Statecraft}
	}

	for _ in 0..<3 {
		unlockedAny := false
		for branch in priorities {
			for tech in CROWN_BRANCH_TECHS[branch] {
				if !KingdomCanUnlockTech(w, kingdom, tech) do continue
				if KingdomUnlockTech(w, kingdom, tech) {
					unlockedAny = true
					break
				}
			}
		}
		if !unlockedAny do break
	}
}

// Strongest first. Every source fires once per cooldown, so the AI spends its
// rare orders before falling back to mortars and naval utility.
AI_ORDER_PRIORITY := [len(ALL_ORDER_KINDS)]OrderKind{
	.Starfall,
	.NapalmBarrage,
	.SiegeTremor,
	.WaterBomber,
	.MiasmaBarrage,
	.GlacierShell,
	.GiantMortar,
	.Blockade,
}

AIUseOrders :: proc(w: ^World, kingdom: int) {
	if !KingdomHasWar(w, kingdom) do return
	for kind in AI_ORDER_PRIORITY {
		if OrderSourceReadyCount(w, kingdom, kind) <= 0 do continue
		if kind == .Blockade {
			if AIUseBlockade(w, kingdom) do return
			continue
		}
		hazard := kind == .GlacierShell || kind == .WaterBomber ||
			kind == .MiasmaBarrage || kind == .NapalmBarrage
		if kind == .NapalmBarrage && WorldWeatherEffects(w).fireSpread < 0.5 do continue
		for other in 0 ..< KINGDOMS_CAPACITY {
			if !KingdomAtWar(w, kingdom, other) do continue
			targetTown := AINearestTownOf(w, other, kingdom)
			if targetTown < 0 do continue
			town := &w.kingdoms[other].towns[targetTown]
			x := f32(town.x)+2
			y := f32(town.y)+2
			if hazard && !AIOrderHazardClear(w, kingdom, x, y, OrderRadius(kind)) do continue
			if KingdomIssueCommand(
				w,
				kingdom,
				CommandUseOrder{kind = kind, x = x, y = y},
			) {
				return
			}
		}
	}
}

// Flood, gas, fire and ice ignore kingdoms. Do not drop one on the assault.
// Mortars, tremors and starfall are exempt: those only damage enemies.
AIOrderHazardClear :: proc(w: ^World, kingdom: int, x, y, radius: f32) -> bool {
	worldWidth := f32(w.maxX)
	worldHeight := f32(w.maxY)
	radiusSquared := radius*radius
	for unitSlot in 0 ..< UNIT_CAPACITY {
		if !w.unitUsed[unitSlot] || w.units[unitSlot].type == nil do continue
		if w.units[unitSlot].kingdome != kingdom do continue
		if UnitHiddenInside(w, unitSlot) do continue
		deltaX := WorldShortestWrappedDelta(w.units[unitSlot].x-x, worldWidth)
		deltaY := WorldShortestWrappedDelta(w.units[unitSlot].y-y, worldHeight)
		if deltaX*deltaX+deltaY*deltaY <= radiusSquared do return false
	}
	return true
}

// Blockades only matter on coastal towns that are not already cut off.
AIUseBlockade :: proc(w: ^World, kingdom: int) -> bool {
	for other in 0 ..< KINGDOMS_CAPACITY {
		if !KingdomAtWar(w, kingdom, other) do continue
		targetTown := AINearestTownOf(w, other, kingdom, coastalOnly = true)
		if targetTown < 0 do continue
		town := &w.kingdoms[other].towns[targetTown]
		if town.blockadeUntil > w.simulationTime do continue
		if KingdomIssueCommand(
			w,
			kingdom,
			CommandUseOrder{kind = .Blockade, x = f32(town.x)+2, y = f32(town.y)+2},
		) {
			return true
		}
	}
	return false
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

AIPendingTo :: proc(w: ^World, kingdom, townSlot: int, to: UnitKind) -> int {
	town := &w.kingdoms[kingdom].towns[townSlot]
	pending := 0
	for job in town.conversions {
		if job.from == .Villager && job.to == to do pending += job.remaining
	}
	return pending
}

AIPendingMilitary :: proc(w: ^World, kingdom, townSlot: int) -> int {
	town := &w.kingdoms[kingdom].towns[townSlot]
	pending := 0
	for job in town.conversions {
		if job.from == .Villager && AIKindIsWarrior(job.to) do pending += job.remaining
	}
	return pending
}

AIQueueConversion :: proc(w: ^World, kingdom, townSlot: int, kind: UnitKind) -> bool {
	if !TownUnitAvailable(w, kingdom, townSlot, kind) do return false
	return KingdomIssueCommand(
		w,
		kingdom,
		CommandQueueConversion{town = townSlot, from = .Villager, to = kind, count = 1},
	)
}

AIWaterCollectorTarget :: proc(w: ^World, kingdom, townSlot: int) -> int {
	town := &w.kingdoms[kingdom].towns[townSlot]
	collectorOutput := TownWaterCollectorOutput(TownWaterAccess(w, kingdom, townSlot))
	if collectorOutput <= 0.001 do return 0
	need := f32(town.citizens)*0.025
	target := int(math.ceil(need/collectorOutput))
	return clamp(target, 1, max(1, town.citizens/4))
}

AIFarmerTarget :: proc(w: ^World, kingdom, townSlot: int) -> int {
	town := &w.kingdoms[kingdom].towns[townSlot]
	target := int(math.ceil(f32(town.citizens)*0.25))
	if town.foodShortage > 0.5 do target += 1
	// The old ten-farmer ceiling cannot feed the late growth eras. Let the
	// target scale with population while keeping the early-game floor.
	return clamp(target, 1, max(10, town.citizens/4))
}

AIMilitaryTarget :: proc(w: ^World, kingdom, townSlot: int, brain: ^AIBrain) -> int {
	town := &w.kingdoms[kingdom].towns[townSlot]
	economy := clamp(1+town.citizens/12, 1, 3)+
		AIFarmerTarget(w, kingdom, townSlot)+
		AIWaterCollectorTarget(w, kingdom, townSlot)
	target := max(3, town.citizens-economy)
	if brain.aggression > 0.65 do target += max(1, town.citizens/8)
	if KingdomHasWar(w, kingdom) do target += 3
	target = min(target, max(3, town.citizens*2/5))
	return clamp(target, 3, 24)
}

AIChooseWarriorKind :: proc(w: ^World, kingdom, townSlot: int) -> (UnitKind, bool) {
	candidates: [len(UnitKind)]UnitKind
	count := 0
	for kind in ALL_UNIT_KINDS {
		if !AIKindIsWarrior(kind) do continue
		if !TownUnitAvailable(w, kingdom, townSlot, kind) do continue
		candidates[count] = kind
		count += 1
	}
	if count == 0 do return .Villager, false
	roll := AIRandom(w, kingdom, 100+townSlot*7)
	return candidates[int(roll*f32(count))%count], true
}

AITownEconomy :: proc(
	w: ^World,
	kingdom, townSlot: int,
	counts: ^[UnitKind]int,
	brain: ^AIBrain,
) {
	town := &w.kingdoms[kingdom].towns[townSlot]
	if town.citizens <= 0 do return

	committed := 0
	for job in town.conversions {
		if job.from == .Villager do committed += job.remaining
	}
	available := counts[.Villager]-committed
	// Villagers drive growth, so the economy only spends the part above a
	// half-population reserve. The military is allowed to draw deeper when the
	// kingdom is at war or its army target is far behind.
	economyReserve := max(2, town.citizens/2)
	militaryReserve := max(2, town.citizens/4)
	// Keep a full settler party at home so the town can still pay the next
	// charter instead of converting every villager into a job.
	if KingdomFreeTownSlot(w, kingdom) >= 0 {
		economyReserve = max(economyReserve, TOWN_FOUNDING_SETTLERS)
		militaryReserve = max(militaryReserve, TOWN_FOUNDING_SETTLERS)
	}
	economyAllowed := available > economyReserve
	militaryAllowed := available > militaryReserve
	if !economyAllowed && !militaryAllowed do return

	buildersTarget := clamp(1+town.citizens/12, 1, 3)
	farmerTarget := AIFarmerTarget(w, kingdom, townSlot)
	waterTarget := AIWaterCollectorTarget(w, kingdom, townSlot)
	military := 0
	for kind in ALL_UNIT_KINDS {
		if AIKindIsWarrior(kind) do military += counts[kind]
	}
	militaryTarget := AIMilitaryTarget(w, kingdom, townSlot, brain)

	// Early essentials first, then a small army, then the rest of the economy.
	builderCount := counts[.Builder]+AIPendingTo(w, kingdom, townSlot, .Builder)
	if economyAllowed && builderCount < 1 {
		if AIQueueConversion(w, kingdom, townSlot, .Builder) do return
	}
	farmerCount := counts[.Farmer]+AIPendingTo(w, kingdom, townSlot, .Farmer)
	if economyAllowed && farmerCount < 1 {
		if AIQueueConversion(w, kingdom, townSlot, .Farmer) do return
	}
	waterCount := counts[.WaterCollector]+AIPendingTo(w, kingdom, townSlot, .WaterCollector)
	if economyAllowed && waterTarget > 0 && waterCount < 1 {
		if AIQueueConversion(w, kingdom, townSlot, .WaterCollector) do return
	}

	earlyMilitary := 2
	if brain.aggression > 0.65 do earlyMilitary = 3
	if militaryAllowed && military+AIPendingMilitary(w, kingdom, townSlot) < earlyMilitary {
		if kind, ok := AIChooseWarriorKind(w, kingdom, townSlot); ok {
			if AIQueueConversion(w, kingdom, townSlot, kind) do return
		}
	}

	if economyAllowed && builderCount < buildersTarget {
		if AIQueueConversion(w, kingdom, townSlot, .Builder) do return
	}
	if economyAllowed && farmerCount < farmerTarget {
		if AIQueueConversion(w, kingdom, townSlot, .Farmer) do return
	}
	if economyAllowed && waterTarget > 0 && waterCount < waterTarget {
		if AIQueueConversion(w, kingdom, townSlot, .WaterCollector) do return
	}

	// Fill whichever role is furthest behind its target. This keeps a growing
	// army from being starved by the constantly growing economy targets.
	bestPriority: f32 = 0
	bestRole: UnitKind = .Villager
	bestMilitary := false

	if buildersTarget > 0 && builderCount < buildersTarget && economyAllowed {
		priority := f32(buildersTarget-builderCount)/f32(buildersTarget)
		if priority > bestPriority {
			bestPriority = priority
			bestRole = .Builder
		}
	}
	if farmerTarget > 0 && farmerCount < farmerTarget && economyAllowed {
		priority := f32(farmerTarget-farmerCount)/f32(farmerTarget)
		if priority > bestPriority {
			bestPriority = priority
			bestRole = .Farmer
		}
	}
	if waterTarget > 0 && waterCount < waterTarget && economyAllowed {
		priority := f32(waterTarget-waterCount)/f32(waterTarget)
		if priority > bestPriority {
			bestPriority = priority
			bestRole = .WaterCollector
		}
	}
	militaryCount := military+AIPendingMilitary(w, kingdom, townSlot)
	if militaryAllowed && militaryCount < militaryTarget {
		priority := f32(militaryTarget-militaryCount)/f32(militaryTarget)
		if priority > bestPriority {
			bestPriority = priority
			bestMilitary = true
		}
	}

	if bestMilitary {
		if kind, ok := AIChooseWarriorKind(w, kingdom, townSlot); ok {
			if AIQueueConversion(w, kingdom, townSlot, kind) do return
		}
	} else if bestRole != .Villager {
		if AIQueueConversion(w, kingdom, townSlot, bestRole) do return
	}

	if _, wanted := AICombatBuildingChoice(w, kingdom, townSlot); wanted {
		if counts[.CombatBuilder]+AIPendingTo(w, kingdom, townSlot, .CombatBuilder) < 1 {
			_ = AIQueueConversion(w, kingdom, townSlot, .CombatBuilder)
		}
	}
}

MilestoneOptionWarriorWeight :: proc(option: MilestoneOption) -> int {
	weight := 0
	for kind in UnitKind {
		if kind in option.units && AIKindIsWarrior(kind) do weight += 1
	}
	return weight
}

AIChooseMilestoneOption :: proc(
	w: ^World,
	kingdom, townSlot: int,
	brain: ^AIBrain,
) -> int {
	town := &w.kingdoms[kingdom].towns[townSlot]
	if town.milestonesChosen >= TOWN_MILESTONE_TIER_COUNT do return 0

	optionA := TOWN_ERA_REWARDS[town.milestonesChosen][0]
	optionB := TOWN_ERA_REWARDS[town.milestonesChosen][1]
	weightA := MilestoneOptionWarriorWeight(optionA)
	weightB := MilestoneOptionWarriorWeight(optionB)

	prefer := 0
	if brain.aggression > 0.55 {
		if weightB > weightA do prefer = 1
	} else {
		if weightA > weightB do prefer = 1
	}
	if AIRandom(w, kingdom, 211+townSlot*13) < 0.18 do prefer = 1-prefer
	return prefer
}

AICombatBuildingChoice :: proc(w: ^World, kingdom, townSlot: int) -> (BuildingKind, bool) {
	town := &w.kingdoms[kingdom].towns[townSlot]
	kinds := [5]BuildingKind{.Watchtower, .Cannon, .GiantMortar, .FireworksGuild, .StarfallSpire}
	for kind in kinds {
		if !(kind in town.unlockedBuildings) do continue
		if town.buildingCounts[kind] > 0 do continue
		if AICombatSitePending(w, kingdom, townSlot, kind) do continue
		return kind, true
	}
	return .Wall, false
}

AICombatSitePending :: proc(w: ^World, kingdom, townSlot: int, kind: BuildingKind) -> bool {
	for slot in 0 ..< COMBAT_SITE_CAPACITY {
		if !w.combatSiteUsed[slot] do continue
		if w.combatSites.kingdom[slot] != kingdom || w.combatSites.town[slot] != townSlot {
			continue
		}
		if w.combatSites.kind[slot] == kind do return true
	}
	return false
}

AITryCombatBuilding :: proc(
	w: ^World,
	kingdom, townSlot: int,
	counts: ^[UnitKind]int,
) {
	if counts[.CombatBuilder] <= 0 do return
	kind, wanted := AICombatBuildingChoice(w, kingdom, townSlot)
	if !wanted do return

	town := &w.kingdoms[kingdom].towns[townSlot]

	width, height := BuildingTileSize(BuildingTypeFromKind(kind))
	centerX := f32(town.x)+2
	centerY := f32(town.y)+2
	for attempt in 0 ..< 12 {
		angle := WorldNoiseHash(kingdom*17+townSlot, attempt, w.seed+0xC0B1)*6.2831853
		distance := 6+WorldNoiseHash(attempt, kingdom, w.seed+0xC0B2)*7
		x := WorldWrapCoordinate(int(centerX+math.cos(angle)*distance)-width/2, int(w.maxX))
		y := WorldWrapCoordinate(int(centerY+math.sin(angle)*distance)-height/2, int(w.maxY))
		if TownCombatConstructionFailure(w, kingdom, townSlot, kind, x, y) != .None do continue
		if KingdomIssueCommand(
			w,
			kingdom,
			CommandBuildCombat{town = townSlot, kind = kind, x = x, y = y},
		) {
			return
		}
	}
}

AITownCount :: proc(w: ^World, kingdom: int) -> int {
	count := 0
	for townSlot in 0 ..< TOWN_CAPACITY {
		if w.kingdoms[kingdom].townUsed[townSlot] do count += 1
	}
	return count
}

AIMilitaryCount :: proc(w: ^World, kingdom: int) -> int {
	count := 0
	for unitSlot in 0 ..< UNIT_CAPACITY {
		if !w.unitUsed[unitSlot] || w.units[unitSlot].type == nil do continue
		if w.units[unitSlot].kingdome != kingdom do continue
		if AIKindIsWarrior(UnitKindOf(w.units[unitSlot].type)) do count += 1
	}
	return count
}

KingdomHasWar :: proc(w: ^World, kingdom: int) -> bool {
	for other in 0 ..< KINGDOMS_CAPACITY {
		if KingdomAtWar(w, kingdom, other) do return true
	}
	return false
}

AINearestTownOf :: proc(w: ^World, kingdom, fromKingdom: int, coastalOnly := false) -> int {
	if !w.kingdomUsed[fromKingdom] do return -1
	centerTown := w.kingdoms[fromKingdom].capitalSlot
	if centerTown < 0 || !w.kingdoms[fromKingdom].townUsed[centerTown] {
		centerTown = -1
		for townSlot in 0 ..< TOWN_CAPACITY {
			if w.kingdoms[fromKingdom].townUsed[townSlot] {
				centerTown = townSlot
				break
			}
		}
	}
	if centerTown < 0 do return -1
	center := &w.kingdoms[fromKingdom].towns[centerTown]
	centerX := f32(center.x)+2
	centerY := f32(center.y)+2
	best := -1
	bestDistance: f32 = 0
	for townSlot in 0 ..< TOWN_CAPACITY {
		if !w.kingdoms[kingdom].townUsed[townSlot] do continue
		if coastalOnly && !TownIsCoastal(w, kingdom, townSlot) do continue
		town := &w.kingdoms[kingdom].towns[townSlot]
		deltaX := WorldShortestWrappedDelta(f32(town.x)+2-centerX, f32(w.maxX))
		deltaY := WorldShortestWrappedDelta(f32(town.y)+2-centerY, f32(w.maxY))
		distance := deltaX*deltaX+deltaY*deltaY
		if best < 0 || distance < bestDistance {
			best = townSlot
			bestDistance = distance
		}
	}
	return best
}

AIPickWarTarget :: proc(
	w: ^World,
	kingdom, ownMilitary: int,
	ownCapitalX, ownCapitalY: f32,
	brain: ^AIBrain,
) -> int {
	best := -1
	bestScore: f32 = -1e9
	for other in 0 ..< KINGDOMS_CAPACITY {
		if !KingdomCanDeclareWar(w, kingdom, other) do continue
		if other == brain.truceKingdom && w.simulationTime < brain.truceUntil do continue
		targetTown := AINearestTownOf(w, other, kingdom)
		if targetTown < 0 do continue

		town := &w.kingdoms[other].towns[targetTown]
		deltaX := WorldShortestWrappedDelta(f32(town.x)+2-ownCapitalX, f32(w.maxX))
		deltaY := WorldShortestWrappedDelta(f32(town.y)+2-ownCapitalY, f32(w.maxY))
		distance := math.sqrt(deltaX*deltaX+deltaY*deltaY)
		score := f32(ownMilitary)-f32(AIMilitaryCount(w, other))*1.1-
			f32(AITownCount(w, other))*4-distance*0.18+WorldNoiseHash(kingdom, other, w.seed+0xA17)*4
		if score > bestScore {
			bestScore = score
			best = other
		}
	}
	return best
}

AIDiplomacy :: proc(w: ^World, kingdom: int) {
	if w.simulationTime < AI_ATTACK_GRACE_SECONDS do return

	brain := &w.controllers[kingdom].ai
	ownMilitary := AIMilitaryCount(w, kingdom)
	ownTowns := AITownCount(w, kingdom)
	if ownTowns <= 0 do return

	warCount := 0
	bestWarEnemy := -1
	for other in 0 ..< KINGDOMS_CAPACITY {
		if !KingdomAtWar(w, kingdom, other) do continue
		warCount += 1
		if bestWarEnemy < 0 do bestWarEnemy = other
	}

	// Keep pressure on current enemies: each town sends its share of warriors
	// toward the nearest surviving enemy town.
	for other in 0 ..< KINGDOMS_CAPACITY {
		if !KingdomAtWar(w, kingdom, other) do continue
		targetTown := AINearestTownOf(w, other, kingdom)
		if targetTown < 0 do continue
		for townSlot in 0 ..< TOWN_CAPACITY {
			if !w.kingdoms[kingdom].townUsed[townSlot] do continue
			town := &w.kingdoms[kingdom].towns[townSlot]
			if town.orderCount >= 3 do continue
			KingdomIssueCommand(
				w,
				kingdom,
				CommandAttackTown{
					town = townSlot,
					targetKingdom = other,
					targetTown = targetTown,
				},
			)
		}
	}

	// A losing or cautious kingdom sues for peace.
	if warCount > 0 && bestWarEnemy >= 0 && w.simulationTime > brain.warCommitUntil &&
		(brain.aggression < 0.55 || ownMilitary*2 < AIMilitaryCount(w, bestWarEnemy)) {
		roll := AIRandom(w, kingdom, 307)
		if roll < 0.35 {
			KingdomIssueCommand(w, kingdom, CommandMakePeace{other = bestWarEnemy})
			brain.truceKingdom = bestWarEnemy
			brain.truceUntil = w.simulationTime+AI_TRUCE_SECONDS
			return
		}
	}

	maxWars := 1
	if brain.aggression > 0.65 do maxWars = 2
	if warCount >= maxWars do return
	if w.simulationTime < brain.truceUntil do return

	capitalTown := w.kingdoms[kingdom].capitalSlot
	if capitalTown < 0 || !w.kingdoms[kingdom].townUsed[capitalTown] do return
	capital := &w.kingdoms[kingdom].towns[capitalTown]
	target := AIPickWarTarget(w, kingdom, ownMilitary, f32(capital.x)+2, f32(capital.y)+2, brain)
	if target < 0 do return
	minAttack := 3+ownTowns
	if brain.aggression > 0.65 do minAttack = 2+ownTowns
	if ownMilitary < minAttack do return
	roll := AIRandom(w, kingdom, 311)
	if roll > 0.30+brain.aggression*0.55 do return

	targetTown := AINearestTownOf(w, target, kingdom)
	if targetTown < 0 do return
	attacked := false
	for townSlot in 0 ..< TOWN_CAPACITY {
		if !w.kingdoms[kingdom].townUsed[townSlot] do continue
		if w.kingdoms[kingdom].towns[townSlot].orderCount >= 1 do continue
		if KingdomIssueCommand(
			w,
			kingdom,
			CommandAttackTown{town = townSlot, targetKingdom = target, targetTown = targetTown},
		) {
			attacked = true
		}
	}
	if attacked do brain.warCommitUntil = w.simulationTime+AI_WAR_COMMIT_SECONDS
}

AIExpand :: proc(w: ^World, kingdom: int) {
	brain := &w.controllers[kingdom].ai
	maxTowns := 6+int(brain.expansion*6)
	if AITownCount(w, kingdom) >= maxTowns do return

	for townSlot in 0 ..< TOWN_CAPACITY {
		if !w.kingdoms[kingdom].townUsed[townSlot] do continue
		town := &w.kingdoms[kingdom].towns[townSlot]
		if town.citizens < TOWN_FOUNDING_MIN_CITIZENS do continue
		if town.wood < TownFoundingWoodCost(w, kingdom) do continue
		if TownUnitCount(w, kingdom, townSlot, .Villager) < TownFoundingSettlers(w, kingdom) do continue
		if TownConstructionKindCount(w, kingdom, townSlot, .TownHall) > 0 do continue
		if TownUnitCount(w, kingdom, townSlot, .Builder) <= 0 do continue
		if KingdomFreeTownSlot(w, kingdom) < 0 do continue
		if AIFoundTownAt(w, kingdom, townSlot) do return
	}
}

AIFoundTownAt :: proc(w: ^World, kingdom, townSlot: int) -> bool {
	town := &w.kingdoms[kingdom].towns[townSlot]
	for attempt in 0 ..< 32 {
		angle := WorldNoiseHash(kingdom*31+townSlot, attempt, w.seed+0xF0D)*6.2831853
		distance := f32(TOWN_FOUNDING_MIN_DISTANCE)+2+
			WorldNoiseHash(attempt, kingdom, w.seed+0xF0E)*28
		centerX := f32(town.x)+2+math.cos(angle)*distance
		centerY := f32(town.y)+2+math.sin(angle)*distance
		x := WorldWrapCoordinate(int(centerX)-2, int(w.maxX))
		y := WorldWrapCoordinate(int(centerY)-2, int(w.maxY))
		if TownFoundingFailure(w, kingdom, townSlot, x, y) != .None do continue
		width, height := BuildingTileSize(TownHall{})
		if WorldScarInRect(w, x, y, width, height, {.Scorched, .Volcanic, .Cleft}) do continue
		if KingdomIssueCommand(w, kingdom, CommandFoundTown{town = townSlot, x = x, y = y}) {
			return true
		}
	}
	return false
}
