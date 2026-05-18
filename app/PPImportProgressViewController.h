// PPImportProgressViewController — modal "Wait please..." card shown
// during a multi-stage .tendies import. Stages run sequentially:
//
//   ✓  Downloading   (only when source is online; suppressed for local imports)
//   ✓  Importing
//   ◌  Resizing
//   –  Done   + [Apply now] button after success
//
// The caller drives the controller forward by calling -finishCurrentStage
// one stage at a time. The view animates each transition (placeholder
// dash -> spinner -> checkmark).
//
// When the final stage completes, an "Apply now" button is revealed on
// the card so the user can apply the wallpaper without bouncing through
// the gallery + detail screen first. The applyHandler block is invoked
// when they tap it.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface PPImportProgressViewController : UIViewController

// Construct with an explicit list of stage titles. Order matters --
// the first stage starts spinning at viewDidLoad and -finishCurrentStage
// advances to the next one.
//
// Typical sequences:
//   Local import:  @[@"Importing", @"Resizing", @"Done"]
//   Online import: @[@"Downloading", @"Importing", @"Resizing", @"Done"]
- (instancetype)initWithStageTitles:(NSArray<NSString *> *)stageTitles;

// Default: 3-stage local import (Importing / Resizing / Done).
- (instancetype)init;

// Update the spinner-row's label without advancing -- useful when one
// stage has sub-progress (e.g. download percentage).
- (void)updateCurrentStageDetail:(nullable NSString *)detail;

// Mark the current stage as finished (spinner -> ✓), advance to the
// next, and start its spinner. Calling this past the last stage is a
// no-op (the card stays open until the user taps Apply or Close).
// Safe from any thread.
- (void)finishCurrentStage;

// Mark the import as failed at the current stage. The card auto-
// dismisses after a short delay; the alert is the caller's job.
- (void)failWithMessage:(nullable NSString *)message;

// Tapped after success -- the caller should run the apply path and
// then dismiss the card via -dismissAfterApplying.
@property (nonatomic, copy, nullable) void (^applyHandler)(void);

// Optional: tapped when the user closes the card without applying.
@property (nonatomic, copy, nullable) void (^closeHandler)(void);

// Auto-fired (besides applyHandler) when all stages are done so the
// caller can refresh its UI. Not the same as applyHandler -- this
// fires on stage transition, applyHandler fires on button tap.
@property (nonatomic, copy, nullable) void (^completion)(void);

// Called by the caller after the apply path finishes; closes the card.
- (void)dismissAfterApplying;

@end

NS_ASSUME_NONNULL_END
