#+vet explicit-allocators
package main

import "base:runtime"
import "core:fmt"

import vk "vendor:vulkan"
import sdl "vendor:sdl3"
import "lib:vma"

// @naming
IPS :: struct {
    instance:        vk.Instance,
    physical_device: vk.PhysicalDevice,
    surface:         vk.SurfaceKHR,
    device_properties: vk.PhysicalDeviceProperties2,
}

Swapchain :: struct {
    swapchain: vk.SwapchainKHR,
    images:           [dynamic] vk.Image,
    render_completes: [dynamic] vk.Semaphore,
    
    size:   uv2,
    format: vk.Format, // @cleanup this should be aligned with the color buffer
    
    color_buffer: Image,
    depth_buffer: Image,
}

Swapchain_Info :: struct {
    image: vk.Image,
    
    render_completed: vk.Semaphore,
}

Pipeline :: struct {
    pipeline: vk.Pipeline,
    layout:   vk.PipelineLayout,
    shader:   Shader,
}

Shader :: struct {
    stages: vk.ShaderStageFlags,
    bytes:  [] u8,
}

Image :: struct {
    format: vk.Format,
    image:  vk.Image,
    view:   vk.ImageView,
    memory: vk.DeviceMemory,
    
    // @cleanup only used by loaded ktx textures anymore
    allocation: vma.Allocation,
	sampler:    vk.Sampler,
}

Buffer :: struct {
    buffer: vk.Buffer,
    memory: vk.DeviceMemory,
    
    data: [] u8,
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

create_instance_physical_device_and_surface :: proc (window: ^sdl.Window, get_instance_proc: pmm) -> IPS {
    vk.GetInstanceProcAddr = auto_cast get_instance_proc
    vk.load_proc_addresses_global(auto_cast vk.GetInstanceProcAddr)
    
    ips: IPS
    {
        instance_extension_count: u32
        instance_extensions_raw := sdl.Vulkan_GetInstanceExtensions(&instance_extension_count)
        
        instance_extensions := make([dynamic] cstring, 0, instance_extension_count, context.temp_allocator)
        for i in 0..<instance_extension_count {
            append(&instance_extensions, instance_extensions_raw[i])
        }
        
        when !Optimized {
            append(&instance_extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)
        }
        
        instance_create_info := vk.InstanceCreateInfo {
            sType = .INSTANCE_CREATE_INFO,
            pApplicationInfo = &vk.ApplicationInfo {
                sType = .APPLICATION_INFO,
                pApplicationName = "How to Vulkan",
                apiVersion = vk.API_VERSION_1_4,
            },
            enabledExtensionCount   = auto_cast len(instance_extensions),
            ppEnabledExtensionNames = raw_data(instance_extensions),
        }
        
        when !Optimized {
            validation_layers := [] cstring { "VK_LAYER_KHRONOS_validation" }
            instance_create_info.enabledLayerCount   = auto_cast len(validation_layers)
            instance_create_info.ppEnabledLayerNames = raw_data(validation_layers)
            
            instance_create_info.pNext = &vk.DebugUtilsMessengerCreateInfoEXT {
                sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
                messageSeverity = { .VERBOSE, .WARNING, .ERROR },
                messageType = { .VALIDATION, .PERFORMANCE },
                pfnUserCallback = vulkan_debug_utils_callback,
            }
        }
        
        check(vk.CreateInstance(&instance_create_info, nil, &ips.instance))
        
        vk.load_proc_addresses_instance(ips.instance)
    }
    
    ////////////////////////////////////////////////
    
    ips.physical_device = choose_physical_device(ips)
    
    ips.device_properties = vk.PhysicalDeviceProperties2 { sType = .PHYSICAL_DEVICE_PROPERTIES_2 }
    vk.GetPhysicalDeviceProperties2(ips.physical_device, &ips.device_properties)
    fmt.printfln("Selected device: %v", cast(cstring) &ips.device_properties.properties.deviceName[0])
    assert(ips.device_properties.properties.limits.timestampComputeAndGraphics)
    
    ////////////////////////////////////////////////
    
    check(sdl.Vulkan_CreateSurface(window, ips.instance, nil, &ips.surface))
    
    return ips
}

choose_physical_device :: proc (ips: IPS) -> vk.PhysicalDevice {
    physical_devices: [] vk.PhysicalDevice
    {
        device_count: u32
        check(vk.EnumeratePhysicalDevices(ips.instance, &device_count, nil))
        physical_devices = make([] vk.PhysicalDevice, device_count, context.temp_allocator)
        check(vk.EnumeratePhysicalDevices(ips.instance, &device_count, raw_data(physical_devices)))
    }
    
    discrete: vk.PhysicalDevice
    fallback: vk.PhysicalDevice
    
    get_family_index_with_graphics :: proc (device: vk.PhysicalDevice) -> u32 {
        queue_family_count: u32
        vk.GetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, nil)
        queue_family_properties := make([] vk.QueueFamilyProperties, queue_family_count, context.temp_allocator)
        vk.GetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, raw_data(queue_family_properties))
        
        queue_family_index := vk.QUEUE_FAMILY_IGNORED
        for props, index in queue_family_properties {
            if .GRAPHICS in props.queueFlags {
                queue_family_index = auto_cast index
                break
            }
        }
        
        return queue_family_index
    }
    
    for device in physical_devices {
        family_index := get_family_index_with_graphics(device)
        
        if family_index == vk.QUEUE_FAMILY_IGNORED {
            continue
        }
        
        if !sdl.Vulkan_GetPresentationSupport(ips.instance, device, family_index) {
            continue
        }
        
        properties := vk.PhysicalDeviceProperties2 { sType = .PHYSICAL_DEVICE_PROPERTIES_2 }
        vk.GetPhysicalDeviceProperties2(device, &properties)
        
        if properties.properties.apiVersion < vk.API_VERSION_1_4 {
            continue
        }
        
        if discrete == nil && properties.properties.deviceType == .DISCRETE_GPU {
            discrete = device
        }
        
        if fallback == nil {
            fallback = device
        }
    }
    
    assert(fallback != nil, "Could not find any compatible device :(")
    
    result := discrete != nil ? discrete : fallback
    
    return result
}

