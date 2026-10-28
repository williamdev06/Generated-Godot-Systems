@tool
class_name VolumetricSkyEffect
extends CompositorEffect
# OWNS:       GPU atmosphere LUTs, cloud noise, cloud raymarch and compositing.
# DEPENDS:    RenderingDevice, shaders/*.glsl, VolumetricSky (writes sun_* every frame).
# INVARIANTS: _update_params packing matches shaders/params.glslinc (INV-2). Uniform bindings match
#             each shader's declarations (INV-3). sun_illuminance uses the x PI convention (INV-4).
# GOTCHAS:    All RenderingDevice work runs on the render thread (_initialize, _render_callback).
#             One instance serves every viewport using the environment (editor + game). Shared LUTs are
#             recomputed inside each callback before use; per-viewport cloud history lives in
#             RenderSceneBuffersRD. Only view 0 of non-MSAA buffers is read: MSAA and XR are unsupported.
#             Godot does not reimport a .glsl when only an included .glslinc changes: after editing an
#             include, reimport the .glsl files (Import dock) or delete .godot/imported/*.glsl-*.
#             Writes the cloud_shadow_area / cloud_shadow_sun shader globals (project.godot) every frame;
#             with several viewports (editor) the last one rendered wins; same for sun_transmittance.

const SHADER_DIRECTORY := "res://volumetric_sky/shaders/"
const SHADER_NAMES: Array[String] = [
	"noise_gen", "transmittance_lut", "multi_scatter_lut", "sky_view_lut", "aerial_perspective",
	"cloud_panorama", "clouds_raymarch", "clouds_temporal", "composite", "cloud_shadow_map",
	"beer_shadow_map", "aerial_perspective_temporal", "weather_gen",
]
# Per-viewport froxel textures owned by this effect (D-10): raw = this frame's jittered result,
# _0/_1 = ping-pong accumulation, indexed like the cloud history.
const FROXEL_TEXTURE_KEYS: Array[String] = [
	"aerial_perspective_raw", "aerial_perspective_0", "aerial_perspective_1",
	"sky_shadow_loss_raw", "sky_shadow_loss_0", "sky_shadow_loss_1",
]
const TRANSMITTANCE_SIZE := Vector2i(256, 64)
const MULTI_SCATTER_SIZE := Vector2i(32, 32)
const SKY_VIEW_SIZE := Vector2i(256, 128)
const CLOUD_PANORAMA_SIZE := Vector2i(128, 64)
const SHAPE_NOISE_SIZE := 128
const DETAIL_NOISE_SIZE := 32
const WEATHER_NOISE_SIZE := 512
const PARAMS_SIZE_BYTES := 432
# Replaced shadow maps are freed this many frames later, after VolumetricSky has rebound its textures.
const RETIRE_DELAY_FRAMES := 4
# Mirror shaders/atmosphere.glslinc (INV-1); used for the CPU-side sun transmittance.
const GROUND_RADIUS_KM := 6360.0
const TOP_RADIUS_KM := 6460.0
const RAYLEIGH_SCATTERING := Vector3(5.802e-3, 13.558e-3, 33.1e-3)
const MIE_EXTINCTION := 4.440e-3
const OZONE_ABSORPTION := Vector3(0.650e-3, 1.881e-3, 0.085e-3)
const CONTEXT := &"volumetric_sky"
const HISTORY_NAMES: Array[StringName] = [&"cloud_history_0", &"cloud_history_1"]
const RGBA16F := RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
const RGBA8 := RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
const SAMPLED_STORAGE := RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT

@export_group("Clouds")
@export_range(0.0, 1.0) var coverage := 0.5
## Cloud extinction per km at full density.
@export var density := 30.0
## Wind velocity along world X/Z in meters per second.
@export var wind := Vector2(10.0, 4.0)
## Optional. R = coverage (scaled by `coverage`), G = cloud type (0 stratus, 0.5 stratocumulus, 1 cumulus).
@export var weather_map: Texture2D
## Kilometers covered by one tile of `weather_map`, centered on the world origin.
@export var weather_map_size_km := 50.0
## Altitude of the cloud layer's base above sea level (world y = 0).
@export_range(0.0, 15.0, 0.05, "suffix:km") var cloud_bottom_km := 1.5
## Altitude of the cloud layer's top; kept at least 100 m above the base.
@export_range(0.1, 20.0, 0.05, "suffix:km") var cloud_top_km := 4.0
## Tile size of the base shape noise. Larger = bigger cloud masses.
@export_range(0.5, 100.0, 0.1, "suffix:km") var shape_noise_scale_km := 12.0
## Tile size of the erosion detail noise. Smaller = finer wisps and billows.
@export_range(0.05, 20.0, 0.05, "suffix:km") var detail_noise_scale_km := 1.5
## Tile size of the procedural coverage/type pattern (unused with a weather_map). Larger = bigger
## clear and cloudy regions.
@export_range(1.0, 500.0, 1.0, "suffix:km") var weather_noise_scale_km := 60.0
## How much procedural coverage varies around `coverage` across the weather pattern.
@export_range(0.0, 2.0, 0.01) var coverage_variation := 0.6
## How strongly detail noise erodes cloud edges.
@export_range(0.0, 1.0, 0.01) var detail_erosion := 0.2

