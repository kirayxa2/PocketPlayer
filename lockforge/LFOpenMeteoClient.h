// LFOpenMeteoClient - minimal weather data client for LockForge widgets.
//
// Apple's WeatherKit is iOS 16+ and requires a developer entitlement,
// neither available to a jailbroken iOS 15 tweak. OpenWeatherMap free
// tier requires a personal API key per user and rate-limits at
// 60 calls/minute -- workable but every user has to register and the
// key can get banned if shared.
//
// Open-Meteo is the right choice here: free, no key, no signup, no
// per-IP rate limit for personal use, returns clean JSON. Their docs
// are at https://open-meteo.com/en/docs. Coverage is global.
//
// API call shape used by LockForge:
//
//   GET https://api.open-meteo.com/v1/forecast
//       ?latitude=<lat>&longitude=<lon>
//       &current=temperature_2m,weathercode,is_day,relativehumidity_2m
//       &daily=temperature_2m_max,temperature_2m_min,weathercode
//       &forecast_days=5&timezone=auto&temperature_unit=<unit>
//
// Response is JSON. We pull the current temperature + WMO weather
// code, plus the daily forecast strip for the rectangular widget,
// and cache the parsed result in /var/mobile/Library/LockForge/
// weather.cache for 30 minutes (TTL is conservative -- weather
// data changes slowly enough that a screen wake within 30 min of a
// previous fetch should NOT block on the network).

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Day in a 5-day forecast. Times are NSDates in the device timezone
// because Open-Meteo's ?timezone=auto parameter returns local-time
// strings; we parse them into wall-clock NSDates.
@interface LFWeatherDay : NSObject
@property (nonatomic, copy)   NSDate   *date;
@property (nonatomic, assign) double    tempMin;     // in requested unit
@property (nonatomic, assign) double    tempMax;
@property (nonatomic, assign) NSInteger weatherCode; // WMO code
@end

@interface LFWeatherSnapshot : NSObject
// Most recent CURRENT observation.
@property (nonatomic, assign) double    currentTemp;        // in requested unit
@property (nonatomic, assign) double    currentHumidity;    // 0..100
@property (nonatomic, assign) NSInteger currentWeatherCode; // WMO code
@property (nonatomic, assign) BOOL      isDay;              // for choosing day vs night SF Symbol
// 5-day strip, including today as element 0.
@property (nonatomic, copy)   NSArray<LFWeatherDay *> *forecast;
// When the snapshot was fetched. Used by callers to decide whether
// to display "—" while a refresh is in flight.
@property (nonatomic, copy)   NSDate   *fetchedAt;
@end

typedef NS_ENUM(NSInteger, LFTempUnit) {
    LFTempUnitCelsius     = 0,
    LFTempUnitFahrenheit  = 1,
};

@interface LFOpenMeteoClient : NSObject

+ (instancetype)shared;

// Last cached snapshot, even if stale. Returned synchronously, so
// widgets can paint SOMETHING immediately on wake. Returns nil if
// nothing has ever been cached on this device (cold start).
- (nullable LFWeatherSnapshot *)cachedSnapshot;

// Async refresh. Hits the network if cache is older than `ttl`
// (default 30 min). If `force` is YES, hits the network regardless.
// Completion is invoked on the main queue with the freshest available
// snapshot (cached one if network failed). Pass nil completion if you
// just want to seed the cache without acting on the result.
//
// Coordinates come from LFLocationService. If we don't have a fix
// yet the call returns the cached snapshot (or nil) without a
// network attempt -- the location service will trigger a refresh
// once a fix arrives.
- (void)refreshIfStaleWithUnit:(LFTempUnit)unit
                         force:(BOOL)force
                    completion:(void (^_Nullable)(LFWeatherSnapshot *_Nullable snapshot,
                                                   NSError *_Nullable error))completion;

// Maps a WMO weather code (0-99 standardized values from Open-Meteo)
// to a representative SF Symbol name. iOS 13+ ships matching symbols
// for the common conditions; less-common codes fall back to a
// reasonable nearby symbol (e.g. dust/sand both map to haze).
// `isDay` selects between sun/moon variants for clear skies.
+ (NSString *)sfSymbolForWMOCode:(NSInteger)code isDay:(BOOL)isDay;

// English condition name, again for the inline widget where text is
// nicer than an SF Symbol alone.
+ (NSString *)conditionNameForWMOCode:(NSInteger)code;

@end

NS_ASSUME_NONNULL_END
