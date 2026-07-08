#+vet explicit-allocators
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import la "core:math/linalg"

import sdl "vendor:sdl3"
import vk  "../lib/vulkan"

////////////////////////////////////////////////

Optimized :: ODIN_OPTIMIZATION_MODE == .Speed

// @todo make this runtime changeable
// @todo disabling VSync produces a validation error, that we wont see if optimizations are enabled, as those disable validation
VSync      :: false when Optimized else true
Validation :: false when Optimized else true

////////////////////////////////////////////////

Geometry :: struct {
    // @todo(viktor): all this data is not needed on the cpu, we could just directly upload it to the gpu buffers
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

// @shader meshlet.mesh
MaxVertices  :: 64
MaxTriangles :: 84

// @shader cull.comp
Cull_Globals :: struct #all_or_none {
    using data: Cull_Data,
    
    draw_buffer:            vk.DeviceAddress "Draw",
    mesh_buffer:            vk.DeviceAddress "Mesh",
    draw_visibility_buffer: vk.DeviceAddress "uint",
    draw_command_buffer:    vk.DeviceAddress "Draw_Command",
    draw_command_count:     vk.DeviceAddress "uint",
    
    depth_pyramid_index: Texture_Index,
}

// @shader
Cull_Data :: struct #all_or_none {
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

// @shader
Draw_Globals :: struct #all_or_none {
    using data: Draw_Data,
    
    draw_command_buffer: vk.DeviceAddress "Draw_Command",
    draw_buffer:         vk.DeviceAddress "Draw",
    mesh_buffer:         vk.DeviceAddress "Mesh",
    meshlet_buffer:      vk.DeviceAddress "Meshlet",
    meshlet_data_buffer: vk.DeviceAddress "uint",
    vertex_buffer:       vk.DeviceAddress "Vertex",
}

// @shader
Draw_Data :: struct {
    view_from_world:  m4,
    screen_from_view: m4,
    light_pos:        [4] v4,
    
    screen_size: v2,
    near_z, far_z: f32,
    frustum: [4] f32,
}


// @shader
Depth_Data :: struct {
    size: v2,
    input_index:  Texture_Index,
    output_index: Texture_Index,
}

// @shader
Draw :: struct {
    orientation: q32,
    p:           v3,
    scale:       f32,
    
    mesh_index:    u32,
    vertex_offset: u32,
    texture_index: Texture_Index,
}

// @shader
Mesh :: struct {
    center: v3,
    radius: f32,
    
    vertex_offset: u32,
    vertex_count:  u32,
    
    lod_count: u32,
    lods:      [8] Mesh_LOD,
}

// @shader
Mesh_LOD :: struct {
    meshlet_offset: u32,
    meshlet_count:  u32,
}

// @shader
Draw_Command :: struct {
    draw_id:        u32,
    meshlet_offset: u32,
    meshlet_count:  u32,
    command:        vk.DrawMeshTasksIndirectCommandEXT,
}

// @shader
Meshlet :: struct {
    center: v3,
    radius: f32,
    cone_axis:   [3] i8,
    cone_cutoff: i8,
    
    data_offset:    u32, // [data_offset:][:vertexcount]
    vertex_count:   u8,
    triangle_count: u8,
}

// @shader
Vertex :: struct {
    p:  v3,      p_pad: f32,
    n:  [3] u8,  n_pad: u8,
    uv: v2,
}

////////////////////////////////////////////////

