package main

import "base:intrinsics"
import "core:math"
import rl "vendor:raylib"

TOWN_SIMULATION_STEP :: 0.25
// A long render/load frame must not trigger a burst of catch-up ticks.
WORLD_MAX_FRAME_DELTA :: 0.25
// Units update in alternating slices. Each slice receives dt*UNIT_UPDATE_SLICES
// so speeds and cooldowns stay the same while per-tick CPU drops by the same
// factor. Rendering interpolates across the full slice window.
UNIT_UPDATE_SLICES :: 2
// Towns use the same model for economy, growth and construction progress.
TOWN_UPDATE_SLICES :: 2
TOWN_ALARM_AREA_FACTOR :: 1.25
WORLD_DAY_LENGTH_SECONDS :: 7*60.0

// --- weather ---------------------------------------------------------------

SEASONS_PER_YEAR :: 4
WEATHER_MIN_SECONDS :: 90
WEATHER_MAX_SECONDS :: 180
WEATHER_RAMP_IN :: 25
WEATHER_RAMP_OUT :: 15
WEATHER_LIGHTNING_DECAY :: 2.5
GAS_CLOUD_WIND_DRIFT :: 0.8

Season :: enum u8 {
	Spring,
	Summer,
	Autumn,
	Winter,
}

WeatherKind :: enum u8 {
	Clear,
	Rain,
	Storm,
	Fog,
	Snow,
	Blizzard,
	Drought,
	Heatwave,
	Sandstorm,
	Ashfall,
}

WeatherState :: struct {
	kind:           WeatherKind,
	nextKind:       WeatherKind,
	value:          f32,
	duration:       f32,
	remaining:      f32,
	windX, windY:   f32,
	season:         Season,
	sequence:       u32,
	lightningTimer: f32,
	lightningFlash: f32,
}

WeatherEffects :: struct {
	food:            f32,
	water:           f32,
	growth:          f32,
	vision:          f32,
	move:            f32,
	fireSpread:      f32,
	fireIgnition:    f32,
	fireExtinguish:  f32,
	harbor:          f32,
	exposure:        f32,
}

WorldSeason :: proc(w: ^World) -> Season {
	return Season(w.dayNumber%SEASONS_PER_YEAR)
}

WorldWeatherEffects :: proc(w: ^World) -> WeatherEffects {
	full := WeatherEffects {
		food = 1,
		water = 1,
		growth = 1,
		vision = 1,
		move = 1,
		fireSpread = 1,
		fireIgnition = 1,
		fireExtinguish = 1,
		harbor = 1,
	}
	switch w.weather.kind {
	case .Clear:
	case .Rain:
		full = WeatherEffects {
			food = 1.15,
			water = 1.30,
			growth = 1.10,
			vision = 0.85,
			move = 0.92,
			fireSpread = 0.25,
			fireIgnition = 0.45,
			fireExtinguish = 2.0,
			harbor = 0.9,
		}
	case .Storm:
		full = WeatherEffects {
			food = 1.05,
			water = 1.25,
			growth = 0.95,
			vision = 0.65,
			move = 0.80,
			fireSpread = 0.10,
			fireIgnition = 0.25,
			fireExtinguish = 2.5,
			harbor = 0.5,
		}
	case .Fog:
		full = WeatherEffects {
			food = 0.95,
			growth = 0.95,
			vision = 0.50,
			move = 0.90,
			fireSpread = 0.70,
			fireIgnition = 0.90,
			fireExtinguish = 1.2,
			harbor = 0.9,
		}
	case .Snow:
		full = WeatherEffects {
			food = 0.82,
			water = 1.10,
			growth = 0.70,
			vision = 0.85,
			move = 0.78,
			fireSpread = 0.15,
			fireIgnition = 0.25,
			fireExtinguish = 2.0,
			harbor = 0.8,
			exposure = 0.0006,
		}
	case .Blizzard:
		full = WeatherEffects {
			food = 0.65,
			water = 0.90,
			growth = 0.00,
			vision = 0.45,
			move = 0.60,
			fireSpread = 0.00,
			fireIgnition = 0.00,
			fireExtinguish = 4.0,
			harbor = 0.3,
			exposure = 0.0018,
		}
	case .Drought:
		full = WeatherEffects {
			food = 0.75,
			water = 0.45,
			growth = 0.72,
			move = 0.95,
			fireSpread = 1.70,
			fireIgnition = 1.25,
			fireExtinguish = 0.7,
			harbor = 0.9,
			exposure = 0.0004,
		}
	case .Heatwave:
		full = WeatherEffects {
			food = 0.86,
			water = 0.72,
			growth = 0.85,
			vision = 0.95,
			move = 0.90,
			fireSpread = 1.40,
			fireIgnition = 1.20,
			fireExtinguish = 0.8,
			harbor = 0.9,
			exposure = 0.0012,
		}
	case .Sandstorm:
		full = WeatherEffects {
			food = 0.80,
			water = 0.90,
			growth = 0.80,
			vision = 0.45,
			move = 0.70,
			fireSpread = 0.80,
			fireIgnition = 0.70,
			fireExtinguish = 1.0,
			harbor = 0.5,
			exposure = 0.0020,
		}
	case .Ashfall:
		full = WeatherEffects {
			food = 0.80,
			water = 0.90,
			growth = 0.75,
			vision = 0.60,
			move = 0.90,
			fireSpread = 0.50,
			fireIgnition = 0.60,
			fireExtinguish = 1.2,
			harbor = 0.8,
			exposure = 0.0008,
		}
	}

	value := clamp(w.weather.value, 0, 1)
	return WeatherEffects {
		food = 1+(full.food-1)*value,
		water = 1+(full.water-1)*value,
		growth = 1+(full.growth-1)*value,
		vision = 1+(full.vision-1)*value,
		move = 1+(full.move-1)*value,
		fireSpread = 1+(full.fireSpread-1)*value,
		fireIgnition = 1+(full.fireIgnition-1)*value,
		fireExtinguish = 1+(full.fireExtinguish-1)*value,
		harbor = 1+(full.harbor-1)*value,
		exposure = full.exposure*value,
	}
}

WorldWeatherVisionFactor :: proc(w: ^World) -> f32 {
	return WorldWeatherEffects(w).vision
}

WorldWeatherMoveFactor :: proc(w: ^World) -> f32 {
	return WorldWeatherEffects(w).move
}

WorldWeatherPick :: proc(w: ^World, season: Season, current: WeatherKind) -> WeatherKind {
	weights: [WeatherKind]f32
	switch season {
	case .Spring:
		weights[.Clear] = 30
		weights[.Rain] = 40
		weights[.Storm] = 10
		weights[.Fog] = 20
	case .Summer:
		weights[.Clear] = 26
		weights[.Rain] = 14
		weights[.Storm] = 16
		weights[.Fog] = 6
		weights[.Heatwave] = 20
		weights[.Drought] = 18
	case .Autumn:
		weights[.Clear] = 24
		weights[.Rain] = 32
		weights[.Storm] = 20
		weights[.Fog] = 24
	case .Winter:
		weights[.Clear] = 18
		weights[.Rain] = 6
		weights[.Snow] = 42
		weights[.Blizzard] = 14
		weights[.Fog] = 20
	}
	if current != .Clear do weights[current] *= 0.12

	total: f32 = 0
	for kind in WeatherKind do total += weights[kind]
	if total <= 0 do return .Clear
	roll := WorldNoiseHash(int(w.weather.sequence), int(season)+13, w.seed+0x7EA5E)*total
	for kind in WeatherKind {
		roll -= weights[kind]
		if roll <= 0 do return kind
	}
	return .Clear
}

WorldWeatherTransition :: proc(w: ^World, kind: WeatherKind) {
	w.weather.kind = kind
	w.weather.sequence += 1
	w.weather.season = WorldSeason(w)

	duration := WEATHER_MIN_SECONDS+
		WorldNoiseHash(int(w.weather.sequence), 5, w.seed+0x71EA)*f32(WEATHER_MAX_SECONDS-WEATHER_MIN_SECONDS)
	switch kind {
	case .Clear:
		duration *= 1.25
	case .Storm, .Blizzard:
		duration *= 0.8
	case .Drought:
		duration *= 1.15
	case .Rain, .Fog, .Snow, .Heatwave, .Sandstorm, .Ashfall:
	}
	w.weather.duration = duration
	w.weather.remaining = duration
	w.weather.nextKind = WorldWeatherPick(w, w.weather.season, kind)

	speed: f32 = 0.03
	switch kind {
	case .Clear:
		speed = 0.03
	case .Rain:
		speed = 0.16
	case .Storm:
		speed = 0.50
	case .Fog:
		speed = 0.02
	case .Snow:
		speed = 0.14
	case .Blizzard:
		speed = 0.55
	case .Drought:
		speed = 0.10
	case .Heatwave:
		speed = 0.06
	case .Sandstorm:
		speed = 0.60
	case .Ashfall:
		speed = 0.15
	}
	angle := WorldNoiseHash(int(w.weather.sequence), 7, w.seed+0x31D)*6.2831853
	w.weather.windX = math.cos(angle)*speed
	w.weather.windY = math.sin(angle)*speed
	w.weather.lightningTimer = 1.5+WorldNoiseHash(int(w.weather.sequence), 9, w.seed+0x4A1)*3
}

