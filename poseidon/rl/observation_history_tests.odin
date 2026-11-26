package rl

import "core:testing"

@(test)
ObservationHistoryPadsRollsAndResets :: proc(t: ^testing.T) {
	storage: [6]f32
	history: ObservationHistory
	initialized := ObservationHistoryInit(&history, storage[:], 3, 2)
	testing.expect(t, initialized && ObservationHistoryValid(&history))
	if !initialized { return }
	flattened: [6]f32
	testing.expect(t, ObservationHistoryFlatten(&history, flattened[:]))
	testing.expect(t, flattened == [6]f32{})

	first := [2]f32{1, 10}
	second := [2]f32{2, 20}
	third := [2]f32{3, 30}
	fourth := [2]f32{4, 40}
	testing.expect(t, ObservationHistoryPush(&history, first[:]))
	testing.expect(t, ObservationHistoryFlatten(&history, flattened[:]))
	testing.expect(t, flattened == [6]f32{0, 0, 0, 0, 1, 10})
	testing.expect(t, ObservationHistoryPush(&history, second[:]))
	testing.expect(t, ObservationHistoryFlatten(&history, flattened[:]))
	testing.expect(t, flattened == [6]f32{0, 0, 1, 10, 2, 20})
	testing.expect(t, ObservationHistoryPush(&history, third[:]) && ObservationHistoryPush(&history, fourth[:]))
	testing.expect(t, ObservationHistoryFlatten(&history, flattened[:]))
	testing.expect(t, flattened == [6]f32{2, 20, 3, 30, 4, 40})
	testing.expect(t, ObservationHistoryReset(&history) && history.count == 0 && history.nextIndex == 0)
	testing.expect(t, ObservationHistoryFlatten(&history, flattened[:]) && flattened == [6]f32{})
	testing.expect(t, ObservationHistoryPush(&history, fourth[:]))
	testing.expect(t, ObservationHistoryFlatten(&history, flattened[:]))
	testing.expect(t, flattened == [6]f32{0, 0, 0, 0, 4, 40})
}

@(test)
ObservationHistoryFailuresAreNonMutating :: proc(t: ^testing.T) {
	storage: [4]f32
	history: ObservationHistory
	testing.expect(t, ObservationHistoryInit(&history, storage[:], 2, 2))
	frame := [2]f32{7, 8}
	testing.expect(t, ObservationHistoryPush(&history, frame[:]))
	originalStorage, originalCount, originalNext := storage, history.count, history.nextIndex
	wrongWidth := [1]f32{1}
	testing.expect(t, !ObservationHistoryPush(&history, wrongWidth[:]))
	invalidFrame := [2]f32{1, transmute(f32)u32(0x7f800000)}
	testing.expect(t, !ObservationHistoryPush(&history, invalidFrame[:]))
	testing.expect(t, storage == originalStorage && history.count == originalCount && history.nextIndex == originalNext)

	tooSmallOutput := [3]f32{9, 9, 9}
	testing.expect(t, !ObservationHistoryFlatten(&history, tooSmallOutput[:]))
	testing.expect(t, tooSmallOutput == [3]f32{9, 9, 9})
	testing.expect(t, !ObservationHistoryPush(&history, storage[:2]))

	aliasedHistory: ObservationHistory
	aliasedStorage: [4]f32
	testing.expect(t, ObservationHistoryInit(&aliasedHistory, aliasedStorage[:], 2, 2))
	aliasedOutput := aliasedStorage[:]
	before := aliasedStorage
	testing.expect(t, !ObservationHistoryFlatten(&aliasedHistory, aliasedOutput))
	testing.expect(t, aliasedStorage == before)
}

@(test)
ObservationHistoryRejectsInvalidCapacity :: proc(t: ^testing.T) {
	storage: [4]f32
	history: ObservationHistory
	testing.expect(t, !ObservationHistoryInit(&history, storage[:], 0, 2))
	testing.expect(t, !ObservationHistoryInit(&history, storage[:], 3, 2))

}
