#version 460

#define Raytrace 1

#if Raytrace
#extension GL_EXT_ray_query: require
#endif // Raytrace

#include "common.glsl"

// layout(constant_id = 0) const bool Late = false; unused
layout(constant_id = 1) const bool Post = false;

layout(push_constant) uniform _ {
    Draw_Data _task;
    Draw_Data _mesh;
    Draw_Data  data;
};

layout(location = 0) flat   in uint        draw_index;
layout(location = 1) smooth in Mesh_Result mesh_result;
#if Debug
layout(location = 6) flat   in uint debug_index;
#endif // Debug

layout(descriptor_heap) uniform texture2D Textures[];
layout(descriptor_heap) uniform sampler   Samplers[];
#if Raytrace
// :AccelerationStructureFromHeap:
layout(set = 0, binding = 0) uniform accelerationStructureEXT top_level;
// layout(descriptor_heap, descriptor_stride = 32) uniform accelerationStructureEXT top_levels[];
#endif // Raytrace


layout(location = 0) out vec4 pixel_result;

void main() {
    vec4 albedo     = vec4(.5, .5, .5, 1);
    vec3 normal_tbn = vec3(0, 0, 1);
    vec3 emmisive   = vec3(0, 0, 0);
    {
        Draw draw = data.draw_buffer[draw_index].v;
        vec2 uv = mesh_result.uv;
        
        // @speed if the texture index is uniform over the lanes, then nonuniformEXT() is a pessimisation.
        if (draw.albedo_texture > 0) {
            albedo = texture(sampler2D(Textures[nonuniformEXT(draw.albedo_texture)], Samplers[Sampler_Texture]), uv);
        }
        if (draw.normal_texture > 0) {
            normal_tbn = texture(sampler2D(Textures[nonuniformEXT(draw.normal_texture)], Samplers[Sampler_Texture]), uv).rgb;
            normal_tbn = normal_tbn * 2 - 1;
        }
        if (draw.emmisive_texture > 0) {
            emmisive = texture(sampler2D(Textures[nonuniformEXT(draw.emmisive_texture)], Samplers[Sampler_Texture]), uv).rgb;
        }
    }
    
    vec3 binormal = cross(mesh_result.normal, mesh_result.tangent.xyz) * mesh_result.tangent.w;
    
    vec3 normal = normalize(normal_tbn.x * mesh_result.tangent.xyz + normal_tbn.y * binormal + normal_tbn.z * mesh_result.normal);
    
    vec3 sun_direction = normalize(data.sun_direction);
    float ndotl = max(dot(normal, sun_direction), 0);
    
#if Raytrace
    
    rayQueryEXT ray_query;
    // :AccelerationStructureFromHeap:
    rayQueryInitializeEXT(ray_query, top_level, gl_RayFlagsTerminateOnFirstHitEXT, 0xFF, mesh_result.p, 0.01, vec3(0,1,0), 1000);
    // uint top_level_index = data.top_level_acceleration_structure_index;
    // rayQueryInitializeEXT(ray_query, top_levels[top_level_index], gl_RayFlagsTerminateOnFirstHitEXT, 0xFF, mesh_result.p, 0.01, sun_direction, 100);
    rayQueryProceedEXT(ray_query);
    
    if (rayQueryGetIntersectionTypeEXT(ray_query, true) != gl_RayQueryCommittedIntersectionNoneEXT) {
        albedo.rgb = vec3(1,0,0);
        ndotl *= 100;
    } else {
        albedo.rgb = vec3(0,0,1);
    }
#endif // Raytrace
    
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