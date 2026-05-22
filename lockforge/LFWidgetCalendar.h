// LFWidgetCalendar - "Up Next" widget. Reads EKEventStore for the
// next upcoming event in the user's calendars. Two families:
//
//   Circular   : compact "Today: 3 events" or "12:30 PM" if there's
//                an imminent event in the next hour.
//   Rectangular: full title + start/end time + colour dot for the
//                calendar.
//
// EventKit on iOS 15 requires the user grant calendar permission via
// UIAlertController prompt. We ask exactly once per device on first
// add of the widget; if the user denies we show a placeholder
// "Calendar access disabled" string and never re-prompt (Apple
// guidance: don't badger users).

#import "LFLockScreenWidget.h"

NS_ASSUME_NONNULL_BEGIN

@interface LFWidgetCalendar : LFLockScreenWidget
@end

NS_ASSUME_NONNULL_END
