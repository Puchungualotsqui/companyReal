package main

import "core:math"

WorldLandPlate :: struct {
	x, y: f32,
	land: bool,
}

WorldPlateElevation :: proc(x, y, width, height: f32, plates: []WorldLandPlate) -> f32 {
	landDistance := width*width+height*height
	oceanDistance := landDistance
	for plate in plates {
		dx := abs(x-plate.x)
		dy := abs(y-plate.y)
		dx = min(dx, abs(width-dx))
		dy = min(dy, abs(height-dy))
		distance := dx*dx+dy*dy
		if plate.land {
			landDistance = min(landDistance, distance)
		} else {
			oceanDistance = min(oceanDistance, distance)
		}
	}
	return (oceanDistance-landDistance)/(oceanDistance+landDistance+1)
}

WorldStampIsland :: proc(field: []f32, width, height: int, centerX, centerY, radius: f32) {
	extent := int(radius)+2
	for dx in -extent..=extent {
		for dy in -extent..=extent {
			value := 1-(f32(dx*dx+dy*dy))/(radius*radius)
			if value <= 0 do continue
			x := WorldWrapCoordinate(int(centerX)+dx, width)
			y := WorldWrapCoordinate(int(centerY)+dy, height)
			field[x*height+y] = max(field[x*height+y], value)
		}
	}
}

WorldGenerationSettings :: struct {
	seed: u64,
	landThreshold: f32,
	// Moisture below this value becomes desert on inland lowlands.
	sandThreshold: f32,
	// Approximate width in tiles of the broad inland biome patches.
	biomeSize: int,
	islandCount: int,
	beachWidth: int,
	riverCount: int,
	lakeCount: int,
	minLakeRadius: int,
	maxLakeRadius: int,
}

WorldGenerationSettingsDefault :: proc() -> WorldGenerationSettings {
	return WorldGenerationSettings{
		seed = 1,
		landThreshold = 0.08,
		sandThreshold = 0.34,
		biomeSize = 10,
		islandCount = 85,
		beachWidth = 2,
		riverCount = 28,
		lakeCount = 24,
		minLakeRadius = 3,
		maxLakeRadius = 8,
	}
}

