#import "LFClockOverlay.h"
#import "LFClockSettings.h"
#import "LFLiquidGlassView.h"
#import "LFGyroscopeManager.h"
#import "LFLockScreenWidgetTray.h"
#import "LFWidgetInline.h"
#import <CoreText/CoreText.h>

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
// Reduced from 8pt to 4pt -- the bigger digits at full vStretch
// already eat most of the horizontal space, so giving the box an
// extra 8pt of width per side lets fontSize grow further before
// the post-measure shrink kicks in. Visual impact at default size
// is negligible (4pt padding looks identical to 8pt at this scale)
// while at full stretch it lets cap-height push closer to half the
// screen height.
static const CGFloat kLFFullWidthSideInset   = 4.0;

// Date pill (iOS 16/26 floats the date in a small rounded rectangle
// above the clock's selection box). Width follows the date text;
// the constants below define padding inside the pill plus its visual
// styling. The pill is OUTSIDE the selection box and its rounded
// border only appears in edit mode -- exactly the same chrome as
// the selection box itself.
static const CGFloat kLFDatePillVPad         = 4.0;
static const CGFloat kLFDatePillHPad         = 14.0;
static const CGFloat kLFDatePillToBoxGap     = 8.0;

// Padding INSIDE the clock's selection box: equal breathing room
// between the rounded outline and the time digits on all four
// sides. iOS 16/26 keeps the digits floating slightly off the
// outline; before this constant we had ~30pt above (left over from
// the date pill being inside the box) and only ~8pt on each side,
// which looked unbalanced. With kLFTimePad applied symmetrically
// the digits sit centred in the box with the same small gap on
// every edge.
// Reduced from 8pt to 6pt for the same reason as kLFFullWidthSideInset
// -- giving the digits more horizontal headroom inside the box lets
// fontSize grow ~10pt further before the shrink loop limits it,
// translating to ~7pt of extra cap-height. The remaining 6pt padding
// still reads as a clear visible gap on every side of the digits.
static const CGFloat kLFTimePad              = 6.0;

// === iOS 26 Adaptive-Time numeric font helper ===
//
// .SFAdaptiveNumeric-Regular ships inside ADTNumeric.ttc which is
// registered for our process at %ctor time (see Tweak.x). It exposes
// FOUR OpenType variation axes via its `fvar` table:
//
//   - 'HGHT' (height):  100 .. 500   (default 100)
//                       The axis Apple actually uses on iOS 26 lock-
//                       screen clocks. Scales glyph height ONLY -- the
//                       advance width and the stroke thicknesses are
//                       NOT modified by this axis. Driving HGHT from
//                       100 to 500 gives a 5x cap-height with the same
//                       digit width and the same stroke weight, which
//                       is the literal "growing taller" effect Apple
//                       ships and which we never managed to mimic on
//                       SF Pro (which has no height axis at all).
//   - 'wdth' (width):    60 .. 100   (default 100)
//   - 'wght' (weight):    1 .. 1000  (default 400)
//   - 'GRAD' (grade):   400 .. 1000  (hidden, leave at default)
//
// Returns nil if the font isn't registered, or if the descriptor
// resolver fell back to a non-Adaptive font (some iOS versions silently
// substitute when the requested PostScript name isn't found). Callers
// fall back to the static system-font path in that case.
//
// Axis tag bytes in C: stored as 4 bytes big-endian. Use explicit hex
// rather than multi-character literals so the encoding is portable.
//   'HGHT' = 0x48 0x47 0x48 0x54 = 0x48474854
//   'wdth' = 0x77 0x64 0x74 0x68 = 0x77647468
//   'wght' = 0x77 0x67 0x68 0x74 = 0x77676874
static UIFont *lf_makeAdaptiveNumericFont(CGFloat size,
                                          CGFloat weight,
                                          CGFloat width,
                                          CGFloat height) {
    NSDictionary *axes = @{
        @(0x48474854): @(height),  // 'HGHT'
        @(0x77647468): @(width),   // 'wdth'
        @(0x77676874): @(weight),  // 'wght'
    };
    NSDictionary *attrs = @{
        (id)kCTFontNameAttribute:      @".SFAdaptiveNumeric-Regular",
        (id)kCTFontVariationAttribute: axes,
    };
    CTFontDescriptorRef desc = CTFontDescriptorCreateWithAttributes(
        (__bridge CFDictionaryRef)attrs);
    if (!desc) return nil;
    CTFontRef ctFont = CTFontCreateWithFontDescriptor(desc, size, NULL);
    CFRelease(desc);
    if (!ctFont) return nil;

    // Sanity-check we got back the real Adaptive-Numeric face and not a
    // system fallback. If the .ttc registration failed silently the
    // descriptor resolver may quietly substitute Helvetica / system,
    // which accepts the size but ignores our axis values. Detect that
    // and tell the caller to fall back to the static-font path.
    NSString *gotName = (__bridge_transfer NSString *)
        CTFontCopyPostScriptName(ctFont);
    if (![gotName hasPrefix:@".SFAdaptive"]) {
        CFRelease(ctFont);
        return nil;
    }
    return (__bridge_transfer UIFont *)ctFont;
}

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
@property (nonatomic, strong, readwrite) LFLiquidGlassView *glassBackground;
@property (nonatomic, strong, readwrite) UIView            *datePillView;
@property (nonatomic, strong, readwrite) UIView            *widgetTray;
// Selection box: rounded-rect chrome that wraps the time digits.
// Always present as a layout container (so the time has a stable
// local coord system), but the visible border only appears in edit
// mode. Owns the resize-handle arc layer so the arc is visually a
// piece of the box's bottom-right corner curve.
@property (nonatomic, strong) UIView            *selectionBoxView;
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