WorldWeatherUpdate :: proc(w: ^World, deltaTime: f32) {
	if deltaTime <= 0 do return

	season := WorldSeason(w)
	if season != w.weather.season {
		newKind := WorldWeatherPick(w, season, w.weather.kind)
		WorldWeatherTransition(w, newKind)
	}
	w.weather.remaining = max(w.weather.remaining-deltaTime, 0)
	if w.weather.remaining <= 0 do WorldWeatherTransition(w, w.weather.nextKind)

	age := w.weather.duration-w.weather.remaining
	fadeIn := clamp(age/WEATHER_RAMP_IN, 0, 1)
	fadeOut := clamp(w.weather.remaining/WEATHER_RAMP_OUT, 0, 1)
	w.weather.value = min(fadeIn, fadeOut)

	if w.weather.kind == .Storm && w.weather.value > 0.3 {
		w.weather.lightningTimer -= deltaTime
		if w.weather.lightningTimer <= 0 {
			w.weather.lightningTimer = 1.5+
				WorldNoiseHash(int(w.simulationTime*4), int(w.weather.sequence), w.seed+0x11)*4
			w.weather.lightningFlash = 1
		}
	}
	w.weather.lightningFlash = max(w.weather.lightningFlash-deltaTime*WEATHER_LIGHTNING_DECAY, 0)

	weatherEffects := WorldWeatherEffects(w)
	active := w.weather.value > 0.2
	wet := active && (w.weather.kind == .Rain || w.weather.kind == .Storm)
	cold := active && (w.weather.kind == .Snow || w.weather.kind == .Blizzard)
	heat := active && (w.weather.kind == .Heatwave || w.weather.kind == .Drought ||
		w.weather.kind == .Sandstorm)
	eventBlizzard := w.environment.phase == .Active && w.environment.kind == .Blizzard

	for unitSlot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[unitSlot] || w.units.type[unitSlot] == nil do continue
		hidden := UnitHiddenInside(w, unitSlot)
		w.units.effects[unitSlot][.Wet] = wet && !hidden
		w.units.effects[unitSlot][.Chilled] = (cold || eventBlizzard) && !hidden
		w.units.effects[unitSlot][.HeatStressed] = heat && !hidden
		if hidden || weatherEffects.exposure <= 0 do continue

		tileX := int(WorldWrapPosition(w.units.x[unitSlot], f32(w.maxX)))
		tileY := int(WorldWrapPosition(w.units.y[unitSlot], f32(w.maxY)))
		tileData := WorldTileAt(w, tileX, tileY)
		climate := tileData.climate
		tile := tileData.type
		coldTile := climate == .Boreal || tile == .Tundra || tile == .Ice
		hotTile := climate == .Arid || climate == .Volcanic || tile == .Desert || tile == .Ash

		exposure := weatherEffects.exposure
		switch w.weather.kind {
		case .Snow:
			exposure = coldTile ? exposure*1.5 : 0
		case .Blizzard:
			exposure *= coldTile ? 1.5 : 0.7
		case .Drought:
			exposure = hotTile ? exposure : 0
		case .Heatwave:
			exposure *= hotTile ? 1.5 : 0.6
		case .Sandstorm:
			exposure *= hotTile ? 1.5 : 0.5
		case .Ashfall:
		case .Clear, .Rain, .Storm, .Fog:
			exposure = 0
		}
		if exposure <= 0 do continue
		damage := UnitMaxHealth(w, unitSlot)*exposure*deltaTime
		UnitApplyDamage(
			w,
			unitSlot,
			damage,
			w.units.x[unitSlot],
			w.units.y[unitSlot],
			.Weather,
		)
	}
}

// --- environment events -----------------------------------------------------

EventSeverity :: enum u8 {
	Minor,
	Moderate,
	Major,
	Cataclysm,
}

EnvironmentEventKind :: enum u8 {
	Wildfire,
	Flood,
	Drought,
	Blizzard,
	Earthquake,
	Eruption,
	Locusts,
	Hurricane,
	MeteorShower,
}

EventPhase :: enum u8 {
	None,
	Telegraph,
	Active,
}

EnvironmentEvent :: struct {
	kind:      EnvironmentEventKind,
	severity:  EventSeverity,
	phase:     EventPhase,
	remaining: f32,
	telegraph: f32,
	duration:  f32,
	centerX:   f32,
	centerY:   f32,
	radius:    f32,
	kingdom:   int,
	town:      int,
	tick:      f32,
	sequence:  u32,
}

EnvironmentEventName :: proc(kind: EnvironmentEventKind) -> cstring {
	switch kind {
	case .Wildfire:
		return "Wildfire"
	case .Flood:
		return "Flood"
	case .Drought:
		return "Drought"
	case .Blizzard:
		return "Blizzard"
	case .Earthquake:
		return "Earthquake"
	case .Eruption:
		return "Eruption"
	case .Locusts:
		return "Locusts"
	case .Hurricane:
		return "Hurricane"
	case .MeteorShower:
		return "Meteor Shower"
	}
	unreachable()
}

EnvironmentSeverityName :: proc(severity: EventSeverity) -> cstring {
	switch severity {
	case .Minor:
		return "Minor"
	case .Moderate:
		return "Moderate"
	case .Major:
		return "Major"
	case .Cataclysm:
		return "Cataclysm"
	}
	unreachable()
}

EnvironmentEventColor :: proc(kind: EnvironmentEventKind) -> rl.Color {
	switch kind {
	case .Wildfire:
		return rl.Color{232, 120, 58, 255}
	case .Flood:
		return rl.Color{92, 160, 220, 255}
	case .Drought:
		return rl.Color{214, 180, 96, 255}
	case .Blizzard:
		return rl.Color{180, 220, 244, 255}
	case .Earthquake:
		return rl.Color{168, 140, 112, 255}
	case .Eruption:
		return rl.Color{230, 86, 58, 255}
	case .Locusts:
		return rl.Color{150, 190, 90, 255}
	case .Hurricane:
		return rl.Color{90, 190, 200, 255}
	case .MeteorShower:
		return rl.Color{210, 150, 250, 255}
	}
	unreachable()
}

EnvironmentSeverityColor :: proc(severity: EventSeverity) -> rl.Color {
	switch severity {
	case .Minor:
		return rl.Color{168, 172, 160, 255}
	case .Moderate:
		return rl.Color{226, 196, 92, 255}
	case .Major:
		return rl.Color{232, 120, 72, 255}
	case .Cataclysm:
		return rl.Color{214, 92, 220, 255}
	}
	unreachable()
}

EnvironmentSeverityScale :: proc(severity: EventSeverity) -> f32 {
	switch severity {
	case .Minor:
		return 0.5
	case .Moderate:
		return 0.8
	case .Major:
		return 1.1
	case .Cataclysm:
		return 1.5
	}
	return 1
}

EnvironmentEventRadius :: proc(severity: EventSeverity) -> f32 {
	switch severity {
	case .Minor:
		return 3.5
	case .Moderate:
		return 5.5
	case .Major:
		return 7.5
	case .Cataclysm:
		return 9.5
	}
	return 5
}

EnvironmentTelegraphSeconds :: proc(severity: EventSeverity) -> f32 {
	switch severity {
	case .Minor:
		return 1.5
	case .Moderate:
		return 3
	case .Major:
		return 5
	case .Cataclysm:
		return 8
	}
	return 3
}

EnvironmentEventDuration :: proc(kind: EnvironmentEventKind, severity: EventSeverity) -> f32 {
	base: f32 = 12
	switch kind {
	case .Wildfire:
		base = 15
	case .Flood:
		base = 4
	case .Drought:
		base = 40
	case .Blizzard:
		base = 20
	case .Earthquake:
		base = 6
	case .Eruption:
		base = 16
	case .Locusts:
		base = 40
	case .Hurricane:
		base = 15
	case .MeteorShower:
		base = 10
	}
	return base*EnvironmentSeverityScale(severity)
}

EnvironmentEventTickSeconds :: proc(kind: EnvironmentEventKind) -> f32 {
	switch kind {
	case .Wildfire:
		return 0.8
	case .Blizzard:
		return 0.5
	case .Earthquake:
		return 1.2
	case .Eruption:
		return 0.9
	case .Hurricane:
		return 1.2
	case .MeteorShower:
		return 1.0
	case .Flood, .Drought, .Locusts:
		return 1.0
	}
	return 1
}

EnvironmentKingdomEra :: proc(w: ^World, kingdom: int) -> int {
	if kingdom < 0 || kingdom >= KINGDOMS_CAPACITY || !w.kingdomUsed[kingdom] do return 0
	best := 0
	for townSlot in 0..<TOWN_CAPACITY {
		if !w.kingdoms[kingdom].townUsed[townSlot] do continue
		best = max(best, TownEra(w, kingdom, townSlot))
	}
	return best
}

EnvironmentMaxEra :: proc(w: ^World) -> int {
	best := 0
	for kingdom in 0..<KINGDOMS_CAPACITY {
		if kingdom == NEUTRAL_KINGDOM do continue
		best = max(best, EnvironmentKingdomEra(w, kingdom))
	}
	return best
}

EnvironmentLeadingKingdom :: proc(w: ^World) -> int {
	best := -1
	bestTowns := -1
	bestCitizens := -1
	for kingdom in 0..<KINGDOMS_CAPACITY {
		if kingdom == NEUTRAL_KINGDOM || !w.kingdomUsed[kingdom] do continue
		towns := 0
		citizens := 0
		for townSlot in 0..<TOWN_CAPACITY {
			if !w.kingdoms[kingdom].townUsed[townSlot] do continue
			towns += 1
			citizens += w.kingdoms[kingdom].towns[townSlot].citizens
		}
		if towns > bestTowns || (towns == bestTowns && citizens > bestCitizens) {
			best = kingdom
			bestTowns = towns
			bestCitizens = citizens
		}
	}
	return best
}

