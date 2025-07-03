#version 450

layout(set = 0, binding = 1) uniform LightInfo {
	vec3 lightPosition;
	vec3 cameraPosition;
} lightInfo;

layout(location = 0) in vec3 fragColor;
layout(location = 1) in vec3 normal;

layout(location = 0) out vec4 outColor;

void main() {
	vec3 lightPosition = normalize(lightInfo.lightPosition);
	vec3 cameraPosition = normalize(lightInfo.cameraPosition);
	vec3 reflected = 2. * dot(normal, lightPosition) * normal - lightPosition;
	float t = (dot(normal, lightPosition) + 1.) / 2.;
	float s = clamp(5. * dot(reflected, cameraPosition) - 4., 0., 1.);
	vec3 coolColor = .25 * fragColor + vec3(0., 0., .5);
	vec3 warmColor = .25 * fragColor + vec3(.5, .5, 0.);
	vec3 highlightColor = vec3(.7, .7, .7);
	vec3 color = s * highlightColor + (1. - s) * (t * warmColor + (1. - t) * coolColor);
    outColor = vec4(color, 1.0);
}
