#[compute]
#version 450
// OWNS:       Temporal accumulation of the jittered aerial perspective volume and sky shadow loss
//             (same idea as Godot's volumetric fog temporal reprojection).
// DEPENDS:    params (previous_view_projection, previous_camera_position, atmosphere_settings.z),
//             raw outputs of aerial_perspective.glsl, last frame's accumulated textures.
// INVARIANTS: History textures differ from the ones written here (ping-pong in the effect). Texel z is
//             the froxel center, matching sample_aerial_perspective.
// GOTCHAS:    No neighborhood clamp, like Godot's fog: fast camera moves or fast cloud shadows ghost for
//             roughly 1 / (1 - amount) frames.

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

#include "params.glslinc"
layout(rgba16f, set = 0, binding = 1) uniform restrict readonly image3D current_aerial_perspective;
layout(set = 0, binding = 2) uniform sampler3D history_aerial_perspective;
layout(rgba16f, set = 0, binding = 3) uniform restrict writeonly image3D accumulated_aerial_perspective;
layout(rgba16f, set = 0, binding = 4) uniform restrict readonly image2D current_sky_shadow_loss;
layout(set = 0, binding = 5) uniform sampler2D history_sky_shadow_loss;
layout(rgba16f, set = 0, binding = 6) uniform restrict writeonly image2D accumulated_sky_shadow_loss;

#include "atmosphere.glslinc"

// Where a world position was on screen last frame; xy uv, z clip w (<= 0 behind the camera).
vec3 previous_screen_position(vec3 world) {
	vec4 clip = params.previous_view_projection * vec4(world, 1.0);
	return vec3(clip.xy / clip.w * 0.5 + 0.5, clip.w);
}

bool inside_unit(vec2 uv) {
	return all(greaterThanEqual(uv, vec2(0.0))) && all(lessThanEqual(uv, vec2(1.0)));
}

void main() {
	ivec3 cell = ivec3(gl_GlobalInvocationID.xyz);
	ivec3 size = imageSize(current_aerial_perspective);
	if (any(greaterThanEqual(cell, size))) {
		return;
	}
	float amount = params.atmosphere_settings.z;
	bool history_valid = params.previous_camera_position.w > 0.5 && amount > 0.0;
	vec2 uv = (vec2(cell.xy) + 0.5) / vec2(size.xy);
	vec3 direction = view_direction(uv);

	vec4 result = imageLoad(current_aerial_perspective, cell);
	if (history_valid) {
		float slice_position = (float(cell.z) + 0.5) / float(size.z);
		vec3 world = params.camera_position.xyz + direction * slice_position * slice_position * AERIAL_PERSPECTIVE_MAX_KM * 1000.0;
		vec3 previous = previous_screen_position(world);
		float previous_slice = sqrt(length(world - params.previous_camera_position.xyz) * 0.001 / AERIAL_PERSPECTIVE_MAX_KM);
		if (previous.z > 0.0 && inside_unit(previous.xy) && previous_slice <= 1.0) {
			vec4 history = textureLod(history_aerial_perspective, vec3(previous.xy, previous_slice), 0.0);
			result = mix(result, history, amount);
		}
	}
	imageStore(accumulated_aerial_perspective, cell, result);

	if (cell.z != size.z - 1) {
		return;
	}
	vec4 loss = imageLoad(current_sky_shadow_loss, cell.xy);
	if (history_valid) {
		// The loss belongs to the sky behind everything: reproject by direction (a far point).
		vec3 previous = previous_screen_position(params.camera_position.xyz + direction * AERIAL_PERSPECTIVE_MAX_KM * 1000.0);
		if (previous.z > 0.0 && inside_unit(previous.xy)) {
			loss = mix(loss, textureLod(history_sky_shadow_loss, previous.xy, 0.0), amount);
		}
	}
	imageStore(accumulated_sky_shadow_loss, cell.xy, loss);
}
