package main

The_Assets: Assets
Assets :: struct {
    initialized: bool,
    
    // These can never be freed
    shader_infos: [dynamic] Shader_Info,
    shader_data:  [dynamic] Shader,
}

Shader_Id :: distinct u32
Nil_Id :: cast(Shader_Id) 0

////////////////////////////////////////////////

init_assets :: proc () {
    assets := &The_Assets
    
    // Nils
    append_nothing(&assets.shader_data)
    append_nothing(&assets.shader_infos)
    
    assets.initialized = true
}

get_assets :: proc (loc := #caller_location) -> ^Assets {
    assets := &The_Assets
    assert(assets.initialized, loc = loc)
    
    return assets
}

////////////////////////////////////////////////

make_shader :: proc () -> (Shader_Id, ^Shader, ^Shader_Info) {
    assets := get_assets()
    
    id := cast(Shader_Id) len(assets.shader_infos)
    info   := append_into(&assets.shader_infos)
    shader := append_into(&assets.shader_data)
    
    return id, shader, info
}

replace_shader :: proc (id: Shader_Id, shader: Shader) {
    assets := get_assets()
    if id < cast(Shader_Id) len(assets.shader_data) {
        assets.shader_data[id] = shader
    }
}

get_shader :: proc (id: Shader_Id, immediately := true) -> ^Shader {
    assets := get_assets()
    
    id := id
    if id >= auto_cast len(assets.shader_data) {
        id = Nil_Id
    }
    
    result := &assets.shader_data[id]
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
