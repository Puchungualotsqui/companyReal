package main

import "core:math"

FLOW_FIELD_CAPACITY :: 16
FLOW_FIELD_MAX_STEPS :: 8

// Path tiles are cheap to route through and slightly faster to walk on.
PATH_SPEED_MULTIPLIER :: 1.25
PATH_STEP_COST :: 3
PLAIN_STEP_COST :: 4
PATH_HEURISTIC_COST :: 3

// Units hop over their own walls instead of being trapped by them.
WALL_JUMP_SECONDS :: 0.35
WALL_JUMP_HEIGHT :: 0.55

FlowDirection :: enum u8 {
	Blocked,
	None,
	East,
	West,
	South,
	North,
}

FlowFollowResult :: enum {
	Travelling,
	Arrived,
	Unreachable,
}

FlowField :: struct {
	targetKingdom, targetTown: int,
	unitKingdom: int,
	hallX, hallY: int,
	walkWater: bool,
	navigationRevision: u64,
	direction: []FlowDirection,
	valid: bool,
	stamp: u64,
}

WorldNavigationInit :: proc(w: ^World) -> bool {
	nodeCount := int(w.maxX)*int(w.maxY)
	if nodeCount <= 0 do return false
	w.tileConstructionBlocked = make([]bool, nodeCount)
	w.navigationDistance = make([]int, nodeCount)
	w.navigationCameFrom = make([]int, nodeCount)
	w.navigationOpen = make([]bool, nodeCount)
	w.navigationClosed = make([]bool, nodeCount)
	w.navigationQueue = make([]int, nodeCount)
	w.navigationStamp = make([]u32, nodeCount)
	return true
}

WorldNavigationDeinit :: proc(w: ^World) {
	delete(w.tileConstructionBlocked)
	delete(w.navigationDistance)
	delete(w.navigationCameFrom)
	delete(w.navigationOpen)
	delete(w.navigationClosed)
	delete(w.navigationQueue)
	delete(w.navigationStamp)
	for &field in w.flowFields {
		delete(field.direction)
	}
}

AStar :: proc(w: ^World, unitType: UnitType, unitKingdom: int, startX, startY, goalX, goalY: int, path: ^[dynamic]int) -> bool {
	clear(path)
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 do return false

	nodeCount := worldWidth*worldHeight
	if nodeCount > len(w.navigationDistance) || nodeCount > len(w.navigationQueue) {
		return false
	}

	wrappedStartX := WorldWrapCoordinate(startX, worldWidth)
	wrappedStartY := WorldWrapCoordinate(startY, worldHeight)
	wrappedGoalX := WorldWrapCoordinate(goalX, worldWidth)
	wrappedGoalY := WorldWrapCoordinate(goalY, worldHeight)

	if !WorldTileWalkable(w, wrappedGoalX, wrappedGoalY, unitType, unitKingdom) do return false

	startIndex := wrappedStartX*worldHeight + wrappedStartY
	goalIndex := wrappedGoalX*worldHeight + wrappedGoalY
	infinity := nodeCount*PLAIN_STEP_COST+1

	cameFrom := w.navigationCameFrom
	gScore := w.navigationDistance
	isOpen := w.navigationOpen
	isClosed := w.navigationClosed
	openSet := w.navigationQueue
	stamp := w.navigationStamp

	// Stamp touched nodes instead of clearing the whole world for every path.
	w.navigationSearchId += 1
	if w.navigationSearchId == 0 {
		for i in 0..<nodeCount {
			stamp[i] = 0
		}
		w.navigationSearchId = 1
	}
	searchId := w.navigationSearchId

	stamp[startIndex] = searchId
	cameFrom[startIndex] = -1
	gScore[startIndex] = 0
	isOpen[startIndex] = true
	isClosed[startIndex] = false
	openCount := 0
	openSet[openCount] = startIndex
	openCount += 1

	found := false
	for openCount > 0 {
		bestPosition := 0
		bestIndex := openSet[0]
		bestScore := gScore[bestIndex] + PATH_HEURISTIC_COST*WorldWrapHeuristic(
			bestIndex/worldHeight,
			bestIndex%worldHeight,
			wrappedGoalX,
			wrappedGoalY,
			worldWidth,
			worldHeight,
		)
		for position in 1..<openCount {
			candidate := openSet[position]
			candidateScore := gScore[candidate] + PATH_HEURISTIC_COST*WorldWrapHeuristic(
				candidate/worldHeight,
				candidate%worldHeight,
				wrappedGoalX,
				wrappedGoalY,
				worldWidth,
				worldHeight,
			)
			if candidateScore < bestScore {
				bestPosition = position
				bestIndex = candidate
				bestScore = candidateScore
			}
		}

		openSet[bestPosition] = openSet[openCount-1]
		openCount -= 1
		isOpen[bestIndex] = false
		if bestIndex == goalIndex {
			found = true
			break
		}
		if isClosed[bestIndex] do continue
		isClosed[bestIndex] = true

		currentX := bestIndex / worldHeight
		currentY := bestIndex % worldHeight
		for direction in 0..<4 {
			nextX := currentX
			nextY := currentY
			switch direction {
			case 0: nextX += 1
			case 1: nextX -= 1
			case 2: nextY += 1
			case 3: nextY -= 1
			}
			nextX = WorldWrapCoordinate(nextX, worldWidth)
			nextY = WorldWrapCoordinate(nextY, worldHeight)
			if !WorldTileWalkable(w, nextX, nextY, unitType, unitKingdom) do continue

			nextIndex := nextX*worldHeight + nextY
			if stamp[nextIndex] != searchId {
				stamp[nextIndex] = searchId
				cameFrom[nextIndex] = -1
				gScore[nextIndex] = infinity
				isOpen[nextIndex] = false
				isClosed[nextIndex] = false
			}
			if isClosed[nextIndex] do continue
			tentativeScore := gScore[bestIndex] + WorldStepCost(w, nextX, nextY)
			if tentativeScore >= gScore[nextIndex] do continue

			cameFrom[nextIndex] = bestIndex
			gScore[nextIndex] = tentativeScore
			if !isOpen[nextIndex] && openCount < nodeCount {
				isOpen[nextIndex] = true
				openSet[openCount] = nextIndex
				openCount += 1
			}
		}
	}

	if found {
		cursor := goalIndex
		for {
			append(path, cursor)
			if cursor == startIndex do break
			cursor = cameFrom[cursor]
			if cursor < 0 {
				clear(path)
				found = false
				break
			}
		}
		for i in 0..<len(path)/2 {
			opposite := len(path) - i - 1
			path[i], path[opposite] = path[opposite], path[i]
		}
	}

	return found
}

