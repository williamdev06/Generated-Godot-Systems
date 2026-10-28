@tool
class_name VoxelTerrain
extends Node3D
# OWNS:       The 3D chunk grid, infinite (streamed around the camera) or contained: threaded
#             generation and meshing, edits.
# DEPENDS:    VoxelChunk, VoxelGenerator, MarchingCubes, VoxelType, VoxelStorage (VoxelRegionStorage,
#             VoxelModel), voxel_terrain.gdshader, WorkerThreadPool
# INVARIANTS: Every chunk not loaded from storage is in _unsaved until written; saved chunks override
#             the generator. A chunk is never in both _chunks and _save_queue (D-25, D-26).
# GOTCHAS:    @tool: everything is rebuilt in the editor when any export, the generator or its noise
#             change. Chunk MeshInstance3Ds are internal children without an owner, so they are
#             never saved into the scene. Without a generator, chunks not in storage are air. A
#             chunk mesh reads samples one past its own on each side (INV-7), so remeshing pulls in
#             neighbour chunk data, generating chunks just outside chunk_extent.
#             Contained worlds (D-20) store no chunks outside model.world_size; meshing reads air
#             there (outside_faces) or repeats the boundary samples; set_voxel ignores them.
#             Streaming (D-19, infinite only): follows the editor camera of 3D viewport 0 in the
#             editor and the current camera in game. Chunks leaving the range lose their mesh and
#             data (queued for saving first).
#             Threading (D-18): _generate_chunk and _mesh_chunk run on worker threads and must not
#             touch members; they get a generator snapshot and copy-on-write sample arrays instead.
#             Tasks call methods on this node, so PREDELETE waits for them. Results are applied in
#             _process, which also runs in the editor. Cancelling only sets a flag the worker checks
#             between stages; the task still has to be waited for (_abandoned_tasks).
#             Chunks whose 3x3x3 neighbourhood is uniformly air or uniformly full get no mesh task.
#             Storage: infinite worlds use storage (D-25), contained ones model (D-26), created
#             built into the scene when empty. Unloaded chunks are written by one save task at a
#             time; editor scene save, rebuild and (infinite) deletion write synchronously. A chunk
#             wanted again before its save finished is taken back from the queue, never reloaded
#             stale. Contained edits reach model every frame, so duplicating it (Make Unique) or
#             saving it as an asset captures them.

@export var generator: VoxelGenerator:
	set(value):
		if generator != null:
			generator.changed.disconnect(_queue_rebuild)
		generator = value
		if generator != null:
			generator.changed.connect(_queue_rebuild)
		_queue_rebuild()

# Off: a contained world of model.world_size chunks from this node's origin along +x, +y, +z.
@export var infinite := true:
	set(value):
		infinite = value
		_queue_rebuild()

# Off: chunks not in storage are air, for hand-authored terrain.
@export var procedural := true:
	set(value):
		procedural = value
		_queue_rebuild()

# Infinite only: chunks in [camera chunk - chunk_extent, camera chunk + chunk_extent) get meshes.
@export var chunk_extent := Vector3i(2, 2, 2):
	set(value):
		chunk_extent = value
		_queue_rebuild()

# Contained only: closes the surface where solid voxels touch the world boundary. Off leaves the
# terrain cut open there.
@export var outside_faces := true:
	set(value):
		outside_faces = value
		_queue_rebuild()

# Infinite only (contained worlds use model.voxel_types): a chunk's type byte indexes this; also
# the shader texture layer of each type. Changing it never remeshes.
@export var voxel_types: Array[VoxelType] = []:
	set(value):
		voxel_types = value
		_watch_types()

# Infinite only: where chunks are saved and loaded. Without one, nothing is saved (warning).
@export var storage: VoxelRegionStorage:
	set(value):
		if storage != null:
			storage.changed.disconnect(_queue_rebuild)
		storage = value
		if storage != null:
			storage.changed.connect(_queue_rebuild)
		_queue_rebuild()

# Contained only: the world (size, types, chunks). Left empty, a model built into the scene is
# created; save that as a file to reuse the terrain, or assign a model asset.
@export var model: VoxelModel:
	set(value):
		if model != null:
			model.changed.disconnect(_queue_rebuild)
		model = value
		if model != null:
			model.changed.connect(_queue_rebuild)
		_queue_rebuild()

