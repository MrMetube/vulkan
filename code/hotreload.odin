package main

import "core:fmt"
import "core:os"
import "core:time"

monitored_files: map[string] time.Time

hotreload :: proc (filepath: string) -> bool {
    last_modification := monitored_files[filepath] or_else {}
    
    info, err := os.stat(filepath, context.temp_allocator)
    if err != nil {
        fmt.eprintfln("Failed to check modification time of file '%v': %v", filepath, os.error_string(err)) 
        return false
    }
    
    result: bool
    delta := time.diff(last_modification, info.modification_time)
    if delta > 0 {
        monitored_files[filepath] = info.modification_time
        result = true
    }
    
    return result
}