@tool
class_name VoxelChunk
extends Resource
# OWNS:       Density and voxel type samples of one chunk (SIZE^3, one sample per world unit).
# DEPENDS:    nothing
# INVARIANTS: densities and types both hold SIZE^3 entries laid out by sample_index (see INV-7).
#             density > 0 is solid, <= 0 is air; the surface is the 0 crossing.
# GOTCHAS:    @tool because VoxelTerrain creates chunks in the editor. A chunk owns samples
#             0..SIZE-1 per axis only; meshing reads one sample past them on each side (INV-7), so
#             edits near a chunk border change neighbour meshes too.

enum Type { DIRT, GRASS, STONE }

const SIZE := 16

@export_storage var densities := PackedFloat32Array()
@export_storage var types := PackedByteArray()


func _init() -> void:
	densities.resize(SIZE * SIZE * SIZE)
	densities.fill(-1.0)
	types.resize(SIZE * SIZE * SIZE)


static func sample_index(local: Vector3i) -> int:
	return local.x + local.y * SIZE + local.z * SIZE * SIZE
