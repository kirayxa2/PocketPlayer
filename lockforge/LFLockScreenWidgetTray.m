#import "LFLockScreenWidgetTray.h"
#import "LFLockScreenWidgetSlot.h"
#import "LFLockScreenWidgetCatalog.h"

static const CGFloat kLFTrayGap = 8.0;
static const CGFloat kLFTrayMaxUnits = 4;

// Tag for the trailing-empty plus-slot when the tray HAS at least one
// real widget but still has units free. (When the tray is fully empty
// we use a single big "Add Widgets" empty-state instead, see below.)
static const NSInteger kLFTagTrailingEmptySlot = 0xEEFA;
// Tag for the empty-state container shown when the tray has zero
// widgets in editing mode (big circular plus + "Add Widgets" label).
static const NSInteger kLFTagEmptyStateContainer = 0xEEFB;

@interface LFLockScreenWidgetTray () <LFLockScreenWidgetSlotDelegate> {
    NSMutableArray<LFLockScreenWidgetSlot *> *_slots;
    UIPanGestureRecognizer *_dragPan;

    // Edit-mode chrome -- a hairline rounded-rect that mirrors the
    // selection rectangle drawn around the clock and date pill in
    // edit mode. Driven by .selectionWidth + intrinsic height.
    UIView *_chromeBorder;

    // Drag state for live-follow tray drag (iOS 26 lets the user
    // drag the whole tray vertically; we move the frame in real-
    // time so the tray "sticks to the finger" rather than jumping
    // discretely between two snap points on release).
    CGFloat _dragStartFrameY;
}
@property (nonatomic, assign, readwrite) BOOL isUserDragging;
@end

@implementation LFLockScreenWidgetTray

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = [UIColor clearColor];
    _slots = [NSMutableArray array];

    // Edit-mode chrome border -- same look as the clock/date selection
    // rectangle: 1pt white at alpha 0.30, 28pt corner radius, hidden
    // when not editing. We draw it BELOW everything else so widget
    // content paints on top of it cleanly.
    _chromeBorder = [UIView new];
    _chromeBorder.userInteractionEnabled = NO;
    _chromeBorder.layer.borderColor      =
        [[UIColor colorWithWhite:1.0 alpha:0.30] CGColor];
    _chromeBorder.layer.borderWidth      = 1.0;
    _chromeBorder.layer.cornerRadius     = 28.0;
    _chromeBorder.hidden                 = YES;
    [self addSubview:_chromeBorder];

    _dragPan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(onDragPan:)];
    _dragPan.minimumNumberOfTouches = 1;
    _dragPan.maximumNumberOfTouches = 1;
    [self addGestureRecognizer:_dragPan];

    return self;
}

#pragma mark - Capacity bookkeeping

static NSInteger lf_unitsForFamily(LFWidgetFamily f) {
    return (f == LFWidgetFamilyRectangular) ? 2 : 1;
}

- (NSInteger)usedUnits {
    NSInteger u = 0;
    for (LFLockScreenWidgetSlot *s in _slots) {
        u += lf_unitsForFamily(s.family);
    }
    return u;
}

#pragma mark - Reload

- (void)reloadFromSlotDictionaries:(NSArray<NSDictionary *> *)slots {
    for (LFLockScreenWidgetSlot *s in _slots) [s removeFromSuperview];
    [_slots removeAllObjects];

    NSInteger units = 0;
    for (NSDictionary *e in slots) {
        LFWidgetKind   kind   = (LFWidgetKind)  [e[@"kind"]   integerValue];
        LFWidgetFamily family = (LFWidgetFamily)[e[@"family"] integerValue];
        NSDictionary  *cfg    = e[@"config"];
        if (![cfg isKindOfClass:[NSDictionary class]]) cfg = nil;
        if (units + lf_unitsForFamily(family) > kLFTrayMaxUnits) break;
        LFLockScreenWidget *w = [LFLockScreenWidgetCatalog
            createWidgetForKind:kind family:family config:cfg];
        if (!w) continue;
        LFLockScreenWidgetSlot *slot = [[LFLockScreenWidgetSlot alloc]
            initWithFamily:family];
        slot.delegate = self;
        slot.widget   = w;
        slot.isEditing = self.isEditing;
        [self addSubview:slot];
        [_slots addObject:slot];
        units += lf_unitsForFamily(family);
    }
    [self setNeedsLayout];
    [self.delegate trayDidUpdateContents:self];
}

#pragma mark - Add / remove

