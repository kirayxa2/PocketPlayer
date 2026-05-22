#import "LFLocationService.h"
#import <CoreLocation/CoreLocation.h>

NSNotificationName const LFLocationDidUpdateNotification = @"LFLocationDidUpdate";

static NSString *const kLFLocationCachePath =
    @"/var/mobile/Library/LockForge/location.cache";

@interface LFLocationService () <CLLocationManagerDelegate> {
    LFLocationCoordinate _coord;
    BOOL                 _refreshInFlight;
    CLLocationManager   *_clManager;
    NSURLSession        *_session;
    BOOL                 _ipFallbackTimerArmed;
}
@end

@implementation LFLocationService

+ (instancetype)shared {
    static LFLocationService *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [LFLocationService new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        // Try to load disk cache; widgets get a sane fallback even
        // before the first network call returns.
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kLFLocationCachePath];
        if (d) {
            _coord.latitude  = [d[@"lat"] doubleValue];
            _coord.longitude = [d[@"lon"] doubleValue];
            _coord.valid     = YES;
        }
        // Ephemeral session: ipapi.co response is small and we don't
        // want NSURLCache to interfere.
        NSURLSessionConfiguration *cfg =
            [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.timeoutIntervalForRequest = 5.0;
        _session = [NSURLSession sessionWithConfiguration:cfg];
    }
    return self;
}

- (LFLocationCoordinate)currentCoordinate { return _coord; }

- (void)requestFixIfNeeded {
    if (_refreshInFlight) return;
    _refreshInFlight = YES;

    // Try CoreLocation first. If we don't have authorization yet, this
    // is a no-op (in a tweak we can't request permission with a UI
    // prompt -- SpringBoard's plist controls that). We start the
    // request, arm a 5s timer to fall back to IP geolocation, and
    // whichever returns first wins.
    if (!_clManager) {
        _clManager = [CLLocationManager new];
        _clManager.delegate        = self;
        _clManager.desiredAccuracy = kCLLocationAccuracyKilometer;
        _clManager.distanceFilter  = 1000.0;
    }
    CLAuthorizationStatus status = [CLLocationManager authorizationStatus];
    if (status == kCLAuthorizationStatusAuthorizedAlways ||
        status == kCLAuthorizationStatusAuthorizedWhenInUse) {
        [_clManager requestLocation];
    }

    // Always arm the IP fallback so denied/silent CL doesn't leave us
    // forever without coordinates. Only arm once per refresh cycle.
    if (!_ipFallbackTimerArmed) {
        _ipFallbackTimerArmed = YES;
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [weakSelf hitIpapiIfStillNeeded];
        });
    }
}

- (void)hitIpapiIfStillNeeded {
    _ipFallbackTimerArmed = NO;
    if (!_refreshInFlight) return;          // CL already returned

    NSURL *u = [NSURL URLWithString:@"https://ipapi.co/json/"];
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [_session dataTaskWithURL:u
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(self) self_ = weakSelf;
            if (!self_) return;
            self_->_refreshInFlight = NO;
            if (err || !data) return;
            NSError *jerr = nil;
            id obj = [NSJSONSerialization JSONObjectWithData:data
                                                      options:0
                                                        error:&jerr];
            if (![obj isKindOfClass:[NSDictionary class]]) return;
            NSDictionary *d = obj;
            id lat = d[@"latitude"];
            id lon = d[@"longitude"];
            if (![lat respondsToSelector:@selector(doubleValue)] ||
                ![lon respondsToSelector:@selector(doubleValue)]) {
                return;
            }
            [self_ ingestLatitude:[lat doubleValue]
                        longitude:[lon doubleValue]];
        });
    }];
    [task resume];
}

- (void)ingestLatitude:(double)lat longitude:(double)lon {
    _coord.latitude  = lat;
    _coord.longitude = lon;
    _coord.valid     = YES;
    NSString *dir = [kLFLocationCachePath stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    [@{ @"lat": @(lat), @"lon": @(lon) } writeToFile:kLFLocationCachePath
                                          atomically:YES];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:LFLocationDidUpdateNotification object:self];
}

#pragma mark - CLLocationManagerDelegate

- (void)locationManager:(CLLocationManager *)manager
     didUpdateLocations:(NSArray<CLLocation *> *)locations {
    CLLocation *l = [locations lastObject];
    if (!l) return;
    _refreshInFlight = NO;
    [self ingestLatitude:l.coordinate.latitude
               longitude:l.coordinate.longitude];
}

- (void)locationManager:(CLLocationManager *)manager
       didFailWithError:(NSError *)error {
    // CL is not going to give us anything useful; the IP fallback is
    // already armed so we'll get a fix from ipapi shortly.
}

@end
