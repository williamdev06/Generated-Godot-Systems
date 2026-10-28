#[compute]
#version 450
// OWNS:       Low-res equirectangular cloud panorama for the sky's radiance cubemap (D-1).
// DEPENDS:    params, LUTs, cloud noise, weather map.
// INVARIANTS: u = azimuth, v = zenith angle / PI; sky.gdshader samples with the inverse (INV-1).
//             Output = (luminance incl. atmosphere in front, cloud transmittance).
// GOTCHAS:    Aerial perspective is integrated inline: the screen-aligned froxel volume can't cover
//             all directions. No detail noise or jitter; ambient lighting doesn't need them.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

#include "params.glslinc"
layout(set = 0, binding = 1) uniform sampler2D transmittance_lut;
layout(set = 0, binding = 2) uniform sampler2D multi_scatter_lut;
layout(set = 0, binding = 3) uniform sampler2D sky_view_lut;
layout(set = 0, binding = 4) uniform sampler3D shape_noise;
layout(set = 0, binding = 5) uniform sampler3D detail_noise;
layout(set = 0, binding = 6) uniform sampler2D weather_map;
layout(set = 0, binding = 11) uniform sampler2D procedural_weather;
layout(rgba16f, set = 0, binding = 7) uniform restrict writeonly image2D cloud_panorama_image;

#include "atmosphere.glslinc"
#include "scattering.glslinc"
#include "clouds.glslinc"

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(cloud_panorama_image);
	if (any(greaterThanEqual(pixel, size))) {
		return;
	}
	vec2 uv = (vec2(pixel) + 0.5) / vec2(size);
	float zenith = uv.y * PI;
	float azimuth = (uv.x - 0.5) * 2.0 * PI;
	vec3 direction = vec3(sin(zenith) * cos(azimuth), cos(zenith), sin(zenith) * sin(azimuth));

	CloudSample clouds = march_clouds(direction, CLOUD_MAX_DISTANCE_KM, 0.5, 24, 3, false);
	vec3 origin = vec3(0.0, GROUND_RADIUS_KM + params.camera_position.w, 0.0);
	ScatteringResult atmosphere = integrate_scattering(origin, direction, params.sun_direction.xyz, params.sun_illuminance.rgb, 8, clouds.distance_km);
	vec3 luminance = clouds.luminance * atmosphere.transmittance + atmosphere.luminance * (1.0 - clouds.transmittance);
	imageStore(cloud_panorama_image, pixel, vec4(luminance, clouds.transmittance));
}
