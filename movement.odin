package main

import "core:fmt"
import "core:math"
import "core:slice"
import "core:sync"

FLOW_FIELD_CAPACITY :: 16
FLOW_FIELD_MAX_STEPS :: 8

// BFS queue entries pack tile coordinates into one int, avoiding a division by
// the world height for every visited tile.
FLOW_QUEUE_SHIFT :: 16
FLOW_QUEUE_MASK :: (1 << FLOW_QUEUE_SHIFT)-1
// Tiles (or BFS pops) a single field may advance per simulation tick. A field
// is shared by every unit marching to the same town, so spreading its build
// over several ticks removes the world-sized one-frame stall.
FLOW_FIELD_BUILD_BUDGET :: 262_144
// Completed fields keep serving for a while even if the world revision moved.
// This guarantees a build can finish and stops constant invalidation during
// battles. Unit movement validates each step, so slightly stale fields are safe.
FLOW_FIELD_REFRESH_SECONDS :: 8.0

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
	direction: []FlowDirection,
	valid: bool,
	stamp: u64,
	builtAt: f32, // Simulation time the field last completed

	// Resumable build state. The walk mask and BFS advance a bounded number
	// of tiles per tick instead of blocking a whole frame.
	building: bool,      // Field is still being built
	queued: bool,        // Already present in the world build queue
	buildMask: bool,     // Mask phase precedes the BFS phase
	maskIndex: int,      // Linear progress through the walk mask
	maskX, maskY: int,   // Cursor for the sequential mask scan
	buildHead: int,      // BFS queue head
	buildTail: int,      // BFS queue tail
	seeded: bool,        // Source ring has been enqueued
	maskKingdom: int,    // Kingdom the mask was built for
	maskWater: bool,     // Mask includes deep water
	maskRevision: u64,   // pathRevision the mask was built for
	walkMask: []u8,      // 1 when a tile is walkable
}

// Step cost per terrain, computed once instead of rounding per neighbour.
tileStepCost: [TileType]int

WorldNavigationInit :: proc(w: ^World) -> bool {
	nodeCount := int(w.maxX)*int(w.maxY)
	if nodeCount <= 0 do return false
	for def, tile in TILE_DEFS {
		tileStepCost[tile] = max(1, int(math.round(f32(PLAIN_STEP_COST)*def.moveCost)))
	}
	w.tileConstructionBlocked = make([]bool, nodeCount)
	w.constructionBlockedTiles = make([dynamic]int, 0, COMBAT_SITE_CAPACITY*16)
	w.navigationDistance = make([]int, nodeCount)
	w.navigationPriority = make([]int, nodeCount)
	w.navigationCameFrom = make([]int, nodeCount)
	w.navigationOpen = make([]bool, nodeCount)
	w.navigationClosed = make([]bool, nodeCount)
	w.navigationQueue = make([]int, nodeCount)
	w.navigationHeapPos = make([]int, nodeCount)
	w.navigationStamp = make([]u32, nodeCount)
	w.flowQueue = make([]int, nodeCount)
	return true
}

WorldNavigationDeinit :: proc(w: ^World) {
	delete(w.tileConstructionBlocked)
	delete(w.constructionBlockedTiles)
	delete(w.navigationDistance)
	delete(w.navigationPriority)
	delete(w.navigationCameFrom)
	delete(w.navigationOpen)
	delete(w.navigationClosed)
	delete(w.navigationQueue)
	delete(w.navigationHeapPos)
	delete(w.navigationStamp)
	delete(w.flowQueue)
	for &field in w.flowFields {
		delete(field.direction)
		delete(field.walkMask)
	}
}

AStarHeapSwap :: #force_inline proc(heap, heapPos: []int, a, b: int) {
	heap[a], heap[b] = heap[b], heap[a]
	heapPos[heap[a]] = a
	heapPos[heap[b]] = b
}

// The heap only compares stored priorities. Recomputing the heuristic here
// used to divide and modulo the tile index on every comparison.
AStarHeapUp :: proc(heap, heapPos, priority: []int, position: int) {
	current := position
	for current > 0 {
		parent := (current-1)/2
		if priority[heap[current]] >= priority[heap[parent]] do break
		AStarHeapSwap(heap, heapPos, current, parent)
		current = parent
	}
}

AStarHeapDown :: proc(heap, heapPos, priority: []int, count, position: int) {
	current := position
	for {
		left := current*2+1
		if left >= count do break
		right := left+1
		smallest := left
		if right < count && priority[heap[right]] < priority[heap[left]] {
			smallest = right
		}
		if priority[heap[current]] <= priority[heap[smallest]] do break
		AStarHeapSwap(heap, heapPos, current, smallest)
		current = smallest
	}
}

