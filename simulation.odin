package main

import "base:intrinsics"
import "core:fmt"
import "core:math"
import slices "core:slice"
import rl "vendor:raylib"
import "d32"

TOWN_SIMULATION_STEP :: 0.25
// A long render/load frame must not trigger a burst of catch-up ticks.
WORLD_MAX_FRAME_DELTA :: 0.25
WORLD_HASH_INTERVAL :: 16

// Units update in alternating slices. Each slice receives dt*UNIT_UPDATE_SLICES
// so speeds and cooldowns stay the same while per-tick CPU drops by the same
// factor. Rendering interpolates across the full slice window.
UNIT_UPDATE_SLICES :: 2
// Towns use the same model for economy, growth and construction progress.
TOWN_UPDATE_SLICES :: 2
TOWN_ALARM_AREA_FACTOR :: d32.Value(125*d32.SCALE/100)
WORLD_DAY_LENGTH_SECONDS :: 7*60.0

// --- weather ---------------------------------------------------------------

SEASONS_PER_YEAR :: 4
WEATHER_MIN_SECONDS :: 90
WEATHER_MAX_SECONDS :: 180
WEATHER_RAMP_IN :: 25
WEATHER_RAMP_OUT :: 15
WEATHER_LIGHTNING_DECAY :: d32.Value(25*d32.SCALE/10)
GAS_CLOUD_WIND_DRIFT :: d32.Value(8*d32.SCALE/10)

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
	value:          d32.Value,
	duration:       d32.Value,
	remaining:      d32.Value,
	windX, windY:   d32.Value,
	season:         Season,
	sequence:       u32,
	lightningTimer: d32.Value,
	lightningFlash: f32, // Presentation only
}

WeatherEffects :: struct {
	food:            d32.Value,
	water:           d32.Value,
	growth:          d32.Value,
	vision:          d32.Value,
	move:            d32.Value,
	fireSpread:      d32.Value,
	fireIgnition:    d32.Value,
	fireExtinguish:  d32.Value,
	harbor:          d32.Value,
	exposure:        d32.Value,
}

WorldSeason :: proc(w: ^World) -> Season {
	return Season(w.dayNumber%SEASONS_PER_YEAR)
}

WorldWeatherEffects :: proc(w: ^World) -> WeatherEffects {
	full := WeatherEffects {
		food = d32.ONE,
		water = d32.ONE,
		growth = d32.ONE,
		vision = d32.ONE,
		move = d32.ONE,
		fireSpread = d32.ONE,
		fireIgnition = d32.ONE,
		fireExtinguish = d32.ONE,
		harbor = d32.ONE,
	}
	switch w.weather.kind {
	case .Clear:
	case .Rain:
		full = WeatherEffects {
			food = d32.FromRatio(115, 100),
			water = d32.FromRatio(130, 100),
			growth = d32.FromRatio(110, 100),
			vision = d32.FromRatio(85, 100),
			move = d32.FromRatio(92, 100),
			fireSpread = d32.FromRatio(25, 100),
			fireIgnition = d32.FromRatio(45, 100),
			fireExtinguish = d32.FromInt(2),
			harbor = d32.FromRatio(90, 100),
		}
	case .Storm:
		full = WeatherEffects {
			food = d32.FromRatio(105, 100),
			water = d32.FromRatio(125, 100),
			growth = d32.FromRatio(95, 100),
			vision = d32.FromRatio(65, 100),
			move = d32.FromRatio(80, 100),
			fireSpread = d32.FromRatio(10, 100),
			fireIgnition = d32.FromRatio(25, 100),
			fireExtinguish = d32.FromRatio(250, 100),
			harbor = d32.FromRatio(50, 100),
		}
	case .Fog:
		full = WeatherEffects {
			food = d32.FromRatio(95, 100),
			growth = d32.FromRatio(95, 100),
			vision = d32.FromRatio(50, 100),
			move = d32.FromRatio(90, 100),
			fireSpread = d32.FromRatio(70, 100),
			fireIgnition = d32.FromRatio(90, 100),
			fireExtinguish = d32.FromRatio(120, 100),
			harbor = d32.FromRatio(90, 100),
		}
	case .Snow:
		full = WeatherEffects {
			food = d32.FromRatio(82, 100),
			water = d32.FromRatio(110, 100),
			growth = d32.FromRatio(70, 100),
			vision = d32.FromRatio(85, 100),
			move = d32.FromRatio(78, 100),
			fireSpread = d32.FromRatio(15, 100),
			fireIgnition = d32.FromRatio(25, 100),
			fireExtinguish = d32.FromInt(2),
			harbor = d32.FromRatio(80, 100),
			exposure = d32.FromRatio(6, 10000),
		}
	case .Blizzard:
		full = WeatherEffects {
			food = d32.FromRatio(65, 100),
			water = d32.FromRatio(90, 100),
			growth = d32.ZERO,
			vision = d32.FromRatio(45, 100),
			move = d32.FromRatio(60, 100),
			fireSpread = d32.ZERO,
			fireIgnition = d32.ZERO,
			fireExtinguish = d32.FromInt(4),
			harbor = d32.FromRatio(30, 100),
			exposure = d32.FromRatio(18, 10000),
		}
	case .Drought:
		full = WeatherEffects {
			food = d32.FromRatio(75, 100),
			water = d32.FromRatio(45, 100),
			growth = d32.FromRatio(72, 100),
			move = d32.FromRatio(95, 100),
			fireSpread = d32.FromRatio(170, 100),
			fireIgnition = d32.FromRatio(125, 100),
			fireExtinguish = d32.FromRatio(70, 100),
			harbor = d32.FromRatio(90, 100),
			exposure = d32.FromRatio(4, 10000),
		}
	case .Heatwave:
		full = WeatherEffects {
			food = d32.FromRatio(86, 100),
			water = d32.FromRatio(72, 100),
			growth = d32.FromRatio(85, 100),
			vision = d32.FromRatio(95, 100),
			move = d32.FromRatio(90, 100),
			fireSpread = d32.FromRatio(140, 100),
			fireIgnition = d32.FromRatio(120, 100),
			fireExtinguish = d32.FromRatio(80, 100),
			harbor = d32.FromRatio(90, 100),
			exposure = d32.FromRatio(12, 10000),
		}
	case .Sandstorm:
		full = WeatherEffects {
			food = d32.FromRatio(80, 100),
			water = d32.FromRatio(90, 100),
			growth = d32.FromRatio(80, 100),
			vision = d32.FromRatio(45, 100),
			move = d32.FromRatio(70, 100),
			fireSpread = d32.FromRatio(80, 100),
			fireIgnition = d32.FromRatio(70, 100),
			fireExtinguish = d32.ONE,
			harbor = d32.FromRatio(50, 100),
			exposure = d32.FromRatio(20, 10000),
		}
	case .Ashfall:
		full = WeatherEffects {
			food = d32.FromRatio(80, 100),
			water = d32.FromRatio(90, 100),
			growth = d32.FromRatio(75, 100),
			vision = d32.FromRatio(60, 100),
			move = d32.FromRatio(90, 100),
			fireSpread = d32.FromRatio(50, 100),
			fireIgnition = d32.FromRatio(60, 100),
			fireExtinguish = d32.FromRatio(120, 100),
			harbor = d32.FromRatio(80, 100),
			exposure = d32.FromRatio(8, 10000),
		}
	}

	value := clamp(w.weather.value, d32.ZERO, d32.ONE)
	return WeatherEffects {
		food = d32.Add(d32.ONE, d32.Mul(d32.Sub(full.food, d32.ONE), value)),
		water = d32.Add(d32.ONE, d32.Mul(d32.Sub(full.water, d32.ONE), value)),
		growth = d32.Add(d32.ONE, d32.Mul(d32.Sub(full.growth, d32.ONE), value)),
		vision = d32.Add(d32.ONE, d32.Mul(d32.Sub(full.vision, d32.ONE), value)),
		move = d32.Add(d32.ONE, d32.Mul(d32.Sub(full.move, d32.ONE), value)),
		fireSpread = d32.Add(d32.ONE, d32.Mul(d32.Sub(full.fireSpread, d32.ONE), value)),
		fireIgnition = d32.Add(d32.ONE, d32.Mul(d32.Sub(full.fireIgnition, d32.ONE), value)),
		fireExtinguish = d32.Add(d32.ONE, d32.Mul(d32.Sub(full.fireExtinguish, d32.ONE), value)),
		harbor = d32.Add(d32.ONE, d32.Mul(d32.Sub(full.harbor, d32.ONE), value)),
		exposure = d32.Mul(full.exposure, value),
	}
}

