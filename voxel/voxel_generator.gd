@tool
class_name VoxelGenerator
extends Resource
# OWNS:       Procedural density and voxel type for chunks and coarse LOD grids.
# DEPENDS:    FastNoiseLite, VoxelChunk
# INVARIANTS: generate() and generate_grid() are pure functions of position and noise, so
#             regenerated chunks match the ones they replace, chunk borders stay seamless, and coarse
#             LOD grids agree with LOD 0 on which samples are solid (INV-11).
# GOTCHAS:    Raw density is noise * HEIGHT - y, so its vertical gradient is about 1 per unit and it
#             approximates the depth below the surface used to pick the type. Overhang undersides
#             therefore also get grass. Stored as 128 + raw * 128 / VoxelChunk.BAND clamped to a
#             byte (D-23): meshing and normals read at most 2 units from the surface, well inside
#             BAND. Grids entirely beyond the band skip the noise, assuming |noise| <= 1
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
	var samples := generate_grid(origin, 1, Vector3i.ONE * VoxelChunk.SIZE)
	if samples[0].count(0) == VoxelChunk.VOLUME:
		return chunk
	chunk.densities = samples[0]
	chunk.types = samples[1]
	return chunk


# [densities, types] of size samples spaced step world units from origin, x fastest. Densities span
# +-BAND * step (step 1 is the chunk format), so coarse grids keep as many samples inside the band;
# whatever the step, a sample is solid exactly when raw >= 0 (INV-11).
func generate_grid(origin: Vector3i, step: int, size: Vector3i) -> Array[PackedByteArray]:
	var band := VoxelChunk.BAND * step
	# Filled as locals: indexing chunk.densities directly copies the whole array on every write.
	var densities := PackedByteArray()
	densities.resize(size.x * size.y * size.z)
	var types := PackedByteArray()
	types.resize(densities.size())
	if origin.y >= HEIGHT + band:
		densities.fill(0)
		types.fill(0)
	elif origin.y + (size.y - 1) * step <= -HEIGHT - band:
		densities.fill(255)
		types.fill(Type.STONE)
	else:
		var index := 0
		for z in size.z:
			for y in size.y:
				for x in size.x:
					var world := origin + Vector3i(x, y, z) * step
					var raw := noise.get_noise_3d(world.x, world.y, world.z) * HEIGHT - world.y
					densities[index] = clampi(floori(128.0 + raw * 128.0 / band), 0, 255)
					if raw < 1.0:
						types[index] = Type.GRASS
					elif raw < 5.0:
						types[index] = Type.DIRT
					else:
						types[index] = Type.STONE
					index += 1
	return [densities, types]
