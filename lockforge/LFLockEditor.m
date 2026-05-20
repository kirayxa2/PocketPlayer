#import "LFLockEditor.h"
#import "LFClockOverlay.h"
#import "LFClockSettings.h"

// =====================================================================
// LFPassthroughView -- transparent container for the editor.
//
// Why we need it: the editor's root view covers the whole window and
// sits ABOVE the cover-sheet view (which contains the clock). UIKit
// hit-tests top-down, so any touch that lands on the editor root
// (anywhere except top bar / bottom panel) was being intercepted by
// the root or the dimmer instead of reaching the clock underneath.
// That's why drag-resize "didn't react" -- the gesture recognizer
// on the resize handle was correct, but the touch never reached it.
//
// The passthrough trick: -hitTest: returns nil whenever the result
// is self -- meaning "the touch landed in empty container space, not
// on a real subview". UIKit then continues searching siblings of the
// editor root in the window, finding the cover-sheet view, which in
// turn finds the clock and handle.
// =====================================================================
@interface LFPassthroughView : UIView
@end
@implementation LFPassthroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self) ? nil : hit;
}
@end

// Layout constants for the editor's bottom panel. Picked to match iOS
// 26's customize sheet density: 60pt-tall font row, 44pt color dot
// row, 36pt slider row, 12pt vertical padding.
static const CGFloat kLFFontRowHeight      = 64;
static const CGFloat kLFColorRowHeight     = 48;
static const CGFloat kLFSliderRowHeight    = 40;
static const CGFloat kLFAlignmentRowHeight = 44;  // small icon row, centered
static const CGFloat kLFEditorBottomPanelHeight =
    kLFFontRowHeight + kLFColorRowHeight + kLFSliderRowHeight +
    kLFAlignmentRowHeight + 24 + 80; // + safeArea
// Top toolbar height (Cancel / Done).
static const CGFloat kLFEditorTopBarHeight = 64;

@interface LFLockEditor () <UICollectionViewDataSource, UICollectionViewDelegate>
@property (nonatomic, weak)   LFClockOverlay      *clockOverlay;
@property (nonatomic, weak)   UIView              *clockOriginalParent;  // remember home for re-parenting on dismiss
@property (nonatomic, strong) UIVisualEffectView  *dimmer;       // covers wallpaper
@property (nonatomic, strong) UIView              *topBar;
@property (nonatomic, strong) UIButton            *cancelButton;
@property (nonatomic, strong) UIButton            *doneButton;
@property (nonatomic, strong) UIView              *bottomPanel;
@property (nonatomic, strong) UIVisualEffectView  *bottomPanelBlur;
@property (nonatomic, strong) UICollectionView    *fontPickerRow;
@property (nonatomic, strong) UICollectionView    *colorPickerRow;
@property (nonatomic, strong) UISlider            *glassSlider;
@property (nonatomic, strong) UILabel             *glassLabel;
// Alignment row -- three small icon buttons (left / center / right),
// horizontally centered in the bottom panel. Maps to LFClockAlignment.
@property (nonatomic, strong) UIView              *alignmentRow;
@property (nonatomic, strong) UIButton            *alignLeftButton;
@property (nonatomic, strong) UIButton            *alignCenterButton;
@property (nonatomic, strong) UIButton            *alignRightButton;
// Snapshot of settings at the moment the editor opened. Used to
// revert if the user taps Cancel.
@property (nonatomic, strong) NSDictionary        *initialSnapshot;
@end

@implementation LFLockEditor

- (instancetype)initWithClockOverlay:(LFClockOverlay *)clockOverlay {
    self = [super init];
    if (!self) return nil;
    _clockOverlay = clockOverlay;
    return self;
}