FLEE_SEARCH_STEPS :: 6
FLEE_SEARCH_CAPACITY :: 1+2*FLEE_SEARCH_STEPS*(FLEE_SEARCH_STEPS+1)
FLEE_THREAT_RADIUS :: 16
FLEE_THREAT_CAPACITY :: 16

UnitNearbyEnemy :: struct {
	slot: int,
	distanceSquared: f32,
}

UnitEnemyDistanceSquared :: proc(w: ^World, x, y: f32, enemySlot: int) -> f32 {
	dx := WorldShortestWrappedDelta(w.units.x[enemySlot]-x, f32(w.maxX))
	dy := WorldShortestWrappedDelta(w.units.y[enemySlot]-y, f32(w.maxY))
	return dx*dx+dy*dy
}

// A wrapped coordinate interval may cross the short final spatial bucket.
UnitNearbyChunkRange :: proc(position, radius, size: f32, chunkSize, chunkCount: int) -> (int, int) {
	if radius >= size*0.5 do return 0, chunkCount
	low, high := position-radius, position+radius
	first := int(WorldWrapPosition(low, size))/chunkSize
	last := int(WorldWrapPosition(high, size))/chunkSize
	count := last-first+1
	if low < 0 || high >= size do count += chunkCount
	return first, min(count, chunkCount)
}

