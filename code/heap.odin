#+vet explicit-allocators
package main

import vk "../lib/vulkan"

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
    get_descriptor_sampler(gpu, .LINEAR, .LINEAR,  .REPEAT,        .WEIGHTED_AVERAGE, auto_cast &result.samplers_cpu[0 * sampler_descriptor_size], cast(u32) sampler_size);
    get_descriptor_sampler(gpu, .LINEAR, .NEAREST, .CLAMP_TO_EDGE, .WEIGHTED_AVERAGE, auto_cast &result.samplers_cpu[1 * sampler_descriptor_size], cast(u32) sampler_size);
    get_descriptor_sampler(gpu, .LINEAR, .NEAREST, .CLAMP_TO_EDGE, .MIN,              auto_cast &result.samplers_cpu[2 * sampler_descriptor_size], cast(u32) sampler_size);
    
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
        data = { pImage = &image_info }
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

get_descriptor_sampler :: proc (gpu: ^Gpu, filter: vk.Filter, mipmap_mode: vk.SamplerMipmapMode, address_mode: vk.SamplerAddressMode, reduction_mode: vk.SamplerReductionMode, descriptor: ^Descriptor, descriptor_size: u32) {
    info := xx_sampler(filter, mipmap_mode, address_mode)
    
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