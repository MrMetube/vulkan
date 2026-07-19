#+vet explicit-allocators
package main

import "core:fmt"
import la "core:math/linalg"

import "../lib/meshoptimizer"
import "../lib/tobj"
import "vendor:cgltf"

load_obj_mesh :: proc (geometry: ^Geometry, filepath: string) -> bool {
    models, _, error := tobj.load_obj_filename(filepath, allocator = context.temp_allocator)
    if error != nil {
        fmt.eprintfln("Failed to load mesh from file %q", filepath)
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
        
        v = { p = p, n = pack_normal(n), uv = cast(hv2) uv }
    }
    
    mesh_indices := model.indices[:]
    
    ////////////////////////////////////////////////
    // optimize mesh
    
    {
        remap := make([] u32, len(mesh_indices), context.temp_allocator)
        
        vertex_count := meshoptimizer.generateVertexRemap(&remap[0], &mesh_indices[0], len(mesh_indices), &mesh_vertices[0], len(mesh_vertices), size_of(Vertex))
        
        result_vertices := make([] Vertex, vertex_count,   context.temp_allocator)
        result_indices  := make([] u32, len(mesh_indices), context.temp_allocator)
        
        meshoptimizer.remapVertexBuffer(&result_vertices[0], &mesh_vertices[0], len(mesh_vertices), size_of(Vertex), &remap[0])
        meshoptimizer.remapIndexBuffer(&result_indices[0],   &mesh_indices[0],  len(mesh_indices),                   &remap[0])
        
        mesh_vertices = result_vertices
        mesh_indices  = result_indices
    }
    
    load_mesh(geometry, mesh_vertices, mesh_indices)
    return true
}

pack_normal :: proc (n: v3) -> [3] u8 {
    result := cast([3] u8) (n * 127 + 127.5)
    return result
}

