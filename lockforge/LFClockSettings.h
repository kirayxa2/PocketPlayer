// LFClockSettings - persisted clock/lock-screen customization state.
//
// Single source of truth for: font choice, color choice, scale (drag-resize
// handle in iOS 26), explicit position offset, Liquid Glass intensity,
// adaptive-color toggle. Read by LFClockOverlay every render frame, written
// by LFLockEditor when the user finishes editing.
//
// Backed by /var/mobile/Library/LockForge/clock.plist so settings persist
// across SpringBoard respawns and tweak reloads.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Built-in clock font presets that the editor offers in a horizontal
// scroll-row. Numeric values are STABLE across versions -- the plist
// stores the int, so don't reorder existing cases (only append).
typedef NS_ENUM(NSInteger, LFClockFont) {
    LFClockFontSystemThin     = 0,  // SF Pro thin (default-ish)
    LFClockFontSystemBold     = 1,  // SF Pro bold
    LFClockFontRoundedHeavy   = 2,  // SF Pro Rounded heavy (iOS 16/26 default look)
    LFClockFontSerif          = 3,  // New York
    LFClockFontMonospace      = 4,  // SF Mono semibold
    LFClockFontCondensedBold  = 5,  // SF Compact condensed (iOS 26 second style)
    LFClockFontUltraThin      = 6,  // ultralight, very iOS 26 minimalist
    LFClockFontCount,               // sentinel
};

// Color choices: 6 presets + custom (UIColor stored as RGBA in plist).
// `Adaptive` reads the wallpaper luminance under the clock and picks
// white or black for legibility (iOS 26 "adaptive time").
typedef NS_ENUM(NSInteger, LFClockColorMode) {
    LFClockColorAdaptive = 0,  // luminance of wallpaper -> white or black
    LFClockColorWhite    = 1,
    LFClockColorBlack    = 2,
    LFClockColorRed      = 3,
    LFClockColorBlue     = 4,
    LFClockColorYellow   = 5,
    LFClockColorPink     = 6,
    LFClockColorCustom   = 7,  // freeform; reads customColorRGBA
    LFClockColorModeCount,
};

@interface LFClockSettings : NSObject

+ (instancetype)shared;

// Whether LockForge actively replaces the system date/time view. When
// NO, the original lockscreen is shown. Default YES.
@property (nonatomic, assign) BOOL enabled;

// Currently chosen font preset.
@property (nonatomic, assign) LFClockFont font;

// Color mode + custom color value (only used when colorMode==Custom).
// CustomColor packed as 4 floats 0..1 [r, g, b, a].
@property (nonatomic, assign) LFClockColorMode colorMode;
@property (nonatomic, copy)   NSArray<NSNumber *> *customColorRGBA;

// Scale factor, 1.0 == default Apple lock-screen size, 2.5 == about
// half-screen. Driven by the iOS 26 drag-handle in the editor.
// Clamped to [0.6, 2.8] when written.
@property (nonatomic, assign) CGFloat scale;

// Explicit position offset for the clock, in points relative to the
// default centered-top position. Editor lets user drag clock around;
// stored as offset so the default still works on rotation/different
// screen sizes.
@property (nonatomic, assign) CGPoint positionOffset;

// Liquid Glass tier. 0 = off (flat color), 1 = light glass, 2 = full
// translucent glass with specular highlight (iOS 26.2 style). Default 0
// so installs with no editor interaction look like classic iOS 15.
@property (nonatomic, assign) NSInteger liquidGlassIntensity;

// Whether to apply gyroscope-based shimmer to glass and parallax to
// multi-layer wallpapers. Default YES, but cheap to disable for
// battery-conscious users.
@property (nonatomic, assign) BOOL gyroEffectsEnabled;

// Resolves the current settings to a concrete UIFont at the requested
// reference height (in points). Used by LFClockOverlay each render.
- (UIFont *)resolvedFontForReferenceSize:(CGFloat)refSize;

// Resolves color. Pass `nil` luminance to skip adaptive logic and use
// the literal preset; pass a sample to enable adaptive color picking.
- (UIColor *)resolvedColorForBackgroundLuminance:(nullable NSNumber *)luminance;

// Persistence. Both are best-effort; if the file system is read-only
// (rare on rootless) settings stay in-memory only.
- (void)save;
- (void)load;

@end

NS_ASSUME_NONNULL_END