@export_group("Cloud Lighting")
## Anisotropy of the forward-scattering lobe (silver linings when facing the sun).
@export_range(0.0, 0.99, 0.01) var forward_scattering := 0.8
## Anisotropy of the back-scattering lobe (brightness when the sun is behind you).
@export_range(-0.99, 0.0, 0.01) var back_scattering := -0.3
## Share of the back-scattering lobe in the phase function.
@export_range(0.0, 1.0, 0.01) var back_scattering_blend := 0.3
## Per-octave falloff of the multiple-scattering approximation. Higher = brighter, softer cloud interiors.
@export_range(0.0, 0.95, 0.01) var multi_scattering := 0.5
## Multiplier on sky and ground-bounce ambient light inside clouds.
@export_range(0.0, 4.0, 0.01) var ambient_strength := 1.0
## Share of cloud extinction that scatters rather than absorbs. Lower = darker, dirtier clouds.
@export_range(0.0, 1.0, 0.01) var cloud_albedo := 1.0
## How far toward the sun each sample looks for self-shadowing.
@export_range(0.1, 10.0, 0.1, "suffix:km") var self_shadow_distance_km := 2.0

@export_group("Cloud Quality")
## Cloud render resolution relative to the screen; edges are upsampled depth-aware.
@export_range(0.25, 1.0, 0.05) var cloud_resolution_scale := 0.5
## Trace one cloud pixel per 2x2 block each frame and rebuild the rest from history (Horizon Zero Dawn
## style): ~4x cheaper raymarch, at the cost of more ghosting during fast camera motion.
@export var cloud_checkerboard := true
## Raymarch steps per cloud pixel.
@export_range(16, 256, 1) var cloud_steps := 64
## Self-shadow steps per raymarch sample.
@export_range(1, 16, 1) var cloud_light_steps := 6
## Clouds beyond this distance from the camera are not drawn.
@export_range(10.0, 300.0, 1.0, "suffix:km") var cloud_max_distance_km := 100.0
## Share of last frame's clouds kept each frame. Higher = smoother, more ghosting on fast motion.
@export_range(0.0, 0.98, 0.01) var cloud_temporal_amount := 0.9
## Beyond this distance clouds skip detail-noise erosion (faded out from 70% of it). Lower = faster.
@export_range(1.0, 300.0, 1.0, "suffix:km") var cloud_detail_lod_distance_km := 30.0

@export_group("Atmosphere")
## Aerosol (Mie) density relative to clean Earth air. Higher = hazier, whiter sky, redder sun and more
## visible light shafts. Changing it recomputes the transmittance and multi-scattering LUTs.
@export_range(0.0, 20.0, 0.01) var haze := 1.0
## Average ground reflectance: light bounced into the atmosphere and the cloud bases. Changing it
## recomputes the multi-scattering LUT.
@export var ground_albedo := Color(0.3, 0.3, 0.3)
## Refresh the sky's ambient/reflection cubemap every this many frames (1 = every frame). Sun movement
## still refreshes it immediately (Godot tracks the light).
@export_range(1, 30, 1) var sky_update_interval := 4

@export_group("Shafts")
## How strongly clouds shadow the air (crepuscular rays). 0 = off, 1 = physical. Material cloud shadows
## are unaffected.
@export_range(0.0, 1.0, 0.01) var shaft_strength := 1.0
## Multiplier on sunlight scattered by aerosols/droplets (Mie) within 100 km of the camera: brighter
## beams and sun glow, so shafts read more strongly (e.g. 2-5 in rain or mist). Mie scatters forward, so
## it shows mostly when facing the sun. Artistic: blue sky color, distant dimming and ambient are unchanged.
@export_range(0.0, 10.0, 0.01) var shaft_intensity := 1.0
## Width of the sun-aligned area around the camera where clouds cast shafts and material cloud shadows.
## Larger reaches further but makes both blurrier (see shadow_map_resolution).
@export_range(8.0, 256.0, 1.0, "suffix:km") var shaft_distance_km := 64.0
## Screen size of one aerial perspective froxel. Smaller = sharper shafts and haze edges, but the
## pass cost grows with the square of the reduction.
@export_range(4, 64, 1, "suffix:px") var shaft_froxel_size_px := 8
## Depth slices of the aerial perspective volume (spread quadratically out to 100 km). More = smoother
## shafts along the view direction; cost grows faster than linearly.
@export_range(16, 128, 1) var shaft_depth_slices := 32
## Like Godot's volumetric fog temporal reprojection amount: the share of last frame's froxels kept each
## frame. > 0 jitters froxel samples every frame and accumulates them, smoothing slice and step banding;
## higher is smoother but ghosts longer. 0 disables jitter and accumulation.
@export_range(0.0, 0.99, 0.01) var shaft_temporal_amount := 0.9