- (BOOL)addWidgetWithKind:(LFWidgetKind)kind
                    family:(LFWidgetFamily)family
                    config:(NSDictionary *)config {
    if (self.usedUnits + lf_unitsForFamily(family) > kLFTrayMaxUnits) {
        return NO;
    }
    LFLockScreenWidget *w = [LFLockScreenWidgetCatalog
        createWidgetForKind:kind family:family config:config];
    if (!w) return NO;
    LFLockScreenWidgetSlot *slot = [[LFLockScreenWidgetSlot alloc]
        initWithFamily:family];
    slot.delegate = self;
    slot.widget   = w;
    slot.isEditing = self.isEditing;
    [self addSubview:slot];
    [_slots addObject:slot];
    [self setNeedsLayout];
    [self.delegate trayDidUpdateContents:self];
    return YES;
}

- (void)removeWidgetAtIndex:(NSInteger)idx {
    if (idx < 0 || idx >= (NSInteger)_slots.count) return;
    LFLockScreenWidgetSlot *s = _slots[idx];
    [s removeFromSuperview];
    [_slots removeObjectAtIndex:idx];
    [self setNeedsLayout];
    [self.delegate trayDidUpdateContents:self];
}

- (NSArray<NSDictionary *> *)serializedSlots {
    NSMutableArray *out = [NSMutableArray array];
    for (LFLockScreenWidgetSlot *s in _slots) {
        if (!s.widget) continue;
        [out addObject:@{
            @"kind":   @(s.widget.kind),
            @"family": @(s.widget.family),
            @"config": s.widget.config ?: @{},
        }];
    }
    return out;
}

#pragma mark - Layout

- (CGSize)naturalSize {
    CGFloat w = 0, h = 0;
    for (LFLockScreenWidgetSlot *s in _slots) {
        CGSize sz = [LFLockScreenWidget naturalSizeForFamily:s.family];
        if (h < sz.height) h = sz.height;
        if (w > 0) w += kLFTrayGap;
        w += sz.width;
    }
    // Reserve space for ONE empty trailing slot ONLY when the tray
    // already has at least one widget -- the "tray is fully empty"
    // case is rendered as a single big "Add Widgets" panel that spans
    // the full chrome width and isn't represented in this measurement.
    if (_slots.count > 0 && self.usedUnits < kLFTrayMaxUnits) {
        CGSize empty = [LFLockScreenWidget naturalSizeForFamily:LFWidgetFamilyCircular];
        if (h < empty.height) h = empty.height;
        if (w > 0) w += kLFTrayGap;
        w += empty.width;
    }
    if (h < 76) h = 76;
    // Always report at least 1pt of width so the tray's superview
    // doesn't auto-hide an empty editing tray (the empty-state panel
    // covers the chrome border at full selectionWidth, but we still
    // need a non-zero natural width so the tray's visibility logic
    // upstream doesn't drop it).
    if (w < 1) w = 1;
    return CGSizeMake(w, h);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;

    // 1) Edit-mode chrome border. Width comes from selectionWidth (set
    //    by the editor to match the clock-box width) so the three
    //    chrome rectangles -- clock, date pill, widget tray -- align
    //    as a tidy column. Height is the natural widget height (76pt).
    if (self.isEditing) {
        CGFloat cw = (self.selectionWidth > 1.0)
            ? self.selectionWidth
            : MAX(self.naturalSize.width, b.size.width);
        CGFloat ch = MAX(self.naturalSize.height, 76);
        _chromeBorder.frame = CGRectMake((b.size.width - cw) / 2.0,
                                         (b.size.height - ch) / 2.0,
                                         cw, ch);
        _chromeBorder.hidden = NO;
    } else {
        _chromeBorder.hidden = YES;
    }

    // 2) Empty-state container -- big circular plus + "Add Widgets"
    //    label, only visible in edit mode when the tray has zero real
    //    widgets. This is what iOS 26 shows when no widgets are
    //    placed: a single full-width tap target instead of a series
    //    of mini empty-slot rectangles.
    UIView *empty = [self viewWithTag:kLFTagEmptyStateContainer];
    BOOL wantEmpty = (self.isEditing && _slots.count == 0);
    if (wantEmpty) {
        if (!empty) empty = [self lf_buildEmptyStateContainer];
        empty.hidden = NO;
        empty.frame  = _chromeBorder.frame;
        [self lf_layoutEmptyStateInternals:empty];
    } else {
        empty.hidden = YES;
    }

    // 3) Filled slots. Lay them out centered on the row.
    CGSize natural = self.naturalSize;
    CGFloat x = (b.size.width - natural.width) / 2.0;
    CGFloat y = (b.size.height - natural.height) / 2.0;
    for (LFLockScreenWidgetSlot *s in _slots) {
        CGSize sz = [LFLockScreenWidget naturalSizeForFamily:s.family];
        s.frame = CGRectMake(x, y + (natural.height - sz.height) / 2.0,
                             sz.width, sz.height);
        x += sz.width + kLFTrayGap;
    }

    // 4) Trailing-empty plus-slot. Only visible in edit mode AND when
    //    the tray already has at least one widget AND there's room
    //    for one more. The fully-empty case is handled by step (2).
    if (self.isEditing && _slots.count > 0 && self.usedUnits < kLFTrayMaxUnits) {
        LFLockScreenWidgetSlot *trailing =
            (LFLockScreenWidgetSlot *)[self viewWithTag:kLFTagTrailingEmptySlot];
        if (!trailing) {
            trailing = [[LFLockScreenWidgetSlot alloc] initWithFamily:LFWidgetFamilyCircular];
            trailing.tag       = kLFTagTrailingEmptySlot;
            trailing.delegate  = self;
            trailing.isEditing = YES;
            [self addSubview:trailing];
        }
        trailing.hidden = NO;
        trailing.isEditing = YES;
        CGSize sz = [LFLockScreenWidget naturalSizeForFamily:LFWidgetFamilyCircular];
        trailing.frame = CGRectMake(x, y + (natural.height - sz.height) / 2.0,
                                     sz.width, sz.height);
    } else {
        UIView *trailing = [self viewWithTag:kLFTagTrailingEmptySlot];
        trailing.hidden  = YES;
    }
}

