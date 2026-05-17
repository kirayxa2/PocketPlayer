// PocketPlayer — animated lockscreen wallpapers (.ca bundles) for iOS 15.
//
// Hierarchy on iOS 15 (Dopamine, rootless):
//   SBCoverSheetWindow
//     └── CSCoverSheetView   <-- we attach our CALayer tree here (zPosition = -1, behind clock)
//
// Progress is fed from whichever of these gets called first:
//   1) CSCoverSheetViewController _updatePresentationProgress:withOffset:presentationState:
//   2) SBCoverSheetSlidingViewController <same selector>
//   3) SBDashBoardViewController <same selector>   (older private name used on some 15.x)
//   4) Fallback: CADisplayLink reading presentationLayer.position.y of the cover sheet window.
//
// All four are installed at once, so we don't have to rebuild to "guess" the right class.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "CAMLParser.h"

// =====================================================================
// Configuration
// =====================================================================

// Path to the active wallpaper bundle. Change here if you ship a different default.
// Layout: <bundle>/contents/<name>.wallpaper/<name>_Floating-WxH@3x~iphone.ca/main.caml
static NSString *const kPPWallpaperRoot =
    @"/var/mobile/Library/PosterPlayer/active/versions/1/contents";

// Show a small red debug label in top-left while we develop.
// Flip to NO before shipping.
static BOOL const kPPDebugLabel = YES;

// =====================================================================
// State
// =====================================================================

static UILabel       *gDebugLabel;
static PPCAMLDocument *gDoc;
static CALayer       *gPosterLayer;     // root we added under CSCoverSheetView.layer
static __weak UIView *gCoverSheetView;
static CADisplayLink *gDisplayLink;
static CGFloat        gLastProgress = 0.0;
static CGFloat        gFallbackBaselineY = -1.0; // y position of cover sheet when fully presented

// =====================================================================
// Helpers
// =====================================================================

@interface CSCoverSheetView : UIView
@end

// Forward-declare the private classes we hook so the compiler is happy.
@interface CSCoverSheetViewController        : UIViewController @end
@interface SBCoverSheetSlidingViewController : UIViewController @end
@interface SBDashBoardViewController         : UIViewController @end

static NSString *PPFindFirstWallpaperBundle(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *err = nil;
    NSArray *items = [fm contentsOfDirectoryAtPath:kPPWallpaperRoot error:&err];
    if (!items) return nil;
    for (NSString *name in items) {
        if ([name hasSuffix:@".wallpaper"]) {
            return [kPPWallpaperRoot stringByAppendingPathComponent:name];
        }
    }
    return nil;
}

static NSString *PPFindFloatingCA(NSString *wallpaperBundle) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *err = nil;
    NSArray *items = [fm contentsOfDirectoryAtPath:wallpaperBundle error:&err];
    if (!items) return nil;
    // Prefer the *_Floating*.ca bundle; fall back to any .ca bundle.
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

