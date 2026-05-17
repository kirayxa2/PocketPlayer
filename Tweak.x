// PocketPlayer — animated lockscreen wallpapers (.ca bundles) for iOS 15.
//
// Architecture (PosterBoard-style, iOS 15 backport):
//
//   [SBHomeScreenWindow / wallpaper window]    <- never moves
//      └── _UIWallpaperView                    <- our CALayer tree lives HERE
//           └── PocketPlayerLayer
//                └── <CAML root layer>
//                     ├── Bottom_chest.png
//                     ├── Top_chest.png        <- animated by Locked->Unlock states
//                     ├── Lock.png             <- animated
//                     └── ...
//
//   [SBCoverSheetWindow]                       <- this is what slides up on swipe
//      └── CSCoverSheetView                    <- only used to track swipe progress
//
// Why:
//   On real PosterBoard the wallpaper sits in its own window that does NOT move
//   during unlock. The cover sheet (clock, notifications, passcode) is a
//   separate window that slides off the top. So:
//     - wallpaper = static, only its inner layers animate via state interpolation
//     - cover sheet = full-screen translation, drives the progress value
//   Putting our layer inside CSCoverSheetView like before made the whole thing
//   slide up together with the clock, which is wrong.
//
// Progress is fed from whichever of these gets called first:
//   1) CSCoverSheetViewController _updatePresentationProgress:withOffset:presentationState:
//   2) SBCoverSheetSlidingViewController <same selector>
//   3) SBDashBoardViewController <same selector>   (older private name on some 15.x)
//   4) Fallback: CADisplayLink reading the cover-sheet view's window-space y.
//
// All four are installed at once, so we don't have to rebuild to "guess" the
// right one for a given iOS 15.x point release.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "CAMLParser.h"

// =====================================================================
// Configuration
// =====================================================================

// Path to the active wallpaper bundle.
// Layout: <root>/<name>.wallpaper/<name>_Floating-WxH@3x~iphone.ca/main.caml
static NSString *const kPPWallpaperRoot =
    @"/var/mobile/Library/PosterPlayer/active/versions/1/contents";

// Show a small red debug label in top-left while we develop.
// Flip to NO before shipping.
static BOOL const kPPDebugLabel = YES;

// =====================================================================
// State
// =====================================================================

static UILabel        *gDebugLabel;
static PPCAMLDocument *gDoc;
static CALayer        *gPosterLayer;     // our container CALayer (zPosition handled below)
static __weak UIView  *gWallpaperView;   // the static wallpaper view we host into
static __weak UIView  *gCoverSheetView;  // the sliding view used only as progress source
static CADisplayLink  *gDisplayLink;
static CGFloat         gLastProgress = 0.0;
static CGFloat         gFallbackBaselineY = -1.0;
static NSString       *gFromState;
static NSString       *gToState;

// =====================================================================
// Private class forward decls (so the compiler is happy under -fobjc-arc)
// =====================================================================

@interface CSCoverSheetView : UIView
@end

@interface CSCoverSheetViewController        : UIViewController @end
@interface SBCoverSheetSlidingViewController : UIViewController @end
@interface SBDashBoardViewController         : UIViewController @end

// _UIWallpaperView lives in UIKit. SBFWallpaperView is its SpringBoard-private
// subclass on iOS 15 and is the one actually placed on the lock screen.
// SBHomeScreenWallpaperView is the home-screen sibling — we MUST NOT host
// our poster in that one (we'd see it on the home screen).
@interface _UIWallpaperView : UIView @end
@interface SBFWallpaperView : _UIWallpaperView @end
@interface SBWallpaperEffectView : UIView @end
@interface SBHomeScreenWallpaperView : UIView @end

