// LFWidgetMusic - "Now Playing" widget. Reads MPNowPlayingInfoCenter
// for the system-wide currently-playing song. Two families:
//
//   Circular   : album art, no text. If no art -> SF Symbol music note
//                with a faint "playing" indicator dot when something
//                is in fact playing.
//   Rectangular: album art on the left, title + artist labels on the
//                right (multi-line, truncated).

#import "LFLockScreenWidget.h"

NS_ASSUME_NONNULL_BEGIN

@interface LFWidgetMusic : LFLockScreenWidget
@end

NS_ASSUME_NONNULL_END
