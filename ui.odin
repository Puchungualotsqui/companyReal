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
}

// Command modes arm the map for the next click. Inspect is the normal mode.
UICommand :: enum {
	Inspect,
	Attack,
	Defend,
	Found,
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
UI_BUTTON : f32 : 20
UI_TEXT_BUTTON_H : f32 : 26

UI_TOWN_TABS := [2]cstring{"TOWN", "ORDERS"}

UI_EFFECT_ROW_H : f32 : 30

UI_COMMAND_BUTTON_W : f32 : 84
UI_COMMAND_BUTTON_H : f32 : 68
UI_COMMAND_GAP : f32 : 12

UI_COLOR_ATTACK := rl.Color{226, 96, 76, 220}
UI_COLOR_DEFEND := rl.Color{106, 178, 224, 220}
UI_COLOR_BUILD := rl.Color{214, 178, 92, 220}
UI_COLOR_FOUND := rl.Color{196, 156, 226, 220}
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
}

UI_FONT_BODY_DATA :: #load("assets/fonts/PixelifySans-Regular.ttf")
UI_FONT_TITLE_DATA :: #load("assets/fonts/PixelifySans-Bold.ttf")

@(private = "file")
ui_fonts: struct {
	body, title, menu: rl.Font,
	loaded:             bool,
}

// raylib rasterizes glyphs with anti-aliasing; the UI is pixel art, so the
// atlas is thresholded to hard alpha edges before it is used. The image keeps
// its native layout because UpdateTexture reinterprets the raw bytes.
@(private = "file")
ui_font_crisp :: proc(font: ^rl.Font) {
	image := rl.LoadImageFromTexture(font.texture)
	defer rl.UnloadImage(image)
	pixels := cast([^]u8)image.data
	pixel_count := int(image.width)*int(image.height)

	#partial switch image.format {
	case .UNCOMPRESSED_GRAY_ALPHA:
		for index in 0 ..< pixel_count {
			alpha := &pixels[index*2+1]
			alpha^ = alpha^ < 128 ? 0 : 255
		}
	case .UNCOMPRESSED_GRAYSCALE:
		for index in 0 ..< pixel_count {
			value := &pixels[index]
			value^ = value^ < 128 ? 0 : 255
		}
	case .UNCOMPRESSED_R8G8B8A8:
		for index in 0 ..< pixel_count {
			alpha := &pixels[index*4+3]
			alpha^ = alpha^ < 128 ? 0 : 255
		}
	case:
		return
	}
	rl.UpdateTexture(font.texture, image.data)
}

@(private = "file")
ui_font_load :: proc(data: []u8, size: i32) -> rl.Font {
	font := rl.LoadFontFromMemory(".ttf", raw_data(data), i32(len(data)), size, nil, 0)
	if font.texture.id == 0 do return rl.GetFontDefault()
	ui_font_crisp(&font)
	rl.SetTextureFilter(font.texture, .POINT)
	return font
}

@(private = "file")
ui_font_init :: proc() {
	if ui_fonts.loaded do return
	ui_fonts.body = ui_font_load(UI_FONT_BODY_DATA, i32(UI_TEXT_SIZE))
	ui_fonts.title = ui_font_load(UI_FONT_TITLE_DATA, i32(UI_TITLE_SIZE))
	ui_fonts.menu = ui_font_load(UI_FONT_TITLE_DATA, 56)
	ui_fonts.loaded = true
}

ui_font :: proc() -> rl.Font {
	ui_font_init()
	return ui_fonts.body
}

ui_title_font :: proc() -> rl.Font {
	ui_font_init()
	return ui_fonts.title
}

ui_menu_font :: proc() -> rl.Font {
	ui_font_init()
	return ui_fonts.menu
}

WorldUIDeinit :: proc() {
	if !ui_fonts.loaded do return
	// A failed load falls back to the shared default font, which must not be freed.
	default_texture := rl.GetFontDefault().texture.id
	if ui_fonts.body.texture.id != default_texture do rl.UnloadFont(ui_fonts.body)
	if ui_fonts.title.texture.id != default_texture do rl.UnloadFont(ui_fonts.title)
	if ui_fonts.menu.texture.id != default_texture do rl.UnloadFont(ui_fonts.menu)
	ui_fonts = {}
}

ui_text :: proc(text: cstring, x, y: f32, color: rl.Color) {
	rl.DrawTextEx(ui_font(), text, rl.Vector2{x, y}, UI_TEXT_SIZE, 1, color)
}

ui_title :: proc(text: cstring, x, y: f32, color: rl.Color) {
	rl.DrawTextEx(ui_title_font(), text, rl.Vector2{x, y}, UI_TITLE_SIZE, 1, color)
}

ui_text_right :: proc(text: cstring, right, y: f32, color: rl.Color) {
	width := rl.MeasureTextEx(ui_font(), text, UI_TEXT_SIZE, 1).x
	rl.DrawTextEx(ui_font(), text, rl.Vector2{right-width, y}, UI_TEXT_SIZE, 1, color)
}

ui_text_center :: proc(text: cstring, center_x, y: f32, color: rl.Color) {
	width := rl.MeasureTextEx(ui_font(), text, UI_TEXT_SIZE, 1).x
	rl.DrawTextEx(ui_font(), text, rl.Vector2{center_x-width*0.5, y}, UI_TEXT_SIZE, 1, color)
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
	case .TownHall, .Home, .Farmland, .Wall, .Bridge, .Cannon, .Watchtower, .Path:
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

UIAttackOrderValid :: proc(w: ^World, kingdom, town, target_kingdom, target_town: int) -> bool {
	if kingdom == target_kingdom do return false
	if !WorldTownExists(w, kingdom, town) || !WorldTownExists(w, target_kingdom, target_town) {
		return false
	}
	if !FogTownDiscovered(w, target_kingdom, target_town) do return false
	if w.kingdoms[kingdom].towns[town].attackOrders[target_kingdom][target_town] {
		return false
	}
	return TownHallSlot(w, target_kingdom, target_town) >= 0
}

UIDefendOrderValid :: proc(w: ^World, kingdom, town, target_kingdom, target_town: int) -> bool {
	if kingdom == target_kingdom && town == target_town do return false
	if !WorldTownExists(w, kingdom, town) || !WorldTownExists(w, target_kingdom, target_town) {
		return false
	}
	if !FogTownDiscovered(w, target_kingdom, target_town) do return false
	if KingdomAtWar(w, kingdom, target_kingdom) do return false
	if w.kingdoms[kingdom].towns[town].defendOrders[target_kingdom][target_town] do return false
	return TownHallSlot(w, target_kingdom, target_town) >= 0
}

UIAttackTargetExists :: proc(w: ^World, kingdom, town: int) -> bool {
	for target_kingdom in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[target_kingdom] do continue
		for target_town in 0..<TOWN_CAPACITY {
			if !w.kingdoms[target_kingdom].townUsed[target_town] do continue
			if UIAttackOrderValid(w, kingdom, town, target_kingdom, target_town) do return true
		}
	}
	return false
}

UIDefendTargetExists :: proc(w: ^World, kingdom, town: int) -> bool {
	for target_kingdom in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[target_kingdom] do continue
		for target_town in 0..<TOWN_CAPACITY {
			if !w.kingdoms[target_kingdom].townUsed[target_town] do continue
			if UIDefendOrderValid(w, kingdom, town, target_kingdom, target_town) do return true
		}
	}
	return false
}

// Counts the town's outgoing attack and defend orders.
UITownOrderCount :: proc(w: ^World, kingdom, town: int) -> int {
	if !WorldTownExists(w, kingdom, town) do return 0
	orders := &w.kingdoms[kingdom].towns[town]
	count := 0
	for target_kingdom in 0..<KINGDOMS_CAPACITY {
		for target_town in 0..<TOWN_CAPACITY {
			if !orders.attackOrders[target_kingdom][target_town] do continue
			if WorldTownExists(w, target_kingdom, target_town) do count += 1
		}
	}
	for protected_kingdom in 0..<KINGDOMS_CAPACITY {
		for protected_town in 0..<TOWN_CAPACITY {
			if !orders.defendOrders[protected_kingdom][protected_town] do continue
			if !WorldTownExists(w, protected_kingdom, protected_town) do continue
			if protected_kingdom == kingdom && protected_town == town do continue
			count += 1
		}
	}
	return count
}

// Orders are listed attacks first, then defends.
UITownOrderAt :: proc(w: ^World, kingdom, town, index: int) -> (attack: bool, target_kingdom, target_town: int, ok: bool) {
	if !WorldTownExists(w, kingdom, town) do return false, -1, -1, false
	orders := &w.kingdoms[kingdom].towns[town]
	count := 0
	for other_kingdom in 0..<KINGDOMS_CAPACITY {
		for other_town in 0..<TOWN_CAPACITY {
			if !orders.attackOrders[other_kingdom][other_town] do continue
			if !WorldTownExists(w, other_kingdom, other_town) do continue
			if count == index do return true, other_kingdom, other_town, true
			count += 1
		}
	}
	for protected_kingdom in 0..<KINGDOMS_CAPACITY {
		for protected_town in 0..<TOWN_CAPACITY {
			if !orders.defendOrders[protected_kingdom][protected_town] do continue
			if !WorldTownExists(w, protected_kingdom, protected_town) do continue
			if protected_kingdom == kingdom && protected_town == town do continue
			if count == index do return false, protected_kingdom, protected_town, true
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
	for town_slot in 0..<TOWN_CAPACITY {
		if !w.kingdoms[local].townUsed[town_slot] do continue
		t := &w.kingdoms[local].towns[town_slot]
		if t.milestonePending && t.milestonesReached < TOWN_MILESTONE_COUNT {
			return local, town_slot, true
		}
	}
	return -1, -1, false
}

UIMilestoneRect :: proc() -> rl.Rectangle {
	width: f32 = 620
	height: f32 = 340
	screen_width := f32(rl.GetScreenWidth())
	screen_height := f32(rl.GetScreenHeight())
	return rl.Rectangle{(screen_width-width)*0.5, (screen_height-height)*0.5, width, height}
}

UI_MILESTONE_SHARED_H :: 64

// Rewards granted by both paths are shown once, above the two choices.
UIMilestoneSharedRewards :: proc(
	w: ^World,
	kingdom, town: int,
) -> (
	units: bit_set[UnitKind],
	unlocks: bit_set[BuildingKind],
	has_shared: bool,
) {
	option_a, ok_a := TownMilestoneOption(w, kingdom, town, 0)
	option_b, ok_b := TownMilestoneOption(w, kingdom, town, 1)
	if !ok_a || !ok_b do return

	units = option_a.units & option_b.units
	unlocks = option_a.unlocks & option_b.unlocks
	for kind in UnitKind {
		if kind in units {
			has_shared = true
			break
		}
	}
	if !has_shared {
		for kind in BuildingKind {
			if kind in unlocks {
				has_shared = true
				break
			}
		}
	}
	return
}

UIMilestoneCardRects :: proc(w: ^World, kingdom, town: int, modal: rl.Rectangle) -> [2]rl.Rectangle {
	card_width := (modal.width-3*UI_PAD)*0.5
	top := modal.y+82
	_, _, has_shared := UIMilestoneSharedRewards(w, kingdom, town)
	if has_shared do top += UI_MILESTONE_SHARED_H
	height := modal.height-(top-modal.y)-UI_PAD
	return [2]rl.Rectangle{
		{modal.x+UI_PAD, top, card_width, height},
		{modal.x+2*UI_PAD+card_width, top, card_width, height},
	}
}

// --- layout ---------------------------------------------------------------

UIConversionRows :: proc(w: ^World, selection: Selection, kinds: ^[len(UnitKind)]UnitKind) -> int {
	kingdom, town := UISelectionTown(w, selection)
	count := 0
	for kind in UI_CONVERSION_KINDS {
		if TownUnitAvailable(w, kingdom, town, kind) || TownUnitCount(w, kingdom, town, kind) > 0 ||
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
		if BuildingIsTraining(kind) do return 2
		return 1
	case .None:
		return 0
	}
	return 0
}

UIUnitEffectCount :: proc(w: ^World, unit_slot: int) -> int {
	if unit_slot < 0 || unit_slot >= UNIT_CAPACITY || !w.unitUsed[unit_slot] do return 0
	count := 0
	for effect in ALL_UNIT_EFFECTS {
		if w.units[unit_slot].effects[effect] do count += 1
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
			}
		}
		return UI_GROWTH_Y+UI_GROWTH_H+UI_PAD
	}
	height := UI_STAT_Y + f32(UIStatCount(w, ui.selection))*UI_STAT_H + UI_PAD
	if ui.selection.kind == .Unit && UIUnitEffectCount(w, ui.selection.slot) > 0 {
		height += UI_EFFECT_ROW_H
	}
	return height
}

