package main

COMBAT_SITE_CAPACITY :: 256

// Combat builders are almost harmless: they only lash out when something
// hostile happens to stand on top of them.
COMBAT_BUILDER_DEFEND_RADIUS :: 1.8
COMBAT_BUILDER_DEFEND_CHANCE :: 0.5
COMBAT_BUILDER_RESCAN_SECONDS :: 1.5

// A player-placed combat building. It costs no wood and can sit anywhere,
// including unreachable water. Builders re-evaluate it whenever navigation
// changes, so a bridge chain can creep across a lake one tile at a time.
CombatSite :: struct {
	kind: BuildingKind,
	x, y: int,
	work: f32,
	kingdom, town: int,
}

CombatBuildingSeconds :: proc(kind: BuildingKind) -> f32 {
	#partial switch kind {
	case .Bridge:
		return 5
	case .Watchtower:
		return 8
	case .Cannon:
		return 12
	}
	return 6
}

// Player order: place a combat building anywhere in the world. No wood is
// paid and no town area is required.
TownStartCombatConstruction :: proc(
	w: ^World,
	kingdom_slot, town_slot: int,
	kind: BuildingKind,
	x, y: int,
) -> bool {
	if !TownCombatConstructionValid(w, kingdom_slot, town_slot, kind, x, y) do return false

	slot := -1
	for index in 0..<COMBAT_SITE_CAPACITY {
		if !w.combatSiteUsed[index] {
			slot = index
			break
		}
	}
	if slot < 0 do return false

	w.combatSites[slot] = CombatSite{kind = kind, x = x, y = y, kingdom = kingdom_slot, town = town_slot}
	w.combatSiteUsed[slot] = true
	// Combat builders rescan on navigation changes; a new order is one.
	w.navigationRevision += 1
	return true
}

TownCombatConstructionValid :: proc(
	w: ^World,
	kingdom_slot, town_slot: int,
	kind: BuildingKind,
	x, y: int,
) -> bool {
	if !WorldTownExists(w, kingdom_slot, town_slot) do return false
	if !BuildingIsCombat(kind) do return false
	town := &w.kingdoms[kingdom_slot].towns[town_slot]
	if !(kind in town.unlockedBuildings) do return false
	if !WorldBuildingValid(w, x, y, BuildingTypeFromKind(kind)) do return false
	if CombatSiteOverlaps(w, x, y, kind) do return false
	return !TownConstructionSiteOverlaps(w, x, y, kind)
}

CombatSiteOverlaps :: proc(w: ^World, x, y: int, kind: BuildingKind) -> bool {
	width, height := BuildingTileSize(BuildingTypeFromKind(kind))
	for slot in 0..<COMBAT_SITE_CAPACITY {
		if !w.combatSiteUsed[slot] do continue
		other_width, other_height := BuildingTileSize(BuildingTypeFromKind(w.combatSites.kind[slot]))
		if x < w.combatSites.x[slot]+other_width &&
			w.combatSites.x[slot] < x+width &&
			y < w.combatSites.y[slot]+other_height &&
			w.combatSites.y[slot] < y+height {
			return true
		}
	}
	return false
}

CombatSiteClear :: proc(w: ^World, kingdom_slot, town_slot: int) {
	changed := false
	for slot in 0..<COMBAT_SITE_CAPACITY {
		if !w.combatSiteUsed[slot] do continue
		if w.combatSites.kingdom[slot] != kingdom_slot || w.combatSites.town[slot] != town_slot {
			continue
		}
		w.combatSiteUsed[slot] = false
		changed = true
	}
	if changed do w.navigationRevision += 1
}

CombatSiteKingdomClear :: proc(w: ^World, kingdom_slot: int) {
	changed := false
	for slot in 0..<COMBAT_SITE_CAPACITY {
		if !w.combatSiteUsed[slot] || w.combatSites.kingdom[slot] != kingdom_slot do continue
		w.combatSiteUsed[slot] = false
		changed = true
	}
	if changed do w.navigationRevision += 1
}

