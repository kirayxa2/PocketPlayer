// LockForge — iOS 16/26-style lock screen editor for jailbroken iOS 15.
//
// Three responsibilities:
//
//   1. Hide the system's date/time view (SBFLockScreenDateView /
//      _MTLumaDeterminationImageView) so it doesn't double up with
//      ours.
//
//   2. Install our LFClockOverlay (with optional Liquid Glass
//      background and resize handle) into the cover-sheet view.
//
//   3. Add a UILongPressGestureRecognizer to the cover-sheet view.
//      On long press -> present LFLockEditor, which shows the font
//      picker / color picker / glass slider and lets the user drag
//      the clock around / resize it.
//
// The tweak DOES NOT TOUCH the wallpaper -- that's PocketPlayer's job.
// Both tweaks load into SpringBoard, but they hook different views,
// so they coexist cleanly.

#import <UIKit/UIKit.h>
#import "LFClockSettings.h"
#import "LFClockOverlay.h"
#import "LFLockEditor.h"

// =====================================================================
// Globals
// =====================================================================

static __weak UIView          *gCoverSheetView;
static LFClockOverlay         *gClockOverlay;
static LFLockEditor           *gEditor;
static UILongPressGestureRecognizer *gLongPress;
static BOOL                    gSystemDateHidden = NO;

// =====================================================================
// Forward decls of private classes we hook.
// =====================================================================

@interface CSCoverSheetView : UIView
@end

// =====================================================================
// Helpers
// =====================================================================

// Walks the cover-sheet view's subviews looking for the system clock
// (SBFLockScreenDateView is the iOS 15 class; _MTLumaDeterminationImageView
// is the older / private one used by the digital clock area). Hides
// every match. Run again on a timer (slow throttle) because Springboard
// occasionally re-shows the original on first lock or after a focus
// change.
static void LFHideSystemDateViewsIn(UIView *root) {
    if (!root) return;
    NSString *cls = NSStringFromClass([root class]);
    if (cls && ([cls containsString:@"LockScreenDateView"] ||
                [cls containsString:@"DateSubtitleDateView"] ||
                [cls containsString:@"LSLockTimeView"]      ||
                [cls containsString:@"DateView"]            ||
                [cls containsString:@"_MTLumaDeterminationImageView"])) {
        // Tag check: don't hide our own LFClockOverlay subviews.
        if (![root isKindOfClass:[LFClockOverlay class]] &&
             root.tag != 0xC10C) {
            root.hidden = YES;
        }
    }
    for (UIView *v in root.subviews) {
        LFHideSystemDateViewsIn(v);
    }
}

// Install (or re-install) the LFClockOverlay into a host view. Idempotent
// -- if already attached, it just re-syncs settings.
static void LFInstallClockIntoCoverSheet(UIView *coverSheetView) {
    if (!coverSheetView) return;
    if (![[LFClockSettings shared] enabled]) return;

    if (gClockOverlay && gClockOverlay.superview == coverSheetView) {
        [gClockOverlay refreshFromSettings];
        return;
    }
    [gClockOverlay removeFromSuperview];

    gClockOverlay = [[LFClockOverlay alloc] initWithFrame:CGRectZero];
    gClockOverlay.tag = 0xC10C;        // identifier for our hide-walk
    [coverSheetView addSubview:gClockOverlay];
    [gClockOverlay refreshFromSettings];
}

// Reads the current cover-sheet wallpaper as a UIImage so the clock can
// adapt its color. We use UIView -drawViewHierarchyInRect: on a small
// canvas (1/4 native size) -- reasonably cheap, runs on a timer once
// every few seconds, only when needed.
static void LFRefreshAdaptiveColor(UIView *coverSheetView) {
    if (!gClockOverlay) return;
    if ([LFClockSettings shared].colorMode != LFClockColorAdaptive) return;
    if (!coverSheetView.window) return;

    CGSize size = CGSizeMake(coverSheetView.bounds.size.width / 4.0,
                             coverSheetView.bounds.size.height / 4.0);
    if (size.width < 4 || size.height < 4) return;

    UIGraphicsBeginImageContextWithOptions(size, NO, 1);
    [coverSheetView drawViewHierarchyInRect:CGRectMake(0, 0, size.width, size.height)
                          afterScreenUpdates:NO];
    UIImage *snap = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    [gClockOverlay applyAdaptiveColorWithBackgroundImage:snap];
}

// =====================================================================
// Long-press gesture -> editor.
// =====================================================================

@interface LFGestureTarget : NSObject
+ (instancetype)shared;
- (void)handleLongPress:(UILongPressGestureRecognizer *)g;
@end

@implementation LFGestureTarget
+ (instancetype)shared {
    static LFGestureTarget *t;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ t = [LFGestureTarget new]; });
    return t;
}
- (void)handleLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    if (gEditor) return;       // already showing
    if (!gClockOverlay)  return;
    UIWindow *win = gCoverSheetView.window;
    if (!win) return;

    gEditor = [[LFLockEditor alloc] initWithClockOverlay:gClockOverlay];
    [gEditor presentInWindow:win];

    // Auto-clear our reference when the editor's view is gone, so
    // next long-press creates a fresh one.
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIWindowDidBecomeHiddenNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *n) {
            if (!gEditor.view.superview) gEditor = nil;
        }];
    });
}
@end

// =====================================================================
// Hooks
// =====================================================================

%hook CSCoverSheetView

- (void)didMoveToWindow {
    %orig;
    if (self.window == nil) return;
    gCoverSheetView = self;
    LFHideSystemDateViewsIn(self);
    LFInstallClockIntoCoverSheet(self);

    // Long-press recognizer: 0.6s minimum -- matches iOS 16/26's
    // "long press to customize" feel. Fail-on-touch-move is YES so
    // a normal swipe-to-unlock still works.
    if (!gLongPress) {
        gLongPress = [[UILongPressGestureRecognizer alloc]
            initWithTarget:[LFGestureTarget shared]
                    action:@selector(handleLongPress:)];
        gLongPress.minimumPressDuration = 0.6;
        gLongPress.allowableMovement    = 12;
        gLongPress.cancelsTouchesInView = NO; // let other gestures through
        [self addGestureRecognizer:gLongPress];
    }
}

- (void)layoutSubviews {
    %orig;
    LFHideSystemDateViewsIn(self);
    LFInstallClockIntoCoverSheet(self);
    LFRefreshAdaptiveColor(self);
}

%end

// =====================================================================
// %ctor
// =====================================================================

%ctor {
    @autoreleasepool {
        NSString *exe = [[[NSBundle mainBundle] executablePath] lastPathComponent];
        if (![exe isEqualToString:@"SpringBoard"]) return;

        // Touch the singleton so settings load early. Defaults are
        // applied if no plist exists yet.
        (void)[LFClockSettings shared];

        %init;
    }
}
