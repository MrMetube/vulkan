#extension GL_EXT_buffer_reference:     require
#extension GL_EXT_buffer_reference2:    require
#extension GL_EXT_shader_8bit_storage:  require
#extension GL_EXT_scalar_block_layout:  require
#extension GL_EXT_nonuniform_qualifier: require
#extension GL_EXT_descriptor_heap:      require

#include "api.generated.glsl"

#define Debug 0

#define TaskWidth      64
#define TaskWidthLimit (1 << 22)

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
    vec3 light_vec;
    vec3 normal;
    vec3 view_vec;
    vec2 uv;
#if Debug
    vec3 debug_color; // @cleanup
#endif // Debug
};

////////////////////////////////////////////////

#define square(x) (x) * (x)
#define square_root(x) sqrt(x)

vec3 rotate(vec4 q, vec3 v) {
    return v + 2.0 * cross(q.xyz, cross(q.xyz, v) + q.w * v);
}

vec3 transform(vec4 orientation, float scale, vec3 offset, vec3 p) {
    return rotate(orientation, p) * scale + offset;
}

// Based on this paper: 
//     2D Polyhedral Bounds of a Clipped, Perspective-Projected 3D Sphere. Michael Mara, Morgan McGuire. 2013
//     https://jcgt.org/published/0002/02/05/paper.pdf
//     :ViewSpace: is used to simplify the original calculations down to this form
bool project_sphere_onto_screen(vec3 view_center, float radius, float s00, float s11, float near_z, out vec4 result) {
    if (view_center.z + radius > -near_z) { // :ViewSpace:
        return false;
    }
    
    // center in the x/y-z frame
    vec2 cx = -view_center.xz;
    vec2 cy = -view_center.yz;
    
    float zz_rr = view_center.z * view_center.z - radius * radius;
    
    // (cos, sin) of angle theta between c and x/y tangent vector
    float vx = square_root(square(view_center.x) + zz_rr);
    float vy = square_root(square(view_center.y) + zz_rr);
    
    vec3  rc = radius * view_center;
    
    float vxx = vx * -view_center.x;
    float vyy = vy * -view_center.y;
    float vxz = vx * -view_center.z;
    float vyz = vy * -view_center.z;
    
    // In the x/y-z reference frame
    // Transform back to camera space
    float min_x = s00 * (vxx - rc.z) / (vxz + rc.x);
    float max_x = s00 * (vxx + rc.z) / (vxz - rc.x);
    float min_y = s11 * (vyy - rc.z) / (vyz + rc.y);
    float max_y = s11 * (vyy + rc.z) / (vyz - rc.y);
    
    result = vec4(min_x, min_y, max_x, max_y);
    
    // transform to clip space
    result = result.xwzy * -0.5 + 0.5;
    
    return true;
}
