@tool
class_name MarchingCubes
extends RefCounted
# OWNS:       Turning a padded density/type grid into one chunk mesh with Marching Cubes.
# DEPENDS:    VoxelChunk (SIZE, ISO)
# INVARIANTS: Input grids hold PADDED^3 samples covering chunk-local -1..SIZE+1 per axis (INV-7).
#             CORNERS and EDGES must keep the numbering TRIANGLES was written for.
# GOTCHAS:    With the case bit set for solid corners, TRIANGLES order gives Godot's clockwise
#             front faces seen from the air side. Normals come from the density gradient, not the
#             triangles, so both sides of a chunk border get identical normals and no seam shows.
#             An edge vertex used only by mixed-type triangles stays in the buffer unreferenced.

const PADDED := VoxelChunk.SIZE + 3

const CORNERS: Array[Vector3i] = [
	Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(1, 1, 0), Vector3i(0, 1, 0),
	Vector3i(0, 0, 1), Vector3i(1, 0, 1), Vector3i(1, 1, 1), Vector3i(0, 1, 1),
]

# Corner pairs per cube edge.
const EDGES: Array[Vector2i] = [
	Vector2i(0, 1), Vector2i(1, 2), Vector2i(2, 3), Vector2i(3, 0),
	Vector2i(4, 5), Vector2i(5, 6), Vector2i(6, 7), Vector2i(7, 4),
	Vector2i(0, 4), Vector2i(1, 5), Vector2i(2, 6), Vector2i(3, 7),
]

# Padded-grid index offset of each corner in CORNERS.
const CORNER_OFFSETS: Array[int] = [
	0, 1, 1 + PADDED, PADDED,
	PADDED * PADDED, 1 + PADDED * PADDED, 1 + PADDED + PADDED * PADDED, PADDED + PADDED * PADDED,
]

# Axis (0 x, 1 y, 2 z) each edge in EDGES runs along.
const EDGE_AXES: Array[int] = [0, 1, 0, 1, 0, 1, 0, 1, 2, 2, 2, 2]

const BARYCENTRIC: Array[Color] = [Color(1, 0, 0), Color(0, 1, 0), Color(0, 0, 1)]

