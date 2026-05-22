// LFLocationService - location resolution for weather widgets.
//
// Two paths, used in priority order:
//   1) CoreLocation on the SpringBoard process. We're a tweak loaded
//      into SpringBoard, so we can attempt CLLocationManager.
//      SpringBoard already has location entitlements for system
//      services, but the per-process authorization status may still
//      be "not determined" or "denied". If denied -> fall back.
//   2) IP-based geolocation through https://ipapi.co/json/. Free,
//      no key, returns lat/lon JSON. Approximate (city-level) but
//      good enough for "weather widget on a phone that doesn't move
//      much in 30 minutes" -- which is exactly what we need.
//
// Coordinate is cached on disk so cold-start widgets paint immediately
// using the last-known location (and refresh in the background once
// CL fires or IP-geo returns).

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct {
    double latitude;
    double longitude;
    BOOL   valid;        // NO if no fix has ever been obtained.
} LFLocationCoordinate;

@interface LFLocationService : NSObject

+ (instancetype)shared;

// Last known (cached, possibly disk-loaded) coordinate. Synchronous,
// safe to call on every paint.
- (LFLocationCoordinate)currentCoordinate;

// Trigger a refresh attempt: ask CoreLocation first, and if that's
// denied or stays silent for 5 seconds, hit ipapi.co. Updates the
// disk cache and posts a notification on success. No-op if a request
// is already in flight.
- (void)requestFixIfNeeded;

// Notification name. Posted on the main queue when a new coordinate
// is available. Weather widgets observe and re-fetch.
extern NSNotificationName const LFLocationDidUpdateNotification;

@end

NS_ASSUME_NONNULL_END
