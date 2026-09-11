// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
#include <metal_stdlib>
using namespace metal;

struct VertexOut { float4 position [[position]]; float2 uv; };
struct BendUniforms {
    float progress;
    float pixelScale;
    float sinTilt;
    float cosTilt;
    float blurAmount;
    float vignetteAmount;
    float edgeShadeAmount;
    float padding;
};

// Cubic B-spline reconstruction using four bilinear reads per mip level.
// See NVIDIA GPU Gems 2, chapter 20, Fast Third-Order Texture Filtering.
half3 glassCubicLevel(texture2d<half> tex, float2 uv, uint mip) {
    constexpr sampler s(address::clamp_to_edge, filter::linear, mip_filter::nearest);
    float2 size = float2(tex.get_width(mip), tex.get_height(mip));
    float2 position = uv * size - .5;
    float2 base = floor(position);
    half2 f = half2(position - base);
    half2 oneMinusF = 1.0h - f;
    half2 fSquared = f * f;
    half2 fCubed = fSquared * f;
    half2 w0 = oneMinusF * oneMinusF * oneMinusF / 6.0h;
    half2 w1 = (3.0h * fCubed - 6.0h * fSquared + 4.0h) / 6.0h;
    half2 w2 = (-3.0h * fCubed + 3.0h * fSquared + 3.0h * f + 1.0h) / 6.0h;
    half2 w3 = fCubed / 6.0h;
    half2 a = w0 + w1, b = w2 + w3;
    float2 low = (base - .5 + float2(w1 / a)) / size;
    float2 high = (base + 1.5 + float2(w3 / b)) / size;
    return tex.sample(s, low, level(mip)).rgb * a.x * a.y
        + tex.sample(s, float2(high.x, low.y), level(mip)).rgb * b.x * a.y
        + tex.sample(s, float2(low.x, high.y), level(mip)).rgb * a.x * b.y
        + tex.sample(s, high, level(mip)).rgb * b.x * b.y;
}

half3 glassDiffusion(texture2d<half> tex, float2 uv, float lod) {
    if (tex.get_num_mip_levels() == 1) return glassCubicLevel(tex, uv, 0);
    // The pyramid begins with the half-resolution image, which corresponds to
    // source LOD 1. Shift source-space LOD into this compact texture's indices.
    float bounded = clamp(lod - 1.0, 0.0, float(tex.get_num_mip_levels() - 1));
    uint lower = uint(floor(bounded));
    uint upper = min(lower + 1, tex.get_num_mip_levels() - 1);
    half3 color = glassCubicLevel(tex, uv, lower);
    if (upper == lower) return color;
    float blend = fract(bounded);
    if (blend <= 1e-5) return color;
    return mix(color, glassCubicLevel(tex, uv, upper), half(blend));
}

vertex VertexOut bendVertex(uint id [[vertex_id]]) {
    float2 positions[] = {float2(-1,-1), float2(3,-1), float2(-1,3)};
    VertexOut out;
    out.position = float4(positions[id], 0, 1);
    out.uv = float2((positions[id].x + 1) * .5, (1 - positions[id].y) * .5);
    return out;
}

