#import "LFClockOverlay.h"
#import "LFClockSettings.h"
#import "LFLiquidGlassView.h"
#import "LFGyroscopeManager.h"

// Reference digit size at scale=1.0. Matches the size Apple uses on a
// 6.1" device (iPhone 14 etc.) for the default clock.
static const CGFloat kLFClockReferenceFontSize = 84.0;

// Drag-handle visual constants. iOS 16/26 uses a small VERTICAL PILL
// (rounded with full-radius ends), not a circle, sitting on the
// right edge of the clock. The visible pill is 8pt wide x 14pt tall;
// the touch target around it is the full 44pt minimum required by
// UIKit guidelines so it doesn't feel "missy" under a fingertip.
static const CGFloat kLFHandleVisibleW       = 8.0;
static const CGFloat kLFHandleVisibleH       = 14.0;
static const CGFloat kLFHandleTouchDiameter  = 44.0;

// Date pill (iOS 16/26 floats the date in a small rounded rectangle
// with a thin border above the time). Width follows the date text;
// the constants below define padding inside the pill plus its visual
// styling. Pill height is fixed at 22pt -- matches Apple's reference
// frame on iPhone.
static const CGFloat kLFDatePillVPad         = 4.0;
static const CGFloat kLFDatePillHPad         = 14.0;
static const CGFloat kLFDatePillToTimeGap    = 12.0;

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
    CGFloat _resizeStartVStretch;// captured on resize-pan Began (Y axis)
    // iOS 26-style axis lock. On gesture Began, `Unknown`. As soon as
    // the finger has moved >= kLFAxisLockThreshold pt away from the
    // start point in EITHER direction, we commit to that axis (Y or X)
    // and ignore the other axis for the rest of the gesture. Each axis
    // controls its OWN independent stretch, so the user can build a
    // tall thin clock, a short wide clock, or any combo. Y dragging
    // never changes width; X dragging never changes height.
    NSInteger _resizeAxis;       // 0=unknown, 1=Y(verticalStretch), 2=X(horizontalStretch)
}
@property (nonatomic, strong) LFLiquidGlassView *glassBackground;
// Date pill: small rounded rect with a thin white border that floats
// just above the time label, exactly like iOS 16/26's editor preview.
// Contains the dateLabel as its single subview.
@property (nonatomic, strong) UIView            *datePillView;
@property (nonatomic, strong) UILabel           *timeLabel;
@property (nonatomic, strong) UILabel           *dateLabel;

// Resize handle: visible 8x14pt VERTICAL PILL on the right edge of
// the clock, but the actual UIView is 44pt for a generous touch
// area. Standard iOS pattern, used by Apple in the iOS 16/26 lock
// screen editor.
@property (nonatomic, strong) UIView            *resizeHandle;       // 44x44 invisible
@property (nonatomic, strong) UIView            *resizeHandleVisible; // 8x14 vertical pill inside

@property (nonatomic, strong) NSTimer           *tickTimer;
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
    _resizeStartVStretch        = 1.0;
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

    // Date pill: floats above the time. iOS 16/26 styling -- thin
    // semi-transparent border around date text. Translucent fill is
    // very subtle so it reads as a delineated container without
    // dominating the wallpaper. Border thickness 1pt; corner radius
    // is half the pill's height so the ends are perfectly round.
    _datePillView                       = [UIView new];
    _datePillView.userInteractionEnabled = NO;
    _datePillView.layer.borderWidth     = 1.0;
    _datePillView.layer.borderColor     =
        [[UIColor colorWithWhite:1.0 alpha:0.25] CGColor];
    _datePillView.layer.masksToBounds   = YES;
    [self addSubview:_datePillView];

    _dateLabel               = [UILabel new];
    _dateLabel.textAlignment = NSTextAlignmentCenter;
    _dateLabel.userInteractionEnabled = NO;
    [_datePillView addSubview:_dateLabel];

    _timeLabel               = [UILabel new];
    _timeLabel.textAlignment = NSTextAlignmentCenter;
    _timeLabel.userInteractionEnabled = NO;
    _timeLabel.numberOfLines = 1;
    _timeLabel.adjustsFontSizeToFitWidth = NO;
    [self addSubview:_timeLabel];

    [self buildResizeHandle];
}

