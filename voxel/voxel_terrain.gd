@tool
class_name VoxelTerrain
extends Node3D
# OWNS:       The 3D chunk grid, infinite (streamed around the camera, optionally with coarse LOD
#             rings) or contained: threaded generation and meshing, trimesh collision, edits, density
#             field queries.
# DEPENDS:    VoxelChunk, VoxelGenerator, MarchingCubes, VoxelType, VoxelStorage (VoxelRegionStorage,
#             VoxelModel), voxel_terrain.gdshader, WorkerThreadPool, physics (StaticBody3D)
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
#             Collision (D-28): each chunk MeshInstance3D has exactly one child chain,
#             StaticBody3D > CollisionShape3D (ConcavePolygonShape3D of the mesh triangles),
#             built in the editor too. The shape is created on the main thread (physics server
#             calls are not thread-safe without physics/3d/run_on_separate_thread); faces on the
#             worker. Density field queries (sample_density, get_normal, raycast, push_out) are
#             terrain-local like set_voxel and main thread only. Unlike get_density they also read
#             chunks that are not loaded, loading or generating them synchronously (one chunk is
#             thousands of noise samples); in infinite worlds those stay until the next _refresh
#             unloads them. Before the first (deferred) rebuild they see no storage or model, so
#             spawn queries from _ready must be deferred. Trilinear density matches the mesh along
#             cell edges only.
#             LOD (D-29..D-31, infinite with lod_extents only): coarse chunks hold no data; each mesh
#             task samples the generator, overridden by loaded LOD 0 chunks within reach (INV-11),
#             and builds transition cells on all 6 faces. The shader shows a face's transition only
#             while transition_mask says the space across it is shown one LOD finer. Coarse chunks
#             have no collision. A layout change keeps the chunks it dropped (_outgoing) visible
#             until everything replacing them has a mesh result, hiding those results meanwhile.

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

# Infinite only: coarse rings around the chunk_extent box, one per entry, each at half the
# resolution of the one inside it (LOD n chunks are 2^n times wider). An entry is the ring's half
# size in its own chunks. With rings, every extent (chunk_extent too) is raised to an even count of
# at least half the extent inside + 2, so rings nest on whole chunks (D-29). Empty: no LOD.
@export var lod_extents: Array[Vector3i] = []:
	set(value):
		lod_extents = value
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

# Physics layers of the chunk trimesh bodies.
@export_flags_3d_physics var collision_layer := 1:
	set(value):
		collision_layer = value
		for mesh_instance in _meshes.values():
			if mesh_instance != null:
				(mesh_instance.get_child(0) as StaticBody3D).collision_layer = value

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

# sample_density above this is solid.
const ISO_DENSITY := VoxelChunk.ISO / 255.0
# Neighbour direction per face, in MarchingCubes face order.
const DIRECTIONS: Array[Vector3i] = [
	Vector3i.LEFT, Vector3i.RIGHT, Vector3i.DOWN, Vector3i.UP, Vector3i.FORWARD, Vector3i.BACK]

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
# Box half sizes per LOD after the nesting rules (_ring_extents); just [chunk_extent] without rings.
var _extents: Array[Vector3i] = []
# Coarse chunk meshes keyed (x, y, z, lod) in that LOD's chunk coordinates (VoxelChunk.SIZE * 2^lod
# units). A null value marks a chunk without surface, like _meshes.
var _lod_meshes: Dictionary[Vector4i, MeshInstance3D] = {}
# Coarse chunks waiting for a mesh task, nearest first.
var _lod_queue: Dictionary[Vector4i, bool] = {}
var _lod_tasks: Dictionary[Vector4i, ChunkTask] = {}
# Chunks of any LOD (LOD 0 keyed with lod 0) the layout dropped while shown; kept until covered.
var _outgoing: Dictionary[Vector4i, bool] = {}
# Per coarser chunk, how many outgoing chunks lie inside it, for _is_overlapped.
var _outgoing_inside: Dictionary[Vector4i, int] = {}
# Chunks with a mesh result kept hidden while an outgoing chunk overlaps them.
var _hidden: Dictionary[Vector4i, bool] = {}
# Coarse chunks whose transition_mask must be recomputed at the end of the frame.
var _mask_dirty: Dictionary[Vector4i, bool] = {}
# LOD 0 chunks kept loaded at the last _refresh, [begin, end); coarse chunks reading them as
# overrides are remeshed when this moves.
var _loaded_begin := Vector3i.ZERO
var _loaded_end := Vector3i.ZERO


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
	_retire_outgoing()
	_update_masks()
	_start_tasks()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		for task in _generation_tasks.values():
			_cancel(task)
		for task in _mesh_tasks.values():
			_cancel(task)
		for task in _lod_tasks.values():
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
	# LOD 1 chunks next to the LOD 0 box read this chunk's samples (INV-11).
	if _extents.size() > 1:
		var lod_coord := _floor_div(coord, 2)
		for z in range(-1, 2):
			for y in range(-1, 2):
				for x in range(-1, 2):
					var key := Vector4i(lod_coord.x + x, lod_coord.y + y, lod_coord.z + z, 1)
					var reach := _lod_reach(key, coord, coord + Vector3i.ONE)
					if reach[0] != reach[1] and _is_lod_target(key) \
							and (_lod_meshes.has(key) or _lod_tasks.has(key)):
						_requeue_lod(key)


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