EnvironmentPickTargetKingdom :: proc(w: ^World, severity: EventSeverity) -> int {
	maxEra := EnvironmentMaxEra(w)
	leader := EnvironmentLeadingKingdom(w)
	weights: [KINGDOMS_CAPACITY]f32
	total: f32 = 0
	for kingdom in 0..<KINGDOMS_CAPACITY {
		if kingdom == NEUTRAL_KINGDOM || !w.kingdomUsed[kingdom] do continue
		weight := 1+w.eventDebt[kingdom]
		if EnvironmentKingdomEra(w, kingdom) < maxEra do weight *= 0.55
		if severity == .Cataclysm && kingdom == leader do weight *= 2.0
		weights[kingdom] = weight
		total += weight
	}
	if severity >= .Major && w.eventLastMajorKingdom >= 0 &&
		w.eventLastMajorKingdom < KINGDOMS_CAPACITY {
		last := w.eventLastMajorKingdom
		total -= weights[last]
		weights[last] = 0
		if total <= 0 {
			weights[last] = 1
			total = 1
		}
	}
	if total <= 0 do return -1
	roll := WorldNoiseHash(int(w.eventSequence)+1, int(severity)+31, w.seed+0xE7E)*total
	for kingdom in 0..<KINGDOMS_CAPACITY {
		roll -= weights[kingdom]
		if weights[kingdom] > 0 && roll <= 0 do return kingdom
	}
	return -1
}

EnvironmentKindEligible :: proc(kind: EnvironmentEventKind, severity: EventSeverity) -> bool {
	switch severity {
	case .Minor:
		return kind == .Flood || kind == .Drought || kind == .Locusts
	case .Moderate:
		return kind == .Flood || kind == .Drought || kind == .Wildfire ||
			kind == .Blizzard || kind == .Locusts
	case .Major:
		return kind == .Wildfire || kind == .Blizzard || kind == .Earthquake ||
			kind == .Flood || kind == .Locusts
	case .Cataclysm:
		return kind == .Eruption || kind == .Hurricane || kind == .MeteorShower ||
			kind == .Earthquake
	}
	return false
}

EnvironmentKingdomHasCoastalTown :: proc(w: ^World, kingdom: int) -> bool {
	for townSlot in 0..<TOWN_CAPACITY {
		if !w.kingdoms[kingdom].townUsed[townSlot] do continue
		if TownIsCoastal(w, kingdom, townSlot) do return true
	}
	return false
}

EnvironmentPickKind :: proc(w: ^World, severity: EventSeverity, kingdom: int) -> EnvironmentEventKind {
	weights: [EnvironmentEventKind]f32
	for kind in EnvironmentEventKind {
		if !EnvironmentKindEligible(kind, severity) do continue
		if kind in w.eventBag do continue
		if kind == .Hurricane && !EnvironmentKingdomHasCoastalTown(w, kingdom) do continue
		weights[kind] = 10
	}
	weights[.Wildfire] *= 2.6
	weights[.Flood] *= 2.4
	weights[.Drought] *= 2.0
	weights[.Blizzard] *= 1.6
	weights[.Earthquake] *= 1.8
	weights[.Eruption] *= 1.6
	weights[.Locusts] *= 1.4
	weights[.Hurricane] *= 1.6
	weights[.MeteorShower] *= 1.6

	switch w.weather.kind {
	case .Rain, .Storm:
		weights[.Wildfire] *= 0.3
		weights[.Flood] *= 1.6
		weights[.Hurricane] *= 1.5
		weights[.Drought] *= 0.5
	case .Snow, .Blizzard:
		weights[.Wildfire] = 0
		weights[.Blizzard] *= 1.6
		weights[.Flood] *= 0.8
	case .Drought, .Heatwave:
		weights[.Wildfire] *= 1.8
		weights[.Drought] *= 1.6
		weights[.Flood] *= 0.5
		weights[.Hurricane] *= 0.5
	case .Clear, .Fog, .Sandstorm, .Ashfall:
	}

	total: f32 = 0
	for kind in EnvironmentEventKind do total += weights[kind]
	if total <= 0 {
		w.eventBag = {}
		return EnvironmentPickKind(w, severity, kingdom)
	}
	roll := WorldNoiseHash(int(w.eventSequence)+1, int(severity)+71, w.seed+0xBA6)*total
	for kind in EnvironmentEventKind {
		roll -= weights[kind]
		if weights[kind] > 0 && roll <= 0 do return kind
	}
	return .Flood
}

EnvironmentPickTown :: proc(w: ^World, kingdom: int, kind: EnvironmentEventKind) -> int {
	count := 0
	for townSlot in 0..<TOWN_CAPACITY {
		if !w.kingdoms[kingdom].townUsed[townSlot] do continue
		if kind == .Hurricane && !TownIsCoastal(w, kingdom, townSlot) do continue
		count += 1
	}
	if count <= 0 do return -1
	index := int(WorldNoiseHash(int(w.eventSequence)+1, count+3, w.seed+0x70A)*f32(count))
	for townSlot in 0..<TOWN_CAPACITY {
		if !w.kingdoms[kingdom].townUsed[townSlot] do continue
		if kind == .Hurricane && !TownIsCoastal(w, kingdom, townSlot) do continue
		if index <= 0 do return townSlot
		index -= 1
	}
	return -1
}

EnvironmentPickAnyTown :: proc(w: ^World, kingdom: int) -> int {
	count := 0
	for townSlot in 0..<TOWN_CAPACITY {
		if w.kingdoms[kingdom].townUsed[townSlot] do count += 1
	}
	if count <= 0 do return -1
	index := int(WorldNoiseHash(int(w.eventSequence)+1, count+9, w.seed+0x70B)*f32(count))
	for townSlot in 0..<TOWN_CAPACITY {
		if !w.kingdoms[kingdom].townUsed[townSlot] do continue
		if index <= 0 do return townSlot
		index -= 1
	}
	return -1
}

EnvironmentEventRevealed :: proc(w: ^World) -> bool {
	if w.environment.phase == .None do return false
	if w.observerKingdom < 0 do return true
	if w.environment.kingdom == w.observerKingdom do return true
	if w.environment.town >= 0 &&
		WorldTownExists(w, w.environment.kingdom, w.environment.town) {
		return FogTownDiscovered(w, w.environment.kingdom, w.environment.town)
	}
	return false
}

EnvironmentEventStart :: proc(w: ^World, severity: EventSeverity) {
	w.eventSequence += 1
	kingdom := EnvironmentPickTargetKingdom(w, severity)
	if kingdom < 0 do return

	kind := EnvironmentPickKind(w, severity, kingdom)
	town := EnvironmentPickTown(w, kingdom, kind)
	if town < 0 {
		kind = .Flood
		town = EnvironmentPickTown(w, kingdom, kind)
	}
	if town < 0 do town = EnvironmentPickAnyTown(w, kingdom)
	if town < 0 do return

	ref := &w.kingdoms[kingdom].towns[town]
	telegraph := EnvironmentTelegraphSeconds(severity)
	w.environment = EnvironmentEvent {
		kind = kind,
		severity = severity,
		phase = .Telegraph,
		remaining = telegraph,
		telegraph = telegraph,
		duration = EnvironmentEventDuration(kind, severity),
		centerX = f32(ref.x)+2,
		centerY = f32(ref.y)+2,
		radius = EnvironmentEventRadius(severity),
		kingdom = kingdom,
		town = town,
		sequence = w.eventSequence,
	}
	w.eventBag += {kind}
	w.eventDebt[kingdom] = 0
	if severity >= .Major do w.eventLastMajorKingdom = kingdom

	switch severity {
	case .Minor:
		w.eventMinorTimer = 70+WorldNoiseHash(int(w.eventSequence), 13, w.seed+0x2A1)*50
	case .Moderate:
		w.eventModerateTimer = 180+WorldNoiseHash(int(w.eventSequence), 17, w.seed+0x2A3)*120
	case .Major:
		w.eventMajorTimer = 420+WorldNoiseHash(int(w.eventSequence), 19, w.seed+0x2A5)*180
	case .Cataclysm:
		w.eventCataclysmTimer = 900+WorldNoiseHash(int(w.eventSequence), 23, w.seed+0x2A7)*600
		w.eventCataclysmCount += 1
	}
	w.eventGap = 45+WorldNoiseHash(int(w.eventSequence), 29, w.seed+0x2A9)*30
	WorldAlertAddEnvironment(w, &w.environment)
}

