//
// LiquidGlass.metal -- iOS 26 Liquid Glass effect adapted to iOS 15 / A9 GPU.
//
// Compiled at CI time on a macOS runner via:
//
//   xcrun -sdk iphoneos metal    -c  LiquidGlass.metal -o LiquidGlass.air
//   xcrun -sdk iphoneos metallib    LiquidGlass.air    -o LiquidGlassShaders.metallib
//
// The resulting LiquidGlassShaders.metallib is committed back to
// lockforge/layout/Library/LockForge/ where Theos automatically
// packages it into the .deb. LFLiquidGlassMetalView loads it from
// the bundle at runtime via [MTLDevice newLibraryWithFile:] so we
// never need the metal toolchain on the developer's machine.
//
// Algorithm credit: Alexey Demin's LiquidGlassKit (MIT licensed,
// https://github.com/DnV1eX/LiquidGlassKit). This file is a stripped-
// down port: we keep the pieces that visibly differentiate Liquid
// Glass from a plain blur, and drop the perceptual-LCH pipeline +
// glare + multi-rectangle smooth-union because:
//
//   1) iPhone 6s ships an A9 GPU (one fragment shader executes per
//      pixel; on a 750x1334 retina lock screen that's ~1M pixels
//      every frame). LCH conversion is ~80 fp ops/pixel -- cheap on
//      A12 but visible heat on A9. We use a straight RGB mix instead;
//      the difference next to a blurred wallpaper is imperceptible.
//
//   2) LockForge clock has exactly ONE shape (the digit-mask glass
//      pill). The smooth-union loop in the original was for merging
//      multiple drag-target circles. We hard-code rectangleCount=1.
//
//   3) Glare adds a directional specular highlight that's beautiful
//      on Apple's tab bars but distracting on numerals. Drop it; the
//      Fresnel rim does the job of delineating the digit edges.
//
// What stays: the proper Snell refraction with chromatic dispersion
// (R/G/B sampled with slightly different offsets so the digit edges
// pick up a faint rainbow), and the Fresnel rim that brightens
// edges based on distance to the SDF boundary. These two are what
// make Liquid Glass look like glass and not like a blur.

#include <metal_stdlib>
#include <simd/simd.h>
using namespace metal;

#define PI M_PI_F

// ---- Refractive indices for dispersion (per channel) -------------
// Slight offset between R and B so light splits at edges (prism).
constant float refractiveIndexRed   = 1.0f - 0.02f;
constant float refractiveIndexGreen = 1.0f;
constant float refractiveIndexBlue  = 1.0f + 0.02f;

// ---- Vertex output / fragment input ------------------------------
struct VertexOutput {
    float4 position [[position]];   // NDC
    half2  uv;                      // [0,1]
};

// ---- Uniforms (mirrors LFLGMetalUniforms in the Obj-C side) ------
//
// One rectangle only: the clock's selection box. Drop the Swift-side
// 16-rectangle smooth-union loop entirely.
struct ShaderUniforms {
    float2 resolution;          // viewport pixels
    float  contentsScale;       // [UIScreen mainScreen].scale
    float  cornerRadius;        // pill corner radius (points)
    float4 materialTint;        // RGBA, .a is mix weight
    float  glassThickness;      // simulated thickness in points
    float  refractiveIndex;     // base IoR (~1.5 for borosilicate)
    float  dispersionStrength;  // 0..0.02 -- prism intensity
    float  fresnelDistanceRange;// edge falloff (px)
    float  fresnelIntensity;    // overall Fresnel weight
    float  fresnelEdgeSharpness;// rim hardness
    float4 rectangle;           // x,y,w,h in points (upper-left origin)
};

// ---- Linear-clamp sampler shared by every texture lookup ---------
constant sampler textureSampler(filter::linear,
                                mag_filter::linear,
                                min_filter::linear,
                                address::clamp_to_edge);

// ============================================================
// Vertex shader: hardcoded full-screen quad (triangle strip 0..3)
// ============================================================
vertex VertexOutput fullscreenQuad(uint vertexID [[vertex_id]]) {
    VertexOutput o;
    float2 positions[4] = {
        float2(-1.0f, -1.0f),
        float2( 1.0f, -1.0f),
        float2(-1.0f,  1.0f),
        float2( 1.0f,  1.0f),
    };
    float2 uvs[4] = {
        float2(0.0f, 1.0f),    // BL  - flipped Y because Metal Y is up,
        float2(1.0f, 1.0f),    // BR    UIKit (and our backdrop texture)
        float2(0.0f, 0.0f),    // TL    is Y down, so we feed flipped UVs
        float2(1.0f, 0.0f),    // TR    rather than flipping the texture.
    };
    o.position = float4(positions[vertexID], 0.0f, 1.0f);
    o.uv       = half2(uvs[vertexID]);
    return o;
}

// ============================================================
// SDF: rounded rectangle (no superellipse, plain quarter-circle corners)
// ============================================================
//
// Returns signed distance in PIXELS (>0 outside, <0 inside).
// rect is in points, fragmentCoord in pixels (upper-left origin).
static float roundedRectSDF(float2 fragmentCoord, float4 rect,
                            float cornerRadius, float contentsScale) {
    float2 originPx = rect.xy * contentsScale;
    float2 sizePx   = rect.zw * contentsScale;
    float  rPx      = cornerRadius * contentsScale;

    float2 centerPx = originPx + sizePx * 0.5f;
    float2 p        = fragmentCoord - centerPx;
    float2 halfExt  = sizePx * 0.5f;
    float2 d        = abs(p) - halfExt + rPx;

    // Standard Inigo Quilez rounded-box SDF.
    return min(max(d.x, d.y), 0.0f) + length(max(d, 0.0f)) - rPx;
}

