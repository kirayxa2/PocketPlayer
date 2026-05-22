// LFWidgetSteps - "Steps" widget. Reads CMPedometer for the today
// step count, draws a green progress ring against a 10K goal with
// the live count in the centre.
//
// CMPedometer doesn't require permission for SAME-PROCESS reads on
// iOS 15 (only HealthKit does), but reading from "today" requires
// queryPedometerDataFromDate which is async; we cache the value
// between refreshes so the UI doesn't flash blank between fetches.

#import "LFLockScreenWidget.h"

NS_ASSUME_NONNULL_BEGIN

@interface LFWidgetSteps : LFLockScreenWidget
@end

NS_ASSUME_NONNULL_END
