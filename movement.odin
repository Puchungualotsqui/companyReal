package main

import "core:fmt"
import "core:math"
import "core:slice"
import "core:sync"
import "d32"
import rl "vendor:raylib"

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
FLOW_FIELD_REFRESH_TICKS :: u64(FLOW_FIELD_REFRESH_SECONDS/TOWN_SIMULATION_STEP)

// Path tiles are cheap to route through and slightly faster to walk on.
PATH_SPEED_MULTIPLIER :: d32.Value(5*d32.SCALE/4)
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
	builtAtTick: u64, // Simulation tick the field last completed

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
		// Round PLAIN_STEP_COST*moveCost once in Q16.16 instead of f32.
		stepRaw := i64(d32.Raw(def.moveCost))*i64(PLAIN_STEP_COST)
		tileStepCost[tile] = max(1, int((stepRaw+d32.SCALE/2)/d32.SCALE))
	}
	w.tileConstructionBlocked = make([]bool, nodeCount)
	w.tileSiteBlocked = make([]u8, nodeCount)
	w.constructionBlockedTiles = make([dynamic]int, 0, COMBAT_SITE_CAPACITY*16)
	// A* owns its own per-thread scratch; these arrays serve the serial town pass.
	w.navigationCameFrom = make([]int, nodeCount)
	w.navigationQueue = make([]int, nodeCount)
	w.navigationStamp = make([]u32, nodeCount)
	w.flowQueue = make([]int, nodeCount)
	return true
}

WorldNavigationDeinit :: proc(w: ^World) {
	delete(w.tileConstructionBlocked)
	delete(w.tileSiteBlocked)
	delete(w.constructionBlockedTiles)
	delete(w.navigationCameFrom)
	delete(w.navigationQueue)
	delete(w.navigationStamp)
	delete(w.flowQueue)
	for &field in w.flowFields {
		delete(field.direction)
		delete(field.walkMask)
	}
}

AStarNodeState :: enum u8 {
	Unseen,
	Open,
	Closed,
}

// A* arrays are indexed by world tile, so each worker needs its own copy to run
// searches in parallel. One set is about 25 MB on the largest map.
AStarScratch :: struct {
	distance:  []i32, // gScore
	priority:  []i32, // gScore + heuristic
	cameFrom:  []i32,
	heapPos:   []i32,
	queue:     []i32,
	state:     []u8,
	stamp:     []u32,
	searchId:  u32,
	nodeCount: int,
	time:      f64, // Seconds spent searching, merged per tick
	calls:     int,
}

astarScratch: [PARALLEL_MAX_THREADS]AStarScratch

AStarScratchAcquire :: proc(nodeCount: int) -> ^AStarScratch {
	scratch := &astarScratch[parallelThreadSlot]
	if scratch.nodeCount == nodeCount do return scratch
	delete(scratch.distance)
	delete(scratch.priority)
	delete(scratch.cameFrom)
	delete(scratch.heapPos)
	delete(scratch.queue)
	delete(scratch.state)
	delete(scratch.stamp)
	scratch^ = AStarScratch {
		distance  = make([]i32, nodeCount),
		priority  = make([]i32, nodeCount),
		cameFrom  = make([]i32, nodeCount),
		heapPos   = make([]i32, nodeCount),
		queue     = make([]i32, nodeCount),
		state     = make([]u8, nodeCount),
		stamp     = make([]u32, nodeCount),
		nodeCount = nodeCount,
	}
	return scratch
}

AStarScratchDeinit :: proc() {
	for &scratch in astarScratch {
		delete(scratch.distance)
		delete(scratch.priority)
		delete(scratch.cameFrom)
		delete(scratch.heapPos)
		delete(scratch.queue)
		delete(scratch.state)
		delete(scratch.stamp)
		scratch = {}
	}
}

AStarHeapSwap :: #force_inline proc(heap, heapPos, priority: []i32, a, b: int) {
	heap[a], heap[b] = heap[b], heap[a]
	heapPos[heap[a]] = i32(a)
	heapPos[heap[b]] = i32(b)
}

// The heap only compares stored priorities. Recomputing the heuristic here
// used to divide and modulo the tile index on every comparison.
AStarHeapUp :: proc(heap, heapPos, priority: []i32, position: int) {
	current := position
	for current > 0 {
		parent := (current-1)/2
		if priority[heap[current]] >= priority[heap[parent]] do break
		AStarHeapSwap(heap, heapPos, priority, current, parent)
		current = parent
	}
}

AStarHeapDown :: proc(heap, heapPos, priority: []i32, count, position: int) {
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
		AStarHeapSwap(heap, heapPos, priority, current, smallest)
		current = smallest
	}
}