var _chunks: Dictionary[Vector3i, VoxelChunk] = {}
# A null value marks a chunk that was meshed but has no surface.
var _meshes: Dictionary[Vector3i, MeshInstance3D] = {}
# Infinite only: chunk the camera is in; the streamed range is centred on it.
var _center := Vector3i.ZERO
# Read by worker threads instead of generator, so inspector edits never race a running task.
var _generator_snapshot: VoxelGenerator
# Infinite: a storage copy, null without a storage directory. Contained: model itself, so writes
# land in the resource that gets saved.
var _storage_snapshot: VoxelStorage
# Loaded chunks not yet written to storage; true when edited (kept on rebuild).
var _unsaved: Dictionary[Vector3i, bool] = {}
# Contained only: set_voxel ran since edits were last written to model.
var _edits_pending := false
# Types whose changed signal is connected to _update_textures (_watch_types).
var _watched_types: Array[VoxelType] = []
# Unloaded chunks waiting for the save task, and the ones it is writing.
var _save_queue: Dictionary[Vector3i, VoxelChunk] = {}
var _saving: Dictionary[Vector3i, VoxelChunk] = {}
var _save_task: ChunkTask
# Both queues are kept nearest-first (_refresh); dictionaries iterate in insertion order.
var _generation_queue: Array[Vector3i] = []
# Chunks waiting for a mesh; started once they and their 26 neighbours have data.
var _mesh_queue: Dictionary[Vector3i, bool] = {}
var _generation_tasks: Dictionary[Vector3i, ChunkTask] = {}
var _mesh_tasks: Dictionary[Vector3i, ChunkTask] = {}
# Cancelled tasks; waited for and their results dropped.
var _abandoned_tasks: Array[ChunkTask] = []
var _rebuild_queued := false
var _material := ShaderMaterial.new()
# Densities and types of an air chunk, standing in for empty chunks and those outside a contained
# world when gathering mesh input.
var _air_samples := PackedByteArray()


# The worker writes result; the main thread reads it only after the task completes. cancelled is
# written by the main thread and polled by the worker; a stale read only delays the cancel.
class ChunkTask:
	var id: int
	var result: Variant
	var cancelled := false
	# Generation only: result came from storage rather than the generator.
	var loaded := false


func _init() -> void:
	_material.shader = preload("voxel_terrain.gdshader")
	_air_samples.resize(VoxelChunk.VOLUME)
	_air_samples.fill(0)


func _ready() -> void:
	_queue_rebuild()


func _process(_delta: float) -> void:
	if infinite:
		var center := _viewer_chunk()
		if center != _center:
			_center = center
			_refresh()
	if _edits_pending and not infinite:
		_edits_pending = false
		_flush(true)
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
		# Contained worlds save with the scene or asset, not on close; closing unsaved discards.
		if infinite:
			_flush(false)
	elif what == NOTIFICATION_EDITOR_PRE_SAVE:
		_flush(false)
		# A built-in model is saved with the scene; an asset (no "::" in its path) by itself.
		if not infinite and model != null and not model.resource_path.is_empty() \
				and not model.resource_path.contains("::"):
			ResourceSaver.save(model)


func _get_configuration_warnings() -> PackedStringArray:
	if infinite and (storage == null or storage.directory.is_empty()):
		return PackedStringArray(["No storage directory selected: this infinite world is not saved."])
	return PackedStringArray()


# density 0.0 (empty) to 1.0 (full), solid above 0.5; type indexes get_voxel_types().
func set_voxel(world: Vector3i, density: float, type: int) -> void:
	var coord := _chunk_coord(world)
	# A contained world has no voxels outside its chunks; brushes reaching past the edge are clipped.
	if _is_outside_world(coord):
		return
	var chunk := _get_chunk(coord)
	_unsaved[coord] = true
	_edits_pending = true
	if chunk.densities.is_empty():
		chunk.densities = _air_samples.duplicate()
		chunk.types = _air_samples.duplicate()
	var index := VoxelChunk.sample_index(world - coord * VoxelChunk.SIZE)
	chunk.densities[index] = roundi(clampf(density, 0.0, 1.0) * 255.0)
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


# set_voxel for each index; the editor's undo/redo replays strokes through this.
func set_voxels(worlds: Array[Vector3i], densities: PackedFloat32Array,
		types: PackedByteArray) -> void:
	for index in worlds.size():
		set_voxel(worlds[index], densities[index], types[index])


# 0.0..1.0. Chunks without data (not generated yet, unloaded, outside a contained world, or all
# air) read as air.
func get_density(world: Vector3i) -> float:
	var coord := _chunk_coord(world)
	var chunk: VoxelChunk = _chunks.get(coord)
	if chunk == null or chunk.densities.is_empty():
		return 0.0
	return chunk.densities[VoxelChunk.sample_index(world - coord * VoxelChunk.SIZE)] / 255.0