// 44pt invisible touch view containing a centered 8x14 visible
// vertical PILL. Pill is white-translucent with a thin dark border
// and a tiny shadow, exactly the style Apple uses on iOS 16/26's
// drag-resize handle.
- (void)buildResizeHandle {
    _resizeHandle = [[UIView alloc] initWithFrame:CGRectMake(0, 0,
        kLFHandleTouchDiameter, kLFHandleTouchDiameter)];
    _resizeHandle.backgroundColor    = [UIColor clearColor];
    _resizeHandle.userInteractionEnabled = YES;
    _resizeHandle.hidden             = YES;
    [self addSubview:_resizeHandle];

    CGFloat offX = (kLFHandleTouchDiameter - kLFHandleVisibleW) / 2.0;
    CGFloat offY = (kLFHandleTouchDiameter - kLFHandleVisibleH) / 2.0;
    _resizeHandleVisible = [[UIView alloc] initWithFrame:CGRectMake(
        offX, offY, kLFHandleVisibleW, kLFHandleVisibleH)];
    _resizeHandleVisible.backgroundColor    = [UIColor colorWithWhite:1.0 alpha:0.85];
    // Full-radius ends so the rectangle becomes a vertical pill.
    _resizeHandleVisible.layer.cornerRadius = kLFHandleVisibleW / 2.0;
    _resizeHandleVisible.layer.borderWidth  = 0.5;
    _resizeHandleVisible.layer.borderColor  = [[UIColor colorWithWhite:0.0 alpha:0.20] CGColor];
    _resizeHandleVisible.layer.shadowColor  = [[UIColor blackColor] CGColor];
    _resizeHandleVisible.layer.shadowOpacity = 0.18;
    _resizeHandleVisible.layer.shadowRadius  = 2.5;
    _resizeHandleVisible.layer.shadowOffset  = CGSizeMake(0, 1);
    _resizeHandleVisible.userInteractionEnabled = NO;
    [_resizeHandle addSubview:_resizeHandleVisible];
}