WorldEnvironmentUpdate :: proc(w: ^World, deltaTime: f32) {
	if deltaTime <= 0 do return
	maxEra := EnvironmentMaxEra(w)
	for kingdom in 0..<KINGDOMS_CAPACITY {
		if kingdom == NEUTRAL_KINGDOM || !w.kingdomUsed[kingdom] do continue
		trailing := EnvironmentKingdomEra(w, kingdom) < maxEra
		gain: f32 = (trailing ? 0.35 : 1.0)/60
		w.eventDebt[kingdom] = min(w.eventDebt[kingdom]+deltaTime*gain, 6)
	}

	w.eventGap = max(w.eventGap-deltaTime, 0)
	w.eventMinorTimer = max(w.eventMinorTimer-deltaTime, 0)
	w.eventModerateTimer = max(w.eventModerateTimer-deltaTime, 0)
	w.eventMajorTimer = max(w.eventMajorTimer-deltaTime, 0)
	w.eventCataclysmTimer = max(w.eventCataclysmTimer-deltaTime, 0)

	if w.environment.phase != .None {
		w.environment.remaining = max(w.environment.remaining-deltaTime, 0)
		switch w.environment.phase {
		case .Telegraph:
			if w.environment.remaining <= 0 {
				w.environment.phase = .Active
				w.environment.remaining = w.environment.duration
				w.environment.tick = 0
				EnvironmentEventActivate(w)
			}
		case .Active:
			EnvironmentEventTick(w, deltaTime)
			if w.environment.remaining <= 0 do EnvironmentEventEnd(w)
		case .None:
		}
		return
	}

	if w.eventGap > 0 do return

	severity: EventSeverity
	ready := false
	if w.eventCataclysmTimer <= 0 && w.eventCataclysmCount < 2 {
		if maxEra >= 2 {
			severity = .Cataclysm
			ready = true
		} else {
			w.eventCataclysmTimer = 30
		}
	}
	if !ready && w.eventMajorTimer <= 0 {
		severity = .Major
		ready = true
	}
	if !ready && w.eventModerateTimer <= 0 {
		severity = .Moderate
		ready = true
	}
	if !ready && w.eventMinorTimer <= 0 {
		severity = .Minor
		ready = true
	}
	if ready do EnvironmentEventStart(w, severity)
}

EnvironmentEventActivate :: proc(w: ^World) {
	e := &w.environment
	scale := EnvironmentSeverityScale(e.severity)
	switch e.kind {
	case .Wildfire:
		EnvironmentFireBurst(w, e.centerX, e.centerY, e.radius, 5+int(scale*6))
	case .Flood:
		WorldHazardSpawnCircle(
			w,
			e.centerX,
			e.centerY,
			e.radius,
			.Flood,
			20+10*scale,
			30+15*scale,
			u64(e.sequence)+0xF100,
		)
	case .Hurricane:
		WorldHazardSpawnCircle(
			w,
			e.centerX,
			e.centerY,
			e.radius,
			.Flood,
			25+12*scale,
			35+18*scale,
			u64(e.sequence)+0xF101,
		)
		EnvironmentDamageArea(
			w,
			e.centerX,
			e.centerY,
			e.radius,
			8*scale,
			30*scale,
			.Area,
		)
	case .Earthquake:
		EnvironmentDamageArea(
			w,
			e.centerX,
			e.centerY,
			e.radius,
			10*scale,
			70*scale,
			.Area,
		)
		DecorationBlastBurst(w, e.centerX, e.centerY, e.radius*0.8)
		WorldTerrainQuakeApply(w, e.centerX, e.centerY, e.radius, u64(e.sequence)+0x9E01)
	case .Eruption:
		EnvironmentDamageArea(
			w,
			e.centerX,
			e.centerY,
			e.radius,
			18*scale,
			110*scale,
			.Fire,
		)
		EnvironmentFireBurst(w, e.centerX, e.centerY, e.radius, 10+int(scale*8))
		DecorationBlastBurst(w, e.centerX, e.centerY, e.radius)
		WorldTerrainEruptionApply(w, e.centerX, e.centerY, e.radius, u64(e.sequence)+0x9E02)
	case .MeteorShower:
		EnvironmentMeteorImpact(w)
	case .Blizzard:
		WorldTerrainFreezeApply(w, e.centerX, e.centerY, e.radius*1.4, u64(e.sequence)+0x9E03)
	case .Drought:
		WorldTerrainDroughtApply(w, e.centerX, e.centerY, e.radius*1.6, u64(e.sequence)+0x9E04)
	case .Locusts:
	}
}

EnvironmentEventTick :: proc(w: ^World, deltaTime: f32) {
	e := &w.environment
	e.tick -= deltaTime
	if e.tick > 0 do return
	e.tick = EnvironmentEventTickSeconds(e.kind)
	scale := EnvironmentSeverityScale(e.severity)

	switch e.kind {
	case .Wildfire:
		EnvironmentFireBurst(w, e.centerX, e.centerY, e.radius, 2+int(scale*2))
		EnvironmentDamageArea(w, e.centerX, e.centerY, e.radius, 2*scale, 6*scale, .Fire)
	case .Blizzard:
		EnvironmentDamageArea(w, e.centerX, e.centerY, e.radius, 2*scale, 0, .Weather)
	case .Earthquake:
		EnvironmentDamageArea(w, e.centerX, e.centerY, e.radius, 4*scale, 35*scale, .Area)
	case .Eruption:
		EnvironmentDamageArea(w, e.centerX, e.centerY, e.radius, 8*scale, 70*scale, .Fire)
		EnvironmentFireBurst(w, e.centerX, e.centerY, e.radius, 2+int(scale*2))
		WorldTerrainLavaSpread(w, e.centerX, e.centerY, e.radius, u64(e.sequence)+0x9E11)
	case .Hurricane:
		EnvironmentDamageArea(w, e.centerX, e.centerY, e.radius, 5*scale, 25*scale, .Area)
	case .MeteorShower:
		EnvironmentMeteorImpact(w)
	case .Flood, .Drought, .Locusts:
	}
}

EnvironmentEventEnd :: proc(w: ^World) {
	w.environment.phase = .None
	w.environment.kingdom = -1
	w.environment.town = -1
	w.eventGap = max(w.eventGap, 25)
}

EnvironmentEventTownFactors :: proc(
	w: ^World,
	kingdom, town: int,
) -> (food, water, growth: f32) {
	food, water, growth = 1, 1, 1
	e := &w.environment
	if e.phase != .Active || e.kingdom != kingdom || e.town != town do return
	scale := EnvironmentSeverityScale(e.severity)
	switch e.kind {
	case .Drought:
		food = 1-0.35*scale
		water = 1-0.65*scale
		growth = 1-0.2*scale
	case .Locusts:
		food = 1-0.8*scale
		growth = 1-0.1*scale
	case .Blizzard:
		food = 1-0.2*scale
		if e.severity >= .Major do growth = 0
	case .Flood, .Wildfire, .Earthquake, .Eruption, .Hurricane, .MeteorShower:
	}
	food = clamp(food, 0.05, 1)
	water = clamp(water, 0.05, 1)
	growth = clamp(growth, 0, 1)
	return
}

EnvironmentFireBurst :: proc(w: ^World, x, y, radius: f32, count: int) {
	if count <= 0 do return
	salt := int(w.simulationTime*8)
	for i in 0..<count {
		angle := WorldNoiseHash(i, int(w.environment.sequence)+salt, w.seed+0x3A1)*6.2831853
		distance := radius*math.sqrt(
			WorldNoiseHash(i, int(w.environment.sequence)+salt+7, w.seed+0x3A3),
		)
		fx := WorldWrapPosition(x+math.cos(angle)*distance, f32(w.maxX))
		fy := WorldWrapPosition(y+math.sin(angle)*distance, f32(w.maxY))
		WorldFireIgnite(w, fx, fy, 1.0, 1.0)
	}
}

EnvironmentMeteorImpact :: proc(w: ^World) {
	e := &w.environment
	scale := EnvironmentSeverityScale(e.severity)
	angle := WorldNoiseHash(int(e.tick*17)+int(e.sequence), int(w.simulationTime*4), w.seed+0x4A1)*6.2831853
	distance := e.radius*math.sqrt(WorldNoiseHash(int(e.sequence), int(w.simulationTime*4), w.seed+0x4A3))
	x := WorldWrapPosition(e.centerX+math.cos(angle)*distance, f32(w.maxX))
	y := WorldWrapPosition(e.centerY+math.sin(angle)*distance, f32(w.maxY))
	EnvironmentDamageArea(w, x, y, 2.5+scale, 10*scale, 45*scale, .Fire)
	EnvironmentFireBurst(w, x, y, 2+scale, 3+int(scale*2))
	DecorationBlastBurst(w, x, y, 2+scale)
	WorldTerrainMeteorCrater(w, int(x), int(y), u64(e.sequence)+0x3E00)
}

EnvironmentDamageArea :: proc(
	w: ^World,
	x, y, radius, unitDamage, buildingDamage: f32,
	damageKind: DamageKind,
) {
	chunkSize := w.spatial.chunkSize
	if chunkSize <= 0 do return
	worldWidth := f32(w.maxX)
	worldHeight := f32(w.maxY)
	centerX := WorldWrapPosition(x, worldWidth)
	centerY := WorldWrapPosition(y, worldHeight)
	radiusSquared := radius*radius
	centerChunkX := int(centerX)/chunkSize
	centerChunkY := int(centerY)/chunkSize
	chunkRadius := int(radius)/chunkSize+1

	for offsetX in -chunkRadius..=chunkRadius {
		chunkX := WorldWrapCoordinate(centerChunkX+offsetX, w.spatial.chunksX)
		for offsetY in -chunkRadius..=chunkRadius {
			chunkY := WorldWrapCoordinate(centerChunkY+offsetY, w.spatial.chunksY)
			chunk := chunkX*w.spatial.chunksY+chunkY

			slot := w.spatial.unitHead[chunk]
			for slot >= 0 {
				next := w.spatial.unitNext[slot]
				if w.unitUsed[slot] && w.units.type[slot] != nil && !UnitHiddenInside(w, slot) {
					deltaX := WorldShortestWrappedDelta(w.units.x[slot]-centerX, worldWidth)
					deltaY := WorldShortestWrappedDelta(w.units.y[slot]-centerY, worldHeight)
					if deltaX*deltaX+deltaY*deltaY <= radiusSquared {
						UnitApplyDamage(w, slot, unitDamage, centerX, centerY, damageKind)
					}
				}
				slot = next
			}

			slot = w.spatial.buildingHead[chunk]
			for slot >= 0 {
				next := w.spatial.buildingNext[slot]
				if w.buildingUsed[slot] {
					distance, impactX, impactY := WarriorBuildingNearestPoint(
						w,
						centerX,
						centerY,
						slot,
					)
					if distance <= radius {
						EnvironmentDamageBuilding(w, slot, buildingDamage, impactX, impactY)
					}
				}
				slot = next
			}
		}
	}

	WorldDecorationAreaDamage(w, centerX, centerY, radius, buildingDamage*0.5)
}