func get_type(world: Vector3i) -> int:
	var coord := _chunk_coord(world)
	var chunk: VoxelChunk = _chunks.get(coord)
	if chunk == null or chunk.types.is_empty():
		return 0
	return chunk.types[VoxelChunk.sample_index(world - coord * VoxelChunk.SIZE)]


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
	# Edits survive into the old storage; chunks the old generator made would only be stale.
	_flush(true)
	_unsaved.clear()
	_chunks.clear()
	_generator_snapshot = null
	if generator != null and procedural:
		_generator_snapshot = generator.duplicate(true) as VoxelGenerator
	_storage_snapshot = null
	if infinite:
		if storage != null and not storage.directory.is_empty():
			_storage_snapshot = storage.duplicate() as VoxelRegionStorage
	else:
		if model == null:
			# Queues one more rebuild through the setter; harmless.
			model = VoxelModel.new()
		_storage_snapshot = model
	# The active palette may have switched with infinite or model.
	_watch_types()
	update_configuration_warnings()
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
		if not _is_loaded(coord):
			if _unsaved.has(coord) and _storage_snapshot != null:
				_save_queue[coord] = _chunks[coord]
			_unsaved.erase(coord)
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
	if _save_task != null and _try_complete(_save_task):
		_save_task = null
		_saving.clear()
	for coord in _generation_tasks.keys():
		var task: ChunkTask = _generation_tasks[coord]
		if _try_complete(task):
			_generation_tasks.erase(coord)
			# set_voxel may have created the chunk while the task ran; the edit wins.
			if not _chunks.has(coord):
				_chunks[coord] = task.result
				if not task.loaded:
					_unsaved[coord] = false
	for coord in _mesh_tasks.keys():
		var task: ChunkTask = _mesh_tasks[coord]
		if _try_complete(task):
			_mesh_tasks.erase(coord)
			_apply_mesh(coord, task.result)


# Tasks in flight are capped at the core count (the pool's default size), so a rebuild or
# deletion only ever waits for a handful of chunks and queued work can still be dropped.
func _start_tasks() -> void:
	if _save_task == null and not _save_queue.is_empty():
		var coords: Array[Vector3i] = []
		var chunk_densities: Array[PackedByteArray] = []
		var chunk_types: Array[PackedByteArray] = []
		for coord in _save_queue:
			coords.append(coord)
			chunk_densities.append(_save_queue[coord].densities)
			chunk_types.append(_save_queue[coord].types)
		_saving = _save_queue.duplicate()
		_save_queue.clear()
		_save_task = ChunkTask.new()
		_save_task.id = WorkerThreadPool.add_task(
			_save_chunks.bind(_storage_snapshot, coords, chunk_densities, chunk_types))
	var task_count := _abandoned_tasks.size() + _generation_tasks.size() + _mesh_tasks.size()
	var free_slots := OS.get_processor_count() - task_count
	while free_slots > 0 and not _generation_queue.is_empty():
		var coord: Vector3i = _generation_queue.pop_front()
		if _chunks.has(coord):
			continue
		var reclaimed := _reclaim(coord)
		if reclaimed != null:
			_chunks[coord] = reclaimed
			continue
		var task := ChunkTask.new()
		task.id = WorkerThreadPool.add_task(
			_generate_chunk.bind(task, _generator_snapshot, _storage_snapshot, coord))
		_generation_tasks[coord] = task
		free_slots -= 1
	for coord: Vector3i in _mesh_queue.keys():
		if free_slots <= 0:
			return
		if _mesh_tasks.has(coord) or not _has_neighbourhood(coord):
			continue
		_mesh_queue.erase(coord)
		var chunk_densities: Array[PackedByteArray] = []
		var chunk_types: Array[PackedByteArray] = []
		for z in range(-1, 2):
			for y in range(-1, 2):
				for x in range(-1, 2):
					var neighbour := coord + Vector3i(x, y, z)
					if _is_outside_world(neighbour) or _chunks[neighbour].densities.is_empty():
						chunk_densities.append(_air_samples)
						chunk_types.append(_air_samples)
					else:
						chunk_densities.append(_chunks[neighbour].densities)
						chunk_types.append(_chunks[neighbour].types)
		if _is_uniform(chunk_densities, 0) or _is_uniform(chunk_densities, 255):
			_apply_mesh(coord, null)
			continue
		# Chunk-local sample bounds the gather clamps to; the default never clamps.
		var sample_min := -Vector3i.ONE
		var sample_max := Vector3i.ONE * (VoxelChunk.SIZE + 1)
		if not infinite and not outside_faces:
			# Repeating the boundary samples outward leaves no sign change, so no surface, there.
			var origin := coord * VoxelChunk.SIZE
			sample_min = sample_min.max(-origin)
			sample_max = sample_max.min(_world_size() * VoxelChunk.SIZE - Vector3i.ONE - origin)
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
func _generate_chunk(task: ChunkTask, generator_snapshot: VoxelGenerator,
		storage_snapshot: VoxelStorage, coord: Vector3i) -> void:
	if task.cancelled:
		return
	if storage_snapshot != null:
		task.result = storage_snapshot.load_chunk(coord)
		task.loaded = task.result != null
	if task.loaded:
		return
	if generator_snapshot != null:
		task.result = generator_snapshot.generate(coord)
	else:
		task.result = VoxelChunk.new()


