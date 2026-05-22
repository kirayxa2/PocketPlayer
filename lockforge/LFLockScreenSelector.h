// LFLockScreenSelector - the iOS 16/26 "wallpaper picker" carousel.
//
// Triggered by long-press on the lockscreen, it presents the famous
// horizontally-scrolling carousel of saved lock screens with peek
// previews on either side, page dots, and the Customize / + buttons:
//
//   ┌────────────────────────────────┐
//   │           PHOTOS               │  <- top label
//   │                                │
//   │  ┃   ┌────────────────┐   ┃    │
//   │  ┃   │  Mon June 29   │   ┃    │  <- center: full preview card
//   │  ┃   │     2:22       │   ┃    │
//   │  ┃   │   [snapshot]   │   ┃    │  <- snapshot of cover sheet
//   │  ┃   │                │   ┃    │     content (wallpaper + clock)
//   │  ┃   │   [Focus]      │   ┃    │
//   │  ┃   └────────────────┘   ┃    │
//   │       •  •  •  •  •            │  <- page dots
//   │                                │
//   │  [Customize]            [+]    │  <- bottom action bar
//   └────────────────────────────────┘
//
// Multi-lockscreen carousel:
//   * Scroll between cards; the snap delegate calls
//     LFLockScreenLibrary.setActiveId on the centred card so the live
//     lock-screen behind us swaps to that screen's wallpaper +
//     settings as the user scrolls.
//   * Customize tap -> ask delegate to spawn the editor on the active
//     (centred) screen.
//   * + tap -> UIImagePickerController, picked image becomes a new
//     lock-screen via library.addLockScreenWithWallpaperImage.
//   * Swipe-up on a card -> remove that lock-screen (library enforces
//     a minimum of 1).
//   * Swipe-down anywhere -> dismiss back to lockscreen.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class LFClockOverlay;
@class LFLockScreenSelector;

// Delegate -- the tweak's gesture target conforms to this so we know
// when the user wants the editor or has dismissed.
@protocol LFLockScreenSelectorDelegate <NSObject>
- (void)selectorDidRequestEditor:(LFLockScreenSelector *)selector;
- (void)selectorDidDismiss:(LFLockScreenSelector *)selector;
@end

@interface LFLockScreenSelector : UIViewController

@property (nonatomic, weak) id<LFLockScreenSelectorDelegate> delegate;

// `coverSheetView` is the view we'll snapshot to populate each card's
// preview. `clockOverlay` is captured so the editor that opens after
// Customize can be wired up correctly (selector itself doesn't touch
// the live clock).
- (instancetype)initWithCoverSheetView:(UIView *)coverSheetView
                          clockOverlay:(LFClockOverlay *)overlay;

// Add the selector's view to `window` and animate in.
- (void)presentInWindow:(UIWindow *)window;

@end

NS_ASSUME_NONNULL_END
