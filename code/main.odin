#+vet explicit-allocators
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import la "core:math/linalg"

import "profiler"

import sdl "vendor:sdl3"
import vk  "../lib/vulkan"

////////////////////////////////////////////////

Optimized :: ODIN_OPTIMIZATION_MODE == .Speed

Validation :: false when Optimized else true

////////////////////////////////////////////////

Geometry :: struct {
    // @todo all this data is not needed on the cpu, we could just directly upload it to the gpu buffers
    vertices:     [dynamic] Vertex,
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
    format: vk.Format,
    memory: vk.DeviceMemory,
    size:   uv3,
    sampled_index: Texture_Index,
    storage_index: Texture_Index,
}

Texture_Index :: distinct u32

Depth_Mip :: struct {
    size: uv2,
    sampled_index: Texture_Index,
    storage_index: Texture_Index,
}

////////////////////////////////////////////////

Cull_Globals :: struct #all_or_none { // :Shader:
    using data: Cull_Data,
    
    draw_buffer:            vk.DeviceAddress "Draw",
    mesh_buffer:            vk.DeviceAddress "Mesh",
    draw_visibility_buffer: vk.DeviceAddress "bool",
    draw_command_buffer:    vk.DeviceAddress "Draw_Command",
    draw_command_count:     vk.DeviceAddress "uint",
    
    depth_pyramid_index: Texture_Index,
}

Cull_Data :: struct #all_or_none { // :Shader:
    view_from_world: m4,
    
    p00, p11, near_z, far_z: f32,
    frustum: [4] f32,
    
    pyramid_size: v2,
    draw_count:   u32,
    flags:        u32,
    
    lod_base: f32,
    lod_step: f32,
    _: v2,
}

// @volatile Cull_Data.flags
DebugFlag_FrustumCulling   :: (1 << 0)
DebugFlag_LevelOfDetail    :: (1 << 1)
DebugFlag_OcclusionCulling :: (1 << 2)

Draw_Globals :: struct #all_or_none { // :Shader:
    using data: Draw_Data,
    
    draw_command_buffer: vk.DeviceAddress "Draw_Command",
    draw_buffer:         vk.DeviceAddress "Draw",
    mesh_buffer:         vk.DeviceAddress "Mesh",
    meshlet_buffer:      vk.DeviceAddress "Meshlet",
    meshlet_data_buffer: vk.DeviceAddress "uint",
    vertex_buffer:       vk.DeviceAddress "Vertex",
}

