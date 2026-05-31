#+vet explicit-allocators
package main

import "base:runtime"
import "core:fmt"
import "core:os"

import vk "vendor:vulkan"
import "../libs/vma"

vk_debug_utils_callback :: proc "system" (messageSeverity: vk.DebugUtilsMessageSeverityFlagsEXT, messageTypes: vk.DebugUtilsMessageTypeFlagsEXT, pCallbackData: ^vk.DebugUtilsMessengerCallbackDataEXT, pUserData: rawptr) -> b32 {
    context = runtime.default_context()
    if .WARNING in messageSeverity || .ERROR in messageSeverity {
        fmt.printfln("Validation Layer: %v", pCallbackData.pMessage)
    }
    return false
}

vk_get_swapchain_format :: proc (ips: IPS) -> vk.Format {
    format_count: u32
    // @study(viktor): GetPhysicalDeviceSurfaceFormats2KHR: would this help?
    check(vk.GetPhysicalDeviceSurfaceFormatsKHR(ips.physical_device, ips.surface, &format_count, nil))
    formats := make([] vk.SurfaceFormatKHR, format_count, context.temp_allocator)
    check(vk.GetPhysicalDeviceSurfaceFormatsKHR(ips.physical_device, ips.surface, &format_count, raw_data(formats)))
    
    if len(formats) == 1 && formats[0].format == .UNDEFINED {
        return .R8G8B8A8_SRGB
    }
    
    for format in formats {
        if format.format == .R8G8B8A8_SRGB || format.format == .B8G8R8A8_SRGB {
            return format.format
        }
    }
    
    return formats[0].format
}

vk_create_swapchain :: proc (ips: IPS, device: vk.Device, window_size: uv2, format: vk.Format, infos: ^#soa [dynamic] Swapchain_Info, old_swapchain: vk.SwapchainKHR = 0) -> vk.SwapchainKHR {
    surface_capabilities: vk.SurfaceCapabilitiesKHR
    check(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(ips.physical_device, ips.surface, &surface_capabilities))
    
    swapchain_extent := surface_capabilities.currentExtent
    if surface_capabilities.currentExtent.width == 0xFFFFFFFF {
        swapchain_extent = vk_to_extent(window_size)
    }
    
    swapchain_create_info := vk.SwapchainCreateInfoKHR {
        sType = .SWAPCHAIN_CREATE_INFO_KHR,
        surface          = ips.surface,
        minImageCount    = surface_capabilities.minImageCount,
        imageFormat      = format,
        imageColorSpace  = .SRGB_NONLINEAR,
        imageExtent      = swapchain_extent,
        imageArrayLayers = 1,
        imageUsage       = { .COLOR_ATTACHMENT },
        preTransform     = { .IDENTITY },
        compositeAlpha   = { .OPAQUE },
        presentMode      = .FIFO,
        
        oldSwapchain = old_swapchain,
    }
    
    result: vk.SwapchainKHR
    check(vk.CreateSwapchainKHR(device, &swapchain_create_info, nil, &result))
    
    if old_swapchain != 0 {
        vk_destroy_swapchain(device, old_swapchain, infos)
    }
    
    image_count: u32
    check(vk.GetSwapchainImagesKHR(device, result, &image_count, nil))
    resize(infos, image_count)
    check(vk.GetSwapchainImagesKHR(device, result, &image_count, infos.image))
    
    for &info in infos {
        info.view = vk_create_2d_image_view(device, info.image, format, { .COLOR })
        info.render_completed = vk_create_semaphore(device)
    }
    
    return result
}

vk_destroy_swapchain :: proc (device: vk.Device, swapchain: vk.SwapchainKHR, infos: ^#soa [dynamic] Swapchain_Info) {
    for &info in infos {
        vk.DestroyImageView(device, info.view, nil)
        vk.DestroySemaphore(device, info.render_completed, nil)
    }
    clear(infos)
    vk.DestroySwapchainKHR(device, swapchain, nil)
}