// Digit-shaped mask layer applied to _glassBackground.layer when
// liquidGlassIntensity > 0. This is what makes the glass effect
// render INSIDE THE DIGITS THEMSELVES (the "цифры из стекла" iOS 26
// look) instead of as a rectangle BEHIND the digits.
//
// Technique: a CATextLayer with the SAME font, size, transform, and
// alignment as _timeLabel. CATextLayer renders white glyphs; when
// installed as `_glassBackground.layer.mask`, Core Animation uses
// each glyph's alpha as the visibility mask for the entire glass
// view. Result: blur, tint, specular highlight, gyro shimmer all
// show only inside the silhouettes of "9:10".
//
// While the mask is active, _timeLabel.layer.opacity is set to 0 so
// the regular non-glass text doesn't double up on top of the glass
// rendering. The label itself stays in the view tree (text accessible,
// metrics unchanged) -- only its visible alpha is gated.
//
// Apple uses an analogous technique on iOS 26: a "GlassMaterial" Metal
// pipeline runs over a region defined by the glyph paths, with the
// glyphs serving as the clipping geometry for the shader. We can't
// run that exact shader on iOS 15 (no .metallib at our build time),
// but the masking principle is the same and the visual result is the
// digit shapes are filled with the live blurred-wallpaper material.
@property (nonatomic, strong) CATextLayer       *digitMaskLayer;

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
    [self subscribeToBatteryNotifications];

    return self;
}

- (CGRect)datePillFrameInOverlayCoords {
    return _datePillView ? _datePillView.frame : CGRectZero;
}

