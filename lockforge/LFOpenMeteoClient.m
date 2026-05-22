#import "LFOpenMeteoClient.h"
#import "LFLocationService.h"

static NSString *const kLFWeatherCachePath =
    @"/var/mobile/Library/LockForge/weather.cache";
static const NSTimeInterval kLFWeatherTTL = 30.0 * 60.0;

@implementation LFWeatherDay
@end

@implementation LFWeatherSnapshot
// NSCoding-free serialization through plain plist dicts. Keeps the
// cache file editable by hand if a user wants to debug a stuck
// reading and avoids tying us to Foundation's archiving conventions
// across the iOS 15 SpringBoard <-> our process boundary.
+ (instancetype)fromPlist:(NSDictionary *)d {
    if (!d) return nil;
    LFWeatherSnapshot *s = [LFWeatherSnapshot new];
    s.currentTemp        = [d[@"currentTemp"]        doubleValue];
    s.currentHumidity    = [d[@"currentHumidity"]    doubleValue];
    s.currentWeatherCode = [d[@"currentWeatherCode"] integerValue];
    s.isDay              = [d[@"isDay"]              boolValue];
    s.fetchedAt          = d[@"fetchedAt"];
    NSMutableArray *days = [NSMutableArray array];
    for (NSDictionary *dd in (NSArray *)d[@"forecast"]) {
        LFWeatherDay *wd = [LFWeatherDay new];
        wd.date        = dd[@"date"];
        wd.tempMin     = [dd[@"tempMin"]     doubleValue];
        wd.tempMax     = [dd[@"tempMax"]     doubleValue];
        wd.weatherCode = [dd[@"weatherCode"] integerValue];
        [days addObject:wd];
    }
    s.forecast = days;
    return s;
}
- (NSDictionary *)toPlist {
    NSMutableArray *days = [NSMutableArray array];
    for (LFWeatherDay *d in self.forecast) {
        [days addObject:@{
            @"date":        d.date ?: [NSDate date],
            @"tempMin":     @(d.tempMin),
            @"tempMax":     @(d.tempMax),
            @"weatherCode": @(d.weatherCode),
        }];
    }
    return @{
        @"currentTemp":        @(self.currentTemp),
        @"currentHumidity":    @(self.currentHumidity),
        @"currentWeatherCode": @(self.currentWeatherCode),
        @"isDay":              @(self.isDay),
        @"fetchedAt":          self.fetchedAt ?: [NSDate date],
        @"forecast":           days,
    };
}
@end

@interface LFOpenMeteoClient () {
    LFWeatherSnapshot *_cache;
    BOOL               _refreshInFlight;
    NSURLSession      *_session;
}
@end

@implementation LFOpenMeteoClient

+ (instancetype)shared {
    static LFOpenMeteoClient *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [LFOpenMeteoClient new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        // Load cache from disk so widgets paint immediately on cold
        // start. Stale-allowed by design.
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kLFWeatherCachePath];
        _cache = [LFWeatherSnapshot fromPlist:d];

        // Plain ephemeral session -- we don't want NSURLCache layered
        // on top of our own disk cache, and we want zero cookies.
        NSURLSessionConfiguration *cfg =
            [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.timeoutIntervalForRequest = 8.0;
        cfg.HTTPMaximumConnectionsPerHost = 2;
        _session = [NSURLSession sessionWithConfiguration:cfg];
    }
    return self;
}

- (LFWeatherSnapshot *)cachedSnapshot { return _cache; }

- (void)refreshIfStaleWithUnit:(LFTempUnit)unit
                         force:(BOOL)force
                    completion:(void (^)(LFWeatherSnapshot *, NSError *))completion {
    if (_refreshInFlight) {
        if (completion) completion(_cache, nil);
        return;
    }

    BOOL stale = !_cache ||
        ([[NSDate date] timeIntervalSinceDate:_cache.fetchedAt] > kLFWeatherTTL);
    if (!force && !stale) {
        if (completion) completion(_cache, nil);
        return;
    }

    LFLocationCoordinate fix = [[LFLocationService shared] currentCoordinate];
    if (!fix.valid) {
        // No location yet -- ask service to acquire one and re-attempt.
        // We deliver the cached snapshot now (could be nil) and the
        // service will trigger another refresh when it has a fix.
        [[LFLocationService shared] requestFixIfNeeded];
        if (completion) completion(_cache, nil);
        return;
    }

    NSString *unitStr = (unit == LFTempUnitFahrenheit) ? @"fahrenheit" : @"celsius";
    NSString *url = [NSString stringWithFormat:
        @"https://api.open-meteo.com/v1/forecast"
        @"?latitude=%.4f&longitude=%.4f"
        @"&current=temperature_2m,weathercode,is_day,relativehumidity_2m"
        @"&daily=temperature_2m_max,temperature_2m_min,weathercode"
        @"&forecast_days=5&timezone=auto&temperature_unit=%@",
        fix.latitude, fix.longitude, unitStr];

    _refreshInFlight = YES;
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [_session dataTaskWithURL:[NSURL URLWithString:url]
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(self) self_ = weakSelf;
            if (!self_) return;
            self_->_refreshInFlight = NO;

            if (err || !data) {
                if (completion) completion(self_->_cache, err);
                return;
            }
            NSError *jerr = nil;
            id obj = [NSJSONSerialization JSONObjectWithData:data
                                                      options:0
                                                        error:&jerr];
            if (![obj isKindOfClass:[NSDictionary class]]) {
                if (completion) completion(self_->_cache, jerr);
                return;
            }
            LFWeatherSnapshot *s = [self_ parseSnapshot:obj];
            if (s) {
                self_->_cache = s;
                NSDictionary *plist = [s toPlist];
                NSString *dir = [kLFWeatherCachePath stringByDeletingLastPathComponent];
                [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                          withIntermediateDirectories:YES
                                                           attributes:nil
                                                                error:NULL];
                [plist writeToFile:kLFWeatherCachePath atomically:YES];
            }
            if (completion) completion(self_->_cache, nil);
        });
    }];
    [task resume];
}

