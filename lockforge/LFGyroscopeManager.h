// LFGyroscopeManager - global motion source for shimmer + parallax.
//
// Why centralized: each consumer (LiquidGlassView, multi-layer wallpaper
// parallax) wants the same tilt vector. Running multiple CMMotionManager
// instances inside SpringBoard wastes battery; one manager broadcasts to
// all subscribers.
//
// Output: clamped (-1, +1) on each axis, smoothed with low-pass filter
// so single-frame jitter doesn't translate into visible jitter on screen.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^LFGyroBlock)(CGPoint normalizedTilt);

@interface LFGyroscopeManager : NSObject

+ (instancetype)shared;

// Begin/stop the underlying CMMotionManager. The shared instance starts
// suspended; first subscriber resumes it, last unsubscriber pauses it.
- (void)addSubscriber:(id)key block:(LFGyroBlock)block;
- (void)removeSubscriber:(id)key;

// Whether motion updates are currently being delivered. Useful for
// cheap state checks without pulling motion data.
@property (nonatomic, readonly) BOOL active;

@end

NS_ASSUME_NONNULL_END
