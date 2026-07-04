#+vet explicit-allocators !unused-procedures
package main

    //////////////////////////////////////////////////////////////////////
   //                                                                  //
   //                                                                  //
   //                       No graphics api                            //
   //                                                                  //
   //              (or as little as possible with Vulkan)              // 
   //                                                                  // 
   //                                                                  //
   // based on: https://www.sebastianaaltonen.com/blog/no-graphics-api //
  //////////////////////////////////////////////////////////////////////

import "base:runtime"

import "core:fmt"

import vk  "../lib/vulkan"
import sdl "vendor:sdl3"

// @todo import the cpu profiler and extract the common parts with the gpu profiler,
// @todo make a list of the api like c forward declarations

MaxFramesInFlight :: 2

Gpu :: struct {
    instance:          vk.Instance,
    physical_device:   vk.PhysicalDevice,
    surface:           vk.SurfaceKHR,
    device_properties: vk.PhysicalDeviceProperties2, 
    heap_properties:   vk.PhysicalDeviceDescriptorHeapPropertiesEXT, 
    memory_properties: vk.PhysicalDeviceMemoryProperties,
    
    device: vk.Device,
    
    // @incomplete this is never initialized. It may help performance if we need to create/recreate many pipelines.
    pipeline_cache: vk.PipelineCache,
    
    // @study as all command buffers are one time submits, do we even need to ensure they are not reused between frames/free at end of the frame
    // Can this just be a single command pool for per frame command buffers, and if there is a second queue then we need another command pool,
    // Or do we actually never need to reset it anyways?
    
    ////////////////////////////////////////////////
    
    general_queue: vk.Queue,
    command_pools:            [MaxFramesInFlight] vk.CommandPool,
    image_aquired_semaphores: [MaxFramesInFlight] vk.Semaphore,
    
    transfer_queue: vk.Queue,
    transfer_command_pool: vk.CommandPool,
    
    swapchain_state:  Swapchain_State,
    swapchain_format: vk.Format,
    image_index: u32, 
    
    ////////////////////////////////////////////////
    // these all have the same lifetime as the swapchain
    
    swapchain_size: uv2,
    
    swapchain: vk.SwapchainKHR,
    swapchain_images: [dynamic] Image, // this is only an image to make use of the last stage access and layout
    render_completes: [dynamic] vk.Semaphore,
}

Swapchain_State :: enum { 
    Dirty,
    Was_Resized,
    Ok,
    Window_Is_Minimized,
}

////////////////////////////////////////////////

gpu_init :: proc (window: ^sdl.Window) -> Gpu {
    result: Gpu
    
    {
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
                    pApplicationName = "Vulkan Renderer",
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
                    .SYNCHRONIZATION_VALIDATION,
                    // DEBUG_PRINTF // @todo enable this, if needed
                }
                
                instance_create_info.pNext = &vk.DebugUtilsMessengerCreateInfoEXT {
                    sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
                    messageSeverity = { .VERBOSE, .WARNING, .ERROR },
                    messageType     = { .VALIDATION },
                    pfnUserCallback = vulkan_debug_utils_callback,
                    
                    pNext = &vk.ValidationFeaturesEXT {
                        sType = .VALIDATION_FEATURES_EXT,
                        enabledValidationFeatureCount = len(enabled),
                        pEnabledValidationFeatures    = &enabled[0],
                    },
                }
            }
            
            check(vk.CreateInstance(&instance_create_info, nil, &result.instance))
            
            vk.load_proc_addresses_instance(result.instance)
            
            assert(vk.GetPhysicalDeviceProperties2 != nil)
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
                
                if !sdl.Vulkan_GetPresentationSupport(auto_cast result.instance, auto_cast device, family_index_with_graphics) {
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
        
        result.heap_properties = vk.PhysicalDeviceDescriptorHeapPropertiesEXT {
            sType = .PHYSICAL_DEVICE_DESCRIPTOR_HEAP_PROPERTIES_EXT,
        }
        result.device_properties = vk.PhysicalDeviceProperties2 { 
            sType = .PHYSICAL_DEVICE_PROPERTIES_2,
            pNext = &result.heap_properties,
        }
        vk.GetPhysicalDeviceProperties2(result.physical_device, &result.device_properties)
        
        fmt.printfln("Selected device: %v", cast(cstring) &result.device_properties.properties.deviceName[0])
        assert(result.device_properties.properties.limits.timestampComputeAndGraphics)
        
        ////////////////////////////////////////////////
        
        check_sdl(sdl.Vulkan_CreateSurface(window, auto_cast result.instance, nil, auto_cast &result.surface))
    }
    
    ////////////////////////////////////////////////
    
    {
        device_extensions := [] cstring { 
            vk.KHR_SWAPCHAIN_EXTENSION_NAME,
            vk.EXT_MESH_SHADER_EXTENSION_NAME,
            vk.KHR_DRAW_INDIRECT_COUNT_EXTENSION_NAME,
            vk.EXT_DESCRIPTOR_HEAP_EXTENSION_NAME,
            vk.KHR_UNIFIED_IMAGE_LAYOUTS_EXTENSION_NAME,
        }
        
        f_heap := vk.PhysicalDeviceDescriptorHeapFeaturesEXT {
            sType = .PHYSICAL_DEVICE_DESCRIPTOR_HEAP_FEATURES_EXT,
            descriptorHeap = true,
        }
        
        // @correctness These features are still extensions, and we should query their availability.
        f_mesh := vk.PhysicalDeviceMeshShaderFeaturesEXT {
            sType = .PHYSICAL_DEVICE_MESH_SHADER_FEATURES_EXT,
            pNext = &f_heap,
            
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
            descriptorBindingSampledImageUpdateAfterBind = true,
            descriptorBindingPartiallyBound= true,
            
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
        
        queue_family_index: u32
        
        device_create_info := vk.DeviceCreateInfo {
            sType = .DEVICE_CREATE_INFO,
            
            pNext = &f2,
            
            queueCreateInfoCount = 1,
            pQueueCreateInfos    = &vk.DeviceQueueCreateInfo {
                sType = .DEVICE_QUEUE_CREATE_INFO,
                queueFamilyIndex = queue_family_index,
                queueCount       = 2,
                pQueuePriorities = raw_data([]f32{ 1, 0 }),
            },
            
            enabledExtensionCount   = auto_cast len(device_extensions),
            ppEnabledExtensionNames = raw_data(device_extensions),
        }
        
        check(vk.CreateDevice(result.physical_device, &device_create_info, nil, &result.device))
        
        vk.load_proc_addresses_device(result.device)
        
        ////////////////////////////////////////////////
        
        vk.GetDeviceQueue(result.device, queue_family_index, 0, &result.general_queue)
        vk.GetDeviceQueue(result.device, queue_family_index, 1, &result.transfer_queue)
        
        vk.GetPhysicalDeviceMemoryProperties(result.physical_device, &result.memory_properties)
        
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
            
            command_pool_create_info := vk.CommandPoolCreateInfo {
                sType = .COMMAND_POOL_CREATE_INFO,
                flags            = { .RESET_COMMAND_BUFFER },
                queueFamilyIndex = queue_family_index,
            }
            
            check(vk.CreateCommandPool(result.device, &command_pool_create_info, nil, &result.transfer_command_pool))
            defer_destroy(vk.DestroyCommandPool, result.transfer_command_pool)
        }
        ////////////////////////////////////////////////
        
        for &sema in result.image_aquired_semaphores {
            sema = gpu_create_semaphore(&result)
            defer_destroy(vk.DestroySemaphore, sema)
        }
    }
    
    ////////////////////////////////////////////////
    
    get_swapchain_format: {
        format_count: u32
        check(vk.GetPhysicalDeviceSurfaceFormatsKHR(result.physical_device, result.surface, &format_count, nil))
        
        formats: [dynamic; 128] vk.SurfaceFormatKHR
        assert(format_count <= cap(formats))
        resize(&formats, format_count)
        check(vk.GetPhysicalDeviceSurfaceFormatsKHR(result.physical_device, result.surface, &format_count, raw_data(&formats)))
        
        if len(formats) == 1 && formats[0].format == .UNDEFINED {
            result.swapchain_format = .R8G8B8A8_SRGB
            break get_swapchain_format
        }
        
        for format in formats {
            if format.format == .R8G8B8A8_SRGB || format.format == .B8G8R8A8_SRGB {
                result.swapchain_format = format.format
                break get_swapchain_format
            }
        }
        
        result.swapchain_format = formats[0].format
        break get_swapchain_format
    }
    
    ok := gpu_recreate_swapchain_if_needed(&result)
    assert(ok)
    
    return result
}

