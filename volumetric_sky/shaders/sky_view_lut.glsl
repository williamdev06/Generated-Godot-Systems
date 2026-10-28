#[compute]
#version 450
// OWNS:       Sky-view LUT: atmosphere in-scattering for every direction from the camera's altitude.
// DEPENDS:    params, transmittance + multi-scattering LUTs.
// INVARIANTS: Layout matches sky_view_uv_to_direction; sky.gdshader inverts it (INV-1).
// GOTCHAS:    Excludes the sun disc; sky.gdshader adds it at full resolution.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

#include "params.glslinc"
layout(set = 0, binding = 1) uniform sampler2D transmittance_lut;
layout(set = 0, binding = 2) uniform sampler2D multi_scatter_lut;
layout(rgba16f, set = 0, binding = 3) uniform restrict writeonly image2D sky_view_image;

#include "atmosphere.glslinc"
#include "scattering.glslinc"

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(sky_view_image);
	if (any(greaterThanEqual(pixel, size))) {
		return;
	}
	vec2 uv = (vec2(pixel) + 0.5) / vec2(size);
	float view_height = GROUND_RADIUS_KM + params.camera_position.w;
	vec3 direction = sky_view_uv_to_direction(uv, view_height);
	ScatteringResult result = integrate_scattering(vec3(0.0, view_height, 0.0), direction, params.sun_direction.xyz, params.sun_illuminance.rgb, 30, 1e9);
	imageStore(sky_view_image, pixel, vec4(result.luminance, 1.0));
}
