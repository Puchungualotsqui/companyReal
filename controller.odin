package main

import "core:fmt"
import "d32"

// A kingdom is driven by a controller, never by the simulation directly.
// Today there are two kinds: the local human (input arrives through the UI)
// and an AI brain. Trained-RL or network controllers can be added as another
// kind and fed through KingdomIssueCommand without touching the simulation.
ControllerKind :: enum {
	Human,
	AI,
}

KingdomController :: struct {
	kind: ControllerKind,
	ai:   AIBrain,
}

// All state-changing actions pass through this command layer. The UI emits
// commands for the local player and the AI emits them for its own kingdom;
// a future network/RL controller can emit the exact same structs.
KingdomCommand :: union {
	CommandQueueConversion,
	CommandRemoveConversion,
	CommandChooseMilestone,
	CommandFoundTown,
	CommandFuseTown,
	CommandBuildCombat,
	CommandAttackTown,
	CommandDefendTown,
	CommandStopAttack,
	CommandStopDefend,
	CommandDeclareWar,
	CommandMakePeace,
	CommandUseOrder,
}

CommandQueueConversion :: struct {
	town:  int,
	from:  UnitKind,
	to:    UnitKind,
	count: int,
}

CommandRemoveConversion :: struct {
	town:  int,
	from:  UnitKind,
	to:    UnitKind,
	count: int,
}

CommandChooseMilestone :: struct {
	town:   int,
	option: int,
}

CommandFoundTown :: struct {
	town: int,
	x, y: int,
}

CommandFuseTown :: struct {
	town:           int,
	targetKingdom: int,
	targetTown:    int,
}

CommandBuildCombat :: struct {
	town: int,
	kind: BuildingKind,
	x, y: int,
}

CommandAttackTown :: struct {
	town:            int,
	targetKingdom:  int,
	targetTown:     int,
}

CommandDefendTown :: struct {
	town:            int,
	targetKingdom:  int,
	targetTown:     int,
}

CommandStopAttack :: struct {
	town:            int,
	targetKingdom:  int,
	targetTown:     int,
}

CommandStopDefend :: struct {
	town:            int,
	targetKingdom:  int,
	targetTown:     int,
}

CommandDeclareWar :: struct {
	other: int,
}

CommandMakePeace :: struct {
	other: int,
}

CommandUseOrder :: struct {
	kind: OrderKind,
	x, y: d32.Value,
}

// UI commands wait for the next tick. AI commands are issued inside its periodic
// update and take effect immediately, but both are logged with their tick.
CommandSource :: enum {
	Human, // External input; replay it on every peer
	AI, // Recomputed deterministically by every peer
}

QueuedCommand :: struct {
	kingdom:   int,
	command:   KingdomCommand,
	targetTick: u64,
}

LoggedCommand :: struct {
	tick: u64,
	sequence: u32,
	kingdom: int,
	command: KingdomCommand,
	accepted: bool,
	source: CommandSource,
}

WorldQueueCommandAt :: proc(
	w: ^World,
	kingdom: int,
	command: KingdomCommand,
	targetTick: u64,
) -> bool {
	if kingdom < 0 || kingdom >= KINGDOMS_CAPACITY || !w.kingdomUsed[kingdom] do return false
	append(&w.pendingCommands, QueuedCommand {
		kingdom = kingdom,
		command = command,
		targetTick = targetTick,
	})
	return true
}

// External input is scheduled a few ticks ahead so every peer can receive it.
WorldQueueCommand :: proc(w: ^World, kingdom: int, command: KingdomCommand) -> bool {
	return WorldQueueCommandAt(
		w,
		kingdom,
		command,
		WorldCurrentTick(w)+SESSION_INPUT_DELAY_TICKS,
	)
}

// Commands whose target tick has arrived are applied in arrival order. Later
// entries stay queued, so late input shifts instead of reordering.
WorldApplyPendingCommands :: proc(w: ^World) {
	current := WorldCurrentTick(w)
	write := 0
	for index in 0..<len(w.pendingCommands) {
		queued := w.pendingCommands[index]
		if queued.targetTick > current {
			w.pendingCommands[write] = queued
			write += 1
			continue
		}
		KingdomIssueCommand(w, queued.kingdom, queued.command, .Human)
	}
	resize(&w.pendingCommands, write)
}

