#[compute]
#version 450
// OWNS:       Full-res composite: aerial perspective on geometry, then upsampled clouds over the scene.
// DEPENDS:    params, scene color + depth, aerial perspective volume, accumulated cloud history.
// INVARIANTS: Sky pixels (depth 0) skip aerial perspective (sky.gdshader already includes it) and get
//             only the cloud-shadow loss subtracted.
// GOTCHAS:    Runs before transparents (D-3), so transparent objects draw over clouds unfogged.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

#include "params.glslinc"
layout(rgba16f, set = 0, binding = 1) uniform image2D color_image;
layout(set = 0, binding = 2) uniform sampler2D depth_texture;
layout(set = 0, binding = 3) uniform sampler3D aerial_perspective;
layout(set = 0, binding = 4) uniform sampler2D cloud_texture;
layout(set = 0, binding = 5) uniform sampler2D sky_shadow_loss;

#include "atmosphere.glslinc"

// Joint bilateral upsample: bilinear weights, suppressed for half-res texels whose scene depth differs
// from this pixel's, so clouds traced past an edge don't bleed onto the geometry in front of it.
vec4 upsample_clouds(vec2 uv, float pixel_distance_km) {
	ivec2 cloud_size = ivec2(params.render_size.xy);
	vec2 texel_position = uv * params.render_size.xy - 0.5;
	ivec2 base_texel = ivec2(floor(texel_position));
	vec2 fraction = texel_position - vec2(base_texel);
	vec4 weighted_sum = vec4(0.0);
	float total_weight = 0.0;
	vec4 closest_depth_clouds = vec4(0.0, 0.0, 0.0, 1.0);
	float closest_depth_difference = 1e9;
	for (int y = 0; y <= 1; y++) {
		for (int x = 0; x <= 1; x++) {
			ivec2 texel = clamp(base_texel + ivec2(x, y), ivec2(0), cloud_size - 1);
			vec4 clouds = texelFetch(cloud_texture, texel, 0);
			float texel_distance_km = scene_distance_km(depth_texture, cloud_texel_full_pixel(texel));
			float relative_difference = abs(texel_distance_km - pixel_distance_km) / max(texel_distance_km, pixel_distance_km);
			float bilinear_weight = (x == 0 ? 1.0 - fraction.x : fraction.x) * (y == 0 ? 1.0 - fraction.y : fraction.y);
			// A 5% depth mismatch drops the weight to 1/e.
			float weight = bilinear_weight * exp(-relative_difference * 20.0);
			weighted_sum += clouds * weight;
			total_weight += weight;
			if (relative_difference < closest_depth_difference) {
				closest_depth_difference = relative_difference;
				closest_depth_clouds = clouds;
			}
		}
	}
	// Geometry thinner than a half-res texel matches no neighbor well: take the closest depth.
	return total_weight > 1e-4 ? weighted_sum / total_weight : closest_depth_clouds;
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.render_size.zw);
	if (any(greaterThanEqual(pixel, size))) {
		return;
	}
	vec2 uv = (vec2(pixel) + 0.5) / vec2(size);
	vec4 color = imageLoad(color_image, pixel);
	float distance_km = scene_distance_km(depth_texture, pixel);
	if (distance_km < SKY_DISTANCE_KM) {
		vec4 aerial = sample_aerial_perspective(aerial_perspective, uv, distance_km);
		color.rgb = color.rgb * aerial.a + aerial.rgb;
	} else {
		// The sky shader's background has no cloud shadows or shaft_intensity boost; apply both
		// (crepuscular rays). The correction is negative where the boost wins.
		color.rgb = max(color.rgb - textureLod(sky_shadow_loss, uv, 0.0).rgb, vec3(0.0));
	}
	vec4 clouds = upsample_clouds(uv, distance_km);
	color.rgb = color.rgb * clouds.a + clouds.rgb;
	imageStore(color_image, pixel, color);
}