- (void)dealloc {
    [_tickTimer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (_gyroSubscriberKey) {
        [[LFGyroscopeManager shared] removeSubscriber:_gyroSubscriberKey];
    }
}

- (void)buildSubviews {
    _glassBackground = [[LFLiquidGlassView alloc] initWithFrame:CGRectZero];
    _glassBackground.glassCornerRadius = 28;
    [self addSubview:_glassBackground];

    // Date pill: floats above the selection box. The border colour
    // and width are now driven by recomputeMetrics depending on
    // _isEditing -- in non-editing mode the pill is just a label
    // container with no visible chrome, matching what iOS shows on
    // the live lock screen. In editing mode it gets the same thin
    // rounded outline as the selection box.
    _datePillView                       = [UIView new];
    _datePillView.userInteractionEnabled = NO;
    _datePillView.layer.masksToBounds   = YES;
    [self addSubview:_datePillView];

    _dateLabel               = [UILabel new];
    _dateLabel.textAlignment = NSTextAlignmentCenter;
    _dateLabel.userInteractionEnabled = NO;
    [_datePillView addSubview:_dateLabel];

    // Selection box: rounded-rect chrome that wraps the time digits.
    // Always present as a layout container so the time label has a
    // stable local coordinate system; the visible border itself is
    // toggled in recomputeMetrics depending on _isEditing.
    // masksToBounds=NO so the resize-handle arc, which sits on this
    // view's layer and naturally extends a little past the corner
    // due to its half-stroke width, doesn't get clipped.
    _selectionBoxView                        = [UIView new];
    _selectionBoxView.userInteractionEnabled = NO;
    _selectionBoxView.backgroundColor        = [UIColor clearColor];
    _selectionBoxView.layer.masksToBounds    = NO;
    [self addSubview:_selectionBoxView];

    _timeLabel               = [UILabel new];
    _timeLabel.textAlignment = NSTextAlignmentCenter;
    _timeLabel.userInteractionEnabled = NO;
    _timeLabel.numberOfLines = 1;
    _timeLabel.adjustsFontSizeToFitWidth = NO;
    [_selectionBoxView addSubview:_timeLabel];

    [self buildResizeHandle];

    // Widget tray. Created here but parented to the overlay's
    // superview in -didMoveToSuperview so it can occupy areas of
    // the screen that lie outside the overlay's own bounds (e.g.
    // pinned at the bottom of the lockscreen above the camera /
    // flashlight buttons). This mirrors how iOS 26 lets the user
    // drag the tray to the bottom of the screen.
    LFLockScreenWidgetTray *tray = [[LFLockScreenWidgetTray alloc]
        initWithFrame:CGRectZero];
    [tray reloadFromSlotDictionaries:[LFClockSettings shared].traySlots];
    _widgetTray = tray;
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
    [_selectionBoxView.layer addSublayer:_resizeHandleArc];
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

// Battery widget (LFDateWidgetBattery) needs to refresh as soon as
// the level/state changes, not just on the once-a-second tick (which
// only updates if text *shape* changed -- the shape is identical for
// 85% vs 86%, so the per-second tick wouldn't catch small drops).
//
// Subscribe to the two NSNotifications UIDevice posts whenever the
// battery monitor sees a change, and force a text refresh from each.
// Cheap: notifications fire only on actual state transitions (~once
// per percent), and the refresh path is just a setText + layout.
- (void)subscribeToBatteryNotifications {
    UIDevice *dev = [UIDevice currentDevice];
    if (!dev.batteryMonitoringEnabled) {
        dev.batteryMonitoringEnabled = YES;
    }
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(onBatteryChanged:)
               name:UIDeviceBatteryLevelDidChangeNotification
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(onBatteryChanged:)
               name:UIDeviceBatteryStateDidChangeNotification
             object:nil];
}

- (void)onBatteryChanged:(NSNotification *)note {
    if ([LFClockSettings shared].dateWidget == LFDateWidgetBattery) {
        [self updateTimeText];
    }
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

    // (Time font is computed below by the iOS 26 non-uniform stretch
    // algorithm, after we know the parent's bounds and the current
    // verticalStretch. Don't pre-assign anything to _timeLabel.font
    // here -- it'd just be overwritten.)

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

    // Date pill geometry. iOS 16/26 customize sheet draws the date
    // pill's selection rectangle at the SAME width as the clock's
    // selection box -- they look like two stacked rounded boxes,
    // identical width, identical chrome. Outside edit mode the pill
    // is just a transparent text container, hugging the date string
    // tightly.
    CGFloat datePillH = ceil(dateSize.height) + 2 * kLFDatePillVPad;
    CGFloat datePillW;            // computed below after boxW is known

    // FULL-WIDTH iOS 16/26-style selection box. Spans the screen
    // width minus a small bezel inset -- not the natural width of
    // the digit text.
    UIView *parentForWidth = self.superview;
    CGFloat parentW = parentForWidth ? parentForWidth.bounds.size.width : 393.0;
    CGFloat boxW    = MAX(parentW - kLFFullWidthSideInset * 2.0,
                          ceil(dateSize.width) + 2 * kLFDatePillHPad + 24);

    // Date pill width: in edit mode -> full clock-box width (so the
    // chrome border matches the box's chrome border exactly, like
    // Apple). In non-edit mode -> tight around the date text.
    if (_isEditing) {
        datePillW = boxW;
    } else {
        datePillW = ceil(dateSize.width) + 2 * kLFDatePillHPad;
    }

    // === iOS 26 Adaptive-Time clock resize via HGHT + wdth axes ===
    //
    // On iOS 26 Apple's lock-screen clock uses .SFAdaptiveNumeric-
    // Regular (font #5 inside ADTNumeric.ttc) and drives the resize
    // handle by sweeping the font's private 'HGHT' (height) axis
    // from 100 to 500.
    //
    // Inspecting this font's HVAR table revealed HGHT is keyed in
    // 20 of 29 variation regions there -- HGHT does NOT just scale
    // glyph height, it also widens the advance widths by Apple's
    // intentional design. Apple's iOS 26 PosterKit pipeline
    // compensates the width post-render.
    //
    // On iOS 15 we approximate that compensation using TWO mechanisms
    // working together:
    //
    //   1. The font's OWN 'wdth' (width) axis -- 60..100. As we sweep
    //      HGHT up, we sweep wdth DOWN (100->60), so the font itself
    //      narrows the digits at the OpenType level. This is the
    //      preferred path because it's the font designer's intended
    //      compensation: stroke weights are interpolated correctly,
    //      no geometric distortion of glyph shape, no thinning of
    //      vertical strokes. Exactly what Apple does on iOS 26.
    //
    //   2. CGAffineTransform.scaleX as a SAFETY NET only. After the
    //      font is built with the chosen HGHT/wdth pair, we measure
    //      its natural rendered width. If the wdth axis (range
    //      100..60 = 40% compression max) wasn't enough to keep
    //      digits inside boxW, we apply a small additional
    //      horizontal squeeze. At typical HGHT values the wdth axis
    //      is enough on its own and scaleX is exactly 1.0.
    //
    //   - vStretch=1.0  -> HGHT=100, wdth=100. Digits at natural
    //                      proportions. No distortion.
    //   - vStretch=2.5  -> HGHT=500, wdth=60. Digits ~3x cap-height,
    //                      narrowed via the font's own width axis.
    //                      scaleX is close to 1.0; if needed it
    //                      adds a tiny squeeze on top.
    //
    // wght stays at 100 (Thin) -- matches the stock iOS lock-screen
    // visual weight Apple ships on the Adaptive Time clock face.
    static const CGFloat kLFVStretchMin = 1.0;
    static const CGFloat kLFVStretchMax = 2.5;

    CGFloat vStretch = MAX(kLFVStretchMin,
                           MIN(kLFVStretchMax, s.verticalStretch));
    CGFloat t = (vStretch - kLFVStretchMin) /
                (kLFVStretchMax - kLFVStretchMin);  // 0 .. 1

    CGFloat hght       = 100.0 + (500.0 - 100.0) * t;   // 100..500
    CGFloat fontWeight = 100.0;                          // Thin, constant
    CGFloat fontWidth  = 100.0 + ( 60.0 - 100.0) * t;   // 100..60 (compresses)

    // Use the ACTUAL displayed text for probing (not a hardcoded
    // "00:00") so that the rendered "9:10" / "23:59" / etc. exactly
    // fits the screen at HGHT=100. .SFAdaptiveNumeric is mostly
    // tabular but the colon advance differs from digit advance.
    NSString *probeText = (_timeLabel.text.length ? _timeLabel.text : @"00:00");
    CGFloat targetTextW = MAX(80.0, boxW - 2 * kLFTimePad);

    // === Step 1: pick fontSize ONCE, at the un-stretched baseline ===
    //
    // fontSize is the MINIMUM-state baseline -- the size at which
    // digits naturally fill the screen at vStretch=1.0 (HGHT=100,
    // wdth=100). Constant across all vStretch values. Probing at
    // the BASELINE axes (not the current ones) is what makes the
    // resize visible: as HGHT grows, the natural rendered cap-
    // height grows along with it and we DON'T cancel that growth
    // by shrinking fontSize.
    CGFloat fontSize = 144.0;     // sane default if probe fails

    UIFont *probeBaseline = lf_makeAdaptiveNumericFont(100.0, fontWeight,
                                                      100.0, 100.0);
    if (probeBaseline) {
        CGSize probeSize = [probeText sizeWithAttributes:
            @{ NSFontAttributeName: probeBaseline }];
        if (probeSize.width > 1.0) {
            fontSize = targetTextW * 100.0 / probeSize.width;
        }
    }

    // === Step 2: build the actual font with the current axes ===
    UIFont *timeFont = lf_makeAdaptiveNumericFont(fontSize, fontWeight,
                                                  fontWidth, hght);
    if (!timeFont) {
        // ADTNumeric.ttc didn't register or descriptor resolver
        // substituted a non-Adaptive font. Fall back to the legacy
        // static-font path: scale the user's chosen system-font preset
        // by vStretch so resize at least changes height visually --
        // imperfect (no HGHT support, will also widen the digits)
        // but better than the clock not resizing at all.
        timeFont = [s resolvedFontForReferenceSize:fontSize * vStretch];
    }
    _timeLabel.font = timeFont;

    CGSize timeSize = [probeText sizeWithAttributes:
        @{ NSFontAttributeName: timeFont }];
    if (timeSize.width  < 1.0) timeSize.width  = 1.0;
    if (timeSize.height < 1.0) timeSize.height = 1.0;

    // === Step 3: scaleX safety net for residual width overflow ===
    //
    // The font's wdth axis (100->60) handles ~40% of the width
    // compensation natively at the OpenType level. If HGHT widens
    // the digits more than 40% at high values, the rendered width
    // still exceeds targetTextW. Apply a pure horizontal CGAffine-
    // Transform squeeze for the residual. Visual stroke distortion
    // from this squeeze is minimal because the wdth axis already
    // did most of the work at the font level. At typical vStretch
    // values scaleX is close to 1.0.
    CGFloat scaleX = (timeSize.width > targetTextW)
                        ? (targetTextW / timeSize.width)
                        : 1.0;

    // Cap height + ascender headroom -- read from the font's MVAR-
    // aware properties. UIFont.capHeight and UIFont.ascender on
    // iOS 14+ DO interpolate with the variation axes for fonts with
    // an MVAR table (this one has it -- verified).
    //
    // No analytical fallback any more: with the wdth axis doing
    // most of the width compensation, fontSize stays at the BASELINE
    // value across the whole vStretch range, so capHeight grows
    // smoothly with HGHT through MVAR. The previous fallback
    // introduced a step-discontinuity at the threshold where the
    // sanity check tripped, which the user perceived as the clock
    // "jumping below the finger" mid-resize.
    CGFloat capHeight = timeFont.capHeight;
    CGFloat capTopGap = timeFont.ascender - capHeight;
    if (capHeight < 1.0) capHeight = fontSize * 0.72;
    if (capTopGap < 0.0) capTopGap = 0.0;

    CGFloat boxH = ceil(capHeight) + 2 * kLFTimePad;

    // Self bounds: date pill stacked above the selection box, with
    // a small fixed gap between them.
    CGFloat width  = boxW;
    CGFloat height = datePillH + kLFDatePillToBoxGap + boxH;
    _naturalSize   = CGSizeMake(width, height);

    NSTextAlignment ta = NSTextAlignmentCenter;
    CGFloat        ax = 0.5;
    if (s.alignment == LFClockAlignmentLeft)  { ta = NSTextAlignmentLeft;  ax = 0.0; }
    if (s.alignment == LFClockAlignmentRight) { ta = NSTextAlignmentRight; ax = 1.0; }
    _timeLabel.textAlignment = ta;
    _dateLabel.textAlignment = NSTextAlignmentCenter;

    self.bounds = CGRectMake(0, 0, width, height);

    // Date pill at the top of self, horizontally centred. Corner
    // radius matches the selection box's corner in edit mode (so the
    // two stacked rectangles read as a matched pair), and falls back
    // to fully-rounded "pill" ends in non-edit mode (Apple's stock
    // lock-screen date renders without any visible chrome anyway, so
    // the corner only really matters in edit).
    _datePillView.frame              = CGRectMake((width - datePillW) / 2.0, 0,
                                                  datePillW, datePillH);
    _datePillView.layer.cornerRadius = _isEditing
        ? MIN(28, datePillH / 2.0)
        : (datePillH / 2.0);
    _dateLabel.frame                 = CGRectMake(0, 0, datePillW, datePillH);

    // Selection box below the pill, full overlay width.
    CGFloat boxY = datePillH + kLFDatePillToBoxGap;
    _selectionBoxView.frame = CGRectMake(0, boxY, boxW, boxH);

    // Time label inside the selection box. Layer ops are ordered
    // carefully to avoid the "clock jumps below the finger" glitch
    // the user observed mid-resize:
    //
    //   1. Reset transform to identity FIRST. UIView.frame is
    //      "undefined" while transform != identity (per Apple docs);
    //      changing bounds/anchor/position with a stale non-identity
    //      transform applied makes UIKit recompute frame in
    //      unpredictable ways, which manifests as a vertical jump
    //      somewhere mid-drag.
    //   2. Set bounds to the natural rendered size.
    //   3. Set anchor to (ax, 0.0) -- top edge of the label is the
    //      fixed point. With anchor at top, scaleX squeezes around
    //      a horizontal line at Y=0 and never moves the cap-top
    //      vertically.
    //   4. Set position so the visible cap-top lands at box-local
    //      Y = kLFTimePad. (The label has capTopGap pixels of
    //      ascender headroom above its caps.)
    //   5. Apply the new scaleX transform LAST, after geometry is
    //      stable. Y is untouched -- height grows naturally with HGHT.
    _timeLabel.transform        = CGAffineTransformIdentity;
    _timeLabel.bounds           = CGRectMake(0, 0, timeSize.width, timeSize.height);

    CGFloat anchorBoxX;
    if (s.alignment == LFClockAlignmentLeft)        anchorBoxX = kLFTimePad;
    else if (s.alignment == LFClockAlignmentRight)  anchorBoxX = boxW - kLFTimePad;
    else                                            anchorBoxX = boxW / 2.0;

    _timeLabel.layer.anchorPoint = CGPointMake(ax, 0.0);
    _timeLabel.layer.position    = CGPointMake(anchorBoxX,
                                               kLFTimePad - capTopGap);
    _timeLabel.transform         = CGAffineTransformMakeScale(scaleX, 1.0);

    // Liquid-glass material now renders ON THE DIGITS THEMSELVES via a
    // glyph-shaped mask, NOT as a rectangle behind the digits. The
    // glass view spans the full selection box (so its blur captures
    // wallpaper from the full digit region), but the layer mask
    // clips the rendered effect to the digit silhouettes only.
    //
    // When intensity == 0 (Solid mode) the mask is removed and the
    // regular textColor-tinted UILabel is shown -- a plain solid
    // colour, exactly the toggle the user picked in the editor.
    _glassBackground.frame             = _selectionBoxView.frame;
    _glassBackground.glassCornerRadius = MIN(28, boxH / 2.0);
    _glassBackground.intensity         = s.liquidGlassIntensity;

    if (s.liquidGlassIntensity > 0) {
        // Glass mode: hide the regular text rendering, build/refresh
        // the digit-shaped mask, install it on the glass view's layer.
        // The text stays in _timeLabel (so accessibility and any other
        // text-driven layout still works) but its visible alpha is 0;
        // the glass material with its own shimmer/specular IS the
        // digit rendering now.
        _timeLabel.layer.opacity = 0.0;

        if (!_digitMaskLayer) {
            _digitMaskLayer = [CATextLayer layer];
            _digitMaskLayer.foregroundColor = [[UIColor whiteColor] CGColor];
            _digitMaskLayer.contentsScale   = [UIScreen mainScreen].scale;
            // Disable implicit animations on every property -- when the
            // minute rolls over and we update string/font/position, we
            // want the mask to switch instantly along with the visible
            // glass material, not lag behind with a fade.
            _digitMaskLayer.actions = @{
                @"contents":  [NSNull null],
                @"position":  [NSNull null],
                @"bounds":    [NSNull null],
                @"transform": [NSNull null],
                @"string":    [NSNull null],
                @"font":      [NSNull null],
                @"fontSize":  [NSNull null],
            };
        }
        _digitMaskLayer.string    = _timeLabel.text ?: @"";
        // CATextLayer wants a CTFont/CGFont/UIFont OR a string family
        // name. Pass the resolved variable UIFont directly -- CA bridges
        // it to a CTFont with all our axis values intact.
        _digitMaskLayer.font      = (__bridge CFTypeRef)timeFont;
        _digitMaskLayer.fontSize  = timeFont.pointSize;
        _digitMaskLayer.alignmentMode =
            (s.alignment == LFClockAlignmentLeft)  ? kCAAlignmentLeft  :
            (s.alignment == LFClockAlignmentRight) ? kCAAlignmentRight :
                                                     kCAAlignmentCenter;

        // Place the mask in the glass view's local coords. The glass
        // view's frame == _selectionBoxView.frame, so positions inside
        // the selection box translate 1:1 to positions inside the
        // glass view. We mirror exactly what we did to _timeLabel:
        //   - bounds   = natural rendered text size
        //   - anchor   = (ax, 0.0)  top-edge anchored
        //   - position = (anchorBoxX, kLFTimePad - capTopGap)
        //   - transform= horizontal squeeze identical to _timeLabel
        // so the digit silhouettes line up pixel-perfect with where
        // _timeLabel WOULD render if it weren't hidden.
        _digitMaskLayer.bounds      = CGRectMake(0, 0,
                                                 timeSize.width,
                                                 timeSize.height);
        _digitMaskLayer.anchorPoint = CGPointMake(ax, 0.0);
        _digitMaskLayer.position    = CGPointMake(anchorBoxX,
                                                  kLFTimePad - capTopGap);
        _digitMaskLayer.transform   = CATransform3DMakeAffineTransform(
            CGAffineTransformMakeScale(scaleX, 1.0));

        _glassBackground.layer.mask = _digitMaskLayer;
    } else {
        // Solid mode: tear down the mask and show the regular label.
        _timeLabel.layer.opacity   = 1.0;
        _glassBackground.layer.mask = nil;
        // Keep _digitMaskLayer instance alive between toggles so we
        // don't re-allocate when the user flips Glass/Solid back and
        // forth in the editor.
    }

    // Resize-handle arc: traces the bottom-right corner curve of
    // the SELECTION BOX, drawn in the box's local coord space (the
    // arc layer is on _selectionBoxView.layer).
    CGFloat cornerR       = MIN(28, boxH / 2.0);
    CGFloat sweep         = kLFHandleArcSweepDeg * M_PI / 180.0;
    CGFloat midAngle      = M_PI_4;   // 45 deg = toward bottom-right
    CGPoint cornerCircleC = CGPointMake(boxW - cornerR, boxH - cornerR);

    UIBezierPath *arcPath =
        [UIBezierPath bezierPathWithArcCenter:cornerCircleC
                                       radius:cornerR
                                   startAngle:midAngle - sweep / 2.0
                                     endAngle:midAngle + sweep / 2.0
                                    clockwise:YES];
    _resizeHandleArc.path   = arcPath.CGPath;
    _resizeHandleArc.frame  = _selectionBoxView.bounds;
    _resizeHandleArc.hidden = !_isEditing;

    // Touch zone in self's coord space: convert from box-local to
    // self by adding the selection box's origin offset. Half the
    // 44x44 sits OUTSIDE the box (since its centre is on the corner)
    // -- self's hitTest override catches that outer half too.
    CGFloat midX        = cornerCircleC.x + cornerR * cos(midAngle);
    CGFloat midY        = cornerCircleC.y + cornerR * sin(midAngle);
    CGFloat midInSelfX  = midX + _selectionBoxView.frame.origin.x;
    CGFloat midInSelfY  = midY + _selectionBoxView.frame.origin.y;
    _resizeHandle.frame = CGRectMake(midInSelfX - kLFHandleTouchDiameter / 2.0,
                                     midInSelfY - kLFHandleTouchDiameter / 2.0,
                                     kLFHandleTouchDiameter,
                                     kLFHandleTouchDiameter);
    _resizeHandle.hidden = !_isEditing;

    // Editing-mode chrome: thin rounded outline on BOTH the date
    // pill AND the selection box, identical style. Outside edit
    // mode neither view shows a border, so the live lock screen
    // displays the date as plain text above plain digits.
    if (_isEditing) {
        CGColorRef chrome = [[UIColor colorWithWhite:1.0 alpha:0.30] CGColor];
        _selectionBoxView.layer.borderColor  = chrome;
        _selectionBoxView.layer.borderWidth  = 1.0;
        _selectionBoxView.layer.cornerRadius = MIN(28, boxH / 2.0);
        _datePillView.layer.borderColor      = chrome;
        _datePillView.layer.borderWidth      = 1.0;
    } else {
        _selectionBoxView.layer.borderColor = nil;
        _selectionBoxView.layer.borderWidth = 0.0;
        _datePillView.layer.borderColor     = nil;
        _datePillView.layer.borderWidth     = 0.0;
    }

    // self.layer never has its own border now -- the selection box
    // owns the editing-mode outline.
    self.layer.borderWidth = 0.0;
    self.layer.borderColor = nil;

    // Anchor the top edge in superview coordinates so vertical growth
    // never tugs the date pill upward off-screen. centerInParent... is
    // the single owner of self.center.y; calling it at the end of
    // every recomputeMetrics ensures resize, font swaps, and minute
    // changes all converge to the same fixed top.
    [self centerInParentApplyingSettings];

    // Tray placement depends on overlay frame (under-clock position
    // anchors to the overlay bottom) -- recompute every time geometry
    // changes so the tray follows the clock when it grows downward.
    [self repositionWidgetTray];
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

        // Mount the widget tray as a sibling of self in the
        // superview, behind self in z-order so the clock's chrome
        // is always on top of any tray content. This is what gives
        // the iOS 26 "tray pinned to the bottom of the screen even
        // though the clock is at the top" behaviour -- the tray's
        // frame is computed in superview coords without dragging
        // the clock's bounds along with it.
        if (_widgetTray && _widgetTray.superview != self.superview) {
            [_widgetTray removeFromSuperview];
            [self.superview insertSubview:_widgetTray belowSubview:self];
            [self repositionWidgetTray];
        }
    } else if (_widgetTray) {
        // Detached from screen -- pull the tray with us so it doesn't
        // leak into a stale superview.
        [_widgetTray removeFromSuperview];
    }
}

