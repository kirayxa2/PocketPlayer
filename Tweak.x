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
static BOOL const kPPDebugLabel = NO;

// We always rebuild emitters from CAML — this isn't a debug option,
// it's needed to make particles render reliably in SpringBoard on
// iOS 15 (see PPDebugAnnotateEmitters comment for the reason). This
// flag is now just a kill-switch; keep it YES for production.
static BOOL const kPPDebugEmitters = YES;

// Production: keep emitter at its CAML-authored position (no pinning
// to a debug location). Set to YES only when investigating offscreen-
// emitter issues with a new wallpaper.
static BOOL const kPPDebugMoveEmitterIntoView = NO;

// Reference CAEmitterLayer for proving the CA particle machinery
// itself works. Off in release builds. Set to YES if a new wallpaper
// shows zero particles and we need to test whether CAEmitterLayer is
// emitting AT ALL.
static BOOL const kPPDebugInjectTestEmitter = NO;

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
static void PPDebugAnnotateEmitters(CALayer *root, UIWindow *window);
static void PPRegisterApplyListener(void);

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

// Append one diagnostic line to /var/mobile/pocketplayer-emitters.log.
// Different from PPSetDebug() because that overwrites; this appends.
//
// Defined here (above PPInstallTestEmitter) so all subsequent emitter
// helpers can call it without needing forward declarations.
static void PPEmitterLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *withNL = [s stringByAppendingString:@"\n"];
    NSString *path = @"/var/mobile/pocketplayer-emitters.log";
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:path];
    }
    if (fh) {
        @try {
            [fh seekToEndOfFile];
            [fh writeData:[withNL dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } @catch (NSException *e) {}
    }
}

// Build a tiny CGImage of the given size and uniform color. Used so
// the reference test emitter has a guaranteed-visible particle texture
// that doesn't depend on any asset on disk.
static CGImageRef PPMakeSolidColorCGImage(CGSize size, UIColor *color) {
    UIGraphicsBeginImageContextWithOptions(size, NO, 0);
    [color setFill];
    UIRectFill(CGRectMake(0, 0, size.width, size.height));
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return CGImageRetain(img.CGImage);
}

// Inject a hand-built CAEmitterLayer into the host view's layer at
// position (50%, 50%). It emits one solid-red 10pt square every 0.5s
// going straight up at 60pt/s. This is the simplest possible test of
// "do CAEmitterLayers render inside SpringBoard on iOS 15 at all".
//
// If you see red squares streaming up from the middle of the screen,
// CA emitters work — and our CAML emitters fail because of how their
// parameters get parsed/composed. If you don't see anything, CA
// emitters are non-functional in this context and we need a software
// particle system instead.
static void PPInstallTestEmitter(UIView *host) {
    if (!kPPDebugInjectTestEmitter) return;

    // Avoid stacking duplicates if didMoveToWindow fires twice.
    for (CALayer *l in [host.layer.sublayers copy]) {
        if ([l.name isEqualToString:@"PPTestEmitter"]) {
            [l removeFromSuperlayer];
        }
    }

    CAEmitterLayer *em = [CAEmitterLayer layer];
    em.name           = @"PPTestEmitter";
    em.bounds         = CGRectMake(0, 0, 20, 20);
    em.position       = CGPointMake(host.bounds.size.width / 2.0,
                                    host.bounds.size.height / 2.0);
    em.zPosition      = 99999;       // above everything (incl. our poster)
    em.emitterShape   = kCAEmitterLayerPoint;
    em.emitterMode    = kCAEmitterLayerOutline;
    em.renderMode     = kCAEmitterLayerAdditive;
    em.emitterSize    = CGSizeMake(2, 2);
    em.lifetime       = 1.0;
    em.birthRate      = 1.0;
    em.speed          = 1.0;

    CAEmitterCell *cell = [CAEmitterCell emitterCell];
    cell.name           = @"PPTestCell";
    cell.birthRate      = 4.0;             // 4 particles/sec
    cell.lifetime       = 4.0;             // each lasts 4s -> visible trail
    cell.lifetimeRange  = 0.0;
    cell.velocity       = 60.0;
    cell.velocityRange  = 0.0;
    cell.scale          = 1.0;
    cell.scaleRange     = 0.0;
    cell.alphaRange     = 0.0;
    cell.alphaSpeed     = 0.0;
    // Straight up. CAEmitterCell uses radians and the convention is:
    // emissionLongitude = 0 means +X, -pi/2 means up (-Y in screen space).
    cell.emissionLongitude = -M_PI_2;
    cell.emissionRange     = 0.0;          // perfectly straight
    // Solid red CGImage, 10x10pt. Created here, retained by the cell.
    CGImageRef cg = PPMakeSolidColorCGImage(CGSizeMake(10, 10), [UIColor redColor]);
    cell.contents = (__bridge_transfer id)cg;
    cell.contentsScale = 1.0;
    [cell setValue:@"plane" forKey:@"particleType"];

    em.emitterCells = @[cell];

    // Crucial: anchor beginTime in the layer's own time-space, not
    // the global media-time before the layer was attached.
    em.beginTime = [em convertTime:CACurrentMediaTime() fromLayer:nil];

    // Magenta border so we can see the layer rect even before any
    // particles fire.
    em.borderColor = [UIColor cyanColor].CGColor;
    em.borderWidth = 1.0;

    [host.layer addSublayer:em];

    PPEmitterLog(@"=== test-emitter installed at center of %@ ===",
                 NSStringFromClass([host class]));
}

// =====================================================================
// Emitter debug
// =====================================================================

// PPEmitterLog defined above (before PPInstallTestEmitter so it can
// call it without a forward declaration).

// Recursive walk that collects every CAEmitterLayer under `root`.
// Implemented here as a plain C-style helper instead of as an ObjC
// category on CALayer because Theos linker behaviour around categories
// declared in a separate .m file is unreliable - a category can be
// stripped by dead-code-elimination if no code in the same translation
// unit references it.
static void PPCollectEmittersRecursive(CALayer *root, NSMutableArray *out) {
    if (!root) return;
    if ([root isKindOfClass:[CAEmitterLayer class]]) {
        [out addObject:root];
    }
    for (CALayer *l in root.sublayers) {
        PPCollectEmittersRecursive(l, out);
    }
}

// For each CAEmitterLayer found in `root`'s subtree:
//
//   1. Add a thin magenta border so we can SEE the bounds rectangle
//      after all parent transforms have composed. If a wallpaper claims
//      "particles aren't appearing" but the magenta box is offscreen,
//      we know it's a coordinate issue, not a particle issue.
//   2. Boost visibility of its cells (birthRate x5, minimum particle
//      scale 2.0pt, opaque alpha) so even configurations that emit
//      mostly-transparent or sub-pixel particles still produce visible
//      output during debugging.
//   3. Append one line per emitter to /var/mobile/pocketplayer-emitters.log
//      with a translation of its position into WINDOW coordinates,
//      so we can compare against the actual screen size.
// PPDebugAnnotateEmitters
//
// PROOF FROM DIAGNOSTICS:
//   * The hand-built reference CAEmitterLayer (PPInstallTestEmitter)
//     at the screen center DOES emit particles correctly on iOS 15.
//   * The CAML-parsed CAEmitterLayer in Mario Galaxy does NOT, even
//     after hoisting it onto a parent layer with no transform chain.
//
// What's actually different between the two? The reference emitter
// is built up from scratch with strongly-typed property setters
// (em.emitterCells = @[cell]), while the CAML emitter has its cells
// configured through KVC (setValue:@... forKey:...). On iOS 15
// CAEmitterLayer caches its cell list state when the layer is
// committed in a CATransaction, and re-parenting after that point
// does NOT cause the cell state to be re-uploaded to the renderer.
//
// SO the only reliable fix is: read the parsed CAEmitterCell back
// out of CAML, then BUILD A FRESH CAEmitterLayer + CAEmitterCell
// from scratch, copy across only the values we need, and replace
// the original. The new layer has clean state and emits correctly.
//
// Step-by-step:
//   1. Find every CAEmitterLayer in the tree.
//   2. Read its cell array, capture each cell's contents (CGImage)
//      and a small fixed set of attributes (birthRate, lifetime,
//      velocity, emissionLongitude, emissionRange, scale, color).
//   3. Compute the original window-space position of the emitter.
//   4. Remove the original emitter from the tree entirely.
//   5. Build a brand-new CAEmitterLayer parented to `root` (our
//      top-level container at window level) and stack new
//      CAEmitterCells with the captured values.
//   6. Position the new emitter at the original window-space center.
static void PPDebugAnnotateEmitters(CALayer *root, UIWindow *window) {
    if (!kPPDebugEmitters || !root) return;

    NSMutableArray *emitters = [NSMutableArray array];
    PPCollectEmittersRecursive(root, emitters);
    PPEmitterLog(@"=== annotate: found %lu emitter(s) under %@ ===",
                 (unsigned long)emitters.count, root.name ?: @"(unnamed)");
    if (emitters.count == 0) return;

    NSInteger idx = 0;
    for (CAEmitterLayer *oldEm in emitters) {
        // 1) Original window-space position.
        CGPoint windowSpaceCenter = CGPointZero;
        if (oldEm.superlayer && window) {
            windowSpaceCenter = [oldEm convertPoint:CGPointZero toLayer:window.layer];
        }

        // 2) Capture attributes we want to copy.
        NSArray<CAEmitterCell *> *oldCells = oldEm.emitterCells ?: @[];
        CGSize  oldEmitterSize = oldEm.emitterSize;
        NSString *oldShape = oldEm.emitterShape ?: kCAEmitterLayerPoint;
        NSString *oldMode  = oldEm.emitterMode  ?: kCAEmitterLayerVolume;
        NSString *oldRender = oldEm.renderMode  ?: kCAEmitterLayerUnordered;

        // 3) Build a fresh CAEmitterLayer.
        CAEmitterLayer *newEm = [CAEmitterLayer layer];
        newEm.name        = [NSString stringWithFormat:@"PocketPlayerEmitter%ld", (long)idx];
        // Use a generous bounds so particles are not clipped to a tiny
        // rectangle. The CAML's emitter bounds are only used as the
        // emission shape's bounds (via emitterSize), not as a render
        // clip rectangle. Most CAML emitters have tiny bounds (like
        // Mario's 21x18) which on iOS 15 sometimes cause culling.
        newEm.bounds      = CGRectMake(0, 0, 200, 200);
        newEm.emitterShape = oldShape;
        newEm.emitterMode  = oldMode;
        newEm.renderMode   = oldRender;
        // emitterSize is what defines the spawn-region, so keep CAML's
        // value (clamped to something visible).
        newEm.emitterSize  = CGSizeMake(MAX(oldEmitterSize.width,  4),
                                        MAX(oldEmitterSize.height, 4));
        newEm.lifetime  = 1.0;
        newEm.birthRate = 1.0;
        newEm.speed     = 1.0;
        newEm.scale     = 1.0;
        newEm.masksToBounds = NO;
        // Render emitter ABOVE the rest of the CAML tree (Mario, planet,
        // chest etc.) so particles aren't z-occluded by static layers.
        // 9000 < 9999 (debug label), well above any CAML layer's
        // implicit zPosition=0.
        newEm.zPosition = 9000;

        // 4) Build fresh cells from captured CAML cells.
        NSMutableArray<CAEmitterCell *> *newCells = [NSMutableArray array];
        for (CAEmitterCell *oldCell in oldCells) {
            CAEmitterCell *nc = [CAEmitterCell emitterCell];
            nc.name              = oldCell.name ?: @"cell";
            nc.contents          = oldCell.contents;
            nc.contentsRect      = oldCell.contentsRect;
            // contentsScale is critical — it divides the texture's
            // pixel size by this number to get the on-screen point
            // size. CAML wallpapers ship huge retina textures (e.g.
            // Mario's starbit.webp is 403x467px) and rely on a high
            // contentsScale (e.g. 16.67) to bring the particle down
            // to ~24x28pt on screen. If we force contentsScale=1.0
            // the particle becomes 403x467 POINTS — a screen-filling
            // square. So preserve whatever the cell came in with;
            // fall back to a sensible auto-scale only when CAML
            // gave us nothing.
            CGFloat oldCS = oldCell.contentsScale;
            if (oldCS > 0.5 && oldCS < 200.0) {
                nc.contentsScale = oldCS;
            } else {
                // Auto-compute so the particle is at most ~32pt on
                // screen, regardless of the texture's pixel size.
                CGFloat px = 0;
                if ([oldCell.contents respondsToSelector:@selector(width)]) {
                    px = (CGFloat)CGImageGetWidth((__bridge CGImageRef)oldCell.contents);
                }
                if (px > 64.0) {
                    nc.contentsScale = px / 32.0;
                } else {
                    nc.contentsScale = 1.0;
                }
            }
            nc.birthRate         = oldCell.birthRate;
            nc.lifetime          = oldCell.lifetime > 0 ? oldCell.lifetime : 4.0;
            nc.lifetimeRange     = oldCell.lifetimeRange;
            nc.velocity          = oldCell.velocity != 0 ? oldCell.velocity : 60.0;
            nc.velocityRange     = oldCell.velocityRange;
            nc.scale             = oldCell.scale > 0 ? oldCell.scale : 1.0;
            nc.scaleRange        = oldCell.scaleRange;
            nc.scaleSpeed        = oldCell.scaleSpeed;
            nc.spin              = oldCell.spin;
            nc.spinRange         = oldCell.spinRange;
            nc.emissionLongitude = oldCell.emissionLongitude;
            nc.emissionLatitude  = oldCell.emissionLatitude;
            nc.emissionRange     = oldCell.emissionRange != 0 ? oldCell.emissionRange : (M_PI / 4);
            // Preserve color decay as authored. The default
            // CAEmitterCell alpha/redSpeed/etc. are 0 so most CAML
            // wallpapers will have constant-color particles anyway.
            nc.alphaRange        = oldCell.alphaRange;
            nc.alphaSpeed        = oldCell.alphaSpeed;
            nc.color             = oldCell.color ?: [UIColor whiteColor].CGColor;
            // Copy color-channel ranges & speeds via KVC since they're
            // exposed as KVC-only on CAEmitterCell.
            @try {
                NSArray *channelKeys = @[
                    @"redRange",   @"greenRange",   @"blueRange",
                    @"redSpeed",   @"greenSpeed",   @"blueSpeed",
                ];
                for (NSString *k in channelKeys) {
                    NSNumber *v = [oldCell valueForKey:k];
                    if (v) [nc setValue:v forKey:k];
                }
            } @catch (NSException *e) {}
            // Acceleration too (xAcceleration / yAcceleration / zAcceleration).
            @try {
                NSArray *accelKeys = @[
                    @"xAcceleration", @"yAcceleration", @"zAcceleration",
                ];
                for (NSString *k in accelKeys) {
                    NSNumber *v = [oldCell valueForKey:k];
                    if (v) [nc setValue:v forKey:k];
                }
            } @catch (NSException *e) {}
            // Force particleType to "plane" via KVC so the texture
            // renders even if CAML didn't specify particleType.
            @try { [nc setValue:@"plane" forKey:@"particleType"]; }
            @catch (NSException *e) {}
            [newCells addObject:nc];
        }

        // If CAML had no cells (unlikely, but defensive), skip - no
        // fallback debug particle in production.
        if (newCells.count == 0) {
            continue;
        }

        // 5) Attach cells BEFORE adding to superlayer (this matters on
        //    iOS 15 — cells set after addSublayer: sometimes don't
        //    upload to the renderer cleanly).
        newEm.emitterCells = newCells;

        // 6) Place at the original window-space position.
        if (window && root) {
            CGPoint targetWP = windowSpaceCenter;
            // If MoveEmitterIntoView is on, pin to 75%/75% so we always
            // see something during debug.
            if (kPPDebugMoveEmitterIntoView) {
                targetWP = CGPointMake(window.bounds.size.width  * 0.75,
                                       window.bounds.size.height * 0.75);
            }
            CGPoint pInRoot = [root convertPoint:targetWP fromLayer:window.layer];
            newEm.position = pInRoot;
        }

        // 7) Pick the host layer.
        //    PROVED: test-emitter on gCoverSheetView.layer DOES emit
        //    on the lockscreen. Mario's emitter on gPosterLayer
        //    (which lives on the cover-sheet WINDOW) does NOT —
        //    because SpringBoard freezes layer-time on the cover-
        //    sheet window during locked-presented state, but NOT
        //    on the cover-sheet view itself.
        //    So we attach emitters to the cover-sheet view's layer
        //    when we have one. They'll slide up with the unlock
        //    swipe (acceptable — the chest does too via the home
        //    poster), but at least they're VISIBLE.
        CALayer *emitterHost = root;
        if (gCoverSheetView && gCoverSheetView.layer) {
            emitterHost = gCoverSheetView.layer;
        }

        // Re-translate position into emitterHost's coordinate space.
        if (emitterHost != root && window) {
            CGPoint inWin = [root convertPoint:newEm.position toLayer:window.layer];
            CGPoint inHost = [emitterHost convertPoint:inWin fromLayer:window.layer];
            newEm.position = inHost;
            newEm.zPosition = 9000;
        }

        [emitterHost addSublayer:newEm];
        newEm.beginTime = [newEm convertTime:CACurrentMediaTime() fromLayer:nil];

        // 8) Remove the old emitter completely so we don't have two.
        [oldEm removeFromSuperlayer];

        CGPoint inWindow = [newEm convertPoint:CGPointZero toLayer:window.layer];
        PPEmitterLog(@"emitter[%ld] REBUILT pos=%@ inWindow=%@ cells=%lu emitterSize=%@",
                     (long)idx,
                     NSStringFromCGPoint(newEm.position),
                     NSStringFromCGPoint(inWindow),
                     (unsigned long)newCells.count,
                     NSStringFromCGSize(newEm.emitterSize));
        idx++;
    }
}

// Re-prime every CAEmitterLayer's beginTime in `root`'s subtree
// AND restore its time / visibility state. On iOS 15 inside the
// cover-sheet window, the layer-time chain that the emitter
// inherits gets stuck (cover-sheet view's parent runs `speed=0`
// during the unlock-presented state, freezing every CAEmitterLayer
// underneath it). Each frame we forcibly:
//
//   * .speed = 1.0   (ignore inherited time-pause from parent)
//   * .hidden = NO   (ignore any spurious hide done by SpringBoard)
//   * .lifetime = 1  (don't let CAML's global multiplier on the
//                     emitter layer kill particles instantly)
//   * .beginTime advanced to layer-local now
//
// This is called per-frame from the CADisplayLink tick when the
// cover-sheet poster is visible. It's cheap (just iterates layers).
static void PPRePrimeEmittersIn(CALayer *root) {
    if (!root) return;
    NSMutableArray *emitters = [NSMutableArray array];
    PPCollectEmittersRecursive(root, emitters);
    for (CAEmitterLayer *em in emitters) {
        em.speed     = 1.0;
        em.hidden    = NO;
        em.lifetime  = 1.0;
        em.birthRate = 1.0;
        em.beginTime = [em convertTime:CACurrentMediaTime() fromLayer:nil];
    }
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

    // The applyState:/applyTransition... calls feed into KVC
    // (-[CALayer setValue:forKeyPath:]), which throws NSException
    // on an unknown keyPath. Catch it here so a single bad CAML
    // doesn't take down SpringBoard on every gesture frame.
    @try {
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
    } @catch (NSException *e) {
        // Disable the bad doc(s) so we don't keep throwing every frame.
        // Safer than trying to rescue: subsequent gestures see no
        // animation, but the static layers stay put and SpringBoard
        // survives. Next respring rebuilds from scratch.
        gFromState = nil;
        gToState   = nil;
        PPSetDebug(@"applyProgress: %@ -- frozen", e.name);
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
    @try {
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
    } @catch (NSException *e) {
        gFromState = nil;
        gToState   = nil;
        PPSetDebug(@"applyProgress(snap): %@ -- frozen", e.name);
    }
    if (gPosterLayer) {
        BOOL wasHidden = gPosterLayer.hidden;
        gPosterLayer.hidden = fullyUnlocked;
        // Going from hidden -> visible (i.e. user just locked the
        // device again, cover sheet is being re-presented). Re-prime
        // every emitter's beginTime, otherwise their timeline is
        // still paused at the moment we hid the poster, and they
        // emit zero particles until the next respring.
        if (wasHidden && !fullyUnlocked) {
            PPRePrimeEmittersIn(gPosterLayer);
        }
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
    // Force speed=1 so the cover-sheet window's frozen-time state
    // (which SpringBoard sets to speed=0 during locked presentation)
    // doesn't cascade into our subtree and freeze the emitters.
    gPosterLayer.speed = 1.0;

    PPResolveStatesFromDocs(docs);

    // Annotate every emitter with a magenta border (and boost particle
    // visibility) so we can SEE physically where emitters end up after
    // all the parent transforms compose. Disabled in release builds.
    PPDebugAnnotateEmitters(container, window);

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

    // Same emitter debug annotation on the home-window poster.
    PPDebugAnnotateEmitters(container, window);

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

    // Per-frame: keep cover-sheet emitters alive. The cover-sheet
    // window inherits a frozen layer-time chain from SpringBoard's
    // unlock-presented state, which on iOS 15 freezes every
    // CAEmitterLayer underneath it. Forcing speed=1, hidden=NO and
    // a fresh beginTime each tick overrides that. Only when the
    // poster is actually visible (not in the post-unlock snap-hide
    // window) — otherwise we'd waste CPU emitting offscreen.
    if (gPosterLayer && !gPosterLayer.hidden) {
        PPRePrimeEmittersIn(gPosterLayer);
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
    PPInstallTestEmitter(self);
    PPStartDisplayLink();
    PPRegisterApplyListener();

    // Install poster directly on the cover sheet WINDOW. The window does
    // not move during unlock; only the cover sheet view (its child) does.
    //
    // The whole CAML pipeline is wrapped here too -- if a wallpaper has
    // a state value with a key path CALayer doesn't recognise, KVC
    // throws inside applyState:/applyTransition:, and an uncaught
    // NSException inside SpringBoard means safe mode for the user. We
    // already guard the apply path; this guard covers the boot path
    // (left over from a previous bad install) so SpringBoard never
    // dies on a wallpaper at startup.
    UIWindow *win = self.window;
    if (win && (!gPosterLayer || gPosterLayer.superlayer != win.layer)) {
        @try {
            PPInstallPosterIntoWindow(win);
            PPCleanupStaleLayersInWindow(win, gPosterLayer);
            // One more sweep AFTER install, so anything that was lurking in
            // a sibling window is removed even if it tried to reattach.
            PPNukeAllStaleLayersEverywhere(gPosterLayer);
        } @catch (NSException *e) {
            PPSetDebug(@"install threw on boot: %@ -- %@", e.name, e.reason);
            // Disable the broken doc so PPApplyProgress doesn't hit it.
            gFromState = nil;
            gToState   = nil;
        }
    }

    // Cover sheet just (re-)appeared - whether from lock or from
    // re-lock-after-unlock, the user is now looking at the lock screen
    // and our poster must be visible. The snap-hide in PPApplyProgress
    // only fires at progress >= 0.99.
    if (gPosterLayer) {
        gPosterLayer.hidden = NO;
        // Re-prime emitters every time the cover sheet remounts —
        // covers the case of unlock-then-relock where the previous
        // cycle paused the emitter timeline.
        PPRePrimeEmittersIn(gPosterLayer);
    }
}

- (void)layoutSubviews {
    %orig;
    if (gDebugLabel.superview == self) {
        gDebugLabel.frame = CGRectMake(8, 60, self.bounds.size.width - 16, 22);
    }
    UIWindow *win = self.window;
    if (win && (!gPosterLayer || gPosterLayer.superlayer != win.layer)) {
        @try {
            PPInstallPosterIntoWindow(win);
            PPNukeAllStaleLayersEverywhere(gPosterLayer);
        } @catch (NSException *e) {
            PPSetDebug(@"install threw on layout: %@", e.name);
            gFromState = nil;
            gToState   = nil;
        }
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

// =====================================================================
// Apply bridge — listen for two SEPARATE Darwin notifications from the
// PocketPoster companion app:
//
//   "com.vortex.pocketplayer.apply"    -- copy a *.wallpaper bundle
//                                         into the active PosterPlayer
//                                         slot. NO respring. The user
//                                         sees the new wallpaper in
//                                         our overlay immediately, and
//                                         everywhere else on the next
//                                         natural respring.
//
//   "com.vortex.pocketplayer.respring" -- kill SpringBoard now. Same
//                                         thing scripts/deploy.sh does
//                                         at the end. Sent only when
//                                         the user explicitly taps
//                                         "Respring" in the app, so
//                                         users on fragile jailbreaks
//                                         can opt out and apply on a
//                                         later natural reboot.
//
// The apply path is intentionally hands-off w.r.t. the rest of this
// file: we only touch /var/mobile/Library/PosterPlayer/active/...
// (replacing the .wallpaper bundle there) and trigger our existing
// PPInstallPosterIntoWindow / PPInstallPosterIntoHomeWindow paths.
// The CAML parser, emitter rebuild, animations, system-wallpaper
// hide, etc. all run unmodified -- we just feed them a new bundle.
// =====================================================================

#import <notify.h>
#import <fcntl.h>
#import <signal.h>
#import <unistd.h>

static NSString *const kPPApplyManifestPath =
    @"/var/mobile/Library/PocketPlayer/apply.plist";
static const char *const kPPApplyDarwinName    = "com.vortex.pocketplayer.apply";
static const char *const kPPRespringDarwinName = "com.vortex.pocketplayer.respring";

// kill -9 ourselves. launchd brings SpringBoard back in ~3s and on
// the next launch our %ctor reads the (already-updated) PosterPlayer
// slot, PosterKit's own startup picks up the new bundle for the home
// screen and behind the lock UI, and our overlay rebuilds from disk.
//
// Only called from the explicit "respring" notification path, never
// automatically. The user has to tap the Respring button in the app.
static void PPRespringNow(void) {
    PPSetDebug(@"respring requested by app");
    [@"respring requested" writeToFile:@"/var/mobile/pocketplayer-apply.log"
                            atomically:YES
                              encoding:NSUTF8StringEncoding
                                 error:NULL];
    // 200ms grace so any pending log flushes hit disk first.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        kill(getpid(), SIGKILL);
    });
}

// Atomically replace the .wallpaper bundle inside
//     /var/mobile/Library/PosterPlayer/active/versions/1/contents/
// with the one at `srcBundle`. Returns YES on success.
//
// We deliberately do NOT touch sibling files (Wallpaper.plist,
// .com.apple.posterkit.*, com.apple.posterkit.*) that PosterPlayer
// manages — only the *.wallpaper folder is swapped in/out.
static BOOL PPInstallBundleIntoActiveSlot(NSString *srcBundle) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (!srcBundle.length) return NO;

    BOOL isDir = NO;
    if (![fm fileExistsAtPath:srcBundle isDirectory:&isDir] || !isDir) {
        NSString *msg = [NSString stringWithFormat:@"src not a dir: %@", srcBundle];
        [msg writeToFile:@"/var/mobile/pocketplayer-apply.log"
              atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return NO;
    }

    NSString *contents = kPPWallpaperRoot;
    [fm createDirectoryAtPath:contents
  withIntermediateDirectories:YES
                   attributes:nil
                        error:NULL];

    // Remove any pre-existing *.wallpaper sibling so PosterPlayer
    // doesn't end up with two competing bundles.
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

    NSString *ok = [NSString stringWithFormat:@"copied %@ -> %@",
                    [srcBundle lastPathComponent], contents];
    [ok writeToFile:@"/var/mobile/pocketplayer-apply.log"
         atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    return YES;
}

// Append a line to the apply log file. Used for crash forensics --
// if the live-rebuild step ever throws (CAML with a keyPath the
// runtime doesn't recognise, etc.), we WILL see it here even though
// the @try below quietly recovers.
static void PPApplyLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *with = [NSString stringWithFormat:@"%@: %@\n",
                      [NSDate date], s];
    NSString *path = @"/var/mobile/pocketplayer-apply.log";
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:path];
    }
    if (fh) {
        @try {
            [fh seekToEndOfFile];
            [fh writeData:[with dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } @catch (NSException *e) {}
    }
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

        // Manifest is one-shot — delete so the listener doesn't loop
        // through it again on every fs event / poll tick.
        [[NSFileManager defaultManager] removeItemAtPath:kPPApplyManifestPath
                                                   error:NULL];

        // From here on, every step that touches the wallpaper bundle's
        // CAML is wrapped in @try/@catch. Why: PPInstallPosterIntoWindow
        // -> PPCAMLParser -> PPCAMLDocument applyState/applyTransition,
        // which calls -[CALayer setValue:forKeyPath:]. If a wallpaper's
        // <LKStateSetValue keyPath="..."> uses a key path CALayer doesn't
        // recognise (private keys, typos, future-iOS keys we don't
        // support yet), KVC throws NSUnknownKeyException. With the
        // tweak running INSIDE SpringBoard, that exception is uncaught
        // -> objc_terminate() -> SpringBoard crash -> safe mode for
        // the user. Catching it here means a bad wallpaper at worst
        // leaves the previous overlay in place; the user can pick a
        // different one without ever leaving the home screen.
        NSString *displayName = manifest[@"displayName"] ?: [src lastPathComponent];

        UIWindow *coverWin = gHostWindow;
        if (coverWin) {
            @try {
                PPInstallPosterIntoWindow(coverWin);
                PPCleanupStaleLayersInWindow(coverWin, gPosterLayer);
                PPNukeAllStaleLayersEverywhere(gPosterLayer);
            } @catch (NSException *e) {
                PPApplyLog(@"apply EXCEPTION (cover) on %@: %@ -- %@",
                           displayName, e.name, e.reason);
                PPSetDebug(@"apply: cover rebuild threw %@", e.name);
                // Don't rethrow -- bundle is already on disk; on the
                // next respring our %ctor will retry from a clean state.
            }
        }

        // Rebuild the home-screen poster too, if we already have one
        // staged. Walks every UIWindowScene's windows and reapplies
        // the home install on whichever window currently hosts a home
        // poster instance.
        if (@available(iOS 15.0, *)) {
            @try {
                for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
                    if (![s isKindOfClass:[UIWindowScene class]]) continue;
                    for (UIWindow *w in ((UIWindowScene *)s).windows) {
                        if (w == coverWin) continue;
                        NSString *cls = NSStringFromClass([w class]);
                        if ([cls containsString:@"HomeScreen"] ||
                            [cls containsString:@"SBHome"]) {
                            PPInstallPosterIntoHomeWindow(w);
                        }
                    }
                }
            } @catch (NSException *e) {
                PPApplyLog(@"apply EXCEPTION (home) on %@: %@ -- %@",
                           displayName, e.name, e.reason);
                PPSetDebug(@"apply: home rebuild threw %@", e.name);
            }
        }

        PPApplyLog(@"apply OK: %@", displayName);
        PPSetDebug(@"apply OK: %@ (respring needed for full effect)", displayName);

        // Note: NEVER auto-respring. The user opts in via the separate
        // "Respring" button in the app, which sends kPPRespringDarwinName.
    }
}

// Three independent triggers on the apply path, any one is enough:
//   1. notify_register_dispatch on "com.vortex.pocketplayer.apply"
//      — fires instantly when notify_post() from the app reaches us.
//   2. dispatch_source(VNODE) on the manifest's parent directory
//      — kqueue fires whenever the plist is created/replaced. This
//      path doesn't require any entitlement to cross the sandbox
//      boundary, so it works even if rootless signing strips the
//      app's notify entitlement.
//   3. NSTimer poll every 2s — paranoid backstop.
//
// Whichever fires first wins; PPHandleApplyNotification is idempotent
// (deletes the manifest after handling) so duplicate triggers no-op.
static void PPRegisterApplyListener(void) {
    static dispatch_once_t once;
    static int notifyToken;
    static int respringToken;
    static dispatch_source_t dirSource;
    static NSTimer *pollTimer;

    dispatch_once(&once, ^{
        // --- apply via Darwin notification ---
        notify_register_dispatch(kPPApplyDarwinName,
                                 &notifyToken,
                                 dispatch_get_main_queue(),
                                 ^(int t) { PPHandleApplyNotification(); });

        // --- respring via separate explicit notification ---
        notify_register_dispatch(kPPRespringDarwinName,
                                 &respringToken,
                                 dispatch_get_main_queue(),
                                 ^(int t) { PPRespringNow(); });

        // --- vnode watcher on the manifest's parent directory ---
        // Apply-only fallback for the case where the app's notify_post
        // is filtered before reaching SpringBoard. Filesystem events
        // never get filtered, so this one always works.
        NSString *dir = [kPPApplyManifestPath stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];
        int fd = open([dir fileSystemRepresentation], O_EVTONLY);
        if (fd >= 0) {
            dirSource = dispatch_source_create(
                DISPATCH_SOURCE_TYPE_VNODE,
                fd,
                DISPATCH_VNODE_WRITE | DISPATCH_VNODE_EXTEND |
                DISPATCH_VNODE_RENAME | DISPATCH_VNODE_LINK,
                dispatch_get_main_queue());
            dispatch_source_set_event_handler(dirSource, ^{
                if ([[NSFileManager defaultManager]
                        fileExistsAtPath:kPPApplyManifestPath]) {
                    PPHandleApplyNotification();
                }
            });
            dispatch_source_set_cancel_handler(dirSource, ^{ close(fd); });
            dispatch_resume(dirSource);
        }

        // --- 2s poll, paranoid backstop ---
        pollTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                    repeats:YES
                                                      block:^(NSTimer *t) {
            if ([[NSFileManager defaultManager]
                    fileExistsAtPath:kPPApplyManifestPath]) {
                PPHandleApplyNotification();
            }
        }];

        // --- one-shot: anything left over from before we attached ---
        if ([[NSFileManager defaultManager] fileExistsAtPath:kPPApplyManifestPath]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                PPHandleApplyNotification();
            });
        }

        PPSetDebug(@"apply listener: notify+vnode+poll armed at %@", dir);
    });
}

