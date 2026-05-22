#import "LFWidgetSteps.h"
#import <CoreMotion/CoreMotion.h>

@interface LFWidgetSteps () {
    CMPedometer *_pedometer;
    CAShapeLayer *_ringTrack;
    CAShapeLayer *_ringFill;
    UILabel      *_topLabel;     // "5,234"
    UILabel      *_botLabel;     // "STEPS"
    NSTimer      *_pollTimer;
    NSInteger     _stepsToday;
}
@end

@implementation LFWidgetSteps

- (instancetype)initWithKind:(LFWidgetKind)kind
                      family:(LFWidgetFamily)family
                      config:(NSDictionary *)config {
    self = [super initWithKind:kind family:family config:config];
    if (!self) return nil;
    [self installGlassBackdrop];

    _ringTrack = [CAShapeLayer layer];
    _ringFill  = [CAShapeLayer layer];
    _ringTrack.fillColor = [[UIColor clearColor] CGColor];
    _ringFill.fillColor  = [[UIColor clearColor] CGColor];
    _ringTrack.strokeColor = [[UIColor colorWithWhite:1.0 alpha:0.15] CGColor];
    _ringFill.strokeColor  = [[UIColor systemGreenColor] CGColor];
    _ringTrack.lineCap = kCALineCapRound;
    _ringFill.lineCap  = kCALineCapRound;
    [self.layer addSublayer:_ringTrack];
    [self.layer addSublayer:_ringFill];

    _topLabel              = [UILabel new];
    _topLabel.textAlignment = NSTextAlignmentCenter;
    _topLabel.textColor    = [UIColor whiteColor];
    _topLabel.font         = [LFLockScreenWidget systemFontOfSize:13
                                                           weight:UIFontWeightHeavy];
    [self addSubview:_topLabel];

    _botLabel              = [UILabel new];
    _botLabel.textAlignment = NSTextAlignmentCenter;
    _botLabel.textColor    = [UIColor colorWithWhite:1.0 alpha:0.55];
    _botLabel.font         = [UIFont systemFontOfSize:8 weight:UIFontWeightBold];
    _botLabel.text         = @"STEPS";
    [self addSubview:_botLabel];

    if ([CMPedometer isStepCountingAvailable]) {
        _pedometer = [CMPedometer new];
    }

    __weak typeof(self) weakSelf = self;
    _pollTimer = [NSTimer scheduledTimerWithTimeInterval:60.0
                                                 repeats:YES
                                                   block:^(NSTimer *_) {
        [weakSelf refreshContent];
    }];
    [self refreshContent];
    return self;
}

- (void)dealloc { [_pollTimer invalidate]; }

- (NSTimeInterval)preferredRefreshInterval { return 60.0; }

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    CGFloat ring = MIN(b.size.width, b.size.height) - 8;
    CGRect ringRect = CGRectMake((b.size.width - ring) / 2.0,
                                 (b.size.height - ring) / 2.0,
                                 ring, ring);
    UIBezierPath *p = [UIBezierPath bezierPathWithOvalInRect:ringRect];
    _ringTrack.path = p.CGPath;
    _ringFill.path  = p.CGPath;
    _ringTrack.lineWidth = 5;
    _ringFill.lineWidth  = 5;
    _ringFill.transform  = CATransform3DMakeRotation(-M_PI_2, 0, 0, 1);
    _ringFill.frame      = self.bounds;
    _ringTrack.frame     = self.bounds;

    _topLabel.frame = CGRectMake(0, b.size.height/2 - 14, b.size.width, 18);
    _botLabel.frame = CGRectMake(0, b.size.height/2 + 6,  b.size.width, 10);
}

- (void)refreshContent {
    if (!_pedometer) {
        _topLabel.text = @"—";
        _ringFill.strokeEnd = 0;
        return;
    }
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDate *startOfDay = [cal startOfDayForDate:[NSDate date]];
    [_pedometer queryPedometerDataFromDate:startOfDay
                                    toDate:[NSDate date]
                               withHandler:^(CMPedometerData *data, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error || !data) return;
            self->_stepsToday = [data.numberOfSteps integerValue];
            NSNumberFormatter *f = [NSNumberFormatter new];
            f.numberStyle = NSNumberFormatterDecimalStyle;
            self->_topLabel.text = [f stringFromNumber:@(self->_stepsToday)];
            CGFloat goal = 10000.0;
            self->_ringFill.strokeEnd = MAX(0.02, MIN(1.0, self->_stepsToday / goal));
        });
    }];
}

@end