# Worker thread: must not touch members. Gets copy-on-write sample arrays, not the chunks, because
# a reclaimed chunk can be edited on the main thread while this runs.
func _save_chunks(storage_snapshot: VoxelStorage, coords: Array[Vector3i],
		chunk_densities: Array[PackedByteArray], chunk_types: Array[PackedByteArray]) -> void:
	for index in coords.size():
		storage_snapshot.save_chunk(coords[index], chunk_densities[index], chunk_types[index])


# Worker thread: must not touch members. The arrays hold the 3x3x3 chunks around the meshed chunk,
# x fastest; they are copy-on-write snapshots, so set_voxel on the main thread cannot change them.
func _mesh_chunk(task: ChunkTask, chunk_densities: Array[PackedByteArray],
		chunk_types: Array[PackedByteArray], sample_min: Vector3i, sample_max: Vector3i) -> void:
	if task.cancelled:
		return
	# Per axis and padded coordinate (chunk-local -1..SIZE+1, clamped): the source neighbour's
	# contribution to its 0..26 index, and the source sample's to its sample_index.
	var neighbour_parts: Array[PackedInt32Array] = []
	var sample_parts: Array[PackedInt32Array] = []
	for axis in 3:
		var neighbour_part := PackedInt32Array()
		var sample_part := PackedInt32Array()
		for padded in MarchingCubes.PADDED:
			var local := clampi(padded - 1, sample_min[axis], sample_max[axis])
			var offset := floori(float(local) / VoxelChunk.SIZE)
			neighbour_part.append((offset + 1) * 3 ** axis)
			sample_part.append((local - offset * VoxelChunk.SIZE) * VoxelChunk.SIZE ** axis)
		neighbour_parts.append(neighbour_part)
		sample_parts.append(sample_part)
	var densities := PackedByteArray()
	densities.resize(MarchingCubes.PADDED ** 3)
	var types := PackedByteArray()
	types.resize(MarchingCubes.PADDED ** 3)
	# Same order as MarchingCubes.padded_index, so the index just counts up.
	var padded_index := 0
	for z in MarchingCubes.PADDED:
		for y in MarchingCubes.PADDED:
			var row_neighbour := neighbour_parts[1][y] + neighbour_parts[2][z]
			var row_sample := sample_parts[1][y] + sample_parts[2][z]
			for x in MarchingCubes.PADDED:
				var neighbour := row_neighbour + neighbour_parts[0][x]
				var index := row_sample + sample_parts[0][x]
				densities[padded_index] = chunk_densities[neighbour][index]
				types[padded_index] = chunk_types[neighbour][index]
				padded_index += 1
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


# True when every chunk is entirely density: no ISO crossing, so no surface. A clamped gather
# (outside_faces off) reads a subset of these chunks, so it holds there too.
func _is_uniform(chunk_densities: Array[PackedByteArray], density: int) -> bool:
	for densities in chunk_densities:
		if densities.count(density) != VoxelChunk.VOLUME:
			return false
	return true


# The palette chunk type bytes index: the model's in contained worlds, so a model asset brings its
# types along (D-27).
func get_voxel_types() -> Array[VoxelType]:
	if infinite:
		return voxel_types
	if model == null:
		var none: Array[VoxelType] = []
		return none
	return model.voxel_types


