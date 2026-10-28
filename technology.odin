package main

CROWN_INSIGHT_PER_MILESTONE :: 1
CROWN_INSIGHT_PER_TOWN :: 1
CROWN_INSIGHT_PER_FUSION :: 1

CrownBranch :: enum {
	Seafaring,
	Provisioning,
	Industry,
	Statecraft,
	Warfare,
}

CrownTech :: enum {
	CoastalBoats,
	FishingFlotillas,
	Harbor,
	SeaPower,
	Blockade,

	CropRotation,
	Irrigation,
	Granary,
	LandReclamation,
	Metropolis,

	Carpentry,
	Masonry,
	Roadworks,
	Bridgeworks,
	BridgeProject,

	Charters,
	Census,
	Bureaucracy,
	Surveyors,
	HighCouncil,

	Drill,
	Armory,
	Fortification,
	Siegecraft,
	Muster,
}

CrownTechDef :: struct {
	branch: CrownBranch,
	tier: int,
	cost: int,
	name: cstring,
	description: cstring,
}

CROWN_TECH_DEFS := [CrownTech]CrownTechDef{
	.CoastalBoats = {.Seafaring, 1, 1, "Coastal Boats", "Civilians and explorers learn the water's road, and may cross open water."},
	.FishingFlotillas = {.Seafaring, 2, 1, "Fishing Flotillas", "Patient nets return full: coastal food +20%, water +15%."},
	.Harbor = {.Seafaring, 3, 2, "Harbor", "A harbor opens the coast: wood, far sight and cheaper charters."},
	.SeaPower = {.Seafaring, 4, 2, "Sea Power", "War learns to swim; military units may cross water."},
	.Blockade = {.Seafaring, 5, 3, "Blockade", "Harbors can close a rival coast and starve it into silence."},

	.CropRotation = {.Provisioning, 1, 1, "Crop Rotation", "The field is taught to rest. Farmland yields +20%."},
	.Irrigation = {.Provisioning, 2, 1, "Irrigation", "Old channels wake; water collectors bring home +20% more."},
	.Granary = {.Provisioning, 3, 2, "Granary", "A granary rises: +10% town growth and +10% food."},
	.LandReclamation = {.Provisioning, 4, 2, "Land Reclamation", "Stone and sand are made to bear seed: farmland on hills and desert."},
	.Metropolis = {.Provisioning, 5, 3, "Metropolis", "The town's reach grows by one, and its people multiply 10% faster."},

	.Carpentry = {.Industry, 1, 1, "Carpentry", "Straight grain, true joints: builders gather +20% wood."},
	.Masonry = {.Industry, 2, 1, "Masonry", "The guild's old secrets: buildings cost 15% less and rise 20% faster."},
	.Roadworks = {.Industry, 3, 2, "Roadworks", "Every path remembers the footfall: +10% speed, 30% faster paths."},
	.Bridgeworks = {.Industry, 4, 2, "Bridgeworks", "Bridges rise 50% faster and stand with 50% more health."},
	.BridgeProject = {.Industry, 5, 3, "Bridge Project", "A realm bound by road and span: bridges and paths give +10% speed."},

	.Charters = {.Statecraft, 1, 1, "Charters", "Old rights, new towns: founding costs 20% less and one fewer settler."},
	.Census = {.Statecraft, 2, 1, "Census", "Every name written twice: conversions complete 20% faster."},
	.Bureaucracy = {.Statecraft, 3, 2, "Bureaucracy", "Quiet clerks win wars: the garrison demand falls from 10% to 5%."},
	.Surveyors = {.Statecraft, 4, 2, "Surveyors", "The land is measured and made legible; unlock the Survey overlay."},
	.HighCouncil = {.Statecraft, 5, 3, "High Council", "Wise voices at the table: milestones grant 2 Crown Insight."},

	.Drill = {.Warfare, 1, 1, "Drill", "The same step, ten thousand times: warrior conversions 20% faster."},
	.Armory = {.Warfare, 2, 1, "Armory", "Oil, iron and care: warriors gain +15% health and +10% damage."},
	.Fortification = {.Warfare, 3, 2, "Fortification", "Walls learn patience: walls, towers and cannons gain +25% health."},
	.Siegecraft = {.Warfare, 4, 2, "Siegecraft", "The mathematics of ruin: siege units deal +25% damage to buildings."},
	.Muster = {.Warfare, 5, 3, "Muster", "Every hand called at once: CombatBuilder conversions 50% faster."},
}