WorldWeatherVisionFactor :: proc(w: ^World) -> d32.Value {
	return WorldWeatherEffects(w).vision
}

WorldWeatherMoveFactor :: proc(w: ^World) -> d32.Value {
	return WorldWeatherEffects(w).move
}

WorldWeatherPick :: proc(w: ^World, season: Season, current: WeatherKind) -> WeatherKind {
	weights: [WeatherKind]d32.Value
	switch season {
	case .Spring:
		weights[.Clear] = d32.FromInt(30)
		weights[.Rain] = d32.FromInt(40)
		weights[.Storm] = d32.FromInt(10)
		weights[.Fog] = d32.FromInt(20)
	case .Summer:
		weights[.Clear] = d32.FromInt(26)
		weights[.Rain] = d32.FromInt(14)
		weights[.Storm] = d32.FromInt(16)
		weights[.Fog] = d32.FromInt(6)
		weights[.Heatwave] = d32.FromInt(20)
		weights[.Drought] = d32.FromInt(18)
	case .Autumn:
		weights[.Clear] = d32.FromInt(24)
		weights[.Rain] = d32.FromInt(32)
		weights[.Storm] = d32.FromInt(20)
		weights[.Fog] = d32.FromInt(24)
	case .Winter:
		weights[.Clear] = d32.FromInt(18)
		weights[.Rain] = d32.FromInt(6)
		weights[.Snow] = d32.FromInt(42)
		weights[.Blizzard] = d32.FromInt(14)
		weights[.Fog] = d32.FromInt(20)
	}
	if current != .Clear do weights[current] = d32.Mul(weights[current], d32.FromRatio(12, 100))

	total := d32.ZERO
	for kind in WeatherKind do total = d32.Add(total, weights[kind])
	if total <= d32.ZERO do return .Clear
	roll := d32.Mul(
		d32.FromRatio(
			i32(WorldNoiseHashInt(int(w.weather.sequence), int(season)+13, w.seed+0x7EA5E)),
			1_000_000,
		),
		total,
	)
	for kind in WeatherKind {
		roll = d32.Sub(roll, weights[kind])
		if roll <= d32.ZERO do return kind
	}
	return .Clear
}

WorldWeatherTransition :: proc(w: ^World, kind: WeatherKind) {
	w.weather.kind = kind
	w.weather.sequence += 1
	w.weather.season = WorldSeason(w)

	duration := d32.Add(
		d32.FromInt(WEATHER_MIN_SECONDS),
		d32.Mul(
			d32.FromRatio(
				i32(WorldNoiseHashInt(int(w.weather.sequence), 5, w.seed+0x71EA)),
				1_000_000,
			),
			d32.FromInt(WEATHER_MAX_SECONDS-WEATHER_MIN_SECONDS),
		),
	)
	switch kind {
	case .Clear:
		duration = d32.Mul(duration, d32.FromRatio(125, 100))
	case .Storm, .Blizzard:
		duration = d32.Mul(duration, d32.FromRatio(8, 10))
	case .Drought:
		duration = d32.Mul(duration, d32.FromRatio(115, 100))
	case .Rain, .Fog, .Snow, .Heatwave, .Sandstorm, .Ashfall:
	}
	w.weather.duration = duration
	w.weather.remaining = duration
	w.weather.nextKind = WorldWeatherPick(w, w.weather.season, kind)

	speed := d32.FromRatio(3, 100)
	switch kind {
	case .Clear:
		speed = d32.FromRatio(3, 100)
	case .Rain:
		speed = d32.FromRatio(16, 100)
	case .Storm:
		speed = d32.FromRatio(5, 10)
	case .Fog:
		speed = d32.FromRatio(2, 100)
	case .Snow:
		speed = d32.FromRatio(14, 100)
	case .Blizzard:
		speed = d32.FromRatio(55, 100)
	case .Drought:
		speed = d32.FromRatio(10, 100)
	case .Heatwave:
		speed = d32.FromRatio(6, 100)
	case .Sandstorm:
		speed = d32.FromRatio(60, 100)
	case .Ashfall:
		speed = d32.FromRatio(15, 100)
	}
	turns := d32.FromRatio(i32(WorldNoiseHashInt(int(w.weather.sequence), 7, w.seed+0x31D)), 1_000_000)
	sine, cosine := d32.SinCos(turns)
	w.weather.windX = d32.Mul(cosine, speed)
	w.weather.windY = d32.Mul(sine, speed)
	w.weather.lightningTimer = d32.Add(
		d32.FromRatio(15, 10),
		d32.Mul(
			d32.FromRatio(
				i32(WorldNoiseHashInt(int(w.weather.sequence), 9, w.seed+0x4A1)),
				1_000_000,
			),
			d32.FromInt(3),
		),
	)
}

