// CAMLParser.h
// Minimal Core Animation ML (.caml) parser for iOS 15.
// Apple's private CAMLParser is unavailable on iOS 15 user-mode, so we roll our own.
//
// Supports:
//   - <CALayer> tree with id / name / bounds / position / transform / backgroundColor /
//     opacity / anchorPoint / cornerRadius / hidden / contentsGravity
//   - <CGImage src="assets/foo.png"/> contents
//   - <states> with <LKState name="..."> containing <LKStateSetValue targetId keyPath><value/>
//   - <stateTransitions> with per-(from,to) durations (basic)
//   - <animations> blocks with <animation type="CAKeyframeAnimation"/CABasicAnimation"/...>
//     attached natively via CALayer.addAnimation:forKey: so Apple's own animator
//     handles repeat/autoreverse/timing without per-frame work from us.
//
// Not supported (gracefully ignored):
//   - <modules>, text layers, gradient layers
//   - CAEmitterLayer (parsed as plain CALayer; particles don't spawn)
//   - <filters> / CAFilter (private API; ignored)
//
// Usage:
//   PPCAMLDocument *doc = [PPCAMLParser parseCAMLAtPath:camlPath assetsPath:assetsPath];
//   doc.rootLayer  -> CALayer tree, ready to add as sublayer
//   [doc applyState:@"Locked" progress:0.0];
//   [doc applyState:@"Unlocked" progress:swipeProgress]; // interpolated 0..1

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

@interface PPCAMLStateValue : NSObject
@property (nonatomic, copy)   NSString *targetId;
@property (nonatomic, copy)   NSString *keyPath;
@property (nonatomic, strong) id value;       // NSNumber for scalars, NSValue for CGPoint/CGSize, UIColor for color
@end

@interface PPCAMLState : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) NSArray<PPCAMLStateValue *> *values;
@end

@interface PPCAMLDocument : NSObject

@property (nonatomic, strong, readonly) CALayer *rootLayer;
@property (nonatomic, strong, readonly) NSDictionary<NSString *, CALayer *> *layersById;
@property (nonatomic, strong, readonly) NSDictionary<NSString *, PPCAMLState *> *states;
// Names of states in the order they were declared in the .caml file.
@property (nonatomic, strong, readonly) NSArray<NSString *> *stateOrder;

// Diagnostics — parser fills these in so callers can show
// "imgs=N missing=N emitters=N cells=N" in a debug label.
@property (nonatomic, assign) NSInteger imagesLoaded;
@property (nonatomic, assign) NSInteger imagesMissing;
@property (nonatomic, assign) NSInteger emittersBuilt;
@property (nonatomic, assign) NSInteger cellsBuilt;

// Snapshot the "base" values (initial) so we can interpolate from them.
- (void)captureBaseValues;

// Apply a single state instantly (progress = 1).
- (void)applyState:(NSString *)stateName;

// Interpolate base -> stateName by progress in [0..1].
- (void)applyState:(NSString *)stateName progress:(CGFloat)progress;

// Interpolate fromState -> toState by progress in [0..1].
- (void)applyTransitionFromState:(NSString *)fromState
                         toState:(NSString *)toState
                        progress:(CGFloat)progress;

@end

@interface PPCAMLParser : NSObject
+ (nullable PPCAMLDocument *)parseCAMLAtPath:(NSString *)camlPath
                                  assetsPath:(NSString *)assetsPath;
@end

// Debug helpers, used by Tweak.x to visualise where emitters
// physically end up on screen.
@interface CALayer (PPDebug)
// Recursively walk the layer tree starting at `self` and return all
// CAEmitterLayers found under it (including self).
- (NSArray<CAEmitterLayer *> *)pp_collectEmitters;
@end

NS_ASSUME_NONNULL_END
