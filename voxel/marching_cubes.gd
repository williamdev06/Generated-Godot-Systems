@tool
class_name MarchingCubes
extends RefCounted
# OWNS:       Turning a padded density/type grid into one chunk's mesh arrays (Transvoxel regular
#             cells), plus transition cells on faces that border a finer chunk.
# DEPENDS:    VoxelChunk (SIZE, ISO), TransvoxelTables
# INVARIANTS: Input grids hold PADDED^3 samples covering chunk-local -1..SIZE+1 per axis (INV-7).
#             Slabs hold slab_size(face) fine samples (half the grid spacing) starting at
#             slab_origin(face), x fastest (INV-10). CORNERS and the face order (axis * 2 + side, side
#             1 = the SIZE end) are what TransvoxelTables and voxel_terrain.gdshader assume.
# GOTCHAS:    Normals come from the density gradient, not the triangles, so both sides of a chunk
#             border get identical normals and no seam shows; transition vertices on the full
#             resolution face take theirs from the fine slab, matching the finer neighbour. An edge
#             vertex used only by mixed-type triangles stays in the buffer unreferenced.
#             Transition vertices are copies, not shared with regular cells: CUSTOM0 alpha marks
#             them (face + 1, plus FIXED on the full resolution face) so the shader can drop the
#             faces whose neighbour is not finer and move the rest (D-33).

const PADDED := VoxelChunk.SIZE + 3
# Fine samples along a face in a slab: -1..2 * SIZE + 1, one past each end for gradients.
const SLAB_SIDE := 2 * VoxelChunk.SIZE + 3
# CUSTOM0 alpha bit of transition vertices on the full resolution face, which the shader never
# moves. The low 3 bits hold the face index + 1.
const FIXED := 8

# TransvoxelTables.REGULAR sample numbering.
const CORNERS: Array[Vector3i] = [
	Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(0, 1, 0), Vector3i(1, 1, 0),
	Vector3i(0, 0, 1), Vector3i(1, 0, 1), Vector3i(0, 1, 1), Vector3i(1, 1, 1),
]

# Padded-grid index offset of each corner in CORNERS.
const CORNER_OFFSETS: Array[int] = [
	0, 1, PADDED, 1 + PADDED,
	PADDED * PADDED, 1 + PADDED * PADDED, PADDED + PADDED * PADDED, 1 + PADDED + PADDED * PADDED,
]

const AXES: Array[Vector3i] = [Vector3i(1, 0, 0), Vector3i(0, 1, 0), Vector3i(0, 0, 1)]

# TransvoxelTables.TRANSITION full resolution samples 0..8 as (u, v) in fine steps, and half
# resolution samples 9..12 as (u, v) in cells.
const FULL_SAMPLES: Array[Vector2i] = [
	Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0),
	Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1),
	Vector2i(0, 2), Vector2i(1, 2), Vector2i(2, 2),
]
const HALF_SAMPLES: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]


# Mesh arrays under construction. Vertices are created once per edge and shared by every triangle of
# one type; mixed type triangles get copies carrying their own barycentric weights (D-23).
class _Surface:
	const BARYCENTRIC: Array[Color] = [Color(1, 0, 0), Color(0, 1, 0), Color(0, 0, 1)]

	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var weights := PackedColorArray()
	# RGBA8 per vertex: rgb the triangle's corner types, a the transition flags.
	var corner_types := PackedByteArray()
	var indices := PackedInt32Array()

	func add_vertex(position: Vector3, normal: Vector3, type: int, flags: int) -> int:
		vertices.append(position)
		normals.append(normal)
		weights.append(BARYCENTRIC[0])
		corner_types.append_array(PackedByteArray([type, type, type, flags]))
		return vertices.size() - 1

	func add_triangle(corners: PackedInt32Array) -> void:
		var triangle_types := PackedByteArray([
			corner_types[corners[0] * 4], corner_types[corners[1] * 4], corner_types[corners[2] * 4]])
		if triangle_types[0] == triangle_types[1] and triangle_types[0] == triangle_types[2]:
			indices.append_array(corners)
			return
		for corner in 3:
			var shared := corners[corner]
			indices.append(vertices.size())
			vertices.append(vertices[shared])
			normals.append(normals[shared])
			weights.append(BARYCENTRIC[corner])
			corner_types.append_array(triangle_types)
			corner_types.append(corner_types[shared * 4 + 3])


