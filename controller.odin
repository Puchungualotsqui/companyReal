package main

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
	CommandBuildCombat,
	CommandAttackTown,
	CommandDefendTown,
	CommandStopAttack,
	CommandStopDefend,
	CommandDeclareWar,
	CommandMakePeace,
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

CommandBuildCombat :: struct {
	town: int,
	kind: BuildingKind,
	x, y: int,
}

CommandAttackTown :: struct {
	town:            int,
	target_kingdom:  int,
	target_town:     int,
}

CommandDefendTown :: struct {
	town:            int,
	target_kingdom:  int,
	target_town:     int,
}

CommandStopAttack :: struct {
	town:            int,
	target_kingdom:  int,
	target_town:     int,
}

CommandStopDefend :: struct {
	town:            int,
	target_kingdom:  int,
	target_town:     int,
}

CommandDeclareWar :: struct {
	other: int,
}

CommandMakePeace :: struct {
	other: int,
}

KingdomIssueCommand :: proc(w: ^World, kingdom: int, command: KingdomCommand) -> bool {
	if kingdom < 0 || kingdom >= KINGDOMS_CAPACITY || !w.kingdomUsed[kingdom] do return false

	switch cmd in command {
	case CommandQueueConversion:
		return TownAddConversion(w, kingdom, cmd.town, cmd.from, cmd.to, cmd.count)
	case CommandRemoveConversion:
		return TownRemoveConversion(w, kingdom, cmd.town, cmd.from, cmd.to, cmd.count)
	case CommandChooseMilestone:
		return TownChooseMilestone(w, kingdom, cmd.town, cmd.option)
	case CommandFoundTown:
		return TownStartFounding(w, kingdom, cmd.town, cmd.x, cmd.y)
	case CommandBuildCombat:
		return TownStartCombatConstruction(w, kingdom, cmd.town, cmd.kind, cmd.x, cmd.y)
	case CommandAttackTown:
		if !WorldTownExists(w, kingdom, cmd.town) do return false
		TownStartAttack(w, kingdom, cmd.town, cmd.target_kingdom, cmd.target_town)
		return true
	case CommandDefendTown:
		if !WorldTownExists(w, kingdom, cmd.town) do return false
		TownStartDefending(w, kingdom, cmd.town, cmd.target_kingdom, cmd.target_town)
		return true
	case CommandStopAttack:
		if !WorldTownExists(w, kingdom, cmd.town) do return false
		TownStopAttack(w, kingdom, cmd.town, cmd.target_kingdom, cmd.target_town)
		return true
	case CommandStopDefend:
		if !WorldTownExists(w, kingdom, cmd.town) do return false
		TownStopDefending(w, kingdom, cmd.town, cmd.target_kingdom, cmd.target_town)
		return true
	case CommandDeclareWar:
		if KingdomAtWar(w, kingdom, cmd.other) do return false
		KingdomDeclareWar(w, kingdom, cmd.other)
		return true
	case CommandMakePeace:
		if !KingdomAtWar(w, kingdom, cmd.other) do return false
		KingdomMakePeace(w, kingdom, cmd.other)
		return true
	}
	return false
}

// Configures who drives each kingdom. `local_kingdom` is the slot controlled
// by the person at this screen; pass -1 for a pure spectator game.
WorldConfigureGame :: proc(w: ^World, local_kingdom: int, spectator: bool) {
	w.gameOver = false
	w.winnerKingdom = -1
	w.playerKingdom = -1
	w.observerKingdom = -1

	for kingdom in 0 ..< KINGDOMS_CAPACITY {
		w.controllers[kingdom] = KingdomController{kind = .AI}
		if w.kingdomUsed[kingdom] do AIStateInit(w, kingdom)
	}

	if !spectator && local_kingdom >= 0 && local_kingdom < KINGDOMS_CAPACITY &&
		w.kingdomUsed[local_kingdom] {
		w.controllers[local_kingdom].kind = .Human
		w.playerKingdom = local_kingdom
		w.observerKingdom = local_kingdom
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

WorldControllersUpdate :: proc(w: ^World, delta_time: f32) {
	for kingdom in 0 ..< KINGDOMS_CAPACITY {
		if !w.kingdomUsed[kingdom] do continue
		switch w.controllers[kingdom].kind {
		case .Human:
			// Local input is translated into KingdomCommands by the UI.
		case .AI:
			AIControllerUpdate(w, kingdom, delta_time)
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
