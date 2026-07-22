#+vet explicit-allocators
package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:slice"
import "core:time"
import la "core:math/linalg"

import "profiler"

import sdl "vendor:sdl3"
import vk  "../lib/vulkan"

////////////////////////////////////////////////

Optimized :: ODIN_OPTIMIZATION_MODE == .Speed

Validation      :: false when Optimized else true
Sync_Validation :: false && Validation

////////////////////////////////////////////////

Geometry :: struct {
    vertices:     [dynamic] Vertex,
    indices:      [dynamic] u32,
    meshlets:     [dynamic] Meshlet,
    meshlet_data: [dynamic] u32,
    
    meshes: [dynamic] Mesh,
}

Render_Targets_And_Stuff :: struct {
    color_buffer: Image,
    depth_buffer: Image,
    color_view: vk.ImageView,
    depth_view: vk.ImageView,
    
    depth_pyramid: Image,
    depth_pyramid_mips: [dynamic; 16] Depth_Mip,
}

Image :: struct {
    image:  vk.Image,
    memory: vk.DeviceMemory,
    
    format:    vk.Format,
    size:      uv3,
    mip_count: u32,
    
    sampled_index: Texture_Index,
    storage_index: Texture_Index,
}

// @todo cleanup Texture_Index
// @waste do we really need more then 65535 textures? how much memory would that many 1k (compressed) textures even require?
Texture_Index :: distinct u32
Sampler_Index :: distinct u32

Depth_Mip :: struct {
    size: uv2,
    sampled_index: Texture_Index,
    storage_index: Texture_Index,
}

Stage :: enum { early, late, post }
Pipelines :: struct {
    culling:      [Stage] Pipeline,
    depth_reduce: Pipeline,
    meshlets:     [Stage] Pipeline,
    ui:           Pipeline,
}

Shaders :: struct {
    meshlet_task: Shader_Id,
    meshlet_mesh: Shader_Id,
    meshlet_frag: Shader_Id,
    culling: Shader_Id,
    depth_reduce: Shader_Id,
    ui_vert: Shader_Id,
    ui_frag: Shader_Id,
}

Buffers :: struct {
    vertices:     Gpu_Slice(Vertex),
    indices:      Gpu_Slice(u32),
    meshlets:     Gpu_Slice(Meshlet),
    meshlet_data: Gpu_Slice(u32),
    meshes:       Gpu_Slice(Mesh),
    draws:        Gpu_Slice(Draw),
    
    draw_commands:      Gpu_Slice(Draw_Command),
    // @todo both need to be cleared to 1 on init. is allocated memory guarenteed to be zeroed? if so then we could make 0 the default by making them xx_occluded
    draw_visibility:    Gpu_Slice(u32),
    meshlet_visibility: Gpu_Slice(u32),
    
    bottom_level_acceleration_structures: vk.DeviceAddress,
    top_level_acceleration_structures:    vk.DeviceAddress,
}

Debug :: struct {
    vsync: bool,
    
    culling_enabled:   bool,
    lod_enabled:       bool,
    occlusion_enabled: bool,
    display_pyramid:   bool,
    display_pyramid_mip_level: i32,
    
    cpu_time:  f64,
    gpu_time:  f64,
    early_rendering_time: f64,
    late_rendering_time:  f64,
    early_cull_time: f64,
    late_cull_time:  f64,
}

Camera :: struct {
    p: v3,
    orientation: q32,
    fov_y: f32,
}

////////////////////////////////////////////////

// Maximum number of total task shader workgroups
TaskWidthLimit :: 1 << 22 // :Shader:

Cull_Data :: struct #all_or_none { // :Shader:
    // data
    view_from_world: m4,
    
    s00, s11, near_z, far_z: f32,
    frustum: [4] f32,
    
    pyramid_size: v2,
    draw_count:   u32,
    flags:        u32,
    
    lod_base: f32,
    lod_step: f32,
    
    _: u32,
    
    // bindings
    depth_pyramid_index: Texture_Index,
    
    draw_visibility_buffer: vk.DeviceAddress "bool",
    draw_buffer:            vk.DeviceAddress "Draw",
    mesh_buffer:            vk.DeviceAddress "Mesh",
    draw_group_count:       vk.DeviceAddress "uvec3",
    draw_command_buffer:    vk.DeviceAddress "Draw_Command",
}

// @volatile Cull_Data.flags
DebugFlag_FrustumCulling   :: (1 << 0)
DebugFlag_LevelOfDetail    :: (1 << 1)
DebugFlag_OcclusionCulling :: (1 << 2)

// @todo It would be way simpler if a bit wasteful to just always pass the shader all buffer addresses (buffers: Buffers).
Draw_Data :: struct #all_or_none { // :Shader:
    view_from_world:  m4, // @todo alignment requirements
    
    screen_size: v2,
    flags: u32,
    
    s00, s11:      f32,
    near_z, far_z: f32,
    pyramid_size:  v2,
    frustum:       [4] f32,
    
    // bindings
    frame_heap_offset:                      u32,
    depth_pyramid_index:                    Texture_Index,
    top_level_acceleration_structure_index: u32,
    
    draw_command_buffer:       vk.DeviceAddress "Draw_Command", // task
    meshlet_visibility_buffer: vk.DeviceAddress "uint",         // task
    draw_buffer:               vk.DeviceAddress "Draw",         // task, mesh, frag
    meshlet_buffer:            vk.DeviceAddress "Meshlet",      // task, mesh
    meshlet_data_buffer:       vk.DeviceAddress "uint",         // mesh
    vertex_buffer:             vk.DeviceAddress "Vertex",       // mesh
}

Depth_Data :: struct { // :Shader:
    size: v2,
    input_index:  Texture_Index,
    output_index: Texture_Index,
}

UI_Data :: struct #all_or_none { // :Shader:
    draw_buffer: vk.DeviceAddress "UI_Draw",
    screen_size: v2,
    mouse_p:     v2,
}

Draw :: struct { // :Shader:
    orientation: q32,
    p:           v3,
    scale:       f32,
    
    albedo_texture:   Texture_Index, // @todo make proper zero values for these: 1x1 white pixel
    normal_texture:   Texture_Index, // @todo make proper zero values for these: ??
    emmisive_texture: Texture_Index, // @todo make proper zero values for these: 1x1 black pixel
    
    mesh_index:    u32,
    post_pass:     b32,
    vertex_offset: u32,
    meshlet_visibility_offset: u32,
}

Mesh :: struct { // :Shader:
    center: v3,
    radius: f32,
    
    vertex_offset: u32,
    vertex_count:  u32,
    
    lod_count: u32,
    lods:      [8] Mesh_LOD,
}

Mesh_LOD :: struct { // :Shader:
    meshlet_offset: u32,
    meshlet_count:  u32,
    
    index_offset: u32,
    index_count:  u32,
}

Draw_Command :: struct { // :Shader:
    draw_index:  u32,
    meshlet_offset: u32,
    meshlet_count:  u32,
    mesh_was_visible_last_frame: b32,
    meshlet_visibility_offset:   u32,
}

Meshlet :: struct { // :Shader:
    center: v3,
    radius: f32,
    cone_axis:   [3] i8,
    cone_cutoff: i8,
    
    data_offset:    u32, // [data_offset:][:vertexcount]
    vertex_count:   u8,
    triangle_count: u8,
}

Vertex :: struct { // :Shader:
    p:  v3,
    n:  [3] u8,
    _:  u8,
    t:  [4] u8,
    uv: hv2,
}

UI_Draw_Command :: struct {
    vertex_count:   u32,
    instance_count: u32,
    first_vertex:   u32,
    first_instance: u32,
}

UI_Draw :: struct { // :Shader:
    rect:  Rectangle2,
    color: v4,
    
    border_color:     v4,
    border_thickness: f32,
    
    corner_radius: f32,
    highlight:     bool,
}

////////////////////////////////////////////////

raytracing_supported: bool

////////////////////////////////////////////////

