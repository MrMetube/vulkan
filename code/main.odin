#+vet explicit-allocators
package main

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:time"
import la "core:math/linalg"

import sdl "vendor:sdl3"
import vk  "vendor:vulkan"

////////////////////////////////////////////////

Optimized :: ODIN_OPTIMIZATION_MODE == .Speed

// @todo(viktor): make this runtime changeable
VSync :: true when !Optimized else false

////////////////////////////////////////////////

DescriptorUpdateData :: struct #raw_union {
    buffer: vk.DescriptorBufferInfo,
    image:  vk.DescriptorImageInfo,
}

Geometry :: struct {
    // @todo(viktor): all this data is not needed on the cpu, we could just directly upload it to the gpu buffers
    vertices:     [dynamic] Vertex,
    meshlets:     [dynamic] Meshlet,
    meshlet_data: [dynamic] u32,
    
    meshes: [dynamic] Mesh,
}

Stuff_With_The_Same_Lifetime_As_The_Swapchain :: struct {
    color_buffer: Image,
    depth_buffer: Image,
    
    depth_sampler: vk.Sampler, // well except you of course..
    depth_pyramid: Image,
    depth_pyramid_mips: [dynamic; 16] Depth_Pyramid_Mip,
}

////////////////////////////////////////////////

// @shader meshlet.mesh
MaxVertices  :: 64
MaxTriangles :: 84

// @shader cull.comp
Cull_Globals :: struct #all_or_none {
    frustum_planes: [6] v4,
    draw_buffer:         vk.DeviceAddress "Draw",
    mesh_buffer:         vk.DeviceAddress "Mesh",
    draw_command_buffer: vk.DeviceAddress "Draw_Command",
    draw_command_count:  vk.DeviceAddress "uint",
    
    camera_p:   v3,
    draw_count: u32,
    
    frustum_culling_enabled: b32,
    lod_enabled:             b32,
}

// @shader
Draw_Globals :: struct {
    view_from_world:      m4,
    projection_from_view: m4,
    light_pos:  [4] v4,
    
    draw_command_buffer: vk.DeviceAddress "Draw_Command",
    draw_buffer:         vk.DeviceAddress "Draw",
    mesh_buffer:         vk.DeviceAddress "Mesh",
    meshlet_buffer:      vk.DeviceAddress "Meshlet",
    meshlet_data_buffer: vk.DeviceAddress "uint",
    vertex_buffer:       vk.DeviceAddress "Vertex",
}