@export_group("Shadow Maps")
## Resolution of the sun-aligned Beer shadow map (material cloud shadows and shafts) over
## shaft_distance_km.
@export_range(128, 2048, 64) var shadow_map_resolution := 512
## Resolution of the top-down cloud AO map over cloud_ao_map_size_km. AO is very soft, so low is fine.
@export_range(64, 2048, 64) var cloud_ao_map_resolution := 256
## Width of the area around the camera that gets cloud ambient occlusion.
@export_range(5.0, 200.0, 1.0, "suffix:km") var cloud_ao_map_size_km := 40.0
## How strongly clouds block sky light in material AO. 1 = by the full sky visibility through clouds;
## lower leaves room for light the clouds themselves scatter down, which the AO map doesn't model.
@export_range(0.0, 1.0, 0.01) var cloud_ao_strength := 1.0
## Recompute the Beer shadow map and cloud AO map every this many frames (1 = every frame). Clouds move
## centimeters per frame, so higher saves time with no visible change; resolution or extent changes
## always refresh immediately.
@export_range(1, 16, 1) var shadow_map_update_interval := 4

# Written every frame by VolumetricSky from the scene's DirectionalLight3D. Illuminance is above the
# atmosphere; the atmosphere's own transmittance is applied in the shaders.
var sun_direction := Vector3.UP
var sun_illuminance := Vector3.ONE * PI
# Atmosphere transmittance toward the sun at the camera; VolumetricSky copies it to the light color.
var sun_transmittance := Color.WHITE
# Camera altitude the sky-view LUT was last built for; VolumetricSky passes it to the sky shader.
var camera_altitude_km := 0.0005

# sky_view_lut, cloud_panorama, cloud_shadow_map and beer_shadow_map are bound by VolumetricSky into the
# sky shader and the cloud_shadow_map / beer_shadow_map globals. Valid once _initialize has run.
var transmittance_lut: RID
var sky_view_lut: RID
var cloud_panorama: RID
var cloud_shadow_map: RID
var beer_shadow_map: RID

var _rd: RenderingDevice
var _shaders := {}
var _pipelines := {}
var _multi_scatter_lut: RID
var _shape_noise: RID
var _detail_noise: RID
var _procedural_weather: RID
var _empty_weather_map: RID
# [RID, frame index after which it may be freed]; see RETIRE_DELAY_FRAMES.
var _retired_textures := []
var _params_buffer: RID
var _linear_clamp_sampler: RID
var _linear_repeat_sampler: RID
var _nearest_sampler: RID
var _frame_index := 0
# [haze, ground_albedo] the transmittance / multi-scattering LUTs were last computed with.
var _lut_settings := []
# Frame and placement the shadow maps were last computed with; shaders and material globals must use
# these, not the current camera, until the next refresh (shadow_map_update_interval).
var _beer_frame := PackedVector3Array()
var _cloud_ao_center := Vector2.ZERO
var _shadow_map_settings := []
var _frames_since_shadow_update := 0
# RenderSceneBuffersRD instance id -> { cloud_size, history_index, history_valid, previous_view_projection,
# froxel_grid, froxel_history_valid, previous_camera_position, FROXEL_TEXTURE_KEYS... }.
# Froxel textures are ours to free, not the buffers'.
var _viewport_state := {}


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT
	_rd = RenderingServer.get_rendering_device()
	RenderingServer.call_on_render_thread(_initialize)


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE:
		return
	var rids: Array = [
		transmittance_lut, _multi_scatter_lut, sky_view_lut, cloud_panorama, cloud_shadow_map, beer_shadow_map,
		_shape_noise, _detail_noise, _procedural_weather, _empty_weather_map, _params_buffer,
		_linear_clamp_sampler, _linear_repeat_sampler, _nearest_sampler,
	]
	for retired: Array in _retired_textures:
		rids.append(retired[0])
	for state: Dictionary in _viewport_state.values():
		for texture_key in FROXEL_TEXTURE_KEYS:
			rids.append(state.get(texture_key, RID()))
	# Freeing a shader also frees its pipeline and uniform sets.
	for rid: RID in rids + _shaders.values():
		if rid.is_valid():
			_rd.free_rid(rid)