#pragma mark - Editing toggle

- (void)setIsEditing:(BOOL)e {
    if (_isEditing == e) return;
    _isEditing = e;
    [self recomputeMetrics];
    if ([_widgetTray respondsToSelector:@selector(setIsEditing:)]) {
        ((LFLockScreenWidgetTray *)_widgetTray).isEditing = e;
    }
}

#pragma mark - Refresh from settings

- (void)refreshFromSettings {
    [self updateTimeText];
    [self recomputeMetrics];
    [self centerInParentApplyingSettings];

    // Pull the latest tray slot list from settings. Cheap to do here
    // -- editor mutations call refreshFromSettings after each picker
    // confirmation, so the live tray stays in sync with disk.
    if ([_widgetTray respondsToSelector:@selector(reloadFromSlotDictionaries:)]) {
        [(LFLockScreenWidgetTray *)_widgetTray
            reloadFromSlotDictionaries:[LFClockSettings shared].traySlots];
        [self repositionWidgetTray];
    }
}

// Position the tray either right under the clock OR pinned to the
// bottom-area of the parent (above the camera/flashlight affordances
// that sit ~110pt above the safe-area bottom). Read once per
// recomputeMetrics so vertical-stretch resize keeps the tray flush
// against the bottom of the (now taller) clock-box when the user is
// in the under-clock position.
- (void)repositionWidgetTray {
    UIView *parent = self.superview;
    if (!parent || !_widgetTray) return;
    LFLockScreenWidgetTray *tray = (LFLockScreenWidgetTray *)_widgetTray;

    // While the user is actively dragging the tray with a finger,
    // hand the frame off to the tray's own pan handler -- if we
    // overwrite frame from here, the live drag would visibly fight
    // the user's gesture (jitter to where we want it, snap back to
    // where the finger is, etc).
    if ([tray respondsToSelector:@selector(isUserDragging)] &&
        tray.isUserDragging) {
        return;
    }

    // The selection-rect chrome around the tray has to match the
    // clock-box width exactly so the three rectangles (clock, date
    // pill, widget tray) line up as a column when editing.
    CGFloat clockBoxW = _selectionBoxView.bounds.size.width;
    if (clockBoxW < 1) clockBoxW = self.bounds.size.width;
    tray.selectionWidth = clockBoxW;

    CGSize natural = tray.naturalSize;
    if (natural.width < 1 || natural.height < 1) {
        tray.hidden = YES;
        return;
    }
    // Hide entirely off-edit when the tray has no widgets -- otherwise
    // the lock screen reserves an invisible 1pt strip for nothing.
    if (!_isEditing && tray.usedUnits == 0) {
        tray.hidden = YES;
        return;
    }
    tray.hidden = NO;

    // When editing, expand the tray's bounds to the clock-box width so
    // the chrome rectangle has room to draw. Off-edit, hug the natural
    // content size so the tray doesn't soak up touches outside the
    // visible widgets.
    CGFloat trayW = _isEditing ? MAX(natural.width, clockBoxW)
                                : natural.width;
    CGFloat trayH = MAX(natural.height, 76);

    LFTrayPosition pos = [LFClockSettings shared].trayPosition;
    CGFloat parentW = parent.bounds.size.width;
    CGFloat parentH = parent.bounds.size.height;
    UIEdgeInsets safe = parent.safeAreaInsets;

    CGFloat trayY;
    if (pos == LFTrayPositionAtBottom) {
        // ~110pt of bottom-strip is reserved for camera/flashlight on
        // iPhone X+ and the home-indicator. iPhone 6s has none of
        // those affordances but the tray still reads better with a
        // generous margin.
        trayY = parentH - safe.bottom - 110.0 - trayH;
    } else {
        // Just below the clock-overlay's frame, with a comfortable
        // gap so the tray doesn't kiss the selection-box border.
        trayY = CGRectGetMaxY(self.frame) + 12.0;
    }
    CGRect f = CGRectMake((parentW - trayW) / 2.0,
                          trayY,
                          trayW, trayH);
    tray.frame = f;
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
    NSString *d = [self resolvedDateWidgetTextForDate:now formatter:dateF];
    BOOL textChanged = (![t isEqualToString:_timeLabel.text] ||
                        ![d isEqualToString:_dateLabel.text]);
    _timeLabel.text = t;
    _dateLabel.text = d;
    // Only redo metrics if text actually changed shape (e.g. minute
    // rolled, or HH digit width changed). Otherwise we waste cycles.
    if (textChanged) [self recomputeMetrics];
}

