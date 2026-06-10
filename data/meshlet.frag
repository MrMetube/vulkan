#version 460

// #extension GL_EXT_nonuniform_qualifier : require
// #extension GL_EXT_samplerless_texture_functions : enable

#include "common.h"

////////////////////////////////////////////////

layout(location = 0) in Mesh_Result mesh_result;

layout(set = 1, binding = 0) uniform sampler2D textures[];

layout(location = 0) out vec4 pixel_result;

void main(void) {
    vec3 diffuse  = vec3(0.0);
    vec3 specular = vec3(0.0);
    
    // Phong lighting
    vec3 n = normalize(mesh_result.normal);
    vec3 v = normalize(mesh_result.view_vec);
    for (int li = 0; li < 4; li++) {
        vec3 l = normalize(mesh_result.light_vec[li]);
        vec3 r = reflect(-l, n);
        diffuse  += max(dot(n, l), 0.0025);
        specular += pow(max(dot(r, v), 0.0), 16.0) * 0.75;
    }
    
    vec3 albedo = texture(textures[0], mesh_result.uv).rgb;
    vec3 color = diffuse * albedo + specular;
    
    if (Debug) {
        color = mesh_result.debug_color;
    }
    
    pixel_result = vec4(color, 1.0);
}