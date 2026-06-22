#+vet explicit-allocators !unused-procedures
package main

 /////////////////////////////////////////////////////////////////////
//                                                                  //
//                                                                  //
//                       No graphics api                            //
//                                                                  //
//              (or as little as possible with Vulkan)              // 
//                                                                  // 
// based on: https://www.sebastianaaltonen.com/blog/no-graphics-api //
/////////////////////////////////////////////////////////////////////

import "base:runtime"

import "core:fmt"

import vk  "vendor:vulkan"
import sdl "vendor:sdl3"

// @todo import the cpu profiler and extract the common parts with the gpu profiler,

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
    
    command_pools:            [MaxFramesInFlight] vk.CommandPool,
    image_aquired_semaphores: [MaxFramesInFlight] vk.Semaphore,
    
    ////////////////////////////////////////////////
    
    queue: vk.Queue, // this is the graphics and compute queue, we could also create a queue just for transfers/copying
    
    // @incomplete this is never initialized. It may help performance if we need to create/recreate many pipelines.
    pipeline_cache: vk.PipelineCache,
    
    swapchain_format: vk.Format,
    
    ////////////////////////////////////////////////
    // these all have the same lifetime as the swapchain
    
    swapchain_size: uv2,
    
    swapchain: vk.SwapchainKHR,
    swapchain_images: [dynamic] Image, // this is only an image to make use of the last: Transition
    render_completes: [dynamic] vk.Semaphore,
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

Memory_Kind :: enum u32 {
    Default,  // cpu_mapped_gpu_memory, for fast gpu read, and direct cpu copying into
    GPU,      // gpu only memory for texture data, or big gpu-only buffers
    Readback, // cpu cached
}

Hazard_Flags :: bit_set[Hazard_Flag; u32]
Hazard_Flag :: enum u32 {
    draw_arguments, // Indirect Draw Commands modify possibly prefetched data
    descriptors,    // If you write to the texture descriptor heap
    depth_stencil,  
}

Gpu_Texture_Kind :: enum u32 {
    _2D, // default should be 2D
    _1D,
    _3D,
    Cube,
    _2D_Array,
    Cube_Array,
}

Gpu_Usage_Flags :: vk.ImageUsageFlags /* bit_set[Usage_Flag; u32]
Usage_Flag ::  enum u32 {
    sampled,
    storage,
    color_attachment,
    depth_stencil_attachment,
    // ...
} */

////////////////////////////////////////////////

Texture_Desc :: struct {
    kind: Gpu_Texture_Kind,
    dimensions: uv3,
    
    mip_count:    u32, // default = 1
    layer_count:  u32, // default = 1
    sample_count: vk.SampleCountFlags, // default = 1
    
    format: Format,
    usage:  Gpu_Usage_Flags,
}

Texture_Descriptor :: struct {
    data: [4] u64,
}

Texture :: distinct u64

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




////////////////////////////////////////////////
// Memory

Gpu_Address :: struct ($T: typeid) { address: vk.DeviceAddress }

// @todo(viktor): can we find a way not to store this metadata per allocation?
the_allocations: map[vk.DeviceAddress] Buffer

