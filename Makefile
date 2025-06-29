hello_triangle: main.odin shaders/triangle/frag.spv shaders/triangle/vert.spv
	odin build . -debug -o:none

shaders/triangle/frag.spv: shaders/triangle/triangle.frag
	glslc shaders/triangle/triangle.frag -o shaders/triangle/frag.spv

shaders/triangle/vert.spv: shaders/triangle/triangle.vert
	glslc shaders/triangle/triangle.vert -o shaders/triangle/vert.spv
