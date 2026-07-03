#+vet explicit-allocators
package main

import vk "../lib/vulkan"

Pipeline :: struct {
    pipeline: vk.Pipeline,
    
    bind_point:    vk.PipelineBindPoint,
    
    resource_types: [32] vk.DescriptorType,
    resource_mask:  Shader_Resource_Mask,
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
    image:  vk.Image,
    format: vk.Format,
    view:   vk.ImageView, // only required by gpu_begin_render_pass
    memory: vk.DeviceMemory,
    size:   uv3,
    
    last_stage:  vk.PipelineStageFlags2,
    last_access: vk.AccessFlags2,
    last_layout: vk.ImageLayout,
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
        gpu.swapchain_images[index].size  = { gpu.swapchain_size.x, gpu.swapchain_size.y, 1 }
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
    image.last_stage  = dst_stage
    image.last_access = dst_access
    image.last_layout = new_layout
    
    return result
}

create_image_barrier_from_last :: proc (image: ^Image, dst_stage: vk.PipelineStageFlags2, dst_access: vk.AccessFlags2, new_layout: vk.ImageLayout) -> vk.ImageMemoryBarrier2 {
    result := create_image_barrier(image, image.last_stage, image.last_access, image.last_layout, dst_stage, dst_access, new_layout)
    return result
}

gpu_image_barrier_from_last_transition :: proc (cmd: vk.CommandBuffer, image: ^Image, dst_stage: vk.PipelineStageFlags2, dst_access: vk.AccessFlags2, new_layout: vk.ImageLayout, flags := vk.DependencyFlags {}) {
    barrier := create_image_barrier_from_last(image, dst_stage, dst_access, new_layout)
    
    gpu_image_barriers(cmd, flags, barrier)
}

gpu_image_barrier :: proc (cmd: vk.CommandBuffer, image: ^Image, src_stage: vk.PipelineStageFlags2, src_access: vk.AccessFlags2, old_layout: vk.ImageLayout, dst_stage: vk.PipelineStageFlags2, dst_access: vk.AccessFlags2, new_layout: vk.ImageLayout, flags := vk.DependencyFlags {}) {
    barrier := create_image_barrier(image, src_stage, src_access, old_layout, dst_stage, dst_access, new_layout)
    
    gpu_image_barriers(cmd, flags, barrier)
}

gpu_image_barriers :: proc (cmd: vk.CommandBuffer, flags: vk.DependencyFlags, barriers: ..vk.ImageMemoryBarrier2) {
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

generate_heap_mappings :: proc (resource_mask: Shader_Resource_Mask, resource_types: [32] vk.DescriptorType, resource_names: [] string, push_constant_size: u32, descriptor_size, sampler_size: u32, mappings: ^[32] vk.DescriptorSetAndBindingMappingEXT) -> vk.ShaderDescriptorSetAndBindingMappingInfoEXT {
    mapping_offset: u32
    descriptor_offset: u32
    // :SamplerHack: we define name->id correspondence here for now; this will move to shader code when descriptor heaps conquer the world
	sampler_names := [] string {
		"texture_sampler",
		"filter_sampler",
		"depth_sampler",
	}
    
    // push descriptors
    for i in cast(u32) 0..<32 {
        if i in resource_mask {
            mapping := &mappings[mapping_offset]
            mapping_offset += 1
            
             mapping^ = {
                sType = .DESCRIPTOR_SET_AND_BINDING_MAPPING_EXT,
                
                descriptorSet = 0,
                firstBinding  = i,
                bindingCount  = 1,
                resourceMask  = vk.SpirvResourceTypeFlagsEXT_ALL,
            }
            
            if resource_types[i] == .SAMPLER {
                mapping.source = .HEAP_WITH_CONSTANT_OFFSET
                
                // :SamplerHack: for now we map samplers by name to avoid having to bind them via push path
				// in the future we will change the shader code to carry the name->binding correspondence statically
                
                for name, name_index in sampler_names {
                    if resource_names[i] == name {
                        mapping.sourceData.constantOffset.heapOffset = cast(u32) name_index * descriptor_size
                    }
                }
            } else {
                mapping.source = .HEAP_WITH_PUSH_INDEX
                mapping.sourceData.pushIndex = {
                    heapOffset = descriptor_offset * descriptor_size,
                    pushOffset = push_constant_size,
                    heapIndexStride = descriptor_size,
                    heapArrayStride = descriptor_size,
                }
                
                descriptor_offset += 1
            }
        }
    }
    
	{ // texture array descriptor
		mapping := &mappings[mapping_offset]
        mapping_offset += 1
        
		mapping^ = {
            sType = .DESCRIPTOR_SET_AND_BINDING_MAPPING_EXT,
            descriptorSet = 1,
            firstBinding = 0,
            bindingCount = 1,
            resourceMask =  vk.SpirvResourceTypeFlagsEXT_ALL,
            source = .HEAP_WITH_CONSTANT_OFFSET,
        }
		mapping.sourceData.constantOffset.heapArrayStride = descriptor_size
	}
	
	{ // sampler descriptors
		mapping := &mappings[mapping_offset]
        mapping_offset += 1
        
        mapping^ = {
            sType = .DESCRIPTOR_SET_AND_BINDING_MAPPING_EXT,
            descriptorSet = 2,
            firstBinding = 0,
            bindingCount = DescriptorSamplerLimit,
            resourceMask = vk.SpirvResourceTypeFlagsEXT_ALL,
            source = .HEAP_WITH_CONSTANT_OFFSET,
        }
		mapping.sourceData.constantOffset.heapArrayStride = descriptor_size
	}
    
	result := vk.ShaderDescriptorSetAndBindingMappingInfoEXT { 
        sType = .SHADER_DESCRIPTOR_SET_AND_BINDING_MAPPING_INFO_EXT,
        mappingCount = mapping_offset,
        pMappings    = &mappings[0],
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