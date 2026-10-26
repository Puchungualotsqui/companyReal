package main

import rl "vendor:raylib"
import "core:fmt"
import "core:math"

UICanControlKingdom :: proc(w: ^World, kingdom: int) -> bool {
	return WorldLocalKingdom(w) == kingdom
}

SelectionKind :: enum {
	None,
	Unit,
	Building,
}

Selection :: struct {
	kind: SelectionKind,
	slot: int,
}

UITownTab :: enum {
	Town,
	Orders,
	Works,
}

// Command modes arm the map for the next click. Inspect is the normal mode.
UICommand :: enum {
	Inspect,
	Attack,
	Defend,
	Found,
	Fuse,
	Build,
	Place,
}

UIPanelMode :: enum {
	None,
	Towns,
	Diplomacy,
}

UIState :: struct {
	selection: Selection,
	hover:     Selection,
	tab:       UITownTab,
	command:   UICommand,
	buildKind: BuildingKind,
	buildKingdom, buildTown: int,
	panel:      UIPanelMode,
	townScroll: int,
}

UI_COLOR_BG := rl.Color{26, 24, 28, 240}
UI_COLOR_HEADER := rl.Color{40, 37, 42, 255}
UI_COLOR_BORDER := rl.Color{12, 11, 14, 255}
UI_COLOR_BORDER_INNER := rl.Color{96, 88, 76, 255}
UI_COLOR_TEXT := rl.Color{222, 214, 198, 255}
UI_COLOR_DIM := rl.Color{152, 144, 130, 255}
UI_COLOR_GOLD := rl.Color{224, 176, 70, 255}
UI_COLOR_DIVIDER := rl.Color{58, 53, 48, 255}
UI_COLOR_BUTTON := rl.Color{52, 48, 54, 255}
UI_COLOR_BUTTON_HOVER := rl.Color{72, 66, 74, 255}
UI_COLOR_BUTTON_OFF := rl.Color{36, 33, 38, 255}
UI_COLOR_DISABLED_TEXT := rl.Color{88, 84, 78, 255}

UI_PANEL_WIDTH : f32 : 380
UI_MARGIN : f32 : 16
UI_PAD : f32 : 14
UI_TEXT_SIZE : f32 : 20
UI_TITLE_SIZE : f32 : 30
UI_HEADER_H : f32 : 92
UI_DESC_Y : f32 : 102
UI_STAT_Y : f32 : 136
UI_STAT_H : f32 : 24
UI_GROWTH_Y : f32 : 264
UI_GROWTH_H : f32 : 20
UI_TOWN_DIVIDER : f32 : 290
UI_TABS_Y : f32 : 298
UI_TABS_H : f32 : 24
UI_SECTION_HEADER : f32 : 26
UI_ROWS_TOP : f32 : 330
UI_ROW_HEIGHT : f32 : 36
UI_CONSTRUCTION_ROW_HEIGHT : f32 : 28
UI_BUTTON : f32 : 20
UI_TEXT_BUTTON_H : f32 : 26

UI_TOWN_TABS := [3]cstring{"TOWN", "ORDERS", "WORKS"}

UI_EFFECT_ROW_H : f32 : 30

UI_COMMAND_BUTTON_W : f32 : 84
UI_COMMAND_BUTTON_H : f32 : 68
UI_COMMAND_GAP : f32 : 12

UI_COLOR_ATTACK := rl.Color{226, 96, 76, 220}
UI_COLOR_DEFEND := rl.Color{106, 178, 224, 220}
UI_COLOR_BUILD := rl.Color{214, 178, 92, 220}
UI_COLOR_FOUND := rl.Color{196, 156, 226, 220}
UI_COLOR_FUSE := rl.Color{224, 176, 70, 220}
UI_COLOR_ATTACK_FAINT := rl.Color{226, 96, 76, 140}
UI_COLOR_DEFEND_FAINT := rl.Color{106, 178, 224, 140}
UI_COLOR_GOOD := rl.Color{112, 200, 126, 255}
UI_COLOR_BAD := rl.Color{226, 96, 76, 255}

UI_CONVERSION_KINDS := [len(UnitKind)-1]UnitKind{
	.Builder,
	.CombatBuilder,
	.WaterCollector,
	.Farmer,
	.Explorer,
	.Knight,
	.Archer,
	.Mage,
	.Giant,
	.Turtle,
	.Catapult,
	.Rogue,
}

UI_COMBAT_BUILD_KINDS := [4]BuildingKind{
	.Wall,
	.Bridge,
	.Watchtower,
	.Cannon,
}

UIStat :: struct {
	label, value: cstring,
	color:       rl.Color,
	icon:        rl.Texture2D, // Drawn after the label when set
}

UI_FOUND_REQ_ICON : f32 : 18
UI_FOUND_REQ_GAP : f32 : 14
UI_FOUND_REQ_TEXT_GAP : f32 : 5
UI_FOUND_HINT_TEXT_SIZE : f32 : 16

UIFoundRequirementIcon :: enum {
	Wood,
	Settlers,
	Builders,
}

UIFoundRequirement :: struct {
	icon:             UIFoundRequirementIcon,
	current, required: int,
}

UI_FONT_BODY_DATA :: #load("assets/fonts/PixelifySans-Regular.ttf")
UI_FONT_TITLE_DATA :: #load("assets/fonts/PixelifySans-Bold.ttf")

@(private = "file")
uiFonts: struct {
	body, title, menu: rl.Font,
	loaded:             bool,
}

// raylib rasterizes glyphs with anti-aliasing; the UI is pixel art, so the
// atlas is thresholded to hard alpha edges before it is used. The image keeps
// its native layout because UpdateTexture reinterprets the raw bytes.
@(private = "file")
UIFontCrisp :: proc(font: ^rl.Font) {
	image := rl.LoadImageFromTexture(font.texture)
	defer rl.UnloadImage(image)
	pixels := cast([^]u8)image.data
	pixelCount := int(image.width)*int(image.height)

	#partial switch image.format {
	case .UNCOMPRESSED_GRAY_ALPHA:
		for index in 0 ..< pixelCount {
			alpha := &pixels[index*2+1]
			alpha^ = alpha^ < 128 ? 0 : 255
		}
	case .UNCOMPRESSED_GRAYSCALE:
		for index in 0 ..< pixelCount {
			value := &pixels[index]
			value^ = value^ < 128 ? 0 : 255
		}
	case .UNCOMPRESSED_R8G8B8A8:
		for index in 0 ..< pixelCount {
			alpha := &pixels[index*4+3]
			alpha^ = alpha^ < 128 ? 0 : 255
		}
	case:
		return
	}
	rl.UpdateTexture(font.texture, image.data)
}

@(private = "file")
UIFontLoad :: proc(data: []u8, size: i32) -> rl.Font {
	font := rl.LoadFontFromMemory(".ttf", raw_data(data), i32(len(data)), size, nil, 0)
	if font.texture.id == 0 do return rl.GetFontDefault()
	UIFontCrisp(&font)
	rl.SetTextureFilter(font.texture, .POINT)
	return font
}

@(private = "file")
UIFontInit :: proc() {
	if uiFonts.loaded do return
	uiFonts.body = UIFontLoad(UI_FONT_BODY_DATA, i32(UI_TEXT_SIZE))
	uiFonts.title = UIFontLoad(UI_FONT_TITLE_DATA, i32(UI_TITLE_SIZE))
	uiFonts.menu = UIFontLoad(UI_FONT_TITLE_DATA, 56)
	uiFonts.loaded = true
}

UIFont :: proc() -> rl.Font {
	UIFontInit()
	return uiFonts.body
}

UITitleFont :: proc() -> rl.Font {
	UIFontInit()
	return uiFonts.title
}

UIMenuFont :: proc() -> rl.Font {
	UIFontInit()
	return uiFonts.menu
}

WorldUIDeinit :: proc() {
	if !uiFonts.loaded do return
	// A failed load falls back to the shared default font, which must not be freed.
	defaultTexture := rl.GetFontDefault().texture.id
	if uiFonts.body.texture.id != defaultTexture do rl.UnloadFont(uiFonts.body)
	if uiFonts.title.texture.id != defaultTexture do rl.UnloadFont(uiFonts.title)
	if uiFonts.menu.texture.id != defaultTexture do rl.UnloadFont(uiFonts.menu)
	uiFonts = {}
}

UIText :: proc(text: cstring, x, y: f32, color: rl.Color) {
	rl.DrawTextEx(UIFont(), text, rl.Vector2{x, y}, UI_TEXT_SIZE, 1, color)
}

UITitle :: proc(text: cstring, x, y: f32, color: rl.Color) {
	rl.DrawTextEx(UITitleFont(), text, rl.Vector2{x, y}, UI_TITLE_SIZE, 1, color)
}

UITextRight :: proc(text: cstring, right, y: f32, color: rl.Color) {
	width := rl.MeasureTextEx(UIFont(), text, UI_TEXT_SIZE, 1).x
	rl.DrawTextEx(UIFont(), text, rl.Vector2{right-width, y}, UI_TEXT_SIZE, 1, color)
}

UITextCenter :: proc(text: cstring, centerX, y: f32, color: rl.Color) {
	width := rl.MeasureTextEx(UIFont(), text, UI_TEXT_SIZE, 1).x
	rl.DrawTextEx(UIFont(), text, rl.Vector2{centerX-width*0.5, y}, UI_TEXT_SIZE, 1, color)
}

UIUnitName :: proc(kind: UnitKind) -> cstring {
	switch kind {
	case .Villager:
		return "Villager"
	case .Builder:
		return "Builder"
	case .CombatBuilder:
		return "Combat Builder"
	case .WaterCollector:
		return "Water Collector"
	case .Farmer:
		return "Farmer"
	case .Knight:
		return "Knight"
	case .Archer:
		return "Archer"
	case .Mage:
		return "Mage"
	case .Giant:
		return "Giant"
	case .Turtle:
		return "Turtle"
	case .Catapult:
		return "Catapult"
	case .Rogue:
		return "Rogue"
	case .Explorer:
		return "Explorer"
	}
	unreachable()
}

UIBuildingName :: proc(kind: BuildingKind) -> cstring {
	switch kind {
	case .TownHall:
		return "Town Hall"
	case .Home:
		return "Home"
	case .Farmland:
		return "Farmland"
	case .Wall:
		return "Wall"
	case .Bridge:
		return "Bridge"
	case .Cannon:
		return "Cannon"
	case .Watchtower:
		return "Watchtower"
	case .ArcheryRange:
		return "Archery Range"
	case .MagicSchool:
		return "Magic School"
	case .GiantPen:
		return "Giant Pen"
	case .SiegeWorkshop:
		return "Siege Workshop"
	case .TurtlePen:
		return "Turtle Pen"
	case .ThievesGuild:
		return "Thieves' Guild"
	case .Path:
		return "Path"
	case .DistrictHall:
		return "District Hall"
	}
	unreachable()
}

UIUnitDescription :: proc(kind: UnitKind) -> cstring {
	switch kind {
	case .Villager:
		return "The realm's workforce."
	case .Builder:
		return "Raises and repairs buildings."
	case .CombatBuilder:
		return "Raises combat buildings in the field."
	case .WaterCollector:
		return "Carries water from lakes, rivers or the sea."
	case .Farmer:
		return "Works the fields for food."
	case .Knight:
		return "Armoured melee infantry."
	case .Archer:
		return "Ranged support. Fragile."
	case .Mage:
		return "Area damage from afar."
	case .Giant:
		return "Slow, huge, devastating."
	case .Turtle:
		return "Armoured. Crosses water."
	case .Catapult:
		return "Siege engine. Slow, long range."
	case .Rogue:
		return "Fast raider. Strikes and runs."
	case .Explorer:
		return "Scouts the frontier through fog of war."
	}
	unreachable()
}

UIBuildingDescription :: proc(kind: BuildingKind) -> cstring {
	switch kind {
	case .TownHall:
		return "Seat of the town."
	case .Home:
		return "Houses the townsfolk."
	case .Farmland:
		return "Produces food."
	case .Wall:
		return "Blocks enemy movement."
	case .Bridge:
		return "Crosses water."
	case .Cannon:
		return "Static gun emplacement."
	case .Watchtower:
		return "Cheap ranged outpost. Sees far, hits light."
	case .ArcheryRange:
		return "Trains archers."
	case .MagicSchool:
		return "Trains mages."
	case .GiantPen:
		return "Trains giants."
	case .SiegeWorkshop:
		return "Trains catapults."
	case .TurtlePen:
		return "Trains turtles."
	case .ThievesGuild:
		return "Trains rogues."
	case .Path:
		return "A trodden road. Units move faster."
	case .DistrictHall:
		return "A fused town's old hall. Its district grows the merged town."
	}
	unreachable()
}

UITownPathName :: proc(path: TownPath) -> cstring {
	switch path {
	case .Rangers:
		return "Rangers"
	case .Mystics:
		return "Mystics"
	case .Beasts:
		return "Beasts"
	case .Siege:
		return "Siege"
	case .Tide:
		return "Tide"
	case .Shadows:
		return "Shadows"
	case .Bastion:
		return "Bastion"
	case .Logistics:
		return "Logistics"
	case .Conquest:
		return "Conquest"
	case .Dominion:
		return "Dominion"
	}
	unreachable()
}

UIUnitStateName :: proc(state: UnitState) -> cstring {
	switch s in state {
	case StatePacific:
		switch s {
		case .Roaming:
			return "Roaming"
		case .Traveling:
			return "Travelling"
		case .Working:
			return "Working"
		case .Returning:
			return "Returning"
		case .ToConstruction:
			return "To site"
		case .Building:
			return "Building"
		case .GoingHome:
			return "Going home"
		case .Sleeping:
			return "Resting"
		case .Hiding:
			return "Sheltering"
		case .Fleeing:
			return "Fleeing enemies"
		}
	case StateWarrior:
		switch s.activity {
		case .Idle:
			return "Idle"
		case .Moving:
			return "Moving"
		case .Escorting:
			return "Escorting"
		case .Attacking:
			return "Fighting"
		}
	case StateConverting:
		return "Retraining"
	}
	return "Unknown"
}

UIUnitFromTraining :: proc(kind: BuildingKind) -> UnitKind {
	switch kind {
	case .ArcheryRange:
		return .Archer
	case .MagicSchool:
		return .Mage
	case .GiantPen:
		return .Giant
	case .SiegeWorkshop:
		return .Catapult
	case .TurtlePen:
		return .Turtle
	case .ThievesGuild:
		return .Rogue
	case .TownHall, .Home, .Farmland, .Wall, .Bridge, .Cannon, .Watchtower, .Path, .DistrictHall:
		return .Villager
	}
	unreachable()
}

UISelectionValid :: proc(w: ^World, selection: Selection) -> bool {
	switch selection.kind {
	case .Unit:
		return selection.slot >= 0 && selection.slot < UNIT_CAPACITY &&
			w.unitUsed[selection.slot] && w.units[selection.slot].type != nil &&
			FogUnitVisible(w, selection.slot)
	case .Building:
		return selection.slot >= 0 && selection.slot < BUILDING_CAPACITY &&
			w.buildingUsed[selection.slot] && FogBuildingVisible(w, selection.slot)
	case .None:
		return false
	}
	return false
}

UISelectionTownHall :: proc(w: ^World, selection: Selection) -> bool {
	if selection.kind != .Building || !UISelectionValid(w, selection) do return false
	return BuildingKindOf(w.buildings[selection.slot].type) == .TownHall
}

UISelectionTown :: proc(w: ^World, selection: Selection) -> (kingdom, town: int) {
	switch selection.kind {
	case .Unit:
		return w.units[selection.slot].kingdome, w.units[selection.slot].town
	case .Building:
		return w.buildings[selection.slot].kingdom, w.buildings[selection.slot].town
	case .None:
	}
	return -1, -1
}

UISelectionPlayerTownHall :: proc(w: ^World, selection: Selection) -> bool {
	if !UISelectionTownHall(w, selection) do return false
	kingdom, _ := UISelectionTown(w, selection)
	return UICanControlKingdom(w, kingdom)
}

// --- war orders -----------------------------------------------------------

UIAttackOrderValid :: proc(w: ^World, kingdom, town, targetKingdom, targetTown: int) -> bool {
	if kingdom == targetKingdom do return false
	if !WorldTownExists(w, kingdom, town) || !WorldTownExists(w, targetKingdom, targetTown) {
		return false
	}
	if !FogTownDiscovered(w, targetKingdom, targetTown) do return false
	if w.kingdoms[kingdom].towns[town].attackOrders[targetKingdom][targetTown] {
		return false
	}
	return TownHallSlot(w, targetKingdom, targetTown) >= 0
}

UIDefendOrderValid :: proc(w: ^World, kingdom, town, targetKingdom, targetTown: int) -> bool {
	if targetKingdom == NEUTRAL_KINGDOM do return false
	if kingdom == targetKingdom && town == targetTown do return false
	if !WorldTownExists(w, kingdom, town) || !WorldTownExists(w, targetKingdom, targetTown) {
		return false
	}
	if !FogTownDiscovered(w, targetKingdom, targetTown) do return false
	if KingdomAtWar(w, kingdom, targetKingdom) do return false
	if w.kingdoms[kingdom].towns[town].defendOrders[targetKingdom][targetTown] do return false
	return TownHallSlot(w, targetKingdom, targetTown) >= 0
}

UIAttackTargetExists :: proc(w: ^World, kingdom, town: int) -> bool {
	for targetKingdom in 0..<KINGDOM_SLOTS {
		if !w.kingdomUsed[targetKingdom] do continue
		for targetTown in 0..<TOWN_CAPACITY {
			if !w.kingdoms[targetKingdom].townUsed[targetTown] do continue
			if UIAttackOrderValid(w, kingdom, town, targetKingdom, targetTown) do return true
		}
	}
	return false
}

UIDefendTargetExists :: proc(w: ^World, kingdom, town: int) -> bool {
	for targetKingdom in 0..<KINGDOM_SLOTS {
		if !w.kingdomUsed[targetKingdom] do continue
		for targetTown in 0..<TOWN_CAPACITY {
			if !w.kingdoms[targetKingdom].townUsed[targetTown] do continue
			if UIDefendOrderValid(w, kingdom, town, targetKingdom, targetTown) do return true
		}
	}
	return false
}

UIFusionTargetExists :: proc(w: ^World, kingdom, town: int) -> bool {
	if !WorldTownExists(w, kingdom, town) do return false
	for targetTown in 0..<TOWN_CAPACITY {
		if !w.kingdoms[kingdom].townUsed[targetTown] do continue
		if TownFusionFailure(w, kingdom, town, kingdom, targetTown) == .None do return true
	}
	return false
}

// Counts the town's outgoing attack and defend orders.
UITownOrderCount :: proc(w: ^World, kingdom, town: int) -> int {
	if !WorldTownExists(w, kingdom, town) do return 0
	orders := &w.kingdoms[kingdom].towns[town]
	count := 0
	for targetKingdom in 0..<KINGDOM_SLOTS {
		for targetTown in 0..<TOWN_CAPACITY {
			if !orders.attackOrders[targetKingdom][targetTown] do continue
			if WorldTownExists(w, targetKingdom, targetTown) do count += 1
		}
	}
	for protectedKingdom in 0..<KINGDOMS_CAPACITY {
		for protectedTown in 0..<TOWN_CAPACITY {
			if !orders.defendOrders[protectedKingdom][protectedTown] do continue
			if !WorldTownExists(w, protectedKingdom, protectedTown) do continue
			if protectedKingdom == kingdom && protectedTown == town do continue
			count += 1
		}
	}
	return count
}