func _initialize() -> void:
	for shader_name in SHADER_NAMES:
		var shader_file: RDShaderFile = load(SHADER_DIRECTORY + shader_name + ".glsl")
		var shader := _rd.shader_create_from_spirv(shader_file.get_spirv())
		_shaders[shader_name] = shader
		_pipelines[shader_name] = _rd.compute_pipeline_create(shader)

	_linear_clamp_sampler = _create_sampler(RenderingDevice.SAMPLER_FILTER_LINEAR, RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE)
	_linear_repeat_sampler = _create_sampler(RenderingDevice.SAMPLER_FILTER_LINEAR, RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT)
	_nearest_sampler = _create_sampler(RenderingDevice.SAMPLER_FILTER_NEAREST, RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE)

	transmittance_lut = _create_texture(Vector3i(TRANSMITTANCE_SIZE.x, TRANSMITTANCE_SIZE.y, 1), RGBA16F)
	_multi_scatter_lut = _create_texture(Vector3i(MULTI_SCATTER_SIZE.x, MULTI_SCATTER_SIZE.y, 1), RGBA16F)
	sky_view_lut = _create_texture(Vector3i(SKY_VIEW_SIZE.x, SKY_VIEW_SIZE.y, 1), RGBA16F)
	cloud_panorama = _create_texture(Vector3i(CLOUD_PANORAMA_SIZE.x, CLOUD_PANORAMA_SIZE.y, 1), RGBA16F)
	# cloud_shadow_map and beer_shadow_map are sized from settings in _ensure_shadow_maps.
	_shape_noise = _create_texture(Vector3i.ONE * SHAPE_NOISE_SIZE, RGBA8)
	_detail_noise = _create_texture(Vector3i.ONE * DETAIL_NOISE_SIZE, RGBA8)
	_procedural_weather = _create_texture(Vector3i(WEATHER_NOISE_SIZE, WEATHER_NOISE_SIZE, 1), RGBA8)
	# Bound when weather_map is null; the shaders never read it because cloud_settings.z is 0.
	var empty_format := _create_format(Vector3i.ONE, RGBA8, RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT)
	_empty_weather_map = _rd.texture_create(empty_format, RDTextureView.new(), [PackedByteArray([0, 0, 0, 0])])
	_params_buffer = _rd.uniform_buffer_create(PARAMS_SIZE_BYTES)

	# Noise never changes; the transmittance / multi-scattering LUTs are computed in _render_callback.
	_dispatch("noise_gen", [_image_uniform(0, _shape_noise)], _groups_3d(Vector3i.ONE * SHAPE_NOISE_SIZE), PackedFloat32Array([0.0, 0.0, 0.0, 0.0]).to_byte_array())
	_dispatch("noise_gen", [_image_uniform(0, _detail_noise)], _groups_3d(Vector3i.ONE * DETAIL_NOISE_SIZE), PackedFloat32Array([1.0, 0.0, 0.0, 0.0]).to_byte_array())
	_dispatch("weather_gen", [_image_uniform(0, _procedural_weather)], _groups_2d(Vector2i(WEATHER_NOISE_SIZE, WEATHER_NOISE_SIZE)))


