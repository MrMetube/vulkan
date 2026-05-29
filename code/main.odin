package main

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:strconv"
import "../libs/vma"
import "../libs/tobj"

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
    }
    
    vk.load_proc_addresses_instance(instance)
    
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
    
    device: vk.Device
    queue:  vk.Queue
    {
        queue_family_count: u32
        vk.GetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, nil)
        queue_family_properties := make([] vk.QueueFamilyProperties, queue_family_count)
        vk.GetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, raw_data(queue_family_properties))
        
        queue_family_index: u32
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

        vk.GetDeviceQueue(device, queue_family_index, 0, &queue)
    }
    
    surface: vk.SurfaceKHR
    check(sdl.Vulkan_CreateSurface(window, instance, &surface))
    
    window_size: [2] i32
    sdl.GetWindowSize(window, &window_size.x, &window_size.y)
    
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
    
    models, materials, error := tobj.load_obj("./tutorial/suzanne.obj")
    assert(error == nil)
    
}

check :: proc { check_vulkan, check_sdl }
check_vulkan :: proc (result: vk.Result, loc := #caller_location) {
    if result != .SUCCESS {
        fmt.printf("%v:%v:%v: Vulkan call returned %v", loc.file_path, loc.line, loc.column, result)
        intrinsics.debug_trap()
        os.exit(1)
    }
}
check_sdl :: proc (result: sdl.bool, loc := #caller_location) {
    if result != true {
        fmt.printf("%v:%v:%v: Vulkan call returned %v", loc.file_path, loc.line, loc.column, sdl.GetError())
        intrinsics.debug_trap()
        os.exit(1)
    }
}