// The desktop remains on the reference open plane. The physical display is a
// moving pane of glass: trace the viewer's ray through it to that fixed plane.
fragment half4 bendFragment(VertexOut in [[stage_in]], texture2d<half> desktop [[texture(0)]],
                              texture2d<half> diffusion [[texture(1)]],
                              constant BendUniforms &u [[buffer(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear, mip_filter::linear);
    float p = clamp(u.progress, 0.0, 1.0);
    if (p <= 0.0) return half4(desktop.sample(s, in.uv, level(0)).rgb, 1.0h);
    float y = clamp(in.uv.y, 0.0, 1.0);
    float height = 1.0 - y;
    // Camera dimensions are in screen heights. This is a fixed viewing-position
    // approximation, not head tracking. Cap below atan(2/.7) to avoid inversion.
    float separation = height * u.sinTilt;
    float rayScale = 2.0 / (2.0 - separation);
    float x = .5 + (in.uv.x - .5) * rayScale;
    float sourceY = 1.0 - (.7 + (height * u.cosTilt - .7) * rayScale);
    float2 uv = float2(x, sourceY);
    float depth = pow(height, 1.8);
    float amount = u.blurAmount;
    // Filter on the fixed image plane. Physical lid foreshortening cancels its
    // apparent stretch in a face-on panel preview; do not compensate it twice.
    float sigma = amount * 48.0 * depth * u.pixelScale;
    float2 imageSize = float2(desktop.get_width(), desktop.get_height());
    // A rounded desktop silhouette, measured in points so preview and Retina
    // capture agree. Keep the radius at the first active frame; the early return
    // above preserves neutral identity without making slight folds square.
    float cornerRadius = min(28.0 * u.pixelScale, min(imageSize.x, imageSize.y) * .12);
    float2 corner = abs((uv - .5) * imageSize) - (imageSize * .5 - cornerRadius);
    float boundaryDistance = -(length(max(corner, 0.0))
        + min(max(corner.x, corner.y), 0.0) - cornerRadius);
    // Diffuse the border itself, not just pixels inside a rectangular cutout.
    // Extra defocus stays near the same rounded contour and follows separation.
    float perimeter = 1.0 - smoothstep(0.0, 56.0 * u.pixelScale, max(boundaryDistance, 0.0));
    sigma *= 1.0 + .85 * perimeter;
    // Use the analytic contour normal. Differencing the nonlinear distance in
    // pixel quads creates asymmetric antialiasing around mirrored corner arcs.
    float2 outer = max(corner, 0.0);
    float2 normal = length(outer) > 1e-5 ? normalize(outer)
        : (corner.x > corner.y ? float2(1, 0) : float2(0, 1));
    normal *= sign(uv - .5);
    float denominator = (2.0 - separation) * (2.0 - separation);
    float dxdy = -2.0 * (in.uv.x - .5) * u.sinTilt / denominator;
    float dydy = 2.0 * (2.0 * u.cosTilt - .7 * u.sinTilt) / denominator;
    float edgeAA = max(abs(normal.x * rayScale * imageSize.x) * fwidth(in.uv.x)
        + abs(normal.x * dxdy * imageSize.x + normal.y * dydy * imageSize.y) * fwidth(in.uv.y), 1e-4);
    float edgeSoftness = max(.5 * edgeAA, 2.0 * amount * u.pixelScale + 2.0 * sigma);
    float coverage = smoothstep(-edgeSoftness, edgeSoftness, boundaryDistance);
    half3 surround = half3(.008h, .010h, .014h);
    if (coverage <= 0) return half4(surround, 1.0h);

    float lod = .5 * log2(1.0 + 3.0 * sigma * sigma);
    // Mip zero is the original IOSurface, never a copied or softened image.
    half3 color;
    if (lod < .001) color = desktop.sample(s, uv, level(0)).rgb;
    else {
        half3 filtered = glassDiffusion(diffusion, uv, lod);
        color = lod < 1.0 ? mix(desktop.sample(s, uv, level(0)).rgb, filtered, half(lod)) : filtered;
    }

    // Vignette belongs to the physical glass edges, not the image behind them.
    float sideDistance = min(in.uv.x, 1.0 - in.uv.x);
    float lateral = 1.0 - smoothstep(0.0, .32, max(sideDistance, 0.0));
    float vignette = u.vignetteAmount * lateral * (1.0 - .30 * smoothstep(.65, 1.0, y));
    // The lifted edge has neutral optical shade, fading into clear glass well
    // before the hinge. Combine transmittances without crushing both corners.
    float liftedEdge = smoothstep(.55, 1.0, height);
    liftedEdge *= liftedEdge;
    float edgeShade = u.edgeShadeAmount * liftedEdge;
    color *= half((1.0 - vignette) * (1.0 - edgeShade));
    return half4(mix(surround, clamp(color, 0.0h, 1.0h), half(coverage)), 1.0h);
}

// The separable [1,4,6,4,1]/16 Gaussian kernel expressed as three linear samples
// per axis: the +/-1.2 offsets combine weights 4/16 and 1/16 exactly.
// Work runs only at the downsampled resolution, not at the full source size.
kernel void gaussianDownsample(texture2d<half, access::sample> source [[texture(0)]],
                               texture2d<half, access::write> destination [[texture(1)]],
                               uint2 position [[thread_position_in_grid]]) {
    if (position.x >= destination.get_width() || position.y >= destination.get_height()) return;
    constexpr sampler s(coord::pixel, address::clamp_to_edge, filter::linear);
    float2 sourceSize = float2(source.get_width(), source.get_height());
    float2 destinationSize = float2(destination.get_width(), destination.get_height());
    float2 center = (float2(position) + .5) * sourceSize / destinationSize;
    constexpr float offsets[] = {-1.2, 0, 1.2};
    constexpr half weights[] = {.3125h, .375h, .3125h};
    half4 color = 0.0h;
    for (uint y = 0; y < 3; ++y) {
        for (uint x = 0; x < 3; ++x) {
            color += source.sample(s, center + float2(offsets[x], offsets[y])) * weights[x] * weights[y];
        }
    }
    destination.write(color, position);
}