func _render_callback(_callback_type: int, render_data: RenderData) -> void:
	var scene_buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var scene_data := render_data.get_render_scene_data() as RenderSceneDataRD
	var full_size := scene_buffers.get_internal_size()
	var cloud_size := Vector2i((Vector2(full_size) * cloud_resolution_scale).ceil()).max(Vector2i.ONE)
	# The raymarch traces one cloud pixel per block; clouds_temporal rebuilds the rest from history.
	var block_size := 2 if cloud_checkerboard else 1
	var traced_size := (cloud_size + Vector2i.ONE * (block_size - 1)) / block_size
	var state := _get_viewport_state(scene_buffers, cloud_size, traced_size)
	_ensure_shadow_maps()
	var camera_position := scene_data.get_cam_transform().origin
	var shadow_map_settings := [shadow_map_resolution, cloud_ao_map_resolution, shaft_distance_km, cloud_ao_map_size_km]
	var update_shadow_maps := _beer_frame.is_empty() or shadow_map_settings != _shadow_map_settings \
		or _frames_since_shadow_update >= shadow_map_update_interval - 1
	if update_shadow_maps:
		var shadow_texel_m := cloud_ao_map_size_km * 1000.0 / cloud_ao_map_resolution
		# Snapped to whole texels so shadows don't shimmer as the camera moves.
		_cloud_ao_center = (Vector2(camera_position.x, camera_position.z) / shadow_texel_m).floor() * shadow_texel_m
		_beer_frame = _beer_shadow_frame(camera_position)
		_shadow_map_settings = shadow_map_settings
		_frames_since_shadow_update = 0
	else:
		_frames_since_shadow_update += 1
	var shadow_center := _cloud_ao_center
	var beer_frame := _beer_frame
	# Before _update_params: a rebuild resets froxel_history_valid, which goes into the params.
	_ensure_froxel_textures(state, full_size)
	var view_projection := _update_params(scene_data, state, full_size, cloud_size, shadow_center, beer_frame)
	camera_altitude_km = maxf(camera_position.y * 0.001, 0.0005)
	sun_transmittance = _sun_transmittance(camera_altitude_km)

	var weather_texture := _empty_weather_map
	if weather_map != null:
		weather_texture = RenderingServer.texture_get_rd_texture(weather_map.get_rid())
	var params := _uniform_buffer_uniform(0, _params_buffer)
	var atmosphere_inputs := [
		_sampler_uniform(1, transmittance_lut, _linear_clamp_sampler),
		_sampler_uniform(2, _multi_scatter_lut, _linear_clamp_sampler),
	]
	var cloud_inputs := [
		_sampler_uniform(3, sky_view_lut, _linear_clamp_sampler),
		_sampler_uniform(4, _shape_noise, _linear_repeat_sampler),
		_sampler_uniform(5, _detail_noise, _linear_repeat_sampler),
		_sampler_uniform(6, weather_texture, _linear_repeat_sampler),
		_sampler_uniform(11, _procedural_weather, _linear_repeat_sampler),
	]
	var depth_texture := scene_buffers.get_depth_layer(0)
	var cloud_current := scene_buffers.get_texture(CONTEXT, &"cloud_current")
	var cloud_distance := scene_buffers.get_texture(CONTEXT, &"cloud_distance")
	var history_index: int = state["history_index"]
	var history_read := scene_buffers.get_texture(CONTEXT, HISTORY_NAMES[1 - history_index])
	var history_write := scene_buffers.get_texture(CONTEXT, HISTORY_NAMES[history_index])
	# Accumulated froxels share the cloud history's ping-pong index.
	var aerial_perspective: RID = state["aerial_perspective_%d" % history_index]
	var sky_shadow_loss: RID = state["sky_shadow_loss_%d" % history_index]

	# Only haze and ground albedo vary in the atmosphere model, so these two LUTs are recomputed only
	# when they change.
	var lut_settings := [haze, ground_albedo]
	if lut_settings != _lut_settings:
		_dispatch("transmittance_lut", [params, _image_uniform(1, transmittance_lut)], _groups_2d(TRANSMITTANCE_SIZE))
		_dispatch("multi_scatter_lut", [
			params,
			_image_uniform(1, _multi_scatter_lut),
			_sampler_uniform(2, transmittance_lut, _linear_clamp_sampler),
		], _groups_2d(MULTI_SCATTER_SIZE))
		_lut_settings = lut_settings
	_dispatch("sky_view_lut", [params] + atmosphere_inputs + [_image_uniform(3, sky_view_lut)], _groups_2d(SKY_VIEW_SIZE))
	# The panorama only feeds the sky cubemap, which VolumetricSky refreshes every sky_update_interval frames.
	if _frame_index % sky_update_interval == 0:
		_dispatch("cloud_panorama", [params] + atmosphere_inputs + cloud_inputs + [_image_uniform(7, cloud_panorama)], _groups_2d(CLOUD_PANORAMA_SIZE))
	# Computed even at shaft_strength 0: material cloud shadows read it too.
	if update_shadow_maps:
		_dispatch("beer_shadow_map", [params, atmosphere_inputs[0]] + cloud_inputs + [_image_uniform(7, beer_shadow_map)], _groups_2d(Vector2i.ONE * shadow_map_resolution))
	_dispatch("aerial_perspective", [params] + atmosphere_inputs + [
		_image_uniform(3, state["aerial_perspective_raw"]),
		_sampler_uniform(4, beer_shadow_map, _linear_clamp_sampler),
		_image_uniform(5, state["sky_shadow_loss_raw"]),
	], _groups_2d(Vector2i(state["froxel_grid"].x, state["froxel_grid"].y)))
	_dispatch("aerial_perspective_temporal", [
		params,
		_image_uniform(1, state["aerial_perspective_raw"]),
		_sampler_uniform(2, state["aerial_perspective_%d" % (1 - history_index)], _linear_clamp_sampler),
		_image_uniform(3, aerial_perspective),
		_image_uniform(4, state["sky_shadow_loss_raw"]),
		_sampler_uniform(5, state["sky_shadow_loss_%d" % (1 - history_index)], _linear_clamp_sampler),
		_image_uniform(6, sky_shadow_loss),
	], _groups_3d(state["froxel_grid"]))
	_dispatch("clouds_raymarch", [params, atmosphere_inputs[0]] + cloud_inputs + [
		_sampler_uniform(7, aerial_perspective, _linear_clamp_sampler),
		_sampler_uniform(8, depth_texture, _nearest_sampler),
		_image_uniform(9, cloud_current),
		_image_uniform(10, cloud_distance),
	], _groups_2d(traced_size))
	_dispatch("clouds_temporal", [
		params,
		_image_uniform(1, cloud_current),
		_image_uniform(2, cloud_distance),
		_sampler_uniform(3, history_read, _linear_clamp_sampler),
		_image_uniform(4, history_write),
	], _groups_2d(cloud_size))
	_dispatch("composite", [
		params,
		_image_uniform(1, scene_buffers.get_color_layer(0)),
		_sampler_uniform(2, depth_texture, _nearest_sampler),
		_sampler_uniform(3, aerial_perspective, _linear_clamp_sampler),
		_sampler_uniform(4, history_write, _linear_clamp_sampler),
		_sampler_uniform(5, sky_shadow_loss, _linear_clamp_sampler),
	], _groups_2d(full_size))
	if update_shadow_maps:
		_dispatch("cloud_shadow_map", [params, atmosphere_inputs[0]] + cloud_inputs + [_image_uniform(7, cloud_shadow_map)], _groups_2d(Vector2i.ONE * cloud_ao_map_resolution))
	# Materials read these next frame together with the map written above, so they stay in sync.
	RenderingServer.global_shader_parameter_set(&"cloud_shadow_area", Vector4(shadow_center.x, shadow_center.y, cloud_ao_map_size_km * 1000.0, cloud_ao_strength))
	RenderingServer.global_shader_parameter_set(&"cloud_shadow_sun", Vector4(sun_direction.x, sun_direction.y, sun_direction.z, _cloud_top_km() * 1000.0))
	RenderingServer.global_shader_parameter_set(&"beer_shadow_center", Vector4(beer_frame[0].x, beer_frame[0].y, beer_frame[0].z, 0.0))
	RenderingServer.global_shader_parameter_set(&"beer_shadow_tangent", Vector4(beer_frame[1].x, beer_frame[1].y, beer_frame[1].z, shaft_distance_km))
	RenderingServer.global_shader_parameter_set(&"beer_shadow_bitangent", Vector4(beer_frame[2].x, beer_frame[2].y, beer_frame[2].z, 0.0))

	state["previous_view_projection"] = view_projection
	state["history_index"] = 1 - history_index
	state["history_valid"] = true
	state["froxel_history_valid"] = true
	state["previous_camera_position"] = camera_position
	_frame_index += 1


