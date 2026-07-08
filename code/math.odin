#+vet !unused-procedures
#+vet explicit-allocators
#+no-instrumentation
package main

import "base:intrinsics"
import "base:builtin"
import "core:math"
import "core:simd"

////////////////////////////////////////////////
// Types

v2  :: [2] f32
v3  :: [3] f32
v4  :: [4] f32

iv2 :: [2] i32
iv3 :: [3] i32
iv4 :: [4] i32

uv2 :: [2] u32
uv3 :: [3] u32
uv4 :: [4] u32

Color :: [4] u8

LaneWidth :: 8

lane_f32 :: #simd [LaneWidth] f32
lane_u32 :: #simd [LaneWidth] u32
lane_i32 :: #simd [LaneWidth] i32

lane_v2 :: [2] lane_f32
lane_v3 :: [3] lane_f32
lane_v4 :: [4] lane_f32

lane_uv3 :: [3] lane_u32

lane_pmm :: #simd [LaneWidth] pmm
lane_umm :: #simd [LaneWidth] umm
lane_f64 :: #simd [LaneWidth] f64
lane_u64 :: #simd [LaneWidth] u64

lane_false :: cast(lane_u32) 0
lane_true  :: cast(lane_u32) 0xffff_ffff

lane_offset :: lane_u32{0, 1, 2, 3, 4, 5, 6, 7} when LaneWidth == 8 else ( lane_u32{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15} when LaneWidth == 16 else lane_u32{0, 1, 2, 3})

m2 :: matrix[2,2] f32
m3 :: matrix[3,3] f32
m4 :: matrix[4,4] f32

q32 :: quaternion128

Rectangle   :: struct($T: typeid) { min, max: T }
Rectangle2  :: Rectangle(v2)
Rectangle3  :: Rectangle(v3)
Rectangle2i :: Rectangle(iv2)

////////////////////////////////////////////////
// Constants

Tau :: 6.28318530717958647692528676655900576
Pi  :: 3.14159265358979323846264338327950288
E   :: 2.71828182845904523536

SqrtTwo   :: 1.41421356237309504880168872420969808
SqrtThree :: 1.73205080756887729352744634150587236
SqrtFive  :: 2.23606797749978969640917366873127623

Ln2  :: 0.693147180559945309417232121458176568
Ln10 :: 2.30258509299404568401799145468436421

MaxF64Precision :: 16 // Maximum number of meaningful digits after the decimal point for 'f64'
MaxF32Precision ::  8 // Maximum number of meaningful digits after the decimal point for 'f32'
MaxF16Precision ::  4 // Maximum number of meaningful digits after the decimal point for 'f16'

Infinity :: math.INF_F32
QNaN     :: math.QNAN_F32

RadiansFromDegrees :: Tau/360.0
DegreesFromRadians :: 360.0/Tau

////////////////////////////////////////////////
// Scalar operations

square :: proc(x: $T) -> T { return x * x }

square_root :: proc(x: $T) -> T {
    result: T
    when intrinsics.type_is_array(T) {
        #no_bounds_check #unroll for i in 0..<len(T) {
            result[i] = simd.sqrt(x[i])
        }
    } else {
        result = simd.sqrt(x)
    }
    return result
}

power :: math.pow

linear_blend  :: proc{ linear_blend_v_e, linear_blend_e }
linear_blend_v_e :: proc(from: $V/[$N]$Element, to: V, t: Element) -> V {
    result := (1-t) * from + t * to
    
    return result
}
linear_blend_e :: proc(from: $T, to: T, t: T) -> T  {
    result := (1-t) * from + t * to
    
    return result
}

linear_remap :: proc (v: $T, old_from, old_to: T, new_from, new_to: T) -> T {
    result: T
    old_range := old_to - old_from
    if old_range != 0 {
        old_t := (v - old_from) / old_range
        result = linear_blend(new_from, new_to, old_t)
    }
    return result
}

bilinear_blend :: proc (a: $V, b, c, d: V, t: [2] $T) -> V {
    la := (1-t.y) * (1-t.x)
    lb := (1-t.y) *    t.x
    lc :=    t.y  * (1-t.x)
    ld :=    t.y  *    t.x
    
    result = la * a + lb * b + lc * c + ld * d
    return result
}

