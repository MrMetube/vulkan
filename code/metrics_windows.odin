#+build windows

package main

import win "core:sys/windows"

foreign import psapi "system:psapi.lib"
foreign psapi {
    GetProcessMemoryInfo :: proc "system" (Process: win.HANDLE, ppsmemCounters: ^PROCESS_MEMORY_COUNTERS, cb: win.DWORD, ) ->  win.BOOL ---
}

PROCESS_MEMORY_COUNTERS ::  struct {
    cb:                         win.DWORD,
    PageFaultCount:             win.DWORD,
    PeakWorkingSetSize:         win.SIZE_T,
    WorkingSetSize:             win.SIZE_T,
    QuotaPeakPagedPoolUsage:    win.SIZE_T,
    QuotaPagedPoolUsage:        win.SIZE_T,
    QuotaPeakNonPagedPoolUsage: win.SIZE_T,
    QuotaNonPagedPoolUsage:     win.SIZE_T,
    PagefileUsage:              win.SIZE_T,
    PeakPagefileUsage:          win.SIZE_T,
}

PROCESS_MEMORY_COUNTERS_EX :: struct {
    cb:                         win.DWORD,
    PageFaultCount:             win.DWORD,
    PeakWorkingSetSize:         win.SIZE_T,
    WorkingSetSize:             win.SIZE_T,
    QuotaPeakPagedPoolUsage:    win.SIZE_T,
    QuotaPagedPoolUsage:        win.SIZE_T,
    QuotaPeakNonPagedPoolUsage: win.SIZE_T,
    QuotaNonPagedPoolUsage:     win.SIZE_T,
    PagefileUsage:              win.SIZE_T,
    PeakPagefileUsage:          win.SIZE_T,
    PrivateUsage:               win.SIZE_T,
}

get_os_timer_frequency :: proc () -> u64 {
    value: win.LARGE_INTEGER
    win.QueryPerformanceFrequency(&value)
    result := cast(u64) value
    return result
}

read_os_timer :: proc () -> u64 {
    value: win.LARGE_INTEGER
    win.QueryPerformanceCounter(&value)
    result := cast(u64) value
    return result
}
