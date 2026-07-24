#+vet explicit-allocators
package main

import "core:fmt"
import "core:os"

The_Assets: Assets
Assets :: struct {
    initialized: bool,
    
    // These can never be freed
    shader_infos: [dynamic] Shader_Info,
    shaders:      [dynamic] Shader,
    
    ////////////////////////////////////////////////
    
    // This needs to store the transient information in each Shader_Compilation and must be able to free individual compilation related allocations.
    shader_compilation_allocator: Allocator,
    // This needs to store the byte data from the recompile and loading up until the next successful recompilation. It also needs to be able to free single allocations.
    shader_bytes_allocator:       Allocator,
    shader_compilation_procs:     Procs,
    shader_compilation_infos:     [dynamic] Shader_Compilation,
}

////////////////////////////////////////////////

init_assets :: proc (shader_bytes_allocator: Allocator) {
    assets := &The_Assets
    
    // Nils
    append_nothing(&assets.shaders)
    append_nothing(&assets.shader_infos)
    
    assets.shader_compilation_allocator = context.allocator
    assets.shader_bytes_allocator       = shader_bytes_allocator
    
    assets.initialized = true
}

deinit_assets :: proc () {
    assets := get_assets()
    load_all_compiled_shaders() // finish all running compilations and clean them up
    for shader in assets.shaders {
        delete(shader.bytes, assets.shader_bytes_allocator)
    }
    delete(assets.shaders)
    delete(assets.shader_infos)
    delete(assets.shader_compilation_procs)
    delete(assets.shader_compilation_infos)
}

get_assets :: proc (loc := #caller_location) -> ^Assets {
    assets := &The_Assets
    assert(assets.initialized, loc = loc)
    
    return assets
}

////////////////////////////////////////////////
// Shaders

Shader_Compilation :: struct {
    completed: bool,
    id: Shader_Id,
    input_path:    string,
    shader_output: string,
    old_bytes: [] u8,
}

Shader_Id  :: distinct u32
Nil_Shader :: cast(Shader_Id) 0

make_shader :: proc () -> (Shader_Id, ^Shader_Info) {
    assets := get_assets()
    
    id := cast(Shader_Id) len(assets.shader_infos)
    info   := append_into(&assets.shader_infos)
    append_into(&assets.shaders)
    
    return id, info
}

get_shader :: proc (id: Shader_Id, immediately: bool = true, loc := #caller_location) -> ^Shader {
    assets := get_assets()
    
    id := id
    if id >= auto_cast len(assets.shaders) {
        id = Nil_Shader
    } else {
        load_compiled_shader(id, immediately)
    }
    
    result := &assets.shaders[id]
    if immediately {
        assert(result.bytes != nil, "Failed to immediately get shader.", loc = loc)
    }
    
    return result
}

get_shader_info :: proc (id: Shader_Id) -> ^Shader_Info {
    assets := get_assets()
    
    id := id
    if id >= auto_cast len(assets.shader_infos) {
        id = Nil_Shader
    }
    
    result := &assets.shader_infos[id]
    return result
}

make_shader_compilation :: proc () -> (^Procs, ^Shader_Compilation, Allocator) {
    assets := get_assets()
    
    comp  := append_into(&assets.shader_compilation_infos)
    procs := &assets.shader_compilation_procs
    alloc := assets.shader_compilation_allocator
    
    return procs, comp, alloc
}

test_and_reset_shaders_was_modified :: proc (ids: ..Shader_Id) -> bool {
    result := false
    
    for id in ids {
        shader := get_shader(id, immediately = false)
        result ||= shader.was_modified
        shader.was_modified = false
    }
    
    return result
}

load_all_compiled_shaders :: proc (immediately := false) {
    load_compiled_shader(0, immediately)
}

// If id == 0 then all shaders will be loaded.
load_compiled_shader :: proc (id: Shader_Id, immediately := false) {
    assets := get_assets()
    if len(assets.shader_compilation_procs) == 0 { return }
    
    completed_count: int
    for &p, index in assets.shader_compilation_procs {
        info := &assets.shader_compilation_infos[index]
        if id != 0 && info.id != id { continue }
        
        state, wait_err := os.process_wait(p, timeout = immediately ? os.TIMEOUT_INFINITE : 0)
        done := true
        if !immediately {
            if wait_err == .Timeout || !state.exited {
                done = false
            }
        } else {
            assert(wait_err == nil)
        }
        
        if done {
            completed_count += 1
            info.completed = true
            
            if state.exit_code != 0 {
                fmt.printfln("Shader compilation failed for %q", info.input_path)
            } else {
                load_and_parse_shader(info^)
            }
        }
        
        if id != 0 { break }
    }
    
    if completed_count != 0 {
        if completed_count == len(assets.shader_compilation_procs) {
            clear(&assets.shader_compilation_procs)
            clear(&assets.shader_compilation_infos)
        } else {
            #reverse for info, index in assets.shader_compilation_infos {
                if info.completed {
                    unordered_remove(&assets.shader_compilation_procs, index)
                    unordered_remove(&assets.shader_compilation_infos, index)
                }
            }
        }
    }
}

load_and_parse_shader :: proc (info: Shader_Compilation) {
    assets := get_assets()
    
    ok := true
    
    shader_bytes, err := os.read_entire_file(info.shader_output, assets.shader_bytes_allocator)
    if err != nil {
        fmt.printfln("Could not load the output file of %q, which is %q: %v", info.input_path, info.shader_output, os.error_string(err))
        ok = false
    }
    
    if ok {
        if info.old_bytes != nil {
            delete(info.old_bytes, assets.shader_bytes_allocator)
        }
        
        shader: Shader
        shader.was_modified = true
        shader.bytes = shader_bytes
        parse_shader(&shader)
        assets.shaders[info.id] = shader
    } else {
        if assets.shaders[info.id].bytes == nil {
            assert(false, fmt.tprintf("Failed to initially load the shader %q", info.input_path))
        }
    }
    
    delete(info.input_path,    assets.shader_compilation_allocator)
    delete(info.shader_output, assets.shader_compilation_allocator)
}