// AI entries only matter for recent hash exchange; human entries are kept for
// recovery. Trimming runs at a fixed tick cadence so every peer stays in sync.
SESSION_AI_LOG_TICKS :: u64(512)
SESSION_TRIM_INTERVAL :: u64(64)

WorldTrimCommandLog :: proc(w: ^World) {
	current := WorldCurrentTick(w)
	if current%SESSION_TRIM_INTERVAL != 0 do return
	write := 0
	for entry in w.commandLog {
		if entry.source == .AI && current > entry.tick &&
			current-entry.tick > SESSION_AI_LOG_TICKS {
			continue
		}
		w.commandLog[write] = entry
		write += 1
	}
	resize(&w.commandLog, write)
}

WorldCommandLogHash :: proc(w: ^World) -> u64 {
	hash: u64 = 0xcbf29ce484222325
	WorldHashValue(&hash, u64(len(w.commandLog)))
	for entry in w.commandLog {
		WorldHashValue(&hash, entry.tick)
		WorldHashValue(&hash, entry.sequence)
		WorldHashValue(&hash, entry.kingdom)
		WorldHashValue(&hash, CommandHash(entry.command))
		WorldHashValue(&hash, entry.accepted)
		WorldHashValue(&hash, entry.source)
	}
	return hash
}

// Matches a peer's periodic session hash. A mismatch is a desync marker; the
// recovery path is to rebuild from the config and the retained human log.
WorldCheckPeerHash :: proc(w: ^World, tick: u64, peerHash: u64) -> bool {
	w.peerHashTick = tick
	w.peerHash = peerHash
	w.peerHashSeen = true
	if tick != WorldCurrentTick(w) do return true
	if peerHash == SessionHash(w) do return true
	w.desyncDetected = true
	if profiler.file != nil {
		buffer: [192]u8
		line := fmt.bprintf(
			buffer[:],
			"DESYNC tick=%d local=%016x peer=%016x\n",
			tick,
			SessionHash(w),
			peerHash,
		)
		ProfilerWrite(line)
	}
	return false
}

// Re-applies accepted log entries for one tick while replaying a fresh world.
WorldReplayCommands :: proc(w: ^World, log: []LoggedCommand, tick: u64) {
	for entry in log {
		if entry.tick != tick || !entry.accepted || entry.source != .Human do continue
		WorldQueueCommandAt(w, entry.kingdom, entry.command, tick)
	}
}

CommandKindTag :: proc(command: KingdomCommand) -> u8 {
	switch _ in command {
	case CommandQueueConversion: return 0
	case CommandRemoveConversion: return 1
	case CommandChooseMilestone: return 2
	case CommandFoundTown: return 3
	case CommandFuseTown: return 4
	case CommandBuildCombat: return 5
	case CommandAttackTown: return 6
	case CommandDefendTown: return 7
	case CommandStopAttack: return 8
	case CommandStopDefend: return 9
	case CommandDeclareWar: return 10
	case CommandMakePeace: return 11
	case CommandUseOrder: return 12
	}
	return 0
}

