# Things to do
- Description to enrich the world of the buildings and units. Some descriptions already overflow by accident the inspection windows. It should resize automatically, so we can translate to other languages later. It should even introduce some interesting lore and mystic
- Debug/stress world with a command argument to test the whole game with a lot of buildings and units already, etc.
- Optimization and bugs solving
- RL AI implementation
- Menu improvement, more similar to the civ VI menu
- Multiplayer
 
# Ideas

# Bugs
- Shadow of home/house is a bit lower. I think we should recheck all building shadows. Also shadows of units jumping is not excellent.
- We need to stress test defense of towns, I have seen attacking indenpendent towns that they don't defend it completly. The attacking units are in the area of the town and even atacking the townhall and the I don't know if get stuck on the back of the townhall or not even detect him. Because I have seen that they are even idle most of the time.

# Corrections

# Things to check
- Easy to see what kingdom is from the town defended or attacked in the townhall options and by arrows color when town selected

# Weather plan

This is the working design for biomes, weather and environmental events. The
rule is simple: **nothing is decorative; every system feeds another**. Weather
changes yields, fire, vision, movement, terrain and orders, and the world
remembers the aftermath.

## Answers to the design questions

1. **Weather is global.** There is one world-wide weather state: one front, one
   wind vector, one temperature. Biomes and tile types change how that weather
   *expresses itself* (snow in the taiga, dust in the desert, monsoon in the
   jungle), but every kingdom is under the same sky at the same time. This is
   also the main fairness lever.
2. **Events can be lethal, but they must vary.** Events are grouped in four
   severity tiers, from flavour to region-altering cataclysm. Minor and moderate
   events mostly hurt the economy; major events can kill units; cataclysms can
   rewrite the map. A weighted bag guarantees variety and prevents repeats.
3. **New `TileType`s, full refactor allowed and preferred.** No legacy
   compatibility is required. The tile roster is redesigned below, together with
   a `TileDef` data table so future tile work does not mean editing every
   exhaustive switch. Existing switches will be migrated in the same pass.
4. **Fair over the long run, not simultaneously.** Global weather is symmetric,
   but events are local, so two kingdoms can have very different minutes. A debt
   system tracks who was recently punished; targeting weights favour kingdoms
   that have been safe for a while, and trailing kingdoms receive relief. Over a
   full game every kingdom sees a comparable share of good and bad.
5. **Session length per era is estimated below** from the current growth
   constants, not designed from scratch. Target: ~40 minutes for a decisive game,
   with 30–55 minutes as the normal band.

## Design pillars

- **Two axes.** `TileType` is physical terrain. `ClimateKind` is a coarse region
  grid used by weather and yields. Do not overload one enum with both meanings.
- **Flow through existing numbers.** Weather modifies `foodPotential`,
  `waterPotential`, growth speed, movement and fire; the AI and UI then react
  for free because they already read those values.
- **Forecast, then consequence.** Every harmful event is announced and has
  counterplay in terrain, tech, town policy or unit behaviour. No hidden losses.
- **Aftermath changes the map.** Burned forest becomes ash and later fertile
  ground, floods enrich soil, blizzards freeze lakes, eruptions raise hills.
  This is where biomes stop being paint.
- **No building per weather.** Counterplay comes from terrain, existing
  infrastructure (Granary, Harbor, Paths, Homes), techs and behaviour, not a
  checklist of one-use buildings.

## Tile model (full refactor)

Proposed `TileType` roster. `Mountain` and `Lava` can be deferred to phase 4 if
scope grows.

