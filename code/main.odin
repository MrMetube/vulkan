#+vet explicit-allocators
package main

import "base:runtime"

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

State :: struct {
    near_z: f32,
    // @correctness draw_distance/far_z is tested in view space, but that is just a translation and rotation right now. 
    // If we also scale, then this value is no longer also a world space distance. In that case we need to actually take
    // the cameras position and view direction, find the point at the draw distance and transform it into view space, 
    // where we then take its distance from the origin as the draw distance.
    draw_distance: f32, 
    
    debug:  Debug, // @naming
    
    absolute_frame_index: u64,
    
    
    // @todo this should not be kept between frames, its state that we just interpret from the physical inputs and not 
    // something we determine. It is just here, because we don't have a real input system and just directly take the 
    // sdl events which only notify us of changes and not states themselves.
    left_down: bool,
    right_down: bool,
    mouse_p:   v2,
    last_time: time.Tick,
    quit: bool,
}

Frame :: struct {
    index: u64,
    delta_time: f32,
    
    print_profile: bool,
    
    bump: ^Bump_Allocator,
    stats_pool: vk.QueryPool,
    query_index: u32,
    
    screen_size: uv2,
    
    draw_count: u32,
    
    frustum: [4] f32,
    view_from_world:  m4,
    screen_from_view: m4,
    
    top_level_acceleration_structure_index: u32,
    
    clear_dvb_and_mvb: bool, // @cleanup
}

Render_Targets :: struct {
    color_buffer:  Texture_Handle,
    depth_buffer:  Texture_Handle,
    depth_pyramid: Texture_Handle,
    
    color_view: vk.ImageView,
    depth_view: vk.ImageView,
    
    depth_pyramid_size: uv2,
    depth_pyramid_mips: [dynamic; 16] Depth_Mip,
    
    color_format:   vk.Format,
    depth_format:   vk.Format,
    pyramid_format: vk.Format,
}

////////////////////////////////////////////////

Depth_Mip :: struct {
    size: uv2,
    sampled_index: u32,
    storage_index: u32,
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

Debug :: struct {
    vsync: bool,
    
    culling_enabled:   bool,
    lod_enabled:       bool,
    occlusion_enabled: bool,
    display_pyramid:   bool,
    display_pyramid_mip_level: i32,
    
    cpu_time:  f64,
    gpu_time:  f64,
    cull_time:      [Stage] f64,
    rendering_time: [Stage] f64,
}

Camera :: struct {
    p: v3,
    orientation: q32,
    fov_y: f32,
}

////////////////////////////////////////////////

Shader_Info :: struct {
    source: Watcher_Id,
    common: Watcher_Id,
}

Shader :: struct {
    was_modified: bool,
    bytes:      [] u8,
    stage:      vk.ShaderStageFlag,
    local_size: uv3,
}

////////////////////////////////////////////////

the_shader_manager: Shader_Manager

Shader_Manager :: struct {
    initialized: bool,
    
    // These can never be freed
    infos:   [dynamic] Shader_Info,
    shaders: [dynamic] Shader,
    
    ////////////////////////////////////////////////
    
    // This needs to store the transient information in each Shader_Compilation and must be able to free individual compilation related allocations.
    compilation_allocator: Allocator,
    // This needs to store the byte data from the recompile and loading up until the next successful recompilation. It also needs to be able to free single allocations.
    bytes_allocator:          Allocator,
    shader_compilation_procs: Procs,
    shader_compilation_infos: [dynamic] Shader_Compilation,
}

Shader_Compilation :: struct {
    completed: bool,
    id: Shader_Id,
    input_path:    string,
    shader_output: string,
    old_bytes: [] u8,
}

Shader_Id  :: distinct u32
Nil_Shader :: cast(Shader_Id) 0

////////////////////////////////////////////////

// Maximum number of total task shader workgroups
TaskWidthLimit :: 1 << 22 // :Shader:

// @volatile Cull_Data.flags
DebugFlag_FrustumCulling   :: (1 << 0)
DebugFlag_LevelOfDetail    :: (1 << 1)
DebugFlag_OcclusionCulling :: (1 << 2)

Draw_Data :: struct #all_or_none { // :Shader:
    view_from_world: m4,
    
    s00, s11:      f32,
    near_z, far_z: f32,
    frustum:       [4] f32,
    
    flags: u32,
    
    depth_pyramid_index: u32,
    
    draw_command_buffer: vk.DeviceAddress "Draw_Command",
    draw_buffer:         vk.DeviceAddress "Draw",
    
    // draw only
    screen_size: v2,
    
    top_level_acceleration_structure_index: u32,
    
    meshlet_visibility_buffer: vk.DeviceAddress "uint",
    meshlet_buffer:            vk.DeviceAddress "Meshlet",
    meshlet_data_buffer:       vk.DeviceAddress "uint",
    vertex_buffer:             vk.DeviceAddress "Vertex",
    
    sun_direction: v3,
    
    // cull only
    pyramid_size: v2,
    
    lod_base:   f32,
    lod_step:   f32,
    draw_count: u32,
    
    draw_visibility_buffer: vk.DeviceAddress "bool",
    mesh_buffer:            vk.DeviceAddress "Mesh",
    draw_group_count:       vk.DeviceAddress "uvec3",
}

