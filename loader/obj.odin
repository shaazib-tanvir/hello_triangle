package loader

import "core:strings"
import "core:strconv"
import "core:log"
import "core:math/linalg"
import "../graphics"

ParseResult :: enum {
	SUCCESS,
	INVALID_INPUT
}

log_warning :: proc(line_number: int, line: string, message: string, location := #caller_location) {
	log.warnf("[obj parser] %v:'%v' %v", line_number, line, message, location=location)
}

parse_vector3 :: proc(line_number: int, line: string, components: []string) -> (vector: linalg.Vector3f32, ok: bool) {
	if len(components) != 3 {
		log_warning(line_number, line, "this must be a vector with 3 components")
		return
	}

	for i in 0..<3 {
		component := components[i]
		parse_ok: bool
		vector[i], parse_ok = strconv.parse_f32(component)
		if !parse_ok {
			log_warning(line_number, line, "failed to parse float")
			return
		}
	}

	ok = true
	return
}

parse_vector2 :: proc(line_number: int, line: string, components: []string) -> (vector: linalg.Vector2f32, ok: bool) {
	if len(components) != 2 {
		log_warning(line_number, line, "this must be a vector with 3 components")
		return
	}

	for i in 0..<2 {
		component := components[i]
		parse_ok: bool
		vector[i], parse_ok = strconv.parse_f32(component)
		if !parse_ok {
			log_warning(line_number, line, "failed to parse float")
			return
		}
	}

	ok = true
	return
}

parse_u32 :: proc(str: string) -> (res: u32, ok: bool) {
	tmp: uint
	tmp, ok = strconv.parse_uint(str)
	res = u32(tmp)
	return
}

parse_indices :: proc(line_number: int, line: string, vertex_data: string) -> (vertex_index: u32, texture_coordinate_index: u32, normal_index: u32, ok: bool) {
	defer {
		if ok && vertex_index == 0 {
			log_warning(line_number, line, "invalid vertex index")
		}
	}

	if vertex_data == "" {
		log_warning(line_number, line, "no vertex data found")
	}
	components := strings.split(vertex_data, "/")
	defer delete(components)
	if len(components) == 1 {
		vertex_index, ok = parse_u32(components[0])
		if !ok {
			log_warning(line_number, line, "failed to parse indices")
		}
		return
	} else if len(components) == 2 {
		vertex_index_ok, texture_coordinate_index_ok: bool
		tmp: uint
		vertex_index, vertex_index_ok = parse_u32(components[0])
		texture_coordinate_index, texture_coordinate_index_ok = parse_u32(components[1])
		ok = texture_coordinate_index_ok && vertex_index_ok
		if !ok {
			log_warning(line_number, line, "failed to parse indices")
		}
		return
	} else if len(components) == 3{
		vertex_index_ok, texture_coordinate_index_ok, normal_ok: bool
		vertex_index, vertex_index_ok = parse_u32(components[0])
		texture_coordinate_index, texture_coordinate_index_ok = parse_u32(components[1])
		normal_index, normal_ok = parse_u32(components[2])
		ok = texture_coordinate_index_ok && vertex_index_ok || normal_ok && vertex_index_ok
		if !ok {
			log_warning(line_number, line, "failed to parse indices")
		}
		return
	} else {
		log_warning(line_number, line, "invalid syntax. the format of face data is vi[/vt[/vn]]")
		return
	}
}

parse_obj :: proc(contents: string) -> (vertices: [dynamic]graphics.Vertex, indices: [dynamic]u32, result: ParseResult) {
	lines := strings.split_lines(contents)
	defer delete(lines)

	vertices = make([dynamic]graphics.Vertex, 0)
	vertex_texture_coordinates := make([dynamic]linalg.Vector2f32, 0)
	defer delete(vertex_texture_coordinates)
	vertex_normals := make([dynamic]linalg.Vector3f32, 0)
	defer delete(vertex_normals)

	indices = make([dynamic]u32, 0)

	for line_number in 0..<len(lines) {
		line := lines[line_number]
		if len(line) == 0 {
			continue
		}

		elements := strings.split(line, " ")
		defer delete(elements)
		prefix := elements[0]

		switch prefix {
		case "#":
			continue
		case "mtllib":
			log_warning(line_number, line, "materials are not supported. prefix 'mtllib is being ignored")
			continue
		case "o":
			continue
		case "v":
			vertex: graphics.Vertex
			value, ok := parse_vector3(line_number, line, elements[1:])
			if !ok {
				result = .INVALID_INPUT
				return
			}
			vertex.position = value
			vertex.color = linalg.Vector3f32{.75, .75, .75}
			append(&vertices, vertex)
		case "vn":
			normal, ok := parse_vector3(line_number, line, elements[1:])
			if !ok {
				result = .INVALID_INPUT
				return
			}
			append(&vertex_normals, normal)
		case "vt":
			texture_coordinate, ok := parse_vector2(line_number, line, elements[1:])
			if !ok {
				result = .INVALID_INPUT
				return
			}
			append(&vertex_texture_coordinates, texture_coordinate)
		case "s":
			log_warning(line_number, line, "smooth shading config is not currently supported")
		case "f":
			vertices_data := elements[1:]
			if len(vertices_data) == 3 {
				for i in 0..<3 {
					vi, vti, vni, parse_ok := parse_indices(line_number, line, vertices_data[i])
					if !parse_ok {
						result = .INVALID_INPUT
						return
					}

					append(&indices, vi - 1)
					if vti != 0 {
						if vti > u32(len(vertex_texture_coordinates)) {
							log_warning(line_number, line, "texture coordinate out of bounds")
							result = .INVALID_INPUT
							return
						}
						vertices[vi - 1].texture_coordinate = vertex_texture_coordinates[vti - 1]
					}
					if vni != 0 {
						if vni > u32(len(vertex_normals)) {
							log_warning(line_number, line, "texture coordinate out of bounds")
							result = .INVALID_INPUT
							return
						}
						vertices[vi - 1].normal = vertex_normals[vni - 1]
					}
				}
			} else if len(vertices_data) == 4 {
				vi, vti, vni: [4]u32
				for i in 0..<4 {
					parse_ok: bool
					vi[i], vti[i], vni[i], parse_ok = parse_indices(line_number, line, vertices_data[i])
					if !parse_ok {
						result = .INVALID_INPUT
						return
					}

					if vti[i] != 0 {
						if vti[i] > u32(len(vertex_texture_coordinates)) {
							log_warning(line_number, line, "texture coordinate index out of bounds")
							result = .INVALID_INPUT
							return
						}
						vertices[vi[i] - 1].texture_coordinate = vertex_texture_coordinates[vti[i] - 1]
					}
					if vni[i] != 0 {
						if vni[i] > u32(len(vertex_normals)) {
							log_warning(line_number, line, "normal index out of bounds")
							result = .INVALID_INPUT
							return
						}
						vertices[vi[i] - 1].normal = vertex_normals[vni[i] - 1]
					}
				}
				append(&indices, vi[0] - 1, vi[1] - 1, vi[2] - 1, vi[0] - 1, vi[2] - 1, vi[3] - 1)
			} else {
				log_warning(line_number, line, "n-gons are not supported. skipping face")
				result = .INVALID_INPUT
				return
			}
		}
	}
	
	return
}
