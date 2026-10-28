# ARCHITECTURE

<!-- AGENT-MAINTAINED. Fixed schema — edit rows, never restructure. -->
<!-- CAP 150 lines. Over cap → compact per CLAUDE.md §8. -->
<!-- Code is authoritative. This file is a map, not a spec. -->

## STACK
Engine: Godot 4.7
Language: GDScript, GLSL compute (RDShaderFile), Godot shading language
Build: Godot editor (Forward+)
Target: Windows, D3D12

## MODULES
| id | path | owns | depends on | status |
|----|------|------|------------|--------|
| M-1 | volumetric_sky/volumetric_sky_effect.gd | GPU atmosphere LUTs, cloud raymarch, compositing | RenderingDevice, M-4, M-2 | active |
| M-2 | volumetric_sky/volumetric_sky.gd | Sun feed, sun tint, sky-shader texture binding | M-1, DirectionalLight3D, WorldEnvironment | active |
| M-3 | volumetric_sky/sky.gdshader | Sky background and radiance cubemap from LUTs | M-1 textures via M-2 | active |
| M-4 | volumetric_sky/shaders/ | Compute passes: LUTs, noise, clouds, composite | M-1 dispatch | active |
| M-5 | volumetric_sky/demo/ | Reference scene wiring M-1..M-3, M-6 | M-1, M-2, M-3, M-6 | active |
| M-6 | volumetric_sky/cloud_shadow.gdshaderinc | Cloud shadow, cloud AO, drop-in light() for materials | shader globals from M-1, M-2 | active |
| M-7 | voxel/voxel_terrain.gd | Streamed or contained chunk grid, threaded meshing, edits | M-8, M-9, M-10 | active |
| M-8 | voxel/voxel_chunk.gd | Per-chunk density and voxel type samples | none | active |
| M-9 | voxel/voxel_generator.gd | Procedural chunk density and type | M-8, FastNoiseLite | active |
| M-10 | voxel/marching_cubes.gd | Padded density grid to chunk ArrayMesh | M-8 | active |
| M-11 | voxel/demo/ | Reference scene for M-7 with M-9 | M-7, M-9 | active |

<!-- status: stable | active | stub | deprecated -->

## DATAFLOW
M-2 -> M-1: sun_direction, sun_illuminance; every _process
M-1 -> M-4: Params UBO (params.glslinc); every _render_callback (PRE_TRANSPARENT)
M-1 -> M-2: sky_view_lut, cloud_panorama, cloud_shadow_map, beer_shadow_map RIDs; once valid after _initialize
M-1 -> M-2: sun_transmittance (atmosphere transmittance at the camera); every _render_callback
M-2 -> DirectionalLight3D: light_color = sun_transmittance; every _process
M-2 -> M-3: Texture2DRD shader params sky_view_lut, cloud_panorama; on bind
M-4 beer_shadow_map -> aerial_perspective: cloud shadow on atmosphere (crepuscular rays) + sky_shadow_loss for sky pixels; every frame
M-4 aerial_perspective (raw, jittered) -> aerial_perspective_temporal -> accumulated volume/loss read by clouds_raymarch and composite; every frame
M-4 composite -> scene color buffer: aerial perspective on geometry + clouds; every frame
M-1 -> M-6: shader globals cloud_shadow_area (AO map center, size, AO strength), cloud_shadow_sun, beer_shadow_center/tangent/bitangent; every _render_callback
M-2 -> M-6: shader globals cloud_shadow_map (AO) and beer_shadow_map (sun shadow), Texture2DRDs of M-1's maps; on bind
M-9 -> M-7: VoxelGenerator.generate(coord) -> VoxelChunk on a worker thread (snapshot generator); per unauthored chunk after a rebuild; synchronously in set_voxel if not yet generated
Camera3D -> M-7: camera position (editor: EditorInterface viewport 0 camera; game: viewport camera); every _process, _refresh when its chunk changes
M-9 -> M-7: Resource.changed (also on noise change) -> full rebuild; deferred, coalesced
M-7 -> M-10: MarchingCubes.build_mesh(padded densities, padded types) -> ArrayMesh or null on a worker thread; per chunk once its 26 neighbours have data, on rebuild and after set_voxel