EnvironmentDamageBuilding :: proc(w: ^World, slot: int, damage, impactX, impactY: f32) {
	if slot < 0 || slot >= BUILDING_CAPACITY || !w.buildingUsed[slot] || damage <= 0 do return
	if w.buildings.kingdom[slot] == NEUTRAL_KINGDOM do return
	BuildingHitBurst(w, slot, impactX, impactY)
	w.buildings.health[slot] -= damage
	if w.buildings.health[slot] > 0 do return
	wasBurning := BuildingOnFire(w, slot)
	BuildingSpawnDebris(w, slot, wasBurning)
	BuildingDestroyedBurst(w, slot)
	BuildingDespawn(w, slot, -1)
}

// Population growth is cohort-based: an era defines how many villagers arrive
// together and how long the next cohort takes. Supply and unconverted villagers
// speed up the countdown rather than changing the cohort size.
GROWTH_FOOD_PER_CITIZEN :: 0.025
GROWTH_MIN_SPEED :: 0.25
GROWTH_MAX_SPEED :: 1.25
GROWTH_VILLAGER_SPEED_BONUS :: 0.005
GROWTH_VILLAGER_SPEED_CAP :: 0.5
GROWTH_MAX_SPAWN_PER_TICK :: 32
// At the unit cap or in a fully packed town, retry the spawn later instead of
// scanning the whole town area every simulation tick.
TOWN_GROWTH_FAIL_COOLDOWN :: 2.0

WorldUpdate :: proc(w: ^World, deltaTime: f32) {
	if deltaTime <= 0 do return
	stepTime := min(deltaTime, WORLD_MAX_FRAME_DELTA)
	simStamp := ProfilerBegin("Sim")
	defer ProfilerEnd(simStamp)

	// Particles and gore run on the render clock so they stay smooth between
	// the coarse town simulation ticks.
	stamp := ProfilerBegin("Sim:Particles")
	WorldParticleUpdate(w, stepTime)
	ProfilerEnd(stamp)

	w.simulationAccumulator += stepTime
	for w.simulationAccumulator >= TOWN_SIMULATION_STEP {
		tickStamp := ProfilerBegin("Sim:Tick")
		w.simulationTime += TOWN_SIMULATION_STEP
		w.dayTime += TOWN_SIMULATION_STEP
		if w.dayTime >= f32(WORLD_DAY_LENGTH_SECONDS) {
			w.dayTime -= f32(WORLD_DAY_LENGTH_SECONDS)
			w.dayNumber += 1
		}
		stamp = ProfilerBegin("Sim:Weather")
		WorldWeatherUpdate(w, TOWN_SIMULATION_STEP)
		ProfilerEnd(stamp)
		stamp = ProfilerBegin("Sim:Environment")
		WorldEnvironmentUpdate(w, TOWN_SIMULATION_STEP)
		ProfilerEnd(stamp)
		stamp = ProfilerBegin("Sim:FlowFields")
		WorldFlowFieldUpdate(w)
		ProfilerEnd(stamp)
		stamp = ProfilerBegin("Sim:Units")
		WorldUnitUpdate(w, TOWN_SIMULATION_STEP)
		ProfilerEnd(stamp)
		stamp = ProfilerBegin("Sim:Buildings")
		WorldBuildingUpdate(w, TOWN_SIMULATION_STEP)
		ProfilerEnd(stamp)
		stamp = ProfilerBegin("Sim:Aegis")
		WorldAegisUpdate(w, TOWN_SIMULATION_STEP)
		ProfilerEnd(stamp)
		stamp = ProfilerBegin("Sim:Fire")
		WorldFireUpdate(w, TOWN_SIMULATION_STEP)
		ProfilerEnd(stamp)
		stamp = ProfilerBegin("Sim:TerrainAftermath")
		WorldTerrainAftermathUpdate(w, TOWN_SIMULATION_STEP)
		ProfilerEnd(stamp)
		stamp = ProfilerBegin("Sim:Lava")
		WorldTerrainLavaUpdate(w, TOWN_SIMULATION_STEP)
		ProfilerEnd(stamp)
		stamp = ProfilerBegin("Sim:Decorations")
		WorldDecorationUpdate(w, TOWN_SIMULATION_STEP)
		ProfilerEnd(stamp)
		stamp = ProfilerBegin("Sim:Blood")
		BloodUpdate(w, TOWN_SIMULATION_STEP)
		ProfilerEnd(stamp)
		stamp = ProfilerBegin("Sim:Controllers")
		WorldControllersUpdate(w, TOWN_SIMULATION_STEP)
		ProfilerEnd(stamp)
		stamp = ProfilerBegin("Sim:Kingdom")
		WorldKingdomUpdate(w, TOWN_SIMULATION_STEP)
		ProfilerEnd(stamp)
		stamp = ProfilerBegin("Sim:Hazards")
		WorldHazardUpdate(w, TOWN_SIMULATION_STEP)
		ProfilerEnd(stamp)
		stamp = ProfilerBegin("Sim:Gas")
		WorldGasCloudUpdate(w, TOWN_SIMULATION_STEP)
		ProfilerEnd(stamp)
		stamp = ProfilerBegin("Sim:Fog")
		if int(w.simulationTime/TOWN_SIMULATION_STEP)%FOG_UPDATE_INTERVAL == 0 {
			FogUpdate(w)
		}
		ProfilerEnd(stamp)
		w.simulationAccumulator -= TOWN_SIMULATION_STEP
		ProfilerEnd(tickStamp)
	}
	stamp = ProfilerBegin("Sim:Animation")
	WorldUnitAnimationUpdate(w, stepTime)
	ProfilerEnd(stamp)
	stamp = ProfilerBegin("Sim:GameEnd")
	WorldCheckGameEnd(w)
	ProfilerEnd(stamp)
}

WorldTimeOfDay :: proc(w: ^World) -> f32 {
	return w.dayTime*24/f32(WORLD_DAY_LENGTH_SECONDS)
}

WorldNightAmount :: proc(w: ^World) -> f32 {
	hour := WorldTimeOfDay(w)
	if hour < 4.5 || hour >= 22 do return 1
	if hour < 6.5 do return 1-(hour-4.5)/2
	if hour < 18.5 do return 0
	return (hour-18.5)/3.5
}

// Deep night is where the world is dark enough to shorten unit vision. Dusk
// and dawn ramp in and out, so the threshold keeps the change from flickering.
WorldIsNight :: proc(w: ^World) -> bool {
	return WorldNightAmount(w) >= 0.5
}

WorldTownExists :: proc(w: ^World, kingdomSlot, townSlot: int) -> bool {
	return kingdomSlot >= 0 && kingdomSlot < KINGDOM_SLOTS &&
		townSlot >= 0 && townSlot < TOWN_CAPACITY &&
		w.kingdomUsed[kingdomSlot] && w.kingdoms[kingdomSlot].townUsed[townSlot]
}

// Scan each town once, rather than repeating the proximity query per sleeper.
WorldTownAlarmUpdate :: proc(w: ^World) {
	for kingdom in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[kingdom] do continue
		for townSlot in 0..<TOWN_CAPACITY {
			if !w.kingdoms[kingdom].townUsed[townSlot] do continue
			town := &w.kingdoms[kingdom].towns[townSlot]
			town.alarmActive, town.threatX, town.threatY = TownHasNearbyEnemy(
				w,
				kingdom,
				townSlot,
			)
		}
	}
}

