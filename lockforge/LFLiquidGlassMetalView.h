// LFLiquidGlassMetalView -- Metal renderer driving the LiquidGlassKit shader.
//
// This file is the Obj-C side of a HOST/SHADER split:
//
//   * Shader (lockforge/LiquidGlassKit/LiquidGlass{Vertex,Fragment}.metal)
//     -- byte-for-byte copy of Alexey Demin's LiquidGlassKit. MD5-verified
//     against the upstream repo. NEVER modified locally; the visual look
//     of the glass is fully owned by these two files.
//
//   * Host (this class + LFLiquidGlassMetalView.m)
//     -- mirrors LiquidGlassKit's LiquidGlassView.swift line-for-line in
//     terms of uniform-buffer layout, the .regular preset values, the
//     CABackdropLayer capture path, and the MPSImageGaussianBlur post-
//     blur. We use Obj-C instead of bundling the upstream Swift module
//     because Theos+Swift in a JB tweak is fragile (Swift 6.2 import
//     syntax, Bundle.module, dyld loader interaction) -- but every
//     constant and every API call here is the SAME as the Swift code,
//     so the rendered output is identical.
//
// The compiled metallib (LiquidGlassShaders.metallib) is built by
// .github/workflows/compile-metal.yml on a macOS runner and dropped
// into lockforge/layout/Library/LockForge/ where Theos packages it
// into the .deb automatically. We load it at runtime via
// -[MTLDevice newLibraryWithFile:].

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface LFLiquidGlassMetalView : UIView

// Returns YES iff a Metal device exists AND the bundled metallib loads.
// LFLiquidGlassView checks this once and decides whether to instantiate
// us or fall back to the legacy UIVisualEffectView path.
+ (BOOL)isAvailable;

// Public knobs forwarded from LFLiquidGlassView.
//
// `intensity`: 0..3. 0 hides the view entirely (Solid mode); 1..3 picks
// progressively more visible glass strength via the .regular preset
// scaled with these multipliers (matches the legacy UIVisualEffectView
// behaviour so existing user plists keep working).
@property (nonatomic, assign) NSInteger intensity;
@property (nonatomic, strong) UIColor   *tintColor;
@property (nonatomic, assign) CGFloat   glassCornerRadius;

// Gyro shimmer offset in [-1, +1] per axis; we feed it into the
// shader's touchPoint uniform so the glare/Fresnel terms shift with
// device tilt, matching the LiquidGlassKit demo widgets.
- (void)setShimmerOffset:(CGPoint)offset;

@end

NS_ASSUME_NONNULL_END
