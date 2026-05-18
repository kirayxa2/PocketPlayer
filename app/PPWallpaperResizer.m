#import "PPWallpaperResizer.h"
#import <UIKit/UIKit.h>

// =====================================================================
// Numeric attribute helpers
// =====================================================================

// Parse "1.5 2.5 3.5" -> @[1.5, 2.5, 3.5]. Returns nil if the string
// doesn't contain at least one number, so the caller knows to leave
// the original attribute untouched.
static NSArray<NSNumber *> *PPRParseNumbers(NSString *s) {
    if (!s.length) return nil;
    NSCharacterSet *sep = [NSCharacterSet characterSetWithCharactersInString:@" ,\t"];
    NSArray *parts = [s componentsSeparatedByCharactersInSet:sep];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *p in parts) {
        if (!p.length) continue;
        // Reject obvious non-numeric tokens (e.g. "0.5deg" inside transform=)
        // but accept leading +/- and decimal point.
        unichar c = [p characterAtIndex:0];
        BOOL numeric = (c >= '0' && c <= '9') || c == '-' || c == '+' || c == '.';
        if (!numeric) return nil;
        [out addObject:@(p.doubleValue)];
    }
    return out.count > 0 ? out : nil;
}

// "1.234567" -> "1.234567" but trims trailing zeros so we don't expand
// the file size unnecessarily and so emitted XML stays close in form
// to what the original author wrote.
static NSString *PPRFmt(double v) {
    if (v == 0) return @"0";
    if (v == (long long)v && fabs(v) < 1e15) {
        return [NSString stringWithFormat:@"%lld", (long long)v];
    }
    NSString *s = [NSString stringWithFormat:@"%.6f", v];
    // Trim trailing zeros, then trailing dot.
    NSUInteger end = s.length;
    while (end > 0 && [s characterAtIndex:end - 1] == '0') end--;
    if (end > 0 && [s characterAtIndex:end - 1] == '.') end--;
    return [s substringToIndex:end];
}

// Format a number list back to a single space-separated string,
// preserving the original count.
static NSString *PPRJoin(NSArray<NSNumber *> *nums) {
    NSMutableArray *parts = [NSMutableArray arrayWithCapacity:nums.count];
    for (NSNumber *n in nums) [parts addObject:PPRFmt(n.doubleValue)];
    return [parts componentsJoinedByString:@" "];
}

// XML-escape an attribute value (quote-safe).
static NSString *PPRXmlEsc(NSString *s) {
    if (!s.length) return @"";
    NSString *r = s;
    r = [r stringByReplacingOccurrencesOfString:@"&"  withString:@"&amp;"];
    r = [r stringByReplacingOccurrencesOfString:@"<"  withString:@"&lt;"];
    r = [r stringByReplacingOccurrencesOfString:@">"  withString:@"&gt;"];
    r = [r stringByReplacingOccurrencesOfString:@"\""  withString:@"&quot;"];
    return r;
}

