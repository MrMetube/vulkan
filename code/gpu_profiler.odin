#+vet explicit-allocators
package main

import "core:fmt"
import "core:time"
import "profiler"

import vk "../lib/vulkan"

QueryPoolSize :: 256

the_gpu_profiler: struct {
    cb:          vk.CommandBuffer,
    pool:        vk.QueryPool,
    zones:       [dynamic] profiler.Zone,
    zone_labels: [dynamic; QueryPoolSize] string,
    open_zones:  [dynamic; QueryPoolSize] int,
    queries:     [dynamic; QueryPoolSize] Profile_Query,
    
    event_table: ^profiler.Event_Table,
}

Profile_Query :: struct { zone_index: int, kind: profiler.Event_Kind }

gpu_profile_init :: proc (gpu: ^Gpu) {
    the_gpu_profiler.pool = create_query_pool(gpu, QueryPoolSize, .TIMESTAMP)
    
    the_gpu_profiler.zones.allocator = context.allocator
    
    the_gpu_profiler.event_table = new(profiler.Event_Table, context.allocator)
    profiler.set_recording(the_gpu_profiler.event_table, true)
}

gpu_profile_frame_begin :: proc (gpu: ^Gpu, cb: vk.CommandBuffer) {
    vk.ResetQueryPool(gpu.device, the_gpu_profiler.pool, 0, QueryPoolSize)
    
    assert(the_gpu_profiler.pool != 0)
    the_gpu_profiler.cb = cb
    
    clear(&the_gpu_profiler.zones)
    clear(&the_gpu_profiler.zone_labels)
    clear(&the_gpu_profiler.open_zones)
    clear(&the_gpu_profiler.queries)
    
    gpu_profile_zone_begin("Frame")
}

gpu_profile_frame_end :: proc () {
    assert(the_gpu_profiler.pool != 0)
    gpu_profile_zone_end()
}

gpu_profile_zone_begin :: proc (label: string) {
    assert(the_gpu_profiler.cb != nil)
    
    zone_index := len(the_gpu_profiler.zone_labels)
    append(&the_gpu_profiler.open_zones,  zone_index)
    append(&the_gpu_profiler.zone_labels, label)
    
    gpu_profile_write_timestamp(.BeginZone, zone_index)
}

gpu_profile_zone_end   :: proc () {
    assert(the_gpu_profiler.cb != nil)
    zone_index := pop(&the_gpu_profiler.open_zones)
    gpu_profile_write_timestamp(.EndZone, zone_index)
}

gpu_profile_write_timestamp :: proc (kind: profiler.Event_Kind, zone_index: int) {
    query_index := cast(u32) len(the_gpu_profiler.queries)
    append(&the_gpu_profiler.queries, Profile_Query { zone_index, kind })
    
    vk.CmdWriteTimestamp2(the_gpu_profiler.cb, { .ALL_COMMANDS }, the_gpu_profiler.pool, query_index)
}

gpu_profile_collate_times :: proc (gpu: ^Gpu, print: bool) {
    cpu_procedure_profile_zone()
    
    assert(the_gpu_profiler.pool != 0)
    assert(len(the_gpu_profiler.open_zones) == 0)
    
    query_results: [QueryPoolSize] u64
    
    cpu_begin_profile_zone("get results")
    // @speed how can we reliably get the results without waiting up to 130ms for them?
    query_count := cast(u32) len(the_gpu_profiler.queries)
    query_result := vk.GetQueryPoolResults(gpu.device, the_gpu_profiler.pool, 0, query_count, cast(int) size_of_slice(query_results[:query_count]), &query_results[0], size_of(query_results[0]), { ._64, .WAIT })
    cpu_end_profile_zone()
    
    if query_result == .NOT_READY || query_result == .ERROR_DEVICE_LOST { return }
    check(query_result)
    
    for query, query_index in the_gpu_profiler.queries {
        timestamp := cast(i64) query_results[query_index]
        label := the_gpu_profiler.zone_labels[query.zone_index]
        profiler.record_event(the_gpu_profiler.event_table, timestamp, query.kind, label)
    }
    
    events := profiler.swap_active_array_and_get_events(the_gpu_profiler.event_table)
    
    profiler.collate_events(events, &the_gpu_profiler.zones, nil)
    
    if print {
        zones := the_gpu_profiler.zones
        
        link: u32
        for {
            zone := zones[link]
            depth := zone.depth_of_the_event
            
            xx :: proc (seconds: f64) -> time.Duration { return time.duration_round(cast(time.Duration) (seconds * cast(f64) time.Second), 10 * time.Nanosecond)  }
            
            for _ in 0..<depth { fmt.printf("    ") }
            fmt.printf("%v: %v", zone.name, xx(gpu_timestamp_to_seconds(gpu, zone.duration)))
            if zone.duration_with_children != zone.duration {
                fmt.printf(" (with children %v)", xx(gpu_timestamp_to_seconds(gpu, zone.duration_with_children)))
            }
            fmt.printfln("")
            
            link = zone.depth_next_event
            if link == 0 { break }
        }
    }
}

gpu_timestamp_to_seconds :: proc (gpu: ^Gpu, timestamp: i64) -> f64 {
    to_seconds := cast(f64) gpu.device_properties.properties.limits.timestampPeriod * 1e-9
    result := cast(f64) timestamp * to_seconds
    return result
}

gpu_profile_get_zone_duration :: proc (gpu: ^Gpu, name: string) -> (f64, bool) #optional_ok {
    result: f64
    ok: bool
    for it in the_gpu_profiler.zones {
        if name == it.name {
            result = gpu_timestamp_to_seconds(gpu, it.duration_with_children)
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