main :: proc () {
    track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
    defer {
        for _, leak in track.allocation_map {
            print("%v leaked %m\n", leak.location, leak.size)
        }
        assert(true)
    }
    
    the_cpu_profiler = new(profiler.Event_Table, context.allocator)
    the_cpu_profile_zones := make([dynamic] profiler.Zone, context.allocator)
    profiler.set_recording(the_cpu_profiler, true)
    
    cpu_begin_profile_zone("Setup")
    
    cpu_begin_profile_zone("SDL Window Creation")
    if !sdl.InitSubSystem({ .VIDEO }) { print_sdl_error_and_exit() }
    defer sdl.Quit()
    defer sdl.QuitSubSystem({ .VIDEO })
    
    window := sdl.CreateWindow("Vulkan Renderer", 1280, 720, sdl.WINDOW_VULKAN | sdl.WINDOW_RESIZABLE)
    if window == nil { print_sdl_error_and_exit () }
    defer sdl.DestroyWindow(window)
    cpu_end_profile_zone()
    
    ////////////////////////////////////////////////
    
    debug := Debug {
        vsync = true,
        
        culling_enabled   = true,
        occlusion_enabled = true,
        
        // @todo lod generation and selection needs to be made better before it can be enabled without visible artefacts
        // lod_enabled       = true,
    }
    
    cpu_begin_profile_zone("OS Metrics sleep")
    profiler.init_os_metrics()
    cpu_end_profile_zone()
    
    gpu := &Gpu {}
    {
        props     := sdl.GetWindowProperties(window)
        hinstance := sdl.GetPointerProperty(props, sdl.PROP_WINDOW_WIN32_INSTANCE_POINTER, nil)
        gpu^ = gpu_init(hinstance, debug.vsync)
    }
    
    cpu_begin_profile_zone("Create Render Targets and Stuff")
    
    stuff: Render_Targets_And_Stuff
    stuff.depth_buffer.format = .D32_SFLOAT
    recreate_stuff(gpu, &stuff)
    
    cpu_end_profile_zone()
    
    ////////////////////////////////////////////////
    
    descriptor_heap := create_descriptor_heap(gpu)
    
    ////////////////////////////////////////////////
    
    cpu_begin_profile_zone("Allocate geometry buffers")
    
    vertex_and_index_usage := vk.BufferUsageFlags { .STORAGE_BUFFER }
    if raytracing_supported {
        vertex_and_index_usage += { .ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_KHR }
    }
    
    buffers: Buffers
    buffers.vertices     = gpu_allocate_slice(gpu, [] Vertex,  256 * Megabyte / size_of(Vertex),  memory = .Default, usage = vertex_and_index_usage)
    // This is only used to build the acceleration structures, if we want to do regular draws it will also need .INDEX_BUFFER in its usage.
    buffers.indices      = gpu_allocate_slice(gpu, [] u32,     256 * Megabyte / size_of(u32),     memory = .Default, usage = vertex_and_index_usage)
    buffers.meshlets     = gpu_allocate_slice(gpu, [] Meshlet, 256 * Megabyte / size_of(Meshlet), memory = .Default)
    buffers.meshlet_data = gpu_allocate_slice(gpu, [] u32,     256 * Megabyte / size_of(u32),     memory = .Default)
    buffers.meshes       = gpu_allocate_slice(gpu, [] Mesh,    256 * Megabyte / size_of(Mesh),    memory = .Default)
    
    // This is written by the cpu every frame in the worst case.
    buffers.draws = gpu_allocate(gpu, [] Draw, 256 * Megabyte / size_of(Draw), 16, Memory_Kind.Default)
    
    cpu_end_profile_zone()
    
    camera := Camera {
        p           = {0, 0, 0},
        orientation = 1,
        fov_y       = 70 * RadiansFromDegrees,
    }
    
    textures: [] Image
    defer delete(textures, context.allocator)
    
    // @todo make a separate allocator for all the scene and geometry setup that we free once before the frame loop
    max_draw_visibility_count: u32
    scene_draws: [dynamic] Draw
    
    bottom_levels: [] Acceleration_Structure
    top_level:     Acceleration_Structure
    {
        loading_scratch := context.temp_allocator
        defer free_all(loading_scratch)
        
        geometry: Geometry
        geometry.vertices.allocator     = loading_scratch
        geometry.indices.allocator      = loading_scratch
        geometry.meshlets.allocator     = loading_scratch
        geometry.meshlet_data.allocator = loading_scratch
        geometry.meshes.allocator       = loading_scratch
        
        {
            path := "niagara_bistro/bistro.gltf"
            texture_paths := make([dynamic] string, loading_scratch)
            print("\nLoading scene: %v\n", path)
            
            cpu_begin_profile_zone("load scene")
            if !load_scene(&geometry, path, &scene_draws, &camera, &texture_paths) {
                os.exit(1)
            }
            cpu_end_profile_zone()
            
            print("  Loaded scene %q: %v meshes, %v draws, %v textures\n", path, len(geometry.meshes), len(scene_draws), len(texture_paths))
            print("  Loading textures\n")
            
            make_by_pointer(&textures, len(texture_paths), context.allocator)
            
            //
            // @speed moving the copies to a queue will speedup the loading from ssd(~22%). It may or may not help
            // with the drivers copy(~71%), depending on its ability to be parallelized. 
            /// 0.957 / 1.34
            /// 0.3 / 1.34
            //
            // Read speed testing estimates a max speed of 6.5 Gb/s with a preallocated and mapped buffer.
            // Here we currently load ~2.1 Gb.
            /// 2.1 / 6.5
            // Just loading the textures should take ~0.3s itself: which it does!
            // The whole texture upload takes roughly 0.8-1.5s, so ~0.5-1.2s itself, which is mainly
            // the copy into the texture by the cpu. A straight memcopy would be faster by the driver
            // may need to swizzle the data based on the formats.
            /// 2.1 / 0.957
            /// 2.1 / 0.493
            // Therefore we only reach speeds of ~2.2 Gb/s (a memcopy of the same data ~4.3Gb/s)
            // So the driver's copy is roughly half as fast as a memcopy.
            //
            // (We could memcopy the drivers swizzled data back into our memory and cache the result.)
            // (This cached data would then be loaded instead and could be memcopied.)
            //
            total_size: int
            {
                cpu_profile_scope("upload textures")
                
                texture_descs      := make([] Texture_Desc, len(texture_paths), loading_scratch)
                texture_pixel_size := make([] int,          len(texture_paths), loading_scratch)
                texture_file       := make([] ^os.File,     len(texture_paths), loading_scratch)
                
                max_size : int
                for texture_path, index in texture_paths {
                    file, open_error := os.open(texture_path); assert(open_error == nil)
                    texture_descs[index], texture_pixel_size[index] = parse_dds_texture_header(file)
                    texture_file[index] = file
                    
                    pixel_size := texture_pixel_size[index]
                    max_size = max(max_size, pixel_size)
                    total_size += pixel_size
                }
                
                copy_buffer := make([] u8, max_size, loading_scratch)
                for index in 0..<len(texture_paths) {
                    pixel_size := texture_pixel_size[index]
                    file       := texture_file[index]
                    buffer := copy_buffer[:pixel_size]
                    read, read_error := os.read_full(file, buffer); assert(read_error == nil); assert(read == pixel_size)
                    os.close(file)
                    
                    texture := gpu_allocate_texture(gpu, texture_descs[index])
                    gpu_copy_to_texture_immediately(gpu, texture, buffer)
                    
                    textures[index] = texture
                }
            }
            
            print("  Loaded textures: %vb\n\n", view_magnitude(total_size))
        }
        
        cpu_begin_profile_zone("upload geometry")
        copy(buffers.vertices.cpu,     geometry.vertices[:])
        copy(buffers.indices.cpu,      geometry.indices[:])
        copy(buffers.meshlets.cpu,     geometry.meshlets[:])
        copy(buffers.meshlet_data.cpu, geometry.meshlet_data[:])
        copy(buffers.meshes.cpu,       geometry.meshes[:])
        cpu_end_profile_zone()
        
        meshlet_visibility_count: u32
        for &draw in scene_draws {
            mesh := geometry.meshes[draw.mesh_index]
            // @speed just ensure that the base lod has the most meshlets
            meshlet_count: u32
            for lod in mesh.lods[:mesh.lod_count] {
                meshlet_count = max(meshlet_count, lod.meshlet_count)
            }
            
            draw.meshlet_visibility_offset = meshlet_visibility_count
            meshlet_visibility_count      += meshlet_count
        }
        max_draw_visibility_count = meshlet_visibility_count
        
        if raytracing_supported {
            
            // @todo which pool?
            queue := gpu.transfer_queue
            pool  := gpu.transfer_command_pool
            
            bottom_levels = build_bottom_level_acceleration_structures(gpu, queue, pool, &buffers, geometry, context.allocator, loading_scratch)
            top_level = build_top_level_acceleration_structures(gpu, queue, pool, &buffers, scene_draws[:], bottom_levels, loading_scratch)
        }
    }
    
    
    cpu_begin_profile_zone("Allocate render buffers")
    
    buffers.draw_commands      = gpu_allocate_slice(gpu, [] Draw_Command, TaskWidthLimit,                        memory = .GPU) 
    buffers.draw_visibility    = gpu_allocate_slice(gpu, [] u32,          256 * Megabyte / size_of(u32),         memory = .GPU, usage = { .STORAGE_BUFFER, .TRANSFER_DST })
    buffers.meshlet_visibility = gpu_allocate_slice(gpu, [] u32,          (max_draw_visibility_count + 31) / 32, memory = .GPU, usage = { .STORAGE_BUFFER, .TRANSFER_DST })
    dvb_and_mvb_cleared := false
    
    cpu_end_profile_zone()
    
    ////////////////////////////////////////////////
    
    cpu_begin_profile_zone("Init shaders")
    watchers := make([dynamic] Watcher, context.allocator)
    
    init_assets(context.allocator)
    
    generate_shader_api("shaders/api.generated.glsl")
    
    // @speed we duplicate this watcher per shader, so that each shader can keep track of the header being changed and be recompiled independently from other shaders, without effecting their modification test.
    shaders := Shaders {
        meshlet_task = init_shader_and_watchers(&watchers, watchers_make(&watchers, "shaders/common.glsl"), "shaders/meshlet.task"),
        meshlet_mesh = init_shader_and_watchers(&watchers, watchers_make(&watchers, "shaders/common.glsl"), "shaders/meshlet.mesh"),
        meshlet_frag = init_shader_and_watchers(&watchers, watchers_make(&watchers, "shaders/common.glsl"), "shaders/meshlet.frag"),
        culling      = init_shader_and_watchers(&watchers, watchers_make(&watchers, "shaders/common.glsl"), "shaders/cull.comp"),
        depth_reduce = init_shader_and_watchers(&watchers, watchers_make(&watchers, "shaders/common.glsl"), "shaders/depth_reduce.comp"),
        
        ui_vert = init_shader_and_watchers(&watchers, watchers_make(&watchers, "shaders/common.glsl"), "shaders/ui.vert"),
        ui_frag = init_shader_and_watchers(&watchers, watchers_make(&watchers, "shaders/common.glsl"), "shaders/ui.frag"),
    }
    
    cpu_end_profile_zone()
    
    ////////////////////////////////////////////////
    
    cpu_begin_profile_zone("Setup other gpu resources")
    
    gpu_profile_init(gpu)
    
    stats_count : u32 : 3
    stats_pools: [MaxFramesInFlight] vk.QueryPool
    for &it in stats_pools {
        it = create_query_pool(gpu, stats_count, .MESH_PRIMITIVES_GENERATED_EXT)
    }
    
    absolute_frame_index: u64
    next_frame := cast(u64) MaxFramesInFlight+1
    frame_semaphore := gpu_create_timeline_semaphore(gpu, MaxFramesInFlight)
    
    pipelines: Pipelines
    
    cpu_end_profile_zone()
    
    cpu_begin_profile_zone("Allocate GPU Bumps")
    frame_bump_allocators: [MaxFramesInFlight] Bump_Allocator
    for &bump in frame_bump_allocators {
        bump = bump_allocator_make_temporary(gpu, 256 * Megabyte, usage = { .STORAGE_BUFFER, .TRANSFER_DST, .INDIRECT_BUFFER })
    }
    
    cpu_end_profile_zone()
    
    ////////////////////////////////////////////////
    
    quit: bool
    last_time := time.tick_now()
    
    cpu_end_profile_zone()
    
    mouse_p: v2
    for !quit {
        free_all(context.temp_allocator)
        
        events := profiler.swap_active_array_and_get_events(the_cpu_profiler)
        profiler.collate_events(events, &the_cpu_profile_zones, nil)
        
        cpu_begin_profile_zone("Frame")
        
        ////////////////////////////////////////////////
        
        // @speed similarly the timestamps should only be collected if we need them. As we currently only look at the last rendered frame, we should only take them if we then also print them. In the future we may want to store more than one frame, but for now this would be better.
        print_profile_and_stats: bool
        if absolute_frame_index == 0 { print_profile_and_stats = true }
        
        mouse_delta: v2
        mouse_wheel_delta: f32
        @(static) left_down:  bool
        
        cpu_begin_profile_zone("Input Events")
        
        vsync_changed: bool
        window_event_begin := time.tick_now()
        for event: sdl.Event; sdl.PollEvent(&event); {
            #partial switch event.type {
            case .QUIT:
                quit = true
            
            case .MOUSE_MOTION:
                mouse_p     = { event.motion.x, cast(f32) gpu.swapchain_size.y - event.motion.y }
                mouse_delta = { event.motion.xrel, event.motion.yrel }
                
            case .MOUSE_BUTTON_DOWN:
                if event.button.button == sdl.BUTTON_LEFT {
                    left_down = true
                }
            case .MOUSE_BUTTON_UP:
                if event.button.button == sdl.BUTTON_LEFT {
                    left_down = false
                }
            case .KEY_DOWN:
                switch event.key.key {
                case sdl.K_C:     debug.culling_enabled   = !debug.culling_enabled
                case sdl.K_L:     debug.lod_enabled       = !debug.lod_enabled
                case sdl.K_O:     debug.occlusion_enabled = !debug.occlusion_enabled
                case sdl.K_P:     debug.display_pyramid   = !debug.display_pyramid
                
                case sdl.K_V:     debug.vsync = !debug.vsync; vsync_changed = true
                
                case sdl.K_I:     print_profile_and_stats = true
                
                case sdl.K_PLUS:  debug.display_pyramid_mip_level = clamp(debug.display_pyramid_mip_level+1, 0, cast(i32) len(stuff.depth_pyramid_mips)-1)
                case sdl.K_MINUS: debug.display_pyramid_mip_level = clamp(debug.display_pyramid_mip_level-1, 0, cast(i32) len(stuff.depth_pyramid_mips)-1)
                
                case sdl.K_ESCAPE: quit = true
                }
                
            case .MOUSE_WHEEL:
                mouse_wheel_delta = event.wheel.y
            }
        }
        
        cpu_end_profile_zone()
        
        window_event_delta := time.tick_since(window_event_begin)
        
        ////////////////////////////////////////////////
        
        current_time  := time.tick_now()
        delta_tick    := time.tick_diff(last_time, current_time)
        // Though we do not track the time, *we* take to handle the input, we also exclude all time taken by sdl and windows(which may block)
        delta_tick    -= window_event_delta
        
        cpu_delta := time.duration_seconds(delta_tick)
        delta_time := cast(f32) cpu_delta
        last_time = current_time
        
        if mouse_wheel_delta != 0 {
            camera.p.z += mouse_wheel_delta * -10 * delta_time
        }
        
        if mouse_delta != 0 && left_down {
            camera.p.xy += mouse_delta * {-1, 1} * delta_time * 5
        }
        
        ////////////////////////////////////////////////
        
        cpu_begin_profile_zone("Frame Sleep")
        gpu_wait_semaphore(gpu, frame_semaphore, next_frame - MaxFramesInFlight)
        cpu_end_profile_zone()
        
        frame_index := absolute_frame_index % MaxFramesInFlight
        absolute_frame_index += 1
        if absolute_frame_index >= MaxFramesInFlight+1 {
            cpu_profile_scope("GPU profiling")
            
            triangle_count: u64
            if absolute_frame_index >= MaxFramesInFlight {
                cpu_profile_scope("collect and print shader stats")
                
                last_finished_stats_pool := stats_pools[frame_index]
                
                stats_result: [128] u64
                size := cast(int) size_of_slice(stats_result[:])
                
                check(vk.GetQueryPoolResults(gpu.device, last_finished_stats_pool, 0, 1, size, &stats_result[0], size_of(stats_result[0]), { ._64 }))
                
                for i in 0..<stats_count {
                    triangle_count += stats_result[i]
                }
            }
            
            gpu_profile_collate_times(gpu, print_profile_and_stats, frame_index)
            
            gpu_delta             := gpu_profile_get_zone_duration(gpu, frame_index, "Frame")
            early_rendering_delta := gpu_profile_get_zone_duration(gpu, frame_index, "early rendering pass")
            late_rendering_delta  := gpu_profile_get_zone_duration(gpu, frame_index, "late rendering pass")
            early_cull_delta      := gpu_profile_get_zone_duration(gpu, frame_index, "early culling")
            late_cull_delta       := gpu_profile_get_zone_duration(gpu, frame_index, "late culling")
            
            blend_factor_k := time_smoothed_blend_factor(7, cpu_delta)
            
            debug.cpu_time             = linear_blend(cpu_delta,             debug.cpu_time,             blend_factor_k)
            debug.early_cull_time      = linear_blend(early_cull_delta,      debug.early_cull_time,      blend_factor_k)
            debug.late_cull_time       = linear_blend(late_cull_delta,       debug.late_cull_time,       blend_factor_k)
            debug.early_rendering_time = linear_blend(early_rendering_delta, debug.early_rendering_time, blend_factor_k)
            debug.late_rendering_time  = linear_blend(late_rendering_delta,  debug.late_rendering_time,  blend_factor_k)
            // this might have happened when a validation error occurred, causing the smooth value to be messed for a very long time
            if gpu_delta >= 0 {
                debug.gpu_time = linear_blend(gpu_delta, debug.gpu_time, blend_factor_k)
            }
            
            view :: proc (seconds: f64) -> time.Duration {
                return time.duration_round(cast(time.Duration) (seconds * cast(f64) time.Second), 1 * time.Microsecond)
            }
            
            cpu_begin_profile_zone("Update window title")
            sb := strings.builder_make(context.temp_allocator)
            fmt.sbprintf(&sb, "%v tri, cpu: %.3v, gpu: %.3v (early cull %.3v, early render %.3v, late cull %.3v, late render %.3v)", 
                view_magnitude(triangle_count, kind = .Count),
                view(debug.cpu_time), view(debug.gpu_time), 
                view(debug.early_cull_time), view(debug.early_rendering_time), view(debug.late_cull_time), view(debug.late_rendering_time),
            )
            fmt.sbprintf(&sb, ", Features: ")
            if debug.vsync {
                fmt.sbprintf(&sb, "VSync ")
            }
            if debug.culling_enabled {
                fmt.sbprintf(&sb, "Culling ")
            }
            if debug.lod_enabled {
                fmt.sbprintf(&sb, "LOD ")
            }
            if debug.occlusion_enabled {
                fmt.sbprintf(&sb, "Occlusion ")
            }
            extra: string
            if debug.display_pyramid {
                extra = fmt.sbprintf(&sb, ", displaying depth mip level %v", debug.display_pyramid_mip_level)
            }
            
            title := strings.to_cstring(&sb)
            sdl.SetWindowTitle(window, title)
           
            cpu_end_profile_zone()
        }
        
        if gpu_recreate_swapchain_if_needed(gpu, debug.vsync, vsync_changed) {
            ok := get_next_image(gpu, frame_semaphore, frame_index)
            assert(ok)
        }
        
        if gpu.swapchain_state == .Was_Resized {
            gpu.swapchain_state = .Ok
            recreate_stuff(gpu, &stuff)
        }
        
        assert(gpu.swapchain_state != .Dirty)
        
        if gpu.swapchain_state == .Window_Is_Minimized { continue }
        
        bump := &frame_bump_allocators[frame_index]
        bump_free_all(bump)
        
        ////////////////////////////////////////////////
        
        watchers_check_for_modification(watchers)
        recompile_shaders_if_needed(watchers, shaders.culling)
        recompile_shaders_if_needed(watchers, shaders.meshlet_task, shaders.meshlet_mesh, shaders.meshlet_frag)
        recompile_shaders_if_needed(watchers, shaders.depth_reduce)
        recompile_shaders_if_needed(watchers, shaders.ui_vert, shaders.ui_frag)
        
        // @todo the work of loading the bytes and parsing them could be moved to a thread. The modified flag then needs to be expanded into a state { Invalid, Loading, Valid }
        load_all_compiled_shaders(immediately = false)
        
        reloaded_cull_shader := test_and_reset_shaders_was_modified(shaders.culling)
        for &cull_pipeline, stage in pipelines.culling {
            if !pipeline_is_valid(cull_pipeline) || reloaded_cull_shader {
                destroy_pipeline(gpu, cull_pipeline)
                immediately := !pipeline_is_valid(cull_pipeline)
                
                compute := get_shader(shaders.culling, immediately)
                constants := [] Specialization_Constant { /* late = */ { b = stage != .early }, /* post = */ { b = stage == .post } }
                
                cull_pipeline = gpu_create_compute_pipeline(gpu, compute, descriptor_heap, constants)
                
                print("Recreated %v cull_pipeline.\n", stage)
            }
        }
        
        if !pipeline_is_valid(pipelines.depth_reduce) || test_and_reset_shaders_was_modified(shaders.depth_reduce) {
            destroy_pipeline(gpu, pipelines.depth_reduce)
            immediately := !pipeline_is_valid(pipelines.depth_reduce)
            
            compute := get_shader(shaders.depth_reduce, immediately)
            pipelines.depth_reduce = gpu_create_compute_pipeline(gpu, compute, descriptor_heap)
            
            print("Recreated depth_pipeline.\n")
        }
        
        reloaded_meshlet_shaders := test_and_reset_shaders_was_modified(shaders.meshlet_task, shaders.meshlet_mesh, shaders.meshlet_frag)
        for &meshlet_pipeline, stage in pipelines.meshlets {
            if !pipeline_is_valid(meshlet_pipeline) || reloaded_meshlet_shaders {
                destroy_pipeline(gpu, meshlet_pipeline)
                immediately := !pipeline_is_valid(meshlet_pipeline)
                
                raster_description: Raster_Desc
                raster_description.depth_format = stuff.depth_buffer.format
                raster_description.color_target_formats = { stuff.color_buffer.format }
                raster_description.blendstate = &Blend_Desc{ **DefaultBlendDesc }
                // :Stencil: 
                
                task, mesh, frag := get_shader(shaders.meshlet_task, immediately), get_shader(shaders.meshlet_mesh, immediately), get_shader(shaders.meshlet_frag, immediately)
                constants := [] Specialization_Constant { /* late = */ { b = stage != .early }, /* post = */ { b = stage == .post } }
                
                meshlet_pipeline = gpu_create_graphics_meshlet_pipeline(gpu, task, mesh, frag, raster_description, descriptor_heap, constants)
                
                print("Recreated %v meshlet_pipeline.\n", stage)
            }
        }    
        
        if !pipeline_is_valid(pipelines.ui) || test_and_reset_shaders_was_modified(shaders.ui_vert, shaders.ui_frag) {
            destroy_pipeline(gpu, pipelines.ui)
            immediately := !pipeline_is_valid(pipelines.ui)
            
            raster_description: Raster_Desc
            raster_description.color_target_formats = { stuff.color_buffer.format }
            raster_description.blendstate = &Blend_Desc { **DefaultBlendDesc }
            raster_description.blendstate.src_color_factor = .SRC_ALPHA
            raster_description.blendstate.dst_color_factor = .ONE_MINUS_SRC_ALPHA
            raster_description.blendstate.src_alpha_factor = .ONE
            raster_description.blendstate.dst_alpha_factor = .ONE_MINUS_SRC_ALPHA
            
            vert, frag := get_shader(shaders.ui_vert, immediately), get_shader(shaders.ui_frag, immediately)
            pipelines.ui = gpu_create_graphics_pipeline(gpu, vert, frag, raster_description, descriptor_heap)
            
            print("Recreated ui_pipeline.\n")
        }
        
        ////////////////////////////////////////////////
        // @waste texture management and draw "generation" only really need to happen once per "level load" as there is no streaming in of data.
        
        // @todo Index type
        frame_heap_offset: u32 // @todo can we just offset the heap's address when we bind it?
        top_level_acceleration_structure_index: u32
        {
            cpu_profile_scope("Setup Descriptor Heap")
            
            write_texture :: proc (gpu: ^Gpu, heap: ^Descriptor_Heap, index_offset: ^Texture_Index, image: Image, sampled: bool, mip_base: u32 = 0, mip_count: u32 = vk.REMAINING_MIP_LEVELS) -> Texture_Index {
                result := index_offset^
                index_offset^ += 1
                write_texture_to_heap(gpu, heap, result, image, sampled ? .SAMPLED_IMAGE : .STORAGE_IMAGE, mip_base, mip_count)
                return result
            }
            
            descriptor_offset := cast(Texture_Index) (frame_index * DescriptorPerFrameLimit)
            
            // @todo add a null texture, which is a bright debug color so that uninitialized indices(0) are easy to find
            // nil_index := append_texture(gpu, &descriptor_heap, &descriptor_offset, nil_texture, true)
            descriptor_offset += 1
            
            // @todo make the null texture not part of the per frame offset, its very texture specific
            frame_heap_offset = cast(u32) descriptor_offset
            
            
            // @todo when would we not want to get the sample/storage descriptors of a texture we uploaded? should this not
            // just be part of the upload code?
            
            // @volatile draws assume that their texture indices start at index 0. Add some kind of base offset that the shader add to a draws
            // texture index(if its not 0?) to get its texture, or do this offsetting on draw generation on the cpu.
            for &texture in textures {
                texture.sampled_index = write_texture(gpu, &descriptor_heap, &descriptor_offset, texture, true)
            }
            
            stuff.depth_buffer.sampled_index  = write_texture(gpu, &descriptor_heap, &descriptor_offset, stuff.depth_buffer,  true)
            stuff.depth_pyramid.sampled_index = write_texture(gpu, &descriptor_heap, &descriptor_offset, stuff.depth_pyramid, true)
            stuff.depth_pyramid.storage_index = write_texture(gpu, &descriptor_heap, &descriptor_offset, stuff.depth_pyramid, false)
            
            for &mip, mip_level in stuff.depth_pyramid_mips {
                mip.sampled_index = write_texture(gpu, &descriptor_heap, &descriptor_offset, stuff.depth_pyramid, true,  cast(u32) mip_level, 1)
                mip.storage_index = write_texture(gpu, &descriptor_heap, &descriptor_offset, stuff.depth_pyramid, false, cast(u32) mip_level, 1)
            }
            
            write_acceleration_structure_to_heap(gpu, &descriptor_heap, cast(u32) descriptor_offset, top_level)
            top_level_acceleration_structure_index = cast(u32) descriptor_offset
            descriptor_offset += 1
            
            // @todo add a barrier after modifying the heap to ensure descriptor caches are flushed
        }
        
        draw_count : u32
        {
            //
            // @hack @race_condition the draw commands should obviously not be written to by the cpu, whilst the gpu is still 
            // processing the previous draw commands. We need atleast MaxFramesInFlight different draw_buffers to prevent this 
            // race condition, if the draws themselves change every frame, which is likely if the objects themselves are dynamic.
            //
            copy(buffers.draws.cpu, scene_draws[:])
            draw_count = cast(u32) len(scene_draws)
        }
        
        ////////////////////////////////////////////////
        
        //
        // :ViewSpace:
        // The default vulkan view space is right-handed with x+ being right, y+ down and the camera looking down z-. The depth buffer maps 
        // the near z clipping plane to 0 and the far plane to 1. This loses floating point precision for far away object and can increase
        // z-fighting.
        // We instead want the coordinate frame to be y+ as up and also want to reverse the depth mapping (reversed-z) to place the most 
        // amount of precision at the far plane. It is then also simple to move the far plane of the projection matrix towards infinity.
        // In the limit this produces the matrix given by projection_reversed_z_infinite_far_plane.
        // 
        
        near_z: f32 = 0.01
        // @todo this is in view/camera space make this a distance in world space
        draw_distance: f32 = 1000
        
        oriented := cast(m4) la.matrix3_from_quaternion(camera.orientation)
        view_from_world  := la.inverse(translate(oriented, camera.p))
        screen_from_view := projection_reversed_z_infinite_far_plane(camera.fov_y, cast(f32) gpu.swapchain_size.x / cast(f32) gpu.swapchain_size.y, near_z)
        
        ////////////////////////////////////////////////
        ////////////////////////////////////////////////
        ////////////////////////////////////////////////
        
        cpu_begin_profile_zone("Record command buffer")
        
        cpu_begin_profile_zone("reset command pool")
        check(vk.ResetCommandPool(gpu.device, gpu.command_pools[frame_index], {}))
        cpu_end_profile_zone()
        
        cmd := gpu_begin_command_recording(gpu, gpu.command_pools[frame_index])
        
        gpu_profile_frame_begin(gpu, cmd, frame_index)
        
        gpu_profile_zone_begin("frame init")
        
        gpu_set_active_heap(cmd, &descriptor_heap)
        
        stats_pool_query_index: u32
        stats_pool := stats_pools[frame_index]
        vk.CmdResetQueryPool(cmd, stats_pool, 0, stats_count)
        
        ////////////////////////////////////////////////
        
        gpu_image_barriers(cmd, { .BY_REGION },
            create_image_barrier_from_undefined(&stuff.color_buffer,                    { .COLOR_ATTACHMENT_OUTPUT, .EARLY_FRAGMENT_TESTS }, { .COLOR_ATTACHMENT_WRITE                       }),
            create_image_barrier_from_undefined(&stuff.depth_buffer,                    { .COLOR_ATTACHMENT_OUTPUT, .EARLY_FRAGMENT_TESTS }, { .DEPTH_STENCIL_ATTACHMENT_WRITE, .MEMORY_READ }), 
            create_image_barrier_from_undefined(&stuff.depth_pyramid,                   { .COMPUTE_SHADER                                 }, { .MEMORY_READ, .MEMORY_WRITE                   }),
            create_image_barrier_from_undefined(&gpu.swapchain_images[gpu.image_index], { .ALL_TRANSFER                                   }, { .TRANSFER_WRITE                               }),
        )
        
        gpu_profile_zone_end()
        
        ////////////////////////////////////////////////
        
        cull_and_render(gpu, cmd, .early, pipelines, shaders, buffers, bump, stats_pool, stats_pool_query_index, &stuff, draw_count, &dvb_and_mvb_cleared, view_from_world, screen_from_view, near_z, draw_distance, debug, frame_heap_offset, top_level_acceleration_structure_index)
        stats_pool_query_index += 1
        
        ////////////////////////////////////////////////
        // depth pyramid generation
        
        {
            cpu_profile_scope("record depth pyramid")
            
            gpu_profile_zone_begin("depth pyramid building")
            gpu_labeled_region_begin(cmd, "depth pyramid building", {0.4, 0.8, 0, 1.0})
            
            gpu_barrier(cmd, { .LATE_FRAGMENT_TESTS }, { .COMPUTE_SHADER })
            
            gpu_set_pipeline(cmd, pipelines.depth_reduce)
            
            for mip, mip_level in stuff.depth_pyramid_mips {
                depth_data := bump_allocate(bump, Depth_Data)
                depth_data.cpu^ = Depth_Data { 
                    size = cast(v2) mip.size,
                }
                if mip_level == 0 {
                    depth_data.cpu.input_index  = stuff.depth_buffer.sampled_index
                    depth_data.cpu.output_index = stuff.depth_pyramid.storage_index
                } else if mip_level == 1 {
                    depth_data.cpu.input_index  = stuff.depth_pyramid.sampled_index
                    depth_data.cpu.output_index = mip.storage_index
                } else {
                    depth_data.cpu.input_index  = stuff.depth_pyramid_mips[mip_level-1].sampled_index
                    depth_data.cpu.output_index = mip.storage_index
                }
                
                gpu_dispatch(cmd, depth_data.gpu, grid_dimension_from_total_count(shaders.depth_reduce, **mip.size))
                
                gpu_barrier(cmd, { .COMPUTE_SHADER }, { .COMPUTE_SHADER })
            }
            
            gpu_barrier(cmd, { .COMPUTE_SHADER }, { .EARLY_FRAGMENT_TESTS })
            
            gpu_labeled_region_end(cmd)
            gpu_profile_zone_end()
        }
        
        ////////////////////////////////////////////////
        
        cull_and_render(gpu, cmd, .late, pipelines, shaders, buffers, bump, stats_pool, stats_pool_query_index, &stuff, draw_count, &dvb_and_mvb_cleared, view_from_world, screen_from_view, near_z, draw_distance, debug, frame_heap_offset, top_level_acceleration_structure_index)
        stats_pool_query_index += 1
        
        cull_and_render(gpu, cmd, .post, pipelines, shaders, buffers, bump, stats_pool, stats_pool_query_index, &stuff, draw_count, &dvb_and_mvb_cleared, view_from_world, screen_from_view, near_z, draw_distance, debug, frame_heap_offset, top_level_acceleration_structure_index)
        stats_pool_query_index += 1
        
        ////////////////////////////////////////////////
        // UI pass
        
        if false {
            @(static) xx: f32 // @cleanup
            xx += delta_time
            
            @(static) active_rect: Rectangle2
            hot_rect: Rectangle2
            
            color_a := color4_from_u8(Color { 0x18, 0x18, 0x18, 0xFF })
            rect_a  := rect_min_dimension(cast(f32) 100, 100, 400, 160)
            color_b := Green
            rect_b  := rect_min_dimension(cast(f32) 200+400, 100, 400, 160)
            
            if !left_down { active_rect = {} }
            
            if rect_contains(rect_a, mouse_p) { hot_rect = rect_a }
            if rect_contains(rect_b, mouse_p) { hot_rect = rect_b }
            
            if left_down && active_rect == {} {
                active_rect = hot_rect != {} ? hot_rect : {-1, -1} // invalid rect
            }
            
            ui_draws := bump_allocate(bump, [] UI_Draw, 2)
            ui_draws.cpu[0] = { 
                rect  = rect_a, 
                color = color_a, 
                highlight = active_rect != {} ? rect_a == active_rect : rect_a == hot_rect, 
                corner_radius = 10,
                
                border_color     = rect_a == active_rect || rect_a == hot_rect ? Blue : Jasmine,
                border_thickness = 4,
            }
            ui_draws.cpu[1] = { 
                rect  = rect_b, 
                color = color_b, 
                highlight = active_rect != {} ? rect_b == active_rect : rect_b == hot_rect, 
                corner_radius = 20,
                
                border_color = Orange,
                border_thickness = 5 + sin(xx)*5,
            }
            
            ////////////////////////////////////////////////
            
            ui_data := bump_allocate(bump, UI_Data)
            ui_data.cpu^ = {
                draw_buffer = ui_draws.gpu.p,
                screen_size = cast(v2) gpu.swapchain_size,
                mouse_p = mouse_p,
            }
            
            ui_draw_command := bump_allocate(bump, UI_Draw_Command)
            ui_draw_command.cpu^ = { 6, cast(u32) len(ui_draws.cpu), 0 ,0 }
            
            gpu_barrier(cmd, 
                { .COLOR_ATTACHMENT_OUTPUT, .LATE_FRAGMENT_TESTS, .DRAW_INDIRECT, .PRE_RASTERIZATION_SHADERS }, 
                { .COLOR_ATTACHMENT_OUTPUT, .EARLY_FRAGMENT_TESTS, .PRE_RASTERIZATION_SHADERS },
            )
            
            // @todo decide if the users passes a z with which to do depth testing
            desc := Render_Pass_Desc {
                color_targets = { { texture = stuff.color_buffer, view = stuff.color_view, load_op = .LOAD, store_op = .STORE } },
            }
            gpu_begin_rendering(gpu, cmd, desc)
                
                gpu_set_viewport(cmd, size = cast(v2) gpu.swapchain_size)
                gpu_set_scissor(cmd,  size = gpu.swapchain_size)
                
                gpu_set_pipeline(cmd, pipelines.ui)
                gpu_draw_indirect(cmd, ui_draw_command.gpu, ui_data.gpu)
                
            gpu_end_rendering(cmd)
        }
        
        
        ////////////////////////////////////////////////
        
        {
            cpu_profile_scope("record copy to swapchain")
            
            gpu_profile_zone_begin("copy to swapchain")
                
                source_image    := &stuff.color_buffer
                swapchain_image := &gpu.swapchain_images[gpu.image_index]
                
                if debug.display_pyramid {
                    source_image = &stuff.depth_pyramid
                }
                
                gpu_barrier(cmd, { .COLOR_ATTACHMENT_OUTPUT, .LATE_FRAGMENT_TESTS, .DRAW_INDIRECT, .PRE_RASTERIZATION_SHADERS }, { .ALL_TRANSFER })
                
                if !debug.display_pyramid {
                    vk.CmdCopyImage(cmd, source_image.image, .GENERAL, swapchain_image.image, .GENERAL, 1, &vk.ImageCopy {
                        srcSubresource = { aspectMask = { .COLOR }, layerCount = 1 },
                        dstSubresource = { aspectMask = { .COLOR }, layerCount = 1 },
                        extent         = { **swapchain_image.size },
                    })
                } else {
                    mip_size  := cast(iv2) stuff.depth_pyramid_mips[debug.display_pyramid_mip_level].size
                    vk.CmdBlitImage(cmd, source_image.image, .GENERAL, swapchain_image.image, .GENERAL, 1, &vk.ImageBlit {
                        srcSubresource = { aspectMask = { .COLOR }, layerCount = 1, mipLevel = cast(u32) debug.display_pyramid_mip_level },
                        dstSubresource = { aspectMask = { .COLOR }, layerCount = 1 },
                        srcOffsets = { {0, 0, 0}, { mip_size.x, mip_size.y, 1 }},
                        dstOffsets = { {0, 0, 0}, { **(cast(iv3) swapchain_image.size) }},
                    }, .NEAREST)
                }
                
                gpu_image_barriers(cmd, { .BY_REGION }, create_image_barrier(swapchain_image, { .ALL_TRANSFER }, { .TRANSFER_WRITE }, .GENERAL, {}, {}, .PRESENT_SRC_KHR))
                
            gpu_profile_zone_end()
        }
        
        ////////////////////////////////////////////////
        
        gpu_profile_frame_end()
        cpu_end_profile_zone()
        
        cpu_begin_profile_zone("submit and present queue")
        gpu_submit(gpu.general_queue, {
            { gpu.image_aquired_semaphores[frame_index], { .TRANSFER },     nil },
            
            { gpu.render_completes[gpu.image_index],     { .ALL_COMMANDS }, 0 },
            { frame_semaphore,                           { .ALL_COMMANDS }, next_frame },
        }, cmd)
        gpu_present(gpu, gpu.general_queue, gpu.render_completes[gpu.image_index])
        
        next_frame += 1
        cpu_end_profile_zone()
        
        ////////////////////////////////////////////////
        
        cpu_end_profile_zone()
        
        if print_profile_and_stats {
            cpu_profile_scope("print cpu profile")
            
            zones := the_cpu_profile_zones
            
            xx :: proc (seconds: f64) -> time.Duration { return cast(time.Duration) (seconds * cast(f64) time.Second) }
            root := zones[0]
            total_time := profiler.clocks_to_seconds(root.duration_with_children)
            
            print("---------------------\nCPU profile:\n")
            if false { // tree view
                link: u32
                for {
                    zone := zones[link]
                    depth := zone.depth_of_the_event
                    
                    seconds               := profiler.clocks_to_seconds(zone.duration)
                    seconds_with_children := profiler.clocks_to_seconds(zone.duration_with_children)
                    
                    print("  %v", view_percentage(seconds_with_children/total_time))
                    for _ in 0..<depth { print("    ") }
                    print(" %v", xx(seconds))
                    if zone.duration_with_children != zone.duration {
                        print(" (with children %v)", xx(seconds_with_children))
                    }
                    print(" - %v", zone.name)
                    print("\n")
                    
                    link = zone.depth_next_event
                    if link == 0 { break }
                }
            } else { // zone view
                // @todo map only cares about name, durations and should also keep a hitcount, the tree data is not correct afterwards
                zone_map := make(map[string] profiler.Zone, context.temp_allocator)
                
                for zone in zones {
                    if zone.name not_in zone_map {
                        zone_map[zone.name] = zone
                    } else {
                        entry := &zone_map[zone.name]
                        entry.duration               += zone.duration
                        entry.duration_with_children += zone.duration_with_children
                    }
                }
                
                zone_list := make([dynamic] profiler.Zone, context.temp_allocator)
                
                for _, zone in zone_map {
                    append(&zone_list, zone)
                }
                
                slice.sort_by(zone_list[:], proc (a, b: profiler.Zone) -> bool {
                    return a.duration > b.duration
                })
                
                
                // @todo also print total time
                // @todo make a toggle for omission
                Omit_Below :: 0 // 0.01
                for zone in zone_list {
                    // @todo also print hitcount and avg duration per hit (mean?)
                    seconds               := profiler.clocks_to_seconds(zone.duration)
                    seconds_with_children := profiler.clocks_to_seconds(zone.duration_with_children)
                    
                    percent := seconds/total_time
                    if percent < Omit_Below {
                        print(" <%v ...\n", view_percentage(0.01))
                        break
                    }
                    print("  %v", view_percentage(percent))
                    print(" %v", xx(seconds))
                    if zone.duration_with_children != zone.duration {
                        print(" (with children %v)", xx(seconds_with_children))
                    }
                    print(" - %v", zone.name)
                    print("\n")
                    
                }
            }
        }
    }
    
    ////////////////////////////////////////////////
    // Cleanup and Shutdown
    
	check(vk.DeviceWaitIdle(gpu.device))
    
    gpu_free(gpu, buffers.vertices)
    gpu_free(gpu, buffers.indices)
    gpu_free(gpu, buffers.meshlets)
    gpu_free(gpu, buffers.meshlet_data)
    gpu_free(gpu, buffers.meshes)
    gpu_free(gpu, buffers.draws)
    gpu_free(gpu, buffers.draw_commands)
    gpu_free(gpu, buffers.draw_visibility)
    gpu_free(gpu, buffers.meshlet_visibility)
    gpu_free(gpu, buffers.bottom_level_acceleration_structures)
    gpu_free(gpu, buffers.top_level_acceleration_structures)
    
    for it in bottom_levels {
        vk.DestroyAccelerationStructureKHR(gpu.device, it.acceleration_structure, nil)
    }
    delete(bottom_levels, context.allocator) // @volatile
    vk.DestroyAccelerationStructureKHR(gpu.device, top_level.acceleration_structure, nil)
    
    for &bump in frame_bump_allocators {
        bump_allocator_delete(gpu, &bump)
    }
    
    for stage in Stage {
        destroy_pipeline(gpu, pipelines.meshlets[stage])
        destroy_pipeline(gpu, pipelines.culling[stage])
    }
    destroy_pipeline(gpu, pipelines.depth_reduce)
    destroy_pipeline(gpu, pipelines.ui)
    
    for texture in textures {
        gpu_free_image(gpu, texture)
    }
    
    destroy_descriptor_heap(gpu, descriptor_heap)
    
    destroy_stuff(gpu, &stuff)
    
    vk.DestroySemaphore(gpu.device, frame_semaphore, nil)
    for pool in stats_pools { vk.DestroyQueryPool(gpu.device, pool, nil) }
    
    gpu_profile_deinit(gpu)
    
    gpu_deinit(gpu)
    
    ////////////////////////////////////////////////
    
    delete(watchers)
    free(the_cpu_profiler, context.allocator) // @volatile see new
    delete(the_cpu_profile_zones)
    
    deinit_assets()
    
    delete(scene_draws)
}

