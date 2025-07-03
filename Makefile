hello_triangle: main.odin graphics/* loader/* shaders/triangle/frag.spv shaders/triangle/vert.spv shaders/triangle_lit/frag.spv shaders/triangle_lit/vert.spv
	odin build . -debug -o:none

shaders/triangle/frag.spv: shaders/triangle/triangle.frag
	glslc shaders/triangle/triangle.frag -o shaders/triangle/frag.spv

shaders/triangle/vert.spv: shaders/triangle/triangle.vert
	glslc shaders/triangle/triangle.vert -o shaders/triangle/vert.spv

shaders/triangle_lit/frag.spv: shaders/triangle_lit/triangle_lit.frag
	glslc shaders/triangle_lit/triangle_lit.frag -o shaders/triangle_lit/frag.spv

shaders/triangle_lit/vert.spv: shaders/triangle_lit/triangle_lit.vert
	glslc shaders/triangle_lit/triangle_lit.vert -o shaders/triangle_lit/vert.spv
