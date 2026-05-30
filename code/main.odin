package main

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:mem"
import "core:strconv"
import "../libs/vma"
import "../libs/tobj"
import "../libs/ktx"
import "../libs/slang/slang"

import sdl "vendor:sdl2"
import vk "vendor:vulkan"

main :: proc () {
    check_sdl(sdl.Init(sdl.INIT_VIDEO) == 0)
    defer sdl.Quit()
    
    window := sdl.CreateWindow("How to Vulkan", sdl.WINDOWPOS_UNDEFINED, sdl.WINDOWPOS_UNDEFINED, 1280, 720, sdl.WINDOW_VULKAN | sdl.WINDOW_RESIZABLE)
    check_sdl(window != nil)
    defer sdl.DestroyWindow(window)
    
    vk.GetInstanceProcAddr = auto_cast sdl.Vulkan_GetVkGetInstanceProcAddr()
    vk.load_proc_addresses_global(auto_cast vk.GetInstanceProcAddr)
    
    ////////////////////////////////////////////////
    
    instance: vk.Instance
    {
        app_info := vk.ApplicationInfo {
            sType = .APPLICATION_INFO,
            pApplicationName = "How to Vulkan",
            apiVersion = vk.API_VERSION_1_3,
        }
        
        instance_extension_count: u32
        sdl.Vulkan_GetInstanceExtensions(window, &instance_extension_count, nil)
        instance_extensions := make([]cstring, instance_extension_count)
        sdl.Vulkan_GetInstanceExtensions(window, &instance_extension_count, raw_data(instance_extensions))
        when false {
            instance_extensions := sdl.Vulkan_GetInstanceExtensions(&instance_extension_count)
        }
        
        instance_create_info := vk.InstanceCreateInfo {
            sType = .INSTANCE_CREATE_INFO,
            pApplicationInfo = &app_info,
            enabledExtensionCount = instance_extension_count,
            ppEnabledExtensionNames = raw_data(instance_extensions),
        }
        
        check(vk.CreateInstance(&instance_create_info, nil, &instance))
        
        vk.load_proc_addresses_instance(instance)
    }
    
    ////////////////////////////////////////////////
    
    physical_device: vk.PhysicalDevice
    {
        devices: [] vk.PhysicalDevice
        {
            device_count: u32
            check(vk.EnumeratePhysicalDevices(instance, &device_count, nil))
            devices = make([] vk.PhysicalDevice, device_count)
            check(vk.EnumeratePhysicalDevices(instance, &device_count, raw_data(devices)))
        }
        
        device_index: u32
        if len(os.args) > 1 {
            device_index = cast(u32) (strconv.parse_u64(os.args[1]) or_else 0)
            assert(device_index < auto_cast len(devices))
        }
        
        physical_device = devices[device_index]
        
        {
            device_properties := vk.PhysicalDeviceProperties2 { sType = .PHYSICAL_DEVICE_PROPERTIES_2 }
            vk.GetPhysicalDeviceProperties2(physical_device, &device_properties)
            fmt.printfln("Selected device: %v", cast(cstring) &device_properties.properties.deviceName[0])
        }
    }
    
    ////////////////////////////////////////////////
    
    device: vk.Device
    queue_family_index: u32
    {
        queue_family_count: u32
        vk.GetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, nil)
        queue_family_properties := make([] vk.QueueFamilyProperties, queue_family_count)
        vk.GetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, raw_data(queue_family_properties))
        
        for props, index in queue_family_properties {
            if .GRAPHICS in props.queueFlags {
                queue_family_index = auto_cast index
            }
        }
        
        when false {
            check(sdl.Vulkan_GetPresentationSupport(instance, physical_device, queue_family_index))
        }
        
        queue_family_priority := [] f32 { 1 }
        queue_create_info := vk.DeviceQueueCreateInfo {
            sType = .DEVICE_QUEUE_CREATE_INFO,
            queueFamilyIndex = queue_family_index,
            queueCount = auto_cast len(queue_family_priority),
            pQueuePriorities = raw_data(queue_family_priority),
        }
        
        device_extensions := [] cstring { vk.KHR_SWAPCHAIN_EXTENSION_NAME }
        
        enabled_vk12_features := vk.PhysicalDeviceVulkan12Features {
            sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
            descriptorIndexing                        = true,
            shaderSampledImageArrayNonUniformIndexing = true,
            descriptorBindingVariableDescriptorCount  = true,
            runtimeDescriptorArray                    = true,
            bufferDeviceAddress                       = true,
        }
        enabled_vk13_features := vk.PhysicalDeviceVulkan13Features {
            sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
            pNext = &enabled_vk12_features,
            synchronization2 = true,
            dynamicRendering = true,
        }
        enabled_vk10_features := vk.PhysicalDeviceFeatures {
            samplerAnisotropy = true,
        }
        
        device_create_info := vk.DeviceCreateInfo {
            sType = .DEVICE_CREATE_INFO,
            
            pEnabledFeatures = &enabled_vk10_features,
            pNext            = &enabled_vk13_features,
            
            queueCreateInfoCount = 1,
            pQueueCreateInfos    = &queue_create_info,
            
            enabledExtensionCount   = auto_cast len(device_extensions),
            ppEnabledExtensionNames = raw_data(device_extensions),
        }
        
        check(vk.CreateDevice(physical_device, &device_create_info, nil, &device))
        
        vk.load_proc_addresses_device(device)
    }
    
    queue: vk.Queue
    vk.GetDeviceQueue(device, queue_family_index, 0, &queue)
    
    ////////////////////////////////////////////////
    
    surface: vk.SurfaceKHR
    check(sdl.Vulkan_CreateSurface(window, instance, &surface))
    
    window_size: iv2
    sdl.GetWindowSize(window, &window_size.x, &window_size.y)
    
    ////////////////////////////////////////////////
    
    swapchain: vk.SwapchainKHR
    {
        surface_capabilities: vk.SurfaceCapabilitiesKHR
        check(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface, &surface_capabilities))
        
        swapchain_extent := surface_capabilities.currentExtent
        if surface_capabilities.currentExtent.width == 0xFFFFFFFF {
            swapchain_extent = { width = cast(u32) window_size.x, height = cast(u32) window_size.y }
        }
        
        image_format := vk.Format.B8G8R8A8_SRGB
        swapchain_create_info := vk.SwapchainCreateInfoKHR {
            sType = .SWAPCHAIN_CREATE_INFO_KHR,
            surface          = surface,
            minImageCount    = surface_capabilities.minImageCount,
            imageFormat      = image_format,
            imageColorSpace  = .SRGB_NONLINEAR,
            imageExtent      = swapchain_extent,
            imageArrayLayers = 1,
            imageUsage       = { .COLOR_ATTACHMENT },
            preTransform     = { .IDENTITY },
            compositeAlpha   = { .OPAQUE },
            presentMode      = .FIFO,
        }
        check(vk.CreateSwapchainKHR(device, &swapchain_create_info, nil, &swapchain))
    }
    
    swapchain_images: [] vk.Image
    swapchain_image_views: [] vk.ImageView
    {
        image_count: u32
        check(vk.GetSwapchainImagesKHR(device, swapchain, &image_count, nil))
        swapchain_images = make([] vk.Image, image_count)
        check(vk.GetSwapchainImagesKHR(device, swapchain, &image_count, raw_data(swapchain_images)))
        swapchain_image_views = make([] vk.ImageView, image_count)
    }
    
    ////////////////////////////////////////////////
    
    allocator: vma.Allocator
    {
        vma_vulkan_functions := vma.create_vulkan_functions()
        
        allocator_create_info := vma.Allocator_Create_Info {
            flags            = {.Buffer_Device_Address},
            instance         = instance,
            physical_device  = physical_device,
            device           = device,
            vulkan_functions = &vma_vulkan_functions,
        }
        check(vma.create_allocator(allocator_create_info, &allocator))
    }
    
    ////////////////////////////////////////////////
    
    depth_format: vk.Format
    depth_format_list := [] vk.Format { .D32_SFLOAT_S8_UINT, .D24_UNORM_S8_UINT }
    for it in depth_format_list {
        format_properties := vk.FormatProperties2 { sType = .FORMAT_PROPERTIES_2 }
        vk.GetPhysicalDeviceFormatProperties2(physical_device, it, &format_properties)
        if .DEPTH_STENCIL_ATTACHMENT in format_properties.formatProperties.optimalTilingFeatures {
            depth_format = it
            break
        }
    }
    
    depth_image_create_info := vk.ImageCreateInfo {
        sType = .IMAGE_CREATE_INFO,
        imageType = .D2,
        format = depth_format,
        extent = { width = cast(u32) window_size.x, height = cast(u32) window_size.y, depth = 1 },
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
    
    depth_image: vk.Image
    depth_image_allocation: vma.Allocation
    check(vma.create_image(allocator, depth_image_create_info, alloc_create_info, &depth_image, &depth_image_allocation, nil))
    
    depth_image_view: vk.ImageView
    depth_image_view_create_info := vk.ImageViewCreateInfo {
        sType = .IMAGE_VIEW_CREATE_INFO,
        image = depth_image,
        viewType = .D2,
        format = depth_format,
        subresourceRange = { aspectMask = { .DEPTH }, levelCount = 1, layerCount = 1 },
    }
    check(vk.CreateImageView(device, &depth_image_view_create_info, nil, &depth_image_view))
    
    ////////////////////////////////////////////////
    
    models, materials, error := tobj.load_obj_filename("./tutorial/suzanne.obj", allocator = context.temp_allocator)
    assert(error == nil)
    model := models[0].mesh
    
    vertices := make([] Vertex, len(model.indices))
    indices  := make([] i32,  len(vertices))
    
    for index, it_index in model.indices {
        v := Vertex {
            p = model.vertices[index]        * { 1, -1, 1 },
            n = model.normals[index]         * { 1, -1, 1 },
            uv = model.texture_coords[index] * { 1, -1 },
        }
        
        vertices[it_index] = v
        indices[it_index] = auto_cast it_index
    }
    
    v_buffer_size := cast(vk.DeviceSize) len(vertices) * size_of(vertices[0])
    i_buffer_size := cast(vk.DeviceSize) len(indices)  * size_of(indices[0])
    
    buffer_create_info := vk.BufferCreateInfo {
        sType = .BUFFER_CREATE_INFO,
        size  = v_buffer_size + i_buffer_size,
        usage = { .VERTEX_BUFFER, .INDEX_BUFFER },
    }
    
    v_buffer_alloc_create_info := vma.Allocation_Create_Info {
        flags = { .Host_Access_Sequential_Write, .Host_Access_Allow_Transfer_Instead, .Mapped },
        usage = .Auto,
    }
    
    v_buffer: vk.Buffer
    v_buffer_allocation: vma.Allocation
    v_buffer_allocation_info: vma.Allocation_Info
    check(vma.create_buffer(allocator, buffer_create_info, v_buffer_alloc_create_info, &v_buffer, &v_buffer_allocation, &v_buffer_allocation_info))
    
    gpu_memory := cast([^]u8) v_buffer_allocation_info.mapped_data
    mem.copy_non_overlapping(gpu_memory[0:],             raw_data(vertices), auto_cast v_buffer_size)
    mem.copy_non_overlapping(gpu_memory[v_buffer_size:], raw_data(indices),  auto_cast i_buffer_size)
    
    ////////////////////////////////////////////////
    
    shader_data := struct {
        projection: m4,
        view:       m4,
        model:      [3] m4,
        light_pos:  [4] v4,
        selected:   u32,
    } {
        light_pos = { 0, -10, 10, 0 },
        selected  = 1,
    }
    
    Frame_Data :: struct {
        shader_data_buffer: Shader_Data_Buffer,
        command_buffer:     vk.CommandBuffer,
        
        fence:           vk.Fence,
        image_aquired:   vk.Semaphore,
    }
    
    Shader_Data_Buffer :: struct {
        allocation:      vma.Allocation,
        allocation_info: vma.Allocation_Info,
        buffer:          vk.Buffer,
        deviceAddress:   vk.DeviceAddress,
        command_buffer:  vk.CommandBuffer,
    }
    
    max_frames_in_flight :: 2
    
    frames := #soa [max_frames_in_flight] Frame_Data {}
    
    for &frame in frames {
        u_buffer_create_info := vk.BufferCreateInfo {
            sType = .BUFFER_CREATE_INFO,
            size  = size_of(shader_data),
            usage = { .SHADER_DEVICE_ADDRESS },
        } 
        
        u_buffer_alloc_create_info := vma.Allocation_Create_Info {
            flags = { .Host_Access_Sequential_Write, .Host_Access_Allow_Transfer_Instead, .Mapped },
            usage = .Auto,
        }
        
        check(vma.create_buffer(allocator, u_buffer_create_info, u_buffer_alloc_create_info, &frame.shader_data_buffer.buffer, &frame.shader_data_buffer.allocation, &frame.shader_data_buffer.allocation_info))
        
        u_buffer_device_address_info := vk.BufferDeviceAddressInfo {
            sType  = .BUFFER_DEVICE_ADDRESS_INFO,
            buffer = frame.shader_data_buffer.buffer,
        }
        frame.shader_data_buffer.deviceAddress = vk.GetBufferDeviceAddress(device, &u_buffer_device_address_info)
    }
    
    ////////////////////////////////////////////////
    
    semaphore_create_info := vk.SemaphoreCreateInfo {
        sType = .SEMAPHORE_CREATE_INFO,
    }
    
    for &frame in frames {
        frame.fence = vk_create_fence(device, { .SIGNALED })
        check(vk.CreateSemaphore(device, &semaphore_create_info, nil, &frame.image_aquired))
    }
    
    render_completed_semaphores: [dynamic] vk.Semaphore
    resize(&render_completed_semaphores, len(swapchain_images))
    for &sema in render_completed_semaphores {
        check(vk.CreateSemaphore(device, &semaphore_create_info, nil, &sema))
    }
    
    ////////////////////////////////////////////////
    
    command_pool_create_info := vk.CommandPoolCreateInfo {
        sType = .COMMAND_POOL_CREATE_INFO,
        flags = { .RESET_COMMAND_BUFFER },
        queueFamilyIndex = queue_family_index,
    }
    
    commandPool: vk.CommandPool
    check(vk.CreateCommandPool(device, &command_pool_create_info, nil, &commandPool))
    
    command_buffer_allocate_info := vk.CommandBufferAllocateInfo {
        sType = .COMMAND_BUFFER_ALLOCATE_INFO,
        commandPool = commandPool,
        commandBufferCount = len(frames.command_buffer),
    }
    check(vk.AllocateCommandBuffers(device, &command_buffer_allocate_info, &frames.command_buffer[0]))
    
    textures: [3] Texture
    texture_descriptors: [dynamic] vk.DescriptorImageInfo
    
    for &texture, index in textures {
        filename := fmt.tprintf("./tutorial/suzanne%v.ktx", index)
        data, err := os.read_entire_file(filename, context.temp_allocator); assert(err == nil)
        
        ktx_texture: ^ktx.Texture
        check(ktx.Texture_CreateFromMemory(&data[0], len(data), { .LOAD_IMAGE_DATA }, &ktx_texture))
        defer ktx.Texture1_Destroy(cast(^ktx.Texture1) ktx_texture)
        
        image_create_info := vk.ImageCreateInfo {
            sType = .IMAGE_CREATE_INFO,
            imageType = .D2,
            format = ktx.Texture_GetVkFormat(ktx_texture),
            extent = { width = ktx_texture.baseWidth, height = ktx_texture.baseHeight, depth = 1 },
            mipLevels = ktx_texture.numLevels,
            arrayLayers = 1,
            samples = { ._1 },
            tiling = .OPTIMAL,
            usage = { .TRANSFER_DST, .SAMPLED },
            initialLayout = .UNDEFINED,
        }
        
        image_allocation_create_info := vma.Allocation_Create_Info { usage = .Auto }
        check(vma.create_image(allocator, image_create_info, image_allocation_create_info, &texture.image, &texture.allocation, nil))
        
        view_create_info := vk.ImageViewCreateInfo {
            sType = .IMAGE_VIEW_CREATE_INFO,
            image = texture.image,
            viewType = .D2,
            format = image_create_info.format,
            subresourceRange = { aspectMask = { .COLOR }, levelCount = ktx_texture.numLevels, layerCount = 1 },
        }
        check(vk.CreateImageView(device, &view_create_info, nil, &texture.view))
        
        image_src_buffer: vk.Buffer
        image_src_allocation: vma.Allocation
        image_src_allocation_info: vma.Allocation_Info
        
        image_src_buffer_create_info := vk.BufferCreateInfo {
            sType = .BUFFER_CREATE_INFO,
            size  = auto_cast ktx_texture.dataSize,
            usage = { .TRANSFER_SRC },
        }
        
        image_src_allocation_create_info := vma.Allocation_Create_Info {
            flags = { .Host_Access_Sequential_Write, .Mapped },
            usage = .Auto,
        }
        
        check(vma.create_buffer(allocator, image_src_buffer_create_info, image_src_allocation_create_info, &image_src_buffer, &image_src_allocation, &image_src_allocation_info))
        
        mem.copy_non_overlapping(image_src_allocation_info.mapped_data, ktx_texture.pData, auto_cast ktx_texture.dataSize)
        
        fence_once := vk_create_fence(device)
        
        cb_once: vk.CommandBuffer
        cb_once_allocate_info := vk.CommandBufferAllocateInfo {
            sType = .COMMAND_BUFFER_ALLOCATE_INFO,
            commandPool = commandPool,
            commandBufferCount = 1,
        }
        check(vk.AllocateCommandBuffers(device, &cb_once_allocate_info, &cb_once))
        
        cb_once_begin_info := vk.CommandBufferBeginInfo {
            sType = .COMMAND_BUFFER_BEGIN_INFO,
            flags = { .ONE_TIME_SUBMIT },
        }
        check(vk.BeginCommandBuffer(cb_once, &cb_once_begin_info))
        
        barrier_image := vk.ImageMemoryBarrier2 {
            sType = .IMAGE_MEMORY_BARRIER_2,
            srcStageMask = {}, // @note(viktor): check if this is correct
            srcAccessMask = {},
            dstStageMask = { .TRANSFER },
            dstAccessMask = { .TRANSFER_WRITE },
            oldLayout = .UNDEFINED,
            newLayout = .TRANSFER_DST_OPTIMAL,
            image = texture.image,
            subresourceRange = { aspectMask = { .COLOR }, levelCount = ktx_texture.numLevels, layerCount = 1 },
        }
        
        barrier_info := vk.DependencyInfo {
            sType = .DEPENDENCY_INFO,
            imageMemoryBarrierCount = 1,
            pImageMemoryBarriers = &barrier_image,
        }
        vk.CmdPipelineBarrier2(cb_once, &barrier_info)
        
        copy_regions := make([dynamic] vk.BufferImageCopy, context.temp_allocator)
        for level in 0..<ktx_texture.numLevels {
            mip_offset: uint
            // @todo(viktor): check that this is correct
            ret := ktx.Texture2_GetImageOffset(cast(^ktx.Texture2) ktx_texture, level, 0, 0, &mip_offset)
            append(&copy_regions, vk.BufferImageCopy{
                bufferOffset = auto_cast mip_offset,
                imageSubresource = { aspectMask = { .COLOR }, mipLevel = level, layerCount = 1 },
                imageExtent = { width = ktx_texture.baseWidth >> level, height = ktx_texture.baseHeight >> level, depth = 1 },
            })
        }
        
        vk.CmdCopyBufferToImage(cb_once, image_src_buffer, texture.image, .TRANSFER_DST_OPTIMAL, auto_cast len(copy_regions), raw_data(copy_regions))
        
        barrier_read := vk.ImageMemoryBarrier2 {
            sType = .IMAGE_MEMORY_BARRIER_2,
            srcStageMask = { .TRANSFER }, // @note(viktor): check if this is correct
            srcAccessMask = { .TRANSFER_WRITE },
            dstStageMask = { .FRAGMENT_SHADER },
            dstAccessMask = { .SHADER_READ },
            oldLayout = .TRANSFER_DST_OPTIMAL,
            newLayout = .READ_ONLY_OPTIMAL,
            image = texture.image,
            subresourceRange = { aspectMask = { .COLOR }, levelCount = ktx_texture.numLevels, layerCount = 1 },
        }
        
        barrier_info.pImageMemoryBarriers = &barrier_read
        vk.CmdPipelineBarrier2(cb_once, &barrier_info)
        
        check(vk.EndCommandBuffer(cb_once))
        
        once_submit_info := vk.SubmitInfo {
            sType = .SUBMIT_INFO,
            commandBufferCount = 1,
            pCommandBuffers = &cb_once,
        }
        
        check(vk.QueueSubmit(queue, 1, &once_submit_info, fence_once))
        
        check(vk.WaitForFences(device, 1, &fence_once, true, max(u64)))
        
        sampler_create_info := vk.SamplerCreateInfo {
            sType = .SAMPLER_CREATE_INFO,
            magFilter = .LINEAR,
            minFilter = .LINEAR,
            mipmapMode = .LINEAR,
            anisotropyEnable = true,
            maxAnisotropy = 8,
            maxLod = cast(f32) ktx_texture.numLevels,
        }
        
        check(vk.CreateSampler(device, &sampler_create_info, nil, &texture.sampler))
        
        append(&texture_descriptors, vk.DescriptorImageInfo{ sampler = texture.sampler, imageView = texture.view, imageLayout = .READ_ONLY_OPTIMAL })
    }
    
    ////////////////////////////////////////////////
    
    desc_variable_flags := vk.DescriptorBindingFlags { .VARIABLE_DESCRIPTOR_COUNT }
    desc_binding_flags := vk.DescriptorSetLayoutBindingFlagsCreateInfo {
        sType = .DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO,
        bindingCount = 1,
        pBindingFlags = &desc_variable_flags,
    }
    
    desc_layout_binding_textures := vk.DescriptorSetLayoutBinding {
        descriptorType = .COMBINED_IMAGE_SAMPLER,
        descriptorCount = len(textures),
        stageFlags = { .FRAGMENT },
    }
    
    desc_layout_textures_create_info := vk.DescriptorSetLayoutCreateInfo {
        sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        pNext = &desc_binding_flags,
        bindingCount = 1,
        pBindings = &desc_layout_binding_textures,
    }
    
    descriptor_set_layout_textures: vk.DescriptorSetLayout
    check(vk.CreateDescriptorSetLayout(device, &desc_layout_textures_create_info, nil, &descriptor_set_layout_textures))
    
    pool_size := vk.DescriptorPoolSize {
        type = .COMBINED_IMAGE_SAMPLER,
        descriptorCount = len(textures),
    }
    
    desc_pool_create_info := vk.DescriptorPoolCreateInfo {
        sType = .DESCRIPTOR_POOL_CREATE_INFO,
        maxSets = 1,
        poolSizeCount = 1,
        pPoolSizes = &pool_size,
    }
    
    descriptor_pool: vk.DescriptorPool
    check(vk.CreateDescriptorPool(device, &desc_pool_create_info, nil, &descriptor_pool))
    
    variable_desc_count := cast(u32) len(textures)
    variable_desc_count_allocate_info := vk.DescriptorSetVariableDescriptorCountAllocateInfo {
        sType = .DESCRIPTOR_SET_VARIABLE_DESCRIPTOR_COUNT_ALLOCATE_INFO,
        descriptorSetCount = 1,
        pDescriptorCounts = &variable_desc_count,
    }
    textures_desc_set_allocate_info := vk.DescriptorSetAllocateInfo {
        sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
        pNext = &variable_desc_count_allocate_info,
        descriptorPool = descriptor_pool,
        descriptorSetCount = 1,
        pSetLayouts = &descriptor_set_layout_textures,
    }
    
    descriptor_set_textures: vk.DescriptorSet
    check(vk.AllocateDescriptorSets(device, &textures_desc_set_allocate_info, &descriptor_set_textures))
    
    write_desc_set := vk.WriteDescriptorSet {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = descriptor_set_textures,
        dstBinding = 0,
        descriptorCount = cast(u32) len(texture_descriptors),
        descriptorType = .COMBINED_IMAGE_SAMPLER,
        pImageInfo = raw_data(texture_descriptors),
    }
    vk.UpdateDescriptorSets(device, 1, &write_desc_set, 0, nil)
    
    ////////////////////////////////////////////////
    
    slang_global_session: ^slang.IGlobalSession
    check(slang.createGlobalSession(slang.API_VERSION, &slang_global_session))
    
    slang_targets := [] slang.TargetDesc {
        { format = .SPIRV, profile = slang_global_session->findProfile("spirv_1_4") }
    }
    slang_options := [] slang.CompilerOptionEntry {
        { name = .EmitSpirvDirectly, value = { kind = .Int, intValue0 = 1 } }
    }
    slang_session_desc := slang.SessionDesc {
        targets = raw_data(slang_targets),
        targetCount = auto_cast len(slang_targets),
        defaultMatrixLayoutMode = .COLUMN_MAJOR,
        compilerOptionEntries = raw_data(slang_options),
        compilerOptionEntryCount = auto_cast len(slang_options),
    }
    
    slang_session: ^slang.ISession
    check(slang_global_session->createSession(slang_session_desc, &slang_session))
    
    slang_module: ^slang.IModule = slang_session->loadModuleFromSource("triangle", "./tutorial/shader.slang", nil, nil)
    spirv: ^slang.IBlob
    slang_module->getTargetCode(0, &spirv, nil)
    
    shader_module_create_info := vk.ShaderModuleCreateInfo {
        sType = .SHADER_MODULE_CREATE_INFO,
        codeSize = auto_cast spirv->getBufferSize(),
        pCode = auto_cast spirv->getBufferPointer(),
    }
    
    shader_module: vk.ShaderModule
    vk.CreateShaderModule(device, &shader_module_create_info, nil, &shader_module)
}

