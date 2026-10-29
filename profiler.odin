package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import rl "vendor:raylib"

// Set to false to remove profiling output and its overhead.
PROFILING_ENABLED :: true

// Lightweight frame profiler. Instrument sections with ProfilerBegin/ProfilerEnd.
// Results are printed to the console and written to profiler.log.
PROFILER_LOG_PATH :: "profiler.log"
PROFILER_REPORT_SECONDS :: 2.0
PROFILER_SLOW_WARNING_SECONDS :: 0.10
PROFILER_SLOW_DUMP_SECONDS :: 0.50
PROFILER_MAX_ENTRIES :: 128
PROFILER_REPORT_ROWS :: 128

// Cached sections for hot loops. Registering by name every call is too slow
// once a section is entered thousands of times per tick.
ProfileSection :: enum {
	UnitSafety, // Civilian threat check
	UnitExtinguish, // Fire response scan
	UnitSeek, // Roam, resource, home and construction searches
	UnitMove, // Path following, including A*
	TownSiteSearch, // Building site sampling
	TownSiteStart, // Committing a construction site
	TownPathSite, // Street extension search
}

PROFILER_SECTION_NAMES := [ProfileSection]cstring {
	.UnitSafety = "Phase:Safety",
	.UnitExtinguish = "Phase:Extinguish",
	.UnitSeek = "Phase:Seek",
	.UnitMove = "Phase:Move",
	.TownSiteSearch = "Phase:SiteSearch",
	.TownSiteStart = "Phase:SiteStart",
	.TownPathSite = "Phase:PathSite",
}

ProfilerEntry :: struct {
	name:        cstring,
	total:       f64, // seconds accumulated this frame
	reportTotal: f64, // seconds accumulated since the last report
	reportPeak:  f64, // worst frame since the last report
	calls:       int, // calls this frame
	reportCalls: int, // calls since the last report
}

ProfileStamp :: struct {
	index: int,
	start: f64,
}

Profiler :: struct {
	entries:          [PROFILER_MAX_ENTRIES]ProfilerEntry,
	count:            int,
	enabled:          bool,
	frameStart:       f64,
	frameTime:        f64,
	reportStart:      f64,
	reportFrames:     int,
	reportFrameTotal: f64,
	reportFrameMax:   f64,
	file:             ^os.File,
	unitKindIndex:    [UnitKind]int,
	sectionIndex:     [ProfileSection]int,
	// Unit updates run on every core, so section timings are locked.
	mutex:            sync.Mutex,
	// Set while the unit loop runs on workers: per-call sections would spend
	// more time on the lock than on the work.
	parallel:         bool,
}

profiler: Profiler

UNIT_PROFILE_NAMES := [UnitKind]cstring{
	.Villager = "Unit:Villager",
	.Builder = "Unit:Builder",
	.CombatBuilder = "Unit:CombatBuilder",
	.WaterCollector = "Unit:WaterCollector",
	.Farmer = "Unit:Farmer",
	.Knight = "Unit:Knight",
	.Archer = "Unit:Archer",
	.Mage = "Unit:Mage",
	.Giant = "Unit:Giant",
	.Turtle = "Unit:Turtle",
	.Catapult = "Unit:Catapult",
	.Rogue = "Unit:Rogue",
	.Explorer = "Unit:Explorer",
}

ProfilerInit :: proc() {
	profiler = Profiler{
		enabled = PROFILING_ENABLED,
		frameStart = rl.GetTime(),
		reportStart = rl.GetTime(),
	}
	for &index in profiler.unitKindIndex do index = -1
	for &index in profiler.sectionIndex do index = -1
	if !PROFILING_ENABLED do return
	for name, kind in UNIT_PROFILE_NAMES {
		profiler.unitKindIndex[kind] = ProfilerRegister(name)
	}
	for name, section in PROFILER_SECTION_NAMES {
		profiler.sectionIndex[section] = ProfilerRegister(name)
	}
	file, err := os.open(PROFILER_LOG_PATH, {.Write, .Create, .Trunc})
	if err == nil do profiler.file = file
}