Depth_Data :: struct { // :Shader:
    size: v2,
    input_index:  u32,
    output_index: u32,
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
    
    // @todo make proper zero values for these: see the shader defaults outside the nil-test
    albedo_texture:   u32,
    normal_texture:   u32,
    emmisive_texture: u32,
    
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
    defer free(the_cpu_profiler, context.allocator)
    profiler.set_recording(the_cpu_profiler, true)
    
    the_cpu_profile_zones := make([dynamic] profiler.Zone, context.allocator)
    defer delete(the_cpu_profile_zones)
    
    profile_zone_begin("Setup")
    
    profile_zone_begin("SDL Window Creation")
    if !sdl.InitSubSystem({ .VIDEO }) { print_sdl_error_and_exit() }
    defer sdl.Quit()
    defer sdl.QuitSubSystem({ .VIDEO })
    
    window := sdl.CreateWindow("Vulkan Renderer", 1280, 720, sdl.WINDOW_VULKAN | sdl.WINDOW_RESIZABLE)
    if window == nil { print_sdl_error_and_exit () }
    defer sdl.DestroyWindow(window)
    profile_zone_end()
    
    ////////////////////////////////////////////////
    
    state: State
    state.near_z = 0.01
    state.draw_distance = 1000
    
    state.debug = {
        vsync = true,
        
        culling_enabled   = true,
        occlusion_enabled = true,
        
        // @todo lod generation and selection needs to be made better before it can be enabled without visible artefacts
        // lod_enabled       = true,
    }
    
    ////////////////////////////////////////////////
    
    profile_zone_begin("OS Metrics sleep")
    profiler.init_os_metrics()
    profile_zone_end()
    
    gpu := &Gpu {}
    
    debug_name_arena := make_arena()
    gpu_debug_name_init(arena_allocator(&debug_name_arena))
    defer gpu_debug_name_deinit()
    
    {
        props     := sdl.GetWindowProperties(window)
        hinstance := sdl.GetPointerProperty(props, sdl.PROP_WINDOW_WIN32_INSTANCE_POINTER, nil)
        gpu^ = gpu_init(hinstance, state.debug.vsync)
    }
    
    render_targets: Render_Targets
    init_render_targets(&render_targets)
    
    ////////////////////////////////////////////////
    
    // @todo is this part of Debug?
    profile_zone_begin("Init shaders")
    watchers := make(Watchers, context.allocator)
    
    init_shader_manager(context.allocator)
    
    generate_shader_api("shaders/api.generated.glsl")
    
    // @speed deduplicate the common watcher and somehow track that the other shaders all depend on it and should all reload if it is changed
    common_watcher := watchers_make(&watchers, "shaders/common.glsl")
    pipelines: Pipelines
    shaders := Shaders {
        meshlet_task = init_shader_and_watchers(&watchers, common_watcher, "shaders/meshlet.task"),
        meshlet_mesh = init_shader_and_watchers(&watchers, common_watcher, "shaders/meshlet.mesh"),
        meshlet_frag = init_shader_and_watchers(&watchers, common_watcher, "shaders/meshlet.frag"),
        culling      = init_shader_and_watchers(&watchers, common_watcher, "shaders/cull.comp"),
        depth_reduce = init_shader_and_watchers(&watchers, common_watcher, "shaders/depth_reduce.comp"),
        
        ui_vert = init_shader_and_watchers(&watchers, common_watcher, "shaders/ui.vert"),
        ui_frag = init_shader_and_watchers(&watchers, common_watcher, "shaders/ui.frag"),
    }
    
    profile_zone_end()
    
    ////////////////////////////////////////////////
    
    profile_zone_begin("Setup other gpu resources")
    
    gpu_profile_init(gpu)
    
    stats_count : u32 : 3
    stats_pools: [MaxFramesInFlight] vk.QueryPool
    for &it in stats_pools {
        it = create_query_pool(gpu, stats_count, .MESH_PRIMITIVES_GENERATED_EXT)
    }
    
    next_frame := cast(u64) MaxFramesInFlight+1
    frame_semaphore := gpu_create_timeline_semaphore(gpu, MaxFramesInFlight)
    
    profile_zone_end()
    
    profile_zone_begin("Allocate GPU Bumps")
    frame_bump_allocators: [MaxFramesInFlight] Bump_Allocator
    for &bump in frame_bump_allocators {
        bump = bump_allocator_make_temporary(gpu, 256 * Megabyte, usage = { .STORAGE_BUFFER, .TRANSFER_DST, .INDIRECT_BUFFER })
    }
    
    profile_zone_end()
    
    ////////////////////////////////////////////////

    scene: Scene
    init_scene(gpu, &scene)
    
    profile_zone_end()
    
    {
        events := profiler.swap_active_array_and_get_events(the_cpu_profiler)
        profiler.collate_events(events, &the_cpu_profile_zones, nil)
        print_cpu_profile(the_cpu_profile_zones[:])
        // Drop the print_cpu_profile event, the printing code assumes there only one root, 
        // but with this extra zone there are two root nodes without a parent.
        // @todo handmade hero used a frame marker event to cleanly seperate frames and then 
        // collected events into a ring buffer of N frames for historical data.
        profiler.swap_active_array_and_get_events(the_cpu_profiler)
    }
    
    for {
        profile_zone_begin("Frame")
        free_all(context.temp_allocator)
        
        ////////////////////////////////////////////////
        
        frame: Frame
        // @cleanup move into Frame
        mouse_delta: v2
        mouse_wheel_delta: f32
        vsync_changed: bool
        
        profile_zone_begin("Input Events")
        
        window_event_begin := time.tick_now()
        pyramid_mip_level_delta: i32
        for event: sdl.Event; sdl.PollEvent(&event); {
            #partial switch event.type {
            case .QUIT:
                state.quit = true
            
            case .MOUSE_MOTION:
                state.mouse_p = { event.motion.x, cast(f32) gpu.swapchain_size.y - event.motion.y }
                mouse_delta   = { event.motion.xrel, event.motion.yrel }
                
            case .MOUSE_BUTTON_DOWN: 
                if event.button.button == sdl.BUTTON_LEFT  { state.left_down  = true  }
                if event.button.button == sdl.BUTTON_RIGHT { state.right_down = true  }
            case .MOUSE_BUTTON_UP:   
                if event.button.button == sdl.BUTTON_LEFT  { state.left_down  = false }
                if event.button.button == sdl.BUTTON_RIGHT { state.right_down = false }
            
            case .KEY_DOWN:
                debug := &state.debug
                switch event.key.key {
                case sdl.K_C:     debug.culling_enabled   = !debug.culling_enabled
                case sdl.K_L:     debug.lod_enabled       = !debug.lod_enabled
                case sdl.K_O:     debug.occlusion_enabled = !debug.occlusion_enabled
                case sdl.K_P:     debug.display_pyramid   = !debug.display_pyramid
                
                case sdl.K_V:     debug.vsync = !debug.vsync; vsync_changed = true
                
                case sdl.K_I:     frame.print_profile = true
                
                case sdl.K_PLUS:  pyramid_mip_level_delta = +1
                case sdl.K_MINUS: pyramid_mip_level_delta = -1
                
                case sdl.K_ESCAPE: state.quit = true
                }
                
            case .MOUSE_WHEEL:
                mouse_wheel_delta = event.wheel.y
            }
        }
        profile_zone_end()
        
        // Don't waste the users time by waiting and rendering another frame.
        if state.quit {
            profile_zone_end() // Frame
            break
        }
        
        window_event_delta := time.tick_since(window_event_begin)
        
        ////////////////////////////////////////////////
        
        cpu_delta: f64
        {
            debug := &state.debug
            debug.display_pyramid_mip_level = clamp(debug.display_pyramid_mip_level+pyramid_mip_level_delta, 0, cast(i32) len(render_targets.depth_pyramid_mips)-1)
            
            current_time  := time.tick_now()
            delta_tick    := time.tick_diff(state.last_time, current_time)
            // Though we do not track the time, *we* take to handle the input, we also exclude all time taken by sdl and windows(which may block)
            delta_tick    -= window_event_delta
            
            cpu_delta  = time.duration_seconds(delta_tick)
            frame.delta_time = cast(f32) cpu_delta
            state.last_time  = current_time
            
            if mouse_delta != 0 {
                if state.left_down {
                    scene.camera.p += la.mul(scene.camera.orientation, v3{ 1, 0, 0 } * (mouse_delta.x * -1 * 5) * frame.delta_time)
                    scene.camera.p += la.mul(scene.camera.orientation, v3{ 0, 1, 0 } * (mouse_delta.y *  1 * 5) * frame.delta_time)
                }
                if state.right_down {
                    yaw   := -mouse_delta.x * 0.001
                    pitch := -mouse_delta.y * 0.001
                    q := scene.camera.orientation
                    q = la.quaternion_angle_axis(yaw, v3 { 0, 1, 0 }) * la.quaternion_angle_axis(pitch, la.mul(q, v3{1,0,0})) * q
                    scene.camera.orientation = la.normalize(q)
                }
            }
            if mouse_wheel_delta != 0 {
                scene.camera.p += la.mul(scene.camera.orientation, v3{ 0, 0, -1 } * (mouse_wheel_delta * -100) * frame.delta_time)
            }
        }
        
        ////////////////////////////////////////////////
        
        if !scene.loaded {
            // @speed move as much of the work into a work queue
            load_scene(gpu, &scene)
            frame.clear_dvb_and_mvb = true
            frame.print_profile = true
        }
        
        ////////////////////////////////////////////////
        
        profile_zone_begin("Frame Sleep")
        gpu_wait_semaphore(gpu, frame_semaphore, next_frame - MaxFramesInFlight)
        profile_zone_end()
        
        // absolute_frame_index should only count renderer frames.
        frame.index                 = state.absolute_frame_index % MaxFramesInFlight
        state.absolute_frame_index += 1
        
        if gpu_recreate_swapchain_if_needed(gpu, state.debug.vsync, vsync_changed) {
            ok := get_next_image(gpu, frame_semaphore, frame.index)
            assert(ok)
        }
        
        if gpu.swapchain_state == .Was_Resized {
            gpu.swapchain_state = .Ok
            recreate_render_targets(gpu, &render_targets)
        }
        
        assert(gpu.swapchain_state != .Dirty)
        
        if gpu.swapchain_state != .Window_Is_Minimized {
            
            frame.screen_size = gpu.swapchain_size
            
            ////////////////////////////////////////////////
            
            if state.absolute_frame_index >= MaxFramesInFlight+1 {
                update_title_and_print_gpu_profile(gpu, stats_pools[:], stats_count, &state, frame, cpu_delta, window)
            }
            
            ////////////////////////////////////////////////
            
            frame.bump = &frame_bump_allocators[frame.index]
            bump_free_all(frame.bump)
            frame.stats_pool = stats_pools[frame.index]
            
            ////////////////////////////////////////////////
            
            hotreload_shaders_and_recreate_pipelines(gpu, &watchers, shaders, &pipelines, &frame, render_targets)
            
            ////////////////////////////////////////////////
            
            {
                //
                // :ViewSpace:
                // The default vulkan view space is right-handed with x+ being right, y+ down and the camera looking down z-. The depth buffer maps 
                // the near z clipping plane to 0 and the far plane to 1. This loses floating point precision for far away object and can increase
                // z-fighting.
                // We instead want the coordinate frame to be y+ as up and also want to reverse the depth mapping (reversed-z) to place the most 
                // amount of precision at the far plane. It is then also simple to move the far plane of the projection matrix towards infinity.
                // In the limit this produces the matrix given by projection_reversed_z_infinite_far_plane.
                // 
                oriented := cast(m4) la.matrix3_from_quaternion(scene.camera.orientation)
                frame.view_from_world  = la.inverse(translate(oriented, scene.camera.p))
                frame.screen_from_view = projection_reversed_z_infinite_far_plane(scene.camera.fov_y, cast(f32) gpu.swapchain_size.x / cast(f32) gpu.swapchain_size.y, state.near_z)
                
                if state.debug.culling_enabled {
                    frustum_x := get_row_v4(frame.screen_from_view, 3) + get_row_v4(frame.screen_from_view, 0) // x + w < 0
                    frustum_y := get_row_v4(frame.screen_from_view, 3) + get_row_v4(frame.screen_from_view, 1) // y + w > 0
                    frustum_x /= length(frustum_x.xyz)
                    frustum_y /= length(frustum_y.xyz)
                    
                    frame.frustum[0] = frustum_x.x
                    frame.frustum[1] = frustum_x.z
                    frame.frustum[2] = frustum_y.y
                    frame.frustum[3] = frustum_y.z
                }
            }
            
            ////////////////////////////////////////////////
            
            profile_zone_begin("Record command buffer")
            
            profile_zone_begin("reset command pool")
            check(vk.ResetCommandPool(gpu.device, gpu.command_pools[frame.index], {}))
            profile_zone_end()
            
            cmd := gpu_begin_command_recording(gpu, gpu.command_pools[frame.index])
            
            gpu_profile_frame_begin(gpu, cmd, frame.index)
            
            gpu_profile_zone_begin("frame init")
            
            vk.CmdResetQueryPool(cmd, frame.stats_pool, 0, stats_count)
            
            ////////////////////////////////////////////////
            
            {
                // @waste texture management and draw "generation" only really need to happen once per "level load" as there is no streaming in of data.
                
                profile_scope("Setup Descriptor Heap")
                
                write_texture :: proc (gpu: ^Gpu, index_offset: ^u32, image: vk.Image, format: vk.Format, sampled: bool, mip_base: u32 = 0, mip_count: u32 = vk.REMAINING_MIP_LEVELS) -> u32 {
                    result := index_offset^
                    index_offset^ += 1
                    // @speed this can write multiple descriptors in a single call, so we could expose a version that passes a base index and then a slice of images
                    write_texture_to_heap(gpu, result, image, format, sampled ? .SAMPLED_IMAGE : .STORAGE_IMAGE, mip_base, mip_count)
                    return result
                }
                
                descriptor_offset := cast(u32) (frame.index * DescriptorPerFrameLimit)
                
                // @todo add a null texture, which is a bright debug color so that uninitialized indices(0) are easy to find
                // nil_index := append_texture(gpu, &descriptor_heap, &descriptor_offset, nil_texture, true)
                descriptor_offset += 1
                descriptor_offset += last_used_heap_index // @todo we must not override the textures, but this is not the correct count
                
                // @todo this doesnt need to happen every frame
                depth_pyramid := get_texture(render_targets.depth_pyramid)^
                for &mip, mip_level in render_targets.depth_pyramid_mips {
                    mip.sampled_index = write_texture(gpu, &descriptor_offset, depth_pyramid.image, render_targets.pyramid_format, true,  cast(u32) mip_level, 1)
                    mip.storage_index = write_texture(gpu, &descriptor_offset, depth_pyramid.image, render_targets.pyramid_format, false, cast(u32) mip_level, 1)
                }
                
                write_acceleration_structure_to_heap(gpu, descriptor_offset, scene.top_level)
                frame.top_level_acceleration_structure_index = descriptor_offset
                descriptor_offset += 1
                
                // @todo can we just offset the heap's address when we bind it? this removes the need for the frame.frame_heap_offset, if we then also store the correct offset and not the absolute index for the top_level_acceleration_structure
                gpu_set_active_heap(cmd, gpu.descriptor_heap)
            
                // @todo is this barrier correct in the commandbuffer if the writes to the heap are done by the cpu? probably a @race
                gpu_barrier(cmd, { .BOTTOM_OF_PIPE }, { .COMPUTE_SHADER, .PRE_RASTERIZATION_SHADERS, .FRAGMENT_SHADER, .DRAW_INDIRECT }, { .descriptors })
            }
            
            ////////////////////////////////////////////////
            
            draw_buffer: Gpu_Slice(Draw)
            {
                profile_scope("Copy draws")
                frame.draw_count = cast(u32) len(scene.draws)
                draw_buffer = bump_allocate_slice(frame.bump, [] Draw, frame.draw_count)
                copy(draw_buffer.cpu, scene.draws[:])
            }
            
            ////////////////////////////////////////////////
            
            {
                color           := get_texture(render_targets.color_buffer) // frame: image
                depth           := get_texture(render_targets.depth_buffer) // frame: image
                depth_pyramid   := get_texture(render_targets.depth_pyramid) // frame: image
                swapchain_image := gpu.swapchain_images[gpu.image_index]
                
                color_format   := render_targets.color_format
                depth_format   := render_targets.depth_format
                pyramid_format := render_targets.pyramid_format
                
                gpu_image_barriers(cmd, { .BY_REGION },
                    create_image_barrier_from_undefined(color.image,         color_format,         { .COLOR_ATTACHMENT_OUTPUT, .EARLY_FRAGMENT_TESTS }, { .COLOR_ATTACHMENT_WRITE                       }),
                    create_image_barrier_from_undefined(depth.image,         depth_format,         { .COLOR_ATTACHMENT_OUTPUT, .EARLY_FRAGMENT_TESTS }, { .DEPTH_STENCIL_ATTACHMENT_WRITE, .MEMORY_READ }), 
                    create_image_barrier_from_undefined(depth_pyramid.image, pyramid_format,       { .COMPUTE_SHADER                                 }, { .MEMORY_READ, .MEMORY_WRITE                   }),
                    create_image_barrier_from_undefined(swapchain_image,     gpu.swapchain_format, { .ALL_TRANSFER                                   }, { .TRANSFER_WRITE                               }),
                )
            }
            
            gpu_profile_zone_end()
            
            ////////////////////////////////////////////////
            
            cull_and_render(cmd, .early, pipelines, shaders, &render_targets, state, scene, &frame, draw_buffer)
            
            generate_depth_pyramid(cmd, pipelines, shaders, render_targets, frame)
            
            cull_and_render(cmd, .late, pipelines, shaders, &render_targets, state, scene, &frame, draw_buffer)
            
            cull_and_render(cmd, .post, pipelines, shaders, &render_targets, state, scene, &frame, draw_buffer)
            
            if false {
                render_ui(cmd, pipelines, render_targets, state, frame)
            }
            
            ////////////////////////////////////////////////
            
            {
                gpu_profile_zone_begin("copy to swapchain")
                source_image    := get_texture(render_targets.color_buffer) // frame: image
                swapchain_image := gpu.swapchain_images[gpu.image_index]
                
                if state.debug.display_pyramid {
                    source_image = get_texture(render_targets.depth_pyramid)
                }
                
                gpu_barrier(cmd, { .COLOR_ATTACHMENT_OUTPUT, .LATE_FRAGMENT_TESTS, .DRAW_INDIRECT, .PRE_RASTERIZATION_SHADERS }, { .ALL_TRANSFER })
                
                if !state.debug.display_pyramid {
                    vk.CmdCopyImage(cmd, source_image.image, .GENERAL, swapchain_image, .GENERAL, 1, &vk.ImageCopy {
                        srcSubresource = { aspectMask = { .COLOR }, layerCount = 1 },
                        dstSubresource = { aspectMask = { .COLOR }, layerCount = 1 },
                        extent         = { gpu.swapchain_size.x, gpu.swapchain_size.y, 1 },
                    })
                } else {
                    mip_index := cast(u32) state.debug.display_pyramid_mip_level
                    mip_size  := cast(iv2) render_targets.depth_pyramid_mips[mip_index].size
                    vk.CmdBlitImage(cmd, source_image.image, .GENERAL, swapchain_image, .GENERAL, 1, &vk.ImageBlit {
                        srcSubresource = { aspectMask = { .COLOR }, layerCount = 1, mipLevel = mip_index },
                        dstSubresource = { aspectMask = { .COLOR }, layerCount = 1 },
                        srcOffsets = { {0, 0, 0}, { mip_size.x, mip_size.y, 1 }},
                        dstOffsets = { {0, 0, 0}, { cast(i32) gpu.swapchain_size.x, cast(i32) gpu.swapchain_size.y, 1 }},
                    }, .NEAREST)
                }
                
                gpu_image_barriers(cmd, { .BY_REGION }, create_image_barrier(swapchain_image, gpu.swapchain_format, { .ALL_TRANSFER }, { .TRANSFER_WRITE }, .GENERAL, {}, {}, .PRESENT_SRC_KHR))
                
                gpu_profile_zone_end()
            }
            
            ////////////////////////////////////////////////
            
            gpu_profile_frame_end()
            profile_zone_end()
            
            profile_zone_begin("submit and present queue")
            gpu_submit(gpu.general_queue, {
                { gpu.image_aquired_semaphores[frame.index], { .TRANSFER },     nil },
                
                { gpu.render_completes[gpu.image_index],     { .ALL_COMMANDS }, 0 },
                { frame_semaphore,                           { .ALL_COMMANDS }, next_frame },
            }, cmd)
            gpu_present(gpu, gpu.general_queue, gpu.render_completes[gpu.image_index])
            
            next_frame += 1
            profile_zone_end()
        }
        
        ////////////////////////////////////////////////
        
        profile_zone_end() // Frame
        {
            events := profiler.swap_active_array_and_get_events(the_cpu_profiler)
            profiler.collate_events(events, &the_cpu_profile_zones, nil)
            
            if frame.print_profile {
                print_cpu_profile(the_cpu_profile_zones[:])
            }
        }
    }
    
    ////////////////////////////////////////////////
    // Cleanup and Shutdown
    
    profiler.swap_active_array_and_get_events(the_cpu_profiler)
    
    profile_zone_begin("Cleanup")
    
    profile_zone_begin("wait and handles")
	check(vk.DeviceWaitIdle(gpu.device))
    
    for stage in Stage {
        destroy_pipeline(gpu, pipelines.meshlets[stage])
        destroy_pipeline(gpu, pipelines.culling[stage])
    }
    destroy_pipeline(gpu, pipelines.depth_reduce)
    destroy_pipeline(gpu, pipelines.ui)
    
    vk.DestroySemaphore(gpu.device, frame_semaphore, nil)
    for pool in stats_pools { vk.DestroyQueryPool(gpu.device, pool, nil) }
    
    gpu_profile_deinit(gpu)
    profile_zone_end()
    
    profile_zone_begin("allocations")
    
    profile_zone_begin("render targets")
    destroy_render_targets(gpu, &render_targets)
    profile_zone_end()
    
    profile_zone_begin("bump allocators")
    for &bump in frame_bump_allocators {
        bump_allocator_delete(gpu, &bump)
    }
    profile_zone_end()
    
    // @speed We should really make an allocator for images that we can just free all at once. 
    // This takes ~120ms with ~340/2.1Gb of textures.
    // This would not just aid shutdown speed, but also changing to another scene.
    deinit_scene(gpu, &scene)
    
    gpu_deinit(gpu)
    profile_zone_end()
    ////////////////////////////////////////////////
    
    profile_zone_begin("assets")
    delete(watchers)
    
    deinit_shader_manager()
    
    profile_zone_end()
    profile_zone_end()
    
    events := profiler.swap_active_array_and_get_events(the_cpu_profiler)
    profiler.collate_events(events, &the_cpu_profile_zones, nil)
    
    print_cpu_profile(the_cpu_profile_zones[:])
}

