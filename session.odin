package main

import "core:fmt"
import "d32"

// Session protocol and command wire format. The protocol version is exchanged
// with the seed so peers reject incompatible builds before simulating.
SESSION_PROTOCOL_VERSION :: u32(1)
// Commands from peers arrive a couple of ticks ahead of the tick they affect.
SESSION_INPUT_DELAY_TICKS :: u64(2)

SessionConfig :: struct {
	protocolVersion: u32,
	seed:            u64,
	width, height:   u32,
	kingdomCount:    u8,
	localKingdom:    i8, // -1 for spectators
	spectator:       bool,
}

WorldSessionConfig :: proc(w: ^World) -> SessionConfig {
	count: u8 = 0
	for kingdom in 0..<KINGDOMS_CAPACITY {
		if w.kingdomUsed[kingdom] do count += 1
	}
	local: i8 = -1
	if w.playerKingdom >= 0 do local = i8(w.playerKingdom)
	return SessionConfig {
		protocolVersion = SESSION_PROTOCOL_VERSION,
		seed = w.seed,
		width = u32(w.maxX),
		height = u32(w.maxY),
		kingdomCount = count,
		localKingdom = local,
		spectator = WorldIsSpectating(w),
	}
}

// Peers must agree on the protocol and initial world before exchanging commands.
SessionConfigCompatible :: proc(a, b: SessionConfig) -> bool {
	return a.protocolVersion == b.protocolVersion &&
		a.seed == b.seed &&
		a.width == b.width &&
		a.height == b.height &&
		a.kingdomCount == b.kingdomCount
}

SessionConfigHash :: proc(config: SessionConfig) -> u64 {
	hash: u64 = 0xcbf29ce484222325
	WorldHashValue(&hash, config.protocolVersion)
	WorldHashValue(&hash, config.seed)
	WorldHashValue(&hash, config.width)
	WorldHashValue(&hash, config.height)
	WorldHashValue(&hash, config.kingdomCount)
	WorldHashValue(&hash, config.localKingdom)
	WorldHashValue(&hash, config.spectator)
	return hash
}

// Config, authoritative state and applied commands in one value for exchange.
SessionHashWithState :: proc(w: ^World, stateHash: u64) -> u64 {
	hash: u64 = 0xcbf29ce484222325
	WorldHashValue(&hash, SessionConfigHash(WorldSessionConfig(w)))
	WorldHashValue(&hash, stateHash)
	WorldHashValue(&hash, WorldCommandLogHash(w))
	return hash
}

SessionHash :: proc(w: ^World) -> u64 {
	return SessionHashWithState(w, WorldStateHash(w))
}

SessionLog :: proc(w: ^World) {
	config := WorldSessionConfig(w)
	fmt.printfln(
		"SESSION version=%d seed=%d width=%d height=%d kingdoms=%d local=%d spectator=%v configHash=%016x",
		config.protocolVersion,
		config.seed,
		config.width,
		config.height,
		config.kingdomCount,
		config.localKingdom,
		config.spectator,
		SessionConfigHash(config),
	)
}

// --- command wire format -----------------------------------------------------

COMMAND_WIRE_MAX_BYTES :: 64

WireWrite :: struct {
	buf: []u8,
	pos: int,
	ok:  bool,
}

WireRead :: struct {
	buf: []u8,
	pos: int,
	ok:  bool,
}

WirePutU8 :: proc(w: ^WireWrite, value: u8) {
	if !w.ok || w.pos+1 > len(w.buf) {
		w.ok = false
		return
	}
	w.buf[w.pos] = value
	w.pos += 1
}

WirePutU32 :: proc(w: ^WireWrite, value: u32) {
	for index in 0..<4 do WirePutU8(w, u8(value>>(8*u32(index))))
}

WirePutU64 :: proc(w: ^WireWrite, value: u64) {
	for index in 0..<8 do WirePutU8(w, u8(value>>(8*u32(index))))
}

WirePutI32 :: proc(w: ^WireWrite, value: i32) {
	WirePutU32(w, transmute(u32)value)
}

WirePutBool :: proc(w: ^WireWrite, value: bool) {
	WirePutU8(w, value ? 1 : 0)
}

WireGetU8 :: proc(r: ^WireRead) -> u8 {
	if !r.ok || r.pos+1 > len(r.buf) {
		r.ok = false
		return 0
	}
	value := r.buf[r.pos]
	r.pos += 1
	return value
}