ProfilerDeinit :: proc() {
	if profiler.file == nil do return
	os.close(profiler.file)
	profiler.file = nil
}

ProfilerWrite :: proc(text: string) {
	fmt.print(text)
	if profiler.file != nil do _, _ = os.write(profiler.file, transmute([]byte)text)
}

ProfilerRegister :: proc(name: cstring) -> int {
	sync.guard(&profiler.mutex)
	for entry, i in profiler.entries[:profiler.count] {
		if entry.name == name do return i
	}
	if profiler.count >= PROFILER_MAX_ENTRIES do return -1
	index := profiler.count
	profiler.entries[index] = ProfilerEntry{name = name}
	profiler.count += 1
	return index
}

ProfilerBegin :: proc(name: cstring) -> ProfileStamp {
	if !profiler.enabled || profiler.parallel do return {index = -1}
	return ProfileStamp{index = ProfilerRegister(name), start = rl.GetTime()}
}

ProfilerAdd :: proc(index: int, elapsed: f64) {
	if !profiler.enabled || index < 0 || index >= profiler.count do return
	sync.guard(&profiler.mutex)
	entry := &profiler.entries[index]
	entry.total += elapsed
	entry.calls += 1
}

// Merges per-worker timing captured during a parallel phase.
ProfilerAddTotal :: proc(index: int, elapsed: f64, calls: int) {
	if !profiler.enabled || index < 0 || index >= profiler.count do return
	sync.guard(&profiler.mutex)
	entry := &profiler.entries[index]
	entry.total += elapsed
	entry.calls += calls
}

// Hot-loop helpers. ProfilerBegin cannot be used here because it resolves the
// name on every call.
ProfileSectionBegin :: proc(section: ProfileSection) -> f64 {
	if !profiler.enabled do return 0
	return rl.GetTime()
}

ProfileSectionEnd :: proc(section: ProfileSection, start: f64) {
	if !profiler.enabled || profiler.parallel do return
	ProfilerAdd(profiler.sectionIndex[section], rl.GetTime()-start)
}

ProfilerEnd :: proc(stamp: ProfileStamp) {
	if !profiler.enabled || profiler.parallel || stamp.index < 0 do return
	elapsed := rl.GetTime()-stamp.start
	{
		sync.guard(&profiler.mutex)
		entry := &profiler.entries[stamp.index]
		entry.total += elapsed
		entry.calls += 1
	}
	if elapsed < PROFILER_SLOW_WARNING_SECONDS do return

	buffer: [256]u8
	line := fmt.bprintf(
		buffer[:],
		"PROFILE SLOW: %s %.1f ms",
		profiler.entries[stamp.index].name,
		elapsed*1000,
		newline = true,
	)
	ProfilerWrite(line)
	if profiler.entries[stamp.index].name == "Sim:Tick" && elapsed >= PROFILER_SLOW_DUMP_SECONDS {
		ProfilerDumpCurrent()
	}
}

ProfilerDumpCurrent :: proc() {
	order: [PROFILER_MAX_ENTRIES]int
	orderCount := 0
	for i in 0..<profiler.count {
		entry := &profiler.entries[i]
		if entry.calls == 0 && entry.total <= 0 do continue
		order[orderCount] = i
		orderCount += 1
	}
	for i in 1..<orderCount {
		current := order[i]
		j := i-1
		for j >= 0 && profiler.entries[current].total > profiler.entries[order[j]].total {
			order[j+1] = order[j]
			j -= 1
		}
		order[j+1] = current
	}

	report: strings.Builder
	defer strings.builder_destroy(&report)
	fmt.sbprintfln(&report, "PROFILE TICK DUMP")
	rows := min(orderCount, PROFILER_REPORT_ROWS)
	for row in 0..<rows {
		entry := &profiler.entries[order[row]]
		fmt.sbprintfln(
			&report,
			"  %-24s total=%.2fms  calls=%d",
			entry.name,
			entry.total*1000,
			entry.calls,
		)
	}
	ProfilerWrite(strings.to_string(report))
}