////////////////////////////////////////////////

the_cpu_profiler: ^profiler.Event_Table

profile_zone_begin :: proc (name: string) {
    profiler.record_event(the_cpu_profiler, read_cycle_counter(), .BeginZone, name)
}
profile_zone_end :: proc () {
    profiler.record_event(the_cpu_profiler, read_cycle_counter(), .EndZone, "")
}

@(deferred_in=_end_scoped_profile_zone)
profile_scope :: proc (name: string) {
    profiler.record_event(the_cpu_profiler, read_cycle_counter(), .BeginZone, name)
}

_end_scoped_profile_zone :: proc (_: string) {
    profiler.record_event(the_cpu_profiler, read_cycle_counter(), .EndZone, "")
}

@(deferred_in=_procedure_end_profile_zone)
profile_procedure :: proc (loc := #caller_location) {
    profiler.record_event(the_cpu_profiler, read_cycle_counter(), .BeginZone, loc.procedure)
}
_procedure_end_profile_zone :: proc (_ := #caller_location) {
    profiler.record_event(the_cpu_profiler, read_cycle_counter(), .EndZone, "")
}

print_cpu_profile :: proc (zones: [] profiler.Zone) {
    profile_procedure()
    
    xx :: proc (seconds: f64) -> time.Duration { return cast(time.Duration) (seconds * cast(f64) time.Second) }
    root := zones[0]
    total_time := profiler.clocks_to_seconds(root.duration_with_children)
    
    print("---------------------\nCPU profile:\n")
    if !false { // tree view
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

update_title_and_print_gpu_profile :: proc (gpu: ^Gpu, stats_pools: [] vk.QueryPool, stats_count: u32, state: ^State, frame: Frame, cpu_delta: f64, window: ^sdl.Window) {
    profile_scope("GPU profiling")
    
    triangle_count: u64
    if state.absolute_frame_index >= MaxFramesInFlight {
        profile_scope("count triangles")
        
        last_finished_stats_pool := stats_pools[frame.index]
        
        stats_result: [128] u64
        size := cast(int) size_of_slice(stats_result[:])
        
        check(vk.GetQueryPoolResults(gpu.device, last_finished_stats_pool, 0, 1, size, &stats_result[0], size_of(stats_result[0]), { ._64 }))
        
        for i in 0..<stats_count {
            triangle_count += stats_result[i]
        }
    }
    
    gpu_profile_collate_events(gpu, frame.index)
    
    gpu_delta             := gpu_profile_get_zone_duration(gpu, frame.index, "Frame")
    cull_delta, rendering_delta: [Stage] f64
    cull_delta[.early]     = gpu_profile_get_zone_duration(gpu, frame.index, "early culling")
    cull_delta[.late]      = gpu_profile_get_zone_duration(gpu, frame.index, "late culling")
    cull_delta[.post]      = gpu_profile_get_zone_duration(gpu, frame.index, "post culling")
    rendering_delta[.early] = gpu_profile_get_zone_duration(gpu, frame.index, "early rendering pass")
    rendering_delta[.late]  = gpu_profile_get_zone_duration(gpu, frame.index, "late rendering pass")
    rendering_delta[.post]  = gpu_profile_get_zone_duration(gpu, frame.index, "post rendering pass")
    
    blend_factor_k := time_smoothed_blend_factor(7, cpu_delta)
    
    debug := &state.debug
    debug.cpu_time = linear_blend(cpu_delta, debug.cpu_time, blend_factor_k)
    for stage in Stage {
        debug.cull_time[stage]      = linear_blend(cull_delta[stage],      debug.cull_time[stage],      blend_factor_k)
        debug.rendering_time[stage] = linear_blend(rendering_delta[stage], debug.rendering_time[stage], blend_factor_k)
    }
    // this might have happened when a validation error occurred, causing the smooth value to be messed for a very long time
    if gpu_delta >= 0 {
        debug.gpu_time = linear_blend(gpu_delta, debug.gpu_time, blend_factor_k)
    }
    
    view :: proc (seconds: f64) -> time.Duration {
        return time.duration_round(cast(time.Duration) (seconds * cast(f64) time.Second), 1 * time.Microsecond)
    }
    
    profile_zone_begin("Update window title")
    sb := strings.builder_make(context.temp_allocator)
    fmt.sbprintf(&sb, "%v tri, cpu: %.3v, gpu: %.3v (", 
        view_magnitude(triangle_count, kind = .Count),
        view(debug.cpu_time), view(debug.gpu_time), 
    )
    
    for stage in Stage {
        if stage != .early { fmt.sbprintf(&sb, ",") }
        fmt.sbprintf(&sb, "%v cull %.3v, %v render %.3v", stage, view(debug.cull_time[stage]), stage, view(debug.rendering_time[stage]))
    }
    fmt.sbprintf(&sb, "), [ ") 
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
        extra = fmt.sbprintf(&sb, ", displaying depth mip level %v ", debug.display_pyramid_mip_level)
    }
    fmt.sbprintf(&sb, "]")

    title := strings.to_cstring(&sb)
    sdl.SetWindowTitle(window, title)

    profile_zone_end()

    if frame.print_profile {
        gpu_print_profile(gpu, frame.index)
    }
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

// @todo frame should not be a pointer but for the stats query index
cull_and_render :: proc (cmd: vk.CommandBuffer, stage: Stage, pipelines: Pipelines, shaders: Shaders, render_targets: ^Render_Targets, state: State, scene: Scene, frame: ^Frame, draw_buffer: Gpu_Slice(Draw)) {
    //
    // early pass - frustum cull             & fill objects that *were* visible last frame
    //  late pass - frustum & occlusion cull & fill objects that were *not* visible last frame
    //  post pass - fill non-opaque objects
    
    cpu_label: string
    switch stage {
    case .early: cpu_label = "record early pass"
    case .late:  cpu_label = "record late pass"
    case .post:  cpu_label = "record post pass"
    }
    profile_scope(cpu_label)
    
    shader_culling_flags: u32 
    if state.debug.culling_enabled   { shader_culling_flags |= DebugFlag_FrustumCulling   }
    if state.debug.lod_enabled       { shader_culling_flags |= DebugFlag_LevelOfDetail    }
    if state.debug.occlusion_enabled { shader_culling_flags |= DebugFlag_OcclusionCulling }
    
    draw_group_count := bump_allocate(frame.bump, uv3)
    
    draw_data := bump_allocate(frame.bump, Draw_Data)
    draw_data.cpu^ = {
        view_from_world = frame.view_from_world,
        
        s00     = frame.screen_from_view[0,0],
        s11     = frame.screen_from_view[1,1],
        near_z  = state.near_z,
        far_z   = state.draw_distance,
        frustum = frame.frustum,
        
        flags = shader_culling_flags,
        
        depth_pyramid_index = get_texture(render_targets.depth_pyramid).sampled_index,
        
        draw_buffer         = draw_buffer.gpu.p,
        draw_command_buffer = scene.buffers.draw_commands.gpu.p,
        
        //
        
        screen_size = cast(v2) frame.screen_size,
        
        top_level_acceleration_structure_index = frame.top_level_acceleration_structure_index,
        
        meshlet_visibility_buffer = scene.buffers.meshlet_visibility.gpu.p,
        meshlet_buffer            = scene.buffers.meshlets.gpu.p,
        meshlet_data_buffer       = scene.buffers.meshlet_data.gpu.p,
        vertex_buffer             = scene.buffers.vertices.gpu.p,
        
        sun_direction = scene.sun_direction,
        
        //
        
        pyramid_size = cast(v2) render_targets.depth_pyramid_size,
        
        lod_base = 10,
        lod_step = 1.5,
        
        draw_count = frame.draw_count,
        
        draw_visibility_buffer = scene.buffers.draw_visibility.gpu.p,
        mesh_buffer            = scene.buffers.meshes.gpu.p,
        draw_group_count       = draw_group_count.gpu.p,
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
            if frame.clear_dvb_and_mvb {
                gpu_fill_memory(cmd, scene.buffers.draw_visibility,    frame.draw_count, 0)
                gpu_fill_memory(cmd, scene.buffers.meshlet_visibility, len(scene.buffers.meshlet_visibility.cpu), 0)
            }
        }
        
        // draw_group_count = {0, 1, 1}
        gpu_fill_memory(cmd, draw_group_count.gpu, 0, size_of(draw_group_count.cpu.x),  0)
        gpu_fill_memory(cmd, draw_group_count.gpu, 1, size_of(draw_group_count.cpu.yz), size_of(draw_group_count.cpu.x))
        
        before_dispatch := vk.PipelineStageFlags2 { .ALL_TRANSFER  }
        switch stage {
        case .early, .post: // nothing
        case .late:         before_dispatch += { .COMPUTE_SHADER } // depth pyramid
        }
        
        gpu_barrier(cmd, before_dispatch, { .COMPUTE_SHADER })
        
        gpu_set_pipeline(cmd, pipelines.culling[stage])
        gpu_dispatch(cmd, draw_data.gpu.p, grid_dimension_from_total_count(shaders.culling, x = frame.draw_count))
        
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
        render_area = rect_zero_dimension(frame.screen_size),
        color_targets = { { 
            view        = render_targets.color_view,
            load_op     = stage == .early ? .CLEAR : .LOAD,
            store_op    = .STORE,
            clear_color = stage == .early ? {0.07, 0.07, 0.07, 1} : {},
        } },
        
        depth_target  = { // :ViewSpace: 0 is the maximal depth value
            view        = render_targets.depth_view,
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
    
    gpu_begin_rendering(cmd, desc)
        
        gpu_set_viewport(cmd, size = cast(v2) frame.screen_size)
        gpu_set_scissor(cmd,  size = frame.screen_size)
        gpu_set_color_write_mask(cmd, 0, { .R, .G, .B, .A })
        gpu_set_depth_state(cmd, depth_test_enable = true, depth_write_enable = true, depth_compare_op = .GREATER)
        gpu_set_cull_state(cmd, { .BACK }, .COUNTER_CLOCKWISE)
        gpu_set_rasterization_samples(cmd, ._1)
        
        vk.CmdBeginQuery(cmd, frame.stats_pool, frame.query_index, {})
        
        gpu_set_pipeline(cmd, pipelines.meshlets[stage])
        gpu_draw_mesh_tasks_indirect(cmd, draw_group_count.gpu, 1, draw_data.gpu.p, draw_data.gpu.p, draw_data.gpu.p)
        
        vk.CmdEndQuery(cmd, frame.stats_pool, frame.query_index)
        frame.query_index += 1
    
    gpu_end_rendering(cmd)
    gpu_labeled_region_end(cmd)
    gpu_profile_zone_end()
}

generate_depth_pyramid :: proc (cmd: vk.CommandBuffer, pipelines: Pipelines, shaders: Shaders, render_targets: Render_Targets, frame: Frame) {
    profile_scope("record depth pyramid")
    
    gpu_profile_zone_begin("depth pyramid building")
    gpu_labeled_region_begin(cmd, "depth pyramid building", {0.4, 0.8, 0, 1.0})
    
    gpu_barrier(cmd, { .LATE_FRAGMENT_TESTS }, { .COMPUTE_SHADER })
    
    gpu_set_pipeline(cmd, pipelines.depth_reduce)
    
    for mip, mip_level in render_targets.depth_pyramid_mips {
        depth_data := bump_allocate(frame.bump, Depth_Data)
        depth_data.cpu^ = Depth_Data { 
            size = cast(v2) mip.size,
        }
        if mip_level == 0 {
            depth_data.cpu.input_index  = get_texture(render_targets.depth_buffer).sampled_index
            depth_data.cpu.output_index = get_texture(render_targets.depth_pyramid).storage_index
        } else if mip_level == 1 {
            depth_data.cpu.input_index  = get_texture(render_targets.depth_pyramid).sampled_index
            depth_data.cpu.output_index = mip.storage_index
        } else {
            depth_data.cpu.input_index  = render_targets.depth_pyramid_mips[mip_level-1].sampled_index
            depth_data.cpu.output_index = mip.storage_index
        }
        
        gpu_dispatch(cmd, depth_data.gpu.p, grid_dimension_from_total_count(shaders.depth_reduce, **mip.size))
        
        gpu_barrier(cmd, { .COMPUTE_SHADER }, { .COMPUTE_SHADER })
    }
    
    gpu_barrier(cmd, { .COMPUTE_SHADER }, { .EARLY_FRAGMENT_TESTS })
    
    gpu_labeled_region_end(cmd)
    gpu_profile_zone_end()
}

render_ui :: proc (cmd: vk.CommandBuffer, pipelines: Pipelines, render_targets: Render_Targets, state: State, frame: Frame) {
    @(static) xx: f32 // @cleanup
    xx += frame.delta_time
    
    @(static) active_rect: Rectangle2
    hot_rect: Rectangle2
    
    color_a := color4_from_u8(Color { 0x18, 0x18, 0x18, 0xFF })
    rect_a  := rect_min_dimension(cast(f32) 100, 100, 400, 160)
    color_b := Green
    rect_b  := rect_min_dimension(cast(f32) 200+400, 100, 400, 160)
    
    if !state.left_down { active_rect = {} }
    
    if rect_contains(rect_a, state.mouse_p) { hot_rect = rect_a }
    if rect_contains(rect_b, state.mouse_p) { hot_rect = rect_b }
    
    if state.left_down && active_rect == {} {
        active_rect = hot_rect != {} ? hot_rect : {-1, -1} // invalid rect
    }
    
    ui_draws := bump_allocate(frame.bump, [] UI_Draw, 2)
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
    
    ui_data := bump_allocate(frame.bump, UI_Data)
    ui_data.cpu^ = {
        draw_buffer = ui_draws.gpu.p,
        screen_size = cast(v2) frame.screen_size,
        mouse_p = state.mouse_p,
    }
    
    ui_draw_command := bump_allocate(frame.bump, UI_Draw_Command)
    ui_draw_command.cpu^ = { 6, cast(u32) len(ui_draws.cpu), 0 ,0 }
    
    gpu_barrier(cmd, 
        { .COLOR_ATTACHMENT_OUTPUT, .LATE_FRAGMENT_TESTS, .DRAW_INDIRECT, .PRE_RASTERIZATION_SHADERS }, 
        { .COLOR_ATTACHMENT_OUTPUT, .EARLY_FRAGMENT_TESTS, .PRE_RASTERIZATION_SHADERS },
    )
    
    // @todo decide if the users passes a z with which to do depth testing
    desc := Render_Pass_Desc {
        render_area = rect_zero_dimension(frame.screen_size),
        color_targets = { { 
            view     = render_targets.color_view,
            load_op  = .LOAD,
            store_op = .STORE
        } },
    }
    gpu_begin_rendering(cmd, desc)
    
    gpu_set_viewport(cmd, size = cast(v2) frame.screen_size)
    gpu_set_scissor(cmd,  size = frame.screen_size)
    gpu_set_input_assembly_state(cmd, .TRIANGLE_LIST)
    
    gpu_set_pipeline(cmd, pipelines.ui)
    gpu_draw_indirect(cmd, ui_draw_command.gpu, ui_data.gpu.p, ui_data.gpu.p)
    
    gpu_end_rendering(cmd)
}

grid_dimension_from_total_count :: proc (id: Shader_Id, x: u32 = 1, y: u32 = 1, z: u32 = 1) -> uv3 {
    shader := get_shader(id)
    result := shader_grid_dimension_from_total_count(shader, x, y, z)
    return result
}

////////////////////////////////////////////////

init_render_targets :: proc (render_targets: ^Render_Targets) {
    // @volatile we want a non-srgb format for the color buffer, but need to then match its component layout to make the "copy to swapchain" not mess up.
    render_targets.color_format   = .B8G8R8A8_UNORM // .B8G8R8A8_SRGB
    render_targets.depth_format   = .D32_SFLOAT
    render_targets.pyramid_format = .R32_SFLOAT
}

recreate_render_targets :: proc (gpu: ^Gpu, render_targets: ^Render_Targets) {
    profile_procedure()
    
    destroy_render_targets(gpu, render_targets)
    
    // Ensures that all reductions are at most 2x2 which makes sure they are conservative.
    pyramid_size := uv2{previous_power_of_two(gpu.swapchain_size.x), previous_power_of_two(gpu.swapchain_size.y)} 
    // Each mip level is a quarter of the size of the previous, as we half both dimensions each time.
    mip_count := 1 + max(integer_log2(pyramid_size.x), integer_log2(pyramid_size.y))
    
    render_targets.depth_pyramid_size = pyramid_size
    
    render_targets.color_buffer  = create_texture(gpu, size = {gpu.swapchain_size.x, gpu.swapchain_size.y, 1}, format = render_targets.color_format,   usage = { .COLOR_ATTACHMENT, .TRANSFER_SRC })
    render_targets.depth_buffer  = create_texture(gpu, size = {gpu.swapchain_size.x, gpu.swapchain_size.y, 1}, format = render_targets.depth_format,   usage = { .DEPTH_STENCIL_ATTACHMENT, .SAMPLED })
    render_targets.depth_pyramid = create_texture(gpu, size = {pyramid_size.x,       pyramid_size.y,       1}, format = render_targets.pyramid_format, usage = { .SAMPLED, .STORAGE, .TRANSFER_SRC },   mip_count = mip_count)
    
    depth := get_texture(render_targets.depth_buffer)
    color := get_texture(render_targets.color_buffer)
    // @todo we dont even need the aspect mask, if this is only used for beginRendering as a depth target, as that mask is ignored
    render_targets.depth_view = gpu_create_image_view(gpu, depth.image, render_targets.depth_format, 0, 1)
    render_targets.color_view = gpu_create_image_view(gpu, color.image, render_targets.color_format, 0, 1)
    
    for i in 0..<mip_count {
        mip_size := pyramid_size
        mip_size.x >>= i
        mip_size.y >>= i
        mip_size = vec_max(mip_size, 1)
        append(&render_targets.depth_pyramid_mips, Depth_Mip { mip_size, 0, 0})
    }
}

destroy_render_targets :: proc (gpu: ^Gpu, render_targets: ^Render_Targets) {
    free_texture(gpu, render_targets.color_buffer)
    free_texture(gpu, render_targets.depth_buffer)
    free_texture(gpu, render_targets.depth_pyramid)
    
    gpu_destroy_texture_view(gpu, render_targets.color_view)
    gpu_destroy_texture_view(gpu, render_targets.depth_view)
    
    clear(&render_targets.depth_pyramid_mips)
}

////////////////////////////////////////////////

init_shader_manager :: proc (bytes_allocator: Allocator) {
    manager := &the_shader_manager
    
    // Nils
    append_nothing(&manager.shaders)
    append_nothing(&manager.infos)
    
    manager.compilation_allocator = context.allocator
    manager.bytes_allocator       = bytes_allocator
    
    manager.initialized = true
}

deinit_shader_manager :: proc () {
    manager := get_shader_manager()
    load_all_compiled_shaders() // finish all running compilations and clean them up
    for shader in manager.shaders {
        delete(shader.bytes, manager.bytes_allocator)
    }
    delete(manager.shaders)
    delete(manager.infos)
    delete(manager.shader_compilation_procs)
    delete(manager.shader_compilation_infos)
}

get_shader_manager :: proc (loc := #caller_location) -> ^Shader_Manager {
    manager := &the_shader_manager
    assert(manager.initialized, loc = loc)
    
    return manager
}

////////////////////////////////////////////////

make_shader :: proc () -> (Shader_Id, ^Shader_Info) {
    manager := get_shader_manager()
    
    id := cast(Shader_Id) len(manager.infos)
    info   := append_into(&manager.infos)
    append_into(&manager.shaders)
    
    return id, info
}

get_shader :: proc (id: Shader_Id, immediately: bool = true, loc := #caller_location) -> ^Shader {
    manager := get_shader_manager()
    
    id := id
    if id >= auto_cast len(manager.shaders) {
        id = Nil_Shader
    } else {
        load_compiled_shader(id, immediately)
    }
    
    result := &manager.shaders[id]
    if immediately {
        assert(result.bytes != nil, "Failed to immediately get shader.", loc = loc)
    }
    
    return result
}

get_shader_info :: proc (id: Shader_Id) -> ^Shader_Info {
    manager := get_shader_manager()
    
    id := id
    if id >= auto_cast len(manager.infos) {
        id = Nil_Shader
    }
    
    result := &manager.infos[id]
    return result
}

make_shader_compilation :: proc () -> (^Procs, ^Shader_Compilation, Allocator) {
    manager := get_shader_manager()
    
    comp  := append_into(&manager.shader_compilation_infos)
    procs := &manager.shader_compilation_procs
    alloc := manager.compilation_allocator
    
    return procs, comp, alloc
}

check_and_reset_shaders_was_modified :: proc (ids: ..Shader_Id) -> bool {
    result := false
    
    for id in ids {
        shader := get_shader(id, immediately = false)
        result ||= shader.was_modified
        shader.was_modified = false
    }
    
    return result
}

load_all_compiled_shaders :: proc (immediately := false) {
    load_compiled_shader(0, immediately)
}

// If id == 0 then all shaders will be loaded.
load_compiled_shader :: proc (id: Shader_Id, immediately := false) {
    manager := get_shader_manager()
    if len(manager.shader_compilation_procs) == 0 { return }
    
    completed_count: int
    for &p, index in manager.shader_compilation_procs {
        info := &manager.shader_compilation_infos[index]
        if id != 0 && info.id != id { continue }
        
        state, wait_err := os.process_wait(p, timeout = immediately ? os.TIMEOUT_INFINITE : 0)
        done := true
        if !immediately {
            if wait_err == .Timeout || !state.exited {
                done = false
            }
        } else {
            assert(wait_err == nil)
        }
        
        if done {
            completed_count += 1
            info.completed = true
            
            if state.exit_code != 0 {
                fmt.printfln("Shader compilation failed for %q", info.input_path)
            } else {
                load_and_parse_shader(info^)
            }
        }
        
        if id != 0 { break }
    }
    
    if completed_count != 0 {
        if completed_count == len(manager.shader_compilation_procs) {
            clear(&manager.shader_compilation_procs)
            clear(&manager.shader_compilation_infos)
        } else {
            #reverse for info, index in manager.shader_compilation_infos {
                if info.completed {
                    unordered_remove(&manager.shader_compilation_procs, index)
                    unordered_remove(&manager.shader_compilation_infos, index)
                }
            }
        }
    }
}

load_and_parse_shader :: proc (info: Shader_Compilation) {
    manager := get_shader_manager()
    
    defer {
        delete(info.input_path,    manager.compilation_allocator)
        delete(info.shader_output, manager.compilation_allocator)
    }
    
    shader_bytes, err := os.read_entire_file(info.shader_output, manager.bytes_allocator)
    if err != nil {
        fmt.printfln("Could not load the output file of %q, which is %q: %v", info.input_path, info.shader_output, os.error_string(err))
        
        if manager.shaders[info.id].bytes == nil {
            assert(false, fmt.tprintf("Failed to initially load the shader %q", info.input_path))
        }
        return
    }
    
    delete(info.old_bytes, manager.bytes_allocator)
    
    shader: Shader
    shader.was_modified = true
    shader.bytes = shader_bytes
    parse_shader(&shader)
    
    manager.shaders[info.id] = shader
}

////////////////////////////////////////////////

init_shader_and_watchers :: proc (watchers: ^Watchers, common_watcher: Watcher_Id, input: string, output_extension := ".spv") -> Shader_Id {
    id, info := make_shader()
    
    info.source = watchers_make(watchers, input)
    info.common = common_watcher
    
    watcher_depend_on(watchers, info.common)
    watcher_depend_on(watchers, info.source)
    
    return id
}

recompile_shaders_if_needed :: proc (watchers: ^Watchers, shaders_ids: ..Shader_Id) {
    for id in shaders_ids {
        info := get_shader_info(id)^
        
        // This unusual form of x = bool || x instead of ||= is required so that even if 
        // source returns true, common is still checked and reset if it also needs to be. 
        // Otherwise the compiler will skip the call if the value is already true.
        needs_recompile: bool
        needs_recompile = watcher_check_and_reset(watchers, info.source) || needs_recompile
        needs_recompile = watcher_check_and_reset(watchers, info.common) || needs_recompile
        
        if needs_recompile {
            shader := get_shader(id, immediately = false)
            
            procs, comp, comp_allocator := make_shader_compilation()
            
            input_path  := watchers[info.source].path
            output_path := compile_shader(input_path, procs = procs)
            
            comp^ = {
                false,
                id,
                strings.clone(input_path,  comp_allocator),
                strings.clone(output_path, comp_allocator),
                shader.bytes,
            }
        }
    }
}

////////////////////////////////////////////////

hotreload_shaders_and_recreate_pipelines :: proc (gpu: ^Gpu, watchers: ^Watchers, shaders: Shaders, pipelines: ^Pipelines, frame: ^Frame, render_targets: Render_Targets) {
    profile_procedure()
    {
        profile_scope("recompile shaders")
        // 
        // @todo the work of loading the bytes and parsing them could be moved to a thread. The modified flag 
        // then needs to be expanded into a state { Invalid, Loading, Valid }.
        // The checking itself can also be done on a different thread, and does not need to be done in sync with
        // the renderer frames.
        // 
        // The main thread would then just check if the shader.bytes themselves have been updated by checking a
        // flag and then use the already loaded bytes to recreate the pipeline. The remaining question then is 
        // how often the watchers-thread should check the files, but maybe there already is an asynchronous OS
        // api which then can just be used and we suspend the thread and let the OS wake it when a file was 
        // modified?
        //
        
        watchers_check_files_for_modification(watchers)
        
        recompile_shaders_if_needed(watchers, 
            shaders.culling,
            shaders.meshlet_task, shaders.meshlet_mesh, shaders.meshlet_frag,
            shaders.depth_reduce,
            shaders.ui_vert, shaders.ui_frag,
        )
        
        load_all_compiled_shaders(immediately = false)
    }
    
    reloaded_cull_shader := check_and_reset_shaders_was_modified(shaders.culling)
    for &cull_pipeline, stage in pipelines.culling {
        if !pipeline_is_valid(cull_pipeline) || reloaded_cull_shader {
            immediately := !pipeline_is_valid(cull_pipeline)
            destroy_pipeline(gpu, cull_pipeline)
            
            compute := get_shader(shaders.culling, immediately)
            constants := [] Specialization_Constant { /* late = */ { b = stage != .early }, /* post = */ { b = stage == .post } }
            
            cull_pipeline = gpu_create_compute_pipeline(gpu, compute, constants)
            
            print("Recreated %v cull_pipeline.\n", stage)
            frame.print_profile = true
        }
    }
    
    if !pipeline_is_valid(pipelines.depth_reduce) || check_and_reset_shaders_was_modified(shaders.depth_reduce) {
        immediately := !pipeline_is_valid(pipelines.depth_reduce)
        destroy_pipeline(gpu, pipelines.depth_reduce)
        
        compute := get_shader(shaders.depth_reduce, immediately)
        pipelines.depth_reduce = gpu_create_compute_pipeline(gpu, compute)
        
        print("Recreated depth_pipeline.\n")
        frame.print_profile = true
    }
    
    reloaded_meshlet_shaders := check_and_reset_shaders_was_modified(shaders.meshlet_task, shaders.meshlet_mesh, shaders.meshlet_frag)
    for &meshlet_pipeline, stage in pipelines.meshlets {
        if !pipeline_is_valid(meshlet_pipeline) || reloaded_meshlet_shaders {
            immediately := !pipeline_is_valid(meshlet_pipeline)
            destroy_pipeline(gpu, meshlet_pipeline)
            
            raster_description: Raster_Desc
            raster_description.depth_format = render_targets.depth_format
            raster_description.color_target_formats = { render_targets.color_format }
            raster_description.blendstate = &Blend_Desc{ **DefaultBlendDesc }
            // :Stencil: 
            
            task, mesh, frag := get_shader(shaders.meshlet_task, immediately), get_shader(shaders.meshlet_mesh, immediately), get_shader(shaders.meshlet_frag, immediately)
            constants := [] Specialization_Constant { /* late = */ { b = stage != .early }, /* post = */ { b = stage == .post } }
            
            meshlet_pipeline = gpu_create_graphics_meshlet_pipeline(gpu, task, mesh, frag, raster_description, constants)
            
            print("Recreated %v meshlet_pipeline.\n", stage)
            frame.print_profile = true
        }
    }    
    
    if !pipeline_is_valid(pipelines.ui) || check_and_reset_shaders_was_modified(shaders.ui_vert, shaders.ui_frag) {
        immediately := !pipeline_is_valid(pipelines.ui)
        destroy_pipeline(gpu, pipelines.ui)
        
        raster_description: Raster_Desc
        raster_description.color_target_formats = { render_targets.color_format } // hotreload shader: format
        raster_description.blendstate = &Blend_Desc { **DefaultBlendDesc }
        raster_description.blendstate.src_color_factor = .SRC_ALPHA
        raster_description.blendstate.dst_color_factor = .ONE_MINUS_SRC_ALPHA
        raster_description.blendstate.src_alpha_factor = .ONE
        raster_description.blendstate.dst_alpha_factor = .ONE_MINUS_SRC_ALPHA
        
        vert, frag := get_shader(shaders.ui_vert, immediately), get_shader(shaders.ui_frag, immediately)
        pipelines.ui = gpu_create_graphics_pipeline(gpu, vert, frag, raster_description)
        
        print("Recreated ui_pipeline.\n")
        frame.print_profile = true
    }
}

////////////////////////////////////////////////

print_sdl_error_and_exit :: proc (loc := #caller_location) -> ! {
    print("%v:%v:%v: SDL call returned %v\n", loc.file_path, loc.line, loc.column, sdl.GetError())
    runtime.exit(1)
}