// Builders work from any walkable tile on the ring around the footprint. An
// isolated bridge has no such tile until another bridge reaches it.
CombatSiteAccessPoint :: proc(
	w: ^World,
	site_slot: int,
	unit_type: UnitType,
) -> (int, int, bool) {
	if site_slot < 0 || site_slot >= COMBAT_SITE_CAPACITY || !w.combatSiteUsed[site_slot] {
		return 0, 0, false
	}

	site := &w.combatSites[site_slot]
	width, height := BuildingTileSize(BuildingTypeFromKind(site.kind))
	world_width := int(w.maxX)
	world_height := int(w.maxY)
	if world_width <= 0 || world_height <= 0 do return 0, 0, false

	for radius in 1..=6 {
		inner_min_x := site.x-radius+1
		inner_max_x := site.x+width-1+radius-1
		inner_min_y := site.y-radius+1
		inner_max_y := site.y+height-1+radius-1
		for x in site.x-radius ..= site.x+width-1+radius {
			for y in site.y-radius ..= site.y+height-1+radius {
				if x >= inner_min_x && x <= inner_max_x && y >= inner_min_y && y <= inner_max_y {
					continue
				}
				wrapped_x := WorldWrapCoordinate(x, world_width)
				wrapped_y := WorldWrapCoordinate(y, world_height)
				if !WorldTileWalkable(w, wrapped_x, wrapped_y, unit_type) do continue
				return wrapped_x, wrapped_y, true
			}
		}
	}
	return 0, 0, false
}

// Nearest reachable-looking site of the builder's town. The previous failure is
// skipped until navigation changes, which is when a new bridge may have made it
// reachable.
CombatSiteFindNearest :: proc(
	w: ^World,
	unit_slot: int,
	sequence: int,
	skip_slot: int,
	skip_revision: u64,
) -> (site_slot, access_x, access_y: int, found: bool) {
	unit := &w.units[unit_slot]
	world_width := f32(w.maxX)
	world_height := f32(w.maxY)
	unit_x := WorldWrapPosition(unit.x, world_width)
	unit_y := WorldWrapPosition(unit.y, world_height)
	seed := u64(unit_slot+sequence*1013)

	best_distance: f32 = 0
	best_score: f32 = -1
	for slot in 0..<COMBAT_SITE_CAPACITY {
		if !w.combatSiteUsed[slot] do continue
		if w.combatSites.kingdom[slot] != unit.kingdome || w.combatSites.town[slot] != unit.town {
			continue
		}
		if slot == skip_slot && skip_revision == w.navigationRevision do continue

		x, y, ok := CombatSiteAccessPoint(w, slot, unit.type)
		if !ok do continue

		site_width, site_height := BuildingTileSize(
			BuildingTypeFromKind(w.combatSites.kind[slot]),
		)
		center_x := f32(w.combatSites.x[slot])+f32(site_width)*0.5
		center_y := f32(w.combatSites.y[slot])+f32(site_height)*0.5
		delta_x := WorldShortestWrappedDelta(center_x-unit_x, world_width)
		delta_y := WorldShortestWrappedDelta(center_y-unit_y, world_height)
		distance_squared := delta_x*delta_x+delta_y*delta_y
		score := WorldNoiseHash(slot, sequence, seed)
		if found && (distance_squared > best_distance ||
			(distance_squared == best_distance && score <= best_score)) {
			continue
		}

		site_slot = slot
		access_x = x
		access_y = y
		best_distance = distance_squared
		best_score = score
		found = true
	}
	return
}

// Advances one builder's share of the site. Returns true when the structure is
// finished and the site can be released.
CombatSiteAdvance :: proc(w: ^World, site_slot: int, delta_time: f32) -> bool {
	if site_slot < 0 || site_slot >= COMBAT_SITE_CAPACITY || !w.combatSiteUsed[site_slot] {
		return true
	}

	site := &w.combatSites[site_slot]
	site.work += delta_time
	if site.work < CombatBuildingSeconds(site.kind) do return false

	if _, ok := BuildingSpawn(
		w,
		site.x,
		site.y,
		BuildingTypeFromKind(site.kind),
		site.kingdom,
		site.town,
	); !ok {
		// Keep the order alive; another builder may finish it later.
		return false
	}
	w.combatSiteUsed[site_slot] = false
	return true
}

