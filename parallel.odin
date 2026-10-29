package main

import "base:intrinsics"
import "core:fmt"
import "core:sync"
import "core:sys/info"
import "core:thread"
import "core:time"

// Coarse fork/join parallelism. A persistent pool is sized from the machine at
// startup; passes only submit ranges and join before returning. Bodies run on
// helper threads: they must only read shared state and write inside their own
// range, with no allocation and no profiler calls.
PARALLEL_ENABLED :: true

// Splitting a range into smaller pieces costs more in task setup than it saves.
PARALLEL_MIN_ITEMS_PER_CHUNK :: 4
// Chunks per helper; more chunks let cheap and expensive items balance out.
PARALLEL_CHUNKS_PER_THREAD :: 4
PARALLEL_MAX_CHUNKS :: 128

// Bodies run on helper threads: they must only read shared state and write
// inside their own range. `worker` identifies the chunk (0 is the caller), so
// passes can keep per-worker accumulators instead of locking.
ParallelBody :: #type proc(ctx: rawptr, start, end, worker: int)

ParallelJob :: struct {
	ctx:   rawptr,
	body:  ParallelBody,
	start, end: int,
	worker: int,
}

parallelPool: thread.Pool
parallelHelperCount: int // Helper threads, excluding the caller
parallelReady: bool

// --- bounded search scratch --------------------------------------------------
// Flee, work-access, building-exit and water searches are small, but they used
// to share the A* arrays under a lock, so every collector and fleeing civilian
// serialized with everything else. Each thread now owns a queue plus a
// generation-stamped visited set, which needs no clearing between searches.
NAV_BFS_CAPACITY :: 4096
NAV_BFS_SLOTS :: 8192 // Power of two, kept at most half full
PARALLEL_MAX_THREADS :: 34

NavBfsScratch :: struct {
	queue:      [NAV_BFS_CAPACITY]int,
	keys:       [NAV_BFS_SLOTS]i32,
	parents:    [NAV_BFS_SLOTS]i32,
	gens:       [NAV_BFS_SLOTS]u32,
	generation: u32,
	count:      int,
}

navBfsScratch: [PARALLEL_MAX_THREADS]NavBfsScratch
parallelThreadCounter: i32

// Thread slot used to pick this thread's scratch. The caller thread is 0.
@(thread_local) parallelThreadSlot: int

parallelThreadInit :: proc(t: ^thread.Thread, user_data: rawptr) {
	parallelThreadSlot = min(
		int(intrinsics.atomic_add(&parallelThreadCounter, 1))+1,
		PARALLEL_MAX_THREADS-1,
	)
}

NavBfsReset :: proc() -> ^NavBfsScratch {
	scratch := &navBfsScratch[parallelThreadSlot]
	scratch.generation += 1
	if scratch.generation == 0 {
		for &gen in scratch.gens do gen = 0
		scratch.generation = 1
	}
	scratch.count = 0
	return scratch
}

// Marks a tile as visited. `fresh` is false when another node already reached
// it during this search. `slot` is always valid for setting the parent.
NavBfsVisit :: proc(scratch: ^NavBfsScratch, index: int) -> (slot: int, fresh: bool) {
	mask := u32(NAV_BFS_SLOTS-1)
	probe := (u32(index)*0x9E3779B1) & mask
	for _ in 0..<NAV_BFS_SLOTS {
		if scratch.gens[probe] != scratch.generation {
			if scratch.count >= NAV_BFS_SLOTS/2 do return -1, false
			scratch.gens[probe] = scratch.generation
			scratch.keys[probe] = i32(index)
			scratch.parents[probe] = -1
			scratch.count += 1
			return int(probe), true
		}
		if scratch.keys[probe] == i32(index) do return int(probe), false
		probe = (probe+1) & mask
	}
	return -1, false
}

NavBfsParent :: proc(scratch: ^NavBfsScratch, index: int) -> int {
	mask := u32(NAV_BFS_SLOTS-1)
	probe := (u32(index)*0x9E3779B1) & mask
	for _ in 0..<NAV_BFS_SLOTS {
		if scratch.gens[probe] != scratch.generation do return -1
		if scratch.keys[probe] == i32(index) do return int(scratch.parents[probe])
		probe = (probe+1) & mask
	}
	return -1
}

// Helpers leave one core to the calling (simulation or render) thread. The
// count comes from the machine instead of a fixed constant.
ParallelInit :: proc() {
	if !PARALLEL_ENABLED do return
	physical, logical, ok := info.cpu_core_count()
	cores := physical
	if !ok || cores <= 0 do cores = logical
	parallelHelperCount = clamp(
		cores-1,
		0,
		PARALLEL_MAX_CHUNKS/PARALLEL_CHUNKS_PER_THREAD,
	)
	if parallelHelperCount <= 0 do return

	parallelThreadCounter = 0
	thread.pool_init(&parallelPool, context.allocator, parallelHelperCount, parallelThreadInit)
	thread.pool_start(&parallelPool)
	parallelReady = true
	if PROFILING_ENABLED do fmt.printfln("PARALLEL helpers=%d", parallelHelperCount)
}

