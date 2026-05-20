#import "LFClockOverlay.h"
#import "LFClockSettings.h"
#import "LFLiquidGlassView.h"
#import "LFGyroscopeManager.h"

// Reference digit size at scale=1.0. Matches the size Apple uses on a
// 6.1" device (iPhone 14 etc.) for the default clock.
static const CGFloat kLFClockReferenceFontSize = 84.0;

// Drag-handle visual constants. Visible circle is 22pt (matching iOS 26),
// but the touch target is the full 44pt minimum required by UIKit
// guidelines so it doesn't feel "missy" under a fingertip.
static const CGFloat kLFHandleVisibleDiameter = 22.0;
static const CGFloat kLFHandleTouchDiameter   = 44.0;

// Distance the finger has to travel away from the touch-down point
// before we lock to a single axis. 12pt matches the system's
// UIPanGestureRecognizer default pan-detection slop, so the lock
// happens just as the gesture is recognised "for real".
static const CGFloat kLFAxisLockThreshold     = 12.0;

@interface LFClockOverlay () <UIGestureRecognizerDelegate> {
    id _gyroSubscriberKey;
    // Cached natural size after font/scale resolve. The position-pan
    // and refreshFromSettings both need to know the size; computing
    // it inside layoutSubviews and again in refresh causes the clock
    // to jitter mid-drag, so we keep one cached result.
    CGSize  _naturalSize;
    BOOL    _isUserDragging;     // bug-1 fix: pause auto-positioning
    CGFloat _resizeStartScale;   // captured on resize-pan Began
    CGFloat _resizeStartStretch; // captured on resize-pan Began
    // iOS 26-style axis lock. On gesture Began, `Unknown`. As soon as
    // the finger has moved >= kLFAxisLockThreshold pt away from the
    // start point in EITHER direction, we commit to that axis (Y or X)
    // and ignore the other axis for the rest of the gesture. This
    // matches Apple's iOS 26 behaviour: drag the handle straight down
    // to scale the whole clock uniformly (up to ~half-screen), drag
    // straight right to stretch the digits horizontally only.
    NSInteger _resizeAxis;       // 0=unknown, 1=Y(uniform), 2=X(stretch)
}
@property (nonatomic, strong) LFLiquidGlassView *glassBackground;
@property (nonatomic, strong) UILabel           *timeLabel;
@property (nonatomic, strong) UILabel           *dateLabel;

// Resize handle: visible 22pt dot, but the actual UIView is 44pt for a
// generous touch area (and a centered 22pt subview for the visible
// circle). Standard iOS pattern, used by Apple in Photos / Numbers etc.
@property (nonatomic, strong) UIView            *resizeHandle;       // 44x44 invisible
@property (nonatomic, strong) UIView            *resizeHandleVisible; // 22x22 dot inside

@property (nonatomic, strong) NSTimer           *tickTimer;
@property (nonatomic, strong) UIPanGestureRecognizer *positionPan;
@property (nonatomic, strong) UIPanGestureRecognizer *resizePan;
@property (nonatomic, strong, nullable) NSNumber *cachedLuminance;
@end

@implementation LFClockOverlay

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.userInteractionEnabled = YES;
    self.backgroundColor        = [UIColor clearColor];
    _isUserDragging             = NO;
    _resizeStartScale           = 1.0;
    _resizeStartStretch         = 1.0;
    _resizeAxis                 = 0;
    _naturalSize                = CGSizeMake(200, 100); // sane initial

    [self buildSubviews];
    [self installGestures];
    [self recomputeMetrics];
    [self centerInParentApplyingSettings];
    [self startTicker];
    [self subscribeToGyroscope];

    return self;
}

- (void)dealloc {
    [_tickTimer invalidate];
    if (_gyroSubscriberKey) {
        [[LFGyroscopeManager shared] removeSubscriber:_gyroSubscriberKey];
    }
}

- (void)buildSubviews {
    _glassBackground = [[LFLiquidGlassView alloc] initWithFrame:CGRectZero];
    _glassBackground.glassCornerRadius = 28;
    [self addSubview:_glassBackground];

    _dateLabel               = [UILabel new];
    _dateLabel.textAlignment = NSTextAlignmentCenter;
    _dateLabel.userInteractionEnabled = NO;
    [self addSubview:_dateLabel];

    _timeLabel               = [UILabel new];
    _timeLabel.textAlignment = NSTextAlignmentCenter;
    _timeLabel.userInteractionEnabled = NO;
    _timeLabel.numberOfLines = 1;
    _timeLabel.adjustsFontSizeToFitWidth = NO;
    [self addSubview:_timeLabel];

    [self buildResizeHandle];
}

