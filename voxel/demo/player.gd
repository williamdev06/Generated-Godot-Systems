extends CharacterBody3D
# OWNS:       Demo first-person player: walk, jump, noclip flight, place and destroy voxels.
# DEPENDS:    VoxelTerrain (raycast, push_out, get_density, get_type, set_voxel), chunk trimesh
#             collision on layer 1 (D-28), child Camera3D.
# INVARIANTS: The body origin is at the feet; the capsule (radius 0.4, height 1.8) sits above it.
#             _overlaps_player assumes that size.
# GOTCHAS:    Controls: WASD move, Space jump, V noclip, left click destroy, right click place, Esc
#             frees the mouse (click recaptures). Chunks have no collision until meshed, so the feet
#             are kept out of solid by density push_out as well (_unstick). Spawn is deferred: the
#             terrain's first rebuild is deferred too and is queued before it (earlier sibling).

@export var terrain: VoxelTerrain

var _noclip := false

@onready var _camera: Camera3D = $Camera3D


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_spawn.call_deferred()


# Drops the player onto the ground below its start.
func _spawn() -> void:
	var local := terrain.to_local(global_position)
	var hit := terrain.raycast(Vector3(local.x, 128.0, local.z), Vector3(local.x, -128.0, local.z))
	if not hit.is_empty():
		global_position = terrain.to_global(hit.position)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_ESCAPE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		elif event.physical_keycode == KEY_V:
			_noclip = not _noclip
			velocity = Vector3.ZERO
	elif event is InputEventMouseButton and event.pressed:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		elif event.button_index == MOUSE_BUTTON_LEFT:
			_edit(false)
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_edit(true)
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		# Radians per pixel.
		rotate_y(-event.relative.x * 0.002)
		_camera.rotation.x = clampf(_camera.rotation.x - event.relative.y * 0.002, -1.55, 1.55)


func _physics_process(delta: float) -> void:
	var input := Vector3(
		float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)),
		0.0,
		float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W)),
	).normalized()
	if _noclip:
		# Flies where the camera looks, straight through terrain.
		global_position += _camera.global_basis * input * 15.0 * delta
		return
	var direction := global_basis * input
	velocity.x = direction.x * 5.0
	velocity.z = direction.z * 5.0
	if is_on_floor():
		if Input.is_physical_key_pressed(KEY_SPACE):
			velocity.y = 5.0
	else:
		velocity += get_gravity() * delta
	move_and_slide()
	_unstick()


# Unmeshed chunks have no collision (D-28), so this holds the player on the density surface until
# their mesh arrives. Probes above the feet: the trilinear surface only matches the mesh along cell
# edges, and probing at the feet would push off ground the capsule already rests on.
func _unstick() -> void:
	var offset := Vector3.UP * 0.25
	var probe := terrain.to_local(global_position + offset)
	var air := terrain.push_out(probe)
	if air != probe:
		global_position = terrain.to_global(air) - offset
		velocity.y = maxf(velocity.y, 0.0)


# Same pick as the editor voxel tool (M-12): nearest sample along the view ray in quarter-unit
# steps, here up to 6 units. Destroy clears the hit sample, place fills the air sample before it.
func _edit(place: bool) -> void:
	var to_terrain := terrain.global_transform.affine_inverse()
	var origin := to_terrain * _camera.global_position
	var direction := (to_terrain.basis * -_camera.global_basis.z).normalized()
	var previous := Vector3i(origin.round())
	for step in 24:
		var sample := Vector3i((origin + direction * step * 0.25).round())
		if terrain.get_density(sample) > 0.5:
			if not place:
				terrain.set_voxel(sample, 0.0, terrain.get_type(sample))
			elif not _overlaps_player(previous):
				# 2 = stone in the demo palette.
				terrain.set_voxel(previous, 1.0, 2)
			return
		previous = sample


# A full sample next to near-surface neighbours (density ~0.5) is solid up to about a unit away,
# so the box is one unit around it, not half.
func _overlaps_player(sample: Vector3i) -> bool:
	var feet := terrain.to_local(global_position)
	var player := AABB(feet - Vector3(0.4, 0.0, 0.4), Vector3(0.8, 1.8, 0.8))
	return player.intersects(AABB(Vector3(sample) - Vector3.ONE, Vector3.ONE * 2.0))