- (LFWeatherSnapshot *)parseSnapshot:(NSDictionary *)d {
    NSDictionary *cur = d[@"current"];
    NSDictionary *daily = d[@"daily"];
    if (![cur isKindOfClass:[NSDictionary class]] ||
        ![daily isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    LFWeatherSnapshot *s = [LFWeatherSnapshot new];
    s.currentTemp        = [cur[@"temperature_2m"]      doubleValue];
    s.currentHumidity    = [cur[@"relativehumidity_2m"] doubleValue];
    s.currentWeatherCode = [cur[@"weathercode"]         integerValue];
    s.isDay              = [cur[@"is_day"]              integerValue] == 1;
    s.fetchedAt          = [NSDate date];

    NSArray *times    = daily[@"time"];
    NSArray *highs    = daily[@"temperature_2m_max"];
    NSArray *lows     = daily[@"temperature_2m_min"];
    NSArray *codes    = daily[@"weathercode"];
    NSMutableArray *days = [NSMutableArray array];
    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.dateFormat = @"yyyy-MM-dd";
    fmt.timeZone   = [NSTimeZone localTimeZone];
    for (NSUInteger i = 0; i < MIN(times.count, MIN(highs.count, MIN(lows.count, codes.count))); i++) {
        LFWeatherDay *wd = [LFWeatherDay new];
        wd.date        = [fmt dateFromString:times[i]] ?: [NSDate date];
        wd.tempMax     = [highs[i] doubleValue];
        wd.tempMin     = [lows[i]  doubleValue];
        wd.weatherCode = [codes[i] integerValue];
        [days addObject:wd];
    }
    s.forecast = days;
    return s;
}

#pragma mark - WMO mapping

// WMO weather codes per Open-Meteo docs. Mapping kept conservative --
// SF Symbol names available in iOS 15.
+ (NSString *)sfSymbolForWMOCode:(NSInteger)code isDay:(BOOL)isDay {
    if (code == 0)            return isDay ? @"sun.max.fill" : @"moon.stars.fill";
    if (code >= 1 && code <= 2)  return isDay ? @"cloud.sun.fill" : @"cloud.moon.fill";
    if (code == 3)               return @"cloud.fill";
    if (code == 45 || code == 48) return @"cloud.fog.fill";
    if (code >= 51 && code <= 57) return @"cloud.drizzle.fill";
    if (code >= 61 && code <= 67) return @"cloud.rain.fill";
    if (code >= 71 && code <= 77) return @"cloud.snow.fill";
    if (code == 80 || code == 81 || code == 82) return @"cloud.heavyrain.fill";
    if (code == 85 || code == 86) return @"cloud.snow.fill";
    if (code == 95)               return @"cloud.bolt.rain.fill";
    if (code == 96 || code == 99) return @"cloud.bolt.fill";
    return isDay ? @"sun.max.fill" : @"moon.stars.fill";
}

+ (NSString *)conditionNameForWMOCode:(NSInteger)code {
    if (code == 0)            return @"CLEAR";
    if (code >= 1 && code <= 2)  return @"PARTLY CLOUDY";
    if (code == 3)               return @"OVERCAST";
    if (code == 45 || code == 48) return @"FOG";
    if (code >= 51 && code <= 57) return @"DRIZZLE";
    if (code >= 61 && code <= 67) return @"RAIN";
    if (code >= 71 && code <= 77) return @"SNOW";
    if (code >= 80 && code <= 82) return @"SHOWERS";
    if (code == 85 || code == 86) return @"SNOW";
    if (code >= 95 && code <= 99) return @"THUNDER";
    return @"WEATHER";
}

@end
