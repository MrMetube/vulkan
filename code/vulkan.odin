#+vet explicit-allocators
package main

import "base:runtime"
import "core:fmt"
import "core:time"

import vk "vendor:vulkan"
import sdl "vendor:sdl3"

// @naming
IPS :: struct {
    instance:          vk.Instance,
    physical_device:   vk.PhysicalDevice,
    surface:           vk.SurfaceKHR,
    device_properties: vk.PhysicalDeviceProperties2,
}

Swapchain :: struct {
    swapchain: vk.SwapchainKHR,
    images:           [dynamic] vk.Image,
    render_completes: [dynamic] vk.Semaphore,
    
    size:   uv2,
    format: vk.Format, // @cleanup this is redundant with the color buffer's format
    
    color_buffer: Image,
    depth_buffer: Image,
}

Pipeline :: struct {
    pipeline: vk.Pipeline,
    layout:   vk.PipelineLayout,
    update_template: vk.DescriptorUpdateTemplate,
    // only used by the graphics pipeline
    shader_stages: vk.ShaderStageFlags,
}

Shader :: struct {
    input:  string, 
    
    stage: vk.ShaderStageFlag,
    bytes:  [] u8,
    
    // @todo(viktor): these are unused right now, but should be used in pipeline creation and usage to make it less volatile
    resource_mask:      bit_set[cast(u32) 0..<32],
    resource_types:     [32] vk.DescriptorType,
    use_push_constants: bool,
    local_size:         [3] u32,
    
    source_watcher: Watcher_Id,
    common_watcher: Watcher_Id,
}

