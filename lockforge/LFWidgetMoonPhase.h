// LFWidgetMoonPhase - "Moon Phase" widget. Pure math from the date,
// no API. Uses the canonical 29.530588853-day synodic month with a
// known new-moon epoch (2000-01-06 18:14 UT) to compute the phase
// fraction, then maps it to one of 8 standard phase names + a hand-
// drawn moon shape (no SF Symbol -- iOS 15 has only "moon.fill" not
// the phase variants).

#import "LFLockScreenWidget.h"

NS_ASSUME_NONNULL_BEGIN

@interface LFWidgetMoonPhase : LFLockScreenWidget
@end

NS_ASSUME_NONNULL_END