# Cube case (bit n set = corner n solid) -> edge triples, one per triangle. Paul Bourke's table.
const TRIANGLES := [
	[],
	[0, 8, 3],
	[0, 1, 9],
	[1, 8, 3, 9, 8, 1],
	[1, 2, 10],
	[0, 8, 3, 1, 2, 10],
	[9, 2, 10, 0, 2, 9],
	[2, 8, 3, 2, 10, 8, 10, 9, 8],
	[3, 11, 2],
	[0, 11, 2, 8, 11, 0],
	[1, 9, 0, 2, 3, 11],
	[1, 11, 2, 1, 9, 11, 9, 8, 11],
	[3, 10, 1, 11, 10, 3],
	[0, 10, 1, 0, 8, 10, 8, 11, 10],
	[3, 9, 0, 3, 11, 9, 11, 10, 9],
	[9, 8, 10, 10, 8, 11],
	[4, 7, 8],
	[4, 3, 0, 7, 3, 4],
	[0, 1, 9, 8, 4, 7],
	[4, 1, 9, 4, 7, 1, 7, 3, 1],
	[1, 2, 10, 8, 4, 7],
	[3, 4, 7, 3, 0, 4, 1, 2, 10],
	[9, 2, 10, 9, 0, 2, 8, 4, 7],
	[2, 10, 9, 2, 9, 7, 2, 7, 3, 7, 9, 4],
	[8, 4, 7, 3, 11, 2],
	[11, 4, 7, 11, 2, 4, 2, 0, 4],
	[9, 0, 1, 8, 4, 7, 2, 3, 11],
	[4, 7, 11, 9, 4, 11, 9, 11, 2, 9, 2, 1],
	[3, 10, 1, 3, 11, 10, 7, 8, 4],
	[1, 11, 10, 1, 4, 11, 1, 0, 4, 7, 11, 4],
	[4, 7, 8, 9, 0, 11, 9, 11, 10, 11, 0, 3],
	[4, 7, 11, 4, 11, 9, 9, 11, 10],
	[9, 5, 4],
	[9, 5, 4, 0, 8, 3],
	[0, 5, 4, 1, 5, 0],
	[8, 5, 4, 8, 3, 5, 3, 1, 5],
	[1, 2, 10, 9, 5, 4],
	[3, 0, 8, 1, 2, 10, 4, 9, 5],
	[5, 2, 10, 5, 4, 2, 4, 0, 2],
	[2, 10, 5, 3, 2, 5, 3, 5, 4, 3, 4, 8],
	[9, 5, 4, 2, 3, 11],
	[0, 11, 2, 0, 8, 11, 4, 9, 5],
	[0, 5, 4, 0, 1, 5, 2, 3, 11],
	[2, 1, 5, 2, 5, 8, 2, 8, 11, 4, 8, 5],
	[10, 3, 11, 10, 1, 3, 9, 5, 4],
	[4, 9, 5, 0, 8, 1, 8, 10, 1, 8, 11, 10],
	[5, 4, 0, 5, 0, 11, 5, 11, 10, 11, 0, 3],
	[5, 4, 8, 5, 8, 10, 10, 8, 11],
	[9, 7, 8, 5, 7, 9],
	[9, 3, 0, 9, 5, 3, 5, 7, 3],
	[0, 7, 8, 0, 1, 7, 1, 5, 7],
	[1, 5, 3, 3, 5, 7],
	[9, 7, 8, 9, 5, 7, 10, 1, 2],
	[10, 1, 2, 9, 5, 0, 5, 3, 0, 5, 7, 3],
	[8, 0, 2, 8, 2, 5, 8, 5, 7, 10, 5, 2],
	[2, 10, 5, 2, 5, 3, 3, 5, 7],
	[7, 9, 5, 7, 8, 9, 3, 11, 2],
	[9, 5, 7, 9, 7, 2, 9, 2, 0, 2, 7, 11],
	[2, 3, 11, 0, 1, 8, 1, 7, 8, 1, 5, 7],
	[11, 2, 1, 11, 1, 7, 7, 1, 5],
	[9, 5, 8, 8, 5, 7, 10, 1, 3, 10, 3, 11],
	[5, 7, 0, 5, 0, 9, 7, 11, 0, 1, 0, 10, 11, 10, 0],
	[11, 10, 0, 11, 0, 3, 10, 5, 0, 8, 0, 7, 5, 7, 0],
	[11, 10, 5, 7, 11, 5],
	[10, 6, 5],
	[0, 8, 3, 5, 10, 6],
	[9, 0, 1, 5, 10, 6],
	[1, 8, 3, 1, 9, 8, 5, 10, 6],
	[1, 6, 5, 2, 6, 1],
	[1, 6, 5, 1, 2, 6, 3, 0, 8],
	[9, 6, 5, 9, 0, 6, 0, 2, 6],
	[5, 9, 8, 5, 8, 2, 5, 2, 6, 3, 2, 8],
	[2, 3, 11, 10, 6, 5],
	[11, 0, 8, 11, 2, 0, 10, 6, 5],
	[0, 1, 9, 2, 3, 11, 5, 10, 6],
	[5, 10, 6, 1, 9, 2, 9, 11, 2, 9, 8, 11],
	[6, 3, 11, 6, 5, 3, 5, 1, 3],
	[0, 8, 11, 0, 11, 5, 0, 5, 1, 5, 11, 6],
	[3, 11, 6, 0, 3, 6, 0, 6, 5, 0, 5, 9],
	[6, 5, 9, 6, 9, 11, 11, 9, 8],
	[5, 10, 6, 4, 7, 8],
	[4, 3, 0, 4, 7, 3, 6, 5, 10],
	[1, 9, 0, 5, 10, 6, 8, 4, 7],
	[10, 6, 5, 1, 9, 7, 1, 7, 3, 7, 9, 4],
	[6, 1, 2, 6, 5, 1, 4, 7, 8],
	[1, 2, 5, 5, 2, 6, 3, 0, 4, 3, 4, 7],
	[8, 4, 7, 9, 0, 5, 0, 6, 5, 0, 2, 6],
	[7, 3, 9, 7, 9, 4, 3, 2, 9, 5, 9, 6, 2, 6, 9],
	[3, 11, 2, 7, 8, 4, 10, 6, 5],
	[5, 10, 6, 4, 7, 2, 4, 2, 0, 2, 7, 11],
	[0, 1, 9, 4, 7, 8, 2, 3, 11, 5, 10, 6],
	[9, 2, 1, 9, 11, 2, 9, 4, 11, 7, 11, 4, 5, 10, 6],
	[8, 4, 7, 3, 11, 5, 3, 5, 1, 5, 11, 6],
	[5, 1, 11, 5, 11, 6, 1, 0, 11, 7, 11, 4, 0, 4, 11],
	[0, 5, 9, 0, 6, 5, 0, 3, 6, 11, 6, 3, 8, 4, 7],
	[6, 5, 9, 6, 9, 11, 4, 7, 9, 7, 11, 9],
	[10, 4, 9, 6, 4, 10],
	[4, 10, 6, 4, 9, 10, 0, 8, 3],
	[10, 0, 1, 10, 6, 0, 6, 4, 0],
	[8, 3, 1, 8, 1, 6, 8, 6, 4, 6, 1, 10],
	[1, 4, 9, 1, 2, 4, 2, 6, 4],
	[3, 0, 8, 1, 2, 9, 2, 4, 9, 2, 6, 4],
	[0, 2, 4, 4, 2, 6],
	[8, 3, 2, 8, 2, 4, 4, 2, 6],
	[10, 4, 9, 10, 6, 4, 11, 2, 3],
	[0, 8, 2, 2, 8, 11, 4, 9, 10, 4, 10, 6],
	[3, 11, 2, 0, 1, 6, 0, 6, 4, 6, 1, 10],
	[6, 4, 1, 6, 1, 10, 4, 8, 1, 2, 1, 11, 8, 11, 1],
	[9, 6, 4, 9, 3, 6, 9, 1, 3, 11, 6, 3],
	[8, 11, 1, 8, 1, 0, 11, 6, 1, 9, 1, 4, 6, 4, 1],
	[3, 11, 6, 3, 6, 0, 0, 6, 4],
	[6, 4, 8, 11, 6, 8],
	[7, 10, 6, 7, 8, 10, 8, 9, 10],
	[0, 7, 3, 0, 10, 7, 0, 9, 10, 6, 7, 10],
	[10, 6, 7, 1, 10, 7, 1, 7, 8, 1, 8, 0],
	[10, 6, 7, 10, 7, 1, 1, 7, 3],
	[1, 2, 6, 1, 6, 8, 1, 8, 9, 8, 6, 7],
	[2, 6, 9, 2, 9, 1, 6, 7, 9, 0, 9, 3, 7, 3, 9],
	[7, 8, 0, 7, 0, 6, 6, 0, 2],
	[7, 3, 2, 6, 7, 2],
	[2, 3, 11, 10, 6, 8, 10, 8, 9, 8, 6, 7],
	[2, 0, 7, 2, 7, 11, 0, 9, 7, 6, 7, 10, 9, 10, 7],
	[1, 8, 0, 1, 7, 8, 1, 10, 7, 6, 7, 10, 2, 3, 11],
	[11, 2, 1, 11, 1, 7, 10, 6, 1, 6, 7, 1],
	[8, 9, 6, 8, 6, 7, 9, 1, 6, 11, 6, 3, 1, 3, 6],
	[0, 9, 1, 11, 6, 7],
	[7, 8, 0, 7, 0, 6, 3, 11, 0, 11, 6, 0],
	[7, 11, 6],
	[7, 6, 11],
	[3, 0, 8, 11, 7, 6],
	[0, 1, 9, 11, 7, 6],
	[8, 1, 9, 8, 3, 1, 11, 7, 6],
	[10, 1, 2, 6, 11, 7],
	[1, 2, 10, 3, 0, 8, 6, 11, 7],
	[2, 9, 0, 2, 10, 9, 6, 11, 7],
	[6, 11, 7, 2, 10, 3, 10, 8, 3, 10, 9, 8],
	[7, 2, 3, 6, 2, 7],
	[7, 0, 8, 7, 6, 0, 6, 2, 0],
	[2, 7, 6, 2, 3, 7, 0, 1, 9],
	[1, 6, 2, 1, 8, 6, 1, 9, 8, 8, 7, 6],
	[10, 7, 6, 10, 1, 7, 1, 3, 7],
	[10, 7, 6, 1, 7, 10, 1, 8, 7, 1, 0, 8],
	[0, 3, 7, 0, 7, 10, 0, 10, 9, 6, 10, 7],
	[7, 6, 10, 7, 10, 8, 8, 10, 9],
	[6, 8, 4, 11, 8, 6],
	[3, 6, 11, 3, 0, 6, 0, 4, 6],
	[8, 6, 11, 8, 4, 6, 9, 0, 1],
	[9, 4, 6, 9, 6, 3, 9, 3, 1, 11, 3, 6],
	[6, 8, 4, 6, 11, 8, 2, 10, 1],
	[1, 2, 10, 3, 0, 11, 0, 6, 11, 0, 4, 6],
	[4, 11, 8, 4, 6, 11, 0, 2, 9, 2, 10, 9],
	[10, 9, 3, 10, 3, 2, 9, 4, 3, 11, 3, 6, 4, 6, 3],
	[8, 2, 3, 8, 4, 2, 4, 6, 2],
	[0, 4, 2, 4, 6, 2],
	[1, 9, 0, 2, 3, 4, 2, 4, 6, 4, 3, 8],
	[1, 9, 4, 1, 4, 2, 2, 4, 6],
	[8, 1, 3, 8, 6, 1, 8, 4, 6, 6, 10, 1],
	[10, 1, 0, 10, 0, 6, 6, 0, 4],
	[4, 6, 3, 4, 3, 8, 6, 10, 3, 0, 3, 9, 10, 9, 3],
	[10, 9, 4, 6, 10, 4],
	[4, 9, 5, 7, 6, 11],
	[0, 8, 3, 4, 9, 5, 11, 7, 6],
	[5, 0, 1, 5, 4, 0, 7, 6, 11],
	[11, 7, 6, 8, 3, 4, 3, 5, 4, 3, 1, 5],
	[9, 5, 4, 10, 1, 2, 7, 6, 11],
	[6, 11, 7, 1, 2, 10, 0, 8, 3, 4, 9, 5],
	[7, 6, 11, 5, 4, 10, 4, 2, 10, 4, 0, 2],
	[3, 4, 8, 3, 5, 4, 3, 2, 5, 10, 5, 2, 11, 7, 6],
	[7, 2, 3, 7, 6, 2, 5, 4, 9],
	[9, 5, 4, 0, 8, 6, 0, 6, 2, 6, 8, 7],
	[3, 6, 2, 3, 7, 6, 1, 5, 0, 5, 4, 0],
	[6, 2, 8, 6, 8, 7, 2, 1, 8, 4, 8, 5, 1, 5, 8],
	[9, 5, 4, 10, 1, 6, 1, 7, 6, 1, 3, 7],
	[1, 6, 10, 1, 7, 6, 1, 0, 7, 8, 7, 0, 9, 5, 4],
	[4, 0, 10, 4, 10, 5, 0, 3, 10, 6, 10, 7, 3, 7, 10],
	[7, 6, 10, 7, 10, 8, 5, 4, 10, 4, 8, 10],
	[6, 9, 5, 6, 11, 9, 11, 8, 9],
	[3, 6, 11, 0, 6, 3, 0, 5, 6, 0, 9, 5],
	[0, 11, 8, 0, 5, 11, 0, 1, 5, 5, 6, 11],
	[6, 11, 3, 6, 3, 5, 5, 3, 1],
	[1, 2, 10, 9, 5, 11, 9, 11, 8, 11, 5, 6],
	[0, 11, 3, 0, 6, 11, 0, 9, 6, 5, 6, 9, 1, 2, 10],
	[11, 8, 5, 11, 5, 6, 8, 0, 5, 10, 5, 2, 0, 2, 5],
	[6, 11, 3, 6, 3, 5, 2, 10, 3, 10, 5, 3],
	[5, 8, 9, 5, 2, 8, 5, 6, 2, 3, 8, 2],
	[9, 5, 6, 9, 6, 0, 0, 6, 2],
	[1, 5, 8, 1, 8, 0, 5, 6, 8, 3, 8, 2, 6, 2, 8],
	[1, 5, 6, 2, 1, 6],
	[1, 3, 6, 1, 6, 10, 3, 8, 6, 5, 6, 9, 8, 9, 6],
	[10, 1, 0, 10, 0, 6, 9, 5, 0, 5, 6, 0],
	[0, 3, 8, 5, 6, 10],
	[10, 5, 6],
	[11, 5, 10, 7, 5, 11],
	[11, 5, 10, 11, 7, 5, 8, 3, 0],
	[5, 11, 7, 5, 10, 11, 1, 9, 0],
	[10, 7, 5, 10, 11, 7, 9, 8, 1, 8, 3, 1],
	[11, 1, 2, 11, 7, 1, 7, 5, 1],
	[0, 8, 3, 1, 2, 7, 1, 7, 5, 7, 2, 11],
	[9, 7, 5, 9, 2, 7, 9, 0, 2, 2, 11, 7],
	[7, 5, 2, 7, 2, 11, 5, 9, 2, 3, 2, 8, 9, 8, 2],
	[2, 5, 10, 2, 3, 5, 3, 7, 5],
	[8, 2, 0, 8, 5, 2, 8, 7, 5, 10, 2, 5],
	[9, 0, 1, 5, 10, 3, 5, 3, 7, 3, 10, 2],
	[9, 8, 2, 9, 2, 1, 8, 7, 2, 10, 2, 5, 7, 5, 2],
	[1, 3, 5, 3, 7, 5],
	[0, 8, 7, 0, 7, 1, 1, 7, 5],
	[9, 0, 3, 9, 3, 5, 5, 3, 7],
	[9, 8, 7, 5, 9, 7],
	[5, 8, 4, 5, 10, 8, 10, 11, 8],
	[5, 0, 4, 5, 11, 0, 5, 10, 11, 11, 3, 0],
	[0, 1, 9, 8, 4, 10, 8, 10, 11, 10, 4, 5],
	[10, 11, 4, 10, 4, 5, 11, 3, 4, 9, 4, 1, 3, 1, 4],
	[2, 5, 1, 2, 8, 5, 2, 11, 8, 4, 5, 8],
	[0, 4, 11, 0, 11, 3, 4, 5, 11, 2, 11, 1, 5, 1, 11],
	[0, 2, 5, 0, 5, 9, 2, 11, 5, 4, 5, 8, 11, 8, 5],
	[9, 4, 5, 2, 11, 3],
	[2, 5, 10, 3, 5, 2, 3, 4, 5, 3, 8, 4],
	[5, 10, 2, 5, 2, 4, 4, 2, 0],
	[3, 10, 2, 3, 5, 10, 3, 8, 5, 4, 5, 8, 0, 1, 9],
	[5, 10, 2, 5, 2, 4, 1, 9, 2, 9, 4, 2],
	[8, 4, 5, 8, 5, 3, 3, 5, 1],
	[0, 4, 5, 1, 0, 5],
	[8, 4, 5, 8, 5, 3, 9, 0, 5, 0, 3, 5],
	[9, 4, 5],
	[4, 11, 7, 4, 9, 11, 9, 10, 11],
	[0, 8, 3, 4, 9, 7, 9, 11, 7, 9, 10, 11],
	[1, 10, 11, 1, 11, 4, 1, 4, 0, 7, 4, 11],
	[3, 1, 4, 3, 4, 8, 1, 10, 4, 7, 4, 11, 10, 11, 4],
	[4, 11, 7, 9, 11, 4, 9, 2, 11, 9, 1, 2],
	[9, 7, 4, 9, 11, 7, 9, 1, 11, 2, 11, 1, 0, 8, 3],
	[11, 7, 4, 11, 4, 2, 2, 4, 0],
	[11, 7, 4, 11, 4, 2, 8, 3, 4, 3, 2, 4],
	[2, 9, 10, 2, 7, 9, 2, 3, 7, 7, 4, 9],
	[9, 10, 7, 9, 7, 4, 10, 2, 7, 8, 7, 0, 2, 0, 7],
	[3, 7, 10, 3, 10, 2, 7, 4, 10, 1, 10, 0, 4, 0, 10],
	[1, 10, 2, 8, 7, 4],
	[4, 9, 1, 4, 1, 7, 7, 1, 3],
	[4, 9, 1, 4, 1, 7, 0, 8, 1, 8, 7, 1],
	[4, 0, 3, 7, 4, 3],
	[4, 8, 7],
	[9, 10, 8, 10, 11, 8],
	[3, 0, 9, 3, 9, 11, 11, 9, 10],
	[0, 1, 10, 0, 10, 8, 8, 10, 11],
	[3, 1, 10, 11, 3, 10],
	[1, 2, 11, 1, 11, 9, 9, 11, 8],
	[3, 0, 9, 3, 9, 11, 1, 2, 9, 2, 11, 9],
	[0, 2, 11, 8, 0, 11],
	[3, 2, 11],
	[2, 3, 8, 2, 8, 10, 10, 8, 9],
	[9, 10, 2, 0, 9, 2],
	[2, 3, 8, 2, 8, 10, 0, 1, 8, 1, 10, 8],
	[1, 10, 2],
	[1, 3, 8, 9, 1, 8],
	[0, 9, 1],
	[0, 3, 8],
	[],
]