| Tile | Role | Movement | Economy | Risk / special |
|---|---|---|---|---|
| `Ocean` | Salt water | Land units blocked | Fishing via Harbor | Storm surge, blockade |
| `Lake` | Fresh water | Land units blocked | Drinking water | Freezes in winter, drown risk |
| `River` | Fresh water | Crossing cost | Drinking water | Flood source |
| `Ice` | Frozen water | Crossable, slippery | Fishing penalty | Melts in spring, drowns if caught |
| `Marsh` | Wetland | Slow | Reeds, fresh water | Disease, flood buffer, drains slowly |
| `Sand` | Coast / dry shore | Normal | Poor | Storms, glass/salt later |
| `Grassland` | Baseline | Normal | Grazing, average | Low cover, grassfire |
| `Plains` | Farmland | Normal | Best food | Low cover, locusts |
| `Forest` | Woodland | Slow | Wood, hunting | Vision cover, fire fuel |
| `Taiga` | Cold woodland | Slower | Wood | Snow, rare fire, poor food |
| `Steppe` | Dry grass | Fast | Herds, cavalry | Wind, grassfire, locusts |
| `Hill` | High ground | Slow | Stone | Vision, wind, flood-safe |
| `Mountain` | Impassable highland | Blocked | Stone | Snowcap, impassable barrier |
| `Desert` | Arid | Slow | Poor water | Heat, sandstorm |
| `Tundra` | Permafrost | Slow | Poor | Blizzard, freezing |
| `Ash` | Recent burn / eruption | Normal | Poor, then fertile | Low fire, regrows |
| `Lava` | Event only | Blocked | None | Ignites, cools to ash/hill |

### Tile data table

Replace scattered tile switches with one table:

```odin
TileDef :: struct {
	name:        cstring,
	moveCost:    f32,
	wood:        f32,
	food:        f32,
	water:       f32, // contribution to TownWaterAccess
	fireRisk:    f32,
	visionCover: f32,
	buildable:   bool,
	passable:    bool,
}

TILE_DEFS := [TileType]TileDef{ /* one entry per tile */ }
```

`BuildingValidTileType`, `UnitValidTileType` and `TileTypeAntiFire` stay, but read
from `TILE_DEFS` where possible so adding a tile is one table entry plus art.

### Climate layer

A coarse `ClimateKind` grid (one cell per ~16 tiles) generated from the same
periodic noise as the terrain:

`Temperate`, `Arid`, `Boreal`, `Tropical`, `Steppe`, `Volcanic`, `Coastal`.

Weather reads this grid to decide whether rain becomes snow, whether a storm
becomes a sandstorm, and whether a flood becomes monsoon flooding. It is also a
cheap way to give each region its own personality without per-tile storage.

## Weather model

### Seasons

- `Spring`, `Summer`, `Autumn`, `Winter`, one day each (7 real minutes).
- Seasons bias weather weights and tile transitions: snow melts in spring, lakes
  freeze in winter, wildfire risk peaks in summer, storms peak in autumn.
- The game starts in spring of year 1.

### Global state

```odin
WeatherKind :: enum {
	Clear, Rain, Storm, Fog, Snow, Blizzard,
	Drought, Heatwave, Sandstorm, Ashfall,
}

WeatherState :: struct {
	kind:          WeatherKind,
	intensity:     f32, // 0..1, ramps in/out over 20–40 s
	remaining:     f32,
	nextKind:      WeatherKind,
	windX, windY:  f32, // global unit wind, changes slowly
	season:        Season,
	seasonDay:     int,
}
```

- One front at a time, global. Forecast shows `kind`, intensity trend and the
  next front.
- Wind is a global vector. It advects fire, gas clouds, smoke and embers, and
  pushes rain/snow visuals. It changes every few minutes, never instantly.

### Weather effects

| Weather | Towns | Units | Existing system it touches |
|---|---|---|---|
| Clear | Baseline | Baseline | — |
| Rain | Growth/water up, fire out | Wet: slower, fire resistant | `foodPotential`, `waterPotential`, fire |
| Storm | Harbor output down | Strong wind, lightning fires, vision down | fire, fog, movement |
| Fog | Slight growth penalty | Vision strongly reduced | `FogUpdate`, `UnitDefaultVision` |
| Snow | Food down, water from snow | Slow, cold damage, ice forms | hazards, `UnitEffects` |
| Blizzard | Growth stalls | Lethal cold, near-zero vision | hazards, shelters |
| Drought | Water and food collapse | Slower, heat stress | `TownWaterAccess`, wells |
| Heatwave | Fire risk up | Heat stress, faster travel? | fire, growth |
| Sandstorm | Desert towns lose production | Vision/movement down, damage | vision, movement |
| Ashfall | Growth down, then fertility up | Vision down, breathing damage | terrain, fire |

