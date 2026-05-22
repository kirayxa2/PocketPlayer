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

// ---------------------------------------------------------------------------
// Glass backdrop -- INTENTIONAL NO-OP since iOS 26 lock screen widgets
// no longer have an opaque per-tile chip behind their content. The
// edit-mode "selection rectangle" lives on the TRAY itself (matching
// the chrome around clock and date), not on individual widgets. Each
// widget renders directly on the wallpaper.
//
// Subclasses still call -installGlassBackdrop in their constructors so
// the signature stays valid and existing widget code compiles unchanged.
// We return a tiny invisible UIVisualEffectView so the call site can
// keep its return-value type if it ever chooses to use it; the view
// has no effect (clear background) and adds nothing visible.
// ---------------------------------------------------------------------------
- (UIVisualEffectView *)installGlassBackdrop {
    UIVisualEffectView *bg = [[UIVisualEffectView alloc] initWithEffect:nil];
    bg.frame              = CGRectZero;
    bg.hidden             = YES;
    bg.userInteractionEnabled = NO;
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
