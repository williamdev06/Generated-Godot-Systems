@tool
extends EditorPlugin
# OWNS:       Viewport sculpting and voxel editing of the selected VoxelTerrain, with undo.
# DEPENDS:    VoxelTerrain (get_density, get_type, set_voxel, set_voxels, voxel_types), VoxelChunk,
#             EditorUndoRedoManager, RenderingServer
# INVARIANTS: Edits go through _set_voxel only, so they land in authored_chunks (D-17) and in the
#             stroke's undo delta.
# GOTCHAS:    Picking marches the density samples in terrain-local space, not the meshes (chunks
#             have no collision); chunks without data read as air, so rays pass through them.
#             Sculpt and flatten write distance below the surface mapped to density
#             0..1 by VoxelChunk.BAND, as VoxelGenerator does (D-23); solid is above 0.5. Edits
#             apply live; the undo action is committed without executing on mouse release. Undo
#             restores samples but chunks stay authored.
#             The brush cursor is a RenderingServer instance, not a node, so it never enters the
#             edited scene.

# Sculpt, Voxel and Density add on click and subtract on shift+click.
enum Tool { NONE, SCULPT, VOXEL, DENSITY, SMOOTH, FLATTEN, PAINT }

const NEIGHBOUR_OFFSETS: Array[Vector3i] = [
	Vector3i.LEFT, Vector3i.RIGHT, Vector3i.DOWN, Vector3i.UP, Vector3i.FORWARD, Vector3i.BACK,
]

var _terrain: VoxelTerrain
var _toolbar := HBoxContainer.new()
var _tool := OptionButton.new()
var _radius := SpinBox.new()
var _strength := SpinBox.new()
var _type := OptionButton.new()
var _cursor_mesh := SphereMesh.new()
var _cursor := RID()
# Last pick, terrain-local. _place_sample is the last air sample before _hit_sample.
var _has_hit := false
var _hit_position := Vector3.ZERO
var _hit_sample := Vector3i.ZERO
var _place_sample := Vector3i.ZERO
# Shift state of the last mouse event.
var _subtract := false
# Flatten levels to the height where the stroke started.
var _flatten_height := 0.0
# Undo delta of the current stroke: each changed sample's value before the stroke touched it.
var _stroke_densities: Dictionary[Vector3i, float] = {}
var _stroke_types: Dictionary[Vector3i, int] = {}


func _enter_tree() -> void:
	for tool_name: String in Tool.keys():
		_tool.add_item(tool_name.capitalize())
	_tool.item_selected.connect(_update_cursor.unbind(1))
	_toolbar.add_child(_tool)
	_radius.prefix = "Radius"
	_radius.min_value = 1.0
	_radius.max_value = 16.0
	_radius.value = 4.0
	_radius.value_changed.connect(_update_cursor.unbind(1))
	_toolbar.add_child(_radius)
	# Density tool only: added to (subtracted from, with shift) the density at the brush centre per
	# stroke step.
	_strength.prefix = "Strength"
	_strength.min_value = 0.0
	_strength.max_value = 0.25
	_strength.step = 0.005
	_strength.value = 0.03
	_toolbar.add_child(_strength)
	# Filled per terrain in _edit, indexed like VoxelTerrain.voxel_types.
	_toolbar.add_child(_type)
	_toolbar.hide()
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _toolbar)
	var cursor_material := StandardMaterial3D.new()
	cursor_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	cursor_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	cursor_material.albedo_color = Color(1.0, 1.0, 1.0, 0.25)
	_cursor_mesh.radius = 1.0
	_cursor_mesh.height = 2.0
	_cursor_mesh.material = cursor_material
	_cursor = RenderingServer.instance_create()
	RenderingServer.instance_set_base(_cursor, _cursor_mesh.get_rid())
	RenderingServer.instance_set_visible(_cursor, false)


func _exit_tree() -> void:
	remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _toolbar)
	_toolbar.queue_free()
	RenderingServer.free_rid(_cursor)


