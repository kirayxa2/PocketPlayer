#import "LFLockScreenWidget.h"
#import <CoreText/SFNTLayoutTypes.h>

@implementation LFLockScreenWidgetDescriptor
@end

@interface LFLockScreenWidget () {
    LFWidgetKind   _kind;
    LFWidgetFamily _family;
    NSDictionary  *_config;
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

- (UIVisualEffectView *)installGlassBackdrop {
    UIBlurEffect *eff = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    UIVisualEffectView *bg = [[UIVisualEffectView alloc] initWithEffect:eff];
    bg.frame              = self.bounds;
    bg.autoresizingMask   = UIViewAutoresizingFlexibleWidth |
                            UIViewAutoresizingFlexibleHeight;
    bg.layer.masksToBounds = YES;
    [self addSubview:bg];
    return bg;
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
