static const bool Debug = false;

////////////////////////////////////////////////
// @todo(viktor): make the cpu output generated.slang with these structures auto generated based on the cpu layout

// @volatile
static const uint VertexLimit   = 64;
static const uint TriangleLimit = 84;

// @volatile
struct Push_Data {
    Draw_Globals *globals;
    uint     mesh_index;
}

// @volatile
struct Draw_Globals {
    m4 view;
    m4 projection;
    v4 light_pos[4];
    
    u32 meshlet_count;
}

// @volatile
struct Draw_Mesh {
    v3 p;
    f32 scale;
    q4  orientation;
}

// @volatile
struct Meshlet {
    v3  center;
    f32 radius;
    s8  cone_axis[3];
    s8  cone_cutoff;
    
    u32 data_offset;
    u8  vertex_count;
    u8  triangle_count;
}

// @volatile
struct Vertex {
    f32 px, py, pz, p_pad;
    u8  nx, ny, nz, n_pad;
	f32 tu, tv;
}

////////////////////////////////////////////////

[[vk::binding(0)]] StructuredBuffer<Vertex>    vertex_buffer;
[[vk::binding(1)]] StructuredBuffer<Meshlet>   meshlet_buffer;
[[vk::binding(2)]] StructuredBuffer<u32>       meshlet_data_buffer;
[[vk::binding(3)]] StructuredBuffer<Draw_Mesh> draw_buffer;

[[vk::binding(0, 1)]] Sampler2D textures[];

// @volatile, the renderer needs to divide the total meshlet count by this to get the number of shaders to dispatch
static const uint TaskWidth = 32;
static const uint MeshWidth = 32;

groupshared Task_Result result;
groupshared Atomic<uint> meshlet_count;

struct Task_Result {
    u32  offset;
    uint indices[TaskWidth];
}

#define Taskshader 0

#if Taskshader
[shader("task")]
[numthreads(TaskWidth, 1, 1)]
void main(uniform Draw_Globals *globals, uint group_id : SV_GroupID, uint thread_id : SV_GroupThreadID) {
    Task_Result result;
    
    uint group_index = group_id.x;
    uint thread_index = thread_id.x;
    
    uint meshlet_group_offset = group_index * 32;
    if (thread_index == 0) {
        result.offset = meshlet_group_offset;
        meshlet_count.store(0);
    }
    
    uint meshlet_index  = meshlet_group_offset + thread_index;
    // v4 cone = meshlet_buffer[meshlet_index].cone;
    
    // if (!cone_cull(cone.xyz, cone.w, v3(0, 0, 1))) {
    //     uint index = meshlet_count.add(1);
    //     result.indices[index] = (u8) thread_index;
    // }
    
    uint index = meshlet_count.add(1);
    result.indices[index] = thread_index;
    
    GroupMemoryBarrierWithGroupSync();
    
    if (thread_index == 0) {
        uint count = meshlet_count.load();
        DispatchMesh(count, 1, 1, result);
    }
}
#endif

struct Mesh_Result {
    v4 pos    : SV_POSITION;
    v3 normal : NORMAL;
    v2 uv     : TEXCOORD0;
    v3 light_vec[4];
    v3 view_vec;
    
    v3 debug_color;
}

