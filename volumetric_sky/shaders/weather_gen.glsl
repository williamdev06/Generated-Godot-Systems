#[compute]
#version 450
// OWNS:       Tileable 2D procedural weather texture: r = coverage variation, g = cloud type.
// DEPENDS:    noise.glslinc.
// INVARIANTS: Tiles across the texture (sampled with repeat in clouds.glslinc sample_weather).
// GOTCHAS:    Runs once at initialization. Smooth Perlin fBm at 512^2 replaces sampling a slice of the
//             128^3 shape noise, whose ~470 m texels left straight cloud edges where coverage thresholds.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba8, set = 0, binding = 0) uniform restrict writeonly image2D weather_image;

#include "noise.glslinc"

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(weather_image);
	if (any(greaterThanEqual(pixel, size))) {
		return;
	}
	vec3 position = vec3((vec2(pixel) + 0.5) / vec2(size), 0.5);
	float coverage_noise = perlin_fbm(position, 4.0);
	// Offset by whole cells' worth of hash input so type is uncorrelated with coverage; still tiles.
	float type_noise = perlin_fbm(position + vec3(0.0, 0.0, 0.25), 3.0);
	// Measured 2nd/98th percentiles of fbm * 0.5 + 0.5 are 0.373/0.612 (coverage) and 0.373/0.631 (type);
	// stretch both to ~[0, 1] before 8-bit storage so coverage_variation and cloud type use the full range.
	vec2 raw = vec2(coverage_noise, type_noise) * 0.5 + 0.5;
	vec2 stretched = clamp((raw - 0.373) / vec2(0.239, 0.258), 0.0, 1.0);
	imageStore(weather_image, pixel, vec4(stretched, 0.0, 1.0));
}
