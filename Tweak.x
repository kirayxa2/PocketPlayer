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
// Window-space mirror copies of every CAML emitter, parented onto the cover
// sheet VIEW (whose layer-tree time is not frozen). The pointers are weak --
// the layers are owned by their superlayer.
static NSMutableArray *gMirrorEmitters; // NSMutableArray<CAEmitterLayer *>

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

// =====================================================================
// Emitter mirroring
// =====================================================================
//
// The cover-sheet WINDOW's layer is held at speed=0 by SpringBoard while the
// device is locked, so any CAEmitterLayer we put inside it stops emitting
// (its internal clock is multiplied by 0). The cover-sheet VIEW that lives
// inside that window does NOT have its layer time frozen -- you can verify
// this by adding any CAEmitterLayer to gCoverSheetView.layer and watching
// it emit normally.
//
// So for every CAEmitterLayer the CAML parser created we build a window-
// space MIRROR on gCoverSheetView.layer, copy the cells across, and silence
// the original. The mirror lives only as long as gCoverSheetView is in the
// window; PPRebuildMirrorEmitters() is idempotent and re-runs whenever the
// view re-mounts.

static CAEmitterCell *PPCloneCell(CAEmitterCell *src) {
    CAEmitterCell *c = [CAEmitterCell emitterCell];
    c.name              = src.name;
    c.contents          = src.contents;
    c.contentsScale     = src.contentsScale > 0 ? src.contentsScale : 1.0;
    c.birthRate         = src.birthRate;
    c.lifetime          = src.lifetime;
    c.lifetimeRange     = src.lifetimeRange;
    c.velocity          = src.velocity;
    c.velocityRange     = src.velocityRange;
    c.xAcceleration     = src.xAcceleration;
    c.yAcceleration     = src.yAcceleration;
    c.zAcceleration     = src.zAcceleration;
    c.scale             = src.scale;
    c.scaleRange        = src.scaleRange;
    c.scaleSpeed        = src.scaleSpeed;
    c.spin              = src.spin;
    c.spinRange         = src.spinRange;
    c.emissionLatitude  = src.emissionLatitude;
    c.emissionLongitude = src.emissionLongitude;
    c.emissionRange     = src.emissionRange;
    c.color             = src.color;
    c.redRange          = src.redRange;
    c.greenRange        = src.greenRange;
    c.blueRange         = src.blueRange;
    c.alphaRange        = src.alphaRange;
    c.redSpeed          = src.redSpeed;
    c.greenSpeed        = src.greenSpeed;
    c.blueSpeed         = src.blueSpeed;
    c.alphaSpeed        = src.alphaSpeed;
    if (src.emitterCells.count) {
        NSMutableArray *kids = [NSMutableArray array];
        for (CAEmitterCell *k in src.emitterCells) [kids addObject:PPCloneCell(k)];
        c.emitterCells = [kids copy];
    }
    return c;
}

static void PPRemoveExistingMirrors(void) {
    for (CAEmitterLayer *m in [gMirrorEmitters copy]) {
        [m removeFromSuperlayer];
    }
    [gMirrorEmitters removeAllObjects];
}

