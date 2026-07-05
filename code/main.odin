#+vet explicit-allocators
package main

import "base:intrinsics"
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

// @cleanup
ImageUpdateData :: struct { image: Image, mip_base, mip_count: u32 }

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
    depth_pyramid_mip_sizes: [dynamic; 16] uv2,
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
}

// @shader
Cull_Data :: struct #all_or_none {
    view_from_world: m4,
    
    frustum_planes: [6] v4,
    draw_count: u32,
    
    pyramid_size: v2,
    p00, p11, near_z: f32,
    
    flags: u32,
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
}


// @shader @todo switching the order causes the size to not be read correctly in the shader and leads to bugs in the depth pyramid construction
Depth_Globals :: struct {
    texture_index: u32,
    size: v2,
}

// @shader
Draw :: struct {
    orientation: q32,
    p:           v3,
    scale:       f32,
    
    mesh_index:    u32,
    vertex_offset: u32,
    texture_index: u32,
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
    draw_id:   u32,
    meshlet_offset: u32,
    meshlet_count:  u32,
    command:   vk.DrawMeshTasksIndirectCommandEXT,
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
    check_sdl(sdl.InitSubSystem({ .VIDEO }))
    defer sdl.Quit()
    defer sdl.QuitSubSystem({ .VIDEO })
    
    window := sdl.CreateWindow("Vulkan Renderer", 1280, 720, sdl.WINDOW_VULKAN | sdl.WINDOW_RESIZABLE)
    check_sdl(window != nil)
    defer sdl.DestroyWindow(window)
    
    ////////////////////////////////////////////////
    
    gpu := gpu_init(window)
    
    stuff: Render_Targets_And_Stuff
    
    // :Stencil: Switch to .D32_SFLOAT_S8_UINT if we actually make use of the stencil buffer.
    stuff.depth_buffer.format = .D32_SFLOAT
    
    recreate_stuff(&gpu, &stuff)
    
    ////////////////////////////////////////////////
    // @speed most of these buffer could be move the GPU local memory
    // 200.000 suzannes: Defaul = 42.2 ms | GPU = 40.8 ms
    memory := Memory_Kind.Default
    
    // @todo(viktor): draws change per frame and could also be placed in the per frame bump allocator, as we just need a gpu address
    // All the geometry data can just live in the gpu
    vb_view,  vertex_buffer         := gpu_allocate(&gpu,      [] Vertex,       256 * Megabyte / size_of(Vertex),       memory = memory)
    mlb_view, meshlet_buffer        := gpu_allocate(&gpu,      [] Meshlet,      256 * Megabyte / size_of(Meshlet),      memory = memory)
    mdb_view, meshlet_data_buffer   := gpu_allocate(&gpu,      [] u32,          256 * Megabyte / size_of(u32),          memory = memory)
    mb_view,  mesh_buffer           := gpu_allocate(&gpu,      [] Mesh,         256 * Megabyte / size_of(Mesh),         memory = memory)
    
    db_view,  draw_buffer           := gpu_allocate(&gpu,      [] Draw,         256 * Megabyte / size_of(Draw),         memory = memory)
    dvb_view, draw_visibilty_buffer := gpu_allocate(&gpu,      [] u32,          256 * Megabyte / size_of(u32),          memory = memory, usage = vk.BufferUsageFlags { .STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST })
    
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
    
    generate_shader_api("shaders/api.generated.glslh")
    
    shader_allocator := context.allocator
    
    shader_files := make([dynamic] string, context.temp_allocator)
    get_all_files_with_extension(&shader_files, "shaders", shader_allocator, ".frag", ".mesh", ".task")
    
    watcher_allocator := context.allocator
    watchers := make([dynamic] Watcher, watcher_allocator)
    
    
    meshlet_shaders: [dynamic] Shader
    for file in shader_files {
        // @speed we duplicate this watcher per shader, so that each shader can keep track of the header being changed and be recompiled independently from other shaders, without effecting their modification test.
        common_watcher_id := watchers_make(&watchers, "shaders/common.glslh")
        shader := init_shader_and_watchers(&watchers, common_watcher_id, file, shader_allocator)
        append(&meshlet_shaders, shader)
    }
    
    early_cull_shader   := init_shader_and_watchers(&watchers, watchers_make(&watchers, "shaders/common.glslh"), "shaders/cull_early.comp",   shader_allocator)
    late_cull_shader    := init_shader_and_watchers(&watchers, watchers_make(&watchers, "shaders/common.glslh"), "shaders/cull_late.comp",    shader_allocator)
    depth_reduce_shader := init_shader_and_watchers(&watchers, watchers_make(&watchers, "shaders/common.glslh"), "shaders/depth_reduce.comp", shader_allocator)
    
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
                create_image_barrier_from_undefined(&texture, { .ALL_TRANSFER }, { .TRANSFER_WRITE }, .GENERAL)
            )
            
            gpu_copy_to_texture(&gpu, cmd, texture, gpu_data)
        }
            
        gpu_barrier(cmd, { .ALL_TRANSFER }, { .ALL_GRAPHICS })
        
        gpu_submit(gpu.transfer_queue, upload_semaphore, 1, cmd)
        gpu_wait_semaphore(&gpu, upload_semaphore, 1)
    }
    
    ////////////////////////////////////////////////
    
    gpu_profile_make_query_pool(gpu.device)
    
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
        defer_destroy(vk.DestroyQueryPool, stats_pool)
    }
    
    ////////////////////////////////////////////////
    
    early_cull_pipeline: Pipeline
    late_cull_pipeline:  Pipeline
    depth_pipeline:      Pipeline
    meshlet_pipeline:    Pipeline
    
    ////////////////////////////////////////////////
    
    absolute_frame_index: u64
    next_frame: u64 = MaxFramesInFlight+1
    frame_semaphore := gpu_create_timeline_semaphore(&gpu, MaxFramesInFlight)
    defer_destroy(vk.DestroySemaphore, frame_semaphore)
    
    ////////////////////////////////////////////////
    
    draw_data: Draw_Data
    
    for &pos, index in draw_data.light_pos {
        t := clamp_01_to_range(cast(f32) 0, cast(f32) len(draw_data.light_pos), cast(f32) index)
        pos.xyz = v3{0, -10, 10}
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
    
    for !quit {
        free_all(context.temp_allocator)
        
        ////////////////////////////////////////////////
        
        // @speed similarly the timestamps should only be collected if we need them. As we currently only look at the last rendered frame, we should only take them if we then also print them. In the future we may want to store more than one frame, but for now this would be better.
        print_profile_and_stats: bool
        
        mouse_delta: v2
        mouse_wheel_delta: f32
        @(static) left_down: bool
        @(static) space_down: bool
        
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
                
                case sdl.K_PLUS:  debug.display_pyramid_mip_level = clamp(debug.display_pyramid_mip_level+1, 0, cast(i32) len(stuff.depth_pyramid_mip_sizes)-1)
                case sdl.K_MINUS: debug.display_pyramid_mip_level = clamp(debug.display_pyramid_mip_level-1, 0, cast(i32) len(stuff.depth_pyramid_mip_sizes)-1)
                
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
        
        gpu_wait_semaphore(&gpu, frame_semaphore, next_frame - MaxFramesInFlight)
        
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
        
        frame_descriptor: Frame_Descriptor
        frame_descriptor.descriptor_offset = DescriptorStaticLimit              + cast(u32) frame_index * DescriptorPerFrameLimit
        frame_descriptor.descriptor_end    = frame_descriptor.descriptor_offset +                     1 * DescriptorPerFrameLimit
        
        ////////////////////////////////////////////////
        
        watchers_check_for_modification(watchers)
        
        if reload_shaders_if_needed(watchers, shader_allocator, &early_cull_shader) || !pipeline_is_valid(early_cull_pipeline) {
            destroy_pipeline(&gpu, early_cull_pipeline)
            early_cull_pipeline = gpu_create_compute_pipeline(&gpu, early_cull_shader, descriptor_heap.resource_size, descriptor_heap.sampler_size)
            fmt.printfln("Recreated early_cull_pipeline.")
        }
        
        if reload_shaders_if_needed(watchers, shader_allocator, &late_cull_shader) || !pipeline_is_valid(late_cull_pipeline) {
            destroy_pipeline(&gpu, late_cull_pipeline)
            late_cull_pipeline = gpu_create_compute_pipeline(&gpu, late_cull_shader, descriptor_heap.resource_size, descriptor_heap.sampler_size, sampler_hack_names = {"", "depth_sampler"})
            fmt.printfln("Recreated late_cull_pipeline.")
        }
        
        if reload_shaders_if_needed(watchers, shader_allocator, &depth_reduce_shader) || !pipeline_is_valid(depth_pipeline) {
            destroy_pipeline(&gpu, depth_pipeline)
            depth_pipeline = gpu_create_compute_pipeline(&gpu, depth_reduce_shader, descriptor_heap.resource_size, descriptor_heap.sampler_size, sampler_hack_names = {"", "depth_sampler", ""})
            fmt.printfln("Recreated depth_pipeline.")
        }
        
        if reload_shaders_if_needed(watchers, shader_allocator, meshlet_shaders[:]) || !pipeline_is_valid(meshlet_pipeline) {
            raster_description := DefaultRasterDesc
            raster_description.depth_format = stuff.depth_buffer.format
            raster_description.color_targets = {
                { format = stuff.color_buffer.format, write_mask = { .R, .G, .B, .A } },
            }
            raster_description.blendstate = &Blend_Desc{ **DefaultBlendDesc }
            // raster_description.blendstate.dst_color_factor = .ONE
            // :Stencil: 
            
            // @cleanup
            task, mesh, frag: Shader
            for it in meshlet_shaders do #partial switch it.stage {
            case .TASK_EXT: task = it
            case .MESH_EXT: mesh = it
            case .FRAGMENT: frag = it
            }
            
            destroy_pipeline(&gpu, meshlet_pipeline)
            meshlet_pipeline = gpu_create_graphics_meshlet_pipeline(&gpu, task, mesh, frag, raster_description, descriptor_heap.resource_size, descriptor_heap.sampler_size, sampler_hack_names = {"texture_sampler", "", "", ""})
            fmt.printfln("Recreated meshlet_pipeline.")
        }
        
        ////////////////////////////////////////////////
        
        entropy := seed_random_series(545114)
        when true {
            draws := db_view[:50_000]
            global_rotation := la.quaternion_from_euler_angles_f32(expand_values(object_rotation * random_unilateral(&entropy, v3)), .XYX)
            for &draw in draws {
                p := random_bilateral(&entropy, v3) * {10, 10, 10} + {0, 0, -10}
                
                draw.p           = p
                draw.scale       = linear_blend(cast(f32) .05, .8, power(random_unilateral(&entropy, f32), 8)) / 2
                rotation        := la.quaternion_angle_axis(random_unilateral(&entropy, f32) * Tau, random_bilateral(&entropy, v3))
                draw.orientation = rotation * global_rotation
                
                draw.texture_index = random_between_u32(&entropy, 0, texture_count-1)
                
                mesh, mesh_index := random_choice_index(&entropy, geometry.meshes[:])
                
                draw.mesh_index    = mesh_index
                draw.vertex_offset = mesh.vertex_offset
            }
        } else {
            draws := db_view[:200_000]
            global_rotation := la.quaternion_from_euler_angles_f32(expand_values(object_rotation * random_unilateral(&entropy, v3)), .XYX)
            for &draw, draw_index in draws {
                p := v3{0, 0, -3} + {0, 0, -10 / cast(f32) (draw_index+1)} * cast(f32) (draw_index)
                
                draw.p           = p
                draw.scale       = 1 / cast(f32) (draw_index+1)
                draw.orientation = global_rotation
                
                draw.texture_index = auto_cast (draw_index+1) % texture_count
                
                mesh, mesh_index := random_choice_index(&entropy, geometry.meshes[:])
                
                draw.mesh_index    = mesh_index
                draw.vertex_offset = mesh.vertex_offset
            }
        }
        
        ////////////////////////////////////////////////
        
        // @important @todo once we are satisfied with the occlusion culling the near plane should be set to a more reasonable value like 0.01. the 0.1 value is just useful for debugging, as the depth values lie in a more visible range.
        near_z: f32 = 0.1
        screen_from_view := projection_reversed_z_infinite_far_plane(70 * RadPerDeg, cast(f32) gpu.swapchain_size.x / cast(f32) gpu.swapchain_size.y, near_z)
        view_from_world  := translate(1, -cam_pos)
        
        draw_distance: f32 = 10
        
        frustum_planes: [6] v4
        if debug.culling_enabled {
            frustum_planes[0] = get_row_v4(screen_from_view, 3) + get_row_v4(screen_from_view, 0) // x + w < 0
            frustum_planes[1] = get_row_v4(screen_from_view, 3) - get_row_v4(screen_from_view, 0) // x - w > 0
            frustum_planes[2] = get_row_v4(screen_from_view, 3) + get_row_v4(screen_from_view, 1) // y + w < 0
            frustum_planes[3] = get_row_v4(screen_from_view, 3) - get_row_v4(screen_from_view, 1) // y - w > 0
            frustum_planes[4] = get_row_v4(screen_from_view, 3) - get_row_v4(screen_from_view, 2) // z - w > 0 -- :ReversedZ:
            frustum_planes[5] = v4{0, 0, -1, draw_distance}                                       // :ReversedZ: infinite far plane
            
            for &plane in frustum_planes {
                plane /= length(plane.xyz)
            }
        }
        
        ////////////////////////////////////////////////
        
        cull_data_flags: u32 
        if debug.culling_enabled   { cull_data_flags |= DebugFlag_FrustumCulling   }
        if debug.lod_enabled       { cull_data_flags |= DebugFlag_LevelOfDetail    }
        if debug.occlusion_enabled { cull_data_flags |= DebugFlag_OcclusionCulling }
        cull_data := Cull_Data {
            frustum_planes          = frustum_planes,
            draw_count              = auto_cast len(draws),
            view_from_world         = view_from_world,
            
            flags = cull_data_flags,
            
            p00 = screen_from_view[0,0],
            p11 = screen_from_view[1,1],
            near_z = near_z,
            
            pyramid_size = cast(v2) stuff.depth_pyramid.size.xy,
        }
        
        draw_data.screen_from_view = screen_from_view
        draw_data.view_from_world  = view_from_world
        
        ////////////////////////////////////////////////
        ////////////////////////////////////////////////
        ////////////////////////////////////////////////
        
        check(vk.ResetCommandPool(gpu.device, gpu.command_pools[frame_index], {}))
        // @api expecting the user to pass the frame index is a source for mistakes
        cmd := gpu_begin_command_recording(&gpu, gpu.command_pools[frame_index], gpu.general_queue)
        
        gpu_profile_frame_begin(gpu.device, cmd)
        
        // Setting these dynamic states outside of rendering-passes means they persist across all passes.
        gpu_set_viewport(cmd, size = cast(v2) gpu.swapchain_size)
        gpu_set_scissor(cmd,  size = gpu.swapchain_size)
        
        gpu_set_active_heap(cmd, &descriptor_heap)
        
        ////////////////////////////////////////////////
        // early cull - frustum cull & fill objects that *were* visible last frame
        
        {
            _, draw_command_count_gpu := bump_allocate_type(bump, u32)
            _, draw_command_gpu := bump_allocate_slice(bump, [] Draw_Command, auto_cast len(draws))
            
            cull_globals_cpu, cull_globals_gpu := bump_allocate_type(bump, Cull_Globals)
            cull_globals_cpu^ = Cull_Globals {
                draw_buffer            = draw_buffer.p,
                mesh_buffer            = mesh_buffer.p,
                draw_visibility_buffer = draw_visibilty_buffer.p,
                draw_command_buffer    = draw_command_gpu.p,
                draw_command_count     = draw_command_count_gpu.p,
                
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
                
                {
                    count, offset := gpu_reflect_get_buffer(draw_command_count_gpu.p)
                    vk.CmdFillBuffer(cmd, count, offset, gpu_size_of(draw_command_count_gpu), 0)
                }
                
                if !dvb_cleared {
                    dvb_cleared = true
                    
                    visibility_buffer, offset := gpu_reflect_get_buffer(draw_visibilty_buffer.p)
                    vk.CmdFillBuffer(cmd, visibility_buffer, offset, cast(vk.DeviceSize) len(draws) * size_of(dvb_view[0]), 1)
                }
                
                ////////////////////////////////////////////////
                
                gpu_barrier(cmd, { .ALL_TRANSFER }, { .COMPUTE_SHADER })
                
                gpu_set_pipeline(cmd, early_cull_pipeline)
                    gpu_dispatch(cmd, &frame_descriptor, cull_globals_gpu, get_group_count(early_cull_shader, auto_cast len(draws)))
                
            gpu_profile_zone_end()
            gpu_labeled_region_end(cmd)
            
            ////////////////////////////////////////////////
            
            gpu_barrier(cmd, { .BOTTOM_OF_PIPE, .COMPUTE_SHADER }, { .DRAW_INDIRECT, .PRE_RASTERIZATION_SHADERS })
            gpu_image_barriers(cmd, { .BY_REGION },
                create_image_barrier_from_undefined(&stuff.color_buffer, { .COLOR_ATTACHMENT_OUTPUT, .EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS }, { .COLOR_ATTACHMENT_WRITE },         .GENERAL),
                create_image_barrier_from_undefined(&stuff.depth_buffer, { .COLOR_ATTACHMENT_OUTPUT, .EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS }, { .DEPTH_STENCIL_ATTACHMENT_WRITE, .MEMORY_READ }, .GENERAL), 
                create_image_barrier_from_undefined(&stuff.depth_pyramid, { .COMPUTE_SHADER }, { .MEMORY_READ, .MEMORY_WRITE }, .GENERAL),
                create_image_barrier_from_undefined(&gpu.swapchain_images[gpu.image_index], { .ALL_TRANSFER }, { .TRANSFER_WRITE }, .GENERAL),
            )
            
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
                        updates := [] ImageUpdateData {
                            {},
                            { textures[0], 0, vk.REMAINING_MIP_LEVELS },
                            { textures[1], 0, vk.REMAINING_MIP_LEVELS },
                            { textures[2], 0, vk.REMAINING_MIP_LEVELS },
                        }
                        
                        gpu_push_descriptors(cmd, &gpu, &descriptor_heap, &frame_descriptor, updates)
                        gpu_draw_meshlets_indirect_count(cmd, &frame_descriptor,
                            draw_command_gpu.p, draw_command_count_gpu, 
                            auto_cast len(draws), size_of(Draw_Command), offset_of(Draw_Command, command),
                            draw_globals_gpu,
                        )
                    
                    gpu_profile_zone_end()
                    gpu_labeled_region_end(cmd)
                    
                    if print_profile_and_stats {
                        vk.CmdEndQuery(cmd, stats_pool, 0)
                    }
                    
                gpu_end_render_pass(cmd)
            gpu_labeled_region_end(cmd)
            gpu_profile_zone_end()
        }
        
        ////////////////////////////////////////////////
        // depth pyramid generation
        
        {
            gpu_profile_zone_begin("depth pyramid building")
            gpu_labeled_region_begin(cmd, "depth pyramid building", {0.4, 0.8, 0, 1.0})
            
            gpu_barrier(cmd, { .EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS }, { .COMPUTE_SHADER })
            
            gpu_set_pipeline(cmd, depth_pipeline)
                for mip_size, mip_level in stuff.depth_pyramid_mip_sizes {
                    updates := [] ImageUpdateData {
                        {
                            mip_level == 0 ? stuff.depth_buffer : stuff.depth_pyramid,
                            mip_level == 0 ? 0 : cast(u32) mip_level-1, 
                            1,
                        },
                        {}, // depth_sampler
                        { stuff.depth_pyramid, cast(u32) mip_level, 1 },
                    }
                    gpu_push_descriptors(cmd, &gpu, &descriptor_heap, &frame_descriptor, updates[:])
                    
                    depth_globals_cpu, depth_globals_gpu := bump_allocate_type(bump, Depth_Globals)
                    depth_globals_cpu^ = Depth_Globals { size = cast(v2) mip_size }
                    
                    gpu_dispatch(cmd, &frame_descriptor, depth_globals_gpu, get_group_count(depth_reduce_shader, **mip_size))
                    
                    gpu_barrier(cmd, { .COMPUTE_SHADER }, { .COMPUTE_SHADER })
                }
            
            gpu_barrier(cmd, { .COMPUTE_SHADER }, { .EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS })
            
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
                draw_visibility_buffer = draw_visibilty_buffer.p,
                draw_command_buffer    = draw_command_gpu.p,
                draw_command_count     = draw_command_count_gpu.p,
                
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
                
                ////////////////////////////////////////////////
                
                gpu_barrier(cmd, { .DRAW_INDIRECT, .PRE_RASTERIZATION_SHADERS }, { .ALL_TRANSFER })
                
                {
                    count, offset := gpu_reflect_get_buffer(draw_command_count_gpu.p)
                    vk.CmdFillBuffer(cmd, count, offset, gpu_size_of(draw_command_count_gpu), 0)
                }
                
                // depth pyramid = compute + draw command count = transfer
                gpu_barrier(cmd, { .ALL_TRANSFER, .COMPUTE_SHADER }, { .COMPUTE_SHADER })
                
                ////////////////////////////////////////////////
                
                gpu_set_pipeline(cmd, late_cull_pipeline)
                    
                    updates := [?] ImageUpdateData {
                        { stuff.depth_pyramid, 0, vk.REMAINING_MIP_LEVELS },
                        { }, // depth_sampler
                    }
                    push_descriptor_heap(&gpu, &descriptor_heap, &frame_descriptor, updates[:])
                    
                    gpu_dispatch(cmd, &frame_descriptor, cull_globals_gpu, get_group_count(late_cull_shader, auto_cast len(draws)))
                    
            gpu_profile_zone_end()
            gpu_labeled_region_end(cmd)
            
            ////////////////////////////////////////////////
            // late rendering - render objects that are visible this frame but weren't drawn in the early pass
            
            gpu_profile_zone_begin("late rendering pass")
            gpu_labeled_region_begin(cmd, "late rendering pass", {0.6, 0.1, 07, 1.0})
            
                gpu_barrier(cmd, 
                    { .COLOR_ATTACHMENT_OUTPUT, .EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS, .COMPUTE_SHADER }, 
                    { .COLOR_ATTACHMENT_OUTPUT, .EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS, .DRAW_INDIRECT, .PRE_RASTERIZATION_SHADERS }
                )
                
                ////////////////////////////////////////////////
            
                begin_meshlet_rendering(&gpu, cmd, &stuff, {}, early = false)
                
                    gpu_set_pipeline(cmd, meshlet_pipeline)
                        updates2 := [] ImageUpdateData {
                            {}, // texture_sampler
                            { textures[0], 0, vk.REMAINING_MIP_LEVELS },
                            { textures[1], 0, vk.REMAINING_MIP_LEVELS },
                            { textures[2], 0, vk.REMAINING_MIP_LEVELS },
                        }
                        
                        gpu_push_descriptors(cmd, &gpu, &descriptor_heap, &frame_descriptor, updates2)
                        
                        gpu_draw_meshlets_indirect_count(cmd, &frame_descriptor,
                            draw_command_gpu.p, draw_command_count_gpu, 
                            auto_cast len(draws), size_of(Draw_Command), offset_of(Draw_Command, command),
                            draw_globals_gpu,
                        )
                    
                gpu_end_render_pass(cmd)
                
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
            
            gpu_barrier(cmd, { .COLOR_ATTACHMENT_OUTPUT, .EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS, .DRAW_INDIRECT, .PRE_RASTERIZATION_SHADERS }, { .ALL_TRANSFER })
            
            if !debug.display_pyramid {
                vk.CmdCopyImage(cmd, source_image.image, .GENERAL, swapchain_image.image, .GENERAL, 1, &vk.ImageCopy {
                    srcSubresource = { aspectMask = { .COLOR }, layerCount = 1 },
                    dstSubresource = { aspectMask = { .COLOR }, layerCount = 1 },
                    extent         = { **swapchain_image.size },
                })
            } else {
                mip_size  := cast(iv2) stuff.depth_pyramid_mip_sizes[debug.display_pyramid_mip_level]
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
        
        // @cleanup dont pass the frameindex, this is a place that could cause mistakes
        end_of_frame_submit(&gpu, gpu.general_queue, frame_semaphore, next_frame, frame_index, &cmd)
        present_the_queue(&gpu, gpu.general_queue)
        next_frame += 1
        
        ////////////////////////////////////////////////
        
        {
            // @todo(viktor): how can we record how many triangles we have rendered after culling?
            
            gpu_profile_collate_times(&gpu, gpu.device, print_profile_and_stats)
            
            gpu_delta             := gpu_profile_get_zone("frame").total_time_with_children
            early_rendering_delta := gpu_profile_get_zone("early rendering pass").total_time_with_children
            late_rendering_delta  := gpu_profile_get_zone("late rendering pass").total_time_with_children
            early_cull_delta      := gpu_profile_get_zone("early culling").total_time_with_children
            late_cull_delta       := gpu_profile_get_zone("late culling").total_time_with_children
            
            debug.cpu_time             = time_smoothed_blend(cpu_delta, debug.cpu_time,             cpu_delta)
            debug.early_cull_time      = time_smoothed_blend(cpu_delta, debug.early_cull_time,      early_cull_delta)
            debug.late_cull_time       = time_smoothed_blend(cpu_delta, debug.late_cull_time,       late_cull_delta)
            debug.early_rendering_time = time_smoothed_blend(cpu_delta, debug.early_rendering_time, early_rendering_delta)
            debug.late_rendering_time  = time_smoothed_blend(cpu_delta, debug.late_rendering_time,  late_rendering_delta)
            // this might have happened when a validation error occurred, causing the smooth value to be messed for a very long time
            if gpu_delta >= 0 {
                debug.gpu_time = time_smoothed_blend(cpu_delta, debug.gpu_time, gpu_delta)
            }
            
            view :: proc (seconds: f64) -> time.Duration {
                return time.duration_round(cast(time.Duration) (seconds * cast(f64) time.Second), 1 * time.Microsecond)
            }
            
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
            
            if print_profile_and_stats {
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
    }
    
    ////////////////////////////////////////////////
    // Cleanup and Shutdown
    
	check(vk.DeviceWaitIdle(gpu.device))
    
    gpu_free(&gpu, vertex_buffer)
    gpu_free(&gpu, meshlet_buffer)
    gpu_free(&gpu, meshlet_data_buffer)
    gpu_free(&gpu, mesh_buffer)
    gpu_free(&gpu, draw_buffer)
    gpu_free(&gpu, draw_visibilty_buffer)
    
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
    
    gpu_deinit(&gpu)
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
    desc := Render_Pass_Desc {
        // :ReversedZ: 0 is the maximal value
        depth_target  = { 
            texture = stuff.depth_buffer, view = stuff.depth_view, load_op = early ? .CLEAR : .LOAD, store_op = early ? .STORE : .DONT_CARE, clear_depth = 0 
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
    
    stuff.depth_pyramid = gpu_allocate_texture(gpu, default_texture_desc(size = {pyramid_size.x, pyramid_size.y, 1}, format = .R32_SFLOAT, mip_count = mip_count, usage = { .SAMPLED, .STORAGE, .TRANSFER_SRC }))
    stuff.depth_buffer = gpu_allocate_texture(gpu, default_texture_desc(size = {gpu.swapchain_size.x, gpu.swapchain_size.y, 1}, format = stuff.depth_buffer.format, usage = { .DEPTH_STENCIL_ATTACHMENT, .SAMPLED }))
    stuff.color_buffer = gpu_allocate_texture(gpu, default_texture_desc(size = {gpu.swapchain_size.x, gpu.swapchain_size.y, 1}, format = gpu.swapchain_format,      usage = { .COLOR_ATTACHMENT, .TRANSFER_SRC }))
    
    for i in 0..<mip_count {
        mip_size := pyramid_size
        mip_size.x >>= i
        mip_size.y >>= i
        mip_size = vec_max(mip_size, 1)
        append(&stuff.depth_pyramid_mip_sizes, mip_size)
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
    
    clear(&stuff.depth_pyramid_mip_sizes)
    
}

////////////////////////////////////////////////

check :: proc (result: vk.Result, loc := #caller_location) {
    if result != .SUCCESS {
        fmt.printf("%v:%v:%v: Vulkan call returned %v", loc.file_path, loc.line, loc.column, result)
        intrinsics.debug_trap()
    }
}

check_sdl :: proc (result: bool, loc := #caller_location) {
    if !result {
        fmt.printf("%v:%v:%v: SDL call returned %v", loc.file_path, loc.line, loc.column, sdl.GetError())
        intrinsics.debug_trap()
        os.exit(1)
    }
}