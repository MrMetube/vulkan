#+vet explicit-allocators
package main

import "core:fmt"
import "core:time"

import vk "../lib/vulkan"

QueryPoolSize :: 256

gpu_profiler: struct {
    cb:         vk.CommandBuffer,
    pool:       vk.QueryPool,
    zones:      [dynamic; QueryPoolSize] Profile_Zone,
    open_zones: [dynamic; QueryPoolSize] int,
    queries:    [dynamic; QueryPoolSize] Profile_Query,
}

Profile_Query :: struct { kind: Query_Kind, zone_index: int }
Query_Kind :: enum { Begin, End }

Profile_Zone :: struct {
    parent_zone: int,
    
    label:       string,
    query_index: u32,
    
    total_time: f64,
    total_time_with_children: f64,
}

gpu_profile_make_query_pool :: proc (device: vk.Device) {
    create_info := vk.QueryPoolCreateInfo {
        sType = .QUERY_POOL_CREATE_INFO,
        queryType = .TIMESTAMP,
        queryCount = QueryPoolSize,
    }
    check(vk.CreateQueryPool(device, &create_info, nil, &gpu_profiler.pool))
    defer_destroy(vk.DestroyQueryPool, gpu_profiler.pool)
}

gpu_profile_frame_begin :: proc (device: vk.Device, cb: vk.CommandBuffer) {
    vk.ResetQueryPool(device, gpu_profiler.pool, 0, QueryPoolSize)
    
    assert(gpu_profiler.pool != 0)
    gpu_profiler.cb = cb
    
    clear(&gpu_profiler.zones)
    clear(&gpu_profiler.open_zones)
    clear(&gpu_profiler.queries)
    
    gpu_profile_zone_begin("frame")
}

gpu_profile_frame_end :: proc () {
    assert(gpu_profiler.pool != 0)
    gpu_profile_zone_end()
}

gpu_profile_zone_begin :: proc (label: string) {
    assert(gpu_profiler.cb != nil)
    zone: Profile_Zone
    zone.parent_zone = peek(gpu_profiler.open_zones[:]) or_else -1
    zone.label = label
    
    zone_index := len(gpu_profiler.zones)
    append(&gpu_profiler.open_zones, zone_index)
    append(&gpu_profiler.zones, zone)
    
    gpu_profile_write_timestamp(.Begin, zone_index)
}

gpu_profile_zone_end   :: proc () {
    assert(gpu_profiler.cb != nil)
    zone_index := pop(&gpu_profiler.open_zones)
    gpu_profile_write_timestamp(.End, zone_index)
}

gpu_profile_write_timestamp :: proc (kind: Query_Kind, zone_index: int) {
    query_index := cast(u32) len(gpu_profiler.queries)
    append(&gpu_profiler.queries, Profile_Query { kind, zone_index })
    
    stage: vk.PipelineStageFlags2
    switch kind {
    case .Begin: stage = { .TOP_OF_PIPE }
    case .End:   stage = { .BOTTOM_OF_PIPE }
    }
    
    vk.CmdWriteTimestamp2(gpu_profiler.cb, stage, gpu_profiler.pool, query_index)
}

gpu_profile_collate_times :: proc (gpu: ^Gpu, device: vk.Device, print: bool) {
    assert(gpu_profiler.pool != 0)
    assert(len(gpu_profiler.open_zones) == 0)
    
    query_results: [QueryPoolSize] u64
    
    query_count := cast(u32) len(gpu_profiler.queries)
    query_result := vk.GetQueryPoolResults(device, gpu_profiler.pool, 0, query_count, cast(int) size_of_slice(query_results[:query_count]), &query_results[0], size_of(query_results[0]), { ._64, .WAIT })
    
    if query_result == .NOT_READY || query_result == .ERROR_DEVICE_LOST { return }
    
    check(query_result)
    
    for query, query_index in gpu_profiler.queries {
        timestamp := cast(f64) query_results[query_index] * cast(f64) gpu.device_properties.properties.limits.timestampPeriod * 1e-9
        
        zone := &gpu_profiler.zones[query.zone_index]
        
        switch query.kind {
        case .Begin:
            zone.total_time               -= timestamp
            zone.total_time_with_children -= timestamp
            
            if zone.parent_zone != -1 {
                parent := &gpu_profiler.zones[zone.parent_zone]
                parent.total_time               += timestamp
                parent.total_time_with_children -= timestamp
            }
            
        case .End:
            zone.total_time               += timestamp
            zone.total_time_with_children += timestamp
            
            if zone.parent_zone != -1 {
                parent := &gpu_profiler.zones[zone.parent_zone]
                parent.total_time               -= timestamp
                parent.total_time_with_children += timestamp
            }
        }
    }
    
    if print {
        fmt.printfln("---------------------\nGPU profile:")
        for zone in gpu_profiler.zones {
            xx :: proc (seconds: f64) -> time.Duration { return cast(time.Duration) (seconds * cast(f64) time.Second) }
            
            fmt.printf("  %25v: %v", zone.label, xx(zone.total_time))
            if zone.total_time_with_children != zone.total_time {
                fmt.printf(" (with children %v)", xx(zone.total_time_with_children))
            }
            fmt.printfln("")
        }
    }
}

gpu_profile_get_zone :: proc (label: string) -> (Profile_Zone, bool) #optional_ok {
    // @speed zones could have been a hashmap, or copied into one if needed
    result: Profile_Zone
    ok: bool
    for it in gpu_profiler.zones {
        if label == it.label {
            result = it
            ok = true
            break
        }
    }
    
    return result, ok
}

////////////////////////////////////////////////

gpu_labeled_region_begin :: proc (cmd: vk.CommandBuffer, label: cstring, color: v4) {
    if !Optimized {
        vk.CmdBeginDebugUtilsLabelEXT(cmd, &vk.DebugUtilsLabelEXT { sType = .DEBUG_UTILS_LABEL_EXT, pLabelName = label, color = color} )
    }
}
gpu_labeled_region_end :: proc (cmd: vk.CommandBuffer) {
    if !Optimized {
        vk.CmdEndDebugUtilsLabelEXT(cmd)
    }
}