AStar :: proc(w: ^World, unitType: UnitType, unitKingdom: int, startX, startY, goalX, goalY: int, path: ^[dynamic]int, maxExpansions := 0) -> bool {
	started := f64(0)
	if profiler.enabled do started = rl.GetTime()
	defer {
		if profiler.enabled {
			scratch := &astarScratch[parallelThreadSlot]
			scratch.time += rl.GetTime()-started
			scratch.calls += 1
		}
	}
	clear(path)
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 do return false

	nodeCount := worldWidth*worldHeight
	wrappedStartX := WorldWrapCoordinate(startX, worldWidth)
	wrappedStartY := WorldWrapCoordinate(startY, worldHeight)
	wrappedGoalX := WorldWrapCoordinate(goalX, worldWidth)
	wrappedGoalY := WorldWrapCoordinate(goalY, worldHeight)

	startIndex := wrappedStartX*worldHeight + wrappedStartY
	goalIndex := wrappedGoalX*worldHeight + wrappedGoalY

	if !WorldTileWalkableAt(w, goalIndex, unitType, unitKingdom, true) do return false

	scratch := AStarScratchAcquire(nodeCount)
	cameFrom := scratch.cameFrom
	gScore := scratch.distance
	priority := scratch.priority
	state := scratch.state
	openSet := scratch.queue
	heapPos := scratch.heapPos
	stamp := scratch.stamp
	infinity := i32(nodeCount*PLAIN_STEP_COST+1)

	// Stamp touched nodes instead of clearing the whole world for every path.
	scratch.searchId += 1
	if scratch.searchId == 0 {
		for &entry in stamp do entry = 0
		scratch.searchId = 1
	}
	searchId := scratch.searchId

	stamp[startIndex] = searchId
	cameFrom[startIndex] = -1
	gScore[startIndex] = 0
	priority[startIndex] = i32(
		PATH_HEURISTIC_COST*WorldWrapHeuristic(
			wrappedStartX,
			wrappedStartY,
			wrappedGoalX,
			wrappedGoalY,
			worldWidth,
			worldHeight,
		),
	)
	state[startIndex] = u8(AStarNodeState.Open)
	heapPos[startIndex] = 0
	openSet[0] = i32(startIndex)
	openCount := 1

	found := false
	expansions := 0
	for openCount > 0 {
		if maxExpansions > 0 && expansions >= maxExpansions do break
		expansions += 1
		bestIndex := int(openSet[0])
		openCount -= 1
		if openCount > 0 {
			last := int(openSet[openCount])
			openSet[0] = i32(last)
			heapPos[last] = 0
			AStarHeapDown(openSet, heapPos, priority, openCount, 0)
		}
		heapPos[bestIndex] = -1
		state[bestIndex] = u8(AStarNodeState.Closed)
		if bestIndex == goalIndex {
			found = true
			break
		}

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
				state[nextIndex] = u8(AStarNodeState.Unseen)
				heapPos[nextIndex] = -1
			}
			if state[nextIndex] == u8(AStarNodeState.Closed) do continue
			tentativeScore := gScore[bestIndex] + i32(WorldStepCostAt(w, nextIndex))
			if tentativeScore >= gScore[nextIndex] do continue

			cameFrom[nextIndex] = i32(bestIndex)
			gScore[nextIndex] = tentativeScore
			priority[nextIndex] = tentativeScore+i32(
				PATH_HEURISTIC_COST*WorldWrapHeuristic(
					nextX,
					nextY,
					wrappedGoalX,
					wrappedGoalY,
					worldWidth,
					worldHeight,
				),
			)
			if state[nextIndex] == u8(AStarNodeState.Open) {
				AStarHeapUp(openSet, heapPos, priority, int(heapPos[nextIndex]))
			} else if openCount < nodeCount {
				state[nextIndex] = u8(AStarNodeState.Open)
				heapPos[nextIndex] = i32(openCount)
				openSet[openCount] = i32(nextIndex)
				openCount += 1
				AStarHeapUp(openSet, heapPos, priority, int(heapPos[nextIndex]))
			}
		}
	}

	if found {
		cursor := goalIndex
		for {
			append(path, cursor)
			if cursor == startIndex do break
			cursor = int(cameFrom[cursor])
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
// Clearance margins as Q16.16 raw units: 1.25 exact, 0.001 rounded to nearest.
FLEE_MELEE_CLEARANCE_RAW :: i64(81920)
FLEE_CLEARANCE_EPSILON_RAW :: i64(66)

UnitNearbyEnemy :: struct {
	slot: int,
	distanceSquared: u64, // Raw squared units
}

// Invalid world geometry sorts as maximally far instead of being ignored.
UnitEnemyDistanceSquared :: proc(w: ^World, x, y: d32.Value, enemySlot: int) -> u64 {
	distanceSquared, valid := d32.WrappedDistanceSquared(
		x,
		y,
		w.units.x[enemySlot],
		w.units.y[enemySlot],
		i64(w.maxX)*d32.SCALE,
		i64(w.maxY)*d32.SCALE,
	)
	if !valid do return ~u64(0)
	return distanceSquared
}

// A wrapped coordinate interval may cross the short final spatial bucket.
UnitNearbyChunkRangeRaw :: proc(positionRaw, radiusRaw, sizeRaw: i64, chunkSize, chunkCount: int) -> (int, int) {
	if sizeRaw <= 0 || chunkSize <= 0 || chunkCount <= 0 do return 0, 0
	if radiusRaw >= sizeRaw/2 do return 0, chunkCount
	low, high := positionRaw-radiusRaw, positionRaw+radiusRaw
	lowWrapped := low%sizeRaw
	if lowWrapped < 0 do lowWrapped += sizeRaw
	highWrapped := high%sizeRaw
	if highWrapped < 0 do highWrapped += sizeRaw
	first := int(lowWrapped/d32.SCALE)/chunkSize
	last := int(highWrapped/d32.SCALE)/chunkSize
	count := last-first+1
	if low < 0 || high >= sizeRaw do count += chunkCount
	return first, min(count, chunkCount)
}

// Keep only the closest threats, visiting each intersecting wrapped chunk once.
UnitCollectNearbyEnemies :: proc(w: ^World, unitSlot: int, radius: d32.Value, enemies: []UnitNearbyEnemy) -> int {
	if unitSlot < 0 || unitSlot >= UNIT_CAPACITY || !w.unitUsed[unitSlot] ||
		w.units[unitSlot].health <= d32.ZERO || radius < d32.ZERO || len(enemies) == 0 {
				return 0
			}
	if w.maxX <= 0 || w.maxY <= 0 || w.spatial.chunkSize <= 0 ||
		w.spatial.chunksX <= 0 || w.spatial.chunksY <= 0 {
				return 0
			}
	unit := &w.units[unitSlot]
	radiusRaw := i64(d32.Raw(radius))
	radiusSquared := u64(radiusRaw)*u64(radiusRaw)
	firstX, countX := UnitNearbyChunkRangeRaw(
		i64(d32.Raw(unit.x)),
		radiusRaw,
		i64(w.maxX)*d32.SCALE,
		w.spatial.chunkSize,
		w.spatial.chunksX,
	)
	firstY, countY := UnitNearbyChunkRangeRaw(
		i64(d32.Raw(unit.y)),
		radiusRaw,
		i64(w.maxY)*d32.SCALE,
		w.spatial.chunkSize,
		w.spatial.chunksY,
	)
	count := 0
	for ox in 0..<countX {
		cx := WorldWrapCoordinate(firstX+ox, w.spatial.chunksX)
		for oy in 0..<countY {
			cy := WorldWrapCoordinate(firstY+oy, w.spatial.chunksY)
			chunk := cx*w.spatial.chunksY+cy
			if !SpatialChunkHasEnemy(w, chunk, unit.kingdome) do continue
			for other := w.spatial.unitHead[chunk]; other >= 0; other = w.spatial.unitNext[other] {
				if other == unitSlot || !w.unitUsed[other] || w.units[other].health <= d32.ZERO do continue
				if !KingdomAtWar(w, unit.kingdome, w.units[other].kingdome) || UnitHiddenInside(w, other) do continue
				distanceSquared := UnitEnemyDistanceSquared(w, unit.x, unit.y, other)
				if distanceSquared > radiusSquared do continue
				position := 0
				for position < count {
					entry := enemies[position]
					if distanceSquared < entry.distanceSquared ||
						(distanceSquared == entry.distanceSquared && other < entry.slot) {
						break
					}
					position += 1
				}
				if position >= len(enemies) do continue
				count = min(count+1, len(enemies))
				for i := count-1; i > position; i -= 1 do enemies[i] = enemies[i-1]
				enemies[position] = UnitNearbyEnemy{other, distanceSquared}
			}
		}
	}
	return count
}

// Visible means outdoors, not player fog-of-war or line of sight.
UnitFindNearbyEnemy :: proc(w: ^World, unitSlot: int, radius: d32.Value) -> int {
	enemies: [1]UnitNearbyEnemy
	if UnitCollectNearbyEnemies(w, unitSlot, radius, enemies[:]) == 0 do return -1
	return enemies[0].slot
}

UnitFleeClearanceSquared :: proc(w: ^World, x, y: d32.Value, enemies: []UnitNearbyEnemy) -> u64 {
	clearance := ~u64(0)
	for enemy in enemies {
		clearance = min(clearance, UnitEnemyDistanceSquared(w, x, y, enemy.slot))
	}
	return clearance
}

// Builds at most 85 reachable nodes, with no full-map A*. Shared navigation
// scratch is stamped, while the resulting short route belongs to the unit.
UnitFindEscapePath :: proc(w: ^World, unitSlot: int, enemies: []UnitNearbyEnemy) -> bool {
	unit := &w.units[unitSlot]
	width, height := int(w.maxX), int(w.maxY)
	startX := UnitTileX(w, unitSlot)
	startY := UnitTileY(w, unitSlot)
	start := startX*height+startY
	clear(&unit.path)
	unit.pathFound = false
	unit.pathReady = true
	unit.pathRevision = w.pathRevision
	unit.pathIndex = 0
	// Cache failure until the primary threat changes tile or navigation changes.
	unit.pathTargetX = UnitTileX(w, enemies[0].slot)
	unit.pathTargetY = UnitTileY(w, enemies[0].slot)
	if len(w.navigationStamp) < width*height || len(w.navigationQueue) < width*height ||
		len(w.navigationCameFrom) < width*height {
				return false
			}
	scratch := NavBfsReset()
	queue := scratch.queue[:]
	depth: [FLEE_SEARCH_CAPACITY]int
	routeClearance: [FLEE_SEARCH_CAPACITY]f32
	startClearanceSquared := UnitFleeClearanceSquared(w, w.units.x[unitSlot], w.units.y[unitSlot], enemies)
	startClearanceRaw := d32.SqrtRaw(startClearanceSquared)
	startClearance := RawToF32(startClearanceRaw)
	// Do not escape through an enemy's immediate melee space, unless already
	// that close; compare the exact squared raw threshold instead.
	meleeClearanceRaw := min(startClearanceRaw, FLEE_MELEE_CLEARANCE_RAW)
	meleeClearanceSquared := u64(meleeClearanceRaw)*u64(meleeClearanceRaw)
	routeClearance[0] = startClearance
	queue[0] = start
	NavBfsVisit(scratch, start)
	queueEnd := 1
	best, bestScore := start, startClearance
	for cursor := 0; cursor < queueEnd; cursor += 1 {
		index := queue[cursor]
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
			slot, fresh := NavBfsVisit(scratch, next)
			if !fresh do continue
			if !WorldTileWalkable(w, nx, ny, unit.type, unit.kingdome) do continue
			clearanceSquared := UnitFleeClearanceSquared(w, TileCenterPosition(nx), TileCenterPosition(ny), enemies)
			if clearanceSquared < meleeClearanceSquared do continue
			clearance := RawToF32(d32.SqrtRaw(clearanceSquared))
			if queueEnd >= FLEE_SEARCH_CAPACITY do continue
			scratch.parents[slot] = i32(index)
			depth[queueEnd] = depth[cursor]+1
			routeClearance[queueEnd] = min(routeClearance[cursor], clearance)
			score := clearance-0.15*f32(depth[queueEnd])-
				2*max(0, startClearance-routeClearance[queueEnd])
			if score > bestScore+0.001 do best, bestScore = next, score
			queue[queueEnd] = next
			queueEnd += 1
		}
	}
	if best == start do return false
	unit.pathTargetX, unit.pathTargetY = best/height, best%height
	for cursor := best; cursor >= 0; cursor = NavBfsParent(scratch, cursor) {
		append(&unit.path, cursor)
	}
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
		w.units[unitSlot].health <= d32.ZERO || deltaTime < 0 || w.maxX <= 0 || w.maxY <= 0 {
				return false
			}
	unit := &w.units[unitSlot]
	if enemySlot < 0 || enemySlot >= UNIT_CAPACITY || !w.unitUsed[enemySlot] ||
		w.units[enemySlot].health <= d32.ZERO || UnitHiddenInside(w, enemySlot) ||
		!KingdomAtWar(w, unit.kingdome, w.units[enemySlot].kingdome) || UnitHiddenInside(w, unitSlot) {
		unit.pathReady, unit.pathFound = false, false
		return false
	}
	// Include the explicit threat even if outside the local radius or crowded out.
	threats: [FLEE_CLEARANCE_ENEMIES]UnitNearbyEnemy
	threats[0] = UnitNearbyEnemy{enemySlot, 0}
	count := 1+UnitCollectNearbyEnemies(w, unitSlot, d32.FromInt(FLEE_THREAT_RADIUS), threats[1:])
	enemies := threats[:count]
	clearanceSquared := UnitFleeClearanceSquared(w, w.units.x[unitSlot], w.units.y[unitSlot], enemies)
	clearanceRaw := d32.SqrtRaw(clearanceSquared)
	// Waypoint clearance must stay within 0.001 of min(clearance, 1.25).
	waypointMarginRaw := min(clearanceRaw, FLEE_MELEE_CLEARANCE_RAW)-FLEE_CLEARANCE_EPSILON_RAW
	waypointMarginSquared := u64(0)
	if waypointMarginRaw > 0 do waypointMarginSquared = u64(waypointMarginRaw)*u64(waypointMarginRaw)
	// Do not replan just because the world changed somewhere else; the route
	// checks below detect an actual blockage or a worse local escape.
	replan := !unit.pathReady
	if !replan && !unit.pathFound {
		replan = unit.pathTargetX != UnitTileX(w, enemySlot) ||
			unit.pathTargetY != UnitTileY(w, enemySlot)
	}
	if !replan && unit.pathFound {
		// Target clearance plus 0.5 must still beat the current clearance.
		targetMarginRaw := clearanceRaw-i64(d32.HALF)
		targetMarginSquared := u64(0)
		if targetMarginRaw > 0 do targetMarginSquared = u64(targetMarginRaw)*u64(targetMarginRaw)
		targetClearanceSquared := UnitFleeClearanceSquared(
			w,
			TileCenterPosition(unit.pathTargetX),
			TileCenterPosition(unit.pathTargetY),
			enemies,
		)
		replan = unit.pathIndex >= len(unit.path) || targetClearanceSquared < targetMarginSquared
		if !replan {
			next := unit.path[unit.pathIndex]
			nx, ny := next/int(w.maxY), next%int(w.maxY)
			nextClearanceSquared := UnitFleeClearanceSquared(w, TileCenterPosition(nx), TileCenterPosition(ny), enemies)
			replan = !WorldTileWalkable(w, nx, ny, unit.type, unit.kingdome) ||
				nextClearanceSquared < waypointMarginSquared
		}
	}
	if replan && !UnitFindEscapePath(w, unitSlot, enemies) do return false
	if !unit.pathFound do return false
	remaining := d32.Mul(
		UnitMoveSpeed(w, unitSlot, UnitDefaultSpeed(unit.type)),
		PositionFromF32(deltaTime),
	)
	for _ in 0..<FLEE_SEARCH_STEPS {
		if remaining <= d32.ZERO || unit.pathIndex >= len(unit.path) do break
		next := unit.path[unit.pathIndex]
		nx, ny := next/int(w.maxY), next%int(w.maxY)
		// Check each waypoint, including when a long tick consumes several.
		nextClearanceSquared := UnitFleeClearanceSquared(w, TileCenterPosition(nx), TileCenterPosition(ny), enemies)
		if nextClearanceSquared < waypointMarginSquared {
			unit.pathReady = false
			return false
		}
		reached, blocked, left := UnitStepTowards(w, unitSlot, TileCenterPosition(nx), TileCenterPosition(ny), remaining)
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
	remaining := d32.Mul(
		UnitMoveSpeed(w, unitSlot, UnitDefaultSpeed(unit.type)),
		PositionFromF32(deltaTime),
	)
	for remaining > d32.ZERO && unit.pathIndex < len(unit.path) {
		next := unit.path[unit.pathIndex]
		nx, ny := next/int(w.maxY), next%int(w.maxY)
		reached, blocked, left := UnitStepTowards(
			w,
			unitSlot,
			TileCenterPosition(nx),
			TileCenterPosition(ny),
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
		if WorldCurrentTick(w)-field.builtAtTick < FLOW_FIELD_REFRESH_TICKS {
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
	start:    int,
}

FlowMaskBuildTiles :: proc(ctx: rawptr, startIndex, endIndex: int, worker: int) {
	job := cast(^FlowMaskJob)ctx
	for offset in startIndex..<endIndex {
		index := job.start+offset
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
		count := min(max(budget^, 0), worldWidth*worldHeight-field.maskIndex)
		job := FlowMaskJob {
			w        = w,
			mask     = mask,
			walkType = walkType,
			kingdom  = field.unitKingdom,
			start    = field.maskIndex,
		}
		ParallelFor(count, &job, FlowMaskBuildTiles)
		budget^ -= count
		field.maskIndex += count
		field.maskX = field.maskIndex/worldHeight
		field.maskY = field.maskIndex%worldHeight
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
			field.builtAtTick = WorldCurrentTick(w)
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
	field.builtAtTick = WorldCurrentTick(w)
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

	remaining := d32.Mul(speed, PositionFromF32(deltaTime))
	worldWidth := int(w.maxX)
	worldHeight := int(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 do return .Unreachable

	for _ in 0..<FLOW_FIELD_MAX_STEPS {
		tileX := UnitTileX(w, unitSlot)
		tileY := UnitTileY(w, unitSlot)
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
			TileCenterPosition(nextX),
			TileCenterPosition(nextY),
			remaining,
		)
		if blocked do return .Unreachable
		remaining = left
		if !reached do return .Travelling
		if remaining <= d32.ZERO do return .Travelling
	}
	return .Travelling
}

// Choose a reachable work point without routing through the proposed footprint.
// This also works before the site is reserved (for founding-order validation).
WORK_ACCESS_MAX_EXPANSIONS :: 256

BuildingFindWorkAccessPoint :: proc(w: ^World, x, y, width, height: int, unitType: UnitType, kingdom, startX, startY: int) -> (int, int, bool) {
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
				deltaX := wrappedX-startTileX
				deltaY := wrappedY-startTileY
				if deltaX > worldWidth/2 do deltaX -= worldWidth
				if deltaX < -(worldWidth/2) do deltaX += worldWidth
				if deltaY > worldHeight/2 do deltaY -= worldHeight
				if deltaY < -(worldHeight/2) do deltaY += worldHeight
				distance := deltaX*deltaX+deltaY*deltaY
				if distance < fallbackDistance {
					fallbackDistance = distance
					fallbackX, fallbackY = wrappedX, wrappedY
				}
			}
		}
		if workRadius > 0 do break
	}
	if workRadius == 0 do return 0, 0, false
	scratch := NavBfsReset()
	queue := scratch.queue[:]
	start := WorldWrapCoordinate(startX, worldWidth)*worldHeight+WorldWrapCoordinate(startY, worldHeight)
	queue[0] = start
	NavBfsVisit(scratch, start)
	queueEnd := 1
	expansions := 0
	for cursor := 0; cursor < queueEnd && expansions < WORK_ACCESS_MAX_EXPANSIONS; cursor += 1 {
		expansions += 1
		index := queue[cursor]
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
			if _, fresh := NavBfsVisit(scratch, nextIndex); !fresh do continue
			if !WorldTileWalkable(w, nextX, nextY, unitType, kingdom) do continue
			queue[queueEnd] = nextIndex
			queueEnd += 1
		}
	}
	return fallbackX, fallbackY, true
}

// Search through the footprint only, stopping at its first walkable exit. This
// avoids moving an occupant across water, other buildings or neighboring sites.
UnitFindBuildingExit :: proc(w: ^World, unitSlot, x, y, width, height: int) -> (int, int, bool) {
	unit := &w.units[unitSlot]
	worldWidth, worldHeight := int(w.maxX), int(w.maxY)
	scratch := NavBfsReset()
	queue := scratch.queue[:]
	start := UnitTileX(w, unitSlot)*worldHeight+UnitTileY(w, unitSlot)
	queue[0] = start
	NavBfsVisit(scratch, start)
	queueEnd := 1
	for cursor := 0; cursor < queueEnd; cursor += 1 {
		index := queue[cursor]
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
			if _, fresh := NavBfsVisit(scratch, nextIndex); !fresh do continue
			inside := nextX >= x && nextX < x+width && nextY >= y && nextY < y+height
			if !inside {
				if WorldTileWalkable(w, nextX, nextY, unit.type, unit.kingdome) {
					return nextX, nextY, true
				}
				continue
			}
			if !WorldTileWalkableBase(w, nextX, nextY, unit.type, unit.kingdome) do continue
			queue[queueEnd] = nextIndex
			queueEnd += 1
		}
	}
	return 0, 0, false
}

// Short errands inside a town are usually clear ground. Walking an L-shaped
// line is far cheaper than an A* search, and the tiles are validated in the
// same axis order UnitMove steps through them.
DIRECT_PATH_MAX_TILES :: 10

UnitDirectPath :: proc(
	w: ^World,
	type: UnitType,
	kingdomSlot, startX, startY, targetX, targetY: int,
	path: ^[dynamic]int,
) -> bool {
	worldWidth, worldHeight := int(w.maxX), int(w.maxY)
	if worldWidth <= 0 || worldHeight <= 0 do return false
	dx := targetX-startX
	dy := targetY-startY
	if dx > worldWidth/2 do dx -= worldWidth
	if dx < -worldWidth/2 do dx += worldWidth
	if dy > worldHeight/2 do dy -= worldHeight
	if dy < -worldHeight/2 do dy += worldHeight
	steps := abs(dx)+abs(dy)
	if steps <= 0 || steps > DIRECT_PATH_MAX_TILES do return false

	clear(path)
	x, y := WorldWrapCoordinate(startX, worldWidth), WorldWrapCoordinate(startY, worldHeight)
	stepX := dx > 0 ? 1 : dx < 0 ? -1 : 0
	stepY := dy > 0 ? 1 : dy < 0 ? -1 : 0
	for _ in 0..<abs(dx) {
		x = WorldWrapCoordinate(x+stepX, worldWidth)
		if !WorldTileWalkable(w, x, y, type, kingdomSlot) {
			clear(path)
			return false
		}
		append(path, x*worldHeight+y)
	}
	for _ in 0..<abs(dy) {
		y = WorldWrapCoordinate(y+stepY, worldHeight)
		if !WorldTileWalkable(w, x, y, type, kingdomSlot) {
			clear(path)
			return false
		}
		append(path, x*worldHeight+y)
	}
	return len(path) > 0
}

UnitStepTowards :: proc(w: ^World, unitSlot: int, targetX, targetY: d32.Value, distance: d32.Value) -> (reached: bool, blocked: bool, remaining: d32.Value) {
	remaining = distance
	if unitSlot < 0 || unitSlot >= UNIT_CAPACITY || !w.unitUsed[unitSlot] {
		return false, true, remaining
	}
	width := i64(w.maxX)*d32.SCALE
	height := i64(w.maxY)*d32.SCALE
	if width <= 0 || height <= 0 do return false, true, remaining

	unit := &w.units[unitSlot]
	defer SpatialUnitMove(w, unitSlot)
	targetPositionX, validTargetX := d32.WrapRaw(
		i64(d32.Raw(targetX)),
		d32.ZERO,
		width,
	)
	targetPositionY, validTargetY := d32.WrapRaw(
		i64(d32.Raw(targetY)),
		d32.ZERO,
		height,
	)
	if !validTargetX || !validTargetY do return false, true, remaining
	remainingRaw := i64(d32.Raw(remaining))
	for remainingRaw > UNIT_POSITION_EPSILON_RAW {
		distanceSquared, valid := d32.WrappedDistanceSquared(
			unit.x,
			unit.y,
			targetPositionX,
			targetPositionY,
			width,
			height,
		)
		if !valid do return false, true, d32.FromRaw(i32(remainingRaw))
		distanceToTarget := d32.SqrtRaw(distanceSquared)
		if distanceToTarget <= UNIT_POSITION_EPSILON_RAW {
			SetUnitPosition(w, unitSlot, targetPositionX, targetPositionY)
			return true, false, d32.FromRaw(i32(remainingRaw))
		}

		deltaX, validX := d32.ShortestWrappedDelta(unit.x, targetPositionX, width)
		deltaY, validY := d32.ShortestWrappedDelta(unit.y, targetPositionY, height)
		if !validX || !validY do return false, true, d32.FromRaw(i32(remainingRaw))
		step := min(distanceToTarget, remainingRaw, d32.SCALE)
		stepX := deltaX*step/distanceToTarget
		stepY := deltaY*step/distanceToTarget
		nextX, _ := d32.AddRawWrapped(i64(d32.Raw(unit.x)), stepX, d32.ZERO, width)
		nextY, _ := d32.AddRawWrapped(i64(d32.Raw(unit.y)), stepY, d32.ZERO, height)
		tileX := int(d32.ToInt(nextX))
		tileY := int(d32.ToInt(nextY))
		currentTileX := UnitTileX(w, unitSlot)
		currentTileY := UnitTileY(w, unitSlot)
		if (tileX != currentTileX || tileY != currentTileY) &&
			!WorldTileWalkable(w, tileX, tileY, unit.type, unit.kingdome) {
			return false, true, d32.FromRaw(i32(remainingRaw))
		}
		if (tileX != currentTileX || tileY != currentTileY) &&
			WorldTileFriendlyWall(w, tileX, tileY, unit.kingdome) {
			unit.jumpStarted = w.simulationTime
		}

		SetUnitPosition(w, unitSlot, nextX, nextY)
		remainingRaw -= step
		if step >= distanceToTarget {
			SetUnitPosition(w, unitSlot, targetPositionX, targetPositionY)
			return true, false, d32.FromRaw(i32(remainingRaw))
		}
	}
	return false, false, d32.FromRaw(i32(remainingRaw))
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
UnitMoveSpeed :: proc(w: ^World, unitSlot: int, baseSpeed: d32.Value) -> d32.Value {
	speed := baseSpeed
	if w.units[unitSlot].effects[.NoWater] do speed = d32.Mul(speed, d32.FromRatio(7, 10))
	tileX := UnitTileX(w, unitSlot)
	tileY := UnitTileY(w, unitSlot)
	tile := w.groundStorage[tileX*int(w.maxY)+tileY].type
	if WorldTileHasPath(w, tileX, tileY) {
		speed = d32.Mul(
			speed,
			d32.Mul(PATH_SPEED_MULTIPLIER, KingdomTechPathSpeedMultiplier(w, w.units[unitSlot].kingdome)),
		)
	} else {
		speed = d32.Div(speed, max(TILE_DEFS[tile].moveCost, d32.FromRatio(1, 10)))
	}
	speed = d32.Mul(speed, UnitSeaSpeedMultiplier(w, unitSlot))
	speed = d32.Mul(speed, WorldWeatherMoveFactor(w))
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

// Raw Q16.16 units as f32 world units.
RawToF32 :: proc(raw: i64) -> f32 {
	return f32(raw)/f32(d32.SCALE)
}

// Q16.16 value as f32 world units.
PositionToF32 :: proc(value: d32.Value) -> f32 {
	return RawToF32(i64(d32.Raw(value)))
}

// Rounds to the nearest raw Q16.16 unit, ties away from zero. Values outside the
// d32 range saturate to MIN/MAX instead of wrapping; NaN becomes ZERO.
PositionFromF32 :: proc(value: f32) -> d32.Value {
	scaled := f64(value)*f64(d32.SCALE)
	if math.is_nan(scaled) do return d32.ZERO
	if scaled >= f64(d32.Raw(d32.MAX)) do return d32.MAX
	if scaled <= f64(d32.Raw(d32.MIN)) do return d32.MIN
	if scaled < 0 do return d32.FromRaw(i32(i64(scaled-0.5)))
	return d32.FromRaw(i32(i64(scaled+0.5)))
}

// Raw distance below which two positions count as the same point (~1e-4 units).
UNIT_POSITION_EPSILON_RAW :: i64(6)

// Temporary f32 adapters for readers that still consume float positions.
UnitX :: proc(w: ^World, slot: int) -> f32 {
	return PositionToF32(w.units.x[slot])
}

UnitY :: proc(w: ^World, slot: int) -> f32 {
	return PositionToF32(w.units.y[slot])
}

UnitPrevX :: proc(w: ^World, slot: int) -> f32 {
	return PositionToF32(w.units.previousX[slot])
}

UnitPrevY :: proc(w: ^World, slot: int) -> f32 {
	return PositionToF32(w.units.previousY[slot])
}

SetUnitPosition :: proc(w: ^World, slot: int, x, y: d32.Value) {
	w.units.x[slot] = x
	w.units.y[slot] = y
}

// Wrapped tile holding the unit's position.
UnitTileX :: proc(w: ^World, slot: int) -> int {
	wrapped, valid := d32.WrapRaw(i64(d32.Raw(w.units.x[slot])), d32.ZERO, i64(w.maxX)*d32.SCALE)
	if !valid do return 0
	return int(d32.ToInt(wrapped))
}

UnitTileY :: proc(w: ^World, slot: int) -> int {
	wrapped, valid := d32.WrapRaw(i64(d32.Raw(w.units.y[slot])), d32.ZERO, i64(w.maxY)*d32.SCALE)
	if !valid do return 0
	return int(d32.ToInt(wrapped))
}

// Center of an already-wrapped tile index.
TileCenterRaw :: proc(tile: int) -> f32 {
	return f32(tile)+0.5
}

// Center of an already-wrapped tile index in Q16.16 raw units.
TileCenterPosition :: proc(tile: int) -> d32.Value {
	return d32.FromRaw(i32(i64(tile)*d32.SCALE+i64(d32.HALF)))
}

// Wrapped tile index containing a Q16.16 position.
PositionTile :: proc(value: d32.Value, size: int) -> int {
	if size <= 0 do return 0
	wrapped, valid := d32.WrapRaw(i64(d32.Raw(value)), d32.ZERO, i64(size)*d32.SCALE)
	if !valid do return 0
	return int(d32.ToInt(wrapped))
}

// Center of a tile index, wrapped into the world first.
TileCenter :: proc(tile, size: int) -> f32 {
	return TileCenterRaw(WorldWrapCoordinate(tile, size))
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