# Connects the active types' changed signals to _update_textures and repacks the textures.
func _watch_types() -> void:
	for voxel_type in _watched_types:
		voxel_type.changed.disconnect(_update_textures)
	_watched_types.clear()
	for voxel_type in get_voxel_types():
		if voxel_type != null:
			# Reference counted: the same type may be listed twice.
			voxel_type.changed.connect(_update_textures, CONNECT_REFERENCE_COUNTED)
			_watched_types.append(voxel_type)
	_update_textures()


# Packs the type textures into the Texture2DArray layers the shader indexes by type.
func _update_textures() -> void:
	var types := get_voxel_types()
	if types.is_empty():
		return
	# Inspector edits pass through empty slots and types without a texture; wait until complete.
	for voxel_type in types:
		if voxel_type == null or voxel_type.texture == null:
			return
	var size := types[0].texture.get_size()
	var images: Array[Image] = []
	for voxel_type in types:
		var image := voxel_type.texture.get_image()
		if image.is_compressed():
			image.decompress()
		image.convert(Image.FORMAT_RGBA8)
		image.resize(int(size.x), int(size.y))
		image.generate_mipmaps()
		images.append(image)
	var textures := Texture2DArray.new()
	textures.create_from_images(images)
	_material.set_shader_parameter(&"type_textures", textures)


func _has_neighbourhood(coord: Vector3i) -> bool:
	for z in range(-1, 2):
		for y in range(-1, 2):
			for x in range(-1, 2):
				var neighbour := coord + Vector3i(x, y, z)
				if not _chunks.has(neighbour) and not _is_outside_world(neighbour):
					return false
	return true


func _get_chunk(coord: Vector3i) -> VoxelChunk:
	if _chunks.has(coord):
		return _chunks[coord]
	var chunk := _reclaim(coord)
	if chunk == null and _storage_snapshot != null:
		chunk = _storage_snapshot.load_chunk(coord)
	if chunk == null:
		if generator != null and procedural:
			chunk = generator.generate(coord)
		else:
			chunk = VoxelChunk.new()
	_chunks[coord] = chunk
	return chunk


# An unloaded chunk whose save has not finished is taken back, not reloaded stale from storage.
# Marked edited, since it may carry edits that a rebuild must not drop.
func _reclaim(coord: Vector3i) -> VoxelChunk:
	var chunk: VoxelChunk = _save_queue.get(coord, _saving.get(coord))
	if chunk != null:
		_save_queue.erase(coord)
		_unsaved[coord] = true
	return chunk


# Writes unsaved chunks now: all, or only edited ones. Without storage it only warns.
func _flush(edited_only: bool) -> void:
	if _save_task != null:
		WorkerThreadPool.wait_for_task_completion(_save_task.id)
		_save_task = null
		_saving.clear()
	var coords: Array[Vector3i] = []
	for coord in _unsaved:
		if _unsaved[coord] or not edited_only:
			coords.append(coord)
	if _storage_snapshot == null:
		if not coords.is_empty():
			push_warning("VoxelTerrain: no storage directory selected; %d chunks were not saved."
				% coords.size())
		return
	for coord in _save_queue:
		_storage_snapshot.save_chunk(coord, _save_queue[coord].densities, _save_queue[coord].types)
	_save_queue.clear()
	for coord in coords:
		_storage_snapshot.save_chunk(coord, _chunks[coord].densities, _chunks[coord].types)
		_unsaved.erase(coord)


# Contained only: chunks along each axis, from the model (zero until the first rebuild creates it).
func _world_size() -> Vector3i:
	return model.world_size if model != null else Vector3i.ZERO


# Chunks that get a mesh are [_mesh_begin(), _mesh_end()) per axis.
func _mesh_begin() -> Vector3i:
	if infinite:
		return _center - chunk_extent
	# The closing faces on the low sides lie in the last cells of chunk -1 (cells span sample n..n+1).
	return -Vector3i.ONE if outside_faces else Vector3i.ZERO


func _mesh_end() -> Vector3i:
	return _center + chunk_extent if infinite else _world_size()


func _is_meshed(coord: Vector3i) -> bool:
	return _is_in_box(coord, _mesh_begin(), _mesh_end())


# Chunks whose data is kept in _chunks.
func _is_loaded(coord: Vector3i) -> bool:
	if infinite:
		# One chunk past the meshed range: meshes read their neighbours' samples (INV-7).
		return _is_in_box(coord, _mesh_begin() - Vector3i.ONE, _mesh_end() + Vector3i.ONE)
	return _is_in_box(coord, Vector3i.ZERO, _world_size())


func _is_outside_world(coord: Vector3i) -> bool:
	return not infinite and not _is_in_box(coord, Vector3i.ZERO, _world_size())


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