- (void)installGestures {
    // iOS 16/26 lock screen clocks CANNOT be moved -- they're glued
    // to a fixed default position. The user can only resize them
    // via the handle. So we install ONLY the resize-pan recognizer
    // here; the position-drag gesture from earlier builds is gone.
    _resizePan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(handleResizePan:)];
    _resizePan.delegate = self;
    _resizePan.maximumNumberOfTouches = 1;
    [_resizeHandle addGestureRecognizer:_resizePan];
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
    _dateLabel.textColor = [color colorWithAlphaComponent:0.85];

    CGSize timeSize = [(_timeLabel.text ?: @"00:00")
        sizeWithAttributes:@{ NSFontAttributeName: _timeLabel.font }];
    CGSize dateSize = [(_dateLabel.text ?: @" ")
        sizeWithAttributes:@{ NSFontAttributeName: _dateLabel.font }];

    // iOS 26-style independent axis stretches. Each axis is owned by
    // its own setting and is changed independently by the resize
    // handle's drag direction. The font's intrinsic point size is
    // unchanged -- we render at natural size and then apply a
    // CGAffineTransform with both axes' stretch factors. This is
    // exactly how Apple does it: rasterise at native size, then
    // bitmap-stretch in either direction.
    //
    // Drag DOWN  -> verticalStretch goes 1.0 -> 5.0  (digits get tall, lots of room)
    // Drag UP    -> verticalStretch goes 1.0 -> 0.6  (digits get short)
    // Drag RIGHT -> horizontalStretch        1.0 -> 2.5  (digits get really wide)
    // Drag LEFT  -> horizontalStretch        1.0 -> 0.6  (digits get narrow)
    CGFloat hStretch = MAX(0.6, MIN(2.5, s.horizontalStretch));
    CGFloat vStretch = MAX(0.6, MIN(5.0, s.verticalStretch));
    CGFloat stretchedTimeWidth  = timeSize.width  * hStretch;
    CGFloat stretchedTimeHeight = timeSize.height * vStretch;

    // Date pill geometry: text size + symmetric padding, rounded
    // ends. Pill is wider than the date text by 2 * kLFDatePillHPad.
    CGFloat datePillW = ceil(dateSize.width)  + 2 * kLFDatePillHPad;
    CGFloat datePillH = ceil(dateSize.height) + 2 * kLFDatePillVPad;

    // Overall overlay bounds = max(pill, time) wide, pill + gap +
    // time tall. We leave a couple of pt of padding on each side so
    // the editing-mode border doesn't clip the time label edges.
    CGFloat width  = MAX(stretchedTimeWidth, datePillW) + 24;
    CGFloat height = datePillH + kLFDatePillToTimeGap + stretchedTimeHeight + 12;
    _naturalSize = CGSizeMake(width, height);

    // Apply alignment to the labels' textAlignment so date and time
    // glue to the same edge. Then anchor the time label's layer at
    // that edge so the CGAffineTransform stretch grows OUT of the
    // anchored side instead of from the centre. This is exactly
    // what iOS 26 does -- the digit cluster's edge stays put while
    // the rest of the digits expand outward.
    NSTextAlignment ta = NSTextAlignmentCenter;
    CGFloat        ax = 0.5;
    if (s.alignment == LFClockAlignmentLeft)  { ta = NSTextAlignmentLeft;  ax = 0.0; }
    if (s.alignment == LFClockAlignmentRight) { ta = NSTextAlignmentRight; ax = 1.0; }
    _timeLabel.textAlignment = ta;
    _dateLabel.textAlignment = NSTextAlignmentCenter;   // date pill always centered

    self.bounds = CGRectMake(0, 0, width, height);

    // Date pill -- rounded rectangle with thin border, centered
    // horizontally, sitting at the top of our overlay.
    _datePillView.frame = CGRectMake((width - datePillW) / 2.0, 0,
                                     datePillW, datePillH);
    _datePillView.layer.cornerRadius = datePillH / 2.0;
    _dateLabel.frame = CGRectMake(0, 0, datePillW, datePillH);

    // The time label spans the full overlay width and uses
    // textAlignment to glue glyphs to the chosen edge. We then apply
    // both axes' stretch via a single CGAffineTransform, around the
    // matching anchor point so the stretch pivots on that edge.
    _timeLabel.transform = CGAffineTransformIdentity;
    _timeLabel.layer.anchorPoint = CGPointMake(ax, 0.5);
    CGFloat timeY = datePillH + kLFDatePillToTimeGap;
    _timeLabel.frame = CGRectMake(0, timeY, width, timeSize.height);
    // Reposition layer so anchor sits at the matching X edge of the
    // label's frame -- (0, mid), (width/2, mid) or (width, mid).
    CGFloat px = ax * width;
    _timeLabel.layer.position = CGPointMake(px, timeY + timeSize.height / 2.0);
    if (fabs(hStretch - 1.0) > 0.001 || fabs(vStretch - 1.0) > 0.001) {
        _timeLabel.transform = CGAffineTransformMakeScale(hStretch, vStretch);
    }

    _glassBackground.frame = self.bounds;
    _glassBackground.glassCornerRadius = MIN(28, height / 2.0);
    _glassBackground.intensity = s.liquidGlassIntensity;

    // Resize handle: 44x44 invisible touch view positioned so that
    // its center sits on the right edge of the time label, vertically
    // aligned with the time's vertical center. The visible 8x14 pill
    // sits inside the touch zone, so it appears half-outside the
    // clock content -- exactly the iOS 16/26 visual.
    CGFloat handleCx = width;
    CGFloat handleCy = timeY + (stretchedTimeHeight / 2.0);
    _resizeHandle.frame = CGRectMake(handleCx - kLFHandleTouchDiameter / 2.0,
                                     handleCy - kLFHandleTouchDiameter / 2.0,
                                     kLFHandleTouchDiameter,
                                     kLFHandleTouchDiameter);
    _resizeHandle.hidden = !_isEditing;

    // Editing-mode chrome: thin border around the entire clock area
    // (matches Apple's "selected" indicator) plus the date pill keeps
    // its border whether or not editing is active.
    if (_isEditing) {
        self.layer.borderColor   = [[UIColor colorWithWhite:1.0 alpha:0.30] CGColor];
        self.layer.borderWidth   = 1.0;
        self.layer.cornerRadius  = _glassBackground.glassCornerRadius;
    } else {
        self.layer.borderColor = nil;
        self.layer.borderWidth = 0.0;
    }
}