// Keep only the closest threats, visiting each intersecting wrapped chunk once.
UnitCollectNearbyEnemies :: proc(w: ^World, unitSlot: int, radius: f32, enemies: []UnitNearbyEnemy) -> int {
	if unitSlot < 0 || unitSlot >= UNIT_CAPACITY || !w.unitUsed[unitSlot] ||
		w.units[unitSlot].health <= 0 || !(radius >= 0) || len(enemies) == 0 {
				return 0
			}
	if w.maxX <= 0 || w.maxY <= 0 || w.spatial.chunkSize <= 0 ||
		w.spatial.chunksX <= 0 || w.spatial.chunksY <= 0 {
				return 0
			}
	unit := &w.units[unitSlot]
	x := WorldWrapPosition(unit.x, f32(w.maxX))
	y := WorldWrapPosition(unit.y, f32(w.maxY))
	firstX, countX := UnitNearbyChunkRange(x, radius, f32(w.maxX), w.spatial.chunkSize, w.spatial.chunksX)
	firstY, countY := UnitNearbyChunkRange(y, radius, f32(w.maxY), w.spatial.chunkSize, w.spatial.chunksY)
	count := 0
	for ox in 0..<countX {
		cx := WorldWrapCoordinate(firstX+ox, w.spatial.chunksX)
		for oy in 0..<countY {
			cy := WorldWrapCoordinate(firstY+oy, w.spatial.chunksY)
			chunk := cx*w.spatial.chunksY+cy
			for other := w.spatial.unitHead[chunk]; other >= 0; other = w.spatial.unitNext[other] {
				if other == unitSlot || !w.unitUsed[other] || w.units[other].health <= 0 do continue
				if !KingdomAtWar(w, unit.kingdome, w.units[other].kingdome) || UnitHiddenInside(w, other) do continue
				distance := UnitEnemyDistanceSquared(w, x, y, other)
				if distance > radius*radius do continue
				position := 0
				for position < count {
					entry := enemies[position]
					if distance < entry.distanceSquared || (distance == entry.distanceSquared && other < entry.slot) do break
					position += 1
				}
				if position >= len(enemies) do continue
				count = min(count+1, len(enemies))
				for i := count-1; i > position; i -= 1 do enemies[i] = enemies[i-1]
				enemies[position] = UnitNearbyEnemy{other, distance}
			}
		}
	}
	return count
}

// Visible means outdoors, not player fog-of-war or line of sight.
UnitFindNearbyEnemy :: proc(w: ^World, unitSlot: int, radius: f32) -> int {
	enemies: [1]UnitNearbyEnemy
	if UnitCollectNearbyEnemies(w, unitSlot, radius, enemies[:]) == 0 do return -1
	return enemies[0].slot
}

UnitFleeClearance :: proc(w: ^World, x, y: f32, enemies: []UnitNearbyEnemy) -> f32 {
	distanceSquared: f32 = 1e30
	for enemy in enemies {
		distanceSquared = min(distanceSquared, UnitEnemyDistanceSquared(w, x, y, enemy.slot))
	}
	return math.sqrt(distanceSquared)
}

// Builds at most 85 reachable nodes, with no full-map A*. Shared navigation
// scratch is stamped, while the resulting short route belongs to the unit.
UnitFindEscapePath :: proc(w: ^World, unitSlot: int, enemies: []UnitNearbyEnemy) -> bool {
	unit := &w.units[unitSlot]
	width, height := int(w.maxX), int(w.maxY)
	startX := int(WorldWrapPosition(unit.x, f32(width)))
	startY := int(WorldWrapPosition(unit.y, f32(height)))
	start := startX*height+startY
	clear(&unit.path)
	unit.pathFound = false
	unit.pathReady = true
	unit.pathRevision = w.navigationRevision
	unit.pathIndex = 0
	// Cache failure until the primary threat changes tile or navigation changes.
	unit.pathTargetX = int(WorldWrapPosition(w.units.x[enemies[0].slot], f32(width)))
	unit.pathTargetY = int(WorldWrapPosition(w.units.y[enemies[0].slot], f32(height)))
	if len(w.navigationStamp) < width*height || len(w.navigationQueue) < width*height ||
		len(w.navigationCameFrom) < width*height {
				return false
			}
	w.navigationSearchId += 1
	if w.navigationSearchId == 0 {
		for &stamp in w.navigationStamp do stamp = 0
		w.navigationSearchId = 1
	}
	stamp := w.navigationSearchId
	depth: [FLEE_SEARCH_CAPACITY]int
	routeClearance: [FLEE_SEARCH_CAPACITY]f32
	startClearance := UnitFleeClearance(w, unit.x, unit.y, enemies)
	routeClearance[0] = startClearance
	w.navigationQueue[0] = start
	w.navigationStamp[start] = stamp
	w.navigationCameFrom[start] = -1
	queueEnd := 1
	best, bestScore := start, startClearance
	for cursor := 0; cursor < queueEnd; cursor += 1 {
		index := w.navigationQueue[cursor]
		if depth[cursor] >= FLEE_SEARCH_STEPS do continue
		for direction in 0..<4 {
			nx, ny := index/height, index%height
			switch direction {
			case 0: nx += 1
			case 1: nx -= 1
			case 2: ny += 1
			case 3: ny -= 1
			}
			nx, ny = WorldWrapCoordinate(nx, width), WorldWrapCoordinate(ny, height)
			next := nx*height+ny
			if w.navigationStamp[next] == stamp do continue
			if !WorldTileWalkable(w, nx, ny, unit.type, unit.kingdome) do continue
			clearance := UnitFleeClearance(w, f32(nx)+0.5, f32(ny)+0.5, enemies)
			// Do not escape through an enemy's immediate melee space, unless
			// already that close; small temporary detours remain possible.
			if clearance < min(startClearance, 1.25) do continue
			if queueEnd >= FLEE_SEARCH_CAPACITY do continue
			w.navigationStamp[next] = stamp
			w.navigationCameFrom[next] = index
			depth[queueEnd] = depth[cursor]+1
			routeClearance[queueEnd] = min(routeClearance[cursor], clearance)
			score := clearance-0.15*f32(depth[queueEnd])-
				2*max(0, startClearance-routeClearance[queueEnd])
			if score > bestScore+0.001 do best, bestScore = next, score
			w.navigationQueue[queueEnd] = next
			queueEnd += 1
		}
	}
	if best == start do return false
	unit.pathTargetX, unit.pathTargetY = best/height, best%height
	for cursor := best; cursor >= 0; cursor = w.navigationCameFrom[cursor] do append(&unit.path, cursor)
	for i in 0..<len(unit.path)/2 {
		opposite := len(unit.path)-i-1
		unit.path[i], unit.path[opposite] = unit.path[opposite], unit.path[i]
	}
	unit.pathIndex = 1
	unit.pathFound = true
	return true
}

