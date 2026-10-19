package main

TOWN_CAPACITY :: 100

Kingdom :: struct {
	towns: #soa [TOWN_CAPACITY]Town,
	townUsed: [TOWN_CAPACITY]bool,
}

Town :: struct {}