// @cleanup this always happens after create_swapchain
vk_create_depth_image :: proc (device: vk.Device, depth_format: vk.Format, window_size: uv2, allocator: vma.Allocator) -> (vk.Image, vk.ImageView, vma.Allocation) {
    image: vk.Image
    allocation: vma.Allocation
    image_view: vk.ImageView
    
    depth_image_create_info := vk.ImageCreateInfo {
        sType = .IMAGE_CREATE_INFO,
        imageType = .D2,
        format = depth_format,
        extent = vk_to_extent(window_size, depth = 1),
        mipLevels = 1,
        arrayLayers = 1,
        samples = { ._1 },
        tiling = .OPTIMAL,
        usage = { .DEPTH_STENCIL_ATTACHMENT },
        initialLayout = .UNDEFINED,
    }
    
    alloc_create_info := vma.Allocation_Create_Info {
        flags = { .Dedicated_Memory },
        usage = .Auto,
    }
    
    check(vma.create_image(allocator, depth_image_create_info, alloc_create_info, &image, &allocation, nil))
    
    image_view = vk_create_2d_image_view(device, image, depth_format, { .DEPTH })
    
    return image, image_view, allocation
}

////////////////////////////////////////////////

vk_create_2d_image_view :: proc (device: vk.Device, image: vk.Image, format: vk.Format, aspect_mask: vk.ImageAspectFlags, level_count: u32 = 1) -> vk.ImageView {
    result: vk.ImageView
    
    check(vk.CreateImageView(device, &vk.ImageViewCreateInfo {
        sType = .IMAGE_VIEW_CREATE_INFO,
        image = image,
        viewType = .D2,
        format = format,
        subresourceRange = { aspectMask = aspect_mask, levelCount = level_count, layerCount = 1 },
    }, nil, &result))
    
    return result
}

@(thread_local)
transition_state: struct {
    is_open:  bool,
    barriers: [dynamic] vk.ImageMemoryBarrier2,
}

vk_begin_transition_images :: proc () {
    assert(!transition_state.is_open)
    
    transition_state.is_open = true
}

vk_append_image_memory_barrier_2 :: proc (image: vk.Image, src_stage_mask: vk.PipelineStageFlags2, src_access_mask: vk.AccessFlags2, old_layout: vk.ImageLayout, dst_stage_mask: vk.PipelineStageFlags2, dst_access_mask: vk.AccessFlags2, new_layout: vk.ImageLayout, aspect_mask := vk.ImageAspectFlags { .COLOR }) {
    assert(transition_state.is_open)
    
    append(&transition_state.barriers, vk.ImageMemoryBarrier2 {
        sType = .IMAGE_MEMORY_BARRIER_2,
        srcStageMask  = src_stage_mask,
        srcAccessMask = src_access_mask,
        dstStageMask  = dst_stage_mask,
        dstAccessMask = dst_access_mask,
        oldLayout = old_layout,
        newLayout = new_layout,
        image = image,
        subresourceRange = { aspectMask = aspect_mask, levelCount = vk.REMAINING_MIP_LEVELS, layerCount = vk.REMAINING_ARRAY_LAYERS },
    })
}

vk_end_transition_images :: proc (command_buffer: vk.CommandBuffer) {
    assert(transition_state.is_open)
    
    vk.CmdPipelineBarrier2(command_buffer, &vk.DependencyInfo {
        sType = .DEPENDENCY_INFO,
        imageMemoryBarrierCount = auto_cast len(transition_state.barriers),
        pImageMemoryBarriers    = raw_data(transition_state.barriers),
    })
    
    clear(&transition_state.barriers)
    transition_state.is_open = false
}

////////////////////////////////////////////////

