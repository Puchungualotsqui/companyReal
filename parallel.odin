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

	thread.pool_init(&parallelPool, context.allocator, parallelHelperCount)
	thread.pool_start(&parallelPool)
	parallelReady = true
	if PROFILING_ENABLED do fmt.printfln("PARALLEL helpers=%d", parallelHelperCount)
}

ParallelDeinit :: proc() {
	if !parallelReady do return
	for thread.pool_num_outstanding(&parallelPool) > 0 do thread.yield()
	thread.pool_join(&parallelPool)
	thread.pool_destroy(&parallelPool)
	parallelReady = false
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