// Override loadView so the root view is our passthrough class instead
// of a plain UIView. Without this, all touches to the empty middle
// area get absorbed by the editor's root and never reach the clock.
- (void)loadView {
    LFPassthroughView *root = [[LFPassthroughView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    root.backgroundColor = [UIColor clearColor];
    self.view = root;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];
    [self snapshotSettings];
    [self buildDimmer];
    [self buildTopBar];
    [self buildBottomPanel];
}

#pragma mark - Setup

- (void)snapshotSettings {
    LFClockSettings *s = [LFClockSettings shared];
    _initialSnapshot = @{
        @"font":                 @(s.font),
        @"colorMode":            @(s.colorMode),
        @"customColorRGBA":      s.customColorRGBA ?: @[ @1, @1, @1, @1 ],
        @"scale":                @(s.scale),
        @"horizontalStretch":    @(s.horizontalStretch),
        @"verticalStretch":      @(s.verticalStretch),
        @"alignment":            @(s.alignment),
        @"positionOffsetX":      @(s.positionOffset.x),
        @"positionOffsetY":      @(s.positionOffset.y),
        @"liquidGlassIntensity": @(s.liquidGlassIntensity),
    };
}

- (void)restoreFromSnapshot {
    LFClockSettings *s = [LFClockSettings shared];
    s.font                 = (LFClockFont)[_initialSnapshot[@"font"] integerValue];
    s.colorMode            = (LFClockColorMode)[_initialSnapshot[@"colorMode"] integerValue];
    s.customColorRGBA      = _initialSnapshot[@"customColorRGBA"];
    s.scale                = [_initialSnapshot[@"scale"] doubleValue];
    s.horizontalStretch    = [_initialSnapshot[@"horizontalStretch"] doubleValue];
    s.verticalStretch      = [_initialSnapshot[@"verticalStretch"] doubleValue];
    s.alignment            = (LFClockAlignment)[_initialSnapshot[@"alignment"] integerValue];
    s.positionOffset       = CGPointMake([_initialSnapshot[@"positionOffsetX"] doubleValue],
                                         [_initialSnapshot[@"positionOffsetY"] doubleValue]);
    s.liquidGlassIntensity = [_initialSnapshot[@"liquidGlassIntensity"] integerValue];
    [_clockOverlay refreshFromSettings];
}

- (void)buildDimmer {
    UIBlurEffect *eff = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    _dimmer = [[UIVisualEffectView alloc] initWithEffect:eff];
    _dimmer.frame = self.view.bounds;
    _dimmer.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                               UIViewAutoresizingFlexibleHeight;
    // CRITICAL: dimmer is just a visual treatment. We must not let it
    // catch any touches, otherwise it eats every drag aimed at the
    // clock under us. With this off, touches on the dimmer fall
    // through to the passthrough root, which forwards them to the
    // cover-sheet view containing the clock.
    _dimmer.userInteractionEnabled = NO;
    [self.view addSubview:_dimmer];
}

- (void)buildTopBar {
    _topBar = [UIView new];
    _topBar.backgroundColor = [UIColor clearColor];
    [self.view addSubview:_topBar];

    UIBlurEffect *eff = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial];
    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:eff];
    blur.alpha = 0.7;
    [_topBar addSubview:blur];
    blur.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [blur.topAnchor      constraintEqualToAnchor:_topBar.topAnchor],
        [blur.bottomAnchor   constraintEqualToAnchor:_topBar.bottomAnchor],
        [blur.leadingAnchor  constraintEqualToAnchor:_topBar.leadingAnchor],
        [blur.trailingAnchor constraintEqualToAnchor:_topBar.trailingAnchor],
    ]];

    _cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_cancelButton setTitle:@"Cancel" forState:UIControlStateNormal];
    [_cancelButton.titleLabel setFont:[UIFont systemFontOfSize:16 weight:UIFontWeightSemibold]];
    [_cancelButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [_cancelButton addTarget:self action:@selector(onCancel) forControlEvents:UIControlEventTouchUpInside];
    [_topBar addSubview:_cancelButton];

    _doneButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_doneButton setTitle:@"Done" forState:UIControlStateNormal];
    [_doneButton.titleLabel setFont:[UIFont systemFontOfSize:16 weight:UIFontWeightBold]];
    [_doneButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [_doneButton addTarget:self action:@selector(onDone) forControlEvents:UIControlEventTouchUpInside];
    [_topBar addSubview:_doneButton];
}

