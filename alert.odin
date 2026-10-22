package main

ALERT_CAPACITY :: 32
ALERT_ATTACK_THROTTLE :: 12

AlertKind :: enum {
	TownFounded,
	TownLost,
	UnderAttack,
	EnemySpotted,
	Milestone,
	WarDeclared,
	PeaceMade,
}

Alert :: struct {
	kind:      AlertKind,
	kingdom:   int,
	town:      int,
	other:     int,
	town_name: Name,
	x, y:      f32,
	time:      f32,
}

AlertFeed :: struct {
	items: [ALERT_CAPACITY]Alert,
	count: int,
	next:  int,
}

WorldAlertAdd :: proc(w: ^World, kind: AlertKind, kingdom, town, other: int, x, y: f32) {
	if kingdom != PLAYER_KINGDOM do return

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

	w.alerts.items[w.alerts.next] = Alert{
		kind = kind,
		kingdom = kingdom,
		town = town,
		other = other,
		x = x,
		y = y,
		time = w.simulationTime,
	}
	if town >= 0 && town < TOWN_CAPACITY && kingdom >= 0 && kingdom < KINGDOMS_CAPACITY {
		w.alerts.items[w.alerts.next].town_name = w.kingdoms[kingdom].towns[town].name
	}
	w.alerts.next = (w.alerts.next+1)%ALERT_CAPACITY
	if w.alerts.count < ALERT_CAPACITY do w.alerts.count += 1
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
