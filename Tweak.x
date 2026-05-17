// PocketPlayer — animated lockscreen wallpapers (.ca bundles) for iOS 15.
//
// Architecture:
//
//   [SBCoverSheetWindow]                    <- never moves; we host on its layer
//     └── PocketPlayerLayer (zPos=-1)       <- our CAML root
//     └── CSCoverSheetView (slides up)      <- progress source
//
// Why we host on the *window*, not on SBFWallpaperView:
//   On iOS 15 the wallpaper view either clips its content (masksToBounds)
//   or its ancestors animate bounds.origin during unlock, both of which
//   defeat a child CALayer counter-translate. The cover sheet window
//   itself, however, is the true root of the lock-screen presentation
//   and does not move. So if we attach our poster to the window's
//   layer at zPosition=-1, it sits behind the (sliding) cover-sheet view
//   while staying glued to screen coordinates.
//
// Progress is fed from whichever of these gets called first:
//   1) CSCoverSheetViewController _updatePresentationProgress:withOffset:presentationState:
//   2) SBCoverSheetSlidingViewController <same selector>
//   3) SBDashBoardViewController <same selector>   (older private name)
//   4) Fallback: CADisplayLink reading the cover-sheet view's window-space y.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <notify.h>
#import "CAMLParser.h"

// =====================================================================
// Configuration
// =====================================================================

static NSString *const kPPWallpaperRoot =
    @"/var/mobile/Library/PosterPlayer/active/versions/1/contents";

static BOOL const kPPDebugLabel = YES;

// =====================================================================
// State
// =====================================================================

static UILabel        *gDebugLabel;
static PPCAMLDocument *gDoc;
static CALayer        *gPosterLayer;     // our container CALayer (in window.layer)
static __weak UIWindow *gHostWindow;     // SBCoverSheetWindow (host of poster layer)
static __weak UIView  *gCoverSheetView;  // the sliding view (progress source only)
static CADisplayLink  *gDisplayLink;
static CGFloat         gLastProgress = 0.0;
static CGFloat         gFallbackBaselineY = -1.0;
static NSString       *gFromState;
static NSString       *gToState;

// =====================================================================
// Private class forward decls
// =====================================================================

@interface CSCoverSheetView : UIView
@end

@interface CSCoverSheetViewController        : UIViewController @end
@interface SBCoverSheetSlidingViewController : UIViewController @end
@interface SBDashBoardViewController         : UIViewController @end

// =====================================================================
// Filesystem helpers
// =====================================================================

static NSString *PPFindFirstWallpaperBundle(void) {
    NSError *err = nil;
    NSArray *items = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:kPPWallpaperRoot error:&err];
    if (!items) return nil;
    for (NSString *name in items) {
        if ([name hasSuffix:@".wallpaper"]) {
            return [kPPWallpaperRoot stringByAppendingPathComponent:name];
        }
    }
    return nil;
}

static NSString *PPFindFloatingCA(NSString *wallpaperBundle) {
    NSError *err = nil;
    NSArray *items = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:wallpaperBundle error:&err];
    if (!items) return nil;
    for (NSString *name in items) {
        if ([name hasSuffix:@".ca"] && [name containsString:@"Floating"]) {
            return [wallpaperBundle stringByAppendingPathComponent:name];
        }
    }
    for (NSString *name in items) {
        if ([name hasSuffix:@".ca"]) {
            return [wallpaperBundle stringByAppendingPathComponent:name];
        }
    }
    return nil;
}

// =====================================================================
// Debug label / log
// =====================================================================

static void PPSetDebug(NSString *fmt, ...) {
    if (!kPPDebugLabel) return;
    va_list args;
    va_start(args, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gDebugLabel) gDebugLabel.text = s;
    });
    [s writeToFile:@"/var/mobile/pocketplayer.log"
        atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void PPInstallDebugLabel(UIView *host) {
    if (!kPPDebugLabel) return;
    if (gDebugLabel.superview == host) return;
    [gDebugLabel removeFromSuperview];

    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(8, 60, host.bounds.size.width - 16, 22)];
    l.tag = 0xCAFE;
    l.textColor = [UIColor redColor];
    l.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightMedium];
    l.text = @"PocketPlayer ready";
    l.userInteractionEnabled = NO;
    l.layer.zPosition = 9999;
    [host addSubview:l];
    gDebugLabel = l;
}