AStar :: proc(w: ^World, unitType: UnitType, unitKingdom: int, startX, startY, goalX, goalY: int, path: ^[dynamic]int, maxExpansions := 0) -> bool {
	// The scratch arrays are shared, so one search runs at a time.
	RecursiveLockAcquire(&w.navMutex)
	defer RecursiveLockRelease(&w.navMutex)
	profileStamp := ProfilerBegin("Nav:AStar")
	defer ProfilerEnd(profileStamp)
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

	startIndex := wrappedStartX*worldHeight + wrappedStartY
	goalIndex := wrappedGoalX*worldHeight + wrappedGoalY
	infinity := nodeCount*PLAIN_STEP_COST+1

	if !WorldTileWalkableAt(w, goalIndex, unitType, unitKingdom, true) do return false

	cameFrom := w.navigationCameFrom
	gScore := w.navigationDistance
	priority := w.navigationPriority
	isOpen := w.navigationOpen
	isClosed := w.navigationClosed
	openSet := w.navigationQueue
	heapPos := w.navigationHeapPos
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
	priority[startIndex] = PATH_HEURISTIC_COST*WorldWrapHeuristic(
		wrappedStartX,
		wrappedStartY,
		wrappedGoalX,
		wrappedGoalY,
		worldWidth,
		worldHeight,
	)
	isOpen[startIndex] = true
	isClosed[startIndex] = false
	heapPos[startIndex] = 0
	openSet[0] = startIndex
	openCount := 1

	found := false
	expansions := 0
	for openCount > 0 {
		if maxExpansions > 0 && expansions >= maxExpansions do break
		expansions += 1
		bestIndex := openSet[0]
		openCount -= 1
		if openCount > 0 {
			last := openSet[openCount]
			openSet[0] = last
			heapPos[last] = 0
			AStarHeapDown(openSet, heapPos, priority, openCount, 0)
		}
		heapPos[bestIndex] = -1
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
			case 0:
				nextX += 1
				if nextX >= worldWidth do nextX = 0
			case 1:
				nextX -= 1
				if nextX < 0 do nextX = worldWidth-1
			case 2:
				nextY += 1
				if nextY >= worldHeight do nextY = 0
			case 3:
				nextY -= 1
				if nextY < 0 do nextY = worldHeight-1
			}

			nextIndex := nextX*worldHeight + nextY
			if !WorldTileWalkableAt(w, nextIndex, unitType, unitKingdom, true) do continue
			if stamp[nextIndex] != searchId {
				stamp[nextIndex] = searchId
				cameFrom[nextIndex] = -1
				gScore[nextIndex] = infinity
				priority[nextIndex] = infinity
				isOpen[nextIndex] = false
				isClosed[nextIndex] = false
				heapPos[nextIndex] = -1
			}
			if isClosed[nextIndex] do continue
			tentativeScore := gScore[bestIndex] + WorldStepCostAt(w, nextIndex)
			if tentativeScore >= gScore[nextIndex] do continue

			cameFrom[nextIndex] = bestIndex
			gScore[nextIndex] = tentativeScore
			priority[nextIndex] = tentativeScore+
				PATH_HEURISTIC_COST*WorldWrapHeuristic(
					nextX,
					nextY,
					wrappedGoalX,
					wrappedGoalY,
					worldWidth,
					worldHeight,
				)
			if isOpen[nextIndex] {
				AStarHeapUp(openSet, heapPos, priority, heapPos[nextIndex])
			} else if openCount < nodeCount {
				isOpen[nextIndex] = true
				heapPos[nextIndex] = openCount
				openSet[openCount] = nextIndex
				openCount += 1
				AStarHeapUp(openSet, heapPos, priority, heapPos[nextIndex])
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

FLEE_SEARCH_STEPS :: 4
FLEE_SEARCH_CAPACITY :: 1+2*FLEE_SEARCH_STEPS*(FLEE_SEARCH_STEPS+1)
FLEE_THREAT_RADIUS :: 16
// Clearance only needs the immediate threats; the explicit one plus the four
// nearest cover every escape decision without scoring the whole neighbourhood.
FLEE_CLEARANCE_ENEMIES :: 5

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
			if !SpatialChunkHasEnemy(w, chunk, unit.kingdome) do continue
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
	// Shares the navigation scratch with A*, so it needs the same lock.
	RecursiveLockGuard(&w.navMutex)
	unit := &w.units[unitSlot]
	width, height := int(w.maxX), int(w.maxY)
	startX := int(WorldWrapPosition(unit.x, f32(width)))
	startY := int(WorldWrapPosition(unit.y, f32(height)))
	start := startX*height+startY
	clear(&unit.path)
	unit.pathFound = false
	unit.pathReady = true
	unit.pathRevision = w.pathRevision
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
	threats: [FLEE_CLEARANCE_ENEMIES]UnitNearbyEnemy
	threats[0] = UnitNearbyEnemy{enemySlot, 0}
	count := 1+UnitCollectNearbyEnemies(w, unitSlot, FLEE_THREAT_RADIUS, threats[1:])
	enemies := threats[:count]
	clearance := UnitFleeClearance(w, unit.x, unit.y, enemies)
	// Do not replan just because the world changed somewhere else; the route
	// checks below detect an actual blockage or a worse local escape.
	replan := !unit.pathReady
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

// Follows an escape route between decision ticks without re-collecting threats
// or rebuilding clearance. Returns true when the route is exhausted.
UnitFollowEscapePath :: proc(w: ^World, unitSlot: int, deltaTime: f32) -> bool {
	unit := &w.units[unitSlot]
	if !unit.pathFound || unit.pathIndex >= len(unit.path) do return true
	remaining := UnitMoveSpeed(w, unitSlot, UnitDefaultSpeed(unit.type))*deltaTime
	for remaining > 0 && unit.pathIndex < len(unit.path) {
		next := unit.path[unit.pathIndex]
		nx, ny := next/int(w.maxY), next%int(w.maxY)
		reached, blocked, left := UnitStepTowards(
			w,
			unitSlot,
			f32(nx)+0.5,
			f32(ny)+0.5,
			remaining,
		)
		if blocked {
			unit.pathReady = false
			return false
		}
		remaining = left
		if !reached do return false
		unit.pathIndex += 1
	}
	return unit.pathIndex >= len(unit.path)
}

// One breadth-first pass per target town builds a shared direction field.
// Every warrior heading to that town follows the same field instead of
// running its own A* search, so pathing cost is independent of unit count.
// Knights and giants share walkability, so one field serves both.
FlowFieldGet :: proc(
	w: ^World,
	kingdom, town: int,
	unitType: UnitType,
	unitKingdom: int,
) -> (field: ^FlowField, ready: bool) {
	if !WorldTownExists(w, kingdom, town) do return nil, false
	if TownHallSlot(w, kingdom, town) < 0 do return nil, false
	hallX := w.kingdoms[kingdom].towns[town].x
	hallY := w.kingdoms[kingdom].towns[town].y
	walkWater := UnitValidTileType(unitType, .Ocean) ||
		UnitCanCrossWater(w, unitType, unitKingdom)

	slot := -1
	for i in 0..<FLOW_FIELD_CAPACITY {
		candidate := &w.flowFields[i]
		if candidate.targetKingdom == kingdom && candidate.targetTown == town &&
			candidate.hallX == hallX && candidate.hallY == hallY &&
			candidate.walkWater == walkWater && candidate.unitKingdom == unitKingdom {
			slot = i
			break
		}
	}
	if slot >= 0 {
		field = &w.flowFields[slot]
		w.flowFieldStamp += 1
		field.stamp = w.flowFieldStamp
		if field.building do return field, false
		if w.simulationTime-field.builtAt < FLOW_FIELD_REFRESH_SECONDS {
			return field, field.valid
		}
		FlowFieldBegin(w, slot)
		return field, false
	}

	for i in 0..<FLOW_FIELD_CAPACITY {
		if w.flowFields[i].targetKingdom < 0 {
			slot = i
			break
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

	field = &w.flowFields[slot]
	field.targetKingdom = kingdom
	field.targetTown = town
	field.unitKingdom = unitKingdom
	field.hallX = hallX
	field.hallY = hallY
	field.walkWater = walkWater
	w.flowFieldStamp += 1
	field.stamp = w.flowFieldStamp
	FlowFieldBegin(w, slot)
	return field, false
}

FlowFieldMaskReady :: proc(w: ^World, field: ^FlowField) -> bool {
	nodeCount := int(w.maxX)*int(w.maxY)
	return len(field.walkMask) == nodeCount &&
		field.maskKingdom == field.unitKingdom &&
		field.maskWater == field.walkWater &&
		field.maskRevision == w.pathRevision
}

// Starts or restarts a field build. The mask and BFS are advanced later by
// FlowFieldBuildStep, at most one field per simulation tick.
FlowFieldBegin :: proc(w: ^World, slot: int) {
	field := &w.flowFields[slot]
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	nodeCount := worldWidth*worldHeight
	if nodeCount <= 0 || nodeCount > len(w.flowQueue) do return
	if worldWidth > FLOW_QUEUE_MASK+1 || worldHeight > FLOW_QUEUE_MASK+1 do return

	if len(field.direction) != nodeCount {
		if field.direction != nil do delete(field.direction)
		field.direction = make([]FlowDirection, nodeCount)
	}
	slice.zero(field.direction)
	field.valid = false
	field.building = true
	field.seeded = false
	field.buildHead = 0
	field.buildTail = 0
	field.buildMask = !FlowFieldMaskReady(w, field)
	if field.buildMask {
		if len(field.walkMask) != nodeCount {
			if field.walkMask != nil do delete(field.walkMask)
			field.walkMask = make([]u8, nodeCount)
		}
		field.maskIndex = 0
		field.maskX = 0
		field.maskY = 0
	}
	if !field.queued && w.flowBuildCount < FLOW_FIELD_CAPACITY {
		queueIndex := (w.flowBuildHead+w.flowBuildCount)%FLOW_FIELD_CAPACITY
		w.flowBuildQueue[queueIndex] = slot
		w.flowBuildCount += 1
		field.queued = true
	}
}

FlowFieldSeed :: proc(w: ^World, field: ^FlowField) -> bool {
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	hallWidth, hallHeight := BuildingTileSize(TownHall{})
	walkable := field.walkMask
	direction := field.direction
	queue := w.flowQueue
	tail := 0
	for radius in 1..=4 {
		ringMinX := field.hallX-radius+1
		ringMaxX := field.hallX+hallWidth-1+radius-1
		ringMinY := field.hallY-radius+1
		ringMaxY := field.hallY+hallHeight-1+radius-1
		found := false
		for x in field.hallX-radius ..= field.hallX+hallWidth-1+radius {
			for y in field.hallY-radius ..= field.hallY+hallHeight-1+radius {
				if x >= ringMinX && x <= ringMaxX && y >= ringMinY && y <= ringMaxY {
					continue
				}
				wrappedX := WorldWrapCoordinate(x, worldWidth)
				wrappedY := WorldWrapCoordinate(y, worldHeight)
				index := wrappedX*worldHeight+wrappedY
				if walkable[index] == 0 || direction[index] != .Blocked do continue
				direction[index] = .None
				queue[tail] = wrappedX<<FLOW_QUEUE_SHIFT|wrappedY
				tail += 1
				found = true
			}
		}
		if found do break
	}
	field.buildHead = 0
	field.buildTail = tail
	return tail > 0
}

// Walk masks cover every tile and never overlap between rows, so they split
// cleanly across cores.
FlowMaskJob :: struct {
	w:        ^World,
	mask:     []u8,
	walkType: UnitType,
	kingdom:  int,
}

FlowMaskBuildTiles :: proc(ctx: rawptr, startIndex, endIndex: int, worker: int) {
	job := cast(^FlowMaskJob)ctx
	for index in startIndex..<endIndex {
		job.mask[index] = WorldTileWalkableAt(job.w, index, job.walkType, job.kingdom, true) ? 1 : 0
	}
}

// Advances the current build by at most budget tiles. Returns true once the
// field is complete (reachable or provably unreachable).
FlowFieldBuildStep :: proc(w: ^World, field: ^FlowField, budget: ^int) -> bool {
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 do return true

	if field.buildMask {
		stamp := ProfilerBegin("Nav:WalkMask")
		mask := field.walkMask
		walkType: UnitType = Knight{}
		if field.walkWater do walkType = Turtle{}
		if ParallelAvailable() {
			job := FlowMaskJob {
				w        = w,
				mask     = mask,
				walkType = walkType,
				kingdom  = field.unitKingdom,
			}
			ParallelFor(len(mask), &job, FlowMaskBuildTiles)
			field.maskX, field.maskY, field.maskIndex = worldWidth, 0, len(mask)
		} else {
			x := field.maskX
			y := field.maskY
			index := field.maskIndex
			for budget^ > 0 && x < worldWidth {
				mask[index] = WorldTileWalkableAt(w, index, walkType, field.unitKingdom, true) ? 1 : 0
				budget^ -= 1
				index += 1
				y += 1
				if y >= worldHeight {
					y = 0
					x += 1
				}
			}
			field.maskX, field.maskY, field.maskIndex = x, y, index
		}
		ProfilerEnd(stamp)
		if field.maskX < worldWidth do return false
		field.maskKingdom = field.unitKingdom
		field.maskWater = field.walkWater
		field.maskRevision = w.pathRevision
		field.buildMask = false
	}

	if !field.seeded {
		if !FlowFieldSeed(w, field) {
			field.valid = false
			field.building = false
			field.builtAt = w.simulationTime
			return true
		}
		field.seeded = true
	}

	stamp := ProfilerBegin("Nav:FlowFieldBfs")
	defer ProfilerEnd(stamp)
	queue := w.flowQueue
	head := field.buildHead
	tail := field.buildTail
	walkable := field.walkMask
	direction := field.direction
	// Queue entries pack x and y so the BFS never divides by the world height.
	for head < tail && budget^ > 0 {
		entry := queue[head]
		head += 1
		budget^ -= 1
		x := entry>>FLOW_QUEUE_SHIFT
		y := entry&FLOW_QUEUE_MASK

		for directionIndex in 0..<4 {
			nextX, nextY := x, y
			step: FlowDirection
			switch directionIndex {
			case 0:
				nextX += 1
				if nextX >= worldWidth do nextX = 0
				step = .West
			case 1:
				nextX -= 1
				if nextX < 0 do nextX = worldWidth-1
				step = .East
			case 2:
				nextY += 1
				if nextY >= worldHeight do nextY = 0
				step = .North
			case 3:
				nextY -= 1
				if nextY < 0 do nextY = worldHeight-1
				step = .South
			}

			nextIndex := nextX*worldHeight+nextY
			if walkable[nextIndex] == 0 || direction[nextIndex] != .Blocked do continue
			direction[nextIndex] = step
			queue[tail] = nextX<<FLOW_QUEUE_SHIFT|nextY
			tail += 1
		}
	}
	field.buildHead, field.buildTail = head, tail
	if head < tail do return false
	field.valid = true
	field.building = false
	field.builtAt = w.simulationTime
	return true
}

WorldFlowFieldUpdate :: proc(w: ^World) {
	if w.flowBuildCount <= 0 do return
	slot := w.flowBuildQueue[w.flowBuildHead]
	field := &w.flowFields[slot]
	if field.building {
		budget := FLOW_FIELD_BUILD_BUDGET
		if !FlowFieldBuildStep(w, field, &budget) do return
	}
	field.queued = false
	w.flowBuildHead = (w.flowBuildHead+1)%FLOW_FIELD_CAPACITY
	w.flowBuildCount -= 1
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
WORK_ACCESS_MAX_EXPANSIONS :: 256

BuildingFindWorkAccessPoint :: proc(w: ^World, x, y, width, height: int, unitType: UnitType, kingdom, startX, startY: int) -> (int, int, bool) {
	// Shares the navigation scratch with A*.
	RecursiveLockGuard(&w.navMutex)
	worldWidth, worldHeight := int(w.maxX), int(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 do return 0, 0, false
	workRadius := 0
	fallbackX, fallbackY := 0, 0
	fallbackDistance: int = max(int)
	startTileX := WorldWrapCoordinate(startX, worldWidth)
	startTileY := WorldWrapCoordinate(startY, worldHeight)
	for radius in 1..=6 {
		for tileX in x-radius..=x+width-1+radius {
			for tileY in y-radius..=y+height-1+radius {
				wrappedX := WorldWrapCoordinate(tileX, worldWidth)
				wrappedY := WorldWrapCoordinate(tileY, worldHeight)
				if BuildingAccessDistance(w, x, y, width, height, wrappedX, wrappedY) != radius do continue
				if !WorldTileWalkable(w, wrappedX, wrappedY, unitType, kingdom) do continue
				workRadius = radius
				deltaX := WorldShortestWrappedDelta(f32(wrappedX-startTileX), f32(worldWidth))
				deltaY := WorldShortestWrappedDelta(f32(wrappedY-startTileY), f32(worldHeight))
				distance := int(deltaX*deltaX+deltaY*deltaY)
				if distance < fallbackDistance {
					fallbackDistance = distance
					fallbackX, fallbackY = wrappedX, wrappedY
				}
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
	expansions := 0
	for cursor := 0; cursor < queueEnd && expansions < WORK_ACCESS_MAX_EXPANSIONS; cursor += 1 {
		expansions += 1
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
			if !WorldTileWalkable(w, nextX, nextY, unitType, kingdom) do continue
			w.navigationStamp[nextIndex] = stamp
			w.navigationQueue[queueEnd] = nextIndex
			queueEnd += 1
		}
	}
	return fallbackX, fallbackY, true
}

// Search through the footprint only, stopping at its first walkable exit. This
// avoids moving an occupant across water, other buildings or neighboring sites.
UnitFindBuildingExit :: proc(w: ^World, unitSlot, x, y, width, height: int) -> (int, int, bool) {
	// Shares the navigation scratch with A*.
	RecursiveLockGuard(&w.navMutex)
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
	wrappedX := WorldWrapCoordinate(x, worldWidth)
	wrappedY := WorldWrapCoordinate(y, worldHeight)
	return WorldTileWalkableAt(
		w,
		wrappedX*worldHeight+wrappedY,
		unitType,
		unitKingdom,
		true,
	)
}

// Used only when clearing an occupied footprint before reserving or completing it.
WorldTileWalkableBase :: proc(w: ^World, x, y: int, unitType: UnitType, unitKingdom: int) -> bool {
	worldWidth, worldHeight := int(w.maxX), int(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 do return false
	wrappedX := WorldWrapCoordinate(x, worldWidth)
	wrappedY := WorldWrapCoordinate(y, worldHeight)
	return WorldTileWalkableAt(
		w,
		wrappedX*worldHeight+wrappedY,
		unitType,
		unitKingdom,
		false,
	)
}

// Coordinates must already be wrapped. Bulk passes can therefore walk the tile
// arrays in index order without paying for a modulo per lookup.
WorldTileWalkableAt :: proc(
	w: ^World,
	index: int,
	unitType: UnitType,
	unitKingdom: int,
	checkConstruction: bool,
) -> bool {
	if checkConstruction && w.tileConstructionBlocked[index] do return false
	if buildingSlot := w.tileBuilding[index]; buildingSlot >= 0 {
		if BuildingKindOf(w.buildings[buildingSlot].type) == .Wall &&
			w.buildings[buildingSlot].kingdom == unitKingdom {
			return true
		}
		return BuildingWalkable(w.buildings[buildingSlot].type)
	}
	if hazardSlot := w.hazardTile[index]; hazardSlot >= 0 && hazardSlot < HAZARD_CAPACITY &&
		w.hazardUsed[hazardSlot] {
		switch w.hazardCells.kind[hazardSlot] {
		case .Ice:
			return true
		case .Flood:
			return UnitCanCrossWater(w, unitType, unitKingdom)
		case .None:
		}
	}
	tile := w.groundStorage[index].type
	if UnitValidTileType(unitType, tile) do return true
	if TileIsDeepWater(tile) && UnitCanCrossWater(w, unitType, unitKingdom) {
		return true
	}
	return false
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

// Index-based variant for A*: the caller already resolved the wrapped tile.
WorldStepCostAt :: proc(w: ^World, index: int) -> int {
	if slot := w.tileBuilding[index];
		slot >= 0 && slot < BUILDING_CAPACITY && w.buildingUsed[slot] &&
		BuildingKindOf(w.buildings[slot].type) == .Path {
		return PATH_STEP_COST
	}
	return tileStepCost[w.groundStorage[index].type]
}

// Base speed adjusted by the tile the unit is standing on.
UnitMoveSpeed :: proc(w: ^World, unitSlot: int, baseSpeed: f32) -> f32 {
	speed := baseSpeed
	if w.units[unitSlot].effects[.NoWater] do speed *= 0.7
	tileX := int(WorldWrapPosition(w.units.x[unitSlot], f32(w.maxX)))
	tileY := int(WorldWrapPosition(w.units.y[unitSlot], f32(w.maxY)))
	tile := w.groundStorage[tileX*int(w.maxY)+tileY].type
	if WorldTileHasPath(w, tileX, tileY) {
		speed *= PATH_SPEED_MULTIPLIER*KingdomTechPathSpeedMultiplier(w, w.units[unitSlot].kingdome)
	} else {
		speed /= max(TILE_DEFS[tile].moveCost, 0.1)
	}
	speed *= UnitSeaSpeedMultiplier(w, unitSlot)
	speed *= WorldWeatherMoveFactor(w)
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
	// Positions can grow far past the world size (weather time, drift), so a
	// subtraction loop can spin for millions of iterations. Use fmod instead.
	wrapped := math.mod(position, size)
	if wrapped < 0 do wrapped += size
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