barycentric_blend :: proc { barycentric_blend_s, barycentric_blend_v }
barycentric_blend_v :: proc (a: $V/ [$N] $E, b, c: V, uv: [2] E) -> V {
    return barycentric_blend(a, b, c, uv[0], uv[1])
}
barycentric_blend_s :: proc (a: $V/ [$N] $E, b, c: V, u, v: E) -> V {
    w := 1 - u - v
    result := w * a + u * b + v * c
    return result
}

// @todo just calculate k and pass it to as many linear_blends as i want
time_smoothed_blend :: proc (from: f64, to: f64, delta_time: f64) -> f64 {
    h :: 3.0 // = the amount of time it takes for the filter to converge to 90% of a fixed input value
    // @speed We could precompute k if needed as it only depends on h and frame time, not the smoothed value itself.
    base := power(cast(f64) .1, 1 / h)
    k := power(base, delta_time)
    
    result := linear_blend(from, to, k)
    return result
}

safe_ratio_or_else :: proc { safe_ratio_or_else_s, safe_ratio_or_else_v }
safe_ratio_or_else_s :: proc(numerator: $T, divisor: T) -> (T, bool) where !intrinsics.type_is_array(T) {
    ratio: T
    ok := divisor != 0
    
    if ok {
        ratio = numerator / divisor
    }
    
    return ratio, ok
}
safe_ratio_or_else_v :: proc(numerator: $V/[$N]$E, divisor: V, n: E) -> (V) {
    ratio: V
    
    #no_bounds_check #unroll for i in 0..<N {
        ratio[i] = safe_ratio_or_n(numerator[i], divisor[i], n)
    }
    
    return ratio
}

safe_ratio_or_n    :: proc(numerator: $T, divisor, n: T) -> T { return safe_ratio_or_else(numerator, divisor) or_else n }
safe_ratio_or_zero :: proc(numerator: $T, divisor: T)    -> T { return safe_ratio_or_else(numerator, divisor) or_else 0 }
safe_ratio_or_one  :: proc(numerator: $T, divisor: T)    -> T { return safe_ratio_or_else(numerator, divisor) or_else 1 }

clamp :: proc(value: $T, min, max: T) -> T {
    result: T
    when intrinsics.type_is_simd_vector(T) {
        result = simd.clamp(value, min, max)
    } else when intrinsics.type_is_array(T) {
        #no_bounds_check #unroll for i in 0..<len(T) {
            result[i] = clamp(value[i], min[i], max[i])
        }
    } else {
        result = builtin.clamp(value, min, max)
    }
    
    return result
}
clamp_01 :: proc(value: $T) -> T { return clamp(value, 0, 1) }

clamp_01_to_range :: proc(min: $T, t, max: T ) -> T {
    range := max - min
    result: T
    if range != 0 {
        percent := (t-min) / range
        result = clamp_01(percent)
    }
    return result
}

sign :: proc{ sign_i, sign_f }
sign_i  :: proc(i: i32) -> i32 { return i >= 0 ? 1 : -1 }
sign_f  :: proc(x: f32) -> f32 { return x >= 0 ? 1 : -1 }

modulus :: proc { modulus_i, modulus_f, modulus_vf, modulus_v }
modulus_f :: proc(value: f32, divisor: f32) -> f32 {
    return math.mod(value, divisor)
}
modulus_i :: proc(value: $I, divisor: I) -> I where intrinsics.type_is_integer(I) {
    return value % divisor
}
modulus_vf :: proc(value: [$N] f32, divisor: f32) -> [N] f32 where N > 1 {
    #no_bounds_check #unroll for i in 0..<N do result[i] = math.mod(value[i], divisor) 
    return result
}
modulus_v :: proc(value: [$N] f32, divisor: [N] f32) -> [N] f32 {
    #no_bounds_check #unroll for i in 0..<N do result[i] = math.mod(value[i], divisor[i]) 
    return result
}