// Big "Add Widgets" empty-state, rendered when the tray has no widgets.
// Layout (matches iOS 26 customize sheet's empty widget area):
//
//    ┌─────────────────────────────────────────┐
//    │                                         │
//    │      [+]  Add Widgets                   │
//    │                                         │
//    └─────────────────────────────────────────┘
//
// The "+" is a 36pt circular button with a 16pt SF Symbol "plus"
// glyph; the label sits 12pt to its right. Both are centered as a
// group inside the chrome border.
- (UIView *)lf_buildEmptyStateContainer {
    UIView *container = [UIView new];
    container.tag = kLFTagEmptyStateContainer;
    container.userInteractionEnabled = YES;

    UIView *plusBg = [UIView new];
    plusBg.backgroundColor      = [UIColor whiteColor];
    plusBg.layer.cornerRadius   = 18.0;     // 36pt circle
    plusBg.layer.masksToBounds  = YES;
    plusBg.userInteractionEnabled = NO;
    [container addSubview:plusBg];

    UIImageView *plusGlyph = [UIImageView new];
    plusGlyph.tintColor   = [UIColor blackColor];
    plusGlyph.contentMode = UIViewContentModeCenter;
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
            configurationWithPointSize:16 weight:UIImageSymbolWeightBold];
        plusGlyph.image = [UIImage systemImageNamed:@"plus" withConfiguration:cfg];
    }
    plusGlyph.userInteractionEnabled = NO;
    [container addSubview:plusGlyph];

    UILabel *addLabel              = [UILabel new];
    addLabel.text                  = @"Add Widgets";
    addLabel.textColor             = [UIColor whiteColor];
    addLabel.font                  = [UIFont systemFontOfSize:16
                                                       weight:UIFontWeightSemibold];
    addLabel.userInteractionEnabled = NO;
    [container addSubview:addLabel];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(onEmptyStateTap)];
    [container addGestureRecognizer:tap];

    [self addSubview:container];

    // Position children in container's coordinate space using a layout
    // closure on bounds change -- but UIView doesn't expose a bounds-
    // change closure; instead we rely on the container being resized
    // exactly to chromeBorder.frame and re-laying out via setNeedsLayout
    // each layout pass. We do that by overriding -layoutSubviews on a
    // tiny inner subclass... actually let's keep it simple and lay out
    // in the parent's -layoutSubviews via a helper.
    return container;
}

// Re-layout the empty-state internals every time the tray itself
// lays out. Called from -layoutSubviews above (we DO call it from
// there indirectly: empty.frame = chromeBorder.frame triggers
// layoutSubviews on the container, which has no override; so we lay
// out manually here by hopping the container's subviews from outside.)
- (void)lf_layoutEmptyStateInternals:(UIView *)container {
    if (!container || container.bounds.size.width < 1) return;
    UIView      *plusBg    = container.subviews[0];
    UIImageView *plusGlyph = (UIImageView *)container.subviews[1];
    UILabel     *addLabel  = (UILabel *)container.subviews[2];

    [addLabel sizeToFit];
    CGFloat plusSize = 36;
    CGFloat gap      = 12;
    CGFloat groupW   = plusSize + gap + addLabel.bounds.size.width;
    CGFloat startX   = (container.bounds.size.width - groupW) / 2.0;
    CGFloat midY     = container.bounds.size.height / 2.0;

    plusBg.frame    = CGRectMake(startX, midY - plusSize/2.0, plusSize, plusSize);
    plusGlyph.frame = plusBg.frame;
    addLabel.frame  = CGRectMake(startX + plusSize + gap,
                                 midY - addLabel.bounds.size.height/2.0,
                                 addLabel.bounds.size.width,
                                 addLabel.bounds.size.height);
}

