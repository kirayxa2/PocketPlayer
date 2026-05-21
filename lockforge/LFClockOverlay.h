// LFClockOverlay - the visible clock that replaces SBFLockScreenDateView.
//
// Layout:
//
//   ┌─────────────────────────────────┐
//   │       <date label, smaller>     │
//   │                                 │
//   │       1   2   :   3   4         │  <- digit label, the big one
//   │                                 │
//   │                            (◯)  │  <- iOS 26 drag-resize handle,
//   └─────────────────────────────────┘     visible only in editor mode
//
// In editor mode (LFLockEditor sets isEditing=YES):
//   - drag-resize handle appears
//   - whole view is draggable to reposition
//   - drag-handle drag scales the digits live (matches iOS 26 exactly)
//
// In normal mode:
//   - just the date + time, no decorations
//   - tick once a second to update the time
//   - re-evaluates adaptive color when wallpaper changes

#import <UIKit/UIKit.h>

@class LFLiquidGlassView;

NS_ASSUME_NONNULL_BEGIN

@interface LFClockOverlay : UIView

// When YES, the resize handle is visible and the user can drag the
// clock around. Set by LFLockEditor when entering / leaving customize
// mode.
@property (nonatomic, assign) BOOL isEditing;

// The Liquid Glass background sits BEHIND the labels. Visible iff
// LFClockSettings.liquidGlassIntensity > 0.
@property (nonatomic, strong, readonly) LFLiquidGlassView *glassBackground;

// Force a re-render. Called when settings change (font/color/etc) or
// when the wallpaper changes (so adaptive color can re-evaluate).
- (void)refreshFromSettings;

// Sample the wallpaper region under the clock and feed luminance into
// adaptive color logic. Called periodically by the editor / display
// link in the main tweak. Pass nil image to use a default white.
- (void)applyAdaptiveColorWithBackgroundImage:(nullable UIImage *)bgImage;

@end

NS_ASSUME_NONNULL_END