////////////////////////////////////////////////

the_cpu_profiler: ^profiler.Event_Table

cpu_begin_profile_zone :: proc (name: string) {
    profiler.record_event(the_cpu_profiler, read_cycle_counter(), .BeginZone, name)
}
cpu_end_profile_zone :: proc () {
    profiler.record_event(the_cpu_profiler, read_cycle_counter(), .EndZone, "")
}

@(deferred_in=_cpu_end_scoped_profile_zone)
cpu_profile_scope :: proc (name: string) {
    profiler.record_event(the_cpu_profiler, read_cycle_counter(), .BeginZone, name)
}

_cpu_end_scoped_profile_zone :: proc (_: string) {
    profiler.record_event(the_cpu_profiler, read_cycle_counter(), .EndZone, "")
}

@(deferred_in=_cpu_procedure_end_profile_zone)
cpu_profile_procedure :: proc (loc := #caller_location) {
    profiler.record_event(the_cpu_profiler, read_cycle_counter(), .BeginZone, loc.procedure)
}
_cpu_procedure_end_profile_zone :: proc (_ := #caller_location) {
    profiler.record_event(the_cpu_profiler, read_cycle_counter(), .EndZone, "")
}

////////////////////////////////////////////////

get_next_image :: proc (gpu: ^Gpu, semaphore: vk.Semaphore, frame_index: u64) -> bool {
    info := vk.AcquireNextImageInfoKHR {
        sType = .ACQUIRE_NEXT_IMAGE_INFO_KHR,
        
        swapchain  = gpu.swapchain,
        timeout    = MaxTimeout,
        semaphore  = gpu.image_aquired_semaphores[frame_index],
        deviceMask = 1 << 0,
    }
    
    result := vk.AcquireNextImage2KHR(gpu.device, &info, &gpu.image_index)
    if result == .ERROR_OUT_OF_DATE_KHR || result == .SUBOPTIMAL_KHR {
        return false
    }
    check(result)
    
    return true
}

