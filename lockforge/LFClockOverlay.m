#import "LFClockOverlay.h"
#import "LFClockSettings.h"
#import "LFLiquidGlassView.h"
#import "LFGyroscopeManager.h"

// Reference digit size at scale=1.0. Matches the size Apple uses on a
// 6.1" device (iPhone 14 etc.) for the default clock.
static const CGFloat kLFClockReferenceFontSize = 84.0;

// Drag-handle visual constants. iOS 16/26 wraps the resize handle
// AROUND the bottom-right rounded corner of the clock's selection
// rectangle: it's a thick liquid-glass STROKE that traces the curve
// of the corner radius, so the handle doesn't look like a separate
// straight pill sitting near the corner -- it IS a piece of the
// corner outline, drawn fatter than the surrounding selection
// border. We render it as a stroked CAShapeLayer arc whose radius
// matches the bordering rectangle's corner radius.
//
// Stroke width 10pt is the visual thickness ("thicker than the
// border, draws the eye"). Arc sweep 56° is the on-screen length
// of the handle along the curve (~28pt at radius 28pt) -- comfortable
// fingertip target without dominating the corner. Round line caps
// give the stroke softly rounded ends.
static const CGFloat kLFHandleStrokeWidth    = 10.0;
static const CGFloat kLFHandleArcSweepDeg    = 56.0;
static const CGFloat kLFHandleTouchDiameter  = 44.0;

// Side inset for the FULL-WIDTH selection rectangle. iOS 16/26's
// lock-screen clock-area selection box spans almost the entire
// screen (just the safe-area horizontal insets), not the natural
// width of the digit text. We mirror that: the selection
// rectangle has a small breathing room from the screen bezels
// (8pt each side) and the time digits are placed inside it via
// textAlignment + anchor (left/center/right), exactly the way
// Apple's editor lays them out.
static const CGFloat kLFFullWidthSideInset   = 8.0;

// Date pill (iOS 16/26 floats the date in a small rounded rectangle
// with a thin border above the time). Width follows the date text;
// the constants below define padding inside the pill plus its visual
// styling. Pill height is fixed at 22pt -- matches Apple's reference
// frame on iPhone.
static const CGFloat kLFDatePillVPad         = 4.0;
static const CGFloat kLFDatePillHPad         = 14.0;
static const CGFloat kLFDatePillToTimeGap    = 12.0;

@interface LFClockOverlay () <UIGestureRecognizerDelegate> {
    id _gyroSubscriberKey;
    // Cached natural size after the font/stretch resolve. layoutSubviews
    // and refreshFromSettings both need to know the size; computing
    // it twice causes the clock to jitter, so we keep one cached
    // result and have recomputeMetrics own it.
    CGSize  _naturalSize;
    BOOL    _isUserDragging;     // pause auto-positioning while user resizes
    CGFloat _resizeStartVStretch;// captured on resize-pan Began (Y axis)
    // Top edge of the clock's frame in superview coordinates. iOS
    // 16/26 lock screen clocks have a FIXED top: when the user
    // resizes via the handle, the top edge stays put and the clock
    // grows/shrinks ONLY toward the bottom. The date pill above
    // the digits, which sits at frame.origin.y=0 in our local space,
    // therefore never moves on screen as the digits grow.
    // Cached on -centerInParentApplyingSettings so the resize-pan
    // logic doesn't have to sample superview safe-area insets each
    // call.
    CGFloat _fixedTopY;
}
@property (nonatomic, strong) LFLiquidGlassView *glassBackground;
// Date pill: small rounded rect with a thin white border that floats
// just above the time label, exactly like iOS 16/26's editor preview.
// Contains the dateLabel as its single subview.
@property (nonatomic, strong) UIView            *datePillView;
@property (nonatomic, strong) UILabel           *timeLabel;
@property (nonatomic, strong) UILabel           *dateLabel;

// Resize handle: visible curved STROKE that traces the bottom-right
// corner radius of the clock's selection rectangle, drawn into a
// CAShapeLayer that lives directly on `self.layer` (so the path can
// span beyond _resizeHandle's 44pt touch box). The 44pt invisible
// touch view sits on top of the arc to give the fingertip a
// generous drag target.
@property (nonatomic, strong) UIView            *resizeHandle;       // 44x44 invisible touch zone
@property (nonatomic, strong) CAShapeLayer      *resizeHandleArc;     // curved stroke along the corner

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
    _resizeStartVStretch        = 1.0;
    _fixedTopY                  = 0;
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