# Trilinear density (0.0..1.0) at a terrain-local point; solid above ISO_DENSITY.
func sample_density(point: Vector3) -> float:
	var base := Vector3i(point.floor())
	var fraction := point - Vector3(base)
	var density := 0.0
	for corner: Vector3i in MarchingCubes.CORNERS:
		var weights := Vector3(
			fraction.x if corner.x == 1 else 1.0 - fraction.x,
			fraction.y if corner.y == 1 else 1.0 - fraction.y,
			fraction.z if corner.z == 1 else 1.0 - fraction.z,
		)
		density += _sample(base + corner) * weights.x * weights.y * weights.z
	return density


# Outward unit normal (negative density gradient) at a terrain-local point. Zero where the field is
# flat: more than VoxelChunk.BAND from the surface, or inside uniformly authored solid.
func get_normal(point: Vector3) -> Vector3:
	var gradient := Vector3(
		sample_density(point + Vector3.RIGHT * 0.5) - sample_density(point + Vector3.LEFT * 0.5),
		sample_density(point + Vector3.UP * 0.5) - sample_density(point + Vector3.DOWN * 0.5),
		sample_density(point + Vector3.BACK * 0.5) - sample_density(point + Vector3.FORWARD * 0.5),
	)
	return -gradient.normalized()


# First surface crossing on the terrain-local segment from -> to as {position, normal}, position on
# the air side; {} if the segment stays in air. Starting inside solid hits at from.
func raycast(from: Vector3, to: Vector3) -> Dictionary:
	if sample_density(from) > ISO_DENSITY:
		return {"position": from, "normal": get_normal(from)}
	# Quarter-unit steps: whole-unit steps skip the thin solid where a ray clips a cell corner.
	var step_count := ceili(from.distance_to(to) * 4.0)
	var previous := from
	for step in range(1, step_count + 1):
		var current := from.lerp(to, float(step) / step_count)
		if sample_density(current) > ISO_DENSITY:
			var hit := _bisect(previous, current)
			return {"position": hit, "normal": get_normal(hit)}
		previous = current
	return {}


# Nearest air to a terrain-local point, for unstucking: the surface crossing toward the closest air
# sample within REACH, on the air side. Returns point unchanged if it is already in air or no air
# is that close. Searches samples rather than following the gradient, which is zero deep in solid.
func push_out(point: Vector3) -> Vector3:
	const REACH := 8
	if sample_density(point) <= ISO_DENSITY:
		return point
	var center := Vector3i(point.round())
	var nearest_air := point
	var nearest_distance := INF
	for z in range(-REACH, REACH + 1):
		for y in range(-REACH, REACH + 1):
			for x in range(-REACH, REACH + 1):
				var sample := center + Vector3i(x, y, z)
				var distance := point.distance_squared_to(Vector3(sample))
				if distance < nearest_distance and _sample(sample) <= ISO_DENSITY:
					nearest_air = Vector3(sample)
					nearest_distance = distance
	if nearest_distance == INF:
		return point
	return _bisect(nearest_air, point)


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
	for task in _lod_tasks.values():
		_cancel(task)
	_generation_tasks.clear()
	_mesh_tasks.clear()
	_lod_tasks.clear()
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
	_extents = _ring_extents()
	# LODs that no longer exist go at once.
	for key in _lod_meshes.keys():
		if key.w >= _extents.size():
			_free_mesh(key)
			_outgoing.erase(key)
			_hidden.erase(key)
	# Recounted, since which coarser chunks exist may have changed.
	_outgoing_inside.clear()
	for key in _outgoing.keys():
		_outgoing.erase(key)
		_add_outgoing(key)
	# Existing meshes stay visible until their replacement arrives, so a rebuild does not flicker.
	for coord in _meshes:
		_mesh_queue[coord] = true
	for key in _lod_meshes:
		_lod_queue[key] = true
	_refresh()


