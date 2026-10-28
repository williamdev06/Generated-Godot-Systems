@tool
class_name VoxelRegionStorage
extends VoxelStorage
# OWNS:       Saving and loading chunks in region files of REGION^3 chunks (Minecraft-style).
# DEPENDS:    VoxelChunk (encode, decode), FileAccess, DirAccess
# INVARIANTS: Region file layout: a header of REGION^3 entries (u32 byte offset, u32 byte length;
#             length 0 = never saved) indexed by the chunk's region-local coordinate, x fastest,
#             then VoxelChunk.encode payloads (INV-9) at those offsets, in any order.
# GOTCHAS:    Called from worker threads. One static mutex serialises all file access, including
#             across duplicates (VoxelTerrain hands workers a snapshot). A write goes to the first
#             gap between other payloads that fits it and the file is truncated after the last
#             payload, so space is reused and files shrink when their tail frees up.

const REGION := 8
const HEADER_SIZE := REGION * REGION * REGION * 8

static var _mutex := Mutex.new()

# Folder of the region files: user:// for runtime saves, res:// for worlds shipped with the game
# (read-only in exports).
@export_dir var directory := "":
	set(value):
		directory = value
		emit_changed()


func load_chunk(coord: Vector3i) -> VoxelChunk:
	_mutex.lock()
	var chunk := _read(coord)
	_mutex.unlock()
	return chunk


func save_chunk(coord: Vector3i, densities: PackedByteArray, types: PackedByteArray) -> void:
	var payload := VoxelChunk.encode(densities, types)
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
	return VoxelChunk.decode(file.get_buffer(length))


func _write(coord: Vector3i, payload: PackedByteArray) -> void:
	var path := _region_path(coord)
	if not FileAccess.file_exists(path):
		DirAccess.make_dir_recursive_absolute(directory)
		var empty_header := PackedByteArray()
		empty_header.resize(HEADER_SIZE)
		empty_header.fill(0)
		FileAccess.open(path, FileAccess.WRITE).store_buffer(empty_header)
	var file := FileAccess.open(path, FileAccess.READ_WRITE)
	var header := file.get_buffer(HEADER_SIZE)
	var entry := _entry_position(coord)
	# Byte ranges (offset, length) of every other saved chunk, in file order.
	var used: Array[Vector2i] = []
	for position in range(0, HEADER_SIZE, 8):
		var length := header.decode_u32(position + 4)
		if length > 0 and position != entry:
			used.append(Vector2i(header.decode_u32(position), length))
	used.sort()
	var offset := HEADER_SIZE
	for slot in used:
		if slot.x - offset >= payload.size():
			break
		offset = slot.x + slot.y
	file.seek(offset)
	file.store_buffer(payload)
	file.seek(entry)
	file.store_32(offset)
	file.store_32(payload.size())
	var end := offset + payload.size()
	if not used.is_empty():
		var last: Vector2i = used.back()
		end = maxi(end, last.x + last.y)
	if file.get_length() > end:
		file.resize(end)


func _region_path(coord: Vector3i) -> String:
	var region := Vector3i(
		floori(float(coord.x) / REGION), floori(float(coord.y) / REGION), floori(float(coord.z) / REGION))
	return directory.path_join("r.%d.%d.%d.region" % [region.x, region.y, region.z])


static func _entry_position(coord: Vector3i) -> int:
	var local := Vector3i(posmod(coord.x, REGION), posmod(coord.y, REGION), posmod(coord.z, REGION))
	return (local.x + local.y * REGION + local.z * REGION * REGION) * 8
