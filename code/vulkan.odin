package main

import "base:runtime"
import "core:fmt"
import vk "vendor:vulkan"
import "../libs/vma"

vk_debug_utils_callback :: proc "system" (messageSeverity: vk.DebugUtilsMessageSeverityFlagsEXT, messageTypes: vk.DebugUtilsMessageTypeFlagsEXT, pCallbackData: ^vk.DebugUtilsMessengerCallbackDataEXT, pUserData: rawptr) -> b32 {
    context = runtime.default_context()
    if .WARNING in messageSeverity || .ERROR in messageSeverity {
        fmt.printfln("Validation Layer: %v", pCallbackData.pMessage)
    }
    return false
}

vk_get_swapchain_format :: proc (ips: IPS) -> vk.Format {
    format_count: u32
    // @study(viktor): GetPhysicalDeviceSurfaceFormats2KHR: would this help?
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

vk_create_swapchain :: proc (ips: IPS, device: vk.Device, window_size: uv2, format: vk.Format, infos: ^#soa [dynamic] Swapchain_Info, old_swapchain: vk.SwapchainKHR = 0) -> vk.SwapchainKHR {
    surface_capabilities: vk.SurfaceCapabilitiesKHR
    check(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(ips.physical_device, ips.surface, &surface_capabilities))
    
    swapchain_extent := surface_capabilities.currentExtent
    if surface_capabilities.currentExtent.width == 0xFFFFFFFF {
        swapchain_extent = vk_to_extent(window_size)
    }
    
    swapchain_create_info := vk.SwapchainCreateInfoKHR {
        sType = .SWAPCHAIN_CREATE_INFO_KHR,
        surface          = ips.surface,
        minImageCount    = surface_capabilities.minImageCount,
        imageFormat      = format,
        imageColorSpace  = .SRGB_NONLINEAR,
        imageExtent      = swapchain_extent,
        imageArrayLayers = 1,
        imageUsage       = { .COLOR_ATTACHMENT },
        preTransform     = { .IDENTITY },
        compositeAlpha   = { .OPAQUE },
        presentMode      = .FIFO,
        
        oldSwapchain = old_swapchain,
    }
    
    result: vk.SwapchainKHR
    check(vk.CreateSwapchainKHR(device, &swapchain_create_info, nil, &result))
    
    if old_swapchain != 0 {
        vk_destroy_swapchain(device, old_swapchain, infos)
    }
    
    image_count: u32
    check(vk.GetSwapchainImagesKHR(device, result, &image_count, nil))
    resize(infos, image_count)
    check(vk.GetSwapchainImagesKHR(device, result, &image_count, infos.image))
    
    for &info in infos {
        info.view = vk_create_2d_image_view(device, info.image, format, { .COLOR })
        info.render_completed = vk_create_semaphore(device)
    }
    
    return result
}

vk_destroy_swapchain :: proc (device: vk.Device, swapchain: vk.SwapchainKHR, infos: ^#soa [dynamic] Swapchain_Info) {
    for &info in infos {
        vk.DestroyImageView(device, info.view, nil)
        vk.DestroySemaphore(device, info.render_completed, nil)
    }
    clear(infos)
    vk.DestroySwapchainKHR(device, swapchain, nil)
}

// @cleanup this always happens after create_swapchain
vk_create_depth_image :: proc (device: vk.Device, depth_format: vk.Format, window_size: uv2, allocator: vma.Allocator) -> (vk.Image, vk.ImageView, vma.Allocation) {
    image: vk.Image
    allocation: vma.Allocation
    image_view: vk.ImageView
    
    depth_image_create_info := vk.ImageCreateInfo {
        sType = .IMAGE_CREATE_INFO,
        imageType = .D2,
        format = depth_format,
        extent = vk_to_extent(window_size, depth = 1),
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
    
    image_view = vk_create_2d_image_view(device, image, depth_format, { .DEPTH })
    
    return image, image_view, allocation
}

////////////////////////////////////////////////

vk_create_2d_image_view :: proc (device: vk.Device, image: vk.Image, format: vk.Format, aspect_mask: vk.ImageAspectFlags, level_count: u32 = 1) -> vk.ImageView {
    result: vk.ImageView
    
    check(vk.CreateImageView(device, &vk.ImageViewCreateInfo {
        sType = .IMAGE_VIEW_CREATE_INFO,
        image = image,
        viewType = .D2,
        format = format,
        subresourceRange = { aspectMask = aspect_mask, levelCount = level_count, layerCount = 1 },
    }, nil, &result))
    
    return result
}

vk_create_semaphore :: proc (device: vk.Device, flags: vk.SemaphoreCreateFlags = {}, timeline_initial_value: Maybe(u64) = nil) -> vk.Semaphore {
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

vk_create_fence :: proc (device: vk.Device, flags: vk.FenceCreateFlags = {}) -> vk.Fence {
    result: vk.Fence
    check(vk.CreateFence(device, &vk.FenceCreateInfo { sType = .FENCE_CREATE_INFO, flags = flags }, nil, &result))
    return result
}

////////////////////////////////////////////////

vk_to_extent :: proc { vk_to_extent_2, vk_to_extent_3 }
vk_to_extent_2 :: proc (size: uv2) -> vk.Extent2D {
    result := vk.Extent2D {
        width  = size.x, 
        height = size.y,
    }
    return result
}
vk_to_extent_3 :: proc (size: uv2, depth: u32) -> vk.Extent3D {
    result := vk.Extent3D {
        width  = size.x, 
        height = size.y,
        depth  = depth
    }
    return result
}
