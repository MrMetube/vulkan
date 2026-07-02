#+vet explicit-allocators
package main

import "core:fmt"
import "core:time"

import vk "vendor:vulkan"

Pipeline :: struct {
    pipeline: vk.Pipeline,
    layout:   vk.PipelineLayout,
    update_template: vk.DescriptorUpdateTemplate,
    
    bind_point:    vk.PipelineBindPoint,
    shader_stages: vk.ShaderStageFlags,
}

Shader :: struct {
    input:  string, 
    
    stage: vk.ShaderStageFlag,
    bytes: [] u8,
    
    parsed: struct {
        resource_mask:      Shader_Resource_Mask,
        resource_types:     [32] vk.DescriptorType,
        use_push_constants: bool,
        local_size:         uv3,
    },
        
    source_watcher: Watcher_Id,
    common_watcher: Watcher_Id,
}

Shader_Resource_Mask :: bit_set[cast(u32) 0..<32; u32]

Image :: struct {
    format: vk.Format,
    image:  vk.Image,
    view:   vk.ImageView,
    memory: vk.DeviceMemory,
    
    last_transition: Transition,
}

Buffer :: struct {
    buffer:  vk.Buffer,
    memory:  vk.DeviceMemory,
    address: vk.DeviceAddress,
}

Transition :: struct {
    stage:  vk.PipelineStageFlags2,
    access: vk.AccessFlags2,
    layout: vk.ImageLayout,
}

////////////////////////////////////////////////

to_be_destroyed_handles: [dynamic] Destroy_Info

Destroy_Info :: struct { 
    handle: vk.NonDispatchableHandle, 
    fn: proc (device: vk.Device, handle: vk.NonDispatchableHandle, pAllocator: ^vk.AllocationCallbacks),
}

defer_destroy :: proc (fn: $F, handle: $T/ vk.NonDispatchableHandle, loc := #caller_location) {
    assert(handle != 0, loc = loc)
    append(&to_be_destroyed_handles, Destroy_Info { handle = auto_cast handle, fn = auto_cast fn })
}

destroy_all_handles :: proc (device: vk.Device) {
    #reverse for item in to_be_destroyed_handles {
        item.fn(device, item.handle, nil)
    }
}

////////////////////////////////////////////////

gpu_recreate_swapchain_if_needed :: proc (gpu: ^Gpu) -> (can_render: bool) {
    if gpu.swapchain_state != .Dirty && gpu.swapchain_state != .Window_Is_Minimized {
        return true
    }
    
    check(vk.DeviceWaitIdle(gpu.device))
    
    surface_capabilities: vk.SurfaceCapabilitiesKHR
    check(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(gpu.physical_device, gpu.surface, &surface_capabilities))
    
    // :Linux: Wayland had a special value for surface_capabilities.currentExtent.width
    swapchain_extent := surface_capabilities.currentExtent
    if swapchain_extent.width == 0 || swapchain_extent.height == 0 {
        gpu.swapchain_state = .Window_Is_Minimized
        return false
    }
    
    old_swapchain := gpu.swapchain
    swapchain_create_info := vk.SwapchainCreateInfoKHR {
        sType = .SWAPCHAIN_CREATE_INFO_KHR,
        surface          = gpu.surface,
        minImageCount    = surface_capabilities.minImageCount,
        imageFormat      = gpu.swapchain_format,
        imageColorSpace  = .SRGB_NONLINEAR,
        imageExtent      = swapchain_extent,
        imageArrayLayers = 1,
        imageUsage       = { .TRANSFER_DST },
        preTransform     = { .IDENTITY },
        compositeAlpha   = { .OPAQUE },
        presentMode      = VSync ? .FIFO : .IMMEDIATE,
        
        oldSwapchain = old_swapchain,
    }
    gpu.swapchain_size = { swapchain_extent.width, swapchain_extent.height }
    
    previous_image_count := cast(u32) len(gpu.swapchain_images)
    
    check(vk.CreateSwapchainKHR(gpu.device, &swapchain_create_info, nil, &gpu.swapchain))
    
    image_count: u32
    check(vk.GetSwapchainImagesKHR(gpu.device, gpu.swapchain, &image_count, nil))
    
    if old_swapchain != 0 {
        // @copypasta a bit redundant with destroy_swapchain, but combining both leads to a mess
        if previous_image_count != image_count {
            for &it in gpu.render_completes {
                vk.DestroySemaphore(gpu.device, it, nil)
            }
            clear(&gpu.render_completes)
            clear(&gpu.swapchain_images) // The swapchain's images are allocated for us, so we can just drop the handles.
        }
        
        vk.DestroySwapchainKHR(gpu.device, old_swapchain, nil)
    }
    
    if previous_image_count != image_count {
        resize(&gpu.swapchain_images, image_count)
        resize(&gpu.render_completes, image_count)
        
        for &it in gpu.render_completes {
            it = gpu_create_semaphore(gpu)
        }
    }
    
    images: [dynamic; 16] vk.Image
    assert(image_count <= cap(images))
    resize(&images, image_count)
    check(vk.GetSwapchainImagesKHR(gpu.device, gpu.swapchain, &image_count, &images[0]))
    for image, index in images {
        gpu.swapchain_images[index].image = image
    }
    
    gpu.swapchain_state = .Was_Resized
    return true
}

