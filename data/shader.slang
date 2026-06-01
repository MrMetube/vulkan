typealias u8  = uint8_t;
typealias f32 = float;
typealias v2 = float2;
typealias v3 = float3;
typealias v4 = float4;
typealias m3 = float3x3;
typealias m4 = float4x4;



// @todo(viktor): packed/remove padding
struct Vertex {
    f32 px, py, pz;
    u8 nx, ny, nz, n_pad;
	f32 tu, tv;
}

[[vk::binding(0, 0)]]
StructuredBuffer<Vertex> vertices;

[[vk::binding(0, 1)]]
Sampler2D textures[];

struct ShaderData {
    m4 projection;
    m4 view;
    m4 model[3];
    v4 light_pos;
    uint32_t selected;
}

struct VSOutput {
    v4 pos : SV_POSITION;
    float3 normal;
    float2 uv;
    float3 factor;
    float3 light_vec;
    float3 view_vec;
    uint32_t instance_index;
}

[shader("vertex")]
VSOutput main(uniform ShaderData *shader_data, uint instance_index : SV_VulkanInstanceID, uint vertex_index : SV_VertexID) {
    Vertex input = vertices[vertex_index];
    
    float3 p = float3(input.px, input.py, input.pz);
    // 0..255 -> 0..2 -> -1..1
    float3 n = float3(input.nx, input.ny, input.nz) / 127.0 - 1.0;
    float2 t = float2(input.tu, input.tv);
    
    VSOutput output;
    m4 modelMat = shader_data->model[instance_index%3];
    f32 offset = floor(f32(instance_index)/3);
    p.z -= offset;
    v4 p_in_view = mul(mul(shader_data->view, modelMat), v4(p, 1));
    
    output.normal = mul((m3) mul(shader_data->view, modelMat), n);
    output.uv = t;
    output.pos = mul(shader_data->projection, p_in_view);
    output.factor = (shader_data->selected == instance_index ? 30.0f : 1.0f);
    output.instance_index = instance_index%3;
    
    // Calculate view vectors required for lighting
    v4 fragPos = p_in_view;
    output.light_vec = shader_data->light_pos.xyz - fragPos.xyz;
    output.view_vec = -fragPos.xyz;
    return output;
}

[shader("fragment")]
v4 main(VSOutput input) {
    // Phong lighting
    float3 n = normalize(input.normal);
    float3 l = normalize(input.light_vec);
    float3 v = normalize(input.view_vec);
    float3 r = reflect(-l, n);
    float3 diffuse = max(dot(n, l), 0.0025);
    float3 specular = pow(max(dot(r, v), 0.0), 16.0) * 0.75;
    
    // Sample from texture
    Sampler2D texture = textures[NonUniformResourceIndex(input.instance_index)];
    float3 albedo = texture.Sample(input.uv).rgb * input.factor;
    float3 color = diffuse * albedo + specular;
    
    return v4(color, 1);
}