ParallelDeinit :: proc() {
	if parallelReady {
		for thread.pool_num_outstanding(&parallelPool) > 0 do thread.yield()
		thread.pool_join(&parallelPool)
		thread.pool_destroy(&parallelPool)
		parallelReady = false
	}
	AStarScratchDeinit()
}

ParallelAvailable :: proc() -> bool {
	return parallelReady
}

// Recursive lock for the shared unit state. Sections are short, so it spins
// briefly and then sleeps with a growing backoff: a pure spin from a dozen
// workers saturates the bus, and the OS recursive mutex can lose a wakeup.
RecursiveLock :: struct {
	owner: u32, // Thread holding it, 0 when free
	depth: int,
}

RecursiveLockAcquire :: proc(l: ^RecursiveLock) {
	tid := u32(sync.current_thread_id())
	if intrinsics.atomic_load_explicit(&l.owner, .Acquire) == tid {
		l.depth += 1
		return
	}
	spins := 0
	backoff := time.Microsecond
	for {
		if intrinsics.atomic_compare_exchange_weak_explicit(
			&l.owner,
			u32(0),
			tid,
			.Acquire,
			.Relaxed,
		) == 0 {
			break
		}
		if spins < 256 {
			intrinsics.cpu_relax()
			spins += 1
			continue
		}
		time.sleep(backoff)
		if backoff < 200*time.Microsecond do backoff *= 2
	}
	l.depth = 1
}

RecursiveLockRelease :: proc(l: ^RecursiveLock) {
	l.depth -= 1
	if l.depth > 0 do return
	intrinsics.atomic_store_explicit(&l.owner, 0, .Release)
}

@(deferred_in=RecursiveLockRelease)
RecursiveLockGuard :: proc(l: ^RecursiveLock) -> bool {
	RecursiveLockAcquire(l)
	return true
}

// Hits collected by the parallel unit loop and applied in one serial pass.
PARALLEL_PENDING_DAMAGE :: 512

PendingDamage :: struct {
	victim: int,
	damage: f32,
	sourceX, sourceY: f32,
	kind: DamageKind,
}

pendingDamage: [PARALLEL_MAX_THREADS][PARALLEL_PENDING_DAMAGE]PendingDamage
pendingDamageCount: [PARALLEL_MAX_THREADS]int

// Construction work is accumulated per worker and applied in one serial pass.
// Taking the shared unit lock for every builder update serialized every builder
// in the world at high populations.
PARALLEL_PENDING_CONSTRUCTION :: 512

PendingConstruction :: struct {
	kingdom, town, site: int,
	amount:             f32,
}

pendingConstruction: [PARALLEL_MAX_THREADS][PARALLEL_PENDING_CONSTRUCTION]PendingConstruction
pendingConstructionCount: [PARALLEL_MAX_THREADS]int

ParallelQueueConstruction :: proc(
	kingdom, town, site: int,
	amount: f32,
) {
	slot := parallelThreadSlot
	count := pendingConstructionCount[slot]
	if count >= PARALLEL_PENDING_CONSTRUCTION do return
	pendingConstruction[slot][count] = PendingConstruction {
		kingdom = kingdom,
		town    = town,
		site    = site,
		amount  = amount,
	}
	pendingConstructionCount[slot] = count+1
}

parallelRunJob :: proc(task: thread.Task) {
	job := cast(^ParallelJob)task.data
	job.body(job.ctx, job.start, job.end, job.worker)
}

// Splits [0, count) into contiguous chunks. Ranges are cache friendly and every
// body only writes inside its own chunk.
ParallelFor :: proc(count: int, ctx: rawptr, body: ParallelBody) {
	if count <= 0 do return
	if !ParallelAvailable() {
		body(ctx, 0, count, 0)
		return
	}

	chunks := min(
		parallelHelperCount*PARALLEL_CHUNKS_PER_THREAD,
		count/PARALLEL_MIN_ITEMS_PER_CHUNK,
	)
	if chunks < 2 {
		body(ctx, 0, count, 0)
		return
	}
	chunkSize := (count+chunks-1)/chunks
	chunks = (count+chunkSize-1)/chunkSize

	jobs: [PARALLEL_MAX_CHUNKS]ParallelJob
	for index in 0..<chunks {
		start := index*chunkSize
		jobs[index] = ParallelJob {
			ctx    = ctx,
			body   = body,
			start  = start,
			end    = min(start+chunkSize, count),
			worker = index,
		}
	}
	// The caller keeps the first chunk, so the main thread is never idle.
	for index in 1..<chunks {
		thread.pool_add_task(&parallelPool, context.allocator, parallelRunJob, &jobs[index])
	}
	body(ctx, jobs[0].start, jobs[0].end, 0)
	for thread.pool_num_outstanding(&parallelPool) > 0 do thread.yield()
}
