#import "LFLockScreenWidget.h"
#import <CoreText/SFNTLayoutTypes.h>

@implementation LFLockScreenWidgetDescriptor
@end

@interface LFLockScreenWidget () {
    LFWidgetKind   _kind;
    LFWidgetFamily _family;
    NSDictionary  *_config;

    // Held weak so the subclass owns the actual subview tree; we
    // just keep pointers so layoutSubviews can keep the corner
    // radius and rim in sync with the live bounds.
    __weak UIVisualEffectView *_glassBackdrop;
    __weak UIView             *_glassRim;
}
@end

@implementation LFLockScreenWidget

- (instancetype)initWithKind:(LFWidgetKind)kind
                      family:(LFWidgetFamily)family
                      config:(NSDictionary *)config {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    _kind   = kind;
    _family = family;
    _config = [config copy] ?: @{};
    self.userInteractionEnabled = NO;     // slot owns hits in edit mode
    self.backgroundColor        = [UIColor clearColor];
    self.layer.masksToBounds    = NO;
    return self;
}

- (LFWidgetKind)kind     { return _kind;   }
- (LFWidgetFamily)family { return _family; }
- (NSDictionary *)config { return _config; }

- (NSTimeInterval)preferredRefreshInterval { return 60.0; }
- (void)refreshContent                     { /* base no-op */ }

+ (CGSize)naturalSizeForFamily:(LFWidgetFamily)family {
    switch (family) {
        case LFWidgetFamilyCircular:    return CGSizeMake( 76, 76);
        case LFWidgetFamilyRectangular: return CGSizeMake(160, 76);
        case LFWidgetFamilyInline:      return CGSizeMake(  0, 22); // h fixed, w by text
    }
}

// ---------------------------------------------------------------------------
// Glass backdrop.
//
// Earlier iteration removed this entirely on the user's request so widgets
// would render straight on the wallpaper with no per-tile chip. That
// made widgets with strong visual content (Battery / Steps / Weather --
// rings, icons, etc) look great, but text-only widgets (Calendar /
// Reminders / WorldClock and Music's labels) became unreadable on busy
// wallpapers -- the user's words: "некоторые виджеты как надо а
// некоторые полное говно". The fix is consistency: every widget gets
// the SAME subtle translucent chip Apple actually uses on iOS 26 lock-
// screen widgets, properly rounded so it never looks like a grey
// rectangle.
//
// Each widget gets:
//   * a UIVisualEffectView with SystemUltraThinMaterialDark (very
//     light blur, just enough darken-and-blur to make text legible
//     on bright wallpapers without overpowering the photo);
//   * cornerRadius matched to family -- circular: h/2 = perfect
//     circle on 76x76, rectangular: 22pt = Apple's iOS 16/26 widget
//     tile radius, inline: h/2 = pill;
//   * a 0.5pt hairline rim inside the blur's contentView at white
//     alpha 0.18 -- same trick Apple uses to outline glass tiles
//     against busy wallpapers without darkening their interior;
//   * frame/cornerRadius re-synced in -layoutSubviews so circular
//     widgets keep a true circle even when the tray's integer-
//     rounded layout pass settles them at slightly different
//     dimensions.
// ---------------------------------------------------------------------------
- (UIVisualEffectView *)installGlassBackdrop {
    UIBlurEffect *eff = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    UIVisualEffectView *bg = [[UIVisualEffectView alloc] initWithEffect:eff];
    bg.frame              = self.bounds;
    bg.autoresizingMask   = UIViewAutoresizingFlexibleWidth |
                            UIViewAutoresizingFlexibleHeight;
    bg.layer.masksToBounds = YES;
    bg.layer.cornerRadius  = [self lf_cornerRadiusForFamily:_family bounds:self.bounds];
    [self insertSubview:bg atIndex:0];
    _glassBackdrop = bg;

    UIView *rim                  = [[UIView alloc] initWithFrame:bg.contentView.bounds];
    rim.autoresizingMask         = UIViewAutoresizingFlexibleWidth |
                                   UIViewAutoresizingFlexibleHeight;
    rim.userInteractionEnabled   = NO;
    rim.layer.borderWidth        = 0.5;
    rim.layer.borderColor        = [[UIColor colorWithWhite:1.0 alpha:0.18] CGColor];
    rim.layer.cornerRadius       = bg.layer.cornerRadius;
    [bg.contentView addSubview:rim];
    _glassRim = rim;
    return bg;
}

- (CGFloat)lf_cornerRadiusForFamily:(LFWidgetFamily)family bounds:(CGRect)b {
    switch (family) {
        case LFWidgetFamilyCircular:    return MIN(b.size.width, b.size.height) / 2.0;
        case LFWidgetFamilyRectangular: return 22.0;
        case LFWidgetFamilyInline:      return b.size.height / 2.0;
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (_glassBackdrop) {
        CGFloat r = [self lf_cornerRadiusForFamily:_family bounds:self.bounds];
        _glassBackdrop.layer.cornerRadius = r;
        _glassRim.layer.cornerRadius      = r;
    }
}

+ (UIFont *)systemFontOfSize:(CGFloat)size weight:(UIFontWeight)w {
    UIFont *base = [UIFont systemFontOfSize:size weight:w];
    UIFontDescriptor *d = [base.fontDescriptor
        fontDescriptorByAddingAttributes:@{
            UIFontDescriptorFeatureSettingsAttribute: @[
                @{ UIFontFeatureTypeIdentifierKey:    @(kNumberSpacingType),
                   UIFontFeatureSelectorIdentifierKey: @(kMonospacedNumbersSelector) },
            ],
        }];
    return d ? [UIFont fontWithDescriptor:d size:size] : base;
}

@end
