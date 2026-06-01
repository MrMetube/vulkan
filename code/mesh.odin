package main

// @speed for cache reasons we should, if possible, do this either whilst loading or combined with other processing, or just offline
build_meshlets :: proc (mesh: ^Mesh) {
    Missing :: ~cast(u8) 0
    meshlet_vertices := make([] u8, len(mesh.vertices), context.temp_allocator)
    for &it in meshlet_vertices do it = Missing
    
    meshlet: ^Meshlet
    append_nothing(&mesh.meshlets)
    meshlet = &mesh.meshlets[len(mesh.meshlets)-1]
    
    for it: int; it < len(mesh.indices); it += 3 {
        is: [3] u16
        for &i, offset in is { i = mesh.indices[it+offset] }
        
        new_vertices: u8
        vs: [3] ^u8
        for &v, offset in vs {
            i := is[offset]
            v = &meshlet_vertices[i]
            if v^ == Missing { 
                new_vertices += 1
            }
        }
        
        flush: bool
        if meshlet.vertex_count + new_vertices > len(meshlet.vertices) {
            flush = true
        }
        
        if meshlet.index_count + 1 > len(meshlet.indices) {
            flush = true
        }
        
        if flush {
            for vi in meshlet.vertices {
                meshlet_vertices[vi] = Missing
            }
            
            append_nothing(&mesh.meshlets)
            meshlet = &mesh.meshlets[len(mesh.meshlets)-1]
        }
        
        for v, index in vs {
            if v^ == Missing {
                v^ = meshlet.vertex_count
                meshlet.vertices[meshlet.vertex_count] = cast(u32) is[index]
                meshlet.vertex_count += 1 
            }
        }
        
        for v, index in vs {
            meshlet.indices[meshlet.index_count + cast(u8) index] = v^
        }
        meshlet.index_count += 3
    }
}