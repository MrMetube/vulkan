#extension GL_EXT_buffer_reference:    require
#extension GL_EXT_buffer_reference2:   require
#extension GL_EXT_shader_8bit_storage: require
#extension GL_EXT_buffer_reference:    require
#extension GL_EXT_scalar_block_layout: require

#include "api.generated.glsl"

#define Debug false

#define TaskWidth 32

// @volatile
#define Flag_FrustumCulling   (1 << 0)
#define Flag_LevelOfDetail    (1 << 1)
#define Flag_OcclusionCulling (1 << 2)

// @volatile :SamplerHack:
#define Sampler_Texture 0
#define Sampler_Filter  1
#define Sampler_Depth   2

struct Task_Result {
    uint indices[TaskWidth];
    uint draw_index;
    uint meshlet_offset;
};

struct Mesh_Result {
    vec3 light_vec[4];
    vec3 normal;
    vec3 view_vec;
    vec2 uv;
#if Debug
    vec3 debug_color; // @cleanup
#endif // Debug
};

////////////////////////////////////////////////

vec3 rotate(vec4 q, vec3 v) {
    return v + 2.0 * cross(q.xyz, cross(q.xyz, v) + q.w * v);
}

vec3 transform(vec4 orientation, float scale, vec3 offset, vec3 p) {
    return rotate(orientation, p) * scale + offset;
}