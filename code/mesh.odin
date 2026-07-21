#+vet explicit-allocators
package main

import "core:fmt"
import "core:strings"

import "../lib/meshoptimizer"
import "vendor:cgltf"

//
// @speed The loading from ssd and the memory overhead themselves are not the bottleneck. It is the 
// generation and processing of meshlets, which takes the majority of the time. But this whole process 
// is embarrisingly parallel. The only shared resource are the buffers in geometry, which would need to
// have their access synchronized, so that no 2 threads use the same memory and that no thread uses
// memory that was freed, if any buffer needed to be reallocated to grow.
//
load_scene :: proc (geometry: ^Geometry, filepath: string, draws: ^[dynamic] Draw, camera: ^Camera, texture_paths: ^[dynamic] string) -> bool {
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
    
    floats   := make([dynamic] f32,    context.temp_allocator)
    vertices := make([dynamic] Vertex, context.temp_allocator)
    indices  := make([dynamic] u32,    context.temp_allocator)
    
    Primitive :: struct { mesh_offset, primitive_count: int }
    primitives := make([dynamic] Primitive,       context.temp_allocator)
    materials  := make([dynamic] ^cgltf.material, context.temp_allocator)
    
    first_mesh_offset := len(geometry.meshes)
    
    for mesh in data.meshes {
        mesh_offset := len(geometry.meshes)
        
        for &primitive in mesh.primitives {
            // @todo remove asserts and fix the material lookup for the draws
            if primitive.type != .triangles { assert(false); continue }
            if primitive.indices == nil     { assert(false); continue }
            
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
            
            non_zero_resize(&vertices, vertex_count)
            non_zero_resize(&floats, vertex_count * 4)
            
            if positions := find_accessor(&primitive, .position); positions != nil {
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
            
            if normals := find_accessor(&primitive, .normal); normals != nil {
                components :: len(Vertex{}.n)
                assert(cgltf.num_components(normals.type) == components)
                
                _ = cgltf.accessor_unpack_floats(normals, &floats[0], vertex_count * components)
                
                for vertex_index in 0..<vertex_count {
                    vertices[vertex_index].n = pack_normal_or_tangent(v3 {
                        floats[vertex_index * components + 0],
                        floats[vertex_index * components + 1],
                        floats[vertex_index * components + 2],
                    })
                }
            }
            
            if tangents := find_accessor(&primitive, .tangent); tangents != nil {
                components :: len(Vertex{}.t)
                assert(cgltf.num_components(tangents.type) == components)
                
                _ = cgltf.accessor_unpack_floats(tangents, &floats[0], vertex_count * components)
                
                for vertex_index in 0..<vertex_count {
                    vertices[vertex_index].t = pack_normal_or_tangent(v4 {
                        floats[vertex_index * components + 0],
                        floats[vertex_index * components + 1],
                        floats[vertex_index * components + 2],
                        floats[vertex_index * components + 3],
                    })
                }
            }
            
            if uvs := find_accessor(&primitive, .texcoord); uvs != nil {
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
            
            non_zero_resize(&indices, primitive.indices.count)
            
            _ = cgltf.accessor_unpack_indices(primitive.indices, &indices[0], size_of(indices[0]), len(indices))
            
            append_mesh(geometry, vertices[:], indices[:])
            append(&materials, primitive.material)
        }
        
        append(&primitives, Primitive { mesh_offset , len(geometry.meshes) - mesh_offset})
    }
    
    assert(len(materials) + first_mesh_offset == len(geometry.meshes))
    
    for &node in data.nodes {
        if node.mesh != nil {
            world_matrix: m4
            cgltf.node_transform_world(&node, raw_data(&world_matrix))
            t, r, s := decompose_transform(world_matrix)
            
            mesh_index := cast(int) cgltf.mesh_index(data, node.mesh)
            slot := primitives[mesh_index]
            
            for index in 0..<slot.primitive_count {
                if s.x != s.y || s.x != s.z {
                    // fmt.printfln("%v: Warning: A mesh has non-uniform scale(%v), which we don't handle. This mesh will not be drawn correctly.", #location(), s)
                }
                
                draw := append_into(draws)
                draw.p             = t
                draw.scale         = max(s.x, s.y, s.z)
                draw.orientation   = r
                draw.mesh_index    = cast(u32) (mesh_index + index)
                draw.vertex_offset = geometry.meshes[draw.mesh_index].vertex_offset
                
                material := materials[draw.mesh_index - cast(u32) first_mesh_offset]
                if material != nil {
                    if material.pbr_metallic_roughness.base_color_texture.texture != nil {
                        draw.albedo_texture = cast(Texture_Index) cgltf.texture_index(data, material.pbr_metallic_roughness.base_color_texture.texture)
                    } else if material.pbr_specular_glossiness.diffuse_texture.texture != nil {
                        draw.albedo_texture = cast(Texture_Index) cgltf.texture_index(data, material.pbr_specular_glossiness.diffuse_texture.texture)
                    }
                    if material.normal_texture.texture != nil {
                        draw.normal_texture = cast(Texture_Index) cgltf.texture_index(data, material.normal_texture.texture)
                    }
                    // @todo load specular texture
                    if material.emissive_texture.texture != nil {
                        draw.emmisive_texture = cast(Texture_Index) cgltf.texture_index(data, material.emissive_texture.texture)
                    }
                }
                
                if material != nil && material.alpha_mode != .opaque {
                    draw.post_pass = true
                }
            }
        }
        
        if node.camera != nil {
            world_matrix: m4
            cgltf.node_transform_world(&node, raw_data(&world_matrix))
            t, r, _ := decompose_transform(world_matrix)
            
            cam := node.camera
            assert(cam.type == .perspective)
            
            camera.p           = t
            camera.orientation = r
            camera.fov_y       = cam.data.perspective.yfov
        }
    }
    
    // @hack real path handling?
    slash_index := strings.last_index_byte(filepath, '/')
    assert(slash_index != -1, "use a path with a slash '/' not a '\\'")
    base_path := filepath[:slash_index+1]
    
    for texture in data.textures {
        assert(texture.image_ != nil)
        
        image := texture.image_
        assert(image.uri != nil)
        uri_size := cgltf.decode_uri(image.uri)
        assert(uri_size <= len(image.uri))
        
        // @hack
        png_path := tprint("%v%v", base_path, (cast(string) image.uri)[:uri_size])
        
        dds_path, _ := strings.replace(png_path, ".png", ".dds", 1, context.temp_allocator)
        append(texture_paths, dds_path)
    }
    
    return true
}

pack_normal_or_tangent :: proc (n: [$N] f32) -> [N] u8 {
    result := cast([N] u8) (n * 127 + 127.5)
    return result
}

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
    m[2, 0] * (m[0, 1] * m[1, 2] - m[1, 1] * m[0, 2])
    
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
    _rotation[qc ~ 0] = qs * qt
    _rotation[qc ~ 1] = qs * (r01 + qs1 * r10)
    _rotation[qc ~ 2] = qs * (r20 + qs2 * r02)
    _rotation[qc ~ 3] = qs * (r12 + qs3 * r21)
    
    return translation, rotation, scale
}

append_mesh :: proc (geometry: ^Geometry, mesh_vertices: [] Vertex, mesh_indices: [] u32) {
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
        lod.index_count  = cast(u32) len(lod_indices)
        lod.index_offset = cast(u32) len(geometry.indices)
        append(&geometry.indices, ..lod_indices)
        
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
    cone_weight  :: 0.25 // 0 when not culling, otherwise 0..1 
    
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