gpu_deinit :: proc (gpu: ^Gpu) {
    defer gpu^ = {}
    
    destroy_all_handles(gpu.device)
    gpu_destroy_swapchain(gpu)
    
    vk.DestroyDevice(gpu.device, nil)
    
    vk.DestroySurfaceKHR(gpu.instance, gpu.surface, nil)
    vk.DestroyInstance(gpu.instance, nil)
}




////////////////////////////////////////////////

Memory_Kind :: enum u32 {
    Default,  // cpu_mapped_gpu_memory, for fast gpu read, and direct cpu copying into
    GPU,      // gpu only memory for texture data, or big gpu-only buffers
    Readback, // cpu cached
}

Hazard_Flags :: bit_set[Hazard_Flag; u32]
Hazard_Flag :: enum u32 {
    draw_arguments, // Indirect Draw Commands modify possibly prefetched data
    descriptors,    // If you write to the texture descriptor heap @todo make gpu_barrier respect this
    depth_stencil,  
}


////////////////////////////////////////////////

Topology :: vk.PrimitiveTopology
Cull     :: enum { None, CCW, CW, All }
Blend    :: vk.BlendOp
Factor   :: vk.BlendFactor

Format :: vk.Format

Raster_Desc :: struct {
    topology:                     Topology,
    cull:                         Cull,
    alpha_to_coverage:            bool,
    // support_dual_source_blending: bool,
    sample_count:                 u8,
    depth_format:                 Format,
    stencil_format:               Format,
    color_targets:                [] Color_Target,
    blendstate:                   ^Blend_Desc, // optional embedded blend state
}

DefaultRasterDesc :: Raster_Desc {
    topology = .TRIANGLE_LIST,
    sample_count = 1,
}

Color_Target :: struct {
    format:     Format,
    write_mask: Color_Mask, // should default to { .R, .G, .B, .A }
}

Blend_Desc :: struct {
    color_op: Blend,
    src_color_factor: Factor,
    dst_color_factor: Factor,
    alpha_op: Blend,
    src_alpha_factor: Factor,
    dst_alpha_factor: Factor,
    color_write_mask: Color_Mask,
}

DefaultBlendDesc :: Blend_Desc {
    src_color_factor = .ONE,
    src_alpha_factor = .ONE,
    color_write_mask = DefaulColorMask,
}

DefaulColorMask :: Color_Mask { .R, .G, .B, .A }

Color_Mask :: vk.ColorComponentFlags

Texture_Desc :: struct {
    kind:         vk.ImageType,
    size:         uv3,
    format:       Format,
    mip_count:    u32,
    sample_count: u32,
    usage:        vk.ImageUsageFlags,
}

default_texture_desc :: proc (
    kind:         vk.ImageType = .D2,
    size:         uv3 = 1,
    format:       Format = .UNDEFINED,
    mip_count:    u32 = 1,
    sample_count: u32 = 1,
    usage:        vk.ImageUsageFlags = {},
) -> Texture_Desc {
    result := Texture_Desc {
        kind = kind,
        size = size,
        format = format,
        mip_count = mip_count,
        sample_count = sample_count,
        usage = usage,
    }
    return result
}




////////////////////////////////////////////////
// Memory

GpuAddress :: struct ($T: typeid) {
    p: vk.DeviceAddress,
}

GpuSlice :: struct ($T: typeid) {
    p:         vk.DeviceAddress,
    byte_size: int,
}

// @todo(viktor): can we find a way not or a better place to store this metadata per allocation?
_the_gpu_allocations: map[vk.DeviceAddress] GpuAllocation
GpuAllocation :: struct {
    buffer:  vk.Buffer,
    memory:  vk.DeviceMemory,
    address: vk.DeviceAddress,
    offset:  vk.DeviceSize,
}

gpu_reflect_get_allocation :: proc (address: vk.DeviceAddress) -> GpuAllocation {
    alloc, ok := _the_gpu_allocations[address]
    assert(ok)
    return alloc
} 
gpu_reflect_get_buffer :: proc (address: vk.DeviceAddress) -> (vk.Buffer, vk.DeviceSize) {
    alloc := gpu_reflect_get_allocation(address)
    return alloc.buffer, alloc.offset
}
gpu_reflect_set_allocation :: proc (address: vk.DeviceAddress, buffer: GpuAllocation, offset: u32 = 0) {
    _the_gpu_allocations[address] = { buffer.buffer, buffer.memory, buffer.address, buffer.offset + cast(vk.DeviceSize) offset }
}

