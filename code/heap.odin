package main

import vk "vendor:vulkan"

DescriptorHeap :: struct {
    buffer: Buffer,
    gpu: vk.DeviceAddress,
    cpu: [] u8,
    layout: vk.DescriptorSetLayout,
    stride: int,
}

// @todo(viktor): this first draft is @slop. read the docs and do a second pass:
// https://docs.vulkan.org/refpages/latest/refpages/source/VK_EXT_descriptor_heap.html
gpu_set_active_texture_head_ptr :: proc (cmd: vk.CommandBuffer, heap: ^DescriptorHeap, set: u32) {
    binding_info := vk.DescriptorBufferBindingInfoEXT {
        sType = .DESCRIPTOR_BUFFER_BINDING_INFO_EXT,
        address = heap.gpu,
        usage   = { .RESOURCE_DESCRIPTOR_BUFFER_EXT },
    }
    vk.CmdBindDescriptorBuffersEXT(cmd, 1, &binding_info)
    
    buffer_index: u32
    offset: vk.DeviceSize
    vk.CmdSetDescriptorBufferOffsetsEXT(cmd, the_bound_pipeline.bind_point, the_bound_pipeline.layout, set, 1, &buffer_index, &offset)
}

create_descriptor_heap :: proc (gpu: ^Gpu, max_textures: u32) -> (heap: DescriptorHeap) {
    props := vk.PhysicalDeviceDescriptorBufferPropertiesEXT{
        sType = .PHYSICAL_DEVICE_DESCRIPTOR_BUFFER_PROPERTIES_EXT
    }
    
    device_props := vk.PhysicalDeviceProperties2 {
        sType = .PHYSICAL_DEVICE_PROPERTIES_2, 
        pNext = &props
    }
    vk.GetPhysicalDeviceProperties2(gpu.physical_device, &device_props)
    heap.stride = props.sampledImageDescriptorSize
    sampler_stride := props.samplerDescriptorSize
    
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
    
    var_size: vk.DeviceSize = 0
    vk.GetDescriptorSetLayoutSizeEXT(gpu.device, heap.layout, &var_size)
    size := cast(int)var_size
    
    cpu_ptr, gpu_addr := gpu_allocate_size(gpu, cast(umm) size, usage = { .RESOURCE_DESCRIPTOR_BUFFER_EXT })
    
    heap.cpu = slice_from_parts(u8, cpu_ptr, size)
    heap.gpu = gpu_addr
    
    return heap
}

write_texture_to_heap :: proc (gpu: ^Gpu, heap: ^DescriptorHeap, index: int, view: vk.ImageView, layout: vk.ImageLayout) {
    img_info := vk.DescriptorImageInfo{imageView = view, imageLayout = layout}
    get_info := vk.DescriptorGetInfoEXT {
        sType = .DESCRIPTOR_GET_INFO_EXT,
        type = .SAMPLED_IMAGE,
        data = vk.DescriptorDataEXT{ pSampledImage = &img_info },
    }
    
    dest_ptr := &heap.cpu[heap.stride * index]
    
    vk.GetDescriptorEXT(gpu.device, &get_info, auto_cast heap.stride, dest_ptr)
}
