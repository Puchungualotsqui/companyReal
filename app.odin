package main

import rl "vendor:raylib"
import "core:fmt"

AppState :: enum {
	MainMenu,
	NewGame,
	Playing,
}

AppOverlay :: enum {
	None,
	Result,
	Pause,
	SpectatorPause,
}

GameResult :: enum {
	None,
	Victory,
	Defeat,
	OtherWinner,
}

NewGameConfig :: struct {
	kingdomCount: int,
	colorIndex:   int,
	spectator:    bool,
	mapSizeIndex: int,
	seed:         u64,
}

AppMapSize :: struct {
	label: cstring,
	tiles: int,
}

APP_MAP_SIZES := [3]AppMapSize {
	{"SMALL", 512},
	{"STANDARD", 768},
	{"LARGE", 1024},
}

APP_MAX_KINGDOMS :: KINGDOMS_CAPACITY

App :: struct {
	state:          AppState,
	overlay:        AppOverlay,
	result:         GameResult,
	resultHandled:  bool,
	quitRequested:  bool,
	config:         NewGameConfig,
	world:          ^World,
	view:           WorldView,
	hasGame:        bool,
	crazyWorld:     bool,
	menuTime:       f32,
}

AppInit :: proc() -> App {
	return App{
		state = .MainMenu,
		config = NewGameConfig{
			kingdomCount = 4,
			colorIndex = 0,
			spectator = false,
			mapSizeIndex = 2,
			seed = AppNewSeed(),
		},
	}
}

AppNewSeed :: proc() -> u64 {
	now := rl.GetTime()
	salt := rl.GetRandomValue(0, max(i32))
	return u64(now*1_000_000) ~ (u64(salt) << 32)+0x9E3779B97F4A7C15
}

AppDeinit :: proc(app: ^App) {
	AppEndGame(app)
	WorldUIDeinit()
}

AppEndGame :: proc(app: ^App) {
	if !app.hasGame do return
	WorldRendererDeinit(&app.view.renderer)
	if app.world != nil {
		WorldDeinit(app.world)
		free(app.world)
		app.world = nil
	}
	app.view = {}
	app.hasGame = false
	app.overlay = .None
}

AppStartGame :: proc(app: ^App) -> bool {
	AppEndGame(app)

	settings := WorldGenerationSettingsDefault()
	settings.seed = app.config.seed
	size := APP_MAP_SIZES[clamp(app.config.mapSizeIndex, 0, len(APP_MAP_SIZES)-1)].tiles

	// Keep the same world density on smaller maps.
	scale := f32(size)/1024.0
	settings.islandCount = max(8, int(f32(settings.islandCount)*scale*scale))
	settings.riverCount = max(4, int(f32(settings.riverCount)*scale*scale))
	settings.lakeCount = max(4, int(f32(settings.lakeCount)*scale*scale))
	settings.biomeSize = max(8, int(f32(settings.biomeSize)*scale))

	world := new(World)
	kingdomCount := clamp(app.config.kingdomCount, 2, APP_MAX_KINGDOMS)
	if !WorldInit(world, uint(size), uint(size), uint(kingdomCount), settings) {
		WorldDeinit(world)
		free(world)
		return false
	}
	if app.crazyWorld {
		WorldCrazyWorldPopulate(world)
	}

	localKingdom := app.config.spectator ? -1 : 0
	localColor := KINGDOM_COLOR_PALETTE[
		clamp(app.config.colorIndex, 0, len(KINGDOM_COLOR_PALETTE)-1)
	]
	AssignKingdomColors(localKingdom, localColor, &world.kingdomColors)
	WorldConfigureGame(world, localKingdom, app.config.spectator)
	FogUpdate(world)

	app.world = world
	app.view = WorldViewInit(world)
	app.hasGame = true
	app.state = .Playing
	app.overlay = .None
	app.result = .None
	app.resultHandled = false
	return true
}