CROWN_BRANCH_TECHS := [CrownBranch][5]CrownTech{
	.Seafaring = {.CoastalBoats, .FishingFlotillas, .Harbor, .SeaPower, .Blockade},
	.Provisioning = {.CropRotation, .Irrigation, .Granary, .LandReclamation, .Metropolis},
	.Industry = {.Carpentry, .Masonry, .Roadworks, .Bridgeworks, .BridgeProject},
	.Statecraft = {.Charters, .Census, .Bureaucracy, .Surveyors, .HighCouncil},
	.Warfare = {.Drill, .Armory, .Fortification, .Siegecraft, .Muster},
}

CrownBranchName :: proc(branch: CrownBranch) -> cstring {
	switch branch {
	case .Seafaring:
		return "SEAFARING"
	case .Provisioning:
		return "PROVISIONING"
	case .Industry:
		return "INDUSTRY"
	case .Statecraft:
		return "STATECRAFT"
	case .Warfare:
		return "WARFARE"
	}
	unreachable()
}

CrownTechName :: proc(tech: CrownTech) -> cstring {
	return CROWN_TECH_DEFS[tech].name
}

CrownTechDescription :: proc(tech: CrownTech) -> cstring {
	return CROWN_TECH_DEFS[tech].description
}

CrownTechBranch :: proc(tech: CrownTech) -> CrownBranch {
	return CROWN_TECH_DEFS[tech].branch
}

CrownTechTier :: proc(tech: CrownTech) -> int {
	return CROWN_TECH_DEFS[tech].tier
}

CrownTechCost :: proc(tech: CrownTech) -> int {
	return CROWN_TECH_DEFS[tech].cost
}

CrownTechPrevious :: proc(tech: CrownTech) -> (CrownTech, bool) {
	chain := CROWN_BRANCH_TECHS[CrownTechBranch(tech)]
	index := CrownTechTier(tech)-2
	if index < 0 || index >= len(chain) do return .CoastalBoats, false
	return chain[index], true
}

KingdomHasTech :: proc(w: ^World, kingdom: int, tech: CrownTech) -> bool {
	if kingdom < 0 || kingdom >= KINGDOMS_CAPACITY || !w.kingdomUsed[kingdom] do return false
	return tech in w.kingdoms[kingdom].techs
}

KingdomInsight :: proc(w: ^World, kingdom: int) -> int {
	if kingdom < 0 || kingdom >= KINGDOMS_CAPACITY do return 0
	return w.kingdoms[kingdom].insight
}

KingdomAddInsight :: proc(w: ^World, kingdom: int, amount: int) {
	if kingdom < 0 || kingdom >= KINGDOMS_CAPACITY || amount <= 0 do return
	w.kingdoms[kingdom].insight += amount
	if kingdom == w.observerKingdom {
		WorldAlertAddInsight(w, kingdom, amount)
	}
}

TECH_BUILDINGS := [2]BuildingKind{.Harbor, .Granary}

TownApplyTechUnlocks :: proc(w: ^World, kingdom, townSlot: int) {
	if kingdom < 0 || kingdom >= KINGDOMS_CAPACITY || townSlot < 0 || townSlot >= TOWN_CAPACITY {
		return
	}
	town := &w.kingdoms[kingdom].towns[townSlot]
	if KingdomHasTech(w, kingdom, .Harbor) do town.unlockedBuildings |= {.Harbor}
	if KingdomHasTech(w, kingdom, .Granary) do town.unlockedBuildings |= {.Granary}
}

KingdomApplyTechBuildingUnlocks :: proc(w: ^World, kingdom: int) {
	for townSlot in 0..<TOWN_CAPACITY {
		if !w.kingdoms[kingdom].townUsed[townSlot] do continue
		TownApplyTechUnlocks(w, kingdom, townSlot)
	}
}

