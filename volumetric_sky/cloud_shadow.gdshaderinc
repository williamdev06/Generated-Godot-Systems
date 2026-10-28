// OWNS:       Cloud shadow and cloud sky-light occlusion (AO) for spatial materials, plus a drop-in
//             light() that applies the shadow.
// DEPENDS:    Shader globals cloud_shadow_map / cloud_shadow_area / cloud_shadow_sun and beer_shadow_map /
//             beer_shadow_center / beer_shadow_tangent / beer_shadow_bitangent, registered in project.godot
//             [shader_globals] and written every frame by VolumetricSky(Effect).
// INVARIANTS: cloud_shadow_sun.w carries the cloud layer top (m) from the effect. cloud_ambient_occlusion()
//             inverts the uv mapping of shaders/cloud_shadow_map.glsl (INV-5); cloud_shadow() inverts
//             shaders/beer_shadow_map.glsl, same as aerial_perspective.glsl (INV-6).
// GOTCHAS:    Usage, in any spatial shader:
//               #include "res://volumetric_sky/cloud_shadow.gdshaderinc"
//               void fragment() { ...; CLOUD_SHADOW_FRAGMENT; }
//             light() has no VERTEX, so the shadow is computed in fragment() and passed via a varying;
//             without CLOUD_SHADOW_FRAGMENT the sun term is undefined. The macro also writes AO, so put
//             any AO of your own after it (see cloud_occlusion below).
//             Defining light() replaces ALL of Godot's built-in lighting, so this file supplies one
//             (Lambert diffuse + GGX specular, cloud-shadowed for directional lights). To keep your own
//             light(), put `#define CLOUD_SHADOW_CUSTOM_LIGHT` before the include and multiply your sun
//             term by cloud_shadow_factor.
//             Sun shadows come from the sun-aligned Beer shadow map, so receivers inside the cloud layer
//             get partial shadow and receivers above it none; coverage is the effect's shaft_distance_km
//             around the camera, fading to unshadowed at the edge. AO uses the top-down map
//             (cloud_ao_map_size_km) and treats receivers inside the layer as on the ground below.

global uniform sampler2D cloud_shadow_map; // r = sky visibility through clouds (cloud AO)
global uniform vec4 cloud_shadow_area; // xy AO map center (world x/z m), z map size m, w cloud AO strength
global uniform vec4 cloud_shadow_sun;  // xyz unit vector toward the sun, w cloud layer top m
global uniform sampler2D beer_shadow_map; // x front depth km, y mean extinction per km, z optical depth
// Beer shadow map frame in cloud space (km: world x, altitude, world z).
global uniform vec4 beer_shadow_center;    // xyz map center
global uniform vec4 beer_shadow_tangent;   // xyz map u axis, w map extent km
global uniform vec4 beer_shadow_bitangent; // xyz map v axis

#define CLOUD_SHADOW_TOP_M cloud_shadow_sun.w

// Fades to "no clouds" at the map border instead of clamping to edge texels.
float cloud_map_edge_fade(vec2 uv) {
	return 1.0 - smoothstep(0.45, 0.5, max(abs(uv.x - 0.5), abs(uv.y - 0.5)));
}

// Fraction of direct sunlight reaching world_position through the clouds (1 = unshadowed).
float cloud_shadow(vec3 world_position) {
	if (cloud_shadow_sun.y <= 0.0) {
		return 1.0;
	}
	vec3 relative = world_position * 0.001 - beer_shadow_center.xyz;
	vec2 uv = vec2(dot(relative, beer_shadow_tangent.xyz), dot(relative, beer_shadow_bitangent.xyz)) / beer_shadow_tangent.w + 0.5;
	// Depth along the light from the map plane; the plane offset is perpendicular to the sun.
	float depth = dot(-relative, cloud_shadow_sun.xyz);
	vec3 beer_shadow = textureLod(beer_shadow_map, uv, 0.0).xyz;
	float transmittance = exp(-min(beer_shadow.z, beer_shadow.y * max(depth - beer_shadow.x, 0.0)));
	return mix(1.0, transmittance, cloud_map_edge_fade(uv));
}

// Sky-light occlusion by clouds at world_position, for AO (1 = unoccluded). Absolute (depends only on
// the receiver's own sky visibility, never on the camera), scaled by cloud_ao_strength (D-15).
float cloud_ambient_occlusion(vec3 world_position) {
	if (world_position.y > CLOUD_SHADOW_TOP_M) {
		return 1.0;
	}
	vec2 uv = (world_position.xz - cloud_shadow_area.xy) / cloud_shadow_area.z + 0.5;
	float visibility = textureLod(cloud_shadow_map, uv, 0.0).r;
	return mix(1.0, visibility, cloud_shadow_area.w * cloud_map_edge_fade(uv));
}

varying float cloud_shadow_factor;
// Declares cloud_occlusion; a material with its own AO writes `AO = own_ao * cloud_occlusion;` after this.
#define CLOUD_SHADOW_FRAGMENT vec3 cloud_world_position = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz; cloud_shadow_factor = cloud_shadow(cloud_world_position); float cloud_occlusion = cloud_ambient_occlusion(cloud_world_position); AO = cloud_occlusion

#ifndef CLOUD_SHADOW_CUSTOM_LIGHT
void light() {
	float shadow = LIGHT_IS_DIRECTIONAL ? cloud_shadow_factor : 1.0;
	float n_dot_l = clamp(dot(NORMAL, LIGHT), 0.0, 1.0);
	// LIGHT_COLOR already carries Godot's x PI, so Lambert divides it back out.
	vec3 irradiance = LIGHT_COLOR * ATTENUATION * shadow * n_dot_l;
	DIFFUSE_LIGHT += irradiance / PI;

	vec3 half_vector = normalize(VIEW + LIGHT);
	float n_dot_v = clamp(dot(NORMAL, VIEW), 1e-4, 1.0);
	float n_dot_h = clamp(dot(NORMAL, half_vector), 0.0, 1.0);
	float l_dot_h = clamp(dot(LIGHT, half_vector), 0.0, 1.0);
	float alpha = ROUGHNESS * ROUGHNESS;
	float alpha_squared = alpha * alpha;
	float distribution_denominator = n_dot_h * n_dot_h * (alpha_squared - 1.0) + 1.0;
	float distribution = alpha_squared / (PI * distribution_denominator * distribution_denominator);
	// Height-correlated Smith visibility (Heitz 2014).
	float visibility = 0.5 / max(n_dot_l * sqrt(n_dot_v * n_dot_v * (1.0 - alpha_squared) + alpha_squared) + n_dot_v * sqrt(n_dot_l * n_dot_l * (1.0 - alpha_squared) + alpha_squared), 1e-5);
	vec3 f0 = mix(vec3(0.04), ALBEDO, METALLIC);
	vec3 fresnel = f0 + (1.0 - f0) * pow(1.0 - l_dot_h, 5.0);
	SPECULAR_LIGHT += irradiance * distribution * visibility * fresnel * SPECULAR_AMOUNT;
}
#endif