WireGetU32 :: proc(r: ^WireRead) -> u32 {
	value: u32 = 0
	for index in 0..<4 do value |= u32(WireGetU8(r))<<(8*u32(index))
	return value
}

WireGetU64 :: proc(r: ^WireRead) -> u64 {
	value: u64 = 0
	for index in 0..<8 do value |= u64(WireGetU8(r))<<(8*u32(index))
	return value
}

WireGetI32 :: proc(r: ^WireRead) -> i32 {
	return transmute(i32)WireGetU32(r)
}

WireGetBool :: proc(r: ^WireRead) -> bool {
	return WireGetU8(r) != 0
}

CommandEncodedSize :: proc(command: KingdomCommand) -> int {
	switch _ in command {
	case CommandQueueConversion, CommandRemoveConversion:
		return 1+4*4
	case CommandChooseMilestone, CommandFoundTown, CommandFuseTown, CommandDeclareWar, CommandMakePeace, CommandUseOrder:
		return 1+4*3
	case CommandBuildCombat:
		return 1+4*4
	case CommandAttackTown, CommandDefendTown, CommandStopAttack, CommandStopDefend:
		return 1+4*3
	}
	return 0
}

CommandEncode :: proc(buf: []u8, command: KingdomCommand) -> (used: int, ok: bool) {
	writer := WireWrite{buf = buf, ok = true}
	WirePutU8(&writer, CommandKindTag(command))
	switch cmd in command {
	case CommandQueueConversion:
		WirePutI32(&writer, i32(cmd.town))
		WirePutI32(&writer, i32(cmd.from))
		WirePutI32(&writer, i32(cmd.to))
		WirePutI32(&writer, i32(cmd.count))
	case CommandRemoveConversion:
		WirePutI32(&writer, i32(cmd.town))
		WirePutI32(&writer, i32(cmd.from))
		WirePutI32(&writer, i32(cmd.to))
		WirePutI32(&writer, i32(cmd.count))
	case CommandChooseMilestone:
		WirePutI32(&writer, i32(cmd.town))
		WirePutI32(&writer, i32(cmd.option))
		WirePutI32(&writer, 0)
	case CommandFoundTown:
		WirePutI32(&writer, i32(cmd.town))
		WirePutI32(&writer, i32(cmd.x))
		WirePutI32(&writer, i32(cmd.y))
	case CommandFuseTown:
		WirePutI32(&writer, i32(cmd.town))
		WirePutI32(&writer, i32(cmd.targetKingdom))
		WirePutI32(&writer, i32(cmd.targetTown))
	case CommandBuildCombat:
		WirePutI32(&writer, i32(cmd.town))
		WirePutI32(&writer, i32(cmd.kind))
		WirePutI32(&writer, i32(cmd.x))
		WirePutI32(&writer, i32(cmd.y))
	case CommandAttackTown:
		WirePutI32(&writer, i32(cmd.town))
		WirePutI32(&writer, i32(cmd.targetKingdom))
		WirePutI32(&writer, i32(cmd.targetTown))
	case CommandDefendTown:
		WirePutI32(&writer, i32(cmd.town))
		WirePutI32(&writer, i32(cmd.targetKingdom))
		WirePutI32(&writer, i32(cmd.targetTown))
	case CommandStopAttack:
		WirePutI32(&writer, i32(cmd.town))
		WirePutI32(&writer, i32(cmd.targetKingdom))
		WirePutI32(&writer, i32(cmd.targetTown))
	case CommandStopDefend:
		WirePutI32(&writer, i32(cmd.town))
		WirePutI32(&writer, i32(cmd.targetKingdom))
		WirePutI32(&writer, i32(cmd.targetTown))
	case CommandDeclareWar:
		WirePutI32(&writer, i32(cmd.other))
		WirePutI32(&writer, 0)
		WirePutI32(&writer, 0)
	case CommandMakePeace:
		WirePutI32(&writer, i32(cmd.other))
		WirePutI32(&writer, 0)
		WirePutI32(&writer, 0)
	case CommandUseOrder:
		WirePutI32(&writer, i32(cmd.kind))
		WirePutI32(&writer, d32.Raw(cmd.x))
		WirePutI32(&writer, d32.Raw(cmd.y))
	}
	return writer.pos, writer.ok
}