round :: proc { round_f, round_v }
round_f :: proc($T: typeid, f: $F) -> T  where !intrinsics.type_is_array(F) {
    return  cast(T) (f < 0 ? -math.round(-f) : math.round(f))
}
round_v :: proc($T: typeid, v: [$N] $F) -> [N] T {
    result: [N] T
    #no_bounds_check #unroll for i in 0..<N {
        result[i] = cast(T) math.round(v[i]) 
    }
    return result
}

floor :: proc { floor_s, floor_v }
floor_s :: proc($T: typeid, f: $F) -> T {
    result := cast(T) (simd.floor(f) when F == lane_f32 else math.floor(f))
    return result
}
floor_v :: proc($T: typeid, v: [$N] f32) -> [N] T {
    result: [N] T
    #unroll for i in 0..<N {
        result[i] = floor(T, v[i])
    }
    return result
}

ceil :: proc { ceil_s, ceil_v }
ceil_s :: proc($T: typeid, f: f32) -> T {
    result := cast(T) (simd.ceil(f) when T == lane_f32 else math.ceil(f))
    return result
}
ceil_v :: proc($T: typeid, v: [$N] f32) -> [N] T {
    result: [N] T
    #unroll for i in 0..<N {
        result[i] = ceil(T, v[i])
    }
    return result
}

truncate :: proc { truncate_s, truncate_v }
truncate_s :: proc($T: typeid, f: f32) -> T {
    return cast(T) f
}
truncate_v :: proc($T: typeid, fs: [$N] f32) -> [N] T {
    return vec_cast(T, fs)
}

sin :: math.sin
cos :: math.cos
tan :: math.tan
acos  :: math.acos
asin  :: math.asin
atan2 :: math.atan2

fractional :: proc { fractional_v, fractional_f }
fractional_v :: proc (v: v2) -> (fractional, integral: v2) {
    fractional.x, integral.x = fractional_f(v.x)
    fractional.y, integral.y = fractional_f(v.y)
    return fractional, integral
}
fractional_f :: proc (x: f32) -> (fractional, integral: f32) {
    integral   = cast(f32) floor(i32, x)
    fractional = x - integral
    return fractional, integral
}


////////////////////////////////////////////////
// Vector operations

Rect3 :: proc(xy: $R/ Rectangle([2] $Element), z_min, z_max: Element) -> Rectangle([3] Element) { 
    return { V3(xy.min, z_min), V3(xy.max, z_max)}
}

perpendicular :: proc(v: v2) -> v2 {
    result := v2{ -v.y, v.x }
    return result
}

arm :: proc(angle: f32) -> v2 {
    result := v2{cos(angle), sin(angle)}
    return result
}

dot :: proc(a: $V/ [$N] $E, b: V) -> E {
    result := a.x * b.x
    result  = fused_mul_add(a.y, b.y, result)
    when N >= 3 do result = fused_mul_add(a.z, b.z, result)
    when N >= 4 do result = fused_mul_add(a.w, b.w, result)
    return result
}

cross :: proc(a: $V, b: V) -> V {
    result: V
    result.x = fused_mul_add(a.y, b.z, -a.z*b.y)
    result.y = fused_mul_add(a.z, b.x, -a.x*b.z)
    result.z = fused_mul_add(a.x, b.y, -a.y*b.x)
    
    return result
}

reflect :: proc(v, axis: $V) -> V {
    result := v - 2 * dot(v, axis) * axis
    return result
}
project :: proc(v, axis: $V) -> V {
    result := v - 1 * dot(v, axis) * axis
    return result
}

length :: proc(vec: $V/ [$N] $T) -> T {
    squared_length := length_squared(vec)
    result := square_root(squared_length)
    return result
}

length_squared :: proc(vec: $V/ [$N] $T) -> T {
    result := dot(vec, vec)
    return result
}

normalize :: proc(vec: $V) -> V {
    result = vec / length(vec)
    return result
}

