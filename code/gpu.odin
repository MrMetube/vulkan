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

import "base:intrinsics"
import "base:runtime"

import "core:dynlib"
import "core:fmt"
import "core:os"

import win "core:sys/windows"
import vk  "../lib/vulkan"

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
    
    swapchain_size: uv2,
    
    swapchain: vk.SwapchainKHR,
    swapchain_images: [dynamic] Image, // technically only the vk.Image and size: uv2 are used
    render_completes: [dynamic] vk.Semaphore,
}

Swapchain_State :: enum { 
    Dirty,
    Was_Resized,
    Ok,
    Window_Is_Minimized,
}

Memory_Kind :: enum u32 {
    Default,  // cpu_mapped_gpu_memory, for fast gpu read, and direct cpu copying into
    GPU,      // gpu only memory for texture data, or big gpu-only buffers
    Readback, // cpu cached
}

Pipeline :: struct {
    pipeline:   vk.Pipeline,
    bind_point: vk.PipelineBindPoint,
}

////////////////////////////////////////////////

Gpu_Slice :: struct ($E: typeid) {
    cpu: [] E,
    gpu: Gpu_Pointer(E),
}

Gpu_Address :: struct ($T: typeid) {
    cpu: ^T,
    gpu: Gpu_Pointer(T),
}

Gpu_Pointer :: struct ($T: typeid) {
    p: vk.DeviceAddress,
}

// If we had access to the address_range extension, most if not all vulkan calls that take a buffer object could be deleted.
_the_gpu_allocations: map[vk.DeviceAddress] GpuAllocation
GpuAllocation :: struct {
    buffer: vk.Buffer,
    memory: vk.DeviceMemory,
    offset: vk.DeviceSize,
}

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
    sample_count:                 vk.SampleCountFlag,
    depth_format:                 Format,
    stencil_format:               Format,
    color_targets:                [] Color_Target,
    blendstate:                   ^Blend_Desc, // optional embedded blend state
}

