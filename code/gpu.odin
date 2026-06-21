#+vet explicit-allocators !unused-procedures
package main

import "base:runtime"

import "core:fmt"

import vk  "vendor:vulkan"
import sdl "vendor:sdl3"

/* 

    I should really just import the cpu profiler and extract the common parts from it and the gpu profiler. Then I should just be able to let them both feed the same object with data and let it derive results from that data once.
     
    The third pass is to provide the "no graphics api"-api, or something as close to it as possible.

*/

MaxFramesInFlight :: 2

Gpu :: struct {
    // @cleanup
    image_index: u32, 
    absolute_frame_index: u32,
    should_recreate_swapchain: bool,
    
    ////////////////////////////////////////////////
    // stuff that exists only once
    
    // @cleanup does anyone even need access to this?
    instance:          vk.Instance,
    physical_device:   vk.PhysicalDevice,
    surface:           vk.SurfaceKHR,
    device_properties: vk.PhysicalDeviceProperties2, 
    memory_properties: vk.PhysicalDeviceMemoryProperties,
    
    device:       vk.Device,
    command_pool: vk.CommandPool,
    queue:        vk.Queue,
    
    // @incomplete this is never initialized. It may help performance if we need to create/recreate many pipelines.
    pipeline_cache: vk.PipelineCache,
    
    ////////////////////////////////////////////////
    
    timeline_semaphore: vk.Semaphore,
    signal_value: u64,
    
    command_buffers:          [MaxFramesInFlight] vk.CommandBuffer,
    image_aquired_semaphores: [MaxFramesInFlight] vk.Semaphore,
    
    ////////////////////////////////////////////////
    // these all have the same lifetime as the swapchain
    
    swapchain: vk.SwapchainKHR,
    swapchain_images: [dynamic] Image, // this is only an image to make use of the last: Transition
    render_completes: [dynamic] vk.Semaphore,
    
    swapchain_size:   uv2,
    swapchain_format: vk.Format, // @cleanup is this always just the color_buffers format?
    color_buffer: Image,
    depth_buffer: Image,
}

////////////////////////////////////////////////

