#[compute]
#version 450
// OWNS:       Cloud raymarch for the current frame, with aerial perspective applied. With checkerboarding,
//             one thread per block traces only that block's checkerboard_offset() pixel.
// DEPENDS:    params, LUTs, cloud noise, weather map, aerial perspective volume, scene depth.
// INVARIANTS: cloud_image = (luminance, transmittance); cloud_distance_image = km, used for reprojection.
//             Both are sized cloud resolution / checkerboard block size (one texel per block).
// GOTCHAS:    Each traced cloud pixel is bounded by the depth of one full-res pixel (cloud_texel_full_pixel);
//             the composite relies on that same pixel for its depth-aware upsample.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

#include "params.glslinc"
layout(set = 0, binding = 1) uniform sampler2D transmittance_lut;
layout(set = 0, binding = 3) uniform sampler2D sky_view_lut;
layout(set = 0, binding = 4) uniform sampler3D shape_noise;
layout(set = 0, binding = 5) uniform sampler3D detail_noise;
layout(set = 0, binding = 6) uniform sampler2D weather_map;
layout(set = 0, binding = 11) uniform sampler2D procedural_weather;
layout(set = 0, binding = 7) uniform sampler3D aerial_perspective;
layout(set = 0, binding = 8) uniform sampler2D depth_texture;
layout(rgba16f, set = 0, binding = 9) uniform restrict writeonly image2D cloud_image;
layout(r32f, set = 0, binding = 10) uniform restrict writeonly image2D cloud_distance_image;

#include "atmosphere.glslinc"
#include "clouds.glslinc"

// Jimenez 2014. Varies per frame so the temporal pass integrates different ray offsets.
float interleaved_gradient_noise(vec2 pixel) {
	return fract(52.9829189 * fract(dot(pixel, vec2(0.06711056, 0.00583715))));
}

void main() {
	ivec2 block = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(block, imageSize(cloud_image)))) {
		return;
	}
	ivec2 size = ivec2(params.render_size.xy);
	ivec2 pixel = min(block * int(params.cloud_settings.w) + checkerboard_offset(), size - 1);
	vec2 uv = (vec2(pixel) + 0.5) / vec2(size);
	float jitter = interleaved_gradient_noise(vec2(pixel) + 5.588238 * params.frame.y);
	float max_distance_km = scene_distance_km(depth_texture, cloud_texel_full_pixel(pixel));
	CloudSample clouds = march_clouds(view_direction(uv), max_distance_km, jitter, int(params.cloud_quality.x), int(params.cloud_quality.y), true);

	// Atmosphere in front of the cloud: the sky behind it already carries its own in-scattering.
	vec4 aerial = sample_aerial_perspective(aerial_perspective, uv, clouds.distance_km);
	vec3 luminance = clouds.luminance * aerial.a + aerial.rgb * (1.0 - clouds.transmittance);
	imageStore(cloud_image, block, vec4(luminance, clouds.transmittance));
	imageStore(cloud_distance_image, block, vec4(clouds.distance_km));
}
