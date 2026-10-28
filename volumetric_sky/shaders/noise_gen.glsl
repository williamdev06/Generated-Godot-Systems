#[compute]
#version 450
// OWNS:       Tileable 3D cloud noise generation (Schneider 2015 layout).
//             Shape (is_detail = 0): r = Perlin-Worley eroded by Worley fBm, stretched to [0, 1];
//             gba = Worley fBm at increasing frequency (each ~0.3..0.7).
//             Detail (is_detail = 1): rgb = Worley fBm at increasing frequency.
// DEPENDS:    Nothing.
// INVARIANTS: Every noise tiles across the texture, so samplers must use repeat.
// GOTCHAS:    Runs once at initialization; Worley costs 27 cell lookups per octave.

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

layout(rgba8, set = 0, binding = 0) uniform restrict writeonly image3D noise_image;
layout(push_constant, std430) uniform PushConstant {
	float is_detail;
	float padding_0;
	float padding_1;
	float padding_2;
} push_constant;

#include "noise.glslinc"

void main() {
	ivec3 cell = ivec3(gl_GlobalInvocationID.xyz);
	ivec3 size = imageSize(noise_image);
	if (any(greaterThanEqual(cell, size))) {
		return;
	}
	vec3 position = (vec3(cell) + 0.5) / vec3(size);
	vec4 noise;
	if (push_constant.is_detail > 0.5) {
		noise = vec4(worley_fbm(position, 4.0), worley_fbm(position, 8.0), worley_fbm(position, 16.0), 1.0);
	} else {
		float perlin = clamp(perlin_fbm(position, 4.0) * 0.5 + 0.5, 0.0, 1.0);
		vec3 worley_octaves = vec3(worley_fbm(position, 4.0), worley_fbm(position, 8.0), worley_fbm(position, 16.0));
		// Perlin-Worley: Perlin's connectivity with Worley's billowy cells.
		float perlin_worley = worley_octaves.x + perlin * (1.0 - worley_octaves.x);
		float worley_combined = dot(worley_octaves, vec3(0.625, 0.25, 0.125));
		float base_shape = (perlin_worley - worley_combined + 1.0) / (2.0 - worley_combined);
		// Measured 2nd/98th percentiles of base_shape are ~0.75/0.90; stretching here, before 8-bit
		// quantization, lets coverage in [0, 1] map roughly linearly onto covered sky.
		noise = vec4(clamp((base_shape - 0.75) / 0.15, 0.0, 1.0), worley_octaves);
	}
	imageStore(noise_image, cell, noise);
}
