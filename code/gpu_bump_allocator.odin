package main

import vk "vendor:vulkan"

Bump_Allocator :: struct {
    backing: Buffer,
    
    cpu: [] u8,
    gpu: [] u8,
    
    offset: u32,
}

bump_allocator_make_temporary :: proc (gpu: ^Gpu, size: u32, usage := vk.BufferUsageFlags{ .STORAGE_BUFFER }) -> Bump_Allocator {
    result: Bump_Allocator
    
    gpu_slice: GpuSlice(u8)
    result.cpu, gpu_slice = gpu_allocate_slice(gpu, [] u8, size, usage = usage)
    result.gpu = slice_from_parts(u8, transmute(pmm) gpu_slice, size)
    
    result.backing, _ = gpu_reflect_get_buffer(gpu_slice.p)
    
    return result
}

bump_free_all :: proc (bump: ^Bump_Allocator) {
    bump.offset = 0
}

bump_allocator_delete :: proc (gpu: ^Gpu, bump: ^Bump_Allocator) {
    address := transmute(vk.DeviceAddress) &bump.gpu[0]
    gpu_free(gpu, address)
    
    bump^ = {}
}

bump_allocate :: proc (bump: ^Bump_Allocator, size: u32, alignment: u32 = 16) -> (cpu: [] u8, gpu: vk.DeviceAddress) {
    bump.offset = align(alignment, bump.offset)
    
    // Simple ring wrap (no overflow detection)
    if bump.offset + size > auto_cast len(bump.cpu) { bump.offset = 0 }
    
    cpu = bump.cpu[bump.offset:][:size]
    gpu = transmute(vk.DeviceAddress) &bump.gpu[bump.offset]
    
    gpu_reflect_set_allocation(gpu, bump.backing, bump.offset)
    
    bump.offset += size
    
    return cpu, gpu
}

gpu_size_of :: proc (x: $G / GpuAddress($T)) -> vk.DeviceSize {
    return size_of(T)
}

bump_allocate_type :: proc (bump: ^Bump_Allocator, $T: typeid) -> (cpu: ^T, gpu: GpuAddress(T)) {
    cpu_bytes, gpu_bytes := bump_allocate(bump, size_of(T), align_of(T))
    cpu = cast(^T) &cpu_bytes[0]
    gpu.p = gpu_bytes
    return cpu, gpu
}

bump_allocate_slice :: proc (bump: ^Bump_Allocator, $T: typeid, len: u32) -> (cpu: ^T, gpu: ^T) {
    cpu_bytes, gpu_bytes := bump_allocate(bump, size_of(T) * len, align_of(T))
    cpu = slice_from_parts(T, &cpu_bytes[0], len)
    gpu = slice_from_parts(T, &gpu_bytes[0], len)
    return cpu, gpu
}