load_scene :: proc (geometry: ^Geometry, filepath: string, draws: ^[dynamic] Draw) -> bool {
    path := fmt.ctprint(filepath)
    
    options: cgltf.options
    data, result := cgltf.parse_file(options, path)
    defer cgltf.free(data)
    
    if result != .success {
        fmt.eprintfln("Failed to load scene from file %q (parsing error): %v", path, result)
        return false
    }
    
    result = cgltf.load_buffers(options, data, path)
    if result != .success {
        fmt.eprintfln("Failed to load scene from file %q (loading error): %v", path, result)
        return false
    }
    
    result = cgltf.validate(data)
    if result != .success {
        fmt.eprintfln("Failed to load scene from file %q (validation error): %v", path, result)
        return false
    }
    
    floats   := make([dynamic] f32, context.temp_allocator)
    vertices := make([dynamic] Vertex, context.temp_allocator)
    indices  := make([dynamic] u32, context.temp_allocator)
    for mesh in data.meshes {
        assert(len(mesh.primitives) == 1, "@todo A mesh has submeshes, which we don't handle")
        
        primitive := &mesh.primitives[0]
        assert(primitive.type == .triangles)
        assert(primitive.indices != nil)
        
        find_accessor :: proc (primitive: ^cgltf.primitive, type: cgltf.attribute_type, index: i32 = 0) -> ^cgltf.accessor {
            result: ^cgltf.accessor
            
            for attribute in primitive.attributes {
                if attribute.type == type && attribute.index == index {
                    result = attribute.data
                    break
                }
            }
            
            return result
        }
        
        clear(&vertices)
        clear(&indices)
        
        vertex_count := primitive.attributes[0].data.count
        
        resize(&vertices, vertex_count)
        non_zero_resize(&floats, vertex_count * 4) // @speed make more resizes non_zero
        
        if positions := find_accessor(primitive, .position); positions != nil {
            components :: len(Vertex{}.p)
            assert(cgltf.num_components(positions.type) == components)
            
            _ = cgltf.accessor_unpack_floats(positions, &floats[0], vertex_count * components)
            
            for vertex_index in 0..<vertex_count {
                vertices[vertex_index].p = {
                    floats[vertex_index * components + 0],
                    floats[vertex_index * components + 1],
                    floats[vertex_index * components + 2],
                }
            }
        }
        
        if normals := find_accessor(primitive, .normal); normals != nil {
            components :: len(Vertex{}.n)
            assert(cgltf.num_components(normals.type) == components)
            
            _ = cgltf.accessor_unpack_floats(normals, &floats[0], vertex_count * components)
            
            for vertex_index in 0..<vertex_count {
                vertices[vertex_index].n = pack_normal(v3 {
                    floats[vertex_index * components + 0],
                    floats[vertex_index * components + 1],
                    floats[vertex_index * components + 2],
                })
            }
        }
        
        if uvs := find_accessor(primitive, .texcoord); uvs != nil {
            components :: len(Vertex{}.uv)
            assert(cgltf.num_components(uvs.type) == components)
            
            _ = cgltf.accessor_unpack_floats(uvs, &floats[0], vertex_count * components)
            
            for vertex_index in 0..<vertex_count {
                vertices[vertex_index].uv = cast(hv2) v2 {
                    floats[vertex_index * components + 0],
                    floats[vertex_index * components + 1],
                }
            }
        }
        
        resize(&indices, primitive.indices.count)
        _ = cgltf.accessor_unpack_indices(primitive.indices, &indices[0], size_of(indices[0]), len(indices))
        
        load_mesh(geometry, vertices[:], indices[:])
    }
    
    for &node in data.nodes {
        if node.mesh != nil {
            world_matrix: m4
            cgltf.node_transform_world(&node, raw_data(&world_matrix))
            
            // stolen from zeux's niagara code
            decompose_transform :: proc (m: m4) -> (translation: v3, rotation: q32, scale: v3) {
                // extract translation from last row
                translation[0] = m[0, 3]
                translation[1] = m[1, 3]
                translation[2] = m[2, 3]
                
                // compute determinant to determine handedness
                det := 
                    m[0, 0] * (m[1, 1] * m[2, 2] - m[1, 2] * m[2, 1]) -
                    m[1, 0] * (m[0, 1] * m[2, 2] - m[2, 1] * m[0, 2]) +
                    m[2, 0] * (m[0, 1] * m[1, 2] - m[1, 1] * m[0, 2]);
                
                sign : f32 = det < 0 ? -1 : 1
                
                // recover scale from axis lengths
                scale[0] = square_root(m[0, 0] * m[0, 0] + m[1, 0] * m[1, 0] + m[2, 0] * m[2, 0]) * sign
                scale[1] = square_root(m[0, 1] * m[0, 1] + m[1, 1] * m[1, 1] + m[2, 1] * m[2, 1]) * sign
                scale[2] = square_root(m[0, 2] * m[0, 2] + m[1, 2] * m[1, 2] + m[2, 2] * m[2, 2]) * sign
                
                // normalize axes to get a pure rotation matrix
                rsx := (scale[0] == 0) ? 0 : 1 / scale[0]
                rsy := (scale[1] == 0) ? 0 : 1 / scale[1]
                rsz := (scale[2] == 0) ? 0 : 1 / scale[2]
                
                r00, r10, r20 := m[0, 0] * rsx, m[0, 1] * rsy, m[0, 2] * rsz
                r01, r11, r21 := m[1, 0] * rsx, m[1, 1] * rsy, m[1, 2] * rsz
                r02, r12, r22 := m[2, 0] * rsx, m[2, 1] * rsy, m[2, 2] * rsz
                
                // "branchless" version of Mike Day's matrix to quaternion conversion
                qc  := r22 < 0 ? (r00 > r11 ? 0 : 1) : (r00 < -r11 ? 2 : 3)
                qs1 : f32 = (      qc & 2) != 0 ? -1 : 1
                qs2 : f32 = (      qc & 1) != 0 ? -1 : 1
                qs3 : f32 = ((qc - 1) & 2) != 0 ? -1 : 1
                
                qt := 1 - qs3*r00 - qs2*r11 - qs1*r22
                qs := 0.5 / square_root(qt)
                
                _rotation := cast(^v4) &rotation 
                _rotation[qc ~ 0] = qs * qt;
                _rotation[qc ~ 1] = qs * (r01 + qs1 * r10)
                _rotation[qc ~ 2] = qs * (r20 + qs2 * r02)
                _rotation[qc ~ 3] = qs * (r12 + qs3 * r21)
                
                return translation, rotation, scale
            }
            
            t, r, s := decompose_transform(world_matrix)
            if s.x != s.y || s.x != s.z {
                fmt.printfln("%v: Warning: A mesh has non-uniform scale(%v), which we don't handle. This mesh will not be drawn correctly.", #location(), s)
            }
            
            draw := append_into(draws)
            draw.p           = t
            draw.scale       = max(s.x, s.y, s.z)
            draw.orientation = r
            draw.mesh_index  = cast(u32) cgltf.mesh_index(data, node.mesh)
            draw.vertex_offset = geometry.meshes[draw.mesh_index].vertex_offset
        }
    }
    
    return true
}


////////////////////////////////////////////////

load_mesh :: proc (geometry: ^Geometry, mesh_vertices: [] Vertex, mesh_indices: [] u32) {
    meshoptimizer.optimizeVertexCache(&mesh_indices[0],  &mesh_indices[0], len(mesh_indices),                    len(mesh_vertices))
    meshoptimizer.optimizeVertexFetch(&mesh_vertices[0], &mesh_indices[0], len(mesh_indices), &mesh_vertices[0], len(mesh_vertices), size_of(Vertex)) 
    
    vertex_offset := cast(u32) len(geometry.vertices)
    append(&geometry.vertices, ..mesh_vertices)
    
    mesh_vertices := mesh_vertices
    mesh_vertices  = geometry.vertices[vertex_offset:][:len(mesh_vertices)]
    
    mesh := append_into(&geometry.meshes)
    mesh.vertex_offset  = vertex_offset
    mesh.vertex_count   = cast(u32) len(mesh_vertices)
    
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
}

append_meshlets :: proc (geometry: ^Geometry, mesh_vertices: [] Vertex, mesh_indices: [] u32) -> (count: u32) {
    // :Shader: meshlet.mesh
    MaxVertices  ::  64
    MaxTriangles :: 126
    cone_weight :: 0.25 // 0 when not culling, otherwise 0..1 
    
    max_meshlet_count := meshoptimizer.buildMeshletsBound(auto_cast len(mesh_indices), MaxVertices, MaxTriangles)
    
    meshlets := make([] meshoptimizer.Meshlet, max_meshlet_count, context.temp_allocator)
    vertices := make([] u32,                   len(mesh_indices), context.temp_allocator)
    indices  := make([] u8,                    len(mesh_indices), context.temp_allocator)
    
    meshlet_count := cast(u32) meshoptimizer.buildMeshlets(&meshlets[0], &vertices[0], &indices[0], &mesh_indices[0], len(mesh_indices), cast(^f32) &mesh_vertices[0], len(mesh_vertices), size_of(mesh_vertices[0]), MaxVertices, MaxTriangles, cone_weight)
    
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
