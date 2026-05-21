#import "LFClockOverlay.h"
#import "LFClockSettings.h"
#import "LFLiquidGlassView.h"
#import "LFGyroscopeManager.h"
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
@property (nonatomic, strong) LFLiquidGlassView *glassBackground;
// Date pill: small rounded rect with a thin white border that floats
// ABOVE the clock's selection box, exactly like iOS 16/26's editor
// preview. Contains the dateLabel as its single subview. The border
// is only set when -isEditing -- otherwise the pill is just a
// transparent label container, just like Apple shows the date as
// plain text outside the editor.
@property (nonatomic, strong) UIView            *datePillView;
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

    // Date pill geometry: text size + symmetric padding, rounded
    // ends.
    CGFloat datePillW = ceil(dateSize.width)  + 2 * kLFDatePillHPad;
    CGFloat datePillH = ceil(dateSize.height) + 2 * kLFDatePillVPad;

    // FULL-WIDTH iOS 16/26-style selection box. Spans the screen
    // width minus a small bezel inset -- not the natural width of
    // the digit text.
    UIView *parentForWidth = self.superview;
    CGFloat parentW = parentForWidth ? parentForWidth.bounds.size.width : 393.0;
    CGFloat boxW    = MAX(parentW - kLFFullWidthSideInset * 2.0,
                          datePillW + 24);

    // === iOS 26 Adaptive-Time clock resize via the HGHT axis ===
    //
    // On iOS 26 Apple's lock-screen clock uses a special font called
    // ".SFAdaptiveNumeric-Regular" (shipped inside ADTNumeric.ttc).
    // What makes the resize feel right is the font's HGHT axis -- a
    // private "height" variation axis that scales glyph height
    // WITHOUT touching the advance width or the stroke thickness.
    //
    // So when the user drags the resize handle:
    //
    //   - fontSize is computed ONCE to make "00:00" naturally fill
    //     boxW at HGHT=100 (default height). It does NOT change as
    //     the user drags -- the digits keep the same horizontal
    //     extent on the screen at every stretch level.
    //
    //   - HGHT is interpolated from 100 (vStretch=1.0) up to 500
    //     (vStretch=2.5). At HGHT=500 the cap-height is 5x the
    //     default, the digit advance widths are unchanged, and the
    //     stroke weights are also unchanged. Result: the clock
    //     "grows down" exactly the way Apple ships it on iOS 26.
    //
    //   - wght stays at 100 (Thin) the entire time, matching the
    //     stock-iOS lock-screen visual weight.
    //
    //   - wdth stays at 100 (default standard width). HGHT does all
    //     the visual work; we don't need to compress horizontally.
    static const CGFloat kLFVStretchMin = 1.0;
    static const CGFloat kLFVStretchMax = 2.5;

    CGFloat vStretch = MAX(kLFVStretchMin,
                           MIN(kLFVStretchMax, s.verticalStretch));
    CGFloat t = (vStretch - kLFVStretchMin) /
                (kLFVStretchMax - kLFVStretchMin);  // 0 .. 1

    // HGHT axis: 100 (default) at vStretch=1.0, up to 500 (max) at
    // vStretch=2.5. Linear ramp -- the user's finger movement maps
    // directly to glyph height, which is the simplest and most
    // predictable behaviour.
    CGFloat hght       = 100.0 + (500.0 - 100.0) * t;   // 100..500
    CGFloat fontWeight = 100.0;                          // Thin, constant
    CGFloat fontWidth  = 100.0;                          // Standard, constant

    // Use the ACTUAL displayed text for probing (not a hardcoded
    // "00:00") so that the rendered "9:10" / "23:59" / etc. exactly
    // fits the screen. .SFAdaptiveNumeric is mostly tabular but the
    // colon advance differs from digit advance, and locale-specific
    // forms can change the string length.
    NSString *probeText = (_timeLabel.text.length ? _timeLabel.text : @"00:00");

    CGFloat targetTextW = MAX(80.0, boxW - 2 * kLFTimePad);

    // === Re-probe at CURRENT HGHT ===
    //
    // First-pass fontSize derivation. We probe at fontSize=100 with
    // ALL THE SAME axis values we'll render with (most importantly,
    // the current HGHT) so that any cross-axis effect HGHT has on
    // advance widths in this font's HVAR / gvar tables is fully
    // compensated. If HGHT happens to widen advance widths at high
    // values (which inspection of Apple's Adaptive Numeric font
    // suggests it does -- the digits are designed to grow taller AND
    // a touch wider together so they remain visually balanced), the
    // fontSize we derive will be SMALLER at higher HGHT, and the
    // rendered "00:00" still fills exactly targetTextW.
    //
    // Net effect from the user's perspective: as the resize handle
    // is dragged, the digits grow taller with no horizontal change.
    // Width stays glued to the screen edge -- only the cap-height
    // increases.
    CGFloat fontSize = 144.0;     // sane default if probe fails

    UIFont *probe = lf_makeAdaptiveNumericFont(100.0, fontWeight,
                                               fontWidth, hght);
    if (probe) {
        CGSize probeSize = [probeText sizeWithAttributes:
            @{ NSFontAttributeName: probe }];
        if (probeSize.width > 1.0) {
            // Width scales linearly with fontSize at fixed axes,
            // so the size that hits targetTextW is exactly
            // targetTextW * 100 / probeSize.width.
            fontSize = targetTextW * 100.0 / probeSize.width;
        }
    }

    UIFont *timeFont = lf_makeAdaptiveNumericFont(fontSize, fontWeight,
                                                  fontWidth, hght);
    if (!timeFont) {
        // Bundled ADTNumeric.ttc is missing or didn't register
        // (descriptor resolver substituted a non-Adaptive font).
        // Fall back to the legacy static-font path: scale the user's
        // chosen font preset by the height ratio so resize at least
        // changes height visually -- but without HGHT support this
        // fallback also grows the digit width, so the clock won't
        // behave perfectly.
        timeFont = [s resolvedFontForReferenceSize:fontSize * (hght / 100.0)];
    }
    _timeLabel.font = timeFont;

    CGSize timeSize = [probeText sizeWithAttributes:
        @{ NSFontAttributeName: timeFont }];
    if (timeSize.width  < 1.0) timeSize.width  = 1.0;
    if (timeSize.height < 1.0) timeSize.height = 1.0;

    // === Safety-net shrink ===
    //
    // If the natural rendered width somehow STILL exceeds targetTextW
    // (e.g. the linear-scaling assumption breaks for this font, or
    // glyph ink overshoots advance width on a particular HGHT value),
    // shrink fontSize in one shot to fit. Preserves the chosen axes.
    // This is what keeps the digits from poking past the selection-
    // box border at any vStretch value.
    if (timeSize.width > targetTextW + 1.0) {
        CGFloat shrink = targetTextW / timeSize.width;
        fontSize *= shrink;
        UIFont *retried = lf_makeAdaptiveNumericFont(fontSize, fontWeight,
                                                     fontWidth, hght);
        if (!retried) {
            retried = [s resolvedFontForReferenceSize:fontSize * (hght / 100.0)];
        }
        timeFont = retried;
        _timeLabel.font = timeFont;
        timeSize = [probeText sizeWithAttributes:
            @{ NSFontAttributeName: timeFont }];
        if (timeSize.width  < 1.0) timeSize.width  = 1.0;
        if (timeSize.height < 1.0) timeSize.height = 1.0;
    }

    // Cap height + ascender headroom for the chosen variation. The
    // Adaptive Numeric font's MVAR table makes UIFont.capHeight and
    // UIFont.ascender interpolate with HGHT correctly, so reading
    // them here gives the actual visible cap height at the current
    // HGHT value. We size boxH from the visible cap-height (not the
    // full line-height) so kLFTimePad really shows up as kLFTimePad
    // to the user, on every side.
    CGFloat capHeight = timeFont.capHeight;
    CGFloat capTopGap = timeFont.ascender - capHeight;

    // Defensive sanity: if MVAR isn't being applied to capHeight on
    // this iOS version, capHeight reads as the HGHT=100 value while
    // the glyph is actually 5x taller. Detect that by comparing
    // measured timeSize.height (which DOES scale with HGHT through
    // the gvar deltas) against fontSize -- if timeSize.height is
    // significantly larger than the un-scaled cap, derive cap from
    // the measured height with a typical SF Pro ratio.
    CGFloat heightRatio = hght / 100.0;
    CGFloat fallbackCap = fontSize * 0.72 * heightRatio;
    if (capHeight < fallbackCap * 0.6) {
        capHeight = fallbackCap;
        capTopGap = fontSize * 0.05 * heightRatio;
    }

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

    // Date pill at the top of self, horizontally centred.
    _datePillView.frame              = CGRectMake((width - datePillW) / 2.0, 0,
                                                  datePillW, datePillH);
    _datePillView.layer.cornerRadius = datePillH / 2.0;
    _dateLabel.frame                 = CGRectMake(0, 0, datePillW, datePillH);

    // Selection box below the pill, full overlay width.
    CGFloat boxY = datePillH + kLFDatePillToBoxGap;
    _selectionBoxView.frame = CGRectMake(0, boxY, boxW, boxH);

    // Time label inside the selection box. With the variable-axis
    // path the label renders NATURALLY at the chosen font size + axes
    // -- no CGAffineTransform stretching. Bounds are exactly the
    // measured natural rendered size, transform stays identity.
    _timeLabel.transform = CGAffineTransformIdentity;
    _timeLabel.bounds    = CGRectMake(0, 0, timeSize.width, timeSize.height);

    CGFloat anchorBoxX;
    if (s.alignment == LFClockAlignmentLeft)        anchorBoxX = kLFTimePad;
    else if (s.alignment == LFClockAlignmentRight)  anchorBoxX = boxW - kLFTimePad;
    else                                            anchorBoxX = boxW / 2.0;

    // Anchor the label at its top edge (Y=0.0) so the visible cap-
    // top stays glued to a fixed Y in box-local coords as the font
    // size changes with vStretch. The cap-top sits capTopGap pixels
    // below the bounds-top in label-local coords (untransformed,
    // and there's no transform now so this is exact). To put the
    // visible cap-top at y=kLFTimePad we offset the layer position
    // upward by capTopGap pixels -- the label's own top edge sits
    // at negative Y inside the box, but the visible cap-top lands
    // at kLFTimePad exactly.
    //
    // Combined with the selection-box's fixed top in screen space
    // (centerInParentApplyingSettings glues self.frame.origin.y to
    // topPadding, and the box sits at a constant offset from that),
    // this gives the digits a constant cap-top Y on the screen
    // during resize. Only the bottom edge moves down as the user
    // drags the handle -- exactly the "glued top, grows down"
    // behaviour Apple ships on iOS 26.
    _timeLabel.layer.anchorPoint = CGPointMake(ax, 0.0);
    _timeLabel.layer.position    = CGPointMake(anchorBoxX,
                                               kLFTimePad - capTopGap);

    // Liquid-glass backdrop sits BEHIND the time digits, occupying
    // exactly the selection box. We position it in self's coords
    // (it's a sibling of _selectionBoxView) so the box's chrome
    // stays in front and the glass corner radius matches the box.
    _glassBackground.frame             = _selectionBoxView.frame;
    _glassBackground.glassCornerRadius = MIN(28, boxH / 2.0);
    _glassBackground.intensity         = s.liquidGlassIntensity;

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