gpu_allocate :: proc { gpu_allocate_size, gpu_allocate_slice, gpu_allocate_type }
gpu_allocate_size :: proc (gpu: ^Gpu, size: umm, alignment: umm = 16, memory: Memory_Kind = .Default, usage := vk.BufferUsageFlags { .STORAGE_BUFFER }) -> (cpu_result: pmm, gpu_result: vk.DeviceAddress) {
    usage := usage
    usage += { .SHADER_DEVICE_ADDRESS }
    
    flags := vk.MemoryPropertyFlags {}
    switch memory {
    case .Default:  flags = { .HOST_VISIBLE, .HOST_COHERENT/* , .DEVICE_LOCAL @todo decide if this is needed here */ }
    case .GPU:      flags = { .HOST_VISIBLE, .DEVICE_LOCAL }
    case .Readback: flags = { .HOST_VISIBLE, .HOST_COHERENT, .HOST_CACHED }
    }
    
    alloc: GpuAllocation
    create_info := vk.BufferCreateInfo {
        sType = .BUFFER_CREATE_INFO,
        size  = auto_cast size,
        usage = usage,
    }
    
    check(vk.CreateBuffer(gpu.device, &create_info, nil, &alloc.buffer))
    
    requirements: vk.MemoryRequirements
    vk.GetBufferMemoryRequirements(gpu.device, alloc.buffer, &requirements)
    
    requirements.alignment = max(requirements.alignment, cast(vk.DeviceSize) alignment)
    alloc.memory = select_memory_type_and_allocate(gpu, requirements, flags, add_device_address_flag = true)
    
    check(vk.BindBufferMemory(gpu.device, alloc.buffer, alloc.memory, 0))
    
    vk.MapMemory(gpu.device, alloc.memory, 0, auto_cast size, {}, &cpu_result)
    
    adress_create_info := vk.BufferDeviceAddressInfo {
        sType = .BUFFER_DEVICE_ADDRESS_INFO,
        buffer = alloc.buffer,
    }
    alloc.address = vk.GetBufferDeviceAddress(gpu.device, &adress_create_info)
    assert(alloc.address != 0)
    
    gpu_result = alloc.address
    
    gpu_reflect_set_allocation(gpu_result, alloc)
    
    return cpu_result, gpu_result
}

gpu_allocate_slice :: proc (gpu: ^Gpu, $T: typeid/ [] $E, #any_int count: umm, alignment: umm = align_of(E), memory: Memory_Kind = .Default, usage := vk.BufferUsageFlags { .STORAGE_BUFFER }) -> ([] E, GpuSlice(E)) {
    size := size_of(E) * count
    cpu_pointer, gpu_pointer := gpu_allocate_size(gpu, size, alignment, memory, usage)
    result := slice_from_parts(E, cpu_pointer, count)
    return result, { gpu_pointer, cast(int) size }
}

gpu_allocate_type :: proc (gpu: ^Gpu, $T: typeid, alignment: umm = align_of(T), memory: Memory_Kind = .Default, usage := vk.BufferUsageFlags { .STORAGE_BUFFER }) -> (^T,GpuAddress(T)) {
    cpu_pointer, gpu_pointer := gpu_allocate_size(gpu, size_of(T), alignment, memory, usage)
    result := cast(^T) cpu_pointer
    return result, { gpu_pointer }
}

gpu_free :: proc { gpu_free_pointer, gpu_free_address, gpu_free_slice }
gpu_free_pointer :: proc (gpu: ^Gpu, pointer: vk.DeviceAddress) {
    alloc := gpu_reflect_get_allocation(pointer)
    assert(alloc.offset == 0)
    vk.FreeMemory(gpu.device,    alloc.memory, nil)
    vk.DestroyBuffer(gpu.device, alloc.buffer, nil)
}
gpu_free_address :: proc (gpu: ^Gpu, address: GpuAddress($T)) {
    gpu_free_pointer(gpu, address.p)
}
gpu_free_slice :: proc (gpu: ^Gpu, slice: GpuSlice($T)) {
    gpu_free_pointer(gpu, slice.p)
}




////////////////////////////////////////////////
// Textures

// @copypasta this can be compressed with allocate_size
gpu_allocate_texture :: proc (gpu: ^Gpu, desc: Texture_Desc) -> Image {
    samples: vk.SampleCountFlag
    switch desc.sample_count {
    case  1: samples = ._1
    case  2: samples = ._2
    case  4: samples = ._4
    case  8: samples = ._8
    case 16: samples = ._16
    case: unreachable()
    }
    
    create_info := vk.ImageCreateInfo {
        sType = .IMAGE_CREATE_INFO,
        imageType     = desc.kind,
        format        = desc.format,
        extent        = { **desc.size },
        mipLevels     = desc.mip_count,
        samples       = { samples },
        usage         = desc.usage,
        arrayLayers   = 1,
        tiling        = .OPTIMAL,
        initialLayout = .UNDEFINED,
    }
    
    result: Image
    result.format = desc.format
    result.size = desc.size
    check(vk.CreateImage(gpu.device, &create_info, nil, &result.image))
    
    requirements: vk.MemoryRequirements
    vk.GetImageMemoryRequirements(gpu.device, result.image, &requirements)
    
    result.memory = select_memory_type_and_allocate(gpu, requirements, { .DEVICE_LOCAL })
    
    check(vk.BindImageMemory(gpu.device, result.image, result.memory, 0))
    
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

get_image_aspect_mask :: proc (format: vk.Format) -> vk.ImageAspectFlags {
    // :Stencil: add .STENCIL to the aspect mask
    result := vk.ImageAspectFlags { .COLOR }
    #partial switch format {
    case .D32_SFLOAT, .D32_SFLOAT_S8_UINT, .D16_UNORM, .D16_UNORM_S8_UINT, .D24_UNORM_S8_UINT: result = { .DEPTH }
    }
    return result
}

gpu_create_image_view :: proc (gpu: ^Gpu, image: Image, mip_base: u32, mip_count: u32) -> vk.ImageView {
    aspect_mask := get_image_aspect_mask(image.format)
    
    view_create_info := vk.ImageViewCreateInfo {
        sType = .IMAGE_VIEW_CREATE_INFO,
        image    = image.image,
        viewType = .D2,
        format   = image.format,
        subresourceRange = { aspectMask = aspect_mask, baseMipLevel = mip_base, levelCount = mip_count, layerCount = 1 },
    }
    
    result: vk.ImageView
    check(vk.CreateImageView(gpu.device, &view_create_info, nil, &result))
    
    return result
}

gpu_free_image :: proc (gpu: ^Gpu, image: Image) {
    vk.DestroyImage(gpu.device, image.image, nil)
    vk.FreeMemory(gpu.device,   image.memory, nil)
}

gpu_destroy_texture_view :: proc (gpu: ^Gpu, view: vk.ImageView) {
    vk.DestroyImageView(gpu.device, view, nil)
}



////////////////////////////////////////////////
// Pipelines 

