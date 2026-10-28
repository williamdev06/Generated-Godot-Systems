@tool
extends EditorPlugin
# OWNS:       Viewport sculpting and voxel editing of the selected VoxelTerrain.
# DEPENDS:    VoxelTerrain (get_density, get_type, set_voxel), VoxelChunk.Type, EditorInterface
# INVARIANTS: Edits go through VoxelTerrain.set_voxel only, so they land in authored_chunks (D-17).
# GOTCHAS:    Godot lists plugins only under res://addons; this one lives in voxel/ and is enabled
#             by its plugin.cfg path in project.godot [editor_plugins]. Picking marches the density
#             samples in terrain-local space, not the meshes (chunks have no collision); chunks
#             without data read as air, so rays pass through them. Sculpt add/remove treat density
#             as distance below the surface, which VoxelGenerator approximates. No undo.

enum Tool { SCULPT_ADD, SCULPT_REMOVE, VOXEL_PLACE, VOXEL_REMOVE, DENSITY }

var _terrain: VoxelTerrain
# -1 when no tool is active; the viewport then behaves normally.
var _tool := -1
var _toolbar := HBoxContainer.new()
var _radius := SpinBox.new()
var _strength := SpinBox.new()
var _type := OptionButton.new()


func _enter_tree() -> void:
	var tool_group := ButtonGroup.new()
	tool_group.allow_unpress = true
	for tool in Tool.size():
		var button := Button.new()
		button.text = Tool.keys()[tool].capitalize()
		button.toggle_mode = true
		button.button_group = tool_group
		button.toggled.connect(_on_tool_toggled.bind(tool))
		_toolbar.add_child(button)
	_radius.prefix = "Radius"
	_radius.min_value = 1.0
	_radius.max_value = 16.0
	_radius.value = 4.0
	_toolbar.add_child(_radius)
	# Density tool only: added to the density at the brush centre per stroke step; negative lowers.
	_strength.prefix = "Strength"
	_strength.min_value = -4.0
	_strength.max_value = 4.0
	_strength.step = 0.1
	_strength.value = 0.5
	_toolbar.add_child(_strength)
	# Indexed by VoxelChunk.Type.
	for type_name: String in VoxelChunk.Type.keys():
		_type.add_item(type_name.capitalize())
	_toolbar.add_child(_type)
	_toolbar.hide()
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _toolbar)


func _exit_tree() -> void:
	remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _toolbar)
	_toolbar.queue_free()


func _handles(object: Object) -> bool:
	return object is VoxelTerrain


func _edit(object: Object) -> void:
	_terrain = object as VoxelTerrain


func _make_visible(visible: bool) -> void:
	_toolbar.visible = visible


func _forward_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
	if _terrain == null or _tool == -1:
		return AFTER_GUI_INPUT_PASS
	var mouse_button := event as InputEventMouseButton
	if mouse_button != null and mouse_button.button_index == MOUSE_BUTTON_LEFT:
		if mouse_button.pressed:
			_apply(camera, mouse_button.position)
		# Consumes the release too, so the click never reaches selection.
		return AFTER_GUI_INPUT_STOP
	var motion := event as InputEventMouseMotion
	# Single-voxel tools act per click; dragging them would stack voxels toward the camera.
	var is_brush := _tool not in [Tool.VOXEL_PLACE, Tool.VOXEL_REMOVE]
	if motion != null and motion.button_mask & MOUSE_BUTTON_MASK_LEFT and is_brush:
		_apply(camera, motion.position)
		return AFTER_GUI_INPUT_STOP
	return AFTER_GUI_INPUT_PASS


func _on_tool_toggled(pressed: bool, tool: Tool) -> void:
	if pressed:
		_tool = tool
	elif _tool == tool:
		_tool = -1


func _apply(camera: Camera3D, screen_position: Vector2) -> void:
	# Terrain-local space: one unit per sample, samples at integer positions.
	var to_terrain := _terrain.global_transform.affine_inverse()
	var origin := to_terrain * camera.project_ray_origin(screen_position)
	var direction := (to_terrain.basis * camera.project_ray_normal(screen_position)).normalized()
	# Quarter-unit steps over 200 units, nearest sample per step. The last air sample before the
	# first solid one is where a voxel is placed.
	var previous := Vector3i(origin.round())
	for step in 800:
		var hit := origin + direction * step * 0.25
		var sample := Vector3i(hit.round())
		if _terrain.get_density(sample) > 0.0:
			match _tool:
				Tool.VOXEL_PLACE:
					_terrain.set_voxel(previous, 1.0, _type.selected as VoxelChunk.Type)
				Tool.VOXEL_REMOVE:
					# Air samples' types are never read when meshing.
					_terrain.set_voxel(sample, -1.0, _type.selected as VoxelChunk.Type)
				_:
					_brush(hit)
			# set_voxel changes saved data the editor does not track; without this, closing the
			# scene loses the edit without a prompt.
			EditorInterface.mark_scene_as_unsaved()
			return
		previous = sample


func _brush(center: Vector3) -> void:
	var radius := _radius.value
	var begin := Vector3i((center - Vector3.ONE * radius).ceil())
	var end := Vector3i((center + Vector3.ONE * radius).floor())
	for z in range(begin.z, end.z + 1):
		for y in range(begin.y, end.y + 1):
			for x in range(begin.x, end.x + 1):
				var sample := Vector3i(x, y, z)
				var distance := center.distance_to(Vector3(sample))
				if distance > radius:
					continue
				var density := _terrain.get_density(sample)
				var new_density := density
				match _tool:
					# Signed distance union/subtraction with the brush sphere.
					Tool.SCULPT_ADD:
						new_density = maxf(density, radius - distance)
					Tool.SCULPT_REMOVE:
						new_density = minf(density, distance - radius)
					Tool.DENSITY:
						new_density = density + _strength.value * (1.0 - distance / radius)
				# Untouched samples are skipped so their chunks do not become authored.
				if new_density == density:
					continue
				# Solid samples keep their type; air turning solid takes the selected one.
				var type: VoxelChunk.Type = _terrain.get_type(sample) if density > 0.0 \
					else _type.selected as VoxelChunk.Type
				_terrain.set_voxel(sample, new_density, type)
