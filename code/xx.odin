#+vet !unused-procedures
package main

import "base:intrinsics"

import "core:fmt"
import "core:os"
import "core:text/regex"
import "core:strings"
import win "core:sys/windows"

////////////////////////////////////////////////

// @todo(viktor): explain the args parsing syntax (run|debug):<target.exe in build dir>

cmd   := &the_state.cmd
procs := &the_state.procs

////////////////////////////////////////////////
// Internal state

raddbg      :: "raddbg.exe"
raddbg_path :: "C:/tools/raddbg/"+ raddbg

Procs :: [dynamic] os.Process
Cmd   :: [dynamic] string

the_state := struct {
    cmd: Cmd,
    procs: Procs,
    
    // @cleanup
    current_output: string,
    last_output:    string,
    outputs: map [string] bool,

    wait_on_procs: bool,
    run_from_data: bool,
    
    runs: [dynamic] Run,
} {
    // Defaults
}

Handle_Running_Exe :: enum {
    Skip,
    Abort, 
    Kill,
}

Run :: struct {
    // @note(viktor): an empty name "" means run the default output
    name: string,
    debug: bool,
}

////////////////////////////////////////////////

@(deferred_none=deinit_build)
init_build :: proc (run_from_data := false, wait := false) {
    gitignore_path := "./build/.gitignore"
    if !os.exists(gitignore_path) {
        data := "*\n!*.odin\n"
        _ = os.write_entire_file(gitignore_path, transmute([] u8) data)
    }
    
    if run_from_data {
        make_directory_if_not_exists("./data")
        the_state.run_from_data = true
    }
    the_state.wait_on_procs = wait
}

deinit_build :: proc () {
    if len(cmd) != 0 {
        fmt.printf("INFO: cmd was not cleared: `%v`\n", strings.join(cmd[:], " "))
    }
    
    if the_state.wait_on_procs {
        procs_flush(procs)
    } else {
        procs_close(procs)
    }
}

////////////////////////////////////////////////

begin_build :: proc (cmd: ^Cmd, package_directory: string, output_name: string, handling: Handle_Running_Exe = .Skip) -> bool {
    // @todo(viktor): check that we do not nest, or make this stateless(see current_output)
    result: bool
    
    if handle_running_exe_gracefully(output_name, handling) {
        append(cmd, "odin", "build")
        append(cmd, fmt.tprintf("./%v", package_directory))
        append(cmd, fmt.tprintf("-out:./build/%v", output_name))
        result = true
        
        the_state.outputs[output_name] = true
        the_state.current_output = output_name
    }
    
    return result
}

build_meander :: proc (debug := "-debug", Cast := "-vet-cast", shadowing := "-vet-shadowing", linker := "-linker:radlink") {
    append(cmd, debug, Cast, shadowing, linker)
}

build_optimizations :: proc (optimize: bool, optimized := "-o:speed", unoptimized := "-o:none") {
    append(cmd, optimize ? optimized : unoptimized)
}

build_native :: proc (native: bool = true, target := "-target:windows_amd64", microarch := "-microarch:native") {
    if native {
        append(cmd, target, microarch)
    }
}

build_pedantic :: proc (pedantic: bool, imports := "-vet-unused-imports", semicolon := "-vet-semicolon", variables := "-vet-unused-variables", style := "-vet-style") {
    if pedantic {
        append(cmd, imports, semicolon, variables, style)
    }
}

end_build :: proc (cmd: ^Cmd) {
    if run_command(cmd) {
        fmt.printf("  Build successful %v.\n", the_state.current_output)
        the_state.last_output = the_state.current_output
    } else {
        the_state.outputs[the_state.current_output] = false
    }
    
    the_state.current_output = ""
}

////////////////////////////////////////////////

parse_run_and_debug_arguments :: proc () {
    runs := &the_state.runs
    
    run_prefix := "run:"
    debug_prefix := "debug:"
    
    any_debug: bool
    for argument in os.args[1:] {
        if strings.starts_with(argument, "/") {
            continue
        }
        
        if argument == "debug" {
            append(runs, Run { name = "", debug = true})
            any_debug = true
        }
        
        if strings.starts_with(argument, run_prefix) {
            rest := argument[len(run_prefix):]
            append(runs, Run { name = rest, debug = false })
            
        } else if strings.starts_with(argument, debug_prefix) {
            rest := argument[len(debug_prefix):]
            append(runs, Run { name = rest, debug = true })
            any_debug = true
        }
    }
    
    if any_debug {
        if ok, _ := is_running(raddbg); ok {
            fmt.printf("Debugger is running, stopping it.\n")
            append(cmd, raddbg_path)
            append(cmd, "--ipc")
            append(cmd, "kill_all")
            run_command(cmd)
        } else {
            fmt.printf("Starting the Debugger.\n")
            append(cmd, raddbg_path)
            run_command(cmd, async = procs)
        }
    }
}

run_or_debug_according_to_args :: proc () {
    for run in the_state.runs {
        name := run.name
        if name == "" { // default
            // @note(viktor): assume last output
            name = the_state.last_output
        }
        
        success, found := the_state.outputs[name]
        if !found {
            verb := run.debug ? "running" : "debugging"
            fmt.printf("ERROR: Skipped %v '%v', because it was not built by this program.\n", verb, name)
            if !run.debug {
                fmt.printf("  Try 'run_command' to run any other program.\n")
            }
            continue
        }
        
        if !success {
            verb := run.debug ? "running" : "debugging"
            fmt.printf("ERROR: Skipped %v '%v', because it failed to build.\n", verb, name)
            continue
        }
        
        if run.debug {
            append(cmd, raddbg_path)
            append(cmd, "--ipc")
            append(cmd, "select_target")
            append(cmd, name)
            run_command(cmd)
            
            append(cmd, raddbg_path)
            append(cmd, "--ipc")
            append(cmd, "restart")
            run_command(cmd)
        } else {
            path: string
            if the_state.run_from_data {
                os.change_directory("./data")
                path = fmt.tprintf("../build/%v", name)
            } else {
                path = fmt.tprintf("./build/%v", name)
            }
            
            append(cmd, path)
            if the_state.wait_on_procs {
                run_command(cmd, async = procs, stdout = os.stdout, stderr = os.stderr)
            } else {
                run_command(cmd, async = procs)
            }
        }
    }
}

