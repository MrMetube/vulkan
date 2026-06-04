#+vet explicit-allocators
package main

import "base:runtime"
import "core:fmt"

import vk "vendor:vulkan"
import sdl "vendor:sdl3"
import "lib:vma"

// @naming
IPS :: struct {
    instance:        vk.Instance,
    physical_device: vk.PhysicalDevice,
    surface:         vk.SurfaceKHR,
}

Swapchain :: struct {
    swapchain: vk.SwapchainKHR,
    infos: #soa [dynamic] Swapchain_Info,
    size:   uv2,
    format: vk.Format,
}

Swapchain_Info :: struct {
    image: vk.Image,
    view:  vk.ImageView,
    
    render_completed: vk.Semaphore,
}

Pipeline :: struct {
    pipeline: vk.Pipeline,
    layout:   vk.PipelineLayout,
    shader:   Shader,
}

Shader :: struct {
    stages: vk.ShaderStageFlags,
    bytes:  [] u8,
}

Image :: struct {
    image: vk.Image,
    view:  vk.ImageView,
    
    // optional
    format: vk.Format,
    
    allocation: vma.Allocation,
	sampler:    vk.Sampler,
}

Buffer :: struct {
    buffer: vk.Buffer,
    memory: vk.DeviceMemory,
    
    data: [] u8,
}

////////////////////////////////////////////////

to_be_destroyed_handles: [dynamic] Destroy_Info

Destroy_Info :: struct { 
    handle: vk.NonDispatchableHandle, 
    fn: proc (device: vk.Device, handle: vk.NonDispatchableHandle, pAllocator: ^vk.AllocationCallbacks),
}

mark_handle :: proc (fn: $F, handle: $T/ vk.NonDispatchableHandle, loc := #caller_location) {
    assert(handle != 0, loc = loc)
    append(&to_be_destroyed_handles, Destroy_Info { handle = auto_cast handle, fn = auto_cast fn })
}

destroy_all_handles :: proc (device: vk.Device) {
    #reverse for item in to_be_destroyed_handles {
        item.fn(device, item.handle, nil)
    }
}

////////////////////////////////////////////////

