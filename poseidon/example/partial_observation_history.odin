package main

// Run with: odin run example/partial_observation_history.odin -file
import "../rl"
import "core:fmt"

OBS_HISTORY_DEPTH :: 3
OBS_HISTORY_WIDTH :: 2

main :: proc() {
	historyStorage: [OBS_HISTORY_DEPTH*OBS_HISTORY_WIDTH]f32
	history: rl.ObservationHistory
	assert(rl.ObservationHistoryInit(&history, historyStorage[:], OBS_HISTORY_DEPTH, OBS_HISTORY_WIDTH))
	flattened: [OBS_HISTORY_DEPTH*OBS_HISTORY_WIDTH]f32

	// Each observation omits velocity; a short history exposes its recent trend.
	firstObservation := [OBS_HISTORY_WIDTH]f32{0.1, 0.5}
	secondObservation := [OBS_HISTORY_WIDTH]f32{0.2, 0.5}
	thirdObservation := [OBS_HISTORY_WIDTH]f32{0.3, 0.5}
	assert(rl.ObservationHistoryPush(&history, firstObservation[:]))
	assert(rl.ObservationHistoryFlatten(&history, flattened[:]))
	fmt.printf("After first observation (left zero-padded): %v\n", flattened)
	assert(rl.ObservationHistoryPush(&history, secondObservation[:]))
	assert(rl.ObservationHistoryPush(&history, thirdObservation[:]))
	assert(rl.ObservationHistoryFlatten(&history, flattened[:]))
	fmt.printf("Full chronological feature window: %v\n", flattened)

	// A new episode starts with no frames from the previous episode.
	assert(rl.ObservationHistoryReset(&history))
	assert(rl.ObservationHistoryPush(&history, firstObservation[:]))
	assert(rl.ObservationHistoryFlatten(&history, flattened[:]))
	fmt.printf("First frame after episode reset: %v\n", flattened)
}
