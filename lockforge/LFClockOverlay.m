#import "LFClockOverlay.h"
#import "LFClockSettings.h"
#import "LFLiquidGlassView.h"
#import "LFGyroscopeManager.h"

// Reference digit size at scale=1.0. Matches the size Apple uses on a
// 6.1" device (iPhone 14 etc.) for the default clock; we'll scale it
// down naturally to whatever screen we're on via Auto-Layout / size
// fitting, but the reference stays here so settings.scale == 1.0
// always means "Apple default".
static const CGFloat kLFClockReferenceFontSize = 84.0;

// Drag-handle visual constants. Matches the iOS 26 pulltab look:
// 22pt circle, white fill 90%, 1pt grey border, drop shadow.
static const CGFloat kLFHandleDiameter = 22.0;

@interface LFClockOverlay () {
    // Keyed weakly into the gyroscope subscriber map so we auto-leave
    // when this view is dealloc'd.
    id _gyroSubscriberKey;
}
@property (nonatomic, strong) LFLiquidGlassView *glassBackground;
@property (nonatomic, strong) UILabel           *timeLabel;
@property (nonatomic, strong) UILabel           *dateLabel;

// Resize handle (iOS 26). Hidden in normal mode. The user drags this
// down/right to enlarge the clock; release to keep the size.
@property (nonatomic, strong) UIView            *resizeHandle;

// Updates the clock once a second. NSTimer is fine here; we don't
// need sub-second precision for showing HH:MM, and CADisplayLink
// would just waste cycles.
@property (nonatomic, strong) NSTimer           *tickTimer;

// Position drag, separate from resize drag.
@property (nonatomic, strong) UIPanGestureRecognizer *positionPan;
@property (nonatomic, strong) UIPanGestureRecognizer *resizePan;

// Live edit-time scale buffer. While the user is dragging the resize
// handle we mutate this; on release we commit it back to settings.
// Lets the user see live feedback without saving partial values.
@property (nonatomic, assign) CGFloat            liveScale;

// Last sampled wallpaper luminance for adaptive color. Cached so
// quick redraws (font change etc.) don't need a fresh sample.
@property (nonatomic, strong, nullable) NSNumber *cachedLuminance;
@end

@implementation LFClockOverlay

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.userInteractionEnabled = YES;
    self.backgroundColor        = [UIColor clearColor];
    _liveScale                  = [LFClockSettings shared].scale;

    [self buildSubviews];
    [self installGestures];
    [self refreshFromSettings];
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

- (void)buildResizeHandle {
    _resizeHandle              = [UIView new];
    _resizeHandle.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.92];
    _resizeHandle.layer.cornerRadius = kLFHandleDiameter / 2.0;
    _resizeHandle.layer.borderWidth  = 1.0;
    _resizeHandle.layer.borderColor  = [[UIColor colorWithWhite:0.0 alpha:0.18] CGColor];
    _resizeHandle.layer.shadowColor  = [[UIColor blackColor] CGColor];
    _resizeHandle.layer.shadowOpacity = 0.18;
    _resizeHandle.layer.shadowRadius  = 3;
    _resizeHandle.layer.shadowOffset  = CGSizeMake(0, 1);
    _resizeHandle.hidden = YES;
    [self addSubview:_resizeHandle];
}

- (void)installGestures {
    _positionPan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(handlePositionPan:)];
    [self addGestureRecognizer:_positionPan];

    _resizePan   = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(handleResizePan:)];
    [_resizeHandle addGestureRecognizer:_resizePan];
    _resizeHandle.userInteractionEnabled = YES;

    // Position pan should lose to resize pan when both could fire on
    // the handle. Standard pattern: resize requires position to fail.
    [_positionPan requireGestureRecognizerToFail:_resizePan];
}

- (void)startTicker {
    _tickTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                 repeats:YES
                                                   block:^(NSTimer *_) {
        [self updateTimeText];
    }];
    // Fire immediately so the first frame has correct text.
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

#pragma mark - Layout

- (void)layoutSubviews {
    [super layoutSubviews];

    LFClockSettings *s = [LFClockSettings shared];
    UIFont *timeFont = [s resolvedFontForReferenceSize:kLFClockReferenceFontSize];
    _timeLabel.font  = timeFont;

    // Date label: smaller, semibold, system rounded for distinction.
    UIFont *dateFont = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    if (@available(iOS 13.0, *)) {
        UIFontDescriptor *d = [dateFont.fontDescriptor
            fontDescriptorWithDesign:UIFontDescriptorSystemDesignRounded];
        if (d) dateFont = [UIFont fontWithDescriptor:d size:14];
    }
    _dateLabel.font  = dateFont;

    // Color application -- adaptive uses cached luminance, others
    // use the literal color.
    UIColor *color = [s resolvedColorForBackgroundLuminance:_cachedLuminance];
    _timeLabel.textColor = color;
    _dateLabel.textColor = [color colorWithAlphaComponent:0.8];

    // Sizing pass: measure the time label first; date sits above it.
    CGSize timeSize = [_timeLabel.text
        sizeWithAttributes:@{ NSFontAttributeName: _timeLabel.font }];
    CGSize dateSize = [_dateLabel.text
        sizeWithAttributes:@{ NSFontAttributeName: _dateLabel.font }];

    CGFloat width  = MAX(timeSize.width,  dateSize.width)  + 24; // padding
    CGFloat height = timeSize.height + dateSize.height + 12;

    self.bounds = CGRectMake(0, 0, width, height);

    _dateLabel.frame = CGRectMake(0, 0,                       width, dateSize.height);
    _timeLabel.frame = CGRectMake(0, dateSize.height + 4,      width, timeSize.height);

    _glassBackground.frame = self.bounds;
    _glassBackground.glassCornerRadius = MIN(28, height / 2.0);

    // Handle sits at bottom-right, just outside the bounds so it's
    // clearly grippable. Visible only when editing.
    _resizeHandle.frame = CGRectMake(width - kLFHandleDiameter * 0.5,
                                     height - kLFHandleDiameter * 0.5,
                                     kLFHandleDiameter, kLFHandleDiameter);
    _resizeHandle.hidden = !_isEditing;
}