WorldWeatherUpdate :: proc(w: ^World, deltaTime: f32) {
	if deltaTime <= 0 do return
	step := PositionFromF32(deltaTime)

	season := WorldSeason(w)
	if season != w.weather.season {
		newKind := WorldWeatherPick(w, season, w.weather.kind)
		WorldWeatherTransition(w, newKind)
	}
	w.weather.remaining = max(d32.Sub(w.weather.remaining, step), d32.ZERO)
	if w.weather.remaining <= d32.ZERO do WorldWeatherTransition(w, w.weather.nextKind)

	age := d32.Sub(w.weather.duration, w.weather.remaining)
	fadeIn := clamp(d32.Div(age, d32.FromInt(WEATHER_RAMP_IN)), d32.ZERO, d32.ONE)
	fadeOut := clamp(d32.Div(w.weather.remaining, d32.FromInt(WEATHER_RAMP_OUT)), d32.ZERO, d32.ONE)
	w.weather.value = min(fadeIn, fadeOut)

	if w.weather.kind == .Storm && w.weather.value > d32.FromRatio(3, 10) {
		w.weather.lightningTimer = d32.Sub(w.weather.lightningTimer, step)
		if w.weather.lightningTimer <= d32.ZERO {
			w.weather.lightningTimer = d32.Add(
				d32.FromRatio(15, 10),
				d32.Mul(
					d32.FromRatio(
						i32(WorldNoiseHashInt(
							int(WorldCurrentTick(w)),
							int(w.weather.sequence),
							w.seed+0x11,
						)),
						1_000_000,
					),
					d32.FromInt(4),
				),
			)
			w.weather.lightningFlash = 1
		}
	}
	w.weather.lightningFlash = max(
		w.weather.lightningFlash-deltaTime*PositionToF32(WEATHER_LIGHTNING_DECAY),
		0,
	)

	weatherEffects := WorldWeatherEffects(w)
	active := w.weather.value > d32.FromRatio(1, 5)
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
		if hidden || weatherEffects.exposure <= d32.ZERO do continue

		tileX := UnitTileX(w, unitSlot)
		tileY := UnitTileY(w, unitSlot)
		tileData := WorldTileAt(w, tileX, tileY)
		climate := tileData.climate
		tile := tileData.type
		coldTile := climate == .Boreal || tile == .Tundra || tile == .Ice
		hotTile := climate == .Arid || climate == .Volcanic || tile == .Desert || tile == .Ash

		exposure := weatherEffects.exposure
		switch w.weather.kind {
		case .Snow:
			exposure = coldTile ? d32.Mul(exposure, d32.FromRatio(3, 2)) : d32.ZERO
		case .Blizzard:
			exposure = d32.Mul(exposure, coldTile ? d32.FromRatio(3, 2) : d32.FromRatio(7, 10))
		case .Drought:
			exposure = hotTile ? exposure : d32.ZERO
		case .Heatwave:
			exposure = d32.Mul(exposure, hotTile ? d32.FromRatio(3, 2) : d32.FromRatio(3, 5))
		case .Sandstorm:
			exposure = d32.Mul(exposure, hotTile ? d32.FromRatio(3, 2) : d32.HALF)
		case .Ashfall:
		case .Clear, .Rain, .Storm, .Fog:
			exposure = d32.ZERO
		}
		if exposure <= d32.ZERO do continue
		// Health, exposure and the tick are all Q16.16.
		damage := d32.Mul(UnitMaxHealth(w, unitSlot), d32.Mul(exposure, step))
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
	remaining: d32.Value,
	telegraph: d32.Value,
	duration:  d32.Value,
	centerX:   d32.Value,
	centerY:   d32.Value,
	radius:    d32.Value,
	kingdom:   int,
	town:      int,
	tick:      d32.Value,
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

EnvironmentSeverityScale :: proc(severity: EventSeverity) -> d32.Value {
	switch severity {
	case .Minor:
		return d32.HALF
	case .Moderate:
		return d32.FromRatio(4, 5)
	case .Major:
		return d32.FromRatio(11, 10)
	case .Cataclysm:
		return d32.FromRatio(3, 2)
	}
	return d32.ONE
}

EnvironmentEventRadius :: proc(severity: EventSeverity) -> d32.Value {
	switch severity {
	case .Minor:
		return d32.FromRatio(35, 10)
	case .Moderate:
		return d32.FromRatio(55, 10)
	case .Major:
		return d32.FromRatio(75, 10)
	case .Cataclysm:
		return d32.FromRatio(95, 10)
	}
	return d32.FromInt(5)
}

EnvironmentTelegraphSeconds :: proc(severity: EventSeverity) -> d32.Value {
	switch severity {
	case .Minor:
		return d32.FromRatio(15, 10)
	case .Moderate:
		return d32.FromInt(3)
	case .Major:
		return d32.FromInt(5)
	case .Cataclysm:
		return d32.FromInt(8)
	}
	return d32.FromInt(3)
}

EnvironmentEventDuration :: proc(kind: EnvironmentEventKind, severity: EventSeverity) -> d32.Value {
	base: i32 = 12
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
	return d32.Mul(d32.FromInt(base), EnvironmentSeverityScale(severity))
}

EnvironmentEventTickSeconds :: proc(kind: EnvironmentEventKind) -> d32.Value {
	switch kind {
	case .Wildfire:
		return d32.FromRatio(8, 10)
	case .Blizzard:
		return d32.HALF
	case .Earthquake:
		return d32.FromRatio(12, 10)
	case .Eruption:
		return d32.FromRatio(9, 10)
	case .Hurricane:
		return d32.FromRatio(12, 10)
	case .MeteorShower:
		return d32.ONE
	case .Flood, .Drought, .Locusts:
		return d32.ONE
	}
	return d32.ONE
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
	weights: [KINGDOMS_CAPACITY]d32.Value
	total := d32.ZERO
	for kingdom in 0..<KINGDOMS_CAPACITY {
		if kingdom == NEUTRAL_KINGDOM || !w.kingdomUsed[kingdom] do continue
		weight := d32.Add(d32.ONE, w.eventDebt[kingdom])
		if EnvironmentKingdomEra(w, kingdom) < maxEra {
			weight = d32.Mul(weight, d32.FromRatio(55, 100))
		}
		if severity == .Cataclysm && kingdom == leader {
			weight = d32.Mul(weight, d32.FromInt(2))
		}
		weights[kingdom] = weight
		total = d32.Add(total, weight)
	}
	if severity >= .Major && w.eventLastMajorKingdom >= 0 &&
		w.eventLastMajorKingdom < KINGDOMS_CAPACITY {
		last := w.eventLastMajorKingdom
		total = d32.Sub(total, weights[last])
		weights[last] = d32.ZERO
		if total <= d32.ZERO {
			weights[last] = d32.ONE
			total = d32.ONE
		}
	}
	if total <= d32.ZERO do return -1
	roll := d32.Mul(
		d32.FromRatio(
			i32(WorldNoiseHashInt(int(w.eventSequence)+1, int(severity)+31, w.seed+0xE7E)),
			1_000_000,
		),
		total,
	)
	for kingdom in 0..<KINGDOMS_CAPACITY {
		roll = d32.Sub(roll, weights[kingdom])
		if weights[kingdom] > d32.ZERO && roll <= d32.ZERO do return kingdom
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
	weights: [EnvironmentEventKind]d32.Value
	for kind in EnvironmentEventKind {
		if !EnvironmentKindEligible(kind, severity) do continue
		if kind in w.eventBag do continue
		if kind == .Hurricane && !EnvironmentKingdomHasCoastalTown(w, kingdom) do continue
		weights[kind] = d32.FromInt(10)
	}
	weights[.Wildfire] = d32.Mul(weights[.Wildfire], d32.FromRatio(26, 10))
	weights[.Flood] = d32.Mul(weights[.Flood], d32.FromRatio(24, 10))
	weights[.Drought] = d32.Mul(weights[.Drought], d32.FromInt(2))
	weights[.Blizzard] = d32.Mul(weights[.Blizzard], d32.FromRatio(16, 10))
	weights[.Earthquake] = d32.Mul(weights[.Earthquake], d32.FromRatio(18, 10))
	weights[.Eruption] = d32.Mul(weights[.Eruption], d32.FromRatio(16, 10))
	weights[.Locusts] = d32.Mul(weights[.Locusts], d32.FromRatio(14, 10))
	weights[.Hurricane] = d32.Mul(weights[.Hurricane], d32.FromRatio(16, 10))
	weights[.MeteorShower] = d32.Mul(weights[.MeteorShower], d32.FromRatio(16, 10))

	switch w.weather.kind {
	case .Rain, .Storm:
		weights[.Wildfire] = d32.Mul(weights[.Wildfire], d32.FromRatio(3, 10))
		weights[.Flood] = d32.Mul(weights[.Flood], d32.FromRatio(16, 10))
		weights[.Hurricane] = d32.Mul(weights[.Hurricane], d32.FromRatio(15, 10))
		weights[.Drought] = d32.Mul(weights[.Drought], d32.FromRatio(5, 10))
	case .Snow, .Blizzard:
		weights[.Wildfire] = d32.ZERO
		weights[.Blizzard] = d32.Mul(weights[.Blizzard], d32.FromRatio(16, 10))
		weights[.Flood] = d32.Mul(weights[.Flood], d32.FromRatio(8, 10))
	case .Drought, .Heatwave:
		weights[.Wildfire] = d32.Mul(weights[.Wildfire], d32.FromRatio(18, 10))
		weights[.Drought] = d32.Mul(weights[.Drought], d32.FromRatio(16, 10))
		weights[.Flood] = d32.Mul(weights[.Flood], d32.FromRatio(5, 10))
		weights[.Hurricane] = d32.Mul(weights[.Hurricane], d32.FromRatio(5, 10))
	case .Clear, .Fog, .Sandstorm, .Ashfall:
	}

	total := d32.ZERO
	for kind in EnvironmentEventKind do total = d32.Add(total, weights[kind])
	if total <= d32.ZERO {
		w.eventBag = {}
		return EnvironmentPickKind(w, severity, kingdom)
	}
	roll := d32.Mul(
		d32.FromRatio(
			i32(WorldNoiseHashInt(int(w.eventSequence)+1, int(severity)+71, w.seed+0xBA6)),
			1_000_000,
		),
		total,
	)
	for kind in EnvironmentEventKind {
		roll = d32.Sub(roll, weights[kind])
		if weights[kind] > d32.ZERO && roll <= d32.ZERO do return kind
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
	index := WorldNoiseIndex(int(w.eventSequence)+1, count+3, w.seed+0x70A, count)
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
	index := WorldNoiseIndex(int(w.eventSequence)+1, count+9, w.seed+0x70B, count)
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
		centerX = d32.Add(d32.FromInt(i32(ref.x)), d32.FromInt(2)),
		centerY = d32.Add(d32.FromInt(i32(ref.y)), d32.FromInt(2)),
		radius = EnvironmentEventRadius(severity),
		kingdom = kingdom,
		town = town,
		sequence = w.eventSequence,
	}
	w.eventBag += {kind}
	w.eventDebt[kingdom] = d32.ZERO
	if severity >= .Major do w.eventLastMajorKingdom = kingdom

	switch severity {
	case .Minor:
		w.eventMinorTimer = d32.Add(
			d32.FromInt(70),
			d32.Mul(
				d32.FromRatio(
					i32(WorldNoiseHashInt(int(w.eventSequence), 13, w.seed+0x2A1)),
					1_000_000,
				),
				d32.FromInt(50),
			),
		)
	case .Moderate:
		w.eventModerateTimer = d32.Add(
			d32.FromInt(180),
			d32.Mul(
				d32.FromRatio(
					i32(WorldNoiseHashInt(int(w.eventSequence), 17, w.seed+0x2A3)),
					1_000_000,
				),
				d32.FromInt(120),
			),
		)
	case .Major:
		w.eventMajorTimer = d32.Add(
			d32.FromInt(420),
			d32.Mul(
				d32.FromRatio(
					i32(WorldNoiseHashInt(int(w.eventSequence), 19, w.seed+0x2A5)),
					1_000_000,
				),
				d32.FromInt(180),
			),
		)
	case .Cataclysm:
		w.eventCataclysmTimer = d32.Add(
			d32.FromInt(900),
			d32.Mul(
				d32.FromRatio(
					i32(WorldNoiseHashInt(int(w.eventSequence), 23, w.seed+0x2A7)),
					1_000_000,
				),
				d32.FromInt(600),
			),
		)
		w.eventCataclysmCount += 1
	}
	w.eventGap = d32.Add(
		d32.FromInt(45),
		d32.Mul(
			d32.FromRatio(
				i32(WorldNoiseHashInt(int(w.eventSequence), 29, w.seed+0x2A9)),
				1_000_000,
			),
			d32.FromInt(30),
		),
	)
	WorldAlertAddEnvironment(w, &w.environment)
}

WorldEnvironmentUpdate :: proc(w: ^World, deltaTime: f32) {
	if deltaTime <= 0 do return
	step := PositionFromF32(deltaTime)
	maxEra := EnvironmentMaxEra(w)
	for kingdom in 0..<KINGDOMS_CAPACITY {
		if kingdom == NEUTRAL_KINGDOM || !w.kingdomUsed[kingdom] do continue
		trailing := EnvironmentKingdomEra(w, kingdom) < maxEra
		rate := d32.ONE
		if trailing do rate = d32.FromRatio(35, 100)
		gain := d32.Div(rate, d32.FromInt(60))
		w.eventDebt[kingdom] = min(
			d32.Add(w.eventDebt[kingdom], d32.Mul(step, gain)),
			d32.FromInt(6),
		)
	}

	w.eventGap = max(d32.Sub(w.eventGap, step), d32.ZERO)
	w.eventMinorTimer = max(d32.Sub(w.eventMinorTimer, step), d32.ZERO)
	w.eventModerateTimer = max(d32.Sub(w.eventModerateTimer, step), d32.ZERO)
	w.eventMajorTimer = max(d32.Sub(w.eventMajorTimer, step), d32.ZERO)
	w.eventCataclysmTimer = max(d32.Sub(w.eventCataclysmTimer, step), d32.ZERO)

	if w.environment.phase != .None {
		w.environment.remaining = max(d32.Sub(w.environment.remaining, step), d32.ZERO)
		switch w.environment.phase {
		case .Telegraph:
			if w.environment.remaining <= d32.ZERO {
				w.environment.phase = .Active
				w.environment.remaining = w.environment.duration
				w.environment.tick = d32.ZERO
				EnvironmentEventActivate(w)
			}
		case .Active:
			EnvironmentEventTick(w, deltaTime)
			if w.environment.remaining <= d32.ZERO do EnvironmentEventEnd(w)
		case .None:
		}
		return
	}

	if w.eventGap > d32.ZERO do return

	severity: EventSeverity
	ready := false
	if w.eventCataclysmTimer <= d32.ZERO && w.eventCataclysmCount < 2 {
		if maxEra >= 2 {
			severity = .Cataclysm
			ready = true
		} else {
			w.eventCataclysmTimer = d32.FromInt(30)
		}
	}
	if !ready && w.eventMajorTimer <= d32.ZERO {
		severity = .Major
		ready = true
	}
	if !ready && w.eventModerateTimer <= d32.ZERO {
		severity = .Moderate
		ready = true
	}
	if !ready && w.eventMinorTimer <= d32.ZERO {
		severity = .Minor
		ready = true
	}
	if ready do EnvironmentEventStart(w, severity)
}

EnvironmentEventActivate :: proc(w: ^World) {
	e := &w.environment
	scaleValue := EnvironmentSeverityScale(e.severity)
	scale := PositionToF32(scaleValue)
	centerX := e.centerX
	centerY := e.centerY
	radius := e.radius
	switch e.kind {
	case .Wildfire:
		EnvironmentFireBurst(w, centerX, centerY, radius, 5+int(scale*6))
	case .Flood:
		WorldHazardSpawnCircle(
			w,
			centerX,
			centerY,
			radius,
			.Flood,
			d32.Add(d32.FromInt(20), d32.Mul(d32.FromInt(10), scaleValue)),
			d32.Add(d32.FromInt(30), d32.Mul(d32.FromInt(15), scaleValue)),
			u64(e.sequence)+0xF100,
		)
	case .Hurricane:
		WorldHazardSpawnCircle(
			w,
			centerX,
			centerY,
			radius,
			.Flood,
			d32.Add(d32.FromInt(25), d32.Mul(d32.FromInt(12), scaleValue)),
			d32.Add(d32.FromInt(35), d32.Mul(d32.FromInt(18), scaleValue)),
			u64(e.sequence)+0xF101,
		)
		EnvironmentDamageArea(
			w,
			centerX,
			centerY,
			radius,
			d32.Mul(d32.FromInt(8), scaleValue),
			d32.Mul(d32.FromInt(30), scaleValue),
			.Area,
		)
	case .Earthquake:
		EnvironmentDamageArea(
			w,
			centerX,
			centerY,
			radius,
			d32.Mul(d32.FromInt(10), scaleValue),
			d32.Mul(d32.FromInt(70), scaleValue),
			.Area,
		)
		DecorationBlastBurst(
			w,
			PositionToF32(centerX),
			PositionToF32(centerY),
			PositionToF32(d32.Mul(radius, d32.FromRatio(8, 10))),
		)
		WorldTerrainQuakeApply(w, centerX, centerY, radius, u64(e.sequence)+0x9E01)
	case .Eruption:
		EnvironmentDamageArea(
			w,
			centerX,
			centerY,
			radius,
			d32.Mul(d32.FromInt(18), scaleValue),
			d32.Mul(d32.FromInt(110), scaleValue),
			.Fire,
		)
		EnvironmentFireBurst(w, centerX, centerY, radius, 10+int(scale*8))
		DecorationBlastBurst(w, PositionToF32(centerX), PositionToF32(centerY), PositionToF32(radius))
		WorldTerrainEruptionApply(w, centerX, centerY, radius, u64(e.sequence)+0x9E02)
	case .MeteorShower:
		EnvironmentMeteorImpact(w)
	case .Blizzard:
		WorldTerrainFreezeApply(
			w,
			centerX,
			centerY,
			d32.Mul(radius, d32.FromRatio(14, 10)),
			u64(e.sequence)+0x9E03,
		)
	case .Drought:
		WorldTerrainDroughtApply(
			w,
			centerX,
			centerY,
			d32.Mul(radius, d32.FromRatio(16, 10)),
			u64(e.sequence)+0x9E04,
		)
	case .Locusts:
	}
}

EnvironmentEventTick :: proc(w: ^World, deltaTime: f32) {
	e := &w.environment
	e.tick = d32.Sub(e.tick, PositionFromF32(deltaTime))
	if e.tick > d32.ZERO do return
	e.tick = EnvironmentEventTickSeconds(e.kind)
	scaleValue := EnvironmentSeverityScale(e.severity)
	scale := PositionToF32(scaleValue)
	centerX := e.centerX
	centerY := e.centerY
	radius := e.radius

	switch e.kind {
	case .Wildfire:
		EnvironmentFireBurst(w, centerX, centerY, radius, 2+int(scale*2))
		EnvironmentDamageArea(
			w,
			centerX,
			centerY,
			radius,
			d32.Mul(d32.FromInt(2), scaleValue),
			d32.Mul(d32.FromInt(6), scaleValue),
			.Fire,
		)
	case .Blizzard:
		EnvironmentDamageArea(
			w,
			centerX,
			centerY,
			radius,
			d32.Mul(d32.FromInt(2), scaleValue),
			d32.ZERO,
			.Weather,
		)
	case .Earthquake:
		EnvironmentDamageArea(
			w,
			centerX,
			centerY,
			radius,
			d32.Mul(d32.FromInt(4), scaleValue),
			d32.Mul(d32.FromInt(35), scaleValue),
			.Area,
		)
	case .Eruption:
		EnvironmentDamageArea(
			w,
			centerX,
			centerY,
			radius,
			d32.Mul(d32.FromInt(8), scaleValue),
			d32.Mul(d32.FromInt(70), scaleValue),
			.Fire,
		)
		EnvironmentFireBurst(w, centerX, centerY, radius, 2+int(scale*2))
		WorldTerrainLavaSpread(w, centerX, centerY, radius, u64(e.sequence)+0x9E11)
	case .Hurricane:
		EnvironmentDamageArea(
			w,
			centerX,
			centerY,
			radius,
			d32.Mul(d32.FromInt(5), scaleValue),
			d32.Mul(d32.FromInt(25), scaleValue),
			.Area,
		)
	case .MeteorShower:
		EnvironmentMeteorImpact(w)
	case .Flood, .Drought, .Locusts:
	}
}

EnvironmentEventEnd :: proc(w: ^World) {
	w.environment.phase = .None
	w.environment.kingdom = -1
	w.environment.town = -1
	w.eventGap = max(w.eventGap, d32.FromInt(25))
}

EnvironmentEventTownFactors :: proc(
	w: ^World,
	kingdom, town: int,
) -> (food, water, growth: d32.Value) {
	food, water, growth = d32.ONE, d32.ONE, d32.ONE
	e := &w.environment
	if e.phase != .Active || e.kingdom != kingdom || e.town != town do return
	scale := EnvironmentSeverityScale(e.severity)
	switch e.kind {
	case .Drought:
		food = d32.Sub(d32.ONE, d32.Mul(d32.FromRatio(35, 100), scale))
		water = d32.Sub(d32.ONE, d32.Mul(d32.FromRatio(65, 100), scale))
		growth = d32.Sub(d32.ONE, d32.Mul(d32.FromRatio(20, 100), scale))
	case .Locusts:
		food = d32.Sub(d32.ONE, d32.Mul(d32.FromRatio(80, 100), scale))
		growth = d32.Sub(d32.ONE, d32.Mul(d32.FromRatio(10, 100), scale))
	case .Blizzard:
		food = d32.Sub(d32.ONE, d32.Mul(d32.FromRatio(20, 100), scale))
		if e.severity >= .Major do growth = d32.ZERO
	case .Flood, .Wildfire, .Earthquake, .Eruption, .Hurricane, .MeteorShower:
	}
	food = clamp(food, d32.FromRatio(5, 100), d32.ONE)
	water = clamp(water, d32.FromRatio(5, 100), d32.ONE)
	growth = clamp(growth, d32.ZERO, d32.ONE)
	return
}

// Unit-disc offset in Q16.16; callers scale it by the effect radius.
@(private = "file")
EnvironmentPlacementOffset :: proc(turnRoll, radiusRoll: u32) -> (d32.Value, d32.Value) {
	turns := d32.FromRatio(i32(turnRoll), 1_000_000)
	radiusFraction := d32.FromRatio(i32(radiusRoll), 1_000_000)
	sine, cosine := d32.SinCos(turns)
	distance := d32.Sqrt(radiusFraction)
	return d32.Mul(cosine, distance), d32.Mul(sine, distance)
}

EnvironmentFireBurst :: proc(w: ^World, x, y, radius: d32.Value, count: int) {
	if count <= 0 do return
	salt := int(WorldCurrentTick(w)*2)
	worldWidthRaw := i64(w.maxX)*d32.SCALE
	worldHeightRaw := i64(w.maxY)*d32.SCALE
	for i in 0..<count {
		turnRoll := WorldNoiseHashInt(i, int(w.environment.sequence)+salt, w.seed+0x3A1)
		radiusRoll := WorldNoiseHashInt(i, int(w.environment.sequence)+salt+7, w.seed+0x3A3)
		offsetX, offsetY := EnvironmentPlacementOffset(turnRoll, radiusRoll)
		fx, validX := d32.AddRawWrapped(
			i64(d32.Raw(x)),
			i64(d32.Raw(d32.Mul(offsetX, radius))),
			d32.ZERO,
			worldWidthRaw,
		)
		fy, validY := d32.AddRawWrapped(
			i64(d32.Raw(y)),
			i64(d32.Raw(d32.Mul(offsetY, radius))),
			d32.ZERO,
			worldHeightRaw,
		)
		if !validX || !validY do continue
		WorldFireIgnite(w, fx, fy, 1.0, 1.0)
	}
}

EnvironmentMeteorImpact :: proc(w: ^World) {
	e := &w.environment
	scaleValue := EnvironmentSeverityScale(e.severity)
	scale := PositionToF32(scaleValue)
	tick := PositionToF32(e.tick)
	turnRoll := WorldNoiseHashInt(int(tick*17)+int(e.sequence), int(WorldCurrentTick(w)), w.seed+0x4A1)
	radiusRoll := WorldNoiseHashInt(int(e.sequence), int(WorldCurrentTick(w)), w.seed+0x4A3)
	offsetX, offsetY := EnvironmentPlacementOffset(turnRoll, radiusRoll)
	worldWidthRaw := i64(w.maxX)*d32.SCALE
	worldHeightRaw := i64(w.maxY)*d32.SCALE
	x, validX := d32.AddRawWrapped(
		i64(d32.Raw(e.centerX)),
		i64(d32.Raw(d32.Mul(offsetX, e.radius))),
		d32.ZERO,
		worldWidthRaw,
	)
	y, validY := d32.AddRawWrapped(
		i64(d32.Raw(e.centerY)),
		i64(d32.Raw(d32.Mul(offsetY, e.radius))),
		d32.ZERO,
		worldHeightRaw,
	)
	if !validX || !validY do return
	impactRadius := d32.Add(d32.FromRatio(5, 2), scaleValue)
	EnvironmentDamageArea(
		w,
		x,
		y,
		impactRadius,
		d32.Mul(d32.FromInt(10), scaleValue),
		d32.Mul(d32.FromInt(45), scaleValue),
		.Fire,
	)
	fireRadius := d32.Add(d32.FromInt(2), scaleValue)
	EnvironmentFireBurst(w, x, y, fireRadius, 3+int(scale*2))
	DecorationBlastBurst(w, PositionToF32(x), PositionToF32(y), PositionToF32(fireRadius))
	WorldTerrainMeteorCrater(w, PositionTile(x, int(w.maxX)), PositionTile(y, int(w.maxY)), u64(e.sequence)+0x3E00)
}

EnvironmentDamageArea :: proc(
	w: ^World,
	x, y, radius: d32.Value,
	unitDamage, buildingDamage: d32.Value,
	damageKind: DamageKind,
) {
	chunkSize := w.spatial.chunkSize
	if chunkSize <= 0 do return
	worldWidthRaw := i64(w.maxX)*d32.SCALE
	worldHeightRaw := i64(w.maxY)*d32.SCALE
	centerPositionX, validX := d32.WrapRaw(i64(d32.Raw(x)), d32.ZERO, worldWidthRaw)
	centerPositionY, validY := d32.WrapRaw(i64(d32.Raw(y)), d32.ZERO, worldHeightRaw)
	if !validX || !validY do return
	radiusRaw := i64(d32.Raw(radius))
	radiusSquaredRaw := u64(radiusRaw)*u64(radiusRaw)
	centerChunkX := int(d32.ToInt(centerPositionX))/chunkSize
	centerChunkY := int(d32.ToInt(centerPositionY))/chunkSize
	chunkRadius := int(d32.ToInt(radius))/chunkSize+1

	for offsetX in -chunkRadius..=chunkRadius {
		chunkX := WorldWrapCoordinate(centerChunkX+offsetX, w.spatial.chunksX)
		for offsetY in -chunkRadius..=chunkRadius {
			chunkY := WorldWrapCoordinate(centerChunkY+offsetY, w.spatial.chunksY)
			chunk := chunkX*w.spatial.chunksY+chunkY

			slot := w.spatial.unitHead[chunk]
			for slot >= 0 {
				next := w.spatial.unitNext[slot]
				if w.unitUsed[slot] && w.units.type[slot] != nil && !UnitHiddenInside(w, slot) {
					distanceSquared, validDistance := d32.WrappedDistanceSquared(
						w.units.x[slot],
						w.units.y[slot],
						centerPositionX,
						centerPositionY,
						worldWidthRaw,
						worldHeightRaw,
					)
					if validDistance && distanceSquared <= radiusSquaredRaw {
						UnitApplyDamage(w, slot, unitDamage, centerPositionX, centerPositionY, damageKind)
					}
				}
				slot = next
			}

			slot = w.spatial.buildingHead[chunk]
			for slot >= 0 {
				next := w.spatial.buildingNext[slot]
				if w.buildingUsed[slot] {
					distanceSquared, impactX, impactY := WarriorBuildingNearestPointSquared(
						w,
						centerPositionX,
						centerPositionY,
						slot,
					)
					if distanceSquared <= radiusSquaredRaw {
						EnvironmentDamageBuilding(
							w,
							slot,
							buildingDamage,
							PositionToF32(impactX),
							PositionToF32(impactY),
						)
					}
				}
				slot = next
			}
		}
	}

	WorldDecorationAreaDamage(
		w,
		centerPositionX,
		centerPositionY,
		radius,
		d32.Mul(buildingDamage, d32.HALF),
	)
}

EnvironmentDamageBuilding :: proc(w: ^World, slot: int, damage: d32.Value, impactX, impactY: f32) {
	if slot < 0 || slot >= BUILDING_CAPACITY || !w.buildingUsed[slot] || damage <= d32.ZERO do return
	if w.buildings.kingdom[slot] == NEUTRAL_KINGDOM do return
	BuildingHitBurst(w, slot, impactX, impactY)
	w.buildings.health[slot] = d32.Sub(w.buildings.health[slot], damage)
	if w.buildings.health[slot] > d32.ZERO do return
	wasBurning := BuildingOnFire(w, slot)
	BuildingSpawnDebris(w, slot, wasBurning)
	BuildingDestroyedBurst(w, slot)
	BuildingDespawn(w, slot, -1)
}

// Population growth is cohort-based: an era defines how many villagers arrive
// together and how long the next cohort takes. Supply and unconverted villagers
// speed up the countdown rather than changing the cohort size.
// Growth values stay as integer ratios so the fixed-point path is exact.
// A citizen needs 25/1000 of a food or water unit per tick.
GROWTH_FOOD_PER_CITIZEN_MILLE :: 25
GROWTH_MIN_SPEED_PERCENT :: 25
GROWTH_MAX_SPEED_PERCENT :: 125
GROWTH_VILLAGER_SPEED_BONUS_MILLE :: 5
GROWTH_VILLAGER_SPEED_CAP_PERCENT :: 50
GROWTH_MAX_SPAWN_PER_TICK :: 32
// At the unit cap or in a fully packed town, retry the spawn later instead of
// scanning the whole town area every simulation tick.
TOWN_GROWTH_FAIL_COOLDOWN :: 2

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
		WorldTick(w)
		w.simulationAccumulator -= TOWN_SIMULATION_STEP
	}
	stamp = ProfilerBegin("Sim:GameEnd")
	WorldCheckGameEnd(w)
	ProfilerEnd(stamp)
}

