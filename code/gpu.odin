#+vet explicit-allocators !unused-procedures
package main

import "base:intrinsics"
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
    
    instance:          vk.Instance,
    physical_device:   vk.PhysicalDevice,
    surface:           vk.SurfaceKHR,
    device_properties: vk.PhysicalDeviceProperties2, 
    memory_properties: vk.PhysicalDeviceMemoryProperties,
    
    device: vk.Device,
    queue:  vk.Queue, // this is the graphics and compute queue, we could also create a queue just for transfers/copying
    
    // @incomplete this is never initialized. It may help performance if we need to create/recreate many pipelines.
    pipeline_cache: vk.PipelineCache,
    
    ////////////////////////////////////////////////
    
    command_pools:            [MaxFramesInFlight] vk.CommandPool,
    image_aquired_semaphores: [MaxFramesInFlight] vk.Semaphore,
    
    ////////////////////////////////////////////////
    // these all have the same lifetime as the swapchain
    
    swapchain: vk.SwapchainKHR,
    swapchain_images: [dynamic] Image, // this is only an image to make use of the last: Transition
    render_completes: [dynamic] vk.Semaphore,
    
    swapchain_size:   uv2,
    swapchain_format: vk.Format,
    
    // @todo(viktor): these should also be part of the app, as we are already passing special usage flags based on what the app wants to do
    color_buffer: Image,
    depth_buffer: Image,
}

////////////////////////////////////////////////

