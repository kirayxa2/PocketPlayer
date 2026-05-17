// CAMLParser.m
#import "CAMLParser.h"
#import <ImageIO/ImageIO.h>
#import <MobileCoreServices/MobileCoreServices.h>

#pragma mark - Helpers

// Diagnostics counters (reset per-parse). Tweak.x reads these via the
// document so it can show "imgs=12 emitters=1 cells=1 missing=0" in the
// debug label and figure out whether emitters never got their texture.
static NSInteger gPPImagesLoaded = 0;
static NSInteger gPPImagesMissing = 0;
static NSInteger gPPEmittersBuilt = 0;
static NSInteger gPPCellsBuilt = 0;

// Robust image loader. +[UIImage imageWithContentsOfFile:] on iOS 15
// can fail on .webp because it dispatches by extension and not by
// magic bytes. Falls back to ImageIO (which understands webp via
// system codecs since iOS 14).
//
// Also: tries common substitutions (.webp -> .png) because some
// authoring tools rename the texture but keep the original src in the
// CAML.
static UIImage *PPLoadImageAtPath(NSString *path) {
    if (!path.length) return nil;

    // Fast path.
    UIImage *img = [UIImage imageWithContentsOfFile:path];
    if (img) return img;

    // ImageIO path (handles webp, heic, etc.)
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (src) {
        CGImageRef cg = CGImageSourceCreateImageAtIndex(src, 0, NULL);
        CFRelease(src);
        if (cg) {
            UIImage *out = [UIImage imageWithCGImage:cg scale:[UIScreen mainScreen].scale orientation:UIImageOrientationUp];
            CGImageRelease(cg);
            if (out) return out;
        }
    }

    // Last resort: try swapping extension. Authors frequently keep an
    // .png src after re-encoding to webp (or vice versa).
    NSString *ext = path.pathExtension.lowercaseString;
    NSArray *alts = nil;
    if ([ext isEqualToString:@"webp"]) alts = @[@"png", @"jpg", @"jpeg", @"heic"];
    else if ([ext isEqualToString:@"png"]) alts = @[@"webp", @"jpg", @"jpeg"];
    else if ([ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"]) alts = @[@"png", @"webp"];
    NSString *base = [path stringByDeletingPathExtension];
    for (NSString *e in alts) {
        NSString *p2 = [base stringByAppendingPathExtension:e];
        UIImage *im = [UIImage imageWithContentsOfFile:p2];
        if (im) return im;
        // ImageIO again on the alt-extension path.
        NSURL *u2 = [NSURL fileURLWithPath:p2];
        CGImageSourceRef s2 = CGImageSourceCreateWithURL((__bridge CFURLRef)u2, NULL);
        if (s2) {
            CGImageRef cg = CGImageSourceCreateImageAtIndex(s2, 0, NULL);
            CFRelease(s2);
            if (cg) {
                UIImage *out = [UIImage imageWithCGImage:cg scale:[UIScreen mainScreen].scale orientation:UIImageOrientationUp];
                CGImageRelease(cg);
                if (out) return out;
            }
        }
    }
    return nil;
}

static NSArray<NSNumber *> *PPParseNumberList(NSString *s) {
    if (!s.length) return @[];
    NSCharacterSet *sep = [NSCharacterSet characterSetWithCharactersInString:@" ,"];
    NSArray *parts = [s componentsSeparatedByCharactersInSet:sep];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *p in parts) {
        if (!p.length) continue;
        [out addObject:@(p.doubleValue)];
    }
    return out;
}

static CGRect PPParseRect(NSString *s) {
    NSArray<NSNumber *> *n = PPParseNumberList(s);
    if (n.count < 4) return CGRectZero;
    return CGRectMake(n[0].doubleValue, n[1].doubleValue, n[2].doubleValue, n[3].doubleValue);
}

static CGPoint PPParsePoint(NSString *s) {
    NSArray<NSNumber *> *n = PPParseNumberList(s);
    if (n.count < 2) return CGPointZero;
    return CGPointMake(n[0].doubleValue, n[1].doubleValue);
}

// Parse "0.51 0.4 0.23" or "0.51 0.4 0.23 1.0" -> UIColor
static UIColor *PPParseColor(NSString *s) {
    NSArray<NSNumber *> *n = PPParseNumberList(s);
    if (n.count >= 4) return [UIColor colorWithRed:n[0].doubleValue green:n[1].doubleValue blue:n[2].doubleValue alpha:n[3].doubleValue];
    if (n.count >= 3) return [UIColor colorWithRed:n[0].doubleValue green:n[1].doubleValue blue:n[2].doubleValue alpha:1.0];
    if (n.count >= 1) return [UIColor colorWithWhite:n[0].doubleValue alpha:1.0];
    return nil;
}

// Lerp scalar
static double PPLerp(double a, double b, double t) { return a + (b - a) * t; }

// Apply a numeric value (NSNumber / NSValue / UIColor) to a CALayer keyPath, interpolating from base.
static void PPApplyInterpolated(CALayer *layer, NSString *keyPath, id base, id target, CGFloat t) {
    if (!layer || !keyPath) return;

    // Numbers (scalar key paths like position.x, bounds.size.width, opacity, transform.rotation.z)
    if ([base isKindOfClass:[NSNumber class]] && [target isKindOfClass:[NSNumber class]]) {
        double v = PPLerp([base doubleValue], [target doubleValue], t);
        [layer setValue:@(v) forKeyPath:keyPath];
        return;
    }

    // CGPoint
    if ([base isKindOfClass:[NSValue class]] && [target isKindOfClass:[NSValue class]]) {
        const char *type = [(NSValue *)base objCType];
        if (strcmp(type, @encode(CGPoint)) == 0) {
            CGPoint a = [base CGPointValue];
            CGPoint b = [target CGPointValue];
            CGPoint r = CGPointMake(PPLerp(a.x, b.x, t), PPLerp(a.y, b.y, t));
            [layer setValue:[NSValue valueWithCGPoint:r] forKeyPath:keyPath];
            return;
        }
        if (strcmp(type, @encode(CGSize)) == 0) {
            CGSize a = [base CGSizeValue];
            CGSize b = [target CGSizeValue];
            CGSize r = CGSizeMake(PPLerp(a.width, b.width, t), PPLerp(a.height, b.height, t));
            [layer setValue:[NSValue valueWithCGSize:r] forKeyPath:keyPath];
            return;
        }
        if (strcmp(type, @encode(CGRect)) == 0) {
            CGRect a = [base CGRectValue];
            CGRect b = [target CGRectValue];
            CGRect r = CGRectMake(PPLerp(a.origin.x, b.origin.x, t), PPLerp(a.origin.y, b.origin.y, t),
                                  PPLerp(a.size.width, b.size.width, t), PPLerp(a.size.height, b.size.height, t));
            [layer setValue:[NSValue valueWithCGRect:r] forKeyPath:keyPath];
            return;
        }
    }

    // UIColor -> CGColor
    if ([base isKindOfClass:[UIColor class]] && [target isKindOfClass:[UIColor class]]) {
        CGFloat r1=0,g1=0,b1=0,a1=1, r2=0,g2=0,b2=0,a2=1;
        [(UIColor *)base getRed:&r1 green:&g1 blue:&b1 alpha:&a1];
        [(UIColor *)target getRed:&r2 green:&g2 blue:&b2 alpha:&a2];
        UIColor *c = [UIColor colorWithRed:PPLerp(r1,r2,t) green:PPLerp(g1,g2,t)
                                     blue:PPLerp(b1,b2,t) alpha:PPLerp(a1,a2,t)];
        [layer setValue:(id)c.CGColor forKeyPath:keyPath];
        return;
    }

    // Fallback: just set target
    [layer setValue:target forKeyPath:keyPath];
}

// =====================================================================
// Animation value parsing
// =====================================================================
//
// CAML <animation>'s <values> children carry one of: <integer>, <real>,
// <point>, <size>, <color>, <transform>. We boil all of these down to
// either NSNumber (scalars) or NSValue (CG*) the way Core Animation
// expects them when handed to a CABasicAnimation / CAKeyframeAnimation.
//
// keyPath "transform.rotation.*", "transform.scale*", "opacity",
// "position.x", "position.y", "bounds.size.*" etc are all scalar.
// "position" is CGPoint, "bounds" is CGRect, "bounds.size" is CGSize.
// We don't try to be exhaustive - whatever we don't recognize, we
// pass through as a raw scalar (val.doubleValue) which works for the
// vast majority of community CAMLs.

// Used while parsing a single <values>/<keyTimes> child element.
static id PPCoerceAnimationValue(NSString *elementName,
                                 NSDictionary<NSString *, NSString *> *attrs)
{
    NSString *v = attrs[@"value"];
    if (!v.length) return nil;

    if ([elementName isEqualToString:@"integer"] ||
        [elementName isEqualToString:@"real"] ||
        [elementName isEqualToString:@"number"]) {
        return @(v.doubleValue);
    }
    if ([elementName isEqualToString:@"point"]) {
        return [NSValue valueWithCGPoint:PPParsePoint(v)];
    }
    if ([elementName isEqualToString:@"size"]) {
        NSArray<NSNumber *> *n = PPParseNumberList(v);
        if (n.count >= 2) return [NSValue valueWithCGSize:CGSizeMake(n[0].doubleValue, n[1].doubleValue)];
        return nil;
    }
    if ([elementName isEqualToString:@"rect"]) {
        return [NSValue valueWithCGRect:PPParseRect(v)];
    }
    if ([elementName isEqualToString:@"color"]) {
        UIColor *c = PPParseColor(v);
        return c ? (id)c.CGColor : nil;
    }
    // Unknown wrapper - try as a scalar.
    return @(v.doubleValue);
}

// Map a CAML "timingFunction" attribute to a CAMediaTimingFunction.
//
// Common values: "easeInEaseOut", "linear", "easeIn", "easeOut",
// "default", or four floats "0.5 0 0.5 1" for a custom cubic Bezier.
// This is what authoring tools like CAPlayground emit.
static CAMediaTimingFunction *PPMakeTimingFunction(NSString *spec) {
    if (!spec.length) return nil;
    NSString *s = [spec stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

    // Named?
    if ([s isEqualToString:@"linear"])
        return [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
    if ([s isEqualToString:@"easeIn"])
        return [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn];
    if ([s isEqualToString:@"easeOut"])
        return [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    if ([s isEqualToString:@"easeInEaseOut"] ||
        [s isEqualToString:@"easeInOut"])
        return [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    if ([s isEqualToString:@"default"])
        return [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionDefault];

    // Four floats?
    NSArray<NSNumber *> *n = PPParseNumberList(s);
    if (n.count >= 4) {
        float c[4] = {n[0].floatValue, n[1].floatValue, n[2].floatValue, n[3].floatValue};
        return [CAMediaTimingFunction functionWithControlPoints:c[0] :c[1] :c[2] :c[3]];
    }
    return nil;
}

#pragma mark - Models

@implementation PPCAMLStateValue
@end

@implementation PPCAMLState
@end

#pragma mark - Document

@interface PPCAMLDocument ()
@property (nonatomic, strong) CALayer *rootLayer;
@property (nonatomic, strong) NSMutableDictionary<NSString *, CALayer *> *mLayersById;
@property (nonatomic, strong) NSMutableDictionary<NSString *, PPCAMLState *> *mStates;
@property (nonatomic, strong) NSMutableArray<NSString *> *mStateOrder;
// base[layerId][keyPath] = baseValue
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, id> *> *baseValues;
@end

@implementation PPCAMLDocument

- (instancetype)init {
    if ((self = [super init])) {
        _mLayersById = [NSMutableDictionary dictionary];
        _mStates     = [NSMutableDictionary dictionary];
        _mStateOrder = [NSMutableArray array];
        _baseValues  = [NSMutableDictionary dictionary];
    }
    return self;
}

- (NSDictionary<NSString *, CALayer *> *)layersById { return _mLayersById; }
- (NSDictionary<NSString *, PPCAMLState *> *)states { return _mStates; }
- (NSArray<NSString *> *)stateOrder { return _mStateOrder; }

- (void)captureBaseValues {
    [_baseValues removeAllObjects];
    for (PPCAMLState *st in _mStates.allValues) {
        for (PPCAMLStateValue *sv in st.values) {
            CALayer *layer = _mLayersById[sv.targetId];
            if (!layer) continue;
            NSMutableDictionary *m = _baseValues[sv.targetId];
            if (!m) { m = [NSMutableDictionary dictionary]; _baseValues[sv.targetId] = m; }
            if (m[sv.keyPath]) continue;
            id current = [layer valueForKeyPath:sv.keyPath];
            if (current) m[sv.keyPath] = current;
        }
    }
}

- (void)applyState:(NSString *)stateName {
    [self applyState:stateName progress:1.0];
}

- (void)applyState:(NSString *)stateName progress:(CGFloat)progress {
    PPCAMLState *st = _mStates[stateName];
    if (!st) return;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    for (PPCAMLStateValue *sv in st.values) {
        CALayer *layer = _mLayersById[sv.targetId];
        if (!layer) continue;
        id base = _baseValues[sv.targetId][sv.keyPath];
        if (!base) base = [layer valueForKeyPath:sv.keyPath];
        PPApplyInterpolated(layer, sv.keyPath, base, sv.value, progress);
    }

    [CATransaction commit];
}

- (void)applyTransitionFromState:(NSString *)fromState
                         toState:(NSString *)toState
                        progress:(CGFloat)progress {
    PPCAMLState *from = _mStates[fromState];
    PPCAMLState *to   = _mStates[toState];
    if (!to) return;

    // Build dict of (layerId, keyPath) -> fromValue from `from` state, fallback to base.
    NSMutableDictionary *fromMap = [NSMutableDictionary dictionary];
    if (from) {
        for (PPCAMLStateValue *sv in from.values) {
            NSString *k = [NSString stringWithFormat:@"%@##%@", sv.targetId, sv.keyPath];
            fromMap[k] = sv.value;
        }
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    for (PPCAMLStateValue *sv in to.values) {
        CALayer *layer = _mLayersById[sv.targetId];
        if (!layer) continue;
        NSString *k = [NSString stringWithFormat:@"%@##%@", sv.targetId, sv.keyPath];
        id base = fromMap[k];
        if (!base) base = _baseValues[sv.targetId][sv.keyPath];
        if (!base) base = [layer valueForKeyPath:sv.keyPath];
        PPApplyInterpolated(layer, sv.keyPath, base, sv.value, progress);
    }

    [CATransaction commit];
}

@end

#pragma mark - Pending animation (in-flight while parsing one <animation>)

// While we're between <animation ...> and </animation>, we accumulate
// state into one of these. On close we materialize a real CABasicAnimation
// or CAKeyframeAnimation and addAnimation:forKey: on the owning layer.
@interface PPPendingAnim : NSObject
@property (nonatomic, copy)   NSString *type;            // "CABasicAnimation", "CAKeyframeAnimation", ...
@property (nonatomic, copy)   NSString *keyPath;
@property (nonatomic, assign) double duration;
@property (nonatomic, assign) double beginTime;
@property (nonatomic, assign) BOOL hasBeginTime;
@property (nonatomic, assign) BOOL autoreverses;
@property (nonatomic, assign) BOOL removedOnCompletion;
@property (nonatomic, assign) BOOL hasRemovedOnCompletion;
@property (nonatomic, assign) double speed;
@property (nonatomic, assign) BOOL hasSpeed;
@property (nonatomic, assign) double repeatCount;
@property (nonatomic, assign) BOOL repeatInf;
@property (nonatomic, copy)   NSString *fillMode;
@property (nonatomic, copy)   NSString *calculationMode;
@property (nonatomic, copy)   NSString *timingFunctionSpec;
@property (nonatomic, copy)   NSString *fromValueLiteral;       // when given as attribute
@property (nonatomic, copy)   NSString *toValueLiteral;         // when given as attribute
@property (nonatomic, strong) NSMutableArray<NSNumber *> *keyTimes;
@property (nonatomic, strong) NSMutableArray *values;           // NSNumber/NSValue/CGColorRef-as-id
@property (nonatomic, strong) NSMutableArray *timingFuncs;      // CAMediaTimingFunction, optional
// Which child list we're currently appending to.
@property (nonatomic, copy)   NSString *currentList;            // "values" / "keyTimes" / nil
@end

@implementation PPPendingAnim
- (instancetype)init {
    if ((self = [super init])) {
        _duration = 0.25;
        _speed = 1.0;
        _repeatCount = 0;
        _removedOnCompletion = YES;
    }
    return self;
}
@end

#pragma mark - Parser

@interface PPCAMLParser () <NSXMLParserDelegate>
@property (nonatomic, copy)   NSString *assetsPath;
@property (nonatomic, strong) PPCAMLDocument *doc;

// Parse stack of CALayer (so we can attach sublayers to parents)
@property (nonatomic, strong) NSMutableArray<CALayer *> *layerStack;

// "where am I" markers
@property (nonatomic, assign) BOOL inSublayers;
@property (nonatomic, assign) BOOL inContents;
@property (nonatomic, assign) BOOL inStates;
@property (nonatomic, strong) PPCAMLState *currentState;
@property (nonatomic, strong) NSMutableArray<PPCAMLStateValue *> *currentStateValues;
@property (nonatomic, strong) PPCAMLStateValue *currentStateValue; // current LKStateSetValue being filled

// Animation block parsing
//
// Depth-counted because <animations> can be nested via grouping (rare,
// but a grouped CAAnimationGroup can technically contain another
// <animations>). We only treat the OUTERMOST animations block as
// "real" and let inner ones contribute their <animation> entries to
// the same layer.
@property (nonatomic, assign) NSInteger animationsDepth;
@property (nonatomic, strong) PPPendingAnim *currentAnim;
@property (nonatomic, assign) NSInteger animKeyCounter;          // for autogen anim key names

// Emitter-cell parsing.
//
// CAEmitterLayer is a CALayer subclass whose particles are described by
// CAEmitterCell objects in its `emitterCells` array. Cells can in turn
// have child cells. The CAML structure is:
//
//   <CAEmitterLayer emitterSize="200 200" emitterMode="points" ...>
//     <emitterCells>
//       <CAEmitterCell birthRate="20" lifetime="100" velocity="114"
//                      particleType="plane" color="1 1 1" ...>
//         <contents type="CGImage" src="assets/starbit.webp"/>
//         <emitterCells>
//           <CAEmitterCell .../>     <!-- child cell, optional -->
//         </emitterCells>
//       </CAEmitterCell>
//     </emitterCells>
//   </CAEmitterLayer>
//
// We push the current cell onto a stack so children attach to the
// right parent. The `emitterCells` wrapper element is just structural
// (we track depth in inEmitterCellsDepth so we know we're inside one).
@property (nonatomic, strong) NSMutableArray<CAEmitterCell *> *cellStack;
@property (nonatomic, assign) NSInteger inEmitterCellsDepth;
@end

@implementation PPCAMLParser

+ (PPCAMLDocument *)parseCAMLAtPath:(NSString *)camlPath assetsPath:(NSString *)assetsPath {
    NSData *data = [NSData dataWithContentsOfFile:camlPath];
    if (!data) {
        NSLog(@"[PocketPlayer] CAML file not found at %@", camlPath);
        return nil;
    }

    // Reset diagnostic counters per-parse (Tweak.x reads them into
    // its debug label).
    gPPImagesLoaded  = 0;
    gPPImagesMissing = 0;
    gPPEmittersBuilt = 0;
    gPPCellsBuilt    = 0;
    gPPEmitterDumpBudget = 8;
    [@"" writeToFile:@"/var/mobile/pocketplayer-emitters.log"
          atomically:YES encoding:NSUTF8StringEncoding error:nil];

    PPCAMLParser *p = [PPCAMLParser new];
    p.assetsPath = assetsPath;
    p.doc = [PPCAMLDocument new];
    p.layerStack = [NSMutableArray array];
    p.cellStack  = [NSMutableArray array];

    NSXMLParser *xml = [[NSXMLParser alloc] initWithData:data];
    xml.delegate = p;
    if (![xml parse]) {
        NSLog(@"[PocketPlayer] CAML parse failed: %@", xml.parserError);
        return nil;
    }

    [p.doc captureBaseValues];
    // Stash counters on the doc so callers can show them.
    p.doc.imagesLoaded  = gPPImagesLoaded;
    p.doc.imagesMissing = gPPImagesMissing;
    p.doc.emittersBuilt = gPPEmittersBuilt;
    p.doc.cellsBuilt    = gPPCellsBuilt;
    return p.doc;
}

#pragma mark Layer factory

- (void)applyAttribute:(NSString *)key value:(NSString *)val toLayer:(CALayer *)layer {
    if (!val.length) return;

    if ([key isEqualToString:@"id"]) {
        layer.name = layer.name ?: val; // keep human name if already set
        // Track in layersById is done outside.
    } else if ([key isEqualToString:@"name"]) {
        layer.name = val;
    } else if ([key isEqualToString:@"bounds"]) {
        layer.bounds = PPParseRect(val);
    } else if ([key isEqualToString:@"position"]) {
        layer.position = PPParsePoint(val);
    } else if ([key isEqualToString:@"anchorPoint"]) {
        layer.anchorPoint = PPParsePoint(val);
    } else if ([key isEqualToString:@"opacity"]) {
        layer.opacity = val.floatValue;
    } else if ([key isEqualToString:@"hidden"]) {
        layer.hidden = val.boolValue;
    } else if ([key isEqualToString:@"cornerRadius"]) {
        layer.cornerRadius = val.doubleValue;
    } else if ([key isEqualToString:@"backgroundColor"]) {
        UIColor *c = PPParseColor(val);
        if (c) layer.backgroundColor = c.CGColor;
    } else if ([key isEqualToString:@"geometryFlipped"]) {
        layer.geometryFlipped = val.boolValue;
    } else if ([key isEqualToString:@"contentsGravity"]) {
        layer.contentsGravity = val;
    } else if ([key isEqualToString:@"transform.rotation.z"]) {
        [layer setValue:@(val.doubleValue) forKeyPath:@"transform.rotation.z"];
    } else if ([key isEqualToString:@"transform.rotation.x"]) {
        [layer setValue:@(val.doubleValue) forKeyPath:@"transform.rotation.x"];
    } else if ([key isEqualToString:@"transform.rotation.y"]) {
        [layer setValue:@(val.doubleValue) forKeyPath:@"transform.rotation.y"];
    } else if ([key isEqualToString:@"transform.scale"] ||
               [key isEqualToString:@"transform.scale.x"] ||
               [key isEqualToString:@"transform.scale.y"]) {
        [layer setValue:@(val.doubleValue) forKeyPath:key];
    } else if ([key isEqualToString:@"transform"]) {
        // Handle the textual form authoring tools emit:
        //
        //   transform="scale(3, 3, 1)"
        //   transform="rotate(45deg)"
        //   transform="translate(10, 20)"
        //   transform="rotate(0deg) rotate(0deg, 0, 1, 0) rotate(0deg, 1, 0, 0)"
        //
        // We compose simple single-call cases. Multi-op chained forms
        // are supported left-to-right (CAML emits them already in
        // the desired application order).
        //
        // Empty value => identity (we leave the layer alone).
        NSString *trimmed = [val stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (!trimmed.length) return;

        CATransform3D acc = CATransform3DIdentity;
        BOOL anyOp = NO;
        // Walk through "name(args)" tokens.
        NSScanner *sc = [NSScanner scannerWithString:trimmed];
        sc.charactersToBeSkipped = [NSCharacterSet whitespaceCharacterSet];
        while (!sc.isAtEnd) {
            NSString *fn = nil;
            if (![sc scanUpToString:@"(" intoString:&fn]) break;
            if (![sc scanString:@"(" intoString:NULL]) break;
            NSString *argstr = nil;
            if (![sc scanUpToString:@")" intoString:&argstr]) break;
            [sc scanString:@")" intoString:NULL];

            fn = [fn stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            NSArray<NSNumber *> *args = PPParseNumberList(argstr);
            // Accept "Xdeg" as just X for rotate; PPParseNumberList
            // already drops the trailing "deg" because doubleValue
            // stops at the first non-numeric character.
            if ([fn isEqualToString:@"scale"]) {
                if (args.count >= 2) {
                    acc = CATransform3DScale(acc, args[0].doubleValue, args[1].doubleValue,
                                             args.count >= 3 ? args[2].doubleValue : 1.0);
                } else if (args.count == 1) {
                    double s = args[0].doubleValue;
                    acc = CATransform3DScale(acc, s, s, 1.0);
                }
                anyOp = YES;
            } else if ([fn isEqualToString:@"rotate"]) {
                // "rotate(Xdeg)" -> Z rotation. With axis args
                // "rotate(Xdeg, ax, ay, az)" -> arbitrary axis.
                if (args.count >= 1) {
                    double angleRad = args[0].doubleValue * M_PI / 180.0;
                    if (args.count >= 4) {
                        acc = CATransform3DRotate(acc, angleRad,
                                                  args[1].doubleValue,
                                                  args[2].doubleValue,
                                                  args[3].doubleValue);
                    } else {
                        acc = CATransform3DRotate(acc, angleRad, 0, 0, 1);
                    }
                }
                anyOp = YES;
            } else if ([fn isEqualToString:@"translate"]) {
                if (args.count >= 2) {
                    acc = CATransform3DTranslate(acc, args[0].doubleValue, args[1].doubleValue,
                                                 args.count >= 3 ? args[2].doubleValue : 0);
                }
                anyOp = YES;
            }
            // Unknown function: skip silently. There may be whitespace
            // between functions; the loop's scanUpToString:@"(" will
            // happily eat it on the next iteration.
        }
        if (anyOp) layer.transform = acc;
    }
}

#pragma mark Emitter attribute helpers

// CAEmitterLayer-only attributes. Most layer-level attributes
// (bounds/position/transform/etc) are handled by applyAttribute: above
// because CAEmitterLayer IS-A CALayer.
//
// Reference: <QuartzCore/CAEmitterLayer.h>.
static void PPApplyEmitterLayerAttribute(CAEmitterLayer *em, NSString *key, NSString *val) {
    if (!em || !val.length) return;

    if ([key isEqualToString:@"emitterSize"]) {
        NSArray<NSNumber *> *n = PPParseNumberList(val);
        if (n.count >= 2) em.emitterSize = CGSizeMake(n[0].doubleValue, n[1].doubleValue);
    } else if ([key isEqualToString:@"emitterPosition"]) {
        em.emitterPosition = PPParsePoint(val);
    } else if ([key isEqualToString:@"emitterDepth"]) {
        em.emitterDepth = val.doubleValue;
    } else if ([key isEqualToString:@"emitterShape"]) {
        em.emitterShape = val; // "point", "line", "rectangle", "circle", "cuboid", "sphere"
    } else if ([key isEqualToString:@"emitterMode"]) {
        em.emitterMode = val;  // "points", "outline", "surface", "volume"
    } else if ([key isEqualToString:@"renderMode"]) {
        em.renderMode = val;   // "unordered", "oldestFirst", "oldestLast", "backToFront", "additive"
    } else if ([key isEqualToString:@"birthRate"]) {
        em.birthRate = val.floatValue;
    } else if ([key isEqualToString:@"lifetime"]) {
        em.lifetime = val.floatValue;
    } else if ([key isEqualToString:@"scale"]) {
        em.scale = val.floatValue;
    } else if ([key isEqualToString:@"spin"]) {
        em.spin = val.floatValue;
    } else if ([key isEqualToString:@"velocity"]) {
        em.velocity = val.floatValue;
    } else if ([key isEqualToString:@"seed"]) {
        em.seed = (unsigned int)val.integerValue;
    } else if ([key isEqualToString:@"preservesDepth"]) {
        em.preservesDepth = val.boolValue;
    }
    // Anything else falls through to the generic CALayer applyAttribute.
}

// Apply one CAEmitterCell attribute. We use KVC because CAEmitterCell
// already exposes everything we need as keyed properties.
//
// Most CAML CAEmitterCell attributes map 1:1 to CAEmitterCell property
// names (birthRate, lifetime, velocity, color, scale, etc.). The
// special-cases below are:
//   - color/redRange/greenRange/blueRange/alphaRange come as a 4-float
//     "r g b a" or 3-float "r g b" string; we parse to UIColor and
//     hand its .CGColor through.
//   - particleType is a string ("plane", "rectangle", "cuboid", ...).
//   - contentsRect / emitterPosition style "x y" or "x y w h" strings
//     need parsing into NSValue.
//   - "name" we set directly so authoring tools that target child
//     cells by name still work.
//   - contentsScale: in PosterBoard CAML files this is the texture
//     pixel/point ratio. Authoring tools sometimes emit large values
//     like 16.67 because the asset was exported at 16x its on-screen
//     size. Apple's CAEmitterCell honours it correctly (texture is
//     divided by contentsScale before rasterisation), so we pass it
//     through unchanged. Earlier we clamped to [0.1, 4.0] which broke
//     exactly the case where it was needed.
static void PPApplyEmitterCellAttribute(CAEmitterCell *cell, NSString *key, NSString *val) {
    if (!cell || !val.length) return;

    // Color attribute is always 3 or 4 floats.
    if ([key isEqualToString:@"color"]) {
        UIColor *c = PPParseColor(val);
        if (c) cell.color = c.CGColor;
        return;
    }

    // particleType / contentsFormat / minificationFilter / magnificationFilter
    // are plain strings; KVC-set them directly.
    if ([key isEqualToString:@"particleType"] ||
        [key isEqualToString:@"contentsFormat"] ||
        [key isEqualToString:@"minificationFilter"] ||
        [key isEqualToString:@"magnificationFilter"] ||
        [key isEqualToString:@"name"]) {
        @try { [cell setValue:val forKey:key]; } @catch (NSException *e) {}
        return;
    }

    // Booleans first: KVC autoboxes "1"/"0"/"YES"/"NO" via
    // -setValue:forKey: but only if the property type is BOOL. To be
    // safe we coerce to NSNumber explicitly.
    if ([key isEqualToString:@"autoreverses"] ||
        [key isEqualToString:@"enabled"] ||
        [key isEqualToString:@"hidden"]) {
        @try { [cell setValue:@(val.boolValue) forKey:key]; } @catch (NSException *e) {}
        return;
    }

    // Everything else we know about on CAEmitterCell is a scalar:
    //
    //   birthRate, lifetime, lifetimeRange, scale, scaleRange, scaleSpeed,
    //   spin, spinRange, velocity, velocityRange, emissionLatitude,
    //   emissionLongitude, emissionRange, redRange, greenRange, blueRange,
    //   alphaRange, redSpeed, greenSpeed, blueSpeed, alphaSpeed,
    //   xAcceleration, yAcceleration, zAcceleration,
    //   contentsFramesPerSecond, duration, beginTime, ...
    //
    // Set via KVC; if the key doesn't exist we silently catch.
    @try { [cell setValue:@(val.doubleValue) forKey:key]; } @catch (NSException *e) {}
}

// Counter for emitter-debug dump throttling (we only dump the first
// few cells/layers per parse, otherwise large CAMLs spam the log).
static NSInteger gPPEmitterDumpBudget = 0;

// Append one line to /var/mobile/pocketplayer-emitters.log so a debug
// build can see what shape the freshly-parsed emitter / cell ended up
// with. Bypasses the normal label log so screen UX stays clean.
static void PPDumpEmitter(NSString *line) {
    NSString *path = @"/var/mobile/pocketplayer-emitters.log";
    NSString *withNL = [line stringByAppendingString:@"\n"];
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

// Build a CAAnimation from a fully-parsed PPPendingAnim and attach it
// to `layer`. Apple's animator handles repeat/autoreverse/timing for
// us frame-by-frame. We don't have to do anything per-tick.
- (void)attachPendingAnim:(PPPendingAnim *)pa toLayer:(CALayer *)layer {
    if (!pa || !pa.keyPath.length || !layer) return;

    CAAnimation *anim = nil;

    BOOL hasValueList = (pa.values.count > 0);
    BOOL hasFromTo    = (pa.fromValueLiteral.length || pa.toValueLiteral.length);
    BOOL isKeyframe   = [pa.type isEqualToString:@"CAKeyframeAnimation"] || hasValueList;

    if (isKeyframe && hasValueList) {
        CAKeyframeAnimation *ka = [CAKeyframeAnimation animationWithKeyPath:pa.keyPath];
        ka.values = pa.values;
        if (pa.keyTimes.count == pa.values.count) ka.keyTimes = pa.keyTimes;
        if (pa.calculationMode.length) ka.calculationMode = pa.calculationMode;
        if (pa.timingFuncs.count) ka.timingFunctions = pa.timingFuncs;
        anim = ka;
    } else if (hasFromTo || [pa.type isEqualToString:@"CABasicAnimation"]) {
        CABasicAnimation *ba = [CABasicAnimation animationWithKeyPath:pa.keyPath];
        // Try to coerce literal strings to NSNumber, falling back to
        // raw string. iOS scalar key paths accept NSNumber.
        if (pa.fromValueLiteral.length) ba.fromValue = @(pa.fromValueLiteral.doubleValue);
        if (pa.toValueLiteral.length)   ba.toValue   = @(pa.toValueLiteral.doubleValue);
        anim = ba;
    } else {
        // Unknown / empty animation block - skip.
        return;
    }

    anim.duration = pa.duration > 0 ? pa.duration : 0.25;
    if (pa.hasBeginTime && pa.beginTime > 0) {
        // CAAnimation.beginTime is layer-time; convert from media time
        // to the layer's timespace so beginTime="1e-100" doesn't get
        // interpreted as "ages ago".
        anim.beginTime = [layer convertTime:CACurrentMediaTime() fromLayer:nil] + pa.beginTime;
    }
    anim.autoreverses = pa.autoreverses;
    if (pa.repeatInf) {
        anim.repeatCount = HUGE_VALF;
    } else if (pa.repeatCount > 0) {
        anim.repeatCount = pa.repeatCount;
    }
    if (pa.fillMode.length) anim.fillMode = pa.fillMode;
    if (pa.hasSpeed) anim.speed = pa.speed;
    if (pa.hasRemovedOnCompletion) anim.removedOnCompletion = pa.removedOnCompletion;

    CAMediaTimingFunction *tf = PPMakeTimingFunction(pa.timingFunctionSpec);
    if (tf) anim.timingFunction = tf;

    NSString *key = [NSString stringWithFormat:@"pp_%@_%ld", pa.keyPath, (long)(self.animKeyCounter++)];
    [layer addAnimation:anim forKey:key];
}

#pragma mark NSXMLParserDelegate

- (void)parser:(NSXMLParser *)parser
didStartElement:(NSString *)elementName
  namespaceURI:(NSString *)namespaceURI
 qualifiedName:(NSString *)qName
    attributes:(NSDictionary<NSString *, NSString *> *)attrs {

    // ---------------- States ----------------
    if ([elementName isEqualToString:@"states"]) {
        self.inStates = YES;
        return;
    }
    if (self.inStates) {
        if ([elementName isEqualToString:@"LKState"]) {
            self.currentState = [PPCAMLState new];
            self.currentState.name = attrs[@"name"];
            self.currentStateValues = [NSMutableArray array];
            return;
        }
        if ([elementName isEqualToString:@"LKStateSetValue"]) {
            self.currentStateValue = [PPCAMLStateValue new];
            self.currentStateValue.targetId = attrs[@"targetId"];
            self.currentStateValue.keyPath  = attrs[@"keyPath"];
            return;
        }
        if ([elementName isEqualToString:@"value"]) {
            if (!self.currentStateValue) return;
            NSString *type = attrs[@"type"];
            NSString *v    = attrs[@"value"];
            if ([type isEqualToString:@"integer"] || [type isEqualToString:@"real"]) {
                self.currentStateValue.value = @(v.doubleValue);
            } else if ([type isEqualToString:@"point"]) {
                self.currentStateValue.value = [NSValue valueWithCGPoint:PPParsePoint(v)];
            } else if ([type isEqualToString:@"size"]) {
                NSArray<NSNumber *> *n = PPParseNumberList(v);
                if (n.count >= 2) self.currentStateValue.value = [NSValue valueWithCGSize:CGSizeMake(n[0].doubleValue, n[1].doubleValue)];
            } else if ([type isEqualToString:@"rect"]) {
                self.currentStateValue.value = [NSValue valueWithCGRect:PPParseRect(v)];
            } else if ([type isEqualToString:@"color"]) {
                self.currentStateValue.value = PPParseColor(v);
            } else {
                // Default: try numeric, else string
                if (v.length && (isdigit([v characterAtIndex:0]) || [v characterAtIndex:0] == '-' || [v characterAtIndex:0] == '.')) {
                    self.currentStateValue.value = @(v.doubleValue);
                } else {
                    self.currentStateValue.value = v;
                }
            }
            return;
        }
        // Anything else inside <states> -- ignore for now (transitions, animations).
        return;
    }

    // ---------------- <animations> blocks ----------------
    //
    // Structure:
    //   <CALayer ...>
    //     <animations>
    //       <animation type="CAKeyframeAnimation" keyPath="position.x"
    //                  duration="2" repeatCount="inf" autoreverses="1">
    //         <keyTimes>
    //           <integer value="0"/>
    //           <integer value="1"/>
    //         </keyTimes>
    //         <values>
    //           <real value="100"/>
    //           <real value="200"/>
    //         </values>
    //         <timingFunctions>
    //           <CAMediaTimingFunction name="easeInEaseOut"/>
    //         </timingFunctions>
    //       </animation>
    //       <animation type="CABasicAnimation" keyPath="opacity"
    //                  duration="1" fromValue="0" toValue="1"/>
    //       <p key="animation-1" type="CAKeyframeAnimation" .../> ← seen in
    //                                                                Waves Bundle
    //     </animations>
    //   </CALayer>
    //
    // We attach the resulting CAAnimation directly to the layer via
    // -addAnimation:forKey: on </animation>, so Core Animation drives
    // it itself - no per-frame ticking from our side.
    if ([elementName isEqualToString:@"animations"]) {
        self.animationsDepth++;
        return;
    }
    if (self.animationsDepth > 0) {
        // Inside an <animations>: each direct child is one animation.
        if ([elementName isEqualToString:@"animation"] ||
            [elementName isEqualToString:@"p"]) {
            // <p key="..."> is what some authoring tools emit; same shape.
            self.currentAnim = [PPPendingAnim new];
            self.currentAnim.type    = attrs[@"type"] ?: @"CABasicAnimation";
            self.currentAnim.keyPath = attrs[@"keyPath"];
            self.currentAnim.keyTimes = [NSMutableArray array];
            self.currentAnim.values   = [NSMutableArray array];
            self.currentAnim.timingFuncs = [NSMutableArray array];

            NSString *dur = attrs[@"duration"];
            if (dur.length) self.currentAnim.duration = dur.doubleValue;

            NSString *bt = attrs[@"beginTime"];
            if (bt.length) {
                self.currentAnim.beginTime = bt.doubleValue;
                // 1e-100 is the "start immediately" idiom in CAML;
                // anything below ~1e-6 we treat as "no offset" so we
                // don't pin the animation to time 0 in absolute media
                // time (which would be ~years ago).
                if (self.currentAnim.beginTime > 1e-6) {
                    self.currentAnim.hasBeginTime = YES;
                }
            }

            NSString *ar = attrs[@"autoreverses"];
            if (ar.length) self.currentAnim.autoreverses = ar.boolValue;

            NSString *roc = attrs[@"removedOnCompletion"];
            if (roc.length) {
                self.currentAnim.removedOnCompletion = roc.boolValue;
                self.currentAnim.hasRemovedOnCompletion = YES;
            }

            NSString *spd = attrs[@"speed"];
            if (spd.length) {
                self.currentAnim.speed = spd.doubleValue;
                self.currentAnim.hasSpeed = YES;
            }

            NSString *rc = attrs[@"repeatCount"];
            if (rc.length) {
                if ([rc isEqualToString:@"inf"] || [rc isEqualToString:@"infinity"]) {
                    self.currentAnim.repeatInf = YES;
                } else {
                    self.currentAnim.repeatCount = rc.doubleValue;
                }
            }

            self.currentAnim.fillMode        = attrs[@"fillMode"];
            self.currentAnim.calculationMode = attrs[@"calculationMode"];
            self.currentAnim.timingFunctionSpec = attrs[@"timingFunction"];
            self.currentAnim.fromValueLiteral   = attrs[@"fromValue"];
            self.currentAnim.toValueLiteral     = attrs[@"toValue"];
            return;
        }
        if (!self.currentAnim) return;

        // Sub-arrays of the animation
        if ([elementName isEqualToString:@"keyTimes"]) {
            self.currentAnim.currentList = @"keyTimes";
            return;
        }
        if ([elementName isEqualToString:@"values"]) {
            self.currentAnim.currentList = @"values";
            return;
        }
        if ([elementName isEqualToString:@"timingFunctions"]) {
            self.currentAnim.currentList = @"timingFunctions";
            return;
        }
        if ([elementName isEqualToString:@"CAMediaTimingFunction"]) {
            CAMediaTimingFunction *tf = nil;
            NSString *named = attrs[@"name"];
            if (named.length) {
                tf = PPMakeTimingFunction(named);
            } else {
                NSString *pts = attrs[@"controlPoints"] ?: attrs[@"value"];
                if (pts.length) tf = PPMakeTimingFunction(pts);
            }
            if (tf) [self.currentAnim.timingFuncs addObject:tf];
            return;
        }

        // Element inside one of the lists
        if ([self.currentAnim.currentList isEqualToString:@"keyTimes"]) {
            id v = PPCoerceAnimationValue(elementName, attrs);
            if ([v isKindOfClass:[NSNumber class]]) {
                [self.currentAnim.keyTimes addObject:(NSNumber *)v];
            }
            return;
        }
        if ([self.currentAnim.currentList isEqualToString:@"values"]) {
            id v = PPCoerceAnimationValue(elementName, attrs);
            if (v) [self.currentAnim.values addObject:v];
            return;
        }
        // Anything else inside an <animation>: ignore (filters, etc).
        return;
    }

    // ---------------- Layer tree ----------------
    if ([elementName isEqualToString:@"sublayers"]) {
        self.inSublayers = YES;
        return;
    }
    if ([elementName isEqualToString:@"contents"]) {
        self.inContents = YES;
        // Two CAML conventions in the wild:
        //
        //   (a) Long form with a child <CGImage>:
        //         <contents>
        //           <CGImage src="assets/foo.png"/>
        //         </contents>
        //       This is what CAPlayground emits. (Dark, etc.)
        //
        //   (b) Short form with the src on <contents> itself:
        //         <contents type="CGImage" src="assets/foo.png"/>
        //       This is what Apple's authoring tools and many community
        //       posts emit. (Waves Bundle, MarioGalaxy, ...)
        //
        // We need to support BOTH or wallpapers from one camp render
        // as a colored background with no objects.
        //
        // Owner can be either the layer we're currently in, or the
        // CAEmitterCell we're currently filling (cells use `contents`
        // the same way layers do, for the particle texture).
        NSString *src = attrs[@"src"];
        if (src.length) {
            NSString *decoded = [src stringByRemovingPercentEncoding] ?: src;
            NSString *imgPath = [self.assetsPath stringByAppendingPathComponent:[decoded lastPathComponent]];
            UIImage *img = PPLoadImageAtPath(imgPath);
            BOOL toCell = (self.cellStack.count > 0);
            if (img) {
                gPPImagesLoaded++;
                if (toCell) {
                    CAEmitterCell *cell = self.cellStack.lastObject;
                    cell.contents = (__bridge id)img.CGImage;
                    // Only set contentsScale from the image if the cell
                    // attribute didn't already pin one — otherwise we'd
                    // overwrite e.g. contentsScale="16.67" from the
                    // CAML with the image's natural scale (usually 1.0)
                    // and the particle would render giant.
                    if (cell.contentsScale == 1.0) {
                        cell.contentsScale = img.scale;
                    }
                } else {
                    CALayer *cur = self.layerStack.lastObject;
                    if (cur) {
                        cur.contents = (__bridge id)img.CGImage;
                        if (cur.contentsScale == 1.0) {
                            cur.contentsScale = img.scale;
                        }
                    }
                }
            } else {
                gPPImagesMissing++;
                NSLog(@"[PocketPlayer] missing image: %@", imgPath);
            }
            if (gPPEmitterDumpBudget > 0) {
                PPDumpEmitter([NSString stringWithFormat:
                    @"  contents short form: src=%@ -> %@ owner=%@ size=%@",
                    decoded,
                    img ? @"OK" : @"FAILED",
                    toCell ? @"CELL" : @"LAYER",
                    img ? NSStringFromCGSize(img.size) : @"-"]);
            }
        }
        return;
    }
    if ([elementName isEqualToString:@"CGImage"] && self.inContents) {
        // <CGImage> long-form contents. Owner is whichever is on top:
        // a CAEmitterCell currently being filled (cells use `contents`
        // for their particle texture), or the current CALayer.
        NSString *src = attrs[@"src"];
        if (src.length) {
            NSString *decoded = [src stringByRemovingPercentEncoding] ?: src;
            NSString *imgPath = [self.assetsPath stringByAppendingPathComponent:[decoded lastPathComponent]];
            UIImage *img = PPLoadImageAtPath(imgPath);
            if (img) {
                gPPImagesLoaded++;
                if (self.cellStack.count) {
                    CAEmitterCell *cell = self.cellStack.lastObject;
                    cell.contents = (__bridge id)img.CGImage;
                    if (cell.contentsScale == 1.0) {
                        cell.contentsScale = img.scale;
                    }
                } else {
                    CALayer *cur = self.layerStack.lastObject;
                    if (cur) {
                        cur.contents = (__bridge id)img.CGImage;
                        if (cur.contentsScale == 1.0) {
                            cur.contentsScale = img.scale;
                        }
                    }
                }
            } else {
                gPPImagesMissing++;
                NSLog(@"[PocketPlayer] missing image: %@", imgPath);
            }
        }
        return;
    }

    // ---------------- Emitter cells ----------------
    //
    // <emitterCells>  is just a container; we track depth to know we're
    // inside one (so a stray <CAEmitterCell> outside this wrapper isn't
    // accidentally treated as a particle definition).
    //
    // <CAEmitterCell> ... </CAEmitterCell>  describes one particle.
    //   - Attaches to the parent CAEmitterLayer's `emitterCells`, OR
    //     to the parent CAEmitterCell's `emitterCells` (CAEmitterCell
    //     can itself contain child cells).
    if ([elementName isEqualToString:@"emitterCells"]) {
        self.inEmitterCellsDepth++;
        return;
    }
    if ([elementName isEqualToString:@"CAEmitterCell"]) {
        CAEmitterCell *cell = [CAEmitterCell emitterCell];
        gPPCellsBuilt++;
        for (NSString *k in attrs) {
            PPApplyEmitterCellAttribute(cell, k, attrs[k]);
        }
        // NOTE: don't dump here — <contents> hasn't been parsed yet,
        // so cell.contents is still nil. We dump on the closing tag,
        // which fires after all children have been processed.
        // Attach to parent cell (nested case) or to the owning emitter
        // layer. We can't actually mutate `emitterCells` until we
        // close the parent's tag because some authoring tools list a
        // bunch of siblings -- so we collect into a temp array via
        // associated state and assign on the parent's close.
        //
        // To keep the existing tree walk linear we just *append* to
        // the parent's emitterCells right now via a fresh array each
        // time (copy + append). Cheap; emitter cell counts are small
        // (< 100 per layer, typically 1-4).
        if (self.cellStack.count) {
            CAEmitterCell *parent = self.cellStack.lastObject;
            NSArray *existing = parent.emitterCells ?: @[];
            parent.emitterCells = [existing arrayByAddingObject:cell];
        } else {
            CALayer *owner = self.layerStack.lastObject;
            if ([owner isKindOfClass:[CAEmitterLayer class]]) {
                CAEmitterLayer *em = (CAEmitterLayer *)owner;
                NSArray *existing = em.emitterCells ?: @[];
                em.emitterCells = [existing arrayByAddingObject:cell];
            }
        }
        [self.cellStack addObject:cell];
        return;
    }

    if ([elementName isEqualToString:@"CALayer"] ||
        [elementName isEqualToString:@"CATransformLayer"] ||
        [elementName isEqualToString:@"CAShapeLayer"] ||
        [elementName isEqualToString:@"CAEmitterLayer"]) {

        CALayer *layer;
        if ([elementName isEqualToString:@"CATransformLayer"]) {
            layer = [CATransformLayer layer];
        } else if ([elementName isEqualToString:@"CAShapeLayer"]) {
            layer = [CAShapeLayer layer];
        } else if ([elementName isEqualToString:@"CAEmitterLayer"]) {
            layer = [CAEmitterLayer layer];
            gPPEmittersBuilt++;
            // CAEmitterLayer needs a non-zero beginTime to start
            // emitting once attached. Without this the emitter sits
            // at timeline=0 and never produces particles, even with
            // birthRate > 0. We assign here on creation; if Apple's
            // anim system later overrides via the CAML <animations>
            // block, that's fine -- ours just primes the timeline.
            ((CAEmitterLayer *)layer).beginTime = CACurrentMediaTime();
        } else {
            layer = [CALayer layer];
        }
        // Apply attributes (CALayer properties for any layer kind, plus
        // emitter-layer-only properties when applicable).
        for (NSString *k in attrs) {
            [self applyAttribute:k value:attrs[k] toLayer:layer];
        }
        if ([layer isKindOfClass:[CAEmitterLayer class]]) {
            CAEmitterLayer *em = (CAEmitterLayer *)layer;
            for (NSString *k in attrs) {
                PPApplyEmitterLayerAttribute(em, k, attrs[k]);
            }
            if (gPPEmitterDumpBudget > 0) {
                // Don't decrement here — let cells share the budget.
                PPDumpEmitter([NSString stringWithFormat:
                    @"emitter bounds=%@ pos=%@ size=%@ shape=%@ mode=%@ render=%@ birthRate=%.2f lifetime=%.2f velocity=%.2f scale=%.2f speed=%.2f",
                    NSStringFromCGRect(em.bounds),
                    NSStringFromCGPoint(em.position),
                    NSStringFromCGSize(em.emitterSize),
                    em.emitterShape ?: @"-",
                    em.emitterMode  ?: @"-",
                    em.renderMode   ?: @"-",
                    em.birthRate, em.lifetime, em.velocity, em.scale, em.speed]);
            }
        }

        NSString *layerId = attrs[@"id"];
        if (layerId.length) self.doc.mLayersById[layerId] = layer;

        // Attach to parent
        CALayer *parent = self.layerStack.lastObject;
        if (parent) {
            [parent addSublayer:layer];
        } else {
            // First layer -> rootLayer
            self.doc.rootLayer = layer;
        }
        [self.layerStack addObject:layer];
        return;
    }
}

- (void)parser:(NSXMLParser *)parser
 didEndElement:(NSString *)elementName
  namespaceURI:(NSString *)namespaceURI
 qualifiedName:(NSString *)qName {

    if ([elementName isEqualToString:@"states"]) {
        self.inStates = NO;
        return;
    }
    if (self.inStates) {
        if ([elementName isEqualToString:@"LKState"]) {
            if (self.currentState && self.currentState.name) {
                self.currentState.values = [self.currentStateValues copy] ?: @[];
                if (!self.doc.mStates[self.currentState.name]) {
                    [self.doc.mStateOrder addObject:self.currentState.name];
                }
                self.doc.mStates[self.currentState.name] = self.currentState;
            }
            self.currentState = nil;
            self.currentStateValues = nil;
            return;
        }
        if ([elementName isEqualToString:@"LKStateSetValue"]) {
            if (self.currentStateValue && self.currentStateValue.targetId && self.currentStateValue.keyPath) {
                [self.currentStateValues addObject:self.currentStateValue];
            }
            self.currentStateValue = nil;
            return;
        }
        return;
    }

    // Animation block close
    if ([elementName isEqualToString:@"animations"]) {
        if (self.animationsDepth > 0) self.animationsDepth--;
        return;
    }
    if (self.animationsDepth > 0) {
        if ([elementName isEqualToString:@"keyTimes"] ||
            [elementName isEqualToString:@"values"] ||
            [elementName isEqualToString:@"timingFunctions"]) {
            self.currentAnim.currentList = nil;
            return;
        }
        if ([elementName isEqualToString:@"animation"] ||
            [elementName isEqualToString:@"p"]) {
            // The <animations> block is a direct child of the layer it
            // applies to, so the *current* layer on the stack is the
            // owner. Materialize and attach.
            CALayer *owner = self.layerStack.lastObject;
            [self attachPendingAnim:self.currentAnim toLayer:owner];
            self.currentAnim = nil;
            return;
        }
        return;
    }

    if ([elementName isEqualToString:@"sublayers"]) { self.inSublayers = NO; return; }
    if ([elementName isEqualToString:@"contents"])  { self.inContents = NO;  return; }
    if ([elementName isEqualToString:@"emitterCells"]) {
        if (self.inEmitterCellsDepth > 0) self.inEmitterCellsDepth--;
        return;
    }
    if ([elementName isEqualToString:@"CAEmitterCell"]) {
        if (self.cellStack.count) {
            CAEmitterCell *cell = self.cellStack.lastObject;
            // Dump now: contents has been set (or not) by the
            // <contents>/<CGImage> child handlers above.
            if (gPPEmitterDumpBudget-- > 0) {
                CGImageRef cg = (__bridge CGImageRef)cell.contents;
                size_t cw = cg ? CGImageGetWidth(cg) : 0;
                size_t ch = cg ? CGImageGetHeight(cg) : 0;
                PPDumpEmitter([NSString stringWithFormat:
                    @"cell-CLOSE name=%@ birthRate=%.2f lifetime=%.2f velocity=%.2f "
                    @"scale=%.2f scaleRange=%.2f contentsScale=%.2f "
                    @"contents=%@ cgSize=%zux%zu particleType=%@",
                    cell.name ?: @"-",
                    cell.birthRate, cell.lifetime, cell.velocity,
                    cell.scale, cell.scaleRange,
                    cell.contentsScale,
                    cell.contents ? @"YES" : @"NO",
                    cw, ch,
                    [cell valueForKey:@"particleType"] ?: @"-"]);
            }
            [self.cellStack removeLastObject];
        }
        return;
    }

@end

#pragma mark - Debug: emitter collection

@implementation CALayer (PPDebug)
- (NSArray<CAEmitterLayer *> *)pp_collectEmitters {
    NSMutableArray *out = [NSMutableArray array];
    if ([self isKindOfClass:[CAEmitterLayer class]]) {
        [out addObject:(CAEmitterLayer *)self];
    }
    for (CALayer *l in self.sublayers) {
        [out addObjectsFromArray:[l pp_collectEmitters]];
    }
    return out;
}
@end
