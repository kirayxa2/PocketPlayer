#import "LFWidgetBattery.h"

@interface LFWidgetBattery () {
    CAShapeLayer *_ringTrack;
    CAShapeLayer *_ringFill;
    UILabel      *_percentLabel;
    UILabel      *_titleLabel;        // "BATTERY" / "CHARGING"
    UIImageView  *_boltView;          // small lightning glyph when charging
}
@end

@implementation LFWidgetBattery

- (instancetype)initWithKind:(LFWidgetKind)kind
                      family:(LFWidgetFamily)family
                      config:(NSDictionary *)config {
    self = [super initWithKind:kind family:family config:config];
    if (!self) return nil;
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
    [self setupSubviewsForFamily:family];

    [[NSNotificationCenter defaultCenter]
        addObserver:self selector:@selector(refreshContent)
               name:UIDeviceBatteryLevelDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self selector:@selector(refreshContent)
               name:UIDeviceBatteryStateDidChangeNotification object:nil];

    [self refreshContent];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (NSTimeInterval)preferredRefreshInterval { return 30.0; }

- (void)setupSubviewsForFamily:(LFWidgetFamily)family {
    [self installGlassBackdrop];

    _ringTrack = [CAShapeLayer layer];
    _ringFill  = [CAShapeLayer layer];
    _ringTrack.fillColor   = [[UIColor clearColor] CGColor];
    _ringFill.fillColor    = [[UIColor clearColor] CGColor];
    _ringTrack.strokeColor = [[UIColor colorWithWhite:1.0 alpha:0.18] CGColor];
    _ringTrack.lineCap     = kCALineCapRound;
    _ringFill.lineCap      = kCALineCapRound;
    [self.layer addSublayer:_ringTrack];
    [self.layer addSublayer:_ringFill];

    _percentLabel = [UILabel new];
    _percentLabel.textAlignment = NSTextAlignmentCenter;
    _percentLabel.textColor     = [UIColor whiteColor];
    [self addSubview:_percentLabel];

    if (family == LFWidgetFamilyRectangular) {
        _titleLabel = [UILabel new];
        _titleLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.65];
        _titleLabel.font = [LFLockScreenWidget systemFontOfSize:11
                                                         weight:UIFontWeightSemibold];
        [self addSubview:_titleLabel];

        _boltView = [UIImageView new];
        _boltView.tintColor   = [UIColor systemYellowColor];
        _boltView.contentMode = UIViewContentModeScaleAspectFit;
        _boltView.hidden      = YES;
        [self addSubview:_boltView];
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    if (self.family == LFWidgetFamilyCircular) {
        CGFloat ring = MIN(b.size.width, b.size.height) - 8;
        CGRect ringRect = CGRectMake((b.size.width - ring) / 2.0,
                                     (b.size.height - ring) / 2.0,
                                     ring, ring);
        UIBezierPath *p = [UIBezierPath bezierPathWithOvalInRect:ringRect];
        _ringTrack.path = p.CGPath;
        _ringFill.path  = p.CGPath;
        _ringTrack.lineWidth = 6;
        _ringFill.lineWidth  = 6;
        _ringFill.transform  = CATransform3DMakeRotation(-M_PI_2, 0, 0, 1);
        _ringFill.frame      = self.bounds;
        _ringTrack.frame     = self.bounds;

        _percentLabel.frame = self.bounds;
        _percentLabel.font  = [LFLockScreenWidget systemFontOfSize:18
                                                            weight:UIFontWeightHeavy];
    } else {
        // Rectangular: ring on the LEFT, label stack on the RIGHT.
        CGFloat ring = b.size.height - 16;
        CGRect ringRect = CGRectMake(8, (b.size.height - ring) / 2.0, ring, ring);
        UIBezierPath *p = [UIBezierPath bezierPathWithOvalInRect:ringRect];
        _ringTrack.path = p.CGPath;
        _ringFill.path  = p.CGPath;
        _ringTrack.lineWidth = 5;
        _ringFill.lineWidth  = 5;
        _ringFill.transform  = CATransform3DMakeRotation(-M_PI_2, 0, 0, 1);
        _ringFill.frame      = self.bounds;
        _ringTrack.frame     = self.bounds;

        CGFloat textX = CGRectGetMaxX(ringRect) + 10;
        CGFloat textW = b.size.width - textX - 8;
        _titleLabel.frame   = CGRectMake(textX, b.size.height/2 - 22, textW, 14);
        _percentLabel.frame = CGRectMake(textX, b.size.height/2 - 6,  textW, 26);
        _percentLabel.font  = [LFLockScreenWidget systemFontOfSize:22
                                                            weight:UIFontWeightHeavy];
        _percentLabel.textAlignment = NSTextAlignmentLeft;
        CGFloat boltSize = 14;
        _boltView.frame = CGRectMake(CGRectGetMaxX(ringRect) - boltSize/2,
                                     CGRectGetMaxY(ringRect) - boltSize - 2,
                                     boltSize, boltSize);
    }
}

- (void)refreshContent {
    UIDevice *dev = [UIDevice currentDevice];
    float lvl = dev.batteryLevel;     // -1 if monitoring off
    if (lvl < 0) lvl = 1.0;           // simulator -> show full
    int pct = (int)roundf(lvl * 100.0f);

    UIColor *fillColor;
    if (lvl <= 0.2)      fillColor = [UIColor systemRedColor];
    else if (lvl <= 0.4) fillColor = [UIColor systemOrangeColor];
    else                 fillColor = [UIColor systemGreenColor];

    BOOL charging = (dev.batteryState == UIDeviceBatteryStateCharging ||
                     dev.batteryState == UIDeviceBatteryStateFull);
    if (charging) fillColor = [UIColor systemBlueColor];

    _ringFill.strokeColor = [fillColor CGColor];
    _ringFill.strokeStart = 0;
    _ringFill.strokeEnd   = MAX(0.02, MIN(1.0, lvl));   // never invisible

    _percentLabel.text = [NSString stringWithFormat:@"%d%%", pct];

    if (_titleLabel) {
        _titleLabel.text = charging ? @"CHARGING" : @"BATTERY";
    }
    _boltView.hidden = !charging;
    // @available(...) cannot be combined with other expressions through
    // && in a regular if-condition -- the compiler refuses to treat it
    // as guarding an availability check in that context. Split the
    // version guard into its own if so the symbol-image API is properly
    // gated for any pre-iOS-13 SDK usage that might happen to compile
    // this file.
    if (charging && !_boltView.image) {
        if (@available(iOS 13.0, *)) {
            UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
                configurationWithPointSize:12 weight:UIImageSymbolWeightBold];
            _boltView.image = [UIImage systemImageNamed:@"bolt.fill"
                                      withConfiguration:cfg];
        }
    }
}

@end
