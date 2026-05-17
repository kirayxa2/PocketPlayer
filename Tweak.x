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

// Set to YES during development to show the on-screen progress label
// and write per-frame log entries to /var/mobile/pocketplayer.log.
// In a release build this should stay NO.
static BOOL const kPPDebugLabel = YES;

// =====================================================================
// State
// =====================================================================

static UILabel        *gDebugLabel;
static NSMutableArray<PPCAMLDocument *> *gDocs;       // cover-sheet docs (Background/Floating/Foreground)
static CALayer        *gPosterLayer;     // our container CALayer (in window.layer)
static __weak UIWindow *gHostWindow;     // SBCoverSheetWindow (host of poster layer)
static __weak UIView  *gCoverSheetView;  // the sliding view (progress source only)
static NSMutableArray<PPCAMLDocument *> *gHomeDocs;   // home-screen docs (frozen at Unlock)
static CALayer        *gHomePosterLayer; // home-screen container CALayer
static __weak UIWindow *gHomeHostWindow; // SBHomeScreenWindow / app's main window
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
// Forward declarations for helpers used out of definition order
// =====================================================================

static BOOL PPIsOurLayerName(NSString *n);
static void PPNukeStaleLayersInTree(CALayer *root, CALayer *keep);
static void PPNukeStaleViewsInTree(UIView *root);
static void PPNukeAllStaleLayersEverywhere(CALayer *keep);
static void PPCleanupStaleLayersInWindow(UIWindow *window, CALayer *keep);
static UIWindow *PPFindHomeScreenWindow(void);
static void PPInstallPosterIntoHomeWindow(UIWindow *window);
static CALayer *PPFindFloatingLayer(CALayer *root);

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

__attribute__((unused))
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

// PosterBoard wallpapers can ship up to three .ca bundles inside a
// .wallpaper directory:
//
//   *_Background-WxH...ca   <- the bottom-most, often the actual content
//   *_Floating-WxH...ca     <- the swipe-animated overlay (chest/lid/...)
//   *_Foreground-WxH...ca   <- a top decoration layer
//
// In many community .tendies (Dark, PurpleShapes, MarioGalaxy...) the
// Floating bundle is empty and the visible content lives entirely in
// Background. So we MUST parse all three and stack them, otherwise these
// wallpapers render as a black screen.
//
// Returns paths in z-order (back-to-front): Background, Floating, Foreground.
// Any missing bundle is simply skipped.
static NSArray<NSString *> *PPFindAllCABundles(NSString *wallpaperBundle) {
    NSError *err = nil;
    NSArray *items = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:wallpaperBundle error:&err];
    if (!items) return @[];

    NSMutableArray<NSString *> *result = [NSMutableArray array];
    NSArray *order = @[@"Background", @"Floating", @"Foreground"];
    NSMutableSet *taken = [NSMutableSet set];

    for (NSString *kind in order) {
        for (NSString *name in items) {
            if (![name hasSuffix:@".ca"]) continue;
            if (![name containsString:kind]) continue;
            [result addObject:[wallpaperBundle stringByAppendingPathComponent:name]];
            [taken addObject:name];
            break;
        }
    }
    // If we matched none of the three known kinds, fall back to any *.ca
    // we can find so completely custom layouts still work.
    if (result.count == 0) {
        for (NSString *name in items) {
            if ([name hasSuffix:@".ca"] && ![taken containsObject:name]) {
                [result addObject:[wallpaperBundle stringByAppendingPathComponent:name]];
            }
        }
    }
    return result;
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

