#import "LFLockEditor.h"
#import "LFClockOverlay.h"
#import "LFClockSettings.h"

// =====================================================================
// LFPassthroughView -- transparent container for the editor.
//
// Earlier in the project's life this class forwarded touches through
// to the cover-sheet underneath (via -hitTest: returning nil) because
// the clock lived in the cover-sheet and we needed its drag-resize
// gestures to keep working from inside the editor's overlay.
//
// Now the clock is REPARENTED into the editor's view in
// -presentInWindow:, so every editor-mode interaction (tap, drag-
// resize) hit-tests through this view directly. We keep the class
// for symmetry with the rest of the file, but it's a plain UIView
// today -- there's no longer any pass-through behaviour.
// =====================================================================
@interface LFPassthroughView : UIView
@end
@implementation LFPassthroughView
@end

// Layout constants for the editor's bottom panel. iOS 16/26 customize
// sheet density: 64pt-tall font row, 48pt color dot row, 40pt slider
// row. Total content sits inside ~16pt vertical padding -- the
// overall panel height is computed in viewDidLayoutSubviews because
// safeAreaInsets.bottom isn't known at compile time.
//
// The font row Y-origin is now offset by `kLFPanelTopPad` so the row
// sits BELOW the close-X button at the panel's top-right corner --
// without that offset the picker cells overlap the X visually and
// catch touches meant for it.
static const CGFloat kLFFontRowHeight   = 64;
static const CGFloat kLFColorRowHeight  = 48;
static const CGFloat kLFSliderRowHeight = 40;
static const CGFloat kLFPanelTopPad     = 50;  // leaves room for the close-X
static const CGFloat kLFPanelBotPad     = 16;  // breathing room above safe area
// (Top bar removed earlier -- the editor uses a small close-X on
// the bottom panel instead, matching iOS 16/26's customize sheet.
// Alignment row removed in this pass: iOS 16/26 lock-screen clocks
// are always centred; the row served no purpose and just made the
// panel taller than necessary.)

@interface LFLockEditor () <UICollectionViewDataSource, UICollectionViewDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, weak)   LFClockOverlay      *clockOverlay;
@property (nonatomic, weak)   UIView              *clockOriginalParent;  // remember home for re-parenting on dismiss
@property (nonatomic, strong) UIVisualEffectView  *dimmer;       // covers wallpaper
// Compact close button -- small "x" pill at the top-right of the
// bottom panel. Replaces the old top bar with Cancel / Done; tapping
// it saves and dismisses (no separate Cancel anymore). Lives INSIDE
// the bottom panel so it slides in/out together with the rest of
// the customize sheet.
@property (nonatomic, strong) UIButton            *closeButton;
@property (nonatomic, strong) UIView              *bottomPanel;
@property (nonatomic, strong) UIVisualEffectView  *bottomPanelBlur;
@property (nonatomic, strong) UICollectionView    *fontPickerRow;
@property (nonatomic, strong) UICollectionView    *colorPickerRow;
@property (nonatomic, strong) UISlider            *glassSlider;
@property (nonatomic, strong) UILabel             *glassLabel;
// iOS 16/26 customize-sheet behaviour: the bottom panel is HIDDEN
// when the editor first appears (just selection rect + handle on
// the clock). Tapping the clock toggles the panel up/down. Tapping
// outside the clock and the panel either slides the panel down (if
// up) or dismisses the editor entirely (if already down). This
// state mirrors the panel's current on-screen position.
@property (nonatomic) BOOL   bottomPanelVisible;
@property (nonatomic) CGFloat panelHeight;            // recomputed each layout pass
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
    [self buildDimmer];
    [self buildBottomPanel];
}

#pragma mark - Setup

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

// Small "x" close button -- replaces the old Cancel/Done top bar.
// Anchored at the top-right corner of the bottom panel; tapping it
// saves all current settings and dismisses the editor (no separate
// Cancel anymore -- everything is live-saved on close). Lives as a
// subview of `_bottomPanel` so it slides in/out together with the
// rest of the customize sheet -- when the panel is hidden, the X is
// hidden too.
- (void)buildCloseButton {
    _closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
            configurationWithPointSize:26 weight:UIImageSymbolWeightSemibold];
        UIImage *xmark = [UIImage systemImageNamed:@"xmark.circle.fill"
                                 withConfiguration:cfg];
        [_closeButton setImage:xmark forState:UIControlStateNormal];
    } else {
        [_closeButton setTitle:@"Close" forState:UIControlStateNormal];
        [_closeButton setTitleColor:[UIColor whiteColor]
                           forState:UIControlStateNormal];
    }
    // Translucent grey circle, matches the iOS 16 sheet-close glyph
    // (white-25% on the symbol's filled background).
    _closeButton.tintColor = [UIColor colorWithWhite:1.0 alpha:0.55];
    [_closeButton addTarget:self
                     action:@selector(onClose)
           forControlEvents:UIControlEventTouchUpInside];
    [_bottomPanel addSubview:_closeButton];
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

    [self buildCloseButton];
    [self buildFontRow];
    [self buildColorRow];
    [self buildGlassSlider];
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

    // Total panel height: top pad (room for close-X) + 3 rows + bottom
    // pad + safe-area inset. Computed dynamically because
    // safeAreaInsets isn't available at compile time.
    CGFloat panelH = kLFPanelTopPad + kLFFontRowHeight + kLFColorRowHeight +
                     kLFSliderRowHeight + kLFPanelBotPad + safe.bottom;
    _panelHeight = panelH;

    // Panel position: at the screen bottom when visible, fully OFF
    // the bottom edge when hidden. Both states are laid out by frame
    // (no transform) so child layout stays simple.
    CGFloat panelY = _bottomPanelVisible
        ? (self.view.bounds.size.height - panelH)
        : self.view.bounds.size.height;
    _bottomPanel.frame = CGRectMake(0,
                                    panelY,
                                    self.view.bounds.size.width,
                                    panelH);
    _bottomPanelBlur.frame = _bottomPanel.bounds;

    // Close X: 30pt circle at top-right of the panel, 12pt margin.
    // Lives inside _bottomPanel now, so its position is in panel
    // coordinates -- it slides with the panel automatically.
    const CGFloat closeSize = 30.0;
    _closeButton.frame = CGRectMake(self.view.bounds.size.width - 12 - closeSize,
                                    12,
                                    closeSize, closeSize);

    // Picker rows. Font row starts BELOW the close-X (kLFPanelTopPad
    // = 50pt = 12pt top inset + 30pt button + 8pt gap) so its cells
    // never overlap the X visually or steal touches from it.
    CGFloat y = kLFPanelTopPad;
    _fontPickerRow.frame  = CGRectMake(0, y, self.view.bounds.size.width, kLFFontRowHeight);
    y += kLFFontRowHeight;
    _colorPickerRow.frame = CGRectMake(0, y, self.view.bounds.size.width, kLFColorRowHeight);
    y += kLFColorRowHeight;
    _glassLabel.frame  = CGRectMake(16, y + 6, 60, 24);
    _glassSlider.frame = CGRectMake(76, y + 4, self.view.bounds.size.width - 92, 28);
}

