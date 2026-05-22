#import "LFWidgetMoonPhase.h"

@interface LFWidgetMoonPhaseDrawing : UIView
@property (nonatomic) double phase;   // 0..1, 0=new, 0.5=full
@end

@implementation LFWidgetMoonPhaseDrawing
- (instancetype)initWithFrame:(CGRect)f {
    self = [super initWithFrame:f];
    if (self) self.backgroundColor = [UIColor clearColor];
    return self;
}
- (void)drawRect:(CGRect)r {
    // Draw a circle representing the moon disc, then the shadow as a
    // half-ellipse offset along the X axis. Phase encoding:
    //   0.00 new        ->  shadow covers the entire disc
    //   0.25 first qtr  ->  shadow covers left half
    //   0.50 full       ->  no shadow
    //   0.75 last qtr   ->  shadow covers right half
    //   1.00 new        ->  shadow covers the entire disc
    CGRect b = self.bounds;
    CGFloat d = MIN(b.size.width, b.size.height);
    CGRect disc = CGRectMake((b.size.width - d) / 2.0,
                             (b.size.height - d) / 2.0, d, d);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetFillColorWithColor(ctx, [UIColor whiteColor].CGColor);
    CGContextFillEllipseInRect(ctx, disc);

    CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0.0 alpha:0.78].CGColor);
    double p = self.phase;
    // Width of the shadow ellipse along X. At p=0/1 (new) covers full
    // disc; at p=0.5 (full) zero width; quarters are half-disc.
    CGFloat ellipseHalfW = d * fabs(0.5 - p) * 2.0;        // 0..d
    CGFloat shadowOffset = (p < 0.5) ? +ellipseHalfW/2 : -ellipseHalfW/2;

    // Draw the dark half-disc (the side that's in shadow) -- first
    // a full half rectangle, then mask back the bright crescent
    // using the offset ellipse.
    CGContextSaveGState(ctx);
    CGContextAddEllipseInRect(ctx, disc);
    CGContextClip(ctx);
    if (p < 0.5) {
        // Waxing: shadow on the LEFT, light on the RIGHT.
        CGRect leftHalf = CGRectMake(disc.origin.x, disc.origin.y, d/2, d);
        CGContextFillRect(ctx, leftHalf);
        // Carve out the light crescent (ellipse from middle pushed
        // toward the right by shadowOffset).
        CGRect ell = CGRectMake(disc.origin.x + d/2 - ellipseHalfW/2 + shadowOffset,
                                disc.origin.y, ellipseHalfW, d);
        CGContextSetFillColorWithColor(ctx, [UIColor whiteColor].CGColor);
        CGContextFillEllipseInRect(ctx, ell);
    } else {
        CGRect rightHalf = CGRectMake(disc.origin.x + d/2, disc.origin.y, d/2, d);
        CGContextFillRect(ctx, rightHalf);
        CGRect ell = CGRectMake(disc.origin.x + d/2 - ellipseHalfW/2 + shadowOffset,
                                disc.origin.y, ellipseHalfW, d);
        CGContextSetFillColorWithColor(ctx, [UIColor whiteColor].CGColor);
        CGContextFillEllipseInRect(ctx, ell);
    }
    CGContextRestoreGState(ctx);
}
@end

@interface LFWidgetMoonPhase () {
    LFWidgetMoonPhaseDrawing *_disc;
    UILabel                  *_phaseLabel;
}
@end

@implementation LFWidgetMoonPhase

- (instancetype)initWithKind:(LFWidgetKind)kind
                      family:(LFWidgetFamily)family
                      config:(NSDictionary *)config {
    self = [super initWithKind:kind family:family config:config];
    if (!self) return nil;
    [self installGlassBackdrop];

    _disc = [[LFWidgetMoonPhaseDrawing alloc] initWithFrame:CGRectZero];
    [self addSubview:_disc];

    _phaseLabel              = [UILabel new];
    _phaseLabel.textAlignment = NSTextAlignmentCenter;
    _phaseLabel.textColor    = [UIColor colorWithWhite:1.0 alpha:0.85];
    _phaseLabel.font         = [UIFont systemFontOfSize:9 weight:UIFontWeightBold];
    [self addSubview:_phaseLabel];

    [self refreshContent];
    return self;
}

- (NSTimeInterval)preferredRefreshInterval { return 6.0 * 3600.0; }

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    CGFloat discSize = MIN(b.size.width, b.size.height) - 20;
    _disc.frame = CGRectMake((b.size.width - discSize) / 2.0,
                             6,
                             discSize, discSize);
    _phaseLabel.frame = CGRectMake(0, b.size.height - 16, b.size.width, 14);
}

- (void)refreshContent {
    // Synodic-month phase calc. Reference new moon at 2000-01-06 18:14 UT
    // (Julian date 2451550.26).
    NSDateComponents *c = [[NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian]
        componentsInTimeZone:[NSTimeZone timeZoneWithAbbreviation:@"UTC"]
                     fromDate:[NSDate date]];
    int Y = (int)c.year, M = (int)c.month, D = (int)c.day;
    if (M < 3) { Y -= 1; M += 12; }
    int A = Y / 100;
    int B = 2 - A + A / 4;
    double JD = floor(365.25 * (Y + 4716)) + floor(30.6001 * (M + 1)) + D + B - 1524.5;
    double daysSinceNew = JD - 2451550.26;
    double cycles = daysSinceNew / 29.530588853;
    double phase = cycles - floor(cycles);   // 0..1

    _disc.phase = phase;
    [_disc setNeedsDisplay];

    NSString *name;
    if      (phase < 0.03 || phase > 0.97) name = @"NEW";
    else if (phase < 0.22) name = @"WAX CRES";
    else if (phase < 0.28) name = @"FIRST QTR";
    else if (phase < 0.47) name = @"WAX GIB";
    else if (phase < 0.53) name = @"FULL";
    else if (phase < 0.72) name = @"WAN GIB";
    else if (phase < 0.78) name = @"LAST QTR";
    else                   name = @"WAN CRES";
    _phaseLabel.text = name;
}

@end
