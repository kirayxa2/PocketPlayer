// LFWidgetBattery - "Battery" widget. Reads UIDevice.batteryLevel +
// batteryState (charging glyph). Two families:
//
//   Circular   : small ring with % in the centre, ring colour shifts
//                green->yellow->red as level drops, blue when charging.
//   Rectangular: bigger ring on the left, "Battery 85%" multi-line
//                stack on the right, charging bolt overlay.

#import "LFLockScreenWidget.h"

NS_ASSUME_NONNULL_BEGIN

@interface LFWidgetBattery : LFLockScreenWidget
@end

NS_ASSUME_NONNULL_END