normalize_or_else :: proc(vec: $V/ [$N] $T) -> (V, bool) {
    result: V
    ok: bool
    len_sq := length_squared(vec)
    if len_sq > 0.0000001 {
        ok = true
        result = vec / square_root(len_sq)
    }
    return result, ok
}
normalize_or_zero :: proc(vec: $V/ [$N] $T) -> V {
    when intrinsics.type_is_simd_vector(T) {
        len_sq := length_squared(vec)
        conditional_assign(greater_than(len_sq, 0.0000001), &result, vec / square_root(len_sq))
    } else {
        result = normalize_or_else(vec) or_else 0
    }
    return result
}

linear_to_srgb :: proc(l: v3) -> v3 {
    l := l
    l = clamp_01(l)
    s: v3
    #no_bounds_check #unroll for i in 0..<len(l) {
        s[i] = 12.92 * l[i]
        if l[i] > 0.0031308 {
            s[i] = 1.055 * power(l[i], 1.0/2.4) - 0.055
        }
    }
    
    return s
}

color_to_u8 :: proc { color_to_u8_3, color_to_u8_4 }
color_to_u8_3 :: proc (color: v3) -> Color {
    v := cast(v4) 255
    v.rgb *= color
    result := round(u8, v)
    return result
}
color_to_u8_4 :: proc (color: v4) -> Color {
    v := cast(v4) 255
    v.rgba *= color
    result := round(u8, v)
    return result
}

////////////////////////////////////////////////
// Simd operations

ternary :: proc (mask: $M, then_value: $T, else_value: T) -> T {
    result: T
    
    when intrinsics.type_is_array(T) {
        #no_bounds_check #unroll for i in 0..<len(T) {
            result[i] = ternary(mask, then_value[i], else_value[i])
        }
    } else {
        result = simd.select(mask, then_value, else_value)
    }
    
    return result
}

conditional_assign :: proc (mask: $M, dest: ^$D, value: D) {
    when intrinsics.type_is_array(D) {
        #no_bounds_check #unroll for i in 0..<len(D) {
            conditional_assign(mask, &dest[i], value[i])
        }
    } else {
        simd.masked_store(dest, value, mask)
    }
}

absolute      :: simd.abs
greater_equal :: simd.lanes_ge
less_equal    :: simd.lanes_le
greater_than  :: simd.lanes_gt
less_than     :: simd.lanes_lt
equal         :: simd.lanes_eq
not_equal     :: simd.lanes_ne

fused_mul_add :: proc(a: $T, b, c: T) -> T  {
    when intrinsics.type_is_array(T) {
        result: T
        #no_bounds_check #unroll for i in 0..<len(T) {
            result[i] = simd.fma(a[i], b[i], c[i])
        }
    } else {
        result := simd.fma(a, b, c)
    }
    return result
}

is_nan :: proc { is_nan_s, is_nan_v }

is_nan_v :: proc (x: $V/ #simd[$N] $F) -> #simd[N] (u32 when F == f32 else u64) {
    result := not_equal(x, x)
    return result
}
is_nan_s :: proc (x: $F) -> bool where !intrinsics.type_is_simd_vector(F) {
    result := !(x == x)
    return result
}

approximate_equal :: proc (a, b: lane_f32, epsilon : lane_f32 = 0.000001) -> lane_u32 {
    result := less_than(absolute(a - b), epsilon)
    return result
}

shift_left     :: simd.shl
shift_right    :: simd.shr
horizontal_add :: simd.reduce_add_bisect
maximum :: proc (a: $T, b: T) -> T {
    when intrinsics.type_is_simd_vector(T) {
        return simd.max(a, b)
    } else {
        return max(a, b)
    }
}
minimum :: proc (a: $T, b: T) -> T {
    when intrinsics.type_is_simd_vector(T) {
        return simd.min(a, b)
    } else {
        return min(a, b)
    }
}

min_max :: proc (a: $T, b: T) -> (min, max: T) {
    when intrinsics.type_is_simd_vector(T) {
        min, max = b, a
        mask := less_than(a, b)
        conditional_assign(mask, &min, a)
        conditional_assign(mask, &max, b)
        return min, max
    } else {
        min, max = b, a
        if a < b do min, max = a, b
        return min, max
    }
}

