#import "LFLockScreenWidget.h"
#import <CoreText/SFNTLayoutTypes.h>

@implementation LFLockScreenWidgetDescriptor
@end

@interface LFLockScreenWidget () {
    LFWidgetKind   _kind;
    LFWidgetFamily _family;
    NSDictionary  *_config;

    // Held weakly via assign so the subclass owns the subview tree;
    // we just keep a pointer so layoutSubviews can keep its corner
    // radius and rim view in sync with bounds.
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
// Earlier rev attached a UIVisualEffectView with SystemUltraThinMaterialDark
// but never set a corner radius -- on iPhone 6s / iOS 15 SpringBoard this
// rendered as an opaque dark-grey rectangle behind every widget (user
// reported it as "просто серый квадрат"). UIVisualEffectView clips to its
// own layer.cornerRadius -- without it, masksToBounds=YES has nothing to
// round, and the system never inherits the parent's roundness.
//
// Now we:
//   * stamp cornerRadius on the BLUR VIEW (not on self) so the glass
//     itself is the rounded shape -- circular widgets get a true circle
//     (radius = h/2), rectangular widgets get the iOS 26 ~22pt rounded
//     rect, inline widgets don't even get a backdrop (caller-driven);
//   * add a hairline white rim 0.5pt at alpha 18% INSIDE the blur,
//     same trick Apple uses on iOS 16/26 widget chips to separate the
//     glass from a busy wallpaper without darkening it;
//   * track frame/cornerRadius from layoutSubviews so resizing the
//     widget keeps the corners correct.
// ---------------------------------------------------------------------------
- (UIVisualEffectView *)installGlassBackdrop {
    UIBlurEffect *eff = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    UIVisualEffectView *bg = [[UIVisualEffectView alloc] initWithEffect:eff];
    bg.frame              = self.bounds;
    bg.autoresizingMask   = UIViewAutoresizingFlexibleWidth |
                            UIViewAutoresizingFlexibleHeight;
    bg.layer.masksToBounds = YES;
    bg.layer.cornerRadius  = [self lf_cornerRadiusForFamily:_family bounds:self.bounds];
    bg.clipsToBounds       = YES;
    [self insertSubview:bg atIndex:0];
    _glassBackdrop = bg;

    // Hairline rim inside the blur. We add it to bg.contentView so it
    // composites correctly with the blur and doesn't get covered by
    // subclass-added subviews on top of `self`.
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
        case LFWidgetFamilyCircular:
            return MIN(b.size.width, b.size.height) / 2.0;
        case LFWidgetFamilyRectangular:
            // Apple's widget tile radius on iOS 16/26 is roughly 22pt.
            return 22.0;
        case LFWidgetFamilyInline:
            return b.size.height / 2.0;
    }
}

// Keep the backdrop's corner radius in sync with the live bounds --
// circular widgets in particular need this because the actual height
// can be rounded slightly differently on different layout passes
// (e.g. integer rounding in -[LFLockScreenWidgetTray layoutSubviews]).
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
