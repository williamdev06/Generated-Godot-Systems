#[compute]
#version 450
// OWNS:       Sun-aligned Beer shadow map (Hillaire 2016): per texel, the front depth of the clouds along
//             the light, their mean extinction, and the total optical depth.
// DEPENDS:    params (beer_shadow_* frame, sun, wind), cloud noise, weather map.
// INVARIANTS: Depth t is measured along the light (-sun) from the map plane through beer_shadow_center;
//             beer_shadow_transmittance() in aerial_perspective.glsl inverts this (INV-6).
// GOTCHAS:    Flat cloud space (no curvature). transmittance_lut / sky_view_lut are declared only because
//             clouds.glslinc references them.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

#include "params.glslinc"
layout(set = 0, binding = 1) uniform sampler2D transmittance_lut;
layout(set = 0, binding = 3) uniform sampler2D sky_view_lut;
layout(set = 0, binding = 4) uniform sampler3D shape_noise;
layout(set = 0, binding = 5) uniform sampler3D detail_noise;
layout(set = 0, binding = 6) uniform sampler2D weather_map;
layout(set = 0, binding = 11) uniform sampler2D procedural_weather;
layout(rgba16f, set = 0, binding = 7) uniform restrict writeonly image2D beer_shadow_image;

#include "atmosphere.glslinc"
#include "clouds.glslinc"

const int STEP_COUNT = 32;
// Caps the slant path through the layer at low sun.
const float MAX_PATH_KM = 30.0;

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(beer_shadow_image);
	if (any(greaterThanEqual(pixel, size))) {
		return;
	}
	vec3 sun_direction = params.sun_direction.xyz;
	if (sun_direction.y <= 0.0) {
		imageStore(beer_shadow_image, pixel, vec4(0.0));
		return;
	}
	vec2 uv = (vec2(pixel) + 0.5) / vec2(size);
	vec2 offset_km = (uv - 0.5) * params.beer_shadow_tangent.w;
	vec3 origin = params.beer_shadow_center.xyz + params.beer_shadow_tangent.xyz * offset_km.x + params.beer_shadow_bitangent.xyz * offset_km.y;
	// Moving t km along the light lowers altitude by sun_direction.y * t.
	float start_t = (origin.y - CLOUD_TOP_KM) / sun_direction.y;
	float end_t = min((origin.y - CLOUD_BOTTOM_KM) / sun_direction.y, start_t + MAX_PATH_KM);
	float step_km = (end_t - start_t) / float(STEP_COUNT);
	vec3 wind_offset = vec3(params.wind.x, 0.0, params.wind.y) * params.frame.x;

	float front_t = end_t;
	float back_t = start_t;
	float optical_depth = 0.0;
	for (int i = 0; i < STEP_COUNT; i++) {
		float t = start_t + (float(i) + 0.5) * step_km;
		vec3 position = origin - sun_direction * t;
		float height_fraction = (position.y - CLOUD_BOTTOM_KM) / (CLOUD_TOP_KM - CLOUD_BOTTOM_KM);
		vec3 noise_position = position + wind_offset;
		float extinction = cloud_extinction(noise_position, height_fraction, sample_weather(noise_position.xz), false);
		if (extinction > 0.0) {
			front_t = min(front_t, t - 0.5 * step_km);
			back_t = t + 0.5 * step_km;
			optical_depth += extinction * step_km;
		}
	}
	// Cloudless texels keep a front depth at the layer entry (not a far sentinel) with zero optical
	// depth: bilinear filtering then blends them smoothly with cloudy neighbors instead of letting
	// a huge front depth light up whole texels.
	if (optical_depth <= 0.0) {
		front_t = start_t;
	}
	float mean_extinction = optical_depth > 0.0 ? optical_depth / (back_t - front_t) : 0.0;
	imageStore(beer_shadow_image, pixel, vec4(front_t, mean_extinction, optical_depth, 0.0));
}