// 44pt invisible touch view containing a centered 22pt visible dot.
// The invisible parent gets the gesture recognizer; the dot is just
// for show.
- (void)buildResizeHandle {
    _resizeHandle = [[UIView alloc] initWithFrame:CGRectMake(0, 0,
        kLFHandleTouchDiameter, kLFHandleTouchDiameter)];
    _resizeHandle.backgroundColor    = [UIColor clearColor];
    _resizeHandle.userInteractionEnabled = YES;
    _resizeHandle.hidden             = YES;
    [self addSubview:_resizeHandle];

    CGFloat off = (kLFHandleTouchDiameter - kLFHandleVisibleDiameter) / 2.0;
    _resizeHandleVisible = [[UIView alloc] initWithFrame:CGRectMake(
        off, off, kLFHandleVisibleDiameter, kLFHandleVisibleDiameter)];
    _resizeHandleVisible.backgroundColor    = [UIColor colorWithWhite:1.0 alpha:0.92];
    _resizeHandleVisible.layer.cornerRadius = kLFHandleVisibleDiameter / 2.0;
    _resizeHandleVisible.layer.borderWidth  = 1.0;
    _resizeHandleVisible.layer.borderColor  = [[UIColor colorWithWhite:0.0 alpha:0.18] CGColor];
    _resizeHandleVisible.layer.shadowColor  = [[UIColor blackColor] CGColor];
    _resizeHandleVisible.layer.shadowOpacity = 0.20;
    _resizeHandleVisible.layer.shadowRadius  = 3;
    _resizeHandleVisible.layer.shadowOffset  = CGSizeMake(0, 1);
    _resizeHandleVisible.userInteractionEnabled = NO;
    [_resizeHandle addSubview:_resizeHandleVisible];
}

- (void)installGestures {
    _positionPan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(handlePositionPan:)];
    _positionPan.delegate = self;          // bug-2 fix: simultaneous gestures
    _positionPan.maximumNumberOfTouches = 1;
    [self addGestureRecognizer:_positionPan];

    _resizePan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(handleResizePan:)];
    _resizePan.delegate = self;
    _resizePan.maximumNumberOfTouches = 1;
    [_resizeHandle addGestureRecognizer:_resizePan];

    // Position pan should defer to resize pan on the handle.
    [_positionPan requireGestureRecognizerToFail:_resizePan];
}

- (void)startTicker {
    __weak __typeof(self) weakSelf = self;
    _tickTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                 repeats:YES
                                                   block:^(NSTimer *_) {
        [weakSelf updateTimeText];
    }];
    [self updateTimeText];
}

- (void)subscribeToGyroscope {
    _gyroSubscriberKey = [NSObject new];
    __weak __typeof(self) weakSelf = self;
    [[LFGyroscopeManager shared] addSubscriber:_gyroSubscriberKey
                                         block:^(CGPoint tilt) {
        [weakSelf.glassBackground setShimmerOffset:tilt];
    }];
}

#pragma mark - Metrics