vk_create_graphics_pipeline :: proc (device: vk.Device, swapchain_format, depth_format: vk.Format, descriptor_set_layout_textures: vk.DescriptorSetLayout, old_pipeline: vk.Pipeline = 0, old_pipeline_layout: vk.PipelineLayout = 0) ->  (vk.Pipeline, vk.PipelineLayout) {
    // @study(viktor): is a pipeline cache still a good optimization?
    pipeline: vk.Pipeline
    pipeline_layout: vk.PipelineLayout
    
    successful: bool
    
    shader_source := "tutorial/shader.slang"
    shader_output := "tutorial/shader.spirv"
    
    shader: if hotreload(shader_source) {
        cmd: Cmd
        cmd.allocator = context.temp_allocator
        append(&cmd, "slangc", "-target", "spirv", "-o", shader_output, shader_source)
        
        // @todo(viktor): start and test later if its finished?
        stdout: string
        stderr: string
        if !run_command(&cmd, or_exit = false, stdout = &stdout, stderr = &stderr) {
            // @logging
            break shader
        }
        
        if stdout != "" {
            fmt.printfln("Hotreload output: %v", stdout)
        }
        
        if stderr != "" {
            fmt.printfln("Hotreload error: %v", stderr)
            break shader
        }
        
        ////////////////////////////////////////////////
        
        shader_bytes, err := os.read_entire_file(shader_output, context.temp_allocator)
        assert(err == nil)
        
        shader_module_create_info := vk.ShaderModuleCreateInfo {
            sType = .SHADER_MODULE_CREATE_INFO,
            codeSize = len(shader_bytes),
            pCode = cast(^u32) &shader_bytes[0],
        }
        
        descriptor_set_layout_textures := descriptor_set_layout_textures
        pipeline_layout_create_info := vk.PipelineLayoutCreateInfo {
            sType = .PIPELINE_LAYOUT_CREATE_INFO,
            setLayoutCount = 1,
            pSetLayouts = &descriptor_set_layout_textures,
            pushConstantRangeCount = 1,
            pPushConstantRanges = &vk.PushConstantRange {
                stageFlags = { .VERTEX },
                size = size_of(vk.DeviceAddress),
            },
        }
        
        check(vk.CreatePipelineLayout(device, &pipeline_layout_create_info, nil, &pipeline_layout))
        
        vertex_attributes := [] vk.VertexInputAttributeDescription {
            { location = 0, binding = 0, format = .R32G32B32_SFLOAT },
            { location = 1, binding = 0, format = .R32G32B32_SFLOAT, offset = auto_cast offset_of(Vertex, n)  },
            { location = 2, binding = 0, format = .R32G32_SFLOAT,    offset = auto_cast offset_of(Vertex, uv) },
        }
        
        shader_stages := [] vk.PipelineShaderStageCreateInfo {
            { sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = { .VERTEX },   pName = "main", pNext = &shader_module_create_info },
            { sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = { .FRAGMENT }, pName = "main", pNext = &shader_module_create_info },
        }
        
        dynamic_states := [] vk.DynamicState { .VIEWPORT, .SCISSOR }
        
        swapchain_format := swapchain_format
        
        pipeline_create_info := vk.GraphicsPipelineCreateInfo {
            sType = .GRAPHICS_PIPELINE_CREATE_INFO,
            pNext = &vk.PipelineRenderingCreateInfo {
                sType = .PIPELINE_RENDERING_CREATE_INFO,
                colorAttachmentCount = 1,
                pColorAttachmentFormats = &swapchain_format,
                depthAttachmentFormat = depth_format,
            },
            stageCount = auto_cast len(shader_stages),
            pStages = raw_data(shader_stages),
            pVertexInputState = &vk.PipelineVertexInputStateCreateInfo {
                sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
                vertexBindingDescriptionCount = 1,
                pVertexBindingDescriptions = &vk.VertexInputBindingDescription {
                    binding = 0,
                    stride = size_of(Vertex),
                    inputRate = .VERTEX,
                },
                vertexAttributeDescriptionCount = auto_cast len(vertex_attributes),
                pVertexAttributeDescriptions = raw_data(vertex_attributes),
            },
            pInputAssemblyState = &vk.PipelineInputAssemblyStateCreateInfo {
                sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
                topology = .TRIANGLE_LIST,
            },
            pViewportState = &vk.PipelineViewportStateCreateInfo {
                sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
                viewportCount = 1,
                scissorCount  = 1,
            },
            pRasterizationState = &vk.PipelineRasterizationStateCreateInfo {
                sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
                cullMode = { .BACK },
                lineWidth = 1,
            },
            pMultisampleState = &vk.PipelineMultisampleStateCreateInfo {
                sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
                rasterizationSamples = { ._1 },
            },
            pDepthStencilState = &vk.PipelineDepthStencilStateCreateInfo {
                sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
                depthTestEnable  = true,
                depthWriteEnable = true,
                depthCompareOp   = .LESS_OR_EQUAL,
            },
            pColorBlendState = &vk.PipelineColorBlendStateCreateInfo {
                sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
                attachmentCount = 1,
                pAttachments = &vk.PipelineColorBlendAttachmentState {
                    colorWriteMask = { .R, .G, .B, .A },
                },
            },
            pDynamicState = &vk.PipelineDynamicStateCreateInfo {
                sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
                dynamicStateCount = auto_cast len(dynamic_states),
                pDynamicStates    = raw_data(dynamic_states),
            },
            layout = pipeline_layout,
        }
        
        check(vk.CreateGraphicsPipelines(device, 0, 1,&pipeline_create_info, nil, &pipeline))
        
        if old_pipeline_layout != 0 {
            vk.DestroyPipelineLayout(device, old_pipeline_layout, nil)
        }
        
        if old_pipeline != 0 {
            vk.DestroyPipeline(device, old_pipeline, nil)
        }
        
        successful = true
    } else {
        // @cleanup did not change file
        return old_pipeline, old_pipeline_layout
    }
    
    if !successful {
        if old_pipeline == 0 || old_pipeline_layout == 0 {
            assert(false, "Failed to create graphics pipeline")
        }
        pipeline        = old_pipeline
        pipeline_layout = old_pipeline_layout
    }
    
    return pipeline, pipeline_layout
}