# Unloads what left the range and queues what entered it, nearest to _center first.
func _refresh() -> void:
	for key in _outgoing.keys():
		if _is_target(key):
			_remove_outgoing(key)
	for coord in _meshes.keys():
		if not _is_meshed(coord):
			_retire(Vector4i(coord.x, coord.y, coord.z, 0))
	for key in _lod_meshes.keys():
		if not _is_lod_target(key):
			_retire(key)
	for coord in _mesh_tasks.keys():
		if not _is_meshed(coord):
			_cancel(_mesh_tasks[coord])
			_mesh_tasks.erase(coord)
	for key in _lod_tasks.keys():
		if not _is_lod_target(key):
			_cancel(_lod_tasks[key])
			_lod_tasks.erase(key)
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
	if _extents.size() <= 1:
		return
	# Only LOD 1 reaches loaded chunks: LOD 2 starts a whole LOD 1 chunk past the LOD 0 box.
	var loaded_begin := _mesh_begin() - Vector3i.ONE
	var loaded_end := _mesh_end() + Vector3i.ONE
	if loaded_begin != _loaded_begin or loaded_end != _loaded_end:
		for key: Vector4i in _lod_meshes.keys() + _lod_tasks.keys():
			if key.w == 1 and _is_lod_target(key) and _lod_reach(key, _loaded_begin, _loaded_end) \
					!= _lod_reach(key, loaded_begin, loaded_end):
				_requeue_lod(key)
		_loaded_begin = loaded_begin
		_loaded_end = loaded_end
	var lod_keys := _lod_queue.keys().filter(_is_lod_target)
	for lod in range(1, _extents.size()):
		var lod_begin := _box_begin(lod)
		var lod_end := _box_end(lod)
		var hole_begin := _box_begin(lod - 1) / 2
		var hole_end := _box_end(lod - 1) / 2
		for z in range(lod_begin.z, lod_end.z):
			for y in range(lod_begin.y, lod_end.y):
				for x in range(lod_begin.x, lod_end.x):
					if _is_in_box(Vector3i(x, y, z), hole_begin, hole_end):
						continue
					var key := Vector4i(x, y, z, lod)
					if not _lod_meshes.has(key) and not _lod_tasks.has(key) and not _lod_queue.has(key):
						lod_keys.append(key)
	lod_keys.sort_custom(_is_nearer_lod)
	_lod_queue.clear()
	for key in lod_keys:
		_lod_queue[key] = true


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
	for key in _lod_tasks.keys():
		var task: ChunkTask = _lod_tasks[key]
		if _try_complete(task):
			_lod_tasks.erase(key)
			_apply_lod_mesh(key, task.result)


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
	var task_count := _abandoned_tasks.size() + _generation_tasks.size() + _mesh_tasks.size() \
		+ _lod_tasks.size()
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
	for key: Vector4i in _lod_queue.keys():
		if free_slots <= 0:
			return
		# Meshing before the loaded chunks it reads arrive would miss their edits (INV-11).
		if _lod_tasks.has(key) or not _has_lod_overrides(key):
			continue
		_lod_queue.erase(key)
		var task := ChunkTask.new()
		task.id = WorkerThreadPool.add_task(
			_mesh_lod_chunk.bind(task, _generator_snapshot, key, _lod_overrides(key)))
		_lod_tasks[key] = task
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
	var arrays := MarchingCubes.build_arrays(densities, types)
	# No surface leaves result null.
	if arrays.is_empty():
		return
	# ConcavePolygonShape3D takes one vertex per triangle corner, not indexed vertices.
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var faces := PackedVector3Array()
	faces.resize(indices.size())
	for index in indices.size():
		faces[index] = vertices[indices[index]]
	# Building the ArrayMesh here is safe: resources may be created off the main thread.
	task.result = [MarchingCubes.create_mesh(arrays), faces]


