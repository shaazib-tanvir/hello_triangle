#version 450

layout(set = 0, binding = 0) uniform ModelViewProjection {
	mat4 model;
	mat4 view;
	mat4 projection;
} mvp;

layout(location = 0) in vec3 inPos;
layout(location = 1) in vec3 inColor;
layout(location = 2) in vec2 inTextureCoord;
layout(location = 3) in vec3 inNormal;

layout(location = 0) out vec3 fragColor;
layout(location = 1) out vec3 normal;

void main() {
	gl_Position = mvp.projection * mvp.view * mvp.model * vec4(inPos, 1.0);
	fragColor = inColor;
	normal = (mvp.model * vec4(inNormal, 1.)).xyz;
}