// The caller owns fleeing state and clears pathReady on entry/resume. Returns
// whether a usable escape route exists (also true for a zero-time tick).
UnitFleeEnemy :: proc(w: ^World, unitSlot, enemySlot: int, deltaTime: f32) -> bool {
	if unitSlot < 0 || unitSlot >= UNIT_CAPACITY || !w.unitUsed[unitSlot] ||
		w.units[unitSlot].health <= 0 || deltaTime < 0 || w.maxX <= 0 || w.maxY <= 0 {
				return false
			}
	unit := &w.units[unitSlot]
	if enemySlot < 0 || enemySlot >= UNIT_CAPACITY || !w.unitUsed[enemySlot] ||
		w.units[enemySlot].health <= 0 || UnitHiddenInside(w, enemySlot) ||
		!KingdomAtWar(w, unit.kingdome, w.units[enemySlot].kingdome) || UnitHiddenInside(w, unitSlot) {
		unit.pathReady, unit.pathFound = false, false
		return false
	}
	// Include the explicit threat even if outside the local radius or crowded out.
	threats: [FLEE_THREAT_CAPACITY+1]UnitNearbyEnemy
	threats[0] = UnitNearbyEnemy{enemySlot, 0}
	count := 1+UnitCollectNearbyEnemies(w, unitSlot, FLEE_THREAT_RADIUS, threats[1:])
	enemies := threats[:count]
	clearance := UnitFleeClearance(w, unit.x, unit.y, enemies)
	replan := !unit.pathReady || unit.pathRevision != w.navigationRevision
	if !replan && !unit.pathFound {
		replan = unit.pathTargetX != int(WorldWrapPosition(w.units.x[enemySlot], f32(w.maxX))) ||
			unit.pathTargetY != int(WorldWrapPosition(w.units.y[enemySlot], f32(w.maxY)))
	}
	if !replan && unit.pathFound {
		replan = unit.pathIndex >= len(unit.path) || UnitFleeClearance(w,
			f32(unit.pathTargetX)+0.5, f32(unit.pathTargetY)+0.5, enemies)+0.5 < clearance
		if !replan {
			next := unit.path[unit.pathIndex]
			nx, ny := next/int(w.maxY), next%int(w.maxY)
			replan = !WorldTileWalkable(w, nx, ny, unit.type, unit.kingdome) ||
				UnitFleeClearance(w, f32(nx)+0.5, f32(ny)+0.5, enemies)+0.001 < min(clearance, 1.25)
		}
	}
	if replan && !UnitFindEscapePath(w, unitSlot, enemies) do return false
	if !unit.pathFound do return false
	remaining := UnitMoveSpeed(w, unitSlot, UnitDefaultSpeed(unit.type))*deltaTime
	for _ in 0..<FLEE_SEARCH_STEPS {
		if remaining <= 0 || unit.pathIndex >= len(unit.path) do break
		next := unit.path[unit.pathIndex]
		nx, ny := next/int(w.maxY), next%int(w.maxY)
		// Check each waypoint, including when a long tick consumes several.
		if UnitFleeClearance(w, f32(nx)+0.5, f32(ny)+0.5, enemies)+0.001 < min(clearance, 1.25) {
			unit.pathReady = false
			return false
		}
		reached, blocked, left := UnitStepTowards(w, unitSlot, f32(nx)+0.5, f32(ny)+0.5, remaining)
		if blocked {
			unit.pathReady, unit.pathFound = false, false
			return false
		}
		remaining = left
		if !reached do break
		unit.pathIndex += 1
	}
	if unit.pathIndex >= len(unit.path) do unit.pathReady = false
	return true
}

