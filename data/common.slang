typealias s8  = int8_t;
typealias u8  = uint8_t;
typealias u16 = uint16_t;
typealias u32 = uint32_t;

typealias f16 = half;
typealias f32 = float;
typealias v2 = float2;
typealias v3 = float3;
typealias v4 = float4;
typealias m3 = float3x3;
typealias m4 = float4x4;

typealias q4 = float4; // quaternion

v3 rotate (q4 q, v3 v) {
    return v + 2.0 * cross(q.xyz, cross(q.xyz, v) + q.w * v);
}
