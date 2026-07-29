#+vet explicit-allocators
package main

import "core:os"

import "base:runtime"

import la "core:math/linalg"
import vk "../lib/vulkan"

Scene :: struct {
    arena:         Arena,
    loading_arena: Arena,
    
    loaded: bool,
    camera:        Camera,
    sun_direction: v3,
    
    draws: [dynamic] Draw,
    
    buffers:       Buffers,
    textures:      [dynamic] Texture_Handle,
    top_level:     Acceleration_Structure,
    bottom_levels: [dynamic] Acceleration_Structure,
}

Buffers :: struct {
    vertices:     Gpu_Slice(Vertex),
    indices:      Gpu_Slice(u32),
    meshlets:     Gpu_Slice(Meshlet),
    meshlet_data: Gpu_Slice(u32),
    meshes:       Gpu_Slice(Mesh),
    
    draw_commands:      Gpu_Slice(Draw_Command),
    // @todo both need to be cleared to 1 on init. is allocated memory guarenteed to be zeroed? if so then we could make 0 the default by making them xx_occluded
    draw_visibility:    Gpu_Slice(u32),
    meshlet_visibility: Gpu_Slice(u32),
    
    bottom_level_acceleration_structures: vk.DeviceAddress,
    top_level_acceleration_structures:    vk.DeviceAddress,
}

Geometry :: struct {
    vertices:     [dynamic] Vertex,
    indices:      [dynamic] u32,
    meshlets:     [dynamic] Meshlet,
    meshlet_data: [dynamic] u32,
    
    meshes: [dynamic] Mesh,
}

init_scene :: proc (gpu: ^Gpu, scene: ^Scene) {
    profile_procedure()
    
    scene.arena         = make_arena()
    scene.loading_arena = make_arena()
    
    scene_allocator := arena_allocator(&scene.arena)
    
    scene.draws         = make([dynamic] Draw,                   scene_allocator)
    scene.textures      = make([dynamic] Texture_Handle,         scene_allocator)
    scene.bottom_levels = make([dynamic] Acceleration_Structure, scene_allocator)
    
    scene.camera = { // May be overridden by the scene itself
        p           = {0, 0, 0},
        orientation = 1,
        fov_y       = 70 * RadiansFromDegrees,
    }
}

deinit_scene :: proc (gpu: ^Gpu, scene: ^Scene) {
    profile_procedure()
    
    unload_scene(gpu, scene)
    
    arena_free_all(&scene.arena)
    
    gpu_free(gpu, scene.buffers.draw_commands)
    gpu_free(gpu, scene.buffers.draw_visibility)
    gpu_free(gpu, scene.buffers.meshlet_visibility)
}