WorldCurrentTick :: proc(w: ^World) -> u64 {
	return w.simulationTick + (w.simulationInTick ? 1 : 0)
}

// Call once after applying each lockstep command frame.
WorldTick :: proc(w: ^World) {
	tickStamp := ProfilerBegin("Sim:Tick")
	w.simulationInTick = true
	w.simulationTime = f32(f64(WorldCurrentTick(w))*TOWN_SIMULATION_STEP)
	WorldApplyPendingCommands(w)
	WorldTrimCommandLog(w)
	WorldAlertPrune(w)
	w.dayTime += TOWN_SIMULATION_STEP
	if w.dayTime >= f32(WORLD_DAY_LENGTH_SECONDS) {
		w.dayTime -= f32(WORLD_DAY_LENGTH_SECONDS)
		w.dayNumber += 1
	}
	stamp := ProfilerBegin("Sim:Weather")
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
	// Lava damage is a slow environmental effect; a quarter of the rate keeps
	// the same total damage without scanning every unit each tick.
	if WorldCurrentTick(w)%4 == 0 {
		WorldTerrainLavaUpdate(w, TOWN_SIMULATION_STEP*4)
	}
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
	if WorldCurrentTick(w)%FOG_UPDATE_INTERVAL == 0 {
		FogUpdate(w)
	}
	ProfilerEnd(stamp)
	stamp = ProfilerBegin("Sim:GameEnd")
	WorldCheckGameEnd(w)
	ProfilerEnd(stamp)
	w.simulationTick += 1
	w.simulationInTick = false
	if w.simulationTick%WORLD_HASH_INTERVAL == 0 && profiler.file != nil {
		buffer: [256]u8
		stateHash := WorldStateHash(w)
		line := fmt.bprintf(
			buffer[:],
			"WORLD HASH tick=%d hash=%016x session=%016x commands=%d commandHash=%016x\n",
			w.simulationTick,
			stateHash,
			SessionHashWithState(w, stateHash),
			len(w.commandLog),
			WorldCommandLogHash(w),
		)
		ProfilerWrite(line)
	}
	ProfilerEnd(tickStamp)
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
	worldWidthRaw := i64(w.maxX)*d32.SCALE
	worldHeightRaw := i64(w.maxY)*d32.SCALE
	// The hall footprint is a box, so the unit delta is shrunk by its half size.
	halfFootprintRawX := i64(width-1)*(d32.SCALE/2)
	halfFootprintRawY := i64(height-1)*(d32.SCALE/2)

	for circleIndex in 0..<TownAreaCircleCount(w, kingdom, townSlot) {
		circleX, circleY, circleRadius := TownAreaCircle(w, kingdom, townSlot, circleIndex)
		radius := d32.Mul(d32.FromInt(i32(circleRadius)), TOWN_ALARM_AREA_FACTOR)
		radiusRaw := i64(d32.Raw(radius))
		radiusSquaredRaw := u64(radiusRaw)*u64(radiusRaw)
		centerPositionX := d32.FromRaw(i32(i64(circleX)*d32.SCALE+halfFootprintRawX))
		centerPositionY := d32.FromRaw(i32(i64(circleY)*d32.SCALE+halfFootprintRawY))
		chunkExtentRaw := radiusRaw+i64(max(width, height))*d32.SCALE
		chunkRadius := int(chunkExtentRaw/(i64(chunkSize)*d32.SCALE))+1
		centerChunkX, centerChunkY := int(d32.ToInt(centerPositionX))/chunkSize, int(d32.ToInt(centerPositionY))/chunkSize
		for offsetX in 0..<min(chunkRadius*2+1, w.spatial.chunksX) {
			chunkX := WorldWrapCoordinate(centerChunkX-chunkRadius+offsetX, w.spatial.chunksX)
			for offsetY in 0..<min(chunkRadius*2+1, w.spatial.chunksY) {
				chunkY := WorldWrapCoordinate(centerChunkY-chunkRadius+offsetY, w.spatial.chunksY)
				chunk := chunkX*w.spatial.chunksY+chunkY
				// The cached presence mask skips chunks that hold no enemy at all.
				if !SpatialChunkHasEnemy(w, chunk, kingdom) do continue
				for unit := w.spatial.unitHead[chunk]; unit >= 0; unit = w.spatial.unitNext[unit] {
					if !w.unitUsed[unit] || UnitHiddenInside(w, unit) do continue
					if !KingdomAtWar(w, kingdom, w.units[unit].kingdome) do continue
					deltaX, validX := d32.ShortestWrappedDelta(w.units.x[unit], centerPositionX, worldWidthRaw)
					deltaY, validY := d32.ShortestWrappedDelta(w.units.y[unit], centerPositionY, worldHeightRaw)
					if !validX || !validY do continue
					dx := max(0, abs(deltaX)-halfFootprintRawX)
					dy := max(0, abs(deltaY)-halfFootprintRawY)
					if u64(dx*dx)+u64(dy*dy) <= radiusSquaredRaw {
						return true, UnitTileX(w, unit), UnitTileY(w, unit)
					}
				}
			}
		}
	}
	return false, 0, 0
}

