#+vet explicit-allocators
package main

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:time"
import "core:mem"
import la "core:math/linalg"

import "../libs/vma"

import sdl "vendor:sdl3"
import vk "vendor:vulkan"

////////////////////////////////////////////////

Frame_Data :: struct {
    shader_data_buffer: Shader_Data_Buffer,
    command_buffer:     vk.CommandBuffer,
    image_aquired:      vk.Semaphore,
}

// @volatile shader.slang needs to match this layout
Shader_Data :: struct {
    projection: m4,
    view:       m4,
    model:      m4,
    light_pos:  [4] v4,
}

// @todo(viktor): move this to my allocator
Shader_Data_Buffer :: struct {
    allocation:      vma.Allocation,
    allocation_info: vma.Allocation_Info,
    
    buffer:        vk.Buffer,
    deviceAddress: vk.DeviceAddress,
}

Swapchain_Info :: struct {
    image: vk.Image,
    view:  vk.ImageView,
    
    render_completed: vk.Semaphore,
}

Texture :: struct {
	image: vk.Image,
	view:  vk.ImageView,
    
	allocation: vma.Allocation,
	sampler:    vk.Sampler,
}

recreate_swapchain: bool

// @naming
IPS :: struct {
    instance:        vk.Instance,
    physical_device: vk.PhysicalDevice,
    surface:         vk.SurfaceKHR,
}

////////////////////////////////////////////////

Mesh :: struct {
    vertices: [] Vertex,
    indices:  [] u16,
    
    meshlets: [dynamic] Meshlet,
}

// @volatile shader.slang needs to match this layout
Vertex :: struct {
    p:  v3,
    n:  [3] u8, _pad: u8,
    uv: v2,
}

// @todo(viktor): check the constraints of my actual hardware for this
Meshlet :: struct {
    vertices: [64] u32,
    indices:  [128-1-1] u8, // @note(viktor): this is done based on the niagra video series, which states that there can be atmost [128] u8 in total for indices and indices_count, we then drop 1 index to get a number divisible by 3
    index_count:  u8,
    vertex_count: u8,
}

////////////////////////////////////////////////

