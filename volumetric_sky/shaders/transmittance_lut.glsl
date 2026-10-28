#[compute]
#version 450
// OWNS:       Transmittance LUT: atmosphere transmittance from any height/zenith angle to space.
// DEPENDS:    params (haze), atmosphere.glslinc.
// INVARIANTS: Re-run only when haze changes (the rest of the atmosphere is fixed).
// GOTCHAS:    Rays that hit the ground are not stored; lookups below the horizon clamp to it.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

#include "params.glslinc"
layout(rgba16f, set = 0, binding = 1) uniform restrict writeonly image2D transmittance_image;

#include "atmosphere.glslinc"

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(transmittance_image);
	if (any(greaterThanEqual(pixel, size))) {
		return;
	}
	vec2 uv = (vec2(pixel) + 0.5) / vec2(size);
	float view_height;
	float view_zenith_cos;
	transmittance_uv_to_params(uv, view_height, view_zenith_cos);

	vec3 origin = vec3(0.0, view_height, 0.0);
	vec3 direction = vec3(0.0, view_zenith_cos, sqrt(max(1.0 - view_zenith_cos * view_zenith_cos, 0.0)));
	const int SAMPLE_COUNT = 40;
	float step_km = ray_sphere(origin, direction, TOP_RADIUS_KM).y / float(SAMPLE_COUNT);
	vec3 optical_depth = vec3(0.0);
	for (int i = 0; i < SAMPLE_COUNT; i++) {
		float height = length(origin + direction * (float(i) + 0.5) * step_km);
		optical_depth += sample_medium(height - GROUND_RADIUS_KM).extinction * step_km;
	}
	imageStore(transmittance_image, pixel, vec4(exp(-optical_depth), 1.0));
}
