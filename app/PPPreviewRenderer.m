#import "PPPreviewRenderer.h"
#import "CAMLParser.h"

@implementation PPPreviewRenderer

// Locate the entry .caml file inside a .wallpaper bundle. Order:
//   1. Floating.ca/main.caml          (animated lockscreen w/ states)
//   2. Background.ca/main.caml         (static fallback)
//   3. <first *.ca>/main.caml          (whatever shows up)
+ (NSString *)findCAMLInBundle:(NSString *)bundlePath
                    assetsPath:(NSString **)outAssets {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *names = [fm contentsOfDirectoryAtPath:bundlePath error:NULL];

    NSArray *prefer = @[@"Floating.ca", @"Background.ca"];
    for (NSString *p in prefer) {
        if ([names containsObject:p]) {
            NSString *ca   = [bundlePath stringByAppendingPathComponent:p];
            NSString *caml = [ca stringByAppendingPathComponent:@"main.caml"];
            if ([fm fileExistsAtPath:caml]) {
                if (outAssets) *outAssets = [ca stringByAppendingPathComponent:@"assets"];
                return caml;
            }
        }
    }
    for (NSString *n in names) {
        if (![n hasSuffix:@".ca"]) continue;
        NSString *ca   = [bundlePath stringByAppendingPathComponent:n];
        NSString *caml = [ca stringByAppendingPathComponent:@"main.caml"];
        if ([fm fileExistsAtPath:caml]) {
            if (outAssets) *outAssets = [ca stringByAppendingPathComponent:@"assets"];
            return caml;
        }
    }
    return nil;
}

// Pick the "Locked" state if present, else the first declared state.
// We render a still, so we apply the chosen state at full progress.
static void PPApplyBaseState(PPCAMLDocument *doc) {
    if (!doc.states.count) return;
    NSArray *prefer = @[@"Locked", @"Default", @"Sleep"];
    for (NSString *name in prefer) {
        if (doc.states[name]) {
            [doc applyState:name progress:0.0];
            return;
        }
    }
    NSString *first = doc.stateOrder.firstObject;
    if (first) [doc applyState:first progress:0.0];
}

+ (BOOL)renderPreviewForBundle:(NSString *)bundlePath
                          size:(CGSize)size
                       outPath:(NSString *)outPath
                         error:(NSError **)error {
    if (size.width < 1 || size.height < 1) size = CGSizeMake(360, 640);

    NSString *assets = nil;
    NSString *caml = [self findCAMLInBundle:bundlePath assetsPath:&assets];
    if (!caml) {
        if (error) *error = [NSError errorWithDomain:@"PocketPoster" code:200
                              userInfo:@{NSLocalizedDescriptionKey:
                                  @"Bundle has no *.ca/main.caml"}];
        return NO;
    }

    PPCAMLDocument *doc = [PPCAMLParser parseCAMLAtPath:caml assetsPath:assets];
    if (!doc || !doc.rootLayer) {
        if (error) *error = [NSError errorWithDomain:@"PocketPoster" code:201
                              userInfo:@{NSLocalizedDescriptionKey:
                                  @"CAML failed to parse"}];
        return NO;
    }

    [doc captureBaseValues];
    PPApplyBaseState(doc);

    // The CAML root has its own bounds; we wrap it in a host layer the
    // size of our output and aspect-fit-scale the root into it. This
    // mirrors what the tweak does when embedding into the cover sheet
    // window, but without window/transform shenanigans.
    CGRect rb = doc.rootLayer.bounds;
    if (rb.size.width <= 0 || rb.size.height <= 0) rb = CGRectMake(0, 0, 390, 844);
    CGFloat sx = size.width  / rb.size.width;
    CGFloat sy = size.height / rb.size.height;
    CGFloat s  = MAX(sx, sy);

    CALayer *host = [CALayer layer];
    host.bounds = CGRectMake(0, 0, size.width, size.height);
    host.position = CGPointMake(size.width / 2.0, size.height / 2.0);
    host.backgroundColor = [UIColor blackColor].CGColor;
    host.masksToBounds = YES;

    doc.rootLayer.anchorPoint = CGPointMake(0.5, 0.5);
    doc.rootLayer.position = CGPointMake(size.width / 2.0, size.height / 2.0);
    doc.rootLayer.transform = CATransform3DMakeScale(s, s, 1.0);
    [host addSublayer:doc.rootLayer];

    // Force a layout pass before rendering -- otherwise sublayers that
    // were added but never had their first commit applied won't draw.
    [host layoutIfNeeded];
    [host setNeedsDisplay];
    [host displayIfNeeded];

    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.scale = 2.0; // retina-ish preview is plenty for thumbs
    UIGraphicsImageRenderer *r =
        [[UIGraphicsImageRenderer alloc] initWithSize:size format:fmt];

    UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [host renderInContext:ctx.CGContext];
    }];
    NSData *png = UIImagePNGRepresentation(img);
    if (!png) {
        if (error) *error = [NSError errorWithDomain:@"PocketPoster" code:202
                              userInfo:@{NSLocalizedDescriptionKey:
                                  @"PNG encode failed"}];
        return NO;
    }
    if (![png writeToFile:outPath atomically:YES]) {
        if (error) *error = [NSError errorWithDomain:@"PocketPoster" code:203
                              userInfo:@{NSLocalizedDescriptionKey:
                                  [@"Could not write " stringByAppendingString:outPath]}];
        return NO;
    }
    return YES;
}

@end