CommandDecode :: proc(buf: []u8) -> (command: KingdomCommand, used: int, ok: bool) {
	reader := WireRead{buf = buf, ok = true}
	tag := WireGetU8(&reader)
	switch tag {
	case 0, 1:
		town := WireGetI32(&reader)
		from := WireGetI32(&reader)
		to := WireGetI32(&reader)
		count := WireGetI32(&reader)
		if !reader.ok || from < 0 || from > i32(max(UnitKind)) ||
			to < 0 || to > i32(max(UnitKind)) {
			return nil, 0, false
		}
		if tag == 0 {
			command = CommandQueueConversion {
				town = int(town),
				from = UnitKind(from),
				to = UnitKind(to),
				count = int(count),
			}
		} else {
			command = CommandRemoveConversion {
				town = int(town),
				from = UnitKind(from),
				to = UnitKind(to),
				count = int(count),
			}
		}
	case 2:
		town := WireGetI32(&reader)
		option := WireGetI32(&reader)
		_ = WireGetI32(&reader)
		if !reader.ok do return nil, 0, false
		command = CommandChooseMilestone{town = int(town), option = int(option)}
	case 3:
		town := WireGetI32(&reader)
		x := WireGetI32(&reader)
		y := WireGetI32(&reader)
		if !reader.ok do return nil, 0, false
		command = CommandFoundTown{town = int(town), x = int(x), y = int(y)}
	case 4:
		town := WireGetI32(&reader)
		targetKingdom := WireGetI32(&reader)
		targetTown := WireGetI32(&reader)
		if !reader.ok do return nil, 0, false
		command = CommandFuseTown {
			town = int(town),
			targetKingdom = int(targetKingdom),
			targetTown = int(targetTown),
		}
	case 5:
		town := WireGetI32(&reader)
		kind := WireGetI32(&reader)
		x := WireGetI32(&reader)
		y := WireGetI32(&reader)
		if !reader.ok || kind < 0 || kind > i32(max(BuildingKind)) do return nil, 0, false
		command = CommandBuildCombat {
			town = int(town),
			kind = BuildingKind(kind),
			x = int(x),
			y = int(y),
		}
	case 6:
		town := WireGetI32(&reader)
		targetKingdom := WireGetI32(&reader)
		targetTown := WireGetI32(&reader)
		if !reader.ok do return nil, 0, false
		command = CommandAttackTown {
			town = int(town),
			targetKingdom = int(targetKingdom),
			targetTown = int(targetTown),
		}
	case 7:
		town := WireGetI32(&reader)
		targetKingdom := WireGetI32(&reader)
		targetTown := WireGetI32(&reader)
		if !reader.ok do return nil, 0, false
		command = CommandDefendTown {
			town = int(town),
			targetKingdom = int(targetKingdom),
			targetTown = int(targetTown),
		}
	case 8:
		town := WireGetI32(&reader)
		targetKingdom := WireGetI32(&reader)
		targetTown := WireGetI32(&reader)
		if !reader.ok do return nil, 0, false
		command = CommandStopAttack {
			town = int(town),
			targetKingdom = int(targetKingdom),
			targetTown = int(targetTown),
		}
	case 9:
		town := WireGetI32(&reader)
		targetKingdom := WireGetI32(&reader)
		targetTown := WireGetI32(&reader)
		if !reader.ok do return nil, 0, false
		command = CommandStopDefend {
			town = int(town),
			targetKingdom = int(targetKingdom),
			targetTown = int(targetTown),
		}
	case 10:
		other := WireGetI32(&reader)
		_ = WireGetI32(&reader)
		_ = WireGetI32(&reader)
		if !reader.ok do return nil, 0, false
		command = CommandDeclareWar{other = int(other)}
	case 11:
		other := WireGetI32(&reader)
		_ = WireGetI32(&reader)
		_ = WireGetI32(&reader)
		if !reader.ok do return nil, 0, false
		command = CommandMakePeace{other = int(other)}
	case 12:
		kind := WireGetI32(&reader)
		x := WireGetI32(&reader)
		y := WireGetI32(&reader)
		if !reader.ok || kind < 0 || kind > i32(max(OrderKind)) do return nil, 0, false
		command = CommandUseOrder {
			kind = OrderKind(kind),
			x = d32.FromRaw(x),
			y = d32.FromRaw(y),
		}
	case:
		return nil, 0, false
	}
	return command, reader.pos, reader.ok
}

LOGGED_COMMAND_HEADER_BYTES :: 18 // tick, sequence, kingdom, accepted, source