// Computes the natural size based on current font + scale + text and
// applies it to bounds / sub-frames. Does NOT touch self.center -- that
// is owned by centerInParentApplyingSettings or the position pan.
//
// Why split this out: layoutSubviews fires constantly (any time the
// parent re-layouts), and if we re-derived the position from settings
// every time, the user's mid-drag movements would get reverted under
// them on the very next layout pass. Now layoutSubviews is a no-op
// for position; only this function (called when settings change)
// touches it.
- (void)recomputeMetrics {
    LFClockSettings *s = [LFClockSettings shared];

    UIFont *timeFont = [s resolvedFontForReferenceSize:kLFClockReferenceFontSize];
    _timeLabel.font  = timeFont;

    UIFont *dateFont = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    if (@available(iOS 13.0, *)) {
        UIFontDescriptor *d = [dateFont.fontDescriptor
            fontDescriptorWithDesign:UIFontDescriptorSystemDesignRounded];
        if (d) dateFont = [UIFont fontWithDescriptor:d size:14];
    }
    _dateLabel.font  = dateFont;

    UIColor *color = [s resolvedColorForBackgroundLuminance:_cachedLuminance];
    _timeLabel.textColor = color;
    _dateLabel.textColor = [color colorWithAlphaComponent:0.8];

    CGSize timeSize = [(_timeLabel.text ?: @"00:00")
        sizeWithAttributes:@{ NSFontAttributeName: _timeLabel.font }];
    CGSize dateSize = [(_dateLabel.text ?: @" ")
        sizeWithAttributes:@{ NSFontAttributeName: _dateLabel.font }];

    // iOS 26 horizontal stretch -- only the time digits stretch
    // along X, the date stays at its natural width. Clamped to the
    // settings range here at use site (settings are stored as the
    // raw value).
    CGFloat stretch = MAX(0.6, MIN(1.6, s.horizontalStretch));
    CGFloat stretchedTimeWidth = timeSize.width * stretch;

    CGFloat width  = MAX(stretchedTimeWidth, dateSize.width) + 24;
    CGFloat height = timeSize.height + dateSize.height + 12;
    _naturalSize = CGSizeMake(width, height);

    self.bounds = CGRectMake(0, 0, width, height);
    _dateLabel.frame = CGRectMake(0, 0, width, dateSize.height);
    // The time label keeps its natural (unstretched) frame and we
    // apply the X scale via a CGAffineTransform. This lets UIKit
    // size the glyphs at their true point size and just stretch
    // the rasterised bitmap horizontally, which is exactly how
    // Apple does it on iOS 26 (cheap and looks correct).
    _timeLabel.transform = CGAffineTransformIdentity;
    _timeLabel.frame = CGRectMake((width - timeSize.width) / 2.0,
                                  dateSize.height + 4,
                                  timeSize.width,
                                  timeSize.height);
    if (fabs(stretch - 1.0) > 0.001) {
        _timeLabel.transform = CGAffineTransformMakeScale(stretch, 1.0);
        // Re-center after transform: setting a transform doesn't
        // move the layer's position, but our frame above assumed
        // identity. Restore the centered X.
        _timeLabel.center = CGPointMake(width / 2.0,
                                        dateSize.height + 4 + timeSize.height / 2.0);
    }

    _glassBackground.frame = self.bounds;
    _glassBackground.glassCornerRadius = MIN(28, height / 2.0);
    _glassBackground.intensity = s.liquidGlassIntensity;

    // Handle is 44x44 invisible, positioned bottom-right with its
    // CENTER at the bottom-right corner of the clock frame. Visible
    // dot inside is centered, so it appears half-outside the clock,
    // matching iOS 26 visually.
    _resizeHandle.frame = CGRectMake(width  - kLFHandleTouchDiameter / 2.0,
                                     height - kLFHandleTouchDiameter / 2.0,
                                     kLFHandleTouchDiameter,
                                     kLFHandleTouchDiameter);
    _resizeHandle.hidden = !_isEditing;

    if (_isEditing) {
        self.layer.borderColor   = [[UIColor colorWithWhite:1.0 alpha:0.35] CGColor];
        self.layer.borderWidth   = 1.0;
        self.layer.cornerRadius  = _glassBackground.glassCornerRadius;
    } else {
        self.layer.borderColor = nil;
        self.layer.borderWidth = 0.0;
    }
}

// Apply the saved position offset to self.center. Called only when
// (a) the overlay gets attached to a parent, (b) settings change
// non-positionally, (c) editor opens/closes. Never during a drag.
- (void)centerInParentApplyingSettings {
    if (_isUserDragging) return;        // bug-1 fix
    UIView *parent = self.superview;
    if (!parent) return;

    LFClockSettings *s = [LFClockSettings shared];
    CGPoint base = CGPointMake(parent.bounds.size.width / 2.0,
                               parent.safeAreaInsets.top + _naturalSize.height / 2.0 + 60);
    self.center = CGPointMake(base.x + s.positionOffset.x,
                              base.y + s.positionOffset.y);
}

#pragma mark - Layout

// Slim layoutSubviews -- frames of children are set in recomputeMetrics
// after font/scale changes. We only get called here on rotation /
// when bounds change for unrelated reasons. No more constant fight
// with the user's drag.
- (void)layoutSubviews {
    [super layoutSubviews];
    // intentionally empty -- recomputeMetrics handles our internal frames
}

- (void)didMoveToSuperview {
    [super didMoveToSuperview];
    if (self.superview) {
        [self centerInParentApplyingSettings];
    }
}

#pragma mark - Editing toggle