////////////////////////////////////////////////

vulkan_debug_utils_callback :: proc "system" (messageSeverity: vk.DebugUtilsMessageSeverityFlagsEXT, messageTypes: vk.DebugUtilsMessageTypeFlagsEXT, pCallbackData: ^vk.DebugUtilsMessengerCallbackDataEXT, pUserData: rawptr) -> b32 {
    context = runtime.default_context()
    if .WARNING in messageSeverity || .ERROR in messageSeverity {
        fmt.printfln("Validation Layer: %v", pCallbackData.pMessage)
    }
    return false
}

get_swapchain_format :: proc (ips: IPS) -> vk.Format {
    format_count: u32
    // @study: GetPhysicalDeviceSurfaceFormats2KHR: would this help?
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

get_depth_buffer_format :: proc (ips: IPS) -> vk.Format {
    result: vk.Format
    
    // @todo(viktor): in niagara it is claimed, that we should "just use D32_SFLOAT" for depth buffer "these days"
    depth_format_list := [] vk.Format { .D32_SFLOAT_S8_UINT, .D24_UNORM_S8_UINT }
    for it in depth_format_list {
        format_properties := vk.FormatProperties2 { sType = .FORMAT_PROPERTIES_2 }
        vk.GetPhysicalDeviceFormatProperties2(ips.physical_device, it, &format_properties)
        
        if .DEPTH_STENCIL_ATTACHMENT in format_properties.formatProperties.optimalTilingFeatures {
            result = it
            break
        }
    }
    
    return result
}

recreate_swapchain :: proc (ips: IPS, device: vk.Device, new_size: uv2, old_swapchain: ^Swapchain) {
    // @cleanup this should not have changed so we could cache it in IPS
    surface_capabilities: vk.SurfaceCapabilitiesKHR
    check(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(ips.physical_device, ips.surface, &surface_capabilities))
    
    swapchain_extent := surface_capabilities.currentExtent
    // @note(viktor): this is like for wayland or something, dont know if i want to maintain that any further
    if surface_capabilities.currentExtent.width == 0xFFFFFFFF {
        swapchain_extent = to_extent(new_size)
    }
    
    if swapchain_extent.width == 0 && swapchain_extent.height == 0 {
        if old_swapchain == nil {
            assert(false, "Welp :(")
        }
        return
    }
    
    swapchain_create_info := vk.SwapchainCreateInfoKHR {
        sType = .SWAPCHAIN_CREATE_INFO_KHR,
        surface          = ips.surface,
        minImageCount    = surface_capabilities.minImageCount,
        imageFormat      = old_swapchain.format,
        imageColorSpace  = .SRGB_NONLINEAR,
        imageExtent      = swapchain_extent,
        imageArrayLayers = 1,
        imageUsage       = { .TRANSFER_DST },
        preTransform     = { .IDENTITY },
        compositeAlpha   = { .OPAQUE },
        presentMode      = VSync ? .FIFO : .IMMEDIATE,
        
        oldSwapchain = old_swapchain.swapchain,
    }
    
    result: Swapchain
    result.size   = new_size
    result.format = old_swapchain.format
    result.depth_buffer.format = old_swapchain.depth_buffer.format
    
    check(vk.CreateSwapchainKHR(device, &swapchain_create_info, nil, &result.swapchain))
    
    if old_swapchain.swapchain != 0 {
        destroy_swapchain(device, old_swapchain)
    }
    
    image_count: u32
    check(vk.GetSwapchainImagesKHR(device, result.swapchain, &image_count, nil))
    resize(&result.images, image_count)
    resize(&result.render_completes, image_count)
    check(vk.GetSwapchainImagesKHR(device, result.swapchain, &image_count, &result.images[0]))
    
    // @waste semaphores only need to be deleted and recreated, if the image_count changes up or down respectively
    for &it in result.render_completes {
        it = create_semaphore(device)
    }
    
    result.depth_buffer = gpu_make_image(result.size, result.depth_buffer.format, { .DEPTH_STENCIL_ATTACHMENT },         { .DEPTH })
    result.color_buffer = gpu_make_image(result.size, result.format,              { .COLOR_ATTACHMENT , .TRANSFER_SRC }, { .COLOR })
    
    old_swapchain ^= result
}

destroy_swapchain :: proc (device: vk.Device, swapchain: ^Swapchain) {
    for &it in swapchain.render_completes {
        vk.DestroySemaphore(device, it, nil)
    }
    clear(&swapchain.render_completes)
    // @note(viktor): the images are allocated for use, so we can just drop the handles
    clear(&swapchain.images)
    
    gpu_delete_image(swapchain.depth_buffer)
    gpu_delete_image(swapchain.color_buffer)
    
    vk.DestroySwapchainKHR(device, swapchain.swapchain, nil)
}

////////////////////////////////////////////////

create_device_queue_frames_and_command_pool_and_init_gpu_allocator :: proc (ips: IPS) -> (vk.Device, vk.Queue, (#soa [] Frame_Data), vk.CommandPool) {
    device: vk.Device
    queue_family_index: u32
    
    queue_family_priority := [] f32 { 1 }
    
    if false {
        // @todo(viktor): GetPhysicalDeviceFeatures2 crashes
        f14 := &vk.PhysicalDeviceVulkan14Features { sType = .PHYSICAL_DEVICE_VULKAN_1_4_FEATURES, pNext = nil }
        f13 := &vk.PhysicalDeviceVulkan13Features { sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES, pNext = &f14 }
        f12 := &vk.PhysicalDeviceVulkan12Features { sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, pNext = &f13 }
        f11 := &vk.PhysicalDeviceVulkan11Features { sType = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES, pNext = &f12 }
        supported_features := vk.PhysicalDeviceFeatures2 { sType = .PHYSICAL_DEVICE_FEATURES_2, pNext = &f11 }
        
        vk.GetPhysicalDeviceFeatures2(ips.physical_device, &supported_features)
        if 
            !f14.maintenance5 || !f14.pushDescriptor ||
            !f13.dynamicRendering ||  !f13.synchronization2 || 
            !f12.timelineSemaphore || !f12.descriptorIndexing || 
            !f12.shaderSampledImageArrayNonUniformIndexing || 
            !f12.descriptorBindingVariableDescriptorCount || 
            !f12.runtimeDescriptorArray || !f12.bufferDeviceAddress ||
            !f12.shaderInt8 || !f12.uniformAndStorageBuffer8BitAccess || 
            !f12.shaderFloat16 ||
            !f11.shaderDrawParameters || !f11.storageBuffer16BitAccess || !f11.uniformAndStorageBuffer16BitAccess {
            fmt.printfln("Physical device doesn't meet the feauture requirements")
            check(false)
        }
    }
    
    device_extensions := [] cstring { 
        vk.KHR_SWAPCHAIN_EXTENSION_NAME,
        vk.EXT_MESH_SHADER_EXTENSION_NAME,
    }
    
    device_create_info := vk.DeviceCreateInfo {
        sType = .DEVICE_CREATE_INFO,
        
        pNext = &vk.PhysicalDeviceFeatures2 {
            sType = .PHYSICAL_DEVICE_FEATURES_2,
            
            features = {
                samplerAnisotropy = true, // @note(viktor): since 1.4 this is required
                shaderInt16       = true,
                multiDrawIndirect = true, // @study check availablity in general nowadays
            },
            
        pNext = &vk.PhysicalDeviceVulkan14Features {
            sType = .PHYSICAL_DEVICE_VULKAN_1_4_FEATURES,
            
            maintenance5   = true, // @note(viktor): deprecates ShaderModule
            pushDescriptor = true, // @note(viktor): remove the need for CmdBindVertexBuffers
            dynamicRenderingLocalRead = true, // @note(viktor): allows rendering to an image and then copying into the swapchain image, whilst using dynamic_rendering
            
            // @todo(viktor): check if this would help the texture upload hostImageCopy
            // hostImageCopy = true,
            // @note(viktor): scalarBlockLayout - struct members are padded like c/c++ would, I assume it makes simple memcopy possible
            
        pNext = &vk.PhysicalDeviceVulkan13Features {
            sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
            
            synchronization2 = true,
            dynamicRendering = true,
            
        pNext = &vk.PhysicalDeviceVulkan12Features {
            sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
            descriptorIndexing                        = true,
            shaderSampledImageArrayNonUniformIndexing = true,
            descriptorBindingVariableDescriptorCount  = true,
            runtimeDescriptorArray                    = true,
            bufferDeviceAddress                       = true,
            timelineSemaphore                         = true,
            
            shaderFloat16 = true,
            shaderInt8    = true,
            uniformAndStorageBuffer8BitAccess = true,
            storageBuffer8BitAccess           = true,
            
        pNext = &vk.PhysicalDeviceVulkan11Features {
            sType = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
            
            storageBuffer16BitAccess = true,
            uniformAndStorageBuffer16BitAccess = true,
            shaderDrawParameters = true,
            
        pNext = &vk.PhysicalDeviceMeshShaderFeaturesEXT {
            sType = .PHYSICAL_DEVICE_MESH_SHADER_FEATURES_EXT,
            
            meshShader = true,
            taskShader = true,
        },
        },
        },
        },
        },
        },
        
        queueCreateInfoCount = 1,
        pQueueCreateInfos    = &vk.DeviceQueueCreateInfo {
            sType = .DEVICE_QUEUE_CREATE_INFO,
            queueFamilyIndex = queue_family_index,
            queueCount       = auto_cast len(queue_family_priority),
            pQueuePriorities = raw_data(queue_family_priority),
        },
        
        enabledExtensionCount   = auto_cast len(device_extensions),
        ppEnabledExtensionNames = raw_data(device_extensions),
    }
    
    check(vk.CreateDevice(ips.physical_device, &device_create_info, nil, &device))
    
    vk.load_proc_addresses_device(device)

    ////////////////////////////////////////////////
    
    queue: vk.Queue
    vk.GetDeviceQueue(device, queue_family_index, 0, &queue)
    
    ////////////////////////////////////////////////
    
    init_gpu_allocator(ips, device)
    
    ////////////////////////////////////////////////
    
    frames := make(#soa [] Frame_Data, MaxFramesInFlight, context.allocator)
    
    for &frame in frames {
        frame.buffer = gpu_make_buffer({ .SHADER_DEVICE_ADDRESS }, size_of(Draw_Globals))
        
        device_address_info := vk.BufferDeviceAddressInfo {
            sType  = .BUFFER_DEVICE_ADDRESS_INFO,
            buffer = frame.buffer.buffer,
        }
        frame.deviceAddress = vk.GetBufferDeviceAddress(device, &device_address_info)
        
        frame.image_aquired = create_semaphore(device)
        defer_destroy(vk.DestroySemaphore, frame.image_aquired)
    }
    
    ////////////////////////////////////////////////
    
    command_pool: vk.CommandPool
    {
        command_pool_create_info := vk.CommandPoolCreateInfo {
            sType = .COMMAND_POOL_CREATE_INFO,
            flags            = { .RESET_COMMAND_BUFFER },
            queueFamilyIndex = queue_family_index,
        }
        
        check(vk.CreateCommandPool(device, &command_pool_create_info, nil, &command_pool))
        
        command_buffer_allocate_info := vk.CommandBufferAllocateInfo {
            sType = .COMMAND_BUFFER_ALLOCATE_INFO,
            commandPool        = command_pool,
            commandBufferCount = cast(u32) len(frames),
        }
        check(vk.AllocateCommandBuffers(device, &command_buffer_allocate_info, &frames.command_buffer[0]))
        defer_destroy(vk.DestroyCommandPool, command_pool)
    }
    
    return device, queue, frames, command_pool
}

////////////////////////////////////////////////

@(thread_local)
transition_state: struct {
    is_open:  bool,
    barriers: [dynamic] vk.ImageMemoryBarrier2,
}

begin_transition_images :: proc () {
    assert(!transition_state.is_open)
    
    transition_state.is_open = true
}

append_image_memory_barrier_2 :: proc (image: vk.Image, src_access_mask: vk.AccessFlags2, old_layout: vk.ImageLayout, dst_access_mask: vk.AccessFlags2, new_layout: vk.ImageLayout, aspect_mask := vk.ImageAspectFlags { .COLOR }) {
    assert(transition_state.is_open)
    
    append(&transition_state.barriers, vk.ImageMemoryBarrier2 {
        sType = .IMAGE_MEMORY_BARRIER_2,
        srcAccessMask = src_access_mask,
        dstAccessMask = dst_access_mask,
        oldLayout = old_layout,
        newLayout = new_layout,
        image = image,
        subresourceRange = { aspectMask = aspect_mask, levelCount = vk.REMAINING_MIP_LEVELS, layerCount = vk.REMAINING_ARRAY_LAYERS },
    })
}

end_transition_images :: proc (command_buffer: vk.CommandBuffer, src_stage_mask, dst_stage_mask: vk.PipelineStageFlags2) {
    assert(transition_state.is_open)
    
    for &it in transition_state.barriers {
        it.srcStageMask = src_stage_mask
        it.dstStageMask = dst_stage_mask
    }
    
    vk.CmdPipelineBarrier2(command_buffer, &vk.DependencyInfo {
        sType = .DEPENDENCY_INFO,
        imageMemoryBarrierCount = auto_cast len(transition_state.barriers),
        pImageMemoryBarriers    = raw_data(transition_state.barriers),
    })
    
    clear(&transition_state.barriers)
    transition_state.is_open = false
}

////////////////////////////////////////////////

shader_source := "shader.slang"
shader_output := "shader.spirv"

should_recreate_pipeline :: proc (pipeline: Pipeline) -> bool {
    if pipeline.pipeline == 0 {
        return true
    }
    
    if is_newer(shader_source, shader_output) {
        return true
    }
    
    return false
}

create_graphics_pipeline :: proc (device: vk.Device, swapchain: Swapchain, set_layouts: [] vk.DescriptorSetLayout, old: Pipeline = {}) -> Pipeline {
    shader, ok := recompile_shader(shader_source, shader_output, context.temp_allocator)
    if !ok {
        if old.pipeline == 0 || old.layout == 0 {
            assert(false, "Failed to create graphics pipeline")
        }
        return old
    }
    
    shader_module_create_info := vk.ShaderModuleCreateInfo {
        sType = .SHADER_MODULE_CREATE_INFO,
        codeSize = len(shader.bytes),
        pCode    = cast(^u32) &shader.bytes[0],
    }
    
    ////////////////////////////////////////////////
    
    // @study: is a pipeline cache still a good optimization?
    result: Pipeline
    result.shader = shader
        
    ranges := [?] vk.PushConstantRange {
        {
            stageFlags = shader.stages,
            size       = size_of(Push_Data),
        },
    }
    
    pipeline_layout_create_info := vk.PipelineLayoutCreateInfo {
        sType = .PIPELINE_LAYOUT_CREATE_INFO,
        setLayoutCount = cast(u32) len(set_layouts),
        pSetLayouts    = &set_layouts[0],
        pushConstantRangeCount = len(ranges),
        pPushConstantRanges    = &ranges[0],
    }
    
    check(vk.CreatePipelineLayout(device, &pipeline_layout_create_info, nil, &result.layout))
    
    shader_stages: [dynamic; 16] vk.PipelineShaderStageCreateInfo
    for stage in shader.stages {
        append(&shader_stages, vk.PipelineShaderStageCreateInfo{ 
            sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, 
            stage = { stage }, 
            pName = "main", 
            pNext = &shader_module_create_info,
        })
    }
    
    dynamic_states := [] vk.DynamicState { .VIEWPORT, .SCISSOR }
    
    swapchain_format := swapchain.format
    
    pipeline_create_info := vk.GraphicsPipelineCreateInfo {
        sType = .GRAPHICS_PIPELINE_CREATE_INFO,
        pNext = &vk.PipelineRenderingCreateInfo {
            sType = .PIPELINE_RENDERING_CREATE_INFO,
            colorAttachmentCount    = 1,
            pColorAttachmentFormats = &swapchain_format,
            depthAttachmentFormat   = swapchain.depth_buffer.format,
        },
        stageCount = auto_cast len(shader_stages),
        pStages    = &shader_stages[0],
        pVertexInputState = &vk.PipelineVertexInputStateCreateInfo { sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO },
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
            depthCompareOp   = .GREATER,
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
        layout = result.layout,
    }
    
    check(vk.CreateGraphicsPipelines(device, 0, 1,&pipeline_create_info, nil, &result.pipeline))
    
    check(vk.DeviceWaitIdle(device))
    
    destroy_pipeline(device, old)
    
    return result
}

destroy_pipeline :: proc (device: vk.Device, pipeline: Pipeline) {
    if pipeline.layout != 0 {
        vk.DestroyPipelineLayout(device, pipeline.layout, nil)
    }
    
    if pipeline.pipeline != 0 {
        vk.DestroyPipeline(device, pipeline.pipeline, nil)
    }
}

create_vertex_update_template :: proc (device: vk.Device, pipeline: Pipeline, storage_buffer_count: u32, old: vk.DescriptorUpdateTemplate = 0) -> vk.DescriptorUpdateTemplate {
    vk.DestroyDescriptorUpdateTemplate(device, old, nil)
    
    // @todo(viktor): The information of which shader stage needs which storage buffer could be parsed from the compiled spirv file.
    // But currently the single shader file contains multiple shader stages, so it would be non trivial to figure out which stage 
    // makes use of a binding. Otherwise we could just maximally bind buffers, so that we atleast never miss a required buffer.
    update_template_entries: [dynamic; 128] vk.DescriptorUpdateTemplateEntry
    for index in 0..<storage_buffer_count {
        append(&update_template_entries, vk.DescriptorUpdateTemplateEntry {
            dstBinding      = index,
            descriptorType  = .STORAGE_BUFFER,
            descriptorCount = 1,
            offset          = cast(int) index * size_of(DescriptorUpdateData),
            stride          = size_of(DescriptorUpdateData),
        })
    }
        
    create_info := vk.DescriptorUpdateTemplateCreateInfo {
        sType = .DESCRIPTOR_UPDATE_TEMPLATE_CREATE_INFO,
        pipelineBindPoint   = .GRAPHICS,
        pipelineLayout      = pipeline.layout,
        templateType        = .PUSH_DESCRIPTORS,
        descriptorUpdateEntryCount = cast(u32) len(update_template_entries),
        pDescriptorUpdateEntries   = &update_template_entries[0],
    }
    
    result: vk.DescriptorUpdateTemplate
    check(vk.CreateDescriptorUpdateTemplate(device, &create_info, nil, &result))
    return result
}

////////////////////////////////////////////////

begin_rendering :: proc (cb: vk.CommandBuffer, swapchain: Swapchain, color_buffer: Image, image_index: u32, clear_color: v4) {
    rendering_info := vk.RenderingInfo {
        sType = .RENDERING_INFO, 
        renderArea = { extent = to_extent(swapchain.size) },
        layerCount = 1,
        colorAttachmentCount = 1,
        pColorAttachments = &vk.RenderingAttachmentInfo {
            sType = .RENDERING_ATTACHMENT_INFO,
            imageView   = color_buffer.view,
            imageLayout = .ATTACHMENT_OPTIMAL,
            loadOp      = .CLEAR,
            storeOp     = .STORE,
            clearValue  = { color = { float32 = clear_color } },
        },
        pDepthAttachment  = &vk.RenderingAttachmentInfo {
            sType = .RENDERING_ATTACHMENT_INFO,
            imageView   = swapchain.depth_buffer.view,
            imageLayout = .ATTACHMENT_OPTIMAL,
            loadOp      = .CLEAR,
            storeOp     = .DONT_CARE,
            clearValue  = { depthStencil = { 0, 0 } }, // :ReversedZ: 0 is the maximal value
        },
    }
    
    vk.CmdBeginRendering(cb, &rendering_info)
}

queue_submit :: proc (queue: vk.Queue, swapchain: Swapchain, frame: Frame_Data, image_index: u32, signal_value: u64, timeline_semaphore: vk.Semaphore) {
    render_complete_and_timeline_submit_info := [] vk.SemaphoreSubmitInfo {
        {
            sType = .SEMAPHORE_SUBMIT_INFO,
            semaphore = swapchain.render_completes[image_index],
            stageMask = { .ALL_GRAPHICS },
        },
        {
            sType = .SEMAPHORE_SUBMIT_INFO,
            semaphore = timeline_semaphore,
            value = signal_value,
            stageMask = { .ALL_COMMANDS },
        },
    }
    
    submit_info := vk.SubmitInfo2 {
        sType = .SUBMIT_INFO_2,
        waitSemaphoreInfoCount = 1,
        pWaitSemaphoreInfos = &vk.SemaphoreSubmitInfo {
            sType = .SEMAPHORE_SUBMIT_INFO,
            semaphore = frame.image_aquired,
            stageMask = { .TRANSFER },
        },
        commandBufferInfoCount = 1,
        pCommandBufferInfos = &vk.CommandBufferSubmitInfo {
            sType = .COMMAND_BUFFER_SUBMIT_INFO,
            commandBuffer = frame.command_buffer,
        },
        signalSemaphoreInfoCount = auto_cast len(render_complete_and_timeline_submit_info),
        pSignalSemaphoreInfos    = raw_data(render_complete_and_timeline_submit_info),
    }
    vk.QueueSubmit2(queue, 1, &submit_info, 0)
}

////////////////////////////////////////////////

@(thread_local) gpu_allocator_state: struct {
    initialized: bool,
    
    device: vk.Device,
    memory_properties: vk.PhysicalDeviceMemoryProperties,
}

init_gpu_allocator :: proc (ips: IPS, device: vk.Device) {
    memory_properties: vk.PhysicalDeviceMemoryProperties
    vk.GetPhysicalDeviceMemoryProperties(ips.physical_device, &memory_properties)
    
    gpu_allocator_state = {
        initialized = true,
        device = device,
        memory_properties = memory_properties,
    }
}

gpu_make_buffer :: proc { gpu_make_buffer_slice, gpu_make_buffer_size }
gpu_make_buffer_slice :: proc (usage: vk.BufferUsageFlags, $S: typeid / [] $E, #any_int len: umm) -> (Buffer, S) {
    // @todo(viktor): why then even store the [] u8 in the Buffer struct?
    size   := size_of(E) * len
    buffer := gpu_make_buffer_size(usage, size)
    view   := slice_from_parts(E, &buffer.data[0], len)
    return buffer, view
}
gpu_make_buffer_size :: proc (usage: vk.BufferUsageFlags, #any_int size: vk.DeviceSize) -> Buffer {
    assert(gpu_allocator_state.initialized)
    
    device := gpu_allocator_state.device
    
    create_info := vk.BufferCreateInfo {
        sType = .BUFFER_CREATE_INFO,
        size  = size,
        usage = usage,
    }
    
    result: Buffer
    check(vk.CreateBuffer(device, &create_info, nil, &result.buffer))
    
    requirements: vk.MemoryRequirements
    vk.GetBufferMemoryRequirements(device, result.buffer, &requirements)
    
    flags := vk.MemoryPropertyFlags { .HOST_VISIBLE, .HOST_COHERENT }
    
    result.memory = select_memory_type_and_allocate(requirements, flags, add_device_address_flag = .SHADER_DEVICE_ADDRESS in usage)
    
    check(vk.BindBufferMemory(device, result.buffer, result.memory, 0))
    
    raw := cast(^RawSlice) &result.data
    raw.len = cast(int) size
    vk.MapMemory(device, result.memory, 0, size, {}, &raw.data)
    
    return result
}

gpu_make_image :: proc (size: uv2, format: vk.Format, usage: vk.ImageUsageFlags, aspect_mask: vk.ImageAspectFlags, flags := vk.MemoryPropertyFlags { .DEVICE_LOCAL }) -> Image {
    assert(gpu_allocator_state.initialized)
    
    device := gpu_allocator_state.device
    
    create_info := vk.ImageCreateInfo {
        sType = .IMAGE_CREATE_INFO,
        imageType     = .D2,
        format        = format,
        extent        = to_extent(size, 1),
        mipLevels     = 1,
        arrayLayers   = 1,
        samples       = { ._1 },
        tiling        = .OPTIMAL,
        usage         = usage,
        initialLayout = .UNDEFINED,
    }
    
    result: Image
    result.format = format
    check(vk.CreateImage(device, &create_info, nil, &result.image))
    
    requirements: vk.MemoryRequirements
    vk.GetImageMemoryRequirements(device, result.image, &requirements)
    
    result.memory = select_memory_type_and_allocate(requirements, flags)
    
    check(vk.BindImageMemory(device, result.image, result.memory, 0))
    
    result.view = create_image_view(device, result.image, format, aspect_mask)
    
    return result
}

select_memory_type_and_allocate :: proc (requirements: vk.MemoryRequirements, flags: vk.MemoryPropertyFlags, add_device_address_flag := false) -> vk.DeviceMemory {
    assert(gpu_allocator_state.initialized)
    
    device := gpu_allocator_state.device
    memory_properties := gpu_allocator_state.memory_properties
    
    selected_memory_type_index: u32
    select: {
        set   := transmute(bit_set[0..=31; u32]) requirements.memoryTypeBits
        types := memory_properties.memoryTypes[:memory_properties.memoryTypeCount]
        for type, i in types {
            if i in set && flags <= type.propertyFlags {
                selected_memory_type_index = cast(u32) i
                break select
            }
        }
        
        assert(false, "No compatible memory type found")
    }
    
    
    allocate_info := vk.MemoryAllocateInfo {
        sType = .MEMORY_ALLOCATE_INFO,
        allocationSize = requirements.size,
        memoryTypeIndex = selected_memory_type_index,
    }
    
    info_for_device_address := vk.MemoryAllocateFlagsInfo {
        sType = .MEMORY_ALLOCATE_FLAGS_INFO,
        flags = { .DEVICE_ADDRESS },
    }
    if add_device_address_flag {
        allocate_info.pNext = &info_for_device_address
    }
    

    memory: vk.DeviceMemory
    check(vk.AllocateMemory(device, &allocate_info, nil, &memory))
    
    return memory
}

create_image_view :: proc (device: vk.Device, image: vk.Image, format: vk.Format, aspect_mask: vk.ImageAspectFlags, level_count: u32 = 1) -> vk.ImageView {
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

/* :ScratchBuffer:
from  Optimizing mesh rendering https://youtu.be/ayKoqK3kQ9c?list=PL0JVLUVCkk-l7CWCn3-cdftR0oajugYvd&t=2359
void uploadBuffer(VkDevice device, VkCommandPool commandPool, VkCommandBuffer commandBuffer, VkQueue queue, const Buffer& buffer, const Buffer& scratch, const void* data, size_t size)

    assert(scratch.data);
    assert(scratch.size >= size);
    memcpy(scratch.data, data, size);

    VK_CHECK(vkResetCommandPool(device, commandPool, 0));

    VkCommandBufferBeginInfo beginInfo = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    beginInfo.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;

    VK_CHECK(vkBeginCommandBuffer(commandBuffer, &beginInfo));

    VkBufferCopy region = { 0, 0, VkDeviceSize(size) };
    vkCmdCopyBuffer(commandBuffer, scratch.buffer, buffer.buffer, 1, &region);

    VkBufferMemoryBarrier copyBarrier = { VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER };
    copyBarrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    copyBarrier.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
    copyBarrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    copyBarrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    copyBarrier.buffer = buffer.buffer;
    copyBarrier.offset = 0;
    copyBarrier.size = size;

    vkCmdPipelineBarrier(commandBuffer, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_DEPENDENCY_BY_REGION_BIT, 0,0,1, &copyBarrier, 0,0);

    VK_CHECK(vkEndCommandBuffer(commandBuffer));

    VkSubmitInfo submitInfo = { VK_STRUCTURE_TYPE_SUBMIT_INFO };
    submitInfo.commandBufferCount = 1;
    submitInfo.pCommandBuffers = &commandBuffer;

    VK_CHECK(vkQueueSubmit(queue, 1, &submitInfo, VK_NULL_HANDLE));

    VK_CHECK(vkDeviceWaitIdle(device));
}
*/

gpu_delete_buffer :: proc (buffer: Buffer) {
    assert(gpu_allocator_state.initialized)
    device := gpu_allocator_state.device
    
    vk.DestroyBuffer(device, buffer.buffer, nil)
    vk.FreeMemory(device,    buffer.memory, nil)
}

gpu_delete_image :: proc (image: Image) {
    assert(gpu_allocator_state.initialized)
    device := gpu_allocator_state.device
    
    vk.DestroyImageView(device, image.view, nil)
    vk.DestroyImage(device,     image.image, nil)
    vk.FreeMemory(device,       image.memory, nil)
}

////////////////////////////////////////////////

create_semaphore :: proc (device: vk.Device, flags: vk.SemaphoreCreateFlags = {}, timeline_initial_value: Maybe(u64) = nil) -> vk.Semaphore {
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

create_fence :: proc (device: vk.Device, flags: vk.FenceCreateFlags = {}) -> vk.Fence {
    result: vk.Fence
    check(vk.CreateFence(device, &vk.FenceCreateInfo { sType = .FENCE_CREATE_INFO, flags = flags }, nil, &result))
    return result
}

////////////////////////////////////////////////

to_extent :: proc { to_extent_2, to_extent_3 }
to_extent_2 :: proc (size: uv2) -> vk.Extent2D {
    result := vk.Extent2D {
        width  = size.x, 
        height = size.y,
    }
    return result
}
to_extent_3 :: proc (size: uv2, depth: u32) -> vk.Extent3D {
    result := vk.Extent3D {
        width  = size.x, 
        height = size.y,
        depth  = depth,
    }
    return result
}