# Mesh.ARRAY_MAX surface arrays, or [] when there is no surface. Every vertex carries its triangle's
# three voxel types (CUSTOM0 rgb, in triangle corner order) and its barycentric weight for them
# (COLOR), which voxel_terrain.gdshader blends by (D-23). Arrays rather than an ArrayMesh so the
# caller can also build collision from them: reading an ArrayMesh back is a GPU readback.
# slab_densities/slab_types: empty, or one slab per face (face order) to build transition cells from.
static func build_arrays(densities: PackedByteArray, types: PackedByteArray,
		slab_densities: Array[PackedByteArray] = [], slab_types: Array[PackedByteArray] = []) -> Array:
	var surface := _Surface.new()
	# Edge (padded index of its lower sample * 3 + axis) -> its vertex, -1 until created.
	var edge_vertices := PackedInt32Array()
	edge_vertices.resize(PADDED ** 3 * 3)
	edge_vertices.fill(-1)
	var triangle := PackedInt32Array([0, 0, 0])
	for z in VoxelChunk.SIZE:
		for y in VoxelChunk.SIZE:
			var cell_index := padded_index(Vector3i(0, y, z))
			for x in VoxelChunk.SIZE:
				var case_index := 0
				for corner in 8:
					if densities[cell_index + CORNER_OFFSETS[corner]] > VoxelChunk.ISO:
						case_index |= 1 << corner
				var edges: Array = TransvoxelTables.REGULAR[case_index]
				for vertex in edges.size():
					var edge: int = edges[vertex]
					# Edge codes list the lower sample first; samples differ in one bit, the edge's axis.
					var start := Vector3i(x, y, z) + CORNERS[edge >> 4]
					var axis := ((edge >> 4) ^ (edge & 15)) >> 1
					triangle[vertex % 3] = _grid_vertex(surface, edge_vertices, densities, types, start,
						axis, 0)
					if vertex % 3 == 2:
						surface.add_triangle(triangle)
				cell_index += 1
	for face in slab_densities.size():
		_add_transition_cells(surface, densities, types, face, slab_densities[face], slab_types[face])
	if surface.vertices.is_empty():
		return []
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = surface.vertices
	arrays[Mesh.ARRAY_NORMAL] = surface.normals
	arrays[Mesh.ARRAY_COLOR] = surface.weights
	arrays[Mesh.ARRAY_CUSTOM0] = surface.corner_types
	arrays[Mesh.ARRAY_INDEX] = surface.indices
	return arrays


# The ArrayMesh for non-empty build_arrays output.
static func create_mesh(arrays: Array) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {},
		Mesh.ARRAY_CUSTOM_RGBA8_UNORM << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
	return mesh


static func padded_index(local: Vector3i) -> int:
	return (local.x + 1) + (local.y + 1) * PADDED + (local.z + 1) * PADDED * PADDED


# Samples per axis of a face's slab: 3 across the face (one fine step either side), SLAB_SIDE along it.
static func slab_size(face: int) -> Vector3i:
	var size := Vector3i.ONE * SLAB_SIDE
	size[face >> 1] = 3
	return size


# First sample of a face's slab in fine steps (2 per cell) from the chunk origin.
static func slab_origin(face: int) -> Vector3i:
	var origin := -Vector3i.ONE
	origin[face >> 1] = (face & 1) * 2 * VoxelChunk.SIZE - 1
	return origin


# The vertex on the padded grid edge from local sample start one step along axis, created on first use.
static func _grid_vertex(surface: _Surface, cache: PackedInt32Array, densities: PackedByteArray,
		types: PackedByteArray, start: Vector3i, axis: int, flags: int) -> int:
	var start_index := padded_index(start)
	var key := start_index * 3 + axis
	if cache[key] == -1:
		var end_index := padded_index(start + AXES[axis])
		var start_density := densities[start_index]
		var end_density := densities[end_index]
		var weight := (VoxelChunk.ISO - start_density) / (end_density - start_density)
		# Density rises into the solid, so the outward normal is the negative gradient.
		var gradient := _gradient(densities, start_index, PADDED).lerp(
			_gradient(densities, end_index, PADDED), weight)
		var type := types[start_index if start_density > VoxelChunk.ISO else end_index]
		cache[key] = surface.add_vertex(Vector3(start).lerp(Vector3(start + AXES[axis]), weight),
			-gradient.normalized(), type, flags)
	return cache[key]