## INVARIANTS
INV-1: Planet radii and transmittance/sky-view/panorama uv mappings are duplicated in shaders/atmosphere.glslinc, shaders/cloud_panorama.glsl and sky.gdshader. Change all, or the sky mismatches the clouds.
INV-2: Params byte layout in VolumetricSkyEffect._update_params matches shaders/params.glslinc. A mismatch gives garbage camera/sun data.
INV-3: RDUniform bindings and texture sizes in M-1 match each shader's declarations and constants. A mismatch makes uniform set creation fail.
INV-4: The sun above the atmosphere is white with illuminance = light energy x PI, matching Godot's internal directional light scaling. The light's color carries the atmosphere transmittance, so anything reading LIGHT0_COLOR / LIGHT_COLOR must not apply transmittance again. The CPU transmittance in M-1 mirrors atmosphere.glslinc constants and haze scaling (INV-1).
INV-5: The AO map uv mapping is duplicated in shaders/cloud_shadow_map.glsl and cloud_shadow.gdshaderinc; the cloud top reaches materials via cloud_shadow_sun.w. All seven shader globals M-6 declares must stay registered in project.godot [shader_globals], or every material using M-6 fails to compile.
INV-6: The Beer shadow map frame (center, tangent, bitangent, extent; built in _beer_shadow_frame) is the only definition: beer_shadow_map.glsl writes with it; aerial_perspective.glsl (params) and cloud_shadow.gdshaderinc (globals) read with the same lookup. Depth is measured along -sun from the map plane.
INV-7: A chunk's mesh reads the padded grid chunk-local -1..SIZE+1 (SIZE+3 per axis): cells 0..SIZE-1 need the +1 corner, gradient normals need one more on each side. MarchingCubes.PADDED, padded_index, VoxelTerrain._remesh and set_voxel's dirty test must agree, or chunk borders crack or keep stale meshes.

