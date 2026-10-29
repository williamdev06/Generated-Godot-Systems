// OWNS:       Chunk surface albedo: per voxel type texture, triplanar, blended across type borders.
//             Transvoxel secondary positions and transition faces of coarse LOD chunks (D-33).
// DEPENDS:    VoxelTerrain: binds type_textures (one layer per get_voxel_types() entry), sets the
//             transition_mask instance uniform. MarchingCubes vertex layout: CUSTOM0 rgb = triangle
//             corner types / 255, CUSTOM0 a = transition flags / 255, COLOR rgb = barycentric weight.
// INVARIANTS: All three vertices of a triangle carry the same CUSTOM0 rgb, so the flat varying is the
//             triangle's types whatever the provoking vertex (D-23). CHUNK_SIZE is VoxelChunk.SIZE and
//             the face bits follow MarchingCubes face order (INV-12).
// GOTCHAS:    Textures are sampled with explicit gradients because the extra samples for mixed
//             triangles sit in a per-triangle branch, where implicit derivatives are undefined.
//             VERTEX is chunk-local in cells (coarse chunks are scaled by their node). A vertex on a
//             face without a finer neighbour never moves, so it keeps matching that neighbour; this
//             also holds for transition vertices, which must land exactly where the regular ones do.
shader_type spatial;

uniform sampler2DArray type_textures : source_color, filter_linear_mipmap, repeat_enable;
// Bit face (MarchingCubes order: axis * 2 + side) set where the neighbour across that face is one
// LOD finer. Always 0 on LOD 0 chunks.
instance uniform int transition_mask = 0;

const float CHUNK_SIZE = 16.0;
// How far, in cells, the outer cell layer is pushed in to make room for transition cells.
const float TRANSITION_WIDTH = 0.5;

varying vec3 world_position;
varying vec3 world_normal;
varying flat vec3 corner_layers;

// Inward offset along one axis of a vertex at chunk-local p; low/high: the faces on that axis with a
// finer neighbour.
float transition_offset(float p, bool low, bool high) {
	if (low && p < 1.0) {
		return (1.0 - p) * TRANSITION_WIDTH;
	}
	if (high && p > CHUNK_SIZE - 1.0) {
		return (CHUNK_SIZE - 1.0 - p) * TRANSITION_WIDTH;
	}
	return 0.0;
}

bool on_plain_face(float p, bool low, bool high) {
	return (p <= 0.0 && !low) || (p >= CHUNK_SIZE && !high);
}

void vertex() {
	int flags = int(round(CUSTOM0.a * 255.0));
	int face = (flags & 7) - 1;
	if (face >= 0 && (transition_mask & (1 << face)) == 0) {
		// Transition cell of a face without a finer neighbour: all three corners meet, nothing draws.
		VERTEX = vec3(0.0);
	} else if (transition_mask != 0 && (flags & 8) == 0) {
		bvec3 low = bvec3((transition_mask & 1) != 0, (transition_mask & 4) != 0,
			(transition_mask & 16) != 0);
		bvec3 high = bvec3((transition_mask & 2) != 0, (transition_mask & 8) != 0,
			(transition_mask & 32) != 0);
		if (!on_plain_face(VERTEX.x, low.x, high.x) && !on_plain_face(VERTEX.y, low.y, high.y)
				&& !on_plain_face(VERTEX.z, low.z, high.z)) {
			// Lengyel's secondary position, projected onto the tangent plane so the surface keeps its
			// shape.
			vec3 offset = vec3(transition_offset(VERTEX.x, low.x, high.x),
				transition_offset(VERTEX.y, low.y, high.y), transition_offset(VERTEX.z, low.z, high.z));
			VERTEX += offset - NORMAL * dot(NORMAL, offset);
		}
	}
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
