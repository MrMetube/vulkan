#+vet explicit-allocators
package main

import "base:intrinsics"
import "core:os"
import "core:fmt"
import win "core:sys/windows"

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

////////////////////////////////////////////////

load_dds_texture :: proc (file_data: [] u8) -> (Texture_Desc, [] u8) {
    DDS_HEADER :: struct #packed {
        dwSize:              win.DWORD,
        dwFlags:             win.DWORD,
        dwHeight:            win.DWORD,
        dwWidth:             win.DWORD,
        dwPitchOrLinearSize: win.DWORD,
        dwDepth:             win.DWORD,
        dwMipMapCount:       win.DWORD,
        dwReserved1:         [11]win.DWORD,
        ddspf:               DDS_PIXELFORMAT,
        dwCaps:              win.DWORD,
        dwCaps2:             win.DWORD,
        dwCaps3:             win.DWORD,
        dwCaps4:             win.DWORD,
        dwReserved2:         win.DWORD,
    }
    
    DDS_PIXELFORMAT :: struct #packed {
        dwSize:        win.DWORD,
        dwFlags:       win.DWORD,
        dwFourCC:      win.DWORD,
        dwRGBBitCount: win.DWORD,
        dwRBitMask:    win.DWORD,
        dwGBitMask:    win.DWORD,
        dwBBitMask:    win.DWORD,
        dwABitMask:    win.DWORD,
    }
    
    DDS_HEADER_DXT10 :: struct #packed {
        dxgiFormat:        DXGI_FORMAT,
        resourceDimension: D3D10_RESOURCE_DIMENSION,
        miscFlag:          win.UINT,
        arraySize:         win.UINT,
        miscFlags2:        win.UINT,
    }
    
    DXGI_FORMAT :: enum win.UINT {
        UNKNOWN = 0,
        R32G32B32A32_TYPELESS = 1,
        R32G32B32A32_FLOAT = 2,
        R32G32B32A32_UINT = 3,
        R32G32B32A32_SINT = 4,
        R32G32B32_TYPELESS = 5,
        R32G32B32_FLOAT = 6,
        R32G32B32_UINT = 7,
        R32G32B32_SINT = 8,
        R16G16B16A16_TYPELESS = 9,
        R16G16B16A16_FLOAT = 10,
        R16G16B16A16_UNORM = 11,
        R16G16B16A16_UINT = 12,
        R16G16B16A16_SNORM = 13,
        R16G16B16A16_SINT = 14,
        R32G32_TYPELESS = 15,
        R32G32_FLOAT = 16,
        R32G32_UINT = 17,
        R32G32_SINT = 18,
        R32G8X24_TYPELESS = 19,
        D32_FLOAT_S8X24_UINT = 20,
        R32_FLOAT_X8X24_TYPELESS = 21,
        X32_TYPELESS_G8X24_UINT = 22,
        R10G10B10A2_TYPELESS = 23,
        R10G10B10A2_UNORM = 24,
        R10G10B10A2_UINT = 25,
        R11G11B10_FLOAT = 26,
        R8G8B8A8_TYPELESS = 27,
        R8G8B8A8_UNORM = 28,
        R8G8B8A8_UNORM_SRGB = 29,
        R8G8B8A8_UINT = 30,
        R8G8B8A8_SNORM = 31,
        R8G8B8A8_SINT = 32,
        R16G16_TYPELESS = 33,
        R16G16_FLOAT = 34,
        R16G16_UNORM = 35,
        R16G16_UINT = 36,
        R16G16_SNORM = 37,
        R16G16_SINT = 38,
        R32_TYPELESS = 39,
        D32_FLOAT = 40,
        R32_FLOAT = 41,
        R32_UINT = 42,
        R32_SINT = 43,
        R24G8_TYPELESS = 44,
        D24_UNORM_S8_UINT = 45,
        R24_UNORM_X8_TYPELESS = 46,
        X24_TYPELESS_G8_UINT = 47,
        R8G8_TYPELESS = 48,
        R8G8_UNORM = 49,
        R8G8_UINT = 50,
        R8G8_SNORM = 51,
        R8G8_SINT = 52,
        R16_TYPELESS = 53,
        R16_FLOAT = 54,
        D16_UNORM = 55,
        R16_UNORM = 56,
        R16_UINT = 57,
        R16_SNORM = 58,
        R16_SINT = 59,
        R8_TYPELESS = 60,
        R8_UNORM = 61,
        R8_UINT = 62,
        R8_SNORM = 63,
        R8_SINT = 64,
        A8_UNORM = 65,
        R1_UNORM = 66,
        R9G9B9E5_SHAREDEXP = 67,
        R8G8_B8G8_UNORM = 68,
        G8R8_G8B8_UNORM = 69,
        BC1_TYPELESS = 70,
        BC1_UNORM = 71,
        BC1_UNORM_SRGB = 72,
        BC2_TYPELESS = 73,
        BC2_UNORM = 74,
        BC2_UNORM_SRGB = 75,
        BC3_TYPELESS = 76,
        BC3_UNORM = 77,
        BC3_UNORM_SRGB = 78,
        BC4_TYPELESS = 79,
        BC4_UNORM = 80,
        BC4_SNORM = 81,
        BC5_TYPELESS = 82,
        BC5_UNORM = 83,
        BC5_SNORM = 84,
        B5G6R5_UNORM = 85,
        B5G5R5A1_UNORM = 86,
        B8G8R8A8_UNORM = 87,
        B8G8R8X8_UNORM = 88,
        R10G10B10_XR_BIAS_A2_UNORM = 89,
        B8G8R8A8_TYPELESS = 90,
        B8G8R8A8_UNORM_SRGB = 91,
        B8G8R8X8_TYPELESS = 92,
        B8G8R8X8_UNORM_SRGB = 93,
        BC6H_TYPELESS = 94,
        BC6H_UF16 = 95,
        BC6H_SF16 = 96,
        BC7_TYPELESS = 97,
        BC7_UNORM = 98,
        BC7_UNORM_SRGB = 99,
        AYUV = 100,
        Y410 = 101,
        Y416 = 102,
        NV12 = 103,
        P010 = 104,
        P016 = 105,
        _420_OPAQUE = 106,
        YUY2 = 107,
        Y210 = 108,
        Y216 = 109,
        NV11 = 110,
        AI44 = 111,
        IA44 = 112,
        P8 = 113,
        A8P8 = 114,
        B4G4R4A4_UNORM = 115,
        P208 = 130,
        V208 = 131,
        V408 = 132,
        SAMPLER_FEEDBACK_MIN_MIP_OPAQUE = 189,
        SAMPLER_FEEDBACK_MIP_REGION_USED_OPAQUE = 190,
        A4B4G4R4_UNORM = 191,
        FORCE_UINT = 0xffffffff
    }
    
    D3D10_RESOURCE_DIMENSION :: enum win.UINT {
        UNKNOWN = 0,
        BUFFER = 1,
        TEXTURE1D = 2,
        TEXTURE2D = 3,
        TEXTURE3D = 4
    }
    
    DDCAPS2_CUBEMAP :: 0x200
    DDCAPS2_VOLUME  :: 0x200000
    
    buffer := make_byte_buffer(file_data)
    buffer.write_cursor = len(file_data)
    
    magic := read_string(&buffer, 4)
    assert(magic == "DDS ")
    
    header := read(&buffer, DDS_HEADER)
    assert(header.dwSize == size_of(header^))
    
    format4cc := string_from_parts(&header.ddspf.dwFourCC, 4)
    
    // @todo properly handle different texture kinds and formats
    
    header10: ^DDS_HEADER_DXT10
    if format4cc == "DX10" {
        read_into(&buffer, &header10)
        assert(header10.resourceDimension == .TEXTURE2D)
    }
    
    assert(header.dwCaps2 != DDCAPS2_CUBEMAP)
    assert(header.dwCaps2 != DDCAPS2_VOLUME)
    
    description := default_texture_desc(
        size      = { header.dwWidth, header.dwHeight, 1 },
        mip_count = header.dwMipMapCount,
        usage     = { .TRANSFER_DST, .SAMPLED },
    )
    
    switch format4cc {
    case "DXT1": description.format = .BC1_RGBA_UNORM_BLOCK
    case "DXT3": description.format = .BC2_UNORM_BLOCK
    case "DXT5": description.format = .BC3_UNORM_BLOCK
    case "DX10":
        #partial switch header10.dxgiFormat {
        case .BC1_UNORM, .BC1_UNORM_SRGB: description.format = .BC1_RGB_UNORM_BLOCK
        case .BC2_UNORM, .BC2_UNORM_SRGB: description.format = .BC2_UNORM_BLOCK
        case .BC3_UNORM, .BC3_UNORM_SRGB: description.format = .BC3_UNORM_BLOCK
        case .BC4_UNORM:                  description.format = .BC4_UNORM_BLOCK
        case .BC4_SNORM:                  description.format = .BC4_SNORM_BLOCK
        case .BC5_UNORM:                  description.format = .BC5_UNORM_BLOCK
        case .BC5_SNORM:                  description.format = .BC5_SNORM_BLOCK
        case .BC6H_UF16:                  description.format = .BC6H_UFLOAT_BLOCK
        case .BC6H_SF16:                  description.format = .BC6H_SFLOAT_BLOCK
        case .BC7_UNORM, .BC7_UNORM_SRGB: description.format = .BC7_UNORM_BLOCK
        }
    }
    assert(description.format != .UNDEFINED)
    
    block_size := 16
    #partial switch description.format {
    case .BC1_RGBA_UNORM_BLOCK, .BC4_SNORM_BLOCK, .BC4_UNORM_BLOCK: block_size = 8
    }
    
    pixel_size: int
    mip_size := description.size.xy
    for level in 0..<description.mip_count {
        blocks := (mip_size + 3) / 4
        pixel_size += cast(int) blocks.x * cast(int) blocks.y * block_size
        
        mip_size = vec_max(mip_size/2, 1)
    }
    
    pixel_data := read_slice(&buffer, [] u8, pixel_size)
    
    assert(read_everything(buffer))
    
    return description, pixel_data
}
