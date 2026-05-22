#import "LFLockScreenWidgetSlot.h"

@interface LFLockScreenWidgetSlot () {
    LFWidgetFamily _family;

    // Empty-state chrome: dashed border + plus glyph in the centre.
    CAShapeLayer *_dashLayer;
    UIImageView  *_plusGlyph;

    // Filled-state chrome: minus button anchored top-left, only
    // visible in edit mode AND while the editor's bottom customize-
    // panel is up (matches iOS 26 behaviour).
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

- (void)setBottomPanelOpen:(BOOL)open {
    _bottomPanelOpen = open;
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
    // Minus button is visible whenever the slot is occupied AND
    // the tray is in edit mode. We tried gating it on the editor's
    // bottom-panel visibility (the iOS 26 customize-sheet pattern)
    // but the user prefers the older flow where the minus is
    // available straight from the regular edit mode without having
    // to toggle the bottom panel first. The bottomPanelOpen flag
    // is still tracked and propagated through the view tree so
    // future tweaks can reuse it -- it just no longer gates this
    // particular control.
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
    // Minus button frame -- larger than the visible glyph so the
    // fingertip target is forgiving. iOS 26 uses a 30pt visible glyph
    // inside a ~44pt invisible touch target. The visible image-view
    // alignment auto-centers the glyph inside the button frame.
    _removeButton.frame = CGRectMake(-14, -14, 36, 36);
    if (_widget) _widget.frame = b;
}

// The minus button sits with its centre at slot's top-left corner
// (frame origin -14,-14), so the OUTER half of the button hangs
// outside self.bounds. UIKit hit-testing clips at bounds, which means
// touches on that outer half were silently dropped -- which is what
// the user reported as "сложно нажать на кнопку удаления". Override
// hit-test so we route minus-button touches to it directly.
//
// Also expand the touch area further (well past the visible chrome)
// so the user can tap "near" the button and still hit it.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (_isEditing && !_removeButton.hidden) {
        // Inflated touch area: 44pt diameter centred on the
        // minus-button's centre, regardless of the visible 36pt
        // chrome. Same trick Apple uses for small toolbar buttons --
        // tap "near" the button still reaches it.
        CGPoint c = CGPointMake(CGRectGetMidX(_removeButton.frame),
                                CGRectGetMidY(_removeButton.frame));
        CGRect target = CGRectMake(c.x - 22, c.y - 22, 44, 44);
        if (CGRectContainsPoint(target, point)) return _removeButton;
    }
    return [super hitTest:point withEvent:event];
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (_isEditing && !_removeButton.hidden) {
        CGPoint c = CGPointMake(CGRectGetMidX(_removeButton.frame),
                                CGRectGetMidY(_removeButton.frame));
        CGRect target = CGRectMake(c.x - 22, c.y - 22, 44, 44);
        if (CGRectContainsPoint(target, point)) return YES;
    }
    return [super pointInside:point withEvent:event];
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
