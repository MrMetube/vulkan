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
