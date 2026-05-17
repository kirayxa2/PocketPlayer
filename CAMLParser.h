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
//
// Not supported (gracefully ignored):
//   - <modules>, animations, filters, text layers, gradient layers
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

NS_ASSUME_NONNULL_END
