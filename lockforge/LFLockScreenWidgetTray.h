// LFLockScreenWidgetTray - the iOS 16/26 widget area.
//
// Holds a bounded number of "units" of widgets. iOS Apple capacity
// model: 4 units total. Circular = 1 unit, Rectangular = 2 units.
// Inline widgets DON'T live in the tray (they live in the date pill
// above the clock).
//
// Layout is auto-flow horizontal:
//   [O] [O] [O] [O]      <- 4 circular
//   [   ] [   ]          <- 2 rectangular
//   [   ] [O] [O]        <- 1 rect + 2 circular
//
// Edit-mode chrome:
//   * Tap an empty trailing slot -> picker opens
//   * Tap a filled slot's minus button -> remove
//   * Long-press anywhere on the tray -> drag whole tray vertically
//     to change LFTrayPosition (under-clock <-> at-bottom)
//
// Edit-mode SELECTION RECTANGLE: when isEditing=YES the tray draws a
// hairline rounded-rect chrome around its full extent -- same look as
// the chrome around the clock and date pill -- so the user can see
// the widget area's bounds while customizing. The chrome's WIDTH is
// driven by the editor (set via -setSelectionWidth: to match the
// clock-box width) and its HEIGHT is the natural widget height (76pt).

#import <UIKit/UIKit.h>
#import "LFLockScreenWidget.h"

NS_ASSUME_NONNULL_BEGIN

@class LFLockScreenWidgetTray;

@protocol LFLockScreenWidgetTrayDelegate <NSObject>
// Tray asks the editor to present the picker for a given family. The
// editor calls -addWidget:family:config: on the tray when the user
// confirms a choice.
- (void)trayDidRequestPicker:(LFLockScreenWidgetTray *)tray
                       family:(LFWidgetFamily)family;
- (void)trayDidUpdateContents:(LFLockScreenWidgetTray *)tray;

// User dropped the tray after the bottom-drag pan; editor decides
// whether to snap into LFTrayPositionAtBottom or back to under-clock.
- (void)tray:(LFLockScreenWidgetTray *)tray didDragWithTranslationY:(CGFloat)dy
            ended:(BOOL)ended;
@end

@interface LFLockScreenWidgetTray : UIView

@property (nonatomic, weak) id<LFLockScreenWidgetTrayDelegate> delegate;

// When YES, slots show chrome (minus button on filled, plus on empty)
// and pan/long-press drag is enabled. Set by the editor.
@property (nonatomic, assign) BOOL isEditing;

// Mirrors the editor's bottom customize-panel visibility state.
// iOS 26 only reveals the per-tile minus button while that panel
// is up -- the tray broadcasts the flag down to each slot.
@property (nonatomic, assign) BOOL bottomPanelOpen;

// True while the user's finger is dragging the tray vertically.
// The clock overlay reads this in -repositionWidgetTray and skips
// re-positioning so the drag isn't fought by the live layout pass.
@property (nonatomic, assign, readonly) BOOL isUserDragging;

// Width of the edit-mode selection-rectangle chrome. Editor sets this
// to match the clock-box width so the three chrome rectangles (clock,
// date pill, widget tray) align as a column. If 0 the chrome falls
// back to the natural widget content width.
@property (nonatomic, assign) CGFloat selectionWidth;

// Total natural width / height after layout. Caller positions the
// tray and reads .intrinsicContentSize to get the right rect.
@property (nonatomic, assign, readonly) CGSize naturalSize;

// Capacity used (sum of slot units). 0..4.
@property (nonatomic, assign, readonly) NSInteger usedUnits;

// Re-build the tray layout from a settings-style array of slot
// dictionaries. Each dict is { kind: int, family: int, config: dict }.
- (void)reloadFromSlotDictionaries:(NSArray<NSDictionary *> *)slots;

// Add a widget at the trailing position. Returns NO if there isn't
// room for it (e.g. trying to add a rectangular when 3 units are used).
- (BOOL)addWidgetWithKind:(LFWidgetKind)kind
                    family:(LFWidgetFamily)family
                    config:(nullable NSDictionary *)config;

// Remove the widget at index `idx`. Subsequent slots shift left.
- (void)removeWidgetAtIndex:(NSInteger)idx;

// Snapshot the tray into the array-of-dicts shape that
// LFClockSettings.traySlots expects.
- (NSArray<NSDictionary *> *)serializedSlots;

@end

NS_ASSUME_NONNULL_END