// @shader
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
    lod_index: u32,
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
    defer sdl.Quit()
    
    check_sdl(sdl.InitSubSystem({ .VIDEO }))
    defer sdl.QuitSubSystem({ .VIDEO })
    
    window := sdl.CreateWindow("How to Vulkan", 1280, 720, sdl.WINDOW_VULKAN | sdl.WINDOW_RESIZABLE)
    check_sdl(window != nil)
    defer sdl.DestroyWindow(window)
    
    ////////////////////////////////////////////////
    
    gpu := gpu_init(window)
    
    stuff: Stuff_With_The_Same_Lifetime_As_The_Swapchain
    
    // :Stencil: Switch to .D32_SFLOAT_S8_UINT if we actually make use of the stencil buffer.
    stuff.depth_buffer.format = .D32_SFLOAT
    
    recreate_stuff(&gpu, &stuff)
    
    ////////////////////////////////////////////////
    // @speed most of these buffer could be move the GPU local memory
    // 200.000 suzannes: Defaul = 42.2 ms | GPU = 40.8 ms
    memory := Memory_Kind.Default
    
    // @todo(viktor): draws change per frame and could also be placed in the per frame bump allocator, as we just need a gpu address
    // All the geometry data can just live in the gpu
    vb_view,   vertex_buffer        := gpu_allocate(&gpu, [] Vertex,    256 * Megabyte / size_of(Vertex),  memory = memory)
    mlb_view,  meshlet_buffer       := gpu_allocate(&gpu, [] Meshlet,   256 * Megabyte / size_of(Meshlet), memory = memory)
    mdb_view,  meshlet_data_buffer  := gpu_allocate(&gpu, [] u32,       256 * Megabyte / size_of(u32),     memory = memory)
    db_view,   draw_buffer          := gpu_allocate(&gpu, [] Draw,      256 * Megabyte / size_of(Draw),    memory = memory)
    mb_view,   mesh_buffer          := gpu_allocate(&gpu, [] Mesh,      256 * Megabyte / size_of(Mesh),    memory = memory)
    dcb_view,  draw_command_buffer  := gpu_allocate(&gpu, [] Draw_Command, 256 * Megabyte / size_of(Draw_Command), memory = memory, usage = vk.BufferUsageFlags {  .STORAGE_BUFFER, .INDIRECT_BUFFER })
    dccb_view, draw_command_count := gpu_allocate_type(&gpu, u32, memory = memory, usage = { .STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST })
    
    unused(dcb_view)
    
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
    
    draw_cull_shader    := init_shader_and_watchers(&watchers, watchers_make(&watchers, "shaders/common.glslh"), "shaders/draw_cull.comp",    shader_allocator)
    depth_reduce_shader := init_shader_and_watchers(&watchers, watchers_make(&watchers, "shaders/common.glslh"), "shaders/depth_reduce.comp", shader_allocator)
    
    ////////////////////////////////////////////////
    
    // this will hold literally all textures, expand if needed and let the shader index into it via Draw.texture_index
    textures: [1024] Image
    texture_descriptors: [3] vk.DescriptorImageInfo
    
    texture_heap := create_descriptor_heap(&gpu, 65536)
    
    {
        upload_bump := bump_allocator_make_temporary(&gpu, 256 * Megabyte, usage = { .TRANSFER_SRC })
        defer bump_allocator_delete(&gpu, &upload_bump)
        
        cmd := gpu_begin_command_recording(&gpu, gpu.transfer_command_pool, gpu.transfer_queue)
        upload_semaphore := gpu_create_timeline_semaphore(&gpu, 0)
        defer gpu_destroy_semaphore(&gpu, upload_semaphore)
        
        default_sampler := create_sampler(&gpu, .LINEAR, .LINEAR, anisotropy = true)
        defer_destroy(vk.DestroySampler, default_sampler)
        
        for &texture, index in textures[:3] {
            filename := fmt.tprintf("tutorial/suzanne%v.ktx", index)
            
            loaded_texture := load_ktx_texture(filename, context.temp_allocator)
            
            description := default_texture_desc()
            description.size.xy = { loaded_texture.width, loaded_texture.height }
            description.format  = loaded_texture.format
            description.usage   = { .TRANSFER_DST, .SAMPLED }
            
            texture      = gpu_allocate_texture(&gpu, description)
            texture.view = gpu_create_texture_view(&gpu, texture, 0, description.mip_count, { .COLOR })
            
            
            texture_descriptors[index] = gpu_texture_descriptor(texture.view, .READ_ONLY_OPTIMAL, default_sampler)
            
            // @waste we should have loaded all data into here if possible
            cpu_data, gpu_data := bump_allocate(&upload_bump, cast(u32) len(loaded_texture.data), alignment = 32)
            copy(cpu_data, loaded_texture.data)
            
            pipeline_barrier_begin()
                add_image_barrier(&texture, {}, {}, .UNDEFINED, { .TRANSFER }, { .TRANSFER_WRITE }, .TRANSFER_DST_OPTIMAL)
            pipeline_barrier_end(cmd)
            
            gpu_copy_to_texture(&gpu, cmd, texture, gpu_data, description.size)
            
            pipeline_barrier_begin()
                add_image_barrier_transition_from_last(&texture, { .FRAGMENT_SHADER }, { .SHADER_READ }, .READ_ONLY_OPTIMAL)
            pipeline_barrier_end(cmd)
            
            write_texture_to_heap(&gpu, &texture_heap, index, texture.view, texture.last_transition.layout)
        }
            
        gpu_barrier(cmd, { .TRANSFER }, { .ALL_COMMANDS }, { .descriptors })
        
        gpu_submit(gpu.transfer_queue, upload_semaphore, 1, cmd)
        gpu_wait_semaphore(&gpu, upload_semaphore, 1)
    }
    
    ////////////////////////////////////////////////
    
    global_sampler := create_sampler(&gpu, .LINEAR, .LINEAR, anisotropy = true)
    
    // @todo(viktor): migrate the depth_pyramid image into the textures array. make it manage all textures, and let stuff just hold onto a handle inside that array.
    // @study how many textures can we index into like this? maxDescriptorSetSampledImages, maxPerStageDescriptorSampledImages
    // @study descriptorBindingUpdateAfterBind
    // @todo it seems we need two texture sets, one for sampling .CombinedImageSampler, and one for writing to .StorageImage
    textures_descriptor_set_layout: vk.DescriptorSetLayout
    textures_descriptor_set:        vk.DescriptorSet
    {
        pool: vk.DescriptorPool
        
        descriptor_layout_create_info := vk.DescriptorSetLayoutCreateInfo {
            sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            pNext = &vk.DescriptorSetLayoutBindingFlagsCreateInfo {
                sType = .DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO,
                bindingCount  = 1,
                pBindingFlags = &vk.DescriptorBindingFlags { .VARIABLE_DESCRIPTOR_COUNT },
            },
            bindingCount = 1,
            pBindings = &vk.DescriptorSetLayoutBinding {
                binding         = 0,
                descriptorType  = .COMBINED_IMAGE_SAMPLER,
                descriptorCount = len(textures),
                stageFlags      = { .FRAGMENT },
            },
        }
        
        check(vk.CreateDescriptorSetLayout(gpu.device, &descriptor_layout_create_info, nil, &textures_descriptor_set_layout))
        defer_destroy(vk.DestroyDescriptorSetLayout, textures_descriptor_set_layout)
        
        descriptor_pool_create_info := vk.DescriptorPoolCreateInfo {
            sType = .DESCRIPTOR_POOL_CREATE_INFO,
            maxSets       = 1,
            poolSizeCount = 1,
            pPoolSizes    = &vk.DescriptorPoolSize {
                type = .COMBINED_IMAGE_SAMPLER,
                descriptorCount = len(textures),
            },
        }
        
        check(vk.CreateDescriptorPool(gpu.device, &descriptor_pool_create_info, nil, &pool))
        defer_destroy(vk.DestroyDescriptorPool, pool)
        
        descriptor_count := cast(u32) len(textures)
        
        textures_desc_set_allocate_info := vk.DescriptorSetAllocateInfo {
            sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
            pNext = &vk.DescriptorSetVariableDescriptorCountAllocateInfo {
                sType = .DESCRIPTOR_SET_VARIABLE_DESCRIPTOR_COUNT_ALLOCATE_INFO,
                descriptorSetCount = 1,
                pDescriptorCounts  = &descriptor_count,
            },
            descriptorPool     = pool,
            descriptorSetCount = 1,
            pSetLayouts        = &textures_descriptor_set_layout,
        }
        
        check(vk.AllocateDescriptorSets(gpu.device, &textures_desc_set_allocate_info, &textures_descriptor_set))
        
        write_desc_set := vk.WriteDescriptorSet {
            sType = .WRITE_DESCRIPTOR_SET,
            dstSet     = textures_descriptor_set,
            dstBinding = 0,
            descriptorType  = .COMBINED_IMAGE_SAMPLER,
            descriptorCount = cast(u32) len(texture_descriptors),
            pImageInfo      = &texture_descriptors[0],
        }
        vk.UpdateDescriptorSets(gpu.device, 1, &write_desc_set, 0, nil)
    }
    
    ////////////////////////////////////////////////
    
    gpu_profile_make_query_pool(gpu.device)
    
    ////////////////////////////////////////////////
    
    depth_descriptor_set_layout := create_descriptor_set_layout(gpu.device, depth_reduce_shader)
    defer_destroy(vk.DestroyDescriptorSetLayout, depth_descriptor_set_layout)
    
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
    
    cull_pipeline:    Pipeline
    depth_pipeline:   Pipeline
    meshlet_pipeline: Pipeline
    
    ////////////////////////////////////////////////
    
    absolute_frame_index: u64
    next_frame: u64 = MaxFramesInFlight+1
    frame_semaphore := gpu_create_timeline_semaphore(&gpu, MaxFramesInFlight)
    defer_destroy(vk.DestroySemaphore, frame_semaphore)
    
    ////////////////////////////////////////////////
    
    draw_globals: Draw_Globals
    
    for &pos, index in draw_globals.light_pos {
        t := clamp_01_to_range(cast(f32) 0, cast(f32) len(draw_globals.light_pos), cast(f32) index)
        pos.xyz = v3{0, -10, 10}
        pos.xz += arm(t * Tau)
    }
    
    HEAP :: true
    
    cam_pos := v3{ 0, 0, 0}
    object_rotation: v3
    quit: bool
    last_time := time.tick_now()
    
    debug: struct {
        culling_enabled: bool,
        lod_enabled:     bool,
        display_pyramid: bool,
        display_pyramid_mip_level: i32,
        
        cpu_time:  f64,
        gpu_time:  f64,
        cull_time: f64,
    } = {
        culling_enabled = true,
        lod_enabled     = true,
    }
    
    // @correctness ensure that this is enough and that we did not overflow inside of a frame and override someone elses data for a shader
    frame_bump_allocators: [MaxFramesInFlight] Bump_Allocator
    for &bump in frame_bump_allocators {
        bump = bump_allocator_make_temporary(&gpu, 1 * Megabyte)
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
                case sdl.K_C:     debug.culling_enabled = !debug.culling_enabled
                case sdl.K_L:     debug.lod_enabled     = !debug.lod_enabled
                case sdl.K_O:     debug.display_pyramid = !debug.display_pyramid
                case sdl.K_PLUS:  debug.display_pyramid_mip_level = clamp(debug.display_pyramid_mip_level+1, 0, cast(i32) len(stuff.depth_pyramid_mips)-1)
                case sdl.K_MINUS: debug.display_pyramid_mip_level = clamp(debug.display_pyramid_mip_level-1, 0, cast(i32) len(stuff.depth_pyramid_mips)-1)
                case sdl.K_P:     print_profile_and_stats = true
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
        
        delta_time_64 := time.duration_seconds(delta_tick)
        delta_time := cast(f32) delta_time_64
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
        
        if gpu.swapchain_state == .Was_Resized {
            gpu.swapchain_state = .Ok
            recreate_stuff(&gpu, &stuff)
        }
        
        assert(gpu.swapchain_state != .Dirty)
        
        if gpu.swapchain_state == .Window_Is_Minimized { continue }
        
        bump := &frame_bump_allocators[frame_index]
        
        ////////////////////////////////////////////////
        
        watchers_check_for_modification(watchers)
        
        if reload_shaders_if_needed(watchers, shader_allocator, &draw_cull_shader) || !pipeline_is_valid(cull_pipeline) {
            destroy_pipeline(&gpu, cull_pipeline)
            
            cull_pipeline = gpu_create_compute_pipeline(&gpu, draw_cull_shader)
        }
        
        if reload_shaders_if_needed(watchers, shader_allocator, &depth_reduce_shader) || !pipeline_is_valid(depth_pipeline) {
            destroy_pipeline(&gpu, depth_pipeline)
            
            depth_pipeline = gpu_create_compute_pipeline(&gpu, depth_reduce_shader, depth_descriptor_set_layout)
            depth_pipeline.update_template = create_update_template(gpu.device, .COMPUTE, depth_pipeline.layout, depth_reduce_shader)
        }
        
        if reload_shaders_if_needed(watchers, shader_allocator, meshlet_shaders[:]) || !pipeline_is_valid(meshlet_pipeline) {
            raster_description := DefaultRasterDesc
            raster_description.depth_format = stuff.depth_buffer.format
            raster_description.color_targets = {
                { format = stuff.color_buffer.format, write_mask = { .R, .G, .B, .A } },
            }
            raster_description.blendstate = &Blend_Desc{ **DefaultBlendDesc }
            // :Stencil: 
            
            // @cleanup
            task, mesh, frag: Shader
            for it in meshlet_shaders do #partial switch it.stage {
            case .TASK_EXT: task = it
            case .MESH_EXT: mesh = it
            case .FRAGMENT: frag = it
            }
            
            destroy_pipeline(&gpu, meshlet_pipeline)
            if HEAP {
                meshlet_pipeline = gpu_create_graphics_meshlet_pipeline(&gpu, task, mesh, frag, raster_description, texture_heap.layout)
            } else {
                meshlet_pipeline = gpu_create_graphics_meshlet_pipeline(&gpu, task, mesh, frag, raster_description, textures_descriptor_set_layout)
            }
        }
        
        ////////////////////////////////////////////////
        
        entropy := seed_random_series(54654)
        when true {
            draws := db_view[:200_000]
            global_rotation := la.quaternion_from_euler_angles_f32(expand_values(object_rotation * random_unilateral(&entropy, v3)), .XYX)
            for &draw in draws {
                p := random_bilateral(&entropy, v3) * {10, 10, 10} - {0, 0, 20}
                
                draw.p           = p
                draw.scale       = linear_blend(cast(f32) .1, .4, square(random_unilateral(&entropy, f32))) / 2
                rotation        := la.quaternion_angle_axis(random_unilateral(&entropy, f32) * Tau, random_bilateral(&entropy, v3))
                draw.orientation = rotation * global_rotation
                
                draw.texture_index = random_index(&entropy, texture_descriptors[:])
                
                mesh, mesh_index := random_choice_index(&entropy, geometry.meshes[:])
                
                draw.mesh_index    = mesh_index
                draw.vertex_offset = mesh.vertex_offset
            }
        } else {
            @(static) draws: [1] Draw
            for &draw in draws {
                p := v3{0, 0, -3}
                
                draw.p           = p
                draw.scale       = 1
                draw.orientation = 0
                
                draw.texture_index = 2
                
                mesh, mesh_index := random_choice_index(&entropy, geometry.meshes[:])
                
                draw.mesh_index    = mesh_index
                draw.vertex_offset = mesh.vertex_offset
            }
        }
        
        ////////////////////////////////////////////////
        
        check(vk.ResetCommandPool(gpu.device, gpu.command_pools[frame_index], {}))
        // @api expecting the user to pass the frame index is a source for mistakes
        cmd := gpu_begin_command_recording(&gpu, gpu.command_pools[frame_index], gpu.general_queue)
        
        gpu_profile_frame_begin(gpu.device, cmd)
        
        ////////////////////////////////////////////////
        
        gpu_labeled_region_begin(cmd, "culling", {0.0, 0.6, 0.8, 1.0})
            gpu_profile_zone_begin("culling")
            
            // @todo(viktor): is this barrier/transition before the fill necessary?
            gpu_barrier(cmd, {}, { .TRANSFER })
            
            ////////////////////////////////////////////////
            
            {
                count_buffer := gpu_reflect_get_buffer(draw_command_count.address).buffer
                vk.CmdFillBuffer(cmd, count_buffer, 0, size_of(dccb_view^), 0)
            }
            
            ////////////////////////////////////////////////
            
            // :OcclusionCull: the memory barrier for the depth pyramid had a parameters, but just for the late pass (see https://youtu.be/Ka30T6BMdhI?list=PLOU0IFZHP8dDap0WO7_IwOzgITq3ZUZsy&t=10157)
            gpu_barrier(cmd, { .DRAW_INDIRECT, .MESH_SHADER_EXT, .TRANSFER }, { .COMPUTE_SHADER })
            
            ////////////////////////////////////////////////
            
            // @important @todo once we are satisfied with the occlusion culling the near plane should be set to a more reasonable value like 0.01. the 0.1 value is just useful for debugging, as the depth values lie in a more visible range.
            projection := projection_reversed_z_infinite_far_plane(70 * RadPerDeg, cast(f32) gpu.swapchain_size.x / cast(f32) gpu.swapchain_size.y, 0.1)
            view       := translate(1, -cam_pos)
            
            draw_distance: f32 = 100
            
            frustum_planes: [6] v4
            if debug.culling_enabled {
                view_projection := projection * view
                cam_forward := v3{0, 0, -1}
                
                frustum_planes[0] = get_row_v4(view_projection, 3) + get_row_v4(view_projection, 0) // x + w < 0
                frustum_planes[1] = get_row_v4(view_projection, 3) - get_row_v4(view_projection, 0) // x - w > 0
                frustum_planes[2] = get_row_v4(view_projection, 3) + get_row_v4(view_projection, 1) // y + w < 0
                frustum_planes[3] = get_row_v4(view_projection, 3) - get_row_v4(view_projection, 1) // y - w > 0
                frustum_planes[4] = get_row_v4(view_projection, 3) - get_row_v4(view_projection, 2) // z - w > 0 -- :ReversedZ:
                
                unused(draw_distance)
                unused(cam_forward)
                // @todo(viktor): also reenable in the compute shader
                // frustum_planes[5] = v4{**cam_forward, draw_distance + dot(cam_forward, cam_pos)}          // :ReversedZ: infinite far plane
                
                for &plane in frustum_planes {
                    plane /= length(plane.xyz)
                }
            }
            
            
            cull_globals_cpu, cull_globals_gpu := bump_allocate_type(bump, Cull_Globals)
            
            cull_globals_cpu^ = Cull_Globals {
                frustum_planes      = frustum_planes,
                draw_buffer         = draw_buffer,
                mesh_buffer         = mesh_buffer,
                draw_command_buffer = draw_command_buffer,
                draw_command_count  = draw_command_count.address,
                
                lod_enabled             = cast(b32) debug.lod_enabled,
                frustum_culling_enabled = cast(b32) debug.culling_enabled,
                draw_count              = auto_cast len(draws),
                camera_p                = cam_pos,
            }
            
            gpu_set_pipeline(cmd, cull_pipeline)
            
                // @shader cull.comp
                gpu_dispatch(cmd, &cull_globals_gpu, get_group_count(draw_cull_shader, auto_cast len(draws)))
            
            ////////////////////////////////////////////////
            
            // @todo(viktor): should these be combined into one api call?
            gpu_barrier(cmd, { .COMPUTE_SHADER }, { .DRAW_INDIRECT })
            // this apparently needs to happend before we do anything related to rendering
            pipeline_barrier_begin()
                add_image_barrier(&stuff.color_buffer, { .BOTTOM_OF_PIPE }, {}, .UNDEFINED, { .COLOR_ATTACHMENT_OUTPUT, .EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS }, { .COLOR_ATTACHMENT_WRITE },         .ATTACHMENT_OPTIMAL)
                add_image_barrier(&stuff.depth_buffer, { .BOTTOM_OF_PIPE }, {}, .UNDEFINED, { .COLOR_ATTACHMENT_OUTPUT, .EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS }, { .DEPTH_STENCIL_ATTACHMENT_WRITE }, .ATTACHMENT_OPTIMAL, { .DEPTH }) // :Stencil: add .STENCIL to the aspect mask
            pipeline_barrier_end(cmd)
            
            ////////////////////////////////////////////////
            
            gpu_profile_zone_end()
        gpu_labeled_region_end(cmd)
        
        ////////////////////////////////////////////////
        
        // Setting these outside of rendering-sections means they persist across all sections.
        gpu_set_viewport(cmd, size = cast(v2) gpu.swapchain_size)
        gpu_set_scissor(cmd,  size = gpu.swapchain_size)
        
        ////////////////////////////////////////////////
        
        // @shaders meshlet pipeline
        draw_globals.projection_from_view = projection
        draw_globals.view_from_world      = view
        
        draw_globals.draw_command_buffer = draw_command_buffer
        draw_globals.draw_buffer         = draw_buffer
        draw_globals.mesh_buffer         = mesh_buffer
        draw_globals.meshlet_buffer      = meshlet_buffer
        draw_globals.meshlet_data_buffer = meshlet_data_buffer
        draw_globals.vertex_buffer       = vertex_buffer
        
        draw_globals_cpu, draw_globals_gpu := bump_allocate_type(bump, Draw_Globals)
        draw_globals_cpu^ = draw_globals
        
        gpu_profile_zone_begin("rendering early pass")
        gpu_labeled_region_begin(cmd, "rendering early pass", {0.6, 0.1, 07, 1.0})
        render(&gpu, cmd, stuff.color_buffer, stuff.depth_buffer, {0.07, 0.07, 0.07, 1}, early = true)
                
            if print_profile_and_stats {
                vk.ResetQueryPool(gpu.device, stats_pool, 0, stats_count)
                vk.CmdBeginQuery(cmd, stats_pool, 0, {})
            }
            
            gpu_labeled_region_begin(cmd, "meshlets", {0.0, 0.6, 0.8, 1.0})
            gpu_profile_zone_begin("meshlets")
            
            gpu_set_pipeline(cmd, meshlet_pipeline)
                if HEAP {
                    gpu_set_active_texture_head_ptr(cmd, &texture_heap, 0)
                } else {
                    // @shader meshlet.task meshlet.mesh meshlet.frag
                    vk.CmdBindDescriptorSets(cmd, meshlet_pipeline.bind_point, meshlet_pipeline.layout, 0, 1, &textures_descriptor_set, 0, nil)
                }
                
                vk.CmdPushConstants(cmd, meshlet_pipeline.layout, meshlet_pipeline.shader_stages, 0, size_of(vk.DeviceAddress), &draw_globals_gpu)
                
                // @api it would be way nicer to be able to combine the address of a buffer with the offset directly, removing two arguments.
                // But I dont know how to then get back to the buffer and offset for vulkans api. :(
                gpu_draw_meshlets_indirect_count(cmd, draw_command_buffer, draw_command_count.address, auto_cast len(draws), size_of(Draw_Command), offset_of(Draw_Command, command), 0)
            
            gpu_profile_zone_end()
            gpu_labeled_region_end(cmd)
            
            if print_profile_and_stats {
                vk.CmdEndQuery(cmd, stats_pool, 0)
            }
            
        gpu_end_render_pass(cmd)
        gpu_labeled_region_end(cmd)
        gpu_profile_zone_end()
        
        ////////////////////////////////////////////////
        
        // :OcclusionCull: the barrier before the depth pyramid was missing the barrier for the pyramid.image itself (see https://youtu.be/Ka30T6BMdhI?list=PLOU0IFZHP8dDap0WO7_IwOzgITq3ZUZsy&t=11592)
        
        pipeline_barrier_begin()
            add_image_barrier_transition_from_last(&stuff.depth_buffer, { .COMPUTE_SHADER }, { .SHADER_READ }, .SHADER_READ_ONLY_OPTIMAL, { .DEPTH })
            add_image_barrier(&stuff.depth_pyramid, {}, {}, .UNDEFINED,  { .COMPUTE_SHADER }, { .SHADER_WRITE }, .GENERAL)
        pipeline_barrier_end(cmd)
        
        ////////////////////////////////////////////////
        
        gpu_profile_zone_begin("depth pyramid building")
        gpu_labeled_region_begin(cmd, "depth pyramid building", {0.4, 0.8, 0, 1.0})
        
        gpu_set_pipeline(cmd, depth_pipeline)
            
            updates: [dynamic; 32] DescriptorUpdateData
            prev_mip: ^Depth_Pyramid_Mip
            for &mip, mip_level in stuff.depth_pyramid_mips {
                // @shaders depth_reduce.comp
                
                clear(&updates)
                append(&updates, DescriptorUpdateData { image = { 
                    stuff.depth_sampler,
                    mip_level == 0 ? stuff.depth_buffer.view                   : prev_mip.view,
                    mip_level == 0 ? stuff.depth_buffer.last_transition.layout : .GENERAL,
                } })
                append(&updates, DescriptorUpdateData { image = { stuff.depth_sampler, mip.view, .GENERAL } })
                vk.CmdPushDescriptorSetWithTemplate(cmd, depth_pipeline.update_template, depth_pipeline.layout, 0, raw_data(&updates))
                
                prev_mip = &mip
                
                depth_globals_cpu, depth_globals_gpu := bump_allocate_type(bump, Depth_Globals)
                depth_globals_cpu^ = Depth_Globals { size = cast(v2) mip.size }
                
                gpu_dispatch(cmd, &depth_globals_gpu, get_group_count(depth_reduce_shader, **mip.size))
                
                pipeline_barrier_begin()
                    add_image_barrier_transition_from_last(&stuff.depth_pyramid, { .COMPUTE_SHADER }, { .SHADER_READ }, .GENERAL)
                pipeline_barrier_end(cmd, { .BY_REGION })
            }
        
        gpu_labeled_region_end(cmd)
        gpu_profile_zone_end()
        
        ////////////////////////////////////////////////
        
        pipeline_barrier_begin()
            add_image_barrier_transition_from_last(&stuff.depth_buffer, {.EARLY_FRAGMENT_TESTS }, { .DEPTH_STENCIL_ATTACHMENT_READ, .DEPTH_STENCIL_ATTACHMENT_WRITE }, .ATTACHMENT_OPTIMAL, { .DEPTH })
        pipeline_barrier_end(cmd)
        
        ////////////////////////////////////////////////
        
        gpu_profile_zone_begin("rendering late pass")
        gpu_labeled_region_begin(cmd, "rendering late pass", {0.6, 0.1, 07, 1.0})
        render(&gpu, cmd, stuff.color_buffer, stuff.depth_buffer, {}, early = false)
            
        gpu_end_render_pass(cmd)
        gpu_labeled_region_end(cmd)
        gpu_profile_zone_end()
        
        ////////////////////////////////////////////////
        
        gpu_profile_zone_begin("copy to swapchain")
        
            pipeline_barrier_begin()
                add_image_barrier(&gpu.swapchain_images[gpu.image_index], { .COLOR_ATTACHMENT_OUTPUT }, {}, .UNDEFINED, { .TRANSFER }, { .TRANSFER_WRITE }, .TRANSFER_DST_OPTIMAL)
                if !debug.display_pyramid {
                    add_image_barrier_transition_from_last(&stuff.color_buffer, { .TRANSFER }, { .TRANSFER_READ }, .TRANSFER_SRC_OPTIMAL)
                } else {
                    add_image_barrier_transition_from_last(&stuff.depth_pyramid, { .TRANSFER }, { .TRANSFER_READ }, .TRANSFER_SRC_OPTIMAL)
                }
            pipeline_barrier_end(cmd)
                
            destination := gpu.swapchain_images[gpu.image_index]
            if !debug.display_pyramid {
                vk.CmdCopyImage(cmd, stuff.color_buffer.image, stuff.color_buffer.last_transition.layout, destination.image, destination.last_transition.layout, 1, &vk.ImageCopy {
                    srcSubresource = { aspectMask = { .COLOR }, layerCount = 1 },
                    dstSubresource = { aspectMask = { .COLOR }, layerCount = 1 },
                    extent         = { gpu.swapchain_size.x, gpu.swapchain_size.y, 1 },
                })
            } else {
                source := stuff.depth_pyramid
                
                mip_size  := cast(iv2) stuff.depth_pyramid_mips[debug.display_pyramid_mip_level].size
                dest_size := cast(iv2) gpu.swapchain_size
                
                vk.CmdBlitImage(cmd, source.image, source.last_transition.layout, destination.image, destination.last_transition.layout, 1, &vk.ImageBlit {
                    srcSubresource = { aspectMask = { .COLOR }, layerCount = 1, mipLevel = cast(u32) debug.display_pyramid_mip_level },
                    dstSubresource = { aspectMask = { .COLOR }, layerCount = 1 },
                    srcOffsets = { {0, 0, 0}, {mip_size.x, mip_size.y,   1}},
                    dstOffsets = { {0, 0, 0}, {dest_size.x, dest_size.y, 1}},
                }, .NEAREST)
            }
            
            pipeline_barrier_begin()
                add_image_barrier_transition_from_last(&gpu.swapchain_images[gpu.image_index], {}, {}, .PRESENT_SRC_KHR)
            pipeline_barrier_end(cmd)
        
        gpu_profile_zone_end()
        
        ////////////////////////////////////////////////
        
        gpu_profile_frame_end()
        
        check(vk.EndCommandBuffer(cmd))
        
        ////////////////////////////////////////////////
        
        // @cleanup dont pass the frameindex, this is a place that could cause mistakes
        end_of_frame_submit(&gpu, gpu.general_queue, frame_semaphore, next_frame, frame_index, &cmd)
        present_the_queue(&gpu, gpu.general_queue)
        next_frame += 1
        
        ////////////////////////////////////////////////
        
        {
            gpu_profile_collate_times(&gpu, gpu.device, print_profile_and_stats)
            
            gpu_delta  := gpu_profile_get_zone("frame").total_time_with_children
            cull_delta := gpu_profile_get_zone("culling").total_time
            
            debug.cpu_time  = time_smoothed_blend(delta_time_64, debug.cpu_time, delta_time_64)
            debug.cull_time = time_smoothed_blend(delta_time_64, debug.cull_time, cull_delta)
            // this might have happened when a validation error occurred, causing the smooth value to be messed for a very long time
            if gpu_delta >= 0 {
                debug.gpu_time = time_smoothed_blend(delta_time_64, debug.gpu_time, gpu_delta)
            }
            
            view :: proc (seconds: f64) -> time.Duration {
                return time.duration_round(cast(time.Duration) (seconds * cast(f64) time.Second), 1 * time.Microsecond)
            }
            
            extra: string
            if debug.display_pyramid {
                extra = fmt.tprintf(", displaying depth mip level %v", debug.display_pyramid_mip_level)
            }
            title := fmt.ctprintf("cpu time: %.3v, gpu time: %.3v, cull time: %.3v, culling %v, level of detail %v%v",
                view(debug.cpu_time), 
                view(debug.gpu_time), 
                view(debug.cull_time), 
                debug.culling_enabled ? "on" : "off",
                debug.lod_enabled     ? "on" : "off",
                extra,
            )
            // @todo(viktor): how can we record how many triangles we have rendered after culling?
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
    gpu_free(&gpu, draw_command_buffer)
    gpu_free(&gpu, draw_command_count)
    
    for &bump in frame_bump_allocators {
        bump_allocator_delete(&gpu, &bump)
    }
    
    destroy_pipeline(&gpu, meshlet_pipeline)
    destroy_pipeline(&gpu, cull_pipeline)
    destroy_pipeline(&gpu, depth_pipeline)
    
    for texture in textures {
        gpu_destroy_texture_view(&gpu, texture.view)
        gpu_free_image(&gpu, texture)
    }
    
    delete_stuff(&gpu, &stuff, final = true)
    
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

render :: proc (gpu: ^Gpu, cmd: vk.CommandBuffer, color_buffer, depth_buffer: Image, clear_color: v4, early: bool) {
    desc := Render_Pass_Desc {
        // :ReversedZ: 0 is the maximal value
        depth_target = { texture = depth_buffer, load_op = early ? .CLEAR : .LOAD, store_op = early ? .STORE : .DONT_CARE, clear_depth = 0 }, 
        color_targets = {
            { texture = color_buffer, load_op = early ? .CLEAR : .LOAD, store_op = .STORE, clear_color = clear_color }
        }, 
        
    }
    gpu_begin_render_pass(gpu, cmd, desc)
}

////////////////////////////////////////////////

recreate_stuff :: proc (gpu: ^Gpu, stuff: ^Stuff_With_The_Same_Lifetime_As_The_Swapchain) {
    delete_stuff(gpu, stuff)
    
    if stuff.depth_sampler == 0 {
        stuff.depth_sampler = create_sampler(gpu, .NEAREST, .NEAREST)
    }
    
    // Ensures that all reductions are at most 2x2 which makes sure they are conservative.
    pyramid_size := uv2{previous_power_of_two(gpu.swapchain_size.x), previous_power_of_two(gpu.swapchain_size.y)} 
    // Each mip level is a quarter of the size of the previous, as we half both dimensions each time.
    mip_count := 1 + max(integer_log2(pyramid_size.x), integer_log2(pyramid_size.y))
    
    
    stuff.depth_pyramid = gpu_allocate_texture(gpu, default_texture_desc(size = {pyramid_size.x, pyramid_size.y, 1}, format = .R32_SFLOAT, mip_count = mip_count, usage = { .SAMPLED, .STORAGE, .TRANSFER_SRC }))
    // :Stencil: add the .STENCIL mask bit
    stuff.depth_buffer = gpu_allocate_texture(gpu, default_texture_desc(size = {gpu.swapchain_size.x, gpu.swapchain_size.y, 1}, format = stuff.depth_buffer.format, usage = { .DEPTH_STENCIL_ATTACHMENT, .SAMPLED }))
    stuff.color_buffer = gpu_allocate_texture(gpu, default_texture_desc(size = {gpu.swapchain_size.x, gpu.swapchain_size.y, 1}, format = gpu.swapchain_format,      usage = { .COLOR_ATTACHMENT, .TRANSFER_SRC }))
    
    for i in 0..<mip_count {
        mip := append_into(&stuff.depth_pyramid_mips)
        mip.view = gpu_create_texture_view(gpu, stuff.depth_pyramid, i, 1, { .COLOR })
        mip.size = pyramid_size
        mip.size.x >>= i
        mip.size.y >>= i
        mip.size = vec_max(mip.size, 1)
    }
    
    stuff.depth_buffer.view = gpu_create_texture_view(gpu, stuff.depth_buffer, 0, 1, { .DEPTH })
    stuff.color_buffer.view = gpu_create_texture_view(gpu, stuff.color_buffer, 0, 1, { .COLOR })
}

delete_stuff :: proc (gpu: ^Gpu, stuff: ^Stuff_With_The_Same_Lifetime_As_The_Swapchain, final := false) {
    gpu_free_image(gpu, stuff.depth_pyramid)
    
    gpu_free_image(gpu, stuff.depth_buffer)
    gpu_free_image(gpu, stuff.color_buffer)
    gpu_destroy_texture_view(gpu, stuff.depth_buffer.view)
    gpu_destroy_texture_view(gpu, stuff.color_buffer.view)
    
    for &it in stuff.depth_pyramid_mips {
        gpu_destroy_texture_view(gpu, it.view)
    }
    clear(&stuff.depth_pyramid_mips)
    
    if final {
        // @todo(viktor): make gpu_destroy_sampler
        vk.DestroySampler(gpu.device, stuff.depth_sampler, nil)
    }
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