UIPanelRect :: proc(w: ^World, ui: ^UIState) -> rl.Rectangle {
	height := UIPanelHeight(w, ui)
	screen_height := f32(rl.GetScreenHeight())
	y := max(UI_MARGIN, screen_height-height-UI_MARGIN)
	return rl.Rectangle{UI_MARGIN, y, UI_PANEL_WIDTH, height}
}

UITabRects :: proc(panel: rl.Rectangle) -> [2]rl.Rectangle {
	rects: [2]rl.Rectangle
	x := panel.x+UI_PAD
	for label, index in UI_TOWN_TABS {
		width := rl.MeasureTextEx(ui_font(), label, UI_TEXT_SIZE, 1).x+20
		rects[index] = rl.Rectangle{x, panel.y+UI_TABS_Y, width, UI_TABS_H}
		x += width+2
	}
	return rects
}

UIButtonRects :: proc(panel: rl.Rectangle, index: int) -> (minus, plus: rl.Rectangle) {
	row_y := panel.y+UI_ROWS_TOP+f32(index)*UI_ROW_HEIGHT
	plus = rl.Rectangle{panel.x+panel.width-UI_PAD-UI_BUTTON, row_y+8, UI_BUTTON, UI_BUTTON}
	minus = rl.Rectangle{plus.x-UI_BUTTON-4, plus.y, UI_BUTTON, UI_BUTTON}
	return
}

UIOrdersPanelHeight :: proc(orders: int) -> f32 {
	return UI_ROWS_TOP+UI_SECTION_HEADER+f32(max(orders, 1))*UI_ROW_HEIGHT+UI_PAD
}

UIOrderCancelRect :: proc(panel: rl.Rectangle, index: int) -> rl.Rectangle {
	row_y := panel.y+UI_ROWS_TOP+UI_SECTION_HEADER+f32(index)*UI_ROW_HEIGHT
	return rl.Rectangle{
		panel.x+panel.width-UI_PAD-72,
		row_y+(UI_ROW_HEIGHT-UI_TEXT_BUTTON_H)*0.5,
		72,
		UI_TEXT_BUTTON_H,
	}
}

UICommandBarRects :: proc() -> (attack, defend, found: rl.Rectangle) {
	total := 3*UI_COMMAND_BUTTON_W+2*UI_COMMAND_GAP
	x := (f32(rl.GetScreenWidth())-total)*0.5
	y := f32(rl.GetScreenHeight())-UI_MARGIN-UI_COMMAND_BUTTON_H
	attack = rl.Rectangle{x, y, UI_COMMAND_BUTTON_W, UI_COMMAND_BUTTON_H}
	defend = rl.Rectangle{x+UI_COMMAND_BUTTON_W+UI_COMMAND_GAP, y, UI_COMMAND_BUTTON_W, UI_COMMAND_BUTTON_H}
	found = rl.Rectangle{x+2*(UI_COMMAND_BUTTON_W+UI_COMMAND_GAP), y, UI_COMMAND_BUTTON_W, UI_COMMAND_BUTTON_H}
	return
}