UnitUpdateSlice :: proc(w: ^World) -> int {
	return int(WorldCurrentTick(w)%UNIT_UPDATE_SLICES)
}

// Hash the slot so contiguous spawn batches of one unit kind do not all land
// in the same slice.
UnitUpdateSliceOf :: proc(unitSlot: int) -> int {
	return int((u64(unitSlot)*0x9E3779B97F4A7C15)>>32)%UNIT_UPDATE_SLICES
}

// The unit pass observes shared state in ascending slot order.
UnitLoopJob :: struct {
	w:             ^World,
	slice:         int,
	tick:          u64,
	deltaTime:     f32,
	shortageEpoch: int,
	damageQueue:   ^PendingDamageQueue,
	kindTime:      [UnitKind]f64,
	kindCalls:     [UnitKind]int,
}

UnitLoopChunk :: proc(ctx: rawptr, start, end, worker: int) {
	job := cast(^UnitLoopJob)ctx
	w := job.w
	previousDamageQueue := pendingDamageQueue
	pendingDamageQueue = job.damageQueue
	defer pendingDamageQueue = previousDamageQueue
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
		if stride > 1 && (job.tick/UNIT_UPDATE_SLICES)%u64(stride) != 0 do continue
		unitDelta := job.deltaTime*f32(UNIT_UPDATE_SLICES*stride)
		w.units.previousX[unitSlot] = w.units.x[unitSlot]
		w.units.previousY[unitSlot] = w.units.y[unitSlot]
		w.units.updateTime[unitSlot] = w.simulationTime
		w.units.updateInterval[unitSlot] = unitDelta
		// Town upkeep rides along with the unit's own slice instead of a second
		// full-capacity scan in the kingdom pass.
		UnitUpdateTownUpkeep(w, unitSlot, job.shortageEpoch, unitDelta)
		w.units.decisionTimer[unitSlot] = max(
			d32.Sub(w.units.decisionTimer[unitSlot], PositionFromF32(unitDelta)),
			d32.ZERO,
		)
		w.units.decisionReady[unitSlot] = w.units.decisionTimer[unitSlot] <= d32.ZERO
		if w.units.decisionReady[unitSlot] {
			jitter := d32.Add(
				d32.FromRatio(3, 4),
				d32.Mul(
					PositionFromF32(WorldNoiseHash(unitSlot, int(job.tick), 0xD3C1)),
					d32.FromRatio(1, 2),
				),
			)
			w.units.decisionTimer[unitSlot] = d32.Mul(CIVILIAN_DECISION_INTERVAL, jitter)
		}
		unitKind := UnitKindOf(w.units[unitSlot].type)
		profileIndex := -1
		if profiler.enabled do profileIndex = profiler.unitKindIndex[unitKind]
		unitStart := ProfilerUnitStart(profileIndex)
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
		job.kindTime[unitKind] += ProfilerUnitElapsed(profileIndex, unitStart)
		job.kindCalls[unitKind] += 1
	}
}