// @cleanup
gpu_create_compute_pipeline :: proc (gpu: ^Gpu, compute: Shader, descriptor_size, sampler_size: u32, set_layout: ..vk.DescriptorSetLayout, sampler_hack_names: [] string = {}) -> Pipeline {
    // @todo(viktor): allow for optional shader constant, i.e. vulkan specialization constants
    assert(compute.stage == .COMPUTE)
    compute := compute
    
    result: Pipeline
    result.bind_point = .COMPUTE
    
    result.resource_mask  = compute.parsed.resource_mask
    result.resource_types = compute.parsed.resource_types
    
    mappings := [32] vk.DescriptorSetAndBindingMappingEXT {}
    heap_mapping: vk.ShaderDescriptorSetAndBindingMappingInfoEXT
    heap_mapping = generate_heap_mappings(result.resource_mask, result.resource_types, sampler_hack_names, size_of(vk.DeviceAddress), descriptor_size, sampler_size, &mappings)
    
    create_info := vk.ComputePipelineCreateInfo {
        sType = .COMPUTE_PIPELINE_CREATE_INFO,
        
        pNext = &vk.PipelineCreateFlags2CreateInfo {
            sType = .PIPELINE_CREATE_FLAGS_2_CREATE_INFO,
            flags = { .DESCRIPTOR_HEAP_EXT },
        },
        
        stage  = { 
            sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, 
            stage = { compute.stage }, 
            pName = "main", 
            pNext = &vk.ShaderModuleCreateInfo {
                sType    = .SHADER_MODULE_CREATE_INFO,
                codeSize = len(compute.bytes),
                pCode    = cast(^u32) &compute.bytes[0],
                
                pNext = &heap_mapping,
            },
        },
    }
    
    check(vk.CreateComputePipelines(gpu.device, gpu.pipeline_cache, 1, &create_info, nil, &result.pipeline))
    
    return result
}

gpu_create_graphics_pipeline :: proc (gpu: ^Gpu, vertex, fragment: Shader, info: Raster_Desc, descriptor_size, sampler_size: u32) -> Pipeline {
    assert(vertex.stage   == .VERTEX)
    assert(fragment.stage == .FRAGMENT)
    
    result: Pipeline
    gpu_create_graphics_pipeline_common(gpu, &result, info, descriptor_size, sampler_size, vertex, fragment)
    
    return result
}

gpu_create_graphics_meshlet_pipeline :: proc { gpu_create_graphics_meshlet_pipeline_tmp, gpu_create_graphics_meshlet_pipeline_mp }

gpu_create_graphics_meshlet_pipeline_tmp :: proc (gpu: ^Gpu, task, mesh, frag: Shader, info: Raster_Desc, descriptor_size, sampler_size: u32, sampler_hack_names := [] string {}) -> Pipeline {
    assert(task.stage == .TASK_EXT)
    assert(mesh.stage == .MESH_EXT)
    assert(frag.stage == .FRAGMENT)
    
    result: Pipeline
    gpu_create_graphics_pipeline_common(gpu, &result, info, descriptor_size, sampler_size, task, mesh, frag, sampler_hack_names = sampler_hack_names)
    
    return result
}

gpu_create_graphics_meshlet_pipeline_mp :: proc (gpu: ^Gpu, mesh, frag: Shader, info: Raster_Desc, descriptor_size, sampler_size: u32) -> Pipeline {
    assert(mesh.stage == .MESH_EXT)
    assert(frag.stage == .FRAGMENT)
    
    result: Pipeline
    gpu_create_graphics_pipeline_common(gpu, &result, info, descriptor_size, sampler_size, mesh, frag)
    
    return result
}

gpu_create_graphics_pipeline_common :: proc (gpu: ^Gpu, result: ^Pipeline, info: Raster_Desc, descriptor_size, sampler_size: u32, shaders: ..Shader, sampler_hack_names := [] string {}) {
    result.resource_types, result.resource_mask = gather_descriptor_resources(..shaders)
    
    mappings := [32] vk.DescriptorSetAndBindingMappingEXT {}
    heap_mapping: vk.ShaderDescriptorSetAndBindingMappingInfoEXT
    heap_mapping = generate_heap_mappings(result.resource_mask, result.resource_types, sampler_hack_names, size_of(vk.DeviceAddress), descriptor_size, sampler_size, &mappings)
    
    shader_stages: [dynamic; 8] vk.PipelineShaderStageCreateInfo
    module_infos:  [dynamic; 8] vk.ShaderModuleCreateInfo
    for &shader in shaders {
        append(&module_infos, vk.ShaderModuleCreateInfo {
            sType = .SHADER_MODULE_CREATE_INFO, 
            codeSize = len(shader.bytes), 
            pCode    = cast(^u32) raw_data(shader.bytes),
            
            pNext = &heap_mapping,
        })
        
        append(&shader_stages, vk.PipelineShaderStageCreateInfo{ 
            sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, 
            stage = { shader.stage }, 
            pName = "main", 
            pNext = last(&module_infos),
        })
    }
    
    dynamic_states := [] vk.DynamicState { .VIEWPORT, .SCISSOR, .LINE_WIDTH }
    
    color_formats: [dynamic; 32] Format
    for target in info.color_targets { append(&color_formats, target.format) }
    
    // @todo(viktor): this has a bunch more fields
    color_attachments: [dynamic; 32] vk.PipelineColorBlendAttachmentState
    for target in info.color_targets {
        attachment := vk.PipelineColorBlendAttachmentState {
            colorWriteMask = target.write_mask,
        }
        
        if info.blendstate != nil {
            attachment.blendEnable = true
            
            attachment.alphaBlendOp = info.blendstate.alpha_op
            attachment.colorBlendOp = info.blendstate.color_op
            
            attachment.srcAlphaBlendFactor = info.blendstate.src_alpha_factor
            attachment.dstAlphaBlendFactor = info.blendstate.dst_alpha_factor
            
            attachment.srcColorBlendFactor = info.blendstate.src_color_factor
            attachment.dstColorBlendFactor = info.blendstate.dst_color_factor
        }
        
        append(&color_attachments, attachment)
    }
    
    sample_count: vk.SampleCountFlag
    switch info.sample_count {
    case: assert(false, "invalid sample count")
    case 1:  sample_count = ._1
    case 2:  sample_count = ._2
	case 4:  sample_count = ._4
	case 8:  sample_count = ._8
	case 16: sample_count = ._16
	case 32: sample_count = ._32
	case 64: sample_count = ._64
    }
    
    cull_mode:  vk.CullModeFlags
    switch info.cull {
    case .None: cull_mode = {}
    case .CCW:  cull_mode = { .FRONT }
    case .CW:   cull_mode = { .BACK  }
    case .All:  cull_mode = { .FRONT, .BACK }
    }
    
    create_info := vk.GraphicsPipelineCreateInfo {
        sType = .GRAPHICS_PIPELINE_CREATE_INFO,
        
        pNext = &vk.PipelineRenderingCreateInfo {
            sType = .PIPELINE_RENDERING_CREATE_INFO,
            
            pNext = &vk.PipelineCreateFlags2CreateInfo {
                sType = .PIPELINE_CREATE_FLAGS_2_CREATE_INFO,
                flags = { .DESCRIPTOR_HEAP_EXT },
            },
            
            colorAttachmentCount    = auto_cast len(color_formats),
            pColorAttachmentFormats = raw_data(&color_formats),
            depthAttachmentFormat   = info.depth_format,
            stencilAttachmentFormat = info.stencil_format,
        },
        
        stageCount = auto_cast len(shader_stages),
        pStages    = &shader_stages[0],
        
        pInputAssemblyState = &vk.PipelineInputAssemblyStateCreateInfo {
            sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            topology = info.topology,
        },
        
        // @study can there be more then 1 with dynamic states?
        pViewportState = &vk.PipelineViewportStateCreateInfo {
            sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            viewportCount = 1,
            scissorCount  = 1,
        },
        
        pRasterizationState = &vk.PipelineRasterizationStateCreateInfo {
            sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            cullMode  = cull_mode,
            frontFace = .COUNTER_CLOCKWISE,
            
            // @todo(viktor): which of these fields can by dynamic state?
            // depthClampEnable:        b32,
            // rasterizerDiscardEnable: b32,
            // polygonMode:             PolygonMode,
            // depthBiasEnable:         b32, -> ext dynamic state
            // depthBiasConstantFactor: f32,
            // depthBiasClamp:          f32,
            // depthBiasSlopeFactor:    f32,
        },
        
        pMultisampleState = &vk.PipelineMultisampleStateCreateInfo {
            sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            rasterizationSamples = { sample_count },
        },
        
        // @todo(viktor): read from info
        pDepthStencilState = &vk.PipelineDepthStencilStateCreateInfo {
            sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
            depthTestEnable  = true,
            depthWriteEnable = true,
            depthCompareOp   = .GREATER,
            // :Stencil: stencilTestEnable:     b32,
        },
        
        pColorBlendState = &vk.PipelineColorBlendStateCreateInfo {
            sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            attachmentCount = auto_cast len(color_attachments),
            pAttachments    = raw_data(&color_attachments),
            // @todo(viktor): these field from the optional blend desc? can these be dynamic state?
            // logicOpEnable:   b32,     -> ext dynamic state
            // logicOp:         LogicOp, -> ext dynamic state
            // blendConstants:  [4]f32,  -> dynamic state
        },
        
        pDynamicState = &vk.PipelineDynamicStateCreateInfo {
            sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            dynamicStateCount = auto_cast len(dynamic_states),
            pDynamicStates    = raw_data(dynamic_states),
        },
    }
    
    check(vk.CreateGraphicsPipelines(gpu.device, gpu.pipeline_cache, 1, &create_info, nil, &result.pipeline))
}