AppContinueSpectating :: proc(app: ^App) {
	if app.world == nil do return
	WorldEnterSpectator(app.world)
	app.view.ui = {}
	app.overlay = .None
	app.result = .None
}

AppResultFromWorld :: proc(w: ^World) -> GameResult {
	if w.playerKingdom >= 0 && !w.kingdomUsed[w.playerKingdom] do return .Defeat
	if w.playerKingdom >= 0 && w.winnerKingdom == w.playerKingdom do return .Victory
	return .OtherWinner
}

AppUpdate :: proc(app: ^App, deltaTime: f32) {
	app.menuTime += deltaTime

	switch app.state {
	case .MainMenu, .NewGame:
		AppMenuUpdate(app)
	case .Playing:
		if !app.hasGame do return
		if app.overlay == .Result {
			AppResultOverlayUpdate(app)
			return
		}
		if app.overlay == .Pause {
			AppPauseOverlayUpdate(app)
			return
		}
		if app.overlay == .SpectatorPause {
			AppPauseOverlayUpdate(app)
			return
		}

		if rl.IsKeyPressed(.ESCAPE) {
			if WorldIsSpectating(app.world) {
				app.overlay = .SpectatorPause
				return
			}
			if app.view.ui.command == .Inspect && app.view.ui.selection.kind == .None &&
				app.view.ui.panel == .None {
				app.overlay = .Pause
				return
			}
		}

		worldStamp := ProfilerBegin("World")
		WorldUpdate(app.world, deltaTime)
		ProfilerEnd(worldStamp)
		if app.world.gameOver && !app.resultHandled {
			app.resultHandled = true
			app.result = AppResultFromWorld(app.world)
			app.overlay = .Result
			return
		}
		viewStamp := ProfilerBegin("View")
		WorldViewUpdate(app.world, &app.view, deltaTime)
		ProfilerEnd(viewStamp)
	}
}

AppDraw :: proc(app: ^App) {
	switch app.state {
	case .MainMenu, .NewGame:
		AppMenuDraw(app)
	case .Playing:
		if !app.hasGame do return
		renderStamp := ProfilerBegin("Render")
		WorldRender(app.world, &app.view.renderer, app.view.camera)
		ProfilerEnd(renderStamp)
		uiStamp := ProfilerBegin("UI")
		WorldUIDraw(app.world, &app.view.renderer, app.view.camera, &app.view.ui)
		ProfilerEnd(uiStamp)
		switch app.overlay {
		case .Result:
			AppDrawResultOverlay(app)
		case .Pause:
			AppDrawPausePanel("PAUSED", "The realm waits.", "RESUME")
		case .SpectatorPause:
			AppDrawPausePanel("SPECTATING", "The simulation continues without you.", "RESUME WATCHING")
		case .None:
		}
	}
}

// --- menu layout ------------------------------------------------------------

AppMainMenuButtonRects :: proc() -> (newGame, quit: rl.Rectangle) {
	screenWidth := f32(rl.GetScreenWidth())
	screenHeight := f32(rl.GetScreenHeight())
	width: f32 = 360
	height: f32 = 62
	x := (screenWidth-width)*0.5
	newGame = rl.Rectangle{x, screenHeight*0.56, width, height}
	quit = rl.Rectangle{x, screenHeight*0.56+height+18, width, height}
	return
}

AppSetupPanelRect :: proc() -> rl.Rectangle {
	screenWidth := f32(rl.GetScreenWidth())
	screenHeight := f32(rl.GetScreenHeight())
	width := min(1040, screenWidth-80)
	height := min(680, screenHeight-60)
	return rl.Rectangle{(screenWidth-width)*0.5, (screenHeight-height)*0.5, width, height}
}

AppSetupRowRect :: proc(panel: rl.Rectangle, row: int) -> rl.Rectangle {
	return rl.Rectangle{panel.x+40, panel.y+104+f32(row)*66, panel.width-80, 54}
}