KingdomUnlockTech :: proc(w: ^World, kingdom: int, tech: CrownTech) -> bool {
	if !KingdomCanUnlockTech(w, kingdom, tech) do return false
	w.kingdoms[kingdom].insight -= CrownTechCost(tech)
	w.kingdoms[kingdom].techs |= {tech}
	if tech == .Harbor || tech == .Granary do KingdomApplyTechBuildingUnlocks(w, kingdom)
	if tech == .Metropolis {
		for townSlot in 0..<TOWN_CAPACITY {
			if w.kingdoms[kingdom].townUsed[townSlot] do TownAreaExpand(w, kingdom, townSlot, 1)
		}
	}

	switch tech {
	case .Armory:
		for slot in 0..<UNIT_CAPACITY {
			if !w.unitUsed[slot] || w.units.kingdome[slot] != kingdom do continue
			if UnitIsWarrior(w.units.type[slot]) do w.units.health[slot] *= 1.15
		}
	case .Fortification:
		for slot in 0..<BUILDING_CAPACITY {
			if !w.buildingUsed[slot] || w.buildings.kingdom[slot] != kingdom do continue
			kind := BuildingKindOf(w.buildings.type[slot])
			if kind == .Wall || kind == .Watchtower || kind == .Cannon {
				w.buildings.health[slot] *= 1.25
			}
		}
	case .Bridgeworks:
		for slot in 0..<BUILDING_CAPACITY {
			if !w.buildingUsed[slot] || w.buildings.kingdom[slot] != kingdom do continue
			if BuildingKindOf(w.buildings.type[slot]) == .Bridge {
				w.buildings.health[slot] *= 1.50
			}
		}
	case .CoastalBoats, .FishingFlotillas, .SeaPower, .Blockade,
		.CropRotation, .Irrigation, .LandReclamation,
		.Carpentry, .Masonry, .Roadworks, .BridgeProject,
		.Charters, .Census, .Bureaucracy, .Surveyors, .HighCouncil,
		.Drill, .Siegecraft, .Muster, .Harbor, .Granary, .Metropolis:
	}
	return true
}

KingdomCanUnlockTech :: proc(w: ^World, kingdom: int, tech: CrownTech) -> bool {
	if kingdom < 0 || kingdom >= KINGDOMS_CAPACITY || !w.kingdomUsed[kingdom] do return false
	if KingdomHasTech(w, kingdom, tech) do return false
	if previous, hasPrevious := CrownTechPrevious(tech); hasPrevious {
		if !KingdomHasTech(w, kingdom, previous) do return false
	}
	return w.kingdoms[kingdom].insight >= CrownTechCost(tech)
}

KingdomTechFoodMultiplier :: proc(w: ^World, kingdom, townSlot: int) -> f32 {
	multiplier: f32 = 1
	if KingdomHasTech(w, kingdom, .CropRotation) do multiplier *= 1.20
	if KingdomHasTech(w, kingdom, .FishingFlotillas) && TownIsCoastal(w, kingdom, townSlot) {
		multiplier *= 1.20
	}
	if TownFindBuilding(w, kingdom, townSlot, .Granary) >= 0 do multiplier *= 1.10
	return multiplier
}

KingdomTechWaterMultiplier :: proc(w: ^World, kingdom, townSlot: int) -> f32 {
	multiplier: f32 = 1
	if KingdomHasTech(w, kingdom, .Irrigation) do multiplier *= 1.20
	if KingdomHasTech(w, kingdom, .FishingFlotillas) && TownIsCoastal(w, kingdom, townSlot) {
		multiplier *= 1.15
	}
	return multiplier
}

KingdomTechGrowthMultiplier :: proc(w: ^World, kingdom, townSlot: int) -> f32 {
	multiplier: f32 = 1
	if TownFindBuilding(w, kingdom, townSlot, .Granary) >= 0 do multiplier *= 1.10
	if KingdomHasTech(w, kingdom, .Metropolis) do multiplier *= 1.10
	return multiplier
}

KingdomTechWoodMultiplier :: proc(w: ^World, kingdom: int) -> f32 {
	if KingdomHasTech(w, kingdom, .Carpentry) do return 1.20
	return 1
}

KingdomTechBuildingCostMultiplier :: proc(w: ^World, kingdom: int) -> f32 {
	if KingdomHasTech(w, kingdom, .Masonry) do return 0.85
	return 1
}

KingdomTechBuildSpeedMultiplier :: proc(w: ^World, kingdom: int) -> f32 {
	if KingdomHasTech(w, kingdom, .Masonry) do return 1.20
	return 1
}

KingdomTechPathSpeedMultiplier :: proc(w: ^World, kingdom: int) -> f32 {
	multiplier: f32 = 1
	if KingdomHasTech(w, kingdom, .Roadworks) do multiplier *= 1.10
	if KingdomHasTech(w, kingdom, .BridgeProject) do multiplier *= 1.10
	return multiplier
}

KingdomTechBridgeBuildMultiplier :: proc(w: ^World, kingdom: int) -> f32 {
	multiplier: f32 = 1
	if KingdomHasTech(w, kingdom, .Bridgeworks) do multiplier *= 1.50
	return multiplier
}

