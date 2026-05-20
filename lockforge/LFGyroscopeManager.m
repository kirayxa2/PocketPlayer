#import "LFGyroscopeManager.h"
#import <CoreMotion/CoreMotion.h>

@interface LFGyroscopeManager ()
@property (nonatomic, strong) CMMotionManager                       *motion;
@property (nonatomic, strong) NSMapTable<id, LFGyroBlock>           *subscribers;
@property (nonatomic, strong) NSOperationQueue                       *queue;
@property (nonatomic, assign) BOOL                                   active;
// Smoothed tilt; integrated each frame to remove high-frequency noise.
@property (nonatomic, assign) CGPoint                                smoothed;
@end

@implementation LFGyroscopeManager

+ (instancetype)shared {
    static LFGyroscopeManager *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [LFGyroscopeManager new]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _motion             = [CMMotionManager new];
    _motion.deviceMotionUpdateInterval = 1.0 / 30.0;   // 30 Hz is plenty
    // Weak-key map so dealloc'd subscribers auto-leave without explicit
    // unsubscribe. Useful when a consumer's parent UIView gets removed
    // and we don't get a clean shutdown call.
    _subscribers        = [NSMapTable weakToStrongObjectsMapTable];
    _queue              = [NSOperationQueue new];
    _queue.maxConcurrentOperationCount = 1;
    _smoothed           = CGPointZero;
    return self;
}

- (void)addSubscriber:(id)key block:(LFGyroBlock)block {
    if (!key || !block) return;
    [_subscribers setObject:[block copy] forKey:key];
    [self resumeIfNeeded];
}

- (void)removeSubscriber:(id)key {
    if (!key) return;
    [_subscribers removeObjectForKey:key];
    if (_subscribers.count == 0) {
        [self pause];
    }
}

- (void)resumeIfNeeded {
    if (_active) return;
    if (![_motion isDeviceMotionAvailable]) return;

    __weak __typeof(self) weakSelf = self;
    [_motion startDeviceMotionUpdatesToQueue:_queue
                                 withHandler:^(CMDeviceMotion *m, NSError *e) {
        __strong __typeof(weakSelf) self_ = weakSelf;
        if (!self_ || !m) return;

        // Pitch/roll are radians, range roughly +/- pi for vertical
        // edge cases. We're interested in the "natural hold" range
        // ~+/- 0.6 rad; clamp + normalize to [-1, +1].
        CGFloat px = MAX(-1.0, MIN(1.0, m.attitude.roll  / 0.6));
        CGFloat py = MAX(-1.0, MIN(1.0, m.attitude.pitch / 0.6));

        // Low-pass: 80% old + 20% new. Removes single-frame spikes
        // (subway, hand tremor) without making motion feel laggy.
        CGPoint prev = self_.smoothed;
        CGPoint next = CGPointMake(prev.x * 0.8 + px * 0.2,
                                   prev.y * 0.8 + py * 0.2);
        self_.smoothed = next;

        dispatch_async(dispatch_get_main_queue(), ^{
            for (id key in [self_.subscribers keyEnumerator]) {
                LFGyroBlock b = [self_.subscribers objectForKey:key];
                if (b) b(next);
            }
        });
    }];
    _active = YES;
}

- (void)pause {
    if (!_active) return;
    [_motion stopDeviceMotionUpdates];
    _active = NO;
}

@end
