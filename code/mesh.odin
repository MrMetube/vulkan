#+vet explicit-allocators
package main

import "../lib/meshoptimizer"
import "../lib/tobj"

load_mesh :: proc (geometry: ^Geometry, filepath: string, _allocator: Allocator) -> bool {
    models, _, error := tobj.load_obj_filename(filepath, allocator = context.temp_allocator)
    if error != nil {
        return false
    }
    
    model := models[0].mesh
    
    mesh_vertices := make([] Vertex, len(model.vertices), context.temp_allocator)
    
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
            n  = cast([3] u8) ((n + 1) * 127.5),
            uv = uv,
        }
    }
    
    mesh_indices := model.indices[:]
    
    ////////////////////////////////////////////////
    // optimize mesh
    
    mesh := append_into(&geometry.meshes)
    mesh.vertex_offset  = cast(u32) len(geometry.vertices)
    mesh.vertex_count   = cast(u32) len(mesh_vertices)
    
    {
        remap := make([] u32, len(mesh_indices), context.temp_allocator)
        
        vertex_count := meshoptimizer.generateVertexRemap(&remap[0], &mesh_indices[0], len(mesh_indices), &mesh_vertices[0], len(mesh_vertices), size_of(Vertex))
        
        start := mesh.vertex_offset
        resize(&geometry.vertices, start + auto_cast vertex_count)
        
        result_vertices := geometry.vertices[start:][:vertex_count]
        result_indices  := make([] u32,    len(mesh_indices), context.temp_allocator)
        
        meshoptimizer.remapVertexBuffer(&result_vertices[0], &mesh_vertices[0], len(mesh_vertices), size_of(Vertex), &remap[0])
        meshoptimizer.remapIndexBuffer(&result_indices[0],   &mesh_indices[0],  len(mesh_indices), &remap[0])
        
        meshoptimizer.optimizeVertexCache(&result_indices[0], &result_indices[0], len(result_indices), len(result_vertices))
        meshoptimizer.optimizeVertexFetch(&result_vertices[0], &result_indices[0], len(result_indices), &result_vertices[0], len(result_vertices), size_of(Vertex)) 
        
        mesh_vertices = result_vertices
        mesh_indices  = result_indices
    }
    
    ////////////////////////////////////////////////
    // compute cone for backface culling
    
    center: v3
    for vertex in mesh_vertices {
        center += vertex.p
    }
    center /= cast(f32) len(mesh_vertices)
    
    radius_squared: f32
    for vertex in mesh_vertices {
        radius_squared = max(radius_squared, length_squared(vertex.p - center))
    }
    
    mesh.center = center
    mesh.radius = square_root(radius_squared)
    
    ////////////////////////////////////////////////
    // build meshlets per lod
    
    lod_indices := make_shallow_copy(mesh_indices, context.temp_allocator)
    
    LOD_Factor :: 0.5
    LOD_Error  :: 1e-2
    
    for &lod in mesh.lods {
        lod.meshlet_offset = cast(u32) len(geometry.meshlets)
        lod.meshlet_count  = append_meshlets(geometry, mesh_vertices, lod_indices[:])
        mesh.lod_count += 1
        
        next_count_target := floor(uint, cast(f32) len(lod_indices) * LOD_Factor)
        
        next_count := meshoptimizer.simplify(&lod_indices[0], &lod_indices[0], len(lod_indices), &mesh_vertices[0].p[0], len(mesh_vertices), size_of(mesh_vertices[0]), next_count_target, LOD_Error, {}, nil)
        assert(next_count <= len(lod_indices))
        if next_count == len(lod_indices) { break }
        lod_indices = lod_indices[:next_count]
    }
    
    return true
}

append_meshlets :: proc (geometry: ^Geometry, mesh_vertices: [] Vertex, mesh_indices: [] u32) -> (count: u32) {
    max_vertices  :: MaxVertices
    max_triangles :: MaxTriangles 
    cone_weight :: 0.5 // 0 when not culling, otherwise 0..1 
    
    max_meshlet_count := meshoptimizer.buildMeshletsBound(auto_cast len(mesh_indices), max_vertices, max_triangles)
    
    meshlets := make([] meshoptimizer.Meshlet, max_meshlet_count, context.temp_allocator)
    vertices := make([] u32,                   len(mesh_indices), context.temp_allocator)
    indices  := make([] u8,                    len(mesh_indices), context.temp_allocator)
    
    meshlet_count := cast(u32) meshoptimizer.buildMeshlets(&meshlets[0], &vertices[0], &indices[0], &mesh_indices[0], len(mesh_indices), cast(^f32) &mesh_vertices[0], len(mesh_vertices), size_of(mesh_vertices[0]), max_vertices, max_triangles, cone_weight)
    
    for source in meshlets[:meshlet_count] {
        dest := append_into(&geometry.meshlets)
        
        source_vertices := vertices[source.vertex_offset:]
        source_indices  := indices[source.triangle_offset:]
        
        dest.data_offset = cast(u32) len(geometry.meshlet_data)
        dest.triangle_count = safe_truncate(u8, source.triangle_count)
        dest.vertex_count   = safe_truncate(u8, source.vertex_count)
        
        index_group_count := (source.triangle_count * 3 + 3) / 4
        
        index_groups := slice_from_parts(u32, &source_indices[0], index_group_count)
        
        append(&geometry.meshlet_data, ..source_vertices[:source.vertex_count])
        append(&geometry.meshlet_data, ..index_groups[:index_group_count])
        
        bounds := meshoptimizer.computeMeshletBounds(&source_vertices[0], &source_indices[0], cast(uint) source.triangle_count, cast(^f32) &mesh_vertices[0], len(mesh_vertices), size_of(mesh_vertices[0]))
        
        dest.center = bounds.center
        dest.radius = bounds.radius
        dest.cone_axis   = bounds.cone_axis_s8
        dest.cone_cutoff = bounds.cone_cutoff_s8
        
        meshlet_vertices  := &geometry.meshlet_data[dest.data_offset]
        meshlet_triangles := &geometry.meshlet_data[dest.data_offset + auto_cast dest.vertex_count]
        meshoptimizer.optimizeMeshlet(meshlet_vertices, cast(^u8) meshlet_triangles, auto_cast dest.triangle_count, auto_cast dest.vertex_count)
    }
    
    return meshlet_count
}