AppSetupOptionRect :: proc(panel: rl.Rectangle, row, index: int, width: f32 = 108) -> rl.Rectangle {
	rowRect := AppSetupRowRect(panel, row)
	return rl.Rectangle{rowRect.x+220+f32(index)*(width+10), rowRect.y+6, width, 42}
}

AppSetupColorRect :: proc(panel: rl.Rectangle, index: int) -> rl.Rectangle {
	rowRect := AppSetupRowRect(panel, 3)
	return rl.Rectangle{rowRect.x+220+f32(index)*46, rowRect.y+7, 40, 40}
}

AppSetupSeedButtonRect :: proc(panel: rl.Rectangle) -> rl.Rectangle {
	rowRect := AppSetupRowRect(panel, 4)
	return rl.Rectangle{rowRect.x+470, rowRect.y+8, 150, 38}
}

AppSetupStartRect :: proc(panel: rl.Rectangle) -> rl.Rectangle {
	return rl.Rectangle{panel.x+40, panel.y+panel.height-72, 280, 50}
}

AppSetupBackRect :: proc(panel: rl.Rectangle) -> rl.Rectangle {
	return rl.Rectangle{panel.x+340, panel.y+panel.height-72, 150, 50}
}

AppResultButtonRects :: proc(panel: rl.Rectangle) -> [3]rl.Rectangle {
	width: f32 = (panel.width-2*24-2*12)/3
	y := panel.y+panel.height-78
	return [3]rl.Rectangle{
		{panel.x+24, y, width, 50},
		{panel.x+24+width+12, y, width, 50},
		{panel.x+24+2*(width+12), y, width, 50},
	}
}

AppResultPanelRect :: proc() -> rl.Rectangle {
	screenWidth := f32(rl.GetScreenWidth())
	screenHeight := f32(rl.GetScreenHeight())
	width: f32 = 760
	height: f32 = 430
	return rl.Rectangle{(screenWidth-width)*0.5, (screenHeight-height)*0.5, width, height}
}

AppSpectatorPanelRect :: proc() -> rl.Rectangle {
	screenWidth := f32(rl.GetScreenWidth())
	screenHeight := f32(rl.GetScreenHeight())
	width: f32 = 540
	height: f32 = 300
	return rl.Rectangle{(screenWidth-width)*0.5, (screenHeight-height)*0.5, width, height}
}

// --- menu input -------------------------------------------------------------

AppMenuUpdate :: proc(app: ^App) {
	if app.state == .MainMenu {
		newGame, quit := AppMainMenuButtonRects()
		if AppMenuClicked(newGame, true) {
			app.state = .NewGame
			return
		}
		if AppMenuClicked(quit, true) do app.quitRequested = true
		return
	}

	if rl.IsKeyPressed(.ESCAPE) {
		app.state = .MainMenu
		return
	}

	panel := AppSetupPanelRect()
	for index in 0 ..< 4 {
		rect := AppSetupOptionRect(panel, 0, index, 88)
		if AppMenuClicked(rect, true) {
			app.config.kingdomCount = index+2
			return
		}
	}
	for index in 0 ..< len(APP_MAP_SIZES) {
		rect := AppSetupOptionRect(panel, 1, index, 118)
		if AppMenuClicked(rect, true) {
			app.config.mapSizeIndex = index
			return
		}
	}
	for index in 0 ..< 2 {
		rect := AppSetupOptionRect(panel, 2, index, 150)
		if AppMenuClicked(rect, true) {
			app.config.spectator = index == 1
			return
		}
	}
	if !app.config.spectator {
		for index in 0 ..< len(KINGDOM_COLOR_PALETTE) {
			rect := AppSetupColorRect(panel, index)
			if AppMenuClicked(rect, true) {
				app.config.colorIndex = index
				return
			}
		}
	}
	if AppMenuClicked(AppSetupSeedButtonRect(panel), true) {
		app.config.seed = AppNewSeed()
		return
	}
	if AppMenuClicked(AppSetupStartRect(panel), true) {
		_ = AppStartGame(app)
		return
	}
	if AppMenuClicked(AppSetupBackRect(panel), true) {
		app.state = .MainMenu
	}
}