Image :: struct {
    format: vk.Format,
    image:  vk.Image,
    view:   vk.ImageView,
    memory: vk.DeviceMemory,
    
	sampler: vk.Sampler,
    
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

create_instance_physical_device_and_surface :: proc (window: ^sdl.Window, get_instance_proc: pmm) -> IPS {
    vk.GetInstanceProcAddr = auto_cast get_instance_proc
    vk.load_proc_addresses_global(auto_cast vk.GetInstanceProcAddr)
    
    ips: IPS
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
                }
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

create_device_queue_frames_and_command_pool_and_init_gpu_allocator :: proc (ips: IPS) -> (vk.Device, vk.Queue, [] Frame, vk.CommandPool) {
    device: vk.Device
    queue_family_index: u32
    
    queue_family_priority := [] f32 { 1 }
    
    device_extensions := [] cstring { 
        vk.KHR_SWAPCHAIN_EXTENSION_NAME,
        vk.EXT_MESH_SHADER_EXTENSION_NAME,
        vk.KHR_DRAW_INDIRECT_COUNT_EXTENSION_NAME,
    }
    
    device_create_info := vk.DeviceCreateInfo {
        sType = .DEVICE_CREATE_INFO,
        
        pNext = &vk.PhysicalDeviceFeatures2 {
            sType = .PHYSICAL_DEVICE_FEATURES_2,
            
            // @correctness These are technically optional device features, and should be queried for availablity before using them.
            features = { 
                multiDrawIndirect = true, // supported on NVidia since the GTX 1080
                samplerAnisotropy = true, // required since 1.4
                shaderInt16       = true, // required since 1.4
                shaderInt64       = true,
            },
        
        // These features are guaranteed to be supported, if the device suppports vulkan 1.4
        pNext = &vk.PhysicalDeviceVulkan14Features {
            sType = .PHYSICAL_DEVICE_VULKAN_1_4_FEATURES,
            
            maintenance5   = true, // deprecates ShaderModule
            pushDescriptor = true, // remove the need for CmdBindVertexBuffers
            dynamicRenderingLocalRead = true, // allows rendering to an image and then copying into the swapchain image, whilst using dynamic_rendering
            
        pNext = &vk.PhysicalDeviceVulkan13Features {
            sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
            
            synchronization2 = true,
            dynamicRendering = true, // remove the need for RenderPass and FrameBuffer objects
            maintenance4     = true, // needed to use layout(local_size...)
            
        pNext = &vk.PhysicalDeviceVulkan12Features {
            sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
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
            
        pNext = &vk.PhysicalDeviceVulkan11Features {
            sType = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
            
            storageBuffer16BitAccess           = true,
            uniformAndStorageBuffer16BitAccess = true,
            shaderDrawParameters               = true,
        
        // @correctness These features are still extensions, and we should query their availability.
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
    
    frames := make([] Frame, MaxFramesInFlight, context.allocator)
    
    // @waste there are a lot of buffers here, each of which is very small
    for &frame in frames {
        frame.draw_globals.gpu, frame.draw_globals.cpu = gpu_make_buffer_type(Draw_Globals, { .SHADER_DEVICE_ADDRESS })
        frame.cull_globals.gpu, frame.cull_globals.cpu = gpu_make_buffer_type(Cull_Globals, { .SHADER_DEVICE_ADDRESS })
        
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
        
        command_buffers := make([] vk.CommandBuffer, len(frames), context.temp_allocator)
        check(vk.AllocateCommandBuffers(device, &command_buffer_allocate_info, &command_buffers[0]))
        
        for &frame, i in frames {
            frame.command_buffer = command_buffers[i]
        }
        
        defer_destroy(vk.DestroyCommandPool, command_pool)
    }
    
    return device, queue, frames, command_pool
}

////////////////////////////////////////////////

get_swapchain_format :: proc (ips: IPS) -> vk.Format {
    format_count: u32
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
    
    // The stencil bits are currently wasted/unused, so we could also just select D32_SFLOAT and save that memory.
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
    
    // @waste semaphores only need to be deleted and recreated, if the image_count changes up or down respectively
    if old_swapchain.swapchain != 0 {
        destroy_swapchain(device, old_swapchain)
    }
    
    image_count: u32
    check(vk.GetSwapchainImagesKHR(device, result.swapchain, &image_count, nil))
    resize(&result.images, image_count)
    resize(&result.render_completes, image_count)
    check(vk.GetSwapchainImagesKHR(device, result.swapchain, &image_count, &result.images[0]))
    
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
    // the images are allocated for us, so we can just drop the handles
    clear(&swapchain.images)
    
    gpu_delete(swapchain.depth_buffer)
    gpu_delete(swapchain.color_buffer)
    
    vk.DestroySwapchainKHR(device, swapchain.swapchain, nil)
}

////////////////////////////////////////////////

@(thread_local)
barrier_state: struct {
    is_open:  bool,
    image_barriers:  [dynamic] vk.ImageMemoryBarrier2,
    buffer_barriers: [dynamic] vk.BufferMemoryBarrier2,
}

begin_pipeline_barrier :: proc () {
    assert(!barrier_state.is_open)
    
    barrier_state.is_open = true
}

add_image_barrier :: proc { add_image_barrier_vk, add_image_barrier_image }
add_image_barrier_image :: proc (image: ^Image, src_stage: vk.PipelineStageFlags2, src_access: vk.AccessFlags2, old_layout: vk.ImageLayout, dst_stage: vk.PipelineStageFlags2, dst_access: vk.AccessFlags2, new_layout: vk.ImageLayout, aspect_mask := vk.ImageAspectFlags { .COLOR }) {
    add_image_barrier(image.image, src_stage, src_access, old_layout, dst_stage, dst_access, new_layout, aspect_mask)
    image.last_transition = { dst_stage, dst_access, new_layout }
}
add_image_barrier_vk :: proc (image: vk.Image, src_stage: vk.PipelineStageFlags2, src_access: vk.AccessFlags2, old_layout: vk.ImageLayout, dst_stage: vk.PipelineStageFlags2, dst_access: vk.AccessFlags2, new_layout: vk.ImageLayout, aspect_mask := vk.ImageAspectFlags { .COLOR }) {
    assert(barrier_state.is_open)
    
    append(&barrier_state.image_barriers, vk.ImageMemoryBarrier2 {
        sType = .IMAGE_MEMORY_BARRIER_2,
        srcAccessMask = src_access,
        dstAccessMask = dst_access,
        srcStageMask  = src_stage,
        dstStageMask  = dst_stage,
        oldLayout = old_layout,
        newLayout = new_layout,
        image = image,
        subresourceRange = { aspectMask = aspect_mask, levelCount = vk.REMAINING_MIP_LEVELS, layerCount = vk.REMAINING_ARRAY_LAYERS },
    })
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

end_pipeline_barrier :: proc (command_buffer: vk.CommandBuffer) {
    assert(barrier_state.is_open)
    
    vk.CmdPipelineBarrier2(command_buffer, &vk.DependencyInfo {
        sType = .DEPENDENCY_INFO,
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

pipeline_is_valid :: proc (pipeline: Pipeline) -> bool {
    result := pipeline.pipeline != 0
    return result
}

create_pipeline_layout :: proc (device: vk.Device, stage_flags: vk.ShaderStageFlags, set_layouts: ..vk.DescriptorSetLayout, with_push_data_which_is_an_address := false) -> vk.PipelineLayout {
    info := vk.PipelineLayoutCreateInfo { sType = .PIPELINE_LAYOUT_CREATE_INFO }
    
    if len(set_layouts) > 0 {
        info.setLayoutCount = cast(u32) len(set_layouts)
        info.pSetLayouts    = &set_layouts[0]
    }
    
    if with_push_data_which_is_an_address {
        info.pushConstantRangeCount = 1
        info.pPushConstantRanges = &vk.PushConstantRange {
            stageFlags = stage_flags,
            size       = size_of(vk.DeviceAddress),
        }
    }
    
    result: vk.PipelineLayout
    check(vk.CreatePipelineLayout(device, &info, nil, &result))
    
    return result
}

create_compute_pipeline :: proc (device: vk.Device, cache: vk.PipelineCache, shader: Shader, storage_buffer_count: u32, set_layout: vk.DescriptorSetLayout, old: Pipeline = {}) -> Pipeline {
    if pipeline_is_valid(old) {
        check(vk.DeviceWaitIdle(device))
        destroy_pipeline(device, old)
    }
    
    assert(shader.stage == .COMPUTE)
    
    result: Pipeline
    result.shader_stages += { shader.stage }
    
    result.layout = create_pipeline_layout(device, result.shader_stages, set_layout, with_push_data_which_is_an_address = true)
    
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
    
    check(vk.CreateComputePipelines(device, cache, 1, &create_info, nil, &result.pipeline))
    
    if storage_buffer_count != 0 {
        result.update_template = create_update_template(device, .COMPUTE, result.layout, storage_buffer_count)
    }
    
    return result
}

create_graphics_pipeline :: proc (device: vk.Device, cache: vk.PipelineCache, swapchain: Swapchain, set_layouts: [] vk.DescriptorSetLayout, shaders: [] Shader, storage_buffer_count: u32, old: Pipeline = {}) -> Pipeline {
    if pipeline_is_valid(old) {
        check(vk.DeviceWaitIdle(device))
        destroy_pipeline(device, old)
    }
    
    result: Pipeline
    for shader in shaders {
        result.shader_stages += { shader.stage }
    }
    
    result.layout = create_pipeline_layout(device, result.shader_stages, ..set_layouts, with_push_data_which_is_an_address = true)
    
    shader_stages: [dynamic; 16] vk.PipelineShaderStageCreateInfo
    module_infos:  [dynamic; 16] vk.ShaderModuleCreateInfo
    for shader in shaders {
        append(&module_infos, vk.ShaderModuleCreateInfo {
            sType    = .SHADER_MODULE_CREATE_INFO,
            codeSize = len(shader.bytes),
            pCode    = cast(^u32) &shader.bytes[0],
        })
        append(&shader_stages, vk.PipelineShaderStageCreateInfo { 
            sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, 
            stage = { shader.stage }, 
            pName = "main", 
            pNext = last(&module_infos),
        })
    }
    
    dynamic_states := [] vk.DynamicState { .VIEWPORT, .SCISSOR }
    
    swapchain_format := swapchain.format
    
    create_info := vk.GraphicsPipelineCreateInfo {
        sType = .GRAPHICS_PIPELINE_CREATE_INFO,
        pNext = &vk.PipelineRenderingCreateInfo {
            sType = .PIPELINE_RENDERING_CREATE_INFO,
            colorAttachmentCount    = 1,
            pColorAttachmentFormats = &swapchain_format,
            depthAttachmentFormat   = swapchain.depth_buffer.format,
            stencilAttachmentFormat = .UNDEFINED,
        },
        stageCount = auto_cast len(shader_stages),
        pStages    = &shader_stages[0],
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
            cullMode  = { .BACK },
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
    
    check(vk.CreateGraphicsPipelines(device, cache, 1,&create_info, nil, &result.pipeline))
    
    if storage_buffer_count != 0 {
        result.update_template = create_update_template(device, .GRAPHICS, result.layout, storage_buffer_count)
    }
    
    return result
}

create_update_template :: proc (device: vk.Device, bind_point: vk. PipelineBindPoint, layout: vk.PipelineLayout, storage_buffer_count: u32) -> vk.DescriptorUpdateTemplate {
    assert(storage_buffer_count != 0)
    
    // @todo(viktor): The information of which shader stage needs which storage buffer could be parsed from the compiled spirv file.
    update_template_entries: [dynamic; 32] vk.DescriptorUpdateTemplateEntry
    for index in 0..<storage_buffer_count {
        append(&update_template_entries, vk.DescriptorUpdateTemplateEntry {
            dstBinding      = index,
            descriptorType  = .STORAGE_BUFFER,
            descriptorCount = 1,
            offset          = cast(int) index * size_of(DescriptorUpdateData),
            stride          = size_of(DescriptorUpdateData),
        })
    }
        
    update_template_create_info := vk.DescriptorUpdateTemplateCreateInfo {
        sType = .DESCRIPTOR_UPDATE_TEMPLATE_CREATE_INFO,
        pipelineBindPoint   = bind_point,
        pipelineLayout      = layout,
        templateType        = .PUSH_DESCRIPTORS,
        descriptorUpdateEntryCount = cast(u32) len(update_template_entries),
        pDescriptorUpdateEntries   = &update_template_entries[0],
    }
    
    result: vk.DescriptorUpdateTemplate
    check(vk.CreateDescriptorUpdateTemplate(device, &update_template_create_info, nil, &result))
    
    return result
}

destroy_pipeline :: proc (device: vk.Device, pipeline: Pipeline) {
    if pipeline.layout != 0 {
        vk.DestroyPipelineLayout(device, pipeline.layout, nil)
    }
    
    if pipeline.pipeline != 0 {
        vk.DestroyPipeline(device, pipeline.pipeline, nil)
    }
    
    vk.DestroyDescriptorUpdateTemplate(device, pipeline.update_template, nil)
    
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

queue_submit :: proc (queue: vk.Queue, swapchain: Swapchain, frame: Frame, image_index: u32, signal_value: u64, timeline_semaphore: vk.Semaphore) {
    render_complete_and_timeline_submit_info := [] vk.SemaphoreSubmitInfo {
        {
            sType = .SEMAPHORE_SUBMIT_INFO,
            semaphore = swapchain.render_completes[image_index],
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
gpu_make_buffer_slice :: proc ($S: typeid / [] $E, #any_int len: umm, usage: vk.BufferUsageFlags) -> (Buffer, S) {
    size   := size_of(E) * len
    buffer, pointer := gpu_make_buffer_size(size, usage)
    view   := slice_from_parts(E, pointer, len)
    return buffer, view
}
gpu_make_buffer_type :: proc ($S: typeid, usage: vk.BufferUsageFlags) -> (Buffer, ^S) {
    size   := size_of(S)
    buffer, pointer := gpu_make_buffer_size(size, usage)
    data := cast(^S) pointer
    return buffer, data
}
gpu_make_buffer_size :: proc (#any_int size: vk.DeviceSize, usage: vk.BufferUsageFlags) -> (Buffer, pmm) {
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
    
    uses_address := .SHADER_DEVICE_ADDRESS in usage
    
    result.memory = select_memory_type_and_allocate(requirements, flags, add_device_address_flag = uses_address)
    
    check(vk.BindBufferMemory(device, result.buffer, result.memory, 0))
    
    pointer: pmm
    vk.MapMemory(device, result.memory, 0, size, {}, &pointer)
    
    if uses_address {
        adress_create_info := vk.BufferDeviceAddressInfo {
            sType = .BUFFER_DEVICE_ADDRESS_INFO,
            buffer = result.buffer,
        }
        
        result.address = vk.GetBufferDeviceAddress(device, &adress_create_info)
        
        assert(result.address != 0)
    }
    
    return result, pointer
}

gpu_make_image :: proc (size: uv2, format: vk.Format, usage: vk.ImageUsageFlags, aspect_mask: vk.ImageAspectFlags, flags := vk.MemoryPropertyFlags { .DEVICE_LOCAL }, mip_levels : u32 = 1) -> Image {
    assert(gpu_allocator_state.initialized)
    
    device := gpu_allocator_state.device
    
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
    check(vk.CreateImage(device, &create_info, nil, &result.image))
    
    requirements: vk.MemoryRequirements
    vk.GetImageMemoryRequirements(device, result.image, &requirements)
    
    result.memory = select_memory_type_and_allocate(requirements, flags)
    
    check(vk.BindImageMemory(device, result.image, result.memory, 0))
    
    view_create_info := vk.ImageViewCreateInfo {
        sType = .IMAGE_VIEW_CREATE_INFO,
        image    = result.image,
        viewType = .D2,
        format   = format,
        subresourceRange = { aspectMask = aspect_mask, levelCount = mip_levels, layerCount = 1 },
    }
    check(vk.CreateImageView(device, &view_create_info, nil, &result.view))
    
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
    check(vk.AllocateMemory(device, &allocate_info, nil, &memory))
    
    return memory
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
gpu_delete :: proc { gpu_delete_buffer, gpu_delete_image }
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

gpu_profile_collate_times :: proc (ips: IPS, device: vk.Device, print: bool) {
    assert(gpu_profiler.pool != 0)
    assert(len(gpu_profiler.open_zones) == 0)
    
    query_results: [QueryPoolSize] u64
    
    query_count := cast(u32) len(gpu_profiler.queries)
    query_result := vk.GetQueryPoolResults(device, gpu_profiler.pool, 0, query_count, cast(int) size_of_slice(query_results[:query_count]), &query_results[0], size_of(query_results[0]), { ._64, .WAIT })
    
    if query_result == .NOT_READY || query_result == .ERROR_DEVICE_LOST { return }
    
    check(query_result)
    
    for query, query_index in gpu_profiler.queries {
        timestamp := cast(f64) query_results[query_index] * cast(f64) ips.device_properties.properties.limits.timestampPeriod * 1e-9
        
        zone := &gpu_profiler.zones[query.zone_index]
        
        switch query.kind {
        case .Begin:
            zone.total_time               -= timestamp
            zone.total_time_with_children -= timestamp
            
            for link := zone.parent_zone; link != -1; {
                parent := &gpu_profiler.zones[link]
                parent.total_time               += timestamp
                parent.total_time_with_children -= timestamp
                
                link = parent.parent_zone
            }
            
        case .End:
            zone.total_time               += timestamp
            zone.total_time_with_children += timestamp
            
            for link := zone.parent_zone; link != -1; {
                parent := &gpu_profiler.zones[link]
                parent.total_time               -= timestamp
                parent.total_time_with_children += timestamp
                
                link = parent.parent_zone
            }
        }
    }
    
    if print {
        fmt.printfln("---------------------\nGPU profile:")
        for zone in gpu_profiler.zones {
            xx :: proc (seconds: f64) -> time.Duration { return cast(time.Duration) (seconds * cast(f64) time.Second) }
            
            fmt.printf("  %12v: %v", zone.label, xx(zone.total_time))
            if zone.total_time_with_children != zone.total_time {
                fmt.printf(" (with children %v)", xx(zone.total_time_with_children))
            }
            fmt.printfln("")
        }
    }
}

gpu_profile_get_zone :: proc (label: string) -> (Profile_Zone, bool) #optional_ok {
    // @speed
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

peek :: proc (s: [] $T) -> (T, bool) {
    result: T
    ok: bool
    if len(s) > 0 {
        result = s[len(s)-1]
        ok = true
    }
    return result, ok
}

////////////////////////////////////////////////

MaxTimeout :: max(u64)

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