static void PPSetDebug(NSString *fmt, ...) {
    if (!kPPDebugLabel) return;
    va_list args;
    va_start(args, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gDebugLabel) gDebugLabel.text = s;
    });
    // Also persist last line, useful when no debug label is shown.
    [s writeToFile:@"/var/mobile/pocketplayer.log"
        atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// State names cached per loaded document. We try the canonical PosterBoard names first
// (Locked/Unlocked), then fall back to whatever the .caml actually defines, in document order.
static NSString *gFromState;
static NSString *gToState;

static void PPResolveStates(PPCAMLDocument *doc) {
    gFromState = nil;
    gToState   = nil;
    if (!doc) return;

    // Preferred canonical pairs in PosterBoard
    NSArray *prefer = @[
        @[@"Locked",   @"Unlocked"],
        @[@"Sleep",    @"Wake"],
        @[@"Default",  @"Activated"],
    ];
    for (NSArray *pair in prefer) {
        if (doc.states[pair[0]] && doc.states[pair[1]]) {
            gFromState = pair[0];
            gToState   = pair[1];
            return;
        }
    }

    // Otherwise: take the first two states we see (parser preserves declaration order).
    NSArray *names = doc.stateOrder;
    if (names.count >= 2) { gFromState = names[0]; gToState = names[1]; }
    else if (names.count == 1) { gFromState = nil;  gToState = names[0]; }
}

// progress: 0 = locked (cover sheet covers screen), 1 = fully unlocked (cover sheet gone)
static void PPApplyProgress(CGFloat progress) {
    progress = MAX(0.0, MIN(1.0, progress));
    gLastProgress = progress;
    if (!gDoc || !gToState) return;

    if (gFromState) {
        [gDoc applyTransitionFromState:gFromState toState:gToState progress:progress];
    } else {
        // Only one state defined -> interpolate base -> that state.
        [gDoc applyState:gToState progress:progress];
    }
}

// =====================================================================
// Setup / teardown of the poster layer
// =====================================================================

static void PPInstallPosterIntoView(UIView *coverSheet) {
    if (!coverSheet) return;
    gCoverSheetView = coverSheet;

    // Remove any previous instance.
    for (CALayer *l in [coverSheet.layer.sublayers copy]) {
        if ([l.name isEqualToString:@"PocketPlayerLayer"]) [l removeFromSuperlayer];
    }

    NSString *bundle  = PPFindFirstWallpaperBundle();
    NSString *caPath  = bundle ? PPFindFloatingCA(bundle) : nil;
    NSString *camlPath = caPath ? [caPath stringByAppendingPathComponent:@"main.caml"] : nil;
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

    // Wrap rootLayer in a container so we can scale to the actual screen.
    CALayer *container = [CALayer layer];
    container.name = @"PocketPlayerLayer";
    container.frame = coverSheet.bounds;
    container.zPosition = -1; // behind clock & notifications
    container.masksToBounds = YES;

    // The CAML was authored for 390x844. Fit-to-bounds scale.
    CGRect rb = doc.rootLayer.bounds;
    if (rb.size.width <= 0 || rb.size.height <= 0) rb = CGRectMake(0, 0, 390, 844);
    CGFloat sx = coverSheet.bounds.size.width  / rb.size.width;
    CGFloat sy = coverSheet.bounds.size.height / rb.size.height;
    CGFloat s  = MAX(sx, sy); // fill (may crop horizontally on narrow phones)

    doc.rootLayer.anchorPoint = CGPointMake(0.5, 0.5);
    doc.rootLayer.position    = CGPointMake(coverSheet.bounds.size.width  / 2.0,
                                            coverSheet.bounds.size.height / 2.0);
    // CAML coords are top-left origin; CALayer is top-left too on iOS, so no flip needed
    // for raw rendering. We DON'T flip geometry so child coordinates match the source.
    doc.rootLayer.transform = CATransform3DMakeScale(s, s, 1.0);

    [container addSublayer:doc.rootLayer];
    [coverSheet.layer addSublayer:container];
    gPosterLayer = container;

    // Make sure base values reflect what's currently in the layer tree.
    [doc captureBaseValues];

    // Pick which two states drive our 0..1 transition.
    PPResolveStates(doc);

    // Log discovered states so we know exactly what the .caml exposes.
    NSArray *names = doc.stateOrder;
    NSString *summary = [NSString stringWithFormat:@"states=[%@] from=%@ to=%@ count=%lu",
        [names componentsJoinedByString:@","], gFromState ?: @"-", gToState ?: @"-",
        (unsigned long)names.count];
    [summary writeToFile:@"/var/mobile/pocketplayer-states.log"
              atomically:YES encoding:NSUTF8StringEncoding error:nil];

    // Apply locked state initially (progress 0).
    PPApplyProgress(0.0);

    PPSetDebug(@"ready %@ st=%lu", [camlPath lastPathComponent], (unsigned long)names.count);
}

// =====================================================================
// Debug label
// =====================================================================

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
// Fallback: CADisplayLink reading presentationLayer y
// =====================================================================

@interface PPDisplayLinkTarget : NSObject
- (void)tick:(CADisplayLink *)link;
@end

@implementation PPDisplayLinkTarget
- (void)tick:(CADisplayLink *)link {
    UIView *cs = gCoverSheetView;
    if (!cs.window) return;
    CALayer *pl = (CALayer *)[cs.layer presentationLayer];
    if (!pl) return;

    // The window/view that holds CSCoverSheetView slides up during unlock.
    // We track our own view's position in window coordinates.
    CGPoint center = [cs.superview convertPoint:cs.center toView:nil];
    CGFloat y = center.y;

    // Establish baseline lazily as the highest y we ever see (= fully presented / locked).
    if (gFallbackBaselineY < 0 || y > gFallbackBaselineY) gFallbackBaselineY = y;

    CGFloat h = cs.bounds.size.height;
    if (h <= 1) return;

    CGFloat travel = gFallbackBaselineY - y; // how far up we've moved
    CGFloat progress = travel / h;
    progress = MAX(0.0, MIN(1.0, progress));

    if (fabs(progress - gLastProgress) > 0.001) {
        PPApplyProgress(progress);
        PPSetDebug(@"fallback progress: %.3f (y=%.1f base=%.1f)", progress, y, gFallbackBaselineY);
    }
}
@end

static void PPStartDisplayLink(void) {
    if (gDisplayLink) return;
    PPDisplayLinkTarget *t = [PPDisplayLinkTarget new];
    // Retain target by associating with the link (CADisplayLink retains target).
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

    PPInstallPosterIntoView(self);
    PPInstallDebugLabel(self);
    PPStartDisplayLink();
}

- (void)layoutSubviews {
    %orig;
    // Keep our container sized to the view.
    if (gPosterLayer && gPosterLayer.superlayer == self.layer) {
        gPosterLayer.frame = self.bounds;
        if (gDoc.rootLayer) {
            gDoc.rootLayer.position = CGPointMake(self.bounds.size.width / 2.0,
                                                  self.bounds.size.height / 2.0);
        }
    }
    if (gDebugLabel.superview == self) {
        gDebugLabel.frame = CGRectMake(8, 60, self.bounds.size.width - 16, 22);
    }
}

%end

// Three different controllers expose the same selector across iOS 15.x point releases.
// We hook all three; only the one in use will be matched at runtime by libhooker/ellekit.

%hook CSCoverSheetViewController
- (void)_updatePresentationProgress:(CGFloat)progress
                         withOffset:(CGFloat)offset
                  presentationState:(NSInteger)state {
    %orig;
    PPApplyProgress(1.0 - progress); // CS reports 1=presented(locked), 0=dismissed(unlocked) — invert
    PPSetDebug(@"CS p=%.3f off=%.1f st=%ld", progress, (double)offset, (long)state);
}
%end

%hook SBCoverSheetSlidingViewController
- (void)_updatePresentationProgress:(CGFloat)progress
                         withOffset:(CGFloat)offset
                  presentationState:(NSInteger)state {
    %orig;
    PPApplyProgress(1.0 - progress);
    PPSetDebug(@"Sl p=%.3f off=%.1f st=%ld", progress, (double)offset, (long)state);
}
%end

%hook SBDashBoardViewController
- (void)_updatePresentationProgress:(CGFloat)progress
                         withOffset:(CGFloat)offset
                  presentationState:(NSInteger)state {
    %orig;
    PPApplyProgress(1.0 - progress);
    PPSetDebug(@"DB p=%.3f off=%.1f st=%ld", progress, (double)offset, (long)state);
}
%end

%ctor {
    @autoreleasepool {
        // Init only if loaded into SpringBoard (filter ensures this, but be safe).
        NSString *exe = [[[NSBundle mainBundle] executablePath] lastPathComponent];
        if (![exe isEqualToString:@"SpringBoard"]) return;
        %init;
    }
}
