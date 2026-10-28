@tool
class_name VoxelGenerator
extends Resource
# OWNS:       Procedural density and voxel type for a chunk.
# DEPENDS:    FastNoiseLite, VoxelChunk
# INVARIANTS: generate() is a pure function of chunk coordinate and noise, so regenerated chunks
#             match the ones they replace and chunk borders stay seamless.
# GOTCHAS:    Density is noise * 24 - y, so its vertical gradient is about 1 per unit and the
#             density value approximates the depth below the surface used to pick the type.
#             Overhang undersides therefore also get grass.

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
	# Filled as locals: indexing chunk.densities directly copies the whole array on every write.
	var densities := chunk.densities
	var types := chunk.types
	var origin := coord * VoxelChunk.SIZE
	for z in VoxelChunk.SIZE:
		for y in VoxelChunk.SIZE:
			for x in VoxelChunk.SIZE:
				var world := origin + Vector3i(x, y, z)
				var density := noise.get_noise_3d(world.x, world.y, world.z) * 24.0 - world.y
				var index := VoxelChunk.sample_index(Vector3i(x, y, z))
				densities[index] = density
				if density < 1.0:
					types[index] = VoxelChunk.Type.GRASS
				elif density < 5.0:
					types[index] = VoxelChunk.Type.DIRT
				else:
					types[index] = VoxelChunk.Type.STONE
	chunk.densities = densities
	chunk.types = types
	return chunk
