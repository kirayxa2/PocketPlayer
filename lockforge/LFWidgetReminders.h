// LFWidgetReminders - count of incomplete reminders due today (or now
// overdue). Same EventKit access dance as LFWidgetCalendar, but for
// EKEntityTypeReminder. Circular only -- the rectangular slot would
// just be a less-readable version of the same data.

#import "LFLockScreenWidget.h"

NS_ASSUME_NONNULL_BEGIN

@interface LFWidgetReminders : LFLockScreenWidget
@end

NS_ASSUME_NONNULL_END
