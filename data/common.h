#define Debug false

#extension GL_EXT_shader_8bit_storage: require
#extension GL_EXT_buffer_reference : require

#define TaskWidth 32

struct Task_Result {
    uint draw_index;
    uint indices[TaskWidth];
};


struct Mesh_Result {
    vec3 normal;
    vec2 uv;
    vec3 light_vec[4];
    vec3 view_vec;

    vec3 debug_color; // @cleanup
};

////////////////////////////////////////////////

// @volatile
layout(buffer_reference, buffer_reference_align = 8) buffer Draw_Globals {
    mat4 view;
    mat4 projection;
    vec4 light_pos[4];
    uint meshlet_count;
};

// @volatile
struct Draw {
    uint command_data[3], pad;
    
    vec4  orientation;
    vec3  p;
    float scale;
};

// @volatile
struct Meshlet {
    vec3  center;
    float radius;
    int8_t cone_axis[3];
    uint8_t cone_cutoff;
    
    uint data_offset;
    uint8_t vertex_count;
    uint8_t triangle_count;
};

////////////////////////////////////////////////

vec3 rotate (vec4 q, vec3 v) {
    return v + 2.0 * cross(q.xyz, cross(q.xyz, v) + q.w * v);
}