// Orders are listed attacks first, then defends.
UITownOrderAt :: proc(w: ^World, kingdom, town, index: int) -> (attack: bool, targetKingdom, targetTown: int, ok: bool) {
	if !WorldTownExists(w, kingdom, town) do return false, -1, -1, false
	orders := &w.kingdoms[kingdom].towns[town]
	count := 0
	for otherKingdom in 0..<KINGDOM_SLOTS {
		for otherTown in 0..<TOWN_CAPACITY {
			if !orders.attackOrders[otherKingdom][otherTown] do continue
			if !WorldTownExists(w, otherKingdom, otherTown) do continue
			if count == index do return true, otherKingdom, otherTown, true
			count += 1
		}
	}
	for protectedKingdom in 0..<KINGDOMS_CAPACITY {
		for protectedTown in 0..<TOWN_CAPACITY {
			if !orders.defendOrders[protectedKingdom][protectedTown] do continue
			if !WorldTownExists(w, protectedKingdom, protectedTown) do continue
			if protectedKingdom == kingdom && protectedTown == town do continue
			if count == index do return false, protectedKingdom, protectedTown, true
			count += 1
		}
	}
	return false, -1, -1, false
}

// --- milestone ------------------------------------------------------------

// The player's first town with an unresolved milestone owns the choice window.
UIMilestoneTown :: proc(w: ^World) -> (kingdom, town: int, pending: bool) {
	local := WorldLocalKingdom(w)
	if local < 0 do return -1, -1, false
	for townSlot in 0..<TOWN_CAPACITY {
		if !w.kingdoms[local].townUsed[townSlot] do continue
		t := &w.kingdoms[local].towns[townSlot]
		if t.milestonePending && t.milestonesChosen < TOWN_MILESTONE_TIER_COUNT {
			return local, townSlot, true
		}
	}
	return -1, -1, false
}

MILESTONE_CAMERA_PAN_SECONDS : f32 : 0.9
UI_FOCUS_CAMERA_PAN_SECONDS : f32 : 0.12

UIMilestoneCameraTarget :: proc(w: ^World, kingdom, town: int) -> (rl.Vector2, bool) {
	if !WorldTownExists(w, kingdom, town) do return {}, false
	if hall := TownHallSlot(w, kingdom, town); hall >= 0 {
		width, height := BuildingTileSize(w.buildings[hall].type)
		return rl.Vector2{
			f32(w.buildings[hall].x)+f32(width)*0.5,
			f32(w.buildings[hall].y)+f32(height)*0.5,
		}, true
	}
	t := &w.kingdoms[kingdom].towns[town]
	width, height := BuildingTileSize(TownHall{})
	return rl.Vector2{f32(t.x)+f32(width)*0.5, f32(t.y)+f32(height)*0.5}, true
}

// A milestone opens a camera session: pan to the first pending town, keep it
// centred while its rewards are chosen, and teleport back to the pre-milestone
// view when nothing is left pending. If another town is queued, pan to it
// without giving the view back first.
WorldMilestoneCameraUpdate :: proc(w: ^World, view: ^WorldView, deltaTime: f32) {
	camera := &view.camera
	cam := &view.milestoneCamera
	kingdom, town, pending := UIMilestoneTown(w)

	if !pending {
		if cam.active {
			camera.target = cam.returnTarget
			camera.zoom = cam.returnZoom
			cam^ = {}
		}
		return
	}

	target, found := UIMilestoneCameraTarget(w, kingdom, town)
	if !found {
		if cam.active {
			camera.target = cam.returnTarget
			camera.zoom = cam.returnZoom
			cam^ = {}
		}
		return
	}

	if !cam.active {
		cam.active = true
		cam.returnTarget = camera.target
		cam.returnZoom = camera.zoom
		cam.kingdom = kingdom
		cam.town = town
		cam.start = camera.target
		cam.target = target
		cam.elapsed = 0
		cam.duration = MILESTONE_CAMERA_PAN_SECONDS
		cam.panning = true
	} else if cam.kingdom != kingdom || cam.town != town {
		cam.kingdom = kingdom
		cam.town = town
		cam.start = camera.target
		cam.target = target
		cam.elapsed = 0
		cam.duration = MILESTONE_CAMERA_PAN_SECONDS
		cam.panning = true
	}

	if cam.panning {
		cam.elapsed += deltaTime
		t := clamp(cam.elapsed/cam.duration, 0, 1)
		smooth := t*t*(3-2*t)
		camera.target.x = cam.start.x+(cam.target.x-cam.start.x)*smooth
		camera.target.y = cam.start.y+(cam.target.y-cam.start.y)*smooth
		if t >= 1 do cam.panning = false
	} else {
		// The choice window blocks map input, but keep the target pinned so the
		// town stays centred even if the player uses camera keys or the wheel.
		camera.target = cam.target
	}
}

UIMilestoneRect :: proc() -> rl.Rectangle {
	width: f32 = 620
	height: f32 = 340
	screenWidth := f32(rl.GetScreenWidth())
	screenHeight := f32(rl.GetScreenHeight())
	return rl.Rectangle{(screenWidth-width)*0.5, (screenHeight-height)*0.5, width, height}
}

UI_MILESTONE_SHARED_H :: 64

// Rewards granted by both paths are shown once, above the two choices.
UIMilestoneSharedRewards :: proc(
	w: ^World,
	kingdom, town: int,
) -> (
	units: bit_set[UnitKind],
	unlocks: bit_set[BuildingKind],
	hasShared: bool,
) {
	optionA, okA := TownMilestoneOption(w, kingdom, town, 0)
	optionB, okB := TownMilestoneOption(w, kingdom, town, 1)
	if !okA || !okB do return

	units = optionA.units & optionB.units
	unlocks = optionA.unlocks & optionB.unlocks
	for kind in UnitKind {
		if kind in units {
			hasShared = true
			break
		}
	}
	if !hasShared {
		for kind in BuildingKind {
			if kind in unlocks {
				hasShared = true
				break
			}
		}
	}
	return
}

UIMilestoneCardRects :: proc(w: ^World, kingdom, town: int, modal: rl.Rectangle) -> [2]rl.Rectangle {
	cardWidth := (modal.width-3*UI_PAD)*0.5
	top := modal.y+82
	_, _, hasShared := UIMilestoneSharedRewards(w, kingdom, town)
	if hasShared do top += UI_MILESTONE_SHARED_H
	height := modal.height-(top-modal.y)-UI_PAD
	return [2]rl.Rectangle{
		{modal.x+UI_PAD, top, cardWidth, height},
		{modal.x+2*UI_PAD+cardWidth, top, cardWidth, height},
	}
}

// --- layout ---------------------------------------------------------------

UIConversionRows :: proc(w: ^World, selection: Selection, kinds: ^[len(UnitKind)]UnitKind) -> int {
	kingdom, town := UISelectionTown(w, selection)
	count := 0
	for kind in UI_CONVERSION_KINDS {
		if TownUnitUnlocked(w, kingdom, town, kind) || TownUnitCount(w, kingdom, town, kind) > 0 ||
			UIConversionCount(w, kingdom, town, .Villager, kind) > 0 ||
			UIConversionCount(w, kingdom, town, kind, .Villager) > 0 {
			kinds[count] = kind
			count += 1
		}
	}
	return count
}

UIConversionRowCount :: proc(w: ^World, selection: Selection) -> int {
	kinds: [len(UnitKind)]UnitKind
	return UIConversionRows(w, selection, &kinds)
}

UIStatCount :: proc(w: ^World, selection: Selection) -> int {
	switch selection.kind {
	case .Unit:
		return 2
	case .Building:
		if UISelectionTownHall(w, selection) do return 7
		kind := BuildingKindOf(w.buildings[selection.slot].type)
		if kind == .DistrictHall do return 3
		if BuildingIsTraining(kind) do return 2
		return 1
	case .None:
		return 0
	}
	return 0
}

UIUnitEffectCount :: proc(w: ^World, unitSlot: int) -> int {
	if unitSlot < 0 || unitSlot >= UNIT_CAPACITY || !w.unitUsed[unitSlot] do return 0
	count := 0
	for effect in ALL_UNIT_EFFECTS {
		if w.units[unitSlot].effects[effect] do count += 1
	}
	return count
}

UIPanelHeight :: proc(w: ^World, ui: ^UIState) -> f32 {
	if ui.selection.kind == .None do return 0
	if UISelectionTownHall(w, ui.selection) {
		kingdom, town := UISelectionTown(w, ui.selection)
		if UICanControlKingdom(w, kingdom) {
			switch ui.tab {
			case .Town:
				rows := UIConversionRowCount(w, ui.selection)
				return UI_ROWS_TOP + f32(rows)*UI_ROW_HEIGHT + UI_PAD
			case .Orders:
				return UIOrdersPanelHeight(UITownOrderCount(w, kingdom, town))
			case .Works:
				return UIConstructionsPanelHeight(TownConstructionCount(w, kingdom, town))
			}
		}
		return UI_GROWTH_Y+UI_GROWTH_H+UI_PAD
	}
	height := UI_STAT_Y + f32(UIStatCount(w, ui.selection))*UI_STAT_H + UI_PAD
	if ui.selection.kind == .Unit && UIUnitEffectCount(w, ui.selection.slot) > 0 {
		height += UI_EFFECT_ROW_H
	}
	if ui.selection.kind == .Building && BuildingKindOf(w.buildings[ui.selection.slot].type) == .Home {
		height += 72
	}
	return height
}

UIPanelRect :: proc(w: ^World, ui: ^UIState) -> rl.Rectangle {
	height := UIPanelHeight(w, ui)
	screenHeight := f32(rl.GetScreenHeight())
	y := max(UI_MARGIN, screenHeight-height-UI_MARGIN)
	return rl.Rectangle{UI_MARGIN, y, UI_PANEL_WIDTH, height}
}

UITabRects :: proc(panel: rl.Rectangle) -> [len(UI_TOWN_TABS)]rl.Rectangle {
	rects: [len(UI_TOWN_TABS)]rl.Rectangle
	x := panel.x+UI_PAD
	for label, index in UI_TOWN_TABS {
		width := rl.MeasureTextEx(UIFont(), label, UI_TEXT_SIZE, 1).x+20
		rects[index] = rl.Rectangle{x, panel.y+UI_TABS_Y, width, UI_TABS_H}
		x += width+2
	}
	return rects
}

UIButtonRects :: proc(panel: rl.Rectangle, index: int) -> (minus, plus: rl.Rectangle) {
	rowY := panel.y+UI_ROWS_TOP+f32(index)*UI_ROW_HEIGHT
	plus = rl.Rectangle{panel.x+panel.width-UI_PAD-UI_BUTTON, rowY+8, UI_BUTTON, UI_BUTTON}
	minus = rl.Rectangle{plus.x-UI_BUTTON-4, plus.y, UI_BUTTON, UI_BUTTON}
	return
}

UIUnitIconRect :: proc(panel: rl.Rectangle, index: int) -> rl.Rectangle {
	rowY := panel.y+UI_ROWS_TOP+f32(index)*UI_ROW_HEIGHT
	return rl.Rectangle{panel.x+UI_PAD, rowY+2, 32, 32}
}

UIOrdersPanelHeight :: proc(orders: int) -> f32 {
	return UI_ROWS_TOP+UI_SECTION_HEADER+f32(max(orders, 1))*UI_ROW_HEIGHT+UI_PAD
}

UIConstructionsPanelHeight :: proc(sites: int) -> f32 {
	return UI_ROWS_TOP+UI_SECTION_HEADER+f32(max(sites, 1))*UI_CONSTRUCTION_ROW_HEIGHT+UI_PAD
}

UIOrderCancelRect :: proc(panel: rl.Rectangle, index: int) -> rl.Rectangle {
	rowY := panel.y+UI_ROWS_TOP+UI_SECTION_HEADER+f32(index)*UI_ROW_HEIGHT
	return rl.Rectangle{
		panel.x+panel.width-UI_PAD-72,
		rowY+(UI_ROW_HEIGHT-UI_TEXT_BUTTON_H)*0.5,
		72,
		UI_TEXT_BUTTON_H,
	}
}

UICommandBarRects :: proc() -> (attack, defend, found, fuse: rl.Rectangle) {
	total := 4*UI_COMMAND_BUTTON_W+3*UI_COMMAND_GAP
	x := (f32(rl.GetScreenWidth())-total)*0.5
	y := f32(rl.GetScreenHeight())-UI_MARGIN-UI_COMMAND_BUTTON_H
	attack = rl.Rectangle{x, y, UI_COMMAND_BUTTON_W, UI_COMMAND_BUTTON_H}
	defend = rl.Rectangle{x+UI_COMMAND_BUTTON_W+UI_COMMAND_GAP, y, UI_COMMAND_BUTTON_W, UI_COMMAND_BUTTON_H}
	found = rl.Rectangle{x+2*(UI_COMMAND_BUTTON_W+UI_COMMAND_GAP), y, UI_COMMAND_BUTTON_W, UI_COMMAND_BUTTON_H}
	fuse = rl.Rectangle{x+3*(UI_COMMAND_BUTTON_W+UI_COMMAND_GAP), y, UI_COMMAND_BUTTON_W, UI_COMMAND_BUTTON_H}
	return
}

UIFoundButtonEnabled :: proc(w: ^World, kingdom, town: int) -> bool {
	if !UICanControlKingdom(w, kingdom) || !WorldTownExists(w, kingdom, town) do return false
	t := &w.kingdoms[kingdom].towns[town]
	if t.wood < TownFoundingWoodCost(w, kingdom) do return false
	if t.citizens < TOWN_FOUNDING_MIN_CITIZENS do return false
	if TownUnitCount(w, kingdom, town, .Villager) < TOWN_FOUNDING_SETTLERS do return false
	if TownUnitCount(w, kingdom, town, .Builder) <= 0 do return false
	return KingdomFreeTownSlot(w, kingdom) >= 0
}

UIBuildButtonRect :: proc() -> rl.Rectangle {
	size := UI_COMMAND_BUTTON_H
	return rl.Rectangle{
		f32(rl.GetScreenWidth())-UI_MARGIN-size,
		f32(rl.GetScreenHeight())-UI_MARGIN-size,
		size,
		size,
	}
}

UIPlayerBuildTown :: proc(w: ^World, ui: ^UIState) -> (kingdom, town: int, found: bool) {
	resolved := false
	switch ui.selection.kind {
	case .Unit:
		if ui.selection.slot >= 0 && ui.selection.slot < UNIT_CAPACITY &&
			w.unitUsed[ui.selection.slot] {
			kingdom = w.units[ui.selection.slot].kingdome
			town = w.units[ui.selection.slot].town
			resolved = true
		}
	case .Building:
		if ui.selection.slot >= 0 && ui.selection.slot < BUILDING_CAPACITY &&
			w.buildingUsed[ui.selection.slot] {
			kingdom = w.buildings[ui.selection.slot].kingdom
			town = w.buildings[ui.selection.slot].town
			resolved = true
		}
	case .None:
	}
	if resolved && UICanControlKingdom(w, kingdom) && WorldTownExists(w, kingdom, town) {
		return kingdom, town, true
	}

	local := WorldLocalKingdom(w)
	if local < 0 do return -1, -1, false
	capital := w.kingdoms[local].capitalSlot
	if !WorldTownExists(w, local, capital) do return -1, -1, false
	return local, capital, true
}

UIHasCombatBuildKind :: proc(w: ^World, kingdom, town: int) -> bool {
	if !WorldTownExists(w, kingdom, town) do return false
	for kind in UI_COMBAT_BUILD_KINDS {
		if kind in w.kingdoms[kingdom].towns[town].unlockedBuildings do return true
	}
	return false
}

UIBuildButtonVisible :: proc(w: ^World, ui: ^UIState) -> bool {
	if ui.command == .Build || ui.command == .Place {
		return WorldTownExists(w, ui.buildKingdom, ui.buildTown)
	}
	kingdom, town, found := UIPlayerBuildTown(w, ui)
	return found && TownUnitUnlocked(w, kingdom, town, .CombatBuilder)
}

UIBuildButtonEnabled :: proc(w: ^World, ui: ^UIState) -> bool {
	if ui.command == .Build || ui.command == .Place {
		return WorldTownExists(w, ui.buildKingdom, ui.buildTown)
	}
	kingdom, town, found := UIPlayerBuildTown(w, ui)
	return found && UIHasCombatBuildKind(w, kingdom, town)
}

UIBuildPaletteRects :: proc(w: ^World, kingdom, town: int) -> (rects: [len(UI_COMBAT_BUILD_KINDS)]rl.Rectangle, kinds: [len(UI_COMBAT_BUILD_KINDS)]BuildingKind, count: int) {
	if !WorldTownExists(w, kingdom, town) do return
	townData := &w.kingdoms[kingdom].towns[town]
	for kind in UI_COMBAT_BUILD_KINDS {
		if !(kind in townData.unlockedBuildings) do continue
		kinds[count] = kind
		count += 1
	}
	if count == 0 do return

	width: f32 = 148
	height: f32 = 54
	gap: f32 = 6
	button := UIBuildButtonRect()
	total := f32(count)*height+f32(count-1)*gap
	x := button.x+button.width-width
	y := button.y-gap-total
	for index in 0..<count {
		rects[index] = rl.Rectangle{x, y+f32(index)*(height+gap), width, height}
	}
	return
}

UIBuildButtonPress :: proc(w: ^World, ui: ^UIState) {
	if ui.command == .Build || ui.command == .Place {
		ui.command = .Inspect
		return
	}
	kingdom, town, found := UIPlayerBuildTown(w, ui)
	if !found || !TownUnitUnlocked(w, kingdom, town, .CombatBuilder) do return
	if !UIHasCombatBuildKind(w, kingdom, town) do return
	ui.buildKingdom = kingdom
	ui.buildTown = town
	ui.command = .Build
	ui.hover = {}
}

UIBuildPalettePress :: proc(w: ^World, ui: ^UIState, mouse: rl.Vector2) -> bool {
	rects, kinds, count := UIBuildPaletteRects(w, ui.buildKingdom, ui.buildTown)
	for index in 0..<count {
		if !rl.CheckCollisionPointRec(mouse, rects[index]) do continue
		ui.buildKind = kinds[index]
		ui.command = .Place
		ui.hover = {}
		return true
	}
	return false
}

// --- conversion state -----------------------------------------------------

UIConversionPending :: proc(w: ^World, kingdom, town: int, kind: UnitKind) -> int {
	if !WorldTownExists(w, kingdom, town) do return 0
	t := &w.kingdoms[kingdom].towns[town]
	pending := 0
	for i in 0..<t.conversionCount {
		job := t.conversions[i]
		if job.from == .Villager && job.to == kind do pending += job.remaining
		if job.from == kind && job.to == .Villager do pending -= job.remaining
	}
	return pending
}

UIConversionCount :: proc(w: ^World, kingdom, town: int, from, to: UnitKind) -> int {
	if !WorldTownExists(w, kingdom, town) do return 0
	t := &w.kingdoms[kingdom].towns[town]
	for i in 0..<t.conversionCount {
		job := t.conversions[i]
		if job.from == from && job.to == to do return job.remaining
	}
	return 0
}

UICanConvertTo :: proc(w: ^World, kingdom, town: int, kind: UnitKind) -> bool {
	if UIConversionCount(w, kingdom, town, kind, .Villager) > 0 do return true
	if !TownUnitAvailable(w, kingdom, town, kind) do return false
	villagers := TownUnitCount(w, kingdom, town, .Villager)
	committed := 0
	t := &w.kingdoms[kingdom].towns[town]
	for i in 0..<t.conversionCount {
		if t.conversions[i].from == .Villager do committed += t.conversions[i].remaining
	}
	return villagers-committed > 0
}