// Picks state names to interpolate between. Looks at every doc in the
// passed-in list (cover-sheet stack OR home stack) and chooses from the
// first one that has at least 2 states.
static void PPResolveStatesFromDocs(NSArray<PPCAMLDocument *> *docs) {
    gFromState = nil;
    gToState   = nil;
    if (docs.count == 0) return;

    NSArray *prefer = @[
        @[@"Locked",  @"Unlock"],
        @[@"Locked",  @"Unlocked"],
        @[@"Sleep",   @"Wake"],
        @[@"Default", @"Activated"],
    ];
    for (PPCAMLDocument *d in docs) {
        for (NSArray *pair in prefer) {
            if (d.states[pair[0]] && d.states[pair[1]]) {
                gFromState = pair[0];
                gToState   = pair[1];
                return;
            }
        }
    }
    for (PPCAMLDocument *d in docs) {
        NSArray *names = d.stateOrder;
        if (names.count >= 2) { gFromState = names[0]; gToState = names[1]; return; }
        if (names.count == 1) { gFromState = nil; gToState = names[0]; return; }
    }
}

// Back-compat single-doc shim — used nowhere now but kept in case old
// call sites remain.
__attribute__((unused))
static void PPResolveStates(PPCAMLDocument *doc) {
    if (!doc) return;
    PPResolveStatesFromDocs(@[doc]);
}

static void PPApplyProgress(CGFloat progress) {
    progress = MAX(0.0, MIN(1.0, progress));
    gLastProgress = progress;

    // Drive the SAME animation on both the cover-sheet poster (so the
    // user sees the chest opening as they swipe) AND the home-screen
    // poster (so the moment the cover-sheet finishes sliding away there
    // is no visible jump - the chest under the dock is already in the
    // exact same opened pose). Disable implicit CA animations so both
    // posters follow the gesture frame-perfect.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    if (gToState) {
        for (PPCAMLDocument *d in gDocs) {
            if (gFromState) {
                [d applyTransitionFromState:gFromState toState:gToState progress:progress];
            } else {
                [d applyState:gToState progress:progress];
            }
        }
        for (PPCAMLDocument *d in gHomeDocs) {
            if (gFromState) {
                [d applyTransitionFromState:gFromState toState:gToState progress:progress];
            } else {
                [d applyState:gToState progress:progress];
            }
        }
    }

    // Snap-hide the cover-sheet poster the moment we've fully unlocked.
    // The cover-sheet WINDOW lives ~2s past the actual unlock (system
    // dismiss animation), and since it's stacked above the home-screen
    // window, our poster on it would otherwise occlude the icons during
    // that window. The home poster has identical pose at this point, so
    // toggling .hidden is invisible to the user — they perceive the same
    // chest staying put while icons spawn on top via the standard iOS
    // home-screen reveal animation.
    //
    // Important: force BOTH posters to the exact final state (1.0)
    // before snapping. _updatePresentationProgress: doesn't always
    // deliver an exact 1.0 - it can stop at 0.992, 0.997 etc - and a
    // sub-pixel pose mismatch between the two posters at the moment of
    // the snap shows up as a tiny visible "cut" in the recording. By
    // overriding both to 1.0 we guarantee identical poses across the
    // hand-off.
    BOOL fullyUnlocked = (progress >= 0.99);
    if (fullyUnlocked && gToState) {
        for (PPCAMLDocument *d in gDocs) {
            if (gFromState) {
                [d applyTransitionFromState:gFromState toState:gToState progress:1.0];
            } else {
                [d applyState:gToState progress:1.0];
            }
        }
        for (PPCAMLDocument *d in gHomeDocs) {
            if (gFromState) {
                [d applyTransitionFromState:gFromState toState:gToState progress:1.0];
            } else {
                [d applyState:gToState progress:1.0];
            }
        }
    }
    if (gPosterLayer) {
        gPosterLayer.hidden = fullyUnlocked;
    }

    [CATransaction commit];
}

// =====================================================================
// Poster install — into the COVER SHEET WINDOW's layer
// =====================================================================

// Recursively walk the CALayer tree of the parsed CAML doc and find a
// sublayer whose name == "Floating". PosterBoard authors very commonly
// wrap their iPhone-sized scene (e.g. 414x736) inside an iPad canvas
// (3176x3176) and put position offsets like "967 216" to place it.
// Rendering the iPad canvas fitted to a 6s screen ends up shrinking
// our chest/Mario/etc. to invisible pixels - so we prefer the inner
// "Floating" layer as the effective root when present.
//
// Returns nil if no such layer exists; caller falls back to doc.rootLayer.
static CALayer *PPFindFloatingLayer(CALayer *root) {
    if (!root) return nil;
    if ([root.name isEqualToString:@"Floating"] && root.bounds.size.width > 0
        && root.bounds.size.height > 0) {
        return root;
    }
    for (CALayer *l in root.sublayers) {
        CALayer *hit = PPFindFloatingLayer(l);
        if (hit) return hit;
    }
    return nil;
}

