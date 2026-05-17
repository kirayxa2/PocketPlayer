// PPPreviewRenderer — turns a *.wallpaper bundle into a static preview
// PNG suitable for the gallery thumbnail and the detail-view header.
//
// We reuse the tweak's CAML parser (../CAMLParser.{h,m}) so any wallpaper
// PocketPlayer can run in SpringBoard, the app can also render. Trade-off:
// emitter cells are intentionally NOT rendered into the still preview --
// they need a live time clock to look right and a frozen still of one is
// always misleading (just a single static texture stuck somewhere). For
// now the preview shows the static layer tree at the wallpaper's "Locked"
// (or first declared) state.
//
// Output: writes a PNG at `outPath` and returns YES, or returns NO and
// optionally fills `error` with a human-readable explanation.

#import <UIKit/UIKit.h>

@interface PPPreviewRenderer : NSObject

// Render a square-ish preview at `size` (points) for the .wallpaper at
// `bundlePath`, save to `outPath`. Safe to call off the main thread.
+ (BOOL)renderPreviewForBundle:(NSString *)bundlePath
                          size:(CGSize)size
                       outPath:(NSString *)outPath
                         error:(NSError **)error;

@end
