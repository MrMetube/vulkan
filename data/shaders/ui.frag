#version 460

#include "common.glsl"

layout(location = 0) smooth in UI_Result      s_in;
layout(location = 1) flat   in UI_Result_Flat f_in;

layout(location = 0) out vec4 out_color;

#define square(x) (x) * (x)
#define square_root(x) sqrt(x)

// @slop
vec3 linear_from_srgb(vec3 c) {
    return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(0.04045, c));
}

vec3 srgb_from_linear(vec3 c) {
    return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(0.0031308, c));
}

vec3 oklab_from_linear(vec3 c) {
    vec3 lms = mat3(
         0.4122214708, 0.5363325363, 0.0514459929,
         0.2119034982, 0.6806995451, 0.1073969566,
         0.0883024619, 0.2817188376, 0.6299787005
    ) * c;

    lms = pow(lms, vec3(1.0 / 3.0));

    return mat3(
         0.2104542553,  0.7936177850, -0.0040720468,
         1.9779984951, -2.4285922050,  0.4505937099,
         0.0259040371,  0.7827717662, -0.8086757660
    ) * lms;
}

vec3 linear_from_oklab(vec3 c) {
    vec3 lms = mat3(
         1.0,  0.3963377774,  0.2158037573,
         1.0, -0.1055613458, -0.0638541728,
         1.0, -0.0894841775, -1.2914855480
    ) * c;

    lms = lms * lms * lms;

    return mat3(
         4.0767416621, -3.3077115913,  0.2309699292,
        -1.2684380046,  2.6097574011, -0.3413193965,
        -0.0041960863, -0.7034186147,  1.7076147010
    ) * lms;
}

vec4 oklch_from_linear(vec4 c) {
    vec3 lab = oklab_from_linear(c.rgb);
    float chroma = length(lab.yz);
    float hue = atan(lab.z, lab.y); // radians
    if (hue < 0.0) hue += 6.28318530718;
    return vec4(lab.x, chroma, hue, c.a);
}

vec4 linear_from_oklch(vec4 lch_a) {
    float a = lch_a.y * cos(lch_a.z);
    float b = lch_a.y * sin(lch_a.z);
    vec3 rgb = linear_from_oklab(vec3(lch_a.x, a, b));
    return vec4(rgb, lch_a.a);
}

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
    
    vec4 color_ok     = oklch_from_linear(s_in.color);
    vec4 highlight_ok = oklch_from_linear(vec4(1));
    vec4 border_ok    = oklch_from_linear(vec4(0.95, 0.05, 0.65, 1));
    
    factor = f_in.has_mouse != 0 ? factor : 0;
    vec4 inner_ok = mix(color_ok, highlight_ok, factor);
    
    // border and corners
    float border_thickness = 6;
    vec4  border_color = vec4(0.95, 0.05, 0.65, 1);
    vec4  outer_rect = f_in.rect;
    float outer_corner_radius = f_in.corner_radius;
    
    float inner_corner_radius = max(0, f_in.corner_radius - border_thickness);
    vec4  inner_rect = outer_rect + vec4(1,1, -1,-1) * border_thickness;
    
    vec4 color = border_color;
    
    vec2 outer_radius = (outer_rect.zw - outer_rect.xy) * 0.5;
    vec2 outer_center = outer_rect.xy + outer_radius;
    
    vec2 inner_radius = (inner_rect.zw - inner_rect.xy) * 0.5;
    vec2 inner_center = inner_rect.xy + inner_radius;
    
    float d_outer = sdRoundBox(pixel - outer_center, outer_radius, vec4(outer_corner_radius));
    float d_inner = sdRoundBox(pixel - inner_center, inner_radius, vec4(inner_corner_radius));
    
    float aa = fwidth(d_outer);
    
    float outer = 1.0 - smoothstep(-aa, aa, d_outer);
    float inner = 1.0 - smoothstep(-aa, aa, d_inner);
    
    color = linear_from_oklch(mix(border_ok, inner_ok, inner));
    color.a *= outer;
    
    out_color = color;
}