extract :: proc { extract_s, extract_v2, extract_v3 }
extract_v3 :: proc (a: lane_v3, #any_int n: u32) -> v3 {
    result: v3
    result.x = extract(a.x, n)
    result.y = extract(a.y, n)
    result.z = extract(a.z, n)
    return result
}
extract_v2 :: proc (a: lane_v2, #any_int n: u32) -> v2 {
    result: v2
    result.x = extract(a.x, n)
    result.y = extract(a.y, n)
    return result
}
extract_s :: proc (a: $T/#simd[$N] $Element, #any_int n: u32) -> Element {
    result: Element
    when intrinsics.type_is_array(T) {
        #no_bounds_check #unroll for i in 0..<len(T) {
            result[i] = simd.extract(a[i], n)
        }
    } else {
        result = simd.extract(a, n)
    }
    return result
}

replace :: proc { replace_s, replace_v2, replace_v3 }
replace_v3 :: proc (a: ^lane_v3, #any_int n: u32, value: v3) {
    replace(&a.x, n, value.x)
    replace(&a.y, n, value.y)
    replace(&a.z, n, value.z)
}
replace_v2 :: proc (a: ^lane_v2, #any_int n: u32, value: v2) {
    replace(&a.x, n, value.x)
    replace(&a.y, n, value.y)
}
replace_s :: proc (a: ^$T/ #simd[$N] $Element, #any_int n: u32, value: Element) {
    when intrinsics.type_is_array(T) {
        #no_bounds_check #unroll for i in 0..<len(T) {
            a[i] = simd.replace(a[i], n, value[i])
        }
    } else {
        a^ = simd.replace(a^, n, value)
    }
}

////////////////////////////////////////////////
// Matrix operations

identity :: proc () -> m4 {
    result : m4 = 1
    return result
}

transpose :: proc (a: m4) -> m4 {
    result: m4
    #no_bounds_check #unroll for c in 0 ..= 3 {
        #unroll for r in 0 ..= 3 {
            result[c, r] = a[r, c]
        }
    }
    return result
}

////////////////////////////////////////////////

multiply :: proc { multiply3, multiply4 }
multiply4 :: proc (a: m4, p: v4) -> v4 {
    result: v4
    result.x = a[0, 0] * p.x + a[0, 1] * p.y + a[0, 2] * p.z + a[0, 3] * p.w
    result.y = a[1, 0] * p.x + a[1, 1] * p.y + a[1, 2] * p.z + a[1, 3] * p.w
    result.z = a[2, 0] * p.x + a[2, 1] * p.y + a[2, 2] * p.z + a[2, 3] * p.w
    result.w = a[3, 0] * p.x + a[3, 1] * p.y + a[3, 2] * p.z + a[3, 3] * p.w
    
    return result
}
multiply3 :: proc (a: m4, p: v3, w: f32 = 1) -> v3 {
    product := multiply(a, v4{**p, w})
    result := product.xyz
    result /= product.w 
    
    return result
}

////////////////////////////////////////////////

x_rotation :: yz_rotation
y_rotation :: xz_rotation
z_rotation :: xy_rotation

xy_rotation :: proc (angle: f32) -> m4 {
    c := cos(angle)
    s := sin(angle)
    
    result := m4 {
        c, -s, 0, 0,
        s,  c, 0, 0,
        0,  0, 1, 0,
        0,  0, 0, 1,
    }
    
    return result
}

yz_rotation :: proc (angle: f32) -> m4 {
    c := cos(angle)
    s := sin(angle)
    
    result := m4 {
        1, 0,  0, 0,
        0, c, -s, 0,
        0, s,  c, 0,
        0, 0,  0, 1,
    }
    
    return result
}

xz_rotation :: proc (angle: f32) -> m4 {
    c := cos(angle)
    s := sin(angle)

    result := m4 {
         c, 0, s, 0,
         0, 1, 0, 0,
        -s, 0, c, 0,
         0, 0, 0, 1,
    }

    return result
}

translate :: proc (a: m4, t: v3) -> m4 {
    result := a
    
    result[0, 3] += t.x
    result[1, 3] += t.y
    result[2, 3] += t.z
    
    return result
}

////////////////////////////////////////////////

get_column :: proc (a: m4, column: u32) -> v3 {
    result: v3
    
    result.x = a[0, column]
    result.y = a[1, column]
    result.z = a[2, column]
    
    return result
}

