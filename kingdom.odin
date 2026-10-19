package main

TOWN_CAPACITY :: 100

Kingdom :: struct {
	capitalSlot: int,
	towns: #soa [TOWN_CAPACITY]Town,
	townUsed: [TOWN_CAPACITY]bool,
}

Town :: struct {
	x, y: int,
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

	bId, ok := BuildingSpawn(w, x, y, TownHall{})
	if !ok do return 0, false

	w.kingdoms[kingdomSlot].towns[i] = Town{
		x, y,
	}
	w.kingdoms[kingdomSlot].townUsed[i] = true
	return i, true
}
