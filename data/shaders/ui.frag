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

vec3 oklch_from_linear(vec3 c) {
    vec3 lab = oklab_from_linear(c);
    float chroma = length(lab.yz);
    float hue = atan(lab.z, lab.y); // radians
    if (hue < 0.0) hue += 6.28318530718;
    return vec3(lab.x, chroma, hue);
}

vec3 linear_from_oklch(vec3 lch) {
    float a = lch.y * cos(lch.z);
    float b = lch.y * sin(lch.z);
    return linear_from_oklab(vec3(lch.x, a, b));
}

////////////////////////////////////////////////

bool is_in_rounded_corner(vec4 rect, float corner_radius, vec2 pixel) {
    vec2 min_delta = rect.xy - pixel +  corner_radius;
    vec2 max_delta = rect.zw - pixel + -corner_radius;
    
    float corner_radius_squared = square(corner_radius);
    
    bool result = false;
    if (
        (min_delta.x > 0 && min_delta.y > 0 && square(min_delta.x) + square(min_delta.y) - corner_radius_squared > 0) ||
        (min_delta.x > 0 && max_delta.y < 0 && square(min_delta.x) + square(max_delta.y) - corner_radius_squared > 0) ||
        (max_delta.x < 0 && min_delta.y > 0 && square(max_delta.x) + square(min_delta.y) - corner_radius_squared > 0) ||
        (max_delta.x < 0 && max_delta.y < 0 && square(max_delta.x) + square(max_delta.y) - corner_radius_squared > 0) ) {
        result = true;
    }
    return result;
}

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
    
    vec4 a = s_in.color;
    vec4 b = vec4(1, 1, 1, 1);
    
    vec3 a_ok = oklch_from_linear(a.rgb);
    vec3 b_ok = oklch_from_linear(b.rgb);
    
    factor = f_in.has_mouse != 0 ? factor : 0;
    vec3 mix_ok = mix(a_ok, b_ok, factor);
    
    vec3 rgb = linear_from_oklch(mix_ok);
    
    vec4 color = vec4(rgb, mix(a.a, b.a, factor));
    
    if (is_in_rounded_corner(f_in.rect, f_in.corner_radius, pixel)) {
        color.a = 0;
    }
    
    out_color = color;
}