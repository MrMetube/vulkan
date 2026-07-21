#+vet explicit-allocators
package main

import la "core:math/linalg"
import vk "../lib/vulkan"

// Required by the spec for acceleration structures. The scratch could have a smaller alignment
// requirement, but it's only a small waste.
@(private="file")
AccelerationStructureAlignment :: 256 

Acceleration_Structure :: struct {
    acceleration_structure: vk.AccelerationStructureKHR,
    address:                vk.DeviceAddress,
}

// @placement what of this is part of gpu.odin and what is from my app

build_bottom_level_acceleration_structures :: proc (gpu: ^Gpu, queue: vk.Queue, command_pool: vk.CommandPool, buffers: ^Buffers, geometry: Geometry, permanent, scratch: Allocator) -> [] Acceleration_Structure {
    LOD_Index :: 0
    
    triangle_counts := make([] u32, len(geometry.meshes), scratch)
    
    build_infos     := make([] vk.AccelerationStructureBuildGeometryInfoKHR, len(geometry.meshes), scratch)
    build_offsets   := make([] umm,                                          len(geometry.meshes), scratch)
    scratch_offsets := make([] umm,                                          len(geometry.meshes), scratch)
    blas_sizes      := make([] umm,                                          len(geometry.meshes), scratch)
    
    ////////////////////////////////////////////////
    
    total_scratch_size: umm
    total_build_size:   umm
    for &source_mesh, index in geometry.meshes {
        #assert(offset_of(Vertex, p) == 0) // vertex data pointer
        #assert(type_of(Vertex{}.p) == v3) // vertex format
        
        lod := &source_mesh.lods[LOD_Index]
        
        triangle_counts[index] = lod.index_count / 3
        
        build_info := &build_infos[index]
        build_info^ = {
            sType = .ACCELERATION_STRUCTURE_BUILD_GEOMETRY_INFO_KHR,
            
            flags = { .PREFER_FAST_TRACE },
            mode  = .BUILD,
            type  = .BOTTOM_LEVEL,
            
            geometryCount = 1,
            pGeometries   = &vk.AccelerationStructureGeometryKHR {
                sType = .ACCELERATION_STRUCTURE_GEOMETRY_KHR,
                
                geometryType = .TRIANGLES,
                geometry = {
                    triangles = {
                        sType = .ACCELERATION_STRUCTURE_GEOMETRY_TRIANGLES_DATA_KHR,
                        
                        vertexFormat = .R32G32B32_SFLOAT,
                        vertexData   = { deviceAddress = buffers.vertices.gpu.p + cast(vk.DeviceAddress) (size_of(Vertex) * source_mesh.vertex_offset) },
                        vertexStride = size_of(Vertex),
                        maxVertex    = source_mesh.vertex_count,
                        
                        indexType    = .UINT32,
                        indexData    = { deviceAddress = buffers.indices.gpu.p  + cast(vk.DeviceAddress) (size_of(u32)    * lod.index_offset) },
                    },
                },
            },
        }
        
        scratch_size: umm
        blas_sizes[index], scratch_size = __get_acceleration_structure_sizes(gpu, build_info, &triangle_counts[index])
        
        build_offsets[index]   = total_build_size
        scratch_offsets[index] = total_scratch_size
        
        total_build_size   += align(AccelerationStructureAlignment, blas_sizes[index])
        total_scratch_size += align(AccelerationStructureAlignment, scratch_size)
    }
    
    ////////////////////////////////////////////////
    
    _, buffers.bottom_level_acceleration_structures = gpu_allocate_size(gpu, total_build_size, AccelerationStructureAlignment, .GPU, { .ACCELERATION_STRUCTURE_STORAGE_KHR })
    
    _, scratch_buffer := gpu_allocate_size(gpu, total_scratch_size, AccelerationStructureAlignment, .GPU)
    defer gpu_free(gpu, scratch_buffer)
    
    ////////////////////////////////////////////////
    
    results := make([] Acceleration_Structure, len(geometry.meshes), permanent)
    
    ranges         := make([] vk.AccelerationStructureBuildRangeInfoKHR,     len(geometry.meshes), scratch)
    range_pointers := make([] [^] vk.AccelerationStructureBuildRangeInfoKHR, len(geometry.meshes), scratch)
    
    for &result, index in results {
        build_info := &build_infos[index]
        
        result = __create_acceleration_structure(gpu, .BOTTOM_LEVEL, buffers.bottom_level_acceleration_structures, blas_sizes[index], build_offsets[index])
        build_info.dstAccelerationStructure  = result.acceleration_structure
        build_info.scratchData.deviceAddress = scratch_buffer + cast(vk.DeviceAddress) scratch_offsets[index]
        
        
        ranges[index]         = { primitiveCount = triangle_counts[index] }
        range_pointers[index] = &ranges[index]
    }
    
    ////////////////////////////////////////////////
    
    __build_acceleration_structures_immediately(gpu, queue, command_pool, build_infos, range_pointers)
    
    return results
}