UICanConvertFrom :: proc(w: ^World, kingdom, town: int, kind: UnitKind) -> bool {
	if UIConversionCount(w, kingdom, town, .Villager, kind) > 0 do return true
	if !WorldTownExists(w, kingdom, town) do return false
	count := TownUnitCount(w, kingdom, town, kind)
	committed := 0
	t := &w.kingdoms[kingdom].towns[town]
	for i in 0..<t.conversionCount {
		if t.conversions[i].from == kind do committed += t.conversions[i].remaining
	}
	return count-committed > 0
}

// --- input ----------------------------------------------------------------

WorldUIUpdate :: proc(w: ^World, view: ^WorldView, camera: rl.Camera2D) {
	WorldAlertPrune(w)
	ui := &view.ui
	if !UISelectionValid(w, ui.selection) {
		ui.selection = {}
		if ui.command == .Attack || ui.command == .Defend || ui.command == .Found ||
			ui.command == .Fuse {
			ui.command = .Inspect
		}
	}

	mouse := rl.GetMousePosition()

	// An unresolved milestone takes over input until the player picks a path.
	if milestoneKingdom, milestoneTown, pending := UIMilestoneTown(w); pending {
		ui.hover = {}
		ui.command = .Inspect
		if rl.IsMouseButtonPressed(.LEFT) {
			UIMilestoneClick(w, milestoneKingdom, milestoneTown, mouse)
		}
		return
	}

	if UIHudUpdate(w, view, mouse) do return

	overUi := false

	buildRect := UIBuildButtonRect()
	buildVisible := UIBuildButtonVisible(w, ui)
	if buildVisible && rl.CheckCollisionPointRec(mouse, buildRect) {
		overUi = true
		ui.hover = {}
		if rl.IsMouseButtonPressed(.LEFT) {
			UIBuildButtonPress(w, ui)
			return
		}
	}
	if ui.command == .Build {
		palette, _, count := UIBuildPaletteRects(w, ui.buildKingdom, ui.buildTown)
		for index in 0..<count {
			if !rl.CheckCollisionPointRec(mouse, palette[index]) do continue
			overUi = true
			ui.hover = {}
			if rl.IsMouseButtonPressed(.LEFT) {
				UIBuildPalettePress(w, ui, mouse)
				return
			}
		}
	}

	if UISelectionPlayerTownHall(w, ui.selection) {
		attackRect, defendRect, foundRect, fuseRect := UICommandBarRects()
		if rl.CheckCollisionPointRec(mouse, attackRect) ||
			rl.CheckCollisionPointRec(mouse, defendRect) ||
			rl.CheckCollisionPointRec(mouse, foundRect) ||
			rl.CheckCollisionPointRec(mouse, fuseRect) {
			overUi = true
			ui.hover = {}
			if rl.IsMouseButtonPressed(.LEFT) {
				UICommandBarPress(w, ui, mouse)
				return
			}
		}
	}

	if ui.command != .Inspect {
		if rl.IsKeyPressed(.ESCAPE) || rl.IsMouseButtonPressed(.RIGHT) {
			ui.command = .Inspect
			ui.hover = {}
			return
		}
		if ui.command == .Build || ui.command == .Place {
			if !WorldTownExists(w, ui.buildKingdom, ui.buildTown) {
				ui.command = .Inspect
			}
		} else if !UISelectionPlayerTownHall(w, ui.selection) {
			ui.command = .Inspect
		}
	}

	if rl.IsKeyPressed(.ESCAPE) {
		ui.selection = {}
		ui.command = .Inspect
		return
	}

	if ui.command != .Inspect {
		ui.hover = {}
		UICommandUpdate(w, ui, camera, mouse)
		return
	}

	panel := UIPanelRect(w, ui)
	if overUi {
		ui.hover = {}
	} else if ui.selection.kind != .None && rl.CheckCollisionPointRec(mouse, panel) {
		ui.hover = {}
	} else {
		ui.hover = UIFindAt(w, camera, mouse)
	}

	if !rl.IsMouseButtonPressed(.LEFT) do return
	if ui.selection.kind != .None && rl.CheckCollisionPointRec(mouse, panel) {
		UIPanelClick(w, view, panel, mouse)
		return
	}
	ui.selection = ui.hover
	if !UISelectionValid(w, ui.selection) do ui.selection = {}
}

UICommandUpdate :: proc(w: ^World, ui: ^UIState, camera: rl.Camera2D, mouse: rl.Vector2) {
	panel := UIPanelRect(w, ui)
	if rl.CheckCollisionPointRec(mouse, panel) do return

	if ui.command == .Place {
		if !WorldTownExists(w, ui.buildKingdom, ui.buildTown) {
			ui.command = .Inspect
			return
		}
		tileX, tileY, ok := UITileAtMouse(w, camera, mouse)
		if !ok do return
		if TownCombatConstructionFailure(w, ui.buildKingdom, ui.buildTown, ui.buildKind, tileX, tileY) != .None {
			return
		}
		if !rl.IsMouseButtonPressed(.LEFT) do return
		KingdomIssueCommand(
			w,
			ui.buildKingdom,
			CommandBuildCombat{
				town = ui.buildTown,
				kind = ui.buildKind,
				x = tileX,
				y = tileY,
			},
		)
		return
	}
	if ui.command == .Build do return

	if ui.command == .Found {
		kingdom, town := UISelectionTown(w, ui.selection)
		if !WorldTownExists(w, kingdom, town) {
			ui.command = .Inspect
			return
		}
		tileX, tileY, ok := UITileAtMouse(w, camera, mouse)
		if !ok do return
		if TownFoundingFailure(w, kingdom, town, tileX, tileY) != .None do return
		if !rl.IsMouseButtonPressed(.LEFT) do return
		if KingdomIssueCommand(w, kingdom, CommandFoundTown{town = town, x = tileX, y = tileY}) {
			ui.command = .Inspect
		}
		return
	}

	kingdom, town := UISelectionTown(w, ui.selection)
	if !WorldTownExists(w, kingdom, town) {
		ui.command = .Inspect
		return
	}

	switch ui.command {
	case .Attack, .Defend:
		targetKingdom, targetTown, _, found := UIFindTownAt(w, camera, mouse)
		if !found do return
		valid := UIDefendOrderValid(w, kingdom, town, targetKingdom, targetTown)
		if ui.command == .Attack {
			valid = UIAttackOrderValid(w, kingdom, town, targetKingdom, targetTown)
		}
		if !valid || !rl.IsMouseButtonPressed(.LEFT) do return
		if ui.command == .Attack {
			KingdomIssueCommand(
				w,
				kingdom,
				CommandAttackTown{town = town, targetKingdom = targetKingdom, targetTown = targetTown},
			)
		} else {
			KingdomIssueCommand(
				w,
				kingdom,
				CommandDefendTown{town = town, targetKingdom = targetKingdom, targetTown = targetTown},
			)
		}
		ui.command = .Inspect

	case .Fuse:
		targetKingdom, targetTown, _, found := UIFindTownAt(w, camera, mouse)
		if !found do return
		if TownFusionFailure(w, kingdom, town, targetKingdom, targetTown) != .None do return
		if !rl.IsMouseButtonPressed(.LEFT) do return
		if KingdomIssueCommand(
			w,
			kingdom,
			CommandFuseTown{town = town, targetKingdom = targetKingdom, targetTown = targetTown},
		) {
			ui.command = .Inspect
		}
		return

	case .Build, .Found, .Place, .Inspect:
	}
}

UIPanelClick :: proc(w: ^World, view: ^WorldView, panel: rl.Rectangle, mouse: rl.Vector2) {
	ui := &view.ui
	if UISelectionPlayerTownHall(w, ui.selection) {
		for rect, index in UITabRects(panel) {
			if rl.CheckCollisionPointRec(mouse, rect) {
				ui.tab = UITownTab(index)
				return
			}
		}

		switch ui.tab {
		case .Town:
			UIConversionClick(w, view, panel, mouse)
		case .Orders:
			UIOrdersClick(w, ui, panel, mouse)
		case .Works:
			// Construction sites are automatic; the tab is read-only.
		}
		return
	}

	UIConversionClick(w, view, panel, mouse)
}

UIOrdersClick :: proc(w: ^World, ui: ^UIState, panel: rl.Rectangle, mouse: rl.Vector2) {
	kingdom, town := UISelectionTown(w, ui.selection)
	orders := UITownOrderCount(w, kingdom, town)
	for index in 0..<orders {
		if !rl.CheckCollisionPointRec(mouse, UIOrderCancelRect(panel, index)) do continue
		attack, targetKingdom, targetTown, found := UITownOrderAt(w, kingdom, town, index)
		if !found do return
		if attack {
			KingdomIssueCommand(
				w,
				kingdom,
				CommandStopAttack{town = town, targetKingdom = targetKingdom, targetTown = targetTown},
			)
		} else {
			KingdomIssueCommand(
				w,
				kingdom,
				CommandStopDefend{town = town, targetKingdom = targetKingdom, targetTown = targetTown},
			)
		}
		return
	}
}

UICommandBarPress :: proc(w: ^World, ui: ^UIState, mouse: rl.Vector2) {
	kingdom, town := UISelectionTown(w, ui.selection)
	attackRect, defendRect, foundRect, fuseRect := UICommandBarRects()
	if rl.CheckCollisionPointRec(mouse, attackRect) {
		if ui.command == .Attack {
			ui.command = .Inspect
		} else if UIAttackTargetExists(w, kingdom, town) {
			ui.command = .Attack
		}
		ui.hover = {}
		return
	}
	if rl.CheckCollisionPointRec(mouse, defendRect) {
		if ui.command == .Defend {
			ui.command = .Inspect
		} else if UIDefendTargetExists(w, kingdom, town) {
			ui.command = .Defend
		}
		ui.hover = {}
		return
	}
	if rl.CheckCollisionPointRec(mouse, foundRect) {
		if ui.command == .Found {
			ui.command = .Inspect
		} else if UIFoundButtonEnabled(w, kingdom, town) {
			ui.command = .Found
		}
		ui.hover = {}
		return
	}
	if rl.CheckCollisionPointRec(mouse, fuseRect) {
		if ui.command == .Fuse {
			ui.command = .Inspect
		} else if UIFusionTargetExists(w, kingdom, town) {
			ui.command = .Fuse
		}
		ui.hover = {}
	}
}

UITileAtMouse :: proc(w: ^World, camera: rl.Camera2D, mouse: rl.Vector2) -> (tileX, tileY: int, ok: bool) {
	if w.maxX == 0 || w.maxY == 0 do return 0, 0, false
	world := rl.GetScreenToWorld2D(mouse, camera)
	return int(WorldWrapPosition(world.x, f32(w.maxX))),
		int(WorldWrapPosition(world.y, f32(w.maxY))),
		true
}

UIMilestoneClick :: proc(w: ^World, kingdom, town: int, mouse: rl.Vector2) {
	modal := UIMilestoneRect()
	cards := UIMilestoneCardRects(w, kingdom, town, modal)
	for card, option in cards {
		if rl.CheckCollisionPointRec(mouse, card) {
			KingdomIssueCommand(w, kingdom, CommandChooseMilestone{town = town, option = option})
			return
		}
	}
}

UIFindBuildingAt :: proc(w: ^World, camera: rl.Camera2D, mouse: rl.Vector2) -> Selection {
	world := rl.GetScreenToWorld2D(mouse, camera)
	if w.maxX == 0 || w.maxY == 0 do return {}
	tileX := int(WorldWrapPosition(world.x, f32(w.maxX)))
	tileY := int(WorldWrapPosition(world.y, f32(w.maxY)))
	if tileX < 0 || tileX >= int(w.maxX) || tileY < 0 || tileY >= int(w.maxY) {
		return {}
	}
	slot := w.tileBuilding[tileX*int(w.maxY)+tileY]
	if slot >= 0 && slot < BUILDING_CAPACITY && w.buildingUsed[slot] && FogBuildingVisible(w, slot) {
		return Selection{kind = .Building, slot = slot}
	}
	return {}
}

UIFindTownAt :: proc(w: ^World, camera: rl.Camera2D, mouse: rl.Vector2) -> (kingdom, town, hallSlot: int, found: bool) {
	selection := UIFindBuildingAt(w, camera, mouse)
	if selection.kind == .Building {
		kingdom = w.buildings[selection.slot].kingdom
		town = w.buildings[selection.slot].town
		if !WorldTownExists(w, kingdom, town) do return -1, -1, -1, false
		hallSlot = TownHallSlot(w, kingdom, town)
		if hallSlot < 0 do return -1, -1, -1, false
		return kingdom, town, hallSlot, true
	}

	// Discovered but currently fogged towns remain valid order targets.
	tileX, tileY, ok := UITileAtMouse(w, camera, mouse)
	if !ok do return -1, -1, -1, false
	kingdom, town, found = FogFindTownAt(w, tileX, tileY)
	if !found do return -1, -1, -1, false
	hallSlot = TownHallSlot(w, kingdom, town)
	return
}

UIFindAt :: proc(w: ^World, camera: rl.Camera2D, mouse: rl.Vector2) -> Selection {
	world := rl.GetScreenToWorld2D(mouse, camera)
	worldWidth := f32(w.maxX)
	worldHeight := f32(w.maxY)
	px := WorldWrapPosition(world.x, worldWidth)
	py := WorldWrapPosition(world.y, worldHeight)

	bestSlot := -1
	bestDistance: f32 = 1e9
	for unitSlot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[unitSlot] do continue
		if w.units[unitSlot].type == nil do continue
		if !FogUnitVisible(w, unitSlot) do continue
		if state, ok := w.units[unitSlot].state.(StateConverting); ok && state.inside {
			continue
		}

		scale := UnitSpriteScale(UnitKindOf(w.units[unitSlot].type))
		x, y := UnitRenderPosition(w, unitSlot)
		if px < x-scale*0.5 || px > x+scale*0.5 || py < y+0.5-scale || py > y+0.5 {
			continue
		}
		dx := px-x
		dy := py-y
		distance := dx*dx+dy*dy
		if distance < bestDistance {
			bestDistance = distance
			bestSlot = unitSlot
		}
	}
	if bestSlot >= 0 {
		return Selection{kind = .Unit, slot = bestSlot}
	}

	tileX := int(px)
	tileY := int(py)
	if tileX >= 0 && tileX < int(w.maxX) && tileY >= 0 && tileY < int(w.maxY) {
		slot := w.tileBuilding[tileX*int(w.maxY)+tileY]
		if slot >= 0 && slot < BUILDING_CAPACITY && w.buildingUsed[slot] && FogBuildingVisible(w, slot) {
			return Selection{kind = .Building, slot = slot}
		}
	}
	return {}
}

UIConversionClick :: proc(w: ^World, view: ^WorldView, panel: rl.Rectangle, mouse: rl.Vector2) {
	ui := &view.ui
	if !UISelectionTownHall(w, ui.selection) do return
	kingdom, town := UISelectionTown(w, ui.selection)
	if !UICanControlKingdom(w, kingdom) do return

	kinds: [len(UnitKind)]UnitKind
	count := UIConversionRows(w, ui.selection, &kinds)
	step := 1
	if rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT) do step = 10
	for i in 0..<count {
		kind := kinds[i]
		if rl.CheckCollisionPointRec(mouse, UIUnitIconRect(panel, i)) {
			UIUnitFocusCamera(w, view, kingdom, town, kind)
			return
		}
		minus, plus := UIButtonRects(panel, i)
		if rl.CheckCollisionPointRec(mouse, plus) {
			if UICanConvertTo(w, kingdom, town, kind) {
				if UIConversionCount(w, kingdom, town, kind, .Villager) > 0 {
					KingdomIssueCommand(
						w,
						kingdom,
						CommandRemoveConversion{town = town, from = kind, to = .Villager, count = step},
					)
				} else {
					KingdomIssueCommand(
						w,
						kingdom,
						CommandQueueConversion{town = town, from = .Villager, to = kind, count = step},
					)
				}
			}
			return
		}
		if rl.CheckCollisionPointRec(mouse, minus) {
			if UICanConvertFrom(w, kingdom, town, kind) {
				if UIConversionCount(w, kingdom, town, .Villager, kind) > 0 {
					KingdomIssueCommand(
						w,
						kingdom,
						CommandRemoveConversion{town = town, from = .Villager, to = kind, count = step},
					)
				} else {
					KingdomIssueCommand(
						w,
						kingdom,
						CommandQueueConversion{town = town, from = kind, to = .Villager, count = step},
					)
				}
			}
			return
		}
	}
}

