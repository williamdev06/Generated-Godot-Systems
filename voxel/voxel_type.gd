@tool
class_name VoxelType
extends Resource
# OWNS:       Appearance of one voxel type.
# DEPENDS:    nothing
# INVARIANTS: Chunks store a type as its index in VoxelTerrain.get_voxel_types(), not as this
#             resource.
# GOTCHAS:    VoxelTerrain packs every type's texture into one Texture2DArray: converted to RGBA8
#             (VRAM compression is lost), resized to the first type's size, mipmaps regenerated.

@export var texture: Texture2D:
	set(value):
		texture = value
		emit_changed()