////////////////////////////////////////////////

is_running :: proc (exe_name: string) -> (running: bool, pid: u32) {
    snapshot := win.CreateToolhelp32Snapshot(win.TH32CS_SNAPALL, 0)
    assert(snapshot != win.INVALID_HANDLE_VALUE, "could not take a snapshot of the running programms")
    defer win.CloseHandle(snapshot)
    
    process_entry := win.PROCESSENTRY32W{ dwSize = size_of(win.PROCESSENTRY32W)}
    
    if win.Process32FirstW(snapshot, &process_entry) {
        for {
            test_name, err := win.utf16_to_utf8(process_entry.szExeFile[:])
            assert(err == nil)
            if exe_name == test_name {
                return true, process_entry.th32ProcessID
            }
            if !win.Process32NextW(snapshot, &process_entry) {
                break
            }
        }
    }
    
    return false, 0
}

handle_running_exe_gracefully :: proc (exe_name: string, handling: Handle_Running_Exe) -> bool {
    ok, pid := is_running(exe_name)
    if ok {
        fmt.printf("INFO: Tried to build '%v', but the program is already running.\n", exe_name)
        switch handling {
        case .Skip:
            fmt.printf("  Skipping build.\n", exe_name)
            ok = false
            
        case .Abort: 
            fmt.printf("  Aborting build!\n", exe_name)
            os.exit(0)
            
        case .Kill:
            // @note(viktor): if the exe was started from the debugger it should already be killed by the kill_all command before the build was started
            if running, _ := is_running(raddbg); !running {
                fmt.printf("  Killing running instance.\n")
                
                process, err := os.process_open(auto_cast pid)
                if err != nil {
                    fmt.printf("  Failed to open '%v': %v\n", exe_name, err)
                    return false
                }
                
                err = os.process_kill(process)
                if err != nil {
                    fmt.printf("  Failed to kill '%v': %v\n", exe_name, err)
                    return false
                }
            }
        }
    }
    
    return true
}

////////////////////////////////////////////////

Command_Console :: union {
    ^string,
    ^os.File,
}
run_command :: proc (cmd: ^Cmd, or_exit := true, keep := false, stdout: Command_Console = nil, stderr: Command_Console = nil, async: ^Procs = nil) -> (success: bool) {
    fmt.printf("CMD: %v\n", strings.join(cmd[:], " "))
    
    process_description := os.Process_Desc { command = cmd[:] }
    process: os.Process
    state:   os.Process_State
	output:  [] byte
	error:   [] byte
    err2:    os.Error
    
    if async == nil {
        state, output, error, err2 = os.process_exec(process_description, context.allocator)
    } else {
        if err, ok := stderr.(^os.File); ok do process_description.stderr = err
        if out, ok := stdout.(^os.File); ok do process_description.stdout = out
        process, err2 = os.process_start(process_description)
        append(async, process)
    }
    
    if err2 != nil {
        fmt.printf("ERROR: Failed to run command: %v\n", err2)
        return false
    }
    
    if async == nil {
        if output != nil {
            switch &out in stdout {
            case nil: 
                fmt.println(cast(string) output)
            case ^string: 
                out^ = cast(string) output
            case ^os.File: // nothing, already passed on exec
            }
        }
        
        if error != nil {
            switch &out in stderr {
            case nil: 
                fmt.eprintln(cast(string) error)
            case ^string: 
                out^ = cast(string) error
            case ^os.File: // nothing, already passed on exec
            }
        }
        
        if or_exit && (!state.success || state.exit_code != 0) do os.exit(state.exit_code)
        
        success = state.success
    } else {
        success = true
    }
    
    if !keep do clear(cmd)
    
    return success
}

procs_flush :: proc (procs: ^Procs) {
    for &p in procs {
        _, _ = os.process_wait(p)
    }
    
    clear(procs)
}

procs_close :: proc (procs: ^Procs) {
    for &p in procs {
        _ = os.process_terminate(p)
    }
    
    clear(procs)
}

////////////////////////////////////////////////

make_directory_if_not_exists :: proc (path: string) -> bool {
    result: bool
    if !os.exists(path) {
        os.make_directory(path)
        result = true
    }
    return result
}

remove_if_exists :: proc (path: string) {
    if os.exists(path) do os.remove(path)
}

delete_all_like :: proc (path, pattern: string) {
    files := all_like(path, pattern)
    for file in files {
        os.remove(file)
    }
}

all_like :: proc (path, pattern: string, allocator := context.temp_allocator) -> [] string {
    dir, _ := os.read_all_directory_by_path(path, allocator)
    reg, _ := regex.create(pattern)
    
    result := make([dynamic] string, allocator)
    for file in dir {
        _, ok := regex.match(reg, file.name)
        if ok {
            append(&result, file.fullpath)
        }
    }
    
    return result[:]
}

////////////////////////////////////////////////

random_number :: proc () -> u8 {
    return cast(u8) intrinsics.read_cycle_counter()
}