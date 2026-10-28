@tool
class_name VoxelGenerator
extends Resource
# OWNS:       Procedural density and voxel type for a chunk.
# DEPENDS:    FastNoiseLite, VoxelChunk
# INVARIANTS: generate() is a pure function of chunk coordinate and noise, so regenerated chunks
#             match the ones they replace and chunk borders stay seamless.
# GOTCHAS:    Raw density is noise * HEIGHT - y, so its vertical gradient is about 1 per unit and it
#             approximates the depth below the surface used to pick the type. Overhang undersides
#             therefore also get grass. Stored as 128 + raw * 128 / VoxelChunk.BAND clamped to a
#             byte (D-23): meshing and normals read at most 2 units from the surface, well inside
#             BAND. Chunks entirely beyond the band skip the noise, assuming |noise| <= 1
#             (UNVERIFIED for every FastNoiseLite noise type).

# Indices into VoxelTerrain.get_voxel_types(), which must list the types in this order.
enum Type { DIRT, GRASS, STONE }

const HEIGHT := 24.0

@export var noise := FastNoiseLite.new():
	set(value):
		if noise != null:
			noise.changed.disconnect(emit_changed)
		noise = value
		if noise != null:
			noise.changed.connect(emit_changed)
		emit_changed()


func _init() -> void:
	# Member initializers bypass the setter, so the default noise is connected here.
	noise.changed.connect(emit_changed)


func generate(coord: Vector3i) -> VoxelChunk:
	var chunk := VoxelChunk.new()
	var origin := coord * VoxelChunk.SIZE
	if origin.y >= HEIGHT + VoxelChunk.BAND:
		return chunk
	# Filled as locals: indexing chunk.densities directly copies the whole array on every write.
	var densities := PackedByteArray()
	densities.resize(VoxelChunk.VOLUME)
	var types := PackedByteArray()
	types.resize(VoxelChunk.VOLUME)
	if origin.y + VoxelChunk.SIZE - 1 <= -HEIGHT - VoxelChunk.BAND:
		densities.fill(255)
		types.fill(Type.STONE)
	else:
		# Same order as VoxelChunk.sample_index, so the index just counts up.
		var index := 0
		for z in range(origin.z, origin.z + VoxelChunk.SIZE):
			for y in range(origin.y, origin.y + VoxelChunk.SIZE):
				for x in range(origin.x, origin.x + VoxelChunk.SIZE):
					var raw := noise.get_noise_3d(x, y, z) * HEIGHT - y
					densities[index] = clampi(floori(128.0 + raw * 128.0 / VoxelChunk.BAND), 0, 255)
					if raw < 1.0:
						types[index] = Type.GRASS
					elif raw < 5.0:
						types[index] = Type.DIRT
					else:
						types[index] = Type.STONE
					index += 1
		if densities.count(0) == VoxelChunk.VOLUME:
			return chunk
	chunk.densities = densities
	chunk.types = types
	return chunk
