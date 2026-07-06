package main

import "base:intrinsics"
import "core:sys/windows"

////////////////////////////////////////////////

the_metrics: OS_Metrics

OS_Metrics :: struct {
    initialized:    bool,
    process_handle: windows.HANDLE,
    cpu_frequency:  u64,
}

init_os_metrics :: proc (milliseconds_to_wait_for_cpu_frequency: u64 = 1000) {
    if !the_metrics.initialized {
        the_metrics.initialized = true
        the_metrics.process_handle = windows.OpenProcess(windows.PROCESS_QUERY_INFORMATION | windows. PROCESS_VM_READ, false, windows.GetCurrentProcessId())
        the_metrics.cpu_frequency = estimate_cpu_frequency(milliseconds_to_wait_for_cpu_frequency)
    }
}

read_os_page_fault_count :: proc () -> (result: u64) {
    assert(the_metrics.process_handle != nil)
    
    memory_counters := PROCESS_MEMORY_COUNTERS_EX { cb = size_of(PROCESS_MEMORY_COUNTERS_EX) }
    
    GetProcessMemoryInfo(the_metrics.process_handle, cast(^PROCESS_MEMORY_COUNTERS) &memory_counters, size_of(memory_counters))
    
    result = cast(u64) memory_counters.PageFaultCount
    return result
}

get_cpu_frequency :: proc () -> (result: u64) {
    assert(the_metrics.initialized)
    result = the_metrics.cpu_frequency
    return result
}

////////////////////////////////////////////////

More_Estimation_Info :: struct {
    os_frequency, os_start, os_end, cpu_start, cpu_end: u64,
}

estimate_cpu_frequency :: proc (milliseconds_to_wait: u64) -> (cpu_frequency: u64)  {
    os_frequency := get_os_timer_frequency()
    os_wait_time := os_frequency * milliseconds_to_wait / 1000
    
    cpu_start := read_cpu_timer()
    os_start := read_os_timer()
    os_elapsed: u64
    for os_elapsed < os_wait_time {
        os_end := read_os_timer()
        os_elapsed = os_end - os_start
    }
    
    cpu_end := read_cpu_timer()
    cpu_elapsed := cpu_end - cpu_start
    if os_elapsed != 0 {
        cpu_frequency = os_frequency * cpu_elapsed / os_elapsed
    }
    
    return cpu_frequency
}

estimate_cpu_frequency_more_info :: proc (milliseconds_to_wait: u64) -> (cpu_frequency: u64, more_info: More_Estimation_Info)  {
    more_info.os_frequency = get_os_timer_frequency()
    os_wait_time := more_info.os_frequency * milliseconds_to_wait / 1000
    
    more_info.cpu_start = read_cpu_timer()
    more_info.os_start = read_os_timer()
    os_elapsed: u64
    for os_elapsed < os_wait_time {
        more_info.os_end = read_os_timer()
        os_elapsed = more_info.os_end - more_info.os_start
    }
    
    more_info.cpu_end = read_cpu_timer()
    cpu_elapsed := more_info.cpu_end - more_info.cpu_start
    if os_elapsed != 0 {
        cpu_frequency = more_info.os_frequency * cpu_elapsed / os_elapsed
    }
    
    return cpu_frequency, more_info
}

read_cpu_timer :: proc () -> (result: u64) {
    result = cast(u64) intrinsics.read_cycle_counter()
    return result
}

clocks_to_seconds :: proc (clocks: i64) -> (result: f64) {
    result = cast(f64) clocks / cast(f64) get_cpu_frequency()
    return result
}