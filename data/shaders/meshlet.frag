#version 460

#include "common.glsl"

layout(push_constant) uniform _ { Draw_Data data; };

layout(location = 0) flat   in uint        draw_index;
layout(location = 1) smooth in Mesh_Result mesh_result;

layout(descriptor_heap) uniform texture2D Textures[];
layout(descriptor_heap) uniform sampler   Samplers[];

layout(location = 0) out vec4 pixel_result;

void main() {
    vec3 diffuse  = vec3(0.0);
    vec3 specular = vec3(0.0);
    
    // Phong lighting
    vec3 n = normalize(mesh_result.normal);
    vec3 v = normalize(mesh_result.view_vec);
    {
        vec3 l = normalize(mesh_result.light_vec);
        vec3 r = reflect(-l, n);
        diffuse  += 3 * max(dot(n, l), 0.0025);
        specular += 3 * pow(max(dot(r, v), 0.0), 16.0) * 0.75;
    }
    
    uint texture_index = data.draw_buffer[draw_index].v.texture_index;
    vec2 uv = mesh_result.uv;
    
    vec3 albedo = texture(sampler2D(Textures[texture_index], Samplers[Sampler_Texture]), uv).rgb;
    
    vec3 color = diffuse * albedo + specular;
    
    #if Debug
        color *= mesh_result.debug_color;
    #endif // Debug
    
    pixel_result = vec4(color, 1);
    // pixel_result = vec4(n+1*0.5, 1);
}