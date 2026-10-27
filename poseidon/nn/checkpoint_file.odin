package nn

import "../core"
import "core:os"

// Serializes into scratch before creating a temporary file in the destination
// directory. The existing destination is not touched on validation, write,
// sync, or close failure. Replacement uses os.rename; its atomicity and crash
// durability depend on the OS and filesystem. A failed cleanup can leave a
// temporary file. Use a trusted directory; replacement may change permissions.
// Scratch and model storage must obey CheckpointWrite's rules.
CheckpointSaveFile :: proc(model: ^Sequential($maxLayers, $maxWidth, $batchCapacity), adam: ^Adam, shuffleState: u64, path: string, scratch: []u8) -> bool {
	if len(path) == 0 || len(path) > 32000 { return false }
	for c in path { if c == 0 { return false } }
	size, ok := CheckpointWrite(model, adam, shuffleState, scratch)
	if !ok { return false }

	dir := "."
	last := -1
	for _, i in path { if os.is_path_separator(path[i]) { last = i } }
	if last >= 0 { dir = path[:last+1] }
	when ODIN_OS == .Windows {
		// A drive-relative path resolves relative to that drive's current directory.
		if last < 0 && len(path) >= 2 && path[1] == ':' { return false }
	}
	file, err := os.create_temp_file(dir, ".poseidon-checkpoint-*")
	if err != nil { return false }
	// Keep the name after close without depending on an allocator.
	nameBuffer: [32768]u8
	name := os.name(file)
	if len(name) > len(nameBuffer) {
		_ = os.remove(name)
		_ = os.close(file)
		return false
	}
	copy(nameBuffer[:], name)
	tempPath := string(nameBuffer[:len(name)])
	renamed := false
	defer if !renamed { _ = os.remove(tempPath) }
	written, writeErr := os.write(file, scratch[:size])
	syncErr: os.Error
	if writeErr == nil && written == size { syncErr = os.sync(file) }
	closeErr := os.close(file)
	if writeErr != nil || written != size || syncErr != nil || closeErr != nil { return false }
	renamed = os.rename(tempPath, path) == nil
	return renamed
}

// Reads no more than len(scratch) checkpoint bytes and probes for excess data.
// On any I/O, size, or validation failure, destination objects are unchanged;
// scratch may be modified. The disjoint-storage and no-concurrent-mutation
// requirements of CheckpointRead also apply to this procedure and the file.
CheckpointLoadFile :: proc(model: ^Sequential($maxLayers, $maxWidth, $batchCapacity), adam: ^Adam, shuffleState: ^u64, path: string, scratch: []u8, parameterStorage: []^core.Node, firstMoment, secondMoment: []f32) -> bool {
	if len(path) == 0 { return false }
	for c in path { if c == 0 { return false } }
	file, err := os.open(path)
	if err != nil { return false }
	count := 0
	valid := true
	atEnd := false
	for count < len(scratch) {
		n, readErr := os.read(file, scratch[count:])
		count += n
		if readErr == .EOF { atEnd = true; break }
		if readErr != nil || n == 0 { valid = false; break }
	}
	if valid && !atEnd {
		probe: [1]u8
		n, readErr := os.read(file, probe[:])
		if n != 0 || readErr != .EOF { valid = false }
	}
	if os.close(file) != nil { valid = false }
	if !valid { return false }
	return CheckpointRead(model, adam, shuffleState, scratch[:count], parameterStorage, firstMoment, secondMoment)
}