- (void)buildBottomPanel {
    _bottomPanel = [UIView new];
    [self.view addSubview:_bottomPanel];

    // Translucent panel base. Liquid-Glass-ish (matches the editor
    // sheet on iOS 26 visually).
    UIBlurEffect *eff = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark];
    _bottomPanelBlur = [[UIVisualEffectView alloc] initWithEffect:eff];
    _bottomPanelBlur.layer.cornerRadius = 32;
    _bottomPanelBlur.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    _bottomPanelBlur.layer.masksToBounds = YES;
    [_bottomPanel addSubview:_bottomPanelBlur];

    [self buildFontRow];
    [self buildColorRow];
    [self buildGlassSlider];
    [self buildAlignmentRow];
}

// Three small icon-only buttons arranged horizontally and centered in
// the bottom panel. Each is 36x36 with an SF Symbol (left/center/right
// alignment). The currently chosen one gets a subtle white border;
// the rest are neutral. Tapping flips LFClockSettings.alignment and
// triggers a live re-layout of the clock.
- (void)buildAlignmentRow {
    _alignmentRow = [UIView new];
    _alignmentRow.backgroundColor = [UIColor clearColor];
    [_bottomPanel addSubview:_alignmentRow];

    _alignLeftButton   = [self makeAlignmentButtonWithSymbol:@"text.alignleft"
                                                         tag:LFClockAlignmentLeft];
    _alignCenterButton = [self makeAlignmentButtonWithSymbol:@"text.aligncenter"
                                                         tag:LFClockAlignmentCenter];
    _alignRightButton  = [self makeAlignmentButtonWithSymbol:@"text.alignright"
                                                         tag:LFClockAlignmentRight];
    [_alignmentRow addSubview:_alignLeftButton];
    [_alignmentRow addSubview:_alignCenterButton];
    [_alignmentRow addSubview:_alignRightButton];
    [self refreshAlignmentSelection];
}

- (UIButton *)makeAlignmentButtonWithSymbol:(NSString *)symbol tag:(NSInteger)tag {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.tag = tag;
    b.tintColor = [UIColor whiteColor];
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
            configurationWithPointSize:18 weight:UIImageSymbolWeightSemibold];
        UIImage *img = [UIImage systemImageNamed:symbol withConfiguration:cfg];
        [b setImage:img forState:UIControlStateNormal];
    } else {
        // Fallback labels on the slim chance someone runs this on a
        // pre-iOS-13 build, which Dopamine doesn't actually support.
        NSString *txt = (tag == LFClockAlignmentLeft) ? @"L"
                      : (tag == LFClockAlignmentRight) ? @"R" : @"C";
        [b setTitle:txt forState:UIControlStateNormal];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    }
    b.layer.cornerRadius = 10;
    b.layer.borderWidth = 1.0;
    b.layer.borderColor = [[UIColor colorWithWhite:1.0 alpha:0.15] CGColor];
    [b addTarget:self
          action:@selector(onAlignmentTap:)
forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)refreshAlignmentSelection {
    LFClockAlignment a = [LFClockSettings shared].alignment;
    UIButton *all[3] = { _alignLeftButton, _alignCenterButton, _alignRightButton };
    for (NSInteger i = 0; i < 3; i++) {
        BOOL on = (i == (NSInteger)a);
        all[i].layer.borderColor =
            (on ? [[UIColor whiteColor] CGColor]
                : [[UIColor colorWithWhite:1.0 alpha:0.15] CGColor]);
        all[i].layer.borderWidth = on ? 2.0 : 1.0;
        all[i].backgroundColor = on
            ? [UIColor colorWithWhite:1.0 alpha:0.10]
            : [UIColor clearColor];
    }
}

- (void)onAlignmentTap:(UIButton *)b {
    LFClockAlignment a = (LFClockAlignment)b.tag;
    if ([LFClockSettings shared].alignment == a) return;
    [LFClockSettings shared].alignment = a;
    [_clockOverlay refreshFromSettings];
    [self refreshAlignmentSelection];
}

