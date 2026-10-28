#[compute]
#version 450
// OWNS:       Temporal reconstruction of the cloud image (reprojection + neighborhood clamp), including
//             filling the pixels the checkerboarded raymarch did not trace this frame.
// DEPENDS:    params (previous_view_projection, frame.z history flag, checkerboard), clouds_raymarch outputs.
// INVARIANTS: history_texture and history_image are different textures (ping-pong in the effect).
//             cloud_image / cloud_distance_image hold one texel per checkerboard block.
// GOTCHAS:    Reprojects with the cloud's weighted depth, so thin layers at different depths can ghost
//             until the clamp catches them. Untraced pixels are pure reprojected history, so fast camera
//             motion shows more ghosting than with checkerboarding off.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

#include "params.glslinc"
layout(rgba16f, set = 0, binding = 1) uniform restrict readonly image2D cloud_image;
layout(r32f, set = 0, binding = 2) uniform restrict readonly image2D cloud_distance_image;
layout(set = 0, binding = 3) uniform sampler2D history_texture;
layout(rgba16f, set = 0, binding = 4) uniform restrict writeonly image2D history_image;

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.render_size.xy);
	if (any(greaterThanEqual(pixel, size))) {
		return;
	}
	int block_size = int(params.cloud_settings.w);
	ivec2 traced_size = imageSize(cloud_image);
	ivec2 block = min(pixel / block_size, traced_size - 1);
	bool traced_this_frame = all(equal(pixel % block_size, checkerboard_offset()));

	// The block's fresh sample: this pixel's own if traced, otherwise a neighbor's from this frame.
	vec4 current = imageLoad(cloud_image, block);
	vec4 neighborhood_min = current;
	vec4 neighborhood_max = current;
	for (int x = -1; x <= 1; x++) {
		for (int y = -1; y <= 1; y++) {
			vec4 neighbor = imageLoad(cloud_image, clamp(block + ivec2(x, y), ivec2(0), traced_size - 1));
			neighborhood_min = min(neighborhood_min, neighbor);
			neighborhood_max = max(neighborhood_max, neighbor);
		}
	}

	vec2 uv = (vec2(pixel) + 0.5) / vec2(size);
	float distance_km = imageLoad(cloud_distance_image, block).r;
	vec3 world = params.camera_position.xyz + view_direction(uv) * distance_km * 1000.0;
	vec4 previous_clip = params.previous_view_projection * vec4(world, 1.0);
	vec2 previous_ndc = previous_clip.xy / previous_clip.w;
	vec2 previous_uv = previous_ndc * 0.5 + 0.5;

	vec4 result = current;
	bool on_screen = previous_clip.w > 0.0 && all(greaterThanEqual(previous_uv, vec2(0.0))) && all(lessThanEqual(previous_uv, vec2(1.0)));
	if (params.frame.z > 0.5 && on_screen) {
		vec4 history = clamp(textureLod(history_texture, previous_uv, 0.0), neighborhood_min, neighborhood_max);
		// cloud_temporal_amount is the history share per frame. A traced pixel gets a fresh sample only
		// every block_size^2 frames, so it takes that many frames' worth of the current weight at once,
		// keeping convergence speed the same as with checkerboarding off.
		float history_share = pow(params.cloud_quality.z, float(block_size * block_size));
		result = traced_this_frame ? mix(current, history, history_share) : history;
	}
	imageStore(history_image, pixel, result);
}