load_scene :: proc (gpu: ^Gpu, scene: ^Scene) {
    profile_procedure()
    defer scene.loaded = true
    
    scene_allocator         := arena_allocator(&scene.arena)
    scene_loading_allocator := arena_allocator(&scene.loading_arena)
    defer arena_free_all(&scene.loading_arena)
    
    clear(&scene.draws)
    clear(&scene.textures)
    clear(&scene.bottom_levels)
    
    {
        geometry: Geometry
        geometry.vertices.allocator     = scene_loading_allocator
        geometry.indices.allocator      = scene_loading_allocator
        geometry.meshlets.allocator     = scene_loading_allocator
        geometry.meshlet_data.allocator = scene_loading_allocator
        geometry.meshes.allocator       = scene_loading_allocator
        
        // @todo @speed move this work into a work_queue with threads.
        // Mutex around 
        // - the draws 
        // - gpu/heap access
        // - permanent and temp allocations
        // First just load all the geometry synchronously and just thread
        // the textures, that way we dont have to mutex the geometry buffers.
        // 
        {
            path := "niagara_bistro/bistro.gltf"
            texture_paths := make([dynamic] string, scene_loading_allocator)
            print("\nLoading scene: %v\n", path)
            
            profile_zone_begin("load gltf scene")
            draws := make([dynamic] Scene_Draw, scene_loading_allocator)
            if !load_gltf_scene(&geometry, path, &draws, &scene.camera, &texture_paths, &scene.sun_direction) {
                runtime.exit(1)
            }
            profile_zone_end()
            
            print("  Loaded scene %q: %v meshes, %v draws, %v textures\n", path, len(geometry.meshes), len(scene.draws), len(texture_paths))
            print("  Loading textures\n")
            
            reserve(&scene.textures, len(texture_paths))
            reserve(&scene.draws,    len(draws))
            
            //
            // @speed Moving the copies to a queue will speedup the loading from ssd(~22%). It may or may not help
            // with the drivers copy(~71%), depending on its ability to be parallelized. 
            /// 0.957 / 1.34
            /// 0.3   / 1.34
            //
            // Read speed testing estimates a max speed of 6.5 Gb/s with a preallocated and mapped buffer.
            // Here we currently load ~2.1 Gb.
            /// 2.1 / 6.5
            // Just loading the textures should take ~0.3s itself: which it does!
            // The whole texture upload takes roughly 0.8-1.5s, so ~0.5-1.2s itself, which is mainly
            // the copy into the texture by the cpu. A straight memcopy would be faster by the driver
            // may need to swizzle the data based on the formats.
            /// 2.1 / 0.957
            /// 2.1 / 0.493
            // Therefore we only reach speeds of ~2.2 Gb/s (a memcopy of the same data ~4.3Gb/s)
            // So the driver's copy is roughly half as fast as a memcopy.
            //
            // https://developer.nvidia.com/blog/advanced-api-performance-async-copy/
            // This article recommends using a copy-queue as NVidia has dedicated async copy engines.
            // It might be the case that the swizzleling already saturates the cpu's memory bandwidth,
            // but that should be specifically tested.
            // 
            // 1. Check out async copy and/or async compute for copy work and synchronize with the 
            //    graphics via semaphores.
            // 2. (optional) Test if the drivers cpu copy is truely bottlenecked if multiple threads
            //    call into it at once.
            // 3. Even if the ssd load is not the biggest part, we can still multithread it. Either
            //    use worker threads, or check out OS native IO rings.
            //
            total_size: int
            {
                profile_scope("upload textures")
                
                texture_descs      := make([] Texture_Desc, len(texture_paths), scene_loading_allocator)
                texture_pixel_size := make([] int,          len(texture_paths), scene_loading_allocator)
                texture_file       := make([] ^os.File,     len(texture_paths), scene_loading_allocator)
                
                max_size : int
                for texture_path, index in texture_paths {
                    file, open_error := os.open(texture_path); assert(open_error == nil)
                    texture_descs[index], texture_pixel_size[index] = parse_dds_texture_header(file)
                    texture_file[index] = file
                    
                    pixel_size := texture_pixel_size[index]
                    max_size = max(max_size, pixel_size)
                    total_size += pixel_size
                }
                
                copy_buffer := make([] u8, max_size, scene_loading_allocator)
                
                for index in 0..<len(texture_paths) {
                    pixel_size := texture_pixel_size[index]
                    file       := texture_file[index]
                    
                    buffer := copy_buffer[:pixel_size]
                    read, read_error := os.read_full(file, buffer); assert(read_error == nil); assert(read == pixel_size)
                    os.close(file)
                    
                    desc := texture_descs[index]
                    handle  := create_texture(gpu, **desc)
                    texture := get_texture(handle)
                    gpu_copy_to_texture_immediately(gpu, texture.image, desc.format, buffer, desc.size.xy, desc.mip_count)
                    
                    append(&scene.textures, handle)
                }
            }
            
            for raw, index in draws {
                draw := cast(Draw) raw
                // @volatile see mesh.odin material texture indices
                if raw.albedo_texture != 0 {
                    draw.albedo_texture   = get_texture(scene.textures[raw.albedo_texture-1]).sampled_index
                }
                if raw.normal_texture != 0 {
                    draw.normal_texture   = get_texture(scene.textures[raw.normal_texture-1]).sampled_index
                }
                if raw.emmisive_texture != 0 {
                    draw.emmisive_texture = get_texture(scene.textures[raw.emmisive_texture-1]).sampled_index
                }
                append(&scene.draws, draw)
            }
            
            print("  Loaded textures: %vb\n\n", view_magnitude(total_size))
        }
        
        {
            profile_scope("Allocate geometry buffers")
            
            vertex_and_index_usage := vk.BufferUsageFlags { .STORAGE_BUFFER }
            if raytracing_supported {
                vertex_and_index_usage += { .ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_KHR }
            }
            
            
            // 
            // @todo If we limit these buffers to exactly as much as the scene requires, we cannot draw anything dynamically 
            // that is not part of the scene definition with the meshlet pipeline. This may or may not be an issue depending
            // on what exactly a "scene" is. If its just the static geometry and we then want to also render dynamic geometry
            // with the same pipeline and draw command we need to append its data into the "geometry" arrays on scene load.
            // 
            // At some point we might want to again move the geometry into which we load back out to let multiple sources add
            // meshes, which we then upload all at once outside.
            // 
            scene.buffers.vertices     = gpu_allocate_slice(gpu, [] Vertex,  256 * Megabyte / size_of(Vertex),  memory = .Default, usage = vertex_and_index_usage)
            scene.buffers.indices      = gpu_allocate_slice(gpu, [] u32,     256 * Megabyte / size_of(u32),     memory = .Default, usage = vertex_and_index_usage + { .INDEX_BUFFER })
            scene.buffers.meshlets     = gpu_allocate_slice(gpu, [] Meshlet, 256 * Megabyte / size_of(Meshlet), memory = .Default)
            scene.buffers.meshlet_data = gpu_allocate_slice(gpu, [] u32,     256 * Megabyte / size_of(u32),     memory = .Default)
            scene.buffers.meshes       = gpu_allocate_slice(gpu, [] Mesh,    256 * Megabyte / size_of(Mesh),    memory = .Default)
            
            // @todo allocating just as much space as needed somehow breaks the acceleration structure building. When waiting for the 
            // build the gpu dies and crashes the program. It probably has to do with some kind of alignment/layout issue, or some
            // out-of-bounds indexing that we don't see when padding the data with megabytes of zeroes as we did before.
            
            // scene.buffers.vertices     = gpu_allocate_slice(gpu, [] Vertex,  len(geometry.vertices), memory = .Default, usage = vertex_and_index_usage)
            // scene.buffers.indices      = gpu_allocate_slice(gpu, [] u32,     len(geometry.indices),  memory = .Default, usage = vertex_and_index_usage + { .INDEX_BUFFER })
            // scene.buffers.meshlets     = gpu_allocate_slice(gpu, [] Meshlet, len(geometry.meshlets),     memory = .Default)
            // scene.buffers.meshlet_data = gpu_allocate_slice(gpu, [] u32,     len(geometry.meshlet_data), memory = .Default)
            // scene.buffers.meshes       = gpu_allocate_slice(gpu, [] Mesh,    len(geometry.meshes),       memory = .Default)
            
            profile_zone_begin("upload geometry")
            copy(scene.buffers.vertices.cpu,     geometry.vertices[:])
            copy(scene.buffers.indices.cpu,      geometry.indices[:])
            copy(scene.buffers.meshlets.cpu,     geometry.meshlets[:])
            copy(scene.buffers.meshlet_data.cpu, geometry.meshlet_data[:])
            copy(scene.buffers.meshes.cpu,       geometry.meshes[:])
            profile_zone_end()
        }
            
        if raytracing_supported {
            // @todo which pool?
            queue := gpu.general_queue
            pool  := gpu.command_pools[0]
            
            build_bottom_level_acceleration_structures(gpu, queue, pool, &scene.buffers, geometry, &scene.bottom_levels, scene_loading_allocator)
            scene.top_level = build_top_level_acceleration_structures(gpu, queue, pool, &scene.buffers, scene.draws[:], scene.bottom_levels[:], scene_loading_allocator)
        }
        
        profile_zone_begin("Allocate render buffers")
        
        meshlet_visibility_count: u32
        for &draw in scene.draws {
            mesh := geometry.meshes[draw.mesh_index]
            // @speed just ensure that the base lod has the most meshlets
            meshlet_count: u32
            for lod in mesh.lods[:mesh.lod_count] {
                meshlet_count = max(meshlet_count, lod.meshlet_count)
            }
            
            draw.meshlet_visibility_offset = meshlet_visibility_count
            meshlet_visibility_count      += meshlet_count
        }
        
        // @todo shouldnt draw_visibility have the same cap as draw commands? or as scene.draws?
        // @placement if these buffers are allocated based on the scene they need to be freed in scene_unload, 
        // otherwise move the allocation/deallocation into init/deinit
        scene.buffers.draw_commands      = gpu_allocate_slice(gpu, [] Draw_Command, TaskWidthLimit,                        memory = .GPU) 
        scene.buffers.draw_visibility    = gpu_allocate_slice(gpu, [] u32,          256 * Megabyte / size_of(u32),         memory = .GPU, usage = { .STORAGE_BUFFER, .TRANSFER_DST })
        scene.buffers.meshlet_visibility = gpu_allocate_slice(gpu, [] u32,          (meshlet_visibility_count + 31) / 32,  memory = .GPU, usage = { .STORAGE_BUFFER, .TRANSFER_DST })
    }
    
    profile_zone_end()
}

