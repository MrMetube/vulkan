#+vet explicit-allocators !unused-procedures
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

last_used_texture: Texture_Handle
textures:      [4096] Texture
texture_infos: [4096] vk.DeviceMemory

last_used_heap_index: u32 // @todo 

Texture :: struct {
    image:  vk.Image,
    
    sampled_index: u32,
    storage_index: u32,
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
    image, memory := gpu_allocate_texture(gpu, {kind, size, format, mip_count, sample_count, usage}, loc)
    
    last_used_texture += 1
    result := last_used_texture
    
    // @volatile
    sampled_index: u32
    storage_index: u32
    if .SAMPLED in usage {
        heap_index := last_used_heap_index
        last_used_heap_index += 1
        write_texture_to_heap(gpu, heap_index, image, format, .SAMPLED_IMAGE)
        sampled_index = heap_index
    }
    if .STORAGE in usage {
        heap_index := last_used_heap_index
        last_used_heap_index += 1
        write_texture_to_heap(gpu, heap_index, image, format, .STORAGE_IMAGE)
        storage_index = heap_index
    }
    
    textures[result] = {
        image  = image,
        sampled_index = sampled_index,
        storage_index = storage_index,
    }
    texture_infos[result] = memory
    
    return result
}

free_texture :: proc (gpu: ^Gpu, handle: Texture_Handle) {
    texture := get_texture(handle)
    memory  := get_texture_memory(handle)
    // @todo this should mark the slots as deleted and the pool should then delete memory.
    // This allows for suballocating textures if that is wanted.
    gpu_free_image(gpu, texture.image, memory^)
}

get_texture :: proc (handle: Texture_Handle) -> ^Texture {
    result := &textures[check_handle(handle, last_used_texture)]
    return result
}
get_texture_memory :: proc (handle: Texture_Handle) -> ^vk.DeviceMemory {
    result := &texture_infos[check_handle(handle, last_used_texture)]
    return result
}

check_handle :: proc (handle: Texture_Handle, cap: Texture_Handle) -> Texture_Handle {
    result: Texture_Handle
    if handle <= cap {
        result = handle
    }
    return result
}
