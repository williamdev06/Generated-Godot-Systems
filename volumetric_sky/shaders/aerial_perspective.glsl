#[compute]
#version 450
// OWNS:       Camera-aligned aerial perspective froxel volume (in-scattering + transmittance), with cloud
//             shadows from the Beer shadow map, which produces crepuscular rays. Also writes, per screen
//             column, the sky background correction: cloud-shadow loss minus the shaft_intensity boost.
// DEPENDS:    params, transmittance + multi-scattering LUTs, Beer shadow map.
// INVARIANTS: Slice distribution is inverted by sample_aerial_perspective in atmosphere.glslinc.
//             beer_shadow_transmittance() inverts the mapping of beer_shadow_map.glsl (INV-6).
// GOTCHAS:    One thread per froxel column marches the view ray once, writing each slice as it passes
//             (SAMPLES_PER_SLICE samples per slice segment), so cost is linear in slices. Shafts are as
//             sharp as the froxel grid (shaft_froxel_size_px / shaft_depth_slices on the effect) and
//             beyond the Beer shadow map's extent the atmosphere is unshadowed.
//             With temporal amount > 0, each frame jitters the column's position inside its froxels and
//             the sample offset along the ray; output is raw and only usable after
//             aerial_perspective_temporal.glsl accumulates it. A texel represents its froxel center.

#define CLOUD_SHADOWED_SCATTERING
// shaft_intensity: boosts lit aerosol (Mie) single scattering inside this volume only.
#define MIE_SINGLE_SCATTERING_SCALE params.atmosphere_settings.w
// Global, set per thread in main() before integrating.
float scattering_sample_offset;
#define SCATTERING_SAMPLE_OFFSET scattering_sample_offset

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

#include "params.glslinc"
layout(set = 0, binding = 1) uniform sampler2D transmittance_lut;
layout(set = 0, binding = 2) uniform sampler2D multi_scatter_lut;
layout(rgba16f, set = 0, binding = 3) uniform restrict writeonly image3D aerial_perspective_image;
layout(set = 0, binding = 4) uniform sampler2D beer_shadow_map;
layout(rgba16f, set = 0, binding = 5) uniform restrict writeonly image2D sky_shadow_loss_image;

#include "atmosphere.glslinc"

// Cloud transmittance toward the sun at a planet-centric position (camera at x = z = 0).
float cloud_shadow_transmittance(vec3 planet_position) {
	vec3 cloud_space = vec3(params.camera_position.x * 0.001 + planet_position.x, length(planet_position) - GROUND_RADIUS_KM, params.camera_position.z * 0.001 + planet_position.z);
	vec3 relative = cloud_space - params.beer_shadow_center.xyz;
	vec2 uv = vec2(dot(relative, params.beer_shadow_tangent.xyz), dot(relative, params.beer_shadow_bitangent.xyz)) / params.beer_shadow_tangent.w + 0.5;
	if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) {
		return 1.0;
	}
	// Depth along the light from the map plane; the plane offset is perpendicular to the sun.
	float depth = dot(-relative, params.sun_direction.xyz);
	vec3 beer_shadow = textureLod(beer_shadow_map, uv, 0.0).xyz;
	float transmittance = exp(-min(beer_shadow.z, beer_shadow.y * max(depth - beer_shadow.x, 0.0)));
	return mix(1.0, transmittance, params.atmosphere_settings.y);
}

#include "scattering.glslinc"

// Jimenez 2014.
float interleaved_gradient_noise(vec2 pixel) {
	return fract(52.9829189 * fract(dot(pixel, vec2(0.06711056, 0.00583715))));
}

const int SAMPLES_PER_SLICE = 2;

void main() {
	ivec2 column = ivec2(gl_GlobalInvocationID.xy);
	ivec3 size = imageSize(aerial_perspective_image);
	if (any(greaterThanEqual(column, size.xy))) {
		return;
	}
	// Positions inside the froxel, 0..1 per axis; 0.5 = center when temporal accumulation is off.
	vec3 jitter = vec3(0.5);
	scattering_sample_offset = 0.3;
	if (params.atmosphere_settings.z > 0.0) {
		float frame = params.frame.y;
		// Golden-ratio (R1/R2) sequences over frames, offset per froxel column by IGN so neighbors
		// don't jitter in lockstep.
		float column_noise = interleaved_gradient_noise(vec2(column));
		jitter.xy = fract(vec2(0.7548776662, 0.5698402910) * frame + column_noise);
		jitter.z = fract(0.6180339887 * frame + column_noise);
		scattering_sample_offset = fract(0.4142135624 * frame + interleaved_gradient_noise(vec2(column) + vec2(13.0, 7.0)));
	}
	vec2 uv = (vec2(column) + jitter.xy) / vec2(size.xy);
	vec3 direction = view_direction(uv);
	vec3 origin = vec3(0.0, GROUND_RADIUS_KM + params.camera_position.w, 0.0);
	vec3 sun_direction = params.sun_direction.xyz;
	float cos_theta = dot(direction, sun_direction);
	float mie_phase = henyey_greenstein(cos_theta, MIE_ANISOTROPY);
	float ray_phase = rayleigh_phase(cos_theta);
	vec2 extent = atmosphere_ray_extent(origin, direction);

	ScatteringResult result = empty_scattering_result();
	float segment_start_km = extent.x;
	for (int slice = 0; slice < size.z; slice++) {
		float slice_position = (float(slice) + jitter.z) / float(size.z);
		float segment_end_km = min(slice_position * slice_position * AERIAL_PERSPECTIVE_MAX_KM, extent.y);
		if (segment_end_km > segment_start_km) {
			float step_km = (segment_end_km - segment_start_km) / float(SAMPLES_PER_SLICE);
			for (int i = 0; i < SAMPLES_PER_SLICE; i++) {
				vec3 position = origin + direction * (segment_start_km + (float(i) + scattering_sample_offset) * step_km);
				accumulate_scattering_sample(result, position, step_km, sun_direction, params.sun_illuminance.rgb, mie_phase, ray_phase);
			}
			segment_start_km = segment_end_km;
		}
		imageStore(aerial_perspective_image, ivec3(column, slice), vec4(result.luminance, dot(result.transmittance, vec3(1.0 / 3.0))));
	}
	// The sky background has neither cloud shadows nor the shaft_intensity boost: store what to
	// subtract from it. Negative when the boost adds more than the shadows remove.
	vec3 boost = (MIE_SINGLE_SCATTERING_SCALE - 1.0) * result.lit_mie_scattering;
	imageStore(sky_shadow_loss_image, column, vec4(result.cloud_shadow_loss - boost, 0.0));
}
