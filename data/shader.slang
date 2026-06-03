typealias u8  = uint8_t;
typealias u16 = uint16_t;
typealias u32 = uint32_t;

typealias f16 = half;
typealias f32 = float;
typealias v2 = float2;
typealias v3 = float3;
typealias v4 = float4;
typealias m3 = float3x3;
typealias m4 = float4x4;


static const bool Debug = false;

static const uint VertexLimit   = 64;
static const uint TriangleLimit = 84;

// @volatile cpu needs to match this layout
struct Data {
    m4 projection;
    m4 view;
    m4 model;
    v4 light_pos[4];
    
    u32 meshlet_count;
}

// @volatile cpu needs to match this layout
struct Vertex {
    f32 px, py, pz, p_pad;
    u8  nx, ny, nz, n_pad;
	f32 tu, tv;
}

// @volatile cpu needs to match this layout
struct Meshlet {
    v4  cone;
    u32 vertices[VertexLimit];
    u8  indices[TriangleLimit][3];
    u8  triangle_count;
    u8  vertex_count;
}

[[vk::binding(0)]] StructuredBuffer<Vertex> vertex_buffer;
[[vk::binding(1)]] StructuredBuffer<Meshlet> meshlet_buffer;

[[vk::binding(0, 1)]] Sampler2D textures[];

struct Task_Result {
    u8 indices[TaskWidth];
    uint meshlet_group;
}

struct Mesh_Result {
    v4 pos    : SV_POSITION;
    v3 normal : NORMAL;
    v2 uv     : TEXCOORD0;
    v3 light_vec[4];
    v3 view_vec;
    
    v3 debug_color;
}

// @volatile, the renderer needs to divide the total meshlet count by this to get the number of shaders to dispatch
static const uint TaskWidth = 1;
static const uint MeshWidth = 32;

// groupshared Task_Result result;
// groupshared Atomic<uint> meshlet_count;

// [shader("task")]
// [numthreads(TaskWidth, 1, 1)]
// void main(uint3 group_id : SV_GroupID /* 0..meshlet_count / TaskWidth */, uint3 thread_id: SV_GroupThreadID /* 0..TaskWidth */, uniform Data *data, ) {
//     DispatchMesh(1, 1, 1, result);
//     // uint meshlet_group_index = group_id.x;
//     // uint thread_index = thread_id.x;
    
//     // uint meshlet_group_offset = meshlet_group_index * 32;
//     // if (thread_index == 0) {
//     //     result.meshlet_group = meshlet_group_offset;
//     //     meshlet_count.store(0);
//     // }
    
//     // GroupMemoryBarrierWithWaveSync();
    
//     // /* 
//     // @study how can this be done in slang
//     // bool accept = !coneCull(meshlets[mi].cone, vec3(0, 0, 1));
//     // uvec4 ballot = subgroupBallot(accept);
//     // uint index = subgroupBallotInclusiveBitCount(ballot);

//     // if (accept)
//     //     meshletIndices[index] = mi;

//     // uint count = subgroupBallotBitCount(ballot);

//     // if (ti == 0)
//     //     gl_TaskCountNV = count;
//     // */
    
//     // uint meshlet_index  = meshlet_group_offset + thread_index;
//     // v4 cone  = meshlet_buffer[meshlet_index].cone;
    
//     // // cone.xyz = normalize(mul((m3) shader_data->model, cone.xyz));
//     // // if (!cone_cull(cone.xyz, cone.w, v3(0, 0, 1))) {
//     // //     uint index = meshlet_count.add(1);
//     // //     result.indices[index] = (u8) thread_index;
//     // // }
    
//     // uint index = meshlet_count.add(1);
//     // result.indices[index] = (u8) thread_index;
    
    
//     // GroupMemoryBarrierWithWaveSync();
    
//     // if (thread_index == 0) {
//     //     uint count = meshlet_count.load();
//     //     DispatchMesh(count, 1, 1, result);
//     // }
// }

[shader("mesh")]
[outputtopology("triangle")]
[numthreads(MeshWidth, 1, 1)]
[outputtopology("triangle")]
void main(in payload Task_Result input, uniform Data *shader_data,
    out OutputVertices<Mesh_Result, VertexLimit> out_vertices, out OutputIndices<uint3, TriangleLimit> out_indices, 
    uint3 group_id : SV_GroupID/* 0..TaskWidth */, uint3 thread_id : SV_GroupThreadID/* 0..MeshWidth */) {
    uint group_index = group_id.x;
    uint thread_index = thread_id.x;
    // uint meshlet_index = input.meshlet_group + input.indices[group_index];
    uint meshlet_index = group_index;
    
    
    Meshlet meshlet = meshlet_buffer[meshlet_index];
    
    //@cleanup make this a single model transform
    m4 model_view = mul(shader_data->view, shader_data->model);
    
    // @todo(viktor): apparently i need more data for a perspective correct culling
    // v4 cone  = meshlet.cone;
    // cone.xyz = normalize(mul((m3) transpose(model_view.invertse)), cone.xyz));
    // if (cone_cull(cone.xyz, cone.w, v3(0, 0, 1))) {
    //     SetMeshOutputCounts(0, 0);
    //     return;
    // }
    
    SetMeshOutputCounts(meshlet.vertex_count, meshlet.triangle_count);
    
    for (int i = thread_index; i < meshlet.vertex_count; i += MeshWidth) {
        uint vertex_index = meshlet.vertices[i];
        
        Vertex input = vertex_buffer[vertex_index];
        
        v3 p = v3(input.px, input.py, input.pz);
        // 0..255 -> 0..2 -> -1..1
        v3 n = v3(input.nx, input.ny, input.nz) / 127.0 - 1.0;
        v2 t = v2(input.tu, input.tv);
        
        Mesh_Result result;
        v4 view_p = mul(model_view, v4(p, 1));
        
        result.normal = mul((m3) model_view, n);
        result.uv = t;
        result.pos = mul(shader_data->projection, view_p);
        
        // Calculate view vectors required for lighting
        for (int li = 0; li < 4; li++) {
            result.light_vec[li] = shader_data->light_pos[li].xyz - view_p.xyz;
        }
        result.view_vec = -view_p.xyz;
        
        out_vertices[i] = result;
        
        if (Debug) {
            uint mhash = hash(meshlet_index);
            result.debug_color = v3(f32(mhash & 255), f32((mhash >> 8) & 255), f32((mhash >> 16) & 255)) / 255;
        }
    }
    
    // @speed as the indices are really [3] u8, we could write them packed into a u32 and get 4x throughput
    for (int i = thread_index; i < meshlet.triangle_count; i += MeshWidth) {
        out_indices[i].x = meshlet.indices[i][0];
        out_indices[i].y = meshlet.indices[i][1];
        out_indices[i].z = meshlet.indices[i][2];
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

bool cone_cull(v3 cone, f32 w, v3 view) {
    return dot(cone, view) > w;
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