- (void)onEmptyStateTap {
    // Default to circular when picked from the empty state -- user
    // can swap to rectangular through the picker's family swatch.
    [self.delegate trayDidRequestPicker:self family:LFWidgetFamilyCircular];
}

- (void)setIsEditing:(BOOL)e {
    _isEditing = e;
    for (LFLockScreenWidgetSlot *s in _slots) s.isEditing = e;
    UIView *trailing = [self viewWithTag:kLFTagTrailingEmptySlot];
    if ([trailing isKindOfClass:[LFLockScreenWidgetSlot class]]) {
        ((LFLockScreenWidgetSlot *)trailing).isEditing = e;
    }
    [self setNeedsLayout];
}

- (void)setBottomPanelOpen:(BOOL)open {
    _bottomPanelOpen = open;
    for (LFLockScreenWidgetSlot *s in _slots) s.bottomPanelOpen = open;
    UIView *trailing = [self viewWithTag:kLFTagTrailingEmptySlot];
    if ([trailing isKindOfClass:[LFLockScreenWidgetSlot class]]) {
        ((LFLockScreenWidgetSlot *)trailing).bottomPanelOpen = open;
    }
}

- (void)setSelectionWidth:(CGFloat)w {
    if (fabs(_selectionWidth - w) < 0.5) return;
    _selectionWidth = w;
    [self setNeedsLayout];
}

#pragma mark - Slot delegate

- (void)slotDidTapAdd:(LFLockScreenWidgetSlot *)slot {
    [self.delegate trayDidRequestPicker:self family:slot.family];
}

- (void)slotDidTapRemove:(LFLockScreenWidgetSlot *)slot {
    NSInteger idx = [_slots indexOfObject:slot];
    if (idx == NSNotFound) return;
    [self removeWidgetAtIndex:idx];
}

#pragma mark - Drag-to-bottom

// iOS 26 lock-screen widget area drag is LIVE: the tray's frame
// follows the finger 1:1 while the gesture is in flight, and
// snaps to the nearest valid Y position when the finger lifts.
// Earlier rev only signalled translation to the delegate without
// moving the tray, so the tray "perescakivalo" (snapped abruptly)
// at the end -- the user reported that. Now we move the frame in
// real time, set isUserDragging=YES so the clock overlay knows
// not to fight us in -repositionWidgetTray, and the delegate fires
// only on Ended so the editor can do the snap decision once with
// the FINAL accumulated translation.
- (void)onDragPan:(UIPanGestureRecognizer *)pan {
    if (!_isEditing) return;

    if (pan.state == UIGestureRecognizerStateBegan) {
        _dragStartFrameY = self.frame.origin.y;
        self.isUserDragging = YES;
    }

    CGPoint t = [pan translationInView:self.superview];

    if (pan.state == UIGestureRecognizerStateChanged ||
        pan.state == UIGestureRecognizerStateBegan) {
        // Live follow: tray.frame.origin.y = startY + translation.y,
        // clamped within sensible parent bounds so we don't drag the
        // tray off-screen or over the status bar. The editor's snap
        // logic later picks one of two known positions; in between,
        // the user gets a smooth visual.
        UIView *parent = self.superview;
        CGFloat parentH = parent ? parent.bounds.size.height
                                  : [UIScreen mainScreen].bounds.size.height;
        UIEdgeInsets safe = parent ? parent.safeAreaInsets
                                    : UIEdgeInsetsZero;
        CGFloat minY = safe.top + 80.0;     // never overlap status bar
        CGFloat maxY = parentH - safe.bottom - 60.0
                       - self.bounds.size.height;
        if (maxY < minY) maxY = minY;
        CGFloat newY = MAX(minY, MIN(maxY, _dragStartFrameY + t.y));
        CGRect f = self.frame;
        f.origin.y = newY;
        // Disable Core Animation implicit animations during the
        // drag so each frame update is rendered as-is (no 0.25s
        // tween that lags behind the finger).
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        self.frame = f;
        [CATransaction commit];
    }

    if (pan.state == UIGestureRecognizerStateEnded ||
        pan.state == UIGestureRecognizerStateCancelled ||
        pan.state == UIGestureRecognizerStateFailed) {
        self.isUserDragging = NO;
        [self.delegate tray:self didDragWithTranslationY:t.y ended:YES];
        [pan setTranslation:CGPointZero inView:self.superview];
    }
}

@end
