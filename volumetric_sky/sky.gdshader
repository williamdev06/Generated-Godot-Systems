// OWNS:       Sky background + radiance cubemap, sampled from VolumetricSkyEffect's compute LUTs (D-1).
// DEPENDS:    VolumetricSky: binds sky_view_lut / cloud_panorama, sets camera_altitude_km and bumps
//             refresh_index every VolumetricSkyEffect.sky_update_interval frames.
// INVARIANTS: Radii and LUT mappings duplicate shaders/atmosphere.glslinc (INV-1).
// GOTCHAS:    The on-screen background has no clouds: the compositor pass draws them over it. Only the
//             cubemap pass adds the low-res cloud panorama. The LUTs lag the camera by one frame.
//             LIGHT0_COLOR is already the atmosphere transmittance (VolumetricSky sets it), so the sun
//             disc must not apply transmittance again.
//             Godot re-renders the radiance cubemap only when it sees the sky change (light moved, a
//             uniform changed, TIME/POSITION used) and can't see LUT contents change. So this shader
//             avoids TIME/POSITION (which would force a re-render every frame or on every camera move)
//             and VolumetricSky changes refresh_index to request one at a throttled rate.
shader_type sky;

uniform sampler2D sky_view_lut : filter_linear, repeat_disable;
uniform sampler2D cloud_panorama : filter_linear, repeat_disable;
uniform float camera_altitude_km = 0.0005;
// Only its changes matter: each new value marks the sky dirty.
uniform float refresh_index = 0.0;

const float GROUND_RADIUS_KM = 6360.0;
const float TOP_RADIUS_KM = 6460.0;
// Visual, not physical: a true disc would be ~15000x the illuminance and swamp the tonemapper.
uniform float sun_disc_brightness : hint_range(0.0, 500.0) = 30.0;

// Inverse of sky_view_uv_to_direction in atmosphere.glslinc.
vec2 sky_view_uv(vec3 direction, float view_height) {
	float horizon_distance = sqrt(max(view_height * view_height - GROUND_RADIUS_KM * GROUND_RADIUS_KM, 0.0));
	float beta = acos(horizon_distance / view_height);
	float zenith_horizon_angle = PI - beta;
	float view_zenith_angle = acos(clamp(direction.y, -1.0, 1.0));
	float v;
	if (view_zenith_angle < zenith_horizon_angle) {
		v = (1.0 - sqrt(1.0 - view_zenith_angle / zenith_horizon_angle)) * 0.5;
	} else {
		v = sqrt((view_zenith_angle - zenith_horizon_angle) / beta) * 0.5 + 0.5;
	}
	return vec2(atan(direction.z, direction.x) / TAU + 0.5, v);
}

void sky() {
	float view_height = GROUND_RADIUS_KM + camera_altitude_km;
	vec3 color = texture(sky_view_lut, sky_view_uv(EYEDIR, view_height)).rgb;
	if (AT_CUBEMAP_PASS) {
		vec2 panorama_uv = vec2(atan(EYEDIR.z, EYEDIR.x) / TAU + 0.5, acos(clamp(EYEDIR.y, -1.0, 1.0)) / PI);
		vec4 clouds = texture(cloud_panorama, panorama_uv);
		color = color * clouds.a + clouds.rgb;
	} else if (LIGHT0_ENABLED) {
		float horizon_cos = -sqrt(max(1.0 - (GROUND_RADIUS_KM * GROUND_RADIUS_KM) / (view_height * view_height), 0.0));
		float sun_radius = LIGHT0_SIZE * 0.5;
		float sun_angle = acos(clamp(dot(EYEDIR, LIGHT0_DIRECTION), -1.0, 1.0));
		if (sun_angle < sun_radius && EYEDIR.y > horizon_cos) {
			float limb_darkening = sqrt(max(1.0 - pow(sun_angle / sun_radius, 2.0), 0.0));
			color += LIGHT0_COLOR * LIGHT0_ENERGY * PI * sun_disc_brightness * limb_darkening;
		}
	}
	// Referenced so refresh_index stays a live uniform (see GOTCHAS).
	COLOR = color + refresh_index * 0.0;
}
