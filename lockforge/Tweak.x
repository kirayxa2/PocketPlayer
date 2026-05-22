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
#import <CoreText/CoreText.h>
#import "LFClockSettings.h"
#import "LFClockOverlay.h"
#import "LFLockEditor.h"
#import "LFLockScreenSelector.h"
#import "LFLockScreenLibrary.h"
#import "LFLockScreenWallpaperView.h"

// =====================================================================
// Bundled iOS 26 Adaptive Time numeric font
// =====================================================================
//
// ADTNumeric.ttc ships in the LockForge .deb at /var/jb/Library/LockForge/
// (rootless) or /Library/LockForge/ (rootful fallback). It is the system
// font Apple uses on the iOS 26 lock screen for the "Adaptive Time"
// clock -- a TrueType Collection containing 13 numeric font faces
// (Slab, NewYork, Compact Soft, Rail, Rounded, Stencil, ...) plus the
// star face we drive from LFClockOverlay:
//
//     PostScript name:  .SFAdaptiveNumeric-Regular
//     Variation axes:
//       'HGHT'   100 .. 500  (HEIGHT axis -- glyph height scaling
//                             that does NOT change advance width or
//                             stroke thickness; this is the literal
//                             axis Apple drags via the resize handle
//                             on iOS 26 and is unique to this font)
//       'wdth'    60 .. 100
//       'wght'     1 .. 1000
//       'GRAD'   400 .. 1000  (hidden grade axis)
//
// Registering the .ttc once at %ctor time registers EVERY face inside
// it for the SpringBoard process; subsequent CTFontDescriptor lookups
// by ".SFAdaptiveNumeric-Regular" find our font and use its full set
// of variation axes (most importantly HGHT, which is the missing
// piece that makes the resize feel exactly like iOS 26 -- digits
// grow taller without growing thicker or wider).

static void LFRegisterBundledNumericFont(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Try rootless path first (matches THEOS_PACKAGE_SCHEME = rootless),
        // fall back to rootful if for any reason the install layout is
        // different.
        NSArray<NSString *> *candidates = @[
            @"/var/jb/Library/LockForge/ADTNumeric.ttc",
            @"/Library/LockForge/ADTNumeric.ttc",
        ];
        for (NSString *path in candidates) {
            if (![[NSFileManager defaultManager] fileExistsAtPath:path]) continue;
            NSURL *url = [NSURL fileURLWithPath:path];
            CFErrorRef err = NULL;
            BOOL ok = CTFontManagerRegisterFontsForURL(
                (__bridge CFURLRef)url,
                kCTFontManagerScopeProcess,
                &err);
            if (ok) {
                NSLog(@"[LockForge] Registered ADTNumeric.ttc (13 faces incl. "
                      @".SFAdaptiveNumeric-Regular) from %@", path);
            } else {
                NSError *nsErr = (__bridge_transfer NSError *)err;
                // 105 == kCTFontManagerErrorAlreadyRegistered, harmless.
                if (nsErr.code != 105) {
                    NSLog(@"[LockForge] ADTNumeric.ttc register FAILED for %@: %@",
                          path, nsErr);
                }
            }
            return;  // first existing candidate wins
        }
        NSLog(@"[LockForge] ADTNumeric.ttc NOT FOUND -- clock will fall back "
              @"to system font (HGHT axis unavailable, resize feel degraded). "
              @"Expected at /var/jb/Library/LockForge/ADTNumeric.ttc");
    });
}

// =====================================================================
// Globals
// =====================================================================

static __weak UIView          *gCoverSheetView;
static LFClockOverlay         *gClockOverlay;
static LFLockEditor           *gEditor;
// Carousel selector that opens FIRST on long-press, then lets the user
// pick "Customize" to drop into the editor (gEditor). This mirrors
// Apple's iOS 16/26 flow exactly: long-press -> wallpaper picker
// carousel -> Customize -> editor.
static LFLockScreenSelector   *gSelector;
// Custom-wallpaper overlay -- a UIImageView at the bottom of the cover
// sheet that draws the active lock-screen's saved wallpaper above the
// system's stock wallpaper. Listens to LFActiveLockScreenChanged-
// Notification and re-reads from LFLockScreenLibrary on its own.
static LFLockScreenWallpaperView *gWallpaperOverlay;
static UILongPressGestureRecognizer *gLongPress;

