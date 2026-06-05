#+vet explicit-allocators
package main

import "lib:meshoptimizer"

optimize_mesh :: proc (mesh: ^Mesh, allocator: Allocator) {
    result: Mesh
    
    remap := make([] u32, len(mesh.indices), allocator)
    vertex_count := meshoptimizer.generateVertexRemap(&remap[0], &mesh.indices[0], len(mesh.indices), &mesh.vertices[0], len(mesh.vertices), size_of(Vertex))
    
    result.vertices = make([] Vertex, vertex_count, allocator)
    result.indices  = make([] u32,    len(mesh.indices), allocator)
    
    meshoptimizer.remapVertexBuffer(&result.vertices[0], &mesh.vertices[0], len(mesh.vertices), size_of(Vertex), &remap[0])
    meshoptimizer.remapIndexBuffer(&result.indices[0], &mesh.indices[0], len(mesh.indices), &remap[0])
    
    meshoptimizer.optimizeVertexCache(&result.indices[0], &result.indices[0], len(result.indices), len(result.vertices))
    meshoptimizer.optimizeVertexFetch(&result.vertices[0], &result.indices[0], len(result.indices), &result.vertices[0], len(result.vertices), size_of(Vertex)) 
    
    mesh ^= result
}

build_meshlets :: proc (mesh: ^Mesh, allocator: Allocator) -> u32 {
    max_vertices  :: MaxVertices
    max_triangles :: MaxTriangles 
    cone_weight :: 0 // 0 when not culling, otherwise 0..1 
    
    max_count := meshoptimizer.buildMeshletsBound(auto_cast len(mesh.indices), max_vertices, max_triangles)
    
    meshlets := make([] meshoptimizer.Meshlet, max_count, context.temp_allocator)
    vertices := make([] u32, len(mesh.indices), context.temp_allocator)
    indices  := make([] u8,  len(mesh.indices), context.temp_allocator)
    
    actual_count := meshoptimizer.buildMeshlets(&meshlets[0], &vertices[0], &indices[0], &mesh.indices[0], len(mesh.indices), cast(^f32) &mesh.vertices[0], len(mesh.vertices), size_of(mesh.vertices[0]), max_vertices, max_triangles, cone_weight)
    
    // :TaskShader: either round of the size, or in shader check the bounds
    aligned_count := align(32, actual_count)
    mesh.meshlets = make([] Meshlet, aligned_count, allocator)
    
    meshlet_data := make([dynamic] u32, allocator)
    
    for &dest, index in mesh.meshlets[:actual_count] {
        source := &meshlets[index]
        
        source_vertices := vertices[source.vertex_offset:]
        source_indices  := indices[source.triangle_offset:]
        
        dest.data_offset = cast(u32) len(meshlet_data)
        dest.triangle_count = safe_truncate(u8, source.triangle_count)
        dest.vertex_count   = safe_truncate(u8, source.vertex_count)
        
        index_group_count := (source.triangle_count * 3 + 3) / 4
        
        index_groups := slice_from_parts(u32, &source_indices[0], index_group_count)
        
        for i in 0..<source.vertex_count {
            append(&meshlet_data, source_vertices[i])
        }
        for i in 0..<index_group_count {
            append(&meshlet_data, index_groups[i])
        }
        
        bounds := meshoptimizer.computeMeshletBounds(&source_vertices[0], &source_indices[0], cast(uint) source.triangle_count, cast(^f32) &mesh.vertices[0], len(mesh.vertices), size_of(mesh.vertices[0]))
        
        dest.center = bounds.center
        dest.radius = bounds.radius
        dest.cone_axis   = bounds.cone_axis_s8
        dest.cone_cutoff = bounds.cone_cutoff_s8
    }
    
    mesh.meshlet_data = meshlet_data[:]
    
    
    for &meshlet in mesh.meshlets {
        meshoptimizer.optimizeMeshlet(&mesh.meshlet_data[meshlet.data_offset], cast(^u8) &mesh.meshlet_data[meshlet.data_offset + auto_cast meshlet.vertex_count], auto_cast meshlet.triangle_count, auto_cast meshlet.vertex_count)
    }
    
    return cast(u32) actual_count
}