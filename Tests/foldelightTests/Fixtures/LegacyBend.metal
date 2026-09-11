// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
#include <metal_stdlib>
using namespace metal;

struct VertexOut { float4 position [[position]]; float2 uv; };
struct BendUniforms { float progress; float perspective; float blur; float shadow; float style; };

vertex VertexOut bendVertex(uint id [[vertex_id]]) {
    float2 positions[] = {float2(-1,-1), float2(3,-1), float2(-1,3)};
    VertexOut out;
    out.position = float4(positions[id], 0, 1);
    out.uv = float2((positions[id].x + 1) * .5, (1 - positions[id].y) * .5);
    return out;
}

fragment float4 bendFragment(VertexOut in [[stage_in]], texture2d<float> desktop [[texture(0)]],
                              constant BendUniforms &u [[buffer(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float p = clamp(u.progress, 0.0, 1.0);
    float fold = p * u.perspective;
    // Inverse projection of a screen hinged along its bottom edge.
    float top = fold * .48;
    float y = (in.uv.y - top) / max(.01, 1.0 - top);
    float width = 1.0 - fold * .44 * (1.0 - y);
    float x = (in.uv.x - .5) / max(.01, width) + .5;
    y += sin(y * M_PI_F) * fold * .1;
    if (y < 0 || y > 1 || x < 0 || x > 1) return float4(.012, .015, .024, 1);
    float2 uv = float2(x,y);
    float2 texel = 1.0 / float2(desktop.get_width(), desktop.get_height());
    float radius = p * u.blur * (u.style > 1.5 ? 32.0 : 15.0) * (1.0 - .55*y);
    float3 color = desktop.sample(s, uv).rgb * .2;
    for (int i=0; i<8; i++) {
        float a = float(i) * M_PI_F * .25;
        color += desktop.sample(s, uv + float2(cos(a),sin(a)) * texel * radius).rgb * .1;
    }
    float darkness = p * u.shadow * (u.style > .5 && u.style < 1.5 ? .85 : .5);
    color *= 1.0 - darkness * (.45 + .55 * (1.0-y));
    if (u.style > 1.5) color = mix(color, float3(.72,.79,.9), p * u.blur * .3);
    float sheen = sin(y * M_PI_F) * p * (u.style < .5 ? .09 : .025);
    return float4(clamp(color + sheen, 0.0, 1.0), 1);
}
