package main

import "lib:meshoptimizer"

// @study look into mesh_optimizer and optimizeVertexCache, optimizeVertexFetch as well as remapVertex/IndexBuffer
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

// @speed for cache reasons we should, if possible, do this either whilst loading or combined with other processing, or just offline
build_meshlets :: proc (mesh: ^Mesh) {
    Missing :: ~cast(u8) 0
    meshlet_vertices := make([] u8, len(mesh.vertices), context.temp_allocator)
    for &it in meshlet_vertices do it = Missing
    
    meshlet: ^Meshlet
    append_nothing(&mesh.meshlets)
    meshlet = &mesh.meshlets[len(mesh.meshlets)-1]
    
    for it: int; it+2 < len(mesh.indices); it += 3 {
        is := xx_take(mesh.indices[it:], 3)
        
        new_vertices: u8
        vs := xx_index_ref(meshlet_vertices[:], is)
        for v in vs {
            if v^ == Missing {
                new_vertices += 1
            }
        }
        
        flush: bool
        if meshlet.vertex_count + new_vertices > len(meshlet.vertices) {
            flush = true
        }
        
        if meshlet.triangle_count >= len(meshlet.indices) {
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
                meshlet.vertices[meshlet.vertex_count] = is[index]
                meshlet.vertex_count += 1 
            }
        }
        
        for v, index in vs {
            meshlet.indices[meshlet.triangle_count][index] = v^
        }
        meshlet.triangle_count += 1
    }
}

build_meshlet_cones :: proc (mesh: ^Mesh) {
    for &meshlet in mesh.meshlets {
        normals: [len(meshlet.indices) * len(meshlet.indices[0])] v3
        
        for indexes, i in meshlet.indices[:meshlet.triangle_count] {
            v := xx_index(mesh.vertices[:], indexes)
            
            edge_01 := v[1].p - v[0].p
            edge_02 := v[2].p - v[0].p
            
            normal := cross(edge_01, edge_02)
            
            normals[i] = normalize_or_zero(normal)
        }
        
        average: v3
        for normal in normals {
            average += normal
        }
        
        average = normalize_or_else(average) or_else {1, 0, 0}
        
        min_cos_angle: f32 = 1
        for normal, i in normals[:meshlet.triangle_count] {
            cos_angle := dot(normal, average)
            min_cos_angle = min(min_cos_angle, cos_angle)
        }
        
        // @note(viktor): For a cone to be frontfacing, the angle between view vector and cone should be < 90° 
        // cone.w = min_dot = dot(avg, x) = cos(a)
        // if view = x + 90 => cos(b) 
        //   = cos(a+90)
        //   = -sin(a)
        // a = acos(cos(a))
        // a = acos(dot(avg,x))
        // => -sin(a) = -sin(acos(dot(avg,x)))
        //            = -sqrt(1-min_dot²)
        
        cone_w: f32 = -1
        if min_cos_angle > 0 {
            cone_w = -square_root(1 - square(min_cos_angle))
        }
        // We then invert this value to not have to do the negation in the shader
        cone_w = -cone_w
        
        meshlet.cone.xyz = average
        meshlet.cone.w   = cone_w
    }
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