# Transition cells over the whole face, between the fine slab (full resolution face) and this
# chunk's own samples on the face (half resolution face).
static func _add_transition_cells(surface: _Surface, densities: PackedByteArray,
		types: PackedByteArray, face: int, slab_densities: PackedByteArray,
		slab_types: PackedByteArray) -> void:
	var axis := face >> 1
	var side := face & 1
	# u x v points into the chunk, as TransvoxelTables requires.
	var u_axis := (axis + 1 + side) % 3
	var v_axis := (axis + 2 - side) % 3
	var size := slab_size(face)
	var origin := slab_origin(face)
	var strides := Vector3i(1, size.x, size.x * size.y)
	var flags := face + 1
	# Fine edge (slab index of its lower sample * 3 + axis) -> its vertex, -1 until created.
	var fine_vertices := PackedInt32Array()
	fine_vertices.resize(size.x * size.y * size.z * 3)
	fine_vertices.fill(-1)
	# Half resolution vertices are this chunk's grid vertices on the face, copied with flags.
	var half_vertices := PackedInt32Array()
	half_vertices.resize(PADDED ** 3 * 3)
	half_vertices.fill(-1)
	var triangle := PackedInt32Array([0, 0, 0])
	var full_indices := PackedInt32Array()
	full_indices.resize(9)
	for cell_v in VoxelChunk.SIZE:
		for cell_u in VoxelChunk.SIZE:
			# Fine position (2 per cell, from the chunk origin) of full resolution sample 0.
			var cell_fine := Vector3i.ZERO
			cell_fine[axis] = side * 2 * VoxelChunk.SIZE
			cell_fine[u_axis] = cell_u * 2
			cell_fine[v_axis] = cell_v * 2
			for sample in 9:
				var fine := cell_fine
				fine[u_axis] += FULL_SAMPLES[sample].x
				fine[v_axis] += FULL_SAMPLES[sample].y
				full_indices[sample] = _slab_index(fine - origin, strides)
			var case_index := 0
			for bit in 9:
				if slab_densities[full_indices[TransvoxelTables.TRANSITION_CASE_SAMPLES[bit]]] \
						> VoxelChunk.ISO:
					case_index |= 1 << bit
			var edges: Array = TransvoxelTables.TRANSITION[case_index]
			for vertex in edges.size():
				var edge: int = edges[vertex]
				var start_sample := edge >> 4
				var end_sample := edge & 15
				if start_sample < 9:
					# Neighbouring full resolution samples: +1 along u, or +3 along v.
					var fine_axis := u_axis if end_sample - start_sample == 1 else v_axis
					var fine_start := cell_fine
					fine_start[u_axis] += FULL_SAMPLES[start_sample].x
					fine_start[v_axis] += FULL_SAMPLES[start_sample].y
					triangle[vertex % 3] = _slab_vertex(surface, fine_vertices, slab_densities,
						slab_types, origin, strides, fine_start, fine_axis, flags | FIXED)
				else:
					var half_start := HALF_SAMPLES[start_sample - 9]
					var half_end := HALF_SAMPLES[end_sample - 9]
					var start := Vector3i.ZERO
					start[axis] = side * VoxelChunk.SIZE
					start[u_axis] = cell_u + half_start.x
					start[v_axis] = cell_v + half_start.y
					var half_axis := u_axis if half_end.x != half_start.x else v_axis
					triangle[vertex % 3] = _grid_vertex(surface, half_vertices, densities, types, start,
						half_axis, flags)
				if vertex % 3 == 2:
					surface.add_triangle(triangle)


# The vertex on the slab edge from fine position start (fine steps from the chunk origin) one fine
# step along axis, in chunk-local units (half a unit per fine step), created on first use.
static func _slab_vertex(surface: _Surface, cache: PackedInt32Array, densities: PackedByteArray,
		types: PackedByteArray, origin: Vector3i, strides: Vector3i, start: Vector3i, axis: int,
		flags: int) -> int:
	var start_index := _slab_index(start - origin, strides)
	var key := start_index * 3 + axis
	if cache[key] == -1:
		var end_index := start_index + strides[axis]
		var start_density := densities[start_index]
		var end_density := densities[end_index]
		var weight := (VoxelChunk.ISO - start_density) / (end_density - start_density)
		var gradient := _gradient(densities, start_index, strides.y, strides.z).lerp(
			_gradient(densities, end_index, strides.y, strides.z), weight)
		var type := types[start_index if start_density > VoxelChunk.ISO else end_index]
		var position := Vector3(start).lerp(Vector3(start + AXES[axis]), weight) * 0.5
		cache[key] = surface.add_vertex(position, -gradient.normalized(), type, flags)
	return cache[key]


static func _slab_index(position: Vector3i, strides: Vector3i) -> int:
	return position.x * strides.x + position.y * strides.y + position.z * strides.z


# Central differences; z_stride defaults to the padded grid's plane size.
static func _gradient(densities: PackedByteArray, index: int, y_stride: int,
		z_stride: int = PADDED * PADDED) -> Vector3:
	return Vector3(
		densities[index + 1] - densities[index - 1],
		densities[index + y_stride] - densities[index - y_stride],
		densities[index + z_stride] - densities[index - z_stride],
	)