DefaultRasterDesc :: Raster_Desc {
    topology = .TRIANGLE_LIST,
    sample_count = ._1,
    cull = .CW,
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

Render_Target :: struct {
    texture: Image,
    view:    vk.ImageView,
    
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

DescriptorStaticLimit   :: 65536 // static resource descriptors
DescriptorPerFrameLimit :: 1024  // submitted per frame via push
DescriptorSamplerLimit  :: 16    // just sampler descriptors

Descriptor_Heap :: struct {
    // Both resources and samplers have a stride of resource_size, which is the larger or buffer and image descriptor size for the current gpu.
    // Therefore indexing needs to be done manually with [index * resource_size], whilst the written to/read from bytes of descriptors is either
    // the resource size or the sampler size, based on the resource itself.
    resources: Gpu_Slice(u8),
    samplers:  Gpu_Slice(u8),
    
    resource_size: u32,
    sampler_size:  u32,
    
    resource_reserved_offset: vk.DeviceSize,
    resource_reserved_size:   vk.DeviceSize,
    
    sampler_reserved_offset: vk.DeviceSize,
    sampler_reserved_size:   vk.DeviceSize,
}

Frame_Descriptor :: struct {
    descriptor_offset: Texture_Index,
    descriptor_end:    Texture_Index,
}

////////////////////////////////////////////////

gpu_init :: proc (windows_hinstance: pmm, vsync: bool) -> Gpu {
    cpu_profile_procedure()
    
    gpu: Gpu
    
    {
        vulkan_path: string
        if ODIN_OS == .Windows {
            vulkan_path = "vulkan-1.dll"
        } else { unimplemented() }
        
        vulkan, did_load := dynlib.load_library(vulkan_path, allocator = context.temp_allocator)
        if !did_load {
            fmt.eprintfln("Could not load the vulkan dynamic lib %q: %v", vulkan_path, dynlib.last_error())
            os.exit(1)
        }
        
        get_instance_proc, ok := dynlib.symbol_address(vulkan, "vkGetInstanceProcAddr", allocator = context.temp_allocator)
        assert(ok)
        
        vk.load_proc_addresses_global(get_instance_proc)
        
        {
            cpu_profile_scope("Vulkan Instance")
            
            instance_extension_names: [dynamic; 16] cstring
            if ODIN_OS == .Windows {
                append(&instance_extension_names, "VK_KHR_surface", "VK_KHR_win32_surface")
            } else { unimplemented() }
            
            when Validation {
                append(&instance_extension_names, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)
            }
            
            instance_create_info := vk.InstanceCreateInfo {
                sType = .INSTANCE_CREATE_INFO,
                pApplicationInfo = &vk.ApplicationInfo {
                    sType = .APPLICATION_INFO,
                    pApplicationName = "Vulkan Renderer",
                    apiVersion = vk.API_VERSION_1_4,
                },
                enabledExtensionCount   = cast(u32) len(instance_extension_names),
                ppEnabledExtensionNames = &instance_extension_names[0],
            }
            
            _ :: runtime
            if Validation {
                validation_layers := [] cstring { "VK_LAYER_KHRONOS_validation" }
                instance_create_info.enabledLayerCount   = cast(u32) len(validation_layers)
                instance_create_info.ppEnabledLayerNames = raw_data(validation_layers)
                
                vulkan_debug_utils_callback :: proc "system" (messageSeverity: vk.DebugUtilsMessageSeverityFlagsEXT, messageTypes: vk.DebugUtilsMessageTypeFlagsEXT, pCallbackData: ^vk.DebugUtilsMessengerCallbackDataEXT, pUserData: rawptr) -> b32 {
                    context = runtime.default_context()
                    if .WARNING in messageSeverity || .ERROR in messageSeverity {
                        fmt.printfln("Validation Layer: %v", pCallbackData.pMessage)
                    }
                    return false
                }
                
                // DEBUG_PRINTF // @todo enable this, if needed
                enabled: [dynamic; 2] vk.ValidationFeatureEnableEXT
                if Sync_Validation { append(&enabled, vk.ValidationFeatureEnableEXT.SYNCHRONIZATION_VALIDATION ) }
                
                instance_create_info.pNext = &vk.DebugUtilsMessengerCreateInfoEXT {
                    sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
                    messageSeverity = { .VERBOSE, .WARNING, .ERROR },
                    messageType     = { .VALIDATION },
                    pfnUserCallback = vulkan_debug_utils_callback,
                    
                    pNext = &vk.ValidationFeaturesEXT {
                        sType = .VALIDATION_FEATURES_EXT,
                        enabledValidationFeatureCount = cast(u32) len(enabled),
                        pEnabledValidationFeatures    = raw_data(&enabled),
                    },
                }
            }
            
            cpu_begin_profile_zone("Create Instance Call")
            check(vk.CreateInstance(&instance_create_info, nil, &gpu.instance))
            cpu_end_profile_zone()
            
            vk.load_proc_addresses_instance(gpu.instance)
            
            assert(vk.GetPhysicalDeviceProperties2 != nil)
        }
        
        ////////////////////////////////////////////////
        
        {
            if ODIN_OS == .Windows {
                
                info := vk.Win32SurfaceCreateInfoKHR {
                    sType = .WIN32_SURFACE_CREATE_INFO_KHR,
                    hinstance = cast(win.HANDLE) windows_hinstance,
                    hwnd      = win.GetActiveWindow(),
                }
                check(vk.CreateWin32SurfaceKHR(gpu.instance, &info, nil, &gpu.surface))
            } else { unimplemented() }
        }
        
        ////////////////////////////////////////////////
        
        {
            physical_devices: [dynamic; 128] vk.PhysicalDevice
            {
                device_count: u32
                check(vk.EnumeratePhysicalDevices(gpu.instance, &device_count, nil))
                assert(device_count <= cap(physical_devices))
                resize(&physical_devices, device_count)
                check(vk.EnumeratePhysicalDevices(gpu.instance, &device_count, raw_data(&physical_devices)))
            }
            
            preferred: vk.PhysicalDevice
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
                            family_index_with_graphics = cast(u32) index
                            break
                        }
                    }
                }
                
                if family_index_with_graphics == vk.QUEUE_FAMILY_IGNORED { continue }
                
                supported: b32
                vk.GetPhysicalDeviceSurfaceSupportKHR(device, family_index_with_graphics, gpu.surface, &supported)
                if !supported { continue }
                
                properties := vk.PhysicalDeviceProperties2 { sType = .PHYSICAL_DEVICE_PROPERTIES_2 }
                vk.GetPhysicalDeviceProperties2(device, &properties)
                if properties.properties.apiVersion < vk.API_VERSION_1_4 { continue }
                
                if properties.properties.deviceType == .CPU { continue }
                
                if preferred == nil && properties.properties.deviceType == .DISCRETE_GPU {
                    preferred = device
                }
                
                if fallback == nil {
                    fallback = device
                }
            }
            assert(fallback != nil, "Could not find any compatible device :(")
            
            gpu.physical_device = preferred != nil ? preferred : fallback
        }
        
        gpu.heap_properties = vk.PhysicalDeviceDescriptorHeapPropertiesEXT {
            sType = .PHYSICAL_DEVICE_DESCRIPTOR_HEAP_PROPERTIES_EXT,
        }
        gpu.device_properties = vk.PhysicalDeviceProperties2 { 
            sType = .PHYSICAL_DEVICE_PROPERTIES_2,
            pNext = &gpu.heap_properties,
        }
        vk.GetPhysicalDeviceProperties2(gpu.physical_device, &gpu.device_properties)
        
        fmt.printfln("Selected device: %v", cast(cstring) &gpu.device_properties.properties.deviceName[0])
        assert(gpu.device_properties.properties.limits.timestampComputeAndGraphics)
    }
    
    ////////////////////////////////////////////////
    // Extensions
    
    {
        cpu_profile_scope("Device")
        device_extensions := [] cstring { 
            vk.KHR_SWAPCHAIN_EXTENSION_NAME,
            vk.EXT_MESH_SHADER_EXTENSION_NAME,
            vk.KHR_DRAW_INDIRECT_COUNT_EXTENSION_NAME,
            vk.EXT_DESCRIPTOR_HEAP_EXTENSION_NAME,
            vk.KHR_UNIFIED_IMAGE_LAYOUTS_EXTENSION_NAME,
            vk.KHR_SHADER_UNTYPED_POINTERS_EXTENSION_NAME,
        }
        
        {
            count: u32
            vk.EnumerateDeviceExtensionProperties(gpu.physical_device, nil, &count, nil)
            extensions := make([] vk.ExtensionProperties, count, context.temp_allocator)
            vk.EnumerateDeviceExtensionProperties(gpu.physical_device, nil, &count, raw_data(extensions))
            
            desired_found := make([] b8, len(device_extensions), context.temp_allocator)
            
            for &it in extensions {
                for desired, desired_index in device_extensions {
                    if desired_found[desired_index] { continue }
                    
                    if desired == cast(cstring) &it.extensionName[0] {
                        desired_found[desired_index] = true
                        break
                    }
                }
            }
            
            all_supported: bool = true
            for found, index in desired_found {
                if !found {
                    fmt.printfln("Extension not supported: %v", device_extensions[index])
                    all_supported = false
                }
            }
            assert(all_supported)
        }
        
        f11 := vk.PhysicalDeviceVulkan11Features {
            sType = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
            
            storageBuffer16BitAccess           = true,
            uniformAndStorageBuffer16BitAccess = true,
            shaderDrawParameters               = true,
        }
        
        f12 := vk.PhysicalDeviceVulkan12Features {
            sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
            
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
            
            synchronization2 = true,
            dynamicRendering = true, // remove the need for RenderPass and FrameBuffer objects
            maintenance4     = true, // needed to use layout(local_size...)
        }
        
        f14 := vk.PhysicalDeviceVulkan14Features {
            sType = .PHYSICAL_DEVICE_VULKAN_1_4_FEATURES,
            
            maintenance5   = true, // deprecates ShaderModule
            pushDescriptor = true, // remove the need for CmdBindVertexBuffers
            dynamicRenderingLocalRead = true, // allows rendering to an image and then copying into the swapchain image, whilst using dynamic_rendering
        }
        
        f2 := vk.PhysicalDeviceFeatures2 {
            sType = .PHYSICAL_DEVICE_FEATURES_2,
            
            // @correctness These are technically optional device features, and should be queried for availablity before using them.
            features = { 
                multiDrawIndirect = true, // supported on NVidia since the GTX 1080
                samplerAnisotropy = true, // required since 1.4
                shaderInt16       = true, // required since 1.4
                shaderInt64       = true,
                
                pipelineStatisticsQuery = true,
            },
        }
                
        f_heap := vk.PhysicalDeviceDescriptorHeapFeaturesEXT {
            sType = .PHYSICAL_DEVICE_DESCRIPTOR_HEAP_FEATURES_EXT,
            descriptorHeap = true,
        }
        
        f_mesh := vk.PhysicalDeviceMeshShaderFeaturesEXT {
            sType = .PHYSICAL_DEVICE_MESH_SHADER_FEATURES_EXT,
            
            meshShader = true, // 57.18% (vulkan.gpuinfo.org for "1.4 and up" on 18.06.2026)
            taskShader = true,
            meshShaderQueries = true,
        }
        
        f_pointer := vk.PhysicalDeviceShaderUntypedPointersFeaturesKHR {
            sType = .PHYSICAL_DEVICE_SHADER_UNTYPED_POINTERS_FEATURES_KHR,
            shaderUntypedPointers = true,
        }
        
        queue_family_index: u32
        
        device_create_info := vk.DeviceCreateInfo {
            sType = .DEVICE_CREATE_INFO,
            
            queueCreateInfoCount = 1,
            pQueueCreateInfos    = &vk.DeviceQueueCreateInfo {
                sType = .DEVICE_QUEUE_CREATE_INFO,
                queueFamilyIndex = queue_family_index,
                queueCount       = 2,
                pQueuePriorities = raw_data([]f32{ 1, 0 }),
            },
            
            enabledExtensionCount   = cast(u32) len(device_extensions),
            ppEnabledExtensionNames = raw_data(device_extensions),
        }
        
        ppNext := &device_create_info.pNext
        ppNext^ = &f11; ppNext = &f11.pNext
        ppNext^ = &f12; ppNext = &f12.pNext
        ppNext^ = &f13; ppNext = &f13.pNext
        ppNext^ = &f14; ppNext = &f14.pNext
        ppNext^ = &f2;  ppNext = &f2.pNext
        
        ppNext^ = &f_mesh; ppNext = &f_mesh.pNext
        ppNext^ = &f_heap; ppNext = &f_heap.pNext
        ppNext^ = &f_pointer; ppNext = &f_pointer.pNext
        
        cpu_begin_profile_zone("Create Device Call")
        check(vk.CreateDevice(gpu.physical_device, &device_create_info, nil, &gpu.device))
        cpu_end_profile_zone()
        
        vk.load_proc_addresses_device(gpu.device)
        
        ////////////////////////////////////////////////
        
        vk.GetDeviceQueue(gpu.device, queue_family_index, 0, &gpu.general_queue)
        vk.GetDeviceQueue(gpu.device, queue_family_index, 1, &gpu.transfer_queue)
        
        vk.GetPhysicalDeviceMemoryProperties(gpu.physical_device, &gpu.memory_properties)
        
        ////////////////////////////////////////////////
        
        {
            for &pool in gpu.command_pools {
                command_pool_create_info := vk.CommandPoolCreateInfo {
                    sType = .COMMAND_POOL_CREATE_INFO,
                    flags            = { .RESET_COMMAND_BUFFER },
                    queueFamilyIndex = queue_family_index,
                }
                
                check(vk.CreateCommandPool(gpu.device, &command_pool_create_info, nil, &pool))
            }
            
            command_pool_create_info := vk.CommandPoolCreateInfo {
                sType = .COMMAND_POOL_CREATE_INFO,
                flags            = { .RESET_COMMAND_BUFFER },
                queueFamilyIndex = queue_family_index,
            }
            
            check(vk.CreateCommandPool(gpu.device, &command_pool_create_info, nil, &gpu.transfer_command_pool))
        }
        
        ////////////////////////////////////////////////
        
        for &sema in gpu.image_aquired_semaphores {
            sema = gpu_create_semaphore(&gpu)
        }
    }
    
    ////////////////////////////////////////////////
    
    cpu_begin_profile_zone("Swapchain")
    get_swapchain_format: {
        format_count: u32
        check(vk.GetPhysicalDeviceSurfaceFormatsKHR(gpu.physical_device, gpu.surface, &format_count, nil))
        
        formats: [dynamic; 128] vk.SurfaceFormatKHR
        assert(format_count <= cap(formats))
        resize(&formats, format_count)
        check(vk.GetPhysicalDeviceSurfaceFormatsKHR(gpu.physical_device, gpu.surface, &format_count, raw_data(&formats)))
        
        if len(formats) == 1 && formats[0].format == .UNDEFINED {
            gpu.swapchain_format = .R8G8B8A8_SRGB
            break get_swapchain_format
        }
        
        for it in formats {
            if it.format == .R8G8B8A8_SRGB || it.format == .B8G8R8A8_SRGB {
                gpu.swapchain_format = it.format
                break get_swapchain_format
            }
        }
        
        gpu.swapchain_format = formats[0].format
    }
    
    ok := gpu_recreate_swapchain_if_needed(&gpu, vsync)
    assert(ok)
    cpu_end_profile_zone()
    
    return gpu
}