// Clicking a unit icon cycles the camera through that town's units of the
// kind, so repeated clicks visit each one in turn.
UIUnitFocusCamera :: proc(w: ^World, view: ^WorldView, kingdom, town: int, kind: UnitKind) {
	worldWidth := f32(w.maxX)
	worldHeight := f32(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 do return

	cam := &view.focusCamera
	startSlot := 0
	if cam.hasUnit && cam.kind == kind && cam.kingdom == kingdom && cam.town == town {
		startSlot = cam.unitSlot+1
	}

	for offset in 0..<UNIT_CAPACITY {
		slot := WorldWrapCoordinate(startSlot+offset, UNIT_CAPACITY)
		if !w.unitUsed[slot] || w.units[slot].type == nil do continue
		if w.units[slot].kingdome != kingdom || w.units[slot].town != town do continue
		if UnitKindOf(w.units[slot].type) != kind do continue

		camera := &view.camera
		camera.target.x = WorldWrapPosition(camera.target.x, worldWidth)
		camera.target.y = WorldWrapPosition(camera.target.y, worldHeight)

		x, y := UnitRenderPosition(w, slot)
		cam.kind = kind
		cam.unitSlot = slot
		cam.hasUnit = true
		cam.kingdom = kingdom
		cam.town = town
		cam.active = true
		cam.elapsed = 0
		cam.duration = UI_FOCUS_CAMERA_PAN_SECONDS
		cam.start = camera.target
		cam.target = rl.Vector2{
			camera.target.x+WorldShortestWrappedDelta(x-camera.target.x, worldWidth),
			camera.target.y+WorldShortestWrappedDelta(y-camera.target.y, worldHeight),
		}
		return
	}
}

WorldFocusCameraUpdate :: proc(view: ^WorldView, deltaTime: f32) {
	cam := &view.focusCamera
	if !cam.active do return

	cam.elapsed += deltaTime
	t := clamp(cam.elapsed/max(cam.duration, 0.0001), 0, 1)
	// Ease-out keeps the jump quick while still reading as motion.
	smooth := 1-(1-t)*(1-t)
	view.camera.target.x = cam.start.x+(cam.target.x-cam.start.x)*smooth
	view.camera.target.y = cam.start.y+(cam.target.y-cam.start.y)*smooth
	if t >= 1 do cam.active = false
}

// --- drawing --------------------------------------------------------------

WorldUIDraw :: proc(w: ^World, renderer: ^WorldRenderer, camera: rl.Camera2D, ui: ^UIState) {
	WorldAlertPrune(w)
	milestoneKingdom, milestoneTown, milestonePending := UIMilestoneTown(w)

	UIDrawOrderArrows(w, camera, ui.selection)
	if ui.command == .Attack || ui.command == .Defend || ui.command == .Fuse {
		UIDrawCommandTargets(w, camera, ui)
	}
	if ui.hover.kind != ui.selection.kind || ui.hover.slot != ui.selection.slot {
		UIDrawTownArea(w, camera, ui.hover, true)
	}
	UIDrawTownArea(w, camera, ui.selection, false)
	UIDrawHover(w, camera, ui.hover, ui.selection)
	if UISelectionValid(w, ui.selection) {
		UIDrawSelection(w, camera, ui.selection)
	}

	panel := UIPanelRect(w, ui)
	UIDrawPanel(w, renderer, ui, panel)
	if !milestonePending {
		UIDrawCommandBar(w, renderer, ui)
		UIDrawBuildButton(w, ui)
		UIDrawBuildPalette(w, renderer, ui)
	}
	UIDrawBuildPreview(w, renderer, camera, ui)
	UIDrawFoundPreview(w, renderer, camera, ui)
	UIDrawCommandHint(w, ui, camera)
	if !milestonePending {
		UIDrawHud(w, ui)
		UIDrawSidePanel(w, ui)
		UIDrawAlerts(w)
	}

	if milestonePending {
		UIDrawMilestone(w, renderer, milestoneKingdom, milestoneTown)
	}
}

// The town's buildable area, drawn as a tile-approximated circle when its hall
// is selected, and faintly while it is only hovered.
UIDrawTownArea :: proc(w: ^World, camera: rl.Camera2D, selection: Selection, faint: bool) {
	if selection.kind != .Building do return
	if !UISelectionTownHall(w, selection) do return
	building := w.buildings[selection.slot]
	UIDrawTownAreaFor(w, camera, building.kingdom, building.town, faint)
}

UIDrawTownAreaFor :: proc(w: ^World, camera: rl.Camera2D, kingdom, townSlot: int, faint: bool) {
	if !WorldTownExists(w, kingdom, townSlot) do return

	accent := FactionColor(w, kingdom)
	fillAlpha: u8 = faint ? 8 : 24
	lineAlpha: u8 = faint ? 70 : 140
	fill := rl.Color{accent[0], accent[1], accent[2], fillAlpha}
	line := rl.Color{accent[0], accent[1], accent[2], lineAlpha}
	thickness := 1/camera.zoom

	areaMinX, areaMaxX, areaMinY, areaMaxY := TownAreaBounds(w, kingdom, townSlot)
	minX := max(0, areaMinX)
	maxX := min(int(w.maxX)-1, areaMaxX)
	minY := max(0, areaMinY)
	maxY := min(int(w.maxY)-1, areaMaxY)

	// Only iterate tiles that can actually be on screen.
	halfWidth := f32(rl.GetScreenWidth())/(2*camera.zoom)
	halfHeight := f32(rl.GetScreenHeight())/(2*camera.zoom)
	minX = max(minX, int(camera.target.x-halfWidth)-1)
	maxX = min(maxX, int(camera.target.x+halfWidth)+1)
	minY = max(minY, int(camera.target.y-halfHeight)-1)
	maxY = min(maxY, int(camera.target.y+halfHeight)+1)
	if minX > maxX || minY > maxY do return

	rl.BeginMode2D(camera)
	for x in minX ..= maxX {
		for y in minY ..= maxY {
			if !TownPointInArea(w, kingdom, townSlot, x, y) do continue
			rl.DrawRectangleRec(rl.Rectangle{f32(x), f32(y), 1, 1}, fill)
			if !TownPointInArea(w, kingdom, townSlot, x+1, y) {
				rl.DrawRectangleRec(rl.Rectangle{f32(x)+1-thickness, f32(y), thickness, 1}, line)
			}
			if !TownPointInArea(w, kingdom, townSlot, x-1, y) {
				rl.DrawRectangleRec(rl.Rectangle{f32(x), f32(y), thickness, 1}, line)
			}
			if !TownPointInArea(w, kingdom, townSlot, x, y+1) {
				rl.DrawRectangleRec(rl.Rectangle{f32(x), f32(y)+1-thickness, 1, thickness}, line)
			}
			if !TownPointInArea(w, kingdom, townSlot, x, y-1) {
				rl.DrawRectangleRec(rl.Rectangle{f32(x), f32(y), 1, thickness}, line)
			}
		}
	}
	rl.EndMode2D()
}

UIDrawHover :: proc(w: ^World, camera: rl.Camera2D, hover, selection: Selection) {
	if hover.kind == .None do return
	if hover.kind == selection.kind && hover.slot == selection.slot do return
	if !UISelectionValid(w, hover) do return

	fill := rl.Color{240, 232, 210, 28}
	line := rl.Color{240, 232, 210, 120}
	thickness := 1.2/camera.zoom

	rl.BeginMode2D(camera)
	switch hover.kind {
	case .Unit:
		scale := UnitSpriteScale(UnitKindOf(w.units[hover.slot].type))
		x, y := UnitRenderPosition(w, hover.slot)
		rect := rl.Rectangle{x-scale*0.5, y+0.5-scale, scale, scale}
		rl.DrawRectangleRec(rect, fill)
		rl.DrawRectangleLinesEx(rect, thickness, line)
	case .Building:
		width, height := BuildingTileSize(w.buildings[hover.slot].type)
		rect := rl.Rectangle {
			f32(w.buildings.x[hover.slot]),
			f32(w.buildings.y[hover.slot]),
			f32(width),
			f32(height),
		}
		rl.DrawRectangleRec(rect, fill)
		rl.DrawRectangleLinesEx(rect, thickness, line)
	case .None:
	}
	rl.EndMode2D()
}

UIDrawSelection :: proc(w: ^World, camera: rl.Camera2D, selection: Selection) {
	rl.BeginMode2D(camera)
	color := rl.Color{236, 204, 116, 220}
	thickness := 1.4/camera.zoom
	switch selection.kind {
	case .Unit:
		scale := UnitSpriteScale(UnitKindOf(w.units[selection.slot].type))
		x, y := UnitRenderPosition(w, selection.slot)
		rect := rl.Rectangle{x-scale*0.5, y+0.5-scale, scale, scale}
		rl.DrawRectangleLinesEx(rect, thickness, color)
	case .Building:
		width, height := BuildingTileSize(w.buildings[selection.slot].type)
		rect := rl.Rectangle {
			f32(w.buildings.x[selection.slot]),
			f32(w.buildings.y[selection.slot]),
			f32(width),
			f32(height),
		}
		rl.DrawRectangleLinesEx(rect, thickness, color)
	case .None:
	}
	rl.EndMode2D()
}

UIDrawStatLabel :: proc(stat: UIStat, x, y: f32) {
	UIText(stat.label, x, y, UI_COLOR_DIM)
	if stat.icon.id == 0 do return
	width := rl.MeasureTextEx(UIFont(), stat.label, UI_TEXT_SIZE, 1).x
	source := rl.Rectangle{0, 0, f32(stat.icon.width), f32(stat.icon.height)}
	rl.DrawTexturePro(stat.icon, source, rl.Rectangle{x+width+2, y-1, 16, 16}, rl.Vector2{0, 0}, 0, rl.WHITE)
}

UIDrawPanel :: proc(w: ^World, renderer: ^WorldRenderer, ui: ^UIState, panel: rl.Rectangle) {
	rl.DrawRectangleRec(panel, UI_COLOR_BG)
	rl.DrawRectangleLinesEx(panel, 2, UI_COLOR_BORDER)
	inner := rl.Rectangle{panel.x+3, panel.y+3, panel.width-6, panel.height-6}
	rl.DrawRectangleLinesEx(inner, 1, UI_COLOR_BORDER_INNER)

	kingdom, town := UISelectionTown(w, ui.selection)
	accent := FactionColor(w, kingdom)

	head := rl.Rectangle{panel.x+3, panel.y+3, panel.width-6, UI_HEADER_H-3}
	rl.DrawRectangleRec(head, UI_COLOR_HEADER)
	rl.DrawRectangleRec(rl.Rectangle{panel.x+3, panel.y+3, 4, UI_HEADER_H-3}, accent)
	rl.DrawRectangleRec(
		rl.Rectangle{panel.x+3, panel.y+UI_HEADER_H-1, panel.width-6, 1},
		UI_COLOR_BORDER_INNER,
	)

	portrait := rl.Rectangle{panel.x+UI_PAD, panel.y+14, 64, 64}
	rl.DrawRectangleRec(portrait, rl.Color{16, 15, 18, 255})
	rl.DrawRectangleLinesEx(portrait, 1, UI_COLOR_BORDER_INNER)
	UIDrawPortrait(w, renderer, ui, portrait)

	titleX := portrait.x+portrait.width+12
	switch ui.selection.kind {
	case .Unit:
		UITitle(UIUnitName(UnitKindOf(w.units[ui.selection.slot].type)), titleX, panel.y+10, UI_COLOR_GOLD)
	case .Building:
		kind := BuildingKindOf(w.buildings[ui.selection.slot].type)
		title := UIBuildingName(kind)
		if kind == .DistrictHall do title = UIDistrictHallName(w, ui.selection.slot)
		if kind == .TownHall && w.buildings[ui.selection.slot].kingdom == NEUTRAL_KINGDOM {
			title = "Independent Hall"
		}
		UITitle(title, titleX, panel.y+10, UI_COLOR_GOLD)
	case .None:
	}
	if WorldTownExists(w, kingdom, town) {
		UIText(
			fmt.ctprintf("%s  -  %s", NameKingdomCString(w, kingdom), NameTownCString(w, kingdom, town)),
			titleX,
			panel.y+48,
			UI_COLOR_DIM,
		)
	}

	switch ui.selection.kind {
	case .Unit:
		UIText(UIUnitDescription(UnitKindOf(w.units[ui.selection.slot].type)), panel.x+UI_PAD, panel.y+UI_DESC_Y, UI_COLOR_TEXT)
	case .Building:
		UIText(UIBuildingDescription(BuildingKindOf(w.buildings[ui.selection.slot].type)), panel.x+UI_PAD, panel.y+UI_DESC_Y, UI_COLOR_TEXT)
	case .None:
	}

	stats: [8]UIStat
	statCount := UIFillStats(w, renderer, ui, &stats)
	if UISelectionTownHall(w, ui.selection) {
		leftLabelX := panel.x+UI_PAD
		leftValueX := panel.x+UI_PAD+170
		rightLabelX := panel.x+UI_PAD+186
		rightValueX := panel.x+panel.width-UI_PAD
		for i in 0..<statCount {
			column := i/4
			row := i%4
			y := panel.y+UI_STAT_Y+f32(row)*UI_STAT_H
			valueColor := stats[i].color
			if valueColor.a == 0 do valueColor = UI_COLOR_TEXT
			if column == 0 {
				UIDrawStatLabel(stats[i], leftLabelX, y)
				UITextRight(stats[i].value, leftValueX, y, valueColor)
			} else {
				UIDrawStatLabel(stats[i], rightLabelX, y)
				UITextRight(stats[i].value, rightValueX, y, valueColor)
			}
		}

	} else {
		for i in 0..<statCount {
			y := panel.y+UI_STAT_Y+f32(i)*UI_STAT_H
			valueColor := stats[i].color
			if valueColor.a == 0 do valueColor = UI_COLOR_TEXT
			UIDrawStatLabel(stats[i], panel.x+UI_PAD, y)
			UIText(stats[i].value, panel.x+UI_PAD+104, y, valueColor)
		}
	}

	if ui.selection.kind == .Unit {
		UIDrawUnitEffects(w, renderer, panel, ui.selection.slot)
	}
	if ui.selection.kind == .Building && BuildingKindOf(w.buildings[ui.selection.slot].type) == .Home {
		UIDrawHomeOccupant(w, renderer, panel, ui.selection.slot)
	}

	if UISelectionTownHall(w, ui.selection) {
		if kingdom != NEUTRAL_KINGDOM do UIDrawGrowthBar(w, panel, kingdom, town)
		if UICanControlKingdom(w, kingdom) {
			UIDrawTownTabs(w, ui, panel)
			switch ui.tab {
			case .Town:
				UIDrawConversions(w, renderer, ui, panel, kingdom, town)
			case .Orders:
				UIDrawOrdersTab(w, renderer, panel, kingdom, town)
			case .Works:
				UIDrawConstructionsTab(w, renderer, panel, kingdom, town)
			}
		}
	}
}

UIDistrictHallName :: proc(w: ^World, buildingSlot: int) -> cstring {
	if buildingSlot < 0 || buildingSlot >= BUILDING_CAPACITY || !w.buildingUsed[buildingSlot] {
		return "District Hall"
	}
	building := w.buildings[buildingSlot]
	if BuildingKindOf(building.type) != .DistrictHall do return "District Hall"
	if !WorldTownExists(w, building.kingdom, building.town) do return "District Hall"
	town := &w.kingdoms[building.kingdom].towns[building.town]
	for districtIndex in 0..<town.districtCount {
		district := &town.districts[districtIndex]
		if district.x == building.x && district.y == building.y {
			return cstring(rawptr(&district.name[0]))
		}
	}
	return "District Hall"
}

UIHomeOccupant :: proc(w: ^World, homeSlot: int) -> int {
	if homeSlot < 0 || homeSlot >= BUILDING_CAPACITY || !w.buildingUsed[homeSlot] do return -1
	if BuildingKindOf(w.buildings[homeSlot].type) != .Home do return -1
	resident := w.buildings[homeSlot].homeResident-1
	if UnitInsideHome(w, resident) == homeSlot do return resident
	return -1
}

UIDrawHomeOccupant :: proc(w: ^World, renderer: ^WorldRenderer, panel: rl.Rectangle, homeSlot: int) {
	y := panel.y+UI_STAT_Y+UI_STAT_H+10
	resident := UIHomeOccupant(w, homeSlot)
	if resident < 0 {
		UIText("INDOOR OCCUPANT", panel.x+UI_PAD, y, UI_COLOR_DIM)
		UIText("No one inside.", panel.x+UI_PAD, y+28, UI_COLOR_DIM)
		return
	}
	label: cstring = "SLEEPING INSIDE"
	if w.units[resident].state.(StatePacific) == .Hiding do label = "SHELTERING INSIDE"
	UIText(label, panel.x+UI_PAD, y, UI_COLOR_DIM)
	kind := UnitKindOf(w.units[resident].type)
	faction := FactionSpriteIndex(w.units[resident].kingdome)
	texture := renderer.sprites.unit[faction][kind]
	stage := UnitDamageStage(w, resident)
	if stage > 0 {
		hurt := renderer.sprites.unitHurt[faction][kind][stage-1]
		if hurt.id != 0 do texture = hurt
	}
	icon := rl.Rectangle{panel.x+UI_PAD, y+26, 32, 32}
	if texture.id != 0 {
		source := rl.Rectangle{0, 0, f32(texture.width), f32(texture.height)}
		rl.DrawTexturePro(texture, source, icon, rl.Vector2{0, 0}, 0, rl.WHITE)
	}
	UIText(fmt.ctprintf("%s #%d", UIUnitName(kind), resident+1), icon.x+42, icon.y+6, UI_COLOR_TEXT)
}

UIDrawTownTabs :: proc(w: ^World, ui: ^UIState, panel: rl.Rectangle) {
	rl.DrawRectangleRec(
		rl.Rectangle{panel.x+UI_PAD, panel.y+UI_TOWN_DIVIDER, panel.width-2*UI_PAD, 1},
		UI_COLOR_DIVIDER,
	)

	kingdom, town := UISelectionTown(w, ui.selection)
	villagers := TownUnitCount(w, kingdom, town, .Villager)
	UITextRight(
		fmt.ctprintf("%d villagers", villagers),
		panel.x+panel.width-UI_PAD,
		panel.y+UI_TABS_Y,
		UI_COLOR_DIM,
	)

	mouse := rl.GetMousePosition()
	tabs := UITabRects(panel)
	for label, index in UI_TOWN_TABS {
		rect := tabs[index]
		active := int(ui.tab) == index
		hovered := rl.CheckCollisionPointRec(mouse, rect)
		color := UI_COLOR_DIM
		if active {
			color = UI_COLOR_GOLD
		} else if hovered {
			color = UI_COLOR_TEXT
		}
		UIText(label, rect.x+4, rect.y-1, color)
		if active {
			rl.DrawRectangleRec(
				rl.Rectangle{rect.x+4, rect.y+UI_TABS_H-2, rect.width-8, 2},
				UI_COLOR_GOLD,
			)
		}
	}
}

UIDrawPortrait :: proc(w: ^World, renderer: ^WorldRenderer, ui: ^UIState, box: rl.Rectangle) {
	kingdom, _ := UISelectionTown(w, ui.selection)
	faction := FactionSpriteIndex(kingdom)

	texture: rl.Texture2D
	switch ui.selection.kind {
	case .Unit:
		kind := UnitKindOf(w.units[ui.selection.slot].type)
		texture = renderer.sprites.unit[faction][kind]
		stage := UnitDamageStage(w, ui.selection.slot)
		if stage > 0 {
			hurt := renderer.sprites.unitHurt[faction][kind][stage-1]
			if hurt.id != 0 do texture = hurt
		}
	case .Building:
		kind := BuildingKindOf(w.buildings[ui.selection.slot].type)
		texture = renderer.sprites.building[faction][kind]
		stage := BuildingDamageStage(w, ui.selection.slot)
		if stage > 0 {
			damaged := renderer.sprites.buildingDamaged[faction][kind][stage-1]
			if damaged.id != 0 do texture = damaged
		}
	case .None:
		return
	}
	if texture.id == 0 do return

	scale := max(1, int(box.width/f32(max(texture.width, texture.height))))
	width := f32(texture.width)*f32(scale)
	height := f32(texture.height)*f32(scale)
	dest := rl.Rectangle{box.x+(box.width-width)*0.5, box.y+(box.height-height)*0.5, width, height}
	source := rl.Rectangle{0, 0, f32(texture.width), f32(texture.height)}
	rl.DrawTexturePro(texture, source, dest, rl.Vector2{0, 0}, 0, rl.WHITE)
}

UIResourceCoverage :: proc(potential, need: f32) -> (cstring, rl.Color) {
	if need <= 0 do return "100%", UI_COLOR_GOOD
	ratio := clamp(potential/need, 0, 1)
	percent := int(math.floor(ratio*100+0.0001))
	color := UI_COLOR_GOOD
	if ratio < 0.999 do color = UI_COLOR_BAD
	return fmt.ctprintf("%d%%", percent), color
}

UIFillStats :: proc(w: ^World, renderer: ^WorldRenderer, ui: ^UIState, stats: ^[8]UIStat) -> int {
	switch ui.selection.kind {
	case .Unit:
		unit := w.units[ui.selection.slot]
		stats[0] = {"Health", fmt.ctprintf("%d / %d", int(unit.health), int(UnitDefaultHealth(unit.type))), UI_COLOR_TEXT, {}}
		stats[1] = {"Task", UIUnitStateName(unit.state), UI_COLOR_TEXT, {}}
		return 2

	case .Building:
		building := w.buildings[ui.selection.slot]
		kind := BuildingKindOf(building.type)
		stats[0] = {"Health", fmt.ctprintf("%d / %d", int(building.health), int(BuildingDefaultHealth(building.type))), UI_COLOR_TEXT, {}}
		if kind == .TownHall {
			t := &w.kingdoms[building.kingdom].towns[building.town]
			stats[1] = {"Citizens", fmt.ctprintf("%d", t.citizens), UI_COLOR_TEXT, {}}
			if building.kingdom == NEUTRAL_KINGDOM {
				guards := TownUnitCount(w, building.kingdom, building.town, .Knight)
				stats[2] = {"Guards", fmt.ctprintf("%d", guards), UI_COLOR_TEXT, {}}
				stats[3] = {"Growth", "None", UI_COLOR_DIM, {}}
				return 4
			}
			stats[2] = {"Wood", fmt.ctprintf("%d", int(t.wood)), UI_COLOR_TEXT, renderer.sprites.woodIcon}
			if t.milestonesEarned < TOWN_MILESTONE_TIER_COUNT {
				stats[3] = {
					"Next era",
					fmt.ctprintf("%d / %d", t.citizens, TOWN_ERAS[t.milestonesEarned+1].threshold),
					UI_COLOR_TEXT,
					{},
				}
			} else {
				stats[3] = {"Era", "5 - complete", UI_COLOR_TEXT, {}}
			}
			foodText, foodColor := UIResourceCoverage(t.foodPotential, f32(t.citizens)*0.025)
			waterText, waterColor := UIResourceCoverage(t.waterPotential, f32(t.citizens)*0.025)
			stats[4] = {"Food", foodText, foodColor, {}}
			stats[5] = {"Water", waterText, waterColor, {}}
			stats[6] = {"Housing", fmt.ctprintf("%d", t.homes), UI_COLOR_TEXT, {}}
			return 7
		}
		if kind == .DistrictHall {
			districtName: cstring = "District"
			t := &w.kingdoms[building.kingdom].towns[building.town]
			for districtIndex in 0..<t.districtCount {
				district := &t.districts[districtIndex]
				if district.x == building.x && district.y == building.y {
					districtName = fmt.ctprintf("%s", cstring(&district.name[0]))
					break
				}
			}
			stats[1] = {
				"Growth",
				fmt.ctprintf("+%d%%", int(TOWN_DISTRICT_GROWTH_BONUS*100)),
				UI_COLOR_GOOD,
				{},
			}
			stats[2] = {"District", districtName, UI_COLOR_TEXT, {}}
			return 3
		}
		if BuildingIsTraining(kind) {
			stats[1] = {"Trains", UIUnitName(UIUnitFromTraining(kind)), UI_COLOR_TEXT, {}}
			return 2
		}
		return 1

	case .None:
	}
	return 0
}

UIUnitEffectName :: proc(effect: UnitEffects) -> cstring {
	switch effect {
	case .NoHome:
		return "Homeless"
	case .NoWater:
		return "Water shortage"
	case .NoFood:
		return "Food shortage"
	}
	unreachable()
}

UIUnitEffectText :: proc(effect: UnitEffects) -> cstring {
	switch effect {
	case .NoHome:
		return "No housing: health regenerates 4x slower."
	case .NoWater:
		return "Water shortage: movement speed -30%."
	case .NoFood:
		return "Food shortage: the town cannot feed everyone."
	}
	unreachable()
}

UIDrawUnitEffects :: proc(
	w: ^World,
	renderer: ^WorldRenderer,
	panel: rl.Rectangle,
	unitSlot: int,
) {
	count := UIUnitEffectCount(w, unitSlot)
	if count <= 0 do return

	y := panel.y+UI_STAT_Y+2*UI_STAT_H+3
	UIText("Effects", panel.x+UI_PAD, y+3, UI_COLOR_DIM)

	mouse := rl.GetMousePosition()
	x := panel.x+UI_PAD+78
	hovered := UnitEffects.NoHome
	anyHovered := false
	for effect in ALL_UNIT_EFFECTS {
		if !w.units[unitSlot].effects[effect] do continue
		icon := rl.Rectangle{x, y, 22, 22}
		hover := rl.CheckCollisionPointRec(mouse, icon)
		background := UI_COLOR_BUTTON_OFF
		border := UI_COLOR_BORDER_INNER
		if hover {
			background = UI_COLOR_BUTTON_HOVER
			border = UI_COLOR_GOLD
			hovered = effect
			anyHovered = true
		}
		rl.DrawRectangleRec(icon, background)
		rl.DrawRectangleLinesEx(icon, 1, border)

		texture := renderer.sprites.effect[effect]
		if texture.id != 0 {
			source := rl.Rectangle{0, 0, f32(texture.width), f32(texture.height)}
			rl.DrawTexturePro(texture, source, icon, rl.Vector2{0, 0}, 0, rl.WHITE)
		}
		x += 27
	}

	if anyHovered do UIDrawUnitEffectTooltip(mouse, hovered)
}

UIDrawUnitEffectTooltip :: proc(mouse: rl.Vector2, effect: UnitEffects) {
	title := UIUnitEffectName(effect)
	body := UIUnitEffectText(effect)
	titleWidth := rl.MeasureTextEx(UIFont(), title, UI_TEXT_SIZE, 1).x
	bodyWidth := rl.MeasureTextEx(UIFont(), body, UI_TEXT_SIZE, 1).x
	padding: f32 = 8
	lineHeight := UIHudLineHeight()
	width := max(titleWidth, bodyWidth)+padding*2
	height := lineHeight*2+padding*2+4

	x := mouse.x+16
	y := mouse.y+16
	screenWidth := f32(rl.GetScreenWidth())
	screenHeight := f32(rl.GetScreenHeight())
	if x+width > screenWidth-8 do x = mouse.x-16-width
	if y+height > screenHeight-8 do y = mouse.y-16-height

	rl.DrawRectangleRec(rl.Rectangle{x, y, width, height}, UI_COLOR_BG)
	rl.DrawRectangleLinesEx(rl.Rectangle{x, y, width, height}, 1, UI_COLOR_GOLD)
	UIText(title, x+padding, y+padding, UI_COLOR_GOLD)
	UIText(body, x+padding, y+padding+lineHeight, UI_COLOR_TEXT)
}

UIDrawGrowthBar :: proc(w: ^World, panel: rl.Rectangle, kingdom, town: int) {
	if !WorldTownExists(w, kingdom, town) do return
	t := &w.kingdoms[kingdom].towns[town]

	y := panel.y+UI_GROWTH_Y
	eta := max(t.growthCooldown, 0)/max(t.growthSpeed, 0.01)
	label := fmt.ctprintf("Next %d in %ds", t.growthBatch, int(math.ceil(eta)))
	if WorldIsNight(w) do label = "Night"
	UIText(
		label,
		panel.x+UI_PAD,
		y,
		UI_COLOR_DIM,
	)

	bar := rl.Rectangle{
		panel.x+UI_PAD+164,
		y+6,
		panel.width-2*UI_PAD-164,
		9,
	}
	progress: f32 = 0
	if t.growthInterval > 0 do progress = clamp(1-t.growthCooldown/t.growthInterval, 0, 1)

	rl.DrawRectangleRec(bar, UI_COLOR_BUTTON_OFF)
	if progress > 0 {
		rl.DrawRectangleRec(
			rl.Rectangle{bar.x, bar.y, bar.width*progress, bar.height},
			UI_COLOR_GOLD,
		)
	}
	rl.DrawRectangleLinesEx(bar, 1, UI_COLOR_BORDER_INNER)
}


UIDrawConversions :: proc(w: ^World, renderer: ^WorldRenderer, ui: ^UIState, panel: rl.Rectangle, kingdom, town: int) {
	kinds: [len(UnitKind)]UnitKind
	count := UIConversionRows(w, ui.selection, &kinds)
	for i in 0..<count {
		UIDrawConversionRow(w, renderer, ui, panel, i, kinds[i], kingdom, town)
	}
}

UIConversionProgress :: proc(w: ^World, kingdom, town: int, kind: UnitKind) -> (assigned, remaining, training: int, progress: f32, hasJob: bool) {
	if !WorldTownExists(w, kingdom, town) do return
	t := &w.kingdoms[kingdom].towns[town]
	for jobIndex in 0..<t.conversionCount {
		job := t.conversions[jobIndex]
		if job.to != kind do continue
		hasJob = true
		assigned += job.assigned
		remaining += job.remaining
	}
	if !hasJob do return

	for unitSlot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[unitSlot] do continue
		if w.units[unitSlot].kingdome != kingdom || w.units[unitSlot].town != town do continue
		state, converting := w.units[unitSlot].state.(StateConverting)
		if !converting || state.to != kind || !state.inside do continue
		training += 1
		seconds := UnitDefaultTrainingTime(kind)
		if seconds > 0 do progress += 1-clamp(state.timer/seconds, 0, 1)
	}
	if training > 0 do progress /= f32(training)
	return
}