ProfilerFrameEnd :: proc(w: ^World) {
	if !profiler.enabled do return
	now := rl.GetTime()
	profiler.frameTime = now-profiler.frameStart
	profiler.reportFrames += 1
	profiler.reportFrameTotal += profiler.frameTime
	profiler.reportFrameMax = max(profiler.reportFrameMax, profiler.frameTime)

	for i in 0..<profiler.count {
		entry := &profiler.entries[i]
		entry.reportTotal += entry.total
		entry.reportPeak = max(entry.reportPeak, entry.total)
		entry.reportCalls += entry.calls
		entry.total = 0
		entry.calls = 0
	}
	profiler.frameStart = now

	if now-profiler.reportStart < PROFILER_REPORT_SECONDS do return
	ProfilerReport(w)
	profiler.reportStart = now
	profiler.reportFrames = 0
	profiler.reportFrameTotal = 0
	profiler.reportFrameMax = 0
	for i in 0..<profiler.count {
		entry := &profiler.entries[i]
		entry.reportTotal = 0
		entry.reportPeak = 0
		entry.reportCalls = 0
	}
}

ProfilerEntryLess :: proc(a, b: ProfilerEntry) -> bool {
	return a.reportTotal > b.reportTotal
}

ProfilerReport :: proc(w: ^World) {
	interval := rl.GetTime()-profiler.reportStart
	frames := max(profiler.reportFrames, 1)
	units, buildings, towns := ProfilerWorldCounts(w)
	report: strings.Builder
	defer strings.builder_destroy(&report)

	fmt.sbprintfln(
		&report,
		"PROFILE %.1fs  frames=%d  frame_avg=%.2fms  frame_max=%.2fms  units=%d  buildings=%d  towns=%d  fires=%d  parallel=%d",
		interval,
		frames,
		profiler.reportFrameTotal/f64(frames)*1000,
		profiler.reportFrameMax*1000,
		units,
		buildings,
		towns,
		w.fireCount,
		parallelHelperCount,
	)

	order: [PROFILER_MAX_ENTRIES]int
	orderCount := 0
	for i in 0..<profiler.count {
		entry := &profiler.entries[i]
		if entry.reportCalls == 0 && entry.reportTotal <= 0 do continue
		order[orderCount] = i
		orderCount += 1
	}
	for i in 1..<orderCount {
		current := order[i]
		j := i-1
		for j >= 0 && ProfilerEntryLess(profiler.entries[current], profiler.entries[order[j]]) {
			order[j+1] = order[j]
			j -= 1
		}
		order[j+1] = current
	}

	rows := min(orderCount, PROFILER_REPORT_ROWS)
	for row in 0..<rows {
		entry := &profiler.entries[order[row]]
		perCall := f64(0)
		if entry.reportCalls > 0 do perCall = entry.reportTotal/f64(entry.reportCalls)*1000
		fmt.sbprintfln(
			&report,
			"  %-24s avg=%.2fms  peak=%.2fms  per_call=%.3fms  calls/frame=%.2f",
			entry.name,
			entry.reportTotal/f64(frames)*1000,
			entry.reportPeak*1000,
			perCall,
			f64(entry.reportCalls)/f64(frames),
		)
	}
	if orderCount > rows {
		fmt.sbprintfln(&report, "  ... %d more sections", orderCount-rows)
	}
	ProfilerWrite(strings.to_string(report))
}

ProfilerWorldCounts :: proc(w: ^World) -> (units, buildings, towns: int) {
	if w == nil do return
	for slot in 0..<UNIT_CAPACITY {
		if w.unitUsed[slot] do units += 1
	}
	for slot in 0..<BUILDING_CAPACITY {
		if w.buildingUsed[slot] do buildings += 1
	}
	for kingdom in 0..<KINGDOM_SLOTS {
		towns += KingdomTownCount(w, kingdom)
	}
	return
}
