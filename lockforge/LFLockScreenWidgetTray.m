#import "LFLockScreenWidgetTray.h"
#import "LFLockScreenWidgetSlot.h"
#import "LFLockScreenWidgetCatalog.h"

static const CGFloat kLFTrayGap = 8.0;
static const CGFloat kLFTrayMaxUnits = 4;

@interface LFLockScreenWidgetTray () <LFLockScreenWidgetSlotDelegate> {
    NSMutableArray<LFLockScreenWidgetSlot *> *_slots;
    UIPanGestureRecognizer *_dragPan;
}
@end

@implementation LFLockScreenWidgetTray

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = [UIColor clearColor];
    _slots = [NSMutableArray array];

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
    // Reserve space for ONE empty trailing slot (so the picker is
    // always reachable until the tray is full).
    if (self.usedUnits < kLFTrayMaxUnits) {
        CGSize empty = [LFLockScreenWidget naturalSizeForFamily:LFWidgetFamilyCircular];
        if (h < empty.height) h = empty.height;
        if (w > 0) w += kLFTrayGap;
        w += empty.width;
    }
    if (h < 76) h = 76;
    return CGSizeMake(w, h);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    CGSize natural = self.naturalSize;
    CGFloat x = (b.size.width - natural.width) / 2.0;
    CGFloat y = (b.size.height - natural.height) / 2.0;

    // Layout filled slots.
    for (LFLockScreenWidgetSlot *s in _slots) {
        CGSize sz = [LFLockScreenWidget naturalSizeForFamily:s.family];
        s.frame = CGRectMake(x, y + (natural.height - sz.height) / 2.0,
                             sz.width, sz.height);
        x += sz.width + kLFTrayGap;
    }

    // The trailing "empty" plus-slot is rendered as a hidden subview
    // when there's still capacity. We DON'T persist it -- it appears
    // only in edit mode for the user to tap.
    if (self.isEditing && self.usedUnits < kLFTrayMaxUnits) {
        // Use a circular empty slot for the trailing plus -- if the
        // user wants rectangular they pick it from inside the picker.
        // Created lazily on first edit-mode layout via the tag below;
        // we don't keep a separate ivar/property because the view
        // tree itself is the source of truth for "does the empty
        // slot exist yet".
        //
        // (An earlier draft of this method probed `valueForKey:@"_emptySlotCached"`
        // which was a non-existent KVC key -- on iOS 15 SpringBoard
        // that throws NSUndefinedKeyException straight out of NSObject
        // and the whole process crashes. Two of those crashes within
        // 30s puts SpringBoard into safe mode. Removed.)
        LFLockScreenWidgetSlot *empty = (LFLockScreenWidgetSlot *)[self viewWithTag:0xEEFA];
        if (!empty) {
            empty = [[LFLockScreenWidgetSlot alloc] initWithFamily:LFWidgetFamilyCircular];
            empty.tag = 0xEEFA;
            empty.delegate = self;
            empty.isEditing = YES;
            [self addSubview:empty];
        }
        empty.hidden = NO;
        empty.isEditing = YES;
        CGSize sz = [LFLockScreenWidget naturalSizeForFamily:LFWidgetFamilyCircular];
        empty.frame = CGRectMake(x, y + (natural.height - sz.height) / 2.0,
                                  sz.width, sz.height);
    } else {
        UIView *empty = [self viewWithTag:0xEEFA];
        empty.hidden = YES;
    }
}

- (void)setIsEditing:(BOOL)e {
    _isEditing = e;
    for (LFLockScreenWidgetSlot *s in _slots) s.isEditing = e;
    UIView *empty = [self viewWithTag:0xEEFA];
    if ([empty isKindOfClass:[LFLockScreenWidgetSlot class]]) {
        ((LFLockScreenWidgetSlot *)empty).isEditing = e;
    }
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

- (void)onDragPan:(UIPanGestureRecognizer *)pan {
    if (!_isEditing) return;
    CGPoint t = [pan translationInView:self.superview];
    [self.delegate tray:self didDragWithTranslationY:t.y
                  ended:(pan.state == UIGestureRecognizerStateEnded ||
                         pan.state == UIGestureRecognizerStateCancelled ||
                         pan.state == UIGestureRecognizerStateFailed)];
    if (pan.state == UIGestureRecognizerStateEnded) {
        [pan setTranslation:CGPointZero inView:self.superview];
    }
}

@end