pipeline_is_valid :: proc (pipeline: Pipeline) -> bool {
    result := pipeline.pipeline != 0
    return result
}

destroy_pipeline :: proc (gpu: ^Gpu, pipeline: Pipeline) {
    if pipeline_is_valid(pipeline) {
        check(vk.DeviceWaitIdle(gpu.device))
        vk.DestroyPipeline(gpu.device, pipeline.pipeline, nil)
    }
}



////////////////////////////////////////////////
// State Objects

// GpuDepthStencilState gpuCreateDepthStencilState(GpuDepthStencilDesc desc);
// GpuBlendState gpuCreateBlendState(GpuBlendDesc desc);
// void gpuFreeDepthStencilState(GpuDepthStencilState state);
// void gpuFreeBlendState(GpuBlendState state);



////////////////////////////////////////////////
// Queue

// GpuQueue gpuCreateQueue(/* DEVICE & QUEUE CREATION DETAILS OMITTED */);

// @todo(viktor): queue is ignored, we need to allocate from a pool created with the correct queue_family_index
gpu_begin_command_recording :: proc (gpu: ^Gpu, command_pool: vk.CommandPool, _: vk.Queue) -> vk.CommandBuffer {
    info := vk.CommandBufferAllocateInfo {
        sType = .COMMAND_BUFFER_ALLOCATE_INFO,
        commandPool        = command_pool,
        commandBufferCount = 1,
    }
    
    result: vk.CommandBuffer
    check(vk.AllocateCommandBuffers(gpu.device, &info, &result))
    
    begin_info := vk.CommandBufferBeginInfo { 
        sType = .COMMAND_BUFFER_BEGIN_INFO, 
        flags = { .ONE_TIME_SUBMIT }, 
    }
    check(vk.BeginCommandBuffer(result, &begin_info))
    
    return result
}

gpu_submit :: proc (queue: vk.Queue, semaphore: vk.Semaphore, signal_value: u64, command_buffers: ..vk.CommandBuffer) {
    for cmd in command_buffers {
        check(vk.EndCommandBuffer(cmd))
    }
    
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
    
    check(vk.QueueSubmit2(queue, 1, &once_submit_info, 0))
}



////////////////////////////////////////////////
// Semaphores

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

gpu_wait_semaphore :: proc (gpu: ^Gpu, semaphore: vk.Semaphore, wait_value: u64, timeout := MaxTimeout) -> (timed_out: bool) {
    semaphores := [?] vk.Semaphore { semaphore }
    values     := [?] u64 { wait_value }
    
    info := vk.SemaphoreWaitInfo {
        sType = .SEMAPHORE_WAIT_INFO,
        semaphoreCount = len(semaphores),
        pSemaphores    = &semaphores[0],
        pValues        = &values[0],
    }
    
    wait_result := vk.WaitSemaphores(gpu.device, &info, timeout)
    if wait_result == .TIMEOUT {
        timed_out = true
    }
    check(wait_result)
    
    return timed_out
}

gpu_destroy_semaphore :: proc (gpu: ^Gpu, semaphore: vk.Semaphore) {
    vk.DestroySemaphore(gpu.device, semaphore, nil)
}




////////////////////////////////////////////////
// Commands

// void gpuMemCpy(GpuCommandBuffer cb, void* destGpu, void* srcGpu,);

gpu_copy :: proc (gpu: ^Gpu, cmd: vk.CommandBuffer, destination: any, source: pmm) {
    unimplemented()
}

gpu_copy_to_texture :: proc (gpu: ^Gpu, cmd: vk.CommandBuffer, destination: Image, source: vk.DeviceAddress) {
    alloc := gpu_reflect_get_allocation(source)
    
    region := vk.BufferImageCopy {
        bufferOffset = alloc.offset,
        imageSubresource = { aspectMask = { .COLOR }, mipLevel = 0, layerCount = 1 },
        imageExtent      = { **destination.size },
    }
    
    vk.CmdCopyBufferToImage(cmd, alloc.buffer, destination.image, destination.last_layout, 1, &region)
}