// Apply the clock's DEFAULT iOS 16/26 position. The clock is locked to
// this position -- there is no per-user position offset anymore (the
// resize handle is the only way to customize it, like Apple).
//
// Default vertical placement: just below the safe-area top, with the
// date pill ~24pt down so it doesn't kiss the status bar / dynamic
// island. Centered horizontally.
- (void)centerInParentApplyingSettings {
    if (_isUserDragging) return;        // resize-pan drag in progress
    UIView *parent = self.superview;
    if (!parent) return;

    CGFloat topPadding = parent.safeAreaInsets.top + 24.0;
    CGPoint center = CGPointMake(parent.bounds.size.width / 2.0,
                                 topPadding + _naturalSize.height / 2.0);
    self.center = center;
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

#pragma mark - Resize pan

- (void)handleResizePan:(UIPanGestureRecognizer *)pan {
    if (!_isEditing) return;

    if (pan.state == UIGestureRecognizerStateBegan) {
        _isUserDragging      = YES;
        _resizeStartScale    = [LFClockSettings shared].scale;
        _resizeStartStretch  = [LFClockSettings shared].horizontalStretch;
        _resizeStartVStretch = [LFClockSettings shared].verticalStretch;
        _resizeAxis          = 0;  // unknown; decided as soon as finger moves
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
        // Y dominant -> verticalStretch ONLY. Down = taller (up to
        // 5.0x at the bottom of the range, which is huge -- on iPhone
        // 6s the natural digit height is ~84pt, so 5x lands at ~420pt
        // and fills most of the screen). Up = shorter (down to 0.6x).
        // Width is untouched -- the user explicitly asked for Y to
        // not bleed into width on iOS 26 axis lock.
        //
        // Divisor 350 keeps finger feel similar to before with the
        // smaller range: roughly 1pt of finger movement = 1.25% of
        // range, so 350pt of vertical drag traverses min<->max,
        // which is the full available swipe height on a 6s.
        CGFloat range       = 5.0 - 0.6;
        CGFloat delta       = t.y / 350.0 * range;
        CGFloat newVStretch = MAX(0.6, MIN(5.0, _resizeStartVStretch + delta));
        if (fabs(newVStretch - [LFClockSettings shared].verticalStretch) > 0.001) {
            [LFClockSettings shared].verticalStretch = newVStretch;
            changed = YES;
        }
    } else if (_resizeAxis == 2) {
        // X dominant -> horizontalStretch ONLY. Right = wider
        // (up to 2.5x), left = narrower (down to 0.6x). Vertical
        // size of the digits is unchanged. Divisor 250 matches the
        // sensitivity feel of the Y axis.
        CGFloat range      = 2.5 - 0.6;
        CGFloat delta      = t.x / 250.0 * range;
        CGFloat newStretch = MAX(0.6, MIN(2.5, _resizeStartStretch + delta));
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