[shader("mesh")]
[outputtopology("triangle")]
[numthreads(MeshWidth, 1, 1)]
[outputtopology("triangle")]
void main(in payload Task_Result input, uniform Push_Data push,
    uint group_index : SV_GroupID, uint thread_index : SV_GroupThreadID,
    out OutputVertices<Mesh_Result, VertexLimit> out_vertices, out OutputIndices<uint3, TriangleLimit> out_indices) {
        
    Meshlet meshlet = {0};
#if Taskshader
    u32 meshlet_index = input.offset + input.indices[group_index];
#else
    u32 meshlet_index = group_index;
#endif
    
    Draw_Globals globals = *push.globals;
    Draw_Mesh draw = draw_buffer[push.mesh_index];
    
    if (meshlet_index < globals.meshlet_count) {
        meshlet = meshlet_buffer[meshlet_index];
    }
    
    m4 view = globals.view;
    
    {
        v3  cone_axis   = v3(meshlet.cone_axis[0], meshlet.cone_axis[1], meshlet.cone_axis[2]) / 127.0f;
        f32 cone_cutoff = meshlet.cone_cutoff / 127.0f;
        v3  center      = meshlet.center;
        f32 radius      = meshlet.radius;
        
        cone_axis = rotate(draw.orientation, cone_axis);
        center    = rotate(draw.orientation, center) * draw.scale + draw.p;
        radius   *= draw.scale;
        
        v3 camera_position = v3(view[0].w, view[1].w, view[2].w);
        
        if (cone_cull(center, radius, cone_axis, cone_cutoff, camera_position)) {
            SetMeshOutputCounts(0, 0);
            return;
        }
    }
    
    SetMeshOutputCounts(meshlet.vertex_count, meshlet.triangle_count);
    
    uint vertex_offset = meshlet.data_offset;
    uint index_offset  = vertex_offset + meshlet.vertex_count;
    for (int i = thread_index; i < meshlet.vertex_count; i += MeshWidth) {
        uint vertex_index = meshlet_data_buffer[vertex_offset + i];
        Vertex vertex = vertex_buffer[vertex_index];
        
        v3 p = v3(vertex.px, vertex.py, vertex.pz);
        p = rotate(draw.orientation, p);
        p *= draw.scale;
        p += draw.p;
        v4 view_p = v4(p, 1);
        
        v3 n = v3(vertex.nx, vertex.ny, vertex.nz) / 127.0 - 1.0;
        // @todo(viktor): fix normal rotation
        v2 t = v2(vertex.tu, vertex.tv);
        
        Mesh_Result result;
        view_p = mul(globals.view, view_p);
        
        result.pos    = mul(globals.projection, mul(globals.view, view_p));
        result.normal = mul((m3) globals.view, n);
        result.uv = t;
        
        // Calculate view vectors required for lighting
        for (int li = 0; li < 4; li++) {
            result.light_vec[li] = globals.light_pos[li].xyz - view_p.xyz;
        }
        result.view_vec = -view_p.xyz;
        
        if (Debug) {
            uint mhash = hash(meshlet_index);
            result.debug_color = v3(f32(mhash & 255), f32((mhash >> 8) & 255), f32((mhash >> 16) & 255)) / 255;
        }
        
        out_vertices[i] = result;
    }
    
    // @speed as the indices are really [3] u8, we could write them packed into a u32 and get 4x throughput
    // [a  b  c  d][e  f  g  h][i  j  k  l]
    // [a  b  c][d  e  f][g  h  i][j  k  l]
    uint triangle_index = thread_index * 4;
    int  word_offset    = thread_index * 3;
    uint group_count    = (meshlet.triangle_count * 3 + 3) / 4;
    while (word_offset < group_count) {
        uint word_index = index_offset + word_offset;
        
        uint4 u0 = unpack_u8u32(meshlet_data_buffer[word_index + 0]);
        uint4 u1 = unpack_u8u32(meshlet_data_buffer[word_index + 1]);
        uint4 u2 = unpack_u8u32(meshlet_data_buffer[word_index + 2]);
        
        out_indices[triangle_index+0] = u0.xyz;
        out_indices[triangle_index+1] = uint3(u0.w, u1.xy);
        out_indices[triangle_index+2] = uint3(u1.zw, u2.x);
        out_indices[triangle_index+3] = u2.yzw;
        
        triangle_index += 4 * MeshWidth;
        word_offset    += 3 * MeshWidth;
    }
}

[shader("fragment")]
v4 main(Mesh_Result input) {
    v3 diffuse  = v3(0);
    v3 specular = v3(0);
    
    // Phong lighting
    v3 n = normalize(input.normal);
    v3 v = normalize(input.view_vec);
    for (int li = 0; li < 4; li++) {
        v3 l = normalize(input.light_vec[li]);
        v3 r = reflect(-l, n);
        diffuse  += max(dot(n, l), 0.0025);
        specular += pow(max(dot(r, v), 0.0), 16.0) * 0.75;
    }
    
    Sampler2D texture = textures[NonUniformResourceIndex(0)];
    v3 albedo = texture.Sample(input.uv).rgb;
    v3 color = diffuse * albedo + specular;
    
    if (Debug) {
        color = input.debug_color;
    }
    
    return v4(color, 1);
}

////////////////////////////////////////////////

inline bool cone_cull(v3 center, f32 radius, v3 axis, f32 cutoff, v3 camera) {
    v3 delta = center - camera;
    return dot(delta, axis) > cutoff * length(delta) + radius;
}

uint hash(uint a) {
    a = (a + 0x7ed55d16) + (a << 12);
    a = (a ^ 0xc761c23c) ^ (a >> 19);
    a = (a + 0x165667b1) + (a << 5);
    a = (a + 0xd3a2646c) ^ (a << 9);
    a = (a + 0xfd7046c5) + (a << 3);
    a = (a ^ 0xb55a4f09) ^ (a >> 16);
    return a;
}

import "common.slang";