# result is null for a chunk without surface, else [ArrayMesh, collision faces].
func _apply_mesh(coord: Vector3i, result: Variant) -> void:
	var key := Vector4i(coord.x, coord.y, coord.z, 0)
	var placed := _meshes.has(coord)
	if result == null:
		if _meshes.get(coord) != null:
			_meshes[coord].queue_free()
		_meshes[coord] = null
	else:
		if _meshes.get(coord) == null:
			var mesh_instance := MeshInstance3D.new()
			mesh_instance.position = Vector3(coord * VoxelChunk.SIZE)
			mesh_instance.material_override = _material
			mesh_instance.visible = not _hidden.has(key)
			var body := StaticBody3D.new()
			body.collision_layer = collision_layer
			body.add_child(CollisionShape3D.new())
			mesh_instance.add_child(body)
			add_child(mesh_instance, false, Node.INTERNAL_MODE_BACK)
			_meshes[coord] = mesh_instance
		_meshes[coord].mesh = result[0]
		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(result[1])
		(_meshes[coord].get_child(0).get_child(0) as CollisionShape3D).shape = shape
	if not placed:
		_place(key)


# Worker thread: must not touch members. overrides: loaded LOD 0 chunks within reach, coord ->
# [densities, types] (INV-11).
func _mesh_lod_chunk(task: ChunkTask, generator_snapshot: VoxelGenerator, key: Vector4i,
		overrides: Dictionary) -> void:
	if task.cancelled:
		return
	var step := 1 << key.w
	var origin := _xyz(key) * VoxelChunk.SIZE * step
	var samples := _sample_grid(generator_snapshot, overrides, origin - Vector3i.ONE * step, step,
		Vector3i.ONE * MarchingCubes.PADDED)
	# Saturated everywhere means at least BAND * step from any surface, so the slabs are too.
	var volume := MarchingCubes.PADDED ** 3
	if samples[0].count(0) == volume or samples[0].count(255) == volume:
		return
	var slab_densities: Array[PackedByteArray] = []
	var slab_types: Array[PackedByteArray] = []
	# Transition cells read the finer LOD's samples: half the step, its band.
	var fine_step := step >> 1
	for face in 6:
		var slab := _sample_grid(generator_snapshot, overrides,
			origin + MarchingCubes.slab_origin(face) * fine_step, fine_step, MarchingCubes.slab_size(face))
		slab_densities.append(slab[0])
		slab_types.append(slab[1])
	if task.cancelled:
		return
	var arrays := MarchingCubes.build_arrays(samples[0], samples[1], slab_densities, slab_types)
	# No surface leaves result null.
	if not arrays.is_empty():
		task.result = MarchingCubes.create_mesh(arrays)


# Worker thread. [densities, types] of size samples step units apart from terrain-local origin, x
# fastest: the generator's (air without one), except samples inside overrides chunks, which take the
# loaded value rescaled to the grid's band. The rescale keeps which samples are solid (INV-11).
static func _sample_grid(generator_snapshot: VoxelGenerator, overrides: Dictionary, origin: Vector3i,
		step: int, size: Vector3i) -> Array[PackedByteArray]:
	var densities := PackedByteArray()
	var types := PackedByteArray()
	if generator_snapshot != null:
		var generated := generator_snapshot.generate_grid(origin, step, size)
		densities = generated[0]
		types = generated[1]
	else:
		densities.resize(size.x * size.y * size.z)
		densities.fill(0)
		types.resize(densities.size())
		types.fill(0)
	if overrides.is_empty():
		return [densities, types]
	var index := 0
	for z in size.z:
		for y in size.y:
			for x in size.x:
				var world := origin + Vector3i(x, y, z) * step
				var coord := _chunk_coord(world)
				if overrides.has(coord):
					var source_densities: PackedByteArray = overrides[coord][0]
					var source_types: PackedByteArray = overrides[coord][1]
					if source_densities.is_empty():
						densities[index] = 0
						types[index] = 0
					else:
						var sample := VoxelChunk.sample_index(world - coord * VoxelChunk.SIZE)
						densities[index] = 128 + floori((source_densities[sample] - 128) / float(step))
						types[index] = source_types[sample]
				index += 1
	return [densities, types]