AppMenuClicked :: proc(rect: rl.Rectangle, enabled: bool) -> bool {
	if !enabled do return false
	if !rl.CheckCollisionPointRec(rl.GetMousePosition(), rect) do return false
	return rl.IsMouseButtonPressed(.LEFT)
}

// --- result / spectator overlays -------------------------------------------

AppResultOverlayUpdate :: proc(app: ^App) {
	panel := AppResultPanelRect()
	buttons := AppResultButtonRects(panel)
	if AppMenuClicked(buttons[0], true) {
		AppContinueSpectating(app)
		return
	}
	if AppMenuClicked(buttons[1], true) {
		AppEndGame(app)
		app.state = .NewGame
		return
	}
	if AppMenuClicked(buttons[2], true) {
		AppEndGame(app)
		app.state = .MainMenu
	}
}

AppPauseOverlayUpdate :: proc(app: ^App) {
	panel := AppSpectatorPanelRect()
	resume := rl.Rectangle{panel.x+24, panel.y+panel.height-78, (panel.width-60)*0.5, 50}
	menu := rl.Rectangle{
		panel.x+36+(panel.width-60)*0.5,
		panel.y+panel.height-78,
		(panel.width-60)*0.5,
		50,
	}
	if AppMenuClicked(resume, true) {
		app.overlay = .None
		return
	}
	if AppMenuClicked(menu, true) {
		AppEndGame(app)
		app.state = .MainMenu
		return
	}
	if rl.IsKeyPressed(.ESCAPE) {
		app.overlay = .None
	}
}

// --- menu drawing -----------------------------------------------------------

AppMenuDraw :: proc(app: ^App) {
	screenWidth := f32(rl.GetScreenWidth())
	screenHeight := f32(rl.GetScreenHeight())
	rl.DrawRectangleGradientV(
		0,
		0,
		rl.GetScreenWidth(),
		rl.GetScreenHeight(),
		rl.Color{17, 20, 28, 255},
		rl.Color{35, 27, 30, 255},
	)

	// Faction banners at the right edge.
	barWidth: f32 = 12
	for color, index in KINGDOM_COLOR_PALETTE {
		alpha := u8(32+index*3)
		x := screenWidth-28-f32(index)*18
		rl.DrawRectangleRec(
			rl.Rectangle{x, 0, barWidth, screenHeight},
			rl.Color{color.r, color.g, color.b, alpha},
		)
	}
	rl.DrawRectangleRec(
		rl.Rectangle{0, screenHeight-3, screenWidth, 3},
		rl.Color{UI_COLOR_GOLD.r, UI_COLOR_GOLD.g, UI_COLOR_GOLD.b, 90},
	)

	if app.state == .MainMenu {
		AppDrawMainMenu(app)
	} else {
		AppDrawSetup(app)
	}
}

AppDrawMainMenu :: proc(app: ^App) {
	screenWidth := f32(rl.GetScreenWidth())
	screenHeight := f32(rl.GetScreenHeight())

	AppDrawTextCentered(
		UIMenuFont(),
		56,
		2,
		"COMPANIA REAL",
		screenWidth*0.5,
		screenHeight*0.24,
		UI_COLOR_GOLD,
	)
	AppDrawTextCentered(
		UIFont(),
		UI_TEXT_SIZE,
		1,
		"A living world of crowns, colonies and carnage.",
		screenWidth*0.5,
		screenHeight*0.24+82,
		UI_COLOR_DIM,
	)
	rl.DrawRectangleRec(
		rl.Rectangle{screenWidth*0.5-220, screenHeight*0.24+122, 440, 2},
		UI_COLOR_DIVIDER,
	)

	newGame, quit := AppMainMenuButtonRects()
	AppDrawMenuButton(newGame, "NEW GAME", true, false, true)
	AppDrawMenuButton(quit, "QUIT", true, false, false)

	AppDrawTextCentered(
		UIFont(),
		UI_TEXT_SIZE,
		1,
		"Blood remembers.",
		screenWidth*0.5,
		screenHeight-44,
		UI_COLOR_DISABLED_TEXT,
	)
}

