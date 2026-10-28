@tool
class_name VoxelChunk
extends Resource
# OWNS:       Density and voxel type samples of one chunk (SIZE^3, one sample per world unit).
# DEPENDS:    nothing
# INVARIANTS: densities and types are both empty (all air) or both hold VOLUME entries laid out by
#             sample_index (see INV-7). Density byte 0..255 is 0.0..1.0; above ISO (0.5) is solid,
#             0 is empty; the surface is the ISO crossing (D-23). A type is an index into
#             VoxelTerrain.voxel_types.
# GOTCHAS:    @tool because VoxelTerrain creates chunks in the editor. A chunk owns samples
#             0..SIZE-1 per axis only; meshing reads one sample past them on each side (INV-7), so
#             edits near a chunk border change neighbour meshes too.

const SIZE := 16
const VOLUME := SIZE * SIZE * SIZE
# Between two byte values, so the surface never passes exactly through a sample.
const ISO := 127.5
# Density 0.0..1.0 spans signed distance -BAND..BAND below the surface, so distance-based writers
# (VoxelGenerator, editor sculpting) produce the same gradients.
const BAND := 8.0

@export_storage var densities := PackedByteArray()
@export_storage var types := PackedByteArray()


static func sample_index(local: Vector3i) -> int:
	return local.x + local.y * SIZE + local.z * SIZE * SIZE