func _get_viewport_state(scene_buffers: RenderSceneBuffersRD, cloud_size: Vector2i, traced_size: Vector2i) -> Dictionary:
	var key := scene_buffers.get_instance_id()
	var state: Dictionary = _viewport_state.get(key, {})
	var has_textures := scene_buffers.has_texture(CONTEXT, &"cloud_current")
	if not state.is_empty() and state["cloud_size"] == cloud_size and state["traced_size"] == traced_size and has_textures:
		return state
	if has_textures:
		scene_buffers.clear_context(CONTEXT)
	var history_format := _create_format(Vector3i(cloud_size.x, cloud_size.y, 1), RGBA16F, SAMPLED_STORAGE)
	for texture_name: StringName in HISTORY_NAMES:
		scene_buffers.create_texture_from_format(CONTEXT, texture_name, history_format, RDTextureView.new(), true)
	# Raymarch outputs hold one texel per checkerboard block.
	var traced_format := _create_format(Vector3i(traced_size.x, traced_size.y, 1), RGBA16F, SAMPLED_STORAGE)
	scene_buffers.create_texture_from_format(CONTEXT, &"cloud_current", traced_format, RDTextureView.new(), true)
	var distance_format := _create_format(Vector3i(traced_size.x, traced_size.y, 1), RenderingDevice.DATA_FORMAT_R32_SFLOAT, SAMPLED_STORAGE)
	scene_buffers.create_texture_from_format(CONTEXT, &"cloud_distance", distance_format, RDTextureView.new(), true)
	# Assigned in place so froxel entries from _ensure_froxel_textures survive a cloud resize.
	state["cloud_size"] = cloud_size
	state["traced_size"] = traced_size
	state["history_index"] = 0
	state["history_valid"] = false
	state["previous_view_projection"] = Projection.IDENTITY
	_viewport_state[key] = state
	return state


# (Re)creates the shadow maps when their resolution settings change, and frees replaced ones once
# VolumetricSky has had time to rebind its Texture2DRDs to the new RIDs.
func _ensure_shadow_maps() -> void:
	for retired: Array in _retired_textures.duplicate():
		if _frame_index > retired[1]:
			_rd.free_rid(retired[0])
			_retired_textures.erase(retired)
	if _texture_width(beer_shadow_map) != shadow_map_resolution:
		_retire_texture(beer_shadow_map)
		beer_shadow_map = _create_texture(Vector3i(shadow_map_resolution, shadow_map_resolution, 1), RGBA16F)
	if _texture_width(cloud_shadow_map) != cloud_ao_map_resolution:
		_retire_texture(cloud_shadow_map)
		cloud_shadow_map = _create_texture(Vector3i(cloud_ao_map_resolution, cloud_ao_map_resolution, 1), RenderingDevice.DATA_FORMAT_R16_SFLOAT)


func _texture_width(texture: RID) -> int:
	return _rd.texture_get_format(texture).width if texture.is_valid() else 0