gpu_init :: proc (window: ^sdl.Window) -> Gpu {
    result: Gpu
    result.signal_value = MaxFramesInFlight
    
    ////////////////////////////////////////////////
    
    { // create_instance_physical_device_and_surface
        vk.GetInstanceProcAddr = auto_cast sdl.Vulkan_GetVkGetInstanceProcAddr()
        vk.load_proc_addresses_global(auto_cast vk.GetInstanceProcAddr)
        
        {
            instance_extension_count: u32
            instance_extensions_raw := sdl.Vulkan_GetInstanceExtensions(&instance_extension_count)
            
            instance_extensions: [dynamic; 128] cstring
            assert(instance_extension_count <= cap(instance_extensions))
            
            append(&instance_extensions, ..instance_extensions_raw[:instance_extension_count])
            
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
                ppEnabledExtensionNames = &instance_extensions[0],
            }
            
            _ :: runtime
            when !Optimized {
                validation_layers := [] cstring { "VK_LAYER_KHRONOS_validation" }
                instance_create_info.enabledLayerCount   = auto_cast len(validation_layers)
                instance_create_info.ppEnabledLayerNames = raw_data(validation_layers)
                
                vulkan_debug_utils_callback :: proc "system" (messageSeverity: vk.DebugUtilsMessageSeverityFlagsEXT, messageTypes: vk.DebugUtilsMessageTypeFlagsEXT, pCallbackData: ^vk.DebugUtilsMessengerCallbackDataEXT, pUserData: rawptr) -> b32 {
                    context = runtime.default_context()
                    if .WARNING in messageSeverity || .ERROR in messageSeverity {
                        fmt.printfln("Validation Layer: %v", pCallbackData.pMessage)
                    }
                    return false
                }
                
                enabled := [?] vk.ValidationFeatureEnableEXT {
                    .BEST_PRACTICES,
                    // DEBUG_PRINTF // @todo enable this, if needed
                    .SYNCHRONIZATION_VALIDATION,
                }
                
                instance_create_info.pNext = &vk.DebugUtilsMessengerCreateInfoEXT {
                    sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
                    messageSeverity = { .VERBOSE, .WARNING, .ERROR },
                    messageType     = { .VALIDATION, .PERFORMANCE },
                    pfnUserCallback = vulkan_debug_utils_callback,
                    
                    pNext = &vk.ValidationFeaturesEXT {
                        sType = .VALIDATION_FEATURES_EXT,
                        enabledValidationFeatureCount = len(enabled),
                        pEnabledValidationFeatures = &enabled[0],
                    },
                }
            }
            
            check(vk.CreateInstance(&instance_create_info, nil, &result.instance))
            
            vk.load_proc_addresses_instance(result.instance)
        }
        
        ////////////////////////////////////////////////
        
        {
            physical_devices: [] vk.PhysicalDevice
            {
                device_count: u32
                check(vk.EnumeratePhysicalDevices(result.instance, &device_count, nil))
                physical_devices = make([] vk.PhysicalDevice, device_count, context.temp_allocator)
                check(vk.EnumeratePhysicalDevices(result.instance, &device_count, raw_data(physical_devices)))
            }
            
            discrete: vk.PhysicalDevice
            fallback: vk.PhysicalDevice
            
            for device in physical_devices {
                family_index_with_graphics := vk.QUEUE_FAMILY_IGNORED
                {
                    queue_family_count: u32
                    vk.GetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, nil)
                    queue_family_properties := make([] vk.QueueFamilyProperties, queue_family_count, context.temp_allocator)
                    vk.GetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, raw_data(queue_family_properties))
                    
                    for props, index in queue_family_properties {
                        if .GRAPHICS in props.queueFlags {
                            family_index_with_graphics = auto_cast index
                            break
                        }
                    }
                }
                
                if family_index_with_graphics == vk.QUEUE_FAMILY_IGNORED {
                    continue
                }
                
                if !sdl.Vulkan_GetPresentationSupport(result.instance, device, family_index_with_graphics) {
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
            
            result.physical_device = discrete != nil ? discrete : fallback
        }
        
        result.device_properties = vk.PhysicalDeviceProperties2 { sType = .PHYSICAL_DEVICE_PROPERTIES_2 }
        vk.GetPhysicalDeviceProperties2(result.physical_device, &result.device_properties)
        
        fmt.printfln("Selected device: %v", cast(cstring) &result.device_properties.properties.deviceName[0])
        assert(result.device_properties.properties.limits.timestampComputeAndGraphics)
        
        ////////////////////////////////////////////////
        
        check(sdl.Vulkan_CreateSurface(window, result.instance, nil, &result.surface))
    }
    
    ////////////////////////////////////////////////
    
    
    { // create_device_queue_frames_and_command_pool_and_init_gpu_allocator
        queue_family_index: u32
        
        device_extensions := [] cstring { 
            vk.KHR_SWAPCHAIN_EXTENSION_NAME,
            vk.EXT_MESH_SHADER_EXTENSION_NAME,
            vk.KHR_DRAW_INDIRECT_COUNT_EXTENSION_NAME,
        }
        
        // @correctness These features are still extensions, and we should query their availability.
        f_mesh := vk.PhysicalDeviceMeshShaderFeaturesEXT {
            sType = .PHYSICAL_DEVICE_MESH_SHADER_FEATURES_EXT,
            
            meshShader = true, // 57.18% (vulkan.gpuinfo.org for "1.4 and up" on 18.06.2026)
            taskShader = true,
            meshShaderQueries = true,
        }
        
        f11 := vk.PhysicalDeviceVulkan11Features {
            sType = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
            pNext = &f_mesh,
            
            storageBuffer16BitAccess           = true,
            uniformAndStorageBuffer16BitAccess = true,
            shaderDrawParameters               = true,
        }
        
        f12 := vk.PhysicalDeviceVulkan12Features {
            sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
            pNext = &f11,
            
            descriptorIndexing                        = true,
            shaderSampledImageArrayNonUniformIndexing = true,
            descriptorBindingVariableDescriptorCount  = true,
            runtimeDescriptorArray                    = true,
            timelineSemaphore                         = true,
            
            bufferDeviceAddress = true,
            
            shaderFloat16 = true,
            shaderInt8    = true,
            uniformAndStorageBuffer8BitAccess = true,
            storageBuffer8BitAccess           = true,
            
            drawIndirectCount = true, // let the culling shader specify the amount of draw commands, so that we don't dispatch empty commands
            
            scalarBlockLayout   = true, // required since 1.4
            samplerFilterMinmax = true,
            
            hostQueryReset = true,
        }
        
        f13 := vk.PhysicalDeviceVulkan13Features {
            sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
            pNext = &f12,
            
            synchronization2 = true,
            dynamicRendering = true, // remove the need for RenderPass and FrameBuffer objects
            maintenance4     = true, // needed to use layout(local_size...)
        }
        
        // These features are guaranteed to be supported, if the device suppports vulkan 1.4
        f14 := vk.PhysicalDeviceVulkan14Features {
            sType = .PHYSICAL_DEVICE_VULKAN_1_4_FEATURES,
            pNext = &f13,
            
            maintenance5   = true, // deprecates ShaderModule
            pushDescriptor = true, // remove the need for CmdBindVertexBuffers
            dynamicRenderingLocalRead = true, // allows rendering to an image and then copying into the swapchain image, whilst using dynamic_rendering
        }
        
        f2 := vk.PhysicalDeviceFeatures2 {
            sType = .PHYSICAL_DEVICE_FEATURES_2,
            pNext = &f14,
            
            // @correctness These are technically optional device features, and should be queried for availablity before using them.
            features = { 
                multiDrawIndirect = true, // supported on NVidia since the GTX 1080
                samplerAnisotropy = true, // required since 1.4
                shaderInt16       = true, // required since 1.4
                shaderInt64       = true,
                
                pipelineStatisticsQuery = true,
            },
        }
        
        device_create_info := vk.DeviceCreateInfo {
            sType = .DEVICE_CREATE_INFO,
            
            pNext = &f2,
            
            queueCreateInfoCount = 1,
            pQueueCreateInfos    = &vk.DeviceQueueCreateInfo {
                sType = .DEVICE_QUEUE_CREATE_INFO,
                queueFamilyIndex = queue_family_index,
                queueCount       = 1,
                pQueuePriorities = raw_data([]f32{ 1 }),
            },
            
            enabledExtensionCount   = auto_cast len(device_extensions),
            ppEnabledExtensionNames = raw_data(device_extensions),
        }
        
        check(vk.CreateDevice(result.physical_device, &device_create_info, nil, &result.device))
        
        vk.load_proc_addresses_device(result.device)
        
        ////////////////////////////////////////////////
        
        vk.GetDeviceQueue(result.device, queue_family_index, 0, &result.queue)
        
        ////////////////////////////////////////////////
        
        vk.GetPhysicalDeviceMemoryProperties(result.physical_device, &result.memory_properties)
        
        ////////////////////////////////////////////////
        
        for &sema in result.image_aquired_semaphores {
            sema = create_semaphore(result.device)
            defer_destroy(vk.DestroySemaphore, sema)
        }
        
        ////////////////////////////////////////////////
        
        {
            command_pool_create_info := vk.CommandPoolCreateInfo {
                sType = .COMMAND_POOL_CREATE_INFO,
                flags            = { .RESET_COMMAND_BUFFER },
                queueFamilyIndex = queue_family_index,
            }
            
            check(vk.CreateCommandPool(result.device, &command_pool_create_info, nil, &result.command_pool))
            
            command_buffer_allocate_info := vk.CommandBufferAllocateInfo {
                sType = .COMMAND_BUFFER_ALLOCATE_INFO,
                commandPool        = result.command_pool,
                commandBufferCount = len(result.command_buffers),
            }
            
            check(vk.AllocateCommandBuffers(result.device, &command_buffer_allocate_info, &result.command_buffers[0]))
            
            defer_destroy(vk.DestroyCommandPool, result.command_pool)
        }
    }
    
    ////////////////////////////////////////////////
        
    get_swapchain_format :: proc (gpu: ^Gpu) -> vk.Format {
        format_count: u32
        check(vk.GetPhysicalDeviceSurfaceFormatsKHR(gpu.physical_device, gpu.surface, &format_count, nil))
        formats := make([] vk.SurfaceFormatKHR, format_count, context.temp_allocator)
        check(vk.GetPhysicalDeviceSurfaceFormatsKHR(gpu.physical_device, gpu.surface, &format_count, raw_data(formats)))
        
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

    get_depth_buffer_format :: proc (gpu: ^Gpu) -> vk.Format {
        result: vk.Format
        
        // :Stencil: Switch to .D32_SFLOAT_S8_UINT if we actually make use of the stencil buffer.
        depth_format_list := [] vk.Format { .D32_SFLOAT }
        for it in depth_format_list {
            format_properties := vk.FormatProperties2 { sType = .FORMAT_PROPERTIES_2 }
            vk.GetPhysicalDeviceFormatProperties2(gpu.physical_device, it, &format_properties)
            
            if .DEPTH_STENCIL_ATTACHMENT in format_properties.formatProperties.optimalTilingFeatures {
                result = it
                break
            }
        }
        assert(result != .UNDEFINED)
        
        return result
    }

    result.swapchain_format    = get_swapchain_format(&result)
    result.depth_buffer.format = get_depth_buffer_format(&result)
    
    recreate_swapchain(&result, sdl_get_window_size(window))
    
    return result
}

