package main

import "core:fmt"
import rl "vendor:raylib"
import "d32"

// Debug stress world: every kingdom starts fully teched, with many towns, a
// large mixed army and a dense spread of buildings. Launched with -crazy_world.
CRAZY_WORLD_FLAG :: "-crazy_world"
// Fixed seed so profiling runs are comparable.
CRAZY_WORLD_SEED :: 0xC0FFEE_1234
// A 2048 map leaves room for 500 towns at the normal founding spacing while
// the dense unit spread stays inside each town's neighbourhood.
CRAZY_WORLD_MAP_SIZE :: 2048
CRAZY_WORLD_TOWNS_PER_KINGDOM :: 20
// Per-town multiplier tuned so the world spawns ~100k units.
CRAZY_WORLD_UNIT_SCALE :: 6.3
// Extra room around the town area so every planned unit finds a tile.
CRAZY_WORLD_UNIT_SPREAD_SLACK :: d32.Value(104_858) // 1.6 in Q16.16
// 1/pi in Q16.16, turning a planned unit count into a disc radius.
CRAZY_WORLD_INV_PI :: d32.Value(20_860)
CRAZY_WORLD_TOWN_MIN_RADIUS :: 24
CRAZY_WORLD_TOWN_MAX_RADIUS :: 420
CRAZY_WORLD_TOWN_SITE_ATTEMPTS :: 4096
CRAZY_WORLD_FOUNDING_SETTLERS :: 8
CRAZY_WORLD_BUILDING_ATTEMPTS :: 512
CRAZY_WORLD_UNIT_ATTEMPTS :: 48
CRAZY_WORLD_INITIAL_WOOD :: 4000
CRAZY_WORLD_INITIAL_INSIGHT :: 500
CRAZY_WORLD_DAY_NUMBER :: 90

CrazyWorldBuilding :: struct {
	kind:  BuildingKind,
	count: int,
}

CRAZY_WORLD_BUILDINGS := [?]CrazyWorldBuilding{
	{.Home, 10},
	{.Farmland, 8},
	{.ArcheryRange, 1},
	{.MagicSchool, 1},
	{.GiantPen, 1},
	{.SiegeWorkshop, 1},
	{.TurtlePen, 1},
	{.ThievesGuild, 1},
	{.DistrictHall, 1},
	{.Granary, 1},
	{.Harbor, 1},
	{.GiantMortar, 1},
	{.AlchemistWorkshop, 1},
	{.FireworksGuild, 1},
	{.StarfallSpire, 1},
	{.Cannon, 2},
	{.Watchtower, 2},
	{.Wall, 8},
	{.Bridge, 1},
	{.Path, 12},
}

CrazyWorldUnits :: struct {
	kind:  UnitKind,
	count: int,
}

CRAZY_WORLD_UNITS := [?]CrazyWorldUnits{
	{.Villager, 30},
	{.Builder, 16},
	{.WaterCollector, 12},
	{.Farmer, 12},
	{.Explorer, 4},
	{.CombatBuilder, 10},
	{.Knight, 24},
	{.Archer, 18},
	{.Mage, 10},
	{.Giant, 5},
	{.Turtle, 4},
	{.Catapult, 5},
	{.Rogue, 8},
}


WorldCrazyWorldPopulate :: proc(w: ^World) {
	start := rl.GetTime()
	phaseStart := start
	if PROFILING_ENABLED do ProfilerWrite("CRAZYWORLD generation\n")

	for kingdom in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[kingdom] do continue
		w.kingdoms[kingdom].insight = CRAZY_WORLD_INITIAL_INSIGHT
		for tech in CrownTech {
			_ = KingdomUnlockTech(w, kingdom, tech)
		}
	}
	CrazyWorldLogPhase("techs", &phaseStart)

	for kingdom in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[kingdom] do continue
		for townSlot in 0..<TOWN_CAPACITY {
			if w.kingdoms[kingdom].townUsed[townSlot] {
				CrazyWorldAdvanceTown(w, kingdom, townSlot)
			}
		}
	}
	CrazyWorldLogPhase("advance towns", &phaseStart)

	for kingdom in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[kingdom] do continue
		CrazyWorldFoundTowns(w, kingdom)
	}
	CrazyWorldLogPhase("found towns", &phaseStart)

	for kingdom in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[kingdom] do continue
		for townSlot in 0..<TOWN_CAPACITY {
			if !w.kingdoms[kingdom].townUsed[townSlot] do continue
			CrazyWorldPlaceBuildings(w, kingdom, townSlot)
		}
	}
	CrazyWorldLogPhase("buildings", &phaseStart)

	for kingdom in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[kingdom] do continue
		for townSlot in 0..<TOWN_CAPACITY {
			if !w.kingdoms[kingdom].townUsed[townSlot] do continue
			CrazyWorldSpawnUnits(w, kingdom, townSlot)
		}
	}
	CrazyWorldLogPhase("units", &phaseStart)

	w.dayNumber = CRAZY_WORLD_DAY_NUMBER
	w.simulationTick = u64(CRAZY_WORLD_DAY_NUMBER*WORLD_DAY_LENGTH_SECONDS/TOWN_SIMULATION_STEP)
	w.simulationTime = f32(f64(w.simulationTick)*TOWN_SIMULATION_STEP)
	WorldConstructionChanged(w)
	FogUpdate(w)
	CrazyWorldLogPhase("fog", &phaseStart)

	if PROFILING_ENABLED {
		buffer: [128]u8
		ProfilerWrite(
			fmt.bprintf(
				buffer[:],
				"  %s = %d ms (units=%d)\n",
				"total",
				int((rl.GetTime()-start)*1000),
				w.unitCount,
			),
		)
	}
}