// SpringBoard window classes used to tell the lock-screen wallpaper apart from
// the home-screen wallpaper. On iOS 15 the lock-screen wallpaper sits inside
// SBCoverSheetWindow (or one of its descendants), while the home-screen
// wallpaper lives in a normal SBHomeScreenWindow.
@interface SBCoverSheetWindow            : UIWindow @end
@interface SBHomeScreenWindow            : UIWindow @end
@interface SBHomeScreenWallpaperWindow   : UIWindow @end

// =====================================================================
// Helpers: filesystem
// =====================================================================

// Walk up the view hierarchy. Return YES iff one of the ancestors is the
// SBCoverSheetWindow (i.e. we are in lock-screen context, NOT home-screen).
static BOOL PPViewIsInLockScreen(UIView *v) {
    if (!v) return NO;
    UIView *cur = v;
    while (cur) {
        Class c = [cur class];
        NSString *name = NSStringFromClass(c);
        if ([name isEqualToString:@"SBCoverSheetWindow"]) return YES;
        // Some 15.x builds wrap wallpaper in SBCoverSheetExternalViewController
        if ([name containsString:@"CoverSheet"]) return YES;
        // Hard-no list: home-screen wallpaper containers
        if ([name isEqualToString:@"SBHomeScreenWindow"] ||
            [name isEqualToString:@"SBHomeScreenWallpaperWindow"]) return NO;
        cur = cur.superview;
    }
    // No window attached yet — treat as "not lock" so we don't host into a
    // floating preview/snapshot view.
    return NO;
}

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

    // Preferred canonical pairs. Community PosterBoard wallpapers usually use
    // "Unlock" (no -ed); Apple's tooling uses "Unlocked".
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

// progress: 0 = locked, 1 = fully unlocked
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
// Poster install (into the static wallpaper view)
// =====================================================================

