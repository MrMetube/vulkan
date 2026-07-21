#version 460

#include "common.glsl"

// layout(constant_id = 0) const bool Late = false; unused
layout(constant_id = 1) const bool Post = false;

layout(push_constant) uniform _ { Draw_Data data; };

layout(location = 0) flat   in uint        draw_index;
layout(location = 1) smooth in Mesh_Result mesh_result;
#if Debug
layout(location = 6) flat   in uint debug_index;
#endif // Debug

layout(descriptor_heap) uniform texture2D Textures[];
layout(descriptor_heap) uniform sampler   Samplers[];

layout(location = 0) out vec4 pixel_result;

void main() {
    vec4 albedo   = vec4(.5, .5, .5, 1);
    vec3 nnormal  = vec3(0, 0, 1); // @naming
    vec3 emmisive = vec3(0);
    {
        Draw draw = data.draw_buffer[draw_index].v;
        vec2 uv = mesh_result.uv;
        
        // @volatile heap StaticLimit. just move those to the end of the heap and forget about them.
        // @speed if the texture index is uniform over the lanes, then nonuniformEXT() is a pessimisation.
        if (draw.albedo_texture > 0) {
            albedo = texture(sampler2D(Textures[nonuniformEXT(65536 + 1 + draw.albedo_texture)], Samplers[Sampler_Texture]), uv);
        }
        if (draw.normal_texture > 0) {
            nnormal = texture(sampler2D(Textures[nonuniformEXT(65536 + 1 + draw.normal_texture)], Samplers[Sampler_Texture]), uv).rgb;
            nnormal = nnormal * 2 - 1;
        }
        if (draw.emmisive_texture > 0) {
            emmisive = texture(sampler2D(Textures[nonuniformEXT(65536 + 1 + draw.emmisive_texture)], Samplers[Sampler_Texture]), uv).rgb;
        }
    }
    
    vec3 binormal = cross(mesh_result.normal, mesh_result.tangent.xyz) * mesh_result.tangent.w;
    
    vec3 normal = normalize(nnormal.x * mesh_result.tangent.xyz + nnormal.y * binormal + nnormal.z * mesh_result.normal);
    
    // @todo lighting
    float ndotl = max(dot(normal, normalize(vec3(-1, 1, -1))), 0);
    vec4 color = vec4(albedo.rgb * sqrt(ndotl + 0.005) + emmisive, albedo.a);
    
    if (Post && albedo.a < 0.5) discard;
    
    #if Debug
        uint index = 0;
        index = debug_index;
        index = draw_index;
        uint mhash = hash(index);
        color.rgb = vec3(float(mhash & 255), float((mhash >> 8) & 255), float((mhash >> 16) & 255)) / 255.0;
    #endif // Debug
    
    
    pixel_result = color;
    // pixel_result.xyz = (normal + 1) / 2;
}