- (void)buildFontRow {
    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.scrollDirection = UICollectionViewScrollDirectionHorizontal;
    layout.itemSize        = CGSizeMake(56, 56);
    layout.minimumLineSpacing = 12;
    layout.sectionInset    = UIEdgeInsetsMake(0, 16, 0, 16);

    _fontPickerRow = [[UICollectionView alloc] initWithFrame:CGRectZero
                                        collectionViewLayout:layout];
    _fontPickerRow.backgroundColor = [UIColor clearColor];
    _fontPickerRow.dataSource      = self;
    _fontPickerRow.delegate        = self;
    _fontPickerRow.showsHorizontalScrollIndicator = NO;
    _fontPickerRow.tag = 1;
    [_fontPickerRow registerClass:[UICollectionViewCell class]
       forCellWithReuseIdentifier:@"font"];
    [_bottomPanel addSubview:_fontPickerRow];
}

- (void)buildColorRow {
    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.scrollDirection = UICollectionViewScrollDirectionHorizontal;
    layout.itemSize        = CGSizeMake(40, 40);
    layout.minimumLineSpacing = 12;
    layout.sectionInset    = UIEdgeInsetsMake(0, 16, 0, 16);

    _colorPickerRow = [[UICollectionView alloc] initWithFrame:CGRectZero
                                         collectionViewLayout:layout];
    _colorPickerRow.backgroundColor = [UIColor clearColor];
    _colorPickerRow.dataSource      = self;
    _colorPickerRow.delegate        = self;
    _colorPickerRow.showsHorizontalScrollIndicator = NO;
    _colorPickerRow.tag = 2;
    [_colorPickerRow registerClass:[UICollectionViewCell class]
        forCellWithReuseIdentifier:@"color"];
    [_bottomPanel addSubview:_colorPickerRow];
}

- (void)buildGlassSlider {
    _glassLabel              = [UILabel new];
    _glassLabel.text         = @"Glass";
    _glassLabel.textColor    = [UIColor whiteColor];
    _glassLabel.font         = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    [_bottomPanel addSubview:_glassLabel];

    _glassSlider                  = [UISlider new];
    _glassSlider.minimumValue     = 0;
    _glassSlider.maximumValue     = 3;
    _glassSlider.value            = (float)[LFClockSettings shared].liquidGlassIntensity;
    _glassSlider.tintColor        = [UIColor whiteColor];
    _glassSlider.continuous       = YES;
    [_glassSlider addTarget:self action:@selector(onGlassSliderChanged:)
           forControlEvents:UIControlEventValueChanged];
    [_bottomPanel addSubview:_glassSlider];
}

#pragma mark - Layout

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIEdgeInsets safe = self.view.safeAreaInsets;

    _topBar.frame = CGRectMake(0, 0, self.view.bounds.size.width,
                               kLFEditorTopBarHeight + safe.top);
    _cancelButton.frame = CGRectMake(16, safe.top + 12, 80, 30);
    _doneButton.frame   = CGRectMake(self.view.bounds.size.width - 80 - 16,
                                     safe.top + 12, 80, 30);

    CGFloat panelH = kLFEditorBottomPanelHeight;
    _bottomPanel.frame = CGRectMake(0,
                                    self.view.bounds.size.height - panelH,
                                    self.view.bounds.size.width,
                                    panelH);
    _bottomPanelBlur.frame = _bottomPanel.bounds;

    CGFloat y = 16;
    _fontPickerRow.frame = CGRectMake(0, y, self.view.bounds.size.width, kLFFontRowHeight);
    y += kLFFontRowHeight;
    _colorPickerRow.frame = CGRectMake(0, y, self.view.bounds.size.width, kLFColorRowHeight);
    y += kLFColorRowHeight;
    _glassLabel.frame = CGRectMake(16, y + 6, 60, 24);
    _glassSlider.frame = CGRectMake(76, y + 4, self.view.bounds.size.width - 92, 28);
    y += kLFSliderRowHeight;

    // Alignment row: three small 36pt buttons centred horizontally
    // inside the panel with 12pt spacing between them.
    _alignmentRow.frame = CGRectMake(0, y, self.view.bounds.size.width,
                                     kLFAlignmentRowHeight);
    const CGFloat btn = 36, gap = 12;
    CGFloat groupW = btn * 3 + gap * 2;
    CGFloat startX = (self.view.bounds.size.width - groupW) / 2.0;
    CGFloat btnY   = (kLFAlignmentRowHeight - btn) / 2.0;
    _alignLeftButton.frame   = CGRectMake(startX,                       btnY, btn, btn);
    _alignCenterButton.frame = CGRectMake(startX + btn + gap,           btnY, btn, btn);
    _alignRightButton.frame  = CGRectMake(startX + (btn + gap) * 2,     btnY, btn, btn);
}

