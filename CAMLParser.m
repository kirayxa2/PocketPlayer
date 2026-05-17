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
    }
    // transform="rotate(0deg)" etc -- skipped, the rotation.* already covers it
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
            NSString *imgPath = [self.assetsPath stringByAppendingPathComponent:[src lastPathComponent]];
            // src might be "assets/foo.png" - lastPathComponent gives "foo.png"
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
        [elementName isEqualToString:@"CAShapeLayer"]) {

        CALayer *layer;
        if ([elementName isEqualToString:@"CATransformLayer"]) layer = [CATransformLayer layer];
        else if ([elementName isEqualToString:@"CAShapeLayer"]) layer = [CAShapeLayer layer];
        else layer = [CALayer layer];

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

    if ([elementName isEqualToString:@"sublayers"]) { self.inSublayers = NO; return; }
    if ([elementName isEqualToString:@"contents"])  { self.inContents = NO;  return; }

    if ([elementName isEqualToString:@"CALayer"] ||
        [elementName isEqualToString:@"CATransformLayer"] ||
        [elementName isEqualToString:@"CAShapeLayer"]) {
        if (self.layerStack.count) [self.layerStack removeLastObject];
        return;
    }
}

@end