cull_and_render :: proc (gpu: ^Gpu, cmd: vk.CommandBuffer, stage: Stage, pipelines: Pipelines, shaders: Shaders, buffers: Buffers, bump: ^Bump_Allocator,  stats_pool: vk.QueryPool, query_index: u32, stuff: ^Render_Targets_And_Stuff, draw_count: u32, dvb_and_mvb_cleared: ^bool, view_from_world: m4, screen_from_view: m4, near_z, draw_distance: f32, debug: Debug, frame_heap_offset, top_level_acceleration_structure_index: u32) {
    //
    // early pass - frustum cull             & fill objects that *were* visible last frame
    //  late pass - frustum & occlusion cull & fill objects that were *not* visible last frame
    //
    
    cpu_label: string
    switch stage {
    case .early: cpu_label = "record early pass"
    case .late:  cpu_label = "record late pass"
    case .post:  cpu_label = "record post pass"
    }
    cpu_profile_scope(cpu_label)
    
    frustum: [4] f32
    if debug.culling_enabled {
        frustum_x := get_row_v4(screen_from_view, 3) + get_row_v4(screen_from_view, 0) // x + w < 0
        frustum_y := get_row_v4(screen_from_view, 3) + get_row_v4(screen_from_view, 1) // y + w > 0
        frustum_x /= length(frustum_x.xyz)
        frustum_y /= length(frustum_y.xyz)
        
        frustum[0] = frustum_x.x
        frustum[1] = frustum_x.z
        frustum[2] = frustum_y.y
        frustum[3] = frustum_y.z
    }
    
    shader_culling_flags: u32 
    if debug.culling_enabled   { shader_culling_flags |= DebugFlag_FrustumCulling   }
    if debug.lod_enabled       { shader_culling_flags |= DebugFlag_LevelOfDetail    }
    if debug.occlusion_enabled { shader_culling_flags |= DebugFlag_OcclusionCulling }
    
    draw_group_count := bump_allocate(bump, uv3)
    
    cull_data := bump_allocate(bump, Cull_Data)
    cull_data.cpu^ = {
        view_from_world = view_from_world,
        
        pyramid_size = cast(v2) stuff.depth_pyramid.size.xy,
        s00 = screen_from_view[0,0],
        s11 = screen_from_view[1,1],
        near_z = near_z,
        far_z  = draw_distance,
        frustum = frustum,
        
        draw_count = draw_count,
        flags      = shader_culling_flags,
        
        lod_base = 10,
        lod_step = 1.5,
        
        depth_pyramid_index = stuff.depth_pyramid.sampled_index,
        draw_buffer            = buffers.draws.gpu.p,
        mesh_buffer            = buffers.meshes.gpu.p,
        draw_visibility_buffer = buffers.draw_visibility.gpu.p,
        draw_command_buffer    = buffers.draw_commands.gpu.p,
        draw_group_count       = {}, // @volatile must be assigned later when its allocated from the frame bump
    }
    cull_data.cpu.draw_group_count = draw_group_count.gpu.p
    
    draw_data := bump_allocate(bump, Draw_Data)
    draw_data.cpu^ = {
        pyramid_size = cast(v2) stuff.depth_pyramid.size.xy,
        s00 = screen_from_view[0,0],
        s11 = screen_from_view[1,1],
        near_z = near_z,
        far_z  = draw_distance,
        frustum = frustum,
        
        flags = shader_culling_flags,
        
        screen_size  = cast(v2) gpu.swapchain_size,
        view_from_world = view_from_world,
        
        frame_heap_offset                      = frame_heap_offset,
        depth_pyramid_index                    = stuff.depth_pyramid.sampled_index,
        top_level_acceleration_structure_index = top_level_acceleration_structure_index,
        
        draw_command_buffer       = buffers.draw_commands.gpu.p,
        draw_buffer               = buffers.draws.gpu.p,
        meshlet_buffer            = buffers.meshlets.gpu.p,
        meshlet_data_buffer       = buffers.meshlet_data.gpu.p,
        vertex_buffer             = buffers.vertices.gpu.p,
        meshlet_visibility_buffer = buffers.meshlet_visibility.gpu.p,
    }
    
    cull_label: cstring
    switch stage {
    case .early: cull_label = "early culling"
    case .late:  cull_label = "late culling"
    case .post:  cull_label = "post culling"
    }
    before_fill := vk.PipelineStageFlags2 { .DRAW_INDIRECT }
    switch stage {
    case .early:       // nothing
    case .late, .post: before_fill += { .PRE_RASTERIZATION_SHADERS }
    }
    
    gpu_labeled_region_begin(cmd, cull_label, {0.0, 0.6, 0.8, 1.0})
    gpu_profile_zone_begin(cast(string) cull_label)
        gpu_barrier(cmd, before_fill, { .ALL_TRANSFER })
        
        if stage == .early {
            // @todo this is stupidly redundant
            if !dvb_and_mvb_cleared^ {
                dvb_and_mvb_cleared^ = true
                gpu_fill_memory(cmd, buffers.draw_visibility,    draw_count, 0)
                gpu_fill_memory(cmd, buffers.meshlet_visibility, len(buffers.meshlet_visibility.cpu), 0)
            }
        }
        
        // draw_group_count = {0, 1, 1}
        gpu_fill_memory(cmd, draw_group_count.gpu, 0, size_of(draw_group_count.cpu.x),  0)
        gpu_fill_memory(cmd, draw_group_count.gpu, 1, size_of(draw_group_count.cpu.yz), size_of(draw_group_count.cpu.x))
        
        before_dispatch := vk.PipelineStageFlags2 { .ALL_TRANSFER  }
        switch stage {
        case .early: // nothing
        case .late:  before_dispatch += { .COMPUTE_SHADER } // depth pyramid
        case .post:  // nothing
        }
        
        gpu_barrier(cmd, before_dispatch, { .COMPUTE_SHADER })
        
        gpu_set_pipeline(cmd, pipelines.culling[stage])
        gpu_dispatch(cmd, cull_data.gpu, grid_dimension_from_total_count(shaders.culling, x = draw_count))
        
    gpu_profile_zone_end()
    gpu_labeled_region_end(cmd)
    
    ////////////////////////////////////////////////
    
    before_draw := vk.PipelineStageFlags2 { .COMPUTE_SHADER }
    after_draw  := vk.PipelineStageFlags2 { .DRAW_INDIRECT, .PRE_RASTERIZATION_SHADERS }
    switch stage {
    case .early: 
        before_draw += { .BOTTOM_OF_PIPE }
        
    case .late, .post:  
        before_draw += { .COLOR_ATTACHMENT_OUTPUT, .LATE_FRAGMENT_TESTS  }
        after_draw  += { .COLOR_ATTACHMENT_OUTPUT, .EARLY_FRAGMENT_TESTS }
    }
    gpu_barrier(cmd, before_draw, after_draw)
    
    desc := Render_Pass_Desc {
        color_targets = { { 
            texture     = stuff.color_buffer,
            view        = stuff.color_view,
            load_op     = stage == .early ? .CLEAR : .LOAD,
            store_op    = .STORE,
            clear_color = stage == .early ? {0.07, 0.07, 0.07, 1} : {},
        } },
        
        depth_target  = { // :ViewSpace: 0 is the maximal depth value
            texture     = stuff.depth_buffer,
            view        = stuff.depth_view,
            load_op     = stage == .early ? .CLEAR : .LOAD,
            store_op    = stage != .post  ? .STORE : .DONT_CARE,
            clear_depth = 0,
        },
    }
    
    switch stage {
    case .early:
        gpu_profile_zone_begin("early rendering pass")
        gpu_labeled_region_begin(cmd, "early rendering pass", {0.6, 0.1, 07, 1.0})
    case .late:
        gpu_profile_zone_begin("late rendering pass")
        gpu_labeled_region_begin(cmd, "late rendering pass", {0.6, 0.1, 07, 1.0})
    case .post:
        gpu_profile_zone_begin("post rendering pass")
        gpu_labeled_region_begin(cmd, "post rendering pass", {0.6, 0.1, 07, 1.0})
    }
    
    gpu_begin_rendering(gpu, cmd, desc)
        
        gpu_set_viewport(cmd, size = cast(v2) gpu.swapchain_size)
        gpu_set_scissor(cmd,  size = gpu.swapchain_size)
        gpu_set_color_write_mask(cmd, 0, { .R, .G, .B, .A })
        gpu_set_depth_state(cmd, depth_test_enable = true, depth_write_enable = true, depth_compare_op = .GREATER)
        gpu_set_cull_state(cmd, { .BACK }, .COUNTER_CLOCKWISE)
        gpu_set_rasterization_samples(cmd, ._1)
        
        // @speed only record if requested by caller(i.e. when it will actually be displayed
        vk.CmdBeginQuery(cmd, stats_pool, query_index, {})
        
        gpu_set_pipeline(cmd, pipelines.meshlets[stage])
        gpu_draw_mesh_tasks_indirect(cmd, draw_group_count.gpu, 1, draw_data.gpu)
        
        vk.CmdEndQuery(cmd, stats_pool, query_index)
    
    gpu_end_rendering(cmd)
    gpu_labeled_region_end(cmd)
    gpu_profile_zone_end()
}

