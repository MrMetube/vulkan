#+vet explicit-allocators
package main

import "core:fmt"
import "core:time"
import "profiler"

import vk "../lib/vulkan"

QueryPoolSize :: 64

the_gpu_profiler: struct {
    state_index:  u64,
    states: [MaxFramesInFlight] struct {
        cb:   vk.CommandBuffer,
        pool: vk.QueryPool,
        
        zones:       [dynamic] profiler.Zone,
        zone_labels: [dynamic; QueryPoolSize] string,
        open_zones:  [dynamic; QueryPoolSize] int,
        queries:     [dynamic; QueryPoolSize] Profile_Query,
     
        event_table: ^profiler.Event_Table,
    },
}

Profile_Query :: struct { zone_index: int, kind: profiler.Event_Kind }

gpu_profile_init :: proc (gpu: ^Gpu) {
    prof := &the_gpu_profiler
    for &state in prof.states {
        state.pool = create_query_pool(gpu, QueryPoolSize, .TIMESTAMP)
        
        state.zones.allocator = context.allocator
        
        state.event_table = new(profiler.Event_Table, context.allocator)
        profiler.set_recording(state.event_table, true)
    }
}

gpu_profile_deinit :: proc (gpu: ^Gpu) {
    prof := &the_gpu_profiler
    for &state in prof.states {
        vk.DestroyQueryPool(gpu.device, state.pool, nil)
        free(state.event_table, context.allocator) // @volatile see init
        delete(state.zones)
    }
}

gpu_profile_frame_begin :: proc (gpu: ^Gpu, cb: vk.CommandBuffer, frame_index: u64) {
    the_gpu_profiler.state_index = frame_index
    prof := &the_gpu_profiler.states[the_gpu_profiler.state_index]
    assert(prof.pool != 0)
    
    vk.ResetQueryPool(gpu.device, prof.pool, 0, QueryPoolSize)
    
    prof.cb = cb
    
    clear(&prof.zones)
    clear(&prof.zone_labels)
    clear(&prof.open_zones)
    clear(&prof.queries)
    
    gpu_profile_zone_begin("Frame")
}

gpu_profile_frame_end :: proc () {
    prof := &the_gpu_profiler.states[the_gpu_profiler.state_index]
    
    assert(prof.pool != 0)
    gpu_profile_zone_end()
}

gpu_profile_zone_begin :: proc (label: string) {
    prof := &the_gpu_profiler.states[the_gpu_profiler.state_index]
    
    assert(prof.cb != nil)
    
    zone_index := len(prof.zone_labels)
    append(&prof.open_zones,  zone_index)
    append(&prof.zone_labels, label)
    
    gpu_profile_write_timestamp(.BeginZone, zone_index)
}

gpu_profile_zone_end   :: proc () {
    prof := &the_gpu_profiler.states[the_gpu_profiler.state_index]
    
    assert(prof.cb != nil)
    zone_index := pop(&prof.open_zones)
    gpu_profile_write_timestamp(.EndZone, zone_index)
}

gpu_profile_write_timestamp :: proc (kind: profiler.Event_Kind, zone_index: int) {
    prof := &the_gpu_profiler.states[the_gpu_profiler.state_index]
    
    query_index := cast(u32) len(prof.queries)
    append(&prof.queries, Profile_Query { zone_index, kind })
    
    vk.CmdWriteTimestamp2(prof.cb, { .ALL_COMMANDS }, prof.pool, query_index)
}

gpu_profile_collate_times :: proc (gpu: ^Gpu, print: bool, frame_index: u64) {
    prof := &the_gpu_profiler.states[frame_index]
    
    assert(prof.pool != 0)
    assert(len(prof.open_zones) == 0)
    
    query_results: [QueryPoolSize] u64
    
    query_count := cast(u32) len(prof.queries)
    
    bytes  := cast(int) size_of_slice(query_results[:query_count])
    data   := &query_results[0]
    stride := cast(vk.DeviceSize) size_of(query_results[0])
    check(vk.GetQueryPoolResults(gpu.device, prof.pool, 0, query_count, bytes, data, stride, { ._64 }))
    
    for query, query_index in prof.queries {
        timestamp := cast(i64) query_results[query_index]
        label := prof.zone_labels[query.zone_index]
        profiler.record_event(prof.event_table, timestamp, query.kind, label)
    }
    
    events := profiler.swap_active_array_and_get_events(prof.event_table)
    
    profiler.collate_events(events, &prof.zones, nil)
    
    if print {
        zones := prof.zones
        
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

gpu_profile_get_zone_duration :: proc (gpu: ^Gpu, frame_index: u64, name: string) -> (f64, bool) #optional_ok {
    prof := &the_gpu_profiler.states[frame_index]
    
    result: f64
    ok: bool
    for it in prof.zones {
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