- (void)setIsEditing:(BOOL)e {
    if (_isEditing == e) return;
    _isEditing = e;
    [self recomputeMetrics];
}

#pragma mark - Refresh from settings

- (void)refreshFromSettings {
    [self updateTimeText];
    [self recomputeMetrics];
    [self centerInParentApplyingSettings];
}

- (void)updateTimeText {
    static NSDateFormatter *timeF;
    static NSDateFormatter *dateF;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        timeF = [NSDateFormatter new];
        timeF.dateFormat = @"H:mm";
        dateF = [NSDateFormatter new];
        dateF.dateFormat = @"EEEE, d MMMM";
    });
    NSDate *now = [NSDate date];
    NSString *t = [timeF stringFromDate:now];
    NSString *d = [[dateF stringFromDate:now] localizedUppercaseString];
    BOOL textChanged = (![t isEqualToString:_timeLabel.text] ||
                        ![d isEqualToString:_dateLabel.text]);
    _timeLabel.text = t;
    _dateLabel.text = d;
    // Only redo metrics if text actually changed shape (e.g. minute
    // rolled, or HH digit width changed). Otherwise we waste cycles.
    if (textChanged) [self recomputeMetrics];
}

- (void)applyAdaptiveColorWithBackgroundImage:(UIImage *)bgImage {
    if (!bgImage) {
        _cachedLuminance = nil;
        [self recomputeMetrics];
        return;
    }
    UIWindow *win = self.window;
    if (!win) return;
    CGRect frameInWin = [self convertRect:self.bounds toView:win];
    CGSize imgPt = bgImage.size;
    CGFloat sx = imgPt.width  / win.bounds.size.width;
    CGFloat sy = imgPt.height / win.bounds.size.height;
    CGRect sample = CGRectMake(CGRectGetMidX(frameInWin) * sx - 10,
                               CGRectGetMidY(frameInWin) * sy - 10,
                               20, 20);
    CGImageRef cg = bgImage.CGImage;
    if (!cg) return;
    CGImageRef cropped = CGImageCreateWithImageInRect(cg, sample);
    if (!cropped) return;

    UIGraphicsBeginImageContextWithOptions(CGSizeMake(1, 1), YES, 1);
    [[[UIImage alloc] initWithCGImage:cropped] drawInRect:CGRectMake(0,0,1,1)];
    UIImage *avg = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    CGImageRelease(cropped);

    unsigned char px[4] = {0};
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, 1, 1, 8, 4, cs,
        kCGImageAlphaPremultipliedLast);
    CGContextDrawImage(ctx, CGRectMake(0,0,1,1), avg.CGImage);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);

    CGFloat lum = (0.2126 * px[0] + 0.7152 * px[1] + 0.0722 * px[2]) / 255.0;
    _cachedLuminance = @(lum);
    [self recomputeMetrics];
}

#pragma mark - UIGestureRecognizerDelegate (bug-2 fix)

// Tell the system that our pans CAN run alongside other recognizers.
// Without this, the cover-sheet's swipe-to-unlock recognizer would
// claim the gesture before ours can get the first translation update.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}

// Begin our pans only when:
// - we are in editing mode (otherwise ignore -- swipe-to-unlock wins)
// - for resize, the touch must actually be on the handle's frame
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if (!_isEditing) return NO;
    return YES;
}

#pragma mark - Hit testing (bug-3 fix: handle is half-outside bounds)

// The resize handle is positioned with its center at the bottom-right
// CORNER of our bounds, which means half of its 44x44 touch area sits
// OUTSIDE our bounds. By default UIKit's -hitTest:withEvent: clips at
// self.bounds and returns nil for any point outside, so touches on the
// outer half of the handle were silently dropped -- which is exactly
// what "as if the trigger isn't being read" looks like from the user
// side.
//
// Override hit-testing so we ALSO check the handle's frame directly
// (in our own coordinate space) before falling back to the default
// behaviour.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (_isEditing && !_resizeHandle.hidden) {
        // Handle frame is in our coordinate space already.
        if (CGRectContainsPoint(_resizeHandle.frame, point)) {
            return _resizeHandle;
        }
    }
    return [super hitTest:point withEvent:event];
}

// Mirror so events delivered to the parent's hit-test can route here
// even when our parent thinks the touch is just outside its child
// list.
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (_isEditing && !_resizeHandle.hidden) {
        if (CGRectContainsPoint(_resizeHandle.frame, point)) return YES;
    }
    return [super pointInside:point withEvent:event];
}