grid_dimension_from_total_count :: proc (id: Shader_Id, x: u32 = 1, y: u32 = 1, z: u32 = 1) -> uv3 {
    shader := get_shader(id)
    result := shader_grid_dimension_from_total_count(shader, x, y, z)
    return result
}

////////////////////////////////////////////////

recreate_stuff :: proc (gpu: ^Gpu, stuff: ^Render_Targets_And_Stuff) {
    destroy_stuff(gpu, stuff)
    
    // Ensures that all reductions are at most 2x2 which makes sure they are conservative.
    pyramid_size := uv2{previous_power_of_two(gpu.swapchain_size.x), previous_power_of_two(gpu.swapchain_size.y)} 
    // Each mip level is a quarter of the size of the previous, as we half both dimensions each time.
    mip_count := 1 + max(integer_log2(pyramid_size.x), integer_log2(pyramid_size.y))
    
    stuff.depth_pyramid = gpu_allocate_texture(gpu, default_texture_desc(size = {pyramid_size.x,       pyramid_size.y,       1}, format = .R32_SFLOAT,               usage = { .SAMPLED, .STORAGE, .TRANSFER_SRC },   mip_count = mip_count))
    stuff.depth_buffer  = gpu_allocate_texture(gpu, default_texture_desc(size = {gpu.swapchain_size.x, gpu.swapchain_size.y, 1}, format = stuff.depth_buffer.format, usage = { .DEPTH_STENCIL_ATTACHMENT, .SAMPLED }))
    // @volatile we want a non-srgb format for the color buffer, but need to then match its component layout to make the "copy to swapchain" not mess up.
    stuff.color_buffer  = gpu_allocate_texture(gpu, default_texture_desc(size = {gpu.swapchain_size.x, gpu.swapchain_size.y, 1}, format = .B8G8R8A8_UNORM,      usage = { .COLOR_ATTACHMENT, .TRANSFER_SRC }))
    
    for i in 0..<mip_count {
        mip_size := pyramid_size
        mip_size.x >>= i
        mip_size.y >>= i
        mip_size = vec_max(mip_size, 1)
        append(&stuff.depth_pyramid_mips, Depth_Mip { mip_size, 0, 0})
    }
    
    stuff.depth_view  = gpu_create_image_view(gpu, stuff.depth_buffer, 0, 1)
    stuff.color_view  = gpu_create_image_view(gpu, stuff.color_buffer, 0, 1)
}

destroy_stuff :: proc (gpu: ^Gpu, stuff: ^Render_Targets_And_Stuff) {
    gpu_free_image(gpu, stuff.depth_pyramid)
    
    gpu_free_image(gpu, stuff.depth_buffer)
    gpu_free_image(gpu, stuff.color_buffer)
    gpu_destroy_texture_view(gpu, stuff.depth_view)
    gpu_destroy_texture_view(gpu, stuff.color_view)
    
    clear(&stuff.depth_pyramid_mips)
}

////////////////////////////////////////////////

print_sdl_error_and_exit :: proc (loc := #caller_location) -> ! {
    print("%v:%v:%v: SDL call returned %v\n", loc.file_path, loc.line, loc.column, sdl.GetError())
    os.exit(1)
}