CrazyWorldLogPhase :: proc(name: cstring, start: ^f64) {
	now := rl.GetTime()
	if PROFILING_ENABLED {
		buffer: [128]u8
		ProfilerWrite(
			fmt.bprintf(buffer[:], "  %s = %d ms\n", name, int((now-start^)*1000)),
		)
	}
	start^ = now
}

CrazyWorldAdvanceTown :: proc(w: ^World, kingdom, townSlot: int) {
	town := &w.kingdoms[kingdom].towns[townSlot]
	town.wood = d32.FromInt(CRAZY_WORLD_INITIAL_WOOD)
	town.milestonesEarned = TOWN_MILESTONE_TIER_COUNT
	for town.milestonesChosen < TOWN_MILESTONE_TIER_COUNT {
		option := (townSlot+town.milestonesChosen)%2
		_ = TownChooseMilestone(w, kingdom, townSlot, option)
	}
	for kind in BuildingKind do town.unlockedBuildings |= {kind}
	for kind in UnitKind do town.unlockedUnits |= {kind}
	town.waterAccessCached = false
	town.coastalCached = false
}

CrazyWorldFoundTowns :: proc(w: ^World, kingdom: int) {
	capital := w.kingdoms[kingdom].capitalSlot
	if capital < 0 do return
	town := &w.kingdoms[kingdom].towns[capital]
	anchorX := town.x+2
	anchorY := town.y+2
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)

	for _ in 1..<CRAZY_WORLD_TOWNS_PER_KINGDOM {
		newSlot := KingdomFreeTownSlot(w, kingdom)
		if newSlot < 0 do break

		for attempt in 0..<CRAZY_WORLD_TOWN_SITE_ATTEMPTS {
			turns := d32.FromRatio(
				i32(WorldNoiseHashInt(attempt, kingdom*31+1, w.seed+0x70A1)),
				1_000_000,
			)
			distance := d32.Add(
				d32.FromInt(CRAZY_WORLD_TOWN_MIN_RADIUS),
				d32.Mul(
					d32.FromRatio(
						i32(WorldNoiseHashInt(attempt, kingdom*31+2, w.seed+0x70A2)),
						1_000_000,
					),
					d32.FromInt(CRAZY_WORLD_TOWN_MAX_RADIUS-CRAZY_WORLD_TOWN_MIN_RADIUS),
				),
			)
			sine, cosine := d32.SinCos(turns)
			x := WorldWrapCoordinate(
				anchorX+int(d32.ToInt(d32.Mul(cosine, distance))),
				worldWidth,
			)
			y := WorldWrapCoordinate(
				anchorY+int(d32.ToInt(d32.Mul(sine, distance))),
				worldHeight,
			)
			if !WorldBuildingValid(w, x, y, TownHall{}) do continue
			if !CrazyWorldTownSiteFree(w, x, y) do continue
			if !TownFound(w, kingdom, x, y, CRAZY_WORLD_FOUNDING_SETTLERS) do continue
			CrazyWorldAdvanceTown(w, kingdom, newSlot)
			break
		}
	}
}

CrazyWorldTownSiteFree :: proc(w: ^World, x, y: int) -> bool {
	worldWidthRaw := i64(w.maxX)*d32.SCALE
	worldHeightRaw := i64(w.maxY)*d32.SCALE
	minimumRaw := i64(TOWN_FOUNDING_MIN_DISTANCE)*d32.SCALE
	minimumSquared := u64(minimumRaw*minimumRaw)
	candidateX := d32.FromInt(i32(x))
	candidateY := d32.FromInt(i32(y))
	for kingdom in 0..<KINGDOM_SLOTS {
		if !w.kingdomUsed[kingdom] do continue
		for townSlot in 0..<TOWN_CAPACITY {
			if !w.kingdoms[kingdom].townUsed[townSlot] do continue
			other := &w.kingdoms[kingdom].towns[townSlot]
			distanceSquared, valid := d32.WrappedDistanceSquared(
				d32.FromInt(i32(other.x+2)),
				d32.FromInt(i32(other.y+2)),
				candidateX,
				candidateY,
				worldWidthRaw,
				worldHeightRaw,
			)
			if !valid do continue
			if distanceSquared < minimumSquared do return false
		}
	}
	return true
}

