package main

import vk "vendor:vulkan"

import "../libs/tobj"

Model :: struct {
    vertices: [] Vertex,
    indices:  [] i16,
    
    index_count: u32,
    v_buffer_size: vk.DeviceSize,
    i_buffer_size: vk.DeviceSize,
}

Vertex :: struct {
    p:  v3,
    n:  v3,
    uv: v2,
}

load_obj :: proc (filepath: string, allocator: Allocator) -> Model {
    models, _, error := tobj.load_obj_filename(filepath, allocator = allocator)
    assert(error == nil)
    model := models[0].mesh
    
    index_count := cast(u32) len(model.indices)
    vertices := make([] Vertex, index_count, allocator)
    indices  := make([] i16,  len(vertices), allocator)
    
    for index, it_index in model.indices {
        v := Vertex {
            p  = model.vertices[index]       * { 1, -1, 1 },
            n  = model.normals[index]        * { 1, -1, 1 },
            uv = model.texture_coords[index] * { 1, -1 },
        }
        
        vertices[it_index] = v
        indices[it_index]  = auto_cast it_index
    }
    
    v_buffer_size := cast(vk.DeviceSize) len(vertices) * size_of(vertices[0])
    i_buffer_size := cast(vk.DeviceSize) len(indices)  * size_of(indices[0])
    
    result: Model
    result.vertices = vertices
    result.indices = indices
    
    result.v_buffer_size = v_buffer_size
    result.i_buffer_size = i_buffer_size
    result.index_count = index_count
    
    return result
}