gpu_deinit :: proc (gpu: ^Gpu) {
    defer gpu^ = {}
    
    destroy_all_handles(gpu.device)
    destroy_swapchain(gpu)
    
    vk.DestroyDevice(gpu.device, nil)
    
    vk.DestroySurfaceKHR(gpu.instance, gpu.surface, nil)
    vk.DestroyInstance(gpu.instance, nil)
}

////////////////////////////////////////////////

wait_for_the_gpu_to_be_ready_for_the_next_frame :: proc (gpu: ^Gpu) -> (frame_index: u32, should_restart_frame: bool) {
    gpu.signal_value += 1
    wait_value := gpu.signal_value - MaxFramesInFlight
    
    wait_info := vk.SemaphoreWaitInfo {
        sType = .SEMAPHORE_WAIT_INFO,
        semaphoreCount = 1,
        pSemaphores    = &gpu.timeline_semaphore,
        pValues        = &wait_value,
    }
    
    wait_result := vk.WaitSemaphores(gpu.device, &wait_info, MaxTimeout)
    if wait_result == .TIMEOUT {
        gpu.should_recreate_swapchain = true
        return 0, true
    }
    
    check(wait_result)
    
    ////////////////////////////////////////////////
    
    frame_index = gpu.absolute_frame_index % MaxFramesInFlight
    gpu.absolute_frame_index += 1
    
    acquire_result := vk.AcquireNextImageKHR(gpu.device, gpu.swapchain, MaxTimeout, gpu.image_aquired_semaphores[frame_index], {}, &gpu.image_index)
    if acquire_result == .ERROR_OUT_OF_DATE_KHR || acquire_result == .SUBOPTIMAL_KHR {
        gpu.should_recreate_swapchain = true
        return 0, true
    }
    check(acquire_result)
    
    return frame_index, false
}

