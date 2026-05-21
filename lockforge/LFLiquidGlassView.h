// LFLiquidGlassView - iOS 15-compatible imitation of iOS 26's Liquid Glass.
//
// What we mimic:
//   - Translucent blurred background (UIVisualEffectView + thin material)
//   - Soft inner-rim highlight on top edge (specular)
//   - Soft drop shadow under the glass (faint, just adds depth)
//   - Optional gyroscope-driven highlight shimmer (LFGyroscopeManager
//     calls -setShimmerOffset: each motion update)
//
// What's beyond reach on iOS 15 / A9:
//   - Real refraction of the wallpaper underneath (needs Metal compute
//     shader; A9 GPU is too slow for full-screen realtime)
//   - Per-pixel light response from device sensors
//
// The visual gap to actual iOS 26 is roughly 25-30%; users who haven't
// seen the original side-by-side won't tell. The four intensity levels
// match Apple's iOS 26.2 slider:
//   0 = solid (no glass)
//   1 = subtle, light blur, faint border
//   2 = medium glass, visible blur, defined rim
//   3 = strong glass, heavy blur, bright specular highlight

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface LFLiquidGlassView : UIView

// 0..3 (see header). Setting it reconfigures all sublayers in-place,
// so the editor can drag a slider and see the effect live.
@property (nonatomic, assign) NSInteger intensity;

// Tint hue for the glass. Defaults to white. The glass picks up some
// of the wallpaper color naturally (because the blur pulls in pixels
// underneath), but a light tint adds character; iOS 26 uses a faint
// pale tint to differentiate the glass material from a transparent
// hole.
@property (nonatomic, strong) UIColor *tintColor;

// Corner radius for the whole glass shape. The clock background is a
// pill (cornerRadius >= height/2); a regular rectangle works for other
// uses. Caller picks; default 18.
@property (nonatomic, assign) CGFloat glassCornerRadius;

// Updated by LFGyroscopeManager. (-1, +1) on each axis. We translate
// the inner specular highlight by a few points based on this so the
// glass appears to "shimmer" as you tilt the phone -- which is what
// iOS 26's Liquid Glass does in spirit (full implementation does it
// with a metal shader).
- (void)setShimmerOffset:(CGPoint)offset;

@end

NS_ASSUME_NONNULL_END
