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

// Horizontal alignment of the clock content (time + date) within the
// overlay. Drives both -textAlignment on the labels and the layer
// anchor point for transform-based stretch, so dragging the resize
// handle scales OUTWARD from the chosen edge:
//   Left  -> scaling pivots on the left edge   (digits grow rightward)
//   Center-> scaling pivots on the centre      (digits grow both sides)
//   Right -> scaling pivots on the right edge  (digits grow leftward)
typedef NS_ENUM(NSInteger, LFClockAlignment) {
    LFClockAlignmentLeft   = 0,
    LFClockAlignmentCenter = 1,
    LFClockAlignmentRight  = 2,
    LFClockAlignmentCount,
};

// What appears in the date "pill" above the clock. iOS 26 calls these
// single-line widgets -- replacements for the date that show one line
// of dynamic text (and an optional small icon). On iOS 15 we don't
// have WidgetKit so the picker is limited to widgets we can compute
// natively without 3rd-party APIs:
//
//   Date        -- "Monday, June 23"  (default, system date format)
//   Battery     -- "85%"  / "Charging 85%"  via UIDevice.batteryLevel
//   DayCounter  -- "Day 174 of 365" via NSCalendar.ordinalityOfUnit
//   CustomText  -- whatever string the user typed in the editor field
//
// Phase 2 will add Weather (OpenWeatherMap key in settings), Calendar
// (EKEventStore next event), Reminders, Astronomy (moon phase, sunrise
// from CLLocation). Each new case appended at the end keeps the int
// values stable.
typedef NS_ENUM(NSInteger, LFDateWidget) {
    LFDateWidgetDate       = 0,  // default -- locale-formatted date string
    LFDateWidgetBattery    = 1,
    LFDateWidgetDayCounter = 2,
    LFDateWidgetCustomText = 3,
    LFDateWidgetCount,
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

// Uniform scale factor. 1.0 == default Apple lock-screen size,
// 2.5 == about half-screen. Driven by the iOS 26 drag-handle in the
// editor when the user drags VERTICALLY (dominant Y axis). Clamped
// to [0.6, 2.8] when written.
@property (nonatomic, assign) CGFloat scale;

// Horizontal stretch factor. 1.0 == natural width, >1.0 == wider
// digits, <1.0 == narrower. iOS 26 separates this from uniform
// scale: dragging the handle to the RIGHT stretches digits by X
// only without changing the font's vertical size. Applied via a
// CGAffineTransform on the time label after recomputeMetrics, so
// it is independent of the font's intrinsic point size. Clamped
// to [0.6, 2.5] -- 2.5x covers most practical needs and makes a
// fully horizontal stretch reach the screen edges on iPhone.
@property (nonatomic, assign) CGFloat horizontalStretch;

// Vertical stretch factor. 1.0 == minimum size (digits inside the
// selection rect with a comfortable side padding), 3.5 == maximum
// (digits almost flush with the left and right edges, much taller
// because the FONT POINT SIZE itself scales -- not a CGAffineTransform
// any more). The clock overlay reads this value and computes the
// font size that makes "00:00" naturally render at the target width
// for the current stretch, so digits scale uniformly width AND
// height. Drag DOWN on the resize handle increases this; drag UP
// at 1.0 does nothing (clamp).
//
// Clamped to [1.0, 3.5]. Old plists with values outside this range
// are migrated up/down at load time.
@property (nonatomic, assign) CGFloat verticalStretch;

// Horizontal alignment of the clock contents (time digits + date
// label). Set by the editor's three small icon buttons (left, centre,
// right). Default Center.
@property (nonatomic, assign) LFClockAlignment alignment;

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

// Which "single-line widget" sits where the date used to sit. Tapping
// the date pill in the editor opens a picker driving this value.
// Default LFDateWidgetDate so existing users see the classic date
// string without doing anything.
@property (nonatomic, assign) LFDateWidget dateWidget;

// User-editable text used when dateWidget == LFDateWidgetCustomText.
// Editor exposes a UITextField writing into this field. Default ""
// (renders empty in custom mode -- the editor pre-fills with a
// suggestion the first time the user enters custom mode).
@property (nonatomic, copy) NSString *dateCustomText;

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
