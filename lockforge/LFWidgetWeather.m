#import "LFWidgetWeather.h"
#import "LFOpenMeteoClient.h"
#import "LFLocationService.h"

@interface LFWidgetWeather () {
    UIImageView *_iconView;
    UILabel     *_tempLabel;
    UILabel     *_condLabel;
    NSArray<UILabel *>     *_dayLabels;
    NSArray<UIImageView *> *_dayIcons;
    NSArray<UILabel *>     *_dayHighs;
}
@end

@implementation LFWidgetWeather

- (instancetype)initWithKind:(LFWidgetKind)kind
                      family:(LFWidgetFamily)family
                      config:(NSDictionary *)config {
    self = [super initWithKind:kind family:family config:config];
    if (!self) return nil;
    [self setupSubviewsForFamily:family];

    [[NSNotificationCenter defaultCenter]
        addObserver:self selector:@selector(refreshContent)
               name:LFLocationDidUpdateNotification object:nil];

    [[LFOpenMeteoClient shared] refreshIfStaleWithUnit:LFTempUnitCelsius
                                                  force:NO
                                             completion:^(LFWeatherSnapshot *_, NSError *__) {
        [self refreshContent];
    }];
    [self refreshContent];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (NSTimeInterval)preferredRefreshInterval { return 30.0 * 60.0; }

- (void)setupSubviewsForFamily:(LFWidgetFamily)family {
    [self installGlassBackdrop];

    _iconView             = [UIImageView new];
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    _iconView.tintColor   = [UIColor whiteColor];
    [self addSubview:_iconView];

    _tempLabel              = [UILabel new];
    _tempLabel.textColor    = [UIColor whiteColor];
    _tempLabel.textAlignment = NSTextAlignmentCenter;
    [self addSubview:_tempLabel];

    if (family == LFWidgetFamilyRectangular) {
        _condLabel              = [UILabel new];
        _condLabel.textColor    = [UIColor colorWithWhite:1.0 alpha:0.65];
        _condLabel.font = [LFLockScreenWidget systemFontOfSize:11
                                                        weight:UIFontWeightSemibold];
        [self addSubview:_condLabel];

        NSMutableArray *days = [NSMutableArray array];
        NSMutableArray *icons = [NSMutableArray array];
        NSMutableArray *highs = [NSMutableArray array];
        for (int i = 0; i < 3; i++) {
            UILabel *dn = [UILabel new];
            dn.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
            dn.font = [UIFont systemFontOfSize:9 weight:UIFontWeightBold];
            dn.textAlignment = NSTextAlignmentCenter;
            [self addSubview:dn]; [days addObject:dn];

            UIImageView *iv = [UIImageView new];
            iv.contentMode = UIViewContentModeScaleAspectFit;
            iv.tintColor = [UIColor whiteColor];
            [self addSubview:iv]; [icons addObject:iv];

            UILabel *hi = [UILabel new];
            hi.textColor = [UIColor whiteColor];
            hi.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
            hi.textAlignment = NSTextAlignmentCenter;
            [self addSubview:hi]; [highs addObject:hi];
        }
        _dayLabels = days; _dayIcons = icons; _dayHighs = highs;
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    if (self.family == LFWidgetFamilyCircular) {
        CGFloat icon = 28;
        _iconView.frame = CGRectMake((b.size.width - icon) / 2.0, 12, icon, icon);
        _tempLabel.frame = CGRectMake(0, 40, b.size.width, 28);
        _tempLabel.font = [LFLockScreenWidget systemFontOfSize:18
                                                        weight:UIFontWeightHeavy];
    } else {
        CGFloat iconSize = 30;
        _iconView.frame  = CGRectMake(12, 12, iconSize, iconSize);
        _tempLabel.frame = CGRectMake(8 + iconSize + 4, 6, 70, 26);
        _tempLabel.font  = [LFLockScreenWidget systemFontOfSize:22
                                                         weight:UIFontWeightHeavy];
        _tempLabel.textAlignment = NSTextAlignmentLeft;
        _condLabel.frame = CGRectMake(8 + iconSize + 4, 30, 80, 14);

        // 3-day strip on the RIGHT: 3 columns, each with day-name on top,
        // icon middle, high temp at bottom.
        CGFloat stripStartX = 92;
        CGFloat colW        = (b.size.width - stripStartX - 8) / 3.0;
        for (int i = 0; i < 3; i++) {
            CGFloat cx = stripStartX + colW * i;
            _dayLabels[i].frame = CGRectMake(cx, 6,  colW, 12);
            _dayIcons[i].frame  = CGRectMake(cx + (colW - 18) / 2.0, 22, 18, 18);
            _dayHighs[i].frame  = CGRectMake(cx, 44, colW, 14);
        }
    }
}

- (void)refreshContent {
    LFWeatherSnapshot *snap = [[LFOpenMeteoClient shared] cachedSnapshot];
    if (!snap) {
        _tempLabel.text = @"—°";
        if (_condLabel) _condLabel.text = @"NO DATA";
        if (@available(iOS 13.0, *)) {
            UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
                configurationWithPointSize:24 weight:UIImageSymbolWeightSemibold];
            _iconView.image = [UIImage systemImageNamed:@"cloud.fill"
                                       withConfiguration:cfg];
        }
        return;
    }
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
            configurationWithPointSize:24 weight:UIImageSymbolWeightSemibold];
        _iconView.image = [UIImage systemImageNamed:
            [LFOpenMeteoClient sfSymbolForWMOCode:snap.currentWeatherCode
                                            isDay:snap.isDay]
                              withConfiguration:cfg];
    }
    _tempLabel.text = [NSString stringWithFormat:@"%d°", (int)round(snap.currentTemp)];
    if (_condLabel) {
        _condLabel.text = [LFOpenMeteoClient conditionNameForWMOCode:snap.currentWeatherCode];
    }
    if (_dayLabels.count == 3) {
        NSDateFormatter *fmt = [NSDateFormatter new];
        fmt.dateFormat = @"EEE";
        for (int i = 0; i < 3 && i < (NSInteger)snap.forecast.count; i++) {
            LFWeatherDay *d = snap.forecast[i];
            _dayLabels[i].text = [[fmt stringFromDate:d.date] uppercaseString];
            if (@available(iOS 13.0, *)) {
                UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
                    configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];
                _dayIcons[i].image = [UIImage systemImageNamed:
                    [LFOpenMeteoClient sfSymbolForWMOCode:d.weatherCode isDay:YES]
                                      withConfiguration:cfg];
            }
            _dayHighs[i].text = [NSString stringWithFormat:@"%d°", (int)round(d.tempMax)];
        }
    }
}

@end