////////////////////////////////////////////////

vk_create_semaphore :: proc (device: vk.Device, flags: vk.SemaphoreCreateFlags = {}, timeline_initial_value: Maybe(u64) = nil) -> vk.Semaphore {
    create_info := vk.SemaphoreCreateInfo { sType = .SEMAPHORE_CREATE_INFO, flags = flags }
    
    if timeline_value, is_timeline := timeline_initial_value.?; is_timeline {
        create_info.pNext = &vk.SemaphoreTypeCreateInfo {
            sType = .SEMAPHORE_TYPE_CREATE_INFO,
            semaphoreType = .TIMELINE,
            initialValue = timeline_value,
        }
    }
    
    result: vk.Semaphore
    check(vk.CreateSemaphore(device, &create_info, nil, &result))
    
    return result
}

vk_create_fence :: proc (device: vk.Device, flags: vk.FenceCreateFlags = {}) -> vk.Fence {
    result: vk.Fence
    check(vk.CreateFence(device, &vk.FenceCreateInfo { sType = .FENCE_CREATE_INFO, flags = flags }, nil, &result))
    return result
}

////////////////////////////////////////////////

vk_to_extent :: proc { vk_to_extent_2, vk_to_extent_3 }
vk_to_extent_2 :: proc (size: uv2) -> vk.Extent2D {
    result := vk.Extent2D {
        width  = size.x, 
        height = size.y,
    }
    return result
}
vk_to_extent_3 :: proc (size: uv2, depth: u32) -> vk.Extent3D {
    result := vk.Extent3D {
        width  = size.x, 
        height = size.y,
        depth  = depth
    }
    return result
}