func _handles(object: Object) -> bool:
	return object is VoxelTerrain


func _edit(object: Object) -> void:
	_terrain = object as VoxelTerrain
	_has_hit = false
	_type.clear()
	if _terrain != null:
		for index in _terrain.voxel_types.size():
			var voxel_type := _terrain.voxel_types[index]
			# Types saved inside the scene have no file name to show.
			var type_name := ""
			if voxel_type != null:
				type_name = voxel_type.resource_path.get_file().get_basename()
			_type.add_item("%d %s" % [index, type_name])
	_update_cursor()


func _make_visible(visible: bool) -> void:
	_toolbar.visible = visible


func _forward_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
	if _terrain == null or _tool.selected == Tool.NONE:
		return AFTER_GUI_INPUT_PASS
	var mouse_button := event as InputEventMouseButton
	if mouse_button != null:
		var is_wheel := mouse_button.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]
		if is_wheel and mouse_button.ctrl_pressed:
			if mouse_button.pressed:
				_radius.value += 1.0 if mouse_button.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0
			return AFTER_GUI_INPUT_STOP
		if mouse_button.button_index == MOUSE_BUTTON_LEFT:
			_subtract = mouse_button.shift_pressed
			if mouse_button.pressed:
				_pick(camera, mouse_button.position)
				_flatten_height = _hit_position.y
				_edit_at_hit()
			else:
				_end_stroke()
			# Consumes the release too, so the click never reaches selection.
			return AFTER_GUI_INPUT_STOP
	var motion := event as InputEventMouseMotion
	if motion != null:
		_subtract = motion.shift_pressed
		_pick(camera, motion.position)
		# The voxel tool acts per click; dragging it would stack voxels toward the camera.
		var is_brush := _tool.selected != Tool.VOXEL
		if motion.button_mask & MOUSE_BUTTON_MASK_LEFT and is_brush:
			_edit_at_hit()
			return AFTER_GUI_INPUT_STOP
	return AFTER_GUI_INPUT_PASS


func _pick(camera: Camera3D, screen_position: Vector2) -> void:
	# Terrain-local space: one unit per sample, samples at integer positions.
	var to_terrain := _terrain.global_transform.affine_inverse()
	var origin := to_terrain * camera.project_ray_origin(screen_position)
	var direction := (to_terrain.basis * camera.project_ray_normal(screen_position)).normalized()
	_has_hit = false
	# Quarter-unit steps over 200 units, nearest sample per step.
	var previous := Vector3i(origin.round())
	for step in 800:
		var hit := origin + direction * step * 0.25
		var sample := Vector3i(hit.round())
		if _terrain.get_density(sample) > 0.5:
			_has_hit = true
			_hit_position = hit
			_hit_sample = sample
			_place_sample = previous
			break
		previous = sample
	_update_cursor()


func _update_cursor() -> void:
	var visible := _terrain != null and _tool.selected != Tool.NONE and _has_hit
	RenderingServer.instance_set_visible(_cursor, visible)
	if not visible:
		return
	var center := _hit_position
	var radius := _radius.value
	# The voxel tool shows the sample it would change.
	if _tool.selected == Tool.VOXEL:
		center = Vector3(_hit_sample if _subtract else _place_sample)
		radius = 0.5
	RenderingServer.instance_set_scenario(_cursor, _terrain.get_world_3d().scenario)
	RenderingServer.instance_set_transform(_cursor,
		_terrain.global_transform * Transform3D(Basis.from_scale(Vector3.ONE * radius), center))


func _edit_at_hit() -> void:
	if not _has_hit:
		return
	if _tool.selected != Tool.VOXEL:
		_brush()
	elif _subtract:
		# Air samples' types are never read when meshing.
		_set_voxel(_hit_sample, 0.0, _type.selected)
	else:
		_set_voxel(_place_sample, 1.0, _type.selected)