gpu_copy_from_texture :: proc (gpu: ^Gpu, cmd: vk.CommandBuffer, destination: vk.DeviceAddress, source: Image, size: uv3) {
    alloc := gpu_reflect_get_allocation(destination)
    
    region := vk.BufferImageCopy {
        bufferOffset = alloc.offset,
        imageSubresource = { aspectMask = { .COLOR }, mipLevel = 0, layerCount = 1 },
        imageExtent      = { **size },
    }
    
    vk.CmdCopyImageToBuffer(cmd, source.image, source.last_layout, alloc.buffer, 1, &region)
}

gpu_barrier :: proc (command_buffer: vk.CommandBuffer, before, after: vk.PipelineStageFlags2, hazard := Hazard_Flags {}, loc := #caller_location) {
    assert(before != {}, loc = loc)
    assert(after  != {}, loc = loc)
    
    info := vk.DependencyInfo {
        sType = .DEPENDENCY_INFO,
        
        memoryBarrierCount = 1,
        pMemoryBarriers    = &vk.MemoryBarrier2 {
            sType = .MEMORY_BARRIER_2,
            
            srcStageMask = before,
            dstStageMask = after,
            
            // @todo(viktor): set based on hazards
            srcAccessMask = { .MEMORY_READ, .MEMORY_WRITE },
            dstAccessMask = { .MEMORY_READ, .MEMORY_WRITE },
        },
    }
    
    // @todo tell the gpu to flush any descriptor caches in texture samplers, or whereever
    // if .descriptors in hazard {
    // }
    
    vk.CmdPipelineBarrier2(command_buffer, &info)
}

// @todo
// void gpuSignalAfter(GpuCommandBuffer cb, STAGE before, void *ptrGpu, uint64 value, SIGNAL signal);
// void gpuWaitBefore(GpuCommandBuffer cb, STAGE after, void *ptrGpu, uint64 value, OP op, HAZARD_FLAGS hazards = 0, uint64 mask = ~0);

gpu_signal_after :: proc (command_buffer: vk.CommandBuffer, stage: vk.PipelineStageFlags2, gpu_pointer: pmm, count: u64, signal_op: any) {
    unimplemented()
}

gpu_wait_before :: proc (command_buffer: vk.CommandBuffer, stage: vk.PipelineStageFlags2, gpu_pointer: pmm, value: u64, wait_op: any) {
    unimplemented()
}

the_bound_pipeline: Pipeline

gpu_set_pipeline :: proc (command_buffer: vk.CommandBuffer, pipeline: Pipeline) {
    vk.CmdBindPipeline(command_buffer, pipeline.bind_point, pipeline.pipeline)
    the_bound_pipeline = pipeline
}

gpu_set_viewport :: proc (cmd: vk.CommandBuffer, offset: v2 = 0, size: v2, min_depth: f32 = 0, max_depth: f32 = 1) {
    vk.CmdSetViewport(cmd, 0, 1, &vk.Viewport { offset.x, offset.y, size.x, size.y, min_depth, max_depth })
}

gpu_set_scissor :: proc (cmd: vk.CommandBuffer, offset: iv2 = 0, size: uv2) {
    vk.CmdSetScissor(cmd, 0, 1, &vk.Rect2D { offset = { **offset }, extent = { **size } })
}

// @todo(viktor): 
// void gpuSetDepthStencilState(GpuCommandBuffer cb, GpuDepthStencilState state);
// void gpuSetBlendState(GpuCommandBuffer cb, GpuBlendState state); 

Render_Target :: struct {
    texture: Image,
    
    load_op:  vk.AttachmentLoadOp,
    store_op: vk.AttachmentStoreOp,
    
    clear_depth:   f32,
    clear_stencil: u32,
    clear_color:   v4,
}

Render_Pass_Desc :: struct {
    depth_target:   Render_Target,
    stencil_target: Render_Target,
    color_targets:  [] Render_Target,
}

gpu_begin_render_pass :: proc (gpu: ^Gpu, cmd: vk.CommandBuffer, desc: Render_Pass_Desc) {
    // @api this should maybe be a parameter
    render_size := gpu.swapchain_size
    
    color_attachments: [dynamic; 64] vk.RenderingAttachmentInfo
    for target in desc.color_targets {
        it := append_into(&color_attachments)
        it^ = {
            sType = .RENDERING_ATTACHMENT_INFO,
            
            imageLayout = .ATTACHMENT_OPTIMAL,
            imageView   = target.texture.view,
            loadOp  = target.load_op,
            storeOp = target.store_op,
        }
        it.clearValue.color.float32 = target.clear_color
    }
    
    rendering_info := vk.RenderingInfo {
        sType = .RENDERING_INFO, 
        
        renderArea = { extent = { **render_size } },
        layerCount = 1,
        
        colorAttachmentCount = auto_cast len(color_attachments),
        pColorAttachments = raw_data(&color_attachments),
    }
    
    if desc.depth_target.texture.image != 0 {
        rendering_info.pDepthAttachment = &vk.RenderingAttachmentInfo {
            sType = .RENDERING_ATTACHMENT_INFO,
            imageLayout = .ATTACHMENT_OPTIMAL,
            imageView   = desc.depth_target.texture.view,
            loadOp      = desc.depth_target.load_op,
            storeOp     = desc.depth_target.store_op,
            clearValue  = { depthStencil = { depth = desc.depth_target.clear_depth } },
        }
    }
    
    if desc.stencil_target.texture.image != 0 {
        rendering_info.pStencilAttachment = &vk.RenderingAttachmentInfo {
            sType = .RENDERING_ATTACHMENT_INFO,
            imageLayout = .ATTACHMENT_OPTIMAL,
            imageView   = desc.stencil_target.texture.view,
            loadOp      = desc.stencil_target.load_op,
            storeOp     = desc.stencil_target.store_op,
            clearValue  = { depthStencil = { stencil = desc.stencil_target.clear_stencil } },
        }
    }
    
    vk.CmdBeginRendering(cmd, &rendering_info)
}
gpu_end_render_pass :: proc (cmd: vk.CommandBuffer) {
    vk.CmdEndRendering(cmd)
}

// void gpuDispatchIndirect(GpuCommandBuffer cb, void* dataGpu, void* gridDimensionsGpu);

// void gpuDrawIndexedInstanced(GpuCommandBuffer cb, void* vertexDataGpu, void* pixelDataGpu, void* indicesGpu, uint32 indexCount, uint32 instanceCount);
// void gpuDrawIndexedInstancedIndirect(GpuCommandBuffer cb, void* vertexDataGpu, void* pixelDataGpu, void* indicesGpu, void* argsGpu);
// void gpuDrawIndexedInstancedIndirectMulti(GpuCommandBuffer cb, void* dataVxGpu, uint32 vxStride, void* dataPxGpu, uint32 pxStride, void* argsGpu, void* drawCountGpu);

