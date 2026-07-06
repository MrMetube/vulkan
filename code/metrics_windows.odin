#+build windows

package main

import "core:sys/windows"

foreign import psapi "system:psapi.lib"
foreign psapi {
    GetProcessMemoryInfo :: proc "system" (
        Process: windows.HANDLE, 
        ppsmemCounters: ^PROCESS_MEMORY_COUNTERS, 
        cb: windows.DWORD,
    ) ->  windows.BOOL ---
    
}

PROCESS_MEMORY_COUNTERS ::  struct {
    cb:                         windows.DWORD,
    PageFaultCount:             windows.DWORD,
    PeakWorkingSetSize:         windows.SIZE_T,
    WorkingSetSize:             windows.SIZE_T,
    QuotaPeakPagedPoolUsage:    windows.SIZE_T,
    QuotaPagedPoolUsage:        windows.SIZE_T,
    QuotaPeakNonPagedPoolUsage: windows.SIZE_T,
    QuotaNonPagedPoolUsage:     windows.SIZE_T,
    PagefileUsage:              windows.SIZE_T,
    PeakPagefileUsage:          windows.SIZE_T,
}

PROCESS_MEMORY_COUNTERS_EX :: struct {
    cb:                         windows.DWORD,
    PageFaultCount:             windows.DWORD,
    PeakWorkingSetSize:         windows.SIZE_T,
    WorkingSetSize:             windows.SIZE_T,
    QuotaPeakPagedPoolUsage:    windows.SIZE_T,
    QuotaPagedPoolUsage:        windows.SIZE_T,
    QuotaPeakNonPagedPoolUsage: windows.SIZE_T,
    QuotaNonPagedPoolUsage:     windows.SIZE_T,
    PagefileUsage:              windows.SIZE_T,
    PeakPagefileUsage:          windows.SIZE_T,
    PrivateUsage:               windows.SIZE_T,
}

get_os_timer_frequency :: proc () -> (result: u64) {
    value: windows.LARGE_INTEGER
    windows.QueryPerformanceFrequency(&value)
    result = cast(u64) value
    return result
}

read_os_timer :: proc () -> (result: u64) {
    value: windows.LARGE_INTEGER
    windows.QueryPerformanceCounter(&value)
    result = cast(u64) value
    return result
}
