// OWNS:       Chunk surface albedo: per voxel type texture, triplanar, blended across type borders.
// DEPENDS:    VoxelTerrain: binds type_textures (one layer per voxel_types entry). MarchingCubes
//             vertex layout: CUSTOM0 rgb = triangle corner types / 255, COLOR rgb = barycentric
//             weight.
// INVARIANTS: All three vertices of a triangle carry the same CUSTOM0, so the flat varying is the
//             triangle's types whatever the provoking vertex (D-23).
// GOTCHAS:    Textures are sampled with explicit gradients because the extra samples for mixed
//             triangles sit in a per-triangle branch, where implicit derivatives are undefined.
shader_type spatial;

uniform sampler2DArray type_textures : source_color, filter_linear_mipmap, repeat_enable;

varying vec3 world_position;
varying vec3 world_normal;
varying flat vec3 corner_layers;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = mat3(MODEL_MATRIX) * NORMAL;
	corner_layers = round(CUSTOM0.rgb * 255.0);
}

vec3 triplanar(float layer, vec3 position, vec3 dx, vec3 dy, vec3 blend) {
	return textureGrad(type_textures, vec3(position.zy, layer), dx.zy, dy.zy).rgb * blend.x
		+ textureGrad(type_textures, vec3(position.xz, layer), dx.xz, dy.xz).rgb * blend.y
		+ textureGrad(type_textures, vec3(position.xy, layer), dx.xy, dy.xy).rgb * blend.z;
}

void fragment() {
	// One texture repeat per 4 world units.
	vec3 position = world_position * 0.25;
	vec3 dx = dFdx(position);
	vec3 dy = dFdy(position);
	vec3 blend = pow(abs(normalize(world_normal)), vec3(4.0));
	blend /= blend.x + blend.y + blend.z;
	vec3 albedo = triplanar(corner_layers.x, position, dx, dy, blend);
	if (corner_layers.x != corner_layers.y || corner_layers.x != corner_layers.z) {
		albedo = albedo * COLOR.r
			+ triplanar(corner_layers.y, position, dx, dy, blend) * COLOR.g
			+ triplanar(corner_layers.z, position, dx, dy, blend) * COLOR.b;
	}
	ALBEDO = albedo;
}
