#+vet explicit-allocators
package main

import "base:intrinsics"
import "core:os"
import "core:fmt"

import vk "vendor:vulkan"

import "../libs/tobj"
import "../libs/ktx"

Model :: struct {
    vertices: [] Vertex,
    indices:  [] i16,
    
    index_count: u32,
    v_buffer_size: vk.DeviceSize,
    i_buffer_size: vk.DeviceSize,
}

Vertex :: struct {
    p:  v3,
    n:  v3,
    uv: v2,
}

load_obj_model :: proc (filepath: string, allocator: Allocator) -> Model {
    models, _, error := tobj.load_obj_filename(filepath, allocator = allocator)
    assert(error == nil)
    model := models[0].mesh
    
    index_count := cast(u32) len(model.indices)
    vertices := make([] Vertex, index_count, allocator)
    indices  := make([] i16,  len(vertices), allocator)
    
    for index, it_index in model.indices {
        v := Vertex {
            p  = model.vertices[index]       * { 1, -1, 1 },
            n  = model.normals[index]        * { 1, -1, 1 },
            uv = model.texture_coords[index] * { 1, -1 },
        }
        
        vertices[it_index] = v
        indices[it_index]  = auto_cast it_index
    }
    
    v_buffer_size := cast(vk.DeviceSize) len(vertices) * size_of(vertices[0])
    i_buffer_size := cast(vk.DeviceSize) len(indices)  * size_of(indices[0])
    
    result: Model
    result.vertices = vertices
    result.indices = indices
    
    result.v_buffer_size = v_buffer_size
    result.i_buffer_size = i_buffer_size
    result.index_count = index_count
    
    return result
}

////////////////////////////////////////////////

Loaded_Texture :: struct {
    format: vk.Format,
    
    data: [] u8,
    
    width:  u32,
    height: u32,
    
    mip_levels: u32,
    mip_offsets: [] uint, // len == mip_levels
}

load_ktx_texture :: proc (filename: string, allocator: Allocator) -> Loaded_Texture {
    data, err := os.read_entire_file(filename, allocator); assert(err == nil)
    
    texture: ^ktx.Texture
    check(ktx.Texture_CreateFromMemory(&data[0], len(data), { .LOAD_IMAGE_DATA }, &texture))
    defer ktx.Texture1_Destroy(cast(^ktx.Texture1) texture)
    
    result: Loaded_Texture
    result.format = ktx.Texture_GetVkFormat(texture)
    
    result.data = make([] u8, texture.dataSize, allocator)
    copy(result.data, texture.pData[:texture.dataSize])
    
    result.width  = texture.baseWidth
    result.height = texture.baseHeight
    
    result.mip_levels = texture.numLevels
    result.mip_offsets = make([] uint, result.mip_levels, allocator)
    
    for &offset, level in result.mip_offsets {
        // @todo(viktor): this is not correct, is the Texture1 binding missing. This causes the mipmaps to be wrong.
        ktx.Texture2_GetImageOffset(cast(^ktx.Texture2) texture, cast(u32) level, 0, 0, &offset)
    }
    
    return result
}

check_ktx :: proc (result: ktx.Result, loc := #caller_location) {
    if result != .SUCCESS {
        fmt.printf("%v:%v:%v: KTX call returned %v", loc.file_path, loc.line, loc.column, result)
        intrinsics.debug_trap()
        os.exit(1)
    }
}