// void gpuDrawMeshlets(GpuCommandBuffer cb, void* meshletDataGpu, void* pixelDataGpu, uvec3 dim);
// void gpuDrawMeshletsIndirect(GpuCommandBuffer cb, void* meshletDataGpu, void* pixelDataGpu, void *dimGpu);

push_descriptor_heap :: proc (gpu: ^Gpu, heap: ^Descriptor_Heap, frame_descriptor: ^Frame_Descriptor, updates: [] DescriptorUpdateData) -> u32 {
    resource_types, resource_mask := the_bound_pipeline.resource_types, the_bound_pipeline.resource_mask
    
    descriptor_count := card(resource_mask)
    
    assert(frame_descriptor.descriptor_offset + auto_cast descriptor_count <= frame_descriptor.descriptor_end)
    descriptor_size := heap.resource_size
    
    result := frame_descriptor.descriptor_offset
    for index in cast(u32) 0..<32 {
        if index in resource_mask {
            info := &updates[index]
            
            descriptor: Descriptor
            type := resource_types[index]
            
            #partial switch type {
            case .SAMPLER: continue // mapped via constant offsets (statically)
            
            case .SAMPLED_IMAGE, .STORAGE_IMAGE:
                image := info.image
                
                get_descriptor_image(gpu, image.image, image.format, image.last_layout, info.mip_base, info.mip_count, type, &descriptor, descriptor_size)
            
            case .UNIFORM_BUFFER, .STORAGE_BUFFER:
                unimplemented()
                /* 
                const Buffer* buffer = static_cast<const Buffer*>(info.resource);
				getDescriptor(framedesc.device, buffer->address, buffer->size, program.resourceTypes[i], descriptor, framedesc.descriptorSize);
                 */
                
            case .ACCELERATION_STRUCTURE_KHR: 
                unimplemented()
                /* 
                VkAccelerationStructureDeviceAddressInfoKHR addressInfo = { VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_DEVICE_ADDRESS_INFO_KHR };
				addressInfo.accelerationStructure = info.accelerationStructure;
				VkDeviceAddress address = vkGetAccelerationStructureDeviceAddressKHR(framedesc.device, &addressInfo);
				getDescriptor(framedesc.device, address, 0, program.resourceTypes[i], descriptor, framedesc.descriptorSize);
                */
            case:
                unreachable()
            }
            
            copy(heap.resources_cpu[frame_descriptor.descriptor_offset * descriptor_size:], descriptor[:descriptor_size])
            frame_descriptor.descriptor_offset += 1
        }
    }
    
    return result
}

// @api we may want to allow the pipeline to have a push constant per stage. For that we need the shaders to each declare the push data to be N pointers to their respective data. Then the pipeline layout and this command both need to declare the correct size of 3 pointers and their offsets in the push data.
gpu_push_constants :: proc (cmd: vk.CommandBuffer, frame_descriptor: ^Frame_Descriptor, push_constant: GpuAddress($T), heap := false) {
    push_constant := push_constant
    info := vk.PushDataInfoEXT {
        sType = .PUSH_DATA_INFO_EXT,
        data  = { address = &push_constant.p, size = size_of(push_constant.p) },
    }
    vk.CmdPushDataEXT(cmd, &info)
}

// @cleanup
gpu_push_descriptors :: proc (cmd: vk.CommandBuffer, gpu: ^Gpu, heap: ^Descriptor_Heap, frame_descriptor: ^Frame_Descriptor, updates: [] DescriptorUpdateData) {
    descriptor_offset := push_descriptor_heap(gpu, heap, frame_descriptor, updates)
    
    info := vk.PushDataInfoEXT {
        sType = .PUSH_DATA_INFO_EXT,
        
        offset = size_of(vk.DeviceAddress), // size of the push_constant
        data = { address = &descriptor_offset, size = size_of(descriptor_offset) },
    }
    vk.CmdPushDataEXT(cmd, &info)
}

gpu_dispatch :: proc (cmd: vk.CommandBuffer, frame_descriptor: ^Frame_Descriptor, push_constant: GpuAddress($T), group_size: uv3) {
    gpu_push_constants(cmd, frame_descriptor, push_constant)
    vk.CmdDispatch(cmd, **group_size)
}

gpu_draw_meshlets_indirect_count :: proc (cmd: vk.CommandBuffer, frame_descriptor: ^Frame_Descriptor, commands: vk.DeviceAddress, count: GpuAddress(u32), max_count: u32, stride: u32, command_offset: umm, push_constant: GpuAddress($T)) {
    // @speed 
    commands, commands_base_offset := gpu_reflect_get_buffer(commands)
    count,    count_offset         := gpu_reflect_get_buffer(count.p)
    
    gpu_push_constants(cmd, frame_descriptor, push_constant)
    vk.CmdDrawMeshTasksIndirectCountEXT(cmd, commands, commands_base_offset + cast(vk.DeviceSize) command_offset, count, count_offset, max_count, stride)
}



////////////////////////////////////////////////
// Descriptor Heap

DescriptorStaticLimit   :: 65536 // static resource descriptors
DescriptorPerFrameLimit :: 1024  // submitted per frame via push
DescriptorSamplerLimit  :: 16    // just sampler descriptors

Descriptor_Heap :: struct {
    resources_cpu: [] u8,
    resources_gpu: GpuSlice(u8),
    samplers_cpu: [] u8,
    samplers_gpu: GpuSlice(u8),
    
    resource_size: u32,
    sampler_size:  u32,
    
    resource_reserved_offset: vk.DeviceSize,
    resource_reserved_size:   vk.DeviceSize,
    
    sampler_reserved_offset: vk.DeviceSize,
    sampler_reserved_size:   vk.DeviceSize,
}

Frame_Descriptor :: struct {
    descriptor_offset: u32,
    descriptor_end:    u32,
}

Descriptor :: distinct [128] u8