CommandHash :: proc(command: KingdomCommand) -> u64 {
	hash: u64 = 0xcbf29ce484222325
	WorldHashValue(&hash, CommandKindTag(command))
	switch cmd in command {
	case CommandQueueConversion:
		WorldHashValue(&hash, cmd.town)
		WorldHashValue(&hash, cmd.from)
		WorldHashValue(&hash, cmd.to)
		WorldHashValue(&hash, cmd.count)
	case CommandRemoveConversion:
		WorldHashValue(&hash, cmd.town)
		WorldHashValue(&hash, cmd.from)
		WorldHashValue(&hash, cmd.to)
		WorldHashValue(&hash, cmd.count)
	case CommandChooseMilestone:
		WorldHashValue(&hash, cmd.town)
		WorldHashValue(&hash, cmd.option)
	case CommandFoundTown:
		WorldHashValue(&hash, cmd.town)
		WorldHashValue(&hash, cmd.x)
		WorldHashValue(&hash, cmd.y)
	case CommandFuseTown:
		WorldHashValue(&hash, cmd.town)
		WorldHashValue(&hash, cmd.targetKingdom)
		WorldHashValue(&hash, cmd.targetTown)
	case CommandBuildCombat:
		WorldHashValue(&hash, cmd.town)
		WorldHashValue(&hash, cmd.kind)
		WorldHashValue(&hash, cmd.x)
		WorldHashValue(&hash, cmd.y)
	case CommandAttackTown:
		WorldHashValue(&hash, cmd.town)
		WorldHashValue(&hash, cmd.targetKingdom)
		WorldHashValue(&hash, cmd.targetTown)
	case CommandDefendTown:
		WorldHashValue(&hash, cmd.town)
		WorldHashValue(&hash, cmd.targetKingdom)
		WorldHashValue(&hash, cmd.targetTown)
	case CommandStopAttack:
		WorldHashValue(&hash, cmd.town)
		WorldHashValue(&hash, cmd.targetKingdom)
		WorldHashValue(&hash, cmd.targetTown)
	case CommandStopDefend:
		WorldHashValue(&hash, cmd.town)
		WorldHashValue(&hash, cmd.targetKingdom)
		WorldHashValue(&hash, cmd.targetTown)
	case CommandDeclareWar:
		WorldHashValue(&hash, cmd.other)
	case CommandMakePeace:
		WorldHashValue(&hash, cmd.other)
	case CommandUseOrder:
		WorldHashValue(&hash, cmd.kind)
		WorldHashValue(&hash, cmd.x)
		WorldHashValue(&hash, cmd.y)
	}
	return hash
}

CommandLogAppend :: proc(
	w: ^World,
	kingdom: int,
	command: KingdomCommand,
	accepted: bool,
	source: CommandSource,
) {
	append(&w.commandLog, LoggedCommand {
		tick = WorldCurrentTick(w),
		sequence = w.commandSequence,
		kingdom = kingdom,
		command = command,
		accepted = accepted,
		source = source,
	})
	w.commandSequence += 1
	if profiler.file == nil do return
	buffer: [160]u8
	line := fmt.bprintf(
		buffer[:],
		"COMMAND tick=%d seq=%d kingdom=%d kind=%d hash=%016x ok=%v source=%d\n",
		WorldCurrentTick(w),
		w.commandSequence-1,
		kingdom,
		CommandKindTag(command),
		CommandHash(command),
		accepted,
		source,
	)
	ProfilerWrite(line)
}

KingdomIssueCommand :: proc(
	w: ^World,
	kingdom: int,
	command: KingdomCommand,
	source := CommandSource.AI,
) -> bool {
	if kingdom < 0 || kingdom >= KINGDOMS_CAPACITY || !w.kingdomUsed[kingdom] {
		return false
	}

	result := false
	switch cmd in command {
	case CommandQueueConversion:
		result = TownAddConversion(w, kingdom, cmd.town, cmd.from, cmd.to, cmd.count)
	case CommandRemoveConversion:
		result = TownRemoveConversion(w, kingdom, cmd.town, cmd.from, cmd.to, cmd.count)
	case CommandChooseMilestone:
		result = TownChooseMilestone(w, kingdom, cmd.town, cmd.option)
	case CommandFoundTown:
		result = TownStartFounding(w, kingdom, cmd.town, cmd.x, cmd.y)
	case CommandFuseTown:
		result = TownFuse(w, kingdom, cmd.town, cmd.targetKingdom, cmd.targetTown)
	case CommandBuildCombat:
		result = TownStartCombatConstruction(w, kingdom, cmd.town, cmd.kind, cmd.x, cmd.y)
	case CommandAttackTown:
		result = TownStartAttack(w, kingdom, cmd.town, cmd.targetKingdom, cmd.targetTown)
	case CommandDefendTown:
		if WorldTownExists(w, kingdom, cmd.town) {
			TownStartDefending(w, kingdom, cmd.town, cmd.targetKingdom, cmd.targetTown)
			result = true
		}
	case CommandStopAttack:
		if WorldTownExists(w, kingdom, cmd.town) {
			TownStopAttack(w, kingdom, cmd.town, cmd.targetKingdom, cmd.targetTown)
			result = true
		}
	case CommandStopDefend:
		if WorldTownExists(w, kingdom, cmd.town) {
			TownStopDefending(w, kingdom, cmd.town, cmd.targetKingdom, cmd.targetTown)
			result = true
		}
	case CommandDeclareWar:
		result = KingdomDeclareWar(w, kingdom, cmd.other)
	case CommandMakePeace:
		if KingdomAtWar(w, kingdom, cmd.other) {
			KingdomMakePeace(w, kingdom, cmd.other)
			result = true
		}
	case CommandUseOrder:
		result = OrderStart(w, kingdom, cmd.kind, cmd.x, cmd.y)
	}
	CommandLogAppend(w, kingdom, command, result, source)
	return result
}

