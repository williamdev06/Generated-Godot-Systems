@tool
class_name VoxelRegionStorage
extends Resource
# OWNS:       Saving and loading chunks in region files of REGION^3 chunks (Minecraft-style).
# DEPENDS:    VoxelChunk, FileAccess, DirAccess
# INVARIANTS: Region file layout: a header of REGION^3 entries (u32 byte offset, u32 byte length;
#             length 0 = never saved) indexed by the chunk's region-local coordinate, x fastest,
#             then payloads: one flag byte (0 all air, 1 samples follow) and for 1 the densities
#             then types (2 * VOLUME bytes), zstd-compressed. Changing it orphans existing saves.
# GOTCHAS:    Called from worker threads. One static mutex serialises all file access, including
#             across duplicates (VoxelTerrain hands workers a snapshot). A payload that outgrows its
#             old bytes is appended and the old bytes are never reused, so re-saved regions grow.

const REGION := 8
const HEADER_SIZE := REGION * REGION * REGION * 8

static var _mutex := Mutex.new()

# Folder of the region files: user:// for runtime saves, res:// for worlds shipped with the game
# (read-only in exports).
@export_dir var directory := "":
	set(value):
		directory = value
		emit_changed()


# Null when the chunk was never saved.
func load_chunk(coord: Vector3i) -> VoxelChunk:
	_mutex.lock()
	var chunk := _read(coord)
	_mutex.unlock()
	return chunk


# Empty arrays save an all-air chunk.
func save_chunk(coord: Vector3i, densities: PackedByteArray, types: PackedByteArray) -> void:
	var payload := PackedByteArray([0])
	if not densities.is_empty():
		payload[0] = 1
		payload.append_array((densities + types).compress(FileAccess.COMPRESSION_ZSTD))
	_mutex.lock()
	_write(coord, payload)
	_mutex.unlock()


func _read(coord: Vector3i) -> VoxelChunk:
	var path := _region_path(coord)
	if not FileAccess.file_exists(path):
		return null
	var file := FileAccess.open(path, FileAccess.READ)
	file.seek(_entry_position(coord))
	var offset := file.get_32()
	var length := file.get_32()
	if length == 0:
		return null
	file.seek(offset)
	var payload := file.get_buffer(length)
	var chunk := VoxelChunk.new()
	if payload[0] == 1:
		var samples := payload.slice(1).decompress(2 * VoxelChunk.VOLUME, FileAccess.COMPRESSION_ZSTD)
		chunk.densities = samples.slice(0, VoxelChunk.VOLUME)
		chunk.types = samples.slice(VoxelChunk.VOLUME)
	return chunk


func _write(coord: Vector3i, payload: PackedByteArray) -> void:
	var path := _region_path(coord)
	if not FileAccess.file_exists(path):
		DirAccess.make_dir_recursive_absolute(directory)
		var header := PackedByteArray()
		header.resize(HEADER_SIZE)
		header.fill(0)
		FileAccess.open(path, FileAccess.WRITE).store_buffer(header)
	var file := FileAccess.open(path, FileAccess.READ_WRITE)
	file.seek(_entry_position(coord))
	var offset := file.get_32()
	var length := file.get_32()
	# Overwritten in place when it fits, otherwise appended.
	if payload.size() > length:
		offset = file.get_length()
	file.seek(offset)
	file.store_buffer(payload)
	file.seek(_entry_position(coord))
	file.store_32(offset)
	file.store_32(payload.size())


func _region_path(coord: Vector3i) -> String:
	var region := Vector3i(
		floori(float(coord.x) / REGION), floori(float(coord.y) / REGION), floori(float(coord.z) / REGION))
	return directory.path_join("r.%d.%d.%d.region" % [region.x, region.y, region.z])


static func _entry_position(coord: Vector3i) -> int:
	var local := Vector3i(posmod(coord.x, REGION), posmod(coord.y, REGION), posmod(coord.z, REGION))
	return (local.x + local.y * REGION + local.z * REGION * REGION) * 8