# result is null for a coarse chunk without surface, else its ArrayMesh.
func _apply_lod_mesh(key: Vector4i, result: Variant) -> void:
	var placed := _lod_meshes.has(key)
	if result == null:
		if _lod_meshes.get(key) != null:
			_lod_meshes[key].queue_free()
		_lod_meshes[key] = null
	else:
		if _lod_meshes.get(key) == null:
			var step := 1 << key.w
			var mesh_instance := MeshInstance3D.new()
			mesh_instance.position = Vector3(_xyz(key) * VoxelChunk.SIZE * step)
			# Vertices stay in cells, which the shader's transition offsets rely on (INV-12).
			mesh_instance.scale = Vector3.ONE * step
			mesh_instance.material_override = _material
			mesh_instance.visible = not _hidden.has(key)
			add_child(mesh_instance, false, Node.INTERNAL_MODE_BACK)
			_lod_meshes[key] = mesh_instance
			_mask_dirty[key] = true
		_lod_meshes[key].mesh = result
	if not placed:
		_place(key)


# A chunk got its first mesh result: hidden while an outgoing chunk still shows its space.
func _place(key: Vector4i) -> void:
	if _is_overlapped(key):
		_hidden[key] = true
		_set_visible(key, false)
	else:
		_visibility_changed(key)


# A shown chunk the layout dropped stays until its space is covered; a hidden one goes at once.
func _retire(key: Vector4i) -> void:
	if _hidden.has(key):
		_hidden.erase(key)
		_free_mesh(key)
	elif not _outgoing.has(key):
		_add_outgoing(key)


# Frees outgoing chunks whose space the layout has fully meshed, then shows what they hid. Both
# happen in the same frame, so nothing flickers.
func _retire_outgoing() -> void:
	var retired := false
	for key in _outgoing.keys():
		if _is_covered(key):
			_remove_outgoing(key)
			_free_mesh(key)
			_visibility_changed(key)
			retired = true
	if not retired:
		return
	for key in _hidden.keys():
		if not _is_overlapped(key):
			_hidden.erase(key)
			_set_visible(key, true)
			_visibility_changed(key)


# True when every chunk of the current layout inside key's space has a mesh result, with or
# without surface. Boxes nest on whole chunks of the next LOD (D-29), so key's space is either
# inside one coarser layout chunk or splits into its 8 children.
func _is_covered(key: Vector4i) -> bool:
	if _is_target(key):
		return _meshes.has(_xyz(key)) if key.w == 0 else _lod_meshes.has(key)
	if key.w > 0 and _is_in_box(_xyz(key), _box_begin(key.w - 1) / 2, _box_end(key.w - 1) / 2):
		for child in 8:
			var offset := Vector3i(child & 1, child >> 1 & 1, child >> 2)
			var child_coord := _xyz(key) * 2 + offset
			if not _is_covered(Vector4i(child_coord.x, child_coord.y, child_coord.z, key.w - 1)):
				return false
		return true
	# Outside every box: nothing replaces it.
	if key.w + 1 >= _extents.size():
		return true
	var parent := _floor_div(_xyz(key), 2)
	return _is_covered(Vector4i(parent.x, parent.y, parent.z, key.w + 1))


func _add_outgoing(key: Vector4i) -> void:
	_outgoing[key] = true
	var coord := _xyz(key)
	for lod in range(key.w + 1, _extents.size()):
		coord = _floor_div(coord, 2)
		var parent := Vector4i(coord.x, coord.y, coord.z, lod)
		_outgoing_inside[parent] = _outgoing_inside.get(parent, 0) + 1


func _remove_outgoing(key: Vector4i) -> void:
	_outgoing.erase(key)
	var coord := _xyz(key)
	for lod in range(key.w + 1, _extents.size()):
		coord = _floor_div(coord, 2)
		var parent := Vector4i(coord.x, coord.y, coord.z, lod)
		_outgoing_inside[parent] -= 1
		if _outgoing_inside[parent] == 0:
			_outgoing_inside.erase(parent)


# Whether an outgoing chunk shares space with key: lies inside it or encloses it.
func _is_overlapped(key: Vector4i) -> bool:
	if _outgoing_inside.has(key) or _outgoing.has(key):
		return true
	var coord := _xyz(key)
	for lod in range(key.w + 1, _extents.size()):
		coord = _floor_div(coord, 2)
		if _outgoing.has(Vector4i(coord.x, coord.y, coord.z, lod)):
			return true
	return false