vk_choose_physical_device :: proc (ips: IPS) -> vk.PhysicalDevice {
    physical_devices: [] vk.PhysicalDevice
    {
        device_count: u32
        check(vk.EnumeratePhysicalDevices(ips.instance, &device_count, nil))
        physical_devices = make([] vk.PhysicalDevice, device_count, context.temp_allocator)
        check(vk.EnumeratePhysicalDevices(ips.instance, &device_count, raw_data(physical_devices)))
    }
    
    discrete: vk.PhysicalDevice
    fallback: vk.PhysicalDevice
    
    vk_get_family_index_with_graphics :: proc (device: vk.PhysicalDevice) -> u32 {
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
        family_index := vk_get_family_index_with_graphics(device)
        
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

vk_debug_utils_callback :: proc "system" (messageSeverity: vk.DebugUtilsMessageSeverityFlagsEXT, messageTypes: vk.DebugUtilsMessageTypeFlagsEXT, pCallbackData: ^vk.DebugUtilsMessengerCallbackDataEXT, pUserData: rawptr) -> b32 {
    context = runtime.default_context()
    if .WARNING in messageSeverity || .ERROR in messageSeverity {
        fmt.printfln("Validation Layer: %v", pCallbackData.pMessage)
    }
    return false
}

vk_get_swapchain_format :: proc (ips: IPS) -> vk.Format {
    format_count: u32
    // @study: GetPhysicalDeviceSurfaceFormats2KHR: would this help?
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

recreate_swapchain :: proc (ips: IPS, device: vk.Device, new_size: uv2, old_swapchain: ^Swapchain) {
    surface_capabilities: vk.SurfaceCapabilitiesKHR
    check(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(ips.physical_device, ips.surface, &surface_capabilities))
    
    swapchain_extent := surface_capabilities.currentExtent
    // @note(viktor): this is like for wayland or something, dont know if i want to maintain that any further
    if surface_capabilities.currentExtent.width == 0xFFFFFFFF {
        swapchain_extent = vk_to_extent(new_size)
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
        imageUsage       = { .COLOR_ATTACHMENT },
        preTransform     = { .IDENTITY },
        compositeAlpha   = { .OPAQUE },
        presentMode      = VSync ? .FIFO : .IMMEDIATE,
        
        oldSwapchain = old_swapchain.swapchain,
    }
    
    result: Swapchain
    result.size   = new_size
    result.format = old_swapchain.format
    result.infos  = old_swapchain.infos
    
    check(vk.CreateSwapchainKHR(device, &swapchain_create_info, nil, &result.swapchain))
    
    if old_swapchain.swapchain != 0 {
        destroy_swapchain(device, old_swapchain)
    }
    
    image_count: u32
    check(vk.GetSwapchainImagesKHR(device, result.swapchain, &image_count, nil))
    resize(&result.infos, image_count)
    check(vk.GetSwapchainImagesKHR(device, result.swapchain, &image_count, result.infos.image))
    
    for &info in result.infos {
        info.view = vk_create_2d_image_view(device, info.image, result.format, { .COLOR })
        info.render_completed = vk_create_semaphore(device)
    }
    
    old_swapchain ^= result
}

destroy_swapchain :: proc (device: vk.Device, swapchain: ^Swapchain) {
    for &info in swapchain.infos {
        vk.DestroyImageView(device, info.view, nil)
        vk.DestroySemaphore(device, info.render_completed, nil)
    }
    clear(&swapchain.infos)
    
    vk.DestroySwapchainKHR(device, swapchain.swapchain, nil)
}

// @cleanup this always happens after create_swapchain
vk_create_depth_image :: proc (device: vk.Device, window_size: uv2, allocator: vma.Allocator, result: ^Image) {
    depth_image_create_info := vk.ImageCreateInfo {
        sType = .IMAGE_CREATE_INFO,
        imageType = .D2,
        format = result.format,
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
    
    check(vma.create_image(allocator, depth_image_create_info, alloc_create_info, &result.image, &result.allocation, nil))
    
    result.view = vk_create_2d_image_view(device, result.image, result.format, { .DEPTH })
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

@(thread_local)
transition_state: struct {
    is_open:  bool,
    barriers: [dynamic] vk.ImageMemoryBarrier2,
}

vk_begin_transition_images :: proc () {
    assert(!transition_state.is_open)
    
    transition_state.is_open = true
}

vk_append_image_memory_barrier_2 :: proc (image: vk.Image, src_stage_mask: vk.PipelineStageFlags2, src_access_mask: vk.AccessFlags2, old_layout: vk.ImageLayout, dst_stage_mask: vk.PipelineStageFlags2, dst_access_mask: vk.AccessFlags2, new_layout: vk.ImageLayout, aspect_mask := vk.ImageAspectFlags { .COLOR }) {
    assert(transition_state.is_open)
    
    append(&transition_state.barriers, vk.ImageMemoryBarrier2 {
        sType = .IMAGE_MEMORY_BARRIER_2,
        srcStageMask  = src_stage_mask,
        srcAccessMask = src_access_mask,
        dstStageMask  = dst_stage_mask,
        dstAccessMask = dst_access_mask,
        oldLayout = old_layout,
        newLayout = new_layout,
        image = image,
        subresourceRange = { aspectMask = aspect_mask, levelCount = vk.REMAINING_MIP_LEVELS, layerCount = vk.REMAINING_ARRAY_LAYERS },
    })
}

vk_end_transition_images :: proc (command_buffer: vk.CommandBuffer) {
    assert(transition_state.is_open)
    
    vk.CmdPipelineBarrier2(command_buffer, &vk.DependencyInfo {
        sType = .DEPENDENCY_INFO,
        imageMemoryBarrierCount = auto_cast len(transition_state.barriers),
        pImageMemoryBarriers    = raw_data(transition_state.barriers),
    })
    
    clear(&transition_state.barriers)
    transition_state.is_open = false
}

////////////////////////////////////////////////

shader_source := "shader.slang"
shader_output := "shader.spirv"

should_recreate_pipeline :: proc (pipeline: Pipeline) -> bool {
    if pipeline.pipeline == 0 {
        return true
    }
    
    if is_newer(shader_source, shader_output) {
        return true
    }
    
    return false
}

create_graphics_pipeline :: proc (device: vk.Device, swapchain_format, depth_format: vk.Format, vertices_descriptor_set_layout, textures_descriptor_set_layout: vk.DescriptorSetLayout, old: Pipeline = {}) -> Pipeline {
    shader, ok := recompile_shader(shader_source, shader_output, context.temp_allocator)
    if !ok {
        if old.pipeline == 0 || old.layout == 0 {
            assert(false, "Failed to create graphics pipeline")
        }
        return old
    }
    
    shader_module_create_info := vk.ShaderModuleCreateInfo {
        sType = .SHADER_MODULE_CREATE_INFO,
        codeSize = len(shader.bytes),
        pCode    = cast(^u32) &shader.bytes[0],
    }
    
    ////////////////////////////////////////////////
    
    // @study: is a pipeline cache still a good optimization?
    result: Pipeline
    result.shader = shader
        
    set_layouts := [?] vk.DescriptorSetLayout {
        vertices_descriptor_set_layout,
        textures_descriptor_set_layout,
    }
    
    pipeline_layout_create_info := vk.PipelineLayoutCreateInfo {
        sType = .PIPELINE_LAYOUT_CREATE_INFO,
        setLayoutCount = len(set_layouts),
        pSetLayouts    = &set_layouts[0],
        pushConstantRangeCount = 1,
        pPushConstantRanges    = &vk.PushConstantRange {
            stageFlags = shader.stages,
            size       = size_of(vk.DeviceAddress),
        },
    }
    
    check(vk.CreatePipelineLayout(device, &pipeline_layout_create_info, nil, &result.layout))
    
    shader_stages: [dynamic; 16] vk.PipelineShaderStageCreateInfo
    for stage in shader.stages {
        append(&shader_stages, vk.PipelineShaderStageCreateInfo{ 
            sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, 
            stage = { stage }, 
            pName = "main", 
            pNext = &shader_module_create_info,
        })
    }
    
    dynamic_states := [] vk.DynamicState { .VIEWPORT, .SCISSOR }
    
    swapchain_format := swapchain_format
    
    pipeline_create_info := vk.GraphicsPipelineCreateInfo {
        sType = .GRAPHICS_PIPELINE_CREATE_INFO,
        pNext = &vk.PipelineRenderingCreateInfo {
            sType = .PIPELINE_RENDERING_CREATE_INFO,
            colorAttachmentCount = 1,
            pColorAttachmentFormats = &swapchain_format,
            depthAttachmentFormat = depth_format,
        },
        stageCount = auto_cast len(shader_stages),
        pStages    = &shader_stages[0],
        pVertexInputState = &vk.PipelineVertexInputStateCreateInfo { // @cleanup
            sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
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
            cullMode = { .BACK },
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
        layout = result.layout,
    }
    
    check(vk.CreateGraphicsPipelines(device, 0, 1,&pipeline_create_info, nil, &result.pipeline))
    
    check(vk.DeviceWaitIdle(device))
    
    destroy_pipeline(device, old)
    
    return result
}

destroy_pipeline :: proc (device: vk.Device, pipeline: Pipeline) {
    if pipeline.layout != 0 {
        vk.DestroyPipelineLayout(device, pipeline.layout, nil)
    }
    
    if pipeline.pipeline != 0 {
        vk.DestroyPipeline(device, pipeline.pipeline, nil)
    }
}

create_vertex_update_template :: proc (device: vk.Device, pipeline: Pipeline, old: vk.DescriptorUpdateTemplate = 0) -> vk.DescriptorUpdateTemplate {
    vk.DestroyDescriptorUpdateTemplate(device, old, nil)
    
    // @todo(viktor): The information of which shader stage needs which storage buffer could be parsed from the compiled spirv file.
    // But currently the single shader file contains multiple shader stages, so it would be non trivial to figure out which stage 
    // makes use of a binding. Otherwise we could just maximally bind buffers, so that we atleast never miss a required buffer.
    update_template_entries := [?] vk.DescriptorUpdateTemplateEntry {
        {
            dstBinding      = 0,
            descriptorType  = .STORAGE_BUFFER,
            descriptorCount = 1,
            offset          = 0 * size_of(DescriptorUpdateData),
            stride          = size_of(DescriptorUpdateData),
        },
        {
            dstBinding      = 1,
            descriptorType  = .STORAGE_BUFFER,
            descriptorCount = 1,
            offset          = 1 * size_of(DescriptorUpdateData),
            stride          = size_of(DescriptorUpdateData),
        },
        {
            dstBinding      = 2,
            descriptorType  = .STORAGE_BUFFER,
            descriptorCount = 1,
            offset          = 2 * size_of(DescriptorUpdateData),
            stride          = size_of(DescriptorUpdateData),
        },
    }
        
    create_info := vk.DescriptorUpdateTemplateCreateInfo {
        sType = .DESCRIPTOR_UPDATE_TEMPLATE_CREATE_INFO,
        pipelineBindPoint   = .GRAPHICS,
        pipelineLayout      = pipeline.layout,
        templateType        = .PUSH_DESCRIPTORS,
        descriptorUpdateEntryCount = len(update_template_entries),
        pDescriptorUpdateEntries   = &update_template_entries[0],
    }
    
    result: vk.DescriptorUpdateTemplate
    check(vk.CreateDescriptorUpdateTemplate(device, &create_info, nil, &result))
    return result
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
gpu_make_buffer_slice :: proc (usage: vk.BufferUsageFlags, $S: typeid / [] $E, #any_int len: umm) -> (Buffer, S) {
    size   := size_of(E) * len
    buffer := gpu_make_buffer_size(usage, size)
    view   := slice_from_parts(E, &buffer.data[0], len)
    return buffer, view
}
gpu_make_buffer_size :: proc (usage: vk.BufferUsageFlags, #any_int size: vk.DeviceSize) -> Buffer {
    assert(gpu_allocator_state.initialized)
    
    device := gpu_allocator_state.device
    memory_properties := gpu_allocator_state.memory_properties
    
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
        allocationSize = requirements.size,
        memoryTypeIndex = selected_memory_type_index,
    }
    
    info_for_device_address := vk.MemoryAllocateFlagsInfo {
        sType = .MEMORY_ALLOCATE_FLAGS_INFO,
        flags = { .DEVICE_ADDRESS },
    }
    if .SHADER_DEVICE_ADDRESS in usage {
        allocate_info.pNext = &info_for_device_address
    }
    
    check(vk.AllocateMemory(device, &allocate_info, nil, &result.memory))
    
    check(vk.BindBufferMemory(device, result.buffer, result.memory, 0))
    
    raw := cast(^RawSlice) &result.data
    raw.len = cast(int) size
    vk.MapMemory(device, result.memory, 0, size, {}, &raw.data)
    
    return result
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

gpu_delete_buffer :: proc (buffer: Buffer) {
    assert(gpu_allocator_state.initialized)
    device := gpu_allocator_state.device
    
    vk.FreeMemory(device,    buffer.memory, nil)
    vk.DestroyBuffer(device, buffer.buffer, nil)
}

////////////////////////////////////////////////

begin_rendering :: proc (cb: vk.CommandBuffer, swapchain: Swapchain, image_index: u32, depth_image: vk.Image, depth_image_view: vk.ImageView, clear_color: v4) {
    swapchain_info := &swapchain.infos[image_index]
    
    vk_begin_transition_images()
        vk_append_image_memory_barrier_2(swapchain_info.image, { .COLOR_ATTACHMENT_OUTPUT }, {}, .UNDEFINED, { .COLOR_ATTACHMENT_OUTPUT }, { .COLOR_ATTACHMENT_READ, . COLOR_ATTACHMENT_WRITE }, .ATTACHMENT_OPTIMAL)
        vk_append_image_memory_barrier_2(depth_image, { .LATE_FRAGMENT_TESTS }, { .DEPTH_STENCIL_ATTACHMENT_WRITE }, .UNDEFINED, { .EARLY_FRAGMENT_TESTS }, { .DEPTH_STENCIL_ATTACHMENT_WRITE }, .ATTACHMENT_OPTIMAL, aspect_mask = { .DEPTH, .STENCIL })
    vk_end_transition_images(cb)
    
    
    rendering_info := vk.RenderingInfo {
        sType = .RENDERING_INFO, 
        renderArea = { extent = vk_to_extent(swapchain.size) },
        layerCount = 1,
        colorAttachmentCount = 1,
        pColorAttachments = &vk.RenderingAttachmentInfo {
            sType = .RENDERING_ATTACHMENT_INFO,
            imageView = swapchain_info.view,
            imageLayout = .ATTACHMENT_OPTIMAL,
            loadOp = .CLEAR,
            storeOp = .STORE,
            clearValue = { color = { float32 = clear_color } },
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
    
    vk.CmdBeginRendering(cb, &rendering_info)
}

end_rendering :: proc (cb: vk.CommandBuffer, swapchain: Swapchain, image_index: u32) {
    swapchain_info := &swapchain.infos[image_index]
    
    vk.CmdEndRendering(cb)
    
    ////////////////////////////////////////////////
    
    vk_begin_transition_images()
        vk_append_image_memory_barrier_2(swapchain_info.image, { .COLOR_ATTACHMENT_OUTPUT }, { .COLOR_ATTACHMENT_WRITE }, .ATTACHMENT_OPTIMAL, {}, {}, .PRESENT_SRC_KHR)
    vk_end_transition_images(cb)
}

queue_submit :: proc (queue: vk.Queue, swapchain: Swapchain, frame: Frame_Data, image_index: u32, signal_value: u64, timeline_semaphore: vk.Semaphore) {
    swapchain_info := &swapchain.infos[image_index]
    
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
}

////////////////////////////////////////////////

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
        depth  = depth,
    }
    return result
}