build_top_level_acceleration_structures :: proc (gpu: ^Gpu, queue: vk.Queue, command_pool: vk.CommandPool, buffers: ^Buffers, draws: [] Draw, bottom_level_acceleration_structures: [] Acceleration_Structure, scratch: Allocator) -> Acceleration_Structure {
    instances := gpu_allocate_slice(gpu, [] vk.AccelerationStructureInstanceKHR, len(draws), usage = { .STORAGE_BUFFER, .ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_KHR })
    defer gpu_free(gpu, instances)
    
    assert(len(draws) <= (1 << 24), "More draws than representable by the instanceCustomIndex")
    for &instance, index in instances.cpu {
        draw := draws[index]
        
        scale    := cast(m3) draw.scale
        rotation := la.matrix3_from_quaternion(draw.orientation)
        
        t := rotation * scale
        transform := matrix[3, 4] f32 {
            t[0,0], t[0,1], t[0,2], draw.p.x,
            t[1,0], t[1,1], t[1,2], draw.p.y,
            t[2,0], t[2,1], t[2,2], draw.p.z,
        }
        
        instance = {
            transform           = { transmute([3][4] f32) transform },
            mask                = 0xFF,
            instanceCustomIndex = cast(u32) index,
            instanceShaderBindingTableRecordOffset = 0,
            accelerationStructureReference = cast(u64) bottom_level_acceleration_structures[draw.mesh_index].address,
        }
    }
    
    ////////////////////////////////////////////////
    
    build_info := vk.AccelerationStructureBuildGeometryInfoKHR {
        sType = .ACCELERATION_STRUCTURE_BUILD_GEOMETRY_INFO_KHR,
        
        flags = { .PREFER_FAST_TRACE },
        mode  = .BUILD, // use .UPDATE if this is (re-)build every frame 
        type  = .TOP_LEVEL,
        
        geometryCount = 1,
        pGeometries   = &vk.AccelerationStructureGeometryKHR {
            sType = .ACCELERATION_STRUCTURE_GEOMETRY_KHR,
            
            geometryType = .INSTANCES,
            geometry = {
                instances = {
                    sType = .ACCELERATION_STRUCTURE_GEOMETRY_INSTANCES_DATA_KHR,
                    data  = { deviceAddress = instances.gpu.p },
                },
            },
        },
    }
    
    instance_count := cast(u32) len(draws)
    
    tlas_size, scratch_size := __get_acceleration_structure_sizes(gpu, &build_info, &instance_count)
    
    ////////////////////////////////////////////////
    
    _, buffers.top_level_acceleration_structures = gpu_allocate_size(gpu, tlas_size, AccelerationStructureAlignment, .GPU, usage = { .ACCELERATION_STRUCTURE_STORAGE_KHR })
    
    _, scratch_buffer := gpu_allocate_size(gpu, scratch_size, AccelerationStructureAlignment, .GPU)
    defer gpu_free(gpu, scratch_buffer)
    
    ////////////////////////////////////////////////
    
    range         := vk.AccelerationStructureBuildRangeInfoKHR { primitiveCount = instance_count }
    range_pointer := cast([^] vk.AccelerationStructureBuildRangeInfoKHR) &range
    
    result := __create_acceleration_structure(gpu, .TOP_LEVEL, buffers.top_level_acceleration_structures, tlas_size)
    build_info.dstAccelerationStructure  = result.acceleration_structure
    build_info.scratchData.deviceAddress = scratch_buffer
    
    ////////////////////////////////////////////////
    
    __build_acceleration_structures_immediately(gpu, queue, command_pool, { build_info }, { range_pointer })
    
    return result
}

////////////////////////////////////////////////

__get_acceleration_structure_sizes :: proc (gpu: ^Gpu, build_info: ^vk.AccelerationStructureBuildGeometryInfoKHR, primitive_count: ^u32) -> (structure_size, scratch_size: umm) {
    
    size_info := vk.AccelerationStructureBuildSizesInfoKHR {
        sType = .ACCELERATION_STRUCTURE_BUILD_SIZES_INFO_KHR,
    }
    vk.GetAccelerationStructureBuildSizesKHR(gpu.device, .DEVICE, build_info, primitive_count, &size_info)
    
    return cast(umm) size_info.accelerationStructureSize, cast(umm) size_info.buildScratchSize
}

__create_acceleration_structure :: proc (gpu: ^Gpu, type: vk.AccelerationStructureTypeKHR, buffer: vk.DeviceAddress, size: umm, offset: umm = 0) -> Acceleration_Structure {
    // @bleh
    structure_buffer, structure_buffer_offset := gpu_reflect_get_buffer(buffer)
    
    result: Acceleration_Structure
    
    info := vk.AccelerationStructureCreateInfoKHR {
        sType = .ACCELERATION_STRUCTURE_CREATE_INFO_KHR,
        
        buffer = structure_buffer,
        offset = structure_buffer_offset + cast(vk.DeviceSize) offset,
        size   = cast(vk.DeviceSize) size,
        
        type = type,
        
    }
    check(vk.CreateAccelerationStructureKHR(gpu.device, &info, nil, &result.acceleration_structure))
    
    address_info := vk.AccelerationStructureDeviceAddressInfoKHR {
        sType = .ACCELERATION_STRUCTURE_DEVICE_ADDRESS_INFO_KHR,
        accelerationStructure = result.acceleration_structure,
    }
    result.address = vk.GetAccelerationStructureDeviceAddressKHR(gpu.device, &address_info)
    
    return result
}

__build_acceleration_structures_immediately :: proc (gpu: ^Gpu, queue: vk.Queue, command_pool: vk.CommandPool, build_infos: [] vk.AccelerationStructureBuildGeometryInfoKHR, range_pointers: [] [^] vk.AccelerationStructureBuildRangeInfoKHR) {
    cmd := gpu_begin_command_recording(gpu, command_pool)
    semaphore := gpu_create_timeline_semaphore(gpu, 0)
    
    vk.CmdBuildAccelerationStructuresKHR(cmd, cast(u32) len(build_infos), raw_data(build_infos), raw_data(range_pointers))
    
    gpu_submit(queue, {{ sema = semaphore, stages = { .ALL_COMMANDS }, signal_value = 1}}, cmd)
    gpu_wait_semaphore(gpu, semaphore, 1) 
    
    gpu_destroy_semaphore(gpu, semaphore)
}