// 44pt invisible touch view + a CAShapeLayer arc drawn directly on
// self.layer. The arc traces the bottom-right corner radius (same
// radius as the editing-mode border) so the handle reads as a
// "thicker piece" of that border curve -- iOS 16/26's exact resize-
// handle visual. The touch zone sits on top of the arc, centered on
// the arc's midpoint, so a fingertip can grab it without aiming.
- (void)buildResizeHandle {
    _resizeHandle = [[UIView alloc] initWithFrame:CGRectMake(0, 0,
        kLFHandleTouchDiameter, kLFHandleTouchDiameter)];
    _resizeHandle.backgroundColor    = [UIColor clearColor];
    _resizeHandle.userInteractionEnabled = YES;
    _resizeHandle.hidden             = YES;
    [self addSubview:_resizeHandle];

    // Arc layer. Stroke = translucent white liquid-glass core; rim is
    // simulated by a brighter shadow than the selection border has,
    // so the handle stands out against the wallpaper behind it.
    _resizeHandleArc = [CAShapeLayer layer];
    _resizeHandleArc.fillColor    = [[UIColor clearColor] CGColor];
    _resizeHandleArc.strokeColor  = [[UIColor colorWithWhite:1.0 alpha:0.85] CGColor];
    _resizeHandleArc.lineWidth    = kLFHandleStrokeWidth;
    _resizeHandleArc.lineCap      = kCALineCapRound;
    _resizeHandleArc.shadowColor  = [[UIColor blackColor] CGColor];
    _resizeHandleArc.shadowOpacity = 0.25;
    _resizeHandleArc.shadowRadius  = 3.0;
    _resizeHandleArc.shadowOffset  = CGSizeMake(0, 1);
    _resizeHandleArc.hidden       = YES;
    [self.layer addSublayer:_resizeHandleArc];
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

    // (Time font is computed below by auto-fit-to-width, after we know
    // the parent's bounds and the current verticalStretch. We don't
    // assign a placeholder here -- it would just be overwritten.)

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

    CGSize dateSize = [(_dateLabel.text ?: @" ")
        sizeWithAttributes:@{ NSFontAttributeName: _dateLabel.font }];

    // Date pill geometry: text size + symmetric padding, rounded
    // ends. Pill is wider than the date text by 2 * kLFDatePillHPad.
    CGFloat datePillW = ceil(dateSize.width)  + 2 * kLFDatePillHPad;
    CGFloat datePillH = ceil(dateSize.height) + 2 * kLFDatePillVPad;

    // FULL-WIDTH iOS 16/26-style selection rectangle. The clock
    // overlay's WIDTH is the screen width minus a small bezel inset
    // -- NOT the natural width of the time text.
    UIView *parentForWidth = self.superview;
    CGFloat parentW = parentForWidth ? parentForWidth.bounds.size.width : 393.0;
    CGFloat width   = MAX(parentW - kLFFullWidthSideInset * 2.0,
                          datePillW + 24);  // never narrower than the date pill

    // === iOS 26-style non-uniform vertical stretch ===
    //
    // Apple's resize in iOS 26 works like this:
    //   - Digits ALWAYS fill the screen width (minus small padding)
    //   - Drag handle ONLY changes HEIGHT (non-uniform Y scale)
    //   - Width stays constant regardless of vStretch
    //   - At max the clock can take ~half the screen height
    //
    // Implementation: render the font at a FIXED large point size
    // (chosen so "00:00" fills width - 16pt), then apply
    // CGAffineTransformMakeScale(1.0, scaleY) where scaleY maps
    // from vStretch. To avoid pixelation at max stretch, we render
    // at the LARGEST needed size (fontPoints * kLFVStretchMax) and
    // then COMPRESS at smaller stretches. Compression is always
    // crisper than expansion because it discards pixels rather than
    // interpolating new ones.
    //
    // vStretch=1.0 → scaleY = 1.0/kLFVStretchMax (compressed, small)
    // vStretch=kLFVStretchMax → scaleY = 1.0 (identity, crisp max)
    static const CGFloat kLFVStretchMax = 2.5;

    NSString *probeText = (_timeLabel.text.length ? _timeLabel.text : @"00:00");
    UIFont   *refFont   = [s resolvedFontForReferenceSize:kLFClockReferenceFontSize];
    CGFloat   refTextW  = [probeText sizeWithAttributes:@{ NSFontAttributeName: refFont }].width;
    if (refTextW < 1.0) refTextW = 1.0;

    // Font size that makes digits fill (width - 16pt) at scaleY=1.
    CGFloat targetTextW = MAX(80.0, width - 16.0);
    CGFloat fontPoints  = kLFClockReferenceFontSize * (targetTextW / refTextW);
    fontPoints          = MAX(20.0, fontPoints);

    UIFont *timeFont = [s resolvedFontForReferenceSize:fontPoints];
    _timeLabel.font  = timeFont;

    // Measure at the rendered (large) font size.
    CGSize timeSize = [probeText sizeWithAttributes:@{ NSFontAttributeName: timeFont }];

    // scaleY maps vStretch [1.0, kLFVStretchMax] onto visual height.
    // At vStretch=1.0 digits appear at their "natural" height
    // (timeSize.height * 1/kLFVStretchMax ≈ 40% of rendered height).
    // At vStretch=kLFVStretchMax digits appear at full rendered height
    // (scaleY=1.0, identity, pixel-perfect).
    CGFloat vStretch = MAX(1.0, MIN(kLFVStretchMax, s.verticalStretch));
    CGFloat scaleY   = vStretch / kLFVStretchMax;

    // The VISUAL height of the time label after transform:
    CGFloat visualTimeH = timeSize.height * scaleY;

    CGFloat height = datePillH + kLFDatePillToTimeGap + ceil(visualTimeH) + 12;
    _naturalSize   = CGSizeMake(width, height);

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

    // The time label spans the full overlay width. It's rendered at
    // the LARGE font size (fills width) but displayed with scaleY
    // compression so it appears at the correct visual height for the
    // current vStretch. The layer's anchorPoint sits at the TOP edge
    // so the digits grow DOWNWARD only as the user drags.
    _timeLabel.transform = CGAffineTransformIdentity;
    CGFloat timeY = datePillH + kLFDatePillToTimeGap;
    _timeLabel.frame = CGRectMake(0, timeY, width, ceil(timeSize.height));
    _timeLabel.layer.anchorPoint = CGPointMake(ax, 0.0);
    _timeLabel.layer.position    = CGPointMake(ax * width, timeY);
    // Apply non-uniform Y-only scale. scaleX=1.0 keeps width constant.
    _timeLabel.transform = CGAffineTransformMakeScale(1.0, scaleY);

    _glassBackground.frame = self.bounds;
    _glassBackground.glassCornerRadius = MIN(28, height / 2.0);
    _glassBackground.intensity = s.liquidGlassIntensity;

    // Resize handle: a CAShapeLayer arc whose radius matches the
    // editing-mode border's corner radius, so the handle reads as a
    // FATTER PIECE OF THE BORDER itself rather than a separate pill
    // floating near the corner. Plus a 44pt invisible touch view
    // centered on the arc's midpoint for fingertip comfort.
    //
    // Math: the bottom-right corner-radius circle is centered at
    // (width - R, height - R). The arc sweeps from `mid - sweep/2`
    // to `mid + sweep/2` around 45° (i.e. the diagonal toward the
    // corner). All angles in radians; UIBezierPath uses standard
    // math convention (0 = +X axis, 90° = +Y axis in UIKit's
    // y-down coords, so 45° points down-and-right toward the
    // corner).
    CGFloat cornerR     = MIN(28, height / 2.0);
    CGFloat sweep       = kLFHandleArcSweepDeg * M_PI / 180.0;
    CGFloat midAngle    = M_PI_4;                    // 45° = toward bottom-right corner
    CGPoint cornerCircleC = CGPointMake(width - cornerR, height - cornerR);

    UIBezierPath *arcPath =
        [UIBezierPath bezierPathWithArcCenter:cornerCircleC
                                       radius:cornerR
                                   startAngle:midAngle - sweep / 2.0
                                     endAngle:midAngle + sweep / 2.0
                                    clockwise:YES];
    _resizeHandleArc.path   = arcPath.CGPath;
    _resizeHandleArc.frame  = self.bounds;
    _resizeHandleArc.hidden = !_isEditing;

    // Touch zone: 44x44 centered on the midpoint of the arc (the 45°
    // tangent point). Since the arc passes through this point,
    // dragging the touch zone is dragging the visible handle.
    CGFloat midX = cornerCircleC.x + cornerR * cos(midAngle);
    CGFloat midY = cornerCircleC.y + cornerR * sin(midAngle);
    _resizeHandle.frame = CGRectMake(midX - kLFHandleTouchDiameter / 2.0,
                                     midY - kLFHandleTouchDiameter / 2.0,
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

    // Anchor the top edge in superview coordinates so vertical growth
    // never pushes the date pill upward off-screen and never tugs
    // the clock above its iOS 16/26 default position. This is the
    // single owner of self.center.y; every recomputeMetrics call
    // ends here so resize, font swaps, and minute-text-changes all
    // converge to the same fixed top.
    [self centerInParentApplyingSettings];
}

// Apply the clock's DEFAULT iOS 16/26 position. The clock is locked to
// this position -- there is no per-user position offset anymore (the
// resize handle is the only way to customize it, like Apple).
//
// Default vertical placement: just below the safe-area top, with the
// date pill ~24pt down so it doesn't kiss the status bar / dynamic
// island. Centered horizontally.
//
// IMPORTANT: this function is the SINGLE SOURCE OF TRUTH for self's
// position on screen. It's called at the end of every
// -recomputeMetrics, so vertical-stretch resize, font swaps, and
// minute-text-changes all reset to the same fixed top, which is what
// makes "the clock can only resize down" feel correct: as bounds.height
// grows, center.y grows by exactly the same amount -- frame.origin.y
// stays put.
- (void)centerInParentApplyingSettings {
    UIView *parent = self.superview;
    if (!parent) return;

    CGFloat topPadding = parent.safeAreaInsets.top + 24.0;
    _fixedTopY = topPadding;
    CGPoint center = CGPointMake(parent.bounds.size.width / 2.0,
                                 topPadding + self.bounds.size.height / 2.0);
    self.center = center;
}

#pragma mark - Layout

// Slim layoutSubviews -- frames of children are set in recomputeMetrics
// after font/scale changes. We DO call recomputeMetrics here as well
// because layoutSubviews is the canonical signal that the parent's
// bounds changed (rotation, sheet resize, etc.), and the clock's
// own width is now derived from the parent's width. Without this
// re-flow, the selection rectangle would stay at whatever width was
// computed at -initWithFrame: time (using the 393pt fallback) and
// not snap to the real screen width once the cover sheet attaches us.
- (void)layoutSubviews {
    [super layoutSubviews];
    [self recomputeMetrics];
}

- (void)didMoveToSuperview {
    [super didMoveToSuperview];
    if (self.superview) {
        // Re-derive the full-screen width and recentre now that the
        // parent's bounds are known. The init pass used a 393pt
        // fallback because superview was still nil at that point.
        [self recomputeMetrics];
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
        _resizeStartVStretch = [LFClockSettings shared].verticalStretch;
        if (_resizeStartVStretch < 1.0) _resizeStartVStretch = 1.0;
    }

    // Use translation in PARENT coordinate space, not self -- since
    // we resize, our own coordinate space changes mid-gesture and
    // pan translation in `self` returns inconsistent values that
    // make the gesture feel non-responsive.
    UIView *parent = self.superview ?: self;
    CGPoint t = [pan translationInView:parent];

    // iOS 26 lock screen clock resize is VERTICAL ONLY (non-uniform
    // Y scale). Drag DOWN grows digits taller, drag UP shrinks them
    // back toward natural height. Width stays constant.
    //
    //   drag DOWN by N pt -> vStretch += N / 300 * (2.5 - 1.0)
    //   drag UP   by N pt -> vStretch -= same
    //
    // Clamped at [1.0, 2.5]. At 2.5 digits reach ~half the screen
    // height on a 6s. Divisor 300 gives comfortable finger-feel:
    // ~300pt of drag (full swipe on 6s) traverses the whole range.
    CGFloat range       = 2.5 - 1.0;
    CGFloat delta       = t.y / 300.0 * range;
    CGFloat newVStretch = MAX(1.0, MIN(2.5, _resizeStartVStretch + delta));

    BOOL changed = NO;
    if (fabs(newVStretch - [LFClockSettings shared].verticalStretch) > 0.001) {
        [LFClockSettings shared].verticalStretch = newVStretch;
        changed = YES;
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
        [[LFClockSettings shared] save];
    }
}

@end
