#+vet explicit-allocators
package main

import vk "../lib/vulkan"

Bump_Allocator :: struct {
    allocation: GpuAllocation,
    
    data:   Gpu_Slice(u8),
    offset: u32,
}

bump_allocator_make_temporary :: proc (gpu: ^Gpu, size: u32, usage := vk.BufferUsageFlags{ .STORAGE_BUFFER }) -> Bump_Allocator {
    result: Bump_Allocator
    
    result.data       = gpu_allocate_slice(gpu, [] u8, size, usage = usage)
    result.allocation = gpu_reflect_get_allocation(result.data.gpu.p)
    
    return result
}

bump_free_all :: proc (bump: ^Bump_Allocator) {
    bump.offset = 0
}

bump_allocator_delete :: proc (gpu: ^Gpu, bump: ^Bump_Allocator) {
    gpu_free(gpu, bump.data)
    
    bump^ = {}
}

bump_allocate :: proc (bump: ^Bump_Allocator, size: u32, alignment: u32 = 16) -> (cpu: [] u8, gpu: vk.DeviceAddress) {
    bump.offset = align(alignment, bump.offset)
    
    assert(bump.offset + size < auto_cast len(bump.data.cpu))
    // Simple ring wrap (no overflow detection)
    // if bump.offset + size > auto_cast len(bump.cpu) { bump.offset = 0 }
    
    cpu = bump.data.cpu[bump.offset:][:size]
    gpu = bump.data.gpu.p + cast(vk.DeviceAddress) bump.offset
    
    gpu_reflect_set_allocation(gpu, bump.allocation, bump.offset)
    
    bump.offset += size
    
    return cpu, gpu
}

bump_allocate_type :: proc (bump: ^Bump_Allocator, $T: typeid) -> Gpu_Address(T) {
    cpu, gpu := bump_allocate(bump, size_of(T), align_of(T))
    
    result: Gpu_Address(T)
    result.cpu = cast(^T) &cpu[0]
    result.gpu.p = gpu
    
    return result
}

bump_allocate_slice :: proc (bump: ^Bump_Allocator, $T: typeid / [] $E, len: u32) -> Gpu_Slice(E) {
    size := size_of(E) * len
    cpu, gpu := bump_allocate(bump, size, align_of(E))
    
    result: Gpu_Slice(E)
    result.cpu = slice_from_parts(E, &cpu[0], len)
    result.gpu = { gpu }
    
    return result
}