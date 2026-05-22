#import "LFWidgetInline.h"
#import "LFOpenMeteoClient.h"
#import "LFLocationService.h"
#import <MediaPlayer/MediaPlayer.h>
#import <EventKit/EventKit.h>

// Single shared event store for all inline EventKit reads (calendar /
// reminders). Lazy-init on first use so the widget can be in a process
// that doesn't have EventKit linked at all (we always link, but the
// shared instance avoids spawning a second connection per use site).
static EKEventStore *gInlineEventStore;
static EKEventStore *lf_inlineStore(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gInlineEventStore = [EKEventStore new]; });
    return gInlineEventStore;
}

@interface LFWidgetInline () {
    UILabel     *_label;
    UIImageView *_iconView;
}
@end

@implementation LFWidgetInline

- (instancetype)initWithKind:(LFWidgetKind)kind
                      family:(LFWidgetFamily)family
                      config:(NSDictionary *)config {
    self = [super initWithKind:kind family:family config:config];
    if (!self) return nil;
    _label = [UILabel new];
    _label.textAlignment = NSTextAlignmentCenter;
    _label.textColor     = [UIColor whiteColor];
    _label.font          = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    [self addSubview:_label];

    _iconView = [UIImageView new];
    _iconView.tintColor   = [UIColor whiteColor];
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    [self addSubview:_iconView];

    [self refreshContent];
    return self;
}

- (NSTimeInterval)preferredRefreshInterval { return 30.0; }

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    NSString *symbol = [[self class] sfSymbolForKind:self.kind];
    // @available cannot be combined with another expression through
    // && inside a regular if condition -- clang refuses to treat that
    // form as gating the SF Symbol API below. Nest the version guard
    // inside the symbol-presence check instead.
    BOOL haveSymbol = NO;
    if (symbol.length) {
        if (@available(iOS 13.0, *)) {
            haveSymbol = YES;
            UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
                configurationWithPointSize:12 weight:UIImageSymbolWeightSemibold];
            if (!_iconView.image) {
                _iconView.image = [UIImage systemImageNamed:symbol withConfiguration:cfg];
            }
        }
    }
    if (haveSymbol) {
        _iconView.hidden = NO;
        _iconView.frame = CGRectMake(0, (b.size.height - 14) / 2.0, 14, 14);
        _label.frame    = CGRectMake(18, 0, b.size.width - 18, b.size.height);
        _label.textAlignment = NSTextAlignmentLeft;
    } else {
        _iconView.hidden = YES;
        _label.frame = self.bounds;
        _label.textAlignment = NSTextAlignmentCenter;
    }
}

- (void)refreshContent {
    _label.text = [[self class] resolvedTextForKind:self.kind config:self.config];
}

#pragma mark - Class-level resolver (used by LFClockOverlay too)