#pragma mark - Buttons

- (void)onCancel {
    [self restoreFromSnapshot];
    [self refreshAlignmentSelection];
    [_fontPickerRow reloadData];
    [_colorPickerRow reloadData];
    _glassSlider.value = (float)[LFClockSettings shared].liquidGlassIntensity;
    [self dismissEditor];
}

- (void)onDone {
    [[LFClockSettings shared] save];
    [self dismissEditor];
}

- (void)dismissEditor {
    _clockOverlay.isEditing = NO;
    __weak __typeof(self) weakSelf = self;
    [UIView animateWithDuration:0.25 animations:^{
        self.view.alpha = 0;
    } completion:^(BOOL ok) {
        __strong __typeof(weakSelf) self_ = weakSelf;
        if (!self_) return;

        // Put the clock back in its original parent (cover-sheet view)
        // so the lockscreen continues to display it after we're gone.
        // Convert center first so it stays put visually.
        if (self_.clockOverlay && self_.clockOriginalParent) {
            UIWindow *win = self_.view.window;
            CGPoint centerInWindow = [self_.view convertPoint:self_.clockOverlay.center
                                                       toView:win];
            CGPoint centerInOrig   = [self_.clockOriginalParent convertPoint:centerInWindow
                                                                    fromView:win];
            [self_.clockOriginalParent addSubview:self_.clockOverlay];
            self_.clockOverlay.center = centerInOrig;
        }

        [self_.view removeFromSuperview];
        // Tell the tweak's gesture handler we're gone so the next
        // long-press spawns a fresh editor (bug-1 fix).
        id<LFLockEditorDelegate> d = self_.delegate;
        if ([d respondsToSelector:@selector(lockEditorDidDismiss:)]) {
            [d lockEditorDidDismiss:self_];
        }
    }];
}

- (void)onGlassSliderChanged:(UISlider *)slider {
    NSInteger v = (NSInteger)roundf(slider.value);
    if (v == [LFClockSettings shared].liquidGlassIntensity) return;
    [LFClockSettings shared].liquidGlassIntensity = v;
    [_clockOverlay refreshFromSettings];
}

#pragma mark - Presentation

- (void)presentInWindow:(UIWindow *)window {
    self.view.frame = window.bounds;
    self.view.alpha = 0;
    [window addSubview:self.view];

    // Move the clock INTO our view, on top of the dimmer, so the user
    // sees it crisp (not behind the dim) AND so its touches go through
    // our editor view directly without competing for hit-tests with
    // the cover-sheet underneath. Saved location remembered so we can
    // put it back when the editor closes.
    _clockOriginalParent = _clockOverlay.superview;
    if (_clockOverlay && _clockOriginalParent) {
        // Convert center to our view's coordinate space first so the
        // clock doesn't visually jump on the reparent.
        CGPoint centerInWindow = [_clockOriginalParent convertPoint:_clockOverlay.center
                                                              toView:window];
        CGPoint centerInUs     = [self.view convertPoint:centerInWindow fromView:window];
        [self.view addSubview:_clockOverlay];     // also removes from old superview
        _clockOverlay.center = centerInUs;
        // The bottom panel and top bar can be in front of the clock
        // for chrome, but the clock itself must be above the dimmer.
        [self.view bringSubviewToFront:_clockOverlay];
        [self.view bringSubviewToFront:_topBar];
        [self.view bringSubviewToFront:_bottomPanel];
    }

    _clockOverlay.isEditing = YES;
    [UIView animateWithDuration:0.25 animations:^{
        self.view.alpha = 1;
    }];
}

#pragma mark - UICollectionViewDataSource / Delegate