// Builds a single CALayer subtree from one CAML file. Returns the
// already-scaled layer ready to add as a sublayer of `container`, plus
// (out) the parsed PPCAMLDocument so the caller can hold on to it for
// state interpolation.
//
// `winSize` is the size of the host window in points; we scale-fit the
// CAML's natural canvas (e.g. 390x844) to that.
static CALayer *PPBuildScaledLayerFromCAML(NSString *caPath,
                                           CGSize winSize,
                                           PPCAMLDocument **outDoc) {
    if (!caPath) { if (outDoc) *outDoc = nil; return nil; }
    NSString *camlPath   = [caPath stringByAppendingPathComponent:@"main.caml"];
    NSString *assetsPath = [caPath stringByAppendingPathComponent:@"assets"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:camlPath]) {
        if (outDoc) *outDoc = nil;
        return nil;
    }
    PPCAMLDocument *doc = [PPCAMLParser parseCAMLAtPath:camlPath assetsPath:assetsPath];
    if (!doc || !doc.rootLayer) {
        if (outDoc) *outDoc = nil;
        return nil;
    }

    // Prefer the inner Floating sub-tree if present (iPad-canvas-with-
    // iPhone-Floating layout), else use the doc's root.
    CALayer *visibleRoot = PPFindFloatingLayer(doc.rootLayer) ?: doc.rootLayer;
    if (visibleRoot != doc.rootLayer) {
        // We're promoting an inner sub-tree to the role of root.
        // Whatever geometryFlipped the OUTER root had defined the
        // coordinate convention the author drew their children in,
        // so we inherit that. Without this, MarioGalaxy-style CAMLs
        // (outer geometryFlipped="1", inner Floating geometryFlipped="0")
        // would render Y-inverted: planet ends up at the top instead
        // of the bottom, Mario above center instead of below, etc.
        visibleRoot.geometryFlipped = doc.rootLayer.geometryFlipped;
        [visibleRoot removeFromSuperlayer];
    }

    CGRect rb = visibleRoot.bounds;
    if (rb.size.width <= 0 || rb.size.height <= 0) rb = CGRectMake(0, 0, 390, 844);
    CGFloat sx = winSize.width  / rb.size.width;
    CGFloat sy = winSize.height / rb.size.height;
    CGFloat s  = MAX(sx, sy);

    visibleRoot.anchorPoint = CGPointMake(0.5, 0.5);
    visibleRoot.position    = CGPointMake(winSize.width  / 2.0,
                                          winSize.height / 2.0);
    visibleRoot.transform   = CATransform3DMakeScale(s, s, 1.0);

    [doc captureBaseValues];

    if (outDoc) *outDoc = doc;
    return visibleRoot;
}

