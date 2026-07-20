#version 460

#include "common.glsl"

layout(push_constant) uniform _ { Draw_Data data; };

layout(location = 0) flat   in uint        draw_index;
layout(location = 1) smooth in Mesh_Result mesh_result;

layout(descriptor_heap) uniform texture2D Textures[];
layout(descriptor_heap) uniform sampler   Samplers[];

layout(location = 0) out vec4 pixel_result;

void main() {
    vec4 albedo = vec4(.5, .5, .5, 1);
    vec4 nnormal = vec4(0, 0, 1, 0); // @naming
    {
        Draw draw = data.draw_buffer[draw_index].v;
        vec2 uv = mesh_result.uv;
        
        // @volatile heap StaticLimit. just move those to the end of the heap and forget about them.
        // @speed if the texture index is uniform over the lanes, then nonuniformEXT() is a pessimisation.
        if (draw.albedo_texture > 0) {
            albedo = texture(sampler2D(Textures[nonuniformEXT(65536 + 1 + draw.albedo_texture)], Samplers[Sampler_Texture]), uv);
        }
        if (draw.normal_texture > 0) {
            nnormal = texture(sampler2D(Textures[nonuniformEXT(65536 + 1 + draw.normal_texture)], Samplers[Sampler_Texture]), uv);
            nnormal = nnormal * 2 - 1;
        }
    }
    
    vec3 binormal = cross(mesh_result.normal, mesh_result.tangent.xyz) * mesh_result.tangent.w;
    
    vec3 normal = normalize(nnormal.x * mesh_result.tangent.xyz + nnormal.y * binormal + nnormal.z * mesh_result.normal);
    
    // @todo lighting
    float ndotl = max(dot(normal, normalize(vec3(1, 1, 1))), 0);
    vec4 color = albedo * sqrt(ndotl + 0.005);
    
    #if Debug
        color = mesh_result.debug_color;
    #endif // Debug
    
    pixel_result = color;
    // pixel_result.xyz = (normal + 1) / 2;
}