// =====================================================================
// State resolution
// =====================================================================

static void PPResolveStates(PPCAMLDocument *doc) {
    gFromState = nil;
    gToState   = nil;
    if (!doc) return;

    NSArray *prefer = @[
        @[@"Locked",  @"Unlock"],
        @[@"Locked",  @"Unlocked"],
        @[@"Sleep",   @"Wake"],
        @[@"Default", @"Activated"],
    ];
    for (NSArray *pair in prefer) {
        if (doc.states[pair[0]] && doc.states[pair[1]]) {
            gFromState = pair[0];
            gToState   = pair[1];
            return;
        }
    }

    NSArray *names = doc.stateOrder;
    if (names.count >= 2) { gFromState = names[0]; gToState = names[1]; }
    else if (names.count == 1) { gFromState = nil; gToState = names[0]; }
}

static void PPApplyProgress(CGFloat progress) {
    progress = MAX(0.0, MIN(1.0, progress));
    gLastProgress = progress;
    if (!gDoc || !gToState) return;
    if (gFromState) {
        [gDoc applyTransitionFromState:gFromState toState:gToState progress:progress];
    } else {
        [gDoc applyState:gToState progress:progress];
    }
}

// =====================================================================
// Poster install — into the COVER SHEET WINDOW's layer
// =====================================================================

static void PPInstallPosterIntoWindow(UIWindow *window) {
    if (!window) return;
    gHostWindow = window;

    // Remove any previous instance from this window.
    for (CALayer *l in [window.layer.sublayers copy]) {
        if ([l.name isEqualToString:@"PocketPlayerLayer"]) [l removeFromSuperlayer];
    }

    NSString *bundle  = PPFindFirstWallpaperBundle();
    NSString *caPath  = bundle ? PPFindFloatingCA(bundle) : nil;
    NSString *camlPath  = caPath ? [caPath stringByAppendingPathComponent:@"main.caml"] : nil;
    NSString *assetsPath = caPath ? [caPath stringByAppendingPathComponent:@"assets"] : nil;

    if (!camlPath || ![[NSFileManager defaultManager] fileExistsAtPath:camlPath]) {
        PPSetDebug(@"no caml at %@", camlPath ?: @"(nil)");
        return;
    }

    PPCAMLDocument *doc = [PPCAMLParser parseCAMLAtPath:camlPath assetsPath:assetsPath];
    if (!doc || !doc.rootLayer) {
        PPSetDebug(@"caml parse failed");
        return;
    }
    gDoc = doc;

    // Container fills the WINDOW. zPosition = -1 puts it behind cover-sheet
    // sibling views (which sit at default zPosition 0) but in front of any
    // background the window may have.
    CALayer *container = [CALayer layer];
    container.name = @"PocketPlayerLayer";
    container.bounds = window.bounds;
    container.position = CGPointMake(window.bounds.size.width / 2.0,
                                     window.bounds.size.height / 2.0);
    container.zPosition = -1;
    container.masksToBounds = NO;

    CGRect rb = doc.rootLayer.bounds;
    if (rb.size.width <= 0 || rb.size.height <= 0) rb = CGRectMake(0, 0, 390, 844);
    CGFloat sx = window.bounds.size.width  / rb.size.width;
    CGFloat sy = window.bounds.size.height / rb.size.height;
    CGFloat s  = MAX(sx, sy);

    doc.rootLayer.anchorPoint = CGPointMake(0.5, 0.5);
    doc.rootLayer.position    = CGPointMake(window.bounds.size.width  / 2.0,
                                            window.bounds.size.height / 2.0);
    doc.rootLayer.transform   = CATransform3DMakeScale(s, s, 1.0);

    [container addSublayer:doc.rootLayer];
    [window.layer addSublayer:container];
    gPosterLayer = container;

    [doc captureBaseValues];
    PPResolveStates(doc);

    NSArray *names = doc.stateOrder;
    NSString *summary = [NSString stringWithFormat:@"states=[%@] from=%@ to=%@ count=%lu",
        [names componentsJoinedByString:@","], gFromState ?: @"-", gToState ?: @"-",
        (unsigned long)names.count];
    [summary writeToFile:@"/var/mobile/pocketplayer-states.log"
              atomically:YES encoding:NSUTF8StringEncoding error:nil];

    PPApplyProgress(0.0);
    PPSetDebug(@"ready %@ st=%lu hostWin=%@",
        [camlPath lastPathComponent],
        (unsigned long)names.count,
        NSStringFromClass([window class]));
}

