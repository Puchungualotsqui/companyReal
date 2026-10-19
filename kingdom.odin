package main

import "core:math"

TOWN_CAPACITY :: 100

Kingdom :: struct {
	capitalSlot: int,
	towns: #soa [TOWN_CAPACITY]Town,
	townUsed: [TOWN_CAPACITY]bool,
}

Town :: struct {
	x, y: int,
	citizens: int,
	wood: f32,
	growthTimer, constructionProgress: f32,
	builders, waterCollectors, farmers: int,
	homes, farmlands: int,
	farmlandOutput: f32,
	foodPotential, waterPotential: f32,
	waterAccess: f32,
	waterAccessTerrainRevision: u64,
	waterAccessCached: bool,
	foodShortage, waterShortage: f32,
}

TownStart :: proc(w: ^World, x, y: int, kingdomSlot: int) -> (int, bool) {
	i := -1
	for slot in 0..<TOWN_CAPACITY {
		if !w.kingdoms[kingdomSlot].townUsed[slot] {
			i = slot
			break
		}
	}
	if i < 0 do return 0, false

	bId, ok := BuildingSpawn(w, x, y, TownHall{}, kingdomSlot, i)
	if !ok do return 0, false

	w.kingdoms[kingdomSlot].towns[i] = Town{
		x = x,
		y = y,
		citizens = 0,
		wood = 35,
	}
	w.kingdoms[kingdomSlot].townUsed[i] = true
	return i, true
}

KingdomChooseTownForUnit :: proc(w: ^World, kingdom_slot, unit_slot, destroyed_building_slot: int) -> int {
	world_width := f32(w.maxX)
	world_height := f32(w.maxY)
	unit_x := WorldWrapPosition(w.units[unit_slot].x, world_width)
	unit_y := WorldWrapPosition(w.units[unit_slot].y, world_height)
	building_width, building_height := BuildingTileSize(TownHall{})

	weights: [TOWN_CAPACITY]f32
	total_weight: f32 = 0
	for town_slot in 0..<TOWN_CAPACITY {
		if !w.kingdoms[kingdom_slot].townUsed[town_slot] do continue
		town := w.kingdoms[kingdom_slot].towns[town_slot]
		town_x := f32(town.x) + f32(building_width)*0.5
		town_y := f32(town.y) + f32(building_height)*0.5
		dx := WorldShortestWrappedDelta(town_x-unit_x, world_width)
		dy := WorldShortestWrappedDelta(town_y-unit_y, world_height)
		distance := math.sqrt(dx*dx + dy*dy)
		weights[town_slot] = 1.0 / (1.0 + distance)
		total_weight += weights[town_slot]
	}
	if total_weight == 0 do return -1

	roll := WorldNoiseHash(unit_slot, destroyed_building_slot, w.navigationRevision+u64(kingdom_slot)*101)*total_weight
	last_town := -1
	for town_slot in 0..<TOWN_CAPACITY {
		if !w.kingdoms[kingdom_slot].townUsed[town_slot] do continue
		last_town = town_slot
		if roll < weights[town_slot] do return town_slot
		roll -= weights[town_slot]
	}
	return last_town
}

KingdomAbsorb :: proc(w: ^World, defeated, destroyer, capital_town, capital_building: int) -> bool {
	if defeated < 0 || defeated >= KINGDOMS_CAPACITY || !w.kingdomUsed[defeated] ||
		destroyer < 0 || destroyer >= KINGDOMS_CAPACITY || !w.kingdomUsed[destroyer] ||
		defeated == destroyer {
		return false
	}

	town_mapping: [TOWN_CAPACITY]int
	reserved: [TOWN_CAPACITY]bool
	for town_slot in 0..<TOWN_CAPACITY {
		town_mapping[town_slot] = -1
	}

	for town_slot in 0..<TOWN_CAPACITY {
		if !w.kingdoms[defeated].townUsed[town_slot] || town_slot == capital_town do continue
		new_slot := -1
		for candidate in 0..<TOWN_CAPACITY {
			if !w.kingdoms[destroyer].townUsed[candidate] && !reserved[candidate] {
				new_slot = candidate
				break
			}
		}
		if new_slot < 0 do return false
		town_mapping[town_slot] = new_slot
		reserved[new_slot] = true
	}

	for old_slot in 0..<TOWN_CAPACITY {
		new_slot := town_mapping[old_slot]
		if new_slot < 0 do continue
		w.kingdoms[destroyer].towns[new_slot] = w.kingdoms[defeated].towns[old_slot]
		w.kingdoms[destroyer].townUsed[new_slot] = true
	}

	for unit_slot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[unit_slot] || w.units[unit_slot].kingdome != defeated do continue
		old_town := w.units[unit_slot].town
		w.units[unit_slot].kingdome = destroyer
		if old_town == capital_town {
			new_town := KingdomChooseTownForUnit(w, destroyer, unit_slot, capital_building)
			w.units[unit_slot].town = new_town
			if new_town >= 0 {
				w.kingdoms[destroyer].towns[new_town].citizens += 1
			}
		} else if old_town >= 0 && old_town < TOWN_CAPACITY {
			w.units[unit_slot].town = town_mapping[old_town]
		} else {
			w.units[unit_slot].town = -1
		}
	}

	for building_slot in 0..<BUILDING_CAPACITY {
		if building_slot == capital_building || !w.buildingUsed[building_slot] ||
			w.buildings[building_slot].kingdom != defeated {
			continue
		}
		old_town := w.buildings[building_slot].town
		w.buildings[building_slot].kingdom = destroyer
		if old_town >= 0 && old_town < TOWN_CAPACITY {
			w.buildings[building_slot].town = town_mapping[old_town]
		} else {
			w.buildings[building_slot].town = -1
		}
	}

	for town_slot in 0..<TOWN_CAPACITY {
		w.kingdoms[defeated].townUsed[town_slot] = false
		w.kingdoms[defeated].towns[town_slot].citizens = 0
	}
	w.kingdoms[defeated].capitalSlot = -1
	w.kingdomUsed[defeated] = false
	return true
}
