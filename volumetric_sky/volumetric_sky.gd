@tool
class_name VolumetricSky
extends Node
# OWNS:       Feeding the sun into VolumetricSkyEffect, tinting the sun by the atmosphere, binding the
#             effect's textures to the sky shader and the cloud_shadow_map / beer_shadow_map shader globals.
# DEPENDS:    DirectionalLight3D (sun), WorldEnvironment whose Compositor holds a VolumetricSkyEffect
#             and whose Sky uses a ShaderMaterial with sky.gdshader.
# INVARIANTS: The sun above the atmosphere is white with illuminance = energy x PI (INV-4); the light's
#             color is overwritten every frame with the atmosphere transmittance at the camera.
# GOTCHAS:    @tool so the editor viewport gets a live sky; this also rewrites light_color in the editor,
#             so a color set on the light by hand is lost. The effect creates its textures on the render
#             thread, so binding waits until its RIDs become valid; replaced shadow maps are freed a few
#             frames later (RETIRE_DELAY_FRAMES), so rebinding must happen within that window.
#             Requests a sky cubemap re-render every sky_update_interval frames via refresh_index.

@export var sun: DirectionalLight3D
@export var world_environment: WorldEnvironment

var _sky_view_texture := Texture2DRD.new()
var _cloud_panorama_texture := Texture2DRD.new()
var _cloud_shadow_texture := Texture2DRD.new()
var _beer_shadow_texture := Texture2DRD.new()


func _process(_delta: float) -> void:
	if sun == null or world_environment == null:
		return
	var effect := _find_effect()
	effect.sun_direction = sun.global_basis.z.normalized()
	effect.sun_illuminance = Vector3.ONE * sun.light_energy * PI
	sun.light_color = effect.sun_transmittance
	# Shadow maps are recreated when their resolution settings change, so recheck every RID.
	var bound := _sky_view_texture.texture_rd_rid == effect.sky_view_lut \
		and _cloud_shadow_texture.texture_rd_rid == effect.cloud_shadow_map \
		and _beer_shadow_texture.texture_rd_rid == effect.beer_shadow_map
	if effect.sky_view_lut.is_valid() and effect.beer_shadow_map.is_valid() and not bound:
		_bind_sky_textures(effect)
	var frame := Engine.get_process_frames()
	if frame % effect.sky_update_interval == 0:
		# A changed uniform makes Godot re-render the sky's radiance cubemap (see sky.gdshader GOTCHAS).
		var sky_material: ShaderMaterial = world_environment.environment.sky.sky_material
		sky_material.set_shader_parameter("camera_altitude_km", effect.camera_altitude_km)
		sky_material.set_shader_parameter("refresh_index", float(frame % 65536))


func _bind_sky_textures(effect: VolumetricSkyEffect) -> void:
	_sky_view_texture.texture_rd_rid = effect.sky_view_lut
	_cloud_panorama_texture.texture_rd_rid = effect.cloud_panorama
	var sky_material: ShaderMaterial = world_environment.environment.sky.sky_material
	sky_material.set_shader_parameter("sky_view_lut", _sky_view_texture)
	sky_material.set_shader_parameter("cloud_panorama", _cloud_panorama_texture)
	_cloud_shadow_texture.texture_rd_rid = effect.cloud_shadow_map
	RenderingServer.global_shader_parameter_set(&"cloud_shadow_map", _cloud_shadow_texture)
	_beer_shadow_texture.texture_rd_rid = effect.beer_shadow_map
	RenderingServer.global_shader_parameter_set(&"beer_shadow_map", _beer_shadow_texture)


func _find_effect() -> VolumetricSkyEffect:
	for effect in world_environment.compositor.compositor_effects:
		if effect is VolumetricSkyEffect:
			return effect
	return null
