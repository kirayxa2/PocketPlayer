// LFLockScreenWidgetSlot - one rectangular cell in the widget tray.
// Holds a single LFLockScreenWidget and decorates it with edit-mode
// chrome (minus button to remove, dashed border for empty slots,
// rounded translucent backdrop).
//
// Slot has a fixed family at creation time -- empty circular slot
// vs empty rectangular slot are visually different sizes and the
// picker offers different content for each.

#import <UIKit/UIKit.h>
#import "LFLockScreenWidget.h"

NS_ASSUME_NONNULL_BEGIN

@class LFLockScreenWidgetSlot;

@protocol LFLockScreenWidgetSlotDelegate <NSObject>
- (void)slotDidTapAdd:(LFLockScreenWidgetSlot *)slot;
- (void)slotDidTapRemove:(LFLockScreenWidgetSlot *)slot;
@end

@interface LFLockScreenWidgetSlot : UIView
@property (nonatomic, assign, readonly) LFWidgetFamily family;
@property (nonatomic, weak) id<LFLockScreenWidgetSlotDelegate> delegate;

// Whether the surrounding tray is in edit mode (shows chrome).
@property (nonatomic, assign) BOOL isEditing;

// Whether the editor's bottom customize-panel is currently open.
// In iOS 26 the per-tile minus button is REVEALED only while the
// bottom-customize sheet is up -- when the sheet is dismissed, the
// minus button hides so the user sees a clean edit-mode preview.
// The tray propagates its own bottomPanelOpen flag down to each
// slot so the visual state matches Apple.
@property (nonatomic, assign) BOOL bottomPanelOpen;

// The currently-installed widget, if any. Setting nil clears the
// slot back to "empty + plus glyph".
@property (nonatomic, strong, nullable) LFLockScreenWidget *widget;

- (instancetype)initWithFamily:(LFWidgetFamily)family;

@end

NS_ASSUME_NONNULL_END