TownHasNearbyEnemy :: proc(
	w: ^World,
	kingdom, townSlot: int,
) -> (found: bool, threatX, threatY: int) {
	if !WorldTownExists(w, kingdom, townSlot) do return false, 0, 0
	chunkSize := w.spatial.chunkSize
	if chunkSize <= 0 || w.spatial.chunksX <= 0 || w.spatial.chunksY <= 0 do return false, 0, 0
	width, height := BuildingTileSize(TownHall{})

	for circleIndex in 0..<TownAreaCircleCount(w, kingdom, townSlot) {
		circleX, circleY, circleRadius := TownAreaCircle(w, kingdom, townSlot, circleIndex)
		centerX := f32(circleX)+f32(width-1)*0.5
		centerY := f32(circleY)+f32(height-1)*0.5
		radius := f32(circleRadius)*TOWN_ALARM_AREA_FACTOR
		chunkRadius := int((radius+f32(max(width, height)))/f32(chunkSize))+1
		centerChunkX, centerChunkY := int(centerX)/chunkSize, int(centerY)/chunkSize
		for offsetX in 0..<min(chunkRadius*2+1, w.spatial.chunksX) {
			chunkX := WorldWrapCoordinate(centerChunkX-chunkRadius+offsetX, w.spatial.chunksX)
			for offsetY in 0..<min(chunkRadius*2+1, w.spatial.chunksY) {
				chunkY := WorldWrapCoordinate(centerChunkY-chunkRadius+offsetY, w.spatial.chunksY)
				chunk := chunkX*w.spatial.chunksY+chunkY
				for unit := w.spatial.unitHead[chunk]; unit >= 0; unit = w.spatial.unitNext[unit] {
					if !w.unitUsed[unit] || UnitHiddenInside(w, unit) do continue
					if !KingdomAtWar(w, kingdom, w.units[unit].kingdome) do continue
					dx := math.abs(WorldShortestWrappedDelta(f32(int(w.units.x[unit]))-centerX, f32(w.maxX)))
					dy := math.abs(WorldShortestWrappedDelta(f32(int(w.units.y[unit]))-centerY, f32(w.maxY)))
					dx = max(0, dx-f32(width-1)*0.5)
					dy = max(0, dy-f32(height-1)*0.5)
					if dx*dx+dy*dy <= radius*radius {
						return true, int(w.units.x[unit]), int(w.units.y[unit])
					}
				}
			}
		}
	}
	return false, 0, 0
}

UnitUpdateSlice :: proc(w: ^World) -> int {
	return int(w.simulationTime/TOWN_SIMULATION_STEP)%UNIT_UPDATE_SLICES
}

// Hash the slot so contiguous spawn batches of one unit kind do not all land
// in the same slice.
UnitUpdateSliceOf :: proc(unitSlot: int) -> int {
	return int((u64(unitSlot)*0x9E3779B97F4A7C15)>>32)%UNIT_UPDATE_SLICES
}

// One tick of unit updates split by unit slot. Every worker keeps its own
// timing; shared town counters are updated atomically. Pathfinding, damage,
// construction and particles still share locks, which is the remaining
// serialization in this pass.
UnitLoopJob :: struct {
	w:         ^World,
	slice:     int,
	tick:      int,
	deltaTime: f32,
	kindTime:  [PARALLEL_MAX_CHUNKS][UnitKind]f64,
	kindCalls: [PARALLEL_MAX_CHUNKS][UnitKind]int,
}

UnitLoopChunk :: proc(ctx: rawptr, start, end, worker: int) {
	job := cast(^UnitLoopJob)ctx
	w := job.w
	for unitSlot in start..<end {
		if !w.unitUsed[unitSlot] do continue
		// A dormant villager must react as soon as its town is alarmed.
		if w.units.updateStride[unitSlot] > 1 {
			kingdomSlot := w.units[unitSlot].kingdome
			townSlot := w.units[unitSlot].town
			if WorldTownExists(w, kingdomSlot, townSlot) &&
				w.kingdoms[kingdomSlot].towns[townSlot].alarmActive {
				UnitWake(w, unitSlot)
			}
		}
		if UnitUpdateSliceOf(unitSlot) != job.slice do continue
		stride := int(w.units.updateStride[unitSlot])
		if stride > 1 && (job.tick/UNIT_UPDATE_SLICES)%stride != 0 do continue
		unitDelta := job.deltaTime*f32(UNIT_UPDATE_SLICES*stride)
		w.units.previousX[unitSlot] = w.units.x[unitSlot]
		w.units.previousY[unitSlot] = w.units.y[unitSlot]
		w.units.updateTime[unitSlot] = w.simulationTime
		w.units.updateInterval[unitSlot] = unitDelta
		w.units.decisionTimer[unitSlot] -= unitDelta
		w.units.decisionReady[unitSlot] = w.units.decisionTimer[unitSlot] <= 0
		if w.units.decisionReady[unitSlot] {
			jitter := 0.75+WorldNoiseHash(unitSlot, job.tick, 0xD3C1)*0.5
			w.units.decisionTimer[unitSlot] = CIVILIAN_DECISION_INTERVAL*jitter
		}
		unitKind := UnitKindOf(w.units[unitSlot].type)
		profileIndex := -1
		if profiler.enabled do profileIndex = profiler.unitKindIndex[unitKind]
		unitStart := f64(0)
		if profileIndex >= 0 do unitStart = rl.GetTime()
		UnitUpdateMilitaryAlarm(w, unitSlot)
		converting := false
		if _, isConverting := w.units[unitSlot].state.(StateConverting); isConverting {
			converting = true
			if !UnitUpdatePacificSafety(w, unitSlot, unitDelta) {
				UnitUpdateConverting(w, unitSlot, unitDelta)
			}
		}
		if !converting {
			switch _ in w.units[unitSlot].type {
			case Villager:
				UnitUpdateVillager(w, unitSlot, unitDelta)
			case Builder:
				UnitUpdateBuilder(w, unitSlot, unitDelta)
			case CombatBuilder:
				CombatBuilderUpdate(w, unitSlot, unitDelta)
			case WaterCollector:
				UnitUpdateWaterCollector(w, unitSlot, unitDelta)
			case Farmer:
				UnitUpdateFarmer(w, unitSlot, unitDelta)
			case Explorer:
				UnitUpdateExplorer(w, unitSlot, unitDelta)
			case Knight, Archer, Mage, Giant, Turtle, Catapult, Rogue:
				UnitUpdateWarrior(w, unitSlot, unitDelta)
			}
			if w.unitUsed[unitSlot] {
				BloodBleedTick(w, unitSlot, unitDelta)
				if w.units.previousX[unitSlot] != w.units.x[unitSlot] ||
					w.units.previousY[unitSlot] != w.units.y[unitSlot] {
					UnitWaterWake(w, unitSlot)
				}
			}
		}
		if w.unitUsed[unitSlot] {
			w.units.updateStride[unitSlot] = UnitDesiredUpdateStride(w, unitSlot)
		}
		if profileIndex < 0 do continue
		job.kindTime[worker][unitKind] += rl.GetTime()-unitStart
		job.kindCalls[worker][unitKind] += 1
	}
}

WorldUnitUpdate :: proc(w: ^World, deltaTime: f32) {
	SpatialCacheBeginTick(w)
	stamp := ProfilerBegin("Unit:Housing")
	WorldHousingUpdate(w)
	ProfilerEnd(stamp)
	stamp = ProfilerBegin("Unit:Alarm")
	WorldTownAlarmUpdate(w)
	ProfilerEnd(stamp)

	tick := int(w.simulationTime/TOWN_SIMULATION_STEP)
	slice := tick%UNIT_UPDATE_SLICES
	stamp = ProfilerBegin("Unit:Loop")
	for kingdomSlot in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[kingdomSlot] do continue
		for townSlot in 0..<TOWN_CAPACITY {
			if !w.kingdoms[kingdomSlot].townUsed[townSlot] do continue
			town := &w.kingdoms[kingdomSlot].towns[townSlot]
			town.buildersBySlice[slice] = 0
			town.waterCollectorsBySlice[slice] = 0
			town.farmersBySlice[slice] = 0
			town.villagersBySlice[slice] = 0
		}
	}

	job := UnitLoopJob {
		w         = w,
		slice     = slice,
		tick      = tick,
		deltaTime = deltaTime,
	}
	// Units of one slot only touch themselves, so the loop splits by slot. The
	// few cross-unit mutations (damage, construction work, spatial links) take
	// their own short locks.
	w.deferDespawn = true
	profiler.parallel = true
	ParallelFor(UNIT_CAPACITY, &job, UnitLoopChunk)
	profiler.parallel = false
	w.deferDespawn = false

	for slot in w.pendingDespawns {
		if w.unitUsed[slot] do UnitDespawn(w, slot)
	}
	clear(&w.pendingDespawns)

	for profileIndex, kind in profiler.unitKindIndex {
		if profileIndex < 0 do continue
		total := f64(0)
		calls := 0
		for worker in 0..<PARALLEL_MAX_CHUNKS {
			total += job.kindTime[worker][kind]
			calls += job.kindCalls[worker][kind]
		}
		if calls > 0 do ProfilerAddTotal(profileIndex, total, calls)
	}

	// Combine the latest worker sample from every slice. Each slice refreshes
	// its own entry when it runs, so a skipped unit keeps its last count.
	for kingdomSlot in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[kingdomSlot] do continue
		for townSlot in 0..<TOWN_CAPACITY {
			if !w.kingdoms[kingdomSlot].townUsed[townSlot] do continue
			town := &w.kingdoms[kingdomSlot].towns[townSlot]
			town.builders = 0
			town.waterCollectors = 0
			town.farmers = 0
			town.villagers = 0
			for sliceIndex in 0..<UNIT_UPDATE_SLICES {
				town.builders += town.buildersBySlice[sliceIndex]
				town.waterCollectors += town.waterCollectorsBySlice[sliceIndex]
				town.farmers += town.farmersBySlice[sliceIndex]
				town.villagers += town.villagersBySlice[sliceIndex]
			}
		}
	}
	ProfilerEnd(stamp)
	stamp = ProfilerBegin("Unit:Separation")
	WorldMeleeSeparation(w)
	ProfilerEnd(stamp)
}

TownUpdateSliceOf :: proc(kingdomSlot, townSlot: int) -> int {
	key := u64(kingdomSlot*TOWN_CAPACITY+townSlot)*0x9E3779B97F4A7C15
	return int(key>>32)%TOWN_UPDATE_SLICES
}

