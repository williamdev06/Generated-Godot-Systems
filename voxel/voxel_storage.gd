@tool
class_name VoxelStorage
extends Resource
# OWNS:       The interface VoxelTerrain saves and loads chunks through.
# DEPENDS:    VoxelChunk
# INVARIANTS: Implementations store VoxelChunk.encode payloads (INV-9) and lock internally: both
#             methods are called from worker threads and the main thread at once.
# GOTCHAS:    Implemented by VoxelRegionStorage (infinite) and VoxelModel (contained).


# Null when the chunk was never saved.
func load_chunk(_coord: Vector3i) -> VoxelChunk:
	return null


# Empty arrays save an all-air chunk.
func save_chunk(_coord: Vector3i, _densities: PackedByteArray, _types: PackedByteArray) -> void:
	pass
