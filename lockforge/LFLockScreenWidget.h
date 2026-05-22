// LFLockScreenWidget - base class + types for iOS 16/26-style lock-
// screen widgets on iOS 15.
//
// Apple ships three widget families since iOS 16:
//
//   accessoryInline       single line of text + optional SF Symbol,
//                         drawn ABOVE the clock (where the date pill
//                         normally lives). On the lock screen you can
//                         only have ONE inline at a time.
//   accessoryCircular     76x76 round, drawn in a slot row BELOW
//                         the clock. Up to four per row.
//   accessoryRectangular  160x76 wider tile, drawn in the same slot
//                         row but takes the width of two circular
//                         slots side-by-side.
//
// Lock-screen widgets in iOS 15 ARE NOT a thing -- WidgetKit's
// accessory* families landed in iOS 16. So we cannot accept third-
// party widgets through the WidgetKit ABI. Instead LockForge ships
// its own widget engine: a fixed catalog of widget kinds we render
// ourselves using iOS 15 APIs (UIDevice for battery, MPNowPlayingInfo
// for music, EKEventStore for calendar, CMPedometer for steps, etc.).
//
// Each widget is a UIView subclass that:
//
//   * declares which families it can render (a circular battery vs a
//     rectangular Now Playing card use the same `kind`, different
//     `family`)
//   * pulls its own data on -refresh
//   * draws itself flat -- the surrounding LFLockScreenWidgetSlot
//     handles the rounded glass backdrop, the optional minus button
//     in edit mode, etc.
//
// Adding a new widget:
//   1. New LFWidget<Name>.h/m subclass implementing -refresh + -drawRect
//      (or pushing subview structure once in -initWithFamily:config:).
//   2. One line in LFLockScreenWidgetCatalog +allKinds returning the
//      new kind, plus one case in +createForKind:family:config:.
// That's it -- the picker, slot, tray, and persistence pick up the
// new widget automatically through the catalog.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Family = visual shape + sizing class. Apple's WidgetFamily on iOS 16
// uses three string constants, we use this enum so it round-trips
// cleanly through the .plist.
typedef NS_ENUM(NSInteger, LFWidgetFamily) {
    LFWidgetFamilyCircular     = 0,   // 76x76 round
    LFWidgetFamilyRectangular  = 1,   // 160x76 wide
    LFWidgetFamilyInline       = 2,   // full-width single-line, above clock
};

// All widget kinds the catalog knows. Numeric values are STABLE --
// stored in the plist, so don't reorder; only append new kinds at
// the end.
//
// Each kind may support multiple families (Battery exists as circular
// AND rectangular, Music exists as circular AND rectangular, etc.).
// Some kinds are inline-only (Date, DayCounter shown in the date pill).
typedef NS_ENUM(NSInteger, LFWidgetKind) {
    // Inline-only (drawn in the date pill above the clock):
    LFWidgetKindDate              =  0,   // "MONDAY, JUNE 23"
    LFWidgetKindDayCounter        =  1,   // "DAY 174 OF 365"
    LFWidgetKindCustomText        =  2,   // user-typed string

    // Cross-family (circular AND rectangular):
    LFWidgetKindBattery           = 10,
    LFWidgetKindWeather           = 11,   // current temp + condition icon
    LFWidgetKindMusic             = 12,   // MPNowPlayingInfo (artwork + title)
    LFWidgetKindCalendar          = 13,   // next event title + time

    // Circular-only:
    LFWidgetKindMoonPhase         = 20,   // computed from date, no API
    LFWidgetKindSteps             = 21,   // CMPedometer today
    LFWidgetKindWorldClock        = 22,   // configurable timezone
    LFWidgetKindReminders         = 23,   // count of due reminders today

    // Rectangular-only:
    LFWidgetKindWeatherForecast   = 30,   // 5-day strip
    LFWidgetKindNowPlayingDetail  = 31,   // bigger Music with artwork
    LFWidgetKindNextEvent         = 32,   // calendar event with title+time

    // Inline-only auxiliary (chosen via the date-pill picker too):
    LFWidgetKindWeatherInline     = 40,   // "72° SUNNY"
    LFWidgetKindBatteryInline     = 41,   // "BATTERY 85%" / "CHARGING 85%"
    LFWidgetKindCalendarInline    = 42,   // "MEETING 3:00 PM"
    LFWidgetKindRemindersInline   = 43,   // "PICK UP MILK"
    LFWidgetKindStocksInline      = 44,   // single ticker, requires API key
    LFWidgetKindActivityInline    = 45,   // Apple Watch activity rings %
    LFWidgetKindAppleTVInline     = 46,   // playing on TV (placeholder on iOS 15)
    LFWidgetKindSportsInline      = 47,   // game score / kickoff time
};

