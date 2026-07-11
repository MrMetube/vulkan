#version 460

#include "common.glsl"

layout(push_constant) uniform Push_Data {
    UI_Data data;
};

layout(location = 0) flat out uint draw_index;

void main() {
    draw_index = gl_InstanceIndex;
    UI_Draw draw = data.draw_buffer[draw_index].v;
    
    const uvec2 indices[6] = uvec2[] (
        uvec2(0, 1), uvec2(2, 1), uvec2(0, 3),
        uvec2(2, 3), uvec2(0, 3), uvec2(2, 1)
    );
    
    uvec2 index = indices[gl_VertexIndex % 6];
    vec2 p = vec2(draw.rect[index.x], draw.rect[index.y]);
    
    vec2 ndc = p / data.screen_size;
    ndc = ndc * 2.0 - 1.0;
    ndc.y = -ndc.y;
    
    gl_Position = vec4(ndc, 0.0, 1.0);
}