// =====================================================================
// transform="scale(1.5) rotate(0.3) translate(10 20)" handling
// =====================================================================
//
// CoreAnimation accepts a textual "transform" attribute that is a
// space-separated list of scale(...) / translate(...) / rotate(...) /
// skew(...) / matrix(...) calls. translate() arguments are in point
// space and MUST be rescaled. scale(), rotate(), skew() are unitless
// or in radians/degrees and stay as-is.
static NSString *PPRRewriteTransform(NSString *t, double k) {
    if (!t.length || k == 1.0) return t;

    // Cheap parser: walk the string, find each "name(args)" call, and if
    // it's translate(...), rescale its args.
    NSMutableString *out = [NSMutableString stringWithCapacity:t.length];
    NSScanner *sc = [NSScanner scannerWithString:t];
    sc.charactersToBeSkipped = nil;
    NSCharacterSet *ws  = [NSCharacterSet whitespaceCharacterSet];
    NSCharacterSet *ident = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-"];

    while (!sc.isAtEnd) {
        // Copy whitespace through.
        NSString *spaces = nil;
        if ([sc scanCharactersFromSet:ws intoString:&spaces]) [out appendString:spaces];
        if (sc.isAtEnd) break;

        // Identifier?
        NSString *name = nil;
        NSUInteger savedLoc = sc.scanLocation;
        if (![sc scanCharactersFromSet:ident intoString:&name]) {
            // Not an identifier -- copy one char and continue.
            unichar c = [t characterAtIndex:sc.scanLocation];
            [out appendFormat:@"%C", c];
            sc.scanLocation = savedLoc + 1;
            continue;
        }

        // Open paren?
        if (sc.isAtEnd || [t characterAtIndex:sc.scanLocation] != '(') {
            [out appendString:name];
            continue;
        }
        sc.scanLocation += 1; // consume '('

        // Read args until ')'.
        NSString *args = nil;
        [sc scanUpToString:@")" intoString:&args];
        if (!sc.isAtEnd) sc.scanLocation += 1; // consume ')'

        if ([name isEqualToString:@"translate"]) {
            NSArray<NSNumber *> *nums = PPRParseNumbers(args ?: @"");
            if (nums.count >= 2) {
                NSMutableArray *scaled = [NSMutableArray array];
                for (NSNumber *n in nums) [scaled addObject:@(n.doubleValue * k)];
                [out appendFormat:@"%@(%@)", name, PPRJoin(scaled)];
                continue;
            }
        }
        // Default: pass through unchanged.
        [out appendFormat:@"%@(%@)", name, args ?: @""];
    }
    return out;
}

// =====================================================================
// Attribute rewrite rules — what gets multiplied by `k` (scale factor).
// =====================================================================
//
// Numeric attributes that are POINT-SCALAR (one number, in points):
static NSSet<NSString *> *PPRPointScalars(void) {
    static NSSet *s; static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithArray:@[
            @"cornerRadius", @"borderWidth",
            // Emitter scalars that are point-typed.
            @"velocity", @"velocityRange",
            @"xAcceleration", @"yAcceleration", @"zAcceleration",
            // shadowOffset is a CGSize but it's emitted as a single
            // bracketless 2-number string sometimes; guard with rect-list.
        ]];
    });
    return s;
}

// Attributes that hold a list of points-in-point-space:
//   bounds   -> "x y w h"
//   position -> "x y"
//   emitterPosition -> "x y" or "x y z"
//   emitterSize     -> "w h"
//   shadowOffset    -> "x y"
static NSSet<NSString *> *PPRPointVectors(void) {
    static NSSet *s; static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithArray:@[
            @"bounds", @"position",
            @"emitterPosition", @"emitterSize",
            @"shadowOffset", @"contentsRect",   // contentsRect is unit-fraction; we WON'T scale it (see below)
            @"contentsCenter",                  // also unit-fraction; ditto
        ]];
    });
    return s;
}

// Attributes that are unit-fraction (0..1) and must NEVER be scaled:
static NSSet<NSString *> *PPRUnitAttrs(void) {
    static NSSet *s; static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithArray:@[
            @"anchorPoint", @"anchorPointZ",
            @"contentsRect", @"contentsCenter",
            @"opacity",
        ]];
    });
    return s;
}

// Rewrites a single attribute value. Returns the new value, or `value`
// unchanged if no rule applies.
//
// `tag` is the element name (e.g. "CALayer"), `attr` is the attribute
// name. `k` is the linear scale factor we apply to point-space numbers.
static NSString *PPRRewriteAttr(NSString *tag, NSString *attr, NSString *value, double k) {
    if (k == 1.0 || !value.length) return value;

    // Unit-fraction attributes are never scaled.
    if ([PPRUnitAttrs() containsObject:attr]) return value;

    if ([attr isEqualToString:@"transform"]) {
        return PPRRewriteTransform(value, k);
    }

    // contentsScale is texture-density, NOT geometry. Never scale.
    if ([attr isEqualToString:@"contentsScale"]) return value;

    // Point-space scalar?
    if ([PPRPointScalars() containsObject:attr]) {
        NSArray<NSNumber *> *nums = PPRParseNumbers(value);
        if (nums.count == 1) return PPRFmt(nums.firstObject.doubleValue * k);
    }

    // Point-space vector (bounds, position, emitterPosition, emitterSize, shadowOffset)?
    if ([PPRPointVectors() containsObject:attr]) {
        // contentsRect / contentsCenter are unit-fraction even though
        // they look like vectors — handled above by Unit set check.
        NSArray<NSNumber *> *nums = PPRParseNumbers(value);
        if (nums.count >= 2) {
            NSMutableArray *scaled = [NSMutableArray arrayWithCapacity:nums.count];
            for (NSNumber *n in nums) [scaled addObject:@(n.doubleValue * k)];
            return PPRJoin(scaled);
        }
    }

    return value;
}