WorldGenerate :: proc(w: ^World, settings: WorldGenerationSettings) {
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 do return

	biomeSize := max(settings.biomeSize, 8)
	biomeDetailSize := max(biomeSize/3, 4)
	biomeCellsX := max(1, worldWidth/biomeSize)
	biomeCellsY := max(1, worldHeight/biomeSize)
	detailCellsX := max(1, worldWidth/biomeDetailSize)
	detailCellsY := max(1, worldHeight/biomeDetailSize)

	// Competing land and ocean plates produce asymmetric continents without a
	// radial falloff. Their boundaries wrap with the world and are warped below.
	columns := max(2, worldWidth/85)
	rows := max(2, worldHeight/85)
	plates := make([dynamic]WorldLandPlate, columns*rows)
	defer delete(plates)
	for column in 0..<columns {
		for row in 0..<rows {
			index := column*rows+row
			plates[index] = WorldLandPlate{
				x = (f32(column)+0.12+WorldNoiseHash(index, 0, settings.seed+101)*0.76)*f32(worldWidth)/f32(columns),
				y = (f32(row)+0.12+WorldNoiseHash(index, 1, settings.seed+101)*0.76)*f32(worldHeight)/f32(rows),
				land = WorldNoiseHash(index, 2, settings.seed+101) < 0.29,
			}
		}
	}
	plates[0].land = true
	plates[1].land = false

	field := make([dynamic]f32, worldWidth*worldHeight)
	defer delete(field)
	for x in 0..<worldWidth {
		for y in 0..<worldHeight {
			warpX := (WorldPeriodicNoise(x, y, worldWidth, worldHeight, 6, 6, settings.seed+11)-0.5)*70 +
				(WorldPeriodicNoise(x, y, worldWidth, worldHeight, 17, 17, settings.seed+19)-0.5)*30
			warpY := (WorldPeriodicNoise(x, y, worldWidth, worldHeight, 6, 6, settings.seed+23)-0.5)*70 +
				(WorldPeriodicNoise(x, y, worldWidth, worldHeight, 17, 17, settings.seed+29)-0.5)*30
			field[x*worldHeight+y] = WorldPlateElevation(f32(x)+warpX, f32(y)+warpY,
				f32(worldWidth), f32(worldHeight), plates[:])
		}
	}

	// Short, tapering island chains sit on the submerged edges of plates.
	for island in 0..<max(0, settings.islandCount) {
		seed := settings.seed+u64(island)*719+401
		for attempt in 0..<48 {
			x := int(WorldNoiseHash(attempt, 0, seed)*f32(worldWidth))
			y := int(WorldNoiseHash(attempt, 1, seed)*f32(worldHeight))
			elevation := field[x*worldHeight+y]
			if elevation > settings.landThreshold-0.12 || elevation < -0.6 do continue
			radius := 4+WorldNoiseHash(island, 2, seed)*9
			angle := WorldNoiseHash(island, 3, seed)*6.2831853
			steps := 2+int(WorldNoiseHash(island, 4, seed)*3)
			for step in 0..<steps {
				WorldStampIsland(field[:], worldWidth, worldHeight, f32(x), f32(y), radius)
				angle += (WorldNoiseHash(step, 5, seed)-0.5)*1.2
				x += int(math.cos(angle)*radius*0.9)
				y += int(math.sin(angle)*radius*0.9)
				radius *= 0.76
			}
			break
		}
	}

	for x in 0..<worldWidth {
		for y in 0..<worldHeight {
			coast := WorldPeriodicNoise(x, y, worldWidth, worldHeight,
				max(1, worldWidth/19), max(1, worldHeight/19), settings.seed+37)
			detail := WorldPeriodicNoise(x, y, worldWidth, worldHeight,
				max(1, worldWidth/7), max(1, worldHeight/7), settings.seed+41)
			landScore := field[x*worldHeight+y]+(coast-0.5)*0.32+(detail-0.5)*0.13

			tileType := TileType.Water
			if landScore > settings.landThreshold {
				moisture := WorldPeriodicNoise(x, y, worldWidth, worldHeight,
					biomeCellsX, biomeCellsY, settings.seed+53)*0.7 +
					WorldPeriodicNoise(x, y, worldWidth, worldHeight,
					detailCellsX, detailCellsY, settings.seed+71)*0.3
				height := WorldPeriodicNoise(x, y, worldWidth, worldHeight,
					biomeCellsX, biomeCellsY, settings.seed+83)*0.7 +
					WorldPeriodicNoise(x, y, worldWidth, worldHeight,
					detailCellsX, detailCellsY, settings.seed+89)*0.3
				if height > 0.65 && landScore > settings.landThreshold+0.12 {
					tileType = .Hill
				} else if moisture < settings.sandThreshold && landScore > settings.landThreshold+0.12 {
					tileType = .Desert
				} else if moisture > 0.57 {
					tileType = .Forest
				} else if moisture > 0.44 {
					tileType = .FertileGround
				} else {
					tileType = .Ground
				}
			}
			w.ground[x][y].type = tileType
		}
	}

	WorldGenerateLakes(w, settings)
	WorldGenerateRivers(w, settings)
	WorldGenerateBeaches(w, settings.beachWidth, settings.seed)
	WorldGenerateDecorations(w, settings.seed)
	w.navigationRevision += 1
	w.terrainRevision += 1
}

