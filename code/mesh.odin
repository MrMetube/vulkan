#+vet explicit-allocators
package main

import "lib:meshoptimizer"
import "lib:tobj"

load_mesh :: proc (geometry: ^Geometry, filepath: string, allocator: Allocator) -> bool {
    // @todo(viktor): dont use allocator param, if we know its temporary
    models, _, error := tobj.load_obj_filename(filepath, allocator = allocator)
    if error != nil {
        return false
    }
    
    model := models[0].mesh
    
    mesh_vertices := make([] Vertex, len(model.vertices), allocator)
    
    has_uvs := len(model.texture_coords) != 0
    
    for &v, index in mesh_vertices {
        n := model.normals[index]
        p := model.vertices[index]
        uv: v2
        if has_uvs {
            uv = model.texture_coords[index] * { 1, -1 }
        }
        
        v = Vertex {
            p  = p,
            n  = cast([3] u8) ((n + 1) * 127),
            uv = uv,
        }
    }
    
    // @waste we allocate vertices and indices, only to then optimize them and throw the original away
    mesh_indices := model.indices[:]
    
    ////////////////////////////////////////////////
    // optimize mesh
    {
        remap := make([] u32, len(mesh_indices), allocator)
        defer delete(remap, allocator)
        
        vertex_count := meshoptimizer.generateVertexRemap(&remap[0], &mesh_indices[0], len(mesh_indices), &mesh_vertices[0], len(mesh_vertices), size_of(Vertex))
        
        result_vertices := make([] Vertex, vertex_count, allocator)
        result_indices  := make([] u32,    len(mesh_indices), allocator)
        
        meshoptimizer.remapVertexBuffer(&result_vertices[0], &mesh_vertices[0], len(mesh_vertices), size_of(Vertex), &remap[0])
        meshoptimizer.remapIndexBuffer(&result_indices[0],   &mesh_indices[0],  len(mesh_indices), &remap[0])
        
        meshoptimizer.optimizeVertexCache(&result_indices[0], &result_indices[0], len(result_indices), len(result_vertices))
        meshoptimizer.optimizeVertexFetch(&result_vertices[0], &result_indices[0], len(result_indices), &result_vertices[0], len(result_vertices), size_of(Vertex)) 
        
        delete(mesh_vertices, allocator)
        
        mesh_vertices = result_vertices
        mesh_indices  = result_indices
    }
    
    vertex_offset := cast(u32) len(geometry.vertices)
    append(&geometry.vertices, ..mesh_vertices)
    
    mesh: Mesh
    mesh.triangle_count = cast(u32) len(mesh_indices) / 3
    mesh.meshlet_offset = cast(u32) len(geometry.meshlets)
    
    ////////////////////////////////////////////////
    // build meshlets
    
    {
        max_vertices  :: MaxVertices
        max_triangles :: MaxTriangles 
        cone_weight :: 0 // 0 when not culling, otherwise 0..1 
        
        max_count := meshoptimizer.buildMeshletsBound(auto_cast len(mesh_indices), max_vertices, max_triangles)
        
        meshlets := make([] meshoptimizer.Meshlet, max_count, context.temp_allocator)
        vertices := make([] u32, len(mesh_indices), context.temp_allocator)
        indices  := make([] u8,  len(mesh_indices), context.temp_allocator)
        
        actual_count := meshoptimizer.buildMeshlets(&meshlets[0], &vertices[0], &indices[0], &mesh_indices[0], len(mesh_indices), cast(^f32) &mesh_vertices[0], len(mesh_vertices), size_of(mesh_vertices[0]), max_vertices, max_triangles, cone_weight)
        
        for source in meshlets[:actual_count] {
            append_nothing(&geometry.meshlets)
            dest := &geometry.meshlets[len(geometry.meshlets)-1]
            
            source_vertices := vertices[source.vertex_offset:]
            source_indices  := indices[source.triangle_offset:]
            
            dest.data_offset = cast(u32) len(geometry.meshlet_data)
            dest.triangle_count = safe_truncate(u8, source.triangle_count)
            dest.vertex_count   = safe_truncate(u8, source.vertex_count)
            
            index_group_count := (source.triangle_count * 3 + 3) / 4
            
            index_groups := slice_from_parts(u32, &source_indices[0], index_group_count)
            
            for i in 0..<source.vertex_count {
                append(&geometry.meshlet_data, vertex_offset + source_vertices[i])
            }
            for i in 0..<index_group_count {
                append(&geometry.meshlet_data, index_groups[i])
            }
            
            bounds := meshoptimizer.computeMeshletBounds(&source_vertices[0], &source_indices[0], cast(uint) source.triangle_count, cast(^f32) &mesh_vertices[0], len(mesh_vertices), size_of(mesh_vertices[0]))
            
            dest.center = bounds.center
            dest.radius = bounds.radius
            dest.cone_axis   = bounds.cone_axis_s8
            dest.cone_cutoff = bounds.cone_cutoff_s8
        }
        
        for &meshlet in geometry.meshlets[mesh.meshlet_offset:] {
            meshlet_vertices  := &geometry.meshlet_data[meshlet.data_offset]
            meshlet_triangles := &geometry.meshlet_data[meshlet.data_offset + auto_cast meshlet.vertex_count]
            meshoptimizer.optimizeMeshlet(meshlet_vertices, cast(^u8) meshlet_triangles, auto_cast meshlet.triangle_count, auto_cast meshlet.vertex_count)
        }
        
        mesh.meshlet_count = cast(u32) actual_count
    }
    
    append(&geometry.meshes, mesh)
    
    return true
}