gpu_destroy_swapchain :: proc (gpu: ^Gpu) { 
    for &it in gpu.render_completes {
        vk.DestroySemaphore(gpu.device, it, nil)
    }
    clear(&gpu.render_completes)
    clear(&gpu.swapchain_images) // The swapchain's images are allocated for us, so we can just drop the handles.
    vk.DestroySwapchainKHR(gpu.device, gpu.swapchain, nil)
}

////////////////////////////////////////////////

// @api image aspect mask should be derivable from the image itself. @study is it fixed per image?
create_image_barrier :: proc (image: ^Image, src_stage: vk.PipelineStageFlags2, src_access: vk.AccessFlags2, old_layout: vk.ImageLayout, dst_stage: vk.PipelineStageFlags2, dst_access: vk.AccessFlags2, new_layout: vk.ImageLayout) -> vk.ImageMemoryBarrier2 {
    aspect_mask := get_image_aspect_mask(image.format)
    
    result := vk.ImageMemoryBarrier2 {
        sType = .IMAGE_MEMORY_BARRIER_2,
        srcAccessMask = src_access,
        dstAccessMask = dst_access,
        srcStageMask  = src_stage,
        dstStageMask  = dst_stage,
        oldLayout = old_layout,
        newLayout = new_layout,
        image = image.image,
        subresourceRange = { aspectMask = aspect_mask, levelCount = vk.REMAINING_MIP_LEVELS, layerCount = vk.REMAINING_ARRAY_LAYERS },
    }
    image.last_transition = { dst_stage, dst_access, new_layout }
    
    return result
}

create_image_barrier_from_last_transition :: proc (image: ^Image, dst_stage: vk.PipelineStageFlags2, dst_access: vk.AccessFlags2, new_layout: vk.ImageLayout) -> vk.ImageMemoryBarrier2 {
    last := image.last_transition
    result := create_image_barrier(image, last.stage, last.access, last.layout, dst_stage, dst_access, new_layout)
    return result
}

gpu_image_barrier_from_last_transition :: proc (cmd: vk.CommandBuffer, image: ^Image, dst_stage: vk.PipelineStageFlags2, dst_access: vk.AccessFlags2, new_layout: vk.ImageLayout, flags := vk.DependencyFlags {}) {
    barrier := create_image_barrier_from_last_transition(image, dst_stage, dst_access, new_layout)
    
    gpu_image_barriers(cmd, barrier, flags = flags)
}

gpu_image_barrier :: proc (cmd: vk.CommandBuffer, image: ^Image, src_stage: vk.PipelineStageFlags2, src_access: vk.AccessFlags2, old_layout: vk.ImageLayout, dst_stage: vk.PipelineStageFlags2, dst_access: vk.AccessFlags2, new_layout: vk.ImageLayout, flags := vk.DependencyFlags {}) {
    barrier := create_image_barrier(image, src_stage, src_access, old_layout, dst_stage, dst_access, new_layout)
    
    gpu_image_barriers(cmd, barrier, flags = flags)
}

gpu_image_barriers :: proc (cmd: vk.CommandBuffer, barriers: ..vk.ImageMemoryBarrier2, flags := vk.DependencyFlags {}) {
    vk.CmdPipelineBarrier2(cmd, &vk.DependencyInfo {
        sType = .DEPENDENCY_INFO,
        dependencyFlags          = flags, 
        imageMemoryBarrierCount  = cast(u32) len(barriers),
        pImageMemoryBarriers     = raw_data(barriers),
    })
}

////////////////////////////////////////////////

