#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

struct PreviewUniforms {
    float2 scale;
    int width;
    int height;
    int layout; // 0 = UYVY, 1 = v210
};

vertex VertexOut previewVertex(uint id [[vertex_id]], constant PreviewUniforms &u [[buffer(0)]]) {
    const float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    VertexOut out;
    out.position = float4(corners[id] * u.scale, 0, 1);
    out.uv = float2((corners[id].x + 1) / 2, (1 - corners[id].y) / 2);
    return out;
}

static float3 ycbcrToRGB(float y, float cb, float cr) {
    // Rec.709 limited range, with components normalised to 0...1 of full code range.
    float luma = (y - 16.0 / 255.0) * (255.0 / 219.0);
    float b = (cb - 128.0 / 255.0) * (255.0 / 224.0);
    float r = (cr - 128.0 / 255.0) * (255.0 / 224.0);
    return saturate(float3(luma + 1.5748 * r, luma - 0.1873 * b - 0.4681 * r, luma + 1.8556 * b));
}

fragment float4 previewFragment(VertexOut in [[stage_in]],
                                constant PreviewUniforms &u [[buffer(0)]],
                                texture2d<uint, access::read> frame [[texture(0)]]) {
    int x = min(int(in.uv.x * u.width), u.width - 1);
    int y = min(int(in.uv.y * u.height), u.height - 1);

    if (u.layout == 0) {
        uint4 w = frame.read(uint2(x / 2, y));
        float luma = float((x & 1) == 0 ? w.g : w.a) / 255.0;
        return float4(ycbcrToRGB(luma, float(w.r) / 255.0, float(w.b) / 255.0), 1);
    }

    // Each 16-byte v210 group holds 6 pixels across 4 words of 3 10-bit components.
    int group = x / 6;
    int position = x % 6;
    int word = group * 4;
    uint3 w0 = frame.read(uint2(word, y)).rgb;
    uint3 w1 = frame.read(uint2(word + 1, y)).rgb;
    uint3 w2 = frame.read(uint2(word + 2, y)).rgb;
    uint3 w3 = frame.read(uint2(word + 3, y)).rgb;

    uint luma;
    switch (position) {
        case 0: luma = w0.g; break;
        case 1: luma = w1.r; break;
        case 2: luma = w1.b; break;
        case 3: luma = w2.g; break;
        case 4: luma = w3.r; break;
        default: luma = w3.b; break;
    }
    uint cb;
    uint cr;
    switch (position / 2) {
        case 0: cb = w0.r; cr = w0.b; break;
        case 1: cb = w1.g; cr = w2.r; break;
        default: cb = w2.b; cr = w3.g; break;
    }
    return float4(ycbcrToRGB(float(luma) / 1023.0, float(cb) / 1023.0, float(cr) / 1023.0), 1);
}