CrazyWorldPlaceBuildings :: proc(w: ^World, kingdom, townSlot: int) {
	sequence := kingdom*TOWN_CAPACITY*97+townSlot*37
	for plan in CRAZY_WORLD_BUILDINGS {
		for _ in 0..<plan.count {
			CrazyWorldPlaceBuilding(w, kingdom, townSlot, plan.kind, &sequence)
		}
	}
}

CrazyWorldPlaceBuilding :: proc(
	w: ^World,
	kingdom, townSlot: int,
	kind: BuildingKind,
	sequence: ^int,
) {
	town := &w.kingdoms[kingdom].towns[townSlot]
	buildingType := BuildingTypeFromKind(kind)
	radius := d32.FromInt(i32(town.areaRadius))
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)

	for _ in 0..<CRAZY_WORLD_BUILDING_ATTEMPTS {
		seq := sequence^
		sequence^ += 1
		turns := d32.FromRatio(
			i32(WorldNoiseHashInt(seq, kingdom*97+townSlot, w.seed+0xB011)),
			1_000_000,
		)
		radiusFraction := d32.FromRatio(
			i32(WorldNoiseHashInt(seq, kingdom*97+townSlot+1, w.seed+0xB012)),
			1_000_000,
		)
		sine, cosine := d32.SinCos(turns)
		distance := d32.Mul(d32.Sqrt(radiusFraction), radius)
		x := WorldWrapCoordinate(
			town.x+2+int(d32.ToInt(d32.Mul(cosine, distance))),
			worldWidth,
		)
		y := WorldWrapCoordinate(
			town.y+2+int(d32.ToInt(d32.Mul(sine, distance))),
			worldHeight,
		)
		if !TownBuildingInArea(w, kingdom, townSlot, x, y, buildingType) do continue
		if !TownBuildingValid(w, kingdom, x, y, buildingType) do continue
		if _, ok := BuildingSpawn(w, x, y, buildingType, kingdom, townSlot); ok {
			return
		}
	}
}

CrazyWorldSpawnUnits :: proc(w: ^World, kingdom, townSlot: int) {
	for plan in CRAZY_WORLD_UNITS {
		CrazyWorldSpawnUnitKind(
			w,
			kingdom,
			townSlot,
			plan.kind,
			int(f32(plan.count)*CRAZY_WORLD_UNIT_SCALE+0.5),
		)
	}
}

CrazyWorldSpawnUnitKind :: proc(
	w: ^World,
	kingdom, townSlot: int,
	kind: UnitKind,
	count: int,
) {
	town := &w.kingdoms[kingdom].towns[townSlot]
	role := UnitTypeFromKind(kind)
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	// The plan is dense: spread units over a disc that is large enough to hold
	// them at one unit per tile instead of cramming the town area.
	spread := d32.Mul(
		d32.Sqrt(d32.Mul(d32.FromInt(i32(max(count, 1))), CRAZY_WORLD_INV_PI)),
		CRAZY_WORLD_UNIT_SPREAD_SLACK,
	)
	radius := d32.FromInt(i32(town.areaRadius))
	if spread < radius do spread = radius
	seed := w.seed ~
		u64(kingdom*TOWN_CAPACITY+townSlot+1)*0x9E3779B97F4A7C15 ~
		(u64(kind)+1)*0xBF58476D1CE4E5B9

	for index in 0..<count {
		for attempt in 0..<CRAZY_WORLD_UNIT_ATTEMPTS {
			seq := index*CRAZY_WORLD_UNIT_ATTEMPTS+attempt
			turns := d32.FromRatio(
				i32(WorldNoiseHashInt(seq, kingdom*131+townSlot*7+1, seed+11)),
				1_000_000,
			)
			radiusFraction := d32.FromRatio(
				i32(WorldNoiseHashInt(seq, kingdom*131+townSlot*7+2, seed+23)),
				1_000_000,
			)
			sine, cosine := d32.SinCos(turns)
			distance := d32.Mul(d32.Sqrt(radiusFraction), spread)
			x := WorldWrapCoordinate(
				town.x+2+int(d32.ToInt(d32.Mul(cosine, distance))),
				worldWidth,
			)
			y := WorldWrapCoordinate(
				town.y+2+int(d32.ToInt(d32.Mul(sine, distance))),
				worldHeight,
			)
			if !UnitValidTileType(role, w.ground[x][y].type) do continue
			if WorldTileOccupied(w, x, y) do continue
			if WorldUnitAtTile(w, x, y) do continue
			if _, ok := UnitSpawn(w, role, TileCenterPosition(x), TileCenterPosition(y), kingdom, townSlot); ok {
				break
			}
		}
	}
}
