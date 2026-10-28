@tool
class_name VoxelModel
extends VoxelStorage
# OWNS:       A contained world in one resource (size, types, chunks): built into the scene or a
#             reusable asset.
# DEPENDS:    VoxelChunk (encode, decode), VoxelType
# INVARIANTS: chunks holds VoxelChunk.encode payloads, the bytes a region file stores (INV-9).
#             Coordinates are chunk coordinates from the terrain's origin. Chunk type bytes index
#             voxel_types, so the palette travels with the data (D-27).
# GOTCHAS:    Workers read while the main thread writes, so _mutex guards chunks. VoxelTerrain
#             writes here directly (no copy); an asset file is only written on editor scene save.
#             changed is emitted for world_size and voxel_types only (VoxelTerrain rebuilds on it),
#             never for chunk writes.

# Chunks along x, y, z from the terrain's origin.
@export var world_size := Vector3i(4, 2, 4):
	set(value):
		world_size = value
		emit_changed()

@export var voxel_types: Array[VoxelType] = []:
	set(value):
		voxel_types = value
		emit_changed()

@export_storage var chunks: Dictionary[Vector3i, PackedByteArray] = {}

var _mutex := Mutex.new()


func load_chunk(coord: Vector3i) -> VoxelChunk:
	_mutex.lock()
	var payload: PackedByteArray = chunks.get(coord, PackedByteArray())
	_mutex.unlock()
	if payload.is_empty():
		return null
	return VoxelChunk.decode(payload)


func save_chunk(coord: Vector3i, densities: PackedByteArray, types: PackedByteArray) -> void:
	var payload := VoxelChunk.encode(densities, types)
	_mutex.lock()
	chunks[coord] = payload
	_mutex.unlock()