func _retire_texture(texture: RID) -> void:
	if texture.is_valid():
		_retired_textures.append([texture, _frame_index + RETIRE_DELAY_FRAMES])


func _cloud_top_km() -> float:
	return maxf(cloud_top_km, cloud_bottom_km + 0.1)


# (Re)creates this viewport's aerial perspective volume and sky shadow loss when the screen size or the
# froxel settings change. The grid is sized from screen pixels, so it can't be shared between viewports.
func _ensure_froxel_textures(state: Dictionary, full_size: Vector2i) -> void:
	var froxel_grid := Vector3i(ceili(full_size.x / float(shaft_froxel_size_px)), ceili(full_size.y / float(shaft_froxel_size_px)), shaft_depth_slices)
	if state.get("froxel_grid", Vector3i.ZERO) == froxel_grid:
		return
	for texture_key in FROXEL_TEXTURE_KEYS:
		if state.has(texture_key):
			_rd.free_rid(state[texture_key])
		var is_volume := texture_key.begins_with("aerial_perspective")
		state[texture_key] = _create_texture(froxel_grid if is_volume else Vector3i(froxel_grid.x, froxel_grid.y, 1), RGBA16F)
	state["froxel_grid"] = froxel_grid
	state["froxel_history_valid"] = false


# Packs shaders/params.glslinc (INV-2). Returns this frame's view-projection for next frame's reprojection.
func _update_params(scene_data: RenderSceneDataRD, state: Dictionary, full_size: Vector2i, cloud_size: Vector2i, shadow_center: Vector2, beer_frame: PackedVector3Array) -> Projection:
	var camera_transform := scene_data.get_cam_transform()
	var view_projection := scene_data.get_cam_projection() * Projection(camera_transform.affine_inverse())
	var camera_position := camera_transform.origin
	var weather_map_size := weather_map_size_km if weather_map != null else 0.0
	var data := PackedFloat32Array()
	data.append_array(_projection_floats(view_projection.inverse()))
	data.append_array(_projection_floats(state["previous_view_projection"]))
	# World y = 0 is sea level; clamp keeps LUT lookups above the ground sphere.
	data.append_array([camera_position.x, camera_position.y, camera_position.z, maxf(camera_position.y * 0.001, 0.0005)])
	data.append_array([sun_direction.x, sun_direction.y, sun_direction.z, 0.0])
	data.append_array([sun_illuminance.x, sun_illuminance.y, sun_illuminance.z, 0.0])
	data.append_array([coverage, density, weather_map_size, 2.0 if cloud_checkerboard else 1.0])
	data.append_array([wind.x * 0.001, wind.y * 0.001, 0.0, 0.0])
	data.append_array([cloud_size.x, cloud_size.y, full_size.x, full_size.y])
	# Frame index wraps so it stays exact as a float (checkerboard order, jitter sequences).
	data.append_array([Time.get_ticks_msec() * 0.001, _frame_index % 65536, 1.0 if state["history_valid"] else 0.0, 0.0])
	data.append_array([shadow_center.x, shadow_center.y, cloud_ao_map_size_km * 1000.0, 0.0])
	data.append_array([beer_frame[0].x, beer_frame[0].y, beer_frame[0].z, 0.0])
	data.append_array([beer_frame[1].x, beer_frame[1].y, beer_frame[1].z, shaft_distance_km])
	data.append_array([beer_frame[2].x, beer_frame[2].y, beer_frame[2].z, 0.0])
	data.append_array([haze, shaft_strength, shaft_temporal_amount, shaft_intensity])
	var previous_camera_position: Vector3 = state.get("previous_camera_position", camera_position)
	data.append_array([previous_camera_position.x, previous_camera_position.y, previous_camera_position.z, 1.0 if state["froxel_history_valid"] else 0.0])
	data.append_array([cloud_bottom_km, _cloud_top_km(), cloud_max_distance_km, detail_erosion])
	data.append_array([shape_noise_scale_km, detail_noise_scale_km, weather_noise_scale_km, coverage_variation])
	data.append_array([forward_scattering, back_scattering, back_scattering_blend, multi_scattering])
	data.append_array([ambient_strength, self_shadow_distance_km, cloud_albedo, 0.0])
	data.append_array([cloud_steps, cloud_light_steps, cloud_temporal_amount, cloud_detail_lod_distance_km])
	data.append_array([ground_albedo.r, ground_albedo.g, ground_albedo.b, 0.0])
	var bytes := data.to_byte_array()
	_rd.buffer_update(_params_buffer, 0, bytes.size(), bytes)
	return view_projection


