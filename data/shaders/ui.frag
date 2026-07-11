#version 460

#include "common.glsl"
#include "colors.glsl"

layout(location = 0) flat in uint draw_index;

layout(location = 0) out vec4 out_color;

#define square(x) (x) * (x)
#define square_root(x) sqrt(x)

////////////////////////////////////////////////

// Signed distance to a 2D rounded box.
//     https://www.shadertoy.com/view/4llXD7
//
// List of some other 2D distances:
//     iquilezles.org/articles/distfunctions2d

// roundness = (top-right, bottom-right, top-left, bottom-left)
float sdRoundBox( in vec2 p, in vec2 radius, in vec4 roundness) {
    vec2 b = radius;
    vec4 r = roundness;
    r.xy = (p.x>0.0) ? r.xy : r.zw;
    r.x  = (p.y>0.0) ? r.x  : r.y;
    vec2 q = abs(p)-b+r.x;
    return min(max(q.x,q.y),0.0) + length(max(q,0.0)) - r.x;
}

////////////////////////////////////////////////

layout(push_constant) uniform Push_Data {
    UI_Data data;
};

void main() {
    // mouse highlight
    vec2 pixel = vec2(gl_FragCoord.x, data.screen_size.y - gl_FragCoord.y);
    vec2 mouse = data.mouse_p;
    vec2 delta = pixel - mouse;
    float dist = length(delta);
    
    float radius = 10.0; 
    float falloff = 100.0;
    float max_factor = 0.25;
    
    float t = max(0.0, dist - radius);
    float decay = exp(-t / falloff);
    
    float factor = max_factor * decay;
    
    UI_Draw draw = data.draw_buffer[draw_index].v;
    
    vec4 color_ok     = oklch_from_linear(draw.color);
    vec4 highlight_ok = oklch_from_linear(vec4(1));
    vec4 border_ok    = oklch_from_linear(draw.border_color);
    
    factor = draw.highlight ? factor : 0;
    vec4 inner_ok = mix(color_ok, highlight_ok, factor);
    
    // border and corners
    float border_thickness = draw.border_thickness;
    
    vec4  outer_rect = draw.rect;
    float outer_corner_radius = draw.corner_radius;
    
    float inner_corner_radius = max(0, outer_corner_radius - border_thickness);
    vec4  inner_rect = outer_rect + vec4(1,1, -1,-1) * border_thickness;
    
    vec2 outer_radius = (outer_rect.zw - outer_rect.xy) * 0.5;
    vec2 outer_center = outer_rect.xy + outer_radius;
    
    vec2 inner_radius = (inner_rect.zw - inner_rect.xy) * 0.5;
    vec2 inner_center = inner_rect.xy + inner_radius;
    
    float d_outer = sdRoundBox(pixel - outer_center, outer_radius, vec4(outer_corner_radius));
    float d_inner = sdRoundBox(pixel - inner_center, inner_radius, vec4(inner_corner_radius));
    
    float aa = fwidth(d_outer);
    
    float outer = 1.0 - smoothstep(-aa, aa, d_outer);
    float inner = 1.0 - smoothstep(-aa, aa, d_inner);
    
    vec4 color = linear_from_oklch(mix(border_ok, inner_ok, inner));
    color.a *= outer;
    
    out_color = color;
}