gpu_deinit :: proc (gpu: ^Gpu) {
    defer gpu^ = {}
    
    for &pool in gpu.command_pools {
        vk.DestroyCommandPool(gpu.device, pool, nil)
    }
        
    vk.DestroyCommandPool(gpu.device, gpu.transfer_command_pool, nil)
    for sema in gpu.image_aquired_semaphores {
        vk.DestroySemaphore(gpu.device, sema, nil)
    }
    
    gpu_destroy_swapchain(gpu)
    
    vk.DestroyDevice(gpu.device, nil)
    
    vk.DestroySurfaceKHR(gpu.instance, gpu.surface, nil)
    vk.DestroyInstance(gpu.instance, nil)
}

check :: proc (result: vk.Result, loc := #caller_location) {
    if result != .SUCCESS {
        fmt.printf("%v:%v:%v: Vulkan call returned %v", loc.file_path, loc.line, loc.column, result)
        intrinsics.debug_trap()
    }
}

gpu_recreate_swapchain_if_needed :: proc (gpu: ^Gpu, vsync: bool, force_recreation := false) -> (can_render: bool) {
    if !force_recreation && gpu.swapchain_state != .Dirty && gpu.swapchain_state != .Window_Is_Minimized {
        return true
    }
    
    check(vk.DeviceWaitIdle(gpu.device))
    
    surface_capabilities: vk.SurfaceCapabilitiesKHR
    check(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(gpu.physical_device, gpu.surface, &surface_capabilities))
    
    present_mode := vk.PresentModeKHR.FIFO
    if !vsync {
        present_mode_count: u32
        check(vk.GetPhysicalDeviceSurfacePresentModesKHR(gpu.physical_device, gpu.surface, &present_mode_count, nil))
        present_modes: [dynamic; 32] vk.PresentModeKHR; assert(present_mode_count <= cap(present_modes))
        resize(&present_modes, present_mode_count)
        check(vk.GetPhysicalDeviceSurfacePresentModesKHR(gpu.physical_device, gpu.surface, &present_mode_count, raw_data(&present_modes)))
        
        found: bool
        for mode in present_modes {
            if mode == .IMMEDIATE {
                found = true
                break
            }
        }
        
        if found {
            present_mode = .IMMEDIATE
        } else {
            fmt.printfln("Vsync was requested but is not supported. Falling back to non-vsync, i.e. FIFO.")
        }
    }
    
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
        presentMode      = present_mode,
        
        oldSwapchain = old_swapchain,
    }
    gpu.swapchain_size = { swapchain_extent.width, swapchain_extent.height }
    
    previous_image_count := cast(u32) len(gpu.swapchain_images)
    
    cpu_begin_profile_zone("Create Swapchain Call")
    check(vk.CreateSwapchainKHR(gpu.device, &swapchain_create_info, nil, &gpu.swapchain))
    cpu_end_profile_zone()
    
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
// Memory

gpu_reflect_get_allocation :: proc (address: vk.DeviceAddress) -> GpuAllocation {
    alloc, ok := _the_gpu_allocations[address]
    assert(ok)
    return alloc
} 
gpu_reflect_get_buffer :: proc (address: vk.DeviceAddress) -> (vk.Buffer, vk.DeviceSize) {
    alloc := gpu_reflect_get_allocation(address)
    return alloc.buffer, alloc.offset
}
gpu_reflect_set_allocation :: proc (address: vk.DeviceAddress, alloc: GpuAllocation, offset: u32 = 0) {
    _the_gpu_allocations[address] = { alloc.buffer, alloc.memory, alloc.offset + cast(vk.DeviceSize) offset }
}

