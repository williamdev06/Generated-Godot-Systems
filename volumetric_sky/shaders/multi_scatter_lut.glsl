#[compute]
#version 450
// OWNS:       Multiple-scattering LUT (Hillaire 2020 section 5.5): x = sun zenith cos, y = height.
// DEPENDS:    params (haze), atmosphere.glslinc, scattering.glslinc, transmittance LUT.
// INVARIANTS: Re-run only when haze changes, right after the transmittance LUT.
// GOTCHAS:    Each texel integrates 64 directions serially; acceptable because it rarely re-runs.

#define MULTI_SCATTERING_PASS

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

#include "params.glslinc"
layout(rgba16f, set = 0, binding = 1) uniform restrict writeonly image2D multi_scatter_image;
layout(set = 0, binding = 2) uniform sampler2D transmittance_lut;

#include "atmosphere.glslinc"
#include "scattering.glslinc"

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(multi_scatter_image);
	if (any(greaterThanEqual(pixel, size))) {
		return;
	}
	vec2 uv = (vec2(pixel) + 0.5) / vec2(size);
	float sun_zenith_cos = uv.x * 2.0 - 1.0;
	vec3 origin = vec3(0.0, mix(GROUND_RADIUS_KM, TOP_RADIUS_KM, uv.y), 0.0);
	vec3 sun_direction = vec3(0.0, sun_zenith_cos, sqrt(max(1.0 - sun_zenith_cos * sun_zenith_cos, 0.0)));

	const int SQRT_DIRECTION_COUNT = 8;
	const float DIRECTION_WEIGHT = 1.0 / float(SQRT_DIRECTION_COUNT * SQRT_DIRECTION_COUNT);
	vec3 second_order = vec3(0.0);
	vec3 multi_scatter_as_1 = vec3(0.0);
	for (int i = 0; i < SQRT_DIRECTION_COUNT; i++) {
		for (int j = 0; j < SQRT_DIRECTION_COUNT; j++) {
			// Uniform sphere sampling on a stratified grid.
			float azimuth = 2.0 * PI * (float(i) + 0.5) / float(SQRT_DIRECTION_COUNT);
			float zenith = acos(1.0 - 2.0 * (float(j) + 0.5) / float(SQRT_DIRECTION_COUNT));
			vec3 direction = vec3(sin(zenith) * cos(azimuth), cos(zenith), sin(zenith) * sin(azimuth));
			ScatteringResult result = integrate_scattering(origin, direction, sun_direction, vec3(1.0), 20, 1e9);
			second_order += result.luminance * DIRECTION_WEIGHT;
			multi_scatter_as_1 += result.multi_scatter_as_1 * DIRECTION_WEIGHT;
		}
	}
	// Infinite-order scattering as a geometric series of the isotropic transfer function.
	imageStore(multi_scatter_image, pixel, vec4(second_order / (1.0 - multi_scatter_as_1), 1.0));
}