+ (NSString *)resolvedTextForKind:(LFWidgetKind)kind
                            config:(NSDictionary *)config {
    switch (kind) {
        case LFWidgetKindDate: {
            static NSDateFormatter *fmt;
            static dispatch_once_t once;
            dispatch_once(&once, ^{
                fmt = [NSDateFormatter new];
                fmt.dateFormat = @"EEEE, d MMMM";
            });
            return [[fmt stringFromDate:[NSDate date]] localizedUppercaseString];
        }
        case LFWidgetKindDayCounter: {
            NSCalendar *cal = [NSCalendar currentCalendar];
            NSDate *now = [NSDate date];
            NSUInteger d = [cal ordinalityOfUnit:NSCalendarUnitDay
                                          inUnit:NSCalendarUnitYear
                                         forDate:now];
            NSRange r = [cal rangeOfUnit:NSCalendarUnitDay
                                  inUnit:NSCalendarUnitYear
                                 forDate:now];
            NSUInteger total = (r.length == NSNotFound) ? 365 : r.length;
            if (d == NSNotFound) d = 1;
            return [NSString stringWithFormat:@"DAY %lu OF %lu",
                    (unsigned long)d, (unsigned long)total];
        }
        case LFWidgetKindCustomText: {
            NSString *t = config[@"text"];
            if (![t isKindOfClass:[NSString class]]) t = nil;
            t = t ? t : @"";
            if (t.length > 60) t = [t substringToIndex:60];
            return t.length ? [t localizedUppercaseString] : @"CUSTOM";
        }
        case LFWidgetKindBatteryInline: {
            UIDevice *dev = [UIDevice currentDevice];
            dev.batteryMonitoringEnabled = YES;
            float lvl = dev.batteryLevel;
            if (lvl < 0) return @"BATTERY";
            int pct = (int)roundf(lvl * 100.0f);
            BOOL charging = (dev.batteryState == UIDeviceBatteryStateCharging ||
                             dev.batteryState == UIDeviceBatteryStateFull);
            return [NSString stringWithFormat:@"%@ %d%%",
                    charging ? @"CHARGING" : @"BATTERY", pct];
        }
        case LFWidgetKindWeatherInline: {
            LFWeatherSnapshot *s = [[LFOpenMeteoClient shared] cachedSnapshot];
            if (!s) {
                [[LFOpenMeteoClient shared] refreshIfStaleWithUnit:LFTempUnitCelsius
                                                              force:NO completion:nil];
                return @"WEATHER";
            }
            return [NSString stringWithFormat:@"%d° %@",
                    (int)round(s.currentTemp),
                    [LFOpenMeteoClient conditionNameForWMOCode:s.currentWeatherCode]];
        }
        case LFWidgetKindCalendarInline: {
            EKAuthorizationStatus st = [EKEventStore authorizationStatusForEntityType:EKEntityTypeEvent];
            if (st != EKAuthorizationStatusAuthorized) return @"CALENDAR";
            EKEventStore *store = lf_inlineStore();
            NSDate *now   = [NSDate date];
            NSDate *until = [now dateByAddingTimeInterval:6 * 3600];
            NSPredicate *p = [store predicateForEventsWithStartDate:now
                                                            endDate:until
                                                          calendars:nil];
            EKEvent *e = [[store eventsMatchingPredicate:p] firstObject];
            if (!e) return @"NO EVENTS";
            NSDateFormatter *fmt = [NSDateFormatter new];
            fmt.dateFormat = @"h:mm a";
            return [[NSString stringWithFormat:@"%@ %@",
                     e.title ?: @"Event",
                     [fmt stringFromDate:e.startDate]] uppercaseString];
        }
        case LFWidgetKindRemindersInline: {
            EKAuthorizationStatus st = [EKEventStore authorizationStatusForEntityType:EKEntityTypeReminder];
            if (st != EKAuthorizationStatusAuthorized) return @"REMINDERS";
            // EventKit's reminder predicate is async; for an inline
            // widget we just return a placeholder + kick off a fetch
            // that updates a static cache so the next tick shows the
            // resolved title.
            static NSString *cachedTitle;
            EKEventStore *store = lf_inlineStore();
            NSPredicate *p = [store predicateForIncompleteRemindersWithDueDateStarting:nil
                                                                                 ending:nil
                                                                              calendars:nil];
            [store fetchRemindersMatchingPredicate:p completion:^(NSArray<EKReminder *> *items) {
                EKReminder *r = [items firstObject];
                cachedTitle = r.title.length ? [r.title uppercaseString] : @"NO REMINDERS";
            }];
            return cachedTitle ?: @"REMINDERS";
        }
        case LFWidgetKindStocksInline: {
            return @"STOCKS";
        }
        case LFWidgetKindActivityInline: {
            // HealthKit on iOS 15 from a JB tweak isn't trivially
            // available without entitlements; surface a placeholder
            // so the option is selectable but doesn't crash.
            return @"ACTIVITY";
        }
        case LFWidgetKindAppleTVInline: {
            return @"APPLE TV";
        }
        case LFWidgetKindSportsInline: {
            return @"SPORTS";
        }
        default: return @"";
    }
}

+ (NSString *)sfSymbolForKind:(LFWidgetKind)kind {
    switch (kind) {
        case LFWidgetKindWeatherInline:   return @"sun.max.fill";
        case LFWidgetKindBatteryInline:   return @"battery.100";
        case LFWidgetKindCalendarInline:  return @"calendar.badge.clock";
        case LFWidgetKindRemindersInline: return @"checklist";
        case LFWidgetKindStocksInline:    return @"chart.line.uptrend.xyaxis";
        case LFWidgetKindActivityInline:  return @"figure.walk";
        case LFWidgetKindAppleTVInline:   return @"tv.fill";
        case LFWidgetKindSportsInline:    return @"sportscourt.fill";
        default:                          return nil;     // text-only
    }
}

@end