create_descriptor_heap :: proc (gpu: ^Gpu) -> Descriptor_Heap {
    resource_count      := cast(vk.DeviceSize) DescriptorStaticLimit + MaxFramesInFlight * DescriptorPerFrameLimit
    resource_size       := max(gpu.heap_properties.bufferDescriptorSize, gpu.heap_properties.imageDescriptorSize)
    resource_alignment  := max(gpu.heap_properties.bufferDescriptorAlignment, gpu.heap_properties.imageDescriptorAlignment)
    
    resource_reserved   := gpu.heap_properties.minResourceHeapReservedRange
    resource_total_size := resource_reserved + resource_size * resource_count
    
    sampler_count      := cast(vk.DeviceSize) DescriptorSamplerLimit
    sampler_size       := gpu.heap_properties.samplerDescriptorSize
    sampler_alignment  := gpu.heap_properties.samplerDescriptorAlignment
    sampler_reserved   := gpu.heap_properties.minSamplerHeapReservedRange
    sampler_total_size := sampler_reserved + sampler_size * sampler_count
    
    result: Descriptor_Heap
    result.resources_cpu, result.resources_gpu = gpu_allocate_slice(gpu, [] u8, auto_cast resource_total_size, alignment = cast(umm) resource_alignment, usage = { .DESCRIPTOR_HEAP_EXT } )
    result.samplers_cpu,  result.samplers_gpu  = gpu_allocate_slice(gpu, [] u8, auto_cast sampler_total_size,  alignment = cast(umm) sampler_alignment,  usage = { .DESCRIPTOR_HEAP_EXT } )
    
    // @correctness we should respect the alignment, which may increase the total size
    result.resource_reserved_offset = resource_count * resource_size
    result.sampler_reserved_offset  = sampler_count  * sampler_size
    result.resource_reserved_size   = resource_reserved
    result.sampler_reserved_size    = sampler_reserved
    
    result.resource_size = cast(u32) resource_size
    result.sampler_size  = cast(u32) sampler_size
    
    // :SamplerHack: fill samplers[0] with texture sampler and samplers[1] with depth sampler
    sampler_descriptor_size := resource_size // :SamplerHack:
    get_descriptor_sampler(gpu, .LINEAR, .LINEAR,  .REPEAT,        .WEIGHTED_AVERAGE, auto_cast &result.samplers_cpu[0 * sampler_descriptor_size], cast(u32) sampler_size)
    get_descriptor_sampler(gpu, .LINEAR, .NEAREST, .CLAMP_TO_EDGE, .WEIGHTED_AVERAGE, auto_cast &result.samplers_cpu[1 * sampler_descriptor_size], cast(u32) sampler_size)
    get_descriptor_sampler(gpu, .LINEAR, .NEAREST, .CLAMP_TO_EDGE, .MIN,              auto_cast &result.samplers_cpu[2 * sampler_descriptor_size], cast(u32) sampler_size)
    
    return result
}

destroy_descriptor_heap :: proc (gpu: ^Gpu, heap: Descriptor_Heap) {
    gpu_free_pointer(gpu, heap.samplers_gpu.p)
    gpu_free_pointer(gpu, heap.resources_gpu.p)
}

// @speed this is called multiple times in a frame. reduce this to once a frame as soon as all pipelines are migrated
gpu_set_active_heap :: proc (cmd: vk.CommandBuffer, heap: ^Descriptor_Heap) {
    sampler_info := vk.BindHeapInfoEXT {
        sType = .BIND_HEAP_INFO_EXT,
        heapRange = {
            address = heap.samplers_gpu.p,
            size    = cast(vk.DeviceSize) heap.samplers_gpu.byte_size,
        },
        reservedRangeOffset = heap.sampler_reserved_offset,
        reservedRangeSize   = heap.sampler_reserved_size,
    }
    
    resource_info := vk.BindHeapInfoEXT {
        sType = .BIND_HEAP_INFO_EXT,
        heapRange = { 
            address = heap.resources_gpu.p,
            size    = cast(vk.DeviceSize) heap.resources_gpu.byte_size,
        },
        reservedRangeOffset = heap.resource_reserved_offset,
        reservedRangeSize   = heap.resource_reserved_size,
    }
    
    vk.CmdBindSamplerHeapEXT(cmd,  &sampler_info)
    vk.CmdBindResourceHeapEXT(cmd, &resource_info)
}

get_descriptor :: proc { get_descriptor_image, get_descriptor_buffer, get_descriptor_sampler }
// @todo switch to .GENERAL layout for all images
get_descriptor_image :: proc (gpu: ^Gpu, image: vk.Image, format: vk.Format, layout: vk.ImageLayout, mip_base: u32, mip_count: u32, type: vk.DescriptorType, descriptor: ^Descriptor, descriptor_size: u32) {
    aspect_mask := get_image_aspect_mask(format)
    
    image_info := vk.ImageDescriptorInfoEXT {
        sType = .IMAGE_DESCRIPTOR_INFO_EXT,
        pView = &vk.ImageViewCreateInfo {
            sType = .IMAGE_VIEW_CREATE_INFO,
            image    = image,
            viewType = .D2,
            format   = format,
            subresourceRange = { aspectMask = aspect_mask, baseMipLevel = mip_base, levelCount = mip_count, layerCount = 1 },
        },
        layout = layout,
    }
    
    info := vk.ResourceDescriptorInfoEXT {
        sType = .RESOURCE_DESCRIPTOR_INFO_EXT,
        type = type,
        data = { pImage = &image_info },
    }
    
    range := vk.HostAddressRangeEXT { address = raw_data(descriptor), size = cast(int) descriptor_size }
    check(vk.WriteResourceDescriptorsEXT(gpu.device, 1, &info, &range))
}

get_descriptor_buffer :: proc (gpu: ^Gpu, address: vk.DeviceAddress, size: vk.DeviceSize, type: vk.DescriptorType, descriptor: ^Descriptor, descriptor_size: u32) {
    buffer_info := vk.DeviceAddressRangeEXT { address = address, size = size }
    
    info := vk.ResourceDescriptorInfoEXT {
        sType = .RESOURCE_DESCRIPTOR_INFO_EXT,
        type = type,
        data = { pAddressRange =  &buffer_info },
    }
    
    range := vk.HostAddressRangeEXT { address = raw_data(descriptor), size = cast(int) descriptor_size }
    check(vk.WriteResourceDescriptorsEXT(gpu.device, 1, &info, &range))
}

get_descriptor_sampler :: proc (gpu: ^Gpu, filter: vk.Filter, mipmap_mode: vk.SamplerMipmapMode, address_mode: vk.SamplerAddressMode, reduction_mode: vk.SamplerReductionMode, descriptor: ^Descriptor, descriptor_size: u32, anisotropy: b32 = false) {
    info := vk.SamplerCreateInfo {
        sType = .SAMPLER_CREATE_INFO,
        
        magFilter  = filter,
        minFilter  = filter,
        mipmapMode = mipmap_mode,
        
        addressModeU = address_mode,
        addressModeV = address_mode,
        addressModeW = address_mode,
        
        anisotropyEnable = anisotropy,
        maxAnisotropy    = anisotropy ? 8 : 1,
        
        minLod = 0,
        maxLod = 16,
    }
    
    reduction_info := vk.SamplerReductionModeCreateInfo {
        sType = .SAMPLER_REDUCTION_MODE_CREATE_INFO,
        reductionMode = reduction_mode,
    }
    
    if reduction_mode != .WEIGHTED_AVERAGE {
        info.pNext = &reduction_info
    }
    
    range := vk.HostAddressRangeEXT { address = raw_data(descriptor), size = cast(int) descriptor_size }
    check(vk.WriteSamplerDescriptorsEXT(gpu.device, 1, &info, &range))
}