#pragma mark - Editing

- (void)setIsEditing:(BOOL)e {
    _isEditing = e;
    _resizeHandle.hidden = !e;
    // Subtle dashed border around the clock during editing tells the
    // user this is the draggable element.
    if (e) {
        self.layer.borderColor = [[UIColor colorWithWhite:1.0 alpha:0.35] CGColor];
        self.layer.borderWidth = 1.0;
        self.layer.cornerRadius = _glassBackground.glassCornerRadius;
    } else {
        self.layer.borderColor = nil;
        self.layer.borderWidth = 0.0;
    }
}

#pragma mark - Refresh

- (void)refreshFromSettings {
    LFClockSettings *s = [LFClockSettings shared];
    _liveScale = s.scale;
    _glassBackground.intensity = s.liquidGlassIntensity;
    [self updateTimeText];
    [self setNeedsLayout];
    [self layoutIfNeeded];

    // Apply stored offset to position so user's last drag-position
    // sticks across reloads.
    UIView *parent = self.superview;
    if (parent) {
        CGPoint base = CGPointMake(parent.bounds.size.width / 2.0,
                                   parent.safeAreaInsets.top + self.bounds.size.height / 2.0 + 60);
        self.center = CGPointMake(base.x + s.positionOffset.x,
                                  base.y + s.positionOffset.y);
    }
}

- (void)updateTimeText {
    static NSDateFormatter *timeF;
    static NSDateFormatter *dateF;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        timeF = [NSDateFormatter new];
        timeF.dateFormat = @"H:mm";   // matches Apple iOS 26 default (no zero pad)
        dateF = [NSDateFormatter new];
        dateF.dateFormat = @"EEEE, d MMMM";
    });
    NSDate *now = [NSDate date];
    _timeLabel.text = [timeF stringFromDate:now];
    _dateLabel.text = [[dateF stringFromDate:now] localizedUppercaseString];
    [self setNeedsLayout];
}

- (void)applyAdaptiveColorWithBackgroundImage:(UIImage *)bgImage {
    if (!bgImage) {
        _cachedLuminance = nil;
        [self setNeedsLayout];
        return;
    }
    // Sample the small region of the wallpaper that sits behind us.
    // Convert our frame to the bgImage's coordinate space approximately
    // by assuming bgImage covers the whole screen. We sample a 20x20
    // region of the bitmap centered on our viewport center -> average
    // luminance.
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

    // Average the pixels by drawing 1x1 and reading. Cheap on A9.
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

    // Rec. 709 luminance.
    CGFloat lum = (0.2126 * px[0] + 0.7152 * px[1] + 0.0722 * px[2]) / 255.0;
    _cachedLuminance = @(lum);
    [self setNeedsLayout];
}

#pragma mark - Gesture handlers

- (void)handlePositionPan:(UIPanGestureRecognizer *)pan {
    if (!_isEditing) return;
    UIView *parent = self.superview;
    if (!parent) return;

    CGPoint t = [pan translationInView:parent];
    [pan setTranslation:CGPointZero inView:parent];

    self.center = CGPointMake(self.center.x + t.x, self.center.y + t.y);

    if (pan.state == UIGestureRecognizerStateEnded ||
        pan.state == UIGestureRecognizerStateCancelled) {
        // Commit offset relative to the default base position.
        CGPoint base = CGPointMake(parent.bounds.size.width / 2.0,
                                   parent.safeAreaInsets.top +
                                   self.bounds.size.height / 2.0 + 60);
        CGPoint offset = CGPointMake(self.center.x - base.x,
                                     self.center.y - base.y);
        [LFClockSettings shared].positionOffset = offset;
        [[LFClockSettings shared] save];
    }
}

// Drag down/right -> bigger; drag up/left -> smaller. Matches iOS 26
// behaviour exactly (both axes contribute, dominant one wins).
- (void)handleResizePan:(UIPanGestureRecognizer *)pan {
    if (!_isEditing) return;
    CGPoint t = [pan translationInView:self];

    // Sensitivity: 200pt of drag covers the full 0.6 -> 2.8 range.
    // Combine the two axes into one scalar; vertical dominates because
    // the iOS 26 hint is "drag down to grow".
    CGFloat delta = (t.y * 0.7 + t.x * 0.3) / 200.0 * (2.8 - 0.6);

    // Apply to the live buffer; commit on release.
    static CGFloat startScale = 1.0;
    if (pan.state == UIGestureRecognizerStateBegan) {
        startScale = _liveScale;
    }
    CGFloat newScale = MAX(0.6, MIN(2.8, startScale + delta));
    _liveScale = newScale;
    [LFClockSettings shared].scale = newScale;

    [self setNeedsLayout];
    [self layoutIfNeeded];

    if (pan.state == UIGestureRecognizerStateEnded ||
        pan.state == UIGestureRecognizerStateCancelled) {
        [[LFClockSettings shared] save];
    }
}

@end