#pragma mark - Bottom panel show / hide

// iOS 16/26-style customize-sheet animation: the bottom panel slides
// up from below the screen when the clock is tapped, and slides back
// down when the user taps anywhere outside it. We tween via
// -setNeedsLayout + UIView animation so the layout pass handles the
// frame change, keeping all subview positions correct relative to the
// panel's current bounds without us having to maintain a transform.
- (void)setBottomPanelVisible:(BOOL)visible animated:(BOOL)animated {
    if (_bottomPanelVisible == visible) return;
    _bottomPanelVisible = visible;
    [self.view setNeedsLayout];
    if (animated) {
        // Spring damping 0.9 / no initial velocity is the same curve
        // Apple uses for sheet-up/-down on iOS 16, soft and quick.
        [UIView animateWithDuration:0.32
                              delay:0
             usingSpringWithDamping:0.9
              initialSpringVelocity:0.0
                            options:UIViewAnimationOptionCurveEaseOut |
                                    UIViewAnimationOptionAllowUserInteraction
                         animations:^{
            [self.view layoutIfNeeded];
        }
                         completion:nil];
    } else {
        [self.view layoutIfNeeded];
    }
}

#pragma mark - Tap recognizers

- (void)installEditorTapRecognizers {
    // Tap on the clock toggles the customize sheet up/down. Lives on
    // the clock overlay so it observes touches anywhere inside its
    // bounds (including the resize handle, where a tap with no drag
    // doesn't trigger a resize and so falls through here).
    UITapGestureRecognizer *clockTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(onClockTap:)];
    clockTap.delegate = self;
    [_clockOverlay addGestureRecognizer:clockTap];

    // Tap anywhere ELSE in the editor view (the dimmer area, in
    // practice). Default UIKit recognizer-resolution rules pick the
    // most-specific recognizer, so taps inside _clockOverlay or
    // _bottomPanel never reach this one -- only true "outside"
    // taps fire it.
    UITapGestureRecognizer *outsideTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(onOutsideTap:)];
    outsideTap.delegate = self;
    [self.view addGestureRecognizer:outsideTap];
}

// Tap on the clock: bring the customize sheet up if it's down,
// otherwise hide it again. Same finger affordance as iOS 16's editor
// where tapping a widget toggles its option sheet.
- (void)onClockTap:(UITapGestureRecognizer *)tap {
    [self setBottomPanelVisible:!_bottomPanelVisible animated:YES];
}

// Tap on the dimmer / empty area:
//   - if the panel is UP   -> slide it down (one-step retreat)
//   - if the panel is DOWN -> dismiss the editor (no other close
//                              affordance is on screen at this point)
- (void)onOutsideTap:(UITapGestureRecognizer *)tap {
    if (_bottomPanelVisible) {
        [self setBottomPanelVisible:NO animated:YES];
    } else {
        [self onClose];
    }
}

#pragma mark - UIGestureRecognizerDelegate

// Allow our editor-level taps to coexist with the clock's pan
// recognizer (drag-resize). Without this, the recognizer system
// might fail one of them prematurely on a fast tap-then-drag.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}

#pragma mark - Buttons

// Single close button -- saves all changes and dismisses the editor.
// (No separate Cancel: every settings change is written to memory
// live as the user toys with the pickers, and persisted to disk on
// dismiss. To revert the user re-edits.)
- (void)onClose {
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
        // The bottom panel + close button must be above the clock
        // for chrome; the clock itself stays above the dimmer.
        [self.view bringSubviewToFront:_clockOverlay];
        [self.view bringSubviewToFront:_bottomPanel];
    }

    // Customize sheet starts HIDDEN -- the editor first reveals just
    // the clock with its selection rect + resize handle, exactly the
    // iOS 16/26 entrance state. The user taps the clock to bring up
    // font / colour / glass options.
    _bottomPanelVisible = NO;
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];

    // Editor-level tap recognizers: clock-tap (toggle sheet) and
    // outside-tap (hide sheet, then dismiss). Installed AFTER the
    // clock has been re-parented so the recognizer is attached to
    // the right view instance.
    [self installEditorTapRecognizers];

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