func _free_mesh(key: Vector4i) -> void:
	var node := _node(key)
	if node != null:
		node.queue_free()
	if key.w == 0:
		_meshes.erase(_xyz(key))
	else:
		_lod_meshes.erase(key)


func _node(key: Vector4i) -> MeshInstance3D:
	return _meshes.get(_xyz(key)) if key.w == 0 else _lod_meshes.get(key)


func _set_visible(key: Vector4i, visible: bool) -> void:
	var node := _node(key)
	if node != null:
		node.visible = visible


# Shown or no longer shown: its own transition mask and those of coarser chunks across its faces
# may change.
func _visibility_changed(key: Vector4i) -> void:
	if key.w > 0:
		_mask_dirty[key] = true
	var coord := _xyz(key)
	var parent := _floor_div(coord, 2)
	for direction in DIRECTIONS:
		var coarse := _floor_div(coord + direction, 2)
		if coarse != parent:
			_mask_dirty[Vector4i(coarse.x, coarse.y, coarse.z, key.w + 1)] = true


func _update_masks() -> void:
	for key in _mask_dirty:
		var node: MeshInstance3D = _lod_meshes.get(key)
		if node != null:
			node.set_instance_shader_parameter(&"transition_mask", _transition_mask(key))
	_mask_dirty.clear()


# Faces (MarchingCubes order) of a coarse chunk across which the space is shown one LOD finer. Only
# the finer chunk touching this face's first cell is checked: they are shown or hidden together.
func _transition_mask(key: Vector4i) -> int:
	var mask := 0
	for face in 6:
		var child := (_xyz(key) + DIRECTIONS[face]) * 2
		# Of the neighbour's two child layers along the axis, the one next to this chunk.
		if (face & 1) == 0:
			child[face >> 1] += 1
		var child_key := Vector4i(child.x, child.y, child.z, key.w - 1)
		var shown := _meshes.has(child) if key.w == 1 else _lod_meshes.has(child_key)
		if shown and not _hidden.has(child_key):
			mask |= 1 << face
	return mask


# Coarse chunk key is part of the current layout: inside its LOD's box, outside the finer one.
func _is_lod_target(key: Vector4i) -> bool:
	if key.w >= _extents.size():
		return false
	var coord := _xyz(key)
	return _is_in_box(coord, _box_begin(key.w), _box_end(key.w)) \
		and not _is_in_box(coord, _box_begin(key.w - 1) / 2, _box_end(key.w - 1) / 2)


func _is_target(key: Vector4i) -> bool:
	return _is_meshed(_xyz(key)) if key.w == 0 else _is_lod_target(key)


func _requeue_lod(key: Vector4i) -> void:
	if _lod_tasks.has(key):
		_cancel(_lod_tasks[key])
		_lod_tasks.erase(key)
	_lod_queue[key] = true


# LOD 0 chunks inside [begin, end) that coarse chunk key samples, as [begin, end), both zero when
# none. Its padded grid reaches one coarse step past the chunk; the slabs stay within that.
func _lod_reach(key: Vector4i, begin: Vector3i, end: Vector3i) -> Array[Vector3i]:
	var step := 1 << key.w
	var origin := _xyz(key) * VoxelChunk.SIZE * step
	var reach_begin := _chunk_coord(origin - Vector3i.ONE * step).max(begin)
	var reach_end := (_chunk_coord(origin + Vector3i.ONE * (VoxelChunk.SIZE + 1) * step)
		+ Vector3i.ONE).min(end)
	if reach_begin.x >= reach_end.x or reach_begin.y >= reach_end.y or reach_begin.z >= reach_end.z:
		return [Vector3i.ZERO, Vector3i.ZERO]
	return [reach_begin, reach_end]


func _has_lod_overrides(key: Vector4i) -> bool:
	var reach := _lod_reach(key, _loaded_begin, _loaded_end)
	for z in range(reach[0].z, reach[1].z):
		for y in range(reach[0].y, reach[1].y):
			for x in range(reach[0].x, reach[1].x):
				if not _chunks.has(Vector3i(x, y, z)):
					return false
	return true


