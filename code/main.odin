#+vet explicit-allocators
package main

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:time"
import "core:mem"
import la "core:math/linalg"

import "lib:vma"

import sdl "vendor:sdl3"
import vk  "vendor:vulkan"

////////////////////////////////////////////////

Optimized :: ODIN_OPTIMIZATION_MODE == .Speed

VSync :: true when !Optimized else false

MaxFramesInFlight :: 2

////////////////////////////////////////////////

Frame_Data :: struct {
    buffer:        Buffer,
    deviceAddress: vk.DeviceAddress,
    
    command_buffer: vk.CommandBuffer,
    image_aquired:  vk.Semaphore,
}

DescriptorUpdateData :: struct #raw_union {
    buffer: vk.DescriptorBufferInfo,
    image:  vk.DescriptorImageInfo,
}

Mesh :: struct {
    vertices: [] Vertex,
    indices:  [] u32,
    
    meshlets: [] Meshlet,
    meshlet_data: [] u32,
}

////////////////////////////////////////////////

// @volatile shader.slang
MaxVertices  :: 64
MaxTriangles :: 84

// @volatile shader.slang
// @note(viktor): this is technically only used for its layout and size, which we query from the compiler
Push_Data :: struct {
    address:    vk.DeviceAddress,
    mesh_index: u32,
}

// @volatile shader.slang
Draw_Globals :: struct {
    view:       m4,
    projection: m4,
    light_pos:  [4] v4,
    
    meshlet_count: u32,
}

// @volatile shader.slang
Draw_Mesh :: struct #align(16) {
    p:           v3,
    scale:       f32,
    orientation: q32,
}

// @volatile shader.slang
Meshlet :: struct #align(16) {
    center: v3,
    radius: f32,
    cone_axis:   [3] i8,
    cone_cutoff: i8,
    
    data_offset:    u32, // data_offset:][:vertexcount stores vertex indices, we store indices packed in 4b units after that
    vertex_count:   u8,
    triangle_count: u8,
}