WorldGenerateLakes :: proc(w: ^World, settings: WorldGenerationSettings) {
	if settings.lakeCount <= 0 do return

	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	minimumRadius := settings.minLakeRadius
	maximumRadius := settings.maxLakeRadius
	if minimumRadius < 1 do minimumRadius = 1
	if maximumRadius < minimumRadius do maximumRadius = minimumRadius

	for lakeIndex in 0..<settings.lakeCount {
		lakeSeed := settings.seed + u64(lakeIndex)*101 + 1009
		radiusCount := maximumRadius - minimumRadius + 1
		radius := minimumRadius + int(WorldNoiseHash(lakeIndex, 2, lakeSeed)*f32(radiusCount))
		if radius > maximumRadius do radius = maximumRadius
		angle := WorldNoiseHash(lakeIndex, 5, lakeSeed)*6.2831853
		axisX, axisY := math.cos(angle), math.sin(angle)
		radiusX := f32(radius)*(1.0+WorldNoiseHash(lakeIndex, 6, lakeSeed)*0.4)
		radiusY := f32(radius)*(0.5+WorldNoiseHash(lakeIndex, 7, lakeSeed)*0.35)
		extent := int(radiusX*1.25)+2

		centerX, centerY := -1, -1
		for attempt in 0..<64 {
			x := int(WorldNoiseHash(lakeIndex, attempt*2+3, lakeSeed)*f32(worldWidth))
			y := int(WorldNoiseHash(lakeIndex, attempt*2+4, lakeSeed)*f32(worldHeight))
			clearance := extent+settings.beachWidth+2
			if w.ground[x][y].type == .Water ||
				w.ground[WorldWrapCoordinate(x+clearance, worldWidth)][y].type == .Water ||
				w.ground[WorldWrapCoordinate(x-clearance, worldWidth)][y].type == .Water ||
				w.ground[x][WorldWrapCoordinate(y+clearance, worldHeight)].type == .Water ||
				w.ground[x][WorldWrapCoordinate(y-clearance, worldHeight)].type == .Water {
				continue
			}
			centerX, centerY = x, y
			break
		}
		if centerX < 0 do continue

		for deltaX in -extent..=extent {
			for deltaY in -extent..=extent {
				distX := f32(deltaX)
				distY := f32(deltaY)
				along := distX*axisX+distY*axisY
				across := distY*axisX-distX*axisY
				x := WorldWrapCoordinate(centerX+deltaX, worldWidth)
				y := WorldWrapCoordinate(centerY+deltaY, worldHeight)
				shoreNoise := WorldPeriodicNoise(x, y, worldWidth, worldHeight, 40, 40, lakeSeed+7)
				shore := 0.75+shoreNoise*0.5
				if w.ground[x][y].type != .Water &&
					along*along/(radiusX*radiusX)+across*across/(radiusY*radiusY) <= shore*shore {
					w.ground[x][y].type = .FreshWater
				}
			}
		}
	}
}

// A distance field guarantees that every river reaches existing water even on
// flat ground, while local elevation and noise choose between downhill routes.
WorldGenerateRivers :: proc(w: ^World, settings: WorldGenerationSettings) {
	if settings.riverCount <= 0 do return
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	nodeCount := worldWidth*worldHeight
	distance := make([dynamic]int, nodeCount)
	defer delete(distance)
	queue := make([dynamic]int, nodeCount)
	defer delete(queue)
	head, tail := 0, 0
	for x in 0..<worldWidth {
		for y in 0..<worldHeight {
			index := x*worldHeight+y
			distance[index] = -1
			if w.ground[x][y].type == .Water || w.ground[x][y].type == .FreshWater {
				distance[index] = 0
				queue[tail] = index
				tail += 1
			}
		}
	}
	if tail == 0 do return

	for head < tail {
		index := queue[head]
		head += 1
		x, y := index/worldHeight, index%worldHeight
		for direction in 0..<4 {
			nx, ny := x, y
			switch direction {
			case 0: nx += 1
			case 1: nx -= 1
			case 2: ny += 1
			case 3: ny -= 1
			}
			nx = WorldWrapCoordinate(nx, worldWidth)
			ny = WorldWrapCoordinate(ny, worldHeight)
			next := nx*worldHeight+ny
			if distance[next] >= 0 do continue
			distance[next] = distance[index]+1
			queue[tail] = next
			tail += 1
		}
	}

	for river in 0..<settings.riverCount {
		start := -1
		for attempt in 0..<96 {
			seed := settings.seed+u64(river)*139+1901
			x := int(WorldNoiseHash(attempt, 0, seed)*f32(worldWidth))
			y := int(WorldNoiseHash(attempt, 1, seed)*f32(worldHeight))
			index := x*worldHeight+y
			if distance[index] < 10 || w.ground[x][y].type != .Hill do continue
			start = index
			break
		}
		if start < 0 do continue

		current := start
		for distance[current] > 0 {
			x, y := current/worldHeight, current%worldHeight
			if w.ground[x][y].type == .River do break
			best := -1
			bestScore := f32(2)
			for direction in 0..<4 {
				nx, ny := x, y
				switch direction {
				case 0: nx += 1
				case 1: nx -= 1
				case 2: ny += 1
				case 3: ny -= 1
				}
				nx = WorldWrapCoordinate(nx, worldWidth)
				ny = WorldWrapCoordinate(ny, worldHeight)
				next := nx*worldHeight+ny
				if distance[next] >= distance[current] do continue
				score := WorldPeriodicNoise(nx, ny, worldWidth, worldHeight,
					max(1, worldWidth/24), max(1, worldHeight/24), settings.seed+u64(river)*19+2017)*0.75 +
					WorldNoiseHash(nx, ny, settings.seed+2019)*0.25
				if w.ground[nx][ny].type == .Hill do score += 0.15
				if w.ground[nx][ny].type == .River do score -= 0.3
				if score < bestScore {
					bestScore = score
					best = next
				}
			}
			if best < 0 do break
			w.ground[x][y].type = .River
			current = best
		}
	}
}