AppDrawSetup :: proc(app: ^App) {
	panel := AppSetupPanelRect()
	rl.DrawRectangleRec(panel, UI_COLOR_BG)
	rl.DrawRectangleLinesEx(panel, 2, UI_COLOR_BORDER)
	rl.DrawRectangleLinesEx(
		rl.Rectangle{panel.x+3, panel.y+3, panel.width-6, panel.height-6},
		1,
		UI_COLOR_BORDER_INNER,
	)

	UITitle("NEW GAME", panel.x+40, panel.y+18, UI_COLOR_GOLD)
	UIText(
		"Choose the shape of the war you want to watch.",
		panel.x+40,
		panel.y+56,
		UI_COLOR_DIM,
	)

	AppSetupLabel(panel, 0, "KINGDOMS")
	for index in 0 ..< 4 {
		rect := AppSetupOptionRect(panel, 0, index, 88)
		AppDrawMenuButton(
			rect,
			fmt.ctprintf("%d", index+2),
			true,
			app.config.kingdomCount == index+2,
			false,
		)
	}

	AppSetupLabel(panel, 1, "MAP")
	for index in 0 ..< len(APP_MAP_SIZES) {
		rect := AppSetupOptionRect(panel, 1, index, 118)
		AppDrawMenuButton(
			rect,
			fmt.ctprintf("%s  %d", APP_MAP_SIZES[index].label, APP_MAP_SIZES[index].tiles),
			true,
			app.config.mapSizeIndex == index,
			false,
		)
	}

	AppSetupLabel(panel, 2, "ROLE")
	AppDrawMenuButton(
		AppSetupOptionRect(panel, 2, 0, 150),
		"PLAY",
		true,
		!app.config.spectator,
		false,
	)
	AppDrawMenuButton(
		AppSetupOptionRect(panel, 2, 1, 150),
		"SPECTATE",
		true,
		app.config.spectator,
		false,
	)

	AppSetupLabel(panel, 3, "YOUR COLOUR")
	if app.config.spectator {
		rowRect := AppSetupRowRect(panel, 3)
		UIText("Observer mode: every kingdom is AI.", rowRect.x+220, rowRect.y+16, UI_COLOR_DIM)
	} else {
		for color, index in KINGDOM_COLOR_PALETTE {
			rect := AppSetupColorRect(panel, index)
			hovered := rl.CheckCollisionPointRec(rl.GetMousePosition(), rect)
			rl.DrawRectangleRec(rect, color)
			rl.DrawRectangleLinesEx(rect, hovered || app.config.colorIndex == index ? 3 : 1, UI_COLOR_BORDER)
			if app.config.colorIndex == index {
				rl.DrawRectangleLinesEx(
					rl.Rectangle{rect.x-3, rect.y-3, rect.width+6, rect.height+6},
					1,
					UI_COLOR_GOLD,
				)
			}
		}
	}

	AppSetupLabel(panel, 4, "SEED")
	rowRect := AppSetupRowRect(panel, 4)
	UIText(
		fmt.ctprintf("%08X", u32(app.config.seed & 0xFFFFFFFF)),
		rowRect.x+220,
		rowRect.y+16,
		UI_COLOR_TEXT,
	)
	AppDrawMenuButton(AppSetupSeedButtonRect(panel), "NEW SEED", true, false, false)

	AppDrawRoster(app, panel)

	AppDrawMenuButton(AppSetupStartRect(panel), "START GAME", true, false, true)
	AppDrawMenuButton(AppSetupBackRect(panel), "BACK", true, false, false)
}

AppSetupLabel :: proc(panel: rl.Rectangle, row: int, label: cstring) {
	rowRect := AppSetupRowRect(panel, row)
	UIText(label, rowRect.x, rowRect.y+14, UI_COLOR_GOLD)
}