get_column_v4 :: proc (a: m4, column: u32) -> v4 {
    result: v4
    
    result.x = a[0, column]
    result.y = a[1, column]
    result.z = a[2, column]
    result.w = a[3, column]
    
    return result
}

get_row :: proc (a: m4, row: u32) -> v3 {
    result: v3
    
    result.x = a[row, 0]
    result.y = a[row, 1]
    result.z = a[row, 2]
    
    return result
}

get_row_v4 :: proc (a: m4, row: u32) -> v4 {
    result: v4
    
    result.x = a[row, 0]
    result.y = a[row, 1]
    result.z = a[row, 2]
    result.w = a[row, 3]
    
    return result
}

rows_3x3 :: proc (x, y, z: v3) -> m4 {
    result: m4
    
    result = m4 {
        x.x, x.y, x.z, 0,
        y.x, y.y, y.z, 0,
        z.x, z.y, z.z, 0,
          0,   0,   0, 1,
    }
    return result
}

columns_3x3 :: proc (x, y, z: v3) -> m4 {
    result: m4
    
    result = m4 {
        x.x, y.x, z.x, 0,
        x.y, y.y, z.y, 0,
        x.z, y.z, z.z, 0,
          0,   0,   0, 1,
    }
    return result
}

projection_reversed_z_infinite_far_plane :: proc (fov_y, aspect_w_h, near_z: f32) -> m4 {
    f := 1 / tan(fov_y / 2)
    x := f / aspect_w_h
    y := f
    n := near_z
    
    // :ViewSpace:
    result := m4 {
        x,  0,  0,  0,
        0, -y,  0,  0, // invert y axis
        0,  0,  0,  n,
        0,  0, -1,  0, // -1 so we look down -z
    }
    
    return result
}

////////////////////////////////////////////////
// Rectangle operations

rect_min_dimension    :: proc { rect_min_dimension_2, rect_min_dimension_v }
rect_zero_dimension   :: proc { rect_zero_dimension_2, rect_zero_dimension_v }
rect_min_max          :: proc { rect_min_max_2, rect_min_max_v }
rect_min_dimension_2  :: proc (x: $E, y, w, h: E)                 -> Rectangle([2] E) { return { {x, y},                   {w, h}                   } }
rect_min_dimension_v  :: proc (min: $T, dimension: T)             -> Rectangle(T)     { return { min,                      min + dimension          } }
rect_zero_dimension_2 :: proc (w: $E, h: E)                       -> Rectangle([2] E) { return { 0,                        {w, h}                   } }
rect_zero_dimension_v :: proc (dimension: $T)                     -> Rectangle(T)     { return { 0,                        dimension                } }
rect_min_max_v        :: proc (min: $T, max: T)                   -> Rectangle(T)     { return { min,                      max                      } }
rect_min_max_2        :: proc (min_x: $E, min_y, max_x, max_y: E) -> Rectangle([2] E) { return { {min_x, min_y},           {max_x, max_y}           } }
rect_center_dimension :: proc (center: $T, dimension: T)          -> Rectangle(T)     { return { center - (dimension / 2), center + (dimension / 2) } }
rect_center_radius    :: proc (center: $T, radius: T)             -> Rectangle(T)     { return { center - radius,          center + radius          } }

rect_inverted_infinity :: proc($R: typeid) -> R {
    T :: intrinsics.type_field_type(R, "min")
    #assert(intrinsics.type_is_subtype_of(R, Rectangle(T)))
    E :: intrinsics.type_elem_type(T)
    
    result.min = max(E)
    result.max = min(E)
    
    return result
}

rect_get_max       :: proc(rect: Rectangle($T)) -> T { return rect.max }
rect_get_min       :: proc(rect: Rectangle($T)) -> T { return rect.min }
rect_get_dimension :: proc(rect: Rectangle($T)) -> T { return rect.max - rect.min }
rect_get_center    :: proc(rect: Rectangle($T)) -> T { return rect.min + 0.5 * rect_get_dimension(rect) }