unload_scene :: proc (gpu: ^Gpu, scene: ^Scene) {
    profile_procedure()
    
    scene.loaded = false
    
    gpu_free(gpu, scene.buffers.vertices)
    gpu_free(gpu, scene.buffers.indices)
    gpu_free(gpu, scene.buffers.meshlets)
    gpu_free(gpu, scene.buffers.meshlet_data)
    gpu_free(gpu, scene.buffers.meshes)
    
    for it in scene.bottom_levels {
        vk.DestroyAccelerationStructureKHR(gpu.device, it.acceleration_structure, nil)
    }
    vk.DestroyAccelerationStructureKHR(gpu.device, scene.top_level.acceleration_structure, nil)
    
    gpu_free(gpu, scene.buffers.bottom_level_acceleration_structures)
    gpu_free(gpu, scene.buffers.top_level_acceleration_structures)
    
    for texture in scene.textures {
        free_texture(gpu, texture)
    }
}

////////////////////////////////////////////////

// Required by the spec for acceleration structures. The scratch could have a smaller alignment
// requirement, but it's only a small waste.
@(private="file")
AccelerationStructureAlignment :: 256 *4*8

build_bottom_level_acceleration_structures :: proc (gpu: ^Gpu, queue: vk.Queue, command_pool: vk.CommandPool, buffers: ^Buffers, geometry: Geometry, results: ^[dynamic] Acceleration_Structure, scratch: Allocator) {
    LOD_Index :: 0
    
    triangle_counts := make([] u32, len(geometry.meshes), scratch)
    
    build_infos     := make([] vk.AccelerationStructureBuildGeometryInfoKHR, len(geometry.meshes), scratch)
    blas_offsets    := make([] umm,                                          len(geometry.meshes), scratch)
    blas_sizes      := make([] umm,                                          len(geometry.meshes), scratch)
    scratch_offsets := make([] umm,                                          len(geometry.meshes), scratch)
    
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
        blas_sizes[index], scratch_size = gpu_get_acceleration_structure_sizes(gpu, build_info, &triangle_counts[index])
        
        blas_offsets[index]    = total_build_size
        scratch_offsets[index] = total_scratch_size
        
        total_build_size   += align(AccelerationStructureAlignment, blas_sizes[index])
        total_scratch_size += align(AccelerationStructureAlignment, scratch_size)
    }
    
    ////////////////////////////////////////////////
    
    _, buffers.bottom_level_acceleration_structures = gpu_allocate_size(gpu, total_build_size, AccelerationStructureAlignment, .GPU, { .ACCELERATION_STRUCTURE_STORAGE_KHR })
    
    _, scratch_buffer := gpu_allocate_size(gpu, total_scratch_size, AccelerationStructureAlignment, .GPU)
    defer gpu_free(gpu, scratch_buffer)
    
    ////////////////////////////////////////////////
    
    resize(results, len(geometry.meshes))
    
    ranges         := make([] vk.AccelerationStructureBuildRangeInfoKHR,     len(geometry.meshes), scratch)
    range_pointers := make([] [^] vk.AccelerationStructureBuildRangeInfoKHR, len(geometry.meshes), scratch)
    
    for &result, index in results {
        build_info := &build_infos[index]
        
        result = gpu_create_acceleration_structure(gpu, .BOTTOM_LEVEL, buffers.bottom_level_acceleration_structures, blas_sizes[index], blas_offsets[index])
        build_info.dstAccelerationStructure  = result.acceleration_structure
        build_info.scratchData.deviceAddress = scratch_buffer + cast(vk.DeviceAddress) scratch_offsets[index]
        
        
        ranges[index]         = { primitiveCount = triangle_counts[index] }
        range_pointers[index] = &ranges[index]
    }
    
    ////////////////////////////////////////////////
    
    build_acceleration_structures_immediately(gpu, queue, command_pool, build_infos, range_pointers)
}

