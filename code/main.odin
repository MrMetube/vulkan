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

// @todo(viktor): should vk.DeviceAddress be part of the buffer, so that it is all in one member
Frame :: struct {
    draw_globals: Push_Constant(Draw_Globals),
    cull_globals: Push_Constant(Cull_Globals),
    
    command_buffer: vk.CommandBuffer,
    image_aquired:  vk.Semaphore,
}

Push_Constant :: struct ($T: typeid) {
    buffer: Buffer,
    cpu:    ^T,
    gpu:    vk.DeviceAddress,
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

Mesh :: struct {
    center: v3,
    radius: f32,
    
    vertex_offset: u32,
    vertex_count:  u32,
    
    meshlet_offset: u32,
    meshlet_count:  u32,
    
    // @note(viktor): just for statistics, might become unused
    triangle_count: u32,
}

////////////////////////////////////////////////

// @volatile task shader
TaskWidth :: 32

// @volatile shaders
MaxVertices  :: 64
MaxTriangles :: 84

// @volatile shaders
Cull_Globals :: struct {
    frustum_planes: [6] v4,
}

// @volatile shaders
Draw_Globals :: struct {
    view:       m4,
    projection: m4,
    light_pos:  [4] v4,
}

// @volatile shaders
Draw :: struct {
    center: v3,
    radius: f32,
    
    vertex_offset:  u32,
    vertex_count:   u32,
    meshlet_offset: u32,
    meshlet_count:  u32,
    
    orientation: q32,
    p:           v3,
    scale:       f32,
}


// @volatile shaders
Draw_Command :: vk.DrawMeshTasksIndirectCommandEXT

// @volatile shaders
Meshlet :: struct #align(16) {
    center: v3,
    radius: f32,
    cone_axis:   [3] i8,
    cone_cutoff: i8,
    
    data_offset:    u32, // data_offset:][:vertexcount
    vertex_count:   u8,
    triangle_count: u8,
}

