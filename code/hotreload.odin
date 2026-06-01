package main

import "core:fmt"
import "core:os"

is_newer :: proc (a, b: string) -> bool {
    a_info, a_err := os.stat(a, context.temp_allocator)
    if a_err != nil {
        fmt.eprintfln("Failed to check modification time of file '%v': %v", a, os.error_string(a_err)) 
        return false
    }
    
    b_info, b_err := os.stat(b, context.temp_allocator)
    if b_err != nil {
        fmt.eprintfln("Failed to check modification time of file '%v': %v", b, os.error_string(b_err)) 
        return true
    }
    
    return a_info.modification_time._nsec > b_info.modification_time._nsec
}

recompile_shader :: proc (input, output: string) -> bool {
    cmd: Cmd
    cmd.allocator = context.temp_allocator
    
    append(&cmd, "slangc")
    /* @study(viktor):
        -O optimization level
        -fvk-invert-y
    */
    append(&cmd, "-target", "spirv",)
    append(&cmd, "-o", output)
    if ODIN_DEBUG {
        append(&cmd, "-g1") // @note(viktor): embed shader source code for renderdoc
    }
    append(&cmd, input)
    
    // @todo(viktor): start and test later if its finished?
    stdout: string
    stderr: string
    if !run_command(&cmd, or_exit = false, stdout = &stdout, stderr = &stderr) {
        fmt.eprintfln("Failed to run command to compile shader '%v'")
        return false
    }
    
    if stdout != "" {
        fmt.printfln("Hotreload output: %v", stdout)
    }
    
    if stderr != "" {
        fmt.printfln("Hotreload error: %v", stderr)
        return false
    }
    
    return true
}