// =====================================================================
// Panic recovery / kill-switch
//
// Story: PocketPlayer parses arbitrary CAML wallpaper bundles inside
// SpringBoard's address space. Most failures throw NSException, which
// we already catch around the apply / install paths. But a sufficiently
// broken bundle can also cause:
//   - EXC_BAD_ACCESS  (nil deref, dangling pointer in CG/CA internals)
//   - SIGABRT from C++ destructors / assertions in QuartzCore
//   - infinite loops -> watchdog kill at 120s
// None of those are catchable in Objective-C. If SpringBoard repeatedly
// crashes at boot trying to load the bundle, the user is stuck in safe
// mode — they can't even open Settings to disable the tweak (the home
// screen is unreachable while SB is crashing).
//
// Solution: heartbeat file + 30s boot-success watchdog.
//   1. At %ctor entry we read heartbeat.plist.
//   2. If the previous boot's record has succeeded=NO, the previous
//      boot didn't survive 30s -> probably crashed. Increment badStreak.
//   3. If badStreak hits 2, we conclude the active wallpaper is toxic.
//      Move it to quarantine/ and remove from the active slot.
//   4. Write a fresh "starting" record (succeeded=NO).
//   5. After 30s of live operation, write succeeded=YES + reset streak.
//
// Net effect: one bad install costs the user 2-3 fast respring cycles
// (~10-20 seconds total) and then they're back on the regular home
// screen with no wallpaper. They can pick a different one from the
// companion app. They never need SSH or DFU.
// =====================================================================

