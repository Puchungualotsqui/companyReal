package main

import rl "vendor:raylib"
import "core:fmt"
import "core:math"

// The player always controls the first kingdom.
PLAYER_KINGDOM :: 0

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
}

UIState :: struct {
	selection: Selection,
	hover:     Selection,
	tab:       UITownTab,
	command:   UICommand,
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
UI_GROWTH_Y : f32 : 240
UI_GROWTH_H : f32 : 20
UI_TOWN_DIVIDER : f32 : 266
UI_TABS_Y : f32 : 274
UI_TABS_H : f32 : 24
UI_SECTION_HEADER : f32 : 26
UI_ROWS_TOP : f32 : 306
UI_ROW_HEIGHT : f32 : 36
UI_BUTTON : f32 : 20
UI_TEXT_BUTTON_H : f32 : 26

UI_TOWN_TABS := [2]cstring{"TOWN", "ORDERS"}

UI_COMMAND_BUTTON_W : f32 : 84
UI_COMMAND_BUTTON_H : f32 : 68
UI_COMMAND_GAP : f32 : 12

UI_COLOR_ATTACK := rl.Color{226, 96, 76, 220}
UI_COLOR_DEFEND := rl.Color{106, 178, 224, 220}
UI_COLOR_ATTACK_FAINT := rl.Color{226, 96, 76, 140}
UI_COLOR_DEFEND_FAINT := rl.Color{106, 178, 224, 140}

UI_CONVERSION_KINDS := [10]UnitKind{
	.Builder,
	.WaterCollector,
	.Farmer,
	.Knight,
	.Archer,
	.Mage,
	.Giant,
	.Turtle,
	.Catapult,
	.Rogue,
}

UIStat :: struct {
	label, value: cstring,
}

UI_FONT_BODY_DATA :: #load("assets/fonts/PixelifySans-Regular.ttf")
UI_FONT_TITLE_DATA :: #load("assets/fonts/PixelifySans-Bold.ttf")

@(private = "file")
ui_fonts: struct {
	body, title: rl.Font,
	loaded:      bool,
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

WorldUIDeinit :: proc() {
	if !ui_fonts.loaded do return
	// A failed load falls back to the shared default font, which must not be freed.
	default_texture := rl.GetFontDefault().texture.id
	if ui_fonts.body.texture.id != default_texture do rl.UnloadFont(ui_fonts.body)
	if ui_fonts.title.texture.id != default_texture do rl.UnloadFont(ui_fonts.title)
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
	case .WaterCollector:
		return "Carries water to the town."
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
	case .TownHall, .Home, .Farmland, .Wall, .Bridge, .Cannon, .Path:
		return .Villager
	}
	unreachable()
}

UISelectionValid :: proc(w: ^World, selection: Selection) -> bool {
	switch selection.kind {
	case .Unit:
		return selection.slot >= 0 && selection.slot < UNIT_CAPACITY &&
			w.unitUsed[selection.slot] && w.units[selection.slot].type != nil
	case .Building:
		return selection.slot >= 0 && selection.slot < BUILDING_CAPACITY &&
			w.buildingUsed[selection.slot]
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
	return kingdom == PLAYER_KINGDOM
}

// --- war orders -----------------------------------------------------------

UIAttackOrderValid :: proc(w: ^World, kingdom, town, target_kingdom, target_town: int) -> bool {
	if kingdom == target_kingdom do return false
	if !WorldTownExists(w, kingdom, town) || !WorldTownExists(w, target_kingdom, target_town) {
		return false
	}
	if w.kingdoms[kingdom].towns[town].attackOrders[target_kingdom][target_town] {
		return false
	}
	return TownHallSlot(w, target_kingdom, target_town) >= 0
}

UIDefendOrderValid :: proc(
	w: ^World,
	kingdom, town, target_kingdom, target_town: int,
) -> bool {
	if kingdom != target_kingdom do return false
	if town == target_town do return false
	if !WorldTownExists(w, kingdom, town) || !WorldTownExists(w, target_kingdom, target_town) {
		return false
	}
	if KingdomAtWar(w, kingdom, target_kingdom) do return false
	if w.kingdoms[kingdom].towns[town].defendOrders[target_town] do return false
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
	if !w.kingdomUsed[kingdom] do return false
	for target_town in 0..<TOWN_CAPACITY {
		if !w.kingdoms[kingdom].townUsed[target_town] do continue
		if UIDefendOrderValid(w, kingdom, town, kingdom, target_town) do return true
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
	for target_town in 0..<TOWN_CAPACITY {
		if !orders.defendOrders[target_town] do continue
		if target_town != town && WorldTownExists(w, kingdom, target_town) do count += 1
	}
	return count
}

// Orders are listed attacks first, then defends.
UITownOrderAt :: proc(
	w: ^World,
	kingdom, town, index: int,
) -> (
	attack: bool,
	target_kingdom, target_town: int,
	ok: bool,
) {
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
	for other_town in 0..<TOWN_CAPACITY {
		if !orders.defendOrders[other_town] do continue
		if other_town == town || !WorldTownExists(w, kingdom, other_town) do continue
		if count == index do return false, kingdom, other_town, true
		count += 1
	}
	return false, -1, -1, false
}

// --- milestone ------------------------------------------------------------

// The player's first town with an unresolved milestone owns the choice window.
UIMilestoneTown :: proc(w: ^World) -> (kingdom, town: int, pending: bool) {
	if !w.kingdomUsed[PLAYER_KINGDOM] do return -1, -1, false
	for town_slot in 0..<TOWN_CAPACITY {
		if !w.kingdoms[PLAYER_KINGDOM].townUsed[town_slot] do continue
		t := &w.kingdoms[PLAYER_KINGDOM].towns[town_slot]
		if t.milestonePending && t.milestonesReached < TOWN_MILESTONE_COUNT {
			return PLAYER_KINGDOM, town_slot, true
		}
	}
	return -1, -1, false
}

UIMilestoneRect :: proc() -> rl.Rectangle {
	width: f32 = 620
	height: f32 = 250
	screen_width := f32(rl.GetScreenWidth())
	screen_height := f32(rl.GetScreenHeight())
	return rl.Rectangle{(screen_width-width)*0.5, (screen_height-height)*0.5, width, height}
}

UIMilestoneCardRects :: proc(modal: rl.Rectangle) -> [2]rl.Rectangle {
	card_width := (modal.width-3*UI_PAD)*0.5
	top := modal.y+82
	height := modal.height-82-UI_PAD
	return [2]rl.Rectangle{
		{modal.x+UI_PAD, top, card_width, height},
		{modal.x+2*UI_PAD+card_width, top, card_width, height},
	}
}

// --- layout ---------------------------------------------------------------

UIConversionRows :: proc(w: ^World, selection: Selection, kinds: ^[10]UnitKind) -> int {
	kingdom, town := UISelectionTown(w, selection)
	count := 0
	for kind in UI_CONVERSION_KINDS {
		if TownUnitAvailable(w, kingdom, town, kind) || TownUnitCount(w, kingdom, town, kind) > 0 {
			kinds[count] = kind
			count += 1
		}
	}
	return count
}

UIConversionRowCount :: proc(w: ^World, selection: Selection) -> int {
	kinds: [10]UnitKind
	return UIConversionRows(w, selection, &kinds)
}

UIStatCount :: proc(w: ^World, selection: Selection) -> int {
	switch selection.kind {
	case .Unit:
		return 2
	case .Building:
		if UISelectionTownHall(w, selection) do return 4
		kind := BuildingKindOf(w.buildings[selection.slot].type)
		if BuildingIsTraining(kind) do return 2
		return 1
	case .None:
		return 0
	}
	return 0
}

UIPanelHeight :: proc(w: ^World, ui: ^UIState) -> f32 {
	if ui.selection.kind == .None do return 0
	if UISelectionTownHall(w, ui.selection) {
		kingdom, town := UISelectionTown(w, ui.selection)
		if kingdom == PLAYER_KINGDOM {
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
	return UI_STAT_Y + f32(UIStatCount(w, ui.selection))*UI_STAT_H + UI_PAD
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

UICommandBarRects :: proc() -> (attack, defend: rl.Rectangle) {
	total := 2*UI_COMMAND_BUTTON_W+UI_COMMAND_GAP
	x := (f32(rl.GetScreenWidth())-total)*0.5
	y := f32(rl.GetScreenHeight())-UI_MARGIN-UI_COMMAND_BUTTON_H
	attack = rl.Rectangle{x, y, UI_COMMAND_BUTTON_W, UI_COMMAND_BUTTON_H}
	defend = rl.Rectangle{x+UI_COMMAND_BUTTON_W+UI_COMMAND_GAP, y, UI_COMMAND_BUTTON_W, UI_COMMAND_BUTTON_H}
	return
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

UICanConvertTo :: proc(w: ^World, kingdom, town: int, kind: UnitKind) -> bool {
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
		ui.command = .Inspect
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

	over_command_bar := false
	if UISelectionPlayerTownHall(w, ui.selection) {
		attack_rect, defend_rect := UICommandBarRects()
		if rl.CheckCollisionPointRec(mouse, attack_rect) ||
			rl.CheckCollisionPointRec(mouse, defend_rect) {
			over_command_bar = true
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
		if !UISelectionPlayerTownHall(w, ui.selection) {
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
	if over_command_bar {
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
			TownStartAttack(w, kingdom, town, target_kingdom, target_town)
		} else {
			TownStartDefending(w, kingdom, town, target_town)
		}
		ui.command = .Inspect

	case .Inspect:
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
			TownStopAttack(w, kingdom, town, target_kingdom, target_town)
		} else {
			TownStopDefending(w, kingdom, town, target_town)
		}
		return
	}
}

UICommandBarPress :: proc(w: ^World, ui: ^UIState, mouse: rl.Vector2) {
	kingdom, town := UISelectionTown(w, ui.selection)
	attack_rect, defend_rect := UICommandBarRects()
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
	}
}

UIMilestoneClick :: proc(w: ^World, kingdom, town: int, mouse: rl.Vector2) {
	modal := UIMilestoneRect()
	cards := UIMilestoneCardRects(modal)
	for card, option in cards {
		if rl.CheckCollisionPointRec(mouse, card) {
			TownChooseMilestone(w, kingdom, town, option)
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
	if slot >= 0 && slot < BUILDING_CAPACITY && w.buildingUsed[slot] {
		return Selection{kind = .Building, slot = slot}
	}
	return {}
}

UIFindTownAt :: proc(
	w: ^World,
	camera: rl.Camera2D,
	mouse: rl.Vector2,
) -> (
	kingdom, town, hall_slot: int,
	found: bool,
) {
	selection := UIFindBuildingAt(w, camera, mouse)
	if selection.kind != .Building do return -1, -1, -1, false
	kingdom = w.buildings[selection.slot].kingdom
	town = w.buildings[selection.slot].town
	if !WorldTownExists(w, kingdom, town) do return -1, -1, -1, false
	hall_slot = TownHallSlot(w, kingdom, town)
	if hall_slot < 0 do return -1, -1, -1, false
	return kingdom, town, hall_slot, true
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
		if slot >= 0 && slot < BUILDING_CAPACITY && w.buildingUsed[slot] {
			return Selection{kind = .Building, slot = slot}
		}
	}
	return {}
}

UIConversionClick :: proc(w: ^World, ui: ^UIState, panel: rl.Rectangle, mouse: rl.Vector2) {
	if !UISelectionTownHall(w, ui.selection) do return
	kingdom, town := UISelectionTown(w, ui.selection)
	if kingdom != PLAYER_KINGDOM do return

	kinds: [10]UnitKind
	count := UIConversionRows(w, ui.selection, &kinds)
	for i in 0..<count {
		kind := kinds[i]
		minus, plus := UIButtonRects(panel, i)
		if rl.CheckCollisionPointRec(mouse, plus) {
			if UICanConvertTo(w, kingdom, town, kind) {
				TownAddConversion(w, kingdom, town, .Villager, kind, 1)
			}
			return
		}
		if rl.CheckCollisionPointRec(mouse, minus) {
			if UICanConvertFrom(w, kingdom, town, kind) {
				TownAddConversion(w, kingdom, town, kind, .Villager, 1)
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
	}
	UIDrawCommandHint(ui)

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

UIDrawTownAreaFor :: proc(
	w: ^World,
	camera: rl.Camera2D,
	kingdom, town_slot: int,
	faint: bool,
) {
	if !WorldTownExists(w, kingdom, town_slot) do return
	town := &w.kingdoms[kingdom].towns[town_slot]

	accent := FactionColor(kingdom)
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
	accent := FactionColor(kingdom)

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
	ui_text(fmt.ctprintf("Kingdom %d  -  Town %d", kingdom+1, town+1), title_x, panel.y+48, UI_COLOR_DIM)

	switch ui.selection.kind {
	case .Unit:
		ui_text(UIUnitDescription(UnitKindOf(w.units[ui.selection.slot].type)), panel.x+UI_PAD, panel.y+UI_DESC_Y, UI_COLOR_TEXT)
	case .Building:
		ui_text(UIBuildingDescription(BuildingKindOf(w.buildings[ui.selection.slot].type)), panel.x+UI_PAD, panel.y+UI_DESC_Y, UI_COLOR_TEXT)
	case .None:
	}

	stats: [5]UIStat
	stat_count := UIFillStats(w, ui, &stats)
	for i in 0..<stat_count {
		y := panel.y+UI_STAT_Y+f32(i)*UI_STAT_H
		ui_text(stats[i].label, panel.x+UI_PAD, y, UI_COLOR_DIM)
		ui_text(stats[i].value, panel.x+UI_PAD+104, y, UI_COLOR_TEXT)
	}

	if UISelectionTownHall(w, ui.selection) {
		UIDrawGrowthBar(w, panel, kingdom, town)
		if kingdom == PLAYER_KINGDOM {
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

UIFillStats :: proc(w: ^World, ui: ^UIState, stats: ^[5]UIStat) -> int {
	switch ui.selection.kind {
	case .Unit:
		unit := w.units[ui.selection.slot]
		stats[0] = {"Health", fmt.ctprintf("%d / %d", int(unit.health), int(UnitDefaultHealth(unit.type)))}
		stats[1] = {"Task", UIUnitStateName(unit.state)}
		return 2

	case .Building:
		building := w.buildings[ui.selection.slot]
		kind := BuildingKindOf(building.type)
		stats[0] = {"Health", fmt.ctprintf("%d / %d", int(building.health), int(BuildingDefaultHealth(building.type)))}
		if kind == .TownHall {
			t := &w.kingdoms[building.kingdom].towns[building.town]
			stats[1] = {"Citizens", fmt.ctprintf("%d", t.citizens)}
			stats[2] = {"Wood", fmt.ctprintf("%d", int(t.wood))}
			if t.milestonesReached < TOWN_MILESTONE_COUNT {
				stats[3] = {
					"Milestone",
					fmt.ctprintf("%d / %d", t.citizens, TOWN_MILESTONES[t.milestonesReached]),
				}
			} else {
				stats[3] = {"Milestone", "Complete"}
			}
			return 4
		}
		if BuildingIsTraining(kind) {
			stats[1] = {"Trains", UIUnitName(UIUnitFromTraining(kind))}
			return 2
		}
		return 1

	case .None:
	}
	return 0
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

UIDrawConversions :: proc(
	w: ^World,
	renderer: ^WorldRenderer,
	ui: ^UIState,
	panel: rl.Rectangle,
	kingdom, town: int,
) {
	kinds: [10]UnitKind
	count := UIConversionRows(w, ui.selection, &kinds)
	for i in 0..<count {
		UIDrawConversionRow(w, renderer, ui, panel, i, kinds[i], kingdom, town)
	}
}

UIDrawConversionRow :: proc(
	w: ^World,
	renderer: ^WorldRenderer,
	ui: ^UIState,
	panel: rl.Rectangle,
	index: int,
	kind: UnitKind,
	kingdom, town: int,
) {
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
	pending := UIConversionPending(w, kingdom, town, kind)
	if pending != 0 {
		ui_text(fmt.ctprintf("%+d", pending), minus.x-56, row_y+8, UI_COLOR_GOLD)
	}
	unit_count := TownUnitCount(w, kingdom, town, kind)
	ui_text_right(fmt.ctprintf("%d", unit_count), minus.x-8, row_y+8, UI_COLOR_TEXT)

	UIButton(minus, "-", UICanConvertFrom(w, kingdom, town, kind))
	UIButton(plus, "+", UICanConvertTo(w, kingdom, town, kind))
}

UIDrawOrdersTab :: proc(
	w: ^World,
	renderer: ^WorldRenderer,
	panel: rl.Rectangle,
	kingdom, town: int,
) {
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

		label := attack ? fmt.ctprintf("Attack  K%d T%d", target_kingdom+1, target_town+1) : fmt.ctprintf("Defend  K%d T%d", target_kingdom+1, target_town+1)
		label_color := attack ? UI_COLOR_ATTACK : UI_COLOR_DEFEND
		ui_text(label, panel.x+UI_PAD+38, row_y+8, label_color)
		UIButton(UIOrderCancelRect(panel, index), "Cancel", true)
	}
}

UIDrawCommandBar :: proc(w: ^World, ui: ^UIState) {
	if !UISelectionPlayerTownHall(w, ui.selection) do return
	kingdom, town := UISelectionTown(w, ui.selection)
	attack_rect, defend_rect := UICommandBarRects()
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
		border = command == .Attack ? UI_COLOR_ATTACK : UI_COLOR_DEFEND
		border_width = 2
	}
	rl.DrawRectangleLinesEx(rect, border_width, border)

	icon_color := command == .Attack ? UI_COLOR_ATTACK : UI_COLOR_DEFEND
	if !enabled do icon_color = UI_COLOR_DISABLED_TEXT
	center_x := rect.x+rect.width*0.5
	center_y := rect.y+23
	switch command {
	case .Attack:
		UIDrawAttackIcon(center_x, center_y, icon_color)
	case .Defend:
		UIDrawDefendIcon(center_x, center_y, icon_color)
	case .Inspect:
	}

	label: cstring = "ATTACK"
	if command == .Defend do label = "DEFEND"
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

UIDrawTownHallOutline :: proc(
	w: ^World,
	camera: rl.Camera2D,
	kingdom, town: int,
	alpha: u8,
	pixel_width: f32,
) {
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
	for defender_town in 0..<TOWN_CAPACITY {
		if !orders.defendedBy[defender_town] do continue
		if defender_town == town || !WorldTownExists(w, kingdom, defender_town) do continue
		UIDrawOrderArrow(
			w,
			camera,
			kingdom,
			defender_town,
			kingdom,
			town,
			UI_COLOR_DEFEND_FAINT,
			false,
		)
	}

	for target_kingdom in 0..<KINGDOMS_CAPACITY {
		for target_town in 0..<TOWN_CAPACITY {
			if !orders.attackOrders[target_kingdom][target_town] do continue
			if !WorldTownExists(w, target_kingdom, target_town) do continue
			UIDrawOrderArrow(w, camera, kingdom, town, target_kingdom, target_town, UI_COLOR_ATTACK, false)
		}
	}
	for target_town in 0..<TOWN_CAPACITY {
		if !orders.defendOrders[target_town] do continue
		if target_town == town || !WorldTownExists(w, kingdom, target_town) do continue
		UIDrawOrderArrow(w, camera, kingdom, town, kingdom, target_town, UI_COLOR_DEFEND, false)
	}
}

// Arrows are drawn in screen space so their heads keep a constant size at any zoom.
UIDrawOrderArrow :: proc(
	w: ^World,
	camera: rl.Camera2D,
	from_kingdom, from_town, to_kingdom, to_town: int,
	color: rl.Color,
	preview: bool,
) {
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

UIDrawCommandHint :: proc(ui: ^UIState) {
	if ui.command == .Inspect do return

	mouse := rl.GetMousePosition()
	attack_rect, defend_rect := UICommandBarRects()
	if rl.CheckCollisionPointRec(mouse, attack_rect) ||
		rl.CheckCollisionPointRec(mouse, defend_rect) {
		return
	}

	label: cstring
	switch ui.command {
	case .Attack:
		label = "Click a building of an enemy town  -  Esc to cancel"
	case .Defend:
		label = "Click a building of a friendly town  -  Esc to cancel"
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
	rl.DrawRectangleRec(rl.Rectangle{modal.x+3, modal.y+3, 4, 72}, FactionColor(kingdom))
	rl.DrawRectangleRec(
		rl.Rectangle{modal.x+3, modal.y+74, modal.width-6, 1},
		UI_COLOR_BORDER_INNER,
	)

	ui_title("Town Milestone", modal.x+UI_PAD, modal.y+10, UI_COLOR_GOLD)
	ui_text(
		fmt.ctprintf("Kingdom %d  -  Town %d  -  %d citizens", kingdom+1, town+1, t.citizens),
		modal.x+UI_PAD,
		modal.y+46,
		UI_COLOR_DIM,
	)

	mouse := rl.GetMousePosition()
	cards := UIMilestoneCardRects(modal)
	for card, option_index in cards {
		hovered := rl.CheckCollisionPointRec(mouse, card)
		background := hovered ? UI_COLOR_BUTTON_HOVER : UI_COLOR_BUTTON
		rl.DrawRectangleRec(card, background)
		rl.DrawRectangleLinesEx(card, 1, hovered ? UI_COLOR_GOLD : UI_COLOR_BORDER_INNER)

		option, ok := TownMilestoneOption(w, kingdom, town, option_index)
		if !ok do continue

		ui_title(UITownPathName(option.path), card.x+UI_PAD, card.y+8, UI_COLOR_GOLD)
		row := 0
		for kind in BuildingKind {
			if !(kind in option.unlocks) do continue
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