PendingDamageMerge :: proc(w: ^World, queue: ^PendingDamageQueue) {
	total := queue.count+len(queue.overflow)
	if total == 0 do return

	hits := queue.inlineHits[:queue.count]
	hasOverflow := len(queue.overflow) > 0
	if hasOverflow {
		hits = make([]PendingDamage, total)
		copy(hits, queue.inlineHits[:queue.count])
		copy(hits[queue.count:], queue.overflow[:])
	}
	defer if hasOverflow do delete(hits)
	slices.sort_by(hits, PendingDamageLess)
	for hit in hits {
		UnitApplyDamageNow(w, hit.victim, hit.damage, hit.sourceX, hit.sourceY, hit.kind)
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

	tick := WorldCurrentTick(w)
	slice := int(tick%UNIT_UPDATE_SLICES)
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

	damageQueue: PendingDamageQueue
	defer delete(damageQueue.overflow)
	job := UnitLoopJob {
		damageQueue   = &damageQueue,
		w             = w,
		slice         = slice,
		tick          = tick,
		deltaTime     = deltaTime,
		shortageEpoch = int(tick/u64(5/TOWN_SIMULATION_STEP)),
	}
	// Unit updates observe and mutate shared state in slot order.
	w.deferDespawn = true
	UnitLoopChunk(&job, 0, UNIT_CAPACITY, 0)

	// Apply builder contributions in unit-slot order.
	constructionStamp := ProfilerBegin("Unit:Construction")
	TownConstructionMerge(w)
	ProfilerEnd(constructionStamp)

	// Sort by hit contents, independent of worker assignment and arrival order.
	PendingDamageMerge(w, &damageQueue)
	// Merge search timings.
	searchTime := f64(0)
	searchCalls := 0
	for threadSlot in 0..<PARALLEL_MAX_THREADS {
		scratch := &astarScratch[threadSlot]
		searchTime += scratch.time
		searchCalls += scratch.calls
		scratch.time = 0
		scratch.calls = 0
	}
	if searchCalls > 0 do ProfilerAddTotal(profiler.searchIndex, searchTime, searchCalls)
	w.deferDespawn = false

	// Requests are appended under unitMutex.
	slices.sort(w.pendingDespawns[:])
	for slot in w.pendingDespawns {
		if slot >= 0 && slot < UNIT_CAPACITY && w.unitUsed[slot] do UnitDespawn(w, slot)
	}
	clear(&w.pendingDespawns)

	for profileIndex, kind in profiler.unitKindIndex {
		if profileIndex < 0 do continue
		if job.kindCalls[kind] > 0 {
			ProfilerAddTotal(profileIndex, job.kindTime[kind], job.kindCalls[kind])
		}
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
	townSlice := int(WorldCurrentTick(w)%TOWN_UPDATE_SLICES)
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

	stamp = ProfilerBegin("Kingdom:Conversions")
	// Job assignment only needs to happen once per town update cycle.
	if townSlice == 0 do WorldConversionAssign(w)
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
		if BuildingKindOf(building.type) != .Home || building.health <= d32.ZERO ||
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
	nextHome := make([]int, BUILDING_CAPACITY)
	defer delete(nextHome)
	worldWidthRaw := i64(w.maxX)*d32.SCALE
	worldHeightRaw := i64(w.maxY)*d32.SCALE
	for home in 0..<BUILDING_CAPACITY {
		if !w.buildingUsed[home] do continue
		building := &w.buildings[home]
		resident := building.homeResident-1
		if resident >= 0 && resident < UNIT_CAPACITY && UnitHome(w, resident) == home do continue
		building.homeResident = 0
		if BuildingKindOf(building.type) != .Home || building.health <= d32.ZERO ||
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
		bestDistance: u64 = 0
		for home := head^; home >= 0; home = nextHome[home] {
			distance, validDistance := d32.WrappedDistanceSquared(
				w.units.x[slot],
				w.units.y[slot],
				TileCenterPosition(w.buildings.x[home]),
				TileCenterPosition(w.buildings.y[home]),
				worldWidthRaw,
				worldHeightRaw,
			)
			assert(validDistance)
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
			if town.alarmActive || UnitFindNearbyEnemy(w, unitSlot, d32.FromInt(FLEE_THREAT_RADIUS)) >= 0 do continue
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
				UnitTileX(w, unitSlot),
				UnitTileY(w, unitSlot),
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
	weather.food = d32.Mul(weather.food, eventFood)
	weather.water = d32.Mul(weather.water, eventWater)
	weather.growth = d32.Mul(weather.growth, eventGrowth)

	workingFarmlands := min(town.farmlands, town.farmers)

	// Blockade is a visible town-level condition with a fixed multiplier.
	blockadeFactor := d32.ONE
	if town.blockadeUntilTick > WorldCurrentTick(w) do blockadeFactor = d32.HALF

	town.foodPotential = d32.ZERO
	if town.farmlands > 0 {
		share := d32.FromRatio(i32(workingFarmlands), i32(town.farmlands))
		town.foodPotential = d32.Mul(town.farmlandOutput, share)
	}
	// All weather and event factors are already Q16.16; each multiply truncates.
	foodMultiplier := d32.Mul(KingdomTechFoodMultiplier(w, kingdomSlot, townSlot), blockadeFactor)
	foodMultiplier = d32.Mul(foodMultiplier, weather.food)
	town.foodPotential = d32.Mul(town.foodPotential, foodMultiplier)
	waterStamp := ProfilerBegin("Town:WaterAccess")
	waterAccess := TownWaterAccess(w, kingdomSlot, townSlot)
	ProfilerEnd(waterStamp)
	town.waterPotential = d32.Mul(
		TownWaterCollectorOutput(waterAccess),
		d32.FromInt(i32(town.waterCollectors)),
	)
	town.waterPotential = d32.Mul(
		town.waterPotential,
		KingdomTechWaterMultiplier(w, kingdomSlot, townSlot),
	)
	town.waterPotential = d32.Mul(town.waterPotential, blockadeFactor)
	town.waterPotential = d32.Mul(town.waterPotential, weather.water)

	if TownFindBuilding(w, kingdomSlot, townSlot, .Harbor) >= 0 {
		// Quantize each tick's income before accumulating; per-tick error is at
		// most half a raw unit and the fixed tick order keeps it deterministic.
		income := d32.Mul(
			d32.Mul(d32.FromRatio(1, 20), weather.harbor),
			PositionFromF32(deltaTime),
		)
		town.wood = d32.Add(town.wood, income)
	}
	FishingFlotillaFx(w, kingdomSlot, townSlot)
	town.foodShortage = TownResourceShortage(town.foodPotential, town.citizens)
	town.waterShortage = TownResourceShortage(town.waterPotential, town.citizens)

	era := TownEra(w, kingdomSlot, townSlot)
	town.growthInterval = d32.FromInt(i32(TOWN_ERAS[era].interval))
	town.growthBatch = TownEffectiveBatch(w, kingdomSlot, townSlot)
	town.growthRate = d32.Div(d32.FromInt(i32(town.growthBatch)), town.growthInterval)

	populationNeed := d32.FromRatio(
		i32(town.citizens+town.growthBatch)*GROWTH_FOOD_PER_CITIZEN_MILLE,
		1000,
	)
	canGrow := town.foodPotential >= populationNeed && town.waterPotential >= populationNeed
	limitingSupply := min(town.foodPotential, town.waterPotential)
	coverage := d32.ONE
	if populationNeed > d32.ZERO {
		coverage = clamp(d32.Div(limitingSupply, populationNeed), d32.ZERO, d32.FromRatio(3, 2))
	}
	// A town always grows at least at the minimum speed, even with no food or
	// water at all, so a bad start cannot permanently strand it.
	speed := clamp(
		coverage,
		d32.FromRatio(GROWTH_MIN_SPEED_PERCENT, 100),
		d32.FromRatio(GROWTH_MAX_SPEED_PERCENT, 100),
	)
	villagerBonus := min(
		d32.FromRatio(GROWTH_VILLAGER_SPEED_CAP_PERCENT, 100),
		d32.FromRatio(i32(town.villagers)*GROWTH_VILLAGER_SPEED_BONUS_MILLE, 1000),
	)
	speed = d32.Mul(speed, d32.Add(d32.ONE, villagerBonus))
	if town.blockadeUntilTick > WorldCurrentTick(w) {
		speed = d32.Mul(speed, d32.FromRatio(75, 100))
	}
	speed = d32.Mul(speed, weather.growth)
	isNight := WorldIsNight(w)
	if isNight do speed = d32.ZERO
	town.growthSpeed = speed

	// deltaTime stays f32; the whole tick's cooldown decrement is quantized once.
	decrement := d32.Mul(PositionFromF32(deltaTime), speed)
	town.growthCooldown = d32.Sub(town.growthCooldown, decrement)
	if !isNight && weather.growth > d32.FromRatio(1, 100) && town.growthCooldown <= d32.ZERO {
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
				town.growthCooldown = d32.ZERO
			}
		} else {
			town.growthCooldown = d32.FromInt(TOWN_GROWTH_FAIL_COOLDOWN)
		}
	}

	if town.builders > 0 {
		town.constructionProgress = d32.Add(
			town.constructionProgress,
			PositionFromF32(f32(town.builders)*deltaTime),
		)
		updateTick := WorldCurrentTick(w)/TOWN_UPDATE_SLICES
		phase := (updateTick+u64(kingdomSlot*TOWN_CAPACITY+townSlot))%
			TOWN_CONSTRUCTION_ATTEMPT_INTERVAL
		if WorldCurrentTick(w) >= town.constructionFailUntilTick &&
			town.constructionProgress >= d32.FromInt(3) && phase == 0 {
			constructionStamp := ProfilerBegin("Town:Construction")
			if TownBuilderConstruct(w, kingdomSlot, townSlot, canGrow) {
				town.constructionProgress = d32.Sub(town.constructionProgress, d32.FromInt(3))
				town.constructionFailUntilTick = 0
			} else {
				town.constructionProgress = min(town.constructionProgress, d32.FromInt(3))
				town.constructionFailUntilTick = WorldCurrentTick(w)+TOWN_CONSTRUCTION_FAIL_TICKS
			}
			ProfilerEnd(constructionStamp)
		} else {
			town.constructionProgress = min(town.constructionProgress, d32.FromInt(3))
		}
	}

	milestoneStamp := ProfilerBegin("Town:Milestone")
	TownMilestoneCheck(w, kingdomSlot, townSlot)
	ProfilerEnd(milestoneStamp)
}


TownResourceShortage :: proc(potential: d32.Value, citizens: int) -> d32.Value {
	need := d32.FromRatio(i32(citizens)*GROWTH_FOOD_PER_CITIZEN_MILLE, 1000)
	if need <= d32.ZERO do return d32.ZERO
	return clamp(d32.Sub(d32.ONE, d32.Div(potential, need)), d32.ZERO, d32.ONE)
}

// Each collector produces a baseline even with no fresh water in reach; nearby
// lakes and rivers add the rest. Island towns therefore keep growing, just on a
// smaller and more expensive water supply.
WATER_COLLECTOR_MAX_OUTPUT_PERCENT :: 20
WATER_COLLECTOR_DRY_OUTPUT_PERCENT :: 10

TownWaterCollectorOutput :: proc(waterAccess: d32.Value) -> d32.Value {
	access := clamp(waterAccess, d32.ZERO, d32.ONE)
	maximum := d32.FromRatio(WATER_COLLECTOR_MAX_OUTPUT_PERCENT, 100)
	dry := d32.FromRatio(WATER_COLLECTOR_DRY_OUTPUT_PERCENT, 100)
	return d32.Add(dry, d32.Mul(d32.Sub(maximum, dry), access))
}

// Water farther than this cannot realistically supply a town, and scanning the
// whole world per town made the first simulation tick extremely slow.
TOWN_WATER_SEARCH_RADIUS :: 64

TownWaterAccess :: proc(w: ^World, kingdomSlot, townSlot: int) -> d32.Value {
	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	if town.waterAccessCached && town.waterAccessTerrainRevision == w.terrainRevision {
		return town.waterAccess
	}

	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 do return d32.ZERO

	centerX := town.x+2
	centerY := town.y+2
	radius := min(TOWN_WATER_SEARCH_RADIUS, min(worldWidth, worldHeight))
	nearestDistanceSquared := 0
	foundWater := false
	for offsetX in -radius..=radius {
		x := WorldWrapCoordinate(centerX+offsetX, worldWidth)
		for offsetY in -radius..=radius {
			y := WorldWrapCoordinate(centerY+offsetY, worldHeight)
			tileType := WorldTileAt(w, x, y).type
			if TILE_DEFS[tileType].water <= d32.ZERO do continue
			distanceSquared := offsetX*offsetX + offsetY*offsetY
			if !foundWater || distanceSquared < nearestDistanceSquared {
				nearestDistanceSquared = distanceSquared
				foundWater = true
			}
		}
	}

	town.waterAccess = d32.ZERO
	if foundWater {
		// Sqrt rounds down and Div truncates, so access never overestimates.
		distance := d32.Sqrt(d32.FromInt(i32(nearestDistanceSquared)))
		town.waterAccess = d32.Div(d32.ONE, d32.Add(d32.ONE, distance))
	}
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
		if unitSlot, ok := UnitSpawn(w, role, TileCenterPosition(x), TileCenterPosition(y), kingdomSlot, townSlot); ok {
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
				if unitSlot, ok := UnitSpawn(w, role, TileCenterPosition(x), TileCenterPosition(y), kingdomSlot, townSlot); ok {
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
			if unitSlot, ok := UnitSpawn(w, role, TileCenterPosition(x), TileCenterPosition(y), kingdomSlot, townSlot); ok {
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
