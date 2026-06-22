package main

import vk "vendor:vulkan"

Bump_Allocator :: struct {
    cpu: [] u8,
    gpu: [] u8,
    
    offset: u32,
}

bump_allocator_make_temporary :: proc (gpu: ^Gpu, size: u32) -> Bump_Allocator {
    result: Bump_Allocator
    
    address: vk.DeviceAddress
    result.cpu, address = gpu_allocate_slice(gpu, [] u8, size)
    result.gpu = slice_from_parts(u8, transmute(pmm) address, size)
    
    return result
}

bump_allocator_delete :: proc (gpu: ^Gpu, bump: ^Bump_Allocator) {
    address := transmute(vk.DeviceAddress) &bump.gpu[0]
    gpu_free(gpu, address)
    
    bump^ = {}
}

bump_allocate :: proc (bump: ^Bump_Allocator, size: u32, alignment: u32 = 16) -> (cpu: [] u8, gpu: [] u8) {
    bump.offset = align(alignment, bump.offset)
    
    // Simple ring wrap (no overflow detection)
    if bump.offset + size > auto_cast len(bump.cpu) { bump.offset = 0 }
    
    cpu = bump.cpu[bump.offset:][:size]
    gpu = bump.gpu[bump.offset:][:size]
    
    bump.offset += size
    
    return cpu, gpu
}

bump_allocate_type :: proc (bump: ^Bump_Allocator, $T: typeid) -> (cpu: ^T, gpu: ^T) {
    cpu_bytes, gpu_bytes := bump_allocate(bump, size_of(T), align_of(T))
    cpu = cast(^T) &cpu_bytes[0]
    gpu = cast(^T) &gpu_bytes[0]
    return cpu, gpu
}

bump_allocate_slice :: proc (bump: ^Bump_Allocator, $T: typeid, len: u32) -> (cpu: ^T, gpu: ^T) {
    cpu_bytes, gpu_bytes := bump_allocate(bump, size_of(T) * len, align_of(T))
    cpu = slice_from_parts(T, &cpu_bytes[0], len)
    gpu = slice_from_parts(T, &gpu_bytes[0], len)
    return cpu, gpu
}