- (NSInteger)collectionView:(UICollectionView *)cv
     numberOfItemsInSection:(NSInteger)section {
    if (cv.tag == 1) return LFClockFontCount;
    if (cv.tag == 2) return LFClockColorModeCount;
    return 0;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)cv
                  cellForItemAtIndexPath:(NSIndexPath *)idx {
    if (cv.tag == 1) {
        UICollectionViewCell *cell = [cv dequeueReusableCellWithReuseIdentifier:@"font"
                                                                   forIndexPath:idx];
        for (UIView *v in cell.contentView.subviews) [v removeFromSuperview];

        UILabel *aa = [UILabel new];
        aa.text          = @"Aa";
        aa.textAlignment = NSTextAlignmentCenter;
        aa.textColor     = [UIColor whiteColor];
        aa.frame         = cell.contentView.bounds;
        aa.font          = [self previewFontForIndex:idx.item];
        [cell.contentView addSubview:aa];

        BOOL selected = (idx.item == [LFClockSettings shared].font);
        cell.contentView.layer.borderColor =
            (selected ? [[UIColor whiteColor] CGColor]
                      : [[UIColor colorWithWhite:1.0 alpha:0.18] CGColor]);
        cell.contentView.layer.borderWidth  = selected ? 2.0 : 1.0;
        cell.contentView.layer.cornerRadius = 16;
        return cell;
    }
    if (cv.tag == 2) {
        UICollectionViewCell *cell = [cv dequeueReusableCellWithReuseIdentifier:@"color"
                                                                   forIndexPath:idx];
        for (UIView *v in cell.contentView.subviews) [v removeFromSuperview];
        UIView *dot = [[UIView alloc] initWithFrame:cell.contentView.bounds];
        dot.layer.cornerRadius = cell.contentView.bounds.size.width / 2.0;
        dot.layer.masksToBounds = YES;
        dot.backgroundColor = [self previewColorForIndex:idx.item];
        // Adaptive: show as gradient half-white, half-black.
        if (idx.item == LFClockColorAdaptive) {
            CAGradientLayer *g = [CAGradientLayer layer];
            g.frame = dot.bounds;
            g.colors = @[ (id)[UIColor whiteColor].CGColor,
                          (id)[UIColor blackColor].CGColor ];
            g.startPoint = CGPointMake(0, 0);
            g.endPoint   = CGPointMake(1, 1);
            [dot.layer addSublayer:g];
            dot.backgroundColor = [UIColor clearColor];
        }
        [cell.contentView addSubview:dot];
        BOOL selected = (idx.item == [LFClockSettings shared].colorMode);
        cell.contentView.layer.borderColor =
            (selected ? [[UIColor whiteColor] CGColor]
                      : [[UIColor clearColor] CGColor]);
        cell.contentView.layer.borderWidth  = selected ? 2.0 : 0.0;
        cell.contentView.layer.cornerRadius = cell.contentView.bounds.size.width / 2.0;
        return cell;
    }
    return [UICollectionViewCell new];
}

- (void)collectionView:(UICollectionView *)cv
didSelectItemAtIndexPath:(NSIndexPath *)idx {
    if (cv.tag == 1) {
        [LFClockSettings shared].font = (LFClockFont)idx.item;
    } else if (cv.tag == 2) {
        [LFClockSettings shared].colorMode = (LFClockColorMode)idx.item;
    }
    [_clockOverlay refreshFromSettings];
    [cv reloadData];
}

#pragma mark - Helpers

- (UIFont *)previewFontForIndex:(NSInteger)i {
    LFClockFont saved = [LFClockSettings shared].font;
    [LFClockSettings shared].font = (LFClockFont)i;
    UIFont *f = [[LFClockSettings shared] resolvedFontForReferenceSize:24];
    [LFClockSettings shared].font = saved;
    return f;
}

- (UIColor *)previewColorForIndex:(NSInteger)i {
    LFClockColorMode saved = [LFClockSettings shared].colorMode;
    [LFClockSettings shared].colorMode = (LFClockColorMode)i;
    UIColor *c = [[LFClockSettings shared] resolvedColorForBackgroundLuminance:nil];
    [LFClockSettings shared].colorMode = saved;
    return c;
}

@end
