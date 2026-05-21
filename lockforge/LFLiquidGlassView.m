#import "LFLiquidGlassView.h"
#import "LFLiquidGlassMetalView.h"

// =====================================================================
// LFLiquidGlassView is now a thin shell that prefers the Metal-driven
// LFLiquidGlassMetalView (when LiquidGlassShaders.metallib was bundled
// AND the device has a Metal device, which is every iOS 15 iPhone),
// and falls back to the original UIVisualEffectView + tint + rim +
// specular setup when Metal isn't usable. The Metal path runs the
// LiquidGlassFragment.metal shader (refraction + chromatic dispersion
// + Fresnel rim) so the visible result is the iOS 26 Liquid Glass
// look on the digit shapes themselves -- which the masked-blur path
// never quite hit.
//
// All public setters (intensity / tintColor / glassCornerRadius /
// shimmer offset) are forwarded to whichever backend is active; the
// rest of the tweak (LFClockOverlay) doesn't know or care which one
// is running.
// =====================================================================

@interface LFLiquidGlassView ()
// Metal-driven backend (preferred). When non-nil, the legacy fields
// below stay at their initial nil values and aren't installed in the
// view hierarchy.
@property (nonatomic, strong) LFLiquidGlassMetalView *metalBackend;

// ----- Legacy fallback path (used when metalBackend is nil) -----
// The blur layer underneath. Style swapped between thin/regular based
// on intensity. Frame matches our bounds.
@property (nonatomic, strong) UIVisualEffectView  *blur;

// A thin tinted overlay -- gives the glass its color cast. Without
// this, the blur looks pure-white-ish and lacks personality.
@property (nonatomic, strong) UIView              *tintOverlay;

// 1pt rim outline along the top edge to mimic "light catching the
// upper rim of a glass". Drawn as a CAGradientLayer with white-to-clear
// across height = ~25% of the view, so the highlight only appears on
// the top quarter.
@property (nonatomic, strong) CAGradientLayer     *specularLayer;

// 1pt full border at low opacity, gives the whole shape a defined
// edge. Real glass has subtle edge refraction; this stand-in is just
// a uniform faint white outline.
@property (nonatomic, strong) CALayer             *rimLayer;
@end

@implementation LFLiquidGlassView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    _intensity         = 0;
    _tintColor         = [UIColor whiteColor];
    _glassCornerRadius = 18;
    self.userInteractionEnabled = NO;
    self.backgroundColor        = [UIColor clearColor];

    // Prefer Metal. If it's not available the legacy subviews are
    // built and the rest of the file behaves as before.
    if ([LFLiquidGlassMetalView isAvailable]) {
        _metalBackend                       = [[LFLiquidGlassMetalView alloc] initWithFrame:self.bounds];
        _metalBackend.autoresizingMask      = UIViewAutoresizingFlexibleWidth |
                                              UIViewAutoresizingFlexibleHeight;
        _metalBackend.intensity             = _intensity;
        _metalBackend.tintColor             = _tintColor;
        _metalBackend.glassCornerRadius     = _glassCornerRadius;
        [self addSubview:_metalBackend];
    } else {
        [self buildSubviews];
        [self applyIntensity];
    }

    return self;
}

- (void)buildSubviews {
    UIBlurEffect *eff = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
    _blur = [[UIVisualEffectView alloc] initWithEffect:eff];
    _blur.userInteractionEnabled = NO;
    [self addSubview:_blur];

    _tintOverlay = [UIView new];
    _tintOverlay.userInteractionEnabled = NO;
    [self addSubview:_tintOverlay];

    _specularLayer = [CAGradientLayer layer];
    _specularLayer.startPoint = CGPointMake(0.5, 0.0);
    _specularLayer.endPoint   = CGPointMake(0.5, 1.0);
    [self.layer addSublayer:_specularLayer];

    _rimLayer = [CALayer layer];
    _rimLayer.borderWidth = 1.0;
    _rimLayer.masksToBounds = YES;
    [self.layer addSublayer:_rimLayer];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (_metalBackend) {
        // Metal backend uses its own MTKView that resizes via
        // autoresizingMask; nothing else to lay out here. We must
        // NOT touch self.layer.cornerRadius / shadow because the
        // Metal view paints the rounded shape from the SDF inside
        // its fragment shader -- adding a cornerRadius here would
        // double-clip and lose the soft pixel-feathered edge.
        return;
    }
    _blur.frame                  = self.bounds;
    _tintOverlay.frame           = self.bounds;
    _rimLayer.frame              = self.bounds;
    _rimLayer.cornerRadius       = _glassCornerRadius;

    // Specular only fades in across the top 35% of the view -- below
    // that line the gradient is fully transparent.
    _specularLayer.frame         = self.bounds;
    _specularLayer.cornerRadius  = _glassCornerRadius;
    _specularLayer.masksToBounds = YES;

    self.layer.cornerRadius      = _glassCornerRadius;
    self.layer.masksToBounds     = NO;        // keep shadow visible
    _blur.layer.cornerRadius     = _glassCornerRadius;
    _blur.layer.masksToBounds    = YES;
    _tintOverlay.layer.cornerRadius   = _glassCornerRadius;
    _tintOverlay.layer.masksToBounds  = YES;
}