WorldGenerateBeaches :: proc(w: ^World, beachWidth: int, seed: u64) {
	if beachWidth <= 0 do return

	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	shoreCellsX := max(1, worldWidth/55)
	shoreCellsY := max(1, worldHeight/55)
	for x in 0..<worldWidth {
		for y in 0..<worldHeight {
			tileType := w.ground[x][y].type
			if tileType == .Water || tileType == .FreshWater || tileType == .River do continue

			// Broad noise makes continuous sandy bays and rocky or vegetated shores.
			shore := WorldPeriodicNoise(x, y, worldWidth, worldHeight,
				shoreCellsX, shoreCellsY, seed+149)*0.8 +
				WorldPeriodicNoise(x, y, worldWidth, worldHeight,
					max(1, worldWidth/18), max(1, worldHeight/18), seed+157)*0.2
			threshold: f32 = 0.51
			if tileType == .Hill do threshold = 0.70
			if tileType == .Forest do threshold = 0.60
			if tileType == .Desert do threshold = 0.40
			if shore < threshold do continue

			nearWater := false
			for deltaX in -beachWidth..=beachWidth {
				for deltaY in -beachWidth..=beachWidth {
					if deltaX*deltaX + deltaY*deltaY > beachWidth*beachWidth do continue
					neighborX := WorldWrapCoordinate(x+deltaX, worldWidth)
					neighborY := WorldWrapCoordinate(y+deltaY, worldHeight)
					if w.ground[neighborX][neighborY].type == .Water {
						nearWater = true
						break
					}
				}
				if nearWater do break
			}
			if nearWater do w.ground[x][y].type = .Sand
		}
	}
}


WorldPeriodicNoise :: proc(x, y, worldWidth, worldHeight, cellsX, cellsY: int, seed: u64) -> f32 {
	if worldWidth <= 0 || worldHeight <= 0 || cellsX <= 0 || cellsY <= 0 do return 0.5

	positionX := (f32(x)+0.5) / f32(worldWidth) * f32(cellsX)
	positionY := (f32(y)+0.5) / f32(worldHeight) * f32(cellsY)
	gridX := int(positionX)
	gridY := int(positionY)
	fractionX := positionX - f32(gridX)
	fractionY := positionY - f32(gridY)
	smoothX := fractionX*fractionX*(3.0-2.0*fractionX)
	smoothY := fractionY*fractionY*(3.0-2.0*fractionY)

	x0 := gridX % cellsX
	y0 := gridY % cellsY
	x1 := (x0+1) % cellsX
	y1 := (y0+1) % cellsY
	topLeft := WorldNoiseHash(x0, y0, seed)
	topRight := WorldNoiseHash(x1, y0, seed)
	bottomLeft := WorldNoiseHash(x0, y1, seed)
	bottomRight := WorldNoiseHash(x1, y1, seed)
	return WorldLerp(
		WorldLerp(topLeft, topRight, smoothX),
		WorldLerp(bottomLeft, bottomRight, smoothX),
		smoothY,
	)
}


WorldNoiseHash :: proc(x, y: int, seed: u64) -> f32 {
	value := u64(x)*0x9E3779B97F4A7C15 ~ u64(y)*0xBF58476D1CE4E5B9 ~ seed
	value = (value ~ (value >> 30)) * 0xBF58476D1CE4E5B9
	value = (value ~ (value >> 27)) * 0x94D049BB133111EB
	value = value ~ (value >> 31)
	return f32(value % 1_000_000) / 1_000_000.0
}

WorldLerp :: proc(a, b, t: f32) -> f32 {
	return a + (b-a)*t
}

