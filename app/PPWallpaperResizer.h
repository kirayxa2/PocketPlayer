// PPWallpaperResizer — rewrites a freshly-imported .wallpaper bundle so
// every author-canvas coordinate (bounds, position, anchorPoint, transform,
// emitter geometry, AND every value inside <states>) is rescaled to fit
// the host device's screen exactly.
//
// Why this is needed:
//   PosterBoard authors design on iPad/iPhone canvases (e.g. 1640x2360).
//   When such a wallpaper hits a smaller phone (e.g. 6s 750x1334) without
//   resize, the runtime fits the canvas to the screen by SCALING the
//   whole CALayer subtree -- which works for static images but produces
//   visible regressions:
//     - particle velocities stay in canvas coords -> particles look
//       slow/fast relative to the screen
//     - state interpolation deltas are in canvas coords -> the chest
//       opens by 200pt when 200pt = entire screen width
//     - sub-pixel layer sizes after CATransform3DMakeScale -> blurry
//
// Resize at IMPORT time pre-applies the scale to every numeric value
// in main.caml so the runtime can render identity-scale and everything
// "just works", visibly identical on any iPhone size from 6s to Pro Max.
//
// We intentionally rewrite XML directly (not via PPCAMLParser) because:
//   - we want to preserve every byte of the original except the numeric
//     attributes we rescale (preserve stateTransitions, modules, comments,
//     unknown elements that the parser quietly drops)
//   - we don't want to risk a parse-and-reserialize round trip that could
//     reorder children or change formatting in ways PosterPlayer notices

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface PPWallpaperResizer : NSObject

// Resize every *.ca/main.caml inside `bundleDir` (which is a *.wallpaper
// directory) to fit `targetSize` (in points). Also updates Wallpaper.plist
// LayerSizes / RenderingSize so PosterKit doesn't re-stretch on load.
//
// Returns YES on success. On failure, populates `error` and the bundle
// is left in whatever partial state it reached (caller should delete the
// import on failure).
+ (BOOL)resizeBundleAtPath:(NSString *)bundleDir
                toSize:(CGSize)targetSize
                 error:(NSError * _Nullable * _Nullable)error;

// Convenience: target size derived from `[UIScreen mainScreen]`.
+ (BOOL)resizeBundleAtPath:(NSString *)bundleDir
       toMainScreenWithError:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
