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
// On Customize tap -> ask delegate to spawn the editor.
// On + tap -> (PR-A) shows "Coming soon" alert. PR-B will add the
// new-lockscreen flow.
// On swipe-down -> dismiss back to lockscreen.
//
// PR-A only has 1 card (matches the single saved lockscreen we keep).
// Page dots, peek of side cards, and scroll snap are still implemented
// so the UI looks right; PR-B will fill in additional cards.

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
