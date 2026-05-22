#import "LFLockScreenWidgetSlot.h"

@interface LFLockScreenWidgetSlot () {
    LFWidgetFamily _family;

    // Empty-state chrome: dashed border + plus glyph in the centre.
    CAShapeLayer *_dashLayer;
    UIImageView  *_plusGlyph;

    // Filled-state chrome: minus button anchored top-left, only
    // visible in edit mode.
    UIButton     *_removeButton;
}
@end

@implementation LFLockScreenWidgetSlot

- (instancetype)initWithFamily:(LFWidgetFamily)family {
    CGSize sz = [LFLockScreenWidget naturalSizeForFamily:family];
    self = [super initWithFrame:CGRectMake(0, 0, sz.width, sz.height)];
    if (!self) return nil;
    _family = family;
    self.backgroundColor      = [UIColor clearColor];
    self.userInteractionEnabled = YES;

    // Dashed border for empty state -- iOS 26 customize sheet uses a
    // pale 1pt dashed outline + a 24pt plus glyph centred.
    _dashLayer = [CAShapeLayer layer];
    _dashLayer.fillColor   = [[UIColor clearColor] CGColor];
    _dashLayer.strokeColor = [[UIColor colorWithWhite:1.0 alpha:0.50] CGColor];
    _dashLayer.lineWidth   = 1.0;
    _dashLayer.lineDashPattern = @[ @4, @3 ];
    [self.layer addSublayer:_dashLayer];

    _plusGlyph = [UIImageView new];
    _plusGlyph.contentMode = UIViewContentModeScaleAspectFit;
    _plusGlyph.tintColor   = [UIColor colorWithWhite:1.0 alpha:0.65];
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
            configurationWithPointSize:22 weight:UIImageSymbolWeightSemibold];
        _plusGlyph.image = [UIImage systemImageNamed:@"plus"
                                   withConfiguration:cfg];
    }
    [self addSubview:_plusGlyph];

    // Tap on the empty slot opens the picker.
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(onTap)];
    [self addGestureRecognizer:tap];

    // Minus button. Hidden by default; revealed in edit mode when
    // the slot has content.
    _removeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
            configurationWithPointSize:22 weight:UIImageSymbolWeightSemibold];
        UIImage *minus = [UIImage systemImageNamed:@"minus.circle.fill"
                                  withConfiguration:cfg];
        [_removeButton setImage:minus forState:UIControlStateNormal];
    }
    _removeButton.tintColor = [UIColor whiteColor];
    [_removeButton addTarget:self
                      action:@selector(onRemove)
            forControlEvents:UIControlEventTouchUpInside];
    _removeButton.hidden = YES;
    [self addSubview:_removeButton];

    return self;
}

- (LFWidgetFamily)family { return _family; }

- (void)setIsEditing:(BOOL)e {
    _isEditing = e;
    [self updateChrome];
}

- (void)setWidget:(LFLockScreenWidget *)w {
    if (_widget == w) return;
    [_widget removeFromSuperview];
    _widget = w;
    if (w) {
        w.frame = self.bounds;
        w.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                             UIViewAutoresizingFlexibleHeight;
        [self insertSubview:w atIndex:0];
    }
    [self updateChrome];
    [self setNeedsLayout];
}

- (void)updateChrome {
    BOOL empty = (_widget == nil);
    _dashLayer.hidden = !empty;
    _plusGlyph.hidden = !empty;
    _removeButton.hidden = !(_isEditing && !empty);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    CGFloat r = (_family == LFWidgetFamilyCircular) ? b.size.height / 2.0 : 18;
    UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:b cornerRadius:r];
    _dashLayer.path  = p.CGPath;
    _dashLayer.frame = b;
    CGFloat g = 26;
    _plusGlyph.frame = CGRectMake((b.size.width - g) / 2.0,
                                  (b.size.height - g) / 2.0, g, g);
    _removeButton.frame = CGRectMake(-10, -10, 28, 28);
    if (_widget) _widget.frame = b;
}

- (void)onTap {
    if (!_isEditing) return;             // taps inert outside edit mode
    if (_widget)     return;             // filled slot ignores body tap
    [self.delegate slotDidTapAdd:self];
}

- (void)onRemove {
    [self.delegate slotDidTapRemove:self];
}

@end
