@tool
class_name VoxelTerrain
extends Node3D
# OWNS:       The 3D chunk grid, infinite (streamed around the camera) or contained: threaded
#             generation and meshing, edits.
# DEPENDS:    VoxelChunk, VoxelGenerator, MarchingCubes, WorkerThreadPool
# INVARIANTS: An authored chunk is the same object in authored_chunks and _chunks, so edits land in
#             the saved data; authored chunks override the generator (see D-17).
# GOTCHAS:    @tool: everything is rebuilt in the editor when any export, the generator or its noise
#             change. Chunk MeshInstance3Ds are internal children without an owner, so they are
#             never saved into the scene. Without a generator, unauthored chunks are air. A chunk
#             mesh reads samples one past its own on each side (INV-7), so remeshing pulls in
#             neighbour chunk data, generating chunks just outside chunk_extent.
#             Contained worlds (D-20) store no chunks outside world_size; meshing reads air
#             there (outside_faces) or repeats the boundary samples; set_voxel ignores them.
#             Streaming (D-19, infinite only): follows the editor camera of 3D viewport 0 in the
#             editor and the current camera in game. Chunks leaving the range lose their mesh and,
#             unless authored, their data.
#             Threading (D-18): _generate_chunk and _mesh_chunk run on worker threads and must not
#             touch members; they get a generator snapshot and copy-on-write sample arrays instead.
#             Tasks call methods on this node, so PREDELETE waits for them. Results are applied in
#             _process, which also runs in the editor. Cancelling only sets a flag the worker checks
#             between stages; the task still has to be waited for (_abandoned_tasks).

@export var generator: VoxelGenerator:
	set(value):
		if generator != null:
			generator.changed.disconnect(_queue_rebuild)
		generator = value
		if generator != null:
			generator.changed.connect(_queue_rebuild)
		_queue_rebuild()

# Off: a contained world of world_size chunks from this node's origin along +x, +y, +z.
@export var infinite := true:
	set(value):
		infinite = value
		_queue_rebuild()

# Off: unauthored chunks are air, for hand-authored terrain.
@export var procedural := true:
	set(value):
		procedural = value
		_queue_rebuild()

# Infinite only: chunks in [camera chunk - chunk_extent, camera chunk + chunk_extent) get meshes.
@export var chunk_extent := Vector3i(2, 2, 2):
	set(value):
		chunk_extent = value
		_queue_rebuild()

# Contained only.
@export var world_size := Vector3i(4, 2, 4):
	set(value):
		world_size = value
		_queue_rebuild()

# Contained only: closes the surface where solid voxels touch the world boundary. Off leaves the
# terrain cut open there.
@export var outside_faces := true:
	set(value):
		outside_faces = value
		_queue_rebuild()

# Chunks changed through set_voxel, saved with the scene.
@export_storage var authored_chunks: Dictionary[Vector3i, VoxelChunk] = {}

var _chunks: Dictionary[Vector3i, VoxelChunk] = {}
# A null value marks a chunk that was meshed but has no surface.
var _meshes: Dictionary[Vector3i, MeshInstance3D] = {}
# Infinite only: chunk the camera is in; the streamed range is centred on it.
var _center := Vector3i.ZERO
# Read by worker threads instead of generator, so inspector edits never race a running task.
var _generator_snapshot: VoxelGenerator
# Both queues are kept nearest-first (_refresh); dictionaries iterate in insertion order.
var _generation_queue: Array[Vector3i] = []
# Chunks waiting for a mesh; started once they and their 26 neighbours have data.
var _mesh_queue: Dictionary[Vector3i, bool] = {}
var _generation_tasks: Dictionary[Vector3i, ChunkTask] = {}
var _mesh_tasks: Dictionary[Vector3i, ChunkTask] = {}
# Cancelled tasks; waited for and their results dropped.
var _abandoned_tasks: Array[ChunkTask] = []
var _rebuild_queued := false
var _material := StandardMaterial3D.new()
# Stands in for chunks outside a contained world.
var _air_chunk := VoxelChunk.new()


# The worker writes result; the main thread reads it only after the task completes. cancelled is
# written by the main thread and polled by the worker; a stale read only delays the cancel.
class ChunkTask:
	var id: int
	var result: Variant
	var cancelled := false


