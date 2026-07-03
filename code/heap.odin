#+vet explicit-allocators
package main

import vk "../lib/vulkan"

Descriptor_Heap :: struct {
    cpu: [] u8,
    gpu: vk.DeviceAddress,
    
    layout: vk.DescriptorSetLayout, // @cleanup this is only used in creation. can we immediatly delete it afterwards?
    
    sampler_offset: int,
    sampler_stride: int,
    
    texture_offset: int,
    texture_stride: int,
}

// @todo(viktor): this first draft is @slop. read the docs and do a second pass:
// https://docs.vulkan.org/refpages/latest/refpages/source/VK_EXT_descriptor_heap.html

create_descriptor_heap :: proc (gpu: ^Gpu, max_textures: u32) -> (heap: Descriptor_Heap) {
    props := vk.PhysicalDeviceDescriptorBufferPropertiesEXT{
        sType = .PHYSICAL_DEVICE_DESCRIPTOR_BUFFER_PROPERTIES_EXT,
    }
    
    device_props := vk.PhysicalDeviceProperties2 {
        sType = .PHYSICAL_DEVICE_PROPERTIES_2, 
        pNext = &props,
    }
    vk.GetPhysicalDeviceProperties2(gpu.physical_device, &device_props)
    
    heap.sampler_stride = props.samplerDescriptorSize
    heap.texture_stride = props.sampledImageDescriptorSize
    
    bindings := [?] vk.DescriptorSetLayoutBinding {
        {
            binding = 0,
            descriptorType  = .SAMPLER,
            descriptorCount = 1,
            stageFlags      = { .FRAGMENT, .COMPUTE },
        },
        {
            binding = 1,
            descriptorType  = .SAMPLED_IMAGE,
            descriptorCount = max_textures,
            stageFlags      = { .FRAGMENT, .COMPUTE },
        },
    }
    
    // @cleanup is partially bound needed?
    flags := [2] vk.DescriptorBindingFlags { {}, { .PARTIALLY_BOUND } }
    flags_info := vk.DescriptorSetLayoutBindingFlagsCreateInfo {
        sType         = .DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO,
        bindingCount  = len(flags),
        pBindingFlags = &flags[0],
    }
    
    layout_info := vk.DescriptorSetLayoutCreateInfo {
        sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        pNext = &flags_info,
        flags = { .DESCRIPTOR_BUFFER_EXT },
        bindingCount = len(bindings),
        pBindings    = &bindings[0],
    }
    vk.CreateDescriptorSetLayout(gpu.device, &layout_info, nil, &heap.layout)
    
    sampler_offset: vk.DeviceSize
    texture_offset: vk.DeviceSize
    vk.GetDescriptorSetLayoutBindingOffsetEXT(gpu.device, heap.layout, 0, &sampler_offset)
    vk.GetDescriptorSetLayoutBindingOffsetEXT(gpu.device, heap.layout, 1, &texture_offset)
    heap.sampler_offset = cast(int) sampler_offset
    heap.texture_offset = cast(int) texture_offset
    
    device_size: vk.DeviceSize
    vk.GetDescriptorSetLayoutSizeEXT(gpu.device, heap.layout, &device_size)
    size := cast(int) device_size
    
    cpu_ptr, gpu_addr := gpu_allocate_size(gpu, cast(umm) size, usage = { .RESOURCE_DESCRIPTOR_BUFFER_EXT, .SAMPLER_DESCRIPTOR_BUFFER_EXT })
    
    heap.cpu = slice_from_parts(u8, cpu_ptr, size)
    heap.gpu = gpu_addr
    
    return heap
}

destroy_descriptor_heap :: proc (gpu: ^Gpu, heap: Descriptor_Heap) {
    gpu_free_pointer(gpu, heap.gpu)
    vk.DestroyDescriptorSetLayout(gpu.device, heap.layout, nil)
}

write_texture_to_heap :: proc (gpu: ^Gpu, heap: ^Descriptor_Heap, index: int, view: vk.ImageView, layout: vk.ImageLayout) {
    info := vk.DescriptorImageInfo { imageView = view, imageLayout = layout }
    
    get_info := vk.DescriptorGetInfoEXT {
        sType = .DESCRIPTOR_GET_INFO_EXT,
        type = .SAMPLED_IMAGE,
        data = vk.DescriptorDataEXT{ pSampledImage = &info },
    }
    
    texture_pointer := &heap.cpu[heap.texture_offset + heap.texture_stride * index]
    
    vk.GetDescriptorEXT(gpu.device, &get_info, heap.texture_stride, texture_pointer)
}

write_global_sampler_to_heap :: proc (gpu: ^Gpu, heap: ^Descriptor_Heap, sampler: vk.Sampler) {
    sampler := sampler
    
    get_info := vk.DescriptorGetInfoEXT {
        sType = .DESCRIPTOR_GET_INFO_EXT,
        type  = .SAMPLER,
        data  = vk.DescriptorDataEXT{ pSampler = &sampler },
    }
    
    index := 0
    sampler_pointer := &heap.cpu[heap.sampler_offset + heap.sampler_stride * index]
    
    vk.GetDescriptorEXT(gpu.device, &get_info, heap.sampler_stride, sampler_pointer)
}

gpu_set_active_texture_head :: proc (cmd: vk.CommandBuffer, heap: ^Descriptor_Heap, set: u32) {
    binding_info := vk.DescriptorBufferBindingInfoEXT {
        sType = .DESCRIPTOR_BUFFER_BINDING_INFO_EXT,
        address = heap.gpu,
        usage   = { .RESOURCE_DESCRIPTOR_BUFFER_EXT, .SAMPLER_DESCRIPTOR_BUFFER_EXT },
    }
    vk.CmdBindDescriptorBuffersEXT(cmd, 1, &binding_info)
    
    buffer_index: u32
    offset: vk.DeviceSize
    vk.CmdSetDescriptorBufferOffsetsEXT(cmd, the_bound_pipeline.bind_point, the_bound_pipeline.layout, set, 1, &buffer_index, &offset)
}