static NSString *const kPPHeartbeatPath =
    @"/var/mobile/Library/PocketPlayer/heartbeat.plist";
static NSString *const kPPQuarantineDir =
    @"/var/mobile/Library/PocketPlayer/quarantine";
static NSString *const kPPQuarantineLog =
    @"/var/mobile/pocketplayer-quarantine.log";

static const NSTimeInterval kPPBootSuccessGrace = 30.0; // seconds
static const NSInteger kPPMaxConsecutiveBadBoots = 2;

// Append one line to /var/mobile/pocketplayer-quarantine.log. Best-effort
// — never throws.
static void PPQuarantineLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"%@: %@\n", [NSDate date], s];
    NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kPPQuarantineLog];
    if (!fh) {
        [@"" writeToFile:kPPQuarantineLog atomically:YES
                encoding:NSUTF8StringEncoding error:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:kPPQuarantineLog];
    }
    if (fh) {
        @try {
            [fh seekToEndOfFile];
            [fh writeData:d];
            [fh closeFile];
        } @catch (NSException *e) {}
    }
}

// Move every *.wallpaper out of the active PosterPlayer slot into the
// quarantine directory, with a unix-time prefix so older quarantines
// don't get clobbered. Active slot ends up empty -> next SpringBoard
// boot reads no bundle -> %ctor's normal install path bails cleanly
// in PPInstallPosterIntoWindow ("no caml at (null)") and the user
// sees the stock iOS wallpaper instead of safe mode.
static void PPQuarantineActiveWallpaper(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:kPPQuarantineDir
  withIntermediateDirectories:YES
                   attributes:nil
                        error:NULL];

    NSArray *contents = [fm contentsOfDirectoryAtPath:kPPWallpaperRoot
                                                error:NULL];
    for (NSString *kid in contents) {
        if (![kid hasSuffix:@".wallpaper"]) continue;
        NSString *src = [kPPWallpaperRoot stringByAppendingPathComponent:kid];
        NSString *stamp = [NSString stringWithFormat:@"%.0f-%@",
                           [NSDate date].timeIntervalSince1970, kid];
        NSString *dst = [kPPQuarantineDir stringByAppendingPathComponent:stamp];
        NSError *err = nil;
        if ([fm moveItemAtPath:src toPath:dst error:&err]) {
            PPQuarantineLog(@"quarantined %@ -> %@", kid, stamp);
        } else {
            // If move fails (rare; rootless permissions can rarely
            // refuse), fall back to a destructive remove. Better to
            // lose the bundle than to keep crashing.
            [fm removeItemAtPath:src error:NULL];
            PPQuarantineLog(@"removed %@ (move failed: %@)",
                            kid, err.localizedDescription ?: @"?");
        }
    }
}

