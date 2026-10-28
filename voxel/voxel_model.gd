@tool
class_name VoxelModel
extends VoxelStorage
# OWNS:       A contained terrain's chunks in one resource: built into the scene or a reusable asset.
# DEPENDS:    VoxelChunk (encode, decode)
# INVARIANTS: chunks holds VoxelChunk.encode payloads, the bytes a region file stores (INV-9).
#             Coordinates are chunk coordinates from the terrain's origin.
# GOTCHAS:    Workers read while the main thread writes, so _mutex guards chunks. VoxelTerrain writes
#             here directly (no copy); an asset file is only written on editor scene save.

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