// Tracks whether we've already done the (heavy-ish) install pass for
// the current cover-sheet view. We flip it to NO when the cover sheet
// remounts. Using this guard, layoutSubviews becomes essentially a
// no-op after the first install -- we don't keep re-creating overlays
// or hide-walking the entire view tree dozens of times per second.
static BOOL                    gInstalledForCurrentMount = NO;

// Adaptive-color sampling is comparatively expensive (drawViewHierarchy
// + 1x1 pixel read). Throttle to once every 3 seconds; the wallpaper
// doesn't change faster than that for our purposes.
static CFTimeInterval          gLastAdaptiveSample = 0;

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

// Install (or re-install) the LFLockScreenWallpaperView at the BOTTOM
// of the cover-sheet view. We want it BELOW the clock overlay (and any
// other LockForge subviews) but ABOVE the system wallpaper -- the
// cover-sheet view itself is a sibling of the wallpaper window, so any
// subview we add covers the wallpaper underneath. Adding via
// `insertSubview:atIndex:0` keeps it as the first visible layer in the
// cover-sheet hierarchy so SBFLockScreen's date / clock / widget views
// (when not hidden) still draw on top.
static void LFInstallWallpaperOverlay(UIView *coverSheetView) {
    if (!coverSheetView) return;
    if (gWallpaperOverlay && gWallpaperOverlay.superview == coverSheetView) {
        [gWallpaperOverlay refresh];
        return;
    }
    [gWallpaperOverlay removeFromSuperview];

    gWallpaperOverlay = [[LFLockScreenWallpaperView alloc]
                          initWithFrame:coverSheetView.bounds];
    gWallpaperOverlay.tag = 0xC10D;
    [coverSheetView insertSubview:gWallpaperOverlay atIndex:0];
}

// Reads the current cover-sheet wallpaper as a UIImage so the clock can
// adapt its color. Throttled (gLastAdaptiveSample) so it doesn't fire
// every layout pass; expensive on A9.
static void LFRefreshAdaptiveColor(UIView *coverSheetView) {
    if (!gClockOverlay) return;
    if ([LFClockSettings shared].colorMode != LFClockColorAdaptive) return;
    if (!coverSheetView.window) return;

    CFTimeInterval now = CACurrentMediaTime();
    if (now - gLastAdaptiveSample < 3.0) return;
    gLastAdaptiveSample = now;

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
// Long-press gesture target / editor lifecycle
// =====================================================================

@interface LFGestureTarget : NSObject <LFLockEditorDelegate, LFLockScreenSelectorDelegate>
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
    if (gSelector || gEditor) return;       // a chrome panel is already up
    if (!gClockOverlay) return;
    UIWindow *win = gCoverSheetView.window;
    if (!win) return;

    // iOS 16/26 flow: long-press goes to the carousel selector first,
    // not the editor. Editor is reachable via the "Customize" button
    // INSIDE the selector. Behaves identically to Apple.
    gSelector = [[LFLockScreenSelector alloc]
        initWithCoverSheetView:gCoverSheetView
                  clockOverlay:gClockOverlay];
    gSelector.delegate = self;
    [gSelector presentInWindow:win];
}

#pragma mark - LFLockScreenSelectorDelegate

// User tapped "Customize" on the selector. The selector animates out
// in parallel; we kick off the editor presentation right away so the
// transition feels instant (matches iOS 26).
- (void)selectorDidRequestEditor:(LFLockScreenSelector *)selector {
    if (gSelector == selector) {
        gSelector = nil;        // selector is animating out, free the slot
    }
    if (gEditor) return;        // shouldn't happen but be safe
    UIWindow *win = gCoverSheetView.window;
    if (!win || !gClockOverlay) return;

    gEditor = [[LFLockEditor alloc] initWithClockOverlay:gClockOverlay];
    gEditor.delegate = self;
    [gEditor presentInWindow:win];
}

// User dismissed the selector without picking Customize (swipe-down,
// etc). Just clean the slot so the next long-press can spawn fresh.
- (void)selectorDidDismiss:(LFLockScreenSelector *)selector {
    if (gSelector == selector) {
        gSelector = nil;
    }
}

#pragma mark - LFLockEditorDelegate

// Editor finished animating out -- we're free to start a new one on
// the next long-press.
- (void)lockEditorDidDismiss:(LFLockEditor *)editor {
    if (gEditor == editor) {
        gEditor = nil;
    }
}