LoggedCommandEncode :: proc(buf: []u8, entry: LoggedCommand) -> (used: int, ok: bool) {
	writer := WireWrite{buf = buf, ok = true}
	WirePutU64(&writer, entry.tick)
	WirePutU32(&writer, entry.sequence)
	WirePutI32(&writer, i32(entry.kingdom))
	WirePutBool(&writer, entry.accepted)
	WirePutU8(&writer, u8(entry.source))
	header := writer.pos
	commandUsed, commandOk := CommandEncode(buf[header:], entry.command)
	if !writer.ok || !commandOk do return 0, false
	return header+commandUsed, true
}

LoggedCommandDecode :: proc(buf: []u8) -> (entry: LoggedCommand, used: int, ok: bool) {
	reader := WireRead{buf = buf, ok = true}
	entry.tick = WireGetU64(&reader)
	entry.sequence = WireGetU32(&reader)
	entry.kingdom = int(WireGetI32(&reader))
	entry.accepted = WireGetBool(&reader)
	source := WireGetU8(&reader)
	if !reader.ok || source > u8(max(CommandSource)) do return {}, 0, false
	entry.source = CommandSource(source)
	command, commandUsed, commandOk := CommandDecode(buf[reader.pos:])
	if !commandOk do return {}, 0, false
	entry.command = command
	return entry, reader.pos+commandUsed, true
}

SessionConfigEncode :: proc(buf: []u8, config: SessionConfig) -> (used: int, ok: bool) {
	writer := WireWrite{buf = buf, ok = true}
	WirePutU32(&writer, config.protocolVersion)
	WirePutU64(&writer, config.seed)
	WirePutU32(&writer, config.width)
	WirePutU32(&writer, config.height)
	WirePutU8(&writer, config.kingdomCount)
	WirePutU8(&writer, u8(config.localKingdom))
	WirePutBool(&writer, config.spectator)
	return writer.pos, writer.ok
}

// --- session packets ---------------------------------------------------------

SESSION_PACKET_HEADER_BYTES :: 9 // kind, protocol version, payload length
SESSION_COMMANDS_HEADER_BYTES :: 4 // entry count
SESSION_COMMAND_MAX_BYTES :: LOGGED_COMMAND_HEADER_BYTES+1+4*4

SessionPacketKind :: enum u8 {
	Config   = 0,
	Commands = 1,
	Hash     = 2,
}

SessionEncodeConfigPacket :: proc(buf: []u8, config: SessionConfig) -> (used: int, ok: bool) {
	if len(buf) < SESSION_PACKET_HEADER_BYTES do return 0, false
	payloadUsed, payloadOk := SessionConfigEncode(buf[SESSION_PACKET_HEADER_BYTES:], config)
	if !payloadOk do return 0, false
	writer := WireWrite{buf = buf, ok = true}
	WirePutU8(&writer, u8(SessionPacketKind.Config))
	WirePutU32(&writer, SESSION_PROTOCOL_VERSION)
	WirePutU32(&writer, u32(payloadUsed))
	if !writer.ok do return 0, false
	return SESSION_PACKET_HEADER_BYTES+payloadUsed, true
}

SessionEncodeHashPacket :: proc(buf: []u8, tick: u64, hash: u64) -> (used: int, ok: bool) {
	if len(buf) < SESSION_PACKET_HEADER_BYTES+16 do return 0, false
	writer := WireWrite{buf = buf, ok = true}
	WirePutU8(&writer, u8(SessionPacketKind.Hash))
	WirePutU32(&writer, SESSION_PROTOCOL_VERSION)
	WirePutU32(&writer, 16)
	WirePutU64(&writer, tick)
	WirePutU64(&writer, hash)
	return writer.pos, writer.ok
}

SessionCommandsPacketSize :: proc(entries: []LoggedCommand) -> int {
	return SESSION_PACKET_HEADER_BYTES+SESSION_COMMANDS_HEADER_BYTES+
		len(entries)*SESSION_COMMAND_MAX_BYTES
}

SessionEncodeCommandsPacket :: proc(buf: []u8, entries: []LoggedCommand) -> (used: int, ok: bool) {
	if len(buf) < SESSION_PACKET_HEADER_BYTES+SESSION_COMMANDS_HEADER_BYTES do return 0, false
	writer := WireWrite{buf = buf, ok = true}
	WirePutU8(&writer, u8(SessionPacketKind.Commands))
	WirePutU32(&writer, SESSION_PROTOCOL_VERSION)
	WirePutU32(&writer, 0) // Patched below
	WirePutU32(&writer, u32(len(entries)))
	for entry in entries {
		if writer.pos >= len(buf) do return 0, false
		encoded, encodedOk := LoggedCommandEncode(buf[writer.pos:], entry)
		if !encodedOk do return 0, false
		writer.pos += encoded
	}
	if !writer.ok do return 0, false
	length := u32(writer.pos-SESSION_PACKET_HEADER_BYTES)
	for index in 0..<4 do buf[5+index] = u8(length>>(8*u32(index)))
	return writer.pos, true
}

