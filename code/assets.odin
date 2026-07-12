#+vet explicit-allocators
package main

import "core:fmt"
import "core:os"

The_Assets: Assets
Assets :: struct {
    initialized: bool,
    
    // These can never be freed
    shader_infos: [dynamic] Shader_Info,
    shaders:  [dynamic] Shader,
    
    ////////////////////////////////////////////////
    
    shader_compilation_procs: Procs,
    shader_compilation_infos: [dynamic] Shader_Compilation,
}

Shader_Compilation :: struct {
    id: Shader_Id,
    input_path:    string,
    shader_output: string,
    shader_allocator: Allocator,
    old: ^Shader,
}

Shader_Id :: distinct u32
Nil_Id :: cast(Shader_Id) 0

////////////////////////////////////////////////

init_assets :: proc () {
    assets := &The_Assets
    
    // Nils
    append_nothing(&assets.shaders)
    append_nothing(&assets.shader_infos)
    
    assets.initialized = true
}

get_assets :: proc (loc := #caller_location) -> ^Assets {
    assets := &The_Assets
    assert(assets.initialized, loc = loc)
    
    return assets
}

////////////////////////////////////////////////

make_shader :: proc () -> (Shader_Id, ^Shader_Info) {
    assets := get_assets()
    
    id := cast(Shader_Id) len(assets.shader_infos)
    info   := append_into(&assets.shader_infos)
    append_into(&assets.shaders)
    
    return id, info
}

get_shader :: proc (id: Shader_Id, immediately: bool = false) -> ^Shader {
    assets := get_assets()
    
    id := id
    if id >= auto_cast len(assets.shaders) {
        id = Nil_Id
    } else {
        if immediately {
            load_all_shaders_immediately()
        }
    }
    
    result := &assets.shaders[id]
    return result
}

get_shader_info :: proc (id: Shader_Id) -> ^Shader_Info {
    assets := get_assets()
    
    id := id
    if id >= auto_cast len(assets.shader_infos) {
        id = Nil_Id
    }
    
    result := &assets.shader_infos[id]
    return result
}

make_shader_compilation :: proc () -> (^Procs, ^Shader_Compilation) {
    assets := get_assets()
    
    comp := append_into(&assets.shader_compilation_infos)
    procs := &assets.shader_compilation_procs
    return procs, comp
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

load_all_shaders_that_were_recompiled_and_are_done :: proc () {
    assets := get_assets()
    if len(assets.shader_compilation_procs) == 0 { return }
    
    #reverse for &p, index in assets.shader_compilation_procs {
        state, wait_err := os.process_wait(p, timeout = 0)
        if wait_err == .Timeout || !state.exited { continue }
        assert(wait_err == nil)
        
        info := assets.shader_compilation_infos[index]
        if state.exit_code != 0 {
            fmt.printfln("Shader compilation failed for %q", info.input_path)
            continue
        }
        
        load_and_parse_shader(info)
        
        unordered_remove(&assets.shader_compilation_procs, index)
        unordered_remove(&assets.shader_compilation_infos, index)
    }
}

load_all_shaders_immediately :: proc () {
    assets := get_assets()
    if len(assets.shader_compilation_procs) == 0 { return }
    
    for &p, index in assets.shader_compilation_procs {
        state, wait_err := os.process_wait(p)
        assert(wait_err == nil)
        
        info := assets.shader_compilation_infos[index]
        if state.exit_code != 0 {
            fmt.printfln("Shader compilation failed for %q", info.input_path)
            continue
        }
        
        load_and_parse_shader(info)
    }
    clear(&assets.shader_compilation_procs)
    clear(&assets.shader_compilation_infos)
}

load_and_parse_shader :: proc (info: Shader_Compilation) {
    assets := get_assets()
    
    ok := true
    
    shader_bytes, err := os.read_entire_file(info.shader_output, info.shader_allocator)
    if err != nil {
        fmt.printfln("Could not load the output file of '%v', which is '%v': %v", info.input_path, info.shader_output, os.error_string(err))
        ok = false
    }
    
    if ok {
        if info.old != nil {
            delete(info.old.bytes, info.shader_allocator)
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
    
    // @todo compilation arena allocator
    delete(info.input_path,    info.shader_allocator)
    delete(info.shader_output, info.shader_allocator)
}