////////////////////////////////////////////////

vk_create_fence :: proc (device: vk.Device, flags: vk.FenceCreateFlags = {}) -> vk.Fence {
    fence_create_info := vk.FenceCreateInfo {
        sType = .FENCE_CREATE_INFO,
        flags = flags
    }
    
    result: vk.Fence
    check(vk.CreateFence(device, &fence_create_info, nil, &result))
    return result
}

////////////////////////////////////////////////

Texture :: struct {
	allocation: vma.Allocation,
	image:      vk.Image,
	view:       vk.ImageView,
	sampler:    vk.Sampler,
}

Vertex :: struct {
    p:  v3,
    n:  v3,
    uv: v2,
}

////////////////////////////////////////////////

check :: proc { check_vulkan, check_sdl, check_ktx, check_slang }
check_vulkan :: proc (result: vk.Result, loc := #caller_location) {
    if result != .SUCCESS {
        fmt.printf("%v:%v:%v: Vulkan call returned %v", loc.file_path, loc.line, loc.column, result)
        intrinsics.debug_trap()
        os.exit(1)
    }
}
check_ktx :: proc (result: ktx.Result, loc := #caller_location) {
    if result != .SUCCESS {
        fmt.printf("%v:%v:%v: KTX call returned %v", loc.file_path, loc.line, loc.column, result)
        intrinsics.debug_trap()
        os.exit(1)
    }
}
check_sdl :: proc (result: sdl.bool, loc := #caller_location) {
    if result != true {
        fmt.printf("%v:%v:%v: SDL call returned %v", loc.file_path, loc.line, loc.column, sdl.GetError())
        intrinsics.debug_trap()
        os.exit(1)
    }
}
check_slang :: proc (result: slang.Result, loc := #caller_location) {
    if result != 0 {
        fmt.printf("%v:%v:%v: slang call returned %v", loc.file_path, loc.line, loc.column, result)
        intrinsics.debug_trap()
        os.exit(1)
    }
}