UIDrawConversionRow :: proc(w: ^World, renderer: ^WorldRenderer, ui: ^UIState, panel: rl.Rectangle, index: int, kind: UnitKind, kingdom, town: int) {
	rowY := panel.y+UI_ROWS_TOP+f32(index)*UI_ROW_HEIGHT

	faction := FactionSpriteIndex(kingdom)
	unitCount := TownUnitCount(w, kingdom, town, kind)
	icon := UIUnitIconRect(panel, index)
	interactive := unitCount > 0
	iconHovered := interactive && rl.CheckCollisionPointRec(rl.GetMousePosition(), icon)
	background := interactive ? UI_COLOR_BUTTON : UI_COLOR_BUTTON_OFF
	if iconHovered do background = UI_COLOR_BUTTON_HOVER
	rl.DrawRectangleRec(icon, background)
	rl.DrawRectangleLinesEx(icon, 1, iconHovered ? UI_COLOR_GOLD : UI_COLOR_BORDER_INNER)
	texture := renderer.sprites.unit[faction][kind]
	if texture.id != 0 {
		source := rl.Rectangle{0, 0, f32(texture.width), f32(texture.height)}
		rl.DrawTexturePro(texture, source, icon, rl.Vector2{0, 0}, 0, rl.WHITE)
	}

	available := TownUnitAvailable(w, kingdom, town, kind)
	missingBuilding := TownUnitUnlocked(w, kingdom, town, kind) && !available
	labelY := missingBuilding ? rowY+1 : rowY+8
	UIText(UIUnitName(kind), panel.x+UI_PAD+38, labelY, available ? UI_COLOR_TEXT : UI_COLOR_DIM)
	if missingBuilding {
		buildingKind := UnitTrainingBuildingKind(kind)
		hint := fmt.ctprintf("Needs %s", UIBuildingName(buildingKind))
		if TownConstructionKindCount(w, kingdom, town, buildingKind) > 0 {
			hint = fmt.ctprintf("Building %s", UIBuildingName(buildingKind))
		}
		rl.DrawTextEx(UIFont(), hint, rl.Vector2{panel.x+UI_PAD+38, rowY+22}, 12, 1, UI_COLOR_DIM)
	}

	minus, plus := UIButtonRects(panel, index)
	_, remaining, training, progress, hasJob := UIConversionProgress(w, kingdom, town, kind)
	if hasJob && remaining > 0 {
		UIText(fmt.ctprintf("%d/%d", training, remaining), minus.x-112, rowY+8, UI_COLOR_DIM)

		if !missingBuilding {
			bar := rl.Rectangle{
				panel.x+UI_PAD+38,
				rowY+31,
				max(minus.x-130-(panel.x+UI_PAD+38), 20),
				3,
			}
			rl.DrawRectangleRec(bar, UI_COLOR_BUTTON_OFF)
			if progress > 0 {
				rl.DrawRectangleRec(
					rl.Rectangle{bar.x, bar.y, bar.width*progress, bar.height},
					UI_COLOR_GOLD,
				)
			}
		}
	}

	pending := UIConversionPending(w, kingdom, town, kind)
	if pending != 0 {
		UIText(fmt.ctprintf("%+d", pending), minus.x-56, rowY+8, UI_COLOR_GOLD)
	}
	UITextRight(fmt.ctprintf("%d", unitCount), minus.x-8, rowY+8, UI_COLOR_TEXT)

	UIButton(minus, "-", UICanConvertFrom(w, kingdom, town, kind))
	UIButton(plus, "+", UICanConvertTo(w, kingdom, town, kind))
}

UIDrawOrdersTab :: proc(w: ^World, renderer: ^WorldRenderer, panel: rl.Rectangle, kingdom, town: int) {
	if !WorldTownExists(w, kingdom, town) do return
	top := panel.y+UI_ROWS_TOP
	orders := UITownOrderCount(w, kingdom, town)

	UIText("STANDING ORDERS", panel.x+UI_PAD, top, UI_COLOR_DIM)
	UITextRight(fmt.ctprintf("%d orders", orders), panel.x+panel.width-UI_PAD, top, UI_COLOR_DIM)

	if orders == 0 {
		UIText("No standing orders.", panel.x+UI_PAD, top+UI_SECTION_HEADER+8, UI_COLOR_DIM)
		return
	}

	for index in 0..<orders {
		attack, targetKingdom, targetTown, found := UITownOrderAt(w, kingdom, town, index)
		if !found do continue
		rowY := panel.y+UI_ROWS_TOP+UI_SECTION_HEADER+f32(index)*UI_ROW_HEIGHT

		faction := FactionSpriteIndex(targetKingdom)
		texture := renderer.sprites.building[faction][.TownHall]
		if texture.id != 0 {
			icon := rl.Rectangle{panel.x+UI_PAD, rowY+2, 32, 32}
			source := rl.Rectangle{0, 0, f32(texture.width), f32(texture.height)}
			rl.DrawTexturePro(texture, source, icon, rl.Vector2{0, 0}, 0, rl.WHITE)
		}

		label := attack ? fmt.ctprintf("Attack  %s", NameTownCString(w, targetKingdom, targetTown)) : fmt.ctprintf("Defend  %s", NameTownCString(w, targetKingdom, targetTown))
		labelColor := attack ? UI_COLOR_ATTACK : UI_COLOR_DEFEND
		UIText(label, panel.x+UI_PAD+38, rowY+8, labelColor)
		UIButton(UIOrderCancelRect(panel, index), "Cancel", true)
	}
}

UIDrawConstructionsTab :: proc(w: ^World, renderer: ^WorldRenderer, panel: rl.Rectangle, kingdom, town: int) {
	if !WorldTownExists(w, kingdom, town) do return
	t := &w.kingdoms[kingdom].towns[town]
	top := panel.y+UI_ROWS_TOP
	count := TownConstructionCount(w, kingdom, town)

	UIText("CONSTRUCTION SITES", panel.x+UI_PAD, top, UI_COLOR_DIM)
	UITextRight(fmt.ctprintf("%d sites", count), panel.x+panel.width-UI_PAD, top, UI_COLOR_DIM)

	if count == 0 {
		UIText("No construction sites.", panel.x+UI_PAD, top+UI_SECTION_HEADER+8, UI_COLOR_DIM)
		return
	}

	faction := FactionSpriteIndex(kingdom)
	row := 0
	for site in t.constructions {
		if !site.active do continue
		rowY := panel.y+UI_ROWS_TOP+UI_SECTION_HEADER+f32(row)*UI_CONSTRUCTION_ROW_HEIGHT
		texture := renderer.sprites.building[faction][site.kind]
		if texture.id != 0 {
			icon := rl.Rectangle{panel.x+UI_PAD, rowY+3, 22, 22}
			source := rl.Rectangle{0, 0, f32(texture.width), f32(texture.height)}
			rl.DrawTexturePro(texture, source, icon, rl.Vector2{0, 0}, 0, rl.WHITE)
		}

		labelX := panel.x+UI_PAD+30
		rl.DrawTextEx(UIFont(), UIBuildingName(site.kind), rl.Vector2{labelX, rowY}, 16, 1, UI_COLOR_TEXT)

		progress: f32 = 0
		status: cstring
		decoration := TownConstructionPendingDecoration(w, site)
		if decoration >= 0 {
			seconds := DecorationClearSeconds(w.decorations.kind[decoration])
			if seconds > 0 do progress = clamp(site.clearWork/seconds, 0, 1)
			status = fmt.ctprintf("Clearing ground  %d%%", int(progress*100))
		} else {
			seconds := BuildingBuildSeconds(site.kind)
			if seconds > 0 do progress = clamp(site.buildWork/seconds, 0, 1)
			status = fmt.ctprintf("Building  %d%%", int(progress*100))
		}
		rl.DrawTextEx(UIFont(), status, rl.Vector2{labelX, rowY+14}, 12, 1, UI_COLOR_DIM)

		bar := rl.Rectangle{panel.x+panel.width-UI_PAD-90, rowY+11, 90, 6}
		rl.DrawRectangleRec(bar, UI_COLOR_BUTTON_OFF)
		if progress > 0 {
			rl.DrawRectangleRec(
				rl.Rectangle{bar.x, bar.y, bar.width*progress, bar.height},
				UI_COLOR_GOLD,
			)
		}
		rl.DrawRectangleLinesEx(bar, 1, UI_COLOR_BORDER_INNER)
		row += 1
	}
}

UIDrawCommandBar :: proc(w: ^World, renderer: ^WorldRenderer, ui: ^UIState) {
	if !UISelectionPlayerTownHall(w, ui.selection) do return
	kingdom, town := UISelectionTown(w, ui.selection)
	attackRect, defendRect, foundRect, fuseRect := UICommandBarRects()
	UIDrawCommandIcon(
		attackRect,
		.Attack,
		UIAttackTargetExists(w, kingdom, town),
		ui.command == .Attack,
	)
	UIDrawCommandIcon(
		defendRect,
		.Defend,
		UIDefendTargetExists(w, kingdom, town),
		ui.command == .Defend,
	)
	UIDrawCommandIcon(
		foundRect,
		.Found,
		UIFoundButtonEnabled(w, kingdom, town),
		ui.command == .Found,
	)
	if TownEra(w, kingdom, town) >= TOWN_FUSION_ERA {
		UIDrawCommandIcon(
			fuseRect,
			.Fuse,
			UIFusionTargetExists(w, kingdom, town),
			ui.command == .Fuse,
		)
		if rl.CheckCollisionPointRec(rl.GetMousePosition(), fuseRect) {
			UIDrawFuseHint(w, fuseRect, kingdom, town)
		}
	}
	if rl.CheckCollisionPointRec(rl.GetMousePosition(), foundRect) {
		UIDrawFoundHint(w, renderer, foundRect, kingdom, town)
	}
}

// Found-button hover readout: one chip per requirement, each with an icon and
// a red/green current/required readout so the missing piece is obvious.
UIFoundRequirements :: proc(w: ^World, kingdom, town: int) -> ([3]UIFoundRequirement, int) {
	townState := &w.kingdoms[kingdom].towns[town]
	requirements := [3]UIFoundRequirement{
		{.Wood, int(townState.wood), int(TownFoundingWoodCost(w, kingdom))},
		{.Settlers, TownUnitCount(w, kingdom, town, .Villager), TOWN_FOUNDING_SETTLERS},
		{.Builders, TownUnitCount(w, kingdom, town, .Builder), 1},
	}
	return requirements, len(requirements)
}

UIDrawFoundSpriteIcon :: proc(texture: rl.Texture2D, x, y: f32) {
	if texture.id == 0 do return
	source := rl.Rectangle{0, 0, f32(texture.width), f32(texture.height)}
	rl.DrawTexturePro(texture, source, rl.Rectangle{x+1, y+1, 16, 16}, rl.Vector2{0, 0}, 0, rl.WHITE)
}

UIDrawFoundRequirementIcon :: proc(
	renderer: ^WorldRenderer,
	faction: int,
	icon: UIFoundRequirementIcon,
	x, y: f32,
) {
	switch icon {
	case .Wood:
		UIDrawFoundSpriteIcon(renderer.sprites.woodIcon, x, y)
	case .Settlers:
		UIDrawFoundSpriteIcon(renderer.sprites.unit[faction][.Villager], x, y)
	case .Builders:
		UIDrawFoundSpriteIcon(renderer.sprites.unit[faction][.Builder], x, y)
	}
}

