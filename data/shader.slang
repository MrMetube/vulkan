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
    f32 px, py, pz, p_pad;
    u8 nx, ny, nz, n_pad;
	f32 tu, tv;
}

static const uint MaxVertexCount = 64;
static const uint MaxIndexCount  = 84;
static const uint ThreadCount    = 32;


// @volatile cpi needs to match this layout
struct Meshlet {
    u32 vertices[MaxVertexCount];
    u8  indices[MaxIndexCount*3];
    u8  triangle_count;
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
    v3 normal : NORMAL;
    v2 uv : TEXCOORD0;
    v3 light_vec[4];
    v3 view_vec;
}

[shader("mesh")]
[outputtopology("triangle")]
[numthreads(ThreadCount, 1, 1)]
[outputtopology("triangle")]
void main (out OutputVertices<Mesh_Result, MaxVertexCount> out_vertices, out OutputIndices<uint3, MaxIndexCount> out_indices, uint3 group_id : SV_GroupID, uint3 thread_id : SV_GroupThreadID, uniform Shader_Data *shader_data) {
    uint mi = group_id.x;
    Meshlet meshet = meshlets[mi];
    
    for (int i = thread_id.x; i < meshet.vertex_count; i += ThreadCount) {
        uint vi = meshet.vertices[i];
        
        Vertex input = vertices[vi];
        
        v3 p = v3(input.px, input.py, input.pz);
        // 0..255 -> 0..2 -> -1..1
        v3 n = v3(input.nx, input.ny, input.nz) / 127.0 - 1.0;
        v2 t = v2(input.tu, input.tv);
        
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
    
    // @speed as the indices are really [3] u8, we could write them packed into a u32 and get 4x throughput
    for (int i = thread_id.x; i < meshet.triangle_count; i += ThreadCount) {
        out_indices[i].x = meshet.indices[i*3+0];
        out_indices[i].y = meshet.indices[i*3+1];
        out_indices[i].z = meshet.indices[i*3+2];
    }
    
    if (thread_id.x == 0) {
        SetMeshOutputCounts(meshet.vertex_count, meshet.triangle_count);
    }
}

[shader("fragment")]
v4 main (Mesh_Result input) {
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
    
    return v4(color, 1);
}