static void PPInstallPosterIntoWindow(UIWindow *window) {
    if (!window) return;
    gHostWindow = window;

    // Remove any previous instance from this window.
    for (CALayer *l in [window.layer.sublayers copy]) {
        if ([l.name isEqualToString:@"PocketPlayerLayer"]) [l removeFromSuperlayer];
    }

    NSString *bundle  = PPFindFirstWallpaperBundle();
    NSArray<NSString *> *caBundles = bundle ? PPFindAllCABundles(bundle) : @[];
    if (caBundles.count == 0) {
        PPSetDebug(@"no .ca bundles in %@", bundle ?: @"(no wallpaper)");
        return;
    }

    // Container fills the WINDOW. zPosition = -1 puts it behind cover-sheet
    // sibling views (which sit at default zPosition 0) but in front of any
    // background the window may have.
    //
    // geometryFlipped = YES compensates for UIWindow.layer's own
    // geometryFlipped (which is YES under UIKit). Setting it here gives
    // our subtree normal UIKit coordinates (origin top-left), without
    // resorting to a Y scale-flip on the root layer.
    CALayer *container = [CALayer layer];
    container.name = @"PocketPlayerLayer";
    container.bounds = window.bounds;
    container.position = CGPointMake(window.bounds.size.width / 2.0,
                                     window.bounds.size.height / 2.0);
    container.zPosition = -1;
    container.masksToBounds = NO;
    container.geometryFlipped = YES;

    // Stack all .ca bundles in z-order: Background, Floating, Foreground.
    // Each becomes its own sublayer of `container`. Empty bundles are
    // gracefully skipped.
    NSMutableArray<PPCAMLDocument *> *docs = [NSMutableArray array];
    NSMutableString *kindList = [NSMutableString string];
    for (NSString *caPath in caBundles) {
        PPCAMLDocument *doc = nil;
        CALayer *l = PPBuildScaledLayerFromCAML(caPath, window.bounds.size, &doc);
        if (!l) continue;
        [container addSublayer:l];
        [docs addObject:doc];
        if (kindList.length) [kindList appendString:@"+"];
        [kindList appendString:[caPath lastPathComponent]];
    }
    if (docs.count == 0) {
        PPSetDebug(@"all .ca parses failed");
        return;
    }
    gDocs = docs;

    [window.layer addSublayer:container];
    gPosterLayer = container;

    PPResolveStatesFromDocs(docs);

    NSMutableString *summary = [NSMutableString string];
    for (NSUInteger i = 0; i < docs.count; i++) {
        if (i) [summary appendString:@" | "];
        [summary appendFormat:@"doc%lu states=[%@]", (unsigned long)i,
            [docs[i].stateOrder componentsJoinedByString:@","]];
    }
    [summary appendFormat:@" | from=%@ to=%@", gFromState ?: @"-", gToState ?: @"-"];
    [summary writeToFile:@"/var/mobile/pocketplayer-states.log"
              atomically:YES encoding:NSUTF8StringEncoding error:nil];

    PPApplyProgress(0.0);
    NSInteger imgs = 0, miss = 0, em = 0, cells = 0;
    for (PPCAMLDocument *d in docs) {
        imgs  += d.imagesLoaded;
        miss  += d.imagesMissing;
        em    += d.emittersBuilt;
        cells += d.cellsBuilt;
    }
    PPSetDebug(@"%lu .ca img=%ld miss=%ld em=%ld cells=%ld",
               (unsigned long)docs.count,
               (long)imgs, (long)miss, (long)em, (long)cells);
}

static void PPCleanupStaleLayersInWindow(UIWindow *window, CALayer *keep) {
    if (!window) return;
    for (CALayer *l in [window.layer.sublayers copy]) {
        if (l != keep && l != gHomePosterLayer && PPIsOurLayerName(l.name)) {
            [l removeFromSuperlayer];
        }
    }
}

// =====================================================================
// Poster install — into the HOME-SCREEN WINDOW's layer (frozen at Unlock)
// =====================================================================

// On iOS 15 the home screen lives in its own UIWindow (commonly named
// SBHomeScreenWindow / SBHomeScreenRootViewController's view's window).
// We pick the lowest-windowLevel window whose class name contains
// "HomeScreen", or fall back to the application's first window that
// isn't the cover-sheet window we already use.
static UIWindow *PPFindHomeScreenWindow(void) {
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
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        windows = [UIApplication sharedApplication].windows;
        #pragma clang diagnostic pop
    }
    for (UIWindow *w in windows) {
        NSString *cls = NSStringFromClass([w class]);
        if (cls && [cls containsString:@"HomeScreen"]) return w;
    }
    return nil;
}