UIFoundButtonEnabled :: proc(w: ^World, kingdom, town: int) -> bool {
	if !UICanControlKingdom(w, kingdom) || !WorldTownExists(w, kingdom, town) do return false
	t := &w.kingdoms[kingdom].towns[town]
	if t.wood < TOWN_FOUNDING_WOOD do return false
	if t.citizens < TOWN_FOUNDING_MIN_CITIZENS do return false
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
	town_data := &w.kingdoms[kingdom].towns[town]
	for kind in UI_COMBAT_BUILD_KINDS {
		if !(kind in town_data.unlockedBuildings) do continue
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
	ui := &view.ui
	if !UISelectionValid(w, ui.selection) {
		ui.selection = {}
		if ui.command == .Attack || ui.command == .Defend || ui.command == .Found {
			ui.command = .Inspect
		}
	}

	mouse := rl.GetMousePosition()

	// An unresolved milestone takes over input until the player picks a path.
	if milestone_kingdom, milestone_town, pending := UIMilestoneTown(w); pending {
		ui.hover = {}
		ui.command = .Inspect
		if rl.IsMouseButtonPressed(.LEFT) {
			UIMilestoneClick(w, milestone_kingdom, milestone_town, mouse)
		}
		return
	}

	if UIHudUpdate(w, view, mouse) do return

	over_ui := false

	build_rect := UIBuildButtonRect()
	build_visible := UIBuildButtonVisible(w, ui)
	if build_visible && rl.CheckCollisionPointRec(mouse, build_rect) {
		over_ui = true
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
			over_ui = true
			ui.hover = {}
			if rl.IsMouseButtonPressed(.LEFT) {
				UIBuildPalettePress(w, ui, mouse)
				return
			}
		}
	}

	if UISelectionPlayerTownHall(w, ui.selection) {
		attack_rect, defend_rect, found_rect := UICommandBarRects()
		if rl.CheckCollisionPointRec(mouse, attack_rect) ||
			rl.CheckCollisionPointRec(mouse, defend_rect) ||
			rl.CheckCollisionPointRec(mouse, found_rect) {
			over_ui = true
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
	if over_ui {
		ui.hover = {}
	} else if ui.selection.kind != .None && rl.CheckCollisionPointRec(mouse, panel) {
		ui.hover = {}
	} else {
		ui.hover = UIFindAt(w, camera, mouse)
	}

	if !rl.IsMouseButtonPressed(.LEFT) do return
	if ui.selection.kind != .None && rl.CheckCollisionPointRec(mouse, panel) {
		UIPanelClick(w, ui, panel, mouse)
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
		tile_x, tile_y, ok := UITileAtMouse(w, camera, mouse)
		if !ok do return
		if TownCombatConstructionFailure(w, ui.buildKingdom, ui.buildTown, ui.buildKind, tile_x, tile_y) != .None {
			return
		}
		if !rl.IsMouseButtonPressed(.LEFT) do return
		KingdomIssueCommand(
			w,
			ui.buildKingdom,
			CommandBuildCombat{
				town = ui.buildTown,
				kind = ui.buildKind,
				x = tile_x,
				y = tile_y,
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
		tile_x, tile_y, ok := UITileAtMouse(w, camera, mouse)
		if !ok do return
		if TownFoundingFailure(w, kingdom, town, tile_x, tile_y) != .None do return
		if !rl.IsMouseButtonPressed(.LEFT) do return
		if KingdomIssueCommand(w, kingdom, CommandFoundTown{town = town, x = tile_x, y = tile_y}) {
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
		target_kingdom, target_town, _, found := UIFindTownAt(w, camera, mouse)
		if !found do return
		valid := UIDefendOrderValid(w, kingdom, town, target_kingdom, target_town)
		if ui.command == .Attack {
			valid = UIAttackOrderValid(w, kingdom, town, target_kingdom, target_town)
		}
		if !valid || !rl.IsMouseButtonPressed(.LEFT) do return
		if ui.command == .Attack {
			KingdomIssueCommand(
				w,
				kingdom,
				CommandAttackTown{town = town, target_kingdom = target_kingdom, target_town = target_town},
			)
		} else {
			KingdomIssueCommand(
				w,
				kingdom,
				CommandDefendTown{town = town, target_kingdom = target_kingdom, target_town = target_town},
			)
		}
		ui.command = .Inspect

	case .Build, .Found, .Place, .Inspect:
	}
}

UIPanelClick :: proc(w: ^World, ui: ^UIState, panel: rl.Rectangle, mouse: rl.Vector2) {
	if UISelectionPlayerTownHall(w, ui.selection) {
		for rect, index in UITabRects(panel) {
			if rl.CheckCollisionPointRec(mouse, rect) {
				ui.tab = UITownTab(index)
				return
			}
		}

		switch ui.tab {
		case .Town:
			UIConversionClick(w, ui, panel, mouse)
		case .Orders:
			UIOrdersClick(w, ui, panel, mouse)
		}
		return
	}

	UIConversionClick(w, ui, panel, mouse)
}

UIOrdersClick :: proc(w: ^World, ui: ^UIState, panel: rl.Rectangle, mouse: rl.Vector2) {
	kingdom, town := UISelectionTown(w, ui.selection)
	orders := UITownOrderCount(w, kingdom, town)
	for index in 0..<orders {
		if !rl.CheckCollisionPointRec(mouse, UIOrderCancelRect(panel, index)) do continue
		attack, target_kingdom, target_town, found := UITownOrderAt(w, kingdom, town, index)
		if !found do return
		if attack {
			KingdomIssueCommand(
				w,
				kingdom,
				CommandStopAttack{town = town, target_kingdom = target_kingdom, target_town = target_town},
			)
		} else {
			KingdomIssueCommand(
				w,
				kingdom,
				CommandStopDefend{town = town, target_kingdom = target_kingdom, target_town = target_town},
			)
		}
		return
	}
}

UICommandBarPress :: proc(w: ^World, ui: ^UIState, mouse: rl.Vector2) {
	kingdom, town := UISelectionTown(w, ui.selection)
	attack_rect, defend_rect, found_rect := UICommandBarRects()
	if rl.CheckCollisionPointRec(mouse, attack_rect) {
		if ui.command == .Attack {
			ui.command = .Inspect
		} else if UIAttackTargetExists(w, kingdom, town) {
			ui.command = .Attack
		}
		ui.hover = {}
		return
	}
	if rl.CheckCollisionPointRec(mouse, defend_rect) {
		if ui.command == .Defend {
			ui.command = .Inspect
		} else if UIDefendTargetExists(w, kingdom, town) {
			ui.command = .Defend
		}
		ui.hover = {}
		return
	}
	if rl.CheckCollisionPointRec(mouse, found_rect) {
		if ui.command == .Found {
			ui.command = .Inspect
		} else if UIFoundButtonEnabled(w, kingdom, town) {
			ui.command = .Found
		}
		ui.hover = {}
	}
}

UITileAtMouse :: proc(w: ^World, camera: rl.Camera2D, mouse: rl.Vector2) -> (tile_x, tile_y: int, ok: bool) {
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
	tile_x := int(WorldWrapPosition(world.x, f32(w.maxX)))
	tile_y := int(WorldWrapPosition(world.y, f32(w.maxY)))
	if tile_x < 0 || tile_x >= int(w.maxX) || tile_y < 0 || tile_y >= int(w.maxY) {
		return {}
	}
	slot := w.tileBuilding[tile_x*int(w.maxY)+tile_y]
	if slot >= 0 && slot < BUILDING_CAPACITY && w.buildingUsed[slot] && FogBuildingVisible(w, slot) {
		return Selection{kind = .Building, slot = slot}
	}
	return {}
}

UIFindTownAt :: proc(w: ^World, camera: rl.Camera2D, mouse: rl.Vector2) -> (kingdom, town, hall_slot: int, found: bool) {
	selection := UIFindBuildingAt(w, camera, mouse)
	if selection.kind == .Building {
		kingdom = w.buildings[selection.slot].kingdom
		town = w.buildings[selection.slot].town
		if !WorldTownExists(w, kingdom, town) do return -1, -1, -1, false
		hall_slot = TownHallSlot(w, kingdom, town)
		if hall_slot < 0 do return -1, -1, -1, false
		return kingdom, town, hall_slot, true
	}

	// Discovered but currently fogged towns remain valid order targets.
	tile_x, tile_y, ok := UITileAtMouse(w, camera, mouse)
	if !ok do return -1, -1, -1, false
	kingdom, town, found = FogFindTownAt(w, tile_x, tile_y)
	if !found do return -1, -1, -1, false
	hall_slot = TownHallSlot(w, kingdom, town)
	return
}

UIFindAt :: proc(w: ^World, camera: rl.Camera2D, mouse: rl.Vector2) -> Selection {
	world := rl.GetScreenToWorld2D(mouse, camera)
	world_width := f32(w.maxX)
	world_height := f32(w.maxY)
	px := WorldWrapPosition(world.x, world_width)
	py := WorldWrapPosition(world.y, world_height)

	best_slot := -1
	best_distance: f32 = 1e9
	for unit_slot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[unit_slot] do continue
		if w.units[unit_slot].type == nil do continue
		if !FogUnitVisible(w, unit_slot) do continue
		if state, ok := w.units[unit_slot].state.(StateConverting); ok && state.inside {
			continue
		}

		scale := UnitSpriteScale(UnitKindOf(w.units[unit_slot].type))
		x, y := UnitRenderPosition(w, unit_slot)
		if px < x-scale*0.5 || px > x+scale*0.5 || py < y+0.5-scale || py > y+0.5 {
			continue
		}
		dx := px-x
		dy := py-y
		distance := dx*dx+dy*dy
		if distance < best_distance {
			best_distance = distance
			best_slot = unit_slot
		}
	}
	if best_slot >= 0 {
		return Selection{kind = .Unit, slot = best_slot}
	}

	tile_x := int(px)
	tile_y := int(py)
	if tile_x >= 0 && tile_x < int(w.maxX) && tile_y >= 0 && tile_y < int(w.maxY) {
		slot := w.tileBuilding[tile_x*int(w.maxY)+tile_y]
		if slot >= 0 && slot < BUILDING_CAPACITY && w.buildingUsed[slot] && FogBuildingVisible(w, slot) {
			return Selection{kind = .Building, slot = slot}
		}
	}
	return {}
}

UIConversionClick :: proc(w: ^World, ui: ^UIState, panel: rl.Rectangle, mouse: rl.Vector2) {
	if !UISelectionTownHall(w, ui.selection) do return
	kingdom, town := UISelectionTown(w, ui.selection)
	if !UICanControlKingdom(w, kingdom) do return

	kinds: [len(UnitKind)]UnitKind
	count := UIConversionRows(w, ui.selection, &kinds)
	for i in 0..<count {
		kind := kinds[i]
		minus, plus := UIButtonRects(panel, i)
		if rl.CheckCollisionPointRec(mouse, plus) {
			if UICanConvertTo(w, kingdom, town, kind) {
				if UIConversionCount(w, kingdom, town, kind, .Villager) > 0 {
					KingdomIssueCommand(
						w,
						kingdom,
						CommandRemoveConversion{town = town, from = kind, to = .Villager, count = 1},
					)
				} else {
					KingdomIssueCommand(
						w,
						kingdom,
						CommandQueueConversion{town = town, from = .Villager, to = kind, count = 1},
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
						CommandRemoveConversion{town = town, from = .Villager, to = kind, count = 1},
					)
				} else {
					KingdomIssueCommand(
						w,
						kingdom,
						CommandQueueConversion{town = town, from = kind, to = .Villager, count = 1},
					)
				}
			}
			return
		}
	}
}

// --- drawing --------------------------------------------------------------

WorldUIDraw :: proc(w: ^World, renderer: ^WorldRenderer, camera: rl.Camera2D, ui: ^UIState) {
	milestone_kingdom, milestone_town, milestone_pending := UIMilestoneTown(w)

	UIDrawOrderArrows(w, camera, ui.selection)
	if ui.command == .Attack || ui.command == .Defend {
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
	if !milestone_pending {
		UIDrawCommandBar(w, ui)
		UIDrawBuildButton(w, ui)
		UIDrawBuildPalette(w, renderer, ui)
	}
	UIDrawBuildPreview(w, renderer, camera, ui)
	UIDrawFoundPreview(w, renderer, camera, ui)
	UIDrawCommandHint(w, ui, camera)
	if !milestone_pending {
		UIDrawHud(w, ui)
		UIDrawSidePanel(w, ui)
		UIDrawAlerts(w)
	}

	if milestone_pending {
		UIDrawMilestone(w, renderer, milestone_kingdom, milestone_town)
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

UIDrawTownAreaFor :: proc(w: ^World, camera: rl.Camera2D, kingdom, town_slot: int, faint: bool) {
	if !WorldTownExists(w, kingdom, town_slot) do return
	town := &w.kingdoms[kingdom].towns[town_slot]

	accent := FactionColor(w, kingdom)
	fill_alpha: u8 = faint ? 8 : 24
	line_alpha: u8 = faint ? 70 : 140
	fill := rl.Color{accent[0], accent[1], accent[2], fill_alpha}
	line := rl.Color{accent[0], accent[1], accent[2], line_alpha}
	thickness := 1/camera.zoom

	hall_width, hall_height := BuildingTileSize(TownHall{})
	radius := town.areaRadius
	min_x := max(0, town.x-radius-1)
	max_x := min(int(w.maxX)-1, town.x+hall_width+radius)
	min_y := max(0, town.y-radius-1)
	max_y := min(int(w.maxY)-1, town.y+hall_height+radius)

	// Only iterate tiles that can actually be on screen.
	half_width := f32(rl.GetScreenWidth())/(2*camera.zoom)
	half_height := f32(rl.GetScreenHeight())/(2*camera.zoom)
	min_x = max(min_x, int(camera.target.x-half_width)-1)
	max_x = min(max_x, int(camera.target.x+half_width)+1)
	min_y = max(min_y, int(camera.target.y-half_height)-1)
	max_y = min(max_y, int(camera.target.y+half_height)+1)
	if min_x > max_x || min_y > max_y do return

	rl.BeginMode2D(camera)
	for x in min_x ..= max_x {
		for y in min_y ..= max_y {
			if !TownPointInArea(w, kingdom, town_slot, x, y) do continue
			rl.DrawRectangleRec(rl.Rectangle{f32(x), f32(y), 1, 1}, fill)
			if !TownPointInArea(w, kingdom, town_slot, x+1, y) {
				rl.DrawRectangleRec(rl.Rectangle{f32(x)+1-thickness, f32(y), thickness, 1}, line)
			}
			if !TownPointInArea(w, kingdom, town_slot, x-1, y) {
				rl.DrawRectangleRec(rl.Rectangle{f32(x), f32(y), thickness, 1}, line)
			}
			if !TownPointInArea(w, kingdom, town_slot, x, y+1) {
				rl.DrawRectangleRec(rl.Rectangle{f32(x), f32(y)+1-thickness, 1, thickness}, line)
			}
			if !TownPointInArea(w, kingdom, town_slot, x, y-1) {
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

	title_x := portrait.x+portrait.width+12
	switch ui.selection.kind {
	case .Unit:
		ui_title(UIUnitName(UnitKindOf(w.units[ui.selection.slot].type)), title_x, panel.y+10, UI_COLOR_GOLD)
	case .Building:
		ui_title(UIBuildingName(BuildingKindOf(w.buildings[ui.selection.slot].type)), title_x, panel.y+10, UI_COLOR_GOLD)
	case .None:
	}
	if WorldTownExists(w, kingdom, town) {
		ui_text(
			fmt.ctprintf("%s  -  %s", NameKingdomCString(w, kingdom), NameTownCString(w, kingdom, town)),
			title_x,
			panel.y+48,
			UI_COLOR_DIM,
		)
	}

	switch ui.selection.kind {
	case .Unit:
		ui_text(UIUnitDescription(UnitKindOf(w.units[ui.selection.slot].type)), panel.x+UI_PAD, panel.y+UI_DESC_Y, UI_COLOR_TEXT)
	case .Building:
		ui_text(UIBuildingDescription(BuildingKindOf(w.buildings[ui.selection.slot].type)), panel.x+UI_PAD, panel.y+UI_DESC_Y, UI_COLOR_TEXT)
	case .None:
	}

	stats: [8]UIStat
	stat_count := UIFillStats(w, ui, &stats)
	if UISelectionTownHall(w, ui.selection) {
		left_label_x := panel.x+UI_PAD
		left_value_x := panel.x+UI_PAD+170
		right_label_x := panel.x+UI_PAD+186
		right_value_x := panel.x+panel.width-UI_PAD
		for i in 0..<stat_count {
			column := i/4
			row := i%4
			y := panel.y+UI_STAT_Y+f32(row)*UI_STAT_H
			value_color := stats[i].color
			if value_color.a == 0 do value_color = UI_COLOR_TEXT
			if column == 0 {
				ui_text(stats[i].label, left_label_x, y, UI_COLOR_DIM)
				ui_text_right(stats[i].value, left_value_x, y, value_color)
			} else {
				ui_text(stats[i].label, right_label_x, y, UI_COLOR_DIM)
				ui_text_right(stats[i].value, right_value_x, y, value_color)
			}
		}
		UIDrawConstructionStatus(w, panel, kingdom, town)
	} else {
		for i in 0..<stat_count {
			y := panel.y+UI_STAT_Y+f32(i)*UI_STAT_H
			value_color := stats[i].color
			if value_color.a == 0 do value_color = UI_COLOR_TEXT
			ui_text(stats[i].label, panel.x+UI_PAD, y, UI_COLOR_DIM)
			ui_text(stats[i].value, panel.x+UI_PAD+104, y, value_color)
		}
	}

	if ui.selection.kind == .Unit {
		UIDrawUnitEffects(w, renderer, panel, ui.selection.slot)
	}

	if UISelectionTownHall(w, ui.selection) {
		UIDrawGrowthBar(w, panel, kingdom, town)
		if UICanControlKingdom(w, kingdom) {
			UIDrawTownTabs(w, ui, panel)
			switch ui.tab {
			case .Town:
				UIDrawConversions(w, renderer, ui, panel, kingdom, town)
			case .Orders:
				UIDrawOrdersTab(w, renderer, panel, kingdom, town)
			}
		}
	}
}

UIDrawTownTabs :: proc(w: ^World, ui: ^UIState, panel: rl.Rectangle) {
	rl.DrawRectangleRec(
		rl.Rectangle{panel.x+UI_PAD, panel.y+UI_TOWN_DIVIDER, panel.width-2*UI_PAD, 1},
		UI_COLOR_DIVIDER,
	)

	kingdom, town := UISelectionTown(w, ui.selection)
	villagers := TownUnitCount(w, kingdom, town, .Villager)
	ui_text_right(
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
		ui_text(label, rect.x+4, rect.y-1, color)
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
		texture = renderer.sprites.unit[faction][UnitKindOf(w.units[ui.selection.slot].type)]
	case .Building:
		texture = renderer.sprites.building[faction][BuildingKindOf(w.buildings[ui.selection.slot].type)]
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

UIFillStats :: proc(w: ^World, ui: ^UIState, stats: ^[8]UIStat) -> int {
	switch ui.selection.kind {
	case .Unit:
		unit := w.units[ui.selection.slot]
		stats[0] = {"Health", fmt.ctprintf("%d / %d", int(unit.health), int(UnitDefaultHealth(unit.type))), UI_COLOR_TEXT}
		stats[1] = {"Task", UIUnitStateName(unit.state), UI_COLOR_TEXT}
		return 2

	case .Building:
		building := w.buildings[ui.selection.slot]
		kind := BuildingKindOf(building.type)
		stats[0] = {"Health", fmt.ctprintf("%d / %d", int(building.health), int(BuildingDefaultHealth(building.type))), UI_COLOR_TEXT}
		if kind == .TownHall {
			t := &w.kingdoms[building.kingdom].towns[building.town]
			stats[1] = {"Citizens", fmt.ctprintf("%d", t.citizens), UI_COLOR_TEXT}
			stats[2] = {"Wood", fmt.ctprintf("%d", int(t.wood)), UI_COLOR_TEXT}
			if t.milestonesReached < TOWN_MILESTONE_COUNT {
				stats[3] = {
					"Milestone",
					fmt.ctprintf("%d / %d", t.citizens, TOWN_MILESTONES[t.milestonesReached]),
					UI_COLOR_TEXT,
				}
			} else {
				stats[3] = {"Milestone", "Complete", UI_COLOR_TEXT}
			}
			food_text, food_color := UIResourceCoverage(t.foodPotential, f32(t.citizens)*0.025)
			water_text, water_color := UIResourceCoverage(t.waterPotential, f32(t.citizens)*0.025)
			stats[4] = {"Food", food_text, food_color}
			stats[5] = {"Water", water_text, water_color}
			stats[6] = {"Housing", fmt.ctprintf("%d", t.homes), UI_COLOR_TEXT}
			return 7
		}
		if BuildingIsTraining(kind) {
			stats[1] = {"Trains", UIUnitName(UIUnitFromTraining(kind)), UI_COLOR_TEXT}
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
	unit_slot: int,
) {
	count := UIUnitEffectCount(w, unit_slot)
	if count <= 0 do return

	y := panel.y+UI_STAT_Y+2*UI_STAT_H+3
	ui_text("Effects", panel.x+UI_PAD, y+3, UI_COLOR_DIM)

	mouse := rl.GetMousePosition()
	x := panel.x+UI_PAD+78
	hovered := UnitEffects.NoHome
	any_hovered := false
	for effect in ALL_UNIT_EFFECTS {
		if !w.units[unit_slot].effects[effect] do continue
		icon := rl.Rectangle{x, y, 22, 22}
		hover := rl.CheckCollisionPointRec(mouse, icon)
		background := UI_COLOR_BUTTON_OFF
		border := UI_COLOR_BORDER_INNER
		if hover {
			background = UI_COLOR_BUTTON_HOVER
			border = UI_COLOR_GOLD
			hovered = effect
			any_hovered = true
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

	if any_hovered do UIDrawUnitEffectTooltip(mouse, hovered)
}

UIDrawUnitEffectTooltip :: proc(mouse: rl.Vector2, effect: UnitEffects) {
	title := UIUnitEffectName(effect)
	body := UIUnitEffectText(effect)
	title_width := rl.MeasureTextEx(ui_font(), title, UI_TEXT_SIZE, 1).x
	body_width := rl.MeasureTextEx(ui_font(), body, UI_TEXT_SIZE, 1).x
	padding: f32 = 8
	line_height := UIHudLineHeight()
	width := max(title_width, body_width)+padding*2
	height := line_height*2+padding*2+4

	x := mouse.x+16
	y := mouse.y+16
	screen_width := f32(rl.GetScreenWidth())
	screen_height := f32(rl.GetScreenHeight())
	if x+width > screen_width-8 do x = mouse.x-16-width
	if y+height > screen_height-8 do y = mouse.y-16-height

	rl.DrawRectangleRec(rl.Rectangle{x, y, width, height}, UI_COLOR_BG)
	rl.DrawRectangleLinesEx(rl.Rectangle{x, y, width, height}, 1, UI_COLOR_GOLD)
	ui_text(title, x+padding, y+padding, UI_COLOR_GOLD)
	ui_text(body, x+padding, y+padding+line_height, UI_COLOR_TEXT)
}

UIDrawGrowthBar :: proc(w: ^World, panel: rl.Rectangle, kingdom, town: int) {
	if !WorldTownExists(w, kingdom, town) do return
	t := &w.kingdoms[kingdom].towns[town]

	y := panel.y+UI_GROWTH_Y
	ui_text("Next villager", panel.x+UI_PAD, y, UI_COLOR_DIM)

	bar := rl.Rectangle{
		panel.x+UI_PAD+126,
		y+6,
		panel.width-2*UI_PAD-126,
		9,
	}
	progress := clamp(t.growthProgress+w.simulationAccumulator*t.growthRate, 0, 1)

	rl.DrawRectangleRec(bar, UI_COLOR_BUTTON_OFF)
	if progress > 0 {
		rl.DrawRectangleRec(
			rl.Rectangle{bar.x, bar.y, bar.width*progress, bar.height},
			UI_COLOR_GOLD,
		)
	}
	rl.DrawRectangleLinesEx(bar, 1, UI_COLOR_BORDER_INNER)
}

UIDrawConstructionStatus :: proc(w: ^World, panel: rl.Rectangle, kingdom, town: int) {
	if !WorldTownExists(w, kingdom, town) do return
	t := &w.kingdoms[kingdom].towns[town]
	y := panel.y+UI_STAT_Y+4*UI_STAT_H
	ui_text("Construction", panel.x+UI_PAD, y, UI_COLOR_DIM)

	value: cstring = "None"
	if t.constructionActive {
		site := t.construction
		if TownConstructionPendingDecoration(w, site) >= 0 {
			value = fmt.ctprintf("%s  clearing", UIBuildingName(site.kind))
		} else {
			seconds := BuildingBuildSeconds(site.kind)
			progress: f32 = 0
			if seconds > 0 do progress = clamp(site.buildWork/seconds, 0, 1)
			value = fmt.ctprintf("%s  %d%%", UIBuildingName(site.kind), int(progress*100))
		}
	}
	ui_text(value, panel.x+UI_PAD+150, y, UI_COLOR_TEXT)
}

UIDrawConversions :: proc(w: ^World, renderer: ^WorldRenderer, ui: ^UIState, panel: rl.Rectangle, kingdom, town: int) {
	kinds: [len(UnitKind)]UnitKind
	count := UIConversionRows(w, ui.selection, &kinds)
	for i in 0..<count {
		UIDrawConversionRow(w, renderer, ui, panel, i, kinds[i], kingdom, town)
	}
}

UIConversionProgress :: proc(w: ^World, kingdom, town: int, kind: UnitKind) -> (assigned, remaining, training: int, progress: f32, has_job: bool) {
	if !WorldTownExists(w, kingdom, town) do return
	t := &w.kingdoms[kingdom].towns[town]
	for job_index in 0..<t.conversionCount {
		job := t.conversions[job_index]
		if job.to != kind do continue
		has_job = true
		assigned += job.assigned
		remaining += job.remaining
	}
	if !has_job do return

	for unit_slot in 0..<UNIT_CAPACITY {
		if !w.unitUsed[unit_slot] do continue
		if w.units[unit_slot].kingdome != kingdom || w.units[unit_slot].town != town do continue
		state, converting := w.units[unit_slot].state.(StateConverting)
		if !converting || state.to != kind || !state.inside do continue
		training += 1
		seconds := UnitDefaultTrainingTime(kind)
		if seconds > 0 do progress += 1-clamp(state.timer/seconds, 0, 1)
	}
	if training > 0 do progress /= f32(training)
	return
}

UIDrawConversionRow :: proc(w: ^World, renderer: ^WorldRenderer, ui: ^UIState, panel: rl.Rectangle, index: int, kind: UnitKind, kingdom, town: int) {
	row_y := panel.y+UI_ROWS_TOP+f32(index)*UI_ROW_HEIGHT

	faction := FactionSpriteIndex(kingdom)
	texture := renderer.sprites.unit[faction][kind]
	if texture.id != 0 {
		icon := rl.Rectangle{panel.x+UI_PAD, row_y+2, 32, 32}
		source := rl.Rectangle{0, 0, f32(texture.width), f32(texture.height)}
		rl.DrawTexturePro(texture, source, icon, rl.Vector2{0, 0}, 0, rl.WHITE)
	}

	ui_text(UIUnitName(kind), panel.x+UI_PAD+38, row_y+8, UI_COLOR_TEXT)

	minus, plus := UIButtonRects(panel, index)
	_, remaining, training, progress, has_job := UIConversionProgress(w, kingdom, town, kind)
	if has_job && remaining > 0 {
		ui_text(fmt.ctprintf("%d/%d", training, remaining), minus.x-112, row_y+8, UI_COLOR_DIM)

		bar := rl.Rectangle{
			panel.x+UI_PAD+38,
			row_y+31,
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

	pending := UIConversionPending(w, kingdom, town, kind)
	if pending != 0 {
		ui_text(fmt.ctprintf("%+d", pending), minus.x-56, row_y+8, UI_COLOR_GOLD)
	}
	unit_count := TownUnitCount(w, kingdom, town, kind)
	ui_text_right(fmt.ctprintf("%d", unit_count), minus.x-8, row_y+8, UI_COLOR_TEXT)

	UIButton(minus, "-", UICanConvertFrom(w, kingdom, town, kind))
	UIButton(plus, "+", UICanConvertTo(w, kingdom, town, kind))
}

UIDrawOrdersTab :: proc(w: ^World, renderer: ^WorldRenderer, panel: rl.Rectangle, kingdom, town: int) {
	if !WorldTownExists(w, kingdom, town) do return
	top := panel.y+UI_ROWS_TOP
	orders := UITownOrderCount(w, kingdom, town)

	ui_text("STANDING ORDERS", panel.x+UI_PAD, top, UI_COLOR_DIM)
	ui_text_right(fmt.ctprintf("%d orders", orders), panel.x+panel.width-UI_PAD, top, UI_COLOR_DIM)

	if orders == 0 {
		ui_text("No standing orders.", panel.x+UI_PAD, top+UI_SECTION_HEADER+8, UI_COLOR_DIM)
		return
	}

	for index in 0..<orders {
		attack, target_kingdom, target_town, found := UITownOrderAt(w, kingdom, town, index)
		if !found do continue
		row_y := panel.y+UI_ROWS_TOP+UI_SECTION_HEADER+f32(index)*UI_ROW_HEIGHT

		faction := FactionSpriteIndex(target_kingdom)
		texture := renderer.sprites.building[faction][.TownHall]
		if texture.id != 0 {
			icon := rl.Rectangle{panel.x+UI_PAD, row_y+2, 32, 32}
			source := rl.Rectangle{0, 0, f32(texture.width), f32(texture.height)}
			rl.DrawTexturePro(texture, source, icon, rl.Vector2{0, 0}, 0, rl.WHITE)
		}

		label := attack ? fmt.ctprintf("Attack  %s", NameTownCString(w, target_kingdom, target_town)) : fmt.ctprintf("Defend  %s", NameTownCString(w, target_kingdom, target_town))
		label_color := attack ? UI_COLOR_ATTACK : UI_COLOR_DEFEND
		ui_text(label, panel.x+UI_PAD+38, row_y+8, label_color)
		UIButton(UIOrderCancelRect(panel, index), "Cancel", true)
	}
}

UIDrawCommandBar :: proc(w: ^World, ui: ^UIState) {
	if !UISelectionPlayerTownHall(w, ui.selection) do return
	kingdom, town := UISelectionTown(w, ui.selection)
	attack_rect, defend_rect, found_rect := UICommandBarRects()
	UIDrawCommandIcon(
		attack_rect,
		.Attack,
		UIAttackTargetExists(w, kingdom, town),
		ui.command == .Attack,
	)
	UIDrawCommandIcon(
		defend_rect,
		.Defend,
		UIDefendTargetExists(w, kingdom, town),
		ui.command == .Defend,
	)
	UIDrawCommandIcon(
		found_rect,
		.Found,
		UIFoundButtonEnabled(w, kingdom, town),
		ui.command == .Found,
	)
	if rl.CheckCollisionPointRec(rl.GetMousePosition(), found_rect) {
		UIDrawFoundHint(w, found_rect, kingdom, town)
	}
}

// Found-button hover readout: shows exactly which requirement is missing, so
// expansion never feels blocked for an unexplained reason.
UIDrawFoundHint :: proc(w: ^World, rect: rl.Rectangle, kingdom, town: int) {
	if !WorldTownExists(w, kingdom, town) do return
	t := &w.kingdoms[kingdom].towns[town]
	builders := TownUnitCount(w, kingdom, town, .Builder)
	text := fmt.ctprintf(
		"Found town  -  wood %d/%d   citizens %d/%d   builders %d/1",
		int(t.wood),
		TOWN_FOUNDING_WOOD,
		t.citizens,
		TOWN_FOUNDING_MIN_CITIZENS,
		builders,
	)
	width := rl.MeasureTextEx(ui_font(), text, UI_TEXT_SIZE, 1).x+2*UI_PAD
	height := UI_TEXT_SIZE+2*UI_PAD
	screen_width := f32(rl.GetScreenWidth())
	x := clamp(rect.x+rect.width*0.5-width*0.5, 8, screen_width-width-8)
	y := rect.y-height-8
	rl.DrawRectangleRec(rl.Rectangle{x, y, width, height}, UI_COLOR_BG)
	rl.DrawRectangleLinesEx(rl.Rectangle{x, y, width, height}, 1, UI_COLOR_BORDER)
	color := UI_COLOR_TEXT
	if !UIFoundButtonEnabled(w, kingdom, town) do color = UI_COLOR_BAD
	ui_text(text, x+UI_PAD, y+UI_PAD-2, color)
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
	border_width: f32 = 1
	if active {
		switch command {
		case .Attack:
			border = UI_COLOR_ATTACK
		case .Defend:
			border = UI_COLOR_DEFEND
		case .Found:
			border = UI_COLOR_FOUND
		case .Build, .Place:
			border = UI_COLOR_BUILD
		case .Inspect:
		}
		border_width = 2
	}
	rl.DrawRectangleLinesEx(rect, border_width, border)

	icon_color := UI_COLOR_BUILD
	switch command {
	case .Attack:
		icon_color = UI_COLOR_ATTACK
	case .Defend:
		icon_color = UI_COLOR_DEFEND
	case .Found:
		icon_color = UI_COLOR_FOUND
	case .Build, .Place, .Inspect:
	}
	if !enabled do icon_color = UI_COLOR_DISABLED_TEXT
	center_x := rect.x+rect.width*0.5
	center_y := rect.y+23
	switch command {
	case .Attack:
		UIDrawAttackIcon(center_x, center_y, icon_color)
	case .Defend:
		UIDrawDefendIcon(center_x, center_y, icon_color)
	case .Found:
		UIDrawFoundIcon(center_x, center_y, icon_color)
	case .Build, .Place:
		UIDrawBuildIcon(center_x, center_y, icon_color)
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
	case .Build, .Place, .Inspect:
	}
	label_color := enabled ? UI_COLOR_TEXT : UI_COLOR_DISABLED_TEXT
	ui_text_center(label, rect.x+rect.width*0.5, rect.y+46, label_color)
}

UIDrawAttackIcon :: proc(center_x, center_y: f32, color: rl.Color) {
	dark := rl.Color{12, 11, 14, 230}
	gold := rl.Color{224, 176, 70, 220}
	grip := rl.Color{132, 98, 64, 230}

	blade_top := rl.Vector2{center_x, center_y-14}
	blade_bottom := rl.Vector2{center_x, center_y+2}
	rl.DrawLineEx(blade_top, blade_bottom, 7, dark)
	rl.DrawLineEx(blade_top, blade_bottom, 4, color)
	rl.DrawTriangle(
		rl.Vector2{center_x, center_y-19},
		rl.Vector2{center_x-4, center_y-12},
		rl.Vector2{center_x+4, center_y-12},
		color,
	)

	guard_left := rl.Vector2{center_x-9, center_y+3}
	guard_right := rl.Vector2{center_x+9, center_y+3}
	rl.DrawLineEx(guard_left, guard_right, 6, dark)
	rl.DrawLineEx(guard_left, guard_right, 3, gold)

	grip_top := rl.Vector2{center_x, center_y+4}
	grip_bottom := rl.Vector2{center_x, center_y+13}
	rl.DrawLineEx(grip_top, grip_bottom, 7, dark)
	rl.DrawLineEx(grip_top, grip_bottom, 4, grip)
	rl.DrawRectangle(i32(center_x)-2, i32(center_y)+13, 4, 4, gold)
}

UIDrawDefendIcon :: proc(center_x, center_y: f32, color: rl.Color) {
	dark := rl.Color{12, 11, 14, 230}
	center := rl.Vector2{center_x, center_y+1}
	rl.DrawPoly(center, 5, 18, 90, dark)
	rl.DrawPoly(center, 5, 15, 90, color)

	emblem := rl.Color{232, 240, 248, 230}
	x := i32(center_x)
	y := i32(center_y)
	rl.DrawRectangle(x-2, y-7, 4, 20, emblem)
	rl.DrawRectangle(x-7, y+1, 14, 4, emblem)
}

UIDrawBuildIcon :: proc(center_x, center_y: f32, color: rl.Color) {
	dark := rl.Color{12, 11, 14, 230}
	x := i32(center_x)
	y := i32(center_y)

	// Hammer handle.
	rl.DrawRectangle(x-2, y-2, 4, 18, dark)
	rl.DrawRectangle(x-1, y-1, 2, 16, rl.Color{132, 98, 64, 230})

	// Head.
	rl.DrawRectangle(x-11, y-12, 22, 7, dark)
	rl.DrawRectangle(x-10, y-11, 20, 5, color)
	rl.DrawRectangle(x-4, y-11, 8, 5, rl.Color{238, 238, 244, 210})
}

UIDrawFoundIcon :: proc(center_x, center_y: f32, color: rl.Color) {
	dark := rl.Color{12, 11, 14, 230}
	x := i32(center_x)
	y := i32(center_y)

	// Small hall with a banner.
	rl.DrawRectangle(x-10, y+1, 20, 12, dark)
	rl.DrawRectangle(x-9, y+2, 18, 10, color)
	rl.DrawRectangle(x-7, y+5, 5, 7, rl.Color{238, 238, 244, 210})
	rl.DrawTriangle(
		rl.Vector2{center_x, center_y-11},
		rl.Vector2{center_x-12, center_y+1},
		rl.Vector2{center_x+12, center_y+1},
		dark,
	)
	rl.DrawTriangle(
		rl.Vector2{center_x, center_y-9},
		rl.Vector2{center_x-10, center_y+1},
		rl.Vector2{center_x+10, center_y+1},
		color,
	)

	// Flag.
	rl.DrawLineEx(
		rl.Vector2{center_x, center_y-14},
		rl.Vector2{center_x, center_y-2},
		3,
		dark,
	)
	rl.DrawTriangle(
		rl.Vector2{center_x+1, center_y-14},
		rl.Vector2{center_x+11, center_y-10},
		rl.Vector2{center_x+1, center_y-6},
		color,
	)
}

UIDrawCommandTargets :: proc(w: ^World, camera: rl.Camera2D, ui: ^UIState) {
	kingdom, town := UISelectionTown(w, ui.selection)
	if !WorldTownExists(w, kingdom, town) do return

	for target_kingdom in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[target_kingdom] do continue
		for target_town in 0..<TOWN_CAPACITY {
			if !w.kingdoms[target_kingdom].townUsed[target_town] do continue
			valid := UIDefendOrderValid(w, kingdom, town, target_kingdom, target_town)
			if ui.command == .Attack {
				valid = UIAttackOrderValid(w, kingdom, town, target_kingdom, target_town)
			}
			if !valid do continue
			UIDrawTownAreaFor(w, camera, target_kingdom, target_town, true)
			UIDrawTownHallOutline(w, camera, target_kingdom, target_town, 150, 1.2)
		}
	}

	hover_kingdom, hover_town, _, found := UIFindTownAt(w, camera, rl.GetMousePosition())
	if !found do return
	valid := UIDefendOrderValid(w, kingdom, town, hover_kingdom, hover_town)
	if ui.command == .Attack {
		valid = UIAttackOrderValid(w, kingdom, town, hover_kingdom, hover_town)
	}
	if !valid do return
	UIDrawTownAreaFor(w, camera, hover_kingdom, hover_town, false)
	UIDrawTownHallOutline(w, camera, hover_kingdom, hover_town, 230, 2)

	preview_color := ui.command == .Attack ? UI_COLOR_ATTACK : UI_COLOR_DEFEND
	UIDrawOrderArrow(w, camera, kingdom, town, hover_kingdom, hover_town, preview_color, true)
}

UIDrawTownHallOutline :: proc(w: ^World, camera: rl.Camera2D, kingdom, town: int, alpha: u8, pixel_width: f32) {
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
	rl.DrawRectangleLinesEx(rect, pixel_width/camera.zoom, rl.Color{236, 204, 116, alpha})
	rl.EndMode2D()
}

UIDrawOrderArrows :: proc(w: ^World, camera: rl.Camera2D, selection: Selection) {
	if !UISelectionTownHall(w, selection) do return
	kingdom, town := UISelectionTown(w, selection)
	if !WorldTownExists(w, kingdom, town) do return
	orders := &w.kingdoms[kingdom].towns[town]

	// Incoming orders are faint so the selected town's own orders stay readable.
	for attacker_kingdom in 0..<KINGDOMS_CAPACITY {
		for attacker_town in 0..<TOWN_CAPACITY {
			if !orders.attackedBy[attacker_kingdom][attacker_town] do continue
			if !WorldTownExists(w, attacker_kingdom, attacker_town) do continue
			if !FogTownDiscovered(w, attacker_kingdom, attacker_town) do continue
			UIDrawOrderArrow(
				w,
				camera,
				attacker_kingdom,
				attacker_town,
				kingdom,
				town,
				UI_COLOR_ATTACK_FAINT,
				false,
			)
		}
	}
	for defender_kingdom in 0..<KINGDOMS_CAPACITY {
		for defender_town in 0..<TOWN_CAPACITY {
			if !orders.defendedBy[defender_kingdom][defender_town] do continue
			if !WorldTownExists(w, defender_kingdom, defender_town) do continue
			if !FogTownDiscovered(w, defender_kingdom, defender_town) do continue
			if defender_kingdom == kingdom && defender_town == town do continue
			UIDrawOrderArrow(
				w,
				camera,
				defender_kingdom,
				defender_town,
				kingdom,
				town,
				UI_COLOR_DEFEND_FAINT,
				false,
			)
		}
	}

	for target_kingdom in 0..<KINGDOMS_CAPACITY {
		for target_town in 0..<TOWN_CAPACITY {
			if !orders.attackOrders[target_kingdom][target_town] do continue
			if !WorldTownExists(w, target_kingdom, target_town) do continue
			if !FogTownDiscovered(w, target_kingdom, target_town) do continue
			UIDrawOrderArrow(w, camera, kingdom, town, target_kingdom, target_town, UI_COLOR_ATTACK, false)
		}
	}
	for protected_kingdom in 0..<KINGDOMS_CAPACITY {
		for protected_town in 0..<TOWN_CAPACITY {
			if !orders.defendOrders[protected_kingdom][protected_town] do continue
			if !WorldTownExists(w, protected_kingdom, protected_town) do continue
			if !FogTownDiscovered(w, protected_kingdom, protected_town) do continue
			if protected_kingdom == kingdom && protected_town == town do continue
			UIDrawOrderArrow(w, camera, kingdom, town, protected_kingdom, protected_town, UI_COLOR_DEFEND, false)
		}
	}
}

// Arrows are drawn in screen space so their heads keep a constant size at any zoom.
UIDrawOrderArrow :: proc(w: ^World, camera: rl.Camera2D, from_kingdom, from_town, to_kingdom, to_town: int, color: rl.Color, preview: bool) {
	from_hall := TownHallSlot(w, from_kingdom, from_town)
	to_hall := TownHallSlot(w, to_kingdom, to_town)
	if from_hall < 0 || to_hall < 0 do return

	from_width, from_height := BuildingTileSize(w.buildings[from_hall].type)
	to_width, to_height := BuildingTileSize(w.buildings[to_hall].type)
	from_x := f32(w.buildings.x[from_hall])+f32(from_width)*0.5
	from_y := f32(w.buildings.y[from_hall])+f32(from_height)*0.5
	to_x := f32(w.buildings.x[to_hall])+f32(to_width)*0.5
	to_y := f32(w.buildings.y[to_hall])+f32(to_height)*0.5
	delta_x := WorldShortestWrappedDelta(to_x-from_x, f32(w.maxX))
	delta_y := WorldShortestWrappedDelta(to_y-from_y, f32(w.maxY))

	start := rl.GetWorldToScreen2D(rl.Vector2{from_x, from_y}, camera)
	end := rl.GetWorldToScreen2D(rl.Vector2{from_x+delta_x, from_y+delta_y}, camera)
	dx := end.x-start.x
	dy := end.y-start.y
	length := math.sqrt(dx*dx+dy*dy)
	if length < 1 do return

	dir_x := dx/length
	dir_y := dy/length
	head_length: f32 = preview ? 12 : 16
	head_half: f32 = preview ? 5 : 7
	line_width: f32 = preview ? 1.8 : 2.6
	line_color := color
	if preview do line_color.a = 150

	base := rl.Vector2{end.x-dir_x*head_length, end.y-dir_y*head_length}
	perp_x := -dir_y
	perp_y := dir_x
	left := rl.Vector2{base.x+perp_x*head_half, base.y+perp_y*head_half}
	right := rl.Vector2{base.x-perp_x*head_half, base.y-perp_y*head_half}

	outline := rl.Color{12, 11, 14, 170}
	rl.DrawLineEx(start, base, line_width+2.2, outline)
	rl.DrawLineEx(start, base, line_width, line_color)

	outer_tip := rl.Vector2{end.x+dir_x*1.5, end.y+dir_y*1.5}
	outer_left := rl.Vector2{left.x+perp_x*1.5, left.y+perp_y*1.5}
	outer_right := rl.Vector2{right.x-perp_x*1.5, right.y-perp_y*1.5}
	rl.DrawTriangle(outer_tip, outer_left, outer_right, outline)
	rl.DrawTriangle(end, left, right, line_color)
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
	attack_rect, defend_rect, found_rect := UICommandBarRects()
	build_rect := UIBuildButtonRect()
	if rl.CheckCollisionPointRec(mouse, attack_rect) ||
		rl.CheckCollisionPointRec(mouse, defend_rect) ||
		rl.CheckCollisionPointRec(mouse, found_rect) {
		return
	}
	if UIBuildButtonVisible(w, ui) && rl.CheckCollisionPointRec(mouse, build_rect) do return
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
		label = fmt.ctprintf(
			"Click land to found a town  -  %d wood  -  Esc to cancel",
			TOWN_FOUNDING_WOOD,
		)
		kingdom, town := UISelectionTown(w, ui.selection)
		if tile_x, tile_y, ok := UITileAtMouse(w, camera, mouse); ok {
			failure := TownFoundingFailure(w, kingdom, town, tile_x, tile_y)
			if failure != .None do label = UIPlacementFailureText(failure)
		}
	case .Build:
		label = "Choose a combat building  -  Esc to cancel"
	case .Place:
		label = fmt.ctprintf("Place %s  -  right click to stop", UIBuildingName(ui.buildKind))
		if tile_x, tile_y, ok := UITileAtMouse(w, camera, mouse); ok {
			failure := TownCombatConstructionFailure(
				w,
				ui.buildKingdom,
				ui.buildTown,
				ui.buildKind,
				tile_x,
				tile_y,
			)
			if failure != .None do label = UIPlacementFailureText(failure)
		}
	case .Inspect:
		return
	}

	font := ui_font()
	text_width := rl.MeasureTextEx(font, label, UI_TEXT_SIZE, 1).x
	box := rl.Rectangle{
		clamp(mouse.x+18, 0, f32(rl.GetScreenWidth())-text_width-2*UI_PAD),
		clamp(mouse.y+18, 0, f32(rl.GetScreenHeight())-UI_TEXT_SIZE-2*UI_PAD),
		text_width+2*UI_PAD,
		UI_TEXT_SIZE+2*UI_PAD,
	}
	rl.DrawRectangleRec(box, UI_COLOR_BG)
	rl.DrawRectangleLinesEx(box, 1, UI_COLOR_BORDER)
	ui_text(label, box.x+UI_PAD, box.y+UI_PAD-2, UI_COLOR_TEXT)
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
		ui_text(UIBuildingName(kind), rect.x+44, rect.y+8, UI_COLOR_TEXT)
		cost := BuildingWoodCost(kind)
		cost_label: cstring = "Free"
		cost_color := UI_COLOR_DIM
		if cost > 0 {
			cost_label = fmt.ctprintf("%d wood", int(cost))
			town := &w.kingdoms[ui.buildKingdom].towns[ui.buildTown]
			if town.wood >= cost do cost_color = UI_COLOR_TEXT
			if town.wood < cost do cost_color = UI_COLOR_ATTACK
		}
		ui_text(cost_label, rect.x+44, rect.y+30, cost_color)
	}
}

UIDrawBuildPreview :: proc(w: ^World, renderer: ^WorldRenderer, camera: rl.Camera2D, ui: ^UIState) {
	if ui.command != .Place do return
	tile_x, tile_y, ok := UITileAtMouse(w, camera, rl.GetMousePosition())
	if !ok do return

	kingdom := ui.buildKingdom
	town := ui.buildTown

	width, height := BuildingTileSize(BuildingTypeFromKind(ui.buildKind))
	valid := TownCombatConstructionFailure(w, kingdom, town, ui.buildKind, tile_x, tile_y) == .None
	color := rl.Color{110, 218, 128, 220}
	if !valid do color = rl.Color{228, 92, 82, 220}

	rl.BeginMode2D(camera)
	rect := rl.Rectangle{f32(tile_x), f32(tile_y), f32(width), f32(height)}
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

	tile_x, tile_y, ok := UITileAtMouse(w, camera, rl.GetMousePosition())
	if !ok do return
	width, height := BuildingTileSize(TownHall{})
	valid := TownFoundingFailure(w, kingdom, town, tile_x, tile_y) == .None
	color := rl.Color{110, 218, 128, 220}
	if !valid do color = rl.Color{228, 92, 82, 220}

	rl.BeginMode2D(camera)
	rect := rl.Rectangle{f32(tile_x), f32(tile_y), f32(width), f32(height)}
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

	ui_title("Town Milestone", modal.x+UI_PAD, modal.y+10, UI_COLOR_GOLD)
	ui_text(
		fmt.ctprintf(
			"%s  -  %s  -  %d citizens",
			NameKingdomCString(w, kingdom),
			NameTownCString(w, kingdom, town),
			t.citizens,
		),
		modal.x+UI_PAD,
		modal.y+46,
		UI_COLOR_DIM,
	)

	mouse := rl.GetMousePosition()

	shared_units, shared_unlocks, has_shared := UIMilestoneSharedRewards(w, kingdom, town)
	if has_shared {
		band := rl.Rectangle{
			modal.x+UI_PAD,
			modal.y+82,
			modal.width-2*UI_PAD,
			UI_MILESTONE_SHARED_H-8,
		}
		rl.DrawRectangleRec(band, UI_COLOR_BUTTON_OFF)
		rl.DrawRectangleLinesEx(band, 1, UI_COLOR_BORDER_INNER)

		title: cstring = "Both paths"
		title_width := UIHudTextWidth(title)
		ui_text(title, modal.x+(modal.width-title_width)*0.5, band.y+5, UI_COLOR_GOLD)

		total_width: f32 = 0
		for kind in UnitKind {
			if !(kind in shared_units) do continue
			if total_width > 0 do total_width += 16
			total_width += 24+8+UIHudTextWidth(UIUnitName(kind))
		}
		for kind in BuildingKind {
			if !(kind in shared_unlocks) do continue
			if total_width > 0 do total_width += 16
			total_width += 24+8+UIHudTextWidth(UIBuildingName(kind))
		}

		item_x := modal.x+(modal.width-total_width)*0.5
		item_y := band.y+28
		for kind in UnitKind {
			if !(kind in shared_units) do continue
			texture := renderer.sprites.unit[FactionSpriteIndex(kingdom)][kind]
			if texture.id != 0 {
				source := rl.Rectangle{0, 0, f32(texture.width), f32(texture.height)}
				rl.DrawTexturePro(texture, source, rl.Rectangle{item_x, item_y, 24, 24}, rl.Vector2{0, 0}, 0, rl.WHITE)
			}
			ui_text(UIUnitName(kind), item_x+32, item_y+2, UI_COLOR_TEXT)
			item_x += 24+8+UIHudTextWidth(UIUnitName(kind))+16
		}
		for kind in BuildingKind {
			if !(kind in shared_unlocks) do continue
			texture := renderer.sprites.building[FactionSpriteIndex(kingdom)][kind]
			if texture.id != 0 {
				source := rl.Rectangle{0, 0, f32(texture.width), f32(texture.height)}
				rl.DrawTexturePro(texture, source, rl.Rectangle{item_x, item_y, 24, 24}, rl.Vector2{0, 0}, 0, rl.WHITE)
			}
			ui_text(UIBuildingName(kind), item_x+32, item_y+2, UI_COLOR_TEXT)
			item_x += 24+8+UIHudTextWidth(UIBuildingName(kind))+16
		}
	}

	cards := UIMilestoneCardRects(w, kingdom, town, modal)
	for card, option_index in cards {
		hovered := rl.CheckCollisionPointRec(mouse, card)
		background := hovered ? UI_COLOR_BUTTON_HOVER : UI_COLOR_BUTTON
		rl.DrawRectangleRec(card, background)
		rl.DrawRectangleLinesEx(card, 1, hovered ? UI_COLOR_GOLD : UI_COLOR_BORDER_INNER)

		option, ok := TownMilestoneOption(w, kingdom, town, option_index)
		if !ok do continue

		ui_title(UITownPathName(option.path), card.x+UI_PAD, card.y+8, UI_COLOR_GOLD)
		row := 0
		for kind in UnitKind {
			if !(kind in option.units) || (kind in shared_units) do continue
			row_y := card.y+42+f32(row)*28
			texture := renderer.sprites.unit[FactionSpriteIndex(kingdom)][kind]
			if texture.id != 0 {
				icon := rl.Rectangle{card.x+UI_PAD, row_y+2, 24, 24}
				source := rl.Rectangle{0, 0, f32(texture.width), f32(texture.height)}
				rl.DrawTexturePro(texture, source, icon, rl.Vector2{0, 0}, 0, rl.WHITE)
			}
			ui_text(UIUnitName(kind), card.x+UI_PAD+32, row_y+2, UI_COLOR_TEXT)
			row += 1
		}
		for kind in BuildingKind {
			if !(kind in option.unlocks) || (kind in shared_unlocks) do continue
			row_y := card.y+42+f32(row)*28
			texture := renderer.sprites.building[FactionSpriteIndex(kingdom)][kind]
			if texture.id != 0 {
				icon := rl.Rectangle{card.x+UI_PAD, row_y+2, 24, 24}
				source := rl.Rectangle{0, 0, f32(texture.width), f32(texture.height)}
				rl.DrawTexturePro(texture, source, icon, rl.Vector2{0, 0}, 0, rl.WHITE)
			}
			ui_text(UIBuildingName(kind), card.x+UI_PAD+32, row_y+2, UI_COLOR_TEXT)
			row += 1
		}
		ui_text("Click to choose", card.x+UI_PAD, card.y+card.height-26, UI_COLOR_DIM)
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
	width := rl.MeasureTextEx(ui_font(), label, UI_TEXT_SIZE, 1).x
	rl.DrawTextEx(
		ui_font(),
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
	return rl.MeasureTextEx(ui_font(), text, UI_TEXT_SIZE, 1).x
}

UIHudLineHeight :: proc() -> f32 {
	return rl.MeasureTextEx(ui_font(), "Ag", UI_TEXT_SIZE, 1).y
}

UIHudTimeLabel :: proc(w: ^World) -> cstring {
	return fmt.ctprintf("Day %d  %02dh", w.dayNumber+1, int(WorldTimeOfDay(w)))
}

UIHudWarLabel :: proc(w: ^World) -> cstring {
	war_count := UIWarCount(w)
	if war_count > 0 do return fmt.ctprintf("AT WAR: %d", war_count)
	return "At peace"
}

UIHudRect :: proc(w: ^World) -> rl.Rectangle {
	local := WorldLocalKingdom(w)
	name := local >= 0 ? NameKingdomCString(w, local) : cstring("SPECTATOR")
	name_width := UIHudTextWidth(name)
	time_width := UIHudTextWidth(UIHudTimeLabel(w))
	war_width := UIHudTextWidth(UIHudWarLabel(w))
	line_width := max(name_width, time_width+24+war_width)

	towns_width := UIHudTextWidth("TOWNS")+2*UI_HUD_BUTTON_PAD
	diplomacy_width := UIHudTextWidth("DIPLOMACY")+2*UI_HUD_BUTTON_PAD
	buttons_width := towns_width+8+diplomacy_width

	height := max(UIHudLineHeight()*2, UI_HUD_BUTTON_H)+2*UI_HUD_PAD
	width := UI_HUD_PAD*2+line_width+UI_HUD_GAP+buttons_width
	return rl.Rectangle{
		max(UI_MARGIN, f32(rl.GetScreenWidth())-UI_MARGIN-width),
		UI_MARGIN,
		width,
		height,
	}
}

UIHudTownsButtonRect :: proc(w: ^World) -> rl.Rectangle {
	hud := UIHudRect(w)
	diplomacy_width := UIHudTextWidth("DIPLOMACY")+2*UI_HUD_BUTTON_PAD
	towns_width := UIHudTextWidth("TOWNS")+2*UI_HUD_BUTTON_PAD
	return rl.Rectangle{
		hud.x+hud.width-UI_HUD_PAD-diplomacy_width-8-towns_width,
		hud.y+(hud.height-UI_HUD_BUTTON_H)*0.5,
		towns_width,
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
	for town_slot in 0..<TOWN_CAPACITY {
		if w.kingdoms[local].townUsed[town_slot] do count += 1
	}
	return count
}

UIPlayerTownAt :: proc(w: ^World, index: int) -> (int, bool) {
	local := WorldLocalKingdom(w)
	if index < 0 || local < 0 do return -1, false
	seen := 0
	for town_slot in 0..<TOWN_CAPACITY {
		if !w.kingdoms[local].townUsed[town_slot] do continue
		if seen == index do return town_slot, true
		seen += 1
	}
	return -1, false
}

UIDiplomacyCount :: proc(w: ^World) -> int {
	count := 0
	local := WorldLocalKingdom(w)
	if local < 0 do return 0
	for kingdom_slot in 0..<KINGDOMS_CAPACITY {
		if kingdom_slot == local || !KingdomDiscovered(w, kingdom_slot) do continue
		count += 1
	}
	return count
}

UIDiplomacyAt :: proc(w: ^World, index: int) -> (int, bool) {
	if index < 0 do return -1, false
	local := WorldLocalKingdom(w)
	if local < 0 do return -1, false
	seen := 0
	for kingdom_slot in 0..<KINGDOMS_CAPACITY {
		if kingdom_slot == local || !KingdomDiscovered(w, kingdom_slot) do continue
		if seen == index do return kingdom_slot, true
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
	row_height: f32 = UI_SIDE_ROW_H
	if ui.panel == .Diplomacy do row_height = UI_DIPLO_ROW_H
	height := UI_SIDE_HEADER_H+f32(rows)*row_height+12
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
	for attacker_kingdom in 0..<KINGDOMS_CAPACITY {
		for attacker_town in 0..<TOWN_CAPACITY {
			if orders.attackedBy[attacker_kingdom][attacker_town] do return true
		}
	}
	return false
}

UIWarCount :: proc(w: ^World) -> int {
	local := WorldLocalKingdom(w)
	if local < 0 do return 0
	count := 0
	for kingdom_slot in 0..<KINGDOMS_CAPACITY {
		if KingdomAtWar(w, local, kingdom_slot) do count += 1
	}
	return count
}

UIFocusTown :: proc(w: ^World, view: ^WorldView, kingdom_slot, town_slot: int) {
	hall := TownHallSlot(w, kingdom_slot, town_slot)
	if hall < 0 do return
	width, height := BuildingTileSize(w.buildings[hall].type)
	view.camera.target = rl.Vector2{
		f32(w.buildings[hall].x)+f32(width)*0.5,
		f32(w.buildings[hall].y)+f32(height)*0.5,
	}
	view.ui.command = .Inspect
	view.ui.hover = {}
	view.ui.selection = {}
	if FogTownVisible(w, kingdom_slot, town_slot) {
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
		return fmt.ctprintf("%s founded", UIAlertTownName(&alert.town_name))
	case .TownLost:
		return fmt.ctprintf("%s lost", UIAlertTownName(&alert.town_name))
	case .UnderAttack:
		return fmt.ctprintf("%s under attack", UIAlertTownName(&alert.town_name))
	case .EnemySpotted:
		return fmt.ctprintf("Enemy spotted: %s", NameKingdomCString(w, alert.other))
	case .Milestone:
		return fmt.ctprintf("%s milestone ready", UIAlertTownName(&alert.town_name))
	case .WarDeclared:
		return fmt.ctprintf("War declared on %s", NameKingdomCString(w, alert.other))
	case .PeaceMade:
		return fmt.ctprintf("Peace with %s", NameKingdomCString(w, alert.other))
	}
	return ""
}

UIAlertColor :: proc(kind: AlertKind) -> rl.Color {
	switch kind {
	case .TownFounded:
		return rl.Color{112, 200, 126, 255}
	case .TownLost, .UnderAttack, .WarDeclared, .EnemySpotted:
		return UI_COLOR_ATTACK
	case .Milestone:
		return UI_COLOR_GOLD
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
				max_scroll := max(count-UI_SIDE_MAX_TOWN_ROWS, 0)
				ui.townScroll = clamp(ui.townScroll, 0, max_scroll)

				if rl.IsMouseButtonPressed(.LEFT) && count > UI_SIDE_MAX_TOWN_ROWS {
					prev, next := UITownPageButtonRects(panel)
					if rl.CheckCollisionPointRec(mouse, prev) && ui.townScroll > 0 {
						ui.townScroll = max(ui.townScroll-UI_SIDE_MAX_TOWN_ROWS, 0)
						return true
					}
					if rl.CheckCollisionPointRec(mouse, next) && ui.townScroll < max_scroll {
						ui.townScroll = min(ui.townScroll+UI_SIDE_MAX_TOWN_ROWS, max_scroll)
						return true
					}
				}

				if rl.IsMouseButtonPressed(.LEFT) {
					row := int((mouse.y-(panel.y+UI_SIDE_HEADER_H))/UI_SIDE_ROW_H)
					if row >= 0 && row < min(count, UI_SIDE_MAX_TOWN_ROWS) {
						if town_slot, found := UIPlayerTownAt(w, ui.townScroll+row); found {
							UIFocusTown(w, view, local, town_slot)
						}
					}
				}
			case .Diplomacy:
				if rl.IsMouseButtonPressed(.LEFT) {
					row := int((mouse.y-(panel.y+UI_SIDE_HEADER_H))/UI_DIPLO_ROW_H)
					if row >= 0 && row < UIDiplomacyCount(w) {
						if kingdom_slot, found := UIDiplomacyAt(w, row); found {
							if rl.CheckCollisionPointRec(mouse, UIDiplomacyActionRect(panel, row)) {
								if KingdomAtWar(w, local, kingdom_slot) {
									KingdomIssueCommand(w, local, CommandMakePeace{other = kingdom_slot})
								} else {
									KingdomIssueCommand(w, local, CommandDeclareWar{other = kingdom_slot})
								}
							} else if town_slot, town_found := FogFirstDiscoveredTown(w, kingdom_slot); town_found {
								UIFocusTown(w, view, kingdom_slot, town_slot)
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
			if rl.IsMouseButtonPressed(.LEFT) {
				row := int((mouse.y-(panel.y+UI_SIDE_HEADER_H))/UI_ALERT_ROW_H)
				if row >= 0 && row < min(w.alerts.count, UI_ALERT_MAX_ROWS) {
					if alert, found := WorldAlertNewest(w, row); found {
						UIFocusAlert(w, view, alert)
					}
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
		line_height := UIHudLineHeight()
		title_y := hud.y+UI_HUD_PAD
		detail_y := title_y+line_height
		ui_text("SPECTATING", hud.x+UI_HUD_PAD, title_y, UI_COLOR_GOLD)
		ui_text("ESC  PAUSE", hud.x+UI_HUD_PAD, detail_y, UI_COLOR_DIM)
		winner := w.winnerKingdom
		if winner >= 0 && w.kingdomUsed[winner] {
			ui_text(
				NameKingdomCString(w, winner),
				hud.x+UI_HUD_PAD+120,
				detail_y,
				FactionColor(w, winner),
			)
		}
		return
	}

	rl.DrawRectangleRec(
		rl.Rectangle{hud.x+3, hud.y+3, 4, hud.height-6},
		FactionColor(w, local),
	)

	line_height := UIHudLineHeight()
	text_x := hud.x+UI_HUD_PAD
	title_y := hud.y+UI_HUD_PAD
	detail_y := title_y+line_height

	ui_text(NameKingdomCString(w, local), text_x, title_y, UI_COLOR_GOLD)

	time_label := UIHudTimeLabel(w)
	time_width := UIHudTextWidth(time_label)
	war_label := UIHudWarLabel(w)
	ui_text(time_label, text_x, detail_y, UI_COLOR_DIM)
	ui_text(
		war_label,
		text_x+time_width+24,
		detail_y,
		UIWarCount(w) > 0 ? UI_COLOR_ATTACK : UI_COLOR_DIM,
	)

	towns_rect := UIHudTownsButtonRect(w)
	diplomacy_rect := UIHudDiplomacyButtonRect(w)
	UIButton(towns_rect, "TOWNS", true)
	UIButton(diplomacy_rect, "DIPLOMACY", true)
	if ui.panel == .Towns {
		rl.DrawRectangleLinesEx(towns_rect, 2, UI_COLOR_GOLD)
	}
	if ui.panel == .Diplomacy {
		rl.DrawRectangleLinesEx(diplomacy_rect, 2, UI_COLOR_GOLD)
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
		ui_text("YOUR TOWNS", panel.x+UI_PAD, panel.y+9, UI_COLOR_GOLD)
		count := UIPlayerTownCount(w)
		if count == 0 {
			ui_text("No towns yet.", panel.x+UI_PAD, panel.y+UI_SIDE_HEADER_H+6, UI_COLOR_DIM)
			return
		}
		visible := min(count, UI_SIDE_MAX_TOWN_ROWS)
		for row in 0..<visible {
			town_slot, found := UIPlayerTownAt(w, ui.townScroll+row)
			if !found do continue
			town := &w.kingdoms[local].towns[town_slot]
			row_rect := rl.Rectangle{
				panel.x+8,
				panel.y+UI_SIDE_HEADER_H+f32(row)*UI_SIDE_ROW_H,
				panel.width-16,
				UI_SIDE_ROW_H-2,
			}
			hovered := rl.CheckCollisionPointRec(rl.GetMousePosition(), row_rect)
			if hovered do rl.DrawRectangleRec(row_rect, UI_COLOR_BUTTON_HOVER)
			ui_text(NameTownCString(w, local, town_slot), row_rect.x+6, row_rect.y+4, UI_COLOR_TEXT)
			ui_text_right(
				fmt.ctprintf("C%d  W%d", town.citizens, int(town.wood)),
				row_rect.x+row_rect.width-6,
				row_rect.y+4,
				UI_COLOR_DIM,
			)
			if UITownUnderAttack(w, local, town_slot) {
				ui_text("!", row_rect.x+row_rect.width-132, row_rect.y+4, UI_COLOR_ATTACK)
			}
		}
		if count > UI_SIDE_MAX_TOWN_ROWS {
			prev, next := UITownPageButtonRects(panel)
			UIButton(prev, "PREV", ui.townScroll > 0)
			UIButton(next, "NEXT", ui.townScroll+UI_SIDE_MAX_TOWN_ROWS < count)
		}
	case .Diplomacy:
		ui_text("DIPLOMACY", panel.x+UI_PAD, panel.y+9, UI_COLOR_GOLD)
		count := UIDiplomacyCount(w)
		if count == 0 {
			ui_text("No kingdoms discovered.", panel.x+UI_PAD, panel.y+UI_SIDE_HEADER_H+6, UI_COLOR_DIM)
			return
		}
		for row in 0..<count {
			kingdom_slot, found := UIDiplomacyAt(w, row)
			if !found do continue
			row_rect := rl.Rectangle{
				panel.x+8,
				panel.y+UI_SIDE_HEADER_H+f32(row)*UI_DIPLO_ROW_H,
				panel.width-16,
				UI_DIPLO_ROW_H-2,
			}
			hovered := rl.CheckCollisionPointRec(rl.GetMousePosition(), row_rect)
			if hovered do rl.DrawRectangleRec(row_rect, UI_COLOR_BUTTON_HOVER)
			rl.DrawRectangleRec(
				rl.Rectangle{row_rect.x+6, row_rect.y+8, 10, 24},
				FactionColor(w, kingdom_slot),
			)
			ui_text(NameKingdomCString(w, kingdom_slot), row_rect.x+24, row_rect.y+4, UI_COLOR_TEXT)
			at_war := KingdomAtWar(w, local, kingdom_slot)
			ui_text(
				at_war ? "AT WAR" : "Peace",
				row_rect.x+24,
				row_rect.y+24,
				at_war ? UI_COLOR_ATTACK : UI_COLOR_DIM,
			)
			action := UIDiplomacyActionRect(panel, row)
			UIButton(action, at_war ? "Make Peace" : "Declare War", true)
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
	ui_text("ALERTS", panel.x+UI_PAD, panel.y+9, UI_COLOR_GOLD)

	rows := min(w.alerts.count, UI_ALERT_MAX_ROWS)
	for row in 0..<rows {
		alert, found := WorldAlertNewest(w, row)
		if !found do continue
		row_rect := rl.Rectangle{
			panel.x+8,
			panel.y+UI_SIDE_HEADER_H+f32(row)*UI_ALERT_ROW_H,
			panel.width-16,
			UI_ALERT_ROW_H-2,
		}
		if rl.CheckCollisionPointRec(rl.GetMousePosition(), row_rect) {
			rl.DrawRectangleRec(row_rect, UI_COLOR_BUTTON_HOVER)
		}
		rl.DrawRectangleRec(
			rl.Rectangle{row_rect.x+2, row_rect.y+4, 3, row_rect.height-8},
			UIAlertColor(alert.kind),
		)
		ui_text(UIAlertText(w, &alert), row_rect.x+12, row_rect.y+4, UI_COLOR_TEXT)
	}
}