KingdomTechFoundingCostMultiplier :: proc(w: ^World, kingdom: int) -> f32 {
	if KingdomHasTech(w, kingdom, .Charters) do return 0.80
	return 1
}

KingdomTechFoundingSettlerReduction :: proc(w: ^World, kingdom: int) -> int {
	if KingdomHasTech(w, kingdom, .Charters) do return 1
	return 0
}

KingdomTechConversionSpeedMultiplier :: proc(w: ^World, kingdom: int, kind: UnitKind) -> f32 {
	multiplier: f32 = 1
	if KingdomHasTech(w, kingdom, .Census) do multiplier *= 1.20
	if KingdomHasTech(w, kingdom, .Drill) && UnitIsWarrior(UnitTypeFromKind(kind)) do multiplier *= 1.20
	if KingdomHasTech(w, kingdom, .Muster) && kind == .CombatBuilder do multiplier *= 1.50
	return multiplier
}

KingdomTechWarriorHealthMultiplier :: proc(w: ^World, kingdom: int) -> f32 {
	if KingdomHasTech(w, kingdom, .Armory) do return 1.15
	return 1
}

KingdomTechWarriorDamageMultiplier :: proc(w: ^World, kingdom: int, kind: UnitKind) -> f32 {
	if KingdomHasTech(w, kingdom, .Armory) && UnitIsWarrior(UnitTypeFromKind(kind)) do return 1.10
	return 1
}

KingdomTechSiegeDamageMultiplier :: proc(w: ^World, kingdom: int, kind: UnitKind) -> f32 {
	if KingdomHasTech(w, kingdom, .Siegecraft) &&
		(kind == .Catapult || kind == .Giant || kind == .Mage) {
		return 1.25
	}
	return 1
}

KingdomTechBuildingHealthMultiplier :: proc(w: ^World, kingdom: int, kind: BuildingKind) -> f32 {
	multiplier: f32 = 1
	if KingdomHasTech(w, kingdom, .Fortification) &&
		(kind == .Wall || kind == .Watchtower || kind == .Cannon) {
		multiplier *= 1.25
	}
	if KingdomHasTech(w, kingdom, .Bridgeworks) && kind == .Bridge do multiplier *= 1.50
	return multiplier
}

KingdomTechBuildingKindCostMultiplier :: proc(w: ^World, kingdom: int, kind: BuildingKind) -> f32 {
	multiplier := KingdomTechBuildingCostMultiplier(w, kingdom)
	if KingdomHasTech(w, kingdom, .Fortification) &&
		(kind == .Wall || kind == .Watchtower || kind == .Cannon) {
		multiplier *= 0.80
	}
	return multiplier
}

KingdomTechGarrisonRatio :: proc(w: ^World, kingdom: int) -> f32 {
	if KingdomHasTech(w, kingdom, .Bureaucracy) do return 0.05
	return TOWN_GARRISON_RATIO
}

UnitMaxHealthFor :: proc(w: ^World, kingdom: int, type: UnitType) -> f32 {
	base := UnitDefaultHealth(type)
	if UnitIsWarrior(type) do base *= KingdomTechWarriorHealthMultiplier(w, kingdom)
	return base
}

UnitMaxHealth :: proc(w: ^World, slot: int) -> f32 {
	if slot < 0 || slot >= UNIT_CAPACITY || !w.unitUsed[slot] || w.units.type[slot] == nil {
		return 0
	}
	return UnitMaxHealthFor(w, w.units.kingdome[slot], w.units.type[slot])
}

BuildingMaxHealthFor :: proc(w: ^World, kingdom: int, type: BuildingType) -> f32 {
	return BuildingDefaultHealth(type)*KingdomTechBuildingHealthMultiplier(w, kingdom, BuildingKindOf(type))
}

BuildingMaxHealth :: proc(w: ^World, slot: int) -> f32 {
	if slot < 0 || slot >= BUILDING_CAPACITY || !w.buildingUsed[slot] do return 0
	return BuildingMaxHealthFor(w, w.buildings.kingdom[slot], w.buildings.type[slot])
}

UnitCanCrossWater :: proc(w: ^World, unitType: UnitType, kingdom: int) -> bool {
	switch _ in unitType {
	case Turtle:
		return true
	case Knight, Archer, Mage, Giant, Catapult, Rogue:
		return KingdomHasTech(w, kingdom, .SeaPower)
	case Villager, Builder, CombatBuilder, WaterCollector, Farmer, Explorer:
		if !KingdomHasTech(w, kingdom, .CoastalBoats) do return false
		return w.kingdoms[kingdom].coastalTownCount > 0
	}
	unreachable()
}

