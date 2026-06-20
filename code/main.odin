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

VSync :: true when !Optimized else false

MaxFramesInFlight :: 2

////////////////////////////////////////////////

Frame :: struct {
    draw_globals: Push_Constant(Draw_Globals),
    cull_globals: Push_Constant(Cull_Globals),
    
    command_buffer: vk.CommandBuffer,
    image_aquired:  vk.Semaphore,
}

Push_Constant :: struct ($T: typeid) {
    gpu: Buffer,
    cpu:    ^T,
}

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

////////////////////////////////////////////////

// @shader meshlet.task
TaskWidth :: 32

// @shader meshlet.mesh
MaxVertices  :: 64
MaxTriangles :: 84

// @shader cull.comp
Cull_Globals :: struct #all_or_none {
    frustum_planes: [6] v4,
    draw:               vk.DeviceAddress "Draw draw_buffer",
    mesh:               vk.DeviceAddress "Mesh mesh_buffer",
    draw_command:       vk.DeviceAddress "Draw_Command draw_command_buffer",
    draw_command_count: vk.DeviceAddress "uint draw_command_count",

    // @cleanup
    camera_p: v3,
    draw_count:              u32,
    
    frustum_culling_enabled: b32,
    lod_enabled:             b32,
}

// @shader
Draw_Globals :: struct {
    view:       m4,
    projection: m4,
    light_pos:  [4] v4,
}