func _init() -> void:
	_material.vertex_color_use_as_albedo = true
	_material.vertex_color_is_srgb = true


func _ready() -> void:
	_queue_rebuild()


func _process(_delta: float) -> void:
	if infinite:
		var center := _viewer_chunk()
		if center != _center:
			_center = center
			_refresh()
	_finish_tasks()
	_start_tasks()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		for task in _generation_tasks.values():
			_cancel(task)
		for task in _mesh_tasks.values():
			_cancel(task)
		for task in _abandoned_tasks:
			WorkerThreadPool.wait_for_task_completion(task.id)


func set_voxel(world: Vector3i, density: float, type: VoxelChunk.Type) -> void:
	var coord := _chunk_coord(world)
	# A contained world has no voxels outside its chunks; brushes reaching past the edge are clipped.
	if _is_outside_world(coord):
		return
	var chunk := _get_chunk(coord)
	authored_chunks[coord] = chunk
	var index := VoxelChunk.sample_index(world - coord * VoxelChunk.SIZE)
	chunk.densities[index] = density
	chunk.types[index] = type
	for z in range(-1, 2):
		for y in range(-1, 2):
			for x in range(-1, 2):
				var neighbour := coord + Vector3i(x, y, z)
				var padded := world - neighbour * VoxelChunk.SIZE + Vector3i.ONE
				var in_padded_grid := padded.x >= 0 and padded.y >= 0 and padded.z >= 0 \
					and padded.x < MarchingCubes.PADDED and padded.y < MarchingCubes.PADDED \
					and padded.z < MarchingCubes.PADDED
				if in_padded_grid and _is_meshed(neighbour):
					_mesh_queue[neighbour] = true


func _queue_rebuild() -> void:
	if _rebuild_queued:
		return
	_rebuild_queued = true
	_rebuild.call_deferred()


func _rebuild() -> void:
	_rebuild_queued = false
	for task in _generation_tasks.values():
		_cancel(task)
	for task in _mesh_tasks.values():
		_cancel(task)
	_generation_tasks.clear()
	_mesh_tasks.clear()
	_chunks.clear()
	_chunks.merge(authored_chunks)
	_generator_snapshot = null
	if generator != null and procedural:
		_generator_snapshot = generator.duplicate(true) as VoxelGenerator
	# Existing meshes stay visible until their replacement arrives, so a rebuild does not flicker.
	for coord in _meshes:
		_mesh_queue[coord] = true
	_refresh()


# Unloads what left the range and queues what entered it, nearest to _center first.
func _refresh() -> void:
	for coord in _meshes.keys():
		if not _is_meshed(coord):
			if _meshes[coord] != null:
				_meshes[coord].queue_free()
			_meshes.erase(coord)
	for coord in _mesh_tasks.keys():
		if not _is_meshed(coord):
			_cancel(_mesh_tasks[coord])
			_mesh_tasks.erase(coord)
	for coord in _generation_tasks.keys():
		if not _is_loaded(coord):
			_cancel(_generation_tasks[coord])
			_generation_tasks.erase(coord)
	for coord in _chunks.keys():
		if not _is_loaded(coord) and not authored_chunks.has(coord):
			_chunks.erase(coord)
	var mesh_coords := _mesh_queue.keys().filter(_is_meshed)
	_generation_queue.clear()
	# Covers both ranges: loaded reaches at most one chunk past the meshed range.
	var begin := _mesh_begin() - Vector3i.ONE
	var end := _mesh_end() + Vector3i.ONE
	for z in range(begin.z, end.z):
		for y in range(begin.y, end.y):
			for x in range(begin.x, end.x):
				var coord := Vector3i(x, y, z)
				var needs_data := not _chunks.has(coord) and not _generation_tasks.has(coord)
				if needs_data and _is_loaded(coord):
					_generation_queue.append(coord)
				var needs_mesh := not _meshes.has(coord) and not _mesh_tasks.has(coord) \
					and not _mesh_queue.has(coord)
				if needs_mesh and _is_meshed(coord):
					mesh_coords.append(coord)
	_generation_queue.sort_custom(_is_nearer)
	mesh_coords.sort_custom(_is_nearer)
	_mesh_queue.clear()
	for coord in mesh_coords:
		_mesh_queue[coord] = true