build_top_level_acceleration_structures :: proc (gpu: ^Gpu, queue: vk.Queue, command_pool: vk.CommandPool, buffers: ^Buffers, draws: [] Draw, bottom_level_acceleration_structures: [] Acceleration_Structure, scratch: Allocator) -> Acceleration_Structure {
    assert(len(draws) <= (1 << 24), "More draws than representable by the instanceCustomIndex")
    
    instance_count := cast(u32) len(draws)
    instances := gpu_allocate_slice(gpu, [] vk.AccelerationStructureInstanceKHR, instance_count, usage = { .STORAGE_BUFFER, .ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_KHR })
    defer gpu_free(gpu, instances)
    
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
        
        it := vk.AccelerationStructureInstanceKHR {
            transform           = { transmute([3][4] f32) transform },
            mask                = 0xFF, // @volatile must agree with the rayQuery's in shaders
            instanceCustomIndex = cast(u32) index,
            accelerationStructureReference = cast(u64) bottom_level_acceleration_structures[draw.mesh_index].address,
        }
        
        instance = it
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
    
    tlas_size, scratch_size := gpu_get_acceleration_structure_sizes(gpu, &build_info, &instance_count)
    
    ////////////////////////////////////////////////
    
    _, buffers.top_level_acceleration_structures = gpu_allocate_size(gpu, tlas_size, AccelerationStructureAlignment, .GPU, usage = { .ACCELERATION_STRUCTURE_STORAGE_KHR })
    
    _, scratch_buffer := gpu_allocate_size(gpu, scratch_size, AccelerationStructureAlignment, .GPU)
    defer gpu_free(gpu, scratch_buffer)
    
    ////////////////////////////////////////////////
    
    range         := vk.AccelerationStructureBuildRangeInfoKHR { primitiveCount = instance_count }
    range_pointer := cast([^] vk.AccelerationStructureBuildRangeInfoKHR) &range
    
    result := gpu_create_acceleration_structure(gpu, .TOP_LEVEL, buffers.top_level_acceleration_structures, tlas_size)
    build_info.dstAccelerationStructure  = result.acceleration_structure
    build_info.scratchData.deviceAddress = scratch_buffer
    
    ////////////////////////////////////////////////
    
    build_acceleration_structures_immediately(gpu, queue, command_pool, { build_info }, { range_pointer })
    
    return result
}

////////////////////////////////////////////////

build_acceleration_structures_immediately :: proc (gpu: ^Gpu, queue: vk.Queue, command_pool: vk.CommandPool, build_infos: [] vk.AccelerationStructureBuildGeometryInfoKHR, range_pointers: [] [^] vk.AccelerationStructureBuildRangeInfoKHR) {
    cmd := gpu_begin_command_recording(gpu, command_pool)
    semaphore := gpu_create_timeline_semaphore(gpu, 0)
    
    vk.CmdBuildAccelerationStructuresKHR(cmd, cast(u32) len(build_infos), raw_data(build_infos), raw_data(range_pointers))
    
    gpu_submit(queue, {{ sema = semaphore, stages = { .ALL_COMMANDS }, signal_value = 1}}, cmd)
    gpu_wait_semaphore(gpu, semaphore, 1) 
    
    gpu_destroy_semaphore(gpu, semaphore)
}