gpu_allocate :: proc { gpu_allocate_size, gpu_allocate_slice, gpu_allocate_type }
gpu_allocate_size :: proc (gpu: ^Gpu, size: umm, alignment: umm = 16, memory: Memory_Kind = .Default, usage := vk.BufferUsageFlags { .STORAGE_BUFFER }) -> (cpu_result: pmm, gpu_result: vk.DeviceAddress) {
    usage := usage
    usage += { .SHADER_DEVICE_ADDRESS }
    
    /* 
    
               DEVICE_LOCAL               - static data, compute only buffers
    .GPU     = DEVICE_LOCAL, HOST_VISIBLE - AMD specific, 256 Mb - dynamic per frame data, uniform data
    .Default = HOST_VISIBLE HOST_COHERENT - over PCIe bus - dynamic data and staging buffers for copys to DEVICE_LOCAL only memory
    
    */
    
    /* 
    
    dynamic multicore by default
    
    split a regular call over all idle thread/cores
    join on return
    
    make the main thread just do the regular call and let the other cores seamlessly "join" the workforce on the function
    
    
    
    Explore vkCmdSetEvent and vkCmdWaitEvents as an alternative for full barriers 
    should only be used when a large distance in the command buffer between set and wait is possible
    
    */
    
    // @todo rethink these categories and make a better heuristic for the user, when to use which kind, without needing the test every single one.
    flags := vk.MemoryPropertyFlags {}
    switch memory {
    case .Default:  flags = { .HOST_VISIBLE, .HOST_COHERENT, .DEVICE_LOCAL }
    case .GPU:      flags = { .DEVICE_LOCAL }
    case .Readback: flags = { .HOST_VISIBLE, .HOST_COHERENT, .HOST_CACHED }
    }
    
    alloc: GpuAllocation
    create_info := vk.BufferCreateInfo {
        sType = .BUFFER_CREATE_INFO,
        size  = cast(vk.DeviceSize) size,
        usage = usage,
    }
    
    check(vk.CreateBuffer(gpu.device, &create_info, nil, &alloc.buffer))
    
    requirements: vk.MemoryRequirements
    vk.GetBufferMemoryRequirements(gpu.device, alloc.buffer, &requirements)
    
    requirements.alignment = max(requirements.alignment, cast(vk.DeviceSize) alignment)
    alloc.memory = select_memory_type_and_allocate(gpu, requirements, flags, add_device_address_flag = true)
    
    check(vk.BindBufferMemory(gpu.device, alloc.buffer, alloc.memory, 0))
    
    if .HOST_VISIBLE in flags {
        vk.MapMemory(gpu.device, alloc.memory, 0, cast(vk.DeviceSize) size, {}, &cpu_result)
    }
    
    adress_create_info := vk.BufferDeviceAddressInfo {
        sType = .BUFFER_DEVICE_ADDRESS_INFO,
        buffer = alloc.buffer,
    }
    gpu_result = vk.GetBufferDeviceAddress(gpu.device, &adress_create_info)
    assert(gpu_result != 0)
    
    gpu_reflect_set_allocation(gpu_result, alloc)
    
    return cpu_result, gpu_result
}

gpu_allocate_slice :: proc (gpu: ^Gpu, $T: typeid/ [] $E, #any_int count: umm, alignment: umm = align_of(E), memory: Memory_Kind = .Default, usage := vk.BufferUsageFlags { .STORAGE_BUFFER }) -> Gpu_Slice(E) {
    size := size_of(E) * count
    cpu, gpu := gpu_allocate_size(gpu, size, alignment, memory, usage)
    
    result: Gpu_Slice(E)
    result.cpu = slice_from_parts(E, cpu, count)
    result.gpu = { gpu }
    
    return result
}

gpu_allocate_type :: proc (gpu: ^Gpu, $T: typeid, alignment: umm = align_of(T), memory: Memory_Kind = .Default, usage := vk.BufferUsageFlags { .STORAGE_BUFFER }) -> Gpu_Address(T) {
    cpu, gpu := gpu_allocate_size(gpu, size_of(T), alignment, memory, usage)
    
    result: Gpu_Address(T)
    result.cpu = cast(^T) cpu
    result.gpu = { gpu }
    
    return result
}

gpu_free :: proc { gpu_free_pointer, gpu_free_address, gpu_free_slice }
gpu_free_pointer :: proc (gpu: ^Gpu, pointer: vk.DeviceAddress) {
    alloc := gpu_reflect_get_allocation(pointer)
    assert(alloc.offset == 0)
    vk.FreeMemory(gpu.device,    alloc.memory, nil)
    vk.DestroyBuffer(gpu.device, alloc.buffer, nil)
}
gpu_free_address :: proc (gpu: ^Gpu, address: Gpu_Address($T)) {
    gpu_free_pointer(gpu, address.gpu.p)
}
gpu_free_slice :: proc (gpu: ^Gpu, slice: Gpu_Slice($T)) {
    gpu_free_pointer(gpu, slice.gpu.p)
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
    result := vk.ImageAspectFlags { .COLOR }
    #partial switch format {
    case .D32_SFLOAT, .D16_UNORM:                                     result = { .DEPTH }
    case .D32_SFLOAT_S8_UINT, .D16_UNORM_S8_UINT, .D24_UNORM_S8_UINT: result = { .DEPTH, .STENCIL }
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

Specialization_Constant :: struct #raw_union {
    u: u32,
    b: b32,
}

// This is a helper struct and proc to wrangle all the pointers between structs in one place.
// It must be allocated(on the stack) by the caller, to ensure the internal pointers are valid
// after the return of the helper function.
Pipeline_Info :: struct {
    mappings:               [2] vk.DescriptorSetAndBindingMappingEXT,
    heap_mapping:           vk.ShaderDescriptorSetAndBindingMappingInfoEXT,
    flags2:                 vk.PipelineCreateFlags2CreateInfo,
    
    specialization_entries: [dynamic; 32] vk.SpecializationMapEntry,
    specialization_info:    vk.SpecializationInfo,
    
    shader_stages:          [dynamic; 8] vk.PipelineShaderStageCreateInfo,
    module_infos:           [dynamic; 8] vk.ShaderModuleCreateInfo,
}

