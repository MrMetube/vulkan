package main

import vk "vendor:vulkan"

Bump_Allocator :: struct {
    backing: GpuAllocation,
    
    cpu: [] u8,
    gpu: vk.DeviceAddress,
    
    offset: u32,
}

bump_allocator_make_temporary :: proc (gpu: ^Gpu, size: u32, usage := vk.BufferUsageFlags{ .STORAGE_BUFFER }) -> Bump_Allocator {
    result: Bump_Allocator
    
    gpu_slice: GpuSlice(u8)
    result.cpu, gpu_slice = gpu_allocate_slice(gpu, [] u8, size, usage = usage)
    result.gpu = gpu_slice.p
    
    result.backing = gpu_reflect_get_allocation(gpu_slice.p)
    
    return result
}

bump_free_all :: proc (bump: ^Bump_Allocator) {
    bump.offset = 0
}

bump_allocator_delete :: proc (gpu: ^Gpu, bump: ^Bump_Allocator) {
    gpu_free(gpu, bump.gpu)
    
    bump^ = {}
}

bump_allocate :: proc (bump: ^Bump_Allocator, size: u32, alignment: u32 = 16) -> (cpu: [] u8, gpu: vk.DeviceAddress) {
    bump.offset = align(alignment, bump.offset)
    
    assert(bump.offset + size < auto_cast len(bump.cpu))
    // Simple ring wrap (no overflow detection)
    // if bump.offset + size > auto_cast len(bump.cpu) { bump.offset = 0 }
    
    cpu = bump.cpu[bump.offset:][:size]
    gpu = bump.gpu + cast(vk.DeviceAddress) bump.offset
    
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

bump_allocate_slice :: proc (bump: ^Bump_Allocator, $T: typeid / [] $E, len: u32) -> (cpu: [] E, gpu: GpuSlice(E)) {
    size := size_of(E) * len
    cpu_bytes, gpu_bytes := bump_allocate(bump, size, align_of(E))
    cpu = slice_from_parts(E, &cpu_bytes[0], len)
    gpu = GpuSlice(E) { p = gpu_bytes, byte_size = cast(int) size }
    return cpu, gpu
}