gpu_init :: proc (window: ^sdl.Window) -> Gpu {
    result: Gpu
    
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
            physical_devices: [dynamic; 128] vk.PhysicalDevice
            {
                device_count: u32
                check(vk.EnumeratePhysicalDevices(result.instance, &device_count, nil))
                assert(device_count <= cap(physical_devices))
                resize(&physical_devices, device_count)
                check(vk.EnumeratePhysicalDevices(result.instance, &device_count, raw_data(&physical_devices)))
            }
            
            discrete: vk.PhysicalDevice
            fallback: vk.PhysicalDevice
            
            for device in physical_devices {
                family_index_with_graphics := vk.QUEUE_FAMILY_IGNORED
                {
                    queue_family_count: u32
                    vk.GetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, nil)
                    queue_family_properties: [dynamic; 128] vk.QueueFamilyProperties
                    assert(queue_family_count <= cap(queue_family_properties))
                    resize(&queue_family_properties, queue_family_count)
                    vk.GetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, raw_data(&queue_family_properties))
                    
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
    
    {
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
            sema = gpu_create_semaphore(&result)
            defer_destroy(vk.DestroySemaphore, sema)
        }
            
        ////////////////////////////////////////////////
        
        {
            for &pool in result.command_pools {
                command_pool_create_info := vk.CommandPoolCreateInfo {
                    sType = .COMMAND_POOL_CREATE_INFO,
                    flags            = { .RESET_COMMAND_BUFFER },
                    queueFamilyIndex = queue_family_index,
                }
                
                check(vk.CreateCommandPool(result.device, &command_pool_create_info, nil, &pool))
                defer_destroy(vk.DestroyCommandPool, pool)
            }
        }
    }
    
    ////////////////////////////////////////////////
        
    get_swapchain_format :: proc (gpu: ^Gpu) -> vk.Format {
        format_count: u32
        check(vk.GetPhysicalDeviceSurfaceFormatsKHR(gpu.physical_device, gpu.surface, &format_count, nil))
        formats: [dynamic; 128] vk.SurfaceFormatKHR
        assert(format_count <= cap(formats))
        resize(&formats, format_count)
        check(vk.GetPhysicalDeviceSurfaceFormatsKHR(gpu.physical_device, gpu.surface, &format_count, raw_data(&formats)))
        
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

get_the_next_frame :: proc (gpu: ^Gpu, semaphore: vk.Semaphore) -> (frame_index: u32, should_restart_frame: bool) {
    frame_index = gpu.absolute_frame_index % MaxFramesInFlight
    gpu.absolute_frame_index += 1
    
    info := vk.AcquireNextImageInfoKHR {
        sType = .ACQUIRE_NEXT_IMAGE_INFO_KHR,
        
        swapchain  = gpu.swapchain,
        timeout    = MaxTimeout,
        semaphore  = gpu.image_aquired_semaphores[frame_index],
        deviceMask = 1 << 0,
    }
    
    result := vk.AcquireNextImage2KHR(gpu.device, &info, &gpu.image_index)
    if result == .ERROR_OUT_OF_DATE_KHR || result == .SUBOPTIMAL_KHR {
        gpu.should_recreate_swapchain = true
        return 0, true
    }
    check(result)
    
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




////////////////////////////////////////////////


//             No graphics api


////////////////////////////////////////////////



Memory_Types :: enum {
    cpu_mapped_gpu_memory, // for fast gpu read, and direct cpu copying into
    gpu_only_memory,       // for texture data, or big gpu-only buffers
    cpu_cached,            // for readback
}


// @api with scalar_block_layout, do we ever need an alignment parameter?
// it seems that base structs should still be aligned by 16 bytes to make the best use of the loading hardware
// this does not change with scalar block layout, as that just reduces padding issues between cpu and gpu.
gpu_allocate :: proc { gpu_allocate_size, gpu_allocate_slice, gpu_allocate_struct }
gpu_allocate_size :: proc (gpu: ^Gpu, size: umm, alignment: umm = 16) -> pmm {
    // @cleanup and use alignment
    _, result := gpu_make_buffer_size(gpu, size, { .STORAGE_BUFFER, .SHADER_DEVICE_ADDRESS })
    return result
}
gpu_allocate_slice :: proc (gpu: ^Gpu, $T: typeid/ [] $E, #any_int count: int) -> [] E {
    data := gpu_allocate_size(gpu, size_of(T) * count, align_of(E))
    result := slice_from_parts(E, data, count)
    return result
}
gpu_allocate_struct :: proc (gpu: ^Gpu, $T: typeid) -> ^T {
    data := gpu_allocate_size(gpu, size_of(T), align_of(T))
    result := cast(^T) data
    return result
}

gpu_free :: proc (gpu: ^Gpu, pointer: pmm) {
    unimplemented()
}

////////////////////////////////////////////////
 
// @todo upload_bump_allocator bump_allocate(size) -> xx

xx :: struct {
    cpu: pmm,
    gpu: pmm,
}

/* 

// Load a mesh using a 3rd party library
auto mesh = createMesh("mesh.obj");
auto upload = uploadBumpAllocator.allocate(mesh.byteSize); // Custom bump allocator (wraps a gpuMalloc ptr)
mesh.load(upload.cpu);

// Allocate GPU-only memory and copy into it
void* meshGpu = gpuMalloc(mesh.byteSize, MEMORY_GPU);
gpuMemCpy(commandBuffer, meshGpu, upload.gpu);

*/

// @api provide a version that allows multiple dest, source pairs with a single wait, or make it begin-end for now?
gpu_mem_copy :: proc (gpu: ^Gpu, cmd: vk.CommandBuffer, destination: xx, source: pmm) {
    semaphore := gpu_create_timeline_semaphore(gpu, 0)
    defer gpu_destroy_semaphore(gpu, semaphore)
    
    // pipeline_barrier_begin()
    //     add_image_barrier(&texture, {}, {}, .UNDEFINED, { .TRANSFER }, { .TRANSFER_WRITE }, .TRANSFER_DST_OPTIMAL)
    // pipeline_barrier_end(cmd)
    
    // copy_regions := make([dynamic] vk.BufferImageCopy, context.temp_allocator)
    // for level in 0..<loaded_texture.mip_levels {
    //     mip_offset := loaded_texture.mip_offsets[level]
        
    //     append(&copy_regions, vk.BufferImageCopy {
    //         bufferOffset     = auto_cast mip_offset,
    //         imageSubresource = { aspectMask = { .COLOR }, mipLevel = level, layerCount = 1 },
    //         imageExtent      = { width = loaded_texture.width >> level, height = loaded_texture.height >> level, depth = 1 },
    //     })
    // }
    
    // vk.CmdCopyBufferToImage(cmd, source_buffer.buffer, texture.image, .TRANSFER_DST_OPTIMAL, auto_cast len(copy_regions), raw_data(copy_regions))
    
    // pipeline_barrier_begin()
    //     add_image_barrier_transition_from_last(&texture, { .FRAGMENT_SHADER }, { .SHADER_READ }, .READ_ONLY_OPTIMAL)
    // pipeline_barrier_end(cmd)
    
    check(vk.EndCommandBuffer(cmd))
    
    gpu_submit(gpu, gpu.queue, semaphore, 1, cmd)
    gpu_wait_semaphore(gpu, semaphore, 1)
}

////////////////////////////////////////////////
// Root arguments

/* 

    // Common header...
    struct alignas(16) Data
    {
        // Uniform data
        float16x4 color; // 16-bit float vector
        uint16x2 offset; // 16-bit integer vector
        const uint8* lut; // pointer to 8-bit data array

        // Pointers to in/out data arrays
        const uint32* input;
        uint32* output;
    };

    // CPU code...
    gpuSetPipeline(commandBuffer, computePipeline);

    auto data = myBumpAllocator.allocate<Data>(); // Custom bump allocator (wraps gpuMalloc ptr, see appendix)
    data.cpu->color = {1.0f, 0.0f, 0.0f, 1.0f};
    data.cpu->offset = {16, 0};
    data.cpu->lut = luts.gpu + 64; // GPU pointers support pointer math (no need for offset API)
    data.cpu->input = input.gpu;
    data.cpu->output = output.gpu;

    gpuDispatch(commandBuffer, data.gpu, uvec3(128, 1, 1));

    // GPU kernel...
    [groupsize = (64, 1, 1)]
    void main(uint32x3 threadId : SV_ThreadID, const Data* data)
    {
        uint32 value = data->input[threadId.x]; 
        // TODO: Code using color, offset, lut, etc...
        data->output[threadId.x] = value;
    }

*/

// Inputs should be marked as constant array and 
// the most important fields should be at the start of the struct, as they are preloaded
// to enable uniformity the data should be always marked as readonly
// by convention buffers should not alias into each other

the_bound_pipeline: Pipeline

gpu_set_pipeline :: proc (command_buffer: vk.CommandBuffer, pipeline: Pipeline) {
    vk.CmdBindPipeline(command_buffer, pipeline.bind_point, pipeline.pipeline)
    the_bound_pipeline = pipeline
}

// @api make gpu_data type safer
gpu_dispatch :: proc (command_buffer: vk.CommandBuffer, gpu_data: pmm, group_size: uv3) {
    assert(the_bound_pipeline.pipeline != 0, "no pipeline was bound")
    
    vk.CmdPushConstants(command_buffer, the_bound_pipeline.layout, the_bound_pipeline.shader_stages, 0, size_of(vk.DeviceAddress), gpu_data)
    
    vk.CmdDispatch(command_buffer, **group_size)
}

////////////////////////////////////////////////
// Texture bindings
// @todo

/* 

    // App startup: Allocate a texture descriptor heap (for example 65536 descriptors)
    GpuTextureDescriptor *textureHeap = gpuMalloc<GpuTextureDescriptor>(65536);

    // Load an image using a 3rd party library
    auto pngImage = pngLoad("cat.png");
    auto uploadMemory = uploadBumpAllocator.allocate(pngImage.byteSize); // Custom bump allocator (wraps gpuMalloc ptr)
    pngImage.load(uploadMemory.cpu);

    // Allocate GPU memory for our texture (optimal layout with metadata)
    GpuTextureDesc textureDesc { .dimensions = pngImage.dimensions, .format = FORMAT_RGBA8_UNORM, .usage = SAMPLED };
    GpuTextureSizeAlign textureSizeAlign = gpuTextureSizeAlign(textureDesc);
    void *texturePtr = gpuMalloc(textureSizeAlign.size, textureSizeAlign.align, MEMORY_GPU);
    GpuTexture texture = gpuCreateTexture(textureDesc, texturePtr);

    // Create a 256-bit texture view descriptor and store it
    textureHeap[0] = gpuTextureViewDescriptor(texture, { .format = FORMAT_RGBA8_UNORM });

    // Batched upload: begin
    GpuCommandBuffer uploadCommandBuffer = gpuStartCommandRecording(queue);

    // Copy all textures here!
    gpuCopyToTexture(uploadCommandBuffer, texturePtr, uploadMemory.gpu, texture);
    // TODO other textures...

    // Batched upload: end
    gpuBarrier(uploadCommandBuffer, STAGE_TRANSFER, STAGE_ALL, HAZARD_DESCRIPTORS);
    gpuSubmit(queue, { uploadCommandBuffer });

    // Later during rendering...
    gpuSetActiveTextureHeapPtr(commandBuffer, gpuHostToDevicePointer(textureHeap));

*/

// Gpu_Texture_Descriptor
// Gpu_Texture_Desc
// Gpu_Texture_View_Descriptor

// gpu_texture_size_align
// gpu_create_texture
// gpu_create_texture_view

// gpu_set_active_texture_heap_ptr

/* 

    // Common header...
    struct alignas(16) Data
    {
        uint32 srcTextureBase;
        uint32 dstTexture;
        float32x2 invDimensions;
    };

    // GPU kernel...
    const Texture textureHeap[];

    [groupsize = (8, 8, 1)]
    void main(uint32x3 threadId : SV_ThreadID, const Data* data)
    {
        Texture textureColor = textureHeap[data->srcTextureBase + 0];
        Texture textureNormal = textureHeap[data->srcTextureBase + 1];
        Texture texturePBR = textureHeap[data->srcTextureBase + 2];

        Sampler sampler = {.minFilter = LINEAR, .magFilter = LINEAR}; // Embedded sampler (Metal-style)

        float32x2 uv = float32x2(threadId.xy) * data->invDimensions;

        float32x4 color = sample(textureColor, sampler, uv);
        float32x4 normal = sample(textureNormal, sampler, uv);
        float32x4 pbr = sample(texturePBR, sampler, uv);

        float32x4 lit = calculateLighting(color, normal, pbr);

        TextureRW dstTexture = TextureRW(textureHeap[data->dstTexture]);
        dstTexture[threadId.xy] = lit;
    }
        
    [groupsize = (8, 8, 1)]
    void main(uint32x3 threadId : SV_ThreadID, const Data* data)
    {
        // Non-uniform "buffer data" is not an issue with pointer semantics! 
        Material* material = data->materialMap[threadId.xy];

        // Non-uniform texture heap index
        uint32 textureBase = NonUniformResourceIndex(material.textureBase);

        Texture textureColor = textureHeap[textureBase + 0];
        Texture textureNormal = textureHeap[textureBase + 1];
        Texture texturePBR = textureHeap[textureBase + 2];

        Sampler sampler = {.minFilter = LINEAR, .magFilter = LINEAR};

        float32x2 uv = float32x2(threadId.xy) * data->invDimensions;

        float32x4 color = sample(textureColor, sampler, uv);
        float32x4 normal = sample(textureNormal, sampler, uv);
        float32x4 pbr = sample(texturePBR, sampler, uv);
        
        color *= material.color;
        pbr *= material.pbr;

        // Rest of the shader
    }

*/

////////////////////////////////////////////////
// Shader pipelines

gpu_create_compute_pipeline :: proc (gpu: ^Gpu, shader: Shader, old: Pipeline_pc($PC)) -> Pipeline_pc(PC) {
    if pipeline_is_valid(old) {
        check(vk.DeviceWaitIdle(gpu.device))
        destroy_pipeline(gpu.device, old)
    }
    
    assert(shader.stage == .COMPUTE)
    
    result: Pipeline_pc(PC)
    result.bind_point    = .COMPUTE
    result.shader_stages = { .COMPUTE }
    
    size := cast(u32) (size_of(vk.DeviceAddress) when intrinsics.type_is_pointer(PC) else size_of(PC))
    
    result.layout = create_pipeline_layout(gpu.device, result.shader_stages, size_of_push_constant = size)
    
    create_info := vk.ComputePipelineCreateInfo {
        sType = .COMPUTE_PIPELINE_CREATE_INFO,
        layout = result.layout,
        stage  = { 
            sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, 
            stage = { shader.stage }, 
            pName = "main", 
            pNext = &vk.ShaderModuleCreateInfo {
                sType    = .SHADER_MODULE_CREATE_INFO,
                codeSize = len(shader.bytes),
                pCode    = cast(^u32) &shader.bytes[0],
            },
        },
    }
    
    check(vk.CreateComputePipelines(gpu.device, gpu.pipeline_cache, 1, &create_info, nil, &result.i.pipeline))
    
    return result
}

////////////////////////////////////////////////
// Shader constants

/* 

// Common header...
struct alignas(16) Constants
{
    int32 qualityLevel;
    uint8* blueNoiseLUT;
};

// CPU code...
Constants constants { .qualityLevel = 2, blueNoiseLUT = blueNoiseLUT.gpu };

auto shaderIR = loadFile("computeShader.ir");
GpuPipeline computePipeline = gpuCreateComputePipeline(shaderIR, &constants);

// GPU kernel...
[groupsize = (8, 8, 1)]
void main(uint32x3 threadId : SV_ThreadID, const Data* data, const Constants constants)
{
    if (constants.qualityLevel == 3)
    {
        // Dead code eliminated
    }
}

*/

////////////////////////////////////////////////
// Barriers and fences

Hazard_Flag :: enum u32 {
    // If you write to the texture descriptor heap (uncommon), you need to add a special flag.
    Descriptors,
    // @todo(viktor): 
    
}
Hazard_Flags :: bit_set[Hazard_Flag; u32]

// @todo(viktor): check where niagara uses dependency flags and add it
gpu_barrier :: proc (command_buffer: vk.CommandBuffer, source_stage, destination_stage: vk.PipelineStageFlags2, hazard := Hazard_Flags {}) {
    // @study vk.DependencyFlags
    info := vk.DependencyInfo {
        sType = .DEPENDENCY_INFO,
        
        memoryBarrierCount = 1,
        pMemoryBarriers    = &vk.MemoryBarrier2 {
            sType = .MEMORY_BARRIER_2,
            srcStageMask = source_stage,
            dstStageMask = destination_stage,
            // srcAccessMask = vk.AccessFlags2., // @todo(viktor): set based on hazards
            // dstAccessMask: AccessFlags2,
        },
    }
    
    // @todo(viktor):  is this sufficient?
    if .COLOR_ATTACHMENT_OUTPUT in destination_stage {
        info.pMemoryBarriers[0].dstAccessMask += { .COLOR_ATTACHMENT_WRITE, .DEPTH_STENCIL_ATTACHMENT_WRITE }
    }
    
    vk.CmdPipelineBarrier2(command_buffer, &info)
}

/* 

gpuSignalAfter(commandBuffer, STAGE_RASTER_COLOR_OUT, gpuPtr, counter, SIGNAL_ATOMIC_MAX);
// Put independent work here
gpuWaitBefore(commandBuffer, STAGE_PIXEL_SHADER, gpuPtr, counter++, OP_GREATER_EQUAL);

*/

gpu_signal_after :: proc (command_buffer: vk.CommandBuffer, stage: vk.PipelineStageFlags2, gpu_pointer: pmm, count: u64, signal_op: any) {
    unimplemented()
}
gpu_wait_before :: proc (command_buffer: vk.CommandBuffer, stage: vk.PipelineStageFlags2, gpu_pointer: pmm, value: u64, wait_op: any) {
    unimplemented()
}

/* 

#define FRAMES_IN_FLIGHT 2

GpuSemaphore frameSemaphore = gpuCreateSemaphore(0);
uint64 nextFrame = 1;

while (running)
{
    if (nextFrame > FRAMES_IN_FLIGHT) 
    {
        gpuWaitSemaphore(frameSemaphore, nextFrame - FRAMES_IN_FLIGHT);
    }
    
    // Render the frame here

    gpuSubmit(queue, {commandBuffer}, frameSemaphore, nextFrame++);
}

gpuDestroySemaphore(frameSemaphore);

*/

MaxTimeout :: max(u64)

gpu_create_semaphore :: proc (gpu: ^Gpu) -> vk.Semaphore {
    info := vk.SemaphoreCreateInfo { sType = .SEMAPHORE_CREATE_INFO }
    
    result: vk.Semaphore
    check(vk.CreateSemaphore(gpu.device, &info, nil, &result))
    
    return result
}

gpu_create_timeline_semaphore :: proc (gpu: ^Gpu, initial_value: u64) -> vk.Semaphore {
    info := vk.SemaphoreCreateInfo { 
        sType = .SEMAPHORE_CREATE_INFO,
        pNext = &vk.SemaphoreTypeCreateInfo {
            sType = .SEMAPHORE_TYPE_CREATE_INFO,
            semaphoreType = .TIMELINE,
            initialValue  = initial_value,
        },
    }
    
    result: vk.Semaphore
    check(vk.CreateSemaphore(gpu.device, &info, nil, &result))
    
    return result
}

gpu_destroy_semaphore :: proc (gpu: ^Gpu, semaphore: vk.Semaphore) {
    vk.DestroySemaphore(gpu.device, semaphore, nil)
}

gpu_wait_semaphore :: proc (gpu: ^Gpu, semaphore: vk.Semaphore, wait_value: u64) {
    semaphores := [?] vk.Semaphore { semaphore }
    values     := [?] u64 { wait_value }
    
    info := vk.SemaphoreWaitInfo {
        sType = .SEMAPHORE_WAIT_INFO,
        semaphoreCount = len(semaphores),
        pSemaphores    = &semaphores[0],
        pValues        = &values[0],
    }
    
    wait_result := vk.WaitSemaphores(gpu.device, &info, MaxTimeout)
    if wait_result == .TIMEOUT {
        gpu.should_recreate_swapchain = true
        unimplemented("recreate immediatly and wait again or just return?")
    }
    check(wait_result)
}

gpu_submit :: proc (gpu: ^Gpu, queue: vk.Queue, semaphore: vk.Semaphore, signal_value: u64, command_buffers: ..vk.CommandBuffer) {
    cmd_infos: [dynamic; 16] vk.CommandBufferSubmitInfo
    for cmd in command_buffers {
        append(&cmd_infos, vk.CommandBufferSubmitInfo {
            sType = .COMMAND_BUFFER_SUBMIT_INFO,
            commandBuffer = cmd,
        })
    }
    
    // @todo(viktor): what if we want to signal multiple semaphores. This is only used by the image_aquired semaphores.
    once_submit_info := vk.SubmitInfo2 {
        sType = .SUBMIT_INFO_2,
        signalSemaphoreInfoCount = 1,
        pSignalSemaphoreInfos    = &vk.SemaphoreSubmitInfo {
            sType = .SEMAPHORE_SUBMIT_INFO,
            semaphore = semaphore,
            value     = signal_value,
            stageMask = { .ALL_COMMANDS },
        },
        commandBufferInfoCount = cast(u32) len(command_buffers),
        pCommandBufferInfos    = &cmd_infos[0],
    }
    
    check(vk.QueueSubmit2(gpu.queue, 1, &once_submit_info, 0))
}

////////////////////////////////////////////////
// Command Buffers

// @todo(viktor): queue is ignored, we need to allocate from a pool created with the correct queue_family_index
gpu_begin_command_recording :: proc (gpu: ^Gpu, frame_index: u32, _: vk.Queue) -> vk.CommandBuffer {
    info := vk.CommandBufferAllocateInfo {
        sType = .COMMAND_BUFFER_ALLOCATE_INFO,
        commandPool        = gpu.command_pools[frame_index],
        commandBufferCount = 1,
    }
    
    result: vk.CommandBuffer
    check(vk.AllocateCommandBuffers(gpu.device, &info, &result))
    
    begin_info := vk.CommandBufferBeginInfo { 
        sType = .COMMAND_BUFFER_BEGIN_INFO, 
        flags = { .ONE_TIME_SUBMIT } 
    }
    check(vk.BeginCommandBuffer(result, &begin_info))
    
    return result
}