// One breadth-first pass per target town builds a shared direction field.
// Every warrior heading to that town follows the same field instead of
// running its own A* search, so pathing cost is independent of unit count.
// Knights and giants share walkability, so one field serves both.
FlowFieldGet :: proc(w: ^World, kingdom, town: int, unitType: UnitType, unitKingdom: int) -> (^FlowField, bool) {
	if !WorldTownExists(w, kingdom, town) do return nil, false
	if TownHallSlot(w, kingdom, town) < 0 do return nil, false
	hallX := w.kingdoms[kingdom].towns[town].x
	hallY := w.kingdoms[kingdom].towns[town].y
	walkWater := UnitValidTileType(unitType, .Water)

	slot := -1
	for i in 0..<FLOW_FIELD_CAPACITY {
		field := &w.flowFields[i]
		if field.targetKingdom == kingdom && field.targetTown == town &&
			field.hallX == hallX && field.hallY == hallY &&
			field.walkWater == walkWater && field.unitKingdom == unitKingdom {
			slot = i
			break
		}
	}
	if slot < 0 {
		for i in 0..<FLOW_FIELD_CAPACITY {
			if w.flowFields[i].targetKingdom < 0 {
				slot = i
				break
			}
		}
	}
	if slot < 0 {
		oldestStamp := max(u64)
		for i in 0..<FLOW_FIELD_CAPACITY {
			if w.flowFields[i].stamp < oldestStamp {
				oldestStamp = w.flowFields[i].stamp
				slot = i
			}
		}
	}

	field := &w.flowFields[slot]
	w.flowFieldStamp += 1
	field.stamp = w.flowFieldStamp
	if field.targetKingdom == kingdom && field.targetTown == town &&
		field.hallX == hallX && field.hallY == hallY &&
		field.walkWater == walkWater && field.unitKingdom == unitKingdom &&
		field.navigationRevision == w.navigationRevision {
		return field, field.valid
	}

	field.targetKingdom = kingdom
	field.targetTown = town
	field.unitKingdom = unitKingdom
	field.hallX = hallX
	field.hallY = hallY
	field.walkWater = walkWater
	field.navigationRevision = w.navigationRevision
	field.valid = FlowFieldCompute(w, field)
	return field, field.valid
}

FlowFieldCompute :: proc(w: ^World, field: ^FlowField) -> bool {
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 do return false

	nodeCount := worldWidth*worldHeight
	if nodeCount > len(w.navigationDistance) || nodeCount > len(w.navigationQueue) {
		return false
	}
	if len(field.direction) != nodeCount {
		if field.direction != nil do delete(field.direction)
		field.direction = make([]FlowDirection, nodeCount)
	}
	for i in 0..<nodeCount {
		field.direction[i] = .Blocked
	}

	distance := w.navigationDistance
	for i in 0..<nodeCount {
		distance[i] = -1
	}
	queue := w.navigationQueue
	head, tail := 0, 0

	walkType: UnitType = Knight{}
	if field.walkWater do walkType = Turtle{}

	hallWidth, hallHeight := BuildingTileSize(TownHall{})
	foundSource := false
	for radius in 1..=4 {
		ringMinX := field.hallX-radius+1
		ringMaxX := field.hallX+hallWidth-1+radius-1
		ringMinY := field.hallY-radius+1
		ringMaxY := field.hallY+hallHeight-1+radius-1
		for x in field.hallX-radius ..= field.hallX+hallWidth-1+radius {
			for y in field.hallY-radius ..= field.hallY+hallHeight-1+radius {
				if x >= ringMinX && x <= ringMaxX && y >= ringMinY && y <= ringMaxY {
					continue
				}
				wrappedX := WorldWrapCoordinate(x, worldWidth)
				wrappedY := WorldWrapCoordinate(y, worldHeight)
				if !WorldTileWalkable(w, wrappedX, wrappedY, walkType, field.unitKingdom) do continue
				index := wrappedX*worldHeight+wrappedY
				if distance[index] == 0 do continue
				distance[index] = 0
				field.direction[index] = .None
				queue[tail] = index
				tail += 1
				foundSource = true
			}
		}
		if foundSource do break
	}
	if !foundSource do return false

	for head < tail {
		index := queue[head]
		head += 1
		currentX := index/worldHeight
		currentY := index%worldHeight
		for direction in 0..<4 {
			nextX := currentX
			nextY := currentY
			switch direction {
			case 0: nextX = WorldWrapCoordinate(currentX+1, worldWidth)
			case 1: nextX = WorldWrapCoordinate(currentX-1, worldWidth)
			case 2: nextY = WorldWrapCoordinate(currentY+1, worldHeight)
			case 3: nextY = WorldWrapCoordinate(currentY-1, worldHeight)
			}
			if !WorldTileWalkable(w, nextX, nextY, walkType, field.unitKingdom) do continue

			nextIndex := nextX*worldHeight+nextY
			if distance[nextIndex] != -1 do continue
			distance[nextIndex] = distance[index]+1
			switch direction {
			case 0: field.direction[nextIndex] = .West
			case 1: field.direction[nextIndex] = .East
			case 2: field.direction[nextIndex] = .North
			case 3: field.direction[nextIndex] = .South
			}
			queue[tail] = nextIndex
			tail += 1
		}
	}
	return true
}