New `UnitEffects`: `Wet`, `Chilled`, `HeatStressed`, `Sick` (swamp/ash). Each gets
an icon and tooltip like `Poisoned` does today.

## Environmental events

### Severity tiers

| Tier | Rhythm | Lethality | Examples |
|---|---|---|---|
| Minor | every 1–2 min | None | Gust, light rain, heat shimmer |
| Moderate | every 3–5 min | Economic, rare deaths | Thunderstorm, drought spell, cold snap, minor flood |
| Major | every 6–10 min | Deaths likely | Wildfire, blizzard, river flood, locusts, earthquake |
| Cataclysm | 15–25 min cooldown, max 2/game | Region-altering | Eruption, hurricane, megafire, meteor shower |

No cataclysm before era 3, and no events at all in the first 3 minutes.

### Event table

| Event | Telegraph | Effect | Aftermath |
|---|---|---|---|
| Wildfire | Smoke column, alarm | Spreads with wind through Forest/Taiga/Steppe | Forest → Ash → fertile regrowth |
| Flood | Dark clouds, river swell | Reuses flood hazard, drowns land units | Enriched soil, destroyed paths |
| Drought | Heat shimmer, forecast | Water/food collapse, fire ignites | Dry rivers and lakes, recover on rain |
| Blizzard | Whiteout front | Vision/movement near zero, cold damage | Lakes freeze, snow cover |
| Earthquake | Tremor ring, camera shake | Building damage in a region | Cracks, exposed stone |
| Eruption | Ash column, rumble | Destroys a region, lava and fire | New hills, very fertile ash |
| Locusts | Moving cloud | Eats farmland output | Temporary famine |
| Hurricane | Large rotating front | Storm + flood + building damage | Flotsam, salt-fertile shores |
| Meteor shower | Shooting stars, warnings | Small impacts, fires | Scorched craters, rare stone |

### Variety and fairness rules

- Each event is drawn from a **weighted bag per severity**; a kind cannot repeat
  while other kinds are still in the bag.
- `eventDebt[kingdom]` rises while a kingdom is safe and drops when it is hit;
  target weight scales with debt. The same kingdom cannot be the target of two
  major events in a row.
- Cataclysms target the current leader more often, but the debt system offsets
  that over the game.
- Trailing kingdoms (one or more eras behind the leader) receive relief:
  favourable weather weight and reduced event targeting. Relief is not hidden;
  it appears in the forecast as “calm front”.
- Because weather is global, harvests and storms are shared. Only disasters are
  local, which keeps the short term dramatic and the long term fair.

## Player agency and counterplay

- **Terrain:** hills for flood safety, rivers for drought, forest for sandstorms,
  away from ash for eruptions, ice for winter crossing.
- **Existing buildings:** Granary (famine), Harbor (storms/fishing), Homes
  (shelter), Paths (firebreaks, faster mud travel).
- **Techs:** Irrigation, Crop Rotation, Storm Shelters, Fire Wardens, Drainage.
  One branch per climate problem, shared across weather types.
- **Behaviour:** units auto-shelter during blizzards, water collectors prioritise
  during drought, AI harvests before winter.
- **Orders:** rain weakens Napalm, boosts Glacier; wind pushes Miasma gas;
  drought makes fire orders devastating and wildfire events cheaper to trigger.

## Visuals and UI

- HUD climate chip: season, weather icon, intensity, wind arrow, remaining time,
  and the next front.
- Map: biome tint, seasonal colour grading, screen-space rain/snow/ash/dust
  particles, lightning flashes, wet ground sheen, smoke columns visible from far
  away, snow accumulation on tiles.
