// CAMLParser.m
#import "CAMLParser.h"

#pragma mark - Helpers

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
@end

@implementation PPCAMLParser

+ (PPCAMLDocument *)parseCAMLAtPath:(NSString *)camlPath assetsPath:(NSString *)assetsPath {
    NSData *data = [NSData dataWithContentsOfFile:camlPath];
    if (!data) {
        NSLog(@"[PocketPlayer] CAML file not found at %@", camlPath);
        return nil;
    }

    PPCAMLParser *p = [PPCAMLParser new];
    p.assetsPath = assetsPath;
    p.doc = [PPCAMLDocument new];
    p.layerStack = [NSMutableArray array];

    NSXMLParser *xml = [[NSXMLParser alloc] initWithData:data];
    xml.delegate = p;
    if (![xml parse]) {
        NSLog(@"[PocketPlayer] CAML parse failed: %@", xml.parserError);
        return nil;
    }

    [p.doc captureBaseValues];
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

#pragma mark Animation materialization

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
        return;
    }
    if ([elementName isEqualToString:@"CGImage"] && self.inContents) {
        CALayer *cur = self.layerStack.lastObject;
        NSString *src = attrs[@"src"];
        if (cur && src.length) {
            // src might be "assets/foo.png" or URL-encoded "Screenshot%20188.png".
            NSString *decoded = [src stringByRemovingPercentEncoding] ?: src;
            NSString *imgPath = [self.assetsPath stringByAppendingPathComponent:[decoded lastPathComponent]];
            UIImage *img = [UIImage imageWithContentsOfFile:imgPath];
            if (img) {
                cur.contents = (__bridge id)img.CGImage;
                cur.contentsScale = img.scale;
            }
        }
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
            // We don't (yet) parse CAEmitterCell. The wrapper CAEmitterLayer
            // is allocated as itself anyway so future emitter-cell support
            // can attach without reparenting; today it just renders nothing,
            // which is correct compared to crashing or skipping the layer.
            layer = [CAEmitterLayer layer];
        } else {
            layer = [CALayer layer];
        }

        // Apply attributes
        for (NSString *k in attrs) {
            [self applyAttribute:k value:attrs[k] toLayer:layer];
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

    if ([elementName isEqualToString:@"CALayer"] ||
        [elementName isEqualToString:@"CATransformLayer"] ||
        [elementName isEqualToString:@"CAShapeLayer"] ||
        [elementName isEqualToString:@"CAEmitterLayer"]) {
        if (self.layerStack.count) [self.layerStack removeLastObject];
        return;
    }
}

@end