static void PPCleanupStaleLayersInWindow(UIWindow *window, CALayer *keep) {
    if (!window) return;
    for (CALayer *l in [window.layer.sublayers copy]) {
        if ([l.name isEqualToString:@"PocketPlayerLayer"] && l != keep) {
            [l removeFromSuperlayer];
        }
    }
}

// Recursively walks a CALayer tree and removes any sublayer named
// "PocketPlayerLayer" that isn't the one we want to keep. Plain C, no
// blocks, to avoid -Warc-retain-cycles on self-referential captures.
static void PPNukeStaleLayersInTree(CALayer *root, CALayer *keep) {
    if (!root) return;
    for (CALayer *l in [root.sublayers copy]) {
        if ([l.name isEqualToString:@"PocketPlayerLayer"] && l != keep) {
            [l removeFromSuperlayer];
            continue;
        }
        PPNukeStaleLayersInTree(l, keep);
    }
}

// Same idea, but for the UIView hierarchy (since debug labels and any
// older-build container UIViews live there).
static void PPNukeStaleViewsInTree(UIView *root) {
    if (!root) return;
    for (UIView *v in [root.subviews copy]) {
        if (v.tag == 0xCAFE && v != gDebugLabel) {
            [v removeFromSuperview];
            continue;
        }
        PPNukeStaleViewsInTree(v);
    }
}

// Walk every UIWindow in the active scene and reap any stale poster
// layers that older builds may have parented to wallpaper views,
// cover-sheet views, or other windows entirely. Run this on every
// install so a newer build always wins decisively.
static void PPNukeAllStaleLayersEverywhere(CALayer *keep) {
    NSArray<UIWindow *> *windows = nil;
    if (@available(iOS 15.0, *)) {
        NSMutableArray *all = [NSMutableArray array];
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]]) {
                [all addObjectsFromArray:((UIWindowScene *)s).windows];
            }
        }
        windows = all;
    }
    if (windows.count == 0) {
        // Last-resort fallback (deprecated but works on jailbroken 15).
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        windows = [UIApplication sharedApplication].windows;
        #pragma clang diagnostic pop
    }
    for (UIWindow *w in windows) {
        PPNukeStaleLayersInTree(w.layer, keep);
        PPNukeStaleViewsInTree(w);
    }
}

// =====================================================================
// CADisplayLink — drives state interpolation only
// =====================================================================

@interface PPDisplayLinkTarget : NSObject
- (void)tick:(CADisplayLink *)link;
@end

@implementation PPDisplayLinkTarget
- (void)tick:(CADisplayLink *)link {
    UIView *cs = gCoverSheetView;
    if (!cs.window) return;

    // Keep poster sized to the window on rotation.
    UIWindow *win = gHostWindow;
    if (gPosterLayer && win && gPosterLayer.superlayer == win.layer) {
        if (!CGSizeEqualToSize(gPosterLayer.bounds.size, win.bounds.size)) {
            gPosterLayer.bounds = win.bounds;
            gPosterLayer.position = CGPointMake(win.bounds.size.width / 2.0,
                                                 win.bounds.size.height / 2.0);
            if (gDoc.rootLayer) {
                CGRect rb = gDoc.rootLayer.bounds;
                if (rb.size.width <= 0 || rb.size.height <= 0) rb = CGRectMake(0, 0, 390, 844);
                CGFloat sx = win.bounds.size.width  / rb.size.width;
                CGFloat sy = win.bounds.size.height / rb.size.height;
                CGFloat s  = MAX(sx, sy);
                gDoc.rootLayer.position = CGPointMake(win.bounds.size.width  / 2.0,
                                                      win.bounds.size.height / 2.0);
                gDoc.rootLayer.transform = CATransform3DMakeScale(s, s, 1.0);
            }
        }
    }

    // Compute progress from the cover sheet's window-space center.
    CGPoint center = [cs.superview convertPoint:cs.center toView:nil];
    CGFloat y = center.y;
    if (gFallbackBaselineY < 0 || y > gFallbackBaselineY) gFallbackBaselineY = y;

    CGFloat travel = gFallbackBaselineY - y;
    if (travel < 0) travel = 0;

    CGFloat h = cs.bounds.size.height;
    if (h > 1) {
        CGFloat progress = travel / h;
        progress = MAX(0.0, MIN(1.0, progress));
        if (fabs(progress - gLastProgress) > 0.001) {
            PPApplyProgress(progress);
            PPSetDebug(@"fb p=%.2f %@->%@ ty=%.0f", progress,
                gFromState ?: @"-", gToState ?: @"-", travel);
        }
    }
}
@end