CombatBuilderUpdate :: proc(w: ^World, unit_slot: int, delta_time: f32) {
	kingdom_slot := w.units[unit_slot].kingdome
	town_slot := w.units[unit_slot].town
	if !WorldTownExists(w, kingdom_slot, town_slot) do return

	if CombatBuilderDefend(w, unit_slot, delta_time) do return

	builder := &w.units[unit_slot].type.(CombatBuilder)
	state := &w.units[unit_slot].state.(StatePacific)

	if builder.site >= 0 && (builder.site >= COMBAT_SITE_CAPACITY || !w.combatSiteUsed[builder.site]) {
		builder.site = -1
		if state^ != .Roaming {
			state^ = .Roaming
			w.units[unit_slot].pathReady = false
		}
	}

	switch state^ {
	case .Roaming:
		if builder.scanTimer > 0 {
			builder.scanTimer -= delta_time
			UnitUpdateRoaming(w, unit_slot, delta_time)
			return
		}
		slot, access_x, access_y, found := CombatSiteFindNearest(
			w,
			unit_slot,
			builder.siteSequence,
			builder.failedSite,
			builder.failedRevision,
		)
		if !found {
			builder.scanTimer = COMBAT_BUILDER_RESCAN_SECONDS
			UnitUpdateRoaming(w, unit_slot, delta_time)
			return
		}
		builder.site = slot
		w.units[unit_slot].pathTargetX = access_x
		w.units[unit_slot].pathTargetY = access_y
		w.units[unit_slot].pathReady = false
		state^ = .ToConstruction
	case .ToConstruction:
		if builder.site < 0 {
			state^ = .Roaming
			w.units[unit_slot].pathReady = false
			break
		}
		if UnitMoveToTarget(w, unit_slot, delta_time) {
			state^ = .Building
			w.units[unit_slot].pathReady = false
		} else if !w.units[unit_slot].pathFound {
			// Unreachable for now: remember it until navigation changes.
			builder.failedSite = builder.site
			builder.failedRevision = w.navigationRevision
			builder.site = -1
			builder.siteSequence += 1
			state^ = .Roaming
			w.units[unit_slot].pathReady = false
		}
	case .Building:
		if builder.site < 0 {
			state^ = .Roaming
			w.units[unit_slot].pathReady = false
			break
		}
		if CombatSiteAdvance(w, builder.site, delta_time) {
			builder.site = -1
			builder.failedSite = -1
			builder.scanTimer = 0
			state^ = .Roaming
			w.units[unit_slot].pathReady = false
		}
	case .GoingHome, .Sleeping, .Traveling, .Working, .Returning:
		state^ = .Roaming
	}
}

// Combat builders never chase. If an enemy happens to be in reach they may
// swing once, then get back to work.
CombatBuilderDefend :: proc(w: ^World, unit_slot: int, delta_time: f32) -> bool {
	unit := &w.units[unit_slot]
	if unit.cooldown > 0 {
		unit.cooldown -= delta_time
		return false
	}

	roll := WorldNoiseHash(unit_slot, int(w.simulationTime*4), 0xC0B1)
	if roll >= COMBAT_BUILDER_DEFEND_CHANCE do return false

	target := CombatBuilderFindEnemy(w, unit_slot, COMBAT_BUILDER_DEFEND_RADIUS)
	if target < 0 do return false

	unit.cooldown = UnitDefaultCooldown(unit.type)
	w.units[target].health -= UnitDefaultDamage(unit.type)
	if w.units[target].health <= 0 do UnitDespawn(w, target)
	return true
}

CombatBuilderFindEnemy :: proc(w: ^World, unit_slot: int, radius: f32) -> int {
	unit := &w.units[unit_slot]
	world_width := f32(w.maxX)
	world_height := f32(w.maxY)
	chunk_size := w.spatial.chunkSize
	if chunk_size <= 0 || radius <= 0 do return -1

	center_chunk_x := int(unit.x)/chunk_size
	center_chunk_y := int(unit.y)/chunk_size
	chunk_radius := int(radius)/chunk_size+1
	best_slot := -1
	best_distance := radius*radius
	for offset_x in -chunk_radius..=chunk_radius {
		chunk_x := WorldWrapCoordinate(center_chunk_x+offset_x, w.spatial.chunksX)
		for offset_y in -chunk_radius..=chunk_radius {
			chunk_y := WorldWrapCoordinate(center_chunk_y+offset_y, w.spatial.chunksY)
			chunk := chunk_x*w.spatial.chunksY+chunk_y
			for other_slot := w.spatial.unitHead[chunk]; other_slot >= 0;
				other_slot = w.spatial.unitNext[other_slot] {
				if other_slot == unit_slot || !w.unitUsed[other_slot] do continue
				if !KingdomAtWar(w, unit.kingdome, w.units[other_slot].kingdome) do continue
				delta_x := WorldShortestWrappedDelta(w.units.x[other_slot]-unit.x, world_width)
				delta_y := WorldShortestWrappedDelta(w.units.y[other_slot]-unit.y, world_height)
				distance_squared := delta_x*delta_x+delta_y*delta_y
				if distance_squared > best_distance do continue
				best_distance = distance_squared
				best_slot = other_slot
			}
		}
	}
	return best_slot
}