func _brush() -> void:
	var radius := _radius.value
	var selected_type := _type.selected
	var begin := Vector3i((_hit_position - Vector3.ONE * radius).ceil())
	var end := Vector3i((_hit_position + Vector3.ONE * radius).floor())
	# Computed before any write, so smoothing reads unedited neighbours.
	var new_densities: Dictionary[Vector3i, float] = {}
	for z in range(begin.z, end.z + 1):
		for y in range(begin.y, end.y + 1):
			for x in range(begin.x, end.x + 1):
				var sample := Vector3i(x, y, z)
				var distance := _hit_position.distance_to(Vector3(sample))
				if distance > radius:
					continue
				var falloff := 1.0 - distance / radius
				var density := _terrain.get_density(sample)
				match _tool.selected:
					# Signed distance union/subtraction with the brush sphere.
					Tool.SCULPT:
						if _subtract:
							new_densities[sample] = minf(density, _distance_density(distance - radius))
						else:
							new_densities[sample] = maxf(density, _distance_density(radius - distance))
					Tool.DENSITY:
						var strength := -_strength.value if _subtract else _strength.value
						new_densities[sample] = density + strength * falloff
					Tool.SMOOTH:
						new_densities[sample] = lerpf(density, _neighbour_average(sample), falloff)
					# A level surface at height h has distance h - y.
					Tool.FLATTEN:
						var level := _distance_density(_flatten_height - sample.y)
						new_densities[sample] = lerpf(density, level, falloff)
					Tool.PAINT:
						new_densities[sample] = density
	for sample: Vector3i in new_densities:
		var density := _terrain.get_density(sample)
		var type := _terrain.get_type(sample)
		var new_density := new_densities[sample]
		# Air turning solid takes the selected type; Paint retypes solid samples.
		var new_type := type
		if density < 0.5 or _tool.selected == Tool.PAINT:
			new_type = selected_type
		# Untouched samples are skipped so their chunks do not become authored.
		if new_density != density or (density > 0.5 and new_type != type):
			_set_voxel(sample, new_density, new_type)


# Distance below the surface to density, clamped to 0..1 like stored samples (VoxelChunk.BAND).
func _distance_density(distance: float) -> float:
	return clampf(0.5 + distance / (2.0 * VoxelChunk.BAND), 0.0, 1.0)


func _neighbour_average(sample: Vector3i) -> float:
	var total := 0.0
	for offset in NEIGHBOUR_OFFSETS:
		total += _terrain.get_density(sample + offset)
	return total / NEIGHBOUR_OFFSETS.size()


func _set_voxel(sample: Vector3i, density: float, type: int) -> void:
	if not _stroke_densities.has(sample):
		_stroke_densities[sample] = _terrain.get_density(sample)
		_stroke_types[sample] = _terrain.get_type(sample)
	_terrain.set_voxel(sample, density, type)


# Commits the stroke as one action holding its delta (before/after per changed sample) on the
# terrain it changed; the do/undo target places it in that terrain's scene history.
func _end_stroke() -> void:
	if _stroke_densities.is_empty():
		return
	var worlds: Array[Vector3i] = []
	worlds.assign(_stroke_densities.keys())
	var old_densities := PackedFloat32Array()
	var old_types := PackedByteArray()
	var new_densities := PackedFloat32Array()
	var new_types := PackedByteArray()
	for world in worlds:
		old_densities.append(_stroke_densities[world])
		old_types.append(_stroke_types[world])
		new_densities.append(_terrain.get_density(world))
		new_types.append(_terrain.get_type(world))
	_stroke_densities.clear()
	_stroke_types.clear()
	var undo_redo := get_undo_redo()
	undo_redo.create_action("Voxel " + _tool.get_item_text(_tool.selected))
	undo_redo.add_do_method(_terrain, &"set_voxels", worlds, new_densities, new_types)
	undo_redo.add_undo_method(_terrain, &"set_voxels", worlds, old_densities, old_types)
	# The stroke is already applied.
	undo_redo.commit_action(false)
