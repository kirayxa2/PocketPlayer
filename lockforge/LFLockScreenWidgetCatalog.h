// LFLockScreenWidgetCatalog - registry of all widgets LockForge knows.
//
// Single point that:
//   * Vends descriptors for the picker UI (display name, icon,
//     supported families, "is suggested for the top row").
//   * Constructs concrete LFLockScreenWidget subclasses given a
//     (kind, family) tuple plus the per-widget config dictionary.
//   * Knows the human-readable "app name" for grouping in the picker
//     (e.g. Battery + BatteryInline both belong to app "Battery").
//
// Adding a new widget kind:
//   1. Drop a new LFWidget<Name>.{h,m} into the lockforge folder
//   2. List its kind in +allDescriptors with the right metadata
//   3. Add a case in +createWidgetForKind:family:config: that calls
//      [[LFWidget<Name> alloc] initWithKind:family:config:]
// Picker, slot, tray pick it up automatically.

#import "LFLockScreenWidget.h"

NS_ASSUME_NONNULL_BEGIN

@interface LFLockScreenWidgetCatalog : NSObject

// Every kind LockForge ships, with metadata. Order in this array is
// the order the picker UI shows them in the all-apps list (after the
// Suggestions row). Keeping data-side here means picker code is dead
// simple; it just iterates.
+ (NSArray<LFLockScreenWidgetDescriptor *> *)allDescriptors;

// Subset where descriptor.isSuggested == YES, in order. Picker shows
// them in the "SUGGESTIONS" row at the top of the sheet.
+ (NSArray<LFLockScreenWidgetDescriptor *> *)suggestedDescriptors;

// Look up the descriptor for a kind. Returns nil if the kind isn't
// known (e.g. the plist comes from a build that introduces new
// kinds and the user reverts to a tweak that doesn't ship them).
+ (nullable LFLockScreenWidgetDescriptor *)descriptorForKind:(LFWidgetKind)kind;

// Pretty group name for the picker's expandable per-app rows.
+ (NSString *)appGroupNameForKind:(LFWidgetKind)kind;

// Construct a live widget instance ready to be added to a slot.
// Returns nil if the (kind, family) combination isn't supported (e.g.
// asking for an inline-only kind with rectangular family) or if the
// kind isn't known.
+ (nullable LFLockScreenWidget *)createWidgetForKind:(LFWidgetKind)kind
                                              family:(LFWidgetFamily)family
                                              config:(nullable NSDictionary *)config;

// Picker preview rendering: small circular icon + name. Caller draws
// the surrounding cell, just hands us the bounds.
+ (UIImage *)previewImageForDescriptor:(LFLockScreenWidgetDescriptor *)d
                                  size:(CGSize)size
                                family:(LFWidgetFamily)family;

@end

NS_ASSUME_NONNULL_END