WorldKingdomUpdate :: proc(w: ^World, deltaTime: f32) {
	townSlice := int(w.simulationTime/TOWN_SIMULATION_STEP)%TOWN_UPDATE_SLICES
	townDelta := deltaTime*f32(TOWN_UPDATE_SLICES)
	stamp := ProfilerBegin("Kingdom:Towns")
	for kingdomSlot in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[kingdomSlot] do continue
		w.kingdoms[kingdomSlot].coastalTownCount = 0
		for townSlot in 0..<TOWN_CAPACITY {
			if !w.kingdoms[kingdomSlot].townUsed[townSlot] do continue
			coastalStamp := ProfilerBegin("Kingdom:Coastal")
			if TownIsCoastal(w, kingdomSlot, townSlot) {
				w.kingdoms[kingdomSlot].coastalTownCount += 1
			}
			ProfilerEnd(coastalStamp)
			if TownUpdateSliceOf(kingdomSlot, townSlot) == townSlice {
				KingdomTownUpdate(w, kingdomSlot, townSlot, townDelta)
			}
		}
	}
	ProfilerEnd(stamp)

	stamp = ProfilerBegin("Kingdom:Housing")
	WorldHousingUpdate(w)
	ProfilerEnd(stamp)
	stamp = ProfilerBegin("Kingdom:Effects")
	shortageEpoch := int(w.simulationTime / 5)
	for unitSlot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[unitSlot] do continue
		kingdomSlot := w.units[unitSlot].kingdome
		townSlot := w.units[unitSlot].town
		if !WorldTownExists(w, kingdomSlot, townSlot) {
			UnitClearTownEffects(w, unitSlot)
			continue
		}

		isHoused := UnitHome(w, unitSlot) >= 0
		UnitApplyTownEffects(w, unitSlot, isHoused, shortageEpoch, deltaTime)
	}
	ProfilerEnd(stamp)

	stamp = ProfilerBegin("Kingdom:Conversions")
	WorldConversionAssign(w)
	ProfilerEnd(stamp)
}

// Keep the existing slot-order housing entitlement, but give each housed citizen
// a persistent Home identity. Awake citizens (including soldiers) reserve capacity
// too, so sleep and the NoHome/regeneration effects cannot disagree.
WorldHousingUpdate :: proc(w: ^World) {
	remaining: [KINGDOM_SLOTS][TOWN_CAPACITY]int
	for home in 0..<BUILDING_CAPACITY {
		if !w.buildingUsed[home] do continue
		building := &w.buildings[home]
		if BuildingKindOf(building.type) != .Home || building.health <= 0 ||
			!WorldTownExists(w, building.kingdom, building.town) {
			continue
		}
		remaining[building.kingdom][building.town] += 1
	}

	for slot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[slot] do continue
		unit := &w.units[slot]
		eligible := false
		if WorldTownExists(w, unit.kingdome, unit.town) {
			eligible = remaining[unit.kingdome][unit.town] > 0
			if eligible do remaining[unit.kingdome][unit.town] -= 1
		}
		if !eligible || UnitHome(w, slot) < 0 do UnitReleaseHome(w, slot)
		if unit.sleepInside && UnitInsideHome(w, slot) < 0 do UnitSleepWake(w, slot)
	}

	freeHome: [KINGDOM_SLOTS][TOWN_CAPACITY]int
	for &kingdom in freeHome do for &town in kingdom do town = -1
	nextHome: [BUILDING_CAPACITY]int
	for home in 0..<BUILDING_CAPACITY {
		if !w.buildingUsed[home] do continue
		building := &w.buildings[home]
		resident := building.homeResident-1
		if resident >= 0 && resident < UNIT_CAPACITY && UnitHome(w, resident) == home do continue
		building.homeResident = 0
		if BuildingKindOf(building.type) != .Home || building.health <= 0 ||
			!WorldTownExists(w, building.kingdom, building.town) {
			continue
		}
		nextHome[home] = freeHome[building.kingdom][building.town]
		freeHome[building.kingdom][building.town] = home
	}
	for slot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[slot] || UnitHome(w, slot) >= 0 do continue
		unit := &w.units[slot]
		if !WorldTownExists(w, unit.kingdome, unit.town) do continue
		head := &freeHome[unit.kingdome][unit.town]
		// Only newly assigned citizens search; existing reservations never shuffle.
		best, previous, bestPrevious := -1, -1, -1
		bestDistance: f32 = 0
		for home := head^; home >= 0; home = nextHome[home] {
			dx := WorldShortestWrappedDelta(f32(w.buildings.x[home])+0.5-unit.x, f32(w.maxX))
			dy := WorldShortestWrappedDelta(f32(w.buildings.y[home])+0.5-unit.y, f32(w.maxY))
			distance := dx*dx+dy*dy
			if best < 0 || distance < bestDistance {
				best, bestPrevious, bestDistance = home, previous, distance
			}
			previous = home
		}
		if best < 0 do continue
		if bestPrevious < 0 {
			head^ = nextHome[best]
		} else {
			nextHome[bestPrevious] = nextHome[best]
		}
		UnitSleepWake(w, slot)
		unit.homeSlot = best
		w.buildings.homeResident[best] = slot+1
	}
}

// Assigns idle units to queued conversions. Runs once per simulation step over
// all units, so the cost stays linear in the number of units rather than towns.
WorldConversionAssign :: proc(w: ^World) {
	for unitSlot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[unitSlot] do continue
		unit := &w.units[unitSlot]
		if _, converting := unit.state.(StateConverting); converting do continue
		if !WorldTownExists(w, unit.kingdome, unit.town) do continue

		town := &w.kingdoms[unit.kingdome].towns[unit.town]
		if town.conversionCount == 0 do continue
		assignedOrder: WarriorOrder = WarriorIdle{}
		if state, warrior := unit.state.(StateWarrior); warrior {
			if state.retreating do continue
			assignedOrder = state.order
		}
		if builder, combatBuilder := unit.type.(CombatBuilder); combatBuilder {
			if builder.returning do continue
			assignedOrder = builder.order
		}
		// Controllers can remove an order after this tick's unit updates.
		switch order in assignedOrder {
		case WarriorAttack:
			if !WorldTownExists(w, order.kingdom, order.town) ||
				!town.attackOrders[order.kingdom][order.town] {
				continue
			}
		case WarriorDefend:
			if !WorldTownExists(w, order.kingdom, order.town) ||
				!town.defendOrders[order.kingdom][order.town] {
				continue
			}
		case WarriorIdle, WarriorGarrison:
		}
		if !UnitIsWarrior(unit.type) && UnitKindOf(unit.type) != .CombatBuilder {
			if town.alarmActive || UnitFindNearbyEnemy(w, unitSlot, FLEE_THREAT_RADIUS) >= 0 do continue
			if state, pacific := unit.state.(StatePacific); pacific && (state == .Hiding || state == .Fleeing) do continue
		}

		from := UnitKindOf(unit.type)
		for jobIndex in 0..<town.conversionCount {
			job := &town.conversions[jobIndex]
			if job.from != from || job.assigned >= job.remaining do continue

			building := TownFindBuilding(
				w,
				unit.kingdome,
				unit.town,
				UnitTrainingBuildingKind(job.to),
			)
			if building < 0 do continue
			buildingX := w.buildings.x[building]
			buildingY := w.buildings.y[building]
			width, height := BuildingTileSize(w.buildings[building].type)
			// Choose an access point reachable from the unit, not merely the
			// nearest walkable ring tile.
			accessX, accessY, found := BuildingFindWorkAccessPoint(
				w,
				buildingX,
				buildingY,
				width,
				height,
				unit.type,
				unit.kingdome,
				int(WorldWrapPosition(unit.x, f32(w.maxX))),
				int(WorldWrapPosition(unit.y, f32(w.maxY))),
			)
			if !found do continue

			job.assigned += 1
			UnitSleepWake(w, unitSlot)
			unit.state = StateConverting{
				to = job.to,
				building = building,
				accessX = accessX,
				accessY = accessY,
			}
			unit.pathReady = false
			break
		}
	}
}

