// PPImportProgressViewController — modal "Wait please..." card shown
// during a multi-stage .tendies import. Stages run sequentially:
//
//   ✓  Importing
//   ◌  Resizing
//   –  Done
//
// The caller drives the controller forward by calling -beginStage: /
// -finishCurrentStage one stage at a time. The view animates each
// transition (placeholder dash -> spinner -> checkmark).

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, PPImportStage) {
    PPImportStageImporting = 0,
    PPImportStageResizing  = 1,
    PPImportStageDone      = 2,
};

@interface PPImportProgressViewController : UIViewController

// All three labels start as "–" except the first which becomes a
// running spinner immediately on viewDidLoad.
- (instancetype)init;

// Mark the current stage as finished (spinner -> ✓), advance to the
// next, and start its spinner. Calling this past PPImportStageDone is
// a no-op. Safe from any thread.
- (void)finishCurrentStage;

// Mark the import as failed at the current stage. The card auto-
// dismisses after a short delay; the alert is the caller's job.
- (void)failWithMessage:(nullable NSString *)message;

// Auto-dismiss timer fires when all 3 stages are complete.
@property (nonatomic, copy, nullable) void (^completion)(void);

@end

NS_ASSUME_NONNULL_END