- (void)setIntensity:(NSInteger)v {
    _intensity = MAX(0, MIN(3, v));
    if (_metalBackend) {
        _metalBackend.intensity = _intensity;
        // Surface-hide LFLiquidGlassView itself when off so callers
        // that toggled .hidden via LFLiquidGlassView still see the
        // expected visibility -- LFClockOverlay reads self.hidden
        // implicitly through the layer's mask side-effects.
        self.hidden = (_intensity == 0);
        return;
    }
    [self applyIntensity];
}

- (void)setTintColor:(UIColor *)t {
    _tintColor = t ?: [UIColor whiteColor];
    if (_metalBackend) {
        _metalBackend.tintColor = _tintColor;
        return;
    }
    [self applyIntensity];
}

- (void)setGlassCornerRadius:(CGFloat)r {
    _glassCornerRadius = MAX(0, r);
    if (_metalBackend) {
        _metalBackend.glassCornerRadius = _glassCornerRadius;
        return;
    }
    [self setNeedsLayout];
}

// Maps the 0..3 intensity onto concrete blur style, tint alpha, rim
// alpha, specular alpha, shadow strength. Also handles the "off" case
// (intensity 0) where everything is hidden.
- (void)applyIntensity {
    BOOL on = _intensity > 0;
    self.hidden = !on;
    if (!on) return;

    UIBlurEffectStyle style;
    CGFloat tintA;       // tint overlay alpha (lower == more colored from wallpaper)
    CGFloat rimA;        // rim border alpha
    CGFloat specA;       // top-edge specular alpha
    CGFloat shadowA;     // drop shadow alpha
    switch (_intensity) {
        case 1: style = UIBlurEffectStyleSystemUltraThinMaterial;
                tintA = 0.05; rimA = 0.18; specA = 0.10; shadowA = 0.10; break;
        case 2: style = UIBlurEffectStyleSystemThinMaterial;
                tintA = 0.10; rimA = 0.30; specA = 0.18; shadowA = 0.14; break;
        case 3:
        default:style = UIBlurEffectStyleSystemMaterial;
                tintA = 0.16; rimA = 0.45; specA = 0.30; shadowA = 0.22; break;
    }
    _blur.effect      = [UIBlurEffect effectWithStyle:style];
    _tintOverlay.backgroundColor = [_tintColor colorWithAlphaComponent:tintA];
    _rimLayer.borderColor = [[UIColor colorWithWhite:1.0 alpha:rimA] CGColor];

    _specularLayer.colors = @[
        (__bridge id)[UIColor colorWithWhite:1.0 alpha:specA].CGColor,
        (__bridge id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor,
    ];
    _specularLayer.locations = @[ @0.0, @0.35 ];

    self.layer.shadowColor   = [[UIColor blackColor] CGColor];
    self.layer.shadowOpacity = (float)shadowA;
    self.layer.shadowRadius  = 8;
    self.layer.shadowOffset  = CGSizeMake(0, 2);
}

- (void)setShimmerOffset:(CGPoint)offset {
    if (_metalBackend) {
        [_metalBackend setShimmerOffset:offset];
        return;
    }
    if (!_gyroEffectsEnabled()) return;
    if (_intensity == 0) return;

    // Translate the specular layer a few points based on tilt; clamp
    // amplitude so it stays inside the glass bounds.
    CGFloat dx = MAX(-1, MIN(1, offset.x)) * 4.0;
    CGFloat dy = MAX(-1, MIN(1, offset.y)) * 2.0;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _specularLayer.transform = CATransform3DMakeTranslation(dx, dy, 0);
    [CATransaction commit];
}

// Tiny static helper to peek at the global toggle without importing
// LFClockSettings here. Avoids a circular import; settings header is
// included only by Tweak.x and the editor.
static BOOL _gyroEffectsEnabled(void) {
    static BOOL cached = YES;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:
            @"/var/mobile/Library/LockForge/clock.plist"];
        if (d[@"gyroEffectsEnabled"]) cached = [d[@"gyroEffectsEnabled"] boolValue];
    });
    return cached;
}

@end