UnitFollowFlowField :: proc(w: ^World, unitSlot: int, field: ^FlowField, deltaTime: f32) -> FlowFollowResult {
	unit := &w.units[unitSlot]
	speed := UnitMoveSpeed(w, unitSlot, UnitDefaultSpeed(unit.type))

	remaining := speed*deltaTime
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 do return .Unreachable

	for _ in 0..<FLOW_FIELD_MAX_STEPS {
		tileX := int(WorldWrapPosition(unit.x, f32(worldWidth)))
		tileY := int(WorldWrapPosition(unit.y, f32(worldHeight)))
		direction := field.direction[tileX*worldHeight+tileY]
		nextX, nextY := tileX, tileY
		switch direction {
		case .Blocked:
			return .Unreachable
		case .None:
			return .Arrived
		case .East:
			nextX = WorldWrapCoordinate(tileX+1, worldWidth)
		case .West:
			nextX = WorldWrapCoordinate(tileX-1, worldWidth)
		case .South:
			nextY = WorldWrapCoordinate(tileY+1, worldHeight)
		case .North:
			nextY = WorldWrapCoordinate(tileY-1, worldHeight)
		}

		reached, blocked, left := UnitStepTowards(
			w,
			unitSlot,
			f32(nextX)+0.5,
			f32(nextY)+0.5,
			remaining,
		)
		if blocked do return .Unreachable
		remaining = left
		if !reached do return .Travelling
		if remaining <= 0 do return .Travelling
	}
	return .Travelling
}