func _finish_tasks() -> void:
	for index in range(_abandoned_tasks.size() - 1, -1, -1):
		if _try_complete(_abandoned_tasks[index]):
			_abandoned_tasks.remove_at(index)
	for coord in _generation_tasks.keys():
		var task: ChunkTask = _generation_tasks[coord]
		if _try_complete(task):
			_generation_tasks.erase(coord)
			# set_voxel may have created the chunk while the task ran; the edit wins.
			if not _chunks.has(coord):
				_chunks[coord] = task.result
	for coord in _mesh_tasks.keys():
		var task: ChunkTask = _mesh_tasks[coord]
		if _try_complete(task):
			_mesh_tasks.erase(coord)
			_apply_mesh(coord, task.result)


# Tasks in flight are capped at the core count (the pool's default size), so a rebuild or
# deletion only ever waits for a handful of chunks and queued work can still be dropped.
func _start_tasks() -> void:
	var task_count := _abandoned_tasks.size() + _generation_tasks.size() + _mesh_tasks.size()
	var free_slots := OS.get_processor_count() - task_count
	while free_slots > 0 and not _generation_queue.is_empty():
		var coord: Vector3i = _generation_queue.pop_front()
		if _chunks.has(coord):
			continue
		var task := ChunkTask.new()
		task.id = WorkerThreadPool.add_task(_generate_chunk.bind(task, _generator_snapshot, coord))
		_generation_tasks[coord] = task
		free_slots -= 1
	for coord in _mesh_queue.keys():
		if free_slots <= 0:
			return
		if _mesh_tasks.has(coord) or not _has_neighbourhood(coord):
			continue
		_mesh_queue.erase(coord)
		var chunk_densities: Array[PackedFloat32Array] = []
		var chunk_types: Array[PackedByteArray] = []
		for z in range(-1, 2):
			for y in range(-1, 2):
				for x in range(-1, 2):
					var neighbour := coord + Vector3i(x, y, z)
					var chunk: VoxelChunk = _air_chunk if _is_outside_world(neighbour) else _chunks[neighbour]
					chunk_densities.append(chunk.densities)
					chunk_types.append(chunk.types)
		# Chunk-local sample bounds the gather clamps to; the default never clamps.
		var sample_min := -Vector3i.ONE
		var sample_max := Vector3i.ONE * (VoxelChunk.SIZE + 1)
		if not infinite and not outside_faces:
			# Repeating the boundary samples outward leaves no sign change, so no surface, there.
			var origin := coord * VoxelChunk.SIZE
			sample_min = sample_min.max(-origin)
			sample_max = sample_max.min(world_size * VoxelChunk.SIZE - Vector3i.ONE - origin)
		var task := ChunkTask.new()
		task.id = WorkerThreadPool.add_task(
			_mesh_chunk.bind(task, chunk_densities, chunk_types, sample_min, sample_max))
		_mesh_tasks[coord] = task
		free_slots -= 1


func _cancel(task: ChunkTask) -> void:
	task.cancelled = true
	_abandoned_tasks.append(task)


func _try_complete(task: ChunkTask) -> bool:
	if not WorkerThreadPool.is_task_completed(task.id):
		return false
	# Required once per task to release it; returns at once since the task is done.
	WorkerThreadPool.wait_for_task_completion(task.id)
	return true


# Worker thread: must not touch members.
func _generate_chunk(task: ChunkTask, generator_snapshot: VoxelGenerator, coord: Vector3i) -> void:
	if task.cancelled:
		return
	if generator_snapshot != null:
		task.result = generator_snapshot.generate(coord)
	else:
		task.result = VoxelChunk.new()


# Worker thread: must not touch members. The arrays hold the 3x3x3 chunks around the meshed chunk,
# x fastest; they are copy-on-write snapshots, so set_voxel on the main thread cannot change them.
func _mesh_chunk(task: ChunkTask, chunk_densities: Array[PackedFloat32Array],
		chunk_types: Array[PackedByteArray], sample_min: Vector3i, sample_max: Vector3i) -> void:
	if task.cancelled:
		return
	var densities := PackedFloat32Array()
	densities.resize(MarchingCubes.PADDED ** 3)
	var types := PackedByteArray()
	types.resize(MarchingCubes.PADDED ** 3)
	for z in range(-1, VoxelChunk.SIZE + 2):
		for y in range(-1, VoxelChunk.SIZE + 2):
			for x in range(-1, VoxelChunk.SIZE + 2):
				var local := Vector3i(x, y, z).clamp(sample_min, sample_max)
				var offset := _chunk_coord(local)
				var neighbour := (offset.x + 1) + (offset.y + 1) * 3 + (offset.z + 1) * 9
				var index := VoxelChunk.sample_index(local - offset * VoxelChunk.SIZE)
				var padded_index := MarchingCubes.padded_index(Vector3i(x, y, z))
				densities[padded_index] = chunk_densities[neighbour][index]
				types[padded_index] = chunk_types[neighbour][index]
	if task.cancelled:
		return
	# Building the ArrayMesh here is safe: resources may be created off the main thread.
	task.result = MarchingCubes.build_mesh(densities, types)


