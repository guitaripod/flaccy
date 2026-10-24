#include <metal_stdlib>
using namespace metal;

struct BackdropUniforms {
    float4 colors[8];
    float time;
    float fade;
    float2 padding;
};

struct BackdropVaryings {
    float4 position [[position]];
    float2 uv;
};

vertex BackdropVaryings backdrop_vertex(uint vertexID [[vertex_id]]) {
    float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    BackdropVaryings out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.uv = positions[vertexID] * 0.5 + 0.5;
    return out;
}

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

static float fbm(float2 p) {
    float value = 0.0;
    float amplitude = 0.5;
    for (int i = 0; i < 3; i++) {
        value += amplitude * valueNoise(p);
        p *= 2.03;
        amplitude *= 0.5;
    }
    return value;
}

static float3 paletteField(constant float4 *colors, float n1, float n2, float blend) {
    float3 warm = mix(colors[0].rgb, colors[1].rgb, n1);
    float3 cool = mix(colors[2].rgb, colors[3].rgb, n2);
    return mix(warm, cool, blend);
}

fragment float4 backdrop_fragment(
    BackdropVaryings in [[stage_in]],
    constant BackdropUniforms &uniforms [[buffer(0)]]
) {
    float t = uniforms.time * 0.05;
    float2 q = in.uv * 1.6 + float2(t * 0.6, -t * 0.4);
    float n1 = fbm(q);
    float n2 = fbm(q + float2(3.7, 1.2) + n1 * 1.5 + t * 0.3);
    float blend = smoothstep(0.2, 0.8, fbm(q * 0.7 - t * 0.2));
    float3 colorA = paletteField(uniforms.colors, n1, n2, blend);
    float3 colorB = paletteField(uniforms.colors + 4, n1, n2, blend);
    float3 color = mix(colorA, colorB, uniforms.fade);
    color *= 0.5 + 0.3 * n2;
    float vignette = smoothstep(1.4, 0.3, length(in.uv - 0.5) * 1.6);
    color *= mix(0.55, 1.0, vignette);
    return float4(color, 1.0);
}