// Configures who drives each kingdom. `localKingdom` is the slot controlled
// by the person at this screen; pass -1 for a pure spectator game.
WorldConfigureGame :: proc(w: ^World, localKingdom: int, spectator: bool) {
	w.gameOver = false
	w.winnerKingdom = -1
	w.playerKingdom = -1
	w.observerKingdom = -1

	for kingdom in 0 ..< KINGDOMS_CAPACITY {
		w.controllers[kingdom] = KingdomController{kind = .AI}
		if w.kingdomUsed[kingdom] do AIStateInit(w, kingdom)
	}

	if !spectator && localKingdom >= 0 && localKingdom < KINGDOMS_CAPACITY &&
		w.kingdomUsed[localKingdom] {
		w.controllers[localKingdom].kind = .Human
		w.playerKingdom = localKingdom
		w.observerKingdom = localKingdom
	}
}

WorldKingdomHuman :: proc(w: ^World, kingdom: int) -> bool {
	return kingdom >= 0 && kingdom < KINGDOMS_CAPACITY && w.kingdomUsed[kingdom] &&
		w.controllers[kingdom].kind == .Human
}

// The local kingdom the UI is allowed to command. Spectators and eliminated
// players get -1.
WorldLocalKingdom :: proc(w: ^World) -> int {
	if w.playerKingdom >= 0 && WorldKingdomHuman(w, w.playerKingdom) do return w.playerKingdom
	return -1
}

WorldIsSpectating :: proc(w: ^World) -> bool {
	return w.observerKingdom < 0
}

// Hands every human-controlled kingdom to the AI and reveals the whole map.
// Used by the "continue watching" flow on victory/defeat.
WorldEnterSpectator :: proc(w: ^World) {
	for kingdom in 0 ..< KINGDOMS_CAPACITY {
		if w.controllers[kingdom].kind != .Human do continue
		w.controllers[kingdom].kind = .AI
		if w.kingdomUsed[kingdom] do AIStateInit(w, kingdom)
	}
	w.playerKingdom = -1
	w.observerKingdom = -1
	WorldAlertClear(w)
	FogUpdate(w)
}

WorldControllersUpdate :: proc(w: ^World, deltaTime: f32) {
	for kingdom in 0 ..< KINGDOMS_CAPACITY {
		if !w.kingdomUsed[kingdom] do continue
		switch w.controllers[kingdom].kind {
		case .Human:
			// Local input is translated into KingdomCommands by the UI.
		case .AI:
			AIControllerUpdate(w, kingdom, deltaTime)
		}
	}
}

WorldCheckGameEnd :: proc(w: ^World) {
	if w.gameOver do return

	alive := 0
	winner := -1
	for kingdom in 0 ..< KINGDOMS_CAPACITY {
		if !w.kingdomUsed[kingdom] do continue
		alive += 1
		winner = kingdom
	}

	// A defeated player stops playing immediately, even while AI kingdoms
	// keep fighting. They may continue as a spectator.
	if w.playerKingdom >= 0 && !w.kingdomUsed[w.playerKingdom] {
		w.gameOver = true
		w.winnerKingdom = winner
		return
	}

	if alive <= 1 {
		w.gameOver = true
		w.winnerKingdom = winner
	}
}