func _apply_mesh(coord: Vector3i, mesh: ArrayMesh) -> void:
	if mesh == null:
		if _meshes.get(coord) != null:
			_meshes[coord].queue_free()
		_meshes[coord] = null
		return
	if _meshes.get(coord) == null:
		var mesh_instance := MeshInstance3D.new()
		mesh_instance.position = Vector3(coord * VoxelChunk.SIZE)
		mesh_instance.material_override = _material
		add_child(mesh_instance, false, Node.INTERNAL_MODE_BACK)
		_meshes[coord] = mesh_instance
	_meshes[coord].mesh = mesh


func _has_neighbourhood(coord: Vector3i) -> bool:
	for z in range(-1, 2):
		for y in range(-1, 2):
			for x in range(-1, 2):
				var neighbour := coord + Vector3i(x, y, z)
				if not _chunks.has(neighbour) and not _is_outside_world(neighbour):
					return false
	return true


func _get_chunk(coord: Vector3i) -> VoxelChunk:
	if not _chunks.has(coord):
		if generator != null and procedural:
			_chunks[coord] = generator.generate(coord)
		else:
			_chunks[coord] = VoxelChunk.new()
	return _chunks[coord]


# Chunks that get a mesh are [_mesh_begin(), _mesh_end()) per axis.
func _mesh_begin() -> Vector3i:
	if infinite:
		return _center - chunk_extent
	# The closing faces on the low sides lie in the last cells of chunk -1 (cells span sample n..n+1).
	return -Vector3i.ONE if outside_faces else Vector3i.ZERO


func _mesh_end() -> Vector3i:
	return _center + chunk_extent if infinite else world_size


func _is_meshed(coord: Vector3i) -> bool:
	return _is_in_box(coord, _mesh_begin(), _mesh_end())


# Chunks whose data is kept in _chunks.
func _is_loaded(coord: Vector3i) -> bool:
	if infinite:
		# One chunk past the meshed range: meshes read their neighbours' samples (INV-7).
		return _is_in_box(coord, _mesh_begin() - Vector3i.ONE, _mesh_end() + Vector3i.ONE)
	return _is_in_box(coord, Vector3i.ZERO, world_size)


func _is_outside_world(coord: Vector3i) -> bool:
	return not infinite and not _is_in_box(coord, Vector3i.ZERO, world_size)


func _is_in_box(coord: Vector3i, begin: Vector3i, end: Vector3i) -> bool:
	return coord.x >= begin.x and coord.x < end.x and coord.y >= begin.y and coord.y < end.y \
		and coord.z >= begin.z and coord.z < end.z


func _is_nearer(a: Vector3i, b: Vector3i) -> bool:
	return (a - _center).length_squared() < (b - _center).length_squared()


# The editor camera in the editor, the current camera in game; keeps the last centre without one.
func _viewer_chunk() -> Vector3i:
	var camera: Camera3D
	if Engine.is_editor_hint():
		# Looked up by name and untyped: the EditorInterface class does not exist in exported games.
		var editor = Engine.get_singleton(&"EditorInterface")
		camera = editor.get_editor_viewport_3d(0).get_camera_3d()
	else:
		camera = get_viewport().get_camera_3d()
	if camera == null:
		return _center
	return _chunk_coord(Vector3i(to_local(camera.global_position).floor()))


static func _chunk_coord(world: Vector3i) -> Vector3i:
	return Vector3i(
		floori(float(world.x) / VoxelChunk.SIZE),
		floori(float(world.y) / VoxelChunk.SIZE),
		floori(float(world.z) / VoxelChunk.SIZE),
	)
