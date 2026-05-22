#import "LFWidgetWorldClock.h"

@interface LFWidgetWorldClock () {
    UILabel *_timeLabel;
    UILabel *_cityLabel;
    NSTimer *_pollTimer;
}
@end

@implementation LFWidgetWorldClock

- (instancetype)initWithKind:(LFWidgetKind)kind
                      family:(LFWidgetFamily)family
                      config:(NSDictionary *)config {
    self = [super initWithKind:kind family:family config:config];
    if (!self) return nil;
    [self installGlassBackdrop];

    _timeLabel              = [UILabel new];
    _timeLabel.textColor    = [UIColor whiteColor];
    _timeLabel.textAlignment = NSTextAlignmentCenter;
    _timeLabel.font         = [LFLockScreenWidget systemFontOfSize:14
                                                            weight:UIFontWeightHeavy];
    [self addSubview:_timeLabel];

    _cityLabel              = [UILabel new];
    _cityLabel.textColor    = [UIColor colorWithWhite:1.0 alpha:0.6];
    _cityLabel.textAlignment = NSTextAlignmentCenter;
    _cityLabel.font         = [UIFont systemFontOfSize:8 weight:UIFontWeightBold];
    [self addSubview:_cityLabel];

    __weak typeof(self) weakSelf = self;
    _pollTimer = [NSTimer scheduledTimerWithTimeInterval:30.0
                                                 repeats:YES
                                                   block:^(NSTimer *_) {
        [weakSelf refreshContent];
    }];
    [self refreshContent];
    return self;
}

- (void)dealloc { [_pollTimer invalidate]; }
- (NSTimeInterval)preferredRefreshInterval { return 30.0; }

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    _timeLabel.frame = CGRectMake(0, b.size.height/2 - 14, b.size.width, 18);
    _cityLabel.frame = CGRectMake(0, b.size.height/2 + 6,  b.size.width, 10);
}

- (void)refreshContent {
    NSString *tzName = self.config[@"timezone"];
    NSTimeZone *tz = tzName ? [NSTimeZone timeZoneWithName:tzName] : nil;
    if (!tz) tz = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];

    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.dateFormat = @"H:mm";
    fmt.timeZone   = tz;
    _timeLabel.text = [fmt stringFromDate:[NSDate date]];

    // City name = last component of the timezone identifier; if the
    // identifier is something abbreviation-style ("UTC") just use it.
    NSString *display = tzName ?: tz.name;
    NSArray *parts = [display componentsSeparatedByString:@"/"];
    NSString *city = [[parts lastObject] stringByReplacingOccurrencesOfString:@"_"
                                                                    withString:@" "];
    _cityLabel.text = city.uppercaseString;
}

@end
