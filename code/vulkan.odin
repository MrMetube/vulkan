#+vet explicit-allocators
package main

import "base:intrinsics"
import "base:runtime"

_ :: runtime

import "core:fmt"
import "core:time"

import vk "vendor:vulkan"

Depth_Pyramid_Mip :: struct {
    view: vk.ImageView,
    size: uv2,
}

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
    bytes:  [] u8,
    
    parsed: struct {
        resource_mask:      Shader_Resource_Mask,
        resource_types:     [32] vk.DescriptorType,
        use_push_constants: bool,
        local_size:         [3] u32,
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
    
    last_transition: Transition,
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

recreate_swapchain :: proc (gpu: ^Gpu, new_size: uv2) {
    vk.DeviceWaitIdle(gpu.device)
    
    surface_capabilities: vk.SurfaceCapabilitiesKHR
    check(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(gpu.physical_device, gpu.surface, &surface_capabilities))
    
    // :Linux: Wayland had a special value for surface_capabilities.currentExtent.width
    swapchain_extent := surface_capabilities.currentExtent
    if swapchain_extent.width == 0 && swapchain_extent.height == 0 {
        if gpu.swapchain == 0 {
            assert(false, "Welp :(")
        }
        return
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
    assert(swapchain_extent == vk.Extent2D{ **new_size })
    gpu.swapchain_size = new_size
    
    previous_image_count := cast(u32) len(gpu.swapchain_images)
    
    check(vk.CreateSwapchainKHR(gpu.device, &swapchain_create_info, nil, &gpu.swapchain))
    
    image_count: u32
    check(vk.GetSwapchainImagesKHR(gpu.device, gpu.swapchain, &image_count, nil))
    
    if old_swapchain != 0 {
        destroy_swapchain(gpu, old_swapchain, image_count_did_change = previous_image_count != image_count)
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
}

// @cleanup this isnt a good design
destroy_swapchain :: proc (gpu: ^Gpu, old_swapchain: vk.SwapchainKHR = 0, image_count_did_change := true) { 
    if image_count_did_change {
        for &it in gpu.render_completes {
            vk.DestroySemaphore(gpu.device, it, nil)
        }
        clear(&gpu.render_completes)
        clear(&gpu.swapchain_images) // The swapchain's images are allocated for us, so we can just drop the handles.
    }
    
    vk.DestroySwapchainKHR(gpu.device, old_swapchain != 0 ? old_swapchain : gpu.swapchain, nil)
}

////////////////////////////////////////////////

@(thread_local)
barrier_state: struct {
    is_open:  bool,
    image_barriers:  [dynamic] vk.ImageMemoryBarrier2,
    buffer_barriers: [dynamic] vk.BufferMemoryBarrier2,
}

pipeline_barrier_begin :: proc () {
    assert(!barrier_state.is_open)
    
    barrier_state.is_open = true
}

add_image_barrier :: proc (image: ^Image, src_stage: vk.PipelineStageFlags2, src_access: vk.AccessFlags2, old_layout: vk.ImageLayout, dst_stage: vk.PipelineStageFlags2, dst_access: vk.AccessFlags2, new_layout: vk.ImageLayout, aspect_mask := vk.ImageAspectFlags { .COLOR }) {
    assert(barrier_state.is_open)
    append(&barrier_state.image_barriers, vk.ImageMemoryBarrier2 {
        sType = .IMAGE_MEMORY_BARRIER_2,
        srcAccessMask = src_access,
        dstAccessMask = dst_access,
        srcStageMask  = src_stage,
        dstStageMask  = dst_stage,
        oldLayout = old_layout,
        newLayout = new_layout,
        image = image.image,
        subresourceRange = { aspectMask = aspect_mask, levelCount = vk.REMAINING_MIP_LEVELS, layerCount = vk.REMAINING_ARRAY_LAYERS },
    })
    image.last_transition = { dst_stage, dst_access, new_layout }
}

add_buffer_barrier :: proc (buffer: ^Buffer, src_stage: vk.PipelineStageFlags2, src_access: vk.AccessFlags2, dst_stage: vk.PipelineStageFlags2, dst_access: vk.AccessFlags2) {
    assert(barrier_state.is_open)
    
    append(&barrier_state.buffer_barriers, vk.BufferMemoryBarrier2 {
        sType = .BUFFER_MEMORY_BARRIER_2,
        srcAccessMask = src_access,
        dstAccessMask = dst_access,
        srcStageMask  = src_stage,
        dstStageMask  = dst_stage,
        buffer = buffer.buffer,
        size   = auto_cast vk.WHOLE_SIZE,
    })
    
    buffer.last_transition = { stage = dst_stage, access = dst_access }
}

add_image_barrier_transition_from_last :: proc (image: ^Image, dst_stage: vk.PipelineStageFlags2, dst_access: vk.AccessFlags2, new_layout: vk.ImageLayout, aspect_mask := vk.ImageAspectFlags { .COLOR }) {
    last := image.last_transition
    add_image_barrier(image, last.stage, last.access, last.layout, dst_stage, dst_access, new_layout, aspect_mask)
}

add_buffer_barrier_transition_from_last :: proc (buffer: ^Buffer, dst_stage: vk.PipelineStageFlags2, dst_access: vk.AccessFlags2) {
    last := buffer.last_transition
    add_buffer_barrier(buffer, last.stage, last.access, dst_stage, dst_access)
}

pipeline_barrier_end :: proc (command_buffer: vk.CommandBuffer, flags := vk.DependencyFlags {}) {
    assert(barrier_state.is_open)
    
    vk.CmdPipelineBarrier2(command_buffer, &vk.DependencyInfo {
        sType = .DEPENDENCY_INFO,
        dependencyFlags          = flags, 
        imageMemoryBarrierCount  = auto_cast len(barrier_state.image_barriers),
        pImageMemoryBarriers     = raw_data(barrier_state.image_barriers),
        bufferMemoryBarrierCount = auto_cast len(barrier_state.buffer_barriers),
        pBufferMemoryBarriers    = raw_data(barrier_state.buffer_barriers),
    })
    
    clear(&barrier_state.image_barriers)
    clear(&barrier_state.buffer_barriers)
    barrier_state.is_open = false
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

gpu_end_the_command_buffer_and_submit_and_present_the_queue :: proc (gpu: ^Gpu, timeline_semaphore: vk.Semaphore, signal_value: u64, frame_index: u32, command_buffer: ^vk.CommandBuffer) {
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
    vk.QueueSubmit2(gpu.queue, 1, &submit_info, 0)
    
    present_info := vk.PresentInfoKHR {
        sType = .PRESENT_INFO_KHR,
        waitSemaphoreCount = 1,
        pWaitSemaphores    = &gpu.render_completes[gpu.image_index],
        swapchainCount     = 1,
        pSwapchains        = &gpu.swapchain,
        pImageIndices      = &gpu.image_index,
    }
    
    present_result := vk.QueuePresentKHR(gpu.queue, &present_info)
    if present_result == .ERROR_OUT_OF_DATE_KHR {
        gpu.should_recreate_swapchain = true
    } else {
        check(present_result)
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