# Beer shadow map frame (INV-6) in cloud space (km: world x, altitude, world z): [center, tangent,
# bitangent], with tangent/bitangent spanning the map plane perpendicular to the sun.
func _beer_shadow_frame(camera_position: Vector3) -> PackedVector3Array:
	var sun := sun_direction.normalized()
	var tangent := sun.cross(Vector3.UP if absf(sun.y) < 0.999 else Vector3.BACK).normalized()
	var bitangent := sun.cross(tangent)
	var camera_cloud_space := camera_position * 0.001
	var texel_km := shaft_distance_km / shadow_map_resolution
	# Snapped to whole texels across the map plane so shafts and shadows don't shimmer as the camera moves.
	var center := tangent * snappedf(camera_cloud_space.dot(tangent), texel_km) \
		+ bitangent * snappedf(camera_cloud_space.dot(bitangent), texel_km) \
		+ sun * camera_cloud_space.dot(sun)
	return PackedVector3Array([center, tangent, bitangent])


# Atmosphere transmittance from altitude_km toward the sun; black once the planet blocks the sun.
# CPU mirror of the transmittance LUT so the DirectionalLight3D color can follow it without a readback.
func _sun_transmittance(altitude_km: float) -> Color:
	var sun := sun_direction.normalized()
	var origin := Vector3(0.0, GROUND_RADIUS_KM + altitude_km, 0.0)
	var b := origin.dot(sun)
	var ground_discriminant := b * b - (origin.length_squared() - GROUND_RADIUS_KM * GROUND_RADIUS_KM)
	if b < 0.0 and ground_discriminant >= 0.0:
		return Color.BLACK
	var distance_to_top := -b + sqrt(b * b - (origin.length_squared() - TOP_RADIUS_KM * TOP_RADIUS_KM))
	const SAMPLE_COUNT := 32
	var step_km := distance_to_top / SAMPLE_COUNT
	var optical_depth := Vector3.ZERO
	for i in SAMPLE_COUNT:
		var altitude := maxf((origin + sun * (i + 0.5) * step_km).length() - GROUND_RADIUS_KM, 0.0)
		var ozone_density := maxf(0.0, 1.0 - absf(altitude - 25.0) / 15.0)
		var extinction := RAYLEIGH_SCATTERING * exp(-altitude / 8.0) + Vector3.ONE * MIE_EXTINCTION * haze * exp(-altitude / 1.2) + OZONE_ABSORPTION * ozone_density
		optical_depth += extinction * step_km
	return Color(exp(-optical_depth.x), exp(-optical_depth.y), exp(-optical_depth.z))


func _projection_floats(projection: Projection) -> PackedFloat32Array:
	var floats := PackedFloat32Array()
	for column: Vector4 in [projection.x, projection.y, projection.z, projection.w]:
		floats.append_array([column.x, column.y, column.z, column.w])
	return floats


func _dispatch(shader_name: String, uniforms: Array, groups: Vector3i, push_constant := PackedByteArray()) -> void:
	var uniform_set := UniformSetCacheRD.get_cache(_shaders[shader_name], 0, uniforms)
	var compute_list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(compute_list, _pipelines[shader_name])
	_rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	if not push_constant.is_empty():
		_rd.compute_list_set_push_constant(compute_list, push_constant, push_constant.size())
	_rd.compute_list_dispatch(compute_list, groups.x, groups.y, groups.z)
	_rd.compute_list_end()


func _groups_2d(size: Vector2i) -> Vector3i:
	return Vector3i(ceili(size.x / 8.0), ceili(size.y / 8.0), 1)


func _groups_3d(size: Vector3i) -> Vector3i:
	return Vector3i(ceili(size.x / 4.0), ceili(size.y / 4.0), ceili(size.z / 4.0))


func _create_format(size: Vector3i, data_format: RenderingDevice.DataFormat, usage_bits: int) -> RDTextureFormat:
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_3D if size.z > 1 else RenderingDevice.TEXTURE_TYPE_2D
	format.width = size.x
	format.height = size.y
	format.depth = size.z
	format.format = data_format
	format.usage_bits = usage_bits
	return format


func _create_texture(size: Vector3i, data_format: RenderingDevice.DataFormat) -> RID:
	return _rd.texture_create(_create_format(size, data_format, SAMPLED_STORAGE), RDTextureView.new())


func _create_sampler(filter: RenderingDevice.SamplerFilter, repeat_mode: RenderingDevice.SamplerRepeatMode) -> RID:
	var sampler_state := RDSamplerState.new()
	sampler_state.min_filter = filter
	sampler_state.mag_filter = filter
	sampler_state.repeat_u = repeat_mode
	sampler_state.repeat_v = repeat_mode
	sampler_state.repeat_w = repeat_mode
	return _rd.sampler_create(sampler_state)


func _image_uniform(binding: int, texture: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = binding
	uniform.add_id(texture)
	return uniform


func _sampler_uniform(binding: int, texture: RID, sampler: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	uniform.binding = binding
	uniform.add_id(sampler)
	uniform.add_id(texture)
	return uniform


func _uniform_buffer_uniform(binding: int, buffer: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	uniform.binding = binding
	uniform.add_id(buffer)
	return uniform
