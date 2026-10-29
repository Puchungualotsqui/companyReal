package main

import "core:fmt"
import "core:sys/info"
import "core:thread"

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

ParallelBody :: #type proc(ctx: rawptr, start, end: int)

ParallelJob :: struct {
	ctx:   rawptr,
	body:  ParallelBody,
	start, end: int,
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

parallelRunJob :: proc(task: thread.Task) {
	job := cast(^ParallelJob)task.data
	job.body(job.ctx, job.start, job.end)
}

// Splits [0, count) into contiguous chunks. Ranges are cache friendly and every
// body only writes inside its own chunk.
ParallelFor :: proc(count: int, ctx: rawptr, body: ParallelBody) {
	if count <= 0 do return
	if !ParallelAvailable() {
		body(ctx, 0, count)
		return
	}

	chunks := min(
		parallelHelperCount*PARALLEL_CHUNKS_PER_THREAD,
		count/PARALLEL_MIN_ITEMS_PER_CHUNK,
	)
	if chunks < 2 {
		body(ctx, 0, count)
		return
	}
	chunkSize := (count+chunks-1)/chunks
	chunks = (count+chunkSize-1)/chunkSize

	jobs: [PARALLEL_MAX_CHUNKS]ParallelJob
	for index in 0..<chunks {
		start := index*chunkSize
		jobs[index] = ParallelJob {
			ctx   = ctx,
			body  = body,
			start = start,
			end   = min(start+chunkSize, count),
		}
	}
	// The caller keeps the first chunk, so the main thread is never idle.
	for index in 1..<chunks {
		thread.pool_add_task(&parallelPool, context.allocator, parallelRunJob, &jobs[index])
	}
	body(ctx, jobs[0].start, jobs[0].end)
	for thread.pool_num_outstanding(&parallelPool) > 0 do thread.yield()
}
