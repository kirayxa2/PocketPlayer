// LFLiquidGlassMetalView -- Metal-driven backend for LFLiquidGlassView.
//
// Wraps an MTKView and a Metal pipeline built from
// LiquidGlassShaders.metallib (compiled by .github/workflows/
// compile-metal.yml on each push that touches LiquidGlass.metal).
//
// Public surface mirrors the bits of LFLiquidGlassView the rest of
// the tweak actually drives: corner radius, intensity, tint color,
// gyro shimmer offset. LFLiquidGlassView creates one of these
// internally when Metal is available, and falls back to its old
// UIVisualEffectView pipeline when:
//   - the Metal device cannot be created (extremely rare on iOS 15
//     iPhone 6s, but defensive: e.g. the metallib didn't bundle)
//   - the metallib file isn't present on disk (CI hasn't run yet)
//
// All the heavy lifting -- backdrop capture, uniform buffering,
// per-frame rendering -- lives here. The fragment shader is in
// LiquidGlass.metal; this file just feeds it textures and uniforms.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface LFLiquidGlassMetalView : UIView

// Test that Metal is available AND the shader library was packaged.
// Done lazily; failure caches NO for the lifetime of the process so
// LFLiquidGlassView falls through to the UIVisualEffectView path
// without re-trying every initWithFrame:.
+ (BOOL)isAvailable;

// Public knobs -- mirror the ones on LFLiquidGlassView so the
// frontend can forward setters verbatim.
@property (nonatomic, assign) NSInteger intensity;          // 0..3
@property (nonatomic, strong) UIColor   *tintColor;
@property (nonatomic, assign) CGFloat   glassCornerRadius;

// Gyro shimmer offset in [-1, +1] per axis. Cheap to update -- just
// adjusts a uniform-buffer value; doesn't trigger redraw on its own
// because the view is already drawing each frame.
- (void)setShimmerOffset:(CGPoint)offset;

@end

NS_ASSUME_NONNULL_END