- Events: map warning ring at the target, banner + alert entry, camera shake for
  quake/eruption, then aftermath visuals.
- Town panel: environment effects row with icons and descriptions, like unit
  effects.
- Audio: rain, wind gusts, thunder, fire crackle, crowd alarm, all intensity-aware.

## Technical integration

- `World` gains one `WeatherState`, one `ClimateKind` grid, one `eventDebt` array
  and one active-event record.
- Weather ticks at **1 Hz**, not per frame. Effects are sampled per town/unit;
  rendering samples only on-screen tiles.
- All randomness derives from `w.seed + dayNumber + simulationTime`.
- Terrain mutation goes through one proc that bumps `terrainRevision` and
  invalidates `waterAccessCached`, `coastalCached`, navigation and fog.
- Hook points: `WorldUpdate` (weather/season tick), `KingdomTownUpdate` (yields),
  `WorldFireIgnite/Update` (wetness, wind), `FogUpdate`/vision, movement speed,
  `OrderStart`/hazards (weather modifiers), `ai.odin` (forecast-aware choices),
  `particles.odin` (Rain, Snow, Ash, Dust, Leaf), `sprites.odin` (tile art).
- Replace per-kind tile switches with `TILE_DEFS` wherever the logic is a simple
  property lookup; keep exhaustive switches only where behaviour is genuinely
  unique.

## Pacing estimates

Assumptions from the current code: 7-minute day, growth active ~61% of the day
(night stops growth), start at 8 villagers, era batches/intervals as in
`TOWN_ERAS`, speed multiplier 1.05–1.4 from villagers, granary, metropolis and
district halls. These are estimates to tune against playtests.

| Era | Citizens | Growth batches | Estimated time | Cumulative |
|---|---|---|---|---|
| 1 | 8 → 18 | ~10 × 1 | 5–7 min | 5–7 min |
| 2 | 18 → 45 | ~6 × 5 | 6–8 min | 11–15 min |
| 3 | 45 → 100 | ~3 × 20 | 7–9 min | 18–24 min |
| 4 | 100 → 200 | ~2 × 60 | 8–11 min | 26–35 min |
| 5 | 200 → 380 | ~2 × 150 | 10–14 min | 36–49 min |

Target session: **~40 minutes** for a decisive game, 30–55 minutes normal,
up to ~60 for a stalemate resolved by fusion or cataclysm. Expansion and fusion
shorten the late eras; a passive game stretches them.

Weather pacing tuned to that:

- 1 season = 1 day = 7 min → a 40-minute game sees ~5–7 seasons.
- One weather front every 2–3 minutes, with 20–40 s ramps.
- Minor events every 1–2 min, moderate every 3–5, major every 6–10.
- A cataclysm can first appear in era 3; at most two per game.
- Result: every era feels different, and no player is expected to survive more
  than one cataclysm without preparation.

## Phased delivery

1. **Tile refactor.** New `TileType` roster, `TILE_DEFS`, climate grid, migration
   of all exhaustive switches, movement/water/fire/yield properties. No weather
   yet, but the map already plays differently.
2. **Global weather + seasons.** One weather state, rain/drought/snow, HUD chip,
   screen-space particles, yield and fire modifiers, AI aware of the forecast.
3. **Events framework.** Severity, weighted bags, debt-based fairness, telegraphs,
   alerts and the active-event lifecycle.
4. **Lethal events + aftermath.** Wildfire, flood, blizzard, earthquake, terrain
   mutation and the ash/fertile regrowth loop.
5. **Cataclysms + polish.** Eruption, hurricane, locusts, meteor shower, audio,
   seasonal art and balance passes.

Each phase should be playable on its own.

## Still open

- Exact tile art budget: 17 tiles × 4 seasons is a lot; start with one seasonal
  tint pass and unique art only for the tiles that change silhouette.
- Whether relief should be visible as a mechanic or only as favourable weather.
- Final event frequencies after the first playtest of phase 3.