// @volatile shaders
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
    check_sdl(window != nil)
    defer sdl.DestroyWindow(window)
    
    ////////////////////////////////////////////////
    
    ips := create_instance_physical_device_and_surface(window, cast(pmm) sdl.Vulkan_GetVkGetInstanceProcAddr())
    
    device, queue, frames, command_pool := create_device_queue_frames_and_command_pool_and_init_gpu_allocator(ips)
    
    ////////////////////////////////////////////////
    
    swapchain: Swapchain
    
    swapchain.format    = get_swapchain_format(ips)
    swapchain.depth_buffer.format = get_depth_buffer_format(ips)
    
    recreate_swapchain(ips, device, sdl_get_window_size(window), &swapchain)
    
    ////////////////////////////////////////////////
    
    vertex_buffer,       vb_view  := gpu_make_buffer({ .STORAGE_BUFFER }, [] Vertex,    256 * Megabyte / size_of(Vertex))
    meshlet_buffer,      mb_view  := gpu_make_buffer({ .STORAGE_BUFFER }, [] Meshlet,   256 * Megabyte / size_of(Meshlet))
    meshlet_data_buffer, mdb_view := gpu_make_buffer({ .STORAGE_BUFFER }, [] u32,       256 * Megabyte / size_of(u32))
    draw_buffer,         db_view  := gpu_make_buffer({ .STORAGE_BUFFER }, [] Draw, 256 * Megabyte / size_of(Draw))
    draw_command_buffer, dcb_view := gpu_make_buffer({ .STORAGE_BUFFER, .INDIRECT_BUFFER }, [] Draw_Command, 256 * Megabyte / size_of(Draw_Command))
    
    Mesh_Info :: struct {
        triangle_count: u32,
        meshlet_count:  u32,
    }
    
    geometry: Geometry
    {
        paths := [?] string {
            "tutorial/suzanne.obj",
            "models/bunny.obj",
            "models/lucy_280k.obj",
        }
        
        for path in paths {
            if !load_mesh(&geometry, path, context.temp_allocator) {
                fmt.eprintfln("Failed to load mesh from file `%v`", path)
            }
        }
        
        copy(vb_view,  geometry.vertices[:])
        copy(mb_view,  geometry.meshlets[:])
        copy(mdb_view, geometry.meshlet_data[:])
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
            
            source_buffer, source_buffer_data := gpu_make_buffer({ .TRANSFER_SRC }, [] u8, len(loaded_texture.data))
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
                add_image_barrier(texture.image, {}, .UNDEFINED, { .TRANSFER_WRITE }, .TRANSFER_DST_OPTIMAL)
            end_pipeline_barrier(cb_once, {}, { .TRANSFER })
            
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
                add_image_barrier(texture.image, { .TRANSFER_WRITE }, .TRANSFER_DST_OPTIMAL, { .SHADER_READ }, .READ_ONLY_OPTIMAL)
            end_pipeline_barrier(cb_once, { .TRANSFER }, { .FRAGMENT_SHADER })
            
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
    
    // @volatile needs to match the bindings in shaders
    GraphicsStorageBufferCount :: 4
    
    graphics_descriptor_set_layout: vk.DescriptorSetLayout
    {
        bindings := [GraphicsStorageBufferCount] vk.DescriptorSetLayoutBinding {
            { // draw
                binding = 0,
                descriptorType = .STORAGE_BUFFER,
                descriptorCount = 1,
                stageFlags = { .MESH_EXT, .TASK_EXT },
            },
            { // meshlet
                binding = 1,
                descriptorType = .STORAGE_BUFFER,
                descriptorCount = 1,
                stageFlags = { .MESH_EXT, .TASK_EXT },
            },
            { // meshlet data
                binding = 2,
                descriptorType = .STORAGE_BUFFER,
                descriptorCount = 1,
                stageFlags = { .MESH_EXT, .TASK_EXT },
            },
            { // vertex
                binding = 3,
                descriptorType = .STORAGE_BUFFER,
                descriptorCount = 1,
                stageFlags = { .MESH_EXT },
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
    
    // @volatile needs to match the bindings in shaders
    ComputeStorageBufferCount :: 2
    
    compute_descriptor_set_layout: vk.DescriptorSetLayout
    {
        bindings := [ComputeStorageBufferCount] vk.DescriptorSetLayoutBinding {
            { // draw
                binding = 0,
                descriptorType = .STORAGE_BUFFER,
                descriptorCount = 1,
                stageFlags = { .MESH_EXT, .TASK_EXT, .COMPUTE },
            },
            { // draw_command
                binding = 1,
                descriptorType = .STORAGE_BUFFER,
                descriptorCount = 1,
                stageFlags = { .TASK_EXT, .COMPUTE },
            },
        }
        
        create_info := vk.DescriptorSetLayoutCreateInfo {
            sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            flags        = { .PUSH_DESCRIPTOR },
            bindingCount = len(bindings),
            pBindings    = &bindings[0],
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
    
    // @todo(viktor): if we want to only reload specific shaders, we need a general purpose allocator.
    shader_allocator := context.allocator
    
    shader_files := make([dynamic] string, context.temp_allocator)
    get_all_files_with_extension(&shader_files, ".", shader_allocator, ".frag", ".mesh", ".task")
    
    watcher_allocator := context.allocator
    watchers := make([dynamic] Watcher, watcher_allocator)
    
    common_watcher_id := watchers_make(&watchers, "common.h")
    
    shaders: [dynamic] Shader
    for file in shader_files {
        shader := init_shader_and_watchers(&watchers, common_watcher_id, file, shader_allocator)
        append(&shaders, shader)
    }
    
    draw_command_compute_shader := init_shader_and_watchers(&watchers, common_watcher_id, "draw_command.comp", shader_allocator)
    
    ////////////////////////////////////////////////
    
    timeline_semaphore := create_semaphore(device, timeline_initial_value = MaxFramesInFlight)
    defer_destroy(vk.DestroySemaphore, timeline_semaphore)
    
    ////////////////////////////////////////////////
    
    QueryPoolSize :: 128
    query_pool: vk.QueryPool
    {
        create_info := vk.QueryPoolCreateInfo {
            sType = .QUERY_POOL_CREATE_INFO,
            queryType = .TIMESTAMP,
            queryCount = QueryPoolSize,
        }
        check(vk.CreateQueryPool(device, &create_info, nil, &query_pool))
        defer_destroy(vk.DestroyQueryPool, query_pool)
    }
    
    ////////////////////////////////////////////////
    
    // @speed is a pipeline cache still a good optimization?
    pipeline_cache: vk.PipelineCache = 0
    
    pipeline:         Pipeline
    compute_pipeline: Pipeline
    
    ////////////////////////////////////////////////
    
    draw_globals: Draw_Globals
    
    for &pos, index in draw_globals.light_pos {
        t := clamp_01_to_range(cast(f32) 0, cast(f32) len(draw_globals.light_pos), cast(f32) index)
        pos.xyz = v3{0, -10, 10}
        pos.xz += arm(t * Tau)
    }
    
    cam_pos := v3{ 0, 0, -6 }
    object_rotation: v3
    quit: bool
    last_time := time.tick_now()
    
    absolute_frame_index: u64
    image_index: u32
    next_signal_value: u64 = MaxFramesInFlight + 1
    should_recreate_swapchain: bool
    
    Smooth :: struct {
        value:      f64,
        last_value: f64,
    }

    smooth_update :: proc (frame_time: f64, smooth: ^Smooth, value: f64) {
        // @speed We could precompute ks if needed as it only depends on h and frame time, not the smooth itself.
        h :: 5.0 // = the amount of time it takes for the filter to converge to 90% of a fixed input value
        k := power(power(cast(f64) .1, 1 / h), frame_time)
        
        smooth.value = linear_blend(value, smooth.last_value, k)
        smooth.last_value = smooth.value
    }
    
    cull_delta: f64
    
    cpu_time: Smooth
    gpu_time: Smooth
    for !quit {
        free_all(context.temp_allocator)
        
        ////////////////////////////////////////////////
        
        // @todo(viktor): we currently include the time sdl.PollEvents and therefore windows window events take, which can just block us.
        current_time := time.tick_now()
        delta_tick := time.tick_diff(last_time, current_time)
        delta_time_64 := time.duration_seconds(delta_tick)
        delta_time := cast(f32) delta_time_64
        last_time = current_time
        
        ////////////////////////////////////////////////
        
        mouse_delta: v2
        @(static) left_down: bool
        @(static) space_down: bool
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
                if event.key.key == sdl.K_SPACE {
                    space_down = true
                }
            case .KEY_UP:
                if event.key.key == sdl.K_SPACE {
                    space_down = false
                }
                
            case .MOUSE_WHEEL:
                cam_pos.z += event.wheel.y * 10 * delta_time
                
            case .WINDOW_RESIZED:
                should_recreate_swapchain = true
            }
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
        
        any_shader_was_changed: bool
        for &shader in shaders {
            if watcher_modified(watchers, shader.source_watcher, shader.common_watcher) {
                result, ok := compile_and_load_shader(shader.input, shader_allocator, old = &shader)
                if !ok { continue }
                
                shader = result
                any_shader_was_changed = true
                watcher_set_up_to_date(watchers, shader.source_watcher, shader.common_watcher)
            }
        }
        compute_shader_was_changed: bool
        if watcher_modified(watchers, draw_command_compute_shader.source_watcher, draw_command_compute_shader.common_watcher) {
            result, ok := compile_and_load_shader(draw_command_compute_shader.input, shader_allocator, old = &draw_command_compute_shader)
            if ok {
                draw_command_compute_shader = result
                watcher_set_up_to_date(watchers, draw_command_compute_shader.source_watcher, draw_command_compute_shader.common_watcher)
                
                compute_shader_was_changed = true
            }
        }
        
        if compute_shader_was_changed || !pipeline_is_valid(compute_pipeline) {
            compute_pipeline = create_compute_pipeline(device, pipeline_cache, draw_command_compute_shader, ComputeStorageBufferCount, compute_descriptor_set_layout, compute_pipeline)
        }
        
        if any_shader_was_changed || !pipeline_is_valid(pipeline) {
            pipeline = create_graphics_pipeline(device, pipeline_cache, swapchain, { graphics_descriptor_set_layout, textures_descriptor_set_layout }, shaders[:], GraphicsStorageBufferCount, pipeline)
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
        
        // @note(viktor): QueuePool must be reset before use, but that would require a whole cmd begin-end.
        if absolute_frame_index > 1 {
            query_results: [4] u64
            query_result := vk.GetQueryPoolResults(device, query_pool, 0, len(&query_results), cast(int) size_of_slice(query_results[:]), &query_results[0], size_of(query_results[0]), { ._64 } )
            
            if query_result != .NOT_READY && query_result != .ERROR_DEVICE_LOST {
                check(query_result)
                
                gpu_begin := cast(f64) query_results[0] * cast(f64) ips.device_properties.properties.limits.timestampPeriod * 1e-9
                gpu_end   := cast(f64) query_results[1] * cast(f64) ips.device_properties.properties.limits.timestampPeriod * 1e-9
                gpu_delta := gpu_end - gpu_begin
                // @note(viktor): this might have happened when a validation error occurred, causing the smooth value to be messed for a very long time
                if gpu_delta >= 0 {
                    smooth_update(delta_time_64, &gpu_time, gpu_delta)
                }
                
                cull_begin := cast(f64) query_results[2] * cast(f64) ips.device_properties.properties.limits.timestampPeriod * 1e-9
                cull_end   := cast(f64) query_results[3] * cast(f64) ips.device_properties.properties.limits.timestampPeriod * 1e-9
                cull_delta = cull_end - cull_begin
            }
        }
        
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
        
        projection_reversed_z :: proc (fov_y, aspect_w_h, near_z: f32) -> m4 { // :ReversedZ:
            f := 1 / tan(fov_y / 2)
            a := f / aspect_w_h
            b := f
            c := near_z
            
            // due to homogenous coordinates, z is effectively 1/z
            result := m4 {
                a,  0,  0, 0,
                0,  b,  0, 0,
                0,  0,  0, c,
                0,  0, -1, 0, // -1 in the original blog post
            }
            
            return result
        }
        
        projection := projection_reversed_z(70 * RadPerDeg, cast(f32) swapchain.size.x / cast(f32) swapchain.size.y, 0.01)
        draw_globals.projection = projection
        draw_globals.view       = translate(1, cam_pos)
        
        // @todo(viktor): we also need to take the view matrix into account
        draw_distance: f32 = 100
        
        cull_globals: Cull_Globals
        
        cull_globals.frustum_planes[0] = get_column_v4(projection, 3) + get_column_v4(projection, 0) // x + w < 0
        cull_globals.frustum_planes[1] = get_column_v4(projection, 3) - get_column_v4(projection, 0) // x - w > 0
        cull_globals.frustum_planes[2] = get_column_v4(projection, 3) + get_column_v4(projection, 1) // y + w < 0
        cull_globals.frustum_planes[3] = get_column_v4(projection, 3) - get_column_v4(projection, 1) // y - w > 0
        cull_globals.frustum_planes[4] = get_column_v4(projection, 3) - get_column_v4(projection, 2) // z - w > 0 -- :ReversedZ:
        cull_globals.frustum_planes[5] = v4{0, 0, -1, draw_distance}                                 // :ReversedZ: infinite far plane
        
        
        frame.draw_globals.cpu^ = draw_globals
        frame.cull_globals.cpu^ = cull_globals
        
        ////////////////////////////////////////////////
        
        triangles_this_frame: u32
        
        entropy := seed_random_series(5175546)
        @(static) draws: [5000] Draw
        for &draw in draws {
            p := random_bilateral(&entropy, v3) * {20, 15, 60}
            
            draw.p           = p
            draw.scale       = linear_blend(cast(f32) 1, 4, square(random_unilateral(&entropy, f32)))
            rotation        := la.quaternion_angle_axis(random_unilateral(&entropy, f32) * Tau, random_bilateral(&entropy, v3))
            global_rotation := la.quaternion_from_euler_angles_f32(expand_values(object_rotation * random_unilateral(&entropy, v3)), .XYX)
            draw.orientation = rotation * global_rotation
            
            mesh := random_choice(&entropy, geometry.meshes[:])
            
            draw.center = mesh.center
            draw.radius = mesh.radius
            
            draw.vertex_offset  = mesh.vertex_offset
            draw.vertex_count   = mesh.vertex_count
            draw.meshlet_offset = mesh.meshlet_offset
            draw.meshlet_count  = mesh.meshlet_count
            
            triangles_this_frame += mesh.triangle_count
        }
        
        copy(db_view, draws[:])
        
        ////////////////////////////////////////////////
        
        smooth_update(delta_time_64, &cpu_time, delta_time_64)
        
        view :: proc (seconds: f64) -> time.Duration {
            return time.duration_round(cast(time.Duration) (seconds * cast(f64) time.Second), 1 * time.Microsecond)
        }
        
        // @todo(viktor): just accumulate triangle count and meshlet count each frame in the draw loop
        sdl.SetWindowTitle(window, fmt.ctprintf("cpu time: %.3v, gpu time: %.3v, cull time: %.3v, triangles: %v, %v triangles/s", 
            view(cpu_time.value), 
            view(gpu_time.value), 
            view(cull_delta), 
            view_magnitude(triangles_this_frame), 
            view_magnitude(cast(f64) triangles_this_frame / gpu_time.value),
        ))
        
        ////////////////////////////////////////////////
        
        cb := frame.command_buffer
        check(vk.ResetCommandBuffer(cb, {}))
        
        check(vk.BeginCommandBuffer(cb, &vk.CommandBufferBeginInfo { sType = .COMMAND_BUFFER_BEGIN_INFO, flags = { .ONE_TIME_SUBMIT } }))
        
        // @todo(viktor): make a basic region based profiler out of the labels
        vk.CmdResetQueryPool(cb, query_pool, 0, QueryPoolSize)
        vk.CmdWriteTimestamp(cb, { .BOTTOM_OF_PIPE }, query_pool, 0)
        
        ////////////////////////////////////////////////
        
        vk.CmdWriteTimestamp(cb, { .BOTTOM_OF_PIPE }, query_pool, 2)
        
        vk.CmdBindPipeline(cb, .COMPUTE, compute_pipeline.pipeline)
        
        // @volatile needs to match the bindings in shaders 
        compute_descriptor_update := [ComputeStorageBufferCount] DescriptorUpdateData {
            { buffer = { draw_buffer.buffer,         0, auto_cast vk.WHOLE_SIZE }},
            { buffer = { draw_command_buffer.buffer, 0, auto_cast vk.WHOLE_SIZE }},
        }
        vk.CmdPushDescriptorSetWithTemplate(cb, compute_pipeline.update_template, compute_pipeline.layout, 0, &compute_descriptor_update[0])
        
        vk.CmdPushConstants(cb, compute_pipeline.layout, compute_pipeline.shader_stages, 0, size_of(frame.cull_globals.gpu), &frame.cull_globals.gpu)
        
        // @volatile the round up needs align with the ComputeWidth
        vk.CmdDispatch(cb, len(draws) + 31 / 32,  1, 1)
        
        begin_pipeline_barrier()
            add_memory_barrier(draw_command_buffer.buffer, { .SHADER_WRITE }, { .INDIRECT_COMMAND_READ })
        end_pipeline_barrier(cb, { .COMPUTE_SHADER }, { .DRAW_INDIRECT })
        
        vk.CmdWriteTimestamp(cb, { .BOTTOM_OF_PIPE }, query_pool, 3)
        
        ////////////////////////////////////////////////
        
        begin_pipeline_barrier()
            add_image_barrier(swapchain.color_buffer.image, {}, .UNDEFINED, { .COLOR_ATTACHMENT_WRITE },         .COLOR_ATTACHMENT_OPTIMAL)
            add_image_barrier(swapchain.depth_buffer.image, {}, .UNDEFINED, { .DEPTH_STENCIL_ATTACHMENT_WRITE }, .DEPTH_STENCIL_ATTACHMENT_OPTIMAL, { .DEPTH, .STENCIL })
        end_pipeline_barrier(cb, { .BOTTOM_OF_PIPE }, { .COLOR_ATTACHMENT_OUTPUT, .EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS })
        
        ////////////////////////////////////////////////
        
        begin_rendering(cb, swapchain, swapchain.color_buffer, image_index, {0.07, 0.07, 0.07, 1})
        
        vk.CmdSetViewport(cb, 0, 1, &vk.Viewport {
            x      = 0,
            y      = 0,
            width  = cast(f32) swapchain.size.x,
            height = cast(f32) swapchain.size.y,
            minDepth = 0,
            maxDepth = 1,
        })
        
        vk.CmdSetScissor(cb, 0, 1, &vk.Rect2D { extent = to_extent(swapchain.size) })
        
        vk.CmdBindPipeline(cb, .GRAPHICS, pipeline.pipeline)
        
        // @volatile needs to match the bindings in shaders 
        graphics_descriptor_update := [GraphicsStorageBufferCount] DescriptorUpdateData {
            { buffer = { draw_buffer.buffer,         0, auto_cast vk.WHOLE_SIZE }},
            { buffer = { meshlet_buffer.buffer,      0, auto_cast vk.WHOLE_SIZE }},
            { buffer = { meshlet_data_buffer.buffer, 0, auto_cast vk.WHOLE_SIZE }},
            { buffer = { vertex_buffer.buffer,       0, auto_cast vk.WHOLE_SIZE }},
        }
        vk.CmdPushDescriptorSetWithTemplate(cb, pipeline.update_template, pipeline.layout, 0, &graphics_descriptor_update[0])
        
        vk.CmdBindDescriptorSets(cb, .GRAPHICS, pipeline.layout, 1, 1, &textures_descriptor_set, 0, nil)
        
        
        vk.CmdPushConstants(cb, pipeline.layout, pipeline.shader_stages, 0, size_of(frame.draw_globals.gpu), &frame.draw_globals.gpu)
        // @todo(viktor): this is deprecated, use vkCmdDrawMeshTasksIndirect2EXT
        vk.CmdDrawMeshTasksIndirectEXT(cb, draw_command_buffer.buffer, 0, len(draws), size_of(Draw_Command))
        
        ////////////////////////////////////////////////
        
        vk.CmdEndRendering(cb)
        
        begin_pipeline_barrier()
            add_image_barrier(swapchain.color_buffer.image, { .COLOR_ATTACHMENT_WRITE }, .COLOR_ATTACHMENT_OPTIMAL, { .TRANSFER_READ }, .TRANSFER_SRC_OPTIMAL)
            add_image_barrier(swapchain.images[image_index], {}, .UNDEFINED, { .TRANSFER_WRITE }, .TRANSFER_DST_OPTIMAL)
        end_pipeline_barrier(cb, { .COLOR_ATTACHMENT_OUTPUT }, { .TRANSFER })
        
        vk.CmdCopyImage(cb, swapchain.color_buffer.image, .TRANSFER_SRC_OPTIMAL, swapchain.images[image_index], .TRANSFER_DST_OPTIMAL, 1, &vk.ImageCopy {
            srcSubresource = { aspectMask = { .COLOR }, layerCount = 1 },
            dstSubresource = { aspectMask = { .COLOR }, layerCount = 1 },
            extent         = to_extent(swapchain.size, 1),
        })
        
        begin_pipeline_barrier()
            add_image_barrier(swapchain.images[image_index], { .TRANSFER_WRITE }, .TRANSFER_DST_OPTIMAL, {}, .PRESENT_SRC_KHR)
        end_pipeline_barrier(cb, { .TRANSFER }, {})
        
        ////////////////////////////////////////////////
        
        vk.CmdWriteTimestamp(cb, { .BOTTOM_OF_PIPE }, query_pool, 1)
        
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
    }
    
    ////////////////////////////////////////////////
    // Cleanup and Shutdown
    
	check(vk.DeviceWaitIdle(device))
    
    for frame in frames {
        gpu_delete(frame.draw_globals.buffer)
        gpu_delete(frame.cull_globals.buffer)
    }
    
    gpu_delete(vertex_buffer)
    gpu_delete(meshlet_buffer)
    gpu_delete(meshlet_data_buffer)
    gpu_delete(draw_buffer)
    gpu_delete(draw_command_buffer)
    
    destroy_swapchain(device, &swapchain)
    destroy_pipeline(device, pipeline)
    destroy_pipeline(device, compute_pipeline)
    
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
        os.exit(1)
    }
}
check_sdl :: proc (result: bool, loc := #caller_location) {
    if !result {
        fmt.printf("%v:%v:%v: SDL call returned %v", loc.file_path, loc.line, loc.column, sdl.GetError())
        intrinsics.debug_trap()
        os.exit(1)
    }
}