// @volatile shader.slang
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
    draw_buffer,         db_view  := gpu_make_buffer({ .STORAGE_BUFFER }, [] Draw_Mesh, 256 * Megabyte / size_of(Draw_Mesh))
    
    Mesh_Info :: struct {
        triangle_count: u32,
        meshlet_count:  u32,
    }
    
    mesh_info: Mesh_Info
    {
        // mesh := load_mesh_from_obj("tutorial/suzanne.obj", context.temp_allocator)
        mesh := load_mesh_from_obj("models/bunny.obj", context.temp_allocator)
        // mesh := load_mesh_from_obj("models/lucy_280k.obj", context.temp_allocator)
        
        optimize_mesh(&mesh, context.temp_allocator)
        
        meshlet_count := build_meshlets(&mesh, context.temp_allocator)
        
        mesh_info.triangle_count = cast(u32) len(mesh.indices)
        mesh_info.meshlet_count  = meshlet_count
        
        copy(vb_view, mesh.vertices)
        copy(mb_view, mesh.meshlets)
        copy(mdb_view, mesh.meshlet_data)
    }
    
    ////////////////////////////////////////////////
    
    shader_data: Draw_Globals
    
    for &pos, index in shader_data.light_pos {
        t := clamp_01_to_range(cast(f32) 0, cast(f32) len(shader_data.light_pos), cast(f32) index)
        pos.xyz = v3{0, -10, 10}
        pos.xz += arm(t * Tau)
    }
    
    ////////////////////////////////////////////////
    
    allocator: vma.Allocator
    {
        vma_vulkan_functions := vma.create_vulkan_functions()
        
        allocator_create_info := vma.Allocator_Create_Info {
            flags            = { .Buffer_Device_Address },
            instance         = ips.instance,
            physical_device  = ips.physical_device,
            device           = device,
            vulkan_functions = &vma_vulkan_functions,
        }
        check(vma.create_allocator(allocator_create_info, &allocator))
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
            
            image_create_info := vk.ImageCreateInfo {
                sType = .IMAGE_CREATE_INFO,
                imageType     = .D2,
                format        = loaded_texture.format,
                extent        = { width = loaded_texture.width, height = loaded_texture.height, depth = 1 },
                mipLevels     = loaded_texture.mip_levels,
                arrayLayers   = 1,
                samples       = { ._1 },
                tiling        = .OPTIMAL,
                usage         = { .TRANSFER_DST, .SAMPLED },
                initialLayout = .UNDEFINED,
            }
            
            image_allocation_create_info := vma.Allocation_Create_Info { usage = .Auto }
            check(vma.create_image(allocator, image_create_info, image_allocation_create_info, &texture.image, &texture.allocation, nil))
            
            texture.view = create_image_view(device, texture.image, image_create_info.format, { .COLOR }, loaded_texture.mip_levels)
            defer_destroy(vk.DestroyImageView, texture.view)
            
            image_src_buffer: vk.Buffer
            image_src_allocation: vma.Allocation
            image_src_allocation_info: vma.Allocation_Info
            
            image_src_buffer_create_info := vk.BufferCreateInfo {
                sType = .BUFFER_CREATE_INFO,
                size  = auto_cast len(loaded_texture.data),
                usage = { .TRANSFER_SRC },
            }
            
            image_src_allocation_create_info := vma.Allocation_Create_Info {
                flags = { .Host_Access_Sequential_Write, .Mapped },
                usage = .Auto,
            }
            
            check(vma.create_buffer(allocator, image_src_buffer_create_info, image_src_allocation_create_info, &image_src_buffer, &image_src_allocation, &image_src_allocation_info))
            defer vma.destroy_buffer(allocator, image_src_buffer, image_src_allocation)
            
            mem.copy_non_overlapping(image_src_allocation_info.mapped_data, raw_data(loaded_texture.data), len(loaded_texture.data))
            
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
            
            
            begin_transition_images()
                // @note(viktor): check if these src masks are correct
                append_image_memory_barrier_2(texture.image, {}, .UNDEFINED, { .TRANSFER_WRITE }, .TRANSFER_DST_OPTIMAL)
            end_transition_images(cb_once, {}, { .TRANSFER })
            
            copy_regions := make([dynamic] vk.BufferImageCopy, context.temp_allocator)
            for level in 0..<loaded_texture.mip_levels {
                mip_offset: uint = loaded_texture.mip_offsets[level]
                
                append(&copy_regions, vk.BufferImageCopy{
                    bufferOffset = auto_cast mip_offset,
                    imageSubresource = { aspectMask = { .COLOR }, mipLevel = level, layerCount = 1 },
                    imageExtent = { width = loaded_texture.width >> level, height = loaded_texture.height >> level, depth = 1 },
                })
            }
            
            vk.CmdCopyBufferToImage(cb_once, image_src_buffer, texture.image, .TRANSFER_DST_OPTIMAL, auto_cast len(copy_regions), raw_data(copy_regions))
            
            begin_transition_images()
                append_image_memory_barrier_2(texture.image, { .TRANSFER_WRITE }, .TRANSFER_DST_OPTIMAL, { .SHADER_READ }, .READ_ONLY_OPTIMAL)
            end_transition_images(cb_once, { .TRANSFER }, { .FRAGMENT_SHADER })
            
            check(vk.EndCommandBuffer(cb_once))
            
            once_submit_info := vk.SubmitInfo {
                sType = .SUBMIT_INFO,
                commandBufferCount = 1,
                pCommandBuffers = &cb_once,
            }
            
            check(vk.QueueSubmit(queue, 1, &once_submit_info, fence_once))
            
            check(vk.WaitForFences(device, 1, &fence_once, true, max(u64)))
            
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
    
    // @volatile needs to match the bindings in shader.slang
    StorageBufferCount :: 4
    data_descriptor_set_layout: vk.DescriptorSetLayout
    {
        bindings := [StorageBufferCount] vk.DescriptorSetLayoutBinding {
            {
                binding = 0,
                descriptorType = .STORAGE_BUFFER,
                descriptorCount = 1,
                stageFlags = { .MESH_EXT },
            },
            {
                binding = 1,
                descriptorType = .STORAGE_BUFFER,
                descriptorCount = 1,
                stageFlags = { .MESH_EXT }, // :TaskShader: + { .TASK_EXT }
            },
            {
                binding = 2,
                descriptorType = .STORAGE_BUFFER,
                descriptorCount = 1,
                stageFlags = { .MESH_EXT }, // :TaskShader: + { .TASK_EXT }
            },
            {
                binding = 3,
                descriptorType = .STORAGE_BUFFER,
                descriptorCount = 1,
                stageFlags = { .MESH_EXT }, // :TaskShader: + { .TASK_EXT }
            },
        }
        
        vertices_descriptor_layout_create_info := vk.DescriptorSetLayoutCreateInfo {
            sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            flags        = { .PUSH_DESCRIPTOR },
            bindingCount = len(bindings),
            pBindings    = &bindings[0],
        }
        
        check(vk.CreateDescriptorSetLayout(device, &vertices_descriptor_layout_create_info, nil, &data_descriptor_set_layout))
        defer_destroy(vk.DestroyDescriptorSetLayout, data_descriptor_set_layout)
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
    
    set_layouts := [] vk.DescriptorSetLayout { data_descriptor_set_layout, textures_descriptor_set_layout }
    
    pipeline := create_graphics_pipeline(device, swapchain, set_layouts)
    
    vertex_descriptor_update_template := create_vertex_update_template(device, pipeline, StorageBufferCount)
    
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
    
    cam_pos := v3{ 0, 0, -6 }
    object_rotation: v3
    quit: bool
    last_time := time.tick_now()
    
    Timeout :: max(u64)
    
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
        
        for event: sdl.Event; sdl.PollEvent(&event); {
            #partial switch event.type {
            case .QUIT:
                quit = true
            
            case .MOUSE_MOTION:
                if event.button.button == sdl.BUTTON_LEFT {
                    object_rotation.y += event.motion.xrel * delta_time
                    object_rotation.x += event.motion.yrel * delta_time
                }
                
            case .MOUSE_WHEEL:
                cam_pos.z += event.wheel.y * 10 * delta_time
                
            case .WINDOW_RESIZED:
                should_recreate_swapchain = true
            }
        }
        
        ////////////////////////////////////////////////
        
        // @todo(viktor): if the window is minimized we can never get it back up and visible
        if should_recreate_swapchain {
            should_recreate_swapchain = false
            
            vk.DeviceWaitIdle(device)
            
            recreate_swapchain(ips, device, sdl_get_window_size(window), &swapchain)
        }
        
        if should_recreate_pipeline(pipeline) {
            pipeline = create_graphics_pipeline(device, swapchain, set_layouts, pipeline)
            vertex_descriptor_update_template = create_vertex_update_template(device, pipeline, StorageBufferCount, vertex_descriptor_update_template)
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
        wait_result := vk.WaitSemaphores(device, &wait_info, Timeout)
        if wait_result == .TIMEOUT {
            should_recreate_swapchain = true
            continue
        }
        check(wait_result)
        
        ////////////////////////////////////////////////
        
        // @note(viktor): QueuePool must be reset before use, but that would require a whole cmd begin-end.
        if absolute_frame_index > 1 {
            query_results: [2] u64
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
            }
        }
        
        ////////////////////////////////////////////////
        
        frame : Frame_Data = frames[absolute_frame_index % MaxFramesInFlight]
        absolute_frame_index += 1
        
        acquire_result := vk.AcquireNextImageKHR(device, swapchain.swapchain, Timeout, frame.image_aquired, {}, &image_index)
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
                a, 0,  0, 0,
                0, b,  0, 0,
                0, 0,  0, c,
                0, 0, -1, 0, // -1 in the original blog post
            }
            
            return result
        }
        
        shader_data.projection = projection_reversed_z(70 * RadPerDeg, cast(f32) swapchain.size.x / cast(f32) swapchain.size.y, 0.01)
        shader_data.view       = translate(1, cam_pos)
        
        
        shader_data.meshlet_count = mesh_info.meshlet_count
        
        copy(frame.buffer.data, to_bytes(&shader_data))
        
        entropy := seed_random_series(5175546)
        draws: [100] Draw_Mesh
        for &draw in draws {
            p := random_bilateral(&entropy, v3) * {30, 20, 10}
            p.z -= 20
            
            draw.p           = p
            draw.scale       = linear_blend(cast(f32) 1.5, 4, square(random_unilateral(&entropy, f32)))
            draw.orientation = la.quaternion_angle_axis(random_unilateral(&entropy, f32) * Tau, random_bilateral(&entropy, v3))
            draw.orientation = la.quaternion_from_euler_angles_f32(expand_values(object_rotation), .XYX) * draw.orientation
        }
        
        copy(db_view, draws[:])
        
        ////////////////////////////////////////////////
        
        smooth_update(delta_time_64, &cpu_time, delta_time_64)
        
        view :: proc (seconds: f64) -> time.Duration {
            return time.duration_round(cast(time.Duration) (seconds * cast(f64) time.Second), 1 * time.Microsecond)
        }
        sdl.SetWindowTitle(window, fmt.ctprintf("cpu time: %.3v, gpu time: %.3v, triangles: %v, meshlets: %v, triangles/s %v", view(cpu_time.value), view(gpu_time.value), view_magnitude(mesh_info.triangle_count), view_magnitude(mesh_info.meshlet_count), view_magnitude(cast(f64) mesh_info.triangle_count * len(draws) / gpu_time.value)))
        
        ////////////////////////////////////////////////
        
        cb := frame.command_buffer
        check(vk.ResetCommandBuffer(cb, {}))
        
        check(vk.BeginCommandBuffer(cb, &vk.CommandBufferBeginInfo { sType = .COMMAND_BUFFER_BEGIN_INFO, flags = { .ONE_TIME_SUBMIT } }))
        
        // @todo(viktor): make a basic region based profiler out of the labels
        vk.CmdResetQueryPool(cb, query_pool, 0, QueryPoolSize)
        vk.CmdWriteTimestamp(cb, { .BOTTOM_OF_PIPE }, query_pool, 0)
        
        ////////////////////////////////////////////////
        
        begin_transition_images()
            append_image_memory_barrier_2(swapchain.color_buffer.image, {}, .UNDEFINED, { .COLOR_ATTACHMENT_WRITE },         .COLOR_ATTACHMENT_OPTIMAL)
            append_image_memory_barrier_2(swapchain.depth_buffer.image, {}, .UNDEFINED, { .DEPTH_STENCIL_ATTACHMENT_WRITE }, .DEPTH_STENCIL_ATTACHMENT_OPTIMAL, { .DEPTH, .STENCIL })
        end_transition_images(cb, { .BOTTOM_OF_PIPE }, { .COLOR_ATTACHMENT_OUTPUT, .EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS })
        
        begin_rendering(cb, swapchain, swapchain.color_buffer, image_index, {0.07, 0.07, 0.07, 1})
        
        ////////////////////////////////////////////////
        
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
        
        // @volatile needs to match the bindings in shader.slang 
        descriptor_update_data := [StorageBufferCount] DescriptorUpdateData {
            { buffer = { vertex_buffer.buffer,       0, auto_cast vk.WHOLE_SIZE }},
            { buffer = { meshlet_buffer.buffer,      0, auto_cast vk.WHOLE_SIZE }},
            { buffer = { meshlet_data_buffer.buffer, 0, auto_cast vk.WHOLE_SIZE }},
            { buffer = { draw_buffer.buffer,         0, auto_cast vk.WHOLE_SIZE }},
        }
        vk.CmdPushDescriptorSetWithTemplate(cb,  vertex_descriptor_update_template, pipeline.layout, 0, &descriptor_update_data[0])
        
        vk.CmdBindDescriptorSets(cb, .GRAPHICS, pipeline.layout, 1, 1, &textures_descriptor_set, 0, nil)
        
        
        for index in 0..<len(draws) {
            vk.CmdPushConstants(cb, pipeline.layout, pipeline.shader.stages, 0, size_of(Push_Data), &Push_Data { address = frame.deviceAddress, mesh_index = cast(u32) index })
            
            count := mesh_info.meshlet_count
            // :TaskShader: each task shader should later spawn 32 meshshaders
            // @volatile this division needs to match the TaskWidth
            // count  = (count + 31) / 32
            vk.CmdDrawMeshTasksEXT(cb, count, 1, 1)
        }
        
        ////////////////////////////////////////////////
        
        vk.CmdEndRendering(cb)
        
        begin_transition_images()
            append_image_memory_barrier_2(swapchain.color_buffer.image, { .COLOR_ATTACHMENT_WRITE }, .COLOR_ATTACHMENT_OPTIMAL, { .TRANSFER_READ }, .TRANSFER_SRC_OPTIMAL)
            append_image_memory_barrier_2(swapchain.images[image_index], {}, .UNDEFINED, { .TRANSFER_WRITE }, .TRANSFER_DST_OPTIMAL)
        end_transition_images(cb, { .COLOR_ATTACHMENT_OUTPUT }, { .TRANSFER })
        
        vk.CmdCopyImage(cb, swapchain.color_buffer.image, .TRANSFER_SRC_OPTIMAL, swapchain.images[image_index], .TRANSFER_DST_OPTIMAL, 1, &vk.ImageCopy {
            srcSubresource = { aspectMask = { .COLOR }, layerCount = 1 },
            dstSubresource = { aspectMask = { .COLOR }, layerCount = 1 },
            extent         = to_extent(swapchain.size, 1),
        })
        
        begin_transition_images()
            append_image_memory_barrier_2(swapchain.images[image_index], { .TRANSFER_WRITE }, .TRANSFER_DST_OPTIMAL, {}, .PRESENT_SRC_KHR)
        end_transition_images(cb, { .TRANSFER }, {})
        
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
        gpu_delete_buffer(frame.buffer)
    }
    
    gpu_delete_buffer(vertex_buffer)
    gpu_delete_buffer(meshlet_buffer)
    gpu_delete_buffer(meshlet_data_buffer)
    gpu_delete_buffer(draw_buffer)
    
    destroy_swapchain(device, &swapchain)
    vk.DestroyDescriptorUpdateTemplate(device, vertex_descriptor_update_template, nil)
    destroy_pipeline(device, pipeline)
    
    for texture in textures {
        vma.destroy_image(allocator, texture.image, texture.allocation)
    }
	vma.destroy_allocator(allocator)
    
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