// === iOS 26 single-line widget resolver for the "date pill" ===
//
// Reads LFClockSettings.dateWidget and produces the string that the
// _dateLabel renders. The four cases each derive their text from a
// system API that's free on iOS 15:
//
//   Date        -> NSDateFormatter localized
//   Battery     -> UIDevice.batteryLevel (-1.0 if monitoring is off)
//   DayCounter  -> NSCalendar -ordinalityOfUnit:inUnit: (day in year)
//   CustomText  -> raw string from the user's editor input
//
// Every text path is upper-cased to match the shipped lock-screen
// look (Apple uppercases the date string on lock-screen specifically;
// other contexts use sentence-case).
- (NSString *)resolvedDateWidgetTextForDate:(NSDate *)now
                                  formatter:(NSDateFormatter *)dateFmt {
    // The legacy resolver lived here when LFDateWidget was a 4-value
    // enum (Date/Battery/Day/Custom). The catalog now exposes ~10
    // inline kinds matching iOS 26's expanded inline picker; settings
    // store the chosen kind in `dateInlineKind` (with migration from
    // `dateWidget` happening at load time, see LFClockSettings.m).
    //
    // We delegate to LFWidgetInline's class-level resolver so any new
    // inline kind we add to the catalog (Stocks, Sports, Apple TV...)
    // is picked up automatically without touching this method.
    LFClockSettings *s = [LFClockSettings shared];
    NSString *txt = [LFWidgetInline resolvedTextForKind:s.dateInlineKind
                                                  config:s.dateInlineConfig];
    return txt.length ? txt : [[dateFmt stringFromDate:now] localizedUppercaseString];
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
    //   drag DOWN by N pt -> vStretch += N / 180 * (2.5 - 1.0)
    //   drag UP   by N pt -> vStretch -= same
    //
    // Clamped at [1.0, 2.5]. At 2.5 digits reach ~430pt tall on a
    // 6s -- well over half the 667pt screen height.
    //
    // Divisor 180 (down from 300) makes the drag feel significantly
    // lighter: a casual ~half-screen swipe (~330pt) takes the user
    // well past max stretch, so the handle responds with strong
    // visual feedback per pixel of finger movement.
    CGFloat range       = 2.5 - 1.0;
    CGFloat delta       = t.y / 180.0 * range;
    CGFloat newVStretch = MAX(1.0, MIN(2.5, _resizeStartVStretch + delta));

    BOOL changed = NO;
    if (fabs(newVStretch - [LFClockSettings shared].verticalStretch) > 0.001) {
        [LFClockSettings shared].verticalStretch = newVStretch;
        changed = YES;
    }

    // iOS 26: as soon as the user starts growing the clock, the
    // widget tray "переплывает" из положения под часами в нижнее
    // (above the camera/flashlight strip), so the growing digits
    // never collide with the tray. Threshold a little above 1.0 so
    // tiny incidental drift doesn't kick the tray loose; once we
    // commit the move, the tray stays at the bottom until the user
    // explicitly drags it back up (handled in editor's
    // -tray:didDragWithTranslationY:ended:).
    if (newVStretch > 1.05 &&
        [LFClockSettings shared].trayPosition == LFTrayPositionUnderClock) {
        [LFClockSettings shared].trayPosition = LFTrayPositionAtBottom;
        // Animate the tray's frame to its new home so the move
        // reads as "tray flowing downward" rather than a teleport.
        [UIView animateWithDuration:0.32
                              delay:0
             usingSpringWithDamping:0.9
              initialSpringVelocity:0.0
                            options:UIViewAnimationOptionCurveEaseOut |
                                    UIViewAnimationOptionAllowUserInteraction
                         animations:^{
            [self repositionWidgetTray];
        }
                         completion:nil];
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