gather_descriptor_resources :: proc (shaders: ..Shader) -> ([32] vk.DescriptorType, Shader_Resource_Mask) {
    resource_types: [32] vk.DescriptorType
    resource_mask: Shader_Resource_Mask
    
    for shader in shaders {
        for i in shader.parsed.resource_mask {
            if i in resource_mask {
                assert(resource_types[i] == shader.parsed.resource_types[i], "Mismatching binding types in shaders")
            } else {
                resource_types[i] = shader.parsed.resource_types[i]
                resource_mask += { i }
            }
        }
    }
    
    return resource_types, resource_mask
}

// @todo if we reach true bindless these functions and most of the Shader.parsed can gladly be deleted
create_descriptor_set_layout :: proc (device: vk.Device, shaders: ..Shader) -> vk.DescriptorSetLayout {
    bindings: [dynamic; 32] vk.DescriptorSetLayoutBinding
    resource_types, resource_mask := gather_descriptor_resources(..shaders)
    
    for i in resource_mask {
        binding := append_into(&bindings)
        
        binding^ = {
            binding         = i,
            
            descriptorType  = resource_types[i],
            descriptorCount = 1,
        }
        
        for shader in shaders {
            if i in shader.parsed.resource_mask {
                binding.stageFlags += { shader.stage }
            }
        }
    }
    
    create_info := vk.DescriptorSetLayoutCreateInfo {
        sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        flags        = { .PUSH_DESCRIPTOR },
        bindingCount = auto_cast len(bindings),
        pBindings    = raw_data(bindings[:]),
    }
    
    result: vk.DescriptorSetLayout
    
    check(vk.CreateDescriptorSetLayout(device, &create_info, nil, &result))
    
    return result
}

create_update_template :: proc (device: vk.Device, bind_point: vk. PipelineBindPoint, layout: vk.PipelineLayout, shaders: ..Shader) -> vk.DescriptorUpdateTemplate {
    entries: [dynamic; 32] vk.DescriptorUpdateTemplateEntry
    resource_types, resource_mask := gather_descriptor_resources(..shaders)
    
    for i in cast(u32) 0..<32 {
        if i in resource_mask {
            entry := append_into(&entries)
            
            entry^ = {
                dstBinding      = i,
                descriptorType  = resource_types[i],
                descriptorCount = 1,
                offset          = cast(int) i * size_of(DescriptorUpdateData),
                stride          = size_of(DescriptorUpdateData),
            }
        }
    }
    
    result: vk.DescriptorUpdateTemplate
    
    if len(entries) > 0 {
        create_info := vk.DescriptorUpdateTemplateCreateInfo {
            sType = .DESCRIPTOR_UPDATE_TEMPLATE_CREATE_INFO,
            pipelineBindPoint = bind_point,
            pipelineLayout    = layout,
            templateType      = .PUSH_DESCRIPTORS,
            descriptorUpdateEntryCount = cast(u32) len(entries),
            pDescriptorUpdateEntries   = &entries[0],
        }
        
        check(vk.CreateDescriptorUpdateTemplate(device, &create_info, nil, &result))
    }
    
    return result
}

////////////////////////////////////////////////

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

////////////////////////////////////////////////

QueryPoolSize :: 256

gpu_profiler: struct {
    cb:         vk.CommandBuffer,
    pool:       vk.QueryPool,
    zones:      [dynamic; QueryPoolSize] Profile_Zone,
    open_zones: [dynamic; QueryPoolSize] int,
    queries:    [dynamic; QueryPoolSize] Profile_Query,
} = {
    
}

Profile_Query :: struct { kind: Query_Kind, zone_index: int }
Query_Kind :: enum { Begin, End }

Profile_Zone :: struct {
    parent_zone: int,
    
    label:       string,
    query_index: u32,
    
    total_time: f64,
    total_time_with_children: f64,
}

gpu_profile_make_query_pool :: proc (device: vk.Device) {
    create_info := vk.QueryPoolCreateInfo {
        sType = .QUERY_POOL_CREATE_INFO,
        queryType = .TIMESTAMP,
        queryCount = QueryPoolSize,
    }
    check(vk.CreateQueryPool(device, &create_info, nil, &gpu_profiler.pool))
    defer_destroy(vk.DestroyQueryPool, gpu_profiler.pool)
}

gpu_profile_frame_begin :: proc (device: vk.Device, cb: vk.CommandBuffer) {
    vk.ResetQueryPool(device, gpu_profiler.pool, 0, QueryPoolSize)
    
    assert(gpu_profiler.pool != 0)
    gpu_profiler.cb = cb
    
    clear(&gpu_profiler.zones)
    clear(&gpu_profiler.open_zones)
    clear(&gpu_profiler.queries)
    
    gpu_profile_zone_begin("frame")
}

