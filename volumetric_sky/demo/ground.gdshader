// OWNS:       Demo ground material; reference usage of cloud_shadow.gdshaderinc.
// DEPENDS:    volumetric_sky/cloud_shadow.gdshaderinc.
// INVARIANTS: None.
// GOTCHAS:    None.
shader_type spatial;

#include "res://volumetric_sky/cloud_shadow.gdshaderinc"

uniform vec3 albedo : source_color = vec3(0.25, 0.3, 0.2);

void fragment() {
	ALBEDO = albedo;
	CLOUD_SHADOW_FRAGMENT;
}
