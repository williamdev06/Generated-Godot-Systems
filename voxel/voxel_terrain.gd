@tool
class_name VoxelTerrain
extends Node3D
# OWNS:       The 3D chunk grid: chunk data lookup, chunk meshes, voxel edits.
# DEPENDS:    VoxelChunk, VoxelGenerator, MarchingCubes
# INVARIANTS: An authored chunk is the same object in authored_chunks and _chunks, so edits land in
#             the saved data; authored chunks override the generator (see D-17).
# GOTCHAS:    @tool: everything is rebuilt in the editor when generator, its noise or chunk_extent
#             change. Chunk MeshInstance3Ds are internal children without an owner, so they are
#             never saved into the scene. Without a generator, unauthored chunks are air. A chunk
#             mesh reads samples one past its own on each side (INV-7), so remeshing pulls in
#             neighbour chunk data, generating chunks just outside chunk_extent.

@export var generator: VoxelGenerator:
	set(value):
		if generator != null:
			generator.changed.disconnect(_queue_rebuild)
		generator = value
		if generator != null:
			generator.changed.connect(_queue_rebuild)
		_queue_rebuild()

# Chunks with coordinates in [-chunk_extent, chunk_extent) per axis get meshes.
@export var chunk_extent := Vector3i(2, 2, 2):
	set(value):
		chunk_extent = value
		_queue_rebuild()

# Chunks changed through set_voxel, saved with the scene.
@export_storage var authored_chunks: Dictionary[Vector3i, VoxelChunk] = {}

var _chunks: Dictionary[Vector3i, VoxelChunk] = {}
var _meshes: Dictionary[Vector3i, MeshInstance3D] = {}
# Chunks waiting for a remesh after set_voxel; flushed once per frame.
var _dirty: Dictionary[Vector3i, bool] = {}
var _rebuild_queued := false
var _material := StandardMaterial3D.new()


func _init() -> void:
	_material.vertex_color_use_as_albedo = true
	_material.vertex_color_is_srgb = true


func _ready() -> void:
	_queue_rebuild()


func set_voxel(world: Vector3i, density: float, type: VoxelChunk.Type) -> void:
	var coord := _chunk_coord(world)
	var chunk := _get_chunk(coord)
	authored_chunks[coord] = chunk
	var index := VoxelChunk.sample_index(world - coord * VoxelChunk.SIZE)
	chunk.densities[index] = density
	chunk.types[index] = type
	if _dirty.is_empty():
		_flush_dirty.call_deferred()
	for z in range(-1, 2):
		for y in range(-1, 2):
			for x in range(-1, 2):
				var neighbour := coord + Vector3i(x, y, z)
				var padded := world - neighbour * VoxelChunk.SIZE + Vector3i.ONE
				var in_padded_grid := padded.x >= 0 and padded.y >= 0 and padded.z >= 0 \
					and padded.x < MarchingCubes.PADDED and padded.y < MarchingCubes.PADDED \
					and padded.z < MarchingCubes.PADDED
				if in_padded_grid and _is_in_extent(neighbour):
					_dirty[neighbour] = true


func _queue_rebuild() -> void:
	if _rebuild_queued:
		return
	_rebuild_queued = true
	_rebuild.call_deferred()


func _rebuild() -> void:
	_rebuild_queued = false
	for mesh_instance in _meshes.values():
		mesh_instance.queue_free()
	_meshes.clear()
	_dirty.clear()
	_chunks.clear()
	_chunks.merge(authored_chunks)
	for z in range(-chunk_extent.z, chunk_extent.z):
		for y in range(-chunk_extent.y, chunk_extent.y):
			for x in range(-chunk_extent.x, chunk_extent.x):
				_remesh(Vector3i(x, y, z))


func _flush_dirty() -> void:
	for coord in _dirty:
		_remesh(coord)
	_dirty.clear()


func _remesh(coord: Vector3i) -> void:
	var densities := PackedFloat32Array()
	densities.resize(MarchingCubes.PADDED ** 3)
	var types := PackedByteArray()
	types.resize(MarchingCubes.PADDED ** 3)
	var origin := coord * VoxelChunk.SIZE
	for z in range(-1, VoxelChunk.SIZE + 2):
		for y in range(-1, VoxelChunk.SIZE + 2):
			for x in range(-1, VoxelChunk.SIZE + 2):
				var world := origin + Vector3i(x, y, z)
				var chunk_coord := _chunk_coord(world)
				var chunk := _get_chunk(chunk_coord)
				var index := VoxelChunk.sample_index(world - chunk_coord * VoxelChunk.SIZE)
				var padded_index := MarchingCubes.padded_index(Vector3i(x, y, z))
				densities[padded_index] = chunk.densities[index]
				types[padded_index] = chunk.types[index]
	var mesh := MarchingCubes.build_mesh(densities, types)
	if mesh == null:
		if _meshes.has(coord):
			_meshes[coord].queue_free()
			_meshes.erase(coord)
		return
	if not _meshes.has(coord):
		var mesh_instance := MeshInstance3D.new()
		mesh_instance.position = Vector3(origin)
		mesh_instance.material_override = _material
		add_child(mesh_instance, false, Node.INTERNAL_MODE_BACK)
		_meshes[coord] = mesh_instance
	_meshes[coord].mesh = mesh


func _get_chunk(coord: Vector3i) -> VoxelChunk:
	if not _chunks.has(coord):
		_chunks[coord] = generator.generate(coord) if generator != null else VoxelChunk.new()
	return _chunks[coord]


func _is_in_extent(coord: Vector3i) -> bool:
	return coord.x >= -chunk_extent.x and coord.x < chunk_extent.x \
		and coord.y >= -chunk_extent.y and coord.y < chunk_extent.y \
		and coord.z >= -chunk_extent.z and coord.z < chunk_extent.z


static func _chunk_coord(world: Vector3i) -> Vector3i:
	return Vector3i(
		floori(float(world.x) / VoxelChunk.SIZE),
		floori(float(world.y) / VoxelChunk.SIZE),
		floori(float(world.z) / VoxelChunk.SIZE),
	)