UIDrawFoundHint :: proc(w: ^World, renderer: ^WorldRenderer, rect: rl.Rectangle, kingdom, town: int) {
	if !WorldTownExists(w, kingdom, town) do return
	requirements, count := UIFoundRequirements(w, kingdom, town)
	faction := FactionSpriteIndex(kingdom)

	title: cstring = "FOUND TOWN"
	titleWidth := rl.MeasureTextEx(UIFont(), title, UI_TEXT_SIZE, 1).x
	chips: [3]f32
	chipsWidth: f32 = 0
	allMet := true
	for requirement, index in requirements[:count] {
		text := fmt.ctprintf("%d/%d", requirement.current, requirement.required)
		chips[index] = UI_FOUND_REQ_ICON+UI_FOUND_REQ_TEXT_GAP+
			rl.MeasureTextEx(UIFont(), text, UI_FOUND_HINT_TEXT_SIZE, 1).x
		chipsWidth += chips[index]
		if index > 0 do chipsWidth += UI_FOUND_REQ_GAP
		if requirement.current < requirement.required do allMet = false
	}

	width := max(titleWidth, chipsWidth)+2*UI_PAD
	height := 2*UI_PAD+UI_TEXT_SIZE+2+UI_FOUND_REQ_ICON
	screenWidth := f32(rl.GetScreenWidth())
	x := clamp(rect.x+rect.width*0.5-width*0.5, 8, screenWidth-width-8)
	y := rect.y-height-8
	box := rl.Rectangle{x, y, width, height}
	rl.DrawRectangleRec(box, UI_COLOR_BG)
	border := allMet ? UI_COLOR_GOOD : UI_COLOR_BORDER
	rl.DrawRectangleLinesEx(box, 1, border)

	UIText(title, x+UI_PAD, y+UI_PAD-3, allMet ? UI_COLOR_GOOD : UI_COLOR_GOLD)
	chipX := x+UI_PAD+max((width-2*UI_PAD-chipsWidth)*0.5, 0)
	chipY := y+UI_PAD+UI_TEXT_SIZE+2
	for requirement, index in requirements[:count] {
		met := requirement.current >= requirement.required
		statusColor := met ? UI_COLOR_GOOD : UI_COLOR_BAD
		UIDrawFoundRequirementIcon(renderer, faction, requirement.icon, chipX, chipY)
		text := fmt.ctprintf("%d/%d", requirement.current, requirement.required)
		rl.DrawTextEx(
			UIFont(),
			text,
			rl.Vector2{chipX+UI_FOUND_REQ_ICON+UI_FOUND_REQ_TEXT_GAP, chipY-1},
			UI_FOUND_HINT_TEXT_SIZE,
			1,
			statusColor,
		)
		chipX += chips[index]+UI_FOUND_REQ_GAP
	}
}

UIDrawFuseHint :: proc(w: ^World, rect: rl.Rectangle, kingdom, town: int) {
	if !WorldTownExists(w, kingdom, town) do return
	t := &w.kingdoms[kingdom].towns[town]
	cost := TownFusionCost(w, kingdom, town)
	text := fmt.ctprintf(
		"Fuse era 5 towns  -  costs %d wood  -  shared frontier required",
		int(cost),
	)
	width := rl.MeasureTextEx(UIFont(), text, UI_TEXT_SIZE, 1).x+2*UI_PAD
	height := UI_TEXT_SIZE+2*UI_PAD
	screenWidth := f32(rl.GetScreenWidth())
	x := clamp(rect.x+rect.width*0.5-width*0.5, 8, screenWidth-width-8)
	y := rect.y-height-8
	rl.DrawRectangleRec(rl.Rectangle{x, y, width, height}, UI_COLOR_BG)
	rl.DrawRectangleLinesEx(rl.Rectangle{x, y, width, height}, 1, UI_COLOR_BORDER)
	color := UI_COLOR_TEXT
	if TownEra(w, kingdom, town) < TOWN_FUSION_ERA || t.wood < cost ||
		!UIFusionTargetExists(w, kingdom, town) {
		color = UI_COLOR_BAD
	}
	UIText(text, x+UI_PAD, y+UI_PAD-2, color)
}

TownFusionFailureText :: proc(failure: FusionFailure) -> cstring {
	switch failure {
	case .None:
		return "Ready to fuse"
	case .NoTown:
		return "No town selected"
	case .DifferentKingdom:
		return "Only towns of the same kingdom can fuse"
	case .SameTown:
		return "Choose another town"
	case .NotEraFive:
		return "Both towns must be in era 5"
	case .NoHall:
		return "A town hall is missing"
	case .NoFrontier:
		return "Towns must share a frontier"
	case .PendingMilestone:
		return "Resolve milestone rewards first"
	case .NoWood:
		return "Not enough wood for the fusion"
	case .DistrictLimit:
		return "This town has reached its district limit"
	case .ConstructionConflict:
		return "Finish active construction first"
	case .ConversionLimit:
		return "Too many conversion jobs to merge"
	}
	return ""
}

UIDrawCommandIcon :: proc(rect: rl.Rectangle, command: UICommand, enabled, active: bool) {
	hovered := enabled && rl.CheckCollisionPointRec(rl.GetMousePosition(), rect)
	background := UI_COLOR_BUTTON
	if !enabled {
		background = UI_COLOR_BUTTON_OFF
	} else if hovered || active {
		background = UI_COLOR_BUTTON_HOVER
	}
	rl.DrawRectangleRec(rect, background)

	border := UI_COLOR_BORDER_INNER
	borderWidth: f32 = 1
	if active {
		switch command {
		case .Attack:
			border = UI_COLOR_ATTACK
		case .Defend:
			border = UI_COLOR_DEFEND
		case .Found:
			border = UI_COLOR_FOUND
		case .Fuse:
			border = UI_COLOR_FUSE
		case .Build, .Place:
			border = UI_COLOR_BUILD
		case .Inspect:
		}
		borderWidth = 2
	}
	rl.DrawRectangleLinesEx(rect, borderWidth, border)

	iconColor := UI_COLOR_BUILD
	switch command {
	case .Attack:
		iconColor = UI_COLOR_ATTACK
	case .Defend:
		iconColor = UI_COLOR_DEFEND
	case .Found:
		iconColor = UI_COLOR_FOUND
	case .Fuse:
		iconColor = UI_COLOR_FUSE
	case .Build, .Place, .Inspect:
	}
	if !enabled do iconColor = UI_COLOR_DISABLED_TEXT
	centerX := rect.x+rect.width*0.5
	centerY := rect.y+23
	switch command {
	case .Attack:
		UIDrawAttackIcon(centerX, centerY, iconColor)
	case .Defend:
		UIDrawDefendIcon(centerX, centerY, iconColor)
	case .Found:
		UIDrawFoundIcon(centerX, centerY, iconColor)
	case .Fuse:
		UIDrawFuseIcon(centerX, centerY, iconColor)
	case .Build, .Place:
		UIDrawBuildIcon(centerX, centerY, iconColor)
	case .Inspect:
	}

	label: cstring = "BUILD"
	switch command {
	case .Attack:
		label = "ATTACK"
	case .Defend:
		label = "DEFEND"
	case .Found:
		label = "FOUND"
	case .Fuse:
		label = "FUSE"
	case .Build, .Place, .Inspect:
	}
	labelColor := enabled ? UI_COLOR_TEXT : UI_COLOR_DISABLED_TEXT
	UITextCenter(label, rect.x+rect.width*0.5, rect.y+46, labelColor)
}

UIDrawFuseIcon :: proc(centerX, centerY: f32, color: rl.Color) {
	dark := rl.Color{12, 11, 14, 230}
	light := rl.Color{238, 238, 244, 220}

	// Two halls meeting over a shared road.
	left := rl.Rectangle{centerX-17, centerY-10, 13, 15}
	right := rl.Rectangle{centerX+4, centerY-10, 13, 15}
	rl.DrawRectangleRec(left, dark)
	rl.DrawRectangleRec(right, dark)
	rl.DrawRectangleLinesEx(left, 2, color)
	rl.DrawRectangleLinesEx(right, 2, color)
	rl.DrawTriangle(
		rl.Vector2{centerX-10.5, centerY-12},
		rl.Vector2{centerX-18, centerY-1},
		rl.Vector2{centerX-3, centerY-1},
		color,
	)
	rl.DrawTriangle(
		rl.Vector2{centerX+10.5, centerY-12},
		rl.Vector2{centerX+3, centerY-1},
		rl.Vector2{centerX+18, centerY-1},
		color,
	)
	rl.DrawLineEx(
		rl.Vector2{centerX-3, centerY+4},
		rl.Vector2{centerX+3, centerY+4},
		3,
		light,
	)
	rl.DrawLineEx(
		rl.Vector2{centerX, centerY-1},
		rl.Vector2{centerX, centerY+12},
		3,
		light,
	)
}

UIDrawAttackIcon :: proc(centerX, centerY: f32, color: rl.Color) {
	dark := rl.Color{12, 11, 14, 230}
	gold := rl.Color{224, 176, 70, 220}
	grip := rl.Color{132, 98, 64, 230}

	bladeTop := rl.Vector2{centerX, centerY-14}
	bladeBottom := rl.Vector2{centerX, centerY+2}
	rl.DrawLineEx(bladeTop, bladeBottom, 7, dark)
	rl.DrawLineEx(bladeTop, bladeBottom, 4, color)
	rl.DrawTriangle(
		rl.Vector2{centerX, centerY-19},
		rl.Vector2{centerX-4, centerY-12},
		rl.Vector2{centerX+4, centerY-12},
		color,
	)

	guardLeft := rl.Vector2{centerX-9, centerY+3}
	guardRight := rl.Vector2{centerX+9, centerY+3}
	rl.DrawLineEx(guardLeft, guardRight, 6, dark)
	rl.DrawLineEx(guardLeft, guardRight, 3, gold)

	gripTop := rl.Vector2{centerX, centerY+4}
	gripBottom := rl.Vector2{centerX, centerY+13}
	rl.DrawLineEx(gripTop, gripBottom, 7, dark)
	rl.DrawLineEx(gripTop, gripBottom, 4, grip)
	rl.DrawRectangle(i32(centerX)-2, i32(centerY)+13, 4, 4, gold)
}

UIDrawDefendIcon :: proc(centerX, centerY: f32, color: rl.Color) {
	dark := rl.Color{12, 11, 14, 230}
	center := rl.Vector2{centerX, centerY+1}
	rl.DrawPoly(center, 5, 18, 90, dark)
	rl.DrawPoly(center, 5, 15, 90, color)

	emblem := rl.Color{232, 240, 248, 230}
	x := i32(centerX)
	y := i32(centerY)
	rl.DrawRectangle(x-2, y-7, 4, 20, emblem)
	rl.DrawRectangle(x-7, y+1, 14, 4, emblem)
}

UIDrawBuildIcon :: proc(centerX, centerY: f32, color: rl.Color) {
	dark := rl.Color{12, 11, 14, 230}
	x := i32(centerX)
	y := i32(centerY)

	// Hammer handle.
	rl.DrawRectangle(x-2, y-2, 4, 18, dark)
	rl.DrawRectangle(x-1, y-1, 2, 16, rl.Color{132, 98, 64, 230})

	// Head.
	rl.DrawRectangle(x-11, y-12, 22, 7, dark)
	rl.DrawRectangle(x-10, y-11, 20, 5, color)
	rl.DrawRectangle(x-4, y-11, 8, 5, rl.Color{238, 238, 244, 210})
}

UIDrawFoundIcon :: proc(centerX, centerY: f32, color: rl.Color) {
	dark := rl.Color{12, 11, 14, 230}
	x := i32(centerX)
	y := i32(centerY)

	// Small hall with a banner.
	rl.DrawRectangle(x-10, y+1, 20, 12, dark)
	rl.DrawRectangle(x-9, y+2, 18, 10, color)
	rl.DrawRectangle(x-7, y+5, 5, 7, rl.Color{238, 238, 244, 210})
	rl.DrawTriangle(
		rl.Vector2{centerX, centerY-11},
		rl.Vector2{centerX-12, centerY+1},
		rl.Vector2{centerX+12, centerY+1},
		dark,
	)
	rl.DrawTriangle(
		rl.Vector2{centerX, centerY-9},
		rl.Vector2{centerX-10, centerY+1},
		rl.Vector2{centerX+10, centerY+1},
		color,
	)

	// Flag.
	rl.DrawLineEx(
		rl.Vector2{centerX, centerY-14},
		rl.Vector2{centerX, centerY-2},
		3,
		dark,
	)
	rl.DrawTriangle(
		rl.Vector2{centerX+1, centerY-14},
		rl.Vector2{centerX+11, centerY-10},
		rl.Vector2{centerX+1, centerY-6},
		color,
	)
}

UIDrawCommandTargets :: proc(w: ^World, camera: rl.Camera2D, ui: ^UIState) {
	kingdom, town := UISelectionTown(w, ui.selection)
	if !WorldTownExists(w, kingdom, town) do return

	for targetKingdom in 0..<KINGDOM_SLOTS {
		if !w.kingdomUsed[targetKingdom] do continue
		for targetTown in 0..<TOWN_CAPACITY {
			if !w.kingdoms[targetKingdom].townUsed[targetTown] do continue
			valid := false
			switch ui.command {
			case .Attack:
				valid = UIAttackOrderValid(w, kingdom, town, targetKingdom, targetTown)
			case .Defend:
				valid = UIDefendOrderValid(w, kingdom, town, targetKingdom, targetTown)
			case .Fuse:
				valid = TownFusionFailure(w, kingdom, town, targetKingdom, targetTown) == .None
			case .Inspect, .Found, .Build, .Place:
			}
			if !valid do continue
			UIDrawTownAreaFor(w, camera, targetKingdom, targetTown, true)
			UIDrawTownHallOutline(w, camera, targetKingdom, targetTown, 150, 1.2)
		}
	}

	hoverKingdom, hoverTown, _, found := UIFindTownAt(w, camera, rl.GetMousePosition())
	if !found do return
	valid := false
	switch ui.command {
	case .Attack:
		valid = UIAttackOrderValid(w, kingdom, town, hoverKingdom, hoverTown)
	case .Defend:
		valid = UIDefendOrderValid(w, kingdom, town, hoverKingdom, hoverTown)
	case .Fuse:
		valid = TownFusionFailure(w, kingdom, town, hoverKingdom, hoverTown) == .None
	case .Inspect, .Found, .Build, .Place:
	}
	if !valid do return
	UIDrawTownAreaFor(w, camera, hoverKingdom, hoverTown, false)
	UIDrawTownHallOutline(w, camera, hoverKingdom, hoverTown, 230, 2)

	previewColor: rl.Color
	switch ui.command {
	case .Attack:
		previewColor = UI_COLOR_ATTACK
	case .Defend:
		previewColor = UI_COLOR_DEFEND
	case .Fuse:
		previewColor = UI_COLOR_FUSE
	case .Inspect, .Found, .Build, .Place:
	}
	UIDrawOrderArrow(w, camera, kingdom, town, hoverKingdom, hoverTown, previewColor, true)
}

UIDrawTownHallOutline :: proc(w: ^World, camera: rl.Camera2D, kingdom, town: int, alpha: u8, pixelWidth: f32) {
	hall := TownHallSlot(w, kingdom, town)
	if hall < 0 do return
	width, height := BuildingTileSize(w.buildings[hall].type)
	rect := rl.Rectangle {
		f32(w.buildings.x[hall]),
		f32(w.buildings.y[hall]),
		f32(width),
		f32(height),
	}
	rl.BeginMode2D(camera)
	rl.DrawRectangleLinesEx(rect, pixelWidth/camera.zoom, rl.Color{236, 204, 116, alpha})
	rl.EndMode2D()
}

UIDrawOrderArrows :: proc(w: ^World, camera: rl.Camera2D, selection: Selection) {
	if !UISelectionTownHall(w, selection) do return
	kingdom, town := UISelectionTown(w, selection)
	if !WorldTownExists(w, kingdom, town) do return
	orders := &w.kingdoms[kingdom].towns[town]

	// Incoming orders are faint so the selected town's own orders stay readable.
	for attackerKingdom in 0..<KINGDOMS_CAPACITY {
		for attackerTown in 0..<TOWN_CAPACITY {
			if !orders.attackedBy[attackerKingdom][attackerTown] do continue
			if !WorldTownExists(w, attackerKingdom, attackerTown) do continue
			if !FogTownDiscovered(w, attackerKingdom, attackerTown) do continue
			UIDrawOrderArrow(
				w,
				camera,
				attackerKingdom,
				attackerTown,
				kingdom,
				town,
				UI_COLOR_ATTACK_FAINT,
				false,
			)
		}
	}
	for defenderKingdom in 0..<KINGDOMS_CAPACITY {
		for defenderTown in 0..<TOWN_CAPACITY {
			if !orders.defendedBy[defenderKingdom][defenderTown] do continue
			if !WorldTownExists(w, defenderKingdom, defenderTown) do continue
			if !FogTownDiscovered(w, defenderKingdom, defenderTown) do continue
			if defenderKingdom == kingdom && defenderTown == town do continue
			UIDrawOrderArrow(
				w,
				camera,
				defenderKingdom,
				defenderTown,
				kingdom,
				town,
				UI_COLOR_DEFEND_FAINT,
				false,
			)
		}
	}

	for targetKingdom in 0..<KINGDOM_SLOTS {
		for targetTown in 0..<TOWN_CAPACITY {
			if !orders.attackOrders[targetKingdom][targetTown] do continue
			if !WorldTownExists(w, targetKingdom, targetTown) do continue
			if !FogTownDiscovered(w, targetKingdom, targetTown) do continue
			UIDrawOrderArrow(w, camera, kingdom, town, targetKingdom, targetTown, UI_COLOR_ATTACK, false)
		}
	}
	for protectedKingdom in 0..<KINGDOMS_CAPACITY {
		for protectedTown in 0..<TOWN_CAPACITY {
			if !orders.defendOrders[protectedKingdom][protectedTown] do continue
			if !WorldTownExists(w, protectedKingdom, protectedTown) do continue
			if !FogTownDiscovered(w, protectedKingdom, protectedTown) do continue
			if protectedKingdom == kingdom && protectedTown == town do continue
			UIDrawOrderArrow(w, camera, kingdom, town, protectedKingdom, protectedTown, UI_COLOR_DEFEND, false)
		}
	}
}

// Arrows are drawn in screen space so their heads keep a constant size at any zoom.
UIDrawOrderArrow :: proc(w: ^World, camera: rl.Camera2D, fromKingdom, fromTown, toKingdom, toTown: int, color: rl.Color, preview: bool) {
	fromHall := TownHallSlot(w, fromKingdom, fromTown)
	toHall := TownHallSlot(w, toKingdom, toTown)
	if fromHall < 0 || toHall < 0 do return

	fromWidth, fromHeight := BuildingTileSize(w.buildings[fromHall].type)
	toWidth, toHeight := BuildingTileSize(w.buildings[toHall].type)
	fromX := f32(w.buildings.x[fromHall])+f32(fromWidth)*0.5
	fromY := f32(w.buildings.y[fromHall])+f32(fromHeight)*0.5
	toX := f32(w.buildings.x[toHall])+f32(toWidth)*0.5
	toY := f32(w.buildings.y[toHall])+f32(toHeight)*0.5
	deltaX := WorldShortestWrappedDelta(toX-fromX, f32(w.maxX))
	deltaY := WorldShortestWrappedDelta(toY-fromY, f32(w.maxY))

	start := rl.GetWorldToScreen2D(rl.Vector2{fromX, fromY}, camera)
	end := rl.GetWorldToScreen2D(rl.Vector2{fromX+deltaX, fromY+deltaY}, camera)
	dx := end.x-start.x
	dy := end.y-start.y
	length := math.sqrt(dx*dx+dy*dy)
	if length < 1 do return

	dirX := dx/length
	dirY := dy/length
	headLength: f32 = preview ? 12 : 16
	headHalf: f32 = preview ? 5 : 7
	lineWidth: f32 = preview ? 1.8 : 2.6
	lineColor := color
	if preview do lineColor.a = 150

	base := rl.Vector2{end.x-dirX*headLength, end.y-dirY*headLength}
	perpX := -dirY
	perpY := dirX
	left := rl.Vector2{base.x+perpX*headHalf, base.y+perpY*headHalf}
	right := rl.Vector2{base.x-perpX*headHalf, base.y-perpY*headHalf}

	outline := rl.Color{12, 11, 14, 170}
	rl.DrawLineEx(start, base, lineWidth+2.2, outline)
	rl.DrawLineEx(start, base, lineWidth, lineColor)

	outerTip := rl.Vector2{end.x+dirX*1.5, end.y+dirY*1.5}
	outerLeft := rl.Vector2{left.x+perpX*1.5, left.y+perpY*1.5}
	outerRight := rl.Vector2{right.x-perpX*1.5, right.y-perpY*1.5}
	rl.DrawTriangle(outerTip, outerLeft, outerRight, outline)
	rl.DrawTriangle(end, left, right, lineColor)
}

