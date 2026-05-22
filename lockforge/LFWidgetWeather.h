// LFWidgetWeather - "Conditions" widget. Pulls Open-Meteo cached
// snapshot. No API key required. Three families:
//
//   Circular   : SF Symbol weather glyph stacked over the current
//                temperature ("72°"). Uses day-vs-night symbol variant.
//   Rectangular: glyph on the left, big temp + condition name + 3-day
//                forecast strip (today / tomorrow / day-after).
//   (LFWidgetKindWeatherForecast routes to this same class with
//    family=Rectangular and a config flag asking for forecast layout.)

#import "LFLockScreenWidget.h"

NS_ASSUME_NONNULL_BEGIN

@interface LFWidgetWeather : LFLockScreenWidget
@end

NS_ASSUME_NONNULL_END
