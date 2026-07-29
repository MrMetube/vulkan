package main

import vk "../lib/vulkan"

/* 

// @todo

Usage :: { VERTEX, UNIFORM, ... }
// named parameters and default values
create_buffer(debugname bytesize usage: Usage = ...) -> Handle(Buffer)
create_shader(
    debugName
    vs = { bytecode, entryFunctionName },
    ps = { bytecode, entryFunctionName },
    graphicsstate = {
        depthTest = COMPARE,
        // binding layouts <- we dont do that here
    }
) -> Handle(Shader)
*/

last_used_texture: u32
textures: [4096] Texture

last_used_heap_index: u32 // @todo 

Texture :: struct {
    // @todo split by access frequency
    image:  vk.Image,
    sampled_index: u32,
    storage_index: u32,
    
    memory: vk.DeviceMemory,
    
    format:    vk.Format,
    size:      uv3,
    mip_count: u32,
}

Texture_Handle :: distinct u32

create_texture :: proc (gpu: ^Gpu,
    kind:         vk.ImageType = .D2,
    size:         uv3 = 1,
    format:       Format = .UNDEFINED,
    mip_count:    u32 = 1,
    sample_count: u32 = 1,
    usage:        vk.ImageUsageFlags = {},
    
    loc := #caller_location,
) -> Texture_Handle {
    image := gpu_allocate_texture(gpu, {kind, size, format, mip_count, sample_count, usage}, loc)
    
    last_used_texture += 1
    index := last_used_texture
    slot  := &textures[index]
    
    // @volatile
    sampled_index: u32
    storage_index: u32
    if .SAMPLED in usage {
        heap_index := last_used_heap_index
        last_used_heap_index += 1
        write_texture_to_heap(gpu, heap_index, image, .SAMPLED_IMAGE)
        sampled_index = heap_index
    }
    if .STORAGE in usage {
        heap_index := last_used_heap_index
        last_used_heap_index += 1
        write_texture_to_heap(gpu, heap_index, image, .STORAGE_IMAGE)
        storage_index = heap_index
    }
    
    slot^ = {
        image = image.image,
        sampled_index = sampled_index,
        storage_index = storage_index,
        
        memory = image.memory,
        
        format    = image.format,
        size      = image.size,
        mip_count = image.mip_count,
    }
    
    result := cast(Texture_Handle) index
    return result
}

get_texture :: proc (handle: Texture_Handle) -> ^Texture {
    result: ^Texture
    if handle <= cast(Texture_Handle) last_used_texture {
        result = &textures[handle]
    }
    return result
}

free_texture :: proc (gpu: ^Gpu, handle: Texture_Handle) {
    texture := get_texture(handle)
    // @todo this should mark the slots as deleted and the pool should then delete memory.
    // This allows for suballocating textures if that is wanted.
    gpu_free_image(gpu, texture.image, texture.memory)
}