UIPlacementFailureText :: proc(failure: PlacementFailure) -> cstring {
	switch failure {
	case .None:
		return ""
	case .NoTown:
		return "Town no longer exists"
	case .AlreadyFounding:
		return "A town hall is already under construction"
	case .Unexplored:
		return "Area not explored"
	case .InvalidTerrain:
		return "Invalid or blocked terrain"
	case .CombatSiteOverlap:
		return "Overlaps a combat construction site"
	case .ConstructionOverlap:
		return "Overlaps another construction site"
	case .TooClose:
		return "Too close to another town"
	case .NotCombat:
		return "Not a combat building"
	case .NotUnlocked:
		return "Not unlocked"
	}
	return ""
}

UIDrawCommandHint :: proc(w: ^World, ui: ^UIState, camera: rl.Camera2D) {
	if ui.command == .Inspect do return

	mouse := rl.GetMousePosition()
	attackRect, defendRect, foundRect, fuseRect := UICommandBarRects()
	buildRect := UIBuildButtonRect()
	if rl.CheckCollisionPointRec(mouse, attackRect) ||
		rl.CheckCollisionPointRec(mouse, defendRect) ||
		rl.CheckCollisionPointRec(mouse, foundRect) ||
		rl.CheckCollisionPointRec(mouse, fuseRect) {
		return
	}
	if UIBuildButtonVisible(w, ui) && rl.CheckCollisionPointRec(mouse, buildRect) do return
	if ui.command == .Build {
		palette, _, count := UIBuildPaletteRects(w, ui.buildKingdom, ui.buildTown)
		for index in 0..<count {
			if rl.CheckCollisionPointRec(mouse, palette[index]) do return
		}
	}

	label: cstring
	switch ui.command {
	case .Attack:
		label = "Click a building of an enemy town  -  Esc to cancel"
	case .Defend:
		label = "Click a building of a non-enemy town  -  Esc to cancel"
	case .Found:
		kingdom, town := UISelectionTown(w, ui.selection)
		cost: f32 = 0
		if WorldTownExists(w, kingdom, town) {
			cost = TownFoundingWoodCost(w, kingdom)
		}
		label = fmt.ctprintf(
			"Click land to found a town  -  %d wood  -  Esc to cancel",
			int(cost),
		)
		if tileX, tileY, ok := UITileAtMouse(w, camera, mouse); ok {
			failure := TownFoundingFailure(w, kingdom, town, tileX, tileY)
			if failure != .None do label = UIPlacementFailureText(failure)
		}
	case .Fuse:
		kingdom, town := UISelectionTown(w, ui.selection)
		cost: f32 = 0
		if WorldTownExists(w, kingdom, town) {
			cost = TownFusionCost(w, kingdom, town)
		}
		label = fmt.ctprintf(
			"Click an adjacent era 5 town  -  %d wood  -  Esc to cancel",
			int(cost),
		)
		targetKingdom, targetTown, _, found := UIFindTownAt(w, camera, mouse)
		if found {
			failure := TownFusionFailure(w, kingdom, town, targetKingdom, targetTown)
			if failure != .None do label = TownFusionFailureText(failure)
		}
	case .Build:
		label = "Choose a combat building  -  Esc to cancel"
	case .Place:
		label = fmt.ctprintf("Place %s  -  right click to stop", UIBuildingName(ui.buildKind))
		if tileX, tileY, ok := UITileAtMouse(w, camera, mouse); ok {
			failure := TownCombatConstructionFailure(
				w,
				ui.buildKingdom,
				ui.buildTown,
				ui.buildKind,
				tileX,
				tileY,
			)
			if failure != .None do label = UIPlacementFailureText(failure)
		}
	case .Inspect:
		return
	}

	font := UIFont()
	textWidth := rl.MeasureTextEx(font, label, UI_TEXT_SIZE, 1).x
	box := rl.Rectangle{
		clamp(mouse.x+18, 0, f32(rl.GetScreenWidth())-textWidth-2*UI_PAD),
		clamp(mouse.y+18, 0, f32(rl.GetScreenHeight())-UI_TEXT_SIZE-2*UI_PAD),
		textWidth+2*UI_PAD,
		UI_TEXT_SIZE+2*UI_PAD,
	}
	rl.DrawRectangleRec(box, UI_COLOR_BG)
	rl.DrawRectangleLinesEx(box, 1, UI_COLOR_BORDER)
	UIText(label, box.x+UI_PAD, box.y+UI_PAD-2, UI_COLOR_TEXT)
}

UIDrawBuildButton :: proc(w: ^World, ui: ^UIState) {
	if WorldLocalKingdom(w) < 0 do return
	if !UIBuildButtonVisible(w, ui) do return
	active := ui.command == .Build || ui.command == .Place
	UIDrawCommandIcon(UIBuildButtonRect(), .Build, UIBuildButtonEnabled(w, ui), active)
}

UIDrawBuildPalette :: proc(w: ^World, renderer: ^WorldRenderer, ui: ^UIState) {
	if ui.command != .Build do return
	rects, kinds, count := UIBuildPaletteRects(w, ui.buildKingdom, ui.buildTown)
	if count == 0 do return

	mouse := rl.GetMousePosition()
	for index in 0..<count {
		rect := rects[index]
		kind := kinds[index]
		hovered := rl.CheckCollisionPointRec(mouse, rect)
		background := UI_COLOR_BUTTON
		if hovered do background = UI_COLOR_BUTTON_HOVER
		rl.DrawRectangleRec(rect, background)
		rl.DrawRectangleLinesEx(rect, 1, hovered ? UI_COLOR_BUILD : UI_COLOR_BORDER_INNER)

		texture := renderer.sprites.building[FactionSpriteIndex(ui.buildKingdom)][kind]
		if texture.id != 0 {
			source := rl.Rectangle{0, 0, f32(texture.width), f32(texture.height)}
			rl.DrawTexturePro(texture, source, rl.Rectangle{rect.x+8, rect.y+12, 30, 30}, rl.Vector2{0, 0}, 0, rl.WHITE)
		}
		UIText(UIBuildingName(kind), rect.x+44, rect.y+8, UI_COLOR_TEXT)
	}
}

UIDrawBuildPreview :: proc(w: ^World, renderer: ^WorldRenderer, camera: rl.Camera2D, ui: ^UIState) {
	if ui.command != .Place do return
	tileX, tileY, ok := UITileAtMouse(w, camera, rl.GetMousePosition())
	if !ok do return

	kingdom := ui.buildKingdom
	town := ui.buildTown

	width, height := BuildingTileSize(BuildingTypeFromKind(ui.buildKind))
	valid := TownCombatConstructionFailure(w, kingdom, town, ui.buildKind, tileX, tileY) == .None
	color := rl.Color{110, 218, 128, 220}
	if !valid do color = rl.Color{228, 92, 82, 220}

	rl.BeginMode2D(camera)
	rect := rl.Rectangle{f32(tileX), f32(tileY), f32(width), f32(height)}
	rl.DrawRectangleRec(rect, rl.Color{color[0], color[1], color[2], 48})
	rl.DrawRectangleLinesEx(rect, 2/camera.zoom, color)

	texture := renderer.sprites.building[FactionSpriteIndex(kingdom)][ui.buildKind]
	if texture.id != 0 {
		source := rl.Rectangle{0, 0, f32(texture.width), f32(texture.height)}
		alpha := valid ? u8(150) : u8(80)
		rl.DrawTexturePro(texture, source, rect, rl.Vector2{0, 0}, 0, rl.Color{255, 255, 255, alpha})
	}
	rl.EndMode2D()
}

UIDrawFoundPreview :: proc(w: ^World, renderer: ^WorldRenderer, camera: rl.Camera2D, ui: ^UIState) {
	if ui.command != .Found do return
	kingdom, town := UISelectionTown(w, ui.selection)
	if !WorldTownExists(w, kingdom, town) do return

	tileX, tileY, ok := UITileAtMouse(w, camera, rl.GetMousePosition())
	if !ok do return
	width, height := BuildingTileSize(TownHall{})
	valid := TownFoundingFailure(w, kingdom, town, tileX, tileY) == .None
	color := rl.Color{110, 218, 128, 220}
	if !valid do color = rl.Color{228, 92, 82, 220}

	rl.BeginMode2D(camera)
	rect := rl.Rectangle{f32(tileX), f32(tileY), f32(width), f32(height)}
	rl.DrawRectangleRec(rect, rl.Color{color[0], color[1], color[2], 48})
	rl.DrawRectangleLinesEx(rect, 2/camera.zoom, color)

	texture := renderer.sprites.building[FactionSpriteIndex(kingdom)][.TownHall]
	if texture.id != 0 {
		source := rl.Rectangle{0, 0, f32(texture.width), f32(texture.height)}
		alpha := valid ? u8(150) : u8(80)
		rl.DrawTexturePro(texture, source, rect, rl.Vector2{0, 0}, 0, rl.Color{255, 255, 255, alpha})
	}
	rl.EndMode2D()
}

UIDrawMilestone :: proc(w: ^World, renderer: ^WorldRenderer, kingdom, town: int) {
	if !WorldTownExists(w, kingdom, town) do return
	t := &w.kingdoms[kingdom].towns[town]

	rl.DrawRectangleRec(
		rl.Rectangle{0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())},
		rl.Color{0, 0, 0, 150},
	)

	modal := UIMilestoneRect()
	rl.DrawRectangleRec(modal, UI_COLOR_BG)
	rl.DrawRectangleLinesEx(modal, 2, UI_COLOR_BORDER)
	rl.DrawRectangleLinesEx(
		rl.Rectangle{modal.x+3, modal.y+3, modal.width-6, modal.height-6},
		1,
		UI_COLOR_BORDER_INNER,
	)

	head := rl.Rectangle{modal.x+3, modal.y+3, modal.width-6, 72}
	rl.DrawRectangleRec(head, UI_COLOR_HEADER)
	rl.DrawRectangleRec(rl.Rectangle{modal.x+3, modal.y+3, 4, 72}, FactionColor(w, kingdom))
	rl.DrawRectangleRec(
		rl.Rectangle{modal.x+3, modal.y+74, modal.width-6, 1},
		UI_COLOR_BORDER_INNER,
	)

	UITitle("Town Milestone", modal.x+UI_PAD, modal.y+10, UI_COLOR_GOLD)
	UIText(
		fmt.ctprintf(
			"%s  -  %s  -  %d citizens  -  reward %d of %d",
			NameKingdomCString(w, kingdom),
			NameTownCString(w, kingdom, town),
			t.citizens,
			t.milestonesChosen+1,
			TOWN_MILESTONE_TIER_COUNT,
		),
		modal.x+UI_PAD,
		modal.y+46,
		UI_COLOR_DIM,
	)

	mouse := rl.GetMousePosition()

	sharedUnits, sharedUnlocks, hasShared := UIMilestoneSharedRewards(w, kingdom, town)
	if hasShared {
		band := rl.Rectangle{
			modal.x+UI_PAD,
			modal.y+82,
			modal.width-2*UI_PAD,
			UI_MILESTONE_SHARED_H-8,
		}
		rl.DrawRectangleRec(band, UI_COLOR_BUTTON_OFF)
		rl.DrawRectangleLinesEx(band, 1, UI_COLOR_BORDER_INNER)

		title: cstring = "Both paths"
		titleWidth := UIHudTextWidth(title)
		UIText(title, modal.x+(modal.width-titleWidth)*0.5, band.y+5, UI_COLOR_GOLD)

		totalWidth: f32 = 0
		for kind in UnitKind {
			if !(kind in sharedUnits) do continue
			if totalWidth > 0 do totalWidth += 16
			totalWidth += 24+8+UIHudTextWidth(UIUnitName(kind))
		}
		for kind in BuildingKind {
			if !(kind in sharedUnlocks) do continue
			if totalWidth > 0 do totalWidth += 16
			totalWidth += 24+8+UIHudTextWidth(UIBuildingName(kind))
		}

		itemX := modal.x+(modal.width-totalWidth)*0.5
		itemY := band.y+28
		for kind in UnitKind {
			if !(kind in sharedUnits) do continue
			texture := renderer.sprites.unit[FactionSpriteIndex(kingdom)][kind]
			if texture.id != 0 {
				source := rl.Rectangle{0, 0, f32(texture.width), f32(texture.height)}
				rl.DrawTexturePro(texture, source, rl.Rectangle{itemX, itemY, 24, 24}, rl.Vector2{0, 0}, 0, rl.WHITE)
			}
			UIText(UIUnitName(kind), itemX+32, itemY+2, UI_COLOR_TEXT)
			itemX += 24+8+UIHudTextWidth(UIUnitName(kind))+16
		}
		for kind in BuildingKind {
			if !(kind in sharedUnlocks) do continue
			texture := renderer.sprites.building[FactionSpriteIndex(kingdom)][kind]
			if texture.id != 0 {
				source := rl.Rectangle{0, 0, f32(texture.width), f32(texture.height)}
				rl.DrawTexturePro(texture, source, rl.Rectangle{itemX, itemY, 24, 24}, rl.Vector2{0, 0}, 0, rl.WHITE)
			}
			UIText(UIBuildingName(kind), itemX+32, itemY+2, UI_COLOR_TEXT)
			itemX += 24+8+UIHudTextWidth(UIBuildingName(kind))+16
		}
	}

	cards := UIMilestoneCardRects(w, kingdom, town, modal)
	for card, optionIndex in cards {
		hovered := rl.CheckCollisionPointRec(mouse, card)
		background := hovered ? UI_COLOR_BUTTON_HOVER : UI_COLOR_BUTTON
		rl.DrawRectangleRec(card, background)
		rl.DrawRectangleLinesEx(card, 1, hovered ? UI_COLOR_GOLD : UI_COLOR_BORDER_INNER)

		option, ok := TownMilestoneOption(w, kingdom, town, optionIndex)
		if !ok do continue

		UITitle(UITownPathName(option.path), card.x+UI_PAD, card.y+8, UI_COLOR_GOLD)
		row := 0
		for kind in UnitKind {
			if !(kind in option.units) || (kind in sharedUnits) do continue
			rowY := card.y+42+f32(row)*28
			texture := renderer.sprites.unit[FactionSpriteIndex(kingdom)][kind]
			if texture.id != 0 {
				icon := rl.Rectangle{card.x+UI_PAD, rowY+2, 24, 24}
				source := rl.Rectangle{0, 0, f32(texture.width), f32(texture.height)}
				rl.DrawTexturePro(texture, source, icon, rl.Vector2{0, 0}, 0, rl.WHITE)
			}
			UIText(UIUnitName(kind), card.x+UI_PAD+32, rowY+2, UI_COLOR_TEXT)
			row += 1
		}
		for kind in BuildingKind {
			if !(kind in option.unlocks) || (kind in sharedUnlocks) do continue
			rowY := card.y+42+f32(row)*28
			texture := renderer.sprites.building[FactionSpriteIndex(kingdom)][kind]
			if texture.id != 0 {
				icon := rl.Rectangle{card.x+UI_PAD, rowY+2, 24, 24}
				source := rl.Rectangle{0, 0, f32(texture.width), f32(texture.height)}
				rl.DrawTexturePro(texture, source, icon, rl.Vector2{0, 0}, 0, rl.WHITE)
			}
			UIText(UIBuildingName(kind), card.x+UI_PAD+32, rowY+2, UI_COLOR_TEXT)
			row += 1
		}
		UIText("Click to choose", card.x+UI_PAD, card.y+card.height-26, UI_COLOR_DIM)
	}
}

UIButton :: proc(rect: rl.Rectangle, label: cstring, enabled: bool) {
	hovered := enabled && rl.CheckCollisionPointRec(rl.GetMousePosition(), rect)
	background := UI_COLOR_BUTTON
	if !enabled {
		background = UI_COLOR_BUTTON_OFF
	} else if hovered {
		background = UI_COLOR_BUTTON_HOVER
	}
	rl.DrawRectangleRec(rect, background)
	rl.DrawRectangleLinesEx(rect, 1, UI_COLOR_BORDER_INNER)

	color := UI_COLOR_TEXT
	if !enabled do color = UI_COLOR_DISABLED_TEXT
	width := rl.MeasureTextEx(UIFont(), label, UI_TEXT_SIZE, 1).x
	rl.DrawTextEx(
		UIFont(),
		label,
		rl.Vector2{rect.x+(rect.width-width)*0.5, rect.y+(rect.height-UI_TEXT_SIZE)*0.5+1},
		UI_TEXT_SIZE,
		1,
		color,
	)
}

// --- kingdom HUD, town list, diplomacy, alerts -----------------------------

UI_HUD_PAD :: 12
UI_HUD_GAP :: 20
UI_HUD_BUTTON_H :: 28
UI_HUD_BUTTON_PAD :: 14
UI_SIDE_PANEL_W :: 420
UI_SIDE_ROW_H :: 30
UI_SIDE_HEADER_H :: 36
UI_SIDE_MAX_TOWN_ROWS :: 10
UI_DIPLO_ROW_H :: 48
UI_ALERT_W :: 380
UI_ALERT_ROW_H :: 30
UI_ALERT_MAX_ROWS :: 6

UIHudTextWidth :: proc(text: cstring) -> f32 {
	return rl.MeasureTextEx(UIFont(), text, UI_TEXT_SIZE, 1).x
}

UIHudLineHeight :: proc() -> f32 {
	return rl.MeasureTextEx(UIFont(), "Ag", UI_TEXT_SIZE, 1).y
}

UIHudTimeLabel :: proc(w: ^World) -> cstring {
	return fmt.ctprintf("Day %d  %02dh", w.dayNumber+1, int(WorldTimeOfDay(w)))
}

UIHudRect :: proc(w: ^World) -> rl.Rectangle {
	local := WorldLocalKingdom(w)
	name := local >= 0 ? NameKingdomCString(w, local) : cstring("SPECTATOR")
	nameWidth := UIHudTextWidth(name)
	timeWidth := UIHudTextWidth(UIHudTimeLabel(w))
	lineWidth := max(nameWidth, timeWidth)

	townsWidth := UIHudTextWidth("TOWNS")+2*UI_HUD_BUTTON_PAD
	diplomacyWidth := UIHudTextWidth("DIPLOMACY")+2*UI_HUD_BUTTON_PAD
	buttonsWidth := townsWidth+8+diplomacyWidth

	height := max(UIHudLineHeight()*2, UI_HUD_BUTTON_H)+2*UI_HUD_PAD
	width := UI_HUD_PAD*2+lineWidth+UI_HUD_GAP+buttonsWidth
	return rl.Rectangle{
		max(UI_MARGIN, f32(rl.GetScreenWidth())-UI_MARGIN-width),
		UI_MARGIN,
		width,
		height,
	}
}

UIHudTownsButtonRect :: proc(w: ^World) -> rl.Rectangle {
	hud := UIHudRect(w)
	diplomacyWidth := UIHudTextWidth("DIPLOMACY")+2*UI_HUD_BUTTON_PAD
	townsWidth := UIHudTextWidth("TOWNS")+2*UI_HUD_BUTTON_PAD
	return rl.Rectangle{
		hud.x+hud.width-UI_HUD_PAD-diplomacyWidth-8-townsWidth,
		hud.y+(hud.height-UI_HUD_BUTTON_H)*0.5,
		townsWidth,
		UI_HUD_BUTTON_H,
	}
}