WorldSpawnInitialKingdoms :: proc(w: ^World, kingdomCount: int, seed: u64) -> bool {
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 || kingdomCount <= 0 ||
		kingdomCount > KINGDOMS_CAPACITY {
		return false
	}

	buildingWidth, buildingHeight := BuildingTileSize(TownHall{})
	nodeCount := worldWidth * worldHeight
	occupied := make([dynamic]bool, nodeCount)
	defer delete(occupied)
	for tile in 0..<nodeCount {
		occupied[tile] = false
	}

	for buildingSlot in 0..<BUILDING_CAPACITY {
		if !w.buildingUsed[buildingSlot] do continue
		buildingX := w.buildings.x[buildingSlot]
		buildingY := w.buildings.y[buildingSlot]
		width, height := BuildingTileSize(w.buildings[buildingSlot].type)
		for x in max(buildingX, 0)..<min(buildingX+width, worldWidth) {
			for y in max(buildingY, 0)..<min(buildingY+height, worldHeight) {
				occupied[x*worldHeight+y] = true
			}
		}
	}

	chosenX: [KINGDOMS_CAPACITY]int
	chosenY: [KINGDOMS_CAPACITY]int

	// Capitals sit on evenly spaced rings around the map centre. Land is
	// irregular, so several ring radii and rotations are sampled; every capital
	// snaps to the nearest valid shore and the layout whose resulting pair
	// distances are the most uniform wins. That keeps starting kingdoms about
	// the same distance apart instead of collapsing onto one coastline.
	centerX := f32(worldWidth)*0.5
	centerY := f32(worldHeight)*0.5
	baseRadius := f32(min(worldWidth, worldHeight))*0.33
	rotation := WorldNoiseHash(0, 0, seed+0xCA917A1)*6.2831853
	minimumSpacing := f32(TOWN_FOUNDING_MIN_DISTANCE)
	minimumSpacingSquared := minimumSpacing*minimumSpacing
	halfWidth := f32(buildingWidth)*0.5
	halfHeight := f32(buildingHeight)*0.5

	// Capitals need a landmass large enough to support more than a single town;
	// otherwise a kingdom is stranded on a tiny island and can never expand or
	// fight. Label connected land once, then keep the landmass area on each
	// candidate site.
	component := make([]i32, nodeCount)
	defer delete(component)
	for &value in component do value = -1
	componentArea := make([dynamic]int, 0, 64)
	defer delete(componentArea)
	stack := make([dynamic]int, 0, 1024)
	defer delete(stack)
	neighbourOffsets := [4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
	for start in 0..<nodeCount {
		if component[start] >= 0 do continue
		startX := start/worldHeight
		startY := start%worldHeight
		if !WorldTileWalkable(w, startX, startY, Builder{}, -1) do continue

		id := i32(len(componentArea))
		area := 0
		clear(&stack)
		append(&stack, start)
		component[start] = id
		for len(stack) > 0 {
			index := pop(&stack)
			x := index/worldHeight
			y := index%worldHeight
			area += 1
			for offset in neighbourOffsets {
				neighbourX := WorldWrapCoordinate(x+offset[0], worldWidth)
				neighbourY := WorldWrapCoordinate(y+offset[1], worldHeight)
				neighbour := neighbourX*worldHeight+neighbourY
				if component[neighbour] >= 0 do continue
				if !WorldTileWalkable(w, neighbourX, neighbourY, Builder{}, -1) {
					continue
				}
				component[neighbour] = id
				append(&stack, neighbour)
			}
		}
		append(&componentArea, area)
	}

	// One candidate per coarse block is plenty: the chosen site only needs to
	// be on the right side of the map, and thinning the list keeps the ring
	// search cheap even on the biggest maps.
	SITE_BLOCK :: 4
	blockWidth := (worldWidth+SITE_BLOCK-1)/SITE_BLOCK
	blockHeight := (worldHeight+SITE_BLOCK-1)/SITE_BLOCK
	siteX := make([dynamic]int, 0, blockWidth*blockHeight/2)
	siteY := make([dynamic]int, 0, blockWidth*blockHeight/2)
	siteArea := make([dynamic]int, 0, blockWidth*blockHeight/2)
	defer delete(siteX)
	defer delete(siteY)
	defer delete(siteArea)

	for blockX in 0..<blockWidth {
		for blockY in 0..<blockHeight {
			blockSite := -1
			for offsetX in 0..<SITE_BLOCK {
				if blockSite >= 0 do break
				x := blockX*SITE_BLOCK+offsetX
				if x >= worldWidth do break
				for offsetY in 0..<SITE_BLOCK {
					y := blockY*SITE_BLOCK+offsetY
					if y >= worldHeight do break
					if !WorldBuildingOverTile(w, x, y, TownHall{}) do continue

					isOccupied := false
					for tileX in x ..< (x + buildingWidth) {
						for tileY in y ..< (y + buildingHeight) {
							if occupied[tileX*worldHeight+tileY] {
								isOccupied = true
								break
							}
						}
						if isOccupied do break
					}
					if isOccupied do continue

					componentId := component[x*worldHeight+y]
					if componentId < 0 do continue
					blockSite = len(siteX)
					append(&siteX, x)
					append(&siteY, y)
					append(&siteArea, componentArea[componentId])
					break
				}
			}
		}
	}
	if len(siteX) < kingdomCount do return false

	// Prefer large landmasses. The threshold relaxes only as far as needed to
	// still offer one site per kingdom, so archipelago maps keep working while
	// ordinary maps keep every capital on connected, expandable ground.
	MIN_CAPITAL_LAND_AREA :: 3000
	areaThreshold := MIN_CAPITAL_LAND_AREA
	for areaThreshold > 0 {
		enough := 0
		for area in siteArea {
			if area >= areaThreshold do enough += 1
		}
		if enough >= kingdomCount do break
		areaThreshold /= 2
	}
	if areaThreshold > 0 {
		write := 0
		for site in 0..<len(siteArea) {
			if siteArea[site] < areaThreshold do continue
			siteX[write] = siteX[site]
			siteY[write] = siteY[site]
			siteArea[write] = siteArea[site]
			write += 1
		}
		resize(&siteX, write)
		resize(&siteY, write)
		resize(&siteArea, write)
	}
	if len(siteX) < kingdomCount do return false

	LAYOUT_RADII :: 3
	LAYOUT_ROTATIONS :: 4
	LAYOUT_COUNT :: LAYOUT_RADII*LAYOUT_ROTATIONS

	layoutX: [LAYOUT_COUNT][KINGDOMS_CAPACITY]int
	layoutY: [LAYOUT_COUNT][KINGDOMS_CAPACITY]int
	bestLayout := -1
	bestLayoutScore := f32(1e30)

	for variant in 0..<LAYOUT_COUNT {
		radiusScale := 0.82+0.36*f32(variant%LAYOUT_RADII)/f32(LAYOUT_RADII-1)
		phase := rotation+6.2831853*f32(variant/LAYOUT_RADII) /
			f32(kingdomCount*LAYOUT_ROTATIONS)
		radius := baseRadius*radiusScale

		variantOk := true
		for kingdomIndex in 0..<kingdomCount {
			angle := phase+6.2831853*f32(kingdomIndex)/f32(kingdomCount)
			targetX := centerX+math.cos(angle)*radius
			targetY := centerY+math.sin(angle)*radius

			bestSite := -1
			bestScore := f32(1e30)
			bestTieBreak := f32(-1.0)
			for site in 0..<len(siteX) {
				candidateX := f32(siteX[site])+halfWidth
				candidateY := f32(siteY[site])+halfHeight
				deltaX := WorldShortestWrappedDelta(candidateX-targetX, f32(worldWidth))
				deltaY := WorldShortestWrappedDelta(candidateY-targetY, f32(worldHeight))
				score := (deltaX*deltaX+deltaY*deltaY)/(radius*radius)

				for previous in 0..<kingdomIndex {
					previousX := f32(layoutX[variant][previous])+halfWidth
					previousY := f32(layoutY[variant][previous])+halfHeight
					spacingX := WorldShortestWrappedDelta(candidateX-previousX, f32(worldWidth))
					spacingY := WorldShortestWrappedDelta(candidateY-previousY, f32(worldHeight))
					spacingSquared := spacingX*spacingX+spacingY*spacingY
					if spacingSquared < minimumSpacingSquared {
						score += 1000*(1-spacingSquared/minimumSpacingSquared)
						if spacingSquared < f32(buildingWidth*buildingWidth) do score += 1_000_000
					}
				}

				tieBreak := WorldNoiseHash(
					siteX[site],
					siteY[site],
					seed+u64(kingdomIndex)*7919+313,
				)
				if score < bestScore || (score == bestScore && tieBreak > bestTieBreak) {
					bestSite = site
					bestScore = score
					bestTieBreak = tieBreak
				}
			}

			if bestSite < 0 {
				variantOk = false
				break
			}
			layoutX[variant][kingdomIndex] = siteX[bestSite]
			layoutY[variant][kingdomIndex] = siteY[bestSite]
		}
		if !variantOk do continue

		// Prefer the layout with the smallest spread between its shortest and
		// longest capital-to-capital distance, with an extra push if any pair
		// ended up closer than the minimum founding distance.
		layoutScore := f32(0)
		if kingdomCount > 1 {
			minimumPair := f32(1e30)
			maximumPair := f32(0)
			for a in 0..<kingdomCount {
				for b in a+1..<kingdomCount {
					deltaX := WorldShortestWrappedDelta(
						f32(layoutX[variant][a])-f32(layoutX[variant][b]),
						f32(worldWidth),
					)
					deltaY := WorldShortestWrappedDelta(
						f32(layoutY[variant][a])-f32(layoutY[variant][b]),
						f32(worldHeight),
					)
					distance := math.sqrt(deltaX*deltaX+deltaY*deltaY)
					minimumPair = min(minimumPair, distance)
					maximumPair = max(maximumPair, distance)
				}
			}
			layoutScore = maximumPair-minimumPair
			if minimumPair < minimumSpacing {
				layoutScore += (minimumSpacing-minimumPair)*8
			}
		}

		if bestLayout < 0 || layoutScore < bestLayoutScore {
			bestLayout = variant
			bestLayoutScore = layoutScore
		}
	}

	if bestLayout < 0 do return false

	// Relaxation: greedy nearest-land snapping can leave one capital much
	// closer to its neighbour than the rest. A few passes re-pick each capital
	// while directly minimising the spread between the shortest and longest
	// pair distance, anchored to its ring position so the capitals stay evenly
	// distributed around the map.
	bestPhase := rotation+6.2831853*f32(bestLayout/LAYOUT_RADII) /
		f32(kingdomCount*LAYOUT_ROTATIONS)
	bestRadiusScale := 0.82+0.36*f32(bestLayout%LAYOUT_RADII)/f32(LAYOUT_RADII-1)
	bestRadius := baseRadius*bestRadiusScale

	if kingdomCount > 2 {
		for _ in 0..<3 {
			for kingdomIndex in 0..<kingdomCount {
				otherMin := f32(1e30)
				otherMax := f32(0)
				for a in 0..<kingdomCount {
					if a == kingdomIndex do continue
					for b in a+1..<kingdomCount {
						if b == kingdomIndex do continue
						deltaX := WorldShortestWrappedDelta(
							f32(layoutX[bestLayout][a])-f32(layoutX[bestLayout][b]),
							f32(worldWidth),
						)
						deltaY := WorldShortestWrappedDelta(
							f32(layoutY[bestLayout][a])-f32(layoutY[bestLayout][b]),
							f32(worldHeight),
						)
						distance := math.sqrt(deltaX*deltaX+deltaY*deltaY)
						otherMin = min(otherMin, distance)
						otherMax = max(otherMax, distance)
					}
				}

				angle := bestPhase+6.2831853*f32(kingdomIndex)/f32(kingdomCount)
				anchorX := centerX+math.cos(angle)*bestRadius
				anchorY := centerY+math.sin(angle)*bestRadius

				bestSite := -1
				bestScore := f32(1e30)
				bestTieBreak := f32(-1.0)
				for site in 0..<len(siteX) {
					candidateX := f32(siteX[site])+halfWidth
					candidateY := f32(siteY[site])+halfHeight

					tooClose := false
					nearest := f32(1e30)
					farthest := f32(0)
					for other in 0..<kingdomCount {
						if other == kingdomIndex do continue
						deltaX := WorldShortestWrappedDelta(
							candidateX-(f32(layoutX[bestLayout][other])+halfWidth),
							f32(worldWidth),
						)
						deltaY := WorldShortestWrappedDelta(
							candidateY-(f32(layoutY[bestLayout][other])+halfHeight),
							f32(worldHeight),
						)
						distance := math.sqrt(deltaX*deltaX+deltaY*deltaY)
						if distance < f32(buildingWidth) {
							tooClose = true
							break
						}
						nearest = min(nearest, distance)
						farthest = max(farthest, distance)
					}
					if tooClose do continue

					spread := max(farthest, otherMax)-min(nearest, otherMin)
					deltaTargetX := WorldShortestWrappedDelta(
						candidateX-anchorX,
						f32(worldWidth),
					)
					deltaTargetY := WorldShortestWrappedDelta(
						candidateY-anchorY,
						f32(worldHeight),
					)
					anchorCost :=
						(deltaTargetX*deltaTargetX+deltaTargetY*deltaTargetY) /
						(bestRadius*bestRadius)*200
					score := spread+anchorCost

					tieBreak := WorldNoiseHash(
						siteX[site],
						siteY[site],
						seed+u64(kingdomIndex)*7919+313,
					)
					if score < bestScore ||
					   (score == bestScore && tieBreak > bestTieBreak) {
						bestSite = site
						bestScore = score
						bestTieBreak = tieBreak
					}
				}

				if bestSite >= 0 {
					layoutX[bestLayout][kingdomIndex] = siteX[bestSite]
					layoutY[bestLayout][kingdomIndex] = siteY[bestSite]
				}
			}
		}
	}

	for kingdomIndex in 0..<kingdomCount {
		chosenX[kingdomIndex] = layoutX[bestLayout][kingdomIndex]
		chosenY[kingdomIndex] = layoutY[bestLayout][kingdomIndex]
	}

	for kingdomIndex in 0..<kingdomCount {
		if _, ok := KingdomSpawn(w, chosenX[kingdomIndex], chosenY[kingdomIndex]); !ok {
			return false
		}
		if !TownSpawnInitialPopulation(w, kingdomIndex, w.kingdoms[kingdomIndex].capitalSlot) {
			return false
		}
	}

	WorldSpawnIndependentTowns(w, siteX[:], siteY[:], kingdomCount)
	return true
}

// Independent towns are placed near each capital so a new kingdom has a soft
// early objective. They all live in the neutral faction slot and never expand.
WorldSpawnIndependentTowns :: proc(w: ^World, siteX, siteY: []int, kingdomCount: int) {
	if kingdomCount <= 0 || len(siteX) == 0 || len(siteX) != len(siteY) do return

	w.kingdoms[NEUTRAL_KINGDOM].culture = NameKingdomCulture(w, NEUTRAL_KINGDOM)
	NameSet(&w.kingdoms[NEUTRAL_KINGDOM].name, "Independent")
	w.kingdomUsed[NEUTRAL_KINGDOM] = true

	hallWidth, hallHeight := BuildingTileSize(TownHall{})
	spawned := 0
	for kingdom in 0..<kingdomCount {
		if !w.kingdomUsed[kingdom] do continue
		capital := w.kingdoms[kingdom].capitalSlot
		if capital < 0 || !w.kingdoms[kingdom].townUsed[capital] do continue
		capitalX := f32(w.kingdoms[kingdom].towns[capital].x)+f32(hallWidth)*0.5
		capitalY := f32(w.kingdoms[kingdom].towns[capital].y)+f32(hallHeight)*0.5

		for _ in 0..<INDEPENDENT_TOWNS_PER_KINGDOM {
			bestSite := -1
			bestScore: f32 = 1e30
			bestTie: f32 = -1
			for site in 0..<len(siteX) {
				x, y := siteX[site], siteY[site]
				if !WorldBuildingValid(w, x, y, TownHall{}) do continue

				centerX := f32(x)+f32(hallWidth)*0.5
				centerY := f32(y)+f32(hallHeight)*0.5
				deltaX := WorldShortestWrappedDelta(centerX-capitalX, f32(w.maxX))
				deltaY := WorldShortestWrappedDelta(centerY-capitalY, f32(w.maxY))
				distance := math.sqrt(deltaX*deltaX+deltaY*deltaY)
				if distance < INDEPENDENT_TOWN_MIN_DISTANCE do continue

				tooClose := false
				for otherKingdom in 0..<KINGDOM_SLOTS {
					if !w.kingdomUsed[otherKingdom] do continue
					for otherTown in 0..<TOWN_CAPACITY {
						if !w.kingdoms[otherKingdom].townUsed[otherTown] do continue
						otherX := f32(w.kingdoms[otherKingdom].towns[otherTown].x)+f32(hallWidth)*0.5
						otherY := f32(w.kingdoms[otherKingdom].towns[otherTown].y)+f32(hallHeight)*0.5
						spacingX := WorldShortestWrappedDelta(centerX-otherX, f32(w.maxX))
						spacingY := WorldShortestWrappedDelta(centerY-otherY, f32(w.maxY))
						if spacingX*spacingX+spacingY*spacingY <
							f32(INDEPENDENT_TOWN_SEPARATION*INDEPENDENT_TOWN_SEPARATION) {
							tooClose = true
							break
						}
					}
					if tooClose do break
				}
				if tooClose do continue

				score := math.abs(distance-f32(INDEPENDENT_TOWN_TARGET_DISTANCE))
				tie := WorldNoiseHash(
					x,
					y,
					w.seed+u64(kingdom)*131+u64(spawned)*7919,
				)
				if score < bestScore || (score == bestScore && tie > bestTie) {
					bestSite = site
					bestScore = score
					bestTie = tie
				}
			}

			if bestSite < 0 do continue
			if _, ok := IndependentTownSpawn(w, siteX[bestSite], siteY[bestSite]); ok {
				spawned += 1
			}
		}
	}

	if spawned == 0 do w.kingdomUsed[NEUTRAL_KINGDOM] = false
}
