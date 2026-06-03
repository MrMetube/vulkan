#+vet explicit-allocators
package main

import "base:intrinsics"
import "core:os"
import "core:fmt"

import vk "vendor:vulkan"

import "lib:tobj"
import "lib:ktx"

load_mesh_from_obj :: proc (filepath: string, allocator: Allocator) -> Mesh {
    models, _, error := tobj.load_obj_filename(filepath, allocator = allocator)
    assert(error == nil)
    model := models[0].mesh
    
    vertices := make([] Vertex, len(model.vertices), allocator)
    
    has_uvs := len(model.texture_coords) != 0
    
    for &v, index in vertices {
        n := model.normals[index]  * { 1, -1, 1 }
        p := model.vertices[index] * { 1, -1, 1 }
        
        v = Vertex {
            p  = p,
            n  = cast([3] u8) ((n + 1) * 127),
            uv = has_uvs ? model.texture_coords[index] * { 1, -1 } : 0,
        }
    }
    
    
    result: Mesh
    result.vertices = vertices
    result.indices  = make_shallow_copy(model.indices[:], allocator)
    
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