UIHudDiplomacyButtonRect :: proc(w: ^World) -> rl.Rectangle {
	towns := UIHudTownsButtonRect(w)
	return rl.Rectangle{
		towns.x+towns.width+8,
		towns.y,
		UIHudTextWidth("DIPLOMACY")+2*UI_HUD_BUTTON_PAD,
		UI_HUD_BUTTON_H,
	}
}

UIPlayerTownCount :: proc(w: ^World) -> int {
	local := WorldLocalKingdom(w)
	if local < 0 do return 0
	count := 0
	for townSlot in 0..<TOWN_CAPACITY {
		if w.kingdoms[local].townUsed[townSlot] do count += 1
	}
	return count
}

UIPlayerTownAt :: proc(w: ^World, index: int) -> (int, bool) {
	local := WorldLocalKingdom(w)
	if index < 0 || local < 0 do return -1, false
	seen := 0
	for townSlot in 0..<TOWN_CAPACITY {
		if !w.kingdoms[local].townUsed[townSlot] do continue
		if seen == index do return townSlot, true
		seen += 1
	}
	return -1, false
}

UIDiplomacyCount :: proc(w: ^World) -> int {
	count := 0
	local := WorldLocalKingdom(w)
	if local < 0 do return 0
	for kingdomSlot in 0..<KINGDOMS_CAPACITY {
		if kingdomSlot == local || !KingdomDiscovered(w, kingdomSlot) do continue
		count += 1
	}
	return count
}

UIDiplomacyAt :: proc(w: ^World, index: int) -> (int, bool) {
	if index < 0 do return -1, false
	local := WorldLocalKingdom(w)
	if local < 0 do return -1, false
	seen := 0
	for kingdomSlot in 0..<KINGDOMS_CAPACITY {
		if kingdomSlot == local || !KingdomDiscovered(w, kingdomSlot) do continue
		if seen == index do return kingdomSlot, true
		seen += 1
	}
	return -1, false
}

UISidePanelRect :: proc(w: ^World, ui: ^UIState) -> rl.Rectangle {
	if ui.panel == .None do return {}
	rows := 1
	switch ui.panel {
	case .Towns:
		rows = min(max(UIPlayerTownCount(w), 1), UI_SIDE_MAX_TOWN_ROWS)
	case .Diplomacy:
		rows = max(UIDiplomacyCount(w), 1)
	case .None:
	}
	rowHeight: f32 = UI_SIDE_ROW_H
	if ui.panel == .Diplomacy do rowHeight = UI_DIPLO_ROW_H
	height := UI_SIDE_HEADER_H+f32(rows)*rowHeight+12
	if ui.panel == .Towns && UIPlayerTownCount(w) > UI_SIDE_MAX_TOWN_ROWS do height += 30
	return rl.Rectangle{UI_MARGIN, UI_MARGIN, UI_SIDE_PANEL_W, height}
}

UIAlertPanelRect :: proc(w: ^World) -> rl.Rectangle {
	rows := min(w.alerts.count, UI_ALERT_MAX_ROWS)
	if rows <= 0 do return {}
	height := UI_SIDE_HEADER_H+f32(rows)*UI_ALERT_ROW_H+8
	hud := UIHudRect(w)
	return rl.Rectangle{
		f32(rl.GetScreenWidth())-UI_MARGIN-UI_ALERT_W,
		hud.y+hud.height+8,
		UI_ALERT_W,
		height,
	}
}

UITownPageButtonRects :: proc(panel: rl.Rectangle) -> (prev, next: rl.Rectangle) {
	y := panel.y+panel.height-27
	prev = rl.Rectangle{panel.x+UI_PAD, y, 64, 22}
	next = rl.Rectangle{panel.x+panel.width-UI_PAD-64, y, 64, 22}
	return
}

UIDiplomacyActionRect :: proc(panel: rl.Rectangle, row: int) -> rl.Rectangle {
	return rl.Rectangle{
		panel.x+panel.width-UI_PAD-128,
		panel.y+UI_SIDE_HEADER_H+f32(row)*UI_DIPLO_ROW_H+11,
		128,
		26,
	}
}

UITownUnderAttack :: proc(w: ^World, kingdom, town: int) -> bool {
	if !WorldTownExists(w, kingdom, town) do return false
	orders := &w.kingdoms[kingdom].towns[town]
	for attackerKingdom in 0..<KINGDOMS_CAPACITY {
		for attackerTown in 0..<TOWN_CAPACITY {
			if orders.attackedBy[attackerKingdom][attackerTown] do return true
		}
	}
	return false
}

UIFocusTown :: proc(w: ^World, view: ^WorldView, kingdomSlot, townSlot: int) {
	hall := TownHallSlot(w, kingdomSlot, townSlot)
	if hall < 0 do return
	width, height := BuildingTileSize(w.buildings[hall].type)
	view.camera.target = rl.Vector2{
		f32(w.buildings[hall].x)+f32(width)*0.5,
		f32(w.buildings[hall].y)+f32(height)*0.5,
	}
	view.ui.command = .Inspect
	view.ui.hover = {}
	view.ui.selection = {}
	if FogTownVisible(w, kingdomSlot, townSlot) {
		view.ui.selection = Selection{kind = .Building, slot = hall}
	}
}

UIFocusAlert :: proc(w: ^World, view: ^WorldView, alert: Alert) {
	if alert.town >= 0 && WorldTownExists(w, alert.kingdom, alert.town) {
		UIFocusTown(w, view, alert.kingdom, alert.town)
		return
	}
	view.ui.command = .Inspect
	view.ui.hover = {}
	if alert.x != 0 || alert.y != 0 {
		view.camera.target = rl.Vector2{alert.x+0.5, alert.y+0.5}
		return
	}
	if alert.other >= 0 {
		if town, found := FogFirstDiscoveredTown(w, alert.other); found {
			UIFocusTown(w, view, alert.other, town)
			return
		}
	}
}

UIAlertTownName :: proc(name: ^Name) -> cstring {
	if name[0] == 0 do return "Unknown"
	return cstring(&name[0])
}

UIAlertText :: proc(w: ^World, alert: ^Alert) -> cstring {
	switch alert.kind {
	case .TownFounded:
		return fmt.ctprintf("%s founded", UIAlertTownName(&alert.townName))
	case .TownLost:
		return fmt.ctprintf("%s lost", UIAlertTownName(&alert.townName))
	case .UnderAttack:
		return fmt.ctprintf("%s under attack", UIAlertTownName(&alert.townName))
	case .EnemySpotted:
		return fmt.ctprintf("Enemy spotted: %s", NameKingdomCString(w, alert.other))
	case .Milestone:
		return fmt.ctprintf("%s milestone ready", UIAlertTownName(&alert.townName))
	case .WarDeclared:
		return fmt.ctprintf("War declared on %s", NameKingdomCString(w, alert.other))
	case .PeaceMade:
		return fmt.ctprintf("Peace with %s", NameKingdomCString(w, alert.other))
	case .TownGrowth:
		if alert.amount == 1 {
			return fmt.ctprintf("%s +%d villager", UIAlertTownName(&alert.townName), alert.amount)
		}
		return fmt.ctprintf("%s +%d villagers", UIAlertTownName(&alert.townName), alert.amount)
	case .TownFused:
		return fmt.ctprintf(
			"%s fused into %s",
			UIAlertTownName(&alert.otherName),
			UIAlertTownName(&alert.townName),
		)
	}
	return ""
}

UIAlertColor :: proc(kind: AlertKind) -> rl.Color {
	switch kind {
	case .TownFounded:
		return rl.Color{112, 200, 126, 255}
	case .TownLost, .UnderAttack, .WarDeclared, .EnemySpotted:
		return UI_COLOR_ATTACK
	case .Milestone, .TownFused:
		return UI_COLOR_GOLD
	case .TownGrowth:
		return UI_COLOR_GOOD
	case .PeaceMade:
		return UI_COLOR_DEFEND
	}
	return UI_COLOR_TEXT
}

UIHudUpdate :: proc(w: ^World, view: ^WorldView, mouse: rl.Vector2) -> bool {
	ui := &view.ui
	ui.hover = {}

	local := WorldLocalKingdom(w)
	if local < 0 do return false

	if rl.IsKeyPressed(.ESCAPE) && ui.panel != .None {
		ui.panel = .None
		return true
	}

	if rl.CheckCollisionPointRec(mouse, UIHudRect(w)) {
		if rl.IsMouseButtonPressed(.LEFT) {
			if rl.CheckCollisionPointRec(mouse, UIHudTownsButtonRect(w)) {
				if ui.panel == .Towns { ui.panel = .None } else { ui.panel = .Towns }
				ui.townScroll = 0
			} else if rl.CheckCollisionPointRec(mouse, UIHudDiplomacyButtonRect(w)) {
				if ui.panel == .Diplomacy { ui.panel = .None } else { ui.panel = .Diplomacy }
			}
		}
		return true
	}

	if ui.panel != .None {
		panel := UISidePanelRect(w, ui)
		if rl.CheckCollisionPointRec(mouse, panel) {
			switch ui.panel {
			case .Towns:
				count := UIPlayerTownCount(w)
				maxScroll := max(count-UI_SIDE_MAX_TOWN_ROWS, 0)
				ui.townScroll = clamp(ui.townScroll, 0, maxScroll)

				if rl.IsMouseButtonPressed(.LEFT) && count > UI_SIDE_MAX_TOWN_ROWS {
					prev, next := UITownPageButtonRects(panel)
					if rl.CheckCollisionPointRec(mouse, prev) && ui.townScroll > 0 {
						ui.townScroll = max(ui.townScroll-UI_SIDE_MAX_TOWN_ROWS, 0)
						return true
					}
					if rl.CheckCollisionPointRec(mouse, next) && ui.townScroll < maxScroll {
						ui.townScroll = min(ui.townScroll+UI_SIDE_MAX_TOWN_ROWS, maxScroll)
						return true
					}
				}

				if rl.IsMouseButtonPressed(.LEFT) {
					row := int((mouse.y-(panel.y+UI_SIDE_HEADER_H))/UI_SIDE_ROW_H)
					if row >= 0 && row < min(count, UI_SIDE_MAX_TOWN_ROWS) {
						if townSlot, found := UIPlayerTownAt(w, ui.townScroll+row); found {
							UIFocusTown(w, view, local, townSlot)
						}
					}
				}
			case .Diplomacy:
				if rl.IsMouseButtonPressed(.LEFT) {
					row := int((mouse.y-(panel.y+UI_SIDE_HEADER_H))/UI_DIPLO_ROW_H)
					if row >= 0 && row < UIDiplomacyCount(w) {
						if kingdomSlot, found := UIDiplomacyAt(w, row); found {
							if rl.CheckCollisionPointRec(mouse, UIDiplomacyActionRect(panel, row)) {
								if KingdomAtWar(w, local, kingdomSlot) {
									KingdomIssueCommand(w, local, CommandMakePeace{other = kingdomSlot})
								} else {
									KingdomIssueCommand(w, local, CommandDeclareWar{other = kingdomSlot})
								}
							} else if townSlot, townFound := FogFirstDiscoveredTown(w, kingdomSlot); townFound {
								UIFocusTown(w, view, kingdomSlot, townSlot)
							}
						}
					}
				}
			case .None:
			}
			return true
		}
	}

	if w.alerts.count > 0 {
		panel := UIAlertPanelRect(w)
		if rl.CheckCollisionPointRec(mouse, panel) {
			row := int((mouse.y-(panel.y+UI_SIDE_HEADER_H))/UI_ALERT_ROW_H)
			validRow := row >= 0 && row < min(w.alerts.count, UI_ALERT_MAX_ROWS)
			if rl.IsMouseButtonPressed(.RIGHT) {
				if validRow do WorldAlertDismiss(w, row)
				return true
			}
			if rl.IsMouseButtonPressed(.LEFT) && validRow {
				if alert, found := WorldAlertNewest(w, row); found {
					UIFocusAlert(w, view, alert)
				}
			}
			return true
		}
	}

	return false
}

UIDrawHud :: proc(w: ^World, ui: ^UIState) {
	hud := UIHudRect(w)
	rl.DrawRectangleRec(hud, UI_COLOR_BG)
	rl.DrawRectangleLinesEx(hud, 2, UI_COLOR_BORDER)
	rl.DrawRectangleLinesEx(
		rl.Rectangle{hud.x+3, hud.y+3, hud.width-6, hud.height-6},
		1,
		UI_COLOR_BORDER_INNER,
	)

	local := WorldLocalKingdom(w)
	if local < 0 {
		rl.DrawRectangleRec(rl.Rectangle{hud.x+3, hud.y+3, 4, hud.height-6}, UI_COLOR_DIM)
		lineHeight := UIHudLineHeight()
		titleY := hud.y+UI_HUD_PAD
		detailY := titleY+lineHeight
		UIText("SPECTATING", hud.x+UI_HUD_PAD, titleY, UI_COLOR_GOLD)
		UIText("ESC  PAUSE", hud.x+UI_HUD_PAD, detailY, UI_COLOR_DIM)
		winner := w.winnerKingdom
		if winner >= 0 && w.kingdomUsed[winner] {
			UIText(
				NameKingdomCString(w, winner),
				hud.x+UI_HUD_PAD+120,
				detailY,
				FactionColor(w, winner),
			)
		}
		return
	}

	rl.DrawRectangleRec(
		rl.Rectangle{hud.x+3, hud.y+3, 4, hud.height-6},
		FactionColor(w, local),
	)

	lineHeight := UIHudLineHeight()
	textX := hud.x+UI_HUD_PAD
	titleY := hud.y+UI_HUD_PAD
	detailY := titleY+lineHeight

	UIText(NameKingdomCString(w, local), textX, titleY, UI_COLOR_GOLD)

	timeLabel := UIHudTimeLabel(w)
	UIText(timeLabel, textX, detailY, UI_COLOR_DIM)

	townsRect := UIHudTownsButtonRect(w)
	diplomacyRect := UIHudDiplomacyButtonRect(w)
	UIButton(townsRect, "TOWNS", true)
	UIButton(diplomacyRect, "DIPLOMACY", true)
	if ui.panel == .Towns {
		rl.DrawRectangleLinesEx(townsRect, 2, UI_COLOR_GOLD)
	}
	if ui.panel == .Diplomacy {
		rl.DrawRectangleLinesEx(diplomacyRect, 2, UI_COLOR_GOLD)
	}
}

UIDrawSidePanel :: proc(w: ^World, ui: ^UIState) {
	if ui.panel == .None do return
	local := WorldLocalKingdom(w)
	if local < 0 do return
	panel := UISidePanelRect(w, ui)
	rl.DrawRectangleRec(panel, UI_COLOR_BG)
	rl.DrawRectangleLinesEx(panel, 2, UI_COLOR_BORDER)
	rl.DrawRectangleLinesEx(
		rl.Rectangle{panel.x+3, panel.y+3, panel.width-6, panel.height-6},
		1,
		UI_COLOR_BORDER_INNER,
	)

	switch ui.panel {
	case .Towns:
		UIText("YOUR TOWNS", panel.x+UI_PAD, panel.y+9, UI_COLOR_GOLD)
		count := UIPlayerTownCount(w)
		if count == 0 {
			UIText("No towns yet.", panel.x+UI_PAD, panel.y+UI_SIDE_HEADER_H+6, UI_COLOR_DIM)
			return
		}
		visible := min(count, UI_SIDE_MAX_TOWN_ROWS)
		for row in 0..<visible {
			townSlot, found := UIPlayerTownAt(w, ui.townScroll+row)
			if !found do continue
			rowRect := rl.Rectangle{
				panel.x+8,
				panel.y+UI_SIDE_HEADER_H+f32(row)*UI_SIDE_ROW_H,
				panel.width-16,
				UI_SIDE_ROW_H-2,
			}
			hovered := rl.CheckCollisionPointRec(rl.GetMousePosition(), rowRect)
			if hovered do rl.DrawRectangleRec(rowRect, UI_COLOR_BUTTON_HOVER)
			UIText(NameTownCString(w, local, townSlot), rowRect.x+6, rowRect.y+4, UI_COLOR_TEXT)
			if UITownUnderAttack(w, local, townSlot) {
				UIText("!", rowRect.x+rowRect.width-16, rowRect.y+4, UI_COLOR_ATTACK)
			}
		}
		if count > UI_SIDE_MAX_TOWN_ROWS {
			prev, next := UITownPageButtonRects(panel)
			UIButton(prev, "PREV", ui.townScroll > 0)
			UIButton(next, "NEXT", ui.townScroll+UI_SIDE_MAX_TOWN_ROWS < count)
		}
	case .Diplomacy:
		UIText("DIPLOMACY", panel.x+UI_PAD, panel.y+9, UI_COLOR_GOLD)
		count := UIDiplomacyCount(w)
		if count == 0 {
			UIText("No kingdoms discovered.", panel.x+UI_PAD, panel.y+UI_SIDE_HEADER_H+6, UI_COLOR_DIM)
			return
		}
		for row in 0..<count {
			kingdomSlot, found := UIDiplomacyAt(w, row)
			if !found do continue
			rowRect := rl.Rectangle{
				panel.x+8,
				panel.y+UI_SIDE_HEADER_H+f32(row)*UI_DIPLO_ROW_H,
				panel.width-16,
				UI_DIPLO_ROW_H-2,
			}
			hovered := rl.CheckCollisionPointRec(rl.GetMousePosition(), rowRect)
			if hovered do rl.DrawRectangleRec(rowRect, UI_COLOR_BUTTON_HOVER)
			rl.DrawRectangleRec(
				rl.Rectangle{rowRect.x+6, rowRect.y+8, 10, 24},
				FactionColor(w, kingdomSlot),
			)
			UIText(NameKingdomCString(w, kingdomSlot), rowRect.x+24, rowRect.y+4, UI_COLOR_TEXT)
			atWar := KingdomAtWar(w, local, kingdomSlot)
			UIText(
				atWar ? "AT WAR" : "Peace",
				rowRect.x+24,
				rowRect.y+24,
				atWar ? UI_COLOR_ATTACK : UI_COLOR_DIM,
			)
			action := UIDiplomacyActionRect(panel, row)
			UIButton(action, atWar ? "Make Peace" : "Declare War", true)
		}
	case .None:
	}
}

UIDrawAlerts :: proc(w: ^World) {
	if w.alerts.count == 0 do return
	panel := UIAlertPanelRect(w)
	rl.DrawRectangleRec(panel, UI_COLOR_BG)
	rl.DrawRectangleLinesEx(panel, 2, UI_COLOR_BORDER)
	rl.DrawRectangleLinesEx(
		rl.Rectangle{panel.x+3, panel.y+3, panel.width-6, panel.height-6},
		1,
		UI_COLOR_BORDER_INNER,
	)
	UIText("ALERTS", panel.x+UI_PAD, panel.y+9, UI_COLOR_GOLD)

	rows := min(w.alerts.count, UI_ALERT_MAX_ROWS)
	for row in 0..<rows {
		alert, found := WorldAlertNewest(w, row)
		if !found do continue
		rowRect := rl.Rectangle{
			panel.x+8,
			panel.y+UI_SIDE_HEADER_H+f32(row)*UI_ALERT_ROW_H,
			panel.width-16,
			UI_ALERT_ROW_H-2,
		}
		if rl.CheckCollisionPointRec(rl.GetMousePosition(), rowRect) {
			rl.DrawRectangleRec(rowRect, UI_COLOR_BUTTON_HOVER)
		}
		rl.DrawRectangleRec(
			rl.Rectangle{rowRect.x+2, rowRect.y+4, 3, rowRect.height-8},
			UIAlertColor(alert.kind),
		)
		UIText(UIAlertText(w, &alert), rowRect.x+12, rowRect.y+4, UI_COLOR_TEXT)
	}
}