UnitOnWaterTile :: proc(w: ^World, unitSlot: int) -> bool {
	if unitSlot < 0 || unitSlot >= UNIT_CAPACITY || !w.unitUsed[unitSlot] do return false
	tileX := int(WorldWrapPosition(w.units.x[unitSlot], f32(w.maxX)))
	tileY := int(WorldWrapPosition(w.units.y[unitSlot], f32(w.maxY)))
	index := tileX*int(w.maxY)+tileY
	if slot := w.tileBuilding[index]; slot >= 0 && w.buildingUsed[slot] {
		if BuildingKindOf(w.buildings.type[slot]) == .Bridge do return false
	}
	if hazardKind, hasHazard := WorldHazardKindAt(w, tileX, tileY); hasHazard {
		switch hazardKind {
		case .Ice:
			return false
		case .Flood:
			return true
		case .None:
		}
	}
	tile := w.ground[tileX][tileY].type
	return TileIsDeepWater(tile)
}

UnitSeaSpeedMultiplier :: proc(w: ^World, unitSlot: int) -> f32 {
	unit := &w.units[unitSlot]
	if !UnitOnWaterTile(w, unitSlot) do return 1
	if UnitKindOf(unit.type) == .Turtle do return 1
	if !UnitCanCrossWater(w, unit.type, unit.kingdome) do return 1
	return 0.60
}

TownIsCoastal :: proc(w: ^World, kingdom, townSlot: int) -> bool {
	if !WorldTownExists(w, kingdom, townSlot) do return false
	town := &w.kingdoms[kingdom].towns[townSlot]
	if town.coastalCached &&
		town.coastalTerrainRevision == w.terrainRevision &&
		town.coastalAreaRadius == town.areaRadius &&
		town.coastalDistricts == town.districtCount {
		return town.coastal
	}

	minX, maxX, minY, maxY := TownAreaBounds(w, kingdom, townSlot)
	coastal := false
	for x in max(minX, 0)..=min(maxX, int(w.maxX)-1) {
		for y in max(minY, 0)..=min(maxY, int(w.maxY)-1) {
			if !TownPointInArea(w, kingdom, townSlot, x, y) do continue
			tile := w.ground[x][y].type
			if TileIsDeepWater(tile) {
				coastal = true
				break
			}
		}
		if coastal do break
	}

	town.coastal = coastal
	town.coastalCached = true
	town.coastalTerrainRevision = w.terrainRevision
	town.coastalAreaRadius = town.areaRadius
	town.coastalDistricts = town.districtCount
	return coastal
}

KingdomCoastalTownCount :: proc(w: ^World, kingdom: int) -> int {
	if kingdom < 0 || kingdom >= KINGDOMS_CAPACITY || !w.kingdomUsed[kingdom] do return 0
	count := 0
	for townSlot in 0..<TOWN_CAPACITY {
		if !w.kingdoms[kingdom].townUsed[townSlot] do continue
		if TownIsCoastal(w, kingdom, townSlot) do count += 1
	}
	return count
}

KingdomHasHarbor :: proc(w: ^World, kingdom: int) -> bool {
	if kingdom < 0 || kingdom >= KINGDOMS_CAPACITY || !w.kingdomUsed[kingdom] do return false
	for slot in 0..<BUILDING_CAPACITY {
		if !w.buildingUsed[slot] || w.buildings.kingdom[slot] != kingdom do continue
		if BuildingKindOf(w.buildings.type[slot]) == .Harbor do return true
	}
	return false
}

KingdomCoastalWoodRate :: proc(w: ^World, kingdom: int) -> f32 {
	if !KingdomHasTech(w, kingdom, .Harbor) do return 0
	rate: f32 = 0
	for townSlot in 0..<TOWN_CAPACITY {
		if !w.kingdoms[kingdom].townUsed[townSlot] do continue
		if !TownIsCoastal(w, kingdom, townSlot) do continue
		if TownFindBuilding(w, kingdom, townSlot, .Harbor) >= 0 do rate += 0.05
	}
	return rate
}

KingdomTechBlockadeDamage :: proc(w: ^World, kingdom, townSlot: int) -> f32 {
	town := &w.kingdoms[kingdom].towns[townSlot]
	if town.blockadeUntil <= w.simulationTime do return 0
	return 0.5
}