// Catalog metadata for a kind, used by the picker UI.
@interface LFLockScreenWidgetDescriptor : NSObject
@property (nonatomic, assign) LFWidgetKind   kind;
@property (nonatomic, copy)   NSString      *appName;     // "Battery", "Weather"
@property (nonatomic, copy)   NSString      *displayName; // "Battery"
@property (nonatomic, copy)   NSString      *sfSymbolName;// SF Symbol name for the picker preview icon
@property (nonatomic, copy)   NSArray<NSNumber *> *supportedFamilies; // [@(LFWidgetFamilyCircular), ...]
@property (nonatomic, assign) BOOL          isSuggested;  // shown in Suggestions row at the top of the picker
@end

// Base class for all rendered widgets.
//
// Subclasses override:
//   * -setupSubviewsForFamily: -- one-shot subview build from family+config
//   * -refreshContent          -- pull data, mutate labels/images
//
// Lifecycle: created by +[LFLockScreenWidgetCatalog createWidgetForKind:family:config:],
// added to a LFLockScreenWidgetSlot, refresh-pulsed by the slot's
// timer (every 60s by default; widgets can override
// preferredRefreshInterval).
@interface LFLockScreenWidget : UIView

@property (nonatomic, readonly, assign) LFWidgetKind   kind;
@property (nonatomic, readonly, assign) LFWidgetFamily family;
// Free-form per-widget params (e.g. WorldClock timezone, CustomText
// string). Round-trips through plist. NSDictionary of plist-safe
// types.
@property (nonatomic, readonly, copy)   NSDictionary  *config;

// Designated initializer. Subclasses MUST call this from their own
// inits, then build subviews in -setupSubviewsForFamily:.
- (instancetype)initWithKind:(LFWidgetKind)kind
                      family:(LFWidgetFamily)family
                      config:(nullable NSDictionary *)config;

// Refresh interval the slot's timer should hit this widget at.
// Default 60s. Subclasses with faster-changing data (Music, Battery)
// can override.
- (NSTimeInterval)preferredRefreshInterval;

// Pull fresh data, update subviews. Called immediately after init,
// then on the slot's refresh tick. Default impl is a no-op.
- (void)refreshContent;

// Family-aware natural size. Slot uses this to lay the widget out;
// widgets normally just return the catalog's standard sizes for
// their family but can override (e.g. inline auto-sizes by text).
+ (CGSize)naturalSizeForFamily:(LFWidgetFamily)family;

// === Helpers for subclasses, implemented in the base ===

// Drop-in white-on-translucent-glass backdrop that subclasses should
// add as their first subview if they want the iOS 26 chrome look
// (battery ring, music tile, etc.). Returns the backdrop view; the
// subclass owns subview ordering on top of it.
//
// On circular family the backdrop is a full-bleed UIVisualEffectView
// with cornerRadius=size/2; on rectangular it's the same view with
// rounded corners ~22pt; on inline it's not added (inline widgets
// blend into the date pill).
- (UIVisualEffectView *)installGlassBackdrop;

// Standard text styling used across most widgets so they read as a
// coherent set: SF Pro semibold, white-95, tabular figures so digits
// don't reflow when the value changes. `size` is in points.
+ (UIFont *)systemFontOfSize:(CGFloat)size weight:(UIFontWeight)w;

@end

NS_ASSUME_NONNULL_END