// Installs a SECOND chest poster on the home-screen window, frozen at
// the Unlock state (chest fully open). This is what the user sees AFTER
// the cover sheet finishes sliding away — the icons/dock get composed
// on top of an already-open chest.
//
// We don't drive this one with progress; it just applies state=Unlock
// once at install time.
static void PPInstallPosterIntoHomeWindow(UIWindow *window) {
    if (!window) return;
    gHomeHostWindow = window;

    // Wipe any prior home-poster from this window.
    for (CALayer *l in [window.layer.sublayers copy]) {
        if (l != gHomePosterLayer && PPIsOurLayerName(l.name)) {
            [l removeFromSuperlayer];
        }
    }

    NSString *bundle  = PPFindFirstWallpaperBundle();
    NSArray<NSString *> *caBundles = bundle ? PPFindAllCABundles(bundle) : @[];
    if (caBundles.count == 0) return;

    CALayer *container = [CALayer layer];
    container.name = @"PocketPlayerHomeLayer";
    container.bounds = window.bounds;
    container.position = CGPointMake(window.bounds.size.width / 2.0,
                                     window.bounds.size.height / 2.0);
    // zPosition = -1000 puts us at the very back of the home window so
    // dock + icons + folders + spotlight all render on top of us.
    container.zPosition = -1000;
    container.masksToBounds = NO;
    container.geometryFlipped = YES;

    NSMutableArray<PPCAMLDocument *> *docs = [NSMutableArray array];
    for (NSString *caPath in caBundles) {
        PPCAMLDocument *doc = nil;
        CALayer *l = PPBuildScaledLayerFromCAML(caPath, window.bounds.size, &doc);
        if (!l) continue;
        [container addSublayer:l];
        [docs addObject:doc];
    }
    if (docs.count == 0) return;
    gHomeDocs = docs;

    [window.layer addSublayer:container];
    gHomePosterLayer = container;

    // Make sure state names are resolved using whichever stack first
    // declares them (cover-sheet stack wins, but if it's empty the home
    // stack provides them).
    if (!gFromState && !gToState) {
        PPResolveStatesFromDocs(docs);
    }

    // Apply current progress so a re-installed home poster catches up
    // to whatever the gesture is doing right now.
    if (gToState) {
        for (PPCAMLDocument *d in docs) {
            if (gFromState) {
                [d applyTransitionFromState:gFromState toState:gToState progress:gLastProgress];
            } else {
                [d applyState:gToState progress:gLastProgress];
            }
        }
    }
}

// True if a layer was created by us OR by any prior incarnation of this
// tweak (the previous one was called PosterPlayer with an 's'). Older
// builds also occasionally used unprefixed names; match anything that
// looks like one of ours.
static BOOL PPIsOurLayerName(NSString *n) {
    if (!n) return NO;
    return [n isEqualToString:@"PocketPlayerLayer"]
        || [n isEqualToString:@"PosterPlayerLayer"]
        || [n hasPrefix:@"PocketPlayer"]
        || [n hasPrefix:@"PosterPlayer"];
}

