#+vet explicit-allocators
package main

import "lib:meshoptimizer"
import "core:mem"

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
    max_vertices  :: len(Meshlet{}.vertices)
    max_triangles :: len(Meshlet{}.indices)
    cone_weight :: 0 // 0 when not culling, otherwise 0..1 
    
    max_count := meshoptimizer.buildMeshletsBound(auto_cast len(mesh.indices), max_vertices, max_triangles)
    
    meshlets := make([] meshoptimizer.Meshlet, max_count, context.temp_allocator)
    vertices := make([] u32, len(mesh.indices), context.temp_allocator)
    indices  := make([] u8,  len(mesh.indices), context.temp_allocator)
    
    actual_count := meshoptimizer.buildMeshlets(&meshlets[0], &vertices[0], &indices[0], &mesh.indices[0], len(mesh.indices), cast(^f32) &mesh.vertices[0], len(mesh.vertices), size_of(mesh.vertices[0]), max_vertices, max_triangles, cone_weight)
    
    // :TaskShader: either round of the size, or in shader check the bounds
    aligned_count := align(32, actual_count)
    mesh.meshlets = make([] Meshlet, aligned_count, allocator)
    
    for &dest, index in mesh.meshlets[:actual_count] {
        source := &meshlets[index]
        
        source_vertices := &vertices[source.vertex_offset]
        source_indices  := &indices[source.triangle_offset]
        
        mem.copy(&dest.vertices[0], source_vertices, cast(int) source.vertex_count * size_of(u32))
        mem.copy(&dest.indices[0],  source_indices,  cast(int) source.triangle_count * size_of(u8) * 3)
        
        dest.triangle_count = safe_truncate(u8, source.triangle_count)
        dest.vertex_count   = safe_truncate(u8, source.vertex_count)
        
        bounds := meshoptimizer.computeMeshletBounds(source_vertices, source_indices, cast(uint) source.triangle_count, cast(^f32) &mesh.vertices[0], len(mesh.vertices), size_of(mesh.vertices[0]))
        
        dest.cone.xyz = bounds.cone_axis
        dest.cone.w   = bounds.cone_cutoff
    }
    
    
    /* 
    // Trim the meshlet data to minimize waste for meshletVertices/meshletTriangles
    {
    const meshopt_Meshlet& last = meshlets.back();
    meshletVertices.resize(last.vertex_offset + last.vertex_count);
    meshletTriangles.resize(last.triangle_offset + last.triangle_count * 3);
    }
    */
    
    // for &meshlet in meshlets {
    //     meshoptimizer.optimizeMeshlet(&vertices[meshlet.vertex_offset], &indices[meshlet.triangle_offset],  meshlet.triangle_count, auto_cast meshlet.vertex_count)
    // }
    
    return cast(u32) actual_count
}

xx_index :: proc (data: [] $T, indices: [$N] $I) -> [N] T {
    result: [N] T
    for index, i in indices {
        result[i] = data[index]
    }
    return result
}
xx_index_ref :: proc (data: [] $T, indices: [$N] $I) -> [N] ^T {
    result: [N] ^T
    for index, i in indices {
        result[i] = &data[index]
    }
    return result
}

xx_take :: proc (data: [] $T, $N: int) -> [N] T {
    result: [N] T
    for &r, index in result {
        r = data[index]
    }
    return result
}