main :: proc () {
    if !sdl.InitSubSystem({ .VIDEO }) { print_sdl_error_and_exit() }
    defer sdl.Quit()
    defer sdl.QuitSubSystem({ .VIDEO })
    
    window := sdl.CreateWindow("Vulkan Renderer", 1280, 720, sdl.WINDOW_VULKAN | sdl.WINDOW_RESIZABLE)
    if window == nil { print_sdl_error_and_exit () }
    defer sdl.DestroyWindow(window)
    
    ////////////////////////////////////////////////
    
    init_os_metrics()
    
    gpu := gpu_init(window)
    
    stuff: Render_Targets_And_Stuff
    stuff.depth_buffer.format = .D32_SFLOAT
    recreate_stuff(&gpu, &stuff)
    
    ////////////////////////////////////////////////
    // @speed most of these buffer could be move the GPU local memory
    // 200.000 suzannes: Default = 38.3 ms | GPU = 35.5 ms
    memory := Memory_Kind.Default
    
    // @todo(viktor): draws change per frame and could also be placed in the per frame bump allocator, as we just need a gpu address
    // All the geometry data can just live in the gpu
    vb_view,  vertex_buffer          := gpu_allocate(&gpu, [] Vertex,  256 * Megabyte / size_of(Vertex),  memory = memory)
    mlb_view, meshlet_buffer         := gpu_allocate(&gpu, [] Meshlet, 256 * Megabyte / size_of(Meshlet), memory = memory)
    mdb_view, meshlet_data_buffer    := gpu_allocate(&gpu, [] u32,     256 * Megabyte / size_of(u32),     memory = memory)
    mb_view,  mesh_buffer            := gpu_allocate(&gpu, [] Mesh,    256 * Megabyte / size_of(Mesh),    memory = memory)
    
    db_view,  draw_buffer            := gpu_allocate(&gpu, [] Draw,    256 * Megabyte / size_of(Draw),    memory = memory)
    dvb_view, draw_visibility_buffer := gpu_allocate(&gpu, [] u32,     256 * Megabyte / size_of(u32),     memory = memory, usage = vk.BufferUsageFlags { .STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST })
    
    dvb_cleared := false
    
    // @todo(viktor): this signifies that we dont need these to be cpu-visible memory
    unused(dvb_view)
    
    geometry: Geometry
    {
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
        
        copy(vb_view,  geometry.vertices[:])
        copy(mlb_view, geometry.meshlets[:])
        copy(mdb_view, geometry.meshlet_data[:])
        copy(mb_view,  geometry.meshes[:])
    }
    
    ////////////////////////////////////////////////
    
    generate_shader_api("shaders/api.generated.glsl")
    
    shader_allocator := context.allocator
    
    watcher_allocator := context.allocator
    watchers := make([dynamic] Watcher, watcher_allocator)
    
    
    // @speed we duplicate this watcher per shader, so that each shader can keep track of the header being changed and be recompiled independently from other shaders, without effecting their modification test.
    meshlet_task_shader := init_shader_and_watchers(&watchers, watchers_make(&watchers, "shaders/common.glsl"), "shaders/meshlet.task",   shader_allocator)
    meshlet_mesh_shader := init_shader_and_watchers(&watchers, watchers_make(&watchers, "shaders/common.glsl"), "shaders/meshlet.mesh",   shader_allocator)
    meshlet_frag_shader := init_shader_and_watchers(&watchers, watchers_make(&watchers, "shaders/common.glsl"), "shaders/meshlet.frag",   shader_allocator)
    cull_shader   := init_shader_and_watchers(&watchers, watchers_make(&watchers, "shaders/common.glsl"), "shaders/cull.comp",   shader_allocator)
    depth_reduce_shader := init_shader_and_watchers(&watchers, watchers_make(&watchers, "shaders/common.glsl"), "shaders/depth_reduce.comp", shader_allocator)
    
    ////////////////////////////////////////////////
    
    texture_count :: 3
    textures: [texture_count] Image
    
    descriptor_heap := create_descriptor_heap(&gpu)
    
    {
        upload_bump := bump_allocator_make_temporary(&gpu, 256 * Megabyte, usage = { .TRANSFER_SRC })
        defer bump_allocator_delete(&gpu, &upload_bump)
        
        cmd := gpu_begin_command_recording(&gpu, gpu.transfer_command_pool, gpu.transfer_queue)
        upload_semaphore := gpu_create_timeline_semaphore(&gpu, 0)
        defer gpu_destroy_semaphore(&gpu, upload_semaphore)
        
        for &texture, index in textures {
            filename := fmt.tprintf("tutorial/suzanne%v.ktx", index)
            
            loaded_texture := load_ktx_texture(filename, context.temp_allocator)
            
            description := default_texture_desc()
            description.size.xy = { loaded_texture.width, loaded_texture.height }
            description.format  = auto_cast loaded_texture.format
            description.usage   = { .TRANSFER_DST, .SAMPLED }
            
            texture = gpu_allocate_texture(&gpu, description)
            
            // @waste we should have loaded all data into here if possible
            cpu_data, gpu_data := bump_allocate(&upload_bump, cast(u32) len(loaded_texture.data), alignment = 32)
            copy(cpu_data, loaded_texture.data)
            
            gpu_image_barriers(cmd, {},
                create_image_barrier_from_undefined(&texture, { .ALL_TRANSFER }, { .MEMORY_READ, .MEMORY_WRITE }, .GENERAL),
            )
            
            gpu_copy_to_texture(cmd, texture, gpu_data)
        }
            
        gpu_barrier(cmd, { .ALL_TRANSFER }, { .ALL_GRAPHICS })
        
        gpu_submit(gpu.transfer_queue, upload_semaphore, 1, cmd)
        gpu_wait_semaphore(&gpu, upload_semaphore, 1)
    }
    
    ////////////////////////////////////////////////
    
    gpu_profile_init(&gpu)
    
    ////////////////////////////////////////////////
    
    stats_pool: vk.QueryPool
    stats_count: u32
    {
        stats_bits := vk.QueryPipelineStatisticFlags {
            .FRAGMENT_SHADER_INVOCATIONS,
            .COMPUTE_SHADER_INVOCATIONS,
            .TASK_SHADER_INVOCATIONS_EXT,
            .MESH_SHADER_INVOCATIONS_EXT,
        }
        stats_count = cast(u32) card(stats_bits)
        StatsSize :: 1
        create_info := vk.QueryPoolCreateInfo {
            sType = .QUERY_POOL_CREATE_INFO,
            queryType          = .PIPELINE_STATISTICS,
            pipelineStatistics = stats_bits,
            queryCount         = stats_count,
        }
        check(vk.CreateQueryPool(gpu.device, &create_info, nil, &stats_pool))
    }
    
    ////////////////////////////////////////////////
    
    early_cull_pipeline: Pipeline
    late_cull_pipeline:  Pipeline
    depth_pipeline:      Pipeline
    meshlet_pipeline:    Pipeline
    
    ////////////////////////////////////////////////
    
    absolute_frame_index: u64
    next_frame := cast(u64) MaxFramesInFlight+1
    frame_semaphore := gpu_create_timeline_semaphore(&gpu, MaxFramesInFlight)
    
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
    
    debug: struct {
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
    } = {
        culling_enabled = true,
        lod_enabled     = true,
    }
    
    // @correctness ensure that this is enough and that we did not overflow inside of a frame and override someone elses data for a shader
    frame_bump_allocators: [MaxFramesInFlight] Bump_Allocator
    for &bump in frame_bump_allocators {
        bump = bump_allocator_make_temporary(&gpu, 256 * Megabyte, usage = { .STORAGE_BUFFER, .TRANSFER_DST, .INDIRECT_BUFFER })
    }
    
    the_cpu_profiler = new(Profile_Event_Table, context.allocator)
    the_cpu_profile_zones := make([dynamic] Profile_Zone, context.allocator)
    set_recording(the_cpu_profiler, true)
    
    for !quit {
        free_all(context.temp_allocator)
        
        events := swap_active_array_and_get_events(the_cpu_profiler)
        collate_events(events, &the_cpu_profile_zones, nil)
        
        cpu_begin_profile_zone("Frame")
        
        ////////////////////////////////////////////////
        
        // @speed similarly the timestamps should only be collected if we need them. As we currently only look at the last rendered frame, we should only take them if we then also print them. In the future we may want to store more than one frame, but for now this would be better.
        print_profile_and_stats: bool
        
        mouse_delta: v2
        mouse_wheel_delta: f32
        @(static) left_down: bool
        @(static) space_down: bool
        
        cpu_begin_profile_zone("Input Events")
        
        window_event_begin := time.tick_now()
        for event: sdl.Event; sdl.PollEvent(&event); {
            #partial switch event.type {
            case .QUIT:
                quit = true
            
            case .MOUSE_MOTION:
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
        
        // Though we do not track the time, *we* take to handle the input, we also exclude all time taken by sdl and windows(which may block) with this
        current_time  := time.tick_now()
        delta_tick    := time.tick_diff(last_time, current_time)
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
        gpu_wait_semaphore(&gpu, frame_semaphore, next_frame - MaxFramesInFlight)
        cpu_end_profile_zone()
        
        frame_index := absolute_frame_index % MaxFramesInFlight
        absolute_frame_index += 1
        
        if gpu_recreate_swapchain_if_needed(&gpu) {
            ok := get_next_image(&gpu, frame_semaphore, frame_index)
            assert(ok)
        }
        
        // @cleanup this signals that we need to transition all images in stuff from .UNDEFINED to .GENERAL image layout
        if gpu.swapchain_state == .Was_Resized {
            gpu.swapchain_state = .Ok
            recreate_stuff(&gpu, &stuff)
        }
        
        assert(gpu.swapchain_state != .Dirty)
        
        if gpu.swapchain_state == .Window_Is_Minimized { continue }
        
        bump := &frame_bump_allocators[frame_index]
        bump_free_all(bump)
        
        ////////////////////////////////////////////////
        
        watchers_check_for_modification(watchers)
        
        reloaded_cull_shader := reload_shaders_if_needed(watchers, shader_allocator, &cull_shader)
        if reloaded_cull_shader || !pipeline_is_valid(early_cull_pipeline) {
            destroy_pipeline(&gpu, early_cull_pipeline)
            early_cull_pipeline = gpu_create_compute_pipeline(&gpu, cull_shader, descriptor_heap.resource_size, descriptor_heap.sampler_size, constants = { /* late = */ transmute(i32) cast(b32) false }, sampler_hack_names = {"", "depth_sampler"})
            fmt.printfln("Recreated early_cull_pipeline.")
        }
        
        if reloaded_cull_shader || !pipeline_is_valid(late_cull_pipeline) {
            destroy_pipeline(&gpu, late_cull_pipeline)
            late_cull_pipeline = gpu_create_compute_pipeline(&gpu, cull_shader, descriptor_heap.resource_size, descriptor_heap.sampler_size, constants = { /* late = */ transmute(i32) cast(b32) true }, sampler_hack_names = {"", "depth_sampler"})
            fmt.printfln("Recreated late_cull_pipeline.")
        }
        
        if reload_shaders_if_needed(watchers, shader_allocator, &depth_reduce_shader) || !pipeline_is_valid(depth_pipeline) {
            destroy_pipeline(&gpu, depth_pipeline)
            depth_pipeline = gpu_create_compute_pipeline(&gpu, depth_reduce_shader, descriptor_heap.resource_size, descriptor_heap.sampler_size, sampler_hack_names = {"", "depth_sampler", ""})
            fmt.printfln("Recreated depth_pipeline.")
        }
        
        if reload_shaders_if_needed(watchers, shader_allocator, &meshlet_task_shader, &meshlet_mesh_shader, &meshlet_frag_shader) || !pipeline_is_valid(meshlet_pipeline) {
            raster_description := DefaultRasterDesc
            raster_description.depth_format = stuff.depth_buffer.format
            raster_description.color_targets = {
                { format = stuff.color_buffer.format, write_mask = { .R, .G, .B, .A } },
            }
            raster_description.blendstate = &Blend_Desc{ **DefaultBlendDesc }
            // raster_description.blendstate.dst_color_factor = .ONE
            // :Stencil: 
            
            task, mesh, frag := meshlet_task_shader, meshlet_mesh_shader, meshlet_frag_shader
            
            destroy_pipeline(&gpu, meshlet_pipeline)
            meshlet_pipeline = gpu_create_graphics_meshlet_pipeline(&gpu, task, mesh, frag, raster_description, descriptor_heap.resource_size, descriptor_heap.sampler_size, sampler_hack_names = {"texture_sampler", "", "", ""})
            fmt.printfln("Recreated meshlet_pipeline.")
        }
        
        ////////////////////////////////////////////////
        
        cpu_begin_profile_zone("Setup Descriptor Heap")
        frame_descriptor: Frame_Descriptor
        frame_descriptor.descriptor_offset = DescriptorStaticLimit              + auto_cast frame_index * DescriptorPerFrameLimit
        frame_descriptor.descriptor_end    = frame_descriptor.descriptor_offset +                     1 * DescriptorPerFrameLimit
        
        {
            frame_descriptor.descriptor_offset = 0
            {
                // @todo add a null texture, which is a bright debug color so that uninitialized indices(0) are easy to find
                write_texture_to_heap(&gpu, &descriptor_heap, frame_descriptor.descriptor_offset, textures[0], .SAMPLED_IMAGE)
                textures[0].sampled_index = frame_descriptor.descriptor_offset
                frame_descriptor.descriptor_offset += 1
                
                write_texture_to_heap(&gpu, &descriptor_heap, frame_descriptor.descriptor_offset, textures[1], .SAMPLED_IMAGE)
                textures[1].sampled_index = frame_descriptor.descriptor_offset
                frame_descriptor.descriptor_offset += 1
                
                write_texture_to_heap(&gpu, &descriptor_heap, frame_descriptor.descriptor_offset, textures[2], .SAMPLED_IMAGE)
                textures[2].sampled_index = frame_descriptor.descriptor_offset
                frame_descriptor.descriptor_offset += 1
                
                write_texture_to_heap(&gpu, &descriptor_heap, frame_descriptor.descriptor_offset, stuff.depth_buffer, .SAMPLED_IMAGE)
                stuff.depth_buffer.sampled_index = frame_descriptor.descriptor_offset
                frame_descriptor.descriptor_offset += 1
                
                write_texture_to_heap(&gpu, &descriptor_heap, frame_descriptor.descriptor_offset, stuff.depth_pyramid, .SAMPLED_IMAGE)
                stuff.depth_pyramid.sampled_index = frame_descriptor.descriptor_offset
                frame_descriptor.descriptor_offset += 1
                
                write_texture_to_heap(&gpu, &descriptor_heap, frame_descriptor.descriptor_offset, stuff.depth_pyramid, .STORAGE_IMAGE)
                stuff.depth_pyramid.storage_index = frame_descriptor.descriptor_offset
                frame_descriptor.descriptor_offset += 1
                
                
                for &mip, mip_level in stuff.depth_pyramid_mips {
                    write_texture_to_heap(&gpu, &descriptor_heap, frame_descriptor.descriptor_offset, stuff.depth_pyramid, .SAMPLED_IMAGE, cast(u32) mip_level, 1)
                    mip.sampled_index = frame_descriptor.descriptor_offset
                    frame_descriptor.descriptor_offset += 1
                    
                    write_texture_to_heap(&gpu, &descriptor_heap, frame_descriptor.descriptor_offset, stuff.depth_pyramid, .STORAGE_IMAGE, cast(u32) mip_level, 1)
                    mip.storage_index = frame_descriptor.descriptor_offset
                    frame_descriptor.descriptor_offset += 1
                }
            }
        }
        cpu_end_profile_zone()
        
        cpu_begin_profile_zone("Generate Draws")
        entropy := seed_random_series(545114)
        when true {
            draws := db_view[:50_000]
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
        } else {
            draws := db_view[:200_000]
            global_rotation := la.quaternion_from_euler_angles_f32(**(object_rotation * random_unilateral(&entropy, v3)), .XYX)
            for &draw, draw_index in draws {
                p := v3{0, 0, -3} + {0, 0, -10 / cast(f32) (draw_index+1)} * cast(f32) (draw_index)
                
                draw.p           = p
                draw.scale       = 1 / cast(f32) (draw_index+1)
                draw.orientation = global_rotation
                
                draw.texture_index = textures[auto_cast (draw_index+1) % texture_count].sampled_index
                
                mesh, mesh_index := random_choice_index(&entropy, geometry.meshes[:])
                
                draw.mesh_index    = mesh_index
                draw.vertex_offset = mesh.vertex_offset
            }
        }
        cpu_end_profile_zone()
        
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
        cmd := gpu_begin_command_recording(&gpu, gpu.command_pools[frame_index], gpu.general_queue)
        
        gpu_profile_frame_begin(&gpu, cmd)
        
        // Setting these dynamic states outside of rendering-passes means they persist across all passes.
        gpu_set_viewport(cmd, size = cast(v2) gpu.swapchain_size)
        gpu_set_scissor(cmd,  size = gpu.swapchain_size)
        
        gpu_set_active_heap(cmd, &descriptor_heap)
        
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
            _, draw_command_count_gpu := bump_allocate_type(bump, u32)
            _, draw_command_gpu := bump_allocate_slice(bump, [] Draw_Command, auto_cast len(draws))
            
            cull_globals_cpu, cull_globals_gpu := bump_allocate_type(bump, Cull_Globals)
            cull_globals_cpu^ = Cull_Globals {
                draw_buffer            = draw_buffer.p,
                mesh_buffer            = mesh_buffer.p,
                draw_visibility_buffer = draw_visibility_buffer.p,
                draw_command_buffer    = draw_command_gpu.p,
                draw_command_count     = draw_command_count_gpu.p,
                
                depth_pyramid_index = stuff.depth_pyramid.sampled_index,
                
                data = cull_data,
            }
            
            draw_globals_cpu, draw_globals_gpu := bump_allocate_type(bump, Draw_Globals)
            draw_globals_cpu^ = Draw_Globals {
                data = draw_data,
                
                draw_command_buffer = draw_command_gpu.p,
                draw_buffer         = draw_buffer.p,
                mesh_buffer         = mesh_buffer.p,
                meshlet_buffer      = meshlet_buffer.p,
                meshlet_data_buffer = meshlet_data_buffer.p,
                vertex_buffer       = vertex_buffer.p,
            }
            
            gpu_labeled_region_begin(cmd, "early culling", {0.0, 0.6, 0.8, 1.0})
                gpu_profile_zone_begin("early culling")
                
                ////////////////////////////////////////////////
                
                gpu_barrier(cmd, { .DRAW_INDIRECT }, { .ALL_TRANSFER })
                
                gpu_fill_memory(cmd, draw_command_count_gpu, 0)
                
                if !dvb_cleared {
                    dvb_cleared = true
                    gpu_fill_memory(cmd, draw_visibility_buffer, cast(u32) len(draws), 1)
                }
                
                ////////////////////////////////////////////////
                
                gpu_barrier(cmd, { .ALL_TRANSFER }, { .COMPUTE_SHADER })
                
                gpu_set_pipeline(cmd, early_cull_pipeline)
                    gpu_dispatch(cmd, &frame_descriptor, cull_globals_gpu, get_group_count(cull_shader, auto_cast len(draws)))
                
            gpu_profile_zone_end()
            gpu_labeled_region_end(cmd)
            
            ////////////////////////////////////////////////
            
            gpu_barrier(cmd, { .BOTTOM_OF_PIPE, .COMPUTE_SHADER }, { .DRAW_INDIRECT, .PRE_RASTERIZATION_SHADERS })
            
            ////////////////////////////////////////////////
            // early render - render objects that were visible last frame
            
            gpu_profile_zone_begin("early rendering pass")
            gpu_labeled_region_begin(cmd, "early rendering pass", {0.6, 0.1, 07, 1.0})
                begin_meshlet_rendering(&gpu, cmd, &stuff, {0.07, 0.07, 0.07, 1}, early = true)
                        
                    if print_profile_and_stats {
                        vk.ResetQueryPool(gpu.device, stats_pool, 0, stats_count)
                        vk.CmdBeginQuery(cmd, stats_pool, 0, {})
                    }
                    
                    gpu_labeled_region_begin(cmd, "meshlets", {0.0, 0.6, 0.8, 1.0})
                    gpu_profile_zone_begin("meshlets")
                    
                    gpu_set_pipeline(cmd, meshlet_pipeline)
                        gpu_draw_meshlets_indirect_count(cmd, &frame_descriptor,
                            draw_command_gpu, draw_command_count_gpu, 
                            auto_cast len(draws), offset_of(Draw_Command, command),
                            draw_globals_gpu,
                        )
                    
                    gpu_profile_zone_end()
                    gpu_labeled_region_end(cmd)
                    
                gpu_end_render_pass(cmd)
            gpu_labeled_region_end(cmd)
            gpu_profile_zone_end()
        }
        
        ////////////////////////////////////////////////
        // depth pyramid generation
        
        {
            gpu_profile_zone_begin("depth pyramid building")
            gpu_labeled_region_begin(cmd, "depth pyramid building", {0.4, 0.8, 0, 1.0})
            
            gpu_barrier(cmd, { .LATE_FRAGMENT_TESTS }, { .COMPUTE_SHADER })
            
            gpu_set_pipeline(cmd, depth_pipeline)
                for mip, mip_level in stuff.depth_pyramid_mips {
                    depth_globals_cpu, depth_globals_gpu := bump_allocate_type(bump, Depth_Data)
                    depth_globals_cpu^ = Depth_Data { 
                        size = cast(v2) mip.size,
                    }
                    if mip_level == 0 {
                        depth_globals_cpu.input_index = stuff.depth_buffer.sampled_index
                    } else if mip_level == 1 {
                        depth_globals_cpu.input_index = stuff.depth_pyramid.sampled_index
                    } else {
                        depth_globals_cpu.input_index = stuff.depth_pyramid_mips[mip_level-1].sampled_index
                    }
                    if mip_level == 0 {
                        depth_globals_cpu.output_index = stuff.depth_pyramid.storage_index
                    } else {
                        depth_globals_cpu.output_index = mip.storage_index
                    }
                    
                    gpu_dispatch(cmd, &frame_descriptor, depth_globals_gpu, get_group_count(depth_reduce_shader, **mip.size))
                    
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
            
            _, draw_command_count_gpu := bump_allocate_type(bump, u32)
            _, draw_command_gpu       := bump_allocate_slice(bump, [] Draw_Command, auto_cast len(draws))
            
            cull_globals_cpu, cull_globals_gpu := bump_allocate_type(bump, Cull_Globals)
            cull_globals_cpu^ = Cull_Globals {
                draw_buffer            = draw_buffer.p,
                mesh_buffer            = mesh_buffer.p,
                draw_visibility_buffer = draw_visibility_buffer.p,
                draw_command_buffer    = draw_command_gpu.p,
                draw_command_count     = draw_command_count_gpu.p,
                
                depth_pyramid_index = stuff.depth_pyramid.sampled_index,
                
                data = cull_data,
            }
            
            draw_globals_cpu, draw_globals_gpu := bump_allocate_type(bump, Draw_Globals)
            draw_globals_cpu^ = Draw_Globals {
                data = draw_data,
                
                draw_command_buffer = draw_command_gpu.p,
                draw_buffer         = draw_buffer.p,
                mesh_buffer         = mesh_buffer.p,
                meshlet_buffer      = meshlet_buffer.p,
                meshlet_data_buffer = meshlet_data_buffer.p,
                vertex_buffer       = vertex_buffer.p,
            }
            
            gpu_labeled_region_begin(cmd, "late culling", {0.0, 0.6, 0.8, 1.0})
                gpu_profile_zone_begin("late culling")
                
                
                
                gpu_barrier(cmd, { .DRAW_INDIRECT, .PRE_RASTERIZATION_SHADERS }, { .ALL_TRANSFER })
                
                gpu_fill_memory(cmd, draw_command_count_gpu, 0)
                
                
                
                // depth pyramid = compute + draw command count = transfer
                gpu_barrier(cmd, { .ALL_TRANSFER, .COMPUTE_SHADER }, { .COMPUTE_SHADER })
                
                gpu_set_pipeline(cmd, late_cull_pipeline)
                    gpu_dispatch(cmd, &frame_descriptor, cull_globals_gpu, get_group_count(cull_shader, auto_cast len(draws)))
                    
            gpu_profile_zone_end()
            gpu_labeled_region_end(cmd)
            
            ////////////////////////////////////////////////
            // late rendering - render objects that are visible this frame but weren't drawn in the early pass
            
            gpu_profile_zone_begin("late rendering pass")
            gpu_labeled_region_begin(cmd, "late rendering pass", {0.6, 0.1, 07, 1.0})
            
                gpu_barrier(cmd, 
                    { .COLOR_ATTACHMENT_OUTPUT, .LATE_FRAGMENT_TESTS,  .COMPUTE_SHADER }, 
                    { .COLOR_ATTACHMENT_OUTPUT, .EARLY_FRAGMENT_TESTS, .DRAW_INDIRECT, .PRE_RASTERIZATION_SHADERS },
                )
                
                begin_meshlet_rendering(&gpu, cmd, &stuff, {}, early = false)
                
                    gpu_set_pipeline(cmd, meshlet_pipeline)
                        gpu_draw_meshlets_indirect_count(cmd, &frame_descriptor,
                            draw_command_gpu, draw_command_count_gpu, 
                            auto_cast len(draws), offset_of(Draw_Command, command),
                            draw_globals_gpu,
                        )
                    
                gpu_end_render_pass(cmd)
                
                if print_profile_and_stats {
                    vk.CmdEndQuery(cmd, stats_pool, 0)
                }
                
            gpu_labeled_region_end(cmd)
            gpu_profile_zone_end()
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
        check(vk.EndCommandBuffer(cmd))
        cpu_end_profile_zone()
        
        cpu_begin_profile_zone("submit and present queue")
        // @cleanup dont pass the frameindex, this is a place that could cause mistakes
        end_of_frame_submit(&gpu, gpu.general_queue, frame_semaphore, next_frame, frame_index, &cmd)
        present_the_queue(&gpu, gpu.general_queue)
        next_frame += 1
        cpu_end_profile_zone()
        
        ////////////////////////////////////////////////
        
        {
            cpu_scoped_profile_zone("GPU profiler collation")
            // @todo(viktor): how can we record how many triangles we have rendered after culling?
            
            gpu_profile_collate_times(&gpu, print_profile_and_stats)
            
            gpu_delta             := gpu_profile_get_zone_duration(&gpu, "Frame")
            early_rendering_delta := gpu_profile_get_zone_duration(&gpu, "early rendering pass")
            late_rendering_delta  := gpu_profile_get_zone_duration(&gpu, "late rendering pass")
            early_cull_delta      := gpu_profile_get_zone_duration(&gpu, "early culling")
            late_cull_delta       := gpu_profile_get_zone_duration(&gpu, "late culling")
            
            debug.cpu_time             = time_smoothed_blend(debug.cpu_time,             cpu_delta,             cpu_delta)
            debug.early_cull_time      = time_smoothed_blend(debug.early_cull_time,      early_cull_delta,      cpu_delta)
            debug.late_cull_time       = time_smoothed_blend(debug.late_cull_time,       late_cull_delta,       cpu_delta)
            debug.early_rendering_time = time_smoothed_blend(debug.early_rendering_time, early_rendering_delta, cpu_delta)
            debug.late_rendering_time  = time_smoothed_blend(debug.late_rendering_time,  late_rendering_delta,  cpu_delta)
            // this might have happened when a validation error occurred, causing the smooth value to be messed for a very long time
            if gpu_delta >= 0 {
                debug.gpu_time = time_smoothed_blend(debug.gpu_time, gpu_delta, cpu_delta)
            }
            
            view :: proc (seconds: f64) -> time.Duration {
                return time.duration_round(cast(time.Duration) (seconds * cast(f64) time.Second), 1 * time.Microsecond)
            }
            
            cpu_begin_profile_zone("Update window title")
            sb := strings.builder_make(context.temp_allocator)
            fmt.sbprintf(&sb, "cpu: %.3v, gpu: %.3v, culling: early %.3v / late %.3v, rendering: early %.3v / late %.3v", 
                view(debug.cpu_time), view(debug.gpu_time), 
                view(debug.early_cull_time), view(debug.late_cull_time),
                view(debug.early_rendering_time), view(debug.late_rendering_time),
            )
            fmt.sbprintf(&sb, ", Features: ")
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
            
            if print_profile_and_stats {
                cpu_scoped_profile_zone("collect and print shader stats")
                
                stats_result: [128] u64
                size := cast(int) size_of_slice(stats_result[:])
                query_result := vk.GetQueryPoolResults(gpu.device, stats_pool, 0, 1, size, &stats_result[0], size_of(stats_result[0]), { ._64, .WAIT })
                check(query_result)
                
                fmt.println("------------------------------------\nStats:")
                bits := [?] vk.QueryPipelineStatisticFlag {
                    .COMPUTE_SHADER_INVOCATIONS,
                    .TASK_SHADER_INVOCATIONS_EXT,
                    .MESH_SHADER_INVOCATIONS_EXT,
                    .FRAGMENT_SHADER_INVOCATIONS,
                }
                
                for bit, index in bits {
                    fmt.printfln("  %v = %v", bit, view_magnitude(stats_result[index]))
                }
                fmt.printfln("-------------------------------------")
            }
        }
        
        cpu_end_profile_zone()
        
        if print_profile_and_stats {
            zones := the_cpu_profile_zones
            
            fmt.printfln("---------------------\nCPU profile:")
            
            dump_zone :: proc (zones: [dynamic] Profile_Zone, index: u32, depth := 0) {
                cpu_procedure_profile_zone()
                
                if index == 0 && depth != 0 { return }
                
                node := zones[index]
                xx :: proc (seconds: f64) -> time.Duration { return cast(time.Duration) (seconds * cast(f64) time.Second) }
                
                for _ in 0..<depth { fmt.printf("    ") }
                fmt.printf("%v: %v", node.name, xx(clocks_to_seconds(node.duration)))
                if node.duration_with_children != node.duration {
                    fmt.printf(" (with children %v)", xx(clocks_to_seconds(node.duration_with_children)))
                }
                fmt.printfln("")
                
                for link := node.first_child_index; link != 0; {
                    child := zones[link]
                    dump_zone(zones, link, depth + 1)
                    link = child.next_sibling_index
                }
            }
            
            dump_zone(zones, 0)
        }
    }
    
    ////////////////////////////////////////////////
    // Cleanup and Shutdown
    
	check(vk.DeviceWaitIdle(gpu.device))
    
    gpu_free(&gpu, vertex_buffer)
    gpu_free(&gpu, meshlet_buffer)
    gpu_free(&gpu, meshlet_data_buffer)
    gpu_free(&gpu, mesh_buffer)
    gpu_free(&gpu, draw_buffer)
    gpu_free(&gpu, draw_visibility_buffer)
    
    for &bump in frame_bump_allocators {
        bump_allocator_delete(&gpu, &bump)
    }
    
    destroy_pipeline(&gpu, meshlet_pipeline)
    destroy_pipeline(&gpu, early_cull_pipeline)
    destroy_pipeline(&gpu, late_cull_pipeline)
    destroy_pipeline(&gpu, depth_pipeline)
    
    for texture in textures {
        gpu_free_image(&gpu, texture)
    }
    
    destroy_descriptor_heap(&gpu, descriptor_heap)
    
    destroy_stuff(&gpu, &stuff)
    
    vk.DestroySemaphore(gpu.device, frame_semaphore, nil)
    vk.DestroyQueryPool(gpu.device, stats_pool, nil)
    vk.DestroyQueryPool(gpu.device, the_gpu_profiler.pool, nil)
    
    gpu_deinit(&gpu)
}

////////////////////////////////////////////////

the_cpu_profiler: ^Profile_Event_Table

cpu_begin_profile_zone :: proc (name: string) {
    record_event(the_cpu_profiler, read_cycle_counter(), .BeginZone, name)
}
cpu_end_profile_zone :: proc () {
    record_event(the_cpu_profiler, read_cycle_counter(), .EndZone, "")
}

@(deferred_in=cpu_end_scoped_profile_zone)
cpu_scoped_profile_zone :: proc (name: string) {
    record_event(the_cpu_profiler, read_cycle_counter(), .BeginZone, name)
}

cpu_end_scoped_profile_zone :: proc (_: string) {
    record_event(the_cpu_profiler, read_cycle_counter(), .EndZone, "")
}

@(deferred_in=cpu_end_procedure_profile_zone)
cpu_procedure_profile_zone :: proc (loc := #caller_location) {
    record_event(the_cpu_profiler, read_cycle_counter(), .BeginZone, loc.procedure)
}
cpu_end_procedure_profile_zone :: proc (_ := #caller_location) {
    record_event(the_cpu_profiler, read_cycle_counter(), .EndZone, "")
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

end_of_frame_submit :: proc (gpu: ^Gpu, queue: vk.Queue, timeline_semaphore: vk.Semaphore, signal_value: u64, frame_index: u64, command_buffer: ^vk.CommandBuffer) {
    // we handed out the command buffer and now ask for it to be returned. After this point it has no use, therefore we destroy the users value.
    defer command_buffer^ = nil
    
    semaphore_info := [?] vk.SemaphoreSubmitInfo {
        {
            sType = .SEMAPHORE_SUBMIT_INFO,
            semaphore = gpu.render_completes[gpu.image_index],
            stageMask = { .ALL_COMMANDS },
        },
        {
            sType = .SEMAPHORE_SUBMIT_INFO,
            semaphore = timeline_semaphore,
            value     = signal_value,
            stageMask = { .ALL_COMMANDS },
        },
    }
    
    submit_info := vk.SubmitInfo2 {
        sType = .SUBMIT_INFO_2,
        waitSemaphoreInfoCount = 1,
        pWaitSemaphoreInfos = &vk.SemaphoreSubmitInfo {
            sType = .SEMAPHORE_SUBMIT_INFO,
         
            semaphore = gpu.image_aquired_semaphores[frame_index],
            stageMask = { .TRANSFER },
        },
        commandBufferInfoCount = 1,
        pCommandBufferInfos = &vk.CommandBufferSubmitInfo {
            sType = .COMMAND_BUFFER_SUBMIT_INFO,
            commandBuffer = command_buffer^,
        },
        signalSemaphoreInfoCount = len(semaphore_info),
        pSignalSemaphoreInfos    = raw_data(&semaphore_info),
    }
    
    check(vk.QueueSubmit2(queue, 1, &submit_info, 0))
}

present_the_queue :: proc (gpu: ^Gpu, queue: vk.Queue) {
    present_info := vk.PresentInfoKHR {
        sType = .PRESENT_INFO_KHR,
        waitSemaphoreCount = 1,
        pWaitSemaphores    = &gpu.render_completes[gpu.image_index],
        swapchainCount     = 1,
        pSwapchains        = &gpu.swapchain,
        pImageIndices      = &gpu.image_index,
    }
    
    result := vk.QueuePresentKHR(queue, &present_info)
    if result == .ERROR_OUT_OF_DATE_KHR {
        gpu.swapchain_state = .Dirty
    } else {
        check(result)
    }
}

begin_meshlet_rendering :: proc (gpu: ^Gpu, cmd: vk.CommandBuffer, stuff: ^Render_Targets_And_Stuff, clear_color: v4, early: bool) {
    desc := Render_Pass_Desc {
        // :ViewSpace: 0 is the maximal depth value
        depth_target  = { 
            texture = stuff.depth_buffer, view = stuff.depth_view, load_op = early ? .CLEAR : .LOAD, store_op = early ? .STORE : .DONT_CARE, clear_depth = 0, 
        }, 
        color_targets = {
            { texture = stuff.color_buffer, view = stuff.color_view, load_op = early ? .CLEAR : .LOAD, store_op = .STORE, clear_color = clear_color },
        }, 
        
    }
    gpu_begin_render_pass(gpu, cmd, desc)
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