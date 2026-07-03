#version 460

#extension GL_EXT_nonuniform_qualifier: require

#include "common.glslh"

////////////////////////////////////////////////

layout(location = 0) flat   in Mesh_Result_Flat   mesh_result_flat;
layout(location = 1) smooth in Mesh_Result_Smooth mesh_result_smooth;

layout(binding = 0) uniform sampler texture_sampler;
layout(binding = 1) uniform texture2D texture_1;
layout(binding = 2) uniform texture2D texture_2;
layout(binding = 3) uniform texture2D texture_3;

layout(location = 0) out vec4 pixel_result;

void main() {
    vec3 diffuse  = vec3(0.0);
    vec3 specular = vec3(0.0);
    
    // Phong lighting
    vec3 n = normalize(mesh_result_smooth.normal);
    vec3 v = normalize(mesh_result_smooth.view_vec);
    for (int li = 0; li < 4; li++) {
        vec3 l = normalize(mesh_result_smooth.light_vec[li]);
        vec3 r = reflect(-l, n);
        diffuse  += max(dot(n, l), 0.0025);
        specular += pow(max(dot(r, v), 0.0), 16.0) * 0.75;
    }
    
    uint texture_index = mesh_result_flat.texture_index;
    vec2 uv = mesh_result_smooth.uv;
    
    // vec3 albedo = texture(sampler2D(texture_heap[nonuniformEXT(texture_index)], texture_sampler), uv).rgb;
    vec3 albedo;
    if (texture_index == 0) {
        albedo = texture(sampler2D(texture_1, texture_sampler), uv).rgb;
    } else if (texture_index == 1) {
        albedo = texture(sampler2D(texture_2, texture_sampler), uv).rgb;
    } else if (texture_index == 2) {
        albedo = texture(sampler2D(texture_3, texture_sampler), uv).rgb;
    }
    
    vec3 color = diffuse * albedo + specular;
    
    if (Debug) {
        color *= mesh_result_smooth.debug_color;
    }
    
    pixel_result = vec4(color, 1);
}