static void PPStartDisplayLink(void) {
    if (gDisplayLink) return;
    PPDisplayLinkTarget *t = [PPDisplayLinkTarget new];
    gDisplayLink = [CADisplayLink displayLinkWithTarget:t selector:@selector(tick:)];
    [gDisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

// =====================================================================
// Apply bridge — listen for "com.vortex.pocketplayer.apply" Darwin
// notifications from the PocketPoster app. When fired, copy the
// manifest's source bundle into the active PosterPlayer slot and
// reload the poster live (no respring).
// =====================================================================

static NSString *const kPPApplyManifestPath =
    @"/var/mobile/Library/PocketPlayer/apply.plist";
static const char *const kPPApplyDarwinName =
    "com.vortex.pocketplayer.apply";

// Atomically replace the .wallpaper bundle inside
//     /var/mobile/Library/PosterPlayer/active/versions/1/contents/
// with the one at `srcBundle`. Returns YES on success.
//
// We intentionally do NOT touch sibling files (Wallpaper.plist etc.)
// that PosterPlayer manages -- only the .wallpaper folder swaps in.
static BOOL PPInstallBundleIntoActiveSlot(NSString *srcBundle) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (!srcBundle.length) return NO;
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:srcBundle isDirectory:&isDir] || !isDir) return NO;

    NSString *contents = kPPWallpaperRoot;
    [fm createDirectoryAtPath:contents
  withIntermediateDirectories:YES
                   attributes:nil
                        error:NULL];

    // Remove any pre-existing *.wallpaper sibling to avoid PosterPlayer
    // glomming two bundles together. Same scan PPFindFirstWallpaperBundle
    // uses, just in delete mode.
    for (NSString *kid in [fm contentsOfDirectoryAtPath:contents error:NULL]) {
        if ([kid hasSuffix:@".wallpaper"]) {
            NSString *victim = [contents stringByAppendingPathComponent:kid];
            [fm removeItemAtPath:victim error:NULL];
        }
    }

    NSString *dstName = [srcBundle lastPathComponent];
    NSString *dstPath = [contents stringByAppendingPathComponent:dstName];

    NSError *err = nil;
    if (![fm copyItemAtPath:srcBundle toPath:dstPath error:&err]) {
        NSString *msg = [NSString stringWithFormat:@"copy failed: %@",
            err.localizedDescription ?: @"?"];
        [msg writeToFile:@"/var/mobile/pocketplayer-apply.log"
              atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return NO;
    }
    return YES;
}

static void PPHandleApplyNotification(void) {
    @autoreleasepool {
        NSDictionary *manifest =
            [NSDictionary dictionaryWithContentsOfFile:kPPApplyManifestPath];
        NSString *src = manifest[@"sourceBundlePath"];
        if (!src.length) {
            PPSetDebug(@"apply: no manifest");
            return;
        }

        if (!PPInstallBundleIntoActiveSlot(src)) {
            PPSetDebug(@"apply: copy failed src=%@", src);
            return;
        }

        // Re-install the poster from disk. Existing PocketPlayerLayer is
        // removed by PPInstallPosterIntoWindow itself; this gives us a
        // brand-new PPCAMLDocument bound to the new bundle. No respring.
        UIWindow *win = gHostWindow;
        if (win) {
            PPInstallPosterIntoWindow(win);
            PPNukeAllStaleLayersEverywhere(gPosterLayer);
            PPRebuildMirrorEmitters();
            PPSetDebug(@"apply OK: %@",
                manifest[@"displayName"] ?: [src lastPathComponent]);
        } else {
            PPSetDebug(@"apply: no host window yet, manifest staged");
        }

        // Manifest is one-shot -- delete so a stale one doesn't trigger
        // re-applies on the next boot.
        [[NSFileManager defaultManager] removeItemAtPath:kPPApplyManifestPath
                                                   error:NULL];
    }
}

