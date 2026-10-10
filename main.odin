package main

import rl "vendor:raylib"

main :: proc() {
	rl.InitWindow(WINDOW_WIDTH, WINDOW_HEIGHT, "COMPANIA REAL")
	defer rl.CloseWindow()
	rl.SetTargetFPS(TARGET_FPS)

	world: World
	WorldInit(&world)
	defer WorldDeinit(&world)

	SquadSpawnOwned(&world, LOCAL_PLAYER_ID, .A, .Line, 8, Vec2{6, 8})
	SquadSpawnOwned(&world, PLAYER_TWO_ID, .B, .Line, 8, Vec2{18, 8})
	BuildingPlaceOwned(&world, LOCAL_PLAYER_ID, .A, .Headquarters, Vec2{4, 4})
	infantry_production := BuildingPlaceOwned(&world, LOCAL_PLAYER_ID, .A, .InfantryProduction, Vec2{8, 4})
	BuildingPlaceOwned(&world, LOCAL_PLAYER_ID, .A, .SupplyDepot, Vec2{12, 4})
	BuildingPlaceOwned(&world, LOCAL_PLAYER_ID, .A, .ReinforcementCenter, Vec2{16, 4})
	BuildingPlaceOwned(&world, LOCAL_PLAYER_ID, .A, .ObservationPost, Vec2{20, 4})
	BuildingPlaceOwned(&world, LOCAL_PLAYER_ID, .A, .Defense, Vec2{12, 12})
	artillery := BuildingPlaceOwned(&world, LOCAL_PLAYER_ID, .A, .ArtilleryEmplacement, Vec2{20, 12})
	BuildingPlaceOwned(&world, PLAYER_TWO_ID, .B, .Headquarters, Vec2{252, 252})
	BuildingQueueForPlayer(&world, LOCAL_PLAYER_ID, infantry_production, .Assault)
	ArtilleryFireForPlayer(&world, LOCAL_PLAYER_ID, artillery, Vec2{18, 8})
	commands := CommandStateInit(LOCAL_PLAYER_ID)

	for !rl.WindowShouldClose() {
		dt := rl.GetFrameTime()
		CommandUpdate(&world, &commands, dt)
		WorldUpdate(&world, dt)
		rl.BeginDrawing()
		rl.ClearBackground(COLOR_BACKGROUND)
		DrawBoard(world, commands.camera, commands.selected)
		rl.EndDrawing()
	}
}

