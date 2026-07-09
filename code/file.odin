#+vet explicit-allocators
package main

import "base:intrinsics"
import "core:os"
import "core:fmt"

import vk "../lib/vulkan"

import "../lib/ktx"

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
    check_ktx(ktx.Texture_CreateFromMemory(&data[0], len(data), { .LOAD_IMAGE_DATA }, &texture))
    defer ktx.Texture1_Destroy(cast(^ktx.Texture1) texture)
    
    result: Loaded_Texture
    result.format = auto_cast ktx.Texture_GetVkFormat(texture)
    
    result.data = make([] u8, texture.dataSize, allocator)
    copy(result.data, texture.pData[:texture.dataSize])
    
    result.width  = texture.baseWidth
    result.height = texture.baseHeight
    
    result.mip_levels = texture.numLevels
    result.mip_offsets = make([] uint, result.mip_levels, allocator)
    
    for &offset, level in result.mip_offsets {
        // @todo this is not correct, is the Texture1 binding missing. This causes the mipmaps to be wrong.
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
