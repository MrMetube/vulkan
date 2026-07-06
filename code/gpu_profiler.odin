#+vet explicit-allocators
package main

import "core:fmt"
import "core:time"

import vk "../lib/vulkan"

QueryPoolSize :: 256

the_gpu_profiler: struct {
    cb:          vk.CommandBuffer,
    pool:        vk.QueryPool,
    zones:       [dynamic] Zone,
    zone_labels: [dynamic; QueryPoolSize] string,
    open_zones:  [dynamic; QueryPoolSize] int,
    queries:     [dynamic; QueryPoolSize] Profile_Query,
}

Profile_Query :: struct { zone_index: int, kind: Event_Kind }

gpu_profile_make_query_pool :: proc (device: vk.Device) {
    create_info := vk.QueryPoolCreateInfo {
        sType = .QUERY_POOL_CREATE_INFO,
        queryType = .TIMESTAMP,
        queryCount = QueryPoolSize,
    }
    check(vk.CreateQueryPool(device, &create_info, nil, &the_gpu_profiler.pool))
}

gpu_profile_frame_begin :: proc (device: vk.Device, cb: vk.CommandBuffer) {
    vk.ResetQueryPool(device, the_gpu_profiler.pool, 0, QueryPoolSize)
    
    assert(the_gpu_profiler.pool != 0)
    the_gpu_profiler.cb = cb
    
    clear(&the_gpu_profiler.zones)
    clear(&the_gpu_profiler.zone_labels)
    clear(&the_gpu_profiler.open_zones)
    clear(&the_gpu_profiler.queries)
    
    gpu_profile_zone_begin("Frame", kind = .BeginFrame)
}

gpu_profile_frame_end :: proc () {
    assert(the_gpu_profiler.pool != 0)
    gpu_profile_zone_end()
}

gpu_profile_zone_begin :: proc (label: string, kind := Event_Kind.BeginZone) {
    assert(the_gpu_profiler.cb != nil)
    
    zone_index := len(the_gpu_profiler.zone_labels)
    append(&the_gpu_profiler.open_zones,  zone_index)
    append(&the_gpu_profiler.zone_labels, label)
    
    gpu_profile_write_timestamp(kind, zone_index)
}

gpu_profile_zone_end   :: proc () {
    assert(the_gpu_profiler.cb != nil)
    zone_index := pop(&the_gpu_profiler.open_zones)
    gpu_profile_write_timestamp(.EndZone, zone_index)
}

gpu_profile_write_timestamp :: proc (kind: Event_Kind, zone_index: int) {
    query_index := cast(u32) len(the_gpu_profiler.queries)
    append(&the_gpu_profiler.queries, Profile_Query { zone_index, kind })
    
    stage: vk.PipelineStageFlags2
    switch kind {
    case .BeginFrame, .BeginZone: stage = { .TOP_OF_PIPE }
    case .EndZone:                stage = { .BOTTOM_OF_PIPE }
    case .UserEvent: unreachable()
    }
    
    vk.CmdWriteTimestamp2(the_gpu_profiler.cb, stage, the_gpu_profiler.pool, query_index)
}

gpu_profile_collate_times :: proc (gpu: ^Gpu, device: vk.Device, print: bool) {
    assert(the_gpu_profiler.pool != 0)
    assert(len(the_gpu_profiler.open_zones) == 0)
    
    query_results: [QueryPoolSize] u64
    
    query_count := cast(u32) len(the_gpu_profiler.queries)
    query_result := vk.GetQueryPoolResults(device, the_gpu_profiler.pool, 0, query_count, cast(int) size_of_slice(query_results[:query_count]), &query_results[0], size_of(query_results[0]), { ._64, .WAIT })
    
    if query_result == .NOT_READY || query_result == .ERROR_DEVICE_LOST { return }
    check(query_result)
    
    // @cleanup
    if the_event_table == nil {
        the_gpu_profiler.zones.allocator = context.allocator
        
        the_event_table = new(Event_Table, context.allocator)
        set_recording(the_event_table, true)
    }
    
    for query, query_index in the_gpu_profiler.queries {
        timestamp := cast(i64) query_results[query_index]
        label := the_gpu_profiler.zone_labels[query.zone_index]
        record_event(timestamp, query.kind, label)
    }
    
    events := swap_active_array_and_get_events(the_event_table)
    
    collate_events(events, &the_gpu_profiler.zones, nil)
    zones := the_gpu_profiler.zones
        
    if print {
        fmt.printfln("---------------------\nNEW PROFILER TREE")
        fmt.printfln("---------------------\nGPU profile:")
        to_seconds := cast(f64) gpu.device_properties.properties.limits.timestampPeriod * 1e-9
        
        dump_zone :: proc (gpu: ^Gpu, zones: [dynamic] Zone, index: u32, depth := 0) {
            if index == 0 && depth != 0 { return }
            
            node := zones[index]
            xx :: proc (seconds: f64) -> time.Duration { return time.duration_round(cast(time.Duration) (seconds * cast(f64) time.Second), 10 * time.Nanosecond)  }
            
            for _ in 0..<depth { fmt.printf("    ") }
            fmt.printf("%v: %v", node.name, xx(gpu_timestamp_to_seconds(gpu, node.duration)))
            if node.duration_of_children != node.duration {
                fmt.printf(" (with children %v)", xx(gpu_timestamp_to_seconds(gpu, node.duration_of_children)))
            }
            fmt.printfln("")
            
            for link := node.first_child_index; link != 0; {
                child := zones[link]
                dump_zone(gpu, zones, link, depth + 1)
                link = child.next_sibling_index
            }
        }
        
        dump_zone(gpu, zones, 0)
    }
}

gpu_timestamp_to_seconds :: proc (gpu: ^Gpu, timestamp: i64) -> f64 {
    to_seconds := cast(f64) gpu.device_properties.properties.limits.timestampPeriod * 1e-9
    result := cast(f64) timestamp * to_seconds
    return result
}

gpu_profile_get_zone_duration :: proc (gpu: ^Gpu, name: string) -> (f64, bool) #optional_ok {
    // @speed zones could have been a hashmap, or copied into one if needed
    result: f64
    ok: bool
    for it in the_gpu_profiler.zones {
        if name == it.name {
            result = gpu_timestamp_to_seconds(gpu, it.duration)
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