// ============================================================
// Surface normal via central finite differences of SDF.
// 0.0005 epsilon balances accuracy and shader divergence.
// ============================================================
static float2 surfaceNormal(float2 fragPx, float4 rect,
                            float cornerRadius, float contentsScale,
                            float2 resolution) {
    float eps = 0.0005f * resolution.y;     // pixels
    float dx = roundedRectSDF(fragPx + float2(eps, 0.0f), rect, cornerRadius, contentsScale)
             - roundedRectSDF(fragPx - float2(eps, 0.0f), rect, cornerRadius, contentsScale);
    float dy = roundedRectSDF(fragPx + float2(0.0f, eps), rect, cornerRadius, contentsScale)
             - roundedRectSDF(fragPx - float2(0.0f, eps), rect, cornerRadius, contentsScale);
    return normalize(float2(dx, dy));
}

// ============================================================
// Sample background texture with per-channel dispersion.
// Three samples per pixel; small offset makes the prism subtle.
// ============================================================
static half4 sampleWithDispersion(texture2d<half> tex,
                                  float2 baseUv, float2 offset,
                                  float dispersionFactor) {
    half4 c;
    c.r = tex.sample(textureSampler,
        baseUv + offset * (1.0f - (refractiveIndexRed   - 1.0f) * dispersionFactor)).r;
    c.g = tex.sample(textureSampler,
        baseUv + offset * (1.0f - (refractiveIndexGreen - 1.0f) * dispersionFactor)).g;
    c.b = tex.sample(textureSampler,
        baseUv + offset * (1.0f - (refractiveIndexBlue  - 1.0f) * dispersionFactor)).b;
    c.a = 1.0h;
    return c;
}

// ============================================================
// Fragment shader: refraction + dispersion + Fresnel rim + tint.
// ============================================================
fragment half4 liquidGlassEffect(VertexOutput in              [[stage_in]],
                                 constant ShaderUniforms& u   [[buffer(0)]],
                                 texture2d<half> background   [[texture(0)]]) {
    // Where am I in pixel space (upper-left origin)?
    // We use UV.x, (1-UV.y) because we flipped uvs in the vertex
    // shader to match UIKit Y-down coords for the backdrop texture.
    float2 fragPx = float2(in.uv.x, 1.0h - in.uv.y) * u.resolution;

    // SDF of our pill in pixels.
    float dPx = roundedRectSDF(fragPx, u.rectangle,
                               u.cornerRadius, u.contentsScale);

    // Outside the pill -> fully transparent. The MTKView itself sits
    // INSIDE the digit-mask layer applied at the Obj-C side, so this
    // pixel will already be clipped, but we still need to return
    // something so MSL emits a valid fragment.
    if (dPx > 0.0f) {
        return half4(0.0h);
    }

    // How far inside the pill, mapped into the simulated thickness.
    float thicknessPx = u.glassThickness * u.contentsScale;
    float depthRatio  = clamp(1.0f - (-dPx) / thicknessPx, 0.0f, 1.0f);

    // Snell refraction: angle into the glass.
    float incidentAngle    = asin(pow(depthRatio, 2.0f));
    float transmittedAngle = asin(sin(incidentAngle) / u.refractiveIndex);
    float edgeShift        = -tan(transmittedAngle - incidentAngle);
    if (-dPx >= thicknessPx) edgeShift = 0.0f;

    half4 outColor;
    if (edgeShift <= 0.0f) {
        // Deep inside the pill -- no edge refraction. Just blurred
        // wallpaper + tint (caller blurs the texture before binding).
        outColor = background.sample(textureSampler, float2(in.uv.x, 1.0f - in.uv.y));
        outColor = mix(outColor,
                       half4(half3(u.materialTint.rgb), 1.0h),
                       half(u.materialTint.a * 0.8f));
    } else {
        // Inside the rim band -- refraction + dispersion.
        float2 n = surfaceNormal(fragPx, u.rectangle, u.cornerRadius,
                                 u.contentsScale, u.resolution);

        // Aspect-correct UV offset.
        float2 uvOffset = -n * edgeShift * 0.05f * u.contentsScale
                        * float2(u.resolution.y / u.resolution.x, 1.0f);
        half4 refracted = sampleWithDispersion(background,
                                                float2(in.uv.x, 1.0f - in.uv.y),
                                                uvOffset,
                                                u.dispersionStrength);

        // Mix in the material tint (subtle pale cast).
        outColor = mix(refracted,
                       half4(half3(u.materialTint.rgb), 1.0h),
                       half(u.materialTint.a * 0.8f));

        // Fresnel rim: brighten near the edge based on -dPx (depth
        // into pill). The original LCH pipeline boosted L*; we use a
        // straight white add scaled by the same falloff curve.
        float fresnel = clamp(
            pow(1.0f + dPx / 1500.0f
                * pow(500.0f / max(u.fresnelDistanceRange, 1.0f), 2.0f)
                + u.fresnelEdgeSharpness,
                5.0f),
            0.0f, 1.0f);
        outColor = mix(outColor,
                       half4(1.0h, 1.0h, 1.0h, 1.0h),
                       half(fresnel * u.fresnelIntensity * 0.7f));
    }

    // 1px AA along the SDF boundary. dPx is in pixels; the smoothstep
    // band is +-1px so the pill edge alpha-feathers cleanly.
    outColor.a *= 1.0h - half(smoothstep(-1.0f, 0.0f, dPx));

    return outColor;
}
