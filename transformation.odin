package main

import math "core:math"

Vec2 :: struct {
	x, y: f32,
}

Rect :: struct {
	x, y, width, height: f32,
}

ViewCamera :: struct {
	position: Vec2,
	zoom: f32,
}

Vec2Add :: proc(a, b: Vec2) -> Vec2 { return Vec2{a.x + b.x, a.y + b.y} }
Vec2Sub :: proc(a, b: Vec2) -> Vec2 { return Vec2{a.x - b.x, a.y - b.y} }
Vec2Scale :: proc(value: Vec2, scale: f32) -> Vec2 { return Vec2{value.x * scale, value.y * scale} }
Vec2Lerp :: proc(a, b: Vec2, amount: f32) -> Vec2 { return Vec2Add(a, Vec2Scale(Vec2Sub(b, a), amount)) }
Vec2Clamp :: proc(value, min, max: Vec2) -> Vec2 { return Vec2{clamp(value.x, min.x, max.x), clamp(value.y, min.y, max.y)} }
Vec2Length :: proc(value: Vec2) -> f32 { return math.sqrt(value.x * value.x + value.y * value.y) }
Vec2Normalize :: proc(value: Vec2) -> Vec2 {
	length := Vec2Length(value)
	if length <= 0 do return Vec2{}
	return Vec2Scale(value, 1 / length)
}

ViewCameraViewSize :: proc(camera: ViewCamera) -> Vec2 { return Vec2{f32(BOARD_COLUMNS) / camera.zoom, f32(BOARD_ROWS) / camera.zoom} }

ViewCameraClamp :: proc(camera: ^ViewCamera, world_size: Vec2) {
	view_size := ViewCameraViewSize(camera^)
	max_position := Vec2Sub(world_size, view_size)
	camera.position = Vec2Clamp(camera.position, Vec2{}, max_position)
}

ViewCameraScreenToWorld :: proc(camera: ViewCamera, screen: Vec2) -> Vec2 {
	cell_size := f32(CELL_SIZE) * camera.zoom
	return Vec2{camera.position.x + (screen.x - f32(BOARD_X)) / cell_size, camera.position.y + (screen.y - f32(BOARD_Y)) / cell_size}
}

ViewCameraWorldToScreen :: proc(camera: ViewCamera, world: Vec2) -> Vec2 {
	cell_size := f32(CELL_SIZE) * camera.zoom
	return Vec2{f32(BOARD_X) + (world.x - camera.position.x) * cell_size, f32(BOARD_Y) + (world.y - camera.position.y) * cell_size}
}