gpu_profile_frame_end :: proc () {
    assert(gpu_profiler.pool != 0)
    gpu_profile_zone_end()
}

gpu_profile_zone_begin :: proc (label: string) {
    assert(gpu_profiler.cb != nil)
    zone: Profile_Zone
    zone.parent_zone = peek(gpu_profiler.open_zones[:]) or_else -1
    zone.label = label
    
    zone_index := len(gpu_profiler.zones)
    append(&gpu_profiler.open_zones, zone_index)
    append(&gpu_profiler.zones, zone)
    
    gpu_profile_write_timestamp(.Begin, zone_index)
}

gpu_profile_zone_end   :: proc () {
    assert(gpu_profiler.cb != nil)
    zone_index := pop(&gpu_profiler.open_zones)
    gpu_profile_write_timestamp(.End, zone_index)
}

gpu_profile_write_timestamp :: proc (kind: Query_Kind, zone_index: int) {
    query_index := cast(u32) len(gpu_profiler.queries)
    append(&gpu_profiler.queries, Profile_Query { kind, zone_index })
    
    stage: vk.PipelineStageFlags2
    switch kind {
    case .Begin: stage = { .TOP_OF_PIPE }
    case .End:   stage = { .BOTTOM_OF_PIPE }
    }
    
    vk.CmdWriteTimestamp2(gpu_profiler.cb, stage, gpu_profiler.pool, query_index)
}

gpu_profile_collate_times :: proc (gpu: ^Gpu, device: vk.Device, print: bool) {
    assert(gpu_profiler.pool != 0)
    assert(len(gpu_profiler.open_zones) == 0)
    
    query_results: [QueryPoolSize] u64
    
    query_count := cast(u32) len(gpu_profiler.queries)
    query_result := vk.GetQueryPoolResults(device, gpu_profiler.pool, 0, query_count, cast(int) size_of_slice(query_results[:query_count]), &query_results[0], size_of(query_results[0]), { ._64, .WAIT })
    
    if query_result == .NOT_READY || query_result == .ERROR_DEVICE_LOST { return }
    
    check(query_result)
    
    for query, query_index in gpu_profiler.queries {
        timestamp := cast(f64) query_results[query_index] * cast(f64) gpu.device_properties.properties.limits.timestampPeriod * 1e-9
        
        zone := &gpu_profiler.zones[query.zone_index]
        
        switch query.kind {
        case .Begin:
            zone.total_time               -= timestamp
            zone.total_time_with_children -= timestamp
            
            if zone.parent_zone != -1 {
                parent := &gpu_profiler.zones[zone.parent_zone]
                parent.total_time               += timestamp
                parent.total_time_with_children -= timestamp
            }
            
        case .End:
            zone.total_time               += timestamp
            zone.total_time_with_children += timestamp
            
            if zone.parent_zone != -1 {
                parent := &gpu_profiler.zones[zone.parent_zone]
                parent.total_time               -= timestamp
                parent.total_time_with_children += timestamp
            }
        }
    }
    
    if print {
        fmt.printfln("---------------------\nGPU profile:")
        for zone in gpu_profiler.zones {
            xx :: proc (seconds: f64) -> time.Duration { return cast(time.Duration) (seconds * cast(f64) time.Second) }
            
            fmt.printf("  %25v: %v", zone.label, xx(zone.total_time))
            if zone.total_time_with_children != zone.total_time {
                fmt.printf(" (with children %v)", xx(zone.total_time_with_children))
            }
            fmt.printfln("")
        }
    }
}

gpu_profile_get_zone :: proc (label: string) -> (Profile_Zone, bool) #optional_ok {
    // @speed zones could have been a hashmap, or copied into one if needed
    result: Profile_Zone
    ok: bool
    for it in gpu_profiler.zones {
        if label == it.label {
            result = it
            ok = true
            break
        }
    }
    
    return result, ok
}

////////////////////////////////////////////////

gpu_labeled_region_begin :: proc (cb: vk.CommandBuffer, label: cstring, color: v4) {
    if !Optimized {
        vk.CmdBeginDebugUtilsLabelEXT(cb, &vk.DebugUtilsLabelEXT { sType = .DEBUG_UTILS_LABEL_EXT, pLabelName = label, color = color} )
    }
}
gpu_labeled_region_end :: proc (cb: vk.CommandBuffer) {
    if !Optimized {
        vk.CmdEndDebugUtilsLabelEXT(cb)
    }
}