make_pipeline_info :: proc (info: ^Pipeline_Info, gpu: ^Gpu, heap: Descriptor_Heap, shaders: [] ^Shader, constants: [] Specialization_Constant) {
    // universal Descriptor Heap mapping
    info.mappings[0] = { // texture array descriptor
        sType = .DESCRIPTOR_SET_AND_BINDING_MAPPING_EXT,
        descriptorSet = 1,
        firstBinding = 0,
        bindingCount = 1,
        resourceMask =  vk.SpirvResourceTypeFlagsEXT_ALL,
        source = .HEAP_WITH_CONSTANT_OFFSET,
        
        sourceData = { constantOffset = { heapArrayStride = heap.resource_size } },
    }
    
    info.mappings[1] = { // sampler descriptors
        sType = .DESCRIPTOR_SET_AND_BINDING_MAPPING_EXT,
        descriptorSet = 2,
        firstBinding = 0,
        bindingCount = DescriptorSamplerLimit,
        resourceMask = vk.SpirvResourceTypeFlagsEXT_ALL,
        source = .HEAP_WITH_CONSTANT_OFFSET,
        
        sourceData = { constantOffset = { heapArrayStride = heap.resource_size } },
    }
    
    info.heap_mapping = vk.ShaderDescriptorSetAndBindingMappingInfoEXT { 
        sType = .SHADER_DESCRIPTOR_SET_AND_BINDING_MAPPING_INFO_EXT,
        mappingCount = 2,
        pMappings    = &info.mappings[0],
    }
    
    info.flags2 = vk.PipelineCreateFlags2CreateInfo {
        sType = .PIPELINE_CREATE_FLAGS_2_CREATE_INFO,
        flags = { .DESCRIPTOR_HEAP_EXT },
    }
    
    // Fill specialization constants
    for i in 0..<len(constants) {
        append(&info.specialization_entries, vk.SpecializationMapEntry {
            constantID = cast(u32) i, 
            offset     = cast(u32) i * size_of(u32), 
            size       = size_of(u32),
        })
    }
    
    info.specialization_info = vk.SpecializationInfo {
        mapEntryCount = cast(u32) len(info.specialization_entries),
        pMapEntries   = raw_data(&info.specialization_entries),
        dataSize      = cast(int) size_of_slice(constants),
        pData         = raw_data(constants),
    }
    
    // Shader creation
    for &shader in shaders {
        append(&info.module_infos, vk.ShaderModuleCreateInfo {
            sType = .SHADER_MODULE_CREATE_INFO, 
            pNext = &info.heap_mapping,
            
            codeSize = len(shader.bytes), 
            pCode    = cast(^u32) raw_data(shader.bytes),
        })
        
        append(&info.shader_stages, vk.PipelineShaderStageCreateInfo{ 
            sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, 
            pNext = last(&info.module_infos),
            
            stage = { shader.stage }, 
            pName = "main", 
            
            pSpecializationInfo = &info.specialization_info,
        })
    }
}

gpu_create_compute_pipeline :: proc (gpu: ^Gpu, compute: ^Shader, heap: Descriptor_Heap, constants: [] Specialization_Constant = nil) -> Pipeline {
    assert(compute.stage == .COMPUTE)
    
    pipeline_info: Pipeline_Info
    make_pipeline_info(&pipeline_info, gpu, heap, { compute }, constants)
    
    result: Pipeline
    result.bind_point = .COMPUTE
    create_info := vk.ComputePipelineCreateInfo {
        sType = .COMPUTE_PIPELINE_CREATE_INFO,
        
        pNext = &pipeline_info.flags2,
        stage = pipeline_info.shader_stages[0],
    }
    
    check(vk.CreateComputePipelines(gpu.device, gpu.pipeline_cache, 1, &create_info, nil, &result.pipeline))
    
    return result
}

gpu_create_graphics_pipeline :: proc (gpu: ^Gpu, vertex, fragment: ^Shader, info: Raster_Desc, heap: Descriptor_Heap, constants: [] Specialization_Constant = nil) -> Pipeline {
    assert(vertex.stage   == .VERTEX)
    assert(fragment.stage == .FRAGMENT)
    
    result: Pipeline
    gpu_create_graphics_pipeline_common(gpu, &result, info, heap, { vertex, fragment }, constants)
    
    return result
}

gpu_create_graphics_meshlet_pipeline :: proc { gpu_create_graphics_meshlet_pipeline_mesh, gpu_create_graphics_meshlet_pipeline_task }
gpu_create_graphics_meshlet_pipeline_task :: proc (gpu: ^Gpu, task, mesh, frag: ^Shader, info: Raster_Desc, heap: Descriptor_Heap, constants: [] Specialization_Constant = nil) -> Pipeline {
    assert(task.stage == .TASK_EXT)
    assert(mesh.stage == .MESH_EXT)
    assert(frag.stage == .FRAGMENT)
    
    result: Pipeline
    gpu_create_graphics_pipeline_common(gpu, &result, info, heap, { task, mesh, frag }, constants)
    
    return result
}

gpu_create_graphics_meshlet_pipeline_mesh :: proc (gpu: ^Gpu, mesh, frag: ^Shader, info: Raster_Desc, heap: Descriptor_Heap, constants: [] Specialization_Constant = nil) -> Pipeline {
    assert(mesh.stage == .MESH_EXT)
    assert(frag.stage == .FRAGMENT)
    
    result: Pipeline
    gpu_create_graphics_pipeline_common(gpu, &result, info, heap, { mesh, frag }, constants)
    
    return result
}

