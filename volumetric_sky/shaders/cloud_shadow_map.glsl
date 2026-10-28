#[compute]
#version 450
// OWNS:       Top-down cloud AO map for a square of world x/z centered near the camera:
//             r = fraction of the sky visible through clouds from the ground below. (Sun shadows come
//             from beer_shadow_map.glsl.)
// DEPENDS:    params (cloud_shadow_area, wind), cloud noise, weather map.
// INVARIANTS: uv -> world mapping is inverted by cloud_ambient_occlusion() in cloud_shadow.gdshaderinc (INV-5).
// GOTCHAS:    Flat-plane approximation: curvature over the map's width is a few tens of meters.
//             transmittance_lut / sky_view_lut are declared only because clouds.glslinc references them.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

#include "params.glslinc"
layout(set = 0, binding = 1) uniform sampler2D transmittance_lut;
layout(set = 0, binding = 3) uniform sampler2D sky_view_lut;
layout(set = 0, binding = 4) uniform sampler3D shape_noise;
layout(set = 0, binding = 5) uniform sampler3D detail_noise;
layout(set = 0, binding = 6) uniform sampler2D weather_map;
layout(set = 0, binding = 11) uniform sampler2D procedural_weather;
layout(r16f, set = 0, binding = 7) uniform restrict writeonly image2D cloud_shadow_image;

#include "atmosphere.glslinc"
#include "clouds.glslinc"

// Caps the slant path of near-horizontal rays.
const float MAX_PATH_KM = 20.0;

// Transmittance through the cloud layer along `direction` (y > 0), entering at the cloud base at base_xz_km.
float layer_transmittance(vec2 base_xz_km, vec3 direction, vec3 wind_offset, int step_count) {
	float path_km = min((CLOUD_TOP_KM - CLOUD_BOTTOM_KM) / direction.y, MAX_PATH_KM);
	float step_km = path_km / float(step_count);
	float optical_depth = 0.0;
	for (int i = 0; i < step_count; i++) {
		float distance_km = (float(i) + 0.5) * step_km;
		float altitude_km = CLOUD_BOTTOM_KM + direction.y * distance_km;
		float height_fraction = (altitude_km - CLOUD_BOTTOM_KM) / (CLOUD_TOP_KM - CLOUD_BOTTOM_KM);
		vec2 position_xz_km = base_xz_km + direction.xz * distance_km;
		vec3 noise_position = vec3(position_xz_km.x, altitude_km, position_xz_km.y) + wind_offset;
		optical_depth += cloud_extinction(noise_position, height_fraction, sample_weather(noise_position.xz), false) * step_km;
	}
	return exp(-optical_depth);
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(cloud_shadow_image);
	if (any(greaterThanEqual(pixel, size))) {
		return;
	}
	vec2 uv = (vec2(pixel) + 0.5) / vec2(size);
	vec2 base_xz_km = (params.cloud_shadow_area.xy + (uv - 0.5) * params.cloud_shadow_area.z) * 0.001;
	vec3 wind_offset = vec3(params.wind.x, 0.0, params.wind.y) * params.frame.x;

	// Sky visibility for a ground receiver below this texel: zenith plus a ring at 45 degrees, an
	// equal-weight approximation of the cosine-weighted hemisphere. Ring rays leave the ground here and
	// reach the cloud base CLOUD_BOTTOM_KM further out, which spreads occlusion past cloud edges.
	float sky_visibility = layer_transmittance(base_xz_km, vec3(0.0, 1.0, 0.0), wind_offset, 8);
	for (int i = 0; i < 6; i++) {
		float azimuth = float(i) * PI / 3.0;
		vec3 direction = normalize(vec3(cos(azimuth), 1.0, sin(azimuth)));
		vec2 entry_xz_km = base_xz_km + direction.xz * (CLOUD_BOTTOM_KM / direction.y);
		sky_visibility += layer_transmittance(entry_xz_km, direction, wind_offset, 8);
	}
	imageStore(cloud_shadow_image, pixel, vec4(sky_visibility / 7.0));
}
