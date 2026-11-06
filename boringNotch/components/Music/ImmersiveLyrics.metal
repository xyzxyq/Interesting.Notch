#include <metal_stdlib>
using namespace metal;

static float focusHash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

// Paired neutral highlights and shadows keep glass edges visible on light and dark desktops.
[[ stitchable ]] half4 immersiveProjector(float2 position, half4 color, float2 size,
                                          float sourceWidth, float receiverWidth, float time) {
    float x = abs(position.x - size.x * 0.5);
    float y = position.y;
    float source = clamp(sourceWidth * 0.5, 1.0, size.x * 0.5 - 1.0);
    float receiver = clamp(receiverWidth * 0.5, source, size.x * 0.5 - 1.0);
    float height = max(size.y, 1.0);
    float slope = (receiver - source) / height;
    float rayX = source + min(y, height) * slope;
    float distance = (x - rayX) / sqrt(1.0 + slope * slope);
    float fade = smoothstep(0.0, 2.0, y) * (1.0 - smoothstep(height * 0.45, height, y));
    float flow = 0.94 + 0.06 * sin(y * 0.12 - time * 0.75);
    float edge = exp(-pow((distance - 0.7) / 1.3, 2.0)) * fade;
    float glow = exp(-pow(distance / 5.0, 2.0)) * fade;
    float apertureMask = 1.0 - smoothstep(rayX * 0.35, rayX, x);
    float aperture = apertureMask * smoothstep(0.0, 3.0, y) * exp(-pow((y - 3.5) / 2.2, 2.0));
    // A black throat hides the glass's top edge, then opens into a soft band of light.
    half throat = half((1.0 - smoothstep(0.0, 4.0, y))
                      * (1.0 - smoothstep(-0.6, 0.6, distance))) * color.a;
    half shade = half(edge * 0.34 + glow * 0.035) * color.a;
    half3 rgb = half3(0.14, 0.16, 0.20) * shade;
    float core = exp(-pow((distance + 0.45) / 0.62, 2.0)) * fade * flow;
    half light = half(aperture * 0.38 + core * 0.65) * color.a;
    rgb = rgb * (1.0h - light) + half3(0.89, 0.93, 0.98) * light;
    return half4(rgb, (shade + throat * (1.0h - shade)) * (1.0h - light) + light);
}

#include <SwiftUI/SwiftUI_Metal.h>

// One transparent lens bends the glyphs without painting a band or leaving a trailing wave.
[[ stitchable ]] half4 immersiveLyricWave(float2 position, SwiftUI::Layer layer, float2 size,
                                          float textWidth, float progress, float strength) {
    if (progress <= 0.0 || progress >= 1.0) { return layer.sample(position); }
    float left = (size.x - textWidth) * 0.5;
    float front = mix(left - 40.0, left + textWidth + 40.0, progress);
    float d = position.x - front - (position.y - 41.0) * 0.10;
    if (abs(d) >= 19.0) { return layer.sample(position); }
    float u = d / 19.0;
    float lens = pow(1.0 - u * u, 2.0);
    float fade = smoothstep(0.0, 0.06, progress) * (1.0 - smoothstep(0.94, 1.0, progress));
    float2 offset = float2(3.0 * u, 2.1 + (position.y - 41.0) * 0.045)
        * lens * fade * strength * 0.70;
    return layer.sample(position - offset);
}

// Outline the final layer so the contour follows the particles and leaves no stale glyph.
[[ stitchable ]] half4 immersiveLyricOutline(float2 position, SwiftUI::Layer layer, float reducedTransparency) {
    half4 ink = layer.sample(position);
    half expanded = ink.a;
    for (int i = 0; i < 8; ++i) {
        float angle = float(i) * 0.785398;
        half neighbor = layer.sample(position + float2(cos(angle), sin(angle)) * 0.85).a;
        expanded = max(expanded, neighbor);
    }
    // A narrow inner bevel stays bright while the letter's center transmits the background.
    half upper = layer.sample(position - float2(0, 0.45)).a;
    half lower = layer.sample(position + float2(0, 0.45)).a;
    half left = layer.sample(position - float2(0.45, 0)).a;
    half right = layer.sample(position + float2(0.45, 0)).a;
    float coverage = max(float(ink.a), 0.001);
    float rim = clamp(float(ink.a - min(min(upper, lower), min(left, right))) / coverage, 0.0, 1.0);
    float bevel = clamp(float(ink.a - min(upper, left)) / coverage, 0.0, 1.0);
    float highlight = max(bevel, exp(-pow((position.y - 32.0) / 2.8, 2.0)) * 0.65);
    half opacity = reducedTransparency > 0.5 ? 1.0h
        : half(min(0.97, 0.90 + highlight * 0.04 + rim * 0.03));
    half glass = mix(0.985h, 1.0h, half(highlight));
    half outline = expanded * (1.0h - ink.a) * 0.88h;
    return half4(ink.rgb * glass * opacity + half3(0.03h * outline),
                 ink.a * opacity + outline);
}

[[ stitchable ]] half4 immersiveParticleDissolve(float2 position, SwiftUI::Layer layer,
                                                 float progress) {
    if (progress >= 1.0) { return half4(0); }
    half4 original = layer.sample(position);
    if (progress < 0.0) { return original; }

    float p = clamp(progress, 0.0, 1.0);
    float2 drift = float2(48.0 * p, -14.0 * p);
    const float grid = 2.0;
    float2 cell = floor((position - drift) / grid);
    half4 dust = half4(0);
    // Local scatter stays within two cells; sample glyph alpha only for a visible dot.
    for (int y = -2; y <= 2; ++y) {
        for (int x = -2; x <= 2; ++x) {
            float2 origin = (cell + float2(x, y) + 0.5) * grid;
            float seed = focusHash(cell + float2(x, y));
            float2 curl = float2(sin(seed * 31.0 + p * 4.0), cos(seed * 23.0 + p * 3.0)) * (3.6 * p);
            float2 center = origin + drift + curl;
            float distance = length(position - center);
            float radius = (0.35 + seed * 0.35) * (1.0 - 0.45 * p);
            float dot = 1.0 - smoothstep(radius * 0.5, radius + 0.3, distance);
            if (dot <= 0.0) { continue; }
            half4 sample = layer.sample(origin);
            half alpha = sample.a * half(dot * pow(1.0 - p, 0.8));
            // The source cell owns one hue for its whole flight; no animated color cycling.
            float hue = fract(seed * 19.17);
            float3 rainbow = clamp(abs(fract(hue + float3(0, 2.0/3.0, 1.0/3.0)) * 6.0 - 3.0) - 1.0, 0.0, 1.0);
            half3 tint = half3(mix(float3(1), rainbow, 0.72));
            dust += half4(tint * alpha, alpha);
        }
    }
    dust = min(dust, half4(1));
    half breakup = half(smoothstep(0.0, 0.18, p));
    return original * (1.0h - breakup) + dust * breakup;
}