static void PPInstallPosterIntoWallpaperView(UIView *wallpaper) {
    if (!wallpaper) return;
    gWallpaperView = wallpaper;

    // Remove any previous instance (we get re-installed on relayout).
    for (CALayer *l in [wallpaper.layer.sublayers copy]) {
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

    // Container scaled to fit the wallpaper view (= screen).
    CALayer *container = [CALayer layer];
    container.name = @"PocketPlayerLayer";
    container.frame = wallpaper.bounds;
    container.zPosition = 100; // above the wallpaper image
    container.masksToBounds = YES;

    CGRect rb = doc.rootLayer.bounds;
    if (rb.size.width <= 0 || rb.size.height <= 0) rb = CGRectMake(0, 0, 390, 844);
    CGFloat sx = wallpaper.bounds.size.width  / rb.size.width;
    CGFloat sy = wallpaper.bounds.size.height / rb.size.height;
    CGFloat s  = MAX(sx, sy); // fill

    doc.rootLayer.anchorPoint = CGPointMake(0.5, 0.5);
    doc.rootLayer.position    = CGPointMake(wallpaper.bounds.size.width  / 2.0,
                                            wallpaper.bounds.size.height / 2.0);
    // Counter geometryFlipped on the host (some wallpaper views use it for
    // perspective zoom), so the CAML stays right-side up.
    CATransform3D t = CATransform3DMakeScale(s, s, 1.0);
    if (wallpaper.layer.geometryFlipped) {
        t = CATransform3DConcat(t, CATransform3DMakeScale(1.0, -1.0, 1.0));
    }
    doc.rootLayer.transform   = t;

    [container addSublayer:doc.rootLayer];
    [wallpaper.layer addSublayer:container];
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
    PPSetDebug(@"ready %@ st=%lu host=%@",
        [camlPath lastPathComponent],
        (unsigned long)names.count,
        NSStringFromClass([wallpaper class]));
}

// =====================================================================
// Fallback: CADisplayLink — reads the cover-sheet view position to derive 0..1
// =====================================================================

@interface PPDisplayLinkTarget : NSObject
- (void)tick:(CADisplayLink *)link;
@end

@implementation PPDisplayLinkTarget
- (void)tick:(CADisplayLink *)link {
    UIView *cs = gCoverSheetView;
    if (!cs.window) return;

    // Convert center to window coords. While unlocking, the cover sheet view
    // (or one of its ancestors) translates upward off-screen.
    CGPoint center = [cs.superview convertPoint:cs.center toView:nil];
    CGFloat y = center.y;

    if (gFallbackBaselineY < 0 || y > gFallbackBaselineY) gFallbackBaselineY = y;

    CGFloat h = cs.bounds.size.height;
    if (h <= 1) return;

    CGFloat travel = gFallbackBaselineY - y;
    CGFloat progress = travel / h;
    progress = MAX(0.0, MIN(1.0, progress));

    if (fabs(progress - gLastProgress) > 0.001) {
        PPApplyProgress(progress);
        PPSetDebug(@"fb p=%.2f %@->%@ y=%.1f", progress,
            gFromState ?: @"-", gToState ?: @"-", y);
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
// Hooks
// =====================================================================

// (1) Wallpaper view — STATIC host. Hook the generic _UIWallpaperView so we
//     catch whatever subclass (SBFWallpaperView, etc.) the running iOS build
//     actually instantiates. We then filter to LOCK-SCREEN context only,
//     so the home-screen wallpaper stays untouched.

static void PPMaybeInstallIntoWallpaper(UIView *v) {
    if (!v.window) return;
    if (!PPViewIsInLockScreen(v)) return;

    // Skip if we already installed into THIS view.
    for (CALayer *l in v.layer.sublayers) {
        if ([l.name isEqualToString:@"PocketPlayerLayer"]) return;
    }
    PPInstallPosterIntoWallpaperView(v);
}

%hook _UIWallpaperView

- (void)didMoveToWindow {
    %orig;
    PPMaybeInstallIntoWallpaper(self);
}

- (void)layoutSubviews {
    %orig;
    if (gPosterLayer && gPosterLayer.superlayer == self.layer) {
        gPosterLayer.frame = self.bounds;
        if (gDoc.rootLayer) {
            CGRect rb = gDoc.rootLayer.bounds;
            if (rb.size.width <= 0 || rb.size.height <= 0) rb = CGRectMake(0, 0, 390, 844);
            CGFloat sx = self.bounds.size.width  / rb.size.width;
            CGFloat sy = self.bounds.size.height / rb.size.height;
            CGFloat s  = MAX(sx, sy);
            // If the host view has geometryFlipped (some wallpaper views do),
            // we counter it by flipping our root layer's Y axis. This keeps
            // the chest right-side up regardless of host orientation.
            CATransform3D t = CATransform3DMakeScale(s, s, 1.0);
            if (self.layer.geometryFlipped) {
                t = CATransform3DConcat(t, CATransform3DMakeScale(1.0, -1.0, 1.0));
            }
            gDoc.rootLayer.position = CGPointMake(self.bounds.size.width  / 2.0,
                                                  self.bounds.size.height / 2.0);
            gDoc.rootLayer.transform = t;
        }
    }
}

%end

// (2) Cover sheet view — used ONLY to:
//       - capture the view ref so the CADisplayLink can read its position
//       - host the debug label

%hook CSCoverSheetView

- (void)didMoveToWindow {
    %orig;
    if (self.window == nil) return;
    gCoverSheetView = self;
    gFallbackBaselineY = -1.0; // re-establish baseline after relayout
    PPInstallDebugLabel(self);
    PPStartDisplayLink();
}

- (void)layoutSubviews {
    %orig;
    if (gDebugLabel.superview == self) {
        gDebugLabel.frame = CGRectMake(8, 60, self.bounds.size.width - 16, 22);
    }
}

%end

// (3) Three potential progress sources. Whichever exists at runtime gets matched.

%hook CSCoverSheetViewController
- (void)_updatePresentationProgress:(CGFloat)progress
                         withOffset:(CGFloat)offset
                  presentationState:(NSInteger)state {
    %orig;
    PPApplyProgress(1.0 - progress); // CS reports 1=locked, 0=unlocked
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
