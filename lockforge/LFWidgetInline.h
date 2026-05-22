// LFWidgetInline - shared renderer for ALL inline single-line
// widgets (the kinds that live in the date-pill area above the
// clock).
//
// Inline widgets are conceptually just a string + optional SF
// Symbol icon. We expose:
//   * A UIView subclass that renders one inline widget into its
//     bounds (used when the picker wants a thumbnail).
//   * +resolvedTextForKind:config: -- returns the string a given
//     inline kind would render right now. LFClockOverlay's date
//     pill uses this directly so we don't have to mount yet
//     another UIView subtree inside the pill.

#import "LFLockScreenWidget.h"

NS_ASSUME_NONNULL_BEGIN

@interface LFWidgetInline : LFLockScreenWidget

// Resolve the live string the inline widget would display right
// now. Pure function -- no side effects, safe to call on every
// minute tick. Returns "" if the kind isn't an inline kind or its
// data source isn't available (no calendar permission, etc.).
+ (NSString *)resolvedTextForKind:(LFWidgetKind)kind
                            config:(nullable NSDictionary *)config;

// SF Symbol that goes to the LEFT of the inline text on lock
// screen, or nil for kinds that don't carry an icon (Date / Day
// Counter / Custom Text / etc).
+ (nullable NSString *)sfSymbolForKind:(LFWidgetKind)kind;

@end

NS_ASSUME_NONNULL_END
