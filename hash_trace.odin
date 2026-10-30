package main

import "core:fmt"
import "core:os"
import "core:strconv"

HASH_TRACE_FLAG :: "-hash_trace"

CommandLineInt :: proc(prefix: string, fallback: int) -> int {
	for arg in os.args[1:] {
		if len(arg) <= len(prefix) || arg[:len(prefix)] != prefix do continue
		value, ok := strconv.parse_int(arg[len(prefix):])
		if ok do return value
	}
	return fallback
}

CommandLineU64 :: proc(prefix: string, fallback: u64) -> u64 {
	for arg in os.args[1:] {
		if len(arg) <= len(prefix) || arg[:len(prefix)] != prefix do continue
		value, ok := strconv.parse_u64(arg[len(prefix):])
		if ok do return value
	}
	return fallback
}

// Deterministic external input used by the trace mode. It also exercises the
// queue -> tick boundary -> log path so replay can be compared.
HashTraceQueueScript :: proc(w: ^World, tick: u64) {
	if !WorldTownExists(w, 0, 0) || !WorldTownExists(w, 1, 0) do return
	switch tick {
	case 1:
		WorldQueueCommand(w, 0, CommandDeclareWar{other = 1})
	case 3:
		WorldQueueCommand(w, 0, CommandAttackTown {
			town = 0,
			targetKingdom = 1,
			targetTown = 0,
		})
	}
}

HashTraceInit :: proc(size, kingdoms: int, seed: u64) -> (^World, bool) {
	w := new(World)
	settings := WorldGenerationSettingsDefault()
	settings.seed = seed
	if !WorldInit(w, uint(size), uint(size), uint(kingdoms), settings) {
		free(w)
		return nil, false
	}
	return w, true
}

// Headless determinism check. Prints one hash per tick for external comparison.
HashTraceRun :: proc() -> bool {
	if !CommandLineFlagPresent(HASH_TRACE_FLAG) do return false

	seed := CommandLineU64("-hash_seed:", 1)
	size := CommandLineInt("-hash_size:", 128)
	ticks := CommandLineInt("-hash_ticks:", 64)
	kingdoms := CommandLineInt("-hash_kingdoms:", 2)
	useCommands := CommandLineFlagPresent("-hash_commands")
	if size <= 0 || ticks < 0 || kingdoms < 1 || kingdoms > KINGDOMS_CAPACITY {
		fmt.eprintln("invalid hash trace arguments")
		return true
	}

	if CommandLineFlagPresent("-hash_parallel") {
		ParallelInit()
		defer ParallelDeinit()
	}
	defer AStarScratchDeinit()

	w, ok := HashTraceInit(size, kingdoms, seed)
	if !ok {
		fmt.eprintln("hash trace world initialization failed")
		return true
	}
	defer free(w)
	defer WorldDeinit(w)
	if useCommands && kingdoms >= 2 do KingdomMeet(w, 0, 1)
	SessionLog(w)

	live := make([]u64, ticks+1)
	defer delete(live)
	live[0] = WorldStateHash(w)
	fmt.printfln(
		"HASH_TRACE version=%d seed=%d size=%d kingdoms=%d initial=%016x",
		WORLD_STATE_VERSION,
		seed,
		size,
		kingdoms,
		live[0],
	)
	for tick in 0..<ticks {
		if useCommands do HashTraceQueueScript(w, u64(tick+1))
		WorldTick(w)
		live[tick+1] = WorldStateHash(w)
		fmt.printfln("HASH_TRACE tick=%d hash=%016x", tick+1, live[tick+1])
	}

	if !useCommands do return true

	wireOk := true
	for entry in w.commandLog {
		buffer: [COMMAND_WIRE_MAX_BYTES]u8
		used, encoded := LoggedCommandEncode(buffer[:], entry)
		if !encoded {
			wireOk = false
			break
		}
		decoded, _, decodedOk := LoggedCommandDecode(buffer[:used])
		if !decodedOk || decoded.tick != entry.tick || decoded.sequence != entry.sequence ||
			decoded.kingdom != entry.kingdom || decoded.accepted != entry.accepted ||
			decoded.source != entry.source ||
			CommandHash(decoded.command) != CommandHash(entry.command) {
			wireOk = false
			break
		}
	}
	fmt.printfln("WIRE ok=%v entries=%d", wireOk, len(w.commandLog))

	replay, replayOk := HashTraceInit(size, kingdoms, seed)
	if !replayOk {
		fmt.eprintln("REPLAY failed: world initialization")
		return true
	}
	defer free(replay)
	defer WorldDeinit(replay)
	if kingdoms >= 2 do KingdomMeet(replay, 0, 1)

	log := w.commandLog[:]
	matched := WorldStateHash(replay) == live[0]
	for tick in 0..<ticks {
		WorldReplayCommands(replay, log, u64(tick+1))
		WorldTick(replay)
		if replay.gameOver != w.gameOver do matched = false
		if WorldStateHash(replay) != live[tick+1] {
			fmt.printfln("REPLAY mismatch tick=%d", tick+1)
			matched = false
			break
		}
	}
	if matched {
		fmt.printfln("REPLAY ok ticks=%d commands=%d", ticks, len(log))
	} else {
		fmt.printfln("REPLAY failed ticks=%d commands=%d", ticks, len(log))
	}

	SessionTraceNetwork(size, kingdoms, seed, live, log, ticks)
	return true
}

// Loopback check for the packet format: config handshake, command batch, then
// compare the peer's per-tick hashes with the live run.
SessionTraceNetwork :: proc(
	size, kingdoms: int,
	seed: u64,
	live: []u64,
	log: []LoggedCommand,
	ticks: int,
) {
	peer, ok := HashTraceInit(size, kingdoms, seed)
	if !ok {
		fmt.printfln("NETWORK failed: peer initialization")
		return
	}
	defer free(peer)
	defer WorldDeinit(peer)
	if kingdoms >= 2 do KingdomMeet(peer, 0, 1)

	networkOk := true
	configBuffer: [128]u8
	configUsed, configOk := SessionEncodeConfigPacket(
		configBuffer[:],
		WorldSessionConfig(peer),
	)
	if !configOk || !WorldReceiveSessionPacket(peer, configBuffer[:configUsed]) {
		networkOk = false
	}

	humanCount := 0
	for entry in log {
		if entry.source == .Human && entry.accepted do humanCount += 1
	}
	humans := make([]LoggedCommand, humanCount)
	defer delete(humans)
	write := 0
	for entry in log {
		if entry.source != .Human || !entry.accepted do continue
		humans[write] = entry
		write += 1
	}

	sizeNeeded := SessionCommandsPacketSize(humans)
	packet := make([]u8, sizeNeeded)
	defer delete(packet)
	packetUsed, packetOk := SessionEncodeCommandsPacket(packet, humans)
	if !packetOk || !WorldReceiveSessionPacket(peer, packet[:packetUsed]) {
		networkOk = false
	}

	for tick in 0..<ticks {
		WorldTick(peer)
		if WorldStateHash(peer) != live[tick+1] {
			networkOk = false
			break
		}
	}
	fmt.printfln("NETWORK ok=%v commands=%d", networkOk, humanCount)
}