rect_add_radius :: proc(rect: $R/Rectangle($T), radius: T) -> R {
    result = rect
    result.min -= radius
    result.max += radius
    return result
}

rect_scale_radius :: proc(rect: $R/Rectangle($T), factor: T) -> R {
    result = rect
    center := rect_get_center(rect)
    result.min = linear_blend(center, result.min, factor)
    result.max = linear_blend(center, result.max, factor)
    return result
}

rect_add_offset :: proc(rect: $R/Rectangle($T), offset: T) -> R {
    result.min = rect.min + offset
    result.max = rect.max + offset
    
    return result
}

rect_contains :: proc(rect: Rectangle($T), point: T) -> bool {
    result = true
    #no_bounds_check #unroll for i in 0..<len(T) {
        result &&= rect.min[i] <= point[i] && point[i] < rect.max[i] 
    }
    return result
}

rect_contains_inclusive :: proc(rect: Rectangle($T), point: T) -> bool {
    result = true
    #no_bounds_check #unroll for i in 0..<len(T) {
        result &&= rect.min[i] <= point[i] && point[i] <= rect.max[i] 
    }
    return result
}

dimension_contains :: proc(dimension: $V/[$N]$T, point: V) -> bool {
    result = true
    #no_bounds_check #unroll for i in 0..<N {
        result &&= 0 <= point[i] && point[i] < dimension[i] 
    }
    return result
}

rect_contains_rect :: proc(a: $R/Rectangle($T), b: R) -> bool {
    u := rect_union(a, b)
    result = a == u
    return result
}

rect_intersects :: proc(a, b: Rectangle($T)) -> bool {
    result  = !(b.max.x <= a.min.x || b.min.x >= a.max.x)
    result &= !(b.max.y <= a.min.y || b.min.y >= a.max.y)
    when len(T) >= 3 do result &= !(b.max.z <= a.min.z || b.min.z >= a.max.z)
    
    return result
}


rect_intersection :: proc(a, b: $R/Rectangle($T)) -> R {
    result.min.x = max(a.min.x, b.min.x)
    result.min.y = max(a.min.y, b.min.y)
    
    result.max.x = min(a.max.x, b.max.x)
    result.max.y = min(a.max.y, b.max.y)
    
    when len(T) >= 3 {
        result.min.z = max(a.min.z, b.min.z)
        result.max.z = min(a.max.z, b.max.z)
    }
    return result
    
}

rect_union_point :: proc(a: $R/Rectangle($T), b: T) -> R {
    result.min.x = min(a.min.x, b.x)
    result.min.y = min(a.min.y, b.y)
    
    result.max.x = max(a.max.x, b.x)
    result.max.y = max(a.max.y, b.y)
    
    when len(T) >= 3 {
        result.min.z = min(a.min.z, b.z)
        result.max.z = max(a.max.z, b.z)
    }
    
    return result
}

rect_union :: proc(a: $R/Rectangle($T), b: R) -> R {
    result.min.x = min(a.min.x, b.min.x)
    result.min.y = min(a.min.y, b.min.y)
    
    result.max.x = max(a.max.x, b.max.x)
    result.max.y = max(a.max.y, b.max.y)
    
    when len(T) >= 3 {
        result.min.z = min(a.min.z, b.min.z)
        result.max.z = max(a.max.z, b.max.z)
    }
    
    return result
}

rect_get_barycentric :: proc(rect: Rectangle($T), p: T) -> T {
    result = safe_ratio_or_zero(p - rect.min, rect.max - rect.min)
    
    return result
}

rect_xy :: proc(rect: Rectangle3) -> Rectangle2 {
    result: Rectangle2
    result.min = rect.min.xy
    result.max = rect.max.xy
    
    return result
}

rect_clamped_area :: proc(rect: Rectangle([$N] $E)) -> E {
    dimension := rect.max - rect.min
    ok := true
    #no_bounds_check #unroll for axis in 0..<N do if dimension[axis] <= 0 { ok = false }
    if ok {
        result = dimension.x * dimension.y
    }
    
    return result
}

rect_has_area :: proc(rect: Rectangle2i) -> bool {
    return rect.min.x < rect.max.x && rect.min.y < rect.max.y
}