// =====================================================================
// XML rewriter — line-by-line scan, emitting modified output.
// =====================================================================
//
// We intentionally DON'T use NSXMLParser's SAX delegate here: we want
// to keep the original file byte-for-byte except for the attributes we
// touch. NSXMLParser would require a re-serialization step (no public
// XML *writer* on iOS) which is fragile.
//
// The implementation below is a small character-by-character scanner
// that finds attribute name="value" pairs and rewrites them. It also
// recognizes the special <value type="..." value="..."/> elements
// inside <states>, where the rescale rule depends on the type:
//
//   type="real" + keyPath that ends in .x/.y/.width/.height/.position
//                 -> rescale the single number
//   type="point" / "size"    -> rescale all numbers in the value
//   type="rect"              -> rescale all 4 numbers
//   type="path"              -> rescale (every other number is a coord)
//
// To know what `keyPath` the current <value> belongs to we maintain a
// tiny stack of the most recent <LKStateSetValue keyPath="..."/>.

@interface PPRWriter : NSObject {
    @public
    double             _k;
    NSMutableString *  _out;
    NSString *         _src;
    NSUInteger         _i;
    // Tag stack (just names, we don't need attrs after we've emitted).
    NSMutableArray<NSString *> *_tagStack;
    // Most recent LKStateSetValue keyPath (for typed <value>'s scaling rule).
    NSString *         _pendingKeyPath;
}
@end

@implementation PPRWriter

- (instancetype)initWithSource:(NSString *)src scale:(double)k {
    if ((self = [super init])) {
        _src = src;
        _k = k;
        _out = [NSMutableString stringWithCapacity:src.length];
        _tagStack = [NSMutableArray array];
        _i = 0;
    }
    return self;
}

- (BOOL)peek:(unichar)c {
    return _i < _src.length && [_src characterAtIndex:_i] == c;
}

- (unichar)cur {
    return _i < _src.length ? [_src characterAtIndex:_i] : 0;
}

// Should this <value type="real" value="N"/> be rescaled given the most
// recent surrounding LKStateSetValue keyPath? We rescale anything that
// looks like a point coordinate; we don't rescale unitless things like
// opacity or transform.rotation.z.
- (BOOL)shouldScaleStateValueWithType:(NSString *)type {
    NSString *kp = _pendingKeyPath;
    if (!kp.length) return NO;

    // Anchors and unit fractions: never.
    if ([kp containsString:@"anchorPoint"]) return NO;
    if ([kp containsString:@"contentsRect"]) return NO;
    if ([kp containsString:@"contentsCenter"]) return NO;
    if ([kp containsString:@"contentsScale"]) return NO;
    if ([kp containsString:@"opacity"]) return NO;
    if ([kp containsString:@"transform.rotation"]) return NO;
    if ([kp containsString:@"transform.scale"]) return NO;
    if ([kp containsString:@"transform.skew"]) return NO;
    if ([kp isEqualToString:@"hidden"]) return NO;

    // .position, .position.x, .position.y, bounds.size.width/height,
    // bounds.origin.x/y, frame, etc -> point space, scale.
    return YES;
}