////////////////////////////////////////////////
// Allocation of GPU resources

gpu_make_buffer :: proc { gpu_make_buffer_slice, gpu_make_buffer_size }
gpu_make_buffer_slice :: proc (gpu: ^Gpu, $S: typeid / [] $E, #any_int len: umm, usage: vk.BufferUsageFlags) -> (Buffer, S) {
    size   := size_of(E) * len
    buffer, pointer := gpu_make_buffer_size(gpu, size, usage)
    view   := slice_from_parts(E, pointer, len)
    return buffer, view
}
gpu_make_buffer_type :: proc (gpu: ^Gpu, $S: typeid, usage: vk.BufferUsageFlags) -> (Buffer, ^S) {
    size   := size_of(S)
    buffer, pointer := gpu_make_buffer_size(gpu, size, usage)
    data := cast(^S) pointer
    return buffer, data
}
gpu_make_buffer_size :: proc (gpu: ^Gpu, #any_int size: vk.DeviceSize, usage: vk.BufferUsageFlags) -> (Buffer, pmm) {
    assert(gpu.device != nil)
    
    create_info := vk.BufferCreateInfo {
        sType = .BUFFER_CREATE_INFO,
        size  = size,
        usage = usage,
    }
    
    result: Buffer
    check(vk.CreateBuffer(gpu.device, &create_info, nil, &result.buffer))
    
    requirements: vk.MemoryRequirements
    vk.GetBufferMemoryRequirements(gpu.device, result.buffer, &requirements)
    
    flags := vk.MemoryPropertyFlags { .HOST_VISIBLE, .HOST_COHERENT }
    
    uses_address := .SHADER_DEVICE_ADDRESS in usage
    
    result.memory = select_memory_type_and_allocate(gpu, requirements, flags, add_device_address_flag = uses_address)
    
    check(vk.BindBufferMemory(gpu.device, result.buffer, result.memory, 0))
    
    pointer: pmm
    vk.MapMemory(gpu.device, result.memory, 0, size, {}, &pointer)
    
    if uses_address {
        adress_create_info := vk.BufferDeviceAddressInfo {
            sType = .BUFFER_DEVICE_ADDRESS_INFO,
            buffer = result.buffer,
        }
        
        result.address = vk.GetBufferDeviceAddress(gpu.device, &adress_create_info)
        
        assert(result.address != 0)
    }
    
    return result, pointer
}