@end

// =====================================================================
// Hooks
// =====================================================================

%hook CSCoverSheetView

- (void)didMoveToWindow {
    %orig;
    if (self.window == nil) {
        // Cover sheet was removed -- forget our install so the next
        // mount re-attaches a fresh overlay rather than dangling.
        gInstalledForCurrentMount = NO;
        return;
    }
    gCoverSheetView = self;
    LFHideSystemDateViewsIn(self);
    LFInstallWallpaperOverlay(self);
    LFInstallClockIntoCoverSheet(self);
    gInstalledForCurrentMount = YES;

    // Long-press recognizer: 0.6s minimum -- matches iOS 16/26's
    // "long press to customize" feel. cancelsTouchesInView=NO so a
    // normal swipe-to-unlock still works, and minimumPressDuration is
    // safely longer than swipe-trigger so they don't interfere.
    if (!gLongPress) {
        gLongPress = [[UILongPressGestureRecognizer alloc]
            initWithTarget:[LFGestureTarget shared]
                    action:@selector(handleLongPress:)];
        gLongPress.minimumPressDuration = 0.6;
        gLongPress.allowableMovement    = 12;
        gLongPress.cancelsTouchesInView = NO;
        [self addGestureRecognizer:gLongPress];
    }
}

- (void)layoutSubviews {
    %orig;
    // Cheap path: only reinstall if we lost our overlay. Repeated
    // layoutSubviews fire dozens of times per second and the previous
    // version did unconditional install + adaptive sample on each
    // call, which murdered scroll perf and (worse) competed with
    // the user's drag gesture.
    //
    // Important: while the editor is presented, gClockOverlay's
    // superview is the editor's view (we re-parent for hit-test
    // reasons), NOT this CSCoverSheetView. We must NOT rebuild a new
    // clock in that case -- the editor already owns the live one.
    BOOL editorOwnsClock = (gEditor != nil);
    if (!editorOwnsClock &&
        (!gInstalledForCurrentMount || gClockOverlay.superview != self)) {
        LFHideSystemDateViewsIn(self);
        LFInstallWallpaperOverlay(self);
        LFInstallClockIntoCoverSheet(self);
        gInstalledForCurrentMount = YES;
    }
    LFRefreshAdaptiveColor(self);   // throttled to 3s internally
}

%end

// Bridge between LFLockScreenLibrary's active-changed notification and
// the live clock overlay. When the user swipes between cards in the
// selector, the library updates LFClockSettings.shared with the new
// active screen's values; this observer kicks the clock overlay to
// re-render with the new font / colour / widgets.
@interface LFActiveScreenObserver : NSObject
+ (instancetype)shared;
@end

@implementation LFActiveScreenObserver
+ (instancetype)shared {
    static LFActiveScreenObserver *o;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        o = [LFActiveScreenObserver new];
        [[NSNotificationCenter defaultCenter]
            addObserver:o
               selector:@selector(onActiveChanged:)
                   name:LFActiveLockScreenChangedNotification
                 object:nil];
    });
    return o;
}
- (void)onActiveChanged:(NSNotification *)n {
    if (gClockOverlay) [gClockOverlay refreshFromSettings];
    if (gWallpaperOverlay) [gWallpaperOverlay refresh];
}
@end

// =====================================================================
// %ctor
// =====================================================================

%ctor {
    @autoreleasepool {
        NSString *exe = [[[NSBundle mainBundle] executablePath] lastPathComponent];
        if (![exe isEqualToString:@"SpringBoard"]) return;

        // Register the bundled iOS 26 Adaptive-Time numeric font into
        // this process before anyone tries to render a clock label --
        // LFClockOverlay reads it by PostScript name during its very
        // first recomputeMetrics.
        LFRegisterBundledNumericFont();

        // Touch the singleton so settings load early. Defaults are
        // applied if no plist exists yet.
        (void)[LFClockSettings shared];

        // THEN initialise the library, which mirrors the active
        // lock-screen's saved values onto LFClockSettings.shared via
        // its setters. Order matters: the library re-enters
        // [LFClockSettings shared] inside its loadFromDisk, so the
        // settings dispatch_once has to be done first.
        (void)[LFLockScreenLibrary shared];

        // Wire up the active-changed observer so swipes in the
        // selector immediately refresh the live clock + wallpaper.
        (void)[LFActiveScreenObserver shared];

        %init;
    }
}