// Rescale a <value type="..." value="..."/> string when appropriate.
// `type` is "real", "point", "size", "rect", "path", "transform", etc.
// `value` is the inner numeric content.
- (NSString *)rewriteStateValueOfType:(NSString *)type value:(NSString *)value {
    if (_k == 1.0 || !value.length) return value;

    if ([type isEqualToString:@"real"] || [type isEqualToString:@"integer"]) {
        if (![self shouldScaleStateValueWithType:type]) return value;
        NSArray *nums = PPRParseNumbers(value);
        if (nums.count == 1) return PPRFmt([nums.firstObject doubleValue] * _k);
        return value;
    }
    if ([type isEqualToString:@"point"] || [type isEqualToString:@"size"]) {
        // Point and Size in CAML state are POINT-space.
        NSArray *nums = PPRParseNumbers(value);
        if (nums.count >= 1) {
            NSMutableArray *out = [NSMutableArray array];
            for (NSNumber *n in nums) [out addObject:@(n.doubleValue * _k)];
            return PPRJoin(out);
        }
    }
    if ([type isEqualToString:@"rect"]) {
        NSArray *nums = PPRParseNumbers(value);
        if (nums.count >= 4) {
            NSMutableArray *out = [NSMutableArray array];
            for (NSNumber *n in nums) [out addObject:@(n.doubleValue * _k)];
            return PPRJoin(out);
        }
    }
    if ([type isEqualToString:@"path"]) {
        // SVG-ish path: M x y L x y C x y x y x y Q x y x y Z ...
        // Numbers are point-space; letters stay.
        NSMutableString *r = [NSMutableString string];
        NSScanner *sc = [NSScanner scannerWithString:value];
        sc.charactersToBeSkipped = nil;
        while (!sc.isAtEnd) {
            NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];
            NSString *spaces = nil;
            if ([sc scanCharactersFromSet:ws intoString:&spaces]) [r appendString:spaces];
            if (sc.isAtEnd) break;
            unichar c = [value characterAtIndex:sc.scanLocation];
            if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == ',') {
                [r appendFormat:@"%C", c];
                sc.scanLocation += 1;
                continue;
            }
            // Number?
            double dv = 0;
            NSUInteger save = sc.scanLocation;
            if ([sc scanDouble:&dv]) {
                [r appendFormat:@"%@", PPRFmt(dv * _k)];
            } else {
                [r appendFormat:@"%C", c];
                sc.scanLocation = save + 1;
            }
        }
        return r;
    }
    return value;
}

@end

