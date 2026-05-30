package main

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:mem"
import la "core:math/linalg"
import "core:strconv"
import "../libs/vma"
import "../libs/tobj"
import "../libs/ktx"
import "../libs/slang/slang"

import sdl "vendor:sdl2"
import vk "vendor:vulkan"

////////////////////////////////////////////////

Swapchain_Info :: struct {
    image: vk.Image,
    image_view: vk.ImageView,
    render_completed: vk.Semaphore,
}

recreate_swapchain: bool

////////////////////////////////////////////////

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
        instance_extension_count: u32
        sdl.Vulkan_GetInstanceExtensions(window, &instance_extension_count, nil)
        instance_extensions := make([]cstring, instance_extension_count, context.temp_allocator)
        sdl.Vulkan_GetInstanceExtensions(window, &instance_extension_count, raw_data(instance_extensions))
        when false {
            instance_extensions := sdl.Vulkan_GetInstanceExtensions(&instance_extension_count)
        }
        
        instance_create_info := vk.InstanceCreateInfo {
            sType = .INSTANCE_CREATE_INFO,
            pApplicationInfo = &vk.ApplicationInfo {
                sType = .APPLICATION_INFO,
                pApplicationName = "How to Vulkan",
                apiVersion = vk.API_VERSION_1_3,
            },
            enabledExtensionCount = instance_extension_count,
            ppEnabledExtensionNames = raw_data(instance_extensions),
        }
        
        when ODIN_DEBUG {
            validation_layers := []cstring{"VK_LAYER_KHRONOS_validation"}
            instance_create_info.enabledLayerCount = auto_cast len(validation_layers)
            instance_create_info.ppEnabledLayerNames = raw_data(validation_layers)
        }
        
        check(vk.CreateInstance(&instance_create_info, nil, &instance))
        
        vk.load_proc_addresses_instance(instance)
    }
    
    ////////////////////////////////////////////////
    
    physical_device: vk.PhysicalDevice
    {
        physical_devices: [] vk.PhysicalDevice
        {
            device_count: u32
            check(vk.EnumeratePhysicalDevices(instance, &device_count, nil))
            physical_devices = make([] vk.PhysicalDevice, device_count)
            check(vk.EnumeratePhysicalDevices(instance, &device_count, raw_data(physical_devices)))
        }
        
        device_index: u32
        if len(os.args) > 1 {
            device_index = cast(u32) (strconv.parse_u64(os.args[1]) or_else 0)
            assert(device_index < auto_cast len(physical_devices))
        }
        
        physical_device = physical_devices[device_index]
        
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
        
        device_extensions := [] cstring { vk.KHR_SWAPCHAIN_EXTENSION_NAME }
        
        device_create_info := vk.DeviceCreateInfo {
            sType = .DEVICE_CREATE_INFO,
            
            pEnabledFeatures = &vk.PhysicalDeviceFeatures {
                samplerAnisotropy = true,
            },
            pNext = &vk.PhysicalDeviceVulkan13Features {
                sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
                pNext = &vk.PhysicalDeviceVulkan12Features {
                    sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
                    descriptorIndexing                        = true,
                    shaderSampledImageArrayNonUniformIndexing = true,
                    descriptorBindingVariableDescriptorCount  = true,
                    runtimeDescriptorArray                    = true,
                    bufferDeviceAddress                       = true,
                },
                synchronization2 = true,
                dynamicRendering = true,
            },
            
            queueCreateInfoCount = 1,
            pQueueCreateInfos    = &vk.DeviceQueueCreateInfo {
                sType = .DEVICE_QUEUE_CREATE_INFO,
                queueFamilyIndex = queue_family_index,
                queueCount = auto_cast len(queue_family_priority),
                pQueuePriorities = raw_data(queue_family_priority),
            },
            
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
    swapchain_create_info: vk.SwapchainCreateInfoKHR
    surface_capabilities: vk.SurfaceCapabilitiesKHR
    image_format := vk.Format.B8G8R8A8_SRGB
    {
        check(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface, &surface_capabilities))
        
        swapchain_extent := surface_capabilities.currentExtent
        if surface_capabilities.currentExtent.width == 0xFFFFFFFF {
            swapchain_extent = { width = cast(u32) window_size.x, height = cast(u32) window_size.y }
        }
        
        swapchain_create_info = vk.SwapchainCreateInfoKHR {
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
    
    swapchain_infos: #soa [dynamic] Swapchain_Info
    image_count: u32
    vk_recreate_swapchain(device, image_format, &image_count, &swapchain_infos, swapchain)
    
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
    depth_image: vk.Image
    depth_image_view: vk.ImageView
    depth_image_allocation: vma.Allocation
    {
        depth_format_list := [] vk.Format { .D32_SFLOAT_S8_UINT, .D24_UNORM_S8_UINT }
        for it in depth_format_list {
            format_properties := vk.FormatProperties2 { sType = .FORMAT_PROPERTIES_2 }
            vk.GetPhysicalDeviceFormatProperties2(physical_device, it, &format_properties)
            
            if .DEPTH_STENCIL_ATTACHMENT in format_properties.formatProperties.optimalTilingFeatures {
                depth_format = it
                break
            }
        }
        
        depth_image, depth_image_view, depth_image_allocation = vk_create_depth_image(device, depth_format, cast(uv2) window_size, allocator)
    }
    
    ////////////////////////////////////////////////
    
    v_buffer: vk.Buffer
    v_buffer_size: vk.DeviceSize
    index_count: u32
    v_buffer_allocation: vma.Allocation
    {
        models, _, error := tobj.load_obj_filename("./tutorial/suzanne.obj", allocator = context.temp_allocator)
        assert(error == nil)
        model := models[0].mesh
        index_count = cast(u32) len(model.indices)
        vertices := make([] Vertex, index_count, context.temp_allocator)
        indices  := make([] i16,  len(vertices), context.temp_allocator)
        
        for index, it_index in model.indices {
            v := Vertex {
                p  = model.vertices[index]       * { 1, -1, 1 },
                n  = model.normals[index]        * { 1, -1, 1 },
                uv = model.texture_coords[index] * { 1, -1 },
            }
            
            vertices[it_index] = v
            indices[it_index]  = auto_cast it_index
        }
        
        v_buffer_size  = cast(vk.DeviceSize) len(vertices) * size_of(vertices[0])
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
        
        v_buffer_allocation_info: vma.Allocation_Info
        check(vma.create_buffer(allocator, buffer_create_info, v_buffer_alloc_create_info, &v_buffer, &v_buffer_allocation, &v_buffer_allocation_info))
        
        gpu_memory := cast([^]u8) v_buffer_allocation_info.mapped_data
        mem.copy_non_overlapping(gpu_memory[0:],             raw_data(vertices), auto_cast v_buffer_size)
        mem.copy_non_overlapping(gpu_memory[v_buffer_size:], raw_data(indices),  auto_cast i_buffer_size)
    }
    
    ////////////////////////////////////////////////
    
    Shader_Data :: struct {
        projection: m4,
        view:       m4,
        model:      [3] m4,
        light_pos:  [4] v4,
        selected:   u32,
    }
    shader_data := Shader_Data {
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
    
    MaxFramesInFlight :: 2
    
    frames := #soa [MaxFramesInFlight] Frame_Data {}
    
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
    
    for &frame in frames {
        frame.fence = vk_create_fence(device, { .SIGNALED })
        frame.image_aquired = vk_create_semaphore(device)
    }
    
    ////////////////////////////////////////////////
    
    commandPool: vk.CommandPool
    {
        command_pool_create_info := vk.CommandPoolCreateInfo {
            sType = .COMMAND_POOL_CREATE_INFO,
            flags = { .RESET_COMMAND_BUFFER },
            queueFamilyIndex = queue_family_index,
        }
        
        check(vk.CreateCommandPool(device, &command_pool_create_info, nil, &commandPool))
        
        command_buffer_allocate_info := vk.CommandBufferAllocateInfo {
            sType = .COMMAND_BUFFER_ALLOCATE_INFO,
            commandPool = commandPool,
            commandBufferCount = len(frames.command_buffer),
        }
        check(vk.AllocateCommandBuffers(device, &command_buffer_allocate_info, &frames.command_buffer[0]))
    }
     
    textures: [3] Texture
    texture_descriptors: [len(textures)] vk.DescriptorImageInfo
    
    {
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
            defer vma.destroy_buffer(allocator, image_src_buffer, image_src_allocation)
            
            mem.copy_non_overlapping(image_src_allocation_info.mapped_data, ktx_texture.pData, auto_cast ktx_texture.dataSize)
            
            fence_once := vk_create_fence(device)
            defer vk.DestroyFence(device, fence_once, nil)
            
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
            
            barrier_info := vk.DependencyInfo {
                sType = .DEPENDENCY_INFO,
                imageMemoryBarrierCount = 1,
                pImageMemoryBarriers = &vk.ImageMemoryBarrier2 {
                    sType = .IMAGE_MEMORY_BARRIER_2,
                    srcStageMask = {}, // @note(viktor): check if this is correct
                    srcAccessMask = {},
                    dstStageMask = { .TRANSFER },
                    dstAccessMask = { .TRANSFER_WRITE },
                    oldLayout = .UNDEFINED,
                    newLayout = .TRANSFER_DST_OPTIMAL,
                    image = texture.image,
                    subresourceRange = { aspectMask = { .COLOR }, levelCount = ktx_texture.numLevels, layerCount = 1 },
                },
            }
            vk.CmdPipelineBarrier2(cb_once, &barrier_info)
            
            copy_regions := make([dynamic] vk.BufferImageCopy, context.temp_allocator)
            for level in 0..<ktx_texture.numLevels {
                mip_offset: uint
                // @todo(viktor): this is not correct, is the Texture1 binding missing. This causes the mipmaps to be wrong.
                ktx.Texture2_GetImageOffset(cast(^ktx.Texture2) ktx_texture, level, 0, 0, &mip_offset)
                append(&copy_regions, vk.BufferImageCopy{
                    bufferOffset = auto_cast mip_offset,
                    imageSubresource = { aspectMask = { .COLOR }, mipLevel = level, layerCount = 1 },
                    imageExtent = { width = ktx_texture.baseWidth >> level, height = ktx_texture.baseHeight >> level, depth = 1 },
                })
            }
            
            vk.CmdCopyBufferToImage(cb_once, image_src_buffer, texture.image, .TRANSFER_DST_OPTIMAL, auto_cast len(copy_regions), raw_data(copy_regions))
            
            barrier_info.pImageMemoryBarriers = &vk.ImageMemoryBarrier2 {
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
            
            texture_descriptors[index] = vk.DescriptorImageInfo{ sampler = texture.sampler, imageView = texture.view, imageLayout = .READ_ONLY_OPTIMAL }
        }
    }
    
    ////////////////////////////////////////////////
    
    descriptor_set_layout_textures: vk.DescriptorSetLayout
    descriptor_set_textures: vk.DescriptorSet
    descriptor_pool: vk.DescriptorPool
    {
        desc_layout_textures_create_info := vk.DescriptorSetLayoutCreateInfo {
            sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            pNext = &vk.DescriptorSetLayoutBindingFlagsCreateInfo {
                sType = .DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO,
                bindingCount = 1,
                pBindingFlags = &vk.DescriptorBindingFlags { .VARIABLE_DESCRIPTOR_COUNT },
            },
            bindingCount = 1,
            pBindings = &vk.DescriptorSetLayoutBinding {
                descriptorType = .COMBINED_IMAGE_SAMPLER,
                descriptorCount = len(textures),
                stageFlags = { .FRAGMENT },
            },
        }
        
        check(vk.CreateDescriptorSetLayout(device, &desc_layout_textures_create_info, nil, &descriptor_set_layout_textures))
        
        desc_pool_create_info := vk.DescriptorPoolCreateInfo {
            sType = .DESCRIPTOR_POOL_CREATE_INFO,
            maxSets = 1,
            poolSizeCount = 1,
            pPoolSizes = &vk.DescriptorPoolSize {
                type = .COMBINED_IMAGE_SAMPLER,
                descriptorCount = len(textures),
            },
        }
        
        check(vk.CreateDescriptorPool(device, &desc_pool_create_info, nil, &descriptor_pool))
        
        variable_desc_count := cast(u32) len(textures)
        
        textures_desc_set_allocate_info := vk.DescriptorSetAllocateInfo {
            sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
            pNext = &vk.DescriptorSetVariableDescriptorCountAllocateInfo {
                sType = .DESCRIPTOR_SET_VARIABLE_DESCRIPTOR_COUNT_ALLOCATE_INFO,
                descriptorSetCount = 1,
                pDescriptorCounts = &variable_desc_count,
            },
            descriptorPool = descriptor_pool,
            descriptorSetCount = 1,
            pSetLayouts = &descriptor_set_layout_textures,
        }
        
        check(vk.AllocateDescriptorSets(device, &textures_desc_set_allocate_info, &descriptor_set_textures))
        
        write_desc_set := vk.WriteDescriptorSet {
            sType = .WRITE_DESCRIPTOR_SET,
            dstSet = descriptor_set_textures,
            dstBinding = 0,
            descriptorCount = cast(u32) len(texture_descriptors),
            descriptorType = .COMBINED_IMAGE_SAMPLER,
            pImageInfo = &texture_descriptors[0],
        }
        vk.UpdateDescriptorSets(device, 1, &write_desc_set, 0, nil)
    }
    
    ////////////////////////////////////////////////
    
    shader_module: vk.ShaderModule
    {
        when false {
            slang_global_session: ^slang.IGlobalSession
            check(slang.createGlobalSession(slang.API_VERSION, &slang_global_session))
            
            slang_targets := [] slang.TargetDesc {
                { format = .SPIRV, profile = slang_global_session->findProfile("spirv_1_4") },
            }
            slang_options := [] slang.CompilerOptionEntry {
                { name = .EmitSpirvDirectly, value = { kind = .Int, intValue0 = 1 } },
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
            
            slang_module := slang_session->loadModuleFromSource("triangle", "./tutorial/shader.slang", nil, nil)
            
            spirv: ^slang.IBlob
            check(slang_module->getTargetCode(0, &spirv, nil))
            
            shader_module_ci := vk.ShaderModuleCreateInfo {
                sType = .SHADER_MODULE_CREATE_INFO,
                codeSize = cast(int) spirv->getBufferSize(),
                pCode = cast(^u32)spirv->getBufferPointer(),
            }
        } else {
            // slangc -target spirv -o ./tutorial/shader.spirv ./tutorial/shader.slang
            shader_bytes, err := os.read_entire_file("./tutorial/shader.spirv", context.temp_allocator)
            assert(err == nil)
            raw_shader_bytes_32 := transmute(RawSlice) shader_bytes
            raw_shader_bytes_32.len /= size_of(u32) / size_of(u8)
            shader_bytes_32 := transmute([] u32) raw_shader_bytes_32
            shader_module_ci := vk.ShaderModuleCreateInfo {
                sType = .SHADER_MODULE_CREATE_INFO,
                codeSize = len(shader_bytes),
                pCode = raw_data(shader_bytes_32),
            }
        }
        
        check(vk.CreateShaderModule(device, &shader_module_ci, nil, &shader_module))
    }
    
    ////////////////////////////////////////////////
    
    pipeline: vk.Pipeline
    pipeline_layout: vk.PipelineLayout
    {
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
            { sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = { .VERTEX },   module = shader_module, pName = "main" },
            { sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = { .FRAGMENT }, module = shader_module, pName = "main" },
        }
        
        dynamic_states := [] vk.DynamicState { .VIEWPORT, .SCISSOR }
        
        pipeline_create_info := vk.GraphicsPipelineCreateInfo {
            sType = .GRAPHICS_PIPELINE_CREATE_INFO,
            pNext = &vk.PipelineRenderingCreateInfo {
                sType = .PIPELINE_RENDERING_CREATE_INFO,
                colorAttachmentCount = 1,
                pColorAttachmentFormats = &image_format,
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
    }
    
    ////////////////////////////////////////////////
    
    cam_pos := v3{ 0, 0, -6 }
    object_rotations: [3] v3
    
    last_time := sdl.GetTicks()
    
    frame_index: u32
    image_index: u32
    Timeout :: max(u64)
    quit: bool
    for !quit {
        free_all(context.temp_allocator)
        
        frame := &frames[frame_index]
        check(vk.WaitForFences(device, 1, &frame.fence, true, Timeout))
        check(vk.ResetFences(device, 1, &frame.fence))
        
        check(vk.AcquireNextImageKHR(device, swapchain, Timeout, frame.image_aquired, {}, &image_index), outofdate_recreates_swapchain = true)
        
        swapchain_info := &swapchain_infos[image_index]
        
        ////////////////////////////////////////////////
        
        current_time := sdl.GetTicks()
        delta_time := cast(f32) (current_time - last_time) / 1000
        last_time = current_time
        
        for event: sdl.Event; sdl.PollEvent(&event); {
            #partial switch event.type {
            case .QUIT:
                quit = true
            
            case .MOUSEMOTION:
                if event.button.button == sdl.BUTTON_LEFT {
                    object_rotations[shader_data.selected].x -= cast(f32) event.motion.yrel * delta_time
                    object_rotations[shader_data.selected].y += cast(f32) event.motion.xrel * delta_time
                }
                
            case .MOUSEWHEEL:
                cam_pos.z += cast(f32) event.wheel.y * 10 * delta_time
                
            case .KEYDOWN:
                if event.key.keysym.sym == .PLUS || event.key.keysym.sym == .KP_PLUS {
                    shader_data.selected = (shader_data.selected + 1) % len(shader_data.model)
                }
                if event.key.keysym.sym == .MINUS || event.key.keysym.sym == .KP_MINUS {
                    shader_data.selected = (shader_data.selected + len(shader_data.model) - 1) % len(shader_data.model)
                }
                
            case .WINDOWEVENT:
                if event.window.event == .RESIZED {
                    recreate_swapchain = true
                }
            }
        }
        
        ////////////////////////////////////////////////
        
        if recreate_swapchain {
            recreate_swapchain = false
            
            vk.DeviceWaitIdle(device)
            
            sdl.GetWindowSize(window, &window_size.x, &window_size.y)
            
            check(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface, &surface_capabilities))
            
            swapchain_create_info.oldSwapchain = swapchain
            swapchain_create_info.imageExtent = { width = cast(u32) window_size.x, height = cast(u32) window_size.y }
            check(vk.CreateSwapchainKHR(device, &swapchain_create_info, nil, &swapchain))
            
            for &info in swapchain_infos {
                vk.DestroyImageView(device, info.image_view, nil)
                vk.DestroySemaphore(device, info.render_completed, nil)
            }
             
            vk_recreate_swapchain(device, image_format, &image_count, &swapchain_infos, swapchain)
            
            vk.DestroySwapchainKHR(device, swapchain_create_info.oldSwapchain, nil)
            
            vma.destroy_image(allocator, depth_image, depth_image_allocation)
            vk.DestroyImageView(device, depth_image_view, nil)
            
            depth_image, depth_image_view, depth_image_allocation = vk_create_depth_image(device, depth_format, cast(uv2) window_size, allocator)
        }
        
        ////////////////////////////////////////////////
        
        shader_data.projection = la.matrix4_perspective(45 * RadPerDeg, cast(f32) window_size.x / cast(f32) window_size.y, 0.1, 128)
        shader_data.view = la.matrix4_translate(cam_pos)
        for &model, i in shader_data.model {
            instance_pos := v3{cast(f32) (i - 1) * 3, 0, 0}
            model = la.matrix4_translate(instance_pos) * la.matrix4_from_quaternion(la.quaternion_from_euler_angles_f32(expand_values(object_rotations[i]), .XYX))
        }
        
        mem.copy_non_overlapping(frame.shader_data_buffer.allocation_info.mapped_data, &shader_data, size_of(shader_data))
        
        ////////////////////////////////////////////////
        
        cb := frame.command_buffer
        check(vk.ResetCommandBuffer(cb, {}))
        
        cb_begin_info := vk.CommandBufferBeginInfo {
            sType = .COMMAND_BUFFER_BEGIN_INFO,
            flags = { .ONE_TIME_SUBMIT },
        }
        check(vk.BeginCommandBuffer(cb, &cb_begin_info))
        
        output_barriers := [2] vk.ImageMemoryBarrier2 {
            {
                sType = .IMAGE_MEMORY_BARRIER_2,
                srcStageMask = { .COLOR_ATTACHMENT_OUTPUT },
                srcAccessMask = {},
                dstStageMask = { .COLOR_ATTACHMENT_OUTPUT },
                dstAccessMask = { .COLOR_ATTACHMENT_READ, . COLOR_ATTACHMENT_WRITE },
                oldLayout = .UNDEFINED,
                newLayout = .ATTACHMENT_OPTIMAL,
                image = swapchain_info.image,
                subresourceRange = { aspectMask = { .COLOR }, levelCount = 1, layerCount = 1 },
            },
            {
                sType = .IMAGE_MEMORY_BARRIER_2,
                srcStageMask = { .LATE_FRAGMENT_TESTS },
                srcAccessMask = { .DEPTH_STENCIL_ATTACHMENT_WRITE },
                dstStageMask = { .EARLY_FRAGMENT_TESTS },
                dstAccessMask = { .DEPTH_STENCIL_ATTACHMENT_WRITE },
                oldLayout = .UNDEFINED,
                newLayout = .ATTACHMENT_OPTIMAL,
                image = depth_image,
                subresourceRange = { aspectMask = { .DEPTH, .STENCIL }, levelCount = 1, layerCount = 1 },
            },
        }
        
        barrier_dependency_info := vk.DependencyInfo {
            sType = .DEPENDENCY_INFO,
            imageMemoryBarrierCount = len(output_barriers),
            pImageMemoryBarriers = &output_barriers[0],
        }
        vk.CmdPipelineBarrier2(cb, &barrier_dependency_info)
        
        ////////////////////////////////////////////////
        
        rendering_info := vk.RenderingInfo {
            sType = .RENDERING_INFO, 
            renderArea = { extent = { width = cast(u32) window_size.x, height = cast(u32) window_size.y } },
            layerCount = 1,
            colorAttachmentCount = 1,
            pColorAttachments = &vk.RenderingAttachmentInfo {
                sType = .RENDERING_ATTACHMENT_INFO,
                imageView = swapchain_info.image_view,
                imageLayout = .ATTACHMENT_OPTIMAL,
                loadOp = .CLEAR,
                storeOp = .STORE,
                clearValue = { color = { float32 = v4{0, 0, .2, 1 } } },
            },
            pDepthAttachment  = &vk.RenderingAttachmentInfo {
                sType = .RENDERING_ATTACHMENT_INFO,
                imageView = depth_image_view,
                imageLayout = .ATTACHMENT_OPTIMAL,
                loadOp = .CLEAR,
                storeOp = .DONT_CARE,
                clearValue = { depthStencil = { 1, 0 } },
            },
        }
        
        ////////////////////////////////////////////////
        
        vk.CmdBeginRendering(cb, &rendering_info)
        
        viewport := vk.Viewport {
            width  = cast(f32) window_size.x,
            height = cast(f32) window_size.y,
            minDepth = 0,
            maxDepth = 1,
        }
        
        vk.CmdSetViewport(cb, 0, 1, &viewport)
        
        scissor := vk.Rect2D { extent = { width = cast(u32) window_size.x, height = cast(u32) window_size.y } }
        vk.CmdSetScissor(cb, 0, 1, &scissor)
        
        vk.CmdBindPipeline(cb, .GRAPHICS, pipeline)
        v_offset: vk.DeviceSize
        vk.CmdBindDescriptorSets(cb, .GRAPHICS, pipeline_layout, 0, 1, &descriptor_set_textures, 0, nil)
        vk.CmdBindVertexBuffers(cb, 0, 1, &v_buffer, &v_offset)
        vk.CmdBindIndexBuffer(cb, v_buffer, v_buffer_size, .UINT16)
        
        vk.CmdPushConstants(cb, pipeline_layout, { .VERTEX }, 0, size_of(vk.DeviceAddress), &frame.shader_data_buffer.deviceAddress)
        
        vk.CmdDrawIndexed(cb, index_count, 3, 0, 0, 0)
        
        vk.CmdEndRendering(cb)
        
        ////////////////////////////////////////////////
        
        barrier_present := vk.ImageMemoryBarrier2 {
            sType = .IMAGE_MEMORY_BARRIER_2,
            srcStageMask = { .COLOR_ATTACHMENT_OUTPUT },
            srcAccessMask = { .COLOR_ATTACHMENT_WRITE },
            dstStageMask = { .COLOR_ATTACHMENT_OUTPUT },
            dstAccessMask = {},
            oldLayout = .ATTACHMENT_OPTIMAL,
            newLayout = .PRESENT_SRC_KHR,
            image = swapchain_info.image,
            subresourceRange = { aspectMask = { .COLOR }, levelCount = 1, layerCount = 1 },
        }
        
        barrier_present_dependency_info := vk.DependencyInfo {
            sType = .DEPENDENCY_INFO,
            imageMemoryBarrierCount = 1,
            pImageMemoryBarriers = &barrier_present,
        }
        vk.CmdPipelineBarrier2(cb, &barrier_present_dependency_info)
        
        vk.EndCommandBuffer(cb)
        
        ////////////////////////////////////////////////
        
        wait_stages := vk.PipelineStageFlags { .COLOR_ATTACHMENT_OUTPUT }
        submit_info := vk.SubmitInfo {
            sType = .SUBMIT_INFO,
            waitSemaphoreCount = 1,
            pWaitSemaphores = &frame.image_aquired,
            pWaitDstStageMask = &wait_stages,
            commandBufferCount = 1,
            pCommandBuffers = &cb,
            signalSemaphoreCount = 1,
            pSignalSemaphores = &swapchain_info.render_completed,
        }
        check(vk.QueueSubmit(queue, 1, &submit_info, frame.fence))
        
        ////////////////////////////////////////////////
        
        frame_index = (frame_index + 1) % MaxFramesInFlight
        
        ////////////////////////////////////////////////
        
        present_info := vk.PresentInfoKHR {
            sType = .PRESENT_INFO_KHR,
            waitSemaphoreCount = 1,
            pWaitSemaphores = &swapchain_info.render_completed,
            swapchainCount = 1,
            pSwapchains = &swapchain,
            pImageIndices = &image_index,
        }
        check(vk.QueuePresentKHR(queue, &present_info), outofdate_recreates_swapchain = true)
        
        ////////////////////////////////////////////////
    }
    
	check(vk.DeviceWaitIdle(device))
    
    for frame in frames {
		vk.DestroyFence(device, frame.fence, nil)
		vk.DestroySemaphore(device, frame.image_aquired, nil)
		vma.destroy_buffer(allocator, frame.shader_data_buffer.buffer, frame.shader_data_buffer.allocation)
    }
    
    for info in swapchain_infos {
        vk.DestroySemaphore(device, info.render_completed, nil)
        vk.DestroyImageView(device, info.image_view, nil)
	}
    
	vma.destroy_image(allocator, depth_image, depth_image_allocation)
	vk.DestroyImageView(device, depth_image_view, nil)
	vma.destroy_buffer(allocator, v_buffer, v_buffer_allocation)
    
    for texture in textures {
        vk.DestroyImageView(device, texture.view, nil)
        vk.DestroySampler(device, texture.sampler, nil)
        vma.destroy_image(allocator, texture.image, texture.allocation)
    }
    
	vk.DestroyDescriptorSetLayout(device, descriptor_set_layout_textures, nil)
	vk.DestroyDescriptorPool(device, descriptor_pool, nil)
	vk.DestroyPipelineLayout(device, pipeline_layout, nil)
	vk.DestroyPipeline(device, pipeline, nil)
	vk.DestroySwapchainKHR(device, swapchain, nil)
	vk.DestroySurfaceKHR(instance, surface, nil)
	vk.DestroyCommandPool(device, commandPool, nil)
	vk.DestroyShaderModule(device, shader_module, nil)
	vma.destroy_allocator(allocator)
	vk.DestroyDevice(device, nil)
	vk.DestroyInstance(instance, nil)
    
	sdl.DestroyWindow(window)
	sdl.QuitSubSystem({.VIDEO})
	sdl.Quit()
}
////////////////////////////////////////////////

vk_create_semaphore :: proc (device: vk.Device, flags: vk.SemaphoreCreateFlags = {}) -> vk.Semaphore {
    result: vk.Semaphore
    check(vk.CreateSemaphore(device, &vk.SemaphoreCreateInfo { sType = .SEMAPHORE_CREATE_INFO, flags = flags }, nil, &result))
    return result
}
vk_create_fence :: proc (device: vk.Device, flags: vk.FenceCreateFlags = {}) -> vk.Fence {
    result: vk.Fence
    check(vk.CreateFence(device, &vk.FenceCreateInfo { sType = .FENCE_CREATE_INFO, flags = flags }, nil, &result))
    return result
}

vk_create_depth_image :: proc (device: vk.Device, depth_format: vk.Format, window_size: uv2, allocator: vma.Allocator) -> (vk.Image, vk.ImageView, vma.Allocation) {
    image: vk.Image
    allocation: vma.Allocation
    image_view: vk.ImageView
    
    depth_image_create_info := vk.ImageCreateInfo {
        sType = .IMAGE_CREATE_INFO,
        imageType = .D2,
        format = depth_format,
        extent = { width = window_size.x, height = window_size.y, depth = 1 },
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
    
    depth_image_view_create_info := vk.ImageViewCreateInfo {
        sType = .IMAGE_VIEW_CREATE_INFO,
        image = image,
        viewType = .D2,
        format = depth_format,
        subresourceRange = { aspectMask = { .DEPTH }, levelCount = 1, layerCount = 1 },
    }
    check(vk.CreateImageView(device, &depth_image_view_create_info, nil, &image_view))
    
    return image, image_view, allocation
}

vk_recreate_swapchain :: proc (device: vk.Device, image_format: vk.Format, image_count: ^u32, swapchain_infos: ^#soa [dynamic] Swapchain_Info, swapchain: vk.SwapchainKHR) {
    check(vk.GetSwapchainImagesKHR(device, swapchain, image_count, nil))
    resize(swapchain_infos, image_count^)
    check(vk.GetSwapchainImagesKHR(device, swapchain, image_count, swapchain_infos.image))
    
    for &info in swapchain_infos {
        view_create_info := vk.ImageViewCreateInfo {
            sType = .IMAGE_VIEW_CREATE_INFO,
            image = info.image,
            viewType = .D2,
            format = image_format,
            subresourceRange = { aspectMask = { .COLOR }, levelCount = 1, layerCount = 1 },
        }
        
        check(vk.CreateImageView(device, &view_create_info, nil, &info.image_view))
        
        info.render_completed = vk_create_semaphore(device)
    }
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
check_vulkan :: proc (result: vk.Result, outofdate_recreates_swapchain := false, loc := #caller_location) {
    if result != .SUCCESS {
        if outofdate_recreates_swapchain == true && result == .ERROR_OUT_OF_DATE_KHR {
            recreate_swapchain = true
        } else {
            fmt.printf("%v:%v:%v: Vulkan call returned %v", loc.file_path, loc.line, loc.column, result)
            intrinsics.debug_trap()
            os.exit(1)
        }
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
	if slang.FAILED(result) {
		code := slang.GET_RESULT_CODE(result)
		facility := slang.GET_RESULT_FACILITY(result)
		estr: string
		switch slang.Result(result) {
		case:
			estr = "Unknown error"
		case slang.E_NOT_IMPLEMENTED():
			estr = "E_NOT_IMPLEMENTED"
		case slang.E_NO_INTERFACE():
			estr = "E_NO_INTERFACE"
		case slang.E_ABORT():
			estr = "E_ABORT"
		case slang.E_INVALID_HANDLE():
			estr = "E_INVALID_HANDLE"
		case slang.E_INVALID_ARG():
			estr = "E_INVALID_ARG"
		case slang.E_OUT_OF_MEMORY():
			estr = "E_OUT_OF_MEMORY"
		case slang.E_BUFFER_TOO_SMALL():
			estr = "E_BUFFER_TOO_SMALL"
		case slang.E_UNINITIALIZED():
			estr = "E_UNINITIALIZED"
		case slang.E_PENDING():
			estr = "E_PENDING"
		case slang.E_CANNOT_OPEN():
			estr = "E_CANNOT_OPEN"
		case slang.E_NOT_FOUND():
			estr = "E_NOT_FOUND"
		case slang.E_INTERNAL_FAIL():
			estr = "E_INTERNAL_FAIL"
		case slang.E_NOT_AVAILABLE():
			estr = "E_NOT_AVAILABLE"
		case slang.E_TIME_OUT():
			estr = "E_TIME_OUT"
		}

        fmt.printf("%v:%v:%v: slang call returned %v (%v) Facility: %v", loc.file_path, loc.line, loc.column, estr, code, facility)
        intrinsics.debug_trap()
        os.exit(1)
	}
}