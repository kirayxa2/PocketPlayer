// LFLockEditor - the iOS 16/26 customization overlay.
//
// Triggered by a long-press on the lockscreen (LFTweak hooks the
// gesture and calls -presentInWindow:). The editor takes over the
// whole window:
//
//   ┌─────────────────────────────────┐
//   │  [Cancel]              [Done]   │  <- top bar
//   │                                 │
//   │      <wallpaper as-is>          │
//   │                                 │
//   │      <CLOCK becomes editable>   │  <- LFClockOverlay.isEditing=YES
//   │                                 │
//   │  (notifications dimmed below)   │
//   │                                 │
//   ├─────────────────────────────────┤
//   │  [Aa]  [Aa]  [Aa]  [Aa]  ...    │  <- font picker scroll row
//   │  ●  ●  ●  ●  ●  ●  ●  ●         │  <- color dots
//   │  Glass: [-----o-----] (0..3)    │  <- liquid glass slider
//   └─────────────────────────────────┘
//
// While editing:
//   - Tap a font dot -> live preview, settings updated immediately
//   - Tap a color dot -> ditto
//   - Drag the resize handle on the clock -> live scale
//   - Drag clock body -> live position
//   - Slider -> live glass intensity
//   - Cancel -> revert to previous settings (we snapshot them on enter)
//   - Done -> persist current settings, dismiss

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class LFClockOverlay;

@interface LFLockEditor : UIViewController

- (instancetype)initWithClockOverlay:(LFClockOverlay *)clockOverlay;

// Present the editor inside the cover-sheet window. Adds a full-screen
// dimming layer above the original wallpaper so the editor UI reads.
- (void)presentInWindow:(UIWindow *)window;

@end

NS_ASSUME_NONNULL_END