# Loaded chunks coarse chunk key samples, coord -> [densities, types]; copy-on-write snapshots for
# the worker, as in _start_tasks.
func _lod_overrides(key: Vector4i) -> Dictionary:
	var overrides := {}
	var reach := _lod_reach(key, _loaded_begin, _loaded_end)
	for z in range(reach[0].z, reach[1].z):
		for y in range(reach[0].y, reach[1].y):
			for x in range(reach[0].x, reach[1].x):
				var chunk: VoxelChunk = _chunks[Vector3i(x, y, z)]
				overrides[Vector3i(x, y, z)] = [chunk.densities, chunk.types]
	return overrides


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
		# Not from storage, so it must be written (class INVARIANTS), as in _finish_tasks.
		_unsaved[coord] = false
	_chunks[coord] = chunk
	return chunk


# 0.0..1.0 density of one sample, loading or generating its chunk if needed; air outside a
# contained world.
func _sample(world: Vector3i) -> float:
	var coord := _chunk_coord(world)
	if _is_outside_world(coord):
		return 0.0
	var chunk := _get_chunk(coord)
	if chunk.densities.is_empty():
		return 0.0
	return chunk.densities[VoxelChunk.sample_index(world - coord * VoxelChunk.SIZE)] / 255.0


# Air side of the surface between an air point and a solid point, to 1/256 of their distance.
func _bisect(air: Vector3, solid: Vector3) -> Vector3:
	for iteration in 8:
		var middle := air.lerp(solid, 0.5)
		if sample_density(middle) > ISO_DENSITY:
			solid = middle
		else:
			air = middle
	return air


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


# Box half sizes per LOD, [0] for LOD 0, made to nest (D-29): even, so each box is whole chunks of
# the next LOD, and at least half the box inside + 2, so the next LOD's box keeps a whole chunk
# around it wherever the camera is and chunks only border chunks one LOD apart.
func _ring_extents() -> Array[Vector3i]:
	var extents: Array[Vector3i] = [chunk_extent]
	if not infinite or lod_extents.is_empty():
		return extents
	extents[0] = chunk_extent + chunk_extent % 2
	for extent in lod_extents:
		var nested := extent.max(extents[-1] / 2 + Vector3i.ONE * 2)
		extents.append(nested + nested % 2)
	return extents


# Infinite: the box of LOD lod in its chunk coordinates is [_box_begin(lod), _box_end(lod)). With
# rings it is centred on the camera snapped to the next LOD's chunks, so it is whole chunks of it.
func _box_begin(lod: int) -> Vector3i:
	if _extents.size() <= 1:
		return _center - chunk_extent
	return _floor_div(_center, 2 << lod) * 2 - _extents[lod]


func _box_end(lod: int) -> Vector3i:
	if _extents.size() <= 1:
		return _center + chunk_extent
	return _floor_div(_center, 2 << lod) * 2 + _extents[lod]


# Chunks that get a mesh are [_mesh_begin(), _mesh_end()) per axis.
func _mesh_begin() -> Vector3i:
	if infinite:
		return _box_begin(0)
	# The closing faces on the low sides lie in the last cells of chunk -1 (cells span sample n..n+1).
	return -Vector3i.ONE if outside_faces else Vector3i.ZERO


func _mesh_end() -> Vector3i:
	return _box_end(0) if infinite else _world_size()


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


# By chunk centre distance to the camera's chunk centre, in LOD 0 chunks.
func _is_nearer_lod(a: Vector4i, b: Vector4i) -> bool:
	return _lod_distance(a) < _lod_distance(b)


func _lod_distance(key: Vector4i) -> float:
	var size := float(1 << key.w)
	return ((Vector3(_xyz(key)) + Vector3.ONE * 0.5) * size - Vector3(_center) - Vector3.ONE * 0.5) \
		.length_squared()


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


static func _xyz(key: Vector4i) -> Vector3i:
	return Vector3i(key.x, key.y, key.z)


static func _floor_div(value: Vector3i, divisor: int) -> Vector3i:
	return Vector3i(
		floori(float(value.x) / divisor),
		floori(float(value.y) / divisor),
		floori(float(value.z) / divisor),
	)


static func _chunk_coord(world: Vector3i) -> Vector3i:
	return Vector3i(
		floori(float(world.x) / VoxelChunk.SIZE),
		floori(float(world.y) / VoxelChunk.SIZE),
		floori(float(world.z) / VoxelChunk.SIZE),
	)