#pragma mark - Position pan

- (void)handlePositionPan:(UIPanGestureRecognizer *)pan {
    if (!_isEditing) return;
    UIView *parent = self.superview;
    if (!parent) return;

    if (pan.state == UIGestureRecognizerStateBegan) {
        _isUserDragging = YES;
    }

    CGPoint t = [pan translationInView:parent];
    [pan setTranslation:CGPointZero inView:parent];
    self.center = CGPointMake(self.center.x + t.x, self.center.y + t.y);

    if (pan.state == UIGestureRecognizerStateEnded ||
        pan.state == UIGestureRecognizerStateCancelled ||
        pan.state == UIGestureRecognizerStateFailed) {
        _isUserDragging = NO;
        CGPoint base = CGPointMake(parent.bounds.size.width / 2.0,
                                   parent.safeAreaInsets.top +
                                   _naturalSize.height / 2.0 + 60);
        CGPoint offset = CGPointMake(self.center.x - base.x,
                                     self.center.y - base.y);
        [LFClockSettings shared].positionOffset = offset;
        [[LFClockSettings shared] save];
    }
}

#pragma mark - Resize pan

- (void)handleResizePan:(UIPanGestureRecognizer *)pan {
    if (!_isEditing) return;

    if (pan.state == UIGestureRecognizerStateBegan) {
        _isUserDragging     = YES;
        _resizeStartScale   = [LFClockSettings shared].scale;
        _resizeStartStretch = [LFClockSettings shared].horizontalStretch;
        _resizeAxis         = 0;  // unknown; decided as soon as finger moves
    }

    // Use translation in PARENT coordinate space, not self -- since
    // we resize, our own coordinate space changes mid-gesture and
    // pan translation in `self` returns inconsistent values that
    // make the gesture feel non-responsive.
    UIView *parent = self.superview ?: self;
    CGPoint t = [pan translationInView:parent];

    // iOS 26 axis-lock decision. We commit to one axis as soon as
    // the user has moved past the slop threshold in either
    // direction. After that, the OTHER axis is ignored for the
    // remainder of this gesture.
    if (_resizeAxis == 0) {
        CGFloat ax = fabs(t.x);
        CGFloat ay = fabs(t.y);
        if (ax >= kLFAxisLockThreshold || ay >= kLFAxisLockThreshold) {
            _resizeAxis = (ay >= ax) ? 1 : 2;
        }
        // Until the threshold is crossed, don't move the clock --
        // matches Apple's behaviour where a tiny finger jiggle
        // doesn't immediately resize anything.
    }

    BOOL changed = NO;

    if (_resizeAxis == 1) {
        // Y dominant -> uniform scale. Down = bigger (up to ~half
        // screen at scale 2.8), up = smaller (down to 0.6).
        CGFloat range    = 2.8 - 0.6;
        CGFloat delta    = t.y / 150.0 * range;
        CGFloat newScale = MAX(0.6, MIN(2.8, _resizeStartScale + delta));
        if (fabs(newScale - [LFClockSettings shared].scale) > 0.001) {
            [LFClockSettings shared].scale = newScale;
            changed = YES;
        }
    } else if (_resizeAxis == 2) {
        // X dominant -> horizontal stretch only. Right = wider
        // (up to 1.6x), left = narrower (down to 0.6x). Vertical
        // size of the digits is unchanged.
        CGFloat range      = 1.6 - 0.6;
        CGFloat delta      = t.x / 200.0 * range;
        CGFloat newStretch = MAX(0.6, MIN(1.6, _resizeStartStretch + delta));
        if (fabs(newStretch - [LFClockSettings shared].horizontalStretch) > 0.001) {
            [LFClockSettings shared].horizontalStretch = newStretch;
            changed = YES;
        }
    }

    if (changed) {
        // Disable implicit Core Animation so the resize is
        // instantaneous and tracks the finger 1:1. Without this,
        // every bounds change animates over 0.25s, which makes the
        // gesture feel laggy and detached from the touch.
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [self recomputeMetrics];
        [CATransaction commit];
    }

    if (pan.state == UIGestureRecognizerStateEnded ||
        pan.state == UIGestureRecognizerStateCancelled ||
        pan.state == UIGestureRecognizerStateFailed) {
        _isUserDragging = NO;
        _resizeAxis     = 0;
        [[LFClockSettings shared] save];
    }
}

@end