AppDrawRoster :: proc(app: ^App, panel: rl.Rectangle) {
	x := panel.x+680
	y := panel.y+112
	UIText("CONTROLLERS", x, y, UI_COLOR_GOLD)

	colors: [KINGDOMS_CAPACITY]rl.Color
	local := app.config.spectator ? -1 : 0
	localColor := KINGDOM_COLOR_PALETTE[
		clamp(app.config.colorIndex, 0, len(KINGDOM_COLOR_PALETTE)-1)
	]
	AssignKingdomColors(local, localColor, &colors)

	count := clamp(app.config.kingdomCount, 2, APP_MAX_KINGDOMS)
	for kingdom in 0 ..< count {
		rowY := y+34+f32(kingdom)*52
		rect := rl.Rectangle{x, rowY, 22, 22}
		rl.DrawRectangleRec(rect, colors[kingdom])
		rl.DrawRectangleLinesEx(rect, 1, UI_COLOR_BORDER)
		role: cstring = "AI"
		isLocal := kingdom == local
		if isLocal do role = "YOU"
		UIText(fmt.ctprintf("Kingdom %d", kingdom+1), x+34, rowY, UI_COLOR_TEXT)
		UIText(role, x+34, rowY+20, isLocal ? UI_COLOR_GOLD : UI_COLOR_DIM)
	}

	total := fmt.ctprintf(
		"%d human  +  %d AI",
		local >= 0 ? 1 : 0,
		count-(local >= 0 ? 1 : 0),
	)
	UIText(total, x, panel.y+panel.height-64, UI_COLOR_DIM)
}

AppDrawMenuButton :: proc(
	rect: rl.Rectangle,
	label: cstring,
	enabled: bool,
	selected: bool,
	primary: bool,
) {
	mouse := rl.GetMousePosition()
	hovered := enabled && rl.CheckCollisionPointRec(mouse, rect)
	background := UI_COLOR_BUTTON
	if hovered do background = UI_COLOR_BUTTON_HOVER
	if selected do background = UI_COLOR_HEADER
	if !enabled do background = UI_COLOR_BUTTON_OFF

	rl.DrawRectangleRec(rect, background)
	border := UI_COLOR_BORDER
	if selected || (hovered && primary) do border = UI_COLOR_GOLD
	rl.DrawRectangleLinesEx(rect, 2, border)
	if primary {
		rl.DrawRectangleRec(
			rl.Rectangle{rect.x+4, rect.y+rect.height-4, rect.width-8, 2},
			selected || hovered ? UI_COLOR_GOLD : UI_COLOR_DIVIDER,
		)
	}

	color := enabled ? UI_COLOR_TEXT : UI_COLOR_DISABLED_TEXT
	if selected do color = UI_COLOR_GOLD
	AppDrawTextCentered(
		UIFont(),
		UI_TEXT_SIZE,
		1,
		label,
		rect.x+rect.width*0.5,
		rect.y+(rect.height-UI_TEXT_SIZE)*0.5,
		color,
	)
}

AppDrawTextCentered :: proc(
	font: rl.Font,
	size: f32,
	spacing: f32,
	text: cstring,
	centerX, y: f32,
	color: rl.Color,
) {
	width := rl.MeasureTextEx(font, text, size, spacing).x
	rl.DrawTextEx(font, text, rl.Vector2{centerX-width*0.5, y}, size, spacing, color)
}

// --- result overlay ---------------------------------------------------------