Draw_Data :: struct { // :Shader:
    view_from_world:  m4,
    screen_from_view: m4,
    light_pos:        [4] v4,
    
    screen_size: v2,
    near_z, far_z: f32,
    frustum: [4] f32,
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

Draw :: struct { // :Shader:
    orientation: q32,
    p:           v3,
    scale:       f32,
    
    mesh_index:    u32,
    vertex_offset: u32,
    texture_index: Texture_Index,
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
}

Draw_Command :: struct { // :Shader:
    draw_id:        u32,
    meshlet_offset: u32,
    meshlet_count:  u32,
    group:          uv3,
}

// @todo do we even need this on the cpu
Task_Command :: struct { // :Shader:
    draw_id:     u32,
    task_offset: u32,
    task_count:  u32,
    late_draw_visibility__meshlet_visibility_offset: u32, // 1 __ 31 bits
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
    p:  v3,      p_pad: f32,
    n:  [3] u8,  n_pad: u8,
    uv: v2,
}

////////////////////////////////////////////////

main :: proc () {
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
    
    debug: struct {
        vsync: bool,
        
        culling_enabled:   bool,
        lod_enabled:       bool,
        occlusion_enabled: bool,
        task_mode:         bool,
        display_pyramid:   bool,
        display_pyramid_mip_level: i32,
        
        cpu_time:  f64,
        gpu_time:  f64,
        early_rendering_time: f64,
        late_rendering_time:  f64,
        early_cull_time: f64,
        late_cull_time:  f64,
    } = {
        vsync = true,
        
        culling_enabled   = true,
        lod_enabled       = true,
        occlusion_enabled = true,
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
    // @speed most of these buffer could be moved to GPU local memory
    cpu_begin_profile_zone("Allocate buffers")
    memory := Memory_Kind.Default
    
    // @todo draws change per frame and could also be placed in the per frame bump allocator, as we just need a gpu address
    // All the geometry data can just live in the gpu
    vertex_buffer          := gpu_allocate(gpu, [] Vertex,  256 * Megabyte / size_of(Vertex),  memory = memory)
    meshlet_buffer         := gpu_allocate(gpu, [] Meshlet, 256 * Megabyte / size_of(Meshlet), memory = memory)
    meshlet_data_buffer    := gpu_allocate(gpu, [] u32,     256 * Megabyte / size_of(u32),     memory = memory)
    mesh_buffer            := gpu_allocate(gpu, [] Mesh,    256 * Megabyte / size_of(Mesh),    memory = memory)
    
    draw_buffer            := gpu_allocate(gpu, [] Draw,    256 * Megabyte / size_of(Draw),    memory = memory)
    draw_visibility_buffer := gpu_allocate(gpu, [] u32,     256 * Megabyte / size_of(u32),     memory = memory, usage = vk.BufferUsageFlags { .STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST })
    
    dvb_cleared := false
    
    cpu_end_profile_zone()
    
    geometry: Geometry
    {
        cpu_scoped_profile_zone("Geometry loading")
        
        paths := [?] string {
            "tutorial/suzanne.obj",
            // "models/bunny.obj",
            // "models/lucy_280k.obj",
        }
        
        for path in paths {
            if !load_mesh(&geometry, path, context.temp_allocator) {
                fmt.eprintfln("Failed to load mesh from file `%v`", path)
            }
        }
        
        copy(vertex_buffer.cpu,       geometry.vertices[:])
        copy(meshlet_buffer.cpu,      geometry.meshlets[:])
        copy(meshlet_data_buffer.cpu, geometry.meshlet_data[:])
        copy(mesh_buffer.cpu,         geometry.meshes[:])
    }
    
    ////////////////////////////////////////////////
    
    cpu_begin_profile_zone("Init shaders")
    watchers := make([dynamic] Watcher, context.allocator)
    
    init_assets(context.allocator)
    
    generate_shader_api("shaders/api.generated.glsl")
    
    // @speed we duplicate this watcher per shader, so that each shader can keep track of the header being changed and be recompiled independently from other shaders, without effecting their modification test.
    meshlet_task_shader := init_shader_and_watchers(&watchers, watchers_make(&watchers, "shaders/common.glsl"), "shaders/meshlet.task")
    meshlet_mesh_shader := init_shader_and_watchers(&watchers, watchers_make(&watchers, "shaders/common.glsl"), "shaders/meshlet.mesh")
    meshlet_frag_shader := init_shader_and_watchers(&watchers, watchers_make(&watchers, "shaders/common.glsl"), "shaders/meshlet.frag")
    cull_shader         := init_shader_and_watchers(&watchers, watchers_make(&watchers, "shaders/common.glsl"), "shaders/cull.comp")
    depth_reduce_shader := init_shader_and_watchers(&watchers, watchers_make(&watchers, "shaders/common.glsl"), "shaders/depth_reduce.comp")
    
    ui_vert_shader := init_shader_and_watchers(&watchers, watchers_make(&watchers, "shaders/common.glsl"), "shaders/ui.vert")
    ui_frag_shader := init_shader_and_watchers(&watchers, watchers_make(&watchers, "shaders/common.glsl"), "shaders/ui.frag")
    
    cpu_end_profile_zone()
    
    ////////////////////////////////////////////////
    
    texture_count :: 3
    textures: [texture_count] Image
    
    descriptor_heap := create_descriptor_heap(gpu)
    
    {
        cpu_scoped_profile_zone("Texture Upload")
        
        upload_bump := bump_allocator_make_temporary(gpu, 256 * Megabyte, usage = { .TRANSFER_SRC })
        defer bump_allocator_delete(gpu, &upload_bump)
        
        cmd := gpu_begin_command_recording(gpu, gpu.transfer_command_pool, gpu.transfer_queue)
        upload_semaphore := gpu_create_timeline_semaphore(gpu, 0)
        defer gpu_destroy_semaphore(gpu, upload_semaphore)
        
        for &texture, index in textures {
            filename := fmt.tprintf("tutorial/suzanne%v.ktx", index)
            
            loaded_texture := load_ktx_texture(filename, context.temp_allocator)
            
            description := default_texture_desc()
            description.size.xy = { loaded_texture.width, loaded_texture.height }
            description.format  = auto_cast loaded_texture.format
            description.usage   = { .TRANSFER_DST, .SAMPLED }
            
            texture = gpu_allocate_texture(gpu, description)
            
            // @waste we should have loaded all data into here if possible
            cpu_data, gpu_data := bump_allocate(&upload_bump, cast(u32) len(loaded_texture.data), alignment = 32)
            copy(cpu_data, loaded_texture.data)
            
            gpu_image_barriers(cmd, {},
                create_image_barrier_from_undefined(&texture, { .ALL_TRANSFER }, { .MEMORY_READ, .MEMORY_WRITE }, .GENERAL),
            )
            
            gpu_copy_to_texture(cmd, texture, gpu_data)
        }
            
        gpu_barrier(cmd, { .ALL_TRANSFER }, { .ALL_GRAPHICS })
        
        gpu_submit(gpu.transfer_queue, { { upload_semaphore, { .ALL_COMMANDS }, 1} }, cmd)
        gpu_wait_semaphore(gpu, upload_semaphore, 1)
     }
    
    ////////////////////////////////////////////////
    
    cpu_begin_profile_zone("Setup other gpu resources")
    
    gpu_profile_init(gpu)
    
    stats_count: u32 = 3
    stats_pool := create_query_pool(gpu, stats_count, .MESH_PRIMITIVES_GENERATED_EXT)
    
    absolute_frame_index: u64
    next_frame := cast(u64) MaxFramesInFlight+1
    frame_semaphore := gpu_create_timeline_semaphore(gpu, MaxFramesInFlight)
    
    cpu_end_profile_zone()
    
    ////////////////////////////////////////////////
    
    cpu_begin_profile_zone("Allocate GPU Bumps")
    frame_bump_allocators: [MaxFramesInFlight] Bump_Allocator
    for &bump in frame_bump_allocators {
        bump = bump_allocator_make_temporary(gpu, 256 * Megabyte, usage = { .STORAGE_BUFFER, .TRANSFER_DST, .INDIRECT_BUFFER })
    }
    
    cpu_end_profile_zone()
    
    ////////////////////////////////////////////////
    
    early_cull_pipeline: Pipeline
    late_cull_pipeline:  Pipeline
    task_early_cull_pipeline: Pipeline
    task_late_cull_pipeline:  Pipeline
    depth_pipeline:      Pipeline
    meshlet_pipeline:    Pipeline
    ui_pipeline:         Pipeline
    
    ////////////////////////////////////////////////
    
    draw_data: Draw_Data
    
    for &pos, index in draw_data.light_pos {
        t := clamp_01_to_range(cast(f32) 0, cast(f32) len(draw_data.light_pos), cast(f32) index)
        pos.xyz = v3{0, 10, 10}
        pos.xz += arm(t * Tau)
    }
    
    cam_pos := v3{ 0, 0, 0}
    object_rotation: v3
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
        @(static) space_down: bool
        
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
                case sdl.K_SPACE: space_down = true
                case sdl.K_C:     debug.culling_enabled   = !debug.culling_enabled
                case sdl.K_L:     debug.lod_enabled       = !debug.lod_enabled
                case sdl.K_O:     debug.occlusion_enabled = !debug.occlusion_enabled
                case sdl.K_P:     debug.display_pyramid   = !debug.display_pyramid
                case sdl.K_T:     debug.task_mode         = !debug.task_mode
                
                case sdl.K_V:     debug.vsync = !debug.vsync; vsync_changed = true
                
                case sdl.K_I:     print_profile_and_stats = true
                
                case sdl.K_PLUS:  debug.display_pyramid_mip_level = clamp(debug.display_pyramid_mip_level+1, 0, cast(i32) len(stuff.depth_pyramid_mips)-1)
                case sdl.K_MINUS: debug.display_pyramid_mip_level = clamp(debug.display_pyramid_mip_level-1, 0, cast(i32) len(stuff.depth_pyramid_mips)-1)
                
                case sdl.K_ESCAPE: quit = true
                }
            case .KEY_UP:
                if event.key.key == sdl.K_SPACE {
                    space_down = false
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
            cam_pos.z += mouse_wheel_delta * -10 * delta_time
        }
        
        if mouse_delta != 0 && left_down {
            if space_down {
                cam_pos.xy += mouse_delta * {-1, 1} * delta_time * 5
            } else {
                object_rotation.yx += mouse_delta * delta_time
            }
        }
        
        ////////////////////////////////////////////////
        
        cpu_begin_profile_zone("Frame Sleep")
        gpu_wait_semaphore(gpu, frame_semaphore, next_frame - MaxFramesInFlight)
        cpu_end_profile_zone()
        
        frame_index := absolute_frame_index % MaxFramesInFlight
        absolute_frame_index += 1
        
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
        recompile_shaders_if_needed(watchers, cull_shader)
        recompile_shaders_if_needed(watchers, depth_reduce_shader)
        recompile_shaders_if_needed(watchers, meshlet_task_shader, meshlet_mesh_shader, meshlet_frag_shader)
        recompile_shaders_if_needed(watchers, ui_vert_shader, ui_frag_shader)
        
        // @todo the work of loading the bytes and parsing them could be moved to a thread. The modified flag then needs to be expanded into a state { Invalid, Loading, Valid }
        load_all_compiled_shaders(immediately = false)
        
        reloaded_cull_shader := test_and_reset_shaders_was_modified(cull_shader)
        
        // @todo put these into some structure that manages all pipelines?
        
        if !pipeline_is_valid(early_cull_pipeline) || reloaded_cull_shader {
            destroy_pipeline(gpu, early_cull_pipeline)
            immediately := !pipeline_is_valid(early_cull_pipeline)
            constants := [] Specialization_Constant { /* late = */ { b = false }, /* task = */ { b = false } }
            early_cull_pipeline = gpu_create_compute_pipeline(gpu, get_shader(cull_shader, immediately), descriptor_heap, constants)
            fmt.printfln("Recreated early_cull_pipeline.")
        }
        
        if !pipeline_is_valid(late_cull_pipeline) || reloaded_cull_shader {
            destroy_pipeline(gpu, late_cull_pipeline)
            immediately := !pipeline_is_valid(late_cull_pipeline)
            constants := [] Specialization_Constant { /* late = */ { b = true }, /* task = */ { b = false } }
            late_cull_pipeline = gpu_create_compute_pipeline(gpu, get_shader(cull_shader, immediately), descriptor_heap, constants)
            fmt.printfln("Recreated late_cull_pipeline.")
        }
        // @copypasta
        if !pipeline_is_valid(task_early_cull_pipeline) || reloaded_cull_shader {
            destroy_pipeline(gpu, task_early_cull_pipeline)
            immediately := !pipeline_is_valid(task_early_cull_pipeline)
            constants := [] Specialization_Constant { /* late = */ { b = false }, /* task = */ { b = true } }
            task_early_cull_pipeline = gpu_create_compute_pipeline(gpu, get_shader(cull_shader, immediately), descriptor_heap, constants)
            fmt.printfln("Recreated early_cull_pipeline.")
        }
        
        if !pipeline_is_valid(task_late_cull_pipeline) || reloaded_cull_shader {
            destroy_pipeline(gpu, task_late_cull_pipeline)
            immediately := !pipeline_is_valid(task_late_cull_pipeline)
            constants := [] Specialization_Constant { /* late = */ { b = true }, /* task = */ { b = true } }
            task_late_cull_pipeline = gpu_create_compute_pipeline(gpu, get_shader(cull_shader, immediately), descriptor_heap, constants)
            fmt.printfln("Recreated task_late_cull_pipeline.")
        }
        
        if !pipeline_is_valid(depth_pipeline) || test_and_reset_shaders_was_modified(depth_reduce_shader) {
            destroy_pipeline(gpu, depth_pipeline)
            immediately := !pipeline_is_valid(depth_pipeline)
            depth_pipeline = gpu_create_compute_pipeline(gpu, get_shader(depth_reduce_shader, immediately), descriptor_heap)
            fmt.printfln("Recreated task_depth_pipeline.")
        }
        
        if !pipeline_is_valid(meshlet_pipeline) || test_and_reset_shaders_was_modified(meshlet_task_shader, meshlet_mesh_shader, meshlet_frag_shader) {
            raster_description := DefaultRasterDesc
            raster_description.depth_format = stuff.depth_buffer.format
            raster_description.color_targets = {
                { format = stuff.color_buffer.format, write_mask = DefaulColorMask },
            }
            raster_description.blendstate = &Blend_Desc{ **DefaultBlendDesc }
            // :Stencil: 
            
            task, mesh, frag := meshlet_task_shader, meshlet_mesh_shader, meshlet_frag_shader
            
            destroy_pipeline(gpu, meshlet_pipeline)
            immediately := !pipeline_is_valid(meshlet_pipeline)
            meshlet_pipeline = gpu_create_graphics_meshlet_pipeline(gpu, get_shader(task, immediately), get_shader(mesh, immediately), get_shader(frag, immediately), raster_description, descriptor_heap)
            fmt.printfln("Recreated meshlet_pipeline.")
        }
        
        if !pipeline_is_valid(ui_pipeline) || test_and_reset_shaders_was_modified(ui_vert_shader, ui_frag_shader) {
            raster_description := DefaultRasterDesc
            raster_description.color_targets = {
                { format = stuff.color_buffer.format, write_mask = DefaulColorMask },
            }
            raster_description.blendstate = &Blend_Desc { **DefaultBlendDesc }
            raster_description.blendstate.src_color_factor = .SRC_ALPHA
            raster_description.blendstate.dst_color_factor = .ONE_MINUS_SRC_ALPHA
            raster_description.blendstate.src_alpha_factor = .ONE
            raster_description.blendstate.dst_alpha_factor = .ONE_MINUS_SRC_ALPHA
            
            destroy_pipeline(gpu, ui_pipeline)
            immediately := !pipeline_is_valid(ui_pipeline)
            ui_pipeline = gpu_create_graphics_pipeline(gpu, get_shader(ui_vert_shader, immediately), get_shader(ui_frag_shader, immediately), raster_description, descriptor_heap)
            fmt.printfln("Recreated ui_pipeline.")
        }
        
        ////////////////////////////////////////////////
        
        frame_descriptor: Frame_Descriptor
        {
            cpu_scoped_profile_zone("Setup Descriptor Heap")
            
            frame_descriptor.descriptor_offset = DescriptorStaticLimit              + auto_cast frame_index * DescriptorPerFrameLimit
            frame_descriptor.descriptor_end    = frame_descriptor.descriptor_offset +                     1 * DescriptorPerFrameLimit
            
            frame_descriptor.descriptor_offset = 0
            {
                // @cleanup who should keep which data, and how often do we actually need to write this (atleast when the swapchain
                // is recreated).
                // @todo add a null texture, which is a bright debug color so that uninitialized indices(0) are easy to find
                write_texture_to_heap(gpu, &descriptor_heap, frame_descriptor.descriptor_offset, textures[0], .SAMPLED_IMAGE)
                textures[0].sampled_index = frame_descriptor.descriptor_offset
                frame_descriptor.descriptor_offset += 1
                
                write_texture_to_heap(gpu, &descriptor_heap, frame_descriptor.descriptor_offset, textures[1], .SAMPLED_IMAGE)
                textures[1].sampled_index = frame_descriptor.descriptor_offset
                frame_descriptor.descriptor_offset += 1
                
                write_texture_to_heap(gpu, &descriptor_heap, frame_descriptor.descriptor_offset, textures[2], .SAMPLED_IMAGE)
                textures[2].sampled_index = frame_descriptor.descriptor_offset
                frame_descriptor.descriptor_offset += 1
                
                write_texture_to_heap(gpu, &descriptor_heap, frame_descriptor.descriptor_offset, stuff.depth_buffer, .SAMPLED_IMAGE)
                stuff.depth_buffer.sampled_index = frame_descriptor.descriptor_offset
                frame_descriptor.descriptor_offset += 1
                
                write_texture_to_heap(gpu, &descriptor_heap, frame_descriptor.descriptor_offset, stuff.depth_pyramid, .SAMPLED_IMAGE)
                stuff.depth_pyramid.sampled_index = frame_descriptor.descriptor_offset
                frame_descriptor.descriptor_offset += 1
                
                write_texture_to_heap(gpu, &descriptor_heap, frame_descriptor.descriptor_offset, stuff.depth_pyramid, .STORAGE_IMAGE)
                stuff.depth_pyramid.storage_index = frame_descriptor.descriptor_offset
                frame_descriptor.descriptor_offset += 1
                
                
                for &mip, mip_level in stuff.depth_pyramid_mips {
                    write_texture_to_heap(gpu, &descriptor_heap, frame_descriptor.descriptor_offset, stuff.depth_pyramid, .SAMPLED_IMAGE, cast(u32) mip_level, 1)
                    mip.sampled_index = frame_descriptor.descriptor_offset
                    frame_descriptor.descriptor_offset += 1
                    
                    write_texture_to_heap(gpu, &descriptor_heap, frame_descriptor.descriptor_offset, stuff.depth_pyramid, .STORAGE_IMAGE, cast(u32) mip_level, 1)
                    mip.storage_index = frame_descriptor.descriptor_offset
                    frame_descriptor.descriptor_offset += 1
                }
            }
        }
        
        draws: [] Draw
        {
            cpu_scoped_profile_zone("Generate Draws")
            entropy := seed_random_series(545114)
            draws = draw_buffer.cpu[:50_000]
            global_rotation := la.quaternion_from_euler_angles_f32(**(object_rotation * random_unilateral(&entropy, v3)), .XYX)
            for &draw in draws {
                p := random_bilateral(&entropy, v3) * {10, 10, 10} + {0, 0, -10}
                
                draw.p           = p
                draw.scale       = linear_blend(cast(f32) .05, .8, power(random_unilateral(&entropy, f32), 8)) / 2
                rotation        := la.quaternion_angle_axis(random_unilateral(&entropy, f32) * Tau, random_bilateral(&entropy, v3))
                draw.orientation = rotation * global_rotation
                
                draw.texture_index = textures[random_between_u32(&entropy, 0, texture_count-1)].sampled_index
                
                mesh, mesh_index := random_choice_index(&entropy, geometry.meshes[:])
                
                draw.mesh_index    = mesh_index
                draw.vertex_offset = mesh.vertex_offset
            }
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
        screen_from_view := projection_reversed_z_infinite_far_plane(70 * RadiansFromDegrees, cast(f32) gpu.swapchain_size.x / cast(f32) gpu.swapchain_size.y, near_z)
        view_from_world  := translate(1, -cam_pos)
        
        // @todo this is in view/camera space make this a distance in world space
        draw_distance: f32 = 1000
        
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
        
        ////////////////////////////////////////////////
        
        cull_data_flags: u32 
        if debug.culling_enabled   { cull_data_flags |= DebugFlag_FrustumCulling   }
        if debug.lod_enabled       { cull_data_flags |= DebugFlag_LevelOfDetail    }
        if debug.occlusion_enabled { cull_data_flags |= DebugFlag_OcclusionCulling }
        cull_data := Cull_Data {
            view_from_world = view_from_world,
            
            p00 = screen_from_view[0,0],
            p11 = screen_from_view[1,1],
            near_z = near_z,
            far_z  = draw_distance,
            
            frustum = frustum,
            
            pyramid_size = cast(v2) stuff.depth_pyramid.size.xy,
            
            draw_count = auto_cast len(draws),
            flags      = cull_data_flags,
            
            lod_base = 10,
            lod_step = 1.5,
        }
        
        draw_data.screen_size = cast(v2) gpu.swapchain_size
        draw_data.near_z = near_z
        draw_data.far_z  = draw_distance
        draw_data.frustum = frustum
        
        draw_data.screen_from_view = screen_from_view
        draw_data.view_from_world  = view_from_world
        
        ////////////////////////////////////////////////
        ////////////////////////////////////////////////
        ////////////////////////////////////////////////
        
        
        cpu_begin_profile_zone("Record command buffer")
        
        check(vk.ResetCommandPool(gpu.device, gpu.command_pools[frame_index], {}))
        // @api expecting the user to pass the frame index is a source for mistakes
        cmd := gpu_begin_command_recording(gpu, gpu.command_pools[frame_index], gpu.general_queue)
        
        gpu_profile_frame_begin(gpu, cmd)
        
        gpu_set_active_heap(cmd, &descriptor_heap)
        
        stats_pool_query_index: u32
        vk.CmdResetQueryPool(cmd, stats_pool, 0, stats_count)
        
        ////////////////////////////////////////////////
        
        gpu_image_barriers(cmd, { .BY_REGION },
            create_image_barrier_from_undefined(&stuff.color_buffer, { .COLOR_ATTACHMENT_OUTPUT, .EARLY_FRAGMENT_TESTS }, { .COLOR_ATTACHMENT_WRITE },         .GENERAL),
            create_image_barrier_from_undefined(&stuff.depth_buffer, { .COLOR_ATTACHMENT_OUTPUT, .EARLY_FRAGMENT_TESTS }, { .DEPTH_STENCIL_ATTACHMENT_WRITE, .MEMORY_READ }, .GENERAL), 
            create_image_barrier_from_undefined(&stuff.depth_pyramid, { .COMPUTE_SHADER }, { .MEMORY_READ, .MEMORY_WRITE }, .GENERAL),
            create_image_barrier_from_undefined(&gpu.swapchain_images[gpu.image_index], { .ALL_TRANSFER }, { .TRANSFER_WRITE }, .GENERAL),
        )
        
        ////////////////////////////////////////////////
        // early cull - frustum cull & fill objects that *were* visible last frame
        
        {
            draw_command_count := bump_allocate_type(bump, u32)
            draw_command := bump_allocate_slice(bump, [] Draw_Command, auto_cast len(draws))
            
            cull_globals := bump_allocate_type(bump, Cull_Globals)
            cull_globals.cpu^ = Cull_Globals {
                draw_buffer            = draw_buffer.gpu.p,
                mesh_buffer            = mesh_buffer.gpu.p,
                draw_visibility_buffer = draw_visibility_buffer.gpu.p,
                draw_command_buffer    = draw_command.gpu.p,
                draw_command_count     = draw_command_count.gpu.p,
                
                depth_pyramid_index = stuff.depth_pyramid.sampled_index,
                
                data = cull_data,
            }
            
            draw_globals := bump_allocate_type(bump, Draw_Globals)
            draw_globals.cpu^ = Draw_Globals {
                data = draw_data,
                
                draw_command_buffer = draw_command.gpu.p,
                draw_buffer         = draw_buffer.gpu.p,
                mesh_buffer         = mesh_buffer.gpu.p,
                meshlet_buffer      = meshlet_buffer.gpu.p,
                meshlet_data_buffer = meshlet_data_buffer.gpu.p,
                vertex_buffer       = vertex_buffer.gpu.p,
            }
            
            max_draw_count := cast(u32) len(draws)
            culling_begin(cmd, early = true)
                
                if !dvb_cleared {
                    dvb_cleared = true
                    gpu_fill_memory(cmd, draw_visibility_buffer, max_draw_count, 1)
                }
            
            if debug.task_mode {
                culling_end(cmd, task_early_cull_pipeline, cull_shader, &frame_descriptor, cull_globals, draw_command_count, max_draw_count, early = true)
            } else {
                culling_end(cmd, early_cull_pipeline, cull_shader, &frame_descriptor, cull_globals, draw_command_count, max_draw_count, early = true)
            }
            
            ////////////////////////////////////////////////
            // early render - render objects that were visible last frame
            
            gpu_barrier(cmd, { .BOTTOM_OF_PIPE, .COMPUTE_SHADER }, { .DRAW_INDIRECT, .PRE_RASTERIZATION_SHADERS })
            
            begin_meshlet_rendering(gpu, cmd, &stuff, {0.07, 0.07, 0.07, 1}, early = true)
                
                gpu_set_viewport(cmd, size = cast(v2) gpu.swapchain_size)
                gpu_set_scissor(cmd,  size = gpu.swapchain_size)
                
                vk.CmdBeginQuery(cmd, stats_pool, stats_pool_query_index, {})
                
                gpu_set_pipeline(cmd, meshlet_pipeline)
                if debug.task_mode {
                    
                } else {
                    gpu_draw_meshlets_indirect_count(cmd, &frame_descriptor,
                        draw_command.gpu, draw_command_count.gpu,
                        auto_cast len(draws), offset_of(Draw_Command, group),
                        draw_globals.gpu,
                    )
                }
                
                vk.CmdEndQuery(cmd, stats_pool, stats_pool_query_index)
                stats_pool_query_index += 1
                
            end_meshlet_rendering(cmd)
        }
        
        ////////////////////////////////////////////////
        // depth pyramid generation
        
        {
            gpu_profile_zone_begin("depth pyramid building")
            gpu_labeled_region_begin(cmd, "depth pyramid building", {0.4, 0.8, 0, 1.0})
            
            gpu_barrier(cmd, { .LATE_FRAGMENT_TESTS }, { .COMPUTE_SHADER })
            
            gpu_set_pipeline(cmd, depth_pipeline)
            
            for mip, mip_level in stuff.depth_pyramid_mips {
                depth_globals := bump_allocate_type(bump, Depth_Data)
                depth_globals.cpu^ = Depth_Data { 
                    size = cast(v2) mip.size,
                }
                if mip_level == 0 {
                    depth_globals.cpu.input_index  = stuff.depth_buffer.sampled_index
                    depth_globals.cpu.output_index = stuff.depth_pyramid.storage_index
                } else if mip_level == 1 {
                    depth_globals.cpu.input_index  = stuff.depth_pyramid.sampled_index
                    depth_globals.cpu.output_index = mip.storage_index
                } else {
                    depth_globals.cpu.input_index  = stuff.depth_pyramid_mips[mip_level-1].sampled_index
                    depth_globals.cpu.output_index = mip.storage_index
                }
                
                gpu_dispatch(cmd, &frame_descriptor, depth_globals.gpu, get_group_count(get_shader(depth_reduce_shader), **mip.size))
                
                gpu_barrier(cmd, { .COMPUTE_SHADER }, { .COMPUTE_SHADER })
            }
            
            gpu_barrier(cmd, { .COMPUTE_SHADER }, { .EARLY_FRAGMENT_TESTS })
            
            gpu_labeled_region_end(cmd)
            gpu_profile_zone_end()
        }
        
        ////////////////////////////////////////////////
        // late cull - frustum & occlusion cull & fill objects that were *not* visible last frame
        
        {
            // @todo these dont need to be cpu visible if that would improve performance 
            // @todo Now that each cull+render pass has its own data instead of sharing it, the memory usage has doubled in the worst case.
            // But atleast this avoids needing to predeclare these two buffers and ensuring barriers and clears are correctly setup before reuse.
            // We cannot clear the bump allocator in between passes to reuse the memory after the first pass is done, as that is asynchronous.
            // 
            // We now dont need to synchronize between the first and the second cull dispatch, as they can fill different buffers.
            // 
            // In general it seems the bump allocator is great for push data/uniforms per shader/pipeline. But the command and count buffers
            // do actually share a lifetime and are specifically used in *all* indirect draw calls. Maybe instead of moving them into the bump
            // they should have been unified with indirect draw calls, so that any further call can just also make use of them. That would 
            // require any pair of indirect draw calls to be serialized and not parallel, but as long as both draw into the same color/depth 
            // buffers that should already be the case.
            // On the other hand with this arrangement we have two disjoint buffer pairs, and can therefore overlap the second filling of the 
            // command data with the creation or drawing of the first, as long as there are no other dependencies between them.
            
            draw_command_count := bump_allocate_type(bump, u32)
            draw_command       := bump_allocate_slice(bump, [] Draw_Command, auto_cast len(draws))
            
            cull_globals := bump_allocate_type(bump, Cull_Globals)
            cull_globals.cpu^ = Cull_Globals {
                draw_buffer            = draw_buffer.gpu.p,
                mesh_buffer            = mesh_buffer.gpu.p,
                draw_visibility_buffer = draw_visibility_buffer.gpu.p,
                draw_command_buffer    = draw_command.gpu.p,
                draw_command_count     = draw_command_count.gpu.p,
                
                depth_pyramid_index = stuff.depth_pyramid.sampled_index,
                
                data = cull_data,
            }
            
            draw_globals := bump_allocate_type(bump, Draw_Globals)
            draw_globals.cpu^ = Draw_Globals {
                data = draw_data,
                
                draw_command_buffer = draw_command.gpu.p,
                draw_buffer         = draw_buffer.gpu.p,
                mesh_buffer         = mesh_buffer.gpu.p,
                meshlet_buffer      = meshlet_buffer.gpu.p,
                meshlet_data_buffer = meshlet_data_buffer.gpu.p,
                vertex_buffer       = vertex_buffer.gpu.p,
            }
            
            culling_begin(cmd, early = false)
            if debug.task_mode {
                culling_end(cmd, task_late_cull_pipeline, cull_shader, &frame_descriptor, cull_globals, draw_command_count, cast(u32) len(draws), early = false)
            } else {
                culling_end(cmd, late_cull_pipeline, cull_shader, &frame_descriptor, cull_globals, draw_command_count, cast(u32) len(draws), early = false)
            }
            
            ////////////////////////////////////////////////
            // late rendering - render objects that are visible this frame but weren't drawn in the early pass
            
            gpu_barrier(cmd, 
                { .COLOR_ATTACHMENT_OUTPUT, .LATE_FRAGMENT_TESTS,  .COMPUTE_SHADER }, 
                { .COLOR_ATTACHMENT_OUTPUT, .EARLY_FRAGMENT_TESTS, .DRAW_INDIRECT, .PRE_RASTERIZATION_SHADERS },
            )
            
            begin_meshlet_rendering(gpu, cmd, &stuff, {}, early = false)
                
                gpu_set_viewport(cmd, size = cast(v2) gpu.swapchain_size)
                gpu_set_scissor(cmd,  size = gpu.swapchain_size)
                
                vk.CmdBeginQuery(cmd, stats_pool, stats_pool_query_index, {})
                
                gpu_set_pipeline(cmd, meshlet_pipeline)
                if debug.task_mode {
                    
                } else {
                    gpu_draw_meshlets_indirect_count(cmd, &frame_descriptor,
                        draw_command.gpu, draw_command_count.gpu, 
                        auto_cast len(draws), offset_of(Draw_Command, group),
                        draw_globals.gpu,
                    )
                }
                
                vk.CmdEndQuery(cmd, stats_pool, stats_pool_query_index)
                stats_pool_query_index += 1
                    
            end_meshlet_rendering(cmd)
        }
        
        ////////////////////////////////////////////////
        // UI pass
        
        {
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
            
            ui_draws := bump_allocate_slice(bump, [] UI_Draw, 2)
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
            
            ui_globals := bump_allocate_type(bump, UI_Data)
            ui_globals.cpu^ = {
                draw_buffer = ui_draws.gpu.p,
                screen_size = cast(v2) gpu.swapchain_size,
                mouse_p = mouse_p,
            }
            
            ui_draw_command := bump_allocate_type(bump, UI_Draw_Command)
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
                
                gpu_set_pipeline(cmd, ui_pipeline)
                gpu_draw_indirect(cmd, &frame_descriptor, ui_draw_command.gpu, ui_globals.gpu)
                
            gpu_end_rendering(cmd)
        }
        
        
        ////////////////////////////////////////////////
        
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
        
        {
            cpu_scoped_profile_zone("GPU profiling")
            
            triangle_count: u64
            if absolute_frame_index >= MaxFramesInFlight {
                cpu_scoped_profile_zone("collect and print shader stats")
                
                stats_result: [128] u64
                size := cast(int) size_of_slice(stats_result[:])
                // @speed we should really not wait for these, as that obviously effects timing measurements
                check(vk.GetQueryPoolResults(gpu.device, stats_pool, 0, 1, size, &stats_result[0], size_of(stats_result[0]), { ._64, .WAIT }))
                
                for i in 0..<stats_pool_query_index {
                    triangle_count += stats_result[i]
                }
            }
            
            gpu_profile_collate_times(gpu, print_profile_and_stats)
            
            gpu_delta             := gpu_profile_get_zone_duration(gpu, "Frame")
            early_rendering_delta := gpu_profile_get_zone_duration(gpu, "early rendering pass")
            late_rendering_delta  := gpu_profile_get_zone_duration(gpu, "late rendering pass")
            early_cull_delta      := gpu_profile_get_zone_duration(gpu, "early culling")
            late_cull_delta       := gpu_profile_get_zone_duration(gpu, "late culling")
            
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
                cpu_procedure_profile_zone()
                return time.duration_round(cast(time.Duration) (seconds * cast(f64) time.Second), 1 * time.Microsecond)
            }
            
            cpu_begin_profile_zone("Update window title")
            sb := strings.builder_make(context.temp_allocator)
            fmt.sbprintf(&sb, "cpu: %.3v, gpu: %.3v, %v tri/s, culling: early %.3v / late %.3v, rendering: early %.3v / late %.3v", 
                view(debug.cpu_time), view(debug.gpu_time), 
                view_magnitude(cast(u64) (cast(f64) triangle_count / debug.gpu_time), kind = .Count),
                view(debug.early_cull_time), view(debug.late_cull_time),
                view(debug.early_rendering_time), view(debug.late_rendering_time),
            )
            fmt.sbprintf(&sb, ", Features: ")
            if debug.vsync {
                fmt.sbprintf(&sb, "VSync ")
            }
            if debug.task_mode {
                fmt.sbprintf(&sb, "Task_Mode ")
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
        
        cpu_end_profile_zone()
        
        if print_profile_and_stats {
            zones := the_cpu_profile_zones
            
            fmt.printfln("---------------------\nCPU profile:")
            root := zones[0]
            total_time := profiler.clocks_to_seconds(root.duration_with_children)
            link: u32
            for {
                zone := zones[link]
                depth := zone.depth_of_the_event
                
                seconds               := profiler.clocks_to_seconds(zone.duration)
                seconds_with_children := profiler.clocks_to_seconds(zone.duration_with_children)
                
                xx :: proc (seconds: f64) -> time.Duration { return cast(time.Duration) (seconds * cast(f64) time.Second) }
                
                fmt.printf("  %v", view_percentage(seconds_with_children/total_time))
                for _ in 0..<depth { fmt.printf("    ") }
                fmt.printf(" %v", xx(seconds))
                if zone.duration_with_children != zone.duration {
                    fmt.printf(" (with children %v)", xx(seconds_with_children))
                }
                fmt.printf(" - %v", zone.name)
                fmt.printfln("")
                
                link = zone.depth_next_event
                if link == 0 { break }
            }
        }
    }
    
    ////////////////////////////////////////////////
    // Cleanup and Shutdown
    
	check(vk.DeviceWaitIdle(gpu.device))
    
    gpu_free(gpu, vertex_buffer)
    gpu_free(gpu, meshlet_buffer)
    gpu_free(gpu, meshlet_data_buffer)
    gpu_free(gpu, mesh_buffer)
    gpu_free(gpu, draw_buffer)
    gpu_free(gpu, draw_visibility_buffer)
    
    for &bump in frame_bump_allocators {
        bump_allocator_delete(gpu, &bump)
    }
    
    destroy_pipeline(gpu, meshlet_pipeline)
    destroy_pipeline(gpu, early_cull_pipeline)
    destroy_pipeline(gpu, late_cull_pipeline)
    destroy_pipeline(gpu, task_early_cull_pipeline)
    destroy_pipeline(gpu, task_late_cull_pipeline)
    destroy_pipeline(gpu, depth_pipeline)
    destroy_pipeline(gpu, ui_pipeline)
    
    for texture in textures {
        gpu_free_image(gpu, texture)
    }
    
    destroy_descriptor_heap(gpu, descriptor_heap)
    
    destroy_stuff(gpu, &stuff)
    
    vk.DestroySemaphore(gpu.device, frame_semaphore, nil)
    vk.DestroyQueryPool(gpu.device, stats_pool, nil)
    vk.DestroyQueryPool(gpu.device, the_gpu_profiler.pool, nil)
    
    gpu_deinit(gpu)
}

////////////////////////////////////////////////

the_cpu_profiler: ^profiler.Event_Table

cpu_begin_profile_zone :: proc (name: string) {
    profiler.record_event(the_cpu_profiler, read_cycle_counter(), .BeginZone, name)
}
cpu_end_profile_zone :: proc () {
    profiler.record_event(the_cpu_profiler, read_cycle_counter(), .EndZone, "")
}

@(deferred_in=cpu_end_scoped_profile_zone)
cpu_scoped_profile_zone :: proc (name: string) {
    profiler.record_event(the_cpu_profiler, read_cycle_counter(), .BeginZone, name)
}

cpu_end_scoped_profile_zone :: proc (_: string) {
    profiler.record_event(the_cpu_profiler, read_cycle_counter(), .EndZone, "")
}

@(deferred_in=_cpu_procedure_end_profile_zone)
cpu_procedure_profile_zone :: proc (loc := #caller_location) {
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

begin_meshlet_rendering :: proc (gpu: ^Gpu, cmd: vk.CommandBuffer, stuff: ^Render_Targets_And_Stuff, clear_color: v4, early: bool) {
    desc: Render_Pass_Desc
    desc.color_targets = { { 
        texture     = stuff.color_buffer,
        view        = stuff.color_view,
        load_op     = early ? .CLEAR : .LOAD,
        store_op    = .STORE,
        clear_color = clear_color,
    } }
    desc.depth_target  = { // :ViewSpace: 0 is the maximal depth value
        texture     = stuff.depth_buffer,
        view        = stuff.depth_view,
        load_op     = early ? .CLEAR : .LOAD,
        store_op    = early ? .STORE : .DONT_CARE,
        clear_depth = 0,
    }
    
    if early {
        gpu_profile_zone_begin("early rendering pass")
        gpu_labeled_region_begin(cmd, "early rendering pass", {0.6, 0.1, 07, 1.0})
    } else {
        gpu_profile_zone_begin("late rendering pass")
        gpu_labeled_region_begin(cmd, "late rendering pass", {0.6, 0.1, 07, 1.0})
    }
    gpu_begin_rendering(gpu, cmd, desc)
    // ...
}

end_meshlet_rendering :: proc (cmd: vk.CommandBuffer) {
    // ...
    gpu_end_rendering(cmd)
    gpu_labeled_region_end(cmd)
    gpu_profile_zone_end()
}

culling_begin :: proc (cmd: vk.CommandBuffer, early: bool) {
    label: cstring = early ? "early culling" : "late_culling"
    before_fill := vk.PipelineStageFlags2 { .DRAW_INDIRECT }
    if !early {
        before_fill += { .PRE_RASTERIZATION_SHADERS }
    }
    
    gpu_labeled_region_begin(cmd, label, {0.0, 0.6, 0.8, 1.0})
    gpu_profile_zone_begin(cast(string) label)
        gpu_barrier(cmd, before_fill, { .ALL_TRANSFER })
        // ...
}

culling_end :: proc (cmd: vk.CommandBuffer, cull_pipeline: Pipeline, cull_shader: Shader_Id, frame_descriptor: ^Frame_Descriptor, cull_globals: Gpu_Address(Cull_Globals), draw_command_count: Gpu_Address(u32), max_draw_count: u32, early: bool) {
    
    before_dispatch := vk.PipelineStageFlags2 { .ALL_TRANSFER  }
    if !early {
        before_dispatch += { .COMPUTE_SHADER } // depth pyramid
    }
    
        // ...
        gpu_fill_memory(cmd, draw_command_count.gpu, 0)
        
        gpu_barrier(cmd, before_dispatch, { .COMPUTE_SHADER })
        
        gpu_set_pipeline(cmd, cull_pipeline)
        gpu_dispatch(cmd, frame_descriptor, cull_globals.gpu, get_group_count(get_shader(cull_shader), max_draw_count))
        
    gpu_profile_zone_end()
    gpu_labeled_region_end(cmd)
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
    stuff.color_buffer  = gpu_allocate_texture(gpu, default_texture_desc(size = {gpu.swapchain_size.x, gpu.swapchain_size.y, 1}, format = gpu.swapchain_format,      usage = { .COLOR_ATTACHMENT, .TRANSFER_SRC }))
    
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
    fmt.printf("%v:%v:%v: SDL call returned %v", loc.file_path, loc.line, loc.column, sdl.GetError())
    os.exit(1)
}