main :: proc () {
    check(sdl.InitSubSystem({ .VIDEO }))
    defer sdl.QuitSubSystem({ .VIDEO })
    defer sdl.Quit()
    
    window := sdl.CreateWindow("How to Vulkan", 1280, 720, sdl.WINDOW_VULKAN | sdl.WINDOW_RESIZABLE)
    check_sdl(window != nil)
    defer sdl.DestroyWindow(window)
    
    vk.GetInstanceProcAddr = auto_cast sdl.Vulkan_GetVkGetInstanceProcAddr()
    vk.load_proc_addresses_global(auto_cast vk.GetInstanceProcAddr)
    
    ////////////////////////////////////////////////
    
    ips: IPS
    {
        instance_extension_count: u32
        instance_extensions_raw := sdl.Vulkan_GetInstanceExtensions(&instance_extension_count)
        
        instance_extensions := make([dynamic] cstring, 0, instance_extension_count, context.temp_allocator)
        for i in 0..<instance_extension_count {
            append(&instance_extensions, instance_extensions_raw[i])
        }
        
        when ODIN_DEBUG {
            append(&instance_extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)
        }
        
        instance_create_info := vk.InstanceCreateInfo {
            sType = .INSTANCE_CREATE_INFO,
            pNext = &vk.DebugUtilsMessengerCreateInfoEXT {
                sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
                messageSeverity = { .VERBOSE, .WARNING, .ERROR },
                messageType = { .VALIDATION, .PERFORMANCE },
                pfnUserCallback = vk_debug_utils_callback,
            },
            pApplicationInfo = &vk.ApplicationInfo {
                sType = .APPLICATION_INFO,
                pApplicationName = "How to Vulkan",
                apiVersion = vk.API_VERSION_1_4,
            },
            enabledExtensionCount = auto_cast len(instance_extensions),
            ppEnabledExtensionNames = raw_data(instance_extensions),
        }
        
        when ODIN_DEBUG {
            validation_layers := []cstring{ "VK_LAYER_KHRONOS_validation" }
            instance_create_info.enabledLayerCount = auto_cast len(validation_layers)
            instance_create_info.ppEnabledLayerNames = raw_data(validation_layers)
        }
        
        check(vk.CreateInstance(&instance_create_info, nil, &ips.instance))
        
        vk.load_proc_addresses_instance(ips.instance)
    }
    
    ////////////////////////////////////////////////
    
    ips.physical_device = vk_choose_physical_device(ips)
    
    device_properties := vk.PhysicalDeviceProperties2 { sType = .PHYSICAL_DEVICE_PROPERTIES_2 }
    vk.GetPhysicalDeviceProperties2(ips.physical_device, &device_properties)
    fmt.printfln("Selected device: %v", cast(cstring) &device_properties.properties.deviceName[0])
    assert(device_properties.properties.limits.timestampComputeAndGraphics)
    
    ////////////////////////////////////////////////
    
    check(sdl.Vulkan_CreateSurface(window, ips.instance, nil, &ips.surface))
    
    window_size := sdl_get_window_size(window)
    
    ////////////////////////////////////////////////
    
    device: vk.Device
    queue_family_index: u32
    {
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
                !f11.shaderDrawParameters || !f11.storageBuffer16BitAccess || !f11.uniformAndStorageBuffer16BitAccess {
                fmt.printfln("Physical device doesn't meet the feauture requirements")
                check(false)
            }
        }
        
        device_extensions := [] cstring { 
            vk.KHR_SWAPCHAIN_EXTENSION_NAME,
            vk.KHR_PUSH_DESCRIPTOR_EXTENSION_NAME, // @todo(viktor): isn't this in 1.4?
            vk.EXT_MESH_SHADER_EXTENSION_NAME,
        }
        
        device_create_info := vk.DeviceCreateInfo {
            sType = .DEVICE_CREATE_INFO,
            
            pNext = &vk.PhysicalDeviceFeatures2 {
                sType = .PHYSICAL_DEVICE_FEATURES_2,
                
                features = {
                    samplerAnisotropy = true, // @note(viktor): since 1.4 this is required
                    shaderInt16 = true,
                },
                
            pNext = &vk.PhysicalDeviceVulkan14Features {
                sType = .PHYSICAL_DEVICE_VULKAN_1_4_FEATURES,
                
                maintenance5   = true, // @note(viktor): deprecates ShaderModule
                pushDescriptor = true, // @note(viktor): remove the need for CmdBindVertexBuffers
                
                // @todo(viktor): check if this would help the texture upload hostImageCopy
                // hostImageCopy = true,
                // @note(viktor): scalarBlockLayout - struct members are padded like c/c++ would, I assume it make simple memcopy possible
                
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
                
                shaderInt8 = true,
                uniformAndStorageBuffer8BitAccess = true,
                storageBuffer8BitAccess = true,
                
            pNext = &vk.PhysicalDeviceVulkan11Features {
                sType = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
                
                storageBuffer16BitAccess = true,
                uniformAndStorageBuffer16BitAccess = true,
                shaderDrawParameters = true,
                
            pNext = &vk.PhysicalDeviceMeshShaderFeaturesEXT {
                sType = .PHYSICAL_DEVICE_MESH_SHADER_FEATURES_EXT,
                
                meshShader = true,
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
    }
    
    queue: vk.Queue
    vk.GetDeviceQueue(device, queue_family_index, 0, &queue)
    
    ////////////////////////////////////////////////
    
    swapchain_format := vk_get_swapchain_format(ips)
    // @todo(viktor): move into swapchain structure along with its current size: uv2
    // @todo(viktor): dont ever use window_size, use swapchain.size
    swapchain_infos: #soa [dynamic] Swapchain_Info
    
    swapchain := vk_create_swapchain(ips, device, window_size, swapchain_format, &swapchain_infos)
    
    ////////////////////////////////////////////////
    
    allocator: vma.Allocator
    {
        vma_vulkan_functions := vma.create_vulkan_functions()
        
        allocator_create_info := vma.Allocator_Create_Info {
            flags            = { .Buffer_Device_Address },
            instance         = ips.instance,
            physical_device  = ips.physical_device,
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
            vk.GetPhysicalDeviceFormatProperties2(ips.physical_device, it, &format_properties)
            
            if .DEPTH_STENCIL_ATTACHMENT in format_properties.formatProperties.optimalTilingFeatures {
                depth_format = it
                break
            }
        }
        
        depth_image, depth_image_view, depth_image_allocation = vk_create_depth_image(device, depth_format, window_size, allocator)
    }
    
    ////////////////////////////////////////////////
    
    init_gpu_allocator(ips, device)
    
    ////////////////////////////////////////////////
    
    vertex_buffer  := gpu_make_buffer({ .STORAGE_BUFFER }, 128 * Megabyte)
    meshlet_buffer := gpu_make_buffer({ .STORAGE_BUFFER}, 128 * Megabyte)
    
    // @todo(viktor): currently we allocate twice, we could probably also allocate once and bind both buffers to the same memory, but I am unsure if that would help with anything.
    mesh: Mesh
    {
        mesh = load_mesh_from_obj("tutorial/suzanne.obj", context.temp_allocator)
        // mesh = load_obj_mesh("models/bunny.obj", context.temp_allocator)
        
        build_meshlets(&mesh)
        
        // @todo(viktor): store that we uploaded the mesh, once we have multiple and or different meshes per frame
        copy(vertex_buffer.data,  slice_to_bytes(mesh.vertices))
        copy(meshlet_buffer.data, slice_to_bytes(mesh.meshlets[:]))
    }
    
    ////////////////////////////////////////////////
    
    ////////////////////////////////////////////////
    
    shader_data: Shader_Data
    
    for &pos, index in shader_data.light_pos {
        t := clamp_01_to_range(cast(f32) 0, cast(f32) len(shader_data.light_pos), cast(f32) index)
        pos.xyz = v3{0, -10, 10}
        pos.xz += arm(t * Tau)
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
        frame.image_aquired = vk_create_semaphore(device)
    }
    
    ////////////////////////////////////////////////
    
    command_pool: vk.CommandPool
    {
        command_pool_create_info := vk.CommandPoolCreateInfo {
            sType = .COMMAND_POOL_CREATE_INFO,
            flags = { .RESET_COMMAND_BUFFER },
            queueFamilyIndex = queue_family_index,
        }
        
        check(vk.CreateCommandPool(device, &command_pool_create_info, nil, &command_pool))
        
        command_buffer_allocate_info := vk.CommandBufferAllocateInfo {
            sType = .COMMAND_BUFFER_ALLOCATE_INFO,
            commandPool = command_pool,
            commandBufferCount = len(frames.command_buffer),
        }
        check(vk.AllocateCommandBuffers(device, &command_buffer_allocate_info, &frames.command_buffer[0]))
    }
     
    textures: [3] Texture
    texture_descriptors: [len(textures)] vk.DescriptorImageInfo
    
    {
        for &texture, index in textures {
            filename := fmt.tprintf("tutorial/suzanne%v.ktx", index)
            
            loaded_texture := load_ktx_texture(filename, context.temp_allocator)
            
            // @cleanup use my allocator and then just copy by hand if possible
            image_create_info := vk.ImageCreateInfo {
                sType = .IMAGE_CREATE_INFO,
                imageType = .D2,
                format = loaded_texture.format,
                extent = { width = loaded_texture.width, height = loaded_texture.height, depth = 1 },
                mipLevels = loaded_texture.mip_levels,
                arrayLayers = 1,
                samples = { ._1 },
                tiling = .OPTIMAL,
                usage = { .TRANSFER_DST, .SAMPLED },
                initialLayout = .UNDEFINED,
            }
            
            image_allocation_create_info := vma.Allocation_Create_Info { usage = .Auto }
            check(vma.create_image(allocator, image_create_info, image_allocation_create_info, &texture.image, &texture.allocation, nil))
            
            texture.view = vk_create_2d_image_view(device, texture.image, image_create_info.format, { .COLOR }, loaded_texture.mip_levels)
            
            image_src_buffer: vk.Buffer
            image_src_allocation: vma.Allocation
            image_src_allocation_info: vma.Allocation_Info
            
            image_src_buffer_create_info := vk.BufferCreateInfo {
                sType = .BUFFER_CREATE_INFO,
                size  = auto_cast len(loaded_texture.data),
                usage = { .TRANSFER_SRC },
            }
            
            image_src_allocation_create_info := vma.Allocation_Create_Info {
                flags = { .Host_Access_Sequential_Write, .Mapped },
                usage = .Auto,
            }
            
            check(vma.create_buffer(allocator, image_src_buffer_create_info, image_src_allocation_create_info, &image_src_buffer, &image_src_allocation, &image_src_allocation_info))
            defer vma.destroy_buffer(allocator, image_src_buffer, image_src_allocation)
            
            mem.copy_non_overlapping(image_src_allocation_info.mapped_data, raw_data(loaded_texture.data), len(loaded_texture.data))
            
            fence_once := vk_create_fence(device)
            defer vk.DestroyFence(device, fence_once, nil)
            
            cb_once: vk.CommandBuffer
            cb_once_allocate_info := vk.CommandBufferAllocateInfo {
                sType = .COMMAND_BUFFER_ALLOCATE_INFO,
                commandPool = command_pool,
                commandBufferCount = 1,
            }
            check(vk.AllocateCommandBuffers(device, &cb_once_allocate_info, &cb_once))
            
            cb_once_begin_info := vk.CommandBufferBeginInfo {
                sType = .COMMAND_BUFFER_BEGIN_INFO,
                flags = { .ONE_TIME_SUBMIT },
            }
            check(vk.BeginCommandBuffer(cb_once, &cb_once_begin_info))
            
            
            vk_begin_transition_images()
                // @note(viktor): check if these src masks are correct
                vk_append_image_memory_barrier_2(texture.image, {}, {}, .UNDEFINED, {.TRANSFER }, { .TRANSFER_WRITE }, .TRANSFER_DST_OPTIMAL)
            vk_end_transition_images(cb_once)
            
            copy_regions := make([dynamic] vk.BufferImageCopy, context.temp_allocator)
            for level in 0..<loaded_texture.mip_levels {
                mip_offset: uint = loaded_texture.mip_offsets[level]
                
                append(&copy_regions, vk.BufferImageCopy{
                    bufferOffset = auto_cast mip_offset,
                    imageSubresource = { aspectMask = { .COLOR }, mipLevel = level, layerCount = 1 },
                    imageExtent = { width = loaded_texture.width >> level, height = loaded_texture.height >> level, depth = 1 },
                })
            }
            
            vk.CmdCopyBufferToImage(cb_once, image_src_buffer, texture.image, .TRANSFER_DST_OPTIMAL, auto_cast len(copy_regions), raw_data(copy_regions))
            
            vk_begin_transition_images()
                vk_append_image_memory_barrier_2(texture.image, {.TRANSFER }, { .TRANSFER_WRITE }, .TRANSFER_DST_OPTIMAL, { .FRAGMENT_SHADER }, { .SHADER_READ }, .READ_ONLY_OPTIMAL)
            vk_end_transition_images(cb_once)
            
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
                magFilter  = .LINEAR,
                minFilter  = .LINEAR,
                mipmapMode = .LINEAR,
                anisotropyEnable = true,
                maxAnisotropy = 8,
                maxLod = cast(f32) loaded_texture.mip_levels,
            }
            
            check(vk.CreateSampler(device, &sampler_create_info, nil, &texture.sampler))
            
            texture_descriptors[index] = vk.DescriptorImageInfo{ sampler = texture.sampler, imageView = texture.view, imageLayout = .READ_ONLY_OPTIMAL }
        }
    }
    
    ////////////////////////////////////////////////
    
    vertices_descriptor_set_layout: vk.DescriptorSetLayout
    {
        bindings := [?] vk.DescriptorSetLayoutBinding {
            {
                binding = 0,
                descriptorType = .STORAGE_BUFFER,
                descriptorCount = 1,
                stageFlags = { .MESH_EXT },
            },
            {
                binding = 1,
                descriptorType = .STORAGE_BUFFER,
                descriptorCount = 1,
                stageFlags = { .MESH_EXT },
            },
        }
        vertices_descriptor_layout_create_info := vk.DescriptorSetLayoutCreateInfo{
            sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            flags = { .PUSH_DESCRIPTOR },
            bindingCount = len(bindings),
            pBindings = &bindings[0],
        }
        
        check(vk.CreateDescriptorSetLayout(device, &vertices_descriptor_layout_create_info, nil, &vertices_descriptor_set_layout))
    }
    
    ////////////////////////////////////////////////
    
    textures_descriptor_set_layout: vk.DescriptorSetLayout
    textures_descriptor_set: vk.DescriptorSet
    textures_descriptor_pool: vk.DescriptorPool
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
                binding = 0,
                descriptorType = .COMBINED_IMAGE_SAMPLER,
                descriptorCount = len(textures),
                stageFlags = { .FRAGMENT },
            },
        }
        
        check(vk.CreateDescriptorSetLayout(device, &desc_layout_textures_create_info, nil, &textures_descriptor_set_layout))
        
        desc_pool_create_info := vk.DescriptorPoolCreateInfo {
            sType = .DESCRIPTOR_POOL_CREATE_INFO,
            maxSets = 1,
            poolSizeCount = 1,
            pPoolSizes = &vk.DescriptorPoolSize {
                type = .COMBINED_IMAGE_SAMPLER,
                descriptorCount = len(textures),
            },
        }
        
        check(vk.CreateDescriptorPool(device, &desc_pool_create_info, nil, &textures_descriptor_pool))
        
        variable_desc_count := cast(u32) len(textures)
        
        textures_desc_set_allocate_info := vk.DescriptorSetAllocateInfo {
            sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
            pNext = &vk.DescriptorSetVariableDescriptorCountAllocateInfo {
                sType = .DESCRIPTOR_SET_VARIABLE_DESCRIPTOR_COUNT_ALLOCATE_INFO,
                descriptorSetCount = 1,
                pDescriptorCounts = &variable_desc_count,
            },
            descriptorPool = textures_descriptor_pool,
            descriptorSetCount = 1,
            pSetLayouts = &textures_descriptor_set_layout,
        }
        
        check(vk.AllocateDescriptorSets(device, &textures_desc_set_allocate_info, &textures_descriptor_set))
        
        write_desc_set := vk.WriteDescriptorSet {
            sType = .WRITE_DESCRIPTOR_SET,
            dstSet = textures_descriptor_set,
            dstBinding = 0,
            descriptorCount = cast(u32) len(texture_descriptors),
            descriptorType = .COMBINED_IMAGE_SAMPLER,
            pImageInfo = &texture_descriptors[0],
        }
        vk.UpdateDescriptorSets(device, 1, &write_desc_set, 0, nil)
    }
    
    ////////////////////////////////////////////////
    
    pipeline, pipeline_layout := vk_create_graphics_pipeline(device, swapchain_format, depth_format, vertices_descriptor_set_layout, textures_descriptor_set_layout)
    
    ////////////////////////////////////////////////
    
    timeline_semaphore := vk_create_semaphore(device, timeline_initial_value = MaxFramesInFlight)
    
    ////////////////////////////////////////////////
    
    QueryPoolSize :: 128
    query_pool: vk.QueryPool
    {
        create_info := vk.QueryPoolCreateInfo {
            sType = .QUERY_POOL_CREATE_INFO,
            queryType = .TIMESTAMP,
            queryCount = QueryPoolSize,
        }
        check(vk.CreateQueryPool(device, &create_info, nil, &query_pool))
    }
    defer vk.DestroyQueryPool(device, query_pool, nil)
    
    ////////////////////////////////////////////////
    
    cam_pos := v3{ 0, 0, -6 }
    object_rotation: v3
    quit: bool
    last_time := time.tick_now()
    
    Timeout :: max(u64)
    
    absolute_frame_index: u64
    image_index: u32
    next_signal_value: u64 = MaxFramesInFlight + 1
    
    Smooth :: struct {
        value:      f64,
        last_value: f64,
    }

    smooth_update :: proc (frame_time: f64, smooth: ^Smooth, value: f64) {
        // @speed We could precompute ks if needed as it only depends on h and frame time, not the smooth itself.
        h :: 5.0 // = the amount of time it takes for the filter to converge to 90% of a fixed input value
        k := power(power(cast(f64) .1, 1 / h), frame_time)
        
        smooth.value = linear_blend(value, smooth.last_value, k)
        smooth.last_value = smooth.value
    }
        
    cpu_time: Smooth
    gpu_time: Smooth
    for !quit {
        free_all(context.temp_allocator)
        
        ////////////////////////////////////////////////
        
        // @todo(viktor): we currently include the time sdl.PollEvents and therefore windows window events take, which can just block us.
        current_time := time.tick_now()
        delta_tick := time.tick_diff(last_time, current_time)
        delta_time := cast(f32) time.duration_seconds(delta_tick)
        last_time = current_time
        
        ////////////////////////////////////////////////
        
        for event: sdl.Event; sdl.PollEvent(&event); {
            #partial switch event.type {
            case .QUIT:
                quit = true
            
            case .MOUSE_MOTION:
                if event.button.button == sdl.BUTTON_LEFT {
                    object_rotation.x -= event.motion.yrel * delta_time
                    object_rotation.y += event.motion.xrel * delta_time
                }
                
            case .MOUSE_WHEEL:
                cam_pos.z += event.wheel.y * 10 * delta_time
                
            case .WINDOW_RESIZED:
                recreate_swapchain = true
            }
        }
        
        ////////////////////////////////////////////////
        
        if recreate_swapchain {
            recreate_swapchain = false
            
            vk.DeviceWaitIdle(device)
            
            window_size = sdl_get_window_size(window)
            
            swapchain = vk_create_swapchain(ips, device, window_size, swapchain_format, &swapchain_infos, swapchain)
            
            vma.destroy_image(allocator, depth_image, depth_image_allocation)
            vk.DestroyImageView(device, depth_image_view, nil)
            depth_image, depth_image_view, depth_image_allocation = vk_create_depth_image(device, depth_format, window_size, allocator)
        }
        
        pipeline, pipeline_layout = vk_create_graphics_pipeline(device, swapchain_format, depth_format, vertices_descriptor_set_layout, textures_descriptor_set_layout, pipeline, pipeline_layout)
        
        ////////////////////////////////////////////////
        
        signal_value := next_signal_value
        next_signal_value += 1
        wait_value := signal_value - MaxFramesInFlight
        
        wait_info := vk.SemaphoreWaitInfo {
            sType = .SEMAPHORE_WAIT_INFO,
            semaphoreCount = 1,
            pSemaphores = &timeline_semaphore,
            pValues = &wait_value,
        }
        vk.WaitSemaphores(device, &wait_info, Timeout)
        
        frame := &frames[absolute_frame_index % MaxFramesInFlight]
        absolute_frame_index += 1
        
        acquire_result := vk.AcquireNextImageKHR(device, swapchain, Timeout, frame.image_aquired, {}, &image_index)
        if acquire_result == .ERROR_OUT_OF_DATE_KHR || acquire_result == .SUBOPTIMAL_KHR {
            recreate_swapchain = true
            continue
        }
        check(acquire_result)
        
        swapchain_info := &swapchain_infos[image_index]
        
        ////////////////////////////////////////////////
        
        query_results: [2] u64
        query_result := vk.GetQueryPoolResults(device, query_pool, 0, len(&query_results), cast(int) size_of_slice(query_results[:]), &query_results[0], size_of(query_results[0]), { ._64 } )
        
        if query_result != .NOT_READY {
            check(query_result)
            
            
            gpu_begin := cast(f64) query_results[0] * cast(f64) device_properties.properties.limits.timestampPeriod * 1e-9
            gpu_end   := cast(f64) query_results[1] * cast(f64) device_properties.properties.limits.timestampPeriod * 1e-9
            gpu_delta := gpu_end - gpu_begin
            // @note(viktor): this might have happened when a validation error occurred, causing the smooth value to be messed for a very long time
            if gpu_delta > 0 {
                smooth_update(cast(f64) delta_time, &gpu_time, gpu_delta)
            }
        }
        
        smooth_update(cast(f64) delta_time, &cpu_time, cast(f64) delta_time)
        
        xx :: proc (seconds: f64) -> time.Duration {
            return time.duration_round(cast(time.Duration) (seconds * cast(f64) time.Second), 1 * time.Microsecond)
        }
        sdl.SetWindowTitle(window, fmt.ctprintf("cpu time: %.3v, gpu time: %.3v, triangles: %v, meshlets: %v", xx(cpu_time.value), xx(gpu_time.value), view_magnitude(len(mesh.indices)), view_magnitude(len(mesh.meshlets))))
            
        ////////////////////////////////////////////////
        
        shader_data.projection = la.matrix4_perspective(45 * RadPerDeg, cast(f32) window_size.x / cast(f32) window_size.y, 0.1, 128)
        shader_data.view = la.matrix4_translate(cam_pos)
        instance_pos := v3{}
        shader_data.model = la.matrix4_translate(instance_pos) * la.matrix4_from_quaternion(la.quaternion_from_euler_angles_f32(expand_values(object_rotation), .XYX))
        
        mem.copy_non_overlapping(frame.shader_data_buffer.allocation_info.mapped_data, &shader_data, size_of(shader_data))
        
        ////////////////////////////////////////////////
        
        cb := frame.command_buffer
        check(vk.ResetCommandBuffer(cb, {}))
        
        cb_begin_info := vk.CommandBufferBeginInfo {
            sType = .COMMAND_BUFFER_BEGIN_INFO,
            flags = { .ONE_TIME_SUBMIT },
        }
        check(vk.BeginCommandBuffer(cb, &cb_begin_info))
        
        vk.CmdResetQueryPool(cb, query_pool, 0, QueryPoolSize)
        // @todo(viktor): make a basic region based profiler out of this the labels and shit
        vk.CmdWriteTimestamp(cb, { .BOTTOM_OF_PIPE }, query_pool, 0)
        
        vk_begin_transition_images()
            vk_append_image_memory_barrier_2(swapchain_info.image, { .COLOR_ATTACHMENT_OUTPUT }, {}, .UNDEFINED, { .COLOR_ATTACHMENT_OUTPUT }, { .COLOR_ATTACHMENT_READ, . COLOR_ATTACHMENT_WRITE }, .ATTACHMENT_OPTIMAL)
            vk_append_image_memory_barrier_2(depth_image, { .LATE_FRAGMENT_TESTS }, { .DEPTH_STENCIL_ATTACHMENT_WRITE }, .UNDEFINED, { .EARLY_FRAGMENT_TESTS }, { .DEPTH_STENCIL_ATTACHMENT_WRITE }, .ATTACHMENT_OPTIMAL, aspect_mask = { .DEPTH, .STENCIL })
        vk_end_transition_images(cb)
        
        ////////////////////////////////////////////////
        
        rendering_info := vk.RenderingInfo {
            sType = .RENDERING_INFO, 
            renderArea = { extent = vk_to_extent(window_size) },
            layerCount = 1,
            colorAttachmentCount = 1,
            pColorAttachments = &vk.RenderingAttachmentInfo {
                sType = .RENDERING_ATTACHMENT_INFO,
                imageView = swapchain_info.view,
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
        
        vk.CmdSetViewport(cb, 0, 1, &vk.Viewport {
            x      = 0,
            y      = 0,
            width  = cast(f32)  window_size.x,
            height = cast(f32)  window_size.y,
            minDepth = 0,
            maxDepth = 1,
        })
        
        vk.CmdSetScissor(cb, 0, 1, &vk.Rect2D { extent = vk_to_extent(window_size) })
        
        vk.CmdBindPipeline(cb, .GRAPHICS, pipeline)
        
        write_descriptor_sets := [?] vk.WriteDescriptorSet {
            {
                sType = .WRITE_DESCRIPTOR_SET,
                dstSet = 0,
                dstBinding = 0,
                descriptorType = .STORAGE_BUFFER,
                descriptorCount = 1,
                pBufferInfo     = &vk.DescriptorBufferInfo {
                    buffer = vertex_buffer.buffer,
                    offset = 0,
                    range  = auto_cast len(vertex_buffer.data),
                },
            },
            {
                sType = .WRITE_DESCRIPTOR_SET,
                dstSet = 0,
                dstBinding = 1,
                descriptorType = .STORAGE_BUFFER,
                descriptorCount = 1,
                pBufferInfo     = &vk.DescriptorBufferInfo {
                    buffer = meshlet_buffer.buffer,
                    offset = 0,
                    range  = auto_cast len(meshlet_buffer.data),
                },
            },
        }
        vk.CmdPushDescriptorSet(cb,  .GRAPHICS, pipeline_layout, 0, len(write_descriptor_sets), &write_descriptor_sets[0])
        vk.CmdBindDescriptorSets(cb, .GRAPHICS, pipeline_layout, 1, 1, &textures_descriptor_set, 0, nil)
        
        vk.CmdPushConstants(cb, pipeline_layout, { .MESH_EXT }, 0, size_of(vk.DeviceAddress), &frame.shader_data_buffer.deviceAddress)
        
        vk.CmdDrawMeshTasksEXT(cb, cast(u32) len(mesh.meshlets), 1, 1)
        
        vk.CmdEndRendering(cb)
        
        ////////////////////////////////////////////////
        
        vk_begin_transition_images()
            vk_append_image_memory_barrier_2(swapchain_info.image, { .COLOR_ATTACHMENT_OUTPUT }, { .COLOR_ATTACHMENT_WRITE }, .ATTACHMENT_OPTIMAL, {}, {}, .PRESENT_SRC_KHR)
        vk_end_transition_images(cb)
        
        vk.CmdWriteTimestamp(cb, { .BOTTOM_OF_PIPE }, query_pool, 1)
        
        vk.EndCommandBuffer(cb)
        
        ////////////////////////////////////////////////
        
        render_complete_and_timeline_submit_info := [] vk.SemaphoreSubmitInfo {
            {
                sType = .SEMAPHORE_SUBMIT_INFO,
                semaphore = swapchain_info.render_completed,
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
                stageMask = { .COLOR_ATTACHMENT_OUTPUT },
            },
            commandBufferInfoCount = 1,
            pCommandBufferInfos = &vk.CommandBufferSubmitInfo {
                sType = .COMMAND_BUFFER_SUBMIT_INFO,
                commandBuffer = frame.command_buffer,
            },
            signalSemaphoreInfoCount = auto_cast len(render_complete_and_timeline_submit_info),
            pSignalSemaphoreInfos = raw_data(render_complete_and_timeline_submit_info),
        }
        vk.QueueSubmit2(queue, 1, &submit_info, 0)
        
        ////////////////////////////////////////////////
        
        present_info := vk.PresentInfoKHR {
            sType = .PRESENT_INFO_KHR,
            waitSemaphoreCount = 1,
            pWaitSemaphores = &swapchain_info.render_completed,
            swapchainCount = 1,
            pSwapchains = &swapchain,
            pImageIndices = &image_index,
        }
        
        present_result := vk.QueuePresentKHR(queue, &present_info)
        if present_result == .ERROR_OUT_OF_DATE_KHR {
            recreate_swapchain = true
        } else {
            check(present_result)
        }
    }    
    
    ////////////////////////////////////////////////
    // Cleanup and Shutdown
    
	check(vk.DeviceWaitIdle(device))
    
    vk.DestroySemaphore(device, timeline_semaphore, nil)
    
    for frame in frames {
		vk.DestroySemaphore(device, frame.image_aquired, nil)
		vma.destroy_buffer(allocator, frame.shader_data_buffer.buffer, frame.shader_data_buffer.allocation)
    }
    
    vk_destroy_swapchain(device, swapchain, &swapchain_infos)
    
	vma.destroy_image(allocator, depth_image, depth_image_allocation)
	vk.DestroyImageView(device, depth_image_view, nil)
    gpu_delete_buffer(vertex_buffer)
    gpu_delete_buffer(meshlet_buffer)
    
    for texture in textures {
        vk.DestroyImageView(device, texture.view, nil)
        vk.DestroySampler(device, texture.sampler, nil)
        vma.destroy_image(allocator, texture.image, texture.allocation)
    }
    
    vk.DestroyDescriptorSetLayout(device, vertices_descriptor_set_layout, nil)
	vk.DestroyDescriptorSetLayout(device, textures_descriptor_set_layout, nil)
	
    vk.DestroyDescriptorPool(device, textures_descriptor_pool, nil)
    
    // @compression with create_graphics_pipeline
	vk.DestroyPipelineLayout(device, pipeline_layout, nil)
	vk.DestroyPipeline(device, pipeline, nil)
    
	vk.DestroyCommandPool(device, command_pool, nil)
	vma.destroy_allocator(allocator)
	vk.DestroyDevice(device, nil)
    
	vk.DestroySurfaceKHR(ips.instance, ips.surface, nil)
	vk.DestroyInstance(ips.instance, nil)
    
	sdl.DestroyWindow(window)
}

////////////////////////////////////////////////

sdl_get_window_size :: proc (window: ^sdl.Window) -> uv2 {
    result: iv2
    sdl.GetWindowSize(window, &result.x, &result.y)
    return cast(uv2) result
}

////////////////////////////////////////////////

check :: proc { check_vulkan, check_sdl, check_ktx }
check_vulkan :: proc (result: vk.Result, loc := #caller_location) {
    if result != .SUCCESS {
        fmt.printf("%v:%v:%v: Vulkan call returned %v", loc.file_path, loc.line, loc.column, result)
        intrinsics.debug_trap()
        os.exit(1)
    }
}
check_sdl :: proc (result: bool, loc := #caller_location) {
    if !result {
        fmt.printf("%v:%v:%v: SDL call returned %v", loc.file_path, loc.line, loc.column, sdl.GetError())
        intrinsics.debug_trap()
        os.exit(1)
    }
}