static void PPRegisterApplyListener(void) {
    static dispatch_once_t once;
    static int token;
    dispatch_once(&once, ^{
        notify_register_dispatch(kPPApplyDarwinName,
                                 &token,
                                 dispatch_get_main_queue(),
                                 ^(int t) { PPHandleApplyNotification(); });
        // If the app fired its notification before we could subscribe
        // (e.g. user tapped Apply seconds before SpringBoard finished
        // booting), the manifest will still be sitting on disk. Pick
        // it up on first install.
        if ([[NSFileManager defaultManager] fileExistsAtPath:kPPApplyManifestPath]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                PPHandleApplyNotification();
            });
        }
    });
}

// =====================================================================
// Hooks
// =====================================================================

%hook CSCoverSheetView

- (void)didMoveToWindow {
    %orig;
    if (self.window == nil) return;
    gCoverSheetView = self;
    gFallbackBaselineY = -1.0;

    // Kill any zombies left by older builds anywhere in the SpringBoard
    // process — wallpaper views, other windows, our own cover sheet view.
    PPNukeAllStaleLayersEverywhere(gPosterLayer);

    PPInstallDebugLabel(self);
    PPStartDisplayLink();
    PPRegisterApplyListener();

    // Install poster directly on the cover sheet WINDOW. The window does
    // not move during unlock; only the cover sheet view (its child) does.
    UIWindow *win = self.window;
    if (win && (!gPosterLayer || gPosterLayer.superlayer != win.layer)) {
        PPInstallPosterIntoWindow(win);
        PPCleanupStaleLayersInWindow(win, gPosterLayer);
        // One more sweep AFTER install, so anything that was lurking in
        // a sibling window is removed even if it tried to reattach.
        PPNukeAllStaleLayersEverywhere(gPosterLayer);
    }
}

- (void)layoutSubviews {
    %orig;
    if (gDebugLabel.superview == self) {
        gDebugLabel.frame = CGRectMake(8, 60, self.bounds.size.width - 16, 22);
    }
    UIWindow *win = self.window;
    if (win && (!gPosterLayer || gPosterLayer.superlayer != win.layer)) {
        PPInstallPosterIntoWindow(win);
        PPNukeAllStaleLayersEverywhere(gPosterLayer);
    }
}

%end

%hook CSCoverSheetViewController
- (void)_updatePresentationProgress:(CGFloat)progress
                         withOffset:(CGFloat)offset
                  presentationState:(NSInteger)state {
    %orig;
    PPApplyProgress(1.0 - progress);
    PPSetDebug(@"CS p=%.2f %@->%@ off=%.0f st=%ld",
        1.0 - progress, gFromState ?: @"-", gToState ?: @"-",
        (double)offset, (long)state);
}
%end

%hook SBCoverSheetSlidingViewController
- (void)_updatePresentationProgress:(CGFloat)progress
                         withOffset:(CGFloat)offset
                  presentationState:(NSInteger)state {
    %orig;
    PPApplyProgress(1.0 - progress);
    PPSetDebug(@"Sl p=%.2f %@->%@ off=%.0f st=%ld",
        1.0 - progress, gFromState ?: @"-", gToState ?: @"-",
        (double)offset, (long)state);
}
%end

%hook SBDashBoardViewController
- (void)_updatePresentationProgress:(CGFloat)progress
                         withOffset:(CGFloat)offset
                  presentationState:(NSInteger)state {
    %orig;
    PPApplyProgress(1.0 - progress);
    PPSetDebug(@"DB p=%.2f %@->%@ off=%.0f st=%ld",
        1.0 - progress, gFromState ?: @"-", gToState ?: @"-",
        (double)offset, (long)state);
}
%end

%ctor {
    @autoreleasepool {
        NSString *exe = [[[NSBundle mainBundle] executablePath] lastPathComponent];
        if (![exe isEqualToString:@"SpringBoard"]) return;
        %init;
    }
}
