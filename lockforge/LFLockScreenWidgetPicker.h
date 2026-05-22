// LFLockScreenWidgetPicker - modal sheet UI for selecting a widget,
// closely mirroring iOS 26's "Add Widgets" sheet:
//
//   ┌────────────────────────────────┐
//   │ ✕                              │
//   │                                │
//   │  ADD WIDGETS                   │  <- big title
//   │                                │
//   │   SUGGESTIONS                  │  <- horizontal scroll row
//   │   ┌────┐ ┌────┐ ┌────┐ ┌────┐  │
//   │   │ Bat│ │Wthr│ │Cal │ │Mus │  │
//   │   └────┘ └────┘ └────┘ └────┘  │
//   │                                │
//   │   ▾ Battery        (cell row)  │  <- expandable per-app rows
//   │   ▾ Calendar                   │
//   │   ▾ Weather                    │
//   │   ▾ Music                      │
//   │   ▾ Astronomy                  │
//   │   ▾ ...                        │
//   └────────────────────────────────┘
//
// Family is fixed by the caller (the slot type the user tapped); the
// picker only shows kinds whose descriptor.supportedFamilies contains
// that family. The completion fires once with the chosen kind+config
// (or nil if the user cancelled).
//
// Per-widget config: most widgets need none. WorldClock needs a
// timezone, CustomText needs a string. We collect those after the
// kind selection via a lightweight follow-up sheet (alert with text
// field, or timezone list); the picker hides this from its caller.

#import <UIKit/UIKit.h>
#import "LFLockScreenWidget.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (^LFPickerCompletion)(LFWidgetKind kind,
                                    LFWidgetFamily family,
                                    NSDictionary *_Nullable config);

@interface LFLockScreenWidgetPicker : UIViewController

// `family` may be a single value (filling a known empty slot) or
// LFWidgetFamilyCircular (default fallback) when called with no
// preferred family. The picker filters its catalog by what fits.
- (instancetype)initForFamily:(LFWidgetFamily)family
                   completion:(LFPickerCompletion)completion;

// Convenience wrapper: present from a host view controller, animated.
- (void)presentFromViewController:(UIViewController *)host;

@end

NS_ASSUME_NONNULL_END
