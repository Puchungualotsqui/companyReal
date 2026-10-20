package main

import rl "vendor:raylib"
import "core:fmt"

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

UIState :: struct {
	selection: Selection,
	hover:     Selection,
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
UI_HEADER_H : f32 : 92
UI_DESC_Y : f32 : 102
UI_STAT_Y : f32 : 136
UI_STAT_H : f32 : 24
UI_TOWN_DIVIDER : f32 : 242
UI_TOWN_LABEL_Y : f32 : 250
UI_ROWS_TOP : f32 : 282
UI_ROW_HEIGHT : f32 : 36
UI_BUTTON : f32 : 20

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

@(private = "file")
ui_font_ready: bool

ui_font :: proc() -> rl.Font {
	font := rl.GetFontDefault()
	if !ui_font_ready {
		rl.SetTextureFilter(font.texture, .POINT)
		ui_font_ready = true
	}
	return font
}

ui_text :: proc(text: cstring, x, y: f32, color: rl.Color) {
	rl.DrawTextEx(ui_font(), text, rl.Vector2{x, y}, UI_TEXT_SIZE, 1, color)
}

ui_title :: proc(text: cstring, x, y: f32, color: rl.Color) {
	rl.DrawTextEx(ui_font(), text, rl.Vector2{x, y}, 30, 1, color)
}

ui_text_right :: proc(text: cstring, right, y: f32, color: rl.Color) {
	width := rl.MeasureTextEx(ui_font(), text, UI_TEXT_SIZE, 1).x
	rl.DrawTextEx(ui_font(), text, rl.Vector2{right-width, y}, UI_TEXT_SIZE, 1, color)
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
	case .TownHall, .Home, .Farmland, .Wall, .Bridge, .Cannon:
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
		kingdom, _ := UISelectionTown(w, ui.selection)
		if kingdom == PLAYER_KINGDOM {
			rows := UIConversionRowCount(w, ui.selection)
			return UI_ROWS_TOP + f32(rows)*UI_ROW_HEIGHT + UI_PAD
		}
	}
	return UI_STAT_Y + f32(UIStatCount(w, ui.selection))*UI_STAT_H + UI_PAD
}

UIPanelRect :: proc(w: ^World, ui: ^UIState) -> rl.Rectangle {
	height := UIPanelHeight(w, ui)
	screen_height := f32(rl.GetScreenHeight())
	y := max(UI_MARGIN, screen_height-height-UI_MARGIN)
	return rl.Rectangle{UI_MARGIN, y, UI_PANEL_WIDTH, height}
}

UIButtonRects :: proc(panel: rl.Rectangle, index: int) -> (minus, plus: rl.Rectangle) {
	row_y := panel.y+UI_ROWS_TOP+f32(index)*UI_ROW_HEIGHT
	plus = rl.Rectangle{panel.x+panel.width-UI_PAD-UI_BUTTON, row_y+8, UI_BUTTON, UI_BUTTON}
	minus = rl.Rectangle{plus.x-UI_BUTTON-4, plus.y, UI_BUTTON, UI_BUTTON}
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
	if !UISelectionValid(w, ui.selection) do ui.selection = {}
	if rl.IsKeyPressed(.ESCAPE) do ui.selection = {}

	mouse := rl.GetMousePosition()
	panel := UIPanelRect(w, ui)
	if ui.selection.kind != .None && rl.CheckCollisionPointRec(mouse, panel) {
		ui.hover = {}
	} else {
		ui.hover = UIFindAt(w, camera, mouse)
	}

	if !rl.IsMouseButtonPressed(.LEFT) do return
	if ui.selection.kind != .None && rl.CheckCollisionPointRec(mouse, panel) {
		UIConversionClick(w, ui, panel, mouse)
		return
	}
	ui.selection = ui.hover
	if !UISelectionValid(w, ui.selection) do ui.selection = {}
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
	UIDrawHover(w, camera, ui.hover, ui.selection)
	if !UISelectionValid(w, ui.selection) do return
	UIDrawSelection(w, camera, ui.selection)

	panel := UIPanelRect(w, ui)
	UIDrawPanel(w, renderer, ui, panel)
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

	stats: [4]UIStat
	stat_count := UIFillStats(w, ui, &stats)
	for i in 0..<stat_count {
		y := panel.y+UI_STAT_Y+f32(i)*UI_STAT_H
		ui_text(stats[i].label, panel.x+UI_PAD, y, UI_COLOR_DIM)
		ui_text(stats[i].value, panel.x+UI_PAD+104, y, UI_COLOR_TEXT)
	}

	if UISelectionTownHall(w, ui.selection) && kingdom == PLAYER_KINGDOM {
		UIDrawConversions(w, renderer, ui, panel, kingdom, town)
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

UIFillStats :: proc(w: ^World, ui: ^UIState, stats: ^[4]UIStat) -> int {
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
			stats[3] = {"Milestones", fmt.ctprintf("%d / %d", t.milestonesReached, TOWN_MILESTONE_COUNT)}
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

UIDrawConversions :: proc(
	w: ^World,
	renderer: ^WorldRenderer,
	ui: ^UIState,
	panel: rl.Rectangle,
	kingdom, town: int,
) {
	rl.DrawRectangleRec(
		rl.Rectangle{panel.x+UI_PAD, panel.y+UI_TOWN_DIVIDER, panel.width-2*UI_PAD, 1},
		UI_COLOR_DIVIDER,
	)

	villagers := TownUnitCount(w, kingdom, town, .Villager)
	ui_text("VILLAGERS", panel.x+UI_PAD, panel.y+UI_TOWN_LABEL_Y, UI_COLOR_DIM)
	ui_text_right(fmt.ctprintf("%d", villagers), panel.x+panel.width-UI_PAD, panel.y+UI_TOWN_LABEL_Y, UI_COLOR_GOLD)

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