// Choose a reachable work point without routing through the proposed footprint.
// This also works before the site is reserved (for founding-order validation).
BuildingFindWorkAccessPoint :: proc(w: ^World, x, y, width, height: int, unitType: UnitType, kingdom, startX, startY: int) -> (int, int, bool) {
	worldWidth, worldHeight := int(w.maxX), int(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 do return 0, 0, false
	workRadius := 0
	for radius in 1..=6 {
		for tileX in x-radius..=x+width-1+radius {
			for tileY in y-radius..=y+height-1+radius {
				wrappedX := WorldWrapCoordinate(tileX, worldWidth)
				wrappedY := WorldWrapCoordinate(tileY, worldHeight)
				if BuildingAccessDistance(w, x, y, width, height, wrappedX, wrappedY) != radius do continue
				if WorldTileWalkable(w, wrappedX, wrappedY, unitType, kingdom) do workRadius = radius
			}
		}
		if workRadius > 0 do break
	}
	if workRadius == 0 do return 0, 0, false
	w.navigationSearchId += 1
	if w.navigationSearchId == 0 {
		for &stamp in w.navigationStamp do stamp = 0
		w.navigationSearchId = 1
	}
	stamp := w.navigationSearchId
	start := WorldWrapCoordinate(startX, worldWidth)*worldHeight+WorldWrapCoordinate(startY, worldHeight)
	w.navigationQueue[0] = start
	w.navigationStamp[start] = stamp
	queueEnd := 1
	for cursor := 0; cursor < queueEnd; cursor += 1 {
		index := w.navigationQueue[cursor]
		currentX, currentY := index/worldHeight, index%worldHeight
		if BuildingAccessDistance(w, x, y, width, height, currentX, currentY) == workRadius &&
			WorldTileWalkable(w, currentX, currentY, unitType, kingdom) {
			return currentX, currentY, true
		}
		for direction in 0..<4 {
			nextX, nextY := currentX, currentY
			switch direction {
			case 0: nextX += 1
			case 1: nextX -= 1
			case 2: nextY += 1
			case 3: nextY -= 1
			}
			nextX = WorldWrapCoordinate(nextX, worldWidth)
			nextY = WorldWrapCoordinate(nextY, worldHeight)
			nextIndex := nextX*worldHeight+nextY
			if w.navigationStamp[nextIndex] == stamp do continue
			if nextX >= x && nextX < x+width && nextY >= y && nextY < y+height do continue
			if !WorldTileWalkable(w, nextX, nextY, unitType, kingdom) do continue
			w.navigationStamp[nextIndex] = stamp
			w.navigationQueue[queueEnd] = nextIndex
			queueEnd += 1
		}
	}
	return 0, 0, false
}

// Search through the footprint only, stopping at its first walkable exit. This
// avoids moving an occupant across water, other buildings or neighboring sites.
UnitFindBuildingExit :: proc(w: ^World, unitSlot, x, y, width, height: int) -> (int, int, bool) {
	unit := &w.units[unitSlot]
	worldWidth, worldHeight := int(w.maxX), int(w.maxY)
	w.navigationSearchId += 1
	if w.navigationSearchId == 0 {
		for &stamp in w.navigationStamp do stamp = 0
		w.navigationSearchId = 1
	}
	stamp := w.navigationSearchId
	start := int(unit.x)*worldHeight+int(unit.y)
	w.navigationQueue[0] = start
	w.navigationStamp[start] = stamp
	queueEnd := 1
	for cursor := 0; cursor < queueEnd; cursor += 1 {
		index := w.navigationQueue[cursor]
		currentX, currentY := index/worldHeight, index%worldHeight
		for direction in 0..<4 {
			nextX, nextY := currentX, currentY
			switch direction {
			case 0: nextX += 1
			case 1: nextX -= 1
			case 2: nextY += 1
			case 3: nextY -= 1
			}
			nextX = WorldWrapCoordinate(nextX, worldWidth)
			nextY = WorldWrapCoordinate(nextY, worldHeight)
			nextIndex := nextX*worldHeight+nextY
			if w.navigationStamp[nextIndex] == stamp do continue
			w.navigationStamp[nextIndex] = stamp
			inside := nextX >= x && nextX < x+width && nextY >= y && nextY < y+height
			if !inside {
				if WorldTileWalkable(w, nextX, nextY, unit.type, unit.kingdome) {
					return nextX, nextY, true
				}
				continue
			}
			if !WorldTileWalkableBase(w, nextX, nextY, unit.type, unit.kingdome) do continue
			w.navigationQueue[queueEnd] = nextIndex
			queueEnd += 1
		}
	}
	return 0, 0, false
}

UnitStepTowards :: proc(w: ^World, unitSlot: int, targetX, targetY, distance: f32) -> (reached: bool, blocked: bool, remaining: f32) {
	remaining = distance
	if unitSlot < 0 || unitSlot >= UNIT_CAPACITY || !w.unitUsed[unitSlot] {
		return false, true, remaining
	}
	worldWidth := f32(w.maxX)
	worldHeight := f32(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 do return false, true, remaining

	unit := &w.units[unitSlot]
	defer SpatialUnitMove(w, unitSlot)
	for remaining > 0.0001 {
		deltaX := WorldShortestWrappedDelta(targetX-unit.x, worldWidth)
		deltaY := WorldShortestWrappedDelta(targetY-unit.y, worldHeight)
		distanceToTarget := math.sqrt(deltaX*deltaX+deltaY*deltaY)
		if distanceToTarget <= 0.0001 {
			unit.x = WorldWrapPosition(targetX, worldWidth)
			unit.y = WorldWrapPosition(targetY, worldHeight)
			return true, false, remaining
		}

		step := min(distanceToTarget, remaining, 1)
		nextX := WorldWrapPosition(unit.x+deltaX/distanceToTarget*step, worldWidth)
		nextY := WorldWrapPosition(unit.y+deltaY/distanceToTarget*step, worldHeight)
		tileX := int(nextX)
		tileY := int(nextY)
		currentTileX := int(WorldWrapPosition(unit.x, worldWidth))
		currentTileY := int(WorldWrapPosition(unit.y, worldHeight))
		if (tileX != currentTileX || tileY != currentTileY) &&
			!WorldTileWalkable(w, tileX, tileY, unit.type, unit.kingdome) {
			return false, true, remaining
		}
		if (tileX != currentTileX || tileY != currentTileY) &&
			WorldTileFriendlyWall(w, tileX, tileY, unit.kingdome) {
			unit.jumpStarted = w.simulationTime
		}

		unit.x = nextX
		unit.y = nextY
		remaining -= step
		if step >= distanceToTarget {
			unit.x = WorldWrapPosition(targetX, worldWidth)
			unit.y = WorldWrapPosition(targetY, worldHeight)
			return true, false, remaining
		}
	}
	return false, false, remaining
}

WorldTileWalkable :: proc(w: ^World, x, y: int, unitType: UnitType, unitKingdom: int) -> bool {
	worldWidth, worldHeight := int(w.maxX), int(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 do return false
	index := WorldWrapCoordinate(x, worldWidth)*worldHeight+WorldWrapCoordinate(y, worldHeight)
	if w.tileConstructionBlocked[index] do return false
	return WorldTileWalkableBase(w, x, y, unitType, unitKingdom)
}

// Used only when clearing an occupied footprint before reserving or completing it.
WorldTileWalkableBase :: proc(w: ^World, x, y: int, unitType: UnitType, unitKingdom: int) -> bool {
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 do return false
	wrappedX := WorldWrapCoordinate(x, worldWidth)
	wrappedY := WorldWrapCoordinate(y, worldHeight)
	index := wrappedX*worldHeight+wrappedY
	if buildingSlot := w.tileBuilding[index]; buildingSlot >= 0 {
		if BuildingKindOf(w.buildings[buildingSlot].type) == .Wall &&
			w.buildings[buildingSlot].kingdom == unitKingdom {
			return true
		}
		return BuildingWalkable(w.buildings[buildingSlot].type)
	}
	return UnitValidTileType(unitType, w.ground[wrappedX][wrappedY].type)
}

WorldTileFriendlyWall :: proc(w: ^World, x, y: int, kingdom: int) -> bool {
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 do return false
	wrappedX := WorldWrapCoordinate(x, worldWidth)
	wrappedY := WorldWrapCoordinate(y, worldHeight)
	slot := w.tileBuilding[wrappedX*worldHeight+wrappedY]
	if slot < 0 || slot >= BUILDING_CAPACITY || !w.buildingUsed[slot] do return false
	if BuildingKindOf(w.buildings[slot].type) != .Wall do return false
	return w.buildings[slot].kingdom == kingdom
}

WorldTileHasPath :: proc(w: ^World, x, y: int) -> bool {
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 do return false
	wrappedX := WorldWrapCoordinate(x, worldWidth)
	wrappedY := WorldWrapCoordinate(y, worldHeight)
	slot := w.tileBuilding[wrappedX*worldHeight+wrappedY]
	if slot < 0 || slot >= BUILDING_CAPACITY || !w.buildingUsed[slot] do return false
	return BuildingKindOf(w.buildings[slot].type) == .Path
}

WorldStepCost :: proc(w: ^World, x, y: int) -> int {
	if WorldTileHasPath(w, x, y) do return PATH_STEP_COST
	return PLAIN_STEP_COST
}

// Base speed adjusted by the tile the unit is standing on.
UnitMoveSpeed :: proc(w: ^World, unitSlot: int, baseSpeed: f32) -> f32 {
	speed := baseSpeed
	if w.units[unitSlot].effects[.NoWater] do speed *= 0.7
	tileX := int(WorldWrapPosition(w.units.x[unitSlot], f32(w.maxX)))
	tileY := int(WorldWrapPosition(w.units.y[unitSlot], f32(w.maxY)))
	if WorldTileHasPath(w, tileX, tileY) do speed *= PATH_SPEED_MULTIPLIER
	return speed
}

WorldWrapCoordinate :: proc(coordinate, size: int) -> int {
	if size <= 0 do return 0
	wrapped := coordinate % size
	if wrapped < 0 do wrapped += size
	return wrapped
}

WorldWrapPosition :: proc(position, size: f32) -> f32 {
	if size <= 0 do return 0
	wrapped := position
	for wrapped < 0 { wrapped += size }
	for wrapped >= size { wrapped -= size }
	return wrapped
}

WorldShortestWrappedDelta :: proc(delta, size: f32) -> f32 {
	halfSize := size * 0.5
	if delta > halfSize do return delta - size
	if delta < -halfSize do return delta + size
	return delta
}

WorldWrapHeuristic :: proc(x, y, goalX, goalY, worldWidth, worldHeight: int) -> int {
	deltaX := x - goalX
	deltaY := y - goalY
	if deltaX < 0 do deltaX = -deltaX
	if deltaY < 0 do deltaY = -deltaY
	deltaX = min(deltaX, worldWidth-deltaX)
	deltaY = min(deltaY, worldHeight-deltaY)
	return deltaX + deltaY
}
