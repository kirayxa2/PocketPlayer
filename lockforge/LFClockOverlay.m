#import "LFClockOverlay.h"
#import "LFClockSettings.h"
#import "LFLiquidGlassView.h"
#import "LFGyroscopeManager.h"

// Reference digit size at scale=1.0. Matches the size Apple uses on a
// 6.1" device (iPhone 14 etc.) for the default clock.
static const CGFloat kLFClockReferenceFontSize = 84.0;

// Drag-handle visual constants. iOS 16/26 wraps the resize handle
// AROUND the bottom-right rounded corner of the clock's selection
// rectangle: it's a thick liquid-glass pill that hugs the curve,
// sitting on the 45° tangent of the corner arc and rotated to lie
// along that tangent. Width 32pt / height 10pt is the on-screen
// reference; the visible pill is THICK (10pt) so it reads as a
// substantial drag target -- the previous 6pt version was too
// fine. The 44pt invisible touch zone around it keeps the
// fingertip-friendly hit area.
static const CGFloat kLFHandleVisibleW       = 32.0;
static const CGFloat kLFHandleVisibleH       = 10.0;
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

// Resize handle: visible 40x6pt HORIZONTAL pill that sits ON the
// rounded bottom border of the clock's selection rectangle. The
// actual UIView is 44pt for a generous touch area. Standard iOS
// pattern, used by Apple in the iOS 16/26 lock screen editor.
@property (nonatomic, strong) UIView            *resizeHandle;       // 44x44 invisible touch zone
@property (nonatomic, strong) UIView            *resizeHandleVisible; // 40x6 horizontal pill inside

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

