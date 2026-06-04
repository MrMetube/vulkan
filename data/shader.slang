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

////////////////////////////////////////////////

static const uint VertexLimit   = 64;
static const uint TriangleLimit = 84;

// @volatile cpu needs to match this layout
struct Data {
    m4 projection;
    m4 view;
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
    u32 data_offset;
    u8  vertex_count;
    u8  triangle_count;
}

// @volatile cpu needs to match this layout
struct Mesh_Draw {
    m4  model;
}

[[vk::binding(0)]] StructuredBuffer<Vertex>    vertex_buffer;
[[vk::binding(1)]] StructuredBuffer<Meshlet>   meshlet_buffer;
[[vk::binding(2)]] StructuredBuffer<u32>       meshlet_data_buffer;
[[vk::binding(3)]] StructuredBuffer<Mesh_Draw> draw_buffer;

[[vk::binding(0, 1)]] Sampler2D textures[];

// @volatile, the renderer needs to divide the total meshlet count by this to get the number of shaders to dispatch
static const uint TaskWidth = 32;
static const uint MeshWidth = 32;

groupshared Task_Result result;
groupshared Atomic<uint> meshlet_count;

struct Task_Result {
    u32 offset;
    uint indices[TaskWidth];
}

#define Taskshader 0

#if Taskshader
[shader("task")]
[numthreads(TaskWidth, 1, 1)]
void main(uniform Data *data, uint group_id : SV_GroupID, uint thread_id : SV_GroupThreadID) {
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
    
    // cone.xyz = normalize(mul((m3) data->model, cone.xyz));
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

// @volatile this order must match the layout of Push_Data on the cpu side
struct Push_Data {
    Data *data;
    uint mesh_index;
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
    
    Data data = *push.data;
    Mesh_Draw draw = draw_buffer[push.mesh_index];
    
    if (meshlet_index < data.meshlet_count) {
        meshlet = meshlet_buffer[meshlet_index];
    }
    
    m4 model_view = mul(data.view, draw.model);
    
    // @todo(viktor): apparently i need more data for a perspective correct culling
    // v4 cone  = meshlet.cone;
    // cone.xyz = normalize(mul((m3) transpose(model_view.invertse)), cone.xyz));
    // if (cone_cull(cone.xyz, cone.w, v3(0, 0, 1))) {
    //     SetMeshOutputCounts(0, 0);
    //     return;
    // }
    
    SetMeshOutputCounts(meshlet.vertex_count, meshlet.triangle_count);
    
    
    uint vertex_offset = meshlet.data_offset;
    uint index_offset  = vertex_offset + meshlet.vertex_count;
    for (int i = thread_index; i < meshlet.vertex_count; i += MeshWidth) {
        uint vertex_index = meshlet_data_buffer[vertex_offset + i];
        
        Vertex vertex = vertex_buffer[vertex_index];
        
        v3 p = v3(vertex.px, vertex.py, vertex.pz);
        // 0..255 -> 0..2 -> -1..1
        v3 n = v3(vertex.nx, vertex.ny, vertex.nz) / 127.0 - 1.0;
        v2 t = v2(vertex.tu, vertex.tv);
        
        Mesh_Result result;
        v4 view_p = mul(model_view, v4(p, 1));
        
        result.normal = mul((m3) model_view, n);
        result.uv = t;
        result.pos = mul(data.projection, view_p);
        
        // Calculate view vectors required for lighting
        for (int li = 0; li < 4; li++) {
            result.light_vec[li] = data.light_pos[li].xyz - view_p.xyz;
        }
        result.view_vec = -view_p.xyz;
        
        out_vertices[i] = result;
        
        if (Debug) {
            uint mhash = hash(meshlet_index);
            result.debug_color = v3(f32(mhash & 255), f32((mhash >> 8) & 255), f32((mhash >> 16) & 255)) / 255;
        }
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