KingdomTownUpdate :: proc(w: ^World, kingdomSlot, townSlot: int, deltaTime: f32) {
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	weather := WorldWeatherEffects(w)
	eventFood, eventWater, eventGrowth := EnvironmentEventTownFactors(w, kingdomSlot, townSlot)
	weather.food *= eventFood
	weather.water *= eventWater
	weather.growth *= eventGrowth

	workingFarmlands := min(town.farmlands, town.farmers)

	// Blockade is a visible town-level condition with a fixed multiplier.
	blockadeFactor: f32 = 1
	if town.blockadeUntil > w.simulationTime do blockadeFactor = 0.5

	town.foodPotential = 0
	if town.farmlands > 0 {
		town.foodPotential = town.farmlandOutput*f32(workingFarmlands)/f32(town.farmlands)
	}
	town.foodPotential *= KingdomTechFoodMultiplier(w, kingdomSlot, townSlot)*blockadeFactor*weather.food
	waterStamp := ProfilerBegin("Town:WaterAccess")
	waterAccess := TownWaterAccess(w, kingdomSlot, townSlot)
	ProfilerEnd(waterStamp)
	town.waterPotential =
		TownWaterCollectorOutput(waterAccess)*
		f32(town.waterCollectors)*KingdomTechWaterMultiplier(w, kingdomSlot, townSlot)*
		blockadeFactor*weather.water

	if TownFindBuilding(w, kingdomSlot, townSlot, .Harbor) >= 0 {
		town.wood += 0.05*deltaTime*weather.harbor
	}
	FishingFlotillaFx(w, kingdomSlot, townSlot)
	town.foodShortage = TownResourceShortage(town.foodPotential, town.citizens)
	town.waterShortage = TownResourceShortage(town.waterPotential, town.citizens)

	era := TownEra(w, kingdomSlot, townSlot)
	town.growthInterval = TOWN_ERAS[era].interval
	town.growthBatch = TownEffectiveBatch(w, kingdomSlot, townSlot)
	town.growthRate = f32(town.growthBatch)/town.growthInterval

	populationNeed := f32(town.citizens+town.growthBatch)*GROWTH_FOOD_PER_CITIZEN
	canGrow := town.foodPotential >= populationNeed && town.waterPotential >= populationNeed
	limitingSupply := min(town.foodPotential, town.waterPotential)
	coverage: f32 = 1
	if populationNeed > 0 {
		coverage = clamp(limitingSupply/populationNeed, 0, 1.5)
	}
	// A town always grows at least at the minimum speed, even with no food or
	// water at all, so a bad start cannot permanently strand it.
	speed := clamp(coverage, GROWTH_MIN_SPEED, GROWTH_MAX_SPEED)
	speed *= 1+min(GROWTH_VILLAGER_SPEED_CAP, f32(town.villagers)*GROWTH_VILLAGER_SPEED_BONUS)
	if town.blockadeUntil > w.simulationTime do speed *= 0.75
	speed *= weather.growth
	isNight := WorldIsNight(w)
	if isNight do speed = 0
	town.growthSpeed = speed

	town.growthCooldown -= deltaTime*speed
	if !isNight && weather.growth > 0.01 && town.growthCooldown <= 0 {
		if town.growthPending <= 0 do town.growthPending = town.growthBatch
		spawnNow := min(town.growthPending, GROWTH_MAX_SPAWN_PER_TICK)
		spawned := TownSpawnCitizens(w, kingdomSlot, townSlot, spawnNow)
		if spawned > 0 {
			town.growthPending -= spawned
			if kingdomSlot == w.observerKingdom {
				WorldAlertAddGrowth(w, kingdomSlot, townSlot, spawned)
			}
			if town.growthPending <= 0 {
				town.growthPending = 0
				town.growthCooldown = town.growthInterval
			} else {
				town.growthCooldown = 0
			}
		} else {
			town.growthCooldown = TOWN_GROWTH_FAIL_COOLDOWN
		}
	}

	if town.builders > 0 {
		town.constructionProgress += f32(town.builders)*deltaTime
		updateTick := int(w.simulationTime/TOWN_SIMULATION_STEP)/TOWN_UPDATE_SLICES
		phase := (updateTick+kingdomSlot*TOWN_CAPACITY+townSlot)%
			TOWN_CONSTRUCTION_ATTEMPT_INTERVAL
		if w.simulationTime >= town.constructionFailUntil &&
			town.constructionProgress >= 3 && phase == 0 {
			constructionStamp := ProfilerBegin("Town:Construction")
			if TownBuilderConstruct(w, kingdomSlot, townSlot, canGrow) {
				town.constructionProgress -= 3
				town.constructionFailUntil = 0
			} else {
				town.constructionProgress = min(town.constructionProgress, 3)
				town.constructionFailUntil = w.simulationTime+
					TOWN_CONSTRUCTION_FAIL_COOLDOWN
			}
			ProfilerEnd(constructionStamp)
		} else {
			town.constructionProgress = min(town.constructionProgress, 3)
		}
	}

	milestoneStamp := ProfilerBegin("Town:Milestone")
	TownMilestoneCheck(w, kingdomSlot, townSlot)
	ProfilerEnd(milestoneStamp)
}


TownResourceShortage :: proc(potential: f32, citizens: int) -> f32 {
	need := f32(citizens)*0.025
	if need <= 0 do return 0
	return clamp(1-potential/need, 0, 1)
}

// Each collector produces a baseline even with no fresh water in reach; nearby
// lakes and rivers add the rest. Island towns therefore keep growing, just on a
// smaller and more expensive water supply.
WATER_COLLECTOR_MAX_OUTPUT :: 0.20
WATER_COLLECTOR_DRY_OUTPUT :: 0.10

TownWaterCollectorOutput :: proc(waterAccess: f32) -> f32 {
	access := clamp(waterAccess, 0, 1)
	return WATER_COLLECTOR_DRY_OUTPUT+
		(WATER_COLLECTOR_MAX_OUTPUT-WATER_COLLECTOR_DRY_OUTPUT)*access
}

// Water farther than this cannot realistically supply a town, and scanning the
// whole world per town made the first simulation tick extremely slow.
TOWN_WATER_SEARCH_RADIUS :: 64

TownWaterAccess :: proc(w: ^World, kingdomSlot, townSlot: int) -> f32 {
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	if town.waterAccessCached && town.waterAccessTerrainRevision == w.terrainRevision {
		return town.waterAccess
	}

	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 do return 0

	centerX := town.x+2
	centerY := town.y+2
	radius := min(TOWN_WATER_SEARCH_RADIUS, min(worldWidth, worldHeight))
	nearestDistanceSquared: f32 = 0
	foundWater := false
	for offsetX in -radius..=radius {
		x := WorldWrapCoordinate(centerX+offsetX, worldWidth)
		for offsetY in -radius..=radius {
			y := WorldWrapCoordinate(centerY+offsetY, worldHeight)
			tileType := WorldTileAt(w, x, y).type
			if TILE_DEFS[tileType].water <= 0 do continue
			deltaX := f32(offsetX)
			deltaY := f32(offsetY)
			distanceSquared := deltaX*deltaX + deltaY*deltaY
			if !foundWater || distanceSquared < nearestDistanceSquared {
				nearestDistanceSquared = distanceSquared
				foundWater = true
			}
		}
	}

	town.waterAccess = 0
	if foundWater do town.waterAccess = 1/(1+math.sqrt(nearestDistanceSquared))
	town.waterAccessTerrainRevision = w.terrainRevision
	town.waterAccessCached = true
	return town.waterAccess
}

TownSpawnCitizen :: proc(w: ^World, kingdomSlot, townSlot: int, role: UnitType) -> int {
	if w.unitCount >= UNIT_CAPACITY do return -1
	if !WorldTownExists(w, kingdomSlot, townSlot) do return -1
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)

	// New villagers step out of the town hall door first.
	for offsetX in 0 ..= 1 {
		x := town.x+1+offsetX
		y := town.y+4
		if x < 0 || y < 0 || x >= worldWidth || y >= worldHeight do continue
		if !UnitValidTileType(role, WorldTileAt(w, x, y).type) || WorldTileOccupied(w, x, y) do continue
		if WorldUnitAtTile(w, x, y) do continue
		if unitSlot, ok := UnitSpawn(w, role, f32(x)+0.5, f32(y)+0.5, kingdomSlot, townSlot); ok {
			return unitSlot
		}
	}

	for radius in 1..=8 {
		minX := max(0, town.x-radius)
		maxX := min(worldWidth-1, town.x+4+radius)
		minY := max(0, town.y-radius)
		maxY := min(worldHeight-1, town.y+4+radius)
		for x in minX..=maxX {
			for y in minY..=maxY {
				if x >= town.x && x < town.x+4 && y >= town.y && y < town.y+4 do continue
				if !UnitValidTileType(role, WorldTileAt(w, x, y).type) || WorldTileOccupied(w, x, y) do continue
				if WorldUnitAtTile(w, x, y) do continue
				if unitSlot, ok := UnitSpawn(w, role, f32(x)+0.5, f32(y)+0.5, kingdomSlot, townSlot); ok {
					return unitSlot
				}
			}
		}
	}

	// A merged town can be much larger than the eight-tile ring above. Sweep the
	// whole compound area so cohorts are not lost when the old hall is crowded.
	areaMinX, areaMaxX, areaMinY, areaMaxY := TownAreaBounds(w, kingdomSlot, townSlot)
	minX := max(0, areaMinX)
	maxX := min(worldWidth-1, areaMaxX)
	minY := max(0, areaMinY)
	maxY := min(worldHeight-1, areaMaxY)
	for x in minX..=maxX {
		for y in minY..=maxY {
			if !TownPointInArea(w, kingdomSlot, townSlot, x, y) do continue
			if !UnitValidTileType(role, WorldTileAt(w, x, y).type) || WorldTileOccupied(w, x, y) do continue
			if WorldUnitAtTile(w, x, y) do continue
			if unitSlot, ok := UnitSpawn(w, role, f32(x)+0.5, f32(y)+0.5, kingdomSlot, townSlot); ok {
				return unitSlot
			}
		}
	}
	return -1
}

// Spawns as many villagers as there is room for, returning the number created.
// A partial batch is carried over by the caller instead of being lost.
TownSpawnCitizens :: proc(w: ^World, kingdomSlot, townSlot, count: int) -> int {
	spawned := 0
	for _ in 0..<count {
		if TownSpawnCitizen(w, kingdomSlot, townSlot, Villager{}) < 0 do break
		spawned += 1
	}
	return spawned
}

TOWN_INITIAL_VILLAGERS :: 8

TownSpawnInitialPopulation :: proc(w: ^World, kingdomSlot, townSlot: int) -> bool {
	for _ in 0..<TOWN_INITIAL_VILLAGERS {
		if TownSpawnCitizen(w, kingdomSlot, townSlot, Villager{}) < 0 do return false
	}
	return true
}