// 44pt invisible touch view containing a centered 32x10 visible
// pill that gets rotated -45° to lie along the bottom-right
// corner-arc tangent. The pill is white-translucent (liquid-
// glass) with a bright rim and a soft drop-shadow so it reads on
// any wallpaper. In recomputeMetrics we move the entire 44pt touch
// view so its CENTER sits exactly on the corner-arc tangent point
// (45° between the bottom and right edges). The pill, anchored at
// its own center, rotates around that same tangent point and so
// appears to "wrap" the rounded corner -- exactly the iOS 16/26
// resize-handle visual.
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
    // Translucent white core: shows through the wallpaper behind it
    // but stays bright enough to read. The thin bright-white rim
    // gives the "glass edge" look, and the soft shadow lifts the
    // pill off the border so it doesn't visually merge with the
    // selection-rect outline.
    _resizeHandleVisible.backgroundColor    = [UIColor colorWithWhite:1.0 alpha:0.55];
    // Full-radius ends turn the rectangle into a thick pill.
    _resizeHandleVisible.layer.cornerRadius = kLFHandleVisibleH / 2.0;
    _resizeHandleVisible.layer.borderWidth  = 0.5;
    _resizeHandleVisible.layer.borderColor  = [[UIColor colorWithWhite:1.0 alpha:0.85] CGColor];
    _resizeHandleVisible.layer.shadowColor  = [[UIColor blackColor] CGColor];
    _resizeHandleVisible.layer.shadowOpacity = 0.22;
    _resizeHandleVisible.layer.shadowRadius  = 3.0;
    _resizeHandleVisible.layer.shadowOffset  = CGSizeMake(0, 1);
    _resizeHandleVisible.userInteractionEnabled = NO;
    // Rotate the visible pill -45° so it lies along the tangent of
    // the bottom-right corner arc. Default anchorPoint (0.5, 0.5)
    // means the rotation pivots around the pill's centre, which
    // sits at the centre of the 44pt touch zone -- and that touch
    // zone is positioned on the arc-tangent point in
    // recomputeMetrics. The rotation is set ONCE at build time;
    // recomputeMetrics only needs to update the touch view's
    // origin.
    _resizeHandleVisible.transform = CGAffineTransformMakeRotation(-M_PI_4);
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

    // iOS 16/26 lock screen clock resize is VERTICAL ONLY: the user
    // drags the resize handle DOWN to grow the digits, and dragging
    // up never compresses below the natural size (i.e. min vStretch
    // is 1.0, NOT 0.6). The horizontal stretch setting still exists
    // in the plist (so old saves don't break) but is forced to 1.0
    // here -- the editor no longer exposes a way to change it, and
    // a stale value from an older build would otherwise make the
    // digits look mis-proportioned.
    //
    // Drag DOWN -> verticalStretch grows 1.0 -> 5.0 (digits get tall
    //              and fill most of the screen on a 6s)
    // Drag UP   -> verticalStretch already at 1.0 stays at 1.0
    //              (the handle simply doesn't react further up)
    CGFloat hStretch = 1.0;
    CGFloat vStretch = MAX(1.0, MIN(5.0, s.verticalStretch));
    CGFloat stretchedTimeHeight = timeSize.height * vStretch;

    // Date pill geometry: text size + symmetric padding, rounded
    // ends. Pill is wider than the date text by 2 * kLFDatePillHPad.
    CGFloat datePillW = ceil(dateSize.width)  + 2 * kLFDatePillHPad;
    CGFloat datePillH = ceil(dateSize.height) + 2 * kLFDatePillVPad;

    // FULL-WIDTH iOS 16/26-style selection rectangle. The clock
    // overlay's WIDTH is the screen width minus a small bezel inset
    // -- NOT the natural width of the time text. Apple lays the
    // clock area out edge-to-edge so the user can left- /
    // center- / right-align the digits inside the same wide
    // selection box. Using natural-text-width (the previous
    // behaviour) made the box look "tiny and centered" on the 6s
    // even when there was plenty of room left and right.
    UIView *parentForWidth = self.superview;
    CGFloat parentW = parentForWidth ? parentForWidth.bounds.size.width : 393.0;
    CGFloat width   = MAX(parentW - kLFFullWidthSideInset * 2.0,
                          datePillW + 24);  // never narrower than the date pill
    CGFloat height  = datePillH + kLFDatePillToTimeGap + stretchedTimeHeight + 12;
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
    // the vertical stretch via a CGAffineTransform, anchored at the
    // TOP edge of the label (anchorPoint Y=0.0). That anchor placement
    // is what makes the iOS 16/26 "grow downward only" behaviour
    // correct: as the user drags the resize handle down,
    // verticalStretch grows and the digits expand toward the bottom
    // of the screen while their top edge stays exactly where it was
    // -- which is what keeps the date pill above the clock visually
    // anchored in place. Anchoring at center-Y (the previous version)
    // caused the digits to grow both upward and downward, which made
    // the date pill appear to shift up when the user resized.
    _timeLabel.transform = CGAffineTransformIdentity;
    CGFloat timeY = datePillH + kLFDatePillToTimeGap;
    _timeLabel.frame = CGRectMake(0, timeY, width, timeSize.height);
    _timeLabel.layer.anchorPoint = CGPointMake(ax, 0.0);
    _timeLabel.layer.position    = CGPointMake(ax * width, timeY);
    if (fabs(hStretch - 1.0) > 0.001 || fabs(vStretch - 1.0) > 0.001) {
        _timeLabel.transform = CGAffineTransformMakeScale(hStretch, vStretch);
    }

    _glassBackground.frame = self.bounds;
    _glassBackground.glassCornerRadius = MIN(28, height / 2.0);
    _glassBackground.intensity = s.liquidGlassIntensity;

    // Resize handle: 44x44 invisible touch view positioned so that
    // its CENTRE sits exactly on the bottom-right corner-arc tangent
    // point of the selection rectangle. The visible 32x10 pill
    // inside is rotated -45° (in buildResizeHandle) so it lies
    // along that tangent, hugging the curve. This is the iOS 16/26
    // resize-handle visual: the pill "wraps" the rounded corner
    // rather than sitting separately above or beside it.
    //
    // Math: for a rounded rectangle with corner radius R, the inset
    // from the bounds-corner (width, height) to the nearest point
    // on the corner-arc (the 45° tangent point, where the arc
    // meets the inscribed circle of the bounds-square) is
    //   R * (1 - cos 45°) = R * (1 - sqrt(2)/2) ≈ R * 0.2929
    CGFloat cornerR    = MIN(28, height / 2.0);
    CGFloat cornerInset = cornerR * (1.0 - 0.70710678);
    CGFloat handleCx   = width  - cornerInset;
    CGFloat handleCy   = height - cornerInset;
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

    // iOS 16/26 lock screen clock resize is VERTICAL ONLY. We map
    // vertical translation to verticalStretch directly:
    //
    //   drag DOWN by N pt   -> vStretch += N / 350 * (5.0 - 1.0)
    //   drag UP   by N pt   -> vStretch -= N / 350 * (5.0 - 1.0)
    //
    // The result is then CLAMPED at 1.0 on the low end and 5.0 on the
    // high end. The clamp at 1.0 is what makes "you can only resize
    // DOWN" correct: dragging up while already at the natural size
    // simply does nothing -- the digits never compress below default.
    //
    // Divisor 350 keeps the same finger-feel as before: ~350pt of
    // vertical drag traverses min<->max, which is the full available
    // swipe height on a 6s.
    CGFloat range       = 5.0 - 1.0;
    CGFloat delta       = t.y / 350.0 * range;
    CGFloat newVStretch = MAX(1.0, MIN(5.0, _resizeStartVStretch + delta));

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