// Rewrites the entire main.caml content. Returns new XML.
static NSString *PPRRewriteCAML(NSString *src, double k, NSError **error) {
    if (!src) return nil;
    if (k == 1.0) return src;

    PPRWriter *w = [[PPRWriter alloc] initWithSource:src scale:k];
    NSString *s = src;
    NSUInteger n = s.length;
    NSUInteger i = 0;

    while (i < n) {
        unichar c = [s characterAtIndex:i];

        // Plain text (between tags). Copy through.
        if (c != '<') {
            [w->_out appendFormat:@"%C", c];
            i++;
            continue;
        }

        // Tag start. Find end '>'.
        NSUInteger gt = i + 1;
        BOOL inQuote = NO;
        unichar q = 0;
        while (gt < n) {
            unichar gc = [s characterAtIndex:gt];
            if (inQuote) {
                if (gc == q) inQuote = NO;
            } else {
                if (gc == '"' || gc == '\'') { inQuote = YES; q = gc; }
                else if (gc == '>') break;
            }
            gt++;
        }
        if (gt >= n) {
            // Malformed -- bail out, return original.
            [w->_out appendString:[s substringFromIndex:i]];
            break;
        }

        NSString *tagFull = [s substringWithRange:NSMakeRange(i + 1, gt - i - 1)];
        // Don't try to rewrite comments, CDATA, processing instructions, doctype.
        if ([tagFull hasPrefix:@"!"] || [tagFull hasPrefix:@"?"]) {
            [w->_out appendFormat:@"<%@>", tagFull];
            i = gt + 1;
            continue;
        }

        BOOL closeTag = [tagFull hasPrefix:@"/"];
        BOOL selfClose = !closeTag && [tagFull hasSuffix:@"/"];
        NSString *body = closeTag ? [tagFull substringFromIndex:1] :
                         (selfClose ? [tagFull substringToIndex:tagFull.length - 1] : tagFull);
        body = [body stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

        // Tag name = until first whitespace or end.
        NSRange wsR = [body rangeOfCharacterFromSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *tagName = wsR.location == NSNotFound ? body : [body substringToIndex:wsR.location];
        NSString *attrPart = wsR.location == NSNotFound ? @"" : [body substringFromIndex:wsR.location];

        // Push/pop tag stack.
        if (closeTag) {
            if (w->_tagStack.count > 0 && [[w->_tagStack lastObject] isEqualToString:tagName]) {
                [w->_tagStack removeLastObject];
            }
            // If we were in an LKStateSetValue, clear pending keyPath when closed.
            if ([tagName isEqualToString:@"LKStateSetValue"]) {
                w->_pendingKeyPath = nil;
            }
            [w->_out appendFormat:@"</%@>", tagName];
            i = gt + 1;
            continue;
        }

        // Parse attributes from `attrPart` and rewrite.
        NSMutableString *newAttrs = [NSMutableString string];
        NSUInteger ap = 0, an = attrPart.length;
        // Per-tag captured info we need at <value type="x" value="y"/>.
        NSString *vType = nil;
        NSString *vValue = nil;
        BOOL vValueSeen = NO;

        while (ap < an) {
            unichar ac = [attrPart characterAtIndex:ap];
            if ([[NSCharacterSet whitespaceCharacterSet] characterIsMember:ac]) {
                [newAttrs appendFormat:@"%C", ac];
                ap++;
                continue;
            }
            // Read attr name = ident.
            NSUInteger ns = ap;
            while (ap < an) {
                unichar nc = [attrPart characterAtIndex:ap];
                if (nc == '=' || nc == '/' || nc == '>' ||
                    [[NSCharacterSet whitespaceCharacterSet] characterIsMember:nc]) break;
                ap++;
            }
            NSString *aname = [attrPart substringWithRange:NSMakeRange(ns, ap - ns)];
            if (!aname.length) {
                // copy single char and move on
                if (ap < an) {
                    [newAttrs appendFormat:@"%C", [attrPart characterAtIndex:ap]];
                    ap++;
                }
                continue;
            }

            // Skip ws then '='.
            while (ap < an && [[NSCharacterSet whitespaceCharacterSet] characterIsMember:[attrPart characterAtIndex:ap]]) ap++;
            if (ap >= an || [attrPart characterAtIndex:ap] != '=') {
                // Bare attribute (no value). Copy as-is.
                [newAttrs appendString:aname];
                continue;
            }
            ap++; // consume '='
            while (ap < an && [[NSCharacterSet whitespaceCharacterSet] characterIsMember:[attrPart characterAtIndex:ap]]) ap++;
            if (ap >= an) break;

            unichar quote = [attrPart characterAtIndex:ap];
            if (quote != '"' && quote != '\'') {
                // Unquoted -- copy char and continue.
                [newAttrs appendString:aname];
                [newAttrs appendString:@"="];
                continue;
            }
            ap++; // consume quote

            NSUInteger vs = ap;
            while (ap < an && [attrPart characterAtIndex:ap] != quote) ap++;
            NSString *avalueRaw = [attrPart substringWithRange:NSMakeRange(vs, ap - vs)];
            // Decode common XML entities so PPRRewriteAttr sees clean numbers.
            NSString *avalue = avalueRaw;
            avalue = [avalue stringByReplacingOccurrencesOfString:@"&amp;"  withString:@"&"];
            avalue = [avalue stringByReplacingOccurrencesOfString:@"&quot;" withString:@"\""];
            avalue = [avalue stringByReplacingOccurrencesOfString:@"&lt;"   withString:@"<"];
            avalue = [avalue stringByReplacingOccurrencesOfString:@"&gt;"   withString:@">"];
            if (ap < an) ap++; // consume closing quote

            NSString *newValue = avalue;

            // Special handling per-tag.
            if ([tagName isEqualToString:@"value"]) {
                if ([aname isEqualToString:@"type"])  vType = avalue;
                if ([aname isEqualToString:@"value"]) { vValue = avalue; vValueSeen = YES; }
                // Defer rewriting until we have both pieces -- but we still
                // need to emit attributes in order, so emit a placeholder we
                // patch later. Easier: collect all attrs, then re-emit.
                // For implementation simplicity here, we emit a temporary
                // marker for the "value" attr and patch after the loop.
                if ([aname isEqualToString:@"value"]) {
                    [newAttrs appendFormat:@"%@=\"\x01PPR_VALUE_PLACEHOLDER\x01\"", aname];
                    continue;
                }
            } else if ([tagName isEqualToString:@"LKStateSetValue"]) {
                if ([aname isEqualToString:@"keyPath"]) {
                    w->_pendingKeyPath = avalue;
                }
                // No rewriting of LKStateSetValue's own attributes.
            } else {
                // Generic CALayer-ish attribute rewriting.
                newValue = PPRRewriteAttr(tagName, aname, avalue, k);
            }

            [newAttrs appendFormat:@"%@=\"%@\"", aname, PPRXmlEsc(newValue)];
        }

        // If this was a <value type=... value=.../> tag we deferred, do
        // the rewrite now that we have type+value, and patch the marker.
        if ([tagName isEqualToString:@"value"] && vValueSeen) {
            NSString *patched = [w rewriteStateValueOfType:(vType ?: @"")
                                                     value:(vValue ?: @"")];
            NSString *marker = @"\x01PPR_VALUE_PLACEHOLDER\x01";
            [newAttrs replaceOccurrencesOfString:marker
                                      withString:PPRXmlEsc(patched)
                                         options:0
                                           range:NSMakeRange(0, newAttrs.length)];
        }

        if (!closeTag && !selfClose) {
            [w->_tagStack addObject:tagName];
        }

        if (selfClose) {
            [w->_out appendFormat:@"<%@%@/>", tagName, newAttrs];
            // Self-closing LKStateSetValue: clear keyPath context.
            if ([tagName isEqualToString:@"LKStateSetValue"]) {
                w->_pendingKeyPath = nil;
            }
        } else {
            [w->_out appendFormat:@"<%@%@>", tagName, newAttrs];
        }
        i = gt + 1;
    }

    return [w->_out copy];
}

// =====================================================================
// Wallpaper.plist tweaks
// =====================================================================
//
// PosterKit reads RenderingSize / LayerSizes out of the bundle's
// Wallpaper.plist on load. If the values disagree with what the CAML
// canvas now claims, PosterKit may stretch the result, defeating our
// per-canvas rescale. Setting these to the target size keeps the runtime
// honest.

static void PPRPatchWallpaperPlist(NSString *bundleDir, CGSize target) {
    NSString *plistPath = [bundleDir stringByAppendingPathComponent:@"Wallpaper.plist"];
    NSMutableDictionary *plist = [[NSMutableDictionary alloc]
        initWithContentsOfFile:plistPath];
    if (!plist) return;

    NSDictionary *sizeDict = @{
        @"width":  @(target.width),
        @"height": @(target.height),
    };

    // Common PosterKit keys -- we rewrite whichever exist. Don't add
    // missing ones, and don't touch anything else.
    if (plist[@"RenderingSize"]) plist[@"RenderingSize"] = sizeDict;
    if (plist[@"DeviceSize"])    plist[@"DeviceSize"]    = sizeDict;

    // LayerSizes is usually a dict of layerID->{width,height}. Replace
    // every value with the new target size; counter-intuitively this is
    // safer than trying to scale per-layer.
    if ([plist[@"LayerSizes"] isKindOfClass:[NSDictionary class]]) {
        NSDictionary *old = plist[@"LayerSizes"];
        NSMutableDictionary *new_ = [NSMutableDictionary dictionary];
        for (NSString *k in old) new_[k] = sizeDict;
        plist[@"LayerSizes"] = new_;
    }

    [plist writeToFile:plistPath atomically:YES];
}

// =====================================================================
// Discover author canvas size
// =====================================================================
//
// We want a single scale factor for the whole bundle (Background +
// Floating + Foreground), so all three rescale identically and stay
// pixel-aligned at composite time. The factor is derived from the
// LARGEST canvas across the three .ca's -- this is the canvas the
// author actually drew on; smaller .ca's are subordinate layers.

static CGSize PPRReadCanvasFromCAML(NSString *camlPath) {
    NSString *src = [NSString stringWithContentsOfFile:camlPath
                                              encoding:NSUTF8StringEncoding error:NULL];
    if (!src.length) return CGSizeZero;

    // Heuristic regex-ish: find the FIRST <CALayer ... bounds="x y w h">.
    // The root layer's bounds is the canvas.
    NSRange r = [src rangeOfString:@"bounds="];
    while (r.location != NSNotFound) {
        NSUInteger after = NSMaxRange(r);
        // Skip optional whitespace, expect quote.
        while (after < src.length && [[NSCharacterSet whitespaceCharacterSet]
            characterIsMember:[src characterAtIndex:after]]) after++;
        if (after >= src.length) break;
        unichar q = [src characterAtIndex:after];
        if (q != '"' && q != '\'') break;
        after++;
        NSUInteger end = after;
        while (end < src.length && [src characterAtIndex:end] != q) end++;
        NSString *boundsStr = [src substringWithRange:NSMakeRange(after, end - after)];
        NSArray *nums = PPRParseNumbers(boundsStr);
        if (nums.count >= 4) {
            double w = [nums[2] doubleValue];
            double h = [nums[3] doubleValue];
            if (w > 0 && h > 0) return CGSizeMake(w, h);
        }
        // Try the next match (rare: malformed first hit).
        NSRange next = NSMakeRange(end, src.length - end);
        r = [src rangeOfString:@"bounds=" options:0 range:next];
    }
    return CGSizeZero;
}

// =====================================================================
// Public API
// =====================================================================

@implementation PPWallpaperResizer

+ (BOOL)resizeBundleAtPath:(NSString *)bundleDir
                    toSize:(CGSize)targetSize
                     error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (targetSize.width <= 0 || targetSize.height <= 0) {
        if (error) *error = [NSError errorWithDomain:@"PocketPoster" code:30
            userInfo:@{NSLocalizedDescriptionKey: @"Invalid target size"}];
        return NO;
    }

    // Find every *.ca/main.caml inside the bundle.
    NSMutableArray<NSString *> *camlPaths = [NSMutableArray array];
    for (NSString *kid in [fm contentsOfDirectoryAtPath:bundleDir error:NULL]) {
        if (![kid hasSuffix:@".ca"]) continue;
        NSString *caml = [bundleDir stringByAppendingPathComponent:
                          [kid stringByAppendingPathComponent:@"main.caml"]];
        if ([fm fileExistsAtPath:caml]) [camlPaths addObject:caml];
    }
    if (camlPaths.count == 0) {
        if (error) *error = [NSError errorWithDomain:@"PocketPoster" code:31
            userInfo:@{NSLocalizedDescriptionKey: @"No *.ca/main.caml inside bundle"}];
        return NO;
    }

    // Pick the largest canvas across the bundle.
    CGSize canvas = CGSizeZero;
    for (NSString *p in camlPaths) {
        CGSize s = PPRReadCanvasFromCAML(p);
        if (s.width * s.height > canvas.width * canvas.height) canvas = s;
    }
    if (canvas.width <= 0 || canvas.height <= 0) {
        if (error) *error = [NSError errorWithDomain:@"PocketPoster" code:32
            userInfo:@{NSLocalizedDescriptionKey: @"Could not detect author canvas"}];
        return NO;
    }

    // Single linear scale -- "fill" semantics, matching Tweak.x.
    double sx = targetSize.width  / canvas.width;
    double sy = targetSize.height / canvas.height;
    double k  = MAX(sx, sy);

    // Skip the heavy work if everything is already ~unit-scale.
    // (e.g. a wallpaper authored exactly for this device.)
    BOOL skip = fabs(k - 1.0) < 0.001;

    if (!skip) {
        for (NSString *p in camlPaths) {
            NSString *src = [NSString stringWithContentsOfFile:p
                                                      encoding:NSUTF8StringEncoding
                                                         error:NULL];
            if (!src) continue;
            NSError *werr = nil;
            NSString *out = PPRRewriteCAML(src, k, &werr);
            if (!out) {
                if (error) *error = werr;
                return NO;
            }
            // Atomic write.
            NSError *fwerr = nil;
            if (![out writeToFile:p
                       atomically:YES
                         encoding:NSUTF8StringEncoding
                            error:&fwerr]) {
                if (error) *error = fwerr;
                return NO;
            }
        }
    }

    // Always update Wallpaper.plist (cheap, idempotent).
    PPRPatchWallpaperPlist(bundleDir, targetSize);

    return YES;
}

+ (BOOL)resizeBundleAtPath:(NSString *)bundleDir
       toMainScreenWithError:(NSError **)error {
    UIScreen *s = [UIScreen mainScreen];
    CGSize sz = s.bounds.size;
    return [self resizeBundleAtPath:bundleDir toSize:sz error:error];
}

@end
