package main

import rl "vendor:raylib"

main :: proc() {
	rl.InitWindow(WINDOW_WIDTH, WINDOW_HEIGHT, "COMPANIA REAL")
	defer rl.CloseWindow()
	rl.SetTargetFPS(TARGET_FPS)

	world: World
	WorldInit(&world)
	defer WorldDeinit(&world)

	SquadSpawn(&world, .A, .Line, 8, Vec2{6, 8}, LOCAL_PLAYER_ID)
	SquadSpawn(&world, .A, .Line, 4, Vec2{70, 8}, LOCAL_PLAYER_ID)
	SquadSpawn(&world, .B, .Line, 8, Vec2{18, 8}, PLAYER_TWO_ID)
	BuildingPlace(&world, .A, .Headquarters, Vec2{4, 4}, LOCAL_PLAYER_ID)
	infantry_production := BuildingPlace(&world, .A, .InfantryProduction, Vec2{8, 4}, LOCAL_PLAYER_ID)
	vehicle_workshop := BuildingPlace(&world, .A, .VehicleWorkshop, Vec2{12, 4}, LOCAL_PLAYER_ID)
	BuildingPlace(&world, .A, .ResourceSite, Vec2{20, 4}, LOCAL_PLAYER_ID, .Materials)
	BuildingPlace(&world, .A, .Refinery, Vec2{28, 4}, LOCAL_PLAYER_ID)
	BuildingPlace(&world, .A, .MunitionsFactory, Vec2{36, 4}, LOCAL_PLAYER_ID)
	BuildingPlace(&world, .A, .Warehouse, Vec2{44, 4}, LOCAL_PLAYER_ID)
	BuildingPlace(&world, .A, .SupplyDepot, Vec2{68, 4}, LOCAL_PLAYER_ID)
	BuildingPlace(&world, .A, .ReinforcementCenter, Vec2{16, 4}, LOCAL_PLAYER_ID)
	BuildingPlace(&world, .A, .ObservationPost, Vec2{20, 20}, LOCAL_PLAYER_ID)
	BuildingPlace(&world, .A, .Defense, Vec2{12, 12}, LOCAL_PLAYER_ID)
	artillery := BuildingPlace(&world, .A, .ArtilleryEmplacement, Vec2{20, 12}, LOCAL_PLAYER_ID)
	BuildingPlace(&world, .B, .Headquarters, Vec2{252, 252}, PLAYER_TWO_ID)
	WorldRequestResourceStockpile(&world, .A, SectorId(2), .Munitions, 100)
	BuildingQueueForPlayer(&world, LOCAL_PLAYER_ID, infantry_production, .Assault)
	BuildingQueueForPlayer(&world, LOCAL_PLAYER_ID, vehicle_workshop, .Vehicle)
	ArtilleryFireForPlayer(&world, LOCAL_PLAYER_ID, artillery, Vec2{18, 8})
	commands := CommandStateInit(LOCAL_PLAYER_ID)

	for !rl.WindowShouldClose() {
		dt := rl.GetFrameTime()
		CommandUpdate(&world, &commands, dt)
		WorldUpdate(&world, dt)
		rl.BeginDrawing()
		rl.ClearBackground(COLOR_BACKGROUND)
		DrawBoard(&world, commands.camera, commands.selected)
		rl.EndDrawing()
	}
}