AppDrawResultOverlay :: proc(app: ^App) {
	rl.DrawRectangle(0, 0, rl.GetScreenWidth(), rl.GetScreenHeight(), rl.Color{0, 0, 0, 190})
	panel := AppResultPanelRect()
	rl.DrawRectangleRec(panel, UI_COLOR_BG)
	rl.DrawRectangleLinesEx(panel, 2, UI_COLOR_BORDER)
	rl.DrawRectangleLinesEx(
		rl.Rectangle{panel.x+3, panel.y+3, panel.width-6, panel.height-6},
		1,
		UI_COLOR_BORDER_INNER,
	)

	title: cstring
	subtitle: cstring
	accent := UI_COLOR_GOLD
	winner := app.world.winnerKingdom
	winnerName: cstring = "No kingdom remains"
	if winner >= 0 && app.world.kingdomUsed[winner] {
		winnerName = NameKingdomCString(app.world, winner)
	}

	switch app.result {
	case .Victory:
		title = "VICTORY"
		subtitle = "The realm is yours."
	case .Defeat:
		title = "DEFEAT"
		subtitle = "Your kingdom has fallen."
		accent = UI_COLOR_ATTACK
	case .OtherWinner:
		title = "A KINGDOM PREVAILS"
		subtitle = fmt.ctprintf("%s rules what remains.", winnerName)
	case .None:
		title = "THE WAR ENDS"
		subtitle = winnerName
	}

	AppDrawTextCentered(
		UIMenuFont(),
		56,
		2,
		title,
		panel.x+panel.width*0.5,
		panel.y+48,
		accent,
	)
	AppDrawTextCentered(
		UIFont(),
		UI_TEXT_SIZE,
		1,
		subtitle,
		panel.x+panel.width*0.5,
		panel.y+132,
		UI_COLOR_TEXT,
	)

	if app.result == .Defeat {
		AppDrawTextCentered(
			UIFont(),
			UI_TEXT_SIZE,
			1,
			"The war continues without you.",
			panel.x+panel.width*0.5,
			panel.y+174,
			UI_COLOR_DIM,
		)
	} else if app.result == .OtherWinner {
		AppDrawTextCentered(
			UIFont(),
			UI_TEXT_SIZE,
			1,
			fmt.ctprintf("Last crown standing: %s", winnerName),
			panel.x+panel.width*0.5,
			panel.y+174,
			UI_COLOR_DIM,
		)
	}

	buttons := AppResultButtonRects(panel)
	AppDrawMenuButton(buttons[0], "CONTINUE WATCHING", true, false, true)
	AppDrawMenuButton(buttons[1], "NEW GAME", true, false, false)
	AppDrawMenuButton(buttons[2], "MAIN MENU", true, false, false)

	UIText(
		"Continue watching hands every kingdom to the AI and reveals the map.",
		panel.x+24,
		panel.y+panel.height-112,
		UI_COLOR_DIM,
	)
}

AppDrawPausePanel :: proc(title: cstring, subtitle: cstring, resumeLabel: cstring) {
	rl.DrawRectangle(0, 0, rl.GetScreenWidth(), rl.GetScreenHeight(), rl.Color{0, 0, 0, 180})
	panel := AppSpectatorPanelRect()
	rl.DrawRectangleRec(panel, UI_COLOR_BG)
	rl.DrawRectangleLinesEx(panel, 2, UI_COLOR_BORDER)
	rl.DrawRectangleLinesEx(
		rl.Rectangle{panel.x+3, panel.y+3, panel.width-6, panel.height-6},
		1,
		UI_COLOR_BORDER_INNER,
	)

	AppDrawTextCentered(
		UIMenuFont(),
		42,
		2,
		title,
		panel.x+panel.width*0.5,
		panel.y+42,
		UI_COLOR_GOLD,
	)
	AppDrawTextCentered(
		UIFont(),
		UI_TEXT_SIZE,
		1,
		subtitle,
		panel.x+panel.width*0.5,
		panel.y+104,
		UI_COLOR_DIM,
	)

	resume := rl.Rectangle{panel.x+24, panel.y+panel.height-78, (panel.width-60)*0.5, 50}
	menu := rl.Rectangle{
		panel.x+36+(panel.width-60)*0.5,
		panel.y+panel.height-78,
		(panel.width-60)*0.5,
		50,
	}
	AppDrawMenuButton(resume, resumeLabel, true, false, true)
	AppDrawMenuButton(menu, "MAIN MENU", true, false, false)
}
