package graphics

import "core:math/linalg"

Vertex :: struct {
	position: linalg.Vector3f32,
	color: linalg.Vector3f32,
	texture_coordinate: linalg.Vector2f32,
	normal: linalg.Vector3f32,
}