gpu_create_graphics_pipeline_common :: proc (gpu: ^Gpu, result: ^Pipeline, info: Raster_Desc, heap: Descriptor_Heap, shaders: [] ^Shader, constants: [] Specialization_Constant) {
    pipeline_info: Pipeline_Info
    make_pipeline_info(&pipeline_info, gpu, heap, shaders, constants)
    
    result.bind_point = .GRAPHICS
    
    // @incomplete expose all dynamic states that are core in 1.4, 
    // and remove their values below and from Raster_Desc if present.
    // DEPTH_BIAS, BLEND_CONSTANTS, DEPTH_BOUNDS, STENCIL_COMPARE_MASK, STENCIL_WRITE_MASK, STENCIL_REFERENCE
    dynamic_states := [] vk.DynamicState { .VIEWPORT, .SCISSOR, .LINE_WIDTH }
    
    color_formats: [dynamic; 32] Format
    for target in info.color_targets { append(&color_formats, target.format) }
    
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
            
            pNext = &pipeline_info.flags2,
            
            colorAttachmentCount    = cast(u32) len(color_formats),
            pColorAttachmentFormats = raw_data(&color_formats),
            depthAttachmentFormat   = info.depth_format,
            stencilAttachmentFormat = info.stencil_format,
        },
        
        stageCount = cast(u32) len(pipeline_info.shader_stages),
        pStages    = &pipeline_info.shader_stages[0],
        
        pInputAssemblyState = &vk.PipelineInputAssemblyStateCreateInfo {
            sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            topology = info.topology,
        },
        
        pVertexInputState = &vk.PipelineVertexInputStateCreateInfo {
            sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        },
        
        // @study can there be more than 1 with dynamic states?
        pViewportState = &vk.PipelineViewportStateCreateInfo {
            sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            viewportCount = 1,
            scissorCount  = 1,
        },
        
        pRasterizationState = &vk.PipelineRasterizationStateCreateInfo {
            sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            cullMode  = cull_mode,
            frontFace = .COUNTER_CLOCKWISE,
            
            // @todo which of these fields can by dynamic state?
            // depthClampEnable:        b32,
            // rasterizerDiscardEnable: b32,
            // polygonMode:             PolygonMode,
            // depthBiasEnable:         b32, -> ext dynamic state
            // depthBiasConstantFactor: f32,
            // depthBiasClamp:          f32,
            // depthBiasSlopeFactor:    f32,
        },
        
        // @incomplete
        pMultisampleState = &vk.PipelineMultisampleStateCreateInfo {
            sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            rasterizationSamples = { info.sample_count },
        },
        
        // @todo not exposed in info. can this be dynamic state?
        pDepthStencilState = &vk.PipelineDepthStencilStateCreateInfo {
            sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
            depthTestEnable  = true,
            depthWriteEnable = true,
            depthCompareOp   = .GREATER,
            // :Stencil: stencilTestEnable
        },
        
        pColorBlendState = &vk.PipelineColorBlendStateCreateInfo {
            sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            attachmentCount = cast(u32) len(color_attachments),
            pAttachments    = raw_data(&color_attachments),
            // @todo these field from the optional blend desc? can these be dynamic state?
            // logicOpEnable:   b32,     -> ext dynamic state
            // logicOp:         LogicOp, -> ext dynamic state
            // blendConstants:  [4]f32,  -> dynamic state
        },
        
        pDynamicState = &vk.PipelineDynamicStateCreateInfo {
            sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            dynamicStateCount = cast(u32) len(dynamic_states),
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

// @todo queue is ignored, we need to allocate from a pool created with the correct queue_family_index
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

Semaphore_Submit :: struct {
    sema:   vk.Semaphore,
    stages: vk.PipelineStageFlags2,
    signal_value: Maybe(u64),
}

gpu_submit :: proc (queue: vk.Queue, semaphores: [] Semaphore_Submit, cmds: ..vk.CommandBuffer) {
    for cmd in cmds {
        check(vk.EndCommandBuffer(cmd))
    }
    
    cmd_infos: [dynamic; 16] vk.CommandBufferSubmitInfo
    for cmd in cmds {
        append(&cmd_infos, vk.CommandBufferSubmitInfo {
            sType = .COMMAND_BUFFER_SUBMIT_INFO,
            commandBuffer = cmd,
        })
    }
    
    signals: [dynamic; 32] vk.SemaphoreSubmitInfo
    waits:   [dynamic; 32] vk.SemaphoreSubmitInfo
    for submit in semaphores {
        info := vk.SemaphoreSubmitInfo {
            sType = .SEMAPHORE_SUBMIT_INFO,
            semaphore = submit.sema,
            stageMask = submit.stages,
        }
        
        switch signal_value in submit.signal_value {
        case u64: 
            info.value = signal_value
            append(&signals, info)
        case:
            append(&waits, info)
        }
    }
    
    info := vk.SubmitInfo2 {
        sType = .SUBMIT_INFO_2,
        waitSemaphoreInfoCount = cast(u32) len(waits),
        pWaitSemaphoreInfos    = raw_data(&waits),
        signalSemaphoreInfoCount = cast(u32) len(signals),
        pSignalSemaphoreInfos    = raw_data(&signals),
        commandBufferInfoCount = cast(u32) len(cmds),
        pCommandBufferInfos    = &cmd_infos[0],
    }
    
    check(vk.QueueSubmit2(queue, 1, &info, 0))
}

gpu_present :: proc (gpu: ^Gpu, queue: vk.Queue, wait_semaphore: vk.Semaphore) {
    wait_semaphore := wait_semaphore
    present_info := vk.PresentInfoKHR {
        sType = .PRESENT_INFO_KHR,
        waitSemaphoreCount = 1,
        pWaitSemaphores    = &wait_semaphore,
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
// Semaphores

MaxTimeout :: max(u64)

gpu_create_semaphore :: proc (gpu: ^Gpu) -> vk.Semaphore {
    result: vk.Semaphore
    check(vk.CreateSemaphore(gpu.device, &{ sType = .SEMAPHORE_CREATE_INFO }, nil, &result))
    
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

gpu_copy :: proc (cmd: vk.CommandBuffer, destination: any, source: pmm) {
    unimplemented()
}

gpu_copy_to_texture :: proc (cmd: vk.CommandBuffer, destination: Image, source: vk.DeviceAddress, layout := vk.ImageLayout.GENERAL) {
    alloc := gpu_reflect_get_allocation(source)
    
    region := vk.BufferImageCopy {
        bufferOffset = alloc.offset,
        imageSubresource = { aspectMask = { .COLOR }, mipLevel = 0, layerCount = 1 },
        imageExtent      = { **destination.size },
    }
    
    vk.CmdCopyBufferToImage(cmd, alloc.buffer, destination.image, layout, 1, &region)
}

gpu_copy_from_texture :: proc (cmd: vk.CommandBuffer, destination: vk.DeviceAddress, source: Image, size: uv3, layout := vk.ImageLayout.GENERAL) {
    alloc := gpu_reflect_get_allocation(destination)
    
    region := vk.BufferImageCopy {
        bufferOffset = alloc.offset,
        imageSubresource = { aspectMask = { .COLOR }, mipLevel = 0, layerCount = 1 },
        imageExtent      = { **size },
    }
    
    vk.CmdCopyImageToBuffer(cmd, source.image, layout, alloc.buffer, 1, &region)
}

gpu_fill_memory :: proc { gpu_fill_memory_address, gpu_fill_memory_slice }
gpu_fill_memory_address :: proc (cmd: vk.CommandBuffer, destination: Gpu_Pointer($T), value: u32, size: vk.DeviceSize = size_of(T), offset: vk.DeviceSize = 0) {
    buffer, buffer_offset := gpu_reflect_get_buffer(destination.p)
    vk.CmdFillBuffer(cmd, buffer, buffer_offset + offset, size, value)
}
gpu_fill_memory_slice   :: proc (cmd: vk.CommandBuffer, destination: Gpu_Slice($T), #any_int count: vk.DeviceSize, value: u32) {
    buffer, offset := gpu_reflect_get_buffer(destination.gpu.p)
    size := size_of(T) * count
    vk.CmdFillBuffer(cmd, buffer, offset, size, value)
}

gpu_barrier :: proc (cmd: vk.CommandBuffer, before, after: vk.PipelineStageFlags2) {
    info := vk.DependencyInfo {
        sType = .DEPENDENCY_INFO,
        
        memoryBarrierCount = 1,
        pMemoryBarriers    = &vk.MemoryBarrier2 {
            sType = .MEMORY_BARRIER_2,
            
            srcStageMask = before,
            dstStageMask = after,
            
            srcAccessMask = { .MEMORY_READ, .MEMORY_WRITE },
            dstAccessMask = { .MEMORY_READ, .MEMORY_WRITE },
        },
    }
    
    vk.CmdPipelineBarrier2(cmd, &info)
}

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
    
    return result
}

create_image_barrier_from_undefined :: proc (image: ^Image, stage: vk.PipelineStageFlags2, access: vk.AccessFlags2, layout: vk.ImageLayout) -> vk.ImageMemoryBarrier2 {
    result := create_image_barrier(image, { .ALL_COMMANDS }, {}, .UNDEFINED, stage, access, layout)
    return result
}

gpu_image_barriers :: proc (cmd: vk.CommandBuffer, flags: vk.DependencyFlags, barriers: ..vk.ImageMemoryBarrier2) {
    vk.CmdPipelineBarrier2(cmd, &vk.DependencyInfo {
        sType = .DEPENDENCY_INFO,
        dependencyFlags          = flags, 
        imageMemoryBarrierCount  = cast(u32) len(barriers),
        pImageMemoryBarriers     = raw_data(barriers),
    })
}

// @todo
// void gpuSignalAfter(GpuCommandBuffer cb, STAGE before, void *ptrGpu, uint64 value, SIGNAL signal);
// void gpuWaitBefore(GpuCommandBuffer cb, STAGE after, void *ptrGpu, uint64 value, OP op, HAZARD_FLAGS hazards = 0, uint64 mask = ~0);

gpu_signal_after :: proc (cmd: vk.CommandBuffer, stage: vk.PipelineStageFlags2, gpu_pointer: pmm, count: u64, signal_op: any) {
    unimplemented()
}

gpu_wait_before :: proc (cmd: vk.CommandBuffer, stage: vk.PipelineStageFlags2, gpu_pointer: pmm, value: u64, wait_op: any) {
    unimplemented()
}

gpu_set_pipeline :: proc (cmd: vk.CommandBuffer, pipeline: Pipeline) {
    vk.CmdBindPipeline(cmd, pipeline.bind_point, pipeline.pipeline)
}

gpu_set_viewport :: proc (cmd: vk.CommandBuffer, offset: v2 = 0, size: v2, min_depth: f32 = 0, max_depth: f32 = 1) {
    vk.CmdSetViewport(cmd, 0, 1, &vk.Viewport { offset.x, offset.y, size.x, size.y, min_depth, max_depth })
}

gpu_set_scissor :: proc (cmd: vk.CommandBuffer, offset: iv2 = 0, size: uv2) {
    vk.CmdSetScissor(cmd, 0, 1, &vk.Rect2D { offset = { **offset }, extent = { **size } })
}

// @todo 
// void gpuSetDepthStencilState(GpuCommandBuffer cb, GpuDepthStencilState state);
// void gpuSetBlendState(GpuCommandBuffer cb, GpuBlendState state); 

gpu_begin_rendering :: proc (gpu: ^Gpu, cmd: vk.CommandBuffer, desc: Render_Pass_Desc) {
    render_size := gpu.swapchain_size
    
    color_attachments: [dynamic; 64] vk.RenderingAttachmentInfo
    for target in desc.color_targets {
        it := append_into(&color_attachments)
        it^ = {
            sType = .RENDERING_ATTACHMENT_INFO,
            
            imageLayout = .GENERAL,
            imageView   = target.view,
            loadOp  = target.load_op,
            storeOp = target.store_op,
        }
        it.clearValue.color.float32 = target.clear_color
    }
    
    rendering_info := vk.RenderingInfo {
        sType = .RENDERING_INFO, 
        
        renderArea = { extent = { **render_size } },
        layerCount = 1,
        
        colorAttachmentCount = cast(u32) len(color_attachments),
        pColorAttachments    = raw_data(&color_attachments),
    }
    
    if desc.depth_target.texture.image != 0 {
        rendering_info.pDepthAttachment = &vk.RenderingAttachmentInfo {
            sType = .RENDERING_ATTACHMENT_INFO,
            imageLayout = .GENERAL,
            imageView   = desc.depth_target.view,
            loadOp      = desc.depth_target.load_op,
            storeOp     = desc.depth_target.store_op,
            clearValue  = { depthStencil = { depth = desc.depth_target.clear_depth } },
        }
    }
    
    if desc.stencil_target.texture.image != 0 {
        rendering_info.pStencilAttachment = &vk.RenderingAttachmentInfo {
            sType = .RENDERING_ATTACHMENT_INFO,
            imageLayout = .GENERAL,
            imageView   = desc.stencil_target.view,
            loadOp      = desc.stencil_target.load_op,
            storeOp     = desc.stencil_target.store_op,
            clearValue  = { depthStencil = { stencil = desc.stencil_target.clear_stencil } },
        }
    }
    
    vk.CmdBeginRendering(cmd, &rendering_info)
}
gpu_end_rendering :: proc (cmd: vk.CommandBuffer) {
    vk.CmdEndRendering(cmd)
}

// void gpuDispatchIndirect(GpuCommandBuffer cb, void* dataGpu, void* gridDimensionsGpu);

// void gpuDrawIndexedInstanced(GpuCommandBuffer cb, void* vertexDataGpu, void* pixelDataGpu, void* indicesGpu, uint32 indexCount, uint32 instanceCount);
// void gpuDrawIndexedInstancedIndirectMulti(GpuCommandBuffer cb, void* dataVxGpu, uint32 vxStride, void* dataPxGpu, uint32 pxStride, void* argsGpu, void* drawCountGpu);

// void gpuDrawMeshlets(GpuCommandBuffer cb, void* meshletDataGpu, void* pixelDataGpu, uvec3 dim);

// @api we may want to allow the pipeline to have a push constant per stage. For that we need the shaders to each declare the push data to be N pointers to their respective data. Then the pipeline layout and this command both needs to declare the correct size of 3 pointers and their offsets in the push data.
gpu_push_constants :: proc (cmd: vk.CommandBuffer, frame_descriptor: ^Frame_Descriptor, push_constant: Gpu_Pointer($T), heap := false) {
    push_constant := push_constant
    info := vk.PushDataInfoEXT {
        sType = .PUSH_DATA_INFO_EXT,
        data  = { address = &push_constant.p, size = size_of(push_constant.p) },
    }
    vk.CmdPushDataEXT(cmd, &info)
}

gpu_dispatch :: proc (cmd: vk.CommandBuffer, frame_descriptor: ^Frame_Descriptor, push_constant: Gpu_Pointer($T), group_size: uv3) {
    gpu_push_constants(cmd, frame_descriptor, push_constant)
    
    vk.CmdDispatch(cmd, **group_size)
}

gpu_draw_indirect :: proc (cmd: vk.CommandBuffer, frame_descriptor: ^Frame_Descriptor, commands: Gpu_Pointer($C), push_constant: Gpu_Pointer($T)) {
    gpu_push_constants(cmd, frame_descriptor, push_constant)
    
    commands, commands_base_offset := gpu_reflect_get_buffer(commands.p)
    vk.CmdDrawIndirect(cmd, commands, commands_base_offset, 1, size_of(C))
}

gpu_draw_indexed_instanced_indirect :: proc (cmd: vk.CommandBuffer, frame_descriptor: ^Frame_Descriptor, draws: Gpu_Pointer($D), max_count: u32, push_constant: Gpu_Pointer($T)) {
    gpu_push_constants(cmd, frame_descriptor, push_constant)
    
    draws, draws_base_offset := gpu_reflect_get_buffer(draws.p)
    vk.CmdDrawIndexedIndirect(cmd, draws, draws_base_offset + cast(vk.DeviceSize) draw_offset, max_count, size_of(D))
}

// @speed The extension device_address_commands would remove the need to ever have a vk.Buffer for any command.
// But its not supported on my RTX 3070 ._.
gpu_draw_mesh_tasks_indirect :: proc (cmd: vk.CommandBuffer, frame_descriptor: ^Frame_Descriptor, group_count: Gpu_Pointer($C), draw_count: u32, push_constant: Gpu_Pointer($T), group_count_offset: umm = 0) {
    gpu_push_constants(cmd, frame_descriptor, push_constant)
    
    group_count, offset := gpu_reflect_get_buffer(group_count.p)
    vk.CmdDrawMeshTasksIndirectEXT(cmd, group_count, offset + cast(vk.DeviceSize) group_count_offset, draw_count, size_of(C))

}
gpu_draw_mesh_tasks_indirect_count :: proc (cmd: vk.CommandBuffer, frame_descriptor: ^Frame_Descriptor, commands: Gpu_Pointer($C), count: Gpu_Pointer(u32), max_count: u32, command_offset: umm, push_constant: Gpu_Pointer($T)) {
    gpu_push_constants(cmd, frame_descriptor, push_constant)
    
    commands, commands_base_offset := gpu_reflect_get_buffer(commands.p)
    count,    count_offset         := gpu_reflect_get_buffer(count.p)
    vk.CmdDrawMeshTasksIndirectCountEXT(cmd, commands, commands_base_offset + cast(vk.DeviceSize) command_offset, count, count_offset, max_count, size_of(C))
}



////////////////////////////////////////////////
// Descriptor Heap

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
    result.resources = gpu_allocate_slice(gpu, [] u8, resource_total_size, alignment = cast(umm) resource_alignment, usage = { .DESCRIPTOR_HEAP_EXT } )
    result.samplers  = gpu_allocate_slice(gpu, [] u8, sampler_total_size,  alignment = cast(umm) sampler_alignment,  usage = { .DESCRIPTOR_HEAP_EXT } )
    
    // @correctness we should respect the alignment, which may increase the total size
    result.resource_reserved_offset = resource_count * resource_size
    result.sampler_reserved_offset  = sampler_count  * sampler_size
    result.resource_reserved_size   = resource_reserved
    result.sampler_reserved_size    = sampler_reserved
    
    result.resource_size = cast(u32) resource_size
    result.sampler_size  = cast(u32) sampler_size
    
    // :SamplerHack: fill samplers[0] with texture sampler and samplers[2] with depth sampler
    descriptor_size := resource_size // :SamplerHack:
    write_descriptor(gpu, .LINEAR, .LINEAR,  .REPEAT,        .WEIGHTED_AVERAGE, result.samplers.cpu[0 * descriptor_size:][:sampler_size])
    write_descriptor(gpu, .LINEAR, .NEAREST, .CLAMP_TO_EDGE, .WEIGHTED_AVERAGE, result.samplers.cpu[1 * descriptor_size:][:sampler_size])
    write_descriptor(gpu, .LINEAR, .NEAREST, .CLAMP_TO_EDGE, .MIN,              result.samplers.cpu[2 * descriptor_size:][:sampler_size])
    
    return result
}

destroy_descriptor_heap :: proc (gpu: ^Gpu, heap: Descriptor_Heap) {
    gpu_free_pointer(gpu, heap.samplers.gpu.p)
    gpu_free_pointer(gpu, heap.resources.gpu.p)
}

gpu_set_active_heap :: proc (cmd: vk.CommandBuffer, heap: ^Descriptor_Heap) {
    byte_size :: proc (s: Gpu_Slice($T)) -> vk.DeviceSize {
        return cast(vk.DeviceSize) len(s.cpu) * size_of(T)
    }
    
    sampler_info := vk.BindHeapInfoEXT {
        sType = .BIND_HEAP_INFO_EXT,
        heapRange = {
            address = heap.samplers.gpu.p,
            size    = byte_size(heap.samplers),
        },
        reservedRangeOffset = heap.sampler_reserved_offset,
        reservedRangeSize   = heap.sampler_reserved_size,
    }
    
    resource_info := vk.BindHeapInfoEXT {
        sType = .BIND_HEAP_INFO_EXT,
        heapRange = { 
            address = heap.resources.gpu.p,
            size    = byte_size(heap.resources),
        },
        reservedRangeOffset = heap.resource_reserved_offset,
        reservedRangeSize   = heap.resource_reserved_size,
    }
    
    vk.CmdBindSamplerHeapEXT(cmd,  &sampler_info)
    vk.CmdBindResourceHeapEXT(cmd, &resource_info)
}

write_texture_to_heap :: proc (gpu: ^Gpu, heap: ^Descriptor_Heap, index: Texture_Index, image: Image, image_type: vk.DescriptorType, mip_base: u32 = 0, mip_count: u32 = vk.REMAINING_MIP_LEVELS) {
    descriptor_size := heap.resource_size
    descriptor_slot := heap.resources.cpu[cast(u32) index * descriptor_size:][:descriptor_size]
    write_descriptor(gpu, image.image, image.format, mip_base, mip_count, image_type, descriptor_slot)
}

write_descriptor :: proc { write_descriptor_image, write_descriptor_buffer, write_descriptor_sampler }
write_descriptor_image :: proc (gpu: ^Gpu, image: vk.Image, format: vk.Format, mip_base: u32, mip_count: u32, type: vk.DescriptorType, descriptor_heap_slot: [] u8) {
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
        layout = .GENERAL,
    }
    
    info := vk.ResourceDescriptorInfoEXT {
        sType = .RESOURCE_DESCRIPTOR_INFO_EXT,
        type = type,
        data = { pImage = &image_info },
    }
    
    range := vk.HostAddressRangeEXT { address = raw_data(descriptor_heap_slot), size = len(descriptor_heap_slot) }
    check(vk.WriteResourceDescriptorsEXT(gpu.device, 1, &info, &range))
}

write_descriptor_buffer :: proc (gpu: ^Gpu, address: vk.DeviceAddress, size: vk.DeviceSize, type: vk.DescriptorType, descriptor_heap_slot: [] u8) {
    buffer_info := vk.DeviceAddressRangeEXT { address = address, size = size }
    
    info := vk.ResourceDescriptorInfoEXT {
        sType = .RESOURCE_DESCRIPTOR_INFO_EXT,
        type = type,
        data = { pAddressRange =  &buffer_info },
    }
    
    range := vk.HostAddressRangeEXT { address = raw_data(descriptor_heap_slot), size = len(descriptor_heap_slot) }
    check(vk.WriteResourceDescriptorsEXT(gpu.device, 1, &info, &range))
}

write_descriptor_sampler :: proc (gpu: ^Gpu, filter: vk.Filter, mipmap_mode: vk.SamplerMipmapMode, address_mode: vk.SamplerAddressMode, reduction_mode: vk.SamplerReductionMode, descriptor_heap_slot: [] u8, anisotropy: b32 = false) {
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
    
    range := vk.HostAddressRangeEXT { address = raw_data(descriptor_heap_slot), size = len(descriptor_heap_slot) }
    check(vk.WriteSamplerDescriptorsEXT(gpu.device, 1, &info, &range))
}

////////////////////////////////////////////////

create_query_pool :: proc (gpu: ^Gpu, query_count: u32, type: vk.QueryType, stats_bits := vk.QueryPipelineStatisticFlags {}) -> vk.QueryPool {
    create_info := vk.QueryPoolCreateInfo {
        sType = .QUERY_POOL_CREATE_INFO,
        queryType  = type,
        queryCount = query_count,
    }
    
    if type == .PIPELINE_STATISTICS {
        create_info.pipelineStatistics = stats_bits
    }
    
    result: vk.QueryPool
    check(vk.CreateQueryPool(gpu.device, &create_info, nil, &result))
    
    return result
}