// Recursively walks a CALayer tree and removes any sublayer that looks
// like one of ours, except the two we want to keep. Plain C, no blocks,
// to avoid -Warc-retain-cycles on self-referential captures.
static void PPNukeStaleLayersInTree(CALayer *root, CALayer *keep) {
    if (!root) return;
    for (CALayer *l in [root.sublayers copy]) {
        if (l != keep && l != gHomePosterLayer && PPIsOurLayerName(l.name)) {
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

// Hides system wallpaper views (the user's own background image) so
// our poster shines through. Walks the cover-sheet view's subview tree
// and hides anything whose class name contains "Wallpaper". Reversible:
// if you uninstall the tweak, the views just get hidden=NO again at next
// respring.
static void PPHideSystemWallpapersIn(UIView *root) {
    if (!root) return;
    NSString *cls = NSStringFromClass([root class]);
    if (cls && [cls containsString:@"Wallpaper"]) {
        // Don't hide our own debug label or container.
        if (root.tag != 0xCAFE) {
            root.hidden = YES;
        }
    }
    for (UIView *v in root.subviews) {
        PPHideSystemWallpapersIn(v);
    }
}

// Same but at window level — walks every window in every scene.
static void PPHideAllSystemWallpapers(void) {
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
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        windows = [UIApplication sharedApplication].windows;
        #pragma clang diagnostic pop
    }
    for (UIWindow *w in windows) {
        // Only hide wallpapers in the lock-screen / cover-sheet windows,
        // not on the home screen — otherwise the home wallpaper goes too.
        NSString *wcls = NSStringFromClass([w class]);
        if (!wcls) continue;
        if ([wcls containsString:@"CoverSheet"]
            || [wcls containsString:@"Lock"]
            || [wcls containsString:@"DashBoard"]) {
            PPHideSystemWallpapersIn(w);
        }
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

    // Re-hide system wallpaper views — iOS occasionally un-hides them
    // during the unlock transition. Throttled to ~3x per second, since
    // walking every window every frame is wasted work.
    static CFTimeInterval sLastWPHide = 0;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - sLastWPHide > 0.3) {
        PPHideAllSystemWallpapers();
        sLastWPHide = now;
    }

    // Install / re-install the home-screen poster lazily, since the
    // home window may not exist when the cover-sheet first comes up.
    if (!gHomePosterLayer || gHomePosterLayer.superlayer == nil) {
        UIWindow *hw = PPFindHomeScreenWindow();
        if (hw) PPInstallPosterIntoHomeWindow(hw);
    }

    // Keep poster sized to the window on rotation. We scale every direct
    // child of `container` (each is a CAML root from one .ca bundle) to
    // fit the new size.
    UIWindow *win = gHostWindow;
    if (gPosterLayer && win && gPosterLayer.superlayer == win.layer) {
        if (!CGSizeEqualToSize(gPosterLayer.bounds.size, win.bounds.size)) {
            gPosterLayer.bounds = win.bounds;
            gPosterLayer.position = CGPointMake(win.bounds.size.width / 2.0,
                                                 win.bounds.size.height / 2.0);
            for (CALayer *root in gPosterLayer.sublayers) {
                CGRect rb = root.bounds;
                if (rb.size.width <= 0 || rb.size.height <= 0) rb = CGRectMake(0, 0, 390, 844);
                CGFloat sx = win.bounds.size.width  / rb.size.width;
                CGFloat sy = win.bounds.size.height / rb.size.height;
                CGFloat s  = MAX(sx, sy);
                root.position = CGPointMake(win.bounds.size.width  / 2.0,
                                            win.bounds.size.height / 2.0);
                root.transform = CATransform3DMakeScale(s, s, 1.0);
            }
        }
    }

    // Same for the home-screen poster.
    UIWindow *hwin = gHomeHostWindow;
    if (gHomePosterLayer && hwin && gHomePosterLayer.superlayer == hwin.layer) {
        if (!CGSizeEqualToSize(gHomePosterLayer.bounds.size, hwin.bounds.size)) {
            gHomePosterLayer.bounds = hwin.bounds;
            gHomePosterLayer.position = CGPointMake(hwin.bounds.size.width / 2.0,
                                                    hwin.bounds.size.height / 2.0);
            for (CALayer *root in gHomePosterLayer.sublayers) {
                CGRect rb = root.bounds;
                if (rb.size.width <= 0 || rb.size.height <= 0) rb = CGRectMake(0, 0, 390, 844);
                CGFloat sx = hwin.bounds.size.width  / rb.size.width;
                CGFloat sy = hwin.bounds.size.height / rb.size.height;
                CGFloat s  = MAX(sx, sy);
                root.position = CGPointMake(hwin.bounds.size.width  / 2.0,
                                            hwin.bounds.size.height / 2.0);
                root.transform = CATransform3DMakeScale(s, s, 1.0);
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

    // Hide the user's stock wallpaper so our poster is the lockscreen.
    PPHideAllSystemWallpapers();

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

    // Cover sheet just (re-)appeared - whether from lock or from
    // re-lock-after-unlock, the user is now looking at the lock screen
    // and our poster must be visible. The snap-hide in PPApplyProgress
    // only fires at progress >= 0.99.
    if (gPosterLayer) gPosterLayer.hidden = NO;
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
