typealias u8  = uint8_t;
typealias u32  = uint32_t;

typealias f32 = float;
typealias v2 = float2;
typealias v3 = float3;
typealias v4 = float4;
typealias m3 = float3x3;
typealias m4 = float4x4;



// @volatile cpi needs to match this layout
struct Vertex {
    f32 px, py, pz;
    u8 nx, ny, nz, n_pad;
	f32 tu, tv;
}


// @volatile cpi needs to match this layout
struct Meshlet {
    u32 vertices[64];
    u8  indices[128-1-1];
    u8  index_count;
    u8  vertex_count;
}

[[vk::binding(0, 0)]]
StructuredBuffer<Vertex> vertices;
[[vk::binding(1, 0)]]
StructuredBuffer<Meshlet> meshlets;

[[vk::binding(0, 1)]]
Sampler2D textures[];

struct Shader_Data {
    m4 projection;
    m4 view;
    m4 model;
    v4 light_pos[4];
}

struct Mesh_Result {
    v4 pos : SV_POSITION;
    float3 normal : NORMAL;
    float2 uv : TEXCOORD0;
    float3 light_vec[4];
    float3 view_vec;
}

static const uint thread_count = 32;

[shader("mesh")]
[outputtopology("triangle")]
[numthreads(thread_count, 1, 1)]
[outputtopology("triangle")]
void main(out OutputVertices<Mesh_Result, 64> out_vertices, out OutputIndices<uint3, 126 / 3> out_indices, uint3 group_id : SV_GroupID, uint3 thread_id : SV_GroupThreadID, uniform Shader_Data *shader_data) {
    uint mi = group_id.x;
    Meshlet meshet = meshlets[mi];
    
    uint primitive_count = meshet.index_count / 3;
    
    SetMeshOutputCounts(meshet.vertex_count, primitive_count);
    
    for (int i = thread_id.x; i < meshet.vertex_count; i += thread_count) {
        uint vi = meshet.vertices[i];
        
        Vertex input = vertices[vi];
        
        float3 p = float3(input.px, input.py, input.pz);
        // 0..255 -> 0..2 -> -1..1
        float3 n = float3(input.nx, input.ny, input.nz) / 127.0 - 1.0;
        float2 t = float2(input.tu, input.tv);
        
        Mesh_Result result;
        //@cleanup single model transform
        m4 modelMat = shader_data->model;
        v4 p_in_view = mul(mul(shader_data->view, modelMat), v4(p, 1));
        
        result.normal = mul((m3) mul(shader_data->view, modelMat), n);
        result.uv = t;
        result.pos = mul(shader_data->projection, p_in_view);
        
        // Calculate view vectors required for lighting
        v4 fragPos = p_in_view;
        for (int li = 0; li < 4; li++) {
            result.light_vec[li] = shader_data->light_pos[li].xyz - fragPos.xyz;
        }
        result.view_vec = -fragPos.xyz;
        
        out_vertices[i] = result;
    }
    
    GroupMemoryBarrierWithGroupSync();
    
    for (int i = thread_id.x; i < primitive_count; i += thread_count) {
        uint base = i * 3;
        // @speed as the indices are really [3] u8, we could write them packed into a u32 and get 4x throughput
        // see: glsl writePackedPrimitiveIndices4x8NV
        out_indices[i] = uint3(
            meshet.indices[base+0],
            meshet.indices[base+1],
            meshet.indices[base+2]
        );
    }
}

[shader("fragment")]
v4 main(Mesh_Result input) {
    v3 diffuse  = v3(0);
    v3 specular = v3(0);
    
    // Phong lighting
    float3 n = normalize(input.normal);
    float3 v = normalize(input.view_vec);
    for (int li = 0; li < 4; li++) {
        float3 l = normalize(input.light_vec[li]);
        float3 r = reflect(-l, n);
        diffuse  += max(dot(n, l), 0.0025);
        specular += pow(max(dot(r, v), 0.0), 16.0) * 0.75;
    }
    
    Sampler2D texture = textures[NonUniformResourceIndex(0)];
    float3 albedo = texture.Sample(input.uv).rgb;
    float3 color = diffuse * albedo + specular;
    
    return v4(color, 1);
}