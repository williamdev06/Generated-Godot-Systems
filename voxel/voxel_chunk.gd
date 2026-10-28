@tool
class_name VoxelChunk
extends Resource
# OWNS:       Density and voxel type samples of one chunk (SIZE^3, one sample per world unit).
# DEPENDS:    nothing
# INVARIANTS: densities and types are both empty (all air) or both hold VOLUME entries laid out by
#             sample_index (see INV-7). Density byte 0..255 is 0.0..1.0; above ISO (0.5) is solid,
#             0 is empty; the surface is the ISO crossing (D-23). A type is an index into
#             VoxelTerrain.get_voxel_types(). encode/decode is the only saved form (INV-9).
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


# The saved form every VoxelStorage uses (D-26): a flag byte (0 all air, 1 samples follow), then
# for 1 the densities and types (2 * VOLUME bytes) zstd-compressed. Changing it orphans saves.
static func encode(densities: PackedByteArray, types: PackedByteArray) -> PackedByteArray:
	var payload := PackedByteArray([0])
	if not densities.is_empty():
		payload[0] = 1
		payload.append_array((densities + types).compress(FileAccess.COMPRESSION_ZSTD))
	return payload


static func decode(payload: PackedByteArray) -> VoxelChunk:
	var chunk := VoxelChunk.new()
	if payload[0] == 1:
		var samples := payload.slice(1).decompress(2 * VOLUME, FileAccess.COMPRESSION_ZSTD)
		chunk.densities = samples.slice(0, VOLUME)
		chunk.types = samples.slice(VOLUME)
	return chunk