## DECISIONS
D-1 2026-10-28: Hybrid rendering. A compute CompositorEffect draws on-screen atmosphere and clouds (depth-aware, fly-through); the sky shader only samples compute LUTs via Texture2DRD to supply the background and radiance cubemap.
D-2 2026-10-28: The planet is re-centered under the camera horizontally; world x/z only drives noise. Keeps every LUT in a fixed up=+y frame. Curvature is relative to the camera.
D-3 2026-10-28: Composite at PRE_TRANSPARENT so transparents draw over clouds; they get no aerial perspective.
D-4 2026-10-28: Earth atmosphere constants are hardcoded; transmittance and multi-scatter LUTs and noise are computed once at init. SUPERSEDED BY D-9
D-5 2026-10-28: Cloud shadows are material-based (a top-down map in shader globals plus an include supplying light()), not post-process darkening, so only direct sun is shadowed. Cost: opted-in materials use the include's Lambert+GGX instead of Godot's built-in lighting.
D-6 2026-10-28: Cloud AO goes into the material's AO output, relative to sky visibility above the camera (absolute when the camera is above the layer), because the radiance cubemap already includes the clouds overhead. It only darkens. SUPERSEDED BY D-15
D-7 2026-10-28: Crepuscular rays come from a sun-aligned Beer shadow map that shadows single scattering in the aerial perspective volume (64x64x32; grid size SUPERSEDED BY D-10). The sky background gets the removed light subtracted. Material shadows stay on the top-down map (D-5; SUPERSEDED BY D-13).
D-8 2026-10-28: DirectionalLight3D color = atmosphere transmittance at the camera, computed on the CPU (no GPU readback); the sun above the atmosphere is hardcoded white.
D-9 2026-10-28: Earth constants stay hardcoded except `haze` (Mie density scale, via params.atmosphere_settings.x). Transmittance and multi-scatter LUTs are recomputed only when haze changes; noise once at init. Shaft settings: strength (0 skips the Beer shadow map pass; SUPERSEDED BY D-13) and distance (Beer map extent).
D-10 2026-10-28: The aerial perspective volume and sky shadow loss are per viewport, sized from screen pixels (shaft_froxel_size_px) and shaft_depth_slices, and owned/freed by M-1 rather than RenderSceneBuffersRD (which only makes 2D textures here). Shaders read the slice count from textureSize.
D-11 2026-10-28: Froxels are jittered per frame (position inside the froxel + integration step offset) and accumulated by a reprojection pass, like Godot's volumetric fog; no neighborhood clamp. Texels represent froxel centers. shaft_temporal_amount = 0 turns both off.
D-12 2026-10-28: shaft_intensity scales only cloud-shadowed Mie single scattering inside the aerial perspective volume (artistic; extinction, Rayleigh sky color and ambient untouched). Sky pixels get the same boost through the sky correction texture (loss minus boost, can be negative).
D-13 2026-10-28: Material sun shadows use the Beer shadow map (correct inside/above the cloud layer), so it is always computed and shaft_distance_km also bounds material shadows. The top-down map keeps only cloud AO (single channel).
D-14 2026-10-28: Every tuning value (cloud layer, noise scales, phase/multi-scattering/ambient/albedo, quality, ground albedo, shadow map sizes) is a grouped export on M-1 packed into params; the sun disc brightness is a sky material uniform. Shadow maps resize live: replaced textures are freed RETIRE_DELAY_FRAMES later so M-2 can rebind. Procedural coverage/type comes from a 512^2 Perlin fBm texture (weather_gen.glsl) instead of a slice of the shape noise, removing straight cloud edges. Beer map cloudless texels store front = layer entry (not a far sentinel) so bilinear filtering stays smooth.
D-15 2026-10-28: Cloud AO is absolute (receiver's own sky visibility, scaled by cloud_ao_strength) because camera-relative AO (D-6) vanished whenever the camera flew under clouds. Accepts some double-darkening with the cubemap; tune with cloud_ao_strength.
D-16 2026-10-28: Performance (1080p viewport 2.7-3.0 -> 1.6-1.9 ms, RTX 3070): aerial perspective marches each froxel column once (O(slices)); clouds take 3x steps through empty space and back up on hit, skip detail beyond cloud_detail_lod_distance_km, halve light steps once transmittance < 0.3, reuse the sample's weather in the light march; shadow maps refresh every shadow_map_update_interval frames with their frame/center stored; the sky cubemap and cloud panorama refresh every sky_update_interval frames (sky shader uses no TIME/POSITION; VolumetricSky bumps refresh_index). AO map defaults to 256.
D-17 2026-10-28: Voxel content = generator output overridden per chunk by authored chunks (VoxelTerrain.authored_chunks, saved with the scene); set_voxel turns a chunk authored. Density > 0 is solid, one sample per world unit, 16^3 per chunk; types colour vertices (solid edge endpoint) via one vertex-colour material.
D-18 2026-10-28: Chunk generation and meshing run as WorkerThreadPool tasks (pool sized to the CPU by Godot), at most OS.get_processor_count() in flight so rebuilds drop queued work and deletion waits briefly. Workers get a generator duplicate and copy-on-write sample arrays, never live state; results are applied in _process. ArrayMesh is built on the worker; nodes are added on the main thread.
D-19 2026-10-28: chunk_extent is a range around the camera's chunk, not the origin. Leaving chunks lose mesh and (unless authored) data; queues are sorted nearest-first on every centre change; out-of-range tasks are cancelled by a flag polled between worker stages (no mid-loop abort, so M-9/M-10 stay untouched).
D-20 2026-10-28: VoxelTerrain toggles infinite (D-19 streaming) vs contained (world_size chunks from the node origin, no streaming) and procedural (off = unauthored chunks are air). Contained worlds keep no data outside; outside_faces reads air there and also meshes chunk -1 on the low sides (their last cells hold the closing faces); off clamps the gather to the boundary samples so the terrain is cut open. set_voxel outside a contained world is ignored.

## OPEN
2026-10-28: MSAA and XR/multiview are unsupported (only view 0, non-MSAA layers are read).
2026-10-28: Editing a shaders/*.glslinc does not trigger reimport of the .glsl files including it; reimport manually.
2026-10-28: Per-viewport froxel textures (D-10) are freed only on resize or effect deletion; closed editor viewports leak theirs until then.
2026-10-28: Between shadow map refreshes, Beer lookups use the current sun direction with the stored frame; a fast-moving sun shows up to shadow_map_update_interval frames of mismatch.
2026-10-28: Noise stretch constants (noise_gen.glsl 0.75/0.15, weather_gen.glsl 0.373/0.239/0.258) come from measured percentiles; re-measure if the noise functions change.