// @api with scalar_block_layout, do we ever need an alignment parameter?
// it seems that base structs should still be aligned by 16 bytes to make the best use of the loading hardware
// this does not change with scalar block layout, as that just reduces padding issues between cpu and gpu.
gpu_allocate :: proc { gpu_allocate_size, gpu_allocate_slice, gpu_allocate_type }
gpu_allocate_size :: proc (gpu: ^Gpu, size: umm, alignment: umm = 16, memory: Memory_Kind = .Default, usage := vk.BufferUsageFlags { .STORAGE_BUFFER }) -> (cpu_result: pmm, gpu_result: vk.DeviceAddress) {
    usage := usage
    usage += { .SHADER_DEVICE_ADDRESS }
    
    flags := vk.MemoryPropertyFlags {}
    switch memory {
    case .Default:  flags = { .HOST_VISIBLE, .HOST_COHERENT }
    case .GPU:      flags = { .HOST_VISIBLE, .DEVICE_LOCAL }
    case .Readback: flags = { .HOST_VISIBLE, .HOST_COHERENT, .HOST_CACHED }
    }
    
    // @cleanup inline and simplify
    gpu_make_buffer :: proc (gpu: ^Gpu, #any_int size: vk.DeviceSize, usage: vk.BufferUsageFlags, flags: vk.MemoryPropertyFlags) -> (Buffer, pmm) {
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
    
    // @cleanup and use alignment
    buffer, result := gpu_make_buffer(gpu, size, usage, flags = flags)
    cpu_result = result
    
    info := vk.BufferDeviceAddressInfo { sType  = .BUFFER_DEVICE_ADDRESS_INFO, buffer = buffer.buffer }
    gpu_result = vk.GetBufferDeviceAddress(gpu.device, &info)
    
    the_allocations[gpu_result] = buffer
    
    return cpu_result, gpu_result
}

gpu_allocate_slice :: proc (gpu: ^Gpu, $T: typeid/ [] $E, #any_int count: umm, memory: Memory_Kind = .Default, usage := vk.BufferUsageFlags { .STORAGE_BUFFER }) -> (result: [] E, gpu_result: vk.DeviceAddress) {
    cpu_pointer, gpu_pointer := gpu_allocate_size(gpu, size_of(E) * count, align_of(E), memory, usage)
    result = slice_from_parts(E, cpu_pointer, count)
    return result, gpu_pointer
}

gpu_allocate_type :: proc (gpu: ^Gpu, $T: typeid, memory: Memory_Kind = .Default, usage := vk.BufferUsageFlags { .STORAGE_BUFFER }) -> (result: ^T, gpu_result: Gpu_Address(T)) {
    cpu_pointer, gpu_pointer := gpu_allocate_size(gpu, size_of(T), align_of(T), memory, usage)
    return cast(^T) cpu_pointer, Gpu_Address(T) { gpu_pointer }
}

gpu_free :: proc { gpu_free_pointer, gpu_free_address }
gpu_free_pointer :: proc (gpu: ^Gpu, pointer: vk.DeviceAddress) {
    buffer := the_allocations[pointer]
    vk.FreeMemory(gpu.device,    buffer.memory, nil)
    vk.DestroyBuffer(gpu.device, buffer.buffer, nil)
}
gpu_free_address :: proc (gpu: ^Gpu, address: Gpu_Address($T)) {
    gpu_free_pointer(gpu, address.address)
}




////////////////////////////////////////////////
// Textures

// @todo
// GpuTextureSizeAlign gpuTextureSizeAlign(GpuTextureDesc desc);
// GpuTexture gpuCreateTexture(GpuTextureDesc desc, void* ptrGpu);
// GpuTextureDescriptor gpuTextureViewDescriptor(GpuTexture texture, GpuViewDesc desc);
// GpuTextureDescriptor gpuRWTextureViewDescriptor(GpuTexture texture, GpuViewDesc desc);

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
// Pipelines 

// @cleanup
gpu_create_compute_pipeline :: proc (gpu: ^Gpu, compute: Shader, temporary_set_layout: vk.DescriptorSetLayout = 0) -> Pipeline {
    // @todo(viktor): allow for optional shader constant, i.e. vulkan specialization constants
    assert(compute.stage == .COMPUTE)
    
    result: Pipeline
    result.bind_point    = .COMPUTE
    result.shader_stages = { .COMPUTE }
    
    if temporary_set_layout != 0 {
        result.layout = create_pipeline_layout(gpu, result.shader_stages, temporary_set_layout)
    } else {
        result.layout = create_pipeline_layout(gpu, result.shader_stages)
    }
    
    create_info := vk.ComputePipelineCreateInfo {
        sType = .COMPUTE_PIPELINE_CREATE_INFO,
        layout = result.layout,
        stage  = { 
            sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, 
            stage = { compute.stage }, 
            pName = "main", 
            pNext = &vk.ShaderModuleCreateInfo {
                sType    = .SHADER_MODULE_CREATE_INFO,
                codeSize = len(compute.bytes),
                pCode    = cast(^u32) &compute.bytes[0],
            },
        },
    }
    
    check(vk.CreateComputePipelines(gpu.device, gpu.pipeline_cache, 1, &create_info, nil, &result.pipeline))
    
    return result
}

gpu_create_graphics_pipeline :: proc (gpu: ^Gpu, vertex, fragment: Shader, info: Raster_Desc) -> Pipeline {
    assert(vertex.stage   == .VERTEX)
    assert(fragment.stage == .FRAGMENT)
    
    result: Pipeline
    gpu_create_graphics_pipeline_common(gpu, &result, info, vertex, fragment)
    
    return result
}

gpu_create_graphics_meshlet_pipeline :: proc { gpu_create_graphics_meshlet_pipeline_tmp, gpu_create_graphics_meshlet_pipeline_mp }

// @todo(viktor): get rid of the set_layout which should only be the textures actually, just make the texture_heap a parameter
gpu_create_graphics_meshlet_pipeline_tmp :: proc (gpu: ^Gpu, task, mesh, frag: Shader, info: Raster_Desc, set_layout: vk.DescriptorSetLayout) -> Pipeline {
    assert(task.stage == .TASK_EXT)
    assert(mesh.stage == .MESH_EXT)
    assert(frag.stage == .FRAGMENT)
    
    result: Pipeline
    gpu_create_graphics_pipeline_common(gpu, &result, info, task, mesh, frag, set_layout = set_layout)
    
    return result
}

gpu_create_graphics_meshlet_pipeline_mp :: proc (gpu: ^Gpu, mesh, frag: Shader, info: Raster_Desc) -> Pipeline {
    assert(mesh.stage == .MESH_EXT)
    assert(frag.stage == .FRAGMENT)
    
    result: Pipeline
    gpu_create_graphics_pipeline_common(gpu, &result, info, mesh, frag)
    
    return result
}

create_pipeline_layout :: proc (gpu: ^Gpu, stage_flags: vk.ShaderStageFlags, set_layouts: ..vk.DescriptorSetLayout) -> vk.PipelineLayout {
    info := vk.PipelineLayoutCreateInfo { sType = .PIPELINE_LAYOUT_CREATE_INFO }
    
    if len(set_layouts) > 0 {
        info.setLayoutCount = cast(u32) len(set_layouts)
        info.pSetLayouts    = &set_layouts[0]
    }
    
    size_of_push_constant := cast(u32) size_of(vk.DeviceAddress)
    if size_of_push_constant != 0 {
        info.pushConstantRangeCount = 1
        info.pPushConstantRanges = &vk.PushConstantRange {
            stageFlags = stage_flags,
            size       = size_of_push_constant,
        }
    }
    
    result: vk.PipelineLayout
    check(vk.CreatePipelineLayout(gpu.device, &info, nil, &result))
    
    return result
}

gpu_create_graphics_pipeline_common :: proc (gpu: ^Gpu, result: ^Pipeline, info: Raster_Desc, shaders: ..Shader, set_layout: vk.DescriptorSetLayout = 0) {
    shader_stages: [dynamic; 4] vk.PipelineShaderStageCreateInfo
    module_infos:  [dynamic; 4] vk.ShaderModuleCreateInfo
    for shader in shaders {
        result.shader_stages += { shader.stage }
        
        append(&module_infos, vk.ShaderModuleCreateInfo {
            sType = .SHADER_MODULE_CREATE_INFO, 
            codeSize = len(shader.bytes), 
            pCode    = cast(^u32) raw_data(shader.bytes),
        })
        
        append(&shader_stages, vk.PipelineShaderStageCreateInfo{ 
            sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, 
            stage = { shader.stage }, 
            pName = "main", 
            pNext = last(&module_infos),
        })
    }
    
    result.layout = create_pipeline_layout(gpu, result.shader_stages, set_layout)
        
    // @todo(viktor): make as much of this a dynamic state
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
            colorAttachmentCount    = auto_cast len(color_formats),
            pColorAttachmentFormats = raw_data(&color_formats),
            depthAttachmentFormat   = info.depth_format,
            stencilAttachmentFormat = info.stencil_format,
        },
        
        stageCount = auto_cast len(shader_stages),
        pStages    = &shader_stages[0],
        
        layout = result.layout,
        
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
        
        vk.DestroyPipelineLayout(gpu.device,           pipeline.layout,          nil)
        vk.DestroyPipeline(gpu.device,                 pipeline.pipeline,        nil)
        vk.DestroyDescriptorUpdateTemplate(gpu.device, pipeline.update_template, nil)
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

gpu_destroy_semaphore :: proc (gpu: ^Gpu, semaphore: vk.Semaphore) {
    vk.DestroySemaphore(gpu.device, semaphore, nil)
}




////////////////////////////////////////////////
// Commands

// void gpuMemCpy(GpuCommandBuffer cb, void* destGpu, void* srcGpu,);
// void gpuCopyToTexture(GpuCommandBuffer cb, void* destGpu, void* srcGpu, GpuTexture texture);
// void gpuCopyFromTexture(GpuCommandBuffer cb, void* destGpu, void* srcGpu, GpuTexture texture);

// @api provide a version that allows multiple dest, source pairs with a single wait, or make it begin-end for now?
gpu_copy :: proc (gpu: ^Gpu, cmd: vk.CommandBuffer, destination: any, source: pmm) {
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
    
    gpu_submit(gpu.queue, semaphore, 1, cmd)
    gpu_wait_semaphore(gpu, semaphore, 1)
}

gpu_copy_to_texture :: proc (gpu: ^Gpu, cmd: vk.CommandBuffer, destination: pmm, source: pmm, texture: Texture) {
    
}

gpu_copy_from_texture :: proc (gpu: ^Gpu, cmd: vk.CommandBuffer, destination: pmm, source: pmm, texture: Texture) {
    
}

// @todo
// void gpuSetActiveTextureHeapPtr(GpuCommandBuffer cb, void *ptrGpu);

MaxTimeout :: max(u64)

// @todo(viktor): check where niagara uses dependency flags and add it
gpu_barrier :: proc (command_buffer: vk.CommandBuffer, before, after: vk.PipelineStageFlags2, hazard := Hazard_Flags {}) {
    // @study vk.DependencyFlags
    info := vk.DependencyInfo {
        sType = .DEPENDENCY_INFO,
        
        memoryBarrierCount = 1,
        pMemoryBarriers    = &vk.MemoryBarrier2 {
            sType = .MEMORY_BARRIER_2,
            srcStageMask = before,
            dstStageMask = after,
            // srcAccessMask = vk.AccessFlags2., // @todo(viktor): set based on hazards
            // dstAccessMask: AccessFlags2,
        },
    }
    
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

// void gpuDispatchIndirect(GpuCommandBuffer cb, void* dataGpu, void* gridDimensionsGpu);

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
        it.sType = .RENDERING_ATTACHMENT_INFO
        
        it.imageLayout = .ATTACHMENT_OPTIMAL
        it.imageView   = target.texture.view
        it.loadOp  = target.load_op
        it.storeOp = target.store_op
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

// void gpuDrawIndexedInstanced(GpuCommandBuffer cb, void* vertexDataGpu, void* pixelDataGpu, void* indicesGpu, uint32 indexCount, uint32 instanceCount);
// void gpuDrawIndexedInstancedIndirect(GpuCommandBuffer cb, void* vertexDataGpu, void* pixelDataGpu, void* indicesGpu, void* argsGpu);
// void gpuDrawIndexedInstancedIndirectMulti(GpuCommandBuffer cb, void* dataVxGpu, uint32 vxStride, void* dataPxGpu, uint32 pxStride, void* argsGpu, void* drawCountGpu);

// void gpuDrawMeshlets(GpuCommandBuffer cb, void* meshletDataGpu, void* pixelDataGpu, uvec3 dim);
// void gpuDrawMeshletsIndirect(GpuCommandBuffer cb, void* meshletDataGpu, void* pixelDataGpu, void *dimGpu);

// @api make gpu_data type safer
gpu_dispatch :: proc (command_buffer: vk.CommandBuffer, pointer_to_the_gpu_address: ^^$T, group_size: uv3) {
    assert(the_bound_pipeline.pipeline != 0, "no pipeline was bound")
    
    vk.CmdPushConstants(command_buffer, the_bound_pipeline.layout, the_bound_pipeline.shader_stages, 0, size_of(vk.DeviceAddress), pointer_to_the_gpu_address)
    
    vk.CmdDispatch(command_buffer, **group_size)
}

gpu_draw_meshlets_indirect_count :: proc (cmd: vk.CommandBuffer, commands, count: vk.Buffer, max_count: u32, stride: u32, command_offset: umm, count_offset: umm) {
    vk.CmdDrawMeshTasksIndirectCountEXT(cmd, commands, auto_cast command_offset, count, auto_cast  count_offset, max_count, size_of(Draw_Command))
}




////////////////////////////////////////////////
// @cleanup @placement

gpu_make_image :: proc (gpu: ^Gpu, size: uv2, format: vk.Format, usage: vk.ImageUsageFlags, aspect_mask: vk.ImageAspectFlags, flags := vk.MemoryPropertyFlags { .DEVICE_LOCAL }, mip_levels : u32 = 1) -> Image {
    assert(gpu.device != nil)
    
    create_info := vk.ImageCreateInfo {
        sType = .IMAGE_CREATE_INFO,
        imageType     = .D2,
        format        = format,
        extent        = { size.x, size.y, 1 },
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

gpu_delete :: proc { gpu_delete_image }
gpu_delete_image :: proc (gpu: ^Gpu, image: Image) {
    assert(gpu.device != nil)
    
    vk.DestroyImageView(gpu.device, image.view, nil)
    vk.DestroyImage(gpu.device,     image.image, nil)
    vk.FreeMemory(gpu.device,       image.memory, nil)
}

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