SessionDecodePacket :: proc(buf: []u8) -> (
	kind: SessionPacketKind,
	payload: []u8,
	used: int,
	ok: bool,
) {
	reader := WireRead{buf = buf, ok = true}
	kindByte := WireGetU8(&reader)
	version := WireGetU32(&reader)
	length := int(WireGetU32(&reader))
	if !reader.ok || version != SESSION_PROTOCOL_VERSION do return .Config, nil, 0, false
	if length < 0 || reader.pos+length > len(buf) do return .Config, nil, 0, false
	return SessionPacketKind(kindByte), buf[reader.pos:reader.pos+length], reader.pos+length, true
}

// Encodes human commands the peer has not received yet. Commands are logged with
// their target tick, so the peer applies them at exactly the same boundary.
WorldCollectHumanCommands :: proc(
	w: ^World,
	cursor: ^int,
	buf: []u8,
) -> (used: int, ok: bool) {
	start := max(cursor^, 0)
	count := 0
	for entry in w.commandLog[start:] {
		if entry.source == .Human do count += 1
	}
	if count == 0 do return 0, true
	if len(buf) < SESSION_PACKET_HEADER_BYTES+SESSION_COMMANDS_HEADER_BYTES {
		return 0, false
	}
	writer := WireWrite{buf = buf, ok = true}
	WirePutU8(&writer, u8(SessionPacketKind.Commands))
	WirePutU32(&writer, SESSION_PROTOCOL_VERSION)
	WirePutU32(&writer, 0) // Patched below
	WirePutU32(&writer, u32(count))
	written := 0
	for entry in w.commandLog[start:] {
		if entry.source != .Human do continue
		if writer.pos >= len(buf) {
			writer.ok = false
			break
		}
		encoded, encodedOk := LoggedCommandEncode(buf[writer.pos:], entry)
		if !encodedOk {
			writer.ok = false
			break
		}
		writer.pos += encoded
		written += 1
	}
	if !writer.ok || written != count do return 0, false
	length := u32(writer.pos-SESSION_PACKET_HEADER_BYTES)
	for index in 0..<4 do buf[5+index] = u8(length>>(8*u32(index)))
	cursor^ = len(w.commandLog)
	return writer.pos, true
}

WorldReceiveSessionPacket :: proc(w: ^World, buf: []u8) -> bool {
	kind, payload, _, ok := SessionDecodePacket(buf)
	if !ok do return false
	switch kind {
	case .Config:
		config, _, configOk := SessionConfigDecode(payload)
		if !configOk do return false
		if w.peerConfigSeen && !SessionConfigCompatible(w.peerConfig, config) {
			w.desyncDetected = true
			return false
		}
		w.peerConfig = config
		w.peerConfigSeen = true
		return true
	case .Commands:
		reader := WireRead{buf = payload, ok = true}
		count := int(WireGetU32(&reader))
		if !reader.ok do return false
		for _ in 0..<count {
			entry, entryUsed, entryOk := LoggedCommandDecode(payload[reader.pos:])
			if !entryOk do return false
			reader.pos += entryUsed
			if !entry.accepted || entry.source != .Human do continue
			WorldQueueCommandAt(w, entry.kingdom, entry.command, entry.tick)
		}
		return true
	case .Hash:
		reader := WireRead{buf = payload, ok = true}
		tick := WireGetU64(&reader)
		hash := WireGetU64(&reader)
		if !reader.ok do return false
		WorldCheckPeerHash(w, tick, hash)
		return true
	}
	return false
}

SessionConfigDecode :: proc(buf: []u8) -> (config: SessionConfig, used: int, ok: bool) {
	reader := WireRead{buf = buf, ok = true}
	config.protocolVersion = WireGetU32(&reader)
	config.seed = WireGetU64(&reader)
	config.width = WireGetU32(&reader)
	config.height = WireGetU32(&reader)
	config.kingdomCount = WireGetU8(&reader)
	config.localKingdom = i8(WireGetU8(&reader))
	config.spectator = WireGetBool(&reader)
	return config, reader.pos, reader.ok
}
