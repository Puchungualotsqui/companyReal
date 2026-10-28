package main

import rl "vendor:raylib"

ALERT_CAPACITY :: 64
ALERT_ATTACK_THROTTLE :: 12
ALERT_LIFETIME_SECONDS :: 60

AlertKind :: enum {
	TownFounded,
	TownLost,
	UnderAttack,
	EnemySpotted,
	Milestone,
	WarDeclared,
	PeaceMade,
	TownGrowth,
	TownFused,
	InsightGained,
	Environment,
}

Alert :: struct {
	kind:       AlertKind,
	kingdom:    int,
	town:       int,
	other:      int,
	townName:  Name,
	otherName: Name,
	x, y:       f32,
	time:       f32,
	realTime:  f64,
	amount:     int,
}

AlertFeed :: struct {
	items: [ALERT_CAPACITY]Alert,
	count: int,
	next:  int,
}

@(private = "file")
WorldAlertPush :: proc(w: ^World, alert: Alert) -> ^Alert {
	slot := w.alerts.next
	entry := alert
	entry.realTime = rl.GetTime()
	w.alerts.items[slot] = entry

	if entry.town >= 0 && entry.town < TOWN_CAPACITY &&
		entry.kingdom >= 0 && entry.kingdom < KINGDOMS_CAPACITY {
		w.alerts.items[slot].townName = w.kingdoms[entry.kingdom].towns[entry.town].name
	}
	if entry.kind == .TownFused && entry.other >= 0 && entry.other < TOWN_CAPACITY &&
		entry.kingdom >= 0 && entry.kingdom < KINGDOMS_CAPACITY {
		w.alerts.items[slot].otherName = w.kingdoms[entry.kingdom].towns[entry.other].name
	}

	w.alerts.next = (w.alerts.next+1)%ALERT_CAPACITY
	if w.alerts.count < ALERT_CAPACITY do w.alerts.count += 1
	return &w.alerts.items[slot]
}

WorldAlertAdd :: proc(w: ^World, kind: AlertKind, kingdom, town, other: int, x, y: f32) {
	if w.observerKingdom < 0 || kingdom != w.observerKingdom do return

	// Damage arrives many times per second; one alert per town is enough.
	if kind == .UnderAttack {
		for i in 0..<w.alerts.count {
			alert := w.alerts.items[(w.alerts.next-1-i+ALERT_CAPACITY*2)%ALERT_CAPACITY]
			if alert.kind == .UnderAttack && alert.kingdom == kingdom && alert.town == town &&
				w.simulationTime-alert.time < ALERT_ATTACK_THROTTLE {
				return
			}
		}
	}

	WorldAlertPush(
		w,
		Alert{
			kind = kind,
			kingdom = kingdom,
			town = town,
			other = other,
			x = x,
			y = y,
			time = w.simulationTime,
		},
	)
}

WorldAlertAddInsight :: proc(w: ^World, kingdom, amount: int) {
	if w.observerKingdom < 0 || kingdom != w.observerKingdom do return
	WorldAlertPush(
		w,
		Alert{
			kind = .InsightGained,
			kingdom = kingdom,
			town = -1,
			other = -1,
			time = w.simulationTime,
			amount = amount,
		},
	)
}

// Population arrivals are frequent; one refreshing row per town keeps the
// feed readable without hiding the event.
WorldAlertAddGrowth :: proc(w: ^World, kingdom, town, amount: int) {
	if w.observerKingdom < 0 || kingdom != w.observerKingdom do return
	now := rl.GetTime()

	for i in 0..<w.alerts.count {
		alert := &w.alerts.items[(w.alerts.next-1-i+ALERT_CAPACITY*2)%ALERT_CAPACITY]
		if alert.kind != .TownGrowth || alert.kingdom != kingdom || alert.town != town do continue
		alert.amount += amount
		alert.realTime = now
		alert.time = w.simulationTime
		return
	}

	townRef := &w.kingdoms[kingdom].towns[town]
	WorldAlertPush(
		w,
		Alert{
			kind = .TownGrowth,
			kingdom = kingdom,
			town = town,
			other = -1,
			x = f32(townRef.x),
			y = f32(townRef.y),
			time = w.simulationTime,
			amount = amount,
		},
	)
}

WorldAlertAddEnvironment :: proc(w: ^World, event: ^EnvironmentEvent) {
	if w.observerKingdom < 0 do return
	if !EnvironmentEventRevealed(w) do return
	WorldAlertPush(
		w,
		Alert{
			kind = .Environment,
			kingdom = event.kingdom,
			town = event.town,
			other = int(event.kind),
			amount = int(event.severity),
			x = event.centerX,
			y = event.centerY,
			time = w.simulationTime,
		},
	)
}

WorldAlertNewest :: proc(w: ^World, index: int) -> (Alert, bool) {
	if index < 0 || index >= w.alerts.count do return {}, false
	slot := (w.alerts.next-1-index+ALERT_CAPACITY*2)%ALERT_CAPACITY
	return w.alerts.items[slot], true
}

WorldAlertClear :: proc(w: ^World) {
	w.alerts.count = 0
	w.alerts.next = 0
}

WorldAlertPrune :: proc(w: ^World) {
	if w.alerts.count == 0 do return
	now := rl.GetTime()

	survivors: [ALERT_CAPACITY]Alert
	count := 0
	for index in 0..<w.alerts.count {
		alert, found := WorldAlertNewest(w, index)
		if !found do continue
		if now-alert.realTime >= ALERT_LIFETIME_SECONDS do continue
		survivors[count] = alert
		count += 1
	}
	if count == w.alerts.count do return

	for index in 0..<count {
		w.alerts.items[count-1-index] = survivors[index]
	}
	for index in count..<ALERT_CAPACITY {
		w.alerts.items[index] = {}
	}
	w.alerts.count = count
	w.alerts.next = count%ALERT_CAPACITY
}

WorldAlertDismiss :: proc(w: ^World, newestIndex: int) {
	if newestIndex < 0 || newestIndex >= w.alerts.count do return

	survivors: [ALERT_CAPACITY]Alert
	count := 0
	for index in 0..<w.alerts.count {
		if index == newestIndex do continue
		alert, found := WorldAlertNewest(w, index)
		if !found do continue
		survivors[count] = alert
		count += 1
	}

	for index in 0..<count {
		w.alerts.items[count-1-index] = survivors[index]
	}
	for index in count..<ALERT_CAPACITY {
		w.alerts.items[index] = {}
	}
	w.alerts.count = count
	w.alerts.next = count%ALERT_CAPACITY
}