gpu_make_image :: proc (gpu: ^Gpu, size: uv2, format: vk.Format, usage: vk.ImageUsageFlags, aspect_mask: vk.ImageAspectFlags, flags := vk.MemoryPropertyFlags { .DEVICE_LOCAL }, mip_levels : u32 = 1) -> Image {
    assert(gpu.device != nil)
    
    create_info := vk.ImageCreateInfo {
        sType = .IMAGE_CREATE_INFO,
        imageType     = .D2,
        format        = format,
        extent        = to_extent(size, 1),
        mipLevels     = mip_levels,
        arrayLayers   = 1,
        samples       = { ._1 },
        tiling        = .OPTIMAL,
        usage         = usage,
        initialLayout = .UNDEFINED,
    }
    
    result: Image
    result.format = format
    check(vk.CreateImage(gpu.device, &create_info, nil, &result.image))
    
    requirements: vk.MemoryRequirements
    vk.GetImageMemoryRequirements(gpu.device, result.image, &requirements)
    
    result.memory = select_memory_type_and_allocate(gpu, requirements, flags)
    
    check(vk.BindImageMemory(gpu.device, result.image, result.memory, 0))
    
    result.view = create_image_view(gpu.device, result, 0, mip_levels, aspect_mask)
    
    return result
}

select_memory_type_and_allocate :: proc (gpu: ^Gpu, requirements: vk.MemoryRequirements, flags: vk.MemoryPropertyFlags, add_device_address_flag := false) -> vk.DeviceMemory {
    
    properties := gpu.memory_properties
    
    selected_memory_type_index: u32
    select: {
        set := transmute(bit_set[0..=31; u32]) requirements.memoryTypeBits
        
        for type, i in properties.memoryTypes[:properties.memoryTypeCount] {
            if i in set && flags <= type.propertyFlags {
                selected_memory_type_index = cast(u32) i
                break select
            }
        }
        
        assert(false, "No compatible memory type found")
    }
    
    allocate_info := vk.MemoryAllocateInfo {
        sType = .MEMORY_ALLOCATE_INFO,
        allocationSize  = requirements.size,
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
    check(vk.AllocateMemory(gpu.device, &allocate_info, nil, &memory))
    
    return memory
}

gpu_delete :: proc { gpu_delete_buffer, gpu_delete_image }
gpu_delete_buffer :: proc (gpu: ^Gpu, buffer: Buffer) {
    assert(gpu.device != nil)
    
    vk.DestroyBuffer(gpu.device, buffer.buffer, nil)
    vk.FreeMemory(gpu.device,    buffer.memory, nil)
}

gpu_delete_image :: proc (gpu: ^Gpu, image: Image) {
    assert(gpu.device != nil)
    
    vk.DestroyImageView(gpu.device, image.view, nil)
    vk.DestroyImage(gpu.device,     image.image, nil)
    vk.FreeMemory(gpu.device,       image.memory, nil)
}

////////////////////////////////////////////////
// @cleanup @placement

create_image_view :: proc (device: vk.Device, image: Image, mip_base: u32, mip_count: u32, aspect_mask: vk.ImageAspectFlags) -> vk.ImageView {
    view_create_info := vk.ImageViewCreateInfo {
        sType = .IMAGE_VIEW_CREATE_INFO,
        image    = image.image,
        viewType = .D2,
        format   = image.format,
        subresourceRange = { aspectMask = aspect_mask, baseMipLevel = mip_base, levelCount = mip_count, layerCount = 1 },
    }
    
    result: vk.ImageView
    check(vk.CreateImageView(device, &view_create_info, nil, &result))
    
    return result
}

create_sampler :: proc (device: vk.Device, filter: vk.Filter, mipmap_mode: vk.SamplerMipmapMode, max_lod: f32 = 16, anisotropy: b32 = false) -> vk.Sampler {
    sampler_create_info := vk.SamplerCreateInfo {
        sType = .SAMPLER_CREATE_INFO,
        
        magFilter  = filter,
        minFilter  = filter,
        mipmapMode = mipmap_mode,
        
        addressModeU = .CLAMP_TO_EDGE,
        addressModeV = .CLAMP_TO_EDGE,
        addressModeW = .CLAMP_TO_EDGE,
        
        anisotropyEnable = anisotropy,
        maxAnisotropy    = anisotropy ? 8 : 0,
        maxLod           = max_lod,
    }
    
    result: vk.Sampler
    check(vk.CreateSampler(device, &sampler_create_info, nil, &result))
    
    return result
}