# Returns null when the chunk has no surface. Every vertex carries its triangle's three voxel types
# (CUSTOM0 rgb, in triangle corner order) and its barycentric weight for them (COLOR), which
# voxel_terrain.gdshader blends by (D-21).
static func build_mesh(densities: PackedByteArray, types: PackedByteArray) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var weights := PackedColorArray()
	# RGBA8 per vertex, alpha unused.
	var corner_types := PackedByteArray()
	var indices := PackedInt32Array()
	# Edge (padded index of its lower sample * 3 + axis) -> its vertex, -1 until created. Triangles
	# whose corners all have one type share these; mixed triangles use copies with their own weights.
	var edge_vertices := PackedInt32Array()
	edge_vertices.resize(PADDED ** 3 * 3)
	edge_vertices.fill(-1)
	var triangle_vertices := PackedInt32Array([0, 0, 0])
	var triangle_types := PackedByteArray([0, 0, 0])
	for z in VoxelChunk.SIZE:
		for y in VoxelChunk.SIZE:
			var cell_index := padded_index(Vector3i(0, y, z))
			for x in VoxelChunk.SIZE:
				var case_index := 0
				for corner in 8:
					if densities[cell_index + CORNER_OFFSETS[corner]] > VoxelChunk.ISO:
						case_index |= 1 << corner
				var edges: Array = TRIANGLES[case_index]
				for triangle in range(0, edges.size(), 3):
					for corner in 3:
						var edge: int = edges[triangle + corner]
						var start_index := cell_index + CORNER_OFFSETS[EDGES[edge].x]
						var end_index := cell_index + CORNER_OFFSETS[EDGES[edge].y]
						var key := mini(start_index, end_index) * 3 + EDGE_AXES[edge]
						if edge_vertices[key] == -1:
							var start_density := densities[start_index]
							var end_density := densities[end_index]
							var weight := (VoxelChunk.ISO - start_density) / (end_density - start_density)
							var cell := Vector3i(x, y, z)
							var start := Vector3(cell + CORNERS[EDGES[edge].x])
							var end := Vector3(cell + CORNERS[EDGES[edge].y])
							edge_vertices[key] = vertices.size()
							vertices.append(start.lerp(end, weight))
							# Density rises into the solid, so the outward normal is the negative gradient.
							var gradient := _gradient(densities, start_index).lerp(_gradient(densities, end_index), weight)
							normals.append(-gradient.normalized())
							var solid_type := types[start_index if start_density > VoxelChunk.ISO else end_index]
							weights.append(BARYCENTRIC[0])
							corner_types.append_array(PackedByteArray([solid_type, solid_type, solid_type, 0]))
						triangle_vertices[corner] = edge_vertices[key]
						triangle_types[corner] = corner_types[edge_vertices[key] * 4]
					if triangle_types[0] == triangle_types[1] and triangle_types[0] == triangle_types[2]:
						indices.append_array(triangle_vertices)
						continue
					for corner in 3:
						var shared := triangle_vertices[corner]
						indices.append(vertices.size())
						vertices.append(vertices[shared])
						normals.append(normals[shared])
						weights.append(BARYCENTRIC[corner])
						corner_types.append_array(triangle_types)
						corner_types.append(0)
				cell_index += 1
	if vertices.is_empty():
		return null
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = weights
	arrays[Mesh.ARRAY_CUSTOM0] = corner_types
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {},
		Mesh.ARRAY_CUSTOM_RGBA8_UNORM << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
	return mesh


static func padded_index(local: Vector3i) -> int:
	return (local.x + 1) + (local.y + 1) * PADDED + (local.z + 1) * PADDED * PADDED


static func _gradient(densities: PackedByteArray, index: int) -> Vector3:
	return Vector3(
		densities[index + 1] - densities[index - 1],
		densities[index + PADDED] - densities[index - PADDED],
		densities[index + PADDED * PADDED] - densities[index - PADDED * PADDED],
	)