// Read previous heartbeat. If the last boot didn't record success
// within 30s, treat it as a fast crash and increment the bad-streak
// counter. If the counter hits the threshold, quarantine the active
// wallpaper. Then write a fresh "starting" record and arm a 30-second
// timer that will mark success.
//
// Wrapped in @try by its only caller (%ctor); even if NSDictionary
// readers throw on a corrupt plist, the recovery path stays alive.
static void PPPanicCheckAtBoot(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [kPPHeartbeatPath stringByDeletingLastPathComponent];
    [fm createDirectoryAtPath:dir
  withIntermediateDirectories:YES
                   attributes:nil
                        error:NULL];

    NSDictionary *prev = [NSDictionary dictionaryWithContentsOfFile:kPPHeartbeatPath];
    NSInteger badStreak = [prev[@"badStreak"] integerValue];
    BOOL prevSucceeded  = [prev[@"succeeded"]  boolValue];
    NSTimeInterval prevStart = [prev[@"startedAt"] doubleValue];

    if (prev != nil && !prevSucceeded) {
        // Previous boot ran our %ctor but never reached the 30s
        // success mark. Almost always means a fast crash (or a
        // watchdog kill within the first 30s of life). Count it.
        badStreak += 1;
        PPQuarantineLog(@"bad boot detected: prevStartedAt=%.0f badStreak=%ld",
                        prevStart, (long)badStreak);
        if (badStreak >= kPPMaxConsecutiveBadBoots) {
            PPQuarantineLog(@"streak hit threshold (%ld) -- quarantining active slot",
                            (long)kPPMaxConsecutiveBadBoots);
            PPQuarantineActiveWallpaper();
            badStreak = 0;
        }
    } else {
        badStreak = 0;
    }

    NSDictionary *fresh = @{
        @"startedAt": @([NSDate date].timeIntervalSince1970),
        @"succeeded": @NO,
        @"badStreak": @(badStreak),
    };
    [fresh writeToFile:kPPHeartbeatPath atomically:YES];

    // Mark success after 30s on the main queue. If main thread is
    // hung (worse than crashed), this block doesn't run, so the next
    // boot still sees succeeded=NO and increments the streak.
    // Captures the timestamp by value so we record when *this* boot
    // actually started, not when the success block fired.
    NSTimeInterval thisBootStart = [fresh[@"startedAt"] doubleValue];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(kPPBootSuccessGrace * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            NSDictionary *ok = @{
                @"startedAt": @(thisBootStart),
                @"succeeded": @YES,
                @"badStreak": @0,
            };
            [ok writeToFile:kPPHeartbeatPath atomically:YES];
        } @catch (NSException *e) {
            // Best-effort -- if we can't write the success mark, the
            // worst that happens is we falsely "remember" this boot
            // as bad next time, which is the safe failure mode.
        }
    });
}

%ctor {
    @autoreleasepool {
        NSString *exe = [[[NSBundle mainBundle] executablePath] lastPathComponent];
        if (![exe isEqualToString:@"SpringBoard"]) return;

        // Run BEFORE %init so we count even a crash inside Logos
        // initialization (e.g. a hooked class isn't found and Logos
        // bails). PPPanicCheckAtBoot itself does no UIKit / QuartzCore
        // work — it only touches the filesystem and dispatch_after,
        // so it can't be the cause of a crash.
        @try {
            PPPanicCheckAtBoot();
        } @catch (NSException *e) {
            // Recovery should never itself break the boot.
        }

        %init;
    }
}