// @shader
Draw :: struct {
    orientation: q32,
    p:           v3,
    scale:       f32,
    
    mesh_index:    u32,
    vertex_offset: u32,
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
    // _pad: u32, // @cleanup it seems the buffer is not correctly written to by the cull.comp shader. the values assuming another padding byte, which the cpu did not assume. CmdDrawMeshTasksIndirectCountEXT then failed to read the correct values as it was given the cpu's alignments and offsets.
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
    
    check(sdl.InitSubSystem({ .VIDEO }))
    defer sdl.QuitSubSystem({ .VIDEO })
    
    window := sdl.CreateWindow("How to Vulkan", 1280, 720, sdl.WINDOW_VULKAN | sdl.WINDOW_RESIZABLE)
    check(window != nil)
    defer sdl.DestroyWindow(window)
    
    ////////////////////////////////////////////////
    
    ips := create_instance_physical_device_and_surface(window, cast(pmm) sdl.Vulkan_GetVkGetInstanceProcAddr())
    
    device, queue, frames, command_pool := create_device_queue_frames_and_command_pool_and_init_gpu_allocator(ips)
    
    ////////////////////////////////////////////////
    
    swapchain: Swapchain
    
    swapchain.format              = get_swapchain_format(ips)
    swapchain.depth_buffer.format = get_depth_buffer_format(ips)
    
    recreate_swapchain(ips, device, sdl_get_window_size(window), &swapchain)
    
    ////////////////////////////////////////////////
    
    // @todo(viktor): currently all are allocated to be host visible, so that we can simplify copying into them.
    // Rethink if any of these should be copied to device_local memory
    vertex_buffer,       vb_view  := gpu_make_buffer([] Vertex,    256 * Megabyte / size_of(Vertex),  { .STORAGE_BUFFER })
    meshlet_buffer,      mlb_view := gpu_make_buffer([] Meshlet,   256 * Megabyte / size_of(Meshlet), { .STORAGE_BUFFER })
    meshlet_data_buffer, mdb_view := gpu_make_buffer([] u32,       256 * Megabyte / size_of(u32),     { .STORAGE_BUFFER })
    draw_buffer,         db_view  := gpu_make_buffer([] Draw,      256 * Megabyte / size_of(Draw),    { .STORAGE_BUFFER, .SHADER_DEVICE_ADDRESS })
    mesh_buffer,         mb_view  := gpu_make_buffer([] Mesh,      256 * Megabyte / size_of(Mesh),    { .STORAGE_BUFFER, .SHADER_DEVICE_ADDRESS })
    // @todo(viktor): this buffer is never seen by the cpu, its filled by compute and used by task+mesh shader
    draw_command_buffer, dcb_view := gpu_make_buffer([] Draw_Command, 256 * Megabyte / size_of(Draw_Command), { .STORAGE_BUFFER, .INDIRECT_BUFFER, .SHADER_DEVICE_ADDRESS })
    draw_command_count_buffer, dccb_view := gpu_make_buffer_type(u32, { .STORAGE_BUFFER, .TRANSFER_DST, .INDIRECT_BUFFER, .SHADER_DEVICE_ADDRESS })
    
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
    
    textures: [3] Image
    texture_descriptors: [len(textures)] vk.DescriptorImageInfo
    
    {
        // @cleanup to do the copy into gpu memory ourselves, we need the tiling to be .LINEAR and not .OPTIMAL, 
        // but in that case we cannot specify any mip_levels. :(
        for &texture, index in textures {
            filename := fmt.tprintf("tutorial/suzanne%v.ktx", index)
            
            loaded_texture := load_ktx_texture(filename, context.temp_allocator)
            
            texture = gpu_make_image({loaded_texture.width, loaded_texture.height}, loaded_texture.format, { .TRANSFER_DST, .SAMPLED }, { .COLOR }, mip_levels = loaded_texture.mip_levels)
            
            source_buffer, source_buffer_data := gpu_make_buffer_slice([] u8, len(loaded_texture.data), { .TRANSFER_SRC })
            defer gpu_delete(source_buffer)
            
            copy(source_buffer_data, loaded_texture.data)
            
            ////////////////////////////////////////////////
            
            fence_once := create_fence(device)
            defer vk.DestroyFence(device, fence_once, nil)
            
            cb_once: vk.CommandBuffer
            cb_once_allocate_info := vk.CommandBufferAllocateInfo {
                sType = .COMMAND_BUFFER_ALLOCATE_INFO,
                commandPool        = command_pool,
                commandBufferCount = 1,
            }
            check(vk.AllocateCommandBuffers(device, &cb_once_allocate_info, &cb_once))
            
            cb_once_begin_info := vk.CommandBufferBeginInfo {
                sType = .COMMAND_BUFFER_BEGIN_INFO,
                flags = { .ONE_TIME_SUBMIT },
            }
            check(vk.BeginCommandBuffer(cb_once, &cb_once_begin_info))
            
            begin_pipeline_barrier()
                add_image_barrier(&texture, {}, {}, .UNDEFINED, { .TRANSFER }, { .TRANSFER_WRITE }, .TRANSFER_DST_OPTIMAL)
            end_pipeline_barrier(cb_once)
            
            copy_regions := make([dynamic] vk.BufferImageCopy, context.temp_allocator)
            for level in 0..<loaded_texture.mip_levels {
                mip_offset: uint = loaded_texture.mip_offsets[level]
                
                append(&copy_regions, vk.BufferImageCopy {
                    bufferOffset = auto_cast mip_offset,
                    imageSubresource = { aspectMask = { .COLOR }, mipLevel = level, layerCount = 1 },
                    imageExtent = { width = loaded_texture.width >> level, height = loaded_texture.height >> level, depth = 1 },
                })
            }
            
            vk.CmdCopyBufferToImage(cb_once, source_buffer.buffer, texture.image, .TRANSFER_DST_OPTIMAL, auto_cast len(copy_regions), raw_data(copy_regions))
            
            begin_pipeline_barrier()
                add_image_barrier_transition_from_last(&texture, { .FRAGMENT_SHADER }, { .SHADER_READ }, .READ_ONLY_OPTIMAL)
            end_pipeline_barrier(cb_once)
            
            check(vk.EndCommandBuffer(cb_once))
            
            once_submit_info := vk.SubmitInfo {
                sType = .SUBMIT_INFO,
                commandBufferCount = 1,
                pCommandBuffers = &cb_once,
            }
            
            check(vk.QueueSubmit(queue, 1, &once_submit_info, fence_once))
            
            check(vk.WaitForFences(device, 1, &fence_once, waitAll = true, timeout = MaxTimeout))
            
            sampler_create_info := vk.SamplerCreateInfo {
                sType = .SAMPLER_CREATE_INFO,
                magFilter  = .LINEAR,
                minFilter  = .LINEAR,
                mipmapMode = .LINEAR,
                anisotropyEnable = true,
                maxAnisotropy = 8,
                maxLod = cast(f32) loaded_texture.mip_levels,
            }
            
            check(vk.CreateSampler(device, &sampler_create_info, nil, &texture.sampler))
            defer_destroy(vk.DestroySampler, texture.sampler)
            
            texture_descriptors[index] = vk.DescriptorImageInfo{ sampler = texture.sampler, imageView = texture.view, imageLayout = .READ_ONLY_OPTIMAL }
        }
    }
    
    ////////////////////////////////////////////////
    
    // @todo put all buffer addresses into the push constant and remove these bindings
    // @shader needs to match the bindings in shaders
    GraphicsStorageBufferCount :: 6
    
    graphics_descriptor_set_layout: vk.DescriptorSetLayout
    {
        bindings := [GraphicsStorageBufferCount] vk.DescriptorSetLayoutBinding {
            { // draw
                binding = 0,
                descriptorType  = .STORAGE_BUFFER,
                descriptorCount = 1,
                stageFlags      = { .MESH_EXT, .TASK_EXT },
            },
            { // mesh
                binding = 1,
                descriptorType  = .STORAGE_BUFFER,
                descriptorCount = 1,
                stageFlags      = { .TASK_EXT },
            },
            { // meshlet
                binding = 2,
                descriptorType  = .STORAGE_BUFFER,
                descriptorCount = 1,
                stageFlags      = { .MESH_EXT, .TASK_EXT },
            },
            { // meshlet data
                binding = 3,
                descriptorType  = .STORAGE_BUFFER,
                descriptorCount = 1,
                stageFlags      = { .MESH_EXT, .TASK_EXT },
            },
            { // vertex
                binding = 4,
                descriptorType  = .STORAGE_BUFFER,
                descriptorCount = 1,
                stageFlags      = { .MESH_EXT },
            },
            { // draw_command
                binding = 5,
                descriptorType  = .STORAGE_BUFFER,
                descriptorCount = 1,
                stageFlags      = { .TASK_EXT },
            },
        }
        
        create_info := vk.DescriptorSetLayoutCreateInfo {
            sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            flags        = { .PUSH_DESCRIPTOR },
            bindingCount = len(bindings),
            pBindings    = &bindings[0],
        }
        
        check(vk.CreateDescriptorSetLayout(device, &create_info, nil, &graphics_descriptor_set_layout))
        defer_destroy(vk.DestroyDescriptorSetLayout, graphics_descriptor_set_layout)
    }
    
    // @shader cull.comp
    ComputeStorageBufferCount :: 0
    
    compute_descriptor_set_layout: vk.DescriptorSetLayout
    {
        bindings := [ComputeStorageBufferCount] vk.DescriptorSetLayoutBinding {
        }
        
        create_info := vk.DescriptorSetLayoutCreateInfo {
            sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            flags        = { .PUSH_DESCRIPTOR },
            bindingCount = len(bindings),
            pBindings    = raw_data(bindings[:]),
        }
        
        check(vk.CreateDescriptorSetLayout(device, &create_info, nil, &compute_descriptor_set_layout))
        defer_destroy(vk.DestroyDescriptorSetLayout, compute_descriptor_set_layout)
    }
    
    ////////////////////////////////////////////////
    
    textures_descriptor_set_layout: vk.DescriptorSetLayout
    textures_descriptor_set:        vk.DescriptorSet
    textures_descriptor_pool:       vk.DescriptorPool
    {
        desc_layout_textures_create_info := vk.DescriptorSetLayoutCreateInfo {
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
        
        check(vk.CreateDescriptorSetLayout(device, &desc_layout_textures_create_info, nil, &textures_descriptor_set_layout))
        defer_destroy(vk.DestroyDescriptorSetLayout, textures_descriptor_set_layout)
        
        desc_pool_create_info := vk.DescriptorPoolCreateInfo {
            sType = .DESCRIPTOR_POOL_CREATE_INFO,
            maxSets       = 1,
            poolSizeCount = 1,
            pPoolSizes    = &vk.DescriptorPoolSize {
                type = .COMBINED_IMAGE_SAMPLER,
                descriptorCount = len(textures),
            },
        }
        
        check(vk.CreateDescriptorPool(device, &desc_pool_create_info, nil, &textures_descriptor_pool))
        defer_destroy(vk.DestroyDescriptorPool, textures_descriptor_pool)
        
        variable_desc_count := cast(u32) len(textures)
        
        textures_desc_set_allocate_info := vk.DescriptorSetAllocateInfo {
            sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
            pNext = &vk.DescriptorSetVariableDescriptorCountAllocateInfo {
                sType = .DESCRIPTOR_SET_VARIABLE_DESCRIPTOR_COUNT_ALLOCATE_INFO,
                descriptorSetCount = 1,
                pDescriptorCounts  = &variable_desc_count,
            },
            descriptorPool     = textures_descriptor_pool,
            descriptorSetCount = 1,
            pSetLayouts        = &textures_descriptor_set_layout,
        }
        
        check(vk.AllocateDescriptorSets(device, &textures_desc_set_allocate_info, &textures_descriptor_set))
        
        write_desc_set := vk.WriteDescriptorSet {
            sType = .WRITE_DESCRIPTOR_SET,
            dstSet = textures_descriptor_set,
            dstBinding = 0,
            descriptorCount = cast(u32) len(texture_descriptors),
            descriptorType = .COMBINED_IMAGE_SAMPLER,
            pImageInfo = &texture_descriptors[0],
        }
        vk.UpdateDescriptorSets(device, 1, &write_desc_set, 0, nil)
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
    
    draw_cull_shader := init_shader_and_watchers(&watchers, watchers_make(&watchers, "shaders/common.glslh"), "shaders/draw_cull.comp", shader_allocator)
    
    ////////////////////////////////////////////////
    
    timeline_semaphore := create_semaphore(device, timeline_initial_value = MaxFramesInFlight)
    defer_destroy(vk.DestroySemaphore, timeline_semaphore)
    
    ////////////////////////////////////////////////
    
    gpu_profile_make_query_pool(device)
    
    ////////////////////////////////////////////////
    
    stats_pool: vk.QueryPool
    stats_bits := vk.QueryPipelineStatisticFlags {
        .FRAGMENT_SHADER_INVOCATIONS,
        .COMPUTE_SHADER_INVOCATIONS,
        .TASK_SHADER_INVOCATIONS_EXT,
        .MESH_SHADER_INVOCATIONS_EXT,
    }
    
    {
        StatsSize :: 1
        create_info := vk.QueryPoolCreateInfo {
            sType = .QUERY_POOL_CREATE_INFO,
            queryType = .PIPELINE_STATISTICS,
            pipelineStatistics = stats_bits,
            queryCount = cast(u32) card(stats_bits),
        }
        check(vk.CreateQueryPool(device, &create_info, nil, &stats_pool))
        defer_destroy(vk.DestroyQueryPool, stats_pool)
    }
    
    ////////////////////////////////////////////////
    
    // @speed is a pipeline cache still a good optimization?
    pipeline_cache: vk.PipelineCache = 0
    
    meshlet_pipeline: Pipeline
    cull_pipeline:    Pipeline
    
    ////////////////////////////////////////////////
    
    draw_globals: Draw_Globals
    
    for &pos, index in draw_globals.light_pos {
        t := clamp_01_to_range(cast(f32) 0, cast(f32) len(draw_globals.light_pos), cast(f32) index)
        pos.xyz = v3{0, -10, 10}
        pos.xz += arm(t * Tau)
    }
    
    cam_pos := v3{ 0, 0, 0}
    object_rotation: v3
    quit: bool
    last_time := time.tick_now()
    
    absolute_frame_index: u64
    image_index: u32
    next_signal_value: u64 = MaxFramesInFlight + 1
    should_recreate_swapchain: bool
    
    time_smoothed_blend :: proc (frame_time: f64, last_value: f64, value: f64) -> f64 {
        // @speed We could precompute ks if needed as it only depends on h and frame time, not the smooth itself.
        h :: 3.0 // = the amount of time it takes for the filter to converge to 90% of a fixed input value
        k := power(power(cast(f64) .1, 1 / h), frame_time)
        
        result := linear_blend(value, last_value, k)
        return result
    }
    
    culling_enabled: bool = true
    lod_enabled:     bool = true
    
    cull_delta: f64
    cpu_time: f64
    gpu_time: f64
    for !quit {
        free_all(context.temp_allocator)
        
        ////////////////////////////////////////////////
        
        print_profile: bool
        
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
                case sdl.K_C:     culling_enabled = !culling_enabled
                case sdl.K_L:     lod_enabled = !lod_enabled
                case sdl.K_P:     print_profile = true
                }
            case .KEY_UP:
                if event.key.key == sdl.K_SPACE {
                    space_down = false
                }
                
            case .MOUSE_WHEEL:
                mouse_wheel_delta = event.wheel.y
                
            case .WINDOW_RESIZED:
                should_recreate_swapchain = true
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
        
        // @todo(viktor): if the window is minimized we can never get it back up and visible
        if should_recreate_swapchain {
            should_recreate_swapchain = false
            
            vk.DeviceWaitIdle(device)
            recreate_swapchain(ips, device, sdl_get_window_size(window), &swapchain)
        }
        
        watchers_check_for_modification(watchers)
        
        if reload_shaders_if_needed(watchers, shader_allocator, &draw_cull_shader) || !pipeline_is_valid(cull_pipeline) {
            cull_pipeline = create_compute_pipeline(device, pipeline_cache, draw_cull_shader, ComputeStorageBufferCount, compute_descriptor_set_layout, cull_pipeline)
        }
        
        if reload_shaders_if_needed(watchers, shader_allocator, meshlet_shaders[:]) || !pipeline_is_valid(meshlet_pipeline) {
            meshlet_pipeline = create_graphics_pipeline(device, pipeline_cache, swapchain, { graphics_descriptor_set_layout, textures_descriptor_set_layout }, meshlet_shaders[:], GraphicsStorageBufferCount, meshlet_pipeline)
        }
        
        ////////////////////////////////////////////////
        
        signal_value := next_signal_value
        next_signal_value += 1
        wait_value := signal_value - MaxFramesInFlight
        
        wait_info := vk.SemaphoreWaitInfo {
            sType = .SEMAPHORE_WAIT_INFO,
            semaphoreCount = 1,
            pSemaphores    = &timeline_semaphore,
            pValues        = &wait_value,
        }
        wait_result := vk.WaitSemaphores(device, &wait_info, MaxTimeout)
        if wait_result == .TIMEOUT {
            should_recreate_swapchain = true
            continue
        }
        check(wait_result)
        
        ////////////////////////////////////////////////
        
        frame := frames[absolute_frame_index % MaxFramesInFlight]
        absolute_frame_index += 1
        
        acquire_result := vk.AcquireNextImageKHR(device, swapchain.swapchain, MaxTimeout, frame.image_aquired, {}, &image_index)
        if acquire_result == .ERROR_OUT_OF_DATE_KHR || acquire_result == .SUBOPTIMAL_KHR {
            should_recreate_swapchain = true
            continue
        }
        check(acquire_result)
        
        ////////////////////////////////////////////////
        
        entropy := seed_random_series(54654)
        when true {
            @(static) draws: [500] Draw
            global_rotation := la.quaternion_from_euler_angles_f32(expand_values(object_rotation * random_unilateral(&entropy, v3)), .XYX)
            for &draw in draws {
                p := random_bilateral(&entropy, v3) * {10, 10, 10} - {0, 0, 20}
                
                draw.p           = p
                draw.scale       = linear_blend(cast(f32) .1, .4, square(random_unilateral(&entropy, f32)))
                rotation        := la.quaternion_angle_axis(random_unilateral(&entropy, f32) * Tau, random_bilateral(&entropy, v3))
                draw.orientation = rotation * global_rotation
                
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
                
                mesh, mesh_index := random_choice_index(&entropy, geometry.meshes[:])
                
                draw.mesh_index    = mesh_index
                draw.vertex_offset = mesh.vertex_offset
            }
        }
        
        copy(db_view, draws[:])
        
        ////////////////////////////////////////////////
        
        projection_reversed_z_infinite_far_plane :: proc (fov_y, aspect_w_h, near_z: f32) -> m4 { // :ReversedZ:
            f := 1 / tan(fov_y / 2)
            x := f / aspect_w_h
            y := f
            n := near_z
            
            result := m4 {
                x,  0,  0,  0,
                0,  y,  0,  0,
                0,  0,  0,  n,
                0,  0, -1,  0,
            }
            
            return result
        }
        
        projection := projection_reversed_z_infinite_far_plane(70 * RadPerDeg, cast(f32) swapchain.size.x / cast(f32) swapchain.size.y, 0.01)
        view       := translate(1, -cam_pos)
        draw_globals.projection = projection
        draw_globals.view       = view
        
        // @todo(viktor): we also need to take the view matrix into account
        draw_distance: f32 = 100
        
        frustum_planes: [6] v4
        if culling_enabled {
            view_projection := projection * view
            cam_forward := v3{0, 0, -1}
            
            frustum_planes[0] = get_row_v4(view_projection, 3) + get_row_v4(view_projection, 0) // x + w < 0
            frustum_planes[1] = get_row_v4(view_projection, 3) - get_row_v4(view_projection, 0) // x - w > 0
            frustum_planes[2] = get_row_v4(view_projection, 3) + get_row_v4(view_projection, 1) // y + w < 0
            frustum_planes[3] = get_row_v4(view_projection, 3) - get_row_v4(view_projection, 1) // y - w > 0
            frustum_planes[4] = get_row_v4(view_projection, 3) - get_row_v4(view_projection, 2) // z - w > 0 -- :ReversedZ:
            // frustum_planes[5] = v4{**cam_forward, draw_distance + dot(cam_forward, cam_pos)}          // :ReversedZ: infinite far plane
            
            for &plane in frustum_planes {
                plane /= length(plane.xyz)
            }
        }
        
        cull_globals := Cull_Globals {
            frustum_planes     = frustum_planes,
            draw               = draw_buffer.address,
            mesh               = mesh_buffer.address,
            draw_command       = draw_command_buffer.address,
            draw_command_count = draw_command_count_buffer.address,
            
            lod_enabled             = cast(b32) lod_enabled,
            frustum_culling_enabled = cast(b32) culling_enabled,
            draw_count              = len(draws),
            camera_p                = cam_pos,
        }
        
        frame.draw_globals.cpu^ = draw_globals
        frame.cull_globals.cpu^ = cull_globals
        
        ////////////////////////////////////////////////
        
        cpu_time = time_smoothed_blend(delta_time_64, cpu_time, delta_time_64)
        
        {
            view :: proc (seconds: f64) -> time.Duration {
                return time.duration_round(cast(time.Duration) (seconds * cast(f64) time.Second), 1 * time.Microsecond)
            }
            
            // @todo(viktor): how can we record how many triangles we have rendered after culling?
            sdl.SetWindowTitle(window, fmt.ctprintf("cpu time: %.3v, gpu time: %.3v, cull time: %.3v, culling %v, level of detail %v", 
                view(cpu_time), 
                view(gpu_time), 
                view(cull_delta), 
                culling_enabled ? "on" : "off",
                lod_enabled     ? "on" : "off",
            ))
        }
        
        ////////////////////////////////////////////////
        
        cb := frame.command_buffer
        check(vk.ResetCommandBuffer(cb, {}))
        
        check(vk.BeginCommandBuffer(cb, &vk.CommandBufferBeginInfo { sType = .COMMAND_BUFFER_BEGIN_INFO, flags = { .ONE_TIME_SUBMIT } }))
        
        vk.ResetQueryPool(device, stats_pool, 0, cast(u32) card(stats_bits))
        
        vk.CmdBeginQuery(cb, stats_pool, 0, {})
        gpu_profile_frame_begin(device, cb)
        
        ////////////////////////////////////////////////
        
        // @todo(viktor): is this barrier/transition before the fill necessary?
        begin_pipeline_barrier()
            add_buffer_barrier(&draw_command_count_buffer, {}, {}, { .TRANSFER }, { .TRANSFER_WRITE })
        end_pipeline_barrier(cb)
        
        vk.CmdFillBuffer(cb, draw_command_count_buffer.buffer, 0, size_of(dccb_view^), 0)
        gpu_profile_zone_begin("culling")
        
        begin_pipeline_barrier()
            // :OcclusionCull: the memory barrier for the depth pyramid had a parameters, but just for the late pass (see https://youtu.be/Ka30T6BMdhI?list=PLOU0IFZHP8dDap0WO7_IwOzgITq3ZUZsy&t=10157)
            add_buffer_barrier(&draw_command_buffer, { .DRAW_INDIRECT, .MESH_SHADER_EXT }, { .INDIRECT_COMMAND_READ, .SHADER_READ }, { .COMPUTE_SHADER }, { .SHADER_WRITE, .SHADER_READ })
            add_buffer_barrier_transition_from_last(&draw_command_count_buffer, { .COMPUTE_SHADER }, { .SHADER_WRITE, .SHADER_READ })
        end_pipeline_barrier(cb)
        
        vk.CmdBindPipeline(cb, .COMPUTE, cull_pipeline.pipeline)
        
        if ComputeStorageBufferCount != 0 {
            // @shader cull.comp
            compute_descriptor_update := [ComputeStorageBufferCount] DescriptorUpdateData {}
            vk.CmdPushDescriptorSetWithTemplate(cb, cull_pipeline.update_template, cull_pipeline.layout, 0, raw_data(compute_descriptor_update[:]))
        }
        
        vk.CmdPushConstants(cb, cull_pipeline.layout, cull_pipeline.shader_stages, 0, size_of(frame.cull_globals.gpu.address), &frame.cull_globals.gpu.address)
        
        draw_count := get_group_count(draw_cull_shader, len(draws))
        vk.CmdDispatch(cb, draw_count, 1, 1)
        
        gpu_profile_zone_end()
        
        gpu_profile_zone_begin("memory barriers")
        
        begin_pipeline_barrier()
            add_buffer_barrier_transition_from_last(&draw_command_buffer, { .DRAW_INDIRECT, .MESH_SHADER_EXT }, { .INDIRECT_COMMAND_READ, .SHADER_READ })
            add_buffer_barrier_transition_from_last(&draw_command_count_buffer, { .DRAW_INDIRECT }, { .INDIRECT_COMMAND_READ })
        end_pipeline_barrier(cb)
        
        ////////////////////////////////////////////////
        
        // :OcclusionCull: the barrier before the depth pyramid was missing the barrier for the pyramid.image itself (see https://youtu.be/Ka30T6BMdhI?list=PLOU0IFZHP8dDap0WO7_IwOzgITq3ZUZsy&t=11592)
        
        begin_pipeline_barrier()
            add_image_barrier(&swapchain.color_buffer, { .BOTTOM_OF_PIPE }, {}, .UNDEFINED, { .COLOR_ATTACHMENT_OUTPUT, .EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS }, { .COLOR_ATTACHMENT_WRITE },         .ATTACHMENT_OPTIMAL)
            add_image_barrier(&swapchain.depth_buffer, { .BOTTOM_OF_PIPE }, {}, .UNDEFINED, { .COLOR_ATTACHMENT_OUTPUT, .EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS }, { .DEPTH_STENCIL_ATTACHMENT_WRITE }, .ATTACHMENT_OPTIMAL, { .DEPTH }) // :Stencil: add .STENCIL to the aspect mask
        end_pipeline_barrier(cb)
        
        gpu_profile_zone_end()
        
        ////////////////////////////////////////////////
        
        begin_rendering(cb, swapchain, swapchain.color_buffer, image_index, {0.07, 0.07, 0.07, 1})
        
        gpu_profile_zone_begin("rendering")
        
        vk.CmdSetViewport(cb, 0, 1, &vk.Viewport {
            x      = 0,
            y      = 0,
            width  = cast(f32) swapchain.size.x,
            height = cast(f32) swapchain.size.y,
            minDepth = 0,
            maxDepth = 1,
        })
        
        vk.CmdSetScissor(cb, 0, 1, &vk.Rect2D { extent = to_extent(swapchain.size) })
        
        gpu_profile_zone_begin("meshlets")
        vk.CmdBindPipeline(cb, .GRAPHICS, meshlet_pipeline.pipeline)
        
        // @shader meshlet pipeline
        graphics_descriptor_update := [GraphicsStorageBufferCount] DescriptorUpdateData {
            { buffer = { draw_buffer.buffer,         0, auto_cast vk.WHOLE_SIZE }},
            { buffer = { mesh_buffer.buffer,         0, auto_cast vk.WHOLE_SIZE }},
            { buffer = { meshlet_buffer.buffer,      0, auto_cast vk.WHOLE_SIZE }},
            { buffer = { meshlet_data_buffer.buffer, 0, auto_cast vk.WHOLE_SIZE }},
            { buffer = { vertex_buffer.buffer,       0, auto_cast vk.WHOLE_SIZE }},
            { buffer = { draw_command_buffer.buffer, 0, auto_cast vk.WHOLE_SIZE }},
        }
        vk.CmdPushDescriptorSetWithTemplate(cb, meshlet_pipeline.update_template, meshlet_pipeline.layout, 0, &graphics_descriptor_update[0])
        
        vk.CmdBindDescriptorSets(cb, .GRAPHICS, meshlet_pipeline.layout, 1, 1, &textures_descriptor_set, 0, nil)
        
        
        vk.CmdPushConstants(cb, meshlet_pipeline.layout, meshlet_pipeline.shader_stages, 0, size_of(frame.draw_globals.gpu.address), &frame.draw_globals.gpu.address)
        vk.CmdDrawMeshTasksIndirectCountEXT(cb, draw_command_buffer.buffer, auto_cast offset_of(Draw_Command, command), draw_command_count_buffer.buffer, 0, len(draws), size_of(Draw_Command))
        gpu_profile_zone_end()
        
        ////////////////////////////////////////////////
        
        vk.CmdEndRendering(cb)
        gpu_profile_zone_end()
        
        gpu_profile_zone_begin("copy to swapchain")
        
        begin_pipeline_barrier()
            add_image_barrier_transition_from_last(&swapchain.color_buffer, { .TRANSFER }, { .TRANSFER_READ }, .TRANSFER_SRC_OPTIMAL)
            add_image_barrier(swapchain.images[image_index], { .COLOR_ATTACHMENT_OUTPUT }, {}, .UNDEFINED, { .TRANSFER }, { .TRANSFER_WRITE }, .TRANSFER_DST_OPTIMAL)
        end_pipeline_barrier(cb)
        
        vk.CmdCopyImage(cb, swapchain.color_buffer.image, .TRANSFER_SRC_OPTIMAL, swapchain.images[image_index], .TRANSFER_DST_OPTIMAL, 1, &vk.ImageCopy {
            srcSubresource = { aspectMask = { .COLOR }, layerCount = 1 },
            dstSubresource = { aspectMask = { .COLOR }, layerCount = 1 },
            extent         = to_extent(swapchain.size, 1),
        })
        
        begin_pipeline_barrier()
            add_image_barrier(swapchain.images[image_index], { .TRANSFER }, { .TRANSFER_WRITE }, .TRANSFER_DST_OPTIMAL, {}, {}, .PRESENT_SRC_KHR)
        end_pipeline_barrier(cb)
        
        gpu_profile_zone_end()
        
        ////////////////////////////////////////////////
        
        gpu_profile_frame_end()
        vk.CmdEndQuery(cb, stats_pool, 0)
        
        vk.EndCommandBuffer(cb)
        
        ////////////////////////////////////////////////
        
        queue_submit(queue, swapchain, frame, image_index, signal_value, timeline_semaphore)
        
        ////////////////////////////////////////////////
        
        present_info := vk.PresentInfoKHR {
            sType = .PRESENT_INFO_KHR,
            waitSemaphoreCount = 1,
            pWaitSemaphores    = &swapchain.render_completes[image_index],
            swapchainCount     = 1,
            pSwapchains        = &swapchain.swapchain,
            pImageIndices      = &image_index,
        }
        
        present_result := vk.QueuePresentKHR(queue, &present_info)
        if present_result == .ERROR_OUT_OF_DATE_KHR {
            should_recreate_swapchain = true
        } else {
            check(present_result)
        }
        
        gpu_profile_collate_times(ips, device, print_profile)
        
        gpu_delta  := gpu_profile_get_zone("frame").total_time_with_children
        cull_delta  = gpu_profile_get_zone("culling").total_time
        // @note(viktor): this might have happened when a validation error occurred, causing the smooth value to be messed for a very long time
        if gpu_delta >= 0 {
            gpu_time = time_smoothed_blend(delta_time_64, gpu_time, gpu_delta)
        }
        
        ////////////////////////////////////////////////
        
        {
            stats_result: [128] u64
            size := cast(int) size_of_slice(stats_result[:])
            query_result := vk.GetQueryPoolResults(device, stats_pool, 0, 1, size, &stats_result[0], size_of(stats_result[0]), { ._64, .WAIT })
            check(query_result)
            
            if print_profile {    
                fmt.println("------------------------------------\nStats:")
                index: int
                for bit in stats_bits { defer index += 1
                    stat_value := stats_result[index]
                    fmt.printfln("  %v = %v", bit, stat_value)
                    
                }
                fmt.printfln("-------------------------------------")
            }
        }
    }
    
    ////////////////////////////////////////////////
    // Cleanup and Shutdown
    
	check(vk.DeviceWaitIdle(device))
    
    for frame in frames {
        gpu_delete(frame.draw_globals.gpu)
        gpu_delete(frame.cull_globals.gpu)
    }
    
    gpu_delete(vertex_buffer)
    gpu_delete(meshlet_buffer)
    gpu_delete(meshlet_data_buffer)
    gpu_delete(mesh_buffer)
    gpu_delete(draw_buffer)
    gpu_delete(draw_command_buffer)
    gpu_delete(draw_command_count_buffer)
    
    destroy_swapchain(device, &swapchain)
    destroy_pipeline(device, meshlet_pipeline)
    destroy_pipeline(device, cull_pipeline)
    
    for texture in textures {
        gpu_delete(texture)
    }
    
    destroy_all_handles(device)
    
	vk.DestroyDevice(device, nil)
    
	vk.DestroySurfaceKHR(ips.instance, ips.surface, nil)
	vk.DestroyInstance(ips.instance, nil)
}

////////////////////////////////////////////////

sdl_get_window_size :: proc (window: ^sdl.Window) -> uv2 {
    result: iv2
    sdl.GetWindowSize(window, &result.x, &result.y)
    return cast(uv2) result
}

////////////////////////////////////////////////

check :: proc { check_vulkan, check_sdl, check_ktx }
check_vulkan :: proc (result: vk.Result, loc := #caller_location) {
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