static void PPRebuildMirrorEmitters(void) {
    UIView *cs = gCoverSheetView;
    if (!cs || !cs.window) return;
    if (!gDoc) return;
    if (!gMirrorEmitters) gMirrorEmitters = [NSMutableArray array];

    PPRemoveExistingMirrors();

    NSArray<CAEmitterLayer *> *sources = gDoc.emitters;
    if (sources.count == 0) {
        PPSetDebug(@"no emitters in CAML");
        return;
    }

    CALayer *host = cs.layer;
    int idx = 0;
    for (CAEmitterLayer *src in sources) {
        // Where is the original emitter in window coordinates? Walk through
        // its accumulated parent transforms via CALayer's own conversion.
        if (!src.superlayer) continue;
        CGPoint srcCenter = CGPointMake(CGRectGetMidX(src.bounds),
                                        CGRectGetMidY(src.bounds));
        CGPoint inHost = [host convertPoint:srcCenter fromLayer:src];

        // Build a fresh emitter from scratch -- this is critical, because
        // CAEmitterLayer caches its render state on first commit and
        // removeFromSuperlayer/addSublayer: doesn't reset it.
        CAEmitterLayer *m = [CAEmitterLayer layer];
        m.name = @"PocketPlayerEmitterMirror";

        // Geometry: keep the same emitter shape/size/mode the wallpaper
        // author chose, but anchor it at the converted window-space point.
        m.bounds          = CGRectMake(0, 0, 1, 1);
        m.position        = inHost;
        m.emitterPosition = CGPointMake(0, 0);
        m.emitterSize     = src.emitterSize;
        m.emitterShape    = src.emitterShape ?: kCAEmitterLayerPoint;
        m.emitterMode     = src.emitterMode  ?: kCAEmitterLayerVolume;
        m.renderMode      = src.renderMode   ?: kCAEmitterLayerUnordered;
        m.birthRate       = src.birthRate > 0 ? src.birthRate : 1.0;
        m.lifetime        = src.lifetime  > 0 ? src.lifetime  : 1.0;
        m.scale           = src.scale     > 0 ? src.scale     : 1.0;
        m.speed           = 1.0;
        m.zPosition       = 9000; // above CAML decor layers, below debug label
        m.masksToBounds   = NO;

        // Clone every cell with a typed setter (KVC into CAEmitterCell is
        // unreliable on iOS 15 for some keys -- typed setters always work).
        NSMutableArray<CAEmitterCell *> *cells = [NSMutableArray array];
        for (CAEmitterCell *cell in src.emitterCells) {
            [cells addObject:PPCloneCell(cell)];
        }
        // emitterCells must be set BEFORE addSublayer: on iOS 15 or the
        // emitter caches a "no cells" state and silently never emits.
        m.emitterCells = [cells copy];

        [host addSublayer:m];
        m.beginTime = [m convertTime:CACurrentMediaTime() fromLayer:nil];

        [gMirrorEmitters addObject:m];

        // We deliberately do NOT silence the original emitter. While the
        // device is locked the cover-sheet WINDOW's layer time is frozen,
        // so the original emits nothing on screen and only the mirror is
        // visible. Once the user unlocks, the cover-sheet VIEW slides
        // off-screen (taking the mirror with it, harmlessly invisible)
        // and the window thaws, letting the ORIGINAL emit on the home
        // screen exactly as before. Net result: both screens get the
        // intended particles, and we never have to track which mode we
        // are in.

        idx++;
    }
    PPSetDebug(@"emitters mirrored=%d host=%@", idx,
        NSStringFromClass([host class]));
}

// Reset beginTime on every mirror so emission keeps flowing across hide/show
// cycles (e.g. after the cover sheet snaps closed and reopens).
static void PPRePrimeMirrorEmitters(void) {
    if (gMirrorEmitters.count == 0) return;
    CFTimeInterval now = CACurrentMediaTime();
    for (CAEmitterLayer *m in gMirrorEmitters) {
        m.speed     = 1.0;
        m.hidden    = NO;
        m.beginTime = [m convertTime:now fromLayer:nil];
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

    // Mirror every CAML emitter onto THIS view's layer. The cover sheet
    // window's layer time is frozen by SpringBoard while locked, so an
    // emitter parented there silently stops emitting -- but a sibling
    // emitter on the cover sheet view ticks normally.
    PPRebuildMirrorEmitters();
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
        PPRebuildMirrorEmitters();
    } else if (gMirrorEmitters.count == 0 && gDoc.emitters.count > 0) {
        // Poster is already installed but mirrors got reaped during a
        // hide/show cycle -- restore them.
        PPRebuildMirrorEmitters();
    } else {
        PPRePrimeMirrorEmitters();
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
